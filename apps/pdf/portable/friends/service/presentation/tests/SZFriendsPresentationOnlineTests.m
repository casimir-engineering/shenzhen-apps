// Online friends as the reader sees them (PROTOCOL.md § Shared objects, Route; helper capability `online`): the
// fixtures online-list.json, online-conversation-kenji-relay.json, online-conversation-priya-connecting.json and
// online-conversation-priya-unreachable.json rebuilt from their facts, then each state on its own. A session over the
// Internet says Online, direct or through the relay; an attempt in progress says Connecting; one that failed says Not
// reachable and that everything waits; the relay's estimates assume its cap. A helper that does not announce `online`
// (M1) says none of it, whatever the facts hold. The fixtures are named online-*, not conversation-*, because the
// fake helper indexes every conversation-*.json by its conversation id as the mockup state of that person.

#import "SZFriendsPresentationWorld.h"

#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsTransfers.h"

static SZFriendsAudience *OnlineAudience(void) {
    SZFriendsAudience *audience = SZPAudience();
    audience.helperCapabilities = [NSSet setWithArray:@[ @"nearby.network", @"host.checkin", @"online" ]];
    return audience;
}

// The list's people with online routes: Mei direct, Daniel through the relay, Priya while an attempt runs, Kenji
// still over Bluetooth with his offer, the others as in list.json.
static NSDictionary<NSString *, SZFriendsPersonFacts *> *OnlinePeople(void) {
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    people[@"c_mei"].routeMethod = SZFriendsRouteMethodInternet;      // kind Local, as the nearby service reports it
    people[@"c_daniel"].routeKind = SZFriendsRouteKindOnline;
    people[@"c_daniel"].routeMethod = SZFriendsRouteMethodRelay;
    people[@"c_priya"].onlineReach = SZFriendsOnlineReachConnecting;
    return people;
}

static SZFriendsPersonFacts *Priya(SZFriendsOnlineReach reach) {
    SZFriendsPersonFacts *priya = SZPPeople()[@"c_priya"];
    priya.onlineReach = reach;
    return priya;
}

static NSDictionary *Conversation(SZFriendsAudience *audience, SZFriendsPersonFacts *person, NSArray *items,
                                  NSString *label) {
    NSDictionary *built = [SZPBuilder(audience) conversationForPerson:person items:items hasEarlier:NO
                                                      highlightItemID:nil waitingElsewhere:2 now:SZPNow()];
    SZPValidateSnapshot(built, @"conversation", label);
    return built;
}

static NSDictionary *Item(NSDictionary *conversation, NSString *itemID) {
    for (NSDictionary *item in conversation[@"items"])
        if ([item[@"item_id"] isEqual:itemID]) return item;
    SZPFail(@"no item %@", itemID);
    return @{};
}

static void TestFixtures(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(OnlineAudience());
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = OnlinePeople();
    SZPExpectFixture([builder listWithPeople:people.allValues previewItems:SZPPreviewItems() profile:SZPProfileRaph()
                                       query:@""
                                         now:SZPNow()],
                     @"online-list.json", @"list");

    SZFriendsPersonFacts *kenji = SZPPeople()[@"c_kenji"];
    kenji.routeKind = SZFriendsRouteKindOnline;
    kenji.routeMethod = SZFriendsRouteMethodRelay;
    NSArray<SZFriendsItemFacts *> *items = SZPItemsFor(@"c_kenji");
    // Offered over the relay before any rate was measured: the estimate assumes what the relay allows.
    items.lastObject.transferRoute = SZFriendsRouteMethodRelay;
    items.lastObject.bytesPerSecond = 0;
    SZPExpectFixture([builder conversationForPerson:kenji items:items hasEarlier:YES highlightItemID:nil
                                   waitingElsewhere:1
                                                now:SZPNow()],
                     @"online-conversation-kenji-relay.json", @"conversation");

    SZPExpectFixture([builder conversationForPerson:Priya(SZFriendsOnlineReachUnreachable) items:SZPItemsFor(@"c_priya")
                                        hasEarlier:NO
                                   highlightItemID:nil
                                  waitingElsewhere:2
                                               now:SZPNow()],
                     @"online-conversation-priya-unreachable.json", @"conversation");
    SZPExpectFixture([builder conversationForPerson:Priya(SZFriendsOnlineReachConnecting) items:SZPItemsFor(@"c_priya")
                                        hasEarlier:NO
                                   highlightItemID:nil
                                  waitingElsewhere:2
                                               now:SZPNow()],
                     @"online-conversation-priya-connecting.json", @"conversation");
}

