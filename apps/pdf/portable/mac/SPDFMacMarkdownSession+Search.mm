#import "SPDFMacMarkdownSessionPrivate.h"

#import "SPDFMacFindNearest.h"
#import "SPDFMacMarkdownPageCanvas.h"

#include <vector>

// The find/search half of the Markdown session, split out of
// SPDFMacMarkdownSession.mm: PDF-parity search (regex, nearest-match
// selection, reveal gating), the centered reveal with the animated red match
// flash, highlight publication to the paged view and minimap model, and the
// scrollbar trough markers.
//
// A search runs page by page on background workers (SPDFMacProgressiveSearch)
// and maps each page's matches to rects there too, so the main thread only
// merges results: a one-letter query over a 1,500-page document finds ~100,000
// matches, and doing the mapping on the main thread hung the app for minutes.
// Matches are kept in text order as pages arrive, so next/previous and
// "x / total" follow the document even while the search runs.


// Matches of one slice, mapped to rects on `pagePosition` of the geometry's
// plan (-1: no geometry). Runs on a search worker.
static SPDFMarkdownPageSearchHits* SPDFMarkdownSearchSlice(SPDFMarkdownRenderedDocument* snapshot, NSString* query,
                                                           NSRegularExpression* expression, NSRange slice,
                                                           SPDFMarkdownSearchGeometry* geometry,
                                                           NSInteger pagePosition,
                                                           SPDFMarkdownCancellationToken* token) {
    if (!slice.length) return nil;
    NSArray<SPDFMarkdownSearchMatch*>* matches = [snapshot searchMatchesForQuery:query
                                                                   caseSensitive:NO
                                                                      expression:expression
                                                                 startingInRange:slice
                                                               cancellationToken:token];
    if (!matches.count || token.isCancelled) return nil;
    SPDFMarkdownPageSearchHits* hits = [SPDFMarkdownPageSearchHits new];
    hits.matches = matches;
    std::vector<SPDFMarkdownMatchGeometry> places(matches.count, SPDFMarkdownMatchGeometry{-1, NSZeroRect});
    NSMutableArray<NSValue*>* rects = [NSMutableArray array];
    hits.pageIndex = -1;
    if (geometry && pagePosition >= 0) {
        std::vector<NSRange> ranges;
        ranges.reserve(matches.count);
        for (SPDFMarkdownSearchMatch* match in matches) ranges.push_back(match.range);
        SPDFMarkdownRangeIndex* index = [[SPDFMarkdownRangeIndex alloc] initWithRangeBuffer:ranges.data()
                                                                                      count:ranges.size()];
        NSInteger pageIndex = (NSInteger)geometry.plan.pages[(NSUInteger)pagePosition].pageIndex;
        hits.pageIndex = pageIndex;
        SPDFMarkdownMatchGeometry* placesData = places.data();
        [geometry enumerateRectsForRanges:index
                            onPageAtIndex:(NSUInteger)pagePosition
                               usingBlock:^(NSUInteger rangeIndex, NSRect rect) {
                                 [rects addObject:[NSValue valueWithRect:rect]];
                                 if (placesData[rangeIndex].page < 0) placesData[rangeIndex] = {pageIndex, rect};
                               }];
    }
    hits.geometry = [NSData dataWithBytes:places.data() length:places.size() * sizeof(SPDFMarkdownMatchGeometry)];
    hits.pageRects = rects;
    return hits;
}

@implementation SPDFMacMarkdownSession (Search)

- (void)removeSearchHighlights {
    _pagedView.searchRanges = @[];
    [_minimapModel updateSearchHighlightRects:nil];
    [self invalidateSearchScrollbarMarkers];
}

// Shows the current matches and the rects mapped so far.
- (void)publishSearchHighlights {
    NSMutableArray<NSValue*>* ranges = [NSMutableArray arrayWithCapacity:_searchMatches.count];
    for (SPDFMarkdownSearchMatch* match in _searchMatches) [ranges addObject:[NSValue valueWithRange:match.range]];
    _pagedView.searchRanges = ranges;
    [_minimapModel updateSearchHighlightRects:_searchPageRects];
    [self invalidateSearchScrollbarMarkers];
}

