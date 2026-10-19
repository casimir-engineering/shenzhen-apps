// Byte-level checks: the JPEG marker walker that guards received pictures and strips metadata from our own output,
// and the end-of-file checks that catch truncated pictures ImageIO would decode anyway.

#import "SZFriendsAvatarsTestSupport.h"
#import "avatars/SZFriendsImageBytes.h"

static NSData *SZTestBaselineJPEG(size_t side) {
    CGImageRef image = SZTestCreateQuadrants(side, side);
    NSDictionary *quality = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.8};
    NSData *jpeg = SZTestEncode(image, @"public.jpeg", quality);
    CGImageRelease(image);
    return jpeg;
}

static int SZTestReadHeader(NSData *data, szfriends_jpeg_info *info) {
    return szfriends_jpeg_read_header(data.bytes, data.length, info);
}

static void SZTestMarkerWalker(void) {
    NSData *jpeg = SZTestBaselineJPEG(256);
    szfriends_jpeg_info info;
    SZ_CHECK(SZTestReadHeader(jpeg, &info) == 0, @"baseline JPEG");
    SZ_CHECK(info.sof_marker == 0xC0 && info.frame_count == 1 && info.width == 256 && info.height == 256 &&
                 info.components == 3 && info.precision == 8,
             @"frame %#x %ux%u x%u", info.sof_marker, info.width, info.height, info.components);

    // Fill bytes before a marker are legal (T.81 B.1.1.2) and must not hide the frame header.
    NSMutableData *filled = [NSMutableData dataWithBytes:jpeg.bytes length:2];
    [filled appendBytes:"\xFF\xFF\xFF" length:3];
    [filled appendData:[jpeg subdataWithRange:NSMakeRange(2, jpeg.length - 2)]];
    SZ_CHECK(SZTestReadHeader(filled, &info) == 0 && info.width == 256, @"fill bytes");

    SZ_CHECK(SZTestReadHeader([jpeg subdataWithRange:NSMakeRange(0, 30)], &info) != 0, @"cut inside a segment");
    SZ_CHECK(SZTestReadHeader([jpeg subdataWithRange:NSMakeRange(1, jpeg.length - 1)], &info) != 0, @"no SOI");
    SZ_CHECK(SZTestReadHeader([NSData data], &info) != 0, @"empty");
    const uint8_t sosFirst[] = {0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0x00};
    SZ_CHECK(SZTestReadHeader([NSData dataWithBytes:sosFirst length:sizeof sosFirst], &info) != 0,
             @"a scan before any frame header");
    const uint8_t overrun[] = {0xFF, 0xD8, 0xFF, 0xE0, 0x40, 0x00, 'J', 'F'};
    SZ_CHECK(SZTestReadHeader([NSData dataWithBytes:overrun length:sizeof overrun], &info) != 0,
             @"a segment length past the end");
    const uint8_t badFrame[] = {0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 8, 1, 0, 1, 0, 3, 1, 0x11, 0,
                                0xFF, 0xDA, 0x00, 0x02};
    SZ_CHECK(SZTestReadHeader([NSData dataWithBytes:badFrame length:sizeof badFrame], &info) != 0,
             @"a frame header whose length disagrees with its component count");
    const uint8_t eoiFirst[] = {0xFF, 0xD8, 0xFF, 0xD9};
    SZ_CHECK(SZTestReadHeader([NSData dataWithBytes:eoiFirst length:sizeof eoiFirst], &info) != 0, @"EOI only");

    // A progressive frame is reported as such, so the received-picture check can refuse it.
    NSMutableData *progressive = [jpeg mutableCopy];
    NSUInteger offset = [progressive rangeOfData:[NSData dataWithBytes:"\xFF\xC0" length:2] options:0
                                           range:NSMakeRange(0, progressive.length)]
                            .location;
    ((uint8_t *)progressive.mutableBytes)[offset + 1] = 0xC2;
    SZ_CHECK(SZTestReadHeader(progressive, &info) == 0 && info.sof_marker == 0xC2, @"progressive marker");

    // Stripping removes APP1-APP15 and COM, keeps everything else, and the result still decodes.
    NSData *planted = SZTestInsertSegment(jpeg, 0xFE, [@"SZFRIENDS-COMMENT" dataUsingEncoding:NSUTF8StringEncoding]);
    planted = SZTestInsertSegment(planted, 0xE1, [@"Exif\0\0SZFRIENDS-EXIF" dataUsingEncoding:NSUTF8StringEncoding]);
    planted = SZTestInsertSegment(planted, 0xE2, [@"ICC_PROFILE SZFRIENDS-ICC" dataUsingEncoding:NSUTF8StringEncoding]);
    NSMutableData *stripped = [NSMutableData dataWithLength:planted.length];
    size_t length = szfriends_jpeg_strip_metadata(planted.bytes, planted.length, stripped.mutableBytes);
    stripped.length = length;
    SZ_CHECK(length > 0, @"strip failed");
    for (NSString *needle in @[ @"SZFRIENDS-COMMENT", @"SZFRIENDS-EXIF", @"SZFRIENDS-ICC" ]) {
        SZ_CHECK(!SZTestContains(stripped, needle), @"%@ survived stripping", needle);
    }
    for (NSNumber *marker in SZTestJPEGMarkers(stripped)) {
        uint8_t m = marker.unsignedCharValue;
        SZ_CHECK(!((m >= 0xE1 && m <= 0xEF) || m == 0xFE), @"marker %#x survived stripping", m);
    }
    NSMutableData *clean = [NSMutableData dataWithLength:jpeg.length];
    size_t cleanLength = szfriends_jpeg_strip_metadata(jpeg.bytes, jpeg.length, clean.mutableBytes);
    clean.length = cleanLength;
    SZ_CHECK([stripped isEqualToData:clean], @"stripping planted segments must give the same bytes as stripping the "
                                             @"original");
    int rgb[3];
    SZ_CHECK(SZTestPixel(stripped, 64, 64, rgb) && SZTestNear(rgb, 255, 0, 0, 40), @"stripped JPEG decodes");
    SZ_CHECK(szfriends_jpeg_strip_metadata(sosFirst, sizeof sosFirst, stripped.mutableBytes) == 0,
             @"malformed input is not stripped");
}