// The facts may say Online or Connecting; an M1 helper's words still never do.
static void TestNothingOnlineWithoutCapability(void) {
    SZFriendsAudience *m1 = SZPAudience();
    NSDictionary *conversation = Conversation(m1, Priya(SZFriendsOnlineReachConnecting), SZPItemsFor(@"c_priya"),
                                              @"m1 connecting");
    SZPExpect([conversation[@"header"][@"route"] isEqual:(@{@"kind" : @"offline", @"method" : NSNull.null,
                                                           @"label" : @"Not nearby right now"})],
              @"M1: no Connecting: %@", conversation[@"header"][@"route"]);
    SZPExpect([conversation[@"composer"][@"note"]
                  isEqual:@"Messages and files send when Priya is nearby with ShenzhenPDF, Shenzhen Files or "
                          @"Shenzhen 3D open."],
              @"M1 note: %@", conversation[@"composer"][@"note"]);
    SZPExpect([Item(conversation, @"m_c4d27a19")[@"status"][@"label"] isEqual:@"Sends when Priya is nearby"],
              @"M1 status: %@", Item(conversation, @"m_c4d27a19")[@"status"]);
    conversation = Conversation(m1, Priya(SZFriendsOnlineReachUnreachable), @[], @"m1 unreachable");
    SZPExpect([conversation[@"header"][@"subtitle"] isEqual:@"Not nearby right now"], @"M1: no Not reachable");
    NSString *note = [[SZFriendsStrings alloc] initWithAudience:m1].staticStrings[@"queued_note"];
    SZPExpect([note isEqualToString:@"Messages and files send when {first} is nearby with ShenzhenPDF, Shenzhen "
                                    @"Files or Shenzhen 3D open."],
              @"M1 welcome queued_note: %@", note);
}

static void TestOnlineRoutes(void) {
    SZFriendsAudience *online = OnlineAudience();
    SZFriendsPersonFacts *mei = SZPPeople()[@"c_mei"];
    mei.routeMethod = SZFriendsRouteMethodInternet; // kind Local: the live route of an online session
    NSDictionary *conversation = Conversation(online, mei, @[], @"mei direct");
    SZPExpect([conversation[@"header"][@"route"] isEqual:(@{@"kind" : @"online", @"method" : @"internet",
                                                           @"label" : @"Online, direct"})],
              @"direct: %@", conversation[@"header"][@"route"]);
    SZPExpect([conversation[@"header"][@"accessibility_label"] isEqual:@"Mei Lin, online, direct, show details"],
              @"direct, spoken: %@", conversation[@"header"][@"accessibility_label"]);
    NSDictionary *details = [SZPBuilder(online) detailsForPerson:mei waitingElsewhere:0 now:SZPNow()];
    SZPValidateSnapshot(details, @"details", @"details direct");
    SZPExpect([details[@"route"][@"kind"] isEqual:@"online"], @"details: %@", details[@"route"]);
    // Even an M1 build's words would not call an Internet session nearby.
    SZPExpect([Conversation(SZPAudience(), mei, @[], @"m1 internet")[@"header"][@"subtitle"]
                  isEqual:@"Online, direct"],
              @"an Internet session is never Nearby");

    mei.routeMethod = SZFriendsRouteMethodRelay;
    conversation = Conversation(online, mei, @[], @"mei relay");
    SZPExpect([conversation[@"header"][@"route"] isEqual:(@{@"kind" : @"online", @"method" : @"relay",
                                                           @"label" : @"Online, through the Friends relay"})],
              @"relay: %@", conversation[@"header"][@"route"]);
    SZPExpect([conversation[@"composer"][@"note"] isEqual:NSNull.null], @"no note while online");
}

