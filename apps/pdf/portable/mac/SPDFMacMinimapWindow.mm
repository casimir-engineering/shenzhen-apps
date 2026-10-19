#import "SPDFMacMinimapWindow.h"

#include <math.h>

const NSInteger kSPDFMinimapWindowExtraPages = 30;
const NSInteger kSPDFMinimapWindowRecenterMarginPages = 15;
const NSInteger kSPDFMinimapWindowEvictSlackPages = 30;

SPDFMinimapThumbnailWindow spdf_minimap_window_empty(void) {
    SPDFMinimapThumbnailWindow window;
    window.start = 0;
    window.end = -1;
    return window;
}

BOOL spdf_minimap_window_is_valid(SPDFMinimapThumbnailWindow window) {
    return window.start >= 0 && window.end >= window.start;
}

BOOL spdf_minimap_window_contains(SPDFMinimapThumbnailWindow window, NSInteger pageIndex) {
    return spdf_minimap_window_is_valid(window) && pageIndex >= window.start && pageIndex <= window.end;
}

static NSInteger spdf_minimap_clamp_page(NSInteger pageIndex, NSInteger pageCount) {
    return MAX((NSInteger)0, MIN(pageIndex, pageCount - 1));
}

SPDFMinimapThumbnailWindow spdf_minimap_window_for_visible_range(NSInteger pageCount,
                                                                 NSInteger visibleFirst,
                                                                 NSInteger visibleLast,
                                                                 SPDFMinimapThumbnailWindow previous) {
    if (pageCount <= 0) return spdf_minimap_window_empty();
    if (visibleLast < visibleFirst) {
        NSInteger swap = visibleFirst;
        visibleFirst = visibleLast;
        visibleLast = swap;
    }
    visibleFirst = spdf_minimap_clamp_page(visibleFirst, pageCount);
    visibleLast = spdf_minimap_clamp_page(visibleLast, pageCount);

    // Hysteresis: keep the previous window while the visible range stays at
    // least the recenter margin inside both edges. The margin band is clamped
    // to the document, so sitting at the first/last page never forces a
    // recenter. A previous window from another (shorter) document fails the
    // bounds check and is recomputed.
    if (spdf_minimap_window_is_valid(previous) && previous.end < pageCount) {
        NSInteger marginFirst = MAX((NSInteger)0, visibleFirst - kSPDFMinimapWindowRecenterMarginPages);
        NSInteger marginLast = MIN(pageCount - 1, visibleLast + kSPDFMinimapWindowRecenterMarginPages);
        if (marginFirst >= previous.start && marginLast <= previous.end) return previous;
    }

    SPDFMinimapThumbnailWindow window;
    window.start = MAX((NSInteger)0, visibleFirst - kSPDFMinimapWindowExtraPages);
    window.end = MIN(pageCount - 1, visibleLast + kSPDFMinimapWindowExtraPages);
    return window;
}

BOOL spdf_minimap_window_should_evict(SPDFMinimapThumbnailWindow window, NSInteger pageIndex) {
    if (!spdf_minimap_window_is_valid(window)) return NO;
    return pageIndex < window.start - kSPDFMinimapWindowEvictSlackPages ||
           pageIndex > window.end + kSPDFMinimapWindowEvictSlackPages;
}

NSArray<NSNumber*>* spdf_minimap_window_render_order(SPDFMinimapThumbnailWindow window,
                                                     NSInteger visibleFirst,
                                                     NSInteger visibleLast) {
    if (!spdf_minimap_window_is_valid(window)) return @[];
    if (visibleLast < visibleFirst) {
        NSInteger swap = visibleFirst;
        visibleFirst = visibleLast;
        visibleLast = swap;
    }
    NSMutableArray<NSNumber*>* order = [NSMutableArray arrayWithCapacity:(NSUInteger)(window.end - window.start + 1)];
    for (NSInteger i = window.start; i <= window.end; ++i) [order addObject:@(i)];
    NSInteger first = visibleFirst;
    NSInteger last = visibleLast;
    [order sortUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
      NSInteger ia = a.integerValue;
      NSInteger ib = b.integerValue;
      NSInteger da = ia < first ? first - ia : (ia > last ? ia - last : 0);
      NSInteger db = ib < first ? first - ib : (ib > last ? ib - last : 0);
      if (da != db) return da < db ? NSOrderedAscending : NSOrderedDescending;
      return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
    }];
    return order;
}

