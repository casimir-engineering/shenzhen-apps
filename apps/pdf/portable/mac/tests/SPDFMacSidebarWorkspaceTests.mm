#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacGroupManagement.h"
#include "spdf_yaml.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ShenzhenMacDelegate
@end
#pragma clang diagnostic pop
@interface ShenzhenMacDelegate (WorkspaceTesting)
- (NSArray*)sidebarGroupSnapshots;
- (void)performSidebarGroupAction:(NSString*)action identifier:(NSString*)identifier value:(NSString*)value;
@end
@interface WorkspaceScrollProbe : NSObject
@property CGFloat tabScrollOffset;
@property(copy) void (^tabScrollDidChange)(CGFloat);
@end
@implementation WorkspaceScrollProbe
@end
@interface WorkspaceProbe : ShenzhenMacDelegate
@property NSInteger saves;
@property NSInteger collectionPanelChecks;
@property NSInteger snapshotCount;
- (void)seed:(NSArray*)tabs;
- (WorkspaceScrollProbe*)createScrollProbe;
- (NSArray*)tabs;
- (NSControl*)navigation;
- (CGFloat)sidebarWidth;
- (void)preferSidebarVisible:(BOOL)visible;
@end
@implementation WorkspaceProbe
- (BOOL)showAIChatSidebarIfSelected {return NO;}
- (void)collectionRememberGroups {}
- (WorkspaceScrollProbe*)createScrollProbe {
    WorkspaceScrollProbe* probe=[WorkspaceScrollProbe new]; _tabStrip=(id)probe; return probe;
}
- (void)seed:(NSArray*)tabs {
    _tabs = tabs.mutableCopy; _selectedTabIndex = tabs.count ? 0 : -1;
    _sidebarWidth = 284; _sidebarPreferredVisible = YES;
    _sidebarContainer = [[NSView alloc] initWithFrame:NSMakeRect(0,0,284,700)];
    _sidebarModeControl = [SPDFSidebarNavigationControl new];
    spdf_sidebar_mode_control_configure_history(_sidebarModeControl,NO,NO,YES);
    [_sidebarContainer addSubview:_sidebarModeControl];
    _sidebarModeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[_sidebarModeControl.topAnchor constraintEqualToAnchor:_sidebarContainer.topAnchor],
        [_sidebarModeControl.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor],
        [_sidebarModeControl.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor]]];
}
- (NSArray*)tabs { return _tabs; }
- (NSControl*)navigation { return _sidebarModeControl; }
- (CGFloat)sidebarWidth { return _sidebarWidth; }
- (void)preferSidebarVisible:(BOOL)visible { _sidebarPreferredVisible=visible; }
- (NSArray*)sidebarGroupSnapshots { self.snapshotCount++; return [super sidebarGroupSnapshots]; }
- (SPDFDocumentTab*)selectedTab { return _selectedTabIndex >= 0 ? _tabs[_selectedTabIndex] : nil; }
- (void)savePersistentState { self.saves++; }
- (void)updateTabStrip {}
- (void)rebuildSidebar { [self showSidebarWorkspacePanel]; }
- (void)rememberActiveTabState {}
- (void)selectTabAtIndex:(NSInteger)index { _selectedTabIndex = index; _sidebarPreferredVisible = _tabs[index].showSidebar; [self activateSelectedTabGroup]; }
- (BOOL)hasSearchSidebar { return NO; }
- (BOOL)collectionShowSelectedHistoryPanel { self.collectionPanelChecks++; return NO; }
- (void)setSidebarActuallyVisible:(BOOL)visible { _sidebarVisible = visible; }
- (void)restoreSidebarWidth {}
@end
static int failures;
static void Check(BOOL ok,NSString* message) { if (!ok) { fprintf(stderr,"FAIL %s\n",message.UTF8String); failures++; } }
static SPDFDocumentTab* Tab(NSString* name) {
    SPDFDocumentTab* tab = [SPDFDocumentTab new]; tab.path = [@"/tmp/" stringByAppendingString:name]; tab.title = name;
    tab.pageIndex = 7; tab.scrollOrigin = NSMakePoint(0,132); tab.hasScrollOrigin = YES; return tab;
}
static NSDictionary* YAML(NSDictionary* value) {
    NSData* json = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    NSString* text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    char* encoded = spdf_yaml_from_json(text.UTF8String,"sidebar session");
    Check(encoded != NULL,@"session serializes to YAML"); if (!encoded) return @{};
    char* decoded = spdf_json_from_yaml(encoded); free(encoded);
    Check(decoded != NULL,@"session parses from YAML"); if (!decoded) return @{};
    NSDictionary* result = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:decoded length:strlen(decoded)] options:0 error:nil];
    free(decoded); return result;
}
static void CheckDocumentMoveIntegration(void) {
    for (NSNumber* sourceFirst in @[@NO,@YES]) {
        WorkspaceProbe* reader=[WorkspaceProbe new];
        SPDFTabGroup* other=[SPDFTabGroup groupWithColor:@"Blue"];
        SPDFTabGroup* source=[SPDFTabGroup groupWithColor:@"Purple"];
        SPDFTabGroup* destination=[SPDFTabGroup groupWithColor:@"Coral"]; destination.hidden=YES;
        SPDFDocumentTab* duplicate=Tab(@"Shared.pdf"); duplicate.group=other;
        SPDFDocumentTab* moved=Tab(@"Shared.pdf"); moved.group=source;
        SPDFDocumentTab* peer=Tab(@"Source peer.pdf"); peer.group=source;
        SPDFDocumentTab* first=Tab(@"Destination first.pdf"); first.group=destination;
        SPDFDocumentTab* last=Tab(@"Destination last.pdf"); last.group=destination;
        [reader seed:sourceFirst.boolValue ? @[duplicate,moved,peer,first,last] : @[duplicate,first,last,moved,peer]];
        [reader performSidebarGroupAction:@"document" identifier:source.identifier value:moved.path];
        Check(reader.selectedTab==moved,@"Groups document activation disambiguates duplicate paths using the clicked group");
        NSData* payload=[NSJSONSerialization dataWithJSONObject:@{@"source":source.identifier,@"path":moved.path} options:0 error:nil];
        [reader performSidebarGroupAction:@"move-document" identifier:destination.identifier
            value:[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]];
        NSArray* members=spdf_tab_group_members(reader.tabs,destination);
        Check([members isEqual:@[first,last,moved]] && duplicate.group==other && peer.group==source,
            @"production Groups drop resolves duplicate path by source group and inserts at target tail in both directions");
        Check(reader.selectedTab==moved && !destination.hidden && reader.saves>0 &&
            reader.navigation.spdf_selectedSidebarMode==SPDFSidebarModeGroups,
            @"production Groups drop reveals destination, selects moved document, persists and retains manager mode");
        NSMutableArray* snapshots=[NSMutableArray array];
        for (SPDFDocumentTab* tab in reader.tabs) [snapshots addObject:spdf_dictionary_from_tab(tab,0)];
        NSDictionary* session=YAML(@{@"tabs":snapshots,@"sidebar":reader.sidebarWorkspaceSnapshot});
        NSMutableArray* restored=[NSMutableArray array];
        for (NSDictionary* snapshot in session[@"tabs"]) [restored addObject:spdf_tab_from_dictionary(snapshot)];
        spdf_tab_groups_normalize(restored);
        NSUInteger movedIndex=[reader.tabs indexOfObjectIdenticalTo:moved];
        SPDFDocumentTab* restoredMove=restored[movedIndex];
        Check([restoredMove.group.identifier isEqual:destination.identifier] &&
            [restoredMove.path isEqual:moved.path] && restoredMove.pageIndex==7 && restoredMove.scrollOrigin.y==132,
            @"YAML retains transferred group, tab position and document reading position");
        NSData* reorder=[NSJSONSerialization dataWithJSONObject:@{@"source":destination.identifier,@"path":moved.path,@"before":first.path} options:0 error:nil];
        [reader performSidebarGroupAction:@"move-document" identifier:destination.identifier
            value:[[NSString alloc] initWithData:reorder encoding:NSUTF8StringEncoding]];
        Check([reader.tabs indexOfObjectIdenticalTo:moved]+1==[reader.tabs indexOfObjectIdenticalTo:first],
            @"production same-group drop inserts before the requested document");
    }
}
static void CheckTabScrollPersistence(void) {
    WorkspaceProbe* reader=[WorkspaceProbe new]; [reader seed:@[]];
    [reader restoreSidebarWorkspaceState:@{@"tabStripScroll":@325}];
    WorkspaceScrollProbe* strip=[reader createScrollProbe]; [reader applySidebarWorkspaceState];
    Check(strip.tabScrollOffset==325 && reader.saves==0,@"tab scroll restores in memory without startup saves or store work");
    if (!strip.tabScrollDidChange) { Check(NO,@"tab scrolling installs its persistence callback"); return; }
    strip.tabScrollOffset=485; strip.tabScrollDidChange(485);
    strip.tabScrollOffset=500; strip.tabScrollDidChange(500);
    [reader applySidebarWorkspaceState];
    Check(strip.tabScrollOffset==500,@"workspace refresh cannot reset a manual tab scroll");
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:.3];
    while(end.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:end];
    Check(reader.saves==1,@"wheel bursts coalesce into one deferred state save");
    NSDictionary* session=YAML(@{@"sidebar":reader.sidebarWorkspaceSnapshot});
    WorkspaceProbe* reopened=[WorkspaceProbe new]; [reopened seed:@[]];
    [reopened restoreSidebarWorkspaceState:session[@"sidebar"]];
    WorkspaceScrollProbe* restored=[reopened createScrollProbe]; [reopened applySidebarWorkspaceState];
    Check(restored.tabScrollOffset==500 && reopened.saves==0,@"per-window YAML roundtrip retains tab-strip scroll");
    [reopened restoreSidebarWorkspaceState:@{@"tabStripScroll":@(-1)}];
    Check(!reopened.sidebarWorkspaceState[@"tabStripScroll"],@"invalid negative tab scroll is ignored");
}
static void BenchmarkWorkspace(void) {
    for (NSNumber* countValue in @[@20,@200,@1000]) {
        NSUInteger count=countValue.unsignedIntegerValue;
        NSMutableArray* tabs=[NSMutableArray array]; SPDFTabGroup* group=nil;
        for (NSUInteger i=0;i<count;i++) {
            if (i%10==0) group=[SPDFTabGroup groupWithColor:@"Blue"];
            SPDFDocumentTab* tab=Tab([NSString stringWithFormat:@"benchmark-%lu.pdf",(unsigned long)i]);
            tab.group=group; [tabs addObject:tab];
        }
        WorkspaceProbe* reader=[WorkspaceProbe new]; [reader seed:tabs];
        reader.navigation.spdf_selectedSidebarMode=SPDFSidebarModeGroups;
        [reader showSidebarWorkspacePanel];
        for (NSUInteger phase=0;phase<4;phase++) {
            if (phase==3) [reader preferSidebarVisible:NO];
            CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
            const NSUInteger repeats=250;
            for (NSUInteger i=0;i<repeats;i++) { @autoreleasepool {
                if (phase==0) (void)[reader sidebarGroupSnapshots];
                else if (phase==1 || phase==3) [reader refreshSidebarWorkspacePanel];
                else [reader showSidebarWorkspacePanel];
            } }
            printf("workspace_tabs=%lu %s_us=%.3f\n",(unsigned long)count,
                phase==0 ? "snapshot" : phase==1 ? "unchanged_refresh" : phase==2 ? "unchanged_show" : "hidden_refresh",
                (CFAbsoluteTimeGetCurrent()-start)*1e6/repeats);
        }
    }
}
static void CheckEmptyGroupPersistence(void) {
    WorkspaceProbe* reader=[WorkspaceProbe new]; [reader seed:@[Tab(@"Current.pdf")]];
    SPDFTabGroup* group=[reader createEmptyTabGroup]; [reader renameTabGroup:group name:@"Next project"];
    NSDictionary* saved=YAML([reader sidebarWorkspaceSnapshot]);
    Check(SPDFSessionHasEmptyTabGroups(@{@"sidebar":saved}),@"session keeps windows containing only empty groups");
    Check(!SPDFSessionHasEmptyTabGroups(@{@"sidebar":@[@1]}) &&
        !SPDFSessionHasEmptyTabGroups(@{@"sidebar":@{@"emptyGroups":@[@1,@{}]}}),@"invalid session groups do not keep empty windows");
    WorkspaceProbe* restored=[WorkspaceProbe new]; [restored seed:@[Tab(@"Current.pdf")]];
    [restored restoreSidebarWorkspaceState:saved];
    SPDFTabGroup* empty=[restored emptyTabGroups].firstObject;
    Check([empty.identifier isEqual:group.identifier] && [empty.name isEqual:@"Next project"],@"YAML preserves empty group identity/name");
    Check([restored pendingNewDocumentGroup]==empty,@"YAML preserves next-open destination");
    NSArray* rows=[restored sidebarGroupSnapshots];
    Check(rows.count==2 && [rows.lastObject[@"documents"] count]==0,@"manager displays empty group with no placeholder document");
    [restored performSidebarGroupAction:@"visibility" identifier:empty.identifier value:@""];
    Check(empty.hidden,@"manager actions resolve empty groups");
    SPDFDocumentTab* next=Tab(@"Next.pdf"); [restored appendNewTabToActiveGroup:next]; [restored normalizeTabGroups];
    Check(next.group==empty && !empty.hidden && ![restored emptyTabGroups].count,@"restored pending group receives new document");
    [restored restoreSidebarWorkspaceState:@{@"emptyGroups":@[@1,@{},@{@"id":@"general"}],@"pendingNewGroupID":@3}];
    Check(![restored emptyTabGroups].count && ![restored pendingNewDocumentGroup],@"invalid/reserved empty groups rejected");
}
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (argc>1 && strcmp(argv[1],"--benchmark")==0) { BenchmarkWorkspace(); return 0; }
        CheckEmptyGroupPersistence();
        CheckDocumentMoveIntegration();
        CheckTabScrollPersistence();
        WorkspaceProbe* reader = [WorkspaceProbe new]; [reader seed:@[Tab(@"Alpha.pdf"),Tab(@"Beta.md")]];
        Check(![reader showSidebarWorkspacePanel] && reader.collectionPanelChecks == 0,
            @"ordinary chapter sidebar starts no management or Collection work");
        reader.navigation.spdf_selectedSidebarMode=SPDFSidebarModeGroups; [reader preferSidebarVisible:NO];
        Check([reader showSidebarWorkspacePanel] && reader.snapshotCount==0 && reader.collectionPanelChecks==0,
            @"restored hidden manager starts no snapshot or Collection work");
        [reader preferSidebarVisible:YES]; reader.navigation.spdf_selectedSidebarMode=SPDFSidebarModeChapters;
        Check([reader sidebarGroupSnapshots].count == 1 && !((SPDFDocumentTab*)reader.tabs.firstObject).group,
            @"manager snapshot shows virtual General without mutating ordinary tabs");
        [reader performSidebarGroupAction:@"visibility" identifier:@"general" value:@""];
        SPDFDocumentTab* selected = reader.selectedTab;
        Check(selected.group.hidden && reader.selectedTab == reader.tabs.firstObject,@"hiding General retains active document");
        reader.sidebarWorkspaceState[@"expandedGroups"] = @[@"general"];
        [reader performSidebarGroupAction:@"rename" identifier:@"general" value:@"Reference"];
        SPDFTabGroup* promoted = selected.group;
        Check(!promoted.general && [promoted.name isEqual:@"Reference"],@"General rename promotes to a named group");
        Check([reader.sidebarWorkspaceState[@"expandedGroups"] isEqual:@[promoted.identifier]],@"renaming General preserves manager expansion");
        NSMutableDictionary* state = reader.sidebarWorkspaceState;
        state[@"compactPanel"] = @"map";
        state[@"groupSearchCollapsed"] = @YES; state[@"groupQuery"] = @"Réference"; state[@"expandedGroups"] = @[promoted.identifier]; state[@"groupScroll"] = @48;
        reader.navigation.spdf_selectedSidebarMode = SPDFSidebarModeGroups;
        NSMutableArray* savedTabs = [NSMutableArray array];
        for (SPDFDocumentTab* tab in reader.tabs) [savedTabs addObject:spdf_dictionary_from_tab(tab,0)];
        NSDictionary* restoredYAML = YAML(@{@"sidebar":reader.sidebarWorkspaceSnapshot,@"tabs":savedTabs});
        NSMutableArray* tabs = [NSMutableArray array];
        for (NSDictionary* item in restoredYAML[@"tabs"]) [tabs addObject:spdf_tab_from_dictionary(item)];
        spdf_tab_groups_normalize(tabs);
        WorkspaceProbe* reopened = [WorkspaceProbe new]; [reopened seed:tabs];
        [reopened restoreSidebarWorkspaceState:restoredYAML[@"sidebar"]]; [reopened applySidebarWorkspaceState];
        Check(reopened.navigation.spdf_selectedSidebarMode == SPDFSidebarModeGroups && reopened.sidebarWidth == 284,
            @"YAML restores exact sidebar mode and width");
        Check([reopened.sidebarWorkspaceState[@"compactPanel"] isEqual:@"map"],@"YAML restores compact panel priority");
        Check([reopened.sidebarWorkspaceState[@"groupSearchCollapsed"] boolValue] &&
            [reopened.sidebarWorkspaceState[@"groupQuery"] isEqual:@"Réference"] &&
            [reopened.sidebarWorkspaceState[@"expandedGroups"] isEqual:@[promoted.identifier]] &&
            [reopened.sidebarWorkspaceState[@"groupScroll"] integerValue] == 48,@"YAML restores manager query, expansion and scroll");
        Check(reopened.selectedTab.group.hidden && reopened.selectedTab.pageIndex == 7 && reopened.selectedTab.scrollOrigin.y == 132,
            @"YAML preserves hidden groups and document reading position");
        SPDFDocumentTab* fresh = Tab(@"Fresh.pdf"); [reopened appendNewTabToActiveGroup:fresh];
        Check(fresh.group.general && !fresh.group.hidden && reopened.selectedTab.group != fresh.group,
            @"opening after restart creates a fresh General after rename");
        [reopened performSidebarGroupAction:@"jump" identifier:promoted.identifier value:@""];
        Check(!reopened.selectedTab.group.hidden && [reopened.selectedTab.group.identifier isEqual:promoted.identifier],
            @"jump restores hidden group and selects its document");
        Check(reopened.navigation.spdf_selectedSidebarMode == SPDFSidebarModeGroups &&
            [reopened.sidebarWorkspaceSnapshot[@"visible"] boolValue],@"jump preserves manager navigation and visibility despite target tab preference");
        [reopened preferSidebarVisible:NO]; NSInteger snapshots=reopened.snapshotCount;
        [reopened refreshSidebarWorkspacePanel];
        Check(reopened.snapshotCount==snapshots,@"hidden sidebar refresh performs no group snapshot work");
        [reopened preferSidebarVisible:YES]; [reopened showSidebarWorkspacePanel];
        Check(reopened.snapshotCount==snapshots+1,@"revealing sidebar refreshes current group state");
        reopened.navigation.spdf_selectedSidebarMode = SPDFSidebarModeHistory; [reopened rememberSidebarWorkspaceMode];
        reopened.navigation.spdf_selectedSidebarMode = SPDFSidebarModeChapters; [reopened applySidebarWorkspaceState];
        Check(reopened.navigation.spdf_selectedSidebarMode == SPDFSidebarModeHistory,@"explicit new mode replaces prior sticky Groups state");
        [reopened restoreSidebarWorkspaceState:@{@"groupQuery":@3,@"expandedGroups":@[@1,@"ok"],@"width":@(-1),@"compactPanel":@"unexpected"}];
        Check(!reopened.sidebarWorkspaceState[@"compactPanel"],@"invalid compact panel preference is ignored");
        Check(!reopened.sidebarWorkspaceState[@"groupQuery"] && [reopened.sidebarWorkspaceState[@"expandedGroups"] isEqual:@[@"ok"]],
            @"malformed YAML fields are ignored safely");
        NSString* source = [NSString stringWithContentsOfFile:@"mac/ShenzhenPDFMac.mm" encoding:NSUTF8StringEncoding error:nil];
        Check([source containsString:@"[self restoreSidebarWorkspaceState:windowState[@\"sidebar\"]]"] &&
            [source containsString:@"@\"sidebar\" : [self sidebarWorkspaceSnapshot]"],@"window YAML load/save both wire workspace state");
        Check([source containsString:@"[[SPDFSidebarNavigationControl alloc] init]"] &&
            [source containsString:@"[self showSidebarWorkspacePanel] ||"],@"reader constructs vertical navigation and routes workspace before legacy modes");
        Check([source containsString:@"_sidebarToggleButton.enabled = _sidebarModeControl != nil"] &&
            [source containsString:@"BOOL canShowSidebar = _sidebarModeControl != nil"],@"empty readers can reopen the always-available sidebar");
        if (!failures) puts("SPDFMacSidebarWorkspaceTests passed");
        return failures ? 1 : 0;
    }
}
