/* chrome_input_test.c — pins portable/win/src/spdf_win_chrome_toolbar.h and
 * portable/win/src/spdf_win_chrome_input.h.
 *
 * WHAT IT IS FOR. The chrome became clickable, and the thing most likely to go
 * wrong when that happens is not the arithmetic: it is that a press somewhere in
 * the chrome falls through and pans the document. That is one assertion --
 * "sweep every pixel of every chrome band and check that not one of them routes
 * to the canvas" -- and it needs no HWND, no desktop and no document, so it is
 * checked exhaustively rather than by clicking around a window.
 *
 * The second thing that goes wrong is hit-testing and painting disagreeing. The
 * defence is structural (both call spdf_win_toolbar_layout) and the check here is
 * the other half of it: the centre of every rect the layout produces must
 * hit-test back to the item that produced it, at 100%, 150% and 200%.
 *
 * The SCROLLERS are routed by the same header and checked in
 * chrome_scroll_input_test.c rather than here, because the two suites together
 * would be past the 500-line cap. What stays here is the sweep over the bands
 * and panels; the sweep over the two troughs is the first function there. The
 * TITLE-BAR policy -- which strip pixels drag the window and which are the three
 * caption buttons (SpdfWinChromeHit::nc) -- is chrome_nc_test.c, split off for
 * the same reason.
 *
 * Both headers are header-only, so no `spdf-test-sources` line is needed --
 * same as chrome_geometry_test.c and tabstrip_geometry_test.c.
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

/* --- the toolbar's table ------------------------------------------------- */

static void test_toolbar_layout_is_ordered_and_inside(float dpi, int markdown) {
    SpdfWinChromeModel m = model_with_tabs(3, 0);
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout tb;
    int i, previous = -1;
    unsigned w = (unsigned)(1120.0f * dpi), h = (unsigned)(800.0f * dpi);

    m.markdown = markdown;
    spdf_win_chrome_layout(&m, w, h, dpi, &l);
    spdf_win_toolbar_layout(l.toolbar, dpi, m.markdown, &tb);
    CHECK(!spdf_win_chrome_rect_empty(l.toolbar));
    /* The Markdown pill is in the row on a Markdown tab and out of it on a PDF,
     * which is the whole of its visibility rule. */
    CHECK(spdf_win_chrome_rect_empty(tb.item[SPDF_WIN_TB_MD_TEXT_PILL]) == !markdown);

    for (i = SPDF_WIN_TB_NONE + 1; i < SPDF_WIN_TB_ITEM_COUNT; ++i) {
        SpdfWinChromeRect r = tb.item[i];
        if (spdf_win_chrome_rect_empty(r)) continue;
        /* Inside the bar, vertically and horizontally. A control that hangs off
         * the row draws over the tab strip above it or the canvas below. */
        CHECK(r.x >= l.toolbar.x);
        CHECK(r.x + r.w <= l.toolbar.x + l.toolbar.w);
        CHECK(r.y >= l.toolbar.y);
        CHECK(r.y + r.h <= l.toolbar.y + l.toolbar.h);
        /* No two controls overlap, in the enum's own order -- which is also
         * left-to-right order, and asserting both at once is what would catch a
         * forgotten advance in the layout's forward walk. */
        if (previous >= 0) CHECK(r.x >= tb.item[previous].x + tb.item[previous].w);
        previous = i;
    }
}

/* THE AGREEMENT CHECK: every rect the layout produced hit-tests back to itself.
 * The separator is excluded because spdf_win_toolbar_hit deliberately ignores
 * it -- it is a hairline of decoration, not a target. */
static void test_toolbar_hit_agrees_with_layout(float dpi, int markdown) {
    SpdfWinChromeModel m = model_with_tabs(3, 0);
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout tb;
    int i;

    m.markdown = markdown;
    spdf_win_chrome_layout(&m, (unsigned)(1120.0f * dpi), (unsigned)(800.0f * dpi), dpi, &l);
    spdf_win_toolbar_layout(l.toolbar, dpi, m.markdown, &tb);

    for (i = SPDF_WIN_TB_NONE + 1; i < SPDF_WIN_TB_ITEM_COUNT; ++i) {
        SpdfWinChromeRect r = tb.item[i];
        int segment = -1;
        if (i == SPDF_WIN_TB_SEPARATOR || spdf_win_chrome_rect_empty(r)) continue;
        CHECK_EQI(spdf_win_toolbar_hit(&tb, r.x + r.w * 0.5f, r.y + r.h * 0.5f, &segment), i);
        /* Corners too: the top-left is inclusive and the bottom-right exclusive,
         * which is the convention spdf_win_chrome_contains states. */
        CHECK_EQI(spdf_win_toolbar_hit(&tb, r.x, r.y, &segment), i);
        CHECK(spdf_win_toolbar_hit(&tb, r.x + r.w, r.y + r.h, &segment) != i);
    }
}

