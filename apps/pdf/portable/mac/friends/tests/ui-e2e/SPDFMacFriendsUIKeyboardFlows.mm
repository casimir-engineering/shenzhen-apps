// friends-ui-e2e: the Friends dropdown by keyboard alone, with key events through the popover's window
// (SZFriendsKeyFocus.h). After the search step of the pair run, with Mei and Kenji in Ana's list: Down Down Return
// opens the second friend's chat, Command-[ comes back with that friend highlighted, Tab goes round every control and
// Shift-Tab back, a letter typed on the list goes to the search, Down and Return open the match, and Escape empties
// the search, then closes. Full Keyboard Access is whatever this Mac has; run with -AppleKeyboardUIMode 2 (this
// process only) for the other case.

#import "SPDFMacFriendsUIPairInternal.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsKeyFocus.h"

// A key with modifiers, down and up; a Command key goes first to the window's key equivalents, as NSApp sends it.
static void UIKeyWith(NSWindow* window, unsigned short keyCode, NSString* characters, NSEventModifierFlags flags) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    const NSEventType types[] = {NSEventTypeKeyDown, NSEventTypeKeyUp};
    for (NSEventType type : types) {
        NSEvent* event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:now
                                      windowNumber:window.windowNumber context:nil characters:characters
                       charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
        if (type == NSEventTypeKeyDown && (flags & NSEventModifierFlagCommand) && [window performKeyEquivalent:event])
            continue;
        [window sendEvent:event];
    }
    UISpin(0.05);
}

static void UIDown(NSWindow* window) { UIKeyWith(window, 125, @"", NSEventModifierFlagFunction); }
static void UITab(NSWindow* window) { UIKeyWith(window, 48, @"\t", 0); }
static void UIBackTab(NSWindow* window) { UIKeyWith(window, 48, @"\x19", NSEventModifierFlagShift); }

static BOOL UISearchFocused(UIRig* rig) {
    NSResponder* responder = rig.popoverWindow.firstResponder;
    return [responder isKindOfClass:NSTextView.class] && ((NSTextView*)responder).isFieldEditor &&
           [(NSView*)responder isDescendantOf:rig.listPage.searchField];
}

// The highlighted rows' people (never more than one).
static NSArray<NSString*>* UIHighlighted(UIRig* rig) {
    NSMutableArray* people = [NSMutableArray array];
    for (SZFriendsRowView* row in rig.listPage.rows)
        if (row.hovered && UIVisible(row)) [people addObject:row.conversationID ?: @"?"];
    return people;
}

static NSString* UIFocusName(UIRig* rig) {
    NSResponder* responder = rig.popoverWindow.firstResponder;
    if (UISearchFocused(rig)) return @"search field";
    if ([responder isKindOfClass:NSButton.class])
        return [NSString stringWithFormat:@"button \"%@\"", ((NSButton*)responder).title.length
                                                                ? ((NSButton*)responder).title
                                                                : ((NSButton*)responder).accessibilityLabel];
    return NSStringFromClass(responder.class);
}

static SZFriendsConversationPage* UIChatOnTop(UIRig* rig, NSString* conversationID) {
    SZFriendsConversationPage* page = (SZFriendsConversationPage*)rig.content.topPage;
    if (![page isKindOfClass:SZFriendsConversationPage.class]) return nil;
    return [page.conversationID isEqualToString:conversationID] ? page : nil;
}

