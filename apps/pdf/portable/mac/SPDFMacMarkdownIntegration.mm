#import "SPDFMacAIIntegration.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacSidebarChapters.h"
#import "SPDFMacTranslationEnablement.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#import "SPDFMacMarkdownCache.h"
#import "SPDFMacMarkdownMinimapModel.h"
#import "SPDFMacMarkdownPrinting.h"
#import "SPDFMacMarkdownRouting.h"
#import "SPDFMacMarkdownSidebarModel.h"
#import "SPDFMacTabHoverPreviewIntegration.h"
#import "SPDFMacViewportCheckpoint.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacSupport.h"
#import "markdown/SPDFMarkdown.h"

@interface SPDFMacMarkdownDelegateState : NSObject
@property(nonatomic, strong) NSView* hostView;
@property(nonatomic, strong) SPDFMacMarkdownSession* activeSession;
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic) BOOL controlsUpdateScheduled;
@property(nonatomic, strong) SPDFMacViewportCheckpoint* viewportCheckpoint;
@end

@implementation SPDFMacMarkdownDelegateState
@end

static char kSPDFMacMarkdownDelegateStateKey;

@implementation ShenzhenMacDelegate (SPDFMacMarkdownIntegration)

- (SPDFMacMarkdownDelegateState*)markdownState {
    SPDFMacMarkdownDelegateState* state = objc_getAssociatedObject(self, &kSPDFMacMarkdownDelegateStateKey);
    if (!state) {
        state = [SPDFMacMarkdownDelegateState new];
        objc_setAssociatedObject(self, &kSPDFMacMarkdownDelegateStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (SPDFMacMarkdownSession*)activeMarkdownSession {
    return self.markdownState.activeSession;
}

- (void)installMarkdownHostInDocumentContainer {
    SPDFMacMarkdownDelegateState* state = self.markdownState;
    if (state.hostView || !_documentContainer) return;
    state.hostView = [[NSView alloc] init];
    state.hostView.translatesAutoresizingMaskIntoConstraints = NO;
    state.hostView.hidden = YES;
    [_documentContainer addSubview:state.hostView positioned:NSWindowAbove relativeTo:_pageScrollView];
    [NSLayoutConstraint activateConstraints:@[
        [state.hostView.topAnchor constraintEqualToAnchor:_pageScrollView.topAnchor],
        [state.hostView.leadingAnchor constraintEqualToAnchor:_pageScrollView.leadingAnchor],
        [state.hostView.trailingAnchor constraintEqualToAnchor:_pageScrollView.trailingAnchor],
        [state.hostView.bottomAnchor constraintEqualToAnchor:_pageScrollView.bottomAnchor],
    ]];
}

// Focus for a document that has JUST finished loading. UNCONDITIONAL, unlike
// the tab-activation claim, and both halves of that were learned the hard way:
// yielding only from {nil, window, tab strip, parked PDF views} made a reopen
// refuse, and exempting a focused NSText to protect a live find edit brought
// the bug back by another route -- search a PDF, reopen a Markdown document,
// and the find field still holds focus, so this stood off, and then
// -updateControlsForActiveMarkdown re-enabled that field and AppKit dropped
// first responder to the WINDOW. Nobody held it and typing went nowhere.
// A document that just appeared is what the user is looking at, so it gets the
// keys; a query typed for the previous document is stale by definition.
- (void)focusMarkdownViewAfterLoad {
    if (_presentationMode) return;
    NSView* target = [self activeDocumentKeyView];
    if (target) [_window makeFirstResponder:target];
}

- (BOOL)isMarkdownActive {
    return self.markdownState.activeSession != nil && SPDFIsRenderedTextDocumentPath(_path);
}

- (BOOL)hasActiveDocument {
    return _doc != NULL || [self isMarkdownActive];
}

- (void)setPDFToolbarViewsHiddenForMarkdown:(BOOL)hidden {
    (void)hidden;
    for (NSView* view in @[
             _sidebarToggleButton, _ocrButton, _translateButton, _ocrSeparator, _findRegexCheckbox, _minimapToggleButton
         ])
        view.hidden = NO;
    [self updateMarkdownFontControls];
}

static CGFloat spdf_mac_clamped_markdown_font_scale(CGFloat scale) {
    return MAX((CGFloat)0.5, MIN((CGFloat)3.0, scale));
}

// Text-size controls apply to every document using the text renderer, including
// Markdown and source files. Segment tooltips carry the current percentage.
- (void)updateMarkdownFontControls {
    BOOL markdownActive = [self isMarkdownActive];
    _markdownFontSizeSegments.hidden = !markdownActive;
    [self updateReadingThemeControls];
    if (!markdownActive) return;
    double percent = round(_markdownFontScale * 100.0);
    [_markdownFontSizeSegments setEnabled:_markdownFontScale > 0.5 forSegment:0];
    [_markdownFontSizeSegments setEnabled:_markdownFontScale < 3.0 forSegment:1];
    [_markdownFontSizeSegments setToolTip:[NSString stringWithFormat:@"Decrease Text Size (%.0f%%)", percent]
                               forSegment:0];
    [_markdownFontSizeSegments setToolTip:[NSString stringWithFormat:@"Increase Text Size (%.0f%%)", percent]
                               forSegment:1];
}

- (void)changeMarkdownFontScaleByFactor:(CGFloat)factor {
    if (![self isMarkdownActive]) return;
    CGFloat scale = spdf_mac_clamped_markdown_font_scale(round(_markdownFontScale * factor * 100.0) / 100.0);
    if (scale == _markdownFontScale) return;
    _markdownFontScale = scale;
    [self savePersistentState];
    [self.markdownState.activeSession applyFontScale:scale];
    [self updateControlsForActiveMarkdown];
}

- (void)decreaseMarkdownFontSize:(id)sender {
    (void)sender;
    [self changeMarkdownFontScaleByFactor:1.0 / 1.1];
}

- (void)increaseMarkdownFontSize:(id)sender {
    (void)sender;
    [self changeMarkdownFontScaleByFactor:1.1];
}

// Launch/reopen backstop. openPaths/selectTabAtIndex early-return when the
// target already is the selected tab and a document is "active" — but a
// stranded Loading markdown session still counts as an active document, so
// without this re-kick the strand would lock in behind those early returns
// (the exact lock-in the launch+open-restored-tab path used to hit).
// Idempotent: no-ops whenever the session has its render installed or work
// actually in flight.
- (void)ensureActiveMarkdownTabHasContent {
    if (![self isMarkdownActive]) return;
    [self.markdownState.activeSession ensureActiveSessionHasContent];
}

- (void)deactivateActiveMarkdownView {
    SPDFMacMarkdownDelegateState* state = self.markdownState;
    [state.viewportCheckpoint cancel];
    state.viewportCheckpoint = nil;
    [state.activeSession deactivate];
    state.activeSession = nil;
    state.hostView.hidden = YES;
    _pageScrollView.hidden = NO;
    [self setPDFToolbarViewsHiddenForMarkdown:NO];
}

- (BOOL)markdownCacheForTab:(SPDFDocumentTab*)tab
          matchesAttributes:(NSDictionary*)attributes
               fileIdentity:(NSString*)fileIdentity {
    return tab.cachedMarkdownSession &&
           spdf_mac_markdown_cache_matches(tab.cachedModificationDate, tab.cachedFileSize,
                                           tab.cachedMarkdownFileIdentity, attributes, fileIdentity);
}

- (void)configureMarkdownSession:(SPDFMacMarkdownSession*)session forTab:(SPDFDocumentTab*)tab {
    session.reader = (id<SPDFMacUIReader>)self;
    [self configureAIAnalysisForMarkdownSession:session path:tab.path];
    __weak ShenzhenMacDelegate* weakSelf = self;
    __weak SPDFMacMarkdownSession* weakSession = session;
    session.statusHandler = ^(NSString* status) {
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (strongSelf && strongSelf.markdownState.activeSession == weakSession)
          strongSelf->_statusLabel.stringValue = status ?: @"";
    };
    session.openExternalURLHandler = ^(NSURL* URL) {
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.markdownState.activeSession != weakSession || !spdf_is_allowed_external_url(URL)) {
          NSBeep();
          return;
      }
      [NSWorkspace.sharedWorkspace openURL:URL];
    };
    session.openDocumentHandler = ^(NSURL* URL, NSString* anchor) {
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.markdownState.activeSession != weakSession || !URL.isFileURL) return;
      NSInteger existing = [strongSelf indexOfTabForPath:URL.path];
      if (existing >= 0) {
          SPDFDocumentTab* destinationTab = strongSelf->_tabs[(NSUInteger)existing];
          destinationTab.markdownAnchor = anchor;
          if (existing == strongSelf->_selectedTabIndex) {
              [strongSelf.markdownState.activeSession navigateToAnchorWhenReady:anchor ?: @""];
          } else
              [strongSelf openPath:URL.path]; // Shows the tab even in a hidden or folded group.
          return;
      }
      [strongSelf openPath:URL.path];
      SPDFDocumentTab* destinationTab = [strongSelf selectedTab];
      destinationTab.markdownAnchor = anchor;
      [strongSelf.markdownState.activeSession navigateToAnchorWhenReady:anchor ?: @""];
    };
    [self configureMarkdownFindHandlersForSession:session tab:tab];
    session.viewportUpdateHandler = ^(NSInteger pageIndex, CGFloat zoom, SPDFMacMarkdownPageFitMode fitMode) {
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.markdownState.activeSession != weakSession || [strongSelf selectedTab] != tab)
          return;
      strongSelf->_pageIndex = pageIndex;
      strongSelf->_zoom = zoom;
      strongSelf->_fitMode = (SPDFFitMode)fitMode;
      tab.pageIndex = pageIndex;
      tab.zoom = zoom;
      tab.customZoom = fitMode == SPDFMacMarkdownPageFitCustom ? zoom : tab.customZoom;
      tab.fitMode = (SPDFFitMode)fitMode;
      // Its hover thumbnail follows the page shown, once the page settles.
      [strongSelf spdf_noteTabHoverPreviewSourcesChanged];
      // Capture the live scroll origin and checkpoint session.yaml after
      // movement settles; the helper is born here, never on ordinary launch.
      SPDFMacMarkdownDelegateState* state = strongSelf.markdownState;
      if (!state.viewportCheckpoint)
          state.viewportCheckpoint = [[SPDFMacViewportCheckpoint alloc] initWithDelay:0.5];
      spdf_schedule_markdown_checkpoint(state.viewportCheckpoint, strongSelf, tab, weakSession);
      if (state.controlsUpdateScheduled) return;
      state.controlsUpdateScheduled = YES;
      dispatch_async(dispatch_get_main_queue(), ^{
        state.controlsUpdateScheduled = NO;
        if (strongSelf.markdownState.activeSession == weakSession) {
            [strongSelf updateControlsForActiveMarkdown];
            [strongSelf updateMarkdownMinimap];
        }
      });
    };
}

