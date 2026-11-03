// SZFriendsListPage and the keyboard: the search field keeps the caret while Up and Down move a highlight through the
// rows and Return opens the highlighted one, as a click does (with text typed and nothing highlighted, the first
// match). The highlight is the one the pointer's hover draws, so there are never two. Tab goes search field, list,
// then every other control top to bottom; with the list focused, Up, Down and Return work the same, Delete chooses
// the row's first menu action as on a focused row, and a letter typed goes back into the search field.

#import "mac/SZFriendsListPageInternal.h"

@implementation SZFriendsListPage (Keyboard)

- (void)setUpKeyboard {
    _keyRow = -1;
    _keyList = [[SZFriendsListKeyView alloc] initWithFrame:NSZeroRect];
    __weak SZFriendsListPage *weakSelf = self;
    _keyList.onKey = ^BOOL(NSEvent *event) { return [weakSelf listKey:event]; };
    _keyList.onFocusChange = ^(BOOL focused) {
        SZFriendsListPage *page = weakSelf;
        if (focused && page && page->_keyRow < 0) [page highlightRow:0 fromKeyboard:YES];
        [page showKeyFocus];
    };
    [self addSubview:_keyList];
}

- (void)layOutKeyList:(NSRect)frame {
    _keyList.frame = frame;
}

// The rows Up and Down go through: the visible tab's.
- (NSArray<SZFriendsRowView *> *)keyRows {
    NSMutableArray<SZFriendsRowView *> *rows = [NSMutableArray array];
    for (SZFriendsRowView *row in self.showingNearby ? self.nearbyPane.personRows : _rowViews)
        if (!row.hidden) [rows addObject:row];
    return rows;
}

#pragma mark - The highlight

- (void)highlightRow:(NSInteger)index fromKeyboard:(BOOL)fromKeyboard {
    NSArray<SZFriendsRowView *> *rows = [self keyRows];
    if (index >= (NSInteger)rows.count) index = (NSInteger)rows.count - 1;
    _keyRow = index;
    _keyRowID = index >= 0 ? rows[(NSUInteger)index].conversationID : nil;
    _keyRowByKeyboard = fromKeyboard;
    _settingKeyRow = YES;
    [rows enumerateObjectsUsingBlock:^(SZFriendsRowView *row, NSUInteger position, BOOL *stop) {
        (void)stop;
        row.hovered = (NSInteger)position == index;
    }];
    _settingKeyRow = NO;
    [self showKeyFocus];
}

- (void)showKeyFocus {
    BOOL focused = _keyList.focused;
    NSArray<SZFriendsRowView *> *rows = [self keyRows];
    [rows enumerateObjectsUsingBlock:^(SZFriendsRowView *row, NSUInteger position, BOOL *stop) {
        (void)stop;
        row.showsKeyFocus = focused && (NSInteger)position == self->_keyRow;
    }];
}

- (void)moveKeyRow:(NSInteger)delta {
    NSArray<SZFriendsRowView *> *rows = [self keyRows];
    if (!rows.count) return;
    // The first Down takes the first row; past either end the highlight stays where it is.
    NSInteger index = _keyRow < 0 ? (delta > 0 ? 0 : -1) : MAX(0, MIN((NSInteger)rows.count - 1, _keyRow + delta));
    if (index < 0) return;
    [self highlightRow:index fromKeyboard:YES];
    [self layoutSubtreeIfNeeded];
    SZFriendsRowView *row = rows[(NSUInteger)index];
    [row scrollRectToVisible:row.bounds];
}

- (void)openKeyRow {
    NSArray<SZFriendsRowView *> *rows = [self keyRows];
    NSInteger index = _keyRow;
    if (index < 0 && self.searchField.stringValue.length) index = 0;
    if (index < 0 || index >= (NSInteger)rows.count) return;
    SZFriendsRowView *row = rows[(NSUInteger)index];
    if (!row.enabled || !row.onPress) return;
    [self highlightRow:index fromKeyboard:YES];
    _openedRowID = row.conversationID;
    row.onPress(row);
}

