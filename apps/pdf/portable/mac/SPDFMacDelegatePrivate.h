#import <Cocoa/Cocoa.h>

#import "SPDFMacDocumentView.h"
#import "SPDFMacFileWatcher.h"
#import "SPDFMacMinimapView.h"
#import "SPDFMacMinimapWindow.h"
#import "SPDFMacModels.h"
#import "SPDFMacPrintView.h"
#import "SPDFMacTabStripView.h"
#import "SPDFMacUIHelpers.h"
#import "SPDFMacWindowShortcuts.h"

#include "shenzhen_pdf_core.h"

@class SPDFRenderOperation; /* NSBlockOperation + spdf_render_token, defined in ShenzhenPDFMac.mm */
@interface ShenzhenMacDelegate : NSObject <NSApplicationDelegate,
                                           NSWindowDelegate,
                                           NSSplitViewDelegate,
                                           NSTableViewDataSource,
                                           NSTableViewDelegate,
                                           NSSearchFieldDelegate,
                                           NSTextFieldDelegate,
                                           NSMenuDelegate,
                                           NSMenuItemValidation> {
    NSWindow* _window;
    SPDFTabStripView* _tabStrip;
    SPDFToolbarStackView* _toolbar;
    NSMenu* _windowMenu;
    NSSplitView* _splitView;
    NSTableView* _sidebarTable;
    NSView* _sidebarContainer;
    NSView* _documentContainer;
    SPDFSidebarDividerView* _sidebarDividerView;
    SPDFScrollView* _pageScrollView;
    SPDFDocumentView* _pageView;
    SPDFMinimapView* _minimapView;
    SPDFMinimapDividerView* _minimapDividerView;
    SPDFFindMarkerScroller* _markerScroller;
    SPDFPresentationOverlayView* _presentationOverlayView;
    NSLayoutConstraint* _minimapWidthConstraint;
    NSLayoutConstraint* _minimapDividerWidthConstraint;
    NSLayoutConstraint* _pageScrollToMinimapConstraint;
    NSLayoutConstraint* _pageScrollFullWidthConstraint;
    NSLayoutConstraint* _tabStripHeightConstraint;
    NSLayoutConstraint* _toolbarHeightConstraint;
    NSSegmentedControl* _pageSegments;
    NSTextField* _pageField;
    NSTextField* _pageCountLabel;
    NSSegmentedControl* _zoomSegments;
    NSPopUpButton* _fitModePopup;
    NSButton* _sidebarToggleButton;
    NSButton* _minimapToggleButton;
    NSSearchField* _searchField;
    NSButton* _findRegexCheckbox;
    BOOL _findRegexMultiline;
    NSButton* _ocrButton;
    NSButton* _translateButton;
    NSSegmentedControl* _markdownFontSizeSegments;
    NSSegmentedControl* _readingThemeButton;  // single-segment pill, not a button
    NSBox* _ocrSeparator;
    NSSegmentedControl* _findSegments;
    NSTextField* _findCountLabel;
    NSView* _toolbarSpacer;
    NSButton* _toolbarOverflowButton;
    NSMenu* _toolbarOverflowMenu;
    NSMenu* _recentlyOpenedMenu;
    NSTextField* _statusLabel;
    NSControl* _sidebarModeControl;
    NSSearchField* _sidebarFilterField;
    NSLayoutConstraint* _sidebarFilterTopConstraint;
    NSLayoutConstraint* _sidebarScrollBelowFilterConstraint;
    NSLayoutConstraint* _sidebarScrollBelowModeConstraint;
    NSPanel* _palettePanel;
    NSSearchField* _paletteSearchField;
    NSButton* _paletteAllDocsCheckbox;
    NSTableView* _paletteTable;
    NSPanel* _ocrInstallPanel;
    NSProgressIndicator* _ocrInstallProgress;
    NSTextView* _ocrInstallLog;
    NSTask* _ocrInstallTask;
    NSPanel* _ocrProgressPanel;
    NSTextField* _ocrProgressTitleLabel;
    NSTextField* _ocrProgressDetailLabel;
    NSProgressIndicator* _ocrProgressIndicator;
    NSPanel* _translationInstallPanel;
    NSTextField* _translationInstallTitleLabel;
    NSProgressIndicator* _translationInstallProgress;
    NSTextView* _translationInstallLog;
    NSTask* _translationInstallTask;
    NSPanel* _translationProgressPanel;
    NSTextField* _translationProgressTitleLabel;
    NSTextField* _translationProgressDetailLabel;
    NSProgressIndicator* _translationProgressIndicator;
    NSButton* _translationProgressCancelButton;
    NSPanel* _selectionTranslationPanel;
    NSPopUpButton* _selectionTranslationSourcePopup;
    NSPopUpButton* _selectionTranslationTargetPopup;
    NSTextView* _selectionTranslationInputView;
    NSTextView* _selectionTranslationOutputView;
    NSTextField* _selectionTranslationStatusLabel;
    NSButton* _selectionTranslationButton;
    NSTask* _translationTask;
    NSPanel* _commentPanel;
    NSTextField* _commentLabel;
    NSPanel* _aboutPanel;
    NSPanel* _permissionsWizardPanel;
    BOOL _pendingShortcutHelpAfterPermissions;
    NSPanel* _shortcutHelpPanel;
    NSSearchField* _shortcutHelpSearchField;
    NSTableView* _shortcutHelpTable;
    NSButton* _shortcutHelpDisableButton;
    NSMutableArray<NSDictionary*>* _shortcutHelpRows;
    NSMutableArray<NSDictionary*>* _paletteResults;
    NSArray<NSDictionary*>* _paletteMenuCommandCandidates;
    NSInteger _paletteMode;
    NSUInteger _paletteSearchGeneration;
    id _paletteEventMonitor;
    id _windowArrangementShortcutMonitor;
    id _keyScrollKeyUpMonitor;
    id _presentationEventMonitor;
    id _presentationGlobalEventMonitor;
    NSOperationQueue* _renderQueue;
    NSOperationQueue* _zoomSeedRenderQueue;
    NSOperationQueue* _cacheRenderQueue;
    NSOperationQueue* _backgroundRenderQueue;
    NSOperationQueue* _minimapQueue;
    NSOperationQueue* _preloadQueue;
    NSOperationQueue* _findQueue;
    NSMutableSet<NSNumber*>* _queuedRenderPages;
    NSMutableDictionary<NSNumber*, NSOperation*>* _queuedRenderOperations;
    NSMutableSet<NSNumber*>* _queuedBaseRenderPages;
    NSMutableDictionary<NSNumber*, NSOperation*>* _queuedBaseRenderOperations;
    NSMutableSet<NSNumber*>* _queuedHighQualityRenderPages;
    NSMutableDictionary<NSNumber*, NSOperation*>* _queuedHighQualityRenderOperations;
    NSMutableSet<NSNumber*>* _queuedMinimapThumbnailPages;
    /* page -> queued minimap-thumbnail op (weak values, auto-cleared when an
     * op finishes), so a recentered thumbnail window can cancel renders that
     * fell out of the window. */
    NSMapTable<NSNumber*, SPDFRenderOperation*>* _queuedMinimapThumbnailOperations;
    /* Current windowed-lazy-loading page window for minimap thumbnails; kept
     * across updates so recentering has hysteresis (see SPDFMacMinimapWindow.h).
     * Zero-initialized {0, 0} is a harmless 1-page window; recomputed on the
     * first thumbnail enqueue. */
    SPDFMinimapThumbnailWindow _minimapThumbnailWindow;
    /* Last enqueued visible-crop / pan-crop render ops, weakly held so a newly
     * enqueued successor can cancel (cookie-abort) a superseded in-flight one. */
    __weak SPDFRenderOperation* _lastVisibleCropRenderOperation;
    __weak SPDFRenderOperation* _lastPanCropRenderOperation;
    NSTimer* _findFlashTimer;
    NSTimeInterval _findFlashStartTime;

    spdf_document* _doc;
    spdf_outline _outline;
    spdf_comments _comments;
    BOOL _activeMetadataBorrowed;
    BOOL _windowLiveResizing;
    SPDFDocumentTab* _activeMetadataTab;
    NSMutableArray<NSDictionary*>* _sidebarItems;
    NSString* _chapterFilterText;
    NSString* _commentFilterText;
    NSMutableArray<SPDFRenderedPage*>* _renderedPages;
    NSMutableArray<SPDFDocumentTab*>* _tabs;
    NSMutableArray<NSDictionary*>* _favorites;
    NSMutableDictionary<NSString*, NSMutableDictionary*>* _documentStates;
    NSMutableArray<NSString*>* _recentlyOpenedPaths;
    NSMutableArray<NSString*>* _closedDocumentPaths;
    // path -> security-scoped bookmark, for App Sandbox file access across launches.
    NSMutableDictionary<NSString*, NSData*>* _securityBookmarks;
    NSMutableSet<NSURL*>* _activeSecurityScopedURLs;
    NSDictionary* _paletteFavoritePendingDelete;
    NSMutableDictionary<NSNumber*, NSArray<NSValue*>*>* _findHighlights;
    NSMutableArray<NSDictionary*>* _findMatches;
    NSMutableSet<NSString*>* _preloadingPaths;
    NSMutableDictionary<NSString*, NSString*>* _preloadTokens;
    NSMutableDictionary* _preloadResults;
    // Launch-only deferred open of a cloud-backed active tab (see
    // loadSelectedTab): set while performStartupDocumentWork runs so the
    // restored active document can be opened off the main thread when it
    // lives on cloud storage instead of blocking the first paint.
    BOOL _startupDocumentWorkInProgress;
    // Identity token for the in-flight deferred cloud open; any subsequent
    // loadSelectedTab supersedes it and the stale completion abandons.
    NSString* _pendingDeferredCloudOpenToken;
    NSUInteger _findGeneration;
    BOOL _findSearchInProgress;
    // Per-page cursor-region caches (page-space text-line + link rects) behind
    // the hover cursor: built once per page off-main, hit-tested per mouse-move.
    NSOperationQueue* _cursorRegionQueue;
    NSMutableDictionary<NSNumber*, NSDictionary*>* _cursorRegionCache;
    NSMutableSet<NSNumber*>* _cursorRegionPagesBuilding;
    NSUInteger _cursorRegionGeneration;
    NSString* _path;
    // Render/read path for the active document. Equals a private read-only temp
    // copy when the active source (_path) is read-only, else equals _path. Only
    // document-open/render/read-content sites consume it; _path stays the SOURCE.
    NSString* _workingPath;
    // One-shot guard so the orphaned read-only-copy sweep runs only once, after
    // the primary launch's first-paint catch-up save.
    BOOL _didSweepReadOnlyCopies;
    NSString* _pendingOpenPath;
    NSMutableArray<NSString*>* _pendingOpenPaths;
    NSInteger _pageIndex;
    NSInteger _highlightPageIndex;
    NSInteger _findMatchIndex;
    // Settings toggle: a new search selects the match nearest the current
    // viewport (default) instead of match #1.
    BOOL _searchJumpsToNearestResult;
    NSInteger _selectionPageIndex;
    NSString* _selectedText;
    BOOL _collapseWhitespaceWhenCopyingText;
    NSInteger _contextPageIndex;
    NSPoint _contextPagePoint;
    NSInteger _contextCommentIndex;
    NSString* _commentAuthor;
    NSString* _translationSourceLanguage;
    NSString* _translationTargetLanguage;
    CGFloat _zoom;
    CGFloat _rememberedCustomZoom;
    SPDFFitMode _fitMode;
    NSInteger _selectedTabIndex;
    NSUInteger _renderGeneration;
    NSTimer* _zoomFinishTimer;
    // Smooth keyboard arrow scrolling, two axes (vertical up/down, horizontal
    // left/right). Hold is detected by real key release rather than auto-repeat
    // timing: a keyDown sets _keyScrollKeyDown (and remembers _keyScrollKeyCode)
    // and a keyUp local monitor clears it, so the ramp accelerates toward the cap
    // for the whole hold with no mid-hold stall, then decelerates on release. The
    // idle timeout is a safety keep-alive only (covers a missed keyUp). Velocity
    // is in pt/s, signed by direction along the active axis (+down/-up,
    // +right/-left in clip-view origin space). Axis 0 = vertical, 1 = horizontal.
    NSTimer* _keyScrollTimer;
    CGFloat _keyScrollVelocity;
    CGFloat _keyScrollDirection;      // -1 / +1 along the active axis, or 0 (idle)
    NSInteger _keyScrollAxis;         // 0 = vertical (y), 1 = horizontal (x)
    BOOL _keyScrollKeyDown;           // YES from keyDown until the matching keyUp
    unsigned short _keyScrollKeyCode; // keyCode of the held arrow
    NSTimeInterval _keyScrollLastEventTime;
    NSTimeInterval _keyScrollLastTickTime;
    NSUInteger _liveZoomSequence;
    NSInteger _liveZoomAnchorPageIndex;
    NSPoint _liveZoomAnchorPagePoint;
    NSPoint _liveZoomAnchorOffsetInViewport;
    BOOL _liveZoomAnchorValid;
    BOOL _uiReady;
    BOOL _updatingSelection;
    BOOL _updatingFromScroll;
    BOOL _suppressScrollCallbacks;
    BOOL _suppressViewportRerender;
    BOOL _liveZooming;
    BOOL _liveZoomQueuesPaused;
    BOOL _liveZoomMinimapUpdateScheduled;
    BOOL _documentViewPanActive;
    BOOL _documentViewPanCropInFlight;
    BOOL _documentViewPanMaintenanceScheduled;
    BOOL _scrollMaintenanceScheduled;
    // Counts coalesced scroll-maintenance ticks so the heavy prefetch/eviction
    // pass runs at a coarser cadence than the per-tick crop refresh.
    NSUInteger _scrollMaintenanceTickCount;
    // Coalesces the per-render-completion bookkeeping (eviction sweep + idle
    // minimap refresh) so a burst of completing prefetch renders doesn't run that
    // heavy work once per page on the main thread.
    BOOL _renderAdoptionMaintenanceScheduled;
    NSUInteger _scrollIdleMinimapRefreshGeneration;
    NSUInteger _documentViewPanCropGeneration;
    NSUInteger _visibleCropRenderSequence;
    NSTimeInterval _lastDocumentPanLiveCropRenderTime;
    NSUInteger _viewportMovementGeneration;
    BOOL _minimapPrecisionViewportDragActive;
    // Horizontal scroll lock: narrow pages (width <= viewport) block horizontal
    // panning and stay centered; wide pages unlock it. Crossing from a wide page
    // back to narrow pages eases the viewport back to center.
    NSTimer* _horizontalLockEaseTimer;
    CGFloat _horizontalLockEaseStartX;
    CGFloat _horizontalLockEaseTargetX;
    NSTimeInterval _horizontalLockEaseStartTime;
    // Coalesces the heavier per-page-change work (zoom-seed caches, neighbor
    // renders, control + sidebar refresh) off the scroll frame so crossing a
    // page boundary doesn't hitch.
    BOOL _pageChangeFollowUpScheduled;
    BOOL _defaultSidebarVisibleForNewDocuments;
    BOOL _defaultMinimapVisibleForNewDocuments;
    BOOL _sidebarPreferredVisible;
    BOOL _sidebarVisible;
    BOOL _minimapPreferredVisible;
    BOOL _minimapVisible;
    // One-shot: set when a document becomes active (open / tab switch) so the
    // FIRST visible minimap thumbnail band renders at UserInitiated QoS instead
    // of Utility. Without this, on a busy launch (many restored tabs warming) or
    // when switching into a tab while a large document is rendering, the
    // thumbnail renders sit behind the page-render and warming work and the
    // strip fills in late. Scroll-driven thumbnail enqueues stay at Utility so
    // the prior anti-stutter behaviour is preserved.
    BOOL _minimapInitialPopulationPending;
    BOOL _presentationMode;
    BOOL _presentationEnteredFullScreen;
    BOOL _presentationUsingBorderlessWindow;
    NSRect _presentationPreviousWindowFrame;
    NSWindowStyleMask _presentationPreviousWindowStyleMask;
    NSInteger _presentationPreviousWindowLevel;
    NSWindowCollectionBehavior _presentationPreviousCollectionBehavior;
    NSWindowTitleVisibility _presentationPreviousTitleVisibility;
    BOOL _presentationPreviousTitlebarAppearsTransparent;
    BOOL _presentationPreviousMovable;
    BOOL _presentationPreviousMovableByWindowBackground;
    BOOL _presentationPreviousHasShadow;
    BOOL _windowMenuTemporarilyEnabledMovable;
    BOOL _windowMenuPreviousMovable;
    SEL _pendingWindowArrangementAction;
    NSTimeInterval _lastPresentationEventTimestamp;
    NSEventType _lastPresentationEventType;
    NSInteger _lastPresentationEventKeyCode;
    NSInteger _lastPresentationEventButtonNumber;
    SPDFFitMode _presentationPreviousFitMode;
    BOOL _presentationPreviousSidebarPreferredVisible;
    BOOL _presentationPreviousMinimapPreferredVisible;
    BOOL _preventSleepInPresentation;
    id<NSObject> _presentationSleepActivityToken;
    BOOL _fullDiskAccessPromptDismissed;
    BOOL _permissionsWizardShown;
    BOOL _ocrInstallRunning;
    BOOL _translationRunning;
    BOOL _translationInstallRunning;
    BOOL _translationCancelRequested;
    NSUInteger _selectionTranslationGeneration;
    BOOL _showShortcutHelpOnLaunch;
    BOOL _autoUpdateEnabled;
    NSString* _skippedUpdateVersion;
    BOOL _defaultReaderPromptDismissed;
    BOOL _tabStripCapturingMouse;
    BOOL _tabStripCapturingMiddleMouse;
    BOOL _terminateOnlyThisProcess;
    BOOL _suppressSessionWriteOnTerminate;
    BOOL _suspendPersistentStateSaves;
    BOOL _needsDeferredPersistentStateSave;
    BOOL _updatingSidebarFilterField;
    NSArray<NSDictionary*>* _pendingTranslationItems;
    NSArray<NSDictionary*>* _pendingTranslationChapters;  // written as the translation's outline (SPDFMacTranslateChapters.h)
    BOOL _translatingMadePDF;  // the local translation works on a PDF made from a Markdown, text or EPUB document
    BOOL _restoringSidebarLayout;
    BOOL _allowSidebarWidthPersistence;
    CGFloat _sidebarWidth;
    CGFloat _minimapWidth;
    SPDFPrintScalingMode _printScalingMode;
    CGFloat _printCustomScale;
    // Persisted Markdown typography multiplier applied to every Markdown
    // document (settings.yaml "markdownFontScale", clamped [0.5, 3.0]).
    CGFloat _markdownFontScale;
    // Persisted reading theme applied to EVERY document, Markdown or rendered
    // (settings.yaml "markdownTheme": "light"/"dark" -- the key kept its
    // original name so the choice already in users' settings carries over with
    // no migration). BOOL keeps this header free of markdown-module types;
    // SPDFMacReadingThemeIntegration.mm maps it to SPDFMarkdownThemeVariant.
    BOOL _darkReadingTheme;
    // Keep-image-colors is per document (SPDFDocumentTab.preservesImageColors).
    // This mirrors the SELECTED tab's value so the background render wrappers
    // stay a plain byte read; the default seeds a document that has no stored
    // choice (settings.yaml "darkThemePreservesImages", default YES).
    BOOL _darkThemePreservesImages;
    BOOL _darkThemePreservesImagesDefault;
    NSSize _restoredWindowContentSize;
    NSRect _restoredWindowFrame;
    BOOL _hasRestoredWindowFrame;
    NSString* _windowSessionID;
    NSMutableArray<NSString*>* _pendingRestoreWindowIDs;
    NSInteger _pendingFindPreferredPage;
    NSInteger _pendingFindPreferredMatchIndex;
    SPDFRenderedPage* _launchPrerenderedFirstPage;
    spdf_outline _launchPrerenderedOutline;
    BOOL _launchPrerenderedOutlineLoaded;
    spdf_comments _launchPrerenderedComments;
    BOOL _launchPrerenderedCommentsLoaded;
    spdf_document* _launchPrerenderedMetadataDocument;
    BOOL _launchPrerenderSidebarExpected;
    BOOL _suppressToolbarOverflowUpdates;
    // Lazily created watcher for the active (frontmost) tab's file; nil until
    // the first document becomes active. Re-pointed on every tab activation,
    // torn down on close/terminate. See "Auto-reload on disk change" section.
    SPDFMacFileWatcher* _activeFileWatcher;
    // Guards against a reload triggered by our own in-flight reopen.
    BOOL _reloadInProgress;
}
@property(nonatomic, copy) NSString* initialPath;
@property(nonatomic, copy) NSString* restoreWindowID;
@property(nonatomic) BOOL detachedTabLaunch;
/* One-time flock-guarded JSON -> YAML state-file migration; must run before
   anything reads state, including startLaunchPrerender's session peek. */
