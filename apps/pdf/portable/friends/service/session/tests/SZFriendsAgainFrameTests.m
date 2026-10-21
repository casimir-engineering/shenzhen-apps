// AGAIN (minor 3, ADR 0016): the codec's bounds on an again message, which patterns may carry it, and the largest
// message crossing a live session intact both ways. The bytes are opaque here; service/sync/SZFriendsAgain.m decodes
// them.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static NSData *SZFAgainRaw(NSData *_Nullable message) {
    uint8_t type = SZFriendsFrameTypeAgain;
    NSMutableData *plaintext = [NSMutableData dataWithBytes:&type length:1];
    if (message != nil) {
        uint8_t header[3] = {SZFriendsFieldAgain, (uint8_t)(message.length >> 8), (uint8_t)message.length};
        [plaintext appendBytes:header length:3];
        [plaintext appendData:message];
    }
    return plaintext;
}

static SZFriendsFrame *SZFAgainFrame(uint8_t fill, NSUInteger bytes) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeAgain
                                  fields:@{@(SZFriendsFieldAgain) : SZFBytes(fill, bytes)}];
}

static void SZFTestAgainCodec(void) {
    SZF_CHECK(SZFriendsFrameTypeAgain == 27 && SZFriendsFieldAgain == 36, @"wire numbers");
    NSError *error = nil;
    SZFriendsFrame *frame = SZFriendsDecodeFrame(SZFAgainRaw(SZFBytes(5, 1)), &error);
    SZF_CHECK(frame.type == SZFriendsFrameTypeAgain &&
                  [[frame dataForTag:SZFriendsFieldAgain] isEqualToData:SZFBytes(5, 1)],
              @"a one-byte AGAIN decodes: %@", error);
    NSData *largest = SZFAgainRaw(SZFBytes(5, SZFriendsFrameAgainMax));
    SZF_CHECK(SZFriendsFrameAgainMax == 64000 && largest.length <= SZFriendsFramePlaintextMax &&
                  SZFriendsDecodeFrame(largest, NULL) != nil, @"the largest message fits one transport message");
    SZF_CHECK(SZFriendsDecodeFrame(SZFAgainRaw(nil), NULL) == nil, @"an AGAIN without its message is refused");
    SZF_CHECK(SZFriendsDecodeFrame(SZFAgainRaw([NSData data]), NULL) == nil, @"an empty one too");
    SZF_CHECK(SZFriendsDecodeFrame(SZFAgainRaw(SZFBytes(5, SZFriendsFrameAgainMax + 1)), NULL) == nil,
              @"over the limit is refused");
    SZF_CHECK(SZFriendsEncodeFrame(SZFAgainFrame(5, SZFriendsFrameAgainMax + 1), NULL) == nil,
              @"the encoder refuses an oversized message too");
}

static void SZFTestAgainOverASession(void) {
    SZFriendsIdentity *mei = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *raph = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, raph)
                                         initiatorIdentity:mei
                                         responderIdentity:raph
                                             publicProfile:nil
                                                    policy:nil];
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([pair.responder sendFrame:SZFAgainFrame(9, SZFriendsFrameAgainMax)], @"the responder sends one");
        SZF_CHECK([pair.initiator sendFrame:SZFAgainFrame(8, 40)], @"and the initiator another");
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5, ^BOOL {
                  return pair.initiatorFrames.count == 1 && pair.responderFrames.count == 1;
              }), @"each side receives the other's");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([[pair.initiatorFrames.firstObject dataForTag:SZFriendsFieldAgain]
                      isEqualToData:SZFBytes(9, SZFriendsFrameAgainMax)], @"the largest arrives intact");
        [pair.initiator close];
    });
    SZF_CHECK([pair waitUntilBothClosed], @"closed");

    // NN names nobody: nobody a file was sent to is on the other end.
    SZFChannelPair *nn = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeNN, nil)
                                       initiatorIdentity:mei
                                       responderIdentity:raph
                                           publicProfile:nil
                                                  policy:nil];
    SZFOnQueue(nn.queue, ^{
        SZF_CHECK(![nn.initiator sendFrame:SZFAgainFrame(1, 100)], @"NN refuses an AGAIN");
    });
}

void SZFRunAgainFrameTests(void) {
    SZFTestAgainCodec();
    SZFTestAgainOverASession();
}