CGFloat spdf_minimap_document_delta_for_strip_scroll(CGFloat stripDeltaY,
                                                     CGFloat stripContentHeight,
                                                     CGFloat stripAvailableHeight,
                                                     CGFloat documentHeight,
                                                     CGFloat documentVisibleHeight) {
    CGFloat maxDocumentScroll = documentHeight - documentVisibleHeight;
    if (maxDocumentScroll <= 0.0 || stripContentHeight <= 0.0) return 0.0;
    CGFloat maxStripScroll = stripContentHeight - stripAvailableHeight;
    CGFloat documentPerStripPixel =
        maxStripScroll > 0.0 ? maxDocumentScroll / maxStripScroll : documentHeight / stripContentHeight;
    return stripDeltaY * documentPerStripPixel;
}

CGFloat spdf_minimap_document_top_for_strip_scroll(CGFloat currentDocumentTop,
                                                   CGFloat stripDeltaY,
                                                   CGFloat stripContentHeight,
                                                   CGFloat stripAvailableHeight,
                                                   CGFloat documentHeight,
                                                   CGFloat documentVisibleHeight) {
    CGFloat delta = spdf_minimap_document_delta_for_strip_scroll(stripDeltaY, stripContentHeight,
                                                                 stripAvailableHeight, documentHeight,
                                                                 documentVisibleHeight);
    CGFloat maxDocumentScroll = MAX(0.0, documentHeight - documentVisibleHeight);
    return MAX(0.0, MIN(currentDocumentTop + delta, maxDocumentScroll));
}

CGFloat spdf_minimap_directional_page_stride(NSInteger currentPageIndex, CGFloat proposedDocumentDelta,
                                             NSArray<NSValue*>* documentPageRects) {
    NSInteger count = (NSInteger)documentPageRects.count;
    if (count <= 0 || fabs(proposedDocumentDelta) <= 0.0001) return 0.0;

    NSInteger pageIndex = MAX((NSInteger)0, MIN(currentPageIndex, count - 1));
    NSRect currentRect = documentPageRects[(NSUInteger)pageIndex].rectValue;
    NSInteger adjacentIndex = proposedDocumentDelta > 0.0 ? pageIndex + 1 : pageIndex - 1;
    CGFloat stride = 0.0;
    if (adjacentIndex >= 0 && adjacentIndex < count) {
        NSRect adjacentRect = documentPageRects[(NSUInteger)adjacentIndex].rectValue;
        stride = proposedDocumentDelta > 0.0 ? NSMinY(adjacentRect) - NSMinY(currentRect)
                                             : NSMinY(currentRect) - NSMinY(adjacentRect);
    }
    if (!isfinite(stride) || stride <= 0.0) stride = NSHeight(currentRect);
    return isfinite(stride) ? MAX(0.0, stride) : 0.0;
}

CGFloat spdf_minimap_document_top_capped_for_discrete_wheel(CGFloat currentDocumentTop, CGFloat proposedDocumentTop,
                                                            NSInteger currentPageIndex,
                                                            NSArray<NSValue*>* documentPageRects,
                                                            CGFloat documentHeight, CGFloat documentVisibleHeight) {
    CGFloat delta = proposedDocumentTop - currentDocumentTop;
    CGFloat stride = spdf_minimap_directional_page_stride(currentPageIndex, delta, documentPageRects);
    if (stride > 0.0 && fabs(delta) > stride) proposedDocumentTop = currentDocumentTop + copysign(stride, delta);
    CGFloat maxDocumentScroll = MAX(0.0, documentHeight - documentVisibleHeight);
    return MAX(0.0, MIN(proposedDocumentTop, maxDocumentScroll));
}
