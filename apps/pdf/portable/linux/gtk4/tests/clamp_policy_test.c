/* Horizontal scroll clamp policy tests (port of clamp_horizontal_scroll,
 * including the June fix: the scrollbar policy derives from the TOTAL content
 * width vs the allocation, never from the current page). glib-only. */

#include <glib.h>

#include "spdf_docview_internal.h"

#define EPS 1e-6

static const SpdfPageSizePt mixed_sizes[] = {
    {612.0, 792.0},
    {10900.0, 7539.0},
    {420.0, 595.0},
};
#define MIXED_COUNT ((int)G_N_ELEMENTS(mixed_sizes))

static void test_uniform_doc_not_scrollable(void) {
    SpdfPageSizePt sizes[2] = {{612.0, 792.0}, {612.0, 792.0}};
    SpdfLayout layout = {0};
    SpdfHScrollClamp clamp;

    spdf_layout_compute(&layout, sizes, 2, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    clamp = spdf_hscroll_clamp(&layout, 0, 900.0, 0.0);
    /* Content narrower than the viewport: no horizontal scrolling, the page
     * is pinned centered. */
    g_assert_false(clamp.scrollable);
    g_assert_cmpfloat_with_epsilon(clamp.value, layout.rects[0].x + layout.rects[0].w * 0.5 - 450.0, EPS);
    spdf_layout_clear(&layout);
}

static void test_policy_from_total_width_not_current_page(void) {
    SpdfLayout layout = {0};
    SpdfHScrollClamp clamp;

    spdf_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    /* June bug regression: current page 0 (Letter, fits the viewport) but the
     * document holds a 10900pt sheet, so the content IS scrollable. Keying
     * the policy on the current page alone pushed every narrower page outside
     * the viewport. */
    clamp = spdf_hscroll_clamp(&layout, 0, 900.0, 0.0);
    g_assert_true(clamp.scrollable);
    /* And the narrow current page is still pinned centered on the wide canvas. */
    g_assert_cmpfloat_with_epsilon(clamp.value, layout.rects[0].x + layout.rects[0].w * 0.5 - 450.0, EPS);
    spdf_layout_clear(&layout);
}

static void test_wide_page_pans_within_its_bounds(void) {
    SpdfLayout layout = {0};
    SpdfHScrollClamp clamp;
    const SpdfPageRect* sheet;

    spdf_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    sheet = &layout.rects[1];

    /* Value left of the sheet: clamped to the sheet's left edge. */
    clamp = spdf_hscroll_clamp(&layout, 1, 900.0, 0.0);
    g_assert_cmpfloat_with_epsilon(clamp.value, sheet->x, EPS);
    /* Value beyond the sheet's right edge: clamped to page_max - viewport. */
    clamp = spdf_hscroll_clamp(&layout, 1, 900.0, 1e9);
    g_assert_cmpfloat_with_epsilon(clamp.value, sheet->x + sheet->w - 900.0, EPS);
    /* Value inside the sheet: untouched. */
    clamp = spdf_hscroll_clamp(&layout, 1, 900.0, sheet->x + 1234.0);
    g_assert_cmpfloat_with_epsilon(clamp.value, sheet->x + 1234.0, EPS);
    spdf_layout_clear(&layout);
}

static void test_clamp_respects_scroll_range(void) {
    SpdfLayout layout = {0};
    SpdfHScrollClamp clamp;

    spdf_layout_compute(&layout, mixed_sizes, MIXED_COUNT, 1.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    /* Centering a narrow page can never scroll past the canvas. */
    clamp = spdf_hscroll_clamp(&layout, 2, 900.0, 0.0);
    g_assert_cmpfloat(clamp.value, >=, 0.0);
    g_assert_cmpfloat(clamp.value, <=, layout.canvas_w - 900.0 + EPS);
    spdf_layout_clear(&layout);
}

static void test_degenerate_inputs_fail_open(void) {
    SpdfLayout layout = {0};
    SpdfHScrollClamp clamp = spdf_hscroll_clamp(&layout, 0, 900.0, 123.0);
    g_assert_false(clamp.scrollable);
    g_assert_cmpfloat_with_epsilon(clamp.value, 123.0, EPS); /* untouched */
    clamp = spdf_hscroll_clamp(NULL, 0, 900.0, 55.0);
    g_assert_cmpfloat_with_epsilon(clamp.value, 55.0, EPS);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/clamp/uniform-not-scrollable", test_uniform_doc_not_scrollable);
    g_test_add_func("/clamp/policy-from-total-width", test_policy_from_total_width_not_current_page);
    g_test_add_func("/clamp/wide-page-pans-in-bounds", test_wide_page_pans_within_its_bounds);
    g_test_add_func("/clamp/respects-scroll-range", test_clamp_respects_scroll_range);
    g_test_add_func("/clamp/degenerate-fails-open", test_degenerate_inputs_fail_open);
    return g_test_run();
}
