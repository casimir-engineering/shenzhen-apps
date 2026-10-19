// SZFriendsMentionPicker: `@` in the composer, a searchable list of the friends a mention may name.
//
// WHY its own `list` subscription rather than the list page's: the list page is not on screen under a conversation,
// and the picker's filter must not change what the list shows when the person goes back (PROTOCOL.md § Views, list).

#import "mac/SZFriendsMentionViews.h"

// At most this many rows show at once; typing narrows them, as in the `#` picker.
static const NSUInteger SZFMentionRowsShown = 6;
static const CGFloat SZFMentionRowHeight = 34;

// One friend: avatar and name. The whole row is one hit target.
@interface SZFMentionRow : SZFriendsButton
@property(nonatomic, copy) NSDictionary *row;
@end

@implementation SZFMentionRow
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsAppearance *appearance = self.theme;
    // The keyboard's choice in the selection colour, the pointer's in the hover colour (as the `#` picker).
    if (self.selectedLook || self.hovered || self.cell.isHighlighted) {
        [(self.selectedLook ? appearance.selectionColor : appearance.hoverColor) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:7 yRadius:7] fill];
    }
    CGFloat height = NSHeight(self.bounds);
    NSRect avatarRect = NSMakeRect(8, floor((height - 24) / 2), 24, 24);
    SZFriendsDrawAvatarInView(SZFDict(self.row, @"avatar"), avatarRect, self);
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{NSFontAttributeName : appearance.bodyFont,
                                 NSForegroundColorAttributeName : appearance.primaryTextColor,
                                 NSParagraphStyleAttributeName : paragraph};
    NSString *title = SZFStr(self.row, @"title") ?: @"";
    CGFloat lineHeight = ceil(appearance.bodyFont.ascender - appearance.bodyFont.descender);
    [title drawWithRect:NSMakeRect(40, floor((height - lineHeight) / 2), NSWidth(self.bounds) - 48, lineHeight)
                options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes];
}
@end

@interface SZFriendsMentionPicker () <NSSearchFieldDelegate>
@end

@implementation SZFriendsMentionPicker {
    SZFriendsContext *_context;
    NSString *_token;
    NSTextField *_emptyLabel;
    NSMutableArray<SZFMentionRow *> *_buttons;
}

- (instancetype)initWithContext:(SZFriendsContext *)context note:(NSString *)note {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 380, 200)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    self.fillColor = appearance.controlColor;
    self.strokeColor = appearance.controlBorderColor;
    self.cornerRadius = 10;
    _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(10, 10, 360, 28)];
    _searchField.bezelStyle = NSTextFieldRoundedBezel;
    _searchField.font = appearance.bodyFont;
    _searchField.sendsSearchStringImmediately = YES;
    _searchField.delegate = self;
    // The list's own words: the filter matches names and IDs, as the list's search does.
    _searchField.placeholderString = [context string:@"search_placeholder"];
    [self addSubview:_searchField];
    _emptyLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _noteLabel = SZFriendsLabel(note ?: @"", appearance.captionFont, appearance.secondaryTextColor);
    [self addSubview:_emptyLabel];
    [self addSubview:_noteLabel];
    _buttons = [NSMutableArray array];
    _rows = @[];
    _selectedIndex = -1;
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)subscribed {
    return _token != nil;
}

- (NSArray<SZFriendsButton *> *)rowButtons {
    return [_buttons copy];
}

- (void)start {
    if (_token) return;
    __weak SZFriendsMentionPicker *weakSelf = self;
    _token = [_context.link subscribeToView:@"list" params:nil handler:^(NSDictionary *data, NSInteger rev) {
        (void)rev;
        [weakSelf applyList:data];
    }];
}

- (void)stop {
    if (_token) [_context.link unsubscribe:_token];
    _token = nil;
}

