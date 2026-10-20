// SZFriendsRowActions: a request row's own buttons (PROTOCOL.md list_row actions), so a friend request is answered
// from the list without opening it (brief § Interface).
//
// Accept and Decline show their word (the action's `title`), Accept filled as the way forward and Decline outlined,
// so a first-time reader tells Decline from Block; Block is a round red icon button. Each has the snapshot's label
// as its tooltip and accessible name ("Accept Mei's request"). Block asks for a second click: the first turns it
// into a red "Block?" pill and sends nothing; a second, separate click within arm.seconds blocks (never the second
// half of a double-click, SZFriendsArming.h). The pill turns back when that time passes, on Escape and when the
// pointer leaves the row, so a pill left behind cannot turn a later stray click into a block.

#import "mac/SZFriendsArming.h"
#import "mac/SZFriendsRowView.h"

static const CGFloat SZFRowActionSide = 28;
static const CGFloat SZFRowActionGap = 6;

// PROTOCOL.md row_action icons; nil for one this view does not know, which it then hides.
static SZFriendsIconDrawer SZFRowActionIcon(NSString *icon) {
    if ([icon isEqualToString:@"accept"]) return ^(NSRect r, NSColor *c) { SZFriendsDrawCheckIcon(r, c); };
    if ([icon isEqualToString:@"decline"]) return ^(NSRect r, NSColor *c) { SZFriendsDrawCloseIcon(r, c); };
    if ([icon isEqualToString:@"block"]) return ^(NSRect r, NSColor *c) { SZFriendsDrawBlockIcon(r, c); };
    return nil;
}

@interface SZFriendsRowActionButton ()
@property(nonatomic, readwrite, getter=isArmed) BOOL armed;
@end

@implementation SZFriendsRowActionButton {
    NSString *_iconName;
    NSString *_word; // the action's title: drawn as a worded pill instead of the icon
}

- (instancetype)initWithRowAction:(NSDictionary *)action appearance:(SZFriendsAppearance *)appearance {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, SZFRowActionSide, SZFRowActionSide)])) return nil;
    _rowAction = [action copy];
    _iconName = [SZFStr(action, @"icon") copy];
    _word = [SZFStr(action, @"title") copy];
    self.theme = appearance;
    self.style = SZFriendsButtonStyleIcon;
    self.title = @"";
    self.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    self.icon = SZFRowActionIcon(_iconName);
    // The mockup's sizes: the cross is drawn smaller so the three glyphs look the same weight.
    CGFloat side = [_iconName isEqualToString:@"decline"] ? 12 : 14;
    self.iconSize = NSMakeSize(side, side);
    [self applyLabels];
    return self;
}

- (void)applyLabels {
    NSDictionary *arm = SZFDict(_rowAction, @"arm");
    NSString *label = _armed ? SZFStr(arm, @"accessibility_label") : SZFStr(_rowAction, @"label");
    self.title = _armed ? (SZFStr(arm, @"label") ?: @"") : (_word ?: @"");
    self.accessibilityLabel = label;
    self.toolTip = label;
}

- (void)setArmed:(BOOL)armed {
    _armed = armed;
    if (armed) self.iconSize = NSMakeSize(13, 13);
    else self.iconSize = [_iconName isEqualToString:@"decline"] ? NSMakeSize(12, 12) : NSMakeSize(14, 14);
    [self applyLabels];
    self.needsDisplay = YES;
}

- (BOOL)worded {
    return !_armed && _word.length > 0;
}

- (CGFloat)fittingWidth {
    if ([self worded]) return ceil([_word sizeWithAttributes:@{NSFontAttributeName : self.font}].width) + 2 * 11;
    if (!_armed) return SZFRowActionSide;
    NSDictionary *attributes = @{NSFontAttributeName : self.font};
    // 8 before the icon, 5 between icon and text, 10 after: the mockup's pill.
    return ceil([self.title sizeWithAttributes:attributes].width) + self.iconSize.width + 8 + 5 + 10;
}