- (void)loadSelectedMarkdownTab:(SPDFDocumentTab*)tab {
    SPDFMacMarkdownDelegateState* state = self.markdownState;
    NSString* path = [tab.path copy];
    [self ensureSecurityAccessForPath:path];
    NSDictionary* attributes = [self fileAttributesForPath:path];
    NSString* fileIdentity = spdf_mac_markdown_file_identity(path);
    if (!attributes) {
        tab.missingFile = YES;
        tab.missingMessage = @"File moved or deleted";
        [self showUnavailableSelectedTab:tab path:path message:tab.missingMessage showOpenError:NO error:NULL];
        return;
    }
    if (![self markdownCacheForTab:tab matchesAttributes:attributes fileIdentity:fileIdentity]) {
        if (tab.cachedMarkdownSession) [self collectionRecordObservedChangeAtPath:path];
        [tab clearCachedRuntime];
    }

    [self clearActiveMetadata];
    [self prepareSelectedTabViewState:tab path:path];
    _doc = NULL;
    _workingPath = path;
    _renderGeneration++;
    _pageScrollView.hidden = YES;
    state.hostView.hidden = NO;
    [self setPDFToolbarViewsHiddenForMarkdown:YES];
    [self setMinimapActuallyVisible:_minimapPreferredVisible];

    SPDFMacMarkdownSession* session = tab.cachedMarkdownSession;
    if (!session) {
        session = [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]
                                                            fontScale:_markdownFontScale
                                                         themeVariant:self.markdownThemeVariant];
        tab.cachedMarkdownSession = session;
    }
    // Cached sessions may predate a font-scale or theme change made in another
    // tab; adopting the global preferences here (before activation) lets
    // activation rerender the stale session once it is on screen. The paper
    // orientation comes from the TAB rather than a global preference — it is
    // this document's own, restored from "markdownLandscape" — but it reaches
    // the session by the same route and gets the same catch-up.
    [session applyFontScale:_markdownFontScale];
    [session applyThemeVariant:self.markdownThemeVariant];
    [session applyPageOrientation:tab.markdownLandscape ? SPDFMarkdownPageOrientationLandscape
                                                        : SPDFMarkdownPageOrientationPortrait];
    session.preservesImageColors = tab.preservesImageColors;
    state.activeSession = session;
    [self configureMarkdownSession:session forTab:tab];
    if (!state.workQueue)
        state.workQueue = dispatch_queue_create("com.intuition.shenzhenpdf.markdown", DISPATCH_QUEUE_CONCURRENT);
    tab.missingFile = NO;
    tab.missingMessage = @"";
    tab.title = spdf_display_name_for_path(path);
    _window.title = [NSString stringWithFormat:@"%@ - Shenzhen PDF", tab.title];
    _statusLabel.stringValue = @"Opening Markdown...";
    [self updateTabStrip];
    [self updateControlsForActiveMarkdown];

    NSString* anchor = tab.markdownAnchor;
    tab.markdownAnchor = nil;
    __weak ShenzhenMacDelegate* weakSelf = self;
    __weak SPDFMacMarkdownSession* weakSession = session;
    [session activateInHostView:state.hostView
                      workQueue:state.workQueue
                   scrollOrigin:tab.hasScrollOrigin ? tab.scrollOrigin : NSZeroPoint
                  selectedRange:tab.markdownSelectionRange
                      pageIndex:tab.pageIndex
                           zoom:tab.zoom > 0 ? tab.zoom : 1.0
                        fitMode:(SPDFMacMarkdownPageFitMode)tab.fitMode
                         anchor:anchor
                     completion:^(BOOL success, NSError* error) {
                       ShenzhenMacDelegate* strongSelf = weakSelf;
                       if (!strongSelf || strongSelf.markdownState.activeSession != weakSession ||
                           [strongSelf selectedTab] != tab)
                           return;
                       if (!success) {
                           tab.missingFile = NO;
                           tab.missingMessage = error.localizedDescription ?: @"Could not open Markdown document";
                           strongSelf->_statusLabel.stringValue = tab.missingMessage;
                       } else {
                           [strongSelf applySinglePageMinimapDefaultToTab:tab
                                                                pageCount:(NSInteger)weakSession.pageCount];
                           strongSelf->_minimapPreferredVisible = tab.showMinimap;
                           [strongSelf setMinimapActuallyVisible:strongSelf->_minimapPreferredVisible];
                           [strongSelf recordFileAttributes:attributes forTab:tab];
                           tab.cachedMarkdownFileIdentity = fileIdentity;
                           [strongSelf repointActiveFileWatcher]; // after the stat above
                           strongSelf->_statusLabel.stringValue = @"Markdown document ready.";
                           // Restored searches must not scroll away from the
                           // restored viewport (the PDF restore's revealMatch:NO).
                           if (tab.searchText.length)
                               [strongSelf startMarkdownFindForQuery:tab.searchText
                                                      preferredIndex:tab.findMatchIndex
                                                              reveal:NO];
                           [strongSelf rebuildSidebar];
                           [strongSelf updateMarkdownMinimap];
                           [strongSelf collectionDidOpenPath:path]; [strongSelf aiDocumentDidOpen:path];
                       }
                       [strongSelf updateControlsForActiveMarkdown];
                       /* After the control pass: it drops first responder. */
                       if (success) [strongSelf focusMarkdownViewAfterLoad];
                       [strongSelf savePersistentState];
                     }];
    [self rebuildSidebar];
    [self teardownActiveFileWatcher]; // re-pointed by the completion above
    [self rememberRecentlyOpenedPath:path];
    [self savePersistentState];
}

