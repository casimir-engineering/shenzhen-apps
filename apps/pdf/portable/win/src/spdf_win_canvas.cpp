/* The continuous scrolling canvas. See spdf_win_canvas.h for the layering.
 *
 * NOTHING HERE IS STUBBED, which is worth saying because an earlier draft of
 * this file was. All three seams are the real thing:
 *
 *  - GEOMETRY IS REAL. Every slot rect, fit zoom, zoom anchor and horizontal
 *    clamp below comes from T3's spdf_win_layout.h, which is the de-glib'd
 *    port of the shipping GTK4 header. Nothing here re-derives layout maths,
 *    which is the point: the provenance comments in that header record which
 *    shipped bug each formulation fixes.
 *  - THE CACHE IS REAL. T3's spdf_win_lru holds decoded pages under the 96 MB
 *    budget with the same LRU policy the other two frontends use.
 *  - THE WORKER POOL IS REAL. T5's spdf_win_render service prefetches the
 *    pages either side of the viewport off-thread.
 *
 * THE VISIBLE PAGE CAN NOW RENDER OFF-THREAD TOO, and the three conditions on
 * that are the whole design. The asymmetry this header used to defend --
 * on-screen pages rendered SYNCHRONOUSLY in ensure_page() even though a worker
 * pool was right there -- rested on two claims that are both still true, so
 * neither is given up:
 *
 *   - the canvas must never hand back a frame with a HOLE in it, so the
 *     placeholder path in the compose layer stays a safety net rather than
 *     something a reader sees on every page break;
 *   - and the headless viewport probe must stay DETERMINISTIC. A
 *     --render-window-png whose pixels depended on whether a worker had
 *     finished yet would be a PNG no comparison against macOS could trust, and
 *     that comparison is the only evidence this port is correct.
 *
 * So the async path is guarded three ways and the guards are what let it exist:
 *
 *   1. OPT-IN. Nothing is asynchronous until a shell calls
 *      spdf_win_canvas_set_async_visible(), which the headless paths never do.
 *      Every --render-window-png frame and every d2d.compose case is therefore
 *      pixel-for-pixel what it was, by construction rather than by measurement.
 *   2. NEVER THE FIRST FRAME, UNLESS IT WAS GIVEN A BUDGET. frames_built gates
 *      it, so the frame a launch paints before ShowWindow
 *      (spdf_win_window_lifecycle.h) is rendered here, complete, exactly as
 *      before. Launch measures the synchronous page render finishing 41-45 ms
 *      BEFORE the GPU device is ready (windows-launch-performance.md §8), so
 *      that render costs the launch nothing at all: it is spent inside a wait
 *      that existed anyway, and moving it off-thread could only trade a
 *      complete first window for a blank one.
 *
 *      What it CAN cost is unbounded, which is the one thing that argument
 *      never covered: a page of 400,000 stroked paths held that frame for 4.5 s
 *      and one of 2,000,000 for 35 s, with no window of the app on screen and
 *      the process hung. So a launch may hand the first frame a BUDGET
 *      (spdf_win_canvas_set_first_frame_budget): the page is asked of the pool
 *      and waited for, briefly, and a frame that misses the budget comes back
 *      with no page draws and a status line rather than not coming back. The
 *      headless paths set no budget and are unchanged by construction, twice
 *      over -- they never arm async either.
 *   3. NEVER WITHOUT A STAND-IN. When the exact key misses, the async path asks
 *      the pool at VISIBLE priority and then draws this same page at the
 *      nearest zoom the cache does hold (spdf_win_lru_lookup_nearest_zoom) --
 *      right content, right aspect, one resolution behind, stretched over its
 *      slot by the machinery that already stretches byte-capped textures. If
 *      the cache holds nothing at all for that page, it renders here after all.
 *      A soft page for a frame or two is the honest cost; a hole is not.
 *
 * What the pool buys for the NEIGHBOURS is unchanged and is still the bigger
 * half: the page you are about to reach is ready before you get there. What it
 * buys for the visible page is that a zoom step, a jump to a match or a
 * restored page does not stop the UI thread for the length of a MuPDF render.
 */
