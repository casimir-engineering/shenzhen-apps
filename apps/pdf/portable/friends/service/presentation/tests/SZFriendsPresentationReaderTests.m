// Decisions about what the reader sees, from the wave 3 UX critique: destructive actions armed or confirmed
// everywhere, Nearby's searching and nobody states, IDs that never break across lines, message times only where
// they help, list subtitles that lead with their status, and the mark for an ID the Friends host confirmed. Every
// snapshot built here is also validated against PROTOCOL.md's schemas.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsTransfers.h"

static SZFriendsPersonFacts *Person(NSString *conversationID, NSString *name, NSString *friendsID) {
    SZFriendsPersonFacts *person = [[SZFriendsPersonFacts alloc] init];
    person.conversationID = conversationID;
    person.name = name;
    person.friendsID = friendsID;
    person.picture = [SZFriendsPicture animalWithSet:1 index:7];
    person.routeKind = SZFriendsRouteKindLocal;
    person.routeMethod = SZFriendsRouteMethodLAN;
    person.lastInteractionAt = SZPHongKong(@"2026-10-12 10:00");
    return person;
}

static NSDictionary *Details(SZFriendsPersonFacts *person) {
    NSDictionary *data = [SZPBuilder(SZPAudience()) detailsForPerson:person waitingElsewhere:0 now:SZPNow()];
    SZPValidateSnapshot(data, @"details", person.conversationID);
    return data;
}

static NSDictionary *Conversation(SZFriendsPersonFacts *person, NSArray *items) {
    NSDictionary *data = [SZPBuilder(SZPAudience()) conversationForPerson:person items:items hasEarlier:NO
                                                          highlightItemID:nil waitingElsewhere:0 now:SZPNow()];
    SZPValidateSnapshot(data, @"conversation", person.conversationID);
    return data;
}

static NSDictionary *ListRow(SZFriendsPersonFacts *person, SZFriendsItemFacts *preview) {
    if (preview) person.lastPreviewItemID = person.lastMessageItemID = preview.itemID;
    person.lastMessageFileCount = preview.kind == SZFriendsItemFactsKindTransfer ? 1 : 0;
    NSDictionary *list = [SZPBuilder(SZPAudience()) listWithPeople:@[ person ]
                                                      previewItems:preview ? @{preview.itemID : preview} : @{}
                                                           profile:SZPProfileRaph() query:@"" now:SZPNow()];
    SZPValidateSnapshot(list, @"list", person.conversationID);
    return [list[@"rows"] firstObject];
}

static void ExpectArmedBlock(NSDictionary *action, NSString *who, NSString *where) {
    NSDictionary *arm = @{@"label" : @"Block?",
                          @"accessibility_label" : [@"Click again to block " stringByAppendingString:who],
                          @"seconds" : @4};
    SZPExpect([action[@"action"] isEqual:@"block"] && [action[@"style"] isEqual:@"destructive"] &&
                  [action[@"arm"] isEqual:arm],
              @"%@: Block is red and needs a second click, like the list row’s: %@", where, action);
}

static NSDictionary *ActionNamed(NSArray *actions, NSString *name) {
    for (NSDictionary *action in actions)
        if ([action[@"action"] isEqual:name]) return action;
    return nil;
}

