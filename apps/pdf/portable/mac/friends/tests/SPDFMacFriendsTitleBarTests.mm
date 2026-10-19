// The Friends button between Groups and Search: one contiguous hit area, no overlap, and the title-bar space on
// either side still dragging the window under the reader's own chrome policy (SPDFMacWindowChrome.mm), in an
// offscreen window built like the coordinator's title bar. Never shown on screen.

#import <AppKit/AppKit.h>
#import "SPDFMacFriendsTitleBar.h"
#import "SPDFMacWindowChrome.h"
#import "SPDFMacFriendsTestSupport.h"

typedef struct {
    NSWindow* window;
    NSView* content;
    NSView* strip;
    NSButton* search;
    NSLayoutConstraint* stripTrailing;
} Bar;

static NSString* Source(NSString* path) {
    NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    Expect(text.length, @"cannot read %@ (tests run with cwd portable/)", path);
    return text;
}

// The geometry below models the coordinator's title bar; if any of these lines change, this test must change too.
static void TestModelMatchesTheReader(void) {
    Expect([Source(@"mac/ShenzhenPDFMac.mm") containsString:
            @"[_tabStrip.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-44]"],
           @"the tab strip no longer ends 44 pt before the trailing edge");
    Expect([Source(@"mac/SPDFMacWorkspaceChrome.mm") containsString:@"[state.command.trailingAnchor "
            "constraintEqualToAnchor:_window.contentView.trailingAnchor constant:-8]"], @"Search moved");
    Expect([Source(@"mac/SPDFMacWorkspaceChrome.mm")
               containsString:@"[button.widthAnchor constraintEqualToConstant:24]"],
           @"Search is no longer 24 pt wide");
    // The reader's category finds Search by its action, directly in the content view.
    Expect([Source(@"mac/SPDFMacWorkspaceChrome.mm")
               containsString:@"state.command = Icon(@\"magnifyingglass\",@\"Find "
            "documents, groups and text · ⌘K\",self,@selector(showFavoritesPalette:));\n    [_window.contentView "
            "addSubview:state.command];"], @"Search is no longer a content-view button sending showFavoritesPalette:");
    Expect([Source(@"mac/SPDFMacTabStripLayout.mm") containsString:
            @"NSMakeRect(MAX([self leftInset]+32,NSWidth(self.bounds)-36), floor((NSHeight(self.bounds)-28)/2),28,28)"],
           @"the tab strip draws Groups somewhere else; update SPDFMacFriendsGroupsRectInStrip");
    // Groups, Friends and Search are one row of icons in one colour (the owner's report of 2026-10-20: Groups was
    // labelColor, a translucent grey beside the other two). Friends takes it through its appearance
    // (SPDFMacFriendsIntegrationTests), Search through SPDFWorkspaceIconCell, Groups here.
    Expect([Source(@"mac/SPDFMacTabStripDrawing.mm") containsString:@"@\"square.3.layers.3d\" "
            "accessibilityDescription:@\"All Groups\"];"] &&
               [Source(@"mac/SPDFMacTabStripDrawing.mm") containsString:@"configurationWithPaletteColors:"
            "@[SPDFChromeIconColor(YES)]]];"],
           @"the Groups icon no longer takes the title bar's icon colour");
    Expect([Source(@"mac/SPDFMacWorkspaceChrome.mm") containsString:@"configurationWithPaletteColors:"
            "@[SPDFChromeIconColor(self.enabled)]]] ?: image;"], @"Search no longer takes the title bar's icon colour");
}

static Bar MakeBar(CGFloat width) {
    Bar bar = {};
    bar.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, 500)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                                                        NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:YES];
    bar.window.titlebarAppearsTransparent = YES;
    bar.window.releasedWhenClosed = NO;
    bar.content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 500)];
    bar.window.contentView = bar.content;
    bar.strip = [NSView new];
    bar.strip.translatesAutoresizingMaskIntoConstraints = NO;
    [bar.content addSubview:bar.strip];
    bar.search = [NSButton buttonWithTitle:@"" target:nil action:NSSelectorFromString(@"showFavoritesPalette:")];
    bar.search.bordered = NO;
    bar.search.translatesAutoresizingMaskIntoConstraints = NO;
    [bar.content addSubview:bar.search];
    [NSLayoutConstraint activateConstraints:@[
        [bar.strip.topAnchor constraintEqualToAnchor:bar.content.topAnchor],
        [bar.strip.leadingAnchor constraintEqualToAnchor:bar.content.leadingAnchor],
        [bar.strip.trailingAnchor constraintEqualToAnchor:bar.content.trailingAnchor constant:-44],
        [bar.strip.heightAnchor constraintEqualToConstant:44],
        [bar.search.widthAnchor constraintEqualToConstant:24], [bar.search.heightAnchor constraintEqualToConstant:24],
        [bar.search.trailingAnchor constraintEqualToAnchor:bar.content.trailingAnchor constant:-8],
        [bar.search.centerYAnchor constraintEqualToAnchor:bar.strip.centerYAnchor]]];
    bar.stripTrailing = SPDFMacFriendsTrailingConstraint(bar.content, bar.strip);
    [bar.content layoutSubtreeIfNeeded];
    return bar;
}

static NSView* HitAt(Bar bar, NSPoint point) {
    return [bar.content hitTest:[bar.content convertPoint:point toView:bar.content.superview]];
}

static NSRect GroupsRect(Bar bar) {
    NSRect inStrip = SPDFMacFriendsGroupsRectInStrip(bar.strip.bounds);
    return [bar.strip convertRect:inStrip toView:bar.content];
}

