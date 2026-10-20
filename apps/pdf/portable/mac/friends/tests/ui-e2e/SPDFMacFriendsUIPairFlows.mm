// friends-ui-e2e's flows for three people (SPDFMacFriendsUIE2E.h): the person at the dropdown (Ana) and two friends,
// each a real helper in a home of its own, meeting over loopback Nearby. Mei asks Ana, who accepts in the list; Ana
// asks Kenji from Nearby, and he accepts; then a message and a small file each way with Mei, and search.

#import "SPDFMacFriendsUIE2E.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsListPage.h"

static NSString* UIToken(void) {
    return [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
}

static NSDictionary* UIRowTitled(NSDictionary* list, NSString* title) {
    for (NSDictionary* row in list[@"rows"])
        if ([row[@"title"] isEqual:title]) return row;
    return nil;
}

static NSArray<NSDictionary*>* UIItems(NSDictionary* conversation, NSString* kind) {
    NSMutableArray* items = [NSMutableArray array];
    for (NSDictionary* item in conversation[@"items"])
        if ([item[@"kind"] isEqual:kind]) [items addObject:item];
    return items;
}

// The list row (a button) whose accessibility label starts with `title`.
static SZFriendsRowView* UIRow(UIRig* rig, NSString* title) {
    for (SZFriendsRowView* row in rig.listPage.rows)
        if ([row.accessibilityLabel hasPrefix:title] && UIVisible(row)) return row;
    return nil;
}

static SZFriendsRowView* UINearbyRow(UIRig* rig, NSString* title) {
    for (SZFriendsRowView* row in rig.listPage.nearbyPane.personRows)
        if ([row.accessibilityLabel hasPrefix:title] && UIVisible(row)) return row;
    return nil;
}

static BOOL UIClickChecked(UIRig* rig, NSView* _Nullable view, NSString* what, const char* file, int line) {
    NSString* why = nil;
    if (view && UIClick(view, &why)) return YES;
    UIFail(rig, file, line, "a click reaches it", [NSString stringWithFormat:@"%@: %@", what, why ?: @"not found"]);
    return NO;
}
#define CLICK(rig, view, what)                                                                                     \
    do {                                                                                                           \
        if (!UIClickChecked(rig, view, what, __FILE__, __LINE__)) return NO;                                      \
    } while (0)

// One of the two friends: a helper in its own home and the client library driving it.
@interface UIFriend : NSObject
@property(nonatomic, strong) SZFE2EHelper* helper;
@property(nonatomic, strong) SZFE2EClient* client;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* list;
@property(nonatomic, copy, nullable) NSString* anaID; // Ana's conversation in this friend's list
@end
@implementation UIFriend
@end

static UIFriend* UIStartFriend(SZFE2EWorld* world, NSString* name) {
    UIFriend* person = [UIFriend new];
    person.name = name;
    person.helper = [world helperNamed:name.lowercaseString];
    NSString* home = [person.helper.stateDirectory stringByAppendingString:@"-home"];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary* env = [UIDeviceEnvironment(name) mutableCopy];
    env[@"HOME"] = home;
    person.helper.extraEnvironment = env;
    if (![person.helper start]) return nil;
    person.client = [SZFE2EClient clientForHelper:person.helper];
    if (!person.client) return nil;
    if (![[person.client intent:@"activate" fields:nil][@"ok"] boolValue]) return nil;
    if (![[person.client intent:@"set_name" fields:@{@"name" : name}][@"ok"] boolValue]) return nil;
    person.list = [person.client subscribe:@"list" params:nil];
    return person.list ? person : nil;
}

static BOOL UIBecomeAna(UIRig* rig) {
    UIBeginFlow(rig, @"pair-name");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsNameEditor* editor = rig.listPage.namePromptEditor;
    EXPECT(rig, editor != nil, "the name card");
    CLICK(rig, editor.field, @"the name field");
    UIType(rig.popoverWindow, @"Ana");
    UIPressReturn(rig.popoverWindow);
    EXPECT(rig, UIWait(5, ^BOOL { return rig.listPage.namePromptEditor == nil; }), "the card goes");
    return YES;
}

// Mei asks Ana while Ana is visible; Ana accepts from the list's row.
static BOOL UIAcceptRequest(UIRig* rig, UIFriend* mei) {
    UIBeginFlow(rig, @"accept-request");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsListPage* list = rig.listPage;
    CLICK(rig, list.nearbyTab, @"the Nearby tab");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindButton(rig.content, @"Make myself visible for 5 minutes") != nil; }),
           "the offer to be visible");
    CLICK(rig, UIFindButton(rig.content, @"Make myself visible for 5 minutes"), @"Make myself visible");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindButton(rig.content, @"Stop") != nil; }), "visible, with Stop");
    NSString* nearby = [mei.client subscribe:@"nearby" params:nil];
    __block NSString* nearbyID = nil;
    EXPECT(rig, UIWait(25, ^BOOL {
               for (NSDictionary* person in [mei.client dataFor:nearby][@"people"])
                   if ([person[@"title"] isEqual:@"Ana"] && [person[@"nearby_id"] isKindOfClass:NSString.class])
                       nearbyID = person[@"nearby_id"];
               return nearbyID != nil;
           }), "Mei sees Ana in Nearby: %@", [mei.client dataFor:nearby]);
    NSDictionary* reply = [mei.client intent:@"send_request" fields:@{@"nearby_id" : nearbyID}];
    EXPECT(rig, [reply[@"ok"] boolValue], "Mei asks: %@", reply);
    [mei.client intent:@"unsubscribe" fields:@{@"subscription" : nearby}];
    CLICK(rig, list.friendsTab, @"the Friends tab");
    __block SZFriendsRowView* row = nil;
    EXPECT(rig, UIWait(15, ^BOOL { return (row = UIRow(rig, @"Mei")) != nil && row.actionsView != nil; }),
           "Mei's request shows in the list with its buttons:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"request");
    // Accept and Decline say their word on the button, so a first-time reader tells Decline from Block; Block is
    // its icon, named for VoiceOver and the tooltip, and asks first (the owner's report of 2026-10-20).
    NSButton* accept = UIFindButton(row, @"Accept");
    NSButton* decline = UIFindButton(row, @"Decline");
    NSButton* block = UIFindButton(row, @"Block Mei");
    EXPECT(rig, accept && decline && block, "the row shows Accept, Decline and Block:\n%@", UIDescribe(row));
    EXPECT(rig, [accept.accessibilityLabel hasPrefix:@"Accept Mei"] &&
                    [decline.accessibilityLabel hasPrefix:@"Decline Mei"] && [block.toolTip isEqualToString:@"Block Mei"] && block.title.length == 0,
           "each is named for what it does (%@, %@, %@)", accept.accessibilityLabel, decline.accessibilityLabel,
           block.toolTip);
    CLICK(rig, accept, @"Accept");
    EXPECT(rig, UIWait(15, ^BOOL { return [UIRowTitled([mei.client dataFor:mei.list], @"Ana")[@"drop_label"] length] > 0; }),
           "Mei sees Ana as a friend: %@", [mei.client dataFor:mei.list]);
    EXPECT(rig, UIWait(10, ^BOOL {
               SZFriendsRowView* now = UIRow(rig, @"Mei");
               return now && !UIVisible(now.actionsView) && now.dropLabel.length > 0;
           }), "Ana's row for Mei is a friend's, without the buttons (actions %@, drop label %@)",
           UIRow(rig, @"Mei").actionsView, UIRow(rig, @"Mei").dropLabel);
    mei.anaID = UIRowTitled([mei.client dataFor:mei.list], @"Ana")[@"conversation_id"];
    UIShot(rig, @"accepted");
    return YES;
}

