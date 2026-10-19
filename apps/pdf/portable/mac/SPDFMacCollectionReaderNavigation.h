#pragma once
#import "SPDFMacCollectionIntegration.h"
@interface ShenzhenMacDelegate (SPDFMacCollectionReaderNavigation)
- (void)collectionNavigateDocument:(NSDictionary*)document version:(NSDictionary*)version
                             page:(NSUInteger)page query:(NSString*)query history:(BOOL)history;
- (void)collectionSetVersionInfo:(NSDictionary*)info forTab:(SPDFDocumentTab*)tab;
- (void)collectionRefreshVersionInfoForDocument:(NSDictionary*)document;
- (void)collectionUpdateVersionIndicator;
// Cached tab identity only; does not open the store or touch the filesystem.
- (BOOL)collectionTabIsSavedVersion:(SPDFDocumentTab*)tab;
// Where the tab's Collection document lives, as last read for this tab; nil when
// not yet known. Cached only, like the above.
- (NSString*)collectionKnownDocumentPathForTab:(SPDFDocumentTab*)tab;
@end