static void TestConnecting(void) {
    NSDictionary *conversation = Conversation(OnlineAudience(), Priya(SZFriendsOnlineReachConnecting),
                                              SZPItemsFor(@"c_priya"), @"priya connecting");
    NSDictionary *header = conversation[@"header"];
    SZPExpect([header[@"route"] isEqual:(@{@"kind" : @"connecting", @"method" : NSNull.null,
                                          @"label" : @"Connecting to Priya…"})] &&
                  [header[@"subtitle"] isEqual:@"Connecting to Priya…"] &&
                  [header[@"accessibility_label"] isEqual:@"Priya Raman, connecting to Priya, show details"],
              @"connecting header: %@", header);
    SZPExpect([conversation[@"composer"][@"note"] isEqual:NSNull.null], @"no waiting note while connecting");
    NSDictionary *message = Item(conversation, @"m_c4d27a19");
    SZPExpect([message[@"status"] isEqual:(@{@"state" : @"connecting", @"label" : @"Connecting to Priya…"})],
              @"queued message while connecting: %@", message[@"status"]);
    SZPExpect([[message[@"actions"] valueForKey:@"action"] isEqual:@[ @"cancel_message" ]], @"still cancellable");
    SZPExpect([message[@"accessibility_label"]
                  isEqual:@"You, 17:58, connecting to Priya: I've marked the new delivery dates on page 4."],
              @"connecting, spoken: %@", message[@"accessibility_label"]);
    NSDictionary *file = Item(conversation, @"t_6a2f90b8");
    SZPExpect([file[@"status_label"] isEqual:@"Connecting to Priya…"] &&
                  [file[@"accessibility_label"] isEqual:@"You are sending Supplier contract v3.pdf, PDF, 2.4 MB. "
                                                        @"Connecting to Priya."],
              @"queued file while connecting: %@", file);

    SZFriendsItemFacts *queued = SZPItemsFor(@"c_priya")[3];
    queued.conversationID = @"c_priya";
    NSDictionary *statuses = [SZPBuilder(OnlineAudience())
        messageStatusWithMessages:@[ queued ]
                           people:@{@"c_priya" : Priya(SZFriendsOnlineReachConnecting)}];
    SZPValidateSnapshot(statuses, @"message_status", @"message_status connecting");
    SZPExpect([statuses[@"messages"][0][@"status"][@"state"] isEqual:@"connecting"], @"message_status: %@", statuses);

    // Only friends are reached online, and a session that is up says how, whatever an attempt does beside it.
    SZFriendsPersonFacts *removed = Priya(SZFriendsOnlineReachConnecting);
    removed.relation = SZFriendsPersonRelationRemoved;
    SZFriendsPersonFacts *keyChange = Priya(SZFriendsOnlineReachConnecting);
    keyChange.keyChangePending = YES;
    SZFriendsPersonFacts *bluetooth = Priya(SZFriendsOnlineReachConnecting);
    bluetooth.routeKind = SZFriendsRouteKindLocal;
    bluetooth.routeMethod = SZFriendsRouteMethodBluetooth;
    NSArray *expected = @[ @"offline", @"offline", @"local" ];
    NSArray *people = @[ removed, keyChange, bluetooth ];
    for (NSUInteger i = 0; i < people.count; i++) {
        NSDictionary *conversation = Conversation(OnlineAudience(), people[i], @[], @"not connecting");
        NSString *kind = conversation[@"header"][@"route"][@"kind"];
        SZPExpect([kind isEqual:expected[i]], @"case %lu shows %@, not %@", (unsigned long)i, kind, expected[i]);
    }
}