// Kenji is visible; Ana asks him from Nearby's Request, and he accepts.
static BOOL UISendRequest(UIRig* rig, UIFriend* kenji) {
    UIBeginFlow(rig, @"send-request");
    EXPECT(rig, [[kenji.client intent:@"start_visibility" fields:nil][@"result"][@"deadline"] length] > 0,
           "Kenji is visible");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsListPage* list = rig.listPage;
    CLICK(rig, list.nearbyTab, @"the Nearby tab");
    __block SZFriendsRowView* row = nil;
    EXPECT(rig, UIWait(25, ^BOOL { return (row = UINearbyRow(rig, @"Kenji")) != nil && row.accessoryButton; }),
           "Kenji shows in Nearby with Request:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"nearby-kenji");
    EXPECT(rig, [row.accessoryButton.title isEqualToString:@"Request"], "the row's button: %@", row.accessoryButton.title);
    CLICK(rig, row.accessoryButton, @"Request");
    EXPECT(rig, UIWait(10, ^BOOL { return UIFindText(rig.content, @"Request sent") != nil; }),
           "the row says the request went:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"request-sent");
    EXPECT(rig, UIWait(15, ^BOOL { return UIRowTitled([kenji.client dataFor:kenji.list], @"Ana") != nil; }),
           "Kenji gets Ana's request");
    kenji.anaID = UIRowTitled([kenji.client dataFor:kenji.list], @"Ana")[@"conversation_id"];
    NSDictionary* reply = [kenji.client intent:@"accept_request" fields:@{@"conversation_id" : kenji.anaID}];
    EXPECT(rig, [reply[@"ok"] boolValue], "Kenji accepts: %@", reply);
    CLICK(rig, list.friendsTab, @"the Friends tab");
    EXPECT(rig, UIWait(15, ^BOOL {
               SZFriendsRowView* now = UIRow(rig, @"Kenji");
               return now && now.dropLabel.length > 0;
           }), "Kenji is Ana's friend in the list:\n%@", UIDescribe(rig.content));
    [kenji.client intent:@"stop_visibility" fields:nil];
    UIShot(rig, @"friends");
    return YES;
}

static SZFriendsConversationPage* UIConversation(UIRig* rig) {
    SZFriendsPage* page = rig.content.topPage;
    return [page isKindOfClass:SZFriendsConversationPage.class] ? (SZFriendsConversationPage*)page : nil;
}

static BOOL UIMessages(UIRig* rig, UIFriend* mei) {
    UIBeginFlow(rig, @"messages");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    CLICK(rig, UIRow(rig, @"Mei"), @"Mei's row");
    EXPECT(rig, UIWait(5, ^BOOL { return UIConversation(rig) != nil; }), "the conversation with Mei opens");
    SZFriendsConversationPage* page = UIConversation(rig);
    EXPECT(rig, UIWait(5, ^BOOL { return UIVisible(page.composer.textView); }), "with a composer");
    CLICK(rig, page.composer.textView, @"the composer");
    EXPECT(rig, UIType(rig.popoverWindow, @"Hello Mei"), "typing reaches the composer");
    // The hint in words a newcomer follows (the owner's report of 2026-10-20: "# Attach · @ Mention").
    EXPECT(rig, UIFindText(page, @"Type # to attach, @ to mention someone, or drop files here") &&
                    !UIFindText(page, @"# Attach"),
           "the composer's hint is plain:\n%@", UIDescribe(page));
    UIShot(rig, @"typed");
    UIPressReturn(rig.popoverWindow);
    NSString* atMei = [mei.client openConversation:mei.anaID];
    EXPECT(rig, UIWait(15, ^BOOL {
               for (NSDictionary* item in UIItems([mei.client dataFor:atMei], @"message"))
                   if ([item.description containsString:@"Hello Mei"]) return YES;
               return NO;
           }), "Mei receives the message: %@", [mei.client dataFor:atMei][@"items"]);
    EXPECT(rig, page.composer.textView.string.length == 0, "the composer empties once sent");
    EXPECT(rig, UIWait(10, ^BOOL { return UIFindText(page, @"Hello Mei") != nil; }), "Ana sees her message");
    NSDictionary* reply = [mei.client intent:@"send_message"
                                     fields:@{@"conversation_id" : mei.anaID, @"text" : @"Hi Ana, got it",
                                              @"client_token" : UIToken()}];
    EXPECT(rig, [reply[@"ok"] boolValue], "Mei answers: %@", reply);
    EXPECT(rig, UIWait(15, ^BOOL { return UIFindText(page, @"Hi Ana, got it") != nil; }),
           "Mei's answer shows in the open conversation:\n%@", UIDescribe(page));
    UIShot(rig, @"both-ways");
    [mei.client intent:@"unsubscribe" fields:@{@"subscription" : atMei}];
    return YES;
}

static NSString* UIFileOfSize(SZFE2EWorld* world, NSString* name, NSUInteger size) {
    return [world fileOfSize:size named:name];
}

static BOOL UIFiles(UIRig* rig, UIFriend* mei, SZFE2EWorld* world) {
    UIBeginFlow(rig, @"files");
    // A file dropped on the Friends button: the views' send picker, then a click on Mei.
    NSString* outgoing = UIFileOfSize(world, @"site-notes.txt", 24 * 1024);
    SZFriendsAttachableItem* item = [SZFriendsAttachableItem new];
    item.title = @"site-notes.txt";
    item.detail = @"";
    item.kindLabel = @"TXT";
    item.fileURL = [NSURL fileURLWithPath:outgoing];
    [rig.dropdown beginSendPickerWithItems:@[ item ]];
    EXPECT(rig, UIWait(5, ^BOOL { return rig.dropdown.shown && rig.dropdown.currentView == SZFriendsDropdownViewList; }),
           "the drop opens the list to choose whom to send it to");
    [rig.popoverWindow makeKeyWindow];
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(rig.content, @"site-notes.txt") != nil; }),
           "the list says which file is about to go:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"send-picker");
    CLICK(rig, UIRow(rig, @"Mei"), @"Mei's row");
    EXPECT(rig, UIWait(5, ^BOOL { return UIConversation(rig) != nil; }), "the conversation opens on the file");
    SZFriendsConversationPage* page = UIConversation(rig);
    EXPECT(rig, UIWait(15, ^BOOL { return UIFindText(page, @"site-notes.txt") != nil; }), "the file shows in the chat");
    NSString* atMei = [mei.client openConversation:mei.anaID];
    __block NSString* incoming = nil;
    EXPECT(rig, UIWait(15, ^BOOL {
               for (NSDictionary* transfer in UIItems([mei.client dataFor:atMei], @"transfer"))
                   if ([transfer[@"state"] isEqual:@"waiting_for_you"]) incoming = transfer[@"transfer_id"];
               return incoming != nil;
           }), "Mei is asked to accept it: %@", [mei.client dataFor:atMei][@"items"]);
    EXPECT(rig, UIWait(10, ^BOOL { return UIFindText(page, @"Waiting for Mei to accept") != nil; }),
           "Ana's card waits for Mei:\n%@", UIDescribe(page));
    UIShot(rig, @"offered");
    NSDictionary* reply = [mei.client intent:@"accept_offer" fields:@{@"transfer_id" : incoming}];
    EXPECT(rig, [reply[@"ok"] boolValue], "Mei accepts: %@", reply);
    EXPECT(rig, UIWait(20, ^BOOL { return UIFindText(page, @"Delivered to Mei") != nil; }),
           "Ana's card says Delivered:\n%@", UIDescribe(page));
    UIShot(rig, @"delivered");
    // Mei sends one back; Ana accepts it from the card.
    NSString* back = UIFileOfSize(world, @"reply.pdf", 18 * 1024);
    reply = [mei.client intent:@"send_files" fields:@{@"conversation_id" : mei.anaID, @"files" : @[ @{@"path" : back} ],
                                                      @"client_token" : UIToken()}];
    EXPECT(rig, [reply[@"ok"] boolValue], "Mei sends a file: %@", reply);
    EXPECT(rig, UIWait(15, ^BOOL { return UIFindText(page, @"Waiting for you to accept") != nil; }),
           "Ana is asked:\n%@", UIDescribe(page));
    __block NSButton* accept = nil;
    EXPECT(rig, UIWait(5, ^BOOL { return (accept = UIFindButton(page, @"Accept")) != nil; }), "with Accept");
    UIShot(rig, @"incoming");
    CLICK(rig, accept, @"Accept");
    // Arrived: the card's status reads Received and it offers Show in Finder.
    EXPECT(rig, UIWait(20, ^BOOL {
               for (NSView* view in UIAllViews(page))
                   if ([view isKindOfClass:NSTextField.class] && UIVisible(view) &&
                       [((NSTextField*)view).stringValue isEqualToString:@"Received"])
                       return UIFindButton(page, @"Show in Finder") != nil;
               return NO;
           }), "the file arrives:\n%@", UIDescribe(page));
    NSString* received = [rig.helper.stateDirectory stringByAppendingPathComponent:@"received"];
    __block NSString* found = nil;
    EXPECT(rig, UIWait(5, ^BOOL {
               for (NSString* name in [NSFileManager.defaultManager enumeratorAtPath:received])
                   if ([name.lastPathComponent isEqualToString:@"reply.pdf"])
                       found = [received stringByAppendingPathComponent:name];
               return found != nil;
           }), "the file is in Ana's received folder");
    EXPECT(rig, [[NSData dataWithContentsOfFile:found] isEqual:[NSData dataWithContentsOfFile:back]], "same bytes");
    NSButton* show = UIFindButton(page, @"Show in Finder");
    EXPECT(rig, show != nil, "the card offers Show in Finder:\n%@", UIDescribe(page));
    CLICK(rig, show, @"Show in Finder");
    EXPECT(rig, UIWait(3, ^BOOL { return rig.bridge.revealed.count > 0; }), "Show in Finder asks the reader");
    UIShot(rig, @"received");
    [mei.client intent:@"unsubscribe" fields:@{@"subscription" : atMei}];
    CLICK(rig, page.header.backButton, @"Back");
    EXPECT(rig, UIWait(5, ^BOOL { return rig.dropdown.currentView == SZFriendsDropdownViewList; }), "back to the list");
    return YES;
}

