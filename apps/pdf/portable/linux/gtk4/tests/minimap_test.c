/* Minimap strip-layout / viewport-mapping / strip-scroll / thumbnail-window
 * tests (spdf_minimap_internal.h). glib-only, exercising the exact shipping
 * logic like the other linux/gtk4 tests. */

#include <glib.h>

#include "spdf_minimap_internal.h"

#define WIDGET_W 126.0
#define USABLE (WIDGET_W - SPDF_MINIMAP_SIDE_INSET)

static SpdfPageSizePt* uniform_sizes(int count, double w, double h) {
    SpdfPageSizePt* sizes = g_new0(SpdfPageSizePt, count);
    for (int i = 0; i < count; ++i) {
        sizes[i].width = w;
        sizes[i].height = h;
    }
    return sizes;
}

/* --------------------------------------------------------------------------
 * Strip layout math. */

static void test_median_width(void) {
    SpdfPageSizePt odd[3] = {{300, 400}, {100, 200}, {200, 300}};
    SpdfPageSizePt even[4] = {{100, 100}, {400, 100}, {200, 100}, {300, 100}};
    g_assert_cmpfloat(spdf_minimap_median_width(odd, 3), ==, 200.0);
    g_assert_cmpfloat(spdf_minimap_median_width(even, 4), ==, 250.0);
    g_assert_cmpfloat(spdf_minimap_median_width(NULL, 0), ==, 0.0);
}

static void test_point_scale_uniform_fills_strip(void) {
    SpdfPageSizePt* sizes = uniform_sizes(5, 612.0, 792.0);
    double scale = spdf_minimap_point_scale(sizes, 5, USABLE);
    /* Uniform width: the widest page fills the usable strip exactly. */
    g_assert_cmpfloat_with_epsilon(scale * 612.0, USABLE, 1e-9);
    g_free(sizes);
}

static void test_point_scale_caps_outlier(void) {
    /* One giant sheet among letter pages: the scale derives from 2.5x the
     * median, not from the outlier, so normal pages stay readable. */
    SpdfPageSizePt sizes[5] = {{612, 792}, {612, 792}, {612, 792}, {612, 792}, {12000, 792}};
    double scale = spdf_minimap_point_scale(sizes, 5, USABLE);
    g_assert_cmpfloat_with_epsilon(scale, USABLE / (2.5 * 612.0), 1e-9);
    /* The normal pages then get usable/2.5 px of width. */
    g_assert_cmpfloat_with_epsilon(612.0 * scale, USABLE / 2.5, 1e-9);
}

static void test_strip_compute_geometry(void) {
    SpdfPageSizePt* sizes = uniform_sizes(3, 612.0, 792.0);
    SpdfMinimapStrip strip = {0};

    spdf_minimap_strip_compute(&strip, sizes, 3, WIDGET_W);
    g_assert_cmpint(strip.count, ==, 3);
    /* Aspect preserved: h/w == 792/612 per page. */
    for (int i = 0; i < 3; ++i) {
        g_assert_cmpfloat_with_epsilon(strip.rects[i].w, USABLE, 1e-9);
        g_assert_cmpfloat_with_epsilon(strip.rects[i].h, USABLE * 792.0 / 612.0, 1e-9);
        /* Centered horizontally. */
        g_assert_cmpfloat_with_epsilon(strip.rects[i].x, floor((WIDGET_W - strip.rects[i].w) * 0.5), 1e-9);
    }
    /* Rows stack with a 4px gap; content height matches the laid-out rects. */
    g_assert_cmpfloat_with_epsilon(strip.rects[1].y, strip.rects[0].h + SPDF_MINIMAP_GAP, 1e-9);
    g_assert_cmpfloat_with_epsilon(strip.content_h, 3.0 * strip.rects[0].h + 2.0 * SPDF_MINIMAP_GAP, 1e-9);
    spdf_minimap_strip_clear(&strip);
    g_free(sizes);
}

