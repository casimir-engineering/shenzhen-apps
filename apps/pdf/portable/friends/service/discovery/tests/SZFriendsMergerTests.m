// The merger with scripted sightings: simultaneous, out-of-order, flapping and expiring; one row per person.

#import "SZFriendsDiscoveryTestSupport.h"

static const SZFriendsDiscoveryMethod Net = SZFriendsDiscoveryMethodNetwork;
static const SZFriendsDiscoveryMethod BT = SZFriendsDiscoveryMethodBluetooth;

static NSData *MeiTag(void) { return SZFTestData(@"0101010101010101"); }
static NSData *MeiNextTag(void) { return SZFTestData(@"0202020202020202"); }
static NSData *KenjiTag(void) { return SZFTestData(@"0303030303030303"); }
static NSData *StrangerTag(void) { return SZFTestData(@"0909090909090909"); }
static NSData *PriyaCallback(void) { return SZFTestData(@"0505050505050505"); }

static SZFriendsDiscoveryMerger *MakeMerger(void) {
    return [[SZFriendsDiscoveryMerger alloc] initWithTagMatcher:^NSString *(NSData *tag) {
        if ([tag isEqual:MeiTag()] || [tag isEqual:MeiNextTag()]) return @"mei";
        if ([tag isEqual:KenjiTag()]) return @"kenji";
        if ([tag isEqual:PriyaCallback()]) return @"priya";
        return nil;
    }];
}

static SZFriendsSighting *S(SZFriendsDiscoveryMethod method,
                            SZFriendsRouteMethod route,
                            NSString *endpoint,
                            NSData *tag,
                            NSTimeInterval seenAt) {
    return SZFTestSighting(method, route, endpoint, tag, @[], NO, SZFTestDate(seenAt));
}

static void TestSimultaneousAndOneRow(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"bt-mei", MeiTag(), 100)];
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"lan-mei", MeiTag(), 100)];
    [merger addSighting:S(Net, SZFriendsRouteMethodPeerToPeerWiFi, @"awdl-mei", MeiTag(), 100)];
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"lan-kenji", KenjiTag(), 100)];
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"bt-stranger", StrangerTag(), 100)];
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"lan-stranger", StrangerTag(), 100)];
    CHECK(merger.candidates.count == 2, "one row per person: %@", merger.candidates);
    CHECK(merger.identifiedCandidates.count == 2);
    SZFriendsCandidate *mei = merger.candidates[0];
    CHECK([mei.conversationID isEqual:@"mei"] && !mei.isPublic && mei.isIdentified);
    CHECK(mei.sightings.count == 3 && mei.sightings[0].route == SZFriendsRouteMethodLAN &&
              mei.sightings[1].route == SZFriendsRouteMethodPeerToPeerWiFi &&
              mei.sightings[2].route == SZFriendsRouteMethodBluetooth,
          "best route first");
    // A hidden stranger is never a candidate: one unmatched device across both methods, for Add by ID only.
    CHECK(merger.unmatchedDevices.count == 1 && merger.unmatchedDevices[0].sightings.count == 2);
    CHECK(merger.unmatchedDevices[0].conversationID == nil && !merger.unmatchedDevices[0].isIdentified);
    CHECK([merger candidateWithID:mei.candidateID] == mei);
}

static void TestOutOfOrder(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"e1", MeiNextTag(), 200)];
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"e1", KenjiTag(), 150)]; // older report arriving late
    CHECK(merger.candidates.count == 1 && [merger.candidates[0].conversationID isEqual:@"mei"]);
    CHECK([merger.candidates[0].sightings[0].presenceTag isEqual:MeiNextTag()], "the newer observation stands");

    [merger removeEndpoint:@"e1" method:Net atDate:SZFTestDate(190)]; // a removal older than the last sighting
    CHECK([merger expireAtDate:SZFTestDate(10000)] == NO && merger.candidates.count == 1, "stale removal ignored");

    [merger removeEndpoint:@"e1" method:Net atDate:SZFTestDate(300)];
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"e1", MeiNextTag(), 250)]; // an add from before the removal
    CHECK([merger expireAtDate:SZFTestDate(330)] && merger.candidates.count == 0, "stale add does not revive it");

    // A removal for an endpoint never seen, or on the other method, changes nothing.
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"x", MeiTag(), 400)];
    NSUInteger generation = merger.generation;
    [merger removeEndpoint:@"x" method:Net atDate:SZFTestDate(401)];
    [merger removeEndpoint:@"nobody" method:BT atDate:SZFTestDate(401)];
    CHECK(merger.generation == generation && merger.candidates.count == 1);
}

