/* empty_state_test.c — pins portable/win/src/spdf_win_chrome_empty.h: what a
 * window with NO DOCUMENT may offer, and the one control it must.
 *
 * WHAT WENT WRONG, AND WHAT THIS FILE IS FOR. A bare launch drew the full
 * toolbar at full contrast with every document-dependent control inert, and the
 * only way out of that state was a keyboard shortcut named in a line of grey
 * text. The app was reported twice as "never responsive to any user input"; the
 * window was in fact foreground, enabled and unhung the whole time. So the
 * regression this file exists to catch is not a crash -- it is a control that
 * looks live and is not, which no crash test and no launch-health probe can see.
 *
 * THE TWO INVARIANTS, and they are two halves of one thing:
 *
 *   1. A control the PAINTER dims is a control the ROUTER refuses, because both
 *      ask spdf_win_toolbar_item_enabled() and neither decides for itself. Test
 *      by walking the WHOLE row: every item is either enabled and routed, or
 *      disabled and refused. A future control added to the row is covered the
 *      day it is added, without this file being edited -- which is the only kind
 *      of coverage that survives.
 *
 *   2. The disable moves NOTHING. Every rect in the row is byte-identical with
 *      and without a document, at every DPI. That is the failure mode
 *      spdf_win_chrome_toolbar.h was created to prevent and the one the layout
 *      differential and the headless compose comparison would otherwise catch
 *      only after the fact.
 *
 * AND THE WAY IN: the "Open a PDF..." button is present, hit-testable, and
 * routed to SPDF_WIN_CA_OPEN_DOC -- and ABSENT on every window that has
 * anything open, including a tab whose document failed to load, which has its
 * own message to show.
 *
 * Header-only under test, so no `spdf-test-sources` line is needed.
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
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* The populated model this port's other chrome tests use, so "with a document"
 * here means the same thing it means in chrome_input_test.c and
 * toolbar_route_test.c. */
static SpdfWinChromeModel doc_model(void) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.tab_count = 2;
    m.selected_tab = 0;
    m.page_index = 3;
    m.page_count = 117;
    m.zoom = 1.0f;
    m.zoom_dpi_scale = 1.0f;
    m.fit_mode = SPDF_WIN_CHROME_FIT_WIDTH;
    return m;
}

/* THE BARE LAUNCH, exactly as spdf_win_chrome_model_inputs_init() leaves it:
 * page_index -1 and page_count 0 are what the model documents as "no document",
 * and no tabs is what -performStartupDocumentWork's else arm produces. */
static SpdfWinChromeModel empty_model(void) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.hot_tab = -1;
    m.hot_close = -1;
    m.selected_tab = -1;
    m.page_index = -1;
    m.page_count = 0;
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

/* --- 1. has_document, and the vocabulary built on it -------------------- */

static void test_has_document(void) {
    SpdfWinChromeModel doc = doc_model();
    SpdfWinChromeModel empty = empty_model();
    SpdfWinChromeColor c = spdf_win_ct_rgb(0x336699u, 0.8f);
    SpdfWinChromeColor dim = spdf_win_chrome_dim(c, 0);
    SpdfWinChromeColor keep = spdf_win_chrome_dim(c, 1);

    CHECK(spdf_win_chrome_has_document(&doc));
    CHECK(!spdf_win_chrome_has_document(&empty));
    /* A NULL model is "no document", not a crash: the router and the painter are
     * both called before the first paint has laid anything out. */
    CHECK(!spdf_win_chrome_has_document(NULL));

    /* A ONE-PAGE DOCUMENT IS A DOCUMENT. The boundary matters because the test
     * is `> 0` and an off-by-one here would grey the entire toolbar of every
     * single-page PDF -- a large class of real files (a scanned receipt, a
     * boarding pass) and exactly the sort of thing nobody opens while testing. */
    empty.page_count = 1;
    empty.page_index = 0;
    CHECK(spdf_win_chrome_has_document(&empty));

    /* Dimming touches ALPHA and nothing else, so a disabled control is the same
     * colour the theme chose, quieter -- not a second grey. */
    CHECK(dim.r == c.r && dim.g == c.g && dim.b == c.b);
    CHECK(dim.a < c.a && dim.a > 0.0f);
    CHECK(keep.a == c.a);
}

