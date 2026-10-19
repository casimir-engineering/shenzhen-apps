#import "SPDFMacUnsavedImageClose.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacTabDetach.h"
#import "SPDFMacSidebarWorkspace.h"
#import <objc/runtime.h>

static char emptyGroupsKey;
BOOL SPDFSessionHasEmptyTabGroups(id windowState) {
    id sidebar=[windowState isKindOfClass:NSDictionary.class] ? windowState[@"sidebar"] : nil;
    id groups=[sidebar isKindOfClass:NSDictionary.class] ? sidebar[@"emptyGroups"] : nil;
    if (![groups isKindOfClass:NSArray.class]) return NO;
    for (id raw in groups) {
        SPDFTabGroup* group=[SPDFTabGroup fromDictionary:raw];
        if (group && !group.general && !group.collectionBackups) return YES;
    }
    return NO;
}

@interface ShenzhenMacDelegate (SPDFMacTabGroupPrivate)
- (void)rememberActiveTabState;
- (void)collectionRememberGroups;
- (NSString*)pathForStateFile:(NSString*)name;
- (id)stateObjectFromFile:(NSString*)name;
- (void)writeStateObject:(id)object toFile:(NSString*)name;
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (void)updateTabStrip;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)closeTabAtIndex:(NSInteger)index;
- (void)insertDraggedTab:(SPDFDocumentTab*)tab atIndex:(NSInteger)index;
- (void)savePersistentState;
@end