static void TestUnreachableAndOffline(void) {
    NSDictionary *conversation = Conversation(OnlineAudience(), Priya(SZFriendsOnlineReachUnreachable),
                                              SZPItemsFor(@"c_priya"), @"priya unreachable");
    SZPExpect([conversation[@"header"][@"route"] isEqual:(@{@"kind" : @"offline", @"method" : NSNull.null,
                                                           @"label" : @"Couldn’t connect just now"})],
              @"unreachable: %@", conversation[@"header"][@"route"]);
    SZPExpect([conversation[@"composer"][@"note"]
                  isEqual:@"Couldn’t connect to Priya just now. Friends keeps trying, and sends what’s waiting as soon "
                          @"as it can."],
              @"unreachable note: %@", conversation[@"composer"][@"note"]);
    SZPExpect([Item(conversation, @"m_c4d27a19")[@"status"]
                  isEqual:(@{@"state" : @"queued", @"label" : @"Sends when Priya is online or nearby"})],
              @"queued online: %@", Item(conversation, @"m_c4d27a19")[@"status"]);
    SZPExpect([Item(conversation, @"t_6a2f90b8")[@"status_label"] isEqual:@"Sends when Priya is online or nearby"],
              @"queued file online");

    conversation = Conversation(OnlineAudience(), Priya(SZFriendsOnlineReachUnknown), @[], @"priya offline");
    SZPExpect([conversation[@"header"][@"subtitle"] isEqual:@"Not connected right now"] &&
                  [conversation[@"composer"][@"note"] isEqual:@"Messages and files send when Priya is online or nearby "
                                                              @"with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open."],
              @"offline with online: %@", conversation);
    NSString *note = [[SZFriendsStrings alloc] initWithAudience:OnlineAudience()].staticStrings[@"queued_note"];
    SZPExpect([note isEqualToString:@"Messages and files send when {first} is online or nearby with ShenzhenPDF, "
                                    @"Shenzhen Files or Shenzhen 3D open."],
              @"welcome queued_note: %@", note);
}

static void TestRelayEstimates(void) {
    SZFriendsStrings *s = [[SZFriendsStrings alloc] initWithAudience:OnlineAudience()];
    // Not measured yet: 4 Mbit/s of payload, what the relay's 5 Mbit/s cap gives (90 MB in about 3 minutes).
    SZPExpect([[s transferEstimateForRemainingBytes:90000000 bytesPerSecond:0 route:SZFriendsRouteMethodRelay]
                  isEqualToString:@"Through the Friends relay, about 3 min"],
              @"unmeasured relay estimate");
    // A burst above the cap is not what the rest of the file gets: 18 MB at 625,000 B/s, not 2,000,000.
    SZPExpect([[s transferEstimateForRemainingBytes:18000000 bytesPerSecond:2000000 route:SZFriendsRouteMethodRelay]
                  isEqualToString:@"Through the Friends relay, about 30 s"],
              @"capped relay estimate");
    SZPExpect([[s transferEstimateForRemainingBytes:18000000 bytesPerSecond:0 route:SZFriendsRouteMethodBluetooth]
                  isEqualToString:@"Over Bluetooth"],
              @"Bluetooth unmeasured still promises no time");
    SZFriendsItemFacts *receiving = SZPTransfer(@"t_r", NO, @"2026-10-12 09:00", @"Plan.pdf", 18000000,
                                                SZFriendsTransferStateReceiving);
    receiving.bytesPerSecond = 2000000;
    receiving.transferRoute = SZFriendsRouteMethodRelay;
    NSDictionary *item = Item(Conversation(OnlineAudience(), SZPPeople()[@"c_mei"], @[ receiving ], @"relay timed"),
                              @"t_r");
    SZPExpect([item[@"status_label"] isEqual:@"Receiving · 0% · about 30 s left"], @"relay time left: %@", item);
}

