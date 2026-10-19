/* find_screenshot.c — composes ONE window frame with a live search in it and
 * writes it to a PNG, offscreen.
 *
 *   find_screenshot.exe <document.pdf> <query> <out.png> [width] [height] [dark]
 *
 * WHY THIS EXISTS. The find track produces two things that can only be judged by
 * looking: the toolbar's find group (field, regex checkbox, counter, prev/next
 * pill) and the in-page highlights. The app can show the first today, but not
 * the second: `scene->overlays` is only reachable where the scene is BUILT, and
 * both scene builders belong to another track, so the one-line hook
 * (spdf_win_find_apply_overlays) is not wired yet. This tool builds a scene of
 * its own, calls the same spdf_win_find_apply_overlays_for() the hook will call,
 * and hands it to the same spdf_win_paint() the window uses -- so the pixels it
 * writes are the pixels the window will draw, not an approximation of them.
 *
 * It is a TOOL, not a case: nothing here asserts. The assertions about the same
 * geometry live in find_overlay_test.c, which needs no Direct2D. Named without
 * the _test suffix so run-tests-native.sh's sweep leaves it alone. Build it with
 * the source list in this comment:
 *
 *   portable\win\build-native.cmd find_screenshot ^
 *     portable/win/tests/find_screenshot.c ^
 *     portable/win/src/spdf_win_d2d.cpp portable/win/src/spdf_win_chrome_paint.cpp ^
 *     portable/win/src/spdf_win_chrome_toolbar.cpp portable/win/src/spdf_win_chrome_find.cpp ^
 *     portable/win/src/spdf_win_chrome_panels.cpp portable/win/src/spdf_win_chrome_sidebar.cpp ^
 *     portable/win/src/spdf_win_chrome_minimap.cpp portable/win/src/spdf_win_chrome_scrollbar.cpp ^
 *     portable/win/src/spdf_win_chrome_content.cpp portable/win/src/spdf_win_chrome_thumbs.cpp ^
 *     portable/win/src/spdf_win_search.cpp portable/win/src/spdf_win_render.c ^
 *     portable/win/src/spdf_win_lru.c portable/core/shenzhen_pdf_core.c ^
 *     portable/core/spdf_selection.c portable/core/spdf_selection_support.c ^
 *     portable/core/spdf_recolor.c portable/core/spdf_win_compat.c
 *
 * Delete it once the hook is wired and `--render-window-png --chrome` can do the
 * same job with SPDF_FIND_QUERY set.
 */
