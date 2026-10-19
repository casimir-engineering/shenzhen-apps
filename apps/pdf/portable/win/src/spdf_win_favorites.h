/* spdf_win_favorites.h — favorites.yaml: page and document favorites.
 *
 * THE SCHEMA IS SHARED with macOS and Linux (spdf_win_recents.h explains why
 * that matters). favorites.yaml is a top-level ARRAY of objects, each with --
 * in the sorted order both other writers use --
 *
 *   created   seconds since the epoch
 *   labels    array of strings, [] when none
 *   name      the display name ("<title> p.<n>" by default for a page)
 *   page      0-based
 *   path      the document
 *   title     the document's display title when the favorite was made
 *   type      "page" or "document"
 *
 * exactly as portable/linux/gtk4/spdf_state.c favorites_to_json emits it and
 * ShenzhenPDFMac.mm writes _favorites. The GTK3 wrapper form {"favorites":[…]}
 * with 1-based pages is read too, as the GTK4 reader does.
 *
 * THE DEDUPE RULE IS THE MAC'S: one document favorite per path, one page
 * favorite per (path, page); adding an existing one replaces it. The toggles
 * below are what Ctrl+D runs: add when absent, remove when present, the same
 * semantics as GTK's win.favorite-page / win.favorite-document.
 *
 * Files go through spdf_win_state.h's public entry points; process-wide state,
 * lazily loaded; UI thread only.
 */
#ifndef SPDF_WIN_FAVORITES_H
#define SPDF_WIN_FAVORITES_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* SPDF_STATE_MAX_FAVORITES */
#define SPDF_WIN_FAVORITES_MAX 4096
#define SPDF_WIN_FAVORITE_PATH_MAX 1024
#define SPDF_WIN_FAVORITE_TEXT_MAX 256
#define SPDF_WIN_FAVORITE_LABELS_MAX 512

typedef struct SpdfWinFavorite {
    char type[16]; /* "page" or "document" */
    char path[SPDF_WIN_FAVORITE_PATH_MAX];
    char title[SPDF_WIN_FAVORITE_TEXT_MAX];
    char name[SPDF_WIN_FAVORITE_TEXT_MAX];
    /* The labels array as raw JSON ("[]" when none), carried through verbatim:
     * this build does not edit labels, and re-emitting the text is how it does
     * not lose them. */
    char labels[SPDF_WIN_FAVORITE_LABELS_MAX];
    int page; /* 0-based */
    long long created;
} SpdfWinFavorite;

/* Forget the in-memory list; the next call reloads. Tests only. */
void spdf_win_favorites_reset(void);

int spdf_win_favorites_count(void);
/* NULL for a bad index. Valid until the next mutation. */
const SpdfWinFavorite* spdf_win_favorites_at(int index);

/* Index of the favorite matching (type, path[, page]) under the dedupe rule,
 * or -1. `page` is ignored for "document". */
int spdf_win_favorites_find(const char* type, const char* path, int page);

/* Add (replacing a duplicate) and write. Empty type reads as "page"; an empty
 * path is refused. Returns the new index or -1. */
int spdf_win_favorites_add(const SpdfWinFavorite* favorite);
/* Remove by index and write. Returns 1 when something was removed. */
int spdf_win_favorites_remove(int index);

/* Ctrl+D: toggle the current page. Returns 1 when a favorite was ADDED, 0 when
 * an existing one was removed, -1 on a bad argument. `title` may be NULL. */
int spdf_win_favorites_toggle_page(const char* path, const char* title, int page);
int spdf_win_favorites_toggle_document(const char* path, const char* title);

/* The favorites.yaml payload as JSON, malloc'd. For tests. */
char* spdf_win_favorites_json(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_FAVORITES_H */
