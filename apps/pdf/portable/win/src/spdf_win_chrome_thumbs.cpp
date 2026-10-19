/* The minimap thumbnail store. See spdf_win_chrome_thumbs.h for the policy and
 * for why none of this may run on the paint path or the launch path. */
#include "spdf_win_chrome_thumbs.h"
#include "spdf_win_open.h" /* the process opener: spdf_open, or Markdown-aware once main() says so */

#include "spdf_win_lru.h"
#include "spdf_win_launch_profile.h" /* SPDF-LAUNCH markers; free when unset */
#include "spdf_win_minimap.h"
#include "spdf_win_render.h"

#include <process.h>
#include <stdlib.h>
#include <string.h>

namespace {

struct Thumb {
    int width;
    int height;
    int stride;
    unsigned revision;
    unsigned char* rgba;
};

void thumb_destroy(void* value) {
    Thumb* t = (Thumb*)value;
    if (!t) return;
    free(t->rgba);
    free(t);
}

/* One in-flight render. The store keeps a small fixed table rather than a list:
 * the thumb window bounds how many pages can be pending, so a table sized to it
 * cannot overflow in practice and cannot allocate on the paint path. */
struct Pending {
    unsigned long long token;
    int page;
};

const int kMaxPending = 24;

/* TIER 2: the strip is not what the reader is reading.
 *
 * This pool and the canvas's are both spdf_win_render services, and both used
 * to size themselves at cores/2 -- 6 each on this box, so 12 worker threads and
 * 12 MuPDF documents, all of them started inside the first paint. That is what
 * windows-launch-performance.md §3.4 measured as 23 threads and 0.2-1 s of CPU
 * in the 700 ms after the first page: not a UI-thread stall, but fan noise and
 * memory bandwidth competing with the first scroll's render of the next page,
 * which is the one render the reader is actually waiting on.
 *
 * Two, because a thumbnail is WARM work by construction (spdf_win_render.h's
 * priority bands) and the bounded thumb window only ever asks for ~15 pages:
 * two workers keep the strip filling visibly while leaving the machine to the
 * page. §5 item 3's "give it 2 workers rather than cores/2", from the file that
 * measured the cost. */
const int kThumbWorkers = 2;
const int kSizeSweepChunk = 32;

} /* namespace */

struct SpdfWinThumbStore {
    char* path;

    /* Page geometry. `sizes` is grown once, `measured` is published by the
     * sizing thread with an interlocked store and read without a lock: an int
     * read is atomic on x86/x64/ARM64 and a stale-by-one read only means one
     * page keeps the fallback size for one more frame. */
    spdf_document* size_doc;
    HANDLE size_thread;
    SpdfWinPageSizePt* sizes;
    volatile long measured;
    int page_count;
    int counted;
    volatile long stop;

    /* Thumbnails. */
    SpdfWinLru cache;
    int cache_ready;
    spdf_win_render_service* svc;
    int svc_dark;
    unsigned revision;
    unsigned long long ready;
    SpdfWinMinimapThumbWindow window;
    Pending pending[kMaxPending];
    int pending_count;

    /* Repaint side channel; see the header. */
    HWND windows[8];
    int window_count;
    int noted_paint_thread;
    CRITICAL_SECTION lock;

    /* Who still holds the store: its owner, and the sizing sweep while it
     * runs. The last one out frees it (store_release), so freeing the store
     * never waits for the sweep. */
    volatile long refs;
};

/* --- the sizing sweep ---------------------------------------------------- */

static void store_release(SpdfWinThumbStore* s);

static unsigned __stdcall size_sweep(void* arg) {
    SpdfWinThumbStore* s = (SpdfWinThumbStore*)arg;
    char err[256] = {0};
    spdf_document* doc;
    int i;

    spdf_win_launch_mark("thumbs-sweep-begin");
    doc = spdf_win_open_document(s->path, err, sizeof(err));
    if (!doc) return 0;
    for (i = 0; i < s->page_count; ++i) {
        float w = 0.0f, h = 0.0f;
        if (InterlockedCompareExchange(&s->stop, 0, 0) != 0) break;
        if (spdf_page_size(doc, i, &w, &h, err, sizeof(err)) && w > 0.0f && h > 0.0f) {
            s->sizes[i].width = (double)w;
            s->sizes[i].height = (double)h;
        } else if (i > 0) {
            s->sizes[i] = s->sizes[0];
        }
        /* Publish in chunks: one invalidate per page on a 500-page document
         * would be 500 repaints for a strip that does not visibly change. */
        InterlockedExchange(&s->measured, (long)(i + 1));
        if ((i + 1) % kSizeSweepChunk == 0 || i + 1 == s->page_count) {
            int k;
            EnterCriticalSection(&s->lock);
            for (k = 0; k < s->window_count; ++k) InvalidateRect(s->windows[k], NULL, FALSE);
            LeaveCriticalSection(&s->lock);
        }
    }
    spdf_close(doc);
    spdf_win_launch_mark_n("thumbs-sweep-end", s->page_count);
    store_release(s); /* the owner may already be gone: see spdf_win_thumbs_free */
    return 0;
}

