#import "SPDFMarkdownVectorPicture.h"

#import "SPDFMarkdownResources.h"

#import <objc/runtime.h>
#import <os/lock.h>

#include <time.h>

// A page whose vector draw took longer than this is drawn on screen from a
// bitmap: a chart of a few thousand paths draws in a few milliseconds, a
// scatter of 60,000 points in half a second, which every scroll would repeat.
static const double SPDFVectorSlowDrawSeconds = 0.012;
// A bitmap covers a little more than the draw that made it, so the small steps
// of a zoom reuse it; it is never made past SPDFVectorBitmapMaximumSide a side.
static const CGFloat SPDFVectorBitmapHeadroom = 1.25;
static const CGFloat SPDFVectorBitmapMaximumSide = 8192;
static const NSUInteger SPDFVectorBitmapCacheBytes = 256 * 1024 * 1024;

static NSCache* SPDFVectorBitmaps(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      cache = [NSCache new];
      cache.name = @"Markdown vector pictures, as bitmaps";
      cache.totalCostLimit = SPDFVectorBitmapCacheBytes;
    });
    return cache;
}

@interface SPDFVectorBitmap : NSObject
@property(nonatomic, readonly) CGImageRef image;
@end
@implementation SPDFVectorBitmap
- (instancetype)initWithImage:(CGImageRef)image {
    if ((self = [super init])) _image = CGImageRetain(image);
    return self;
}
- (void)dealloc {
    CGImageRelease(_image);
}
@end

static CGPDFDocumentRef SPDFOpenVectorPDF(NSData* data) {
    CGDataProviderRef provider = data.length ? CGDataProviderCreateWithCFData((__bridge CFDataRef)data) : NULL;
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGDataProviderRelease(provider);
    return document;
}

// A vector picture's pages, opened once per rep: the light one from the rep's
// own PDF, the dark one from the installed recolourer the first time the dark
// theme draws the picture. Also how long a vector draw of it takes, and the
// keys of its bitmaps.
@interface SPDFVectorPicturePages : NSObject
@property(nonatomic, readonly) NSObject* lightKey;
@property(nonatomic, readonly) NSObject* darkKey;
@end

@implementation SPDFVectorPicturePages {
    os_unfair_lock _lock;
    CGPDFDocumentRef _light;
    CGPDFDocumentRef _dark;
    BOOL _openedLight;
    BOOL _openedDark;
    double _slowestDraw;
}
- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _lightKey = [NSObject new];
        _darkKey = [NSObject new];
    }
    return self;
}
- (void)dealloc {
    [SPDFVectorBitmaps() removeObjectForKey:_lightKey];
    [SPDFVectorBitmaps() removeObjectForKey:_darkKey];
    CGPDFDocumentRelease(_light);
    CGPDFDocumentRelease(_dark);
}
- (CGPDFDocumentRef)documentForRep:(NSPDFImageRep*)rep dark:(BOOL)dark {
    os_unfair_lock_lock(&_lock);
    if (!_openedLight) {
        _openedLight = YES;
        _light = SPDFOpenVectorPDF(rep.PDFRepresentation);
    }
    if (dark && !_openedDark) {
        _openedDark = YES;
        SPDFMarkdownVectorRecolorer recolor = SPDFMarkdownInstalledVectorRecolorer();
        _dark = recolor && _light ? SPDFOpenVectorPDF(recolor(rep.PDFRepresentation)) : NULL;
    }
    CGPDFDocumentRef document = dark ? _dark : _light;
    os_unfair_lock_unlock(&_lock);
    return document;
}
- (BOOL)drawsSlowly {
    os_unfair_lock_lock(&_lock);
    BOOL slow = _slowestDraw > SPDFVectorSlowDrawSeconds;
    os_unfair_lock_unlock(&_lock);
    return slow;
}
- (void)noteDrawSeconds:(double)seconds {
    os_unfair_lock_lock(&_lock);
    _slowestDraw = MAX(_slowestDraw, seconds);
    os_unfair_lock_unlock(&_lock);
}
@end

