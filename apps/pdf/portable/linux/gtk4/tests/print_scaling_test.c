/* Pure-logic tests for spdf_print.c's scaling/placement math (glib only, no
 * GTK — the GTK half of the module is compiled out via SPDF_PRINT_TESTING).
 * The rules under test are ports of the Mac print helpers
 * (SPDFMacPrintView.mm): SPDFClampPrintCustomScale, spdf_print_scale_for_mode
 * and spdf_print_destination_rect, plus the Linux-only visible-source split
 * and render-zoom (dpi / byte-cap) policy. All rects in PDF points; the
 * imageable area's origin is (0,0), like GtkPrintContext's draw-page space. */
#define SPDF_PRINT_TESTING 1

#include "../spdf_print.c"

#include <math.h>

/* US Letter imageable area with a 18pt margin all around. */
#define LETTER_IMG_W (612.0 - 36.0)
#define LETTER_IMG_H (792.0 - 36.0)

static void assert_rect(const SpdfPrintRect* rect, double x, double y, double w, double h) {
    g_assert_cmpfloat(fabs(rect->x - x), <, 1e-9);
    g_assert_cmpfloat(fabs(rect->y - y), <, 1e-9);
    g_assert_cmpfloat(fabs(rect->w - w), <, 1e-9);
    g_assert_cmpfloat(fabs(rect->h - h), <, 1e-9);
}

static void test_clamp_custom_scale(void) {
    g_assert_cmpfloat(spdf_print_clamp_custom_scale(1.0), ==, 1.0);
    g_assert_cmpfloat(spdf_print_clamp_custom_scale(0.25), ==, 0.25);
    /* Below/above the Mac limits clamps, not rejects. */
    g_assert_cmpfloat(spdf_print_clamp_custom_scale(0.01), ==, SPDF_PRINT_MIN_CUSTOM_SCALE);
    g_assert_cmpfloat(spdf_print_clamp_custom_scale(50.0), ==, SPDF_PRINT_MAX_CUSTOM_SCALE);
    /* Degenerate values fall back to 1.0 (SPDFClampPrintCustomScale). */
    g_assert_cmpfloat(spdf_print_clamp_custom_scale(0.0), ==, 1.0);
    g_assert_cmpfloat(spdf_print_clamp_custom_scale(-2.0), ==, 1.0);
    g_assert_cmpfloat(spdf_print_clamp_custom_scale(NAN), ==, 1.0);
    g_assert_cmpfloat(spdf_print_clamp_custom_scale(INFINITY), ==, 1.0);
}

static void test_mode_scale(void) {
    /* Fit: min of the two axis ratios — the height limits an A4-ish portrait
     * page on Letter with margins. */
    double fit = spdf_print_mode_scale(595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_FIT, 1.0);
    g_assert_cmpfloat(fabs(fit - LETTER_IMG_H / 842.0), <, 1e-12);
    /* Fit GROWS small pages (Mac behavior: no shrink-only). */
    g_assert_cmpfloat(spdf_print_mode_scale(100.0, 100.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_FIT, 1.0), >,
                      1.0);
    /* Landscape page on portrait paper: width ratio limits. */
    fit = spdf_print_mode_scale(842.0, 595.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_FIT, 1.0);
    g_assert_cmpfloat(fabs(fit - LETTER_IMG_W / 842.0), <, 1e-12);
    /* Actual is always 1.0; custom scale is ignored. */
    g_assert_cmpfloat(spdf_print_mode_scale(595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_ACTUAL, 3.0),
                      ==, 1.0);
    /* Custom returns the clamped custom scale, independent of the paper. */
    g_assert_cmpfloat(spdf_print_mode_scale(595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_CUSTOM, 0.5),
                      ==, 0.5);
    g_assert_cmpfloat(spdf_print_mode_scale(595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_CUSTOM, 99.0),
                      ==, SPDF_PRINT_MAX_CUSTOM_SCALE);
    /* Degenerate page or paper → 1.0 (Mac guard). */
    g_assert_cmpfloat(spdf_print_mode_scale(0.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_FIT, 1.0), ==,
                      1.0);
    g_assert_cmpfloat(spdf_print_mode_scale(595.0, 842.0, 0.0, LETTER_IMG_H, SPDF_PRINT_SCALING_FIT, 1.0), ==, 1.0);
}