- (void)migrateStateFilesIfNeeded;
- (BOOL)scrollViewShouldTurnWheelIntoPageChange:(NSEvent*)event;
- (BOOL)zoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)zoomWithMagnifyEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)zoomWithMagnifyDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)zoomByFactor:(CGFloat)factor centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)beginLiveZoomByFactor:(CGFloat)factor centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)cancelPendingLiveZoomCompletion;
- (void)documentScrollPositionChanged;
- (NSInteger)documentViewCurrentPageIndex;
- (SPDFCursorRegionKind)documentViewCursorRegionAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint;
- (void)invalidateCursorRegionCache;
- (void)buildCursorRegionsForPageIfNeeded:(NSInteger)pageIndex;
- (BOOL)documentViewOpenLinkAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint;
- (BOOL)documentViewSelectionChangedOnPage:(NSInteger)pageIndex from:(NSPoint)start to:(NSPoint)end;
- (void)documentViewDidBeginPan;
- (void)documentViewDidFinishPanMotion;
- (void)cancelDocumentTransientInteraction;
- (BOOL)handleTabStripMouseEvent:(NSEvent*)event;
- (void)copySelection:(id)sender;
- (void)searchSelectedTextInBrowser:(id)sender;
- (void)showSelectionTranslationPanel:(id)sender;
- (void)runSelectionTranslationFromPanel:(id)sender;
- (void)saveDocumentAs:(id)sender;
- (BOOL)saveActiveDocumentAsWithPanelTitle:(NSString*)panelTitle statusMessage:(NSString*)statusMessage;
- (BOOL)ensureActivePDFCanBeModifiedForOperation:(NSString*)operationName;
- (void)translateDocumentLocally:(id)sender;
- (void)rotateClockwise:(id)sender;
- (void)rotateAnticlockwise:(id)sender;
- (SPDFDocumentTab*)tabSnapshotForDragAtIndex:(NSInteger)index;
- (void)insertDraggedTab:(SPDFDocumentTab*)tab atIndex:(NSInteger)index;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)closeTabAtIndex:(NSInteger)index;
- (void)copyTabPathToPasteboardAtIndex:(NSInteger)index;
- (void)moveTabFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex;
- (void)detachTabAtIndex:(NSInteger)index;
- (void)newTabRequested:(id)sender;
- (void)previousPage:(id)sender;
- (void)nextPage:(id)sender;
- (void)performWindowArrangementAction:(SEL)action sender:(id)sender;
- (void)drainPendingWindowArrangementAction;
- (BOOL)deferWindowArrangementActionIfNeeded:(SEL)action sender:(id)sender;
- (void)installWindowArrangementShortcutMonitor;
- (void)removeWindowArrangementShortcutMonitor;
- (void)openPath:(NSString*)path;
- (void)openPaths:(NSArray<NSString*>*)paths;
- (void)openRecentDocument:(id)sender;
- (void)reopenLastClosedDocument:(id)sender;
- (void)focusFind:(id)sender;
- (void)paste:(id)sender;
- (void)startSearchForText:(NSString*)query;
- (void)showFindPalette:(id)sender;
- (void)toggleFindRegex:(id)sender;
- (void)toggleFindRegexMultiline:(id)sender;
- (void)toggleCollapseWhitespaceWhenCopyingText:(id)sender;
- (void)openStateFile:(id)sender;
- (void)revealSettingsFolder:(id)sender;
- (void)toggleDefaultSidebarForNewDocuments:(id)sender;
- (void)toggleDefaultMinimapForNewDocuments:(id)sender;
- (void)toggleSearchJumpsToNearestResult:(id)sender;
- (NSString*)documentStateKeyForPath:(NSString*)path;
- (void)applyStoredDocumentStateToTab:(SPDFDocumentTab*)tab;
- (void)saveDocumentStateForTab:(SPDFDocumentTab*)tab;
- (void)paletteMoveSelection:(NSInteger)delta;
- (void)closePalette:(id)sender;
- (void)activatePaletteSelection:(id)sender;
- (void)paletteFavoriteDeleteClicked:(id)sender;
- (SPDFDocumentView*)newDocumentView;
- (void)replaceDocumentViewForTabSwitch;
- (SPDFDocumentTab*)selectedTab;
- (void)clearActiveMetadata;
- (void)adoptCachedMetadataForTab:(SPDFDocumentTab*)tab;
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab;
- (void)closeActiveDocumentIfUnowned;
- (void)cancelInactiveTabPreloads;
- (BOOL)preloadToken:(NSString*)token isCurrentForPath:(NSString*)standardizedPath;
- (void)finishPreloadForPath:(NSString*)standardizedPath token:(NSString*)token;
- (void)updateFindControls;
- (void)updateMinimap;
- (void)showEmptyDocumentViewWithMessage:(NSString*)message;
- (void)repointActiveFileWatcher;
- (void)teardownActiveFileWatcher;
- (void)reloadSelectedTabFromDiskChange;
- (void)checkAllTabsForExternalChangesOnFocus;
// Renders one page off the given document at an explicit zoom and scale. The
// reading theme rides along through -readingThemeRenderFlags, so callers that
// must have the document's own colors (Copy Page Image) clear it first.
- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex
                                document:(spdf_document*)doc
                                    zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale
                                   error:(char*)err
                             errorLength:(size_t)errLen;
