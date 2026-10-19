// Shenzhen Friends views tests: destructive actions outside the list. An action with `arm` turns into a red pill on
// its first click and acts on a second, separate click (never a double-click's second half) in the request card,
// the key-change card and details; a destructive confirmation draws its button red; Escape turns a pill back first;
// VoiceOver hears arming, Copy and inline errors; a Friends ID the server confirmed carries a check.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsArming.h"
#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"

static NSDictionary *SZFArm(NSString *who) {
    return @{@"label" : @"Block?", @"accessibility_label" : [@"Click again to block " stringByAppendingString:who],
             @"seconds" : @4};
}

// details-mei with Remove (asks first) and Block (armed), as the presentation sends them, whatever the fixture holds.
static NSDictionary *SZFDetailsWithDestructiveActions(void) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"details-mei") mutableCopy];
    data[@"actions"] = @[
        @{@"action" : @"remove_friend", @"label" : @"Remove friend", @"style" : @"destructive",
          @"note" : @"Keeps your conversation.",
          @"confirm" : @{@"title" : @"Remove Mei as a friend?", @"body" : @"Mei isn’t told.",
                         @"confirm_label" : @"Remove Friend", @"cancel_label" : @"Cancel", @"destructive" : @YES}},
        @{@"action" : @"block", @"label" : @"Block Mei", @"style" : @"destructive", @"note" : @"Mei can’t reach you.",
          @"arm" : SZFArm(@"Mei")},
    ];
    data[@"key_change"] = @{@"title" : @"Mei’s key changed", @"body" : @"Compare codes first.",
                            @"actions" : @[ @{@"action" : @"block", @"label" : @"Block Mei", @"style" : @"destructive",
                                              @"arm" : SZFArm(@"Mei")} ]};
    return data;
}

static NSArray<NSString *> *SZFSentTypes(SZFTestTransport *transport) {
    NSMutableArray *types = [NSMutableArray array];
    for (NSDictionary *sent in transport.sent) [types addObject:sent[@"type"]];
    return types;
}

