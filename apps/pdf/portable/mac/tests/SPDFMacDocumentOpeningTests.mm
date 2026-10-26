#import "SPDFMacDocumentOpening.h"
#import "SPDFMacOpenRouting.h"
#import "SPDFMacTabGroupIntegration.h"
#include <unistd.h>

// The production open path (SPDFMacDocumentOpening.mm) and group category run on
// a headless delegate. Document loading, persistence and window activation are
// recorded instead of performed; no app, window or other process is touched.
extern "C" BOOL spdf_is_sandboxed(void) { return NO; }
void spdf_launch_profile_log(NSString* format, ...) { (void)format; }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ShenzhenMacDelegate
@end
#pragma clang diagnostic pop

@interface OpenProbe : ShenzhenMacDelegate
@property(nonatomic) NSMutableDictionary* workspace;
@property(nonatomic) NSInteger activations, focusCount, stripRefreshes, loads;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* otherWindows;
@property(nonatomic) NSMutableArray<NSArray*>* handOffs;
@property(nonatomic) NSMutableArray<NSDictionary*>* requests, *confirmations;
@property(nonatomic) NSMutableArray<NSArray*>* navigations;
@property(nonatomic) NSArray<NSString*>* opened; // what activityDidOpenPaths: heard (last opened)
- (void)seed:(NSArray*)tabs selected:(NSInteger)index;
- (NSArray<SPDFDocumentTab*>*)tabs;
- (NSInteger)selectedIndex;
@end
@implementation OpenProbe
- (void)seed:(NSArray*)tabs selected:(NSInteger)index {
    _tabs = [tabs mutableCopy]; _selectedTabIndex = index; _uiReady = YES;
    _window = (NSWindow*)[NSObject new]; // openPaths only needs a built window, never draws it
    _path = index >= 0 ? _tabs[(NSUInteger)index].path : nil;
    _pendingOpenPaths = [NSMutableArray array];
    self.otherWindows = [NSMutableDictionary dictionary]; self.handOffs = [NSMutableArray array];
    self.requests = [NSMutableArray array]; self.confirmations = [NSMutableArray array];
    self.navigations = [NSMutableArray array];
}
- (NSArray<SPDFDocumentTab*>*)tabs { return _tabs; }
- (NSInteger)selectedIndex { return _selectedTabIndex; }
- (void)performWithBatchedPersistentStateSaves:(void (^)(void))block {
    _suspendPersistentStateSaves = YES; block(); _suspendPersistentStateSaves = NO;
}
- (void)rememberActiveTabState {}
- (void)collectionWillOpenPaths:(NSArray*)paths { (void)paths; }
- (void)activityDidOpenPaths:(NSArray*)paths { self.opened = [(self.opened ?: @[]) arrayByAddingObjectsFromArray:paths]; }
- (void)activityStartTracking {}
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
- (void)loadSelectedTab { self.loads++; _path = [self selectedTab].path; }
- (void)ensureActiveMarkdownTabHasContent {}
- (void)collectionDidOpenPath:(NSString*)path { (void)path; }
- (void)aiDocumentDidOpen:(NSString*)path { (void)path; }
- (void)rememberRecentlyOpenedPath:(NSString*)path { (void)path; }
- (void)focusActiveDocumentViewAfterTabSelection { self.focusCount++; }
// Mirrors the coordinator: selection expands the selected tab's group (it never unhides one).
- (void)selectTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) return;
    if (index != _selectedTabIndex || [self hasActiveDocument])
        spdf_tab_groups_activate(_tabs, _tabs[(NSUInteger)index]);
    [self updateTabStrip];
    if (index == _selectedTabIndex && [self hasActiveDocument]) {
        [self focusActiveDocumentViewAfterTabSelection];
        return;
    }
    _selectedTabIndex = index; [self normalizeTabGroups]; [self loadSelectedTab];
    [self focusActiveDocumentViewAfterTabSelection];
}
- (void)savePersistentState {}
- (void)updateTabStrip { self.stripRefreshes++; }
- (void)refreshSidebarWorkspacePanel {}
- (void)collectionRememberGroups {}
- (NSMutableDictionary*)sidebarWorkspaceState {
    if (!self.workspace) self.workspace = [NSMutableDictionary dictionary];
    return self.workspace;
}
- (void)activateWindowForExternalOpen { self.activations++; }
- (BOOL)canOpenDocumentAtPath:(NSString*)path showError:(BOOL)showError { (void)showError; return path.length > 0; }
- (NSArray<NSString*>*)openableDocumentPathsFromPaths:(NSArray<NSString*>*)paths showErrors:(BOOL)showErrors {
    (void)showErrors; return paths;
}
- (pid_t)otherWindowProcessShowingPath:(NSString*)path { return (pid_t)self.otherWindows[path].intValue; }
// The real hand-off runs; only delivery to the other process is recorded.
- (BOOL)sendShowDocumentRequest:(NSDictionary*)userInfo toProcess:(pid_t)pid {
    [self.handOffs addObject:@[userInfo[@"path"], @(pid)]]; [self.requests addObject:userInfo];
    return YES;
}
- (void)sendShowDocumentConfirmation:(NSDictionary*)userInfo { [self.confirmations addObject:userInfo]; }
- (void)listenForDocumentsOpenedInOtherWindows {}
- (NSTimeInterval)showDocumentHandOffTimeout { return 0.05; }
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page {
    [self.navigations addObject:@[path, @(page)]];
    return @{};
}
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

