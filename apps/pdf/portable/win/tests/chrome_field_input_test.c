/* chrome_field_input_test.c — pins the FIELD and SIDEBAR half of
 * portable/win/src/spdf_win_chrome_input.h, and the tab reorder arithmetic the
 * strip drives.
 *
 * WHY A FOURTH ROUTING SUITE. chrome_input_test.c sweeps every chrome pixel and
 * asserts none of it pans the document; chrome_scroll_input_test.c does the same
 * for the two troughs and then checks that a press on one does the RIGHT thing.
 * This file is that second half for the controls that only became live when the
 * chrome became typeable: the two text fields, the regex checkbox, the find
 * pill, the sidebar's filter field and its chapter rows. It is separate because
 * all three files together would be far past the 500-line cap, which
 * tools/file-size-limits.md answers with a new file rather than a raised one --
 * and chrome_scroll_input_test.c already set that precedent for exactly this
 * header.
 *
 * WHAT GOES WRONG HERE, specifically:
 *
 *   - a click on the find field focusing the PAGE field, or either of them
 *     falling through to the toolbar and doing nothing, which is what they both
 *     did until now;
 *   - the find pill's two halves swapped, so "next match" goes backwards --
 *     invisible in a screenshot and infuriating in use;
 *   - the sidebar's filter field and its first row overlapping, so the top
 *     chapter cannot be clicked;
 *   - a row index computed against a different row count from the one that was
 *     drawn, which lands the reader on the wrong chapter;
 *   - a tab dragged onto its own edge MOVING, when both gaps adjacent to a
 *     dragged tab must collapse to a no-op.
 *
 * Header-only under test, so no `spdf-test-sources` line.
 */
#include "spdf_win_chrome_input.h"
#include "spdf_win_tabstrip.h"

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

/* The window every screenshot in portable/docs is taken in, with a live query
 * and a chapter list -- the state a reader is in once they have opened
 * something and started looking for a word in it. */
static SpdfWinChromeModel model_live(int rows) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.drag_tab = -1;
    m.drop_slot = -1;
    m.tab_count = 3;
    m.selected_tab = 1;
    m.page_index = 3;
    m.page_count = 117;
    m.zoom = 1.0f;
    m.zoom_dpi_scale = 1.0f;
    m.fit_mode = SPDF_WIN_CHROME_FIT_WIDTH;
    m.query = L"outline";
    m.search_active = 1;
    m.sidebar_row_count = rows;
    return m;
}

static SpdfWinChromeHit route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m, float x, float y, int button) {
    SpdfWinChromeHit hit;
    spdf_win_chrome_input_route(l, m, x, y, button, &hit);
    return hit;
}

/* --- the toolbar's four newly live controls ------------------------------ */

static void test_toolbar_fields(float dpi) {
    SpdfWinChromeModel m = model_live(40);
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout tb;
    spdf_win_chrome_layout(&m, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &l);
    spdf_win_toolbar_layout(l.toolbar, dpi, m.markdown, &tb);

    /* A window wide enough that the whole find group is present -- these four
     * assertions would be vacuous against an empty rect. */
    CHECK(!spdf_win_chrome_rect_empty(tb.item[SPDF_WIN_TB_FIND_FIELD]));
    CHECK(!spdf_win_chrome_rect_empty(tb.item[SPDF_WIN_TB_FIND_REGEX]));
    CHECK(!spdf_win_chrome_rect_empty(tb.item[SPDF_WIN_TB_FIND_PILL]));

#define AT(id, fx) (tb.item[id].x + tb.item[id].w * (fx)), (tb.item[id].y + tb.item[id].h * 0.5f)
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_FIND_FIELD, 0.5f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_FOCUS_FIND);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_PAGE_FIELD, 0.5f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_FOCUS_PAGE);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_FIND_REGEX, 0.5f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_TOGGLE_REGEX);
    /* PREVIOUS is the first half. Reversed, "next match" walks backwards, which
     * no screenshot can show. */
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_FIND_PILL, 0.25f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_FIND_PREV);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_FIND_PILL, 0.75f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_FIND_NEXT);
    /* The two fields are DIFFERENT controls: neither may answer for the other,
     * whatever the row's collapse order has done to the widths. */
    CHECK(tb.item[SPDF_WIN_TB_PAGE_FIELD].x + tb.item[SPDF_WIN_TB_PAGE_FIELD].w <= tb.item[SPDF_WIN_TB_FIND_FIELD].x);
    /* A hover and a middle click do not focus anything -- focus follows a
     * deliberate left click, or the pointer crossing the toolbar would steal the
     * keyboard from the document. */
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_FIND_FIELD, 0.5f), SPDF_WIN_CB_NONE).action, SPDF_WIN_CA_NONE);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_FIND_FIELD, 0.5f), SPDF_WIN_CB_MIDDLE).action, SPDF_WIN_CA_NONE);
#undef AT
}