/* Both halves of every pill, because a swapped pair is a prev button that pages
 * forward, a minus that zooms in, or an A− that makes the text bigger. */
static void test_pill_segments(void) {
    SpdfWinChromeModel m = model_with_tabs(3, 0);
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout tb;
    int ids[4];
    int k;

    ids[0] = SPDF_WIN_TB_PAGE_PILL;
    ids[1] = SPDF_WIN_TB_ZOOM_PILL;
    ids[2] = SPDF_WIN_TB_FIND_PILL;
    ids[3] = SPDF_WIN_TB_MD_TEXT_PILL;
    m.markdown = 1; /* or the fourth pill is not in the row to split */
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);
    spdf_win_toolbar_layout(l.toolbar, 1.0f, m.markdown, &tb);

    for (k = 0; k < 4; ++k) {
        SpdfWinChromeRect r = tb.item[ids[k]];
        int segment = -1;
        if (spdf_win_chrome_rect_empty(r)) continue;
        CHECK_EQI(spdf_win_toolbar_hit(&tb, r.x + r.w * 0.25f, r.y + r.h * 0.5f, &segment), ids[k]);
        CHECK_EQI(segment, 0);
        CHECK_EQI(spdf_win_toolbar_hit(&tb, r.x + r.w * 0.75f, r.y + r.h * 0.5f, &segment), ids[k]);
        CHECK_EQI(segment, 1);
        /* The split is exactly where the painter drew the divider. */
        CHECK_EQI(spdf_win_toolbar_hit(&tb, spdf_win_toolbar_cell(r, 1, 2).x, r.y + r.h * 0.5f, &segment), ids[k]);
        CHECK_EQI(segment, 1);
    }
    /* A non-pill reports segment 0, never a stale value. */
    {
        int segment = 7;
        SpdfWinChromeRect r = tb.item[SPDF_WIN_TB_FIT_POPUP];
        CHECK_EQI(spdf_win_toolbar_hit(&tb, r.x + 1.0f, r.y + 1.0f, &segment), SPDF_WIN_TB_FIT_POPUP);
        CHECK_EQI(segment, 0);
    }
}

/* The find group is the one place the forward and backward walks interact. */
static void test_find_group_drops_when_narrow(void) {
    SpdfWinChromeModel m = model_with_tabs(1, 0);
    SpdfWinChromeLayout wide, narrow;
    SpdfWinToolbarLayout tw, tn;

    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &wide);
    spdf_win_toolbar_layout(wide.toolbar, 1.0f, 0, &tw);
    CHECK(!spdf_win_chrome_rect_empty(tw.item[SPDF_WIN_TB_FIND_FIELD]));
    CHECK(!spdf_win_chrome_rect_empty(tw.item[SPDF_WIN_TB_FIND_PILL]));

    /* macOS's own minimum content width. The row cannot hold the find group
     * there, and the controls that remain must still not overlap. */
    spdf_win_chrome_layout(&m, (unsigned)SPDF_WIN_CHROME_MIN_CONTENT_W, 800, 1.0f, &narrow);
    spdf_win_toolbar_layout(narrow.toolbar, 1.0f, 0, &tn);
    CHECK(spdf_win_chrome_rect_empty(tn.item[SPDF_WIN_TB_FIND_FIELD]));
    CHECK(spdf_win_chrome_rect_empty(tn.item[SPDF_WIN_TB_FIND_PILL]));
    CHECK(!spdf_win_chrome_rect_empty(tn.item[SPDF_WIN_TB_MINIMAP_TOGGLE]));
    CHECK(tn.item[SPDF_WIN_TB_MINIMAP_TOGGLE].x + tn.item[SPDF_WIN_TB_MINIMAP_TOGGLE].w <=
          narrow.toolbar.x + narrow.toolbar.w);

    /* An empty bar -- presentation mode, or a window too small for the bands --
     * must produce an all-empty table rather than rects at the origin. */
    {
        SpdfWinToolbarLayout empty;
        int i;
        spdf_win_toolbar_layout(spdf_win_chrome_zero(), 1.0f, 1, &empty);
        for (i = 0; i < SPDF_WIN_TB_ITEM_COUNT; ++i) CHECK(spdf_win_chrome_rect_empty(empty.item[i]));
        CHECK_EQI(spdf_win_toolbar_hit(&empty, 10.0f, 10.0f, NULL), SPDF_WIN_TB_NONE);
    }
}

