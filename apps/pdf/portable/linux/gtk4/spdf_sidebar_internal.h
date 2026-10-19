/* Pure sidebar logic for the GTK4 frontend. glib-only (no GTK includes) so
 * tests/sidebar_test.c compiles the exact shipping logic against glib alone
 * (same pattern as spdf_search_internal.h). spdf_sidebar.c is the only GTK
 * consumer.
 *
 * Ported semantics:
 *   spdf_sidebar_outline_normalize_levels — GTK3 add_sidebar_row indentation
 *       tolerated raw levels; the GTK4 tree model needs a well-formed tree,
 *       so levels are clamped to "at most one deeper than the previous row"
 *       (the classic outline fix-up; pre-order document order is preserved).
 *   spdf_sidebar_outline_child_count/child_at — tree edges over the
 *       normalized pre-order level array (children of i = following items
 *       one level deeper, stopping at the first item at i's level or above;
 *       parent -1 = virtual root).
 *   spdf_sidebar_outline_index_for_page — Mac chapterTitleForPage: the last
 *       outline entry (document order) on the largest start page <= page;
 *       same-page ties keep the deeper (or equal) level. -1 when nothing
 *       starts at or before the page.
 *   spdf_sidebar_group_append — Mac rebuildSearchSidebarItems: a divider row
 *       is emitted whenever a match's chapter differs from the previous
 *       match's chapter; documents without an outline get no dividers.
 *   spdf_sidebar_chapter_title — Mac chapterTitleForPage fallbacks:
 *       "Untitled" for a chapter with an empty title, "Document" for matches
 *       before the first chapter of an outlined document.
 *   spdf_sidebar_snippet_markup — search-result rows bold the query inside
 *       the snippet (Pango markup, first case-insensitive occurrence; regex
 *       queries that don't literally occur fall back to the plain snippet).
 */
#pragma once

#include <glib.h>
#include <string.h>

G_BEGIN_DECLS

/* --------------------------------------------------------------------------
 * Outline tree shape. Levels come straight from spdf_outline_item.level in
 * pre-order; normalization makes every parent/child edge explicit. */

static inline void spdf_sidebar_outline_normalize_levels(int* levels, int count) {
    int prev = -1;
    if (!levels) return;
    for (int i = 0; i < count; ++i) {
        int level = levels[i] < 0 ? 0 : levels[i];
        if (level > prev + 1) level = prev + 1;
        levels[i] = level;
        prev = level;
    }
}

/* Number of direct children of `parent` (-1 = virtual root) over a
 * NORMALIZED level array. */
static inline int spdf_sidebar_outline_child_count(const int* levels, int count, int parent) {
    int parent_level = parent < 0 ? -1 : levels[parent];
    int children = 0;
    if (!levels || parent >= count) return 0;
    for (int i = parent + 1; i < count; ++i) {
        if (levels[i] <= parent_level) break;
        if (levels[i] == parent_level + 1) ++children;
    }
    return children;
}

/* Pre-order index of the nth direct child of `parent` (-1 = virtual root),
 * or -1 when out of range. */
static inline int spdf_sidebar_outline_child_at(const int* levels, int count, int parent, int nth) {
    int parent_level = parent < 0 ? -1 : levels[parent];
    int seen = 0;
    if (!levels || parent >= count || nth < 0) return -1;
    for (int i = parent + 1; i < count; ++i) {
        if (levels[i] <= parent_level) break;
        if (levels[i] == parent_level + 1 && seen++ == nth) return i;
    }
    return -1;
}

/* The outline entry the reader is "in" on `page` (Mac chapterTitleForPage):
 * last entry in document order on the largest start page <= page, same-page
 * ties keep the deeper-or-equal level. -1 = before the first chapter. */
static inline int spdf_sidebar_outline_index_for_page(const int* pages, const int* levels, int count, int page) {
    int best = -1;
    int best_page = -1;
    int best_level = -1;

    if (!pages) return -1;
    for (int i = 0; i < count; ++i) {
        int level = levels && levels[i] > 0 ? levels[i] : 0;
        if (pages[i] < 0 || pages[i] > page) continue;
        if (pages[i] < best_page) continue;
        if (pages[i] == best_page && level < best_level) continue;
        best = i;
        best_page = pages[i];
        best_level = level;
    }
    return best;
}

/* --------------------------------------------------------------------------
 * Search-result grouping. Rows are appended incrementally as match batches
 * stream in ("matches-changed"); grouping only depends on the previous
 * match's chapter, so append-only building stays correct. */

typedef struct {
    gboolean is_header; /* TRUE: chapter divider; FALSE: match row */
    int value;          /* header: chapter_index (-1 = before first chapter);
                           match row: match index */
} SpdfSidebarGroupRow;

#define SPDF_SIDEBAR_NO_CHAPTER G_MININT /* *prev_chapter initializer */

/* Appends the rows for one match: a header first when its chapter differs
 * from the previous match's chapter (documents without an outline get no
 * headers), then the match row. *prev_chapter carries the grouping state. */
static inline void spdf_sidebar_group_append(GArray* rows, int* prev_chapter, int chapter_index, gboolean has_outline,
                                             int match_index) {
    SpdfSidebarGroupRow row;
    if (!rows || !prev_chapter) return;
    if (has_outline && *prev_chapter != chapter_index) {
        row.is_header = TRUE;
        row.value = chapter_index;
        g_array_append_val(rows, row);
        *prev_chapter = chapter_index;
    }
    row.is_header = FALSE;
    row.value = match_index;
    g_array_append_val(rows, row);
}

/* Header title for a chapter divider. titles = outline titles in pre-order
 * (entries may be NULL/empty). "" when the document has no outline (no
 * header is drawn then). */
