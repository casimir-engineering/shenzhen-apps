#import "SPDFMacCollectionWindow.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionCompare.h"
@class SPDFCollectionThumbnailLoader;
@interface SPDFMacCollectionWindow ()
@property(nonatomic) SPDFMacCollectionStore* store;
@property(nonatomic, copy) SPDFCollectionOpenHandler openHandler;
@property(nonatomic) NSView* contentHost;
@property(nonatomic) NSView* documentsPane;
@property(nonatomic) NSView* settingsPane;
@property(nonatomic) NSView* historyPane;
@property(nonatomic) NSButton* documentsButton;
@property(nonatomic) NSButton* settingsButton;
@property(nonatomic) NSTextField* resultSummary;
@property(nonatomic) NSTextField* locationField;
@property(nonatomic, copy) NSString* destination;
@property(nonatomic) NSMutableSet<NSString*>* expandedResults;
@property(nonatomic) NSPopUpButton* viewPicker;
@property(nonatomic) NSPopUpButton* sortPicker;
@property(nonatomic) NSSearchField* search;
@property(nonatomic) NSTableView* table;
@property(nonatomic) NSScrollView* listScroll;
@property(nonatomic) NSCache<NSString*, NSImage*>* thumbnailCache;
@property(nonatomic) NSOperationQueue* thumbnailQueue;
@property(nonatomic) NSMutableSet<NSString*>* pendingThumbnails;
@property(nonatomic) SPDFCollectionThumbnailLoader* thumbnails;
@property(nonatomic) NSTextField* details;
@property(nonatomic) NSTextField* storage;
@property(nonatomic) NSTextField* storagePolicy;
@property(nonatomic) NSTextField* settingsStatus;
@property(nonatomic) NSButton* enabled;
@property(nonatomic) NSTextField* limitField;
@property(nonatomic) NSPopUpButton* limitPicker;
@property(nonatomic) NSTextField* limitUnit;
@property(nonatomic) NSSlider* dynamicPercent;
@property(nonatomic) NSTextField* dynamicPercentLabel;
@property(nonatomic) NSArray<NSDictionary*>* rows;
@property(nonatomic) NSArray<NSDictionary*>* documents;
@property(nonatomic) NSString* documentID;
@property(nonatomic) NSString* restoreHistoryVersionID;
@property(nonatomic) NSDictionary* initialBrowseState;
@property(nonatomic) BOOL hasLoadedResults;
@property(nonatomic) NSString* resultQuery;
@property(nonatomic) BOOL reloadingResults;
@property(nonatomic) BOOL storeRefreshPending;
@property(nonatomic) BOOL loadingResults;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) dispatch_queue_t preferenceQueue;
@property(nonatomic) BOOL mutationPending;
@property(nonatomic) NSMutableArray<NSButton*>* selectionButtons;
- (void)buildManagerLayout;
- (NSMenu*)collectionViewOptionsMenu;
- (void)returnToReader:(id)sender;
- (void)buildSettingsPane;
- (void)updateStoragePolicy;
- (void)changeDynamicPercent:(id)sender;
- (void)showDocumentMenu:(NSControl*)sender;
- (void)populateDocumentMenu:(NSMenu*)menu;
- (void)showDestination:(NSString*)destination;
- (void)navigate:(id)sender;
- (void)persistManagerPreferences;
- (NSDictionary*)captureBrowseState;
- (void)restoreBrowseState:(NSDictionary*)state toRows:(NSMutableArray*)rows query:(NSString*)query;
- (void)restoreBrowseSelectionAndScroll:(NSDictionary*)state;
- (void)showHistoryForDocument:(NSDictionary*)document version:(NSDictionary*)version;
- (void)historyForRow:(id)sender;
- (NSView*)resultCellForRow:(NSInteger)row;
- (void)reload:(id)sender;
- (void)refreshFromStore;
- (NSDictionary*)selectedDocument;
- (NSDictionary*)selectedVersion;
- (void)updateDetails;
- (void)showError:(NSError*)error;
@end
@interface SPDFMacCollectionWindow (Actions)
- (NSArray<NSDictionary*>*)selectedRowsSnapshot;
- (void)openOriginal:(id)sender;
- (void)preview:(id)sender;
- (void)selectSearchMatch:(NSControl*)sender;
- (void)history:(id)sender;
- (void)comparePrevious:(id)sender;
- (void)locate:(id)sender;
- (void)exportCopy:(id)sender;
- (void)keep:(id)sender;
- (void)deleteSelected:(id)sender;
- (void)changeEnabled:(id)sender;
- (void)changeLimit:(id)sender;
- (void)changeLocation:(id)sender;
- (void)openLocation:(id)sender;
@end
@interface SPDFMacCollectionWindow (Thumbnails)
- (void)initializeThumbnails;
- (void)requestThumbnail:(NSDictionary*)row key:(NSString*)key;
- (void)cancelThumbnails;
@end
