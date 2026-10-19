#import "SPDFMacModels.h"
#import "SPDFMacPastedImageState.h"
#import "SPDFMacTabGroups.h"

#import "SPDFMacMarkdownSession.h"

@implementation SPDFDocumentTab
@synthesize path = _path;
@synthesize unsavedPastedImage = _unsavedPastedImage;

- (void)setPath:(NSString*)path {
    if ([_path isEqualToString:path]) return;
    _path = [path copy];
    _unsavedPastedImage = SPDFPathIsUnsavedPastedImage(_path);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pageIndex = 0;
        _zoom = 1.0;
        _customZoom = 1.0;
        _fitMode = SPDFFitModePage;
        _searchText = @"";
        _searchRegexMultiline = YES;
        _findMatchIndex = -1;
        _showSidebar = YES;
        _showMinimap = YES;
        _preservesImageColors = YES;
        _missingMessage = @"";
        _markdownSelectionRange = NSMakeRange(0, 0);
    }
    return self;
}

- (void)setCachedDocument:(spdf_document*)cachedDocument {
    if (_cachedDocument == cachedDocument) return;
    spdf_close(_cachedDocument);
    _cachedDocument = cachedDocument;
}

- (void)clearCachedRuntime {
    [_cachedMarkdownSession cancelAllOperations];
    self.cachedMarkdownSession = nil;
    self.cachedMarkdownFileIdentity = nil;
    self.cachedDocument = NULL;
    self.cachedRenderedPages = nil;
    self.cachedModificationDate = nil;
    self.cachedFileSize = 0;
    spdf_free_outline(&_cachedOutline);
    spdf_free_comments(&_cachedComments);
    memset(&_cachedOutline, 0, sizeof(_cachedOutline));
    memset(&_cachedComments, 0, sizeof(_cachedComments));
    self.cachedOutlineLoaded = NO;
    self.cachedCommentsLoaded = NO;
}

- (void)replaceCachedOutline:(spdf_outline)outline loaded:(BOOL)loaded {
    spdf_free_outline(&_cachedOutline);
    _cachedOutline = outline;
    _cachedOutlineLoaded = loaded;
}

- (void)replaceCachedComments:(spdf_comments)comments loaded:(BOOL)loaded {
    spdf_free_comments(&_cachedComments);
    _cachedComments = comments;
    _cachedCommentsLoaded = loaded;
}

- (void)dealloc {
    spdf_close(_cachedDocument);
    spdf_free_outline(&_cachedOutline);
    spdf_free_comments(&_cachedComments);
}

@end

SPDFDocumentTab* spdf_copy_document_tab(SPDFDocumentTab* source) {
    SPDFDocumentTab* copy = [[SPDFDocumentTab alloc] init];
    copy.group = [source.group copy];
    copy.collectionHistoryDocumentID = source.collectionHistoryDocumentID;
    copy.collectionVersionLabel = source.collectionVersionLabel;
    copy.path = source.path;
    copy.title = source.title;
    copy.lastViewedAt = source.lastViewedAt;
    copy.pageIndex = source.pageIndex;
    copy.zoom = source.zoom;
    copy.customZoom = source.customZoom;
    copy.fitMode = source.fitMode;
    copy.scrollOrigin = source.scrollOrigin;
    copy.hasScrollOrigin = source.hasScrollOrigin;
    copy.searchText = source.searchText;
    copy.searchRegex = source.searchRegex;
    copy.searchRegexMultiline = source.searchRegexMultiline;
    copy.findMatchIndex = source.findMatchIndex;
    copy.showSidebar = source.showSidebar;
    copy.showMinimap = source.showMinimap;
    copy.hasMinimapPreference = source.hasMinimapPreference;
    copy.preservesImageColors = source.preservesImageColors;
    copy.missingFile = source.missingFile;
    copy.missingMessage = source.missingMessage;
    copy.markdownSelectionRange = source.markdownSelectionRange;
    copy.markdownLandscape = source.markdownLandscape;
    copy.markdownAnchor = source.markdownAnchor;
    copy.readOnly = source.readOnly;
    copy.workingPath = source.workingPath;
    copy.readOnlyCopyBinding = source.readOnlyCopyBinding;
    copy.copiedSourceFileSize = source.copiedSourceFileSize;
    copy.copiedSourceModificationDate = source.copiedSourceModificationDate;
    return copy;
}

