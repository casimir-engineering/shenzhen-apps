/* spdf_win_annot_model.h — the annotations module's PURE half, ported from the
 * GTK4 frontend: the path and write-preflight rules, the comment-marker
 * geometry, the two hit tests, and the strings the sidebar and the hover
 * preview show.
 *
 * TRANSCRIPTION, NOT A REWRITE, in the sense spdf_win_sidebar_results.h means
 * it. Section 1 below is portable/linux/gtk4/spdf_annot.c section 1 -- the part
 * that file compiles alone under SPDF_ANNOT_TESTING for its own
 * tests/annot_preflight_test.c -- with glib's strings replaced by the CRT's and
 * NOTHING ELSE changed. It is compared against the real GTK source, compiled
 * through the glib shim, by
 *
 *   portable\win\tests\annot-differential-native.cmd
 *
 * for EXACT equality over a matrix of paths. Section 2 is the comment-side
 * logic that in spdf_annot.c is welded to SpdfTab (annot_comment_at_point,
 * annot_comment_at_badge, annot_comment_item_for_index) and the badge rect
 * that spdf_internal.h shares between the doc view's painter and that hit
 * test (spdf_comment_marker_badge); those take the core's spdf_comment_item
 * array directly and are pinned by portable/win/tests/annot_model_test.c with
 * the GTK constants cited beside each. Section 3 is the text: the row the GTK
 * comments pane shows (spdf_sidebar.c comments_rebuild) and the message the
 * macOS hover bubble shows (ShenzhenPDFMac.mm commentAnnotationsForPage /
 * documentViewHoverComment:), which differ and are both kept.
 *
 * THE TWO DIFFERENCES FROM THE ORIGINAL, both in the platform:
 *
 *   1. g_canonicalize_filename is not ported. spdf_win_annot_path_is_under_directory
 *      compares the paths it is GIVEN; a caller that wants canonical paths
 *      canonicalises first (GetFullPathNameW), which is what
 *      spdf_win_annot.cpp does. The differential's shim gives the GTK side
 *      the same identity canonicalisation, so the containment rule itself is
 *      checked exactly.
 *   2. A directory separator is '\\' OR '/'. The original tests G_DIR_SEPARATOR
 *      alone; Windows paths arrive in both spellings and a rule that read
 *      "C:/Temp/x.pdf" as not under "C:\Temp" would be wrong in the way that
 *      lets a temp file be written to. The differential feeds backslash paths,
 *      where the two agree by construction; the slash acceptance is pinned by
 *      the unit test.
 *
 * PURE, HEADER-ONLY, C and C++ under MSVC. No Win32, no Direct2D, no
 * allocation except where the original allocated (the two filename builders
 * return malloc'd strings the caller frees, as their g_strdup_printf did).
 */
#ifndef SPDF_WIN_ANNOT_MODEL_H
#define SPDF_WIN_ANNOT_MODEL_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shenzhen_pdf_core.h" /* spdf_comment_item, spdf_rect */

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_AM_INLINE __inline
#else
#define SPDF_WIN_AM_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* --------------------------------------------------------------------------
 * 1. Path / preflight rules (spdf_annot.c:28-82). */

static SPDF_WIN_AM_INLINE int spdf_win_annot_ascii_strcasecmp(const char* a, const char* b) {
    /* g_ascii_strcasecmp: ASCII letters only, so a locale cannot change it. */
    for (;; ++a, ++b) {
        int ca = (unsigned char)*a, cb = (unsigned char)*b;
        if (ca >= 'A' && ca <= 'Z') ca += 'a' - 'A';
        if (cb >= 'A' && cb <= 'Z') cb += 'a' - 'A';
        if (ca != cb) return ca - cb;
        if (!ca) return 0;
    }
}

