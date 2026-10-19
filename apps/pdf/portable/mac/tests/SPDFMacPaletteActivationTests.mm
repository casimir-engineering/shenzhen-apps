#import "SPDFMacPaletteActivation.h"
#import "SPDFMacCollectionPaletteModel.h"
#import "SPDFMacDocumentOpening.h"
#import "SPDFMacTabGroupIntegration.h"
#include <unistd.h>

// What Return, Cmd+Return, the arrow keys and a click do in the Cmd+K palette,
// on a headless reader running the production palette and open paths. Chat,
// document loading and window activation are recorded instead of performed; no
// window is shown and no other process is touched.
extern "C" BOOL spdf_is_sandboxed(void) { return NO; }
void spdf_launch_profile_log(NSString* format, ...) { (void)format; }
static NSMutableArray<ShenzhenMacDelegate*>* gControllers;
NSArray<ShenzhenMacDelegate*>* SPDFMacAllWindowControllers(void) { return gControllers ?: @[]; }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ShenzhenMacDelegate
@end
#pragma clang diagnostic pop

@interface ClickTable : NSTableView
@property(nonatomic) NSInteger fixtureClickedRow;
@end
@implementation ClickTable
- (NSInteger)clickedRow { return self.fixtureClickedRow; }
@end
// The table shows whatever the palette holds, as the reader's own data source does.
@interface PaletteSource : NSObject <NSTableViewDataSource>
@property(nonatomic, copy) NSArray* (^rows)(void);
@end
@implementation PaletteSource
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return (NSInteger)self.rows().count; }
- (id)tableView:(NSTableView*)table objectValueForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table; (void)column; return self.rows()[(NSUInteger)row][@"title"];
}
@end