- (NSColor *)iconColor {
    SZFriendsAppearance *appearance = self.theme;
    if (_armed || [_iconName isEqualToString:@"block"]) return appearance.destructiveColor;
    if ([_iconName isEqualToString:@"accept"]) return appearance.successColor;
    return appearance.primaryTextColor;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsAppearance *appearance = self.theme;
    NSRect bounds = self.bounds;
    CGFloat radius = NSHeight(bounds) / 2;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:radius
                                                          yRadius:radius];
    // Flat at rest like the host's panel icon buttons; the hover colour under the pointer. The armed pill is opaque,
    // blended from the background, so "Block?" keeps 4.5:1 whatever the row draws behind it.
    NSColor *fill = nil, *stroke = nil;
    BOOL accept = [_iconName isEqualToString:@"accept"];
    if ([self worded]) {
        // Accept is the way forward, filled like the dropdown's primary buttons; Decline is outlined.
        fill = accept ? appearance.primaryButtonColor : appearance.controlColor;
        stroke = accept ? nil : appearance.controlBorderColor;
        if (!self.enabled) fill = [fill colorWithAlphaComponent:0.5];
    } else if (_armed) {
        fill = [appearance.backgroundColor blendedColorWithFraction:0.12 ofColor:appearance.destructiveColor];
        stroke = [appearance.destructiveColor colorWithAlphaComponent:0.6];
    } else if (self.enabled && (self.cell.isHighlighted || self.hovered)) {
        fill = appearance.hoverColor;
    }
    if ([self worded] && self.hovered && self.enabled)
        fill = [fill blendedColorWithFraction:0.08 ofColor:NSColor.grayColor];
    if (fill && self.cell.isHighlighted) fill = [fill blendedColorWithFraction:0.15 ofColor:NSColor.grayColor];
    else if (fill && _armed && self.hovered) fill = [fill blendedColorWithFraction:0.08 ofColor:NSColor.grayColor];
    if (fill) {
        [fill setFill];
        [shape fill];
    }
    if (stroke) {
        [stroke setStroke];
        [shape stroke];
    }
    NSColor *iconColor = [self iconColor];
    NSSize icon = self.iconSize;
    CGFloat iconY = floor((NSHeight(bounds) - icon.height) / 2);
    if ([self worded]) {
        NSColor *text = accept ? appearance.primaryButtonTextColor : appearance.primaryTextColor;
        NSDictionary *attributes = @{NSFontAttributeName : self.font, NSForegroundColorAttributeName : text};
        NSSize size = [_word sizeWithAttributes:attributes];
        NSPoint origin =
            NSMakePoint(floor((NSWidth(bounds) - size.width) / 2), floor((NSHeight(bounds) - size.height) / 2));
        [_word drawAtPoint:origin withAttributes:attributes];
    } else if (!_armed) {
        CGFloat iconX = floor((NSWidth(bounds) - icon.width) / 2);
        if (self.icon) self.icon(NSMakeRect(iconX, iconY, icon.width, icon.height), iconColor);
    } else {
        CGFloat x = 8;
        if (self.icon) self.icon(NSMakeRect(x, iconY, icon.width, icon.height), iconColor);
        x += icon.width + 5;
        NSDictionary *attributes = @{NSFontAttributeName : self.font, NSForegroundColorAttributeName : iconColor};
        NSSize text = [self.title sizeWithAttributes:attributes];
        [self.title drawAtPoint:NSMakePoint(x, floor((NSHeight(bounds) - text.height) / 2)) withAttributes:attributes];
    }
    if (self.window.firstResponder == self && self.window.isKeyWindow) {
        [NSGraphicsContext saveGraphicsState];
        NSSetFocusRingStyle(NSFocusRingOnly);
        [shape fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}

@end

@implementation SZFriendsRowActionsView {
    __weak SZFriendsContext *_context;
    NSArray *_actions;
    NSMutableArray<SZFriendsRowActionButton *> *_buttons;
    SZFriendsRowActionButton *_armedButton;
    SZFriendsArming *_arming;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, SZFRowActionSide, SZFRowActionSide)])) return nil;
    _context = context;
    _buttons = [NSMutableArray array];
    _arming = [[SZFriendsArming alloc] initWithContext:context];
    return self;
}

