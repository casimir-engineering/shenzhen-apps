// SZFriendsDropdownController: the Friends button and the one semi-transient dropdown that holds everything.

#import "mac/SZFriendsDropdownInternal.h"

#import "mac/SZFriendsConversationPage.h"

#pragma mark - Popover presenter

@interface SZFriendsPopoverPresenter () <NSPopoverDelegate>
@end

@implementation SZFriendsPopoverPresenter {
    NSPopover *_popover;
}

@synthesize onDismiss = _onDismiss;

- (BOOL)isPresented {
    return _popover.isShown;
}

- (void)presentView:(NSView *)view size:(NSSize)size fromButton:(NSView *)button {
    if (!_popover) {
        _popover = [NSPopover new];
        // Semi-transient: a click in the window or on the button closes it, but working in another app does
        // not, so files can be dragged in from Finder or Shenzhen Files (brief § Interface).
        _popover.behavior = NSPopoverBehaviorSemitransient;
        _popover.animates = NO;
        _popover.delegate = self;
        _popover.contentViewController = [NSViewController new];
    }
    _popover.contentViewController.view = view;
    _popover.contentSize = size;
    [_popover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMaxY];
}

- (void)resizeTo:(NSSize)size {
    if (_popover.isShown) _popover.contentSize = size;
}

- (void)dismiss {
    [_popover performClose:nil];
}

- (BOOL)popoverShouldDetach:(NSPopover *)popover {
    (void)popover;
    return NO;
}

- (void)popoverDidClose:(NSNotification *)notification {
    (void)notification;
    if (self.onDismiss) self.onDismiss();
}

@end

#pragma mark - Controller

NSNotificationName const SZFriendsShowJoinNotification = @"SZFriendsShowJoinNotification";

@implementation SZFriendsDropdownController {
    __weak id<SZFriendsHost> _host;
    SZFriendsHelperLink *_link;
    id<SZFriendsDropdownPresenter> _presenter;
    SZFriendsTitleButton *_button;
    NSString *_badgeToken;
    BOOL _installed;
    BOOL _closedByButtonPress;
    SZFriendsServicesProvider *_services;
    BOOL _servicesOffered;
    BOOL _linkReady; // the state last seen, so a new connection starts from no focus
}

@synthesize content = _content;

- (instancetype)initWithHost:(id<SZFriendsHost>)host link:(SZFriendsHelperLink *)link {
    if (!(self = [super init])) return nil;
    [self setUpWithHost:host link:link presenter:[SZFriendsPopoverPresenter new]];
    return self;
}

- (instancetype)initWithHost:(id<SZFriendsHost>)host link:(SZFriendsHelperLink *)link
                   presenter:(id<SZFriendsDropdownPresenter>)presenter {
    if (!(self = [super init])) return nil;
    [self setUpWithHost:host link:link presenter:presenter];
    return self;
}

- (void)setUpWithHost:(id<SZFriendsHost>)host link:(SZFriendsHelperLink *)link
            presenter:(id<SZFriendsDropdownPresenter>)presenter {
    _host = host;
    _link = link;
    _presenter = presenter;
    _context = [[SZFriendsContext alloc] initWithHost:host link:link];
    __weak SZFriendsDropdownController *weakSelf = self;
    _presenter.onDismiss = ^{ [weakSelf presenterDidDismiss]; };
    _windowFocused = ^BOOL(void) {
        SZFriendsDropdownController *controller = weakSelf;
        if (!controller || !NSApp.isActive) return NO;
        NSWindow *dropdownWindow = controller->_content.window, *buttonWindow = controller->_button.window;
        return dropdownWindow.isKeyWindow || buttonWindow.isKeyWindow;
    };
}

