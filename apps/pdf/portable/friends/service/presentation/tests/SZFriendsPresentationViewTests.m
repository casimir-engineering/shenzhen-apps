// View edge cases beyond the fixtures: badge counting, list filters, previews and row states, every transfer and
// message state, links, highlights, request cards and composer hints. Every snapshot built here is also validated
// against PROTOCOL.md's schemas, so a state the fixtures never show still produces a valid frame.

#import "SZFriendsPresentationWorld.h"

#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsTransfers.h"

static NSDate *Now(void) {
    return SZPNow();
}

static SZFriendsPersonFacts *Friend(NSString *conversationID, NSString *name) {
    SZFriendsPersonFacts *person = [[SZFriendsPersonFacts alloc] init];
    person.conversationID = conversationID;
    person.name = name;
    person.friendsID = [conversationID stringByAppendingString:@"-id"];
    person.picture = [SZFriendsPicture animalWithSet:1 index:7];
    person.routeKind = SZFriendsRouteKindLocal;
    person.routeMethod = SZFriendsRouteMethodLAN;
    person.lastInteractionAt = SZPHongKong(@"2026-10-12 10:00");
    return person;
}

static NSDictionary *List(NSArray *people, NSDictionary *items, NSString *query) {
    NSDictionary *list = [SZPBuilder(SZPAudience()) listWithPeople:people previewItems:items ?: @{}
                                                           profile:SZPProfileRaph() query:query now:Now()];
    SZPValidateSnapshot(list, @"list", [NSString stringWithFormat:@"list(%@)", query]);
    return list;
}

static void TestBadge(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary *badge = [builder badgeWithPeople:@[]];
    SZPExpect([badge[@"label"] isEqual:@""] && [badge[@"accessibility_label"] isEqual:@"Friends"], @"empty badge");
    SZFriendsPersonFacts *offers = Friend(@"c_a", @"Ana");
    offers.offersWaiting = 3; // one row, however many offers
    SZFriendsPersonFacts *blocked = Friend(@"c_b", @"Bo");
    blocked.relation = SZFriendsPersonRelationBlocked;
    blocked.offersWaiting = 2; // blocked people cannot offer; never counted
    badge = [builder badgeWithPeople:@[ offers, blocked ]];
    SZPExpect([badge[@"count"] isEqual:@1] && [badge[@"accessibility_label"] isEqual:@"Friends, 1 waiting for you"],
              @"badge counts rows: %@", badge);
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 120; i++) {
        SZFriendsPersonFacts *request = Friend([NSString stringWithFormat:@"c_%d", i], @"Someone New");
        request.relation = SZFriendsPersonRelationIncomingRequest;
        [many addObject:request];
    }
    badge = [builder badgeWithPeople:many];
    SZPExpect([badge[@"label"] isEqual:@"99+"] && [badge[@"count"] isEqual:@120], @"99+ badge");
    SZPValidateSnapshot(badge, @"badge", @"badge 120");
}

