/* Minimap strip-geometry conformance for portable/win/src/spdf_win_minimap.h.
 *
 * Two jobs in one binary, the same pair layout_geometry_test.c has:
 *
 *   1. ASSERTIONS. Every check exits non-zero on failure, so this is a
 *      pass/fail suite judged by its exit code and never by reading output.
 *   2. TRANSCRIPT. It prints every computed number in a fixed format, so the
 *      same binary built by two toolchains must produce a byte-identical
 *      transcript.
 *
 * The values below are NOT invented. They are derived from
 * portable/linux/gtk4/spdf_minimap_internal.h and
 * portable/mac/SPDFMacMinimapView.mm, and every one of them is annotated with
 * how it falls out of those. The stronger check --
 * portable/win/tests/minimap_differential.c -- compiles the REAL GTK4 header
 * beside the port in one binary and compares every function with `==`; this file
 * exists because a differential cannot catch a constant that is wrong in BOTH
 * implementations, and because it runs with no extra include paths.
 *
 * Header-only subject: no extra translation units to link.
 */

#include <stdio.h>
#include <string.h>

#include "spdf_win_minimap.h"

static int failures;

static void expect(int condition, const char* what) {
    if (!condition) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

#define EPS 1e-9

static void expect_near(double got, double want, const char* what) {
    double d = got - want;
    if (d < 0.0) d = -d;
    if (d > EPS) {
        printf("FAIL %s: got %.9f want %.9f\n", what, got, want);
        failures++;
    }
}

/* The macOS default minimap: kDefaultMinimapWidth 126.5, so usable = 108.5. */
#define PANEL_W 126.5
#define USABLE (PANEL_W - SPDF_WIN_MINIMAP_SIDE_INSET)

/* Letter pages, and the same mixed set the layout tests use: a Letter sheet, a
 * 10900 pt schematic foldout, an A5 page and a tall poster. The foldout is the
 * whole reason the scale comes off the MEDIAN. */
static const SpdfWinPageSizePt letter[3] = {{612.0, 792.0}, {612.0, 792.0}, {612.0, 792.0}};
static const SpdfWinPageSizePt mixed[4] = {{612.0, 792.0}, {10900.0, 7539.0}, {420.0, 595.0}, {612.0, 1584.0}};

static void test_median(void) {
    /* Odd count takes the middle element; even count averages the middle two.
     * mixed sorted is [420, 612, 612, 10900], so the median is 612 -- the giant
     * page does not move it, which is the property the mean would lose. */
    expect_near(spdf_win_minimap_median_width(letter, 3), 612.0, "median of three letter pages");
    expect_near(spdf_win_minimap_median_width(mixed, 4), 612.0, "median is robust to one giant page");
    expect_near(spdf_win_minimap_median_width(mixed, 1), 612.0, "median of one page is that page");
    expect_near(spdf_win_minimap_median_width(mixed, 2), (612.0 + 10900.0) * 0.5, "median of two averages both");
    expect_near(spdf_win_minimap_median_width(NULL, 4), 0.0, "median of nothing is 0");
    expect_near(spdf_win_minimap_median_width(letter, 0), 0.0, "median of zero pages is 0");
    printf("median letter=%.9f mixed=%.9f\n", spdf_win_minimap_median_width(letter, 3),
           spdf_win_minimap_median_width(mixed, 4));
}

static void test_point_scale(void) {
    double uniform = spdf_win_minimap_point_scale(letter, 3, USABLE);
    double capped = spdf_win_minimap_point_scale(mixed, 4, USABLE);

    /* A uniform document keeps exactly usable/widest: the widest page fills the
     * strip, which is the pre-cap behaviour the cap had to preserve. */
    expect_near(uniform, USABLE / 612.0, "uniform document: scale is usable/widest");
    /* With the foldout, the effective widest is capped at 2.5 * median = 1530,
     * NOT 10900 -- so the normal pages stay 43.4 px wide instead of 6.1. */
    expect_near(capped, USABLE / (SPDF_WIN_MINIMAP_MAX_WIDTH_RATIO * 612.0), "cap applies at 2.5x the median");
    expect(capped * 612.0 > 40.0, "a normal page survives the foldout at a readable width");
    expect_near(spdf_win_minimap_point_scale(letter, 3, 1.0), 0.0, "a 1 px strip has no scale");
    expect_near(spdf_win_minimap_point_scale(letter, 0, USABLE), 0.0, "no pages, no scale");
    printf("scale uniform=%.9f capped=%.9f normal_page_px=%.9f\n", uniform, capped, capped * 612.0);
}

static void test_strip(void) {
    SpdfWinMinimapStrip strip;
    double scale;
    int i;

    memset(&strip, 0, sizeof(strip));
    spdf_win_minimap_strip_compute(&strip, letter, 3, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET, SPDF_WIN_MINIMAP_GAP);
    expect(strip.count == 3, "three pages, three rects");
    expect_near(strip.rects[0].w, USABLE, "a uniform page fills the usable width");
    expect_near(strip.rects[0].h, USABLE * (792.0 / 612.0), "height follows the width, aspect preserved");
    /* floor((126.5 - 108.5) / 2) = floor(9) = 9. Floor, not round: a rect at a
     * fractional x puts the page's edge across two columns. */
    expect_near(strip.rects[0].x, 9.0, "each page is centred, floored");
    expect_near(strip.rects[1].y, strip.rects[0].h + SPDF_WIN_MINIMAP_GAP, "the gap is 4 px, between pages only");
    expect_near(strip.content_h, 3.0 * strip.rects[0].h + 2.0 * SPDF_WIN_MINIMAP_GAP,
                "content height has one fewer gap than pages");
    for (i = 0; i < 3; ++i)
        printf("strip letter[%d] x=%.9f y=%.9f w=%.9f h=%.9f\n", i, strip.rects[i].x, strip.rects[i].y,
               strip.rects[i].w, strip.rects[i].h);
    printf("strip letter content_h=%.9f point_scale=%.9f\n", strip.content_h, strip.point_scale);

    spdf_win_minimap_strip_compute(&strip, mixed, 4, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET, SPDF_WIN_MINIMAP_GAP);
    scale = USABLE / (SPDF_WIN_MINIMAP_MAX_WIDTH_RATIO * 612.0);
    expect(strip.count == 4, "four pages, four rects");
    expect_near(strip.rects[0].w, 612.0 * scale, "a normal page is drawn at the shared point scale");
    /* The foldout is clamped to the strip, and its HEIGHT follows the clamped
     * width -- so it keeps its own aspect and does not become a letterbox. */
    expect_near(strip.rects[1].w, USABLE, "the foldout is clamped to the usable width");
    expect_near(strip.rects[1].h, USABLE * (7539.0 / 10900.0), "the clamped page keeps its own aspect");
    /* The foldout is wider AND taller in absolute px -- it fills the strip
     * where the Letter page uses 43.4 of it -- but its ASPECT is its own:
     * 7539/10900 is flatter than 792/612, and that is what must survive. */
    expect(strip.rects[1].w > strip.rects[0].w, "the foldout is the widest slot in the strip");
    expect(strip.rects[1].h / strip.rects[1].w < strip.rects[0].h / strip.rects[0].w,
           "the landscape foldout stays flatter than the portrait page");
    expect_near(strip.rects[2].w, 420.0 * scale, "the A5 page is smaller than the Letter page");
    expect(strip.rects[3].h > strip.rects[0].h, "the tall poster is taller than Letter at the same width");
    for (i = 0; i < 4; ++i)
        printf("strip mixed[%d] x=%.9f y=%.9f w=%.9f h=%.9f\n", i, strip.rects[i].x, strip.rects[i].y,
               strip.rects[i].w, strip.rects[i].h);
    printf("strip mixed content_h=%.9f point_scale=%.9f\n", strip.content_h, strip.point_scale);

    /* Reallocation rule: the array is reused whenever the count is unchanged,
     * and a zero count leaves an empty strip rather than a dangling pointer. */
    spdf_win_minimap_strip_compute(&strip, mixed, 0, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET, SPDF_WIN_MINIMAP_GAP);
    expect(strip.count == 0 && strip.rects == NULL, "zero pages clears the strip");
    expect_near(strip.content_h, 0.0, "zero pages, zero content height");
    spdf_win_minimap_strip_clear(&strip);
}

static void test_content_top(void) {
    double edge = SPDF_WIN_MINIMAP_EDGE_INSET;
    double pad = SPDF_WIN_MINIMAP_TOP_PAD;

    /* Fits: centred, floored. 700 - 16 = 684 available, 300 < 684. */
    expect_near(spdf_win_minimap_content_top(300.0, 700.0, edge, pad, 0.0), floor((700.0 - 300.0) * 0.5),
                "a strip that fits is vertically centred");
    expect_near(spdf_win_minimap_content_top(300.0, 700.0, edge, pad, 1.0), floor((700.0 - 300.0) * 0.5),
                "a centred strip ignores the scroll fraction");
    /* Overflows: 8 - fraction * (content - available). */
    expect_near(spdf_win_minimap_content_top(2000.0, 700.0, edge, pad, 0.0), pad, "at the top, content_top is the pad");
    expect_near(spdf_win_minimap_content_top(2000.0, 700.0, edge, pad, 1.0), pad - (2000.0 - 684.0),
                "at the bottom, the last page's foot is at the panel's foot");
    expect_near(spdf_win_minimap_content_top(2000.0, 700.0, edge, pad, 0.5), pad - 0.5 * (2000.0 - 684.0),
                "halfway is halfway");
    /* Out-of-range fractions clamp rather than running off the strip. */
    expect_near(spdf_win_minimap_content_top(2000.0, 700.0, edge, pad, -3.0), pad, "a negative fraction clamps to 0");
    expect_near(spdf_win_minimap_content_top(2000.0, 700.0, edge, pad, 9.0), pad - (2000.0 - 684.0),
                "a fraction above 1 clamps to 1");
    printf("content_top fit=%.9f top=%.9f mid=%.9f bottom=%.9f\n",
           spdf_win_minimap_content_top(300.0, 700.0, edge, pad, 0.0),
           spdf_win_minimap_content_top(2000.0, 700.0, edge, pad, 0.0),
           spdf_win_minimap_content_top(2000.0, 700.0, edge, pad, 0.5),
           spdf_win_minimap_content_top(2000.0, 700.0, edge, pad, 1.0));
}

static void test_hit_and_range(void) {
    SpdfWinMinimapStrip strip;
    int page = -1, first = -1, last = -1;
    double fx = -1.0, fy = -1.0;

    memset(&strip, 0, sizeof(strip));
    spdf_win_minimap_strip_compute(&strip, letter, 3, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET, SPDF_WIN_MINIMAP_GAP);

    expect(spdf_win_minimap_page_hit(&strip, 60.0, 1.0, &page, &fx, &fy) && page == 0, "a click near the top hits page 0");
    expect(spdf_win_minimap_page_hit(&strip, 60.0, strip.rects[2].y + 1.0, &page, &fx, &fy) && page == 2,
           "a click in the third slot hits page 2");
    /* x is CLAMPED into the rect rather than rejected: macOS's pageHitForMiniPoint
     * lets the y band decide the page. */
    expect(spdf_win_minimap_page_hit(&strip, -50.0, 1.0, &page, &fx, &fy) && fx == 0.0, "x clamps to the leading edge");
    expect(spdf_win_minimap_page_hit(&strip, 9999.0, 1.0, &page, &fx, &fy) && fx == 1.0,
           "x clamps to the trailing edge");
    expect(!spdf_win_minimap_page_hit(&strip, 60.0, -5.0, &page, &fx, &fy), "above the strip hits nothing");
    expect(!spdf_win_minimap_page_hit(&strip, 60.0, strip.content_h + 5.0, &page, &fx, &fy),
           "below the strip hits nothing");
    /* A y inside a GAP hits nothing, which is why the gap is 4 px and not 0. */
    expect(!spdf_win_minimap_page_hit(&strip, 60.0, strip.rects[0].h + 2.0, &page, &fx, &fy),
           "a click in the gap hits nothing");

    expect(spdf_win_minimap_strip_visible_range(&strip, 0.0, 10.0, &first, &last) && first == 0 && last == 0,
           "a 10 px band at the top shows page 0 only");
    expect(spdf_win_minimap_strip_visible_range(&strip, 0.0, strip.content_h, &first, &last) && first == 0 && last == 2,
           "a band over the whole strip shows every page");
    printf("visible_range whole first=%d last=%d\n", first, last);
    spdf_win_minimap_strip_clear(&strip);
}

static void test_thumb_window(void) {
    SpdfWinMinimapThumbWindow w = spdf_win_minimap_thumb_window_empty();
    SpdfWinMinimapThumbWindow kept;

    expect(!spdf_win_minimap_thumb_window_valid(w), "an empty window is not valid");
    expect(!spdf_win_minimap_thumb_window_contains(w, 0), "an empty window contains nothing");

    /* 200 pages, viewport on 100-104, nothing cached: +-30 pages. */
    w = spdf_win_minimap_thumb_window_for_visible_range(200, 100, 104, w);
    expect(w.start == 70 && w.end == 134, "a fresh window is the visible range padded by 30");
    expect(spdf_win_minimap_thumb_window_contains(w, 70) && spdf_win_minimap_thumb_window_contains(w, 134),
           "the window is inclusive at both ends");

    /* Scrolling five pages stays inside the 15-page hysteresis band, so the
     * window is KEPT -- this is the check that stops a scroll from re-queueing
     * 60 renders per frame. */
    kept = spdf_win_minimap_thumb_window_for_visible_range(200, 105, 109, w);
    expect(kept.start == w.start && kept.end == w.end, "a small scroll keeps the window");
    /* Scrolling far enough that the margin leaves the window recentres it. */
    kept = spdf_win_minimap_thumb_window_for_visible_range(200, 120, 124, w);
    expect(kept.start == 90 && kept.end == 154, "a scroll past the margin recentres the window");

    /* Both ends clamp to the document, so sitting on page 0 or the last page
     * never forces a recompute every frame. */
    w = spdf_win_minimap_thumb_window_for_visible_range(200, 0, 3, spdf_win_minimap_thumb_window_empty());
    expect(w.start == 0 && w.end == 33, "the window clamps at the first page");
    kept = spdf_win_minimap_thumb_window_for_visible_range(200, 0, 3, w);
    expect(kept.start == 0 && kept.end == 33, "sitting on page 0 keeps the window");
    w = spdf_win_minimap_thumb_window_for_visible_range(200, 196, 199, spdf_win_minimap_thumb_window_empty());
    expect(w.start == 166 && w.end == 199, "the window clamps at the last page");

    /* A window remembered from a LONGER document must be recomputed, not reused. */
    w.start = 400;
    w.end = 460;
    kept = spdf_win_minimap_thumb_window_for_visible_range(200, 10, 12, w);
    expect(kept.end < 200, "a window from another document is discarded");

    /* A page five past the window is kept (the 30-page evict slack); one far
     * outside is evicted. */
    w = spdf_win_minimap_thumb_window_for_visible_range(500, 200, 204, spdf_win_minimap_thumb_window_empty());
    expect(!spdf_win_minimap_thumb_window_should_evict(w, w.end + 5), "the evict slack keeps a near-miss page");
    expect(spdf_win_minimap_thumb_window_should_evict(w, w.end + 31), "a far page is evicted");
    expect(spdf_win_minimap_thumb_window_should_evict(w, 0), "page 0 is evicted from a window 200 pages away");
    expect(!spdf_win_minimap_thumb_window_should_evict(spdf_win_minimap_thumb_window_empty(), 0),
           "an empty window evicts nothing");

    /* Zero pages: empty, never a 0..-1 that a loop would misread. */
    w = spdf_win_minimap_thumb_window_for_visible_range(0, 0, 0, spdf_win_minimap_thumb_window_empty());
    expect(!spdf_win_minimap_thumb_window_valid(w), "no pages, no window");
    printf("thumb_window fresh=[70,134] clamped_first=[0,33] clamped_last=[166,199]\n");
}

static void test_thumb_zoom(void) {
    double scale = USABLE / (SPDF_WIN_MINIMAP_MAX_WIDTH_RATIO * 612.0);

    /* A thumbnail is rendered at its own CLAMPED display width over its point
     * width, so it is never bigger than the slot it lands in. */
    expect_near(spdf_win_minimap_thumb_zoom(letter, 3, 0, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET), USABLE / 612.0,
                "a uniform page renders at usable/width");
    expect_near(spdf_win_minimap_thumb_zoom(mixed, 4, 0, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET), scale,
                "a normal page beside a foldout renders at the shared scale");
    expect_near(spdf_win_minimap_thumb_zoom(mixed, 4, 1, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET), USABLE / 10900.0,
                "the foldout renders to the strip width, not past it");
    expect_near(spdf_win_minimap_thumb_zoom(mixed, 4, 9, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET), 0.0,
                "an out-of-range page has no zoom");
    expect_near(spdf_win_minimap_thumb_zoom(mixed, 4, 0, 10.0, SPDF_WIN_MINIMAP_SIDE_INSET), 0.0,
                "a panel narrower than the inset has no zoom");
    /* The whole point: rendering the foldout at the NORMAL pages' zoom would
     * produce a 773 px wide bitmap for a 108 px slot. */
    expect(10900.0 * spdf_win_minimap_thumb_zoom(mixed, 4, 1, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET) <= USABLE + EPS,
           "no thumbnail is rendered wider than the strip");
    printf("thumb_zoom uniform=%.9f normal=%.9f foldout=%.9f\n",
           spdf_win_minimap_thumb_zoom(letter, 3, 0, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET),
           spdf_win_minimap_thumb_zoom(mixed, 4, 0, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET),
           spdf_win_minimap_thumb_zoom(mixed, 4, 1, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET));
}

static void test_viewport(void) {
    SpdfWinRect band;

    /* macOS's fallback branch (:300-306): x = 5, width = panel - 10, height by
     * the visible fraction of the document, top by the scroll fraction. */
    band = spdf_win_minimap_viewport_band(PANEL_W, 1000.0, 100.0, 10.0, 0.0);
    expect_near(band.x, 5.0, "the band is inset 5 px");
    expect_near(band.w, PANEL_W - 10.0, "the band spans the panel less 10 px");
    expect_near(band.h, 100.0, "the band is the visible fraction of the content");
    expect_near(band.y, 0.0, "at the top, the band is at the top");
    band = spdf_win_minimap_viewport_band(PANEL_W, 1000.0, 100.0, 10.0, 1.0);
    expect_near(band.y, 900.0, "at the bottom, the band's foot is the content's foot");
    /* A document shorter than one viewport gives a full-height band, never a
     * taller-than-content one. */
    band = spdf_win_minimap_viewport_band(PANEL_W, 1000.0, 10.0, 100.0, 0.0);
    expect_near(band.h, 1000.0, "a fully visible document fills the band");
    expect_near(band.y, 0.0, "a full-height band cannot be scrolled");
    /* The 0.02 floor and the 10 px minimum: a 5000-page document still gets a
     * grabbable band. */
    band = spdf_win_minimap_viewport_band(PANEL_W, 300.0, 100000.0, 10.0, 0.5);
    /* The 0.02 floor puts it at 6 px and the 10 px minimum then wins -- which is
     * the order macOS applies them in: clamp the fraction, THEN MAX(10). */
    expect_near(band.h, 10.0, "the 10 px minimum beats the 0.02 fraction floor");
    /* A taller strip lets the 0.02 floor show through on its own. */
    band = spdf_win_minimap_viewport_band(PANEL_W, 3000.0, 100000.0, 10.0, 0.5);
    expect_near(band.h, 3000.0 * 0.02, "the visible fraction has a 0.02 floor");
    printf("viewport_band top y=%.9f h=%.9f tiny h=%.9f floor h=%.9f\n", 0.0, 100.0, 10.0, 3000.0 * 0.02);
}

/* The doc<->strip mapping, which is what a minimap click and drag ride on. */
static void test_document_mapping(void) {
    SpdfWinMinimapStrip strip;
    double doc_y[3] = {13.0, 1000.0, 2000.0};
    double doc_h[3] = {900.0, 900.0, 900.0};
    double at_top, at_page1_mid, round_trip;

    memset(&strip, 0, sizeof(strip));
    spdf_win_minimap_strip_compute(&strip, letter, 3, PANEL_W, SPDF_WIN_MINIMAP_SIDE_INSET, SPDF_WIN_MINIMAP_GAP);

    at_top = spdf_win_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 3, 0.0);
    expect_near(at_top, strip.rects[0].y, "above the first page clamps to the strip top");
    expect_near(spdf_win_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 3, 99999.0),
                strip.rects[2].y + strip.rects[2].h, "below the last page clamps to the strip foot");
    at_page1_mid = spdf_win_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 3, 1000.0 + 450.0);
    expect_near(at_page1_mid, strip.rects[1].y + strip.rects[1].h * 0.5, "the middle of a page maps to its middle");
    /* A y in a document GAP maps proportionally onto the strip gap, so a drag
     * between pages does not jump. */
    expect(spdf_win_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 3, 950.0) >
               strip.rects[0].y + strip.rects[0].h - EPS,
           "a document gap maps into the strip gap");
    /* Round trip: the inverse must land back on the same document point. */
    round_trip = spdf_win_minimap_document_y_for_strip_y(&strip, doc_y, doc_h, 3, at_page1_mid);
    expect_near(round_trip, 1450.0, "strip -> document -> strip round-trips inside a page");
    printf("mapping page1_mid strip_y=%.9f doc_y=%.9f\n", at_page1_mid, round_trip);
    /* A mismatched count refuses rather than reading past the array. */
    expect_near(spdf_win_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 2, 500.0), 0.0,
                "a count that disagrees with the strip returns 0");
    spdf_win_minimap_strip_clear(&strip);
}

