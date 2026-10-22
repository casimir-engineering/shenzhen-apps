// SZFriendsDetailsPage: a friend's details, opened from the conversation header.

#import "mac/SZFriendsDetailsPage.h"

#import "mac/SZFriendsArming.h"

@implementation SZFriendsDetailsPage {
    NSString *_token;
    NSDictionary *_data;
    NSScrollView *_scroll;
    SZFriendsFlippedView *_content;
    SZFriendsAvatarView *_avatar;
    NSTextField *_routeLabel;
    SZFriendsFlippedView *_routeIcon; // the route's icon before its words, as the conversation header draws it
    NSTextField *_idLabel;
    NSView *_attestationView;
    NSTextField *_confirmedLabel;
    NSTextField *_verifyLabel;
    NSTextField *_verifyBody;
    NSTextField *_verifyCode;
    NSArray<SZFriendsActionButton *> *_verifyButtons;
    BOOL _verified;
    NSTextField *_autoTitle;
    NSTextField *_autoBody;
    NSTextField *_receivedLabel;
    NSArray<SZFriendsActionButton *> *_receivedButtons;
    SZFriendsFlippedView *_keyChange;
    NSTextField *_keyTitle;
    NSTextField *_keyBody;
    NSArray<SZFriendsActionButton *> *_keyButtons;
    NSMutableArray<NSTextField *> *_actionNotes;
    NSArray<SZFriendsActionButton *> *_actionButtons;
    CGFloat _dividerA;
    CGFloat _dividerB;
}

- (instancetype)initWithContext:(SZFriendsContext *)context conversationID:(NSString *)conversationID {
    if (!(self = [super initWithContext:context])) return nil;
    _conversationID = [conversationID copy];
    SZFriendsAppearance *appearance = context.appearance;
    __weak SZFriendsDetailsPage *weakSelf = self;
    _header = [[SZFriendsHeaderView alloc] initWithAppearance:appearance];
    _header.backButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf.context.navigator goBack];
    };
    [self addSubview:_header];
    _content = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    _content.drawContents = ^(SZFriendsFlippedView *view) { [weakSelf drawContent:view]; };
    _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 48, 400, 400)];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.documentView = _content;
    [self addSubview:_scroll];

    _avatar = [SZFriendsAvatarView new];
    _routeLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _routeIcon = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 11, 11)];
    _routeIcon.drawContents = ^(SZFriendsFlippedView *view) {
        SZFriendsDetailsPage *page = weakSelf;
        NSDictionary *route = page ? SZFDict(page->_data, @"route") : nil;
        SZFriendsDrawRouteIcon(SZFriendsRouteGlyph(route), view.bounds,
                               SZFriendsRouteColor(page.context.appearance, SZFStr(route, @"kind")));
    };
    _idLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _cpyButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain appearance:appearance];
    _cpyButton.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawCopyIcon(rect, color); };
    _cpyButton.iconSize = NSMakeSize(12, 12); // a small glyph in a 24 pt target (layout)
    // The small check beside an ID the Friends server confirmed is this person's; its tooltip says so.
    SZFriendsFlippedView *attestation = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 12, 12)];
    attestation.drawContents = ^(SZFriendsFlippedView *view) {
        SZFriendsDrawCheckIcon(view.bounds, appearance.successColor);
    };
    _attestationView = attestation;
    // PROTOCOL.md details: the label itself under the ID line, so what the check means is read, not guessed.
    _confirmedLabel = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    _cpyButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsDetailsPage *page = weakSelf;
        if (page) [page.context copyText:SZFStr(page->_data, @"friends_id")];
    };
    _verifyLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    _verifyBody = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _verifyCode = SZFriendsLabel(@"", [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold],
                                 appearance.primaryTextColor);
    _autoTitle = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _autoBody = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _autoAcceptSwitch = [NSSwitch new];
    _autoAcceptSwitch.target = self;
    _autoAcceptSwitch.action = @selector(autoAcceptToggled:);
    _receivedLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _keyChange = [SZFriendsFlippedView new];
    _keyChange.fillColor = [appearance.warningColor colorWithAlphaComponent:0.14];
    _keyChange.strokeColor = [appearance.warningColor colorWithAlphaComponent:0.45];
    _keyChange.cornerRadius = 10;
    _keyTitle = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _keyBody = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    [_keyChange addSubview:_keyTitle];
    [_keyChange addSubview:_keyBody];
    for (NSView *view in @[ _avatar, _routeIcon, _routeLabel, _idLabel, _attestationView, _confirmedLabel, _cpyButton,
                            _verifyLabel, _verifyBody, _verifyCode, _autoTitle, _autoBody, _autoAcceptSwitch,
                            _receivedLabel, _keyChange ])
        [_content addSubview:view];
    _actionNotes = [NSMutableArray array];
    _actionButtons = @[];
    _keyButtons = @[];
    _verifyButtons = @[];
    _receivedButtons = @[];
    return self;
}

