// friends-ui-e2e's flows for three people (SPDFMacFriendsUIE2E.h): Remove from a row's menu, on the computer at the
// dropdown and on the friend's, and a second computer joining Ana's profile; Remove from a friend's details.

#import "SPDFMacFriendsUIPairInternal.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"
#import "mac/SZFriendsListPage.h"

#pragma mark - Removing someone from the list

static NSDictionary* UIJoinRow(SZFE2EClient* client, NSString* list, NSString* state) {
    for (NSDictionary* row in [client dataFor:list][@"join_requests"])
        if ([row[@"state"] isEqual:state]) return row;
    return nil;
}

// Ana's second computer: a helper of its own that joins her profile (as friends-e2e-devices-check joins one), so
// it holds her friends too. `ana` is another app's client on Ana's helper, which approves.
static UIFriend* UIStartSecondComputer(SZFE2EWorld* world, SZFE2EClient* ana) {
    UIFriend* laptop = [UIFriend new];
    laptop.name = @"Ana";
    laptop.helper = [world helperNamed:@"ana-laptop"];
    NSString* home = [laptop.helper.stateDirectory stringByAppendingString:@"-home"];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary* env = [UIDeviceEnvironment(@"Ana laptop") mutableCopy];
    env[@"HOME"] = home;
    laptop.helper.extraEnvironment = env;
    if (![laptop.helper start]) return nil;
    laptop.client = [SZFE2EClient clientForHelper:laptop.helper];
    if (!laptop.client || ![[laptop.client intent:@"activate" fields:nil][@"ok"] boolValue]) return nil;
    laptop.list = [laptop.client subscribe:@"list" params:nil];
    NSString* profile = [ana subscribe:@"profile" params:nil];
    NSString* anaList = [ana subscribe:@"list" params:nil];
    __block NSString* friendsID = nil;
    if (!UIWait(5, ^BOOL {
            id value = [ana dataFor:profile][@"id"][@"friends_id"];
            friendsID = [value isKindOfClass:NSString.class] ? value : nil;
            return friendsID.length > 0;
        }))
        return nil;
    NSString* join = [laptop.client subscribe:@"join" params:nil];
    if (![[laptop.client intent:@"join_profile" fields:@{@"friends_id" : friendsID}][@"ok"] boolValue]) return nil;
    if (!UIWait(25, ^BOOL { return UIJoinRow(ana, anaList, @"waiting") != nil; })) return nil;
    NSDictionary* waiting = UIJoinRow(ana, anaList, @"waiting");
    if (![[ana intent:@"approve_join" fields:@{@"join_id" : waiting[@"join_id"]}][@"ok"] boolValue]) return nil;
    if (!UIWait(5, ^BOOL { return [UIJoinRow(ana, anaList, @"approved")[@"code"] length] > 0; })) return nil;
    NSString* code = UIJoinRow(ana, anaList, @"approved")[@"code"];
    if (![[laptop.client intent:@"enter_join_code" fields:@{@"code" : code}][@"ok"] boolValue]) return nil;
    if (!UIWait(25, ^BOOL { return [[laptop.client dataFor:join][@"state"] isEqual:@"joined"]; })) return nil;
    [laptop.client intent:@"unsubscribe" fields:@{@"subscription" : join}];
    [ana intent:@"unsubscribe" fields:@{@"subscription" : profile}];
    [ana intent:@"unsubscribe" fields:@{@"subscription" : anaList}];
    return laptop;
}

// A right-click as the window server delivers it: the press, then the release.
static BOOL UIRightClick(UIRig* rig, NSView* view, const char* file, int line) {
    NSString* why = nil;
    if (!view || !UIScrollIntoView(view) || !UIVisible(view)) why = @"not on screen";
    NSWindow* window = view.window;
    NSPoint point = NSZeroPoint;
    if (!why) {
        point = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
        NSView* hit = [(window.contentView.superview ?: window.contentView) hitTest:point];
        if (!(hit == view || [hit isDescendantOf:view])) why = [NSString stringWithFormat:@"lands on %@", hit.className];
    }
    if (why) {
        UIFail(rig, file, line, "a right-click reaches it", why);
        return NO;
    }
    [window makeKeyWindow];
    const NSEventType types[] = {NSEventTypeRightMouseDown, NSEventTypeRightMouseUp};
    for (NSEventType type : types) {
        NSEvent* event = [NSEvent mouseEventWithType:type location:point modifierFlags:0
                                           timestamp:NSProcessInfo.processInfo.systemUptime
                                        windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1
                                            pressure:type == NSEventTypeRightMouseDown ? 1 : 0];
        [window sendEvent:event];
    }
    UISpin(0.05);
    return YES;
}

