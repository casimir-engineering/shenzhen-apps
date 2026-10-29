// Liveness while a transfer runs (ADR 0018 § 7), as the Rust core's tests/session_liveness.rs checks it: PING after a
// keepalive without sending, a session closed after the silence limit (Bluetooth: longer) without hearing anything,
// only while watching, never because this side itself stalled, and which transfers watch. The intervals are shortened
// a hundredfold-ish so the suite stays quick; the production values are checked once.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsSecureChannelInternal.h"

static const NSTimeInterval SZFKeepalive = 0.05, SZFSilence = 0.4, SZFSilenceBluetooth = 0.6;

static SZFChannelPair *SZFLivePair(SZFriendsRouteMethod route) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsHandshakeOptions *options = SZFOptions(SZFriendsHandshakeIK, bob);
    options.route = route;
    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:options
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:nil
                                                    policy:nil];
    for (SZFriendsSecureChannel *channel in @[ pair.initiator, pair.responder ]) {
        [channel setKeepaliveInterval:SZFKeepalive silence:SZFSilence bluetooth:SZFSilenceBluetooth];
    }
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"established");
    return pair;
}

// The route goes quiet one way: nothing the responder writes reaches the initiator any more.
static void SZFSilenceResponder(SZFChannelPair *pair) {
    pair.responderStream.filter = ^NSData *(NSData *write, uint64_t offset) {
        (void)write, (void)offset;
        return nil;
    };
}

static NSTimeInterval SZFNow(void) {
    return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
}

static void SZFTestDefaults(void) {
    SZF_CHECK(SZFriendsKeepaliveInterval == 1 && SZFriendsSilenceLimit == 8 && SZFriendsSilenceLimitBluetooth == 12,
              @"ADR 0018 § 7's numbers, as szfriends_wire::consts has them");
}

static void SZFTestBothSidesPingAndNobodyCloses(void) {
    SZFChannelPair *pair = SZFLivePair(SZFriendsRouteMethodLAN);
    __block NSUInteger beforeInitiator = 0, beforeResponder = 0;
    SZFOnQueue(pair.queue, ^{
        beforeInitiator = pair.initiatorStream.writeCount;
        beforeResponder = pair.responderStream.writeCount;
        [pair.initiator setLivenessKeepalive:YES watch:YES];
        [pair.responder setLivenessKeepalive:YES watch:YES];
    });
    // Three silence limits without a frame from either side: PINGs only, about one per keepalive each way.
    [NSThread sleepForTimeInterval:SZFSilence * 3];
    SZFOnQueue(pair.queue, ^{
        NSUInteger initiator = pair.initiatorStream.writeCount - beforeInitiator;
        NSUInteger responder = pair.responderStream.writeCount - beforeResponder;
        NSUInteger expected = (NSUInteger)(SZFSilence * 3 / SZFKeepalive);
        SZF_CHECK(initiator >= expected / 2 && initiator <= expected + 2 && responder >= expected / 2 &&
                      responder <= expected + 2,
                  @"pings %lu and %lu, about %lu expected", (unsigned long)initiator, (unsigned long)responder,
                  (unsigned long)expected);
        SZF_CHECK(pair.initiatorFrames.count == 0 && pair.responderFrames.count == 0, @"PING never reaches onFrame");
        SZF_CHECK(!pair.initiatorClosed && !pair.responderClosed, @"nobody closes");
        [pair.initiator setLivenessKeepalive:NO watch:NO];
        [pair.responder setLivenessKeepalive:NO watch:NO];
        beforeInitiator = pair.initiatorStream.writeCount;
    });
    [NSThread sleepForTimeInterval:SZFKeepalive * 4];
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(pair.initiatorStream.writeCount == beforeInitiator, @"no PING once no transfer runs");
    });
}