NSDictionary* spdf_dictionary_from_tab(SPDFDocumentTab* tab, NSInteger sourceWindowNumber) {
    if (!tab) return @{};
    NSDictionary* result = @{
        @"path" : tab.path ?: @"",
        @"title" : tab.title ?: @"",
        @"lastViewedAt" : @(tab.lastViewedAt),
        @"page" : @(tab.pageIndex),
        @"zoom" : @(tab.zoom),
        @"customZoom" : @(tab.customZoom),
        @"fitMode" : @(tab.fitMode),
        /* The app is always continuous now. Single-page view mode was removed;
         * keep emitting viewMode=1 (continuous) so older app versions reading
         * this session still open these tabs in the correct mode. */
        @"viewMode" : @1,
        @"scrollX" : @(tab.scrollOrigin.x),
        @"scrollY" : @(tab.scrollOrigin.y),
        @"hasScrollOrigin" : @(tab.hasScrollOrigin),
        @"searchText" : tab.searchText ?: @"",
        @"searchRegex" : @(tab.searchRegex),
        @"searchRegexMultiline" : @(tab.searchRegexMultiline),
        @"findMatchIndex" : @(tab.findMatchIndex),
        @"markdownLandscape" : @(tab.markdownLandscape),
        @"markdownSelectionLocation" : @(tab.markdownSelectionRange.location),
        @"markdownSelectionLength" : @(tab.markdownSelectionRange.length),
        @"showSidebar" : @(tab.showSidebar),
        @"showMinimap" : @(tab.showMinimap),
        @"preservesImageColors" : @(tab.preservesImageColors),
        @"sourcePID" : @(NSProcessInfo.processInfo.processIdentifier),
        @"sourceWindow" : @(sourceWindowNumber),
        @"readOnly" : @(tab.readOnly),
        @"workingPath" : tab.workingPath ?: @"",
        @"roCopyFileSize" : @(tab.copiedSourceFileSize),
        @"roCopyModifiedAt" :
            @(tab.copiedSourceModificationDate ? tab.copiedSourceModificationDate.timeIntervalSince1970 : 0.0)
    };
    if (!tab.group && !tab.collectionHistoryDocumentID.length && !tab.collectionVersionLabel.length && !tab.readOnlyCopyBinding.count) return result;
    NSMutableDictionary* grouped = [result mutableCopy];
    if (tab.readOnlyCopyBinding.count) grouped[@"roCopyBinding"] = tab.readOnlyCopyBinding;
    if (tab.group) grouped[@"group"] = tab.group.dictionary;
    if (tab.collectionVersionLabel.length) grouped[@"collectionVersionLabel"] = tab.collectionVersionLabel;
    if (tab.collectionHistoryDocumentID.length) grouped[@"collectionHistoryID"] = tab.collectionHistoryDocumentID;
    return grouped;
}