// A new paged view (re-render, orientation): the ranges still hold, the rects
// are re-mapped onto its pages in the background.
- (void)applySearchHighlights {
    [self publishSearchHighlights];
    SPDFMarkdownSearchGeometry* geometry = _pagedView.searchGeometry;
    if (!geometry || !_searchMatches.count) return;
    std::vector<NSRange> ranges;
    ranges.reserve(_searchMatches.count);
    for (SPDFMarkdownSearchMatch* match in _searchMatches) ranges.push_back(match.range);
    SPDFMarkdownRangeIndex* index = [[SPDFMarkdownRangeIndex alloc] initWithRangeBuffer:ranges.data()
                                                                                  count:ranges.size()];
    NSUInteger generation = _searchGeneration;
    NSUInteger count = _searchMatches.count;
    SPDFMacMarkdownPagedView* pagedView = _pagedView;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      std::vector<SPDFMarkdownMatchGeometry> places(count, SPDFMarkdownMatchGeometry{-1, NSZeroRect});
      NSMutableDictionary<NSNumber*, NSArray<NSValue*>*>* rectsByPage = [NSMutableDictionary dictionary];
      NSArray<SPDFMarkdownPage*>* pages = geometry.plan.pages;
      SPDFMarkdownMatchGeometry* placesData = places.data();
      for (NSUInteger position = 0; position < pages.count; ++position) {
          @autoreleasepool {
              NSInteger pageIndex = (NSInteger)pages[position].pageIndex;
              NSMutableArray<NSValue*>* rects = [NSMutableArray array];
              [geometry enumerateRectsForRanges:index
                                  onPageAtIndex:position
                                     usingBlock:^(NSUInteger rangeIndex, NSRect rect) {
                                       [rects addObject:[NSValue valueWithRect:rect]];
                                       if (placesData[rangeIndex].page < 0) placesData[rangeIndex] = {pageIndex, rect};
                                     }];
              if (rects.count) rectsByPage[@(pageIndex)] = rects;
          }
      }
      NSData* mapped = [NSData dataWithBytes:places.data() length:count * sizeof(SPDFMarkdownMatchGeometry)];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_searchGeneration || pagedView != self->_pagedView ||
            count != self->_searchMatches.count)
            return;
        self->_searchMatchGeometry = [mapped mutableCopy];
        self->_searchPageRects = rectsByPage;
        [self->_minimapModel updateSearchHighlightRects:rectsByPage];
        [self invalidateSearchScrollbarMarkers];
      });
    });
}

- (void)cancelRunningSearch {
    [_search cancel];
    _search = nil;
    _searchReplacesPrevious = NO;
    _searchPendingPages = nil;
}

- (void)resetSearchResults {
    [self cancelRunningSearch];
    [self resetSearchMatches];
}

- (void)resetSearchMatches {
    _searchMatches = [NSMutableArray array];
    _searchMatchGeometry = [NSMutableData data];
    _searchPageRects = [NSMutableDictionary dictionary];
    _searchedPages = [NSMutableIndexSet indexSet];
    _searchSlices = nil;
    _searchOrderPrefix = 0;
    _currentMatchIndex = -1;
}

- (void)clearSearch {
    [_searchToken cancel];
    _searchToken = nil;
    _searchGeneration++;
    [self resetSearchResults];
    _activeSearchQuery = nil;
    _searchErrorDescription = nil;
    [self clearMatchFlash];
    [self removeSearchHighlights];
    if (self.searchUpdateHandler) self.searchUpdateHandler(0, -1, NO);
}

- (double)searchProgress {
    if (!_search || !_search.pageCount) return 1.0;
    return (double)_search.pagesSearched / (double)_search.pageCount;
}

- (void)searchForQuery:(NSString*)query preferredIndex:(NSInteger)preferredIndex {
    [self searchForQuery:query regex:NO preferredIndex:preferredIndex jumpToNearest:NO reveal:YES];
}

- (void)searchForQuery:(NSString*)query
                 regex:(BOOL)regex
        preferredIndex:(NSInteger)preferredIndex
         jumpToNearest:(BOOL)jumpToNearest
                reveal:(BOOL)reveal {
    [self searchForQuery:query regex:regex preferredIndex:preferredIndex jumpToNearest:jumpToNearest
        reveal:reveal publicationAllowed:nil];
}

