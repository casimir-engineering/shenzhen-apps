// SZFriendsPicturePipeline: a person's own picture in, a friend's picture checked, and both out in one form, a
// 256 x 256 baseline sRGB JPEG with no metadata (SZFriendsAvatars.h).

#import <ImageIO/ImageIO.h>

#import "avatars/SZFriendsAvatarsInternal.h"
#import "avatars/SZFriendsImageBytes.h"

const NSUInteger SZFriendsPictureMaxInputBytes = 5 * 1024 * 1024;
const NSUInteger SZFriendsPictureMaxInputPixels = 8192;
const NSUInteger SZFriendsPictureOutputPixels = 256;
const NSUInteger SZFriendsPictureMaxOutputBytes = 48 * 1024;

// The largest intermediate bitmap: 2048 x 2048 x 4 bytes = 16 MiB. ImageIO decodes every accepted format straight
// to a reduced size, so a 48-megapixel photo never exists at full size in the helper; a tight crop of a huge
// picture is upscaled slightly instead of decoding more.
static const NSUInteger SZFriendsDecodeMaxSide = 2048;
// Decompression bombs: a few kilobytes of PNG can declare 8192 x 8192 pixels (256 MiB decoded). An honest image
// of over 4 megapixels carries at least one byte per 1,024 pixels: a flat-colored 4096 x 4096 PNG screenshot
// carries one per 350, a photo one per 3 to 10. Smaller images are cheap however they are built.
static const double SZFriendsBombMinPixels = 2048.0 * 2048.0;
static const double SZFriendsBombMaxPixelsPerByte = 1024.0;
// Tried in order until the JPEG fits SZFriendsPictureMaxOutputBytes. A photo fits at the first: even pure noise at
// 256 x 256 comes to about 26 KiB at 0.85, so the lower steps are for safety, not expected use.
static const double SZFriendsJPEGQualities[] = {0.85, 0.75, 0.65, 0.55, 0.45, 0.35, 0.25, 0.15};

CGColorSpaceRef SZFriendsPictureSRGB(void) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    return space;
}

// The accepted formats, each with the check that the file reaches its end: ImageIO decodes a truncated file
// without complaint and fills the rest with gray (SZFriendsImageBytes.h).
//
// Formats a person plausibly picks as a profile photo, each of which ImageIO decodes straight to a reduced size
// (measured: an 8192 x 8192 picture peaks at 16 to 121 MB). Everything else ImageIO could decode is refused
// before its decoder runs: fewer parsers, fewer ways in. GIF is refused too because it always decodes at full
// size (330 MB for 8192 x 8192), and TIFF for its many rarely used codecs.
typedef int (*SZFriendsEndCheck)(const uint8_t *bytes, size_t length);

static SZFriendsEndCheck SZFriendsAcceptedFormat(CFStringRef type) {
    NSString *name = (__bridge NSString *)type;
    if ([name isEqualToString:@"public.jpeg"]) return szfriends_jpeg_is_complete;
    if ([name isEqualToString:@"public.png"]) return szfriends_png_is_complete;
    if ([name isEqualToString:@"public.heic"] || [name isEqualToString:@"public.heif"]) {
        return szfriends_bmff_is_complete;
    }
    if ([name isEqualToString:@"org.webmproject.webp"]) return szfriends_webp_is_complete;
    return NULL;
}

static NSUInteger SZFriendsUnsignedProperty(NSDictionary *properties, CFStringRef key) {
    id value = properties[(__bridge NSString *)key];
    if (![value isKindOfClass:[NSNumber class]] || [value doubleValue] < 0) return 0;
    return [value unsignedIntegerValue];
}

typedef struct {
    NSUInteger width, height; // displayed, after the EXIF orientation
} SZFriendsDisplaySize;

