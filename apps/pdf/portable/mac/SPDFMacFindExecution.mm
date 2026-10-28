#import "SPDFMacFindExecution.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacFindContext.h"
#import "SPDFMacFindFailure.h"
#import "SPDFMacLaunchPrerenderPrivate.h"
#import "SPDFMacProgressiveSearch.h"

#import <objc/runtime.h>
@interface ShenzhenMacDelegate (SPDFFindExecutionPrivate)
- (void)clearFindResults;
- (void)applySearchHighlightsToCurrentPage;
- (NSString*)activeWorkingPath;
- (void)jumpToFindMatchAtIndex:(NSInteger)index;
@end

// The state of one running PDF/EPUB/text search, kept by the delegate.
@interface SPDFMacPDFFindRun : NSObject
@property(nonatomic, strong) SPDFMacProgressiveSearch* search;
@property(nonatomic, strong) NSMutableIndexSet* donePages;
@property(nonatomic) NSUInteger orderPrefix;
@property(nonatomic) BOOL picksFirstMatch;
@property(nonatomic) BOOL nearest;
@property(nonatomic) BOOL reveal;
@property(nonatomic) CFTimeInterval lastListRebuild;
@end
@implementation SPDFMacPDFFindRun
@end

// One search worker's open copy of the document.
@interface SPDFMacFindWorkerDocument : NSObject
@property(nonatomic) spdf_document* doc;
@property(nonatomic) NSUInteger pagesSinceOpen;
@end
@implementation SPDFMacFindWorkerDocument
@end

static char pdfFindRunKey;

