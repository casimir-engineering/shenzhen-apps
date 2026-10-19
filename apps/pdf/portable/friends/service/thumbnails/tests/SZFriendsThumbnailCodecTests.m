// The C layer: QOI round trips and hand-assembled streams (so the opcodes are checked against the specification, not
// only against our own encoder), every malformed shape the strict decoder refuses, the PNG writer read back by
// ImageIO, and the downscaler.

#import "SZFriendsThumbnailTestSupport.h"

#import "service/thumbnails/szfriends_image.h"
#import "service/thumbnails/szfriends_qoi.h"

static NSData *SZTEncode(NSData *rgba, uint32_t width, uint32_t height, uint8_t channels) {
    NSMutableData *out = [NSMutableData dataWithLength:(size_t)width * height * 5 + 22];
    size_t length = szfriends_qoi_encode(rgba.bytes, width, height, channels, out.mutableBytes, out.length);
    out.length = length;
    return out;
}

// The decoded pixels, or nil when the header or the stream is refused.
static NSData *SZTDecode(NSData *qoi, uint32_t cap) {
    szfriends_qoi_desc desc;
    if (!szfriends_qoi_read_header(qoi.bytes, qoi.length, cap, cap, &desc)) return nil;
    NSMutableData *rgba = [NSMutableData dataWithLength:(size_t)desc.width * desc.height * 4];
    return szfriends_qoi_decode(qoi.bytes, qoi.length, &desc, rgba.mutableBytes, rgba.length) ? rgba : nil;
}

static NSData *SZTStream(uint32_t width, uint32_t height, uint8_t channels, NSArray<NSNumber *> *ops) {
    NSMutableData *data = [NSMutableData dataWithBytes:"qoif" length:4];
    uint8_t header[10] = {(uint8_t)(width >> 24), (uint8_t)(width >> 16), (uint8_t)(width >> 8), (uint8_t)width,
                          (uint8_t)(height >> 24), (uint8_t)(height >> 16), (uint8_t)(height >> 8), (uint8_t)height,
                          channels, 0};
    [data appendBytes:header length:sizeof header];
    for (NSNumber *op in ops) {
        uint8_t byte = op.unsignedCharValue;
        [data appendBytes:&byte length:1];
    }
    static const uint8_t end[8] = {0, 0, 0, 0, 0, 0, 0, 1};
    [data appendBytes:end length:8];
    return data;
}

static void SZTRoundTrips(void) {
    struct {
        NSUInteger w, h;
        int kind;
    } cases[] = {{1, 1, 0}, {7, 3, 0}, {64, 64, 0}, {192, 192, 0}, {192, 108, 1}, {130, 1, 2}, {33, 47, 3}, {5, 5, 4}};
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        NSUInteger w = cases[i].w, h = cases[i].h;
        NSData *pixels = cases[i].kind == 0   ? SZTNoise(w, h, NO)
                         : cases[i].kind == 1 ? SZTGradient(w, h)
                         : cases[i].kind == 2 ? SZTSolid(w, h, 0x336699ff) // runs longer than 62
                         : cases[i].kind == 3 ? SZTNoise(w, h, YES)
                                              : SZTSolid(w, h, 0x00000000);
        uint8_t channels = cases[i].kind == 0 || cases[i].kind == 4 ? 4 : 3;
        NSData *qoi = SZTEncode(pixels, (uint32_t)w, (uint32_t)h, channels);
        SZT_CHECK(qoi.length > 0, @"case %zu encodes", i);
        SZT_CHECK([SZTDecode(qoi, 192) isEqualToData:pixels], @"case %zu (%lux%lu) round trips", i, (unsigned long)w,
                  (unsigned long)h);
        SZT_CHECK(((const uint8_t *)qoi.bytes)[12] == channels, @"case %zu: channels in the header", i);
    }
    // A palette that repeats exercises INDEX; the encoded size proves the encoder used it.
    NSMutableData *palette = [NSMutableData dataWithLength:64 * 64 * 4];
    uint32_t colours[4] = {0xff0000ff, 0x00ff00ff, 0x0000ffff, 0xffffffff};
    for (NSUInteger i = 0; i < 64 * 64; i++) {
        uint32_t c = colours[(i * 7 + i / 64) % 4];
        uint8_t px[4] = {(uint8_t)(c >> 24), (uint8_t)(c >> 16), (uint8_t)(c >> 8), (uint8_t)c};
        memcpy((uint8_t *)palette.mutableBytes + i * 4, px, 4);
    }
    NSData *qoi = SZTEncode(palette, 64, 64, 3);
    SZT_CHECK([SZTDecode(qoi, 192) isEqualToData:palette] && qoi.length < 64 * 64 + 64, @"palette: %lu bytes",
              (unsigned long)qoi.length);
}

