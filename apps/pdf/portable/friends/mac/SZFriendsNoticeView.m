// SZFriendsNoticeView: the one layout behind every card and quiet line in the list and Nearby.

#import "mac/SZFriendsListPage.h"

@implementation SZFriendsNoticeView {
    SZFriendsContext *_context;
    NSDictionary *_action;
    void (^_onPress)(NSDictionary *action);
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 376, 40)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    _titleLabel = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _bodyLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _noteLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    for (NSTextField *label in @[ _titleLabel, _bodyLabel, _noteLabel ]) [self addSubview:label];
    _padding = 12;
    self.cornerRadius = 10;
    return self;
}

- (void)setNameEditor:(SZFriendsNameEditor *)nameEditor {
    [_nameEditor removeFromSuperview];
    _nameEditor = nameEditor;
    if (nameEditor) [self addSubview:nameEditor];
}

- (void)setBigLabel:(NSTextField *)bigLabel {
    [_bigLabel removeFromSuperview];
    _bigLabel = bigLabel;
    if (bigLabel) [self addSubview:bigLabel];
}

- (void)setButton:(SZFriendsButton *)button {
    [_button removeFromSuperview];
    _button = button;
    if (button) [self addSubview:button];
}

- (void)setSecondaryButton:(SZFriendsButton *)secondaryButton {
    [_secondaryButton removeFromSuperview];
    _secondaryButton = secondaryButton;
    if (secondaryButton) [self addSubview:secondaryButton];
    [self setNeedsLayout:YES];
}

- (void)setAction:(NSDictionary *)action onPress:(void (^)(NSDictionary *))onPress {
    _onPress = [onPress copy];
    NSString *name = SZFStr(action, @"action");
    if (![SZFriendsContext knowsAction:name]) {
        _action = nil;
        self.button = nil;
        return;
    }
    // Nearby re-renders every second while visible; keep the same button so hover and focus survive the tick.
    BOOL same = self.button && [SZFStr(_action, @"action") isEqualToString:name];
    _action = [action copy];
    SZFriendsButtonStyle style = SZFriendsButtonStyleNamed(SZFStr(action, @"style"));
    if (!same) {
        self.button = [SZFriendsButton buttonWithTitle:@"" style:style appearance:_context.appearance];
        __weak SZFriendsNoticeView *weakSelf = self;
        self.button.onPress = ^(SZFriendsButton *button) {
            (void)button;
            SZFriendsNoticeView *notice = weakSelf;
            if (notice && notice->_onPress && notice->_action) notice->_onPress(notice->_action);
        };
    }
    self.button.style = style;
    self.button.title = SZFStr(action, @"label") ?: @"";
    self.button.needsDisplay = YES;
    [self setNeedsLayout:YES];
}

- (CGFloat)buttonWidth {
    if (!self.button) return 0;
    return MAX(self.button.style == SZFriendsButtonStyleLink ? 0 : 56, [self.button fittingWidth]);
}

- (CGFloat)trailingWidth {
    if (!self.bigLabel && !(self.button && self.buttonTrailing)) return 0;
    NSString *bigText = self.bigLabel.stringValue;
    CGFloat big = bigText.length ? SZFriendsTextWidth(bigText, self.bigLabel.font) + 4 : 0;
    return MAX(big, self.buttonTrailing ? [self buttonWidth] : 0);
}

// One pass computes every frame; -heightForWidth: runs it without touching the views' frames.
- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat pad = self.padding;
    CGFloat x = pad + (self.iconDrawer ? 22 : 0);
    CGFloat trailing = [self trailingWidth];
    CGFloat textWidth = MAX(40, width - x - pad - (trailing ? trailing + 12 : 0));
    CGFloat y = pad;
    BOOL any = NO;
    BOOL buttonOnTop = self.button && !self.buttonTrailing && self.buttonFirst;
    if (buttonOnTop) {
        CGFloat height = self.buttonFullWidth ? 34 : 28;
        CGFloat buttonWidth = self.buttonFullWidth ? width - 2 * pad : MIN([self buttonWidth], textWidth);
        if (apply) self.button.frame = NSMakeRect(self.buttonFullWidth ? pad : x, y, buttonWidth, height);
        y += height + 8;
    }
    for (NSTextField *label in @[ self.titleLabel, self.bodyLabel ]) {
        CGFloat height = SZFriendsFieldHeight(label, textWidth);
        if (!height) {
            if (apply) label.hidden = YES;
            continue;
        }
        if (any) y += 3;
        if (apply) {
            label.frame = NSMakeRect(x, y, textWidth, height);
            label.hidden = NO;
        }
        y += height;
        any = YES;
    }
    if (self.nameEditor && !self.nameEditor.hidden) {
        if (any) y += 8;
        CGFloat height = [self.nameEditor heightForWidth:textWidth];
        if (apply) self.nameEditor.frame = NSMakeRect(x, y, textWidth, height);
        y += height;
        any = YES;
    }
    CGFloat noteHeight = SZFriendsFieldHeight(self.noteLabel, textWidth);
    if (apply) self.noteLabel.hidden = noteHeight == 0;
    if (noteHeight) {
        if (any) y += 6;
        if (apply) self.noteLabel.frame = NSMakeRect(x, y, textWidth, noteHeight);
        y += noteHeight;
        any = YES;
    }
    if (self.button && !self.buttonTrailing && !buttonOnTop) {
        BOOL link = self.button.style == SZFriendsButtonStyleLink;
        CGFloat height = self.buttonFullWidth ? 34 : (link ? 18 : 28);
        if (any) y += link ? 2 : 8;
        CGFloat buttonWidth = self.buttonFullWidth ? width - 2 * pad : MIN([self buttonWidth], textWidth);
        CGFloat buttonX = self.buttonFullWidth ? pad : x - (link ? 2 : 0);
        if (apply) self.button.frame = NSMakeRect(buttonX, y, buttonWidth, height);
        y += height;
    }
    if (self.secondaryButton) {
        if (any) y += 2;
        CGFloat linkWidth = MIN([self.secondaryButton fittingWidth], textWidth);
        if (apply) self.secondaryButton.frame = NSMakeRect(x - 2, y, linkWidth, 18);
        y += 18;
    }
    CGFloat bottom = y + pad;
    if (trailing) {
        CGFloat bigHeight = self.bigLabel ? SZFriendsFieldHeight(self.bigLabel, trailing) : 0;
        CGFloat columnHeight = bigHeight + (self.bigLabel && self.button ? 6 : 0) + (self.button ? 26 : 0);
        bottom = MAX(bottom, columnHeight + 2 * pad);
        CGFloat columnY = self.bigLabel ? pad : floor((bottom - columnHeight) / 2);
        CGFloat columnX = width - pad - trailing;
        if (apply && self.bigLabel) self.bigLabel.frame = NSMakeRect(columnX, columnY, trailing, bigHeight);
        if (apply && self.button) {
            CGFloat buttonWidth = [self buttonWidth];
            self.button.frame = NSMakeRect(columnX + floor((trailing - buttonWidth) / 2), columnY + columnHeight - 26,
                                           buttonWidth, 26);
        }
    }
    return ceil(bottom);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutForWidth:width apply:NO];
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.iconDrawer)
        self.iconDrawer(NSMakeRect(self.padding, self.padding + 1, 14, 14),
                        self.iconColor ?: _context.appearance.secondaryTextColor);
}

@end
