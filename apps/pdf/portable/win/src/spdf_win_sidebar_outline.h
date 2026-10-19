/* spdf_win_sidebar_outline.h — the chapter list's hierarchy: which rows fold,
 * what a fold hides, and how a folded row is remembered.
 *
 * TRANSCRIBED FROM THE MAC, NOT FROM GTK. portable/mac/SPDFMacSidebarOutline.mm
 * (a5820117a, "Nest the chapter list, with per-document memory of what is
 * collapsed") is the original, function for function; the GTK4 sidebar has no
 * collapse state, so the differential that checks spdf_win_sidebar_results.h
 * against portable/linux/gtk4/spdf_sidebar_internal.h cannot cover these. What
 * checks them instead is portable/win/tests/sidebar_outline_test.c, which pins
 * the SAME expected rows the mac's SPDFMacSidebarOutlineTests.mm pins -- the
 * README-shaped outline, the deeper-rooted one, the skipped level, the stale
 * key -- so the two implementations are held to one answer.
 *
 * Both sources -- a PDF's outline items and a Markdown document's headings --
 * hand the sidebar rows carrying a level, and nothing else describes the
 * nesting: a row's children are simply the rows after it with a deeper level,
 * up to the next row at its own level or shallower. The hierarchy is derived,
 * not stored, so both sources get it at once.
 *
 * Levels are the RAW item levels, as the mac reads them (item[@"level"]), not
 * the normalised ones spdf_win_sidebar_results.h's tree functions take. The mac
 * derives "children" from raw levels, which is what makes an outline that
 * starts at level 2 nest from its own root and a skipped level (H1 then H3)
 * still a child; normalising first would change which rows a stored key names.
 *
 * A row's identity for the per-document memory is POSITIONAL -- the ordinal of
 * each ancestor among its siblings, joined by dots ("0.2.1") -- rather than
 * title-based, so two identically named sections stay distinct. A document
 * edited so that its structure shifts simply stops matching its stale keys,
 * which then hide nothing; that is the documented default, expanded.
 *
 * Kept pure (levels in, flags and keys out) so the collapse rules are testable
 * with no table, no document and no window. Header-only, C and C++ under MSVC.
 */
#ifndef SPDF_WIN_SIDEBAR_OUTLINE_H
#define SPDF_WIN_SIDEBAR_OUTLINE_H

#include <stdio.h>
#include <string.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_SO_INLINE __inline
#else
#define SPDF_WIN_SO_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* The ordinal stack is bounded where the mac's NSMutableArray is not. 64 nested
 * depths is far past any real outline (the indent clamps at 16); a row deeper
 * than that keeps the first 64 ordinals of its key, which still names one row,
 * and the divergence is stated here rather than hidden. */
#define SPDF_WIN_SIDEBAR_OUTLINE_MAX_DEPTH 64
/* 64 depths of up to 10 digits plus a dot each, plus the terminator. */
#define SPDF_WIN_SIDEBAR_OUTLINE_KEY_MAX (SPDF_WIN_SIDEBAR_OUTLINE_MAX_DEPTH * 11 + 1)

/* SPDFOutlineLevelAt: out of range reads as 0. */
static SPDF_WIN_SO_INLINE int spdf_win_sidebar_outline_level_at(const int* levels, int count, int index) {
    if (!levels || index < 0 || index >= count) return 0;
    return levels[index];
}

/* Does this row have at least one child? Only such a row draws a disclosure
 * triangle. (spdf_sidebar_outline_has_children.) */
static SPDF_WIN_SO_INLINE int spdf_win_sidebar_outline_has_children(const int* levels, int count, int index) {
    if (index < 0 || index + 1 >= count) return 0;
    return spdf_win_sidebar_outline_level_at(levels, count, index + 1) >
           spdf_win_sidebar_outline_level_at(levels, count, index);
}

/* The row's key, "0.2.1", into `out`. Walks forward keeping one ordinal per
 * depth: each row increments the ordinal at its own depth and drops anything
 * deeper (spdf_sidebar_outline_key). Returns the key's length; 0 and "" for an
 * index out of range or a buffer that cannot hold it. */
