/* spdf_win_tabs_names.h — what a tab is CALLED when two tabs share a name.
 *
 * A transcription of portable/mac/SPDFMacSupport.mm:18-137 --
 * spdf_display_label_without_extension, spdf_display_name_for_path,
 * spdf_display_path_without_extension, spdf_display_components_for_path,
 * spdf_display_candidate_for_components, spdf_candidates_are_unique and
 * spdf_disambiguated_display_names_for_paths -- into toolkit-free C, the way
 * spdf_win_tabstrip.h transcribed the strip's geometry, and for the reason
 * portable/docs/windows-port-plan.md §2.3 gives: the rule is the mac app's,
 * not an invented one, and re-deriving it would re-derive its edge cases too.
 *
 * THE RULE. Every tab shows its file's display name -- the last path component
 * with a known document extension removed. When several open tabs would show
 * the SAME name (case-insensitively), each of them grows the shortest tail of
 * its path that tells them apart: first "folder/name", then "a/.../name",
 * "a/b/.../name" and so on, trying every tail length in turn and within it
 * every count of leading folders; the first arrangement in which all the
 * candidates differ wins. When even the whole paths coincide after the
 * extension is gone, each tab shows its full path without extension.
 *
 * NO ALLOCATION, NO STATE. Components are (pointer, length) views into the
 * caller's paths and the results are written into caller-provided rows, so
 * this can run inside the chrome model build once per paint without a malloc
 * on the paint path. Case folding is ASCII: the mac version uses -lowercaseString,
 * which folds every script, and two paths that differ only in the case of a
 * non-ASCII letter would be told apart here and merged there. Recorded rather
 * than hidden; a Windows path differing only that way is a curiosity.
 *
 * Header-only, C-compatible, and compiled by MSVC as C and as C++.
 */
#ifndef SPDF_WIN_TABS_NAMES_H
#define SPDF_WIN_TABS_NAMES_H

#include <stddef.h>
#include <string.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_TN_INLINE __inline
#else
#define SPDF_WIN_TN_INLINE inline
#endif

/* One row of output. A display name is a path tail, so it is bounded by a path. */
#define SPDF_WIN_TABS_NAME_MAX 512
/* Paths deeper than this show their deepest components only; nobody's
 * documents folder is 32 levels down, and a bound keeps the working set on the
 * stack. */
#define SPDF_WIN_TABS_NAME_COMPONENTS 32
/* The most tabs one call handles: SPDF_WIN_TABS_MAX's value, restated so this
 * header need not include the tab model. */
#define SPDF_WIN_TABS_NAME_MAX_PATHS 64

typedef struct SpdfWinTnComponent {
    const char* p;
    int len;
} SpdfWinTnComponent;

static SPDF_WIN_TN_INLINE char spdf_win_tn_lower(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }

static SPDF_WIN_TN_INLINE int spdf_win_tn_ieq(const char* a, int alen, const char* b, int blen) {
    int i;
    if (alen != blen) return 0;
    for (i = 0; i < alen; ++i)
        if (spdf_win_tn_lower(a[i]) != spdf_win_tn_lower(b[i])) return 0;
    return 1;
}

/* spdf_display_label_without_extension (SPDFMacSupport.mm:18-31): the LAST
 * occurrence of each known extension in turn, removed when it ends the label
 * or is followed by whitespace or '-' ("report.pdf - copy" -> "report - copy").
 * Returns the label's new length after writing it into `out`. */