- (void)applyList:(NSDictionary *)data {
    // Only people a mention may name: friends with a Friends ID. The helper says which (rows[].mentionable).
    NSMutableArray *rows = [NSMutableArray array];
    for (id row in SZFArr(data, @"rows"))
        if (SZFBool(row, @"mentionable") && SZFStr(row, @"conversation_id").length && rows.count < SZFMentionRowsShown)
            [rows addObject:row];
    NSString *previous = _selectedIndex >= 0 && _selectedIndex < (NSInteger)_rows.count
                             ? SZFStr(_rows[(NSUInteger)_selectedIndex], @"conversation_id") : nil;
    _rows = rows;
    for (NSView *button in _buttons) [button removeFromSuperview];
    [_buttons removeAllObjects];
    __weak SZFriendsMentionPicker *weakSelf = self;
    NSInteger keep = 0;
    for (NSUInteger index = 0; index < rows.count; index++) {
        SZFMentionRow *button = [SZFMentionRow buttonWithTitle:@"" style:SZFriendsButtonStylePlain
                                                    appearance:_context.appearance];
        button.row = rows[index];
        button.accessibilityLabel = SZFStr(rows[index], @"title");
        button.onPress = ^(SZFriendsButton *pressed) {
            (void)pressed;
            weakSelf.selectedIndex = (NSInteger)index;
            [weakSelf chooseSelected];
        };
        if (previous && [SZFStr(rows[index], @"conversation_id") isEqualToString:previous]) keep = (NSInteger)index;
        [_buttons addObject:button];
        [self addSubview:button];
    }
    // When no one matches, the helper's words for it (a filter that matches nobody); nothing of the views' own.
    _emptyLabel.stringValue = rows.count ? @"" : (SZFStr(SZFDict(data, @"empty"), @"title") ?: @"");
    self.selectedIndex = keep;
    for (NSView *view = self.superview; view; view = view.superview) view.needsLayout = YES;
    self.needsLayout = YES;
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = _buttons.count ? MAX(0, MIN((NSInteger)_buttons.count - 1, selectedIndex)) : -1;
    [_buttons enumerateObjectsUsingBlock:^(SZFMentionRow *button, NSUInteger index, BOOL *stop) {
        (void)stop;
        button.selectedLook = (NSInteger)index == self->_selectedIndex;
        button.needsDisplay = YES;
    }];
}

- (void)chooseSelected {
    if (_selectedIndex < 0 || _selectedIndex >= (NSInteger)_rows.count) return;
    if (self.onChoose) self.onChoose(_rows[(NSUInteger)_selectedIndex]);
}

- (CGFloat)noteHeightForWidth:(CGFloat)width {
    return SZFriendsFieldHeight(_noteLabel, width - 28);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat body = _buttons.count ? _buttons.count * (SZFMentionRowHeight + 2) + 2
                                  : (_emptyLabel.stringValue.length ? 26 : 0);
    CGFloat note = [self noteHeightForWidth:width];
    return 10 + 28 + 6 + body + (note ? note + 8 : 0) + 8;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _searchField.frame = NSMakeRect(10, 10, width - 20, 28);
    CGFloat y = 44;
    for (SZFMentionRow *button in _buttons) {
        button.frame = NSMakeRect(6, y, width - 12, SZFMentionRowHeight);
        y += SZFMentionRowHeight + 2;
    }
    _emptyLabel.hidden = _buttons.count > 0 || _emptyLabel.stringValue.length == 0;
    if (!_emptyLabel.hidden) {
        _emptyLabel.frame = NSMakeRect(14, y + 4, width - 28, 18);
        y += 26;
    }
    if (_buttons.count) y += 2;
    CGFloat note = [self noteHeightForWidth:width];
    _noteLabel.hidden = note == 0;
    if (note) _noteLabel.frame = NSMakeRect(14, y + 2, width - 28, note);
}

- (void)controlTextDidChange:(NSNotification *)notification {
    (void)notification;
    // The helper filters by names and IDs as the list's search does; each keystroke is local and costs nothing.
    if (_token) [_context.link setFilter:_searchField.stringValue ?: @"" forSubscription:_token];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)control, (void)textView;
    if (command == @selector(moveDown:)) self.selectedIndex += 1;
    else if (command == @selector(moveUp:)) self.selectedIndex -= 1;
    else if (command == @selector(insertNewline:)) [self chooseSelected];
    else if (command == @selector(cancelOperation:)) SZFriendsForwardEscape(self);
    else return NO;
    return YES;
}

@end
