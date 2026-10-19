#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacTabGroups.h"
BOOL SPDFSessionHasEmptyTabGroups(id windowState);
@interface ShenzhenMacDelegate (SPDFMacTabGroupIntegration) <SPDFTabGroupReader>
// Empty groups are real workspace objects, never placeholder document tabs.
- (NSArray<SPDFTabGroup*>*)emptyTabGroups;
- (void)resetEmptyTabGroups;
- (void)syncEmptyTabGroups;
- (SPDFTabGroup*)createEmptyTabGroup;
- (SPDFTabGroup*)pendingNewDocumentGroup;
- (SPDFTabGroup*)ensureGeneralTabGroup;
- (void)normalizeTabGroups;
- (void)activateSelectedTabGroup;
- (NSInteger)appendNewTabToActiveGroup:(SPDFDocumentTab*)tab;
@end