// Every Block in the dropdown asks for a second click, Remove friend asks first, and both are drawn destructive;
// neither is ever a link. Every confirmation Friends asks for marks its button destructive.
static void TestDestructiveActions(void) {
    SZFriendsPersonFacts *mei = Person(@"c_mei", @"Mei Lin", @"jasmine-street");
    NSArray *actions = Details(mei)[@"actions"];
    ExpectArmedBlock(ActionNamed(actions, @"block"), @"Mei", @"details");
    NSDictionary *remove = ActionNamed(actions, @"remove_friend");
    SZPExpect([remove[@"style"] isEqual:@"destructive"] && [remove[@"confirm"][@"destructive"] isEqual:@YES] &&
                  [remove[@"confirm"][@"title"] isEqual:@"Remove Mei?"] &&
                  [remove[@"confirm"][@"confirm_label"] isEqual:@"Remove"] &&
                  [remove[@"confirm"][@"body"] containsString:@"won’t be sent"] && remove[@"confirm"][@"option"] == nil,
              @"Remove friend asks first, in red: %@", remove);

    mei.keyChangePending = YES;
    ExpectArmedBlock(ActionNamed(Details(mei)[@"key_change"][@"actions"], @"block"), @"Mei", @"key change card");

    SZFriendsPersonFacts *lena = Person(@"c_lena", @"Lena Weber", @"amber-falcon");
    lena.relation = SZFriendsPersonRelationIncomingRequest;
    NSArray *card = Conversation(lena, @[])[@"request"][@"actions"];
    ExpectArmedBlock(ActionNamed(card, @"block"), @"Lena", @"request card");
    for (NSDictionary *action in card) SZPExpect(![action[@"style"] isEqual:@"link"], @"no link on the card");

    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary *settings = [builder settingsWithProfile:SZPProfileRaph() people:@[]];
    SZPExpect([settings[@"history"][@"confirm"][@"destructive"] isEqual:@YES] &&
                  [settings[@"reset"][@"confirm"][@"destructive"] isEqual:@YES],
              @"Settings confirmations are destructive");
    SZFriendsProfileFacts *broken = SZPProfileRaph();
    broken.identityState = SZFriendsIdentityFactsStateUnavailable;
    NSDictionary *banner =
        [builder listWithPeople:@[] previewItems:@{} profile:broken query:@"" now:SZPNow()][@"banner"];
    SZPExpect([banner[@"action"][@"confirm"][@"destructive"] isEqual:@YES], @"banner reset is destructive");
}

static SZFriendsNearbyFacts *Working(NSDate *since) {
    SZFriendsNearbyFacts *facts = [[SZFriendsNearbyFacts alloc] init];
    facts.networkState = facts.bluetoothState = SZFriendsAdapterStateWorking;
    facts.searching = YES;
    facts.workingSince = since;
    return facts;
}

static NSDictionary *Nearby(SZFriendsNearbyFacts *facts, NSDate *now) {
    NSDictionary *data = [SZPBuilder(SZPAudience()) nearbyWithFacts:facts profile:SZPProfileRaph() query:@"" now:now];
    SZPValidateSnapshot(data, @"nearby", @"reader nearby");
    return data;
}