#include "spdf_win_canvas_internal.h"
#include "spdf_win_launch_profile.h" /* SPDF-LAUNCH markers; free when unset */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* --- the cached value ---------------------------------------------------- */

static void destroy_bitmap(void* value) {
    spdf_bitmap* bitmap = (spdf_bitmap*)value;
    if (!bitmap) return;
    spdf_free_bitmap(bitmap);
    free(bitmap);
}


/* --- measurement --------------------------------------------------------- */

/* Measures pages up to and including `through`. Returns non-zero when at least
 * one new page was measured, i.e. when the layout is now stale. Internal to the
 * canvas's translation units (spdf_win_canvas_internal.h), not public. */
int spdf_win_canvas_ensure_measured(spdf_win_canvas* canvas, int through) {
    char err[128];

    if (through >= canvas->page_count) through = canvas->page_count - 1;
    if (through < canvas->measured) return 0;
    for (int i = canvas->measured; i <= through; ++i) {
        float w = 0.0f;
        float h = 0.0f;
        if (spdf_page_size(canvas->doc, i, &w, &h, err, sizeof(err)) && w > 0.0f && h > 0.0f) {
            canvas->sizes[i].width = w;
            canvas->sizes[i].height = h;
        }
        /* On failure the page keeps the estimate rather than collapsing to
         * zero: a damaged page should leave a gap in the strip, not shift
         * every page after it. */
    }
    canvas->measured = through + 1;
    return 1;
}

/* --- layout -------------------------------------------------------------- */

static int current_page_of(const spdf_win_canvas* canvas) {
    int page = spdf_win_layout_page_nearest_center(&canvas->layout, canvas->scroll_y + (double)canvas->vp_h * 0.5);
    return page < 0 ? 0 : page;
}

static void clamp_scroll(spdf_win_canvas* canvas) {
    SpdfWinHScrollClamp h;
    double max_y = spdf_win_max_d(0.0, canvas->layout.canvas_h - (double)canvas->vp_h);

    canvas->scroll_y = spdf_win_clamp_d(canvas->scroll_y, 0.0, max_y);
    h = spdf_win_hscroll_clamp(&canvas->layout, current_page_of(canvas), (double)canvas->vp_w, canvas->scroll_x);
    canvas->scroll_x = h.value;
}

/* Re-derives the zoom under a fit mode and rebuilds every slot rect. The fit
 * modes key on the CURRENT page, so a mixed-size document fits the page you
 * are looking at rather than the widest sheet in the file. */
/* Everything already rendered is now the wrong size. Bumping the generation
 * cancels in-flight prefetches and makes their results arrive as SUPERSEDED
 * rather than being adopted -- without it, a worker that started before a zoom
 * change would file a stale bitmap under a key nothing will ever ask for, and
 * the LRU would carry it until eviction. */
static void note_zoom_changed(spdf_win_canvas* canvas, double before) {
    if (canvas->service && fabs(canvas->zoom - before) > 1e-9) spdf_win_render_service_bump_generation(canvas->service);
}

void spdf_win_canvas_relayout(spdf_win_canvas* canvas) {
    int page = current_page_of(canvas);
    double before = canvas->zoom;
    double fit = 0.0;

    if (page >= canvas->page_count) page = canvas->page_count - 1;
    if (page < 0) page = 0;
    if (canvas->page_count > 0) {
        const SpdfWinPageSizePt* size = &canvas->sizes[page];
        if (canvas->mode == SPDF_WIN_ZOOM_FIT_WIDTH)
            fit = spdf_win_fit_width_zoom(size->width, (double)canvas->vp_w);
        else if (canvas->mode == SPDF_WIN_ZOOM_FIT_PAGE)
            fit = spdf_win_fit_page_zoom(size->width, size->height, (double)canvas->vp_w, (double)canvas->vp_h);
        else if (canvas->mode == SPDF_WIN_ZOOM_FIT_HEIGHT)
            fit = spdf_win_fit_height_zoom(size->height, (double)canvas->vp_h);
        else if (canvas->mode == SPDF_WIN_ZOOM_ACTUAL)
            fit = spdf_win_clamp_d(canvas->dpi_scale, SPDF_WIN_MIN_ZOOM, SPDF_WIN_MAX_ZOOM);
    }
    /* 0.0 is the fit helpers' "viewport too small to trust" answer; keeping
     * the current zoom then is what stops a window that has not been sized yet
     * from snapping to something absurd. */
    if (fit > 0.0) canvas->zoom = fit;
    note_zoom_changed(canvas, before);

    spdf_win_layout_compute(&canvas->layout, canvas->sizes, canvas->page_count, canvas->zoom, (double)canvas->vp_w,
                            SPDF_WIN_PAGE_MARGIN_H, SPDF_WIN_PAGE_MARGIN_V);
    clamp_scroll(canvas);
}

