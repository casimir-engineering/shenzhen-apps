// One profile on several computers built from facts (SZFriendsPresentationDevices.h): every devices-* fixture is what
// the builder makes of the facts the mockups show, byte for byte as parsed JSON, and each built snapshot validates
// against PROTOCOL.md. Without devices facts every view stays the one-computer view.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/store/SZFriendsTransfers.h"

static SZFriendsDeviceFacts *Computer(NSString *deviceID, NSString *name, NSString *system, BOOL thisComputer,
                                      BOOL connected, NSString *_Nullable seen) {
    SZFriendsDeviceFacts *device = [[SZFriendsDeviceFacts alloc] init];
    device.deviceID = deviceID;
    device.name = name;
    device.system = system;
    device.thisComputer = thisComputer;
    device.connected = connected;
    device.lastSeenAt = seen ? SZPHongKong(seen) : nil;
    return device;
}

static SZFriendsDevicesFacts *FourComputers(void) {
    SZFriendsDevicesFacts *facts = [[SZFriendsDevicesFacts alloc] init];
    facts.now = SZPNow();
    facts.computers = @[
        Computer(@"d_1e9c4a70", @"Raph’s MacBook Pro", @"macOS 26.1", YES, YES, nil),
        Computer(@"d_5b07e2c9", @"Raph’s Mac mini", @"macOS 15.7", NO, YES, @"2026-10-12 14:47"),
        Computer(@"d_93f2d618", @"Studio workstation", @"Linux", NO, NO, @"2026-10-11 18:02"),
        Computer(@"d_c0a47b3e", @"Raph’s MacBook Air", @"macOS 26.1", NO, NO, nil),
    ];
    facts.friendsID = @"cottage-violet";
    return facts;
}

static SZFriendsPersonFacts *You(NSString *lastInteraction) {
    SZFriendsProfileFacts *profile = SZPProfileRaph();
    SZFriendsPersonFacts *you = [[SZFriendsPersonFacts alloc] init];
    you.conversationID = @"you";
    you.name = profile.name;
    you.friendsID = profile.friendsID;
    you.picture = profile.picture;
    you.relation = SZFriendsPersonRelationFriend;
    you.lastInteractionAt = SZPHongKong(lastInteraction);
    return you;
}

static void TestProfileAndRows(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    builder.devices = FourComputers();
    SZPExpectFixture([builder profileWithFacts:SZPProfileRaph() waitingElsewhere:2], @"devices-profile.json",
                     @"profile");
    // Within the hour: minutes; this computer cannot remove itself; a removed computer offers nothing.
    builder.devices.computers = @[ builder.devices.computers[0],
                                   Computer(@"d_2", @"Office iMac", @"macOS 26.1", NO, NO, @"2026-10-12 14:40") ];
    NSDictionary *rows = [builder devicesSectionWithFacts:builder.devices now:SZPNow()];
    NSDictionary *office = rows[@"rows"][1];
    SZPExpect([office[@"last_connected"] isEqual:@"7 min ago"] &&
                  [office[@"accessibility_label"] isEqual:@"Office iMac, macOS 26.1, last connected 7 minutes ago"],
              @"minutes: %@", office);
    builder.devices.removed = YES;
    rows = [builder devicesSectionWithFacts:builder.devices now:SZPNow()];
    SZPExpect(rows[@"rows"][1][@"remove"] == NSNull.null && rows[@"rows"][0][@"rename"] == NSNull.null &&
                  rows[@"add"] == NSNull.null,
              @"a removed computer removes, renames and adds nothing");
    builder.devices = nil;
    SZPExpect([builder profileWithFacts:SZPProfileRaph() waitingElsewhere:2][@"devices"] == nil,
              @"without the capability, no devices");
}

