// Shenzhen Friends views tests: system notifications (PROTOCOL.md § Notifications). The views declare focus and the
// ask; the dropdown tells the helper which conversation it shows while focused, only on change and again after a
// reconnect; the list's notifications card sends Turn On and Not Now; Settings' switches send one field each and its
// permission action opens Shenzhen Friends' own notification settings.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"

// A Ready link whose welcome announces `notifications`, unless `notifications` is NO (a helper from before them).
static SZFriendsHelperLink *SZFNotifyLink(SZFTestTransport **transportOut, BOOL notifications) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    NSMutableDictionary *welcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    if (notifications) welcome[@"capabilities"] = [welcome[@"capabilities"] arrayByAddingObject:@"notifications"];
    [transport deliver:welcome];
    *transportOut = transport;
    return link;
}

// The conversation_id of every set_focus sent so far, "null" for null.
static NSArray<NSString *> *SZFFocusSent(SZFTestTransport *transport) {
    NSMutableArray *sent = [NSMutableArray array];
    for (NSDictionary *frame in transport.sent) {
        if (![frame[@"type"] isEqualToString:@"set_focus"]) continue;
        id value = frame[@"fields"][@"conversation_id"];
        [sent addObject:[value isKindOfClass:NSString.class] ? value : @"null"];
    }
    return sent;
}

static NSDictionary *SZFLastSent(SZFTestTransport *transport, NSString *type) {
    for (NSDictionary *frame in transport.sent.reverseObjectEnumerator)
        if ([frame[@"type"] isEqualToString:type]) return frame;
    return nil;
}

static void SZFTestNotifyCapabilities(void) {
    NSArray *capabilities = [SZFriendsClientTransport capabilitiesForHost:[SZFTestHost new]];
    SZFExpect([capabilities containsObject:@"notifications.focus"] && [capabilities containsObject:@"notifications.ask"],
              @"the views send set_focus and show the ask card: %@", capabilities);
    SZFExpect(![capabilities containsObject:@"background.reachable"], @"a Mac never keeps Friends in the background");
}

static void SZFTestFocus(void) {
    SZFTestTransport *transport = nil;
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:[SZFTestHost new] link:SZFNotifyLink(&transport, YES)
                                                presenter:[SZFTestPresenter new]];
    __block BOOL focused = YES;
    controller.windowFocused = ^BOOL(void) { return focused; };
    [controller install];
    SZFExpect(SZFFocusSent(transport).count == 0, @"nothing while the dropdown is closed: %@", SZFFocusSent(transport));

    [controller showConversation:@"c_mei" highlightMessage:nil];
    SZFExpect([SZFFocusSent(transport) isEqual:@[ @"c_mei" ]], @"open on Mei: %@", SZFFocusSent(transport));
    [controller updateFocus];
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
    SZFExpect(SZFFocusSent(transport).count == 1, @"only on change: %@", SZFFocusSent(transport));

    // The app goes to the background: no window of it is focused.
    focused = NO;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidResignActiveNotification object:NSApp];
    SZFExpect([SZFFocusSent(transport).lastObject isEqualToString:@"null"], @"null when the app is not active: %@",
              SZFFocusSent(transport));
    focused = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
    SZFExpect([SZFFocusSent(transport).lastObject isEqualToString:@"c_mei"], @"back: %@", SZFFocusSent(transport));

    // Another page, another conversation, the list, closing.
    [controller showConversation:@"c_kenji" highlightMessage:nil];
    SZFExpect([SZFFocusSent(transport).lastObject isEqualToString:@"c_kenji"], @"Kenji: %@", SZFFocusSent(transport));
    [controller showList];
    SZFExpect([SZFFocusSent(transport).lastObject isEqualToString:@"null"], @"the list shows no conversation");
    [controller showConversation:@"c_mei" highlightMessage:nil];
    NSUInteger before = SZFFocusSent(transport).count;
    [controller.content openDetails:@"c_mei"];
    SZFExpect(SZFFocusSent(transport).count == before + 1 && [SZFFocusSent(transport).lastObject isEqualToString:@"null"],
              @"a friend's details is not the conversation: %@", SZFFocusSent(transport));
    [controller.content goBack];
    SZFExpect([SZFFocusSent(transport).lastObject isEqualToString:@"c_mei"], @"back on Mei");
    [controller close];
    SZFExpect([SZFFocusSent(transport).lastObject isEqualToString:@"null"], @"closing: %@", SZFFocusSent(transport));
    SZFExpect([[SZFLastSent(transport, @"set_focus")[@"fields"] allKeys] isEqual:@[ @"conversation_id" ]],
              @"null is sent as conversation_id null: %@", SZFLastSent(transport, @"set_focus"));

    // A new connection starts with no focus: open on a conversation, it is told again once Ready.
    [controller showConversation:@"c_mei" highlightMessage:nil];
    before = SZFFocusSent(transport).count;
    [transport setLinkState:SZFriendsLinkStateWaiting];
    [transport setLinkState:SZFriendsLinkStateReady];
    SZFExpect(SZFFocusSent(transport).count == before + 1 && [SZFFocusSent(transport).lastObject isEqualToString:@"c_mei"],
              @"sent again after a reconnect: %@", SZFFocusSent(transport));
    [controller uninstall];
    SZFExpect([SZFFocusSent(transport).lastObject isEqualToString:@"null"], @"Friends turned off here: focus let go");

    // A helper without notifications never hears set_focus (it would answer unknown_intent).
    SZFTestTransport *older = nil;
    SZFriendsDropdownController *quiet =
        [[SZFriendsDropdownController alloc] initWithHost:[SZFTestHost new] link:SZFNotifyLink(&older, NO)
                                                presenter:[SZFTestPresenter new]];
    quiet.windowFocused = ^BOOL(void) { return YES; };
    [quiet install];
    [quiet showConversation:@"c_mei" highlightMessage:nil];
    [quiet close];
    SZFExpect(SZFFocusSent(older).count == 0, @"no set_focus to an older helper: %@", SZFFocusSent(older));
    [quiet uninstall];
}

