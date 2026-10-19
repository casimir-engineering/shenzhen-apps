// SZFriendsRequestCardView: a pending friend request with the comparison code both screens show.

#import "mac/SZFriendsArming.h"
#import "mac/SZFriendsConversationPage.h"

@implementation SZFriendsRequestCardView {
    SZFriendsContext *_context;
    SZFriendsAvatarView *_avatar;
    NSTextField *_title;
    NSTextField *_subtitle;
    SZFriendsFlippedView *_codeBox;
    NSTextField *_codePrompt;
    NSTextField *_code;
    NSTextField *_footnote;
    NSArray<SZFriendsButton *> *_buttons; // primary and secondary, in one centered row
    NSArray<SZFriendsButton *> *_links;   // link and destructive, each on its own line under them
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, context.appearance.dropdownWidth, 400)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    _avatar = [SZFriendsAvatarView new];
    [self addSubview:_avatar];
    _title = SZFriendsLabel(@"", [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold], appearance.primaryTextColor);
    _subtitle = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _codeBox = [SZFriendsFlippedView new];
    _codeBox.fillColor = appearance.fieldBackgroundColor;
    _codeBox.strokeColor = appearance.separatorColor;
    _codeBox.cornerRadius = 10;
    _codePrompt = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    // Tabular digits so both people read the code at the same rhythm.
    _code = SZFriendsLabel(@"", [NSFont monospacedDigitSystemFontOfSize:26 weight:NSFontWeightSemibold],
                           appearance.primaryTextColor);
    _footnote = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    for (NSTextField *label in @[ _title, _subtitle, _codePrompt, _code, _footnote ])
        label.alignment = NSTextAlignmentCenter;
    [self addSubview:_title];
    [self addSubview:_subtitle];
    [self addSubview:_codeBox];
    [_codeBox addSubview:_codePrompt];
    [_codeBox addSubview:_code];
    [self addSubview:_footnote];
    _buttons = @[];
    _links = @[];
    return self;
}

- (NSArray<SZFriendsButton *> *)actionButtons {
    return [_buttons arrayByAddingObjectsFromArray:_links];
}

- (void)applyRequest:(NSDictionary *)request conversationID:(NSString *)conversationID {
    _avatar.avatar = SZFDict(request, @"avatar");
    _title.stringValue = SZFStr(request, @"title") ?: @"";
    _subtitle.stringValue = SZFStr(request, @"subtitle") ?: @"";
    _codePrompt.stringValue = SZFStr(request, @"code_prompt") ?: @"";
    NSString *code = SZFStr(request, @"comparison_code");
    if (code) {
        // Letter-spaced like the mockup; the digits are the snapshot's, untouched.
        NSMutableParagraphStyle *centred = [NSMutableParagraphStyle new];
        centred.alignment = NSTextAlignmentCenter;
        _code.attributedStringValue = [[NSAttributedString alloc]
            initWithString:code
                attributes:@{NSFontAttributeName : _code.font, NSForegroundColorAttributeName : _code.textColor,
                             NSKernAttributeName : @3, NSParagraphStyleAttributeName : centred}];
    } else {
        _code.stringValue = @"";
    }
    _code.alignment = NSTextAlignmentCenter;
    _code.accessibilityLabel = SZFStr(request, @"comparison_code_accessibility_label");
    _footnote.stringValue = SZFStr(request, @"footnote") ?: @"";
    NSDictionary *ids = conversationID ? @{@"conversation_id" : conversationID} : @{};
    // Unchanged actions keep their buttons, so an armed "Block?" survives a snapshot that changed something else.
    NSArray *previous = self.actionButtons;
    NSArray<SZFriendsActionButton *> *all = SZFriendsActionButtonsFor(SZFArr(request, @"actions"), ids, _context,
                                                                      previous);
    for (NSView *old in previous)
        if (![(NSArray *)all containsObject:old]) [old removeFromSuperview];
    NSMutableArray *buttons = [NSMutableArray array], *links = [NSMutableArray array];
    for (SZFriendsActionButton *button in all) {
        SZFriendsButtonStyle style = button.style;
        BOOL inRow = style == SZFriendsButtonStylePrimary || style == SZFriendsButtonStyleSecondary;
        if (inRow) button.font = SZFriendsSemibold(_context.appearance.bodyFont);
        [(inRow ? buttons : links) addObject:button];
        if (button.superview != self) [self addSubview:button];
    }
    _buttons = buttons;
    _links = links;
    [self setNeedsLayout:YES];
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat inner = width - 44, y = 26;
    if (apply) _avatar.frame = NSMakeRect(floor((width - 64) / 2), y, 64, 64);
    y += 64 + 16;
    y = apply ? SZFriendsPlace(_title, 22, y, inner) : y + SZFriendsFieldHeight(_title, inner);
    y += 4;
    y = apply ? SZFriendsPlace(_subtitle, 22, y, inner) : y + SZFriendsFieldHeight(_subtitle, inner);
    y += 16;
    CGFloat promptHeight = SZFriendsFieldHeight(_codePrompt, inner - 28);
    CGFloat codeHeight = SZFriendsFieldHeight(_code, inner - 28);
    CGFloat boxHeight = 14 + promptHeight + (codeHeight ? 8 + codeHeight : 0) + 14;
    if (apply) {
        _codeBox.frame = NSMakeRect(22, y, inner, boxHeight);
        _codePrompt.frame = NSMakeRect(14, 14, inner - 28, promptHeight);
        _code.frame = NSMakeRect(14, 14 + promptHeight + 8, inner - 28, codeHeight);
        _code.hidden = codeHeight == 0;
    }
    y += boxHeight + 16;
    if (_buttons.count) {
        CGFloat total = 0;
        for (SZFriendsButton *button in _buttons) total += MAX(84, [button fittingWidth] + 12) + 10;
        CGFloat x = floor((width - total + 10) / 2);
        for (SZFriendsButton *button in _buttons) {
            CGFloat buttonWidth = MAX(84, [button fittingWidth] + 12);
            if (apply) button.frame = NSMakeRect(x, y, buttonWidth, 32);
            x += buttonWidth + 10;
        }
        y += 32 + 12;
    }
    for (SZFriendsButton *link in _links) {
        CGFloat linkWidth = [link fittingWidth] + 8;
        if (apply) link.frame = NSMakeRect(floor((width - linkWidth) / 2), y, linkWidth, 20);
        y += 20 + 8;
    }
    if (_footnote.stringValue.length) {
        y += 8;
        CGFloat footnoteHeight = SZFriendsFieldHeight(_footnote, inner);
        // At the foot of the card when it is taller than its content, as the mockup places it.
        CGFloat bottom = apply ? MAX(y, NSHeight(self.bounds) - 22 - footnoteHeight) : y;
        if (apply) SZFriendsPlace(_footnote, 22, bottom, inner);
        y += footnoteHeight;
    }
    return y + 22;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutForWidth:width apply:NO];
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

@end