/* --- routing ------------------------------------------------------------- */

static SpdfWinChromeHit route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m, float x, float y, int button) {
    SpdfWinChromeHit hit;
    spdf_win_chrome_input_route(l, m, x, y, button, &hit);
    return hit;
}

/* THE HEADLINE ASSERTION. Not one pixel of the tab strip, the toolbar, either
 * side panel or either divider may route to the canvas -- with either button.
 * A press that fell through would pan the document, which is the exact
 * regression this whole change risked introducing. */
/* `live` turns on the two states that only exist once the chrome is typeable: a
 * search query (which RAISES the sidebar's minimum width, so it changes the
 * layout the sweep runs over) and a filled chapter list (which makes the sidebar
 * route rows rather than swallowing every press). Both are configurations a
 * reader is in for most of a session and neither existed when this sweep was
 * written; running it in both is what keeps "no chrome pixel pans the document"
 * true of the app people actually use. */
static void test_no_chrome_pixel_routes_to_the_canvas_in(float dpi, int live) {
    SpdfWinChromeModel m = model_with_tabs(5, 2);
    SpdfWinChromeLayout l;
    unsigned w = (unsigned)(1120.0f * dpi), h = (unsigned)(800.0f * dpi);
    float x, y;
    int buttons[2];
    int b;

    buttons[0] = SPDF_WIN_CB_LEFT;
    buttons[1] = SPDF_WIN_CB_MIDDLE;
    if (live) {
        m.query = L"outline";
        m.search_active = 1;
        m.sidebar_row_count = 40;
    }
    spdf_win_chrome_layout(&m, w, h, dpi, &l);

    for (b = 0; b < 2; ++b) {
        /* Both bands, every 3 px across and every 5 px down: dense enough to
         * cross every control boundary and cheap enough to run every build. */
        for (y = l.tabstrip.y; y < l.toolbar.y + l.toolbar.h; y += 5.0f)
            for (x = 0.0f; x < (float)w; x += 3.0f) CHECK(route(&l, &m, x, y, buttons[b]).action != SPDF_WIN_CA_CANVAS);
        /* The panels and the dividers, down the middle of the split row. */
        y = l.canvas.y + l.canvas.h * 0.5f;
        for (x = l.sidebar.x; x < l.sidebar.x + l.sidebar.w + l.sidebar_divider.w; x += 3.0f)
            CHECK(route(&l, &m, x, y, buttons[b]).action != SPDF_WIN_CA_CANVAS);
        for (x = l.minimap_divider.x; x < l.minimap.x + l.minimap.w; x += 3.0f)
            CHECK(route(&l, &m, x, y, buttons[b]).action != SPDF_WIN_CA_CANVAS);
    }

    /* And the converse: the canvas's own middle DOES route to the canvas, with
     * both buttons, or drag-to-pan is gone. */
    CHECK_EQI(route(&l, &m, l.canvas.x + l.canvas.w * 0.5f, l.canvas.y + l.canvas.h * 0.5f, SPDF_WIN_CB_LEFT).action,
              SPDF_WIN_CA_CANVAS);
    CHECK_EQI(route(&l, &m, l.canvas.x + l.canvas.w * 0.5f, l.canvas.y + l.canvas.h * 0.5f, SPDF_WIN_CB_MIDDLE).action,
              SPDF_WIN_CA_CANVAS);
    /* A bare hover over the canvas is CANVAS too, and asks for an arrow: the
     * pan cursor belongs to the drag, not to the position. */
    CHECK_EQI(route(&l, &m, l.canvas.x + 5.0f, l.canvas.y + 5.0f, SPDF_WIN_CB_NONE).cursor, SPDF_WIN_CC_ARROW);
}

