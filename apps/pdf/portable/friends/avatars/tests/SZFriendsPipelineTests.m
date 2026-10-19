// Own pictures through SZFriendsPicturePipeline: output shape, crop, orientation, metadata, determinism, limits.

#import "SZFriendsAvatarsTestSupport.h"

static NSDictionary *SZTestQuality(double quality) {
    return @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality)};
}

// What every output must be: a 256 x 256 baseline JPEG within 48 KiB, carrying no metadata segment or dictionary.
void SZTestCheckOutputShape(NSString *what, NSData *jpeg);
void SZTestCheckOutputShape(NSString *what, NSData *jpeg) {
    SZ_CHECK(jpeg.length > 0 && jpeg.length <= SZFriendsPictureMaxOutputBytes, @"%@: %lu bytes", what,
             (unsigned long)jpeg.length);
    if (jpeg.length == 0) return;
    NSError *error = nil;
    SZ_CHECK([SZFriendsPicturePipeline validateReceivedImage:jpeg error:&error], @"%@: a friend would refuse it: %@",
             what, error.localizedDescription);
    for (NSNumber *marker in SZTestJPEGMarkers(jpeg)) {
        uint8_t m = marker.unsignedCharValue;
        SZ_CHECK(!((m >= 0xE1 && m <= 0xEF) || m == 0xFE), @"%@: metadata segment %#x", what, m);
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
    if (source) CFRelease(source);
    SZ_CHECK([properties[(__bridge NSString *)kCGImagePropertyPixelWidth] integerValue] == 256 &&
                 [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] integerValue] == 256,
             @"%@: %@", what, properties);
    for (NSString *key in @[ (__bridge NSString *)kCGImagePropertyGPSDictionary,
                             (__bridge NSString *)kCGImagePropertyExifDictionary,
                             (__bridge NSString *)kCGImagePropertyTIFFDictionary,
                             (__bridge NSString *)kCGImagePropertyIPTCDictionary ]) {
        SZ_CHECK(properties[key] == nil, @"%@: output carries %@", what, key);
    }
}

static void SZTestCheckQuadrants(NSString *what, NSData *jpeg, const int colors[4][3]) {
    const size_t points[4][2] = {{64, 64}, {192, 64}, {64, 192}, {192, 192}};
    for (int i = 0; i < 4; i++) {
        int rgb[3] = {0};
        BOOL ok = SZTestPixel(jpeg, points[i][0], points[i][1], rgb);
        SZ_CHECK(ok && SZTestNear(rgb, colors[i][0], colors[i][1], colors[i][2], 40), @"%@: point %d is %d,%d,%d",
                 what, i, rgb[0], rgb[1], rgb[2]);
    }
}

