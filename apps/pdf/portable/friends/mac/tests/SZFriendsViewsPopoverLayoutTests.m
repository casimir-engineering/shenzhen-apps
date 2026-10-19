// The dropdown inside its popover: everything it draws lies inside the popover's content area, opened once and
// again, at its full height and in a short window, in light and dark, and the Friends button looks selected only
// while it is open. Then Nearby's Allow and Try Again, and Settings' Nearby line, send what they say.
//
// The presenter hosts the dropdown the way NSPopover does on macOS 26 (an NSPopoverFrame that places the content
// view 13 pt in from each side and keeps it there between openings), in a window that never reaches the screen. A
// real popover cannot be shown without a window on screen; friends/mac/tools/popover-probe.m does that by hand.

#import "SZFriendsViewsTestSupport.h"

static const CGFloat SZFPopoverInset = 13;

@interface SZFTestInsetPresenter : NSObject <SZFriendsDropdownPresenter>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSView *frameView;
@property(nonatomic, strong, nullable) NSView *content;
@end

@implementation SZFTestInsetPresenter {
    BOOL _presented;
}
@synthesize onDismiss = _onDismiss;
- (instancetype)initWithAppearance:(NSAppearanceName)appearance {
    if ((self = [super init])) {
        _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 900)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:YES];
        _window.releasedWhenClosed = NO;
        _window.appearance = [NSAppearance appearanceNamed:appearance];
        _frameView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 900)];
        _window.contentView = _frameView;
    }
    return self;
}
- (BOOL)isPresented {
    return _presented;
}
- (void)presentView:(NSView *)view size:(NSSize)size fromButton:(NSView *)button {
    (void)button;
    _presented = YES;
    // As NSPopover: the frame fits the content size plus its inset, and the content is placed once, when it
    // arrives; a view it already holds keeps the origin it was given.
    [_frameView setFrameSize:NSMakeSize(size.width + 2 * SZFPopoverInset, size.height + 2 * SZFPopoverInset)];
    if (view.superview != _frameView) {
        [view removeFromSuperview];
        view.frame = NSMakeRect(SZFPopoverInset, SZFPopoverInset, size.width, size.height);
        [_frameView addSubview:view];
    } else {
        [view setFrameSize:size];
    }
    _content = view;
    [_frameView layoutSubtreeIfNeeded];
}
- (void)resizeTo:(NSSize)size {
    [_content setFrameSize:size];
}
- (void)dismiss {
    if (!_presented) return;
    _presented = NO;
    if (self.onDismiss) self.onDismiss();
}
- (NSRect)contentArea {
    return NSInsetRect(_frameView.bounds, SZFPopoverInset, SZFPopoverInset);
}
@end

static NSDictionary *SZFLastSentOfType(SZFTestTransport *transport, NSString *type) {
    for (NSDictionary *frame in transport.sent.reverseObjectEnumerator)
        if ([frame[@"type"] isEqualToString:type]) return frame;
    return nil;
}

static void SZFDeliverView(SZFTestTransport *transport, NSString *view, NSDictionary *data, NSString *subscription) {
    NSDictionary *subscribe = nil;
    for (NSDictionary *frame in transport.sent.reverseObjectEnumerator)
        if ([frame[@"type"] isEqualToString:@"subscribe"] && [frame[@"fields"][@"view"] isEqualToString:view]) {
            subscribe = frame;
            break;
        }
    if (subscribe) {
        [transport deliver:@{@"type" : @"reply", @"re" : subscribe[@"id"], @"ok" : @YES,
                             @"result" : @{@"subscription" : subscription}}];
    }
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : subscription, @"view" : view, @"rev" : @1,
                         @"data" : data}];
}

// Every visible view the dropdown draws, in the frame view's coordinates. A scroll view's document is checked as
// the scroll view (rows scroll inside it; that is not cropping).
static void SZFCollectOutside(NSView *view, NSView *root, NSRect area, NSMutableArray<NSString *> *outside) {
    if (view.hidden || view.alphaValue == 0) return;
    NSRect frame = [view convertRect:view.bounds toView:root];
    if (NSWidth(frame) > 0 && NSHeight(frame) > 0 && !NSContainsRect(NSInsetRect(area, -0.5, -0.5), frame)) {
        [outside addObject:[NSString stringWithFormat:@"%@ %@", view.className, NSStringFromRect(frame)]];
    }
    if ([view isKindOfClass:NSScrollView.class] || [view isKindOfClass:NSTextField.class] ||
        [view isKindOfClass:NSSearchField.class])
        return;
    for (NSView *subview in view.subviews) SZFCollectOutside(subview, root, area, outside);
}

