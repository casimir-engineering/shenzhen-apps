// Shenzhen Friends views tests: every golden fixture builds its view, and every visible control is one full-bounds
// hit target at 1x and 2x.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsItemViewsInternal.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"

static NSString *SZFTitle(NSView *view) {
    return [view isKindOfClass:NSButton.class] ? ((NSButton *)view).title : @"";
}

static NSArray<NSString *> *SZFButtonTitles(NSView *root) {
    NSMutableArray *titles = [NSMutableArray array];
    for (NSView *view in SZFTestHitTargets(root))
        if (SZFTitle(view).length) [titles addObject:SZFTitle(view)];
    return titles;
}

static BOOL SZFHasLabel(NSView *root, NSString *text) {
    // A snapshot marks views as needing layout; the window's next pass would lay them out on screen.
    [root.window.contentView layoutSubtreeIfNeeded];
    for (NSTextField *field in SZFTestSubviews(root, NSTextField.class))
        if (!field.hidden && [field.stringValue isEqualToString:text]) return YES;
    return NO;
}

static SZFriendsContext *SZFFixtureContext(void) {
    return SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
}

static void SZFTestListFixtures(void) {
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:SZFFixtureContext()];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    [page applySnapshot:SZFTestSnapshot(@"list")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.rows.count == 7, @"seven rows, got %lu", (unsigned long)page.rows.count);
    SZFExpect(page.rows[0].dropLabel == nil, @"a pending request refuses drops");
    SZFExpect([page.rows[1].dropLabel isEqualToString:@"Send to Mei"], @"Mei's drop label");
    SZFExpect([page.rows[1].accessibilityLabel hasPrefix:@"Mei Lin, unread"], @"row accessibility label from snapshot");
    SZFExpect([page.footer.nameButton.title isEqualToString:@"Raph"], @"footer name");
    SZFExpect([page.footer.addButton.title isEqualToString:@"Add by ID"], @"Add by ID");
    // Wording comes from the fixture: the helper owns it (U+2011 keeps an ID on one line), the view only shows it.
    SZFExpect(SZFHasLabel(page.footer, SZFTestSnapshot(@"list")[@"footer"][@"id_label"]), @"footer ID line");
    SZFExpect(SZFTestSnapshot(@"list")[@"footer"][@"id_note"] == [NSNull null] &&
                  !SZFHasLabel(page.footer, @"already taken"),
              @"no note about the ID under it");
    SZFExpect([page.searchField.placeholderString isEqualToString:@"Search names and IDs"], @"search placeholder");
    SZFExpect([page.friendsTab.title isEqualToString:@"Friends"] && [page.nearbyTab.title isEqualToString:@"Nearby"],
              @"tabs from welcome strings");
    SZFExpect(page.namePromptField == nil && page.bannerButton == nil, @"no prompt or banner in list.json");

    [page applySnapshot:SZFTestSnapshot(@"list-id-changed")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.rows.count == 0, @"no rows");
    SZFExpect([page.bannerButton.title isEqualToString:@"OK"], @"ID-changed banner with its dismiss action");
    SZFExpect(SZFHasLabel(page, SZFTestSnapshot(@"list-id-changed")[@"banner"][@"text"]), @"banner text");
    SZFExpect([page.namePromptField.placeholderString isEqualToString:@"Your name"], @"name prompt field");
    SZFExpect(SZFHasLabel(page, @"No friends yet"), @"empty state");
    SZFExpect([page.footer.nameButton.title isEqualToString:@"Choose your name"], @"name placeholder until chosen");

    [page showNearby:YES];
    [page applyNearbySnapshot:SZFTestSnapshot(@"nearby-visible-bluetooth-off")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.kind == SZFriendsDropdownViewNearby, @"Nearby tab");
    SZFExpect(page.nearbyPane.personRows.count == 4, @"four people");
    SZFExpect([page.nearbyPane.personRows[1].accessoryButton.title isEqualToString:@"Request"], @"Request action");
    SZFExpect(page.nearbyPane.personRows[0].accessoryButton == nil, @"a friend has no Request");
    SZFExpect([page.nearbyPane.visibilityButton.title isEqualToString:@"Stop"], @"Stop while visible");
    SZFExpect(SZFHasLabel(page.nearbyPane, @"4:12"), @"countdown");
    SZFExpect(SZFHasLabel(page.nearbyPane, @"Bluetooth is off. People nearby without Wi-Fi won’t appear."),
            @"quiet note");
    [page applyNearbySnapshot:SZFTestSnapshot(@"nearby-local-network-denied")];
    [page layoutSubtreeIfNeeded];
    SZFExpect([page.nearbyPane.visibilityButton.title isEqualToString:@"Make myself visible for 5 minutes"],
              @"hidden: the visibility action");
    SZFExpect(SZFHasLabel(page.nearbyPane, SZFTestSnapshot(@"nearby-local-network-denied")[@"alert"][@"title"]),
              @"alert card");
    SZFExpect([SZFButtonTitles(page.nearbyPane) containsObject:@"Open Privacy Settings"], @"alert action");
    SZFExpect(page.nearbyPane.personRows.count == 1, @"Kenji over Bluetooth");
    (void)window;
}

