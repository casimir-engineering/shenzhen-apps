#import "SPDFMacMarkdownSessionPrivate.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacMarkdownSourceRevision.h"

#import "SPDFMacMarkdownSidebarModel.h"
#import "SPDFMacMarkdownView.h"


@implementation SPDFMacMarkdownSession {
    NSUInteger _activationGeneration;
    // The current activation generation's initial parse+paginate pass is in
    // flight. Cleared by that pass's completion or by cancelAllOperations.
    BOOL _loadInFlight;
    // The live activation's completion, retained until the initial load (or
    // the fast install path) finishes so a cancelled-and-self-healed load
    // still reports back to the reader. Cleared by deactivate.
    void (^_pendingActivationCompletion)(BOOL, NSError*);
}

- (void)relocateDocumentToURL:(NSURL*)URL { _documentURL = [URL copy]; }
- (instancetype)initWithDocumentURL:(NSURL*)URL {
    return [self initWithDocumentURL:URL fontScale:1.0];
}

- (instancetype)initWithDocumentURL:(NSURL*)URL fontScale:(CGFloat)fontScale {
    return [self initWithDocumentURL:URL fontScale:fontScale themeVariant:SPDFMarkdownThemeVariantLight];
}

- (instancetype)initWithDocumentURL:(NSURL*)URL
                          fontScale:(CGFloat)fontScale
                       themeVariant:(SPDFMarkdownThemeVariant)themeVariant {
    NSParameterAssert(URL.isFileURL);
    self = [super init];
    if (!self) return nil;
    _documentURL = [URL copy];
    _searchMatches = @[];
    _currentMatchIndex = -1;
    _languageOverrides = [NSMutableDictionary dictionary];
    _fontScale = SPDFMacMarkdownClampFontScale(fontScale);
    _renderedFontScale = _fontScale;
    _themeVariant = themeVariant;
    _renderedThemeVariant = _themeVariant;
    _pendingReanchorLocation = NSNotFound;  // 0 is a real location; nil-ness is not
    _diagramCache = [SPDFMarkdownDiagramCache new];
    [self buildRootView];
    return self;
}

- (void)applyFontScale:(CGFloat)scale {
    CGFloat clamped = SPDFMacMarkdownClampFontScale(scale);
    if (clamped == _fontScale) return;
    _fontScale = clamped;
    if (_active && self.document) [self rerenderDocumentWithStatus:@"Text size updated."];
}

// The theme mirrors applyFontScale: exactly — an active session rerenders in
// place preserving the viewport; an inactive one adopts the preference and
// catches up on activation.
- (void)setPreservesImageColors:(BOOL)preservesImageColors {
    if (preservesImageColors == _preservesImageColors) return;
    _preservesImageColors = preservesImageColors;
    // Draw-time only: retarget the live plan instead of re-rendering, then
    // repaint. The canvas is the scroll view's document view, so the scroll
    // view's own setNeedsDisplay: never reached it and the change only showed
    // up after switching tabs and back.
    [_paginationPlan setPreservesImageColors:preservesImageColors];
    [_pagedView redrawPages];
    [_minimapModel invalidateThumbnails];
}

- (void)applyThemeVariant:(SPDFMarkdownThemeVariant)themeVariant {
    if (themeVariant == _themeVariant) return;
    _themeVariant = themeVariant;
    if (_active && self.document) [self rerenderDocumentWithStatus:@"Reading theme updated."];
}

- (BOOL)isNavigationReady {
    return _active && !_loadInFlight && !_reloadInFlight && !_renderToken &&
        self.state == SPDFMacMarkdownSessionReady && !self.renderTrailsPreferences &&
        _pagedView.superview && _pagedView.alphaValue >= 1;
}

- (NSString*)loadedSourceRevision { return SPDFMacMarkdownSourceRevision(self.document.model); }

- (SPDFMarkdownPaginationPlan*)paginationPlan {
    return _paginationPlan;
}

- (void)buildRootView {
    NSAssert(NSThread.isMainThread, @"Markdown AppKit views must be created on the main thread");
    _rootView = [[NSView alloc] init];
    _rootView.translatesAutoresizingMaskIntoConstraints = NO;
    _placeholder = [NSTextField labelWithString:@"Loading text..."];
    _placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    _placeholder.alignment = NSTextAlignmentCenter;
    _placeholder.textColor = SPDFCollectionColor(@"secondary");
    [_rootView addSubview:_placeholder];
    [NSLayoutConstraint activateConstraints:@[
        [_placeholder.centerXAnchor constraintEqualToAnchor:_rootView.centerXAnchor],
        [_placeholder.centerYAnchor constraintEqualToAnchor:_rootView.centerYAnchor],
    ]];
}

