#import "../SPDFMacUIHelpers.h"

#import "../SPDFMacFitGeometry.h"
#import "../SPDFMacMarkdownPageCanvas.h"
#import "../SPDFMacMarkdownPagedView.h"
#import "../markdown/SPDFMarkdown.h"

#include <assert.h>

void spdf_activate_window_for_view(NSView* view) {
    (void)view;
}

// Regression for the "page number changes but the visible page does not" bug:
// goToPageAtIndex:alignTop: used AppKit's minimum-scroll scrollRectToVisible:,
// which moved nothing when the target page was already partially visible while
// _currentPageIndex still advanced. Both alignTop values must now land the
// page's top at the viewport top with the PDF path's 12pt breathing room, and
// out-of-range indexes must clamp to the first/last page.
void spdf_assert_paged_view_go_to_page_scrolls(SPDFMacMarkdownPagedView* view) {
    SPDFMacMarkdownPageCanvas* canvas = (SPDFMacMarkdownPageCanvas*)view.documentView;
    assert(view.pageCount > 2);
    NSRect page = [canvas frameForPageAtIndex:2];
    BOOL alignTopValues[] = {YES, NO};
    for (size_t i = 0; i < 2; ++i) {
        // Park the viewport so page 2 peeks in at the bottom edge — the exact
        // partially-visible state the minimum scroll used to leave alone.
        [view.contentView
            scrollToPoint:NSMakePoint(0, NSMinY(page) - NSHeight(view.contentView.bounds) + 40.0)];
        [view reflectScrolledClipView:view.contentView];
        assert(NSIntersectsRect(view.documentVisibleRect, page));
        NSPoint before = view.documentVisibleRect.origin;
        [view goToPageAtIndex:2 alignTop:alignTopValues[i]];
        assert(!NSEqualPoints(view.documentVisibleRect.origin, before)); // the viewport actually moved
        // The 12pt breathing room belongs to a page TALLER than the viewport; a
        // page that fits is centred, which at exact fit means flush with the
        // top. This fixture's page height equals the viewport height, so the
        // sheet's top must sit exactly at the viewport top -- stepping used to
        // subtract 12 unconditionally and leave a strip of canvas above it.
        assert(fabs(NSHeight(page) - NSHeight(view.documentVisibleRect)) <= 0.5);
        assert(fabs(NSMinY(view.documentVisibleRect) - NSMinY(page)) < 1.5);
        assert(view.currentPageIndex == 2);
    }
    [view goToPageAtIndex:-7 alignTop:YES];
    assert(view.currentPageIndex == 0);
    assert(NSMinY(view.documentVisibleRect) >= -0.5);
    [view goToPageAtIndex:(NSInteger)view.pageCount + 9 alignTop:NO];
    assert(view.currentPageIndex == (NSInteger)view.pageCount - 1);
    assert(NSMaxY(view.documentVisibleRect) <= view.documentCanvasSize.height + 0.5);
}

