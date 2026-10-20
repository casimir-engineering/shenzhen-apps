// Cmd+J and Cmd+K for Friends on the real reader: the reader's own delegate, main menu and window (no document open),
// the real Friends views and client library, and the protocol area's in-process fake helper in a temporary
// SZFRIENDS_STATE_DIR (never the real helper, its state or the Keychain).
//
//   Friends off: no Friends items in the menu or in Cmd+K, and Cmd+J does nothing.
//   Friends attached: Cmd+J (a key event through -[NSApplication sendEvent:], so the main menu's key equivalents
//   run as for a key press) opens the dropdown with its search field focused and closes it again, also while that
//   field has focus; Cmd+K, typing "friends" and Return opens it; "friend", "nearby", "add by id" and "chat" list
//   Open Friends; Add by ID… and Make Myself Visible land where they say; the button's tooltip shows ⌘J.
//   Detached again: everything is gone.
//
// No window is ever seen: every window AppKit orders in is made fully transparent and click-through first, and the
// app's activation policy is Prohibited, so it never activates, takes focus or shows in the Dock. Because such an
// app has no key window, NSApp hands key equivalents straight to the main menu; the probe therefore first asks the
// window that would be key (the reader's, or the dropdown's while its field has focus) to perform the key
// equivalent, as AppKit does, and checks that it passes it on. Letters typed into Cmd+K go to the palette's window
// (-[NSWindow sendEvent:]), which is where AppKit sends them; Return goes through NSApp like Cmd+J.
//
// Run from portable/: make -f Makefile -f mac/tests/friends-shortcut-probe.mk mac-friends-shortcut-probe

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacPalettePresentation.h"
#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacFriendsMenu.h"
#import "mac/SZFriendsDropdownInternal.h"
#include "client/szfriends_client.h"
#include "client/fake/szfriends_fake_helper.h"
#import <objc/runtime.h>

static NSUInteger failures;
static void Check(BOOL ok, NSString* message) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        failures++;
    }
}

static BOOL RunUntil(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return done();
}

static void Settle(NSTimeInterval seconds) { RunUntil(seconds, ^BOOL { return NO; }); }

#pragma mark - Windows nobody sees

static IMP gOriginalOrder;
static NSUInteger gOrderedIn;
// Every window ordered in is transparent and ignores the mouse before it reaches the window server.
static void TransparentOrder(NSWindow* window, SEL selector, NSInteger place, NSInteger other) {
    if (place != NSWindowOut) {
        window.alphaValue = 0;
        window.ignoresMouseEvents = YES;
        if (NSMaxX(window.frame) > -1000) [window setFrameOrigin:NSMakePoint(-10000 - NSWidth(window.frame), -10000)];
        gOrderedIn++;
    }
    ((void (*)(id, SEL, NSInteger, NSInteger))gOriginalOrder)(window, selector, place, other);
}
static NSRect Unconstrained(id object, SEL selector, NSRect frame, NSScreen* screen) {
    (void)object, (void)selector, (void)screen;
    return frame;
}
static void InstallWindowGuards(void) {
    gOriginalOrder = method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:)),
                                              (IMP)TransparentOrder);
    method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(constrainFrameRect:toScreen:)),
                             (IMP)Unconstrained);
}
static void CheckNothingSeen(void) {
    for (NSWindow* window in NSApp.windows)
        Check(!window.visible || window.alphaValue == 0, [NSString stringWithFormat:@"%@ stayed transparent",
                                                          NSStringFromClass(window.class)]);
    NSArray* info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary* window in info)
        if ([window[(id)kCGWindowOwnerPID] intValue] == getpid())
            Check([window[(id)kCGWindowAlpha] doubleValue] == 0, @"no window of the probe is visible on screen");
}

#pragma mark - Events

static unsigned short KeyCode(unichar c) {
    static const char* const keys = "asdfhgzxcv\0bqweryt";
    for (unsigned short i = 0; i < 18; i++) if (keys[i] == c) return i;
    switch (c) {
        case 'o': return 31; case 'u': return 32; case 'i': return 34; case 'p': return 35; case 'l': return 37;
        case 'j': return 38; case 'k': return 40; case 'n': return 45; case 'm': return 46; case ' ': return 49;
        default: return 0;
    }
}

static NSEvent* KeyDown(NSString* characters, unsigned short code, NSEventModifierFlags flags, NSWindow* window) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
                           timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                             context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO
                             keyCode:code];
}

