/* The canvas's half of T5's render service: prefetch, the visible-page ask,
 * the first frame's bound, adoption, the per-page decision that consumes all
 * four (spdf_win_canvas_ensure_page), and the notify hook.
 *
 * Split out of spdf_win_canvas.cpp under the repo's 500-line cap. The division
 * is not arbitrary -- this file is the ONLY place the canvas talks to another
 * thread, so "is this concurrent?" is answerable by looking at one file rather
 * than by reading the whole canvas. ensure_page() joined it when that file hit
 * the cap a second time, and it belongs: every clause of it but the last asks
 * whether the pool can supply this page, and the last one is what happens when
 * the answer is no.
 *
 * THE THREADING RULE, and it is the reason almost none of this needs a lock:
 * requests go out from build_scene and results come back through
 * spdf_win_render_drain(), which runs on whichever thread calls it -- the same
 * one. The worker threads never touch the canvas or its cache; they hand back a
 * buffer and nothing else. The one exception is spdf_win_canvas_render_notify(),
 * which DOES run on a worker, reads two fields and one interlocked word, and
 * calls nothing of the canvas's -- see its comment. If a future change ever
 * calls drain() from a second thread, the LRU needs a mutex that same day.
 */
#include "spdf_win_canvas_internal.h"
#include "spdf_win_launch_profile.h" /* SPDF-LAUNCH markers; free when unset */

#include <windows.h> /* Sleep and GetTickCount64 for the waits; Interlocked* for notify */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* --- what is already on its way ------------------------------------------
 *
 * The service coalesces a second request whose key matches one in flight, but
 * only up to SPDF_WIN_RENDER_MAX_WAITERS of them; past that it starts a second
 * render of the same page. A window repainting while a slow page renders would
 * hit that in a quarter of a second, so the canvas keeps its own small table
 * and simply does not ask twice. */

static int inflight_index(const spdf_win_canvas* canvas, const SpdfWinLruKey* key) {
    int i;
    for (i = 0; i < canvas->inflight_count; ++i)
        if (spdf_win_lru_key_equal(&canvas->inflight[i].key, key)) return i;
    return -1;
}

static void inflight_drop(spdf_win_canvas* canvas, unsigned long long token) {
    int i;
    for (i = 0; i < canvas->inflight_count; ++i) {
        if (canvas->inflight[i].token != token) continue;
        canvas->inflight[i] = canvas->inflight[canvas->inflight_count - 1];
        --canvas->inflight_count;
        return;
    }
}

/* --- prefetch adoption --------------------------------------------------- */

/* One per outstanding request. It carries the display scale rather than
 * reading canvas->dpi_scale at delivery, because the two can differ: the
 * window may have moved to another monitor while the render was in flight,
 * and filing the result under today's scale would put it where nothing will
 * ever look for it. */
struct adopt_ctx {
    spdf_win_canvas* canvas;
    double scale;
};

