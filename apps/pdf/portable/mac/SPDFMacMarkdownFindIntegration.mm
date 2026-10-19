#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacFindExecution.h"

#import "SPDFMacMarkdownSidebarModel.h"
#import "markdown/SPDFMarkdown.h"

// Find/search integration for Markdown tabs: the toolbar search entry point,
// the session's search callbacks, and match metadata — the Markdown half of
// the PDF tab's find experience (nearest-match selection, reveal gating,
// "Match N of M" jumps that never rebuild the sidebar, regex support, and the
// minimap/scrollbar marker refreshes).
@implementation ShenzhenMacDelegate (SPDFMacMarkdownFindIntegration)

// Sets the status line and re-asserts it once the queued viewport-driven
// controls refresh has run: a reveal schedules an async
// updateControlsForActiveMarkdown that would otherwise overwrite the find
// status with "Page N of M" one runloop later (the PDF path sets its status
// after all synchronous control updates, so the find status is what remains).
- (void)setMarkdownFindStatus:(NSString*)status {
    _statusLabel.stringValue = status;
    __weak ShenzhenMacDelegate* weakSelf = self;
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    dispatch_async(dispatch_get_main_queue(), ^{
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (strongSelf && strongSelf.activeMarkdownSession == session) strongSelf->_statusLabel.stringValue = status;
    });
}

- (void)configureMarkdownFindHandlersForSession:(SPDFMacMarkdownSession*)session tab:(SPDFDocumentTab*)tab {
    __weak ShenzhenMacDelegate* weakSelf = self;
    __weak SPDFMacMarkdownSession* weakSession = session;
    session.searchUpdateHandler = ^(NSUInteger count, NSInteger currentIndex, BOOL searching) {
      ShenzhenMacDelegate* strongSelf = weakSelf;
      SPDFMacMarkdownSession* strongSession = weakSession;
      if (!strongSelf || !strongSession || strongSelf.activeMarkdownSession != strongSession ||
          [strongSelf selectedTab] != tab)
          return;
      [strongSelf handleMarkdownSearchUpdateForSession:strongSession
                                                   tab:tab
                                                 count:count
                                          currentIndex:currentIndex
                                             searching:searching];
    };
    session.matchIndexChangedHandler = ^(NSInteger currentIndex, NSUInteger count) {
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.activeMarkdownSession != weakSession || [strongSelf selectedTab] != tab) return;
      [strongSelf handleMarkdownMatchIndexChangeForTab:tab currentIndex:currentIndex count:count];
    };
}

// Full search-lifecycle updates (start, completion, clear): republish the
// match metadata, rebuild the sidebar, and refresh the minimap markers.
- (void)handleMarkdownSearchUpdateForSession:(SPDFMacMarkdownSession*)session
                                         tab:(SPDFDocumentTab*)tab
                                       count:(NSUInteger)count
                                currentIndex:(NSInteger)currentIndex
                                   searching:(BOOL)searching {
    _findSearchInProgress = searching;
    [_findMatches removeAllObjects];
    SPDFMacMarkdownSidebarModel* sidebarModel = session.sidebarModel;
    NSArray<SPDFMarkdownSearchMatch*>* matches = session.searchMatches;
    for (NSUInteger index = 0; index < count && index < matches.count; ++index) {
        NSRange range = matches[index].range;
        [_findMatches addObject:@{
            @"markdownIndex" : @(index),
            @"page" : @([sidebarModel pageIndexForRange:range]),
            @"range" : [NSValue valueWithRange:range],
        }];
    }
    _findMatchIndex = currentIndex;
    tab.findMatchIndex = currentIndex;
    [self updateFindControls];
    [self rebuildSidebar];
    [self updateMarkdownMinimap];
    NSString* query = _searchField.stringValue ?: @"";
    if (searching || !query.length) return;
    if (session.searchErrorDescription.length) {
        [self setMarkdownFindStatus:[NSString stringWithFormat:@"Invalid regex/search: %@",
                                                               session.searchErrorDescription]];
    } else {
        [self setMarkdownFindStatus:
                  count ? [NSString stringWithFormat:@"%lu matches for \"%@\"", (unsigned long)count, query]
                        : [NSString stringWithFormat:@"No matches for \"%@\"", query]];
    }
}

