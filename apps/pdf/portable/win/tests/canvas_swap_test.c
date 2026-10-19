/* canvas_swap_test.c -- the document changes under a live canvas
 * (spdf_win_canvas_replace_document, portable/win/src/spdf_win_canvas_swap.cpp).
 *
 * What an in-place Markdown reload rests on, asserted with no window and no
 * Markdown: a real canvas over one document, driven the way a window drives it
 * -- frame, scroll, frame -- then handed a second document opened from the same
 * or another file. The contract is spdf_win_canvas.h's:
 *
 *   1. THE VIEWPORT IS KEPT. Zoom mode, zoom and scroll offset survive the swap
 *      and are clamped into the new document rather than reset to the top --
 *      the reader's place, which is the whole reason to swap instead of reopen.
 *   2. NO FRAME HAS A HOLE. The first frame after the swap carries a bitmap for
 *      every visible page, rendered on the calling thread because the cache is
 *      empty and there is no stand-in -- a frame from the new document, not an
 *      empty one and not one from the old.
 *   3. OWNERSHIP NEVER MIXES. The document create() borrowed is still the
 *      caller's after the swap and after destroy; the adopted one is the
 *      canvas's. A NULL or empty replacement is refused and nothing is taken.
 *   4. THE WORKERS FOLLOW. A canvas with a render service still prefetches
 *      after the swap -- the pool was restarted, not orphaned.
 */
/* spdf-test-sources: portable/win/src/spdf_win_canvas.cpp portable/win/src/spdf_win_canvas_swap.cpp portable/win/src/spdf_win_canvas_prefetch.cpp portable/win/src/spdf_win_canvas_selection.cpp portable/win/src/spdf_win_find_canvas.cpp portable/win/src/spdf_win_selection.cpp portable/win/src/spdf_win_links.cpp portable/win/src/spdf_win_lru.c portable/win/src/spdf_win_render.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf portable/win/tests/fixtures/outline.pdf */
/* spdf-test-needs: mupdf */

#include <windows.h>

#include "spdf_win_canvas.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

static int g_failures;
static int g_checks;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static spdf_document* open_doc(const char* path) {
    char err[256] = {0};
    spdf_document* doc = spdf_open(path, err, sizeof(err));
    if (!doc) printf("FAIL could not open %s: %s\n", path, err);
    return doc;
}

static int frame_is_whole(const spdf_win_scene* scene) {
    int i;
    if (scene->page_count <= 0) return 0;
    for (i = 0; i < scene->page_count; ++i)
        if (!scene->pages[i].bitmap) return 0;
    return 1;
}

static int build(spdf_win_canvas* canvas, spdf_win_scene* scene) {
    memset(scene, 0, sizeof(*scene));
    return spdf_win_canvas_build_scene(canvas, scene);
}

