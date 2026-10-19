/* spdf_win_search.h — the find logic, ported from the GTK4 frontend.
 *
 * TRANSCRIPTION, NOT A REWRITE. Every function below is the corresponding
 * `static inline` in portable/linux/gtk4/spdf_search_internal.h with glib's
 * types and containers replaced and NOTHING ELSE changed — same branches, same
 * comparison order, same edge behaviour. That header already carries the
 * provenance of each rule back to the macOS and GTK3 sources
 * (spdf_search_nearest_match <- SPDFMacFindNearest.mm, spdf_search_snippet <-
 * findContextForQuery @10398, the marker layout <- findScrollbarMarkers @6188,
 * the counter <- update_find_controls @1988, the 20000/2048 caps <- GTK3's
 * MAX_FIND_MATCHES / MAX_FIND_QUERY_BYTES); it is not repeated here, because two
 * copies of a provenance note is how one of them goes stale. Read that file
 * beside this one.
 *
 * WHY A PORT AT ALL, given the original is already toolkit-free: it is
 * glib-free, not dependency-free. It needs GArray, g_strdup/g_strndup,
 * g_strlcpy/g_snprintf and g_strstrip, and linking glib into the Windows app to
 * get seven allocations and a substring search would be a large dependency for a
 * small amount of code. Same trade spdf_win_layout.h made against
 * spdf_docview_internal.h, and it is safe for the same reason: the port is
 * checked against the original rather than against its author's memory.
 *
 *   portable\win\tests\search-differential-native.cmd
 *
 * compiles the REAL GTK header (under a glib shim) into the same binary as this
 * one, drives both with identical inputs and compares for EXACT equality —
 * doubles with `==`, strings with strcmp. That pattern has already caught a
 * one-ulp transcription error in this port, so do not "clean up" any expression
 * below without re-running it: `fraction * MAX(1.0, lane_h - tick_h)` and
 * `CLAMP` argument order are load-bearing.
 *
 * THE THREE BEHAVIOURAL DIFFERENCES, all in the container and all deliberate:
 *
 *   1. The match list is a plain grown array over malloc/realloc where the
 *      original uses GArray. glib ABORTS on OOM; these functions FAIL — append
 *      returns 0 and frees the snippet it was handed, exactly as it does at the
 *      cap. A caller that ignores the return value therefore loses matches
 *      rather than the process, which is the right failure for a search.
 *   2. `spdf_win_search_match_list_get` returns NULL for an out-of-range index,
 *      as the original does; `g_array_index` in the original's own append path
 *      is unchecked and so is the port's.
 *   3. Growth is by doubling from 64. GArray's own growth policy is also
 *      doubling, but it is not part of the contract either way — only the
 *      element ORDER and the cap are, and the differential checks both.
 *
 * PURE, TOOLKIT-FREE, HEADER-ONLY, and MSVC-clean as C and as C++: no windows.h,
 * no Direct2D, no chrome type. The engine that DRIVES this (the worker thread,
 * the generation counter, the marks the toolbar reads) is deliberately not here
 * — it lives in spdf_win_chrome_find.h and spdf_win_search.cpp, so this file can
 * stay a transcription that a test compiles beside its original.
 */
#ifndef SPDF_WIN_SEARCH_H
#define SPDF_WIN_SEARCH_H

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shenzhen_pdf_core.h" /* spdf_rect, shared with the GTK original */

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_SEARCH_INLINE __inline
#else
#define SPDF_WIN_SEARCH_INLINE inline
#endif

#define SPDF_WIN_SEARCH_MAX_QUERY_BYTES 2048 /* GTK3 MAX_FIND_QUERY_BYTES */
#define SPDF_WIN_SEARCH_MAX_MATCHES 20000    /* GTK3 MAX_FIND_MATCHES */
#define SPDF_WIN_SEARCH_MARKER_TICK_H 3.0    /* GTK3 draw_find_marker mark_height */

/* glib's MAX and CLAMP, character for character (glib/gmacros.h). Copied rather
 * than taken from <algorithm> or rewritten as an if-chain because the COMPARISON
 * ORDER decides CLAMP(x, lo, hi) when hi < lo and when x is NaN, and the
 * differential compares those cases. Named, not #defined as MAX/CLAMP, so this
 * header cannot collide with a consumer's own macros. */
