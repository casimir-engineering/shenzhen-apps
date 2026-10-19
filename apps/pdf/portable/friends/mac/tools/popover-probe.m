// popover-probe <fixtures dir> <animal manifest> <renders dir>: the dropdown in a real NSPopover, opened twice from a
// button in a window, with where AppKit put it. Puts a window on screen for about a second, so it is not part of
// friends-views-check (which never shows one); run it by hand with `make friends-views-popover-probe` after changing
// how the dropdown is presented. It exits 1 when, on either opening, the content view is not where the popover
// placed it the first time or any visible view lies outside it. Renders go to <renders dir>/popover-probe-*.png.
#import "SZFriendsViewsTestSupport.h"

static NSDictionary *LastSent(SZFTestTransport *transport, NSString *type) {
    for (NSDictionary *frame in transport.sent.reverseObjectEnumerator)
        if ([frame[@"type"] isEqualToString:type]) return frame;
    return @{};
}

static NSUInteger Outside(NSView *view, NSView *root, NSRect area) {
    if (view.hidden || view.alphaValue == 0) return 0;
    NSRect frame = [view convertRect:view.bounds toView:root];
    NSUInteger count = NSWidth(frame) > 0 && !NSContainsRect(NSInsetRect(area, -0.5, -0.5), frame) ? 1 : 0;
    if (count) printf("  outside: %s %s\n", view.className.UTF8String, NSStringFromRect(frame).UTF8String);
    if ([view isKindOfClass:NSScrollView.class] || [view isKindOfClass:NSControl.class]) return count;
    for (NSView *subview in view.subviews) count += Outside(subview, root, area);
    return count;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 4) return 2;
        SZFTestFixturesDir = @(argv[1]);
        SZFTestRendersDir = @(argv[3]);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [SZFriendsAvatarView setAnimalManifestPath:@(argv[2])];
        char state[] = "/tmp/szfriends-popover-probe.XXXXXX";
        if (!mkdtemp(state)) return 2;
        setenv("SZFRIENDS_STATE_DIR", state, 1);
        setenv("SZFRIENDS_KEY_STORE", "file", 1);
        SZFTestTransport *transport = nil;
        SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
        SZFTestHost *host = [SZFTestHost new];
        SZFriendsDropdownController *controller = [[SZFriendsDropdownController alloc] initWithHost:host link:link];
        [controller install];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 900, 760)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        host.installedButton.frame = NSMakeRect(700, 720, 28, 28);
        [window.contentView addSubview:host.installedButton];
        [window orderFront:nil];
        NSRect placed = NSZeroRect;
        int failures = 0;
        for (int opening = 1; opening <= 2; opening++) {
            [controller toggle];
            if (opening == 1) {
                NSDictionary *subscribe = LastSent(transport, @"subscribe");
                [transport deliver:@{@"type" : @"reply", @"re" : subscribe[@"id"] ?: @"", @"ok" : @YES,
                                     @"result" : @{@"subscription" : @"s_1"}}];
                [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_1", @"view" : @"list",
                                     @"rev" : @1, @"data" : SZFTestSnapshot(@"list")}];
            }
            SZFTestSpin(0.3);
            NSView *content = controller.content;
            NSView *frameView = content.superview;
            if (opening == 1) placed = content.frame;
            printf("opening %d: popover frame %s, content %s\n", opening, NSStringFromRect(frameView.frame).UTF8String,
                   NSStringFromRect(content.frame).UTF8String);
            if (!NSEqualRects(content.frame, placed)) failures++;
            NSUInteger outside = Outside(content, frameView, placed);
            failures += outside > 0;
            SZFTestRender(frameView, [NSString stringWithFormat:@"popover-probe-%d", opening], 2);
            [controller close];
            SZFTestSpin(0.2);
        }
        [window orderOut:nil];
        printf("%s\n", failures ? "popover-probe: FAILED" : "popover-probe passed");
        return failures ? 1 : 0;
    }
}
