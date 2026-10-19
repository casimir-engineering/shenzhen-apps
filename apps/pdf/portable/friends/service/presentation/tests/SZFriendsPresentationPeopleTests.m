// Edge cases for Nearby (every pair of method states), friend details, the profile, Settings and search results.

#import "SZFriendsPresentationWorld.h"

#import "service/identity/SZFriendsIdentity.h"

static NSDictionary *NearbyData(SZFriendsNearbyFacts *facts, NSString *query, NSDate *now) {
    NSDictionary *data = [SZPBuilder(SZPAudience()) nearbyWithFacts:facts profile:SZPProfileRaph() query:query
                                                                now:now ?: SZPNow()];
    SZPValidateSnapshot(data, @"nearby", [NSString stringWithFormat:@"nearby %ld/%ld", (long)facts.networkState,
                                                                    (long)facts.bluetoothState]);
    return data;
}

static NSString *Said(NSDictionary *data) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id value in @[ data[@"visibility"][@"body"] ?: @"", data[@"alert"], data[@"note"], data[@"empty"] ]) {
        if ([value isKindOfClass:NSString.class]) [parts addObject:value];
        if ([value isKindOfClass:NSDictionary.class])
            for (NSString *key in @[ @"title", @"body", @"text" ])
                if ([value[key] isKindOfClass:NSString.class]) [parts addObject:value[key]];
    }
    for (NSDictionary *method in data[@"methods"]) [parts addObject:method[@"label"]];
    return [parts componentsJoinedByString:@" | "];
}

// Allow while nothing has asked for access; Open Privacy Settings for a refusal; Try Again for a failure; and, with
// no identity, nothing about access or radios at all, since nothing ran (the owner's report of 2026-10-20: Bluetooth
// on, nothing refused, and the tab said to allow access in System Settings and that Bluetooth was not working).
static void TestNearbyAsksAndRetries(void) {
    SZFriendsNearbyFacts *facts = [[SZFriendsNearbyFacts alloc] init];
    facts.networkState = facts.bluetoothState = SZFriendsAdapterStateNotAsked;
    NSDictionary *data = NearbyData(facts, @"", nil);
    SZPExpect([data[@"alert"][@"action"][@"action"] isEqual:@"activate"] &&
                  [data[@"alert"][@"action"][@"label"] isEqual:@"Allow"] && data[@"note"] == [NSNull null],
              @"not asked: one card with Allow: %@ %@", data[@"alert"], data[@"note"]);
    SZPExpect(![data[@"empty"][@"title"] containsString:@"Looking"], @"not asked is not looking: %@", data[@"empty"]);
    facts.networkState = SZFriendsAdapterStateWorking;
    data = NearbyData(facts, @"", nil);
    SZPExpect(data[@"alert"] == [NSNull null] && [data[@"note"][@"action"][@"action"] isEqual:@"activate"],
              @"Bluetooth not asked: a quiet line with Allow: %@", data[@"note"]);

    facts.networkState = facts.bluetoothState = SZFriendsAdapterStateDenied;
    data = NearbyData(facts, @"", nil);
    SZPExpect([data[@"visibility"][@"action"][@"settings_target"] isEqual:@"local_network_privacy"],
              @"both refused: visibility opens the Local Network pane: %@", data[@"visibility"]);
    facts.networkState = SZFriendsAdapterStateUnavailable;
    data = NearbyData(facts, @"", nil);
    SZPExpect([data[@"visibility"][@"action"][@"settings_target"] isEqual:@"bluetooth_privacy"],
              @"Bluetooth refused, network failing: the Bluetooth pane: %@", data[@"visibility"]);
    SZPExpect([data[@"alert"][@"action"][@"action"] isEqual:@"activate"], @"failing network: Try Again");
    facts.bluetoothState = SZFriendsAdapterStateUnavailable;
    data = NearbyData(facts, @"", nil);
    SZPExpect(![Said(data) containsString:@"System Settings"] &&
                  [data[@"visibility"][@"action"][@"action"] isEqual:@"activate"],
              @"both failing: no permission words, Try Again: %@", Said(data));
    facts.networkState = SZFriendsAdapterStateWorking;
    facts.bluetoothState = SZFriendsAdapterStateUnsupported;
    data = NearbyData(facts, @"", nil);
    SZPExpect([data[@"note"][@"text"] containsString:@"can’t use Bluetooth"] && data[@"note"][@"action"] == [NSNull null] &&
                  [data[@"methods"][1][@"state"] isEqual:@"unavailable"],
              @"no Bluetooth on this computer is said as such: %@", data[@"note"]);

    SZFriendsProfileFacts *profile = SZPProfileRaph();
    profile.identityState = SZFriendsIdentityFactsStateUnavailable;
    facts.networkState = facts.bluetoothState = SZFriendsAdapterStateUnavailable;
    data = [SZPBuilder(SZPAudience()) nearbyWithFacts:facts profile:profile query:@"" now:SZPNow()];
    SZPValidateSnapshot(data, @"nearby", @"nearby without an identity");
    SZPExpect(data[@"alert"] == [NSNull null] && data[@"note"] == [NSNull null] &&
                  [data[@"methods"][0][@"state"] isEqual:@"not_asked"],
              @"no identity: no card, no line: %@", data);
    SZPExpect([Said(data) containsString:@"Reset Friends"] && ![Said(data) containsString:@"System Settings"] &&
                  ![Said(data) containsString:@"Bluetooth"] && ![Said(data) containsString:@"network"],
              @"no identity: says reset, nothing about access or radios: %@", Said(data));
}

