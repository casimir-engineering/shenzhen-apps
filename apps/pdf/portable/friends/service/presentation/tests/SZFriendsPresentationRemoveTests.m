// Removing people from the list (remove_friend, client capability list.menu): every row's menu and its question, the
// You row's empty menu, people off the list skipped by the list and the badge, and snapshots for clients without
// list.menu left exactly as they were.
//
// The list-menu.json fixture is the list's people with three changed, so one list shows every kind of row:
// Tulip is a former friend (Removed), Daniel a link contact (Removed, linkContact) and Priya a request this person
// sent (OutgoingRequest); Kenji is off the list (Removed, leftList). With the You row as devices-list.json has it.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsTransfers.h"

static SZFriendsAudience *MenuAudience(void) {
    SZFriendsAudience *audience = SZPAudience();
    audience.capabilities = [audience.capabilities setByAddingObject:@"list.menu"];
    return audience;
}

static NSArray<SZFriendsPersonFacts *> *MenuPeople(void) {
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    people[@"c_tulip"].relation = SZFriendsPersonRelationRemoved;
    people[@"c_daniel"].relation = SZFriendsPersonRelationRemoved;
    people[@"c_daniel"].linkContact = YES;
    people[@"c_priya"].relation = SZFriendsPersonRelationOutgoingRequest;
    people[@"c_kenji"].relation = SZFriendsPersonRelationRemoved;
    people[@"c_kenji"].leftList = YES;
    return people.allValues;
}

static SZFriendsDevicesFacts *YouOnly(void) {
    SZFriendsDevicesFacts *facts = [[SZFriendsDevicesFacts alloc] init];
    facts.now = SZPNow();
    SZFriendsProfileFacts *profile = SZPProfileRaph();
    SZFriendsPersonFacts *you = [[SZFriendsPersonFacts alloc] init];
    you.conversationID = @"you";
    you.name = profile.name;
    you.friendsID = profile.friendsID;
    you.picture = profile.picture;
    you.relation = SZFriendsPersonRelationFriend;
    you.lastInteractionAt = SZPHongKong(@"2026-10-12 15:02");
    facts.you = you;
    facts.youPreview = SZPTransfer(@"t_6a2e9f14", YES, @"2026-10-12 15:02", @"Bracket drawing rev C.pdf", 41203776,
                                   SZFriendsTransferStateSending);
    return facts;
}

static NSDictionary *MenuList(SZFriendsAudience *audience, NSArray<SZFriendsPersonFacts *> *people) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(audience);
    builder.devices = YouOnly();
    NSMutableDictionary *list = [[builder listWithPeople:people previewItems:SZPPreviewItems()
                                                 profile:SZPProfileRaph() query:@"" now:SZPNow()] mutableCopy];
    list[@"join_requests"] = @[];
    return [builder listWithDevices:list people:people query:@"" now:SZPNow()];
}

static NSDictionary *RowFor(NSDictionary *list, NSString *conversationID) {
    for (NSDictionary *row in list[@"rows"])
        if ([row[@"conversation_id"] isEqual:conversationID]) return row;
    return nil;
}

static void TestMenuFixture(void) {
    NSDictionary *list = MenuList(MenuAudience(), MenuPeople());
    SZPExpectFixture(list, @"list-menu.json", @"list");
    SZPExpect(RowFor(list, @"c_kenji") == nil, @"someone off the list has no row");
    SZPExpect([RowFor(list, @"you")[@"menu"] isEqual:@[]], @"the You row's menu is empty");
    NSDictionary *mei = RowFor(list, @"c_mei")[@"menu"][0];
    SZPExpect([mei[@"action"] isEqual:@"remove_friend"] && [mei[@"label"] isEqual:@"Remove"] &&
                  [mei[@"style"] isEqual:@"destructive"] && mei[@"arm"] == NSNull.null,
              @"Remove, in red, asked once: %@", mei);
    SZPExpect([mei[@"confirm"][@"option"] isEqual:(@{@"label" : @"Also delete chat history",
                                                     @"field" : @"delete_history"})],
              @"history with Mei: the option to delete it too: %@", mei[@"confirm"]);
    NSDictionary *priya = RowFor(list, @"c_priya")[@"menu"][0][@"confirm"];
    SZPExpect([RowFor(list, @"c_priya")[@"menu"][0][@"label"] isEqual:@"Cancel request"] &&
                  [priya[@"title"] isEqual:@"Cancel your request to Priya?"] &&
                  [priya[@"confirm_label"] isEqual:@"Cancel request"] &&
                  [priya[@"cancel_label"] isEqual:@"Keep request"] &&
                  [priya[@"body"] hasPrefix:@"Priya won’t get your request, and leaves your list."],
              @"a request this person sent is cancelled: %@", priya);
    NSDictionary *jonas = RowFor(list, @"c_jonas")[@"menu"][0][@"confirm"];
    SZPExpect([jonas[@"body"] hasPrefix:@"Jonas leaves your list and stays blocked."], @"blocked: %@", jonas);
    NSDictionary *lena = RowFor(list, @"c_lena")[@"menu"][0][@"confirm"];
    SZPExpect([lena[@"title"] isEqual:@"Remove Lena?"] &&
                  [lena[@"body"] hasPrefix:@"Lena leaves your list. Either of you can send a new request later."],
              @"incoming request: %@", lena);
}

