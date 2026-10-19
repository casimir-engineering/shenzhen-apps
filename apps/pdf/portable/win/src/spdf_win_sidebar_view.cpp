/* Building the Search section's rows from the find session. See
 * spdf_win_sidebar_view.h for what the rows are and where they go.
 *
 * REBUILT ONLY WHEN THE RESULTS CHANGED. The session's revision counter moves
 * on every batch adopted, every step and every new query; this compares that
 * one integer (and the searching flag, which changes the status line) per
 * frame and otherwise hands back the rows it already has. So a 20,000-match
 * search costs one build per batch and nothing per paint after it -- the
 * standing speed rule applied to the one place in the sidebar that could scale
 * with match count.
 *
 * THE PORTED LOGIC IS CALLED, NOT REIMPLEMENTED: grouping through
 * spdf_win_sidebar_group_append, headers through spdf_win_sidebar_chapter_title,
 * snippets through spdf_win_sidebar_snippet_window and the bold span through
 * spdf_win_sidebar_snippet_match_range -- every one of them differentially
 * tested against the GTK original.
 *
 * STRINGS LIVE IN ONE ARENA the rows point into, grown as needed and reused
 * across builds; UTF-8 in, UTF-16 out, through CP_UTF8 and never anything
 * narrower (this machine's ANSI code page is 1252, and a snippet is exactly
 * where a CJK or accented line turns up).
 *
 * Not linked into the painters' tests: the sidebar painter reads the PUBLISHED
 * view (spdf_win_sidebar_view.h's side channel) and never this builder, so a
 * test that draws the sidebar does not drag in the engine.
 */
#include "spdf_win_sidebar_view.h"

#include "spdf_win_chrome_find.h"
#include "spdf_win_sidebar_results.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct SpdfWinSidebarResultsBuilder {
    SpdfWinSidebarResultRow* rows;
    int row_count;
    int row_cap;
    /* Titles and subtitles, as offsets into `arena` while building (the arena
     * may move), resolved to pointers once the build is complete. */
    size_t* title_off;
    size_t* subtitle_off;
    wchar_t* arena;
    size_t arena_used;
    size_t arena_cap;

    unsigned built_revision;
    int built_valid;
    int built_searching;
    int built_current;
    SpdfWinSidebarResultsView view;
};

SpdfWinSidebarResultsBuilder* spdf_win_sidebar_results_builder_new(void) {
    SpdfWinSidebarResultsBuilder* b = (SpdfWinSidebarResultsBuilder*)calloc(1, sizeof(*b));
    if (b) b->view.current_row = -1;
    return b;
}

void spdf_win_sidebar_results_builder_free(SpdfWinSidebarResultsBuilder* b) {
    if (!b) return;
    free(b->rows);
    free(b->title_off);
    free(b->subtitle_off);
    free(b->arena);
    free(b);
}