static void test_dest_rect_fit_portrait(void) {
    /* Portrait A4 on Letter: height-limited, centered horizontally. */
    SpdfPrintRect rect = spdf_print_dest_rect(595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_FIT, 1.0);
    double scale = LETTER_IMG_H / 842.0;

    assert_rect(&rect, (LETTER_IMG_W - 595.0 * scale) / 2.0, 0.0, 595.0 * scale, LETTER_IMG_H);
    /* Aspect preserved. */
    g_assert_cmpfloat(fabs(rect.w / rect.h - 595.0 / 842.0), <, 1e-12);
}

static void test_dest_rect_fit_landscape(void) {
    /* Landscape page on portrait paper: width-limited, centered vertically. */
    SpdfPrintRect rect = spdf_print_dest_rect(842.0, 595.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_FIT, 1.0);
    double scale = LETTER_IMG_W / 842.0;

    assert_rect(&rect, 0.0, (LETTER_IMG_H - 595.0 * scale) / 2.0, LETTER_IMG_W, 595.0 * scale);
}

static void test_dest_rect_actual_centered(void) {
    /* A small page at Actual Size sits centered, unscaled. */
    SpdfPrintRect rect = spdf_print_dest_rect(200.0, 100.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_ACTUAL, 1.0);

    assert_rect(&rect, (LETTER_IMG_W - 200.0) / 2.0, (LETTER_IMG_H - 100.0) / 2.0, 200.0, 100.0);
}

static void test_dest_rect_oversized_overflows(void) {
    /* An A0 sheet (2384×3370) at Actual Size overflows the paper on both
     * axes symmetrically (negative origin — the visible-source split crops). */
    SpdfPrintRect rect =
        spdf_print_dest_rect(2384.0, 3370.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_ACTUAL, 1.0);

    assert_rect(&rect, (LETTER_IMG_W - 2384.0) / 2.0, (LETTER_IMG_H - 3370.0) / 2.0, 2384.0, 3370.0);
    g_assert_cmpfloat(rect.x, <, 0.0);
    g_assert_cmpfloat(rect.y, <, 0.0);
}

static void test_dest_rect_minimum_size(void) {
    /* Sub-point results are floored to 1×1 pt (Mac MAX(1.0, …)). */
    SpdfPrintRect rect = spdf_print_dest_rect(4.0, 4.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_CUSTOM, 0.10);

    g_assert_cmpfloat(rect.w, ==, 1.0);
    g_assert_cmpfloat(rect.h, ==, 1.0);
}

static void test_visible_source_fully_on_paper(void) {
    /* Page fully on paper: source is the whole page, dst is the dest rect. */
    SpdfPrintRect dest = spdf_print_dest_rect(595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_FIT, 1.0);
    SpdfPrintRect src;
    SpdfPrintRect dst;

    g_assert_true(spdf_print_visible_source(&dest, 595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, &src, &dst));
    assert_rect(&src, 0.0, 0.0, 595.0, 842.0);
    assert_rect(&dst, dest.x, dest.y, dest.w, dest.h);
}

static void test_visible_source_oversized_crops(void) {
    /* A0 at Actual on Letter: dst is the whole imageable area, src the
     * centered paper-sized window into the page. */
    SpdfPrintRect dest =
        spdf_print_dest_rect(2384.0, 3370.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_ACTUAL, 1.0);
    SpdfPrintRect src;
    SpdfPrintRect dst;

    g_assert_true(spdf_print_visible_source(&dest, 2384.0, 3370.0, LETTER_IMG_W, LETTER_IMG_H, &src, &dst));
    assert_rect(&dst, 0.0, 0.0, LETTER_IMG_W, LETTER_IMG_H);
    assert_rect(&src, (2384.0 - LETTER_IMG_W) / 2.0, (3370.0 - LETTER_IMG_H) / 2.0, LETTER_IMG_W, LETTER_IMG_H);
    /* Cropping is what bounds print memory by PAPER area for huge sheets. */
    g_assert_cmpfloat(src.w, <, 2384.0);
    g_assert_cmpfloat(src.h, <, 3370.0);
}