- (void)renderDocumentAndScrollToPage:(NSInteger)pageIndex alignTop:(BOOL)alignTop;
- (void)renderDocumentAndScrollToPage:(NSInteger)pageIndex
                             alignTop:(BOOL)alignTop
                        restoreOrigin:(NSValue*)restoreOrigin;
- (CGFloat)zoomForFitMode:(SPDFFitMode)fitMode pageIndex:(NSInteger)pageIndex;
- (CGFloat)zoomForFitMode:(SPDFFitMode)fitMode
                 pageSize:(NSSize)pageSize
                 clipSize:(NSSize)clipSize
             fallbackZoom:(CGFloat)fallbackZoom;
- (void)scrollToPage:(NSInteger)pageIndex alignTop:(BOOL)alignTop;
- (void)scrollDocumentClipViewToOrigin:(NSPoint)origin notify:(BOOL)notify;
- (void)scrollDocumentClipViewToOrigin:(NSPoint)origin pageIndexHint:(NSInteger)pageIndex notify:(BOOL)notify;
- (void)scrollDocumentClipViewToDocumentOrigin:(NSPoint)origin notify:(BOOL)notify;
- (NSPoint)normalizedDocumentScrollOrigin:(NSPoint)origin forPageIndex:(NSInteger)pageIndex;
- (CGFloat)presentationCenteredScrollOriginYForPageIndex:(NSInteger)pageIndex;
- (void)stabilizeDocumentLayoutWithRestoreOrigin:(NSValue*)restoreOrigin
                                        alignTop:(BOOL)alignTop
                                      generation:(NSUInteger)generation
                                            path:(NSString*)path;
