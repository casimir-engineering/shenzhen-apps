// CHAIN (minor 2, ADR 0012): the codec's bounds on a device chain, which patterns may carry it, and the largest chain
// crossing a live session intact. The chain's bytes are opaque here; the identity area verifies them.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static NSData *SZFChainRaw(NSData *_Nullable chain) {
    uint8_t type = SZFriendsFrameTypeChain;
    NSMutableData *plaintext = [NSMutableData dataWithBytes:&type length:1];
    if (chain != nil) {
        uint8_t header[3] = {SZFriendsFieldChain, (uint8_t)(chain.length >> 8), (uint8_t)chain.length};
        [plaintext appendBytes:header length:3];
        [plaintext appendData:chain];
    }
    return plaintext;
}

static SZFriendsFrame *SZFChainFrame(uint8_t fill, NSUInteger bytes) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeChain
                                  fields:@{@(SZFriendsFieldChain) : SZFBytes(fill, bytes)}];
}

static void SZFTestChainCodec(void) {
    SZF_CHECK(SZFriendsFrameTypeChain == 24 && SZFriendsFieldChain == 33, @"wire numbers");
    SZF_CHECK(SZFriendsSessionMinor >= 2, @"CHAIN is minor 2");
    NSError *error = nil;
    SZFriendsFrame *frame = SZFriendsDecodeFrame(SZFChainRaw(SZFBytes(5, 300)), &error);
    SZF_CHECK(frame.type == SZFriendsFrameTypeChain &&
                  [[frame dataForTag:SZFriendsFieldChain] isEqualToData:SZFBytes(5, 300)],
              @"a CHAIN decodes: %@", error);
    NSData *largest = SZFChainRaw(SZFBytes(5, SZFriendsFrameChainMax));
    SZF_CHECK(SZFriendsFrameChainMax == 64000 && largest.length <= SZFriendsFramePlaintextMax &&
                  SZFriendsDecodeFrame(largest, NULL) != nil, @"the largest chain fits one transport message");
    SZF_CHECK(SZFriendsDecodeFrame(SZFChainRaw(nil), NULL) == nil, @"a CHAIN without its chain is refused");
    SZF_CHECK(SZFriendsDecodeFrame(SZFChainRaw(SZFBytes(5, 2)), NULL) == nil, @"too short to be a chain");
    SZF_CHECK(SZFriendsDecodeFrame(SZFChainRaw(SZFBytes(5, SZFriendsFrameChainMax + 1)), NULL) == nil,
              @"over the limit is refused");
    SZF_CHECK(SZFriendsEncodeFrame(SZFChainFrame(5, SZFriendsFrameChainMax + 1), NULL) == nil,
              @"the encoder refuses an oversized chain too");
    SZF_CHECK([SZFriendsEncodeFrame(SZFChainFrame(5, 3), NULL) isEqualToData:SZFChainRaw(SZFBytes(5, 3))],
              @"encoding: type 24, then field 33");
}

static void SZFTestChainOverASession(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, bob)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:nil
                                                    policy:nil];
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.initiator.negotiatedMinor == 4 && pair.responder.negotiatedMinor == 4, @"both speak minor 4");
        SZF_CHECK([pair.responder sendFrame:SZFChainFrame(9, SZFriendsFrameChainMax)], @"the responder sends one");
        SZF_CHECK([pair.initiator sendFrame:SZFChainFrame(8, 400)], @"and the initiator its own");
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5, ^BOOL {
                  return pair.initiatorFrames.count == 1 && pair.responderFrames.count == 1;
              }), @"each side receives the other's chain");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([[pair.initiatorFrames.firstObject dataForTag:SZFriendsFieldChain]
                      isEqualToData:SZFBytes(9, SZFriendsFrameChainMax)], @"the largest chain arrives intact");
        [pair.initiator close];
    });
    SZF_CHECK([pair waitUntilBothClosed], @"closed");

    // NN names nobody, so it never carries a chain.
    SZFChannelPair *nn = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeNN, nil)
                                       initiatorIdentity:alice
                                       responderIdentity:bob
                                           publicProfile:nil
                                                  policy:nil];
    SZFOnQueue(nn.queue, ^{
        SZF_CHECK(![nn.initiator sendFrame:SZFChainFrame(1, 100)], @"NN refuses a CHAIN");
    });
}

void SZFRunChainFrameTests(void) {
    SZFTestChainCodec();
    SZFTestChainOverASession();
}