static void TestFlappingAndGrace(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"lan", MeiTag(), 100)];
    NSString *candidateID = merger.candidates[0].candidateID;
    NSUInteger generation = merger.generation;
    [merger removeEndpoint:@"lan" method:Net atDate:SZFTestDate(110)];
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"lan", MeiTag(), 115)];
    [merger removeEndpoint:@"lan" method:Net atDate:SZFTestDate(120)];
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"lan", MeiTag(), 121)];
    CHECK(merger.generation == generation, "a flap inside the grace changes nothing anyone sees");
    CHECK([merger.candidates[0].candidateID isEqual:candidateID]);

    [merger removeEndpoint:@"lan" method:Net atDate:SZFTestDate(200)];
    CHECK([merger.nextExpiry isEqual:SZFTestDate(200 + SZFriendsBonjourRemovalGrace)]);
    [merger removeEndpoint:@"lan" method:Net atDate:SZFTestDate(220)];
    CHECK([merger expireAtDate:SZFTestDate(229)] == NO && merger.candidates.count == 1, "lingers through the grace");
    CHECK([merger expireAtDate:SZFTestDate(230)] && merger.candidates.count == 0,
          "a repeated removal does not extend the grace");
    CHECK(merger.nextExpiry == nil);
    CHECK(SZFriendsBonjourRemovalGrace == 30 && SZFriendsBluetoothSightingLife == 90);
}

static void TestIndependentExpiry(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(), 100)];
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"lan", MeiTag(), 100)];
    NSString *candidateID = merger.candidates[0].candidateID;
    CHECK([merger.nextExpiry isEqual:SZFTestDate(190)]);
    CHECK([merger expireAtDate:SZFTestDate(189)] == NO);
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(), 160)]; // seen again: life restarts
    CHECK([merger expireAtDate:SZFTestDate(200)] == NO && merger.candidates[0].sightings.count == 2);
    CHECK([merger expireAtDate:SZFTestDate(250)], "Bluetooth expires on its own timer");
    SZFriendsCandidate *mei = merger.candidates[0];
    CHECK(mei.sightings.count == 1 && mei.sightings[0].route == SZFriendsRouteMethodLAN,
          "the route icon stays on Wi-Fi");
    CHECK([mei.candidateID isEqual:candidateID]);

    [merger removeEndpoint:@"lan" method:Net atDate:SZFTestDate(300)];
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(), 310)];
    CHECK([merger expireAtDate:SZFTestDate(330)] && merger.candidates.count == 1);
    CHECK(merger.candidates[0].sightings[0].route == SZFriendsRouteMethodBluetooth);
    CHECK([merger.candidates[0].candidateID isEqual:candidateID], "same row while any sighting is alive");
    // A Bluetooth "loss" neither shortens nor extends its life.
    [merger removeEndpoint:@"bt" method:BT atDate:SZFTestDate(320)];
    CHECK([merger expireAtDate:SZFTestDate(399)] == NO && merger.candidates.count == 1);
    CHECK([merger expireAtDate:SZFTestDate(400)] && merger.candidates.count == 0);
}

static void TestWindowRotation(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"name-w", MeiTag(), 890)];
    NSString *candidateID = merger.candidates[0].candidateID;
    // The next window: a new instance name with the next tag, then the old name goes away.
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"name-w1", MeiNextTag(), 901)];
    [merger removeEndpoint:@"name-w" method:Net atDate:SZFTestDate(902)];
    CHECK(merger.candidates.count == 1 && [merger.candidates[0].candidateID isEqual:candidateID]);
    [merger expireAtDate:SZFTestDate(1000)];
    CHECK(merger.candidates.count == 1 && merger.candidates[0].sightings.count == 1 &&
          [merger.candidates[0].candidateID isEqual:candidateID]);
}

static void TestPublicEntries(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    NSData *aikoKey = SZFTestData(@"aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00");
    [merger addSighting:SZFTestSighting(Net, SZFriendsRouteMethodLAN, @"pub-net", nil, @[], YES, SZFTestDate(100))];
    [merger addSighting:SZFTestSighting(BT, SZFriendsRouteMethodBluetooth, @"pub-bt", nil, @[], YES, SZFTestDate(100))];
    CHECK(merger.candidates.count == 2 && merger.candidates[0].isPublic, "unidentified: one candidate per endpoint");
    CHECK(merger.identifiedCandidates.count == 0, "a stranger appears only after a handshake returned key and profile");
    NSString *firstID = merger.candidates[0].candidateID;

    [merger identifyEndpoint:@"pub-net" method:Net identityKey:aikoKey conversationID:nil];
    CHECK(merger.identifiedCandidates.count == 1 && [merger.identifiedCandidates[0].identityKey isEqual:aikoKey]);
    [merger identifyEndpoint:@"pub-bt" method:BT identityKey:aikoKey conversationID:nil];
    CHECK(merger.candidates.count == 1 && merger.candidates[0].sightings.count == 2, "both methods, one row");
    CHECK([merger.candidates[0].candidateID isEqual:firstID] && merger.candidates[0].isPublic);

    // Mei is a friend and also visible: her public entry joins her row once a handshake says it is her.
    [merger addSighting:S(Net, SZFriendsRouteMethodLAN, @"mei-hidden", MeiTag(), 100)];
    NSString *meiID = [merger.candidates[1] candidateID];
    [merger addSighting:SZFTestSighting(Net, SZFriendsRouteMethodLAN, @"mei-public", nil, @[], YES, SZFTestDate(101))];
    CHECK(merger.candidates.count == 3);
    [merger identifyEndpoint:@"mei-public" method:Net identityKey:SZFTestData(@"bb") conversationID:@"mei"];
    CHECK(merger.candidates.count == 2 && merger.identifiedCandidates.count == 2);
    SZFriendsCandidate *mei = [merger candidateWithID:meiID];
    CHECK(mei.sightings.count == 2 && !mei.isPublic && [mei.conversationID isEqual:@"mei"], "the older id survives");

    // An identification is forgotten with its endpoint.
    [merger removeEndpoint:@"pub-net" method:Net atDate:SZFTestDate(200)];
    [merger expireAtDate:SZFTestDate(10000)];
    CHECK(merger.candidates.count == 1 && [merger.candidates[0].conversationID isEqual:@"mei"]);
    [merger identifyEndpoint:@"gone" method:Net identityKey:aikoKey conversationID:nil];
    CHECK(merger.candidates.count == 1);
}

