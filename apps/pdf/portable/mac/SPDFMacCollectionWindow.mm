#import "SPDFMacCollectionRetention.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacCollectionStoreContextSearch.h"
#import "SPDFMacCollectionWindowHistory.h"
#import "SPDFMacCollectionManagerWindow.h"
#import "SPDFMacCollectionStyle.h"

static BOOL MatchesDocumentView(NSDictionary* doc, NSInteger view) {
    if (view == 2) return !SPDFCollectionOriginalAvailable(doc);
    if (view == 4) return [doc[@"excluded"] boolValue];
    if (view == 3) {
        for (NSDictionary* version in doc[@"versions"]) if ([version[@"keep"] boolValue]) return YES;
        return NO;
    }
    return YES;
}
static NSDictionary* LatestSavedVersion(NSDictionary* doc) {
    for (NSDictionary* version in [doc[@"versions"] reverseObjectEnumerator])
        if (SPDFCollectionVersionIsLatest(doc,version)) return version;
    return @{};
}
@implementation SPDFMacCollectionWindow
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store open:(SPDFCollectionOpenHandler)open {
    NSWindow* window = [[SPDFCollectionManagerWindow alloc] initWithContentRect:NSMakeRect(0, 0, 850, 590)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    _store = store; _openHandler = [open copy]; _rows = @[]; _documents = @[];
    window.titleVisibility = NSWindowTitleHidden; window.titlebarAppearsTransparent = YES;
    window.title = @"Collection"; window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(680, 460); [window setFrameAutosaveName:@"CollectionManager"];
    NSDictionary* preferences = store.settings;
    _initialBrowseState = [preferences[@"managerBrowseState"] isKindOfClass:NSDictionary.class] ? preferences[@"managerBrowseState"] : @{};
    NSArray* expanded = [_initialBrowseState[@"expanded"] isKindOfClass:NSArray.class] ? _initialBrowseState[@"expanded"] : @[];
    _expandedResults = [NSMutableSet setWithArray:expanded];
    // Legacy embedded-History preferences resume Documents. History now lives
    // exclusively in the reader and is opened only by an explicit action.
    _preferenceQueue = dispatch_queue_create("engineering.casimir.collection.manager-preferences", DISPATCH_QUEUE_SERIAL);
    [self buildManagerLayout];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(managerWindowWillClose:)
        name:NSWindowWillCloseNotification object:window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange:)
        name:SPDFCollectionStoreDidChangeNotification object:store];
    return self;
}
- (void)storeDidChange:(NSNotification*)notification {
    (void)notification; [self refreshFromStore];
}
- (void)refreshFromStore {
    @synchronized(self) { if (_storeRefreshPending) return; _storeRefreshPending=YES; }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self) {
            if (self.loadingResults) return; // One trailing refresh, never parallel store-change searches.
            self.storeRefreshPending=NO;
        }
        // Construction alone remains lazy. Refresh only an already consulted manager.
        if (self.generation || self.hasLoadedResults) [self reload:self.store];
    });
}
- (void)showDocumentID:(NSString*)documentID query:(NSString*)query {
    if (documentID.length || query != nil) {
        _documentID = documentID;
        _restoreHistoryVersionID = nil;
    }
    if (query != nil) { _search.stringValue = query; [self showDestination:@"Documents"]; }
    if (documentID.length) {
        _search.stringValue = query ?: @""; [_viewPicker selectItemWithTag:0];
        [self showDestination:@"Documents"];
    }

    [self reload:nil]; [self showWindow:nil]; [self.window makeKeyAndOrderFront:nil];
}
- (void)reload:(id)sender {
    if (sender == _search || sender == _viewPicker) {
        _documentID = nil; _restoreHistoryVersionID = nil;
    }
    if (sender != _store) [self persistManagerPreferences];
    NSDictionary* browseState = [self captureBrowseState];
    NSUInteger generation = ++_generation; _loadingResults=YES;
    NSInteger view = _viewPicker.selectedItem.tag, sort = _sortPicker.indexOfSelectedItem;
    NSString* query = [_search.stringValue copy]; NSString* selectedID = [_documentID copy];
    _storage.stringValue = @"Loading local history…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray* docs = [self.store documents]; NSMutableArray* rows = [NSMutableArray array];
        if (query.length) {
            // Documents always searches and displays one current saved copy per document.
            // Historical versions are available exclusively through that document's History.
            for (NSDictionary* group in [self.store searchGroups:query allVersions:NO]) {
                NSDictionary* doc = group[@"document"];
                if (!MatchesDocumentView(doc,view)) continue;
                for (NSDictionary* result in group[@"versions"]) {
                    if (!SPDFCollectionVersionIsLatest(doc,result[@"version"])) continue;
                    NSMutableDictionary* row = [result mutableCopy]; row[@"document"] = doc;
                    [rows addObject:row]; break;
                }
            }
        } else {
            for (NSDictionary* doc in docs) if (MatchesDocumentView(doc,view))
                [rows addObject:@{@"document":doc,@"version":LatestSavedVersion(doc)}];
        }
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
            if (sort == 2) return [a[@"document"][@"title"] localizedStandardCompare:b[@"document"][@"title"]];
            NSNumber* left = a[@"version"][@"capturedAt"], *right = b[@"version"][@"capturedAt"];
            BOOL leftDated = [left isKindOfClass:NSNumber.class], rightDated = [right isKindOfClass:NSNumber.class];
            // Excluded documents and failed first captures legitimately have
            // no saved version. Keep them last in either date order.
            if (leftDated != rightDated) return leftDated ? NSOrderedAscending : NSOrderedDescending;
            if (!leftDated) return [a[@"document"][@"id"] compare:b[@"document"][@"id"]];
            NSComparisonResult result = [left compare:right];
            return sort == 0 ? (NSComparisonResult)-result : result;
        }];
        unsigned long long used = [self.store storageUsedBytes];
        NSDictionary* budget = [self.store storageBudget];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.reloadingResults = YES;
            NSDictionary* restoredState = self.hasLoadedResults && [self.resultQuery isEqual:query]
                ? [self captureBrowseState] : browseState;
            [self restoreBrowseState:restoredState toRows:rows query:query];
            if (![browseState[@"query"] isEqual:query]) [self.expandedResults removeAllObjects];
            self.documents = docs; self.rows = rows; self.resultQuery = query; self.hasLoadedResults = YES;
            self.table.rowHeight = 100;
            [self.table reloadData];
            [self restoreBrowseSelectionAndScroll:restoredState];
            self.reloadingResults = NO;
            self.resultSummary.stringValue = query.length ? @"No matching documents." : @"Documents you open will appear here when Collection is enabled.";
            self.resultSummary.hidden = rows.count > 0;
            self.locationField.stringValue = self.store.rootURL.path;
            [self updateStoragePolicy];
            self.enabled.state = self.store.isEnabled ? NSControlStateValueOn : NSControlStateValueOff;
            if (selectedID.length) {
                self.documentID = nil;
                for (NSUInteger index=0;index<rows.count;index++) if ([rows[index][@"document"][@"id"] isEqual:selectedID]) {
                    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
                    [self.table scrollRowToVisible:index]; break;
                }
                self.restoreHistoryVersionID = nil;
            }
            self.storage.stringValue = [NSString stringWithFormat:@"%@ used · %@",
                [NSByteCountFormatter stringFromByteCount:(long long)used countStyle:NSByteCountFormatterCountStyleFile],
                self.store.isEnabled ? @"Capturing" : @"Capture off"];
            if ([budget[@"storageMode"] isEqual:@"dynamic"]) self.storage.stringValue=[self.storage.stringValue stringByAppendingFormat:@" · %@",
                [budget[@"capacityAvailable"] boolValue] ? [NSString stringWithFormat:@"Current budget: %@",
                    [NSByteCountFormatter stringFromByteCount:[budget[@"storageLimitBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]] : @"Disk space unavailable; automatic cleanup paused"];
            [self updateDetails];
            self.loadingResults=NO;
            @synchronized(self) {
                if (self.storeRefreshPending) { self.storeRefreshPending=NO; [self refreshFromStore]; }
            }
        });
    });
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView { (void)tableView; return _rows.count; }
- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)tableView; (void)column; return [self resultCellForRow:row];
}
- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    (void)notification; [self updateDetails];
    if (!self.reloadingResults && self.hasLoadedResults) [self persistManagerPreferences];
}
- (NSDictionary*)selectedDocument {
    if ([self.destination isEqual:@"History"]) return [self historySelectedDocument];
    NSInteger row = _table.selectedRow;
    return row >= 0 && row < (NSInteger)_rows.count ? _rows[(NSUInteger)row][@"document"] : nil;
}
- (NSDictionary*)selectedVersion {
    if ([self.destination isEqual:@"History"]) return [self historySelectedVersion];
    NSInteger row = _table.selectedRow;
    return row >= 0 && row < (NSInteger)_rows.count ? _rows[(NSUInteger)row][@"version"] : nil;
}
- (void)updateDetails {
    NSDictionary* doc = [self selectedDocument], *version = [self selectedVersion];
    NSString* (^date)(id) = ^NSString*(id seconds) {
        return seconds ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[seconds doubleValue]]
            dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @"Not captured";
    };
    NSString* warnings = [version[@"assetWarnings"] isKindOfClass:NSArray.class]
        ? [version[@"assetWarnings"] componentsJoinedByString:@"\n"] : @"";
    _details.stringValue = doc ? [NSString stringWithFormat:@"%@\n%@\n%@ · %lu versions\nCaptured %@\nSource modified %@\n%@ · %@\n%@%@%@",
        doc[@"title"],doc[@"path"],doc[@"status"] ?: @"Protected",(unsigned long)[doc[@"versions"] count],
        date(version[@"capturedAt"]),date(version[@"modifiedAt"]),
        [NSByteCountFormatter stringFromByteCount:[version[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile],
        [version[@"keep"] boolValue] ? @"Kept version" : version[@"id"] ? @"Collection document" : @"No archived version",
        [doc[@"excluded"] boolValue] ? @"Saving new versions is paused" : @"Saving new versions is enabled",
        [version[@"encrypted"] boolValue] ? @"\nEncrypted · no text index" : @"",
        warnings.length ? [@"\nAssets incomplete:\n" stringByAppendingString:warnings] : @""]
        : (_rows.count ? @"Select a document or version." : @"No documents in this view.");
    BOOL single = [self.destination isEqual:@"History"] || _table.selectedRowIndexes.count == 1;
    BOOL archived = [version[@"id"] length] > 0;
    BOOL sourceAvailable = SPDFCollectionOriginalAvailable(doc);
    NSArray* versions = doc ? doc[@"versions"] ?: @[] : @[];
    BOOL previous = versions.count > 1 && ![versions.firstObject[@"id"] isEqual:version[@"id"]];
    NSArray* selectedRows = [self selectedRowsSnapshot];
    for (NSButton* button in _selectionButtons) {
        NSString* action = NSStringFromSelector(button.action);
        if ([action isEqual:@"keep:"]) {
            BOOL kept = SPDFCollectionSelectionIsKept(selectedRows);
            button.title = kept ? @"Stop keep forever" : @"Keep forever";
            button.hidden = ![self.store isStorageLimited];
            button.toolTip = @"Keeping any version protects this document’s entire history from automatic storage cleanup. "
                @"Removing all Keep forever marks allows cleanup; it does not delete anything immediately. Manual deletion is still available.";
        }
        BOOL bulk = [@[@"keep:",@"deleteSelected:"] containsObject:action];
        button.enabled = doc && (single || bulk) && !_mutationPending;
        if ([@[@"preview:",@"exportCopy:",@"keep:",@"comparePrevious:"] containsObject:action])
            button.enabled &= archived;
        if ([action isEqual:@"openOriginal:"]) button.enabled &= sourceAvailable;
        if ([action isEqual:@"comparePrevious:"]) button.enabled &= previous;
        if ([action hasPrefix:@"compare"]) button.enabled &= ![version[@"encrypted"] boolValue];
    }
}
- (void)managerWindowWillClose:(NSNotification*)notification {
    (void)notification; [self persistManagerPreferences];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)showError:(NSError*)error { if (error) [self.window presentError:error]; }
@end