static void adopt_render(spdf_win_render_result* result, void* user_data) {
    adopt_ctx* ctx = (adopt_ctx*)user_data;
    SpdfWinLruKey key;
    spdf_bitmap* bitmap;

    if (!ctx) return;
    /* The slot goes FIRST and unconditionally: exactly one callback arrives per
     * request whatever its status, so this is the one place the table can be
     * kept honest, and a cancelled or superseded page must become askable
     * again. */
    inflight_drop(ctx->canvas, result->token);
    /* Anything but OK -- cancelled, superseded by a zoom change, shut down,
     * failed -- is simply dropped. The service guarantees exactly one callback
     * per request either way, which is what makes freeing ctx here safe. */
    if (result->status != SPDF_WIN_RENDER_OK || !result->rgba || result->width <= 0) {
        /* AND IT ENDS THE FIRST FRAME'S BUDGET. The pool opens its own handle
         * on the file, so it can fail where this thread cannot: an encrypted
         * document the reader unlocked in THIS process is the case that
         * matters, and a document whose pages only render here would otherwise
         * sit behind "Opening…" forever, waiting for a page nobody will ever
         * deliver. One failure and the first frame goes back to rendering on
         * the calling thread, exactly as it did before the bound existed. */
        if (ctx->canvas->frames_built == 0) ctx->canvas->first_frame_budget_ms = 0;
        free(ctx);
        return;
    }
    /* Keyed on what was ACTUALLY rendered, not on what was asked for: the
     * service applies its own byte cap and may have come back at a lower zoom
     * than the request named. */
    key = spdf_win_lru_key(result->spec.page, result->render_zoom, ctx->scale);
    bitmap = (spdf_bitmap*)calloc(1, sizeof(*bitmap));
    if (bitmap) {
        bitmap->width = result->width;
        bitmap->height = result->height;
        bitmap->stride = result->stride;
        bitmap->rgba = result->rgba;
        result->rgba = NULL; /* ownership taken; the service must not free it */
        spdf_win_lru_insert(&ctx->canvas->cache, &key, bitmap,
                            spdf_win_lru_bitmap_bytes(bitmap->width, bitmap->height));
    }
    free(ctx);
}

/* The one call both askers make. Returns non-zero when the pool now owns a
 * render for `key`, whether this call started it or an earlier one did. */
static int request_page(spdf_win_canvas* canvas, int page, double render_zoom, const SpdfWinLruKey* key,
                        int priority) {
    spdf_win_render_spec spec;
    adopt_ctx* ctx;
    unsigned long long token;

    if (inflight_index(canvas, key) >= 0) return 1;
    if (canvas->inflight_count >= SPDF_WIN_CANVAS_MAX_INFLIGHT) return 0;

    ctx = (adopt_ctx*)calloc(1, sizeof(*ctx));
    if (!ctx) return 0;
    ctx->canvas = canvas;
    ctx->scale = canvas->dpi_scale;

    memset(&spec, 0, sizeof(spec));
    spec.page = page;
    spec.zoom = (float)render_zoom;
    spec.flags = canvas->render_flags;
    token = spdf_win_render_request(canvas->service, &spec, priority, adopt_render, ctx);
    if (!token) {
        free(ctx);
        return 0;
    }
    canvas->inflight[canvas->inflight_count].key = *key;
    canvas->inflight[canvas->inflight_count].token = token;
    canvas->inflight_count++;
    return 1;
}

/* Ask the pool for a page that is about to matter. Skipped for anything not
 * yet measured: its size is still page 1's guess, so its render zoom would be
 * a guess too, and a bitmap filed under a guessed key is work thrown away. */
void spdf_win_canvas_prefetch(spdf_win_canvas* canvas, int page) {
    const SpdfWinPageSizePt* size;
    double render_zoom;
    SpdfWinLruKey key;

    if (!canvas->service || page < 0 || page >= canvas->measured) return;
    size = &canvas->sizes[page];
    render_zoom = spdf_win_capped_render_zoom(canvas->zoom, size->width, size->height);
    key = spdf_win_lru_key(page, render_zoom, canvas->dpi_scale);
    if (spdf_win_lru_peek(&canvas->cache, &key)) return;
    (void)request_page(canvas, page, render_zoom, &key, SPDF_WIN_RENDER_NEAR);
}

/* The page under the viewport, at VISIBLE priority so it jumps every queued
 * neighbour (spdf_win_render.h's priority bands). The caller has just missed
 * the cache for this exact key, so there is no peek here. */
int spdf_win_canvas_request_visible(spdf_win_canvas* canvas, int page, double render_zoom) {
    SpdfWinLruKey key;
    if (!canvas->service || page < 0) return 0;
    key = spdf_win_lru_key(page, render_zoom, canvas->dpi_scale);
    return request_page(canvas, page, render_zoom, &key, SPDF_WIN_RENDER_VISIBLE);
}

