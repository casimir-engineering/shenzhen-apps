/* Folding the chapter list: the disclosure toggle, the one expand / collapse
 * button, and the press that reaches either.
 *
 * SPDFMacSidebarChapters.mm's toggleChapterAtSidebarRow:, toggleAllChapters:,
 * expandAllChapters: and collapseAllChapters: over the provider's view
 * (spdf_win_chrome_content.h, SpdfWinContentFoldView). Split from
 * spdf_win_chrome_content.cpp when that file passed the 500-line cap; the
 * provider keeps the document, the outline and the store, this unit keeps the
 * rules for changing the collapsed set and never touches a file itself. */
#include "spdf_win_chrome_content.h"

#include <stdlib.h>
#include <string.h>

namespace {

/* Every collapsible row's key: what "collapse all" stores
 * (spdf_sidebar_outline_collapsible_keys). malloc'd array of malloc'd keys. */
char** collapsible_keys(const SpdfWinContentFoldView* v, int* out_count) {
    char** keys;
    int i, n = 0;
    *out_count = 0;
    keys = (char**)calloc((size_t)(v->outline_count > 0 ? v->outline_count : 1), sizeof(char*));
    if (!keys) return NULL;
    for (i = 0; i < v->outline_count; ++i) {
        char key[SPDF_WIN_SIDEBAR_OUTLINE_KEY_MAX];
        if (!spdf_win_sidebar_outline_has_children(v->levels, v->outline_count, i)) continue;
        if (spdf_win_sidebar_outline_key(v->levels, v->outline_count, i, key, sizeof(key)) <= 0) continue;
        keys[n] = _strdup(key);
        if (keys[n]) ++n;
    }
    *out_count = n;
    return keys;
}

/* The current set with one key added or removed. */
char** collapsed_with(const SpdfWinContentFoldView* v, const char* key, int add, int* out_count) {
    char** keys = (char**)calloc((size_t)v->collapsed_count + 1, sizeof(char*));
    int i, n = 0;
    *out_count = 0;
    if (!keys) return NULL;
    for (i = 0; i < v->collapsed_count; ++i) {
        if (!v->collapsed[i] || strcmp(v->collapsed[i], key) == 0) continue;
        keys[n] = _strdup(v->collapsed[i]);
        if (keys[n]) ++n;
    }
    if (add) {
        keys[n] = _strdup(key);
        if (keys[n]) ++n;
    }
    *out_count = n;
    return keys;
}

} /* namespace */

int spdf_win_chrome_content_toggle_row(int row) {
    SpdfWinContentFoldView v;
    char key[SPDF_WIN_SIDEBAR_OUTLINE_KEY_MAX];
    char** keys;
    int count, index;

    if (!spdf_win_chrome_content_fold_view(&v)) return 0;
    if (!v.sidebar->rows || row < 0 || row >= v.sidebar->row_count) return 0;
    if (!v.sidebar->rows[row].has_children) return 0;
    index = v.sidebar->rows[row].outline_index;
    if (spdf_win_sidebar_outline_key(v.levels, v.outline_count, index, key, sizeof(key)) <= 0) return 0;
    keys = collapsed_with(&v, key, !v.sidebar->rows[row].collapsed, &count);
    if (!keys) return 0;
    spdf_win_chrome_content_fold_apply(keys, count);
    return 1;
}

int spdf_win_chrome_content_toggle_all(void) {
    SpdfWinContentFoldView v;
    char** keys;
    int count;

    if (!spdf_win_chrome_content_fold_view(&v)) return 0;
    if (v.sidebar->collapsible_count <= 0) return 0;
    /* Collapse while anything is still open, expand once nothing is. */
    if (v.sidebar->open_count > 0) {
        keys = collapsible_keys(&v, &count);
        if (!keys) return 0;
    } else {
        keys = NULL;
        count = 0;
    }
    spdf_win_chrome_content_fold_apply(keys, count);
    return 1;
}

int spdf_win_chrome_content_sidebar_press(int row, SpdfWinChromeRect sidebar, float x, float y, float dpi_scale) {
    SpdfWinContentFoldView v;
    SpdfWinSidebarLayout l;
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;

    if (!spdf_win_chrome_content_fold_view(&v)) return 0;
    spdf_win_sidebar_layout(sidebar, 0, s, &l);
    if (row < 0) {
        /* The filter row: the button's slot, only while the button is up. */
        if (!v.sidebar->loaded || v.sidebar->collapsible_count <= 0) return 0;
        if (!spdf_win_chrome_contains(l.toggle, x, y)) return 0;
        return spdf_win_chrome_content_toggle_all();
    }
    if (!v.sidebar->rows || row >= v.sidebar->row_count || !v.sidebar->rows[row].has_children) return 0;
    {
        SpdfWinChromeRect r = spdf_win_sidebar_row_rect(&l, v.sidebar->scroll_y, row);
        SpdfWinChromeRect d = spdf_win_sidebar_disclosure_rect(r, v.sidebar->rows[row].level, s);
        if (!spdf_win_chrome_contains(d, x, y)) return 0;
    }
    return spdf_win_chrome_content_toggle_row(row);
}