/* --- the sidebar --------------------------------------------------------- */

static void test_sidebar_filter_and_rows(float dpi) {
    SpdfWinChromeModel m = model_live(40);
    SpdfWinChromeLayout l;
    SpdfWinSidebarLayout sb;
    SpdfWinChromeHit hit;
    int row;
    float y;

    spdf_win_chrome_layout(&m, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &l);
    CHECK(!spdf_win_chrome_rect_empty(l.sidebar));
    spdf_win_sidebar_layout(l.sidebar, m.sidebar_section, dpi, &sb);
    CHECK(!spdf_win_chrome_rect_empty(sb.filter));
    CHECK(!spdf_win_chrome_rect_empty(sb.list));
    /* The filter field ends before the list begins, or the top chapter is
     * unclickable and the field swallows a row. */
    CHECK(sb.filter.y + sb.filter.h <= sb.list.y);

    CHECK_EQI(route(&l, &m, sb.filter.x + sb.filter.w * 0.5f, sb.filter.y + sb.filter.h * 0.5f, SPDF_WIN_CB_LEFT)
                  .action,
              SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER);
    /* The section control above it is still inert, and must NOT be the filter. */
    CHECK(route(&l, &m, sb.sections.x + 2.0f, sb.sections.y + sb.sections.h * 0.5f, SPDF_WIN_CB_LEFT).action !=
          SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER);

    /* EVERY VISIBLE ROW, and the router's answer must be the row the same
     * geometry function would place under that point -- which is the whole
     * hit-test-and-paint-agree rule, one level down. */
    for (row = 0; row < m.sidebar_row_count; ++row) {
        SpdfWinChromeRect r = spdf_win_sidebar_row_rect(&sb, 0.0f, row);
        if (r.y < sb.list.y || r.y + r.h > sb.list.y + sb.list.h) continue; /* clipped away */
        hit = route(&l, &m, r.x + r.w * 0.5f, r.y + r.h * 0.5f, SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_ROW);
        CHECK_EQI(hit.index, row);
    }

    /* Below the last row is empty panel: swallowed, and above all NOT the last
     * row again and NOT the canvas. */
    y = sb.list.y + sb.list.h - 1.0f;
    hit = route(&l, &m, sb.list.x + 2.0f, y, SPDF_WIN_CB_LEFT);
    CHECK(hit.action != SPDF_WIN_CA_CANVAS);
    if (hit.action == SPDF_WIN_CA_SIDEBAR_ROW) CHECK(hit.index < m.sidebar_row_count);

    /* WITH NO ROWS nothing in the list is clickable, and the filter field still
     * is -- an empty outline must not take the field away with it. */
    {
        SpdfWinChromeModel empty = model_live(0);
        SpdfWinChromeLayout el;
        SpdfWinSidebarLayout esb;
        spdf_win_chrome_layout(&empty, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &el);
        spdf_win_sidebar_layout(el.sidebar, empty.sidebar_section, dpi, &esb);
        CHECK_EQI(route(&el, &empty, esb.list.x + 4.0f, esb.list.y + 4.0f, SPDF_WIN_CB_LEFT).action,
                  SPDF_WIN_CA_NONE);
        CHECK_EQI(
            route(&el, &empty, esb.filter.x + 4.0f, esb.filter.y + esb.filter.h * 0.5f, SPDF_WIN_CB_LEFT).action,
            SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER);
    }
}

