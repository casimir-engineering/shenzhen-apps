// SZFriendsLinkPage: what a friend link or a download link says, before anything happens (PROTOCOL.md § Links).

#import "mac/SZFriendsLinkPage.h"

@implementation SZFriendsLinkPage {
    NSDictionary *_card;
    SZFriendsAvatarView *_avatar;
    NSMutableArray<SZFriendsButton *> *_buttons;
    BOOL _asked;
    BOOL _observing;
}

- (instancetype)initWithContext:(SZFriendsContext *)context payload:(NSString *)payload {
    if (!(self = [super initWithContext:context])) return nil;
    _payload = [payload copy];
    SZFriendsAppearance *appearance = context.appearance;
    __weak SZFriendsLinkPage *weakSelf = self;
    _header = [[SZFriendsHeaderView alloc] initWithAppearance:appearance];
    _header.backButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf.context.navigator goBack];
    };
    [_header setBack:nil fallbackLabel:[context string:@"back"]];
    [self addSubview:_header];
    _avatar = [SZFriendsAvatarView new];
    _avatar.hidden = YES;
    NSFont *titleFont = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    _titleLabel = SZFriendsLabel(@"", titleFont, appearance.primaryTextColor);
    _subtitleLabel = SZFriendsLabel(@"", appearance.bodyFont, appearance.secondaryTextColor);
    _noteLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _messageLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    for (NSTextField *label in @[ _titleLabel, _subtitleLabel, _noteLabel, _messageLabel ]) {
        label.alignment = NSTextAlignmentCenter;
        [self addSubview:label];
    }
    [self addSubview:_avatar];
    _buttons = [NSMutableArray array];
    return self;
}

- (void)dealloc {
    [self stopWaiting];
}

- (SZFriendsDropdownView)kind {
    return SZFriendsDropdownViewLink;
}

- (NSArray<SZFriendsButton *> *)actionButtons {
    return [_buttons copy];
}

- (NSView *)preferredFirstResponder {
    return _buttons.firstObject;
}

- (void)pageWillAppear {
    [super pageWillAppear];
    if (!_card && !_asked) [self ask];
}

#pragma mark - Asking the helper

- (void)ask {
    _asked = YES;
    __weak SZFriendsLinkPage *weakSelf = self;
    [self.context.link sendIntent:@"open_link" fields:@{@"payload" : _payload}
                            reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                [weakSelf answered:result error:error];
                            }];
}

- (void)answered:(NSDictionary *)result error:(SZFriendsLinkError *)error {
    if ([error.code isEqualToString:@"not_ready"] || [error.code isEqualToString:@"connection_lost"]) {
        // The helper is starting or handing over: the dropdown's status line says so, and the link is asked about
        // again as soon as it answers, so the person never has to open the link twice.
        [self waitForHelper];
        return;
    }
    if (error) [self applyError:error.message];
    else [self applyCard:SZFDict(result, @"card")];
}

- (void)waitForHelper {
    // The refusal may arrive after the helper came back (it is delivered on a later turn of the run loop).
    if (self.context.link.state == SZFriendsLinkStateReady) {
        [self ask];
        return;
    }
    if (_observing) return;
    _observing = YES;
    [self.context.link addObserver:self forKeyPath:@"state" options:0 context:NULL];
}

