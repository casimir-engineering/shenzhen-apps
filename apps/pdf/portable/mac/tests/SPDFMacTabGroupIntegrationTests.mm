#import "SPDFMacTabGroupReaderProbe.h"
#include <initializer_list>

static int failures;
static void Expect(NSString* label, BOOL condition) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); ++failures; }
}
static SPDFDocumentTab* Tab(NSString* path) {
    SPDFDocumentTab* tab = [[SPDFDocumentTab alloc] init];
    tab.path = path; tab.title = path.lastPathComponent;
    return tab;
}
static void CheckCreationPlacement(BOOL before, BOOL explicitPlacement) {
    GroupReaderProbe* reader = [GroupReaderProbe new];
    NSMutableArray* tabs = [NSMutableArray array];
    for (NSUInteger i=0;i<60;i++) [tabs addObject:Tab([NSString stringWithFormat:@"/placement-%lu.md",(unsigned long)i])];
    // With overflow, a left-side visible target can be near the end of the model.
    NSInteger source = explicitPlacement ? 59 : before ? 10 : 0;
    NSInteger target = explicitPlacement ? 54 : before ? 11 : 55;
    SPDFDocumentTab* dragged = tabs[source]; SPDFDocumentTab* destination = tabs[target];
    dragged.pageIndex = 9; destination.pageIndex = 17;
    [reader seed:tabs selected:source];
    if (explicitPlacement) {
        BOOL supported = [reader respondsToSelector:@selector(createGroupForTabAtIndex:withTabAtIndex:color:beforeTargetGroup:)];
        Expect(@"creation accepts an explicit visible-side placement",supported);
        if (!supported) return;
        [reader createGroupForTabAtIndex:source withTabAtIndex:target color:@"Blue" beforeTargetGroup:before];
    } else [reader createGroupForTabAtIndex:source withTabAtIndex:target color:@"Blue"];
    Expect(before ? @"left-side creation precedes General" : @"right-side creation follows General",
        ((SPDFDocumentTab*)(before ? reader.tabs.firstObject : reader.tabs.lastObject)).group == dragged.group &&
        ((SPDFDocumentTab*)(before ? reader.tabs.lastObject : reader.tabs.firstObject)).group.general);
    Expect(@"creation keeps both documents and all other tabs",reader.tabs.count == 60 &&
        dragged.group == destination.group && [NSSet setWithArray:reader.tabs].count == 60);
    Expect(@"creation preserves active document and reading state",[reader.activePath isEqual:dragged.path] &&
        ((SPDFDocumentTab*)reader.tabs[reader.selectedIndex]) == dragged && dragged.pageIndex == 9 && destination.pageIndex == 17);
    NSMutableArray* restored = [NSMutableArray array];
    for (NSDictionary* encoded in reader.savedTabs) [restored addObject:spdf_tab_from_dictionary(encoded)];
    spdf_tab_groups_normalize(restored);
    Expect(@"created side and document order survive session restore",
        [[restored valueForKey:@"path"] isEqual:[reader.tabs valueForKey:@"path"]] &&
        ((SPDFDocumentTab*)(before ? restored.lastObject : restored.firstObject)).group.general);
}
static void CheckGapDrops(void) {
    for (NSInteger boundary : {0, 2, 4}) {
        GroupReaderProbe* reader = [GroupReaderProbe new];
        SPDFDocumentTab* a = Tab(@"/gap-a.pdf"), *b = Tab(@"/gap-b.pdf");
        SPDFDocumentTab* c = Tab(@"/gap-c.md"), *d = Tab(@"/gap-d.md");
        a.group = b.group = [SPDFTabGroup groupWithColor:@"Blue"];
        c.group = d.group = [SPDFTabGroup groupWithColor:@"Green"];
        a.pageIndex = 7;
        [reader seed:@[a,b,c,d] selected:2];
        [reader moveTabAtIndex:0 toGroup:nil atIndex:boundary];
        NSInteger expected = boundary > 0 ? boundary - 1 : 0;
        Expect(@"gap drop creates General at the requested boundary",
            reader.tabs[expected] == a && a.group.general && a.group.explicitGeneral);
        Expect(@"gap drop preserves every document and selects the moved document",
            reader.tabs.count == 4 && reader.selectedIndex == expected &&
            [reader.activePath isEqual:a.path] && a.pageIndex == 7 && b.group != a.group);
        NSMutableArray* restored = [NSMutableArray array];
        for (NSDictionary* encoded in reader.savedTabs) [restored addObject:spdf_tab_from_dictionary(encoded)];
        spdf_tab_groups_normalize(restored);
        Expect(@"General gap placement persists through the session codec",
            [[restored valueForKey:@"path"] isEqual:[reader.tabs valueForKey:@"path"]] &&
            ((SPDFDocumentTab*)restored[expected]).group.general);
    }
    for (BOOL generalFirst : {YES, NO}) {
        GroupReaderProbe* reader = [GroupReaderProbe new];
        SPDFDocumentTab* a = Tab(@"/join-a.pdf"), *b = Tab(@"/join-b.pdf");
        SPDFDocumentTab* g = Tab(@"/join-general.pdf"), *h = Tab(@"/join-general-2.pdf");
        a.group = b.group = [SPDFTabGroup groupWithColor:@"Blue"];
        g.group = h.group = SPDFTabGroup.generalGroup;
        g.group.hidden = YES;
        [reader seed:generalFirst ? @[g,h,a,b] : @[a,b,g,h] selected:generalFirst ? 2 : 0];
        [reader moveTabAtIndex:reader.selectedIndex toGroup:nil atIndex:generalFirst ? 4 : 0];
        Expect(@"joining General at a remote gap preserves its existing position",
            [reader.tabs isEqual:generalFirst ? @[g,h,a,b] : @[b,g,h,a]] && a.group == g.group);
        Expect(@"gap drop reveals and expands a hidden General instead of losing the tab",
            !g.group.hidden && !g.group.collapsed);
        [reader moveTabAtIndex:[reader.tabs indexOfObjectIdenticalTo:g] toGroup:nil atIndex:0];
        Expect(@"moving General's own member never duplicates the group",
            spdf_tab_group_members(reader.tabs,g.group).count == 3 && reader.tabs.count == 4);
    }
    // Cross-window insertion uses the same resolver before the tab is added.
    SPDFDocumentTab* a = Tab(@"/external-a.pdf"), *incoming = Tab(@"/incoming.pdf");
    a.group = [SPDFTabGroup groupWithColor:@"Blue"];
    NSMutableArray* tabs = [@[a] mutableCopy];
    NSInteger index = spdf_tab_group_prepare_gap_drop(tabs,incoming,0);
    [tabs insertObject:incoming atIndex:index]; spdf_tab_groups_normalize(tabs);
    Expect(@"incoming gap drop creates General before the neighboring group",
        tabs.firstObject == incoming && incoming.group.general);
    SPDFDocumentTab* second = Tab(@"/incoming-2.pdf");
    index = spdf_tab_group_prepare_gap_drop(tabs,second,tabs.count);
    [tabs insertObject:second atIndex:index]; spdf_tab_groups_normalize(tabs);
    Expect(@"incoming gap drop joins existing General without moving it",
        [tabs isEqual:@[incoming,second,a]] && second.group == incoming.group);
}
static void CheckFreshGeneral(void) {
    GroupReaderProbe* reader=[GroupReaderProbe new];
    SPDFDocumentTab* a=Tab(@"/fresh-first.pdf"), *b=Tab(@"/fresh-second.md");
    a.pageIndex=7; b.pageIndex=11;
    [reader seed:@[a,b] selected:1];
    [reader normalizeTabGroups];
    SPDFTabGroup* general=a.group;
    Expect(@"fresh nil-group documents appear as General in the picker model",
        general.general && [general.displayName isEqual:@"General"] && b.group==general &&
        spdf_tab_group_members(reader.tabs,general).count==2);
    Expect(@"initial General normalization preserves selection, order, and reading positions",
        reader.selectedIndex==1 && [reader.activePath isEqual:b.path] && reader.tabs[0]==a &&
        reader.tabs[1]==b && a.pageIndex==7 && b.pageIndex==11);
    [reader normalizeTabGroups];
    Expect(@"General normalization is idempotent without save or layout recursion",
        a.group==general && b.group==general && reader.saveCount==0 && reader.stripRefreshCount==0);
    [reader savePersistentState];
    NSMutableArray* restored=[NSMutableArray array];
    for (NSDictionary* encoded in reader.savedTabs) [restored addObject:spdf_tab_from_dictionary(encoded)];
    spdf_tab_groups_normalize(restored);
    Expect(@"initial General survives the regular persistence path",
        ((SPDFDocumentTab*)restored[0]).group.general && ((SPDFDocumentTab*)restored[1]).group.general);
}
static void CheckCollapsedGroupRestore(void) {
    GroupReaderProbe* reader=[GroupReaderProbe new];
    SPDFDocumentTab* reading=Tab(@"/reading.pdf"), *browsing=Tab(@"/browsing.md");
    reading.group=[SPDFTabGroup groupWithColor:@"Purple"];
    browsing.group=SPDFTabGroup.generalGroup;
    reading.pageIndex=7;
    [reader seed:@[reading,browsing] selected:0];
    [reader toggleTabGroup:reading.group];
    Expect(@"folding the reading group keeps its document active",
        reading.group.collapsed && reader.selectedIndex==0 && [reader.activePath isEqual:reading.path]);
    NSMutableArray* restored=[NSMutableArray array];
    for (NSDictionary* encoded in reader.savedTabs) [restored addObject:spdf_tab_from_dictionary(encoded)];
    GroupReaderProbe* relaunched=[GroupReaderProbe new];
    [relaunched seed:restored selected:0];
    [relaunched normalizeTabGroups];
    SPDFDocumentTab* selected=relaunched.tabs[0];
    Expect(@"session restore preserves the collapsed reading group and position",
        selected.group.collapsed && selected.pageIndex==7 && relaunched.selectedIndex==0);
    NSString* path=[@(__FILE__).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"../ShenzhenPDFMac.mm"];
    NSString* coordinator=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    Expect(@"startup selects the already restored index",
        [coordinator containsString:@"[self selectTabAtIndex:MAX(0, _selectedTabIndex)];"]);
    Expect(@"initial restore skips group activation until a real navigation occurs",
        [coordinator containsString:@"if (index != _selectedTabIndex || [self hasActiveDocument])\n        spdf_tab_groups_activate"]);
    NSRange begin=[coordinator rangeOfString:@"- (void)loadSelectedTab {"];
    NSRange end=begin.location==NSNotFound ? NSMakeRange(NSNotFound,0) :
        [coordinator rangeOfString:@"// Tail of loadSelectedTab" options:0
            range:NSMakeRange(begin.location,coordinator.length-begin.location)];
    NSString* load=end.location==NSNotFound ? nil : [coordinator substringWithRange:NSMakeRange(begin.location,end.location-begin.location)];
    Expect(@"document restore does not reexpand the reading group",
        load.length && ![load containsString:@"activateSelectedTabGroup"] && ![load containsString:@"spdf_tab_groups_activate"]);
}
static void CheckGroupManagement(void) {
    GroupReaderProbe* reader=[GroupReaderProbe new];
    SPDFDocumentTab* a=Tab(@"/managed-a.pdf"), *b=Tab(@"/managed-b.md");
    [reader seed:@[a,b] selected:0];
    SPDFTabGroup* general=[reader ensureGeneralTabGroup];
    Expect(@"explicit General materializes all ordinary tabs",general.general && a.group==general && b.group==general);
    [reader setTabGroup:general hidden:YES];
    Expect(@"hiding active General keeps document and selection",[reader.activePath isEqual:a.path] && reader.selectedIndex==0 && general.hidden);
    NSMutableArray* decoded=[NSMutableArray array];
    for (NSDictionary* saved in reader.savedTabs) [decoded addObject:spdf_tab_from_dictionary(saved)];
    spdf_tab_groups_normalize(decoded);
    Expect(@"a lone hidden General survives session roundtrip",((SPDFDocumentTab*)decoded[0]).group.general &&
        ((SPDFDocumentTab*)decoded[0]).group.hidden && ((SPDFDocumentTab*)decoded[0]).group.explicitGeneral);
    general.lastUsedPath=b.path;
    [reader jumpTabGroup:general];
    Expect(@"manager jump unhides and activates remembered document",!general.hidden && [reader.activePath isEqual:b.path]);
    [reader renameTabGroup:general name:@"Inbox"];
    NSString* promotedID=[general.identifier copy];
    Expect(@"renamed General becomes a real custom group",!general.general && [general.name isEqual:@"Inbox"] &&
        [spdf_tab_group_colors() containsObject:general.colorName] && [reader.workspace[@"newDocumentsInGeneral"] boolValue]);
    SPDFDocumentTab* fresh=Tab(@"/fresh-after-rename.pdf");
    [reader appendNewTabToActiveGroup:fresh];
    Expect(@"first new document creates fresh General instead of entering promoted group",fresh.group.general &&
        fresh.group!=general && [general.identifier isEqual:promotedID] && a.group==general && b.group==general);
    [reader setTabGroup:general hidden:YES]; [reader setTabGroup:fresh.group hidden:YES];
    Expect(@"all groups can hide without changing active document",[reader.activePath isEqual:b.path] && general.hidden && fresh.group.hidden);
    decoded=[NSMutableArray array];
    for (NSDictionary* saved in reader.savedTabs) [decoded addObject:spdf_tab_from_dictionary(saved)];
    spdf_tab_groups_normalize(decoded);
    GroupReaderProbe* restored=[GroupReaderProbe new]; [restored seed:decoded selected:reader.selectedIndex];
    restored.workspace=[reader.workspace mutableCopy];
    Expect(@"roundtrip preserves hidden groups order membership and selected document",[restored.activePath isEqual:b.path] &&
        [[restored.tabs valueForKey:@"path"] isEqual:[reader.tabs valueForKey:@"path"]] &&
        ((SPDFDocumentTab*)restored.tabs[0]).group.hidden && ((SPDFDocumentTab*)restored.tabs.lastObject).group.hidden &&
        [((SPDFDocumentTab*)restored.tabs[0]).group.identifier isEqual:promotedID]);
    SPDFDocumentTab* next=Tab(@"/next-after-relaunch.md"); [restored appendNewTabToActiveGroup:next];
    Expect(@"new opens retain General routing after restart and reveal the new tab",next.group.general && !next.group.hidden &&
        ((SPDFDocumentTab*)restored.tabs[0]).group.hidden && [spdf_tab_group_members(restored.tabs,next.group) count]==2);
    SPDFTabGroup* currentGeneral=next.group;
    NSUInteger beforeClose=restored.tabs.count;
    restored.closeResponse=NSAlertFirstButtonReturn;
    [restored requestCloseTabGroup:((SPDFDocumentTab*)restored.tabs[0]).group];
    Expect(@"Cancel leaves group documents open",restored.tabs.count==beforeClose && restored.closeAlert!=nil);
    restored.closeResponse=NSAlertSecondButtonReturn;
    [restored requestCloseTabGroup:((SPDFDocumentTab*)restored.tabs[0]).group];
    SPDFDocumentTab* reopened=Tab(@"/reopened-after-close.md"); [restored appendNewTabToActiveGroup:reopened];
    Expect(@"closing promoted group then reopening reuses the unique General",restored.tabs.count==3 &&
        reopened.group==currentGeneral && spdf_tab_group_members(restored.tabs,currentGeneral).count==3);
    [restored closeTabGroup:currentGeneral];
    SPDFDocumentTab* afterEmpty=Tab(@"/after-empty.md"); [restored appendNewTabToActiveGroup:afterEmpty];
    Expect(@"opening after every group closes creates one fresh General",restored.tabs.count==1 && afterEmpty.group.general &&
        afterEmpty.group!=currentGeneral && afterEmpty.group.explicitGeneral);
    // Ungrouping before General must retain its persisted hidden state.
    [reader setTabGroup:fresh.group hidden:YES];
    [reader ungroupTabs:general];
    Expect(@"ungrouping before hidden General preserves its canonical settings",a.group==fresh.group &&
        b.group==fresh.group && fresh.group.hidden && fresh.group.explicitGeneral);
}
static void CheckOpeningOriginalFromBackups(void) {
    GroupReaderProbe* reader = [GroupReaderProbe new];
    SPDFDocumentTab* backup = Tab(@"/collection/copy.pdf");
    backup.readOnly = YES; backup.group = SPDFTabGroup.collectionBackupsGroup;
    [reader seed:@[backup] selected:0];
    [reader recolorTabGroup:backup.group color:@"Purple"];
    Expect(@"recolor API cannot change reserved backup color",[backup.group.colorName isEqual:@"Orange"]);
    SPDFDocumentTab* original = Tab(@"/documents/original.pdf");
    NSInteger inserted = [reader appendNewTabToActiveGroup:original];
    Expect(@"opening an original from Backups creates General instead of mixing editable documents",
        inserted == 1 && original.group.general && !original.readOnly && backup.group.collectionBackups);
    original.group.hidden = YES;
    SPDFDocumentTab* another = Tab(@"/documents/another.md");
    [reader appendNewTabToActiveGroup:another];
    Expect(@"original opens reuse and reveal existing General while Backups stays intact",
        another.group == original.group && !original.group.hidden && reader.tabs.count == 3 &&
        [spdf_tab_group_members(reader.tabs,backup.group) isEqual:@[backup]]);
    [reader savePersistentState];
    NSMutableArray* restoredTabs = [NSMutableArray array];
    for (NSDictionary* saved in reader.savedTabs) [restoredTabs addObject:spdf_tab_from_dictionary(saved)];
    spdf_tab_groups_normalize(restoredTabs);
    GroupReaderProbe* restored = [GroupReaderProbe new]; [restored seed:restoredTabs selected:0];
    SPDFDocumentTab* afterRestart = Tab(@"/documents/after-restart.txt");
    [restored appendNewTabToActiveGroup:afterRestart];
    Expect(@"legacy Backups joins ordinary General on restoration",afterRestart.group.general &&
        [spdf_tab_group_members(restored.tabs,afterRestart.group) count] == 4 &&
        !((SPDFDocumentTab*)restored.tabs[0]).group.collectionBackups);
}
static void CheckEmptyGroups(void) {
    GroupReaderProbe* reader=[GroupReaderProbe new];
    SPDFDocumentTab* current=Tab(@"/reading.pdf"); current.pageIndex=12;
    [reader seed:@[current] selected:0];
    Expect(@"ordinary sessions allocate no empty-group registry", [reader emptyTabGroups]==nil);
    SPDFTabGroup* first=[reader createEmptyTabGroup];
    Expect(@"empty group preserves document, position and tab count", reader.tabs.count==1 &&
        reader.selectedIndex==0 && [reader.activePath isEqual:current.path] && current.pageIndex==12);
    Expect(@"empty group is real, saved and pending", [reader emptyTabGroups].firstObject==first &&
        [reader.workspace[@"emptyGroups"] count]==1 && [reader pendingNewDocumentGroup]==first);
    [reader renameTabGroup:first name:@" Research "];
    [reader setTabGroup:first hidden:YES];
    Expect(@"empty group supports rename and visibility", [first.name isEqual:@"Research"] && first.hidden);
    SPDFTabGroup* second=[reader createEmptyTabGroup];
    Expect(@"multiple empty groups remain distinct", [reader emptyTabGroups].count==2 && ![first.identifier isEqual:second.identifier]);
    reader.closeResponse=NSAlertFirstButtonReturn; [reader requestCloseTabGroup:second];
    Expect(@"cancel closing empty group preserves it", [reader emptyTabGroups].count==2);
    reader.closeResponse=NSAlertSecondButtonReturn; [reader requestCloseTabGroup:second];
    Expect(@"closing empty group clears pending destination without closing reader", [reader emptyTabGroups].count==1 &&
        ![reader pendingNewDocumentGroup] && reader.tabs.count==1);
    [reader jumpTabGroup:first];
    Expect(@"jump to empty group arms next open without navigating", !first.hidden &&
        [reader pendingNewDocumentGroup]==first && [reader.activePath isEqual:current.path]);
    reader.workspace[@"newDocumentsInGeneral"]=@YES;
    SPDFDocumentTab* a=Tab(@"/new-a.pdf"), *b=Tab(@"/new-b.md");
    [reader appendNewTabToActiveGroup:a]; [reader normalizeTabGroups];
    [reader appendNewTabToActiveGroup:b]; [reader normalizeTabGroups];
    Expect(@"pending destination overrides default and receives entire batch", a.group==first && b.group==first);
    Expect(@"filled group has no duplicate empty record", ![reader emptyTabGroups].count && !reader.workspace[@"emptyGroups"]);
    [reader selectTabAtIndex:[reader.tabs indexOfObjectIdenticalTo:b]];
    Expect(@"activating opened document consumes pending destination", ![reader pendingNewDocumentGroup]);
    SPDFDocumentTab* c=Tab(@"/normal-after-batch.pdf"); [reader appendNewTabToActiveGroup:c];
    Expect(@"ordinary destination policy resumes after batch", c.group.general);
    GroupReaderProbe* blank=[GroupReaderProbe new]; [blank seed:@[] selected:-1];
    SPDFTabGroup* blankGroup=[blank createEmptyTabGroup];
    Expect(@"empty window can own a group without fake documents", blank.tabs.count==0 && blank.selectedIndex==-1);
    SPDFDocumentTab* only=Tab(@"/first.pdf"); [blank appendNewTabToActiveGroup:only]; [blank normalizeTabGroups];
    Expect(@"first document enters empty-window group", only.group==blankGroup && ![blank emptyTabGroups].count);
}
int main(void) {
    @autoreleasepool {
        CheckEmptyGroups();
        CheckOpeningOriginalFromBackups();
        CheckFreshGeneral();
        CheckGapDrops();
        CheckCollapsedGroupRestore();
        CheckGroupManagement();
        CheckCreationPlacement(YES,NO); CheckCreationPlacement(NO,NO);
        CheckCreationPlacement(YES,YES); CheckCreationPlacement(NO,YES);
        GroupReaderProbe* reader = [[GroupReaderProbe alloc] init];
        SPDFDocumentTab* a = Tab(@"/a.pdf");
        SPDFDocumentTab* b = Tab(@"/b.md");
        SPDFDocumentTab* c = Tab(@"/c.pdf");
        SPDFDocumentTab* d = Tab(@"/d.md");
        [reader seed:@[a, b, c, d] selected:0];
        [reader createGroupForTabAtIndex:1 withTabAtIndex:2 color:@"Purple"];
        SPDFTabGroup* purple = b.group;
        Expect(@"pair creation gives both tabs one group", purple && c.group == purple);
        Expect(@"all remaining tabs share General", a.group.general && a.group == d.group);
        Expect(@"creating a group preserves current document selection after normalization",
               [reader.activePath isEqualToString:b.path]);
        [reader renameTabGroup:purple name:@"  References  "];
        [reader recolorTabGroup:purple color:@"Teal"];
        Expect(@"rename and palette persist immediately", [reader.savedTabs[2][@"group"][@"name"] isEqual:@"References"]
            && [reader.savedTabs[2][@"group"][@"color"] isEqual:@"Teal"]);
        [reader toggleTabGroup:purple];
        Expect(@"folding persists immediately", [reader.savedTabs[2][@"group"][@"collapsed"] boolValue]);
        SPDFDocumentTab* fresh = Tab(@"/new.md");
        NSInteger inserted = [reader appendNewTabToActiveGroup:fresh];
        Expect(@"new opens append inside active group", fresh.group == purple && inserted == 4);
        [reader moveTabGroup:purple toIndex:0];
        Expect(@"dragging handle reorders whole group intact", [reader.tabs isEqual:@[b, c, fresh, a, d]]);
        Expect(@"group reorder keeps selected document", ((SPDFDocumentTab*)reader.tabs[reader.selectedIndex]) == b);
        [reader moveTabAtIndex:1 toGroup:a.group atIndex:reader.tabs.count];
        Expect(@"dropping a tab into General moves membership and order", c.group.general && reader.tabs.lastObject == c);
        [reader ungroupTabs:purple];
        BOOL ordinary = YES;
        for (SPDFDocumentTab* tab in reader.tabs) ordinary &= tab.group.general;
        Expect(@"ungrouping last custom group returns all tabs to General", ordinary);

        GroupReaderProbe* source = [[GroupReaderProbe alloc] init];
        SPDFDocumentTab* one = Tab(@"/one.md");
        SPDFDocumentTab* two = Tab(@"/two.pdf");
        [source seed:@[one, two] selected:0];
        [source createGroupForTabAtIndex:0 withTabAtIndex:1 color:@"Rose"];
        one.pageIndex = 7; two.pageIndex = 11;
        one.group.lastUsedPath = two.path;
        [source toggleTabGroup:one.group];
        [source toggleTabGroup:one.group];
        Expect(@"expanding a group preserves the selected document and reading positions",
            !one.group.collapsed && [source.activePath isEqual:one.path] && one.pageIndex == 7 && two.pageIndex == 11);
        GroupReaderProbe* browsing = [GroupReaderProbe new];
        SPDFDocumentTab* outside = Tab(@"/outside.pdf");
        [browsing seed:@[outside, one, two] selected:0];
        [browsing normalizeTabGroups];
        one.group.collapsed = YES;
        [browsing toggleTabGroup:one.group];
        Expect(@"browsing another group never selects one of its tabs",
            !one.group.collapsed && [browsing.activePath isEqual:outside.path] && browsing.selectedIndex == 0);
        Expect(@"browsing a group collapses the previous group without navigation", outside.group.collapsed);
        Expect(@"manual expansion is persisted", ![browsing.savedTabs[1][@"group"][@"collapsed"] boolValue]);
        [source detachTabGroup:one.group atScreenPoint:NSMakePoint(300, 500)];
        Expect(@"failed handoff write leaves the source tabs open and reports the failure",
               source.handoffWriteCount == 1 && source.errorCount == 1 && source.tabs.count == 2);
        NSArray* payload = [source snapshotTabGroup:one.group];
        GroupReaderProbe* destination = [[GroupReaderProbe alloc] init];
        SPDFDocumentTab* existing = Tab(@"/existing.pdf");
        [destination seed:@[existing] selected:0];
        [destination insertDraggedGroup:payload atIndex:0];
        Expect(@"incoming group before active tab loads the incoming last-used document",
               [destination.activePath isEqualToString:two.path]);
        Expect(@"incoming group owns two tabs and General owns preexisting tab", existing.group.general
            && ((SPDFDocumentTab*)destination.tabs[0]).group == ((SPDFDocumentTab*)destination.tabs[1]).group);
        Expect(@"incoming reading positions survive", ((SPDFDocumentTab*)destination.tabs[0]).pageIndex == 7
            && ((SPDFDocumentTab*)destination.tabs[1]).pageIndex == 11);
        [destination closeTabGroup:((SPDFDocumentTab*)destination.tabs[0]).group];
        Expect(@"closing a group only closes its members", [destination.tabs isEqual:@[existing]] && existing.group.general);
        // Duplicate paths keep the destination's live document but join the
        // moved group; the source may close safely after this successful drop.
        [destination seed:@[one, existing] selected:0];
        [destination insertDraggedGroup:payload atIndex:1];
        Expect(@"duplicate path transfer does not create duplicate tabs", destination.tabs.count == 3);
        Expect(@"duplicate document joins incoming group", one.group && one.group == ((SPDFDocumentTab*)destination.tabs[1]).group);
    }
    if (!failures) puts("SPDFMacTabGroupIntegrationTests passed");
    return failures ? 1 : 0;
}
