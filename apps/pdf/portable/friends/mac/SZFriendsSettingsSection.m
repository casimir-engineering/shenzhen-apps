// SZFriendsSettingsSection: the Friends part of the host's Settings, below the host's own checkbox and disclosure.

#import "mac/SZFriendsDropdownInternal.h"

// The section's view: rows of (label and note | control), laid out for whatever width Settings gives it, with an
// intrinsic height that follows the snapshot so the host's pane grows and shrinks with it.
@interface SZFriendsSettingsView : SZFriendsFlippedView
@property(nonatomic, copy) CGFloat (^measure)(CGFloat width, BOOL apply);
@end

@implementation SZFriendsSettingsView
- (NSSize)intrinsicContentSize {
    CGFloat width = NSWidth(self.bounds) > 0 ? NSWidth(self.bounds) : 560;
    return NSMakeSize(NSViewNoIntrinsicMetric, self.measure ? self.measure(width, NO) : 0);
}
- (void)layout {
    [super layout];
    if (self.measure) self.measure(NSWidth(self.bounds), YES);
}
- (void)setFrameSize:(NSSize)newSize {
    BOOL widthChanged = newSize.width != NSWidth(self.frame);
    [super setFrameSize:newSize];
    if (widthChanged) [self invalidateIntrinsicContentSize];
}
@end

@interface SZFriendsSettingsSection () <NSTextFieldDelegate>
@end

@implementation SZFriendsSettingsSection {
    SZFriendsSettingsView *_view;
    NSString *_token;
    NSDictionary *_data;
    NSMutableArray<NSTextField *> *_labels; // label, note pairs per row
    NSTextField *_idValue;
    SZFriendsButton *_copyButton;
    SZFriendsButton *_receivedButton;
    SZFriendsButton *_changeButton;
    SZFriendsButton *_historyButton;
    SZFriendsButton *_resetButton;
    BOOL _showingFriends;
    NSMutableArray<NSView *> *_friendViews;
    NSMutableArray<NSSwitch *> *_switches;
    NSTextField *_statusLabel;
}

- (instancetype)initWithHost:(id<SZFriendsHost>)host link:(SZFriendsHelperLink *)link {
    if (!(self = [super init])) return nil;
    _context = [[SZFriendsContext alloc] initWithHost:host link:link];
    SZFriendsAppearance *appearance = _context.appearance;
    __weak SZFriendsSettingsSection *weakSelf = self;
    _context.presentConfirmation = ^(NSDictionary *confirm, void (^onConfirm)(void)) {
        [weakSelf confirm:confirm then:onConfirm];
    };
    _view = [[SZFriendsSettingsView alloc] initWithFrame:NSMakeRect(0, 0, 560, 300)];
    _view.identifier = SZFriendsIdentifierSettings; // the host's assistant skips it (SZFriendsUI.h)
    _view.measure = ^CGFloat(CGFloat width, BOOL apply) { return [weakSelf layoutForWidth:width apply:apply]; };
    _labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < 12; i++) {
        BOOL title = i % 2 == 0;
        NSFont *font = title ? SZFriendsSemibold(appearance.bodyFont) : appearance.secondaryFont;
        NSColor *color = title ? appearance.primaryTextColor : appearance.secondaryTextColor;
        NSTextField *label = SZFriendsLabel(@"", font, color);
        [_labels addObject:label];
        [_view addSubview:label];
    }
    _nameField = [NSTextField textFieldWithString:@""];
    _nameField.bezelStyle = NSTextFieldRoundedBezel;
    _nameField.font = appearance.bodyFont;
    _nameField.delegate = self;
    _idValue = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _idValue.selectable = YES;
    _copyButton = [self button:^{ [weakSelf.context copyText:SZFStr(SZFDict(weakSelf.data, @"id"), @"friends_id")]; }];
    _receivedButton = [self button:^{
        NSDictionary *received = SZFDict(weakSelf.data, @"received");
        [weakSelf.context performAction:SZFDict(received, @"action") ids:nil done:nil];
    }];
    _changeButton = [self button:^{ [weakSelf toggleFriends]; }];
    _historyButton = [self button:^{ [weakSelf runConfirmed:@"delete_history" section:@"history"]; }];
    _resetButton = [self button:^{ [weakSelf runConfirmed:@"reset_friends" section:@"reset"]; }];
    _resetButton.style = SZFriendsButtonStyleSecondary;
    for (NSView *view in @[ _nameField, _idValue ]) [_view addSubview:view];
    _friendViews = [NSMutableArray array];
    _switches = [NSMutableArray array];
    _statusLabel = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    [_view addSubview:_statusLabel];
    // While the helper is not answering the rows keep their last values; this line says why they do not change.
    [link addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionInitial context:NULL];
    return self;
}