/* --- 1-3: a canvas with no workers, so every render is observable ---------- */
static void test_swap_keeps_viewport_and_ownership(const char* golden, const char* outline) {
    char err[256] = {0};
    /* The long document first (outline.pdf: pages enough to scroll into), the
     * short one as the replacement, so the swap has to cope with a page count
     * that SHRINKS under the offset. */
    spdf_document* first = open_doc(outline);
    spdf_document* second = open_doc(golden);
    spdf_win_canvas* canvas;
    spdf_win_scene scene;
    float zoom_before, y_before;
    int pages_first, pages_second;
    if (!first || !second) {
        ++g_failures;
        return;
    }
    pages_first = spdf_page_count(first);
    pages_second = spdf_page_count(second);
    CHECK(pages_first > pages_second);

    canvas = spdf_win_canvas_create(first, NULL, 0u, err, sizeof(err));
    CHECK(canvas != NULL);
    if (!canvas) return;
    spdf_win_canvas_set_viewport(canvas, 900, 700, 1.0f);
    spdf_win_canvas_set_zoom_mode(canvas, SPDF_WIN_ZOOM_FREE);
    spdf_win_canvas_set_zoom_at(canvas, 1.3f, 0.0f, 0.0f);
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    /* Into the document, so "the place was kept" means something. */
    spdf_win_canvas_scroll_to_page(canvas, 1);
    spdf_win_canvas_scroll_by(canvas, 0.0f, 37.0f);
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    zoom_before = spdf_win_canvas_zoom(canvas);
    y_before = spdf_win_canvas_scroll_y(canvas);
    CHECK(y_before > 0.0f);

    /* Refused replacements take nothing. */
    CHECK(spdf_win_canvas_replace_document(canvas, NULL) == 0);
    CHECK(spdf_win_canvas_replace_document(NULL, second) == 0);
    CHECK(spdf_win_canvas_page_count(canvas) == pages_first);

    /* THE SWAP. */
    CHECK(spdf_win_canvas_replace_document(canvas, second) == 1);
    CHECK(spdf_win_canvas_page_count(canvas) == pages_second);
    /* 1. The viewport is kept: same zoom mode, same zoom, and the offset either
     * where it was or -- the new document being too short to hold it -- clamped
     * to its end rather than reset to the top. */
    CHECK(spdf_win_canvas_zoom_mode(canvas) == SPDF_WIN_ZOOM_FREE);
    CHECK(fabs(spdf_win_canvas_zoom(canvas) - zoom_before) < 1e-6);
    CHECK(fabs(spdf_win_canvas_scroll_y(canvas) - y_before) < 1.0f ||
          fabs(spdf_win_canvas_scroll_y(canvas) - (spdf_win_canvas_content_h(canvas) - 700.0f)) < 1.0f ||
          spdf_win_canvas_content_h(canvas) <= 700.0f);
    /* 2. No hole: the first frame after the swap renders every visible page,
     * here, on this thread. */
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    CHECK(spdf_win_canvas_sync_renders(canvas) > 0);
    CHECK(spdf_win_canvas_stale_draws(canvas) == 0);
    /* ...and a second frame comes from the cache, as usual. */
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    CHECK(spdf_win_canvas_sync_renders(canvas) == 0);
    /* The pages drawn are the NEW document's: their size is the new sheet. */
    {
        double x, y, w, h;
        float pw = 0.0f, ph = 0.0f;
        CHECK(spdf_win_canvas_page_rect(canvas, 0, &x, &y, &w, &h));
        CHECK(spdf_page_size(second, 0, &pw, &ph, err, sizeof(err)));
        CHECK(fabs(w - (double)pw * zoom_before) < 1.0);
    }

    /* A fit mode survives too, re-derived from the new sheet -- and a swap to
     * the SAME sheet (a Markdown file re-read after an edit is exactly that)
     * keeps the offset to the pixel. */
    spdf_win_canvas_set_zoom_mode(canvas, SPDF_WIN_ZOOM_FIT_WIDTH);
    spdf_win_canvas_scroll_to_page(canvas, 1);
    spdf_win_canvas_scroll_by(canvas, 0.0f, 23.0f);
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    {
        spdf_document* third = open_doc(golden);
        float fit_before = spdf_win_canvas_zoom(canvas);
        float x_same = spdf_win_canvas_scroll_x(canvas);
        float y_same = spdf_win_canvas_scroll_y(canvas);
        CHECK(third != NULL);
        CHECK(y_same > 0.0f);
        if (third) {
            CHECK(spdf_win_canvas_replace_document(canvas, third) == 1);
            CHECK(spdf_win_canvas_zoom_mode(canvas) == SPDF_WIN_ZOOM_FIT_WIDTH);
            CHECK(fabs(spdf_win_canvas_zoom(canvas) - fit_before) < 1e-6); /* same sheet, same fit */
            CHECK(fabs(spdf_win_canvas_scroll_x(canvas) - x_same) < 1e-3);
            CHECK(fabs(spdf_win_canvas_scroll_y(canvas) - y_same) < 1e-3);
            CHECK(spdf_win_canvas_current_page(canvas) == 1);
            CHECK(build(canvas, &scene) && frame_is_whole(&scene));
            CHECK(spdf_win_canvas_sync_renders(canvas) > 0);
        }
    }

    /* 3. Ownership: `second` and `third` are the canvas's now (closed by it);
     * `first` is still ours and still works after destroy. */
    spdf_win_canvas_destroy(canvas);
    CHECK(spdf_page_count(first) == pages_first);
    spdf_close(first);
}

/* --- 4: a canvas WITH workers keeps prefetching after the swap ------------- */
static volatile long g_notified;
static void on_ready(void* ctx) {
    (void)ctx;
    InterlockedIncrement(&g_notified);
}

static void test_swap_restarts_workers(const char* outline) {
    char err[256] = {0};
    spdf_document* first = open_doc(outline);
    spdf_document* second = open_doc(outline);
    spdf_win_canvas* canvas;
    spdf_win_scene scene;
    unsigned long long started_before;
    if (!first || !second) {
        ++g_failures;
        return;
    }
    canvas = spdf_win_canvas_create(first, outline, 0u, err, sizeof(err));
    CHECK(canvas != NULL);
    if (!canvas) return;
    spdf_win_canvas_set_viewport(canvas, 900, 700, 1.0f);
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    spdf_win_canvas_settle(canvas, 5000);
    started_before = spdf_win_canvas_prefetched(canvas);
    CHECK(started_before > 0); /* the neighbours were asked for */

    CHECK(spdf_win_canvas_replace_document(canvas, second) == 1);
    /* The new pool starts from zero and the first frame renders here (no
     * stand-in in an empty cache), then the neighbours are asked of the NEW
     * pool. */
    CHECK(spdf_win_canvas_prefetched(canvas) == 0);
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    CHECK(spdf_win_canvas_sync_renders(canvas) > 0);
    spdf_win_canvas_settle(canvas, 5000);
    CHECK(spdf_win_canvas_prefetched(canvas) > 0);
    /* And the async path still works over the new document: a zoom step draws
     * a stand-in while the exact render lands, then adopts it. */
    spdf_win_canvas_zoom_at(canvas, 1.25f, 450.0f, 350.0f);
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    spdf_win_canvas_settle(canvas, 5000);
    CHECK(build(canvas, &scene) && frame_is_whole(&scene));
    CHECK(spdf_win_canvas_stale_draws(canvas) == 0);

    spdf_win_canvas_destroy(canvas);
    spdf_close(first);
}

int main(int argc, char** argv) {
    if (argc < 3) {
        printf("usage: canvas_swap_test golden.pdf outline.pdf\n");
        return 64;
    }
    test_swap_keeps_viewport_and_ownership(argv[1], argv[2]);
    test_swap_restarts_workers(argv[2]);
    if (g_failures) {
        printf("canvas_swap_test: %d of %d checks failed\n", g_failures, g_checks);
        return 1;
    }
    printf("canvas_swap_test: %d checks passed\n", g_checks);
    return 0;
}
