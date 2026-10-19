// Test image builders for friends-avatars-check (SZFriendsAvatarsTestSupport.h).

#import <ImageIO/ImageIO.h>
#import <zlib.h>

#import "SZFriendsAvatarsTestSupport.h"

NSString *SZTestProtocolCode(NSError *error) {
    return error.userInfo[SZFriendsPictureErrorCodeKey];
}

CGImageRef SZTestCreateImage(size_t width, size_t height, void (^draw)(CGContextRef context)) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context =
        CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    draw(context);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return image;
}

CGImageRef SZTestCreateQuadrants(size_t width, size_t height) {
    return SZTestCreateImage(width, height, ^(CGContextRef context) {
        CGFloat w = width / 2.0, h = height / 2.0;
        // Core Graphics' origin is bottom left, so the top row of quadrants is at y = h.
        CGContextSetRGBFillColor(context, 1, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(0, h, w, h));
        CGContextSetRGBFillColor(context, 0, 1, 0, 1);
        CGContextFillRect(context, CGRectMake(w, h, w, h));
        CGContextSetRGBFillColor(context, 0, 0, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, w, h));
        CGContextSetRGBFillColor(context, 1, 1, 0, 1);
        CGContextFillRect(context, CGRectMake(w, 0, w, h));
    });
}

NSData *SZTestEncode(CGImageRef image, NSString *type, NSDictionary *properties) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)type, 1, NULL);
    if (!destination) return [NSData data];
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return ok ? data : [NSData data];
}

static void SZTestAppendChunk(NSMutableData *png, const char type[4], NSData *payload) {
    uint32_t length = CFSwapInt32HostToBig((uint32_t)payload.length);
    [png appendBytes:&length length:4];
    NSMutableData *typed = [NSMutableData dataWithBytes:type length:4];
    [typed appendData:payload];
    [png appendData:typed];
    uint32_t crc = CFSwapInt32HostToBig((uint32_t)crc32(0, typed.bytes, (uInt)typed.length));
    [png appendBytes:&crc length:4];
}

NSData *SZTestGrayPNG(uint32_t width, uint32_t height, uint8_t bitDepth) {
    static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    NSMutableData *png = [NSMutableData dataWithBytes:signature length:8];
    uint8_t header[13] = {0};
    uint32_t w = CFSwapInt32HostToBig(width), h = CFSwapInt32HostToBig(height);
    memcpy(header, &w, 4);
    memcpy(header + 4, &h, 4);
    header[8] = bitDepth;
    header[9] = 0; // grayscale
    SZTestAppendChunk(png, "IHDR", [NSData dataWithBytes:header length:13]);
    // Each row is a filter byte (0, none) and the packed samples, all zero.
    size_t rowBytes = 1 + ((size_t)width * bitDepth + 7) / 8;
    NSMutableData *raw = [NSMutableData dataWithLength:rowBytes * height];
    uLongf compressedLength = compressBound(raw.length);
    NSMutableData *compressed = [NSMutableData dataWithLength:compressedLength];
    compress2(compressed.mutableBytes, &compressedLength, raw.bytes, raw.length, 9);
    compressed.length = compressedLength;
    SZTestAppendChunk(png, "IDAT", compressed);
    SZTestAppendChunk(png, "IEND", [NSData data]);
    return png;
}

BOOL SZTestPixel(NSData *encoded, size_t x, size_t y, int rgb[3]) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)encoded, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (source) CFRelease(source);
    if (!image) return NO;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (x >= width || y >= height) {
        CGImageRelease(image);
        return NO;
    }
    uint8_t pixel[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    // Shift the image so the wanted pixel lands on the 1 x 1 bitmap; Core Graphics counts y from the bottom.
    CGContextDrawImage(context, CGRectMake(-(CGFloat)x, -(CGFloat)(height - 1 - y), width, height), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    CGImageRelease(image);
    rgb[0] = pixel[0];
    rgb[1] = pixel[1];
    rgb[2] = pixel[2];
    return YES;
}

BOOL SZTestNear(const int rgb[3], int r, int g, int b, int tolerance) {
    return abs(rgb[0] - r) <= tolerance && abs(rgb[1] - g) <= tolerance && abs(rgb[2] - b) <= tolerance;
}

NSArray<NSNumber *> *SZTestJPEGMarkers(NSData *jpeg) {
    NSMutableArray *markers = [NSMutableArray array];
    const uint8_t *p = jpeg.bytes;
    size_t i = 2;
    while (i + 4 <= jpeg.length && p[i] == 0xFF) {
        uint8_t marker = p[i + 1];
        [markers addObject:@(marker)];
        if (marker == 0xDA) break;
        i += 2 + (((size_t)p[i + 2] << 8) | p[i + 3]);
    }
    return markers;
}

NSData *SZTestInsertSegment(NSData *jpeg, uint8_t marker, NSData *payload) {
    NSMutableData *out = [NSMutableData dataWithBytes:jpeg.bytes length:2];
    uint8_t head[4] = {0xFF, marker, (uint8_t)((payload.length + 2) >> 8), (uint8_t)((payload.length + 2) & 0xFF)};
    [out appendBytes:head length:4];
    [out appendData:payload];
    [out appendData:[jpeg subdataWithRange:NSMakeRange(2, jpeg.length - 2)]];
    return out;
}

BOOL SZTestContains(NSData *haystack, NSString *needle) {
    NSData *bytes = [needle dataUsingEncoding:NSUTF8StringEncoding];
    return [haystack rangeOfData:bytes options:0 range:NSMakeRange(0, haystack.length)].location != NSNotFound;
}