static SPDF_WIN_TN_INLINE int spdf_win_tn_label_without_extension(const char* label, int len, char* out, int out_len) {
    static const char* const exts[] = {".pdf", ".xps", ".cbz", ".epub", ".markdown", ".md"};
    size_t e;
    int n = 0;
    if (out_len <= 0) return 0;
    for (e = 0; e < sizeof(exts) / sizeof(exts[0]); ++e) {
        int k = (int)strlen(exts[e]);
        int at;
        for (at = len - k; at >= 0; --at) {
            char next;
            int at_end;
            if (!spdf_win_tn_ieq(label + at, k, exts[e], k)) continue;
            at_end = at + k == len;
            next = at_end ? '\0' : label[at + k];
            if (at_end || next == ' ' || next == '\t' || next == '\n' || next == '\r' || next == '-') {
                int i;
                for (i = 0; i < at && n < out_len - 1; ++i) out[n++] = label[i];
                for (i = at + k; i < len && n < out_len - 1; ++i) out[n++] = label[i];
                out[n] = '\0';
                return n;
            }
            break; /* only the LAST occurrence of this extension is considered */
        }
    }
    for (n = 0; n < len && n < out_len - 1; ++n) out[n] = label[n];
    out[n] = '\0';
    return n;
}

/* spdf_display_components_for_path (:52-63): split on both separators, drop
 * empty components. The last component's extension is stripped by the caller
 * through the label function above, because a component is a view and the
 * stripped form is a new string. Returns the count, at most
 * SPDF_WIN_TABS_NAME_COMPONENTS (keeping the DEEPEST ones). */
static SPDF_WIN_TN_INLINE int spdf_win_tn_components(const char* path, SpdfWinTnComponent* out) {
    int count = 0;
    const char* start = path;
    const char* p;
    if (!path) return 0;
    for (p = path;; ++p) {
        if (*p == '/' || *p == '\\' || *p == '\0') {
            if (p > start) {
                if (count == SPDF_WIN_TABS_NAME_COMPONENTS) {
                    memmove(out, out + 1, sizeof(out[0]) * (size_t)(count - 1));
                    count--;
                }
                out[count].p = start;
                out[count].len = (int)(p - start);
                count++;
            }
            start = p + 1;
            if (*p == '\0') break;
        }
    }
    return count;
}

static SPDF_WIN_TN_INLINE void spdf_win_tn_append(char* out, int* n, int out_len, const char* text, int len) {
    int i;
    for (i = 0; i < len && *n < out_len - 1; ++i) out[(*n)++] = text[i];
    out[*n] = '\0';
}

/* spdf_display_candidate_for_components (:65-75). `last` is the stripped last
 * component, already computed by the caller. */
static SPDF_WIN_TN_INLINE void spdf_win_tn_candidate(const SpdfWinTnComponent* comps, int count, const char* last,
                                                     int tail_length, int leading_count, char* out, int out_len) {
    int start, tail_count, i, n = 0, visible_leading;
    if (out_len <= 0) return;
    out[0] = '\0';
    if (count <= 0) return;
    if (tail_length > count) tail_length = count;
    start = count - tail_length;
    tail_count = tail_length;
    if (tail_count <= 2) {
        for (i = start; i < count; ++i) {
            if (i > start) spdf_win_tn_append(out, &n, out_len, "/", 1);
            if (i == count - 1) spdf_win_tn_append(out, &n, out_len, last, (int)strlen(last));
            else spdf_win_tn_append(out, &n, out_len, comps[i].p, comps[i].len);
        }
        return;
    }
    visible_leading = leading_count < tail_count - 2 ? leading_count : tail_count - 2;
    for (i = 0; i < visible_leading; ++i) {
        if (i) spdf_win_tn_append(out, &n, out_len, "/", 1);
        spdf_win_tn_append(out, &n, out_len, comps[start + i].p, comps[start + i].len);
    }
    spdf_win_tn_append(out, &n, out_len, "/.../", 5);
    spdf_win_tn_append(out, &n, out_len, last, (int)strlen(last));
}

/* spdf_display_path_without_extension (:46-50): the whole path with whatever
 * extension its last component has removed -- ANY extension here, not only a
 * known one, which is what stringByDeletingPathExtension does. */
static SPDF_WIN_TN_INLINE void spdf_win_tn_path_without_extension(const char* path, char* out, int out_len) {
    int len = (int)strlen(path), dot = -1, i, n = 0;
    for (i = len - 1; i >= 0; --i) {
        if (path[i] == '/' || path[i] == '\\') break;
        if (path[i] == '.') {
            dot = i;
            break;
        }
    }
    /* A leading dot is not an extension, and a stem that would be empty keeps
     * the path (`stem.length && ![stem isEqualToString:path]`). */
    if (dot <= 0 || path[dot - 1] == '/' || path[dot - 1] == '\\') dot = len;
    spdf_win_tn_append(out, &n, out_len, path, dot);
}