// The slices the workers search: one per page, from the page's first
// fragment to the next page's, so a page's matches arrive together and map
// onto that page. Without page geometry, fixed-size slices.
- (NSData*)searchSlicesForLength:(NSUInteger)length geometry:(SPDFMarkdownSearchGeometry*)geometry {
    std::vector<NSRange> slices;
    if (geometry) {
        NSArray<SPDFMarkdownPage*>* pages = geometry.plan.pages;
        std::vector<NSUInteger> starts(pages.count, 0);
        NSUInteger previous = 0;
        for (NSUInteger position = 0; position < pages.count; ++position) {
            NSUInteger start = NSNotFound;
            for (SPDFMarkdownPageFragment* fragment in pages[position].fragments)
                start = MIN(start, fragment.attributedRange.location);
            if (start == NSNotFound) start = previous;
            start = position == 0 ? 0 : MIN(length, MAX(previous, start));
            starts[position] = start;
            previous = start;
        }
        for (NSUInteger position = 0; position < pages.count; ++position) {
            NSUInteger end = position + 1 < pages.count ? starts[position + 1] : length;
            slices.push_back(NSMakeRange(starts[position], end - starts[position]));
        }
    } else {
        static const NSUInteger sliceLength = 64 * 1024;
        for (NSUInteger start = 0; start < length; start += sliceLength)
            slices.push_back(NSMakeRange(start, MIN(sliceLength, length - start)));
    }
    return [NSData dataWithBytes:slices.data() length:slices.size() * sizeof(NSRange)];
}

- (void)searchForQuery:(NSString*)query regex:(BOOL)regex preferredIndex:(NSInteger)preferredIndex
    jumpToNearest:(BOOL)jumpToNearest reveal:(BOOL)reveal publicationAllowed:(BOOL (^)(void))publicationAllowed {
    BOOL rerun = !reveal && _searchMatches.count && [query isEqualToString:_activeSearchQuery] &&
                 regex == _activeSearchRegex;
    [_searchToken cancel];
    _searchToken = nil;
    _searchGeneration++;
    NSUInteger searchGeneration = _searchGeneration;
    _searchErrorDescription = nil;
    [self clearMatchFlash];
    [self cancelRunningSearch];
    static const NSUInteger maximumInteractiveQueryLength = 4096;
    if (!query.length || query.length > maximumInteractiveQueryLength || !self.renderedDocument || !_active) {
        [self resetSearchMatches];
        _activeSearchQuery = nil;
        [self removeSearchHighlights];
        if (self.searchUpdateHandler) self.searchUpdateHandler(0, -1, NO);
        return;
    }
    // Pending citations must not be replayed by reflow/reload without their guard.
    _activeSearchQuery = publicationAllowed ? nil : [query copy];
    _activeSearchRegex = regex;
    if (rerun) {
        _searchReplacesPrevious = YES;
        _searchPendingPages = [NSMutableArray array];
    } else {
        [self resetSearchMatches];
        [self removeSearchHighlights];
    }
    NSRegularExpression* expression = nil;
    if (regex) {
        NSError* error = nil;
        expression = [NSRegularExpression regularExpressionWithPattern:query
                                                               options:NSRegularExpressionCaseInsensitive
                                                                 error:&error];
        if (!expression) {
            [self cancelRunningSearch];
            [self resetSearchMatches];
            [self removeSearchHighlights];
            _activeSearchQuery = [query copy];
            _searchErrorDescription = error.localizedDescription ?: @"Invalid regular expression";
            if (self.searchUpdateHandler) self.searchUpdateHandler(0, -1, NO);
            return;
        }
    }
    SPDFMarkdownCancellationToken* token = [SPDFMarkdownCancellationToken new];
    _searchToken = token;
    SPDFMarkdownRenderedDocument* snapshot = self.renderedDocument;
    NSUInteger length = snapshot.attributedString.length;
    SPDFMarkdownSearchGeometry* geometry = _pagedView.searchGeometry;
    if (geometry.attributedString.length != length) geometry = nil;
    NSData* slices = [self searchSlicesForLength:length geometry:geometry];
    _searchSlices = slices;
    NSUInteger sliceCount = slices.length / sizeof(NSRange);
    // Nearest-first: start at the page on screen and pick the first match at
    // or after its top as soon as the pages before it in that order are done.
    NSUInteger firstSlice = 0;
    _searchStartLocation = 0;
    if (jumpToNearest && geometry && _pagedView) {
        firstSlice = (NSUInteger)MAX((NSInteger)0, MIN((NSInteger)sliceCount - 1, self.currentPageIndex));
        _searchStartLocation = MAX(((const NSRange*)slices.bytes)[firstSlice].location,
                                   _pagedView.visibleAttributedLocation);
    }
    _searchPicksFirstMatch = preferredIndex < 0;
    _searchRevealsFirstMatch = reveal;
    if (self.searchUpdateHandler) self.searchUpdateHandler(0, -1, YES);
    SPDFMacProgressiveSearch* search =
        [[SPDFMacProgressiveSearch alloc] initWithPageCount:sliceCount
                                                  firstPage:firstSlice
                                                workerCount:[SPDFMacProgressiveSearch workerCountForPageCount:sliceCount]];
    search.startQueue = _workQueue;
    _search = search;
    const NSRange* sliceRanges = (const NSRange*)slices.bytes;
    __weak SPDFMacMarkdownSession* weakSelf = self;
    BOOL (^stillWanted)(void) = ^BOOL {
      SPDFMacMarkdownSession* strongSelf = weakSelf;
      if (!strongSelf || !strongSelf->_active || token.isCancelled || searchGeneration != strongSelf->_searchGeneration)
          return NO;
      if (publicationAllowed && (strongSelf.renderedDocument != snapshot || !publicationAllowed())) {
          [strongSelf clearSearch];
          return NO;
      }
      return YES;
    };
    [search startWithContext:^id(NSString** error) {
      (void)error;
      return slices;  // keeps the slice buffer alive for the workers
    }
        searchPage:^id(id context, NSUInteger slice, NSString** error) {
          (void)context;
          (void)error;
          return SPDFMarkdownSearchSlice(snapshot, query, expression, sliceRanges[slice], geometry,
                                         geometry ? (NSInteger)slice : -1, token);
        }
        closeContext:nil
        results:^(NSArray<SPDFMacSearchPageResult*>* pages) {
          if (!stillWanted()) return;
          [weakSelf mergeSearchPages:pages];
        }
        completion:^(NSString* error) {
          (void)error;
          if (!stillWanted()) return;
          [weakSelf finishSearchWithPreferredIndex:preferredIndex jumpToNearest:jumpToNearest reveal:reveal];
        }];
}

