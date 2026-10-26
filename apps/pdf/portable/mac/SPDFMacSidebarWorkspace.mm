#import "SPDFMacAIIntegration.h"
#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacGroupManagement.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import <objc/runtime.h>

static char stateKey, groupsControllerKey, emptySearchKey, saveGenerationKey, tabScrollSaveGenerationKey;
@interface ShenzhenMacDelegate (SidebarWorkspaceHost)
- (void)selectTabAtIndex:(NSInteger)index;
- (void)savePersistentState;
@end
@interface SPDFTabStripView (SidebarDocumentMenu)
- (NSMenu*)contextMenuForTabAtIndex:(NSInteger)index;
@end
@implementation ShenzhenMacDelegate (SPDFMacSidebarWorkspace)
- (NSMutableDictionary*)sidebarWorkspaceState {
    NSMutableDictionary* state = objc_getAssociatedObject(self,&stateKey);
    if (!state) { state = [NSMutableDictionary dictionary]; objc_setAssociatedObject(self,&stateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return state;
}
- (NSDictionary*)sidebarWorkspaceSnapshot {
    [self syncEmptyTabGroups];
    NSMutableDictionary* state = [[self sidebarWorkspaceState] mutableCopy];
    if (_sidebarModeControl) state[@"mode"] = @(_sidebarModeControl.spdf_selectedSidebarMode);
    if (_tabStrip && _tabStrip.tabScrollDidChange) state[@"tabStripScroll"] = @(_tabStrip.tabScrollOffset);
    state[@"width"] = @(_sidebarWidth); state[@"visible"] = @(_sidebarPreferredVisible);
    return state;
}
- (void)restoreSidebarWorkspaceState:(id)value {
    NSMutableDictionary* state = [NSMutableDictionary dictionary];
    if ([value isKindOfClass:NSDictionary.class]) {
        for (NSString* key in @[@"mode",@"groupScroll",@"width",@"visible",@"newDocumentsInGeneral",@"groupSearchCollapsed",@"chatWidth"])
            if ([value[key] isKindOfClass:NSNumber.class]) state[key] = value[key];
        id tabScroll=value[@"tabStripScroll"];
        if ([tabScroll isKindOfClass:NSNumber.class] && isfinite([tabScroll doubleValue]) && [tabScroll doubleValue]>=0)
            state[@"tabStripScroll"]=tabScroll;
        if ([value[@"emptyGroups"] isKindOfClass:NSArray.class]) {
            NSMutableArray* groups=[NSMutableArray array];
            for (id raw in value[@"emptyGroups"]) {
                SPDFTabGroup* group=[SPDFTabGroup fromDictionary:raw];
                if (group && !group.general && !group.collectionBackups) [groups addObject:group.dictionary];
            }
            if (groups.count) state[@"emptyGroups"]=groups;
        }
        if ([value[@"pendingNewGroupID"] isKindOfClass:NSString.class]) state[@"pendingNewGroupID"]=value[@"pendingNewGroupID"];
        if ([value[@"groupQuery"] isKindOfClass:NSString.class]) state[@"groupQuery"] = value[@"groupQuery"];
        if ([@[@"sidebar",@"map"] containsObject:value[@"compactPanel"] ?: @""]) state[@"compactPanel"] = value[@"compactPanel"];
        NSMutableArray* expanded = [NSMutableArray array];
        for (id entry in [value[@"expandedGroups"] isKindOfClass:NSArray.class] ? value[@"expandedGroups"] : @[])
            if ([entry isKindOfClass:NSString.class]) [expanded addObject:entry];
        state[@"expandedGroups"] = expanded;
    }
    objc_setAssociatedObject(self,&stateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self resetEmptyTabGroups];
    double width = [state[@"width"] doubleValue];
    if (isfinite(width) && width >= 160 && width <= 800) _sidebarWidth = width;
    if (state[@"visible"]) _sidebarPreferredVisible = [state[@"visible"] boolValue];
}
- (void)applySidebarWorkspaceState {
    NSDictionary* state = [self sidebarWorkspaceState];
    if (state[@"mode"]) _sidebarModeControl.spdf_selectedSidebarMode = [state[@"mode"] integerValue];
    if (_tabStrip && !_tabStrip.tabScrollDidChange) {
        if (state[@"tabStripScroll"]) _tabStrip.tabScrollOffset=[state[@"tabStripScroll"] doubleValue];
        __weak ShenzhenMacDelegate* weakSelf=self;
        _tabStrip.tabScrollDidChange=^(CGFloat offset) {
            ShenzhenMacDelegate* owner=weakSelf; if(!owner) return;
            [owner sidebarWorkspaceState][@"tabStripScroll"]=@(offset);
            // Save once after the gesture settles, never once per wheel event.
            NSUInteger generation=[objc_getAssociatedObject(owner,&tabScrollSaveGenerationKey) unsignedIntegerValue]+1;
            objc_setAssociatedObject(owner,&tabScrollSaveGenerationKey,@(generation),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
                if ([objc_getAssociatedObject(owner,&tabScrollSaveGenerationKey) unsignedIntegerValue]==generation)
                    [owner savePersistentState];
            });
        };
    }
}
- (void)rememberSidebarWorkspaceMode {
    NSMutableDictionary* state = [self sidebarWorkspaceState];
    state[@"mode"] = @(_sidebarModeControl.spdf_selectedSidebarMode);
    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeGroups) {
        NSString* activeGroup = [self selectedTab].group.identifier ?: @"general";
        NSMutableSet* expanded = [NSMutableSet setWithArray:state[@"expandedGroups"] ?: @[]];
        [expanded addObject:activeGroup];
        state[@"expandedGroups"] = [expanded.allObjects sortedArrayUsingSelector:@selector(compare:)];
    }
    state[@"width"] = @(_sidebarWidth); state[@"visible"] = @(_sidebarPreferredVisible);
    [self savePersistentState];
}
- (void)syncSidebarNavigationAvailability {
    BOOL markdown = [self isMarkdownActive];
    BOOL hasSearch = markdown ? [self markdownHasSearchSidebar] : [self hasSearchSidebar];
    [self syncSidebarModeControlSegmentsForSearchAvailability:hasSearch];
    spdf_sidebar_mode_control_set_document_availability(_sidebarModeControl,
        markdown ? [self markdownHasChapters] : (_outline.count > 0 || [self aiGeneratedChapterRows].count > 0), !markdown && _comments.count > 0);
}
- (NSArray<NSDictionary*>*)sidebarGroupSnapshots {
    NSMutableArray* groups = [NSMutableArray array]; NSMutableDictionary* lookup = [NSMutableDictionary dictionary];
    for (SPDFDocumentTab* tab in _tabs) {
        SPDFTabGroup* group = tab.group; NSString* identifier = group.identifier ?: @"general";
        NSMutableDictionary* row = lookup[identifier];
        if (!row) {
            row = [@{@"id":identifier,@"name":group.displayName ?: @"General",@"color":group.colorName ?: @"Gray",
                @"collapsed":@(group.collapsed),@"hidden":@(group.hidden),@"selected":@NO,@"documents":[NSMutableArray array]} mutableCopy];
            lookup[identifier] = row; [groups addObject:row];
        }
        BOOL selected = tab == [self selectedTab]; if (selected) row[@"selected"] = @YES;
        [row[@"documents"] addObject:@{@"path":tab.path ?: @"",@"title":spdf_tab_display_name(tab) ?: tab.title ?: tab.path.lastPathComponent ?: @"Document",@"selected":@(selected)}];
    }
    for (SPDFTabGroup* group in [self emptyTabGroups]) if (!lookup[group.identifier])
        [groups addObject:@{@"id":group.identifier,@"name":group.displayName,@"color":group.colorName,
            @"collapsed":@(group.collapsed),@"hidden":@(group.hidden),@"selected":@NO,@"documents":@[]}];
    return groups;
}
- (void)performSidebarGroupAction:(NSString*)action identifier:(NSString*)identifier value:(NSString*)value {
    if ([action isEqual:@"end-search"]) { [_window makeFirstResponder:[self activeDocumentKeyView]]; return; }
    SPDFTabGroup* group = nil;
    for (SPDFDocumentTab* tab in _tabs) if ([tab.group.identifier isEqual:identifier]) { group = tab.group; break; }
    if (!group) for (SPDFTabGroup* empty in [self emptyTabGroups])
        if ([empty.identifier isEqual:identifier]) { group=empty; break; }
    if (!group && [identifier isEqual:@"general"]) group = [self ensureGeneralTabGroup];
    if (!group) return;
    if ([action isEqual:@"collapse"]) [self toggleTabGroup:group];
    else if ([action isEqual:@"visibility"]) [self setTabGroup:group hidden:!group.hidden];
    else if ([action isEqual:@"close"]) [self requestCloseTabGroup:group];
    else if ([action isEqual:@"rename"]) [self renameTabGroup:group name:value];
    else if ([action isEqual:@"move-document"]) {
        NSDictionary* source = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![source isKindOfClass:NSDictionary.class]) return;
        NSUInteger index = NSNotFound, destination = 0;
        for (NSUInteger i=0;i<_tabs.count;i++) {
            if ([_tabs[i].path isEqual:source[@"path"]] && [_tabs[i].group.identifier isEqual:source[@"source"]]) index = i;
            if ([_tabs[i].group.identifier isEqual:identifier]) destination = i+1;
        }
        if (index == NSNotFound) return;
        if ([source[@"before"] length]) for(NSUInteger i=0;i<_tabs.count;i++)
            if([_tabs[i].group.identifier isEqual:identifier] && [_tabs[i].path isEqual:source[@"before"]]) { destination=i; break; }
        group.hidden = NO;
        [self moveTabAtIndex:index toGroup:group atIndex:destination];
    }
    else if ([action isEqual:@"document"]) {
        if(group.hidden) group.hidden=NO;
        for (NSUInteger i=0;i<_tabs.count;i++) if ([_tabs[i].path isEqual:value] && [_tabs[i].group.identifier isEqual:identifier]) { [self selectTabAtIndex:i]; break; }
    } else [self jumpTabGroup:group];
    // Management remains open while its explicit group/document navigation runs.
    _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeGroups; _sidebarPreferredVisible = YES;
    [self rememberSidebarWorkspaceMode]; [self rebuildSidebar];
}
- (void)refreshSidebarWorkspacePanel {
    // The panel's own hidden flag tracks its mode, not its hidden ancestor.
    // Defer snapshots until reveal when the whole sidebar is closed.
    if (!_sidebarPreferredVisible) return;
    SPDFGroupManagementController* controller = objc_getAssociatedObject(self,&groupsControllerKey);
    if (controller && !controller.view.hidden)
        [controller updateGroups:[self sidebarGroupSnapshots] state:[self sidebarWorkspaceState]];
}
- (void)attachSidebarWorkspaceView:(NSView*)view {
    view.identifier = @"WorkspaceSidebarBody";
    view.translatesAutoresizingMaskIntoConstraints = NO; [_sidebarContainer addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:_sidebarModeControl.bottomAnchor constant:(_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch ? 78 : 4)],
        [view.bottomAnchor constraintEqualToAnchor:_sidebarContainer.bottomAnchor]]];
}
- (void)focusSidebarSearch:(id)sender { (void)sender; [_window makeFirstResponder:_searchField]; }
- (BOOL)showSidebarWorkspacePanel {
    NSInteger mode = _sidebarModeControl.spdf_selectedSidebarMode;
    BOOL groups = mode == SPDFSidebarModeGroups;
    BOOL emptySearch = mode == SPDFSidebarModeSearch && ![self hasSearchSidebar];
    SPDFGroupManagementController* controller = objc_getAssociatedObject(self,&groupsControllerKey);
    NSView* searchView = objc_getAssociatedObject(self,&emptySearchKey);
    BOOL enteringGroups = groups && (!controller || controller.view.hidden || !_sidebarVisible);
    controller.view.hidden = !groups; searchView.hidden = !emptySearch;
    BOOL chats=[self showAIChatSidebarIfSelected];
    if (!groups && !emptySearch && !chats) return NO;
    if (!_sidebarPreferredVisible) { [self setSidebarActuallyVisible:NO]; return YES; }
    [self collectionShowSelectedHistoryPanel];
    _sidebarTable.enclosingScrollView.hidden = YES; _sidebarFilterField.hidden = YES;
    [_sidebarContainer viewWithTag:8801].hidden = YES;
    if (chats) { [self setSidebarActuallyVisible:_sidebarPreferredVisible]; return YES; }
    if (groups) {
        if (!controller) {
            controller = [SPDFGroupManagementController new]; __weak ShenzhenMacDelegate* weakSelf = self;
            controller.actionHandler = ^(NSString* action,NSString* identifier,NSString* value) {
                [weakSelf performSidebarGroupAction:action identifier:identifier value:value];
            };
            controller.documentMenuProvider = ^NSMenu*(NSString* path,NSString* groupID) {
                ShenzhenMacDelegate* owner=weakSelf; if(!owner) return nil;
                for(NSUInteger i=0;i<owner->_tabs.count;i++)
                    if([owner->_tabs[i].path isEqual:path] && [owner->_tabs[i].group.identifier isEqual:groupID])
                        return [owner->_tabStrip contextMenuForTabAtIndex:i];
                return nil;
            };
            controller.stateHandler = ^(NSDictionary* state) {
                ShenzhenMacDelegate* owner = weakSelf; if (!owner) return;
                [[owner sidebarWorkspaceState] addEntriesFromDictionary:state];
                NSUInteger generation = [objc_getAssociatedObject(owner,&saveGenerationKey) unsignedIntegerValue]+1;
                objc_setAssociatedObject(owner,&saveGenerationKey,@(generation),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
                    if ([objc_getAssociatedObject(owner,&saveGenerationKey) unsignedIntegerValue] == generation) [owner savePersistentState];
                });
            };
            [self attachSidebarWorkspaceView:controller.view];
            objc_setAssociatedObject(self,&groupsControllerKey,controller,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        controller.view.hidden = NO; [self refreshSidebarWorkspacePanel];
        if (enteringGroups) [controller revealSelectedDocument];
    } else if (!searchView) {
        NSTextField* title = [NSTextField labelWithString:@"Find in this document"];
        title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        NSTextField* help = [NSTextField wrappingLabelWithString:@"Type above to find text in this document. Results will appear here."];
        help.textColor = NSColor.secondaryLabelColor;
        NSStackView* stack = [NSStackView stackViewWithViews:@[title,help]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.alignment = NSLayoutAttributeLeading; stack.spacing = 10;
        searchView = [NSView new]; [self attachSidebarWorkspaceView:searchView];
        stack.translatesAutoresizingMaskIntoConstraints = NO; [searchView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:searchView.leadingAnchor constant:16],
            [stack.trailingAnchor constraintEqualToAnchor:searchView.trailingAnchor constant:-16],
            [stack.topAnchor constraintEqualToAnchor:searchView.topAnchor constant:20]]];
        objc_setAssociatedObject(self,&emptySearchKey,searchView,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self setSidebarActuallyVisible:_sidebarPreferredVisible]; if (_sidebarVisible) [self restoreSidebarWidth];
    return YES;
}
@end
