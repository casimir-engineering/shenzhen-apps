// Shenzhen Friends views tests: one profile on several computers (PROTOCOL.md § Devices, § Joining). Your computers
// renames and removes through the helper's actions; the list shows the join rows, the removed notice and You; the
// join page sends what the person typed; a file on another computer offers Get; deleting history says it reaches
// every computer; and each view reads whole in light and dark from 320 to 400 pt.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"
#import "mac/SZFriendsDevices.h"
#import "mac/SZFriendsItemViewsInternal.h"
#import "mac/SZFriendsSettingsSection.h"

static NSDictionary *SZFLast(SZFTestTransport *transport, NSString *type) {
    for (NSDictionary *frame in transport.sent.reverseObjectEnumerator)
        if ([frame[@"type"] isEqualToString:type]) return frame;
    return nil;
}

static void SZFReply(SZFTestTransport *transport, NSDictionary *intent, NSDictionary *_Nullable error) {
    NSMutableDictionary *reply = [@{@"type" : @"reply", @"re" : intent[@"id"] ?: @"", @"ok" : @(error == nil)}
        mutableCopy];
    if (error) reply[@"error"] = @{@"code" : error[@"code"], @"message" : error[@"message"], @"retryable" : @NO,
                                   @"details" : @{}};
    else reply[@"result"] = @{};
    [transport deliver:reply];
}

static BOOL SZFVisible(NSView *view, NSView *root) {
    for (NSView *ancestor = view; ancestor && ancestor != root.superview; ancestor = ancestor.superview)
        if (ancestor.hidden) return NO;
    return YES;
}

// Nothing the person needs is cut: every visible label is as tall as its text needs at its width and inside the
// page's width, and every visible button is as wide as its title.
static void SZFExpectWhole(NSView *root, NSString *name) {
    NSRect bounds = root.bounds;
    for (NSTextField *label in SZFTestSubviews(root, NSTextField.class)) {
        if (!SZFVisible(label, root) || label.editable || !label.stringValue.length) continue;
        NSRect frame = [label convertRect:label.bounds toView:root];
        SZFExpect(NSHeight(label.frame) + 0.5 >= SZFriendsFieldHeight(label, NSWidth(label.frame)),
                  @"%@: \"%@\" is cut (%@)", name, label.stringValue, NSStringFromRect(label.frame));
        SZFExpect(NSMinX(frame) >= -0.5 && NSMaxX(frame) <= NSWidth(bounds) + 0.5, @"%@: \"%@\" leaves the page",
                  name, label.stringValue);
    }
    for (SZFriendsButton *button in SZFTestSubviews(root, SZFriendsButton.class)) {
        if (!SZFVisible(button, root) || !button.title.length || button.style == SZFriendsButtonStylePlain) continue;
        SZFExpect([button fittingWidth] <= NSWidth(button.frame) + 0.5, @"%@: button \"%@\" is cut (%.0f < %.0f)", name,
                  button.title, NSWidth(button.frame), [button fittingWidth]);
    }
}

// The confirmations a context asked for; each is confirmed at once unless `holds` is set.
@interface SZFConfirmations : NSObject
@property(nonatomic, copy, nullable) NSDictionary *last;
@property(nonatomic) BOOL holds;
@end
@implementation SZFConfirmations
@end

static SZFriendsContext *SZFContext(SZFTestTransport **transport, SZFConfirmations *_Nullable confirmations) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(transport));
    if (confirmations) context.presentConfirmation = ^(NSDictionary *confirm, void (^onConfirm)(BOOL)) {
        confirmations.last = confirm;
        if (!confirmations.holds) onConfirm(NO);
    };
    return context;
}