// Match index of the search match nearest the current viewport (the PDF path's
// nearestFindMatchIndexToCurrentViewport, over canvas geometry). -1 when it
// cannot be computed, in which case the caller falls back to the first match.
- (NSInteger)nearestMatchIndexToViewport {
    NSInteger count = (NSInteger)_searchMatches.count;
    if (count == 0 || !_pagedView) return -1;
    NSRect visible = _pagedView.documentVisibleRect;
    if (NSIsEmptyRect(visible)) return -1;
    NSArray<NSValue*>* pageRects = _pagedView.documentPageRects;
    if (pageRects.count == 0) return -1;

    // Visible page range: pages are stacked top-to-bottom in increasing Y, so
    // scan with an early break (same invariant as the PDF page layout).
    NSInteger firstVisible = -1;
    NSInteger lastVisible = -1;
    for (NSInteger i = 0; i < (NSInteger)pageRects.count; ++i) {
        NSRect pageRect = pageRects[(NSUInteger)i].rectValue;
        if (NSIsEmptyRect(pageRect)) continue;
        if (NSMinY(pageRect) > NSMaxY(visible)) break;
        if (NSMaxY(pageRect) < NSMinY(visible)) continue;
        if (firstVisible < 0) firstVisible = i;
        lastVisible = i;
    }
    if (firstVisible < 0) {
        firstVisible = MAX(0, self.currentPageIndex);
        lastVisible = firstVisible;
    }

    std::vector<NSInteger> pages((size_t)count);
    std::vector<CGFloat> centers((size_t)count);
    for (NSInteger i = 0; i < count; ++i) {
        NSInteger page = -1;
        CGFloat center = [self documentCenterYOfSearchMatchAtIndex:(NSUInteger)i page:&page];
        pages[(size_t)i] = page;
        centers[(size_t)i] = isnan(center) && page >= 0 && page < (NSInteger)pageRects.count
                                 ? NSMidY(pageRects[(NSUInteger)page].rectValue)
                                 : center;
    }
    return spdf_nearest_find_match_index(pages.data(), centers.data(), count, firstVisible, lastVisible,
                                          NSMidY(visible));
}