- (NSView*)rootView {
    return _rootView;
}
- (id<SPDFMacUIReader>)reader {
    return _reader;
}
- (void)setReader:(id<SPDFMacUIReader>)reader {
    _reader = reader;
    _pagedView.reader = reader;
}
- (NSTextView*)textView {
    return nil;
}
- (NSArray<SPDFMarkdownSearchMatch*>*)searchMatches {
    return _searchMatches ?: @[];
}
- (NSInteger)currentMatchIndex {
    return _currentMatchIndex;
}
- (NSPoint)scrollOrigin {
    return _pagedView ? _pagedView.contentView.bounds.origin : _pendingScrollOrigin;
}
- (NSRange)selectedRange {
    return _pagedView ? _pagedView.selectedRange : _pendingSelectedRange;
}
- (NSString*)selectedText {
    return _pagedView.selectedText ?: @"";
}
- (BOOL)selectionContainsImage {
    return [_pagedView selectionContainsImage];
}
- (BOOL)copySelectionToPasteboard:(NSPasteboard*)pasteboard plainTextTransform:(NSString* (^)(NSString*))transform {
    return [_pagedView writeSelectionToPasteboard:pasteboard plainTextTransform:transform];
}
- (NSUInteger)pageCount {
    return _pagedView.pageCount;
}
- (NSInteger)currentPageIndex {
    return _pagedView ? _pagedView.currentPageIndex : _pendingPageIndex;
}
- (NSUInteger)visibleAttributedLocation {
    return _pagedView ? _pagedView.visibleAttributedLocation : NSNotFound;
}
- (CGFloat)zoom {
    return _pagedView ? _pagedView.magnification : MAX(0.1, _pendingZoom);
}
- (SPDFMacMarkdownPageFitMode)fitMode {
    return _pagedView ? _pagedView.fitMode : _pendingFitMode;
}
- (NSArray<NSValue*>*)documentPageRects {
    return _pagedView.documentPageRects ?: @[];
}
- (NSRect)documentVisibleRect {
    return _pagedView ? _pagedView.documentVisibleRect : NSZeroRect;
}
- (NSSize)documentCanvasSize {
    return _pagedView ? _pagedView.documentCanvasSize : NSZeroSize;
}
- (SPDFMacMarkdownMinimapModel*)minimapModel {
    return _minimapModel;
}
- (SPDFMacMarkdownSidebarModel*)sidebarModel {
    return _sidebarModel;
}