// Opens an own picture and checks every limit from its headers, before anything is decoded.
static CGImageSourceRef SZFriendsOpenOwnPicture(NSData *data, SZFriendsDisplaySize *size, NSError **error)
    CF_RETURNS_RETAINED {
    if (data.length == 0) return (SZFriendsPictureFail(error, SZFriendsPictureFailureUnreadable, nil, nil), NULL);
    if (data.length > SZFriendsPictureMaxInputBytes) {
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureTooManyBytes, nil, nil), NULL);
    }
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceShouldCache : @NO};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)options);
    SZFriendsEndCheck reachesEnd = source ? SZFriendsAcceptedFormat(CGImageSourceGetType(source)) : NULL;
    if (!reachesEnd || !reachesEnd(data.bytes, data.length) || CGImageSourceGetCount(source) < 1 ||
        CGImageSourceGetStatus(source) != kCGImageStatusComplete) {
        if (source) CFRelease(source);
        return (SZFriendsPictureFail(error, SZFriendsPictureFailureUnreadable, nil, nil), NULL);
    }
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSUInteger width = SZFriendsUnsignedProperty(properties, kCGImagePropertyPixelWidth);
    NSUInteger height = SZFriendsUnsignedProperty(properties, kCGImagePropertyPixelHeight);
    NSUInteger orientation = SZFriendsUnsignedProperty(properties, kCGImagePropertyOrientation);
    SZFriendsPictureFailure failure = SZFriendsPictureFailureUnreadable;
    BOOL ok = NO;
    if (width == 0 || height == 0) {
        failure = SZFriendsPictureFailureUnreadable;
    } else if (MAX(width, height) > SZFriendsPictureMaxInputPixels) {
        failure = SZFriendsPictureFailureTooManyPixels;
    } else if ((double)width * height > SZFriendsBombMinPixels &&
               (double)width * height > (double)data.length * SZFriendsBombMaxPixelsPerByte) {
        failure = SZFriendsPictureFailureBomb;
    } else {
        ok = YES;
    }
    if (!ok) {
        CFRelease(source);
        return (SZFriendsPictureFail(error, failure, nil, nil), NULL);
    }
    // Orientations 5 to 8 turn the picture a quarter, so the person sees it with width and height swapped.
    BOOL quarterTurn = orientation >= 5 && orientation <= 8;
    size->width = quarterTurn ? height : width;
    size->height = quarterTurn ? width : height;
    return source;
}

// The crop square in displayed pixels, whole numbers. NSZeroRect: the centered largest square.
static BOOL SZFriendsResolveCrop(NSRect crop, SZFriendsDisplaySize size, CGRect *square, NSError **error) {
    if (NSEqualRects(crop, NSZeroRect)) {
        NSUInteger side = MIN(size.width, size.height);
        *square = CGRectMake((size.width - side) / 2, (size.height - side) / 2, side, side);
        return YES;
    }
    double x = round(crop.origin.x), y = round(crop.origin.y), side = round(crop.size.width);
    if (!isfinite(x) || !isfinite(y) || !isfinite(side) || round(crop.size.height) != side || side < 1 || x < 0 ||
        y < 0 || x + side > size.width || y + side > size.height) {
        return SZFriendsPictureFail(error, SZFriendsPictureFailureCropOffImage, nil, nil);
    }
    *square = CGRectMake(x, y, side, side);
    return YES;
}

CGImageRef SZFriendsPictureCreateSquare(CGImageRef image) {
    size_t side = SZFriendsPictureOutputPixels;
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, SZFriendsPictureSRGB(),
                                                 (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    if (!context) return NULL;
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, side, side));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), image);
    CGImageRef square = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return square;
}

static NSData *SZFriendsEncodeOnce(CGImageRef image, double quality) {
    NSMutableData *encoded = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)encoded, CFSTR("public.jpeg"), 1, NULL);
    if (!destination) return nil;
    NSDictionary *properties = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality)};
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (!ok) return nil;
    // ImageIO adds EXIF and Photoshop segments even for a bare bitmap. They hold nothing personal here, but
    // stripping them makes "no metadata" exact and checkable, and saves bytes in the session frame.
    NSMutableData *stripped = [NSMutableData dataWithLength:encoded.length];
    size_t length = szfriends_jpeg_strip_metadata(encoded.bytes, encoded.length, stripped.mutableBytes);
    if (length == 0) return nil;
    stripped.length = length;
    return stripped;
}

