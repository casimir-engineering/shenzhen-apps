#import <Cocoa/Cocoa.h>

#import "SPDFMacTabStripGeometry.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacTabStripViewPrivate.h"
#import "SPDFMacWindowChrome.h"

@interface SPDFFakeTab : NSObject
@property(nonatomic, strong) SPDFTabGroup* group;
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* collectionVersionLabel;
@property(nonatomic) BOOL readOnly;
@property(nonatomic) BOOL unsavedPastedImage;
@property(nonatomic) BOOL missingFile;
@end

@implementation SPDFFakeTab
@end

// Fake "document view" standing in for the PDF page view / markdown canvas:
// the only view in the test window that accepts first responder by design.
@interface SPDFFakeDocumentView : NSView
@end

@implementation SPDFFakeDocumentView

- (BOOL)acceptsFirstResponder {
    return YES;
}

@end

@interface SPDFFakeTabReader : NSObject
@property(nonatomic) NSInteger newTabCount;
@property(nonatomic) NSInteger newGroupCount;
@property(nonatomic) NSInteger selectedTabIndex;
@property(nonatomic) NSInteger movedTabCount;
@property(nonatomic) NSInteger typeToSearchCalls;
@property(nonatomic, copy) NSString* lastTypeToSearch;
@property(nonatomic, weak) NSWindow* hostWindow;
@property(nonatomic, weak) NSView* tabStrip;
@property(nonatomic, weak) NSView* documentKeyView;
@end

@implementation SPDFFakeTabReader

- (void)newTabRequested:(id)sender {
    (void)sender;
    self.newTabCount += 1;
}

- (void)createEmptyTabGroupFromPlus:(id)sender {
    (void)sender;
    self.newGroupCount += 1;
}

- (void)selectTabAtIndex:(NSInteger)index {
    self.selectedTabIndex = index;
    // Mirror the app delegate's tab-activation chokepoint so these tests cover
    // the strip-click -> selection -> guarded focus-claim wiring end to end.
    [SPDFTabStripView claimFocusOnDocumentKeyView:self.documentKeyView
                                           window:self.hostWindow
                                         tabStrip:self.tabStrip
                                 parkedResponders:@[]];
}

- (void)moveTabFromIndex:(NSInteger)sourceIndex toIndex:(NSInteger)targetIndex {
    (void)sourceIndex;
    (void)targetIndex;
    self.movedTabCount += 1;
}