// A shortcut pressed while `keyWindow` would be key: AppKit offers it to that window's views first, then to the
// main menu (here through -[NSApplication sendEvent:]). NO when a view in the window kept it.
static BOOL PressShortcut(NSString* key, NSWindow* keyWindow) {
    NSEvent* event = KeyDown(key, KeyCode([key characterAtIndex:0]), NSEventModifierFlagCommand, keyWindow);
    if ([keyWindow performKeyEquivalent:event]) return NO;
    [NSApp sendEvent:event];
    return YES;
}

#pragma mark - The reader

@interface ShenzhenMacDelegate (FriendsShortcutProbeAccess)
- (void)buildWindow;
- (void)buildMenu;
- (void)friendsAttach;
- (void)friendsDetachDisabling:(BOOL)disabling;
- (void)closePalette:(id)sender;
@end

@interface FriendsShortcutReader : ShenzhenMacDelegate
- (void)prepareEmptyWindow;
- (NSWindow*)window;
- (NSPanel*)palette;
- (NSSearchField*)paletteField;
- (NSArray<NSDictionary*>*)paletteRows;
- (NSInteger)paletteSelectedRow;
@end

@implementation FriendsShortcutReader
// Disk boundaries, as in the workspace probe: nothing here writes the reader's state.
- (void)savePersistentState {}
- (void)persistActiveState {}
- (void)rememberActiveTabState {}
- (void)prepareEmptyWindow {
    _tabs = [NSMutableArray array];
    _selectedTabIndex = -1; _zoom = 1; _fitMode = SPDFFitModeWidth; _markdownFontScale = 1;
    _sidebarWidth = 240; _minimapWidth = 112;
    _restoredWindowContentSize = NSMakeSize(1100, 760);
    _renderedPages = [NSMutableArray array]; _sidebarItems = [NSMutableArray array];
    _findMatches = [NSMutableArray array]; _findHighlights = [NSMutableDictionary dictionary];
    _findMatchIndex = -1; _findQueue = [NSOperationQueue new];
    // What -applicationDidFinishLaunching: allocates for the palette, which the probe never runs.
    _paletteResults = [NSMutableArray array]; _favorites = [NSMutableArray array];
    _recentlyOpenedPaths = [NSMutableArray array]; _closedDocumentPaths = [NSMutableArray array];
    _documentStates = [NSMutableDictionary dictionary];
    [self buildWindow];
    _uiReady = YES;
    [_window setContentSize:NSMakeSize(1100, 760)];
    [_window orderWindow:NSWindowAbove relativeTo:0];
    [_window.contentView layoutSubtreeIfNeeded];
}
- (NSWindow*)window { return _window; }
- (NSPanel*)palette { return _palettePanel; }
- (NSSearchField*)paletteField { return _paletteSearchField; }
- (NSArray<NSDictionary*>*)paletteRows { return [_paletteResults copy] ?: @[]; }
- (NSInteger)paletteSelectedRow { return _paletteTable.selectedRow; }
@end

static NSArray<NSString*>* PaletteCommandTitles(FriendsShortcutReader* reader) {
    return [[reader paletteMenuCommandCandidates] valueForKey:@"title"];
}

static NSMenuItem* FriendsItem(NSString* identifier) {
    NSMenu* view = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
    for (NSMenuItem* item in view.itemArray) {
        if ([item.identifier isEqualToString:identifier]) return item;
        for (NSMenuItem* inner in item.submenu.itemArray)
            if ([inner.identifier isEqualToString:identifier]) return inner;
    }
    return nil;
}

// The search field, or the field editor typing into it.
static BOOL SearchFieldHasFocus(SZFriendsDropdownController* dropdown) {
    if (!dropdown.shown || dropdown.currentView != SZFriendsDropdownViewList) return NO;
    NSSearchField* search = dropdown.content.listPage.searchField;
    NSResponder* responder = search.window.firstResponder;
    if (responder == search) return YES;
    return [responder isKindOfClass:NSTextView.class] && ((NSTextView*)responder).isFieldEditor &&
        ((NSTextView*)responder).delegate == (id)search;
}

static NSInteger RowTitled(NSArray<NSDictionary*>* rows, NSString* title) {
    for (NSUInteger i = 0; i < rows.count; i++)
        if ([rows[i][@"title"] isEqual:title]) return (NSInteger)i;
    return -1;
}

static BOOL Searching(NSArray<NSDictionary*>* rows) {
    for (NSDictionary* row in rows) if ([row[@"kind"] isEqual:@"status"]) return YES;
    return NO;
}

