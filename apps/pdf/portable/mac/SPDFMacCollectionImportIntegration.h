#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (CollectionInitialImport)
- (void)collectionImportRecentDocuments;
@end
@interface ShenzhenMacDelegate (CollectionImportRetry)
- (void)collectionAllowImportRetryAfterFailure;
@end