- (void)dealloc {
    if (_installed) {
        [_link removeObserver:self forKeyPath:@"state"];
        [_link removeObserver:self forKeyPath:@"helperCapabilities"];
    }
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSButton *)button {
    if (!_button) {
        _button = [[SZFriendsTitleButton alloc] initWithContext:_context];
        __weak SZFriendsDropdownController *weakSelf = self;
        _button.onPress = ^(SZFriendsButton *button) {
            (void)button;
            [weakSelf toggle];
        };
        _button.onSpringLoad = ^(SZFriendsDropVerdict verdict) { [weakSelf springOpenForVerdict:verdict]; };
        _button.onDropItems = ^(NSArray<SZFriendsAttachableItem *> *items) {
            [weakSelf beginSendPickerWithItems:items];
        };
    }
    return _button;
}

- (SZFriendsDropdownContent *)content {
    if (!_content) {
        // Built on first open, never at install: the launch path pays for one button and nothing else.
        _content = [[SZFriendsDropdownContent alloc] initWithContext:_context];
        __weak SZFriendsDropdownController *weakSelf = self;
        _content.onClose = ^{ [weakSelf close]; };
        _content.onTopPageChange = ^{ [weakSelf updateFocus]; };
    }
    return _content;
}

- (void)install {
    if (_installed) return;
    _installed = YES;
    id<SZFriendsHost> host = _host;
    [host friendsInstallButton:self.button];
    if (_link.state == SZFriendsLinkStateIdle) [_link start];
    __weak SZFriendsDropdownController *weakSelf = self;
    _badgeToken = [_link subscribeToView:@"badge" params:nil handler:^(NSDictionary *data, NSInteger rev) {
        (void)rev;
        [weakSelf applyBadge:data];
    }];
    // KVO rather than the link's onStateChange block, which belongs to the host adapter.
    [_link addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionInitial context:NULL];
    [_link addObserver:self forKeyPath:@"helperCapabilities" options:0 context:NULL];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(showJoin:) name:SZFriendsShowJoinNotification object:_link];
    // Focus follows the app and its windows: any key window or activation change may change what the person sees.
    for (NSNotificationName name in @[ NSApplicationDidBecomeActiveNotification,
                                       NSApplicationDidResignActiveNotification, NSWindowDidBecomeKeyNotification,
                                       NSWindowDidResignKeyNotification ])
        [center addObserver:self selector:@selector(focusMayHaveChanged:) name:name object:nil];
}

- (void)focusMayHaveChanged:(NSNotification *)notification {
    (void)notification;
    [self updateFocus];
}

#pragma mark - Focus (PROTOCOL.md § Notifications)

// The conversation the person is looking at: the dropdown open on it, in the active app's key window. The helper
// does not notify for it. Sent only on change, and only to a helper that posts notifications; a new connection
// starts with none, so it is sent again after a reconnect.
- (void)updateFocus {
    BOOL ready = _installed && _link.state == SZFriendsLinkStateReady;
    if (!ready || ![_link.helperCapabilities containsObject:@"notifications"]) {
        _sentFocus = nil;
        return;
    }
    NSString *focus = self.shown && self.windowFocused && self.windowFocused() ? _content.shownConversationID : nil;
    if (focus == _sentFocus || [focus isEqualToString:_sentFocus]) return;
    _sentFocus = [focus copy];
    [_link sendIntent:@"set_focus" fields:@{@"conversation_id" : focus ?: (id)NSNull.null} reply:nil];
}

- (void)showJoin:(NSNotification *)notification {
    (void)notification;
    [self open];
    [self.content openJoin];
}

- (void)uninstall {
    if (!_installed) return;
    [self close];
    _installed = NO;
    if (_sentFocus) [_link sendIntent:@"set_focus" fields:@{@"conversation_id" : NSNull.null} reply:nil];
    _sentFocus = nil;
    [_link removeObserver:self forKeyPath:@"state"];
    [_link removeObserver:self forKeyPath:@"helperCapabilities"];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_badgeToken) [_link unsubscribe:_badgeToken];
    _badgeToken = nil;
    [self withdrawServices];
    [_host friendsRemoveButton:self.button];
}

