// SZFriendsContext: what every Friends view shares, and the one place PROTOCOL.md actions become intents.

#import "mac/SZFriendsPage.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation SZFriendsDraft
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _text = @"";
    _items = @[];
    return self;
}
@end

// Which id each intent action takes from the object that carries it (PROTOCOL.md § Shared objects, action).
// An empty value means the intent takes no id. Client-side actions are handled separately.
static NSDictionary<NSString *, NSString *> *SZFActionIDs(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"accept_request" : @"conversation_id", @"decline_request" : @"conversation_id",
            @"cancel_request" : @"conversation_id", @"block" : @"conversation_id", @"unblock" : @"conversation_id",
            @"remove_friend" : @"conversation_id", @"mark_verified" : @"conversation_id",
            @"accept_key_change" : @"conversation_id", @"delete_history" : @"conversation_id",
            @"send_request" : @"nearby_id", @"accept_offer" : @"transfer_id", @"decline_offer" : @"transfer_id",
            @"cancel_transfer" : @"transfer_id", @"retry_item" : @"item_id", @"dismiss_banner" : @"kind",
            // An outgoing message that has not left this Mac (queued or connecting): its item_id is its message_id.
            @"cancel_message" : @"message_id",
            // A stranger's mention card: the intent takes the action's own fields, as they are (PROTOCOL.md).
            @"add_from_mention" : @"",
            // Links (PROTOCOL.md § Links): the card's actions carry the link's payload, a download link's Revoke its
            // own link_id, and Reset link needs nothing else.
            @"add_from_link" : @"", @"receive_link" : @"", @"revoke_link" : @"", @"reset_friend_link" : @"",
            @"start_visibility" : @"", @"stop_visibility" : @"", @"reset_friends" : @"",
            // Several computers (PROTOCOL.md § Devices, § Joining): a file another computer holds is fetched by its
            // transfer_id; a device row's Remove, a join row's Approve and Deny, and Start again carry their own id.
            @"fetch_from_device" : @"transfer_id", @"revoke_device" : @"", @"approve_join" : @"", @"deny_join" : @"",
            @"join_profile" : @"", @"cancel_join" : @"",
        };
    });
    return table;
}

// The field an action carries itself and sends as it is (PROTOCOL.md § Shared objects, action); nil for none.
static NSString *SZFOwnField(NSString *name) {
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{@"revoke_link" : @"link_id", @"add_from_link" : @"payload", @"receive_link" : @"payload",
                  @"revoke_device" : @"device_id", @"approve_join" : @"join_id", @"deny_join" : @"join_id",
                  @"join_profile" : @"friends_id"};
    });
    return table[name];
}

// System Settings panes per settings_target. macOS 13 renamed the Bluetooth and Wi-Fi panes; the privacy anchors
// are the same on 12 and later.
static NSURL *SZFSettingsURL(NSString *target) {
    NSString *url = nil;
    if ([target isEqualToString:@"local_network_privacy"])
        url = @"x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork";
    else if ([target isEqualToString:@"bluetooth_privacy"])
        url = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth";
    else if ([target isEqualToString:@"bluetooth"]) {
        if (@available(macOS 13.0, *)) url = @"x-apple.systempreferences:com.apple.BluetoothSettings";
        else url = @"x-apple.systempreferences:com.apple.preferences.Bluetooth";
    } else if ([target isEqualToString:@"wifi"]) {
        if (@available(macOS 13.0, *)) url = @"x-apple.systempreferences:com.apple.wifi-settings-extension";
        else url = @"x-apple.systempreferences:com.apple.preference.network?Wi-Fi";
    }
    return url ? [NSURL URLWithString:url] : nil;
}

SZFriendsPress SZFriendsPressFromEvent(NSEvent *event, NSTimeInterval now) {
    SZFriendsPress press = {now, 1};
    if (!event || fabs(event.timestamp - now) > 1) return press;
    switch (event.type) {
    case NSEventTypeLeftMouseDown:
    case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseDown:
    case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseDown:
    case NSEventTypeOtherMouseUp:
        press.clickCount = MAX(1, event.clickCount); // clickCount raises on any other event type
        press.time = event.timestamp;
        break;
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp:
        press.time = event.timestamp;
        break;
    default:
        break;
    }
    return press;
}

