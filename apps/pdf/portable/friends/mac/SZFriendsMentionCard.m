// SZFriendsMentionCardView: what a click on a stranger's mention shows (PROTOCOL.md § Mentions, mention_card).
//
// WHY the name shows literally: it is the name the sender wrote for someone the reader does not know, and the card is
// where the reader decides whether to add them, so a character that draws nothing shows as its code point, as on a
// proposal (SZFriendsLiteralText.m), rather than hiding what the name really is.

#import "mac/SZFriendsArming.h"
#import "mac/SZFriendsComposerInternal.h"
#import "mac/SZFriendsMentionViews.h"

static const CGFloat SZFCardPadding = 14;
static const CGFloat SZFCardButtonHeight = 26;

@implementation SZFriendsMentionCardView {
    SZFriendsContext *_context;
    NSArray<SZFriendsActionButton *> *_buttons;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 300, 120)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    self.fillColor = appearance.backgroundColor;
    self.strokeColor = appearance.controlBorderColor;
    self.cornerRadius = 10;
    _titleLabel = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _idLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _statusLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    _resultLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    for (NSTextField *label in @[ _titleLabel, _idLabel, _statusLabel, _resultLabel ]) [self addSubview:label];
    _buttons = @[];
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityGroupRole;
    return self;
}

- (NSArray<SZFriendsButton *> *)actionButtons {
    return [_buttons copy];
}

- (void)applyMention:(NSDictionary *)mention {
    _mention = [mention copy];
    SZFriendsAppearance *appearance = _context.appearance;
    NSDictionary *card = SZFDict(mention, @"card");
    NSString *title = SZFStr(card, @"title") ?: @"";
    _titleLabel.attributedStringValue = SZFriendsLiteralText(title, SZFriendsSemibold(appearance.bodyFont),
                                                             appearance.primaryTextColor, appearance.warningColor);
    _idLabel.stringValue = SZFStr(card, @"id_label") ?: @"";
    _statusLabel.stringValue = SZFStr(card, @"status_label") ?: @"";
    self.accessibilityLabel = title;
    NSString *conversationID = SZFStr(card, @"conversation_id");
    NSDictionary *ids = conversationID.length ? @{@"conversation_id" : conversationID} : @{};
    // Unchanged actions keep their buttons, so an armed "Block?" survives a snapshot that changed something else.
    NSArray<SZFriendsActionButton *> *buttons = SZFriendsActionButtonsFor(SZFArr(card, @"actions"), ids, _context,
                                                                          _buttons);
    for (NSView *old in _buttons)
        if (![(NSArray *)buttons containsObject:old]) [old removeFromSuperview];
    __weak SZFriendsMentionCardView *weakSelf = self;
    for (SZFriendsActionButton *button in buttons) {
        if (button.superview != self) [self addSubview:button];
        button.onReply = ^(NSDictionary *result, SZFriendsLinkError *error) {
            [weakSelf showReply:result error:error];
        };
    }
    _buttons = buttons;
    for (NSView *view = self; view; view = view.superview) view.needsLayout = YES;
}

// What the helper said about the action (Add: "Request sent to Leo Park. …"; a refusal: why), under the buttons and
// spoken, since it appears away from where VoiceOver is. It stays while the card follows its person through new
// snapshots (Request sent).
- (void)showReply:(NSDictionary *)result error:(SZFriendsLinkError *)error {
    NSString *message = error ? error.message : SZFStr(result, @"message");
    _resultLabel.stringValue = message ?: @"";
    _resultLabel.textColor = error ? _context.appearance.destructiveColor : _context.appearance.primaryTextColor;
    [_context announce:message];
    for (NSView *view = self; view; view = view.superview) view.needsLayout = YES;
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat inner = width - 2 * SZFCardPadding, y = 12;
    for (NSTextField *label in @[ _titleLabel, _idLabel, _statusLabel ]) {
        CGFloat height = SZFriendsFieldHeight(label, inner);
        if (apply) {
            label.hidden = height == 0;
            if (height) label.frame = NSMakeRect(SZFCardPadding, y, inner, height);
        }
        if (height) y += height + (label == _titleLabel ? 2 : 4);
    }
    // Buttons in one row, wrapping when they do not fit: Add alone, or Accept, Decline and Block.
    if (_buttons.count) {
        y += 6;
        CGFloat x = SZFCardPadding;
        for (SZFriendsActionButton *button in _buttons) {
            BOOL plain = button.style == SZFriendsButtonStyleLink || button.style == SZFriendsButtonStyleDestructive;
            CGFloat buttonWidth = MIN(inner, plain ? [button fittingWidth] : MAX(64, [button fittingWidth] + 8));
            if (x > SZFCardPadding && x + buttonWidth > SZFCardPadding + inner) {
                x = SZFCardPadding;
                y += SZFCardButtonHeight + 6;
            }
            if (apply) button.frame = NSMakeRect(x, y, buttonWidth, SZFCardButtonHeight);
            x += buttonWidth + 8;
        }
        y += SZFCardButtonHeight + 4;
    }
    CGFloat result = SZFriendsFieldHeight(_resultLabel, inner);
    if (apply) {
        _resultLabel.hidden = result == 0;
        if (result) _resultLabel.frame = NSMakeRect(SZFCardPadding, y + 4, inner, result);
    }
    if (result) y += result + 4;
    return y + 12;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutForWidth:width apply:NO];
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

@end
