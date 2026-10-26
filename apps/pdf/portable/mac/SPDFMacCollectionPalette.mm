#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionPalette.h"
#import "SPDFMacCollectionPaletteModel.h"
#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacPaletteActivation.h"
#import "SPDFMacPaletteDocumentNames.h"
#import "SPDFMacPaletteResults.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacPaletteTextSearch.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacTabGroups.h"
#import "markdown/SPDFMarkdownDocument.h"
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>
#import <float.h>
#import "friends/SPDFMacFriendsIntegration.h"

id spdf_state_object_from_yaml_data(NSData* data);
static const void* kSPDFPaletteSearchToken = &kSPDFPaletteSearchToken;

static NSArray<NSDictionary*>* SessionWindows(id session) {
    return [session isKindOfClass:NSDictionary.class] && [session[@"windows"] isKindOfClass:NSArray.class]
        ? session[@"windows"] : @[];
}
static NSDictionary* MergeSession(id stored, NSDictionary* liveWindow) {
    NSMutableArray* windows = [SessionWindows(stored) mutableCopy];
    if (liveWindow) [windows addObject:liveWindow];
    return @{@"windows":windows};
}
static NSArray<NSDictionary*>* SearchCandidates(NSArray<NSDictionary*>* candidates) {
    return [candidates sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
      NSComparisonResult recent = [b[@"focusedAt"] compare:a[@"focusedAt"]];
      return recent != NSOrderedSame ? recent : [a[@"_order"] compare:b[@"_order"]];
    }];
}
// Where each row's document lives, for the quiet column beside its name.
static NSArray<NSDictionary*>* Located(NSArray<NSDictionary*>* rows) {
    NSString* home = NSHomeDirectory(), *support = SPDFMacStateDirectoryPath();
    NSMutableArray* located = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary* row in rows) {
        NSMutableDictionary* display = [row mutableCopy];
        display[@"location"] = spdf_palette_location_label(row[@"path"], home, support);
        [located addObject:display];
    }
    return located;
}
static NSArray<NSDictionary*>* CollectionRows(NSArray<NSDictionary*>* hits, NSString* query, BOOL text) {
    NSMutableArray* rows = [NSMutableArray array];
    for (NSDictionary* hit in Located(hits ?: @[])) {
        NSMutableDictionary* row = [hit mutableCopy]; row[@"kind"] = @"collectionDocument";
        NSString* saved = [hit[@"title"] isKindOfClass:NSString.class] ? hit[@"title"] : @"";
        row[@"title"] = saved.length ? spdf_palette_file_display_name(saved)
                                     : spdf_palette_document_title(hit[@"path"], nil, nil);
        row[@"subtitle"] = text ? spdf_collection_palette_single_line(hit[@"snippet"] ?: @"") : @"";
        NSInteger oneBasedPage = [hit[@"page"] integerValue];
        if (text) row[@"page"] = @(oneBasedPage > 0 ? oneBasedPage - 1 : 0);
        if (text && oneBasedPage > 0)
            row[@"title"] = [NSString stringWithFormat:@"%@ · page %ld", row[@"title"], (long)oneBasedPage];
        if (text) row[@"query"] = query;
        [rows addObject:row];
    }
    return rows;
}