static void TestListRows(void) {
    NSDictionary *people = SZPPeople();
    NSArray *everyone = [people allValues];
    NSDictionary *items = SZPPreviewItems();
    NSArray *rows = List(everyone, items, @"MEI")[@"rows"];
    SZPExpect(rows.count == 1 && [rows[0][@"conversation_id"] isEqual:@"c_mei"], @"case-insensitive name filter");
    rows = List(everyone, items, @"jasmine street")[@"rows"];
    SZPExpect(rows.count == 1 && [rows[0][@"conversation_id"] isEqual:@"c_mei"], @"ID typed with a space");
    NSDictionary *none = List(everyone, items, @" zzz ");
    SZPExpect([none[@"rows"] count] == 0 && [none[@"empty"][@"kind"] isEqual:@"no_match"] &&
                  [none[@"empty"][@"title"] containsString:@"“zzz”"],
              @"no match empty state: %@", none[@"empty"]);
    SZFriendsPersonFacts *tomas = Friend(@"c_tomas", @"Tomás Rivera");
    SZPExpect([List(@[ tomas ], nil, @"tomas")[@"rows"] count] == 1, @"diacritic-insensitive");

    // Equal times keep a stable order by conversation id.
    NSArray *tied = List(@[ Friend(@"c_z", @"Zed"), Friend(@"c_a", @"Ann") ], nil, @"")[@"rows"];
    SZPExpect([tied[0][@"conversation_id"] isEqual:@"c_a"], @"ties ordered by id");

    SZFriendsPersonFacts *blocked = Friend(@"c_blocked", @"Bo Block");
    blocked.relation = SZFriendsPersonRelationBlocked;
    blocked.offersWaiting = 1;
    SZFriendsPersonFacts *outgoing = Friend(@"c_out", @"Olu Out");
    outgoing.relation = SZFriendsPersonRelationOutgoingRequest;
    outgoing.routeKind = SZFriendsRouteKindNone;
    SZFriendsPersonFacts *removed = Friend(@"c_removed", @"Rae Removed");
    removed.relation = SZFriendsPersonRelationRemoved;
    SZFriendsPersonFacts *keyChange = Friend(@"c_key", @"Kim Key");
    keyChange.keyChangePending = YES;
    SZFriendsPersonFacts *offers = Friend(@"c_offers", @"Ola Offers");
    offers.offersWaiting = 3;
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    for (NSDictionary *row in List(@[ blocked, outgoing, removed, keyChange, offers ], nil, @"")[@"rows"])
        byID[row[@"conversation_id"]] = row;
    SZPExpect([byID[@"c_blocked"][@"blocked"] isEqual:@YES] && [byID[@"c_blocked"][@"subtitle"] isEqual:@"Blocked"] &&
                  byID[@"c_blocked"][@"waiting"] == [NSNull null] && byID[@"c_blocked"][@"drop_label"] == [NSNull null],
              @"blocked row: %@", byID[@"c_blocked"]);
    SZPExpect([byID[@"c_out"][@"subtitle"] isEqual:@"Request sent"] &&
                  byID[@"c_out"][@"route"][@"label"] == [NSNull null] &&
                  [byID[@"c_out"][@"accessibility_label"] isEqual:@"Olu Out, request sent, 10:00"],
              @"outgoing request row: %@", byID[@"c_out"]);
    SZPExpect([byID[@"c_removed"][@"subtitle"] isEqual:@"No longer friends"] &&
                  byID[@"c_removed"][@"drop_label"] == [NSNull null],
              @"removed row");
    SZPExpect([byID[@"c_key"][@"waiting"][@"kind"] isEqual:@"key_change"] &&
                  [byID[@"c_key"][@"subtitle"] isEqual:@"Key changed. Check it’s really Kim"],
              @"key change row: %@", byID[@"c_key"]);
    SZPExpect([byID[@"c_offers"][@"subtitle"] isEqual:@"Sent you 3 files"], @"several offers");

    // Previews: an outgoing queued message says when it goes and drops the route; long text is cut to one line.
    SZFriendsPersonFacts *mei = Friend(@"c_mei2", @"Mei Lin");
    mei.lastPreviewItemID = @"m_q";
    SZFriendsItemFacts *queued = SZPMessage(@"m_q", YES, @"2026-10-12 10:00", @"hi", SZFriendsOutboxStateQueued);
    NSDictionary *row = List(@[ mei ], @{@"m_q" : queued}, @"")[@"rows"][0];
    SZPExpect([row[@"subtitle"] isEqual:@"Sends when Mei is nearby · hi"] &&
                  [row[@"accessibility_label"] isEqual:@"Mei Lin, you said hi, it sends when Mei is nearby, 10:00"],
              @"queued message preview: %@", row);
    NSString *longText = [@"" stringByPaddingToLength:300 withString:@"word \n" startingAtIndex:0];
    row = List(@[ mei ], @{@"m_q" : SZPMessage(@"m_q", NO, @"2026-10-12 10:00", longText, 0)}, @"")[@"rows"][0];
    SZPExpect([row[@"subtitle"] length] <= 121 && [row[@"subtitle"] hasSuffix:@"…"] &&
                  ![row[@"subtitle"] containsString:@"\n"],
              @"long preview cut to one line (%lu)", (unsigned long)[row[@"subtitle"] length]);
    SZFriendsItemFacts *keyEvent = SZPEvent(@"e_k", @"2026-10-12 10:00", SZFriendsEventKeyChanged);
    row = List(@[ mei ], @{@"m_q" : keyEvent}, @"")[@"rows"][0];
    SZPExpect([row[@"accessibility_label"] hasPrefix:@"Mei Lin, Mei’s key changed"], @"a name keeps its capital: %@",
              row[@"accessibility_label"]);

    // Without drop.files the rows refuse drops.
    SZFriendsAudience *noDrops = SZPAudience();
    noDrops.capabilities = [NSSet set];
    NSDictionary *plain = [SZPBuilder(noDrops) listWithPeople:@[ mei ] previewItems:@{} profile:SZPProfileRaph()
                                                        query:@"" now:Now()];
    SZPExpect(plain[@"rows"][0][@"drop_label"] == [NSNull null], @"no drop label without drop.files");
}