- (NSArray<SZFriendsRowActionButton *> *)buttons {
    return [_buttons copy];
}

- (BOOL)isArmed {
    return _armedButton != nil;
}

- (BOOL)applyActions:(NSArray *)actions {
    if ([actions isEqual:_actions]) return _buttons.count > 0;
    [self disarm];
    _actions = [actions copy];
    self.busy = NO;
    for (NSView *button in _buttons) [button removeFromSuperview];
    [_buttons removeAllObjects];
    __weak SZFriendsRowActionsView *weakSelf = self;
    for (NSDictionary *action in actions) {
        if (![action isKindOfClass:NSDictionary.class]) continue;
        if (![SZFriendsContext knowsAction:SZFStr(action, @"action")] || !SZFRowActionIcon(SZFStr(action, @"icon")))
            continue;
        SZFriendsRowActionButton *button = [[SZFriendsRowActionButton alloc] initWithRowAction:action
                                                                                    appearance:_context.appearance];
        button.onPress = ^(SZFriendsButton *pressed) { [weakSelf pressed:(SZFriendsRowActionButton *)pressed]; };
        button.pressSubject = self.pressSubject;
        [_buttons addObject:button];
        [self addSubview:button];
    }
    [self updateEnabled];
    [self setNeedsLayout:YES];
    return _buttons.count > 0;
}

- (void)pressed:(SZFriendsRowActionButton *)button {
    if (self.busy || self.inactive) return;
    NSDictionary *arm = SZFDict(button.rowAction, @"arm");
    if (arm && !button.armed) {
        [self arm:button seconds:SZFNum(arm, @"seconds")];
        return;
    }
    // The second click of a double-click, or one too quick to have read the pill: stay armed, send nothing.
    if (button.armed && ![_arming pressConfirms]) return;
    [self disarm];
    if (self.onAction) self.onAction(button.rowAction);
}

- (void)arm:(SZFriendsRowActionButton *)button seconds:(double)seconds {
    [self disarm];
    button.armed = YES;
    _armedButton = button;
    __weak SZFriendsRowActionsView *weakSelf = self;
    [_arming armForSeconds:seconds expired:^{ [weakSelf disarm]; }];
    [self widthChanged];
    SZFriendsContext *context = _context;
    if (context) SZFriendsAnnounceArmed(context, button, button.accessibilityLabel);
}

- (BOOL)disarm {
    if (!_armedButton) return NO;
    [_arming disarm];
    SZFriendsRowActionButton *button = _armedButton;
    button.armed = NO;
    _armedButton = nil;
    [self widthChanged];
    SZFriendsContext *context = _context;
    if (context.postAccessibility) context.postAccessibility(button, NSAccessibilityTitleChangedNotification, nil);
    return YES;
}

- (void)widthChanged {
    [self setNeedsLayout:YES];
    if (self.onWidthChange) self.onWidthChange();
}

- (void)setPressSubject:(id (^)(void))pressSubject {
    _pressSubject = [pressSubject copy];
    for (SZFriendsRowActionButton *button in _buttons) button.pressSubject = _pressSubject;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    [self updateEnabled];
}

- (void)setInactive:(BOOL)inactive {
    _inactive = inactive;
    if (inactive) [self disarm];
    self.alphaValue = inactive ? 0.4 : 1;
    [self updateEnabled];
}

- (void)updateEnabled {
    for (SZFriendsRowActionButton *button in _buttons) button.enabled = !_busy && !_inactive;
}

- (CGFloat)fittingWidth {
    CGFloat width = 0;
    for (SZFriendsRowActionButton *button in _buttons)
        width += [button fittingWidth] + (width > 0 ? SZFRowActionGap : 0);
    return width;
}

- (void)layout {
    [super layout];
    CGFloat x = 0, y = floor((NSHeight(self.bounds) - SZFRowActionSide) / 2);
    for (SZFriendsRowActionButton *button in _buttons) {
        CGFloat width = [button fittingWidth];
        button.frame = NSMakeRect(x, y, width, SZFRowActionSide);
        x += width + SZFRowActionGap;
    }
}

@end