static void SZTestShapeMetadataDeterminism(void) {
    CGImageRef image = SZTestCreateQuadrants(640, 480);
    NSMutableDictionary *withMetadata = [SZTestQuality(0.95) mutableCopy];
    withMetadata[(__bridge NSString *)kCGImagePropertyExifDictionary] = @{
        (__bridge NSString *)kCGImagePropertyExifUserComment : @"SZFRIENDS-SECRET-COMMENT",
        (__bridge NSString *)kCGImagePropertyExifDateTimeOriginal : @"2026:10:12 14:47:48",
    };
    withMetadata[(__bridge NSString *)kCGImagePropertyGPSDictionary] = @{
        (__bridge NSString *)kCGImagePropertyGPSLatitude : @22.5431,
        (__bridge NSString *)kCGImagePropertyGPSLatitudeRef : @"N",
        (__bridge NSString *)kCGImagePropertyGPSLongitude : @114.0579,
        (__bridge NSString *)kCGImagePropertyGPSLongitudeRef : @"E",
    };
    withMetadata[(__bridge NSString *)kCGImagePropertyTIFFDictionary] =
        @{(__bridge NSString *)kCGImagePropertyTIFFMake : @"SZFriendsCam",
          (__bridge NSString *)kCGImagePropertyTIFFModel : @"X1"};
    NSData *tagged = SZTestEncode(image, @"public.jpeg", withMetadata);
    NSData *plain = SZTestEncode(image, @"public.jpeg", SZTestQuality(0.95));
    CGImageRelease(image);
    SZ_CHECK(SZTestContains(tagged, @"SZFriendsCam"), @"the test input must really carry metadata");

    NSError *error = nil;
    NSData *output = [SZFriendsPicturePipeline normalizedImageFromData:tagged crop:NSZeroRect error:&error];
    SZ_CHECK(output != nil, @"640 x 480 JPEG: %@", error.localizedDescription);
    SZTestCheckOutputShape(@"JPEG with metadata", output);
    for (NSString *planted in @[ @"SZFRIENDS-SECRET", @"SZFriendsCam", @"2026:10:12" ]) {
        SZ_CHECK(!SZTestContains(output, planted), @"%@ reached the output", planted);
    }
    // The centered square of a 640 x 480 picture keeps all four quadrants in place.
    const int quadrants[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 0}};
    SZTestCheckQuadrants(@"center crop", output, quadrants);
    // Deterministic, and metadata cannot change a single output byte.
    NSData *again = [SZFriendsPicturePipeline normalizedImageFromData:tagged crop:NSZeroRect error:NULL];
    NSData *fromPlain = [SZFriendsPicturePipeline normalizedImageFromData:plain crop:NSZeroRect error:NULL];
    SZ_CHECK([again isEqualToData:output], @"same input, different output");
    SZ_CHECK([fromPlain isEqualToData:output], @"metadata changed the output");

    NSData *topLeft = [SZFriendsPicturePipeline normalizedImageFromData:plain crop:NSMakeRect(0, 0, 240, 240)
                                                                  error:NULL];
    const int allRed[4][3] = {{255, 0, 0}, {255, 0, 0}, {255, 0, 0}, {255, 0, 0}};
    SZTestCheckQuadrants(@"crop at the top left, origin top left", topLeft, allRed);
    NSData *bottomRight = [SZFriendsPicturePipeline normalizedImageFromData:plain crop:NSMakeRect(320, 240, 240, 240)
                                                                      error:NULL];
    const int allYellow[4][3] = {{255, 255, 0}, {255, 255, 0}, {255, 255, 0}, {255, 255, 0}};
    SZTestCheckQuadrants(@"crop at the bottom right", bottomRight, allYellow);
}

static void SZTestOrientation(void) {
    // Stored 200 x 100 with EXIF orientation 6 (turn a quarter clockwise to view): people see it 100 x 200, with
    // blue top left, red top right, yellow bottom left, green bottom right. The same picture drawn upright needs
    // no orientation; both must come out alike, and crops count in what people see.
    CGImageRef stored = SZTestCreateQuadrants(200, 100);
    NSMutableDictionary *turned = [SZTestQuality(1.0) mutableCopy];
    turned[(__bridge NSString *)kCGImagePropertyOrientation] = @6;
    NSData *rotated = SZTestEncode(stored, @"public.jpeg", turned);
    CGImageRelease(stored);
    CGImageRef upright = SZTestCreateImage(100, 200, ^(CGContextRef context) {
        CGContextSetRGBFillColor(context, 0, 0, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 100, 50, 100));
        CGContextSetRGBFillColor(context, 1, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(50, 100, 50, 100));
        CGContextSetRGBFillColor(context, 1, 1, 0, 1);
        CGContextFillRect(context, CGRectMake(0, 0, 50, 100));
        CGContextSetRGBFillColor(context, 0, 1, 0, 1);
        CGContextFillRect(context, CGRectMake(50, 0, 50, 100));
    });
    NSData *drawn = SZTestEncode(upright, @"public.jpeg", SZTestQuality(1.0));
    CGImageRelease(upright);
    for (NSData *input in @[ rotated, drawn ]) {
        NSString *what = input == rotated ? @"orientation 6" : @"drawn upright";
        NSData *center = [SZFriendsPicturePipeline normalizedImageFromData:input crop:NSZeroRect error:NULL];
        const int centerColors[4][3] = {{0, 0, 255}, {255, 0, 0}, {255, 255, 0}, {0, 255, 0}};
        SZTestCheckQuadrants([what stringByAppendingString:@", center"], center, centerColors);
        NSData *top = [SZFriendsPicturePipeline normalizedImageFromData:input crop:NSMakeRect(0, 0, 100, 100)
                                                                  error:NULL];
        const int topColors[4][3] = {{0, 0, 255}, {255, 0, 0}, {0, 0, 255}, {255, 0, 0}};
        SZTestCheckQuadrants([what stringByAppendingString:@", top square"], top, topColors);
        NSError *error = nil;
        SZ_CHECK(![SZFriendsPicturePipeline normalizedImageFromData:input crop:NSMakeRect(100, 0, 100, 100)
                                                              error:&error] &&
                     [SZTestProtocolCode(error) isEqual:@"invalid_field"],
                 @"%@: a crop inside the stored pixels but outside what people see must fail", what);
    }
}