@implementation ShenzhenMacDelegate (SPDFMacFindExecution)
- (SPDFMacPDFFindRun*)pdfFindRun {
    return objc_getAssociatedObject(self, &pdfFindRunKey);
}
- (void)setPdfFindRun:(SPDFMacPDFFindRun*)run {
    objc_setAssociatedObject(self, &pdfFindRunKey, run, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)resetSavedIndex revealMatch:(BOOL)revealMatch
    publicationAllowed:(BOOL (^)(void))publicationAllowed {
    if ([self isMarkdownActive]) {
        [self startMarkdownFindForCurrentQueryResetSavedIndex:resetSavedIndex revealMatch:revealMatch publicationAllowed:publicationAllowed];
        return;
    }
    if (!_doc || !_path.length) {
        [self clearFindResults];
        return;
    }

    NSString* query = [_searchField.stringValue copy];
    BOOL useRegex = _findRegexCheckbox.state == NSControlStateValueOn;
    BOOL useRegexMultiline = _findRegexMultiline;
    if (_selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count) {
        SPDFDocumentTab* tab = _tabs[(NSUInteger)_selectedTabIndex];
        tab.searchText = query ?: @"";
        tab.searchRegex = useRegex;
        tab.searchRegexMultiline = useRegexMultiline;
        if (resetSavedIndex) tab.findMatchIndex = -1;
    }
    [_findQueue cancelAllOperations];
    [self cancelProgressiveFind];
    _findGeneration++;
    NSUInteger generation = _findGeneration;
    [self setFindFailureMessage:nil];
    [_findHighlights removeAllObjects];
    [_findMatches removeAllObjects];
    _findMatchIndex = -1;
    _findSearchInProgress = NO;
    [self applySearchHighlightsToCurrentPage];
    [self updateFindControls];

    if (query.length == 0) {
        _pendingFindPreferredPage = -1;
        _pendingFindPreferredMatchIndex = -1;
        _statusLabel.stringValue = @"Ready";
        [self rebuildSidebar];
        return;
    }

    NSString* path = [self activeWorkingPath]; // temp copy for read-only source
    NSString* sourcePath = [_path copy];
    NSInteger preferredPage = _pendingFindPreferredPage;
    _pendingFindPreferredPage = -1;
    NSInteger preferredMatchIndex = _pendingFindPreferredMatchIndex;
    _pendingFindPreferredMatchIndex = -1;
    _findSearchInProgress = YES;
    self.findLiveMatchCount = 0;
    [self setFindProgress:0.0];
    [self updateFindControls];
    if (resetSavedIndex || revealMatch) [self showSearchSidebarForFind];
    _statusLabel.stringValue = [NSString stringWithFormat:@"Searching for \"%@\"...", query];

    // Pages are searched by a few workers, each with its own open copy of the
    // document, starting at the page on screen; matches show as they are found
    // and are kept in page order, so next/previous and "x / total" follow the
    // document even before the search ends.
    NSUInteger pageCount = (NSUInteger)MAX(0, spdf_page_count(_doc));
    BOOL nearest = preferredPage < 0 && preferredMatchIndex < 0 && _searchJumpsToNearestResult;
    NSUInteger firstPage = nearest ? (NSUInteger)MAX(0, MIN(_pageIndex, (NSInteger)pageCount - 1)) : 0;
    // Reflowable formats lay the whole book out when opened, so they get fewer copies.
    BOOL fixedLayout = [sourcePath.pathExtension caseInsensitiveCompare:@"pdf"] == NSOrderedSame;
    NSUInteger workers = [SPDFMacProgressiveSearch workerCountForPageCount:pageCount];
    if (!fixedLayout) workers = MIN(workers, (NSUInteger)2);
    SPDFMacProgressiveSearch* search = [[SPDFMacProgressiveSearch alloc] initWithPageCount:MAX(pageCount, (NSUInteger)1)
                                                                                firstPage:firstPage
                                                                              workerCount:workers];
    SPDFMacPDFFindRun* run = [SPDFMacPDFFindRun new];
    run.search = search;
    run.donePages = [NSMutableIndexSet indexSet];
    run.picksFirstMatch = preferredPage < 0 && preferredMatchIndex < 0;
    run.nearest = nearest;
    run.reveal = revealMatch;
    self.pdfFindRun = run;
    NSString* utf8Query = [query copy];
    __weak ShenzhenMacDelegate* weakSelf = self;
    BOOL (^stillWanted)(void) = ^BOOL {
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (!strongSelf || generation != strongSelf->_findGeneration) {
          [search cancel];
          return NO;
      }
      if (publicationAllowed && !publicationAllowed()) {
          [search cancel];
          strongSelf->_findSearchInProgress = NO;
          [strongSelf setFindProgress:1.0];
          [strongSelf updateFindControls];
          return NO;
      }
      return YES;
    };
    spdf_document* (^openCopy)(NSString**) = ^spdf_document*(NSString** error) {
      char openErr[1024];
      openErr[0] = 0;
      spdf_document* doc = [weakSelf openSpdfDocumentAtPath:path
                                                 sourcePath:sourcePath
                                                     status:NULL
                                                      error:openErr
                                                errorLength:sizeof(openErr)];
      if (!doc)
          *error = [NSString stringWithFormat:@"Search unavailable. Press Enter to retry.\n%@",
                                              [NSString stringWithUTF8String:openErr[0] ? openErr : "Could not read the document."]];
      return doc;
    };
    [search startWithContext:^id(NSString** error) {
      spdf_document* doc = openCopy(error);
      if (!doc) return nil;
      SPDFMacFindWorkerDocument* worker = [SPDFMacFindWorkerDocument new];
      worker.doc = doc;
      return worker;
    }
        searchPage:^id(id context, NSUInteger page, NSString** error) {
          SPDFMacFindWorkerDocument* worker = context;
          // A copy of the document keeps everything it has read; a PDF copy is
          // reopened now and then so a search's memory stays flat. (Reflowable
          // formats lay the whole book out again on open, so they keep theirs.)
          if (fixedLayout && ++worker.pagesSinceOpen > 48) {
              NSString* reopenError = nil;
              spdf_document* fresh = openCopy(&reopenError);
              if (fresh) {
                  spdf_close(worker.doc);
                  worker.doc = fresh;
                  worker.pagesSinceOpen = 0;
              }
          }
          spdf_document* doc = worker.doc;
          if (!doc || (NSInteger)page >= spdf_page_count(doc)) return nil;
          char err[512];
          err[0] = 0;
          spdf_rect rects[256];
          int count = spdf_search_page_rects_options(doc, (int)page, utf8Query.UTF8String, useRegex, useRegexMultiline,
                                                     rects, 256, err, sizeof(err));
          if (count < 0) {
              *error = [NSString stringWithUTF8String:err[0] ? err : "Search failed"];
              return nil;
          }
          if (count <= 0) return nil;
          NSMutableArray<NSValue*>* values = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
          NSMutableArray<NSDictionary*>* matches = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
          spdf_text_lines lines;
          memset(&lines, 0, sizeof(lines));
          BOOL hasTextLines = spdf_extract_page_text_lines(doc, (int)page, &lines, err, sizeof(err));
          SPDFMacFindContext* contexts = [[SPDFMacFindContext alloc] initWithLines:hasTextLines ? &lines : NULL
                                                                             query:utf8Query
                                                                             regex:useRegex
                                                                         multiline:useRegexMultiline];
          for (int i = 0; i < count; ++i) {
              NSRect r = NSMakeRect(rects[i].x0, rects[i].y0, rects[i].x1 - rects[i].x0, rects[i].y1 - rects[i].y0);
              [values addObject:[NSValue valueWithRect:r]];
              NSDictionary* context = [contexts contextForMatchRect:r];
              [matches addObject:@{
                  @"page" : @(page),
                  @"rect" : [NSValue valueWithRect:r],
                  @"context" : context[@"title"], @"matchRanges":context[@"matchRanges"]
              }];
          }
          if (hasTextLines) spdf_free_text_lines(&lines);
          return @{@"rects" : values, @"matches" : matches};
        }
        closeContext:^(id context) {
          SPDFMacFindWorkerDocument* worker = context;
          if (worker.doc) spdf_close(worker.doc);
          worker.doc = NULL;
        }
        results:^(NSArray<SPDFMacSearchPageResult*>* pages) {
          if (!stillWanted()) return;
          [weakSelf mergePDFFindPages:pages run:run];
        }
        completion:^(NSString* searchError) {
          if (!stillWanted()) return;
          [weakSelf finishPDFFindRun:run
                               query:query
                               error:searchError
                       preferredPage:preferredPage
                 preferredMatchIndex:preferredMatchIndex
                         revealMatch:revealMatch];
        }];
}

// Lower bound of `page` in the page-ordered matches.
- (NSUInteger)findMatchIndexForPage:(NSInteger)page {
    NSUInteger low = 0, high = _findMatches.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if ([_findMatches[middle][@"page"] integerValue] < page) low = middle + 1;
        else high = middle;
    }
    return low;
}