// One marker per trough position: 100,000 matches would otherwise mean
// 100,000 markers drawn into a few hundred points of scroller.
- (NSArray<NSDictionary*>*)searchScrollbarMarkers {
    if (_searchMatches.count == 0 || !_pagedView) return @[];
    CGFloat canvasHeight = MAX(1.0, self.documentCanvasSize.height);
    static const double buckets = 2048.0;
    NSMutableIndexSet* taken = [NSMutableIndexSet indexSet];
    NSMutableArray<NSDictionary*>* markers = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)_searchMatches.count; ++i) {
        CGFloat center = [self documentCenterYOfSearchMatchAtIndex:(NSUInteger)i page:NULL];
        if (isnan(center)) continue;
        CGFloat fraction = MAX(0.0, MIN(1.0, center / canvasHeight));
        BOOL active = i == _currentMatchIndex;
        NSUInteger bucket = (NSUInteger)(fraction * buckets);
        if (!active && [taken containsIndex:bucket]) continue;
        [taken addIndex:bucket];
        [markers addObject:@{@"fraction" : @(fraction), @"active" : @(active)}];
    }
    return markers;
}

- (void)invalidateSearchScrollbarMarkers {
    [_pagedView.verticalScroller setNeedsDisplay:YES];
}

// PDF flash envelope (stepFindFlash: at 60Hz): blink in (0.10s), blink out
// (0.08s), blink in (0.08s), a 1s hold, then a 0.25s fade.
static CGFloat SPDFMacMarkdownFindFlashAlpha(NSTimeInterval elapsed, BOOL* finished) {
    *finished = NO;
    if (elapsed < 0.10) return (CGFloat)(elapsed / 0.10);
    if (elapsed < 0.18) return (CGFloat)(1.0 - (elapsed - 0.10) / 0.08);
    if (elapsed < 0.26) return (CGFloat)((elapsed - 0.18) / 0.08);
    if (elapsed < 1.26) return 1.0;
    if (elapsed < 1.51) return (CGFloat)(1.0 - (elapsed - 1.26) / 0.25);
    *finished = YES;
    return 0.0;
}

- (void)clearMatchFlash {
    [_matchFlashTimer invalidate];
    _matchFlashTimer = nil;
    _pagedView.activeSearchRange = NSMakeRange(0, 0);
    _pagedView.activeSearchAlpha = 0.0;
}

- (void)flashMatchRange:(NSRange)range {
    if (!range.length) return;
    [_matchFlashTimer invalidate];
    _pagedView.activeSearchRange = range;
    _pagedView.activeSearchAlpha = 0.0;
    _matchFlashStartTime = NSDate.timeIntervalSinceReferenceDate;
    // The timer retains the session only for the flash's bounded 1.51s life.
    _matchFlashTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                        target:self
                                                      selector:@selector(stepMatchFlash:)
                                                      userInfo:nil
                                                       repeats:YES];
    [self stepMatchFlash:_matchFlashTimer];
}

- (void)stepMatchFlash:(NSTimer*)timer {
    (void)timer;
    BOOL finished = NO;
    CGFloat alpha =
        SPDFMacMarkdownFindFlashAlpha(NSDate.timeIntervalSinceReferenceDate - _matchFlashStartTime, &finished);
    if (finished) {
        [self clearMatchFlash];
        return;
    }
    _pagedView.activeSearchAlpha = MAX(0.0, MIN(1.0, alpha));
}

- (void)revealCurrentMatch {
    if (_currentMatchIndex < 0 || _currentMatchIndex >= (NSInteger)_searchMatches.count) return;
    NSRange range = _searchMatches[(NSUInteger)_currentMatchIndex].range;
    // PDF parity: the match is centered in the viewport (chapter/anchor
    // navigation keeps the top-aligned revealRange:), then flashed.
    if (![_pagedView centerRange:range]) [_pagedView revealRange:range];
    [self flashMatchRange:range];
}

- (void)moveToNextMatch:(BOOL)forward {
    if (_searchMatches.count == 0) return;
    _searchPicksFirstMatch = NO;  // the reader is moving; a running search leaves the selection alone
    NSInteger count = (NSInteger)_searchMatches.count;
    _currentMatchIndex =
        _currentMatchIndex < 0 ? (forward ? 0 : count - 1) : (_currentMatchIndex + (forward ? 1 : -1) + count) % count;
    [self revealCurrentMatch];
    if (self.matchIndexChangedHandler) self.matchIndexChangedHandler(_currentMatchIndex, _searchMatches.count);
}

- (void)goToSearchMatchAtIndex:(NSInteger)matchIndex {
    if (matchIndex < 0 || matchIndex >= (NSInteger)_searchMatches.count) return;
    _searchPicksFirstMatch = NO;
    _currentMatchIndex = matchIndex;
    [self revealCurrentMatch];
    if (self.matchIndexChangedHandler) self.matchIndexChangedHandler(_currentMatchIndex, _searchMatches.count);
}

@end
