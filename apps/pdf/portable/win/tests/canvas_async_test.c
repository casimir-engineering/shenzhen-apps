/* canvas_async_test.c — the visible page rendered OFF the calling thread, and
 * the three guards that make that safe.
 *
 * A real canvas over a real document with no window anywhere, driven the way a
 * window drives it: build a frame, move, build again. What it asserts is the
 * contract spdf_win_canvas.cpp's header states, because every one of those
 * clauses is load-bearing and none of them is checkable from the outside:
 *
 *   1. UNARMED, NOTHING CHANGES. Sync renders, stale draws and cache bytes come
 *      out of an identical script the same either way -- which is why every
 *      --render-window-png frame is byte-identical and why that is true by
 *      construction rather than by a pixel comparison.
 *   2. THE FIRST FRAME IS SYNCHRONOUS, armed or not, UNLESS IT WAS GIVEN A
 *      BUDGET. That is what keeps the launch path painting a COMPLETE window
 *      before ShowWindow -- and the budget is what keeps a page that takes
 *      four seconds to render from meaning four seconds with no window at all
 *      (spdf_win_canvas_set_first_frame_budget; case 3b).
 *   3. NO FRAME EVER HAS A HOLE. Every draw in every frame of every case below
 *      carries a bitmap, including the frames that had to draw a page at the
 *      wrong zoom while the right one rendered. A frame that is still waiting
 *      for its first page has no DRAWS at all and carries a message instead,
 *      which is the same invariant seen from the other side.
 *
 * Plus the thing threading changes have to earn: a stress run of rapid scrolls,
 * zooms and rebuilds that ends with the pool idle, nothing in flight, and the
 * documents closed -- callback-exactly-once is the render pool's own contract
 * (render_service_test.c) and this is the canvas holding up its end of it.
 *
 * WHAT IT IS NOT. It does not compare pixels: the stand-in is by definition a
 * different resolution from the exact render, and asserting anything about how
 * it looks belongs to the d2d compose cases. It asserts WHICH bitmap was drawn
 * and WHERE the render happened.
 */
/* spdf-test-sources: portable/win/src/spdf_win_canvas.cpp portable/win/src/spdf_win_canvas_prefetch.cpp portable/win/src/spdf_win_canvas_selection.cpp portable/win/src/spdf_win_find_canvas.cpp portable/win/src/spdf_win_selection.cpp portable/win/src/spdf_win_links.cpp portable/win/src/spdf_win_lru.c portable/win/src/spdf_win_render.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/outline.pdf */
/* spdf-test-needs: mupdf */

#include <stdio.h>
#include <string.h>
#include <windows.h>

#include "spdf_win_canvas.h"
#include "spdf_win_render.h"

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

/* The window's notify hook, in its smallest honest form: it is called on a
 * WORKER thread, so it does one interlocked increment and returns. A real
 * window PostMessages. */
static volatile long g_notified;
static void on_ready(void* ctx) {
    (void)ctx;
    InterlockedIncrement(&g_notified);
}

/* Every draw in a frame must carry a bitmap. This is guard 3, asserted on every
 * frame every case builds rather than once at the end, because a hole appears
 * for exactly one frame and a check at the end would never see it. */
static int frame_is_whole(const spdf_win_scene* scene) {
    int i;
    if (scene->page_count <= 0) return 0;
    for (i = 0; i < scene->page_count; ++i)
        if (!scene->pages[i].bitmap) return 0;
    return 1;
}

static spdf_win_canvas* open_canvas(const char* path, spdf_document** out_doc) {
    char err[256] = {0};
    spdf_document* doc = spdf_open(path, err, sizeof(err));
    spdf_win_canvas* canvas;
    if (!doc) {
        printf("SKIP could not open %s: %s\n", path, err);
        return NULL;
    }
    canvas = spdf_win_canvas_create(doc, path, 0u, err, sizeof(err));
    if (!canvas) {
        printf("FAIL could not build a canvas: %s\n", err);
        ++g_failures;
        spdf_close(doc);
        return NULL;
    }
    spdf_win_canvas_set_viewport(canvas, 1120, 800, 1.0f);
    *out_doc = doc;
    return canvas;
}