// Settings' Nearby line for each case, with the button that fixes it.
static void TestSettingsNearby(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    SZFriendsProfileFacts *profile = SZPProfileRaph();
    struct {
        SZFriendsAdapterState network, bluetooth;
        NSString *action, *target, *words;
    } cases[] = {
        {SZFriendsAdapterStateNotAsked, SZFriendsAdapterStateNotAsked, @"activate", nil, @"you’re asked"},
        {SZFriendsAdapterStateDenied, SZFriendsAdapterStateWorking, @"open_settings", @"local_network_privacy",
         @"Local Network access is off"},
        {SZFriendsAdapterStateWorking, SZFriendsAdapterStateDenied, @"open_settings", @"bluetooth_privacy",
         @"Bluetooth access is off"},
        {SZFriendsAdapterStateRadioOff, SZFriendsAdapterStateWorking, @"open_settings", @"wifi", @"Wi-Fi is off"},
        {SZFriendsAdapterStateWorking, SZFriendsAdapterStateRadioOff, @"open_settings", @"bluetooth",
         @"Bluetooth is off"},
        {SZFriendsAdapterStateUnavailable, SZFriendsAdapterStateWorking, @"activate", nil, @"isn’t working"},
        {SZFriendsAdapterStateWorking, SZFriendsAdapterStateUnsupported, nil, nil,
         @"can’t use Bluetooth. ShenzhenPDF finds people nearby on your network."},
        {SZFriendsAdapterStateUnsupported, SZFriendsAdapterStateWorking, nil, nil,
         @"can’t look for people on your network. ShenzhenPDF finds people nearby over Bluetooth."},
        {SZFriendsAdapterStateUnsupported, SZFriendsAdapterStateUnsupported, nil, nil,
         @"can’t find people nearby on this computer"},
        {SZFriendsAdapterStateWorking, SZFriendsAdapterStateWorking, nil, nil, @"can find people nearby"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        SZFriendsNearbyFacts *facts = [[SZFriendsNearbyFacts alloc] init];
        facts.networkState = cases[i].network;
        facts.bluetoothState = cases[i].bluetooth;
        NSMutableDictionary *settings = [[builder settingsWithProfile:profile people:@[]] mutableCopy];
        settings[@"nearby"] = [builder nearbyAccessWithFacts:facts profile:profile];
        SZPValidateSnapshot(settings, @"settings", [NSString stringWithFormat:@"settings nearby %zu", i]);
        NSDictionary *nearby = settings[@"nearby"];
        id action = nearby[@"action"];
        SZPExpect(cases[i].action ? [action[@"action"] isEqual:cases[i].action] : action == [NSNull null],
                  @"case %zu action: %@", i, action);
        if (cases[i].target) SZPExpect([action[@"settings_target"] isEqual:cases[i].target], @"case %zu: %@", i, action);
        SZPExpect([nearby[@"note"] containsString:cases[i].words], @"case %zu note: %@", i, nearby[@"note"]);
    }
    profile.identityState = SZFriendsIdentityFactsStateUnavailable;
    NSDictionary *nearby = [builder nearbyAccessWithFacts:[[SZFriendsNearbyFacts alloc] init] profile:profile];
    SZPExpect([nearby[@"note"] containsString:@"reset Friends"] && nearby[@"action"] == [NSNull null],
              @"no identity: %@", nearby);
}

static void TestNearbyStates(void) {
    for (NSInteger network = SZFriendsAdapterStateNotAsked; network <= SZFriendsAdapterStateUnsupported; network++) {
        for (NSInteger bluetooth = SZFriendsAdapterStateNotAsked; bluetooth <= SZFriendsAdapterStateUnsupported;
             bluetooth++) {
            SZFriendsNearbyFacts *facts = [[SZFriendsNearbyFacts alloc] init];
            facts.networkState = network;
            facts.bluetoothState = bluetooth;
            NSDictionary *data = NearbyData(facts, @"", nil);
            BOOL alert = data[@"alert"] != [NSNull null], note = data[@"note"] != [NSNull null];
            // Never an alert and a note about the same method: under the network card the line is about Bluetooth,
            // who is still found or what is wrong with it, and the empty state leaves the remedy to the card.
            if (alert && note) SZPExpect([data[@"note"][@"text"] containsString:@"Bluetooth"],
                                         @"%ld/%ld alert and note: %@", (long)network, (long)bluetooth, data[@"note"]);
            if (alert && [data[@"empty"] isKindOfClass:NSDictionary.class])
                SZPExpect(data[@"empty"][@"body"] == [NSNull null], @"%ld/%ld: the card says it, the empty state "
                          @"does not repeat it: %@", (long)network, (long)bluetooth, data[@"empty"]);
            BOOL bluetoothBroken = bluetooth >= SZFriendsAdapterStateDenied;
            BOOL bothRadiosOff = network == SZFriendsAdapterStateRadioOff && bluetooth == SZFriendsAdapterStateRadioOff;
            if (alert && bluetoothBroken)
                SZPExpect(bothRadiosOff ? !note && [data[@"alert"][@"title"] containsString:@"Bluetooth"] : note,
                          @"%ld/%ld: Bluetooth’s state is named somewhere: %@ %@", (long)network, (long)bluetooth,
                          data[@"alert"], data[@"note"]);
            SZPExpect(data[@"empty"] != [NSNull null], @"%ld/%ld says why nobody shows", (long)network,
                      (long)bluetooth);
            BOOL bothBroken = network >= SZFriendsAdapterStateDenied && bluetooth >= SZFriendsAdapterStateDenied;
            SZPExpect(!bothBroken || ([data[@"empty"][@"kind"] isEqual:@"unavailable"] &&
                                      [data[@"visibility"][@"state"] isEqual:@"unavailable"]),
                      @"%ld/%ld: nothing works, never an empty successful search", (long)network, (long)bluetooth);
        }
    }
    SZFriendsNearbyFacts *facts = [[SZFriendsNearbyFacts alloc] init];
    facts.networkState = SZFriendsAdapterStateStarting;
    facts.bluetoothState = SZFriendsAdapterStateStarting;
    SZPExpect([NearbyData(facts, @"", nil)[@"empty"][@"kind"] isEqual:@"searching"], @"starting: searching");
    TestNearbyAsksAndRetries();
    facts.networkState = facts.bluetoothState = SZFriendsAdapterStateWorking;
    SZPExpect([NearbyData(facts, @"", nil)[@"empty"][@"kind"] isEqual:@"nobody"], @"working, nobody visible");
    facts.bluetoothState = SZFriendsAdapterStateDenied;
    NSDictionary *note = NearbyData(facts, @"", nil)[@"note"];
    SZPExpect([note[@"action"][@"settings_target"] isEqual:@"bluetooth_privacy"] &&
                  [note[@"text"] containsString:@"ShenzhenPDF"],
              @"Bluetooth denied: quiet line with privacy settings: %@", note);
    facts.networkState = SZFriendsAdapterStateRadioOff;
    facts.bluetoothState = SZFriendsAdapterStateWorking;
    SZPExpect([NearbyData(facts, @"", nil)[@"alert"][@"action"][@"settings_target"] isEqual:@"wifi"],
              @"Wi-Fi off card");

    SZFriendsNearbyFacts *visible = SZPNearbyVisibleBluetoothOff();
    NSDate *deadline = visible.visibilityDeadline;
    NSDictionary *data = NearbyData(visible, @"", [deadline dateByAddingTimeInterval:-1]);
    SZPExpect([data[@"visibility"][@"remaining_label"] isEqual:@"0:01"], @"last second");
    data = NearbyData(visible, @"", [deadline dateByAddingTimeInterval:1]);
    SZPExpect([data[@"visibility"][@"state"] isEqual:@"hidden"], @"expiry never extends the deadline");
    data = NearbyData(visible, @"nobody-here", nil);
    SZPExpect([data[@"empty"][@"kind"] isEqual:@"no_match"] && [data[@"people"] count] == 0, @"filter with no match");
    data = NearbyData(visible, @"lagoon", nil);
    SZPExpect([data[@"people"] count] == 1 && [data[@"people"][0][@"title"] isEqual:@"coral\u2011lagoon"],
              @"filter by ID");

    SZFriendsNearbyPersonFacts *asked = visible.people[1];
    asked.relation = SZFriendsPersonRelationIncomingRequest;
    SZFriendsNearbyPersonFacts *blocked = visible.people[3];
    blocked.relation = SZFriendsPersonRelationBlocked;
    data = NearbyData(visible, @"", nil);
    SZPExpect([data[@"people"] count] == 3, @"blocked people never appear");
    SZPExpect([data[@"people"][1][@"status_label"] isEqual:@"Wants to be friends"] &&
                  data[@"people"][1][@"action"] == [NSNull null],
              @"someone who asked you: %@", data[@"people"][1]);
}

static NSDictionary *Details(SZFriendsPersonFacts *person, NSInteger waiting) {
    NSDictionary *data = [SZPBuilder(SZPAudience()) detailsForPerson:person waitingElsewhere:waiting now:SZPNow()];
    SZPValidateSnapshot(data, @"details", person.conversationID);
    return data;
}

static void TestDetails(void) {
    NSDictionary *people = SZPPeople();
    SZFriendsPersonFacts *kenji = people[@"c_kenji"];
    kenji.comparisonCode = @"418270";
    NSDictionary *data = Details(kenji, 2);
    SZPExpect([data[@"verification"][@"comparison_code"] isEqual:@"418 270"] &&
                  [data[@"verification"][@"action"][@"action"] isEqual:@"mark_verified"] &&
                  [data[@"back"][@"badge_count"] isEqual:@2] &&
                  [data[@"back"][@"accessibility_label"]
                      isEqual:@"Back to the conversation with Kenji, 2 more waiting for you in Friends"],
              @"unverified with a live code: %@", data[@"verification"]);
    kenji.routeKind = SZFriendsRouteKindOffline;
    data = Details(kenji, 0);
    SZPExpect(data[@"verification"][@"comparison_code"] == [NSNull null] &&
                  data[@"verification"][@"action"] == [NSNull null] &&
                  [data[@"verification"][@"body"]
                      isEqual:@"Compare codes the next time you’re both online or nearby to be sure this is really "
                              @"Kenji."],
              @"no code without a live session, and the next session may be online: %@", data[@"verification"]);
    kenji.relation = SZFriendsPersonRelationBlocked;
    data = Details(kenji, 0);
    SZPExpect([[data[@"actions"] valueForKey:@"action"] isEqual:(@[ @"delete_history", @"unblock" ])] &&
                  [data[@"auto_accept"][@"available"] isEqual:@NO],
              @"blocked: their chat's history and unblock only, no automatic acceptance");
    SZFriendsPersonFacts *daniel = people[@"c_daniel"];
    daniel.keyChangePending = YES;
    daniel.receivedFileCount = 1;
    daniel.friendsID = nil;
    data = Details(daniel, 0);
    SZPExpect([[data[@"key_change"][@"actions"] valueForKey:@"action"] isEqual:(@[ @"accept_key_change", @"block" ])] &&
                  [data[@"received"][@"label"] isEqual:@"Received from Daniel: 1 file"] &&
                  data[@"received"][@"action"] == [NSNull null] && data[@"friends_id"] == [NSNull null],
              @"key change, one file, no ID: %@", data);
}

static void TestProfileAndSettings(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    SZFriendsProfileFacts *profile = SZPProfileRaph();
    profile.friendsIDState = SZFriendsIDStateReserved;
    NSDictionary *data = [builder profileWithFacts:profile waitingElsewhere:3];
    SZPExpect([data[@"id"][@"state"] isEqual:@"reserved"] &&
                  [data[@"id"][@"note"] isEqual:@"People can add you with it."] &&
                  [data[@"back"][@"accessibility_label"] isEqual:@"Back to Friends, 3 waiting"],
              @"reserved profile: %@", data[@"id"]);
    SZPValidateSnapshot(data, @"profile", @"reserved");
    profile = SZPProfileIDChanged();
    profile.picture = [SZFriendsPicture placeholder];
    profile.identityPublicKey = [NSData dataWithBytes:(const unsigned char[]){0xfb, 0xff, 0xfe} length:3];
    data = [builder profileWithFacts:profile waitingElsewhere:0];
    SZPExpect([data[@"id"][@"state"] isEqual:@"changed"] &&
                  [data[@"id"][@"note"] containsString:@"walnut\u2011valley"] &&
                  data[@"picture"][@"selected_index"] == [NSNull null] && data[@"id"][@"qr_payload"] == [NSNull null] &&
                  data[@"id"][@"qr_label"] == [NSNull null] && [data[@"id"][@"friends_id"] isEqual:@"walnut-garden"],
              @"changed profile, placeholder picture, no QR in M1, raw ID to copy: %@", data[@"id"]);
    SZPValidateSnapshot(data, @"profile", @"changed");
    profile.identityState = SZFriendsIdentityFactsStateUnavailable;
    SZPExpect([[builder profileWithFacts:profile waitingElsewhere:0][@"id"][@"state"] isEqual:@"unavailable"],
              @"unavailable identity");

    NSMutableArray *friends = [NSMutableArray array];
    for (NSString *name in @[ @"Ann Lee", @"Bo Chan", @"Cy Wu", @"Di Ng", @"Ed Ho", @"Flo Yu" ]) {
        SZFriendsPersonFacts *person = [[SZFriendsPersonFacts alloc] init];
        person.conversationID = [@"c_" stringByAppendingString:[name substringToIndex:2]];
        person.name = name;
        person.lastInteractionAt = [SZPNow() dateByAddingTimeInterval:-(double)friends.count * 60];
        [friends addObject:person];
    }
    NSString *(^note)(NSArray *, NSUInteger) = ^NSString *(NSArray *people, NSUInteger enabled) {
      for (NSUInteger i = 0; i < people.count; i++) ((SZFriendsPersonFacts *)people[i]).autoAccept = i < enabled;
      NSDictionary *settings = [builder settingsWithProfile:SZPProfileRaph() people:people];
      SZPValidateSnapshot(settings, @"settings", @"settings");
      return settings[@"auto_accept"][@"note"];
    };
    SZPExpect([note(@[], 0) isEqual:@"Turn it on for a friend in their details."], @"no friends");
    SZPExpect([note(friends, 0) isEqual:@"Off. Every file waits for you to accept it."], @"none enabled");
    SZPExpect([note([friends subarrayWithRange:NSMakeRange(0, 1)], 1) isEqual:@"From Ann Lee."], @"only friend");
    SZPExpect([note([friends subarrayWithRange:NSMakeRange(0, 3)], 3) isEqual:@"From every friend."], @"all");
    SZPExpect([note(friends, 3) isEqual:@"From Ann Lee, Bo Chan and Cy Wu. Everyone else asks first."], @"three named");
    SZPExpect([note(friends, 4) isEqual:@"From Ann Lee, Bo Chan and 2 others. Everyone else asks first."],
              @"many: %@", note(friends, 4));
}

static void TestSearch(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary *people = SZPPeople();
    NSDictionary *empty = [builder searchResultWithHits:@[] people:people more:NO now:SZPNow()];
    SZPExpect([empty[@"empty_label"] isEqual:@"No messages or files match."], @"empty search");
    SZPValidateResult(empty, @"search_messages", @"empty search");

    NSString *padding = [@"" stringByPaddingToLength:200 withString:@"lorem ipsum " startingAtIndex:0];
    SZFriendsSearchHitFacts *deep = [[SZFriendsSearchHitFacts alloc] init];
    deep.conversationID = @"c_mei";
    deep.itemID = @"m_deep";
    deep.sentAt = SZPHongKong(@"2026-10-05 09:00");
    deep.text = [NSString stringWithFormat:@"%@合同%@", padding, padding];
    deep.matchRanges = @[ [NSValue valueWithRange:NSMakeRange(200, 2)] ];
    SZFriendsSearchHitFacts *orphan = [[SZFriendsSearchHitFacts alloc] init];
    orphan.conversationID = @"c_deleted";
    NSDictionary *result = [builder searchResultWithHits:@[ deep, orphan ] people:people more:YES now:SZPNow()];
    NSArray *excerpt = [result[@"results"] firstObject][@"excerpt"];
    SZPExpect([result[@"results"] count] == 1 && [result[@"more"] isEqual:@YES], @"orphan hits skipped");
    SZPExpect([excerpt.firstObject[@"text"] isEqual:@"…"] && [excerpt.lastObject[@"text"] isEqual:@"…"] &&
                  [excerpt[2][@"text"] isEqual:@"合同"] && [excerpt[2][@"match"] isEqual:@YES],
              @"two-character Chinese match in a window: %@", excerpt);
    SZPExpect([[result[@"results"] firstObject][@"time_label"] isEqual:@"5 Oct"], @"search time label");
    SZPValidateResult(result, @"search_messages", @"windowed search");
}

void SZPRunPeopleEdgeTests(void) {
    TestNearbyStates();
    TestSettingsNearby();
    TestDetails();
    TestProfileAndSettings();
    TestSearch();
}
