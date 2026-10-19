// Making thumbnails without holding anyone up: QuickLook renders off the helper's queue, two at a time, and a render
// that has not finished within the timeout counts as no thumbnail (SZFriendsThumbnails.h).

#import "service/thumbnails/SZFriendsThumbnails.h"

#import <CoreGraphics/CoreGraphics.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// QuickLook's picture as straight-alpha RGBA, fitted to `maxSide`. CoreGraphics draws premultiplied, so the colour of
// each translucent pixel is divided back out.
static SZFriendsThumbnailPixels *_Nullable SZFriendsPixelsFromImage(CGImageRef image, NSUInteger maxSide) {
    size_t sourceWidth = CGImageGetWidth(image), sourceHeight = CGImageGetHeight(image);
    if (sourceWidth == 0 || sourceHeight == 0) return nil;
    size_t longer = MAX(sourceWidth, sourceHeight);
    size_t width = sourceWidth, height = sourceHeight;
    if (longer > maxSide) {
        width = MAX((size_t)1, (sourceWidth * maxSide + longer / 2) / longer);
        height = MAX((size_t)1, (sourceHeight * maxSide + longer / 2) / longer);
    }
    NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(rgba.mutableBytes, width, height, 8, width * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    uint8_t *bytes = rgba.mutableBytes;
    for (size_t i = 0; i < width * height; i++) {
        uint8_t *px = bytes + i * 4;
        if (px[3] == 0 || px[3] == 255) continue;
        for (int c = 0; c < 3; c++) px[c] = (uint8_t)MIN(255u, ((unsigned)px[c] * 255u + px[3] / 2u) / px[3]);
    }
    return [[SZFriendsThumbnailPixels alloc] initWithRGBA:rgba width:width height:height];
}

@implementation SZFriendsQuickLookRenderer

- (nullable dispatch_block_t)renderFileAtPath:(NSString *)path
                               typeIdentifier:(nullable NSString *)typeIdentifier
                                      maxSide:(NSUInteger)maxSide
                                   completion:(void (^)(SZFriendsThumbnailPixels *_Nullable pixels))completion {
    // Scale 1: the size is in pixels, the same on every Mac, because the picture is sent to someone else's screen.
    // Thumbnail only: QuickLook's icon for a format it cannot draw would be a picture of the type, not the file, and
    // the recipient's views draw the type icon themselves.
    QLThumbnailGenerationRequestRepresentationTypes types = QLThumbnailGenerationRequestRepresentationTypeThumbnail;
    QLThumbnailGenerationRequest *request =
        [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:[NSURL fileURLWithPath:path]
                                                           size:CGSizeMake(maxSide, maxSide)
                                                          scale:1
                                            representationTypes:types];
    UTType *type = typeIdentifier.length ? [UTType typeWithIdentifier:typeIdentifier] : nil;
    if (type != nil) request.contentType = type;
    [QLThumbnailGenerator.sharedGenerator
        generateBestRepresentationForRequest:request
                           completionHandler:^(QLThumbnailRepresentation *representation, NSError *error) {
                               (void)error;
                               CGImageRef image = representation.CGImage;
                               completion(image ? SZFriendsPixelsFromImage(image, maxSide) : nil);
                           }];
    // Security review: a 1 GiB sparse PDF or a page of two million operators kept QuickLook busy after the helper had
    // stopped waiting. Cancelled, the request ends; its completion, reporting the cancellation, comes after the nil.
    return ^{
      [QLThumbnailGenerator.sharedGenerator cancelRequest:request];
    };
}

@end

@implementation SZFriendsThumbnailMaker {
    id<SZFriendsThumbnailRenderer> _renderer;
    NSTimeInterval _timeout;
    NSOperationQueue *_operations;
}

- (instancetype)initWithRenderer:(id<SZFriendsThumbnailRenderer>)renderer timeout:(NSTimeInterval)timeout {
    if ((self = [super init])) {
        _renderer = renderer;
        _timeout = timeout;
        _operations = [[NSOperationQueue alloc] init];
        // Two at a time: a drop of many files must not start a hundred renders whose two-second clocks all run while
        // QuickLook works through them, and the helper's own queue never waits on any of them.
        _operations.maxConcurrentOperationCount = 2;
        _operations.qualityOfService = NSQualityOfServiceUtility;
        _operations.name = @"Shenzhen Friends thumbnails";
    }
    return self;
}

- (instancetype)init {
    return [self initWithRenderer:[[SZFriendsQuickLookRenderer alloc] init] timeout:SZFriendsThumbnailRenderTimeout];
}

- (void)makeThumbnailOfFileAtPath:(NSString *)path
                   typeIdentifier:(nullable NSString *)typeIdentifier
                            queue:(dispatch_queue_t)queue
                       completion:(void (^)(SZFriendsThumbnail *_Nullable thumbnail))completion {
    id<SZFriendsThumbnailRenderer> renderer = _renderer;
    NSTimeInterval timeout = _timeout;
    [_operations addOperationWithBlock:^{
        // The clock starts when this render starts, not when it was queued behind others.
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block SZFriendsThumbnailPixels *result = nil;
        NSLock *lock = [[NSLock alloc] init];
        __block BOOL expired = NO;
        dispatch_block_t stop = [renderer renderFileAtPath:path
                                            typeIdentifier:typeIdentifier
                                                   maxSide:SZFriendsThumbnailMaxSide
                                                completion:^(SZFriendsThumbnailPixels *pixels) {
                                                    [lock lock];
                                                    if (!expired) result = pixels;
                                                    [lock unlock];
                                                    dispatch_semaphore_signal(done);
                                                }];
        dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
        long waited = dispatch_semaphore_wait(done, deadline);
        [lock lock];
        expired = waited != 0;
        SZFriendsThumbnailPixels *pixels = expired ? nil : result;
        [lock unlock];
        // Nobody waits for it any more: the renderer stops rather than work on for nothing.
        if (expired && stop) stop();
        SZFriendsThumbnail *thumbnail = pixels ? SZFriendsThumbnailFromPixels(pixels) : nil;
        dispatch_async(queue, ^{ completion(thumbnail); });
    }];
}

@end
