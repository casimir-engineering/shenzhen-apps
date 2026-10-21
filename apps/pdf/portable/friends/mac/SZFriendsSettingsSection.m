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

@interface SZFriendsSettingsSection ()
@end

// Rows in order; `nearby`, `join` and `notifications` show only when the helper sends them (PROTOCOL.md § settings).
static NSArray<NSString *> *SZFSettingsRows(void) {
    return @[ @"name", @"id", @"received", @"auto_accept", @"nearby", @"join", @"notifications", @"history", @"reset" ];
}
static const NSUInteger SZFSettingsRowCount = 9, SZFSettingsReceivedRow = 2, SZFSettingsAutoAcceptRow = 3,
                        SZFSettingsNearbyRow = 4, SZFSettingsJoinRow = 5, SZFSettingsNotificationsRow = 6;

// The Notifications row's switches, in order, each sent back alone with set_notifications (PROTOCOL.md §
// Notifications, Settings); `background` comes only to an Android host, so never here, but is drawn if it does.
static NSArray<NSString *> *SZFNotificationSwitchKeys(void) {
    return @[ @"enabled", @"preview", @"background" ];
}

@implementation SZFriendsSettingsSection {
    SZFriendsSettingsView *_view;
    NSString *_token;
    NSDictionary *_data;
    NSMutableArray<NSTextField *> *_labels; // label, note pairs per row
    SZFriendsNameEditor *_nameEditor;       // the name friends see, with Save (SZFriendsListPage.h)
    NSString *_appliedName;                 // the name last shown, so a snapshot never overwrites typing
    NSTextField *_idValue;
    SZFriendsButton *_copyButton;
    SZFriendsButton *_receivedButton;
    SZFriendsButton *_receivedChangeButton;
    SZFriendsButton *_changeButton;
    SZFriendsButton *_historyButton;
    SZFriendsButton *_resetButton;
    SZFriendsButton *_nearbyButton;
    SZFriendsButton *_joinButton; // Use my existing profile…: the join page, after Reset when it asks first
    SZFriendsButton *_notificationsButton; // Allow or Open System Settings, for the permission
    NSArray<NSSwitch *> *_notificationSwitches;     // per SZFNotificationSwitchKeys()
    NSArray<NSTextField *> *_notificationLabels;    // label, note pairs per switch
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
    _context.presentConfirmation = ^(NSDictionary *confirm, void (^onConfirm)(BOOL)) {
        [weakSelf confirm:confirm then:onConfirm];
    };
    _view = [[SZFriendsSettingsView alloc] initWithFrame:NSMakeRect(0, 0, 560, 300)];
    _view.identifier = SZFriendsIdentifierSettings; // the host's assistant skips it (SZFriendsUI.h)
    _view.measure = ^CGFloat(CGFloat width, BOOL apply) { return [weakSelf layoutForWidth:width apply:apply]; };
    _labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < 2 * SZFSettingsRowCount; i++) {
        BOOL title = i % 2 == 0;
        NSFont *font = title ? SZFriendsSemibold(appearance.bodyFont) : appearance.secondaryFont;
        NSColor *color = title ? appearance.primaryTextColor : appearance.secondaryTextColor;
        NSTextField *label = SZFriendsLabel(@"", font, color);
        [_labels addObject:label];
        [_view addSubview:label];
    }
    _nameEditor = [[SZFriendsNameEditor alloc] initWithContext:_context font:appearance.bodyFont];
    _nameEditor.onLayoutChange = ^{
        SZFriendsSettingsSection *section = weakSelf;
        [section->_view invalidateIntrinsicContentSize];
        [section->_view setNeedsLayout:YES];
    };
    _nameEditor.onCancel = ^{
        SZFriendsSettingsSection *section = weakSelf;
        if (!section) return;
        [section->_nameEditor reset];
        section->_nameEditor.field.stringValue = section->_appliedName ?: @"";
        if (section->_nameEditor.field.currentEditor) [section->_view.window makeFirstResponder:nil];
    };
    _idValue = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _idValue.selectable = YES;
    _copyButton = [self button:^{ [weakSelf.context copyText:SZFStr(SZFDict(weakSelf.data, @"id"), @"friends_id")]; }];
    _receivedButton = [self button:^{
        NSDictionary *received = SZFDict(weakSelf.data, @"received");
        [weakSelf.context performAction:SZFDict(received, @"action") ids:nil done:nil];
    }];
    _receivedChangeButton = [self button:^{ [weakSelf chooseReceivedFolder]; }];
    _chooseFolder = ^(NSString *startPath, void (^chosen)(NSString *path)) {
        [weakSelf showFolderPanelAt:startPath chosen:chosen];
    };
    _changeButton = [self button:^{ [weakSelf toggleFriends]; }];
    _historyButton = [self button:^{ [weakSelf runConfirmed:@"delete_history" section:@"history"]; }];
    _resetButton = [self button:^{ [weakSelf runConfirmed:@"reset_friends" section:@"reset"]; }];
    _resetButton.style = SZFriendsButtonStyleSecondary;
    // Allow, Open Privacy Settings, a radio's settings or Try Again: whatever the helper's Nearby line offers.
    _nearbyButton = [self button:^{
        [weakSelf.context performAction:SZFDict(SZFDict(weakSelf.data, @"nearby"), @"action") ids:nil done:nil];
    }];
    _joinButton = [self button:^{
        [weakSelf.context performAction:SZFDict(SZFDict(weakSelf.data, @"join"), @"action") ids:nil done:nil];
    }];
    _joinButton.style = SZFriendsButtonStyleSecondary;
    _notificationsButton = [self button:^{
        [weakSelf.context performAction:SZFDict(SZFDict(weakSelf.data, @"notifications"), @"action") ids:nil done:nil];
    }];
    NSMutableArray *switches = [NSMutableArray array], *labels = [NSMutableArray array];
    for (NSString *key in SZFNotificationSwitchKeys()) {
        NSSwitch *toggle = [NSSwitch new];
        toggle.controlSize = NSControlSizeSmall;
        toggle.identifier = key;
        toggle.target = self;
        toggle.action = @selector(notificationSwitchToggled:);
        [switches addObject:toggle];
        [_view addSubview:toggle];
        NSTextField *label = SZFriendsLabel(@"", appearance.bodyFont, appearance.primaryTextColor);
        NSTextField *note = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
        [labels addObjectsFromArray:@[ label, note ]];
        [_view addSubview:label];
        [_view addSubview:note];
    }
    _notificationSwitches = switches;
    _notificationLabels = labels;
    for (NSView *view in @[ _nameEditor, _idValue ]) [_view addSubview:view];
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