@implementation ShenzhenMacDelegate (SPDFMacTabGroupIntegration)
- (NSArray<SPDFTabGroup*>*)emptyTabGroups {
    NSMutableArray* groups=objc_getAssociatedObject(self,&emptyGroupsKey);
    // No registry allocation for ordinary sessions. Decode only saved empty groups.
    if (!groups && [[self sidebarWorkspaceState][@"emptyGroups"] count]) {
        groups=[NSMutableArray array];
        NSMutableSet* ids=[NSMutableSet set];
        for (id value in [self sidebarWorkspaceState][@"emptyGroups"]) {
            SPDFTabGroup* group=[SPDFTabGroup fromDictionary:value];
            if (!group || group.general || group.collectionBackups || [ids containsObject:group.identifier]) continue;
            [groups addObject:group]; [ids addObject:group.identifier];
        }
        objc_setAssociatedObject(self,&emptyGroupsKey,groups,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return groups;
}
- (void)resetEmptyTabGroups { objc_setAssociatedObject(self,&emptyGroupsKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (void)syncEmptyTabGroups {
    NSMutableArray* groups=(id)[self emptyTabGroups];
    if (!groups) return;
    // Once populated, the existing per-tab codec owns this group's state.
    NSIndexSet* populated=[groups indexesOfObjectsPassingTest:^BOOL(SPDFTabGroup* group, NSUInteger i, BOOL* stop) {
        (void)i; (void)stop; return spdf_tab_group_members(self->_tabs,group).count>0;
    }];
    [groups removeObjectsAtIndexes:populated];
    NSMutableArray* values=[NSMutableArray arrayWithCapacity:groups.count];
    for (SPDFTabGroup* group in groups) [values addObject:group.dictionary];
    if (values.count) [self sidebarWorkspaceState][@"emptyGroups"]=values;
    else { [[self sidebarWorkspaceState] removeObjectForKey:@"emptyGroups"]; [self resetEmptyTabGroups]; }
}
- (SPDFTabGroup*)createEmptyTabGroup {
    NSMutableArray* groups=[([self emptyTabGroups] ?: @[]) mutableCopy];
    NSMutableArray* colors=[spdf_tab_group_colors() mutableCopy];
    for (SPDFDocumentTab* tab in _tabs) [colors removeObject:tab.group.colorName ?: @""];
    for (SPDFTabGroup* group in groups) [colors removeObject:group.colorName];
    SPDFTabGroup* group=[SPDFTabGroup groupWithColor:colors.count ? colors.firstObject : spdf_tab_group_unused_color(_tabs)];
    group.collapsed=YES; [groups addObject:group];
    objc_setAssociatedObject(self,&emptyGroupsKey,groups,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self sidebarWorkspaceState][@"pendingNewGroupID"]=group.identifier;
    [self finishTabGroupChange];
    return group;
}
- (SPDFTabGroup*)pendingNewDocumentGroup {
    NSString* identifier=[self sidebarWorkspaceState][@"pendingNewGroupID"];
    if (!identifier.length) return nil;
    for (SPDFTabGroup* group in [self emptyTabGroups]) if ([group.identifier isEqual:identifier]) return group;
    for (SPDFDocumentTab* tab in _tabs) if ([tab.group.identifier isEqual:identifier]) return tab.group;
    [[self sidebarWorkspaceState] removeObjectForKey:@"pendingNewGroupID"];
    return nil;
}
- (SPDFTabGroup*)ensureGeneralTabGroup {
    SPDFTabGroup* general=nil;
    for (SPDFDocumentTab* tab in _tabs) if (tab.group.general) { general=tab.group; break; }
    if (!general) for (SPDFDocumentTab* tab in _tabs) if (!tab.group) {
        if (!general) general=SPDFTabGroup.generalGroup;
        tab.group=general;
    }
    if (general) { general.explicitGeneral=YES; [self finishTabGroupChange]; }
    return general;
}
- (void)setTabGroup:(SPDFTabGroup*)group hidden:(BOOL)hidden {
    if (!group) return;
    group.hidden=hidden;
    if (group.general) group.explicitGeneral=YES;
    // Visibility is independent of selection: hiding the active group leaves its document open.
    [self finishTabGroupChange];
}
- (void)jumpTabGroup:(SPDFTabGroup*)group {
    NSArray* members=spdf_tab_group_members(_tabs,group);
    if (!members.count) {
        if ([[self emptyTabGroups] containsObject:group]) {
            group.hidden=NO; [self sidebarWorkspaceState][@"pendingNewGroupID"]=group.identifier;
            [self finishTabGroupChange];
        }
        return;
    }
    SPDFDocumentTab* target=members.firstObject;
    for (SPDFDocumentTab* tab in members) if ([tab.path isEqual:group.lastUsedPath]) { target=tab; break; }
    group.hidden=NO;
    spdf_tab_groups_activate(_tabs,target);
    [self selectTabAtIndex:[_tabs indexOfObjectIdenticalTo:target]];
    [self finishTabGroupChange];
}
- (void)normalizeTabGroups {
    SPDFDocumentTab* selected = _selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count
        ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
    // General is a real workspace group from the first document. Materialize
    // legacy nil membership in memory only: this refresh must never recursively
    // save state, rebuild the strip, or activate a different document.
    SPDFTabGroup* general=nil;
    for (SPDFDocumentTab* tab in _tabs) if (tab.group.general) {
        general=tab.group; general.explicitGeneral=YES; break;
    }
    for (SPDFDocumentTab* tab in _tabs) if (!tab.group) {
        if (!general) { general=SPDFTabGroup.generalGroup; general.explicitGeneral=YES; }
        tab.group=general;
    }
    spdf_tab_groups_normalize(_tabs);
    [self syncEmptyTabGroups];
    if (selected) _selectedTabIndex = [_tabs indexOfObjectIdenticalTo:selected];
}
- (void)activateSelectedTabGroup {
    if (_selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count) {
        SPDFDocumentTab* selected=_tabs[(NSUInteger)_selectedTabIndex];
        spdf_tab_groups_activate(_tabs,selected);
        if ([selected.group.identifier isEqual:[self sidebarWorkspaceState][@"pendingNewGroupID"]])
            [[self sidebarWorkspaceState] removeObjectForKey:@"pendingNewGroupID"];
    }
}
- (NSInteger)appendNewTabToActiveGroup:(SPDFDocumentTab*)tab {
    SPDFTabGroup* group = _selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count
        ? _tabs[(NSUInteger)_selectedTabIndex].group : nil;
    SPDFTabGroup* pending=[self pendingNewDocumentGroup];
    if (pending) group=pending;
    // Backups is a reserved destination for immutable Collection copies. Opening
    // an original from it must not inherit that group; archived opens route explicitly.
    if (!pending && ([[self sidebarWorkspaceState][@"newDocumentsInGeneral"] boolValue] || group.hidden || group.collectionBackups)) {
        group=nil;
        for (SPDFDocumentTab* existing in _tabs) if (existing.group.general) { group=existing.group; break; }
        if (!group) group=SPDFTabGroup.generalGroup;
        group.explicitGeneral=YES;
    }
    // Explicitly opening a new document must not strand its tab in a hidden group.
    group.hidden=NO;
    tab.group = group;
    NSInteger index = _tabs.count;
    if (group) {
        for (NSInteger i = _tabs.count - 1; i >= 0; --i)
            if (_tabs[(NSUInteger)i].group == group) { index = i + 1; break; }
    }
    [_tabs insertObject:tab atIndex:(NSUInteger)index];
    return index;
}
- (void)finishTabGroupChange {
    [self normalizeTabGroups];
    [self collectionRememberGroups];
    [self updateTabStrip];
    [self savePersistentState];
    [self refreshSidebarWorkspacePanel];
}
- (void)createGroupForTabAtIndex:(NSInteger)index withTabAtIndex:(NSInteger)other color:(NSString*)color {
    NSInteger target = other >= 0 && other < (NSInteger)_tabs.count ? other : index;
    if (index < 0 || index >= (NSInteger)_tabs.count) return;
    SPDFTabGroup* parent = _tabs[(NSUInteger)target].group;
    NSInteger first = target, last = target;
    while (first > 0 && _tabs[(NSUInteger)first-1].group == parent) --first;
    while (last+1 < (NSInteger)_tabs.count && _tabs[(NSUInteger)last+1].group == parent) ++last;
    [self createGroupForTabAtIndex:index withTabAtIndex:other color:color
        beforeTargetGroup:target-first < (last-first+1)/2];
}
- (void)createGroupForTabAtIndex:(NSInteger)index withTabAtIndex:(NSInteger)other color:(NSString*)color
             beforeTargetGroup:(BOOL)before {
    if (index < 0 || index >= (NSInteger)_tabs.count) return;
    SPDFDocumentTab* selected = _tabs[(NSUInteger)index];
    SPDFDocumentTab* target = other >= 0 && other < (NSInteger)_tabs.count ? _tabs[(NSUInteger)other] : selected;
    SPDFDocumentTab* active = _selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count
        ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
    SPDFTabGroup* parent = target.group;
    NSMutableArray* members = [NSMutableArray array];
    NSUInteger fallback = 0;
    NSUInteger targetIndex = [_tabs indexOfObjectIdenticalTo:target];
    for (NSUInteger i=0;i<_tabs.count;i++) {
        SPDFDocumentTab* tab = _tabs[i];
        if (tab == selected || tab == target) [members addObject:tab];
        else if (i < targetIndex) ++fallback;
    }
    [_tabs removeObjectsInArray:members];
    NSUInteger insertion = fallback;
    // General remains contiguous, on the opposite side from the visible drop.
    // Establish that boundary before normalization; first occurrence alone
    // would move a left-side group behind every hidden General tab.
    for (NSUInteger i=0;i<_tabs.count;i++) if (_tabs[i].group == parent) {
        insertion = before ? i : i+1;
        if (before) break;
    }
    SPDFTabGroup* group = [SPDFTabGroup groupWithColor:color ?: spdf_tab_group_unused_color(_tabs)];
    for (SPDFDocumentTab* tab in members) tab.group = group;
    [_tabs insertObjects:members atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertion,members.count)]];
    if (active) _selectedTabIndex = [_tabs indexOfObjectIdenticalTo:active];
    [self normalizeTabGroups];
    spdf_tab_groups_activate(_tabs, selected);
    [self selectTabAtIndex:[_tabs indexOfObjectIdenticalTo:selected]];
    [self finishTabGroupChange];
}
- (void)toggleTabGroup:(SPDFTabGroup*)group {
    if (!group) return;
    group.collapsed = !group.collapsed;
    // Browsing another group only changes the strip, never the reading position.
    if (!group.collapsed)
        for (SPDFDocumentTab* tab in _tabs) if (tab.group != group) tab.group.collapsed = YES;
    [self finishTabGroupChange];
}
- (void)renameTabGroup:(SPDFTabGroup*)group name:(NSString*)name {
    if (!group) return;
    NSString* trimmed=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (group.general && trimmed.length && ![trimmed isEqual:@"General"]) {
        NSString* previousIdentifier=group.identifier;
        group.identifier=NSUUID.UUID.UUIDString;
        NSMutableArray* expanded=[[self sidebarWorkspaceState][@"expandedGroups"] mutableCopy];
        if ([expanded containsObject:previousIdentifier]) {
            [expanded removeObject:previousIdentifier]; [expanded addObject:group.identifier];
            [self sidebarWorkspaceState][@"expandedGroups"]=expanded;
        }
        group.colorName=spdf_tab_group_unused_color(_tabs);
        group.explicitGeneral=NO;
        [self sidebarWorkspaceState][@"newDocumentsInGeneral"]=@YES;
    }
    group.name = trimmed;
    [self finishTabGroupChange];
}
- (void)recolorTabGroup:(SPDFTabGroup*)group color:(NSString*)color {
    if (group.general || group.collectionBackups || ![spdf_tab_group_colors() containsObject:color]) return;
    group.colorName = color;
    [self finishTabGroupChange];
}
- (void)ungroupTabs:(SPDFTabGroup*)group {
    if (!group || group.general) return;
    if ([[self emptyTabGroups] containsObject:group]) { [self closeTabGroup:group]; return; }
    for (SPDFDocumentTab* tab in spdf_tab_group_members(_tabs, group)) tab.group = nil;
    [self finishTabGroupChange];
}
- (void)presentGroupCloseConfirmation:(NSAlert*)alert completion:(void (^)(NSModalResponse))completion {
    if (_window) [alert beginSheetModalForWindow:_window completionHandler:completion];
    else completion([alert runModal]);
}
- (void)requestCloseTabGroup:(SPDFTabGroup*)group {
    NSUInteger count=spdf_tab_group_members(_tabs,group).count;
    if ((!count && ![[self emptyTabGroups] containsObject:group]) || _window.attachedSheet) return;
    NSAlert* alert=[NSAlert new]; alert.alertStyle=NSAlertStyleWarning;
    alert.messageText=[NSString stringWithFormat:@"Close group “%@”?",group.displayName];
    alert.informativeText=[NSString stringWithFormat:@"This closes %lu %@ in this group. Files and Collection history are not deleted.",
        (unsigned long)count,count==1 ? @"document" : @"documents"];
    [alert addButtonWithTitle:@"Cancel"]; [alert addButtonWithTitle:@"Close Group"];
    [self presentGroupCloseConfirmation:alert completion:^(NSModalResponse response) {
        if (response==NSAlertSecondButtonReturn) [self closeTabGroup:group];
    }];
}
- (void)closeTabGroup:(SPDFTabGroup*)group {
    NSMutableArray* empty=(id)[self emptyTabGroups];
    if ([empty containsObject:group]) {
        [empty removeObject:group];
        if ([group.identifier isEqual:[self sidebarWorkspaceState][@"pendingNewGroupID"]])
            [[self sidebarWorkspaceState] removeObjectForKey:@"pendingNewGroupID"];
        [self finishTabGroupChange]; return;
    }
    NSArray* members = spdf_tab_group_members(_tabs, group);
    void (^closeMembers)(void) = ^{
        for (SPDFDocumentTab* tab in [members reverseObjectEnumerator]) {
            NSUInteger index = [self->_tabs indexOfObjectIdenticalTo:tab];
            if (index != NSNotFound) [self closeTabAtIndex:(NSInteger)index];
        }
    };
    if ([self deferClosingImageTabs:members action:closeMembers]) return;
    closeMembers();
}
- (void)moveTabGroup:(SPDFTabGroup*)group toIndex:(NSInteger)index {
    NSArray* members = spdf_tab_group_members(_tabs, group);
    if (!members.count) return;
    SPDFDocumentTab* selected = _selectedTabIndex >= 0 ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
    index = MAX(0, MIN(index, (NSInteger)_tabs.count));
    // A whole group inserts at a group boundary, never splits another group.
    if (index < (NSInteger)_tabs.count) {
        SPDFTabGroup* destination = _tabs[(NSUInteger)index].group;
        while (index > 0 && _tabs[(NSUInteger)index - 1].group == destination) --index;
    }
    NSInteger removedBefore = 0;
    for (NSInteger i = 0; i < index; ++i) if ([members containsObject:_tabs[(NSUInteger)i]]) ++removedBefore;
    [_tabs removeObjectsInArray:members];
    index = MAX(0, MIN(index - removedBefore, (NSInteger)_tabs.count));
    NSIndexSet* indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(index, members.count)];
    [_tabs insertObjects:members atIndexes:indexes];
    if (selected) _selectedTabIndex = [_tabs indexOfObjectIdenticalTo:selected];
    [self finishTabGroupChange];
}
- (void)moveTabAtIndex:(NSInteger)index toGroup:(SPDFTabGroup*)group atIndex:(NSInteger)destination {
    if (index < 0 || index >= (NSInteger)_tabs.count) return;
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    SPDFDocumentTab* selected = _selectedTabIndex >= 0 ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
    if (group) tab.group = group;
    else destination = spdf_tab_group_prepare_gap_drop(_tabs, tab, destination);
    [_tabs removeObjectAtIndex:index];
    if (destination > index) --destination;
    destination = MAX(0, MIN(destination, (NSInteger)_tabs.count));
    [_tabs insertObject:tab atIndex:destination];
    if (selected) _selectedTabIndex = [_tabs indexOfObjectIdenticalTo:selected];
    [self normalizeTabGroups];
    spdf_tab_groups_activate(_tabs, tab);
    [self selectTabAtIndex:[_tabs indexOfObjectIdenticalTo:tab]];
    [self finishTabGroupChange];
}
- (NSArray<NSDictionary*>*)snapshotTabGroup:(SPDFTabGroup*)group {
    [self rememberActiveTabState];
    NSMutableArray* result = [NSMutableArray array];
    for (SPDFDocumentTab* tab in spdf_tab_group_members(_tabs, group))
        [result addObject:spdf_dictionary_from_tab(tab, _window.windowNumber)];
    return result;
}
- (void)insertDraggedGroup:(NSArray<NSDictionary*>*)items atIndex:(NSInteger)index {
    // Decode before mutation. Cross-window groups keep identity so returning a
    // group to its originating window rejoins any tabs left there.
    NSMutableArray* incoming = [NSMutableArray array];
    for (id item in items) {
        SPDFDocumentTab* tab = spdf_tab_from_dictionary(item);
        if (tab) [incoming addObject:tab];
    }
    if (!incoming.count) return;
    [self rememberActiveTabState];
    SPDFDocumentTab* previous = _selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count
        ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
    index = MAX(0, MIN(index, (NSInteger)_tabs.count));
    if (index < (NSInteger)_tabs.count) {
        SPDFTabGroup* group = _tabs[(NSUInteger)index].group;
        while (index > 0 && _tabs[(NSUInteger)index - 1].group == group) --index;
    }
    SPDFDocumentTab* target = nil;
    for (SPDFDocumentTab* tab in incoming) {
        SPDFDocumentTab* existing = nil;
        for (SPDFDocumentTab* candidate in _tabs)
            if ([candidate.path.stringByStandardizingPath isEqualToString:tab.path.stringByStandardizingPath])
                { existing = candidate; break; }
        if (existing) { existing.group = tab.group; target = existing; continue; }
        [_tabs insertObject:tab atIndex:index++];
        if (!target || [tab.path isEqualToString:tab.group.lastUsedPath]) target = tab;
    }
    _selectedTabIndex = previous ? [_tabs indexOfObjectIdenticalTo:previous] : -1;
    [self normalizeTabGroups];
    [self selectTabAtIndex:[_tabs indexOfObjectIdenticalTo:target]];
    [self finishTabGroupChange];
}
- (void)detachTabGroup:(SPDFTabGroup*)group atScreenPoint:(NSPoint)point {
    NSArray* tabs = [self snapshotTabGroup:group];
    if (!tabs.count) return;
    NSString* path = tabs.firstObject[@"path"];
    NSString* executable = NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments.firstObject;
    if (!executable.length) return;
    NSRect frame = _window.frame;
    frame.origin = NSMakePoint(point.x - MIN(180.0, frame.size.width / 2), point.y - frame.size.height + 22);
    NSDictionary* handoff = @{@"tabs": tabs, @"frame": NSStringFromRect(frame)};
    NSString* handoffName = spdf_mac_detach_handoff_name(path);
    [self writeStateObject:handoff toFile:handoffName];
    // The shared writer has a void API. Read back before launching/closing:
    // a full disk or inaccessible state directory must leave the source intact.
    if (![[self stateObjectFromFile:handoffName] isEqual:handoff]) {
        [self showError:@"Could not move group to a new window"
                 detail:@"The group's reading positions could not be saved. The tabs remain in this window."];
        return;
    }
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"--detached-tab", path];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError* error = nil;
    if (![task launchAndReturnError:&error]) {
        [NSFileManager.defaultManager removeItemAtPath:[self pathForStateFile:spdf_mac_detach_handoff_name(path)] error:nil];
        [self showError:@"Could not move group to a new window" detail:error.localizedDescription];
        return;
    }
    [self closeTabGroup:group];
}
@end
