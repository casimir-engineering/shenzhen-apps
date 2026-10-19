/* chrome_scroll_input_test.c — pins the SCROLLER half of
 * portable/win/src/spdf_win_chrome_input.h.
 *
 * WHY A THIRD ROUTING SUITE. chrome_input_test.c already sweeps every pixel of
 * every chrome band and asserts that none of it routes to the canvas, and the
 * scrollers were added to that sweep there. This file holds the rest -- the
 * checks that a press on a trough does the RIGHT thing rather than merely not
 * the wrong one -- and it is separate because both files would otherwise be
 * past the 500-line cap (tools/file-size-limits.md asks for an extracted file
 * rather than a raised one).
 *
 * WHAT IT IS FOR. A scrollbar is the only chrome control whose target moves, and
 * it moves as a function of two floats that arrive from the document. The
 * painter and the router agree only because both go through
 * spdf_win_chrome_scroll_bar() and spdf_win_scroll_thumb(); this suite is the
 * evidence that they do -- press on the drawn thumb arms a drag, press above it
 * pages back, press below it pages forward -- at three DPI scales and with the
 * thumb at the top, the middle and the bottom of its travel.
 *
 * spdf_win_chrome_scroll.h's own arithmetic is pinned next door in
 * chrome_scroll_test.c. Header-only under test, so no `spdf-test-sources` line.
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

/* The macOS default window with both panels open and five tabs, which is the
 * configuration every screenshot in portable/docs is taken in. */
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

/* The same window with a document that overflows both ways, so BOTH scrollers
 * exist and neither thumb is full-length. A zeroed model reports v_visible = 0,
 * which spdf_win_chrome_scroll.h reads as "unknown" and draws as a full-length
 * thumb -- correct, but it makes the track a single region and hides every
 * boundary a routing test wants to cross. */
static SpdfWinChromeModel model_scrollable(void) {
    SpdfWinChromeModel m = model_with_tabs(3, 1);
    m.v_pos = 0.4f;
    m.v_visible = 0.25f;
    m.h_pos = 0.3f;
    m.h_visible = 0.5f;
    m.h_scrollable = 1;
    /* A LIVE SIDEBAR LIST AND A LIVE QUERY, which is the state a reader is in
     * for most of a session and which did not exist when this suite was
     * written. Both matter to a SCROLLER sweep for one reason each: the query
     * raises the sidebar's minimum width (spdf_win_chrome_clamp_sidebar_pt), so
     * it moves the canvas -- and therefore both troughs -- sideways; and a
     * non-zero row count makes the sidebar's own routing live, so a trough that
     * had drifted into the panel would now come back as a chapter row instead of
     * as a scroller. Neither may change what a press on a trough does. */
    m.query = L"outline";
    m.search_active = 1;
    m.sidebar_row_count = 40;
    return m;
}


static SpdfWinChromeHit route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m, float x, float y, int button) {
    SpdfWinChromeHit hit;
    spdf_win_chrome_input_route(l, m, x, y, button, &hit);
    return hit;
}


/* THE SWEEP'S SCROLLER HALF. Every pixel of both troughs, with a document that
 * overflows and one that does not, and with three scroll positions so the thumb
 * sits at the top, the middle and the bottom of its travel. A drag begun on a
 * scroller that reached SPDF_WIN_CA_CANVAS would scroll the document AND pan it,
 * which is the specific way this feature could break the gesture that was
 * already working. */
static void test_no_scroller_pixel_routes_to_the_canvas(float dpi) {
    SpdfWinChromeModel s = model_scrollable();
    SpdfWinChromeLayout sl;
    unsigned w = (unsigned)(1120.0f * dpi), h = (unsigned)(800.0f * dpi);
    float positions[3];
    float x, y;
    int buttons[2];
    int b, p;

    buttons[0] = SPDF_WIN_CB_LEFT;
    buttons[1] = SPDF_WIN_CB_MIDDLE;
    positions[0] = 0.0f;
    positions[1] = 0.5f;
    positions[2] = 1.0f;
    for (p = 0; p < 3; ++p) {
        s.v_pos = positions[p];
        s.h_pos = positions[p];
        spdf_win_chrome_layout(&s, w, h, dpi, &sl);
        CHECK(!spdf_win_chrome_rect_empty(sl.vscroll));
        CHECK(!spdf_win_chrome_rect_empty(sl.hscroll));
        for (b = 0; b < 2; ++b) {
            for (y = sl.vscroll.y; y < sl.vscroll.y + sl.vscroll.h; y += 2.0f)
                for (x = sl.vscroll.x; x < sl.vscroll.x + sl.vscroll.w; x += 2.0f)
                    CHECK(route(&sl, &s, x, y, buttons[b]).action != SPDF_WIN_CA_CANVAS);
            for (y = sl.hscroll.y; y < sl.hscroll.y + sl.hscroll.h; y += 2.0f)
                for (x = sl.hscroll.x; x < sl.hscroll.x + sl.hscroll.w; x += 2.0f)
                    CHECK(route(&sl, &s, x, y, buttons[b]).action != SPDF_WIN_CA_CANVAS);
        }
    }
}

