// Refusals before a responder's first reply all look alike from outside (review finding "hidden listener refusal
// timing"): nothing written, nothing more read, and the link closed SZFriendsRefusalDelay after message 1 arrived,
// whatever the reason and however long the work behind it took. Also the replay cache on its own, and the
// admission questions a listener's stream is asked.

#import "SZFRefusalRig.h"
#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

#import "service/session/SZFriendsSecureChannelInternal.h"

static void SZFTestRefusalTimingIndependentOfReason(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *carol = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *badCert = [SZFriendsIdentity szf_newIdentity];
    [badCert szf_setCertificate:alice.staticCertificate];
    NSData *ikToBob = SZFMessage1(SZFOptions(SZFriendsHandshakeIK, bob), alice);
    NSMutableData *unknownPreamble = [NSMutableData dataWithBytes:"SZ\x09\x00" length:4];
    [unknownPreamble appendData:SZFRandomBytes(40)];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    NSTimeInterval arrival = 1000;

    // The slow refusal: a policy that takes 0.4 s (a store lookup under load) before saying no.
    SZFRefusalRig *rig = [SZFRefusalRig rigFor:bob profile:nil cache:nil policy:^BOOL(SZFRefusalRig *r,
                                                                                       SZFriendsHandshakePattern p) {
        (void)p;
        r.now += 0.4;
        return NO;
    }];
    SZFRefusalCase slow = {"slow policy refusal", SZFriendsSessionErrorRejected};
    [offsets addObject:@(SZFExpectQuietRefusal(rig, ikToBob, arrival, slow))];
    SZF_CHECK(rig.policyCalls == 1, @"the policy was asked once");

    struct {
        SZFRefusalCase expected;
        NSData *message;
        BOOL admit;
    } cases[] = {
        {{"sealed to another static key", SZFriendsSessionErrorHandshakeFailed},
         SZFMessage1(SZFOptions(SZFriendsHandshakeIK, carol), alice), YES},
        {{"certificate not binding the key", SZFriendsSessionErrorHandshakeFailed},
         SZFMessage1(SZFOptions(SZFriendsHandshakeIK, bob), badCert), YES},
        {{"admission rate full", SZFriendsSessionErrorRejected}, ikToBob, NO},
        {{"XX at a hidden listener", SZFriendsSessionErrorRejected},
         SZFMessage1(SZFOptions(SZFriendsHandshakeXX, nil), alice), YES},
        {{"unknown preamble", SZFriendsSessionErrorHandshakeFailed}, unknownPreamble, YES},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        arrival += 100;
        SZFRefusalRig *each = [SZFRefusalRig rigFor:bob profile:nil cache:nil policy:nil];
        each.stream.admit = cases[i].admit;
        [offsets addObject:@(SZFExpectQuietRefusal(each, cases[i].message, arrival, cases[i].expected))];
        SZF_CHECK(each.policyCalls == 0, @"%s: refused before the policy", cases[i].expected.label);
    }

    // NN refused by the policy (Add by ID's per-listener rate).
    arrival += 100;
    SZFRefusalRig *nn = [SZFRefusalRig rigFor:bob profile:nil cache:nil policy:^BOOL(SZFRefusalRig *r,
                                                                                      SZFriendsHandshakePattern p) {
        (void)r;
        return p != SZFriendsHandshakeNN;
    }];
    [offsets addObject:@(SZFExpectQuietRefusal(nn, SZFMessage1(SZFOptions(SZFriendsHandshakeNN, nil), alice), arrival,
                                               (SZFRefusalCase){"NN over its rate", SZFriendsSessionErrorRejected}))];

    // A replay: the first copy is answered (so its timing is the accepted path), the second refused like the rest.
    SZFriendsReplayCache *cache = [[SZFriendsReplayCache alloc] init];
    SZFRefusalRig *first = [SZFRefusalRig rigFor:bob profile:nil cache:cache policy:nil];
    [first deliver:ikToBob at:arrival + 50];
    SZFOnQueue(first.queue, ^{
        SZF_CHECK(first.listenerEnd.transcript.length > 0 && first.policyCalls == 1, @"the original is answered");
    });
    arrival += 100;
    SZFRefusalRig *replay = [SZFRefusalRig rigFor:bob profile:nil cache:cache policy:nil];
    [offsets addObject:@(SZFExpectQuietRefusal(replay, ikToBob, arrival,
                                               (SZFRefusalCase){"replayed message 1", SZFriendsSessionErrorReplayed}))];
    SZF_CHECK(replay.policyCalls == 0, @"a replay never reaches the policy");

    for (NSNumber *offset in offsets) {
        SZF_CHECK(fabs(offset.doubleValue - SZFriendsRefusalDelay) < 1e-9,
                  @"every refusal closes %.1f s after message 1, got %.6f", SZFriendsRefusalDelay,
                  offset.doubleValue);
    }
    SZF_CHECK(offsets.count == 8, @"every reason exercised");
}