// Index-only jumps (next/previous/sidebar activation): PDF parity is
// updateFindControls + selectCurrentSidebarRow + "Match N of M" — never a
// sidebar rebuild.
- (void)handleMarkdownMatchIndexChangeForTab:(SPDFDocumentTab*)tab
                                currentIndex:(NSInteger)currentIndex
                                       count:(NSUInteger)count {
    _findMatchIndex = currentIndex;
    tab.findMatchIndex = currentIndex;
    [self updateFindControls];
    [self selectCurrentSidebarRow];
    if (currentIndex < 0 || count == 0) return;
    [self setMarkdownFindStatus:[NSString stringWithFormat:@"Match %ld of %ld", (long)currentIndex + 1, (long)count]];
}

// Markdown branch of startFindForCurrentQueryResetSavedIndex:revealMatch: —
// the toolbar search field, regex checkbox toggles, and tab-switch restores.
- (void)startMarkdownFindForCurrentQueryResetSavedIndex:(BOOL)resetSavedIndex revealMatch:(BOOL)revealMatch {
    [self startMarkdownFindForCurrentQueryResetSavedIndex:resetSavedIndex revealMatch:revealMatch publicationAllowed:nil];
}
- (void)startMarkdownFindForCurrentQueryResetSavedIndex:(BOOL)resetSavedIndex revealMatch:(BOOL)revealMatch
    publicationAllowed:(BOOL (^)(void))publicationAllowed {
    SPDFDocumentTab* tab = [self selectedTab];
    if (!tab) return;
    NSString* query = [_searchField.stringValue copy] ?: @"";
    tab.searchText = query;
    tab.searchRegex = _findRegexCheckbox.state == NSControlStateValueOn;
    if (resetSavedIndex) tab.findMatchIndex = -1;
    if (!query.length) {
        [self clearMarkdownFindResults];
        [self updateFindControls];
        _statusLabel.stringValue = @"Ready";
        return;
    }
    // No explicit target (-1) lets the session pick the match nearest the
    // viewport, gated by the same setting as the PDF path.
    [self startMarkdownFindForQuery:query
                     preferredIndex:resetSavedIndex ? -1 : tab.findMatchIndex
                             reveal:revealMatch publicationAllowed:publicationAllowed];
    if (resetSavedIndex || revealMatch) [self showSearchSidebarForFind];
}

- (void)startMarkdownFindForQuery:(NSString*)query preferredIndex:(NSInteger)preferredIndex reveal:(BOOL)reveal {
    [self startMarkdownFindForQuery:query preferredIndex:preferredIndex reveal:reveal publicationAllowed:nil];
}
- (void)startMarkdownFindForQuery:(NSString*)query preferredIndex:(NSInteger)preferredIndex reveal:(BOOL)reveal
    publicationAllowed:(BOOL (^)(void))publicationAllowed {
    SPDFDocumentTab* tab = [self selectedTab];
    if (![self isMarkdownActive] || !tab) return;
    tab.searchText = query ?: @"";
    tab.searchRegex = _findRegexCheckbox.state == NSControlStateValueOn;
    tab.findMatchIndex = preferredIndex;
    [self.activeMarkdownSession searchForQuery:query ?: @""
                                         regex:tab.searchRegex
                                preferredIndex:preferredIndex
                                 jumpToNearest:_searchJumpsToNearestResult
                                        reveal:reveal publicationAllowed:publicationAllowed];
}

- (void)moveMarkdownFindForward:(BOOL)forward {
    // The session's matchIndexChangedHandler refreshes controls, the sidebar
    // row selection, and the "Match N of M" status.
    [self.activeMarkdownSession moveToNextMatch:forward];
}

- (void)clearMarkdownFindResults {
    [self.activeMarkdownSession clearSearch];
    [_findMatches removeAllObjects];
    _findMatchIndex = -1;
    _findSearchInProgress = NO;
    [self rebuildSidebar];
}

@end
