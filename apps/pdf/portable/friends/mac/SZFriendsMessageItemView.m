// Message bubbles: the body (plain or Markdown), then the time line: "Via the assistant", time, status and actions.

#import "mac/SZFriendsItemViewsInternal.h"

@implementation SZFriendsAssistantLabelView {
    SZFriendsAppearance *_theme;
    NSTextField *_label;
}

- (instancetype)initWithAppearance:(SZFriendsAppearance *)appearance {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 160, 15)])) return nil;
    _theme = appearance;
    _text = @"";
    _label = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    _label.maximumNumberOfLines = 1;
    _label.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_label];
    __weak SZFriendsAssistantLabelView *weakSelf = self;
    // The spark is the assistant's mark in the host's chat too; drawn, so it stays sharp and needs no image.
    self.drawContents = ^(SZFriendsFlippedView *view) {
        (void)view;
        SZFriendsAssistantLabelView *label = weakSelf;
        if (label) SZFriendsDrawAssistantIcon(NSMakeRect(0, 2, 11, 11), label->_theme.secondaryTextColor);
    };
    return self;
}

- (void)setText:(NSString *)text {
    _text = [text copy] ?: @"";
    _label.stringValue = _text;
    self.hidden = _text.length == 0;
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (CGFloat)fittingWidth {
    return _text.length ? 15 + SZFriendsTextWidth(_text, _theme.captionFont) + 4 : 0;
}

- (void)layout {
    [super layout];
    _label.frame = NSMakeRect(15, 0, MAX(0, NSWidth(self.bounds) - 15), 15);
}

@end

const CGFloat SZFriendsCancelledBubbleAlpha = 0.45;

@implementation SZFriendsMessageItemView {
    SZFriendsFlippedView *_bubble;
    NSTextField *_meta;
    NSTextField *_status;
}

- (NSTextField *)timeLabel {
    return _meta;
}

- (NSView *)bubble {
    return _bubble;
}

- (void)setUp {
    SZFriendsAppearance *appearance = self.context.appearance;
    _bubble = [SZFriendsFlippedView new];
    _bubble.cornerRadius = 12;
    [self addSubview:_bubble];
    _body = [[SZFriendsMessageBody alloc] initWithContext:self.context];
    [_bubble addSubview:_body];
    _assistantLabel = [[SZFriendsAssistantLabelView alloc] initWithAppearance:appearance];
    [self addSubview:_assistantLabel];
    _meta = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    _status = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    [self addSubview:_meta];
    [self addSubview:_status];
}

- (BOOL)outgoing {
    return [SZFStr(self.item, @"direction") isEqualToString:@"out"];
}

- (void)applyItem:(NSDictionary *)item {
    [super applyItem:item];
    SZFriendsAppearance *appearance = self.context.appearance;
    _bubble.fillColor = [self outgoing] ? appearance.outgoingBubbleColor : appearance.incomingBubbleColor;
    _body.edgeColor = _bubble.fillColor;
    _bubble.strokeColor = self.highlighted ? appearance.accentColor : nil;
    [_body applyItem:item];
    _assistantLabel.text = SZFStr(item, @"assistant_label") ?: @"";
    _meta.stringValue = SZFStr(item, @"time_label") ?: @"";
    NSDictionary *status = SZFDict(item, @"status");
    _status.stringValue = SZFStr(status, @"label") ?: @"";
    _status.textColor = [SZFStr(status, @"state") isEqualToString:@"failed"] ? appearance.destructiveColor
                                                                          : appearance.secondaryTextColor;
    // A message the person cancelled never left: its bubble fades, as the list fades rows that take nothing, so it
    // reads as not sent at a glance and not only from the small "Cancelled" under it.
    _bubble.alphaValue = [SZFStr(status, @"state") isEqualToString:@"cancelled"] ? SZFriendsCancelledBubbleAlpha : 1;
    // Cancel withdraws a message only from a helper that announces messages.cancel; from any other the intent would
    // fail as unknown, so the button would do nothing.
    NSArray *actions = SZFArr(item, @"actions");
    if (![self.context.link.helperCapabilities containsObject:@"messages.cancel"])
        actions = [actions filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id action, id bindings) {
                               (void)bindings;
                               return ![SZFStr(action, @"action") isEqualToString:@"cancel_message"];
                           }]];
    [self buttonsForActions:actions];
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    BOOL outgoing = [self outgoing];
    // Plain messages stay chat-narrow; Markdown may hold a table or a diagram, so its bubble may use the width the
    // incoming/outgoing offset leaves (40 pt shows which side it is on).
    NSSize body = [_body sizeForPlainWidth:MAX(40, MIN(280, width - 60) - 22) markdownWidth:MAX(40, width - 40 - 22)];
    CGFloat bubbleWidth = body.width + 22, bubbleHeight = body.height + 16;
    CGFloat bubbleX = outgoing ? width - bubbleWidth : 0;
    if (apply) {
        _bubble.frame = NSMakeRect(bubbleX, 0, bubbleWidth, bubbleHeight);
        _body.frame = NSMakeRect(11, 8, body.width, body.height);
    }
    // The time line sits under the bubble on its side: "Via the assistant" leads it, as under a transfer card, then
    // the time, the status and the actions (Try again, Cancel).
    NSFont *font = self.context.appearance.captionFont;
    CGFloat metaWidth = _meta.stringValue.length ? SZFriendsTextWidth(_meta.stringValue, font) + 4 : 0;
    CGFloat statusWidth = _status.stringValue.length ? SZFriendsTextWidth(_status.stringValue, font) + 4 : 0;
    CGFloat actionsWidth = 0;
    for (SZFriendsButton *button in self.actionButtons) actionsWidth += [button fittingWidth] + 8;
    BOOL hasTail = statusWidth || self.actionButtons.count;
    CGFloat labelWidth = MIN(_assistantLabel.fittingWidth, width - 8);
    CGFloat tailWidth = (statusWidth ? statusWidth + 6 : 0) + actionsWidth;
    // When it all does not fit, the status and actions continue on a second line: the label stays with the time
    // rather than moving to a line of its own, so it reads the same under every message and file.
    BOOL wraps = (labelWidth > 0 || metaWidth) && hasTail &&
                 (labelWidth > 0 ? labelWidth + 10 : 0) + metaWidth + tailWidth > width - 8;
    CGFloat lead = labelWidth > 0 ? labelWidth + (metaWidth || (hasTail && !wraps) ? 10 : 0) : 0;
    CGFloat y = bubbleHeight;
    if (apply) _assistantLabel.hidden = labelWidth == 0;
    // A message within minutes of the one before it has no time (time_label null) and, when it has no label, status
    // or action either, no line under its bubble: a time line per message left five items in a 640 pt dropdown.
    _meta.hidden = metaWidth == 0;
    if (!lead && !metaWidth && !hasTail) {
        if (apply) _status.hidden = YES;
        return y;
    }
    y += 3;
    CGFloat x = outgoing ? width - 4 - lead - metaWidth - (wraps ? 0 : tailWidth) : 4;
    CGFloat timeX = x + lead;
    CGFloat statusX = timeX + metaWidth + (metaWidth ? 6 : 0);
    CGFloat buttonX = timeX + metaWidth + (statusWidth ? statusWidth + 6 : 0) + (metaWidth || statusWidth ? 8 : 0);
    if (apply) {
        if (labelWidth > 0) _assistantLabel.frame = NSMakeRect(x, y, labelWidth, 15);
        _meta.frame = NSMakeRect(timeX, y, metaWidth, 15);
    }
    if (wraps) {
        y += 18;
        CGFloat buttonsWidth = actionsWidth ? actionsWidth - 8 : 0;
        CGFloat lineWidth = statusWidth + (statusWidth && buttonsWidth ? 8 : 0) + buttonsWidth;
        statusX = outgoing ? width - 4 - lineWidth : 4;
        buttonX = statusX + (statusWidth ? statusWidth + 8 : 0);
    }
    if (apply) {
        _status.frame = NSMakeRect(statusX, y, statusWidth, 15);
        _status.hidden = statusWidth == 0;
        for (SZFriendsButton *button in self.actionButtons) {
            CGFloat buttonWidth = [button fittingWidth];
            button.frame = NSMakeRect(buttonX, y - 1, buttonWidth, 17);
            buttonX += buttonWidth + 8;
        }
    }
    // A button reaches one point below the line (y - 1 + 17); the view must contain it, or clicks on its bottom
    // edge fall through to the history behind it.
    return y + (self.actionButtons.count ? 16 : 15);
}

@end