- (void)attachToHostView:(NSView*)hostView {
    if (_rootView.superview != hostView) {
        [_rootView removeFromSuperview];
        [hostView addSubview:_rootView];
        [NSLayoutConstraint activateConstraints:@[
            [_rootView.topAnchor constraintEqualToAnchor:hostView.topAnchor],
            [_rootView.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
            [_rootView.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
            [_rootView.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor],
        ]];
    }
}

- (void)activateInHostView:(NSView*)hostView
                 workQueue:(dispatch_queue_t)workQueue
              scrollOrigin:(NSPoint)scrollOrigin
             selectedRange:(NSRange)selectedRange
                 pageIndex:(NSInteger)pageIndex
                      zoom:(CGFloat)zoom
                   fitMode:(SPDFMacMarkdownPageFitMode)fitMode
                    anchor:(NSString*)anchor
                completion:(void (^)(BOOL, NSError*))completion {
    NSAssert(NSThread.isMainThread, @"Markdown activation must occur on the main thread");
    // Activating again while the initial load is already in flight must not
    // cancel and restart it: adopt the new viewport/completion and let the
    // running load install with them (idempotent activation).
    BOOL adoptInFlightLoad = _active && _loadInFlight && !self.document;
    if (!adoptInFlightLoad) [self cancelAllOperations];
    _active = YES;
    _workQueue = workQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    _pendingScrollOrigin = scrollOrigin;
    _pendingSelectedRange = selectedRange;
    _pendingPageIndex = MAX(0, pageIndex);
    _pendingZoom = MAX(0.1, zoom);
    _pendingFitMode = fitMode;
    _pendingAnchor = [anchor copy];
    _pendingActivationCompletion = [completion copy];
    [self attachToHostView:hostView];
    if (self.document && self.renderedDocument) {
        [self installRenderedDocument:self.renderedDocument
                       paginationPlan:_paginationPlan
                    interactiveString:_interactiveString
                 preserveCurrentState:NO];
        // Catch up with a font scale, theme or paper changed while this
        // session was cached.
        if (self.renderTrailsPreferences) [self rerenderDocumentWithStatus:nil];
        [self finishActivationWithSuccess:YES error:nil];
        return;
    }
    if (adoptInFlightLoad) return;
    [self startInitialDocumentLoad];
}

// The initial parse+measure+paginate pass for the current activation
// generation. Callers guarantee no initial load is already in flight.
- (void)startInitialDocumentLoad {
    self.state = SPDFMacMarkdownSessionLoading;
    _placeholder.stringValue = @"Loading text...";
    _placeholder.hidden = NO;
    [_pagedView removeFromSuperview];
    _pagedView = nil;
    _loadInFlight = YES;
    NSUInteger activationGeneration = _activationGeneration;
    NSURL* URL = self.documentURL;
    SPDFMarkdownRenderOptions* renderOptions = [self renderOptionsForCurrentScale];
    SPDFMarkdownPageOrientation orientation = _pageOrientation;
    dispatch_queue_t workQueue = _workQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_async(workQueue, ^{
      NSError* error = nil;
      SPDFMarkdownPageConfiguration* paper = nil;
      SPDFMarkdownDocument* document = SPDFMacMarkdownLoadDocument(URL, renderOptions, orientation, nil, &paper, &error);
      SPDFMarkdownPaginationPlan* plan = nil;
      NSAttributedString* interactive = nil;
      if (document) {
          plan = SPDFMacMarkdownPlanForConfiguration(document.renderedDocument, renderOptions.themeVariant,
                                                self->_preservesImageColors, paper);
          interactive = SPDFMacMarkdownInteractiveString(document.model, document.renderedDocument);
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        // Only the live generation's load may clear the in-flight flag or
        // install: a cancel or a newer activation owns the session otherwise.
        if (activationGeneration != self->_activationGeneration) return;
        self->_loadInFlight = NO;
        if (!self->_active) return;
        if (!document) {
            self.state = SPDFMacMarkdownSessionFailed;
            self->_placeholder.stringValue = error.localizedDescription ?: @"Could not open text document.";
            [self finishActivationWithSuccess:NO error:error];
            return;
        }
        self.document = document;
        self.renderedDocument = document.renderedDocument;
        self->_paginationPlan = plan;
        self->_interactiveString = interactive;
        self->_renderedFontScale = renderOptions.fontScale;
        self->_renderedThemeVariant = renderOptions.themeVariant;
        self->_renderedOrientation = paper.orientation;
        if (self->_pageOrientation == orientation) self->_pageOrientation = paper.orientation;
        self.state = SPDFMacMarkdownSessionReady;
        [self installRenderedDocument:self.renderedDocument
                       paginationPlan:plan
                    interactiveString:interactive
                 preserveCurrentState:NO];
        // Catch up with a font scale, theme or paper applied while the first
        // render was in flight.
        if (self.renderTrailsPreferences) [self rerenderDocumentWithStatus:nil];
        [self finishActivationWithSuccess:YES error:nil];
      });
    });
}

- (void)finishActivationWithSuccess:(BOOL)success error:(NSError*)error {
    void (^activationCompletion)(BOOL, NSError*) = _pendingActivationCompletion;
    _pendingActivationCompletion = nil;
    if (activationCompletion) activationCompletion(success, error);
}

// Self-healing activation invariant: an active session must either have its
// rendered document installed or work actually in flight. Idempotent; main
// thread only. Cancels that land while the session stays on screen (e.g. the
// tab cache dropping its runtime cancels the very session the reader is
// displaying) re-enter here to restart whatever the cancel killed — without
// this the dropped load completion would strand the visible tab on the
// "Loading Markdown..." placeholder forever.
- (void)ensureActiveSessionHasContent {
    NSAssert(NSThread.isMainThread, @"Markdown session healing must occur on the main thread");
    if (!_active || _loadInFlight) return;
    if (self.document && self.renderedDocument) {
        if (!_pagedView)
            [self installRenderedDocument:self.renderedDocument
                           paginationPlan:_paginationPlan
                        interactiveString:_interactiveString
                     preserveCurrentState:NO];
        // Restart a cancelled font-scale/theme/paper catch-up rerender.
        if (!_renderToken && self.renderTrailsPreferences) [self rerenderDocumentWithStatus:nil];
        return;
    }
    [self startInitialDocumentLoad];
}


- (void)deactivate {
    _pendingScrollOrigin = self.scrollOrigin;
    _pendingSelectedRange = self.selectedRange;
    _pendingPageIndex = self.currentPageIndex;
    _pendingZoom = self.zoom;
    _pendingFitMode = self.fitMode;
    _active = NO;
    // The activation intent dies with the deactivation: its completion must
    // never fire late (the next activation supplies a fresh one).
    _pendingActivationCompletion = nil;
    [self clearMatchFlash];
    [self cancelAllOperations];
    // Downloads must not keep starting for a background tab; fetched bytes
    // stay cached so reactivation never re-downloads.
    [self cancelQueuedRemoteImageFetches];
    [_rootView removeFromSuperview];
}

- (void)cancelAllOperations {
    BOOL searchWasRunning = _searchToken != nil;
    [_searchToken cancel];
    [_renderToken cancel];
    _searchToken = nil;
    _renderToken = nil;
    _loadInFlight = NO;
    _reloadInFlight = NO;
    _activationGeneration++;
    _searchGeneration++;
    _renderGeneration++;
    if (searchWasRunning && self.searchUpdateHandler)
        self.searchUpdateHandler(_searchMatches.count, _currentMatchIndex, NO);
    // A cancel that leaves this session active (anything but deactivation)
    // must not strand the on-screen tab: the generation bump silently drops
    // every queued completion, so schedule an idempotent healing pass. It
    // no-ops whenever an activation restarted or reinstalled work first.
    if (_active) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self ensureActiveSessionHasContent];
        });
    }
}