- (void)stopWaiting {
    if (!_observing) return;
    _observing = NO;
    [self.context.link removeObserver:self forKeyPath:@"state"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change
                       context:(void *)context {
    (void)keyPath, (void)object, (void)change, (void)context;
    if (self.context.link.state != SZFriendsLinkStateReady) return;
    [self stopWaiting];
    [self ask];
}

#pragma mark - Rendering

- (void)applySnapshot:(NSDictionary *)data {
    [self applyCard:data];
}

- (void)applyCard:(NSDictionary *)card {
    _card = [card copy];
    _avatar.avatar = SZFDict(card, @"avatar");
    _avatar.hidden = _avatar.avatar == nil;
    _titleLabel.stringValue = SZFStr(card, @"title") ?: @"";
    _subtitleLabel.stringValue = SZFStr(card, @"subtitle") ?: @"";
    _noteLabel.stringValue = SZFStr(card, @"note") ?: @"";
    _messageLabel.stringValue = @"";
    [self rebuildButtons:SZFArr(card, @"actions")];
    [self setNeedsLayout:YES];
}

- (void)applyError:(NSString *)message {
    _card = nil;
    _avatar.hidden = YES;
    for (NSTextField *label in @[ _titleLabel, _subtitleLabel, _noteLabel ]) label.stringValue = @"";
    [self rebuildButtons:@[]];
    [self showMessage:message failed:YES];
}

- (void)showMessage:(NSString *)message failed:(BOOL)failed {
    SZFriendsAppearance *appearance = self.context.appearance;
    _messageLabel.stringValue = message ?: @"";
    _messageLabel.textColor = failed ? appearance.destructiveColor : appearance.primaryTextColor;
    // It appears where nothing had focus: VoiceOver hears it too.
    [self.context announce:message];
    [self setNeedsLayout:YES];
}

- (void)rebuildButtons:(NSArray *)actions {
    for (NSView *button in _buttons) [button removeFromSuperview];
    [_buttons removeAllObjects];
    __weak SZFriendsLinkPage *weakSelf = self;
    for (id action in actions) {
        if (![action isKindOfClass:NSDictionary.class] || ![SZFriendsContext knowsAction:SZFStr(action, @"action")])
            continue;
        SZFriendsButton *button = [SZFriendsButton buttonWithTitle:SZFStr(action, @"label") ?: @""
                                                            style:SZFriendsButtonStyleNamed(SZFStr(action, @"style"))
                                                       appearance:self.context.appearance];
        NSDictionary *pressed = action;
        button.onPress = ^(SZFriendsButton *sender) {
            (void)sender;
            [weakSelf perform:pressed];
        };
        [_buttons addObject:button];
        [self addSubview:button];
    }
}

- (void)perform:(NSDictionary *)action {
    for (SZFriendsButton *button in _buttons) button.enabled = NO;
    __weak SZFriendsLinkPage *weakSelf = self;
    [self.context performAction:action ids:nil reply:^(NSDictionary *result, SZFriendsLinkError *error) {
        SZFriendsLinkPage *page = weakSelf;
        if (!page) return;
        for (SZFriendsButton *button in page->_buttons) button.enabled = error != nil;
        if (error) {
            [page showMessage:error.message failed:YES];
            return;
        }
        [page showMessage:SZFStr(result, @"message") failed:NO];
        // The request or the incoming file lives in its conversation from now on, with its progress.
        NSString *conversationID = SZFStr(result, @"conversation_id");
        if (conversationID.length) [page.context.navigator openConversation:conversationID highlightMessage:nil];
    }];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), pad = 24, inner = width - 2 * pad, y = SZFriendsHeaderHeight + 20;
    _header.frame = NSMakeRect(0, 0, width, SZFriendsHeaderHeight);
    if (!_avatar.hidden) {
        _avatar.frame = NSMakeRect(floor((width - 56) / 2), y, 56, 56);
        y += 56 + 12;
    }
    for (NSTextField *label in @[ _titleLabel, _subtitleLabel, _noteLabel ]) {
        label.hidden = label.stringValue.length == 0;
        if (!label.hidden) y = SZFriendsPlace(label, pad, y, inner) + (label == _noteLabel ? 4 : 6);
    }
    y += 12;
    CGFloat total = 0;
    for (SZFriendsButton *button in _buttons) total += MAX(96, [button fittingWidth]) + 8;
    CGFloat x = floor((width - MAX(0, total - 8)) / 2);
    for (SZFriendsButton *button in _buttons) {
        CGFloat buttonWidth = MAX(96, [button fittingWidth]);
        button.frame = NSMakeRect(x, y, buttonWidth, 30);
        x += buttonWidth + 8;
    }
    if (_buttons.count) y += 30 + 12;
    _messageLabel.hidden = _messageLabel.stringValue.length == 0;
    if (!_messageLabel.hidden) SZFriendsPlace(_messageLabel, pad, y, inner);
}

@end