/* Opens the store's own document handle (the core allows one per thread, so it
 * cannot borrow the app's) and starts the sizing sweep. Called from the first
 * page_count/page_sizes query, i.e. from the first minimap paint -- never from
 * launch. */
static void ensure_pages(SpdfWinThumbStore* s) {
    char err[256] = {0};
    int i;

    if (!s || s->counted) return;
    s->counted = 1;
    spdf_win_launch_mark("thumbs-open-begin");
    s->size_doc = spdf_win_open_document(s->path, err, sizeof(err));
    spdf_win_launch_mark("thumbs-doc-opened");
    if (!s->size_doc) return;
    s->page_count = spdf_page_count(s->size_doc);
    if (s->page_count <= 0) return;
    s->sizes = (SpdfWinPageSizePt*)calloc((size_t)s->page_count, sizeof(SpdfWinPageSizePt));
    if (!s->sizes) {
        s->page_count = 0;
        return;
    }
    /* Page 0 synchronously: it is the one size the canvas has already paid for,
     * and it is what every unmeasured page borrows. */
    {
        float w = 0.0f, h = 0.0f;
        if (spdf_page_size(s->size_doc, 0, &w, &h, err, sizeof(err)) && w > 0.0f && h > 0.0f) {
            s->sizes[0].width = (double)w;
            s->sizes[0].height = (double)h;
        } else {
            s->sizes[0].width = 612.0;
            s->sizes[0].height = 792.0;
        }
    }
    for (i = 1; i < s->page_count; ++i) s->sizes[i] = s->sizes[0];
    InterlockedExchange(&s->measured, 1);
    /* The app's own handle is not needed after page 0; the sweep opens its own.
     * Closing it here keeps exactly one extra document handle alive rather than
     * two. */
    spdf_close(s->size_doc);
    s->size_doc = NULL;
    if (s->page_count > 1) {
        /* The sweep's hold, taken BEFORE the thread exists so it can never
         * observe a count it has not been given. */
        InterlockedIncrement(&s->refs);
        s->size_thread = (HANDLE)_beginthreadex(NULL, 0, size_sweep, s, 0, NULL);
        if (!s->size_thread) InterlockedDecrement(&s->refs);
    }
}

/* --- construction -------------------------------------------------------- */

SpdfWinThumbStore* spdf_win_thumbs_new(const char* utf8_path) {
    SpdfWinThumbStore* s;
    size_t n;

    if (!utf8_path || !*utf8_path) return NULL;
    s = (SpdfWinThumbStore*)calloc(1, sizeof(*s));
    if (!s) return NULL;
    n = strlen(utf8_path) + 1;
    s->path = (char*)malloc(n);
    if (!s->path) {
        free(s);
        return NULL;
    }
    memcpy(s->path, utf8_path, n);
    s->window = spdf_win_minimap_thumb_window_empty();
    s->svc_dark = -1;
    s->refs = 1;
    InitializeCriticalSection(&s->lock);
    return s;
}

/* The last holder out frees the store: the owner from spdf_win_thumbs_free(),
 * or the sizing sweep when it finds the owner already gone. */
static void store_release(SpdfWinThumbStore* s) {
    if (InterlockedDecrement(&s->refs) != 0) return;
    if (s->size_doc) spdf_close(s->size_doc);
    if (s->cache_ready) spdf_win_lru_deinit(&s->cache);
    free(s->sizes);
    free(s->path);
    DeleteCriticalSection(&s->lock);
    free(s);
}

void spdf_win_thumbs_free(SpdfWinThumbStore* s) {
    if (!s) return;
    InterlockedExchange(&s->stop, 1);
    if (s->svc) spdf_win_render_service_free(s->svc);
    if (s->size_thread) {
        /* NO WAIT. The sweep checks `stop` between pages, but its first step
         * is its own open of the document, and on a large file that alone is
         * seconds -- which this used to spend blocked on the UI thread, up to
         * a five-second cap, with the window answering nothing. The sweep
         * holds its own reference and lets go when it ends (store_release);
         * the handle is closed, the thread is not waited for. */
        CloseHandle(s->size_thread);
        s->size_thread = NULL;
    }
    store_release(s);
}