static BOOL UISearch(UIRig* rig) {
    UIBeginFlow(rig, @"search");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsListPage* list = rig.listPage;
    EXPECT(rig, UIRow(rig, @"Mei") && UIRow(rig, @"Kenji"), "both friends are listed");
    CLICK(rig, list.searchField, @"the search field");
    UIType(rig.popoverWindow, @"Mei");
    EXPECT(rig, UIWait(5, ^BOOL { return UIRow(rig, @"Mei") && !UIRow(rig, @"Kenji"); }),
           "typing Mei leaves Mei alone:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"mei");
    UIClearField(rig.popoverWindow);
    UIType(rig.popoverWindow, @"zzz");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(rig.content, @"No one matches") != nil && !UIRow(rig, @"Mei"); }),
           "no match says so:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"no-match");
    UIClearField(rig.popoverWindow);
    EXPECT(rig, UIWait(5, ^BOOL { return UIRow(rig, @"Mei") && UIRow(rig, @"Kenji"); }), "clearing shows both again");
    // The search follows to Nearby and back. The whole name: search also matches IDs, and "ken" is in five words
    // a random Friends ID is made of (awaken, kennel, unbroken, unshaken, unspoken), which once matched Mei.
    UIType(rig.popoverWindow, @"Kenji");
    CLICK(rig, list.nearbyTab, @"the Nearby tab");
    CLICK(rig, list.friendsTab, @"the Friends tab");
    EXPECT(rig, UIWait(5, ^BOOL { return UIRow(rig, @"Kenji") && !UIRow(rig, @"Mei"); }),
           "back on Friends the search still applies:\n%@", UIDescribe(rig.content));
    CLICK(rig, list.searchField, @"the search field");
    UIClearField(rig.popoverWindow);
    UIShot(rig, @"cleared");
    return YES;
}

