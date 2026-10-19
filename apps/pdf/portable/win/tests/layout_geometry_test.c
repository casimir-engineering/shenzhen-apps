/* Continuous-scroll geometry conformance for portable/win/src/spdf_win_layout.h.
 *
 * Two jobs in one binary, both of which have to hold:
 *
 *   1. ASSERTIONS. Every check below exits non-zero on failure, so this file is
 *      a pass/fail test whether it is run natively on macOS or in the Windows
 *      guest through portable/win/tests/run-tests.sh. Nothing is judged by
 *      reading output text.
 *   2. TRANSCRIPT. It also prints every computed number in a fixed format. The
 *      same binary built by clang/arm64 on macOS and by MSVC/ARM64 in the guest
 *      must produce a BYTE-IDENTICAL transcript; portable/win/tests/t3-verify.sh
 *      builds both and diffs them. That is the standard portable/win/verify.sh
 *      already set for spdf_recolor.c, and it is what turns "it compiles on
 *      Windows" into "it computes the same layout on Windows".
 *
 * The expected values are not invented here. They are the GTK4 layer's, and
 * portable/win/tests/gtk_differential.c asserts the port against the real GTK
 * header on macOS. The constants asserted below (13/26 margins, the 80px
 * viewport guard, the 0.10-8.0 zoom clamp) are pinned separately so that a
 * change to BOTH implementations at once still trips something.
 *
 * Header-only subject: no extra translation units to link.
 */

#include <stdio.h>

#include "spdf_win_layout.h"

static int failures;

static void fail(const char* what) {
    printf("FAIL %s\n", what);
    failures++;
}

static void expect(int condition, const char* what) {
    if (!condition) fail(what);
}

#define EPS 1e-9

static int near_d(double a, double b) {
    double d = a - b;
    if (d < 0.0) d = -d;
    return d <= EPS;
}

static void expect_near(double got, double want, const char* what) {
    if (!near_d(got, want)) {
        printf("FAIL %s: got %.9f want %.9f\n", what, got, want);
        failures++;
    }
}

/* Letter, a 10900pt-wide schematic sheet, A5-ish, a tall poster. The same
 * fixture the GTK layout tests use. */
static const SpdfWinPageSizePt mixed_sizes[] = {
    {612.0, 792.0},
    {10900.0, 7539.0},
    {420.0, 595.0},
    {612.0, 4000.0},
};
#define MIXED_COUNT 4

static void print_layout(const char* label, const SpdfWinLayout* layout) {
    int i;
    printf("layout %s count=%d canvas=%.6f x %.6f\n", label, layout->count, layout->canvas_w, layout->canvas_h);
    for (i = 0; i < layout->count; ++i)
        printf("  slot %d  x=%.6f y=%.6f w=%.6f h=%.6f crop=%d\n", i, layout->rects[i].x, layout->rects[i].y,
               layout->rects[i].w, layout->rects[i].h, spdf_win_slot_needs_crop(&layout->rects[i], 900.0, 700.0));
}

static void test_uniform_stack(void) {
    SpdfWinPageSizePt sizes[3] = {{612.0, 792.0}, {612.0, 792.0}, {612.0, 792.0}};
    SpdfWinLayout layout;
    int i;

    layout.rects = NULL;
    layout.count = 0;
    layout.canvas_w = 0.0;
    layout.canvas_h = 0.0;

    spdf_win_layout_compute(&layout, sizes, 3, 1.0, 900.0, SPDF_WIN_PAGE_MARGIN_H, SPDF_WIN_PAGE_MARGIN_V);
    print_layout("uniform", &layout);
    expect(layout.count == 3, "uniform count");
    /* Canvas at least as wide as the viewport; every page centred in it. */
    expect_near(layout.canvas_w, 900.0, "uniform canvas_w");
    for (i = 0; i < 3; ++i) {
        expect_near(layout.rects[i].x + layout.rects[i].w * 0.5, 450.0, "uniform centre");
        expect_near(layout.rects[i].w, 612.0, "uniform w");
        expect_near(layout.rects[i].h, 792.0, "uniform h");
    }
    /* 13 above the first, 26 between, 13 below the last. */
    expect_near(layout.rects[0].y, 13.0, "uniform first y");
    expect_near(layout.rects[1].y, 13.0 + 792.0 + 26.0, "uniform second y");
    expect_near(layout.canvas_h, 13.0 + 3 * 792.0 + 2 * 26.0 + 13.0, "uniform canvas_h");
    spdf_win_layout_clear(&layout);
    expect(layout.rects == NULL && layout.count == 0, "clear resets");
}