- (SZFriendsButton *)joinButton {
    return _joinButton;
}

- (SZFriendsButton *)nearbyButton {
    return _nearbyButton;
}

- (SZFriendsButton *)receivedChangeButton {
    return _receivedChangeButton;
}

- (SZFriendsButton *)notificationsButton {
    return _notificationsButton;
}

- (NSArray<NSSwitch *> *)notificationSwitches {
    return _notificationSwitches;
}

- (NSTextField *)receivedFolderField {
    return _labels[2 * SZFSettingsReceivedRow + 1];
}

// Change…: the folder picker, then set_received_folder. A folder the helper refuses says why on the same sheet's
// window; the row changes only when the next snapshot names the new folder.
- (void)chooseReceivedFolder {
    NSDictionary *received = SZFDict(_data, @"received");
    if (!self.chooseFolder) return;
    __weak SZFriendsSettingsSection *weakSelf = self;
    self.chooseFolder(SZFStr(received, @"path"), ^(NSString *path) {
        SZFriendsSettingsSection *section = weakSelf;
        [section.context.link sendIntent:@"set_received_folder" fields:@{@"path" : path}
                                   reply:^(NSDictionary *result, SZFriendsLinkError *error) {
            (void)result;
            if (error.message.length) [weakSelf showRefusal:error.message];
        }];
    });
}

- (void)showFolderPanelAt:(nullable NSString *)startPath chosen:(void (^)(NSString *path))chosen {
    NSWindow *window = _view.window;
    if (!window) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.resolvesAliases = YES;
    if (startPath.length) panel.directoryURL = [NSURL fileURLWithPath:startPath isDirectory:YES];
    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        NSString *path = panel.URL.path;
        if (response == NSModalResponseOK && path.length) chosen(path);
    }];
}