static void SZTestFormats(void) {
    CGImageRef image = SZTestCreateQuadrants(512, 512);
    NSData *heic = SZTestEncode(image, @"public.heic", SZTestQuality(0.9));
    SZ_CHECK(heic.length > 0, @"this Mac could not write HEIC for the test");
    NSData *fromHEIC = [SZFriendsPicturePipeline normalizedImageFromData:heic crop:NSZeroRect error:NULL];
    SZTestCheckOutputShape(@"HEIC", fromHEIC);
    const int quadrants[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 0}};
    SZTestCheckQuadrants(@"HEIC", fromHEIC, quadrants);
    NSData *webp = [NSData dataWithBytes:SZTestWebP length:sizeof SZTestWebP];
    NSData *fromWebP = [SZFriendsPicturePipeline normalizedImageFromData:webp crop:NSZeroRect error:NULL];
    SZTestCheckOutputShape(@"WebP", fromWebP);
    SZTestCheckQuadrants(@"WebP", fromWebP, quadrants);
    // GIF and TIFF decode at full size or bring many codecs, and AVIF (a box format like HEIC) is not offered on
    // every supported macOS; all are refused before decoding.
    for (NSString *type in @[ @"com.compuserve.gif", @"public.tiff", @"public.avif" ]) {
        NSError *error = nil;
        NSData *data = SZTestEncode(image, type, nil);
        NSData *output = [SZFriendsPicturePipeline normalizedImageFromData:data crop:NSZeroRect error:&error];
        SZ_CHECK(data.length > 0 && !output && error.code == SZFriendsPictureErrorUnreadable &&
                     [SZTestProtocolCode(error) isEqual:@"picture_invalid"],
                 @"%@ must be refused", type);
    }
    CGImageRelease(image);

    // Transparent areas come out white, the same in every app and appearance.
    CGImageRef badge = SZTestCreateImage(300, 300, ^(CGContextRef context) {
        CGContextClearRect(context, CGRectMake(0, 0, 300, 300));
        CGContextSetRGBFillColor(context, 1, 0, 0, 1);
        CGContextFillEllipseInRect(context, CGRectMake(100, 100, 100, 100));
    });
    NSData *png = SZTestEncode(badge, @"public.png", nil);
    CGImageRelease(badge);
    NSData *fromPNG = [SZFriendsPicturePipeline normalizedImageFromData:png crop:NSZeroRect error:NULL];
    SZTestCheckOutputShape(@"transparent PNG", fromPNG);
    int rgb[3];
    SZ_CHECK(SZTestPixel(fromPNG, 6, 6, rgb) && SZTestNear(rgb, 255, 255, 255, 12), @"corner %d,%d,%d", rgb[0], rgb[1],
             rgb[2]);
    SZ_CHECK(SZTestPixel(fromPNG, 128, 128, rgb) && SZTestNear(rgb, 255, 0, 0, 40), @"center %d,%d,%d", rgb[0], rgb[1],
             rgb[2]);

    // Pure noise is the hardest case for the 48 KiB budget; a fixed generator keeps the test reproducible.
    __block uint32_t state = 12345;
    CGImageRef noise = SZTestCreateImage(512, 512, ^(CGContextRef context) {
        uint8_t *pixels = CGBitmapContextGetData(context);
        size_t count = CGBitmapContextGetBytesPerRow(context) * 512;
        for (size_t i = 0; i < count; i++) {
            state = state * 1664525u + 1013904223u;
            pixels[i] = (i % 4 == 3) ? 255 : (uint8_t)(state >> 24);
        }
    });
    NSData *noisy = SZTestEncode(noise, @"public.png", nil);
    CGImageRelease(noise);
    NSData *fromNoise = [SZFriendsPicturePipeline normalizedImageFromData:noisy crop:NSZeroRect error:NULL];
    SZTestCheckOutputShape(@"noise", fromNoise);

    // A tight crop of a large picture: decoded at a reduced size, still cut from the right place.
    CGImageRef large = SZTestCreateQuadrants(3000, 2000);
    NSData *largeJPEG = SZTestEncode(large, @"public.jpeg", SZTestQuality(0.8));
    CGImageRelease(large);
    NSData *tight = [SZFriendsPicturePipeline normalizedImageFromData:largeJPEG crop:NSMakeRect(1400, 900, 200, 200)
                                                                error:NULL];
    SZTestCheckOutputShape(@"tight crop", tight);
    SZTestCheckQuadrants(@"tight crop across the middle", tight, quadrants);
}