- (void)applyBadge:(NSDictionary *)data {
    NSString *label = SZFStr(data, @"label");
    _button.badgeLabel = label.length ? label : nil;
    _button.accessibilityLabel = SZFStr(data, @"accessibility_label") ?: [_context string:@"button_label"];
    // "Friends (Beta)": the tooltip says Friends is a beta; a helper without button_tooltip gives the plain name.
    NSString *toolTip = [_context string:@"button_tooltip"];
    if (!toolTip.length) toolTip = [_context string:@"button_label"];
    _button.toolTip = toolTip.length ? toolTip : nil;
}

#pragma mark - Services for the host (Cmd+K, citations)

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change
                       context:(void *)context {
    (void)object, (void)change, (void)context;
    BOOL ready = _link.state == SZFriendsLinkStateReady;
    if ([keyPath isEqualToString:@"state"]) {
        if (ready) [self offerServices];
        else [self withdrawServices];
        // Each connection starts with no focus on the helper's side.
        if (ready != _linkReady) _sentFocus = nil;
        _linkReady = ready;
    }
    [self updateFocus];
}

- (void)offerServices {
    id<SZFriendsHost> host = _host;
    if (_servicesOffered || ![host respondsToSelector:@selector(friendsServicesDidBecomeAvailable:)]) return;
    if (!_services) _services = [[SZFriendsServicesProvider alloc] initWithContext:_context controller:self];
    _servicesOffered = YES;
    [host friendsServicesDidBecomeAvailable:_services];
}

- (void)withdrawServices {
    id<SZFriendsHost> host = _host;
    if (!_servicesOffered) return;
    _servicesOffered = NO;
    if ([host respondsToSelector:@selector(friendsServicesDidBecomeUnavailable)])
        [host friendsServicesDidBecomeUnavailable];
}

#pragma mark - Showing and closing

- (BOOL)isShown {
    return _presenter.isPresented;
}

- (SZFriendsDropdownView)currentView {
    return _content ? _content.topPage.kind : SZFriendsDropdownViewList;
}

- (NSSize)dropdownSize {
    SZFriendsAppearance *appearance = _context.appearance;
    NSView *button = self.button;
    CGFloat space = appearance.dropdownMaxHeight + 24;
    if (button.window) space = NSMinY([button convertRect:button.bounds toView:nil]);
    return NSMakeSize(appearance.dropdownWidth, SZFriendsDropdownHeight(space, appearance.dropdownMaxHeight));
}

- (void)open {
    if (!_installed) return;
    if (self.shown) return;
    NSSize size = [self dropdownSize];
    SZFriendsDropdownContent *content = self.content;
    // The size only: the popover places its content view inside its own frame (13 pt in on macOS 26, clear of the
    // glass edge and arrow), and keeps the view between openings. Setting the origin here moved a reopened
    // dropdown's content down and left of that place, cropping its left and bottom edges (the owner's report of
    // 2026-10-20: search field against the left edge, footer cut off).
    [content setFrameSize:size];
    [_presenter presentView:content size:size fromButton:self.button];
    _button.selectedLook = YES;
    // The person opened Friends: the helper may start Nearby now, which is the only time it may prompt.
    [_link sendIntent:@"activate" fields:nil reply:nil];
    content.presented = YES;
}

- (void)toggle {
    if (_closedByButtonPress) {
        // The same click on the button already closed the popover (semi-transient closes on a click in the
        // window); reopening it on mouse-up would make the button impossible to close with.
        _closedByButtonPress = NO;
        return;
    }
    if (self.shown) [self close];
    else [self open];
}

- (void)close {
    if (self.shown) [_presenter dismiss];
    else [self presenterDidDismiss];
}

- (void)presenterDidDismiss {
    NSEvent *event = NSApp.currentEvent;
    if (event.type == NSEventTypeLeftMouseDown && _button.window && event.window == _button.window) {
        NSPoint point = [_button convertPoint:event.locationInWindow fromView:nil];
        if (NSPointInRect(point, _button.bounds)) {
            _closedByButtonPress = YES;
            dispatch_time_t soon = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
            dispatch_after(soon, dispatch_get_main_queue(), ^{ self->_closedByButtonPress = NO; });
        }
    }
    _button.selectedLook = NO;
    _content.presented = NO;
}