namespace {

const size_t kNoString = (size_t)-1;

/* Appends `utf8` (or `len` bytes of it, len < 0 for the whole string) to the
 * arena as UTF-16 with a terminator. Returns the offset, or kNoString. */
size_t arena_put_utf8(SpdfWinSidebarResultsBuilder* b, const char* utf8, int len) {
    int need;
    size_t off;
    if (!utf8) utf8 = "";
    if (len < 0) len = (int)strlen(utf8);
    need = len > 0 ? MultiByteToWideChar(CP_UTF8, 0, utf8, len, NULL, 0) : 0;
    if (need < 0) need = 0;
    if (b->arena_used + (size_t)need + 1 > b->arena_cap) {
        size_t want = (b->arena_used + (size_t)need + 1) * 2 + 256;
        wchar_t* grown = (wchar_t*)realloc(b->arena, want * sizeof(wchar_t));
        if (!grown) return kNoString;
        b->arena = grown;
        b->arena_cap = want;
    }
    off = b->arena_used;
    if (need > 0) MultiByteToWideChar(CP_UTF8, 0, utf8, len, b->arena + off, need);
    b->arena[off + (size_t)need] = L'\0';
    b->arena_used += (size_t)need + 1;
    return off;
}

size_t arena_put_wide(SpdfWinSidebarResultsBuilder* b, const wchar_t* text) {
    size_t n = wcslen(text), off;
    if (b->arena_used + n + 1 > b->arena_cap) {
        size_t want = (b->arena_used + n + 1) * 2 + 256;
        wchar_t* grown = (wchar_t*)realloc(b->arena, want * sizeof(wchar_t));
        if (!grown) return kNoString;
        b->arena = grown;
        b->arena_cap = want;
    }
    off = b->arena_used;
    memcpy(b->arena + off, text, (n + 1) * sizeof(wchar_t));
    b->arena_used += n + 1;
    return off;
}

int reserve_rows(SpdfWinSidebarResultsBuilder* b, int want) {
    int cap;
    SpdfWinSidebarResultRow* rows;
    size_t* t;
    size_t* s;
    if (want <= b->row_cap) return 1;
    cap = b->row_cap ? b->row_cap : 64;
    while (cap < want) cap *= 2;
    rows = (SpdfWinSidebarResultRow*)realloc(b->rows, sizeof(*rows) * (size_t)cap);
    if (!rows) return 0;
    b->rows = rows;
    t = (size_t*)realloc(b->title_off, sizeof(size_t) * (size_t)cap);
    if (!t) return 0;
    b->title_off = t;
    s = (size_t*)realloc(b->subtitle_off, sizeof(size_t) * (size_t)cap);
    if (!s) return 0;
    b->subtitle_off = s;
    b->row_cap = cap;
    return 1;
}

int push_row(SpdfWinSidebarResultsBuilder* b, int kind, size_t title, size_t subtitle, int match_index,
             int bold_start, int bold_len) {
    SpdfWinSidebarResultRow* r;
    if (!reserve_rows(b, b->row_count + 1)) return 0;
    r = &b->rows[b->row_count];
    r->kind = kind;
    r->title = NULL;
    r->subtitle = NULL;
    r->match_index = match_index;
    r->bold_start = bold_start;
    r->bold_len = bold_len;
    b->title_off[b->row_count] = title;
    b->subtitle_off[b->row_count] = subtitle;
    b->row_count++;
    return 1;
}

/* UTF-16 unit count of the first `bytes` bytes of `utf8`. */
int utf16_units(const char* utf8, int bytes) {
    int n;
    if (bytes <= 0) return 0;
    n = MultiByteToWideChar(CP_UTF8, 0, utf8, bytes, NULL, 0);
    return n < 0 ? 0 : n;
}

/* mac :9509-9521: status text quotes the query. The quotes are the plain ASCII
 * ones macOS uses. */
size_t status_row(SpdfWinSidebarResultsBuilder* b, const char* prefix, const char* query, const char* suffix) {
    char text[600];
    _snprintf_s(text, sizeof(text), _TRUNCATE, "%s\"%s\"%s", prefix, query ? query : "", suffix);
    return arena_put_utf8(b, text, -1);
}

void build(SpdfWinSidebarResultsBuilder* b, SpdfWinFindSession* s, int searching) {
    int count = spdf_win_find_match_count(s);
    const char* query = spdf_win_find_query(s);
    const char* error = spdf_win_find_error(s);
    int chapter_count = spdf_win_find_chapter_count(s);
    int has_outline = chapter_count > 0;
    int prev_chapter = SPDF_WIN_SIDEBAR_NO_CHAPTER;
    const char** titles = NULL;
    int i;

    b->row_count = 0;
    b->arena_used = 0;
    b->view.current_row = -1;

    if (count <= 0) {
        size_t title;
        if (searching) title = status_row(b, "Searching for ", query, "...");
        else if (error) title = arena_put_utf8(b, error, -1);
        else if (query) title = status_row(b, "No matches for ", query, "");
        else title = arena_put_utf8(b, "No search results", -1);
        push_row(b, SPDF_WIN_SIDEBAR_RESULT_STATUS, title, kNoString, -1, -1, 0);
        return;
    }

    /* The outline titles in the array shape the ported header takes; a failed
     * allocation degrades to no headers rather than to no rows. */
    if (has_outline) {
        titles = (const char**)malloc(sizeof(char*) * (size_t)chapter_count);
        if (titles)
            for (i = 0; i < chapter_count; ++i) titles[i] = spdf_win_find_chapter_title(s, i);
        else
            has_outline = 0;
    }

    for (i = 0; i < count; ++i) {
        SpdfWinFindMatchInfo m;
        SpdfWinSidebarGroupRow group[2];
        int group_count = 0, g;
        if (!spdf_win_find_match_at(s, i, &m)) break;
        spdf_win_sidebar_group_append(group, &group_count, 2, &prev_chapter, m.chapter_index, has_outline, i);
        for (g = 0; g < group_count; ++g) {
            if (group[g].is_header) {
                const char* shown = spdf_win_sidebar_chapter_title(titles, chapter_count, group[g].value);
                push_row(b, SPDF_WIN_SIDEBAR_RESULT_HEADER, arena_put_utf8(b, shown, -1), kNoString, -1, -1, 0);
            } else {
                char subtitle[96];
                char* window = spdf_win_sidebar_snippet_window(m.snippet, query);
                const char* shown = window && window[0] ? window : (query ? query : "Match");
                const char* bs = NULL;
                const char* be = NULL;
                int bold_start = -1, bold_len = 0;
                size_t title;
                if (spdf_win_sidebar_snippet_match_range(shown, query, &bs, &be)) {
                    bold_start = utf16_units(shown, (int)(bs - shown));
                    bold_len = utf16_units(bs, (int)(be - bs));
                }
                title = arena_put_utf8(b, shown, -1);
                free(window);
                _snprintf_s(subtitle, sizeof(subtitle), _TRUNCATE, "Page %d - match %d of %d", m.page + 1, i + 1,
                            count);
                if (i == spdf_win_find_match_index(s)) b->view.current_row = b->row_count;
                push_row(b, SPDF_WIN_SIDEBAR_RESULT_MATCH, title, arena_put_utf8(b, subtitle, -1), i, bold_start,
                         bold_len);
            }
        }
    }
    free((void*)titles);
}

void resolve_pointers(SpdfWinSidebarResultsBuilder* b) {
    int i;
    for (i = 0; i < b->row_count; ++i) {
        b->rows[i].title = b->title_off[i] == kNoString ? L"" : b->arena + b->title_off[i];
        b->rows[i].subtitle = b->subtitle_off[i] == kNoString ? NULL : b->arena + b->subtitle_off[i];
    }
    b->view.rows = b->rows;
    b->view.row_count = b->row_count;
}

/* Keep the current row inside the list, moving as little as possible (the
 * scroll-to-selection an NSTableView performs). */
void reveal_current(SpdfWinSidebarResultsBuilder* b, float list_h, float dpi) {
    float top, bottom, max_scroll;
    if (b->view.current_row < 0 || !(list_h > 0.0f)) return;
    top = spdf_win_sidebar_results_row_top(&b->view, b->view.current_row, dpi);
    bottom = top + spdf_win_sidebar_result_row_h(b->rows[b->view.current_row].kind, dpi);
    if (top < b->view.scroll_y) b->view.scroll_y = top;
    else if (bottom > b->view.scroll_y + list_h) b->view.scroll_y = bottom - list_h;
    max_scroll = spdf_win_sidebar_results_max_scroll(&b->view, list_h, dpi);
    if (b->view.scroll_y > max_scroll) b->view.scroll_y = max_scroll;
    if (b->view.scroll_y < 0.0f) b->view.scroll_y = 0.0f;
}

} /* namespace */

