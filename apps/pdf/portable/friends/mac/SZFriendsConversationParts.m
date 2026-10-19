// The conversation's supporting views: message list (a drop target), `#` picker, search results, request card.

#import "mac/SZFriendsConversationPage.h"

#pragma mark - Message list

@interface SZFriendsMessageList ()
@property(nonatomic, readwrite) SZFriendsDropHighlight dropHighlight;
@property(nonatomic, copy, readwrite) NSString *dropRefusal;
@end

// Drawn over the list while a drag hovers: an outline when it can be sent, the refusal when it holds a folder, a
// link or a special file. The refusal sits on a plate of its own, opaque, so it never reads as one more line of the
// conversation: drawn straight over the list it fell between the bubbles in their text colour (UX verification,
// wave 6d). It never takes clicks, so the messages under it stay usable.
@interface SZFriendsDropOverlay : SZFriendsFlippedView
@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) NSColor *textColor, *plateColor, *plateTint;
@property(nonatomic, readonly) NSRect plateRect; // as last drawn; NSZeroRect without words
@end

@implementation SZFriendsDropOverlay
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    _plateRect = NSZeroRect;
    if (!self.text.length) return;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    NSDictionary *attributes = @{NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName : self.textColor ?: NSColor.labelColor,
                                 NSParagraphStyleAttributeName : paragraph};
    // Wrapped, within the list's width: drop_not_a_file is two sentences, wider than a narrow conversation.
    CGFloat width = MAX(0, MIN(320, NSWidth(self.bounds) - 48));
    NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin;
    NSSize size = [self.text boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX) options:options
                                       attributes:attributes].size;
    size = NSMakeSize(ceil(size.width), ceil(size.height));
    NSRect textRect = NSMakeRect(floor(NSMidX(self.bounds) - size.width / 2),
                                 floor(NSMidY(self.bounds) - size.height / 2), size.width, size.height);
    _plateRect = NSInsetRect(textRect, -14, -10);
    NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:_plateRect xRadius:8 yRadius:8];
    [(self.plateColor ?: NSColor.windowBackgroundColor) setFill];
    [plate fill];
    if (self.plateTint) {
        [self.plateTint setFill];
        [plate fill];
    }
    if (self.strokeColor) {
        [self.strokeColor setStroke];
        plate.lineWidth = 1;
        [plate stroke];
    }
    [self.text drawWithRect:textRect options:options attributes:attributes];
}
@end

@implementation SZFriendsMessageList {
    SZFriendsContext *_context;
    SZFriendsDropOverlay *_overlay;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, 300)])) return nil;
    _context = context;
    _dropRefusal = @"";
    self.drawsBackground = NO;
    self.hasVerticalScroller = YES;
    self.autohidesScrollers = YES;
    self.scrollerStyle = NSScrollerStyleOverlay;
    self.borderType = NSNoBorder;
    return self;
}

- (void)setAcceptsDrops:(BOOL)acceptsDrops {
    _acceptsDrops = acceptsDrops;
    if (acceptsDrops) [self registerForDraggedTypes:[SZFriendsDrops draggedTypesForHost:_context.host]];
    else [self unregisterDraggedTypes];
}

- (void)setDropHighlight:(SZFriendsDropHighlight)dropHighlight {
    _dropHighlight = dropHighlight;
    if (dropHighlight == SZFriendsDropHighlightNone) {
        _dropRefusal = @"";
        [_overlay removeFromSuperview];
        _overlay = nil;
        return;
    }
    if (!_overlay) {
        _overlay = [[SZFriendsDropOverlay alloc] initWithFrame:NSInsetRect(self.bounds, 6, 6)];
        _overlay.cornerRadius = 10;
        _overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_overlay positioned:NSWindowAbove relativeTo:nil];
    }
    SZFriendsAppearance *appearance = _context.appearance;
    BOOL accept = dropHighlight == SZFriendsDropHighlightAccept;
    _overlay.strokeColor = accept ? appearance.accentColor : appearance.warningColor;
    _overlay.fillColor = [(accept ? appearance.selectionColor : appearance.warningColor) colorWithAlphaComponent:0.25];
    _overlay.text = accept ? @"" : self.dropRefusal;
    _overlay.textColor = appearance.primaryTextColor;
    _overlay.plateColor = appearance.backgroundColor;
    _overlay.plateTint = [appearance.warningColor colorWithAlphaComponent:0.14];
    _overlay.needsDisplay = YES;
}

