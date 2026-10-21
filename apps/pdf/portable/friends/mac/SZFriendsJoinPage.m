// SZFriendsJoinPage: a new computer joining the person's existing profile (PROTOCOL.md § Joining, snapshot.join).

#import "mac/SZFriendsDevices.h"

@interface SZFriendsJoinPage () <NSTextFieldDelegate>
@end

@implementation SZFriendsJoinPage {
    NSDictionary *_data;
    NSString *_token;
    NSString *_replyError; // a refused join_profile or enter_join_code, until the next snapshot changes the state
    NSMutableArray<SZFriendsActionButton *> *_buttons;
    SZFriendsFlippedView *_routeIcon;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithContext:context])) return nil;
    SZFriendsAppearance *appearance = context.appearance;
    __weak SZFriendsJoinPage *weakSelf = self;
    _header = [[SZFriendsHeaderView alloc] initWithAppearance:appearance];
    _header.backButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf.context.navigator goBack];
    };
    [_header setBack:nil fallbackLabel:[context string:@"back"]];
    [self addSubview:_header];
    _titleLabel = SZFriendsLabel(@"", [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold],
                                 appearance.primaryTextColor);
    _messageLabel = SZFriendsLabel(@"", appearance.bodyFont, appearance.secondaryTextColor);
    _errorLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.destructiveColor);
    _routeLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    for (NSTextField *label in @[ _titleLabel, _messageLabel, _errorLabel, _routeLabel ]) {
        label.alignment = NSTextAlignmentCenter;
        [self addSubview:label];
    }
    _routeIcon = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 11, 11)];
    _routeIcon.drawContents = ^(SZFriendsFlippedView *view) {
        SZFriendsJoinPage *page = weakSelf;
        NSDictionary *route = page ? SZFDict(page->_data, @"route") : nil;
        SZFriendsDrawRouteIcon(SZFriendsRouteGlyph(route), view.bounds,
                               SZFriendsRouteColor(page.context.appearance, SZFStr(route, @"kind")));
    };
    _routeIcon.hidden = YES;
    [self addSubview:_routeIcon];
    _idField = [NSTextField textFieldWithString:@""];
    _idField.font = appearance.bodyFont;
    // The code is read back digit by digit: monospaced digits, large, so a typo stands out against the other screen.
    _codeField = [NSTextField textFieldWithString:@""];
    _codeField.font = [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightMedium];
    _codeField.alignment = NSTextAlignmentCenter;
    for (NSTextField *field in @[ _idField, _codeField ]) {
        field.bezelStyle = NSTextFieldRoundedBezel;
        field.delegate = self;
        field.hidden = YES;
        [self addSubview:field];
    }
    _idButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:appearance];
    _idButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf submitID];
    };
    _codeButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:appearance];
    _codeButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf submitCode];
    };
    for (SZFriendsButton *button in @[ _idButton, _codeButton ]) {
        button.hidden = YES;
        [self addSubview:button];
    }
    _buttons = [NSMutableArray array];
    return self;
}

- (SZFriendsDropdownView)kind {
    return SZFriendsDropdownViewJoin;
}

- (NSView *)routeIconView {
    return _routeIcon;
}

- (NSArray<SZFriendsActionButton *> *)actionButtons {
    return [_buttons copy];
}

- (NSView *)preferredFirstResponder {
    if (!_codeField.hidden) return _codeField;
    if (!_idField.hidden) return _idField;
    return _buttons.firstObject;
}

- (void)pageWillAppear {
    [super pageWillAppear];
    __weak SZFriendsJoinPage *weakSelf = self;
    _token = [self.context.link subscribeToView:@"join" params:nil handler:^(NSDictionary *data, NSInteger rev) {
        (void)rev;
        [weakSelf applySnapshot:data];
    }];
}

- (void)pageDidDisappear {
    [super pageDidDisappear];
    if (_token) [self.context.link unsubscribe:_token];
    _token = nil;
}

#pragma mark - Rendering

- (void)applySnapshot:(NSDictionary *)data {
    NSString *previousState = SZFStr(_data, @"state");
    _data = [data copy];
    if (![previousState isEqualToString:SZFStr(data, @"state")]) _replyError = nil;
    _titleLabel.stringValue = SZFStr(data, @"title") ?: @"";
    _messageLabel.stringValue = SZFStr(data, @"message") ?: @"";
    NSDictionary *route = SZFDict(data, @"route");
    _routeLabel.stringValue = SZFStr(route, @"label") ?: @"";
    _routeLabel.textColor = SZFriendsRouteColor(self.context.appearance, SZFStr(route, @"kind"));
    _routeIcon.hidden = !SZFriendsRouteGlyph(route) || !_routeLabel.stringValue.length;
    _routeIcon.needsDisplay = YES;
    NSDictionary *idField = SZFDict(data, @"id_field");
    _idField.hidden = _idButton.hidden = idField == nil;
    _idField.placeholderString = SZFStr(idField, @"placeholder");
    _idField.accessibilityLabel = SZFStr(idField, @"placeholder");
    _idButton.title = SZFStr(idField, @"button") ?: @"";
    NSDictionary *codeField = SZFDict(data, @"code_field");
    BOOL codeShown = codeField != nil;
    // A new code field starts empty; the same one keeps what is typed while a check runs.
    if (codeShown && _codeField.hidden) _codeField.stringValue = @"";
    _codeField.hidden = _codeButton.hidden = !codeShown;
    _codeField.placeholderString = SZFStr(codeField, @"placeholder");
    _codeField.accessibilityLabel = SZFStr(codeField, @"placeholder");
    _codeField.enabled = _codeButton.enabled = SZFBool(codeField, @"enabled");
    _codeButton.title = SZFStr(codeField, @"button") ?: @"";
    NSString *error = SZFStr(data, @"error");
    if (error.length && ![error isEqualToString:_errorLabel.stringValue]) {
        // A wrong code leaves the field empty for the next try; it is the one thing to fix now.
        _codeField.stringValue = @"";
        [self.context announce:error];
    }
    _errorLabel.stringValue = error ?: _replyError ?: @"";
    NSArray *previous = [_buttons copy];
    NSArray *buttons = SZFriendsActionButtonsFor(SZFArr(data, @"actions"), nil, self.context, previous);
    for (NSView *old in previous)
        if (![buttons containsObject:old]) [old removeFromSuperview];
    __weak SZFriendsJoinPage *weakSelf = self;
    for (SZFriendsActionButton *button in buttons) {
        button.onReply = ^(NSDictionary *result, SZFriendsLinkError *failure) {
            (void)result;
            [weakSelf showReplyError:failure];
        };
        if (!button.superview) [self addSubview:button];
    }
    [_buttons setArray:buttons];
    [self setNeedsLayout:YES];
}