/* --- 2. the row: dimmed means refused, and nothing moved ----------------- */

/* Every control macOS's -updateControls disables, and the three it does not.
 * Spelled out here as well as in the header so the LIST is pinned and not just
 * the mechanism: silently dropping the Map toggle out of the switch would
 * otherwise pass every other assertion in this file. */
static void test_needs_document_list(void) {
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_SIDEBAR_TOGGLE));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_OCR));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_TRANSLATE));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_PAGE_FIELD));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_PAGE_COUNT));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_PAGE_PILL));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_FIT_POPUP));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_ZOOM_PILL));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_MD_TEXT_PILL));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_FIND_FIELD));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_FIND_REGEX));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_FIND_COUNT));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_FIND_PILL));
    CHECK(spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_MINIMAP_TOGGLE));
    /* The three that stay live, each for a stated reason (see the header):
     * decoration, this port's File menu, and a setting rather than a document
     * property. */
    CHECK(!spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_SEPARATOR));
    CHECK(!spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_OVERFLOW));
    CHECK(!spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_READING_THEME));
    /* SPDF_WIN_TB_NONE is a miss, and a miss needs nothing. */
    CHECK(!spdf_win_toolbar_item_needs_document(SPDF_WIN_TB_NONE));
}

/* THE WHOLE ROW, WALKED. A click at the centre of every control that is in the
 * row, with and without a document, against the ONE predicate both sides share.
 *
 * The with-document half deliberately asserts a RELATION rather than restating
 * chrome_input_test.c's and dpi_hit_parity_test.c's tables of expected actions:
 * that the new gate is a no-op on a populated row, because
 * spdf_win_toolbar_item_enabled() is true for every item there. Restating the
 * action map would be a second copy of it to keep in step; asserting that the
 * gate cannot fire is what actually says "the populated row is untouched". */