static void SZTSpecificationStreams(void) {
    // Red from the initial black wraps to a DIFF (r - 1), then a run of one: the reference encoder's exact bytes.
    NSData *red = SZTSolid(2, 1, 0xff0000ff);
    NSData *expected = SZTStream(2, 1, 3, @[ @0x5a, @0xc0 ]);
    SZT_CHECK([SZTEncode(red, 2, 1, 3) isEqualToData:expected], @"two red pixels: %@", SZTEncode(red, 2, 1, 3));
    SZT_CHECK([SZTDecode(expected, 192) isEqualToData:red], @"and they decode");
    // RGB, LUMA, RGBA, then INDEX back to the first colour (its hash slot is 9).
    NSData *mixed = SZTStream(4, 1, 4, @[ @0xfe, @10, @20, @30, @0xa5, @0xa5, @0xff, @1, @2, @3, @4, @0x09 ]);
    const uint8_t want[16] = {10, 20, 30, 255, 17, 25, 32, 255, 1, 2, 3, 4, 10, 20, 30, 255};
    NSData *pixels = [NSData dataWithBytes:want length:sizeof want];
    SZT_CHECK([SZTDecode(mixed, 192) isEqualToData:pixels], @"RGB, LUMA, RGBA and INDEX decode as specified");
    SZT_CHECK([SZTEncode(pixels, 4, 1, 4) isEqualToData:mixed], @"and our encoder picks the same opcodes");
}

static void SZTMalformed(void) {
    NSData *good = SZTEncode(SZTNoise(16, 9, NO), 16, 9, 4);
    SZT_CHECK(SZTDecode(good, 192) != nil, @"the base stream decodes");
    szfriends_qoi_desc desc;
    SZT_CHECK(!szfriends_qoi_read_header(good.bytes, SZFRIENDS_QOI_MIN_SIZE - 1, 192, 192, &desc), @"too short");
    SZT_CHECK(!szfriends_qoi_read_header(good.bytes, good.length, 15, 192, &desc), @"wider than the cap");
    SZT_CHECK(!szfriends_qoi_read_header(good.bytes, good.length, 192, 8, &desc), @"taller than the cap");
    struct {
        size_t offset;
        uint8_t value;
        const char *what;
    } headers[] = {{0, 'Q', "magic"}, {7, 0, "zero width"}, {11, 0, "zero height"}, {12, 2, "two channels"},
                   {12, 5, "five channels"}, {13, 2, "colorspace 2"}};
    for (size_t i = 0; i < sizeof headers / sizeof headers[0]; i++) {
        NSMutableData *bad = [good mutableCopy];
        if (headers[i].offset == 7 || headers[i].offset == 11) {
            memset((uint8_t *)bad.mutableBytes + headers[i].offset - 3, 0, 4);
        } else {
            ((uint8_t *)bad.mutableBytes)[headers[i].offset] = headers[i].value;
        }
        SZT_CHECK(SZTDecode(bad, 192) == nil, @"header refused: %s", headers[i].what);
    }
    // Every truncation fails, never reads past the end, and never yields an image.
    for (NSUInteger length = 0; length < good.length; length++) {
        SZT_CHECK(SZTDecode([good subdataWithRange:NSMakeRange(0, length)], 192) == nil, @"truncated to %lu",
                  (unsigned long)length);
    }
    NSMutableData *trailing = [good mutableCopy];
    [trailing appendBytes:"\0" length:1];
    SZT_CHECK(SZTDecode(trailing, 192) == nil, @"a byte after the end marker");
    NSMutableData *marker = [good mutableCopy];
    ((uint8_t *)marker.mutableBytes)[marker.length - 1] = 2;
    SZT_CHECK(SZTDecode(marker, 192) == nil, @"a damaged end marker");
    SZT_CHECK(SZTDecode(SZTStream(2, 1, 4, @[ @0xc2 ]), 192) == nil, @"a run past the last pixel");
    SZT_CHECK(SZTDecode(SZTStream(1, 1, 4, @[ @0xfe, @1, @2 ]), 192) == nil, @"RGB cut short by the end marker");
    SZT_CHECK(SZTDecode(SZTStream(1, 1, 4, @[ @0xff, @1, @2, @3 ]), 192) == nil, @"RGBA cut short");
    SZT_CHECK(SZTDecode(SZTStream(1, 1, 4, @[ @0xa0 ]), 192) == nil, @"LUMA without its second byte");
    SZT_CHECK(SZTDecode(SZTStream(2, 2, 4, @[ @0xc0 ]), 192) == nil, @"too few pixels");
    SZT_CHECK(SZTDecode(SZTStream(1, 1, 4, @[ @0xc0, @0xc0 ]), 192) == nil, @"too many opcodes");
    NSMutableData *rgba = [NSMutableData dataWithLength:16 * 9 * 4 - 1];
    szfriends_qoi_read_header(good.bytes, good.length, 192, 192, &desc);
    SZT_CHECK(!szfriends_qoi_decode(good.bytes, good.length, &desc, rgba.mutableBytes, rgba.length),
              @"a pixel buffer of the wrong size is refused");
    // Single-byte damage anywhere either still decodes or is refused; the sanitizers prove nothing is overrun.
    for (NSUInteger i = 0; i < good.length; i++) {
        NSMutableData *damaged = [good mutableCopy];
        ((uint8_t *)damaged.mutableBytes)[i] ^= (uint8_t)(1 + arc4random_uniform(255));
        (void)SZTDecode(damaged, 192);
    }
    // The encoder refuses rather than overruns a buffer one byte short of what it needs.
    NSMutableData *exact = [NSMutableData dataWithLength:good.length];
    NSData *noise = SZTNoise(16, 9, NO);
    size_t needed = szfriends_qoi_encode(noise.bytes, 16, 9, 4, exact.mutableBytes, 16 * 9 * 5 + 22);
    SZT_CHECK(needed > 0 && szfriends_qoi_encode(noise.bytes, 16, 9, 4, exact.mutableBytes, needed) == needed &&
                  szfriends_qoi_encode(noise.bytes, 16, 9, 4, exact.mutableBytes, needed - 1) == 0,
              @"the encoder stops at its buffer (needs %zu)", needed);
    SZT_CHECK(szfriends_qoi_encode(noise.bytes, 0, 9, 4, exact.mutableBytes, exact.length) == 0, @"zero width");
    SZT_CHECK(szfriends_qoi_encode(noise.bytes, 16, 9, 2, exact.mutableBytes, exact.length) == 0, @"two channels");
}