- (SZFriendsDropdownView)kind {
    return SZFriendsDropdownViewDetails;
}

- (NSArray<SZFriendsButton *> *)actionButtons {
    return _actionButtons;
}

- (NSArray<SZFriendsButton *> *)keyChangeButtons {
    return _keyButtons;
}

- (NSView *)keyChangeCard {
    return _keyChange;
}

- (NSView *)verificationLabel {
    return _verifyLabel;
}

- (NSView *)attestationView {
    return _attestationView;
}

- (NSView *)routeIconView {
    return _routeIcon;
}

- (NSTextField *)routeLabel {
    return _routeLabel;
}

// Escape turns an armed "Block?" or "Remove?" back before it closes anything (SZFriendsArming.h).
- (BOOL)dismissInnermostPicker {
    return SZFriendsDisarmActionButtons(self);
}

- (void)pageWillAppear {
    [super pageWillAppear];
    __weak SZFriendsDetailsPage *weakSelf = self;
    _token = [self.context.link subscribeToView:@"details" params:@{@"conversation_id" : _conversationID}
                                        handler:^(NSDictionary *data, NSInteger rev) {
                                            (void)rev;
                                            [weakSelf applySnapshot:data];
                                        }];
}

- (void)pageDidDisappear {
    [super pageDidDisappear];
    if (_token) [self.context.link unsubscribe:_token];
    _token = nil;
}

// Buttons for `actions` inside `container`, keeping those whose action did not change (an armed pill survives a
// snapshot that changed something else). The font is the buttons' own 12 pt semibold, as everywhere else.
- (NSArray<SZFriendsActionButton *> *)buttonsForActions:(NSArray *)actions ids:(NSDictionary *)ids
                                                 inView:(NSView *)container
                                              replacing:(NSArray<SZFriendsActionButton *> *)previous {
    NSArray *buttons = SZFriendsActionButtonsFor(actions, ids, self.context, previous);
    for (SZFriendsActionButton *old in previous)
        if (![buttons containsObject:old]) [old removeFromSuperview];
    for (SZFriendsActionButton *button in buttons)
        if (button.superview != container) [container addSubview:button];
    return buttons;
}