#include "spdf_win_chrome_find.h"
#include "spdf_win_d2d.h"
#include "spdf_win_layout.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv) {
    const char* path;
    const char* query;
    char err[512] = {0};
    wchar_t out_path[1024];
    wchar_t wide_query[256];
    unsigned client_w, client_h;
    int dark;
    float dpi = 1.0f;
    spdf_document* doc;
    spdf_bitmap bitmap;
    spdf_win_d2d* d2d;
    SpdfWinChromeModel model;
    SpdfWinChromeLayout layout;
    SpdfWinFindSession* find;
    spdf_win_page_draw page;
    spdf_win_scene scene;
    SpdfWinChromeTab tab;
    wchar_t title[64];
    float pw = 0.0f, ph = 0.0f, zoom;
    int spins;
    HRESULT hr;

    if (argc < 4) {
        printf("usage: find_screenshot <document.pdf> <query> <out.png> [w] [h] [dark]\n");
        return 64;
    }
    path = argv[1];
    query = argv[2];
    client_w = (unsigned)(argc > 4 ? atoi(argv[4]) : 1400);
    client_h = (unsigned)(argc > 5 ? atoi(argv[5]) : 900);
    dark = argc > 6 ? atoi(argv[6]) : 0;
    MultiByteToWideChar(CP_ACP, 0, argv[3], -1, out_path, 1024);
    MultiByteToWideChar(CP_ACP, 0, query, -1, wide_query, 256);

    /* --- run the search to completion, exactly as the UI thread drives it --- */
    find = spdf_win_find_session_new();
    if (!find) return 70;
    spdf_win_find_set(find, path, query, 0);
    for (spins = 0; spins < 60000; ++spins) {
        spdf_win_find_poll(find);
        if (!spdf_win_find_searching(find)) break;
        Sleep(1);
    }
    spdf_win_find_poll(find);
    printf("search: %d match(es), current %d\n", spdf_win_find_match_count(find),
           spdf_win_find_match_index(find));

    /* --- the chrome model, hand-built, which is the whole point of the model
     * being a plain value type ---------------------------------------------- */
    memset(&model, 0, sizeof(model));
    memset(&tab, 0, sizeof(tab));
    MultiByteToWideChar(CP_ACP, 0, path, -1, title, 64);
    tab.title = title;
    model.tabs = &tab;
    model.tab_count = 1;
    model.selected_tab = 0;
    model.hot_tab = -1;
    model.hot_close = -1;
    model.dark = dark;
    model.show_sidebar = 1;
    model.show_minimap = 1;
    model.page_index = 0;
    model.zoom_dpi_scale = dpi;
    model.fit_mode = SPDF_WIN_CHROME_FIT_WIDTH;
    model.query = wide_query;
    model.searching = spdf_win_find_searching(find);
    model.match_count = spdf_win_find_match_count(find);
    model.match_index = spdf_win_find_match_index(find);
    model.marks = spdf_win_find_marks(find, &model.mark_count, &model.active_mark);
    model.search_active = 1;
    model.v_visible = 0.6f;

    spdf_win_chrome_layout(&model, client_w, client_h, dpi, &layout);

    /* --- one page, fit to the canvas region, at the page the active match is
     * on so the ring is in frame ------------------------------------------- */
    doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        printf("open failed: %s\n", err);
        return 65;
    }
    memset(&page, 0, sizeof(page));
    spdf_win_find_current_target(find, &page.page_index, NULL);
    if (page.page_index < 0) page.page_index = 0;
    model.page_index = page.page_index;
    model.page_count = spdf_page_count(doc);
    if (!spdf_page_size(doc, page.page_index, &pw, &ph, err, sizeof(err))) {
        printf("page size failed: %s\n", err);
        return 66;
    }
    zoom = (float)spdf_win_fit_width_zoom(pw, layout.canvas.w - 2.0 * SPDF_WIN_PAGE_MARGIN_H);
    memset(&bitmap, 0, sizeof(bitmap));
    if (!spdf_render_page_rgba_opts(doc, page.page_index, zoom, dark ? SPDF_RENDER_DARK_THEME : 0u, NULL, &bitmap, err,
                                    sizeof(err))) {
        printf("render failed: %s\n", err);
        return 67;
    }
    page.bitmap = &bitmap;
    page.dest_w = (float)bitmap.width;
    page.dest_h = (float)bitmap.height;
    /* CANVAS-LOCAL, not client-local: spdf_win_paint translates by the canvas
     * origin itself, and getting this wrong is the bug the port already hit
     * once. */
    page.dest_x = (layout.canvas.w - page.dest_w) * 0.5f;
    page.dest_y = (float)SPDF_WIN_PAGE_MARGIN_V;

    memset(&scene, 0, sizeof(scene));
    scene.fit = SPDF_WIN_FIT_CANVAS;
    scene.pages = &page;
    scene.page_count = 1;
    scene.target_px_w = (unsigned)layout.canvas.w;
    scene.target_px_h = (unsigned)layout.canvas.h;
    scene.client_px_w = client_w;
    scene.client_px_h = client_h;
    scene.dpi_scale = dpi;
    scene.dark = dark;
    scene.chrome = &model;

    /* THE HOOK, called here exactly as the scene builder will call it. */
    spdf_win_find_apply_overlays_for(find, &scene);
    printf("overlays: %d\n", scene.overlay_count);

    d2d = spdf_win_d2d_create(err, sizeof(err));
    if (!d2d) {
        printf("d2d failed: %s\n", err);
        return 68;
    }
    hr = spdf_win_render_scene_to_png(d2d, client_w, client_h, &scene, out_path);
    printf("png hr=0x%08lx -> %s\n", (unsigned long)hr, argv[3]);

    spdf_win_d2d_destroy(d2d);
    spdf_free_bitmap(&bitmap);
    spdf_close(doc);
    spdf_win_find_session_free(find);
    return SUCCEEDED(hr) ? 0 : 69;
}