static void test_strip_compute_clamps_overwide_page(void) {
    /* The outlier page's displayed width is clamped to the usable strip and
     * its height follows the clamped width (aspect preserved). */
    SpdfPageSizePt sizes[5] = {{612, 792}, {612, 792}, {612, 792}, {612, 792}, {12000, 6000}};
    SpdfMinimapStrip strip = {0};

    spdf_minimap_strip_compute(&strip, sizes, 5, WIDGET_W);
    g_assert_cmpfloat_with_epsilon(strip.rects[4].w, USABLE, 1e-9);
    g_assert_cmpfloat_with_epsilon(strip.rects[4].h, USABLE * 6000.0 / 12000.0, 1e-9);
    spdf_minimap_strip_clear(&strip);
}

static void test_content_top(void) {
    /* Fits: centered. */
    g_assert_cmpfloat(spdf_minimap_content_top(100.0, 400.0, 0.0), ==, 150.0);
    /* Overflows: 8px pad at fraction 0, offset grows with the fraction. */
    g_assert_cmpfloat(spdf_minimap_content_top(1000.0, 416.0, 0.0), ==, SPDF_MINIMAP_TOP_PAD);
    g_assert_cmpfloat_with_epsilon(spdf_minimap_content_top(1000.0, 416.0, 1.0),
                                   SPDF_MINIMAP_TOP_PAD - (1000.0 - 400.0), 1e-9);
    g_assert_cmpfloat_with_epsilon(spdf_minimap_content_top(1000.0, 416.0, 0.5),
                                   SPDF_MINIMAP_TOP_PAD - 0.5 * (1000.0 - 400.0), 1e-9);
}

/* --------------------------------------------------------------------------
 * Visible-thumb range. */

static void test_visible_range(void) {
    SpdfPageSizePt* sizes = uniform_sizes(20, 612.0, 792.0);
    SpdfMinimapStrip strip = {0};
    int first = -1;
    int last = -1;
    double row;

    spdf_minimap_strip_compute(&strip, sizes, 20, WIDGET_W);
    row = strip.rects[0].h + SPDF_MINIMAP_GAP;

    /* A band over the first page only. */
    g_assert_true(spdf_minimap_strip_visible_range(&strip, 0.0, strip.rects[0].h * 0.5, &first, &last));
    g_assert_cmpint(first, ==, 0);
    g_assert_cmpint(last, ==, 0);

    /* A band from mid page 2 to mid page 5. */
    g_assert_true(spdf_minimap_strip_visible_range(&strip, 2.0 * row + 5.0, 5.0 * row + 5.0, &first, &last));
    g_assert_cmpint(first, ==, 2);
    g_assert_cmpint(last, ==, 5);

    /* A band past the end fails. */
    g_assert_false(
        spdf_minimap_strip_visible_range(&strip, strip.content_h + 10.0, strip.content_h + 20.0, &first, &last));
    spdf_minimap_strip_clear(&strip);
    g_free(sizes);
}

/* --------------------------------------------------------------------------
 * Viewport rect mapping (document space <-> strip space). */

static void doc_rows(const SpdfMinimapStrip* strip, double doc_scale, double gap, double** doc_y, double** doc_h) {
    /* Fabricate document rows proportional to the strip pages. */
    double y = 13.0;
    *doc_y = g_new0(double, strip->count);
    *doc_h = g_new0(double, strip->count);
    for (int i = 0; i < strip->count; ++i) {
        (*doc_y)[i] = y;
        (*doc_h)[i] = strip->rects[i].h * doc_scale;
        y += (*doc_h)[i] + gap;
    }
}