- (NSRect)dropRefusalRect {
    return _overlay ? [self convertRect:_overlay.plateRect fromView:_overlay] : NSZeroRect;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (!_acceptsDrops) return NSDragOperationNone;
    SZFriendsDropVerdict verdict = [SZFriendsDrops verdictForPasteboard:sender.draggingPasteboard host:_context.host];
    NSString *key = SZFriendsDropRefusalKey(verdict);
    self.dropRefusal = key ? [_context string:key] : @"";
    self.dropHighlight = SZFriendsDropHighlightForVerdict(verdict);
    return self.dropHighlight == SZFriendsDropHighlightAccept ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    (void)sender;
    return self.dropHighlight == SZFriendsDropHighlightAccept ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropHighlight = SZFriendsDropHighlightNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (self.dropHighlight != SZFriendsDropHighlightAccept) return NO;
    __weak SZFriendsMessageList *weakSelf = self;
    [SZFriendsDrops readItemsFromPasteboard:sender.draggingPasteboard host:_context.host
                           promiseDirectory:_context.promiseDirectory
                                 completion:^(NSArray<SZFriendsAttachableItem *> *items, BOOL refusedFolder) {
                                     SZFriendsMessageList *list = weakSelf;
                                     if (list.onDropItems && !refusedFolder && items.count) list.onDropItems(items);
                                 }];
    return YES;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropHighlight = SZFriendsDropHighlightNone;
}

@end

#pragma mark - Two-line list rows (picker items, search results)

@interface SZFriendsTwoLineButton : SZFriendsButton
@property(nonatomic, copy) NSString *glyphLabel;   // nil: no document glyph
@property(nonatomic, copy) NSString *firstLine;
@property(nonatomic, copy) NSString *firstLineTrailing;
@property(nonatomic, copy) NSAttributedString *secondLine;
@end

@implementation SZFriendsTwoLineButton
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsAppearance *appearance = self.theme;
    // The keyboard's selection in the selection colour; the pointer's hover in the host's hover colour.
    if (self.selectedLook || self.hovered || self.cell.isHighlighted) {
        [(self.selectedLook ? appearance.selectionColor : appearance.hoverColor) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:7 yRadius:7] fill];
    }
    CGFloat x = 8;
    if (self.glyphLabel) {
        SZFriendsDrawDocumentGlyph(NSMakeRect(x, floor((NSHeight(self.bounds) - 30) / 2), 24, 30), self.glyphLabel,
                                   SZFriendsDynamicColor(0x3a3a46, 0x3a3a46));
        x += 34;
    }
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *first = @{NSFontAttributeName : SZFriendsSemibold(appearance.bodyFont),
                            NSForegroundColorAttributeName : appearance.primaryTextColor,
                            NSParagraphStyleAttributeName : paragraph};
    NSDictionary *trailing = @{NSFontAttributeName : appearance.captionFont,
                               NSForegroundColorAttributeName : appearance.secondaryTextColor};
    CGFloat trailingWidth = self.firstLineTrailing.length
                                ? ceil([self.firstLineTrailing sizeWithAttributes:trailing].width) + 8 : 0;
    CGFloat width = NSWidth(self.bounds) - x - 8;
    [self.firstLine drawWithRect:NSMakeRect(x, 6, width - trailingWidth, 18)
                         options:NSStringDrawingUsesLineFragmentOrigin attributes:first];
    if (trailingWidth) [self.firstLineTrailing drawAtPoint:NSMakePoint(NSWidth(self.bounds) - trailingWidth, 8)
                                            withAttributes:trailing];
    NSMutableAttributedString *second = [self.secondLine mutableCopy];
    [second addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, second.length)];
    [second drawWithRect:NSMakeRect(x, 24, width, NSHeight(self.bounds) - 28)
                 options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
}
@end