// Two groups; the active document is in Research, and the reader is browsing Drawings.
static OpenProbe* BrowsingProbe(SPDFTabGroup** research, SPDFTabGroup** drawings, SPDFTabGroup** archive) {
    *research = [SPDFTabGroup groupWithColor:@"Blue"]; (*research).name = @"Research";
    *drawings = [SPDFTabGroup groupWithColor:@"Green"]; (*drawings).name = @"Drawings";
    *archive = [SPDFTabGroup groupWithColor:@"Red"]; (*archive).name = @"Archive";
    OpenProbe* reader = [OpenProbe new];
    [reader seed:@[Tab(@"/docs/a.pdf", *research), Tab(@"/docs/b.pdf", *research), Tab(@"/docs/c.pdf", *drawings),
                   Tab(@"/docs/d.pdf", *archive)] selected:0];
    (*research).collapsed = YES; (*drawings).collapsed = NO; (*archive).collapsed = YES; (*archive).hidden = YES;
    return reader;
}

static void CheckReopenShowsTheRightGroup(void) {
    SPDFTabGroup *research, *drawings, *archive;
    OpenProbe* reader = BrowsingProbe(&research, &drawings, &archive);
    NSInteger strip = reader.stripRefreshes;
    [reader application:NSApp openFiles:@[@"/docs/a.pdf"]];
    Expect(@"reopening the active document from Finder brings its group back to the strip",
           !research.collapsed && drawings.collapsed && archive.collapsed);
    Expect(@"the reopened document stays selected, focused and its window comes forward",
           reader.selectedIndex == 0 && reader.focusCount > 0 && reader.activations == 1);
    Expect(@"the strip redraws to show the document's group", reader.stripRefreshes > strip);
    Expect(@"reopening never adds a duplicate tab", reader.tabs.count == 4);
    Expect(@"reopening a document whose tab is open still counts as opening it (last opened)",
           [reader.opened isEqual:@[@"/docs/a.pdf"]]);

    reader = BrowsingProbe(&research, &drawings, &archive);
    [reader application:NSApp openFile:@"/docs/d.pdf"];
    Expect(@"a background tab in a hidden group is selected", reader.selectedIndex == 3 && reader.loads == 1);
    Expect(@"its hidden group is shown and expanded, the others folded",
           !archive.hidden && !archive.collapsed && research.collapsed && drawings.collapsed);
    Expect(@"the window is brought forward once", reader.activations == 1);

    reader = BrowsingProbe(&research, &drawings, &archive);
    [reader showDocumentsAtPaths:@[@"/docs/c.pdf"]];
    Expect(@"a document in the group being browsed is selected", reader.selectedIndex == 2 && !drawings.collapsed);

    reader = BrowsingProbe(&research, &drawings, &archive);
    [reader showDocumentsAtPaths:@[@"/docs/new.pdf"]];
    SPDFDocumentTab* added = reader.selectedIndex >= 0 ? reader.tabs[(NSUInteger)reader.selectedIndex] : nil;
    Expect(@"a new document opens selected in the active document's group, which is expanded",
           [added.path isEqual:@"/docs/new.pdf"] && added.group == research && !research.collapsed
           && drawings.collapsed);

    reader = BrowsingProbe(&research, &drawings, &archive);
    NSMenuItem* recent = [NSMenuItem new]; recent.representedObject = @"/docs/d.pdf";
    [reader openRecentDocument:recent];
    Expect(@"Open Recent selects the existing tab and brings its window forward",
           reader.selectedIndex == 3 && !archive.hidden && reader.activations == 1);
}

