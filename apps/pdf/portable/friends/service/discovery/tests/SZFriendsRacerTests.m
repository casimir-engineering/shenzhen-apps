// Route racing, the session tie-break, the launch decision and the visibility deadline.

#import "SZFriendsDiscoveryTestSupport.h"

#import "service/discovery/SZFriendsDiscoveryCoordinator.h"

static SZFriendsCandidate *FriendCandidate(NSArray<SZFriendsSighting *> *sightings) {
    SZFriendsDiscoveryMerger *merger = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:^NSString *(NSData *tag) {
        return [tag isEqual:SZFTestData(@"0101010101010101")] ? @"mei" : nil;
    }];
    for (SZFriendsSighting *sighting in sightings) [merger addSighting:sighting];
    return merger.candidates.firstObject;
}

static void TestAttempts(void) {
    NSData *tag = SZFTestData(@"0101010101010101");
    NSDate *t = SZFTestDate(1000);
    SZFriendsRouteRacer *racer = [SZFriendsRouteRacer new];
    SZFriendsCandidate *all = FriendCandidate(@[
        SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodPeerToPeerWiFi, @"awdl", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", tag, @[], NO, t),
    ]);
    NSArray<SZFriendsDialAttempt *> *attempts = [racer attemptsForCandidate:all];
    CHECK(attempts.count == 3);
    CHECK([attempts[0].sighting.endpointID isEqual:@"lan"] && attempts[0].delay == SZFriendsDialDelayLAN);
    CHECK([attempts[1].sighting.endpointID isEqual:@"awdl"] && attempts[1].delay == SZFriendsDialDelayPeerToPeerWiFi);
    CHECK([attempts[2].sighting.endpointID isEqual:@"bt"] && attempts[2].delay == SZFriendsDialDelayBluetooth);
    CHECK(SZFriendsDialDelayLAN == 0 && SZFriendsDialDelayPeerToPeerWiFi == 0.15 && SZFriendsDialDelayBluetooth == 0.5);

    // A friend just seen over Bluetooth whose Wi-Fi endpoint is lingering: Wi-Fi is still dialed, first.
    SZFriendsDiscoveryMerger *merger = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:^NSString *(NSData *t2) {
        return [t2 isEqual:tag] ? @"mei" : nil;
    }];
    [merger addSighting:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", tag, @[], NO,
                                        t)];
    [merger removeEndpoint:@"lan" method:SZFriendsDiscoveryMethodNetwork atDate:[t dateByAddingTimeInterval:1]];
    [merger addSighting:SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", tag,
                                        @[], NO, [t dateByAddingTimeInterval:2])];
    attempts = [racer attemptsForCandidate:merger.candidates.firstObject];
    CHECK(attempts.count == 2 && [attempts[0].sighting.endpointID isEqual:@"lan"] && attempts[0].delay == 0);

    // A visible friend: IK goes to the hidden entry; the public one only when it is all there is.
    SZFriendsDiscoveryMerger *visible = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:^NSString *(NSData *t2) {
        return [t2 isEqual:tag] ? @"mei" : nil;
    }];
    [visible addSighting:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"public", nil, @[],
                                         YES, t)];
    [visible identifyEndpoint:@"public" method:SZFriendsDiscoveryMethodNetwork identityKey:tag conversationID:@"mei"];
    attempts = [racer attemptsForCandidate:visible.candidates.firstObject];
    CHECK(attempts.count == 1 && [attempts[0].sighting.endpointID isEqual:@"public"], "public only: dial it");
    [visible addSighting:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"hidden", tag, @[],
                                         NO, t)];
    CHECK(visible.candidates.count == 1 && visible.candidates[0].sightings.count == 2);
    attempts = [racer attemptsForCandidate:visible.candidates.firstObject];
    CHECK(attempts.count == 1 && [attempts[0].sighting.endpointID isEqual:@"hidden"], "IK to the hidden entry");
}

static NSArray<NSString *> *Dialed(SZFriendsRouteRacer *racer, SZFriendsCandidate *candidate) {
    NSMutableArray<NSString *> *endpoints = [NSMutableArray array];
    for (SZFriendsDialAttempt *attempt in [racer attemptsForCandidate:candidate]) {
        [endpoints addObject:attempt.sighting.endpointID];
    }
    return endpoints;
}

