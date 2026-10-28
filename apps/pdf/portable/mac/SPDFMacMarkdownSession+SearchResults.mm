#import "SPDFMacMarkdownSessionPrivate.h"

// The results half of the Markdown session's search: merging pages as the
// workers finish them (kept in text order), picking the first match while the
// search runs, finishing it, and each match's place on the canvas.

@implementation SPDFMarkdownPageSearchHits
@end

@implementation SPDFMacMarkdownSession (SearchResults)

// Lower bound of `location` in the text-ordered matches.
- (NSUInteger)searchMatchIndexForLocation:(NSUInteger)location {
    NSUInteger low = 0, high = _searchMatches.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (_searchMatches[middle].range.location < location) low = middle + 1;
        else high = middle;
    }
    return low;
}

- (void)mergeSearchPages:(NSArray<SPDFMacSearchPageResult*>*)pages {
    if (_searchReplacesPrevious) {
        [_searchPendingPages addObjectsFromArray:pages];
        return;
    }
    [self insertSearchPages:pages];
    [self publishSearchHighlights];
    [self pickFirstSearchMatchIfReady];
    if (self.searchUpdateHandler) self.searchUpdateHandler(_searchMatches.count, _currentMatchIndex, YES);
}

- (void)insertSearchPages:(NSArray<SPDFMacSearchPageResult*>*)pages {
    for (SPDFMacSearchPageResult* page in pages) {
        [_searchedPages addIndex:page.pageIndex];
        SPDFMarkdownPageSearchHits* hits = page.payload;
        if (!hits.matches.count) continue;
        NSUInteger count = hits.matches.count;
        NSUInteger insert = [self searchMatchIndexForLocation:hits.matches.firstObject.range.location];
        [_searchMatches insertObjects:hits.matches atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insert, count)]];
        [_searchMatchGeometry replaceBytesInRange:NSMakeRange(insert * sizeof(SPDFMarkdownMatchGeometry), 0)
                                        withBytes:hits.geometry.bytes
                                           length:hits.geometry.length];
        if (_currentMatchIndex >= (NSInteger)insert) _currentMatchIndex += (NSInteger)count;
        if (hits.pageIndex >= 0 && hits.pageRects.count) _searchPageRects[@(hits.pageIndex)] = hits.pageRects;
    }
}

// Walks the search order from the starting page while its pages are done; the
// first match met there is the one nearest the reader, so it is selected (and
// revealed) without waiting for the rest of the document.
- (void)pickFirstSearchMatchIfReady {
    if (!_searchPicksFirstMatch || !_search) return;
    NSUInteger sliceCount = _searchSlices.length / sizeof(NSRange);
    const NSRange* slices = (const NSRange*)_searchSlices.bytes;
    while (_searchOrderPrefix < sliceCount) {
        NSUInteger slice = (_search.firstPage + _searchOrderPrefix) % sliceCount;
        if (![_searchedPages containsIndex:slice]) return;
        NSUInteger from = slices[slice].location;
        if (_searchOrderPrefix == 0) from = MAX(from, _searchStartLocation);
        NSUInteger index = [self searchMatchIndexForLocation:from];
        ++_searchOrderPrefix;
        if (index < _searchMatches.count && _searchMatches[index].range.location < NSMaxRange(slices[slice])) {
            [self selectSearchMatchAtIndex:(NSInteger)index reveal:_searchRevealsFirstMatch];
            return;
        }
    }
}

- (void)selectSearchMatchAtIndex:(NSInteger)index reveal:(BOOL)reveal {
    _searchPicksFirstMatch = NO;
    _currentMatchIndex = index;
    if (reveal) [self revealCurrentMatch];
}

- (void)finishSearchWithPreferredIndex:(NSInteger)preferredIndex
                         jumpToNearest:(BOOL)jumpToNearest
                                reveal:(BOOL)reveal {
    _search = nil;
    _searchToken = nil;
    if (_searchReplacesPrevious) {
        NSArray<SPDFMacSearchPageResult*>* pages = _searchPendingPages ?: @[];
        _searchReplacesPrevious = NO;
        _searchPendingPages = nil;
        [self resetSearchMatches];
        [self insertSearchPages:pages];
        [self publishSearchHighlights];
    }
    NSInteger count = (NSInteger)_searchMatches.count;
    if (count && _currentMatchIndex < 0) {
        NSInteger resolved = preferredIndex;
        if (resolved < 0 && jumpToNearest) resolved = [self nearestMatchIndexToViewport];
        [self selectSearchMatchAtIndex:MAX(0, MIN(resolved, count - 1)) reveal:reveal];
    }
    _searchPicksFirstMatch = NO;
    if (!count) _currentMatchIndex = -1;
    if (self.searchUpdateHandler) self.searchUpdateHandler(_searchMatches.count, _currentMatchIndex, NO);
}

- (SPDFMarkdownMatchGeometry)geometryOfSearchMatchAtIndex:(NSUInteger)index {
    if ((index + 1) * sizeof(SPDFMarkdownMatchGeometry) > _searchMatchGeometry.length)
        return SPDFMarkdownMatchGeometry{-1, NSZeroRect};
    return ((const SPDFMarkdownMatchGeometry*)_searchMatchGeometry.bytes)[index];
}

// Canvas-space center Y of a match from the mapped rects; NAN when unmapped.
- (CGFloat)documentCenterYOfSearchMatchAtIndex:(NSUInteger)index page:(NSInteger*)outPage {
    SPDFMarkdownMatchGeometry place = [self geometryOfSearchMatchAtIndex:index];
    if (place.page < 0) {
        if (outPage) *outPage = (NSInteger)[_pagedView pageIndexForRange:_searchMatches[index].range];
        return NAN;
    }
    if (outPage) *outPage = place.page;
    return NSMinY([_pagedView frameForPageAtIndex:(NSUInteger)place.page]) + NSMidY(place.rect);
}

@end