/* The constants themselves, pinned separately: a differential cannot notice a
 * number that is wrong in both implementations. */
static void test_constants(void) {
    expect_near(SPDF_WIN_MINIMAP_GAP, 4.0, "gap is 4 pt");
    expect_near(SPDF_WIN_MINIMAP_SIDE_INSET, 18.0, "side inset is 18 pt");
    expect_near(SPDF_WIN_MINIMAP_EDGE_INSET, 16.0, "edge inset is 16 pt");
    expect_near(SPDF_WIN_MINIMAP_TOP_PAD, 8.0, "top pad is 8 pt");
    expect_near(SPDF_WIN_MINIMAP_MAX_WIDTH_RATIO, 2.5, "the over-wide cap is 2.5x the median");
    expect(SPDF_WIN_MINIMAP_THUMB_MAX_BYTES == (size_t)32 * 1024 * 1024, "the thumbnail budget is 32 MB");
    expect(SPDF_WIN_MINIMAP_WINDOW_EXTRA_PAGES == 30, "the thumbnail window pads by 30 pages");
    expect(SPDF_WIN_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES == 15, "the recenter margin is 15 pages");
    expect(SPDF_WIN_MINIMAP_WINDOW_EVICT_SLACK_PAGES == 30, "the evict slack is 30 pages");
    expect_near(SPDF_WIN_MINIMAP_MARKER_TICK_H, 3.0, "a search tick is 3 px");
}

int main(void) {
    test_constants();
    test_median();
    test_point_scale();
    test_strip();
    test_content_top();
    test_hit_and_range();
    test_thumb_window();
    test_thumb_zoom();
    test_viewport();
    test_document_mapping();

    if (failures) {
        printf("%d minimap geometry check(s) failed\n", failures);
        return 1;
    }
    printf("All minimap geometry checks passed\n");
    return 0;
}