@interface PaletteProbe : ShenzhenMacDelegate
@property(nonatomic) NSMutableArray<NSString*>* chats;
@property(nonatomic) NSInteger activations, closes, scrolledRow;
@property(nonatomic) PaletteSource* source;
- (void)seedTabs:(NSArray*)tabs selected:(NSInteger)index;
- (void)showRows:(NSArray*)rows highlighted:(NSInteger)row query:(NSString*)query;
- (ClickTable*)table;
- (NSSearchField*)field;
- (NSArray<SPDFDocumentTab*>*)tabs;
- (NSInteger)selectedIndex;
@end
@implementation PaletteProbe
- (void)seedTabs:(NSArray*)tabs selected:(NSInteger)index {
    _tabs = [tabs mutableCopy]; _selectedTabIndex = index; _uiReady = YES;
    _window = (NSWindow*)[NSObject new]; // openPaths only needs a built window, never draws it
    _path = index >= 0 ? _tabs[(NSUInteger)index].path : nil;
    _pendingOpenPaths = [NSMutableArray array];
    self.chats = [NSMutableArray array];
}
- (void)showRows:(NSArray*)rows highlighted:(NSInteger)row query:(NSString*)query {
    if (!_paletteTable) {
        _paletteTable = [[ClickTable alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
        [_paletteTable addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"result"]];
        NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 500, 120)];
        scroll.documentView = _paletteTable; // four rows tall: a page is three rows
        _paletteTable.rowHeight = 28;
        self.source = [PaletteSource new];
        __weak PaletteProbe* weakSelf = self;
        self.source.rows = ^NSArray* { PaletteProbe* probe = weakSelf; return probe ? probe->_paletteResults : @[]; };
        _paletteTable.dataSource = self.source;
        _paletteSearchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 0, 400, 30)];
    }
    _paletteMode = 1; // as Cmd+K opens it
    _paletteResults = [rows mutableCopy];
    [_paletteTable reloadData];
    NSIndexSet* highlight = row >= 0 ? [NSIndexSet indexSetWithIndex:(NSUInteger)row] : [NSIndexSet indexSet];
    [_paletteTable selectRowIndexes:highlight byExtendingSelection:NO];
    [self paletteForgetHighlightMove]; // fresh results, as each search starts
    _paletteSearchField.stringValue = query ?: @"";
    self.table.fixtureClickedRow = -1;
}
- (ClickTable*)table { return (ClickTable*)_paletteTable; }
- (NSSearchField*)field { return _paletteSearchField; }
- (NSArray<SPDFDocumentTab*>*)tabs { return _tabs; }
- (NSInteger)selectedIndex { return _selectedTabIndex; }
// Palette and chat seams.
- (void)showAIChat:(id)sender { (void)sender; [self.chats addObject:@""]; }
- (void)showAIChatForQuery:(NSString*)query { [self.chats addObject:query ?: @""]; }
- (void)closePalette:(id)sender { (void)sender; self.closes++; }
- (void)cancelCollectionPaletteSearch {}
- (BOOL)openCollectionPaletteResult:(NSDictionary*)result { (void)result; return NO; }
- (void)scrollPaletteRowToVisibleWithHeader:(NSInteger)row {
    self.scrolledRow = row; [_paletteTable scrollRowToVisible:row];
}
- (void)updatePalettePanelFramePreservingTop:(BOOL)preserveTop { (void)preserveTop; }
// Rows are as tall as they say ("height"), else the table's own row height.
- (CGFloat)paletteHeightForRow:(NSInteger)row {
    BOOL known = row >= 0 && row < (NSInteger)_paletteResults.count;
    NSNumber* height = known ? _paletteResults[(NSUInteger)row][@"height"] : nil;
    return height ? height.doubleValue : _paletteTable.rowHeight;
}
// The production open path's seams, as in SPDFMacDocumentOpeningTests.
- (void)performWithBatchedPersistentStateSaves:(void (^)(void))block {
    _suspendPersistentStateSaves = YES; block(); _suspendPersistentStateSaves = NO;
}
- (void)rememberActiveTabState {}
- (void)collectionWillOpenPaths:(NSArray*)paths { (void)paths; }
- (void)captureSecurityBookmarkForPath:(NSString*)path { (void)path; }
- (NSInteger)indexOfTabForPath:(NSString*)path {
    for (NSUInteger i = 0; i < _tabs.count; ++i)
        if ([_tabs[i].path.stringByStandardizingPath isEqualToString:path.stringByStandardizingPath])
            return (NSInteger)i;
    return -1;
}
- (SPDFDocumentTab*)newTabForPath:(NSString*)path {
    SPDFDocumentTab* tab = [SPDFDocumentTab new]; tab.path = path; tab.title = path.lastPathComponent; return tab;
}
- (BOOL)hasActiveDocument { return _path.length > 0; }
- (SPDFDocumentTab*)selectedTab {
    BOOL valid = _selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count;
    return valid ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
}
- (void)loadSelectedTab { _path = [self selectedTab].path; }
- (void)ensureActiveMarkdownTabHasContent {}
- (void)collectionDidOpenPath:(NSString*)path { (void)path; }
- (void)aiDocumentDidOpen:(NSString*)path { (void)path; }
- (void)rememberRecentlyOpenedPath:(NSString*)path { (void)path; }
- (void)focusActiveDocumentViewAfterTabSelection {}
- (void)selectTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) return;
    if (index != _selectedTabIndex || [self hasActiveDocument])
        spdf_tab_groups_activate(_tabs, _tabs[(NSUInteger)index]);
    if (index == _selectedTabIndex && [self hasActiveDocument]) return;
    _selectedTabIndex = index; [self normalizeTabGroups]; [self loadSelectedTab];
}
- (void)savePersistentState {}
- (void)updateTabStrip {}
- (void)refreshSidebarWorkspacePanel {}
- (void)collectionRememberGroups {}
- (NSMutableDictionary*)sidebarWorkspaceState { return [NSMutableDictionary dictionary]; }
- (void)activateWindowForExternalOpen { self.activations++; }
- (pid_t)otherWindowProcessShowingPath:(NSString*)path { (void)path; return 0; }
- (void)listenForDocumentsOpenedInOtherWindows {}
@end

static int failures;
static void Expect(NSString* label, BOOL condition) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); ++failures; }
}
static SPDFDocumentTab* Tab(NSString* path, SPDFTabGroup* group) {
    SPDFDocumentTab* tab = [SPDFDocumentTab new];
    tab.path = path; tab.title = path.lastPathComponent; tab.group = group;
    return tab;
}
static NSEvent* Key(unsigned short code, NSString* characters, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
                        windowNumber:0 context:nil characters:characters charactersIgnoringModifiers:characters
                           isARepeat:NO keyCode:code];
}
static NSEvent* Return(NSEventModifierFlags flags) { return Key(36, @"\r", flags); }
static NSEvent* Press(NSEventType type, NSPoint location) {
    return [NSEvent mouseEventWithType:type location:location modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                           eventNumber:0 clickCount:1 pressure:1];
}