NSData *SZFriendsPictureEncodeJPEG(CGImageRef image, NSError **error) {
    for (size_t i = 0; i < sizeof SZFriendsJPEGQualities / sizeof SZFriendsJPEGQualities[0]; i++) {
        NSData *encoded = SZFriendsEncodeOnce(image, SZFriendsJPEGQualities[i]);
        if (!encoded) break;
        if (encoded.length <= SZFriendsPictureMaxOutputBytes) return encoded;
    }
    return (SZFriendsPictureFail(error, SZFriendsPictureFailureEncode, nil, nil), nil);
}

// Decodes no more pixels than the crop needs at 256 x 256, capped at SZFriendsDecodeMaxSide, with the EXIF
// orientation applied, then cuts out the square.
static CGImageRef SZFriendsCreateCroppedImage(CGImageSourceRef source, SZFriendsDisplaySize size, CGRect square)
    CF_RETURNS_RETAINED {
    NSUInteger longest = MAX(size.width, size.height);
    double needed = ceil((double)longest * SZFriendsPictureOutputPixels / square.size.width);
    NSUInteger decodeSide = (NSUInteger)MIN((double)longest, MIN(MAX(needed, SZFriendsPictureOutputPixels),
                                                                  (double)SZFriendsDecodeMaxSide));
    NSDictionary *options = @{
        // Never the embedded EXIF thumbnail: it can be stale and show the photo before it was edited or cropped.
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @(decodeSide),
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
    };
    CGImageRef decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    if (!decoded) return NULL;
    double scaleX = (double)CGImageGetWidth(decoded) / size.width;
    double scaleY = (double)CGImageGetHeight(decoded) / size.height;
    double x = floor(square.origin.x * scaleX), y = floor(square.origin.y * scaleY);
    double side = MAX(1.0, round(square.size.width * MIN(scaleX, scaleY)));
    side = MIN(side, MIN(CGImageGetWidth(decoded) - x, CGImageGetHeight(decoded) - y));
    CGImageRef cropped = side >= 1 ? CGImageCreateWithImageInRect(decoded, CGRectMake(x, y, side, side)) : NULL;
    CGImageRelease(decoded);
    return cropped;
}

// A friend's picture, decoded only after its markers show a small baseline JPEG of exactly 256 x 256.
static CGImageRef SZFriendsCreateReceivedImage(NSData *data, NSError **error) CF_RETURNS_RETAINED {
    szfriends_jpeg_info info;
    BOOL ok = data.length > 0 && data.length <= SZFriendsPictureMaxOutputBytes &&
              szfriends_jpeg_read_header(data.bytes, data.length, &info) == 0 && info.frame_count == 1 &&
              (info.sof_marker == 0xC0 || info.sof_marker == 0xC1) && info.precision == 8 &&
              info.width == SZFriendsPictureOutputPixels && info.height == SZFriendsPictureOutputPixels &&
              (info.components == 1 || info.components == 3) && szfriends_jpeg_is_complete(data.bytes, data.length);
    // Progressive and arithmetic-coded files are refused above: this encoder never writes them, and a
    // progressive file with thousands of scans is the classic way to make a tiny JPEG cost seconds to decode.
    if (!ok) return (SZFriendsPictureFail(error, SZFriendsPictureFailureReceivedInvalid, nil, nil), NULL);
    NSDictionary *sourceOptions = @{(__bridge NSString *)kCGImageSourceShouldCache : @NO};
    CGImageSourceRef source =
        CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)sourceOptions);
    CGImageRef image = NULL;
    if (source && CGImageSourceGetType(source) && CFEqual(CGImageSourceGetType(source), CFSTR("public.jpeg")) &&
        CGImageSourceGetCount(source) == 1 && CGImageSourceGetStatus(source) == kCGImageStatusComplete) {
        NSDictionary *options = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @(SZFriendsPictureOutputPixels),
            (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
        };
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    }
    if (source) CFRelease(source);
    if (image && (CGImageGetWidth(image) != SZFriendsPictureOutputPixels ||
                  CGImageGetHeight(image) != SZFriendsPictureOutputPixels)) {
        CGImageRelease(image);
        image = NULL;
    }
    if (!image) SZFriendsPictureFail(error, SZFriendsPictureFailureReceivedInvalid, nil, nil);
    return image;
}