- (void)showRefusal:(NSString *)message {
    NSWindow *window = _view.window;
    if (!window) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    SZFriendsHideWindowFromAssistant(alert.window, SZFriendsIdentifierAlert);
    [alert beginSheetModalForWindow:window completionHandler:nil];
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
    NSArray *sections = SZFSettingsRows();
    for (NSUInteger i = 0; i < sections.count; i++) {
        NSDictionary *section = SZFDict(data, sections[i]);
        _labels[2 * i].stringValue = SZFStr(section, @"label") ?: @"";
        _labels[2 * i + 1].stringValue = SZFStr(section, @"note") ?: @"";
    }
    NSDictionary *name = SZFDict(data, @"name");
    // What the person is typing stays; a field still showing the last name follows the new one.
    NSString *savedName = SZFStr(name, @"value") ?: @"";
    NSTextField *nameField = _nameEditor.field;
    if (!nameField.currentEditor || [nameField.stringValue isEqualToString:_appliedName ?: @""])
        nameField.stringValue = savedName;
    _appliedName = savedName;
    _nameEditor.currentName = savedName;
    [_nameEditor reloadStrings];
    nameField.placeholderString = SZFStr(name, @"placeholder");
    nameField.accessibilityLabel = SZFStr(name, @"label");
    NSDictionary *identifier = SZFDict(data, @"id");
    _idValue.stringValue = SZFStr(identifier, @"friends_id") ?: @"";
    _copyButton.title = SZFStr(identifier, @"copy_label") ?: @"";
    NSDictionary *received = SZFDict(data, @"received");
    _receivedButton.title = SZFStr(SZFDict(received, @"action"), @"label") ?: @"";
    _receivedButton.hidden = ![SZFriendsContext knowsAction:SZFStr(SZFDict(received, @"action"), @"action")];
    // The folder's name under the label, then the note (empty unless the last file went elsewhere).
    NSDictionary *change = SZFDict(received, @"change");
    _receivedChangeButton.title = SZFStr(change, @"label") ?: @"";
    _receivedChangeButton.hidden = ![SZFStr(change, @"action") isEqualToString:@"choose_received_folder"];
    NSString *folder = SZFStr(received, @"value"), *note = SZFStr(received, @"note");
    NSTextField *folderField = self.receivedFolderField;
    folderField.stringValue = folder.length && note.length ? [NSString stringWithFormat:@"%@\n%@", folder, note]
                                                           : (folder.length ? folder : note ?: @"");
    folderField.toolTip = SZFStr(received, @"path");
    _changeButton.title = SZFStr(SZFDict(data, @"auto_accept"), @"action_label") ?: @"";
    // No friends, no switch to show: the row's note says where to turn it on.
    _changeButton.hidden = SZFArr(SZFDict(data, @"auto_accept"), @"friends").count == 0;
    if (_changeButton.hidden) {
        _showingFriends = NO;
        _changeButton.selectedLook = NO;
    }
    _historyButton.title = SZFStr(SZFDict(data, @"history"), @"action_label") ?: @"";
    _resetButton.title = SZFStr(SZFDict(data, @"reset"), @"action_label") ?: @"";
    NSDictionary *nearbyAction = SZFDict(SZFDict(data, @"nearby"), @"action");
    _nearbyButton.title = SZFStr(nearbyAction, @"label") ?: @"";
    _nearbyButton.hidden = ![SZFriendsContext knowsAction:SZFStr(nearbyAction, @"action")];
    BOOL nearbyRow = SZFDict(data, @"nearby") != nil;
    _labels[2 * SZFSettingsNearbyRow].hidden = _labels[2 * SZFSettingsNearbyRow + 1].hidden = !nearbyRow;
    NSDictionary *joinAction = SZFDict(SZFDict(data, @"join"), @"action");
    _joinButton.title = SZFStr(joinAction, @"label") ?: @"";
    BOOL joinRow = [SZFriendsContext knowsAction:SZFStr(joinAction, @"action")];
    _joinButton.hidden = !joinRow;
    _labels[2 * SZFSettingsJoinRow].hidden = _labels[2 * SZFSettingsJoinRow + 1].hidden = !joinRow;
    [self applyNotifications:SZFDict(data, @"notifications")];
    [self rebuildFriends];
    [_view invalidateIntrinsicContentSize];
    [_view setNeedsLayout:YES];
}

