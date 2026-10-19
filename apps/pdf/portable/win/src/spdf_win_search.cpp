/* The find engine. See spdf_win_chrome_find.h for the API and for why it is
 * declared there rather than in spdf_win_search.h.
 *
 * THE SHAPE, and every rule it obeys:
 *
 *   - ONE WORKER THREAD PER SEARCH, with its own spdf_document. The core allows
 *     one document per thread, so the app's handle is never touched off-thread;
 *     this is the same model as the GTK4 controller (spdf_search.c
 *     search_worker) and the macOS startFindForCurrentQuery. Results arrive as
 *     generation-checked batches of 128, so a long document highlights and
 *     counts as it goes rather than after.
 *
 *   - NOTHING ON THE PAINT PATH OR THE LAUNCH PATH. The session allocates one
 *     struct and starts no thread until a non-empty query arrives, so a document
 *     nobody searches, every --render-png and the probe all pay exactly nothing.
 *     Everything the UI thread calls (set with an unchanged query, poll,
 *     step, marks, apply_overlays) is O(1)-ish and cannot block.
 *
 *   - CANCELLATION IS A COUNTER. spdf_win_find_set bumps `generation`; the worker
 *     polls it once per page and stops, and any batch it already posted is
 *     discarded because it carries the old generation. Deliberately not a thread
 *     join: a join on the UI thread is a stall of exactly the length of the
 *     search that is being abandoned, which is the wrong end of the trade.
 *
 *   - THE PORTED LOGIC IS CALLED, NOT REIMPLEMENTED. Every decision below that
 *     has a GTK4 original -- the match list and its 20000 cap, the query byte
 *     cap, the snippet, chapter attribution, the marker fractions -- goes through
 *     spdf_win_search.h, which is differentially tested against that original.
 *
 * THIS FILE IS THE WORKER AND THE LIFECYCLE. The UI-thread API is in
 * spdf_win_search_api.h and the two pixel mappings in
 * spdf_win_search_geometry.h, both included at the BOTTOM so they see the
 * complete session struct -- internal headers rather than second translation
 * units, so the struct stays private to one .cpp (tools/file-size-limits.md
 * asks for extraction, not a raised cap). The CHROME-FACING half -- the
 * process-wide session, the query bridge and spdf_win_find_fill_model() -- is
 * in spdf_win_chrome_model.cpp.
 *
 * THE OUTLINE TITLES TRAVEL WITH THE RESULTS. The sidebar's Search section
 * groups matches under their chapter heading (mac rebuildSearchSidebarItems),
 * which needs the title of every outline entry -- and the worker has the
 * outline open anyway for chapter attribution. It publishes a copy under the
 * lock once per search; poll() adopts it onto the UI thread, which is the only
 * thread that ever reads it afterwards. Nothing borrows across the lock.
 */
#include "spdf_win_chrome_find.h"
#include "spdf_win_open.h" /* the process opener: spdf_open, or Markdown-aware once main() says so */

#include "spdf_win_d2d.h" /* spdf_win_scene, spdf_win_overlay */
#include "spdf_win_layout.h"

#include <process.h>
#include <stdlib.h>
#include <string.h>

#define SPDF_FIND_PAGE_RECT_MAX 256 /* GTK3's per-page rect cap (SEARCH_PAGE_RECT_MAX) */
#define SPDF_FIND_BATCH_MATCHES 128 /* GTK4's worker->main delivery granularity */
#define SPDF_FIND_DEFAULT_LANE_H 800.0f

struct SpdfWinFindSession {
    CRITICAL_SECTION lock;

    /* --- UI thread only ------------------------------------------------- */
    char* path;
    char* query;
    int regex;
    int regex_multiline;
    SpdfWinSearchMatchList list;
    int current;
    int started;
    char error[512];
    /* Bumped on every change a reader of the list could see -- a batch
     * adopted, the current match moved, the query replaced -- so a consumer
     * that caches a view of the results (the sidebar's rows) can compare one
     * integer per frame instead of the list. */
    unsigned revision;

    /* The document's outline titles, in spdf_load_outline order, adopted from
     * the worker by poll(). Owned here; NULL/0 without an outline. */
    char** titles;
    int title_count;

    float* marks;
    int mark_count;
    int active_mark;
    float* raw_marks;
    int raw_capacity;
    float lane_h;    /* device px of the scroller trough, from the last frame */
    float dpi_scale; /* device px per logical px, likewise */

