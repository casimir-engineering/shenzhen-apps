#pragma once

#import <Foundation/Foundation.h>

// Shared exact-fit canvas geometry for the PDF and Markdown document views.
//
// Exact-viewport convention: the fit zooms are computed against the raw clip
// size (no decorative insets), so Fit Width fills the viewport width exactly
// and Fit Page makes the page height equal the viewport height exactly. For
// that to hold on screen the decorative canvas chrome (the outer margin above
// the first and below the last page) must not force scrollability at exact
// fit, so the outer vertical inset collapses as the tallest page approaches
// the viewport height:
//
//   - pages much shorter than the viewport keep the full decorative inset
//     (multi-page documents stay top-anchored exactly as before);
//   - within one inset of exact fit the margin shrinks continuously;
//   - at and beyond exact fit it is 0, so the fit page's top sits at the
//     viewport top and a single fit page is not scrollable at all;
//   - a SINGLE-page document shorter than the viewport is vertically CENTERED
//     (the inset grows past the decorative value to split the leftover space),
//     mirroring the horizontal center lock's fits-horizontally behavior.
//
// Pure function so the convention is unit-testable headlessly for both views.
static inline CGFloat spdf_mac_vertical_canvas_inset(NSUInteger pageCount,
                                                     CGFloat tallestPageHeight,
                                                     CGFloat viewportHeight,
                                                     CGFloat decorativeInset) {
    if (pageCount == 0 || viewportHeight <= 1.0) return decorativeInset;  // viewport unknown: keep the chrome
    CGFloat centered = (viewportHeight - tallestPageHeight) / 2.0;
    if (pageCount == 1) return MAX(0.0, centered);
    return MAX(0.0, MIN(decorativeInset, centered));
}

// Where the viewport's top goes when a page is brought in by a fit or a page
// step. A page that fits the viewport vertically is CENTERED on it -- which,
// at exact fit, puts its top flush with the viewport's top, so no gutter shows
// above or below a Fit Page / Fit Height sheet on any page of the document. A
// page taller than the viewport keeps the small breathing room above its top
// that page stepping has always had. Before this the breathing room applied to
// every page, so Fit Page on page 2 of a PDF showed a 12pt strip of the gutter
// above the sheet ("black on top") while page 1, whose canvas inset had
// collapsed to 0, did not.
static inline CGFloat spdf_mac_fit_scroll_origin_y(CGFloat pageMinY,
                                                        CGFloat pageHeight,
                                                        CGFloat viewportHeight,
                                                        CGFloat breathingRoom) {
    if (pageHeight <= viewportHeight + 0.5) return MAX(0.0, pageMinY - (viewportHeight - pageHeight) / 2.0);
    return MAX(0.0, pageMinY - breathingRoom);
}

// Horizontal mirror for the near-fit band: the side margin beside a page keeps
// its decorative value while there is room, shrinks continuously once the
// widest page is within one margin of the viewport width, and reaches 0 at
// exact fit — so Fit Width/Fit Page never gain a horizontal scroller (or a
// vertically-shrunken clip) from decoration alone.
static inline CGFloat spdf_mac_horizontal_canvas_margin(CGFloat widestPageWidth,
                                                        CGFloat viewportWidth,
                                                        CGFloat decorativeMargin) {
    return MAX(0.0, MIN(decorativeMargin, viewportWidth - widestPageWidth));
}