static NSData *SZFriendsNormalizeOwnPicture(NSData *data, NSRect crop, NSError **error) {
    SZFriendsDisplaySize size = {0, 0};
    CGImageSourceRef source = SZFriendsOpenOwnPicture(data, &size, error);
    if (!source) return nil;
    CGRect square;
    if (!SZFriendsResolveCrop(crop, size, &square, error)) {
        CFRelease(source);
        return nil;
    }
    CGImageRef cropped = SZFriendsCreateCroppedImage(source, size, square);
    CFRelease(source);
    if (!cropped) return (SZFriendsPictureFail(error, SZFriendsPictureFailureUnreadable, nil, nil), nil);
    CGImageRef output = SZFriendsPictureCreateSquare(cropped);
    CGImageRelease(cropped);
    if (!output) return (SZFriendsPictureFail(error, SZFriendsPictureFailureEncode, nil, nil), nil);
    NSData *jpeg = SZFriendsPictureEncodeJPEG(output, error);
    CGImageRelease(output);
    return jpeg;
}

static NSData *SZFriendsNormalizeReceivedPicture(NSData *data, NSError **error) {
    CGImageRef image = SZFriendsCreateReceivedImage(data, error);
    if (!image) return nil;
    CGImageRef output = SZFriendsPictureCreateSquare(image);
    CGImageRelease(image);
    if (!output) return (SZFriendsPictureFail(error, SZFriendsPictureFailureEncode, nil, nil), nil);
    NSData *jpeg = SZFriendsPictureEncodeJPEG(output, error);
    CGImageRelease(output);
    return jpeg;
}

@implementation SZFriendsPicturePipeline

// Each public entry drains its own autorelease pool, so ImageIO's temporaries never pile up in a helper that
// processes pictures from a long-running loop. The error goes through a strong local: one autoreleased inside the
// pool would be freed when it drains, leaving the caller's pointer dangling (the suite crashed on exactly that).
+ (NSData *)normalizedImageFromData:(NSData *)data crop:(NSRect)crop error:(NSError **)error {
    NSError *failure = nil;
    NSData *jpeg = nil;
    @autoreleasepool {
        jpeg = SZFriendsNormalizeOwnPicture(data, crop, &failure);
    }
    if (!jpeg && error) *error = failure;
    return jpeg;
}

+ (BOOL)validateReceivedImage:(NSData *)data error:(NSError **)error {
    NSError *failure = nil;
    CGImageRef image = NULL;
    @autoreleasepool {
        image = SZFriendsCreateReceivedImage(data, &failure);
    }
    if (!image) {
        if (error) *error = failure;
        return NO;
    }
    CGImageRelease(image);
    return YES;
}

+ (NSData *)normalizedReceivedImage:(NSData *)data error:(NSError **)error {
    NSError *failure = nil;
    NSData *jpeg = nil;
    @autoreleasepool {
        jpeg = SZFriendsNormalizeReceivedPicture(data, &failure);
    }
    if (!jpeg && error) *error = failure;
    return jpeg;
}

+ (SZFriendsPicture *)storeImage:(NSData *)jpeg inDirectory:(NSString *)directory error:(NSError **)error {
    return SZFriendsPictureStore(jpeg, directory, error);
}

+ (SZFriendsPicture *)pictureFromIntentPicture:(id)picture
                                     animalSet:(SZFriendsAnimalSet *)set
                             picturesDirectory:(NSString *)directory
                                         error:(NSError **)error {
    return SZFriendsPictureFromIntent(picture, set, directory, error);
}

@end