- (void)minimapViewDidRequestScrollToFraction:(CGFloat)yFraction;
- (void)minimapViewDidRequestViewportTopFraction:(CGFloat)yFraction;
- (void)minimapViewDidRequestViewportTopFraction:(CGFloat)yFraction documentCenterX:(CGFloat)documentCenterX;
- (void)minimapViewDidFinishViewportDrag;
- (void)minimapViewDidRequestScrollToPage:(NSInteger)pageIndex yFractionInPage:(CGFloat)yFraction;
- (void)minimapViewDidRequestCenterAtDocumentPoint:(NSPoint)documentPoint;
- (void)minimapViewDidRequestCenterOnPage:(NSInteger)pageIndex
                          xFractionInPage:(CGFloat)xFraction
                          yFractionInPage:(CGFloat)yFraction;
- (void)minimapViewDidReceiveScrollWheel:(NSEvent*)event;
- (void)minimapViewDidReceiveZoomScrollWheel:(NSEvent*)event documentPoint:(NSPoint)documentPoint;
- (void)minimapViewDidReceiveMagnify:(NSEvent*)event documentPoint:(NSPoint)documentPoint;
- (void)minimapViewDidReceiveMagnifyDelta:(CGFloat)delta documentPoint:(NSPoint)documentPoint;
- (BOOL)openFilesFromPasteboard:(NSPasteboard*)pasteboard;
- (void)showContextMenuForDocumentView:(NSView*)view event:(NSEvent*)event;
- (void)setCommentAuthor:(id)sender;
- (void)editComment:(id)sender;
- (void)deleteComment:(id)sender;
- (NSNumber*)commentIndexForSidebarRow:(NSInteger)row;
- (BOOL)documentArrowKeyDown:(NSEvent*)event;
- (void)goToAdjacentPagePreservingRelativePosition:(NSInteger)delta;
- (void)installPresentationEventMonitor;
- (void)removePresentationEventMonitor;
- (void)writeSessionStateForCurrentWindow;
- (void)removeSessionStateForCurrentWindow;
- (void)savePersistentState;
- (void)performStartupDocumentWork;
- (void)performWithBatchedPersistentStateSaves:(void (^)(void))block;
- (void)resumePersistentStateSavesAfterLaunch;
- (void)dismissTabHoverPanel;
- (CGFloat)renderDisplayScaleForPageWidth:(CGFloat)pageWidth
                               pageHeight:(CGFloat)pageHeight
                                     zoom:(CGFloat)zoom
                             displayScale:(CGFloat)displayScale;