static void test_strip_y_document_y_round_trip(void) {
    SpdfPageSizePt* sizes = uniform_sizes(10, 612.0, 792.0);
    SpdfMinimapStrip strip = {0};
    double* doc_y;
    double* doc_h;

    spdf_minimap_strip_compute(&strip, sizes, 10, WIDGET_W);
    doc_rows(&strip, 6.0, 26.0, &doc_y, &doc_h);

    /* Mid page 3 maps to mid strip rect 3 and back. */
    {
        double doc_mid = doc_y[3] + doc_h[3] * 0.5;
        double strip_y = spdf_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 10, doc_mid);
        g_assert_cmpfloat_with_epsilon(strip_y, strip.rects[3].y + strip.rects[3].h * 0.5, 1e-6);
        g_assert_cmpfloat_with_epsilon(spdf_minimap_document_y_for_strip_y(&strip, doc_y, doc_h, 10, strip_y),
                                       doc_mid, 1e-6);
    }
    /* A document y in the gap between pages 4 and 5 lands in the strip gap. */
    {
        double doc_gap_mid = doc_y[4] + doc_h[4] + 13.0;
        double strip_y = spdf_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 10, doc_gap_mid);
        g_assert_cmpfloat(strip_y, >=, strip.rects[4].y + strip.rects[4].h);
        g_assert_cmpfloat(strip_y, <=, strip.rects[5].y);
    }
    /* Out-of-content clamps to the strip ends. */
    g_assert_cmpfloat(spdf_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 10, -100.0), ==, strip.rects[0].y);
    g_assert_cmpfloat(spdf_minimap_strip_y_for_document_y(&strip, doc_y, doc_h, 10, 1e9), ==,
                      strip.rects[9].y + strip.rects[9].h);

    g_free(doc_y);
    g_free(doc_h);
    spdf_minimap_strip_clear(&strip);
    g_free(sizes);
}

static void test_viewport_rect(void) {
    SpdfPageSizePt* sizes = uniform_sizes(10, 612.0, 792.0);
    SpdfMinimapStrip strip = {0};
    double* doc_y;
    double* doc_h;
    double* doc_x;
    double* doc_w;
    double x;
    double y;
    double w;
    double h;
    double full_x;
    double full_w;

    spdf_minimap_strip_compute(&strip, sizes, 10, WIDGET_W);
    doc_rows(&strip, 6.0, 26.0, &doc_y, &doc_h);
    doc_x = g_new0(double, 10);
    doc_w = g_new0(double, 10);
    for (int i = 0; i < 10; ++i) {
        doc_x[i] = 40.0;
        doc_w[i] = strip.rects[i].w * 6.0;
    }

    /* Viewport covering exactly page 2, full page width visible: maps to
     * (about) strip rect 2, width = the page's strip rect inset by -2 (Mac
     * union-of-miniRects model). */
    spdf_minimap_viewport_rect(&strip, doc_x, doc_y, doc_w, doc_h, 10, doc_x[2] - 10.0, doc_y[2], doc_w[2] + 20.0,
                               doc_h[2], WIDGET_W, &x, &y, &w, &h);
    g_assert_cmpfloat_with_epsilon(x, MAX(0.0, strip.rects[2].x - 2.0), 1e-6);
    g_assert_cmpfloat_with_epsilon(w, strip.rects[2].w + 4.0, 1e-6);
    g_assert_cmpfloat_with_epsilon(y, strip.rects[2].y, 1e-6);
    g_assert_cmpfloat_with_epsilon(h, strip.rects[2].h, 1e-6);
    full_x = x;
    full_w = w;

    /* Zoomed in: only the middle half of the page width is visible — the
     * indicator narrows accordingly (the user-reported GTK4 bug kept it
     * full-width at every zoom). */
    spdf_minimap_viewport_rect(&strip, doc_x, doc_y, doc_w, doc_h, 10, doc_x[2] + doc_w[2] * 0.25, doc_y[2],
                               doc_w[2] * 0.5, doc_h[2], WIDGET_W, &x, &y, &w, &h);
    g_assert_cmpfloat(w, <, full_w);
    g_assert_cmpfloat_with_epsilon(w, strip.rects[2].w * 0.5 + 4.0, 1e-6);
    g_assert_cmpfloat(x, >, full_x);
    g_assert_cmpfloat_with_epsilon(x, strip.rects[2].x + strip.rects[2].w * 0.25 - 2.0, 1e-6);

    /* Without horizontal info the full-width fallback band survives. */
    spdf_minimap_viewport_rect(&strip, NULL, doc_y, NULL, doc_h, 10, 0.0, doc_y[2], 0.0, doc_h[2], WIDGET_W, &x,
                               &y, &w, &h);
    g_assert_cmpfloat(x, ==, 5.0);
    g_assert_cmpfloat(w, ==, WIDGET_W - 10.0);

    /* A sliver of a viewport keeps the 10px minimum height. */
    spdf_minimap_viewport_rect(&strip, doc_x, doc_y, doc_w, doc_h, 10, doc_x[0], doc_y[0], doc_w[0], 1.0, WIDGET_W,
                               NULL, &y, NULL, &h);
    g_assert_cmpfloat(h, >=, 10.0);

    g_free(doc_x);
    g_free(doc_w);
    g_free(doc_y);
    g_free(doc_h);
    spdf_minimap_strip_clear(&strip);
    g_free(sizes);
}

