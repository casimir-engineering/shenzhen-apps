#import "SPDFMacAgentGroups.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacSidebarWorkspace.h"

@interface ShenzhenMacDelegate (SPDFMacAgentGroupBatch)
- (void)rememberActiveTabState;
- (void)finishTabGroupChange;
@end

static NSDictionary* GroupError(NSString* message) { return @{@"error":message}; }
@implementation ShenzhenMacDelegate (SPDFMacAgentGroups)
- (SPDFTabGroup*)agentGroupWithID:(NSString*)identifier {
    for (SPDFDocumentTab* tab in _tabs) if ([tab.group.identifier isEqual:identifier]) return tab.group;
    for (SPDFTabGroup* group in [self emptyTabGroups]) if ([group.identifier isEqual:identifier]) return group;
    return nil;
}
- (SPDFDocumentTab*)agentTabWithPath:(NSString*)path {
    for (SPDFDocumentTab* tab in _tabs)
        if ([tab.path.stringByStandardizingPath isEqual:path]) return tab;
    return nil;
}
- (NSDictionary*)agentGroupSnapshot {
    NSMutableArray* groups=[NSMutableArray array]; NSMutableArray* tabs=[NSMutableArray array];
    NSMutableDictionary* byID=[NSMutableDictionary dictionary];
    for (NSUInteger i=0;i<_tabs.count;i++) {
        SPDFDocumentTab* tab=_tabs[i]; SPDFTabGroup* group=tab.group;
        NSDictionary* item=@{@"path":tab.path ?: @"",@"title":tab.title ?: @"",@"index":@(i+1),
            @"groupID":group.identifier ?: (id)NSNull.null,@"selected":@(i==(NSUInteger)_selectedTabIndex),
            @"readOnly":@(tab.readOnly),@"missingFile":@(tab.missingFile)};
        [tabs addObject:item];
        if (!group) continue;
        NSMutableDictionary* row=byID[group.identifier];
        if (!row) {
            row=[group.dictionary mutableCopy]; row[@"displayName"]=group.displayName;
            row[@"general"]=@(group.general); row[@"paths"]=[NSMutableArray array];
            row[@"position"]=@(groups.count+1); byID[group.identifier]=row; [groups addObject:row];
        }
        [row[@"paths"] addObject:tab.path ?: @""];
    }
    for (SPDFTabGroup* group in [self emptyTabGroups]) if (!byID[group.identifier]) {
        NSMutableDictionary* row=[group.dictionary mutableCopy]; row[@"displayName"]=group.displayName;
        row[@"general"]=@NO; row[@"paths"]=@[]; row[@"position"]=@(groups.count+1); [groups addObject:row];
    }
    return @{@"windowSessionID":_windowSessionID ?: @"",@"groups":groups,@"tabs":tabs,
             @"colors":spdf_tab_group_colors(),
             @"newDocumentsInGeneral":@([[self sidebarWorkspaceState][@"newDocumentsInGeneral"] boolValue])};
}
- (NSDictionary*)performAgentGroupCommand:(NSDictionary*)command {
    if ([command[@"windowSessionID"] length] && ![command[@"windowSessionID"] isEqual:_windowSessionID])
        return GroupError(@"The command reached a different reader window. List groups in the intended window first.");
    NSString* action=command[@"action"];
    if ([action isEqual:@"list-groups"]) return [self agentGroupSnapshot];
    SPDFTabGroup* group=[self agentGroupWithID:command[@"groupID"]];
    SPDFTabGroup* before=[self agentGroupWithID:command[@"beforeGroupID"]];
    BOOL implicitGeneral=!group && [command[@"groupID"] isEqual:@"general"] && _tabs.count && !_tabs.firstObject.group &&
        ([@[@"update-group",@"jump-group"] containsObject:action]);
    if (command[@"groupID"] && !group && !implicitGeneral) return GroupError(@"Group no longer exists. List groups again.");
    if (command[@"beforeGroupID"] && !before) return GroupError(@"Destination group no longer exists. List groups again.");
    NSString* name=[command[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL promotesGeneral=(group.general || implicitGeneral) && name.length && ![name isEqual:@"General"];
    if (command[@"color"] && (![spdf_tab_group_colors() containsObject:command[@"color"]] || ((group.general || implicitGeneral) && !promotesGeneral)))
        return GroupError(@"Use a color returned by list-groups. General keeps its fixed gray color.");
    if (implicitGeneral) group=[self ensureGeneralTabGroup];
    NSString* affected=nil;
    if ([action isEqual:@"create-group"]) {
        NSMutableArray<SPDFDocumentTab*>* members=[NSMutableArray array];
        for (NSString* path in command[@"paths"]) {
            SPDFDocumentTab* tab=[self agentTabWithPath:path];
            if (!tab) return GroupError(@"Every requested document must already be open in this reader window.");
            [members addObject:tab];
        }
        if (before) {
            BOOL survives=NO;
            for (SPDFDocumentTab* tab in _tabs) if (tab.group==before && ![members containsObject:tab]) survives=YES;
            if (!survives && ![[self emptyTabGroups] containsObject:before]) return GroupError(@"The destination group would be emptied by this creation. Choose another destination.");
        }
        // A batch must not open/render every member or serialize the session
        // once per tab. Keep the normal final-selection behavior, with one commit.
        [self rememberActiveTabState];
        SPDFDocumentTab* active=_selectedTabIndex>=0 && _selectedTabIndex<(NSInteger)_tabs.count
            ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
        group=[SPDFTabGroup groupWithColor:command[@"color"] ?: spdf_tab_group_unused_color(_tabs)];
        group.name=name ?: @"";
        for (SPDFDocumentTab* tab in members) tab.group=group;
        [_tabs removeObjectsInArray:members];
        NSUInteger position=before ? [_tabs indexOfObjectIdenticalTo:spdf_tab_group_members(_tabs,before).firstObject] : _tabs.count;
        if (position==NSNotFound) position=_tabs.count;
        [_tabs insertObjects:members atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(position,members.count)]];
        if (active) _selectedTabIndex=[_tabs indexOfObjectIdenticalTo:active];
        [self normalizeTabGroups];
        spdf_tab_groups_activate(_tabs,members.lastObject);
        [self selectTabAtIndex:[_tabs indexOfObjectIdenticalTo:members.lastObject]];
        [self finishTabGroupChange]; affected=group.identifier;
    } else if ([action isEqual:@"update-group"]) {
        if (command[@"name"]) [self renameTabGroup:group name:command[@"name"]];
        if (command[@"color"]) [self recolorTabGroup:group color:command[@"color"]];
        if (command[@"collapsed"] && group.collapsed != [command[@"collapsed"] boolValue]) [self toggleTabGroup:group];
        if (command[@"hidden"]) [self setTabGroup:group hidden:[command[@"hidden"] boolValue]];
        affected=group.identifier;
    } else if ([action isEqual:@"move-tab"]) {
        SPDFDocumentTab* tab=[self agentTabWithPath:command[@"path"]];
        SPDFDocumentTab* beforeTab=[self agentTabWithPath:command[@"beforePath"]];
        if (!tab) return GroupError(@"Document is not open in this reader window.");
        if (command[@"beforePath"] && (!beforeTab || beforeTab.group!=group))
            return GroupError(@"beforePath must identify an open tab in the destination group.");
        NSArray* members=spdf_tab_group_members(_tabs,group);
        NSInteger destination=beforeTab ? [_tabs indexOfObjectIdenticalTo:beforeTab] :
            (members.count ? [_tabs indexOfObjectIdenticalTo:members.lastObject]+1 : _tabs.count);
        [self moveTabAtIndex:[_tabs indexOfObjectIdenticalTo:tab] toGroup:group atIndex:destination];
        affected=group.identifier;
    } else if ([action isEqual:@"move-group"]) {
        if (before!=group) [self moveTabGroup:group toIndex:before ?
            [_tabs indexOfObjectIdenticalTo:spdf_tab_group_members(_tabs,before).firstObject] : _tabs.count];
        affected=group.identifier;
    } else if ([action isEqual:@"jump-group"]) {
        [self jumpTabGroup:group]; affected=group.identifier;
    } else if ([action isEqual:@"ungroup"]) {
        if (group.general) return GroupError(@"General cannot be ungrouped.");
        [self ungroupTabs:group];
    } else return GroupError(@"Unsupported group action.");
    NSMutableDictionary* result=[[self agentGroupSnapshot] mutableCopy];
    if (affected) result[@"groupID"]=affected;
    return result;
}
@end