- (BOOL)fullPageRenderAllowedForPage:(SPDFRenderedPage*)page zoom:(CGFloat)zoom displayScale:(CGFloat)displayScale;
- (NSRect)visiblePageCropRectForPageIndex:(NSInteger)pageIndex extraViewMargin:(CGFloat)extraViewMargin;
- (void)renderVisiblePageCropsForCurrentViewportWithDisplayScale:(CGFloat)displayScale
                                 allowFullPageRenderAllowedPages:(BOOL)allowFullPageRenderAllowedPages;
- (void)renderVisiblePageCropsForCurrentViewportAfterLiveZoom;
- (void)schedulePostLiveZoomViewportRenderForSequence:(NSUInteger)sequence
                                                 path:(NSString*)path
                                     renderGeneration:(NSUInteger)renderGeneration;
- (void)renderVisiblePageCropsForCurrentViewportIfNeeded;
- (void)cancelCacheRenderOperations;
- (void)scheduleDocumentPanMaintenance;
- (void)renderLiveDocumentPanViewportCropIfDue;
- (NSUInteger)estimatedRenderedImageByteCostForPage:(SPDFRenderedPage*)page
                                               zoom:(CGFloat)zoom
                                       displayScale:(CGFloat)displayScale;
- (NSUInteger)renderedBaseImageByteCost:(SPDFRenderedPage*)page;
- (NSUInteger)renderedHighQualityImageByteCost:(SPDFRenderedPage*)page;
- (BOOL)shouldKeepFullRenderedDocumentAtCurrentZoom;
- (NSInteger)backgroundRenderBatchSizeForCurrentZoom;
- (BOOL)canOpenDocumentAtPath:(NSString*)path showError:(BOOL)showError;
- (NSArray<NSString*>*)openableDocumentPathsFromPaths:(NSArray<NSString*>*)paths showErrors:(BOOL)showErrors;
- (BOOL)hasOtherShenzhenWindows;
- (void)activateWindowForExternalOpen;
- (void)spawnPendingRestoredWindowsIfNeeded;
- (NSArray<NSDictionary*>*)commentAnnotationsForPage:(NSInteger)pageIndex;
- (void)documentViewHoverComment:(NSDictionary*)comment atWindowPoint:(NSPoint)windowPoint;
- (void)documentViewEndHoverComment;
- (void)setMinimapActuallyVisible:(BOOL)visible;
- (void)sidebarDividerDraggedByDeltaX:(CGFloat)deltaX;
- (void)sidebarDividerDidFinishDragging;
- (void)minimapDividerDraggedByDeltaX:(CGFloat)deltaX;
- (void)minimapDividerDidFinishDragging;
- (void)clearFindFieldFocus;

