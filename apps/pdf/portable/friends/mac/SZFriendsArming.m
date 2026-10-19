// SZFriendsArming: arm-then-confirm for PROTOCOL.md actions that carry `arm`, and the action button every view uses.

#import "mac/SZFriendsArming.h"

BOOL SZFriendsArmAcceptsConfirm(NSTimeInterval armedAt, NSTimeInterval pressedAt, NSInteger clickCount,
                                NSTimeInterval doubleClickInterval) {
    if (clickCount > 1) return NO;
    return pressedAt - armedAt >= doubleClickInterval;
}

void SZFriendsAnnounceArmed(SZFriendsContext *context, NSButton *button, NSString *text) {
    if (context.postAccessibility) context.postAccessibility(button, NSAccessibilityTitleChangedNotification, nil);
    [context announce:text];
}

@implementation SZFriendsArming {
    __weak SZFriendsContext *_context;
    NSTimeInterval _armedAt;
    NSUInteger _generation;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super init])) return nil;
    _context = context;
    return self;
}

- (SZFriendsPress)press {
    SZFriendsContext *context = _context;
    if (context.currentPress) return context.currentPress();
    return SZFriendsPressFromEvent(NSApp.currentEvent, NSProcessInfo.processInfo.systemUptime);
}

- (void)armForSeconds:(double)seconds expired:(void (^)(void))expired {
    _armed = YES;
    _armedAt = [self press].time;
    NSUInteger generation = ++_generation;
    __weak SZFriendsArming *weakSelf = self;
    void (^onExpiry)(void) = [expired copy];
    SZFriendsContext *context = _context;
    if (context.scheduleAfter)
        context.scheduleAfter(seconds >= 1 ? seconds : 1, ^{
            SZFriendsArming *arming = weakSelf;
            if (!arming || generation != arming->_generation || !arming->_armed) return;
            [arming disarm];
            if (onExpiry) onExpiry();
        });
}

- (BOOL)pressConfirms {
    if (!_armed) return NO;
    SZFriendsPress press = [self press];
    return SZFriendsArmAcceptsConfirm(_armedAt, press.time, press.clickCount, NSEvent.doubleClickInterval);
}

- (BOOL)disarm {
    if (!_armed) return NO;
    _armed = NO;
    _generation++;
    return YES;
}

@end

@interface SZFriendsActionButton ()
- (NSDictionary *)ids;
@end

@implementation SZFriendsActionButton {
    __weak SZFriendsContext *_context;
    NSDictionary *_ids;
    SZFriendsArming *_arming;
    NSString *_restingTitle;
    NSString *_restingToolTip;
}

+ (instancetype)buttonForAction:(NSDictionary *)action ids:(NSDictionary *)ids context:(SZFriendsContext *)context {
    if (![SZFriendsContext knowsAction:SZFStr(action, @"action")]) return nil;
    SZFriendsActionButton *button = [self buttonWithTitle:SZFStr(action, @"label") ?: @""
                                                    style:SZFriendsButtonStyleNamed(SZFStr(action, @"style"))
                                               appearance:context.appearance];
    button->_context = context;
    button->_actionObject = [action copy];
    button->_ids = [ids copy] ?: @{};
    button->_arming = [[SZFriendsArming alloc] initWithContext:context];
    button->_restingTitle = button.title;
    __weak SZFriendsActionButton *weakButton = button;
    button.onPress = ^(SZFriendsButton *pressed) {
        (void)pressed;
        [weakButton handlePress];
    };
    return button;
}

- (BOOL)isArmed {
    return _arming.armed;
}

- (NSDictionary *)ids {
    return _ids;
}

- (NSDictionary *)arm {
    return SZFDict(_actionObject, @"arm");
}

- (void)handlePress {
    NSDictionary *arm = [self arm];
    if (arm && !_arming.armed) {
        __weak SZFriendsActionButton *weakSelf = self;
        [_arming armForSeconds:SZFNum(arm, @"seconds") expired:^{ [weakSelf showArmed:NO]; }];
        [self showArmed:YES];
        return;
    }
    if (arm && ![_arming pressConfirms]) return; // the second half of a double-click: stay armed, send nothing
    [self disarm];
    SZFriendsReplyHandler reply = self.onReply;
    if (self.disablesOncePressed) {
        self.enabled = NO;
        __weak SZFriendsActionButton *weakSelf = self;
        SZFriendsReplyHandler then = reply;
        reply = ^(NSDictionary<NSString *, id> *result, SZFriendsLinkError *error) {
            if (error != nil) weakSelf.enabled = YES; // refused: it may be pressed again
            if (then) then(result, error);
        };
    }
    [_context performAction:_actionObject ids:_ids reply:reply];
}