static void TestLists(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSArray<SZFriendsPersonFacts *> *everyone = SZPPeople().allValues;
    NSDate *now = SZPNow();
    SZFriendsDevicesFacts *facts = FourComputers();
    facts.you = You(@"2026-10-12 15:02");
    facts.youPreview = SZPTransfer(@"t_6a2e9f14", YES, @"2026-10-12 15:02", @"Bracket drawing rev C.pdf", 41203776,
                                   SZFriendsTransferStateSending);
    builder.devices = facts;
    NSArray<SZFriendsPersonFacts *> *meiOnly = @[ SZPPeople()[@"c_mei"] ];
    NSMutableDictionary *list = [[builder listWithPeople:meiOnly previewItems:SZPPreviewItems()
                                                 profile:SZPProfileRaph() query:@"" now:now] mutableCopy];
    list[@"join_requests"] = @[];
    SZPExpectFixture([builder listWithDevices:list people:meiOnly query:@"" now:now], @"devices-list.json", @"list");
    NSDictionary *filtered = [builder listWithDevices:[builder listWithPeople:everyone previewItems:SZPPreviewItems()
                                                                      profile:SZPProfileRaph() query:@"mei" now:now]
                                               people:everyone query:@"mei" now:now];
    SZPExpect(![[filtered[@"rows"] valueForKey:@"conversation_id"] containsObject:@"you"], @"You only matches You");

    // Removed: the rows stay to read, no drops, no join rows.
    SZFriendsPersonFacts *mei = SZPPeople()[@"c_mei"];
    mei.routeKind = SZFriendsRouteKindNone;
    mei.routeMethod = SZFriendsRouteMethodNone;
    facts.you = nil;
    facts.removed = YES;
    NSMutableDictionary *removed = [[builder listWithPeople:@[ mei ] previewItems:SZPPreviewItems()
                                                    profile:SZPProfileRaph() query:@"" now:now] mutableCopy];
    removed[@"join_requests"] = @[ @{@"join_id" : @"x"} ];
    SZPExpectFixture([builder listWithDevices:removed people:@[ mei ] query:@"" now:now], @"devices-list-removed.json",
                     @"list");

    // A new computer: no name yet, nobody in Friends, offered to join.
    SZFriendsDevicesFacts *fresh = [[SZFriendsDevicesFacts alloc] init];
    fresh.now = now;
    fresh.joinOffered = YES;
    builder.devices = fresh;
    SZFriendsProfileFacts *unnamed = SZPProfileRaph();
    unnamed.name = nil;
    NSMutableDictionary *empty = [[builder listWithPeople:@[] previewItems:@{} profile:unnamed query:@"" now:now]
        mutableCopy];
    empty[@"join_requests"] = @[];
    SZPExpectFixture([builder listWithDevices:empty people:@[] query:@"" now:now], @"devices-list-new-computer.json",
                     @"list");
    // Named, still nobody: the list keeps offering it.
    NSDictionary *named = [builder listWithDevices:[builder listWithPeople:@[] previewItems:@{}
                                                                  profile:SZPProfileRaph() query:@"" now:now]
                                            people:@[] query:@"" now:now];
    SZPExpect([named[@"join"][@"action"][@"action"] isEqual:@"open_join"], @"offered once named: %@", named[@"join"]);

    // Friends here already, no name yet: joining replaces them, so it asks first and opens the join view after.
    SZFriendsDevicesFacts *own = [[SZFriendsDevicesFacts alloc] init];
    own.now = now;
    own.joinReplaces = YES;
    own.friendsID = @"cottage-violet";
    own.computers = @[ Computer(@"d_1e9c4a70", @"Raph’s MacBook Pro", @"macOS 26.1", YES, YES, nil) ];
    builder.devices = own;
    NSMutableDictionary *withMei = [[builder listWithPeople:meiOnly previewItems:SZPPreviewItems() profile:unnamed
                                                      query:@"" now:now] mutableCopy];
    withMei[@"join_requests"] = @[];
    SZPExpectFixture([builder listWithDevices:withMei people:meiOnly query:@"" now:now],
                     @"devices-list-join-reset.json", @"list");
    // Named: only Settings offers it then, so friends' rows are not crowded by it.
    named = [builder listWithDevices:[builder listWithPeople:meiOnly previewItems:SZPPreviewItems()
                                                     profile:SZPProfileRaph() query:@"" now:now]
                              people:meiOnly query:@"" now:now];
    SZPExpect(named[@"join"] == NSNull.null, @"not on a named list with friends: %@", named[@"join"]);
    own.removed = YES;
    SZPExpect([builder listWithDevices:withMei people:meiOnly query:@"" now:now][@"join"] == NSNull.null,
              @"a removed computer starts over first");
}