static void TestListBanners(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    SZFriendsProfileFacts *profile = SZPProfileIDChanged();
    profile.identityState = SZFriendsIdentityFactsStateUnavailable;
    NSDictionary *list = [builder listWithPeople:@[] previewItems:@{} profile:profile query:@"" now:Now()];
    SZPExpect([list[@"banner"][@"kind"] isEqual:@"identity_unavailable"] &&
                  [list[@"banner"][@"action"][@"action"] isEqual:@"reset_friends"] &&
                  [list[@"banner"][@"action"][@"confirm"][@"confirm_label"] isEqual:@"Reset Friends"] &&
                  list[@"footer"][@"id_note"] == [NSNull null],
              @"identity banner first, with a confirmed reset: %@", list[@"banner"]);
    SZPValidateSnapshot(list, @"list", @"identity banner");
    profile.identityState = SZFriendsIdentityFactsStateReady;
    for (NSNumber *need in @[ @(SZFriendsUpdateNeedOnline), @(SZFriendsUpdateNeedStore) ]) {
        profile.updateNeed = need.integerValue;
        list = [builder listWithPeople:@[] previewItems:@{} profile:profile query:@"" now:Now()];
        SZPExpect([list[@"banner"][@"kind"] isEqual:@"update_required"] &&
                      [list[@"banner"][@"text"] containsString:@"ShenzhenPDF"],
                  @"update banner names the app: %@", list[@"banner"]);
        SZPValidateSnapshot(list, @"list", @"update banner");
    }
}

static NSDictionary *Conversation(SZFriendsPersonFacts *person, NSArray *items, NSString *highlight,
                                  SZFriendsAudience *audience) {
    NSDictionary *data = [SZPBuilder(audience ?: SZPAudience()) conversationForPerson:person items:items hasEarlier:NO
                                                                     highlightItemID:highlight waitingElsewhere:0
                                                                                 now:Now()];
    SZPValidateSnapshot(data, @"conversation", person.conversationID);
    return data;
}

static NSArray *ActionNames(NSDictionary *item) {
    return [item[@"actions"] valueForKey:@"action"];
}

