/* The per-page cursor-region cache, the click that follows a link, and the
 * worker thread that finds plain-text URLs for the hover hand. See
 * spdf_win_links.h for the layering, the provenance of the pure half, and the
 * reason hover and click ask the core two different questions.
 *
 * THE WORKER, and the one rule it obeys: IT NEVER TOUCHES THE CALLER'S
 * DOCUMENT. The core allows one spdf_document per thread and locks nothing
 * inside it (shenzhen_pdf_core.c:40-43), so the thread opens its own handle
 * from the path the canvas hands over, exactly as the render pool and the
 * thumbnail store do. What crosses the lock is a page number going out and an
 * array of rects coming back; the UI thread merges the rects into its own
 * cache on the next hover, which is also the moment the hand appears -- the
 * same moment it appears on macOS, whose cursor rects are rebuilt asynchronously
 * and take effect on the next mouse move.
 *
 * ONE PAGE AT A TIME, LATEST WINS. The pointer is over one page; a request for
 * a page the pointer has already left is dropped before it is started, and a
 * result for a page the cache has moved past is ignored when it lands. So a
 * fast scroll through a dense document costs at most one structured-text pass
 * per page the pointer actually rests on.
 */
#include "spdf_win_links.h"
#include "spdf_win_open.h" /* the process opener: spdf_open, or Markdown-aware once main() says so */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <process.h>
#include <stdlib.h>
#include <string.h>

struct spdf_win_links {
    int page;     /* the cached page, or -1 */
    int has_text; /* text regions were built for it */
    spdf_rect links[SPDF_WIN_CURSOR_REGION_MAX_LINK_RECTS];
    int link_count;
    spdf_rect* text;
    int text_count;
    int text_capacity;

    /* --- the text-URL worker ------------------------------------------- */
    char* path; /* UTF-8, owned; NULL disables the worker entirely */
    int merged_page; /* UI: the page whose worker result is in `links`, or -1 */
    HANDLE thread;
    HANDLE wake;
    CRITICAL_SECTION lock;
    volatile long quit;
    /* Who still holds this block: the canvas, and the worker while it runs.
     * Whoever lets go last frees it (links_release), so the UI thread never
     * has to wait for the worker to be done with it. */
    volatile long refs;
    /* under `lock` */
    int want_page; /* the page whose text URLs are wanted; -1 when none */
    int done_page; /* the page `done_rects` describe; -1 when none */
    spdf_rect done_rects[SPDF_WIN_CURSOR_REGION_MAX_LINK_RECTS];
    int done_count;
};

spdf_win_links* spdf_win_links_new(void) {
    spdf_win_links* links = (spdf_win_links*)calloc(1, sizeof(*links));
    if (!links) return NULL;
    links->page = -1;
    links->merged_page = -1;
    links->want_page = -1;
    links->done_page = -1;
    links->refs = 1;
    InitializeCriticalSection(&links->lock);
    return links;
}

/* The last holder out frees the block: the canvas from spdf_win_links_free(),
 * or the worker when it finds the canvas already gone. */
static void links_release(spdf_win_links* links) {
    if (InterlockedDecrement(&links->refs) != 0) return;
    if (links->wake) CloseHandle(links->wake);
    DeleteCriticalSection(&links->lock);
    free(links->path);
    free(links->text);
    free(links);
}

void spdf_win_links_free(spdf_win_links* links) {
    if (!links) return;
    if (links->thread) {
        /* NO JOIN. This runs on the UI thread every time a canvas goes -- a
         * tab switch, a reload from disk, a theme flip -- and the worker may
         * be inside spdf_page_link_rects(detect_text_links = 1), which is one
         * page's structured-text pass, or inside its first open of the
         * document. Neither is interruptible and on a dense or a large file
         * either is whole seconds, during which a joining UI thread would
         * answer nothing (the shell ghosts a window after five). The worker
         * checks `quit` after every page and is woken if idle, so it ends on
         * its own soon enough; the block outlives the canvas until it does
         * (links_release) and the thread handle is simply let go of. */
        InterlockedExchange(&links->quit, 1);
        SetEvent(links->wake);
        CloseHandle(links->thread);
        links->thread = NULL;
    }
    links_release(links);
}