// The owner's request of 2026-10-20: someone who is no longer a friend can be taken off the list. Ana right-clicks
// Mei, chooses Remove and confirms; Mei's row goes at once, stays gone with the helper's next list, and goes from
// Ana's other computer too. The history is kept (the box stays unticked).
BOOL UIRemoveFromList(UIRig* rig, SZFE2EWorld* world) {
    UIBeginFlow(rig, @"remove");
    UICloseDropdown(rig);
    SZFE2EClient* ana = [SZFE2EClient clientForHelper:rig.helper];
    EXPECT(rig, ana != nil, "another app connects to Ana's helper");
    UIFriend* laptop = UIStartSecondComputer(world, ana);
    EXPECT(rig, laptop != nil, "Ana's second computer joins her profile:\n%@", laptop.helper.log ?: @"");
    EXPECT(rig, UIWait(25, ^BOOL { return UIRowTitled([laptop.client dataFor:laptop.list], @"Mei") != nil; }),
           "the second computer lists Mei: %@", [laptop.client dataFor:laptop.list][@"rows"]);
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    __block SZFriendsRowView* row = nil;
    EXPECT(rig, UIWait(5, ^BOOL { return (row = UIRow(rig, @"Mei")) != nil; }), "Mei's row");
    NSString* meiID = row.conversationID;
    [rig.menus removeAllObjects];
    if (!UIRightClick(rig, row, __FILE__, __LINE__)) return NO;
    NSMenu* menu = rig.menus.lastObject;
    EXPECT(rig, menu.numberOfItems == 1 && [menu.itemArray.firstObject.title isEqualToString:@"Remove"],
           "right-click on Mei offers Remove: %@", menu.itemArray);
    EXPECT(rig, rig.dropdown.currentView == SZFriendsDropdownViewList, "the right-click opened nothing else");
    [menu performActionForItemAtIndex:0];
    SZFriendsConfirmView* confirm = rig.content.confirmation;
    EXPECT(rig, UIWait(3, ^BOOL { return UIFindText(rig.content, @"Remove Mei?") != nil; }),
           "Remove asks first:\n%@", UIDescribe(rig.content));
    EXPECT(rig, UIFindText(confirm, @"leaves your list") && UIVisible(confirm.optionCheckbox) &&
                    [confirm.optionCheckbox.title isEqualToString:@"Also delete chat history"] &&
                    confirm.optionCheckbox.state == NSControlStateValueOff,
           "it says what happens, with the history box unticked:\n%@", UIDescribe(confirm));
    EXPECT(rig, UIRow(rig, @"Mei") != nil, "nothing happens before the answer");
    UIShot(rig, @"confirm");
    NSInteger lists = UISnapshotCount(rig, @"list");
    CLICK(rig, confirm.confirmButton, @"Remove");
    EXPECT(rig, UIRow(rig, @"Mei") == nil, "Mei's row goes at once:\n%@", UIDescribe(rig.content));
    EXPECT(rig, UIWaitNextSnapshot(rig, @"list", lists, 10) &&
                    UIWait(10, ^BOOL { return UIRowTitled(rig.snapshots[@"list"], @"Mei") == nil; }),
           "the helper's list no longer has her: %@", rig.snapshots[@"list"][@"rows"]);
    EXPECT(rig, UIRow(rig, @"Mei") == nil && UIRow(rig, @"Kenji") != nil, "Mei stays gone, Kenji stays");
    UIShot(rig, @"removed");
    EXPECT(rig, UIWait(25, ^BOOL { return UIRowTitled([laptop.client dataFor:laptop.list], @"Mei") == nil; }),
           "Ana's second computer no longer lists Mei: %@", [laptop.client dataFor:laptop.list][@"rows"]);
    // Unticked: the chat with Mei is kept.
    NSString* atMei = [ana openConversation:meiID];
    EXPECT(rig, UIWait(10, ^BOOL {
               for (NSDictionary* item in UIItems([ana dataFor:atMei], @"message"))
                   if ([item.description containsString:@"Hello Mei"]) return YES;
               return NO;
           }), "the chat with Mei is kept: %@", [ana dataFor:atMei][@"items"]);
    [laptop.client close];
    [laptop.helper terminate];
    [ana close];
    return YES;
}

// Testing of 2026-10-22: Remove friend on a friend's details took the person off the list, and the dropdown stayed
// on their details, over their chat. Ana opens Kenji's chat, then his details from the name at the top, presses
// Remove friend and confirms: the dropdown is back on the list, without Kenji.
BOOL UIRemoveFromDetails(UIRig* rig) {
    UIBeginFlow(rig, @"remove-details");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    CLICK(rig, UIRow(rig, @"Kenji"), @"Kenji's row");
    EXPECT(rig, UIWait(5, ^BOOL { return rig.dropdown.currentView == SZFriendsDropdownViewConversation; }),
           "the chat with Kenji opens");
    SZFriendsConversationPage* chat = (SZFriendsConversationPage*)rig.content.topPage;
    CLICK(rig, chat.header.titleButton, @"Kenji's name");
    EXPECT(rig, UIWait(5, ^BOOL { return rig.dropdown.currentView == SZFriendsDropdownViewDetails; }),
           "his details open:\n%@", UIDescribe(rig.content));
    SZFriendsPage* details = rig.content.topPage;
    __block NSButton* remove = nil;
    EXPECT(rig, UIWait(5, ^BOOL { return (remove = UIFindButton(details, @"Remove friend")) != nil; }),
           "the details offer Remove friend:\n%@", UIDescribe(details));
    UIShot(rig, @"details");
    CLICK(rig, remove, @"Remove friend");
    SZFriendsConfirmView* confirm = rig.content.confirmation;
    EXPECT(rig, UIWait(3, ^BOOL { return UIFindText(rig.content, @"Remove Kenji?") != nil; }),
           "Remove asks first:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"confirm");
    CLICK(rig, confirm.confirmButton, @"Remove");
    EXPECT(rig, UIWait(10, ^BOOL { return rig.dropdown.currentView == SZFriendsDropdownViewList; }),
           "the dropdown is back on the list:\n%@", UIDescribe(rig.content));
    EXPECT(rig, UIWait(10, ^BOOL { return UIRow(rig, @"Kenji") == nil; }), "without Kenji:\n%@",
           UIDescribe(rig.content));
    UIShot(rig, @"back-on-list");
    return YES;
}
