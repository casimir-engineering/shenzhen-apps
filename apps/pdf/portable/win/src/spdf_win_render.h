/* spdf_win_render.h — background page-render service for the Win32 frontend.
 *
 * Track T5. The pipeline that keeps scrolling smooth: a small worker pool
 * renders pages off the UI thread and hands finished RGBA buffers back, with
 * request coalescing, priority ordering, generation-based invalidation and
 * cooperative cancellation.
 *
 * POLICY, and where each rule comes from (all three frontends must behave the
 * same, so every deviation below is deliberate and named):
 *
 *   - Worker pool sized min(4, max(1, cores/2)), overridable by
 *     SPDF_RENDER_WORKERS and by a per-service ceiling
 *     (spdf_win_render_service_new_ex). Matches portable/linux/gtk4/
 *     spdf_render.c (SPDF_RENDER_MAX_WORKERS) and the macOS _renderQueue,
 *     which caps at 3 because more concurrent renders saturate memory
 *     bandwidth and stall main-thread input even though the work is off-main
 *     (architecture.md §3.3). Threads are spawned LAZILY on the first request:
 *     launching the app must not cost four thread stacks nobody asked for.
 *
 *     THE CEILING IS A TIERING TOOL, not a tuning knob. A process runs more
 *     than one of these pools -- the canvas's, and the minimap thumbnail
 *     store's -- and cores/2 each meant 12 worker threads and 12 MuPDF
 *     documents on a 12-thread box, every one of them started inside the first
 *     paint (windows-launch-performance.md §3.4 measured 23 threads and
 *     0.2-1 s of CPU in the 700 ms after the first page). The pages the reader
 *     is looking at must out-thread the ones they are not, so the pool behind
 *     a background strip asks for a ceiling and the canvas's does not.
 *
 *   - Priority (0 visible, 1 near, 2 warm) then FIFO sequence, exactly the
 *     GTK4 render_task_compare ordering and the macOS
 *     queuePriorityForRenderDistance. The visible page is always rendered
 *     first, at the zoom that is actually on screen.
 *
 *   - Coalescing. A request whose key matches one already pending or running
 *     does not start a second render; it attaches as a waiter, as the macOS
 *     pipeline's _queuedRenderOperations map does. The waiter that arrived
 *     first gets the pixels (SPDF_WIN_RENDER_OK); later waiters are told
 *     SPDF_WIN_RENDER_COALESCED with primary_token naming the one that did,
 *     so nothing is copied and no caller's user_data is silently dropped.
 *
 *   - Generation counters. The caller bumps the generation whenever anything
 *     that invalidates rendered pixels changes -- document reload, zoom
 *     change, and in particular a READING THEME FLIP. Work from an older
 *     generation is canceled and its result discarded rather than adopted;
 *     this is the macOS `generation != self->_renderGeneration` check, moved
 *     to where it cannot be forgotten. See also spdf_win_render_key: the
 *     render flags are part of a page's identity, so a cache keyed on it can
 *     never serve a light-theme bitmap to a dark-theme view.
 *
 *   - Cancellation is cooperative and real. Cancelling sets an atomic abort
 *     flag AND cancels the core's spdf_render_token (an fz_cookie abort that
 *     mupdf polls between display-list nodes), so a superseded render stops
 *     within milliseconds instead of running to completion.
 *
 *   - Delivery. Every request produces EXACTLY ONE done callback, on the
 *     thread that calls spdf_win_render_drain(), including on cancellation,
 *     error and service shutdown -- so per-request user_data always has a
 *     deterministic release point. Workers never call back directly; they
 *     push onto a completion queue and fire the notify hook (typically a
 *     PostMessage). Draining is O(1) per item: adoption on the UI thread must
 *     never do O(n) work (architecture.md §3.6).
 *
 * Deviations from the GTK4 service, and why:
 *
 *   - No bitmap cache lives here. GTK4 folds an LRU of finished textures into
 *     its render service; on Windows that cache is spdf_win_lru (track T3) and
 *     belongs to the view. This file owns scheduling only, which is what makes
 *     it testable against a stub renderer with no MuPDF and no window.
 *
 *   - Worker documents are keyed on path alone, not on (path, mtime, size).
 *     GTK4 stats the file on every render to notice an external rewrite; on
 *     Windows the frontend learns that from ReadDirectoryChangesW instead, so
 *     the per-render syscall buys nothing. Re-opening after such a rewrite is
 *     not wired up here yet -- it belongs with the file watcher.
 */
#ifndef SPDF_WIN_RENDER_H
#define SPDF_WIN_RENDER_H

#include <math.h>
#include <stddef.h>

#include "shenzhen_pdf_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* A single decoded page bitmap never exceeds this, and the render zoom is
 * reduced until it does not. Same 96 MB figure as the mac and GTK4 pipelines
 * (SPDF_MAX_RENDER_SURFACE_BYTES). The view stretches the smaller bitmap back
 * over the uncapped slot, so layout geometry never sees the cap. */
#define SPDF_WIN_RENDER_MAX_BYTES ((size_t)96 * 1024 * 1024)