static void SPDFDrawVectorPage(CGPDFPageRef page, CGContextRef context, CGRect destination) {
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
    BOOL turned = (CGPDFPageGetRotationAngle(page) / 90) % 2 != 0;
    CGSize shown = turned ? CGSizeMake(box.size.height, box.size.width) : box.size;
    if (shown.width <= 0 || shown.height <= 0) return;
    CGContextSaveGState(context);
    CGContextClipToRect(context, destination);
    CGContextTranslateCTM(context, destination.origin.x, destination.origin.y);
    CGContextScaleCTM(context, destination.size.width / shown.width, destination.size.height / shown.height);
    // At the page's own size the transform only places and turns the page.
    CGContextConcatCTM(context, CGPDFPageGetDrawingTransform(page, kCGPDFCropBox,
                                                             CGRectMake(0, 0, shown.width, shown.height), 0, true));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawPDFPage(context, page);
    CGContextRestoreGState(context);
}

// The page as a bitmap at least `pixels` large (up to the maximum side): the
// one kept when it is large enough, else a new one with some headroom.
static CGImageRef SPDFCopyVectorBitmap(SPDFVectorPicturePages* pages, CGPDFPageRef page, BOOL dark, CGSize pixels) {
    NSObject* key = dark ? pages.darkKey : pages.lightKey;
    CGFloat longest = MAX(pixels.width, pixels.height);
    if (longest < 1) return NULL;
    CGFloat wanted = MIN(ceil(longest), SPDFVectorBitmapMaximumSide);
    SPDFVectorBitmap* kept = [SPDFVectorBitmaps() objectForKey:key];
    if (kept && MAX(CGImageGetWidth(kept.image), CGImageGetHeight(kept.image)) >= wanted)
        return CGImageRetain(kept.image);
    CGFloat scale = MIN(SPDFVectorBitmapHeadroom, SPDFVectorBitmapMaximumSide / longest);
    size_t width = (size_t)MAX(1.0, ceil(pixels.width * scale));
    size_t height = (size_t)MAX(1.0, ceil(pixels.height * scale));
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!bitmap) return NULL;
    SPDFDrawVectorPage(page, bitmap, CGRectMake(0, 0, width, height));
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    if (image)
        [SPDFVectorBitmaps() setObject:[[SPDFVectorBitmap alloc] initWithImage:image] forKey:key cost:width * height * 4];
    return image;
}

BOOL SPDFMarkdownDrawVectorPicture(NSImage* image, CGContextRef context, CGRect destination, BOOL dark) {
    static const void* key = &key;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSPDFImageRep* rep = nil;
    for (NSImageRep* candidate in image.representations)
        if ([candidate isKindOfClass:NSPDFImageRep.class]) rep = (NSPDFImageRep*)candidate;
    if (!rep || !context) return NO;
    os_unfair_lock_lock(&lock);
    SPDFVectorPicturePages* pages = objc_getAssociatedObject(rep, key);
    if (!pages) {
        pages = [SPDFVectorPicturePages new];
        objc_setAssociatedObject(rep, key, pages, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
    CGPDFDocumentRef document = [pages documentForRep:rep dark:dark];
    CGPDFPageRef page = document ? CGPDFDocumentGetPage(document, (size_t)MAX(rep.currentPage, 0) + 1) : NULL;
    if (!page) return NO;
    // A bitmap (a page canvas tile, the map, a thumbnail) or a window has pixels
    // of its own; print and PDF export do not, and always get the vectors.
    NSGraphicsContext* current = NSGraphicsContext.currentContext;
    BOOL screen = CGBitmapContextGetWidth(context) > 0 || (current.CGContext == context && current.isDrawingToScreen);
    if (screen && pages.drawsSlowly) {
        CGSize device = CGContextConvertSizeToDeviceSpace(context, destination.size);
        CGImageRef bitmap = SPDFCopyVectorBitmap(pages, page, dark, CGSizeMake(fabs(device.width), fabs(device.height)));
        if (bitmap) {
            CGContextSaveGState(context);
            CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
            CGContextDrawImage(context, destination, bitmap);
            CGContextRestoreGState(context);
            CGImageRelease(bitmap);
            return YES;
        }
    }
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    SPDFDrawVectorPage(page, context, destination);
    if (screen) [pages noteDrawSeconds:(double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9];
    return YES;
}