// Peer-to-peer Wi-Fi is dialed only where it keeps the Wi-Fi connection; otherwise the order goes on without it.
static void TestPeerToPeerWiFiCapability(void) {
    NSData *tag = SZFTestData(@"0101010101010101");
    NSDate *t = SZFTestDate(1000);
    SZFriendsCandidate *every = FriendCandidate(@[
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodRelay, @"relay", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodPeerToPeerWiFi, @"awdl", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodInternet, @"inet", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", tag, @[], NO, t),
    ]);
    CHECK([SZFriendsRouteRacer new].peerToPeerWiFi == SZFriendsPeerToPeerWiFiConcurrentWithStation, "macOS: AWDL");
    CHECK(SZFriendsPeerToPeerWiFiUsable(SZFriendsPeerToPeerWiFiConcurrentWithStation));
    SZFriendsRouteRacer *keeps = [SZFriendsRouteRacer new];
    keeps.peerToPeerWiFi = SZFriendsPeerToPeerWiFiConcurrentWithStation;
    CHECK([Dialed(keeps, every) isEqual:(@[ @"lan", @"awdl", @"inet", @"bt", @"relay" ])]);
    SZFriendsPeerToPeerWiFi unusable[] = {SZFriendsPeerToPeerWiFiDropsStation, SZFriendsPeerToPeerWiFiUnsupported,
                                          SZFriendsPeerToPeerWiFiUnknown};
    for (size_t i = 0; i < sizeof unusable / sizeof unusable[0]; i++) {
        CHECK(!SZFriendsPeerToPeerWiFiUsable(unusable[i]));
        SZFriendsRouteRacer *racer = [SZFriendsRouteRacer new];
        racer.peerToPeerWiFi = unusable[i];
        CHECK([Dialed(racer, every) isEqual:(@[ @"lan", @"inet", @"bt", @"relay" ])], "capability %ld",
              (long)unusable[i]);
    }
    // Without LAN, Internet leads rather than the direct link.
    SZFriendsCandidate *noLAN = FriendCandidate(@[
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodPeerToPeerWiFi, @"awdl", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodInternet, @"inet", tag, @[], NO, t),
    ]);
    SZFriendsRouteRacer *drops = [SZFriendsRouteRacer new];
    drops.peerToPeerWiFi = SZFriendsPeerToPeerWiFiDropsStation;
    CHECK([Dialed(drops, noLAN) isEqual:(@[ @"inet", @"bt" ])]);
}

static void TestDecisions(void) {
    SZFriendsRouteRacer *racer = [SZFriendsRouteRacer new];
    SZFriendsCandidate *candidate = FriendCandidate(@[
        SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt",
                        SZFTestData(@"0101010101010101"), @[], NO, SZFTestDate(1)),
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodPeerToPeerWiFi, @"p2p",
                        SZFTestData(@"0101010101010101"), @[], NO, SZFTestDate(1)),
    ]);
    SZFriendsDialAttempt *p2p = [racer attemptsForCandidate:candidate][0];
    SZFriendsDialAttempt *bt = [racer attemptsForCandidate:candidate][1];
    CHECK([racer shouldStartAttempt:bt currentRoute:SZFriendsRouteMethodNone]);
    CHECK(![racer shouldStartAttempt:bt currentRoute:SZFriendsRouteMethodLAN]);
    CHECK(![racer shouldStartAttempt:bt currentRoute:SZFriendsRouteMethodBluetooth],
          "never a second session on one class");
    CHECK([racer shouldStartAttempt:p2p currentRoute:SZFriendsRouteMethodBluetooth], "could find a faster class");
    CHECK(![racer shouldStartAttempt:p2p currentRoute:SZFriendsRouteMethodLAN]);

    // Bluetooth completes first and carries traffic at once; Wi-Fi then supersedes it; a late duplicate closes.
    CHECK([racer decisionForCompletedRoute:SZFriendsRouteMethodBluetooth currentRoute:SZFriendsRouteMethodNone] ==
          SZFriendsRaceDecisionAdopt);
    CHECK([racer decisionForCompletedRoute:SZFriendsRouteMethodLAN currentRoute:SZFriendsRouteMethodBluetooth] ==
          SZFriendsRaceDecisionUpgrade);
    CHECK([racer decisionForCompletedRoute:SZFriendsRouteMethodPeerToPeerWiFi
                              currentRoute:SZFriendsRouteMethodBluetooth] == SZFriendsRaceDecisionUpgrade);
    CHECK([racer decisionForCompletedRoute:SZFriendsRouteMethodBluetooth currentRoute:SZFriendsRouteMethodLAN] ==
          SZFriendsRaceDecisionClose);
    CHECK([racer decisionForCompletedRoute:SZFriendsRouteMethodLAN currentRoute:SZFriendsRouteMethodLAN] ==
          SZFriendsRaceDecisionClose);
}