/* Cache-key zoom quantization: 1/4096 of a device pixel per point is far below
 * any visible difference and makes float zooms comparable exactly. */
#define SPDF_WIN_RENDER_ZOOM_QUANTUM 4096.0

/* Hard ceiling on workers, and on how many requests may coalesce onto one
 * render before an extra one is simply queued separately. */
#define SPDF_WIN_RENDER_MAX_WORKERS 4
#define SPDF_WIN_RENDER_MAX_WAITERS 16

enum spdf_win_render_priority {
    SPDF_WIN_RENDER_VISIBLE = 0,
    SPDF_WIN_RENDER_NEAR = 1,
    SPDF_WIN_RENDER_WARM = 2
};

enum spdf_win_render_status {
    SPDF_WIN_RENDER_OK = 0,
    SPDF_WIN_RENDER_CANCELED = 1,   /* the caller cancelled this token */
    SPDF_WIN_RENDER_SUPERSEDED = 2, /* the generation moved on; result discarded */
    SPDF_WIN_RENDER_COALESCED = 3,  /* an earlier token got these pixels */
    SPDF_WIN_RENDER_ERROR = 4,      /* err[] says why */
    SPDF_WIN_RENDER_SHUTDOWN = 5    /* the service was freed with work in flight */
};

/* What to render, and the epoch it belongs to. `flags` are the core's
 * SPDF_RENDER_* bits -- notably SPDF_RENDER_DARK_THEME and
 * SPDF_RENDER_PRESERVE_IMAGES -- and they travel all the way back out on the
 * result, so a consumer can never mistake a light-theme bitmap for a dark one. */
typedef struct spdf_win_render_spec {
    int page;
    float zoom;                    /* device px per PDF point, DPI scale included */
    unsigned flags;                /* SPDF_RENDER_* */
    unsigned long long generation; /* 0 means "use the service's current generation" */
} spdf_win_render_spec;

/* The identity of a rendered page. Page, quantized zoom and render flags --
 * the flags are what make a theme flip invalidate cached pixels rather than
 * showing stale ones. T3's LRU should key on exactly this. */
typedef struct spdf_win_render_key {
    int page;
    long long zoom_q;
    unsigned flags;
} spdf_win_render_key;

/* Header-only like the GTK4 layout header's 83 inline helpers, so a test can
 * assert on identity and the byte cap without linking the pool. */
static inline spdf_win_render_key spdf_win_render_key_for(const spdf_win_render_spec* spec) {
    spdf_win_render_key key;
    key.page = spec ? spec->page : 0;
    key.zoom_q = spec ? (long long)llround((double)spec->zoom * SPDF_WIN_RENDER_ZOOM_QUANTUM) : 0;
    key.flags = spec ? spec->flags : 0u;
    return key;
}

static inline int spdf_win_render_key_equal(const spdf_win_render_key* a, const spdf_win_render_key* b) {
    return a && b && a->page == b->page && a->zoom_q == b->zoom_q && a->flags == b->flags;
}

static inline unsigned spdf_win_render_key_hash(const spdf_win_render_key* key) {
    unsigned h;
    if (!key) return 0u;
    h = (unsigned)key->page * 2654435761u;
    h ^= (unsigned)((unsigned long long)key->zoom_q ^ ((unsigned long long)key->zoom_q >> 32)) * 40503u;
    return h ^ key->flags * 2246822519u;
}

/* Reduce a render zoom so width*height*zoom^2*4 stays under max_bytes.
 * Identical formula to spdf_capped_render_zoom_for_cap in the GTK4 layout
 * header, duplicated so this file has no dependency on track T3. */
static inline double spdf_win_render_capped_zoom(double zoom, double page_width, double page_height,
                                                 size_t max_bytes) {
    double bytes;
    if (zoom <= 0.0 || page_width <= 0.0 || page_height <= 0.0 || max_bytes == 0) return zoom;
    bytes = page_width * page_height * zoom * zoom * 4.0;
    if (bytes <= (double)max_bytes) return zoom;
    return zoom * sqrt((double)max_bytes / bytes);
}

typedef struct spdf_win_render_result {
    unsigned long long token;
    unsigned long long primary_token; /* set when status == SPDF_WIN_RENDER_COALESCED */
    spdf_win_render_spec spec;        /* exactly what was asked for, flags included */
    int status;                       /* enum spdf_win_render_status */
    int width;
    int height;
    int stride;
    unsigned char* rgba;   /* NULL unless status == SPDF_WIN_RENDER_OK */
    float render_zoom;     /* what was actually rendered at; <= spec.zoom after the byte cap */
    char err[256];
} spdf_win_render_result;

/* Called once per request from spdf_win_render_drain(). Take ownership of the
 * pixels by stealing result->rgba and setting it to NULL; anything left behind
 * is freed by the service when the callback returns. */
typedef void (*spdf_win_render_done)(spdf_win_render_result* result, void* user_data);

/* Fired on a WORKER thread the moment a result becomes drainable. Must be
 * cheap and thread-safe -- PostMessage(hwnd, WM_APP_RENDER_READY, 0, 0) is the
 * intended implementation. */
