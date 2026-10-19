#import "SPDFMacTabViewState.h"

#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownCache.h"
#import "SPDFMacMarkdownRouting.h"
#import "SPDFMacSupport.h"

// Implemented in ShenzhenPDFMac.mm, which keeps them private to its own
// translation unit; declared here the way the launch prerender declares the
// coordinator methods its worker reuses.
@interface ShenzhenMacDelegate (SPDFMacTabViewStateHost)
- (void)invalidateCursorRegionCache;
- (void)clearFindResults;
- (void)rememberActiveTabState;
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab;
- (void)loadSelectedTab;
- (NSDictionary*)fileAttributesForPath:(NSString*)path;
- (void)recordFileAttributes:(NSDictionary*)attributes forTab:(SPDFDocumentTab*)tab;
- (CGFloat)backingScale;
- (void)clearToolbarFieldFocusForTabSwitch;
@end

@implementation ShenzhenMacDelegate (SPDFMacTabViewState)

- (void)prepareSelectedTabViewState:(SPDFDocumentTab*)tab path:(NSString*)path {
    _path = [path copy];
    // Render/read path: temp copy when the source is read-only, else the source.
    // _path stays the SOURCE for title/Recent/Favorites/watcher/Save/edit-gate.
    _workingPath = tab.workingPath.length ? [tab.workingPath copy] : [path copy];
    // Every document (re)load and tab switch funnels through here, so this is
    // the invalidation choke point for the per-page cursor-region caches.
    [self invalidateCursorRegionCache];
    _highlightPageIndex = -1;
    _selectionPageIndex = -1;
    _selectedText = nil;
    _searchField.stringValue = tab.searchText ?: @"";
    _findRegexCheckbox.state = tab.searchRegex ? NSControlStateValueOn : NSControlStateValueOff;
    _findRegexMultiline = tab.searchRegexMultiline;
    _sidebarPreferredVisible = tab.showSidebar;
    _minimapPreferredVisible = tab.showMinimap;
    // Keep-image-colors is this document's own (SPDFDocumentTab.preservesImageColors).
    // The render wrappers read the mirrored byte on background queues, so it has
    // to point at the document they are about to render.
    _darkThemePreservesImages = tab.preservesImageColors;
    [self clearFindResults];
}

- (void)seedKeepImageColorsForNewTab:(SPDFDocumentTab*)tab {
    tab.preservesImageColors = _darkThemePreservesImagesDefault;
}

- (void)seedNewTabFromDocumentMemory:(SPDFDocumentTab*)tab {
    [self seedKeepImageColorsForNewTab:tab];
    NSDictionary* state = _documentStates[[self documentStateKeyForPath:tab.path]];
    if (![state isKindOfClass:NSDictionary.class]) return;
    if (state[@"preservesImageColors"] != nil) tab.preservesImageColors=[state[@"preservesImageColors"] boolValue];
    // Absent for every document that has never been turned, and for every PDF:
    // only the Markdown rotate command writes it (SPDFMacMarkdownOrientation.mm).
    if (state[@"markdownLandscape"] != nil) tab.markdownLandscape = [state[@"markdownLandscape"] boolValue];
}

- (SPDFDocumentView*)newDocumentView {
    SPDFDocumentView* view = [[SPDFDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 800, 1000)];
    view.reader = self;
    [view registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    view.presentationMode = _presentationMode;
    view.themeVariant = self.markdownThemeVariant; // see applyReadingThemeToDocumentViewport
    view.zoom = _zoom;
    view.currentPageIndex = _pageIndex;
    view.backingScale = [self backingScale];
    view.viewportWidthHint = MAX(1.0, _pageScrollView.contentSize.width);
    view.viewportHeightHint = MAX(1.0, _pageScrollView.contentSize.height);
    view.activeFindPageIndex = -1;
    view.emptyMessage = @"Open a document";
    return view;
}

- (void)replaceDocumentViewForTabSwitch {
    [_pageView cancelTransientInteraction];
    [self clearToolbarFieldFocusForTabSwitch];
    NSClipView* clipView = _pageScrollView.contentView;
    BOOL previousPostsBoundsChangedNotifications = clipView.postsBoundsChangedNotifications;
    clipView.postsBoundsChangedNotifications = NO;
    _pageScrollView.documentView = nil;
    _pageView = [self newDocumentView];
    _pageScrollView.documentView = _pageView;
    clipView.postsBoundsChangedNotifications = previousPostsBoundsChangedNotifications;
    [self clearToolbarFieldFocusForTabSwitch];
}

// The Markdown counterpart of capturing a tab's view state: the live session
// holds it, and it has to land on the tab before any reload or tab switch.
- (void)rememberActiveMarkdownStateForTab:(SPDFDocumentTab*)tab {
    if (!tab || ![self isMarkdownActive]) return;
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    tab.path = _path;
    tab.title = spdf_display_name_for_path(_path);
    tab.scrollOrigin = session.scrollOrigin;
    tab.hasScrollOrigin = YES;
    tab.markdownSelectionRange = session.selectedRange;
    tab.pageIndex = session.currentPageIndex;
    tab.zoom = session.zoom;
    if (session.fitMode == SPDFMacMarkdownPageFitCustom) tab.customZoom = session.zoom;
    tab.fitMode = (SPDFFitMode)session.fitMode;
    tab.searchText = _searchField.stringValue ?: @"";
    tab.searchRegex = _findRegexCheckbox.state == NSControlStateValueOn;
    tab.findMatchIndex = session.currentMatchIndex;
    tab.showSidebar = _sidebarPreferredVisible;
    tab.showMinimap = _minimapPreferredVisible;
    tab.markdownLandscape = session.pageOrientation == SPDFMarkdownPageOrientationLandscape;
}

- (void)reloadSelectedTabFromDiskChange {
    SPDFDocumentTab* tab = [self selectedTab];
    if (!tab || !tab.path.length) return;
    if (_reloadInProgress) return;

    // Markdown reloads IN PLACE. The path below is a full reopen: it discards
    // the cached runtime and re-runs -loadSelectedTab, which for Markdown tears
    // the session down, shows the placeholder, and builds a new one -- the
    // window blanks and comes back, and a document being saved repeatedly reads
    // as the whole screen flashing. The session instead re-reads the file and
    // swaps the result under the live view, keeping the viewport.
    if ([self isMarkdownActive] && SPDFIsRenderedTextDocumentPath(tab.path)) {
        [self rememberActiveMarkdownStateForTab:tab];
        // Move the change baseline with the content: the watcher compares the
        // file against these, so leaving them behind would report the same edit
        // again and reload in a loop.
        NSDictionary* attributes = [self fileAttributesForPath:tab.path];
        if (attributes) [self recordFileAttributes:attributes forTab:tab];
        tab.cachedMarkdownFileIdentity = spdf_mac_markdown_file_identity(tab.path);
        [self.activeMarkdownSession reloadFromDiskWithStatus:@"Reloaded after the file changed on disk."];
        return;
    }

    _reloadInProgress = YES;
    // Capture current view state into the tab so loadSelectedTab restores it.
    [self rememberActiveTabState];
    // Force a real reopen: drop the cached document/runtime so loadSelectedTab
    // takes the open-from-disk branch instead of the cache-hit branch.
    [self discardCachedRuntimeForTab:tab];
    [self loadSelectedTab];
    _statusLabel.stringValue = @"Reloaded after the file changed on disk.";
    _reloadInProgress = NO;
}

@end