static void test_toolbar_actions(void) {
    SpdfWinChromeModel m = model_with_tabs(3, 1);
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout tb;
    m.markdown = 1; /* so the A−/A＋ pill is in the row to be clicked */
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);
    spdf_win_toolbar_layout(l.toolbar, 1.0f, m.markdown, &tb);

#define AT(id, fx) (tb.item[id].x + tb.item[id].w * (fx)), (tb.item[id].y + tb.item[id].h * 0.5f)
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_SIDEBAR_TOGGLE, 0.5f), SPDF_WIN_CB_LEFT).action,
              SPDF_WIN_CA_TOGGLE_SIDEBAR);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_MINIMAP_TOGGLE, 0.5f), SPDF_WIN_CB_LEFT).action,
              SPDF_WIN_CA_TOGGLE_MINIMAP);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_READING_THEME, 0.5f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_TOGGLE_THEME);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_FIT_POPUP, 0.5f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_CYCLE_FIT);
    /* chevron.left is the FIRST segment, minus is the first of the zoom pill.
     * Reversing either is a silent product bug, not a crash. */
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_PAGE_PILL, 0.25f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_PREV_PAGE);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_PAGE_PILL, 0.75f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_NEXT_PAGE);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_ZOOM_PILL, 0.25f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_ZOOM_OUT);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_ZOOM_PILL, 0.75f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_ZOOM_IN);
    /* The two power tools name their intent; the caller posts the command. */
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_OCR, 0.5f), SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_OCR);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_TRANSLATE, 0.5f), SPDF_WIN_CB_LEFT).action,
              SPDF_WIN_CA_TRANSLATE_SELECTION);
    /* The Markdown pill's own two halves, and the PDF row it must not disturb,
     * are toolbar_route_test.c -- this file was at the line cap. */
    /* Nothing is wired to the middle button in the toolbar, and a hover is not a
     * click. Both must be inert rather than firing the left-button action. */
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_ZOOM_PILL, 0.75f), SPDF_WIN_CB_MIDDLE).action, SPDF_WIN_CA_NONE);
    CHECK_EQI(route(&l, &m, AT(SPDF_WIN_TB_SIDEBAR_TOGGLE, 0.5f), SPDF_WIN_CB_NONE).action, SPDF_WIN_CA_NONE);
    /* A gap between two controls is toolbar, not canvas and not an action. */
    CHECK_EQI(route(&l, &m, tb.item[SPDF_WIN_TB_OCR].x - 2.0f, tb.item[SPDF_WIN_TB_OCR].y, SPDF_WIN_CB_LEFT).action,
              SPDF_WIN_CA_NONE);
#undef AT
}

