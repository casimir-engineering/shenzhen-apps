// SZFriendsRowView: a person's row, drawn whole so the row is one contiguous hit area and one drop target.

#import "mac/SZFriendsRowView.h"

const CGFloat SZFriendsRowHeight = 50;

@interface SZFriendsRowView ()
@property(nonatomic, readwrite) SZFriendsDropHighlight dropHighlight;
@end

@implementation SZFriendsRowView {
    __weak SZFriendsContext *_context;
    NSDictionary *_avatar;
    NSString *_rowTitle;
    NSString *_subtitle;
    NSString *_timeLabel;
    NSString *_waitingLabel;
    NSString *_statusLabel;
    NSDictionary *_route;
    NSString *_dropRefusal;
    NSString *_dragRefusal; // why the files over a row that takes them would not go (a folder's, a link's words)
    NSString *_idConfirmedLabel;
    BOOL _unread;
    BOOL _listRow;
    NSRect _routeRect;
    NSRect _idConfirmedRect;
    NSString *_dragConversationID; // whom the row showed when the drag over it entered; nil outside a drag
}

static BOOL SZFSamePerson(NSString *a, NSString *b) {
    return a == b || [a isEqualToString:b];
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 380, SZFriendsRowHeight)])) return nil;
    _context = context;
    self.theme = context.appearance;
    self.style = SZFriendsButtonStylePlain;
    self.title = @"";
    // A click goes to whom the row showed when the mouse went down, or to nobody (SZFriendsButton pressSubject).
    __weak SZFriendsRowView *weakSelf = self;
    self.pressSubject = ^id {
        return weakSelf.conversationID;
    };
    return self;
}

- (void)configureWithListRow:(NSDictionary *)row {
    _listRow = YES;
    _avatar = SZFDict(row, @"avatar");
    _rowTitle = SZFStr(row, @"title") ?: @"";
    _subtitle = SZFStr(row, @"subtitle") ?: @"";
    _timeLabel = SZFStr(row, @"time_label") ?: @"";
    _waitingLabel = SZFStr(SZFDict(row, @"waiting"), @"label");
    _route = SZFDict(row, @"route");
    _unread = SZFBool(row, @"unread");
    // PROTOCOL.md list_row style; any other value is drawn as normal.
    _muted = [SZFStr(row, @"style") isEqualToString:@"muted"];
    _statusLabel = nil;
    NSString *conversationID = SZFStr(row, @"conversation_id");
    // Rows are reused by position: an armed pill belongs to the person it was armed for, never to whoever takes
    // the row's place when the list reorders.
    if (![conversationID isEqualToString:_conversationID]) [_actionsView disarm];
    _conversationID = [conversationID copy];
    [self dropPersonChanged];
    _dropLabel = [SZFStr(row, @"drop_label") copy];
    _dropRefusal = [SZFStr(row, @"drop_refusal") copy];
    // list_row id_confirmed: the Friends server confirmed this person holds the Friends ID; id_confirmed_label is
    // the mark's tooltip (the row's accessibility_label already says it).
    _idConfirmed = SZFBool(row, @"id_confirmed");
    _idConfirmedLabel = [SZFStr(row, @"id_confirmed_label") copy];
    [self.accessoryButton removeFromSuperview];
    _accessoryButton = nil;
    [self applyRowActions:SZFArr(row, @"actions")];
    self.accessibilityLabel = SZFStr(row, @"accessibility_label") ?: _rowTitle;
    [self updateDragRegistration];
    [self setNeedsLayout:YES];
    self.needsDisplay = YES;
}

- (void)configureWithNearbyPerson:(NSDictionary *)person {
    _listRow = NO;
    _avatar = SZFDict(person, @"avatar");
    _rowTitle = SZFStr(person, @"title") ?: @"";
    _subtitle = SZFStr(person, @"subtitle") ?: @"";
    _timeLabel = nil;
    _waitingLabel = nil;
    _route = nil;
    _unread = NO;
    _muted = NO;
    _statusLabel = SZFStr(person, @"status_label");
    _conversationID = [SZFStr(person, @"conversation_id") copy];
    [self dropPersonChanged];
    _dropLabel = nil;
    _dropRefusal = nil;
    _idConfirmed = NO;
    _idConfirmedLabel = nil;
    [self.accessoryButton removeFromSuperview];
    _accessoryButton = nil;
    [self applyRowActions:@[]];
    NSDictionary *action = SZFDict(person, @"action");
    if ([SZFriendsContext knowsAction:SZFStr(action, @"action")]) {
        _accessoryButton = [SZFriendsButton buttonWithTitle:SZFStr(action, @"label")
                                                      style:SZFriendsButtonStyleNamed(SZFStr(action, @"style"))
                                                 appearance:self.theme];
        [self addSubview:_accessoryButton];
    }
    // A stranger with no conversation yet is not clickable; only their Request button is.
    self.enabled = _conversationID != nil;
    self.accessibilityLabel = SZFStr(person, @"accessibility_label") ?: _rowTitle;
    [self updateDragRegistration];
    [self setNeedsLayout:YES];
    self.needsDisplay = YES;
}