// A 64 x 64 lossless WebP of the four test quadrants (66 bytes), made once with ImageMagick: ImageIO reads WebP but
// cannot write it, and the pipeline accepts WebP, so the suite needs a real one.
const uint8_t SZTestWebP[66] = {
    0x52, 0x49, 0x46, 0x46, 0x3a, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c, 0x2d,
    0x00, 0x00, 0x00, 0x2f, 0x3f, 0xc0, 0x0f, 0x00, 0x1f, 0x20, 0x10, 0x48, 0xda, 0x1f, 0x7a, 0x8d, 0xf9,
    0x17, 0x10, 0x14, 0xf9, 0x3f, 0xda, 0xfc, 0x07, 0x5f, 0x24, 0x80, 0x48, 0x80, 0xc4, 0x93, 0x9e, 0xf4,
    0xa4, 0x89, 0x01, 0xb4, 0x88, 0xfe, 0x4f, 0xc0, 0xb1, 0xe8, 0x5b, 0x70, 0xe8, 0x1b, 0x00,
};

static void SZTestEnds(void) {
    CGImageRef image = SZTestCreateQuadrants(320, 240);
    NSData *jpeg = SZTestEncode(image, @"public.jpeg", nil);
    NSData *png = SZTestEncode(image, @"public.png", nil);
    NSData *heic = SZTestEncode(image, @"public.heic", nil);
    CGImageRelease(image);
    NSData *webp = [NSData dataWithBytes:SZTestWebP length:sizeof SZTestWebP];
    typedef int (*SZTestEndCheck)(const uint8_t *, size_t);
    NSDictionary<NSString *, NSData *> *files = @{@"JPEG" : jpeg, @"PNG" : png, @"HEIC" : heic, @"WebP" : webp};
    NSDictionary<NSString *, NSValue *> *checks = @{
        @"JPEG" : [NSValue valueWithPointer:(const void *)szfriends_jpeg_is_complete],
        @"PNG" : [NSValue valueWithPointer:(const void *)szfriends_png_is_complete],
        @"HEIC" : [NSValue valueWithPointer:(const void *)szfriends_bmff_is_complete],
        @"WebP" : [NSValue valueWithPointer:(const void *)szfriends_webp_is_complete],
    };
    for (NSString *format in files) {
        NSData *file = files[format];
        SZTestEndCheck check = (SZTestEndCheck)checks[format].pointerValue;
        SZ_CHECK(file.length > 16 && check(file.bytes, file.length) == 1, @"whole %@", format);
        SZ_CHECK(check(file.bytes, file.length - 1) == 0, @"%@ missing its last byte", format);
        SZ_CHECK(check(file.bytes, file.length / 2) == 0, @"%@ cut in half", format);
        SZ_CHECK(check(file.bytes, 0) == 0 && check(NULL, 0) == 0, @"empty %@", format);
        NSMutableData *trailing = [file mutableCopy];
        [trailing appendBytes:"\0\0\0\0" length:4];
        if ([format isEqual:@"JPEG"] || [format isEqual:@"PNG"] || [format isEqual:@"WebP"]) {
            SZ_CHECK(check(trailing.bytes, trailing.length) == 1, @"%@ with bytes after its end", format);
        }
    }
    // The EOI of an embedded EXIF thumbnail sits before the scan and must not make a cut file look whole.
    NSData *thumbnailed = SZTestInsertSegment(jpeg, 0xE1, [NSData dataWithBytes:"Exif\0\0\xFF\xD8\xFF\xD9" length:10]);
    SZ_CHECK(szfriends_jpeg_is_complete(thumbnailed.bytes, thumbnailed.length / 2) == 0, @"thumbnail EOI");
    const uint8_t endless[] = {0, 0, 0, 0, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c'};
    SZ_CHECK(szfriends_bmff_is_complete(endless, sizeof endless) == 1, @"a box that runs to the end");
    const uint8_t tiny[] = {0, 0, 0, 4, 'f', 't', 'y', 'p'};
    SZ_CHECK(szfriends_bmff_is_complete(tiny, sizeof tiny) == 0, @"a box smaller than its header");
}

void SZRunJPEGTests(SZTestContext context) {
    (void)context;
    SZTestMarkerWalker();
    SZTestEnds();
}