- (BOOL)disarm {
    if (![_arming disarm]) return NO;
    [self showArmed:NO];
    return YES;
}

- (void)showArmed:(BOOL)armed {
    NSDictionary *arm = [self arm];
    if (armed) {
        _restingToolTip = self.toolTip;
        self.title = SZFStr(arm, @"label") ?: _restingTitle;
        self.accessibilityLabel = SZFStr(arm, @"accessibility_label");
        self.toolTip = self.accessibilityLabel;
    } else {
        self.title = _restingTitle ?: @"";
        self.accessibilityLabel = nil;
        self.toolTip = _restingToolTip;
    }
    self.needsDisplay = YES;
    // The pill's width differs from the resting label's: every frame-laid-out ancestor up to the page lays out again.
    for (NSView *view = self.superview; view; view = view.superview) {
        view.needsLayout = YES;
        if ([view isKindOfClass:SZFriendsPage.class]) break;
    }
    SZFriendsContext *context = _context;
    if (armed && context) SZFriendsAnnounceArmed(context, self, self.accessibilityLabel);
    else if (context.postAccessibility) context.postAccessibility(self, NSAccessibilityTitleChangedNotification, nil);
}

// Leaving the button turns the pill back, so a "Block?" never waits for a click aimed at something else.
- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    [self disarm];
}

- (CGFloat)fittingWidth {
    if (!_arming.armed) return [super fittingWidth];
    NSDictionary *attributes = @{NSFontAttributeName : self.font};
    CGFloat pill = ceil([self.title sizeWithAttributes:attributes].width) + 24;
    // Never narrower than the label it replaced: the pointer that armed it must still be inside, or the pill would
    // turn back at once on mouseExited.
    CGFloat resting = ceil([_restingTitle sizeWithAttributes:attributes].width) + 2 * (self.style ==
                          SZFriendsButtonStyleLink || self.style == SZFriendsButtonStyleDestructive ? 2 : 12);
    return MAX(pill, resting);
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!_arming.armed) {
        [super drawRect:dirtyRect];
        return;
    }
    // The armed pill, as the list's request rows draw it: opaque, tinted from the background, red text.
    SZFriendsAppearance *appearance = self.theme;
    NSRect bounds = self.bounds;
    CGFloat radius = NSHeight(bounds) / 2;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:radius
                                                          yRadius:radius];
    NSColor *fill = [appearance.backgroundColor blendedColorWithFraction:0.12 ofColor:appearance.destructiveColor];
    if (self.cell.isHighlighted || self.hovered)
        fill = [fill blendedColorWithFraction:self.cell.isHighlighted ? 0.2 : 0.08 ofColor:NSColor.grayColor];
    [fill setFill];
    [shape fill];
    [[appearance.destructiveColor colorWithAlphaComponent:0.6] setStroke];
    [shape stroke];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{NSFontAttributeName : self.font,
                                 NSForegroundColorAttributeName : appearance.destructiveColor,
                                 NSParagraphStyleAttributeName : paragraph};
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawWithRect:NSMakeRect(6, floor((NSHeight(bounds) - size.height) / 2), NSWidth(bounds) - 12,
                                        ceil(size.height))
                     options:NSStringDrawingUsesLineFragmentOrigin
                  attributes:attributes];
    if (self.window.firstResponder == self && self.window.isKeyWindow) {
        [NSGraphicsContext saveGraphicsState];
        NSSetFocusRingStyle(NSFocusRingOnly);
        [shape fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}

@end

NSArray<SZFriendsActionButton *> *SZFriendsActionButtonsFor(NSArray *actions, NSDictionary *ids,
                                                            SZFriendsContext *context, NSArray *previous) {
    NSMutableArray *reusable = [NSMutableArray arrayWithArray:previous ?: @[]];
    NSMutableArray *buttons = [NSMutableArray array];
    NSDictionary *wanted = ids ?: @{};
    for (id action in actions) {
        if (![action isKindOfClass:NSDictionary.class]) continue;
        SZFriendsActionButton *button = nil;
        for (SZFriendsActionButton *candidate in reusable)
            if ([candidate.actionObject isEqual:action] && [[candidate ids] isEqual:wanted]) {
                button = candidate;
                break;
            }
        if (button) [reusable removeObject:button];
        else button = [SZFriendsActionButton buttonForAction:action ids:wanted context:context];
        if (button) [buttons addObject:button];
    }
    return buttons;
}

BOOL SZFriendsDisarmActionButtons(NSView *root) {
    BOOL any = NO;
    for (NSView *child in root.subviews) {
        if ([child isKindOfClass:SZFriendsActionButton.class]) any |= [(SZFriendsActionButton *)child disarm];
        any |= SZFriendsDisarmActionButtons(child);
    }
    return any;
}
