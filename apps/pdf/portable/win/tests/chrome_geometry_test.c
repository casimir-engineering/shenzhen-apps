/* chrome_geometry_test.c — pins portable/win/src/spdf_win_chrome.h.
 *
 * The chrome's division of the client area has no GTK4 original to
 * differentially test against (the GTK frontend's chrome is built from real GTK
 * widgets, not from arithmetic), so this suite pins the invariants the division
 * must have plus the specific macOS metrics.
 *
 * The invariants matter more than the numbers. The layer's first integration bug
 * was a WIDTH bug -- the chrome was laid out against the canvas region it had
 * just produced instead of against the window, and drew the whole window's
 * furniture into the left half of itself. What made that possible is that
 * `spdf_win_canvas_build_scene()` overwrites `scene->target_px_w` with the
 * canvas viewport, so the value meant two different things either side of one
 * call. Geometry alone could not catch it -- hence the tiling and
 * exact-cover checks below, which at least guarantee that WHATEVER width is
 * passed in is fully accounted for by the rects that come out.
 *
 * Header-only under test, so no `spdf-test-sources` line is needed.
 */
#include "spdf_win_chrome.h"

#include <stdio.h>
#include <string.h>
#include <wchar.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                            \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQF(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (fabsf((float)(a) - (float)(b)) > 0.001f) {                                                                 \
            fprintf(stderr, "FAIL %s == %s (%.4f vs %.4f) (%s:%d)\n", #a, #b, (double)(a), (double)(b), __FILE__,       \
                    __LINE__);                                                                                         \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static SpdfWinChromeModel default_model(void) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.selected_tab = -1;
    return m;
}

/* --- the metrics are macOS's ------------------------------------------- */
static void test_metrics(void) {
    CHECK_EQF(SPDF_WIN_CHROME_TABSTRIP_H, 42.0);
    CHECK_EQF(SPDF_WIN_CHROME_TOOLBAR_H, 42.0);
    CHECK_EQF(SPDF_WIN_CHROME_SIDEBAR_W, 240.0);
    CHECK_EQF(SPDF_WIN_CHROME_SIDEBAR_MIN_W, 176.0);
    CHECK_EQF(SPDF_WIN_CHROME_SIDEBAR_MAX_W, 320.0);
    CHECK_EQF(SPDF_WIN_CHROME_MINIMAP_W, 126.5);
    CHECK_EQF(SPDF_WIN_CHROME_MINIMAP_MIN_W, 72.0);
    CHECK_EQF(SPDF_WIN_CHROME_MINIMAP_MAX_W, 260.0);
    CHECK_EQF(SPDF_WIN_CHROME_DIVIDER_W, 5.0);
    CHECK_EQF(SPDF_WIN_CHROME_DEFAULT_CONTENT_W, 1120.0);
    CHECK_EQF(SPDF_WIN_CHROME_DEFAULT_CONTENT_H, 800.0);
    CHECK_EQF(SPDF_WIN_CHROME_MIN_CONTENT_W, 560.0);
    CHECK_EQF(SPDF_WIN_CHROME_MIN_CONTENT_H, 380.0);
}

/* --- THE EXACT-COVER INVARIANT ------------------------------------------
 * Left to right, the split row's rects must tile the client width with no gap
 * and no overlap; top to bottom, the bands plus the split row must tile the
 * height. This is the check that would have caught the width bug. */