static void SZFTestArmedInDetails(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [content openDetails:@"c_mei"];
    SZFriendsDetailsPage *details = (SZFriendsDetailsPage *)content.topPage;
    [details applySnapshot:SZFDetailsWithDestructiveActions()];
    [content layoutSubtreeIfNeeded];
    NSUInteger before = transport.sent.count;
    SZFriendsActionButton *block = (SZFriendsActionButton *)details.actionButtons.lastObject;
    SZFExpect([block isKindOfClass:SZFriendsActionButton.class] && block.style == SZFriendsButtonStyleDestructive,
              @"Block is drawn destructive");
    CGFloat restingWidth = NSWidth(block.frame);
    SZFTestClickAfter(clock, block, 10, 1);
    [content layoutSubtreeIfNeeded];
    SZFExpect(block.armed && [block.title isEqualToString:@"Block?"] &&
                  [block.accessibilityLabel isEqualToString:@"Click again to block Mei"] &&
                  transport.sent.count == before,
              @"the first click arms and sends nothing: %@ %@", block.title, SZFSentTypes(transport));
    SZFExpect(NSWidth(block.frame) >= restingWidth, @"the pill never shrinks out from under the pointer");
    NSString *armed = [NSString stringWithFormat:@"%@ (high): Click again to block Mei",
                                                 NSAccessibilityAnnouncementRequestedNotification];
    SZFExpect([clock.spoken containsObject:armed], @"arming is announced: %@", clock.spoken);
    SZFTestClickAfter(clock, block, NSEvent.doubleClickInterval / 3, 2);
    SZFExpect(block.armed && transport.sent.count == before, @"a double-click's second half does nothing");
    // A snapshot that changes nothing about Block keeps the pill.
    [details applySnapshot:SZFDetailsWithDestructiveActions()];
    SZFExpect(details.actionButtons.lastObject == block && block.armed, @"an unchanged action keeps its armed button");
    // Escape turns the pill back before anything closes.
    __block NSInteger closes = 0;
    content.onClose = ^{ closes++; };
    [content friendsHandleEscape];
    SZFExpect(!block.armed && closes == 0 && [block.title isEqualToString:@"Block Mei"], @"Escape disarms first");
    // Leaving the button turns the pill back, as leaving a request row does.
    SZFTestClickAfter(clock, block, 10, 1);
    [block mouseExited:[NSEvent enterExitEventWithType:NSEventTypeMouseExited location:NSZeroPoint modifierFlags:0
                                             timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0
                                        trackingNumber:0 userData:NULL]];
    SZFExpect(!block.armed && transport.sent.count == before, @"the pointer leaving disarms, sending nothing");
    SZFTestClickAfter(clock, block, 10, 1);
    SZFTestClickAfter(clock, block, NSEvent.doubleClickInterval + 0.05, 1);
    SZFExpect([SZFSentTypes(transport).lastObject isEqualToString:@"block"] &&
                  [transport.sent.lastObject[@"fields"][@"conversation_id"] isEqualToString:@"c_mei"],
              @"a separate second click blocks: %@", SZFSentTypes(transport));

    // The key-change card's Block arms the same way.
    SZFriendsActionButton *keyBlock = (SZFriendsActionButton *)details.keyChangeButtons.firstObject;
    before = transport.sent.count;
    SZFTestClickAfter(clock, keyBlock, 10, 1);
    SZFExpect(keyBlock.armed && transport.sent.count == before, @"the key-change card's Block arms first");
    // The pill turns back on its timer.
    clock.blocks.lastObject();
    SZFExpect(!keyBlock.armed, @"and turns back after arm.seconds");

    // Remove asks first, in a destructive confirmation; only its confirm button sends.
    SZFriendsButton *remove = details.actionButtons.firstObject;
    before = transport.sent.count;
    SZFTestClickAfter(clock, remove, 10, 1);
    SZFriendsConfirmView *confirm = content.confirmation;
    SZFExpect(confirm && confirm.confirmButton.style == SZFriendsButtonStyleDestructiveBordered &&
                  transport.sent.count == before,
              @"Remove asks with a red confirm button");
    [confirm.confirmButton performClick:nil];
    SZFExpect([SZFSentTypes(transport).lastObject isEqualToString:@"remove_friend"], @"confirming removes: %@",
              SZFSentTypes(transport));
    (void)window;
}

static void SZFTestDestructiveConfirm(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    NSDictionary *question = @{@"title" : @"Delete?", @"body" : @"Gone for good.", @"confirm_label" : @"Delete",
                               @"cancel_label" : @"Cancel"};
    [context performAction:@{@"action" : @"delete_history", @"label" : @"Delete", @"style" : @"secondary",
                             @"confirm" : question}
                       ids:nil done:nil];
    SZFExpect(content.confirmation.confirmButton.style == SZFriendsButtonStylePrimary, @"a plain question stays blue");
    [content friendsHandleEscape];
    [context performAction:@{@"action" : @"delete_history", @"label" : @"Delete", @"style" : @"destructive",
                             @"confirm" : question}
                       ids:nil done:nil];
    SZFExpect(content.confirmation.confirmButton.style == SZFriendsButtonStyleDestructiveBordered,
              @"a destructive action's question is drawn destructive even unmarked");
    uint32_t title = SZFTestResolved(content.confirmation.confirmButton.iconColor, NSAppearanceNameDarkAqua);
    SZFExpect(title == SZFTestResolved(context.appearance.destructiveColor, NSAppearanceNameDarkAqua),
              @"in the destructive colour: %06x", title);
    (void)window;
}