static void SZFTestConversationFixtures(void) {
    SZFriendsContext *context = SZFFixtureContext();
    SZFriendsConversationPage *mei = [[SZFriendsConversationPage alloc] initWithContext:context conversationID:@"c_mei"
                                                                       highlightMessage:nil];
    NSWindow *window = SZFTestHostWindow(mei, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    [mei applySnapshot:SZFTestSnapshot(@"conversation-mei")];
    SZFExpect(mei.itemViews.count == 6, @"six items, got %lu", (unsigned long)mei.itemViews.count);
    SZFExpect([mei.header.titleButton.title isEqualToString:@"Mei Lin"] && mei.header.titleButton.enabled,
              @"header name opens details");
    SZFExpect([mei.header.backButton.badgeLabel isEqualToString:@"2"], @"back arrow carries the waiting count");
    SZFExpect([mei.header.backButton.accessibilityLabel isEqualToString:@"Back to Friends, 2 waiting"], @"back label");
    SZFExpect(mei.itemViews[4].progressView != nil, @"receiving transfer shows progress");
    SZFExpect([SZFTitle(mei.itemViews[4].actionButtons.firstObject) isEqualToString:@"Cancel"],
            @"Cancel on a transfer");
    SZFExpect(!mei.composer.hidden && [mei.composer.sendButton.title isEqualToString:@"Send"], @"composer");
    SZFExpect([mei.searchField.placeholderString isEqualToString:@"Search this conversation"], @"conversation search");
    SZFExpect([mei.itemViews[0].itemKind isEqualToString:@"day"], @"oldest first, day separator on top");
    SZFExpect(NSMinY(mei.itemViews[5].frame) > NSMinY(mei.itemViews[1].frame), @"messages run oldest to newest");

    SZFriendsConversationPage *kenji = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                           conversationID:@"c_kenji"
                                                                         highlightMessage:nil];
    NSWindow *kenjiWindow = SZFTestHostWindow(kenji, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [kenji applySnapshot:SZFTestSnapshot(@"conversation-kenji-offer")];
    NSArray *offerTitles = [kenji.itemViews.lastObject.actionButtons valueForKey:@"title"];
    SZFExpect(([offerTitles isEqualToArray:@[ @"Accept", @"Decline" ]]), @"offer actions: %@", offerTitles);
    SZFExpect(SZFHasLabel(kenji, @"Over Bluetooth, about 6 min"), @"route note on a slow offer");

    SZFriendsConversationPage *priya = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                           conversationID:@"c_priya"
                                                                         highlightMessage:nil];
    NSWindow *priyaWindow = SZFTestHostWindow(priya, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    [priya applySnapshot:SZFTestSnapshot(@"conversation-priya-queued")];
    SZFExpect(SZFHasLabel(priya.composer, @"Messages and files send when Priya is nearby with ShenzhenPDF, "
                                          @"Shenzhen Files or Shenzhen 3D open."),
              @"composer note says when queued messages go");
    SZFExpect(SZFHasLabel(priya, @"Sends when Priya is nearby"), @"queued status written for the reader");
    // The message Priya never got (cancelled) fades; the others, queued or failed, show at full strength.
    for (SZFriendsItemView *view in priya.itemViews) {
        if (![view isKindOfClass:SZFriendsMessageItemView.class]) continue;
        SZFriendsMessageItemView *message = (SZFriendsMessageItemView *)view;
        BOOL cancelled = [message.itemID isEqualToString:@"m_7a3e5b21"];
        SZFExpect(fabs(message.bubble.alphaValue - (cancelled ? SZFriendsCancelledBubbleAlpha : 1)) < 0.01,
                  @"%@ bubble alpha %.2f", message.itemID, message.bubble.alphaValue);
    }

    SZFriendsConversationPage *lena = [[SZFriendsConversationPage alloc] initWithContext:context
            conversationID:@"c_lena"
                                                                        highlightMessage:nil];
    NSWindow *lenaWindow = SZFTestHostWindow(lena, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    [lena applySnapshot:SZFTestSnapshot(@"conversation-request-lena")];
    SZFExpect(lena.composer.hidden && lena.messageList.hidden, @"request card replaces history and composer");
    NSArray *requestTitles = [lena.requestCard.actionButtons valueForKey:@"title"];
    SZFExpect(([requestTitles isEqualToArray:@[ @"Accept", @"Decline", @"Block Lena" ]]), @"request actions %@",
              requestTitles);
    SZFExpect(!lena.header.titleButton.enabled, @"no details for a pending request");
    BOOL code = NO;
    for (NSTextField *field in SZFTestSubviews(lena.requestCard, NSTextField.class))
        code = code || [field.stringValue isEqualToString:@"418 270"];
    SZFExpect(code, @"comparison code shown");
    (void)window, (void)kenjiWindow, (void)priyaWindow, (void)lenaWindow;
}

static void SZFTestOtherFixtures(void) {
    SZFriendsContext *context = SZFFixtureContext();
    SZFriendsDetailsPage *details = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
    NSWindow *window = SZFTestHostWindow(details, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    [details applySnapshot:SZFTestSnapshot(@"details-mei")];
    [details layoutSubtreeIfNeeded];
    SZFExpect(details.autoAcceptSwitch.state == NSControlStateValueOn && details.autoAcceptSwitch.enabled,
              @"automatic acceptance on and available");
    SZFExpect(([[details.actionButtons valueForKey:@"title"]
                  isEqualToArray:@[ @"Delete chat history…", @"Remove friend", @"Block Mei" ]]),
              @"Delete chat history, Remove and Block");
    SZFExpect(SZFHasLabel(details, @"Clears this chat on this computer. Mei stays your friend."),
              @"what deleting the chat's history does, under its button");
    SZFExpect(SZFHasLabel(details, @"Verified: you compared codes on 3 Oct"), @"verified state");
    SZFExpect([SZFButtonTitles(details) containsObject:@"Show in Finder"], @"received files: Show in Finder");
    SZFExpect([details.cpyButton.accessibilityLabel isEqualToString:@"Copy Mei’s ID"], @"copy ID label");

    SZFriendsProfilePage *profile = [[SZFriendsProfilePage alloc] initWithContext:context];
    NSWindow *profileWindow = SZFTestHostWindow(profile, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    [profile applySnapshot:SZFTestSnapshot(@"profile-unreserved")];
    SZFExpect([profile.nameField.stringValue isEqualToString:@"Raph"], @"profile name");
    id qrLabel = SZFTestSnapshot(@"profile-unreserved")[@"id"][@"qr_label"];
    BOOL qrShown = [qrLabel isKindOfClass:NSString.class];
    SZFExpect([profile.cpyButton.title isEqualToString:@"Copy"] &&
                  (qrShown ? [profile.qrButton.title isEqualToString:qrLabel] && !profile.qrButton.hidden
                           : profile.qrButton.hidden),
              @"Copy, and the QR button only with a QR to show");
    SZFExpect([profile.addButton.title isEqualToString:@"Send request"], @"add by ID button");
    SZFExpect(SZFHasLabel(profile, SZFTestSnapshot(@"profile-unreserved")[@"id"][@"friends_id"]), @"the ID itself");
    [profile toggleAnimals];
    SZFExpect(profile.showingAnimals && profile.animalButtons.count == 24, @"the whole animal set, got %lu",
              (unsigned long)profile.animalButtons.count);
    SZFExpect(profile.animalButtons.firstObject.selectedLook, @"the selected animal is marked");
    SZFExpect([profile.ownPictureButton.title isEqualToString:@"Use your own picture…"], @"own picture");
    SZFExpect([profile dismissInnermostPicker] && !profile.showingAnimals, @"Escape closes the animal grid first");

    SZFriendsSettingsSection *settings = [[SZFriendsSettingsSection alloc] initWithHost:[SZFTestHost new]
                                                                                   link:SZFTestReadyLink(NULL)];
    NSWindow *settingsWindow = SZFTestHostWindow(settings.view, NSMakeSize(560, 520), NSAppearanceNameDarkAqua);
    [settings applySnapshot:SZFTestSnapshot(@"settings")];
    NSArray *titles = [settings.buttons valueForKey:@"title"];
    NSArray *expectedTitles = @[ @"Copy", @"Show in Finder", @"Choose friends…", @"Delete history…", @"Reset Friends…" ];
    SZFExpect([titles isEqualToArray:expectedTitles], @"settings actions: %@", titles);
    SZFExpect([settings.nameField.stringValue isEqualToString:@"Raph"], @"settings name");
    CGFloat collapsed = settings.view.intrinsicContentSize.height;
    [settings.buttons[2] performClick:nil];
    SZFExpect(settings.autoAcceptSwitches.count == 5, @"one switch per friend");
    SZFExpect(settings.autoAcceptSwitches[0].state == NSControlStateValueOn &&
                  settings.autoAcceptSwitches[2].state == NSControlStateValueOff,
              @"switch states from the snapshot");
    SZFExpect(settings.view.intrinsicContentSize.height > collapsed + 100, @"height follows the content");
    // No friends: nothing to choose, so no button, and the switches go.
    NSMutableDictionary *lonely = [SZFTestSnapshot(@"settings") mutableCopy];
    lonely[@"auto_accept"] = @{@"label" : @"Accept files automatically",
                               @"note" : @"Turn it on for a friend in their details.",
                               @"action_label" : @"Choose friends…", @"friends" : @[]};
    [settings applySnapshot:lonely];
    SZFExpect(settings.buttons[2].hidden && settings.autoAcceptSwitches.count == 0, @"no friends, no button");
    [settings applySnapshot:SZFTestSnapshot(@"settings")];
    SZFExpect(!settings.buttons[2].hidden && settings.autoAcceptSwitches.count == 0, @"friends again, closed");

    SZFTestHost *host = [SZFTestHost new];
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:host link:SZFTestReadyLink(NULL)
                                                presenter:[SZFTestPresenter new]];
    [controller install];
    SZFExpect(host.installedButton == controller.button, @"button handed to the host");
    SZFExpect(NSEqualSizes(controller.button.intrinsicContentSize, NSMakeSize(28, 28)), @"28 pt title-bar button");
    [controller uninstall];
    SZFExpect(host.installedButton == nil, @"button removed on uninstall");
    (void)window, (void)profileWindow, (void)settingsWindow;
}

void SZFTestFixtureConstruction(void) {
    SZFTestListFixtures();
    SZFTestConversationFixtures();
    SZFTestOtherFixtures();
    SZFExpect(SZFriendsDropdownHeight(1000, 640) == 640, @"capped at 640");
    SZFExpect(SZFriendsDropdownHeight(500, 640) == 476, @"fits the window");
    SZFExpect(SZFriendsDropdownHeight(120, 640) == 280, @"never collapses");
}

// Every control under `targets`, hit-tested from `root` (the window's content), so a view drawn on top of another
// (the `#` picker over the history, a confirmation over the list) is proven to own its whole frame.
static void SZFExpectFullHitsWithin(NSView *targets, NSView *root, NSString *name) {
    [root layoutSubtreeIfNeeded];
    NSArray *controls = SZFTestHitTargets(targets);
    SZFExpect(controls.count > 0, @"%@ has controls", name);
    for (NSView *target in controls) {
        NSUInteger missed = SZFTestMissedHits(target, root);
        SZFExpect(missed == 0, @"%@: %@ \"%@\" missed %lu hit points", name, target.className, SZFTitle(target),
                  (unsigned long)missed);
    }
}

static void SZFExpectFullHits(NSView *root, NSString *name) {
    SZFExpectFullHitsWithin(root, root, name);
}

void SZFTestHitTesting(void) {
    SZFriendsContext *context = SZFFixtureContext();
    NSArray *cases = @[
        @[ @"list", @"list" ], @[ @"list-id-changed", @"list" ], @[ @"nearby-visible-bluetooth-off", @"nearby" ],
        @[ @"nearby-local-network-denied", @"nearby" ], @[ @"conversation-mei", @"conversation" ],
        @[ @"conversation-kenji-offer", @"conversation" ], @[ @"conversation-priya-queued", @"conversation" ],
        @[ @"conversation-request-lena", @"conversation" ], @[ @"details-mei", @"details" ],
        @[ @"profile-unreserved", @"profile" ]
    ];
    for (NSArray *entry in cases) {
        NSString *fixture = entry[0], *kind = entry[1];
        NSDictionary *data = SZFTestSnapshot(fixture);
        SZFriendsPage *page = nil;
        if ([kind isEqualToString:@"list"] || [kind isEqualToString:@"nearby"]) {
            SZFriendsListPage *list = [[SZFriendsListPage alloc] initWithContext:context];
            page = list;
        } else if ([kind isEqualToString:@"conversation"]) {
            page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                       conversationID:data[@"conversation_id"]
                                                     highlightMessage:nil];
        } else if ([kind isEqualToString:@"details"]) {
            page = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
        } else {
            page = [[SZFriendsProfilePage alloc] initWithContext:context];
        }
        NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
        if ([kind isEqualToString:@"nearby"]) {
            [(SZFriendsListPage *)page showNearby:YES];
            [(SZFriendsListPage *)page applyNearbySnapshot:data];
        } else {
            [page applySnapshot:data];
        }
        if ([kind isEqualToString:@"profile"]) [(SZFriendsProfilePage *)page toggleAnimals];
        SZFExpectFullHits(window.contentView, fixture);
    }
    // The `#` picker over the composer, and the confirmation over the whole dropdown.
    SZFTestHost *pickerHost = [SZFTestHost new];
    SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
    item.title = @"Supplier contract v3.pdf";
    pickerHost.attachableItems = @[ item, item ];
    SZFriendsContext *pickerContext = SZFTestContext(pickerHost, SZFTestReadyLink(NULL));
    SZFriendsConversationPage *picking = [[SZFriendsConversationPage alloc] initWithContext:pickerContext
                                                                             conversationID:@"c_mei"
                                                                           highlightMessage:nil];
    NSWindow *pickerWindow = SZFTestHostWindow(picking, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    [picking applySnapshot:SZFTestSnapshot(@"conversation-mei")];
    [picking openAttachPicker];
    SZFExpect(SZFTestWaitUntil(5, ^BOOL { return picking.attachPicker.itemButtons.count == 2; }), @"picker items");
    SZFExpectFullHitsWithin(picking.attachPicker, pickerWindow.contentView, @"attach picker");
    SZFriendsDropdownContent *confirming = [[SZFriendsDropdownContent alloc] initWithContext:SZFFixtureContext()];
    NSWindow *confirmWindow = SZFTestHostWindow(confirming, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [confirming.listPage applySnapshot:SZFTestSnapshot(@"list")];
    confirming.context.presentConfirmation(SZFTestSnapshot(@"settings")[@"reset"][@"confirm"], ^{});
    SZFExpectFullHitsWithin(confirming.confirmation, confirmWindow.contentView, @"confirmation");

    SZFriendsSettingsSection *settings = [[SZFriendsSettingsSection alloc] initWithHost:[SZFTestHost new]
                                                                                   link:SZFTestReadyLink(NULL)];
    NSWindow *settingsWindow = SZFTestHostWindow(settings.view, NSMakeSize(560, 640), NSAppearanceNameAqua);
    [settings applySnapshot:SZFTestSnapshot(@"settings")];
    [settings.buttons[2] performClick:nil];
    SZFExpectFullHits(settingsWindow.contentView, @"settings");

    // The title button: one 28 pt target with its badge inside, nothing spilling onto the draggable title bar.
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:[SZFTestHost new] link:SZFTestReadyLink(NULL)
                                                presenter:[SZFTestPresenter new]];
    SZFriendsButton *button = (SZFriendsButton *)controller.button;
    button.badgeLabel = @"2";
    NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 120, 40)];
    NSWindow *barWindow = SZFTestHostWindow(bar, NSMakeSize(120, 40), NSAppearanceNameDarkAqua);
    button.frame = NSMakeRect(46, 6, 28, 28);
    [bar addSubview:button];
    SZFExpect(SZFTestMissedHits(button, barWindow.contentView) == 0, @"title button full bounds");
    NSView *outside = [barWindow.contentView hitTest:[bar convertPoint:NSMakePoint(NSMaxX(button.frame) + 1, 20)
                                                                toView:barWindow.contentView.superview]];
    SZFExpect(outside != button, @"space beside the button stays the title bar's");
}
