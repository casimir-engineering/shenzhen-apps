// SZFriendsFooterView: the name friends see (renamed in place, with Save and Cancel), the ID with Copy, Add by ID.

#import "mac/SZFriendsListPage.h"

// Sees every press in the view it watches (the list page) before the pressed control does, and reports one outside
// `inside`: the rename ends when the person clicks anywhere else in the list. It never claims the press.
@interface SZFriendsPressElsewhere : NSGestureRecognizer
@property(nonatomic, weak) NSView *inside;
@property(nonatomic, copy) void (^onPressElsewhere)(void);
@end

@implementation SZFriendsPressElsewhere

- (void)mouseDown:(NSEvent *)event {
    NSView *inside = self.inside;
    if (inside && !NSPointInRect([inside convertPoint:event.locationInWindow fromView:nil], inside.bounds) &&
        self.onPressElsewhere) {
        // After the press: the field ends editing first, and the control pressed still gets its click.
        dispatch_async(dispatch_get_main_queue(), self.onPressElsewhere);
    }
    self.state = NSGestureRecognizerStateFailed;
}

@end

@implementation SZFriendsFooterView {
    SZFriendsContext *_context;
    SZFriendsAvatarView *_avatarView;
    NSTextField *_idLabel;
    NSString *_friendsID;
    NSString *_name;
    NSString *_errorText;
    NSDictionary *_footer;
    SZFriendsPressElsewhere *_pressElsewhere;
    NSString *_savedText;   // name_saved, while the name shows its check
    NSUInteger _savedRound; // which save the pending reset belongs to
}

@synthesize nameEditor = _nameEditor;

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
    _nameButton.toolTip = _savedText ?: _nameButton.accessibilityLabel;
    [self applyNameIcon];
    _idLabel.stringValue = SZFStr(footer, @"id_label") ?: @"";
    _cpyButton.title = @"";
    _cpyButton.accessibilityLabel = [_context string:@"copy_your_id"];
    _cpyButton.toolTip = _cpyButton.accessibilityLabel.length ? _cpyButton.accessibilityLabel : nil;
    _addButton.title = SZFStr(footer, @"add_label") ?: @"";
    _errorText = nil;
    [self setNeedsLayout:YES];
    self.needsDisplay = YES;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    if (_nameEditor) return 13 + MAX(26, [_nameEditor heightForWidth:width - 12 - 48]) + 13;
    return 10 + 32 + 10;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _avatarView.frame = NSMakeRect(12, 12, 28, 28);
    if (_nameEditor) {
        // Renaming takes the whole row: the field and Save where the name, the ID and Add by ID were, so even the
        // narrowest dropdown leaves room to see the name being typed.
        CGFloat editorHeight = [_nameEditor heightForWidth:width - 12 - 48];
        _nameEditor.frame = NSMakeRect(48, 13, width - 12 - 48, editorHeight);
        for (NSView *view in @[ _nameButton, _idLabel, _cpyButton, _addButton ]) view.hidden = YES;
        return;
    }
    _nameButton.hidden = _idLabel.hidden = NO;
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
    CGFloat idWidth = MIN(SZFriendsTextWidth(_idLabel.stringValue, _idLabel.font) + 4, textRight - textX - 26);
    _idLabel.frame = NSMakeRect(textX - 2, 28, MAX(0, idWidth), 16);
    // A 24 pt target around the small glyph, centred on the ID line: 20 x 18 was fiddly to hit beside the text.
    CGFloat copyWidth = _cpyButton.title.length ? MAX(24, [_cpyButton fittingWidth]) : 24;
    _cpyButton.frame = NSMakeRect(NSMaxX(_idLabel.frame), 24, copyWidth, 24);
    _cpyButton.hidden = _friendsID.length == 0;
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

// The pencil says the name can be changed; just after a rename a check says it was (name_saved, as its tooltip).
- (void)applyNameIcon {
    if (_savedText) {
        NSColor *success = _context.appearance.successColor;
        _nameButton.icon = ^(NSRect rect, NSColor *color) {
            (void)color;
            SZFriendsDrawCheckIcon(rect, success);
        };
    } else {
        _nameButton.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawPencilIcon(rect, color); };
    }
    _nameButton.needsDisplay = YES;
}

