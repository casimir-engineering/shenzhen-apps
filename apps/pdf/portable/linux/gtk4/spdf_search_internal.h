/* Pure search logic for the GTK4 frontend. glib-only (no GTK includes) so the
 * linux/gtk4/tests sources compile the exact shipping logic against glib
 * alone (same pattern as spdf_docview_internal.h). spdf_search.c is the only
 * GTK consumer.
 *
 * Ported semantics:
 *   spdf_search_match_list_*      <- GTK3 append_find_match/clear_find_results
 *                                    (portable/linux/ShenzhenPDFGtk.c @1948,
 *                                    incl. the MAX_FIND_MATCHES 20000 cap)
 *   spdf_search_counter_text      <- GTK3 update_find_controls ("", "0 / 0",
 *                                    "N / M") @1988
 *   spdf_search_dup_query         <- GTK3 dup_limited_utf8 + MAX_FIND_QUERY_BYTES
 *   spdf_search_nearest_match     <- Mac spdf_nearest_find_match_index
 *                                    (SPDFMacFindNearest.mm): page distance from
 *                                    the visible range first, then vertical
 *                                    distance from the viewport center, then
 *                                    document order
 *   spdf_search_marker_fraction/y <- Mac findScrollbarMarkers (proportional
 *                                    document-space layout, ShenzhenPDFMac.mm
 *                                    @6188) + GTK3 draw_find_marker tick
 *                                    clamping (3px ticks pinned inside the lane)
 *   spdf_search_chapter_for_page  <- Mac sidebar chapter grouping: a match
 *                                    belongs to the last outline entry (pre-order)
 *                                    that starts on or before its page
 *   spdf_search_snippet           <- Mac findContextForQuery (ShenzhenPDFMac.mm
 *                                    @10398): the text line intersecting the
 *                                    match rect (2pt slop), else the line whose
 *                                    vertical center is nearest
 */
#pragma once

#include <glib.h>
#include <math.h>
#include <string.h>

#include "shenzhen_pdf_core.h"

G_BEGIN_DECLS

#define SPDF_SEARCH_MAX_QUERY_BYTES 2048 /* GTK3 MAX_FIND_QUERY_BYTES */
#define SPDF_SEARCH_MAX_MATCHES 20000    /* GTK3 MAX_FIND_MATCHES */
#define SPDF_SEARCH_MARKER_TICK_H 3.0    /* GTK3 draw_find_marker mark_height */

/* One search hit. rect is in page space (PDF points, y down as the core
 * returns it); snippet is the surrounding text line (owned by the list);
 * chapter_index is the pre-order outline index the match falls under, -1
 * before the first chapter / without an outline. */
typedef struct {
    int page;
    spdf_rect rect;
    char* snippet;
    int chapter_index;
} SpdfSearchMatch;

typedef struct {
    GArray* matches; /* SpdfSearchMatch; snippets owned */
} SpdfSearchMatchList;

static inline void spdf_search_match_list_init(SpdfSearchMatchList* list) {
    if (!list) return;
    list->matches = g_array_new(FALSE, TRUE, sizeof(SpdfSearchMatch));
}

static inline guint spdf_search_match_list_count(const SpdfSearchMatchList* list) {
    return list && list->matches ? list->matches->len : 0;
}

static inline const SpdfSearchMatch* spdf_search_match_list_get(const SpdfSearchMatchList* list, guint index) {
    if (!list || !list->matches || index >= list->matches->len) return NULL;
    return &g_array_index(list->matches, SpdfSearchMatch, index);
}

/* Appends a match, taking ownership of snippet (freed even when the cap
 * rejects the match). Returns FALSE at the MAX_FIND_MATCHES cap. */
static inline gboolean spdf_search_match_list_append(SpdfSearchMatchList* list, int page, spdf_rect rect,
                                                     char* snippet, int chapter_index) {
    SpdfSearchMatch match;
    if (!list || !list->matches || list->matches->len >= SPDF_SEARCH_MAX_MATCHES) {
        g_free(snippet);
        return FALSE;
    }
    match.page = page;
    match.rect = rect;
    match.snippet = snippet;
    match.chapter_index = chapter_index;
    g_array_append_val(list->matches, match);
    return TRUE;
}

static inline void spdf_search_match_list_clear(SpdfSearchMatchList* list) {
    if (!list || !list->matches) return;
    for (guint i = 0; i < list->matches->len; ++i) g_free(g_array_index(list->matches, SpdfSearchMatch, i).snippet);
    g_array_set_size(list->matches, 0);
}

static inline void spdf_search_match_list_deinit(SpdfSearchMatchList* list) {
    if (!list || !list->matches) return;
    spdf_search_match_list_clear(list);
    g_array_free(list->matches, TRUE);
    list->matches = NULL;
}

/* Moves every match of src onto the end of dst (batch delivery from the
 * worker); src is left empty but initialized. Ownership of snippets moves. */
static inline void spdf_search_match_list_steal_into(SpdfSearchMatchList* dst, SpdfSearchMatchList* src) {
    if (!dst || !dst->matches || !src || !src->matches) return;
    for (guint i = 0; i < src->matches->len; ++i) {
        SpdfSearchMatch* m = &g_array_index(src->matches, SpdfSearchMatch, i);
        if (dst->matches->len >= SPDF_SEARCH_MAX_MATCHES) {
            g_free(m->snippet);
            continue;
        }
        g_array_append_val(dst->matches, *m);
    }
    g_array_set_size(src->matches, 0); /* snippets now owned by dst */
}

