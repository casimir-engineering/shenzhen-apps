#import "SPDFMacFindNearest.h"

#include <math.h>

NSInteger spdf_nearest_find_match_index(const NSInteger* matchPageIndexes,
                                        const CGFloat* matchDocumentCenterYs,
                                        NSInteger matchCount,
                                        NSInteger firstVisiblePageIndex,
                                        NSInteger lastVisiblePageIndex,
                                        CGFloat viewportCenterY) {
    if (matchCount <= 0 || !matchPageIndexes || !matchDocumentCenterYs) return -1;
    if (lastVisiblePageIndex < firstVisiblePageIndex) {
        NSInteger swap = firstVisiblePageIndex;
        firstVisiblePageIndex = lastVisiblePageIndex;
        lastVisiblePageIndex = swap;
    }

    NSInteger bestIndex = 0;
    NSInteger bestPageDistance = NSIntegerMax;
    CGFloat bestVerticalDistance = CGFLOAT_MAX;
    for (NSInteger i = 0; i < matchCount; ++i) {
        NSInteger page = matchPageIndexes[i];
        NSInteger pageDistance = 0;
        if (page < firstVisiblePageIndex) pageDistance = firstVisiblePageIndex - page;
        else if (page > lastVisiblePageIndex) pageDistance = page - lastVisiblePageIndex;
        CGFloat verticalDistance = fabs(matchDocumentCenterYs[i] - viewportCenterY);
        // Strict comparisons keep the earliest (document-order) match on ties.
        if (pageDistance < bestPageDistance ||
            (pageDistance == bestPageDistance && verticalDistance < bestVerticalDistance)) {
            bestPageDistance = pageDistance;
            bestVerticalDistance = verticalDistance;
            bestIndex = i;
        }
    }
    return bestIndex;
}