- (BOOL)showingNameSaved {
    return _savedText != nil;
}

- (void)showNameSaved:(NSString *)name {
    NSString *format = [_context string:@"name_saved"];
    if (!format.length) return;
    _savedText = [format stringByReplacingOccurrencesOfString:@"{name}" withString:name ?: @""];
    NSUInteger round = ++_savedRound;
    _nameButton.toolTip = _savedText;
    [self applyNameIcon];
    [_context announce:_savedText];
    __weak SZFriendsFooterView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsNameSavedSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       SZFriendsFooterView *footer = weakSelf;
                       if (!footer || footer->_savedRound != round) return;
                       footer->_savedText = nil;
                       footer->_nameButton.toolTip = footer->_nameButton.accessibilityLabel;
                       [footer applyNameIcon];
                   });
}

- (void)beginEditingName {
    if (_nameEditor) return;
    _savedText = nil;
    _savedRound++;
    [self applyNameIcon];
    _nameEditor = [[SZFriendsNameEditor alloc] initWithContext:_context font:_context.appearance.secondaryFont];
    _nameEditor.showsCancel = YES;
    _nameEditor.field.stringValue = _name ?: @"";
    _nameEditor.field.placeholderString = SZFStr(_footer, @"name_placeholder");
    _nameEditor.field.accessibilityLabel = [_context string:@"edit_name"];
    _nameEditor.currentName = _name;
    __weak SZFriendsFooterView *weakSelf = self;
    _nameEditor.onCancel = ^{ [weakSelf endEditing]; };
    _nameEditor.onSaved = ^(NSString *name) {
        // The helper took it: the footer shows it now, and its next snapshot says the same.
        SZFriendsFooterView *footer = weakSelf;
        if (!footer) return;
        footer->_name = [name copy];
        footer->_nameButton.title = name;
        footer->_nameButton.font = SZFriendsSemibold(footer->_context.appearance.secondaryFont);
        [footer endEditing];
        [footer showNameSaved:name];
    };
    // Clicking anywhere else, or the field losing the typing some other way, leaves the rename as Cancel does.
    SZFriendsNameEditor *editor = _nameEditor;
    void (^leave)(void) = ^{
        SZFriendsFooterView *footer = weakSelf;
        if (!footer || footer->_nameEditor != editor || editor.saving) return;
        if (editor.field.currentEditor) return; // the typing came back to the field
        [footer endEditing];
    };
    _nameEditor.onEndEditing = ^{ dispatch_async(dispatch_get_main_queue(), leave); };
    _pressElsewhere = [SZFriendsPressElsewhere new];
    _pressElsewhere.delaysPrimaryMouseButtonEvents = NO;
    _pressElsewhere.inside = _nameEditor;
    _pressElsewhere.onPressElsewhere = ^{
        SZFriendsFooterView *footer = weakSelf;
        if (footer && footer->_nameEditor == editor && !editor.saving) [footer endEditing];
    };
    [self.superview addGestureRecognizer:_pressElsewhere];
    _nameEditor.onLayoutChange = ^{ [weakSelf relayoutDropdown]; };
    _nameButton.hidden = YES;
    [self addSubview:_nameEditor];
    [self relayoutDropdown];
    [self layoutSubtreeIfNeeded];
    [self.window makeFirstResponder:_nameEditor.field];
}

- (void)relayoutDropdown {
    [self setNeedsLayout:YES];
    [self.superview setNeedsLayout:YES];
}

- (BOOL)cancelEditingName {
    if (!_nameEditor) return NO;
    [self endEditing];
    return YES;
}

- (void)endEditing {
    SZFriendsNameEditor *editor = _nameEditor;
    _nameEditor = nil;
    if (_pressElsewhere) [_pressElsewhere.view removeGestureRecognizer:_pressElsewhere];
    _pressElsewhere = nil;
    if (editor.field.currentEditor) [self.window makeFirstResponder:nil];
    [editor removeFromSuperview];
    _nameButton.hidden = NO;
    [self relayoutDropdown];
}

@end