static void test_row_refusal(float dpi) {
    SpdfWinChromeModel doc = doc_model();
    SpdfWinChromeModel empty = empty_model();
    SpdfWinChromeLayout ld, le;
    SpdfWinToolbarLayout td, te;
    int i;
    unsigned w = (unsigned)(1400.0f * dpi), h = (unsigned)(900.0f * dpi);

    spdf_win_chrome_layout(&doc, w, h, dpi, &ld);
    spdf_win_chrome_layout(&empty, w, h, dpi, &le);
    /* Same `markdown` on both sides: this test is about the DOCUMENT's presence,
     * not about which kind it is. The Markdown pill's own effect on the row is
     * toolbar_route_test.c's. */
    spdf_win_toolbar_layout(ld.toolbar, dpi, 0, &td);
    spdf_win_toolbar_layout(le.toolbar, dpi, 0, &te);

    for (i = SPDF_WIN_TB_NONE + 1; i < SPDF_WIN_TB_ITEM_COUNT; ++i) {
        SpdfWinChromeRect r = td.item[i];
        float cx, cy;

        /* THE TOOLBAR'S RECTS ARE IDENTICAL WITH AND WITHOUT A DOCUMENT. The
         * whole change is a colour and a refusal; if a single edge moved, the
         * layout differential and every headless expectation would be wrong and
         * this is where it shows up first. */
        CHECK(te.item[i].x == r.x && te.item[i].y == r.y);
        CHECK(te.item[i].w == r.w && te.item[i].h == r.h);

        if (spdf_win_chrome_rect_empty(r)) continue; /* not in this row */
        if (i == SPDF_WIN_TB_SEPARATOR) continue;    /* a hairline the router skips */
        cx = r.x + r.w * 0.5f;
        cy = r.y + r.h * 0.5f;

        /* WITH a document EVERY item is live, so the new gate cannot fire on a
         * populated row -- which is the whole of "the with-document behaviour is
         * untouched", stated as the property rather than as a second copy of
         * chrome_input_test.c's action table. */
        CHECK(spdf_win_toolbar_item_enabled(&doc, i));
        CHECK_EQI(route(&ld, &doc, cx, cy, SPDF_WIN_CB_LEFT).part, SPDF_WIN_CHROME_TOOLBAR);

        if (spdf_win_toolbar_item_needs_document(i)) {
            /* Dimmed and refused, and refused is NOT the same as forwarded: a
             * press on the toolbar must never reach the document, which is the
             * rule the whole router is built on. */
            CHECK(!spdf_win_toolbar_item_enabled(&empty, i));
            CHECK_EQI(route(&le, &empty, cx, cy, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_NONE);
            CHECK_EQI(route(&le, &empty, cx, cy, SPDF_WIN_CB_LEFT).part, SPDF_WIN_CHROME_TOOLBAR);
        } else {
            /* Left alone: the SAME action with and without a document, so the
             * empty window's remaining chrome behaves identically to a populated
             * window's. */
            CHECK(spdf_win_toolbar_item_enabled(&empty, i));
            CHECK_EQI(route(&le, &empty, cx, cy, SPDF_WIN_CB_LEFT).action,
                      route(&ld, &doc, cx, cy, SPDF_WIN_CB_LEFT).action);
        }
    }

    /* THE TWO LABELS MAP TO NO ACTION EVEN WITH A DOCUMENT, and that is the
     * router's existing, deliberate behaviour rather than something this change
     * introduced: spdf_win_chrome_toolbar.h explains that the 64 pt find counter
     * is REPORTED by the hit test (a click on it is a click someone aimed) and
     * left for the router to decide about, and the router decides nothing. Pinned
     * here so the walk above cannot be "fixed" by asserting that every control
     * has an action. */
    {
        SpdfWinChromeRect pc = td.item[SPDF_WIN_TB_PAGE_COUNT];
        SpdfWinChromeRect fc = td.item[SPDF_WIN_TB_FIND_COUNT];
        CHECK_EQI(route(&ld, &doc, pc.x + pc.w * 0.5f, pc.y + pc.h * 0.5f, SPDF_WIN_CB_LEFT).action,
                  SPDF_WIN_CA_NONE);
        if (!spdf_win_chrome_rect_empty(fc))
            CHECK_EQI(route(&ld, &doc, fc.x + fc.w * 0.5f, fc.y + fc.h * 0.5f, SPDF_WIN_CB_LEFT).action,
                      SPDF_WIN_CA_NONE);
    }

    /* The two that must still work by name, because they are the empty window's
     * only remaining chrome: the app menu (this port's File menu) and the
     * reading theme. */
    {
        SpdfWinChromeRect o = te.item[SPDF_WIN_TB_OVERFLOW];
        SpdfWinChromeRect t = te.item[SPDF_WIN_TB_READING_THEME];
        CHECK(!spdf_win_chrome_rect_empty(o));
        CHECK_EQI(route(&le, &empty, o.x + o.w * 0.5f, o.y + o.h * 0.5f, SPDF_WIN_CB_LEFT).action,
                  SPDF_WIN_CA_APP_MENU);
        CHECK(!spdf_win_chrome_rect_empty(t));
        CHECK_EQI(route(&le, &empty, t.x + t.w * 0.5f, t.y + t.h * 0.5f, SPDF_WIN_CB_LEFT).action,
                  SPDF_WIN_CA_TOGGLE_THEME);
    }

    /* And the two that were the loudest lies, by name as well as by the walk:
     * the page arrows and the Map switch. Both halves of the page pill, since a
     * pill is refused as a whole and not one segment at a time. */
    {
        SpdfWinChromeRect p = te.item[SPDF_WIN_TB_PAGE_PILL];
        SpdfWinChromeRect map = te.item[SPDF_WIN_TB_MINIMAP_TOGGLE];
        float y = p.y + p.h * 0.5f;
        CHECK_EQI(route(&le, &empty, p.x + p.w * 0.25f, y, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_NONE);
        CHECK_EQI(route(&le, &empty, p.x + p.w * 0.75f, y, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_NONE);
        CHECK_EQI(route(&le, &empty, map.x + map.w * 0.5f, map.y + map.h * 0.5f, SPDF_WIN_CB_LEFT).action,
                  SPDF_WIN_CA_NONE);
        /* With a document they are exactly what they always were. */
        p = td.item[SPDF_WIN_TB_PAGE_PILL];
        y = p.y + p.h * 0.5f;
        CHECK_EQI(route(&ld, &doc, p.x + p.w * 0.25f, y, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_PREV_PAGE);
        CHECK_EQI(route(&ld, &doc, p.x + p.w * 0.75f, y, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_NEXT_PAGE);
        map = td.item[SPDF_WIN_TB_MINIMAP_TOGGLE];
        CHECK_EQI(route(&ld, &doc, map.x + map.w * 0.5f, map.y + map.h * 0.5f, SPDF_WIN_CB_LEFT).action,
                  SPDF_WIN_CA_TOGGLE_MINIMAP);
    }
}

/* --- 3. the way in ------------------------------------------------------- */

static void test_open_button(float dpi) {
    SpdfWinChromeModel empty = empty_model();
    SpdfWinChromeModel doc = doc_model();
    SpdfWinChromeLayout l;
    SpdfWinChromeRect b, hint;
    unsigned w = (unsigned)(1120.0f * dpi), h = (unsigned)(800.0f * dpi);
    float cx, cy;

    spdf_win_chrome_layout(&empty, w, h, dpi, &l);
    b = spdf_win_chrome_empty_open_rect(&l, &empty);
    hint = spdf_win_chrome_empty_hint_rect(&l, &empty);

    CHECK(!spdf_win_chrome_rect_empty(b));
    /* INSIDE THE CANVAS REGION, all four edges. A button drawn under the toolbar
     * band or past the scroller would be a button the reader cannot press, and
     * the chrome painters draw over the canvas region, not under it. */
    CHECK(b.x >= l.canvas.x && b.x + b.w <= l.canvas.x + l.canvas.w);
    CHECK(b.y >= l.canvas.y && b.y + b.h <= l.canvas.y + l.canvas.h);
    /* Horizontally centred, and BELOW the middle -- the placeholder line
     * draw_message() centres is what it has to stay clear of. */
    CHECK(b.x + b.w * 0.5f >= l.canvas.x + l.canvas.w * 0.5f - 1.0f);
    CHECK(b.x + b.w * 0.5f <= l.canvas.x + l.canvas.w * 0.5f + 1.0f);
    CHECK(b.y > l.canvas.y + l.canvas.h * 0.5f);
    /* Whole pixels, so the capsule's edge does not straddle two columns. */
    CHECK(b.x == floorf(b.x) && b.y == floorf(b.y));
    /* It scales with the display: 168 x 32 pt, whatever the DPI. */
    CHECK(b.w == spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_BUTTON_W, dpi));
    CHECK(b.h == spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_BUTTON_H, dpi));

    /* The drop hint is under it and still inside the canvas. */
    CHECK(!spdf_win_chrome_rect_empty(hint));
    CHECK(hint.y >= b.y + b.h);
    CHECK(hint.y + hint.h <= l.canvas.y + l.canvas.h);

    /* HIT-TESTABLE, and routed to the one command Ctrl+O and the strip's `+`
     * also post. */
    cx = b.x + b.w * 0.5f;
    cy = b.y + b.h * 0.5f;
    CHECK(spdf_win_chrome_empty_open_hit(&l, &empty, cx, cy));
    CHECK_EQI(spdf_win_chrome_hit(&l, cx, cy), SPDF_WIN_CHROME_CANVAS);
    CHECK_EQI(route(&l, &empty, cx, cy, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_OPEN_DOC);
    /* Every corner of it, not just the middle: the rect the router tests must be
     * the rect the painter filled. */
    CHECK_EQI(route(&l, &empty, b.x + 1.0f, b.y + 1.0f, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_OPEN_DOC);
    CHECK_EQI(route(&l, &empty, b.x + b.w - 1.0f, b.y + b.h - 1.0f, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_OPEN_DOC);
    /* Just outside is canvas again, and canvas with no document does nothing. */
    CHECK(!spdf_win_chrome_empty_open_hit(&l, &empty, b.x - 2.0f, cy));
    CHECK(!spdf_win_chrome_empty_open_hit(&l, &empty, cx, b.y - 4.0f));

    /* THE POINT IS CLAIMED WHATEVER THE BUTTON, hover included, so a press on it
     * can never become a document gesture -- the rule the minimap strip and the
     * two scrollers already follow. */
    CHECK_EQI(route(&l, &empty, cx, cy, SPDF_WIN_CB_MIDDLE).action, SPDF_WIN_CA_NONE);
    CHECK_EQI(route(&l, &empty, cx, cy, SPDF_WIN_CB_NONE).action, SPDF_WIN_CA_NONE);

    /* WITH A DOCUMENT THERE IS NO BUTTON, and the same point is ordinary canvas
     * -- which is what keeps a click in the middle of a page a click on the
     * page. */
    spdf_win_chrome_layout(&doc, w, h, dpi, &l);
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_open_rect(&l, &doc)));
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_hint_rect(&l, &doc)));
    CHECK_EQI(route(&l, &doc, cx, cy, SPDF_WIN_CB_LEFT).action, SPDF_WIN_CA_CANVAS);
}

static void test_open_button_absences(void) {
    SpdfWinChromeModel m = empty_model();
    SpdfWinChromeLayout l;

    /* A TAB WHOSE DOCUMENT FAILED TO OPEN has page_count 0 and a tab, and it has
     * its own message to show through scene->message. A 168 pt accent button
     * dropped on top of that would bury the only explanation the reader gets. */
    m.tab_count = 1;
    m.selected_tab = 0;
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);
    CHECK(!spdf_win_chrome_has_document(&m));
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_open_rect(&l, &m)));
    /* ...and the row is still refused there, because nothing in it can work. */
    CHECK(!spdf_win_toolbar_item_enabled(&m, SPDF_WIN_TB_PAGE_PILL));

    /* PRESENTATION MODE collapses the chrome to nothing; a button in the middle
     * of a presented page would be the loudest possible bug. */
    m = empty_model();
    m.presentation = 1;
    spdf_win_chrome_layout(&m, 1120, 800, 1.0f, &l);
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_open_rect(&l, &m)));

    /* A CANVAS TOO SMALL FOR IT: the button stands down rather than truncating
     * its label to "Open a..." or landing across the placeholder line. Ctrl+O,
     * the drop target and the overflow menu all still work.
     *
     * The window's own minimum size is what makes this reachable at all -- a
     * reader really can drag a window this small. */
    m = empty_model();
    spdf_win_chrome_layout(&m, 200, 700, 1.0f, &l);
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_open_rect(&l, &m)));
    spdf_win_chrome_layout(&m, 900, 150, 1.0f, &l);
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_open_rect(&l, &m)));
    /* Zero client area: no layout, no button, no crash. */
    spdf_win_chrome_layout(&m, 0, 0, 1.0f, &l);
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_open_rect(&l, &m)));

    /* NULL either side is "not on screen", not a crash: the router is called
     * before the first paint has laid anything out. */
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_open_rect(NULL, &m)));
    CHECK(spdf_win_chrome_rect_empty(spdf_win_chrome_empty_open_rect(&l, NULL)));
    CHECK(!spdf_win_chrome_empty_open_hit(NULL, NULL, 10.0f, 10.0f));
}

