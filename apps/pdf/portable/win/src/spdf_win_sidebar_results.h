/* spdf_win_sidebar_results.h — the sidebar's pure logic, ported from the GTK4
 * frontend: outline tree shape, chapter attribution, search-result grouping,
 * the snippet window and the query-in-snippet range.
 *
 * TRANSCRIPTION, NOT A REWRITE. Every function below is the corresponding
 * `static inline` in portable/linux/gtk4/spdf_sidebar_internal.h with glib's
 * types and containers replaced and NOTHING ELSE changed -- same branches, same
 * comparison order, same edge behaviour. That header carries each rule's
 * provenance back to the macOS sources (chapterTitleForPage,
 * rebuildSearchSidebarItems, paletteSnippetRangeInLine, the "Untitled" /
 * "Document" fallbacks); it is not repeated here, because two copies of a
 * provenance note is how one goes stale. Read that file beside this one.
 *
 * WHY A PORT AT ALL, given the original is toolkit-free: it is glib-free, not
 * dependency-free. It needs GArray, g_utf8_* iteration and casefolding,
 * g_unichar_isspace, g_markup_escape_text and g_strconcat. Same trade
 * spdf_win_search.h made against spdf_search_internal.h, checked the same way:
 *
 *   portable\win\tests\sidebar-differential-native.cmd
 *
 * compiles the REAL GTK header (under portable/win/tests/glib_shim_sidebar) into
 * the same binary as this one and compares every function for EXACT equality.
 *
 * THE FOUR DIFFERENCES, all in the container or the platform and all deliberate:
 *
 *   1. spdf_win_sidebar_group_append writes into an explicit array with a count
 *      and a capacity where the original appends to a GArray. glib aborts on
 *      OOM; this returns how many rows it wrote and stops at the capacity.
 *   2. Casefolding. g_utf8_casefold performs full Unicode case folding; the
 *      Windows spelling here is LCMapStringEx(LCMAP_LOWERCASE) over UTF-16,
 *      which is simple lowercasing. The shim gives the GTK side THIS SAME
 *      function, so the differential checks the structural logic -- the word
 *      window, the ranges, the escaping -- exactly, and the fold itself is
 *      equal by construction. What it does NOT check is the fold; that is
 *      stated here rather than hidden behind a green run.
 *   3. g_unichar_isspace is spelled out as glib's own set -- the Zs/Zl/Zp
 *      categories plus \t \n \v \f \r -- so a CP1252 locale's isspace() cannot
 *      change it.
 *   4. The UTF-8 iteration helpers (next_char, get_char, strlen with a byte cap,
 *      offset_to_pointer) reproduce glib's non-validating skip table. Invalid
 *      input is walked the way glib walks it, byte for byte.
 *
 * spdf_win_sidebar_snippet_markup produces Pango markup, which nothing on
 * Windows renders. It is ported anyway so the file is a complete transcription
 * the differential can check whole; the Windows sidebar uses
 * spdf_win_sidebar_snippet_match_range to bold the same span in DirectWrite.
 *
 * PURE, HEADER-ONLY, C and C++ under MSVC. The glib replacements -- the UTF-8
 * walkers, the whitespace set, the casefold -- are in spdf_win_sidebar_utf8.h,
 * so this file is the transcription and that one is the platform.
 */
#ifndef SPDF_WIN_SIDEBAR_RESULTS_H
#define SPDF_WIN_SIDEBAR_RESULTS_H

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "spdf_win_search.h"       /* spdf_win_search_strstrip, spdf_win_search_dup_bytes */
#include "spdf_win_sidebar_utf8.h" /* the g_utf8_* / g_unichar_* / casefold replacements */