static void CheckOtherWindows(void) {
    SPDFTabGroup *research, *drawings, *archive;
    OpenProbe* reader = BrowsingProbe(&research, &drawings, &archive);
    reader.otherWindows[@"/docs/elsewhere.pdf"] = @4242;
    reader.otherWindows[@"/docs/a.pdf"] = @4243; // also shown elsewhere, but open here
    [reader showDocumentsAtPaths:@[@"/docs/elsewhere.pdf"]];
    Expect(@"a document another window shows is handed to that window",
           reader.handOffs.count == 1 && [reader.handOffs[0][0] isEqual:@"/docs/elsewhere.pdf"]
           && [reader.handOffs[0][1] intValue] == 4242);
    Expect(@"no duplicate opens here and this window does not take the front",
           reader.tabs.count == 4 && reader.activations == 0);
    [reader showDocumentsAtPaths:@[@"/docs/a.pdf", @"/docs/elsewhere.pdf", @"/docs/fresh.pdf"]];
    Expect(@"a document open here stays here; a new one opens here",
           reader.handOffs.count == 2 && reader.tabs.count == 5 && reader.activations == 1);

    reader = BrowsingProbe(&research, &drawings, &archive);
    [reader handleShowDocumentRequest:@{@"pid" : @(getpid() + 1), @"path" : @"/docs/d.pdf"}];
    Expect(@"a request for another window is ignored", reader.selectedIndex == 0 && reader.activations == 0);
    [reader handleShowDocumentRequest:@{@"pid" : @(getpid()), @"path" : @"/docs/x.spdf-command"}];
    Expect(@"command files never arrive this way", reader.tabs.count == 4 && reader.activations == 0);
    [reader handleShowDocumentRequest:@{@"pid" : @(getpid()), @"path" : @"/docs/d.pdf"}];
    Expect(@"a request from another window selects the tab in its group and comes forward",
           reader.selectedIndex == 3 && !archive.hidden && !archive.collapsed && reader.activations == 1);
}

static void Settle(void) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]]; }

// A chat link to a page of a document another window shows: that window goes to
// the page, and the document opens here when that window never answers.
static void CheckHandOffKeepsThePage(void) {
    SPDFTabGroup *research, *drawings, *archive;
    OpenProbe* reader = BrowsingProbe(&research, &drawings, &archive);
    reader.otherWindows[@"/docs/elsewhere.pdf"] = @4242;
    [reader showDocumentAtPath:@"/docs/elsewhere.pdf" page:@3];
    NSDictionary* request = reader.requests.firstObject;
    Expect(@"the hand-off carries the linked page",
           reader.requests.count == 1 && [request[@"page"] isEqual:@3] && [request[@"from"] intValue] == getpid());
    [reader handleShowDocumentConfirmation:@{@"pid" : @(getpid()), @"request" : request[@"request"] ?: @""}];
    Settle();
    Expect(@"once the other window answers, nothing opens here",
           reader.tabs.count == 4 && reader.activations == 0 && !reader.navigations.count);

    reader = BrowsingProbe(&research, &drawings, &archive);
    reader.otherWindows[@"/docs/elsewhere.pdf"] = @4242;
    [reader showDocumentAtPath:@"/docs/elsewhere.pdf" page:@3];
    request = reader.requests.firstObject;
    [reader handleShowDocumentConfirmation:@{@"pid" : @(getpid() + 1), @"request" : request[@"request"] ?: @""}];
    Settle();
    SPDFDocumentTab* selected = reader.tabs[(NSUInteger)reader.selectedIndex];
    Expect(@"with no answer, the document opens here at the linked page",
           reader.tabs.count == 5 && [selected.path isEqual:@"/docs/elsewhere.pdf"] && reader.activations == 1
           && [reader.navigations.firstObject isEqual:(@[@"/docs/elsewhere.pdf", @3])]);

    reader = BrowsingProbe(&research, &drawings, &archive);
    [reader handleShowDocumentRequest:@{@"pid" : @(getpid()), @"path" : @"/docs/d.pdf", @"page" : @7,
                                        @"from" : @4242, @"request" : @"r1"}];
    Expect(@"the owning window answers the window that asked",
           [reader.confirmations.firstObject isEqual:(@{@"pid" : @4242, @"request" : @"r1"})]);
    Expect(@"the owning window shows the linked page",
           reader.selectedIndex == 3 && [reader.navigations.firstObject isEqual:(@[@"/docs/d.pdf", @7])]
           && reader.activations == 1);
    reader = BrowsingProbe(&research, &drawings, &archive);
    [reader handleShowDocumentRequest:@{@"pid" : @(getpid()), @"path" : @"/docs/d.pdf", @"page" : @"x"}];
    Expect(@"a malformed page still shows the document", reader.selectedIndex == 3 && !reader.navigations.count);
    Expect(@"pages are positive whole numbers",
           !SPDFMacShowDocumentRequestPage(@{@"page" : @0}) && !SPDFMacShowDocumentRequestPage(@{@"page" : @1.5})
           && [SPDFMacShowDocumentRequestPage(@{@"page" : @2}) isEqual:@2]);
}