static void TestTransfers(void) {
    SZFriendsPersonFacts *mei = Friend(@"c_mei3", @"Mei Lin");
    for (NSInteger state = SZFriendsTransferStateQueued; state <= SZFriendsTransferStateFailed; state++) {
        for (NSNumber *outgoing in @[ @NO, @YES ]) {
            SZFriendsItemFacts *item = SZPTransfer(@"t_x", outgoing.boolValue, @"2026-10-12 09:00", @"Plan.pdf",
                                                   5000000, state);
            item.bytesDone = 2000000;
            item.bytesPerSecond = 100000;
            item.transferRoute = SZFriendsRouteMethodBluetooth;
            item.localPath = @"/tmp/received/Plan.pdf";
            NSDictionary *built = [Conversation(mei, @[ item ], nil, nil)[@"items"] lastObject];
            NSString *spoken = built[@"accessibility_label"];
            SZPExpect(spoken.length > 0 && ![spoken containsString:@"{"],
                      @"state %ld spoken: %@", (long)state, built[@"accessibility_label"]);
            SZPExpect(![built[@"status_label"] containsString:@"{"], @"state %ld status: %@", (long)state,
                      built[@"status_label"]);
        }
    }
    SZFriendsItemFacts *offer = SZPTransfer(@"t_o", NO, @"2026-10-12 09:00", @"Plan.pdf", 5000000,
                                            SZFriendsTransferStateWaitingForYou);
    SZPExpect([ActionNames([Conversation(mei, @[ offer ], nil, nil)[@"items"] lastObject])
                  isEqual:(@[ @"accept_offer", @"decline_offer" ])],
              @"offer actions");
    offer.askedBecauseDiskLow = YES;
    NSString *status = [Conversation(mei, @[ offer ], nil, nil)[@"items"] lastObject][@"status_label"];
    SZPExpect([status hasPrefix:@"Waiting for you. "],
              @"disk-low offer says why it asks");
    SZFriendsItemFacts *received = SZPTransfer(@"t_r", NO, @"2026-10-12 09:00", @"Plan.pdf", 5000000,
                                               SZFriendsTransferStateReceived);
    received.localPath = @"/tmp/received/Plan.pdf";
    NSDictionary *item = [Conversation(mei, @[ received ], nil, nil)[@"items"] lastObject];
    SZPExpect([ActionNames(item) isEqual:(@[ @"open_file", @"show_file" ])] &&
                  [item[@"actions"][1][@"label"] isEqual:@"Show in Finder"] &&
                  [item[@"file"][@"path"] isEqual:@"/tmp/received/Plan.pdf"],
              @"received PDF opens in place and shows in Finder: %@", item[@"actions"]);
    received.fileName = @"Archive.zip";
    received.fileExtension = @"zip";
    item = [Conversation(mei, @[ received ], nil, nil)[@"items"] lastObject];
    SZPExpect([ActionNames(item) isEqual:(@[ @"show_file" ])],
              @"a format the app cannot open offers Show in Finder only");
    SZFriendsItemFacts *sending = SZPTransfer(@"t_s", YES, @"2026-10-12 09:00", @"Plan.pdf", 5000000,
                                              SZFriendsTransferStateSending);
    sending.bytesDone = 2000000;
    sending.bytesPerSecond = 25000;
    sending.transferRoute = SZFriendsRouteMethodBluetooth;
    item = [Conversation(mei, @[ sending ], nil, nil)[@"items"] lastObject];
    SZPExpect([item[@"progress"][@"fraction"] isEqual:@0.4] &&
                  [item[@"status_label"] isEqual:@"Sending · 40% · about 2 min left"] &&
                  [item[@"route_note"] isEqual:@"Over Bluetooth, about 2 min"] &&
                  [item[@"progress"][@"accessibility_label"] isEqual:@"Sending, 40 percent"],
              @"sending over Bluetooth: %@", item);
    SZFriendsItemFacts *failed = SZPTransfer(@"t_f", YES, @"2026-10-12 09:00", @"Plan.pdf", 1,
                                             SZFriendsTransferStateFailed);
    item = [Conversation(mei, @[ failed ], nil, nil)[@"items"] lastObject];
    SZPExpect([ActionNames(item) isEqual:(@[ @"retry_item" ])],
              @"failed outgoing file can be retried");
    SZFriendsItemFacts *relayed = SZPTransfer(@"t_y", YES, @"2026-10-12 09:00", @"Plan.pdf", 18000000,
                                              SZFriendsTransferStateOffered);
    relayed.bytesPerSecond = 100000;
    relayed.transferRoute = SZFriendsRouteMethodRelay;
    SZPExpect([[Conversation(mei, @[ relayed ], nil, nil)[@"items"] lastObject][@"route_note"]
                  isEqual:@"Through the Friends relay, about 3 min"],
              @"relay estimate");
}

static void TestMessagesAndDays(void) {
    SZFriendsPersonFacts *mei = Friend(@"c_mei4", @"Mei Lin");
    NSArray *messages = @[
        SZPMessage(@"m_1", YES, @"2026-10-08 09:00", @"see https://example.com/plan please",
                   SZFriendsOutboxStateFailed),
        SZPMessage(@"m_2", YES, @"2026-10-11 09:00", @"two", SZFriendsOutboxStateConnecting),
        SZPMessage(@"m_3", YES, @"2026-10-12 09:00", @"three", SZFriendsOutboxStateSending),
        SZPEvent(@"e_new", @"2026-10-12 09:30", @"a_kind_from_the_future"),
    ];
    NSDictionary *data = Conversation(mei, messages, @"m_2", nil);
    NSArray *items = data[@"items"];
    NSArray *kinds = [items valueForKey:@"kind"];
    SZPExpect([kinds isEqual:(@[ @"day", @"message", @"day", @"message", @"day", @"message" ])],
              @"one separator per day, unknown event skipped: %@", kinds);
    SZPExpect([items[0][@"label"] isEqual:@"Thursday"] && [items[2][@"label"] isEqual:@"Yesterday"] &&
                  [items[4][@"label"] isEqual:@"Today"],
              @"day labels");
    NSArray *segments = items[1][@"segments"];
    SZPExpect(segments.count == 3 && [segments[1][@"url"] isEqual:@"https://example.com/plan"] &&
                  [items[1][@"text"] isEqual:@"see https://example.com/plan please"],
              @"links become segments: %@", segments);
    SZPExpect([ActionNames(items[1]) isEqual:(@[ @"retry_item" ])] &&
                  [items[1][@"status"][@"label"] isEqual:@"Not delivered"] &&
                  [items[1][@"accessibility_label"] hasSuffix:@"please. Not delivered."],
              @"failed message: %@", items[1]);
    SZPExpect([items[3][@"status"][@"label"] isEqual:@"Connecting to Mei…"] &&
                  [items[3][@"highlighted"] isEqual:@YES] &&
                  [data[@"highlight_item_id"] isEqual:@"m_2"],
              @"connecting and highlighted");
    SZPExpect(Conversation(mei, messages, @"m_gone", nil)[@"highlight_item_id"] == [NSNull null],
              @"a highlight that is not in the window is not claimed");
}

