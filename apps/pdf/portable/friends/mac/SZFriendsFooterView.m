// SZFriendsFooterView: the name friends see (edited in place), the ID with Copy, the unreserved note, Add by ID.

#import "mac/SZFriendsListPage.h"

@interface SZFriendsFooterView () <NSTextFieldDelegate>
@end

@implementation SZFriendsFooterView {
    SZFriendsContext *_context;
    SZFriendsAvatarView *_avatarView;
    NSTextField *_idLabel;
    NSTextField *_noteLabel;
    NSTextField *_nameEditor;
    NSString *_friendsID;
    NSString *_name;
    NSString *_errorText;
    NSDictionary *_footer;
    BOOL _cancellingEdit;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, context.appearance.dropdownWidth, 52)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    _avatarView = [SZFriendsAvatarView new];
    [self addSubview:_avatarView];
    __weak SZFriendsFooterView *weakSelf = self;
    _nameButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain appearance:appearance];
    _nameButton.alignment = NSTextAlignmentLeft;
    _nameButton.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawPencilIcon(rect, color); };
    _nameButton.iconSize = NSMakeSize(11, 11);
    _nameButton.iconTrailing = YES;
    _nameButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf beginEditingName];
    };
    [self addSubview:_nameButton];
    _idLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _idLabel.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    _idLabel.maximumNumberOfLines = 1;
    [self addSubview:_idLabel];
    _cpyButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain appearance:appearance];
    _cpyButton.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawCopyIcon(rect, color); };
    _cpyButton.iconSize = NSMakeSize(12, 12);
    _cpyButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf copyID];
    };
    [self addSubview:_cpyButton];
    _offersAdding = YES;
    _addButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleSecondary appearance:appearance];
    _addButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsFooterView *footer = weakSelf;
        if (footer.onAddByID) footer.onAddByID();
    };
    [self addSubview:_addButton];
    _noteLabel = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    [self addSubview:_noteLabel];
    return self;
}

- (void)setOffersAdding:(BOOL)offersAdding {
    _offersAdding = offersAdding;
    [self setNeedsLayout:YES];
}

- (void)applyFooter:(NSDictionary *)footer {
    _footer = [footer copy];
    _avatarView.avatar = SZFDict(footer, @"avatar");
    _name = SZFStr(footer, @"name");
    _friendsID = SZFStr(footer, @"friends_id");
    _nameButton.title = _name ?: (SZFStr(footer, @"name_placeholder") ?: @"");
    _nameButton.font = _name ? SZFriendsSemibold(_context.appearance.secondaryFont) : _context.appearance.secondaryFont;
    _nameButton.accessibilityLabel = [_context string:@"edit_name"].length ? [_context string:@"edit_name"] : nil;
    _nameButton.toolTip = _nameButton.accessibilityLabel;
    _idLabel.stringValue = SZFStr(footer, @"id_label") ?: @"";
    _cpyButton.title = @"";
    _cpyButton.accessibilityLabel = [_context string:@"copy_your_id"];
    _cpyButton.toolTip = _cpyButton.accessibilityLabel.length ? _cpyButton.accessibilityLabel : nil;
    _addButton.title = SZFStr(footer, @"add_label") ?: @"";
    _errorText = nil;
    _noteLabel.stringValue = SZFStr(footer, @"id_note") ?: @"";
    [self setNeedsLayout:YES];
    self.needsDisplay = YES;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat note = SZFriendsFieldHeight(_noteLabel, width - 24);
    return 10 + 32 + (note ? 6 + note : 0) + 10;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _avatarView.frame = NSMakeRect(12, 12, 28, 28);
    CGFloat addWidth = _addButton.title.length && self.offersAdding ? MAX(80, [_addButton fittingWidth]) : 0;
    _addButton.frame = NSMakeRect(width - 12 - addWidth, 12, addWidth, 28);
    _addButton.hidden = addWidth == 0;
    CGFloat textX = 48;
    CGFloat textRight = width - 12 - addWidth - 10;
    CGFloat nameWidth = MIN([_nameButton fittingWidth], textRight - textX + 8);
    // The name button reaches 8 pt left of the text so its hover fill has room; the text itself aligns at textX.
    // Name (6-24) and the ID line with its copy button (24-48) never share a pixel row: a long placeholder like
    // "Choose your name" reaches over the copy button's column, and overlapping frames split one click target.
    _nameButton.frame = NSMakeRect(textX - 8, 6, nameWidth, 18);
    if (_nameEditor) _nameEditor.frame = NSMakeRect(textX - 3, 5, MAX(120, textRight - textX), 22);
    CGFloat idWidth = MIN(SZFriendsTextWidth(_idLabel.stringValue, _idLabel.font) + 4, textRight - textX - 26);
    _idLabel.frame = NSMakeRect(textX - 2, 28, MAX(0, idWidth), 16);
    // A 24 pt target around the small glyph, centred on the ID line: 20 x 18 was fiddly to hit beside the text.
    CGFloat copyWidth = _cpyButton.title.length ? MAX(24, [_cpyButton fittingWidth]) : 24;
    _cpyButton.frame = NSMakeRect(NSMaxX(_idLabel.frame), 24, copyWidth, 24);
    _cpyButton.hidden = _friendsID.length == 0;
    SZFriendsPlace(_noteLabel, 12, 48, width - 24);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [_context.appearance.separatorColor setFill];
    NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 1));
}