@implementation SZFriendsContext {
    BOOL _inMarkdownPass;
}

- (instancetype)initWithHost:(id<SZFriendsHost>)host link:(SZFriendsHelperLink *)link {
    if (!(self = [super init])) return nil;
    _host = host;
    _link = link;
    _appearance = host ? [host friendsAppearance] : [SZFriendsAppearance new];
    if (!_appearance) _appearance = [SZFriendsAppearance new];
    _drafts = [NSMutableDictionary new];
    _assistantRuns = [NSMutableDictionary new];
    _assistantProposals = [NSMutableDictionary new];
    _pasteboard = NSPasteboard.generalPasteboard;
    _openURL = ^(NSURL *url) { [NSWorkspace.sharedWorkspace openURL:url]; };
    _presentMenu = ^(NSMenu *menu, NSView *view, NSPoint point) {
        [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
    };
    _scheduleAfter = ^(NSTimeInterval seconds, dispatch_block_t block) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       block);
    };
    _currentPress = ^SZFriendsPress(void) {
        return SZFriendsPressFromEvent(NSApp.currentEvent, NSProcessInfo.processInfo.systemUptime);
    };
    _postAccessibility = ^(id element, NSAccessibilityNotificationName name, NSDictionary *userInfo) {
        if (userInfo) NSAccessibilityPostNotificationWithUserInfo(element, name, userInfo);
        else NSAccessibilityPostNotification(element, name);
    };
    _chooseImage = ^(void (^completion)(NSString *path)) {
        // Not modal: the dropdown is semi-transient and stays open while the panel is up.
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        SZFriendsHideWindowFromAssistant(panel, SZFriendsIdentifierOpenPanel);
        panel.allowedContentTypes = @[ UTTypeImage ];
        panel.allowsMultipleSelection = NO;
        [panel beginWithCompletionHandler:^(NSModalResponse response) {
            completion(response == NSModalResponseOK ? panel.URL.path : nil);
        }];
    };
    return self;
}

- (NSString *)string:(NSString *)key {
    return [self.link staticStringForKey:key] ?: @"";
}

- (void)markdownPass:(void (^)(void))layout {
    id<SZFriendsHost> host = self.host;
    BOOL opens = !_inMarkdownPass && [host respondsToSelector:@selector(friendsBeginMarkdownPass)] &&
                 [host respondsToSelector:@selector(friendsEndMarkdownPass)];
    if (opens) {
        _inMarkdownPass = YES;
        [host friendsBeginMarkdownPass];
    }
    layout();
    if (opens) {
        [host friendsEndMarkdownPass];
        _inMarkdownPass = NO;
    }
}

+ (BOOL)knowsAction:(NSString *)action {
    if (!action) return NO;
    return SZFActionIDs()[action] != nil || [action isEqualToString:@"open_file"] ||
           [action isEqualToString:@"show_file"] || [action isEqualToString:@"open_settings"];
}

- (void)performAction:(NSDictionary *)action ids:(NSDictionary *)ids done:(void (^)(SZFriendsLinkError *))done {
    [self performAction:action ids:ids reply:done ? ^(NSDictionary *result, SZFriendsLinkError *error) {
        (void)result;
        done(error);
    } : nil];
}

