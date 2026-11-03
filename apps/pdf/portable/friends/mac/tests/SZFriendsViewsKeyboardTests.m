// Shenzhen Friends views tests: the dropdown by keyboard alone (SZFriendsKeyFocus.h, SZFriendsListPageKeyboard.m).
// Up and Down move the list's highlight while the search field keeps the caret, Return opens the highlighted row,
// Command-[ comes back with it still highlighted, Escape empties the search before it closes; Tab goes search field,
// list, then every other control and round again, Shift-Tab the other way, with or without Full Keyboard Access.
// The field's commands go through its real field editor, other keys to the focused view's -keyDown:.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"
#import "mac/SZFriendsKeyFocus.h"

static NSTextView *SZFEditor(NSWindow *window) {
    NSResponder *responder = window.firstResponder;
    BOOL editor = [responder isKindOfClass:NSTextView.class] && ((NSTextView *)responder).isFieldEditor;
    return editor ? (NSTextView *)responder : nil;
}

static BOOL SZFSearchFocused(SZFriendsListPage *list) {
    NSTextView *editor = SZFEditor(list.window);
    return editor && [editor isDescendantOf:list.searchField];
}

static NSInteger SZFHighlighted(SZFriendsListPage *list) {
    NSInteger found = -1, count = 0;
    for (NSUInteger index = 0; index < list.rows.count; index++) {
        if (!list.rows[index].hovered) continue;
        found = (NSInteger)index;
        count++;
    }
    return count > 1 ? -2 : found; // -2: two highlights, never allowed
}

static void SZFCommand(NSWindow *window, SEL command) {
    NSResponder *responder = window.firstResponder;
    if ([responder isKindOfClass:NSTextView.class]) [(NSTextView *)responder doCommandBySelector:command];
}

static void SZFKey(NSWindow *window, NSString *characters, unsigned short keyCode, NSEventModifierFlags flags) {
    [window.firstResponder keyDown:SZFTestKeyEvent(characters, keyCode, flags)];
}

static NSDictionary *SZFListWithRows(NSArray<NSString *> *conversationIDs) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"list") mutableCopy];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *row in data[@"rows"])
        if ([conversationIDs containsObject:row[@"conversation_id"]]) [rows addObject:row];
    data[@"rows"] = rows;
    return data;
}