static void TestSessionRace(void) {
    NSData *low = SZFTestData(@"01ff"), *high = SZFTestData(@"02");
    CHECK(SZFriendsSessionAWins(SZFriendsRouteMethodLAN, high, SZFriendsRouteMethodBluetooth, low), "class first");
    CHECK(!SZFriendsSessionAWins(SZFriendsRouteMethodBluetooth, low, SZFriendsRouteMethodPeerToPeerWiFi, high));
    CHECK(SZFriendsSessionAWins(SZFriendsRouteMethodLAN, low, SZFriendsRouteMethodLAN, high), "lower key bytewise");
    CHECK(!SZFriendsSessionAWins(SZFriendsRouteMethodLAN, high, SZFriendsRouteMethodLAN, low));
    // Both sides evaluate with A and B swapped and must agree on the same session.
    NSData *keys[] = {low, high, SZFTestData(@"01"), SZFTestData(@"0100")};
    SZFriendsRouteMethod routes[] = {SZFriendsRouteMethodLAN, SZFriendsRouteMethodBluetooth};
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            for (int r = 0; r < 2; r++) {
                for (int s = 0; s < 2; s++) {
                    if (i == j && r == s) continue;
                    BOOL aWins = SZFriendsSessionAWins(routes[r], keys[i], routes[s], keys[j]);
                    BOOL bWins = SZFriendsSessionAWins(routes[s], keys[j], routes[r], keys[i]);
                    CHECK(aWins != bWins, "keys %d/%d routes %d/%d", i, j, r, s);
                }
            }
        }
    }
    CHECK(SZFriendsSessionAWins(SZFriendsRouteMethodLAN, SZFTestData(@"01"), SZFriendsRouteMethodLAN,
                                SZFTestData(@"0100")),
          "a prefix sorts first");
    CHECK(SZFriendsSessionAWins(SZFriendsRouteMethodLAN, low, SZFriendsRouteMethodLAN, low), "identical: keep A");
}

// Review finding "route class": None (0) and values outside the enum used to beat LAN because their numbers are
// smaller. They now rank below every real class, on both sides of the comparison.
static void TestSessionRaceUnknownRoutes(void) {
    NSData *low = SZFTestData(@"01"), *high = SZFTestData(@"02");
    SZFriendsRouteMethod real[] = {SZFriendsRouteMethodLAN, SZFriendsRouteMethodPeerToPeerWiFi,
                                   SZFriendsRouteMethodBluetooth, SZFriendsRouteMethodInternet,
                                   SZFriendsRouteMethodRelay};
    SZFriendsRouteMethod unknown[] = {SZFriendsRouteMethodNone, (SZFriendsRouteMethod)6, (SZFriendsRouteMethod)255,
                                      (SZFriendsRouteMethod)-1};
    for (size_t r = 0; r < sizeof real / sizeof real[0]; r++) {
        for (size_t u = 0; u < sizeof unknown / sizeof unknown[0]; u++) {
            CHECK(SZFriendsSessionAWins(real[r], high, unknown[u], low), "class %ld beats %ld", (long)real[r],
                  (long)unknown[u]);
            CHECK(!SZFriendsSessionAWins(unknown[u], low, real[r], high), "%ld loses to class %ld", (long)unknown[u],
                  (long)real[r]);
        }
    }
    // Two sessions without a real class fall back to the key, so both sides still agree.
    CHECK(SZFriendsSessionAWins(SZFriendsRouteMethodNone, low, (SZFriendsRouteMethod)9, high));
    CHECK(!SZFriendsSessionAWins((SZFriendsRouteMethod)9, high, SZFriendsRouteMethodNone, low));
}

