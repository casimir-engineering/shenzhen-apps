#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacCollectionHistory.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionRestoreTab.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacWorkspacePanels.h"
#import <objc/runtime.h>
@interface ShenzhenMacDelegate (CollectionRestoreHost)
- (void)rememberActiveTabState;
@end
static char historyControllerKey, historyWrapperKey, historyDocumentKey, historyDirtyKey;
@implementation ShenzhenMacDelegate (SPDFMacCollectionSidebar)
- (void)showCollectionHistory:(id)sender {
    NSString* path = [sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] isKindOfClass:NSString.class]
        ? [sender representedObject] : _path;
    SPDFMacCollectionStore* store = [SPDFMacCollectionStore defaultStore];
    NSDictionary* doc = [store documentForPath:path] ?: [store archiveInfoForPath:path][@"document"];
    if (!doc[@"id"]) { [self showCollectionManager:nil]; return; }
    [self selectedTab].collectionHistoryDocumentID = doc[@"id"];
    [self syncSidebarModeControlSegmentsForSearchAvailability:[self hasSearchSidebar]];
    _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeHistory;
    [self prioritizeWorkspaceSidebar];
    _sidebarPreferredVisible = YES; _sidebarWidth = MAX(280, _sidebarWidth);
    [self rememberSidebarWorkspaceMode]; [self collectionRememberSidebarMode]; [self rebuildSidebar];
}
- (void)collectionRememberSidebarMode {
    if (![self selectedTab].collectionHistoryDocumentID.length) return;
    NSString* path = [self selectedTab].path; if (!path.length) return;
    NSString* key = [self documentStateKeyForPath:path];
    NSMutableDictionary* state = [_documentStates[key] mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"collectionHistorySelected"] = @(_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeHistory);
    state[@"path"] = path; _documentStates[key] = state;
    [self savePersistentState];
}
- (void)collectionRemoveHistoryView {
    [(SPDFMacCollectionHistoryController*)objc_getAssociatedObject(self, &historyControllerKey) cancelPendingPreviews];
    [objc_getAssociatedObject(self, &historyWrapperKey) removeFromSuperview];
    objc_setAssociatedObject(self, &historyControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &historyWrapperKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &historyDocumentKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &historyDirtyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (BOOL)collectionShowSelectedHistoryPanel {
    NSString* identifier = [self selectedTab].collectionHistoryDocumentID;
    [self syncSidebarModeControlSegmentsForSearchAvailability:[self hasSearchSidebar]];
    BOOL visible = identifier.length && _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeHistory;
    NSView* wrapper = objc_getAssociatedObject(self, &historyWrapperKey);
    if (wrapper && ![identifier isEqual:objc_getAssociatedObject(self, &historyDocumentKey)]) {
        [self collectionRemoveHistoryView]; wrapper = nil;
    }
    _sidebarTable.enclosingScrollView.hidden = visible;
    if (!visible) {
        [(SPDFMacCollectionHistoryController*)objc_getAssociatedObject(self, &historyControllerKey) cancelPendingPreviews];
        wrapper.hidden = YES; return NO;
    }
    if (!_sidebarPreferredVisible) {
        [(SPDFMacCollectionHistoryController*)objc_getAssociatedObject(self, &historyControllerKey) cancelPendingPreviews];
        [self setSidebarActuallyVisible:NO];
        return YES;
    }
    _sidebarFilterField.hidden = YES;
    [_sidebarContainer viewWithTag:8801].hidden = YES;
    if (!wrapper) {
        __weak ShenzhenMacDelegate* weakSelf = self;
        SPDFMacCollectionHistoryController* controller = [[SPDFMacCollectionHistoryController alloc]
            initWithStore:SPDFMacCollectionStore.defaultStore documentID:identifier open:^(NSString* path, BOOL archived) {
                [weakSelf collectionOpenPath:path archived:archived];
                if ([[weakSelf selectedTab].path isEqual:path]) [weakSelf showCollectionHistory:nil];
            }];
        controller.showsDocumentTitle = NO;
        controller.restoreLinkHandler = ^(NSString* previousPath, NSString* restoredPath) {
            ShenzhenMacDelegate* reader = weakSelf; if (!reader) return;
            SPDFDocumentTab* missing = SPDFCollectionMissingTab(reader->_tabs,identifier,previousPath);
            SPDFDocumentTab* existing = SPDFCollectionExistingRestoredTab(reader->_tabs,restoredPath);
            if (missing && existing && missing != existing) {
                [reader rememberActiveTabState];
                SPDFDocumentTab* position = spdf_copy_document_tab(missing);
                [reader closeTabAtIndex:[reader->_tabs indexOfObjectIdenticalTo:missing]];
                SPDFCollectionRestoreReadingPosition(position,existing);
                NSInteger index = [reader->_tabs indexOfObjectIdenticalTo:existing];
                if (index == reader->_selectedTabIndex) [reader loadSelectedTab]; else [reader selectTabAtIndex:index];
                [reader savePersistentState];
            } else if (missing) {
                [reader discardCachedRuntimeForTab:missing];
                [reader collectionSetVersionInfo:nil forTab:missing];
                missing.workingPath=nil; missing.collectionVersionLabel=nil;
                missing.path = restoredPath; missing.title = restoredPath.lastPathComponent.stringByDeletingPathExtension;
                missing.missingFile = NO; missing.missingMessage = @""; missing.readOnly = NO;
                NSInteger index = [reader->_tabs indexOfObjectIdenticalTo:missing];
                if (index == reader->_selectedTabIndex) [reader loadSelectedTab]; else [reader selectTabAtIndex:index];
                [reader savePersistentState];
            } else [reader collectionOpenPath:restoredPath archived:NO];
            if ([[reader selectedTab].path isEqual:restoredPath]) [reader showCollectionHistory:nil];
        };
        controller.manageHandler = ^(NSString* documentID) {
            [weakSelf showCollectionManagerForDocumentID:documentID query:@""];
        };
        wrapper = controller.view; wrapper.translatesAutoresizingMaskIntoConstraints = NO;
        [_sidebarContainer addSubview:wrapper];
        wrapper.identifier = @"WorkspaceSidebarBody";
        [NSLayoutConstraint activateConstraints:@[
            [wrapper.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor],
            [wrapper.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor],
            [wrapper.topAnchor constraintEqualToAnchor:_sidebarModeControl.bottomAnchor constant:8],
            [wrapper.bottomAnchor constraintEqualToAnchor:_sidebarContainer.bottomAnchor]]];
        objc_setAssociatedObject(self, &historyControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &historyWrapperKey, wrapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &historyDocumentKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if ([objc_getAssociatedObject(self, &historyDirtyKey) boolValue]) {
        [(SPDFMacCollectionHistoryController*)objc_getAssociatedObject(self, &historyControllerKey) reload];
        objc_setAssociatedObject(self, &historyDirtyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    wrapper.hidden = NO;
    [self setSidebarActuallyVisible:_sidebarPreferredVisible];
    if (_sidebarVisible) [self restoreSidebarWidth];
    return YES;
}
- (void)collectionPrepareForTabPath:(NSString*)path {
    [(SPDFMacCollectionHistoryController*)objc_getAssociatedObject(self, &historyControllerKey) cancelPendingPreviews];
    // No store access on launch: the persisted tab ID is enough to restore the mode.
    NSString* key = [self documentStateKeyForPath:path];
    BOOL history = [_documentStates[key][@"collectionHistorySelected"] boolValue];
    [self syncSidebarModeControlSegmentsForSearchAvailability:NO];
    if (history && [self selectedTab].collectionHistoryDocumentID.length)
        _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeHistory;
    else if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeHistory)
        _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeChapters;
    [self applySidebarWorkspaceState];
}
- (void)collectionRefreshHistory {
    // The normal capture completion calls this after opening; do not add store work to launch.
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    NSDictionary* doc = [store documentForPath:_path] ?: [store archiveInfoForPath:_path][@"document"];
    [self collectionRefreshVersionInfoForDocument:doc];
    [self selectedTab].collectionHistoryDocumentID = doc[@"id"];
    SPDFMacCollectionHistoryController* controller = objc_getAssociatedObject(self, &historyControllerKey);
    if ([doc[@"id"] isEqual:objc_getAssociatedObject(self, &historyDocumentKey)]) {
        if (_sidebarPreferredVisible && _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeHistory) [controller reload];
        else objc_setAssociatedObject(self, &historyDirtyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self rebuildSidebar];
}
@end