static void check_tiling(const SpdfWinChromeLayout* l, unsigned w, unsigned h, const char* what) {
    float sum = 0.0f;
    float split_top = 0.0f;
    (void)what;

    if (!spdf_win_chrome_rect_empty(l->tabstrip)) {
        CHECK_EQF(l->tabstrip.x, 0.0f);
        CHECK_EQF(l->tabstrip.w, (float)w);
        CHECK_EQF(l->tabstrip.y, 0.0f);
        split_top += l->tabstrip.h;
        /* THE CAPTION RESERVE rides on the strip: same height, flush with the
         * trailing edge, exactly the three buttons wide, and INSIDE the strip
         * rather than beside it -- the band and its hairline are still the
         * strip's. A strip narrower than the reserve has no reserve at all. */
        if (!spdf_win_chrome_rect_empty(l->caption)) {
            CHECK_EQF(l->caption.y, 0.0f);
            CHECK_EQF(l->caption.h, l->tabstrip.h);
            CHECK_EQF(l->caption.x + l->caption.w, (float)w);
            CHECK_EQF(l->caption.w, spdf_win_chrome_px(SPDF_WIN_TABSTRIP_TRAILING_INSET, l->dpi_scale));
            CHECK(l->caption.x >= 0.0f);
        } else {
            CHECK((float)w < spdf_win_chrome_px(SPDF_WIN_TABSTRIP_TRAILING_INSET, l->dpi_scale));
        }
    } else {
        /* No strip, no caption buttons: presentation mode is fullscreen-like. */
        CHECK(spdf_win_chrome_rect_empty(l->caption));
    }
    if (!spdf_win_chrome_rect_empty(l->toolbar)) {
        CHECK_EQF(l->toolbar.x, 0.0f);
        CHECK_EQF(l->toolbar.w, (float)w);
        CHECK_EQF(l->toolbar.y, split_top);
        split_top += l->toolbar.h;
    }

    /* Every split-row rect starts at the same y. The panels and dividers span
     * the full split height; the canvas and its VERTICAL scroller lose the
     * horizontal scroller's band when there is one, which is exactly why they
     * are checked separately below rather than lumped in here. */
    {
        const SpdfWinChromeRect* panel[4];
        int i;
        panel[0] = &l->sidebar;
        panel[1] = &l->sidebar_divider;
        panel[2] = &l->minimap_divider;
        panel[3] = &l->minimap;
        for (i = 0; i < 4; ++i) {
            if (spdf_win_chrome_rect_empty(*panel[i])) continue;
            CHECK_EQF(panel[i]->y, split_top);
            CHECK_EQF(panel[i]->h, (float)h - split_top);
            sum += panel[i]->w;
        }
        /* The canvas region: canvas + vertical scroller side by side. */
        sum += l->canvas.w;
        if (!spdf_win_chrome_rect_empty(l->vscroll)) sum += l->vscroll.w;
        CHECK_EQF(l->canvas.y, split_top);
    }
    /* Exact cover of the width, scrollers included. */
    CHECK_EQF(sum, (float)w);

    /* And of the canvas region's HEIGHT: canvas + horizontal scroller. */
    {
        float vsum = l->canvas.h;
        if (!spdf_win_chrome_rect_empty(l->hscroll)) vsum += l->hscroll.h;
        CHECK_EQF(vsum, (float)h - split_top);
        if (!spdf_win_chrome_rect_empty(l->vscroll)) {
            /* The vertical trough must stop where the horizontal one starts, or
             * the two fight over the corner pixel. */
            CHECK_EQF(l->vscroll.y, split_top);
            CHECK_EQF(l->vscroll.h, l->canvas.h);
            CHECK_EQF(l->vscroll.x, l->canvas.x + l->canvas.w);
        }
        if (!spdf_win_chrome_rect_empty(l->hscroll)) {
            CHECK_EQF(l->hscroll.x, l->canvas.x);
            CHECK_EQF(l->hscroll.w, l->canvas.w);
            CHECK_EQF(l->hscroll.y, l->canvas.y + l->canvas.h);
        }
    }

    /* Strict left-to-right order, and no overlap. */
    if (!spdf_win_chrome_rect_empty(l->sidebar)) {
        CHECK(l->sidebar.x == 0.0f);
        CHECK(l->sidebar_divider.x >= l->sidebar.x + l->sidebar.w);
        CHECK(l->canvas.x >= l->sidebar_divider.x + l->sidebar_divider.w);
    } else {
        CHECK(spdf_win_chrome_rect_empty(l->sidebar_divider));
        CHECK_EQF(l->canvas.x, 0.0f);
    }
    if (!spdf_win_chrome_rect_empty(l->minimap)) {
        /* Past the canvas AND its vertical scroller. */
        CHECK(l->minimap_divider.x >= l->canvas.x + l->canvas.w + l->vscroll.w);
        CHECK(l->minimap.x >= l->minimap_divider.x + l->minimap_divider.w);
        CHECK_EQF(l->minimap.x + l->minimap.w, (float)w);
    } else {
        CHECK(spdf_win_chrome_rect_empty(l->minimap_divider));
        CHECK_EQF(l->canvas.x + l->canvas.w + l->vscroll.w, (float)w);
    }
}

