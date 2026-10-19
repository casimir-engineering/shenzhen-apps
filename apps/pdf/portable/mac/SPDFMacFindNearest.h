#import <Foundation/Foundation.h>

// Picks the search match closest to the current viewport so a new search can
// select "5 / 10" instead of always jumping back to match #1.
//
// Pure function over parallel arrays describing the matches in document order:
// - matchPageIndexes[i]: the page a match sits on.
// - matchDocumentCenterYs[i]: the match's vertical center in document-view
//   coordinates (flipped, y grows downward), i.e. pageRect.minY + midY * zoom.
// - firstVisiblePageIndex / lastVisiblePageIndex: the inclusive range of pages
//   intersecting the viewport.
// - viewportCenterY: the viewport's vertical center in the same document-view
//   coordinates as matchDocumentCenterYs.
//
// Selection order: smallest page distance from the visible range first (0 for
// matches on a visible page), then smallest vertical distance from the
// viewport center, then document order (lowest index). Returns the winning
// match index, or -1 when matchCount <= 0 or an array is missing.
NSInteger spdf_nearest_find_match_index(const NSInteger* matchPageIndexes,
                                        const CGFloat* matchDocumentCenterYs,
                                        NSInteger matchCount,
                                        NSInteger firstVisiblePageIndex,
                                        NSInteger lastVisiblePageIndex,
                                        CGFloat viewportCenterY);
