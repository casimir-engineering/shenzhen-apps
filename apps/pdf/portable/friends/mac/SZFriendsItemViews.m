// History items: day separators, message bubbles, transfer cards and events, drawn from PROTOCOL.md items.

#import "mac/SZFriendsArming.h"
#import "mac/SZFriendsItemViewsInternal.h"
#import "mac/SZFriendsTransferProgress.h"

@interface SZFriendsDayItemView : SZFriendsItemView
@end
@interface SZFriendsEventItemView : SZFriendsItemView
@end

// Determinate or indeterminate progress drawn flat, so it renders identically offscreen and on screen.
@interface SZFriendsProgressBar : NSView
@property(nonatomic) double fraction;
@property(nonatomic) BOOL determinate;
@property(nonatomic, strong) SZFriendsAppearance *theme;
@end

@implementation SZFriendsProgressBar
- (BOOL)isAccessibilityElement {
    return YES;
}
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityProgressIndicatorRole;
}
- (id)accessibilityValue {
    return self.determinate ? @(self.fraction) : nil;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat radius = NSHeight(self.bounds) / 2;
    [self.theme.separatorColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:radius yRadius:radius] fill];
    NSRect filled = self.bounds;
    if (self.determinate) filled.size.width = round(NSWidth(self.bounds) * MAX(0, MIN(1, self.fraction)));
    else filled = NSMakeRect(NSWidth(self.bounds) * 0.3, 0, NSWidth(self.bounds) * 0.3, NSHeight(self.bounds));
    [self.theme.accentColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:filled xRadius:radius yRadius:radius] fill];
}
@end

@implementation SZFriendsItemView

+ (instancetype)viewForItem:(NSDictionary *)item context:(SZFriendsContext *)context {
    NSString *kind = SZFStr(item, @"kind");
    Class class = [kind isEqualToString:@"day"]        ? SZFriendsDayItemView.class
                  : [kind isEqualToString:@"message"]  ? SZFriendsMessageItemView.class
                  : [kind isEqualToString:@"transfer"] ? SZFriendsTransferItemView.class
                                                       : SZFriendsEventItemView.class;
    SZFriendsItemView *view = [[class alloc] initWithFrame:NSMakeRect(0, 0, 372, 20)];
    view.context = context;
    view.itemKind = kind ?: @"event";
    [view setUp];
    [view applyItem:item];
    return view;
}

- (void)setUp {
}

- (void)applyItem:(NSDictionary *)item {
    self.item = item;
    self.itemID = SZFStr(item, @"item_id") ?: @"";
    self.highlighted = SZFBool(item, @"highlighted");
    self.accessibilityLabel = SZFStr(item, @"accessibility_label");
    [self setNeedsLayout:YES];
    self.needsDisplay = YES;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutForWidth:width apply:NO];
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    (void)width, (void)apply;
    return 0;
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

// The action buttons for this item, known actions only, in the snapshot's order; unchanged ones are kept, so a
// progress tick does not drop an armed pill (SZFriendsArming.h). New buttons are added to the item itself.
- (NSArray<SZFriendsButton *> *)buttonsForActions:(NSArray *)actions {
    NSMutableDictionary *ids = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"transfer_id", @"item_id" ])
        if (SZFStr(self.item, key)) ids[key] = SZFStr(self.item, key);
    // A message item's id is the message_id send_message returned, which cancel_message takes (PROTOCOL.md).
    if ([self.itemKind isEqualToString:@"message"] && ids[@"item_id"]) ids[@"message_id"] = ids[@"item_id"];
    NSArray *previous = self.actionButtons;
    NSArray<SZFriendsActionButton *> *buttons = SZFriendsActionButtonsFor(actions, ids, self.context, previous);
    for (NSView *old in previous)
        if (![(NSArray *)buttons containsObject:old]) [old removeFromSuperview];
    for (SZFriendsActionButton *button in buttons) {
        if (!button.superview) [self addSubview:button];
        button.toolTip = button.armed ? button.toolTip : SZFStr(button.actionObject, @"note");
    }
    self.actionButtons = buttons;
    return buttons;
}

@end