    /* The minimap strip's markers: every match as (page, fraction of that
     * page's height), rebuilt beside the scroller marks. */
    SpdfWinFindPageMark* page_marks;
    int page_mark_count;
    int page_mark_capacity;

    spdf_win_overlay* overlays;
    int overlay_capacity;
    int overlay_count;

    /* --- shared, under `lock` ------------------------------------------- */
    SpdfWinSearchMatchList pending;
    long pending_gen;
    char pending_error[512];
    int pending_has_error;
    SpdfWinPageSizePt* sizes;
    int size_count;
    char** pending_titles;
    int pending_title_count;
    long pending_titles_gen;

    /* --- interlocked ---------------------------------------------------- */
    volatile long generation;
    volatile long finished_gen;
    volatile long live_workers;

    /* Repaint side channel, exactly the shape and the justification of
     * spdf_win_thumbs_note_paint_thread: a batch lands on a worker thread
     * milliseconds to seconds after the frame that asked for it, and without
     * this the highlights and the counter would not appear until the next mouse
     * move. spdf_win_paint() still needs no HWND -- this is the session's side
     * channel, not the painter's. */
    HWND windows[8];
    int window_count;
    int noted_paint_thread;
};

/* Defined in spdf_win_search_geometry.h, which is included at the BOTTOM of this
 * file so it sees the complete struct above. Forward-declared here because the
 * UI-thread API rebuilds the ticks whenever the match list or the current match
 * moves. */
static void rebuild_marks(SpdfWinFindSession* s);

/* THE REGEX MULTILINE FLAG IS PROCESS-WIDE, like the query bridge's regex flag,
 * and for the same reason: it is the reader's setting, not a property of one
 * search. spdf_win_find_set() reads it as a fourth input and restarts when it
 * changed, so the Edit menu row takes effect on the next paint with no caller
 * having to learn a new argument. Defaults ON, as both originals do
 * (SPDFMacModels.mm:15 `_searchRegexMultiline = YES`, spdf_state.c:780 TRUE). */
static volatile long g_regex_multiline = 1;

void spdf_win_find_set_regex_multiline(int on) { InterlockedExchange(&g_regex_multiline, on ? 1 : 0); }
int spdf_win_find_regex_multiline(void) { return (int)InterlockedCompareExchange(&g_regex_multiline, 0, 0); }