// Exact-viewport fit + vertical centering (live user requirements):
//   1. Fit Page fits the page EXACTLY: page height == viewport height (0.5pt),
//      page top at the viewport top; Fit Width fills the width exactly.
//   2. A one-page document at fit is NOT scrollable (canvas height <= viewport,
//      no vertical scroller); zooming OUT below fit keeps the page vertically
//      CENTERED (constrainBoundsRect clamps attempted scrolls back).
//   3. Multi-page documents keep their scroller and stay scrollable.
// Also unit-tests the shared pure inset math with the PDF view's constants
// (kPageMargin 44 -> decorative inset 22), the PDF layout's headless seam.
void spdf_assert_markdown_exact_fit_and_vertical_centering(SPDFMacMarkdownPagedView* multiPageView) {
    // --- Shared pure fit geometry, PDF convention (SPDFMacDocumentView.mm) ---
    assert(spdf_mac_vertical_canvas_inset(1, 700.0, 700.0, 22.0) == 0.0);   // exact fit: inset collapsed
    assert(spdf_mac_vertical_canvas_inset(1, 800.0, 700.0, 22.0) == 0.0);   // beyond fit: flush
    assert(spdf_mac_vertical_canvas_inset(1, 500.0, 700.0, 22.0) == 100.0); // single page: centered split
    assert(spdf_mac_vertical_canvas_inset(3, 700.0, 700.0, 22.0) == 0.0);   // multi-page exact fit: top at 0
    assert(spdf_mac_vertical_canvas_inset(3, 500.0, 700.0, 22.0) == 22.0);  // multi-page below fit: decorative cap
    assert(spdf_mac_vertical_canvas_inset(2, 670.0, 700.0, 22.0) == 15.0);  // near-fit band shrinks continuously
    assert(spdf_mac_vertical_canvas_inset(1, 500.0, 0.0, 22.0) == 22.0);    // viewport unknown: keep the chrome
    assert(spdf_mac_horizontal_canvas_margin(500.0, 900.0, 44.0) == 44.0);
    assert(spdf_mac_horizontal_canvas_margin(880.0, 900.0, 44.0) == 20.0);
    assert(spdf_mac_horizontal_canvas_margin(900.0, 900.0, 44.0) == 0.0);
    assert(spdf_mac_horizontal_canvas_margin(950.0, 900.0, 44.0) == 0.0);

    // --- One-page Markdown document, live paged view ---
    SPDFMarkdownParser* parser = [SPDFMarkdownParser new];
    SPDFMarkdownDocumentModel* model = [parser parseString:@"# One page\n\nA short paragraph.\n"
                                                 sourceURL:nil
                                                     error:nil];
    SPDFMarkdownRenderedDocument* rendered =
        [[SPDFMarkdownRenderer new] renderModel:model
                                        options:[SPDFMarkdownRenderOptions defaultOptions]
                              languageOverrides:nil];
    SPDFMarkdownPageConfiguration* configuration = [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    SPDFMarkdownPaginationPlan* plan =
        [paginator paginateItems:[paginator measureRenderedDocument:rendered
                                                     containerWidth:NSWidth(configuration.printableRect)]
                   configuration:configuration];
    assert(plan.pages.count == 1);
    SPDFMacMarkdownPagedView* view =
        [[SPDFMacMarkdownPagedView alloc] initWithPaginationPlan:plan attributedString:rendered.attributedString];
    view.frame = NSMakeRect(0, 0, 900, 700);
    [view layoutSubtreeIfNeeded];
    SPDFMacMarkdownPageCanvas* canvas = (SPDFMacMarkdownPageCanvas*)view.documentView;

    // Fit Page: page height == viewport height exactly, page top at viewport top.
    [view applyFitMode:SPDFMacMarkdownPageFitPage];
    NSSize viewport = view.contentSize;  // points
    NSRect pageFrame = [canvas frameForPageAtIndex:0];
    assert(fabs(NSHeight(pageFrame) * view.magnification - viewport.height) <= 0.5);
    assert(NSMinY(pageFrame) <= 0.5);                        // inset collapsed: page top at canvas top...
    assert(NSMinY(view.documentVisibleRect) <= 0.5);         // ...which sits at the viewport top
    assert(fabs(NSMidX(pageFrame) - NSMidX(view.contentView.bounds)) < 1.0);  // width centered
    // Nothing to scroll: the chrome must not force scrollability at exact fit.
    assert(view.documentCanvasSize.height <= NSHeight(view.contentView.bounds) + 0.5);
    assert(!view.hasVerticalScroller);
    NSPoint fitOrigin = view.documentVisibleRect.origin;
    [view scrollByDocumentDeltaX:0.0 deltaY:300.0];
    assert(fabs(view.documentVisibleRect.origin.y - fitOrigin.y) <= 0.5);
    assert(fabs(view.documentVisibleRect.origin.x - fitOrigin.x) <= 0.5);

    // Fit Width fills the viewport width exactly (same exact-viewport convention).
    [view applyFitMode:SPDFMacMarkdownPageFitWidth];
    assert(fabs(NSWidth([canvas frameForPageAtIndex:0]) * view.magnification - view.contentSize.width) <= 0.5);

    // Zooming OUT below fit keeps the single page vertically centered.
    [view applyFitMode:SPDFMacMarkdownPageFitPage];
    [view zoomByFactor:0.85];
    [view zoomByFactor:0.85];
    assert(view.fitMode == SPDFMacMarkdownPageFitCustom);
    pageFrame = [canvas frameForPageAtIndex:0];
    assert(NSMinY(pageFrame) > 10.0);  // clearly floated off the top
    assert(fabs(NSMidY(pageFrame) - NSMidY(view.contentView.bounds)) < 1.0);
    assert(fabs(NSMidX(pageFrame) - NSMidX(view.contentView.bounds)) < 1.0);
    assert(!view.hasVerticalScroller);
    // Attempted scrolls stay centered; the clip view clamps the wheel/elastic
    // paths back too (min==max vertical lock, mirroring the horizontal lock).
    [view scrollByDocumentDeltaX:0.0 deltaY:250.0];
    assert(fabs(NSMidY([canvas frameForPageAtIndex:0]) - NSMidY(view.contentView.bounds)) < 1.0);
    NSRect proposed = view.contentView.bounds;
    proposed.origin.y = 120.0;
    assert(fabs(NSMinY([view.contentView constrainBoundsRect:proposed])) <= 0.5);
    assert(view.verticalScrollElasticity == NSScrollElasticityNone);

    // --- Multi-page documents keep the scroller and stay scrollable ---
    [multiPageView applyFitMode:SPDFMacMarkdownPageFitPage];
    SPDFMacMarkdownPageCanvas* multiCanvas = (SPDFMacMarkdownPageCanvas*)multiPageView.documentView;
    NSRect firstPage = [multiCanvas frameForPageAtIndex:0];
    // Exact fit holds page-wise: page top at the viewport top, height exact.
    assert(NSMinY(firstPage) <= 0.5);
    assert(fabs(NSHeight(firstPage) * multiPageView.magnification - multiPageView.contentSize.height) <= 0.5);
    assert(multiPageView.documentCanvasSize.height >
           NSHeight(multiPageView.contentView.bounds) + 0.5);  // still scrollable
    assert(multiPageView.hasVerticalScroller);
    assert(multiPageView.verticalScrollElasticity == NSScrollElasticityAllowed);
    // The fit placed the CURRENT page flush in the viewport; if that was the last
    // page there is nothing below it to scroll to, so start from the top.
    [multiPageView goToPageAtIndex:0 alignTop:YES];
    NSPoint beforeScroll = multiPageView.documentVisibleRect.origin;
    [multiPageView scrollByDocumentDeltaX:0.0 deltaY:200.0];
    assert(multiPageView.documentVisibleRect.origin.y > beforeScroll.y + 100.0);

    // --- A fit is not only a zoom: the CURRENT page is then placed in the
    // viewport the way a one-page document's sheet is. Land on page 2, drag it
    // so it straddles the viewport, and re-apply each fit. ---
    assert(multiPageView.pageCount >= 3);
    [multiPageView goToPageAtIndex:2 alignTop:YES];
    [multiPageView scrollByDocumentDeltaX:0.0 deltaY:150.0];  // a slice of page 1 shows above
    NSRect page2 = [multiCanvas frameForPageAtIndex:2];
    assert(multiPageView.documentVisibleRect.origin.y > NSMinY(page2) + 50.0);  // genuinely straddling
    // Fit Page: page 2's top flush with the viewport top (exact height), centered horizontally.
    [multiPageView applyFitMode:SPDFMacMarkdownPageFitPage];
    page2 = [multiCanvas frameForPageAtIndex:2];
    assert(fabs(NSMinY(multiPageView.documentVisibleRect) - NSMinY(page2)) <= 0.5);
    assert(fabs(NSMidX(multiPageView.documentVisibleRect) - NSMidX(page2)) <= 1.0);
    assert(multiPageView.currentPageIndex == 2);
    // STEPPING to a page at Fit Page must land flush too, not 12pt below the
    // top: the breathing room belongs to a page taller than the viewport. This
    // path subtracted 12 unconditionally, so every stepped-to sheet showed a
    // strip of canvas above it while the PDF view, sharing the same rule, did not.
    [multiPageView goToPageAtIndex:1 alignTop:YES];
    NSRect page1 = [multiCanvas frameForPageAtIndex:1];
    assert(fabs(NSMinY(multiPageView.documentVisibleRect) - NSMinY(page1)) <= 0.5);
    [multiPageView goToPageAtIndex:2 alignTop:YES];
    page2 = [multiCanvas frameForPageAtIndex:2];
    assert(fabs(NSMinY(multiPageView.documentVisibleRect) - NSMinY(page2)) <= 0.5);
    [multiPageView applyFitMode:SPDFMacMarkdownPageFitPage];
    // Fit Height: same alignment, page height exact.
    [multiPageView scrollByDocumentDeltaX:0.0 deltaY:120.0];
    [multiPageView applyFitMode:SPDFMacMarkdownPageFitHeight];
    page2 = [multiCanvas frameForPageAtIndex:2];
    assert(fabs(NSMinY(multiPageView.documentVisibleRect) - NSMinY(page2)) <= 0.5);
    assert(fabs(NSHeight(page2) * multiPageView.magnification - multiPageView.contentSize.height) <= 0.5);
    // Fit Width: the page is taller than the viewport, so it starts at its top.
    [multiPageView scrollByDocumentDeltaX:0.0 deltaY:120.0];
    [multiPageView applyFitMode:SPDFMacMarkdownPageFitWidth];
    page2 = [multiCanvas frameForPageAtIndex:2];
    assert(fabs(NSMinY(multiPageView.documentVisibleRect) - NSMinY(page2)) <= 0.5);
    assert(fabs(NSWidth(page2) * multiPageView.magnification - multiPageView.contentSize.width) <= 0.5);

    // --- The PDF path's fitted scroll origin, shared pure geometry ---
    assert(spdf_mac_fit_scroll_origin_y(1226.0, 600.0, 600.0, 12.0) == 1226.0);  // exact fit: flush, no strip
    assert(spdf_mac_fit_scroll_origin_y(1226.0, 400.0, 600.0, 12.0) == 1126.0);  // shorter page: centered
    assert(spdf_mac_fit_scroll_origin_y(1226.0, 900.0, 600.0, 12.0) == 1214.0);  // taller page: breathing room
    assert(spdf_mac_fit_scroll_origin_y(0.0, 900.0, 600.0, 12.0) == 0.0);        // never above the canvas
}

// Focused Markdown test executables do not link the complete app UI helpers.
// This minimal implementation supplies the shared superclass while production
// builds use SPDFMacUIHelpers.mm.
static NSMapTable<SPDFScrollView*, id<SPDFMacUIReader>>* TestScrollViewReaders(void) {
    static NSMapTable<SPDFScrollView*, id<SPDFMacUIReader>>* readers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      readers = [NSMapTable weakToWeakObjectsMapTable];
    });
    return readers;
}