/* --- lifecycle ----------------------------------------------------------- */

spdf_win_canvas* spdf_win_canvas_create(spdf_document* doc, const char* path, unsigned render_flags, char* err,
                                        size_t err_len) {
    spdf_win_canvas* canvas;
    float w = 612.0f;
    float h = 792.0f;

    if (err && err_len) err[0] = '\0';
    if (!doc) return NULL;

    canvas = (spdf_win_canvas*)calloc(1, sizeof(*canvas));
    if (!canvas) return NULL;
    canvas->doc = doc;
    canvas->path = path ? _strdup(path) : NULL;
    canvas->render_flags = render_flags;
    canvas->page_count = spdf_page_count(doc);
    canvas->zoom = 1.0;
    canvas->mode = SPDF_WIN_ZOOM_FIT_WIDTH;
    canvas->dpi_scale = 1.0;
    canvas->vp_w = 1;
    canvas->vp_h = 1;
    if (canvas->page_count <= 0) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "This document has no pages.");
        free(canvas);
        return NULL;
    }

    canvas->sizes = (SpdfWinPageSizePt*)calloc((size_t)canvas->page_count, sizeof(SpdfWinPageSizePt));
    if (!canvas->sizes) {
        free(canvas);
        return NULL;
    }
    spdf_win_launch_mark("canvas-create-begin");
    if (!spdf_page_size(doc, 0, &w, &h, err, err_len) || w <= 0.0f || h <= 0.0f) {
        free(canvas->sizes);
        free(canvas);
        return NULL;
    }
    spdf_win_launch_mark("canvas-page0-measured");
    for (int i = 0; i < canvas->page_count; ++i) {
        canvas->sizes[i].width = w;
        canvas->sizes[i].height = h;
    }
    canvas->measured = 1;

    spdf_win_lru_init(&canvas->cache, SPDF_WIN_MAX_RENDER_SURFACE_BYTES, destroy_bitmap);
    /* No path means no prefetch -- the workers open the file themselves, one
     * document per thread, because the core's contract is one spdf_document
     * per thread and handing them ours would break it. Not having a service is
     * a supported state, not a failure: everything still renders, just on the
     * calling thread. Starting it costs nothing here; T5 spawns threads on the
     * first request, not on construction, so launch pays for no worker it does
     * not use. */
    /* The notify hook is the canvas's own trampoline, installed here because
     * the service's is immutable after construction, and INERT until a shell
     * arms it with spdf_win_canvas_set_async_visible(). Unarmed it costs one
     * interlocked read per completion, which is the price of the visible page
     * being able to render off-thread at all: without a notify, the bitmap
     * would land and nothing would ask for the repaint that shows it, and the
     * reader would sit looking at the stand-in until they moved the mouse. */
    canvas->service =
        spdf_win_render_service_new(path, NULL, SPDF_WIN_MAX_RENDER_SURFACE_BYTES, spdf_win_canvas_render_notify,
                                    canvas);
    return canvas;
}