- (void)applySnapshot:(NSDictionary *)data {
    _data = [data copy];
    SZFriendsAppearance *appearance = self.context.appearance;
    NSDictionary *ids = @{@"conversation_id" : SZFStr(data, @"conversation_id") ?: _conversationID};
    [_header setTitle:SZFStr(data, @"title") subtitle:nil subtitleColor:nil clickable:NO accessibilityLabel:nil];
    [_header setBack:SZFDict(data, @"back") fallbackLabel:[self.context string:@"back"]];
    if (self.onBackBadgeChange) self.onBackBadgeChange();
    _avatar.avatar = SZFDict(data, @"avatar");
    NSDictionary *route = SZFDict(data, @"route");
    _routeLabel.stringValue = SZFStr(route, @"label") ?: @"";
    _routeLabel.textColor = SZFriendsRouteColor(appearance, SZFStr(route, @"kind"));
    _routeIcon.hidden = !SZFriendsRouteGlyph(route) || !_routeLabel.stringValue.length;
    _routeIcon.needsDisplay = YES;
    _idLabel.stringValue = SZFStr(data, @"id_label") ?: @"";
    _attestationView.hidden = !SZFBool(data, @"id_confirmed") || !_idLabel.stringValue.length;
    _attestationView.toolTip = SZFStr(data, @"id_confirmed_label");
    _attestationView.accessibilityLabel = _attestationView.toolTip;
    _confirmedLabel.stringValue = _attestationView.hidden ? @"" : (_attestationView.toolTip ?: @"");
    _cpyButton.hidden = !SZFStr(data, @"friends_id");
    _cpyButton.accessibilityLabel = SZFStr(data, @"copy_id_accessibility_label");
    _cpyButton.toolTip = _cpyButton.accessibilityLabel;

    NSDictionary *verification = SZFDict(data, @"verification");
    _verified = [SZFStr(verification, @"state") isEqualToString:@"verified"];
    _verifyLabel.stringValue = SZFStr(verification, @"label") ?: @"";
    _verifyLabel.textColor = _verified ? appearance.successColor : appearance.primaryTextColor;
    _verifyBody.stringValue = SZFStr(verification, @"body") ?: @"";
    _verifyCode.stringValue = SZFStr(verification, @"comparison_code") ?: @"";
    NSDictionary *verifyAction = SZFDict(verification, @"action");
    _verifyButtons = [self buttonsForActions:verifyAction ? @[ verifyAction ] : @[] ids:ids inView:_content
                                   replacing:_verifyButtons];

    NSDictionary *autoAccept = SZFDict(data, @"auto_accept");
    _autoTitle.stringValue = SZFStr(autoAccept, @"title") ?: @"";
    _autoBody.stringValue = SZFStr(autoAccept, @"body") ?: @"";
    _autoAcceptSwitch.state = SZFBool(autoAccept, @"enabled") ? NSControlStateValueOn : NSControlStateValueOff;
    _autoAcceptSwitch.enabled = SZFBool(autoAccept, @"available");
    _autoAcceptSwitch.accessibilityLabel = _autoTitle.stringValue;

    NSDictionary *received = SZFDict(data, @"received");
    _receivedLabel.stringValue = SZFStr(received, @"label") ?: @"";
    NSDictionary *receivedAction = SZFDict(received, @"action");
    _receivedButtons = [self buttonsForActions:receivedAction ? @[ receivedAction ] : @[] ids:ids inView:_content
                                     replacing:_receivedButtons];

    NSDictionary *keyChange = SZFDict(data, @"key_change");
    _keyChange.hidden = keyChange == nil;
    _keyTitle.stringValue = SZFStr(keyChange, @"title") ?: @"";
    _keyBody.stringValue = SZFStr(keyChange, @"body") ?: @"";
    _keyButtons = [self buttonsForActions:SZFArr(keyChange, @"actions") ids:ids inView:_keyChange
                                replacing:_keyButtons];

    _actionButtons = [self buttonsForActions:SZFArr(data, @"actions") ids:ids inView:_content
                                   replacing:_actionButtons];
    for (NSTextField *note in _actionNotes) [note removeFromSuperview];
    [_actionNotes removeAllObjects];
    __weak SZFriendsDetailsPage *weakSelf = self;
    for (SZFriendsActionButton *button in _actionButtons) {
        NSTextField *note = SZFriendsLabel(SZFStr(button.actionObject, @"note"), appearance.secondaryFont,
                                           appearance.secondaryTextColor);
        [_content addSubview:note];
        [_actionNotes addObject:note];
        // Removed, the person is off the list, and their details and chat have nobody to show: back to the list.
        if ([SZFStr(button.actionObject, @"action") isEqualToString:@"remove_friend"]) {
            button.onReply = ^(NSDictionary *result, SZFriendsLinkError *error) {
                (void)result;
                if (!error) [weakSelf.context.navigator popToList];
            };
        }
    }
    [self setNeedsLayout:YES];
    self.needsDisplay = YES;
}