// Cmd+K, then `query` typed into the palette's field; returns once the rows stop changing.
static NSArray<NSDictionary*>* TypeInPalette(FriendsShortcutReader* reader, NSString* query) {
    if (!reader.palette.visible) Check(PressShortcut(@"k", reader.window), @"the reader passes Cmd+K on to the menu");
    Check(RunUntil(2, ^BOOL { return reader.palette.visible; }), @"Cmd+K opens the palette");
    reader.paletteField.stringValue = @"";
    [reader.palette makeFirstResponder:reader.paletteField];
    for (NSUInteger i = 0; i < query.length; i++) {
        NSString* character = [query substringWithRange:NSMakeRange(i, 1)];
        [reader.palette sendEvent:KeyDown(character, KeyCode([character characterAtIndex:0]), 0, reader.palette)];
    }
    Check([reader.paletteField.stringValue isEqualToString:query],
          [NSString stringWithFormat:@"typing reached the palette field (\"%@\")", reader.paletteField.stringValue]);
    RunUntil(5, ^BOOL { return !Searching(reader.paletteRows); });
    Settle(0.2);
    return reader.paletteRows;
}

static void PressInPalette(FriendsShortcutReader* reader, NSString* characters, unsigned short code) {
    [NSApp sendEvent:KeyDown(characters, code, 0, reader.palette)];
}

#pragma mark - Checks

static void CheckFriendsOff(FriendsShortcutReader* reader, NSString* when) {
    NSArray* titles = PaletteCommandTitles(reader);
    for (NSString* title in @[ SPDFMacFriendsOpenTitle, SPDFMacFriendsCloseTitle, SPDFMacFriendsAddByIDTitle,
                               SPDFMacFriendsVisibleTitle, SPDFMacFriendsSettingsTitle ])
        Check(![titles containsObject:title], [NSString stringWithFormat:@"%@: Cmd+K has no %@", when, title]);
    Check(!FriendsItem(SPDFMacFriendsMenuItemIdentifier), [NSString stringWithFormat:@"%@: no View ▸ Friends", when]);
    Check(PressShortcut(@"j", reader.window) && ![reader friendsState].dropdown.shown,
          [NSString stringWithFormat:@"%@: Cmd+J does nothing", when]);
}

static void CheckCommandJ(FriendsShortcutReader* reader) {
    SZFriendsDropdownController* dropdown = [reader friendsState].dropdown;
    NSButton* button = dropdown.button;
    Check(button.window == reader.window, @"the Friends button is in the reader window's title bar");
    Check(!dropdown.shown, @"the dropdown starts closed");
    NSMenuItem* open = FriendsItem(SPDFMacFriendsOpenItemIdentifier);
    Check([open.keyEquivalent isEqualToString:@"j"] && open.keyEquivalentModifierMask == NSEventModifierFlagCommand,
          @"View ▸ Friends ▸ Open Friends shows ⌘J");
    NSUInteger holders = 0;
    for (NSMenuItem* top in NSApp.mainMenu.itemArray)
        for (NSMenuItem* item in top.submenu.itemArray) {
            if ([item.keyEquivalent isEqualToString:@"j"] && item.keyEquivalentModifierMask == NSEventModifierFlagCommand)
                holders++;
            for (NSMenuItem* inner in item.submenu.itemArray)
                if ([inner.keyEquivalent isEqualToString:@"j"] &&
                    inner.keyEquivalentModifierMask == NSEventModifierFlagCommand)
                    holders++;
        }
    Check(holders == 1, [NSString stringWithFormat:@"exactly one menu item owns ⌘J (%lu)", (unsigned long)holders]);

    Check(PressShortcut(@"j", reader.window), @"the reader window passes Cmd+J on to the menu");
    Check(RunUntil(2, ^BOOL { return dropdown.shown; }), @"Cmd+J opens Friends");
    Check(RunUntil(2, ^BOOL { return SearchFieldHasFocus(dropdown); }),
          [NSString stringWithFormat:@"the search field has focus when Friends opens (first responder %@)",
                                     dropdown.content.window.firstResponder]);
    [open.menu update];
    Check([open.title isEqualToString:SPDFMacFriendsCloseTitle], @"the item reads Close Friends while it is open");

    NSWindow* popover = dropdown.content.window;
    Check(PressShortcut(@"j", popover), @"the dropdown's search field passes Cmd+J on to the menu");
    Check(RunUntil(2, ^BOOL { return !dropdown.shown; }), @"Cmd+J closes Friends while its search field has focus");
    [open.menu update];
    Check([open.title isEqualToString:SPDFMacFriendsOpenTitle], @"the item reads Open Friends again");

    Check(PressShortcut(@"j", reader.window) && RunUntil(2, ^BOOL { return dropdown.shown; }) &&
              RunUntil(2, ^BOOL { return SearchFieldHasFocus(dropdown); }),
          @"Cmd+J opens Friends again, on the search field");
    Check(PressShortcut(@"j", reader.window) && RunUntil(2, ^BOOL { return !dropdown.shown; }),
          @"Cmd+J from the reader window closes it");
}