/* Nothing in the sidebar pans the document, at any row count. The canvas sweep
 * next door covers the panel as a whole; this covers it now that the panel
 * ANSWERS, which is when a fall-through could first appear. */
static void test_no_sidebar_pixel_pans(float dpi) {
    int counts[3];
    int c, b;
    int buttons[2];
    float x, y;
    buttons[0] = SPDF_WIN_CB_LEFT;
    buttons[1] = SPDF_WIN_CB_MIDDLE;
    counts[0] = 0;
    counts[1] = 3;
    counts[2] = 400;
    for (c = 0; c < 3; ++c) {
        SpdfWinChromeModel m = model_live(counts[c]);
        SpdfWinChromeLayout l;
        spdf_win_chrome_layout(&m, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &l);
        for (b = 0; b < 2; ++b)
            for (y = l.sidebar.y; y < l.sidebar.y + l.sidebar.h; y += 3.0f)
                for (x = l.sidebar.x; x < l.sidebar.x + l.sidebar.w; x += 3.0f)
                    CHECK(route(&l, &m, x, y, buttons[b]).action != SPDF_WIN_CA_CANVAS);
    }
}

/* --- tab drag-to-reorder ------------------------------------------------- */

/* The composition the app performs on mouse-up: a pointer x becomes a slot among
 * the VISIBLE tabs, the slot is offset by the visible window's start, and
 * spdf_win_tabstrip_move_index() turns that into a destination.
 *
 * The two arithmetic halves are pinned individually in tabstrip_geometry_test.c.
 * What is pinned HERE is the composition, because that is what the app wrote and
 * it is where the visible-window offset can be forgotten -- which would be
 * invisible until a strip went into overflow. */
static int drop_destination(double strip_w, int count, int selected, int source, double x) {
    int start = 0, visible = 0;
    int slot = spdf_win_tabstrip_drop_slot(strip_w, count, selected, x);
    spdf_win_tabstrip_visible_range(strip_w, count, selected, &start, &visible);
    return spdf_win_tabstrip_move_index(start + slot, source, count);
}

static void test_tab_drop_destination(void) {
    const double w = 1120.0;
    int count = 6, selected = 2;
    int source, i;

    /* A tab dropped ON ITSELF stays put, from anywhere within its own rect AND
     * from both adjacent gaps. This is the property spdf_win_tabstrip.h calls
     * out ("BOTH gaps adjacent to the source collapse to a no-op move") and the
     * one a hand-rolled version always gets wrong on one side. */
    for (source = 0; source < count; ++source) {
        SpdfWinTabRect t = spdf_win_tabstrip_tab_rect(w, count, selected, source);
        if (spdf_win_tabstrip_rect_is_empty(t)) continue;
        CHECK_EQI(drop_destination(w, count, selected, source, t.x + 1.0), source);
        CHECK_EQI(drop_destination(w, count, selected, source, t.x + t.w * 0.5 - 1.0), source);
        CHECK_EQI(drop_destination(w, count, selected, source, t.x + t.w - 1.0), source);
    }

    /* Dragging tab 0 to the far right lands it last; dragging the last one to
     * the far left lands it first. */
    CHECK_EQI(drop_destination(w, count, selected, 0, 100000.0), count - 1);
    CHECK_EQI(drop_destination(w, count, selected, count - 1, -100000.0), 0);

    /* Every destination is a valid index, from every x across the strip and for
     * every source -- a move to count, or to -1, is a corrupted tab model. */
    for (source = 0; source < count; ++source)
        for (i = -50; i < 1200; i += 7) {
            int to = drop_destination(w, count, selected, source, (double)i);
            CHECK(to >= 0 && to < count);
        }

    /* A single tab cannot be reordered anywhere. */
    CHECK_EQI(drop_destination(w, 1, 0, 0, 500.0), 0);
    /* An overflowing strip: the visible window no longer starts at 0, which is
     * the case the start offset exists for. Every destination must still be in
     * range and a self-drop must still be a no-op. */
    for (i = 0; i < 30; ++i) {
        SpdfWinTabRect t = spdf_win_tabstrip_tab_rect(w, 30, 20, i);
        int to;
        if (spdf_win_tabstrip_rect_is_empty(t)) continue;
        to = drop_destination(w, 30, 20, i, t.x + t.w * 0.5 - 1.0);
        CHECK_EQI(to, i);
        to = drop_destination(w, 30, 20, i, 0.0);
        CHECK(to >= 0 && to < 30);
    }
}