static void CheckSessionOwner(void) {
    NSDictionary* session = @{@"windows" : @[
        @{@"pid" : @10, @"tabs" : @[@{@"path" : @"/docs/a.pdf"}]},                       // this process
        @{@"pid" : @20, @"tabs" : @[@{@"path" : @"/docs/a.pdf"}], @"focusedAt" : @90},    // quit, still saved
        @{@"pid" : @30, @"tabs" : @[@{@"path" : @"/docs/./a.pdf"}], @"focusedAt" : @50},
        @{@"pid" : @40, @"tabs" : @[@{@"path" : @"/docs/a.pdf"}], @"focusedAt" : @70},
        @{@"tabs" : @[@{@"path" : @"/docs/b.pdf"}]},                                    // older version, no pid
        @"malformed"]};
    BOOL (^running)(pid_t) = ^BOOL(pid_t pid) { return pid == 30 || pid == 40; };
    Expect(@"the most recently focused running window showing the document owns it",
           SPDFMacOtherWindowShowingPath(session, @"/docs/a.pdf", 10, running) == 40);
    Expect(@"a window without a running process never owns a document",
           SPDFMacOtherWindowShowingPath(session, @"/docs/b.pdf", 10, running) == 0);
    Expect(@"this process is never its own owner",
           SPDFMacOtherWindowShowingPath(session, @"/docs/a.pdf", 10, ^BOOL(pid_t pid) { return pid == 10; }) == 0);
    Expect(@"unknown documents and malformed sessions have no owner",
           SPDFMacOtherWindowShowingPath(session, @"/docs/z.pdf", 10, running) == 0
           && SPDFMacOtherWindowShowingPath(@"bad", @"/docs/a.pdf", 10, running) == 0);
    Expect(@"requests carry only absolute document paths",
           SPDFMacShowDocumentRequestPath(@{@"pid" : @5, @"path" : @"relative.pdf"}, 5) == nil
           && [SPDFMacShowDocumentRequestPath(@{@"pid" : @5, @"path" : @"/a.pdf"}, 5) isEqual:@"/a.pdf"]);
}

static void CheckSourceContracts(void) {
    NSString* dir = @(__FILE__).stringByDeletingLastPathComponent;
    NSString* (^read)(NSString*) = ^NSString*(NSString* name) {
        return [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:name]
                                         encoding:NSUTF8StringEncoding error:nil] ?: @"";
    };
    NSString* coordinator = read(@"../ShenzhenPDFMac.mm");
    Expect(@"the other-window listener starts after the first paint, not on the launch path",
           [coordinator containsString:@"[self showUnifiedSettingsAfterFirstPaint];\n"
                                        "                       [self listenForDocumentsOpenedInOtherWindows];"]);
    Expect(@"each window records the process that shows it", [coordinator containsString:@"@\"pid\" : @(getpid())"]);
    NSRange load = [coordinator rangeOfString:@"- (void)loadSelectedTab {"];
    NSString* loading = load.location == NSNotFound ? @"" :
        [coordinator substringWithRange:NSMakeRange(load.location, MIN((NSUInteger)1200, coordinator.length - load.location))];
    Expect(@"every tab load reports to the activity tracker (last opened, the tab in front)",
           [loading containsString:@"[self activityTabDidLoad:tab];"]);
    Expect(@"a closing tab tells the tracker the tab in front may change",
           [coordinator containsString:@"[_closedDocumentPaths addObject:[path copy]]; [self activityDocumentWillClose];"]);
    NSString* opening = read(@"../SPDFMacDocumentOpening.mm");
    NSRange listen = [opening rangeOfString:@"- (void)listenForDocumentsOpenedInOtherWindows {\n"];
    Expect(@"view tracking starts with the other-window listener, after the first paint",
           listen.location != NSNotFound && [[opening substringFromIndex:NSMaxRange(listen)]
               hasPrefix:@"    [self activityStartTracking];"]);
    NSString* browsing = read(@"../SPDFMacFileBrowsing.mm");
    Expect(@"Open... and Open Path bring the document's tab forward",
           [browsing componentsSeparatedByString:@"[self showDocumentsAtPaths:"].count == 3);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        CheckReopenShowsTheRightGroup();
        CheckOtherWindows();
        CheckHandOffKeepsThePage();
        CheckSessionOwner();
        CheckSourceContracts();
    }
    if (!failures) puts("SPDFMacDocumentOpeningTests passed");
    return failures ? 1 : 0;
}