// PROTOCOL.md list_row actions: a request row's own buttons, drawn in place of its time and waiting label.
- (void)applyRowActions:(NSArray *)actions {
    if (actions.count && !_actionsView) {
        _actionsView = [[SZFriendsRowActionsView alloc] initWithContext:_context];
        _actionsView.pressSubject = self.pressSubject;
        __weak SZFriendsRowView *weakSelf = self;
        _actionsView.onAction = ^(NSDictionary *action) {
            SZFriendsRowView *row = weakSelf;
            if (row.onRowAction) row.onRowAction(row, action);
        };
        // The armed pill is wider than the icon: the text column gives way and the row redraws around it.
        _actionsView.onWidthChange = ^{
            [weakSelf setNeedsLayout:YES];
            weakSelf.needsDisplay = YES;
        };
        [self addSubview:_actionsView];
    }
    BOOL shown = [_actionsView applyActions:actions];
    _actionsView.hidden = !shown;
    _actionsView.inactive = self.dimmed;
}

- (BOOL)showsRowActions {
    return _actionsView && !_actionsView.hidden;
}

// Leaving the row turns an armed pill back, so a "Block?" never waits under a pointer that went elsewhere.
- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    [_actionsView disarm];
}

// The row is one button to VoiceOver; its own buttons are listed as its children so they can be reached too.
- (NSArray *)accessibilityChildren {
    NSMutableArray *children = [NSMutableArray arrayWithArray:[super accessibilityChildren] ?: @[]];
    NSMutableArray<NSView *> *own = [NSMutableArray array];
    if ([self showsRowActions]) [own addObjectsFromArray:_actionsView.buttons];
    if (_accessoryButton) [own addObject:_accessoryButton];
    for (NSView *view in own)
        if (![children containsObject:view]) [children addObject:view];
    return children;
}

- (CGFloat)avatarX {
    return _listRow ? 22 : 8;
}

- (void)layout {
    [super layout];
    [self removeAllToolTips];
    _routeRect = NSZeroRect;
    if (_accessoryButton) {
        CGFloat width = MAX(64, [_accessoryButton fittingWidth]);
        _accessoryButton.frame = NSMakeRect(NSWidth(self.bounds) - 8 - width, floor((NSHeight(self.bounds) - 28) / 2),
                                            width, 28);
    }
    if ([self showsRowActions]) {
        CGFloat width = [_actionsView fittingWidth];
        _actionsView.frame = NSMakeRect(NSWidth(self.bounds) - 8 - width, floor((NSHeight(self.bounds) - 28) / 2),
                                        width, 28);
    }
    if (SZFStr(_route, @"label") && !_waitingLabel && ![self showsRowActions]) {
        _routeRect = NSMakeRect(NSWidth(self.bounds) - 8 - 13, 27, 13, 13);
        [self addToolTipRect:NSInsetRect(_routeRect, -3, -3) owner:self userData:NULL];
    }
    // The confirmed-ID check sits right after the title, wherever the title's width puts it; the title line carries
    // the tooltip and answers only when the pointer is on the check (as last drawn).
    if (_idConfirmed && _idConfirmedLabel.length)
        [self addToolTipRect:NSMakeRect(0, 0, NSWidth(self.bounds), NSMidY(self.bounds)) owner:self userData:(void *)1];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view, (void)tag;
    if (data) return NSPointInRect(point, NSInsetRect(_idConfirmedRect, -3, -3)) ? (_idConfirmedLabel ?: @"") : @"";
    return SZFStr(_route, @"label") ?: @"";
}

// While files are dragged, or while "Send 2 files to…" waits for a click, a row that cannot receive them says why
// under the pointer ("Lena isn't your friend yet"), in the helper's words; without them it only fades.
- (NSString *)refusalText {
    if (!_listRow || _dropLabel || !_dropRefusal.length) return nil;
    BOOL dragging = self.dropHighlight == SZFriendsDropHighlightRefuse;
    return dragging || (self.dimmed && self.hovered) ? _dropRefusal : nil;
}

