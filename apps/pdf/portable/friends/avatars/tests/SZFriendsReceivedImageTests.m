// Pictures received from friends: only a small baseline 256 x 256 JPEG passes, and re-encoding drops whatever the
// sender embedded.

#import "SZFriendsAvatarsTestSupport.h"

void SZTestCheckOutputShape(NSString *what, NSData *jpeg);

static NSData *SZTestJPEG(size_t width, size_t height, BOOL progressive) {
    CGImageRef image = SZTestCreateQuadrants(width, height);
    NSMutableDictionary *properties =
        [@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.8} mutableCopy];
    if (progressive) {
        properties[(__bridge NSString *)kCGImagePropertyJFIFDictionary] =
            @{(__bridge NSString *)kCGImagePropertyJFIFIsProgressive : @YES};
    }
    NSData *jpeg = SZTestEncode(image, @"public.jpeg", properties);
    CGImageRelease(image);
    return jpeg;
}

static void SZTestRefused(NSString *what, NSData *data) {
    NSError *error = nil;
    SZ_CHECK(![SZFriendsPicturePipeline validateReceivedImage:data error:&error] &&
                 [SZTestProtocolCode(error) isEqual:@"picture_invalid"],
             @"%@ must be refused", what);
    SZ_CHECK([SZFriendsPicturePipeline normalizedReceivedImage:data error:NULL] == nil, @"%@ must not re-encode", what);
}

void SZRunReceivedImageTests(SZTestContext context) {
    (void)context;
    CGImageRef image = SZTestCreateQuadrants(640, 480);
    NSData *photo = SZTestEncode(image, @"public.jpeg", nil);
    CGImageRelease(image);
    NSData *sent = [SZFriendsPicturePipeline normalizedImageFromData:photo crop:NSZeroRect error:NULL];
    NSError *error = nil;
    SZ_CHECK([SZFriendsPicturePipeline validateReceivedImage:sent error:&error], @"our own output: %@",
             error.localizedDescription);
    NSData *received = [SZFriendsPicturePipeline normalizedReceivedImage:sent error:&error];
    SZTestCheckOutputShape(@"re-encoded friend's picture", received);

    NSData *progressive = SZTestJPEG(256, 256, YES);
    SZ_CHECK([SZTestJPEGMarkers(progressive) containsObject:@0xC2], @"the test input must really be progressive");
    SZTestRefused(@"a progressive JPEG", progressive);
    SZTestRefused(@"257 x 257", SZTestJPEG(257, 257, NO));
    SZTestRefused(@"255 x 255", SZTestJPEG(255, 255, NO));
    SZTestRefused(@"256 x 128", SZTestJPEG(256, 128, NO));
    CGImageRef square = SZTestCreateQuadrants(256, 256);
    SZTestRefused(@"a PNG", SZTestEncode(square, @"public.png", nil));
    CGImageRelease(square);
    SZTestRefused(@"empty", [NSData data]);
    SZTestRefused(@"garbage", [@"not a picture at all" dataUsingEncoding:NSUTF8StringEncoding]);
    SZTestRefused(@"truncated", [sent subdataWithRange:NSMakeRange(0, sent.length / 3)]);
    SZTestRefused(@"over 48 KiB", SZTestInsertSegment(sent, 0xFE, [NSMutableData dataWithLength:49 * 1024]));

    // Arithmetic coding: the same file with its frame marker changed from baseline (C0) to C9.
    NSMutableData *arithmetic = [sent mutableCopy];
    NSUInteger offset = [arithmetic rangeOfData:[NSData dataWithBytes:"\xFF\xC0" length:2] options:0
                                          range:NSMakeRange(0, arithmetic.length)]
                            .location;
    SZ_CHECK(offset != NSNotFound, @"baseline frame marker");
    if (offset != NSNotFound) {
        ((uint8_t *)arithmetic.mutableBytes)[offset + 1] = 0xC9;
        SZTestRefused(@"an arithmetic-coded frame", arithmetic);
    }

    // A sender's own segments pass validation (they are harmless to skip) but never survive re-encoding.
    NSData *exif = [@"Exif\0\0SZFRIENDS-PEER-SECRET" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *tagged = SZTestInsertSegment(sent, 0xE1, exif);
    tagged = SZTestInsertSegment(tagged, 0xFE, [@"SZFRIENDS-PEER-COMMENT" dataUsingEncoding:NSUTF8StringEncoding]);
    SZ_CHECK([SZFriendsPicturePipeline validateReceivedImage:tagged error:NULL], @"tagged picture should validate");
    NSData *cleaned = [SZFriendsPicturePipeline normalizedReceivedImage:tagged error:NULL];
    SZTestCheckOutputShape(@"re-encoded tagged picture", cleaned);
    SZ_CHECK(!SZTestContains(cleaned, @"SZFRIENDS-PEER"), @"a sender's metadata survived re-encoding");
}