static void SZFExpectInside(SZFTestInsetPresenter *presenter, NSString *label) {
    NSView *content = presenter.content;
    [presenter.frameView layoutSubtreeIfNeeded];
    NSRect area = [presenter contentArea];
    SZFExpect(NSEqualRects(content.frame, area), @"%@: the dropdown is placed %@ in a content area of %@", label,
              NSStringFromRect(content.frame), NSStringFromRect(area));
    NSMutableArray<NSString *> *outside = [NSMutableArray array];
    SZFCollectOutside(content, presenter.frameView, area, outside);
    SZFExpect(outside.count == 0, @"%@: drawn outside the popover's content area: %@", label, outside);
}

static NSDictionary *SZFListWithIdentityBanner(void) {
    NSMutableDictionary *list = [SZFTestSnapshot(@"list") mutableCopy];
    list[@"banner"] = @{
        @"kind" : @"identity_unavailable",
        @"text" : @"Friends can’t open your identity on this computer, so nobody can reach you here until you "
                  @"reset Friends.",
        @"action" : @{
            @"action" : @"reset_friends", @"label" : @"Reset Friends…", @"style" : @"destructive",
            @"confirm" : @{@"title" : @"Reset Friends?", @"body" : @"You get a new ID.", @"confirm_label" : @"Reset",
                           @"cancel_label" : @"Cancel", @"destructive" : @YES}
        }
    };
    return list;
}