// Review finding "presence tag relay": after a failed handshake, that endpoint is dialed for that person only after
// a backoff (2 s, doubling to 900 s), while their other endpoints and other people are unaffected.
static void TestEndpointBackoff(void) {
    NSData *tag = SZFTestData(@"0101010101010101");
    __block NSDate *now = SZFTestDate(5000);
    SZFriendsRouteRacer *racer = [SZFriendsRouteRacer new];
    racer.clock = ^NSDate * {
        return now;
    };
    SZFriendsCandidate *mei = FriendCandidate(@[
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"relay", tag, @[], NO, now),
        SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", tag, @[], NO, now),
    ]);
    CHECK([racer attemptsForCandidate:mei].count == 2 && racer.nextBackoffEnd == nil);
    [racer noteHandshakeFailedAtEndpoint:@"relay" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    NSArray<SZFriendsDialAttempt *> *attempts = [racer attemptsForCandidate:mei];
    CHECK(attempts.count == 1 && [attempts[0].sighting.endpointID isEqual:@"bt"], "the failed endpoint waits");
    CHECK([racer.nextBackoffEnd isEqual:[now dateByAddingTimeInterval:SZFriendsEndpointBackoffFirst]]);
    // Keyed per method too: the same name on Bluetooth is another endpoint.
    [racer noteHandshakeFailedAtEndpoint:@"bt" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    CHECK([racer attemptsForCandidate:mei].count == 1);
    now = [now dateByAddingTimeInterval:SZFriendsEndpointBackoffFirst];
    CHECK([racer attemptsForCandidate:mei].count == 2, "dialed again once the backoff passed");
    NSTimeInterval expected = SZFriendsEndpointBackoffFirst;
    for (int i = 0; i < 12; i++) {
        [racer noteHandshakeFailedAtEndpoint:@"relay" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
        expected = MIN(expected * 2, SZFriendsEndpointBackoffMax);
        NSTimeInterval wait = [racer.nextBackoffEnd timeIntervalSinceDate:now];
        CHECK(fabs(wait - expected) < 1e-6, "failure %d waits %.0f s, expected %.0f", i + 2, wait, expected);
    }
    CHECK(SZFriendsEndpointBackoffMax == 900, "never longer than a window");
    [racer noteHandshakeSucceededAtEndpoint:@"relay" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    CHECK([racer attemptsForCandidate:mei].count == 2, "a session that went live clears it");
    // Long quiet after a backoff ended: the next failure starts from the first step again.
    [racer noteHandshakeFailedAtEndpoint:@"relay" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    now = [now dateByAddingTimeInterval:SZFriendsEndpointBackoffFirst + SZFriendsEndpointBackoffMax];
    [racer noteHandshakeFailedAtEndpoint:@"relay" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    CHECK(fabs([racer.nextBackoffEnd timeIntervalSinceDate:now] - SZFriendsEndpointBackoffFirst) < 1e-6);
    // Another person dialing the same endpoint is not held back by Mei's failures.
    SZFriendsDiscoveryMerger *merger = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:^NSString *(NSData *t) {
        return [t isEqual:tag] ? @"kenji" : nil;
    }];
    [merger addSighting:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"relay", tag, @[],
                                        NO, now)];
    CHECK([racer attemptsForCandidate:merger.candidates.firstObject].count == 1);
}

// Review finding "presence tag relay" (wave 3): the backoff was keyed by endpoint, and an endpoint is a Bonjour name
// the advertiser picks, so a relayer re-advertising a captured tag under a new name drew a fresh dial from each friend
// every time. Now a failure holds the tag back for that person and method, whatever name shows it next.
static void TestTagBackoff(void) {
    NSData *tag = SZFTestData(@"0101010101010101"), *nextWindow = SZFTestData(@"0202020202020202");
    __block NSDate *now = SZFTestDate(9000);
    SZFriendsRouteRacer *racer = [SZFriendsRouteRacer new];
    racer.clock = ^NSDate * {
        return now;
    };
    SZFriendsSighting * (^lan)(NSString *, NSData *) = ^SZFriendsSighting *(NSString *name, NSData *t) {
        return SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, name, t, @[], NO, now);
    };
    CHECK([racer attemptsForCandidate:FriendCandidate(@[ lan(@"relay-1", tag) ])].count == 1);
    [racer noteHandshakeFailedAtEndpoint:@"relay-1" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    CHECK([racer attemptsForCandidate:FriendCandidate(@[ lan(@"relay-2", tag) ])].count == 0,
          "the same tag under a new name waits out the backoff");
    SZFriendsSighting *bluetooth =
        SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", tag, @[], NO, now);
    CHECK([racer attemptsForCandidate:FriendCandidate(@[ bluetooth ])].count == 1, "another method is not held back");
    now = [now dateByAddingTimeInterval:SZFriendsEndpointBackoffFirst];
    CHECK([racer attemptsForCandidate:FriendCandidate(@[ lan(@"relay-3", tag) ])].count == 1, "dialed once it passed");
    [racer noteHandshakeFailedAtEndpoint:@"relay-3" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    CHECK(fabs([racer.nextBackoffEnd timeIntervalSinceDate:now] - 2 * SZFriendsEndpointBackoffFirst) < 1e-6,
          "a second failure under a third name doubles the same backoff");
    // The next window's tag is new: the friend's own device is dialed as soon as it shows it.
    SZFriendsDiscoveryMerger *merger = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:^NSString *(NSData *t) {
        return [t isEqual:tag] || [t isEqual:nextWindow] ? @"mei" : nil;
    }];
    [merger addSighting:lan(@"mei-next", nextWindow)];
    CHECK([racer attemptsForCandidate:merger.candidates.firstObject].count == 1, "a new window starts clean");
    // A session that went live through the tag clears it for every name showing it.
    [racer noteHandshakeSucceededAtEndpoint:@"relay-3" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    CHECK([racer attemptsForCandidate:FriendCandidate(@[ lan(@"relay-4", tag) ])].count == 1);

    // Matched by a callback tag: the failure is held against that tag, so varying the presence tag beside it (which
    // matches nobody) earns no fresh dial.
    NSData *callback = SZFTestData(@"0c0c0c0c0c0c0c0c");
    SZFriendsTagMatcher matcher = ^NSString *(NSData *t) {
        return [t isEqual:callback] ? @"lena" : nil;
    };
    racer.tagMatcher = matcher;
    SZFriendsCandidate * (^requester)(NSString *, NSString *) = ^SZFriendsCandidate *(NSString *name, NSString *hex) {
        SZFriendsDiscoveryMerger *m = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:matcher];
        [m addSighting:SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, name, SZFTestData(hex),
                                       @[ callback ], NO, now)];
        return m.candidates.firstObject;
    };
    CHECK([racer attemptsForCandidate:requester(@"call-1", @"a1a1a1a1a1a1a1a1")].count == 1);
    [racer noteHandshakeFailedAtEndpoint:@"call-1" method:SZFriendsDiscoveryMethodNetwork conversationID:@"lena"];
    CHECK([racer attemptsForCandidate:requester(@"call-2", @"b2b2b2b2b2b2b2b2")].count == 0,
          "a relayer cannot buy a dial by changing the tag that does not match");

    // The coordinator gives its racer the merger's matcher, as it is at the moment of the dial.
    SZFriendsDiscoveryMerger *wired = [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:^NSString *(NSData *t) {
        (void)t;
        return nil;
    }];
    SZFriendsDiscoveryCoordinator *coordinator =
        [[SZFriendsDiscoveryCoordinator alloc] initWithAdapters:@[]
                                                         merger:wired
                                                          queue:dispatch_queue_create("test.racer", NULL)
                                                          clock:^NSDate * {
                                                              return now;
                                                          }];
    CHECK(coordinator.racer.tagMatcher(tag) == nil);
    wired.tagMatcher = ^NSString *(NSData *t) {
        return [t isEqual:tag] ? @"mei" : nil;
    };
    CHECK([coordinator.racer.tagMatcher(tag) isEqual:@"mei"], "the matcher the helper set last");
}

// Lead decision 5 (ADR 0011 § Route rank): LAN, peer-to-peer Wi-Fi, Internet, Bluetooth, relay, at every site.
// The wire numbers put Bluetooth (3) before Internet (4), so each check below fails under a numeric comparison.
static void TestExplicitRank(void) {
    SZFriendsRouteMethod order[] = {SZFriendsRouteMethodLAN, SZFriendsRouteMethodPeerToPeerWiFi,
                                    SZFriendsRouteMethodInternet, SZFriendsRouteMethodBluetooth,
                                    SZFriendsRouteMethodRelay};
    for (size_t i = 0; i < 5; i++) {
        CHECK(SZFriendsRouteRank(order[i]) == (NSInteger)i, "rank of %ld", (long)order[i]);
        CHECK(SZFriendsRouteIsBetter(order[i], SZFriendsRouteMethodNone), "every real route beats None");
        CHECK(SZFriendsRouteIsBetter(order[i], (SZFriendsRouteMethod)7), "and unknown values");
        for (size_t j = i + 1; j < 5; j++) {
            CHECK(SZFriendsRouteIsBetter(order[i], order[j]) && !SZFriendsRouteIsBetter(order[j], order[i]));
            CHECK(SZFriendsDialDelayForRoute(order[i]) < SZFriendsDialDelayForRoute(order[j]),
                  "the stagger follows the rank: %ld before %ld", (long)order[i], (long)order[j]);
        }
    }
    CHECK(SZFriendsRouteMethodBluetooth == 3 && SZFriendsRouteMethodInternet == 4, "wire numbers unchanged");
    CHECK(SZFriendsDialDelayForRoute(SZFriendsRouteMethodInternet) == SZFriendsDialDelayInternet &&
              SZFriendsDialDelayInternet == 0.3 && SZFriendsDialDelayInternet != SZFriendsDialDelayBluetooth,
          "Internet has its own delay");
    CHECK(SZFriendsDialDelayForRoute(SZFriendsRouteMethodRelay) == SZFriendsDialDelayRelay &&
          SZFriendsDialDelayRelay == 5 && SZFriendsDialDelayForRoute(SZFriendsRouteMethodNone) == 5);

    // attemptsForCandidate: an Internet endpoint is dialed before a Bluetooth one, after the Wi-Fi ones.
    NSData *tag = SZFTestData(@"0101010101010101");
    NSDate *t = SZFTestDate(1000);
    SZFriendsRouteRacer *racer = [SZFriendsRouteRacer new];
    NSArray<SZFriendsDialAttempt *> *attempts = [racer attemptsForCandidate:FriendCandidate(@[
        SZFTestSighting(SZFriendsDiscoveryMethodBluetooth, SZFriendsRouteMethodBluetooth, @"bt", tag, @[], NO, t),
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodInternet, @"net", tag, @[], NO, t),
    ])];
    CHECK(attempts.count == 2 && [attempts[0].sighting.endpointID isEqual:@"net"] &&
          attempts[0].delay == SZFriendsDialDelayInternet && [attempts[1].sighting.endpointID isEqual:@"bt"]);
    SZFriendsDialAttempt *internet = attempts[0], *bluetooth = attempts[1];

    // shouldStartAttempt: Internet may still win over Bluetooth; Bluetooth never starts beside Internet.
    CHECK([racer shouldStartAttempt:internet currentRoute:SZFriendsRouteMethodBluetooth]);
    CHECK(![racer shouldStartAttempt:bluetooth currentRoute:SZFriendsRouteMethodInternet]);
    CHECK([racer shouldStartAttempt:internet currentRoute:SZFriendsRouteMethodRelay], "direct may leave the relay");
    CHECK([racer shouldStartAttempt:bluetooth currentRoute:SZFriendsRouteMethodRelay]);
    CHECK(![racer shouldStartAttempt:internet currentRoute:SZFriendsRouteMethodPeerToPeerWiFi]);
    CHECK(![racer shouldStartAttempt:internet currentRoute:SZFriendsRouteMethodInternet]);

    // decisionForCompletedRoute: a better route takes the session over (ADR 0001 resumes the transfer on it).
    SZFriendsRaceDecision (^decide)(SZFriendsRouteMethod, SZFriendsRouteMethod) =
        ^SZFriendsRaceDecision(SZFriendsRouteMethod route, SZFriendsRouteMethod current) {
            return [racer decisionForCompletedRoute:route currentRoute:current];
        };
    CHECK(decide(SZFriendsRouteMethodInternet, SZFriendsRouteMethodBluetooth) == SZFriendsRaceDecisionUpgrade);
    CHECK(decide(SZFriendsRouteMethodBluetooth, SZFriendsRouteMethodInternet) == SZFriendsRaceDecisionClose);
    CHECK(decide(SZFriendsRouteMethodInternet, SZFriendsRouteMethodRelay) == SZFriendsRaceDecisionUpgrade);
    CHECK(decide(SZFriendsRouteMethodBluetooth, SZFriendsRouteMethodRelay) == SZFriendsRaceDecisionUpgrade);
    CHECK(decide(SZFriendsRouteMethodRelay, SZFriendsRouteMethodBluetooth) == SZFriendsRaceDecisionClose,
          "never the relay while another route works");
    CHECK(decide(SZFriendsRouteMethodInternet, SZFriendsRouteMethodInternet) == SZFriendsRaceDecisionClose,
          "within the Internet class the first path keeps the session");
    CHECK(decide(SZFriendsRouteMethodLAN, SZFriendsRouteMethodInternet) == SZFriendsRaceDecisionUpgrade);
    CHECK(decide(SZFriendsRouteMethodRelay, SZFriendsRouteMethodNone) == SZFriendsRaceDecisionAdopt);

    // SZFriendsSessionAWins: the class decides before the key, on both sides.
    NSData *low = SZFTestData(@"01"), *high = SZFTestData(@"02");
    CHECK(SZFriendsSessionAWins(SZFriendsRouteMethodInternet, high, SZFriendsRouteMethodBluetooth, low));
    CHECK(!SZFriendsSessionAWins(SZFriendsRouteMethodBluetooth, low, SZFriendsRouteMethodInternet, high));
    CHECK(SZFriendsSessionAWins(SZFriendsRouteMethodBluetooth, high, SZFriendsRouteMethodRelay, low));
    for (size_t i = 0; i < 5; i++) {
        for (size_t j = 0; j < 5; j++) {
            if (i == j) continue;
            BOOL aWins = SZFriendsSessionAWins(order[i], high, order[j], low);
            CHECK(aWins == (i < j) && aWins != SZFriendsSessionAWins(order[j], low, order[i], high),
                  "routes %ld/%ld", (long)order[i], (long)order[j]);
        }
    }
}

// ADR 0020: while the relay carries Mei's session her backoffs end at each probe, so an endpoint that failed many
// times is dialed again within a second; a later failure still counts on from where it was. Others' stay.
static void TestBackoffsEndWhileRelayed(void) {
    NSData *tag = SZFTestData(@"0101010101010101");
    __block NSDate *now = SZFTestDate(5000);
    SZFriendsRouteRacer *racer = [SZFriendsRouteRacer new];
    racer.clock = ^NSDate * {
        return now;
    };
    SZFriendsCandidate *mei = FriendCandidate(@[
        SZFTestSighting(SZFriendsDiscoveryMethodNetwork, SZFriendsRouteMethodLAN, @"lan", tag, @[], NO, now),
    ]);
    CHECK([racer attemptsForCandidate:mei].count == 1);
    for (int i = 0; i < 8; i++) {
        [racer noteHandshakeFailedAtEndpoint:@"lan" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
        now = [now dateByAddingTimeInterval:1];
    }
    CHECK([racer attemptsForCandidate:mei].count == 0, "minutes of backoff");
    [racer endBackoffsForConversation:@"kenji"];
    CHECK([racer attemptsForCandidate:mei].count == 0);
    [racer endBackoffsForConversation:@"mei"];
    CHECK([racer attemptsForCandidate:mei].count == 1, "dialed again at once");
    [racer noteHandshakeFailedAtEndpoint:@"lan" method:SZFriendsDiscoveryMethodNetwork conversationID:@"mei"];
    CHECK([racer.nextBackoffEnd timeIntervalSinceDate:now] > 60, "the count goes on");
}

static void TestLaunchDecision(void) {
    CHECK(SZFriendsStartAdapterAtLaunch(SZFriendsPermissionAllowed, NO));
    CHECK(!SZFriendsStartAdapterAtLaunch(SZFriendsPermissionDenied, YES));
    CHECK(!SZFriendsStartAdapterAtLaunch(SZFriendsPermissionNotDetermined, YES), "Bluetooth waits for the first open");
    CHECK(!SZFriendsStartAdapterAtLaunch(SZFriendsPermissionUnknown, NO), "Local Network: browsing is the ask");
    CHECK(SZFriendsStartAdapterAtLaunch(SZFriendsPermissionUnknown, YES));
}

void SZFriendsRunRacerTests(void) {
    TestAttempts();
    TestPeerToPeerWiFiCapability();
    TestDecisions();
    TestSessionRace();
    TestSessionRaceUnknownRoutes();
    TestExplicitRank();
    TestEndpointBackoff();
    TestTagBackoff();
    TestBackoffsEndWhileRelayed();
    TestLaunchDecision();
}

#pragma mark - Visibility

static SZFriendsInstant At(NSTimeInterval wall, NSTimeInterval continuous) {
    SZFriendsInstant instant = {wall, continuous};
    return instant;
}

void SZFriendsRunVisibilityTests(void) {
    const NSTimeInterval t0 = 1791787668, c0 = 5000;
    CHECK(SZFriendsVisibilityDuration == 300);
    SZFriendsVisibility *visibility = [[SZFriendsVisibility alloc] initWithStoredDeadline:nil now:At(t0, c0)];
    CHECK(![visibility isVisibleAt:At(t0, c0)] && visibility.deadline == nil);
    NSDate *deadline = [visibility startAt:At(t0, c0)];
    CHECK([deadline isEqual:SZFTestDate(t0 + 300)]);
    CHECK([[visibility startAt:At(t0 + 100, c0 + 100)] isEqual:deadline], "repeating does not extend");
    CHECK([visibility isVisibleAt:At(t0 + 299, c0 + 299)] && [visibility remainingAt:At(t0 + 299, c0 + 299)] == 1);
    CHECK(![visibility isVisibleAt:At(t0 + 300, c0 + 300)] && visibility.deadline == nil, "expiry clears it");
    CHECK([[visibility startAt:At(t0 + 400, c0 + 400)] isEqual:SZFTestDate(t0 + 700)], "a new start after expiry");
    [visibility stop];
    CHECK(![visibility isVisibleAt:At(t0 + 401, c0 + 401)] && visibility.deadline == nil);

    // Sleep: ten minutes asleep ends it, whether or not the continuous clock counted the nap.
    SZFriendsVisibility *sleeper = [[SZFriendsVisibility alloc] initWithStoredDeadline:nil now:At(t0, c0)];
    [sleeper startAt:At(t0, c0)];
    CHECK(![sleeper isVisibleAt:At(t0 + 600, c0 + 600)]);
    [sleeper startAt:At(t0 + 1000, c0 + 1000)];
    CHECK(![sleeper isVisibleAt:At(t0 + 1600, c0 + 1010)], "a clock that paused in sleep cannot extend it");

    // The wall clock set back: by 50 s the continuous clock still ends it on time; by 200 s it ends at once.
    SZFriendsVisibility *setBack = [[SZFriendsVisibility alloc] initWithStoredDeadline:nil now:At(t0, c0)];
    [setBack startAt:At(t0, c0)];
    CHECK([setBack isVisibleAt:At(t0 + 50, c0 + 100)] && [setBack remainingAt:At(t0 + 50, c0 + 100)] == 200);
    CHECK(![setBack isVisibleAt:At(t0 + 250, c0 + 300)]);
    [setBack startAt:At(t0 + 1000, c0 + 1000)];
    CHECK(![setBack isVisibleAt:At(t0 + 900, c0 + 1100)]);

    // Restart, disable then enable: the stored deadline stands, never extended, and fails closed when odd.
    SZFriendsVisibility *restored = [[SZFriendsVisibility alloc] initWithStoredDeadline:SZFTestDate(t0 + 300)
                                                                                    now:At(t0 + 120, 1)];
    CHECK([restored isVisibleAt:At(t0 + 120, 1)] && [restored remainingAt:At(t0 + 120, 1)] == 180);
    CHECK([[restored startAt:At(t0 + 130, 11)] isEqual:SZFTestDate(t0 + 300)]);
    SZFriendsVisibility *late = [[SZFriendsVisibility alloc] initWithStoredDeadline:SZFTestDate(t0 + 300)
                                                                                now:At(t0 + 400, 1)];
    CHECK(![late isVisibleAt:At(t0 + 400, 1)] && late.deadline == nil, "a wake past the deadline stops it first");
    SZFriendsVisibility *odd = [[SZFriendsVisibility alloc] initWithStoredDeadline:SZFTestDate(t0 + 600) now:At(t0, 1)];
    CHECK(odd.deadline == nil, "more than 5 minutes left means the clock moved: dropped");

    SZFriendsInstant a = SZFriendsInstantNow();
    usleep(20000);
    SZFriendsInstant b = SZFriendsInstantNow();
    CHECK(b.continuous > a.continuous && b.continuous - a.continuous < 1 && fabs(b.wall - a.wall) < 1);
}