- (NSString*)markdownSelectedText {
    return self.markdownState.activeSession.selectedText ?: @"";
}

- (void)updateControlsForActiveMarkdown {
    if (![self isMarkdownActive]) return;
    SPDFMacMarkdownSession* session = self.markdownState.activeSession;
    [self setPDFToolbarViewsHiddenForMarkdown:YES];
    _pageIndex = session.currentPageIndex;
    _zoom = session.zoom;
    _fitMode = (SPDFFitMode)session.fitMode;
    NSInteger pageCount = (NSInteger)session.pageCount;
    [_pageSegments setEnabled:_pageIndex > 0 forSegment:0];
    [_pageSegments setEnabled:_pageIndex + 1 < pageCount forSegment:1];
    _pageField.hidden = NO;
    _pageCountLabel.hidden = NO;
    _pageSegments.hidden = NO;
    _fitModePopup.hidden = NO;
    _zoomSegments.hidden = NO;
    _pageField.enabled = pageCount > 0;
    [_zoomSegments setEnabled:pageCount > 0 forSegment:0];
    [_zoomSegments setEnabled:pageCount > 0 forSegment:1];
    _fitModePopup.enabled = pageCount > 0;
    _pageField.stringValue = pageCount ? [NSString stringWithFormat:@"%ld", (long)_pageIndex + 1] : @"";
    _pageCountLabel.stringValue = [NSString stringWithFormat:@"/ %ld", (long)pageCount];
    _searchField.hidden = NO;
    _searchField.enabled = session.state == SPDFMacMarkdownSessionReady;
    _sidebarToggleButton.enabled = session.state == SPDFMacMarkdownSessionReady;
    _minimapToggleButton.enabled = session.state == SPDFMacMarkdownSessionReady;
    _findRegexCheckbox.enabled = session.state == SPDFMacMarkdownSessionReady;
    // OCR needs a scanned raster, which a Markdown document never has.
    // Translate only needs text: it stays live for selection translation (see
    // SPDFMacTranslationPolicy.h).
    _ocrButton.enabled = NO;
    [self updateTranslateCommandEnablement];
    [self updateFindControls];
    [self syncToolbarState];
    NSString* title = [self displayNameForPathConsideringOpenTabs:_path];
    _window.title = [NSString stringWithFormat:@"%@ - Shenzhen PDF", title];
    if (pageCount)
        _statusLabel.stringValue = [NSString
            stringWithFormat:@"Page %ld of %ld    Zoom %.0f%%", (long)_pageIndex + 1, (long)pageCount, _zoom * 100.0];
}