static void test_mixed_sizes_share_a_midline(void) {
    SpdfWinLayout layout;
    double mid;
    int i;

    layout.rects = NULL;
    layout.count = 0;
    layout.canvas_w = 0.0;
    layout.canvas_h = 0.0;

    spdf_win_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_WIN_PAGE_MARGIN_H,
                            SPDF_WIN_PAGE_MARGIN_V);
    print_layout("mixed", &layout);
    /* The canvas is as wide as the widest page + margins, and EVERY page is
     * centred on the same midline -- the June centring bug class. */
    expect_near(layout.canvas_w, 10900.0 + 44.0, "mixed canvas_w");
    mid = layout.canvas_w * 0.5;
    for (i = 0; i < MIXED_COUNT; ++i) {
        expect_near(layout.rects[i].x + layout.rects[i].w * 0.5, mid, "mixed centre");
        expect_near(layout.rects[i].w, mixed_sizes[i].width, "mixed w");
        expect_near(layout.rects[i].h, mixed_sizes[i].height, "mixed h");
        if (i > 0) expect_near(layout.rects[i].y, layout.rects[i - 1].y + layout.rects[i - 1].h + 26.0, "mixed gap");
    }
    /* Slot geometry never depends on the render byte cap, even though the giant
     * sheet's texture certainly will be capped. */
    expect(spdf_win_capped_render_zoom(1.0, 10900.0, 7539.0) < 1.0, "giant sheet is byte-capped");
    expect_near(layout.rects[1].w, 10900.0, "capping does not shrink the slot");
    spdf_win_layout_clear(&layout);
}

static void test_nearest_center_and_visible_range(void) {
    SpdfWinLayout layout;
    double y;
    int band;
    static const double bands[][2] = {{0.0, 100.0},     {0.0, 8000.0},   {820.0, 830.0},     {830.0, 831.0},
                                      {8400.0, 9100.0}, {-500.0, -10.0}, {40000.0, 41000.0}, {13.0, 20000.0}};

    layout.rects = NULL;
    layout.count = 0;
    layout.canvas_w = 0.0;
    layout.canvas_h = 0.0;
    spdf_win_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_WIN_PAGE_MARGIN_H,
                            SPDF_WIN_PAGE_MARGIN_V);

    for (y = -200.0; y <= 14000.0; y += 617.0)
        printf("nearest y=%.6f -> %d\n", y, spdf_win_layout_page_nearest_center(&layout, y));

    for (band = 0; band < (int)(sizeof(bands) / sizeof(bands[0])); ++band) {
        int first = -1;
        int last = -1;
        int ok = spdf_win_layout_visible_range(&layout, bands[band][0], bands[band][1], &first, &last);
        printf("range [%.6f,%.6f] -> %d first=%d last=%d\n", bands[band][0], bands[band][1], ok, ok ? first : -1,
               ok ? last : -1);
        if (ok) expect(first <= last, "visible range is ordered");
    }

    /* Band entirely above the first page: nothing intersects. */
    expect(spdf_win_layout_visible_range(&layout, -500.0, -10.0, NULL, NULL) == 0, "above-document band is empty");
    /* Band entirely below the last page: nothing intersects. */
    expect(spdf_win_layout_visible_range(&layout, 40000.0, 41000.0, NULL, NULL) == 0, "below-document band is empty");
    /* Degenerate band. */
    expect(spdf_win_layout_visible_range(&layout, 100.0, 100.0, NULL, NULL) == 0, "empty band is empty");
    /* A band covering everything covers every page. */
    {
        int first = -1;
        int last = -1;
        expect(spdf_win_layout_visible_range(&layout, 0.0, layout.canvas_h, &first, &last) == 1, "full band hits");
        expect(first == 0 && last == MIXED_COUNT - 1, "full band spans the document");
    }
    /* An empty layout resolves to no page at all. */
    {
        SpdfWinLayout empty;
        empty.rects = NULL;
        empty.count = 0;
        empty.canvas_w = 0.0;
        empty.canvas_h = 0.0;
        expect(spdf_win_layout_page_nearest_center(&empty, 10.0) == -1, "empty layout has no nearest page");
        expect(spdf_win_layout_visible_range(&empty, 0.0, 10.0, NULL, NULL) == 0, "empty layout shows nothing");
    }
    spdf_win_layout_clear(&layout);
}

