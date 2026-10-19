#import "SPDFMacFindExecution.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacFindContext.h"
#import "SPDFMacFindFailure.h"
#import "SPDFMacLaunchPrerenderPrivate.h"
@interface ShenzhenMacDelegate (SPDFFindExecutionPrivate)
- (void)clearFindResults;
- (void)applySearchHighlightsToCurrentPage;
- (NSString*)activeWorkingPath;
- (void)jumpToFindMatchAtIndex:(NSInteger)index;
@end

@implementation ShenzhenMacDelegate (SPDFMacFindExecution)
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
    [self updateFindControls];
    if (resetSavedIndex || revealMatch) [self showSearchSidebarForFind];
    _statusLabel.stringValue = [NSString stringWithFormat:@"Searching for \"%@\"...", query];
    [_findQueue addOperationWithBlock:^{
      @autoreleasepool {
          NSMutableDictionary<NSNumber*, NSArray<NSValue*>*>* highlights = [NSMutableDictionary dictionary];
          NSMutableArray<NSDictionary*>* matches = [NSMutableArray array];
          __block NSString* searchError = nil;
          char openErr[1024];
          spdf_document* doc = [self openSpdfDocumentAtPath:path
                                                 sourcePath:sourcePath
                                                     status:NULL
                                                      error:openErr
                                                errorLength:sizeof(openErr)];
          if (!doc) {
              NSString* failure=[NSString stringWithUTF8String:openErr[0] ? openErr : "Could not read the document."];
              [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                if (generation != self->_findGeneration) return;
            if (publicationAllowed && !publicationAllowed()) {
                self->_findSearchInProgress=NO; [self updateFindControls]; return;
            }
                self->_findSearchInProgress = NO;
                [self setFindFailureMessage:[NSString stringWithFormat:@"Search unavailable. Press Enter to retry.\n%@",failure]];
                [self updateFindControls];
                [self rebuildSidebar];
              }];
              return;
          }

          NSInteger pageCount = spdf_page_count(doc);
          for (NSInteger page = 0; page < pageCount; ++page) {
              if (generation != self->_findGeneration) break;
              char err[512];
              spdf_rect rects[256];
              int count = spdf_search_page_rects_options(doc, (int)page, query.UTF8String, useRegex, useRegexMultiline,
                                                         rects, 256, err, sizeof(err));
              if (count < 0) {
                  searchError = [NSString stringWithUTF8String:err[0] ? err : "Search failed"];
                  break;
              }
              if (count <= 0) continue;
              NSMutableArray<NSValue*>* values = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
              spdf_text_lines lines;
              memset(&lines, 0, sizeof(lines));
              BOOL hasTextLines = spdf_extract_page_text_lines(doc, (int)page, &lines, err, sizeof(err));
              SPDFMacFindContext* contexts=[[SPDFMacFindContext alloc] initWithLines:hasTextLines ? &lines : NULL
                  query:query regex:useRegex multiline:useRegexMultiline];
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
              highlights[@(page)] = values;
          }
          spdf_close(doc);

          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            if (generation != self->_findGeneration) return;
            if (publicationAllowed && !publicationAllowed()) {
                self->_findSearchInProgress=NO; [self updateFindControls]; return;
            }
            [self->_findHighlights removeAllObjects];
            [self->_findHighlights addEntriesFromDictionary:highlights];
            [self->_findMatches removeAllObjects];
            [self->_findMatches addObjectsFromArray:matches];
            NSInteger preferredMatch = -1;
            if (preferredPage >= 0) {
                for (NSInteger i = 0; i < (NSInteger)self->_findMatches.count; ++i) {
                    if ([self->_findMatches[(NSUInteger)i][@"page"] integerValue] == preferredPage) {
                        preferredMatch = i;
                        break;
                    }
                }
            }
            if (preferredMatchIndex >= 0 && preferredMatchIndex < (NSInteger)self->_findMatches.count)
                preferredMatch = preferredMatchIndex;
            // New/changed query with no explicit target: select the match
            // nearest the current viewport (counter shows its true index)
            // instead of match #1, when the setting is enabled.
            if (preferredMatch < 0 && self->_searchJumpsToNearestResult)
                preferredMatch = [self nearestFindMatchIndexToCurrentViewport];
            self->_findMatchIndex = preferredMatch >= 0 ? preferredMatch : (self->_findMatches.count > 0 ? 0 : -1);
            self->_findSearchInProgress = NO;
            [self setFindFailureMessage:searchError.length ? [NSString stringWithFormat:@"Search failed: %@",searchError] : nil];
            [self rememberActiveTabFindState];
            [self applySearchHighlightsToCurrentPage];
            [self updateFindControls];
            [self rebuildSidebar];
            if (searchError.length > 0) {
                self->_statusLabel.stringValue = [NSString stringWithFormat:@"Invalid regex/search: %@", searchError];
            } else if (self->_findMatchIndex >= 0) {
                if (revealMatch) [self jumpToFindMatchAtIndex:self->_findMatchIndex];
                self->_statusLabel.stringValue =
                    [NSString stringWithFormat:@"%ld matches for \"%@\"", (long)self->_findMatches.count, query];
            } else
                self->_statusLabel.stringValue = [NSString stringWithFormat:@"No matches for \"%@\"", query];
          }];
      }
    }];
}

@end