static void SZFTestArmedRequestCard(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-request-lena") mutableCopy];
    NSMutableDictionary *request = [data[@"request"] mutableCopy];
    NSMutableArray *actions = [request[@"actions"] mutableCopy];
    NSMutableDictionary *block = [actions.lastObject mutableCopy];
    block[@"style"] = @"destructive";
    block[@"arm"] = SZFArm(@"Lena");
    actions[actions.count - 1] = block;
    request[@"actions"] = actions;
    data[@"request"] = request;
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:@"c_lena"
                                                                        highlightMessage:nil];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:data];
    [page layoutSubtreeIfNeeded];
    SZFriendsActionButton *button = (SZFriendsActionButton *)page.requestCard.actionButtons.lastObject;
    SZFExpect(button.style == SZFriendsButtonStyleDestructive, @"the card's Block is red, not a blue link");
    NSUInteger before = transport.sent.count;
    SZFTestClickAfter(clock, button, 10, 1);
    [page layoutSubtreeIfNeeded];
    SZFExpect(button.armed && transport.sent.count == before, @"the card's Block arms first");
    SZFExpect(SZFTestMissedHits(button, window.contentView) == 0, @"the pill is one full-bounds target");
    SZFExpect([page dismissInnermostPicker] && !button.armed, @"Escape turns the card's pill back first");
    (void)window;
}

