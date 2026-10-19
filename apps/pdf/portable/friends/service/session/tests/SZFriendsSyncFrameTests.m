// SYNC (minor 2, friends-multi-device.md § Sync): the codec's bounds on a sync message, which patterns may carry it,
// and the largest message crossing a live session intact both ways. The bytes are opaque here; the sync area decodes
// them.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

static NSData *SZFSyncRaw(NSData *_Nullable message) {
    uint8_t type = SZFriendsFrameTypeSync;
    NSMutableData *plaintext = [NSMutableData dataWithBytes:&type length:1];
    if (message != nil) {
        uint8_t header[3] = {SZFriendsFieldSync, (uint8_t)(message.length >> 8), (uint8_t)message.length};
        [plaintext appendBytes:header length:3];
        [plaintext appendData:message];
    }
    return plaintext;
}

static SZFriendsFrame *SZFSyncFrame(uint8_t fill, NSUInteger bytes) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeSync
                                  fields:@{@(SZFriendsFieldSync) : SZFBytes(fill, bytes)}];
}

static void SZFTestSyncCodec(void) {
    SZF_CHECK(SZFriendsFrameTypeSync == 26 && SZFriendsFieldSync == 35, @"wire numbers");
    NSError *error = nil;
    SZFriendsFrame *frame = SZFriendsDecodeFrame(SZFSyncRaw(SZFBytes(5, 1)), &error);
    SZF_CHECK(frame.type == SZFriendsFrameTypeSync &&
                  [[frame dataForTag:SZFriendsFieldSync] isEqualToData:SZFBytes(5, 1)],
              @"a one-byte SYNC decodes: %@", error);
    NSData *largest = SZFSyncRaw(SZFBytes(5, SZFriendsFrameSyncMax));
    SZF_CHECK(SZFriendsFrameSyncMax == 64000 && largest.length <= SZFriendsFramePlaintextMax &&
                  SZFriendsDecodeFrame(largest, NULL) != nil, @"the largest message fits one transport message");
    SZF_CHECK(SZFriendsDecodeFrame(SZFSyncRaw(nil), NULL) == nil, @"a SYNC without its message is refused");
    SZF_CHECK(SZFriendsDecodeFrame(SZFSyncRaw([NSData data]), NULL) == nil, @"an empty one too");
    SZF_CHECK(SZFriendsDecodeFrame(SZFSyncRaw(SZFBytes(5, SZFriendsFrameSyncMax + 1)), NULL) == nil,
              @"over the limit is refused");
    SZF_CHECK(SZFriendsEncodeFrame(SZFSyncFrame(5, SZFriendsFrameSyncMax + 1), NULL) == nil,
              @"the encoder refuses an oversized message too");
}

static void SZFTestSyncOverASession(void) {
    SZFriendsIdentity *laptop = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *desktop = [SZFriendsIdentity szf_newIdentity];
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeIK, desktop)
                                         initiatorIdentity:laptop
                                         responderIdentity:desktop
                                             publicProfile:nil
                                                    policy:nil];
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([pair.responder sendFrame:SZFSyncFrame(9, SZFriendsFrameSyncMax)], @"the responder sends one");
        SZF_CHECK([pair.initiator sendFrame:SZFSyncFrame(8, 40)], @"and the initiator another");
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5, ^BOOL {
                  return pair.initiatorFrames.count == 1 && pair.responderFrames.count == 1;
              }), @"each side receives the other's");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([[pair.initiatorFrames.firstObject dataForTag:SZFriendsFieldSync]
                      isEqualToData:SZFBytes(9, SZFriendsFrameSyncMax)], @"the largest arrives intact");
        [pair.initiator close];
    });
    SZF_CHECK([pair waitUntilBothClosed], @"closed");

    // NN names nobody: no device of anyone's is on the other end.
    SZFChannelPair *nn = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeNN, nil)
                                       initiatorIdentity:laptop
                                       responderIdentity:desktop
                                           publicProfile:nil
                                                  policy:nil];
    SZFOnQueue(nn.queue, ^{
        SZF_CHECK(![nn.initiator sendFrame:SZFSyncFrame(1, 100)], @"NN refuses a SYNC");
    });
}

void SZFRunSyncFrameTests(void) {
    SZFTestSyncCodec();
    SZFTestSyncOverASession();
}