static void CheckPalette(FriendsShortcutReader* reader) {
    SZFriendsDropdownController* dropdown = [reader friendsState].dropdown;
    NSArray* titles = PaletteCommandTitles(reader);
    for (NSString* title in @[ SPDFMacFriendsOpenTitle, SPDFMacFriendsAddByIDTitle, SPDFMacFriendsVisibleTitle,
                               SPDFMacFriendsSettingsTitle ])
        Check([titles containsObject:title], [NSString stringWithFormat:@"with no document open, Cmd+K offers %@", title]);

    NSArray* rows = TypeInPalette(reader, @"friends");
    NSInteger row = RowTitled(rows, SPDFMacFriendsOpenTitle);
    Check(row >= 0, [NSString stringWithFormat:@"\"friends\" lists Open Friends: %@", [rows valueForKey:@"title"]]);
    Check(row >= 0 && reader.paletteSelectedRow == row,
          [NSString stringWithFormat:@"Open Friends is the highlighted row (row %ld of %@)",
                                     (long)reader.paletteSelectedRow, [rows valueForKey:@"title"]]);
    PressInPalette(reader, @"\r", 36);
    Check(RunUntil(2, ^BOOL { return dropdown.shown; }), @"Return on Open Friends opens Friends");
    // Open Friends, not a message row: the list with its search field, not a conversation.
    Check(RunUntil(2, ^BOOL { return SearchFieldHasFocus(dropdown); }), @"Return ran Open Friends: the list, searching");
    Check(!reader.palette.visible, @"the palette closed");
    Check(PressShortcut(@"j", dropdown.content.window) && RunUntil(2, ^BOOL { return !dropdown.shown; }),
          @"Cmd+J closes what the palette opened");

    for (NSString* query in @[ @"friend", @"nearby", @"add by id", @"chat" ]) {
        rows = TypeInPalette(reader, query);
        Check(RowTitled(rows, SPDFMacFriendsOpenTitle) >= 0,
              [NSString stringWithFormat:@"\"%@\" lists Open Friends: %@", query, [rows valueForKey:@"title"]]);
    }
    Check(RowTitled(rows, SPDFMacFriendsSettingsTitle) < 0, @"\"chat\" does not list Friends Settings");
    rows = TypeInPalette(reader, @"add by id");
    Check(RowTitled(rows, SPDFMacFriendsAddByIDTitle) >= 0, @"\"add by id\" lists Add by ID…");
    rows = TypeInPalette(reader, @"visible");
    Check(RowTitled(rows, SPDFMacFriendsVisibleTitle) >= 0, @"\"visible\" lists Make Myself Visible");
    PressInPalette(reader, @"\x1b", 53);
    Check(RunUntil(2, ^BOOL { return !reader.palette.visible; }), @"Escape closes the palette");
}

static size_t FramesOfType(szfriends_fake_helper* fake, const char* type) {
    size_t count = 0;
    NSString* needle = [NSString stringWithFormat:@"\"type\":\"%s\"", type];
    for (size_t i = 0; i < szfriends_fake_helper_frame_count(fake); i++) {
        char* frame = szfriends_fake_helper_copy_frame(fake, i);
        if (frame && strstr(frame, needle.UTF8String)) count++;
        free(frame);
    }
    return count;
}