/* --------------------------------------------------------------------------
 * Search-marker y position. */

static void test_marker_y(void) {
    SpdfPageRect rect = {10.0, 100.0, 90.0, 120.0};
    /* Center of the page -> tick centered on the rect midline. */
    g_assert_cmpfloat_with_epsilon(spdf_minimap_marker_y(&rect, 396.0, 792.0, 3.0), 100.0 + 60.0 - 1.5, 1e-9);
    /* Top edge pins inside the rect. */
    g_assert_cmpfloat(spdf_minimap_marker_y(&rect, 0.0, 792.0, 3.0), ==, 100.0);
    /* Bottom edge pins so the tick stays fully inside. */
    g_assert_cmpfloat(spdf_minimap_marker_y(&rect, 792.0, 792.0, 3.0), ==, 100.0 + 120.0 - 3.0);
    /* Out-of-range fractions clamp. */
    g_assert_cmpfloat(spdf_minimap_marker_y(&rect, -50.0, 792.0, 3.0), ==, 100.0);
    g_assert_cmpfloat(spdf_minimap_marker_y(&rect, 9999.0, 792.0, 3.0), ==, 100.0 + 120.0 - 3.0);
}

/* --------------------------------------------------------------------------
 * Strip-scroll model (Mac db9515802). */

static void test_strip_scroll_overflowing_strip(void) {
    /* strip: 2000px content in a 400px lane; document: 90000px in a 900px
     * viewport. maxStrip = 1600, maxDoc = 89100 -> ratio 55.6875. */
    double ratio = (90000.0 - 900.0) / (2000.0 - 400.0);
    g_assert_cmpfloat_with_epsilon(spdf_minimap_document_delta_for_strip_scroll(10.0, 2000.0, 400.0, 90000.0, 900.0),
                                   10.0 * ratio, 1e-9);
    /* The full strip travel traverses the full document. */
    g_assert_cmpfloat_with_epsilon(
        spdf_minimap_document_top_for_strip_scroll(0.0, 1600.0, 2000.0, 400.0, 90000.0, 900.0), 89100.0, 1e-6);
}

static void test_strip_scroll_fitting_strip_falls_back(void) {
    /* Strip fits its lane: scale falls back to docHeight/contentHeight. */
    g_assert_cmpfloat_with_epsilon(spdf_minimap_document_delta_for_strip_scroll(10.0, 300.0, 400.0, 9000.0, 900.0),
                                   10.0 * 9000.0 / 300.0, 1e-9);
}

static void test_strip_scroll_clamps(void) {
    g_assert_cmpfloat(spdf_minimap_document_top_for_strip_scroll(50.0, -10000.0, 2000.0, 400.0, 90000.0, 900.0), ==,
                      0.0);
    g_assert_cmpfloat(spdf_minimap_document_top_for_strip_scroll(89000.0, 10000.0, 2000.0, 400.0, 90000.0, 900.0),
                      ==, 89100.0);
    /* No scrollable document: no movement. */
    g_assert_cmpfloat(spdf_minimap_document_delta_for_strip_scroll(10.0, 2000.0, 400.0, 900.0, 900.0), ==, 0.0);
}

