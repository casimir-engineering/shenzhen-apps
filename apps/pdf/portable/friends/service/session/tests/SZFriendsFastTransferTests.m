// ADR 0018 § 1 and § 6 in the channel: fast transfers only when both sides negotiated minor 4 and set the capability
// bit; toward anyone else no minor-4 frame leaves and the tree's OFFER fields are stripped; one received outside such a
// session closes it; and a lane's token travels in IK message 1 to the responder.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsSecureChannelInternal.h"

static SZFChannelPair *SZFPair(SZFriendsCapabilities initiator, SZFriendsCapabilities responder, NSData *lane) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsHandshakeOptions *options = SZFOptions(SZFriendsHandshakeIK, bob);
    options.lane = lane;
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:options
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:nil
                                                    policy:nil];
    pair.initiator.localCapabilities = initiator;
    pair.responder.localCapabilities = responder;
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    return pair;
}

static SZFriendsFrame *SZFHashes(void) {
    uint8_t index[4] = {0};
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeHashes
                                  fields:@{@(SZFriendsFieldID) : SZFBytes(1, 16),
                                           @(SZFriendsFieldIndex) : [NSData dataWithBytes:index length:4],
                                           @(SZFriendsFieldHashes) : SZFBytes(2, 32)}];
}

static SZFriendsFrame *SZFOfferWithTree(void) {
    uint8_t shift = 20;
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeOffer
                                  fields:@{@(SZFriendsFieldID) : SZFBytes(1, 16),
                                           @(SZFriendsFieldName) : [@"a.bin" dataUsingEncoding:NSUTF8StringEncoding],
                                           @(SZFriendsFieldSize) : [SZFriendsFrame fieldWithUInt64:5
                                                                                               tag:SZFriendsFieldSize],
                                           @(SZFriendsFieldDigest) : SZFBytes(3, 32),
                                           @(SZFriendsFieldTreeRoot) : SZFBytes(4, 32),
                                           @(SZFriendsFieldBlockShift) : [NSData dataWithBytes:&shift length:1]}];
}

static void SZFTestBothSidesNegotiate(void) {
    SZFChannelPair *pair = SZFPair(SZFriendsCapabilityFastTransfers, SZFriendsCapabilityFastTransfers, nil);
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.initiator.negotiatedMinor == 4 && pair.initiator.fastTransfers && pair.responder.fastTransfers,
                  @"minor 4 and fast transfers both ways");
        SZF_CHECK([pair.initiator sendFrame:SZFHashes()] && [pair.initiator sendFrame:SZFOfferWithTree()], @"sent");
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, 5, ^BOOL { return pair.responderFrames.count == 2; }), @"both arrive");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([pair.responderFrames[1] dataForTag:SZFriendsFieldTreeRoot] != nil, @"the tree goes with the offer");
        SZF_CHECK(!pair.responderClosed, @"open");
    });
}

static void SZFTestOneSideWithoutStaysOld(void) {
    for (int which = 0; which < 2; which++) {
        SZFChannelPair *pair = which == 0 ? SZFPair(SZFriendsCapabilityFastTransfers, 0, nil)
                                          : SZFPair(0, SZFriendsCapabilityFastTransfers, nil);
        SZFOnQueue(pair.queue, ^{
            SZF_CHECK(pair.initiator.negotiatedMinor == 4 && !pair.initiator.fastTransfers &&
                          !pair.responder.fastTransfers,
                      @"minor 4 alone is not enough");
            SZF_CHECK(![pair.initiator sendFrame:SZFHashes()], @"no minor-4 frame toward a peer without them");
            SZF_CHECK([pair.initiator sendFrame:SZFOfferWithTree()], @"the offer itself goes");
        });
        SZF_CHECK(SZFWaitUntil(pair.queue, 5, ^BOOL { return pair.responderFrames.count == 1; }), @"offer arrives");
        SZFOnQueue(pair.queue, ^{
            SZFriendsFrame *offer = pair.responderFrames[0];
            SZF_CHECK(offer.type == SZFriendsFrameTypeOffer && [offer dataForTag:SZFriendsFieldTreeRoot] == nil &&
                          [offer dataForTag:SZFriendsFieldBlockShift] == nil,
                      @"stripped of the tree's fields");
        });
    }
}

static void SZFTestAFastFrameOutsideCloses(void) {
    // The initiator believes in fast transfers (as a broken or hostile peer would); the responder never set the bit.
    SZFChannelPair *pair = SZFPair(SZFriendsCapabilityFastTransfers, 0, nil);
    SZFOnQueue(pair.queue, ^{
        pair.initiator.remoteCapabilities = SZFriendsCapabilityFastTransfers;
        SZF_CHECK([pair.initiator sendFrame:SZFHashes()], @"sent anyway");
    });
    SZF_CHECK([pair waitUntilBothClosed], @"the receiver closes");
    SZF_CHECK(pair.responderFrames.count == 0, @"and never hands it on");
    SZF_CHECK([pair.initiatorError.userInfo[SZFriendsSessionCloseReasonKey] integerValue] ==
                  SZFriendsCloseReasonProtocolError,
              @"as a protocol error: %@", pair.initiatorError);
}

static void SZFTestLaneTokenReachesTheResponder(void) {
    NSData *h = SZFBytes(0x5a, 64);
    NSData *token = SZFriendsLaneToken(h, 1);
    SZF_CHECK(token.length == 16 && SZFriendsLaneToken(SZFBytes(1, 63), 1) == nil, @"16 bytes from a 64-byte hash");
    SZF_CHECK(![token isEqualToData:SZFriendsLaneToken(h, 2)], @"one per index");
    SZFChannelPair *pair = SZFPair(SZFriendsCapabilityFastTransfers, SZFriendsCapabilityFastTransfers, token);
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([pair.responder.presentedLane isEqualToData:token], @"the responder sees the token");
        SZF_CHECK(pair.initiator.presentedLane == nil, @"only the responder");
    });
    SZFChannelPair *plain = SZFPair(SZFriendsCapabilityFastTransfers, SZFriendsCapabilityFastTransfers, nil);
    SZFOnQueue(plain.queue, ^{
        SZF_CHECK(plain.responder.presentedLane == nil, @"no lane, no token");
    });
}

void SZFRunFastTransferTests(void) {
    SZFTestBothSidesNegotiate();
    SZFTestOneSideWithoutStaysOld();
    SZFTestAFastFrameOutsideCloses();
    SZFTestLaneTokenReachesTheResponder();
}