static void SZFTestYourComputers(void) {
    SZFTestTransport *transport = nil;
    SZFConfirmations *confirmations = [SZFConfirmations new];
    SZFriendsContext *context = SZFContext(&transport, confirmations);
    SZFriendsProfilePage *page = [[SZFriendsProfilePage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:SZFTestSnapshot(@"profile-unreserved")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.computersView.hidden && NSHeight(page.computersView.frame) == 0, @"no computers without devices");
    [page applySnapshot:SZFTestSnapshot(@"devices-profile")];
    [page layoutSubtreeIfNeeded];
    SZFriendsYourComputersView *computers = page.computersView;
    SZFExpect(!computers.hidden && computers.nameLabels.count == 4, @"one row per computer");
    SZFExpect([computers.nameLabels[0].stringValue isEqualToString:@"Raph’s MacBook Pro"] &&
                  [computers.detailLabels[0].stringValue isEqualToString:@"macOS 26.1 · This computer"],
              @"this computer first, its system and that it is this one: %@", computers.detailLabels[0].stringValue);
    SZFExpect([computers.detailLabels[3].stringValue hasSuffix:@"Not connected to this computer yet"],
              @"never reached");
    NSString *spoken = computers.nameLabels[1].accessibilityLabel;
    SZFExpect([spoken isEqualToString:@"Raph’s Mac mini, macOS 15.7, connected now"], @"a row reads aloud: %@", spoken);
    SZFExpect(computers.removeButtons.count == 3, @"Remove on the other computers only");
    SZFExpect([computers.removeButtons[0].accessibilityLabel isEqualToString:@"Remove…, Raph’s Mac mini"],
              @"Remove names its computer: %@", computers.removeButtons[0].accessibilityLabel);

    // Remove asks first with the helper's words, then sends the row's own id.
    [computers.removeButtons[1] performClick:nil];
    SZFExpect([confirmations.last[@"title"] isEqualToString:@"Remove Studio workstation?"] &&
                  [confirmations.last[@"body"] containsString:@"stops getting your messages and files"],
              @"the confirmation says what happens: %@", confirmations.last);
    NSDictionary *revoke = SZFLast(transport, @"revoke_device");
    SZFExpect([revoke[@"fields"] isEqual:@{@"device_id" : @"d_93f2d618"}], @"revoke_device: %@", revoke);
    confirmations.last = nil;
    confirmations.holds = YES;
    NSUInteger sent = transport.sent.count;
    [computers.removeButtons[2] performClick:nil];
    SZFExpect(confirmations.last && transport.sent.count == sent, @"nothing is removed until the confirm button");

    // Rename: this computer's row only, the field starts from its name, what is too long is never typed.
    SZFExpect(!computers.renameButton.hidden && [computers.renameButton.title isEqualToString:@"Rename"], @"Rename");
    [computers.renameButton performClick:nil];
    [page layoutSubtreeIfNeeded];
    SZFExpect(computers.renaming && !computers.renameField.hidden &&
                  [computers.renameField.stringValue isEqualToString:@"Raph’s MacBook Pro"],
              @"the field opens on the name");
    computers.renameField.stringValue = [@"" stringByPaddingToLength:70 withString:@"é" startingAtIndex:0];
    [NSNotificationCenter.defaultCenter postNotificationName:NSControlTextDidChangeNotification
                                                      object:computers.renameField];
    SZFExpect([computers.renameField.stringValue lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == 64,
              @"at most 64 bytes of UTF-8: %lu",
              (unsigned long)[computers.renameField.stringValue lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    computers.renameField.stringValue = @"Studio MacBook";
    [computers.saveButton performClick:nil];
    NSDictionary *rename = SZFLast(transport, @"rename_device");
    SZFExpect([rename[@"fields"] isEqual:@{@"name" : @"Studio MacBook"}], @"rename_device: %@", rename);
    SZFReply(transport, rename, @{@"code" : @"name_invalid", @"message" : @"Type a name for this computer."});
    [page layoutSubtreeIfNeeded];
    SZFExpect(computers.renaming && !computers.renameError.hidden &&
                  [computers.renameError.stringValue isEqualToString:@"Type a name for this computer."],
              @"a refused name says why and stays open");
    [computers.saveButton performClick:nil];
    SZFReply(transport, SZFLast(transport, @"rename_device"), nil);
    SZFExpect(!computers.renaming, @"a saved name closes the field");
    [computers beginRenaming];
    SZFExpect([page dismissInnermostPicker] && !computers.renaming, @"Escape closes the field first");
    for (NSView *target in computers.removeButtons)
        SZFExpect(SZFTestMissedHits(target, page) == 0, @"%@ is one contiguous hit target", target);
    (void)window;
}

static void SZFTestJoinRows(void) {
    SZFTestTransport *transport = nil;
    SZFConfirmations *confirmations = [SZFConfirmations new];
    SZFriendsContext *context = SZFContext(&transport, confirmations);
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    (void)window;
    [page applySnapshot:SZFTestSnapshot(@"list")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.devicesView.hidden && page.joinButton == nil, @"nothing for computers without devices");
    [page applySnapshot:SZFTestSnapshot(@"list-join-requests")];
    [page layoutSubtreeIfNeeded];
    NSArray<SZFriendsJoinRequestView *> *requests = page.devicesView.requestViews;
    SZFExpect(!page.devicesView.hidden && requests.count == 2, @"one card per request");
    SZFExpect(NSMaxY([page.devicesView convertRect:page.devicesView.bounds toView:page]) <=
                  NSMinY([page.scrollView convertRect:page.scrollView.bounds toView:page]) + 0.5,
              @"the requests sit above the rows");
    SZFriendsJoinRequestView *approved = requests[0], *waiting = requests[1];
    SZFExpect([approved.codeLabel.stringValue isEqualToString:@"4831 2207"] && !approved.codeLabel.hidden &&
                  approved.codeLabel.selectable &&
                  [approved.codeLabel.accessibilityLabel isEqualToString:@"4 8 3 1, 2 2 0 7"],
              @"the code large, selectable and read digit by digit");
    SZFExpect(approved.codeLabel.font.pointSize >= 24, @"the code is drawn large");
    SZFExpect(waiting.codeLabel.hidden && waiting.actionButtons.count == 2, @"a waiting request: Approve and Deny");
    [waiting.actionButtons[0] performClick:nil];
    SZFExpect(!waiting.actionButtons[0].enabled, @"Approve, once pressed, waits for the code");
    [waiting.actionButtons[0] performClick:nil];
    NSUInteger approvals = 0;
    for (NSDictionary *frame in transport.sent) approvals += [frame[@"type"] isEqualToString:@"approve_join"];
    SZFExpect(approvals == 1, @"one approve_join for two clicks: %lu", (unsigned long)approvals);
    NSDictionary *approve = SZFLast(transport, @"approve_join");
    NSString *waitingID = @"5f2d0c4be1a94a7b8d3e6f1a2b3c4d5e", *approvedID = @"0a1b2c3d4e5f60718293a4b5c6d7e8f9";
    SZFExpect([approve[@"fields"] isEqual:@{@"join_id" : waitingID}], @"approve: %@", approve);
    SZFTestClickAfter(clock, waiting.actionButtons[1], 1, 1);
    SZFExpect(SZFLast(transport, @"deny_join") == nil && [waiting.actionButtons[1].title isEqualToString:@"Deny?"],
              @"Deny asks for a second click: %@", waiting.actionButtons[1].title);
    SZFExpect([page dismissInnermostPicker] && [waiting.actionButtons[1].title isEqualToString:@"Deny"],
              @"Escape turns Deny? back first");
    SZFTestClickAfter(clock, waiting.actionButtons[1], 1, 1);
    SZFTestClickAfter(clock, waiting.actionButtons[1], 1, 1);
    SZFExpect([SZFLast(transport, @"deny_join")[@"fields"][@"join_id"] isEqualToString:waitingID],
              @"the second click denies");
    [approved.actionButtons[0] performClick:nil];
    SZFExpect([SZFLast(transport, @"deny_join")[@"fields"][@"join_id"] isEqualToString:approvedID],
              @"Cancel withdraws the code");

    // This computer removed: the notice with Start Over, no Add, no Nearby, rows still there for reading.
    [page applySnapshot:SZFTestSnapshot(@"devices-list-removed")];
    [page layoutSubtreeIfNeeded];
    SZFriendsNoticeView *removed = page.devicesView.removedNotice;
    SZFExpect(page.devicesView.removed && !removed.hidden &&
                  [removed.titleLabel.stringValue isEqualToString:@"This computer was removed from your profile"],
              @"the removed notice");
    SZFExpect(page.nearbyTab.superview.hidden && page.footer.addButton.hidden && page.rows.count > 0,
              @"no Nearby, no Add, rows readable");
    page.rows[0].dimmed = page.rows[0].hovered = YES; // as while files wait for a row
    SZFExpect([[page.rows[0] refusalText] isEqualToString:@"This computer can’t send anymore"] &&
                  !page.rows[0].dropLabel,
              @"rows refuse drops with the helper's words");
    [removed.button performClick:nil];
    NSDictionary *reset = SZFLast(transport, @"reset_friends");
    SZFExpect([confirmations.last[@"title"] isEqualToString:@"Start over on this computer?"] &&
                  [reset[@"fields"] isEqual:@{@"confirm" : @"reset"}],
              @"Start Over asks first, then resets: %@", reset);
    [page applySnapshot:SZFTestSnapshot(@"devices-list")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(!page.nearbyTab.superview.hidden && !page.footer.addButton.hidden && page.devicesView.hidden,
              @"a normal list again");
    SZFExpect([page.rows[0].conversationID isEqualToString:@"you"] &&
                  [page.rows[0].dropLabel isEqualToString:@"Send to all your computers"],
              @"You first, taking files for every computer");
}

static void SZFTestJoinPage(void) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:[SZFTestHost new] link:link presenter:[SZFTestPresenter new]];
    [controller install];
    [controller toggle];
    SZFriendsListPage *list = controller.content.listPage;
    [list applySnapshot:SZFTestSnapshot(@"devices-list-new-computer")];
    SZFExpect([list.joinButton.title isEqualToString:@"Use my existing profile"], @"the name prompt offers joining");
    [list.joinButton performClick:nil];
    SZFExpect(controller.currentView == SZFriendsDropdownViewJoin, @"it opens the join page");
    NSDictionary *subscribe = SZFLast(transport, @"subscribe");
    SZFExpect([subscribe[@"fields"][@"view"] isEqualToString:@"join"], @"the page subscribes to join: %@", subscribe);
    SZFriendsJoinPage *page = (SZFriendsJoinPage *)controller.content.topPage;
    [page applySnapshot:SZFTestSnapshot(@"join-idle")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(!page.idField.hidden && page.codeField.hidden && [page.idButton.title isEqualToString:@"Continue"],
              @"idle: the ID field");
    page.idField.stringValue = @" cottage-violet ";
    [page.idButton performClick:nil];
    NSDictionary *join = SZFLast(transport, @"join_profile");
    SZFExpect([join[@"fields"] isEqual:@{@"friends_id" : @"cottage-violet"}], @"join_profile: %@", join);
    SZFReply(transport, join, @{@"code" : @"id_is_yours", @"message" : @"That’s this computer’s own ID."});
    SZFExpect([page.errorLabel.stringValue isEqualToString:@"That’s this computer’s own ID."] && page.idButton.enabled,
              @"a refused ID says why");
    [page applySnapshot:SZFTestSnapshot(@"join-wrong-code")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.idField.hidden && !page.codeField.hidden && page.codeField.enabled, @"the code field");
    SZFExpect([page.errorLabel.stringValue hasPrefix:@"That code didn’t match"], @"why the code failed");
    page.codeField.stringValue = @"4831 2207";
    [page submitCode];
    SZFExpect([SZFLast(transport, @"enter_join_code")[@"fields"] isEqual:@{@"code" : @"4831 2207"}], @"the code sent");
    NSMutableDictionary *checking = [SZFTestSnapshot(@"join-wrong-code") mutableCopy];
    NSMutableDictionary *field = [checking[@"code_field"] mutableCopy];
    field[@"enabled"] = @NO;
    checking[@"code_field"] = field;
    checking[@"state"] = @"checking";
    checking[@"error"] = NSNull.null;
    [page applySnapshot:checking];
    SZFExpect(!page.codeField.enabled && !page.codeButton.enabled, @"no second code while one is checked");
    SZFExpect(page.actionButtons.count == 1 && [page.actionButtons[0].title isEqualToString:@"Cancel"], @"Cancel");
    [page.actionButtons[0] performClick:nil];
    SZFExpect(SZFLast(transport, @"cancel_join") != nil, @"Cancel stops asking");
    [page applySnapshot:SZFTestSnapshot(@"join-denied")];
    [page.actionButtons[0] performClick:nil];
    SZFExpect([SZFLast(transport, @"join_profile")[@"fields"] isEqual:@{@"friends_id" : @"cottage-violet"}],
              @"Start again asks the same ID");
    [page applySnapshot:SZFTestSnapshot(@"join-joined")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.idField.hidden && page.codeField.hidden && page.actionButtons.count == 0 &&
                  [page.titleLabel.stringValue isEqualToString:@"This computer now uses your profile"],
              @"joined: just what happened");
    [controller uninstall];
}

static void SZFTestOtherComputersFiles(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFContext(&transport, NULL);
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context conversationID:@"c_mei"
                                                                       highlightMessage:nil];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    (void)window;
    [page applySnapshot:SZFTestSnapshot(@"devices-conversation-mei-files")];
    [page layoutSubtreeIfNeeded];
    SZFriendsItemView *onDevice = nil, *fetching = nil;
    for (SZFriendsItemView *item in page.itemViews) {
        NSString *state = SZFStr(item.item, @"state");
        if ([state isEqualToString:@"on_device"]) onDevice = item;
        if ([state isEqualToString:@"fetching"] && !fetching) fetching = item;
    }
    SZFExpect(onDevice.actionButtons.count == 1 && [onDevice.actionButtons[0].title isEqualToString:@"Get"],
              @"a file on another computer offers Get");
    NSArray *labels = [SZFTestSubviews(onDevice, NSTextField.class) valueForKey:@"stringValue"];
    SZFExpect([labels containsObject:@"On Raph’s Mac mini"], @"it says where the file is: %@", labels);
    [onDevice.actionButtons[0] performClick:nil];
    NSDictionary *fetch = SZFLast(transport, @"fetch_from_device");
    SZFExpect([fetch[@"fields"] isEqual:@{@"transfer_id" : SZFStr(onDevice.item, @"transfer_id")}], @"Get: %@", fetch);
    SZFExpect(fetching.progressView != nil && fetching.actionButtons.count == 1, @"copying shows progress and Cancel");
    [fetching.actionButtons[0] performClick:nil];
    SZFExpect([SZFLast(transport, @"cancel_transfer")[@"fields"][@"transfer_id"]
                  isEqualToString:SZFStr(fetching.item, @"transfer_id")],
              @"Cancel stops the copy");

    // You: the person's own conversation, nothing to open behind its title.
    SZFriendsConversationPage *you = [[SZFriendsConversationPage alloc] initWithContext:context conversationID:@"you"
                                                                      highlightMessage:nil];
    NSWindow *youWindow = SZFTestHostWindow(you, NSMakeSize(400, 640), NSAppearanceNameAqua);
    (void)youWindow;
    [you applySnapshot:SZFTestSnapshot(@"devices-conversation-you")];
    [you layoutSubtreeIfNeeded];
    SZFExpect([you.header.titleButton.title isEqualToString:@"You"] && !you.composer.hidden &&
                  [you.composer.textView.accessibilityLabel isEqualToString:@"Message yourself"],
              @"You: its title and composer");
}

static void SZFTestHistoryOnEveryComputer(void) {
    SZFTestTransport *transport = nil;
    SZFConfirmations *confirmations = [SZFConfirmations new];
    SZFriendsContext *context = SZFContext(&transport, confirmations);
    SZFriendsDetailsPage *details = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
    NSWindow *window = SZFTestHostWindow(details, NSMakeSize(400, 640), NSAppearanceNameAqua);
    (void)window;
    [details applySnapshot:SZFTestSnapshot(@"devices-details-mei")];
    [details layoutSubtreeIfNeeded];
    NSArray *labels = [SZFTestSubviews(details, NSTextField.class) valueForKey:@"stringValue"];
    SZFExpect([labels containsObject:@"Clears this chat on all your computers. Mei stays your friend."],
              @"the note says every computer");
    [details.actionButtons[0] performClick:nil];
    SZFExpect([confirmations.last[@"body"] containsString:@"and from your other computers as soon as they connect"] &&
                  [SZFLast(transport, @"delete_history")[@"fields"] isEqual:@{@"conversation_id" : @"c_mei"}],
              @"the confirmation says every computer, then deletes: %@", confirmations.last[@"body"]);
    NSDictionary *history = SZFTestSnapshot(@"devices-settings")[@"history"];
    NSAlert *alert = [SZFriendsSettingsSection alertForConfirm:history[@"confirm"]];
    SZFExpect([alert.informativeText containsString:@"from your other computers as soon as they connect"],
              @"Settings' Delete history says every computer: %@", alert.informativeText);
}

// Each devices view in light and dark at the narrowest and widest dropdown: drawn, and nothing key cut.
static void SZFTestDevicesRenders(void) {
    NSArray *builders = @[
        @[ @"devices-profile", ^NSView *(SZFriendsContext *context) {
              SZFriendsProfilePage *page = [[SZFriendsProfilePage alloc] initWithContext:context];
              [page applySnapshot:SZFTestSnapshot(@"devices-profile")];
              return page;
          } ],
        @[ @"devices-join-rows", ^NSView *(SZFriendsContext *context) {
              SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
              [page applySnapshot:SZFTestSnapshot(@"list-join-requests")];
              return page;
          } ],
        @[ @"devices-removed", ^NSView *(SZFriendsContext *context) {
              SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
              [page applySnapshot:SZFTestSnapshot(@"devices-list-removed")];
              return page;
          } ],
        @[ @"devices-join-code", ^NSView *(SZFriendsContext *context) {
              SZFriendsJoinPage *page = [[SZFriendsJoinPage alloc] initWithContext:context];
              [page applySnapshot:SZFTestSnapshot(@"join-wrong-code")];
              return page;
          } ],
        @[ @"devices-join-denied", ^NSView *(SZFriendsContext *context) {
              SZFriendsJoinPage *page = [[SZFriendsJoinPage alloc] initWithContext:context];
              [page applySnapshot:SZFTestSnapshot(@"join-denied")];
              return page;
          } ],
    ];
    for (NSArray *entry in builders) {
        for (NSNumber *width in @[ @320, @400 ]) {
            for (NSAppearanceName appearance in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
                SZFTestTransport *transport = nil;
                SZFriendsContext *context = SZFContext(&transport, NULL);
                NSView *(^build)(SZFriendsContext *) = entry[1];
                NSView *view = build(context);
                NSWindow *window = SZFTestHostWindow(view, NSMakeSize(width.doubleValue, 640), appearance);
                [window.contentView layoutSubtreeIfNeeded];
                BOOL dark = [appearance isEqualToString:NSAppearanceNameDarkAqua];
                NSString *name = [NSString stringWithFormat:@"%@-%@-%@", entry[0], width, dark ? @"dark" : @"light"];
                SZFExpectWhole(view, name);
                NSString *path = SZFTestRender(window.contentView, name, 2);
                NSBitmapImageRep *rep = path ? (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path]
                                             : nil;
                NSMutableSet *colours = [NSMutableSet set];
                for (NSInteger y = 0; y < rep.pixelsHigh; y += 7)
                    for (NSInteger x = 0; x < rep.pixelsWide; x += 7)
                        [colours addObject:@(SZFTestBitmapPixel(rep, x, y))];
                SZFExpect(colours.count > 8, @"%@ is drawn (%lu colours)", name, (unsigned long)colours.count);
            }
        }
    }
}

void SZFTestDevices(void) {
    SZFTestYourComputers();
    SZFTestJoinRows();
    SZFTestJoinPage();
    SZFTestOtherComputersFiles();
    SZFTestHistoryOnEveryComputer();
    SZFTestDevicesRenders();
}
