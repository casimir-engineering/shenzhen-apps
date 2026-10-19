// JOIN (PROTOCOL.md § Joining): the codec's bounds on a join message, NN carrying it both ways as often as the
// exchange needs, and IK refusing it. The message's bytes are opaque here; the identity area reads them.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static NSData *SZFJoinRaw(NSData *_Nullable message) {
    uint8_t type = SZFriendsFrameTypeJoin;
    NSMutableData *plaintext = [NSMutableData dataWithBytes:&type length:1];
    if (message != nil) {
        uint8_t header[3] = {SZFriendsFieldJoin, (uint8_t)(message.length >> 8), (uint8_t)message.length};
        [plaintext appendBytes:header length:3];
        [plaintext appendData:message];
    }
    return plaintext;
}

static SZFriendsFrame *SZFJoinFrame(uint8_t fill, NSUInteger bytes) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeJoin
                                  fields:@{@(SZFriendsFieldJoin) : SZFBytes(fill, bytes)}];
}

static void SZFTestJoinCodec(void) {
    SZF_CHECK(SZFriendsFrameTypeJoin == 25 && SZFriendsFieldJoin == 34, @"wire numbers");
    SZF_CHECK(SZFriendsFrameJoinMax == 1000, @"one join message fits a signalling Frame item");
    SZF_CHECK(SZFriendsDecodeFrame(SZFJoinRaw(SZFBytes(2, 1)), NULL) != nil, @"one byte decodes");
    SZF_CHECK(SZFriendsDecodeFrame(SZFJoinRaw(SZFBytes(2, SZFriendsFrameJoinMax)), NULL) != nil, @"the largest");
    SZF_CHECK(SZFriendsDecodeFrame(SZFJoinRaw(nil), NULL) == nil, @"a JOIN without its message is refused");
    SZF_CHECK(SZFriendsDecodeFrame(SZFJoinRaw(SZFBytes(2, SZFriendsFrameJoinMax + 1)), NULL) == nil, @"too big");
    SZF_CHECK([SZFriendsEncodeFrame(SZFJoinFrame(2, 5), NULL) isEqualToData:SZFJoinRaw(SZFBytes(2, 5))],
              @"encoding: type 25, then field 34");
}

static void SZFTestJoinOverSessions(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *bob = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *nn = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeNN, nil)
                                       initiatorIdentity:alice
                                       responderIdentity:bob
                                           publicProfile:nil
                                                  policy:nil];
    [nn start];
    SZF_CHECK([nn waitUntilBothEstablished], @"NN established");
    SZFOnQueue(nn.queue, ^{
        for (uint8_t i = 0; i < 3; i++) {
            SZF_CHECK([nn.initiator sendFrame:SZFJoinFrame(i, 100)], @"the new computer sends %d", i);
            SZF_CHECK([nn.responder sendFrame:SZFJoinFrame(i, SZFriendsFrameJoinMax)], @"the other answers %d", i);
        }
    });
    SZF_CHECK(SZFWaitUntil(nn.queue, 5, ^BOOL {
                  return nn.initiatorFrames.count == 3 && nn.responderFrames.count == 3;
              }), @"every JOIN arrives, both ways");
    SZFOnQueue(nn.queue, ^{ [nn.initiator close]; });
    SZF_CHECK([nn waitUntilBothClosed], @"closed");

    // A session that names its peers carries no join message.
    SZFChannelPair *ik = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, bob)
                                       initiatorIdentity:alice
                                       responderIdentity:bob
                                           publicProfile:nil
                                                  policy:nil];
    [ik start];
    SZF_CHECK([ik waitUntilBothEstablished], @"IK established");
    SZFOnQueue(ik.queue, ^{
        SZF_CHECK(![ik.initiator sendFrame:SZFJoinFrame(1, 10)], @"IK refuses a JOIN");
        [ik.initiator close];
    });
    SZF_CHECK([ik waitUntilBothClosed], @"closed");
}

void SZFRunJoinFrameTests(void) {
    SZFTestJoinCodec();
    SZFTestJoinOverSessions();
}