static void SZFTestDropdownInsidePopover(NSAppearanceName appearance, CGFloat windowHeight, NSString *label) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    SZFTestHost *host = [SZFTestHost new];
    SZFTestInsetPresenter *presenter = [[SZFTestInsetPresenter alloc] initWithAppearance:appearance];
    SZFriendsDropdownController *controller = [[SZFriendsDropdownController alloc] initWithHost:host link:link
                                                                                       presenter:presenter];
    [controller install];
    // The host's title bar: the button near the top of a window `windowHeight` tall, so the dropdown gets the
    // space below it (a short window gets the 280 pt minimum).
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, windowHeight)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    window.appearance = [NSAppearance appearanceNamed:appearance];
    host.installedButton.frame = NSMakeRect(700, windowHeight - 34, 28, 28);
    [window.contentView addSubview:host.installedButton];
    SZFriendsTitleButton *button = (SZFriendsTitleButton *)controller.button;
    SZFExpect(!button.selectedLook, @"%@: the button is not selected while Friends is closed", label);

    [controller toggle];
    SZFExpect(button.selectedLook, @"%@: selected while the dropdown is open", label);
    SZFDeliverView(transport, @"list", SZFListWithIdentityBanner(), @"s_list");
    SZFExpectInside(presenter, [label stringByAppendingString:@", first opening"]);
    // The owner's report (2026-10-20): reopened, the content sat down and left of the popover, cropped.
    [controller close];
    SZFExpect(!button.selectedLook, @"%@: not selected once closed", label);
    [controller toggle];
    SZFExpectInside(presenter, [label stringByAppendingString:@", opened again"]);
    SZFriendsFooterView *footer = SZFTestSubviews(controller.content, SZFriendsFooterView.class).firstObject;
    NSRect footerFrame = [footer convertRect:footer.bounds toView:presenter.frameView];
    SZFExpect(footer && NSContainsRect(NSInsetRect([presenter contentArea], -0.5, -0.5), footerFrame) &&
                  NSHeight(footerFrame) >= [footer heightForWidth:NSWidth(footerFrame)] - 0.5,
              @"%@: the footer shows whole: %@", label, NSStringFromRect(footerFrame));

    // Reset Friends… from the banner: its question shows inside the dropdown, where the person can answer it.
    SZFriendsNoticeView *banner = nil;
    for (SZFriendsNoticeView *notice in SZFTestSubviews(controller.content.listPage, SZFriendsNoticeView.class))
        if (!notice.hidden && [notice.bodyLabel.stringValue containsString:@"identity"]) banner = notice;
    if (!banner) {
        for (SZFriendsNoticeView *notice in SZFTestSubviews(controller.content.listPage, SZFriendsNoticeView.class))
            if (!notice.hidden && [notice.titleLabel.stringValue containsString:@"identity"]) banner = notice;
    }
    SZFExpect(banner.button != nil, @"%@: the reset banner has its button", label);
    [banner.button performClick:nil];
    SZFriendsConfirmView *confirmation = controller.content.confirmation;
    SZFExpect(confirmation != nil, @"%@: Reset Friends… asks first", label);
    SZFExpectInside(presenter, [label stringByAppendingString:@", Reset Friends question"]);
    [confirmation.confirmButton performClick:nil];
    NSDictionary *reset = SZFLastSentOfType(transport, @"reset_friends");
    SZFExpect([reset[@"fields"][@"confirm"] isEqual:@"reset"], @"%@: the confirm button sends Reset: %@", label, reset);

    // The Nearby tab with its card, at the same sizes.
    [controller.content.listPage showNearby:YES];
    SZFDeliverView(transport, @"nearby", SZFTestSnapshot(@"nearby-local-network-denied"), @"s_nearby");
    SZFExpectInside(presenter, [label stringByAppendingString:@", Nearby"]);
    NSString *name = [NSString stringWithFormat:@"popover-%@-%@", label,
                      [appearance isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark"];
    SZFExpect(SZFTestRender(presenter.frameView, [name stringByReplacingOccurrencesOfString:@" " withString:@"-"], 2),
              @"%@: render written", label);
    [controller close];
    [controller uninstall];
}

// Nearby's Allow (nothing asked yet) and Try Again (a method failing) send `activate`, as opening Friends does.
static void SZFTestNearbyAllowSendsActivate(void) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], link);
    SZFriendsNearbyPane *pane = [[SZFriendsNearbyPane alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(pane, NSMakeSize(400, 600), NSAppearanceNameAqua);
    NSMutableDictionary *data = [SZFTestSnapshot(@"nearby-local-network-denied") mutableCopy];
    data[@"alert"] = @{@"title" : @"Find people near you", @"body" : @"Click Allow to start looking.",
                       @"action" : @{@"action" : @"activate", @"label" : @"Allow", @"style" : @"primary"}};
    [pane applyNearby:data];
    [window.contentView layoutSubtreeIfNeeded];
    SZFriendsButton *allow = nil;
    for (SZFriendsButton *candidate in SZFTestSubviews(pane, SZFriendsButton.class))
        if ([candidate.title isEqualToString:@"Allow"] && !candidate.hidden) allow = candidate;
    SZFExpect(allow != nil, @"the card shows Allow");
    [transport.sent removeAllObjects];
    [allow performClick:nil];
    SZFExpect([SZFLastSentOfType(transport, @"activate") isKindOfClass:NSDictionary.class],
              @"Allow sends activate: %@", transport.sent);
}

// Settings' Nearby line: its words and its one button, which sends what the helper put on it.
static void SZFTestSettingsNearbyLine(void) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    SZFriendsSettingsSection *section = [[SZFriendsSettingsSection alloc] initWithHost:[SZFTestHost new] link:link];
    NSWindow *window = SZFTestHostWindow(section.view, NSMakeSize(560, 700), NSAppearanceNameAqua);
    [section sectionWillAppear];
    NSMutableDictionary *settings = [SZFTestSnapshot(@"settings") mutableCopy];
    settings[@"nearby"] = @{@"label" : @"Nearby",
                            @"note" : @"Allow ShenzhenPDF to find people nearby. The first time, you’re asked "
                                      @"whether it may use your local network and Bluetooth.",
                            @"action" : @{@"action" : @"activate", @"label" : @"Allow", @"style" : @"secondary"}};
    SZFDeliverView(transport, @"settings", settings, @"s_settings");
    [window.contentView layoutSubtreeIfNeeded];
    SZFriendsButton *allow = section.nearbyButton;
    SZFExpect(!allow.hidden && [allow.title isEqualToString:@"Allow"] && NSWidth(allow.frame) > 0,
              @"the Nearby line has Allow: %@ %@", allow.title, NSStringFromRect(allow.frame));
    BOOL saysIt = NO;
    for (NSTextField *field in SZFTestSubviews(section.view, NSTextField.class))
        if ([field.stringValue containsString:@"you’re asked"] && !field.hidden && NSHeight(field.frame) > 0) saysIt = YES;
    SZFExpect(saysIt, @"the Nearby line says what Allow does");
    [transport.sent removeAllObjects];
    [allow performClick:nil];
    SZFExpect(SZFLastSentOfType(transport, @"activate") != nil, @"Allow in Settings sends activate");

    settings[@"nearby"] = @{@"label" : @"Nearby", @"note" : @"Local Network access is off for ShenzhenPDF.",
                            @"action" : @{@"action" : @"open_settings", @"label" : @"Open Privacy Settings",
                                          @"style" : @"secondary", @"settings_target" : @"local_network_privacy"}};
    __block NSURL *opened = nil;
    section.context.openURL = ^(NSURL *url) { opened = url; };
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_settings", @"view" : @"settings", @"rev" : @2,
                         @"data" : settings}];
    [window.contentView layoutSubtreeIfNeeded];
    [section.nearbyButton performClick:nil];
    SZFExpect([opened.absoluteString containsString:@"Privacy_LocalNetwork"], @"opens the Local Network pane: %@",
              opened);

    // Without the line (an older helper), nothing shows for it.
    [settings removeObjectForKey:@"nearby"];
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_settings", @"view" : @"settings", @"rev" : @3,
                         @"data" : settings}];
    [window.contentView layoutSubtreeIfNeeded];
    SZFExpect(section.nearbyButton.hidden, @"no Nearby button without the line");
    [section sectionDidDisappear];
}

void SZFTestPopoverLayout(void) {
    for (NSAppearanceName appearance in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        SZFTestDropdownInsidePopover(appearance, 900, @"full height");
        SZFTestDropdownInsidePopover(appearance, 330, @"short window");
    }
    SZFTestNearbyAllowSendsActivate();
    SZFTestSettingsNearbyLine();
}