static void test_tiling_across_sizes(void) {
    float scales[] = {1.0f, 1.25f, 1.5f, 2.0f};
    unsigned widths[] = {400, 560, 800, 1120, 1680, 2560, 3840};
    unsigned heights[] = {300, 380, 600, 800, 1440};
    size_t si, wi, hi;
    SpdfWinChromeModel m = default_model();

    for (si = 0; si < sizeof(scales) / sizeof(scales[0]); ++si) {
        for (wi = 0; wi < sizeof(widths) / sizeof(widths[0]); ++wi) {
            for (hi = 0; hi < sizeof(heights) / sizeof(heights[0]); ++hi) {
                SpdfWinChromeLayout l;
                spdf_win_chrome_layout(&m, widths[wi], heights[hi], scales[si], &l);
                check_tiling(&l, widths[wi], heights[hi], "both panels");
                /* The canvas must never vanish entirely, whatever the window. */
                CHECK(l.canvas.w > 0.0f);
                CHECK(l.canvas.h > 0.0f);
            }
        }
    }

    /* Same, with each panel hidden in turn and with both hidden. */
    {
        int sb, mm;
        for (sb = 0; sb <= 1; ++sb) {
            for (mm = 0; mm <= 1; ++mm) {
                SpdfWinChromeLayout l;
                SpdfWinChromeModel m2 = default_model();
                m2.show_sidebar = sb;
                m2.show_minimap = mm;
                spdf_win_chrome_layout(&m2, 1120, 800, 1.5f, &l);
                check_tiling(&l, 1120, 800, "panel combination");
                if (!sb) CHECK(spdf_win_chrome_rect_empty(l.sidebar));
                if (!mm) CHECK(spdf_win_chrome_rect_empty(l.minimap));
            }
        }
    }
}

/* --- the macOS default window, at 1x, has macOS's numbers -------------- */
static void test_default_window_1x(void) {
    SpdfWinChromeModel m = default_model();
    SpdfWinChromeLayout l;
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);

    CHECK_EQF(l.tabstrip.h, 42.0f);
    /* Three Windows 11 caption buttons at 46 px: 138, macOS's own windowed
     * traffic-light reserve mirrored to the trailing end. */
    CHECK_EQF(l.caption.w, 138.0f);
    CHECK_EQF(l.caption.x, 1120.0f - 138.0f);
    CHECK_EQF(l.caption.h, 42.0f);
    CHECK_EQF(l.toolbar.h, 42.0f);
    CHECK_EQF(l.toolbar.y, 42.0f);
    CHECK_EQF(l.sidebar.y, 84.0f);
    CHECK_EQF(l.sidebar.h, 800.0f - 84.0f);
    /* 240 is under 0.34 * 1120 = 380.8, so the default survives the clamp. */
    CHECK_EQF(l.sidebar.w, 240.0f);
    CHECK_EQF(l.sidebar_divider.w, 5.0f);
    /* 126.5 rounds to 127 whole device pixels at 1x. */
    CHECK_EQF(l.minimap.w, 127.0f);
    CHECK_EQF(l.minimap_divider.w, 5.0f);
    /* ...less the vertical scroller, which lives INSIDE the canvas region and
     * is always present (macOS never autohides its scrollers). */
    CHECK_EQF(l.vscroll.w, 15.0f);
    CHECK_EQF(l.canvas.w, 1120.0f - 240.0f - 5.0f - 5.0f - 127.0f - 15.0f);
    /* No horizontal trough: the default model reports the content does not
     * overflow horizontally, so there is nothing to scroll. */
    CHECK(spdf_win_chrome_rect_empty(l.hscroll));
    CHECK_EQF(l.canvas.h, 800.0f - 84.0f);
    check_tiling(&l, 1120, 800, "default 1x");

    /* With horizontal overflow the trough appears, takes 15 pt off the canvas's
     * height, and shortens the vertical trough so the two do not meet. */
    {
        SpdfWinChromeModel m2 = default_model();
        SpdfWinChromeLayout l2;
        m2.h_scrollable = 1;
        spdf_win_chrome_layout(&m2, 1120, 800, 1.0f, &l2);
        CHECK_EQF(l2.hscroll.h, 15.0f);
        CHECK_EQF(l2.canvas.h, 800.0f - 84.0f - 15.0f);
        CHECK_EQF(l2.vscroll.h, l2.canvas.h);
        check_tiling(&l2, 1120, 800, "default 1x, h-scrollable");
    }
}

