#pragma once

#import "SPDFMacMarkdownSession.h"

#import "SPDFMacMarkdownMinimapModel.h"
#import "SPDFMacMarkdownPagedView.h"
#import "markdown/SPDFMarkdown.h"

@class SPDFMacMarkdownLanguagePickerController;
@class SPDFMacMarkdownSessionImageLoader;

NS_ASSUME_NONNULL_BEGIN

// Shared between the session lifecycle (SPDFMacMarkdownSession.mm) and its
// find/search (SPDFMacMarkdownSession+Search.mm) and interaction
// (SPDFMacMarkdownSession+Interaction.mm) halves; not part of the public
// session API. The remaining lifecycle-only ivars stay declared in
// SPDFMacMarkdownSession.mm's implementation block.
@interface SPDFMacMarkdownSession () {
  @protected
    SPDFMacMarkdownPagedView* _Nullable _pagedView;
    SPDFMarkdownPaginationPlan* _Nullable _paginationPlan;
    // Lazily built LIGHT export rendition, populated only while the session
    // renders DARK. _exportRenditionSource is the renderedDocument it was
    // derived from: a rerender installs a new object, which invalidates the
    // cache by identity with no explicit bookkeeping (see
    // SPDFMacMarkdownSession+Export.mm).
    SPDFMarkdownPaginationPlan* _Nullable _exportPlan;
    NSAttributedString* _Nullable _exportAttributedString;
    SPDFMarkdownRenderedDocument* _Nullable _exportRenditionSource;
    SPDFMacMarkdownMinimapModel* _Nullable _minimapModel;
    // Backing ivars for the reader preferences. Declared here rather than
    // auto-synthesized so the appearance half can reach them; the property
    // declarations in SPDFMacMarkdownSession.h adopt these by name.
    CGFloat _fontScale;
    SPDFMarkdownThemeVariant _themeVariant;
    SPDFMarkdownPageOrientation _pageOrientation;
    BOOL _preservesImageColors;
    // fontScale/themeVariant/orientation of the currently installed
    // renderedDocument and plan; when any of them trails the session
    // preference (changed while inactive or mid-load) activation schedules a
    // catch-up rerender. Shared with the appearance half
    // (SPDFMacMarkdownSession+Appearance.mm).
    // The in-flight render and the generation that supersedes it. Shared so a
    // disk reload (SPDFMacMarkdownSession+Reload.mm) can cancel and supersede a
    // render exactly the way the in-place rerender does.
    NSAttributedString* _Nullable _interactiveString;
    // Reached by the install/swap half (SPDFMacMarkdownSession+ViewSwap.mm),
    // which owns -installRenderedDocument: and the handover it performs.
    NSPoint _pendingScrollOrigin;
    NSRange _pendingSelectedRange;
    NSInteger _pendingPageIndex;
    CGFloat _pendingZoom;
    SPDFMacMarkdownPageFitMode _pendingFitMode;
    NSTextField* _placeholder;
    __weak id<SPDFMacUIReader> _reader;
    NSView* _rootView;
    SPDFMacMarkdownSidebarModel* _sidebarModel;
    SPDFMarkdownCancellationToken* _Nullable _renderToken;
    NSUInteger _renderGeneration;
    CGFloat _renderedFontScale;
    SPDFMarkdownThemeVariant _renderedThemeVariant;
    SPDFMarkdownPageOrientation _renderedOrientation;
    // Set by an orientation switch: the attributed location that was at the
    // top of the viewport, so the next install can land on whichever page now
    // holds it. NSNotFound means "no re-anchor pending" — an absolute scroll
    // origin is meaningless once the document re-flows onto different paper.
    NSUInteger _pendingReanchorLocation;
    SPDFMarkdownDiagramCache* _Nullable _diagramCache;  // shared by every rerender
    NSString* _Nullable _pendingAnchor;
    NSMutableDictionary<NSNumber*, NSString*>* _languageOverrides;
    SPDFMacMarkdownLanguagePickerController* _Nullable _languagePicker;
    NSArray<SPDFMarkdownSearchMatch*>* _searchMatches;
    NSInteger _currentMatchIndex;
    // The live query/regex flag, kept so a font-scale or language re-render can
    // re-run the search against the freshly rendered attributed string instead
    // of reapplying stale ranges.
    NSString* _Nullable _activeSearchQuery;
    BOOL _activeSearchRegex;
    NSString* _Nullable _searchErrorDescription;
    // PDF-parity current-match flash (stepFindFlash:'s envelope) driving the
    // paged view's activeSearchRange/activeSearchAlpha overlay.
    NSTimer* _Nullable _matchFlashTimer;
    NSTimeInterval _matchFlashStartTime;
    SPDFMarkdownCancellationToken* _Nullable _searchToken;
    NSUInteger _searchGeneration;
    dispatch_queue_t _Nullable _workQueue;
    BOOL _active;
    BOOL _reloadInFlight; // A source reload also delays external navigation.
    // Lazily created by the RemoteImages half; nil until the document's first
    // active render encounters a remote image target.
    SPDFMacMarkdownSessionImageLoader* _Nullable _imageLoader;
}
@property(nonatomic) SPDFMacMarkdownSessionState state;
@property(nonatomic, strong, nullable) SPDFMarkdownDocument* document;
@property(nonatomic, strong, nullable) SPDFMarkdownRenderedDocument* renderedDocument;
@end