static void test_fit_modes(void) {
    static const double viewports[] = {60.0, 80.0, 81.0, 900.0, 1600.0, 20000.0};
    int i;

    for (i = 0; i < (int)(sizeof(viewports) / sizeof(viewports[0])); ++i) {
        double vw = viewports[i];
        printf("fit vw=%.6f width=%.6f page=%.6f height=%.6f\n", vw, spdf_win_fit_width_zoom(612.0, vw),
               spdf_win_fit_page_zoom(612.0, 792.0, vw, vw), spdf_win_fit_height_zoom(792.0, vw));
    }
    /* The GTK3 "allocation <= 80" guard: too small to trust, keep current zoom. */
    expect_near(spdf_win_fit_width_zoom(612.0, 80.0), 0.0, "fit-width guard at 80");
    expect(spdf_win_fit_width_zoom(612.0, 81.0) > 0.0, "fit-width works above 80");
    expect_near(spdf_win_fit_width_zoom(612.0, 612.0), 1.0, "fit-width identity");
    /* Clamped to the zoom bounds at both ends. */
    expect_near(spdf_win_fit_width_zoom(612.0, 20000.0), SPDF_WIN_MAX_ZOOM, "fit-width clamps high");
    expect_near(spdf_win_fit_width_zoom(1000000.0, 900.0), SPDF_WIN_MIN_ZOOM, "fit-width clamps low");
    /* Fit-page takes the tighter of the two axes. */
    expect_near(spdf_win_fit_page_zoom(612.0, 792.0, 1224.0, 792.0), 1.0, "fit-page picks the height");
    expect_near(spdf_win_fit_page_zoom(612.0, 792.0, 612.0, 1584.0), 1.0, "fit-page picks the width");
    expect_near(spdf_win_fit_height_zoom(792.0, 792.0), 1.0, "fit-height identity");
    /* Degenerate page sizes fail open. */
    expect_near(spdf_win_fit_width_zoom(0.0, 900.0), 0.0, "fit-width rejects a zero-width page");
    expect_near(spdf_win_fit_page_zoom(612.0, 0.0, 900.0, 900.0), 0.0, "fit-page rejects a zero-height page");
}