/* --- the segment control and the Search section's rows ------------------- */

/* The segment under the pointer is the segment the painter drew there (both
 * call spdf_win_sidebar_sections_rect), three segments with a live query and
 * two without; and in the Search section a click on the list carries the
 * LIST-LOCAL Y in `index` -- scroll included -- for the app to resolve against
 * the published rows, since the router has no view of their heights. */
static void test_sidebar_sections_and_search_rows(float dpi) {
    SpdfWinChromeModel m = model_live(40);
    SpdfWinChromeLayout l;
    SpdfWinSidebarLayout sb;
    SpdfWinChromeRect bar;
    SpdfWinChromeHit hit;

    spdf_win_chrome_layout(&m, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &l);
    spdf_win_sidebar_layout(l.sidebar, m.sidebar_section, dpi, &sb);
    bar = spdf_win_sidebar_sections_rect(sb.sections, l.sidebar, 3, dpi);
    CHECK(!spdf_win_chrome_rect_empty(bar));
    CHECK(bar.w <= sb.sections.w + 0.001f);

#define SEG(fx) route(&l, &m, bar.x + bar.w * (fx), bar.y + bar.h * 0.5f, SPDF_WIN_CB_LEFT)
    hit = SEG(0.17f);
    CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_SECTION);
    CHECK_EQI(hit.index, 0);
    hit = SEG(0.50f);
    CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_SECTION);
    CHECK_EQI(hit.index, 1);
    hit = SEG(0.83f);
    CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_SECTION);
    CHECK_EQI(hit.index, 2);
    /* A hover and a middle click choose nothing. */
    CHECK_EQI(route(&l, &m, bar.x + bar.w * 0.5f, bar.y + bar.h * 0.5f, SPDF_WIN_CB_NONE).action, SPDF_WIN_CA_NONE);
    CHECK_EQI(route(&l, &m, bar.x + bar.w * 0.5f, bar.y + bar.h * 0.5f, SPDF_WIN_CB_MIDDLE).action, SPDF_WIN_CA_NONE);
    /* Past the normalised bar's right edge is panel, not the last segment. */
    if (bar.x + bar.w + 2.0f < l.sidebar.x + l.sidebar.w)
        CHECK(route(&l, &m, bar.x + bar.w + 2.0f, bar.y + bar.h * 0.5f, SPDF_WIN_CB_LEFT).action !=
              SPDF_WIN_CA_SIDEBAR_SECTION);
#undef SEG

    /* Without a live query there are two segments, and the point that was the
     * middle of "Comments" above is now inside "Chapters". */
    {
        SpdfWinChromeModel two = model_live(40);
        SpdfWinChromeLayout tl;
        SpdfWinSidebarLayout tsb;
        SpdfWinChromeRect tbar;
        two.search_active = 0;
        two.query = NULL;
        spdf_win_chrome_layout(&two, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &tl);
        spdf_win_sidebar_layout(tl.sidebar, two.sidebar_section, dpi, &tsb);
        tbar = spdf_win_sidebar_sections_rect(tsb.sections, tl.sidebar, 2, dpi);
        hit = route(&tl, &two, tbar.x + tbar.w * 0.25f, tbar.y + tbar.h * 0.5f, SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_SECTION);
        CHECK_EQI(hit.index, 0);
        hit = route(&tl, &two, tbar.x + tbar.w * 0.75f, tbar.y + tbar.h * 0.5f, SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_SECTION);
        CHECK_EQI(hit.index, 1);
    }

    /* The Search section: no filter field, and the list reports local y. */
    {
        SpdfWinChromeModel sm = model_live(0);
        SpdfWinChromeLayout sl;
        SpdfWinSidebarLayout ssb;
        float local = spdf_win_chrome_px(37.0, dpi);
        sm.sidebar_section = 2;
        sm.sidebar_scroll_y = spdf_win_chrome_px(30.0, dpi);
        spdf_win_chrome_layout(&sm, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &sl);
        spdf_win_sidebar_layout(sl.sidebar, 2, dpi, &ssb);
        CHECK(spdf_win_chrome_rect_empty(ssb.filter));
        hit = route(&sl, &sm, ssb.list.x + ssb.list.w * 0.5f, ssb.list.y + local, SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_ROW);
        CHECK_EQI(hit.index, (int)floorf(local + sm.sidebar_scroll_y));
        /* Even with zero chapter rows: the Search list does not depend on the
         * Chapters row count. */
        hit = route(&sl, &sm, ssb.list.x + 3.0f, ssb.list.y + 1.0f, SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_ROW);
        CHECK(hit.index >= 0);
        /* Below the list is still panel, never canvas. */
        CHECK(route(&sl, &sm, ssb.list.x + 3.0f, sl.sidebar.y + sl.sidebar.h - 1.0f, SPDF_WIN_CB_LEFT).action !=
              SPDF_WIN_CA_CANVAS);
        /* A hover over the list is nothing. */
        CHECK_EQI(route(&sl, &sm, ssb.list.x + 3.0f, ssb.list.y + local, SPDF_WIN_CB_NONE).action, SPDF_WIN_CA_NONE);
    }
}