typedef void (*spdf_win_render_notify)(void* ctx);

/* Handed to the backend so a long render can notice it has been superseded.
 * Poll it in any loop that can run for more than a few milliseconds. */
typedef struct spdf_win_render_abort {
    spdf_render_token* token; /* the core's fz_cookie abort; may be NULL */
    volatile long* flag;      /* set to 1 on cancel/supersede/shutdown */
} spdf_win_render_abort;

int spdf_win_render_aborted(const spdf_win_render_abort* abort);

/* THE INJECTABLE SEAM. The default backend calls the core
 * (spdf_render_page_rgba_opts) against a per-worker-thread spdf_document,
 * honouring the core's one-document-per-thread contract. Tests replace it with
 * a stub, which is what makes the queue policy verifiable with no MuPDF, no
 * document and no window. Both hooks run on a worker thread. */
typedef struct spdf_win_render_backend {
    void* ctx;
    /* Page size in PDF points. Return 1 on success, 0 with err filled. */
    int (*page_size)(void* ctx, const char* path, int page, float* width, float* height, char* err, size_t err_len);
    /* Render at `zoom`, already byte-capped. Return 1 on success. Return 0
     * with err set to "Render canceled." when the abort was observed. */
    int (*render)(void* ctx, const char* path, int page, float zoom, unsigned flags,
                  const spdf_win_render_abort* abort, spdf_bitmap* out, char* err, size_t err_len);
    /* Optional: release this thread's cached state before the worker exits. */
    void (*thread_exit)(void* ctx);
} spdf_win_render_backend;

const spdf_win_render_backend* spdf_win_render_core_backend(void);

typedef struct spdf_win_render_service spdf_win_render_service;

/* `backend` NULL means the core backend; the struct and `path` are copied.
 * `max_bytes` 0 means SPDF_WIN_RENDER_MAX_BYTES. `notify` may be NULL. All of
 * it is immutable afterwards, so the worker reads it without taking the lock.
 * No threads are started until the first request. */
spdf_win_render_service* spdf_win_render_service_new(const char* path, const spdf_win_render_backend* backend,
                                                     size_t max_bytes, spdf_win_render_notify notify, void* ctx);
/* The same, plus a CEILING on the worker count for this service: `max_workers`
 * of 0 means the policy default (cores/2, capped at
 * SPDF_WIN_RENDER_MAX_WORKERS), and anything smaller than the default wins.
 * A larger value does not raise the default -- the cap is a cap. Read the
 * tiering note in the policy section above before passing one. */
spdf_win_render_service* spdf_win_render_service_new_ex(const char* path, const spdf_win_render_backend* backend,
                                                        size_t max_bytes, spdf_win_render_notify notify, void* ctx,
                                                        int max_workers);
/* Cancels everything in flight, waits for the workers -- for a bounded time,
 * because the caller is the UI thread -- then delivers every outstanding
 * request with SPDF_WIN_RENDER_SHUTDOWN on the calling thread so user_data is
 * released. A worker still inside a render past that bound is left to finish
 * on its own and the service outlives this call until it does; that one
 * request's user_data is then never delivered. Safe with NULL. */
void spdf_win_render_service_free(spdf_win_render_service* svc);

/* Bump on anything that invalidates rendered pixels -- reload, zoom change,
 * and above all a reading-theme flip. Everything from an older generation is
 * cancelled and will be delivered SPDF_WIN_RENDER_SUPERSEDED. Returns the new
 * generation. */
unsigned long long spdf_win_render_service_bump_generation(spdf_win_render_service* svc);

/* Returns the assigned token, or 0 if the request could not be accepted.
 * `priority` is clamped into [VISIBLE, WARM]. */
unsigned long long spdf_win_render_request(spdf_win_render_service* svc, const spdf_win_render_spec* spec,
                                           int priority, spdf_win_render_done done, void* user_data);
/* Cancels one request. To cancel everything -- a theme flip, a reload, a tab
 * switch -- bump the generation instead: it stops in-flight work AND makes
 * every result that was already produced under the old epoch unadoptable. */
void spdf_win_render_cancel(spdf_win_render_service* svc, unsigned long long token);

/* UI thread. Delivers up to max_items completions (<= 0 means all currently
 * available) and returns how many were delivered. */
int spdf_win_render_drain(spdf_win_render_service* svc, int max_items);

/* Diagnostic counters, one entry point so the lock is taken once per query.
 * TASKS_STARTED counts tasks the pool dequeued, not requests accepted -- the
 * gap between the two is exactly what coalescing saved. */
enum spdf_win_render_stat_id {
    SPDF_WIN_RENDER_STAT_INFLIGHT = 0, /* requests accepted but not yet delivered */
    SPDF_WIN_RENDER_STAT_WORKERS = 2,
    SPDF_WIN_RENDER_STAT_TASKS_STARTED = 3,
    SPDF_WIN_RENDER_STAT_GENERATION = 4
};
unsigned long long spdf_win_render_stat(spdf_win_render_service* svc, int which);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_RENDER_H */