static void test_tabstrip_actions(void) {
    SpdfWinChromeModel m = model_with_tabs(4, 1);
    SpdfWinChromeLayout l;
    SpdfWinTabRect tab, close;
    float strip_w, mid_y;
    int i;

    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);
    strip_w = l.tabstrip.w; /* dpi 1, so points and pixels coincide here */
    mid_y = l.tabstrip.y + l.tabstrip.h * 0.5f;

    for (i = 0; i < m.tab_count; ++i) {
        SpdfWinChromeHit hit;
        tab = spdf_win_tabstrip_tab_rect(strip_w, m.tab_count, m.selected_tab, i);
        CHECK(!spdf_win_tabstrip_rect_is_empty(tab));
        /* The title area, left of the close box. */
        hit = route(&l, &m, (float)tab.x + 4.0f, mid_y, SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.action, SPDF_WIN_CA_SELECT_TAB);
        CHECK_EQI(hit.index, i);
        /* Hover reports the tab as hot without selecting it. */
        hit = route(&l, &m, (float)tab.x + 4.0f, mid_y, SPDF_WIN_CB_NONE);
        CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
        CHECK_EQI(hit.hot_tab, i);
        CHECK_EQI(hit.hot_close, -1);

        /* The close box wins over the tab, or every close click selects. */
        close = spdf_win_tabstrip_close_rect(tab);
        hit = route(&l, &m, (float)(close.x + close.w / 2.0), (float)(close.y + close.h / 2.0), SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.action, SPDF_WIN_CA_CLOSE_TAB);
        CHECK_EQI(hit.index, i);
        hit = route(&l, &m, (float)(close.x + close.w / 2.0), (float)(close.y + close.h / 2.0), SPDF_WIN_CB_NONE);
        CHECK_EQI(hit.hot_close, i);

        /* MIDDLE-CLICK CLOSES, anywhere on the tab -- macOS's behaviour and the
         * desktop's. Aimed at the title, not at the close circle. */
        hit = route(&l, &m, (float)tab.x + 4.0f, mid_y, SPDF_WIN_CB_MIDDLE);
        CHECK_EQI(hit.action, SPDF_WIN_CA_CLOSE_TAB);
        CHECK_EQI(hit.index, i);
    }

    /* The `+`. */
    {
        SpdfWinTabRect plus = spdf_win_tabstrip_plus_rect(strip_w);
        CHECK_EQI(route(&l, &m, (float)(plus.x + plus.w / 2.0), mid_y, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_NEW_TAB);
    }
    /* Overflow appears only when the tabs do not fit; forty of them in 1120 pt
     * do not. */
    {
        SpdfWinChromeModel many = model_with_tabs(40, 20);
        SpdfWinTabRect ov;
        CHECK(spdf_win_tabstrip_has_overflow(strip_w, many.tab_count));
        ov = spdf_win_tabstrip_overflow_rect(strip_w, many.tab_count);
        CHECK_EQI(route(&l, &many, (float)(ov.x + ov.w / 2.0), mid_y, SPDF_WIN_CB_LEFT).action,
                  SPDF_WIN_CA_TAB_OVERFLOW);
    }
    /* An empty strip: no tabs, so no tab actions and nothing hot. */
    {
        SpdfWinChromeModel none = model_with_tabs(0, -1);
        SpdfWinChromeHit hit = route(&l, &none, 100.0f, mid_y, SPDF_WIN_CB_LEFT);
        CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
        CHECK_EQI(hit.hot_tab, -1);
    }
}

static void test_dividers(void) {
    SpdfWinChromeModel m = model_with_tabs(2, 0);
    SpdfWinChromeLayout l;
    SpdfWinChromeHit hit;
    float y;

    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);
    y = l.canvas.y + l.canvas.h * 0.5f;

    /* Hover asks for the left-right resize cursor -- macOS's resizeLeftRight
     * (SPDFMacUIHelpers.mm:425-431) -- and does NOT arm a drag. */
    hit = route(&l, &m, l.sidebar_divider.x + l.sidebar_divider.w * 0.5f, y, SPDF_WIN_CB_NONE);
    CHECK_EQI(hit.part, SPDF_WIN_CHROME_SIDEBAR_DIVIDER);
    CHECK_EQI(hit.cursor, SPDF_WIN_CC_SIZEWE);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);

    hit = route(&l, &m, l.sidebar_divider.x + l.sidebar_divider.w * 0.5f, y, SPDF_WIN_CB_LEFT);
    CHECK_EQI(hit.action, SPDF_WIN_CA_DRAG_SIDEBAR);
    hit = route(&l, &m, l.minimap_divider.x + l.minimap_divider.w * 0.5f, y, SPDF_WIN_CB_LEFT);
    CHECK_EQI(hit.action, SPDF_WIN_CA_DRAG_MINIMAP);

    /* The clamps are macOS's, and a drag past either end must stop rather than
     * run away -- the reason the drag helpers exist at all. */
    CHECK(spdf_win_chrome_sidebar_drag_pt(&l, 1.0f, 0) == (float)SPDF_WIN_CHROME_SIDEBAR_MIN_W);
    CHECK(spdf_win_chrome_sidebar_drag_pt(&l, 5000.0f, 0) <= (float)SPDF_WIN_CHROME_SIDEBAR_MAX_W);
    CHECK(spdf_win_chrome_minimap_drag_pt(&l, l.minimap.x + l.minimap.w - 1.0f) ==
          (float)SPDF_WIN_CHROME_MINIMAP_MIN_W);
    CHECK(spdf_win_chrome_minimap_drag_pt(&l, 0.0f) <= (float)SPDF_WIN_CHROME_MINIMAP_MAX_W);
    /* AND A QUIRK WORTH PINNING RATHER THAN FIXING. Both clamps read a want of
     * exactly 0 (or less) as "give me the DEFAULT width" --
     * spdf_win_chrome_clamp_sidebar_pt's `if (want_pt <= 0.0f) want_pt = 240`.
     * So a drag that lands precisely on the panel's own origin snaps to 240
     * rather than to the 176 minimum. That overload is load-bearing elsewhere:
     * it is how a model with sidebar_w == 0 asks for the macOS default. Pinned
     * here so nobody "fixes" the drag by changing the clamp and quietly breaks
     * every default-width caller. */
    CHECK(spdf_win_chrome_sidebar_drag_pt(&l, 0.0f, 0) == (float)SPDF_WIN_CHROME_SIDEBAR_W);
    CHECK(spdf_win_chrome_minimap_drag_pt(&l, 5000.0f) == (float)SPDF_WIN_CHROME_MINIMAP_W);
    /* The search section raises the minimum to 216 (:72-76). */
    CHECK(spdf_win_chrome_sidebar_drag_pt(&l, 1.0f, 1) == (float)SPDF_WIN_CHROME_SIDEBAR_SEARCH_MIN_W);
}