@implementation SZFriendsDayItemView {
    NSTextField *_label;
}
- (void)setUp {
    _label = SZFriendsLabel(@"", SZFriendsSemibold(self.context.appearance.captionFont),
                            self.context.appearance.secondaryTextColor);
    _label.alignment = NSTextAlignmentCenter;
    [self addSubview:_label];
}
- (void)applyItem:(NSDictionary *)item {
    [super applyItem:item];
    _label.stringValue = SZFStr(item, @"label") ?: @"";
}
- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat height = SZFriendsFieldHeight(_label, width);
    if (apply) _label.frame = NSMakeRect(0, 2, width, height);
    return height + 4;
}
@end

@implementation SZFriendsEventItemView {
    NSTextField *_label;
}
- (void)setUp {
    _label = SZFriendsLabel(@"", self.context.appearance.secondaryFont, self.context.appearance.secondaryTextColor);
    _label.alignment = NSTextAlignmentCenter;
    [self addSubview:_label];
}
- (void)applyItem:(NSDictionary *)item {
    [super applyItem:item];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithString:SZFStr(item, @"text") ?: @""
            attributes:@{NSFontAttributeName : self.context.appearance.secondaryFont,
                         NSForegroundColorAttributeName : self.context.appearance.secondaryTextColor}];
    NSString *time = SZFStr(item, @"time_label");
    if (time.length) {
        // The time sits beside the event in the caption size, like a message's time under its bubble.
        [text appendAttributedString:[[NSAttributedString alloc]
                                         initWithString:[@"  " stringByAppendingString:time]
                                             attributes:@{NSFontAttributeName : self.context.appearance.captionFont,
                                                          NSForegroundColorAttributeName :
                                                              self.context.appearance.secondaryTextColor}]];
    }
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    [text addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, text.length)];
    _label.attributedStringValue = text;
}
- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat height = SZFriendsFieldHeight(_label, width - 40);
    if (apply) _label.frame = NSMakeRect(20, 2, width - 40, height);
    return height + 4;
}
@end

