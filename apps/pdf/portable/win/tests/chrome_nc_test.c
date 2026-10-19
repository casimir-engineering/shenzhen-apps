/* chrome_nc_test.c — pins the TITLE-BAR half of portable/win/src/spdf_win_chrome_input.h:
 * SpdfWinChromeHit::nc, the window manager's view of a point.
 *
 * The tab strip is the caption (spdf_win_tabstrip.h's header), and
 * spdf_win_window_caption.h turns the router's `nc` into HTCAPTION /
 * HTMINBUTTON / HTMAXBUTTON / HTCLOSE / HTCLIENT. So the click policy macOS
 * states in SPDFMacWindowChrome (handoff §3.6) -- a click on empty title-bar area
 * drags, a double-click zooms, a click on any control never does either -- is
 * decided here, from the same geometry the painter draws, and can be checked
 * without a window. Split from chrome_input_test.c, which was at the 500-line
 * cap; same header-only subject, so no `spdf-test-sources` line is needed.
 *
 * The live counterpart is the WM_NCHITTEST probe over a real window, which
 * asserts the HT codes at the same points; what it cannot do is enumerate every
 * pixel, which is what the sweep at the end of test_nc_policy_in does.
 */
#include "spdf_win_chrome_input.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if ((int)(a) != (int)(b)) {                                                                                     \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* The macOS default window with both panels open, as chrome_input_test.c
 * builds it. */
static SpdfWinChromeModel model_with_tabs(int tab_count, int selected) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.tab_count = tab_count;
    m.selected_tab = selected;
    m.page_index = 3;
    m.page_count = 117;
    m.zoom = 1.0f;
    m.zoom_dpi_scale = 1.0f;
    m.fit_mode = SPDF_WIN_CHROME_FIT_WIDTH;
    return m;
}

static SpdfWinChromeHit route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m, float x, float y, int button) {
    SpdfWinChromeHit hit;
    spdf_win_chrome_input_route(l, m, x, y, button, &hit);
    return hit;
}

/* THE TITLE BAR. The strip is the caption now (spdf_win_tabstrip.h), and the
 * window manager's view of every strip pixel comes from the same routing as the
 * app's -- so this pins the policy in handoff §3.6 directly: a control is never
 * a drag, empty strip always is, and the three caption buttons are found by the
 * same geometry that draws them. Everything below the strip is CLIENT. */