int spdf_win_thumbs_page_count(SpdfWinThumbStore* s) {
    if (!s) return 0;
    ensure_pages(s);
    return s->page_count;
}

int spdf_win_thumbs_page_sizes(SpdfWinThumbStore* s, SpdfWinPageSizePt* out, int count) {
    int i, measured;
    if (!s || !out || count <= 0) return 0;
    ensure_pages(s);
    measured = (int)InterlockedCompareExchange(&s->measured, 0, 0);
    for (i = 0; i < count; ++i) {
        if (s->sizes && i < s->page_count) {
            out[i] = s->sizes[i];
        } else {
            out[i].width = 612.0;
            out[i].height = 792.0;
        }
    }
    return measured;
}

/* --- the repaint side channel ------------------------------------------- */

static BOOL CALLBACK collect_window(HWND hwnd, LPARAM param) {
    SpdfWinThumbStore* s = (SpdfWinThumbStore*)param;
    if (s->window_count < (int)(sizeof(s->windows) / sizeof(s->windows[0]))) s->windows[s->window_count++] = hwnd;
    return TRUE;
}

void spdf_win_thumbs_note_paint_thread(SpdfWinThumbStore* s) {
    if (!s || s->noted_paint_thread) return;
    s->noted_paint_thread = 1;
    EnterCriticalSection(&s->lock);
    EnumThreadWindows(GetCurrentThreadId(), collect_window, (LPARAM)s);
    LeaveCriticalSection(&s->lock);
}

static void invalidate(SpdfWinThumbStore* s) {
    int i;
    EnterCriticalSection(&s->lock);
    for (i = 0; i < s->window_count; ++i) InvalidateRect(s->windows[i], NULL, FALSE);
    LeaveCriticalSection(&s->lock);
}

static void thumb_notify(void* ctx) {
    invalidate((SpdfWinThumbStore*)ctx);
}

/* --- rendering ---------------------------------------------------------- */

static void drop_pending(SpdfWinThumbStore* s, unsigned long long token) {
    int i;
    for (i = 0; i < s->pending_count; ++i) {
        if (s->pending[i].token != token) continue;
        s->pending[i] = s->pending[s->pending_count - 1];
        --s->pending_count;
        return;
    }
}

static int is_pending(const SpdfWinThumbStore* s, int page) {
    int i;
    for (i = 0; i < s->pending_count; ++i)
        if (s->pending[i].page == page) return 1;
    return 0;
}

static SpdfWinLruKey thumb_key(int page) {
    /* The store holds one thumbnail per page and drops everything when the
     * theme flips, so page alone identifies an entry. The zoom/scale fields are
     * pinned at 1 so the key is stable across a panel resize -- a re-rendered
     * thumbnail replaces the old one by page, which is what keeps the strip
     * from holding two sizes of the same picture. */
    return spdf_win_lru_key(page, 1.0, 1.0);
}

static void thumb_done(spdf_win_render_result* r, void* user) {
    SpdfWinThumbStore* s = (SpdfWinThumbStore*)user;
    SpdfWinLruKey key;
    Thumb* t;

    drop_pending(s, r->token);
    if (r->status != SPDF_WIN_RENDER_OK || !r->rgba || r->width <= 0 || r->height <= 0) return;
    t = (Thumb*)calloc(1, sizeof(*t));
    if (!t) return;
    t->width = r->width;
    t->height = r->height;
    t->stride = r->stride;
    t->revision = ++s->revision;
    t->rgba = r->rgba;
    r->rgba = NULL; /* the store owns the pixels now */
    key = thumb_key(r->spec.page);
    if (!spdf_win_lru_insert(&s->cache, &key, t, spdf_win_lru_bitmap_bytes(t->width, t->height))) {
        thumb_destroy(t);
        return;
    }
    ++s->ready;
    SPDF_WIN_LAUNCH_MARK_ONCE("first-thumbnail-adopted");
}

int spdf_win_thumbs_drain(SpdfWinThumbStore* s) {
    if (!s || !s->svc) return 0;
    return spdf_win_render_drain(s->svc, 0);
}