static void TestConversations(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDate *now = SZPNow();
    SZFriendsDevicesFacts *facts = FourComputers();
    facts.you = You(@"2026-10-12 15:02");
    SZFriendsItemFacts *message = SZPMessage(@"m_0c7d31e8", YES, @"2026-10-12 14:58", @"Pages to check: 3–5 and 9.",
                                             -1);
    SZFriendsItemFacts *file = SZPTransfer(@"t_6a2e9f14", YES, @"2026-10-12 15:02", @"Bracket drawing rev C.pdf",
                                           41203776, SZFriendsTransferStateQueued);
    facts.youItemsEverywhere = [NSSet setWithObject:@"m_0c7d31e8"];
    facts.youCopying = @{@"t_6a2e9f14" : @0.4};
    builder.devices = facts;
    SZPExpectFixture([builder conversationForPerson:facts.you items:@[ message, file ] hasEarlier:NO
                                    highlightItemID:nil waitingElsewhere:2 now:now],
                     @"devices-conversation-you.json", @"conversation");
    // Once everything is everywhere, the composer says nothing more.
    facts.youCopying = @{};
    facts.youItemsEverywhere = [NSSet setWithObjects:@"m_0c7d31e8", @"t_6a2e9f14", nil];
    NSDictionary *done = [builder conversationForPerson:facts.you items:@[ message, file ] hasEarlier:NO
                                        highlightItemID:nil waitingElsewhere:2 now:now];
    SZPExpect(done[@"composer"][@"note"] == NSNull.null, @"no note once on every computer");
    SZPExpect([[done[@"items"] lastObject][@"status_label"] isEqual:@"On all your computers"], @"%@", done[@"items"]);

    // Files on another computer.
    NSArray *items = @[
        SZPTransfer(@"t_c81f04d2", NO, @"2026-10-12 10:05", @"Factory audit photos.pdf", 312475648,
                    SZFriendsTransferStateReceived),
        SZPTransfer(@"t_4d9b7a35", NO, @"2026-10-12 10:07", @"Line 2 layout.pdf", 58402113,
                    SZFriendsTransferStateReceived),
        SZPTransfer(@"t_e27c6b90", NO, @"2026-10-12 10:12", @"Supplier quote.pdf", 96110592,
                    SZFriendsTransferStateReceived),
    ];
    SZFriendsDeviceFileFacts *onMini = [[SZFriendsDeviceFileFacts alloc] init];
    onMini.deviceName = @"Raph’s Mac mini";
    SZFriendsDeviceFileFacts *copying = [[SZFriendsDeviceFileFacts alloc] init];
    copying.deviceName = @"Raph’s Mac mini";
    copying.fetching = YES;
    copying.holderConnected = YES;
    copying.fraction = 0.25;
    SZFriendsDeviceFileFacts *away = [[SZFriendsDeviceFileFacts alloc] init];
    away.deviceName = @"Studio workstation";
    away.fetching = YES;
    facts.files = @{@"t_c81f04d2" : onMini, @"t_4d9b7a35" : copying, @"t_e27c6b90" : away};
    SZPExpectFixture([builder conversationForPerson:SZPPeople()[@"c_mei"] items:items hasEarlier:NO
                                    highlightItemID:nil waitingElsewhere:2 now:now],
                     @"devices-conversation-mei-files.json", @"conversation");
}

static void TestHistoryWords(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    builder.devices = FourComputers();
    SZPExpectFixture([builder settingsWithProfile:SZPProfileRaph() people:people.allValues], @"devices-settings.json",
                     @"settings");
    SZPExpectFixture([builder detailsForPerson:people[@"c_mei"] waitingElsewhere:2 now:SZPNow()],
                     @"devices-details-mei.json", @"details");
    SZPExpect([builder settingsWithProfile:SZPProfileRaph() people:people.allValues][@"join"] == nil,
              @"a profile on several computers offers no other one");
    // One computer: the words of one computer.
    builder.devices.computers = @[ builder.devices.computers[0] ];
    SZPExpectFixture([builder settingsWithProfile:SZPProfileRaph() people:people.allValues], @"settings.json",
                     @"settings");
    // One computer with friends: Settings offers the person's existing profile, after Reset.
    builder.devices.joinReplaces = YES;
    SZPExpectFixture([builder settingsWithProfile:SZPProfileRaph() people:people.allValues],
                     @"devices-settings-join.json", @"settings");
    SZFriendsAudience *chats = SZPAudience();
    chats.capabilities = [chats.capabilities setByAddingObject:@"assistant.chats"];
    SZFriendsSnapshotBuilder *assistant = SZPBuilder(chats);
    assistant.devices = builder.devices;
    NSString *body = [assistant settingsWithProfile:SZPProfileRaph() people:people.allValues][@"join"][@"action"]
        [@"confirm"][@"body"];
    SZPExpect([body containsString:@"AI chat answers"], @"the AI chat's answers stay: %@", body);
}