static void test_discrete_wheel_page_stride_cap(void) {
    const double doc_y[] = {20.0, 740.0, 1760.0};
    const double doc_h[] = {700.0, 1000.0, 500.0};
    const double doc_height = 10000.0;
    const double visible_height = 800.0;

    g_assert_cmpfloat(spdf_minimap_directional_page_stride(1, 5000.0, doc_y, doc_h, 3), ==, 1020.0);
    g_assert_cmpfloat(spdf_minimap_directional_page_stride(1, -5000.0, doc_y, doc_h, 3), ==, 720.0);
    g_assert_cmpfloat(spdf_minimap_directional_page_stride(2, 5000.0, doc_y, doc_h, 3), ==, 500.0);
    g_assert_cmpfloat(spdf_minimap_document_top_capped_for_discrete_wheel(4000.0, 9000.0, 1, doc_y, doc_h, 3,
                                                                          doc_height, visible_height),
                      ==, 5020.0);
    g_assert_cmpfloat(spdf_minimap_document_top_capped_for_discrete_wheel(4000.0, 0.0, 1, doc_y, doc_h, 3, doc_height,
                                                                          visible_height),
                      ==, 3280.0);
    g_assert_cmpfloat(spdf_minimap_document_top_capped_for_discrete_wheel(4000.0, 4400.0, 1, doc_y, doc_h, 3,
                                                                          doc_height, visible_height),
                      ==, 4400.0);
    g_assert_cmpfloat(spdf_minimap_document_top_capped_for_discrete_wheel(9000.0, 9900.0, 2, doc_y, doc_h, 3,
                                                                          doc_height, visible_height),
                      ==, 9200.0);
}

/* --------------------------------------------------------------------------
 * Kinetic strip-scroll momentum (GtkKineticScrolling decay model). */

static void test_kinetic_step_decay(void) {
    /* One 16ms frame at 600 px/s: velocity decays by exp(-4*0.016), distance
     * is the closed-form integral of the decaying velocity. */
    double v = 600.0;
    double exp_part = exp(-SPDF_MINIMAP_KINETIC_FRICTION * 0.016);
    double delta = spdf_minimap_kinetic_step(&v, 0.016);
    g_assert_cmpfloat_with_epsilon(delta, (1.0 - exp_part) * 600.0 / SPDF_MINIMAP_KINETIC_FRICTION, 1e-9);
    g_assert_cmpfloat_with_epsilon(v, 600.0 * exp_part, 1e-9);
    /* Degenerate dt: nothing moves, nothing decays. */
    g_assert_cmpfloat(spdf_minimap_kinetic_step(&v, 0.0), ==, 0.0);
    g_assert_cmpfloat(spdf_minimap_kinetic_step(&v, -1.0), ==, 0.0);
    g_assert_cmpfloat(spdf_minimap_kinetic_step(NULL, 0.016), ==, 0.0);
}

static void test_kinetic_total_travel(void) {
    /* Integrated to exhaustion the tail covers v0/friction — a 1600 px/s
     * flick travels ~400 strip px, i.e. a whole strip lane, matching the
     * "flick traverses the whole document" release note when fed through the
     * maxDoc/maxStrip strip-scroll model. Frame-size independence: many
     * small steps sum to the same closed form. */
    double v = 1600.0;
    double total = 0.0;
    int frames = 0;
    while (!spdf_minimap_kinetic_done(v) && frames < 10000) {
        total += spdf_minimap_kinetic_step(&v, 1.0 / 120.0);
        frames++;
    }
    g_assert_cmpfloat_with_epsilon(total, 1600.0 / SPDF_MINIMAP_KINETIC_FRICTION, 1.0);
    /* Sign follows the velocity. */
    v = -1600.0;
    g_assert_cmpfloat(spdf_minimap_kinetic_step(&v, 0.016), <, 0.0);
}

static void test_kinetic_duration(void) {
    /* The 1 px/s stop threshold ends a typical flick after ~1.5s (GTK feel:
     * ln(v0)/friction seconds), and momentum-worthy velocities survive the
     * done check while sub-threshold ones never start. */
    double v = 400.0;
    double t = 0.0;
    while (!spdf_minimap_kinetic_done(v)) {
        spdf_minimap_kinetic_step(&v, 1.0 / 60.0);
        t += 1.0 / 60.0;
    }
    g_assert_cmpfloat(t, >, 1.3);
    g_assert_cmpfloat(t, <, 1.7);
    g_assert_true(spdf_minimap_kinetic_done(0.5));
    g_assert_true(spdf_minimap_kinetic_done(-0.5));
    g_assert_false(spdf_minimap_kinetic_done(-30.0));
}

/* --------------------------------------------------------------------------
 * Bounded thumbnail window. */