static void TestRequestsAndComposer(void) {
    SZFriendsPersonFacts *olu = Friend(@"c_out2", @"Olu Out");
    olu.relation = SZFriendsPersonRelationOutgoingRequest;
    olu.requestAt = SZPHongKong(@"2026-10-12 14:40");
    olu.routeKind = SZFriendsRouteKindNone;
    NSDictionary *card = Conversation(olu, @[], nil, nil)[@"request"];
    SZPExpect([card[@"direction"] isEqual:@"outgoing"] && [ActionNames(card) isEqual:(@[ @"cancel_request" ])] &&
                  card[@"comparison_code"] == [NSNull null] &&
                  [card[@"subtitle"] isEqual:@"Sent today at 14:40 · ID c_out2\u2011id"] &&
                  [card[@"code_prompt"] isEqual:@"A code to compare appears when you’re both online or nearby."],
              @"outgoing request card: %@", card);
    SZFriendsPersonFacts *byID = Friend(@"c_in2", @"Ines In");
    byID.relation = SZFriendsPersonRelationIncomingRequest;
    byID.requestAt = SZPHongKong(@"2026-10-11 09:00");
    card = Conversation(byID, @[], nil, nil)[@"request"];
    SZPExpect([card[@"subtitle"] hasPrefix:@"Sent to your ID · yesterday at 09:00"], @"request by ID: %@",
              card[@"subtitle"]);

    SZFriendsPersonFacts *blocked = Friend(@"c_bl", @"Bo Block");
    blocked.relation = SZFriendsPersonRelationBlocked;
    NSDictionary *data = Conversation(blocked, @[], nil, nil);
    SZPExpect([data[@"composer"][@"enabled"] isEqual:@NO] && [data[@"header"][@"subtitle"] isEqual:@"Blocked"] &&
                  [data[@"composer"][@"accepts_drops"] isEqual:@NO],
              @"blocked conversation");
    // Verify, wave 6e: the line says "Blocked", so no route icon or "Nearby" tooltip stands before it, even with a
    // session still up; and a screen reader hears the line too.
    SZPExpect([data[@"header"][@"route"][@"kind"] isEqual:@"none"] && data[@"header"][@"route"][@"label"] ==
                  [NSNull null] && [data[@"header"][@"accessibility_label"] isEqual:@"Bo Block, blocked, show details"],
              @"a blocked friend's header carries no route: %@", data[@"header"]);
    SZFriendsPersonFacts *near = Friend(@"c_bt", @"Mei Lin");
    near.routeMethod = SZFriendsRouteMethodBluetooth;
    NSDictionary *header = Conversation(near, @[], nil, nil)[@"header"];
    SZPExpect([header[@"route"][@"method"] isEqual:@"bluetooth"] &&
                  [header[@"accessibility_label"] isEqual:@"Mei Lin, nearby, over Bluetooth, show details"],
              @"the header's accessible name says the route: %@", header);
    near.routeKind = SZFriendsRouteKindNone;
    header = Conversation(near, @[], nil, nil)[@"header"];
    SZPExpect([header[@"accessibility_label"] isEqual:@"Mei Lin, show details"], @"no route, nothing to say: %@",
              header);
    SZFriendsPersonFacts *changed = Friend(@"c_kc", @"Kim Key");
    changed.keyChangePending = YES;
    SZPExpect([Conversation(changed, @[], nil, nil)[@"composer"][@"note"] containsString:@"key changed"],
              @"key change disables the composer with a reason");

    SZFriendsAudience *assistant = SZPAudience();
    assistant.capabilities = [NSSet setWithArray:@[ @"attach.items", @"assistant.drafts", @"drop.files" ]];
    NSArray *hint = Conversation(Friend(@"c_h", @"Hana"), @[], nil, assistant)[@"composer"][@"hint"];
    NSArray *expected = @[
        @{@"text" : @"Type "}, @{@"text" : @"#", @"emphasis" : @YES}, @{@"text" : @" to attach, "},
        @{@"text" : @"/", @"emphasis" : @YES}, @{@"text" : @" to ask the assistant, or drop files here"}
    ];
    SZPExpect([hint isEqual:expected], @"hint with the assistant: %@", hint);
    assistant.capabilities = [NSSet setWithArray:@[ @"attach.items", @"mentions" ]];
    hint = Conversation(Friend(@"c_h", @"Hana"), @[], nil, assistant)[@"composer"][@"hint"];
    expected = @[
        @{@"text" : @"Type "}, @{@"text" : @"#", @"emphasis" : @YES}, @{@"text" : @" to attach or "},
        @{@"text" : @"@", @"emphasis" : @YES}, @{@"text" : @" to mention someone"}
    ];
    SZPExpect([hint isEqual:expected], @"two keys, no dropping: %@", hint);
    assistant.capabilities = [NSSet setWithObject:@"drop.files"];
    hint = Conversation(Friend(@"c_h", @"Hana"), @[], nil, assistant)[@"composer"][@"hint"];
    SZPExpect([hint isEqual:(@[ @{@"text" : @"Drop files here to send them"} ])], @"drop-only hint: %@", hint);
    assistant.capabilities = [NSSet set];
    SZPExpect([Conversation(Friend(@"c_h", @"Hana"), @[], nil, assistant)[@"composer"][@"hint"] count] == 0,
              @"no hint without capabilities");
}

