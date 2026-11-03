#import "SPDFMarkdownPicture.h"

#import <ImageIO/ImageIO.h>
#import <os/lock.h>

#include <atomic>

const NSUInteger SPDFMarkdownPictureMaximumDecodedSide = 8192;
// A decode covers a little more than the draw that asked for it, so the small
// steps of a zoom reuse it instead of decoding at every step.
static const CGFloat SPDFPictureDecodeHeadroom = 1.25;
// Print and PDF export have no pixels of their own: decode for 300 dpi. A file
// up to twice that is handed over whole, as it is: a smaller copy of it would
// save little and, re-encoded, could cost more bytes than the file.
static const CGFloat SPDFPicturePrintPixelsPerPoint = 300.0 / 72.0;
static const CGFloat SPDFPicturePrintWholeFactor = 2;
// Decoded pixels kept across draws (purgeable, so the system can take them
// sooner): about forty photos at screen size.
static const NSUInteger SPDFPictureCacheBytes = 256 * 1024 * 1024;
// A picture at most this much larger than the decode a draw wants is drawn from
// the file as it is, decoded by ImageIO as it draws, as every picture was before
// display-size decoding: a smaller copy would cost that full decode and a copy
// on top for little saving. Those decodes are kept up to the second budget
// (what 32 million pixels took), the least recently drawn let go first.
static const CGFloat SPDFPictureWholeFactor = 2;
static const NSUInteger SPDFPictureWholeCacheBytes = 128 * 1024 * 1024;

static NSCache* SPDFPictureWholeCache(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      cache = [NSCache new];
      cache.name = @"Markdown pictures, whole";
      cache.totalCostLimit = SPDFPictureWholeCacheBytes;
    });
    return cache;
}

// A picture as the file has it, for the whole-picture cache.
@interface SPDFPictureWhole : NSObject
@property(nonatomic, readonly) CGImageRef image;
@end
@implementation SPDFPictureWhole
- (instancetype)initWithImage:(CGImageRef)image {
    if ((self = [super init])) _image = CGImageRetain(image);
    return self;
}
- (void)dealloc {
    CGImageRelease(_image);
}
@end

// Guards NSPurgeableData access counts, which the draw and CoreGraphics'
// release callbacks change from any thread.
static os_unfair_lock SPDFPictureAccessLock = OS_UNFAIR_LOCK_INIT;

static NSCache* SPDFPictureCache(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      cache = [NSCache new];
      cache.name = @"Markdown pictures";
      cache.totalCostLimit = SPDFPictureCacheBytes;
    });
    return cache;
}

// One decoded picture in purgeable memory, 8-bit premultiplied RGBA.
@interface SPDFPicturePixels : NSObject
@property(nonatomic, readonly) size_t width;
@property(nonatomic, readonly) size_t height;
@property(nonatomic, readonly) NSUInteger cost;
@property(nonatomic, readonly) void* variant;  // the function that made these pixels, NULL for the decode itself
@end

static void SPDFPicturePixelsReleased(void* info, const void* data, size_t size) {
    (void)data;
    (void)size;
    NSPurgeableData* bytes = (__bridge_transfer NSPurgeableData*)info;
    os_unfair_lock_lock(&SPDFPictureAccessLock);
    [bytes endContentAccess];
    os_unfair_lock_unlock(&SPDFPictureAccessLock);
}

@implementation SPDFPicturePixels {
    NSPurgeableData* _bytes;
    size_t _bytesPerRow;
    CGColorSpaceRef _space;
    CGBitmapInfo _info;
}

// Copies `image` into new purgeable memory, released for purging at once.
- (nullable instancetype)initCopying:(CGImageRef)image variant:(void*)variant {
    if (!(self = [super init])) return nil;
    _width = CGImageGetWidth(image);
    _height = CGImageGetHeight(image);
    _variant = variant;
    CGColorSpaceRef own = CGImageGetColorSpace(image);
    _space = own && CGColorSpaceGetModel(own) == kCGColorSpaceModelRGB ? CGColorSpaceRetain(own)
                                                                        : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _bytesPerRow = _width * 4;
    if (!_space || !_width || !_height || _height > SIZE_MAX / _bytesPerRow) return nil;
    _bytes = [[NSPurgeableData alloc] initWithLength:_bytesPerRow * _height];  // accessed until endContentAccess
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    BOOL opaque = alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipLast || alpha == kCGImageAlphaNoneSkipFirst;
    CGBitmapInfo info = (opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast) | kCGBitmapByteOrder32Big;
    _info = info;
    CGContextRef context = CGBitmapContextCreate(_bytes.mutableBytes, _width, _height, 8, _bytesPerRow, _space, info);
    if (!context) {  // a colour space a bitmap cannot draw into: fall back to sRGB
        CGColorSpaceRelease(_space);
        _space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        context = CGBitmapContextCreate(_bytes.mutableBytes, _width, _height, 8, _bytesPerRow, _space, info);
    }
    if (context) {
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, _width, _height), image);
        CGContextRelease(context);
    }
    os_unfair_lock_lock(&SPDFPictureAccessLock);
    [_bytes endContentAccess];
    os_unfair_lock_unlock(&SPDFPictureAccessLock);
    if (!context) return nil;
    _cost = _bytesPerRow * _height;
    return self;
}