namespace {

char* dup_str(const char* s) {
    size_t n;
    char* out;
    if (!s) return NULL;
    n = strlen(s);
    out = (char*)malloc(n + 1);
    if (out) memcpy(out, s, n + 1);
    return out;
}

int same_str(const char* a, const char* b) {
    if (!a) a = "";
    if (!b) b = "";
    return strcmp(a, b) == 0;
}

void free_titles(char** titles, int count) {
    int i;
    if (!titles) return;
    for (i = 0; i < count; ++i) free(titles[i]);
    free(titles);
}

BOOL CALLBACK collect_window(HWND hwnd, LPARAM param) {
    SpdfWinFindSession* s = (SpdfWinFindSession*)param;
    if (s->window_count < (int)(sizeof(s->windows) / sizeof(s->windows[0]))) s->windows[s->window_count++] = hwnd;
    return TRUE;
}

void invalidate_windows(SpdfWinFindSession* s) {
    int i;
    EnterCriticalSection(&s->lock);
    for (i = 0; i < s->window_count; ++i) InvalidateRect(s->windows[i], NULL, FALSE);
    LeaveCriticalSection(&s->lock);
}

struct Job {
    SpdfWinFindSession* session;
    long generation;
    char* path;
    char* query;
    int regex;
    int regex_multiline;
};

/* One page's worth of snippets, from the page's own text lines. The GTK4 worker
 * does exactly this and for the same reason: the snippet is the sidebar's row
 * text, and extracting lines is only worth it on a page that actually matched. */
void snippets_for_page(spdf_document* doc, int page, const spdf_rect* rects, int hits, int chapter,
                       SpdfWinSearchMatchList* batch, int* total) {
    char err[256] = {0};
    spdf_text_lines lines;
    const char** texts = NULL;
    spdf_rect* bounds = NULL;
    int has_lines, i;

    memset(&lines, 0, sizeof(lines));
    has_lines = spdf_extract_page_text_lines(doc, page, &lines, err, sizeof(err)) && lines.count > 0;
    if (has_lines) {
        texts = (const char**)malloc(sizeof(*texts) * (size_t)lines.count);
        bounds = (spdf_rect*)malloc(sizeof(*bounds) * (size_t)lines.count);
        if (!texts || !bounds) has_lines = 0;
    }
    if (has_lines) {
        for (i = 0; i < lines.count; ++i) {
            texts[i] = lines.items[i].text;
            bounds[i] = lines.items[i].bounds;
        }
    }
    for (i = 0; i < hits && *total < SPDF_WIN_SEARCH_MAX_MATCHES; ++i) {
        char* snippet = has_lines ? spdf_win_search_snippet(texts, bounds, lines.count, rects[i])
                                  : spdf_win_search_dup_bytes("", 0);
        spdf_win_search_match_list_append(batch, page, rects[i], snippet, chapter);
        (*total)++;
    }
    free(texts);
    free(bounds);
    if (lines.count > 0 || lines.items) spdf_free_text_lines(&lines);
}

/* Hands a batch to the UI thread. Discards it if the generation has moved on,
 * and RESETS whatever an older generation left behind -- otherwise a fast
 * retype would deliver the tail of the previous query's results. */
void post_batch(SpdfWinFindSession* s, long gen, SpdfWinSearchMatchList* batch, const char* error) {
    EnterCriticalSection(&s->lock);
    if (s->pending_gen != gen) {
        spdf_win_search_match_list_clear(&s->pending);
        s->pending_gen = gen;
        s->pending_has_error = 0;
        s->pending_error[0] = 0;
    }
    spdf_win_search_match_list_steal_into(&s->pending, batch);
    if (error && error[0]) {
        /* A failed search shows NO matches (GTK3 semantics, inherited by the
         * mac app), so the error arrives having thrown the rest away. */
        spdf_win_search_match_list_clear(&s->pending);
        s->pending_has_error = 1;
        strncpy(s->pending_error, error, sizeof(s->pending_error) - 1);
        s->pending_error[sizeof(s->pending_error) - 1] = 0;
    }
    LeaveCriticalSection(&s->lock);
    invalidate_windows(s);
}

/* The outline titles, once per search, for the sidebar's chapter headers. A
 * copy for the UI thread; the outline itself is freed with the worker's. */
void post_titles(SpdfWinFindSession* s, long gen, const spdf_outline* outline) {
    char** titles = NULL;
    int count = outline ? outline->count : 0;
    int i;
    if (count > 0) {
        titles = (char**)calloc((size_t)count, sizeof(char*));
        if (!titles) count = 0;
        for (i = 0; i < count; ++i) titles[i] = dup_str(outline->items[i].title ? outline->items[i].title : "");
    }
    EnterCriticalSection(&s->lock);
    free_titles(s->pending_titles, s->pending_title_count);
    s->pending_titles = titles;
    s->pending_title_count = count;
    s->pending_titles_gen = gen;
    LeaveCriticalSection(&s->lock);
}

unsigned __stdcall search_worker(void* arg) {
    Job* job = (Job*)arg;
    SpdfWinFindSession* s = job->session;
    char err[512] = {0};
    const char* error = NULL;
    SpdfWinSearchMatchList batch;
    int* chapter_pages = NULL;
    int chapter_count = 0;
    int total = 0;
    int page, page_count = 0;
    spdf_document* doc;

    spdf_win_search_match_list_init(&batch);
    doc = spdf_win_open_document(job->path, err, sizeof(err));
    if (!doc) {
        error = err[0] ? err : "Could not open the document for search.";
    } else {
        spdf_outline outline;
        memset(&outline, 0, sizeof(outline));
        page_count = spdf_page_count(doc);
        if (spdf_load_outline(doc, &outline, err, sizeof(err)) && outline.count > 0) {
            chapter_count = outline.count;
            chapter_pages = (int*)malloc(sizeof(int) * (size_t)chapter_count);
            if (chapter_pages)
                for (int i = 0; i < chapter_count; ++i) chapter_pages[i] = outline.items[i].page_index;
            else
                chapter_count = 0;
        }
        post_titles(s, job->generation, &outline);
        spdf_free_outline(&outline);

        /* The mark layout needs every page's height, and the overlay mapping
         * needs the width of any page that matched. Both are published as the
         * sweep reaches them; an unmeasured page borrows page 0's size, which is
         * macOS's own placeholder geometry pass. */
        EnterCriticalSection(&s->lock);
        free(s->sizes);
        s->sizes = page_count > 0 ? (SpdfWinPageSizePt*)calloc((size_t)page_count, sizeof(SpdfWinPageSizePt)) : NULL;
        s->size_count = s->sizes ? page_count : 0;
        LeaveCriticalSection(&s->lock);

        for (page = 0; page < page_count && total < SPDF_WIN_SEARCH_MAX_MATCHES; ++page) {
            spdf_rect rects[SPDF_FIND_PAGE_RECT_MAX];
            int hits;
            float pw = 0.0f, ph = 0.0f;

            if (InterlockedCompareExchange(&s->generation, 0, 0) != job->generation) break;

            if (spdf_page_size(doc, page, &pw, &ph, err, sizeof(err)) && pw > 0.0f && ph > 0.0f) {
                EnterCriticalSection(&s->lock);
                if (s->sizes && page < s->size_count) {
                    s->sizes[page].width = (double)pw;
                    s->sizes[page].height = (double)ph;
                }
                LeaveCriticalSection(&s->lock);
            }

            hits = spdf_search_page_rects_options(doc, page, job->query, job->regex, job->regex_multiline, rects,
                                                 SPDF_FIND_PAGE_RECT_MAX, err, sizeof(err));
            if (hits < 0) {
                /* Graceful invalid-pattern failure: the first error wins. */
                error = err[0] ? err : (job->regex ? "Invalid regular expression." : "Search failed.");
                break;
            }
            if (hits == 0) continue;

            snippets_for_page(doc, page, rects, hits, spdf_win_search_chapter_for_page(chapter_pages, chapter_count, page),
                              &batch, &total);
            if (spdf_win_search_match_list_count(&batch) >= SPDF_FIND_BATCH_MATCHES)
                post_batch(s, job->generation, &batch, NULL);
        }
        spdf_close(doc);
    }

    post_batch(s, job->generation, &batch, error);
    spdf_win_search_match_list_deinit(&batch);
    free(chapter_pages);
    InterlockedExchange(&s->finished_gen, job->generation);
    InterlockedDecrement(&s->live_workers);
    free(job->path);
    free(job->query);
    free(job);
    return 0;
}

} /* namespace */