@implementation SZFriendsTransferItemView {
    SZFriendsFlippedView *_card;
    NSTextField *_name;
    NSTextField *_meta;
    NSTextField *_routeNote;
    NSTextField *_status;
    NSTextField *_routeLabel;
    SZFriendsFlippedView *_routeIcon; // the route's icon before its words, as the conversation header draws it
    NSTextField *_time;
    SZFriendsProgressBar *_progress;
    // Progress by route (PROTOCOL.md § Fast transfers), when the snapshot carries it: the route icons beside the name,
    // the split bar, the amount and time left under it, and the detail line with the status line's links.
    BOOL _byRoute;
    SZFriendsSplitProgressBar *_split;
    NSMutableArray<SZFriendsTransferRouteIcon *> *_routeIcons;
    NSTextField *_amount, *_left, *_detail;
}
- (NSTextField *)timeLabel {
    return _time;
}
- (NSView *)routeIconView {
    return _routeIcon;
}
- (NSTextField *)routeLabel {
    return _routeLabel;
}
- (void)setUp {
    SZFriendsAppearance *appearance = self.context.appearance;
    _assistantLabel = [[SZFriendsAssistantLabelView alloc] initWithAppearance:appearance];
    [self addSubview:_assistantLabel];
    _card = [SZFriendsFlippedView new];
    _card.fillColor = appearance.fieldBackgroundColor;
    _card.strokeColor = appearance.separatorColor;
    _card.cornerRadius = 10;
    [self addSubview:_card];
    _name = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _name.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _name.maximumNumberOfLines = 1;
    _meta = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _routeNote = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    _status = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _time = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    _routeLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _routeLabel.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    _routeLabel.maximumNumberOfLines = 1;
    for (NSTextField *label in @[ _name, _meta, _routeNote, _status, _routeLabel ]) [_card addSubview:label];
    __weak SZFriendsTransferItemView *weakSelf = self;
    _routeIcon = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 11, 11)];
    _routeIcon.drawContents = ^(SZFriendsFlippedView *view) {
        SZFriendsTransferItemView *item = weakSelf;
        if (!item) return;
        NSDictionary *route = SZFDict(item.item, @"route");
        SZFriendsDrawRouteIcon(SZFriendsRouteGlyph(route), view.bounds,
                               SZFriendsRouteColor(item.context.appearance, SZFStr(route, @"kind")));
    };
    [_card addSubview:_routeIcon];
    [self addSubview:_time];
    _progress = [SZFriendsProgressBar new];
    _progress.theme = appearance;
    [_card addSubview:_progress];
    _split = [SZFriendsSplitProgressBar new];
    _split.theme = appearance;
    [_card addSubview:_split];
    _routeIcons = [NSMutableArray array];
    // Tabular digits, so the figures do not shuffle the line as they change.
    NSFont *digits = [NSFont monospacedDigitSystemFontOfSize:appearance.secondaryFont.pointSize weight:NSFontWeightRegular];
    _amount = SZFriendsLabel(@"", digits, appearance.secondaryTextColor);
    _left = SZFriendsLabel(@"", digits, appearance.secondaryTextColor);
    _left.alignment = NSTextAlignmentRight;
    _detail = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    for (NSTextField *label in @[ _amount, _left, _detail ]) {
        label.maximumNumberOfLines = 1;
        label.cell.lineBreakMode = NSLineBreakByTruncatingTail;
        [_card addSubview:label];
    }
    _detail.maximumNumberOfLines = 2;
    _detail.cell.lineBreakMode = NSLineBreakByWordWrapping;
    _preview = [[SZFriendsFilePreviewView alloc] initWithFrame:NSMakeRect(12, 10, 28, 34)];
    _preview.theme = appearance;
    [_card addSubview:_preview];
}
- (BOOL)outgoing {
    return [SZFStr(self.item, @"direction") isEqualToString:@"out"];
}
- (void)applyItem:(NSDictionary *)item {
    [super applyItem:item];
    SZFriendsAppearance *appearance = self.context.appearance;
    NSDictionary *file = SZFDict(item, @"file");
    _name.stringValue = SZFStr(file, @"name") ?: @"";
    [_preview applyFile:file thumbnail:SZFDict(item, @"thumbnail")];
    _meta.stringValue = SZFStr(item, @"meta_label") ?: @"";
    _assistantLabel.text = SZFStr(item, @"assistant_label") ?: @"";
    _routeNote.stringValue = SZFStr(item, @"route_note") ?: @"";
    _status.stringValue = SZFStr(item, @"status_label") ?: @"";
    NSString *state = SZFStr(item, @"state");
    _status.textColor = [state isEqualToString:@"delivered"] || [state isEqualToString:@"received"]
                            ? appearance.successColor
                        : [state isEqualToString:@"failed"] ? appearance.destructiveColor
                                                            : appearance.secondaryTextColor;
    // A file copying here from another of the person's computers: the route it comes by, under its status.
    NSDictionary *route = SZFDict(item, @"route");
    _routeLabel.stringValue = SZFStr(route, @"label") ?: @"";
    _routeLabel.textColor = SZFriendsRouteColor(appearance, SZFStr(route, @"kind"));
    _routeLabel.hidden = _routeLabel.stringValue.length == 0;
    _routeIcon.hidden = _routeLabel.hidden || !SZFriendsRouteGlyph(route);
    _routeIcon.needsDisplay = YES;
    // VoiceOver reads the route with the rest of the card, after what the helper says of it.
    NSString *spoken = SZFStr(item, @"accessibility_label");
    if (!_routeLabel.hidden && spoken.length && ![spoken containsString:_routeLabel.stringValue])
        self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", spoken, _routeLabel.stringValue];
    _time.stringValue = SZFStr(item, @"time_label") ?: @"";
    _card.strokeColor = self.highlighted ? appearance.accentColor : appearance.separatorColor;
    NSDictionary *progress = SZFDict(item, @"progress");
    _byRoute = SZFStr(progress, @"amount_label").length > 0;
    _progress.hidden = progress == nil || _byRoute;
    _progress.fraction = SZFNum(progress, @"fraction");
    _progress.determinate = SZFBool(progress, @"determinate");
    _progress.accessibilityLabel = SZFStr(progress, @"accessibility_label");
    _progress.needsDisplay = YES;
    _split.hidden = !_byRoute;
    _split.fraction = SZFNum(progress, @"fraction");
    _split.determinate = SZFBool(progress, @"determinate");
    _split.segments = SZFArr(progress, @"segments");
    _split.finishing = _byRoute && SZFBool(progress, @"finishing");
    _split.accessibilityLabel = SZFStr(progress, @"accessibility_label");
    _split.needsDisplay = YES;
    self.progressView = progress ? (_byRoute ? _split : _progress) : nil;
    _amount.stringValue = _byRoute ? SZFStr(progress, @"amount_label") : @"";
    _left.stringValue = _byRoute ? SZFStr(progress, @"time_left_label") ?: @"" : @"";
    _detail.stringValue = _byRoute ? SZFStr(progress, @"detail_label") ?: @"" : @"";
    NSArray *routes = _byRoute ? SZFArr(progress, @"routes") : @[];
    while (_routeIcons.count > routes.count) {
        [_routeIcons.lastObject removeFromSuperview];
        [_routeIcons removeLastObject];
    }
    while (_routeIcons.count < routes.count) {
        SZFriendsTransferRouteIcon *icon = [SZFriendsTransferRouteIcon new];
        icon.theme = appearance;
        [_card addSubview:icon];
        [_routeIcons addObject:icon];
    }
    [routes enumerateObjectsUsingBlock:^(NSDictionary *route, NSUInteger i, BOOL *stop) {
      (void)stop;
      SZFriendsTransferRouteIcon *icon = self->_routeIcons[i];
      icon.method = [route isKindOfClass:NSDictionary.class] ? SZFStr(route, @"method") : nil;
      icon.active = [route isKindOfClass:NSDictionary.class] && SZFBool(route, @"active");
      icon.toolTip = [route isKindOfClass:NSDictionary.class] ? SZFStr(route, @"label") : nil;
      icon.accessibilityLabel = icon.toolTip;
      icon.needsDisplay = YES;
    }];
    // The lines under the bar say what the status line would (the routes, the amount); its links stay.
    _status.hidden = _byRoute;
    if (_byRoute) _routeLabel.hidden = _routeIcon.hidden = YES;
    for (SZFriendsButton *button in [self buttonsForActions:SZFArr(item, @"actions")])
        if (button.superview != _card) [_card addSubview:button];
}
- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    // Wider with progress by route, so the amount, the percentage and the speed fit beside the time left.
    CGFloat cardWidth = MIN(_byRoute ? 340 : 280, width - 40);
    CGFloat inner = cardWidth - 24;
    // The preview, or the type's icon, leads; name and size sit beside it. The preview's slot comes from the
    // snapshot's width and height, so the card keeps its shape when the picture arrives.
    NSSize slot = _preview.size;
    CGFloat textX = 12 + slot.width + 10, textWidth = cardWidth - textX - 12;
    // The route icons sit at the name's right, 24 points each with 4 between.
    CGFloat iconsWidth = _routeIcons.count ? _routeIcons.count * 28 - 4 : 0;
    if (iconsWidth) textWidth -= iconsWidth + 8;
    CGFloat y = 10;
    if (apply) {
        CGFloat x = cardWidth - 12 - iconsWidth;
        for (SZFriendsTransferRouteIcon *icon in _routeIcons) {
            icon.frame = NSMakeRect(x, y + MAX(0, (slot.height - 24) / 2), 24, 24);
            x += 28;
        }
    }
    CGFloat nameHeight = SZFriendsFieldHeight(_name, textWidth), metaHeight = SZFriendsFieldHeight(_meta, textWidth);
    if (apply) {
        _preview.frame = NSMakeRect(12, y, slot.width, slot.height);
        _name.frame = NSMakeRect(textX, y, textWidth, nameHeight);
        _meta.frame = NSMakeRect(textX, y + nameHeight + 2, textWidth, metaHeight);
    }
    y += MAX(slot.height, nameHeight + 2 + metaHeight);
    if (_routeNote.stringValue.length) {
        y += 8;
        y = apply ? SZFriendsPlace(_routeNote, 12, y, inner) : y + SZFriendsFieldHeight(_routeNote, inner);
    } else if (apply) {
        _routeNote.hidden = YES;
    }
    if (!_progress.hidden) {
        y += 8;
        if (apply) _progress.frame = NSMakeRect(12, y, inner, 5);
        y += 5;
    }
    if (_byRoute) {
        // The split bar, then the amount on the left and the time left on the right, as the approved design.
        y += 10;
        if (apply) _split.frame = NSMakeRect(12, y, inner, 8);
        y += 8 + 6;
        CGFloat leftWidth = _left.stringValue.length ? SZFriendsTextWidth(_left.stringValue, _left.font) + 6 : 0;
        if (apply) {
            _amount.frame = NSMakeRect(12, y, inner - leftWidth - 6, 16);
            _left.frame = NSMakeRect(12 + inner - leftWidth, y, leftWidth, 16);
        }
        _left.hidden = leftWidth == 0;
        y += 16;
    } else if (apply) {
        _amount.hidden = YES;
        _left.hidden = YES;
        _detail.hidden = YES;
    }
    if (apply) _amount.hidden = !_byRoute;
    // Link actions (Cancel, Show in Finder) share the status line, right-aligned; buttons get their own row.
    NSMutableArray *links = [NSMutableArray array], *buttons = [NSMutableArray array];
    for (SZFriendsButton *button in self.actionButtons)
        [(button.style == SZFriendsButtonStyleLink || button.style == SZFriendsButtonStyleDestructive ? links : buttons)
            addObject:button];
    CGFloat linksWidth = 0;
    for (SZFriendsButton *button in links) linksWidth += [button fittingWidth] + 8;
    if (_byRoute && (_detail.stringValue.length || links.count)) {
        // "Via Same Wi-Fi + Bluetooth · …", with Cancel at its right.
        y += 2;
        CGFloat detailWidth = MAX(40, inner - linksWidth);
        CGFloat detailHeight = _detail.stringValue.length ? MAX(16, SZFriendsFieldHeight(_detail, detailWidth)) : 16;
        if (apply) {
            _detail.hidden = _detail.stringValue.length == 0;
            _detail.frame = NSMakeRect(12, y, detailWidth, detailHeight);
            CGFloat x = cardWidth - 12;
            for (SZFriendsButton *button in links.reverseObjectEnumerator) {
                CGFloat buttonWidth = [button fittingWidth];
                x -= buttonWidth;
                button.frame = NSMakeRect(x, y - 1, buttonWidth, 18);
                x -= 8;
            }
        }
        y += detailHeight;
    } else if (_byRoute) {
        if (apply) _detail.hidden = YES;
    } else if (_status.stringValue.length || links.count) {
        y += 6;
        CGFloat statusWidth = MAX(40, inner - linksWidth);
        CGFloat statusHeight = MAX(16, SZFriendsFieldHeight(_status, statusWidth));
        if (apply) {
            _status.frame = NSMakeRect(12, y, statusWidth, statusHeight);
            CGFloat x = cardWidth - 12;
            for (SZFriendsButton *button in links.reverseObjectEnumerator) {
                CGFloat buttonWidth = [button fittingWidth];
                x -= buttonWidth;
                button.frame = NSMakeRect(x, y - 1, buttonWidth, 18);
                x -= 8;
            }
        }
        y += statusHeight;
    }
    // The route line: its icon, 4 points, then its words, as the conversation header draws it.
    if (!_routeLabel.hidden) {
        y += 4;
        CGFloat icon = _routeIcon.hidden ? 0 : 15;
        if (apply) {
            _routeIcon.frame = NSMakeRect(12, y + 2, 11, 11);
            _routeLabel.frame = NSMakeRect(12 + icon, y, inner - icon, 16);
        }
        y += 16;
    }
    if (buttons.count) {
        y += 8;
        CGFloat x = 12;
        for (SZFriendsButton *button in buttons) {
            CGFloat buttonWidth = MAX(72, [button fittingWidth]);
            if (apply) button.frame = NSMakeRect(x, y, buttonWidth, 26);
            x += buttonWidth + 8;
        }
        y += 26;
    }
    CGFloat cardHeight = y + 10;
    CGFloat cardX = [self outgoing] ? width - cardWidth : 0;
    // A file the assistant sent says so on the time line under its card, before the time, as a message bubble does.
    BOOL outgoing = [self outgoing];
    CGFloat labelWidth = MIN(_assistantLabel.fittingWidth, width - 8);
    CGFloat timeText = SZFriendsTextWidth(_time.stringValue, self.context.appearance.captionFont) + 4;
    BOOL sameLine = labelWidth > 0 && labelWidth + 10 + timeText <= width - 8;
    CGFloat timeY = cardHeight + 3 + (labelWidth > 0 && !sameLine ? 18 : 0);
    if (apply) {
        _card.frame = NSMakeRect(cardX, 0, cardWidth, cardHeight);
        _assistantLabel.hidden = labelWidth == 0;
        CGFloat labelX = outgoing ? width - 4 - labelWidth - (sameLine ? timeText + 10 : 0) : 4;
        _assistantLabel.frame = NSMakeRect(labelX, cardHeight + 3, labelWidth, 15);
        CGFloat timeX = !outgoing && sameLine ? 4 + labelWidth + 10 : 4;
        _time.frame = NSMakeRect(timeX, timeY, width - 4 - timeX, 15);
        _time.alignment = outgoing ? NSTextAlignmentRight : NSTextAlignmentLeft;
        _card.needsDisplay = YES;
    }
    return timeY + 15;
}
@end