/* --- DPI: every band is a whole number of device pixels ---------------- */
static void test_whole_pixels(void) {
    float scales[] = {1.0f, 1.25f, 1.5f, 1.75f, 2.0f, 2.5f, 3.0f};
    size_t i;
    SpdfWinChromeModel m = default_model();
    for (i = 0; i < sizeof(scales) / sizeof(scales[0]); ++i) {
        SpdfWinChromeLayout l;
        const SpdfWinChromeRect* all[8];
        int k;
        spdf_win_chrome_layout(&m, 1600, 1000, scales[i], &l);
        all[0] = &l.tabstrip;
        all[1] = &l.toolbar;
        all[2] = &l.sidebar;
        all[3] = &l.sidebar_divider;
        all[4] = &l.canvas;
        all[5] = &l.minimap_divider;
        all[6] = &l.minimap;
        all[7] = &l.caption;
        for (k = 0; k < 8; ++k) {
            /* A fractional edge puts a 1 px separator across two rows -- the
             * defect the dark page border already hit at 150%. */
            CHECK_EQF(all[k]->x, floorf(all[k]->x));
            CHECK_EQF(all[k]->y, floorf(all[k]->y));
            CHECK_EQF(all[k]->w, floorf(all[k]->w));
            CHECK_EQF(all[k]->h, floorf(all[k]->h));
        }
        /* 42 pt scales linearly and lands whole. */
        CHECK_EQF(l.tabstrip.h, floorf(42.0f * scales[i] + 0.5f));
    }
}

/* --- presentation mode collapses both bands ---------------------------- */
static void test_presentation(void) {
    SpdfWinChromeModel m = default_model();
    SpdfWinChromeLayout l;
    m.presentation = 1;
    spdf_win_chrome_layout(&m, 1120, 800, 1.5f, &l);
    CHECK(spdf_win_chrome_rect_empty(l.tabstrip));
    CHECK(spdf_win_chrome_rect_empty(l.caption));
    CHECK(spdf_win_chrome_rect_empty(l.toolbar));
    CHECK_EQF(l.canvas.y, 0.0f);
    CHECK_EQF(l.canvas.h, 800.0f);
    check_tiling(&l, 1120, 800, "presentation");
}

/* --- clamps match macOS's ---------------------------------------------- */
static void test_clamps(void) {
    /* Default when asked for 0. */
    CHECK_EQF(spdf_win_chrome_clamp_sidebar_pt(0.0f, 1120.0f, 0), 240.0f);
    /* Below the minimum is raised. */
    CHECK_EQF(spdf_win_chrome_clamp_sidebar_pt(50.0f, 1120.0f, 0), 176.0f);
    /* Search mode raises the minimum to 216. */
    CHECK_EQF(spdf_win_chrome_clamp_sidebar_pt(50.0f, 1120.0f, 1), 216.0f);
    /* Above the maximum is lowered. */
    CHECK_EQF(spdf_win_chrome_clamp_sidebar_pt(900.0f, 4000.0f, 0), 320.0f);
    /* The 0.34 fraction binds on a narrow window: 0.34 * 600 = 204. */
    CHECK_EQF(spdf_win_chrome_clamp_sidebar_pt(300.0f, 600.0f, 0), 204.0f);
    /* When the fraction falls below the minimum, the minimum wins -- so a
     * narrow window keeps a usable sidebar rather than a sliver. */
    CHECK_EQF(spdf_win_chrome_clamp_sidebar_pt(300.0f, 400.0f, 0), 176.0f);

    CHECK_EQF(spdf_win_chrome_clamp_minimap_pt(0.0f, 1120.0f), 126.5f);
    CHECK_EQF(spdf_win_chrome_clamp_minimap_pt(10.0f, 1120.0f), 72.0f);
    CHECK_EQF(spdf_win_chrome_clamp_minimap_pt(9000.0f, 4000.0f), 260.0f);
}