- (void)autoAcceptToggled:(NSSwitch *)sender {
    BOOL enabled = sender.state == NSControlStateValueOn;
    __weak SZFriendsDetailsPage *weakSelf = self;
    NSDictionary *fields = @{@"conversation_id" : _conversationID, @"enabled" : @(enabled)};
    [self.context.link sendIntent:@"set_auto_accept" fields:fields
                            reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                (void)result;
                                // The helper decides; a refused change goes back to what the snapshot says.
                                SZFriendsDetailsPage *page = weakSelf;
                                if (error && page) [page applySnapshot:page->_data];
                            }];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    _header.frame = NSMakeRect(0, 0, width, SZFriendsHeaderHeight);
    _scroll.frame = NSMakeRect(0, SZFriendsHeaderHeight, width, height - SZFriendsHeaderHeight);
    CGFloat pad = 18, inner = width - 2 * pad, y = 18;
    _avatar.frame = NSMakeRect(pad, y, 48, 48);
    CGFloat textX = pad + 60, textWidth = inner - 60;
    // The icon 11 pt and 4 pt from the words, centred on their line, as in the conversation header.
    CGFloat icon = _routeIcon.hidden ? 0 : 15;
    _routeIcon.frame = NSMakeRect(textX, y + 8, 11, 11);
    _routeLabel.frame = NSMakeRect(textX + icon, y + 6, textWidth - icon, 16);
    CGFloat check = _attestationView.hidden ? 0 : 15;
    CGFloat idWidth = MIN(textWidth - 24 - check, SZFriendsTextWidth(_idLabel.stringValue, _idLabel.font) + 4);
    _idLabel.frame = NSMakeRect(textX, y + 25, idWidth, 16);
    _attestationView.frame = NSMakeRect(textX + idWidth + 1, y + 27, 12, 12);
    // A 24 pt target around the small glyph, centred on the ID line, like the row and title-bar buttons.
    _cpyButton.frame = NSMakeRect(textX + idWidth + check, y + 21, 24, 24);
    CGFloat blockBottom = y + 48;
    if (_confirmedLabel.stringValue.length) blockBottom = MAX(blockBottom, SZFriendsPlace(_confirmedLabel, textX,
                                                                                         y + 44, textWidth));
    else _confirmedLabel.hidden = YES;
    y = blockBottom + 14;
    // A changed key is why the person came here (its row says so): its card leads, right under who this is, and
    // the comparison code it asks for follows it.
    if (!_keyChange.hidden) {
        CGFloat cardInner = inner - 24, cardY = 12;
        cardY = SZFriendsPlace(_keyTitle, 12, cardY, cardInner);
        cardY = SZFriendsPlace(_keyBody, 12, cardY + 4, cardInner);
        CGFloat x = 12;
        for (SZFriendsButton *button in _keyButtons) {
            CGFloat buttonWidth = MAX(72, [button fittingWidth]);
            button.frame = NSMakeRect(x, cardY + 10, buttonWidth, 28);
            x += buttonWidth + 8;
        }
        cardY += _keyButtons.count ? 10 + 28 : 0;
        _keyChange.frame = NSMakeRect(pad, y, inner, cardY + 12);
        y += cardY + 12 + 14;
    }
    CGFloat iconSpace = 22;
    y = SZFriendsPlace(_verifyLabel, pad + iconSpace, y, inner - iconSpace);
    if (_verifyBody.stringValue.length) y = SZFriendsPlace(_verifyBody, pad + iconSpace, y + 4, inner - iconSpace);
    else _verifyBody.hidden = YES;
    if (_verifyCode.stringValue.length) y = SZFriendsPlace(_verifyCode, pad + iconSpace, y + 6, inner - iconSpace);
    else _verifyCode.hidden = YES;
    for (SZFriendsButton *button in _verifyButtons) {
        CGFloat buttonWidth = MAX(80, [button fittingWidth]);
        button.frame = NSMakeRect(pad + iconSpace, y + 8, buttonWidth, 28);
        y += 8 + 28;
    }
    y += 14;
    _dividerA = y;
    y += 15;
    NSSize switchSize = _autoAcceptSwitch.fittingSize;
    CGFloat switchWidth = switchSize.width;
    CGFloat autoWidth = inner - switchWidth - 12;
    CGFloat autoTop = y;
    y = SZFriendsPlace(_autoTitle, pad, y, autoWidth);
    y = SZFriendsPlace(_autoBody, pad, y + 4, autoWidth);
    _autoAcceptSwitch.frame = NSMakeRect(width - pad - switchWidth, autoTop, switchWidth, switchSize.height);
    SZFriendsButton *receivedButton = _receivedButtons.firstObject;
    if (_receivedLabel.stringValue.length || receivedButton) {
        y += 14;
        CGFloat buttonWidth = receivedButton ? [receivedButton fittingWidth] : 0;
        _receivedLabel.frame = NSMakeRect(pad, y, inner - buttonWidth - 8, 16);
        receivedButton.frame = NSMakeRect(width - pad - buttonWidth, y - 1, buttonWidth, 18);
        y += 18;
    }
    y += 14;
    _dividerB = y;
    y += 13;
    for (NSUInteger i = 0; i < _actionButtons.count; i++) {
        SZFriendsButton *button = _actionButtons[i];
        BOOL chrome = button.style == SZFriendsButtonStylePrimary || button.style == SZFriendsButtonStyleSecondary;
        CGFloat buttonHeight = chrome ? 28 : 22;
        button.frame = NSMakeRect(pad - (chrome ? 0 : 2), y, [button fittingWidth] + (chrome ? 8 : 0), buttonHeight);
        y += buttonHeight + 2;
        y = SZFriendsPlace(_actionNotes[i], pad, y, inner) + 12;
    }
    _content.frame = NSMakeRect(0, 0, width, MAX(y + 8, NSHeight(_scroll.frame)));
    _content.needsDisplay = YES;
}

// Dividers and the verification icon live in the content's coordinates, so they scroll with everything else.
- (void)drawContent:(SZFriendsFlippedView *)view {
    SZFriendsAppearance *appearance = self.context.appearance;
    [appearance.separatorColor setFill];
    NSRectFill(NSMakeRect(18, _dividerA, NSWidth(view.bounds) - 36, 1));
    NSRectFill(NSMakeRect(18, _dividerB, NSWidth(view.bounds) - 36, 1));
    if (!_verifyLabel.stringValue.length) return;
    NSRect icon = NSMakeRect(18, NSMinY(_verifyLabel.frame) + 1, 14, 14);
    if (_verified) SZFriendsDrawCheckCircleIcon(icon, appearance.successColor);
    else SZFriendsDrawInfoIcon(icon, appearance.secondaryTextColor);
}

@end