- (NSString *)dropPillText {
    if (!_dropLabel || self.dropHighlight == SZFriendsDropHighlightNone) return nil;
    if (self.dropHighlight == SZFriendsDropHighlightAccept) return _dropLabel.length ? _dropLabel : nil;
    return self.dropRefusalShownAbove || !_dragRefusal.length ? nil : _dragRefusal;
}

- (void)setDropRefusalShownAbove:(BOOL)shown {
    if (_dropRefusalShownAbove == shown) return;
    _dropRefusalShownAbove = shown;
    self.needsDisplay = YES;
}

// Where the waiting bar is drawn: the row's leading edge, clear of its rounded corners.
- (NSRect)waitingBarRect {
    return NSMakeRect(1, 9, 3, MAX(0, NSHeight(self.bounds) - 18));
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.needsDisplay = YES;
}

#pragma mark - Drawing

static void SZFDrawLine(NSString *text, NSRect rect, NSFont *font, NSColor *color, NSTextAlignment alignment) {
    if (!text.length) return;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    paragraph.alignment = alignment;
    NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine;
    [text drawWithRect:rect
               options:options
            attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : color,
                         NSParagraphStyleAttributeName : paragraph}];
}

// A pill too wide for one line beside the name (drop_not_a_file is two sentences) wraps within `maxWidth`, centred
// on `midY`, so the name keeps its room rather than the reason being cut short.
static CGFloat SZFWrappedPill(NSString *text, CGFloat right, CGFloat midY, CGFloat maxWidth, NSFont *font,
                              NSColor *fill, NSColor *textColor) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    NSDictionary *attributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : textColor,
                                 NSParagraphStyleAttributeName : paragraph};
    NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin;
    NSRect used = [text boundingRectWithSize:NSMakeSize(maxWidth - 10, CGFLOAT_MAX) options:options
                                  attributes:attributes];
    CGFloat width = ceil(NSWidth(used)) + 10, height = ceil(NSHeight(used)) + 4;
    NSRect pill = NSMakeRect(right - width, floor(midY - height / 2), width, height);
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:5 yRadius:5] fill];
    [text drawWithRect:NSInsetRect(pill, 5, 2) options:options attributes:attributes];
    return width;
}

static CGFloat SZFPill(NSString *text, CGFloat right, CGFloat y, NSFont *font, NSColor *fill, NSColor *textColor) {
    CGFloat width = SZFriendsTextWidth(text, font) + 10;
    NSRect pill = NSMakeRect(right - width, y, width, ceil(font.pointSize + 6));
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:4 yRadius:4] fill];
    SZFDrawLine(text, NSMakeRect(NSMinX(pill), NSMinY(pill) + 2, width, NSHeight(pill)), font, textColor,
                NSTextAlignmentCenter);
    return width;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsAppearance *appearance = self.theme;
    NSRect bounds = self.bounds;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.75, 0.75) xRadius:8 yRadius:8];
    SZFriendsDropHighlight drop = self.dropHighlight;
    NSString *refusal = [self refusalText];
    if (drop == SZFriendsDropHighlightAccept) {
        [appearance.selectionColor setFill];
        [shape fill];
        [appearance.accentColor setStroke];
        shape.lineWidth = 1.5;
        [shape stroke];
    } else if (drop == SZFriendsDropHighlightRefuse && _dropLabel) {
        [[appearance.warningColor colorWithAlphaComponent:0.18] setFill]; // a folder over a row that takes files
        [shape fill];
    } else if (self.enabled && !self.dimmed && (self.hovered || self.cell.isHighlighted)) {
        // The host's hover colour, never the selection colour: in ShenzhenPDF that marks the selected chapter or
        // chat, and a waiting row tinted with it looked selected while every hovered row looked like it was waiting.
        [appearance.hoverColor setFill];
        [shape fill];
    }

    NSFont *refusalFont = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    CGFloat reserved = refusal ? SZFriendsTextWidth(refusal, refusalFont) + 10 : 0;
    if (!self.dimmed) {
        [self drawContent:bounds reserving:reserved];
    } else {
        CGContextRef context = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(context);
        CGContextSetAlpha(context, 0.4);
        CGContextBeginTransparencyLayer(context, NULL);
        [self drawContent:bounds reserving:reserved];
        CGContextEndTransparencyLayer(context);
        CGContextRestoreGState(context);
    }
    // At full strength over a faded row: the reason is the one thing on it meant to be read.
    if (refusal)
        SZFPill(refusal, NSWidth(bounds) - 8, NSMidY(bounds) - 10, refusalFont, appearance.warningColor,
                appearance.backgroundColor);
}