// Search internals the lifecycle half calls across the file split; implemented
// in SPDFMacMarkdownSession+Search.mm.
@interface SPDFMacMarkdownSession (SearchInternal)
- (void)applySearchHighlights;
- (void)removeSearchHighlights;
- (void)clearMatchFlash;
@end

// Lifecycle internals the interaction half calls across the file split;
// implemented in SPDFMacMarkdownSession.mm.
// The export rendition, implemented in SPDFMacMarkdownSession+Export.mm.
@interface SPDFMacMarkdownSession (Export)
@end

// Paginates a rendition exactly the way the live screen pass does, so an export
// plan and the on-screen plan differ in palette and nothing else. The single
// seam every plan goes through (screen, print, export, copy-page), which is why
// the paper orientation is a parameter here beside the theme. Shared by the
// lifecycle passes and the export rendition; implemented alongside the latter.
FOUNDATION_EXPORT SPDFMarkdownPaginationPlan* SPDFMacMarkdownPlanForRendition(
    SPDFMarkdownRenderedDocument* rendered, SPDFMarkdownThemeVariant variant, BOOL preservesImageColors,
    SPDFMarkdownPageOrientation orientation);

// The printable box the plan above will paginate into, for the RENDER half of
// the same pass (SPDFMarkdownRenderOptions.pageContentSize). Both read the one
// SPDFMarkdownPageConfiguration factory, so a figure can never be fitted to a
// different page than the one it lands on.
FOUNDATION_EXPORT NSSize SPDFMacMarkdownPageContentSize(SPDFMarkdownPageOrientation orientation);

FOUNDATION_EXPORT SPDFMarkdownPaginationPlan* SPDFMacMarkdownPlanForConfiguration(
    SPDFMarkdownRenderedDocument* rendered, SPDFMarkdownThemeVariant variant, BOOL preservesImageColors,
    SPDFMarkdownPageConfiguration* configuration);
// Parse once, resolve author paper before fitting figures, then render once.
FOUNDATION_EXPORT SPDFMarkdownDocument* _Nullable SPDFMacMarkdownLoadDocument(
    NSURL* URL, SPDFMarkdownRenderOptions* options, SPDFMarkdownPageOrientation orientation,
    NSDictionary* _Nullable previousFrontMatter, SPDFMarkdownPageConfiguration* _Nullable* _Nullable configuration,
    NSError* _Nullable* _Nullable error);
@interface SPDFMacMarkdownSession (PaperConfiguration)
- (SPDFMarkdownPageConfiguration*)currentPageConfiguration;
@end

// Clamps a reader font scale into the supported range.
FOUNDATION_EXPORT CGFloat SPDFMacMarkdownClampFontScale(CGFloat scale);

@interface SPDFMacMarkdownSession (Appearance)
- (SPDFMarkdownRenderOptions*)renderOptionsForThemeVariant:(SPDFMarkdownThemeVariant)variant;
- (SPDFMarkdownRenderOptions*)renderOptionsForCurrentScale;
- (BOOL)renderTrailsPreferences;
@end

@interface SPDFMacMarkdownSession (LifecycleInternal)
// Shared rerender flow for language overrides and font-scale changes. A
// nil/empty status skips the status callback.
- (void)rerenderDocumentWithStatus:(NSString* _Nullable)status;
// Swap a freshly rendered document under the live view. preserveCurrentState
// keeps the reader's viewport, selection and zoom across the swap.
// Reveal a configured paged view and drop the one it replaces, in one pass.
// Implemented in SPDFMacMarkdownSession+ViewSwap.mm.
- (void)revealPagedView:(NSView*)incoming replacing:(NSView* _Nullable)outgoing;
- (void)installRenderedDocument:(SPDFMarkdownRenderedDocument*)rendered
                 paginationPlan:(SPDFMarkdownPaginationPlan*)plan
              interactiveString:(NSAttributedString*)interactive
           preserveCurrentState:(BOOL)preserve;
// The session's current render options with an EXPLICIT theme variant, so the
// export half can ask for a light rendition of a dark session.
- (SPDFMarkdownRenderOptions*)renderOptionsForThemeVariant:(SPDFMarkdownThemeVariant)variant;
@end

// Interaction internals the lifecycle half calls across the file split;
// implemented in SPDFMacMarkdownSession+Interaction.mm.
@interface SPDFMacMarkdownSession (InteractionInternal)
- (void)activateDestination:(NSString*)destination wikiLink:(BOOL)wikiLink;
- (void)applyLanguageIdentifier:(NSString*)identifier toCodeBlock:(NSUInteger)blockIndex;
@end

// Remote-image lazy loading, implemented in
// SPDFMacMarkdownSession+RemoteImages.mm. Downloads start only once an ACTIVE
// session installs a render containing https image targets; arrivals feed
// SPDFMarkdownRenderOptions.remoteImageData and trigger one coalesced
// viewport-preserving rerender per batch.
@interface SPDFMacMarkdownSession (RemoteImages)
// The session's lazily created loader; tests inject their fetcher seam here
// before activating.
- (SPDFMacMarkdownSessionImageLoader*)remoteImageLoader;
// Replaces the loader (tests supply one with a private cache directory) and
// rebinds its update handler to this session's coalesced rerender.
- (void)installRemoteImageLoader:(SPDFMacMarkdownSessionImageLoader*)loader;
- (void)applyRemoteImageState:(SPDFMarkdownRenderOptions*)options;
- (void)startRemoteImageFetchesIfNeeded;
- (void)cancelQueuedRemoteImageFetches;
@end

NS_ASSUME_NONNULL_END