/* THE ENTRY POINT: spdf_disambiguated_display_names_for_paths (:82-137).
 * `out` has `count` rows of SPDF_WIN_TABS_NAME_MAX bytes; every row is written.
 * A NULL or empty path yields an empty name. */
static SPDF_WIN_TN_INLINE void spdf_win_tabs_display_names(const char* const* paths, int count,
                                                           char (*out)[SPDF_WIN_TABS_NAME_MAX]) {
    SpdfWinTnComponent comps[SPDF_WIN_TABS_NAME_MAX_PATHS][SPDF_WIN_TABS_NAME_COMPONENTS];
    char last[SPDF_WIN_TABS_NAME_MAX_PATHS][SPDF_WIN_TABS_NAME_MAX];
    int comp_count[SPDF_WIN_TABS_NAME_MAX_PATHS];
    int group[SPDF_WIN_TABS_NAME_MAX_PATHS]; /* index of the first path sharing this base, i.e. the group id */
    int i, j;

    if (!paths || !out) return;
    if (count > SPDF_WIN_TABS_NAME_MAX_PATHS) count = SPDF_WIN_TABS_NAME_MAX_PATHS;

    /* Bases, and the groups of equal (case-insensitive) bases. */
    for (i = 0; i < count; ++i) {
        const char* path = paths[i] ? paths[i] : "";
        comp_count[i] = spdf_win_tn_components(path, comps[i]);
        if (comp_count[i] > 0) {
            const SpdfWinTnComponent* c = &comps[i][comp_count[i] - 1];
            spdf_win_tn_label_without_extension(c->p, c->len, last[i], SPDF_WIN_TABS_NAME_MAX);
        } else {
            last[i][0] = '\0';
        }
        strcpy(out[i], last[i]);
        group[i] = i;
        for (j = 0; j < i; ++j) {
            if (spdf_win_tn_ieq(last[j], (int)strlen(last[j]), last[i], (int)strlen(last[i]))) {
                group[i] = group[j];
                break;
            }
        }
    }

    /* Each group with more than one member. */
    for (i = 0; i < count; ++i) {
        int members = 0, max_tail = 1, tail_length, resolved = 0;
        if (group[i] != i) continue;
        for (j = i; j < count; ++j)
            if (group[j] == i) {
                members++;
                if (comp_count[j] > max_tail) max_tail = comp_count[j];
            }
        if (members <= 1) continue;

        for (tail_length = 2; tail_length <= max_tail && !resolved; ++tail_length) {
            int max_leading = tail_length <= 2 ? 1 : tail_length - 2;
            int leading_count;
            for (leading_count = 1; leading_count <= max_leading; ++leading_count) {
                int unique = 1, a, b;
                for (a = i; a < count; ++a)
                    if (group[a] == i)
                        spdf_win_tn_candidate(comps[a], comp_count[a], last[a], tail_length, leading_count, out[a],
                                              SPDF_WIN_TABS_NAME_MAX);
                for (a = i; a < count && unique; ++a) {
                    if (group[a] != i) continue;
                    for (b = a + 1; b < count; ++b) {
                        if (group[b] != i) continue;
                        if (spdf_win_tn_ieq(out[a], (int)strlen(out[a]), out[b], (int)strlen(out[b]))) {
                            unique = 0;
                            break;
                        }
                    }
                }
                if (unique) {
                    resolved = 1;
                    break;
                }
            }
        }
        if (!resolved) {
            for (j = i; j < count; ++j) {
                if (group[j] != i) continue;
                spdf_win_tn_path_without_extension(paths[j] ? paths[j] : "", out[j], SPDF_WIN_TABS_NAME_MAX);
                if (!out[j][0]) strcpy(out[j], last[j]);
            }
        }
    }
}

#endif /* SPDF_WIN_TABS_NAMES_H */
