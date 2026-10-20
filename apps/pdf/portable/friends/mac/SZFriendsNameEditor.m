// SZFriendsNameEditor: the field and Save button behind the name prompt and the footer's rename (SZFriendsListPage.h).

#import "mac/SZFriendsListPage.h"

static const CGFloat SZFriendsNameEditorRowHeight = 26;

@interface SZFriendsNameEditor () <NSTextFieldDelegate>
@end

@implementation SZFriendsNameEditor {
    SZFriendsContext *_context;
    NSProgressIndicator *_spinner;
    NSString *_refusal; // why the last Save did not go through; cleared by typing
}

- (instancetype)initWithContext:(SZFriendsContext *)context font:(NSFont *)font {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 352, SZFriendsNameEditorRowHeight)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    _field = [NSTextField textFieldWithString:@""];
    _field.bezelStyle = NSTextFieldRoundedBezel;
    _field.font = font;
    _field.delegate = self;
    _field.cell.scrollable = YES;
    _field.cell.wraps = NO;
    [self addSubview:_field];
    _saveButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:appearance];
    __weak SZFriendsNameEditor *weakSelf = self;
    _saveButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf save];
    };
    [self addSubview:_saveButton];
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    [self addSubview:_spinner];
    // Why a name was refused, in the colour the dropdown uses for what went wrong.
    _messageLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.destructiveColor);
    [self addSubview:_messageLabel];
    [self reloadStrings];
    return self;
}

- (NSString *)typedName {
    return [_field.stringValue ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (BOOL)hasTyping {
    return _field.stringValue.length > 0;
}

// The helper's words only: without them (an older helper) Save has no title, and Return still saves.
- (void)reloadStrings {
    NSString *save = [_context string:@"save"];
    _saveButton.title = save;
    _saveButton.hidden = save.length == 0;
    _saveButton.accessibilityLabel = save.length ? save : nil;
    [self updateSaveButton];
}

- (void)setCurrentName:(NSString *)currentName {
    _currentName = [currentName copy];
    [self updateSaveButton];
}

- (void)updateSaveButton {
    NSString *name = [self typedName];
    _saveButton.enabled = !_saving && name.length > 0 && ![name isEqualToString:_currentName ?: @""];
    _saveButton.needsDisplay = YES;
}

- (void)setMessage:(NSString *)message {
    _refusal = message.length ? [message copy] : nil;
    _messageLabel.stringValue = _refusal ?: @"";
    if (_refusal) [_context announce:_refusal];
    [self setNeedsLayout:YES];
    if (self.onLayoutChange) self.onLayoutChange();
}

- (void)setSaving:(BOOL)saving {
    _saving = saving;
    _field.enabled = !saving;
    if (saving) [_spinner startAnimation:nil];
    else [_spinner stopAnimation:nil];
    [self updateSaveButton];
    [self setNeedsLayout:YES];
}

- (void)reset {
    _field.stringValue = @"";
    self.saving = NO;
    [self setMessage:nil];
}

- (BOOL)cancelTyping {
    if (_saving) return NO;
    BOOL changed = ![(_field.stringValue ?: @"") isEqualToString:_currentName ?: @""] || _refusal != nil;
    if (!changed) return NO;
    if (self.onCancel) {
        self.onCancel();
        return YES;
    }
    _field.stringValue = @"";
    if (_field.currentEditor) [self.window makeFirstResponder:nil];
    [self setMessage:nil];
    [self updateSaveButton];
    return YES;
}

- (void)save {
    if (_saving) return;
    NSString *name = [self typedName];
    if (name.length == 0) {
        // Clearing the name is not what Save is for: friends would then see the ID, which the card already says.
        [self setMessage:[_context string:@"name_empty"]];
        [self.window makeFirstResponder:_field];
        return;
    }
    if ([name isEqualToString:_currentName ?: @""]) {
        if (self.onSaved) self.onSaved(name);
        return;
    }
    self.saving = YES;
    [self setMessage:nil];
    __weak SZFriendsNameEditor *weakSelf = self;
    [_context.link sendIntent:@"set_name" fields:@{@"name" : name}
                        reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                            (void)result;
                            SZFriendsNameEditor *editor = weakSelf;
                            if (!editor) return;
                            editor.saving = NO;
                            if (error) {
                                // The helper's reason (too long, a line break), or the link's own words when the
                                // helper was not reached; never a guess of ours.
                                [editor setMessage:error.message];
                                [editor.window makeFirstResponder:editor->_field];
                                return;
                            }
                            editor->_currentName = [name copy];
                            [editor updateSaveButton];
                            if (editor.onSaved) editor.onSaved(name);
                        }];
}

#pragma mark - Field

- (void)controlTextDidChange:(NSNotification *)notification {
    (void)notification;
    if (_refusal) [self setMessage:nil];
    [self updateSaveButton];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)control, (void)textView;
    if (command == @selector(insertNewline:)) {
        [self save];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        // What was typed goes first; with nothing typed, Escape reaches the dropdown and closes it.
        if (![self cancelTyping]) SZFriendsForwardEscape(self);
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    (void)notification;
    if (self.onEndEditing) self.onEndEditing();
}

#pragma mark - Layout

- (CGFloat)saveWidth {
    return _saveButton.hidden ? 0 : MAX(60, [_saveButton fittingWidth]);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat message = SZFriendsFieldHeight(_messageLabel, width);
    return SZFriendsNameEditorRowHeight + (message ? 6 + message : 0);
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat save = [self saveWidth];
    CGFloat fieldWidth = MAX(60, width - (save ? save + 8 : 0));
    _field.frame = NSMakeRect(0, 1, fieldWidth, SZFriendsNameEditorRowHeight - 2);
    _saveButton.frame = NSMakeRect(width - save, 0, save, SZFriendsNameEditorRowHeight);
    // Over the field's trailing end while saving, where the text it is saving already is.
    _spinner.frame = NSMakeRect(fieldWidth - 22, 5, 16, 16);
    CGFloat message = SZFriendsFieldHeight(_messageLabel, width);
    _messageLabel.hidden = message == 0;
    if (message) _messageLabel.frame = NSMakeRect(0, SZFriendsNameEditorRowHeight + 6, width, message);
}

@end