/* --- hit testing ------------------------------------------------------- */
static void test_hit(void) {
    SpdfWinChromeModel m = default_model();
    SpdfWinChromeLayout l;
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);

    CHECK(spdf_win_chrome_hit(&l, 500.0f, 10.0f) == SPDF_WIN_CHROME_TABSTRIP);
    CHECK(spdf_win_chrome_hit(&l, 500.0f, 60.0f) == SPDF_WIN_CHROME_TOOLBAR);
    /* The caption reserve wins over the strip that contains it, edge to edge
     * and the full strip height; one pixel left of it is strip again. */
    CHECK(spdf_win_chrome_hit(&l, l.caption.x, 0.0f) == SPDF_WIN_CHROME_CAPTION);
    CHECK(spdf_win_chrome_hit(&l, l.caption.x + l.caption.w - 1.0f, l.caption.h - 1.0f) == SPDF_WIN_CHROME_CAPTION);
    CHECK(spdf_win_chrome_hit(&l, l.caption.x - 1.0f, 10.0f) == SPDF_WIN_CHROME_TABSTRIP);
    CHECK(spdf_win_chrome_hit(&l, l.caption.x + 10.0f, l.caption.h) == SPDF_WIN_CHROME_TOOLBAR);
    CHECK(spdf_win_chrome_hit(&l, 100.0f, 400.0f) == SPDF_WIN_CHROME_SIDEBAR);
    CHECK(spdf_win_chrome_hit(&l, l.canvas.x + 50.0f, 400.0f) == SPDF_WIN_CHROME_CANVAS);
    CHECK(spdf_win_chrome_hit(&l, l.minimap.x + 10.0f, 400.0f) == SPDF_WIN_CHROME_MINIMAP);

    /* A divider is found even a couple of points outside its 5 pt width: the
     * grab area is widened, and it is tested BEFORE the panels it overlaps. */
    CHECK(spdf_win_chrome_hit(&l, l.sidebar_divider.x + 2.0f, 400.0f) == SPDF_WIN_CHROME_SIDEBAR_DIVIDER);
    CHECK(spdf_win_chrome_hit(&l, l.sidebar_divider.x - 1.0f, 400.0f) == SPDF_WIN_CHROME_SIDEBAR_DIVIDER);
    CHECK(spdf_win_chrome_hit(&l, l.minimap_divider.x + 2.0f, 400.0f) == SPDF_WIN_CHROME_MINIMAP_DIVIDER);

    /* Outside the client is nothing. */
    CHECK(spdf_win_chrome_hit(&l, -5.0f, 400.0f) == SPDF_WIN_CHROME_NONE);
    CHECK(spdf_win_chrome_hit(&l, 5000.0f, 400.0f) == SPDF_WIN_CHROME_NONE);
    CHECK(spdf_win_chrome_hit(NULL, 5.0f, 5.0f) == SPDF_WIN_CHROME_NONE);
}

/* --- divider drags land inside the clamps ------------------------------ */
static void test_drags(void) {
    SpdfWinChromeModel m = default_model();
    SpdfWinChromeLayout l;
    float w;
    spdf_win_chrome_layout(&m, 1600, 900, 1.0f, &l);

    /* Dragging the sidebar's seam to x = 300 asks for 300 pt; 0.34 * 1600 = 544
     * so the 320 maximum binds. */
    w = spdf_win_chrome_sidebar_drag_pt(&l, 300.0f, 0);
    CHECK(w >= SPDF_WIN_CHROME_SIDEBAR_MIN_W);
    CHECK(w <= SPDF_WIN_CHROME_SIDEBAR_MAX_W);
    CHECK_EQF(w, 300.0f);

    /* Dragging far left clamps to the minimum, not to zero. */
    w = spdf_win_chrome_sidebar_drag_pt(&l, 10.0f, 0);
    CHECK_EQF(w, SPDF_WIN_CHROME_SIDEBAR_MIN_W);
    /* And far right to the maximum. */
    w = spdf_win_chrome_sidebar_drag_pt(&l, 1500.0f, 0);
    CHECK_EQF(w, SPDF_WIN_CHROME_SIDEBAR_MAX_W);

    /* The minimap's leading edge moves the opposite way. */
    w = spdf_win_chrome_minimap_drag_pt(&l, l.minimap.x - 40.0f);
    CHECK(w > SPDF_WIN_CHROME_MINIMAP_W);
    w = spdf_win_chrome_minimap_drag_pt(&l, 1599.0f);
    CHECK_EQF(w, SPDF_WIN_CHROME_MINIMAP_MIN_W);

    CHECK_EQF(spdf_win_chrome_sidebar_drag_pt(NULL, 100.0f, 0), 0.0f);
    CHECK_EQF(spdf_win_chrome_minimap_drag_pt(NULL, 100.0f), 0.0f);
}

