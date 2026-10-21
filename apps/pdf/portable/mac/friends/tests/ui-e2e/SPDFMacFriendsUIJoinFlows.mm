// friends-ui-e2e's flow for one person with two computers (SPDFMacFriendsUIE2E.h): this Mac uses the profile of the
// person's other computer through the join page (PROTOCOL.md § Joining), and the page names the route it joined over.

#import "SPDFMacFriendsUIFlowsInternal.h"

#import "mac/SZFriendsDevices.h"
#import "mac/SZFriendsListPage.h"

static NSDictionary* UIWaitingJoin(SZFE2EClient* client, NSString* list, NSString* state) {
    for (NSDictionary* row in [client dataFor:list][@"join_requests"])
        if ([row[@"state"] isEqual:state]) return row;
    return nil;
}

static SZFriendsJoinPage* UIJoinPage(UIRig* rig) {
    SZFriendsPage* page = rig.content.topPage;
    return [page isKindOfClass:SZFriendsJoinPage.class] ? (SZFriendsJoinPage*)page : nil;
}

// Clicks the visible field `field` and types `text` into it, as a person does.
static BOOL UIFill(UIRig* rig, NSTextField* field, NSString* text, const char* file, int line) {
    NSString* why = nil;
    if (!UIVisible(field) || (!UIClick(field, &why) && ![field.window makeFirstResponder:field])) {
        UIFail(rig, file, line, "the field takes typing", why ?: @"not visible");
        return NO;
    }
    UIClearField(field.window);
    return UIType(field.window, text);
}

// The route line of the join page: its words shown, and its icon drawn before them.
static BOOL UIJoinRouteShown(SZFriendsJoinPage* page) {
    return page && UIVisible(page.routeLabel) && page.routeLabel.stringValue.length > 0 &&
           !page.routeIconView.hidden && NSMaxX(page.routeIconView.frame) <= NSMinX(page.routeLabel.frame);
}

// The person's other computer is a helper of its own (Ana's, with her name). On this Mac, which has nobody to lose
// after the earlier steps, "Use my existing profile…" opens the join page: the other computer's ID, Approve there,
// the code it shows typed here, Join. While the code is checked, and once joined, the page shows the route.
BOOL UIJoinExistingProfile(UIRig* rig, SZFE2EWorld* world) {
    UIBeginFlow(rig, @"join");
    UICloseDropdown(rig);
    SZFE2EHelper* other = [world helperNamed:@"other-computer"];
    NSString* home = [other.stateDirectory stringByAppendingString:@"-home"];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary* env = [UIDeviceEnvironment(@"Ana studio") mutableCopy];
    env[@"HOME"] = home;
    other.extraEnvironment = env;
    EXPECT(rig, [other start], "the other computer's helper starts");
    SZFE2EClient* there = [SZFE2EClient clientForHelper:other];
    EXPECT(rig, there && [[there intent:@"activate" fields:nil][@"ok"] boolValue] &&
                    [[there intent:@"set_name" fields:@{@"name" : @"Ana"}][@"ok"] boolValue],
           "the other computer has a profile:\n%@", other.log);
    NSString* profile = [there subscribe:@"profile" params:nil];
    NSString* list = [there subscribe:@"list" params:nil];
    __block NSString* friendsID = nil;
    EXPECT(rig, UIWait(5, ^BOOL {
               id value = [there dataFor:profile][@"id"][@"friends_id"];
               friendsID = [value isKindOfClass:NSString.class] ? value : nil;
               return friendsID.length > 0;
           }), "its Friends ID");

    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    [rig.content popToList];
    __block SZFriendsButton* offer = nil;
    EXPECT(rig, UIWait(10, ^BOOL { return (offer = rig.listPage.joinButton) != nil && UIVisible(offer); }),
           "the list offers the existing profile:\n%@", UIDescribe(rig.content));
    CLICK(rig, offer, offer.title);
    EXPECT(rig, UIWait(5, ^BOOL { return UIJoinPage(rig) != nil && UIVisible(UIJoinPage(rig).idField); }),
           "the join page asks for the ID:\n%@", UIDescribe(rig.content));
    SZFriendsJoinPage* page = UIJoinPage(rig);
    EXPECT(rig, page.routeLabel.hidden && page.routeIconView.hidden, "no route before a code is checked");
    UIShot(rig, @"id");
    if (!UIFill(rig, page.idField, friendsID, __FILE__, __LINE__)) return NO;
    CLICK(rig, page.idButton, @"Continue");

    EXPECT(rig, UIWait(25, ^BOOL { return UIWaitingJoin(there, list, @"waiting") != nil; }),
           "the other computer is asked: %@", [there dataFor:list][@"join_requests"]);
    NSDictionary* reply = [there intent:@"approve_join"
                                 fields:@{@"join_id" : UIWaitingJoin(there, list, @"waiting")[@"join_id"]}];
    EXPECT(rig, [reply[@"ok"] boolValue], "it approves: %@", reply);
    __block NSString* code = nil;
    EXPECT(rig, UIWait(10, ^BOOL { return (code = UIWaitingJoin(there, list, @"approved")[@"code"]) != nil; }),
           "it shows a code");
    EXPECT(rig, UIWait(15, ^BOOL { return UIVisible(page.codeField); }), "the page asks for the code:\n%@",
           UIDescribe(page));
    UIShot(rig, @"code");
    if (!UIFill(rig, page.codeField, [code stringByReplacingOccurrencesOfString:@" " withString:@""], __FILE__,
                __LINE__))
        return NO;
    CLICK(rig, page.codeButton, @"Join");

    // Checking may pass too quickly to see; once joined the route must show, whichever session carries it.
    __block BOOL routeWhileChecking = NO;
    EXPECT(rig, UIWait(40, ^BOOL {
               [page layoutSubtreeIfNeeded];
               BOOL joined = [page.titleLabel.stringValue isEqualToString:@"This computer now uses your profile"];
               if (!joined && UIJoinRouteShown(page)) routeWhileChecking = YES;
               return joined && UIJoinRouteShown(page);
           }), "joined, the page names the route it joined over:\n%@", UIDescribe(page));
    EXPECT(rig, [page.routeLabel.stringValue isEqualToString:@"Nearby, on your network"],
           "two computers on one network join nearby: %@", page.routeLabel.stringValue);
    printf("    route shown while checking: %s\n", routeWhileChecking ? "yes" : "no (it passed too quickly)");
    UIShot(rig, @"joined");
    [there intent:@"unsubscribe" fields:@{@"subscription" : profile}];
    [there intent:@"unsubscribe" fields:@{@"subscription" : list}];
    [there close];
    [other terminate];
    return YES;
}