#pragma mark - `#` picker

@interface SZFriendsAttachPicker () <NSSearchFieldDelegate>
@end

@implementation SZFriendsAttachPicker {
    SZFriendsContext *_context;
    NSTextField *_keys;
    NSTextField *_note;
    NSMutableArray<SZFriendsTwoLineButton *> *_rows;
    NSArray<SZFriendsAttachableItem *> *_items;
    NSUInteger _generation;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
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
    _searchField.placeholderString = context.host.friendsAttachPlaceholder;
    [self addSubview:_searchField];
    _keys = SZFriendsLabel([context string:@"attach_keys"], appearance.captionFont, appearance.secondaryTextColor);
    _note = SZFriendsLabel([context string:@"attach_note"], appearance.captionFont, appearance.secondaryTextColor);
    _note.alignment = NSTextAlignmentRight;
    [self addSubview:_keys];
    [self addSubview:_note];
    _rows = [NSMutableArray array];
    _items = @[];
    return self;
}

- (NSArray<SZFriendsAttachableItem *> *)items {
    return _items;
}

- (NSArray<SZFriendsButton *> *)itemButtons {
    return [_rows copy];
}

- (void)reloadForQuery:(NSString *)query {
    NSUInteger generation = ++_generation;
    __weak SZFriendsAttachPicker *weakSelf = self;
    [_context.host friendsAttachableItemsMatching:query ?: @""
                                       completion:^(NSArray<SZFriendsAttachableItem *> *items) {
                                           SZFriendsAttachPicker *picker = weakSelf;
                                           // A slower answer to an older query must not replace a newer one.
                                           if (!picker || generation != picker->_generation) return;
                                           [picker showItems:items ?: @[]];
                                       }];
}

- (void)showItems:(NSArray<SZFriendsAttachableItem *> *)items {
    _items = [items subarrayWithRange:NSMakeRange(0, MIN(items.count, 6u))];
    for (NSView *row in _rows) [row removeFromSuperview];
    [_rows removeAllObjects];
    __weak SZFriendsAttachPicker *weakSelf = self;
    [_items enumerateObjectsUsingBlock:^(SZFriendsAttachableItem *item, NSUInteger index, BOOL *stop) {
        (void)stop;
        SZFriendsTwoLineButton *row = [SZFriendsTwoLineButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain
                                                                  appearance:self->_context.appearance];
        row.glyphLabel = item.kindLabel ?: @"";
        row.firstLine = item.title;
        row.secondLine = [[NSAttributedString alloc]
            initWithString:item.detail ?: @""
                attributes:@{NSFontAttributeName : self->_context.appearance.secondaryFont,
                             NSForegroundColorAttributeName : self->_context.appearance.secondaryTextColor}];
        row.accessibilityLabel = item.title;
        row.onPress = ^(SZFriendsButton *button) {
            (void)button;
            weakSelf.selectedIndex = (NSInteger)index;
            [weakSelf chooseSelected];
        };
        [self->_rows addObject:row];
        [self addSubview:row];
    }];
    self.selectedIndex = 0;
    if (self.superview) [self.superview setNeedsLayout:YES];
    [self setNeedsLayout:YES];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = _rows.count ? MAX(0, MIN((NSInteger)_rows.count - 1, selectedIndex)) : -1;
    [_rows enumerateObjectsUsingBlock:^(SZFriendsTwoLineButton *row, NSUInteger index, BOOL *stop) {
        (void)stop;
        row.selectedLook = (NSInteger)index == self->_selectedIndex;
    }];
}