static void TestCallbackAndRematch(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    // Priya asked for us by ID: her presence tag means nothing to us, her callback tag does.
    [merger addSighting:SZFTestSighting(Net, SZFriendsRouteMethodLAN, @"priya", StrangerTag(),
                                        @[ SZFTestData(@"ffffffffffffffff"), PriyaCallback() ], NO, SZFTestDate(100))];
    CHECK(merger.candidates.count == 1 && [merger.candidates[0].conversationID isEqual:@"priya"]);
    // Blocking Priya rebuilds the matcher without her: her device is a hidden stranger again, at once.
    NSUInteger generation = merger.generation;
    merger.tagMatcher = ^NSString *(NSData *tag) {
        (void)tag;
        return nil;
    };
    CHECK(merger.candidates.count == 0 && merger.unmatchedDevices.count == 1 && merger.generation != generation);
    // Accepting a stranger as a friend: their device becomes their row without waiting for a new sighting.
    merger.tagMatcher = ^NSString *(NSData *tag) {
        return [tag isEqual:StrangerTag()] ? @"new-friend" : nil;
    };
    CHECK(merger.candidates.count == 1 && [merger.candidates[0].conversationID isEqual:@"new-friend"]);
    CHECK(merger.unmatchedDevices.count == 0);
    // A presence match wins over a callback match.
    SZFriendsDiscoveryMerger *both = MakeMerger();
    [both addSighting:SZFTestSighting(Net, SZFriendsRouteMethodLAN, @"x", MeiTag(), @[ PriyaCallback() ], NO,
                                      SZFTestDate(1))];
    CHECK([both.candidates[0].conversationID isEqual:@"mei"]);
}

static void TestGeneration(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    NSUInteger start = merger.generation;
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(), 100)];
    NSUInteger afterAdd = merger.generation;
    CHECK(afterAdd != start);
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(), 130)];
    CHECK(merger.generation == afterAdd, "a re-sighting with the same content is not news");
    [merger addSighting:SZFTestSighting(BT, SZFriendsRouteMethodBluetooth, @"bt", MeiTag(), @[ PriyaCallback() ], NO,
                                        SZFTestDate(140))];
    CHECK(merger.generation != afterAdd, "new callback tags are");
}

// Lead decision 5: sightings sort by the explicit rank, so an Internet sighting comes before a Bluetooth one even
// though its wire number (4) is larger than Bluetooth's (3), and the relay comes last.
static void TestRankOrder(void) {
    SZFriendsDiscoveryMerger *merger = MakeMerger();
    [merger addSighting:S(BT, SZFriendsRouteMethodBluetooth, @"bt-mei", MeiTag(), 100)];
    [merger addSighting:S(Net, SZFriendsRouteMethodRelay, @"relay-mei", MeiTag(), 100)];
    [merger addSighting:S(Net, SZFriendsRouteMethodInternet, @"net-mei", MeiTag(), 100)];
    [merger addSighting:S(Net, SZFriendsRouteMethodPeerToPeerWiFi, @"awdl-mei", MeiTag(), 100)];
    CHECK(merger.candidates.count == 1);
    NSArray<SZFriendsSighting *> *sightings = merger.candidates.firstObject.sightings;
    CHECK(sightings.count == 4 && sightings[0].route == SZFriendsRouteMethodPeerToPeerWiFi &&
              sightings[1].route == SZFriendsRouteMethodInternet &&
              sightings[2].route == SZFriendsRouteMethodBluetooth && sightings[3].route == SZFriendsRouteMethodRelay,
          "P2P, Internet, Bluetooth, relay");
}

void SZFriendsRunMergerTests(void) {
    TestSimultaneousAndOneRow();
    TestRankOrder();
    TestOutOfOrder();
    TestFlappingAndGrace();
    TestIndependentExpiry();
    TestWindowRotation();
    TestPublicEntries();
    TestCallbackAndRematch();
    TestGeneration();
}
