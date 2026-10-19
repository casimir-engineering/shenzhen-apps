/* spdf_win_palette_filter.h — the command palette's filtering and ranking, as
 * a transcription of the pure half of portable/linux/gtk4/spdf_palette.c
 * (lines 42-251, the part that compiles glib-only under SPDF_PALETTE_TESTING).
 *
 * PORTED, NOT RE-DERIVED. portable/docs/windows-port-plan.md 2.3: the GTK4
 * frontend factored its reasoning out of its widgets and pinned it
 * (tests/palette_filter_test.c), and that reasoning is itself a port of
 * SPDFMacPaletteResults.mm, so the three frontends rank the same query the same
 * way. Every function below names the GTK function it transcribes, and
 * portable/win/tests/palette_differential.c compiles the GTK original beside
 * this header in ONE MSVC binary and asserts exact equality over the same
 * inputs -- so a difference can only be a transcription error.
 *
 * WHAT DIFFERS, DELIBERATELY, AND WHY IT IS OUTSIDE THE DIFFERENTIAL'S INPUTS:
 *   - a path's last component splits on '\' as well as '/', because Windows
 *     paths do (GTK's strrchr(path, '/') would treat "C:\a\b.pdf" as one
 *     component);
 *   - the canonical form used for deduplication folds ASCII case and normalises
 *     separators, because NTFS paths are case-insensitive; GTK's
 *     g_canonicalize_filename is case-preserving on a case-sensitive
 *     filesystem. The differential feeds POSIX-style paths with no case-only
 *     duplicates, where both rules agree.
 *   - nothing here allocates: the GTK functions that return a malloc'd string
 *     (breadcrumb, snippet) write into a caller's buffer instead. Same bytes.
 *
 * Header-only, static, toolkit-free, C. Included by the palette model and by
 * the tests.
 */
#ifndef SPDF_WIN_PALETTE_FILTER_H
#define SPDF_WIN_PALETTE_FILTER_H

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_PF_INLINE static __inline
#else
#define SPDF_WIN_PF_INLINE static inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Sections in display order (spdf_palette.h SpdfPaletteSection; the mac's
 * refreshPaletteResults order, Recents being the GTK4 extra). */
typedef enum spdf_win_palette_section {
    SPDF_WIN_PALETTE_SECTION_OPEN_DOCS = 0,
    SPDF_WIN_PALETTE_SECTION_FAVORITES,
    SPDF_WIN_PALETTE_SECTION_COMMANDS,
    SPDF_WIN_PALETTE_SECTION_RECENTS
} spdf_win_palette_section;

#define SPDF_WIN_PALETTE_SNIPPET_CONTEXT_BYTES 24