- (void)keyRowsChanged {
    NSArray<SZFriendsRowView *> *rows = [self keyRows];
    if (!_keyRowByKeyboard) {
        // The pointer's highlight stays with the place under it, as a hover does.
        _keyRow = -1;
        _keyRowID = nil;
        [rows enumerateObjectsUsingBlock:^(SZFriendsRowView *row, NSUInteger position, BOOL *stop) {
            if (!row.hovered) return;
            self->_keyRow = (NSInteger)position;
            self->_keyRowID = row.conversationID;
            *stop = YES;
        }];
        [self showKeyFocus];
        return;
    }
    NSInteger index = -1;
    for (NSUInteger position = 0; _keyRowID && position < rows.count; position++)
        if ([rows[position].conversationID isEqualToString:_keyRowID]) index = (NSInteger)position;
    // Gone, or nothing highlighted yet while searching: the first match.
    if (index < 0 && self.searchField.stringValue.length && rows.count) index = 0;
    [self highlightRow:index fromKeyboard:YES];
}

- (void)restoreKeyRow {
    if (!_openedRowID) return;
    _keyRowID = _openedRowID;
    _keyRowByKeyboard = YES;
    _openedRowID = nil;
    [self keyRowsChanged];
}

- (void)noteRowHovered:(SZFriendsRowView *)row inside:(BOOL)inside {
    if (_settingKeyRow) return;
    NSInteger index = (NSInteger)[[self keyRows] indexOfObjectIdenticalTo:row];
    if (index == NSNotFound) return;
    if (inside) [self highlightRow:index fromKeyboard:NO];
    else if (index == _keyRow) [self highlightRow:-1 fromKeyboard:NO];
}

#pragma mark - The search field

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.searchField) return;
    [self searchChanged];
}

- (void)searchChanged {
    // Typing is the keyboard's: the next rows keep the highlighted person, else highlight the first match.
    _keyRowByKeyboard = YES;
    for (NSString *token in @[ _listToken ?: @"", _nearbyToken ?: @"" ])
        if (token.length) [self.context.link setFilter:self.searchField.stringValue forSubscription:token];
}

- (BOOL)clearSearch {
    if (!self.searchField.stringValue.length) return NO;
    self.searchField.stringValue = @"";
    [self searchChanged];
    return YES;
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)textView;
    if (control != self.searchField) return NO;
    if (SZFriendsFocusCommand(control, command)) return YES;
    if (command == @selector(moveDown:) || command == @selector(moveUp:)) {
        [self moveKeyRow:command == @selector(moveDown:) ? 1 : -1];
        return YES;
    }
    if (command == @selector(insertNewline:)) {
        [self openKeyRow];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        SZFriendsForwardEscape(self);
        return YES;
    }
    return NO;
}

#pragma mark - The list focused

- (NSArray<NSView *> *)keyFocusStops {
    NSMutableArray<NSView *> *stops = [SZFriendsFocusStops(self) mutableCopy];
    [stops removeObject:self.searchField];
    if ([self keyRows].count) [stops insertObject:_keyList atIndex:0];
    if (!self.searchField.isHiddenOrHasHiddenAncestor) [stops insertObject:self.searchField atIndex:0];
    return stops;
}

- (BOOL)listKey:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                        NSEventModifierFlagControl);
    BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    if (SZFriendsIsTabKey(event)) return SZFriendsMoveFocus(_keyList, shift);
    if (flags) return NO;
    switch (event.keyCode) {
    case 125: // Down
    case 126: // Up
        [self moveKeyRow:event.keyCode == 125 ? 1 : -1];
        return YES;
    case 36: // Return
    case 76: // Enter
    case 49: // Space
        [self openKeyRow];
        return YES;
    case 53: // Escape
        SZFriendsForwardEscape(self);
        return YES;
    case 51:  // Delete
    case 117: // Forward Delete
        if (_keyRow >= 0 && _keyRow < (NSInteger)[self keyRows].count)
            [[self keyRows][(NSUInteger)_keyRow] keyDown:event];
        return YES;
    default:
        break;
    }
    // A letter (or any text) goes to the search field, after what is typed there.
    NSString *characters = event.characters;
    unichar first = characters.length ? [characters characterAtIndex:0] : 0;
    if (first < 0x20 || first == 0x7f || (first >= 0xF700 && first <= 0xF8FF)) return NO;
    if (!SZFriendsFocus(self.searchField)) return NO;
    NSText *editor = [self.window fieldEditor:NO forObject:self.searchField];
    if (![editor isKindOfClass:NSTextView.class]) return NO;
    editor.selectedRange = NSMakeRange(editor.string.length, 0);
    [editor keyDown:event];
    return YES;
}

@end