SPDFDocumentTab* spdf_tab_from_dictionary(NSDictionary* item) {
    if (![item isKindOfClass:NSDictionary.class]) return nil;
    NSString* path = item[@"path"];
    if (![path isKindOfClass:NSString.class] || path.length == 0) return nil;
    SPDFDocumentTab* tab = [[SPDFDocumentTab alloc] init];
    if (item[@"group"]) tab.group = [SPDFTabGroup fromDictionary:item[@"group"]];
    tab.path = path;
    if ([item[@"collectionVersionLabel"] isKindOfClass:NSString.class]) tab.collectionVersionLabel = item[@"collectionVersionLabel"];
    if ([item[@"collectionHistoryID"] isKindOfClass:NSString.class]) tab.collectionHistoryDocumentID = item[@"collectionHistoryID"];
    if ([item[@"title"] isKindOfClass:NSString.class]) tab.title = item[@"title"];
    if ([item[@"lastViewedAt"] isKindOfClass:NSNumber.class]) tab.lastViewedAt = [item[@"lastViewedAt"] doubleValue];
    tab.pageIndex = MAX(0, [item[@"page"] integerValue]);
    tab.zoom = [item[@"zoom"] doubleValue] > 0 ? [item[@"zoom"] doubleValue] : 1.0;
    tab.customZoom = [item[@"customZoom"] doubleValue] > 0 ? [item[@"customZoom"] doubleValue] : tab.zoom;
    if (item[@"fitMode"]) tab.fitMode = (SPDFFitMode)MAX(0, MIN(4, [item[@"fitMode"] integerValue]));
    /* viewMode is intentionally ignored: single-page view mode was removed and
     * the app is always continuous. Old sessions that stored viewMode=0 (single)
     * open fine as continuous. */
    tab.scrollOrigin = NSMakePoint([item[@"scrollX"] doubleValue], [item[@"scrollY"] doubleValue]);
    if (item[@"hasScrollOrigin"] != nil)
        tab.hasScrollOrigin = [item[@"hasScrollOrigin"] boolValue];
    else
        tab.hasScrollOrigin = item[@"scrollX"] != nil || item[@"scrollY"] != nil;
    if ([item[@"searchText"] isKindOfClass:NSString.class]) tab.searchText = item[@"searchText"];
    tab.searchRegex = [item[@"searchRegex"] boolValue];
    tab.searchRegexMultiline = item[@"searchRegexMultiline"] ? [item[@"searchRegexMultiline"] boolValue] : YES;
    tab.findMatchIndex = item[@"findMatchIndex"] ? [item[@"findMatchIndex"] integerValue] : -1;
    NSUInteger markdownSelectionLocation = [item[@"markdownSelectionLocation"] unsignedIntegerValue];
    NSUInteger markdownSelectionLength = [item[@"markdownSelectionLength"] unsignedIntegerValue];
    tab.markdownSelectionRange = NSMakeRange(markdownSelectionLocation, markdownSelectionLength);
    tab.markdownLandscape = [item[@"markdownLandscape"] boolValue];
    tab.showSidebar = item[@"showSidebar"] ? [item[@"showSidebar"] boolValue] : YES;
    tab.showMinimap = item[@"showMinimap"] ? [item[@"showMinimap"] boolValue] : YES;
    tab.hasMinimapPreference = item[@"showMinimap"] != nil;
    // A session written before this was per-document has no key; the caller
    // seeds those tabs with the launch default (see -seedKeepImageColorsForNewTab:).
    if (item[@"preservesImageColors"] != nil)
        tab.preservesImageColors = [item[@"preservesImageColors"] boolValue];
    tab.readOnly = [item[@"readOnly"] boolValue];
    if ([item[@"workingPath"] isKindOfClass:NSString.class] && [item[@"workingPath"] length] > 0)
        tab.workingPath = item[@"workingPath"];
    tab.readOnlyCopyBinding = [item[@"roCopyBinding"] isKindOfClass:NSDictionary.class] ? item[@"roCopyBinding"] : nil;
    tab.copiedSourceFileSize = (unsigned long long)[item[@"roCopyFileSize"] unsignedLongLongValue];
    double roModified = [item[@"roCopyModifiedAt"] doubleValue];
    if (roModified > 0.0) tab.copiedSourceModificationDate = [NSDate dateWithTimeIntervalSince1970:roModified];
    return tab;
}

NSUInteger spdf_session_focused_window_index(NSArray* windows) {
    if (![windows isKindOfClass:NSArray.class] || windows.count == 0) return NSNotFound;
    NSUInteger best = NSNotFound;
    double bestFocusedAt = -1.0;
    for (NSUInteger i = 0; i < windows.count; i++) {
        if (![windows[i] isKindOfClass:NSDictionary.class]) continue;
        double focusedAt = [windows[i][@"focusedAt"] doubleValue];
        if (best == NSNotFound || focusedAt > bestFocusedAt) {
            best = i;
            bestFocusedAt = focusedAt;
        }
    }
    return best;
}

@implementation SPDFWorkerDocument

- (void)dealloc {
    spdf_close(_document);
}

@end

NSString* spdf_mac_detach_handoff_name(NSString* path) {
    NSString* standardized = path.stringByStandardizingPath ?: @"";
    if (!standardized.length) return @"";
    // A stable, filesystem-safe name both sides compute from the path alone.
    // Hashing keeps it short and keeps the document's name out of the state
    // directory, where a listing would otherwise leak what is open.
    unsigned long long hash = 1469598103934665603ULL;  // FNV-1a
    for (NSUInteger i = 0; i < standardized.length; ++i) {
        hash ^= (unsigned long long)[standardized characterAtIndex:i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"detach-%016llx.yaml", hash];
}