/* path_has_pdf_extension: last extension is ".pdf", ASCII case-insensitive. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_path_has_pdf_extension(const char* path) {
    const char* dot = path ? strrchr(path, '.') : NULL;
    return dot && spdf_win_annot_ascii_strcasecmp(dot, ".pdf") == 0;
}

static SPDF_WIN_AM_INLINE int spdf_win_annot_is_sep(char c) { return c == '\\' || c == '/'; }

/* path_is_under_directory: prefix containment (or equality) on a separator
 * boundary. Paths are compared as given -- see the header's difference 1. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_path_is_under_directory(const char* path, const char* directory) {
    size_t dir_len;
    if (!path || !*path || !directory || !*directory) return 0;
    dir_len = strlen(directory);
    return strcmp(path, directory) == 0 ||
           (strncmp(path, directory, dir_len) == 0 && spdf_win_annot_is_sep(path[dir_len]));
}

/* path_is_in_temp_directory, with the probed directories injected. The two
 * POSIX literals are the original's and never match a Windows path; they stay
 * so the rule is the same rule. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_path_is_temp_in(const char* path, const char* tmp_dir,
                                                             const char* runtime_dir) {
    return spdf_win_annot_path_is_under_directory(path, tmp_dir) ||
           spdf_win_annot_path_is_under_directory(path, "/tmp") ||
           spdf_win_annot_path_is_under_directory(path, "/var/tmp") ||
           spdf_win_annot_path_is_under_directory(path, runtime_dir);
}

static SPDF_WIN_AM_INLINE char* spdf_win_annot_strdup(const char* s) {
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out) memcpy(out, s, n);
    return out;
}

/* filename_with_pdf_extension: the path as is when it already ends in .pdf,
 * else with ".pdf" appended. malloc'd; NULL for NULL/"" (as g_strdup of NULL). */
static SPDF_WIN_AM_INLINE char* spdf_win_annot_filename_with_pdf_extension(const char* path) {
    size_t n;
    char* out;
    if (!path || !*path) return NULL;
    if (spdf_win_annot_path_has_pdf_extension(path)) return spdf_win_annot_strdup(path);
    n = strlen(path);
    out = (char*)malloc(n + 5);
    if (!out) return NULL;
    memcpy(out, path, n);
    memcpy(out + n, ".pdf", 5);
    return out;
}

/* g_path_get_basename, on either separator: the last component, trailing
 * separators stripped; "." for an empty path; the separator itself for a
 * root. */
static SPDF_WIN_AM_INLINE char* spdf_win_annot_path_basename(const char* path) {
    size_t end, start;
    char* out;
    if (!path || !*path) return spdf_win_annot_strdup(".");
    end = strlen(path);
    while (end > 0 && spdf_win_annot_is_sep(path[end - 1])) --end;
    if (end == 0) {
        out = (char*)malloc(2);
        if (out) {
            out[0] = path[0];
            out[1] = '\0';
        }
        return out;
    }
    start = end;
    while (start > 0 && !spdf_win_annot_is_sep(path[start - 1])) --start;
    out = (char*)malloc(end - start + 1);
    if (!out) return NULL;
    memcpy(out, path + start, end - start);
    out[end - start] = '\0';
    return out;
}

/* copy_page_clicked's name build: "<stem> - page N.pdf", stem = the basename
 * with its last extension cut ("Page" for a NULL/empty path or an empty stem).
 * malloc'd. */
static SPDF_WIN_AM_INLINE char* spdf_win_annot_single_page_filename(const char* doc_path, int page_index) {
    char* base = spdf_win_annot_path_basename(doc_path && *doc_path ? doc_path : "Page");
    char* dot;
    char* name;
    size_t n;
    if (!base) return NULL;
    dot = strrchr(base, '.');
    if (dot && dot != base) *dot = '\0';
    n = strlen(base) + 32;
    name = (char*)malloc(n);
    if (name) _snprintf_s(name, n, _TRUNCATE, "%s - page %d.pdf", *base ? base : "Page", page_index + 1);
    free(base);
    return name;
}

/* pdf_path_allows_same_folder_write's verdict, probes injected. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_same_folder_write_allowed(int is_temp, int file_writable,
                                                                       int dir_writable) {
    return !is_temp && file_writable && dir_writable;
}

/* prompt_save_as_before_modification's save-target rule: a .pdf, outside the
 * temp folders. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_save_target_acceptable(const char* path, const char* tmp_dir,
                                                                    const char* runtime_dir) {
    if (!path || !*path || !spdf_win_annot_path_has_pdf_extension(path)) return 0;
    return !spdf_win_annot_path_is_temp_in(path, tmp_dir, runtime_dir);
}

/* --------------------------------------------------------------------------
 * 2. Markers and hit tests. Page-space PDF points throughout, origin top-left,
 * the space spdf_comment_item.bounds is in. */

#define SPDF_WIN_ANNOT_COMMENT_HIT_SLOP_PT 3.0f /* spdf_annot.c:113, GTK3 comment_index_at_page_point */
#define SPDF_WIN_ANNOT_BADGE_HIT_SLOP_PT 2.0f   /* spdf_annot.c:114 */
#define SPDF_WIN_ANNOT_SELECTION_RECT_MAX 256   /* spdf_annot.c:112; the mac's 256 too */