void spdf_win_links_invalidate(spdf_win_links* links) {
    if (!links) return;
    links->page = -1;
    links->has_text = 0;
    links->link_count = 0;
    links->text_count = 0;
    links->merged_page = -1;
    EnterCriticalSection(&links->lock);
    links->want_page = -1;
    links->done_page = -1;
    links->done_count = 0;
    LeaveCriticalSection(&links->lock);
}

void spdf_win_links_set_source(spdf_win_links* links, const char* utf8_path) {
    if (!links || links->path) return; /* set once, before any request */
    links->path = utf8_path && utf8_path[0] ? _strdup(utf8_path) : NULL;
}

/* --- the worker ------------------------------------------------------------ */

static unsigned __stdcall text_link_worker(void* arg) {
    spdf_win_links* links = (spdf_win_links*)arg;
    spdf_document* doc = NULL;
    char err[256];

    for (;;) {
        int page;
        spdf_rect raw[SPDF_WIN_CURSOR_REGION_MAX_LINK_RECTS];
        int count;

        EnterCriticalSection(&links->lock);
        page = links->want_page;
        links->want_page = -1;
        LeaveCriticalSection(&links->lock);
        if (InterlockedCompareExchange(&links->quit, 0, 0)) break;
        if (page < 0) {
            WaitForSingleObject(links->wake, INFINITE);
            continue;
        }
        if (!doc) doc = spdf_win_open_document(links->path, err, sizeof(err));
        if (!doc) break; /* an unopenable document has no text URLs; the thread rests */

        /* detect_text_links = 1: the structured-text pass, off the UI thread,
         * which is the whole reason this thread exists. */
        count = spdf_page_link_rects(doc, page, 1, raw, (int)(sizeof(raw) / sizeof(raw[0])), err, sizeof(err));
        EnterCriticalSection(&links->lock);
        if (count >= 0) {
            links->done_page = page;
            links->done_count = count;
            memcpy(links->done_rects, raw, sizeof(raw[0]) * (size_t)count);
        }
        LeaveCriticalSection(&links->lock);
    }
    if (doc) spdf_close(doc);
    links_release(links); /* the canvas may already be gone: see spdf_win_links_free */
    return 0;
}

/* Ask for `page`'s text URLs. Starts the thread on the first request, so a
 * document nobody hovers over pays no thread. */
static void request_text_links(spdf_win_links* links, int page) {
    if (!links->path) return;
    if (!links->wake) {
        links->wake = CreateEventW(NULL, FALSE, FALSE, NULL);
        if (!links->wake) return;
    }
    EnterCriticalSection(&links->lock);
    links->want_page = page;
    LeaveCriticalSection(&links->lock);
    if (!links->thread) {
        /* The worker's hold is taken BEFORE the thread exists, so it can never
         * observe a count it has not been given. */
        InterlockedIncrement(&links->refs);
        links->thread = (HANDLE)_beginthreadex(NULL, 0, text_link_worker, links, 0, NULL);
        if (!links->thread) {
            InterlockedDecrement(&links->refs);
            return;
        }
    }
    SetEvent(links->wake);
}

/* Adopt the worker's answer for the cached page, once. The full set from
 * spdf_page_link_rects(detect_text_links = 1) REPLACES the annotation-only set:
 * it is a superset, built by the same core call with the same filter. */
static void merge_text_links(spdf_win_links* links) {
    if (links->merged_page == links->page) return;
    EnterCriticalSection(&links->lock);
    if (links->done_page == links->page) {
        int i;
        links->link_count = 0;
        for (i = 0; i < links->done_count; ++i)
            spdf_win_cursor_region_append_rect(links->links, &links->link_count,
                                               (int)(sizeof(links->links) / sizeof(links->links[0])),
                                               &links->done_rects[i]);
        links->merged_page = links->page;
    }
    LeaveCriticalSection(&links->lock);
}

/* --- building ------------------------------------------------------------- */