void spdf_win_canvas_destroy(spdf_win_canvas* canvas) {
    if (!canvas) return;
    /* The service FIRST, and while the canvas is still whole: freeing it
     * cancels everything in flight and then delivers each outstanding request
     * SPDF_WIN_RENDER_SHUTDOWN on this thread, and those callbacks touch this
     * canvas's cache. Tearing the cache down first would hand them freed
     * memory. */
    spdf_win_render_service_free(canvas->service);
    canvas->service = NULL;
    spdf_win_canvas_selection_teardown(canvas);
    spdf_win_lru_deinit(&canvas->cache);
    spdf_win_layout_clear(&canvas->layout);
    /* A document adopted by spdf_win_canvas_replace_document() is the canvas's
     * to close; the one create() was given never is. After the service and the
     * selection, both of which may still name it. */
    if (canvas->owned_doc) spdf_close(canvas->owned_doc);
    free(canvas->draws);
    free(canvas->sizes);
    free(canvas->path);
    free(canvas);
}

/* --- viewport, zoom, scroll ---------------------------------------------- */

void spdf_win_canvas_set_viewport(spdf_win_canvas* canvas, unsigned px_w, unsigned px_h, float dpi_scale) {
    if (!canvas) return;
    if (px_w == 0) px_w = 1;
    if (px_h == 0) px_h = 1;
    if (dpi_scale <= 0.0f) dpi_scale = 1.0f;
    if (canvas->vp_w == px_w && canvas->vp_h == px_h && canvas->dpi_scale == (double)dpi_scale) return;
    canvas->vp_w = px_w;
    canvas->vp_h = px_h;
    canvas->dpi_scale = dpi_scale;
    spdf_win_canvas_relayout(canvas);
}

void spdf_win_canvas_set_zoom_mode(spdf_win_canvas* canvas, spdf_win_zoom_mode mode) {
    if (!canvas || canvas->mode == mode) return;
    canvas->mode = mode;
    spdf_win_canvas_relayout(canvas);
}

spdf_win_zoom_mode spdf_win_canvas_zoom_mode(const spdf_win_canvas* canvas) {
    return canvas ? canvas->mode : SPDF_WIN_ZOOM_FREE;
}

float spdf_win_canvas_zoom(const spdf_win_canvas* canvas) { return canvas ? (float)canvas->zoom : 1.0f; }

void spdf_win_canvas_set_zoom_at(spdf_win_canvas* canvas, float zoom, float vx, float vy) {
    SpdfWinZoomAnchor anchor;
    double target;

    if (!canvas) return;
    target = spdf_win_clamp_d((double)zoom, SPDF_WIN_MIN_ZOOM, SPDF_WIN_MAX_ZOOM);
    if (fabs(target - canvas->zoom) < 1e-9) return;

    /* Captured BEFORE the relayout, in document space (page + PDF point), so
     * the point survives a layout whose slot rects all moved. */
    spdf_win_zoom_anchor_capture(&anchor, &canvas->layout, canvas->sizes, canvas->zoom, (double)vx, (double)vy,
                                 canvas->scroll_x, canvas->scroll_y);
    double before = canvas->zoom;
    canvas->zoom = target;
    canvas->mode = SPDF_WIN_ZOOM_FREE;
    note_zoom_changed(canvas, before);
    spdf_win_layout_compute(&canvas->layout, canvas->sizes, canvas->page_count, canvas->zoom, (double)canvas->vp_w,
                            SPDF_WIN_PAGE_MARGIN_H, SPDF_WIN_PAGE_MARGIN_V);
    spdf_win_zoom_anchor_apply(&anchor, &canvas->layout, canvas->zoom, (double)canvas->vp_w, (double)canvas->vp_h,
                               &canvas->scroll_x, &canvas->scroll_y);
    clamp_scroll(canvas);
}

void spdf_win_canvas_zoom_at(spdf_win_canvas* canvas, float factor, float vx, float vy) {
    if (!canvas || !(factor > 0.0f)) return;
    spdf_win_canvas_set_zoom_at(canvas, (float)(canvas->zoom * (double)factor), vx, vy);
}