SpdfWinFindSession* spdf_win_find_session_new(void) {
    SpdfWinFindSession* s = (SpdfWinFindSession*)calloc(1, sizeof(SpdfWinFindSession));
    if (!s) return NULL;
    InitializeCriticalSection(&s->lock);
    spdf_win_search_match_list_init(&s->list);
    spdf_win_search_match_list_init(&s->pending);
    s->current = -1;
    s->active_mark = -1;
    s->pending_gen = -1;
    s->pending_titles_gen = -1;
    s->finished_gen = 0;
    s->lane_h = SPDF_FIND_DEFAULT_LANE_H;
    s->dpi_scale = 1.0f;
    s->regex_multiline = spdf_win_find_regex_multiline();
    return s;
}

void spdf_win_find_session_free(SpdfWinFindSession* s) {
    if (!s) return;
    /* Bump first so every worker stops at its next page boundary, then wait for
     * them: they hold a pointer to this struct. The wait is bounded by one page
     * search, and it is the only blocking wait in the file. */
    InterlockedIncrement(&s->generation);
    while (InterlockedCompareExchange(&s->live_workers, 0, 0) != 0) Sleep(1);
    spdf_win_search_match_list_deinit(&s->list);
    spdf_win_search_match_list_deinit(&s->pending);
    free_titles(s->titles, s->title_count);
    free_titles(s->pending_titles, s->pending_title_count);
    free(s->sizes);
    free(s->marks);
    free(s->raw_marks);
    free(s->page_marks);
    free(s->overlays);
    free(s->path);
    free(s->query);
    DeleteCriticalSection(&s->lock);
    free(s);
}

/* The UI-thread API, then the two pixel mappings. Included HERE, at the bottom,
 * so both see the complete session struct; see their own header comments. */
#include "spdf_win_search_api.h"
#include "spdf_win_search_geometry.h"
