// The assistant's app_controls tool never sees or operates Friends (brief § AI boundaries: without an `@` chip the
// assistant cannot see Friends at all; text cannot change settings). The security review found it could list and
// press the Friends button, dropdown rows, request buttons, the Settings section and its confirmation alerts.
//
// Windows here are never ordered on screen: a fixture window reports itself visible, which is all app_controls asks.
// Friends interface is stood in for by views carrying the "szfriends." identifier prefix the views give theirs, plus
// the host adapter's own Settings pane and title-bar placement, which mark themselves.

#import <AppKit/AppKit.h>
#import "SPDFMacAIAppControls.h"
#import "SPDFMacFriendsSettingsPane.h"
#import "SPDFMacFriendsTitleBar.h"
#import "SPDFMacFriendsTestSupport.h"

@interface FixtureWindow : NSWindow
@end
@implementation FixtureWindow
- (BOOL)isVisible { return YES; }
@end

@interface Presses : NSObject
@property NSInteger count;
- (void)press:(id)sender;
@end
@implementation Presses
- (void)press:(id)sender { (void)sender; self.count++; }
@end

static FixtureWindow* Window(void) {
    FixtureWindow* window = [[FixtureWindow alloc] initWithContentRect:NSMakeRect(-20000, -20000, 800, 500)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    return window;
}

static NSButton* Button(NSString* title, NSView* parent, Presses* presses) {
    NSButton* button = [NSButton buttonWithTitle:title target:presses action:@selector(press:)];
    [parent addSubview:button];
    return button;
}

static NSView* Container(NSString* identifier, NSView* parent) {
    NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    view.identifier = identifier;
    [parent addSubview:view];
    return view;
}

static NSArray<NSString*>* Labels(NSDictionary* inspection, NSString* key) {
    return [inspection[key] valueForKey:@"label"] ?: @[];
}

static NSString* TargetID(NSDictionary* inspection, NSString* label) {
    for (NSDictionary* row in inspection[@"controls"]) if ([row[@"label"] isEqual:label]) return row[@"id"];
    return nil;
}

static void Spin(void) {
    SPDFMacFriendsTestRunUntil(0.2, ^BOOL { return NO; });
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        Presses* presses = [Presses new];

        // The reader window: Search and a plain button, the Friends title button, and an open dropdown page.
        FixtureWindow* reader = Window();
        NSView* content = reader.contentView;
        NSView* strip = [[NSView alloc] initWithFrame:NSMakeRect(0, 460, 600, 40)];
        [content addSubview:strip];
        NSLayoutConstraint* stripTrailing = [strip.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                                                                 constant:-44];
        stripTrailing.active = YES;
        NSButton* search = Button(@"Search", content, presses);
        NSButton* movable = Button(@"Rotate", content, presses);
        NSButton* friends = [NSButton buttonWithTitle:@"Friends" target:presses action:@selector(press:)];
        Expect(SPDFMacFriendsInstallTitleBarButton(friends, content, strip, stripTrailing, search, 24),
               @"the Friends button was not placed");
        NSView* dropdown = Container(@"szfriends.popover.list", content);
        NSView* row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 44)];
        [dropdown addSubview:row];
        Button(@"Accept", row, presses).accessibilityLabel = @"Accept Lena Fischer’s request";
        NSTextField* name = [NSTextField textFieldWithString:@"Raph"];
        name.editable = YES;
        [row addSubview:name];

        // Settings: a reader section, the host's Friends pane (checkbox and disclosure) and the views' section.
        FixtureWindow* settings = Window();
        Button(@"General", settings.contentView, presses);
        SPDFMacFriendsSettingsPane* pane = [[SPDFMacFriendsSettingsPane alloc] initWithSource:nil];
        [settings.contentView addSubview:pane];
        Button(@"Delete history", Container(@"szfriends.settings", pane.sectionContainer), presses);

        // A Friends confirmation alert, marked on its content view, and one marked on the window.
        FixtureWindow* alert = Window();
        alert.contentView.identifier = @"szfriends.alert.reset";
        Button(@"Reset Friends", alert.contentView, presses);
        FixtureWindow* panel = Window();
        panel.identifier = @"szfriends.alert.block";
        Button(@"Block", panel.contentView, presses);

        // The menu bar: an ordinary command and a Friends submenu.
        NSMenu* menu = [NSMenu new];
        NSMenuItem* file = [menu addItemWithTitle:@"File" action:nil keyEquivalent:@""];
        file.submenu = [NSMenu new];
        [file.submenu addItemWithTitle:@"Open…" action:@selector(press:) keyEquivalent:@""].target = presses;
        NSMenuItem* friendsMenu = [menu addItemWithTitle:@"Friends" action:nil keyEquivalent:@""];
        friendsMenu.identifier = @"szfriends.menu";
        friendsMenu.submenu = [NSMenu new];
        NSMenuItem* reset = [friendsMenu.submenu addItemWithTitle:@"Reset Friends…" action:@selector(press:)
                                                    keyEquivalent:@""];
        reset.target = presses;

        NSMutableDictionary* targets = [NSMutableDictionary dictionary];
        NSDictionary* inspection = SPDFMacAIAppControlsInspect(menu, @[reader, settings, alert, panel], targets);
        NSArray* controls = Labels(inspection, @"controls"), *menus = Labels(inspection, @"menus");
        Expect([controls containsObject:@"Search"] && [controls containsObject:@"Rotate"] &&
               [controls containsObject:@"General"] && [menus containsObject:@"File → Open…"],
               @"ordinary controls must still be listed: %@ %@", controls, menus);
        for (NSString* hidden in @[@"Friends", @"Accept Lena Fischer’s request", @"Raph", @"Delete history",
                                   @"Reset Friends", @"Block", SPDFMacFriendsEnableTitle, @"friendsEnabled"])
            Expect(![controls containsObject:hidden], @"app_controls listed Friends interface \"%@\": %@", hidden,
                   controls);
        for (NSString* label in menus)
            Expect(![label containsString:@"Friends"], @"app_controls listed a Friends menu item: %@", label);
        Expect(targets.count == controls.count + menus.count, @"a target was kept that the list does not show");

        // Pressing an ordinary button still works, so the refusals below are refusals.
        NSDictionary* result = SPDFMacAIAppControlsOperate(@"activate", @{@"id" : TargetID(inspection, @"Search")},
                                                           targets);
        Spin();
        Expect([result[@"dispatched"] boolValue] && presses.count == 1, @"Search was not pressed: %@", result);

        // A control that moved into Friends interface after the list was made cannot be pressed.
        NSString* rotate = TargetID(inspection, @"Rotate");
        [movable removeFromSuperview];
        [row addSubview:movable];
        result = SPDFMacAIAppControlsOperate(@"activate", @{@"id" : rotate}, targets);
        Spin();
        Expect(result[@"error"] && presses.count == 1, @"a control inside Friends was pressed: %@", result);

        // Nor can a stale or forged target name Friends controls, menu items or the Settings checkbox.
        NSDictionary* forged = @{@"f" : friends, @"n" : name, @"c" : pane.enableCheckbox, @"m" : reset};
        Expect(SPDFMacAIAppControlsOperate(@"activate", @{@"id" : @"f"}, forged)[@"error"] &&
               SPDFMacAIAppControlsOperate(@"set", @{@"id" : @"n", @"value" : @"Mallory"}, forged)[@"error"] &&
               SPDFMacAIAppControlsOperate(@"activate", @{@"id" : @"c"}, forged)[@"error"] &&
               SPDFMacAIAppControlsOperate(@"activate", @{@"id" : @"m"}, forged)[@"error"],
               @"a forged target reached Friends interface");
        Spin();
        Expect(presses.count == 1 && [name.stringValue isEqual:@"Raph"], @"Friends interface was operated");

        Expect([friends.identifier hasPrefix:SPDFMacAIAppControlsHiddenPrefix] &&
               [pane.identifier hasPrefix:SPDFMacAIAppControlsHiddenPrefix],
               @"the host adapter must mark the title button and its Settings pane");
        Expect(SPDFMacAIAppControlsHidesMenuItem(reset) && !SPDFMacAIAppControlsHidesView(search) &&
               SPDFMacAIAppControlsHidesView(alert.contentView.subviews.firstObject),
               @"the hidden-interface checks disagree with the listing");
        [reader close];
        [settings close];
        [alert close];
        [panel close];
    }
    puts("SPDFMacFriendsAppControlsTests passed");
    return 0;
}
