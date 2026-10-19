#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacPageRendering.h"

// Immediate, reversible in-document link following.
//
// The document view decides click-vs-drag on mouse-up and then has to decide
// WHEN to act. It used to always wait out NSEvent.doubleClickInterval so a
// double-click on link text could cancel the jump and select a word instead.
// That wait is the whole cost of clicking a table-of-contents entry: measured
// on a 22-page PDF, the deferral is ~503ms and the navigation it guards is
// ~5ms (hit test 0.0ms, page render enqueue 0.0ms, resize 0.2ms, scroll 0.2ms,
// toolbar/sidebar 2.9ms, state persist 2.0ms).
//
// So the wait is inverted rather than removed: a destination inside this
// document is reached immediately, and the multi-click gesture that used to
// pre-empt it now takes it back instead (documentViewRestoreDocumentPosition:).
// Word and block selection over link text keeps working; only the order
// changed. Links that leave the document keep the deferral -- launching
// another application is not something a second click can undo.
@implementation ShenzhenMacDelegate (SPDFMacLinkNavigation)

- (BOOL)documentViewFollowInDocumentLinkAtPageIndex:(NSInteger)pageIndex
                                          pagePoint:(NSPoint)pagePoint
                                      restoreOrigin:(NSPoint*)restoreOrigin
                                   restorePageIndex:(NSInteger*)restorePageIndex {
    if (!_doc || !_pageScrollView) return NO;

    char err[512];
    spdf_link_target target;
    // Classification only, and the same full check the activation itself runs
    // (detect_text_links=1) so the two never disagree about what is under the
    // point. It is a rect test against cached link data -- sub-millisecond.
    int hit = spdf_link_at_point(_doc, (int)pageIndex, (float)pagePoint.x, (float)pagePoint.y, &target,
                                 /*detect_text_links=*/1, err, sizeof(err));
    if (hit <= 0) return NO;
    BOOL staysInDocument = target.kind == SPDF_LINK_INTERNAL && target.page_index >= 0;
    spdf_free_link_target(&target);
    if (!staysInDocument) return NO;

    NSPoint origin = _pageScrollView.contentView.bounds.origin;
    NSInteger fromPageIndex = _pageIndex;
    if (![self documentViewOpenLinkAtPageIndex:pageIndex pagePoint:pagePoint]) return NO;

    if (restoreOrigin) *restoreOrigin = origin;
    if (restorePageIndex) *restorePageIndex = fromPageIndex;
    return YES;
}

- (void)documentViewRestoreDocumentPosition:(NSPoint)origin pageIndex:(NSInteger)pageIndex {
    if (!_doc || !_pageScrollView) return;
    // Same zoom and same page sizes, so the layout the jump scrolled through is
    // still the layout being scrolled back: restoring the clip origin restores
    // the exact pixels, and the view point the pending click carries maps back
    // to the page point the user pressed.
    NSInteger restored = MAX(0, MIN(pageIndex, spdf_page_count(_doc) - 1));
    _pageIndex = restored;
    _pageView.currentPageIndex = restored;
    [self scrollDocumentClipViewToOrigin:origin pageIndexHint:restored notify:NO];
    [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    [_pageView setNeedsDisplay:YES];
    [self updateMinimap];
    [self updateControls];
    [self selectCurrentSidebarRow];
    [self persistActiveState];
}

// A link used to arrive via scrollToPageRect:, which CENTERS its rect in the
// viewport. For a find hit that is right; for a link destination it means the
// tail of the preceding page sits above the thing you asked to see. Aligning to
// the top is also deterministic: the resulting offset depends only on the
// TARGET page's rect and the destination's own Y, never on page N-1.
- (void)scrollToLinkDestinationOnPage:(NSInteger)pageIndex pageY:(CGFloat)pageY {
    if (!_doc || !_pageScrollView || _renderedPages.count == 0) return;
    NSInteger page = MAX(0, MIN(pageIndex, (NSInteger)_renderedPages.count - 1));
    // Reuse the shared top-alignment for the horizontal origin, the presentation
    // -mode centering and the position bookkeeping; only Y differs, and only
    // when the destination names a point partway down the page.
    [self scrollToPage:page alignTop:YES];

    NSRect pageRect = [_pageView rectForPageAtIndex:page];
    if (_presentationMode || pageY <= 0.0 || NSIsEmptyRect(pageRect)) return;

    NSPoint origin = _pageScrollView.contentView.bounds.origin;
    origin.y = spdf_mac_link_destination_scroll_origin_y(pageRect, pageY, _zoom);
    [self scrollDocumentClipViewToOrigin:origin pageIndexHint:page notify:NO];
    [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    [_pageView setNeedsDisplay:YES];
    [self documentScrollPositionChanged];
    [self updateMinimap];
}

@end