static void SZFTestListArrowsAndReturn(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), NSAppearanceNameAqua);
    __block NSInteger closes = 0;
    content.onClose = ^{ closes++; };
    content.presented = YES;
    SZFriendsListPage *list = content.listPage;
    [list applySnapshot:SZFTestSnapshot(@"list")];
    [content layoutSubtreeIfNeeded];
    SZFExpect(SZFSearchFocused(list), @"the search field has the focus when Friends opens: %@", window.firstResponder);
    SZFExpect(SZFHighlighted(list) == -1, @"nothing is highlighted before a key");

    SZFCommand(window, @selector(moveDown:));
    SZFExpect(SZFHighlighted(list) == 0, @"the first Down highlights the first row: %ld", (long)SZFHighlighted(list));
    SZFCommand(window, @selector(moveDown:));
    SZFExpect(SZFHighlighted(list) == 1 && SZFSearchFocused(list),
              @"the second Down the second row, the caret staying in the search field");
    for (int i = 0; i < 5; i++) SZFCommand(window, @selector(moveUp:));
    SZFExpect(SZFHighlighted(list) == 0, @"Up stops at the first row");
    for (int i = 0; i < 20; i++) SZFCommand(window, @selector(moveDown:));
    SZFExpect(SZFHighlighted(list) == (NSInteger)list.rows.count - 1, @"Down stops at the last row");
    // The pointer takes the same highlight: never two.
    SZFriendsRowView *kenji = list.rows[2];
    [kenji mouseEntered:[NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:NSZeroPoint modifierFlags:0
                                              timestamp:0 windowNumber:0 context:nil eventNumber:0
                                         trackingNumber:0 userData:NULL]];
    SZFExpect(SZFHighlighted(list) == 2, @"hovering a row moves the one highlight there: %ld",
              (long)SZFHighlighted(list));
    SZFCommand(window, @selector(moveUp:));
    SZFExpect(SZFHighlighted(list) == 1, @"and the keys go on from it");

    // Return opens the highlighted row as a click does.
    SZFCommand(window, @selector(insertNewline:));
    SZFriendsConversationPage *chat = (SZFriendsConversationPage *)content.topPage;
    SZFExpect([chat isKindOfClass:SZFriendsConversationPage.class] && [chat.conversationID isEqualToString:@"c_mei"],
              @"Return opens Mei's chat: %@", content.topPage);
    // Command-[ goes back, with Mei still highlighted and the caret in the search field.
    SZFExpect([content performKeyEquivalent:SZFTestKeyEvent(@"[", 33, NSEventModifierFlagCommand)] &&
                  content.topPage == list,
              @"Command-[ comes back to the list");
    SZFExpect(SZFHighlighted(list) == 1 && SZFSearchFocused(list), @"with Mei highlighted: %ld",
              (long)SZFHighlighted(list));

    // Typing: the next rows keep the highlighted person, or highlight the first match.
    list.searchField.stringValue = @"i";
    [(id<NSSearchFieldDelegate>)list controlTextDidChange:[NSNotification notificationWithName:@""
                                                                                        object:list.searchField]];
    [list applySnapshot:SZFListWithRows(@[ @"c_kenji", @"c_mei", @"c_priya" ])];
    SZFExpect(SZFHighlighted(list) == 0 && [list.rows[0].conversationID isEqualToString:@"c_mei"],
              @"Mei still matches and stays highlighted where she now is: %ld", (long)SZFHighlighted(list));
    list.searchField.stringValue = @"pri";
    [(id<NSSearchFieldDelegate>)list controlTextDidChange:[NSNotification notificationWithName:@""
                                                                                        object:list.searchField]];
    [list applySnapshot:SZFListWithRows(@[ @"c_priya" ])];
    SZFExpect(SZFHighlighted(list) == 0, @"a search without her highlights the first match");
    [list.rows[0] mouseExited:[NSEvent enterExitEventWithType:NSEventTypeMouseExited location:NSZeroPoint
                                                modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                                  eventNumber:0 trackingNumber:0 userData:NULL]];
    SZFExpect(SZFHighlighted(list) == -1, @"the pointer leaving takes the highlight away");
    SZFCommand(window, @selector(insertNewline:));
    chat = (SZFriendsConversationPage *)content.topPage;
    SZFExpect([chat isKindOfClass:SZFriendsConversationPage.class] && [chat.conversationID isEqualToString:@"c_priya"],
              @"with text typed and nothing highlighted, Return opens the first match: %@", content.topPage);
    [content goBack];
    [list applySnapshot:SZFListWithRows(@[])];
    SZFCommand(window, @selector(insertNewline:));
    SZFExpect(content.topPage == list, @"with no match Return does nothing");

    // Escape empties the search first, then closes.
    NSDictionary *subscribe = nil;
    for (NSDictionary *frame in transport.sent)
        if ([frame[@"type"] isEqual:@"subscribe"] && [frame[@"fields"][@"view"] isEqual:@"list"]) subscribe = frame;
    [transport deliver:@{@"type" : @"reply", @"re" : subscribe[@"id"] ?: @"", @"ok" : @YES,
                         @"result" : @{@"subscription" : @"s_list"}}];
    NSUInteger sent = transport.sent.count;
    SZFCommand(window, @selector(cancelOperation:));
    SZFExpect(closes == 0 && list.searchField.stringValue.length == 0, @"the first Escape empties the search");
    NSDictionary *filter = transport.sent.count > sent ? transport.sent.lastObject : nil;
    SZFExpect([filter[@"type"] isEqual:@"set_filter"] && [filter[@"fields"][@"query"] isEqual:@""],
              @"and the list follows: %@", filter);
    SZFCommand(window, @selector(cancelOperation:));
    SZFExpect(closes == 1, @"the second Escape closes");
    content.presented = NO;
    (void)window;
}