int spdf_win_canvas_scroll_to(spdf_win_canvas* canvas, float x, float y) {
    double before_x;
    double before_y;

    if (!canvas) return 0;
    before_x = canvas->scroll_x;
    before_y = canvas->scroll_y;
    canvas->scroll_x = (double)x;
    canvas->scroll_y = (double)y;
    clamp_scroll(canvas);
    return fabs(canvas->scroll_x - before_x) > 0.01 || fabs(canvas->scroll_y - before_y) > 0.01;
}

int spdf_win_canvas_scroll_by(spdf_win_canvas* canvas, float dx, float dy) {
    if (!canvas) return 0;
    return spdf_win_canvas_scroll_to(canvas, (float)(canvas->scroll_x + (double)dx),
                                     (float)(canvas->scroll_y + (double)dy));
}

int spdf_win_canvas_scroll_to_page(spdf_win_canvas* canvas, int page_index) {
    if (!canvas || page_index < 0 || page_index >= canvas->page_count) return 0;
    if (spdf_win_canvas_ensure_measured(canvas, page_index)) spdf_win_canvas_relayout(canvas);
    if (page_index >= canvas->layout.count) return 0;
    return spdf_win_canvas_scroll_to(canvas, (float)canvas->scroll_x,
                                     (float)(canvas->layout.rects[page_index].y - SPDF_WIN_PAGE_MARGIN_V));
}

/* The scrollbar arithmetic -- fractions, and the current page's pan range --
 * is spdf_win_canvas_scrollbar.h, included once, here, because it needs
 * current_page_of() and spdf_win_canvas_scroll_to() above it and belongs
 * after them in the reading order too. */
#include "spdf_win_canvas_scrollbar.h"

float spdf_win_canvas_scroll_x(const spdf_win_canvas* canvas) { return canvas ? (float)canvas->scroll_x : 0.0f; }
float spdf_win_canvas_scroll_y(const spdf_win_canvas* canvas) { return canvas ? (float)canvas->scroll_y : 0.0f; }
float spdf_win_canvas_content_w(const spdf_win_canvas* canvas) { return canvas ? (float)canvas->layout.canvas_w : 0.0f; }
float spdf_win_canvas_content_h(const spdf_win_canvas* canvas) { return canvas ? (float)canvas->layout.canvas_h : 0.0f; }
int spdf_win_canvas_page_count(const spdf_win_canvas* canvas) { return canvas ? canvas->page_count : 0; }
int spdf_win_canvas_current_page(const spdf_win_canvas* canvas) { return canvas ? current_page_of(canvas) : 0; }
size_t spdf_win_canvas_cache_bytes(const spdf_win_canvas* canvas) {
    return canvas ? spdf_win_lru_bytes(&canvas->cache) : 0;
}

/* --- rendering -----------------------------------------------------------
 *
 * THE T5 SEAM -- cache hit, then the stand-in, then the first frame's bound,
 * then a synchronous render -- is spdf_win_canvas_ensure_page(), and it lives
 * in spdf_win_canvas_prefetch.cpp with the rest of the pool's business. It
 * moved when this file reached its 500-line cap, to the seam
 * spdf_win_canvas_internal.h had already drawn: every clause of that decision
 * except the last is about the worker pool, and the last one is what happens
 * when the pool is not used. What is left here is geometry and composition. */

