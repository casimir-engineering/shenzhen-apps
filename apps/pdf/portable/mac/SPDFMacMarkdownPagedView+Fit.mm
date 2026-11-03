#import "SPDFMacMarkdownPagedViewPrivate.h"

// Exact-viewport fit, and what follows it.
//
// A fit is two things on this view: the magnification a mode means against
// the raw viewport, and where the view sits once that zoom is in. Fit Page and
// Fit Height place the CURRENT page -- centered where it is smaller than the
// viewport, flush with its top where it is taller, exactly as a one-page
// document's sheet sits and as the PDF view places a fitted page. Fit Width and
// 100% keep the reading position, as the PDF view does. Split from
// SPDFMacMarkdownPagedView.mm, which keeps the scroll-view plumbing, so the fit
// rules read on their own.

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
    // Fit Page and Fit Height show the whole current page. Fit Width and 100% keep the reading position: the point
    // of the page under the viewport's centre stays under its centre, as Zoom In and Zoom Out keep it (PDF parity,
    // applyFitModeKeepingPosition:). Before, Fit Width always went to the top of the current page.
    BOOL wholePage = fitMode == SPDFMacMarkdownPageFitPage || fitMode == SPDFMacMarkdownPageFitHeight;
    NSPoint anchorFraction = NSZeroPoint;
    NSInteger anchorPage = wholePage ? -1 : [self pageAtViewportCenter:&anchorFraction];
    // Two passes, PDF parity with the tab-switch fit reconciliation: applying a
    // fit can show/hide the vertical scroller, which (with legacy scrollers)
    // changes the viewport the fit was computed against. The second pass
    // recomputes against the settled viewport so the fit stays exact.
    for (int pass = 0; pass < 2; ++pass) {
        CGFloat zoom = MAX(kSPDFMarkdownMinimumZoom, MIN(kSPDFMarkdownMaximumZoom, [self zoomForFitMode:fitMode]));
        if (pass > 0 && fabs(zoom - self.magnification) < 0.0001) break;
        NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)MAX(0, _currentPageIndex)];
        NSRect bounds = self.contentView.bounds;
        [self setMagnification:zoom
               centeredAtPoint:wholePage ? NSMakePoint(NSMidX(page), NSMidY(page))
                                         : NSMakePoint(NSMidX(bounds), NSMidY(bounds))];
        _fitMode = fitMode;
        [self updateCanvasGeometryPreservingCenter:YES];
    }
    if (wholePage)
        [self alignCurrentPageAfterFit];
    else if (anchorPage >= 0)
        [self centerViewportOnPage:anchorPage fraction:anchorFraction];
    [self viewportDidChange:nil];
}

// The page under the viewport's centre, and where on it the centre is as a share of the page's size (a centre in
// the gap between two pages counts as the nearer page's edge). -1 without pages. Canvas coordinates throughout.
- (NSInteger)pageAtViewportCenter:(NSPoint*)fraction {
    NSUInteger count = self.pageCount;
    if (!count) return -1;
    NSRect bounds = self.contentView.bounds;
    NSPoint center = NSMakePoint(NSMidX(bounds), NSMidY(bounds));
    NSUInteger best = self.presentationMode ? (NSUInteger)MAX(0, MIN(_currentPageIndex, (NSInteger)count - 1)) : 0;
    CGFloat bestDistance = self.presentationMode ? 0.0 : CGFLOAT_MAX;  // presenting: the presented page
    for (NSUInteger i = 0; i < count && bestDistance > 0.0; ++i) {
        NSRect page = [_canvas frameForPageAtIndex:i];
        CGFloat distance = MAX(0.0, MAX(NSMinY(page) - center.y, center.y - NSMaxY(page)));
        if (distance < bestDistance) bestDistance = distance, best = i;
    }
    NSRect page = [_canvas frameForPageAtIndex:best];
    fraction->x = MAX(0.0, MIN(1.0, (center.x - NSMinX(page)) / MAX(1.0, NSWidth(page))));
    fraction->y = MAX(0.0, MIN(1.0, (center.y - NSMinY(page)) / MAX(1.0, NSHeight(page))));
    return (NSInteger)best;
}

// Puts that point of the page back under the viewport's centre once the pages are laid out at the new zoom; a page
// no wider than the viewport stays centred across it.
- (void)centerViewportOnPage:(NSInteger)pageIndex fraction:(NSPoint)fraction {
    if (pageIndex < 0 || (NSUInteger)pageIndex >= self.pageCount) return;
    NSRect page = [_canvas frameForPageAtIndex:(NSUInteger)pageIndex];
    NSRect bounds = self.contentView.bounds;
    NSSize canvas = _canvas.frame.size;
    NSPoint origin;
    origin.x = NSWidth(page) <= NSWidth(bounds) + 0.5 ? NSMidX(page) - NSWidth(bounds) / 2.0
                                                       : NSMinX(page) + NSWidth(page) * fraction.x - NSWidth(bounds) / 2.0;
    origin.y = NSMinY(page) + NSHeight(page) * fraction.y - NSHeight(bounds) / 2.0;
    origin.x = MAX(0.0, MIN(origin.x, MAX(0.0, canvas.width - NSWidth(bounds))));
    origin.y = MAX(0.0, MIN(origin.y, MAX(0.0, canvas.height - NSHeight(bounds))));
    [self.contentView scrollToPoint:origin];
    [self reflectScrolledClipView:self.contentView];
}

// Fit Page and Fit Height are not only a zoom. As on the PDF path -- and as in a
// one-page document, whose canvas centers its only sheet -- the current page
// then sits IN the viewport: centered on every axis where it is smaller than
// the viewport, and flush with its top or left edge on an axis where it is
// taller or wider. Keeping only the point under the viewport's center, Fit Page
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