- (void)mergePDFFindPages:(NSArray<SPDFMacSearchPageResult*>*)pages run:(SPDFMacPDFFindRun*)run {
    BOOL currentPageChanged = NO;
    for (SPDFMacSearchPageResult* result in pages) {
        [run.donePages addIndex:result.pageIndex];
        NSDictionary* hits = result.payload;
        NSArray<NSDictionary*>* matches = hits[@"matches"];
        if (!matches.count) continue;
        NSUInteger insert = [self findMatchIndexForPage:(NSInteger)result.pageIndex];
        [_findMatches insertObjects:matches
                          atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insert, matches.count)]];
        if (_findMatchIndex >= (NSInteger)insert) _findMatchIndex += (NSInteger)matches.count;
        _findHighlights[@(result.pageIndex)] = hits[@"rects"];
        currentPageChanged |= (NSInteger)result.pageIndex == _pageIndex;
    }
    self.findLiveMatchCount = _findMatches.count;
    [self setFindProgress:(double)run.search.pagesSearched / (double)MAX((NSUInteger)1, run.search.pageCount)];
    [self pickFirstPDFFindMatchIfReady:run];
    if (currentPageChanged) [self applySearchHighlightsToCurrentPage];
    [self updateFindControls];
    // The list walks every match found so far: rebuilt at most twice a second.
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - run.lastListRebuild >= 0.5) {
        run.lastListRebuild = now;
        [self rebuildSidebar];
    }
    _statusLabel.stringValue = [NSString stringWithFormat:@"Searching for \"%@\"... %lu found",
                                                          _searchField.stringValue ?: @"",
                                                          (unsigned long)_findMatches.count];
}

// Walks the pages in search order from the starting page while they are done;
// the first match met there (the nearest one, on the starting page) is
// selected and shown without waiting for the rest of the document.
- (void)pickFirstPDFFindMatchIfReady:(SPDFMacPDFFindRun*)run {
    if (!run.picksFirstMatch) return;
    NSUInteger pageCount = run.search.pageCount;
    while (run.orderPrefix < pageCount) {
        NSUInteger page = (run.search.firstPage + run.orderPrefix) % pageCount;
        if (![run.donePages containsIndex:page]) return;
        NSUInteger index = [self findMatchIndexForPage:(NSInteger)page];
        BOOL starting = run.orderPrefix == 0;
        ++run.orderPrefix;
        if (index >= _findMatches.count || [_findMatches[index][@"page"] integerValue] != (NSInteger)page) continue;
        if (starting && run.nearest) {
            NSInteger nearest = [self nearestFindMatchIndexToCurrentViewport];
            if (nearest >= 0) index = (NSUInteger)nearest;
        }
        [self selectPDFFindMatch:(NSInteger)index run:run];
        return;
    }
}

- (void)selectPDFFindMatch:(NSInteger)index run:(SPDFMacPDFFindRun*)run {
    run.picksFirstMatch = NO;
    _findMatchIndex = index;
    [self applySearchHighlightsToCurrentPage];
    if (run.reveal) [self jumpToFindMatchAtIndex:index];
}