static void ExpectDraggable(Bar bar, NSPoint point, NSString* where) {
    NSView* hit = HitAt(bar, point);
    Expect(hit && !spdf_window_chrome_view_is_interactive(hit), @"%@ at %@ hits %@, which would not drag the window",
           where, NSStringFromPoint(point), hit);
    Expect(spdf_window_chrome_action(1, NO, NO, spdf_window_chrome_view_is_interactive(hit)) ==
           SPDFWindowChromeActionDrag, @"%@ is not draggable title bar", where);
}

static void CheckPlacement(Bar bar, NSButton* friends) {
    [bar.content layoutSubtreeIfNeeded];
    NSRect button = friends.frame, groups = GroupsRect(bar), search = bar.search.frame;
    Expect(NSWidth(button) == 28 && NSHeight(button) == 28, @"button frame %@", NSStringFromRect(button));
    Expect(fabs(NSMidY(button) - NSMidY(bar.strip.frame)) < 0.01, @"button is off the tab strip's row");
    Expect(fabs(NSMaxX(groups) + 8 - NSMinX(button)) < 0.01 && fabs(NSMaxX(button) + 8 - NSMinX(search)) < 0.01,
           @"gaps: groups %@ friends %@ search %@", NSStringFromRect(groups), NSStringFromRect(button),
           NSStringFromRect(search));
    Expect(NSMaxX(bar.strip.frame) <= NSMinX(button) + 0.01, @"the tab strip's frame overlaps the button");
    // Every point of the frame belongs to the button: a first click anywhere on it works.
    for (CGFloat x = NSMinX(button) + 0.25; x < NSMaxX(button); x += 0.5)
        for (CGFloat y = NSMinY(button) + 0.25; y < NSMaxY(button); y += 0.5) {
            NSView* hit = HitAt(bar, NSMakePoint(x, y));
            Expect(hit == friends || [hit isDescendantOf:friends], @"(%.2f, %.2f) inside the button hits %@", x, y,
                   hit);
            if (hit != friends && ![hit isDescendantOf:friends]) return;
        }
    Expect(spdf_window_chrome_action(1, NO, NO, spdf_window_chrome_view_is_interactive(friends)) ==
           SPDFWindowChromeActionNone, @"a click on the button would drag the window");
    // Just outside the frame, on all four sides, is not the button.
    for (NSValue* value in @[[NSValue valueWithPoint:NSMakePoint(NSMinX(button) - 0.5, NSMidY(button))],
                             [NSValue valueWithPoint:NSMakePoint(NSMaxX(button) + 0.5, NSMidY(button))],
                             [NSValue valueWithPoint:NSMakePoint(NSMidX(button), NSMinY(button) - 0.5)],
                             [NSValue valueWithPoint:NSMakePoint(NSMidX(button), NSMaxY(button) + 0.5)]]) {
        NSView* hit = HitAt(bar, value.pointValue);
        Expect(hit != friends && ![hit isDescendantOf:friends], @"the button claims %@ outside its frame",
               NSStringFromPoint(value.pointValue));
    }
    ExpectDraggable(bar, NSMakePoint(NSMaxX(groups) + 4, NSMidY(button)), @"the gap between Groups and Friends");
    ExpectDraggable(bar, NSMakePoint(NSMaxX(button) + 4, NSMidY(button)), @"the gap between Friends and Search");
    ExpectDraggable(bar, NSMakePoint(NSMidX(button), NSMaxY(button) + 3), @"the title bar below the button");
}

static void TestInstallAndUninstall(void) {
    Bar bar = MakeBar(900);
    Expect(bar.stripTrailing != nil, @"the tab strip's trailing constraint was not found");
    Expect(SPDFMacFriendsButtonWithAction(bar.content, NSSelectorFromString(@"showFavoritesPalette:")) == bar.search &&
           !SPDFMacFriendsButtonWithAction(bar.content, @selector(copy:)), @"Search must be found by its action");
    CGFloat originalStripEnd = NSMaxX(bar.strip.frame);
    NSButton* friends = [NSButton buttonWithTitle:@"" target:nil action:nil];
    friends.bordered = NO;
    SPDFMacFriendsTitleBarPlacement* placement =
        SPDFMacFriendsInstallTitleBarButton(friends, bar.content, bar.strip, bar.stripTrailing, bar.search, 28);
    Expect(placement.installed && friends.superview == bar.content, @"the button was not installed");
    CheckPlacement(bar, friends);

    // Narrow windows keep the same arrangement: the strip gives up width, the three buttons never overlap.
    [bar.window setContentSize:NSMakeSize(420, 500)];
    CheckPlacement(bar, friends);
    [bar.window setContentSize:NSMakeSize(900, 500)];

    [placement uninstall];
    [bar.content layoutSubtreeIfNeeded];
    Expect(!friends.superview && bar.stripTrailing.active && fabs(NSMaxX(bar.strip.frame) - originalStripEnd) < 0.01,
           @"uninstall must give the title bar back exactly as it was");
    [placement uninstall];  // idempotent

    // The pieces must share one view tree; otherwise nothing changes.
    NSView* elsewhere = [NSView new];
    Expect(!SPDFMacFriendsInstallTitleBarButton(friends, elsewhere, bar.strip, bar.stripTrailing, bar.search, 28) &&
           bar.stripTrailing.active, @"an install into the wrong view changed the title bar");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        TestModelMatchesTheReader();
        TestInstallAndUninstall();
    }
    puts("SPDFMacFriendsTitleBarTests passed");
    return 0;
}