// Without history, the question says nothing about it and offers no option.
static void TestNoHistoryNoOption(void) {
    NSArray<SZFriendsPersonFacts *> *people = MenuPeople();
    for (SZFriendsPersonFacts *person in people) person.lastPreviewItemID = nil;
    NSDictionary *list = MenuList(MenuAudience(), people);
    for (NSDictionary *row in list[@"rows"]) {
        for (NSDictionary *action in row[@"menu"]) {
            SZPExpect(action[@"confirm"][@"option"] == nil && ![action[@"confirm"][@"body"] containsString:@"history"],
                      @"%@: %@", row[@"conversation_id"], action[@"confirm"]);
        }
    }
    // Tulip has no name yet, so her Friends ID names her.
    NSDictionary *confirm = RowFor(list, @"c_tulip")[@"menu"][0][@"confirm"];
    SZPExpect([confirm isEqual:(@{@"title" : @"Remove tulip\u2011canyon?",
                                  @"body" : @"tulip\u2011canyon leaves your list. Either of you can send a new "
                                            @"request later.",
                                  @"confirm_label" : @"Remove", @"cancel_label" : @"Cancel",
                                  @"destructive" : @YES})],
              @"a former friend without history: %@", confirm);
}

// A client without list.menu gets the snapshots it always got, apart from the people taken off the list.
static void TestWithoutMenu(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSArray<SZFriendsPersonFacts *> *everyone = SZPPeople().allValues;
    NSDictionary *list = [builder listWithPeople:everyone previewItems:SZPPreviewItems() profile:SZPProfileRaph()
                                           query:@"" now:SZPNow()];
    for (NSDictionary *row in list[@"rows"]) SZPExpect(row[@"menu"] == nil, @"no menu key: %@", row);
    NSDictionary *withYou = MenuList(SZPAudience(), MenuPeople());
    for (NSDictionary *row in withYou[@"rows"]) SZPExpect(row[@"menu"] == nil, @"no menu key: %@", row);
}

// Off the list: no row, nothing waiting on the badge, and "nobody yet" once nobody else is listed; a search for them
// finds no row either.
static void TestOffTheList(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    SZFriendsPersonFacts *kenji = people[@"c_kenji"];
    NSInteger before = [[builder badgeWithPeople:people.allValues][@"count"] integerValue];
    kenji.relation = SZFriendsPersonRelationRemoved;
    kenji.leftList = YES;
    SZPExpect([[builder badgeWithPeople:people.allValues][@"count"] integerValue] == before - 1,
              @"his waiting offer no longer counts");
    NSDictionary *list = [builder listWithPeople:@[ kenji ] previewItems:SZPPreviewItems() profile:SZPProfileRaph()
                                           query:@"" now:SZPNow()];
    SZPExpect([list[@"rows"] count] == 0 && [list[@"empty"][@"title"] isEqual:[builder.strings
                                                                                  text:@"list.empty.title"]] &&
                  list[@"empty"][@"kind"] == nil,
              @"nobody listed: the empty list: %@", list[@"empty"]);
    list = [builder listWithPeople:@[ kenji ] previewItems:SZPPreviewItems() profile:SZPProfileRaph()
                             query:@"Kenji" now:SZPNow()];
    SZPExpect([list[@"rows"] count] == 0, @"a filter does not bring him back");
    SZPValidateSnapshot(list, @"list", @"off the list");
    SZPExpect([builder detailsForPerson:kenji waitingElsewhere:0 now:SZPNow()] != nil, @"his details still open");
}

// A friend's details: Remove friend keeps its place and label, says the person leaves the list, and asks the list's
// question.
static void TestDetailsRemove(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    SZFriendsPersonFacts *mei = SZPPeople()[@"c_mei"];
    NSDictionary *details = [builder detailsForPerson:mei waitingElsewhere:0 now:SZPNow()];
    NSDictionary *remove = details[@"actions"][1];
    SZPExpect([remove[@"action"] isEqual:@"remove_friend"] && [remove[@"label"] isEqual:@"Remove friend"] &&
                  [remove[@"note"] isEqual:@"Takes Mei off your list. Mei can send you a new request."],
              @"%@", remove);
    SZPExpect([remove[@"confirm"] isEqual:[builder removeConfirmForPerson:mei]], @"the same question as the menu");
}

void SZPRunRemoveTests(void) {
    TestMenuFixture();
    TestNoHistoryNoOption();
    TestWithoutMenu();
    TestOffTheList();
    TestDetailsRemove();
}