/* --- the minimap strip ---------------------------------------------------- */

/* A left press inside the strip is the minimap's; the caller decides click or
 * drag against the painted frame. Nothing in the strip pans, hovers show an
 * arrow, and the other buttons are inert. */
static void test_minimap_press(float dpi) {
    SpdfWinChromeModel m = model_live(10);
    SpdfWinChromeLayout l;
    SpdfWinChromeHit hit;
    float x, y, fy;

    spdf_win_chrome_layout(&m, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &l);
    CHECK(!spdf_win_chrome_rect_empty(l.minimap));
    x = l.minimap.x + l.minimap.w * 0.5f;
    for (fy = 0.05f; fy < 1.0f; fy += 0.3f) {
        y = l.minimap.y + l.minimap.h * fy;
        hit = route(&l, &m, x, y, SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.part, SPDF_WIN_CHROME_MINIMAP);
        CHECK_EQI(hit.action, SPDF_WIN_CA_MINIMAP);
        hit = route(&l, &m, x, y, SPDF_WIN_CB_NONE);
        CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
        CHECK_EQI(hit.cursor, SPDF_WIN_CC_ARROW);
        CHECK_EQI(route(&l, &m, x, y, SPDF_WIN_CB_MIDDLE).action, SPDF_WIN_CA_NONE);
    }
    /* The divider beside it is still the divider, so a drag armed at its edge
     * resizes rather than jumps. */
    hit = route(&l, &m, l.minimap_divider.x + l.minimap_divider.w * 0.5f, l.minimap.y + l.minimap.h * 0.5f,
                SPDF_WIN_CB_LEFT);
    CHECK_EQI(hit.action, SPDF_WIN_CA_DRAG_MINIMAP);
    /* With the strip hidden there is no minimap part anywhere. */
    {
        SpdfWinChromeModel hidden = model_live(10);
        SpdfWinChromeLayout hl;
        hidden.show_minimap = 0;
        spdf_win_chrome_layout(&hidden, (unsigned)(1400.0f * dpi), (unsigned)(900.0f * dpi), dpi, &hl);
        CHECK(route(&hl, &hidden, x, l.minimap.y + l.minimap.h * 0.5f, SPDF_WIN_CB_LEFT).action !=
              SPDF_WIN_CA_MINIMAP);
    }
}

int main(void) {
    float scales[3];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.5f; /* this machine's own 144 dpi -- the fractional case */
    scales[2] = 2.0f;

    for (i = 0; i < 3; ++i) {
        test_toolbar_fields(scales[i]);
        test_sidebar_filter_and_rows(scales[i]);
        test_no_sidebar_pixel_pans(scales[i]);
        test_sidebar_sections_and_search_rows(scales[i]);
        test_minimap_press(scales[i]);
    }
    test_tab_drop_destination();

    printf("chrome_field_input_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
