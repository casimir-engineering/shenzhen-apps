/* Layout math tests for the GTK4 document canvas (spdf_docview_internal.h).
 * glib-only; build via `make -C portable linux-gtk4-tests`. */

#include <glib.h>

#include "spdf_docview_internal.h"

#define EPS 1e-6

/* Letter, a 10900pt-wide schematic sheet, A5-ish, tall poster. */
static const SpdfPageSizePt mixed_sizes[] = {
    {612.0, 792.0},
    {10900.0, 7539.0},
    {420.0, 595.0},
    {612.0, 4000.0},
};
#define MIXED_COUNT ((int)G_N_ELEMENTS(mixed_sizes))

static void test_layout_uniform(void) {
    SpdfPageSizePt sizes[3] = {{612.0, 792.0}, {612.0, 792.0}, {612.0, 792.0}};
    SpdfLayout layout = {0};

    spdf_layout_compute(&layout, sizes, 3, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    g_assert_cmpint(layout.count, ==, 3);
    /* Canvas at least as wide as the viewport; pages centered in it. */
    g_assert_cmpfloat(layout.canvas_w, ==, 900.0);
    for (int i = 0; i < 3; ++i) {
        g_assert_cmpfloat_with_epsilon(layout.rects[i].x + layout.rects[i].w * 0.5, 450.0, EPS);
        g_assert_cmpfloat_with_epsilon(layout.rects[i].w, 612.0, EPS);
        g_assert_cmpfloat_with_epsilon(layout.rects[i].h, 792.0, EPS);
    }
    /* 13 top margin, 26 between pages, 13 bottom. */
    g_assert_cmpfloat_with_epsilon(layout.rects[0].y, 13.0, EPS);
    g_assert_cmpfloat_with_epsilon(layout.rects[1].y, 13.0 + 792.0 + 26.0, EPS);
    g_assert_cmpfloat_with_epsilon(layout.canvas_h, 13.0 + 3 * 792.0 + 2 * 26.0 + 13.0, EPS);
    spdf_layout_clear(&layout);
}

static void test_layout_mixed_giant_sheet(void) {
    SpdfLayout layout = {0};
    double mid;

    spdf_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    /* The canvas is as wide as the widest page + margins, and EVERY page is
     * centered on the same midline (the June centering bug class). */
    g_assert_cmpfloat_with_epsilon(layout.canvas_w, 10900.0 + 44.0, EPS);
    mid = layout.canvas_w * 0.5;
    for (int i = 0; i < MIXED_COUNT; ++i) {
        g_assert_cmpfloat_with_epsilon(layout.rects[i].x + layout.rects[i].w * 0.5, mid, EPS);
        g_assert_cmpfloat_with_epsilon(layout.rects[i].w, mixed_sizes[i].width, EPS);
        g_assert_cmpfloat_with_epsilon(layout.rects[i].h, mixed_sizes[i].height, EPS);
        if (i > 0) {
            /* Monotonic vertical order with the 26px gap. */
            g_assert_cmpfloat_with_epsilon(layout.rects[i].y,
                                           layout.rects[i - 1].y + layout.rects[i - 1].h + 26.0, EPS);
        }
    }
    /* Slot geometry never depends on the render byte cap, even though the
     * giant sheet's texture will be capped. */
    g_assert_cmpfloat(spdf_capped_render_zoom(1.0, 10900.0, 7539.0), <, 1.0);
    g_assert_cmpfloat_with_epsilon(layout.rects[1].w, 10900.0, EPS);
    spdf_layout_clear(&layout);
}

static void test_layout_zoom_scales_rects(void) {
    SpdfLayout layout = {0};

    spdf_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 2.5, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    for (int i = 0; i < MIXED_COUNT; ++i) {
        g_assert_cmpfloat_with_epsilon(layout.rects[i].w, mixed_sizes[i].width * 2.5, EPS);
        g_assert_cmpfloat_with_epsilon(layout.rects[i].h, mixed_sizes[i].height * 2.5, EPS);
    }
    spdf_layout_clear(&layout);
}

static void test_nearest_center_matches_linear_scan(void) {
    SpdfLayout layout = {0};
    double probes[] = {-100.0, 0.0, 13.0, 500.0, 900.0, 5000.0, 9000.0, 12000.0, 1e9};

    spdf_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    for (guint k = 0; k < G_N_ELEMENTS(probes); ++k) {
        double y = probes[k];
        int best = -1;
        double best_distance = 0.0;
        for (int i = 0; i < layout.count; ++i) {
            double center = layout.rects[i].y + layout.rects[i].h * 0.5;
            double distance = ABS(center - y);
            if (best < 0 || distance < best_distance) {
                best = i;
                best_distance = distance;
            }
        }
        g_assert_cmpint(spdf_layout_page_nearest_center(&layout, y), ==, best);
    }
    spdf_layout_clear(&layout);
}

static void test_visible_range(void) {
    SpdfLayout layout = {0};
    int first = -1;
    int last = -1;

    spdf_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    /* Band inside page 0 only. */
    g_assert_true(spdf_layout_visible_range(&layout, 20.0, 100.0, &first, &last));
    g_assert_cmpint(first, ==, 0);
    g_assert_cmpint(last, ==, 0);
    /* Band spanning the page 0 / page 1 boundary. */
    g_assert_true(spdf_layout_visible_range(&layout, layout.rects[0].y + layout.rects[0].h - 10.0,
                                            layout.rects[1].y + 10.0, &first, &last));
    g_assert_cmpint(first, ==, 0);
    g_assert_cmpint(last, ==, 1);
    /* Band covering everything. */
    g_assert_true(spdf_layout_visible_range(&layout, 0.0, layout.canvas_h, &first, &last));
    g_assert_cmpint(first, ==, 0);
    g_assert_cmpint(last, ==, MIXED_COUNT - 1);
    spdf_layout_clear(&layout);
}

static void test_crop_regime_decision(void) {
    SpdfLayout layout = {0};

    spdf_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    /* 900x700 viewport: Letter is fine, the schematic and the tall poster
     * enter the crop regime. */
    g_assert_false(spdf_slot_needs_crop(&layout.rects[0], 900.0, 700.0));
    g_assert_true(spdf_slot_needs_crop(&layout.rects[1], 900.0, 700.0));
    g_assert_true(spdf_slot_needs_crop(&layout.rects[3], 900.0, 700.0));
    spdf_layout_clear(&layout);
}

static void test_fit_zooms(void) {
    /* Fit width: viewport / page width, no padding (GTK3 fit branch). */
    g_assert_cmpfloat_with_epsilon(spdf_fit_width_zoom(612.0, 1224.0), 2.0, EPS);
    /* Fit page: the more constrained axis wins. */
    g_assert_cmpfloat_with_epsilon(spdf_fit_page_zoom(612.0, 792.0, 1224.0, 792.0), 1.0, EPS);
    /* Clamped to the zoom bounds. */
    g_assert_cmpfloat_with_epsilon(spdf_fit_width_zoom(10900.0, 900.0), SPDF_MIN_ZOOM, EPS);
    g_assert_cmpfloat_with_epsilon(spdf_fit_width_zoom(10.0, 10000.0), SPDF_MAX_ZOOM, EPS);
    /* Degenerate viewport: caller keeps the current zoom. */
    g_assert_cmpfloat(spdf_fit_width_zoom(612.0, 50.0), ==, 0.0);
    g_assert_cmpfloat(spdf_fit_page_zoom(612.0, 792.0, 900.0, 50.0), ==, 0.0);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/layout/uniform", test_layout_uniform);
    g_test_add_func("/layout/mixed-giant-sheet", test_layout_mixed_giant_sheet);
    g_test_add_func("/layout/zoom-scales-rects", test_layout_zoom_scales_rects);
    g_test_add_func("/layout/nearest-center", test_nearest_center_matches_linear_scan);
    g_test_add_func("/layout/visible-range", test_visible_range);
    g_test_add_func("/layout/crop-regime", test_crop_regime_decision);
    g_test_add_func("/layout/fit-zooms", test_fit_zooms);
    return g_test_run();
}