// The palette as the owner saw it: the chat row first, then open documents.
static NSArray* EmptySearchRows(void) {
    return @[spdf_collection_palette_chat_row(@""), @{@"kind" : @"header", @"title" : @"Open documents"},
             @{@"kind" : @"openDoc", @"title" : @"Sample50-4B_DS_2.0_A", @"path" : @"/docs/a.pdf"},
             @{@"kind" : @"openDoc", @"title" : @"Sample_Before_vs_After_4_Images", @"path" : @"/docs/c.pdf"},
             @{@"kind" : @"header", @"title" : @"Actions"},
             @{@"kind" : @"addDoc", @"title" : @"Favorite current document"}];
}

static PaletteProbe* Reader(SPDFTabGroup** drawings) {
    SPDFTabGroup* research = [SPDFTabGroup groupWithColor:@"Blue"]; research.name = @"Research";
    *drawings = [SPDFTabGroup groupWithColor:@"Green"]; (*drawings).name = @"Drawings";
    PaletteProbe* reader = [PaletteProbe new];
    [reader seedTabs:@[Tab(@"/docs/a.pdf", research), Tab(@"/docs/b.pdf", research), Tab(@"/docs/c.pdf", *drawings)]
            selected:1];
    (*drawings).collapsed = YES; (*drawings).hidden = YES;
    gControllers = [NSMutableArray arrayWithObject:reader];
    return reader;
}

static void CheckReturnOpensTheHighlightedDocument(void) {
    SPDFTabGroup* drawings;
    PaletteProbe* reader = Reader(&drawings);
    [reader showRows:EmptySearchRows() highlighted:3 query:@""];
    [reader activatePaletteSelection:nil];
    Expect(@"Return on an empty search opens the highlighted document, not a chat",
           reader.chats.count == 0 && reader.selectedIndex == 2 && reader.closes == 1);
    Expect(@"the document's tab comes forward in its own group, which was hidden and collapsed",
           !drawings.hidden && !drawings.collapsed && reader.activations == 1);

    [reader showRows:EmptySearchRows() highlighted:3 query:@""];
    Expect(@"the Return key goes through the same choice",
           [reader paletteHandleKeyEvent:Return(0)] && reader.chats.count == 0 && reader.closes == 2);

    [reader showRows:EmptySearchRows() highlighted:0 query:@""];
    [reader paletteHandleKeyEvent:Return(0)];
    Expect(@"Return on the chat row, highlighted on an empty search, opens the chat",
           reader.chats.count == 1 && [reader.chats.lastObject isEqualToString:@""]);

    [reader showRows:@[@{@"kind" : @"status", @"title" : @"Searching…"}] highlighted:-1 query:@"col: torque"];
    Expect(@"Return while the list only says it is searching does nothing",
           [reader paletteHandleKeyEvent:Return(0)] && reader.chats.count == 1 && reader.closes == 2);
    [reader showRows:@[@{@"kind" : @"status", @"title" : @"No matches"}] highlighted:-1 query:@"col: torque"];
    [reader activatePaletteSelection:nil];
    Expect(@"Return with no matches does nothing", reader.chats.count == 1 && reader.closes == 2);
    [reader paletteHandleKeyEvent:Return(NSEventModifierFlagCommand)];
    Expect(@"Cmd+Return still opens the chat there", reader.chats.count == 2);
}

static void CheckCommandReturnAndClicks(void) {
    SPDFTabGroup* drawings;
    PaletteProbe* reader = Reader(&drawings);
    NSArray* rows = @[@{@"kind" : @"header", @"title" : @"Open documents"},
                      @{@"kind" : @"openDoc", @"title" : @"c", @"path" : @"/docs/c.pdf"},
                      spdf_collection_palette_chat_row(@"torque curve")];
    [reader showRows:rows highlighted:1 query:@"  torque curve "];
    [reader paletteHandleKeyEvent:Return(NSEventModifierFlagCommand)];
    Expect(@"Cmd+Return starts the chat from the typed text alone, without opening the row",
           reader.chats.count == 1 && [reader.chats[0] isEqualToString:@"  torque curve "] &&
               reader.selectedIndex == 1);

    [reader showRows:rows highlighted:1 query:@"torque"];
    reader.table.fixtureClickedRow = 0;
    [reader activatePaletteSelection:reader.table];
    Expect(@"a click on a heading does not open the highlighted row", reader.selectedIndex == 1 && reader.closes == 0);
    reader.table.fixtureClickedRow = -1;
    [reader activatePaletteSelection:reader.table];
    Expect(@"a click below the rows opens nothing", reader.selectedIndex == 1 && reader.chats.count == 1);
    reader.table.fixtureClickedRow = 1;
    [reader activatePaletteSelection:reader.table];
    Expect(@"a click on a document opens it", reader.selectedIndex == 2 && reader.closes == 1);
}

