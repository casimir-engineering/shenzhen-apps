#pragma once
#import "SPDFMacDelegatePrivate.h"

@interface ShenzhenMacDelegate (SPDFMacWorkspacePanels)
// Requested visibility remains independent of compact-window presentation.
- (void)applyWorkspacePanelPolicy;
- (void)prioritizeWorkspaceSidebar;
- (void)prioritizeWorkspaceMap;
- (BOOL)workspacePanelPolicyIsApplying;
@end

@interface ShenzhenMacDelegate (SPDFMacWorkspacePanelPrimitives)
- (void)setWorkspaceSidebarVisibleWithoutPolicy:(BOOL)visible;
- (void)setWorkspaceMapVisibleWithoutPolicy:(BOOL)visible;
@end
