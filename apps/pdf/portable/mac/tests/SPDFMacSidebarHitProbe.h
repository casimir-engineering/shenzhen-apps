#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SidebarHitProbe)
- (NSUInteger)probeHistoryMouseClicks;
- (NSUInteger)probePanelDividerTargets;
@end

void spdf_sidebar_probe_install_order_guard(void);