/* spdf_internal.h spdf_comment_marker_badge: a 12 pt square hugging the
 * annotation's top-right corner, 4 in and 8 out on each axis. Shared between
 * the painter and the click-to-edit test so the two cannot disagree. */
static SPDF_WIN_AM_INLINE spdf_rect spdf_win_annot_badge(const spdf_rect* bounds) {
    spdf_rect badge;
    float right = bounds->x0 > bounds->x1 ? bounds->x0 : bounds->x1;
    float top = bounds->y0 < bounds->y1 ? bounds->y0 : bounds->y1;
    badge.x0 = right - 4.0f;
    badge.x1 = right + 8.0f;
    badge.y0 = top - 8.0f;
    badge.y1 = top + 4.0f;
    return badge;
}

/* annot_comment_at_point: the first comment on `page` whose bounds, inflated
 * by 3 pt, contain the point. Items with a negative index (the core's marker
 * for "not a visible comment") and degenerate rects are skipped. Returns the
 * comment INDEX (spdf_comment_item.index, what spdf_update_comment wants), or
 * -1. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_comment_at_point(const spdf_comment_item* items, int count,
                                                              int page_index, float page_x, float page_y) {
    int i;
    for (i = 0; i < count; ++i) {
        const spdf_comment_item* item = &items[i];
        float x0, x1, y0, y1;
        if (item->page_index != page_index || item->index < 0) continue;
        x0 = (item->bounds.x0 < item->bounds.x1 ? item->bounds.x0 : item->bounds.x1) - SPDF_WIN_ANNOT_COMMENT_HIT_SLOP_PT;
        x1 = (item->bounds.x0 > item->bounds.x1 ? item->bounds.x0 : item->bounds.x1) + SPDF_WIN_ANNOT_COMMENT_HIT_SLOP_PT;
        y0 = (item->bounds.y0 < item->bounds.y1 ? item->bounds.y0 : item->bounds.y1) - SPDF_WIN_ANNOT_COMMENT_HIT_SLOP_PT;
        y1 = (item->bounds.y0 > item->bounds.y1 ? item->bounds.y0 : item->bounds.y1) + SPDF_WIN_ANNOT_COMMENT_HIT_SLOP_PT;
        if (x1 <= x0 || y1 <= y0) continue;
        if (page_x >= x0 && page_x <= x1 && page_y >= y0 && page_y <= y1) return item->index;
    }
    return -1;
}

/* annot_comment_at_badge: click-to-edit tests ONLY the badge (plus 2 pt), not
 * the whole annotation, so text selection over a highlight still works. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_comment_at_badge(const spdf_comment_item* items, int count,
                                                              int page_index, float page_x, float page_y) {
    int i;
    for (i = 0; i < count; ++i) {
        const spdf_comment_item* item = &items[i];
        spdf_rect badge;
        if (item->page_index != page_index || item->index < 0) continue;
        badge = spdf_win_annot_badge(&item->bounds);
        if (page_x >= badge.x0 - SPDF_WIN_ANNOT_BADGE_HIT_SLOP_PT && page_x <= badge.x1 + SPDF_WIN_ANNOT_BADGE_HIT_SLOP_PT &&
            page_y >= badge.y0 - SPDF_WIN_ANNOT_BADGE_HIT_SLOP_PT && page_y <= badge.y1 + SPDF_WIN_ANNOT_BADGE_HIT_SLOP_PT)
            return item->index;
    }
    return -1;
}

/* annot_comment_item_for_index. */
static SPDF_WIN_AM_INLINE const spdf_comment_item* spdf_win_annot_item_for_index(const spdf_comment_item* items,
                                                                                 int count, int comment_index) {
    int i;
    if (comment_index < 0 || !items) return NULL;
    for (i = 0; i < count; ++i)
        if (items[i].index == comment_index) return &items[i];
    return NULL;
}

/* A comment whose bounds have no area (the core reports some Popup-less
 * annotations that way) has nothing to mark on the page; the sidebar still
 * lists it, and a click there goes to the page rather than to a rect --
 * spdf_sidebar.c comments_rebuild's `w > 0 && h > 0` guard. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_bounds_have_area(const spdf_rect* b) {
    return b && b->x1 - b->x0 > 0.0f && b->y1 - b->y0 > 0.0f;
}

/* --------------------------------------------------------------------------
 * 3. Text. UTF-8 in, UTF-8 out into caller buffers; every string may be NULL. */

