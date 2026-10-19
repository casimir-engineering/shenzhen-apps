/* sidebar_route_test.c — the two routes the wiring pass connected to handlers:
 * the sidebar's SEGMENT CONTROL (Chapters / Comments / Search) and a press on
 * the MINIMAP STRIP, as spdf_win_chrome_input_route() reports them.
 *
 * WHAT IT IS FOR. chrome_perform() in spdf_win_chrome_actions.h now maps
 * SPDF_WIN_CA_SIDEBAR_SECTION to chrome_sidebar_section(a, hit->index) and
 * SPDF_WIN_CA_MINIMAP to minimap_press(); both handlers need an `app`, so what
 * can be pinned without one is the half that decides: that the centre of every
 * segment the painter draws routes to that segment's INDEX, at 100%, 150% and
 * 200%, with two segments and with three (a live search adds the third and
 * narrows them all), and that a press anywhere on the strip is a minimap
 * action with the left button and nothing with any other -- never the canvas.
 * The rects come from the same functions the painters draw with
 * (spdf_win_sidebar_layout, spdf_win_sidebar_sections_rect), which is
 * spdf_win_chrome.h's rule for hit-testing and painting agreeing.
 *
 * Header-only under test, so no `spdf-test-sources` line -- same as
 * chrome_input_test.c, from which this is split for the 500-line cap.
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
        if ((int)(a) != (int)(b)) {                                                                                    \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* Both panels open, three tabs, a few chapter rows; `search_active` adds the
 * Search segment exactly as spdf_win_find_fill_model does for a live query. */
static SpdfWinChromeModel model_for(int search_active) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.tab_count = 3;
    m.selected_tab = 1;
    m.page_index = 0;
    m.page_count = 12;
    m.zoom = 1.0f;
    m.zoom_dpi_scale = 1.0f;
    m.fit_mode = SPDF_WIN_CHROME_FIT_WIDTH;
    m.sidebar_row_count = 5;
    if (search_active) {
        m.query = L"fixture";
        m.search_active = 1;
    }
    return m;
}

static SpdfWinChromeHit route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m, float x, float y, int button) {
    SpdfWinChromeHit hit;
    spdf_win_chrome_input_route(l, m, x, y, button, &hit);
    return hit;
}

static void test_segments(float dpi, int search_active) {
    SpdfWinChromeModel m = model_for(search_active);
    SpdfWinChromeLayout l;
    SpdfWinSidebarLayout sb;
    SpdfWinChromeRect bar;
    int segments = search_active ? 3 : 2;
    int seg;

    spdf_win_chrome_layout(&m, (unsigned)(1120.0f * dpi), (unsigned)(800.0f * dpi), dpi, &l);
    CHECK(!spdf_win_chrome_rect_empty(l.sidebar));
    spdf_win_sidebar_layout(l.sidebar, m.sidebar_section, dpi, &sb);
    bar = spdf_win_sidebar_sections_rect(sb.sections, l.sidebar, segments, dpi);
    CHECK(!spdf_win_chrome_rect_empty(bar));

    for (seg = 0; seg < segments; ++seg) {
        float x = bar.x + bar.w * ((float)seg + 0.5f) / (float)segments;
        float y = bar.y + bar.h * 0.5f;
        SpdfWinChromeHit hit = route(&l, &m, x, y, SPDF_WIN_CB_LEFT);
        /* The segment IS the section number chrome_sidebar_section() stores. */
        CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_SECTION);
        CHECK_EQI(hit.index, seg);
        CHECK_EQI(hit.part, SPDF_WIN_CHROME_SIDEBAR);
        /* Only the left button selects a section; the middle button does
         * nothing there -- and, as everywhere in the sidebar, never pans. */
        hit = route(&l, &m, x, y, SPDF_WIN_CB_MIDDLE);
        CHECK(hit.action != SPDF_WIN_CA_SIDEBAR_SECTION);
        CHECK(hit.action != SPDF_WIN_CA_CANVAS);
    }
    /* Just past the control's right edge is sidebar, not a segment. */
    {
        SpdfWinChromeHit hit = route(&l, &m, bar.x + bar.w + 2.0f, bar.y + bar.h * 0.5f, SPDF_WIN_CB_LEFT);
        CHECK(hit.action != SPDF_WIN_CA_SIDEBAR_SECTION);
        CHECK(hit.action != SPDF_WIN_CA_CANVAS);
    }
    /* With no live search there is no third segment to hit: the point where
     * the third would be is still the sidebar and routes as segment 1 or as
     * nothing, but never as a section index the app has no content for. */
    if (!search_active) {
        SpdfWinChromeHit hit = route(&l, &m, bar.x + bar.w * (2.5f / 3.0f), bar.y + bar.h * 0.5f, SPDF_WIN_CB_LEFT);
        CHECK(hit.action != SPDF_WIN_CA_SIDEBAR_SECTION || hit.index < 2);
    }
}

static void test_minimap(float dpi) {
    SpdfWinChromeModel m = model_for(0);
    SpdfWinChromeLayout l;
    SpdfWinChromeHit hit;
    float x, y;

    spdf_win_chrome_layout(&m, (unsigned)(1120.0f * dpi), (unsigned)(800.0f * dpi), dpi, &l);
    CHECK(!spdf_win_chrome_rect_empty(l.minimap));
    x = l.minimap.x + l.minimap.w * 0.5f;
    y = l.minimap.y + l.minimap.h * 0.5f;

    /* A left press arms the strip gesture; the app resolves click-vs-drag
     * against the frame the painter recorded (spdf_win_search_map.h). */
    hit = route(&l, &m, x, y, SPDF_WIN_CB_LEFT);
    CHECK_EQI(hit.part, SPDF_WIN_CHROME_MINIMAP);
    CHECK_EQI(hit.action, SPDF_WIN_CA_MINIMAP);
    /* Any other button, and a bare hover, does nothing -- and neither pans. */
    hit = route(&l, &m, x, y, SPDF_WIN_CB_MIDDLE);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
    hit = route(&l, &m, x, y, SPDF_WIN_CB_NONE);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
    CHECK_EQI(hit.cursor, SPDF_WIN_CC_ARROW);
    /* Near the edges is still strip -- past the divider's grab zone on the
     * left (its slop reaches a few points into the panel, and a press there IS
     * a divider drag), and right up to the window edge on the right. */
    hit = route(&l, &m, l.minimap.x + 12.0f * dpi, l.minimap.y + 2.0f, SPDF_WIN_CB_LEFT);
    CHECK_EQI(hit.action, SPDF_WIN_CA_MINIMAP);
    hit = route(&l, &m, l.minimap.x + l.minimap.w - 2.0f, l.minimap.y + l.minimap.h - 2.0f, SPDF_WIN_CB_LEFT);
    CHECK_EQI(hit.action, SPDF_WIN_CA_MINIMAP);
}

int main(void) {
    float scales[3];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.5f; /* this machine's own 144 dpi -- the fractional case */
    scales[2] = 2.0f;
    for (i = 0; i < 3; ++i) {
        test_segments(scales[i], 0);
        test_segments(scales[i], 1);
        test_minimap(scales[i]);
    }
    printf("sidebar_route_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