BOOL UIFlowTwoPeople(SZFE2EWorld* world, UIVariant* variant) {
    [world beginScenario:[@"pair-" stringByAppendingString:variant.name]];
    UIRig* rig = UIStartRig(world, variant, @"ana", nil);
    UIFriend* mei = rig ? UIStartFriend(world, @"Mei") : nil;
    UIFriend* kenji = mei ? UIStartFriend(world, @"Kenji") : nil;
    if (!rig || !mei || !kenji) {
        UIFail(rig, __FILE__, __LINE__, "three helpers start", @"");
        [world printLogs];
        if (rig) UIStopRig(rig);
        [world endScenario];
        UIRecord(variant, @"two people: start", NO);
        return NO;
    }
    BOOL all = YES;
    struct {
        NSString* name;
        BOOL (^run)(void);
    } steps[] = {
        {@"two people: choose the name", ^BOOL { return UIBecomeAna(rig); }},
        {@"two people: be visible, accept a request in the list", ^BOOL { return UIAcceptRequest(rig, mei); }},
        {@"two people: Request from Nearby, accepted", ^BOOL { return UISendRequest(rig, kenji); }},
        {@"two people: a message each way", ^BOOL { return UIMessages(rig, mei); }},
        {@"two people: a file each way", ^BOOL { return UIFiles(rig, mei, world); }},
        {@"search filters the list", ^BOOL { return UISearch(rig); }},
    };
    for (auto& step : steps) {
        if (!all) {
            UIRecord(variant, [step.name stringByAppendingString:@" (not run: an earlier step failed)"], NO);
            continue;
        }
        int failuresBefore = UIFailures;
        BOOL passed = step.run() && UIFailures == failuresBefore;
        UIRecord(variant, step.name, passed);
        // Each step needs the ones before it (a friend to message, a file to receive).
        all = all && passed;
    }
    if (!all) [world printLogs];
    UIStopRig(rig);
    [mei.client close];
    [kenji.client close];
    [world endScenario];
    return all;
}
