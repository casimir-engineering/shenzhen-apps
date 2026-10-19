#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacCollectionHost)
- (void)loadSelectedTab;
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab;
@end
@interface ShenzhenMacDelegate (SPDFMacCollectionAPI)
- (void)collectionPrepareForTabPath:(NSString*)path;
- (void)collectionRefreshHistory;
- (BOOL)collectionShowSelectedHistoryPanel;
- (void)collectionRememberSidebarMode;
- (void)collectionSaveArchiveCopy:(id)sender;
- (void)collectionRecordObservedChangeAtPath:(NSString*)path;
- (void)collectionDidSavePath:(NSString*)path;
- (void)collectionClearObservedChangeAtPath:(NSString*)path;
- (void)collectionDidOpenPath:(NSString*)path;
- (void)collectionRememberPasswordForPath:(NSString*)path;
- (void)collectionWillOpenPaths:(NSArray<NSString*>*)paths;
- (void)collectionRecordUserOpenForPath:(NSString*)path document:(NSDictionary*)document;
- (NSUInteger)collectionConsumeUserOpenForPath:(NSString*)path;
- (void)collectionRecordUserOpenCount:(NSUInteger)count document:(NSDictionary*)document;
- (BOOL)collectionProtectPath:(NSString*)path operation:(NSString*)operation;
- (void)installCollectionSettingsMenu:(NSMenu*)menu;
- (void)addCollectionItemsToTabMenu:(NSMenu*)menu path:(NSString*)path;
- (void)showCollectionManager:(id)sender;
- (void)showCollectionSettings:(id)sender;
- (void)showCollectionManagerForQuery:(NSString*)query;
- (void)showCollectionManagerForDocumentID:(NSString*)documentID query:(NSString*)query;
- (void)showCollectionHistory:(id)sender;
- (void)showCollectionPreviousVersion:(id)sender;
- (void)showCollectionRecovery:(id)sender;
- (void)collectionRememberGroups;
- (BOOL)collectionRestoreMissingTab:(SPDFDocumentTab*)tab path:(NSString*)path;
- (void)collectionConvertTab:(SPDFDocumentTab*)tab path:(NSString*)path info:(NSDictionary*)info;
- (void)collectionPresentEditablePath:(NSString*)path info:(NSDictionary*)info;
- (BOOL)collectionPresentMissingPath:(NSString*)path;
- (void)collectionOpenPath:(NSString*)path archived:(BOOL)archived;
- (BOOL)openCollectionPaletteResult:(NSDictionary*)result;
@end