// The production scheduler: the refusal really waits, then closes on its own.
static void SZFTestRefusalWaitsInRealTime(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    dispatch_queue_t queue = dispatch_queue_create("szfriends.session.refusal.real", DISPATCH_QUEUE_SERIAL);
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    SZFriendsSecureChannel *initiator =
        [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:streams[0]
                                                         identity:alice
                                                          options:SZFOptions(SZFriendsHandshakeIK, bob)
                                                            queue:queue];
    SZFriendsSecureChannel *responder = [[SZFriendsSecureChannel alloc]
        initAsResponderWithStream:streams[1]
                         identity:bob
                    publicProfile:nil
                        keyPolicy:^BOOL(NSData *k, SZFriendsHandshakePattern p, NSData *t) {
                            (void)k, (void)p, (void)t;
                            return NO;
                        }
                            queue:queue];
    __block NSDate *closedAt = nil;
    responder.onClose = ^(NSError *error) {
        (void)error;
        closedAt = [NSDate date];
    };
    NSDate *started = [NSDate date];
    SZFOnQueue(queue, ^{
        [responder setRefusalDelay:0.3];
        [responder start];
        [initiator start];
    });
    SZF_CHECK(!SZFWaitUntil(queue, 0.15,
                            ^BOOL {
                                return closedAt != nil;
                            }),
              @"not closed before the deadline");
    SZF_CHECK(SZFWaitUntil(queue, 3,
                           ^BOOL {
                               return closedAt != nil && streams[0].closedByPeer;
                           }),
              @"closed by the deadline");
    SZF_CHECK([closedAt timeIntervalSinceDate:started] >= 0.29, @"closed after %.3f s",
              [closedAt timeIntervalSinceDate:started]);
    SZFOnQueue(queue, ^{
        SZF_CHECK(streams[1].transcript.length == 0, @"nothing written");
        [initiator close];
    });
}

static void SZFTestReplayCache(void) {
    __block NSTimeInterval now = 50;
    SZFriendsReplayCache *cache = [[SZFriendsReplayCache alloc] initWithCapacity:2
                                                                           clock:^NSTimeInterval {
                                                                               return now;
                                                                           }];
    NSData *a = SZFBytes(1, 32), *b = SZFBytes(2, 32), *c = SZFBytes(3, 32);
    SZF_CHECK([cache recordEphemeralKey:a] && ![cache recordEphemeralKey:a], @"a repeat is refused");
    now += SZFriendsReplayWindow - 1;
    SZF_CHECK(![cache recordEphemeralKey:a], @"still refused just inside the window");
    now += 1;
    SZF_CHECK([cache recordEphemeralKey:a], @"forgotten once the window has passed");
    SZF_CHECK([cache recordEphemeralKey:b] && [cache recordEphemeralKey:c] && cache.count == 2,
              @"capacity holds: the oldest goes first");
    SZF_CHECK(![cache recordEphemeralKey:c] && [cache recordEphemeralKey:a], @"a was evicted, c kept");
    SZF_CHECK(SZFriendsReplayCache.sharedCache == SZFriendsReplayCache.sharedCache, @"one shared cache");
}

