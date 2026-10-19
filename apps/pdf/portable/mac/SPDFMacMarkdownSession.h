#pragma once

#import <AppKit/AppKit.h>
#import "SPDFMacMarkdownPagedView.h"
#import "markdown/SPDFMarkdownDecorations.h"

@class SPDFMarkdownDocument;
@class SPDFMarkdownDocumentModel;
@class SPDFMarkdownPaginationPlan;
@class SPDFMarkdownRenderedDocument;
@class SPDFMarkdownSearchMatch;
@class SPDFMacMarkdownMinimapModel;
@class SPDFMacMarkdownSidebarModel;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacMarkdownSessionState) {
    SPDFMacMarkdownSessionIdle,
    SPDFMacMarkdownSessionLoading,
    SPDFMacMarkdownSessionReady,
    SPDFMacMarkdownSessionFailed,
};

@interface SPDFMacMarkdownSession : NSObject
@property(nonatomic, readonly, copy) NSURL* documentURL;
// Same-directory file rename; retain the current rendered pages and reading position.
- (void)relocateDocumentToURL:(NSURL*)URL;
@property(nonatomic, readonly) NSView* rootView;
@property(nonatomic, weak, nullable) id<SPDFMacUIReader> reader;
@property(nonatomic, readonly, nullable) NSTextView* textView;
@property(nonatomic, readonly, nullable) SPDFMarkdownDocument* document;
@property(nonatomic, readonly, nullable) SPDFMarkdownRenderedDocument* renderedDocument;
// Exact source identity captured around parsing; never refreshed from an old live render.
@property(nonatomic, readonly, nullable) NSString* loadedSourceRevision;
// The live on-screen pagination plan (current font scale, language overrides,
// reserved language-control band). Print and Save-as-PDF consume this plan
// with renderedDocument so exports match the reader page for page.
@property(nonatomic, readonly, nullable) SPDFMarkdownPaginationPlan* paginationPlan;
// The reader's "Keep Image Colors in Dark Theme" answer. Since 26.9.1-1 the
// setting defaults to YES (keep the image's own colors); the delegate seeds it
// from settings.yaml "darkThemePreservesImages" and hands it here, so this
// property is never the place the default lives. Only affects drawing, so
// setting it retargets the live plan in place rather than re-rendering; the
// caller redraws.
@property(nonatomic) BOOL preservesImageColors;
// The EXPORT rendition: Save as PDF, Print, Copy Page and Copy Page Image
// always produce the LIGHT reading theme, matching the PDF side (where an
// export always carries the document's own colors — dark paper baked into a
// file would be wrong everywhere else it is opened).
//
// While the session is light these are the live plan and string themselves —
// the identical objects, no render, no pagination, not one extra allocation on
// the common path. Only while DARK is on do they build a light rendition, once,
// lazily, on the first export, cached until the next rerender replaces the
// installed renderedDocument (font scale, theme, language override, remote
// image). Everything else about the export is unchanged: same font scale, same
// margins, same reserved language-control band, same page breaks.
@property(nonatomic, readonly, nullable) SPDFMarkdownPaginationPlan* exportPaginationPlan;
@property(nonatomic, readonly, nullable) NSAttributedString* exportAttributedString;
@property(nonatomic, readonly) SPDFMacMarkdownSessionState state;
// Main-thread, side-effect-free readiness for external navigation. Ready state
// alone precedes deferred viewport restoration and may cover a cached rerender.
@property(nonatomic, readonly, getter=isNavigationReady) BOOL navigationReady;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownSearchMatch*>* searchMatches;
@property(nonatomic, readonly) NSInteger currentMatchIndex;
@property(nonatomic, readonly) NSPoint scrollOrigin;
@property(nonatomic, readonly) NSRange selectedRange;
@property(nonatomic, readonly, copy) NSString* selectedText;
@property(nonatomic, readonly) NSUInteger pageCount;
@property(nonatomic, readonly) NSInteger currentPageIndex;
@property(nonatomic, readonly) NSUInteger visibleAttributedLocation;
@property(nonatomic, readonly) CGFloat zoom;
@property(nonatomic, readonly) SPDFMacMarkdownPageFitMode fitMode;
// Uniform typography multiplier applied to every render, clamped to
// [0.5, 3.0]. Set at creation for the first render; applyFontScale: rerenders
// the active session while preserving its viewport state.
@property(nonatomic, readonly) CGFloat fontScale;
// The reading theme applied to every render (default Light). Set at creation
// for the first render; applyThemeVariant: rerenders the active session while
// preserving its viewport state, exactly like applyFontScale:.
@property(nonatomic, readonly) SPDFMarkdownThemeVariant themeVariant;
// The PAPER every render is paginated onto (default Portrait). This is what a
// rotate command changes on a Markdown document: the pages become A4 landscape
// and the text RE-FLOWS onto them upright — nothing is ever turned on its
// side. Set before activation for the first render; applyPageOrientation:
// re-paginates the active session in place, exactly like applyThemeVariant:.
// Print, Save as PDF, Copy Page and Copy Page Image all follow it, because it
// travels on the pagination plan they consume rather than on the reader.
@property(nonatomic, readonly) SPDFMarkdownPageOrientation pageOrientation;
@property(nonatomic, readonly, copy) NSArray<NSValue*>* documentPageRects;
@property(nonatomic, readonly) NSRect documentVisibleRect;
@property(nonatomic, readonly) NSSize documentCanvasSize;
@property(nonatomic, readonly, nullable) SPDFMacMarkdownMinimapModel* minimapModel;
@property(nonatomic, readonly, nullable) SPDFMacMarkdownSidebarModel* sidebarModel;
@property(nonatomic, copy, nullable) void (^openDocumentHandler)(NSURL* URL, NSString* _Nullable anchor);
@property(nonatomic, copy, nullable) void (^openExternalURLHandler)(NSURL* URL);
@property(nonatomic, copy, nullable) void (^statusHandler)(NSString* status);
// Optional consumer notified only after a completed rerender has installed its live layout.
@property(nonatomic, copy, nullable) void (^renderInstalledHandler)(void);
@property(nonatomic, copy, nullable) void (^searchUpdateHandler)
    (NSUInteger count, NSInteger currentIndex, BOOL searching);