- (BOOL)markdownHasChapters {
    return self.markdownState.activeSession.sidebarModel.chapterItems.count > 0 || [self aiGeneratedChapterRows].count > 0;
}

- (BOOL)markdownHasSearchSidebar {
    return [self isMarkdownActive] &&
           (_searchField.stringValue.length > 0 || _findSearchInProgress || _findMatches.count > 0);
}

- (void)rebuildMarkdownSidebar {
    [_sidebarItems removeAllObjects];
    SPDFMacMarkdownSession* session = self.markdownState.activeSession;
    SPDFMacMarkdownSidebarModel* model = session.sidebarModel;
    BOOL loading = !model && session.state == SPDFMacMarkdownSessionLoading;
    BOOL hasChapters = model.chapterItems.count > 0 || [self aiGeneratedChapterRows].count > 0;
    BOOL hasSearch = [self markdownHasSearchSidebar];
    BOOL hasSidebar = _sidebarModeControl != nil;

    [self syncSidebarModeControlSegmentsForSearchAvailability:hasSearch];
    if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch && !hasSearch)
        _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeChapters;
    else if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeComments)
        _sidebarModeControl.spdf_selectedSidebarMode = hasChapters ? SPDFSidebarModeChapters : SPDFSidebarModeSearch;
    else if (_sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeChapters && !hasChapters && hasSearch)
        _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeSearch;

    [_sidebarModeControl spdf_setEnabled:hasChapters forSidebarMode:SPDFSidebarModeChapters];
    if (hasSearch) [_sidebarModeControl spdf_setEnabled:YES forSidebarMode:SPDFSidebarModeSearch];
    [self syncSidebarFilterField];

    if (loading) {
        [_sidebarItems addObject:@{@"kind" : @"findStatus", @"title" : @"Loading chapters...", @"page" : @(-1)}];
    } else if (hasSidebar && _sidebarModeControl.spdf_selectedSidebarMode == SPDFSidebarModeSearch) {
        [_sidebarItems addObjectsFromArray:[model searchSidebarItemsForMatches:session.searchMatches
                                                                         query:_searchField.stringValue ?: @""
                                                                     searching:_findSearchInProgress]];
    } else if (hasChapters) {
        [_sidebarItems addObjectsFromArray:[model chapterItemsMatchingQuery:_chapterFilterText ?: @""]];
        [self appendAIGeneratedChaptersMatchingFilter:_chapterFilterText];
    }

    [self syncSidebarTableColumnWidth];
    [self applyChapterNestingAndReload];
    if (_sidebarItems.count > 0)
        [_sidebarTable
            noteHeightOfRowsWithIndexesChanged:[NSIndexSet
                                                   indexSetWithIndexesInRange:NSMakeRange(0, _sidebarItems.count)]];
    [self setSidebarActuallyVisible:hasSidebar && _sidebarPreferredVisible];
    if (hasSidebar && _sidebarVisible) [self restoreSidebarWidth];
    if (hasSidebar) [self selectCurrentSidebarRow];
}