static void SZFTestSilentRouteCloses(SZFriendsRouteMethod route, NSTimeInterval limit) {
    SZFChannelPair *pair = SZFLivePair(route);
    __block NSTimeInterval started = 0;
    SZFOnQueue(pair.queue, ^{
        SZFSilenceResponder(pair);
        [pair.responder setLivenessKeepalive:YES watch:NO];
        [pair.initiator setLivenessKeepalive:YES watch:YES];
        started = SZFNow();
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, limit * 4,
                           ^BOOL {
                               return pair.initiatorClosed;
                           }),
              @"a silent route closes (route %ld)", (long)route);
    NSTimeInterval took = SZFNow() - started;
    SZF_CHECK(took >= limit - 0.01 && took < limit + 0.25, @"closed after %.3f s, the limit is %.3f s", took, limit);
    SZF_CHECK(pair.initiatorError.code == SZFriendsSessionErrorSilent, @"silent: %@", pair.initiatorError);
    SZF_CHECK(pair.initiatorStream.closed, @"the link closes with it, so the helper redials");
}

static void SZFTestOnlyAWatchingSessionCloses(void) {
    SZFChannelPair *pair = SZFLivePair(SZFriendsRouteMethodLAN);
    SZFOnQueue(pair.queue, ^{
        SZFSilenceResponder(pair);
        // Pinging but not watching: a sender whose bytes are all confirmed, an offer waiting for its answer.
        [pair.initiator setLivenessKeepalive:YES watch:NO];
    });
    [NSThread sleepForTimeInterval:SZFSilence * 2];
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(!pair.initiatorClosed, @"not watching: open whatever the silence");
        SZF_CHECK(!pair.initiator.watchingLiveness, @"not watching");
        // Watching starts the count afresh, whatever came before.
        [pair.initiator setLivenessKeepalive:YES watch:YES];
        SZF_CHECK(pair.initiator.watchingLiveness, @"watching");
    });
    [NSThread sleepForTimeInterval:SZFSilence / 2];
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(!pair.initiatorClosed, @"the limit counts from when watching started");
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, SZFSilence * 3,
                           ^BOOL {
                               return pair.initiatorClosed;
                           }),
              @"then closes");
}

static void SZFTestThisSideStallingIsNotSilence(void) {
    SZFChannelPair *pair = SZFLivePair(SZFriendsRouteMethodLAN);
    SZFOnQueue(pair.queue, ^{
        SZFSilenceResponder(pair);
        [pair.initiator setLivenessKeepalive:YES watch:YES];
    });
    // The queue is busy for longer than the limit (a long disk operation): the bytes the peer sent may be unread.
    dispatch_async(pair.queue, ^{
        [NSThread sleepForTimeInterval:SZFSilence * 1.5];
    });
    [NSThread sleepForTimeInterval:SZFSilence * 1.5 + SZFKeepalive];
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(!pair.initiatorClosed, @"a stall on this side does not count as the peer's silence");
    });
    SZF_CHECK(SZFWaitUntil(pair.queue, SZFSilence * 3,
                           ^BOOL {
                               return pair.initiatorClosed;
                           }),
              @"still nothing afterwards: closed");
    SZF_CHECK(pair.initiatorError.code == SZFriendsSessionErrorSilent, @"silent: %@", pair.initiatorError);
}

static void SZFTestReleasedPeerTrafficKeepsItOpen(void) {
    // The responder stands for a released peer: it never pings, but sends what its transfer requires.
    SZFChannelPair *pair = SZFLivePair(SZFriendsRouteMethodLAN);
    SZFOnQueue(pair.queue, ^{
        [pair.initiator setLivenessKeepalive:YES watch:YES];
    });
    for (int i = 0; i < 8; i++) {
        [NSThread sleepForTimeInterval:SZFSilence / 3];
        SZFOnQueue(pair.queue, ^{
            [pair.responder sendFrame:SZFMessageFrame(@"progress")];
        });
    }
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK(!pair.initiatorClosed, @"its own traffic keeps the session open");
    });
    // It goes quiet: closed within the limit.
    SZF_CHECK(SZFWaitUntil(pair.queue, SZFSilence * 3,
                           ^BOOL {
                               return pair.initiatorClosed;
                           }),
              @"closed once it goes quiet");
}