static int build(spdf_win_canvas* canvas, spdf_win_scene* scene) {
    memset(scene, 0, sizeof(*scene));
    return spdf_win_canvas_build_scene(canvas, scene);
}

/* --- 1: an unarmed canvas is the canvas that shipped -------------------- */

/* THE SCRIPT, and it is a zoom script on purpose. A zoom step invalidates every
 * cached bitmap at once, so the frame after it is both the frame that would draw
 * a stand-in and the frame the synchronous canvas spends a whole MuPDF render
 * on -- Ctrl+wheel is the interaction where this change is worth the most,
 * because notches arrive faster than a page renders. Run it armed and unarmed
 * and compare the counters a --render-window-png transcript prints, plus the
 * wall time each build_scene() took on THIS thread, which is what a stutter is
 * made of. */
struct run {
    int sync;
    int stale;
    size_t bytes;
    double ui_ms;     /* total time inside build_scene() */
    double worst_ms;  /* the slowest single frame: the stutter */
};

static double now_ms(void) {
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}

static void script(spdf_win_canvas* canvas, struct run* out) {
    spdf_win_scene scene;
    int i;
    memset(out, 0, sizeof(*out));
    for (i = 0; i < 8; ++i) {
        double t0 = now_ms();
        int ok = build(canvas, &scene);
        double ms = now_ms() - t0;
        CHECK(ok != 0);
        CHECK(frame_is_whole(&scene));
        out->sync += spdf_win_canvas_sync_renders(canvas);
        out->stale += spdf_win_canvas_stale_draws(canvas);
        out->ui_ms += ms;
        if (ms > out->worst_ms) out->worst_ms = ms;
        if (i % 2 == 1) spdf_win_canvas_zoom_at(canvas, 1.4f, 560.0f, 400.0f);
        else spdf_win_canvas_scroll_by(canvas, 0.0f, 400.0f);
        /* What a reader's hand supplies for free and a back-to-back loop does
         * not. Without it the async canvas would simply never have a result to
         * adopt and the two runs would agree for the wrong reason. */
        spdf_win_canvas_settle(canvas, 8000);
    }
    out->bytes = spdf_win_canvas_cache_bytes(canvas);
}

static void case_unarmed_is_unchanged(const char* path) {
    spdf_document* doc = NULL;
    spdf_win_canvas* canvas = open_canvas(path, &doc);
    struct run off, on;
    if (!canvas) return;
    script(canvas, &off);
    CHECK(off.stale == 0);
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);

    canvas = open_canvas(path, &doc);
    if (!canvas) return;
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    script(canvas, &on);
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);

    /* Same script, same visible pages, same bytes resident: the async canvas
     * did not render MORE, it rendered the same work somewhere else. A settle
     * between frames is what makes that comparable at all. */
    CHECK(on.bytes == off.bytes);
    /* And it moved work off this thread rather than merely relabelling it. The
     * first frame is synchronous in both runs, so this can never reach zero. */
    CHECK(on.sync < off.sync);
    CHECK(on.stale >= 1);
    /* Times are PRINTED, not asserted: the box this runs on builds five other
     * tracks at once and a wall-clock bound would be a flake generator. The
     * counters above are the assertion. */
    printf("script sync=%d/%d stale=%d/%d bytes=%llu/%llu (off/on)\n", off.sync, on.sync, off.stale, on.stale,
           (unsigned long long)off.bytes, (unsigned long long)on.bytes);
    printf("script ui-thread total %.1f/%.1f ms, worst frame %.1f/%.1f ms (off/on)\n", off.ui_ms, on.ui_ms,
           off.worst_ms, on.worst_ms);
}

/* --- 2: the first frame is synchronous whatever the flag says ----------- */

static void case_first_frame_is_synchronous(const char* path) {
    spdf_document* doc = NULL;
    spdf_win_canvas* canvas = open_canvas(path, &doc);
    spdf_win_scene scene;
    if (!canvas) return;
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    CHECK(build(canvas, &scene) != 0);
    /* THE LAUNCH GUARANTEE. Page 0 was rendered on this thread, in this call,
     * and the frame is complete -- so a window that paints before ShowWindow
     * still reveals a finished page rather than an empty client area. */
    CHECK(spdf_win_canvas_sync_renders(canvas) >= 1);
    CHECK(spdf_win_canvas_stale_draws(canvas) == 0);
    CHECK(frame_is_whole(&scene));
    /* And the second frame at the same zoom is a pure cache hit either way:
     * async only shows up when something invalidated the pixels. */
    CHECK(build(canvas, &scene) != 0);
    CHECK(spdf_win_canvas_sync_renders(canvas) == 0);
    CHECK(spdf_win_canvas_stale_draws(canvas) == 0);
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);
}

