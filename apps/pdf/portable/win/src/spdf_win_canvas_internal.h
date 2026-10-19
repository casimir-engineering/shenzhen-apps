/* The canvas's private state, shared by exactly five translation units.
 *
 * It exists because spdf_win_canvas.cpp reached the repo's 500-line cap and the
 * rule is extraction over cap bumps (tools/file-size-limits.md). Every seam is
 * the honest one: spdf_win_canvas.cpp is geometry and composition -- what is
 * where, at what zoom -- spdf_win_canvas_prefetch.cpp is everything to do with
 * T5's worker pool -- up to and including which bitmap this frame draws a page
 * with (spdf_win_canvas_ensure_page) -- spdf_win_canvas_selection.cpp is the
 * pointer gesture that turns those two into a text selection and a followed link,
 * spdf_win_find_canvas.cpp is the navigation surface the search & map track
 * drives -- scroll to a match, read a page's slot, re-measure a rotated page --
 * and spdf_win_canvas_swap.cpp is the one operation that changes the DOCUMENT
 * under a live viewport (a Markdown file re-read after it changed on disk).
 * Nothing outside those five files may include this header; spdf_win_canvas.h
 * is the public surface. (spdf_win_canvas_scrollbar.h is part of
 * spdf_win_canvas.cpp's own translation unit, not a sixth file.)
 */
#ifndef SPDF_WIN_CANVAS_INTERNAL_H
#define SPDF_WIN_CANVAS_INTERNAL_H

#include "spdf_win_canvas.h"
#include "spdf_win_layout.h"
#include "spdf_win_links.h"
#include "spdf_win_lru.h"
#include "spdf_win_render.h"
#include "spdf_win_selection.h"


#include <windows.h> /* Sleep, for the headless settle only */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* How many renders the canvas will track as outstanding at once. A viewport
 * shows one or two pages at a readable zoom and up to a dozen at 10%, plus the
 * two neighbours; 32 covers that with room to spare, and overflow degrades to a
 * synchronous render rather than to a duplicate task. */
#define SPDF_WIN_CANVAS_MAX_INFLIGHT 32

struct spdf_win_canvas {
    spdf_document* doc; /* borrowed at create(); the adopted one after a replace */
    /* A document handed over by spdf_win_canvas_replace_document(), which the
     * canvas OWNS: closed on the next replace and on destroy. NULL while the
     * canvas still shows the document it was created over, which stays the
     * caller's -- the two ownerships never mix (spdf_win_canvas_swap.cpp). */
    spdf_document* owned_doc;
    /* The document's UTF-8 path, copied; NULL when the caller gave none. The
     * render workers get it at construction; the links cache gets it lazily,
     * so its text-URL thread can open a handle of its own. */
    char* path;
    unsigned render_flags;
    int page_count;

    /* Page sizes in PDF points. Pages [0, measured) have been asked of the
     * core; the rest hold page 1's size as an estimate. Launching measures
     * exactly ONE page, because a 500-page document would otherwise pay 500
     * fz_load_page calls before the first pixel appears, and launch time is
     * the product's headline promise. The estimate only ever affects the
     * total scroll height below the viewport; everything at or above the
     * viewport is exact, because build_scene() measures forward until the
     * visible range stops moving. */
    SpdfWinPageSizePt* sizes;
    int measured;

    SpdfWinLayout layout;
    double zoom;
    spdf_win_zoom_mode mode;
    double scroll_x;
    double scroll_y;

    unsigned vp_w;
    unsigned vp_h;
    double dpi_scale;

    SpdfWinLru cache; /* SpdfWinLruKey -> spdf_bitmap*, owned */

    /* T5's worker pool: neighbour prefetch always, and the VISIBLE page too
     * once a shell has armed spdf_win_canvas_set_async_visible(). What the
     * pool buys for the neighbours is the page you are about to scroll onto
     * being ready before you get there; what it buys for the visible page is
     * that a zoom or a jump does not stop the UI thread for the length of a
     * MuPDF render. Async is off until armed, and never applies to the FIRST
     * frame -- see spdf_win_canvas.cpp's header for both reasons.
     *
     * Every touch of `cache` stays on one thread: requests are made from
     * build_scene, and results are adopted in spdf_win_render_drain(), which
     * runs on whichever thread calls it -- the same one. The LRU needs no lock
     * because it never sees a second thread. */
    spdf_win_render_service* service;
    int sync_renders; /* synchronous renders during the last build_scene */
    int stale_draws;  /* pages drawn from a lower/higher-zoom stand-in */
    int async_visible;
    unsigned long long frames_built;
    /* Written once, before async is first armed, and read from a WORKER thread
     * through the notify trampoline; `notify_armed` is the interlocked word
     * that publishes them. See spdf_win_canvas_prefetch.cpp. */
    void (*ready_fn)(void*);
    void* ready_ctx;
    volatile long notify_armed;