int spdf_win_thumbs_lookup(SpdfWinThumbStore* s, int page, SpdfWinMinimapThumb* out) {
    SpdfWinLruKey key;
    Thumb* t;
    if (!s || !s->cache_ready || !out) return 0;
    key = thumb_key(page);
    t = (Thumb*)spdf_win_lru_lookup(&s->cache, &key);
    if (!t || !t->rgba) return 0;
    out->width = t->width;
    out->height = t->height;
    out->stride = t->stride;
    out->rgba = t->rgba;
    out->revision = t->revision;
    return 1;
}

/* Queue one page if it has neither pixels nor a render in flight. */
static void queue_page(SpdfWinThumbStore* s, const SpdfWinPageSizePt* sizes, int count, int page, double panel_w,
                       double side_inset, int dark) {
    SpdfWinMinimapThumb probe;
    spdf_win_render_spec spec;
    unsigned long long token;
    double zoom;

    if (page < 0 || page >= count) return;
    if (s->pending_count >= kMaxPending) return;
    if (spdf_win_thumbs_lookup(s, page, &probe)) return;
    if (is_pending(s, page)) return;
    zoom = spdf_win_minimap_thumb_zoom(sizes, count, page, panel_w, side_inset);
    if (!(zoom > 0.0)) return;
    spec.page = page;
    spec.zoom = (float)zoom;
    spec.flags = dark ? (unsigned)SPDF_RENDER_DARK_THEME : 0u;
    spec.generation = 0;
    token = spdf_win_render_request(s->svc, &spec, SPDF_WIN_RENDER_WARM, thumb_done, s);
    if (!token) return;
    s->pending[s->pending_count].token = token;
    s->pending[s->pending_count].page = page;
    ++s->pending_count;
}

void spdf_win_thumbs_request(SpdfWinThumbStore* s, const SpdfWinPageSizePt* sizes, int count, int first, int last,
                             double panel_w, double side_inset, int dark) {
    int page;

    if (!s || !sizes || count <= 0) return;
    if (!s->cache_ready) {
        spdf_win_lru_init(&s->cache, SPDF_WIN_MINIMAP_THUMB_MAX_BYTES, thumb_destroy);
        s->cache_ready = 1;
    }
    if (s->svc_dark != (dark ? 1 : 0)) {
        /* A theme flip invalidates every thumbnail. Bumping the generation stops
         * the work in flight AND makes anything already produced unadoptable,
         * which is the rule spdf_win_render.h states for exactly this case. */
        if (s->svc) spdf_win_render_service_bump_generation(s->svc);
        spdf_win_lru_remove_all(&s->cache);
        s->pending_count = 0;
        s->svc_dark = dark ? 1 : 0;
    }
    if (!s->svc) {
        s->svc = spdf_win_render_service_new_ex(s->path, NULL, 0, thumb_notify, s, kThumbWorkers);
        if (!s->svc) return;
        spdf_win_launch_mark("thumbs-service-created");
    }

    {
        SpdfWinMinimapThumbWindow before = s->window;
        s->window = spdf_win_minimap_thumb_window_for_visible_range(count, first, last, s->window);
        if (!spdf_win_minimap_thumb_window_valid(s->window)) return;
        /* Evict only when the window actually moved: the hysteresis makes that
         * rare, and scanning every page on every frame would put O(pages) work
         * on the paint path for a store that is already byte-capped. */
        if (before.start != s->window.start || before.end != s->window.end) {
            for (page = 0; page < count; ++page) {
                SpdfWinLruKey key;
                if (!spdf_win_minimap_thumb_window_should_evict(s->window, page)) continue;
                key = thumb_key(page);
                spdf_win_lru_remove(&s->cache, &key);
            }
        }
    }

    /* Two passes so what the reader can SEE is queued first: the pool is FIFO
     * within a priority and every thumbnail is WARM, so queue order is the only
     * lever. Only pages inside the bounded window are ever queued at all, and
     * the pending table caps how many can be outstanding at once. */
    for (page = (first > s->window.start ? first : s->window.start);
         page <= last && page <= s->window.end && page < count; ++page)
        queue_page(s, sizes, count, page, panel_w, side_inset, dark);
    for (page = s->window.start; page <= s->window.end && page < count; ++page)
        queue_page(s, sizes, count, page, panel_w, side_inset, dark);
}

unsigned long long spdf_win_thumbs_stat_ready(SpdfWinThumbStore* s) {
    return s ? s->ready : 0;
}

unsigned long long spdf_win_thumbs_stat_started(SpdfWinThumbStore* s) {
    if (!s || !s->svc) return 0;
    return spdf_win_render_stat(s->svc, SPDF_WIN_RENDER_STAT_TASKS_STARTED);
}