static SPDF_WIN_SO_INLINE int spdf_win_sidebar_outline_key(const int* levels, int count, int index, char* out,
                                                           size_t out_cap) {
    int ordinals[SPDF_WIN_SIDEBAR_OUTLINE_MAX_DEPTH];
    int depths[SPDF_WIN_SIDEBAR_OUTLINE_MAX_DEPTH];
    int n = 0;
    int i, k;
    size_t used = 0;

    if (!out || out_cap == 0) return 0;
    out[0] = '\0';
    if (!levels || index < 0 || index >= count) return 0;
    for (i = 0; i <= index; ++i) {
        int level = levels[i];
        while (n > 0 && depths[n - 1] > level) --n;
        if (n > 0 && depths[n - 1] == level) {
            ordinals[n - 1] += 1;
        } else if (n < SPDF_WIN_SIDEBAR_OUTLINE_MAX_DEPTH) {
            depths[n] = level;
            ordinals[n] = 0;
            ++n;
        }
    }
    for (k = 0; k < n; ++k) {
        char piece[16];
        int len = _snprintf_s(piece, sizeof(piece), _TRUNCATE, k ? ".%d" : "%d", ordinals[k]);
        if (len < 0 || used + (size_t)len + 1 > out_cap) {
            out[0] = '\0';
            return 0;
        }
        memcpy(out + used, piece, (size_t)len);
        used += (size_t)len;
    }
    out[used] = '\0';
    return (int)used;
}

/* Is `key` one of the stored collapsed keys? Linear: the set is the handful of
 * chapters a reader folded, never the outline. */
static SPDF_WIN_SO_INLINE int spdf_win_sidebar_outline_key_in(const char* const* collapsed, int collapsed_count,
                                                              const char* key) {
    int i;
    if (!collapsed || !key || !key[0]) return 0;
    for (i = 0; i < collapsed_count; ++i)
        if (collapsed[i] && strcmp(collapsed[i], key) == 0) return 1;
    return 0;
}

/* The rows to display, one flag per row: every row except those with a
 * collapsed ancestor. A collapsed row is itself visible -- it is what the
 * reader clicks to expand (spdf_sidebar_outline_visible_indexes). The level of
 * the shallowest collapsed ancestor currently hiding rows is carried forward;
 * anything deeper than it stays hidden until a row at or above it appears --
 * which is the bug the mac's test guards: a sibling AFTER a collapsed section
 * must come back. Returns how many rows are visible. */
static SPDF_WIN_SO_INLINE int spdf_win_sidebar_outline_visible(const int* levels, int count,
                                                               const char* const* collapsed, int collapsed_count,
                                                               unsigned char* out_visible) {
    int hiding = 0;
    int hiding_level = 0;
    int shown = 0;
    int i;
    char key[SPDF_WIN_SIDEBAR_OUTLINE_KEY_MAX];

    if (!out_visible) return 0;
    for (i = 0; i < count; ++i) {
        int level = spdf_win_sidebar_outline_level_at(levels, count, i);
        if (hiding && level <= hiding_level) hiding = 0;
        out_visible[i] = (unsigned char)(hiding ? 0 : 1);
        if (hiding) continue;
        ++shown;
        if (collapsed_count > 0 && spdf_win_sidebar_outline_has_children(levels, count, i) &&
            spdf_win_sidebar_outline_key(levels, count, i, key, sizeof(key)) > 0 &&
            spdf_win_sidebar_outline_key_in(collapsed, collapsed_count, key)) {
            hiding = 1;
            hiding_level = level;
        }
    }
    return shown;
}

/* How many rows have children -- the size of what "collapse all" stores
 * (spdf_sidebar_outline_collapsible_keys.count). "Expand all" stores nothing,
 * which is also the default for a document never touched. */
static SPDF_WIN_SO_INLINE int spdf_win_sidebar_outline_collapsible_count(const int* levels, int count) {
    int n = 0;
    int i;
    for (i = 0; i < count; ++i)
        if (spdf_win_sidebar_outline_has_children(levels, count, i)) ++n;
    return n;
}

/* How many of those are NOT collapsed: the one expand / collapse button
 * collapses while this is non-zero and expands once it is zero
 * (toggleAllChapters:, updateChapterOutlineToggleForCollapsible:). */
static SPDF_WIN_SO_INLINE int spdf_win_sidebar_outline_open_count(const int* levels, int count,
                                                                  const char* const* collapsed, int collapsed_count) {
    int n = 0;
    int i;
    char key[SPDF_WIN_SIDEBAR_OUTLINE_KEY_MAX];
    for (i = 0; i < count; ++i) {
        if (!spdf_win_sidebar_outline_has_children(levels, count, i)) continue;
        if (collapsed_count > 0 && spdf_win_sidebar_outline_key(levels, count, i, key, sizeof(key)) > 0 &&
            spdf_win_sidebar_outline_key_in(collapsed, collapsed_count, key))
            continue;
        ++n;
    }
    return n;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SIDEBAR_OUTLINE_H */
