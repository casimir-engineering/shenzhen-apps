/* Zoom-anchor math tests: the document point under the cursor stays under the
 * cursor across a zoom, including on pixel-capped giant sheets (the June
 * zoom-anchor drift defect). glib-only. */

#include <glib.h>

#include "spdf_docview_internal.h"

#define EPS 1e-6

static const SpdfPageSizePt sizes[] = {
    {612.0, 792.0},
    {10900.0, 7539.0}, /* pixel-capped at any realistic scale */
    {420.0, 595.0},
};
#define COUNT ((int)G_N_ELEMENTS(sizes))

/* One anchored zoom step; asserts the anchored document point projects back
 * to the anchored viewport point (exactly, when no scroll clamping bites). */
static void assert_anchor_roundtrip(double old_zoom, double new_zoom, double viewport_x, double viewport_y,
                                    double scroll_x, double scroll_y, double viewport_w, double viewport_h) {
    SpdfLayout layout = {0};
    SpdfZoomAnchor anchor = {0};
    double sx = 0.0;
    double sy = 0.0;
    const SpdfPageRect* rect;
    double projected_x;
    double projected_y;

    spdf_layout_compute(&layout, sizes, COUNT, old_zoom, viewport_w, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    spdf_zoom_anchor_capture(&anchor, &layout, sizes, old_zoom, viewport_x, viewport_y, scroll_x, scroll_y);
    g_assert_true(anchor.valid);

    spdf_layout_compute(&layout, sizes, COUNT, new_zoom, viewport_w, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    g_assert_true(spdf_zoom_anchor_apply(&anchor, &layout, new_zoom, viewport_w, viewport_h, &sx, &sy));

    rect = &layout.rects[anchor.page];
    projected_x = rect->x + anchor.page_x * new_zoom - sx;
    projected_y = rect->y + anchor.page_y * new_zoom - sy;
    /* Unless the target scroll hit the document edge, the anchored point is
     * back under the anchored viewport point. */
    if (sx > EPS && sx < layout.canvas_w - viewport_w - EPS)
        g_assert_cmpfloat_with_epsilon(projected_x, viewport_x, 1e-6);
    if (sy > EPS && sy < layout.canvas_h - viewport_h - EPS)
        g_assert_cmpfloat_with_epsilon(projected_y, viewport_y, 1e-6);
    spdf_layout_clear(&layout);
}

static void test_anchor_on_normal_page(void) {
    /* Pointer over page 0 territory near the top of the document. */
    assert_anchor_roundtrip(1.0, 1.5, 300.0, 200.0, 5200.0, 100.0, 900.0, 700.0);
    assert_anchor_roundtrip(1.5, 1.0, 300.0, 200.0, 5200.0, 150.0, 900.0, 700.0);
}

static void test_anchor_on_pixel_capped_sheet(void) {
    double scroll_y = 900.0; /* inside the giant sheet */
    double scale = 2.0;
    /* Regression for the June defect: the render scale IS capped here... */
    g_assert_cmpfloat(spdf_capped_render_zoom(scale, 10900.0, 7539.0), <, scale);
    /* ...but the anchor lives in document space, so anchored zoom over the
     * capped sheet is still exact. */
    assert_anchor_roundtrip(2.0, 2.2, 450.0, 350.0, 9000.0, scroll_y, 900.0, 700.0);
    assert_anchor_roundtrip(2.2, 1.6, 120.0, 650.0, 12000.0, scroll_y + 500.0, 900.0, 700.0);
}

static void test_anchor_capture_document_point(void) {
    SpdfLayout layout = {0};
    SpdfZoomAnchor anchor = {0};

    spdf_layout_compute(&layout, sizes, COUNT, 2.0, 900.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    /* Point 100 content px below/inside page 0's origin. */
    {
        double content_x = layout.rects[0].x + 100.0;
        double content_y = layout.rects[0].y + 100.0;
        spdf_zoom_anchor_capture(&anchor, &layout, sizes, 2.0, 10.0, 20.0, content_x - 10.0, content_y - 20.0);
        g_assert_true(anchor.valid);
        g_assert_cmpint(anchor.page, ==, 0);
        g_assert_cmpfloat_with_epsilon(anchor.page_x, 50.0, EPS); /* 100 px / zoom 2 */
        g_assert_cmpfloat_with_epsilon(anchor.page_y, 50.0, EPS);
    }
    spdf_layout_clear(&layout);
}

static void test_anchor_over_margin_clamps_to_nearest_page(void) {
    SpdfPageSizePt uniform[2] = {{612.0, 792.0}, {612.0, 792.0}};
    SpdfLayout layout = {0};
    SpdfZoomAnchor anchor = {0};

    spdf_layout_compute(&layout, uniform, 2, 1.0, 1200.0, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);
    /* In the left margin, vertically inside page 1: clamps to page 1's left
     * edge instead of failing (capture_zoom_anchor's margin behavior). */
    {
        double content_y = layout.rects[1].y + 10.0;
        spdf_zoom_anchor_capture(&anchor, &layout, uniform, 1.0, 0.0, 0.0, 5.0, content_y);
        g_assert_true(anchor.valid);
        g_assert_cmpint(anchor.page, ==, 1);
        g_assert_cmpfloat_with_epsilon(anchor.page_x, 0.0, EPS);
        g_assert_cmpfloat_with_epsilon(anchor.page_y, 10.0, EPS);
    }
    /* In the gap between the pages: clamps to the nearer page's bottom edge. */
    {
        double content_y = layout.rects[0].y + layout.rects[0].h + 5.0;
        spdf_zoom_anchor_capture(&anchor, &layout, uniform, 1.0, 0.0, 0.0, layout.canvas_w * 0.5, content_y);
        g_assert_true(anchor.valid);
        g_assert_cmpint(anchor.page, ==, 0);
        g_assert_cmpfloat_with_epsilon(anchor.page_y, 792.0, EPS);
    }
    spdf_layout_clear(&layout);
}

static void test_anchor_fails_open_without_layout(void) {
    SpdfZoomAnchor anchor = {0};
    SpdfLayout layout = {0};
    anchor.valid = TRUE;
    spdf_zoom_anchor_capture(&anchor, &layout, NULL, 1.0, 0.0, 0.0, 0.0, 0.0);
    g_assert_false(anchor.valid);
    g_assert_false(spdf_zoom_anchor_apply(&anchor, &layout, 1.0, 900.0, 700.0, NULL, NULL));
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/zoom-anchor/normal-page", test_anchor_on_normal_page);
    g_test_add_func("/zoom-anchor/pixel-capped-sheet", test_anchor_on_pixel_capped_sheet);
    g_test_add_func("/zoom-anchor/capture-document-point", test_anchor_capture_document_point);
    g_test_add_func("/zoom-anchor/margin-clamps-to-page", test_anchor_over_margin_clamps_to_nearest_page);
    g_test_add_func("/zoom-anchor/fails-open", test_anchor_fails_open_without_layout);
    return g_test_run();
}
