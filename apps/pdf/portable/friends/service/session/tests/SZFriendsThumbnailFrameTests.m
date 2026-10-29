// THUMBNAIL (minor 1): the codec's bounds on a file preview, minor-version negotiation with a peer that predates it,
// and the channel queueing previews behind messages (brief § Transfers: "after the offer, behind queued messages").

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsHandshakePayload.h"

static NSData *SZFThumbnailRaw(NSData *ident, NSData *width, NSData *height, NSData *data) {
    uint8_t type = SZFriendsFrameTypeThumbnail;
    NSMutableData *plaintext = [NSMutableData dataWithBytes:&type length:1];
    NSArray *fields = @[ @(SZFriendsFieldID), ident, @(SZFriendsFieldWidth), width, @(SZFriendsFieldHeight), height,
                         @(SZFriendsFieldData), data ];
    for (NSUInteger i = 0; i < fields.count; i += 2) {
        NSData *value = fields[i + 1];
        if (value.length == 0 && [fields[i] intValue] != SZFriendsFieldData) continue; // leave the field out
        uint8_t header[3] = {(uint8_t)[fields[i] intValue], (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [plaintext appendBytes:header length:3];
        [plaintext appendData:value];
    }
    return plaintext;
}

static SZFriendsFrame *SZFThumbnailFrame(uint8_t fill, NSUInteger bytes) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeThumbnail
                                  fields:@{
                                      @(SZFriendsFieldID) : SZFBytes(0x42, 16),
                                      @(SZFriendsFieldWidth) : [SZFriendsFrame fieldWithUInt64:192
                                                                                           tag:SZFriendsFieldWidth],
                                      @(SZFriendsFieldHeight) : [SZFriendsFrame fieldWithUInt64:144
                                                                                            tag:SZFriendsFieldHeight],
                                      @(SZFriendsFieldData) : SZFBytes(fill, bytes),
                                  }];
}

static void SZFTestThumbnailCodec(void) {
    NSData *ident = SZFBytes(1, 16), *side = [SZFriendsFrame fieldWithUInt64:96 tag:SZFriendsFieldWidth];
    NSError *error = nil;
    SZFriendsFrame *frame = SZFriendsDecodeFrame(SZFThumbnailRaw(ident, side, side, SZFBytes(7, 23)), &error);
    uint64_t width = 0, height = 0;
    SZF_CHECK(frame.type == SZFriendsFrameTypeThumbnail && [frame getUInt64:&width forTag:SZFriendsFieldWidth] &&
                  [frame getUInt64:&height forTag:SZFriendsFieldHeight] && width == 96 && height == 96,
              @"a THUMBNAIL decodes with its sides: %@", error);
    SZF_CHECK(SZFriendsFrameThumbnailMax == 64000, @"64 KB of QOI");
    NSData *largest = SZFThumbnailRaw(ident, side, side, SZFBytes(7, SZFriendsFrameThumbnailMax));
    SZF_CHECK(largest.length <= SZFriendsFramePlaintextMax && SZFriendsDecodeFrame(largest, NULL) != nil,
              @"the largest preview fits one transport message (%lu bytes)", (unsigned long)largest.length);
    struct {
        NSData *plaintext;
        const char *what;
    } refused[] = {
        {SZFThumbnailRaw(ident, side, side, SZFBytes(7, SZFriendsFrameThumbnailMax + 1)), "data over 64,000 bytes"},
        {SZFThumbnailRaw(ident, side, side, SZFBytes(7, 22)), "data shorter than any QOI stream"},
        {SZFThumbnailRaw(ident, [NSData data], side, SZFBytes(7, 100)), "no width"},
        {SZFThumbnailRaw(ident, side, [NSData data], SZFBytes(7, 100)), "no height"},
        {SZFThumbnailRaw(ident, SZFBytes(0, 3), side, SZFBytes(7, 100)), "a three-byte width"},
        {SZFThumbnailRaw(SZFBytes(1, 15), side, side, SZFBytes(7, 100)), "a short id"},
    };
    for (size_t i = 0; i < sizeof refused / sizeof refused[0]; i++) {
        SZF_CHECK(SZFriendsDecodeFrame(refused[i].plaintext, &error) == nil &&
                      error.code == SZFriendsSessionErrorFrameInvalid,
                  @"refused: %s", refused[i].what);
    }
    SZF_CHECK(SZFriendsEncodeFrame(SZFThumbnailFrame(1, SZFriendsFrameThumbnailMax + 1), NULL) == nil,
              @"the encoder refuses an oversized preview too");
}

static void SZFTestMinorNegotiation(void) {
    uint16_t negotiated = 99;
    SZF_CHECK(SZFriendsNegotiateMinor(0, SZFriendsSessionMinor, 0, 0, &negotiated) && negotiated == 0,
              @"a minor-0 peer negotiates 0, so it is never sent a THUMBNAIL");
    SZF_CHECK(SZFriendsNegotiateMinor(0, SZFriendsSessionMinor, 0, 7, &negotiated) && negotiated == 4,
              @"a newer peer meets us at 4");
    SZF_CHECK(SZFriendsNegotiateMinor(0, SZFriendsSessionMinor, 0, 1, &negotiated) && negotiated == 1,
              @"a minor-1 peer negotiates 1: THUMBNAIL but never a CHAIN");
}

static void SZFTestThumbnailsWaitBehindMessages(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, bob)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:nil
                                                    policy:nil];
    pair.initiatorStream.preferredWriteSize = 1024; // a small in-flight budget, like an L2CAP link
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    SZFOnQueue(pair.queue, ^{
        for (uint8_t i = 1; i <= 3; i++) SZF_CHECK([pair.initiator sendFrame:SZFThumbnailFrame(i, 60000)], @"queued");
        SZF_CHECK([pair.initiator sendFrame:SZFMessageFrame(@"typed after dropping three files")], @"message");
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5, ^BOOL { return pair.responderFrames.count == 4; }), @"all four arrive");
    SZFOnQueue(pair.queue, ^{
        NSUInteger message = NSNotFound, lastThumbnail = 0;
        for (NSUInteger i = 0; i < pair.responderFrames.count; i++) {
            if (pair.responderFrames[i].type == SZFriendsFrameTypeMessage) message = i;
            if (pair.responderFrames[i].type == SZFriendsFrameTypeThumbnail) lastThumbnail = i;
        }
        // The first preview was already on the link; the message overtakes the two still queued.
        SZF_CHECK(message == 1 && lastThumbnail == 3, @"the message arrived at %lu of 4", (unsigned long)message);
        SZF_CHECK([[pair.responderFrames[3] dataForTag:SZFriendsFieldData] isEqualToData:SZFBytes(3, 60000)],
                  @"previews keep their order");
        [pair.initiator close];
    });
    SZF_CHECK([pair waitUntilBothClosed], @"closed");
}

void SZFRunThumbnailFrameTests(void) {
    SZFTestThumbnailCodec();
    SZFTestMinorNegotiation();
    SZFTestThumbnailsWaitBehindMessages();
}