/* --- the scrollers ------------------------------------------------------- */

/* THE AGREEMENT CHECK, scroller edition, and it is the one that matters most
 * here: the thumb the router hands a drag to must be the thumb the painter drew.
 * Both call spdf_win_scroll_thumb() through spdf_win_chrome_scroll_bar(), so the
 * check is that the router's answers partition the trough exactly as that
 * geometry says -- press on the thumb arms a drag, press above it pages back,
 * press below it pages forward -- at three DPI scales and three positions. */
static void test_scroller_routing(float dpi) {
    SpdfWinChromeModel m = model_scrollable();
    SpdfWinChromeLayout l;
    float positions[3];
    int p, axis;

    positions[0] = 0.0f;
    positions[1] = 0.45f;
    positions[2] = 1.0f;

    for (p = 0; p < 3; ++p) {
        m.v_pos = positions[p];
        m.h_pos = positions[p];
        spdf_win_chrome_layout(&m, (unsigned)(1120.0f * dpi), (unsigned)(800.0f * dpi), dpi, &l);

        for (axis = 0; axis < 2; ++axis) {
            spdf_win_chrome_part part = axis == SPDF_WIN_SCROLL_H ? SPDF_WIN_CHROME_HSCROLL : SPDF_WIN_CHROME_VSCROLL;
            SpdfWinScrollBar bar;
            SpdfWinChromeRect thumb;
            spdf_win_chrome_action drag_action =
                axis == SPDF_WIN_SCROLL_H ? SPDF_WIN_CA_DRAG_HSCROLL : SPDF_WIN_CA_DRAG_VSCROLL;
            float cross, along;
            SpdfWinChromeHit hit;

            spdf_win_chrome_scroll_bar(&l, &m, part, &bar);
            CHECK(!spdf_win_chrome_rect_empty(bar.track));
            thumb = spdf_win_scroll_thumb(bar.track, bar.pos, bar.visible, spdf_win_scroll_thumb_min(dpi), bar.axis);
            CHECK(!spdf_win_chrome_rect_empty(thumb));

            /* Down the middle of the trough across the axis, so the cross-axis
             * coordinate is never the thing under test. */
            cross = axis == SPDF_WIN_SCROLL_H ? bar.track.y + bar.track.h * 0.5f : bar.track.x + bar.track.w * 0.5f;

            /* The thumb's own centre. */
            along = spdf_win_scroll_start(thumb, axis) + spdf_win_scroll_len(thumb, axis) * 0.5f;
            hit = axis == SPDF_WIN_SCROLL_H ? route(&l, &m, along, cross, SPDF_WIN_CB_LEFT)
                                            : route(&l, &m, cross, along, SPDF_WIN_CB_LEFT);
            CHECK_EQI(hit.part, part);
            CHECK_EQI(hit.scroll_part, SPDF_WIN_SCROLL_THUMB);
            CHECK_EQI(hit.action, drag_action);
            /* A scroller keeps the ARROW: Windows does not change the cursor
             * over a scrollbar, and a resize cursor there would read as the
             * panel edge two pixels away. */
            CHECK_EQI(hit.cursor, SPDF_WIN_CC_ARROW);

            /* One pixel before the thumb is the BACK trough -- unless the thumb
             * is already at the very start, where there is no back trough. */
            along = spdf_win_scroll_start(thumb, axis) - 1.0f;
            hit = axis == SPDF_WIN_SCROLL_H ? route(&l, &m, along, cross, SPDF_WIN_CB_LEFT)
                                            : route(&l, &m, cross, along, SPDF_WIN_CB_LEFT);
            if (spdf_win_scroll_start(thumb, axis) > spdf_win_scroll_start(bar.track, axis))
                CHECK_EQI(hit.action, SPDF_WIN_CA_SCROLL_PAGE_BACK);
            else CHECK(hit.action != SPDF_WIN_CA_CANVAS);

            /* And one pixel after it is the FORWARD trough. */
            along = spdf_win_scroll_start(thumb, axis) + spdf_win_scroll_len(thumb, axis);
            hit = axis == SPDF_WIN_SCROLL_H ? route(&l, &m, along, cross, SPDF_WIN_CB_LEFT)
                                            : route(&l, &m, cross, along, SPDF_WIN_CB_LEFT);
            if (along < spdf_win_scroll_start(bar.track, axis) + spdf_win_scroll_len(bar.track, axis))
                CHECK_EQI(hit.action, SPDF_WIN_CA_SCROLL_PAGE_FORWARD);
            else CHECK(hit.action != SPDF_WIN_CA_CANVAS);

            /* A bare hover reports the part without arming anything, which is
             * what lights the thumb; and the MIDDLE button does nothing at all
             * on a scroller, so a middle-drag over one is inert rather than a
             * scroll. */
            along = spdf_win_scroll_start(thumb, axis) + spdf_win_scroll_len(thumb, axis) * 0.5f;
            hit = axis == SPDF_WIN_SCROLL_H ? route(&l, &m, along, cross, SPDF_WIN_CB_NONE)
                                            : route(&l, &m, cross, along, SPDF_WIN_CB_NONE);
            CHECK_EQI(hit.scroll_part, SPDF_WIN_SCROLL_THUMB);
            CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
            hit = axis == SPDF_WIN_SCROLL_H ? route(&l, &m, along, cross, SPDF_WIN_CB_MIDDLE)
                                            : route(&l, &m, cross, along, SPDF_WIN_CB_MIDDLE);
            CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
        }
    }
}