/* The GTK comments row (spdf_sidebar.c:517-519): body = text, else type, else
 * "Comment"; title = "author: body" when there is an author, else body. The
 * mac row is the same shape (rebuildSidebar :9595-9598). */
static SPDF_WIN_AM_INLINE int spdf_win_annot_row_title(const spdf_comment_item* item, char* out, size_t out_len) {
    const char* body;
    int n;
    if (!out || !out_len) return 0;
    if (!item) {
        out[0] = '\0';
        return 0;
    }
    body = item->text && *item->text ? item->text : (item->type && *item->type ? item->type : "Comment");
    if (item->author && *item->author) n = _snprintf_s(out, out_len, _TRUNCATE, "%s: %s", item->author, body);
    else n = _snprintf_s(out, out_len, _TRUNCATE, "%s", body);
    return n < 0 ? (int)(out_len - 1) : n;
}

/* The GTK row's subtitle: "Page N", 1-based (spdf_sidebar.c:520). */
static SPDF_WIN_AM_INLINE int spdf_win_annot_row_subtitle(const spdf_comment_item* item, char* out, size_t out_len) {
    int n;
    if (!out || !out_len) return 0;
    n = _snprintf_s(out, out_len, _TRUNCATE, "Page %d", item ? item->page_index + 1 : 0);
    return n < 0 ? (int)(out_len - 1) : n;
}

/* The mac hover bubble (commentAnnotationsForPage :7577-7580,
 * documentViewHoverComment :7593-7595): title = "author - type" when there is
 * an author, else the type ("Comment" when the core gives none); the message
 * is "title\ntext" when there is text, else the title alone. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_hover_text(const spdf_comment_item* item, char* out, size_t out_len) {
    const char* type;
    int n;
    if (!out || !out_len) return 0;
    if (!item) {
        out[0] = '\0';
        return 0;
    }
    type = item->type && *item->type ? item->type : "Comment";
    if (item->author && *item->author) {
        if (item->text && *item->text)
            n = _snprintf_s(out, out_len, _TRUNCATE, "%s - %s\n%s", item->author, type, item->text);
        else n = _snprintf_s(out, out_len, _TRUNCATE, "%s - %s", item->author, type);
    } else {
        if (item->text && *item->text) n = _snprintf_s(out, out_len, _TRUNCATE, "%s\n%s", type, item->text);
        else n = _snprintf_s(out, out_len, _TRUNCATE, "%s", type);
    }
    return n < 0 ? (int)(out_len - 1) : n;
}

/* The mac filter haystack for a comment row (:9599-9600): "title author type
 * p.N" -- so a filter on the author, the kind or the page number matches too. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_filter_haystack(const spdf_comment_item* item, char* out,
                                                             size_t out_len) {
    char title[1024];
    int n;
    if (!out || !out_len) return 0;
    spdf_win_annot_row_title(item, title, sizeof(title));
    n = _snprintf_s(out, out_len, _TRUNCATE, "%s %s %s p.%d", title, item && item->author ? item->author : "",
                    item && item->type ? item->type : "", item ? item->page_index + 1 : 0);
    return n < 0 ? (int)(out_len - 1) : n;
}

/* The delete confirmation's detail (mac deleteComment: :11997-12001): the
 * fixed sentence, then a blank line and the text cut to 180 characters with
 * "..." when longer. Byte-based like the GTK strings here; a cut inside a
 * multibyte sequence is backed up to the sequence start so the preview stays
 * valid UTF-8. */
static SPDF_WIN_AM_INLINE int spdf_win_annot_delete_detail(const char* text, char* out, size_t out_len) {
    const char* fixed = "This will permanently remove the comment from the PDF.";
    size_t cut = 180;
    int n;
    if (!out || !out_len) return 0;
    if (!text || !*text) {
        n = _snprintf_s(out, out_len, _TRUNCATE, "%s", fixed);
        return n < 0 ? (int)(out_len - 1) : n;
    }
    if (strlen(text) <= cut) {
        n = _snprintf_s(out, out_len, _TRUNCATE, "%s\n\n%s", fixed, text);
        return n < 0 ? (int)(out_len - 1) : n;
    }
    while (cut > 0 && ((unsigned char)text[cut] & 0xC0) == 0x80) --cut;
    n = _snprintf_s(out, out_len, _TRUNCATE, "%s\n\n%.*s...", fixed, (int)cut, text);
    return n < 0 ? (int)(out_len - 1) : n;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_ANNOT_MODEL_H */