static void CheckOtherItems(FriendsShortcutReader* reader, szfriends_fake_helper* fake) {
    SZFriendsDropdownController* dropdown = [reader friendsState].dropdown;
    NSMenuItem* add = FriendsItem(SPDFMacFriendsAddByIDItemIdentifier);
    Check([NSApp sendAction:add.action to:add.target from:add], @"Add by ID… runs");
    Check(RunUntil(2, ^BOOL { return dropdown.shown && dropdown.currentView == SZFriendsDropdownViewProfile; }),
          @"Add by ID… opens the profile page, where Add by ID is");
    NSResponder* responder = dropdown.content.window.firstResponder;
    Check([responder isKindOfClass:NSTextView.class] && ((NSTextView*)responder).isFieldEditor,
          @"the ID field has focus");
    [dropdown close];

    size_t before = FramesOfType(fake, "start_visibility");
    NSMenuItem* visible = FriendsItem(SPDFMacFriendsVisibleItemIdentifier);
    Check([(id<NSMenuItemValidation>)visible.target validateMenuItem:visible], @"Make Myself Visible is available");
    Check([NSApp sendAction:visible.action to:visible.target from:visible], @"Make Myself Visible runs");
    Check(RunUntil(2, ^BOOL { return dropdown.shown && dropdown.content.listPage.showingNearby; }),
          @"Make Myself Visible opens the Nearby tab");
    Check(RunUntil(3, ^BOOL { return FramesOfType(fake, "start_visibility") == before + 1; }),
          @"Make Myself Visible asks Friends to be visible, once");
    [dropdown close];

    NSMenuItem* settings = FriendsItem(SPDFMacFriendsSettingsItemIdentifier);
    Check(settings && [(id<NSMenuItemValidation>)settings.target validateMenuItem:settings],
          @"Friends Settings… is available");
}

static void CheckToolTip(FriendsShortcutReader* reader) {
    NSButton* button = [reader friendsState].dropdown.button;
    Check(RunUntil(5, ^BOOL { return [button.toolTip isEqualToString:@"Friends · ⌘J"]; }),
          [NSString stringWithFormat:@"the Friends button's tooltip shows the shortcut (%@)", button.toolTip]);
    button.toolTip = @"Friends"; // what the views set again on every badge update
    Check([button.toolTip isEqualToString:@"Friends · ⌘J"], @"the shortcut comes back after the views reset it");
}

#pragma mark - Main

static BOOL RemoveSocketFallback(NSString* state) {
    char path[1024];
    bool fallback = false;
    if (szfriends_socket_path(state.fileSystemRepresentation, path, sizeof path, &fallback) != SZFRIENDS_OK ||
        !fallback)
        return YES;
    NSString* folder = [@(path) stringByDeletingLastPathComponent];
    if (![folder.lastPathComponent hasPrefix:@"szfriends-"]) return NO;
    [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    return ![NSFileManager.defaultManager fileExistsAtPath:folder];
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"spdf-friends-shortcut-%d-%@", getpid(), NSUUID.UUID.UUIDString]];
        NSString* friendsState = [root stringByAppendingPathComponent:@"friends"];
        [NSFileManager.defaultManager createDirectoryAtPath:friendsState withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions : @0700} error:nil];
        setenv("SPDF_STATE_DIR", root.fileSystemRepresentation, 1);
        setenv("SPDF_NO_WINDOW_FIRST", "1", 1);
        setenv("SZFRIENDS_STATE_DIR", friendsState.fileSystemRepresentation, 1);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        InstallWindowGuards();

        szfriends_fake_helper_config config = {};
        config.state_dir = friendsState.fileSystemRepresentation;
        config.fixtures_dir = "friends/fixtures";
        szfriends_fake_helper* fake = NULL;
        if (szfriends_fake_helper_start(&config, &fake) != SZFRIENDS_OK || !fake) {
            fprintf(stderr, "FAIL: the fake helper did not start (run from portable/)\n");
            return 1;
        }

        FriendsShortcutReader* reader = [FriendsShortcutReader new];
        NSApp.delegate = reader;
        [reader buildMenu];
        [reader prepareEmptyWindow];
        Check(reader.window.contentView != nil, @"the reader window is built");

        CheckFriendsOff(reader, @"before Friends attaches");
        [reader friendsAttach];
        SPDFMacFriendsReaderState* state = [reader friendsState];
        Check(RunUntil(5, ^BOOL { return state.link.state == SZFriendsLinkStateReady && state.placement != nil; }),
              [NSString stringWithFormat:@"Friends attaches to the fake helper (link %ld, button %@)",
                                         (long)state.link.state, state.placement]);
        if (state.placement) {
            CheckToolTip(reader);
            CheckCommandJ(reader);
            CheckPalette(reader);
            CheckOtherItems(reader, fake);
        }
        [reader friendsDetachDisabling:NO];
        CheckFriendsOff(reader, @"after Friends detaches");
        CheckNothingSeen();
        Check(gOrderedIn > 0, @"the probe really ordered its windows in");

        [reader closePalette:nil];
        [reader.window orderOut:nil];
        szfriends_fake_helper_stop(fake);
        Check(RemoveSocketFallback(friendsState), @"the fake helper's socket folder is removed");
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        if (!failures) puts("SPDFMacFriendsShortcutProbe passed");
    }
    return failures ? 1 : 0;
}