static SPDF_WIN_SEARCH_INLINE double spdf_win_search_max(double a, double b) { return ((a) > (b)) ? (a) : (b); }

static SPDF_WIN_SEARCH_INLINE double spdf_win_search_clamp(double x, double low, double high) {
    return ((x) > (high)) ? (high) : (((x) < (low)) ? (low) : (x));
}

/* One search hit. `rect` is in page space (PDF points, y down as the core
 * returns it); `snippet` is the surrounding text line, owned by the list;
 * `chapter_index` is the pre-order outline index the match falls under, -1
 * before the first chapter and without an outline. */
typedef struct SpdfWinSearchMatch {
    int page;
    spdf_rect rect;
    char* snippet;
    int chapter_index;
} SpdfWinSearchMatch;

typedef struct SpdfWinSearchMatchList {
    SpdfWinSearchMatch* items; /* snippets owned */
    unsigned count;
    unsigned capacity;
} SpdfWinSearchMatchList;

static SPDF_WIN_SEARCH_INLINE void spdf_win_search_match_list_init(SpdfWinSearchMatchList* list) {
    if (!list) return;
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static SPDF_WIN_SEARCH_INLINE unsigned spdf_win_search_match_list_count(const SpdfWinSearchMatchList* list) {
    return list && list->items ? list->count : 0;
}

static SPDF_WIN_SEARCH_INLINE const SpdfWinSearchMatch* spdf_win_search_match_list_get(
    const SpdfWinSearchMatchList* list, unsigned index) {
    if (!list || !list->items || index >= list->count) return NULL;
    return &list->items[index];
}

/* Doubling from 64. Returns 0 when the allocation fails, leaving the list
 * exactly as it was -- realloc's own contract, which is why the result goes into
 * a temporary before it is adopted. */
static SPDF_WIN_SEARCH_INLINE int spdf_win_search_match_list_reserve(SpdfWinSearchMatchList* list, unsigned want) {
    unsigned capacity;
    SpdfWinSearchMatch* grown;
    if (!list) return 0;
    if (want <= list->capacity) return 1;
    capacity = list->capacity ? list->capacity : 64u;
    while (capacity < want) capacity *= 2u;
    grown = (SpdfWinSearchMatch*)realloc(list->items, (size_t)capacity * sizeof(*grown));
    if (!grown) return 0;
    list->items = grown;
    list->capacity = capacity;
    return 1;
}

/* Appends a match, taking ownership of `snippet` (freed even when the cap or an
 * allocation failure rejects the match). Returns 0 at the MAX_MATCHES cap. */
static SPDF_WIN_SEARCH_INLINE int spdf_win_search_match_list_append(SpdfWinSearchMatchList* list, int page,
                                                                   spdf_rect rect, char* snippet, int chapter_index) {
    SpdfWinSearchMatch match;
    if (!list || list->count >= (unsigned)SPDF_WIN_SEARCH_MAX_MATCHES ||
        !spdf_win_search_match_list_reserve(list, list->count + 1u)) {
        free(snippet);
        return 0;
    }
    match.page = page;
    match.rect = rect;
    match.snippet = snippet;
    match.chapter_index = chapter_index;
    list->items[list->count++] = match;
    return 1;
}

static SPDF_WIN_SEARCH_INLINE void spdf_win_search_match_list_clear(SpdfWinSearchMatchList* list) {
    unsigned i;
    if (!list || !list->items) return;
    for (i = 0; i < list->count; ++i) free(list->items[i].snippet);
    list->count = 0;
}

static SPDF_WIN_SEARCH_INLINE void spdf_win_search_match_list_deinit(SpdfWinSearchMatchList* list) {
    if (!list || !list->items) return;
    spdf_win_search_match_list_clear(list);
    free(list->items);
    list->items = NULL;
    list->capacity = 0;
}

/* Moves every match of `src` onto the end of `dst` (batch delivery from the
 * worker); `src` is left empty but initialized. Ownership of snippets moves. */
static SPDF_WIN_SEARCH_INLINE void spdf_win_search_match_list_steal_into(SpdfWinSearchMatchList* dst,
                                                                        SpdfWinSearchMatchList* src) {
    unsigned i;
    if (!dst || !src || !src->items) return;
    for (i = 0; i < src->count; ++i) {
        SpdfWinSearchMatch* m = &src->items[i];
        if (dst->count >= (unsigned)SPDF_WIN_SEARCH_MAX_MATCHES ||
            !spdf_win_search_match_list_reserve(dst, dst->count + 1u)) {
            free(m->snippet);
            continue;
        }
        dst->items[dst->count++] = *m;
    }
    src->count = 0; /* snippets now owned by dst */
}

/* --------------------------------------------------------------------------
 * Counter string. Hidden/empty without a query, "0 / 0" for a query without
 * matches, "current+1 / total" otherwise, and the bare total while a search is
 * running with nothing selected yet.
 *
 * THIS IS THE GTK COUNTER, and the Windows toolbar does NOT draw it directly:
 * macOS shows "..." in the searching state where GTK shows the running total
 * (ShenzhenPDFMac.mm:10631-10652). spdf_win_chrome_find.h owns that variant.
 * Keeping this one a faithful port is what lets the differential check it at
 * all -- a function that had been "improved" toward macOS could not be compared
 * against its original. */
static SPDF_WIN_SEARCH_INLINE void spdf_win_search_counter_text(char* buf, size_t len, int has_query, int current,
                                                               int total) {
    if (!buf || len == 0) return;
    if (!has_query) buf[0] = '\0';
    else if (total <= 0) {
        /* g_strlcpy's truncating copy, not strcpy: a 3-byte buffer must get
         * "0 " and a NUL, not five bytes and a smashed stack. */
        size_t n = strlen("0 / 0");
        if (n >= len) n = len - 1;
        memcpy(buf, "0 / 0", n);
        buf[n] = '\0';
    } else if (current < 0)
        snprintf(buf, len, "%d", total); /* searching / no selection yet */
    else
        snprintf(buf, len, "%d / %d", current + 1, total);
}

/* --------------------------------------------------------------------------
 * Query duplication with the GTK3 byte cap, truncated on a UTF-8 character
 * boundary (port of dup_limited_utf8). Never returns NULL unless malloc fails,
 * which is the one place glib would have aborted instead. */
static SPDF_WIN_SEARCH_INLINE char* spdf_win_search_dup_bytes(const char* text, size_t len) {
    char* out = (char*)malloc(len + 1);
    if (!out) return NULL;
    if (len) memcpy(out, text, len);
    out[len] = '\0';
    return out;
}

static SPDF_WIN_SEARCH_INLINE char* spdf_win_search_dup_query(const char* text) {
    size_t len;
    const char* end;
    if (!text) return spdf_win_search_dup_bytes("", 0);
    len = strlen(text);
    if (len <= SPDF_WIN_SEARCH_MAX_QUERY_BYTES) return spdf_win_search_dup_bytes(text, len);
    end = text + SPDF_WIN_SEARCH_MAX_QUERY_BYTES;
    /* back up to the start of the (possibly split) character */
    while (end > text && (*end & 0xC0) == 0x80) end--;
    return spdf_win_search_dup_bytes(text, (size_t)(end - text));
}

/* --------------------------------------------------------------------------
 * Nearest-match selection over parallel arrays in document order. Smallest page
 * distance from the visible range wins, ties broken by vertical distance from
 * the viewport centre, then document order. Returns -1 when count <= 0. */
static SPDF_WIN_SEARCH_INLINE int spdf_win_search_nearest_match(const int* pages, const double* centers, int count,
                                                                int first_visible, int last_visible,
                                                                double viewport_center_y) {
    int best_index = 0;
    int best_page_distance = INT_MAX;
    double best_vertical = DBL_MAX;
    int i;

    if (count <= 0 || !pages || !centers) return -1;
    if (last_visible < first_visible) {
        int swap = first_visible;
        first_visible = last_visible;
        last_visible = swap;
    }
    for (i = 0; i < count; ++i) {
        int page_distance = 0;
        double vertical = fabs(centers[i] - viewport_center_y);
        if (pages[i] < first_visible) page_distance = first_visible - pages[i];
        else if (pages[i] > last_visible) page_distance = pages[i] - last_visible;
        /* Strict comparisons keep the earliest (document-order) match on ties. */
        if (page_distance < best_page_distance ||
            (page_distance == best_page_distance && vertical < best_vertical)) {
            best_page_distance = page_distance;
            best_vertical = vertical;
            best_index = i;
        }
    }
    return best_index;
}

/* --------------------------------------------------------------------------
 * Scrollbar heat-map tick layout: fraction = match document-space centre y over
 * total document height, clamped to [0, 1]; the lane then pins the tick fully
 * inside its own height. */
static SPDF_WIN_SEARCH_INLINE double spdf_win_search_marker_fraction(double center_y, double document_h) {
    if (document_h <= 0.0) return 0.0;
    return spdf_win_search_clamp(center_y / document_h, 0.0, 1.0);
}

static SPDF_WIN_SEARCH_INLINE double spdf_win_search_marker_y(double fraction, double lane_h, double tick_h) {
    double y;
    fraction = spdf_win_search_clamp(fraction, 0.0, 1.0);
    if (lane_h <= tick_h) return 0.0;
    y = fraction * spdf_win_search_max(1.0, lane_h - tick_h);
    return spdf_win_search_clamp(y, 0.0, lane_h - tick_h);
}

/* --------------------------------------------------------------------------
 * Chapter attribution: a match on `page` belongs to the LAST outline entry
 * starting on or before that page; -1 before the first chapter or with no
 * outline. Binary search over the non-decreasing page array. */
static SPDF_WIN_SEARCH_INLINE int spdf_win_search_chapter_for_page(const int* chapter_pages, int chapter_count,
                                                                  int page) {
    int lo = 0;
    int hi = chapter_count - 1;
    int best = -1;

    if (!chapter_pages || chapter_count <= 0) return -1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        if (chapter_pages[mid] <= page) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return best;
}

/* --------------------------------------------------------------------------
 * Snippet: the text line backing a match. Prefer the line whose bounds (inset
 * by -2 pt) intersect the match rect, else the line whose vertical centre is
 * nearest the match centre. Returns a newly allocated, whitespace-trimmed copy
 * ("" when there are no lines). */
static SPDF_WIN_SEARCH_INLINE int spdf_win_search_rects_intersect(const spdf_rect* a, const spdf_rect* b,
                                                                 double slop) {
    return a->x0 - slop < b->x1 && b->x0 < a->x1 + slop && a->y0 - slop < b->y1 && b->y0 < a->y1 + slop;
}

/* g_strstrip in place: g_strchug + g_strchomp, which use g_ascii_isspace --
 * space, \t, \n, \v, \f, \r and nothing locale-dependent. isspace() would drop
 * a 0xA0 in a CP1252 locale and change the string, so the set is spelled out. */
static SPDF_WIN_SEARCH_INLINE int spdf_win_search_is_ascii_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

static SPDF_WIN_SEARCH_INLINE char* spdf_win_search_strstrip(char* text) {
    size_t len;
    char* start;
    if (!text) return NULL;
    start = text;
    while (*start && spdf_win_search_is_ascii_space(*start)) start++;
    if (start != text) memmove(text, start, strlen(start) + 1);
    len = strlen(text);
    while (len > 0 && spdf_win_search_is_ascii_space(text[len - 1])) text[--len] = '\0';
    return text;
}

static SPDF_WIN_SEARCH_INLINE char* spdf_win_search_snippet(const char* const* line_texts,
                                                            const spdf_rect* line_bounds, int line_count,
                                                            spdf_rect match_rect) {
    const char* best = NULL;
    double best_distance = DBL_MAX;
    double match_center_y = (match_rect.y0 + match_rect.y1) * 0.5;
    int i;

    for (i = 0; i < line_count; ++i) {
        const char* text = line_texts ? line_texts[i] : NULL;
        double distance;
        if (!text || !*text) continue;
        if (spdf_win_search_rects_intersect(&line_bounds[i], &match_rect, 2.0)) {
            best = text;
            break;
        }
        distance = fabs((line_bounds[i].y0 + line_bounds[i].y1) * 0.5 - match_center_y);
        if (distance < best_distance) {
            best_distance = distance;
            best = text;
        }
    }
    if (!best) return spdf_win_search_dup_bytes("", 0);
    return spdf_win_search_strstrip(spdf_win_search_dup_bytes(best, strlen(best)));
}

#endif /* SPDF_WIN_SEARCH_H */