static void SZFTestAskCard(void) {
    SZFTestTransport *transport = nil;
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:[SZFTestHost new] link:SZFNotifyLink(&transport, YES)
                                                presenter:[SZFTestPresenter new]];
    controller.windowFocused = ^BOOL(void) { return NO; };
    [controller install];
    [controller showList];
    NSWindow *window = SZFTestHostWindow(controller.content, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFriendsListPage *page = controller.content.listPage;
    [page applySnapshot:SZFTestSnapshot(@"views-notifications-list")];
    [controller.content layoutSubtreeIfNeeded];
    SZFExpect([page.bannerButton.title isEqualToString:@"Turn On"], @"Turn On: %@", page.bannerButton.title);
    SZFExpect([page.bannerDismissButton.title isEqualToString:@"Not Now"], @"Not Now: %@",
              page.bannerDismissButton.title);
    SZFExpect(NSWidth(page.bannerDismissButton.frame) > 0 && NSWidth(page.bannerButton.frame) > 0 &&
                  !NSIntersectsRect(page.bannerButton.frame, page.bannerDismissButton.frame),
              @"both buttons laid out apart: %@ %@", NSStringFromRect(page.bannerButton.frame),
              NSStringFromRect(page.bannerDismissButton.frame));
    SZFExpect(SZFTestMissedHits(page.bannerDismissButton, controller.content) == 0, @"Not Now takes its clicks");
    SZFTestRender(controller.content, @"notifications-ask-card-light", 2);

    [page.bannerButton performClick:nil];
    NSDictionary *allow = SZFLastSent(transport, @"allow_notifications");
    SZFExpect(allow && [allow[@"fields"] count] == 0, @"Turn On asks the helper to ask the system: %@", allow);
    [page.bannerDismissButton performClick:nil];
    NSDictionary *dismiss = SZFLastSent(transport, @"dismiss_banner");
    SZFExpect([dismiss[@"fields"] isEqual:@{@"kind" : @"notifications"}], @"Not Now dismisses this card: %@", dismiss);

    // Another banner keeps its one button.
    [page applySnapshot:SZFTestSnapshot(@"list-id-changed")];
    SZFExpect(page.bannerDismissButton == nil && [page.bannerButton.title isEqualToString:@"OK"],
              @"the ID-changed banner has no Not Now");
    [page.bannerButton performClick:nil];
    SZFExpect([SZFLastSent(transport, @"dismiss_banner")[@"fields"] isEqual:@{@"kind" : @"id_changed"}],
              @"its OK still dismisses id_changed");
    [window orderOut:nil];
    [controller uninstall];
}