- (void)finishPDFFindRun:(SPDFMacPDFFindRun*)run
                   query:(NSString*)query
                   error:(NSString*)searchError
           preferredPage:(NSInteger)preferredPage
     preferredMatchIndex:(NSInteger)preferredMatchIndex
             revealMatch:(BOOL)revealMatch {
    if (self.pdfFindRun == run) self.pdfFindRun = nil;
    BOOL openFailed = [searchError hasPrefix:@"Search unavailable"];
    NSInteger count = (NSInteger)_findMatches.count;
    if (count && _findMatchIndex < 0) {
        NSInteger preferredMatch = -1;
        if (preferredPage >= 0) {
            NSUInteger index = [self findMatchIndexForPage:preferredPage];
            if (index < _findMatches.count && [_findMatches[index][@"page"] integerValue] == preferredPage)
                preferredMatch = (NSInteger)index;
        }
        if (preferredMatchIndex >= 0 && preferredMatchIndex < count) preferredMatch = preferredMatchIndex;
        // New/changed query with no explicit target: select the match
        // nearest the current viewport (counter shows its true index)
        // instead of match #1, when the setting is enabled.
        if (preferredMatch < 0 && _searchJumpsToNearestResult)
            preferredMatch = [self nearestFindMatchIndexToCurrentViewport];
        _findMatchIndex = preferredMatch >= 0 ? preferredMatch : 0;
        if (revealMatch) [self jumpToFindMatchAtIndex:_findMatchIndex];
    }
    _findSearchInProgress = NO;
    self.findLiveMatchCount = 0;
    [self setFindProgress:1.0];
    if (openFailed) {
        [self setFindFailureMessage:searchError];
        [self updateFindControls];
        [self rebuildSidebar];
        return;
    }
    [self setFindFailureMessage:searchError.length ? [NSString stringWithFormat:@"Search failed: %@", searchError] : nil];
    [self rememberActiveTabFindState];
    [self applySearchHighlightsToCurrentPage];
    [self updateFindControls];
    [self rebuildSidebar];
    if (searchError.length > 0) {
        _statusLabel.stringValue = [NSString stringWithFormat:@"Invalid regex/search: %@", searchError];
    } else if (_findMatchIndex >= 0) {
        _statusLabel.stringValue =
            [NSString stringWithFormat:@"%ld matches for \"%@\"", (long)_findMatches.count, query];
    } else
        _statusLabel.stringValue = [NSString stringWithFormat:@"No matches for \"%@\"", query];
}

// The search list in the sidebar, moved here with the search it lists.
// Attributes a search match to the outline heading that precedes it in reading
// order. `pt` is the top-left of the match rect in the app's TOP-DOWN page space
// (origin top-left, y increases downward), i.e. the same convention search rects
// use. Outline dest coordinates (spdf_outline_item.dest_x/dest_y) were determined
// empirically to ALSO be top-down on this corpus (a heading visually at the top of
// the page has the smallest dest_y, matching search rect y0), so no axis flip is
// needed and page height is not required to compare them. When the page has no
// outline entry with a usable dest that precedes the match, this falls back to the
// cross-page chapter carried over from earlier pages (today's page-only behavior),
// preserving correctness for single-heading-per-page docs and PDFs whose outline
// lacks coordinates.
- (NSString*)chapterTitleForMatchOnPage:(NSInteger)pageIndex atPagePoint:(NSPoint)pt {
    if (_outline.count <= 0) return @"";

    // Cross-page candidate: the last heading (document order) on the largest page
    // strictly before matchPage. This is the chapter that carried over onto the
    // match's page from earlier in the document. Mirrors chapterTitleForPage:'s
    // tie-break on level for same-page entries.
    // Titles are made into strings only for the two winners: the list asks
    // this once per listed match, and outlines can hold thousands of entries.
    int carryItem = -1;
    NSInteger carryPage = -1;
    NSInteger carryLevel = -1;

    // On-page candidate: among headings on matchPage that have a usable dest and
    // are at-or-before the match in reading order (y first with a tolerance, then
    // x), pick the latest one in reading order.
    const CGFloat yTol = 1.0; // small tolerance so a heading on the match's own line still counts
    BOOL haveOnPage = NO;
    int onPageItem = -1;
    CGFloat bestY = -CGFLOAT_MAX;
    CGFloat bestX = -CGFLOAT_MAX;

    for (int i = 0; i < _outline.count; ++i) {
        spdf_outline_item item = _outline.items[i];
        if (item.page_index < 0) continue;
        NSInteger level = MAX(0, item.level);

        if (item.page_index < pageIndex) {
            if (item.page_index < carryPage) continue;
            if (item.page_index == carryPage && level < carryLevel) continue;
            carryPage = item.page_index;
            carryLevel = level;
            carryItem = i;
            continue;
        }
        if (item.page_index > pageIndex) continue;

        // Same page as the match. Only usable if the heading carries a position.
        if (!item.has_dest) continue;
        CGFloat hy = (CGFloat)item.dest_y;
        CGFloat hx = (CGFloat)item.dest_x;
        // Heading must be at-or-before the match in reading order.
        BOOL precedes = (hy < pt.y + yTol) && (fabs(hy - pt.y) > yTol || hx <= pt.x);
        if (!precedes) continue;
        // Among those, keep the latest in reading order (largest y, then x).
        if (hy > bestY + yTol || (fabs(hy - bestY) <= yTol && hx >= bestX)) {
            bestY = hy;
            bestX = hx;
            onPageItem = i;
            haveOnPage = YES;
        }
    }

    NSString* (^titleOf)(int) = ^NSString*(int index) {
      const char* title = _outline.items[index].title;
      return title && *title ? [NSString stringWithUTF8String:title] : @"Untitled";
    };
    NSString* onPageTitle = haveOnPage ? titleOf(onPageItem) : @"";
    if (haveOnPage && onPageTitle.length) return onPageTitle;
    NSString* carryTitle = carryItem >= 0 ? titleOf(carryItem) : @"";
    if (carryTitle.length) return carryTitle;
    // No heading precedes the match anywhere: fall back to page-only grouping
    // (handles PDFs whose outline lacks dest coordinates entirely).
    NSString* fallback = [self chapterTitleForPage:pageIndex];
    return fallback.length ? fallback : @"Document";
}