@implementation SPDFScrollView
- (id<SPDFMacUIReader>)reader {
    return [TestScrollViewReaders() objectForKey:self];
}
- (void)setReader:(id<SPDFMacUIReader>)reader {
    if (reader)
        [TestScrollViewReaders() setObject:reader forKey:self];
    else
        [TestScrollViewReaders() removeObjectForKey:self];
}
@end

// The production marker drawing lives in SPDFMacUIHelpers.mm; focused test
// executables only need the class and its reader wiring to exist.
@implementation SPDFFindMarkerScroller {
    __weak id<SPDFMacUIReader> _testReader;
}
- (id<SPDFMacUIReader>)reader {
    return _testReader;
}
- (void)setReader:(id<SPDFMacUIReader>)reader {
    _testReader = reader;
}
@end

// Same clamp behavior as the production SPDFDocumentClipView in
// SPDFMacUIHelpers.mm, which these focused executables do not link.
@implementation SPDFDocumentClipView

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        _horizontalLockMinX = NAN;
        _horizontalLockMaxX = NAN;
        _verticalLockMinY = NAN;
        _verticalLockMaxY = NAN;
    }
    return self;
}

- (NSRect)constrainBoundsRect:(NSRect)proposedBounds {
    NSRect bounds = [super constrainBoundsRect:proposedBounds];
    if (isfinite(_horizontalLockMinX))
        bounds.origin.x = MAX(_horizontalLockMinX, MIN(bounds.origin.x, MAX(_horizontalLockMinX, _horizontalLockMaxX)));
    if (isfinite(_verticalLockMinY))
        bounds.origin.y = MAX(_verticalLockMinY, MIN(bounds.origin.y, MAX(_verticalLockMinY, _verticalLockMaxY)));
    return bounds;
}

@end
