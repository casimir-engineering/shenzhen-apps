/* toolbar_route_test.c — pins portable/win/src/spdf_win_chrome_toolbar_route.h
 * and the one thing in spdf_win_chrome_toolbar.h that depends on the DOCUMENT
 * rather than on the window: the Markdown A−/A＋ text-size pill.
 *
 * WHY A FILE OF ITS OWN. The pill is the first toolbar control whose PRESENCE
 * varies, and it was inserted in the MIDDLE of the row's forward walk. That is
 * the shape of change that goes wrong quietly in two directions at once: the
 * pill can fail to appear on a Markdown tab, and — much worse — everything
 * after it can shift on a PDF tab, redrawing the whole right-hand half of the
 * toolbar 68 pt over on every document this app has ever opened. The second
 * failure is invisible to a reader who never opens Markdown, so it is asserted
 * as arithmetic here and as pixels by the headless compose comparison
 * (run-tests-native.d2d.sh, d2d.compose-*).
 *
 * Its sibling is sidebar_route_test.c, which pins the other case extracted out
 * of spdf_win_chrome_input_route() for the size ratchet. chrome_input_test.c
 * keeps the row-wide invariants -- the enum order, the hit/layout agreement, and
 * the sweep that says no chrome pixel pans the document -- and runs each of them
 * over BOTH rows.
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
        if ((int)(a) != (int)(b)) {                                                                                     \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static SpdfWinChromeModel model(int markdown) {
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
    m.markdown = markdown;
    return m;
}

/* THE PDF ROW IS THE ROW IT WAS, and the pill lands in the gap the zoom pill's
 * own wide spacing already left. There is no pre-change layout left to diff
 * against, so the "unchanged" half is pinned as the RELATION the layout produced
 * before this item existed: the reading-theme button one wide spacing after the
 * zoom pill. */
static void test_placement(float dpi) {
    SpdfWinChromeModel m = model(0);
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout pdf, md;
    SpdfWinChromeRect zoom, pill, theme;
    float wide = spdf_win_chrome_px(SPDF_WIN_TB_WIDE_SPACING, dpi);
    float narrow = spdf_win_chrome_px(SPDF_WIN_TB_SPACING, dpi);

    spdf_win_chrome_layout(&m, (unsigned)(1120.0f * dpi), (unsigned)(800.0f * dpi), dpi, &l);
    spdf_win_toolbar_layout(l.toolbar, dpi, 0, &pdf);
    spdf_win_toolbar_layout(l.toolbar, dpi, 1, &md);

    CHECK(spdf_win_chrome_rect_empty(pdf.item[SPDF_WIN_TB_MD_TEXT_PILL]));
    zoom = pdf.item[SPDF_WIN_TB_ZOOM_PILL];
    theme = pdf.item[SPDF_WIN_TB_READING_THEME];
    CHECK(theme.x == zoom.x + zoom.w + wide);

    zoom = md.item[SPDF_WIN_TB_ZOOM_PILL];
    pill = md.item[SPDF_WIN_TB_MD_TEXT_PILL];
    theme = md.item[SPDF_WIN_TB_READING_THEME];
    CHECK(!spdf_win_chrome_rect_empty(pill));
    /* The 8 pt custom spacing stays attached to the zoom pill (:3123-3125); the
     * ordinary 4 pt follows the new control. */
    CHECK(pill.x == zoom.x + zoom.w + wide);
    CHECK(theme.x == pill.x + pill.w + narrow);
    /* Same baseline and same size as the zoom pill, which is what makes the two
     * read as a pair rather than as two unrelated capsules. */
    CHECK(pill.y == zoom.y);
    CHECK(pill.h == zoom.h);
    CHECK(pill.w == zoom.w); /* both are SPDF_WIN_TB_PILL_W */
    /* Nothing at or before the zoom pill moved, on either row. */
    CHECK(md.item[SPDF_WIN_TB_ZOOM_PILL].x == pdf.item[SPDF_WIN_TB_ZOOM_PILL].x);
    CHECK(md.item[SPDF_WIN_TB_SIDEBAR_TOGGLE].x == pdf.item[SPDF_WIN_TB_SIDEBAR_TOGGLE].x);
    CHECK(md.item[SPDF_WIN_TB_PAGE_FIELD].x == pdf.item[SPDF_WIN_TB_PAGE_FIELD].x);
    /* The backward walk is untouched: the trailing group never moves. */
    CHECK(md.item[SPDF_WIN_TB_MINIMAP_TOGGLE].x == pdf.item[SPDF_WIN_TB_MINIMAP_TOGGLE].x);
    CHECK(md.item[SPDF_WIN_TB_OVERFLOW].x == pdf.item[SPDF_WIN_TB_OVERFLOW].x);
}

/* A− is the FIRST half and A＋ the second. Reversed, the pill would shrink the
 * text a reader asked to grow -- a silent product bug, not a crash. */
static void test_routes(void) {
    SpdfWinChromeModel md = model(1);
    SpdfWinChromeModel pdf = model(0);
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout tb;
    SpdfWinChromeHit hit;
    SpdfWinChromeRect r;
    float y;

    spdf_win_chrome_layout(&md, 1120, 800, 1.0f, &l);
    spdf_win_toolbar_layout(l.toolbar, 1.0f, 1, &tb);
    r = tb.item[SPDF_WIN_TB_MD_TEXT_PILL];
    y = r.y + r.h * 0.5f;

    spdf_win_chrome_input_route(&l, &md, r.x + r.w * 0.25f, y, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_MD_TEXT_SMALLER);
    spdf_win_chrome_input_route(&l, &md, r.x + r.w * 0.75f, y, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_MD_TEXT_LARGER);
    /* The divider the painter drew is the boundary the router splits on. */
    spdf_win_chrome_input_route(&l, &md, spdf_win_toolbar_cell(r, 1, 2).x, y, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_MD_TEXT_LARGER);
    /* Neither the middle button nor a bare hover is a click, here as anywhere
     * else in the row. */
    spdf_win_chrome_input_route(&l, &md, r.x + r.w * 0.25f, y, SPDF_WIN_CB_MIDDLE, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
    spdf_win_chrome_input_route(&l, &md, r.x + r.w * 0.25f, y, SPDF_WIN_CB_NONE, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_NONE);
    /* Nothing in the toolbar ever falls through to the canvas. */
    CHECK(hit.part == SPDF_WIN_CHROME_TOOLBAR);

    /* THE ROUTER FOLLOWS THE MODEL rather than its own guess. On a PDF tab the
     * pixels the pill would have occupied belong to the reading-theme button,
     * which is exactly what the painter drew there. */
    spdf_win_chrome_input_route(&l, &pdf, r.x + r.w * 0.25f, y, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_TOGGLE_THEME);
    /* ... and the second half of that would-be pill is past the 32 pt button,
     * so it is bare toolbar: no action, and still not the canvas. */
    spdf_win_chrome_input_route(&l, &pdf, r.x + r.w * 0.75f, y, SPDF_WIN_CB_LEFT, &hit);
    CHECK(hit.action != SPDF_WIN_CA_CANVAS);
}

int main(void) {
    float scales[3];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.5f; /* this machine's own 144 dpi -- the fractional case */
    scales[2] = 2.0f;

    for (i = 0; i < 3; ++i) test_placement(scales[i]);
    test_routes();

    printf("toolbar_route_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