static void SZTPNG(void) {
    struct {
        NSUInteger w, h;
        BOOL translucent;
    } cases[] = {{1, 1, NO}, {3, 2, YES}, {192, 192, NO}, {191, 120, YES}}; // 192 x 192 spans three stored blocks
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        NSUInteger w = cases[i].w, h = cases[i].h;
        NSData *pixels = cases[i].translucent ? SZTNoise(w, h, NO) : SZTGradient(w, h);
        size_t size = szfriends_png_size((uint32_t)w, (uint32_t)h);
        NSMutableData *png = [NSMutableData dataWithLength:size];
        SZT_CHECK(szfriends_png_encode(pixels.bytes, (uint32_t)w, (uint32_t)h, png.mutableBytes, size) == size,
                  @"case %zu writes exactly its size", i);
        SZT_CHECK(szfriends_png_encode(pixels.bytes, (uint32_t)w, (uint32_t)h, png.mutableBytes, size - 1) == 0,
                  @"case %zu refuses a short buffer", i);
        NSUInteger dw = 0, dh = 0;
        NSData *decoded = SZTDecodePNG(png, &dw, &dh);
        SZT_CHECK(dw == w && dh == h && decoded != nil, @"case %zu: ImageIO reads %lux%lu", i, (unsigned long)dw,
                  (unsigned long)dh);
        if (decoded == nil) continue;
        BOOL same = YES;
        const uint8_t *a = pixels.bytes, *b = decoded.bytes;
        for (NSUInteger p = 0; p < w * h && same; p++) {
            // Colour under zero alpha carries no information once premultiplied, so only alpha must agree there.
            same = a[p * 4 + 3] == b[p * 4 + 3] && (a[p * 4 + 3] == 0 || !memcmp(a + p * 4, b + p * 4, 3));
        }
        SZT_CHECK(same, @"case %zu: the pixels ImageIO reads are ours", i);
    }
    SZT_CHECK(szfriends_png_size(0, 4) == 0 && szfriends_png_size(4097, 4) == 0, @"sizes out of range");
}

static void SZTDownscale(void) {
    const uint8_t src[2 * 2 * 4] = {255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 255, 255};
    uint8_t one[4];
    SZT_CHECK(szfriends_rgba_downscale(src, 2, 2, one, 1, 1), @"2x2 to 1x1");
    // Alpha-weighted: the transparent pixel adds no black; red and two blues average by coverage.
    SZT_CHECK(one[0] == 85 && one[1] == 0 && one[2] == 170 && one[3] == 191, @"got %u %u %u %u", one[0], one[1],
              one[2], one[3]);
    uint8_t row[2 * 4];
    SZT_CHECK(szfriends_rgba_downscale(src, 2, 2, row, 2, 1), @"2x2 to 2x1");
    SZT_CHECK(row[0] == 128 && row[2] == 128 && row[4] == 0 && row[6] == 255 && row[7] == 128, @"columns");
    SZT_CHECK(!szfriends_rgba_downscale(src, 2, 2, row, 3, 1), @"never upscales");
    uint32_t w = 0, h = 0;
    szfriends_fit_size(400, 300, 192, &w, &h);
    SZT_CHECK(w == 192 && h == 144, @"400x300 fits as %ux%u", w, h);
    szfriends_fit_size(100, 50, 192, &w, &h);
    SZT_CHECK(w == 100 && h == 50, @"small pictures keep their size");
    szfriends_fit_size(5000, 3, 192, &w, &h);
    SZT_CHECK(w == 192 && h == 1, @"a sliver keeps one row");
}

void SZTRunCodecTests(void) {
    SZTRoundTrips();
    SZTSpecificationStreams();
    SZTMalformed();
    SZTPNG();
    SZTDownscale();
}
