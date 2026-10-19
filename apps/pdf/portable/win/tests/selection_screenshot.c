/* selection_screenshot.c — composes ONE canvas frame with a live text selection
 * in it and writes it to a PNG, offscreen.
 *
 *   selection_screenshot.exe <document.pdf> <text to select> <out.png>
 *                            [width] [height] [dark]
 *
 * WHY THIS EXISTS, and it is the same reason find_screenshot.c exists: the
 * selection's rects are only reachable where the scene is BUILT, and the
 * one-line hook that calls spdf_win_canvas_apply_selection_overlays() belongs to
 * the shell track. Until it is wired, `--render-window-png` cannot show a
 * selection. This drives the REAL canvas -- the same
 * spdf_win_canvas_pointer_press/drag/release an input router will call, at the
 * canvas's own zoom and scroll -- then calls the same
 * spdf_win_canvas_apply_selection_overlays() the hook will call and hands the
 * result to the same spdf_win_paint() the window uses. The pixels it writes are
 * the pixels the window will draw.
 *
 * It needs no HWND, no desktop and no unlocked session, which is what makes it
 * usable as evidence on this machine at all.
 *
 * It is a TOOL, not a case: nothing here asserts. The assertions about the same
 * geometry are in canvas_selection_test.c and selection_model_test.c, neither of
 * which needs Direct2D. Named without the _test suffix so run-tests-native.sh's
 * sweep leaves it alone. Build it with the source list in this comment:
 *
 *   portable\win\build-native.cmd selection_screenshot ^
 *     portable/win/tests/selection_screenshot.c ^
 *     portable/win/src/spdf_win_canvas.cpp portable/win/src/spdf_win_canvas_prefetch.cpp ^
 *     portable/win/src/spdf_win_canvas_selection.cpp portable/win/src/spdf_win_selection.cpp ^
 *     portable/win/src/spdf_win_links.cpp portable/win/src/spdf_win_lru.c ^
 *     portable/win/src/spdf_win_render.c portable/win/src/spdf_win_d2d.cpp ^
 *     portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c ^
 *     portable/core/spdf_selection_support.c portable/core/spdf_recolor.c ^
 *     portable/core/spdf_win_compat.c
 *
 * Delete it once the hook is wired and --render-window-png can do the same job.
 */
#include "spdf_win_canvas.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv) {
    char err[512] = {0};
    wchar_t out_path[1024];
    const char* path;
    const char* needle;
    unsigned w, h;
    int dark;
    spdf_document* doc;
    spdf_win_canvas* canvas;
    spdf_win_d2d* d2d;
    spdf_win_scene scene;
    const spdf_win_page_draw* draw = NULL;
    spdf_rect line;
    float pw = 0.0f, ph = 0.0f, x0, y0, x1, y1;
    const char* text;
    HRESULT hr;
    int i;

    if (argc < 4) {
        printf("usage: %s <document.pdf> <text> <out.png> [w] [h] [dark]\n", argv[0]);
        return 64;
    }
    path = argv[1];
    needle = argv[2];
    w = argc > 4 ? (unsigned)atoi(argv[4]) : 900u;
    h = argc > 5 ? (unsigned)atoi(argv[5]) : 1100u;
    dark = argc > 6 ? atoi(argv[6]) : 0;
    if (w < 64) w = 64;
    if (h < 64) h = 64;
    if (MultiByteToWideChar(CP_UTF8, 0, argv[3], -1, out_path, 1024) <= 0) {
        printf("bad output path\n");
        return 64;
    }

    doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        printf("open failed: %s\n", err);
        return 65;
    }
    if (!spdf_page_size(doc, 0, &pw, &ph, err, sizeof(err))) {
        printf("page size failed: %s\n", err);
        return 66;
    }
    canvas = spdf_win_canvas_create(doc, path, dark ? SPDF_RENDER_DARK_THEME : 0u, err, sizeof(err));
    if (!canvas) {
        printf("canvas failed: %s\n", err);
        return 66;
    }
    spdf_win_canvas_set_viewport(canvas, w, h, 1.0f);
    spdf_win_canvas_set_zoom_mode(canvas, SPDF_WIN_ZOOM_FIT_WIDTH);

    memset(&scene, 0, sizeof(scene));
    if (!spdf_win_canvas_build_scene(canvas, &scene)) {
        printf("nothing to draw\n");
        return 67;
    }
    for (i = 0; i < scene.page_count; ++i)
        if (scene.pages[i].page_index == 0) draw = &scene.pages[i];
    if (!draw) {
        printf("page 0 is not in the scene\n");
        return 67;
    }

    /* Find the line to select the same way a reader would point at it, then
     * drive the real gesture across it. */
    if (spdf_search_page_rects(doc, 0, needle, &line, 1, err, sizeof(err)) != 1) {
        printf("'%s' not found on page 1: %s\n", needle, err);
        return 68;
    }
    x0 = draw->dest_x + (line.x0 + 0.5f) * (draw->dest_w / pw);
    y0 = draw->dest_y + (line.y0 + line.y1) * 0.5f * (draw->dest_h / ph);
    x1 = draw->dest_x + (line.x1 - 0.5f) * (draw->dest_w / pw);
    y1 = y0;
    spdf_win_canvas_pointer_press(canvas, x0, y0, 1);
    spdf_win_canvas_pointer_drag(canvas, x1, y1);
    spdf_win_canvas_pointer_release(canvas, NULL);
    text = spdf_win_canvas_selection_text(canvas);
    printf("selected: '%s'\n", text ? text : "(nothing)");

    /* THE HOOK, called here exactly as the scene builder will call it. A real
     * frame runs find's producer first; with nobody searching it contributes
     * nothing, so the base is empty and the selection is the whole array. */
    scene.overlays = NULL;
    scene.overlay_count = 0;
    spdf_win_canvas_apply_selection_overlays(canvas, &scene);
    printf("overlays: %d\n", scene.overlay_count);

    d2d = spdf_win_d2d_create(err, sizeof(err));
    if (!d2d) {
        printf("d2d failed: %s\n", err);
        return 69;
    }
    hr = spdf_win_render_scene_to_png(d2d, w, h, &scene, out_path);
    printf("png hr=0x%08lx -> %s\n", (unsigned long)hr, argv[3]);

    spdf_win_d2d_destroy(d2d);
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);
    return SUCCEEDED(hr) ? 0 : 70;
}