/* --- 3: a zoom step draws the stand-in, then the real thing ------------- */

static void case_zoom_uses_stand_in_then_settles(const char* path) {
    spdf_document* doc = NULL;
    spdf_win_canvas* canvas = open_canvas(path, &doc);
    spdf_win_scene scene;
    const spdf_bitmap* soft;
    const spdf_bitmap* sharp;
    int soft_h;
    if (!canvas) return;
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    CHECK(build(canvas, &scene) != 0); /* frame 1: synchronous, warms the cache */
    InterlockedExchange(&g_notified, 0);

    /* A zoom step: every cached bitmap is now the wrong size, so this is the
     * frame the old canvas spent a whole MuPDF render on. */
    spdf_win_canvas_zoom_at(canvas, 2.0f, 560.0f, 400.0f);
    CHECK(build(canvas, &scene) != 0);
    CHECK(frame_is_whole(&scene));
    CHECK(spdf_win_canvas_stale_draws(canvas) >= 1);
    CHECK(spdf_win_canvas_sync_renders(canvas) == 0);
    soft = scene.pages[0].bitmap;
    soft_h = soft->height;
    /* The stand-in is the SAME PAGE at the old zoom: smaller than the slot it
     * is being stretched over, which is exactly the byte-cap case the compose
     * layer already handles. */
    CHECK((double)soft_h < (double)scene.pages[0].dest_h * 0.9);

    /* The pool was told, and the worker rang the bell. */
    CHECK(spdf_win_canvas_settle(canvas, 8000) >= 1);
    CHECK(InterlockedCompareExchange(&g_notified, 0, 0) >= 1);

    /* The next frame is the exact render, at the slot's own size. */
    CHECK(build(canvas, &scene) != 0);
    CHECK(frame_is_whole(&scene));
    CHECK(spdf_win_canvas_stale_draws(canvas) == 0);
    CHECK(spdf_win_canvas_sync_renders(canvas) == 0);
    sharp = scene.pages[0].bitmap;
    CHECK(sharp != soft);
    CHECK(sharp->height > soft_h);
    printf("stand-in %dpx -> exact %dpx over a %.0fpx slot\n", soft_h, sharp->height, (double)scene.pages[0].dest_h);
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);
}

/* --- 3b: the first frame has a bound ------------------------------------
 *
 * THE ONE FRAME WITH NOTHING TO FALL BACK ON. A fresh canvas has no exact
 * bitmap and no stand-in, so the first frame used to render on this thread
 * however long that took -- and a launch paints that frame BEFORE ShowWindow,
 * so its cost is measured in seconds with no window on screen at all.
 *
 * spdf_win_canvas_set_first_frame_budget() bounds it, and this case pins the
 * bound against the SAME document at the SAME zoom on whatever machine it runs
 * on: build the first frame twice, once unbounded and once with a 1 ms budget,
 * and compare how long build_scene() held the calling thread. No wall-clock
 * constant appears in an assertion -- the unbounded run is the constant.
 *
 * A slow first page has to come from a fixture small enough to keep in the
 * repo, so the zoom is pushed to the render byte cap: a ~100 MB raster of a
 * 612x792 page, which is tens of milliseconds of writing pixels however fast
 * the box is. That is also why the bound and the RECOVERY are two separate
 * canvases below -- at the cap, one page fills the whole 96 MB bitmap cache, so
 * the neighbour prefetch evicts it as fast as it arrives, and a frame that
 * never keeps its page is a cache-pressure story rather than this one. */