static inline const char* spdf_sidebar_chapter_title(const char* const* titles, int outline_count, int chapter_index) {
    if (outline_count <= 0) return "";
    if (chapter_index < 0 || chapter_index >= outline_count || !titles) return "Document";
    return titles[chapter_index] && *titles[chapter_index] ? titles[chapter_index] : "Untitled";
}

/* --------------------------------------------------------------------------
 * Sidebar filter (Mac _sidebarFilterField, localizedCaseInsensitiveContains):
 * case-insensitive substring over UTF-8 casefolds. `needle_folded` must
 * already be casefolded (the caller folds the filter text once); an empty or
 * NULL needle matches everything. */
static inline gboolean spdf_sidebar_filter_matches(const char* haystack, const char* needle_folded) {
    char* folded;
    gboolean hit;
    if (!needle_folded || !*needle_folded) return TRUE;
    if (!haystack || !*haystack) return FALSE;
    folded = g_utf8_casefold(haystack, -1);
    hit = strstr(folded, needle_folded) != NULL;
    g_free(folded);
    return hit;
}

/* --------------------------------------------------------------------------
 * First case-insensitive occurrence of `query` in `s` (UTF-8 casefold over
 * equal character counts). Returns FALSE when the query does not literally
 * occur — e.g. regex patterns. On success, start and end bound the occurrence. */
static inline gboolean spdf_sidebar_snippet_match_range(const char* s, const char* query, const char** start,
                                                        const char** end) {
    char* folded_query = NULL;
    gboolean found = FALSE;

    if (!s || !query || !*query) return FALSE;
    folded_query = g_utf8_casefold(query, -1);
    if (*folded_query) {
        glong query_chars = g_utf8_strlen(query, -1);
        for (const char* p = s; *p; p = g_utf8_next_char(p)) {
            const char* q = p;
            glong n = 0;
            char* candidate;
            while (*q && n < query_chars) {
                q = g_utf8_next_char(q);
                ++n;
            }
            if (n < query_chars) break; /* fewer chars left than the query */
            candidate = g_utf8_casefold(p, q - p);
            found = strcmp(candidate, folded_query) == 0;
            g_free(candidate);
            if (found) {
                *start = p;
                *end = q;
                break;
            }
        }
    }
    g_free(folded_query);
    return found;
}

/* --------------------------------------------------------------------------
 * Snippet window. Port of Mac paletteSnippetRangeInLine (the sidebar search
 * rows run their line through it via findContextForQuery): keep from the 2nd
 * word before the match to the 2nd word after it — no leading line prefix,
 * just the surrounding words. When the query doesn't literally occur (regex)
 * the whole line stays; when the match doesn't overlap any word (whitespace
 * queries) a 24-character window each side is kept instead. Words are
 * maximal runs of non-whitespace. Returns a trimmed copy; caller frees. */
static inline char* spdf_sidebar_snippet_window(const char* line, const char* query) {
    const char* s = line ? line : "";
    const char* match_start;
    const char* match_end;
    const char* win_start = NULL;
    const char* win_end = NULL;
    const char* words[2] = {0}; /* starts of the last 2 words before the match */
    const char* p;
    int after = 0;

    if (!spdf_sidebar_snippet_match_range(s, query, &match_start, &match_end))
        return g_strstrip(g_strdup(s));

    /* Walk the words once, remembering the last 3 word starts up to the
     * match and extending the window until the 2nd word past the match. */
    p = s;
    while (*p) {
        const char* word_start;
        const char* word_end;
        while (*p && g_unichar_isspace(g_utf8_get_char(p))) p = g_utf8_next_char(p);
        if (!*p) break;
        word_start = p;
        while (*p && !g_unichar_isspace(g_utf8_get_char(p))) p = g_utf8_next_char(p);
        word_end = p;
        if (win_start == NULL) {
            if (word_start < match_end && match_start < word_end) {
                /* First word intersecting the match: window starts 2 words back. */
                win_start = words[1] ? words[1] : (words[0] ? words[0] : word_start);
                win_end = word_end;
            } else {
                words[1] = words[0];
                words[0] = word_start;
            }
        }
        if (win_start) {
            if (word_start < match_end && match_start < word_end) {
                win_end = word_end; /* still inside the match: reset the tail */
                after = 0;
            } else if (++after <= 2) {
                win_end = word_end;
            } else {
                break;
            }
        }
    }

    if (!win_start) {
        /* Match overlaps no word (whitespace query): 24 chars each side. */
        glong before_chars = g_utf8_strlen(s, match_start - s);
        win_start = g_utf8_offset_to_pointer(s, MAX(0, before_chars - 24));
        win_end = match_end;
        for (int i = 0; i < 24 && *win_end; ++i) win_end = g_utf8_next_char(win_end);
    }
    return g_strstrip(g_strndup(win_start, win_end - win_start));
}

/* --------------------------------------------------------------------------
 * Snippet markup: escape the snippet for Pango and bold the first
 * case-insensitive occurrence of `query` (queries that do not literally
 * occur — e.g. regex patterns — leave the snippet unbolded). Caller frees. */
static inline char* spdf_sidebar_snippet_markup(const char* snippet, const char* query) {
    const char* s = snippet ? snippet : "";
    const char* start;
    const char* end;
    char* result;
    char* pre;
    char* mid;
    char* post;

    if (!spdf_sidebar_snippet_match_range(s, query, &start, &end)) return g_markup_escape_text(s, -1);
    pre = g_markup_escape_text(s, start - s);
    mid = g_markup_escape_text(start, end - start);
    post = g_markup_escape_text(end, -1);
    result = g_strconcat(pre, "<b>", mid, "</b>", post, NULL);
    g_free(pre);
    g_free(mid);
    g_free(post);
    return result;
}

G_END_DECLS