static void build_links(spdf_win_links* cache, spdf_document* doc, int page_index) {
    spdf_rect raw[SPDF_WIN_CURSOR_REGION_MAX_LINK_RECTS];
    char err[256];
    int count, i;

    cache->link_count = 0;
    /* detect_text_links = 0: hover runs on every mouse move and must not build
     * the page's structured text. spdf_page_link_rects's header says so. The
     * text URLs arrive from the worker and are merged in when they land. */
    count = spdf_page_link_rects(doc, page_index, 0, raw, (int)(sizeof(raw) / sizeof(raw[0])), err, sizeof(err));
    if (count < 0) return; /* an unreadable page has no links, not a crash */
    for (i = 0; i < count; ++i)
        spdf_win_cursor_region_append_rect(cache->links, &cache->link_count,
                                           (int)(sizeof(cache->links) / sizeof(cache->links[0])), &raw[i]);
}

static void build_text(spdf_win_links* cache, spdf_document* doc, int page_index) {
    spdf_text_lines lines;
    char err[256];
    int i;

    cache->text_count = 0;
    memset(&lines, 0, sizeof(lines));
    if (!spdf_extract_page_text_lines(doc, page_index, &lines, err, sizeof(err))) return;
    if (lines.count > cache->text_capacity) {
        spdf_rect* grown = (spdf_rect*)realloc(cache->text, sizeof(spdf_rect) * (size_t)lines.count);
        if (!grown) {
            spdf_free_text_lines(&lines);
            return;
        }
        cache->text = grown;
        cache->text_capacity = lines.count;
    }
    for (i = 0; i < lines.count; ++i)
        spdf_win_cursor_region_append_rect(cache->text, &cache->text_count, cache->text_capacity, &lines.items[i].bounds);
    spdf_free_text_lines(&lines);
}

int spdf_win_links_ensure_page(spdf_win_links* links, spdf_document* doc, int page_index, int want_text_regions) {
    if (!links || !doc || page_index < 0) return 0;
    if (links->page != page_index) {
        links->page = page_index;
        links->has_text = 0;
        links->text_count = 0;
        links->merged_page = -1;
        build_links(links, doc, page_index);
        request_text_links(links, page_index);
    }
    merge_text_links(links);
    if (want_text_regions && !links->has_text) {
        build_text(links, doc, page_index);
        links->has_text = 1;
    }
    return 1;
}

int spdf_win_links_text_urls_ready(const spdf_win_links* links) {
    return links && links->page >= 0 && links->merged_page == links->page;
}

/* --- asking --------------------------------------------------------------- */

SpdfWinCursorRegionKind spdf_win_links_region_at(spdf_win_links* links, spdf_document* doc, int page_index,
                                                 int want_text_regions, float x, float y) {
    if (!spdf_win_links_ensure_page(links, doc, page_index, want_text_regions)) return SPDF_WIN_CURSOR_REGION_NONE;
    return spdf_win_cursor_region_at_point(links->links, (unsigned)links->link_count, links->text,
                                           (unsigned)links->text_count, (double)x, (double)y,
                                           SPDF_WIN_CURSOR_LINK_HIT_PADDING);
}

int spdf_win_links_hit(spdf_win_links* links, spdf_document* doc, int page_index, float x, float y) {
    int i;
    if (!spdf_win_links_ensure_page(links, doc, page_index, 0)) return 0;
    for (i = 0; i < links->link_count; ++i)
        if (spdf_win_cursor_rect_contains(&links->links[i], (double)x, (double)y, SPDF_WIN_CURSOR_LINK_HIT_PADDING))
            return 1;
    return 0;
}

int spdf_win_links_target_at(spdf_document* doc, int page_index, float x, float y, spdf_link_target* out) {
    char err[256];
    int rc;

    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    out->page_index = -1;
    if (!doc || page_index < 0) return -1;
    /* detect_text_links = 1 HERE as well: a click resolves the target itself,
     * once, and cannot wait for the worker. */
    rc = spdf_link_at_point(doc, page_index, x, y, out, 1, err, sizeof(err));
    if (rc < 0) return -1;
    return out->kind == SPDF_LINK_NONE ? 0 : 1;
}