static void test_nc_policy_in(float dpi) {
    SpdfWinChromeModel m = model_with_tabs(3, 1);
    SpdfWinChromeLayout l;
    unsigned w = (unsigned)(1120.0f * dpi), h = (unsigned)(800.0f * dpi);
    float strip_w, strip_h, mid_y, x, y;
    int i;

    spdf_win_chrome_layout(&m, w, h, dpi, &l);
    strip_w = l.tabstrip.w / dpi;
    strip_h = l.tabstrip.h / dpi;
    mid_y = l.tabstrip.y + l.tabstrip.h * 0.5f;

    /* Every tab, its close box, the `+`: ours. */
    for (i = 0; i < m.tab_count; ++i) {
        SpdfWinTabRect tab = spdf_win_tabstrip_tab_rect(strip_w, m.tab_count, m.selected_tab, i);
        SpdfWinTabRect close = spdf_win_tabstrip_close_rect(tab);
        CHECK_EQI(route(&l, &m, (float)(tab.x + 4.0) * dpi, mid_y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CLIENT);
        CHECK_EQI(route(&l, &m, (float)(close.x + close.w / 2.0) * dpi, (float)(close.y + close.h / 2.0) * dpi,
                        SPDF_WIN_CB_NONE).nc,
                  SPDF_WIN_NC_CLIENT);
        /* The forgiving slop above the tab body selects the tab, so it must not
         * drag the window either: the two pixel sets are complementary. */
        CHECK_EQI(route(&l, &m, (float)(tab.x + 4.0) * dpi, l.tabstrip.y + 1.0f, SPDF_WIN_CB_NONE).nc,
                  SPDF_WIN_NC_CLIENT);
    }
    {
        SpdfWinTabRect plus = spdf_win_tabstrip_plus_rect(strip_w);
        CHECK_EQI(route(&l, &m, (float)(plus.x + plus.w / 2.0) * dpi, mid_y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CLIENT);
        /* The gap between the last tab and the `+` is empty title bar. The tab
         * area ends 10 pt before the `+` and a tab's forgiving slop reaches 6 pt
         * past its body, so the last 4 pt before the `+` are always empty. */
        CHECK_EQI(route(&l, &m, (float)(plus.x - 3.0) * dpi, mid_y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CAPTION);
        /* And so is the leading inset, left of the first tab. */
        CHECK_EQI(route(&l, &m, 4.0f * dpi, mid_y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CAPTION);
    }

    /* The three caption buttons, at their centres and at their shared edges,
     * with the button that WM_NCHITTEST will name for each. */
    {
        int expect[4];
        int b;
        expect[SPDF_WIN_CAPTION_MINIMIZE] = SPDF_WIN_NC_MINIMIZE;
        expect[SPDF_WIN_CAPTION_MAXIMIZE] = SPDF_WIN_NC_MAXIMIZE;
        expect[SPDF_WIN_CAPTION_CLOSE] = SPDF_WIN_NC_CLOSE;
        for (b = SPDF_WIN_CAPTION_MINIMIZE; b <= SPDF_WIN_CAPTION_CLOSE; ++b) {
            SpdfWinTabRect r = spdf_win_tabstrip_caption_rect(strip_w, strip_h, b);
            SpdfWinChromeHit hit;
            CHECK(!spdf_win_tabstrip_rect_is_empty(r));
            CHECK_EQI(r.h, strip_h);
            hit = route(&l, &m, (float)(r.x + r.w / 2.0) * dpi, mid_y, SPDF_WIN_CB_NONE);
            CHECK_EQI(hit.nc, expect[b]);
            CHECK_EQI(hit.part, SPDF_WIN_CHROME_CAPTION);
            /* A button is never an app action, with any button. */
            CHECK_EQI(route(&l, &m, (float)(r.x + r.w / 2.0) * dpi, mid_y, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_NONE);
            CHECK_EQI(route(&l, &m, (float)(r.x + r.w / 2.0) * dpi, mid_y, SPDF_WIN_CB_MIDDLE).action,
                      SPDF_WIN_CA_NONE);
            /* Left edge inclusive, and the full strip height. */
            CHECK_EQI(route(&l, &m, (float)r.x * dpi, l.tabstrip.y, SPDF_WIN_CB_NONE).nc, expect[b]);
            CHECK_EQI(route(&l, &m, (float)r.x * dpi, l.tabstrip.y + l.tabstrip.h - 1.0f, SPDF_WIN_CB_NONE).nc,
                      expect[b]);
        }
        /* The close button ends at the window's edge. */
        CHECK_EQI(route(&l, &m, (float)w - 1.0f, mid_y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CLOSE);
    }

    /* Below the strip, nothing is the window manager's. */
    for (y = l.toolbar.y; y < (float)h; y += 37.0f)
        for (x = 0.0f; x < (float)w; x += 53.0f) CHECK_EQI(route(&l, &m, x, y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CLIENT);

    /* Every strip pixel is either the app's or the window manager's, and the
     * two partitions are decided by whether a control is under the pointer:
     * where nc is CLIENT a hover lights something or a press does something,
     * and where it is CAPTION neither happens. */
    for (x = 0.0f; x < (float)w; x += 2.0f) {
        SpdfWinChromeHit hover = route(&l, &m, x, mid_y, SPDF_WIN_CB_NONE);
        SpdfWinChromeHit press = route(&l, &m, x, mid_y, SPDF_WIN_CB_LEFT);
        int on_control = hover.hot_tab >= 0 || hover.hot_close >= 0 || press.action != SPDF_WIN_CA_NONE;
        if (hover.part == SPDF_WIN_CHROME_CAPTION) continue;
        CHECK_EQI(hover.nc, on_control ? SPDF_WIN_NC_CLIENT : SPDF_WIN_NC_CAPTION);
    }

    /* AN EMPTY STRIP IS STILL A TITLE BAR: with no document open the window has
     * nothing but the `+` and the three buttons, and it must still drag,
     * double-click-maximize and close. */
    {
        SpdfWinChromeModel none = model_with_tabs(0, -1);
        SpdfWinTabRect plus = spdf_win_tabstrip_plus_rect(strip_w);
        SpdfWinTabRect close = spdf_win_tabstrip_caption_rect(strip_w, strip_h, SPDF_WIN_CAPTION_CLOSE);
        CHECK_EQI(route(&l, &none, 100.0f * dpi, mid_y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CAPTION);
        CHECK_EQI(route(&l, &none, (float)(plus.x + 2.0) * dpi, mid_y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CLIENT);
        CHECK_EQI(route(&l, &none, (float)(close.x + 2.0) * dpi, mid_y, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CLOSE);
    }
}

/* Nothing may route to the window manager on a NULL layout or model: every
 * pixel stays the app's, which is the pre-caption behaviour and the safe
 * default -- a window that cannot be dragged for one frame beats a click on a
 * tab that moves the window. */
static void test_degenerate_inputs(void) {
    SpdfWinChromeModel m = model_with_tabs(2, 0);
    SpdfWinChromeLayout l;
    SpdfWinChromeHit hit;
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);

    spdf_win_chrome_input_route(NULL, &m, 10.0f, 10.0f, SPDF_WIN_CB_NONE, &hit);
    CHECK_EQI(hit.nc, SPDF_WIN_NC_CLIENT);
    spdf_win_chrome_input_route(&l, NULL, 10.0f, 10.0f, SPDF_WIN_CB_NONE, &hit);
    CHECK_EQI(hit.nc, SPDF_WIN_NC_CLIENT);
    /* Outside the window entirely. */
    spdf_win_chrome_input_route(&l, &m, -5.0f, -5.0f, SPDF_WIN_CB_NONE, &hit);
    CHECK_EQI(hit.nc, SPDF_WIN_NC_CLIENT);
    /* Presentation mode has no strip, so no title bar and no buttons: the
     * window is fullscreen-like, exactly as macOS's is. */
    m.presentation = 1;
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);
    CHECK_EQI(route(&l, &m, 10.0f, 10.0f, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CLIENT);
    CHECK_EQI(route(&l, &m, 1110.0f, 10.0f, SPDF_WIN_CB_NONE).nc, SPDF_WIN_NC_CLIENT);
}

int main(void) {
    float scales[3];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.5f; /* this machine's own 144 dpi -- the fractional case */
    scales[2] = 2.0f;
    for (i = 0; i < 3; ++i) test_nc_policy_in(scales[i]);
    test_degenerate_inputs();
    printf("chrome_nc_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
