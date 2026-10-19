#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacWorkspaceChrome)
- (void)installWorkspaceChrome;
- (void)syncWorkspaceChrome;
- (void)revealWorkspaceFind;
- (void)showGroupsSidebar:(id)sender;
@end

NSButton* SPDFWorkspaceRegexCheckbox(id target,SEL action);
