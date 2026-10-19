/* dpi_hit_parity_test.c -- at every DPI the app can be run at, the point the
 * PAINTER put a control at must be the point the ROUTER finds that control at.
 *
 * WHY THIS AND NOT chrome_input_test.c. That file already checks the layout
 * against itself: spdf_win_toolbar_hit() finds every rect spdf_win_toolbar_layout()
 * produced. This checks the WHOLE PATH a click actually travels --
 * spdf_win_chrome_input_route(), which must first agree that the point is in the
 * toolbar band at all (spdf_win_chrome_hit), then divide the row, then name an
 * ACTION -- and it checks it against the rect the painter would have drawn. A
 * control can be hit-testable inside its own row and still be unreachable,
 * because the band above it swallowed the click or the row was laid out against
 * a different DPI than the one the painter used. That failure has exactly one
 * symptom, and it is the one this campaign is chasing: the buttons are visible
 * and pressing them does nothing.
 *
 * THE FOUR SCALES ARE THE ONES WINDOWS OFFERS, not round numbers: 96 (100%),
 * 120 (125%), 144 (150% -- the reporter's own display) and 192 (200%). 125% and
 * 150% are the fractional cases, where a scaled metric lands between pixels and
 * a painter and a router that round differently drift apart. chrome_input_test.c
 * covers 1.0, 1.5 and 2.0; 1.25 is added here because it is the scale at which
 * 42 pt bands and 28 pt controls stop being whole pixels.
 *
 * WHAT IT ESTABLISHES ABOUT THE REPORT. If any control were off at 150%, this
 * would say which one and by how much. It passes, which is evidence the way a
 * negative result is evidence: the DPI path is not where the input went.
 *
 * Header-only under test, so no `spdf-test-sources` line is needed.
 */
#include "spdf_win_chrome_input.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if ((int)(a) != (int)(b)) {                                                                                    \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* The four DPIs, as scales. The window computes exactly this
 * (spdf_win_window_dpi_scale: dpi / 96) and hands the same float to the painter
 * (spdf_win_window_target.h) and to the router (spdf_win_window_input.h), which
 * is the structural half of the guarantee; this file is the measured half. */
static const unsigned k_dpi[] = {96u, 120u, 144u, 192u};
static float scale_of(unsigned dpi) { return (float)dpi / 96.0f; }

/* A model with everything on, so every control the row can hold is in it. */
static SpdfWinChromeModel model_all(int markdown, int search_active, int section) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.tab_count = 3;
    m.selected_tab = 1;
    m.page_index = 3;
    m.page_count = 117;
    m.zoom = 1.0f;
    m.zoom_dpi_scale = 1.0f;
    m.sidebar_w = 245.0f;
    m.minimap_w = 96.0f;
    m.sidebar_row_count = 24;
    m.sidebar_section = section;
    m.search_active = search_active;
    m.markdown = markdown;
    m.selected_tab = 1;
    return m;
}

/* The action the router must name for each toolbar control, and for a pill
 * which half. Kept here rather than derived from spdf_win_toolbar_route.h, on
 * purpose: a table that restated the code under test would pass however the
 * code changed. These are the meanings the toolbar's own header documents. */
typedef struct Expect {
    int item;      /* spdf_win_toolbar_item */
    float across;  /* 0.25 / 0.5 / 0.75 of the rect's width */
    int action;    /* spdf_win_chrome_action */
} Expect;

static const Expect k_toolbar[] = {
    {SPDF_WIN_TB_SIDEBAR_TOGGLE, 0.5f, SPDF_WIN_CA_TOGGLE_SIDEBAR},
    {SPDF_WIN_TB_MINIMAP_TOGGLE, 0.5f, SPDF_WIN_CA_TOGGLE_MINIMAP},
    {SPDF_WIN_TB_READING_THEME, 0.5f, SPDF_WIN_CA_TOGGLE_THEME},
    {SPDF_WIN_TB_OCR, 0.5f, SPDF_WIN_CA_OCR},
    {SPDF_WIN_TB_TRANSLATE, 0.5f, SPDF_WIN_CA_TRANSLATE_SELECTION},
    {SPDF_WIN_TB_PAGE_FIELD, 0.5f, SPDF_WIN_CA_FOCUS_PAGE},
    {SPDF_WIN_TB_PAGE_PILL, 0.25f, SPDF_WIN_CA_PREV_PAGE},
    {SPDF_WIN_TB_PAGE_PILL, 0.75f, SPDF_WIN_CA_NEXT_PAGE},
    {SPDF_WIN_TB_FIT_POPUP, 0.5f, SPDF_WIN_CA_CYCLE_FIT},
    {SPDF_WIN_TB_ZOOM_PILL, 0.25f, SPDF_WIN_CA_ZOOM_OUT},
    {SPDF_WIN_TB_ZOOM_PILL, 0.75f, SPDF_WIN_CA_ZOOM_IN},
    {SPDF_WIN_TB_MD_TEXT_PILL, 0.25f, SPDF_WIN_CA_MD_TEXT_SMALLER},
    {SPDF_WIN_TB_MD_TEXT_PILL, 0.75f, SPDF_WIN_CA_MD_TEXT_LARGER},
    {SPDF_WIN_TB_FIND_FIELD, 0.5f, SPDF_WIN_CA_FOCUS_FIND},
    {SPDF_WIN_TB_FIND_REGEX, 0.5f, SPDF_WIN_CA_TOGGLE_REGEX},
    {SPDF_WIN_TB_FIND_PILL, 0.25f, SPDF_WIN_CA_FIND_PREV},
    {SPDF_WIN_TB_FIND_PILL, 0.75f, SPDF_WIN_CA_FIND_NEXT},
    {SPDF_WIN_TB_OVERFLOW, 0.5f, SPDF_WIN_CA_APP_MENU}
};

