// The list's rows for several computers (PROTOCOL.md § Devices, § Joining): a join request waiting on this computer,
// with Approve and Deny, then the code to type on the new one; and the notice that this computer was removed.

#import "mac/SZFriendsDevices.h"

@implementation SZFriendsJoinRequestView {
    SZFriendsContext *_context;
    NSMutableArray<SZFriendsActionButton *> *_buttons;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 376, 80)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    // Drawn like the rows waiting for an answer: the accent says this one needs the person.
    self.fillColor = [appearance.accentColor colorWithAlphaComponent:0.08];
    self.strokeColor = [appearance.accentColor colorWithAlphaComponent:0.5];
    self.cornerRadius = 10;
    _titleLabel = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _subtitleLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    // The code is read off this screen and typed on the other: large monospaced digits, selectable so it can be
    // checked character by character, read aloud digit by digit.
    _codeLabel = SZFriendsLabel(@"", [NSFont monospacedDigitSystemFontOfSize:28 weight:NSFontWeightSemibold],
                                appearance.primaryTextColor);
    _codeLabel.selectable = YES;
    _codeLabel.alignment = NSTextAlignmentCenter;
    _codeNoteLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    for (NSTextField *label in @[ _titleLabel, _subtitleLabel, _codeLabel, _codeNoteLabel ]) [self addSubview:label];
    _buttons = [NSMutableArray array];
    self.accessibilityElement = NO;
    return self;
}

- (NSArray<SZFriendsActionButton *> *)actionButtons {
    return [_buttons copy];
}

- (void)applyRequest:(NSDictionary *)request {
    _joinID = [SZFStr(request, @"join_id") copy];
    _titleLabel.stringValue = SZFStr(request, @"title") ?: @"";
    _subtitleLabel.stringValue = SZFStr(request, @"subtitle") ?: @"";
    _codeLabel.stringValue = SZFStr(request, @"code") ?: @"";
    _codeLabel.accessibilityLabel = SZFStr(request, @"code_accessibility_label");
    _codeNoteLabel.stringValue = SZFStr(request, @"code_note") ?: @"";
    _titleLabel.accessibilityLabel = SZFStr(request, @"accessibility_label");
    NSArray *previous = [_buttons copy];
    NSArray *buttons = SZFriendsActionButtonsFor(SZFArr(request, @"actions"), nil, _context, previous);
    for (NSView *old in previous)
        if (![buttons containsObject:old]) [old removeFromSuperview];
    for (SZFriendsActionButton *button in buttons) {
        if (!button.superview) [self addSubview:button];
        // One press approves: a second one, before the code shows, would only ask again.
        button.disablesOncePressed = [SZFStr(button.actionObject, @"action") isEqualToString:@"approve_join"];
    }
    [_buttons setArray:buttons];
    [self setNeedsLayout:YES];
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat pad = 12, inner = width - 2 * pad, y = pad;
    for (NSTextField *label in @[ _titleLabel, _subtitleLabel ]) {
        CGFloat height = SZFriendsFieldHeight(label, inner);
        if (apply) label.frame = NSMakeRect(pad, y, inner, height);
        y += height + 3;
    }
    BOOL code = _codeLabel.stringValue.length > 0;
    if (apply) _codeLabel.hidden = !code;
    if (code) {
        CGFloat height = SZFriendsFieldHeight(_codeLabel, inner);
        if (apply) _codeLabel.frame = NSMakeRect(pad, y + 6, inner, height);
        y += height + 12;
    }
    CGFloat noteHeight = SZFriendsFieldHeight(_codeNoteLabel, inner);
    if (apply) _codeNoteLabel.hidden = noteHeight == 0;
    if (noteHeight) {
        if (apply) _codeNoteLabel.frame = NSMakeRect(pad, y, inner, noteHeight);
        y += noteHeight + 3;
    }
    if (_buttons.count) {
        CGFloat x = pad;
        y += 6;
        for (SZFriendsActionButton *button in _buttons) {
            CGFloat buttonWidth = MAX(80, [button fittingWidth]);
            if (apply) button.frame = NSMakeRect(x, y, buttonWidth, 28);
            x += buttonWidth + 8;
        }
        y += 28;
    }
    return ceil(y + pad);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutForWidth:width apply:NO];
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

@end

@implementation SZFriendsListDevicesView {
    SZFriendsContext *_context;
    NSMutableArray<SZFriendsJoinRequestView *> *_requests;
    NSDictionary *_joinAction; // the list's join action while offered
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 376, 10)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    _removedNotice = [[SZFriendsNoticeView alloc] initWithContext:context];
    _removedNotice.fillColor = [appearance.warningColor colorWithAlphaComponent:0.14];
    _removedNotice.padding = 10;
    _removedNotice.bodyLabel.textColor = appearance.primaryTextColor;
    _removedNotice.hidden = YES;
    [self addSubview:_removedNotice];
    _joinNotice = [[SZFriendsNoticeView alloc] initWithContext:context];
    _joinNotice.fillColor = appearance.fieldBackgroundColor;
    _joinNotice.padding = 10;
    _joinNotice.hidden = YES;
    [self addSubview:_joinNotice];
    _requests = [NSMutableArray array];
    self.hidden = YES;
    return self;
}