@implementation ShenzhenMacDelegate (SPDFMacCollectionPalette)
- (NSDictionary*)livePaletteSessionWindow {
    NSMutableArray* tabs = [NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) {
        if (!tab.path.length) continue;
        NSMutableDictionary* item = [@{@"path":tab.path, @"title":tab.title ?: @"",
            @"markdownLandscape":@(tab.markdownLandscape), @"lastViewedAt":@(tab.lastViewedAt)} mutableCopy];
        if (tab.group) item[@"group"] = tab.group.dictionary;
        [tabs addObject:item];
    }
    return @{@"id":@"live-palette", @"focusedAt":@(DBL_MAX), @"tabs":tabs};
}
- (NSDictionary*)paletteCandidateForTab:(SPDFDocumentTab*)tab {
    // A document already loaded knows its own title; nothing is read for it.
    spdf_document* doc = tab.cachedDocument;
    if (!doc && tab == [self selectedTab] && [_path isEqualToString:tab.path]) doc = _doc;
    const char* metadata = doc ? spdf_title(doc) : NULL;
    NSString* title = spdf_palette_document_title(tab.path, tab.collectionVersionLabel ?: spdf_tab_display_name(tab),
                                                  metadata ? [NSString stringWithUTF8String:metadata] : nil);
    NSMutableDictionary* item = [@{@"path":tab.path, @"title":title ?: @"", @"lastViewedAt":@(tab.lastViewedAt)}
        mutableCopy];
    if (tab.collectionVersionLabel.length) item[@"collectionVersionLabel"] = tab.collectionVersionLabel;
    if (tab.collectionHistoryDocumentID.length) item[@"collectionHistoryID"] = tab.collectionHistoryDocumentID;
    // A working copy's tab knows its original once opened, so the two fold into one row at once.
    NSString* original = spdf_palette_collection_copy_document_id(tab.path)
        ? [self collectionKnownDocumentPathForTab:tab] : nil;
    if (original.length) item[@"originalPath"] = original;
    if (tab.group) item[@"group"] = tab.group.dictionary;
    return item;
}
- (void)cancelCollectionPaletteSearch {
    [objc_getAssociatedObject(self, kSPDFPaletteSearchToken) cancel];
    ++_paletteSearchGeneration;
}
- (void)refreshPaletteResults {
    [self cancelCollectionPaletteSearch];
    [self paletteForgetHighlightMove]; // new words: the best match leads again
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:1];
    objc_setAssociatedObject(self, kSPDFPaletteSearchToken, progress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger generation = ++_paletteSearchGeneration;
    NSDictionary* parsed = spdf_collection_palette_query(_paletteSearchField.stringValue);
    BOOL collectionOnly = [parsed[@"collectionOnly"] boolValue]; NSString* query = parsed[@"query"];
    NSArray* liveCandidates = [self openDocumentPaletteCandidates];
    NSDictionary* liveWindow = [self livePaletteSessionWindow];
    NSDictionary* immediateSession = MergeSession(nil, liveWindow);
    NSArray* immediateOpen = spdf_palette_merge_collection_copies(
        spdf_collection_palette_open_candidates(liveCandidates, immediateSession), @{});
    NSArray* supplements = collectionOnly ? @[] : [self collectionPaletteSupplementaryRowsForQuery:query
        excludingOpenPaths:spdf_collection_palette_open_paths(immediateOpen)];
    // The chat is a row like any other: first while nothing is typed, so Return
    // on an empty search still opens it, and last once words are typed.
    BOOL chatFirst = !collectionOnly && !query.length;
    NSArray* leading = chatFirst ? @[spdf_collection_palette_chat_row(@"")] : @[];
    if (!collectionOnly && query.length)
        supplements = [supplements arrayByAddingObject:spdf_collection_palette_chat_row(query)];
    NSArray* titledOpen = collectionOnly ? @[] : Located(spdf_collection_palette_open_name_rows(immediateOpen, query));
    NSArray* groups = collectionOnly ? @[] : spdf_collection_palette_group_rows(immediateSession, query);
    NSArray* instant = [[leading arrayByAddingObjectsFromArray:spdf_collection_palette_rows(collectionOnly, query,
        titledOpen, groups, @[], @[], @[], NO)] arrayByAddingObjectsFromArray:supplements];
    [_paletteResults setArray:instant];
    [_paletteResults addObject:@{@"kind":@"status", @"title":@"Searching…",
                                 @"subtitle":@"Open documents, groups and local Collection"}];
    [_paletteTable reloadData]; [self selectFirstPaletteResult];
    [self updatePalettePanelFramePreservingTop:_palettePanel.visible];

    NSString* sessionPath = [[self pathForStateFile:@"session.yaml"] copy];
    // Each tier publishes independently: parsing a large open PDF must never
    // hold back an indexed Collection title (or another keystroke).
    __block NSArray *latestNames = titledOpen, *latestGroups = groups;
    __block NSArray *latestOpenText = @[], *latestCollectionNames = @[], *latestCollectionText = @[];
    __block NSArray *latestFriends = @[];
    void (^publish)(NSString*, NSArray*, NSArray*) = ^(NSString* tier, NSArray* first, NSArray* second) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger current = self->_paletteSearchGeneration;
            BOOL visible = self->_palettePanel.visible;
            if (!spdf_collection_palette_can_publish(progress, generation, current, visible)) return;
            if ([tier isEqual:@"names"]) { latestNames = first; latestGroups = second; }
            if ([tier isEqual:@"openText"]) latestOpenText = first;
            if ([tier isEqual:@"collectionNames"]) latestCollectionNames = first;
            if ([tier isEqual:@"collectionText"]) latestCollectionText = first;
            if ([tier isEqual:@"friends"]) latestFriends = first;
            NSArray* rows = [[leading arrayByAddingObjectsFromArray:spdf_collection_palette_rows(collectionOnly,
                query, latestNames, latestGroups, latestOpenText, latestCollectionNames, latestCollectionText,
                collectionOnly)] arrayByAddingObjectsFromArray:supplements];
            rows = SPDFMacFriendsPaletteMergeRows(rows, latestFriends);
            [self applyPaletteRows:rows];
        });
    };
    if (!collectionOnly) [self friendsSearchPaletteQuery:query progress:progress
                                                  publish:^(NSArray* rows) { publish(@"friends", rows, nil); }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (progress.cancelled) return;
        NSDictionary* stored = SPDFSearchCachedFile(sessionPath,@"session",1024 * 1024, ^id {
            return spdf_state_object_from_yaml_data([NSData dataWithContentsOfFile:sessionPath]);
        });
        NSDictionary* session = MergeSession(stored, liveWindow);
        SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
        // The search below reads the same cached manifest; it says which open
        // working copy belongs to which original.
        NSString* manifestPath = [store.rootURL URLByAppendingPathComponent:@"manifest.json"].path;
        NSDictionary* manifest = SPDFSearchCachedJSON(manifestPath);
        NSDictionary* originals = spdf_palette_collection_original_paths(manifest);
        NSArray* candidates = spdf_palette_titled_from_collection(spdf_palette_merge_collection_copies(
            spdf_collection_palette_open_candidates(liveCandidates, session), originals), originals,
            spdf_palette_collection_titles(manifest));
        NSSet* openPaths = spdf_collection_palette_open_paths(candidates);
        NSArray* asyncOpenNames = collectionOnly ? @[] : spdf_collection_palette_open_name_rows(candidates, query);
        NSArray* asyncGroups = collectionOnly ? @[] : spdf_collection_palette_group_rows(session, query);
        publish(@"names",Located(asyncOpenNames),asyncGroups);
        if (progress.cancelled) return;
        if (!collectionOnly && query.length) {
            // Serialize cold extraction so rapid typing cannot run multiple
            // Markdown pagination jobs concurrently. Warm reads reuse text.
            static dispatch_queue_t textQueue; static dispatch_once_t once;
            dispatch_once(&once, ^{
                textQueue = dispatch_queue_create("org.shenzhenpdf.palette-text", DISPATCH_QUEUE_SERIAL);
            });
            dispatch_async(textQueue, ^{
                if (progress.cancelled) return;
                publish(@"openText",SPDFPaletteOpenTextMatches(SearchCandidates(candidates),query,progress),nil);
            });
        }
        NSSet* nameExclusions = collectionOnly ? NSSet.set : openPaths;
        NSArray* nameHits = [store search:query titlesOnly:YES excludingPaths:nameExclusions limit:5 progress:progress];
        publish(@"collectionNames",CollectionRows(nameHits,query,NO),nil);
        if (progress.cancelled || !query.length) return;
        NSArray* textHits = [store search:query titlesOnly:NO excludingPaths:NSSet.set limit:5 progress:progress];
        publish(@"collectionText",CollectionRows(textHits,query,YES),nil);
    });
}
- (BOOL)openCollectionPaletteResult:(NSDictionary*)result {
    if ([self friendsOpenPaletteResult:result]) return YES;
    NSString* kind = result[@"kind"];
    if (![kind hasPrefix:@"collection"]) return NO;
    if ([kind isEqual:@"collectionShowAll"]) {
        NSString* query = result[@"query"] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{ [self showCollectionManagerForQuery:query]; });
        return YES;
    }
    NSString* path = result[@"path"];
    if ([kind isEqual:@"collectionGroup"]) { [self focusOpenDocumentTabForPath:path]; return YES; }
    if ([kind isEqual:@"collectionDocument"] && !SPDFCollectionOriginalAvailable(result)) {
        SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
        NSDictionary* doc = result; NSError* error = nil;
        NSURL* URL = [store materializeVersionID:doc[@"latestVersionID"] documentID:doc[@"id"] error:&error];
        if (!URL) { [_window presentError:error]; return YES; }
        path = URL.path;
    }
    [self collectionOpenPath:path archived:[SPDFMacCollectionStore.defaultStore isArchivePath:path]];
    [self collectionNavigateResult:result path:path attempts:100];
    return YES;
}
- (void)collectionNavigateResult:(NSDictionary*)result path:(NSString*)path attempts:(NSInteger)attempts {
    if (!result[@"page"] || ![_path isEqual:path] || attempts <= 0) return;
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? self.activeMarkdownSession : nil;
    if (session && !session.isNavigationReady) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self collectionNavigateResult:result path:path attempts:attempts - 1];
        }); return;
    }
    NSInteger page = MAX(0, [result[@"page"] integerValue]);
    if (session) [self markdownGoToPage:page]; else [self goToPage:page preserveSinglePagePosition:NO];
    if ([result[@"query"] length]) {
        _searchField.stringValue = result[@"query"]; _findRegexCheckbox.state = NSControlStateValueOff;
        _pendingFindPreferredPage = page;
        [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:YES];
    }
}
@end