- (void)setDimmed:(BOOL)dimmed {
    _dimmed = dimmed;
    // Faded rows (the send picker's requests) take no answer either; the buttons fade with the row.
    _actionsView.inactive = dimmed;
    self.needsDisplay = YES;
}

- (void)drawContent:(NSRect)bounds reserving:(CGFloat)reserved {
    SZFriendsAppearance *appearance = self.theme;
    SZFriendsDropHighlight drop = self.dropHighlight;
    CGFloat midY = NSMidY(bounds);
    // Waiting for an answer: a bar at the leading edge (with the pill), which no hover state can imitate. Part of
    // the content, so it fades with a row that cannot take files.
    if (_waitingLabel && drop == SZFriendsDropHighlightNone) {
        [appearance.accentColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:[self waitingBarRect] xRadius:1.5 yRadius:1.5] fill];
    }
    if (_listRow && _unread) {
        [appearance.accentColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(8.5, midY - 3.5, 7, 7)] fill];
    }
    CGFloat avatarX = [self avatarX];
    NSRect avatarRect = NSMakeRect(avatarX, midY - 17, 34, 34);
    if (_muted) {
        // One transparency layer, so the avatar's overlapping shapes fade as a whole instead of showing through.
        CGContextRef context = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(context);
        CGContextSetAlpha(context, 0.45);
        CGContextBeginTransparencyLayer(context, NULL);
        SZFriendsDrawAvatarInView(_avatar, avatarRect, self);
        CGContextEndTransparencyLayer(context);
        CGContextRestoreGState(context);
    } else {
        SZFriendsDrawAvatarInView(_avatar, avatarRect, self);
    }

    // Right column first, so the text column takes what is left.
    CGFloat right = NSWidth(bounds) - 8;
    CGFloat rightWidth = 0;
    NSFont *pillFont = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
    if (reserved > 0) {
        rightWidth = reserved; // the refusal pill, drawn over this column by -drawRect:
    } else if (drop != SZFriendsDropHighlightNone && _dropLabel) {
        NSString *text = [self dropPillText];
        NSFont *font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
        NSColor *fill = drop == SZFriendsDropHighlightAccept ? appearance.accentColor : appearance.warningColor;
        CGFloat limit = floor(NSWidth(bounds) * 0.55);
        if (text.length && SZFriendsTextWidth(text, font) + 10 > limit)
            rightWidth = SZFWrappedPill(text, right, midY, limit, [NSFont systemFontOfSize:11 weight:NSFontWeightBold],
                                        fill, appearance.backgroundColor);
        else if (text.length)
            rightWidth = SZFPill(text, right, midY - 10, font, fill, appearance.backgroundColor);
    } else if (_accessoryButton) {
        rightWidth = NSWidth(_accessoryButton.frame);
    } else if ([self showsRowActions]) {
        rightWidth = NSWidth(_actionsView.frame);
    } else if (_listRow) {
        NSFont *timeFont = appearance.captionFont;
        CGFloat timeWidth = SZFriendsTextWidth(_timeLabel, timeFont);
        SZFDrawLine(_timeLabel, NSMakeRect(right - timeWidth, 8, timeWidth, 15), timeFont,
                    appearance.secondaryTextColor, NSTextAlignmentRight);
        rightWidth = timeWidth;
        if (_waitingLabel) {
            rightWidth = MAX(rightWidth, SZFPill(_waitingLabel, right, 26, pillFont, appearance.accentColor,
                                                 appearance.backgroundColor));
        } else if (!NSIsEmptyRect(_routeRect)) {
            SZFriendsDrawRouteIcon(SZFriendsRouteGlyph(_route), _routeRect,
                                   SZFriendsRouteColor(appearance, SZFStr(_route, @"kind")));
        }
    } else if (_statusLabel.length) {
        NSFont *font = appearance.secondaryFont;
        rightWidth = SZFriendsTextWidth(_statusLabel, font);
        SZFDrawLine(_statusLabel, NSMakeRect(right - rightWidth, midY - 8, rightWidth, 16), font,
                    appearance.secondaryTextColor, NSTextAlignmentRight);
    }

    CGFloat textX = avatarX + 34 + 10;
    CGFloat textWidth = MAX(0, right - (rightWidth ? rightWidth + 10 : 0) - textX);
    NSColor *subtitleColor = _waitingLabel ? appearance.accentColor : appearance.secondaryTextColor;
    NSFont *titleFont = SZFriendsSemibold(appearance.bodyFont);
    CGFloat checkSpace = _idConfirmed ? 14 : 0;
    CGFloat titleWidth = MIN(SZFriendsTextWidth(_rowTitle, titleFont), MAX(0, textWidth - checkSpace));
    SZFDrawLine(_rowTitle, NSMakeRect(textX, midY - 18, titleWidth, 18), titleFont,
                _muted ? appearance.secondaryTextColor : appearance.primaryTextColor, NSTextAlignmentLeft);
    // The small check beside a Friends ID the server confirmed is this person's.
    _idConfirmedRect = _idConfirmed ? NSMakeRect(textX + titleWidth + 3, midY - 14, 10, 10) : NSZeroRect;
    if (_idConfirmed) SZFriendsDrawCheckIcon(_idConfirmedRect, appearance.successColor);
    SZFDrawLine(_subtitle, NSMakeRect(textX, midY + 1, textWidth, 17), appearance.secondaryFont, subtitleColor,
                NSTextAlignmentLeft);
}