#ifdef __cplusplus
extern "C" {
#endif

/* --------------------------------------------------------------------------
 * Outline tree shape. Levels come straight from spdf_outline_item.level in
 * pre-order; normalization makes every parent/child edge explicit. */

static SPDF_WIN_SR_INLINE void spdf_win_sidebar_outline_normalize_levels(int* levels, int count) {
    int prev = -1;
    int i;
    if (!levels) return;
    for (i = 0; i < count; ++i) {
        int level = levels[i] < 0 ? 0 : levels[i];
        if (level > prev + 1) level = prev + 1;
        levels[i] = level;
        prev = level;
    }
}

/* Number of direct children of `parent` (-1 = virtual root) over a
 * NORMALIZED level array. */
static SPDF_WIN_SR_INLINE int spdf_win_sidebar_outline_child_count(const int* levels, int count, int parent) {
    int parent_level = parent < 0 ? -1 : levels[parent];
    int children = 0;
    int i;
    if (!levels || parent >= count) return 0;
    for (i = parent + 1; i < count; ++i) {
        if (levels[i] <= parent_level) break;
        if (levels[i] == parent_level + 1) ++children;
    }
    return children;
}

/* Pre-order index of the nth direct child of `parent` (-1 = virtual root),
 * or -1 when out of range. */
static SPDF_WIN_SR_INLINE int spdf_win_sidebar_outline_child_at(const int* levels, int count, int parent, int nth) {
    int parent_level = parent < 0 ? -1 : levels[parent];
    int seen = 0;
    int i;
    if (!levels || parent >= count || nth < 0) return -1;
    for (i = parent + 1; i < count; ++i) {
        if (levels[i] <= parent_level) break;
        if (levels[i] == parent_level + 1 && seen++ == nth) return i;
    }
    return -1;
}

/* The outline entry the reader is "in" on `page` (Mac chapterTitleForPage):
 * last entry in document order on the largest start page <= page, same-page
 * ties keep the deeper-or-equal level. -1 = before the first chapter. */
static SPDF_WIN_SR_INLINE int spdf_win_sidebar_outline_index_for_page(const int* pages, const int* levels, int count,
                                                                      int page) {
    int best = -1;
    int best_page = -1;
    int best_level = -1;
    int i;

    if (!pages) return -1;
    for (i = 0; i < count; ++i) {
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
 * stream in; grouping only depends on the previous match's chapter, so
 * append-only building stays correct. */

typedef struct SpdfWinSidebarGroupRow {
    int is_header; /* 1: chapter divider; 0: match row */
    int value;     /* header: chapter_index (-1 = before first chapter);
                      match row: match index */
} SpdfWinSidebarGroupRow;

#define SPDF_WIN_SIDEBAR_NO_CHAPTER INT_MIN /* *prev_chapter initializer */

/* Appends the rows for one match: a header first when its chapter differs
 * from the previous match's chapter (documents without an outline get no
 * headers), then the match row. *prev_chapter carries the grouping state.
 * Returns how many rows were written (0 when `rows` is full). */
static SPDF_WIN_SR_INLINE int spdf_win_sidebar_group_append(SpdfWinSidebarGroupRow* rows, int* count, int capacity,
                                                            int* prev_chapter, int chapter_index, int has_outline,
                                                            int match_index) {
    int written = 0;
    if (!rows || !count || !prev_chapter) return 0;
    if (has_outline && *prev_chapter != chapter_index) {
        if (*count >= capacity) return written;
        rows[*count].is_header = 1;
        rows[*count].value = chapter_index;
        (*count)++;
        written++;
        *prev_chapter = chapter_index;
    }
    if (*count >= capacity) return written;
    rows[*count].is_header = 0;
    rows[*count].value = match_index;
    (*count)++;
    written++;
    return written;
}

/* Header title for a chapter divider. titles = outline titles in pre-order
 * (entries may be NULL/empty). "" when the document has no outline (no
 * header is drawn then). */
static SPDF_WIN_SR_INLINE const char* spdf_win_sidebar_chapter_title(const char* const* titles, int outline_count,
                                                                     int chapter_index) {
    if (outline_count <= 0) return "";
    if (chapter_index < 0 || chapter_index >= outline_count || !titles) return "Document";
    return titles[chapter_index] && *titles[chapter_index] ? titles[chapter_index] : "Untitled";
}

/* --------------------------------------------------------------------------
 * Sidebar filter (Mac _sidebarFilterField, localizedCaseInsensitiveContains):
 * case-insensitive substring over UTF-8 casefolds. `needle_folded` must
 * already be casefolded (the caller folds the filter text once); an empty or
 * NULL needle matches everything. */
static SPDF_WIN_SR_INLINE int spdf_win_sidebar_filter_matches(const char* haystack, const char* needle_folded) {
    char* folded;
    int hit;
    if (!needle_folded || !*needle_folded) return 1;
    if (!haystack || !*haystack) return 0;
    folded = spdf_win_sidebar_casefold(haystack, -1);
    if (!folded) return 0;
    hit = strstr(folded, needle_folded) != NULL;
    free(folded);
    return hit;
}

/* --------------------------------------------------------------------------
 * First case-insensitive occurrence of `query` in `s` (UTF-8 casefold over
 * equal character counts). Returns 0 when the query does not literally
 * occur -- e.g. regex patterns. On success, start and end bound the occurrence. */
static SPDF_WIN_SR_INLINE int spdf_win_sidebar_snippet_match_range(const char* s, const char* query,
                                                                   const char** start, const char** end) {
    char* folded_query = NULL;
    int found = 0;

    if (!s || !query || !*query) return 0;
    folded_query = spdf_win_sidebar_casefold(query, -1);
    if (!folded_query) return 0;
    if (*folded_query) {
        long query_chars = spdf_win_sidebar_utf8_strlen(query, -1);
        const char* p;
        for (p = s; *p; p = spdf_win_sidebar_utf8_next(p)) {
            const char* q = p;
            long n = 0;
            char* candidate;
            while (*q && n < query_chars) {
                q = spdf_win_sidebar_utf8_next(q);
                ++n;
            }
            if (n < query_chars) break; /* fewer chars left than the query */
            candidate = spdf_win_sidebar_casefold(p, (long)(q - p));
            found = candidate && strcmp(candidate, folded_query) == 0;
            free(candidate);
            if (found) {
                *start = p;
                *end = q;
                break;
            }
        }
    }
    free(folded_query);
    return found;
}

/* --------------------------------------------------------------------------
 * Snippet window. Port of Mac paletteSnippetRangeInLine (the sidebar search
 * rows run their line through it via findContextForQuery): keep from the 2nd
 * word before the match to the 2nd word after it -- no leading line prefix,
 * just the surrounding words. When the query doesn't literally occur (regex)
 * the whole line stays; when the match doesn't overlap any word (whitespace
 * queries) a 24-character window each side is kept instead. Words are
 * maximal runs of non-whitespace. Returns a trimmed copy; caller frees. */
static SPDF_WIN_SR_INLINE char* spdf_win_sidebar_snippet_window(const char* line, const char* query) {
    const char* s = line ? line : "";
    const char* match_start = NULL;
    const char* match_end = NULL;
    const char* win_start = NULL;
    const char* win_end = NULL;
    const char* words[2] = {0}; /* starts of the last 2 words before the match */
    const char* p;
    int after = 0;

    if (!spdf_win_sidebar_snippet_match_range(s, query, &match_start, &match_end))
        return spdf_win_search_strstrip(spdf_win_search_dup_bytes(s, strlen(s)));

    /* Walk the words once, remembering the last 3 word starts up to the
     * match and extending the window until the 2nd word past the match. */
    p = s;
    while (*p) {
        const char* word_start;
        const char* word_end;
        while (*p && spdf_win_sidebar_unichar_isspace(spdf_win_sidebar_utf8_get(p))) p = spdf_win_sidebar_utf8_next(p);
        if (!*p) break;
        word_start = p;
        while (*p && !spdf_win_sidebar_unichar_isspace(spdf_win_sidebar_utf8_get(p)))
            p = spdf_win_sidebar_utf8_next(p);
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
        long before_chars = spdf_win_sidebar_utf8_strlen(s, (long)(match_start - s));
        int i;
        win_start = spdf_win_sidebar_utf8_offset_to_pointer(s, before_chars - 24 > 0 ? before_chars - 24 : 0);
        win_end = match_end;
        for (i = 0; i < 24 && *win_end; ++i) win_end = spdf_win_sidebar_utf8_next(win_end);
    }
    return spdf_win_search_strstrip(spdf_win_search_dup_bytes(win_start, (size_t)(win_end - win_start)));
}

/* --------------------------------------------------------------------------
 * Snippet markup: escape the snippet for Pango and bold the first
 * case-insensitive occurrence of `query` (queries that do not literally
 * occur -- e.g. regex patterns -- leave the snippet unbolded). Caller frees.
 *
 * spdf_win_sidebar_markup_escape is g_markup_escape_text (glib/gmarkup.c
 * append_escaped_text): the five entities, and the control ranges glib writes
 * as numeric references. `length` < 0 means NUL-terminated. */
static SPDF_WIN_SR_INLINE char* spdf_win_sidebar_markup_escape(const char* text, long length) {
    const char* p;
    const char* end;
    size_t cap, n = 0;
    char* out;

    if (!text) text = "";
    if (length < 0) length = (long)strlen(text);
    end = text + length;
    cap = (size_t)length * 6 + 16; /* "&quot;" is the longest expansion, "&#x9f;" the longest reference */
    out = (char*)malloc(cap);
    if (!out) return NULL;
    p = text;
    while (p < end) {
        const char* next = spdf_win_sidebar_utf8_next(p);
        unsigned c = spdf_win_sidebar_utf8_get(p);
        const char* rep = NULL;
        char ref[16];
        if (next > end) next = end;
        switch (*p) {
            case '&': rep = "&amp;"; break;
            case '<': rep = "&lt;"; break;
            case '>': rep = "&gt;"; break;
            case '\'': rep = "&apos;"; break;
            case '"': rep = "&quot;"; break;
            default:
                if ((0x1 <= c && c <= 0x8) || (0xb <= c && c <= 0xc) || (0xe <= c && c <= 0x1f) ||
                    (0x7f <= c && c <= 0x84) || (0x86 <= c && c <= 0x9f)) {
                    _snprintf_s(ref, sizeof(ref), _TRUNCATE, "&#x%x;", c);
                    rep = ref;
                }
                break;
        }
        if (rep) {
            size_t rl = strlen(rep);
            if (n + rl + 1 > cap) break;
            memcpy(out + n, rep, rl);
            n += rl;
        } else {
            size_t cl = (size_t)(next - p);
            if (n + cl + 1 > cap) break;
            memcpy(out + n, p, cl);
            n += cl;
        }
        p = next;
    }
    out[n] = '\0';
    return out;
}

static SPDF_WIN_SR_INLINE char* spdf_win_sidebar_snippet_markup(const char* snippet, const char* query) {
    const char* s = snippet ? snippet : "";
    const char* start = NULL;
    const char* end = NULL;
    char* result;
    char* pre;
    char* mid;
    char* post;
    size_t len;

    if (!spdf_win_sidebar_snippet_match_range(s, query, &start, &end)) return spdf_win_sidebar_markup_escape(s, -1);
    pre = spdf_win_sidebar_markup_escape(s, (long)(start - s));
    mid = spdf_win_sidebar_markup_escape(start, (long)(end - start));
    post = spdf_win_sidebar_markup_escape(end, -1);
    if (!pre || !mid || !post) {
        free(pre);
        free(mid);
        free(post);
        return NULL;
    }
    len = strlen(pre) + 3 + strlen(mid) + 4 + strlen(post);
    result = (char*)malloc(len + 1);
    if (result) {
        strcpy_s(result, len + 1, pre);
        strcat_s(result, len + 1, "<b>");
        strcat_s(result, len + 1, mid);
        strcat_s(result, len + 1, "</b>");
        strcat_s(result, len + 1, post);
    }
    free(pre);
    free(mid);
    free(post);
    return result;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SIDEBAR_RESULTS_H */