- (void)chooseSelected {
    if (_selectedIndex < 0 || _selectedIndex >= (NSInteger)_items.count) return;
    if (self.onChoose) self.onChoose(_items[(NSUInteger)_selectedIndex]);
}

- (CGFloat)preferredHeight {
    return 10 + 28 + 8 + _rows.count * 46 + (_rows.count ? 4 : 0) + 18 + 10;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _searchField.frame = NSMakeRect(10, 10, width - 20, 28);
    CGFloat y = 46;
    for (SZFriendsTwoLineButton *row in _rows) {
        row.frame = NSMakeRect(6, y, width - 12, 44);
        y += 46;
    }
    y += _rows.count ? 4 : 0;
    CGFloat half = floor((width - 28) / 2);
    _keys.frame = NSMakeRect(14, y, half, 16);
    _note.frame = NSMakeRect(14 + half, y, width - 28 - half, 16);
}

- (void)controlTextDidChange:(NSNotification *)notification {
    (void)notification;
    [self reloadForQuery:_searchField.stringValue];
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

#pragma mark - Conversation search results

@implementation SZFriendsSearchResultsView {
    SZFriendsContext *_context;
    NSMutableArray<SZFriendsTwoLineButton *> *_rows;
    NSTextField *_emptyLabel;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 380, 120)])) return nil;
    _context = context;
    self.fillColor = context.appearance.controlColor;
    self.strokeColor = context.appearance.controlBorderColor;
    self.cornerRadius = 10;
    _rows = [NSMutableArray array];
    _emptyLabel = SZFriendsLabel(@"", context.appearance.secondaryFont, context.appearance.secondaryTextColor);
    _emptyLabel.alignment = NSTextAlignmentCenter;
    [self addSubview:_emptyLabel];
    return self;
}

- (NSArray<SZFriendsButton *> *)resultButtons {
    return [_rows copy];
}

- (void)applyResult:(NSDictionary *)result {
    for (NSView *row in _rows) [row removeFromSuperview];
    [_rows removeAllObjects];
    SZFriendsAppearance *appearance = _context.appearance;
    __weak SZFriendsSearchResultsView *weakSelf = self;
    for (NSDictionary *entry in SZFArr(result, @"results")) {
        SZFriendsTwoLineButton *row = [SZFriendsTwoLineButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain
                                                                  appearance:appearance];
        row.firstLine = SZFStr(entry, @"sender_label") ?: @"";
        row.firstLineTrailing = SZFStr(entry, @"time_label");
        row.secondLine = SZFriendsRichText(SZFArr(entry, @"excerpt"), appearance.secondaryFont,
                                           appearance.secondaryTextColor, appearance);
        // Who and the matching words, as the snapshot gives them; the view composes no sentence of its own.
        row.accessibilityLabel = row.firstLine;
        row.accessibilityValue = row.secondLine.string;
        NSString *conversationID = SZFStr(entry, @"conversation_id"), *messageID = SZFStr(entry, @"message_id");
        row.onPress = ^(SZFriendsButton *button) {
            (void)button;
            SZFriendsSearchResultsView *view = weakSelf;
            if (view.onChoose && conversationID && messageID) view.onChoose(conversationID, messageID);
        };
        [_rows addObject:row];
        [self addSubview:row];
    }
    _emptyLabel.stringValue = _rows.count ? @"" : (SZFStr(result, @"empty_label") ?: @"");
    [self setNeedsLayout:YES];
}

- (CGFloat)preferredHeight {
    if (!_rows.count) return _emptyLabel.stringValue.length ? 44 : 0;
    return MIN(6, _rows.count) * 48 + 8;
}

- (void)layout {
    [super layout];
    CGFloat y = 4;
    for (SZFriendsTwoLineButton *row in _rows) {
        row.frame = NSMakeRect(4, y, NSWidth(self.bounds) - 8, 46);
        y += 48;
    }
    _emptyLabel.frame = NSMakeRect(10, 13, NSWidth(self.bounds) - 20, 18);
    _emptyLabel.hidden = _rows.count > 0;
}

@end