/* --- the first frame's bound ----------------------------------------------
 *
 * WHY THE FIRST FRAME IS THE ONE THAT NEEDS A BOUND. It is the only frame with
 * nothing to fall back on: no exact bitmap, no stand-in at another zoom, and --
 * on a launch -- no window on screen either, because the launch paints before
 * ShowWindow so the window appears complete rather than blank. Every later
 * frame degrades gracefully; this one does not degrade at all, it just does not
 * return. Measured on this desktop: a page of 400,000 stroked paths held it for
 * 4.5 s and one of 2,000,000 for 35 s, with no window of the app on screen and
 * the process IsHungAppWindow-hung the whole time.
 *
 * So the page is asked of the POOL and waited for, and the wait has an end.
 * Waiting on the UI thread is exactly what spdf_win_canvas_settle() forbids,
 * and for the same reason -- so this is the one place it is allowed and the
 * reason is written down: there is no window yet, so there is no message to
 * pump and nothing this thread could be doing instead; the wait is bounded; and
 * what it buys is that the alternative wait, the unbounded one, never happens.
 *
 * Sleep(1) rounds up to the process's timer resolution, which can be 16 ms.
 * That is slack inside a budget of 250 and it is absorbed entirely by the GPU
 * device prewarm the first compose waits on anyway -- measured 41 ms of it
 * after the first page render ends (windows-native-observations.md sec 18). */

void spdf_win_canvas_set_first_frame_budget(spdf_win_canvas* canvas, int ms) {
    if (!canvas) return;
    canvas->first_frame_budget_ms = ms > 0 ? ms : 0;
    canvas->first_frame_deadline = 0;
}

static const spdf_bitmap* await_first_page(spdf_win_canvas* canvas, int page, double render_zoom,
                                           const SpdfWinLruKey* key, int* deferred) {
    *deferred = 0;
    /* Armed, budgeted, and with a pool to ask: any of the three missing and
     * the caller renders on this thread, which is what the headless paths and
     * a canvas with no path always do. */
    if (!canvas->service || !canvas->async_visible || !canvas->first_frame_budget_ms) return NULL;
    if (!request_page(canvas, page, render_zoom, key, SPDF_WIN_RENDER_VISIBLE)) return NULL;
    *deferred = 1;
    /* ONE deadline for the whole frame, taken on the first wait: two visible
     * pages must share the budget, not have one each. */
    if (!canvas->first_frame_deadline)
        canvas->first_frame_deadline = GetTickCount64() + (unsigned long long)canvas->first_frame_budget_ms;
    for (;;) {
        const void* got;
        spdf_win_render_drain(canvas->service, -1);
        got = spdf_win_lru_lookup(&canvas->cache, key);
        if (!got) {
            /* The pool applies its own byte cap and may come back at a lower
             * zoom than was asked for, which files the bitmap under a
             * different key. Taking it anyway is what keeps a deferred frame
             * from waiting on a key nothing will ever fill; it draws stretched
             * over its slot, like every other stand-in. */
            got = spdf_win_lru_lookup_nearest_zoom(&canvas->cache, page, canvas->dpi_scale, render_zoom, NULL);
            if (got) canvas->stale_draws++;
        }
        if (got) {
            *deferred = 0;
            return (const spdf_bitmap*)got;
        }
        /* adopt_render clears the budget when a render comes back anything but
         * OK. Falling through then puts the page back on this thread rather
         * than leaving the launch behind a status line forever. */
        if (!canvas->first_frame_budget_ms) {
            *deferred = 0;
            return NULL;
        }
        if (GetTickCount64() >= canvas->first_frame_deadline) break;
        Sleep(1);
    }
    /* The message the compose layer draws when a frame has no page draws in
     * it, and the only thing a reader sees of this bound. One word and the
     * ellipsis CHARACTER, which is how both frontends write a status that is
     * still running (SPDFMacPropertiesPanel.mm "Counting…", SPDFUpdater.mm
     * "Preparing update…"); the three-dot form is for a menu item that opens a
     * dialog, which is a different promise. */
    wcscpy_s(canvas->status, sizeof(canvas->status) / sizeof(canvas->status[0]), L"Opening…");
    return NULL;
}

