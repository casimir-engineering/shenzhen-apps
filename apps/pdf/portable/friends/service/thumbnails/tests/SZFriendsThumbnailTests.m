// Shenzhen Friends thumbnails suite: the QOI codec and PNG writer, fitting and the received-thumbnail checks, the
// maker's timeout and concurrency, and real QuickLook renders of a PDF, Markdown, an image, a text file and an unknown
// binary. Built with AddressSanitizer and UndefinedBehaviorSanitizer. Prints "SZFriendsThumbnailTests passed" and
// exits 0 only when every check passed.

#import "SZFriendsThumbnailTestSupport.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

int SZTFailures = 0;
static NSMutableArray<NSString *> *SZTScratch;

void SZTFail(const char *file, int line, const char *expression, NSString *detail) {
    SZTFailures++;
    fprintf(stderr, "%s:%d: check failed: %s %s\n", file, line, expression, detail.UTF8String);
}

NSData *SZTNoise(NSUInteger width, NSUInteger height, BOOL opaque) {
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    arc4random_buf(data.mutableBytes, data.length);
    uint8_t *bytes = data.mutableBytes;
    if (opaque) {
        for (NSUInteger i = 0; i < width * height; i++) bytes[i * 4 + 3] = 255;
    }
    return data;
}

NSData *SZTGradient(NSUInteger width, NSUInteger height) {
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger y = 0; y < height; y++) {
        for (NSUInteger x = 0; x < width; x++) {
            uint8_t *px = bytes + (y * width + x) * 4;
            px[0] = (uint8_t)(x * 255 / MAX(width - 1, (NSUInteger)1));
            px[1] = (uint8_t)(y * 255 / MAX(height - 1, (NSUInteger)1));
            px[2] = (uint8_t)((x + y) & 0xff);
            px[3] = 255;
        }
    }
    return data;
}

NSData *SZTSolid(NSUInteger width, NSUInteger height, uint32_t rgba) {
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < width * height; i++) {
        bytes[i * 4] = (uint8_t)(rgba >> 24);
        bytes[i * 4 + 1] = (uint8_t)(rgba >> 16);
        bytes[i * 4 + 2] = (uint8_t)(rgba >> 8);
        bytes[i * 4 + 3] = (uint8_t)rgba;
    }
    return data;
}

NSData *SZTDecodePNG(NSData *png, NSUInteger *width, NSUInteger *height) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (source) CFRelease(source);
    if (image == NULL) return nil;
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    NSData *result = nil;
    CFDataRef raw = CGDataProviderCopyData(CGImageGetDataProvider(image));
    // An 8-bit RGBA PNG decodes to unpremultiplied RGBA rows, possibly padded; anything else is a failure here.
    if (raw && CGImageGetBitsPerPixel(image) == 32 && CGImageGetAlphaInfo(image) == kCGImageAlphaLast) {
        NSMutableData *packed = [NSMutableData dataWithLength:w * h * 4];
        size_t stride = CGImageGetBytesPerRow(image);
        for (size_t y = 0; y < h; y++) {
            memcpy((uint8_t *)packed.mutableBytes + y * w * 4, CFDataGetBytePtr(raw) + y * stride, w * 4);
        }
        result = packed;
    }
    if (raw) CFRelease(raw);
    CGImageRelease(image);
    *width = w;
    *height = h;
    return result;
}

NSString *SZTScratchDirectory(void) {
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szft.XXXXXX"];
    char buffer[1024];
    strlcpy(buffer, pattern.fileSystemRepresentation, sizeof buffer);
    NSString *path = mkdtemp(buffer) ? @(buffer) : nil;
    if (path == nil) {
        SZTFail(__FILE__, __LINE__, "mkdtemp", @"");
        return NSTemporaryDirectory();
    }
    [SZTScratch addObject:path];
    return path;
}

void SZTRemoveScratch(void) {
    for (NSString *path in SZTScratch) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [SZTScratch removeAllObjects];
}

int main(void) {
    @autoreleasepool {
        SZTScratch = [NSMutableArray array];
        NSArray *groups = @[
            @[ @"codec", ^{ SZTRunCodecTests(); } ],
            @[ @"thumbnails", ^{ SZTRunThumbnailTests(); } ],
            @[ @"quicklook", ^{ SZTRunRenderTests(); } ],
        ];
        for (NSArray *group in groups) {
            NSDate *start = [NSDate date];
            int before = SZTFailures;
            ((void (^)(void))group[1])();
            printf("  %-12s %5.2f s%s\n", [group[0] UTF8String], -start.timeIntervalSinceNow,
                   SZTFailures == before ? "" : "  FAILED");
        }
        // Removed whether or not a check failed: nothing a run made outlives it.
        SZTRemoveScratch();
        if (SZTFailures != 0) {
            fprintf(stderr, "SZFriendsThumbnailTests: %d check(s) failed\n", SZTFailures);
            return 1;
        }
        printf("SZFriendsThumbnailTests passed\n");
        return 0;
    }
}