/* The horizontal trough exists only when the content overflows sideways -- the
 * one model field spdf_win_chrome_layout() reads. With it off, the pixels the
 * trough would have occupied belong to the CANVAS and must pan as they always
 * did, which is the half of this that a "scrollers are new chrome" change could
 * quietly take away. */
static void test_hscroll_appears_only_when_scrollable(void) {
    SpdfWinChromeModel off = model_scrollable();
    SpdfWinChromeModel on = model_scrollable();
    SpdfWinChromeLayout lo, ln;

    off.h_scrollable = 0;
    spdf_win_chrome_layout(&off, 1120, 800, 1.0f, &lo);
    spdf_win_chrome_layout(&on, 1120, 800, 1.0f, &ln);
    CHECK(spdf_win_chrome_rect_empty(lo.hscroll));
    CHECK(!spdf_win_chrome_rect_empty(ln.hscroll));
    CHECK(lo.canvas.h > ln.canvas.h);
    /* The row the horizontal trough would occupy is canvas without it. */
    CHECK_EQI(route(&lo, &off, ln.hscroll.x + ln.hscroll.w * 0.5f, ln.hscroll.y + ln.hscroll.h * 0.5f,
                    SPDF_WIN_CB_LEFT)
                  .action,
              SPDF_WIN_CA_CANVAS);
    /* And with it, that same point is the trough and nothing else. */
    CHECK(route(&ln, &on, ln.hscroll.x + ln.hscroll.w * 0.5f, ln.hscroll.y + ln.hscroll.h * 0.5f, SPDF_WIN_CB_LEFT)
              .action != SPDF_WIN_CA_CANVAS);
}

/* spdf_win_chrome_scroll_bar() picks the band, the track and the fractions
 * together. Picking one scroller's rect with the other's fraction produces a
 * thumb in a plausible place, so this pins that the pairs stay paired. */
static void test_scroll_bar_selector(void) {
    SpdfWinChromeModel m = model_scrollable();
    SpdfWinChromeLayout l;
    SpdfWinScrollBar v, h, none;

    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);
    spdf_win_chrome_scroll_bar(&l, &m, SPDF_WIN_CHROME_VSCROLL, &v);
    spdf_win_chrome_scroll_bar(&l, &m, SPDF_WIN_CHROME_HSCROLL, &h);
    CHECK_EQI(v.axis, SPDF_WIN_SCROLL_V);
    CHECK_EQI(h.axis, SPDF_WIN_SCROLL_H);
    CHECK(v.pos == m.v_pos && v.visible == m.v_visible);
    CHECK(h.pos == m.h_pos && h.visible == m.h_visible);
    CHECK(v.band.x == l.vscroll.x && v.band.y == l.vscroll.y);
    CHECK(h.band.x == l.hscroll.x && h.band.y == l.hscroll.y);

    /* Anything that is not a scroller yields an empty, zeroed bar rather than a
     * stale one -- the caller may read every field after any call. */
    spdf_win_chrome_scroll_bar(&l, &m, SPDF_WIN_CHROME_TOOLBAR, &none);
    CHECK(spdf_win_chrome_rect_empty(none.band));
    CHECK(spdf_win_chrome_rect_empty(none.track));
    spdf_win_chrome_scroll_bar(NULL, &m, SPDF_WIN_CHROME_VSCROLL, &none);
    CHECK(spdf_win_chrome_rect_empty(none.band));
    spdf_win_chrome_scroll_bar(&l, NULL, SPDF_WIN_CHROME_VSCROLL, &none);
    CHECK(spdf_win_chrome_rect_empty(none.band));
    spdf_win_chrome_scroll_bar(&l, &m, SPDF_WIN_CHROME_VSCROLL, NULL); /* must not crash */
    ++g_checks;
}

int main(void) {
    float scales[3];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.5f; /* this machine's own 144 dpi -- the fractional case */
    scales[2] = 2.0f;

    for (i = 0; i < 3; ++i) {
        test_no_scroller_pixel_routes_to_the_canvas(scales[i]);
        test_scroller_routing(scales[i]);
    }
    test_hscroll_appears_only_when_scrollable();
    test_scroll_bar_selector();

    printf("chrome_scroll_input_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
