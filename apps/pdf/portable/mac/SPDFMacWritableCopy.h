#pragma once
#import "SPDFMacDelegatePrivate.h"

@interface ShenzhenMacDelegate (SPDFMacWritableCopy)
// The active PDF cannot be written where it is (a read-only file or folder, a temporary folder): it moves to a
// writable copy in the app's own storage, the tab follows, and the edit goes on there -- nothing is asked. YES when
// the edit may proceed on the copy.
- (BOOL)moveActivePDFToWritableCopyForOperation:(NSString*)operation;
@end
