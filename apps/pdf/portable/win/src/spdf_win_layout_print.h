#pragma once

/* spdf_win_layout_print.h — `--print-layout W H SCALE`: where the chrome puts
 * every band and every toolbar control, for a client area of W x H device pixels
 * at SCALE device pixels per logical pixel.
 *
 * WHY IT EXISTS. portable/win/tests's launch.health case sends REAL input --
 * SendInput, into whatever window is in front -- and it has to click the
 * toolbar's next-page button. A hard-coded coordinate would be a coordinate
 * measured once at 150% on this machine (the ad-hoc probe scripts have exactly
 * that, with a comment saying so), and the day the row gains a control or the
 * reader runs at 125% the test would click the button next door and still pass
 * or still fail for the wrong reason.
 *
 * The row is already laid out ONCE, purely, in spdf_win_chrome_toolbar.h, and
 * the painter and the input router both read that table. This switch prints the
 * same table. So the test clicks where the app itself would hit-test, by
 * construction, and a layout change moves the test's click with it.
 *
 * IT NEEDS NO WINDOW, NO DIRECT2D AND NO DOCUMENT -- spdf_win_chrome_layout()
 * and spdf_win_toolbar_layout() are toolkit-free and take a client size, a DPI
 * scale and a model. That is also why the switch is answered before the Direct2D
 * device is created in spdf_win_main.cpp.
 *
 * THE OUTPUT is one record per line, `kind name x y w h`, in client device
 * pixels with the origin at the client area's top-left:
 *
 *     layout client=1400x900 dpi_scale=1.500 markdown=0
 *     band toolbar 0 90 1400 63
 *     item page-pill 594 97 96 42
 *     action next-page 642 97 48 42
 *
 * `item` lines are the controls; `action` lines resolve a pill into the halves
 * spdf_win_chrome_toolbar_route.h maps to commands, so a caller asks for
 * "next-page" rather than knowing that it is the right half of the page pill.
 * Empty controls (squeezed out of a narrow row) are omitted, which is the same
 * "w <= 0 means absent" contract SpdfWinToolbarLayout states.
 */

#include "spdf_win_chrome.h"
#include "spdf_win_chrome_toolbar.h"
#include "spdf_win_health.h" /* spdf_win_health_print: stdout for a GUI-subsystem exe */

static const char* const kLayoutItemNames[SPDF_WIN_TB_ITEM_COUNT] = {
    "none",         "sidebar-toggle", "ocr",           "translate",  "separator",
    "page-field",   "page-count",     "page-pill",     "fit-popup",  "zoom-pill",
    "md-text-pill", "reading-theme",  "find-field",    "find-regex", "find-count",
    "find-pill",    "overflow",       "minimap-toggle"};

static void layout_print_rect(const char* kind, const char* name, SpdfWinChromeRect r) {
    char line[160];
    if (spdf_win_chrome_rect_empty(r)) return;
    _snprintf_s(line, sizeof(line), _TRUNCATE, "%s %s %d %d %d %d\n", kind, name, (int)r.x, (int)r.y, (int)r.w,
                (int)r.h);
    spdf_win_health_print(line);
}

/* One half of a two-segment pill, under the name of the command that half
 * posts. The cell comes from spdf_win_toolbar_cell(), the same function the
 * painter draws the divider with and the router splits the hit with, so a pill
 * of odd device width splits here exactly where it splits there. */
static void layout_print_cell(const char* name, SpdfWinChromeRect pill, int index) {
    if (spdf_win_chrome_rect_empty(pill)) return;
    layout_print_rect("action", name, spdf_win_toolbar_cell(pill, index, 2));
}

/* W and H are the CLIENT area in device pixels (GetClientRect's answer, which is
 * already physical on a per-monitor-aware window) and `scale` is
 * GetDpiForWindow / 96. `markdown` puts the A−/A＋ pill in the row; a PDF tab
 * passes 0 and every control after the zoom pill sits where it sat. */
static int run_print_layout(unsigned client_w, unsigned client_h, float scale, int markdown) {
    SpdfWinChromeModel model;
    SpdfWinChromeLayout l;
    SpdfWinToolbarLayout tb;
    char head[160];
    int i;

    memset(&model, 0, sizeof(model));
    /* The launch defaults (spdf_win_main.cpp): both panels open, nothing
     * hovered, no drag. Only the two panels affect the bands this prints, and
     * neither affects the toolbar row, which is full width at every setting. */
    model.show_sidebar = 1;
    model.show_minimap = 1;
    model.hot_tab = -1;
    model.hot_close = -1;
    model.drag_tab = -1;
    model.drop_slot = -1;
    model.markdown = markdown;

    if (scale <= 0.0f) scale = 1.0f;
    spdf_win_chrome_layout(&model, client_w, client_h, scale, &l);
    spdf_win_toolbar_layout(l.toolbar, scale, markdown, &tb);

    _snprintf_s(head, sizeof(head), _TRUNCATE, "layout client=%ux%u dpi_scale=%.3f markdown=%d\n", client_w, client_h,
                (double)scale, markdown);
    spdf_win_health_print(head);

    layout_print_rect("band", "tabstrip", l.tabstrip);
    layout_print_rect("band", "caption", l.caption);
    layout_print_rect("band", "toolbar", l.toolbar);
    layout_print_rect("band", "sidebar", l.sidebar);
    layout_print_rect("band", "canvas", l.canvas);
    layout_print_rect("band", "vscroll", l.vscroll);
    layout_print_rect("band", "hscroll", l.hscroll);
    layout_print_rect("band", "minimap", l.minimap);

    for (i = SPDF_WIN_TB_NONE + 1; i < SPDF_WIN_TB_ITEM_COUNT; ++i)
        layout_print_rect("item", kLayoutItemNames[i], tb.item[i]);

    /* The commands, in the mapping spdf_win_chrome_toolbar_route.h holds. */
    layout_print_rect("action", "toggle-sidebar", tb.item[SPDF_WIN_TB_SIDEBAR_TOGGLE]);
    layout_print_rect("action", "toggle-minimap", tb.item[SPDF_WIN_TB_MINIMAP_TOGGLE]);
    layout_print_rect("action", "toggle-theme", tb.item[SPDF_WIN_TB_READING_THEME]);
    layout_print_rect("action", "cycle-fit", tb.item[SPDF_WIN_TB_FIT_POPUP]);
    layout_print_rect("action", "app-menu", tb.item[SPDF_WIN_TB_OVERFLOW]);
    layout_print_rect("action", "ocr", tb.item[SPDF_WIN_TB_OCR]);
    layout_print_rect("action", "translate", tb.item[SPDF_WIN_TB_TRANSLATE]);
    layout_print_rect("action", "find-field", tb.item[SPDF_WIN_TB_FIND_FIELD]);
    layout_print_cell("prev-page", tb.item[SPDF_WIN_TB_PAGE_PILL], 0);
    layout_print_cell("next-page", tb.item[SPDF_WIN_TB_PAGE_PILL], 1);
    layout_print_cell("zoom-out", tb.item[SPDF_WIN_TB_ZOOM_PILL], 0);
    layout_print_cell("zoom-in", tb.item[SPDF_WIN_TB_ZOOM_PILL], 1);
    layout_print_cell("find-prev", tb.item[SPDF_WIN_TB_FIND_PILL], 0);
    layout_print_cell("find-next", tb.item[SPDF_WIN_TB_FIND_PILL], 1);
    return 0;
}