#pragma mark - Drop target

// A row that refuses files still listens to drags when it can say why, so the reason shows under the pointer.
- (void)updateDragRegistration {
    if (_dropLabel || (_listRow && _dropRefusal.length))
        [self registerForDraggedTypes:[SZFriendsDrops draggedTypesForHost:_context.host]];
    else
        [self unregisterDraggedTypes];
}

- (void)setDropHighlight:(SZFriendsDropHighlight)highlight {
    _dropHighlight = highlight;
    self.needsDisplay = YES;
}

// A snapshot moved someone else into the row under a drag: its highlight ("Send to Mei") goes at once, and the row
// takes nothing until the drag leaves and comes back, so a drop released a moment later never reaches whoever arrived.
- (void)dropPersonChanged {
    if (_dragConversationID && !SZFSamePerson(_dragConversationID, _conversationID))
        self.dropHighlight = SZFriendsDropHighlightNone;
}

- (BOOL)dropStillForEnteredPerson {
    return _dragConversationID && SZFSamePerson(_dragConversationID, _conversationID);
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    _dragConversationID = _conversationID ?: @"";
    SZFriendsDropVerdict verdict = [SZFriendsDrops verdictForPasteboard:sender.draggingPasteboard host:_context.host];
    if (!_dropLabel) {
        self.dropHighlight = verdict == SZFriendsDropVerdictNone ? SZFriendsDropHighlightNone
                                                                 : SZFriendsDropHighlightRefuse;
        return NSDragOperationNone;
    }
    NSString *key = SZFriendsDropRefusalKey(verdict);
    _dragRefusal = key ? [_context string:key] : nil;
    self.dropHighlight = SZFriendsDropHighlightForVerdict(verdict);
    return self.dropHighlight == SZFriendsDropHighlightAccept ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    (void)sender;
    BOOL accepts = self.dropHighlight == SZFriendsDropHighlightAccept && [self dropStillForEnteredPerson];
    return accepts ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    _dragConversationID = nil;
    self.dropHighlight = SZFriendsDropHighlightNone;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    (void)sender;
    return self.dropHighlight == SZFriendsDropHighlightAccept && [self dropStillForEnteredPerson];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (self.dropHighlight != SZFriendsDropHighlightAccept || ![self dropStillForEnteredPerson]) return NO;
    // Promised files arrive later, by which time the row may show someone else: they go to whom it was dropped on.
    NSString *conversationID = _conversationID;
    __weak SZFriendsRowView *weakSelf = self;
    [SZFriendsDrops readItemsFromPasteboard:sender.draggingPasteboard host:_context.host
                           promiseDirectory:_context.promiseDirectory
                                 completion:^(NSArray<SZFriendsAttachableItem *> *items, BOOL refusedFolder) {
                                     SZFriendsRowView *row = weakSelf;
                                     if (!row || refusedFolder || !items.count || !row.onDropItems) return;
                                     row.onDropItems(row, conversationID, items);
                                 }];
    return YES;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    (void)sender;
    _dragConversationID = nil;
    self.dropHighlight = SZFriendsDropHighlightNone;
}

@end
