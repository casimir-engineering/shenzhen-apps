#import "SPDFMacWorkspacePanels.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacSidebarWorkspace.h"
#import <objc/runtime.h>

static char panelPolicyKey;
@interface SPDFWorkspacePanelPolicy : NSObject
@property BOOL sidebarRequested;
@property BOOL mapRequested;
@property BOOL applying;
@property BOOL sidebarConfigured;
@property BOOL mapConfigured;
@property NSUInteger applicationCount;
@end
@implementation SPDFWorkspacePanelPolicy
@end

@interface ShenzhenMacDelegate (WorkspacePanelGeometry)
- (CGFloat)clampedSidebarWidth;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ShenzhenMacDelegate (SPDFMacWorkspacePanels)
- (SPDFWorkspacePanelPolicy*)workspacePanelPolicy {
    SPDFWorkspacePanelPolicy* state = objc_getAssociatedObject(self,&panelPolicyKey);
    if (!state) {
        state = [SPDFWorkspacePanelPolicy new];
        state.sidebarRequested = _sidebarPreferredVisible;
        state.mapRequested = _minimapPreferredVisible;
        objc_setAssociatedObject(self,&panelPolicyKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}
- (BOOL)workspacePanelPolicyIsApplying {
    return [(SPDFWorkspacePanelPolicy*)objc_getAssociatedObject(self,&panelPolicyKey) applying];
}
- (void)prioritizeWorkspaceSidebar { [self sidebarWorkspaceState][@"compactPanel"] = @"sidebar"; }
- (void)prioritizeWorkspaceMap { [self sidebarWorkspaceState][@"compactPanel"] = @"map"; }
- (void)setSidebarActuallyVisible:(BOOL)visible {
    SPDFWorkspacePanelPolicy* state = [self workspacePanelPolicy];
    if (state.applying) return;
    state.sidebarRequested = visible;
    NSUInteger before = state.applicationCount;
    [self applyWorkspacePanelPolicy];
    if (before == state.applicationCount) { [self syncToolbarState]; [self updateControls]; }
}
- (void)setMinimapActuallyVisible:(BOOL)visible {
    SPDFWorkspacePanelPolicy* state = [self workspacePanelPolicy];
    if (state.applying) return;
    state.mapRequested = visible;
    NSUInteger before = state.applicationCount;
    [self applyWorkspacePanelPolicy];
    if (before == state.applicationCount) [self syncToolbarState];
}
- (void)applyWorkspacePanelPolicy {
    SPDFWorkspacePanelPolicy* state = objc_getAssociatedObject(self,&panelPolicyKey);
    if (!state || state.applying || !_splitView) return;
    BOOL sidebar = state.sidebarRequested, map = state.mapRequested && [self hasActiveDocument];
    CGFloat width = NSWidth(_splitView.bounds);
    CGFloat sidebarWidth = [self clampedSidebarWidth];
    CGFloat chatWidth=[self aiChatReservedWidth];
    // Temporarily yield auxiliary space to chat; retain the user's panel preferences.
    if(chatWidth>0 && width>0) {
        width-=chatWidth;
        if(sidebar && width-sidebarWidth<280)sidebar=NO;
        if(map && width-(sidebar ? sidebarWidth : 0)-_minimapWidth-8<280)map=NO;
    }
    // This is a layout budget, not a stored preference or a new document zoom.
    // The active navigation panel wins while there is insufficient reading room.
    if (sidebar && map && width > 0 && width-sidebarWidth-_minimapWidth-8 < 320) {
        if ([[self sidebarWorkspaceState][@"compactPanel"] isEqual:@"map"]) sidebar = NO; else map = NO;
    }
    BOOL sidebarReady = _sidebarContainer && _documentContainer;
    BOOL mapReady = _minimapView && _minimapWidthConstraint && _minimapDividerView &&
        _pageScrollFullWidthConstraint && _pageScrollToMinimapConstraint;
    BOOL updateSidebar = sidebarReady && (!state.sidebarConfigured || sidebar != _sidebarVisible);
    BOOL mapConstraintsMatch = map ? (!_pageScrollFullWidthConstraint.active && _pageScrollToMinimapConstraint.active)
                                  : (_pageScrollFullWidthConstraint.active && !_pageScrollToMinimapConstraint.active);
    BOOL updateMap = mapReady && (!state.mapConfigured || map != _minimapVisible || !mapConstraintsMatch ||
        _minimapWidthConstraint.constant != (map ? _minimapWidth : 0));
    if (!updateSidebar && !updateMap) return;
    state.applying = YES;
    BOOL persistWidth = _allowSidebarWidthPersistence;
    _allowSidebarWidthPersistence = NO;
    // Remove the losing panel first; avoid an intermediate squeezed viewport.
    if (updateSidebar && !sidebar) [self setWorkspaceSidebarVisibleWithoutPolicy:NO];
    if (updateMap && !map) [self setWorkspaceMapVisibleWithoutPolicy:NO];
    if (updateSidebar && sidebar) [self setWorkspaceSidebarVisibleWithoutPolicy:YES];
    if (updateMap && map) [self setWorkspaceMapVisibleWithoutPolicy:YES];
    state.sidebarConfigured |= updateSidebar; state.mapConfigured |= updateMap;
    state.applicationCount++;
    _allowSidebarWidthPersistence = persistWidth;
    state.applying = NO;
}
@end

#pragma clang diagnostic pop