    /* THE FIRST FRAME'S BOUND (spdf_win_canvas.h, set_first_frame_budget).
     * `first_frame_budget_ms` is the launch's ask and 0 everywhere else;
     * `first_frame_deadline` is the GetTickCount64 it turns into on the first
     * wait, so two visible pages share ONE budget rather than one each.
     * `page_deferred` is the last ensure_page's answer: the pool owns this
     * page and the frame must leave it out. All three are prefetch.cpp's. */
    int first_frame_budget_ms;
    unsigned long long first_frame_deadline;
    int page_deferred;

    /* WHAT IS ALREADY ON ITS WAY, so a repaint at 60 Hz does not ask sixty
     * times for one render. The service coalesces identical requests, but only
     * up to SPDF_WIN_RENDER_MAX_WAITERS of them; past that it starts a SECOND
     * render of the same page, and a 300 ms page under a continuous scroll
     * would queue a dozen duplicates. A fixed table, so nothing allocates on
     * the paint path; when it is full the caller falls back to rendering on
     * this thread, which is slow but never wrong. */
    struct spdf_win_canvas_inflight {
        SpdfWinLruKey key;
        unsigned long long token;
    } inflight[SPDF_WIN_CANVAS_MAX_INFLIGHT];
    int inflight_count;

    /* Scratch for build_scene's page list, grown and reused rather than
     * reallocated per frame: a malloc on every paint is a malloc on the scroll
     * hot path. */
    spdf_win_page_draw* draws;
    int draws_cap;
    int draws_count;

    wchar_t status[256];

    /* --- selection and links, all of it owned by spdf_win_canvas_selection.cpp
     *
     * Allocated LAZILY on the first pointer event, so a document nobody clicks
     * on costs two null pointers and no allocation -- the same rule the find
     * session states for a document nobody searches.
     *
     * They live on the CANVAS rather than beside the window because a selection
     * belongs to a document view: it survives a scroll, a zoom and a repaint,
     * it dies with the document, and it needs exactly the geometry this struct
     * already holds. Per-tab lifetime then comes for free, since a tab owns a
     * canvas. `doc` is the UI thread's handle, which is what makes the core
     * calls below legal on the UI thread (shenzhen_pdf_core.c:40-43). */
    spdf_win_selection* selection;
    spdf_win_links* links;
    /* Where the last press landed, in page space, so the release can resolve
     * the link it was over without re-hit-testing a pointer that has moved. */
    int press_page;
    float press_page_x;
    float press_page_y;
    /* Owned by the canvas and freed before it is overwritten: spdf_link_target
     * carries a malloc'd uri for external links. */
    spdf_link_target nav;
    int nav_valid;
};

/* spdf_win_canvas_prefetch.cpp -- everything that talks to another thread.
 * `prefetch` is the NEAR-priority neighbour ask (skipped for an unmeasured
 * page); `request_visible` is the VISIBLE-priority ask for a page that is on
 * screen right now, and returns non-zero when the pool took it. `render_notify`
 * is the service's notify hook: it runs on a WORKER thread. */
void spdf_win_canvas_prefetch(spdf_win_canvas* canvas, int page);
int spdf_win_canvas_request_visible(spdf_win_canvas* canvas, int page, double render_zoom);
void spdf_win_canvas_render_notify(void* ctx);

/* THE T5 SEAM, for build_scene: the bitmap to draw page `page` with this frame,
 * from the cache, from the pool, or rendered here. NULL means there is nothing
 * to draw -- with `canvas->page_deferred` set the page is merely still
 * rendering and the frame must leave it out; without it the page failed and the
 * compose layer's placeholder is the honest answer. */
const spdf_bitmap* spdf_win_canvas_ensure_page(spdf_win_canvas* canvas, int page);

/* spdf_win_canvas.cpp, for the other three units. Measures pages up to and
 * including `through`, returning non-zero when the layout went stale; and the
 * relayout that re-derives the fit zoom and rebuilds every slot. Neither is
 * public: a caller outside the canvas cannot know when a measure is due. */
int spdf_win_canvas_ensure_measured(spdf_win_canvas* canvas, int through);
void spdf_win_canvas_relayout(spdf_win_canvas* canvas);

/* spdf_win_canvas_selection.cpp. Called from spdf_win_canvas_destroy() while
 * the canvas is still whole, for the same reason the render service is torn
 * down there rather than by whoever created it. */
void spdf_win_canvas_selection_teardown(spdf_win_canvas* canvas);

#endif /* SPDF_WIN_CANVAS_INTERNAL_H */
