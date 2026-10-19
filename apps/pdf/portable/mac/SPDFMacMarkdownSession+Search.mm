#import "SPDFMacMarkdownSessionPrivate.h"

#import "SPDFMacFindNearest.h"

// The find/search half of the Markdown session, split out of
// SPDFMacMarkdownSession.mm: PDF-parity search (regex, nearest-match
// selection, reveal gating), the centered reveal with the animated red match
// flash, highlight publication to the paged view and minimap model, and the
// scrollbar trough markers.
@implementation SPDFMacMarkdownSession (Search)

- (void)removeSearchHighlights {
    _pagedView.searchRanges = @[];
    [_minimapModel updateSearchHighlightRects:nil];
    [self invalidateSearchScrollbarMarkers];
}

- (void)applySearchHighlights {
    NSMutableArray<NSValue*>* ranges = [NSMutableArray arrayWithCapacity:_searchMatches.count];
    for (SPDFMarkdownSearchMatch* match in _searchMatches) [ranges addObject:[NSValue valueWithRange:match.range]];
    _pagedView.searchRanges = ranges;
    [_minimapModel updateSearchHighlightRects:[_pagedView pageLocalRectsForRanges:ranges]];
    [self invalidateSearchScrollbarMarkers];
}

- (void)clearSearch {
    [_searchToken cancel];
    _searchToken = nil;
    _searchGeneration++;
    _searchMatches = @[];
    _currentMatchIndex = -1;
    _activeSearchQuery = nil;
    _searchErrorDescription = nil;
    [self clearMatchFlash];
    [self removeSearchHighlights];
    if (self.searchUpdateHandler) self.searchUpdateHandler(0, -1, NO);
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
- (void)searchForQuery:(NSString*)query regex:(BOOL)regex preferredIndex:(NSInteger)preferredIndex
    jumpToNearest:(BOOL)jumpToNearest reveal:(BOOL)reveal publicationAllowed:(BOOL (^)(void))publicationAllowed {
    [_searchToken cancel];
    _searchToken = nil;
    _searchGeneration++;
    NSUInteger searchGeneration = _searchGeneration;
    _searchErrorDescription = nil;
    [self clearMatchFlash];
    if (!query.length || !self.renderedDocument || !_active) {
        _searchMatches = @[];
        _currentMatchIndex = -1;
        _activeSearchQuery = nil;
        [self removeSearchHighlights];
        if (self.searchUpdateHandler) self.searchUpdateHandler(0, -1, NO);
        return;
    }
    // Pending citations must not be replayed by reflow/reload without their guard.
    _activeSearchQuery = publicationAllowed ? nil : [query copy];
    _activeSearchRegex = regex;
    if (self.searchUpdateHandler) self.searchUpdateHandler(0, -1, YES);
    SPDFMarkdownCancellationToken* token = [SPDFMarkdownCancellationToken new];
    _searchToken = token;
    SPDFMarkdownRenderedDocument* snapshot = self.renderedDocument;
    dispatch_async(_workQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError* error = nil;
      NSArray* matches = [snapshot searchForQuery:query
                                    caseSensitive:NO
                                            regex:regex
                                cancellationToken:token
                                            error:&error];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_active || token.isCancelled || searchGeneration != self->_searchGeneration) return;
        if (publicationAllowed && (self.renderedDocument!=snapshot || !publicationAllowed())) {
            [self clearSearch]; return;
        }
        self->_activeSearchQuery=[query copy];
        self->_searchToken = nil;
        self->_searchErrorDescription =
            matches ? nil : (error.localizedDescription ?: @"Invalid regular expression");
        self->_searchMatches = matches ?: @[];
        NSInteger resolved = preferredIndex;
        if (resolved < 0 && jumpToNearest) resolved = [self nearestMatchIndexToViewport];
        self->_currentMatchIndex =
            self->_searchMatches.count ? MAX(0, MIN(resolved, (NSInteger)self->_searchMatches.count - 1)) : -1;
        [self applySearchHighlights];
        if (reveal && self->_currentMatchIndex >= 0) [self revealCurrentMatch];
        if (self.searchUpdateHandler)
            self.searchUpdateHandler(self->_searchMatches.count, self->_currentMatchIndex, NO);
      });
    });
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

    NSInteger* pages = (NSInteger*)malloc(sizeof(NSInteger) * (size_t)count);
    CGFloat* centers = (CGFloat*)malloc(sizeof(CGFloat) * (size_t)count);
    if (!pages || !centers) {
        free(pages);
        free(centers);
        return -1;
    }
    for (NSInteger i = 0; i < count; ++i) {
        NSRange range = _searchMatches[(NSUInteger)i].range;
        NSInteger page = (NSInteger)[_pagedView pageIndexForRange:range];
        NSRect matchRect = [_pagedView firstRectForRange:range];
        pages[i] = page;
        centers[i] = NSIsEmptyRect(matchRect) && page >= 0 && page < (NSInteger)pageRects.count
                         ? NSMidY(pageRects[(NSUInteger)page].rectValue)
                         : NSMidY(matchRect);
    }
    NSInteger nearest =
        spdf_nearest_find_match_index(pages, centers, count, firstVisible, lastVisible, NSMidY(visible));
    free(pages);
    free(centers);
    return nearest;
}

- (NSArray<NSDictionary*>*)searchScrollbarMarkers {
    if (_searchMatches.count == 0 || !_pagedView) return @[];
    CGFloat canvasHeight = MAX(1.0, self.documentCanvasSize.height);
    NSMutableArray<NSDictionary*>* markers = [NSMutableArray arrayWithCapacity:_searchMatches.count];
    for (NSInteger i = 0; i < (NSInteger)_searchMatches.count; ++i) {
        NSRect matchRect = [_pagedView firstRectForRange:_searchMatches[(NSUInteger)i].range];
        if (NSIsEmptyRect(matchRect)) continue;
        CGFloat fraction = NSMidY(matchRect) / canvasHeight;
        [markers addObject:@{
            @"fraction" : @(MAX(0.0, MIN(1.0, fraction))),
            @"active" : @(i == _currentMatchIndex)
        }];
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
    NSInteger count = (NSInteger)_searchMatches.count;
    _currentMatchIndex =
        _currentMatchIndex < 0 ? (forward ? 0 : count - 1) : (_currentMatchIndex + (forward ? 1 : -1) + count) % count;
    [self revealCurrentMatch];
    if (self.matchIndexChangedHandler) self.matchIndexChangedHandler(_currentMatchIndex, _searchMatches.count);
}

- (void)goToSearchMatchAtIndex:(NSInteger)matchIndex {
    if (matchIndex < 0 || matchIndex >= (NSInteger)_searchMatches.count) return;
    _currentMatchIndex = matchIndex;
    [self revealCurrentMatch];
    if (self.matchIndexChangedHandler) self.matchIndexChangedHandler(_currentMatchIndex, _searchMatches.count);
}

@end