static void SZFTestTabLoop(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), NSAppearanceNameDarkAqua);
    content.presented = YES;
    SZFriendsListPage *list = content.listPage;
    [list applySnapshot:SZFTestSnapshot(@"list")];
    [content layoutSubtreeIfNeeded];

    // Tab: search field, then the list.
    SZFCommand(window, @selector(insertTab:));
    NSResponder *focused = window.firstResponder;
    SZFExpect([focused isKindOfClass:SZFriendsListKeyView.class], @"Tab from the search goes to the list: %@", focused);
    SZFExpect(SZFHighlighted(list) == 0 && list.rows[0].showsKeyFocus, @"the list's first row highlighted, ringed");
    SZFKey(window, @"", 125, NSEventModifierFlagFunction);
    SZFExpect(SZFHighlighted(list) == 1 && list.rows[1].showsKeyFocus && !list.rows[0].showsKeyFocus,
              @"Down moves highlight and ring together");
    // Then each of the page's controls once, and back round to the search field.
    NSMutableArray<NSResponder *> *visited = [NSMutableArray arrayWithObject:focused];
    for (int i = 0; i < 30 && !SZFSearchFocused(list); i++) {
        SZFKey(window, @"\t", 48, 0);
        if (!SZFSearchFocused(list)) [visited addObject:window.firstResponder];
    }
    SZFExpect(SZFSearchFocused(list), @"Tab comes round to the search field: %@", visited);
    SZFExpect([visited containsObject:list.friendsTab] && [visited containsObject:list.nearbyTab] &&
                  [visited containsObject:list.footer.addButton] && [visited containsObject:list.footer.cpyButton],
              @"through the tabs and the footer's buttons: %@", visited);
    SZFExpect([NSSet setWithArray:visited].count == visited.count, @"each once: %@", visited);
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSResponder *stop in visited)
        if ([stop isKindOfClass:SZFriendsButton.class]) [buttons addObject:stop];
    SZFExpect(buttons.count == visited.count - 1, @"every stop after the list is a button: %@", visited);
    // Shift-Tab goes the other way: from the search field to the last control, and back to the list.
    SZFCommand(window, @selector(insertBacktab:));
    SZFExpect(window.firstResponder == visited.lastObject, @"Shift-Tab from the search: the last control (%@)",
              window.firstResponder);
    for (NSUInteger i = 1; i < visited.count; i++) SZFKey(window, @"\x19", 48, NSEventModifierFlagShift);
    SZFExpect(window.firstResponder == visited.firstObject, @"and back to the list: %@", window.firstResponder);

    // A letter typed while the list has the focus goes into the search field, after what is there.
    list.searchField.stringValue = @"m";
    SZFKey(window, @"e", 14, 0);
    SZFExpect(SZFSearchFocused(list) && [list.searchField.stringValue isEqualToString:@"me"],
              @"typing on the list types into the search: \"%@\" %@", list.searchField.stringValue,
              window.firstResponder);
    SZFExpect(!list.rows[1].showsKeyFocus && list.rows[1].hovered,
              @"the ring goes with the focus, the highlight stays");
    list.searchField.stringValue = @"";

    // A focused button presses on Return.
    SZFCommand(window, @selector(insertTab:));
    SZFKey(window, @"\t", 48, 0);
    SZFExpect(window.firstResponder == list.friendsTab, @"after the list, the Friends tab: %@", window.firstResponder);
    SZFKey(window, @"\t", 48, 0);
    SZFKey(window, @"\r", 36, 0);
    SZFExpect(list.showingNearby && window.firstResponder == list.nearbyTab, @"Return on Nearby shows Nearby");
    SZFKey(window, @"\t", 48, NSEventModifierFlagShift);
    SZFKey(window, @" ", 49, 0);
    SZFExpect(!list.showingNearby, @"Space on Friends shows Friends");

    // In a chat Tab leaves the composer for the chat's buttons, and no tab is typed.
    [content openConversation:@"c_mei" highlightMessage:nil];
    SZFriendsConversationPage *chat = (SZFriendsConversationPage *)content.topPage;
    [chat applySnapshot:SZFTestSnapshot(@"conversation-mei")];
    [content layoutSubtreeIfNeeded];
    [window makeFirstResponder:chat.composer.textView];
    SZFKey(window, @"\t", 48, 0);
    SZFExpect([window.firstResponder isKindOfClass:SZFriendsButton.class] && ![chat.composer.textView.string
                                                                                  containsString:@"\t"],
              @"Tab in the composer goes to a button: %@", window.firstResponder);
    for (int i = 0; i < 40 && window.firstResponder != chat.composer.textView; i++) SZFKey(window, @"\t", 48, 0);
    SZFExpect(window.firstResponder == chat.composer.textView, @"and comes round to the composer");
    SZFKey(window, @"\x19", 48, NSEventModifierFlagShift);
    SZFExpect([window.firstResponder isKindOfClass:SZFriendsButton.class], @"Shift-Tab: the button before it");

    // A page with nowhere to type: the dropdown keeps the focus, and Tab enters the page at its first control.
    [content openDetails:@"c_mei"];
    SZFExpect(window.firstResponder == content, @"details: the dropdown holds the focus, not the hidden composer: %@",
              window.firstResponder);
    [content.topPage applySnapshot:SZFTestSnapshot(@"details-mei")];
    [content layoutSubtreeIfNeeded];
    SZFKey(window, @"\t", 48, 0);
    SZFriendsDetailsPage *details = (SZFriendsDetailsPage *)content.topPage;
    SZFExpect(window.firstResponder == details.header.backButton, @"Tab: the back arrow first: %@",
              window.firstResponder);

    // A confirmation takes the focus to its Cancel, Tab stays inside it, Escape cancels.
    context.presentConfirmation(@{@"title" : @"Remove Mei?", @"confirm_label" : @"Remove", @"cancel_label" : @"Cancel",
                                  @"destructive" : @YES},
                                ^(BOOL ticked) { (void)ticked; });
    SZFriendsConfirmView *confirm = content.confirmation;
    SZFExpect(window.firstResponder == confirm.cancelButton, @"the confirmation's Cancel has the focus: %@",
              window.firstResponder);
    SZFKey(window, @"\t", 48, 0);
    SZFExpect(window.firstResponder == confirm.confirmButton, @"Tab: its confirm button");
    SZFKey(window, @"\t", 48, 0);
    SZFExpect(window.firstResponder == confirm.cancelButton, @"and round, never to the page under it");
    SZFKey(window, @"\x1b", 53, 0);
    SZFExpect(content.confirmation == nil, @"Escape on a focused button cancels the confirmation");
    content.presented = NO;
    (void)transport;
}

void SZFTestKeyboard(void) {
    SZFTestListArrowsAndReturn();
    SZFTestTabLoop();
}