/* --------------------------------------------------------------------------
 * Counter string. GTK3 update_find_controls: hidden/empty without a query,
 * "0 / 0" for a query without matches, "current+1 / total" otherwise. */
static inline void spdf_search_counter_text(char* buf, gsize len, gboolean has_query, int current, int total) {
    if (!buf || len == 0) return;
    if (!has_query) g_strlcpy(buf, "", len);
    else if (total <= 0) g_strlcpy(buf, "0 / 0", len);
    else if (current < 0) g_snprintf(buf, len, "%d", total); /* searching / no selection yet */
    else g_snprintf(buf, len, "%d / %d", current + 1, total);
}

/* --------------------------------------------------------------------------
 * Query duplication with the GTK3 byte cap, truncated on a UTF-8 character
 * boundary (port of dup_limited_utf8). Never returns NULL. */
static inline char* spdf_search_dup_query(const char* text) {
    gsize len;
    const char* end;
    if (!text) return g_strdup("");
    len = strlen(text);
    if (len <= SPDF_SEARCH_MAX_QUERY_BYTES) return g_strdup(text);
    end = text + SPDF_SEARCH_MAX_QUERY_BYTES;
    /* back up to the start of the (possibly split) character */
    while (end > text && (*end & 0xC0) == 0x80) end--;
    return g_strndup(text, (gsize)(end - text));
}

/* --------------------------------------------------------------------------
 * Nearest-match selection. Port of Mac spdf_nearest_find_match_index over
 * parallel arrays in document order:
 *   pages[i]   — the page match i sits on;
 *   centers[i] — the match's vertical center in document space (y down);
 *   first/last_visible — inclusive page range intersecting the viewport;
 *   viewport_center_y — viewport vertical center in the same document space.
 * Smallest page distance from the visible range wins, ties broken by vertical
 * distance, then document order. Returns -1 when count <= 0. */
static inline int spdf_search_nearest_match(const int* pages, const double* centers, int count, int first_visible,
                                            int last_visible, double viewport_center_y) {
    int best_index = 0;
    int best_page_distance = G_MAXINT;
    double best_vertical = G_MAXDOUBLE;

    if (count <= 0 || !pages || !centers) return -1;
    if (last_visible < first_visible) {
        int swap = first_visible;
        first_visible = last_visible;
        last_visible = swap;
    }
    for (int i = 0; i < count; ++i) {
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
 * Scrollbar heat-map tick layout. Mac findScrollbarMarkers places each tick
 * proportionally: fraction = match document-space center y / total document
 * height, clamped to [0, 1]. The lane then pins the (GTK3 3px) tick fully
 * inside its height. */
static inline double spdf_search_marker_fraction(double center_y, double document_h) {
    if (document_h <= 0.0) return 0.0;
    return CLAMP(center_y / document_h, 0.0, 1.0);
}

static inline double spdf_search_marker_y(double fraction, double lane_h, double tick_h) {
    double y;
    fraction = CLAMP(fraction, 0.0, 1.0);
    if (lane_h <= tick_h) return 0.0;
    y = fraction * MAX(1.0, lane_h - tick_h);
    return CLAMP(y, 0.0, lane_h - tick_h);
}

/* --------------------------------------------------------------------------
 * Chapter attribution for grouping (Mac sidebar model): given the outline
 * items' start pages in pre-order, a match on `page` belongs to the LAST
 * entry starting on or before that page; -1 before the first chapter or with
 * no outline. Binary search over the non-decreasing page array. */
static inline int spdf_search_chapter_for_page(const int* chapter_pages, int chapter_count, int page) {
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
 * Snippet: the text line backing a match. Port of Mac findContextForQuery:
 * prefer the line whose bounds (inset by -2pt) intersect the match rect,
 * else the line whose vertical center is nearest the match center. Returns a
 * newly allocated, whitespace-trimmed copy ("" when there are no lines). */
static inline gboolean spdf_search_rects_intersect(const spdf_rect* a, const spdf_rect* b, double slop) {
    return a->x0 - slop < b->x1 && b->x0 < a->x1 + slop && a->y0 - slop < b->y1 && b->y0 < a->y1 + slop;
}

static inline char* spdf_search_snippet(const char* const* line_texts, const spdf_rect* line_bounds, int line_count,
                                        spdf_rect match_rect) {
    const char* best = NULL;
    double best_distance = G_MAXDOUBLE;
    double match_center_y = (match_rect.y0 + match_rect.y1) * 0.5;

    for (int i = 0; i < line_count; ++i) {
        const char* text = line_texts ? line_texts[i] : NULL;
        double distance;
        if (!text || !*text) continue;
        if (spdf_search_rects_intersect(&line_bounds[i], &match_rect, 2.0)) {
            best = text;
            break;
        }
        distance = fabs((line_bounds[i].y0 + line_bounds[i].y1) * 0.5 - match_center_y);
        if (distance < best_distance) {
            best_distance = distance;
            best = text;
        }
    }
    if (!best) return g_strdup("");
    return g_strstrip(g_strdup(best));
}

G_END_DECLS