- (void)performAction:(NSDictionary *)action ids:(NSDictionary *)ids reply:(SZFriendsReplyHandler)reply {
    NSString *name = SZFStr(action, @"action");
    if (![SZFriendsContext knowsAction:name]) return;
    NSDictionary *confirm = SZFDict(action, @"confirm");
    // A destructive action's question is drawn destructive too, even from a helper that marks only the action.
    if (confirm && [SZFStr(action, @"style") isEqualToString:@"destructive"] && !SZFBool(confirm, @"destructive")) {
        NSMutableDictionary *marked = [confirm mutableCopy];
        marked[@"destructive"] = @YES;
        confirm = marked;
    }
    __weak SZFriendsContext *weakSelf = self;
    void (^run)(void) = ^{ [weakSelf runAction:name object:action ids:ids reply:reply]; };
    if (!confirm) {
        run();
    } else if (self.presentConfirmation) {
        self.presentConfirmation(confirm, run);
    }
}

- (void)runAction:(NSString *)name object:(NSDictionary *)action ids:(NSDictionary *)ids
            reply:(SZFriendsReplyHandler)reply {
    id<SZFriendsHost> host = self.host;
    NSString *path = SZFStr(action, @"path");
    if ([name isEqualToString:@"open_file"] || [name isEqualToString:@"show_file"]) {
        if (path.length && host) {
            NSURL *url = [NSURL fileURLWithPath:path];
            if ([name isEqualToString:@"open_file"]) [host friendsOpenReceivedFileAtURL:url];
            else [host friendsRevealFileAtURL:url];
        }
        if (reply) reply(@{}, nil);
        return;
    }
    if ([name isEqualToString:@"open_settings"]) {
        NSURL *url = SZFSettingsURL(SZFStr(action, @"settings_target"));
        if (url && self.openURL) self.openURL(url);
        if (reply) reply(@{}, nil);
        return;
    }
    NSString *idKey = SZFActionIDs()[name];
    NSMutableDictionary *fields = [NSMutableDictionary new];
    if (idKey.length) {
        NSString *value = ids[idKey];
        // delete_history without a conversation deletes everything; every other id is required.
        if (!value.length && ![name isEqualToString:@"delete_history"]) return;
        if (value.length) fields[idKey] = value;
    }
    if ([name isEqualToString:@"reset_friends"]) fields[@"confirm"] = @"reset";
    if ([name isEqualToString:@"add_from_mention"]) {
        // The ID and key reach a view only here, to be sent back untouched: the helper binds the request to that key.
        for (NSString *key in @[ @"friends_id", @"identity_key", @"name" ]) {
            NSString *value = SZFStr(action, key);
            if (!value.length) return;
            fields[key] = value;
        }
    }
    NSString *own = SZFOwnField(name);
    if (own) {
        // Sent as the helper wrote it into the action: the views never build or read a link or an id themselves.
        if (!SZFStr(action, own).length) return;
        fields[own] = SZFStr(action, own);
    }
    [self.link sendIntent:name fields:fields reply:reply];
}

- (void)announce:(NSString *)text {
    // Announcements go to the application element, which VoiceOver speaks whichever window has focus (the
    // dropdown is a popover window of its own).
    id element = NSApp;
    if (!text.length || !element || !self.postAccessibility) return;
    self.postAccessibility(element, NSAccessibilityAnnouncementRequestedNotification,
                           @{NSAccessibilityAnnouncementKey : text,
                             NSAccessibilityPriorityKey : @(NSAccessibilityPriorityHigh)});
}

- (void)copyText:(NSString *)text {
    if (!text.length) return;
    [self.pasteboard clearContents];
    [self.pasteboard setString:text forType:NSPasteboardTypeString];
    [self announce:[self string:@"copied"]];
}

+ (NSString *)clientToken {
    uint8_t bytes[12];
    arc4random_buf(bytes, sizeof bytes);
    NSMutableString *token = [NSMutableString stringWithCapacity:24];
    for (size_t i = 0; i < sizeof bytes; i++) [token appendFormat:@"%02x", bytes[i]];
    return token;
}

+ (NSDictionary *)fileObjectForItem:(SZFriendsAttachableItem *)item {
    NSMutableDictionary *file = [@{@"path" : item.fileURL.path ?: @""} mutableCopy];
    if (item.title.length) file[@"display_name"] = item.title;
    file[@"revision"] = item.revision ?: (id)NSNull.null;
    return file;
}

@end