static void CheckMovementKeys(void) {
    SPDFTabGroup* drawings;
    PaletteProbe* reader = Reader(&drawings);
    NSArray* rows = EmptySearchRows();
    [reader showRows:rows highlighted:0 query:@""];
    [reader paletteHandleKeyEvent:Key(125, @"", 0)];
    Expect(@"down skips the heading", reader.table.selectedRow == 2);
    [reader paletteHandleKeyEvent:Key(119, @"", 0)];
    Expect(@"End highlights the last row", reader.table.selectedRow == 5);
    [reader paletteHandleKeyEvent:Key(125, @"", 0)];
    Expect(@"down from the last row wraps to the first", reader.table.selectedRow == 0);
    [reader paletteHandleKeyEvent:Key(121, @"", 0)];
    Expect(@"Page Down moves a page, past the heading", reader.table.selectedRow == 3);
    [reader paletteHandleKeyEvent:Key(121, @"", 0)];
    [reader paletteHandleKeyEvent:Key(121, @"", 0)];
    Expect(@"Page Down stops at the last row", reader.table.selectedRow == 5);
    [reader paletteHandleKeyEvent:Key(115, @"", 0)];
    Expect(@"Home highlights the first row", reader.table.selectedRow == 0);
    Expect(@"ordinary typing stays with the search field", ![reader paletteHandleKeyEvent:Key(0, @"a", 0)]);
    [reader paletteHandleKeyEvent:Key(53, @"\x1b", 0)];
    Expect(@"Escape closes the palette", reader.closes == 1);

    // Rows with a second line are taller: a page is what fits, not a count of standard rows.
    NSMutableArray* tall = [NSMutableArray arrayWithObjects:@{@"kind" : @"askAI", @"title" : @"Chat", @"height" : @28},
                                                            @{@"kind" : @"header", @"title" : @"Open", @"height" : @24},
                                                            nil];
    for (NSString* name in @[@"a", @"b", @"c", @"d", @"e"])
        [tall addObject:@{@"kind" : @"openDoc", @"title" : name, @"path" : name, @"height" : @50}];
    [reader showRows:tall highlighted:0 query:@""];
    [reader paletteHandleKeyEvent:Key(121, @"", 0)];
    Expect(@"Page Down moves by the rows that fit at their own heights", reader.table.selectedRow == 2);
    [reader paletteHandleKeyEvent:Key(121, @"", 0)];
    Expect(@"where only one more tall row fits, a page is that row", reader.table.selectedRow == 3);
    [reader paletteHandleKeyEvent:Key(116, @"", 0)];
    Expect(@"Page Up steps back the same way", reader.table.selectedRow == 2);
}

static void CheckHighlightMoves(void) {
    SPDFTabGroup* drawings;
    PaletteProbe* reader = Reader(&drawings);
    [reader showRows:EmptySearchRows() highlighted:0 query:@""];
    Expect(@"new results start with the highlight on the first row, not moved",
           ![reader paletteHighlightMovedByPerson]);
    [reader paletteHandleKeyEvent:Key(125, @"", 0)];
    Expect(@"an arrow key moves the highlight", [reader paletteHighlightMovedByPerson]);
    [reader paletteForgetHighlightMove];
    [reader paletteHandleKeyEvent:Key(119, @"", 0)];
    Expect(@"End moves it", [reader paletteHighlightMovedByPerson]);
    [reader paletteForgetHighlightMove];
    [reader paletteHandleKeyEvent:Key(121, @"", 0)];
    Expect(@"a page moves it", [reader paletteHighlightMovedByPerson]);
    [reader paletteForgetHighlightMove];
    NSRect heading = [reader.table rectOfRow:1];
    [reader paletteNoteClickAt:[reader.table convertPoint:NSMakePoint(NSMidX(heading), NSMidY(heading)) toView:nil]];
    Expect(@"a press on a heading does not", ![reader paletteHighlightMovedByPerson]);
    NSRect document = [reader.table rectOfRow:3];
    NSPoint onDocument = [reader.table convertPoint:NSMakePoint(NSMidX(document), NSMidY(document)) toView:nil];
    [reader paletteNoteMouseDown:Press(NSEventTypeRightMouseDown, onDocument)];
    [reader paletteNoteMouseDown:Press(NSEventTypeOtherMouseDown, onDocument)];
    Expect(@"a right or middle press on a row does not", ![reader paletteHighlightMovedByPerson]);
    [reader paletteNoteMouseDown:Press(NSEventTypeLeftMouseDown, onDocument)];
    Expect(@"a left press on a row does", [reader paletteHighlightMovedByPerson]);
}