/* --- the T5 seam ----------------------------------------------------------
 *
 * ONE PAGE, ONE FRAME: cache hit, then the stand-in, then the first frame's
 * bound, then a render on this thread. spdf_win_canvas.cpp's header argues the
 * order and the three guards on the async path; this is where the decision is
 * made, next to the pool it is about.
 *
 * The zoom is byte-capped before it reaches the core, so a 10900x7539 pt sheet
 * renders a smaller texture that the compose layer stretches back over its full
 * slot -- geometry never sees the cap, which is what keeps the zoom anchor
 * exact on giant pages. */
const spdf_bitmap* spdf_win_canvas_ensure_page(spdf_win_canvas* canvas, int page) {
    SpdfWinLruKey key;
    const SpdfWinPageSizePt* size = &canvas->sizes[page];
    double render_zoom = spdf_win_capped_render_zoom(canvas->zoom, size->width, size->height);
    spdf_bitmap* bitmap;
    char err[256];

    canvas->page_deferred = 0;
    key = spdf_win_lru_key(page, render_zoom, canvas->dpi_scale);
    bitmap = (spdf_bitmap*)spdf_win_lru_lookup(&canvas->cache, &key);
    if (bitmap) return bitmap;

    /* THE ASYNC PATH, and the stand-in that makes it safe. Both lookups bump
     * recency, so every bitmap this frame points at is among the most recently
     * used and the eviction a later insert triggers cannot take one out from
     * under the scene -- the invariant that made the synchronous path's
     * borrowed pointers safe, unchanged. */
    if (canvas->async_visible && canvas->frames_built > 0) {
        /* The stand-in is looked for FIRST, and the request is only made when
         * one exists. Asking first and then finding nothing to draw would leave
         * a render in flight that this thread is about to duplicate -- two
         * renders of one page, the second one thrown away. */
        bitmap = (spdf_bitmap*)spdf_win_lru_lookup_nearest_zoom(&canvas->cache, page, canvas->dpi_scale, render_zoom,
                                                                NULL);
        if (bitmap && spdf_win_canvas_request_visible(canvas, page, render_zoom)) {
            canvas->stale_draws++;
            return bitmap;
        }
        /* Either the page has never been rendered at any zoom -- a fresh
         * document, a fresh tab -- or the in-flight table is full. Both fall
         * through to the render below, which is slower but never wrong. */
    }

    /* THE FIRST FRAME'S BOUND, and the one case where "slower but never wrong"
     * is not good enough: a launch paints this frame with no window on screen,
     * so its cost is an app that has no window at all. `deferred` means the
     * pool has the page and the budget ran out -- this frame goes up without
     * it, and build_scene drops the draw. */
    if (canvas->first_frame_budget_ms && canvas->frames_built == 0) {
        bitmap = (spdf_bitmap*)await_first_page(canvas, page, render_zoom, &key, &canvas->page_deferred);
        if (bitmap || canvas->page_deferred) return bitmap;
    }

    canvas->sync_renders++;
    bitmap = (spdf_bitmap*)calloc(1, sizeof(*bitmap));
    if (!bitmap) return NULL;
    SPDF_WIN_LAUNCH_MARK_ONCE("first-page-render-begin");
    if (!spdf_render_page_rgba_opts(canvas->doc, page, (float)render_zoom, canvas->render_flags, NULL, bitmap, err,
                                    sizeof(err))) {
        _snwprintf_s(canvas->status, _TRUNCATE, L"Could not render page %d: %hs", page + 1, err);
        free(bitmap);
        return NULL;
    }
    if (spdf_win_launch_enabled()) {
        char tag[64];
        _snprintf_s(tag, sizeof(tag), _TRUNCATE, "first-page-render-end %dx%d", bitmap->width, bitmap->height);
        SPDF_WIN_LAUNCH_MARK_ONCE(tag);
    }
    if (!spdf_win_lru_insert(&canvas->cache, &key, bitmap, spdf_win_lru_bitmap_bytes(bitmap->width, bitmap->height)))
        return NULL; /* insert destroyed it; a placeholder is drawn this frame */
    return bitmap;
}