// For 8 seconds after a method starts working an empty Nearby says it is looking, once; then it says nobody is
// visible, once, with a body of its own. A spinner shows only beside people it has found.
static void TestNearbyStates(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDate *since = SZPNow();
    NSDictionary *data = Nearby(Working(since), [since dateByAddingTimeInterval:3]);
    SZPExpect([data[@"empty"][@"kind"] isEqual:@"searching"] && data[@"empty"][@"body"] == [NSNull null] &&
                  [data[@"empty"][@"title"] isEqual:@"Looking for people nearby…"] &&
                  data[@"status"] == [NSNull null],
              @"first seconds: looking, without a second spinner: %@ %@", data[@"empty"], data[@"status"]);
    NSDate *refresh = [builder nearbyRefreshDateWithFacts:Working(since) now:[since dateByAddingTimeInterval:3]];
    SZPExpect([refresh isEqual:[since dateByAddingTimeInterval:8]], @"rebuild when looking ends: %@", refresh);

    data = Nearby(Working(since), [since dateByAddingTimeInterval:8]);
    SZPExpect([data[@"empty"][@"kind"] isEqual:@"nobody"] && data[@"status"] == [NSNull null] &&
                  [data[@"empty"][@"body"] isEqual:@"ShenzhenPDF keeps looking while it’s open."] &&
                  ![data[@"empty"][@"body"] isEqual:data[@"visibility"][@"body"]],
              @"after 8 s: nobody, its own body, no spinner: %@ %@", data[@"empty"], data[@"status"]);
    SZPExpect(![builder nearbyRefreshDateWithFacts:Working(since) now:[since dateByAddingTimeInterval:8]],
              @"nothing left to rebuild for");
    SZPExpect([Nearby(Working(nil), since)[@"empty"][@"kind"] isEqual:@"nobody"], @"no start time: no guessing");

    SZFriendsNearbyFacts *found = SZPNearbyVisibleBluetoothOff();
    SZPExpect([Nearby(found, since)[@"status"][@"label"] isEqual:@"Still looking"], @"spinner beside people");

    SZFriendsNearbyFacts *off = [[SZFriendsNearbyFacts alloc] init];
    off.networkState = off.bluetoothState = SZFriendsAdapterStateRadioOff;
    data = Nearby(off, since);
    SZPExpect([data[@"alert"][@"title"] isEqual:@"Wi-Fi and Bluetooth are off"] && data[@"note"] == [NSNull null] &&
                  data[@"empty"] == [NSNull null],
              @"both radios off: one card names both, nothing repeats it: %@ %@ %@", data[@"alert"], data[@"note"],
              data[@"empty"]);
    off.bluetoothState = SZFriendsAdapterStateDenied;
    data = Nearby(off, since);
    SZPExpect([data[@"alert"][@"title"] isEqual:@"Wi-Fi is off"] && data[@"note"] == [NSNull null] &&
                  data[@"empty"] == [NSNull null] && data[@"visibility"][@"body"] == [NSNull null] &&
                  data[@"visibility"][@"action"] == [NSNull null],
              @"Wi-Fi off and Bluetooth denied: the card's one fix, no second problem under it: %@ %@", data[@"note"],
              data[@"visibility"]);
    // Bluetooth still finding people is worth its line under the card: it changes what the person can do.
    off.bluetoothState = SZFriendsAdapterStateWorking;
    SZPExpect([Nearby(off, since)[@"note"][@"text"] isEqual:@"Still looking over Bluetooth."], @"still Bluetooth");
}

static BOOL HasHyphenatedID(NSString *text) {
    return [text rangeOfString:@"[a-z]+-[a-z]+" options:NSRegularExpressionSearch].location != NSNotFound;
}

// Display strings join an ID's words with U+2011 so a line never breaks inside it; friends_id stays ASCII for Copy,
// and a filter typed or pasted either way finds the person.
static void TestIDsNeverBreak(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    SZFriendsProfileFacts *changed = SZPProfileIDChanged();
    NSDictionary *list = [builder listWithPeople:@[] previewItems:@{} profile:changed query:@"" now:SZPNow()];
    NSArray<NSString *> *shown =
        @[ list[@"banner"][@"text"], list[@"name_prompt"][@"note"], list[@"footer"][@"id_label"] ];
    for (NSString *text in shown)
        SZPExpect(!HasHyphenatedID(text) && [text containsString:@"walnut‑garden"], @"breakable ID: %@", text);
    SZPExpect([list[@"footer"][@"friends_id"] isEqual:@"walnut-garden"], @"the ID to copy is ASCII");
    SZPExpect([[builder.strings addByIDSentMessageForID:@"willow-breeze"] containsString:@"willow‑breeze"],
              @"Add by ID reply");

    SZFriendsPersonFacts *unnamed = Person(@"c_t", nil, @"tulip-canyon");
    for (NSString *query in @[ @"tulip-canyon", @"tulip‑canyon", @"tulip canyon" ]) {
        NSDictionary *found = [builder listWithPeople:@[ unnamed ] previewItems:@{} profile:SZPProfileRaph()
                                                query:query now:SZPNow()];
        SZPExpect([found[@"rows"] count] == 1, @"filter \"%@\" finds the ID", query);
    }
    NSDictionary *row = ListRow(unnamed, nil);
    SZPExpect([row[@"title"] isEqual:@"tulip‑canyon"] && [row[@"avatar"][@"initials"] isEqual:@"TC"],
              @"unnamed row: display title, initials from both words: %@", row);
}