static void test_thumb_window_initial(void) {
    SpdfMinimapThumbWindow window =
        spdf_minimap_thumb_window_for_visible_range(500, 100, 110, spdf_minimap_thumb_window_empty());
    g_assert_cmpint(window.start, ==, 100 - SPDF_MINIMAP_WINDOW_EXTRA_PAGES);
    g_assert_cmpint(window.end, ==, 110 + SPDF_MINIMAP_WINDOW_EXTRA_PAGES);
    /* Clamped at the document edges. */
    window = spdf_minimap_thumb_window_for_visible_range(500, 0, 5, spdf_minimap_thumb_window_empty());
    g_assert_cmpint(window.start, ==, 0);
    window = spdf_minimap_thumb_window_for_visible_range(500, 495, 499, spdf_minimap_thumb_window_empty());
    g_assert_cmpint(window.end, ==, 499);
    /* Empty documents yield the empty window. */
    g_assert_false(spdf_minimap_thumb_window_valid(
        spdf_minimap_thumb_window_for_visible_range(0, 0, 0, spdf_minimap_thumb_window_empty())));
}

static void test_thumb_window_hysteresis(void) {
    SpdfMinimapThumbWindow previous =
        spdf_minimap_thumb_window_for_visible_range(500, 100, 110, spdf_minimap_thumb_window_empty());
    SpdfMinimapThumbWindow kept;
    SpdfMinimapThumbWindow recentered;

    /* Drifting a few pages keeps the previous window (no re-render churn). */
    kept = spdf_minimap_thumb_window_for_visible_range(500, 105, 115, previous);
    g_assert_cmpint(kept.start, ==, previous.start);
    g_assert_cmpint(kept.end, ==, previous.end);

    /* Crossing the recenter margin rebuilds around the new range. */
    recentered = spdf_minimap_thumb_window_for_visible_range(500, 130, 140, previous);
    g_assert_cmpint(recentered.start, ==, 100);
    g_assert_cmpint(recentered.end, ==, 170);

    /* A previous window from a longer document is discarded. */
    recentered = spdf_minimap_thumb_window_for_visible_range(50, 10, 12, previous);
    g_assert_cmpint(recentered.start, ==, 0);
    g_assert_cmpint(recentered.end, ==, 42);
}

static void test_thumb_window_evict(void) {
    SpdfMinimapThumbWindow window;
    window.start = 100;
    window.end = 140;
    g_assert_false(spdf_minimap_thumb_window_should_evict(window, 120));
    g_assert_false(
        spdf_minimap_thumb_window_should_evict(window, 100 - SPDF_MINIMAP_WINDOW_EVICT_SLACK_PAGES));
    g_assert_true(
        spdf_minimap_thumb_window_should_evict(window, 100 - SPDF_MINIMAP_WINDOW_EVICT_SLACK_PAGES - 1));
    g_assert_true(
        spdf_minimap_thumb_window_should_evict(window, 140 + SPDF_MINIMAP_WINDOW_EVICT_SLACK_PAGES + 1));
    g_assert_false(spdf_minimap_thumb_window_should_evict(spdf_minimap_thumb_window_empty(), 5));
}

/* --------------------------------------------------------------------------
 * Long-document drag + page hit. */

static void test_long_document_drag(void) {
    SpdfPageSizePt* short_doc = uniform_sizes(20, 612.0, 792.0);  /* 15840pt: below threshold */
    SpdfPageSizePt* long_doc = uniform_sizes(21, 612.0, 792.0);   /* 16632pt: above */
    g_assert_false(spdf_minimap_use_long_document_drag(short_doc, 20));
    g_assert_true(spdf_minimap_use_long_document_drag(long_doc, 21));
    g_free(short_doc);
    g_free(long_doc);

    /* Slow drags move at the page-count fine scale; fast drags approach 1:1. */
    g_assert_cmpfloat_with_epsilon(spdf_minimap_long_drag_scale(1.0, 1.0 / 60.0, 100), 0.30, 1e-9);
    g_assert_cmpfloat_with_epsilon(spdf_minimap_long_drag_scale(1.0, 1.0 / 60.0, 21),
                                   CLAMP(20.0 / 21.0, 0.30, 0.72), 1e-9);
    g_assert_cmpfloat_with_epsilon(spdf_minimap_long_drag_scale(100.0, 1.0 / 60.0, 100), 1.0, 1e-9);

    /* Thumb sized against the track, never collapsing the drag range. */
    g_assert_cmpfloat_with_epsilon(spdf_minimap_drag_thumb_height(900.0, 90000.0, 400.0), 10.0, 1e-9);
    g_assert_cmpfloat_with_epsilon(spdf_minimap_drag_thumb_height(45000.0, 90000.0, 400.0), 200.0, 1e-9);
    g_assert_cmpfloat(spdf_minimap_drag_thumb_height(900.0, 900.0, 400.0), ==, 400.0);
}