static SZFriendsItemFacts *Moved(NSString *transferID, BOOL outgoing, NSString *time, NSString *name, uint64_t size,
                                 SZFriendsAgainState again) {
    SZFriendsItemFacts *item = SZPTransfer(transferID, outgoing, time, name, size,
                                           outgoing ? SZFriendsTransferStateDelivered : SZFriendsTransferStateReceived);
    item.fileMissing = YES;
    item.again = again;
    return item;
}

// Files the person moved or deleted (PROTOCOL.md § Getting a file again): Get again from Mei, copying from her,
// waiting for her, her answer that she no longer has one, one still on another computer (Get), and one this person
// sent from another computer, which only says where it went.
static void TestFilesAgain(void) {
    SZFriendsAudience *audience = SZPAudience();
    audience.capabilities = [audience.capabilities setByAddingObject:@"files.again"];
    SZFriendsSnapshotBuilder *builder = SZPBuilder(audience);
    builder.devices = FourComputers();
    SZFriendsItemFacts *copying = Moved(@"t_7b3e0f42", NO, @"2026-10-12 09:20", @"Shift rota.pdf", 1203456,
                                        SZFriendsAgainAsked);
    copying.againConnected = YES;
    copying.againFraction = 0.4;
    NSArray *items = @[
        Moved(@"t_5a90c3e1", NO, @"2026-10-12 09:12", @"Site photos.pdf", 48231004, SZFriendsAgainNone), copying,
        Moved(@"t_91c6d2a8", NO, @"2026-10-12 09:31", @"Supplier quote.pdf", 3604480, SZFriendsAgainAsked),
        Moved(@"t_2f8a4c17", NO, @"2026-10-12 09:44", @"Old floor plan.pdf", 5100000, SZFriendsAgainGone),
        Moved(@"t_c4e19b05", NO, @"2026-10-12 09:50", @"Audit checklist.pdf", 860160, SZFriendsAgainNone),
        Moved(@"t_e83d5a6c", YES, @"2026-10-12 10:02", @"Quote reply.pdf", 2200000, SZFriendsAgainNone),
    ];
    SZFriendsDeviceFileFacts *onMini = [[SZFriendsDeviceFileFacts alloc] init];
    onMini.deviceName = @"Raph’s Mac mini";
    builder.devices.files = @{@"t_c4e19b05" : onMini};
    SZFriendsPersonFacts *mei = SZPPeople()[@"c_mei"];
    NSDictionary *built = [builder conversationForPerson:mei items:items hasEarlier:NO highlightItemID:nil
                                        waitingElsewhere:2 now:SZPNow()];
    SZPExpectFixture(built, @"devices-conversation-mei-again.json", @"conversation");
    // A host that cannot send Get again is told where the file is, and offered nothing.
    SZFriendsSnapshotBuilder *older = SZPBuilder(SZPAudience());
    older.devices = builder.devices;
    NSDictionary *plain = [older conversationForPerson:mei items:@[ items[0] ] hasEarlier:NO highlightItemID:nil
                                      waitingElsewhere:2 now:SZPNow()][@"items"][1];
    SZPExpect([plain[@"state"] isEqual:@"missing"] && [plain[@"actions"] count] == 0, @"no Get again: %@", plain);
    // Nor is anyone who is not a friend now: their file stays moved or deleted.
    mei.relation = SZFriendsPersonRelationRemoved;
    NSDictionary *removed = [builder conversationForPerson:mei items:@[ items[0] ] hasEarlier:NO highlightItemID:nil
                                          waitingElsewhere:2 now:SZPNow()][@"items"][1];
    SZPExpect([removed[@"state"] isEqual:@"missing"] && [removed[@"actions"] count] == 0, @"removed: %@", removed);
}

void SZPRunDevicesBuildTests(void) {
    TestProfileAndRows();
    TestLists();
    TestConversations();
    TestHistoryWords();
    TestFilesAgain();
}