BOOL UIKeyboard(UIRig* rig) {
    UIBeginFlow(rig, @"keyboard");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    NSWindow* window = rig.popoverWindow;
    SZFriendsListPage* list = rig.listPage;
    fprintf(stderr, "[%s keyboard] Full Keyboard Access %s\n", rig.variant.name.UTF8String,
            NSApp.isFullKeyboardAccessEnabled ? "on" : "off");
    EXPECT(rig, UIWait(5, ^BOOL { return UIRow(rig, @"Mei") && UIRow(rig, @"Kenji"); }), "both friends are listed");
    EXPECT(rig, UISearchFocused(rig), "the search field has the focus: %@", window.firstResponder);
    NSArray<SZFriendsRowView*>* rows = list.rows;
    NSString* second = rows[1].conversationID;
    NSString* secondName = rows[1].accessibilityLabel;

    // Down Down: the second row, the caret still in the search field.
    UIDown(window);
    UIDown(window);
    EXPECT(rig, [UIHighlighted(rig) isEqualToArray:@[ second ]] && UISearchFocused(rig),
           "Down Down highlights the second row (%@), the search keeping the focus: %@ %@", secondName,
           UIHighlighted(rig), window.firstResponder);
    UIShot(rig, @"down-down");
    // Return opens it, as a click does; the composer takes the focus.
    UIPressReturn(window);
    EXPECT(rig, UIWait(5, ^BOOL {
               SZFriendsConversationPage* chat = UIChatOnTop(rig, second);
               return chat && window.firstResponder == chat.composer.textView;
           }),
           "Return opens %@'s chat with the composer focused: %@ %@", secondName, rig.content.topPage,
           window.firstResponder);
    UIShot(rig, @"chat");
    // Tab leaves the composer for the chat's buttons and comes round to it again; Return still sends.
    SZFriendsConversationPage* chat = UIChatOnTop(rig, second);
    UITab(window);
    EXPECT(rig, [window.firstResponder isKindOfClass:SZFriendsButton.class] &&
                    ![chat.composer.textView.string containsString:@"\t"],
           "Tab in the composer goes to a button: %@", window.firstResponder);
    UIShot(rig, @"chat-button-focus");
    for (int i = 0; i < 40 && window.firstResponder != chat.composer.textView; i++) UITab(window);
    EXPECT(rig, window.firstResponder == chat.composer.textView, "Tab comes round to the composer");
    // Command-[ goes back, the friend still highlighted.
    UIKeyWith(window, 33, @"[", NSEventModifierFlagCommand);
    EXPECT(rig, UIWait(5, ^BOOL { return rig.content.topPage == list && UISearchFocused(rig); }),
           "Command-[ comes back to the list, in the search field: %@", rig.content.topPage);
    EXPECT(rig, [UIHighlighted(rig) isEqualToArray:@[ second ]], "with %@ still highlighted: %@", secondName,
           UIHighlighted(rig));

    // Tab: the list, with a ring on the highlighted row; then every control, round to the search field.
    UITab(window);
    EXPECT(rig, [window.firstResponder isKindOfClass:SZFriendsListKeyView.class], "Tab goes to the list: %@",
           UIFocusName(rig));
    SZFriendsRowView* ringed = nil;
    for (SZFriendsRowView* row in list.rows)
        if (row.showsKeyFocus) ringed = row;
    EXPECT(rig, ringed && [ringed.conversationID isEqualToString:second], "the highlighted row shows the focus");
    UIShot(rig, @"list-focus");
    NSMutableArray<NSString*>* visited = [NSMutableArray arrayWithObject:@"list"];
    NSMutableArray<NSResponder*>* stops = [NSMutableArray arrayWithObject:window.firstResponder];
    for (int i = 0; i < 30 && !UISearchFocused(rig); i++) {
        UITab(window);
        if (UISearchFocused(rig)) break;
        [visited addObject:UIFocusName(rig)];
        [stops addObject:window.firstResponder];
        if (stops.count == 2) UIShot(rig, @"button-focus");
        if (stops.count == 5) UIShot(rig, @"footer-button-focus");
    }
    fprintf(stderr, "[%s keyboard] Tab: search field, %s\n", rig.variant.name.UTF8String,
            [visited componentsJoinedByString:@", "].UTF8String);
    EXPECT(rig, UISearchFocused(rig), "Tab comes round to the search field: %@", visited);
    EXPECT(rig, [stops containsObject:list.friendsTab] && [stops containsObject:list.footer.addButton],
           "by the tabs and the footer's Add by ID: %@", visited);
    EXPECT(rig, [NSSet setWithArray:stops].count == stops.count, "each control once: %@", visited);
    UIBackTab(window);
    EXPECT(rig, window.firstResponder == stops.lastObject, "Shift-Tab from the search: the last control (%@)",
           UIFocusName(rig));
    for (NSUInteger i = 1; i < stops.count; i++) UIBackTab(window);
    EXPECT(rig, window.firstResponder == stops.firstObject, "Shift-Tab goes back to the list: %@", UIFocusName(rig));

    // A letter typed on the list goes into the search; Down and Return open the match.
    UIKeyWith(window, 40, @"k", 0);
    EXPECT(rig, UISearchFocused(rig) && [list.searchField.stringValue isEqualToString:@"k"],
           "typing k on the list types it into the search: \"%@\" %@", list.searchField.stringValue,
           UIFocusName(rig));
    UIType(window, @"enji");
    EXPECT(rig, UIWait(5, ^BOOL { return UIRow(rig, @"Kenji") && !UIRow(rig, @"Mei"); }), "Kenji alone matches");
    NSString* kenji = UIRow(rig, @"Kenji").conversationID;
    UIDown(window);
    EXPECT(rig, [UIHighlighted(rig) isEqualToArray:@[ kenji ]], "Kenji highlighted: %@", UIHighlighted(rig));
    UIShot(rig, @"typed-down");
    UIPressReturn(window);
    EXPECT(rig, UIWait(5, ^BOOL { return UIChatOnTop(rig, kenji) != nil; }), "Return opens Kenji's chat");
    UIKeyWith(window, 33, @"[", NSEventModifierFlagCommand);
    EXPECT(rig, UIWait(5, ^BOOL { return rig.content.topPage == list && UISearchFocused(rig); }), "back to the list");

    // Escape empties the search, then closes.
    UIPressEscape(window);
    EXPECT(rig, rig.dropdown.shown && list.searchField.stringValue.length == 0,
           "the first Escape empties the search and leaves Friends open");
    EXPECT(rig, UIWait(5, ^BOOL { return UIRow(rig, @"Mei") && UIRow(rig, @"Kenji"); }), "both friends again");
    UIPressEscape(window);
    EXPECT(rig, UIWait(5, ^BOOL { return !rig.dropdown.shown; }), "the second Escape closes Friends");
    return YES;
}