// Only an incoming request is answered from the list (brief § Interface); every other row, waiting or not, carries
// no buttons of its own. The buttons are icons, so their labels name the person for the tooltip and VoiceOver.
static void TestRowActions(void) {
    SZFriendsPersonFacts *request = Friend(@"c_req", nil);
    request.friendsID = @"tulip-canyon"; // unnamed: the ID is the title
    request.relation = SZFriendsPersonRelationIncomingRequest;
    SZFriendsPersonFacts *offers = Friend(@"c_offers", @"Ola Offers");
    offers.offersWaiting = 1;
    SZFriendsPersonFacts *keyChange = Friend(@"c_key", @"Kim Key");
    keyChange.keyChangePending = YES;
    SZFriendsPersonFacts *outgoing = Friend(@"c_out", @"Olu Out");
    outgoing.relation = SZFriendsPersonRelationOutgoingRequest;
    SZFriendsPersonFacts *blocked = Friend(@"c_blocked", @"Bo Block");
    blocked.relation = SZFriendsPersonRelationBlocked;
    SZFriendsPersonFacts *removed = Friend(@"c_removed", @"Rae Removed");
    removed.relation = SZFriendsPersonRelationRemoved;
    NSArray *people = @[ request, offers, keyChange, outgoing, blocked, removed, Friend(@"c_friend", @"Fay") ];
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    for (NSDictionary *row in List(people, nil, @"")[@"rows"]) byID[row[@"conversation_id"]] = row;
    NSArray *actions = byID[@"c_req"][@"actions"];
    NSArray *expected = @[
        @{@"action" : @"accept_request", @"icon" : @"accept", @"title" : @"Accept",
          @"label" : @"Accept tulip\u2011canyon’s request", @"arm" : [NSNull null]},
        @{@"action" : @"decline_request", @"icon" : @"decline", @"title" : @"Decline",
          @"label" : @"Decline tulip\u2011canyon’s request", @"arm" : [NSNull null]},
        @{@"action" : @"block", @"icon" : @"block", @"title" : [NSNull null], @"label" : @"Block tulip\u2011canyon",
          @"arm" : @{@"label" : @"Block?", @"accessibility_label" : @"Click again to block tulip\u2011canyon",
                     @"seconds" : @4}},
    ];
    SZPExpect([actions isEqual:expected], @"request row answers from the list: %@", actions);
    SZPExpect([byID[@"c_req"][@"waiting"][@"kind"] isEqual:@"request"], @"and still counts as waiting");
    for (NSString *conversationID in @[ @"c_offers", @"c_key", @"c_out", @"c_blocked", @"c_removed", @"c_friend" ])
        SZPExpect([byID[conversationID][@"actions"] isEqual:@[]], @"%@ carries no row actions: %@", conversationID,
                  byID[conversationID][@"actions"]);
}

void SZPRunViewEdgeTests(void) {
    TestBadge();
    TestListRows();
    TestRowActions();
    TestListBanners();
    TestTransfers();
    TestMessagesAndDays();
    TestRequestsAndComposer();
    SZPRunPeopleEdgeTests();
}