/* EVERY TOOLBAR CONTROL, FROM THE PAINTER'S OWN RECT, THROUGH THE WHOLE ROUTER.
 *
 * The window is sized in DEVICE pixels, as a real one is: a 1120x800 logical
 * window at 150% really is 1680x1200 physical, and a test that scaled only one
 * of the two would be testing a window that cannot exist. */
static void test_every_toolbar_control(unsigned dpi, int markdown) {
    float s = scale_of(dpi);
    SpdfWinChromeModel m = model_all(markdown, 1, 0);
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout tb;
    SpdfWinChromeHit hit;
    size_t i;

    spdf_win_chrome_layout(&m, (unsigned)(1400.0f * s), (unsigned)(900.0f * s), s, &l);
    spdf_win_toolbar_layout(l.toolbar, s, m.markdown, &tb);

    for (i = 0; i < sizeof(k_toolbar) / sizeof(k_toolbar[0]); ++i) {
        SpdfWinChromeRect r = tb.item[k_toolbar[i].item];
        float x, y;
        /* The Markdown pill is only in the row on a Markdown tab; every other
         * control is always there, and an empty rect for one of those is
         * itself the failure. */
        if (spdf_win_chrome_rect_empty(r)) {
            if (k_toolbar[i].item == SPDF_WIN_TB_MD_TEXT_PILL && !markdown) continue;
            ++g_checks;
            ++g_failures;
            fprintf(stderr, "FAIL dpi=%u markdown=%d: toolbar item %d has no rect\n", dpi, markdown,
                    k_toolbar[i].item);
            continue;
        }
        x = r.x + r.w * k_toolbar[i].across;
        y = r.y + r.h * 0.5f;
        /* The band first: the router only reaches the toolbar case if
         * spdf_win_chrome_hit() agrees the point is in the toolbar. */
        spdf_win_chrome_input_route(&l, &m, x, y, SPDF_WIN_CB_LEFT, &hit);
        ++g_checks;
        if (hit.part != SPDF_WIN_CHROME_TOOLBAR || hit.action != k_toolbar[i].action) {
            ++g_failures;
            fprintf(stderr,
                    "FAIL dpi=%u markdown=%d item=%d at (%.2f, %.2f) [rect %.2f,%.2f %.2fx%.2f]: part=%d action=%d, "
                    "wanted part=%d action=%d\n",
                    dpi, markdown, k_toolbar[i].item, x, y, r.x, r.y, r.w, r.h, (int)hit.part, (int)hit.action,
                    (int)SPDF_WIN_CHROME_TOOLBAR, k_toolbar[i].action);
        }
    }
}

/* THE SIDEBAR'S CONTROLS, the same way: the segment control's three segments
 * from the rect the painter measures them in, the filter field, and the first
 * and last visible list rows. */
static void test_every_sidebar_control(unsigned dpi, int section) {
    float s = scale_of(dpi);
    SpdfWinChromeModel m = model_all(0, 1, section);
    SpdfWinChromeLayout l;
    SpdfWinSidebarLayout sb;
    SpdfWinChromeRect bar;
    SpdfWinChromeHit hit;
    int segments = 3; /* search_active, so Chapters / Comments / Search */
    int seg;

    spdf_win_chrome_layout(&m, (unsigned)(1400.0f * s), (unsigned)(900.0f * s), s, &l);
    spdf_win_sidebar_layout(l.sidebar, m.sidebar_section, s, &sb);
    bar = spdf_win_sidebar_sections_rect(sb.sections, l.sidebar, segments, s);

    for (seg = 0; seg < segments; ++seg) {
        float x = bar.x + bar.w * ((float)seg + 0.5f) / (float)segments;
        float y = bar.y + bar.h * 0.5f;
        spdf_win_chrome_input_route(&l, &m, x, y, SPDF_WIN_CB_LEFT, &hit);
        ++g_checks;
        if (hit.action != SPDF_WIN_CA_SIDEBAR_SECTION || hit.index != seg) {
            ++g_failures;
            fprintf(stderr, "FAIL dpi=%u section=%d segment %d at (%.2f, %.2f): action=%d index=%d\n", dpi, section,
                    seg, x, y, (int)hit.action, hit.index);
        }
    }

    /* The filter field, which the SEARCH section does not have: macOS hides and
     * disables it there (:3149-3157) and spdf_win_sidebar_layout() returns an
     * empty rect to match. Asserted both ways round, so a filter that stopped
     * being routable in Chapters and a filter that appeared in Search would each
     * fail. */
    if (section == 2) {
        CHECK(spdf_win_chrome_rect_empty(sb.filter));
    } else {
        CHECK(!spdf_win_chrome_rect_empty(sb.filter));
        spdf_win_chrome_input_route(&l, &m, sb.filter.x + sb.filter.w * 0.5f, sb.filter.y + sb.filter.h * 0.5f,
                                    SPDF_WIN_CB_LEFT, &hit);
        CHECK_EQI(hit.action, SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER);
    }

    /* The list: the first row and a row well inside it. Chapters names the row
     * index; the other two sections report the list-local Y, so only the action
     * is asserted there (spdf_win_sidebar_input.h says why). */
    spdf_win_chrome_input_route(&l, &m, sb.list.x + sb.list.w * 0.5f, sb.list.y + 2.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_ROW);
    if (section == 0) CHECK_EQI(hit.index, 0);
    spdf_win_chrome_input_route(&l, &m, sb.list.x + sb.list.w * 0.5f, sb.list.y + sb.list.h * 0.5f, SPDF_WIN_CB_LEFT,
                                &hit);
    CHECK_EQI(hit.action, SPDF_WIN_CA_SIDEBAR_ROW);
    CHECK(hit.index >= 0);
}