static void test_page_hit(void) {
    SpdfPageSizePt* sizes = uniform_sizes(5, 612.0, 792.0);
    SpdfMinimapStrip strip = {0};
    int page = -1;
    double x_fraction = -1.0;
    double y_fraction = -1.0;

    spdf_minimap_strip_compute(&strip, sizes, 5, WIDGET_W);
    /* Center of page 2. */
    g_assert_true(spdf_minimap_page_hit(&strip, strip.rects[2].x + strip.rects[2].w * 0.25,
                                        strip.rects[2].y + strip.rects[2].h * 0.5, &page, &x_fraction, &y_fraction));
    g_assert_cmpint(page, ==, 2);
    g_assert_cmpfloat_with_epsilon(x_fraction, 0.25, 1e-9);
    g_assert_cmpfloat_with_epsilon(y_fraction, 0.5, 1e-9);
    /* A point in a gap misses. */
    g_assert_false(
        spdf_minimap_page_hit(&strip, 20.0, strip.rects[0].y + strip.rects[0].h + SPDF_MINIMAP_GAP * 0.5, &page,
                              NULL, NULL));
    /* X outside the rect clamps its fraction. */
    g_assert_true(spdf_minimap_page_hit(&strip, -50.0, strip.rects[0].y + 1.0, &page, &x_fraction, NULL));
    g_assert_cmpfloat(x_fraction, ==, 0.0);
    spdf_minimap_strip_clear(&strip);
    g_free(sizes);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/minimap/median-width", test_median_width);
    g_test_add_func("/minimap/point-scale-uniform", test_point_scale_uniform_fills_strip);
    g_test_add_func("/minimap/point-scale-outlier-cap", test_point_scale_caps_outlier);
    g_test_add_func("/minimap/strip-geometry", test_strip_compute_geometry);
    g_test_add_func("/minimap/strip-overwide-clamp", test_strip_compute_clamps_overwide_page);
    g_test_add_func("/minimap/content-top", test_content_top);
    g_test_add_func("/minimap/visible-range", test_visible_range);
    g_test_add_func("/minimap/strip-doc-round-trip", test_strip_y_document_y_round_trip);
    g_test_add_func("/minimap/viewport-rect", test_viewport_rect);
    g_test_add_func("/minimap/marker-y", test_marker_y);
    g_test_add_func("/minimap/strip-scroll-overflow", test_strip_scroll_overflowing_strip);
    g_test_add_func("/minimap/strip-scroll-fallback", test_strip_scroll_fitting_strip_falls_back);
    g_test_add_func("/minimap/strip-scroll-clamps", test_strip_scroll_clamps);
    g_test_add_func("/minimap/discrete-wheel-page-stride-cap", test_discrete_wheel_page_stride_cap);
    g_test_add_func("/minimap/kinetic-step-decay", test_kinetic_step_decay);
    g_test_add_func("/minimap/kinetic-total-travel", test_kinetic_total_travel);
    g_test_add_func("/minimap/kinetic-duration", test_kinetic_duration);
    g_test_add_func("/minimap/thumb-window-initial", test_thumb_window_initial);
    g_test_add_func("/minimap/thumb-window-hysteresis", test_thumb_window_hysteresis);
    g_test_add_func("/minimap/thumb-window-evict", test_thumb_window_evict);
    g_test_add_func("/minimap/long-document-drag", test_long_document_drag);
    g_test_add_func("/minimap/page-hit", test_page_hit);
    return g_test_run();
}