#pragma mark - Copy

- (void)copyID {
    [_context copyText:_friendsID];
    NSString *copied = [_context string:@"copied"];
    if (!copied.length) return;
    _cpyButton.title = copied;
    _cpyButton.accessibilityLabel = copied;
    [self setNeedsLayout:YES];
    __weak SZFriendsFooterView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SZFriendsFooterView *footer = weakSelf;
        if (footer) [footer applyFooter:footer->_footer];
    });
}

#pragma mark - Name, edited in place

- (BOOL)isEditingName {
    return _nameEditor != nil;
}

- (void)beginEditingName {
    if (_nameEditor) return;
    _nameEditor = [NSTextField textFieldWithString:_name ?: @""];
    _nameEditor.placeholderString = SZFStr(_footer, @"name_placeholder");
    _nameEditor.font = _context.appearance.secondaryFont;
    _nameEditor.bezelStyle = NSTextFieldRoundedBezel;
    _nameEditor.delegate = self;
    _nameEditor.accessibilityLabel = [_context string:@"edit_name"];
    _nameButton.hidden = YES;
    [self addSubview:_nameEditor];
    [self layout];
    [self.window makeFirstResponder:_nameEditor];
}

- (BOOL)cancelEditingName {
    if (!_nameEditor) return NO;
    _cancellingEdit = YES;
    [self endEditing];
    return YES;
}

- (void)endEditing {
    NSTextField *editor = _nameEditor;
    _nameEditor = nil;
    if (editor.currentEditor) [self.window makeFirstResponder:nil];
    [editor removeFromSuperview];
    _nameButton.hidden = NO;
    _cancellingEdit = NO;
    [self setNeedsLayout:YES];
}

- (void)commitName {
    NSString *name = _nameEditor.stringValue ?: @"";
    [self endEditing];
    if ([name isEqualToString:_name ?: @""]) return;
    __weak SZFriendsFooterView *weakSelf = self;
    [_context.link sendIntent:@"set_name" fields:@{@"name" : name}
                        reply:^(NSDictionary *result, SZFriendsLinkError *error) {
        (void)result;
        SZFriendsFooterView *footer = weakSelf;
        if (!footer || !error.message.length) return;
        footer->_noteLabel.stringValue = error.message;
        [footer->_context announce:error.message];
        [footer.superview setNeedsLayout:YES];
    }];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)control, (void)textView;
    if (command == @selector(insertNewline:)) {
        [self commitName];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        // The inline editor is the innermost thing open: Escape closes it, and only it.
        SZFriendsForwardEscape(self);
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    (void)notification;
    // Clicking elsewhere keeps what was typed, as Finder's inline rename does; Escape discards it.
    if (_nameEditor && !_cancellingEdit) [self commitName];
}

@end
