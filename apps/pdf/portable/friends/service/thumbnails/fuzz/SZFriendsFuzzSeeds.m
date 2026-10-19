// Writes the seed corpora the fuzzers start from (make friends-thumbnails-fuzz-seeds): QOI streams that use every
// opcode, and one valid frame of every session type plus handshake payloads. The committed corpus under
// fuzz/corpus/ is this program's output, so it can be regenerated after a format change instead of edited by hand.
//
// Usage: SZFriendsFuzzSeeds <qoi directory> <frame directory>

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsHandshakePayload.h"
#import "service/session/SZFriendsSession.h"
#import "service/thumbnails/SZFriendsThumbnails.h"
#import "service/thumbnails/szfriends_qoi.h"

static NSData *SZSeedPixels(NSUInteger width, NSUInteger height, int kind) {
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *px = data.mutableBytes;
    uint32_t state = 12345;
    for (NSUInteger i = 0; i < width * height; i++, px += 4) {
        NSUInteger x = i % width, y = i / width;
        state = state * 1103515245u + 12345u; // fixed, so regenerating gives the same files
        switch (kind) {
        case 0: px[0] = 200, px[1] = 40, px[2] = 40, px[3] = 255; break;                   // runs
        case 1: px[0] = (uint8_t)x, px[1] = (uint8_t)y, px[2] = (uint8_t)(x + y), px[3] = 255; break; // DIFF, LUMA
        case 2: memcpy(px, (uint8_t[]){(uint8_t)((i % 3) * 120), 30, 200, 255}, 4); break;    // INDEX
        default: memcpy(px, &state, 4); break;                                                // RGB, RGBA
        }
    }
    return data;
}

static void SZSeedWrite(NSString *directory, NSString *name, NSData *data) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (![data writeToFile:path atomically:YES]) fprintf(stderr, "cannot write %s\n", path.UTF8String);
}

static NSData *SZSeedQOI(NSUInteger width, NSUInteger height, int kind) {
    NSData *pixels = SZSeedPixels(width, height, kind);
    NSMutableData *out = [NSMutableData dataWithLength:width * height * 5 + 32];
    out.length = szfriends_qoi_encode(pixels.bytes, (uint32_t)width, (uint32_t)height, kind == 3 ? 4 : 3,
                                      out.mutableBytes, out.length);
    return out;
}

static NSData *SZSeedU(uint64_t value, SZFriendsFieldTag tag) {
    return [SZFriendsFrame fieldWithUInt64:value tag:tag];
}

static NSData *SZSeedBytes(uint8_t fill, NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    memset(data.mutableBytes, fill, count);
    return data;
}