/* --- the toolbar's two readouts ---------------------------------------- */

/* Moved here from chrome_input_test.c, which needed the lines for the Markdown
 * pill: these two helpers belong to spdf_win_chrome.h, which is this suite's
 * subject, and neither has anything to do with routing a mouse event. */
static void test_fit_labels_and_zoom_percent(void) {
    SpdfWinChromeModel m = default_model();

    CHECK(wcscmp(spdf_win_chrome_fit_label(SPDF_WIN_CHROME_FIT_ACTUAL), L"100%") == 0);
    CHECK(wcscmp(spdf_win_chrome_fit_label(SPDF_WIN_CHROME_FIT_WIDTH), L"Fit Width") == 0);
    CHECK(wcscmp(spdf_win_chrome_fit_label(SPDF_WIN_CHROME_FIT_HEIGHT), L"Fit Height") == 0);
    CHECK(wcscmp(spdf_win_chrome_fit_label(SPDF_WIN_CHROME_FIT_PAGE), L"Fit Page") == 0);
    /* CUSTOM has no fixed title: macOS inserts a percentage item instead, and
     * the caller must format it. NULL is how this header says so. */
    CHECK(spdf_win_chrome_fit_label(SPDF_WIN_CHROME_FIT_CUSTOM) == NULL);

    /* The percentage divides out the DPI scale, or a 150% display would read
     * 150% at actual size. */
    m.zoom = 1.0f;
    m.zoom_dpi_scale = 1.0f;
    CHECK(spdf_win_chrome_zoom_percent(&m) == 100);
    m.zoom = 1.5f;
    m.zoom_dpi_scale = 1.5f;
    CHECK(spdf_win_chrome_zoom_percent(&m) == 100);
    m.zoom = 3.0f;
    m.zoom_dpi_scale = 1.5f;
    CHECK(spdf_win_chrome_zoom_percent(&m) == 200);
    m.zoom = 0.435f;
    m.zoom_dpi_scale = 1.0f;
    CHECK(spdf_win_chrome_zoom_percent(&m) == 44); /* rounded, as "%.0f%%" rounds */
    m.zoom = 0.0f;
    CHECK(spdf_win_chrome_zoom_percent(&m) == 100); /* no zoom yet, not 0% */
    CHECK(spdf_win_chrome_zoom_percent(NULL) == 100);
}

/* --- degenerate input -------------------------------------------------- */
static void test_degenerate(void) {
    SpdfWinChromeModel m = default_model();
    SpdfWinChromeLayout l;

    spdf_win_chrome_layout(&m, 0, 0, 1.0f, &l);
    CHECK(spdf_win_chrome_rect_empty(l.canvas));
    CHECK(spdf_win_chrome_rect_empty(l.tabstrip));

    spdf_win_chrome_layout(NULL, 800, 600, 1.0f, &l);
    CHECK(spdf_win_chrome_rect_empty(l.canvas));

    /* A zero or negative scale must not divide by zero or produce NaN. */
    spdf_win_chrome_layout(&m, 800, 600, 0.0f, &l);
    CHECK_EQF(l.dpi_scale, 1.0f);
    CHECK(l.canvas.w > 0.0f);
    spdf_win_chrome_layout(&m, 800, 600, -3.0f, &l);
    CHECK_EQF(l.dpi_scale, 1.0f);

    /* Calling with a NULL out pointer must not crash. */
    spdf_win_chrome_layout(&m, 800, 600, 1.0f, NULL);
    ++g_checks;
}

int main(void) {
    test_metrics();
    test_tiling_across_sizes();
    test_default_window_1x();
    test_whole_pixels();
    test_presentation();
    test_clamps();
    test_hit();
    test_drags();
    test_fit_labels_and_zoom_percent();
    test_degenerate();

    printf("chrome_geometry_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