- (void)showReplyError:(SZFriendsLinkError *)error {
    if (!error.message.length) return;
    _replyError = [error.message copy];
    _errorLabel.stringValue = _replyError;
    [self.context announce:_replyError];
    [self setNeedsLayout:YES];
}

#pragma mark - Sending

- (void)submitID {
    NSString *typed = [_idField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (_idField.hidden || !typed.length) return;
    [self send:@"join_profile" fields:@{@"friends_id" : typed} button:_idButton];
}

- (void)submitCode {
    NSString *typed = [_codeField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (_codeField.hidden || !_codeField.enabled || !typed.length) return;
    [self send:@"enter_join_code" fields:@{@"code" : typed} button:_codeButton];
}

// The button rests until the reply, so a double press asks once; the snapshot before the reply shows what follows.
- (void)send:(NSString *)intent fields:(NSDictionary *)fields button:(SZFriendsButton *)button {
    button.enabled = NO;
    __weak SZFriendsJoinPage *weakSelf = self;
    [self.context.link sendIntent:intent fields:fields reply:^(NSDictionary *result, SZFriendsLinkError *error) {
        (void)result;
        SZFriendsJoinPage *page = weakSelf;
        if (!page) return;
        BOOL enabled = button != page->_codeButton || SZFBool(SZFDict(page->_data, @"code_field"), @"enabled");
        button.enabled = enabled;
        [page showReplyError:error];
    }];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)textView;
    if (command == @selector(cancelOperation:)) {
        SZFriendsForwardEscape(self);
        return YES;
    }
    if (command != @selector(insertNewline:)) return NO;
    if (control == _codeField) [self submitCode];
    else [self submitID];
    return YES;
}

- (BOOL)dismissInnermostPicker {
    return SZFriendsDisarmActionButtons(self);
}

#pragma mark - Layout

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), pad = 24, inner = width - 2 * pad, y = SZFriendsHeaderHeight + 20;
    _header.frame = NSMakeRect(0, 0, width, SZFriendsHeaderHeight);
    for (NSTextField *label in @[ _titleLabel, _messageLabel ]) {
        label.hidden = label.stringValue.length == 0;
        if (!label.hidden) y = SZFriendsPlace(label, pad, y, inner) + 8;
    }
    // The route line, centred: its icon, 4 points, then its words.
    _routeLabel.hidden = _routeLabel.stringValue.length == 0;
    if (_routeLabel.hidden) _routeIcon.hidden = YES;
    else {
        CGFloat icon = _routeIcon.hidden ? 0 : 15;
        CGFloat words = MIN(ceil(_routeLabel.intrinsicContentSize.width), inner - icon);
        CGFloat x = floor((width - icon - words) / 2);
        _routeIcon.frame = NSMakeRect(x, y + 2, 11, 11);
        _routeLabel.frame = NSMakeRect(x + icon, y, words, 16);
        y += 16 + 8;
    }
    y += 8;
    if (!_idField.hidden) {
        CGFloat buttonWidth = MAX(88, [_idButton fittingWidth]);
        _idField.frame = NSMakeRect(pad, y, inner - buttonWidth - 8, 28);
        _idButton.frame = NSMakeRect(width - pad - buttonWidth, y, buttonWidth, 28);
        y += 28 + 12;
    }
    if (!_codeField.hidden) {
        // The code field on its own line, wide enough for eight digits and a space at any dropdown width.
        _codeField.frame = NSMakeRect(pad, y, inner, 40);
        y += 40 + 8;
        CGFloat buttonWidth = MAX(120, [_codeButton fittingWidth]);
        _codeButton.frame = NSMakeRect(floor((width - buttonWidth) / 2), y, buttonWidth, 30);
        y += 30 + 12;
    }
    _errorLabel.hidden = _errorLabel.stringValue.length == 0;
    if (!_errorLabel.hidden) y = SZFriendsPlace(_errorLabel, pad, y, inner) + 12;
    CGFloat total = 0;
    for (SZFriendsButton *button in _buttons) total += MAX(96, [button fittingWidth]) + 8;
    CGFloat x = floor((width - MAX(0, total - 8)) / 2);
    for (SZFriendsButton *button in _buttons) {
        CGFloat buttonWidth = MAX(96, [button fittingWidth]);
        button.frame = NSMakeRect(x, y, buttonWidth, 30);
        x += buttonWidth + 8;
    }
}

@end