static NSData *SZSeedText(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <qoi directory> <frame directory>\n", argv[0]);
            return 2;
        }
        NSString *qoi = @(argv[1]), *frames = @(argv[2]);
        for (NSString *directory in @[ qoi, frames ]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                       attributes:nil error:NULL];
        }
        SZSeedWrite(qoi, @"runs-130x1.qoi", SZSeedQOI(130, 1, 0));
        SZSeedWrite(qoi, @"gradient-24x16.qoi", SZSeedQOI(24, 16, 1));
        SZSeedWrite(qoi, @"palette-12x12.qoi", SZSeedQOI(12, 12, 2));
        SZSeedWrite(qoi, @"noise-rgba-8x6.qoi", SZSeedQOI(8, 6, 3));
        SZSeedWrite(qoi, @"one-pixel.qoi", SZSeedQOI(1, 1, 3));
        SZSeedWrite(qoi, @"tall-1x192.qoi", SZSeedQOI(1, 192, 1));

        NSData *ident = SZSeedBytes(0x11, 16), *sentAt = SZSeedU(1760251668000, SZFriendsFieldSentAt);
        NSData *thumbnail = SZSeedQOI(24, 16, 1);
        NSDictionary<NSString *, SZFriendsFrame *> *samples = @{
            @"hello" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeHello fields:@{}],
            @"profile" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile fields:@{
                @(SZFriendsFieldName) : SZSeedText(@"Mei"), @(SZFriendsFieldFriendsID) : SZSeedText(@"maple-river"),
                @(SZFriendsFieldPictureSet) : SZSeedU(1, SZFriendsFieldPictureSet),
                @(SZFriendsFieldPictureIndex) : SZSeedU(4, SZFriendsFieldPictureIndex)}],
            @"request" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeRequest fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldSentAt) : sentAt,
                @(SZFriendsFieldText) : SZSeedText(@"hi")}],
            @"message" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeMessage fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldSentAt) : sentAt,
                @(SZFriendsFieldText) : SZSeedText(@"合同 report, pages 3–5"),
                @(SZFriendsFieldOfferIDs) : SZSeedBytes(0x22, 32), @(SZFriendsFieldViaAssistant) : SZSeedBytes(1, 1)}],
            @"offer" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeOffer fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldName) : SZSeedText(@"Site photos.pdf"),
                @(SZFriendsFieldFileType) : SZSeedText(@"com.adobe.pdf"), @(SZFriendsFieldSize) :
                SZSeedU(42318806, SZFriendsFieldSize), @(SZFriendsFieldDigest) : SZSeedBytes(0x33, 32)}],
            @"offer-reply" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeOfferReply fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldAccept) : SZSeedBytes(1, 1),
                @(SZFriendsFieldOffset) : SZSeedU(4096, SZFriendsFieldOffset)}],
            @"chunk" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeChunk fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldOffset) : SZSeedU(0, SZFriendsFieldOffset),
                @(SZFriendsFieldData) : SZSeedBytes(0x44, 512)}],
            @"progress" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeProgress fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldOffset) : SZSeedU(512, SZFriendsFieldOffset)}],
            @"done" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeDone fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldDigest) : SZSeedBytes(0x55, 32)}],
            @"ack" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeAck fields:@{@(SZFriendsFieldID) : ident}],
            @"cancel" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeCancel fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldReason) : SZSeedBytes(0, 1)}],
            @"presence-secret" : [SZFriendsFrame frameWithType:SZFriendsFrameTypePresenceSecret fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldSecret) : SZSeedBytes(0x66, 32)}],
            @"request-by-id" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeRequestByID fields:@{
                @(SZFriendsFieldFriendsID) : SZSeedText(@"maple-river"), @(SZFriendsFieldToken) : SZSeedBytes(3, 16),
                @(SZFriendsFieldCallbackSecret) : SZSeedBytes(4, 32), @(SZFriendsFieldCertificate) :
                SZSeedBytes(5, 96), @(SZFriendsFieldStaticKey) : SZSeedBytes(6, 32),
                @(SZFriendsFieldSignature) : SZSeedBytes(7, 64)}],
            @"code-commit" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeCodeCommit fields:@{
                @(SZFriendsFieldCommitment) : SZSeedBytes(8, 32)}],
            @"close" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeClose fields:@{
                @(SZFriendsFieldReason) : SZSeedBytes(1, 1)}],
            @"thumbnail" : [SZFriendsFrame frameWithType:SZFriendsFrameTypeThumbnail fields:@{
                @(SZFriendsFieldID) : ident, @(SZFriendsFieldWidth) : SZSeedU(24, SZFriendsFieldWidth),
                @(SZFriendsFieldHeight) : SZSeedU(16, SZFriendsFieldHeight), @(SZFriendsFieldData) : thumbnail}],
        };
        int failures = 0;
        for (NSString *name in samples) {
            NSData *encoded = SZFriendsEncodeFrame(samples[name], NULL);
            if (encoded == nil) {
                fprintf(stderr, "seed %s does not encode\n", name.UTF8String);
                failures++;
                continue;
            }
            SZSeedWrite(frames, [name stringByAppendingString:@".frame"], encoded);
        }
        SZFriendsHandshakePayload *payload = [SZFriendsHandshakePayload localPayload];
        payload.certificate = SZSeedBytes(0xcc, 96);
        payload.hasRouteClass = YES;
        payload.routeClass = 1;
        NSMutableData *typed = [NSMutableData dataWithBytes:"\x00" length:1]; // the target skips one byte for payloads
        [typed appendData:[payload encodedDataWithError:NULL] ?: [NSData data]];
        SZSeedWrite(frames, @"handshake-payload.frame", typed);
        return failures == 0 ? 0 : 1;
    }
}