- (void)dealloc {
    _active = NO; // teardown must never schedule the healing pass
    [self cancelAllOperations];
}

// Shared rerender flow for language overrides, font-scale, theme and paper
// changes: every pass renders with the session's current font scale, theme and
// orientation so any kind of change survives the others. A nil/empty status
// skips the status callback.
- (void)rerenderDocumentWithStatus:(NSString*)status {
    _reloadInFlight = NO; // This generation supersedes any source reload.
    [_renderToken cancel];
    _renderGeneration++;
    NSUInteger renderGeneration = _renderGeneration;
    CGFloat fontScale = _fontScale;
    SPDFMarkdownThemeVariant themeVariant = _themeVariant;
    SPDFMarkdownPageOrientation orientation = _pageOrientation;
    SPDFMarkdownPageConfiguration* paper = self.currentPageConfiguration;
    NSDictionary* overrides = [_languageOverrides copy];
    __weak SPDFMacMarkdownSession* weakSelf = self;
    _renderToken = [self.document
        renderWithOptions:[self renderOptionsForCurrentScale]
        languageOverrides:overrides
                workQueue:_workQueue
          completionQueue:_workQueue
               completion:^(SPDFMarkdownRenderedDocument* rendered, BOOL cancelled) {
                 SPDFMacMarkdownSession* strongSelf = weakSelf;
                 if (!strongSelf || cancelled || !strongSelf->_active ||
                     renderGeneration != strongSelf->_renderGeneration || !rendered)
                     return;
                 SPDFMarkdownPaginationPlan* plan =
                     SPDFMacMarkdownPlanForConfiguration(rendered, themeVariant, self->_preservesImageColors, paper);
                 NSAttributedString* interactive =
                     SPDFMacMarkdownInteractiveString(strongSelf.document.model, rendered);
                 dispatch_async(dispatch_get_main_queue(), ^{
                   SPDFMacMarkdownSession* mainSelf = weakSelf;
                   if (!mainSelf || cancelled || !mainSelf->_active || renderGeneration != mainSelf->_renderGeneration)
                       return;
                   mainSelf->_renderToken = nil;
                   mainSelf.renderedDocument = rendered;
                   mainSelf->_paginationPlan = plan;
                   mainSelf->_interactiveString = interactive;
                   mainSelf->_renderedFontScale = fontScale;
                   mainSelf->_renderedThemeVariant = themeVariant;
                   mainSelf->_renderedOrientation = orientation;
                   [mainSelf installRenderedDocument:rendered
                                      paginationPlan:plan
                                   interactiveString:interactive
                                preserveCurrentState:YES];
                   // The attributed string changed: re-run the active search so
                   // match ranges can't go stale (the same match index is kept
                   // when the count still fits, else it clamps), without
                   // scrolling away from the preserved viewport.
                   if (mainSelf->_activeSearchQuery.length)
                       [mainSelf searchForQuery:mainSelf->_activeSearchQuery
                                          regex:mainSelf->_activeSearchRegex
                                 preferredIndex:mainSelf->_currentMatchIndex
                                  jumpToNearest:NO
                                         reveal:NO];
                   if (status.length && mainSelf.statusHandler) mainSelf.statusHandler(status);
                   if (mainSelf.renderInstalledHandler) mainSelf.renderInstalledHandler();
                 });
               }];
}

@end
