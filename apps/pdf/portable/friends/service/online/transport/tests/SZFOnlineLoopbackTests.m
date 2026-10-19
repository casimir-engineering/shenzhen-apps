// Two peer connections in this process over 127.0.0.1: ADR 0001 with Noise over the data channel and 50 MiB with
// its digest, the order of the delegate's callbacks, the fingerprint rule against a host in the middle, links
// offering nothing private, and cancellation.

#import "SZFOnlineTestSupport.h"

static const uint64_t kDirectBytes = 50ull * 1024 * 1024;

static SZFriendsOnlineDataChannelTransport *LoopbackTransport(void) {
    return [[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"];
}

static NSString *WithFingerprint(NSString *sdp, NSData *fingerprint) {
    NSMutableArray<NSString *> *hex = [NSMutableArray array];
    const uint8_t *bytes = fingerprint.bytes;
    for (NSUInteger i = 0; i < fingerprint.length; i++) [hex addObject:[NSString stringWithFormat:@"%02X", bytes[i]]];
    NSMutableArray<NSString *> *lines = [[sdp componentsSeparatedByString:@"\r\n"] mutableCopy];
    for (NSUInteger i = 0; i < lines.count; i++) {
        if ([lines[i] hasPrefix:@"a=fingerprint:"]) {
            lines[i] = [@"a=fingerprint:sha-256 " stringByAppendingString:[hex componentsJoinedByString:@":"]];
        }
    }
    return [lines componentsJoinedByString:@"\r\n"];
}

static void CheckOrder(SZFORecorder *events, NSString *side) {
    SZFO_CHECK([events.events.firstObject isEqualToString:@"description"], "%@: the description comes first: %@", side,
               events.events);
    NSCountedSet<NSString *> *counts = [[NSCountedSet alloc] initWithArray:events.events];
    SZFO_CHECK([counts countForObject:@"description"] == 1 && [counts countForObject:@"gathered"] <= 1 &&
                   [counts countForObject:@"failed"] <= 1, "%@: %@", side, events.events);
    NSUInteger firstStream = [events.events indexOfObject:@"stream"];
    SZFO_CHECK(firstStream != NSNotFound && firstStream > 0, "%@: a stream after the description", side);
    SZFO_CHECK(![events.sdp containsString:@"a=candidate"], "%@: candidates trickle, never in the SDP", side);
    SZFO_CHECK(events.fingerprint.length == SZFriendsOnlineFingerprintLength, "%@", side);
    SZFriendsOnlineDescription *parsed = [SZFriendsOnlineDescription descriptionWithSDP:events.sdp error:NULL];
    SZFO_CHECK([parsed.fingerprint isEqualToData:events.fingerprint], "%@: the fingerprint beside the SDP is its own",
               side);
    for (NSNumber *technique in events.techniques) {
        SZFO_CHECK(technique.integerValue == SZFriendsOnlineTechniqueHostPrivate, "%@: loopback host only", side);
    }
}

static void TestDirectTransfer(void) {
    SZFOPair *pair = [[SZFOPair alloc] initWithTransport:LoopbackTransport()
                                                 purpose:SZFriendsOnlinePurposeFriend
                                                    kind:SZFriendsOnlineConnectionDirect];
    SZFO_CHECK([pair start]);
    SZFO_CHECK([pair waitForStreams], "both sides open a stream over 127.0.0.1 (%@ / %@)", pair.offererEvents.error,
               pair.answererEvents.error);
    __block id<SZFriendsByteStream> initiator = nil, responder = nil;
    SZFOOnQueue(pair.offererQueue, ^{
        CheckOrder(pair.offererEvents, @"offerer");
        initiator = pair.offererEvents.streams.firstObject;
        SZFriendsOnlineRoute route = pair.offerer.route;
        SZFO_CHECK(route.method == SZFriendsRouteMethodInternet &&
                       route.technique == SZFriendsOnlineTechniqueHostPrivate && !route.ipv6,
                   "a direct route: class 4, technique %ld", (long)route.technique);
        SZFO_CHECK(pair.offererEvents.openedRoute.technique == route.technique);
        SZFO_CHECK(pair.offerer.localPort != 0 && pair.offerer.localFingerprint.length == 32);
        SZFO_CHECK(initiator.preferredWriteSize == SZFriendsOnlineMessageMax);
        id<SZFriendsOnlineConnectionExtras> extras = (id<SZFriendsOnlineConnectionExtras>)pair.offerer;
        SZFO_CHECK(extras.directPhase.started && extras.directPhase.stopped && !extras.directPhase.expired,
                   "the direct phase ran from the answer to the first stream");
    });
    SZFOOnQueue(pair.answererQueue, ^{
        CheckOrder(pair.answererEvents, @"answerer");
        responder = pair.answererEvents.streams.firstObject;
        SZFO_CHECK(pair.answererEvents.openedRoute.method == SZFriendsRouteMethodInternet);
    });
    NSTimeInterval seconds = 0;
    BOOL moved = initiator && responder && SZFOTransfer(initiator, responder, kDirectBytes, 10, &seconds);
    SZFO_CHECK(moved, "50 MiB under Noise IK with its BLAKE2b digest");
    if (moved) printf("  50 MiB over the loopback data channel in %.2f s\n", seconds);

    // libjuice takes 30 remote candidates; the transport refuses the rest instead of letting the stack drop them.
    SZFOOnQueue(pair.offererQueue, ^{
        NSError *error = nil;
        NSUInteger accepted = 0;
        for (unsigned port = 41000; port < 41040; port++) {
            NSString *line = [NSString stringWithFormat:@"candidate:7 1 UDP 1 127.0.0.1 %u typ host", port];
            if (![pair.offerer addRemoteCandidate:line technique:SZFriendsOnlineTechniquePredictedPort error:&error]) {
                break;
            }
            accepted++;
        }
        SZFO_CHECK(accepted > 0 && accepted < 30 && error.code == SZFriendsOnlineErrorCandidateRefused,
                   "SZFriendsOnlineRemoteCandidateMax across every source (%lu accepted)", (unsigned long)accepted);
        SZFO_CHECK(pair.offererEvents.error == nil, "a refused candidate leaves the connection running");
    });

    // A second answer is refused and ends the attempt: the authenticated exchange carries exactly one.
    SZFOOnQueue(pair.offererQueue, ^{
        NSError *error = nil;
        SZFO_CHECK(![pair.offerer applyRemoteAnswerSDP:pair.answererEvents.sdp
                                     remoteFingerprint:pair.answererEvents.fingerprint
                                                 error:&error] &&
                   error.code == SZFriendsOnlineErrorDescriptionInvalid);
    });
    SZFO_CHECK(SZFOWaitUntil(pair.offererQueue, 2, ^BOOL {
        return pair.offererEvents.error.code == SZFriendsOnlineErrorDescriptionInvalid;
    }), "and the delegate hears the same error");
    [pair close];
}

static void TestOffererAppliesNothingEarly(void) {
    SZFOPair *pair = [[SZFOPair alloc] initWithTransport:LoopbackTransport()
                                                 purpose:SZFriendsOnlinePurposeFriend
                                                    kind:SZFriendsOnlineConnectionDirect];
    pair.rewriteOffer = ^NSString *(NSString *sdp) {
        (void)sdp;
        return nil; // the answerer never opens
    };
    SZFO_CHECK([pair start]);
    SZFO_CHECK(SZFOWaitUntil(pair.offererQueue, 5, ^BOOL {
        return pair.offererEvents.sdp != nil;
    }));
    SZFOOnQueue(pair.offererQueue, ^{
        NSError *error = nil;
        SZFO_CHECK(![pair.offerer addRemoteCandidate:@"candidate:1 1 UDP 2122317823 127.0.0.1 40000 typ host"
                                           technique:SZFriendsOnlineTechniqueHostPrivate
                                               error:&error] &&
                   error.code == SZFriendsOnlineErrorNotAuthorized,
                   "no remote candidate before IK message 2 authenticated the responder");
    });
    [pair close];
}

static void TestFingerprintRule(void) {
    NSData *swapped = SZFOBytes(0x5A, SZFriendsOnlineFingerprintLength);
    // A host in the middle swaps the SDP's fingerprint, but the authenticated one is the offerer's: refused before
    // any peer connection exists.
    SZFOPair *rewritten = [[SZFOPair alloc] initWithTransport:LoopbackTransport()
                                                      purpose:SZFriendsOnlinePurposeFriend
                                                         kind:SZFriendsOnlineConnectionDirect];
    rewritten.rewriteOffer = ^NSString *(NSString *sdp) {
        return WithFingerprint(sdp, swapped);
    };
    SZFO_CHECK([rewritten start]);
    SZFO_CHECK(SZFOWaitUntil(rewritten.answererQueue, 5, ^BOOL {
        return rewritten.answererOpenError != nil;
    }) && rewritten.answererOpenError.code == SZFriendsOnlineErrorFingerprintMismatch);
    [rewritten close];

    // The authenticated fingerprint and the SDP agree, but the offerer's DTLS certificate is another: DTLS
    // refuses it after ICE connects, and no stream ever opens.
    SZFOPair *impostor = [[SZFOPair alloc] initWithTransport:LoopbackTransport()
                                                     purpose:SZFriendsOnlinePurposeFriend
                                                        kind:SZFriendsOnlineConnectionDirect];
    impostor.rewriteOffer = ^NSString *(NSString *sdp) {
        return WithFingerprint(sdp, swapped);
    };
    impostor.authenticatedOfferFingerprint = swapped;
    SZFO_CHECK([impostor start]);
    SZFO_CHECK(SZFOWaitUntil(impostor.answererQueue, 10, ^BOOL {
        return impostor.answererEvents.error != nil;
    }), "the answerer fails");
    SZFOOnQueue(impostor.answererQueue, ^{
        SZFO_CHECK(impostor.answererEvents.error.code == SZFriendsOnlineErrorFingerprintMismatch, "%@",
                   impostor.answererEvents.error);
        SZFO_CHECK(impostor.answererEvents.streams.count == 0);
    });
    SZFOOnQueue(impostor.offererQueue, ^{
        SZFO_CHECK(impostor.offererEvents.streams.count == 0, "nor does the offerer get a stream");
    });
    [impostor close];
}

static void TestLinksOfferNothingPrivate(void) {
    SZFOPair *pair = [[SZFOPair alloc] initWithTransport:LoopbackTransport()
                                                 purpose:SZFriendsOnlinePurposeLink
                                                    kind:SZFriendsOnlineConnectionDirect];
    SZFO_CHECK([pair start]);
    SZFO_CHECK(SZFOWaitUntil(pair.offererQueue, 5, ^BOOL {
        return [pair.offererEvents.events containsObject:@"gathered"];
    }), "gathering ends");
    SZFOOnQueue(pair.offererQueue, ^{
        SZFO_CHECK(pair.offererEvents.candidates.count == 0, "a link's opener never learns a loopback or private "
                   "address: %@", pair.offererEvents.candidates);
    });
    [pair close];
}

void SZFORunLoopbackTests(void) {
    TestDirectTransfer();
    TestOffererAppliesNothingEarly();
    TestFingerprintRule();
    TestLinksOfferNothingPrivate();
}