- (NSArray<SZFriendsJoinRequestView *> *)requestViews {
    return [_requests copy];
}

// A link button that runs the list's current join action (open_join, or Reset Friends with its confirmation first).
- (SZFriendsButton *)joinButtonWithLabel:(NSString *)label {
    SZFriendsButton *button = [SZFriendsButton buttonWithTitle:label style:SZFriendsButtonStyleLink
                                                    appearance:_context.appearance];
    __weak SZFriendsListDevicesView *weakSelf = self;
    button.onPress = ^(SZFriendsButton *pressed) {
        (void)pressed;
        SZFriendsListDevicesView *view = weakSelf;
        if (view) [view->_context performAction:view->_joinAction ids:nil done:nil];
    };
    return button;
}

- (void)offerJoin:(NSDictionary *)join inPrompt:(SZFriendsNoticeView *)prompt promptShown:(BOOL)promptShown {
    NSDictionary *action = SZFDict(join, @"action");
    NSString *label = SZFStr(action, @"label"), *note = SZFStr(join, @"note");
    BOOL offered = label.length && [SZFriendsContext knowsAction:SZFStr(action, @"action")];
    _joinAction = offered ? action : nil;
    // In the name prompt while it shows, its note as the link's tooltip; else a card of its own above the rows.
    if (offered && promptShown) {
        if (![prompt.secondaryButton.title isEqualToString:label]) prompt.secondaryButton = [self joinButtonWithLabel:label];
        prompt.secondaryButton.toolTip = note;
    } else {
        prompt.secondaryButton = nil;
    }
    BOOL card = offered && !promptShown;
    _joinNotice.hidden = !card;
    _joinNotice.bodyLabel.stringValue = card ? note ?: @"" : @"";
    if (!card) _joinNotice.secondaryButton = nil;
    else if (![_joinNotice.secondaryButton.title isEqualToString:label])
        _joinNotice.secondaryButton = [self joinButtonWithLabel:label];
    self.hidden = _removedNotice.hidden && _joinNotice.hidden && _requests.count == 0;
    [self setNeedsLayout:YES];
}

- (void)applyList:(NSDictionary *)data {
    NSDictionary *removed = SZFDict(data, @"removed");
    _removed = [SZFStr(data, @"state") isEqualToString:@"device_removed"];
    _removedNotice.hidden = removed == nil;
    _removedNotice.titleLabel.stringValue = SZFStr(removed, @"title") ?: @"";
    _removedNotice.bodyLabel.stringValue = SZFStr(removed, @"body") ?: @"";
    __weak SZFriendsListDevicesView *weakSelf = self;
    [_removedNotice setAction:SZFDict(removed, @"action") onPress:^(NSDictionary *action) {
        SZFriendsListDevicesView *view = weakSelf;
        if (view) [view->_context performAction:action ids:nil done:nil];
    }];
    // A removed computer answers no request: the rows are gone with everything else that would send.
    NSArray *requests = _removed ? @[] : SZFArr(data, @"join_requests");
    while (_requests.count > requests.count) {
        [_requests.lastObject removeFromSuperview];
        [_requests removeLastObject];
    }
    while (_requests.count < requests.count) {
        SZFriendsJoinRequestView *view = [[SZFriendsJoinRequestView alloc] initWithContext:_context];
        [_requests addObject:view];
        [self addSubview:view];
    }
    [requests enumerateObjectsUsingBlock:^(id request, NSUInteger index, BOOL *stop) {
        (void)stop;
        [self->_requests[index] applyRequest:[request isKindOfClass:NSDictionary.class] ? request : @{}];
    }];
    self.hidden = _removedNotice.hidden && _joinNotice.hidden && _requests.count == 0;
    [self setNeedsLayout:YES];
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat y = 0;
    NSMutableArray<NSView *> *shown = [NSMutableArray array];
    if (!_joinNotice.hidden) [shown addObject:_joinNotice];
    if (!_removedNotice.hidden) [shown addObject:_removedNotice];
    [shown addObjectsFromArray:_requests];
    for (NSView *view in shown) {
        CGFloat height = [(id)view heightForWidth:width];
        if (apply) view.frame = NSMakeRect(0, y, width, height);
        y += height + 8;
    }
    return shown.count ? y - 8 : 0;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutForWidth:width apply:NO];
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

@end