// This device's notifications: the label and the permission's note on the row, its one action (Allow, or Open
// System Settings once refused), and the switches under it. Anything the helper leaves out is not drawn.
- (void)applyNotifications:(NSDictionary *)notifications {
    BOOL row = notifications != nil;
    _labels[2 * SZFSettingsNotificationsRow].hidden = _labels[2 * SZFSettingsNotificationsRow + 1].hidden = !row;
    NSDictionary *action = SZFDict(notifications, @"action");
    _notificationsButton.title = SZFStr(action, @"label") ?: @"";
    _notificationsButton.hidden = !row || ![SZFriendsContext knowsAction:SZFStr(action, @"action")];
    NSArray *keys = SZFNotificationSwitchKeys();
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSDictionary *part = SZFDict(notifications, keys[i]);
        NSSwitch *toggle = _notificationSwitches[i];
        NSTextField *label = _notificationLabels[2 * i], *note = _notificationLabels[2 * i + 1];
        BOOL shown = part != nil && SZFStr(part, @"label").length > 0;
        toggle.hidden = label.hidden = note.hidden = !shown;
        label.stringValue = SZFStr(part, @"label") ?: @"";
        note.stringValue = SZFStr(part, @"note") ?: @"";
        toggle.accessibilityLabel = label.stringValue;
        toggle.state = SZFBool(part, @"value") ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

// One switch, one field: the others keep whatever the helper has (PROTOCOL.md set_notifications).
- (void)notificationSwitchToggled:(NSSwitch *)toggle {
    if (!toggle.identifier.length) return;
    [_context.link sendIntent:@"set_notifications"
                       fields:@{toggle.identifier : @(toggle.state == NSControlStateValueOn)}
                        reply:nil];
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
    // A confirm option ("Also delete chat history") is the alert's checkbox, unticked.
    NSString *option = SZFStr(SZFDict(confirm, @"option"), @"label");
    if (option.length) {
        alert.showsSuppressionButton = YES;
        alert.suppressionButton.title = option;
        alert.suppressionButton.state = NSControlStateValueOff;
    }
    SZFriendsHideWindowFromAssistant(alert.window, SZFriendsIdentifierAlert);
    return alert;
}

// Settings is a window of its own, so its confirmations are the standard sheet on it.
- (void)confirm:(NSDictionary *)confirm then:(void (^)(BOOL))onConfirm {
    NSWindow *window = _view.window;
    if (!window) return;
    NSAlert *alert = [SZFriendsSettingsSection alertForConfirm:confirm];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        BOOL ticked = alert.showsSuppressionButton && alert.suppressionButton.state == NSControlStateValueOn;
        if (response == NSAlertFirstButtonReturn) onConfirm(ticked);
    }];
}

- (NSTextField *)nameField {
    return _nameEditor.field;
}