/* The conversion whose absence made a cursor-anchored zoom drift. */
static void test_canvas_local_conversion(void) {
    SpdfWinChromeModel m = model_with_tabs(1, 0);
    SpdfWinChromeLayout l;
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);

    CHECK(l.canvas.x > 0.0f); /* there IS an offset to subtract, with a sidebar */
    CHECK(l.canvas.y > 0.0f); /* and one from the two bands */
    CHECK(spdf_win_chrome_input_canvas_x(&l, l.canvas.x) == 0.0f);
    CHECK(spdf_win_chrome_input_canvas_y(&l, l.canvas.y) == 0.0f);
    CHECK(spdf_win_chrome_input_canvas_x(&l, l.canvas.x + 17.0f) == 17.0f);
    CHECK(spdf_win_chrome_input_canvas_y(&l, l.canvas.y + 17.0f) == 17.0f);
    /* A NULL layout passes the point through, which is the no-chrome case every
     * pre-chrome caller and the headless probe are in. */
    CHECK(spdf_win_chrome_input_canvas_x(NULL, 42.0f) == 42.0f);
}

/* --- the readouts the toolbar draws ------------------------------------- */

/* Nothing may crash or route on a NULL layout or model -- the state the window
 * is in before its first paint has divided anything. */
static void test_degenerate_inputs(void) {
    SpdfWinChromeModel m = model_with_tabs(2, 0);
    SpdfWinChromeLayout l;
    SpdfWinChromeHit hit;
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);

    spdf_win_chrome_input_route(NULL, &m, 10.0f, 10.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
    CHECK_EQI(hit.hot_tab, -1);
    CHECK_EQI(hit.cursor, SPDF_WIN_CC_ARROW);
    spdf_win_chrome_input_route(&l, NULL, 10.0f, 10.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
    /* A point outside the window entirely. */
    spdf_win_chrome_input_route(&l, &m, -5.0f, -5.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
    spdf_win_chrome_input_route(&l, &m, 99999.0f, 99999.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
    spdf_win_chrome_input_route(NULL, NULL, 0.0f, 0.0f, 0, NULL); /* must not crash */
}

int main(void) {
    float scales[3];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.5f; /* this machine's own 144 dpi -- the fractional case */
    scales[2] = 2.0f;

    for (i = 0; i < 3; ++i) {
        /* Both rows at every scale: the PDF one and the Markdown one, which
         * differ by a control in the middle of the forward walk. */
        test_toolbar_layout_is_ordered_and_inside(scales[i], 0);
        test_toolbar_layout_is_ordered_and_inside(scales[i], 1);
        test_toolbar_hit_agrees_with_layout(scales[i], 0);
        test_toolbar_hit_agrees_with_layout(scales[i], 1);
        test_no_chrome_pixel_routes_to_the_canvas_in(scales[i], 0);
        test_no_chrome_pixel_routes_to_the_canvas_in(scales[i], 1);
    }
    test_pill_segments();
    test_find_group_drops_when_narrow();
    test_toolbar_actions();
    test_tabstrip_actions();
    test_dividers();
    test_canvas_local_conversion();
    test_degenerate_inputs();

    printf("chrome_input_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