// PROTOCOL.md § Fast transfers: every block arrived, the whole file's check runs for more than a second.
static void TestAFileBeingCheckedSaysFinishing(void) {
    SZFriendsItemFacts *finishing = SZPTransfer(@"t_f", NO, @"2026-10-12 09:00", @"Scan.step", 8000000000,
                                                SZFriendsTransferStateReceiving);
    finishing.bytesDone = 8000000000;
    finishing.bytesPerSecond = 90000000;
    finishing.finishing = YES;
    NSDictionary *row = Item(Conversation(OnlineAudience(), SZPPeople()[@"c_mei"], @[ finishing ], @"finishing"),
                             @"t_f");
    SZPExpect([row[@"state"] isEqual:@"receiving"] && [row[@"status_label"] isEqual:@"Finishing…"],
              @"the row says Finishing…: %@", row);
    SZPExpect([row[@"progress"][@"fraction"] doubleValue] == 1.0 &&
                  [row[@"progress"][@"accessibility_label"] isEqual:@"Finishing"],
              @"a full bar: %@", row[@"progress"]);
    SZPExpect([row[@"accessibility_label"] hasSuffix:@", finishing"], @"spoken: %@", row[@"accessibility_label"]);
}

// ADR 0019: the Wi-Fi Direct boost's question, only for views that declared transfers.boost, and the words after.
static void TestTheBoostAsksOnlyWhereTheViewKnowsIt(void) {
    SZFriendsItemFacts *sending = SZPTransfer(@"t_b", YES, @"2026-10-12 09:00", @"Site survey.mp4", 100000000,
                                              SZFriendsTransferStateSending);
    sending.boostStage = 1;
    sending.boostNetwork = @"HomeWiFi";
    sending.boostLeavesWiFi = YES;
    sending.boostBluetoothSeconds = 700;
    sending.boostDirectSeconds = 28;
    SZFriendsAudience *audience = OnlineAudience();
    audience.capabilities = [audience.capabilities setByAddingObject:@"transfers.boost"];
    NSDictionary *row = Item(Conversation(audience, SZPPeople()[@"c_mei"], @[ sending ], @"boost"), @"t_b");
    NSString *note = row[@"route_note"];
    SZPExpect([note isEqual:@"Go faster? Mei isn’t on your Wi-Fi, so this is going over Bluetooth (about 12 min). "
                            @"Leave “HomeWiFi” for about 30 s to connect to Mei directly. Your computer rejoins it "
                            @"by itself when it’s done."],
              @"the question: %@", note);
    NSArray *names = [row[@"actions"] valueForKey:@"action"];
    NSArray *expected = @[ @"boost_transfer", @"skip_boost", @"cancel_transfer" ];
    SZPExpect([names isEqual:expected], @"Go faster, Not now: %@",
              row[@"actions"]);
    NSDictionary *old = Item(Conversation(OnlineAudience(), SZPPeople()[@"c_mei"], @[ sending ], @"no boost"), @"t_b");
    id oldNote = old[@"route_note"];
    SZPExpect(![[old[@"actions"] valueForKey:@"action"] containsObject:@"boost_transfer"] &&
                  !([oldNote isKindOfClass:[NSString class]] && [oldNote hasPrefix:@"Go faster"]),
              @"a view without transfers.boost is never asked: %@", old);
    sending.boostStage = 5;
    row = Item(Conversation(audience, SZPPeople()[@"c_mei"], @[ sending ], @"rejoin failed"), @"t_b");
    SZPExpect([row[@"route_note"] isEqual:@"Your computer didn’t get back on “HomeWiFi” by itself. Choose it in the "
                                          @"Wi-Fi menu."],
              @"the way back failed: %@", row[@"route_note"]);
}

void SZPRunOnlineTests(void) {
    TestFixtures();
    TestNothingOnlineWithoutCapability();
    TestOnlineRoutes();
    TestConnecting();
    TestUnreachableAndOffline();
    TestRelayEstimates();
    TestAFileBeingCheckedSaysFinishing();
    TestTheBoostAsksOnlyWhereTheViewKnowsIt();
}
