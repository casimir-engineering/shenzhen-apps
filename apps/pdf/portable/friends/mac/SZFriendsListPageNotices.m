// SZFriendsListPage's cards above the rows: the name prompt, which asks for a name until one is saved and then says
// so, and the strip for files on their way in ("Send 2 files to…" or the drop hint).

#import "mac/SZFriendsListPageInternal.h"

@implementation SZFriendsListPage (Notices)

// The card that asks for a name until one is saved. What is typed survives every snapshot. When the helper confirms
// the name, the card says so where the person typed it (welcome.strings name_saved, with a check) and goes a moment
// later; the helper's next snapshot (no name_prompt) does not cut that short.
- (void)applyNamePrompt:(NSDictionary *)prompt {
    if (_namePromptSaved) {
        if (!prompt) return;
        [self endNameSaved]; // asked again meanwhile (Reset Friends): the card asks
    }
    // The snapshot without the card can come before set_name's reply: the card waits for the reply to say "Saved".
    if (!prompt && !_namePrompt.hidden && _namePrompt.nameEditor.saving) return;
    BOOL wasHidden = _namePrompt.hidden;
    _namePrompt.hidden = prompt == nil;
    _namePrompt.titleLabel.stringValue = SZFStr(prompt, @"title") ?: @"";
    // The card shows on first run, so it also says Friends is a beta (welcome.strings beta_note), under its own note.
    NSString *note = SZFStr(prompt, @"note"), *betaNote = [self.context string:@"beta_note"];
    if (prompt && betaNote.length) note = note.length ? [NSString stringWithFormat:@"%@\n%@", note, betaNote] : betaNote;
    _namePrompt.noteLabel.stringValue = note ?: @"";
    if (prompt && !_namePrompt.nameEditor) {
        SZFriendsNameEditor *editor = [[SZFriendsNameEditor alloc] initWithContext:self.context
                                                                              font:self.context.appearance.bodyFont];
        __weak SZFriendsListPage *weakSelf = self;
        editor.onSaved = ^(NSString *name) { [weakSelf showNameSaved:name]; };
        editor.onLayoutChange = ^{ [weakSelf setNeedsLayout:YES]; };
        _namePrompt.nameEditor = editor;
    }
    if (prompt && wasHidden && !_namePrompt.nameEditor.saving) [_namePrompt.nameEditor reset];
    [_namePrompt.nameEditor reloadStrings];
    _namePrompt.nameEditor.field.placeholderString = SZFStr(prompt, @"placeholder");
    _namePrompt.nameEditor.field.accessibilityLabel = SZFStr(prompt, @"title");
}

- (void)showNameSaved:(NSString *)name {
    SZFriendsNameEditor *editor = _namePrompt.nameEditor;
    // The field goes, so the typing goes to search: the next thing a person does in the list. The field let go of
    // the typing while it rested for the helper's answer, which left nothing focused.
    NSResponder *focus = self.window.firstResponder;
    if (editor.field.currentEditor || !focus || focus == self.window) [self.window makeFirstResponder:self.searchField];
    [editor reset];
    NSString *saved = [[self.context string:@"name_saved"] stringByReplacingOccurrencesOfString:@"{name}"
                                                                                     withString:name ?: @""];
    if (![self.context string:@"name_saved"].length) {
        _namePrompt.hidden = YES;
        [self setNeedsLayout:YES];
        return;
    }
    _namePromptSaved = YES;
    _namePrompt.hidden = NO;
    NSUInteger round = ++_namePromptRound;
    _namePrompt.titleLabel.stringValue = saved;
    _namePrompt.noteLabel.stringValue = @"";
    _namePrompt.nameEditor.hidden = YES;
    _namePrompt.secondaryButton = nil;
    _namePrompt.iconDrawer = ^(NSRect rect, NSColor *color) { SZFriendsDrawCheckIcon(rect, color); };
    _namePrompt.iconColor = self.context.appearance.successColor;
    _namePrompt.needsDisplay = YES;
    [self.context announce:saved];
    [self setNeedsLayout:YES];
    __weak SZFriendsListPage *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsNameSavedSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       SZFriendsListPage *page = weakSelf;
                       if (!page || !page->_namePromptSaved || page->_namePromptRound != round) return;
                       [page endNameSaved];
                       page->_namePrompt.hidden = YES;
                       [page setNeedsLayout:YES];
                   });
}

- (void)endNameSaved {
    _namePromptSaved = NO;
    _namePromptRound++;
    _namePrompt.iconDrawer = nil;
    _namePrompt.iconColor = nil;
    _namePrompt.nameEditor.hidden = NO;
    _namePrompt.needsDisplay = YES;
}

// Whenever files are on their way in (dragged over the dropdown, or waiting for "Send 2 files to…"), a row that
// refuses them (a request, a blocked person) fades, so it never looks like a place to drop or click.
- (void)dimRowsThatRefuseFiles {
    BOOL sending = _sendTitle != nil || _dropHint != nil;
    BOOL refusalShown = _dropHintRefuses && !_sendTitle;
    for (SZFriendsRowView *row in _rowViews) {
        row.dimmed = sending && !row.dropLabel;
        row.dropRefusalShownAbove = refusalShown;
    }
}

- (void)updateSendNotice {
    [self dimRowsThatRefuseFiles];
    NSString *text = _sendTitle ?: _dropHint;
    _sendNotice.hidden = text.length == 0;
    _sendNotice.bodyLabel.stringValue = text ?: @"";
    _sendNotice.bodyLabel.font = _sendTitle ? SZFriendsSemibold(self.context.appearance.bodyFont)
                                            : self.context.appearance.secondaryFont;
    // A way out for the mouse, not only Escape: the static Cancel, at the strip's trailing edge.
    NSString *cancel = [self.context string:@"cancel"];
    if (_sendTitle && cancel.length && !_sendNotice.button) {
        SZFriendsButton *button = [SZFriendsButton buttonWithTitle:cancel style:SZFriendsButtonStyleLink
                                                        appearance:self.context.appearance];
        __weak SZFriendsListPage *weakSelf = self;
        button.onPress = ^(SZFriendsButton *pressed) {
            (void)pressed;
            [weakSelf.context.navigator finishSendPicker];
        };
        _sendNotice.button = button;
        _sendNotice.buttonTrailing = YES;
    } else if (!_sendTitle) {
        _sendNotice.button = nil;
        _sendNotice.secondaryButton = nil;
    }
    [self setNeedsLayout:YES];
}

@end
