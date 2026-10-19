#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacSidebarWorkspace)
- (NSMutableDictionary*)sidebarWorkspaceState;
- (NSDictionary*)sidebarWorkspaceSnapshot;
- (void)restoreSidebarWorkspaceState:(id)value;
- (void)applySidebarWorkspaceState;
- (void)rememberSidebarWorkspaceMode;
- (void)syncSidebarNavigationAvailability;
- (BOOL)showSidebarWorkspacePanel;
- (void)refreshSidebarWorkspacePanel;
@end