static void case_first_frame_budget(const char* path) {
    spdf_document* doc = NULL;
    spdf_win_canvas* canvas;
    spdf_win_scene scene;
    double unbounded_ms;
    double bounded_ms;
    double t0;
    int first_ok;

    /* --- the bound. Run 1: no budget, which is the launch as it shipped --
     * one MuPDF render, on this thread, inside build_scene. */
    canvas = open_canvas(path, &doc);
    if (!canvas) return;
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    spdf_win_canvas_set_zoom_at(canvas, 40.0f, 560.0f, 400.0f); /* capped to ~7.2 */
    t0 = now_ms();
    CHECK(build(canvas, &scene) != 0);
    unbounded_ms = now_ms() - t0;
    CHECK(frame_is_whole(&scene));
    CHECK(spdf_win_canvas_sync_renders(canvas) >= 1);
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);

    /* Run 2: the same first frame at the same zoom, with a budget of 1 ms. */
    canvas = open_canvas(path, &doc);
    if (!canvas) return;
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    spdf_win_canvas_set_first_frame_budget(canvas, 1);
    spdf_win_canvas_set_zoom_at(canvas, 40.0f, 560.0f, 400.0f);
    t0 = now_ms();
    CHECK(build(canvas, &scene) == 0); /* nothing to draw yet -- and it said so */
    bounded_ms = now_ms() - t0;
    /* THE BOUND. Not "fast" in milliseconds, which would be a flake generator
     * on a box building five other tracks: a fraction of what the same frame
     * costs with no bound, which is the claim being made. */
    CHECK(bounded_ms < unbounded_ms * 0.5);
    /* NEVER A HOLE. The frame has no page draws at all rather than a slot with
     * no bitmap in it, and it carries the line the compose layer draws when a
     * scene has nothing to show. */
    CHECK(scene.page_count == 0);
    CHECK(scene.message != NULL && scene.message[0] != L'\0');
    /* And the page went to the POOL rather than to this thread. */
    CHECK(spdf_win_canvas_sync_renders(canvas) == 0);
    printf("first frame: %.1f ms unbounded, %.1f ms with a 1 ms budget, message \"%ls\"\n", unbounded_ms, bounded_ms,
           scene.message ? scene.message : L"");
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);

    /* --- the recovery, at a zoom where the cache holds what it is given.
     * Whether this first frame beats its 1 ms budget or misses it is the
     * machine's business; what must hold either way is that nothing rendered
     * on this thread and that the page is THERE on the frame after the pool
     * finishes -- in a window, the repaint the `ready` hook asks for. */
    canvas = open_canvas(path, &doc);
    if (!canvas) return;
    InterlockedExchange(&g_notified, 0);
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    spdf_win_canvas_set_first_frame_budget(canvas, 1);
    first_ok = build(canvas, &scene);
    CHECK(spdf_win_canvas_sync_renders(canvas) == 0);
    if (!first_ok) {
        CHECK(scene.page_count == 0);
        CHECK(scene.message != NULL);
    } else {
        CHECK(frame_is_whole(&scene));
    }
    CHECK(spdf_win_canvas_settle(canvas, 60000) >= 1);
    CHECK(InterlockedCompareExchange(&g_notified, 0, 0) >= 1);
    CHECK(build(canvas, &scene) != 0);
    CHECK(frame_is_whole(&scene));
    CHECK(spdf_win_canvas_sync_renders(canvas) == 0);
    printf("first frame recovery: deferred=%d, then %d page(s), %d rendered here\n", !first_ok, scene.page_count,
           spdf_win_canvas_sync_renders(canvas));
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);
}

/* --- 4: the stress case ------------------------------------------------- */

/* Rapid scrolls, zooms and rebuilds with no settle anywhere -- the shape of a
 * hand on a wheel, which is the case where the pool is asked for a page it is
 * already rendering and where a generation bump lands on work in flight. Three
 * invariants, and the third is the one that would catch a leak: every request
 * accepted is answered exactly once, so a service that reports nothing in
 * flight has also freed every adopt_ctx and every RGBA buffer it was handed. */