// Fired by next/previous/explicit match jumps (never by searchUpdateHandler's
// search lifecycle), so index-only changes can refresh controls without
// rebuilding the sidebar — the PDF jump path's split.
@property(nonatomic, copy, nullable) void (^matchIndexChangedHandler)(NSInteger currentIndex, NSUInteger count);
// Human-readable engine failure from the last completed search (an invalid
// regex pattern); nil after a successful search or clear.
@property(nonatomic, readonly, copy, nullable) NSString* searchErrorDescription;
@property(nonatomic, copy, nullable) void (^viewportUpdateHandler)
    (NSInteger pageIndex, CGFloat zoom, SPDFMacMarkdownPageFitMode fitMode);

// Image-aware selection copy, forwarded to the paged view (see
// SPDFMacMarkdownPagedView's writeSelectionToPasteboard:plainTextTransform:).
// Both answer NO/false while the session has no live paged view.
- (BOOL)selectionContainsImage;
- (BOOL)copySelectionToPasteboard:(NSPasteboard*)pasteboard
               plainTextTransform:(NSString* (^_Nullable)(NSString* text))transform;

- (instancetype)initWithDocumentURL:(NSURL*)URL;
- (instancetype)initWithDocumentURL:(NSURL*)URL fontScale:(CGFloat)fontScale;
- (instancetype)initWithDocumentURL:(NSURL*)URL
                          fontScale:(CGFloat)fontScale
                       themeVariant:(SPDFMarkdownThemeVariant)themeVariant NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)applyFontScale:(CGFloat)scale;
- (void)applyThemeVariant:(SPDFMarkdownThemeVariant)themeVariant;
- (void)activateInHostView:(NSView*)hostView
                 workQueue:(dispatch_queue_t)workQueue
              scrollOrigin:(NSPoint)scrollOrigin
             selectedRange:(NSRange)selectedRange
                 pageIndex:(NSInteger)pageIndex
                      zoom:(CGFloat)zoom
                   fitMode:(SPDFMacMarkdownPageFitMode)fitMode
                    anchor:(nullable NSString*)anchor
                completion:(void (^)(BOOL success, NSError* _Nullable error))completion;
- (void)deactivate;
- (void)cancelAllOperations;
// Idempotent self-heal (main thread): an ACTIVE session must either have its
// rendered document installed or work actually in flight; restarts whatever a
// cancel killed. No-ops for inactive sessions, in-flight loads, and installed
// documents — safe to call from any "is this tab actually showing something"
// checkpoint (cancelAllOperations schedules it itself for cancels that land
// while the session stays active; app-level open/select early-return paths
// call it directly so a stranded Loading tab can never lock in).
- (void)ensureActiveSessionHasContent;
@end

// The RAW source of one fenced code block, straight from the parsed model:
// exactly the characters between the fences, never the syntax-highlighted
// rendition and never the language label. nil when the block index is not a
// fenced code block. SPDFMacMarkdownCopyCodeSource writes it to `pasteboard`
// as plain text, and is what the code box's copy button ultimately runs.
FOUNDATION_EXPORT NSString* _Nullable SPDFMacMarkdownCodeSourceForBlock(SPDFMarkdownDocumentModel* model,
                                                                        NSUInteger blockIndex);
FOUNDATION_EXPORT BOOL SPDFMacMarkdownCopyCodeSource(SPDFMarkdownDocumentModel* model, NSUInteger blockIndex,
                                                     NSPasteboard* pasteboard);