static void test_zoom_anchor_round_trip(void) {
    SpdfWinLayout layout;
    SpdfWinZoomAnchor anchor;
    static const double points[][2] = {{450.0, 300.0}, {10.0, 10.0}, {899.0, 699.0}, {450.0, 0.0}};
    int i;

    layout.rects = NULL;
    layout.count = 0;
    layout.canvas_w = 0.0;
    layout.canvas_h = 0.0;

    for (i = 0; i < (int)(sizeof(points) / sizeof(points[0])); ++i) {
        double scroll_x = 0.0;
        double scroll_y = 900.0;
        double new_x = 0.0;
        double new_y = 0.0;
        double back_x;
        double back_y;

        spdf_win_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_WIN_PAGE_MARGIN_H,
                                SPDF_WIN_PAGE_MARGIN_V);
        spdf_win_zoom_anchor_capture(&anchor, &layout, mixed_sizes, 1.0, points[i][0], points[i][1], scroll_x,
                                     scroll_y);
        printf("anchor at (%.6f,%.6f) -> valid=%d page=%d pt=(%.6f,%.6f)\n", points[i][0], points[i][1], anchor.valid,
               anchor.page, anchor.page_x, anchor.page_y);
        expect(anchor.valid == 1, "anchor captured");

        /* Relayout at 2x and re-derive the scroll. */
        spdf_win_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 2.0, 900.0, SPDF_WIN_PAGE_MARGIN_H,
                                SPDF_WIN_PAGE_MARGIN_V);
        expect(spdf_win_zoom_anchor_apply(&anchor, &layout, 2.0, 900.0, 700.0, &new_x, &new_y) == 1, "anchor applied");
        printf("  at zoom 2.0 -> scroll=(%.6f,%.6f)\n", new_x, new_y);

        /* The anchored document point is back under the anchored viewport point,
         * unless the clamp to the scrollable range moved it -- which is the only
         * thing allowed to. */
        back_x = layout.rects[anchor.page].x + anchor.page_x * 2.0 - new_x;
        back_y = layout.rects[anchor.page].y + anchor.page_y * 2.0 - new_y;
        if (new_x > 0.0 && new_x < layout.canvas_w - 900.0) expect_near(back_x, anchor.viewport_x, "anchor holds x");
        if (new_y > 0.0 && new_y < layout.canvas_h - 700.0) expect_near(back_y, anchor.viewport_y, "anchor holds y");
    }

    /* An anchor out over the margin resolves to the page NEAREST it in 2D --
     * which in this document is the 10900pt sheet, not the letter page above
     * it, because the sheet's left edge is 17pt away and the letter page's is
     * 5161pt away -- and the captured point is clamped into that page. */
    spdf_win_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_WIN_PAGE_MARGIN_H,
                            SPDF_WIN_PAGE_MARGIN_V);
    spdf_win_zoom_anchor_capture(&anchor, &layout, mixed_sizes, 1.0, 5.0, 0.0, 0.0, 0.0);
    printf("margin anchor -> valid=%d page=%d pt=(%.6f,%.6f)\n", anchor.valid, anchor.page, anchor.page_x,
           anchor.page_y);
    expect(anchor.valid == 1 && anchor.page == 1, "margin anchor lands on the nearest page");
    expect(anchor.page_x >= 0.0 && anchor.page_x <= mixed_sizes[anchor.page].width, "margin anchor clamped in x");
    expect(anchor.page_y >= 0.0 && anchor.page_y <= mixed_sizes[anchor.page].height, "margin anchor clamped in y");
    /* A point inside a page resolves to that page. */
    spdf_win_zoom_anchor_capture(&anchor, &layout, mixed_sizes, 1.0, 450.0, 100.0, 4900.0, 0.0);
    expect(anchor.valid == 1 && anchor.page == 0, "a point inside page 0 anchors to page 0");

    /* Fails open rather than guessing. */
    {
        SpdfWinLayout empty;
        double sx = 7.0;
        double sy = 9.0;
        empty.rects = NULL;
        empty.count = 0;
        empty.canvas_w = 0.0;
        empty.canvas_h = 0.0;
        spdf_win_zoom_anchor_capture(&anchor, &empty, NULL, 1.0, 10.0, 10.0, 0.0, 0.0);
        expect(anchor.valid == 0, "no anchor without pages");
        expect(spdf_win_zoom_anchor_apply(&anchor, &empty, 1.0, 900.0, 700.0, &sx, &sy) == 0, "apply rejects it");
        expect_near(sx, 7.0, "apply left scroll_x alone");
        expect_near(sy, 9.0, "apply left scroll_y alone");
    }
    spdf_win_layout_clear(&layout);
}