- (void)rebuildSearchSidebarItems {
    if (!_doc || ![self hasSearchSidebar]) return;
    NSString* query = _searchField.stringValue ?: @"";
    if (_findSearchInProgress && _findMatches.count == 0) {
        [_sidebarItems addObject:@{
            @"kind" : @"findStatus",
            @"page" : @(-1),
            @"title" : [NSString stringWithFormat:@"Searching for \"%@\"...", query]
        }];
        return;
    }
    if (self.findFailureMessage.length) {
        [_sidebarItems addObject:@{@"kind":@"findStatus",@"page":@(-1),@"title":self.findFailureMessage}];
        if (!_findMatches.count) return;
    }
    if (_findMatches.count == 0) {
        NSString* title =
            query.length ? [NSString stringWithFormat:@"No matches for \"%@\"", query] : @"No search results";
        [_sidebarItems addObject:@{@"kind" : @"findStatus", @"page" : @(-1), @"title" : title}];
        return;
    }

    NSString* previousChapter = nil;
    NSInteger listed = (NSInteger)MIN(_findMatches.count, SPDFSearchSidebarListLimit);
    for (NSInteger i = 0; i < listed; ++i) {
        NSDictionary* match = _findMatches[(NSUInteger)i];
        NSInteger page = [match[@"page"] integerValue];
        NSRect matchRect = [match[@"rect"] rectValue];
        // Top-left of the match in top-down page space (origin top-left).
        NSPoint matchTopLeft = NSMakePoint(NSMinX(matchRect), NSMinY(matchRect));
        NSString* chapter = [self chapterTitleForMatchOnPage:page atPagePoint:matchTopLeft];
        if (chapter.length > 0 && ![chapter isEqualToString:previousChapter]) {
            [_sidebarItems addObject:@{@"kind" : @"findDivider", @"title" : chapter, @"page" : @(-1)}];
            previousChapter = chapter;
        }

        NSString* context = match[@"context"];
        if (![context isKindOfClass:NSString.class] || context.length == 0) context = query.length ? query : @"Match";
        NSString* subtitle = [NSString
            stringWithFormat:@"Page %ld - match %ld of %ld", (long)page + 1, (long)i + 1, (long)_findMatches.count];
        [_sidebarItems addObject:@{
            @"kind" : @"findResult",
            @"title" : context, @"matchRanges":match[@"matchRanges"] ?: @[],
            @"subtitle" : subtitle,
            @"query" : query,
            @"page" : @(page),
            @"findIndex" : @(i)
        }];
    }
    if (listed < (NSInteger)_findMatches.count)
        [_sidebarItems addObject:@{
            @"kind" : @"findStatus",
            @"page" : @(-1),
            @"title" : SPDFSearchSidebarOverflowTitle(_findMatches.count)
        }];
}

- (void)cancelProgressiveFind {
    [self.pdfFindRun.search cancel];
    self.pdfFindRun = nil;
    [self setFindProgress:1.0];
}

@end