// A message shows its time only 5 minutes or more after the message before it; the first of a day always does,
// transfers and events keep theirs, and the spoken label always says the time.
static void TestMessageTimes(void) {
    SZFriendsPersonFacts *mei = Person(@"c_m", @"Mei Lin", @"jasmine-street");
    NSArray *items = @[
        SZPMessage(@"m_1", NO, @"2026-10-11 23:58", @"late", 0),
        SZPMessage(@"m_2", YES, @"2026-10-12 00:01", @"after midnight", SZFriendsOutboxStateDelivered),
        SZPMessage(@"m_3", NO, @"2026-10-12 00:04", @"three minutes on", 0),
        SZPTransfer(@"t_1", NO, @"2026-10-12 00:05", @"Plan.pdf", 1000, SZFriendsTransferStateReceived),
        SZPMessage(@"m_4", NO, @"2026-10-12 00:09", @"five minutes after the last message", 0),
        SZPMessage(@"m_5", YES, @"2026-10-12 00:13:59", @"four fifty-nine", SZFriendsOutboxStateDelivered),
    ];
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    for (NSDictionary *item in Conversation(mei, items)[@"items"]) byID[item[@"item_id"]] = item;
    NSDictionary *expected = @{@"m_1" : @"23:58", @"m_2" : @"00:01", @"m_3" : [NSNull null], @"t_1" : @"00:05",
                               @"m_4" : @"00:09", @"m_5" : [NSNull null]};
    for (NSString *itemID in expected)
        SZPExpect([byID[itemID][@"time_label"] isEqual:expected[itemID]], @"%@ time %@, expected %@", itemID,
                  byID[itemID][@"time_label"], expected[itemID]);
    SZPExpect([byID[@"m_3"][@"accessibility_label"] containsString:@"00:04"], @"spoken label keeps the time");
}

// The changing part of a subtitle comes first, so it survives truncation; the status says whose it is.
static void TestStatusFirstSubtitles(void) {
    SZFriendsPersonFacts *priya = Person(@"c_p", @"Priya Raman", @"silver-ocean");
    SZFriendsItemFacts *queued = SZPTransfer(@"t_q", YES, @"2026-10-12 09:00", @"Plan.pdf", 1000,
                                             SZFriendsTransferStateQueued);
    NSDictionary *row = ListRow(priya, queued);
    SZPExpect([row[@"subtitle"] isEqual:@"You: 📎 Plan.pdf"] &&
                  [row[@"accessibility_label"] containsString:@"you sent Plan.pdf, it sends when Priya is nearby"],
              @"queued file: %@", row);
    SZFriendsItemFacts *automatic = SZPTransfer(@"t_a", NO, @"2026-10-12 09:00", @"Guide.pdf", 1000,
                                                SZFriendsTransferStateReceived);
    automatic.acceptedAutomatically = YES;
    SZPExpect([ListRow(priya, automatic)[@"subtitle"] isEqual:@"Priya: 📎 Guide.pdf"],
              @"automatic file");
    SZFriendsItemFacts *failed = SZPMessage(@"m_f", YES, @"2026-10-12 09:00", @"hello", SZFriendsOutboxStateFailed);
    SZPExpect([ListRow(priya, failed)[@"subtitle"] isEqual:@"Not sent · You: hello"], @"failed message");
    SZFriendsItemFacts *delivered = SZPMessage(@"m_d", YES, @"2026-10-12 09:00", @"hi", SZFriendsOutboxStateDelivered);
    SZPExpect([ListRow(priya, delivered)[@"subtitle"] isEqual:@"You: hi"], @"no status: who said it");
}