// Implemented in SPDFMacMarkdownSession+Paper.mm: the sheet the document is
// laid out on, which is what a rotate command turns on a Markdown document.
@interface SPDFMacMarkdownSession (Paper)
// Switches the paper between A4 portrait and A4 landscape. An ACTIVE session
// re-paginates in place, keeping its fit mode and custom zoom and re-anchoring
// to whatever was at the top of the viewport (an absolute scroll offset means
// nothing across a re-flow). An INACTIVE one adopts it silently and catches up
// on activation — the applyFontScale:/applyThemeVariant: contract exactly.
- (void)applyPageOrientation:(SPDFMarkdownPageOrientation)orientation;
@end

// Implemented in SPDFMacMarkdownSession+Reload.mm: re-reading the document
// after its file changed on disk, which is a rerender from a new source rather
// than a fresh load — see that file for why.
@interface SPDFMacMarkdownSession (Reload)
// Re-read the document from disk and swap it under the live view, keeping the
// reader's viewport, selection and zoom.
- (void)reloadFromDiskWithStatus:(NSString* _Nullable)status;
@end

// Implemented in SPDFMacMarkdownSession+Interaction.mm: heading anchors, the
// code-language picker, the code copy button, and the viewport forwarding onto
// the paged view.
@interface SPDFMacMarkdownSession (Interaction)
- (BOOL)scrollToHeadingAnchor:(NSString*)anchor;
- (void)navigateToAnchorWhenReady:(NSString*)anchor;
- (void)showLanguagePickerForCodeBlock:(NSUInteger)blockIndex parentWindow:(NSWindow*)window;
// A code box's copy button, on the session's own document: writes that block's
// RAW fence source as plain text and reports the status. NO when the index is
// not a fenced code block, its source is empty, or the write was rejected.
- (nullable NSString*)codeSourceForCodeBlock:(NSUInteger)blockIndex;
- (BOOL)copyCodeBlock:(NSUInteger)blockIndex;
- (void)goToPageAtIndex:(NSInteger)pageIndex;
- (void)zoomByFactor:(CGFloat)factor;
- (void)setZoom:(CGFloat)zoom;
- (void)applyFitMode:(SPDFMacMarkdownPageFitMode)fitMode;
- (void)setPresentationMode:(BOOL)presentationMode;
- (NSUInteger)pageIndexForRange:(NSRange)range;
- (void)revealRange:(NSRange)range;
- (void)centerAtDocumentPoint:(NSPoint)point;
- (void)centerOnPageAtIndex:(NSInteger)pageIndex xFraction:(CGFloat)xFraction yFraction:(CGFloat)yFraction;
- (void)scrollByDocumentDeltaX:(CGFloat)deltaX deltaY:(CGFloat)deltaY;
- (void)forwardScrollWheelEvent:(NSEvent*)event;
- (void)magnifyByDelta:(CGFloat)delta;
- (BOOL)zoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)magnifyByDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)magnifyByDelta:(CGFloat)delta centeredAtDocumentPoint:(NSPoint)documentPoint;
- (void)noteExternalScrollPositionChanged;
@end

// Implemented in SPDFMacMarkdownSession+Search.mm: the PDF-parity find half of
// the session (nearest-match selection, centered reveal with the animated red
// flash, regex support, and scrollbar trough markers).
@interface SPDFMacMarkdownSession (Search)
// Convenience for the full search below: plain (non-regex) query, no
// nearest-match preference, revealing the selected match.
- (void)searchForQuery:(NSString*)query preferredIndex:(NSInteger)preferredIndex;
// PDF-parity search. preferredIndex < 0 means "no explicit target": the match
// nearest the current viewport is selected when jumpToNearest is set, else the
// first match. reveal == NO keeps the viewport still (no scroll, no flash) —
// the toolbar's non-revealing restore path.
- (void)searchForQuery:(NSString*)query
                 regex:(BOOL)regex
        preferredIndex:(NSInteger)preferredIndex
         jumpToNearest:(BOOL)jumpToNearest
                reveal:(BOOL)reveal;
- (void)searchForQuery:(NSString*)query regex:(BOOL)regex preferredIndex:(NSInteger)preferredIndex
    jumpToNearest:(BOOL)jumpToNearest reveal:(BOOL)reveal
    publicationAllowed:(nullable BOOL (^)(void))publicationAllowed;
- (void)clearSearch;
- (void)moveToNextMatch:(BOOL)forward;
- (void)goToSearchMatchAtIndex:(NSInteger)matchIndex;
// PDF-parity scrollbar trough markers: one {fraction, active} entry per search
// match (fraction = match center Y / canvas height), the shape
// [reader findScrollbarMarkers] serves to SPDFFindMarkerScroller.
- (NSArray<NSDictionary*>*)searchScrollbarMarkers;
- (void)invalidateSearchScrollbarMarkers;
@end

NS_ASSUME_NONNULL_END