// The width a row's control takes: the name field is fixed, buttons fit their titles, the ID fits its text.
- (CGFloat)controlWidthForRow:(NSUInteger)row control:(NSView *)control {
    if (row == 0) return 300;
    if (row == 1) return SZFriendsTextWidth(_idValue.stringValue, _idValue.font) + 4;
    return MAX(90, [(SZFriendsButton *)control fittingWidth]);
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    NSArray<NSView *> *controls =
        @[ _nameEditor, _idValue, _receivedButton, _changeButton, _nearbyButton, _joinButton, _notificationsButton,
           _historyButton, _resetButton ];
    CGFloat y = 0;
    CGFloat statusHeight = SZFriendsFieldHeight(_statusLabel, width);
    if (apply) {
        _statusLabel.frame = NSMakeRect(0, 0, width, statusHeight);
        _statusLabel.hidden = statusHeight == 0;
    }
    if (statusHeight) y += statusHeight + 12;
    BOOL nearbyRow = SZFDict(_data, @"nearby") != nil;
    for (NSUInteger row = 0; row < SZFSettingsRowCount; row++) {
        if ((row == SZFSettingsNearbyRow && !nearbyRow) || (row == SZFSettingsJoinRow && _joinButton.hidden) ||
            (row == SZFSettingsNotificationsRow && !SZFDict(_data, @"notifications")))
            continue;
        NSView *control = controls[row];
        // A Nearby line with nothing to fix has no button, and its words take the whole width.
        CGFloat controlWidth = control.hidden ? 0 : [self controlWidthForRow:row control:control];
        // The ID's Copy, and Change… before Show in Finder, sit left of the row's control.
        SZFriendsButton *beside = row == 1 ? _copyButton : row == SZFSettingsReceivedRow ? _receivedChangeButton : nil;
        CGFloat copyWidth = beside && !beside.hidden ? MAX(70, [beside fittingWidth]) + 12 : 0;
        CGFloat textWidth = MAX(120, width - controlWidth - copyWidth - 16);
        NSTextField *label = _labels[2 * row], *note = _labels[2 * row + 1];
        CGFloat labelHeight = SZFriendsFieldHeight(label, textWidth);
        CGFloat noteHeight = SZFriendsFieldHeight(note, textWidth);
        // The name's Save and its refusal can make the first row taller than its words.
        CGFloat editorHeight = row == 0 ? [_nameEditor heightForWidth:controlWidth] : 0;
        CGFloat rowHeight = MAX(MAX(labelHeight + (noteHeight ? 3 + noteHeight : 0), 30), editorHeight);
        if (apply) {
            label.frame = NSMakeRect(0, y, textWidth, labelHeight);
            note.frame = NSMakeRect(0, y + labelHeight + 3, textWidth, noteHeight);
            CGFloat controlHeight = row == 0 ? editorHeight : row == 1 ? 20 : 28;
            CGFloat controlY = row == 0 && editorHeight > 30 ? y : y + floor((rowHeight - controlHeight) / 2);
            control.frame = NSMakeRect(width - controlWidth - copyWidth, controlY, controlWidth, controlHeight);
            if (row == 1) {
                CGFloat buttonY = y + floor((rowHeight - 28) / 2);
                _copyButton.frame = NSMakeRect(width - copyWidth + 12, buttonY, copyWidth - 12, 28);
            } else if (row == SZFSettingsReceivedRow && copyWidth > 0) {
                // Change… first, then Show in Finder at the trailing edge.
                CGFloat buttonY = y + floor((rowHeight - 28) / 2);
                _receivedChangeButton.frame = NSMakeRect(width - controlWidth - copyWidth, buttonY, copyWidth - 12, 28);
                control.frame = NSMakeRect(width - controlWidth, controlY, controlWidth, controlHeight);
            }
        }
        y += rowHeight + 16;
        if (row == SZFSettingsNotificationsRow) y = [self layoutNotificationSwitchesAt:y width:width apply:apply];
        if (row != SZFSettingsAutoAcceptRow || !_showingFriends) continue;
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

// The Notifications row's switches, indented under it like the friends' switches: words on the left (a note under
// the label where there is one), the switch at the trailing edge.
- (CGFloat)layoutNotificationSwitchesAt:(CGFloat)y width:(CGFloat)width apply:(BOOL)apply {
    BOOL any = NO;
    for (NSUInteger i = 0; i < _notificationSwitches.count; i++) {
        NSSwitch *toggle = _notificationSwitches[i];
        if (toggle.hidden) continue;
        NSTextField *label = _notificationLabels[2 * i], *note = _notificationLabels[2 * i + 1];
        NSSize size = toggle.fittingSize;
        CGFloat textWidth = MAX(120, width - 12 - size.width - 16);
        CGFloat labelHeight = SZFriendsFieldHeight(label, textWidth);
        CGFloat noteHeight = SZFriendsFieldHeight(note, textWidth);
        CGFloat rowHeight = MAX(22, labelHeight + (noteHeight ? 3 + noteHeight : 0));
        if (apply) {
            label.frame = NSMakeRect(12, y, textWidth, labelHeight);
            note.frame = NSMakeRect(12, y + labelHeight + 3, textWidth, noteHeight);
            note.hidden = noteHeight == 0;
            toggle.frame = NSMakeRect(width - size.width, y + floor((MAX(labelHeight, 22) - size.height) / 2),
                                      size.width, size.height);
        }
        y += rowHeight + 8;
        any = YES;
    }
    return any ? y + 8 : y;
}

@end