- (void)dealloc {
    [_context.link removeObserver:self forKeyPath:@"state"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change
                       context:(void *)context {
    (void)keyPath, (void)object, (void)change, (void)context;
    SZFriendsHelperLink *link = _context.link;
    _statusLabel.stringValue = link.state == SZFriendsLinkStateReady ? @"" : (link.statusText ?: @"");
    [_view invalidateIntrinsicContentSize];
    [_view setNeedsLayout:YES];
}

- (NSDictionary *)data {
    return _data;
}

- (SZFriendsButton *)button:(void (^)(void))action {
    SZFriendsButton *button = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleSecondary
                                                    appearance:_context.appearance];
    button.onPress = ^(SZFriendsButton *pressed) {
        (void)pressed;
        action();
    };
    [_view addSubview:button];
    return button;
}

- (NSView *)view {
    return _view;
}

- (NSArray<SZFriendsButton *> *)buttons {
    return @[ _copyButton, _receivedButton, _changeButton, _historyButton, _resetButton ];
}

- (NSArray<NSSwitch *> *)autoAcceptSwitches {
    return [_switches copy];
}

- (BOOL)holdsSubscription {
    return _token != nil;
}

- (void)sectionWillAppear {
    if (_token) return;
    __weak SZFriendsSettingsSection *weakSelf = self;
    _token = [_context.link subscribeToView:@"settings" params:nil handler:^(NSDictionary *data, NSInteger rev) {
        (void)rev;
        [weakSelf applySnapshot:data];
    }];
}

- (void)sectionDidDisappear {
    if (_token) [_context.link unsubscribe:_token];
    _token = nil;
}

- (void)applySnapshot:(NSDictionary *)data {
    _data = [data copy];
    NSArray *sections = @[ @"name", @"id", @"received", @"auto_accept", @"history", @"reset" ];
    for (NSUInteger i = 0; i < sections.count; i++) {
        NSDictionary *section = SZFDict(data, sections[i]);
        _labels[2 * i].stringValue = SZFStr(section, @"label") ?: @"";
        _labels[2 * i + 1].stringValue = SZFStr(section, @"note") ?: @"";
    }
    NSDictionary *name = SZFDict(data, @"name");
    if (!_nameField.currentEditor) _nameField.stringValue = SZFStr(name, @"value") ?: @"";
    _nameField.placeholderString = SZFStr(name, @"placeholder");
    _nameField.accessibilityLabel = SZFStr(name, @"label");
    NSDictionary *identifier = SZFDict(data, @"id");
    _idValue.stringValue = SZFStr(identifier, @"friends_id") ?: @"";
    _copyButton.title = SZFStr(identifier, @"copy_label") ?: @"";
    NSDictionary *received = SZFDict(data, @"received");
    _receivedButton.title = SZFStr(SZFDict(received, @"action"), @"label") ?: @"";
    _receivedButton.hidden = ![SZFriendsContext knowsAction:SZFStr(SZFDict(received, @"action"), @"action")];
    _changeButton.title = SZFStr(SZFDict(data, @"auto_accept"), @"action_label") ?: @"";
    _historyButton.title = SZFStr(SZFDict(data, @"history"), @"action_label") ?: @"";
    _resetButton.title = SZFStr(SZFDict(data, @"reset"), @"action_label") ?: @"";
    [self rebuildFriends];
    [_view invalidateIntrinsicContentSize];
    [_view setNeedsLayout:YES];
}

- (void)toggleFriends {
    _showingFriends = !_showingFriends;
    _changeButton.selectedLook = _showingFriends;
    [self rebuildFriends];
    [_view invalidateIntrinsicContentSize];
    [_view setNeedsLayout:YES];
}

- (void)rebuildFriends {
    for (NSView *view in _friendViews) [view removeFromSuperview];
    [_friendViews removeAllObjects];
    [_switches removeAllObjects];
    if (!_showingFriends) return;
    SZFriendsAppearance *appearance = _context.appearance;
    for (NSDictionary *friend in SZFArr(SZFDict(_data, @"auto_accept"), @"friends")) {
        SZFriendsAvatarView *avatar = [SZFriendsAvatarView new];
        avatar.avatar = SZFDict(friend, @"avatar");
        NSTextField *title = SZFriendsLabel(SZFStr(friend, @"title"), appearance.bodyFont, appearance.primaryTextColor);
        NSSwitch *toggle = [NSSwitch new];
        toggle.controlSize = NSControlSizeSmall;
        toggle.state = SZFBool(friend, @"enabled") ? NSControlStateValueOn : NSControlStateValueOff;
        toggle.accessibilityLabel = SZFStr(friend, @"title");
        toggle.identifier = SZFStr(friend, @"conversation_id");
        toggle.target = self;
        toggle.action = @selector(friendToggled:);
        for (NSView *view in @[ avatar, title, toggle ]) {
            [_view addSubview:view];
            [_friendViews addObject:view];
        }
        [_switches addObject:toggle];
    }
}

- (void)friendToggled:(NSSwitch *)toggle {
    if (!toggle.identifier) return;
    NSDictionary *fields = @{@"conversation_id" : toggle.identifier,
                             @"enabled" : @(toggle.state == NSControlStateValueOn)};
    [_context.link sendIntent:@"set_auto_accept" fields:fields reply:nil];
}

- (void)runConfirmed:(NSString *)action section:(NSString *)section {
    NSDictionary *part = SZFDict(_data, section);
    NSDictionary *object = @{@"action" : action, @"label" : SZFStr(part, @"action_label") ?: @"",
                             @"style" : @"secondary", @"confirm" : SZFDict(part, @"confirm") ?: @{}};
    [_context performAction:object ids:nil done:nil];
}

// A PROTOCOL.md confirm object as the standard alert, marked so the host's assistant cannot press its buttons.
+ (NSAlert *)alertForConfirm:(NSDictionary *)confirm {
    NSAlert *alert = [NSAlert new];
    alert.messageText = SZFStr(confirm, @"title") ?: @"";
    alert.informativeText = SZFStr(confirm, @"body") ?: @"";
    NSButton *confirmButton = [alert addButtonWithTitle:SZFStr(confirm, @"confirm_label") ?: @""];
    if (@available(macOS 11.0, *)) confirmButton.hasDestructiveAction = YES;
    [alert addButtonWithTitle:SZFStr(confirm, @"cancel_label") ?: @""];
    SZFriendsHideWindowFromAssistant(alert.window, SZFriendsIdentifierAlert);
    return alert;
}

// Settings is a window of its own, so its confirmations are the standard sheet on it.
- (void)confirm:(NSDictionary *)confirm then:(void (^)(void))onConfirm {
    NSWindow *window = _view.window;
    if (!window) return;
    NSAlert *alert = [SZFriendsSettingsSection alertForConfirm:confirm];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) onConfirm();
    }];
}