// What a listener's stream is told: the pattern, once, before the policy and any Diffie-Hellman; that a complete
// message 1 arrived, once, whatever becomes of it; and that the initiator is known, once, as early as it is (review
// finding "admission lockout": a newcomer may evict the oldest connection that has not authenticated, so a friend's
// must leave that pool at the policy, not a round trip later at HELLO). An initiator is told nothing.
static void SZFTestAdmissionQuestions(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFRefusalRig *rig = [SZFRefusalRig rigFor:bob profile:nil cache:nil policy:nil];
    __block NSUInteger policyCallsWhenAsked = 99;
    __weak SZFRefusalRig *weakRig = rig;
    rig.stream.onAsk = ^{
        policyCallsWhenAsked = weakRig.policyCalls;
    };
    NSData *ikToBob = SZFMessage1(SZFOptions(SZFriendsHandshakeIK, bob), alice);
    // Split, so message 1 is complete only with its last byte.
    [rig deliver:[ikToBob subdataWithRange:NSMakeRange(0, ikToBob.length - 1)] at:10];
    SZFOnQueue(rig.queue, ^{
        SZF_CHECK(rig.stream.firstMessages == 0, @"not before message 1 is complete");
    });
    [rig deliver:[ikToBob subdataWithRange:NSMakeRange(ikToBob.length - 1, 1)] at:10.1];
    SZFOnQueue(rig.queue, ^{
        SZF_CHECK([rig.stream.askedPatterns isEqual:@[ @(SZFriendsHandshakeIK) ]] && policyCallsWhenAsked == 0,
                  @"asked about IK before the policy: %@", rig.stream.askedPatterns);
        SZF_CHECK(rig.policyCalls == 1 && rig.listenerEnd.transcript.length > 0, @"then answered");
        SZF_CHECK(rig.stream.firstMessages == 1, @"told message 1 arrived, once");
        SZF_CHECK(rig.stream.authenticated == 1, @"an IK message 1 the policy accepts names the initiator");
    });

    // Refused: message 1 arrived, but nobody is known.
    SZFRigPolicy refuse = ^BOOL(SZFRefusalRig *r, SZFriendsHandshakePattern p) {
        (void)r, (void)p;
        return NO;
    };
    SZFRefusalRig *refused = [SZFRefusalRig rigFor:bob profile:nil cache:nil policy:refuse];
    [refused deliver:ikToBob at:20];
    SZFOnQueue(refused.queue, ^{
        SZF_CHECK(refused.stream.firstMessages == 1 && refused.stream.authenticated == 0, @"refused: not known");
    });

    SZFChannelPair *pair = [SZFChannelPair pairWithOptions:SZFOptions(SZFriendsHandshakeXX, nil)
                                         initiatorIdentity:alice
                                         responderIdentity:bob
                                             publicProfile:@{}
                                                    policy:nil];
    SZFAdmissionStream *initiatorSide = [[SZFAdmissionStream alloc] initWithStream:pair.initiatorStream];
    SZFAdmissionStream *responderSide = [[SZFAdmissionStream alloc] initWithStream:pair.responderStream];
    pair.initiator->_stream = initiatorSide;
    pair.responder->_stream = responderSide;
    [pair start];
    SZF_CHECK([pair waitUntilBothEstablished], @"XX on a public entry goes live");
    SZFOnQueue(pair.queue, ^{
        SZF_CHECK([responderSide.askedPatterns isEqual:@[ @(SZFriendsHandshakeXX) ]] &&
                      responderSide.authenticated == 1 && responderSide.firstMessages == 1,
                  @"responder asked once and told once, at message 3 and not again at HELLO");
        SZF_CHECK(initiatorSide.askedPatterns.count == 0 && initiatorSide.authenticated == 0 &&
                      initiatorSide.firstMessages == 0,
                  @"an initiator never");
    });

    // NN names nobody: only HELLO, which proves the initiator finished the handshake, gives the place back.
    SZFRefusalRig *nn = [SZFRefusalRig rigFor:bob profile:nil cache:nil policy:nil];
    [nn deliver:SZFMessage1(SZFOptions(SZFriendsHandshakeNN, nil), alice) at:30];
    SZFOnQueue(nn.queue, ^{
        SZF_CHECK(nn.listenerEnd.transcript.length > 0 && nn.stream.firstMessages == 1 && nn.stream.authenticated == 0,
                  @"NN answered, but message 1 names nobody");
    });
}