/* glib's g_ascii_* set, spelled out so no locale can change a comparison. */
SPDF_WIN_PF_INLINE int spdf_win_pf_lower(int c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; }
SPDF_WIN_PF_INLINE int spdf_win_pf_isalnum(int c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
SPDF_WIN_PF_INLINE int spdf_win_pf_isspace(int c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

/* palette_ascii_word_boundary */
SPDF_WIN_PF_INLINE int spdf_win_pf_word_boundary(const char* haystack, int index) {
    return index == 0 || !spdf_win_pf_isalnum((unsigned char)haystack[index - 1]);
}

/* spdf_palette_fuzzy_score: -1 when query is not a case-insensitive ASCII
 * subsequence of haystack; otherwise >= 0. +1 per matched byte, +3 on a word
 * boundary, +2 when it follows the previous match; gaps between first and last
 * match -1 each (capped 8), bytes skipped before the first match -1 each
 * (capped 3). An empty query scores 0 against anything. */
SPDF_WIN_PF_INLINE int spdf_win_palette_fuzzy_score(const char* query, const char* haystack) {
    const char* q;
    const char* h;
    int score = 0, gap = 0, lead = 0, index = 0;
    int last_match = -2;

    if (!query || !*query) return 0;
    if (!haystack || !*haystack) return -1;
    q = query;
    for (h = haystack; *h && *q; ++h, ++index) {
        if (spdf_win_pf_lower((unsigned char)*h) == spdf_win_pf_lower((unsigned char)*q)) {
            score += 1;
            if (spdf_win_pf_word_boundary(haystack, index)) score += 3;
            if (index == last_match + 1) score += 2;
            last_match = index;
            ++q;
        } else if (last_match >= 0) {
            ++gap;
        } else {
            ++lead;
        }
    }
    if (*q) return -1;
    score -= gap < 8 ? gap : 8;
    score -= lead < 3 ? lead : 3;
    return score > 0 ? score : 0;
}

typedef struct SpdfWinPaletteCommand {
    int command;            /* the spdf_win_command this row runs */
    const char* title;      /* UTF-8, mnemonic stripped */
    const char* accel;      /* what the menu prints, UTF-8, or NULL */
    const char* breadcrumb; /* "File ▸ Open..." or NULL */
    int enabled;
    int toggled;
} SpdfWinPaletteCommand;

typedef struct SpdfWinPaletteMatch {
    int index;
    int score;
} SpdfWinPaletteMatch;

/* palette_match_compare: score descending, then table order. */
SPDF_WIN_PF_INLINE int spdf_win_pf_match_compare(const void* a, const void* b) {
    const SpdfWinPaletteMatch* ma = (const SpdfWinPaletteMatch*)a;
    const SpdfWinPaletteMatch* mb = (const SpdfWinPaletteMatch*)b;
    if (ma->score != mb->score) return mb->score - ma->score;
    return ma->index - mb->index;
}

/* spdf_palette_filter_commands */
SPDF_WIN_PF_INLINE int spdf_win_palette_filter_commands(const SpdfWinPaletteCommand* commands, int count,
                                                        const char* query, SpdfWinPaletteMatch* out, int out_max) {
    int filtered = query && *query;
    int n = 0, i;

    if (!commands || !out || out_max <= 0) return 0;
    for (i = 0; i < count && n < out_max; ++i) {
        int score = 0;
        if (!commands[i].enabled || !commands[i].title || !*commands[i].title) continue;
        if (filtered) {
            int crumb_score = spdf_win_palette_fuzzy_score(query, commands[i].breadcrumb);
            score = spdf_win_palette_fuzzy_score(query, commands[i].title);
            score = score > crumb_score ? score : crumb_score;
            if (score < 0) continue;
        }
        out[n].index = i;
        out[n].score = score;
        n++;
    }
    if (filtered) qsort(out, (size_t)n, sizeof(*out), spdf_win_pf_match_compare);
    return n;
}

/* palette_ascii_ci_strstr */
SPDF_WIN_PF_INLINE const char* spdf_win_pf_ci_strstr(const char* haystack, const char* needle) {
    size_t needle_len = strlen(needle);
    const char* h;
    if (needle_len == 0) return haystack;
    for (h = haystack; *h; ++h) {
        size_t i = 0;
        while (i < needle_len && h[i] &&
               spdf_win_pf_lower((unsigned char)h[i]) == spdf_win_pf_lower((unsigned char)needle[i]))
            ++i;
        if (i == needle_len) return h;
    }
    return NULL;
}

/* spdf_palette_menu_breadcrumb: "group ▸ title", or whichever part exists.
 * Returns 0 and writes "" when both are empty (GTK returns NULL). */
SPDF_WIN_PF_INLINE int spdf_win_palette_menu_breadcrumb(const char* group, const char* title, char* out,
                                                        size_t out_cap) {
    int has_group = group && *group;
    int has_title = title && *title;
    size_t n = 0;
    if (!out || !out_cap) return 0;
    out[0] = '\0';
    if (!has_group && !has_title) return 0;
    if (has_group) {
        n = strlen(group);
        if (n >= out_cap) return 0;
        memcpy(out, group, n);
    }
    if (has_group && has_title) {
        if (n + 5 >= out_cap) return 0;
        memcpy(out + n, " \xE2\x96\xB8 ", 5); /* " ▸ " */
        n += 5;
    }
    if (has_title) {
        size_t t = strlen(title);
        if (n + t >= out_cap) return 0;
        memcpy(out + n, title, t);
        n += t;
    }
    out[n] = '\0';
    return 1;
}

/* The last path component, splitting on both separators (the one deliberate
 * departure from GTK's strrchr(path, '/')). */
SPDF_WIN_PF_INLINE const char* spdf_win_pf_basename(const char* path) {
    const char* p = path;
    const char* last = path;
    for (; *p; ++p)
        if (*p == '/' || *p == '\\') last = p + 1;
    return last;
}

/* spdf_palette_open_document_matches_query */
SPDF_WIN_PF_INLINE int spdf_win_palette_open_document_matches_query(const char* query, const char* title,
                                                                    const char* path) {
    const char* base;
    if (!query || !*query) return 1;
    if (title && *title && spdf_win_pf_ci_strstr(title, query)) return 1;
    if (!path || !*path) return 0;
    base = spdf_win_pf_basename(path);
    return *base && spdf_win_pf_ci_strstr(base, query) != NULL;
}

/* THE DEDUPE KEY (palette_canonical_path / g_canonicalize_filename on GTK, the
 * mac's stringByStandardizingPath): a lexical canonical form. Separators are
 * normalised to '\', runs collapsed, "." dropped, ".." resolved against the
 * component before it (never above the root), ASCII case folded. Returns 0 when
 * it does not fit. */
SPDF_WIN_PF_INLINE int spdf_win_palette_canonical_path(const char* path, char* out, size_t out_cap) {
    size_t n = 0, root = 0;
    const char* p = path ? path : "";
    if (!out || !out_cap) return 0;
    /* Keep a root -- "C:\", "\\server\share\" or "\" -- untouched. */
    if (((p[0] >= 'a' && p[0] <= 'z') || (p[0] >= 'A' && p[0] <= 'Z')) && p[1] == ':') {
        if (n + 3 > out_cap) return 0;
        out[n++] = (char)spdf_win_pf_lower((unsigned char)p[0]);
        out[n++] = ':';
        p += 2;
        if (*p == '/' || *p == '\\') {
            out[n++] = '\\';
            while (*p == '/' || *p == '\\') p++;
        }
        root = n;
    } else if (*p == '/' || *p == '\\') {
        int unc = (p[1] == '/' || p[1] == '\\');
        if (n + 1 > out_cap) return 0;
        out[n++] = '\\';
        p++;
        if (unc) {
            /* "\\server\share\" is the root of a UNC path: ".." never climbs
             * out of the share, as spdf_win_path_root_len also states. */
            int part;
            if (n + 1 > out_cap) return 0;
            out[n++] = '\\';
            while (*p == '/' || *p == '\\') p++;
            for (part = 0; part < 2 && *p; ++part) {
                while (*p && *p != '/' && *p != '\\') {
                    if (n + 2 >= out_cap) return 0;
                    out[n++] = (char)spdf_win_pf_lower((unsigned char)*p++);
                }
                out[n++] = '\\';
                while (*p == '/' || *p == '\\') p++;
            }
        }
        root = n;
    }
    while (*p) {
        const char* seg = p;
        size_t len;
        while (*p && *p != '/' && *p != '\\') p++;
        len = (size_t)(p - seg);
        while (*p == '/' || *p == '\\') p++;
        if (len == 0 || (len == 1 && seg[0] == '.')) continue;
        if (len == 2 && seg[0] == '.' && seg[1] == '.') {
            if (n > root) {
                n--; /* the trailing separator, if the last component has one */
                while (n > root && out[n - 1] != '\\') n--;
            }
            continue;
        }
        if (n + len + 1 >= out_cap) return 0;
        {
            size_t i;
            for (i = 0; i < len; ++i) out[n++] = (char)spdf_win_pf_lower((unsigned char)seg[i]);
        }
        out[n++] = '\\';
    }
    if (n > root && out[n - 1] == '\\') n--;
    out[n] = '\0';
    return 1;
}

typedef struct SpdfWinPaletteOpenDoc {
    const char* path;
    const char* title;
} SpdfWinPaletteOpenDoc;

/* spdf_palette_filter_open_documents: candidate order kept, blank paths
 * skipped, each document once (a duplicate is recorded as seen only when it
 * matched, like the mac's seenPaths), filtered by the query. */
SPDF_WIN_PF_INLINE int spdf_win_palette_filter_open_documents(const SpdfWinPaletteOpenDoc* docs, int count,
                                                              const char* query, int* out, int out_max) {
    int n = 0, i, j;
    if (!docs || !out || out_max <= 0) return 0;
    for (i = 0; i < count && n < out_max; ++i) {
        char key[1024], other[1024];
        int seen = 0;
        if (!docs[i].path || !*docs[i].path) continue;
        if (!spdf_win_palette_canonical_path(docs[i].path, key, sizeof(key))) continue;
        for (j = 0; j < n && !seen; ++j)
            if (spdf_win_palette_canonical_path(docs[out[j]].path, other, sizeof(other)) && strcmp(key, other) == 0)
                seen = 1;
        if (seen || !spdf_win_palette_open_document_matches_query(query, docs[i].title, docs[i].path)) continue;
        out[n++] = i;
    }
    return n;
}

/* spdf_palette_query_reveals_all_favorites: the trimmed query is a >= 3 byte
 * case-insensitive prefix of "favorites". */
SPDF_WIN_PF_INLINE int spdf_win_palette_query_reveals_all_favorites(const char* query) {
    const char* keyword = "favorites";
    const char* start;
    const char* end;
    size_t len, i;
    if (!query) return 0;
    start = query;
    while (*start && spdf_win_pf_isspace((unsigned char)*start)) start++;
    end = start + strlen(start);
    while (end > start && spdf_win_pf_isspace((unsigned char)end[-1])) end--;
    len = (size_t)(end - start);
    if (len < 3 || len > strlen(keyword)) return 0;
    for (i = 0; i < len; ++i)
        if (spdf_win_pf_lower((unsigned char)start[i]) != keyword[i]) return 0;
    return 1;
}

/* spdf_palette_favorite_shadowed_by_open_doc: only a DOCUMENT favorite of an
 * open document hides. open_keys are canonical (spdf_win_palette_canonical_path)
 * forms of the open documents' paths. */
SPDF_WIN_PF_INLINE int spdf_win_palette_favorite_shadowed_by_open_doc(const char* favorite_type,
                                                                      const char* favorite_path,
                                                                      const char* const* open_keys, int open_count) {
    char key[1024];
    int i;
    if (!open_keys || open_count <= 0) return 0;
    if (!favorite_type || strcmp(favorite_type, "document") != 0) return 0;
    if (!favorite_path || !*favorite_path) return 0;
    if (!spdf_win_palette_canonical_path(favorite_path, key, sizeof(key))) return 0;
    for (i = 0; i < open_count; ++i)
        if (open_keys[i] && strcmp(open_keys[i], key) == 0) return 1;
    return 0;
}

/* spdf_palette_snippet_from_line: up to 24 bytes of context either side of the
 * first case-insensitive occurrence, never splitting a UTF-8 sequence, trimmed,
 * with an ellipsis on each clipped end. Returns 0 (out = "") when the query
 * does not occur or nothing remains. */
SPDF_WIN_PF_INLINE int spdf_win_palette_snippet_from_line(const char* line, const char* query, char* out,
                                                          size_t out_cap) {
    const char* hit;
    size_t start, end, len, n = 0, body;
    if (!out || !out_cap) return 0;
    out[0] = '\0';
    if (!line || !*line || !query || !*query) return 0;
    hit = spdf_win_pf_ci_strstr(line, query);
    if (!hit) return 0;
    len = strlen(line);
    start = (size_t)(hit - line);
    end = start + strlen(query) + SPDF_WIN_PALETTE_SNIPPET_CONTEXT_BYTES;
    if (end > len) end = len;
    start = start > SPDF_WIN_PALETTE_SNIPPET_CONTEXT_BYTES ? start - SPDF_WIN_PALETTE_SNIPPET_CONTEXT_BYTES : 0;
    while (start > 0 && ((unsigned char)line[start] & 0xC0) == 0x80) start--;
    while (end < len && ((unsigned char)line[end] & 0xC0) == 0x80) end++;
    while (start < end && spdf_win_pf_isspace((unsigned char)line[start])) start++;
    while (end > start && spdf_win_pf_isspace((unsigned char)line[end - 1])) end--;
    if (end <= start) return 0;
    body = end - start;
    if (body + 7 >= out_cap) return 0; /* two ellipses of 3 bytes and a NUL */
    if (start > 0) {
        memcpy(out + n, "\xE2\x80\xA6", 3);
        n += 3;
    }
    memcpy(out + n, line + start, body);
    n += body;
    if (end < len) {
        memcpy(out + n, "\xE2\x80\xA6", 3);
        n += 3;
    }
    out[n] = '\0';
    return 1;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PALETTE_FILTER_H */