- (void)commitName {
    NSString *value = _nameField.stringValue ?: @"";
    if ([value isEqualToString:SZFStr(SZFDict(_data, @"name"), @"value") ?: @""]) return;
    [_context.link sendIntent:@"set_name" fields:@{@"name" : value} reply:nil];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)control, (void)textView;
    if (command != @selector(insertNewline:)) return NO;
    [self commitName];
    return YES;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    (void)notification;
    [self commitName];
}

// The width a row's control takes: the name field is fixed, buttons fit their titles, the ID fits its text.
- (CGFloat)controlWidthForRow:(NSUInteger)row control:(NSView *)control {
    if (row == 0) return 220;
    if (row == 1) return SZFriendsTextWidth(_idValue.stringValue, _idValue.font) + 4;
    return MAX(90, [(SZFriendsButton *)control fittingWidth]);
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    NSArray<NSView *> *controls =
        @[ _nameField, _idValue, _receivedButton, _changeButton, _historyButton, _resetButton ];
    CGFloat y = 0;
    CGFloat statusHeight = SZFriendsFieldHeight(_statusLabel, width);
    if (apply) {
        _statusLabel.frame = NSMakeRect(0, 0, width, statusHeight);
        _statusLabel.hidden = statusHeight == 0;
    }
    if (statusHeight) y += statusHeight + 12;
    for (NSUInteger row = 0; row < 6; row++) {
        NSView *control = controls[row];
        CGFloat controlWidth = [self controlWidthForRow:row control:control];
        CGFloat copyWidth = row == 1 ? MAX(70, [_copyButton fittingWidth]) + 12 : 0;
        CGFloat textWidth = MAX(120, width - controlWidth - copyWidth - 16);
        NSTextField *label = _labels[2 * row], *note = _labels[2 * row + 1];
        CGFloat labelHeight = SZFriendsFieldHeight(label, textWidth);
        CGFloat noteHeight = SZFriendsFieldHeight(note, textWidth);
        CGFloat rowHeight = MAX(labelHeight + (noteHeight ? 3 + noteHeight : 0), 30);
        if (apply) {
            label.frame = NSMakeRect(0, y, textWidth, labelHeight);
            note.frame = NSMakeRect(0, y + labelHeight + 3, textWidth, noteHeight);
            CGFloat controlHeight = row == 1 ? 20 : 28;
            CGFloat controlY = y + floor((rowHeight - controlHeight) / 2);
            control.frame = NSMakeRect(width - controlWidth - copyWidth, controlY, controlWidth, controlHeight);
            if (row == 1) {
                CGFloat buttonY = y + floor((rowHeight - 28) / 2);
                _copyButton.frame = NSMakeRect(width - copyWidth + 12, buttonY, copyWidth - 12, 28);
            }
        }
        y += rowHeight + 16;
        if (row != 3 || !_showingFriends) continue;
        for (NSUInteger i = 0; i < _switches.count; i++) {
            if (apply) {
                NSView *toggle = _friendViews[3 * i + 2];
                NSSize size = toggle.fittingSize;
                _friendViews[3 * i].frame = NSMakeRect(12, y, 22, 22);
                _friendViews[3 * i + 1].frame = NSMakeRect(44, y + 3, width - 44 - size.width - 12, 18);
                CGFloat toggleY = y + floor((22 - size.height) / 2);
                toggle.frame = NSMakeRect(width - size.width, toggleY, size.width, size.height);
            }
            y += 30;
        }
        y += _switches.count ? 6 : 0;
    }
    return MAX(0, y - 16);
}

@end
