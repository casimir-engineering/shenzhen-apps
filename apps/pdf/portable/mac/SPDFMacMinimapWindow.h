#import <Foundation/Foundation.h>

// Windowed lazy loading for minimap thumbnails.
//
// Thumbnails are only rendered/kept for a window of pages around the visible
// strip range, so the minimap works at constant memory for any document size
// (the old design capped thumbnail drawing at 400 pages and never evicted).
// Pages outside the window draw the cheap placeholder; their strip slots keep
// exact geometry, so drag/click/zoom hit-testing is unaffected.
//
// The window has hysteresis: it recenters only once the visible range moves
// within kSPDFMinimapWindowRecenterMarginPages of a window edge, so scrolling
// one page at a time does not recompute (and re-evict) per step.

// Pages rendered beyond the visible strip range on each side.
extern const NSInteger kSPDFMinimapWindowExtraPages;
// Recenter once the visible range is within this many pages of a window edge.
extern const NSInteger kSPDFMinimapWindowRecenterMarginPages;
// Extra pages kept beyond the window before a thumbnail is evicted, so a
// recenter doesn't immediately drop pages the user may scroll straight back to.
extern const NSInteger kSPDFMinimapWindowEvictSlackPages;

typedef struct SPDFMinimapThumbnailWindow {
    NSInteger start;  // first page index in the window, inclusive
    NSInteger end;    // last page index in the window, inclusive; start > end means "no window yet"
} SPDFMinimapThumbnailWindow;

SPDFMinimapThumbnailWindow spdf_minimap_window_empty(void);
BOOL spdf_minimap_window_is_valid(SPDFMinimapThumbnailWindow window);
BOOL spdf_minimap_window_contains(SPDFMinimapThumbnailWindow window, NSInteger pageIndex);

// Window for the visible strip range [visibleFirst..visibleLast] (both
// inclusive, clamped to the document). Returns `previous` unchanged while it
// still covers the visible range plus the recenter margin (clamped to the
// document edges); otherwise recenters to visible ± kSPDFMinimapWindowExtraPages.
SPDFMinimapThumbnailWindow spdf_minimap_window_for_visible_range(NSInteger pageCount,
                                                                 NSInteger visibleFirst,
                                                                 NSInteger visibleLast,
                                                                 SPDFMinimapThumbnailWindow previous);

// YES when pageIndex is further than kSPDFMinimapWindowEvictSlackPages outside
// `window` and its thumbnail should be dropped. Never YES for an invalid window.
BOOL spdf_minimap_window_should_evict(SPDFMinimapThumbnailWindow window, NSInteger pageIndex);

// All page indexes of `window` ordered by render priority: pages nearest the
// visible range first (the visible pages themselves lead), ties by lower index.
NSArray<NSNumber*>* spdf_minimap_window_render_order(SPDFMinimapThumbnailWindow window,
                                                     NSInteger visibleFirst,
                                                     NSInteger visibleLast);

// Strip scrolling: a plain scroll gesture over the minimap scrolls the STRIP by
// the gesture distance and the document follows at the strip's page-per-pixel
// scale (VS Code-style). The strip has no scroll state of its own — its offset
// is derived from the document scroll position — so these map a strip-space
// gesture delta to the equivalent document movement.

// Document-space Y movement for scrolling the strip contents by stripDeltaY
// pixels (positive = toward the document end). While the strip overflows its
// viewport the scale is the scrollbar ratio maxDocumentScroll/maxStripScroll,
// which keeps the strip glued 1:1 to the gesture; when the whole strip fits
// (no overflow, so the strip itself cannot move) it falls back to
// documentHeight/stripContentHeight so the gesture moves the viewport
// indicator by the gesture distance instead. Returns 0 when the document
// itself cannot scroll.
CGFloat spdf_minimap_document_delta_for_strip_scroll(CGFloat stripDeltaY,
                                                     CGFloat stripContentHeight,
                                                     CGFloat stripAvailableHeight,
                                                     CGFloat documentHeight,
                                                     CGFloat documentVisibleHeight);

// New document top after a strip scroll: currentDocumentTop plus the delta
// above, clamped to [0, documentHeight - documentVisibleHeight].
CGFloat spdf_minimap_document_top_for_strip_scroll(CGFloat currentDocumentTop, CGFloat stripDeltaY,
                                                   CGFloat stripContentHeight, CGFloat stripAvailableHeight,
                                                   CGFloat documentHeight, CGFloat documentVisibleHeight);

// Maximum document-space movement for one discrete wheel event. The stride is
// directional: toward the document end it is the current-to-next page-origin
// distance; toward the start it is the previous-to-current distance. At a
// document edge it falls back to the current page height.
CGFloat spdf_minimap_directional_page_stride(NSInteger currentPageIndex, CGFloat proposedDocumentDelta,
                                             NSArray<NSValue*>* documentPageRects);

// Clamp a proposed strip-scroll destination to one directional page stride.
// Precise trackpad and momentum scrolling continue to use the uncapped mapping.
CGFloat spdf_minimap_document_top_capped_for_discrete_wheel(CGFloat currentDocumentTop, CGFloat proposedDocumentTop,
                                                            NSInteger currentPageIndex,
                                                            NSArray<NSValue*>* documentPageRects,
                                                            CGFloat documentHeight, CGFloat documentVisibleHeight);