// Review finding "timing through the shared queue": IK message 1 sealed to another listener's key failed after one
// X25519 operation, while one sealed to ours ran two and a certificate check before the policy refused it; message 1
// is processed on the helper's one serial queue, so an NN reply queued behind it came later on the long path. Now
// every IK message 1 costs two X25519 operations and one certificate check, whatever happens to it.
static void SZFTestMessage1WorkIndependentOfKey(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *carol = [SZFriendsIdentity szf_newIdentity], *badCert = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *noCert = [SZFriendsIdentity szf_newIdentity];
    [badCert szf_setCertificate:alice.staticCertificate];
    NSData *none = nil; // presents no certificate at all
    [noCert szf_setCertificate:none];
    NSData *ikToBob = SZFMessage1(SZFOptions(SZFriendsHandshakeIK, bob), alice);
    NSMutableData *tampered = [ikToBob mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[tampered.length - 1] ^= 1; // the payload's tag: fails after both DH
    struct {
        const char *label;
        NSData *message;
        BOOL accept;
        NSUInteger dummyDH, dummyChecks;
    } cases[] = {
        {"sealed to us, refused by the policy", ikToBob, NO, 0, 0},
        {"sealed to us, accepted", ikToBob, YES, 0, 0},
        {"sealed to another static key", SZFMessage1(SZFOptions(SZFriendsHandshakeIK, carol), alice), NO, 1, 1},
        {"payload tampered", tampered, NO, 0, 1},
        {"no certificate", SZFMessage1(SZFOptions(SZFriendsHandshakeIK, bob), noCert), NO, 0, 1},
        {"certificate not binding the key", SZFMessage1(SZFOptions(SZFriendsHandshakeIK, bob), badCert), NO, 0, 0},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        BOOL accept = cases[i].accept;
        const char *label = cases[i].label;
        NSUInteger dummyDH = cases[i].dummyDH, dummyChecks = cases[i].dummyChecks;
        SZFRigPolicy decide = ^BOOL(SZFRefusalRig *r, SZFriendsHandshakePattern p) {
            (void)r, (void)p;
            return accept;
        };
        SZFRefusalRig *rig = [SZFRefusalRig rigFor:bob profile:nil cache:nil policy:decide];
        [rig deliver:cases[i].message at:100];
        SZFOnQueue(rig.queue, ^{
            SZFriendsSecureChannel *responder = rig.responder;
            SZF_CHECK(responder.message1ScalarMultiplications == 2 && responder.message1CertificateChecks == 1,
                      @"%s: %lu X25519, %lu certificate checks", label,
                      (unsigned long)responder.message1ScalarMultiplications,
                      (unsigned long)responder.message1CertificateChecks);
            SZF_CHECK(responder.message1DummyScalarMultiplications == dummyDH &&
                          responder.message1DummyCertificateChecks == dummyChecks,
                      @"%s: %lu and %lu of them dummies", label,
                      (unsigned long)responder.message1DummyScalarMultiplications,
                      (unsigned long)responder.message1DummyCertificateChecks);
            SZF_CHECK((rig.listenerEnd.transcript.length > 0) == accept, @"%s: answered only when accepted", label);
        });
    }
}

// Wave-4 re-check: message 1 may be 65,535 bytes, and only the listener it is sealed to decrypts and hashes the
// payload, so a padded IK message 1 made that listener's refusal measurably slower through the shared queue. Anything
// longer than an honest handshake message is now refused on its length prefix, before any Diffie-Hellman, by every
// listener alike, while the longest honest message 1 (a token and a 512-byte attestation) still gets through.
static void SZFTestOversizedMessage1RefusedBeforeAnyWork(void) {
    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity], *bob = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *carol = [SZFriendsIdentity szf_newIdentity];
    NSMutableData *padded = [NSMutableData dataWithBytes:"SZ\x01\x01" length:4]; // preamble: major 1, IK
    NSUInteger length = SZFriendsResponderHandshakeMax + 1;
    uint8_t prefix[2] = {(uint8_t)(length >> 8), (uint8_t)length};
    [padded appendBytes:prefix length:2];
    [padded appendData:SZFRandomBytes(length)];
    NSTimeInterval arrival = 5000;
    for (SZFriendsIdentity *listener in @[ bob, carol ]) {
        SZFRefusalRig *rig = [SZFRefusalRig rigFor:listener profile:nil cache:nil policy:nil];
        NSTimeInterval closedAfter = SZFExpectQuietRefusal(
            rig, padded, arrival, (SZFRefusalCase){"message 1 over the limit", SZFriendsSessionErrorFrameInvalid});
        SZF_CHECK(fabs(closedAfter - SZFriendsRefusalDelay) < 1e-9, @"refused like any other: %.6f", closedAfter);
        SZFOnQueue(rig.queue, ^{
            SZF_CHECK(rig.responder.message1ScalarMultiplications == 0 && rig.policyCalls == 0,
                      @"no Diffie-Hellman and no policy: %lu X25519",
                      (unsigned long)rig.responder.message1ScalarMultiplications);
        });
        arrival += 100;
    }
    // The longest honest message 1 fits and is answered.
    SZFriendsHandshakeOptions *options = SZFOptions(SZFriendsHandshakeIK, bob);
    options.requestToken = SZFRandomBytes(16);
    dispatch_queue_t queue = dispatch_queue_create("szfriends.session.longest", DISPATCH_QUEUE_SERIAL);
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    SZFriendsSecureChannel *initiator = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:streams[0]
                                                                                         identity:alice
                                                                                          options:options
                                                                                            queue:queue];
    initiator.localAttestation = SZFRandomBytes(SZFriendsAttestationMax);
    __block NSData *longest = nil;
    SZFOnQueue(queue, ^{
        [streams[1] startWithQueue:queue];
        [initiator start];
        longest = [streams[0].transcript copy];
        [initiator close];
    });
    SZFDrain(queue);
    SZF_CHECK(longest.length > 4 + 2 + 700 && longest.length <= 4 + 2 + SZFriendsResponderHandshakeMax,
              @"the longest honest message 1 is %lu bytes", (unsigned long)longest.length);
    SZFRefusalRig *rig = [SZFRefusalRig rigFor:bob profile:nil cache:nil policy:nil];
    [rig deliver:longest at:arrival];
    SZFOnQueue(rig.queue, ^{
        SZF_CHECK(rig.listenerEnd.transcript.length > 0 && rig.policyCalls == 1, @"answered: %@", rig.error);
    });
}

void SZFRunChannelRefusalTests(void) {
    SZFTestOversizedMessage1RefusedBeforeAnyWork();
    SZFTestRefusalTimingIndependentOfReason();
    SZFTestRefusalWaitsInRealTime();
    SZFTestReplayCache();
    SZFTestAdmissionQuestions();
    SZFTestMessage1WorkIndependentOfKey();
}