- (void)dealloc {
    if (_space) CGColorSpaceRelease(_space);
}

// An image over the pixels that keeps them from being purged while it lives;
// NULL once the system has reclaimed them.
- (nullable CGImageRef)newImage {
    os_unfair_lock_lock(&SPDFPictureAccessLock);
    BOOL available = [_bytes beginContentAccess];
    os_unfair_lock_unlock(&SPDFPictureAccessLock);
    if (!available) return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithData((__bridge_retained void*)_bytes, _bytes.bytes,
                                                              _bytes.length, SPDFPicturePixelsReleased);
    if (!provider) {
        SPDFPicturePixelsReleased((__bridge void*)_bytes, NULL, 0);  // balances the retain and the access
        return NULL;
    }
    CGImageRef image = CGImageCreate(_width, _height, 8, 32, _bytesPerRow, _space,
                                     _info, provider, NULL,
                                     true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}
@end

// What every copy of one picture rep shares: NSImage copies its reps.
@interface SPDFPictureSource : NSObject
@property(nonatomic, readonly) size_t width;
@property(nonatomic, readonly) size_t height;
@property(nonatomic, readonly) NSData* _Nullable (^reload)(void);
@property(nonatomic, readonly) NSNumber* decodeKey;
@property(nonatomic, readonly) NSNumber* variantKey;
@end

@implementation SPDFPictureSource
- (instancetype)initWithWidth:(size_t)width height:(size_t)height reload:(NSData* _Nullable (^)(void))reload {
    if ((self = [super init])) {
        static std::atomic<unsigned long long> next{0};
        unsigned long long key = ++next;
        _width = width;
        _height = height;
        _reload = [reload copy];
        _decodeKey = @(key * 2);
        _variantKey = @(key * 2 + 1);
    }
    return self;
}
- (void)dealloc {
    [SPDFPictureCache() removeObjectForKey:_decodeKey];
    [SPDFPictureCache() removeObjectForKey:_variantKey];
    [SPDFPictureWholeCache() removeObjectForKey:_decodeKey];
}
@end

static CGFloat SPDFPictureDevicePixels(CGContextRef context, CGSize size, BOOL* screen) {
    CGSize device = CGContextConvertSizeToDeviceSpace(context, size);
    CGFloat side = MAX(fabs(device.width), fabs(device.height));
    // A bitmap (an offscreen page, a thumbnail) or a window counts its own
    // pixels; anything else is print or PDF.
    NSGraphicsContext* current = NSGraphicsContext.currentContext;
    *screen = CGBitmapContextGetWidth(context) > 0 || (current.CGContext == context && current.isDrawingToScreen);
    return *screen ? side : side * SPDFPicturePrintPixelsPerPoint;
}

@interface SPDFMarkdownPictureRep ()
- (nullable CGImageRef)newFullImage;
@end

// A copied picture (the pasteboard, a rich-text copy) is the picture itself at
// its own pixel size; AppKit would otherwise render the rep at the screen's
// scale, twice the picture's size on a Retina screen.
@interface SPDFMarkdownPictureImage : NSImage
@end
@implementation SPDFMarkdownPictureImage
- (NSData*)TIFFRepresentation {
    return [self TIFFRepresentationUsingCompression:NSTIFFCompressionNone factor:0];
}
- (NSData*)TIFFRepresentationUsingCompression:(NSTIFFCompression)compression factor:(float)factor {
    CGImageRef full = [SPDFMarkdownPictureRepForImage(self) newFullImage];
    if (!full) return [super TIFFRepresentationUsingCompression:compression factor:factor];
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithCGImage:full];
    CGImageRelease(full);
    return [bitmap TIFFRepresentationUsingCompression:compression factor:factor];
}
@end

@implementation SPDFMarkdownPictureRep {
    SPDFPictureSource* _source;
}