// Probe mirroring the production reader's type-to-search acceptance: printable,
// unmodified keys are consumed; Escape / Cmd-shortcuts are refused so the
// strip's keyDown falls through to super for them.
- (BOOL)documentTypeToSearchKeyDown:(NSEvent*)event {
    self.typeToSearchCalls += 1;
    if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption |
                               NSEventModifierFlagFunction))
        return NO;
    NSString* typed = event.characters ?: @"";
    if (typed.length == 0 || [typed rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return NO;
    self.lastTypeToSearch = typed;
    return YES;
}

@end

@interface SPDFChromeSpyWindow : NSWindow <SPDFWindowChromeHandling>
@property(nonatomic) NSInteger chromeEventCount;
@property(nonatomic) SPDFWindowChromeAction lastChromeAction;
@end

@implementation SPDFChromeSpyWindow

- (void)handleChromeMouseDown:(NSEvent*)event {
    self.chromeEventCount += 1;
    self.lastChromeAction = spdf_window_chrome_action(event.clickCount, NO, NO, NO);
}

@end

// Capture the actual menu from the production click path without entering a
// modal menu loop in the headless fixture.
@interface SPDFMenuSpyTabStrip : SPDFTabStripView
@property(nonatomic, strong) NSMenu* lastAddMenu;
@property(nonatomic) NSInteger addMenuCount;
@end
@implementation SPDFMenuSpyTabStrip
- (void)showNewTabOrGroupMenu {
    self.lastAddMenu = [self newTabOrGroupMenu];
    self.addMenuCount += 1;
}
@end

// The tab-strip implementation references these application helpers from
// paths unrelated to this focused interaction test. Small deterministic stubs
// keep the test linked to the production view without pulling in the app.
NSString* spdf_display_label_without_extension(NSString* label) {
    return label ?: @"";
}

NSString* spdf_display_name_for_path(NSString* path) {
    return path.lastPathComponent ?: @"";
}

NSArray<NSString*>* spdf_disambiguated_display_names_for_paths(NSArray<NSString*>* paths) {
    return paths;
}

NSDictionary* spdf_dictionary_from_tab(SPDFDocumentTab* tab, NSInteger sourceWindowNumber) {
    (void)tab;
    (void)sourceWindowNumber;
    return @{};
}

SPDFDocumentTab* spdf_tab_from_dictionary(NSDictionary* item) {
    (void)item;
    return nil;
}

void spdf_set_menu_item_system_symbol(NSMenuItem* item, NSString* symbolName) {
    (void)item;
    (void)symbolName;
}

static void expect_true(NSString* label, BOOL value) {
    if (value) return;
    NSLog(@"FAIL %@", label);
    exit(1);
}

static void expect_integer(NSString* label, NSInteger actual, NSInteger expected) {
    if (actual == expected) return;
    NSLog(@"FAIL %@: got %ld, expected %ld", label, (long)actual, (long)expected);
    exit(1);
}

static NSEvent* mouse_event(SPDFChromeSpyWindow* window, NSEventType type, NSPoint point, NSInteger clickCount) {
    return [NSEvent mouseEventWithType:type
                              location:point
                         modifierFlags:0
                             timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:window.windowNumber
                               context:nil
                           eventNumber:1
                            clickCount:clickCount
                              pressure:1.0];
}

static void dispatch(SPDFChromeSpyWindow* window, NSEventType type, NSPoint point, NSInteger clickCount) {
    [window sendEvent:mouse_event(window, type, point, clickCount)];
}

static NSEvent* key_event(SPDFChromeSpyWindow* window, NSString* characters, unsigned short keyCode,
                          NSEventModifierFlags modifierFlags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                            location:NSZeroPoint
                       modifierFlags:modifierFlags
                           timestamp:NSProcessInfo.processInfo.systemUptime
                        windowNumber:window.windowNumber
                             context:nil
                          characters:characters
         charactersIgnoringModifiers:characters
                           isARepeat:NO
                             keyCode:keyCode];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        SPDFChromeSpyWindow* window = [[SPDFChromeSpyWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 42)
                                                                             styleMask:NSWindowStyleMaskBorderless
                                                                               backing:NSBackingStoreBuffered
                                                                                 defer:NO];
        SPDFMenuSpyTabStrip* strip = [[SPDFMenuSpyTabStrip alloc] initWithFrame:window.contentView.bounds];
        strip.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        SPDFFakeTabReader* reader = [[SPDFFakeTabReader alloc] init];
        reader.selectedTabIndex = -1;
        SPDFFakeTab* tab = [[SPDFFakeTab alloc] init];
        tab.path = @"/tmp/alpha.pdf";
        tab.title = @"Alpha";
        SPDFFakeTab* secondTab = [[SPDFFakeTab alloc] init];
        secondTab.path = @"/tmp/beta.pdf";
        secondTab.title = @"Beta";
        strip.reader = (id)reader;
        strip.tabs = (id) @[ tab, secondTab ];
        strip.selectedIndex = 0;
        [window.contentView addSubview:strip];
        SPDFFakeDocumentView* documentView = [[SPDFFakeDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        [window.contentView addSubview:documentView];
        reader.hostWindow = window;
        reader.tabStrip = strip;
        reader.documentKeyView = documentView;
        [window orderFront:nil];
        [window makeKeyWindow];
        [window displayIfNeeded];

        NSPoint tabPoint = NSMakePoint(180, 21);
        NSPoint emptyPoint = NSMakePoint(820, 21);
        NSRect plusFrame = [strip plusRect];
        NSPoint plusPoint = NSMakePoint(NSMidX(plusFrame), NSMidY(plusFrame));
        expect_true(@"tab is an interactive hit region", [strip containsTabOrControlAtPoint:tabPoint]);
        expect_true(@"plus is an interactive hit region", [strip containsTabOrControlAtPoint:plusPoint]);
        expect_true(@"background is outside interactive hit regions", ![strip containsTabOrControlAtPoint:emptyPoint]);

        dispatch(window, NSEventTypeLeftMouseDown, tabPoint, 1);
        dispatch(window, NSEventTypeLeftMouseUp, tabPoint, 1);
        expect_integer(@"tab press selects the tab", reader.selectedTabIndex, 0);

        dispatch(window, NSEventTypeLeftMouseDown, tabPoint, 1);
        dispatch(window, NSEventTypeLeftMouseDragged, NSMakePoint(650, 21), 1);
        dispatch(window, NSEventTypeLeftMouseUp, NSMakePoint(650, 21), 1);
        expect_integer(@"tab remains reorderable", reader.movedTabCount, 1);
        expect_integer(@"tab gesture never enters window chrome", window.chromeEventCount, 0);

        expect_true(@"chooser is built lazily on demand", strip.lastAddMenu == nil && strip.addMenuCount == 0);
        dispatch(window, NSEventTypeLeftMouseDown, plusPoint, 1);
        expect_integer(@"plus opens the compact chooser", strip.addMenuCount, 1);
        expect_integer(@"plus does not immediately open a document", reader.newTabCount, 0);
        expect_integer(@"chooser has only the two requested actions", strip.lastAddMenu.numberOfItems, 2);
        NSMenuItem* newTab = [strip.lastAddMenu itemAtIndex:0];
        NSMenuItem* newGroup = [strip.lastAddMenu itemAtIndex:1];
        expect_true(@"New Tab uses existing open action", [newTab.title isEqualToString:@"New Tab"] &&
            newTab.target == reader && newTab.action == @selector(newTabRequested:));
        expect_true(@"New Group routes to empty-group action", [newGroup.title isEqualToString:@"New Group…"] &&
            newGroup.target == reader && newGroup.action == @selector(createEmptyTabGroupFromPlus:));
        [strip.lastAddMenu performActionForItemAtIndex:0];
        [strip.lastAddMenu performActionForItemAtIndex:1];
        expect_integer(@"New Tab calls reader once", reader.newTabCount, 1);
        expect_integer(@"New Group calls reader once", reader.newGroupCount, 1);
        for (NSAccessibilityElement* child in strip.accessibilityChildren) {
            if (![child.accessibilityLabel isEqualToString:@"New Tab or Group"]) continue;
            expect_true(@"plus has popup accessibility role", [child.accessibilityRole isEqualToString:NSAccessibilityPopUpButtonRole]);
            expect_true(@"accessible plus press opens chooser", [child accessibilityPerformPress]);
        }
        expect_integer(@"mouse and accessibility share chooser", strip.addMenuCount, 2);
        expect_integer(@"plus never enters window chrome", window.chromeEventCount, 0);

        dispatch(window, NSEventTypeLeftMouseDown, emptyPoint, 1);
        expect_integer(@"empty background forwards one event", window.chromeEventCount, 1);
        expect_integer(@"single background press starts native drag", window.lastChromeAction,
                       SPDFWindowChromeActionDrag);

        dispatch(window, NSEventTypeLeftMouseDown, emptyPoint, 2);
        expect_integer(@"double background press forwards once", window.chromeEventCount, 2);
        expect_integer(@"double background press uses native zoom", window.lastChromeAction,
                       SPDFWindowChromeActionZoom);

        // Focus after selection: a tab click must land keyboard focus on the
        // document view, so typing searches without a click in the preview.
        [window makeFirstResponder:nil];
        expect_true(@"window holds first responder before the click", window.firstResponder == window);
        dispatch(window, NSEventTypeLeftMouseDown, tabPoint, 1);
        dispatch(window, NSEventTypeLeftMouseUp, tabPoint, 1);
        expect_true(@"tab selection focuses the document view", window.firstResponder == documentView);

        // The guard: a deliberately focused text editor (the find field's field
        // editor in the app) keeps first responder across a tab selection.
        NSTextView* textEditor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 60, 20)];
        [window.contentView addSubview:textEditor];
        expect_true(@"text editor takes first responder", [window makeFirstResponder:textEditor]);
        dispatch(window, NSEventTypeLeftMouseDown, tabPoint, 1);
        dispatch(window, NSEventTypeLeftMouseUp, tabPoint, 1);
        expect_true(@"tab selection never steals focus from a text editor", window.firstResponder == textEditor);
        expect_true(@"guarded claim refuses while a text editor is focused",
                    ![SPDFTabStripView claimFocusOnDocumentKeyView:documentView
                                                            window:window
                                                          tabStrip:strip
                                                  parkedResponders:@[]]);

        // A parked responder (the delegate lists the outgoing page/scroll view)
        // does give way to the claim.
        SPDFFakeDocumentView* parkedView = [[SPDFFakeDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        [window.contentView addSubview:parkedView];
        expect_true(@"parked view takes first responder", [window makeFirstResponder:parkedView]);
        expect_true(@"claim moves focus from a parked responder",
                    [SPDFTabStripView claimFocusOnDocumentKeyView:documentView
                                                           window:window
                                                         tabStrip:strip
                                                 parkedResponders:@[ parkedView ]]);
        expect_true(@"document view holds focus after the claim", window.firstResponder == documentView);

        // WHY THE REOPEN FIX NEEDED A SECOND RULE. The tab-activation claim
        // yields only from {nil, window, tab strip, parked}. Reopening a
        // Markdown document (Cmd+Shift+T) leaves first responder on none of
        // those -- the outgoing session's canvas, a sidebar row, a toolbar
        // control -- so re-running that claim when the load completed refused,
        // and the reopened document still could not be typed into. This pins
        // the refusal, so the load-time rule cannot be "simplified" back into
        // the tab-activation one.
        SPDFFakeDocumentView* staleHolder = [[SPDFFakeDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        [window.contentView addSubview:staleHolder];
        expect_true(@"a stale non-parked view can hold first responder", [window makeFirstResponder:staleHolder]);
        expect_true(@"the tab-activation claim REFUSES a stale non-parked holder",
                    ![SPDFTabStripView claimFocusOnDocumentKeyView:documentView
                                                            window:window
                                                          tabStrip:strip
                                                  parkedResponders:@[]]);
        expect_true(@"so focus stays stuck on the stale holder", window.firstResponder == staleHolder);

        // The load-time rule (-focusMarkdownViewAfterLoad) yields to anything
        // that is not a live text edit. Same predicate, asserted here so the
        // reader's copy and this expectation cannot drift apart.
        expect_true(@"a stale holder is not a text edit, so the load rule takes focus",
                    ![window.firstResponder isKindOfClass:NSText.class] &&
                        [window makeFirstResponder:documentView] && window.firstResponder == documentView);
        expect_true(@"a focused field editor IS a text edit, so the load rule stands off",
                    [window makeFirstResponder:textEditor] &&
                        [window.firstResponder isKindOfClass:NSText.class]);

        // Belt-and-braces keyDown forwarding: a printable key over the strip
        // reaches the type-to-search hook; Escape and Cmd shortcuts fall
        // through to super (the probe mirrors the production reader's filter).
        NSInteger callsBefore = reader.typeToSearchCalls;
        [strip keyDown:key_event(window, @"a", 0, 0)];
        expect_integer(@"printable key over the strip reaches type-to-search", reader.typeToSearchCalls,
                       callsBefore + 1);
        expect_true(@"printable key carries its characters", [reader.lastTypeToSearch isEqualToString:@"a"]);
        [strip keyDown:key_event(window, @"\033", 53, 0)];
        expect_true(@"escape is not consumed as a search", [reader.lastTypeToSearch isEqualToString:@"a"]);
        [strip keyDown:key_event(window, @"f", 3, NSEventModifierFlagCommand)];
        expect_true(@"cmd shortcuts are not consumed as a search", [reader.lastTypeToSearch isEqualToString:@"a"]);
    }
    return 0;
}