static void test_visible_source_custom_zoom_crops_scaled(void) {
    /* 400% custom on a Letter-sized page: src shrinks by the scale factor. */
    SpdfPrintRect dest = spdf_print_dest_rect(612.0, 792.0, LETTER_IMG_W, LETTER_IMG_H, SPDF_PRINT_SCALING_CUSTOM, 4.0);
    SpdfPrintRect src;
    SpdfPrintRect dst;

    g_assert_true(spdf_print_visible_source(&dest, 612.0, 792.0, LETTER_IMG_W, LETTER_IMG_H, &src, &dst));
    assert_rect(&dst, 0.0, 0.0, LETTER_IMG_W, LETTER_IMG_H);
    g_assert_cmpfloat(fabs(src.w - LETTER_IMG_W / 4.0), <, 1e-9);
    g_assert_cmpfloat(fabs(src.h - LETTER_IMG_H / 4.0), <, 1e-9);
    /* Centered window: src center == page center. */
    g_assert_cmpfloat(fabs((src.x + src.w / 2.0) - 306.0), <, 1e-9);
    g_assert_cmpfloat(fabs((src.y + src.h / 2.0) - 396.0), <, 1e-9);
}

static void test_visible_source_degenerate(void) {
    SpdfPrintRect dest = {10.0, 10.0, 0.0, 100.0};
    SpdfPrintRect src;
    SpdfPrintRect dst;

    g_assert_false(spdf_print_visible_source(&dest, 595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, &src, &dst));
    g_assert_false(spdf_print_visible_source(NULL, 595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, &src, &dst));
    /* A dest entirely off the paper is not visible. */
    dest.x = LETTER_IMG_W + 5.0;
    dest.y = 0.0;
    dest.w = 100.0;
    dest.h = 100.0;
    g_assert_false(spdf_print_visible_source(&dest, 595.0, 842.0, LETTER_IMG_W, LETTER_IMG_H, &src, &dst));
}

static void test_render_zoom_dpi(void) {
    /* 600 dpi, fit-scale 1.0 → 600/72; no cap in the way. */
    double zoom = spdf_print_render_zoom(1.0, 600.0, 600.0, 595.0, 842.0, 0.0);
    g_assert_cmpfloat(fabs(zoom - 600.0 / 72.0), <, 1e-12);
    /* Asymmetric dpi uses the larger axis. */
    zoom = spdf_print_render_zoom(1.0, 300.0, 600.0, 595.0, 842.0, 0.0);
    g_assert_cmpfloat(fabs(zoom - 600.0 / 72.0), <, 1e-12);
    /* The scaling mode multiplies in: printing at 50% halves the zoom. */
    zoom = spdf_print_render_zoom(0.5, 600.0, 600.0, 595.0, 842.0, 0.0);
    g_assert_cmpfloat(fabs(zoom - 0.5 * 600.0 / 72.0), <, 1e-12);
    /* A nominal 72 dpi backend (preview / print-to-file) is raised to the
     * 300 dpi floor instead of printing blocky 72 dpi bitmaps. */
    zoom = spdf_print_render_zoom(1.0, 72.0, 72.0, 595.0, 842.0, 0.0);
    g_assert_cmpfloat(fabs(zoom - SPDF_PRINT_TARGET_DPI_FLOOR / 72.0), <, 1e-12);
    /* …but never below 1.0 even for tiny mode scales (Mac minimum zoom). */
    zoom = spdf_print_render_zoom(0.10, 72.0, 72.0, 100.0, 100.0, 0.0);
    g_assert_cmpfloat(zoom, >=, SPDF_PRINT_MIN_RENDER_ZOOM);
}