int spdf_win_canvas_build_scene(spdf_win_canvas* canvas, spdf_win_scene* scene) {
    int first = 0;
    int last = 0;
    int visible = 0;

    if (!canvas || !scene) return 0;
    /* Adopt anything the pool finished since the last frame. Cheap and O(1)
     * per item -- adoption on the UI thread must never do O(n) work. */
    if (canvas->service) spdf_win_render_drain(canvas->service, -1);
    canvas->sync_renders = 0;
    canvas->stale_draws = 0;
    if (canvas->layout.count != canvas->page_count) spdf_win_canvas_relayout(canvas);

    /* Measure forward until the visible range stops changing. Each round can
     * only extend `measured`, which is bounded by the page count, so this
     * terminates; in practice it runs twice -- once to find the range under
     * the estimate, once to confirm it under the real sizes. */
    for (int round = 0; round < 8; ++round) {
        double y0 = canvas->scroll_y;
        double y1 = y0 + (double)canvas->vp_h;
        visible = spdf_win_layout_visible_range(&canvas->layout, y0, y1, &first, &last);
        if (!visible) {
            first = last = current_page_of(canvas);
            visible = canvas->page_count > 0;
        }
        if (!spdf_win_canvas_ensure_measured(canvas, last + 1)) break;
        spdf_win_canvas_relayout(canvas);
    }

    if (last >= canvas->page_count) last = canvas->page_count - 1;
    if (first < 0) first = 0;

    if (last - first + 1 > canvas->draws_cap) {
        int want = last - first + 1;
        spdf_win_page_draw* grown = (spdf_win_page_draw*)realloc(canvas->draws, (size_t)want * sizeof(*grown));
        if (!grown) return 0;
        canvas->draws = grown;
        canvas->draws_cap = want;
    }

    canvas->draws_count = 0;
    for (int i = first; i <= last && visible; ++i) {
        const SpdfWinRect* rect = &canvas->layout.rects[i];
        spdf_win_page_draw* draw = &canvas->draws[canvas->draws_count];
        draw->bitmap = spdf_win_canvas_ensure_page(canvas, i);
        /* A PAGE THE POOL IS STILL RENDERING GETS NO SLOT AT ALL. A slot with a
         * NULL bitmap is the compose layer's placeholder, which is the right
         * answer for a page that FAILED and the wrong one for a page that is
         * merely not here yet: the frame would then claim to hold something,
         * and the status line -- the only thing there is to show -- would not
         * be drawn. Dropping the draw is what keeps "no frame has a hole in
         * it" true while the first page is still on its way. */
        if (!draw->bitmap && canvas->page_deferred) continue;
        ++canvas->draws_count;
        draw->page_index = i;
        draw->dest_x = (float)(rect->x - canvas->scroll_x);
        draw->dest_y = (float)(rect->y - canvas->scroll_y);
        draw->dest_w = (float)rect->w;
        draw->dest_h = (float)rect->h;
    }

    /* The two pages the reader is most likely to reach next, off-thread. Both
     * directions, because scrolling back up is as common as scrolling down --
     * but NOT WHILE THIS FRAME IS STILL WAITING FOR ITS FIRST PAGE. A
     * neighbour rendered beside the page somebody is actually waiting for
     * costs that page real time: measured 6.4 s against 4.6 s on a page of
     * 400,000 stroked paths, because two MuPDF renders of one heavy page share
     * one machine's memory bandwidth. They are asked for on the frame that
     * finally has something in it, which for a page nobody has scrolled to yet
     * is soon enough. */
    if (canvas->draws_count > 0 || !canvas->page_deferred) {
        spdf_win_canvas_prefetch(canvas, last + 1);
        spdf_win_canvas_prefetch(canvas, first - 1);
    }

    scene->page = NULL;
    scene->pages = canvas->draws;
    scene->page_count = canvas->draws_count;
    scene->fit = SPDF_WIN_FIT_CANVAS;
    scene->target_px_w = canvas->vp_w;
    scene->target_px_h = canvas->vp_h;
    scene->dpi_scale = (float)canvas->dpi_scale;
    scene->dark = (canvas->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    scene->message = canvas->draws_count > 0 ? NULL : (canvas->status[0] ? canvas->status : NULL);
    /* Counted only for a frame that HAS something in it, because it is the
     * gate on the async path and "the first frame is synchronous" has to mean
     * the first frame a reader can see, not the first call made against a
     * canvas that had no viewport yet. */
    if (canvas->draws_count > 0) {
        /* The launch timeline's answer to "when was there a PAGE on screen",
         * which first-compose-end stopped answering the moment a first frame
         * could be a status line instead. */
        SPDF_WIN_LAUNCH_MARK_ONCE("first-page-scene");
        canvas->frames_built++;
    }
    return canvas->draws_count > 0;
}