- (void)activateMarkdownSidebarItem:(NSDictionary*)item {
    NSString* kind = item[@"kind"];
    if ([kind isEqualToString:@"findResult"]) {
        [self.markdownState.activeSession goToSearchMatchAtIndex:[item[@"findIndex"] integerValue]];
    } else if ([kind isEqualToString:@"chapter"]) {
        NSValue* rangeValue = item[@"range"];
        if ([rangeValue isKindOfClass:NSValue.class])
            [self.markdownState.activeSession revealRange:rangeValue.rangeValue];
    }
    [self updateControlsForActiveMarkdown];
    [self selectCurrentSidebarRow];
}

- (void)printActiveMarkdown {
    SPDFMacMarkdownSession* session = self.markdownState.activeSession;
    // Always the LIGHT rendition, like every other export (see
    // SPDFMacMarkdownSession.exportPaginationPlan). Free while the reader is
    // light: these ARE the live plan and string.
    SPDFMarkdownPaginationPlan* plan = session.exportPaginationPlan;
    NSAttributedString* text = session.exportAttributedString;
    if (![self isMarkdownActive] || !text || !plan) {
        NSBeep();
        return;
    }
    NSPrintOperation* operation =
        [SPDFMacMarkdownPrintAdapter printOperationForPaginationPlan:plan
                                                    attributedString:text
                                                           printInfo:[NSPrintInfo.sharedPrintInfo copy]];
    operation.jobTitle = _path.lastPathComponent ?: @"Markdown Document";
    [operation runOperationModalForWindow:_window delegate:nil didRunSelector:NULL contextInfo:NULL];
}

- (void)saveActiveMarkdownAsPDF {
    SPDFMacMarkdownSession* session = self.markdownState.activeSession;
    SPDFMarkdownPaginationPlan* plan = session.exportPaginationPlan;
    NSAttributedString* text = session.exportAttributedString;
    if (![self isMarkdownActive] || !text || !plan) {
        NSBeep();
        return;
    }
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.title = @"Save Markdown as PDF";
    panel.canCreateDirectories = YES;
    panel.nameFieldStringValue =
        [[_path.lastPathComponent stringByDeletingPathExtension] stringByAppendingPathExtension:@"pdf"];
    panel.allowedContentTypes = @[ UTTypePDF ];
    if ([panel runModal] != NSModalResponseOK) return;
    NSError* error = nil;
    if (![SPDFMacMarkdownPrintAdapter writePaginationPlan:plan
                                         attributedString:text
                                                    toURL:panel.URL
                                                    error:&error]) {
        [self showError:@"Could not save Markdown as PDF"
                 detail:error.localizedDescription ?: @"The PDF could not be written."];
        return;
    }
    _statusLabel.stringValue = @"Markdown PDF saved.";
}

@end