static void test_render_zoom_byte_cap(void) {
    /* A4 at 600 dpi is ~139 MB RGBA — the 128 MiB cap must shrink the zoom
     * to exactly the cap (continuous, not halving). */
    double zoom = spdf_print_render_zoom(1.0, 600.0, 600.0, 595.0, 842.0, SPDF_PRINT_RENDER_BYTE_CAP);
    double bytes = 595.0 * zoom * 842.0 * zoom * 4.0;

    g_assert_cmpfloat(zoom, <, 600.0 / 72.0);
    g_assert_cmpfloat(fabs(bytes - SPDF_PRINT_RENDER_BYTE_CAP), <, 1024.0);
    /* Under the cap: untouched. */
    zoom = spdf_print_render_zoom(1.0, 300.0, 300.0, 200.0, 200.0, SPDF_PRINT_RENDER_BYTE_CAP);
    g_assert_cmpfloat(fabs(zoom - 300.0 / 72.0), <, 1e-12);
    /* The cap may push below the 1.0 minimum for absurd sources — memory
     * correctness wins over the quality floor. */
    zoom = spdf_print_render_zoom(1.0, 300.0, 300.0, 30000.0, 30000.0, SPDF_PRINT_RENDER_BYTE_CAP);
    g_assert_cmpfloat(zoom, <, 1.0);
    g_assert_cmpfloat(zoom, >=, 0.05);
    g_assert_cmpfloat(30000.0 * zoom * 30000.0 * zoom * 4.0, <=, SPDF_PRINT_RENDER_BYTE_CAP + 1024.0);
}

static void test_render_zoom_dimension_cap(void) {
    /* A very long, skinny page trips the dimension cap before the byte cap:
     * 30000 pt tall at zoom 1 would be under the byte cap but over 16384 px. */
    double zoom = spdf_print_render_zoom(1.0, 72.0, 72.0, 100.0, 30000.0, SPDF_PRINT_RENDER_BYTE_CAP);

    g_assert_cmpfloat(30000.0 * zoom, <=, SPDF_PRINT_MAX_RENDER_DIMENSION + 0.5);
    /* Degenerate dpi input falls back to the floor, not garbage. */
    zoom = spdf_print_render_zoom(1.0, NAN, -5.0, 595.0, 842.0, 0.0);
    g_assert_cmpfloat(fabs(zoom - SPDF_PRINT_TARGET_DPI_FLOOR / 72.0), <, 1e-12);
}

static void test_render_zoom_permissions(void) {
    double zoom = spdf_print_render_zoom(1.0, 1200.0, 1200.0, 595.0, 842.0, 0.0);
    double restricted = spdf_print_permission_render_zoom(zoom, 1.0, FALSE);

    g_assert_cmpfloat(fabs(restricted - SPDF_PRINT_RESTRICTED_DPI / 72.0), <, 1e-12);
    g_assert_cmpfloat(spdf_print_permission_render_zoom(zoom, 1.0, TRUE), ==, zoom);
    g_assert_cmpfloat(spdf_print_permission_render_zoom(1.0, 1.0, FALSE), ==, 1.0);
    g_assert_cmpfloat(spdf_print_permission_render_zoom(zoom, 0.5, FALSE), ==, 0.5 * SPDF_PRINT_RESTRICTED_DPI / 72.0);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/print/clamp_custom_scale", test_clamp_custom_scale);
    g_test_add_func("/print/mode_scale", test_mode_scale);
    g_test_add_func("/print/dest_rect/fit_portrait", test_dest_rect_fit_portrait);
    g_test_add_func("/print/dest_rect/fit_landscape", test_dest_rect_fit_landscape);
    g_test_add_func("/print/dest_rect/actual_centered", test_dest_rect_actual_centered);
    g_test_add_func("/print/dest_rect/oversized_overflows", test_dest_rect_oversized_overflows);
    g_test_add_func("/print/dest_rect/minimum_size", test_dest_rect_minimum_size);
    g_test_add_func("/print/visible_source/fully_on_paper", test_visible_source_fully_on_paper);
    g_test_add_func("/print/visible_source/oversized_crops", test_visible_source_oversized_crops);
    g_test_add_func("/print/visible_source/custom_zoom", test_visible_source_custom_zoom_crops_scaled);
    g_test_add_func("/print/visible_source/degenerate", test_visible_source_degenerate);
    g_test_add_func("/print/render_zoom/dpi", test_render_zoom_dpi);
    g_test_add_func("/print/render_zoom/byte_cap", test_render_zoom_byte_cap);
    g_test_add_func("/print/render_zoom/dimension_cap", test_render_zoom_dimension_cap);
    g_test_add_func("/print/render_zoom/permissions", test_render_zoom_permissions);
    return g_test_run();
}