+ (NSImage*)imageWithBytes:(NSData*)bytes reload:(NSData* _Nullable (^)(void))reload {
    CGImageSourceRef source = bytes.length ? CGImageSourceCreateWithData((__bridge CFDataRef)bytes, NULL) : NULL;
    if (!source) return nil;
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    unsigned long long width = [properties[(NSString*)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    unsigned long long height = [properties[(NSString*)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    if (!width || !height || width > INT32_MAX || height > INT32_MAX) return nil;
    SPDFMarkdownPictureRep* rep = [[SPDFMarkdownPictureRep alloc]
        initWithSource:[[SPDFPictureSource alloc] initWithWidth:(size_t)width height:(size_t)height reload:reload]];
    NSImage* image = [[SPDFMarkdownPictureImage alloc] initWithSize:rep.size];
    image.cacheMode = NSImageCacheNever;  // AppKit's own bitmap cache would hold a full-size decode
    [image addRepresentation:rep];
    return image;
}

- (instancetype)initWithSource:(SPDFPictureSource*)source {
    if ((self = [super init])) {
        _source = source;
        self.size = NSMakeSize(source.width, source.height);
        self.pixelsWide = (NSInteger)source.width;
        self.pixelsHigh = (NSInteger)source.height;
        self.alpha = YES;
        self.opaque = NO;
    }
    return self;
}

- (id)copyWithZone:(NSZone*)zone {
    (void)zone;
    SPDFMarkdownPictureRep* copy = [[SPDFMarkdownPictureRep alloc] initWithSource:_source];
    copy.size = self.size;
    return copy;
}

- (NSUInteger)cachedLongestSide {
    if ([SPDFPictureWholeCache() objectForKey:_source.decodeKey]) return MAX(_source.width, _source.height);
    SPDFPicturePixels* pixels = [SPDFPictureCache() objectForKey:_source.decodeKey];
    return pixels ? MAX(pixels.width, pixels.height) : 0;
}

// For print and PDF: the whole picture as the file has it, decoded only as it
// is drawn (a PDF then embeds a JPEG's own bytes), or a copy `side` pixels
// long, itself a JPEG when the file is one, so a PDF does not hold a photo as
// lossless pixels.
- (nullable CGImageRef)newPrintImageWithLongestSide:(CGFloat)side whole:(BOOL)whole {
    NSData* bytes = _source.reload ? _source.reload() : nil;
    CGImageSourceRef source = bytes.length ? CGImageSourceCreateWithData((__bridge CFDataRef)bytes, NULL) : NULL;
    if (!source) return NULL;
    CFStringRef type = CGImageSourceGetType(source);
    BOOL JPEG = type && CFStringCompare(type, CFSTR("public.jpeg"), 0) == kCFCompareEqualTo;
    CFRelease(source);
    if (whole) return [self newOriginalFromBytes:bytes];
    CGImageRef copy = [self newDecodeWithLongestSide:side];
    if (!copy || !JPEG) return copy;
    NSMutableData* encoded = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)encoded, CFSTR("public.jpeg"), 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, copy,
                                   (__bridge CFDictionaryRef) @{(NSString*)kCGImageDestinationLossyCompressionQuality : @0.9});
        BOOL written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRef recoded = written ? [self newOriginalFromBytes:encoded] : NULL;
        if (recoded) {
            CGImageRelease(copy);
            return recoded;
        }
    }
    return copy;
}

- (nullable CGImageRef)newFullImage {
    if (MAX(_source.width, _source.height) > SPDFMarkdownPictureMaximumDecodedSide)
        return [self newDecodeWithLongestSide:SPDFMarkdownPictureMaximumDecodedSide];
    NSData* bytes = _source.reload ? _source.reload() : nil;
    return bytes ? [self newOriginalFromBytes:bytes] : NULL;
}

- (nullable CGImageRef)newOriginalFromBytes:(NSData*)bytes {
    CGImageSourceRef source = bytes.length ? CGImageSourceCreateWithData((__bridge CFDataRef)bytes, NULL) : NULL;
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    return image;
}

- (nullable CGImageRef)newDecodeWithLongestSide:(CGFloat)side {
    NSData* bytes = _source.reload ? _source.reload() : nil;
    CGImageSourceRef source = bytes.length ? CGImageSourceCreateWithData((__bridge CFDataRef)bytes, NULL) : NULL;
    if (!source) return NULL;
    NSDictionary* options = @{
        (NSString*)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (NSString*)kCGImageSourceThumbnailMaxPixelSize : @(MAX(1.0, side)),
        (NSString*)kCGImageSourceShouldCacheImmediately : @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

// Caches `image` (+1, consumed) as purgeable pixels under `key` and returns
// the image to draw: one over the cached pixels, or `image` itself.
static CGImageRef SPDFPictureKeep(CGImageRef image, NSNumber* key, void* variant) {
    SPDFPicturePixels* pixels = [[SPDFPicturePixels alloc] initCopying:image variant:variant];
    if (!pixels) return image;
    [SPDFPictureCache() setObject:pixels forKey:key cost:pixels.cost];
    CGImageRef kept = [pixels newImage];
    if (!kept) return image;
    CGImageRelease(image);
    return kept;
}

- (CGImageRef)copyImageForContext:(CGContextRef)context
                             size:(CGSize)size
                          variant:(CGImageRef _Nullable (*)(CGImageRef))variant {
    if (!context || size.width <= 0 || size.height <= 0) return NULL;
    NSCache* cache = SPDFPictureCache();
    CGFloat ceiling = MIN((CGFloat)MAX(_source.width, _source.height), (CGFloat)SPDFMarkdownPictureMaximumDecodedSide);
    BOOL screen = YES;
    CGFloat needed = MIN(ceiling, ceil(SPDFPictureDevicePixels(context, size, &screen)));
    if (!screen) {
        // Print and PDF keep what they are handed and draw a page once: no
        // cache, and the file itself when the whole picture is wanted.
        BOOL whole = needed * SPDFPicturePrintWholeFactor >= (CGFloat)MAX(_source.width, _source.height);
        CGImageRef image = [self newPrintImageWithLongestSide:needed whole:whole];
        CGImageRef made = image && variant ? variant(image) : NULL;
        if (!made) return image;
        CGImageRelease(image);
        return made;
    }
    CGFloat side = MIN(ceiling, ceil(needed * SPDFPictureDecodeHeadroom));
    CGFloat full = (CGFloat)MAX(_source.width, _source.height);
    SPDFPictureWhole* whole = [SPDFPictureWholeCache() objectForKey:_source.decodeKey];
    SPDFPicturePixels* pixels = whole ? nil : [cache objectForKey:_source.decodeKey];
    CGImageRef image = whole ? CGImageRetain(whole.image)
                     : pixels && (CGFloat)MAX(pixels.width, pixels.height) >= needed ? [pixels newImage] : NULL;
    if (!image && full <= ceiling && side * SPDFPictureWholeFactor >= full) {
        NSData* bytes = _source.reload ? _source.reload() : nil;
        image = bytes ? [self newOriginalFromBytes:bytes] : NULL;
        if (!image) return NULL;
        [cache removeObjectForKey:_source.decodeKey];
        [cache removeObjectForKey:_source.variantKey];  // made from the decode being replaced
        [SPDFPictureWholeCache() setObject:[[SPDFPictureWhole alloc] initWithImage:image]
                                    forKey:_source.decodeKey
                                      cost:_source.width * _source.height * 4];
    }
    if (!image) {
        [cache removeObjectForKey:_source.variantKey];  // made from the decode being replaced
        CGImageRef decoded = [self newDecodeWithLongestSide:side];
        if (!decoded) return NULL;
        image = SPDFPictureKeep(decoded, _source.decodeKey, NULL);
    }
    if (!variant) return image;
    SPDFPicturePixels* derived = [cache objectForKey:_source.variantKey];
    if (derived && derived.variant == (void*)variant && derived.width == CGImageGetWidth(image) &&
        derived.height == CGImageGetHeight(image)) {
        CGImageRef kept = [derived newImage];
        if (kept) {
            CGImageRelease(image);
            return kept;
        }
    }
    CGImageRef made = variant(image);
    if (!made) return image;
    CGImageRelease(image);
    return SPDFPictureKeep(made, _source.variantKey, (void*)variant);
}

// Plain AppKit drawing (a text view, a pasteboard TIFF) gets the same
// display-size decode for the current context.
- (BOOL)draw {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGRect rect = CGRectMake(0, 0, self.size.width, self.size.height);
    CGImageRef image = context ? [self copyImageForContext:context size:rect.size variant:NULL] : NULL;
    if (!image) return NO;
    CGContextDrawImage(context, rect, image);
    CGImageRelease(image);
    return YES;
}
@end

SPDFMarkdownPictureRep* SPDFMarkdownPictureRepForImage(NSImage* image) {
    for (NSImageRep* rep in image.representations)
        if ([rep isKindOfClass:SPDFMarkdownPictureRep.class]) return (SPDFMarkdownPictureRep*)rep;
    return nil;
}
