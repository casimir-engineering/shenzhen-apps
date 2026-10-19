#pragma once
#import "SPDFMacTabGroupIntegration.h"

// Link the production category onto a headless delegate. Its document loading
// and disk boundary are replaced; group mutations and codec paths are real.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ShenzhenMacDelegate
@end
#pragma clang diagnostic pop

@interface GroupReaderProbe : ShenzhenMacDelegate
@property(nonatomic, copy) NSString* activePath;
@property(nonatomic) NSMutableDictionary* workspace;
@property(nonatomic, strong) NSArray* savedTabs;
@property(nonatomic) NSInteger saveCount;
@property(nonatomic) NSInteger stripRefreshCount;
@property(nonatomic) NSInteger handoffWriteCount;
@property(nonatomic) NSInteger errorCount;
@property NSModalResponse closeResponse;
@property NSAlert* closeAlert;
- (void)seed:(NSArray*)tabs selected:(NSInteger)index;
- (NSArray*)tabs;
- (NSInteger)selectedIndex;
@end
@implementation GroupReaderProbe
// Save/alert behavior is exercised by SPDFMacUnsavedImageCloseTests. These
// group fixtures contain saved documents and have no asynchronous close gate.
- (BOOL)deferClosingImageTabs:(NSArray<SPDFDocumentTab*>*)tabs action:(void (^)(void))action {
    (void)action;
    for (SPDFDocumentTab* tab in tabs) NSCAssert(!tab.unsavedPastedImage, @"saved-document fixture required");
    return NO;
}
- (void)presentGroupCloseConfirmation:(NSAlert*)alert completion:(void (^)(NSModalResponse))completion {
    self.closeAlert=alert; completion(self.closeResponse);
}
- (void)seed:(NSArray*)tabs selected:(NSInteger)index {
    _tabs = [tabs mutableCopy];
    _selectedTabIndex = index;
    self.activePath = index >= 0 ? _tabs[(NSUInteger)index].path : nil;
}
- (NSArray*)tabs { return _tabs; }
- (NSInteger)selectedIndex { return _selectedTabIndex; }
- (void)rememberActiveTabState {}
- (void)collectionRememberGroups {}
- (NSMutableDictionary*)sidebarWorkspaceState { if (!self.workspace) self.workspace=[NSMutableDictionary dictionary]; return self.workspace; }
- (void)writeStateObject:(id)object toFile:(NSString*)name {
    (void)object; (void)name; self.handoffWriteCount++;
}
- (id)stateObjectFromFile:(NSString*)name { (void)name; return nil; }
- (void)showError:(NSString*)message detail:(NSString*)detail { (void)message; (void)detail; self.errorCount++; }
- (void)updateTabStrip { self.stripRefreshCount++; }
- (void)refreshSidebarWorkspacePanel {}
- (void)savePersistentState {
    self.saveCount++;
    NSMutableArray* encoded = [NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) [encoded addObject:spdf_dictionary_from_tab(tab, 0)];
    self.savedTabs = encoded;
}
- (void)selectTabAtIndex:(NSInteger)index {
    // The real reader short-circuits selecting the current index. Incoming
    // groups must update that index when inserting before the active tab.
    if (index == _selectedTabIndex && self.activePath.length) return;
    _selectedTabIndex = index;
    self.activePath = _tabs[(NSUInteger)index].path;
    [self activateSelectedTabGroup];
}
- (void)closeTabAtIndex:(NSInteger)index {
    SPDFDocumentTab* current = _selectedTabIndex >= 0 ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
    [_tabs removeObjectAtIndex:index];
    _selectedTabIndex = current && [_tabs containsObject:current] ? [_tabs indexOfObjectIdenticalTo:current] : -1;
    [self normalizeTabGroups];
    [self savePersistentState];
}
@end
