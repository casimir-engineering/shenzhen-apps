#import "SPDFMacMarkdownPagedViewPrivate.h"

// Exact-viewport fit, and what follows it.
//
// A fit is two things on this view: the magnification a mode means against
// the raw viewport, and the placing of the CURRENT page once that zoom is in --
// the page centered where it is smaller than the viewport, flush with its top
// where it is taller, exactly as a one-page document's sheet sits and as the
// PDF view places a fitted page. Split from SPDFMacMarkdownPagedView.mm, which
// keeps the scroll-view plumbing, so the fit rules read on their own.

@implementation SPDFMacMarkdownPagedView (Fit)

// Exact-viewport fit (PDF parity): fits are computed against the raw viewport
// with no decorative inset — Fit Width fills the viewport width exactly and
// Fit Page makes the page height equal the viewport height exactly, page top
// at the viewport top (the canvas inset collapses at exact fit, see
// SPDFMacMarkdownPageCanvas's layoutViewportSize).
- (CGFloat)zoomForFitMode:(SPDFMacMarkdownPageFitMode)fitMode {
    NSSize viewport = self.contentSize;
    NSSize paper = _plan.configuration.paperSize;
    CGFloat width = MAX(1, viewport.width) / paper.width;
    CGFloat height = MAX(1, viewport.height) / paper.height;
    if (fitMode == SPDFMacMarkdownPageFitWidth) return width;
    if (fitMode == SPDFMacMarkdownPageFitHeight) return height;
    if (fitMode == SPDFMacMarkdownPageFitPage) return MIN(width, height);
    if (fitMode == SPDFMacMarkdownPageFitActual) return 1.0;
    return self.magnification;
}

- (void)applyFitMode:(SPDFMacMarkdownPageFitMode)fitMode {
    _fitMode = fitMode;
    // Two passes, PDF parity with the tab-switch fit reconciliation: applying a
    // fit can show/hide the vertical scroller, which (with legacy scrollers)
    // changes the viewport the fit was computed against. The second pass
    // recomputes against the settled viewport so the fit stays exact.
    for (int pass = 0; pass < 2; ++pass) {
        CGFloat zoom = MAX(kSPDFMarkdownMinimumZoom, MIN(kSPDFMarkdownMaximumZoom, [self zoomForFitMode:fitMode]));
        if (pass > 0 && fabs(zoom - self.magnification) < 0.0001) break;
        NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)MAX(0, _currentPageIndex)];
        [self setMagnification:zoom centeredAtPoint:NSMakePoint(NSMidX(page), NSMidY(page))];
        _fitMode = fitMode;
        [self updateCanvasGeometryPreservingCenter:YES];
    }
    if (fitMode != SPDFMacMarkdownPageFitCustom && fitMode != SPDFMacMarkdownPageFitActual)
        [self alignCurrentPageAfterFit];
    [self viewportDidChange:nil];
}

// A fit is not only a zoom. As on the PDF path -- and as in a one-page document,
// whose canvas centers its only sheet -- the current page then sits IN the
// viewport: centered on every axis where it is smaller than the viewport, and
// flush with its top or left edge on an axis where it is taller or wider (Fit
// Width's tall page starts at its top). Before this, the fit only kept whatever
// point of the page happened to be under the viewport's center, so Fit Page
// could leave the sheet straddling two viewports with a slice of its neighbour
// showing, and Fit Height could land a page anywhere along its height. All
// math is in canvas coordinates, the space of the clip view's bounds.
- (void)alignCurrentPageAfterFit {
    if (!self.pageCount) return;
    NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)MAX(0, _currentPageIndex)];
    NSRect bounds = self.contentView.bounds;
    NSSize canvas = _canvas.frame.size;
    NSPoint origin;
    origin.x = NSWidth(page) <= NSWidth(bounds) + 0.5 ? NSMidX(page) - NSWidth(bounds) / 2.0 : NSMinX(page);
    origin.y = NSHeight(page) <= NSHeight(bounds) + 0.5 ? NSMidY(page) - NSHeight(bounds) / 2.0 : NSMinY(page);
    origin.x = MAX(0.0, MIN(origin.x, MAX(0.0, canvas.width - NSWidth(bounds))));
    origin.y = MAX(0.0, MIN(origin.y, MAX(0.0, canvas.height - NSHeight(bounds))));
    [self.contentView scrollToPoint:origin];
    [self reflectScrolledClipView:self.contentView];
}

@end