- (void)clearPageFieldFocus;
- (void)clearToolbarFieldFocusForTabSwitch;
- (void)restoreSidebarWidth;
- (BOOL)hasSearchSidebar;
- (NSString*)chapterTitleForPage:(NSInteger)pageIndex;
- (void)rebuildSearchSidebarItems;
- (void)showSearchSidebarForFind;
- (NSArray<NSValue*>*)rangesOfPaletteQuery:(NSString*)query inString:(NSString*)text limit:(NSUInteger)limit;
- (NSRange)paletteSnippetRangeInLine:(NSString*)line matchRange:(NSRange)matchRange;
- (void)leavePresentationModeAndExitFullScreen:(BOOL)exitFullScreen sender:(id)sender;
- (void)activateSidebarRow:(id)sender;
- (void)scrollToPageRect:(NSRect)targetRect pageIndex:(NSInteger)pageIndex;
- (void)flashPageRect:(NSRect)targetRect pageIndex:(NSInteger)pageIndex;
- (CGFloat)paletteHeightForRow:(NSInteger)row;
- (void)updatePalettePanelFramePreservingTop:(BOOL)preserveTop;
- (void)scrollPaletteRowToVisibleWithHeader:(NSInteger)row;
- (void)restorePaletteSelectionAfterReloadFromRow:(NSInteger)previousRow;
- (void)rememberActiveTabFindState;
- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)resetSavedIndex revealMatch:(BOOL)revealMatch;
- (NSInteger)nearestFindMatchIndexToCurrentViewport;
- (void)invalidateFindMarkers;
- (NSArray<NSDictionary*>*)findScrollbarMarkers;
- (BOOL)isAutoFitMode:(SPDFFitMode)fitMode;
- (void)relayoutDocumentForViewportChange;
- (NSString*)currentCommentAuthor;
- (void)normalizeSidebarModeControlWidths;
- (void)enqueueNearbyPageRendersForGeneration:(NSUInteger)generation preferredPage:(NSInteger)preferredPage;
- (void)enqueueFocusedDocumentBaseCacheForGeneration:(NSUInteger)generation preferredPage:(NSInteger)preferredPage;
- (void)enqueueZoomSeedCachesForGeneration:(NSUInteger)generation
                             preferredPage:(NSInteger)preferredPage
                          includeWholeBase:(BOOL)includeWholeBase;