static void SZTestExpectFailure(NSString *what, NSData *data, NSRect crop, SZFriendsPictureError code,
                                NSString *protocolCode) {
    NSError *error = nil;
    NSData *output = [SZFriendsPicturePipeline normalizedImageFromData:data crop:crop error:&error];
    SZ_CHECK(output == nil && error.code == code && [SZTestProtocolCode(error) isEqual:protocolCode] &&
                 error.localizedDescription.length > 0,
             @"%@: got %@ (%ld, %@)", what, output ? @"an image" : @"no image", (long)error.code,
             SZTestProtocolCode(error));
}

static void SZTestLimits(void) {
    NSMutableData *oversized = [NSMutableData dataWithLength:SZFriendsPictureMaxInputBytes + 1];
    memcpy(oversized.mutableBytes, "\xFF\xD8\xFF\xE0", 4);
    SZTestExpectFailure(@"one byte over 5 MiB", oversized, NSZeroRect, SZFriendsPictureErrorTooLarge,
                        @"picture_invalid");
    oversized.length = SZFriendsPictureMaxInputBytes;
    SZTestExpectFailure(@"5 MiB of garbage is unreadable, not too large", oversized, NSZeroRect,
                        SZFriendsPictureErrorUnreadable, @"picture_invalid");
    SZTestExpectFailure(@"empty", [NSData data], NSZeroRect, SZFriendsPictureErrorUnreadable, @"picture_invalid");
    SZTestExpectFailure(@"text", [@"hello, not a picture" dataUsingEncoding:NSUTF8StringEncoding], NSZeroRect,
                        SZFriendsPictureErrorUnreadable, @"picture_invalid");

    SZTestExpectFailure(@"8193 pixels wide", SZTestGrayPNG(8193, 8, 1), NSZeroRect, SZFriendsPictureErrorTooLarge,
                        @"picture_invalid");
    NSError *error = nil;
    SZ_CHECK([SZFriendsPicturePipeline normalizedImageFromData:SZTestGrayPNG(8192, 8, 1) crop:NSZeroRect error:&error],
             @"8192 pixels wide is within the limit: %@", error.localizedDescription);
    // 8 KB of PNG declaring 67 megapixels: refused from its header, never decoded.
    NSData *bomb = SZTestGrayPNG(8192, 8192, 1);
    SZ_CHECK(bomb.length < 64 * 1024, @"bomb is %lu bytes", (unsigned long)bomb.length);
    SZTestExpectFailure(@"decompression bomb", bomb, NSZeroRect, SZFriendsPictureErrorTooLarge, @"picture_invalid");
    NSError *bombError = nil, *pixelsError = nil;
    [SZFriendsPicturePipeline normalizedImageFromData:bomb crop:NSZeroRect error:&bombError];
    [SZFriendsPicturePipeline normalizedImageFromData:SZTestGrayPNG(8193, 8, 1) crop:NSZeroRect error:&pixelsError];
    SZ_CHECK(![bombError.localizedDescription isEqual:pixelsError.localizedDescription],
             @"a bomb within the size limits must not be told to stay under them");
    SZ_CHECK([SZFriendsPicturePipeline normalizedImageFromData:SZTestGrayPNG(2048, 2048, 8) crop:NSZeroRect error:NULL],
             @"a flat 2048 x 2048 PNG is an honest picture");

    CGImageRef image = SZTestCreateQuadrants(640, 480);
    NSData *jpeg = SZTestEncode(image, @"public.jpeg", SZTestQuality(0.9));
    CGImageRelease(image);
    // ImageIO would decode each of these, gray where the bytes stop; nobody should get half a picture.
    CGImageRef small = SZTestCreateQuadrants(320, 240);
    NSDictionary<NSString *, NSData *> *cut = @{
        @"JPEG" : jpeg,
        @"PNG" : SZTestEncode(small, @"public.png", nil),
        @"HEIC" : SZTestEncode(small, @"public.heic", nil),
        @"WebP" : [NSData dataWithBytes:SZTestWebP length:sizeof SZTestWebP],
    };
    CGImageRelease(small);
    for (NSString *format in cut) {
        NSData *whole = cut[format];
        SZ_CHECK([SZFriendsPicturePipeline normalizedImageFromData:whole crop:NSZeroRect error:NULL], @"whole %@",
                 format);
        SZTestExpectFailure([@"truncated " stringByAppendingString:format],
                            [whole subdataWithRange:NSMakeRange(0, whole.length * 3 / 4)], NSZeroRect,
                            SZFriendsPictureErrorUnreadable, @"picture_invalid");
    }
    NSDictionary<NSString *, NSValue *> *badCrops = @{
        @"off the right edge" : [NSValue valueWithRect:NSMakeRect(500, 0, 200, 200)],
        @"off the bottom" : [NSValue valueWithRect:NSMakeRect(0, 400, 100, 100)],
        @"not square" : [NSValue valueWithRect:NSMakeRect(0, 0, 100, 50)],
        @"negative" : [NSValue valueWithRect:NSMakeRect(-10, 0, 100, 100)],
        @"empty side" : [NSValue valueWithRect:NSMakeRect(10, 10, 0, 0)],
    };
    for (NSString *name in badCrops) {
        SZTestExpectFailure([@"crop " stringByAppendingString:name], jpeg, badCrops[name].rectValue,
                            SZFriendsPictureErrorInvalidField, @"invalid_field");
    }
    [SZFriendsPicturePipeline normalizedImageFromData:jpeg crop:NSMakeRect(500, 0, 200, 200) error:&error];
    SZ_CHECK([error.userInfo[SZFriendsPictureErrorFieldKey] isEqual:@"picture.crop"], @"field %@", error.userInfo);
    SZ_CHECK([SZFriendsPicturePipeline normalizedImageFromData:jpeg crop:NSMakeRect(160, 0, 480, 480) error:NULL],
             @"a crop touching the right and bottom edges fits");
}

void SZRunPipelineTests(SZTestContext context) {
    (void)context;
    SZTestShapeMetadataDeterminism();
    SZTestOrientation();
    SZTestFormats();
    SZTestLimits();
}