/* --- 4. the keyboard's focus target ------------------------------------- */

static void test_focus_value(void) {
    /* SPDF_WIN_FOCUS_OPEN must not collide with a FIELD, or a WM_CHAR would be
     * inserted into whichever buffer it aliased. It is deliberately last, and
     * NONE must stay 0 so a zeroed app means "the document has the keyboard". */
    CHECK_EQI(SPDF_WIN_FOCUS_NONE, 0);
    CHECK(SPDF_WIN_FOCUS_OPEN != SPDF_WIN_FOCUS_NONE);
    CHECK(SPDF_WIN_FOCUS_OPEN != SPDF_WIN_FOCUS_FIND);
    CHECK(SPDF_WIN_FOCUS_OPEN != SPDF_WIN_FOCUS_PAGE);
    CHECK(SPDF_WIN_FOCUS_OPEN != SPDF_WIN_FOCUS_SIDEBAR_FILTER);
}

int main(void) {
    /* 1.5 is this machine's own 144 dpi -- the fractional case, where a rect
     * that is not snapped to whole pixels shows up. */
    float scales[4];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.25f;
    scales[2] = 1.5f;
    scales[3] = 2.0f;

    test_has_document();
    test_needs_document_list();
    test_focus_value();
    test_open_button_absences();
    for (i = 0; i < 4; ++i) {
        test_row_refusal(scales[i]);
        test_open_button(scales[i]);
    }

    printf("empty_state_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