- (void)enqueueHighQualityZoomCacheForPageIndexes:(NSArray<NSNumber*>*)pageIndexes
                                 renderGeneration:(NSUInteger)generation
                                 liveZoomSequence:(NSUInteger)liveZoomSequence
                                    preferredPage:(NSInteger)preferredPage;
- (void)evictDistantRenderedPageImages;
- (void)scheduleNearbyPageRendersAfterFirstPaintForGeneration:(NSUInteger)generation
                                                preferredPage:(NSInteger)preferredPage;
- (void)schedulePostFirstPaintWorkForGeneration:(NSUInteger)generation
                                           path:(NSString*)path
                            savedFindMatchIndex:(NSInteger)savedFindMatchIndex
                                  restoreSearch:(BOOL)restoreSearch
                            preferredRenderPage:(NSInteger)preferredRenderPage;
@end

@interface ShenzhenMacDelegate (SPDFMacUIReaderConformance) <SPDFMacDocumentViewReader>
@end

// Implemented in SPDFMacLinkNavigation.mm: instant, reversible in-document link
// following and the top-aligned arrival it scrolls to.
@interface ShenzhenMacDelegate (SPDFMacLinkNavigation)
- (BOOL)documentViewFollowInDocumentLinkAtPageIndex:(NSInteger)pageIndex
                                          pagePoint:(NSPoint)pagePoint
                                      restoreOrigin:(NSPoint*)restoreOrigin
                                   restorePageIndex:(NSInteger*)restorePageIndex;
- (void)documentViewRestoreDocumentPosition:(NSPoint)origin pageIndex:(NSInteger)pageIndex;
// Puts a link destination at the TOP of the viewport. `pageY` is the
// destination's offset from the target page's top edge in page points; 0 means
// the link named only a page, and the page's own start is the destination.
- (void)scrollToLinkDestinationOnPage:(NSInteger)pageIndex pageY:(CGFloat)pageY;
@end

@interface ShenzhenMacDelegate (ShortcutHelp)
- (NSArray<NSDictionary*>*)shortcutHelpCatalog;
- (void)refreshShortcutHelpRows;
- (NSView*)shortcutKeycapsViewForKeys:(NSArray<NSString*>*)keys;
- (void)showShortcutHelp:(id)sender;
- (void)closeShortcutHelp:(id)sender;
- (void)disableLaunchShortcutHelp:(id)sender;
@end