static void case_stress(const char* path) {
    spdf_document* doc = NULL;
    spdf_win_canvas* canvas = open_canvas(path, &doc);
    spdf_win_scene scene;
    unsigned seed = 20260903u;
    int i;
    int holes = 0;
    if (!canvas) return;
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    CHECK(build(canvas, &scene) != 0);
    for (i = 0; i < 400; ++i) {
        seed = seed * 1103515245u + 12345u;
        switch ((seed >> 16) % 4u) {
            case 0: spdf_win_canvas_scroll_by(canvas, 0.0f, (float)(int)((seed >> 8) % 900u) - 300.0f); break;
            case 1: spdf_win_canvas_zoom_at(canvas, (seed & 1u) ? 1.1f : 0.9f, 400.0f, 300.0f); break;
            case 2: spdf_win_canvas_scroll_to_page(canvas, (int)((seed >> 4) % 4u)); break;
            default: spdf_win_canvas_set_zoom_mode(canvas, ((seed >> 2) & 1u) ? SPDF_WIN_ZOOM_FIT_PAGE
                                                                             : SPDF_WIN_ZOOM_FIT_WIDTH); break;
        }
        if (!build(canvas, &scene) || !frame_is_whole(&scene)) ++holes;
    }
    CHECK(holes == 0);
    /* Let everything land, then insist the books balance. */
    (void)spdf_win_canvas_settle(canvas, 20000);
    printf("stress frames=400 holes=%d started=%llu\n", holes, spdf_win_canvas_prefetched(canvas));
    /* Destroy is the real assertion: it cancels everything in flight and then
     * delivers every outstanding request on this thread, so a canvas whose
     * in-flight bookkeeping was wrong would double-free or leak here, under a
     * debug CRT that says so. */
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);
}

/* --- 5: arming is write-once ------------------------------------------- */

static void other_ready(void* ctx) { (void)ctx; }

static void case_arming_is_write_once(const char* path) {
    spdf_document* doc = NULL;
    spdf_win_canvas* canvas = open_canvas(path, &doc);
    spdf_win_scene scene;
    if (!canvas) return;
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    CHECK(build(canvas, &scene) != 0);
    /* A second, DIFFERENT hook changes NOTHING. The pair is published to the
     * worker with one interlocked store and rewriting it would be the one race
     * in this design, so the canvas keeps the hook it was armed with -- it does
     * not adopt the new one and it does not disarm itself either, because
     * silently turning async off would be a worse surprise than ignoring a call
     * that should not have been made. */
    spdf_win_canvas_set_async_visible(canvas, other_ready, NULL);
    InterlockedExchange(&g_notified, 0);
    spdf_win_canvas_zoom_at(canvas, 2.0f, 0.0f, 0.0f);
    CHECK(build(canvas, &scene) != 0);
    CHECK(spdf_win_canvas_stale_draws(canvas) >= 1);
    CHECK(spdf_win_canvas_sync_renders(canvas) == 0);
    /* And the bell that rang was the FIRST hook's. */
    CHECK(spdf_win_canvas_settle(canvas, 8000) >= 1);
    CHECK(InterlockedCompareExchange(&g_notified, 0, 0) >= 1);
    /* Disarming works, and re-arming the ORIGINAL hook works again. */
    spdf_win_canvas_set_async_visible(canvas, NULL, NULL);
    spdf_win_canvas_zoom_at(canvas, 1.3f, 0.0f, 0.0f);
    CHECK(build(canvas, &scene) != 0);
    CHECK(spdf_win_canvas_stale_draws(canvas) == 0);
    CHECK(spdf_win_canvas_sync_renders(canvas) >= 1);
    spdf_win_canvas_set_async_visible(canvas, on_ready, NULL);
    spdf_win_canvas_zoom_at(canvas, 0.6f, 0.0f, 0.0f);
    CHECK(build(canvas, &scene) != 0);
    CHECK(spdf_win_canvas_stale_draws(canvas) >= 1);
    spdf_win_canvas_destroy(canvas);
    spdf_close(doc);
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "portable/win/tests/fixtures/outline.pdf";
    printf("== canvas_async transcript ==\n");
    case_unarmed_is_unchanged(path);
    case_first_frame_is_synchronous(path);
    case_zoom_uses_stand_in_then_settles(path);
    case_first_frame_budget(path);
    case_arming_is_write_once(path);
    case_stress(path);
    printf("canvas_async_test: %s (%d failure%s of %d checks)\n", g_failures ? "FAIL" : "PASS", g_failures,
           g_failures == 1 ? "" : "s", g_checks);
    return g_failures ? 1 : 0;
}