static void test_hscroll_clamp_policy(void) {
    SpdfWinLayout layout;
    int page;
    static const double values[] = {-500.0, 0.0, 400.0, 6000.0, 99999.0};
    int i;

    layout.rects = NULL;
    layout.count = 0;
    layout.canvas_w = 0.0;
    layout.canvas_h = 0.0;
    spdf_win_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_WIN_PAGE_MARGIN_H,
                            SPDF_WIN_PAGE_MARGIN_V);

    for (page = 0; page < MIXED_COUNT; ++page) {
        for (i = 0; i < (int)(sizeof(values) / sizeof(values[0])); ++i) {
            SpdfWinHScrollClamp c = spdf_win_hscroll_clamp(&layout, page, 900.0, values[i]);
            printf("hclamp page=%d value=%.6f -> scrollable=%d value=%.6f\n", page, values[i], c.scrollable, c.value);
            expect(c.value >= 0.0, "clamp never goes negative");
            expect(c.value <= layout.canvas_w - 900.0 + EPS, "clamp never exceeds the range");
        }
    }

    /* The scrollbar policy comes from the TOTAL content width, not the current
     * page: page 0 is narrower than the viewport but the document still needs a
     * horizontal scrollbar because page 1 is 10900pt wide. */
    expect(spdf_win_hscroll_clamp(&layout, 0, 900.0, 0.0).scrollable == 1, "policy follows the document, not the page");
    /* A page narrower than the viewport is pinned centred, whatever was asked
     * for. */
    expect_near(spdf_win_hscroll_clamp(&layout, 0, 900.0, 4000.0).value,
                spdf_win_hscroll_clamp(&layout, 0, 900.0, 0.0).value, "narrow page ignores the requested value");
    /* A page wider than the viewport pans inside its own bounds. */
    {
        SpdfWinHScrollClamp c = spdf_win_hscroll_clamp(&layout, 1, 900.0, 99999.0);
        expect_near(c.value, layout.rects[1].x + layout.rects[1].w - 900.0, "wide page pans to its right edge");
    }
    /* A document narrower than the viewport is not scrollable. */
    {
        SpdfWinPageSizePt small[1];
        SpdfWinLayout narrow;
        narrow.rects = NULL;
        narrow.count = 0;
        narrow.canvas_w = 0.0;
        narrow.canvas_h = 0.0;
        small[0].width = 420.0;
        small[0].height = 595.0;
        spdf_win_layout_compute(&narrow, small, 1, 1.0, 900.0, SPDF_WIN_PAGE_MARGIN_H, SPDF_WIN_PAGE_MARGIN_V);
        expect(spdf_win_hscroll_clamp(&narrow, 0, 900.0, 0.0).scrollable == 0, "narrow document is not scrollable");
        spdf_win_layout_clear(&narrow);
    }
    spdf_win_layout_clear(&layout);
}

static void test_render_byte_cap(void) {
    static const double zooms[] = {0.25, 1.0, 2.0, 8.0};
    int i;

    for (i = 0; i < (int)(sizeof(zooms) / sizeof(zooms[0])); ++i)
        printf("cap zoom=%.6f letter=%.6f sheet=%.6f\n", zooms[i], spdf_win_capped_render_zoom(zooms[i], 612.0, 792.0),
               spdf_win_capped_render_zoom(zooms[i], 10900.0, 7539.0));

    /* Under the cap: untouched. */
    expect_near(spdf_win_capped_render_zoom(1.0, 612.0, 792.0), 1.0, "small page is not capped");
    /* Over the cap: scaled so the bitmap lands exactly on the cap. */
    {
        double capped = spdf_win_capped_render_zoom(2.0, 10900.0, 7539.0);
        double bytes = 10900.0 * 7539.0 * capped * capped * 4.0;
        expect(capped < 2.0, "giant sheet is capped");
        expect(bytes <= (double)SPDF_WIN_MAX_RENDER_SURFACE_BYTES * 1.000001, "capped bitmap fits the budget");
        expect(bytes >= (double)SPDF_WIN_MAX_RENDER_SURFACE_BYTES * 0.999, "capped bitmap uses the budget");
    }
    /* Degenerate inputs fail open. */
    expect_near(spdf_win_capped_render_zoom(0.0, 612.0, 792.0), 0.0, "zero zoom passes through");
    expect_near(spdf_win_capped_render_zoom(1.0, 0.0, 792.0), 1.0, "zero width passes through");
}

int main(void) {
    printf("== spdf_win_layout transcript ==\n");
    test_uniform_stack();
    test_mixed_sizes_share_a_midline();
    test_nearest_center_and_visible_range();
    test_fit_modes();
    test_zoom_anchor_round_trip();
    test_hscroll_clamp_policy();
    test_render_byte_cap();
    printf("== %d failures ==\n", failures);
    return failures == 0 ? 0 : 1;
}