static void SZFTestTransfersWatchOnlyWhileThePeerOwesSomething(void) {
    NSData *offer = SZFBytes(7, 16);
    SZFriendsChunkSender *sender = [[SZFriendsChunkSender alloc] initWithOfferID:offer size:10000 resumeOffset:0
                                                                      chunkBytes:1000 window:4000];
    SZFriendsChunkReceiver *receiver = [[SZFriendsChunkReceiver alloc] initWithOfferID:offer size:10000
                                                                        verifiedOffset:0 chunkBytes:1000
                                                                                window:4000];
    BOOL keepalive = YES, watch = YES;
    SZFriendsTransferLiveness(@[], @[], &keepalive, &watch);
    SZF_CHECK(!keepalive && !watch, @"no transfer: nothing");
    SZFriendsTransferLiveness(@[ sender ], @[ receiver ], &keepalive, &watch);
    SZF_CHECK(keepalive && !watch, @"accepted, nothing sent yet: ping, but nothing is due from the peer");
    SZFriendsFrame *chunk = [sender chunkFrameWithData:SZFBytes(1, 1000)];
    SZFriendsTransferLiveness(@[ sender ], @[], &keepalive, &watch);
    SZF_CHECK(keepalive && watch, @"PROGRESS is due for the bytes sent");
    SZFriendsTransferLiveness(@[], @[ receiver ], &keepalive, &watch);
    SZF_CHECK(keepalive && !watch, @"a released sender may hash before its first chunk");
    SZF_CHECK([receiver acceptChunkFrame:chunk error:NULL] != nil, @"chunk");
    SZFriendsTransferLiveness(@[], @[ receiver ], &keepalive, &watch);
    SZF_CHECK(keepalive && watch, @"chunks are arriving");
    SZF_CHECK([sender handleProgressFrame:[receiver progressFrameForDurableOffset:1000] error:NULL], @"progress");
    SZFriendsTransferLiveness(@[ sender ], @[], &keepalive, &watch);
    SZF_CHECK(keepalive && !watch, @"everything sent is confirmed");
    // The whole file arrived: between DONE and ACK a released receiver checks it in silence.
    for (uint64_t offset = 1000; offset < 10000; offset += 1000) {
        SZFriendsFrame *frame = [SZFriendsFrame
            frameWithType:SZFriendsFrameTypeChunk
                   fields:@{
                       @(SZFriendsFieldID) : offer,
                       @(SZFriendsFieldOffset) : [SZFriendsFrame fieldWithUInt64:offset tag:SZFriendsFieldOffset],
                       @(SZFriendsFieldData) : SZFBytes(1, 1000),
                   }];
        SZF_CHECK([receiver acceptChunkFrame:frame error:NULL] != nil, @"chunk at %llu", (unsigned long long)offset);
        [receiver progressFrameForDurableOffset:offset + 1000];
    }
    SZFriendsTransferLiveness(@[], @[ receiver ], &keepalive, &watch);
    SZF_CHECK(keepalive && !watch, @"complete: nothing more is due");
}

void SZFRunChannelLivenessTests(void) {
    SZFTestDefaults();
    SZFTestBothSidesPingAndNobodyCloses();
    SZFTestSilentRouteCloses(SZFriendsRouteMethodLAN, SZFSilence);
    SZFTestSilentRouteCloses(SZFriendsRouteMethodPeerToPeerWiFi, SZFSilence);
    SZFTestSilentRouteCloses(SZFriendsRouteMethodBluetooth, SZFSilenceBluetooth);
    SZFTestOnlyAWatchingSessionCloses();
    SZFTestThisSideStallingIsNotSilence();
    SZFTestReleasedPeerTrafficKeepsItOpen();
    SZFTestTransfersWatchOnlyWhileThePeerOwesSomething();
}