// Results arriving while the palette is open: the highlight follows the best match
// until the person moves it, then stays on their row wherever it lands.
static void CheckArrivingResults(void) {
    SPDFTabGroup* drawings;
    PaletteProbe* reader = Reader(&drawings);
    NSArray* rows = EmptySearchRows();
    // c lands after another choosable row, so staying on it differs from following the best match.
    NSArray* later = @[rows[1], rows[2], rows[3], rows[0], rows[4], rows[5]];
    [reader showRows:rows highlighted:0 query:@""];
    [reader applyPaletteRows:later];
    Expect(@"an untouched highlight goes to the first row that can be chosen",
           reader.table.selectedRow == 1 && reader.scrolledRow == 1);
    [reader showRows:rows highlighted:0 query:@""];
    [reader paletteHandleKeyEvent:Key(125, @"", 0)];
    [reader paletteHandleKeyEvent:Key(125, @"", 0)];
    Expect(@"fixture: the person moved the highlight to c", reader.table.selectedRow == 3);
    [reader applyPaletteRows:later];
    Expect(@"a moved highlight stays on its row where the new results put it",
           reader.table.selectedRow == 2 && reader.scrolledRow == 2);
    [reader showRows:rows highlighted:0 query:@""];
    NSRect c = [reader.table rectOfRow:3];
    [reader paletteNoteMouseDown:Press(NSEventTypeRightMouseDown,
                                       [reader.table convertPoint:NSMakePoint(NSMidX(c), NSMidY(c)) toView:nil])];
    [reader applyPaletteRows:later];
    Expect(@"a right click leaves the highlight following the best match", reader.table.selectedRow == 1);
    reader.scrolledRow = -1;
    [reader applyPaletteRows:@[]];
    Expect(@"no results show No matches with nothing highlighted",
           reader.table.selectedRow == -1 && reader.scrolledRow == -1 && reader.table.numberOfRows == 1);
}

static void CheckInputMethodComposition(void) {
    SPDFTabGroup* drawings;
    PaletteProbe* reader = Reader(&drawings);
    [reader showRows:EmptySearchRows() highlighted:3 query:@""];
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 60) styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    [window.contentView addSubview:reader.field];
    [window makeFirstResponder:reader.field];
    NSTextView* editor = (NSTextView*)reader.field.currentEditor;
    [editor setMarkedText:@"zhong" selectedRange:NSMakeRange(5, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    Expect(@"fixture composes text in the search field", editor.hasMarkedText);
    BOOL handled = [reader paletteHandleKeyEvent:Return(0)] || [reader paletteHandleKeyEvent:Key(125, @"", 0)] ||
                   [reader paletteHandleKeyEvent:Key(53, @"\x1b", 0)];
    Expect(@"while pinyin is being composed, Return, arrows and Escape belong to the input method",
           !handled && reader.selectedIndex == 1 && reader.closes == 0 && reader.table.selectedRow == 3);
    [editor unmarkText];
    Expect(@"once composed, Return opens the highlighted row again", [reader paletteHandleKeyEvent:Return(0)] &&
           reader.selectedIndex == 2);
    Expect(@"headless input-method check never shows a window", !window.visible);
    [window close];
}

static void CheckOtherWindowOwnsTheDocument(void) {
    SPDFTabGroup *drawings, *otherDrawings;
    PaletteProbe* reader = Reader(&drawings);
    PaletteProbe* other = Reader(&otherDrawings);
    [other seedTabs:@[Tab(@"/docs/x.pdf", nil), Tab(@"/docs/elsewhere.pdf", otherDrawings)] selected:0];
    gControllers = [NSMutableArray arrayWithObjects:other, reader, nil];
    [reader showRows:@[@{@"kind" : @"openDoc", @"title" : @"elsewhere", @"path" : @"/docs/elsewhere.pdf"}]
         highlighted:0 query:@""];
    [reader activatePaletteSelection:nil];
    Expect(@"a document another window shows comes forward there, in its group, without a duplicate tab here",
           other.selectedIndex == 1 && !otherDrawings.hidden && other.activations == 1 && reader.tabs.count == 3);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        CheckReturnOpensTheHighlightedDocument();
        CheckCommandReturnAndClicks();
        CheckMovementKeys();
        CheckHighlightMoves();
        CheckArrivingResults();
        CheckInputMethodComposition();
        CheckOtherWindowOwnsTheDocument();
    }
    if (!failures) printf("SPDFMacPaletteActivationTests passed\n");
    return failures ? 1 : 0;
}