static void SZFTestNotificationSettings(void) {
    SZFTestTransport *transport = nil;
    SZFriendsSettingsSection *section =
        [[SZFriendsSettingsSection alloc] initWithHost:[SZFTestHost new] link:SZFNotifyLink(&transport, YES)];
    __block NSURL *opened = nil;
    section.context.openURL = ^(NSURL *url) { opened = url; };
    NSWindow *window = SZFTestHostWindow(section.view, NSMakeSize(560, 900), NSAppearanceNameAqua);
    [section applySnapshot:SZFTestSnapshot(@"settings")];
    SZFExpect(section.notificationsButton.hidden, @"a helper without notifications: no row");
    for (NSSwitch *toggle in section.notificationSwitches) SZFExpect(toggle.hidden, @"and no switches");

    [section applySnapshot:SZFTestSnapshot(@"views-notifications-settings")];
    [section.view layoutSubtreeIfNeeded];
    NSArray<NSSwitch *> *switches = section.notificationSwitches;
    SZFExpect(!switches[0].hidden && switches[0].state == NSControlStateValueOn, @"Show notifications, on");
    SZFExpect(!switches[1].hidden && switches[1].state == NSControlStateValueOff, @"Show message text, off");
    SZFExpect(switches[2].hidden, @"no background switch on a Mac");
    SZFExpect([switches[1].accessibilityLabel isEqualToString:@"Show message text"], @"labelled for VoiceOver");
    SZFExpect([section.notificationsButton.title isEqualToString:@"Open System Settings"] &&
                  !section.notificationsButton.hidden,
              @"the permission's action: %@", section.notificationsButton.title);
    SZFExpect(SZFTestMissedHits(switches[1], section.view) == 0, @"the preview switch takes its clicks");
    SZFTestRender(section.view, @"notifications-settings-light", 2);

    [switches[1] performClick:nil];
    NSDictionary *preview = SZFLastSent(transport, @"set_notifications");
    SZFExpect([preview[@"fields"] isEqual:@{@"preview" : @YES}], @"one field per switch: %@", preview);
    [switches[0] performClick:nil];
    SZFExpect([SZFLastSent(transport, @"set_notifications")[@"fields"] isEqual:@{@"enabled" : @NO}],
              @"turning notifications off: %@", SZFLastSent(transport, @"set_notifications"));

    [section.notificationsButton performClick:nil];
    SZFExpect([opened.absoluteString isEqualToString:@"x-apple.systempreferences:com.apple.Notifications-Settings."
                                                     @"extension?id=com.intuition.shenzhenfriends"],
              @"Shenzhen Friends' own notification settings: %@", opened);

    // Not asked yet: Allow sends allow_notifications.
    NSMutableDictionary *data = [SZFTestSnapshot(@"views-notifications-settings") mutableCopy];
    NSMutableDictionary *notifications = [data[@"notifications"] mutableCopy];
    notifications[@"note"] = @"Friends hasn’t asked to show notifications yet.";
    notifications[@"action"] = @{@"action" : @"allow_notifications", @"label" : @"Allow", @"style" : @"secondary"};
    data[@"notifications"] = notifications;
    [section applySnapshot:data];
    [section.notificationsButton performClick:nil];
    SZFExpect(SZFLastSent(transport, @"allow_notifications") != nil, @"Allow asks the helper");
    notifications[@"action"] = NSNull.null;
    notifications[@"note"] = @"";
    data[@"notifications"] = notifications;
    [section applySnapshot:data];
    SZFExpect(section.notificationsButton.hidden, @"allowed: nothing to press");
    [window orderOut:nil];
}

void SZFTestNotifications(void) {
    SZFTestNotifyCapabilities();
    SZFTestFocus();
    SZFTestAskCard();
    SZFTestNotificationSettings();
}
