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

static void TestNearbyStates(void) {
    for (NSInteger network = SZFriendsAdapterStateNotAsked; network <= SZFriendsAdapterStateUnavailable; network++) {
        for (NSInteger bluetooth = SZFriendsAdapterStateNotAsked; bluetooth <= SZFriendsAdapterStateUnavailable;
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
    SZPExpect([NearbyData(facts, @"", nil)[@"empty"][@"kind"] isEqual:@"searching"], @"starting: searching");
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
    TestDetails();
    TestProfileAndSettings();
    TestSearch();
}