const SpdfWinSidebarResultsView* spdf_win_sidebar_results_build(SpdfWinSidebarResultsBuilder* b,
                                                                SpdfWinFindSession* s, int searching, float list_h_px,
                                                                float dpi_scale) {
    unsigned revision = spdf_win_find_revision(s);
    int current = spdf_win_find_match_index(s);
    if (!b) return NULL;
    if (!s) {
        b->row_count = 0;
        b->view.rows = NULL;
        b->view.row_count = 0;
        b->view.current_row = -1;
        b->view.scroll_y = 0.0f;
        b->built_valid = 0;
        return &b->view;
    }
    if (!b->built_valid || b->built_revision != revision || b->built_searching != (searching ? 1 : 0)) {
        int query_changed = !b->built_valid || b->built_current < 0;
        build(b, s, searching);
        resolve_pointers(b);
        b->built_valid = 1;
        b->built_revision = revision;
        b->built_searching = searching ? 1 : 0;
        if (query_changed) b->view.scroll_y = 0.0f;
        if (current != b->built_current || query_changed) reveal_current(b, list_h_px, dpi_scale);
        b->built_current = current;
    }
    /* The list may have been resized since the build; the offset must stay
     * inside it. */
    {
        float max_scroll = spdf_win_sidebar_results_max_scroll(&b->view, list_h_px, dpi_scale);
        if (b->view.scroll_y > max_scroll) b->view.scroll_y = max_scroll;
        if (b->view.scroll_y < 0.0f) b->view.scroll_y = 0.0f;
    }
    return &b->view;
}

int spdf_win_sidebar_results_scroll_by(SpdfWinSidebarResultsBuilder* b, float dy, float list_h_px, float dpi_scale) {
    float before, max_scroll;
    if (!b || !b->built_valid) return 0;
    before = b->view.scroll_y;
    max_scroll = spdf_win_sidebar_results_max_scroll(&b->view, list_h_px, dpi_scale);
    b->view.scroll_y = spdf_win_chrome_max(0.0f, spdf_win_chrome_min(max_scroll, b->view.scroll_y + dy));
    return fabsf(b->view.scroll_y - before) > 0.01f;
}