- (void)showList {
    [self open];
    [self.content popToList];
    [self.content.listPage showNearby:NO];
}

- (void)showConversation:(NSString *)conversationID highlightMessage:(NSString *)messageID {
    [self open];
    [self.content openConversation:conversationID highlightMessage:messageID];
}

- (void)beginSendPickerWithItems:(NSArray<SZFriendsAttachableItem *> *)items {
    if (!items.count) return;
    NSMutableArray *files = [NSMutableArray array];
    for (SZFriendsAttachableItem *item in items) [files addObject:[SZFriendsContext fileObjectForItem:item]];
    [self open];
    [self.content beginSendPickerWithFiles:files];
    [self offerLinkInsteadForItems:items];
}

// One file and a host that copies download links: "Copy link instead" under "Send Site photos.pdf to…".
- (void)offerLinkInsteadForItems:(NSArray<SZFriendsAttachableItem *> *)items {
    id<SZFriendsHost> host = _host;
    if (items.count != 1 || !self.offersLinks || ![host respondsToSelector:@selector(friendsCopyLinkInsteadLabel)] ||
        ![host respondsToSelector:@selector(friendsOfferDownloadLinkForItem:fromView:)])
        return;
    NSString *label = host.friendsCopyLinkInsteadLabel;
    if (!label.length) return;
    SZFriendsButton *button = [SZFriendsButton buttonWithTitle:label style:SZFriendsButtonStyleLink
                                                    appearance:_context.appearance];
    SZFriendsAttachableItem *item = items.firstObject;
    __weak SZFriendsDropdownController *weakSelf = self;
    button.onPress = ^(SZFriendsButton *pressed) {
        SZFriendsDropdownController *controller = weakSelf;
        id<SZFriendsHost> owner = controller ? controller->_host : nil;
        // The host's expiry choice runs from the button while it is still on screen; the picker ends after.
        [owner friendsOfferDownloadLinkForItem:item fromView:pressed];
        [controller.content finishSendPicker];
    };
    [self.content.listPage setSendPickerLinkButton:button];
}

#pragma mark - Links

- (BOOL)offersLinks {
    return _link.state == SZFriendsLinkStateReady && [_link.helperCapabilities containsObject:@"links"];
}

- (void)showLinkPayload:(NSString *)payload {
    if (!payload.length) return;
    [self open];
    [self.content openLinkPayload:payload];
}

- (void)copyDownloadLinkForItem:(SZFriendsAttachableItem *)item expiresDays:(NSInteger)days
                     completion:(void (^)(NSString *, BOOL))completion {
    NSDictionary *fields = @{@"file" : [SZFriendsContext fileObjectForItem:item], @"expires_days" : @(days)};
    SZFriendsContext *context = _context;
    [_link sendIntent:@"make_download_link" fields:fields reply:^(NSDictionary *result, SZFriendsLinkError *error) {
        NSString *url = SZFStr(result, @"url");
        if (error || !url.length) {
            completion(error.message, NO);
            return;
        }
        [context.pasteboard clearContents];
        [context.pasteboard setString:url forType:NSPasteboardTypeString];
        completion(SZFStr(result, @"message"), YES);
    }];
}

- (void)springOpenForVerdict:(SZFriendsDropVerdict)verdict {
    [self open];
    [self.content popToList];
    [self.content.listPage showNearby:NO];
    // Above the rows: why the files would not go (a folder's, a link's words), or how to send them.
    NSString *refusal = SZFriendsDropRefusalKey(verdict);
    NSString *hint = [_context string:refusal ?: @"drop_hint"];
    [self.content setDropHint:hint.length ? hint : nil refusing:refusal != nil && hint.length];
}

@end