/* THE BANDS THEMSELVES. Every rect the layout hands the painter must be
 * classified as its own part by the hit test the router runs first -- otherwise
 * a control inside it is unreachable however well the row divides. Empty rects
 * are skipped: a band that is not shown has none. */
static void test_bands_classify_at(unsigned dpi) {
    float s = scale_of(dpi);
    SpdfWinChromeModel m = model_all(0, 1, 0);
    SpdfWinChromeLayout l;
    struct {
        SpdfWinChromeRect r;
        int part;
        const char* name;
    } bands[5];
    size_t i;

    spdf_win_chrome_layout(&m, (unsigned)(1400.0f * s), (unsigned)(900.0f * s), s, &l);
    bands[0].r = l.tabstrip;  bands[0].part = SPDF_WIN_CHROME_TABSTRIP;  bands[0].name = "tabstrip";
    bands[1].r = l.toolbar;   bands[1].part = SPDF_WIN_CHROME_TOOLBAR;   bands[1].name = "toolbar";
    bands[2].r = l.sidebar;   bands[2].part = SPDF_WIN_CHROME_SIDEBAR;   bands[2].name = "sidebar";
    bands[3].r = l.minimap;   bands[3].part = SPDF_WIN_CHROME_MINIMAP;   bands[3].name = "minimap";
    bands[4].r = l.canvas;    bands[4].part = SPDF_WIN_CHROME_CANVAS;    bands[4].name = "canvas";

    for (i = 0; i < sizeof(bands) / sizeof(bands[0]); ++i) {
        int got;
        if (spdf_win_chrome_rect_empty(bands[i].r)) continue;
        got = spdf_win_chrome_hit(&l, bands[i].r.x + bands[i].r.w * 0.5f, bands[i].r.y + bands[i].r.h * 0.5f);
        ++g_checks;
        if (got != bands[i].part) {
            ++g_failures;
            fprintf(stderr, "FAIL dpi=%u: the centre of the %s band classifies as part %d, not %d\n", dpi,
                    bands[i].name, got, bands[i].part);
        }
    }
}

/* A LAST SANITY CHECK ON THE UNITS THEMSELVES: the layout really does scale
 * with the DPI, so the four runs above are four different geometries and not
 * the same one measured four times. A router that ignored dpi_scale would pass
 * every assertion above while being wrong on a real 144-dpi machine. */
static void test_the_geometry_actually_scales(void) {
    SpdfWinChromeModel m = model_all(0, 1, 0);
    SpdfWinChromeLayout a, b;
    spdf_win_chrome_layout(&m, 1400, 900, 1.0f, &a);
    spdf_win_chrome_layout(&m, 2100, 1350, 1.5f, &b);
    CHECK(b.toolbar.h > a.toolbar.h * 1.4f && b.toolbar.h < a.toolbar.h * 1.6f);
    CHECK(b.tabstrip.h > a.tabstrip.h * 1.4f && b.tabstrip.h < a.tabstrip.h * 1.6f);
    CHECK(b.toolbar.y > a.toolbar.y * 1.4f);
}

int main(void) {
    size_t d;
    for (d = 0; d < sizeof(k_dpi) / sizeof(k_dpi[0]); ++d) {
        test_every_toolbar_control(k_dpi[d], 0);
        test_every_toolbar_control(k_dpi[d], 1);
        test_every_sidebar_control(k_dpi[d], 0);
        test_every_sidebar_control(k_dpi[d], 1);
        test_every_sidebar_control(k_dpi[d], 2);
        test_bands_classify_at(k_dpi[d]);
    }
    test_the_geometry_actually_scales();

    printf("dpi_hit_parity_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