// The Friends host attested the ID: rows and details carry a mark with words for it; nothing else does.
static void TestIDConfirmed(void) {
    SZFriendsPersonFacts *answer = Person(@"c_a", nil, @"tulip-canyon");
    answer.relation = SZFriendsPersonRelationOutgoingRequest;
    NSDictionary *row = ListRow(answer, nil);
    SZPExpect([row[@"id_confirmed"] isEqual:@NO] && row[@"id_confirmed_label"] == [NSNull null], @"not attested");
    answer.friendsIDConfirmed = YES;
    row = ListRow(answer, nil);
    SZPExpect([row[@"id_confirmed"] isEqual:@YES] &&
                  [row[@"id_confirmed_label"] isEqual:@"ID confirmed by the Friends server"] &&
                  [row[@"accessibility_label"] hasSuffix:@", ID confirmed"],
              @"attested answer: %@", row);
    answer.relation = SZFriendsPersonRelationFriend;
    NSDictionary *details = Details(answer);
    SZPExpect([details[@"id_confirmed"] isEqual:@YES] && [details[@"id_confirmed_label"] length] > 0, @"details");
    answer.friendsID = nil; // no ID, nothing to confirm
    SZPExpect([Details(answer)[@"id_confirmed"] isEqual:@NO], @"no ID, no mark");
}

static void TestReaderStrings(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    SZFriendsStrings *s = builder.strings;
    NSDictionary *settings = [builder settingsWithProfile:SZPProfileRaph() people:@[]];
    SZPExpect([settings[@"name"][@"note"] isEqual:@"The name your friends see."], @"settings name note");
    NSDictionary *profile = [builder profileWithFacts:SZPProfileRaph() waitingElsewhere:0];
    SZPExpect([profile[@"picture"][@"choose_label"] isEqual:@"Change picture…"] &&
                  profile[@"id"][@"note"] == [NSNull null],
              @"profile words, and nothing about an unreserved ID until something happens to it: %@", profile);
    SZPExpect([[s messageForErrorCode:@"picture_invalid" details:@{}] containsString:@"picture under 5 MB"],
              @"picture, not photo");
    SZFriendsNearbyFacts *denied = SZPNearbyLocalNetworkDenied();
    SZPExpect([Nearby(denied, SZPNow())[@"alert"][@"title"] isEqual:@"ShenzhenPDF can’t find people on your network"],
              @"network denied title");
    for (NSString *value in SZFriendsEnglishCatalog().allValues)
        SZPExpect([value rangeOfString:@"photo" options:NSCaseInsensitiveSearch].location == NSNotFound ||
                      [value containsString:@"photos"],
                  @"\"photo\" where a picture is meant: %@", value);
    // Apostrophes are typographic, as in the host's own text, so a Friends line beside it (an AI chat card, a reply's
    // message) reads the same; welcome.strings and every snapshot carry these values unchanged.
    for (NSString *key in SZFriendsEnglishCatalog())
        SZPExpect(![SZFriendsEnglishCatalog()[key] containsString:@"'"], @"%@ has a straight apostrophe: %@", key,
                  SZFriendsEnglishCatalog()[key]);
    // The same words show in Shenzhen Files on Linux, and a friend's computer may be anything: a computer is a
    // computer (or its own name), never "Mac".
    NSRegularExpression *mac = [NSRegularExpression regularExpressionWithPattern:@"\\bMacs?\\b" options:0 error:NULL];
    for (NSString *key in SZFriendsEnglishCatalog()) {
        NSString *value = SZFriendsEnglishCatalog()[key];
        SZPExpect([mac firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] == nil,
                  @"%@ says Mac: %@", key, value);
    }
}

void SZPRunReaderTests(void) {
    TestDestructiveActions();
    TestNearbyStates();
    TestIDsNeverBreak();
    TestMessageTimes();
    TestStatusFirstSubtitles();
    TestIDConfirmed();
    TestReaderStrings();
}