static void SZFTestAnnouncements(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    [context copyText:@"jasmine-street"];
    NSString *copied = [NSString stringWithFormat:@"%@ (high): Copied",
                                                  NSAccessibilityAnnouncementRequestedNotification];
    SZFExpect([clock.spoken isEqual:@[ copied ]], @"Copy is announced: %@", clock.spoken);

    // An inline error under the composer is spoken as it appears.
    SZFriendsComposerView *composer = [[SZFriendsComposerView alloc] initWithContext:context conversationID:@"c_mei"];
    NSWindow *window = SZFTestHostWindow(composer, NSMakeSize(400, 140), NSAppearanceNameAqua);
    [composer applyComposer:SZFTestSnapshot(@"conversation-mei")[@"composer"]];
    [composer.textView insertText:@"hello" replacementRange:NSMakeRange(0, 0)];
    [composer send];
    NSMutableDictionary *failure = [SZFTestFrame(@"frames/reply-error") mutableCopy];
    failure[@"re"] = transport.sent.lastObject[@"id"];
    [clock.spoken removeAllObjects];
    [transport deliver:failure];
    NSString *message = failure[@"error"][@"message"];
    NSString *spokenError = [NSString stringWithFormat:@"%@ (high): %@",
                                                       NSAccessibilityAnnouncementRequestedNotification, message];
    SZFExpect(message.length && [clock.spoken containsObject:spokenError], @"the send error is announced: %@",
              clock.spoken);

    // So is the answer to Add by ID, which appears under its field.
    SZFriendsProfilePage *profile = [[SZFriendsProfilePage alloc] initWithContext:context];
    NSWindow *profileWindow = SZFTestHostWindow(profile, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [profile applySnapshot:SZFTestSnapshot(@"profile-unreserved")];
    profile.addField.stringValue = @"willow-breeze";
    [profile sendAddRequest];
    NSMutableDictionary *reply = [SZFTestFrame(@"replies/add_by_id") mutableCopy];
    reply[@"re"] = transport.sent.lastObject[@"id"];
    [clock.spoken removeAllObjects];
    [transport deliver:reply];
    NSString *answer = reply[@"result"][@"message"];
    SZFExpect(answer.length && clock.spoken.count == 1 && [clock.spoken.firstObject hasSuffix:answer],
              @"the Add by ID answer is announced: %@", clock.spoken);
    (void)window, (void)profileWindow;
}

static void SZFTestConfirmedIDs(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    NSMutableDictionary *row = [SZFTestSnapshot(@"list")[@"rows"][5] mutableCopy];
    row[@"id_confirmed"] = @YES;
    row[@"id_confirmed_label"] = @"ID confirmed by the Friends server";
    SZFriendsRowView *view = [[SZFriendsRowView alloc] initWithContext:context];
    view.frame = NSMakeRect(0, 0, 388, SZFriendsRowHeight);
    NSWindow *window = SZFTestHostWindow(view, view.frame.size, NSAppearanceNameAqua);
    [view configureWithListRow:row];
    NSBitmapImageRep *marked = SZFTestBitmap(view);
    row[@"id_confirmed"] = @NO;
    [view configureWithListRow:row];
    NSBitmapImageRep *plain = SZFTestBitmap(view);
    SZFExpect(![marked.TIFFRepresentation isEqualToData:plain.TIFFRepresentation] && !view.idConfirmed,
              @"a confirmed ID draws its check; an unconfirmed one does not");

    SZFriendsDetailsPage *details = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_tulip"];
    NSWindow *detailsWindow = SZFTestHostWindow(details, NSMakeSize(400, 560), NSAppearanceNameAqua);
    NSMutableDictionary *data = [SZFTestSnapshot(@"details-mei") mutableCopy];
    data[@"id_confirmed"] = @YES;
    data[@"id_confirmed_label"] = @"ID confirmed by the Friends server";
    [details applySnapshot:data];
    [details layoutSubtreeIfNeeded];
    NSRect check = details.attestationView.frame;
    SZFExpect(!details.attestationView.hidden && [details.attestationView.toolTip hasPrefix:@"ID confirmed"] &&
                  NSMinX(check) >= NSMinX(details.cpyButton.frame) - 16 &&
                  NSMaxX(check) <= NSMinX(details.cpyButton.frame),
              @"details: the check sits between the ID and Copy: %@", NSStringFromRect(check));
    data[@"id_confirmed"] = @NO;
    [details applySnapshot:data];
    SZFExpect(details.attestationView.hidden, @"no check for an unconfirmed ID");
    (void)window, (void)detailsWindow;
}

// Delete chat history… on a friend's details asks first, over the dropdown, with the question the helper wrote; Cancel
// sends nothing, and confirming sends delete_history for this chat alone.
static void SZFTestDeleteChatHistory(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [content openDetails:@"c_mei"];
    SZFriendsDetailsPage *details = (SZFriendsDetailsPage *)content.topPage;
    NSDictionary *data = SZFTestSnapshot(@"details-mei");
    [details applySnapshot:data];
    [content layoutSubtreeIfNeeded];
    NSDictionary *question = [data[@"actions"] firstObject][@"confirm"];
    SZFriendsButton *delete = details.actionButtons.firstObject;
    SZFExpect([delete.title isEqualToString:@"Delete chat history…"] && delete.style == SZFriendsButtonStyleDestructive,
              @"Delete chat history… first, drawn destructive: %@", delete.title);
    NSUInteger before = transport.sent.count;
    SZFTestClickAfter(clock, delete, 10, 1);
    SZFriendsConfirmView *confirm = content.confirmation;
    BOOL title = NO, body = NO;
    for (NSTextField *field in SZFTestSubviews(confirm, NSTextField.class)) {
        title = title || [field.stringValue isEqualToString:question[@"title"]];
        body = body || [field.stringValue isEqualToString:question[@"body"]];
    }
    SZFExpect(confirm && title && body && transport.sent.count == before,
              @"asks first with the helper's question, sending nothing");
    SZFExpect(confirm.confirmButton.style == SZFriendsButtonStyleDestructiveBordered &&
                  [confirm.confirmButton.title isEqualToString:@"Delete History"],
              @"confirms in red: %@", confirm.confirmButton.title);
    [confirm.cancelButton performClick:nil];
    SZFExpect(content.confirmation == nil && transport.sent.count == before, @"Cancel sends nothing");
    SZFTestClickAfter(clock, delete, 10, 1);
    [content.confirmation.confirmButton performClick:nil];
    NSDictionary *sent = transport.sent.lastObject;
    SZFExpect(transport.sent.count == before + 1 && [sent[@"type"] isEqualToString:@"delete_history"] &&
                  [sent[@"fields"] isEqual:@{@"conversation_id" : @"c_mei"}],
              @"confirming deletes Mei's chat only: %@", sent);
    (void)window;
}

void SZFTestArmedActions(void) {
    SZFTestDeleteChatHistory();
    SZFTestArmedInDetails();
    SZFTestDestructiveConfirm();
    SZFTestArmedRequestCard();
    SZFTestAnnouncements();
    SZFTestConfirmedIDs();
}