/* --- the notify hook, and the only canvas code that runs off the UI thread --
 *
 * A worker calls this the moment a result becomes drainable. It must be cheap
 * and thread-safe, so it does exactly one thing: hand the shell's own hook
 * (a PostMessage, in the window) the shell's own context. Nothing of the
 * canvas is read but the two write-once fields and the interlocked word that
 * publishes them, and nothing is written at all.
 *
 * `notify_armed` is the publication barrier. ready_fn/ready_ctx are written by
 * the UI thread BEFORE the interlocked store that arms them and are never
 * rewritten (spdf_win_canvas_set_async_visible refuses to change a hook it
 * already has), so a worker that sees armed != 0 sees both fields whole.
 * Disarming stores 0 and leaves the fields alone, so the racing worker's worst
 * case is one extra call to a hook that is still valid.
 *
 * It fires for a PREFETCH completion too, which the old comment here called
 * pointless -- "a prefetched page is by definition not on screen yet". That is
 * still true, and it is still one InvalidateRect the next paint was going to do
 * anyway; paying it is far cheaper than a second notify path. */
void spdf_win_canvas_render_notify(void* ctx) {
    spdf_win_canvas* canvas = (spdf_win_canvas*)ctx;
    if (!canvas) return;
    if (InterlockedCompareExchange(&canvas->notify_armed, 0, 0) == 0) return;
    if (canvas->ready_fn) canvas->ready_fn(canvas->ready_ctx);
}

void spdf_win_canvas_set_async_visible(spdf_win_canvas* canvas, void (*ready)(void*), void* ready_ctx) {
    if (!canvas) return;
    if (!ready) {
        /* Disarm only. The hook itself is left in place: it is write-once so a
         * worker mid-notify can never see a half-changed pair. */
        InterlockedExchange(&canvas->notify_armed, 0);
        canvas->async_visible = 0;
        return;
    }
    if (!canvas->ready_fn) {
        canvas->ready_fn = ready;
        canvas->ready_ctx = ready_ctx;
    }
    /* A second arming with a DIFFERENT hook is refused rather than honoured:
     * see the notify hook's comment for why the pair has to be write-once. One
     * shell arms one canvas once, and a canvas dies with its tab. */
    if (canvas->ready_fn != ready || canvas->ready_ctx != ready_ctx) return;
    canvas->async_visible = 1;
    InterlockedExchange(&canvas->notify_armed, 1);
}

int spdf_win_canvas_settle(spdf_win_canvas* canvas, int timeout_ms) {
    int adopted = 0;
    int waited = 0;

    if (!canvas || !canvas->service) return 0;
    /* Only the headless probe should call this. A window drains as it paints
     * and never blocks; blocking the UI thread on a prefetch would give back
     * exactly the stall the prefetch exists to remove. */
    while (waited < timeout_ms && spdf_win_render_stat(canvas->service, SPDF_WIN_RENDER_STAT_INFLIGHT) > 0) {
        adopted += spdf_win_render_drain(canvas->service, -1);
        Sleep(2);
        waited += 2;
    }
    return adopted + spdf_win_render_drain(canvas->service, -1);
}

int spdf_win_canvas_sync_renders(const spdf_win_canvas* canvas) { return canvas ? canvas->sync_renders : 0; }

int spdf_win_canvas_stale_draws(const spdf_win_canvas* canvas) { return canvas ? canvas->stale_draws : 0; }

unsigned long long spdf_win_canvas_prefetched(spdf_win_canvas* canvas) {
    return canvas && canvas->service ? spdf_win_render_stat(canvas->service, SPDF_WIN_RENDER_STAT_TASKS_STARTED) : 0;
}
