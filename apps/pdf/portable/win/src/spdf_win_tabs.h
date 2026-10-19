/* spdf_win_tabs.h — several documents open at once, one of them showing.
 *
 * IT OWNS NO WIN32 AND NO DIRECT2D, and it does not include spdf_win_canvas.h
 * either. That is the same discipline spdf_win_canvas.h states for itself, for
 * the same reason: the interesting behaviour here is policy — which tab gets
 * selected when you close the one you are looking at, what a restored session
 * costs before you touch it — and policy that can only be exercised through an
 * HWND is policy nobody can test. Everything below runs headlessly, which is
 * why portable/win/tests/tabs_test.c is a plain C program.
 *
 * A tab is a PATH plus the view state that belongs to that path (page, zoom,
 * fit mode, scroll offset) plus, once somebody actually looks at it, a
 * document. The document is deliberately an opaque `void*` supplied by a
 * caller-provided hook rather than a spdf_document*: it keeps this file free of
 * the core and of MuPDF, and it is what lets the lazy-restore test count
 * materialisations without opening a single PDF.
 *
 * ---------------------------------------------------------------------------
 * LAZY BY CONTRACT
 *
 * Restoring N tabs must not open or render N documents. Startup time is the
 * product's headline promise and it is the one thing a session feature can
 * quietly destroy: fifteen restored tabs that each open a document at launch
 * turn a 200 ms start into several seconds, and the user paid that for
 * fourteen documents they were not looking at.
 *
 * So NOTHING here opens a document as a side effect of existing. Exactly two
 * calls can invoke the open hook — spdf_win_tabs_document() and
 * spdf_win_tabs_select() — and spdf_win_session_restore() calls neither. The
 * deferred form, spdf_win_tabs_select_deferred(), moves the selection without
 * materialising anything, so a frontend can restore the persisted selection at
 * launch and let the first paint decide when to pay for it.
 * spdf_win_tabs_materialize_count() exists purely so a test can assert the
 * number of documents opened is the number the reader asked for.
 *
 * ---------------------------------------------------------------------------
 * THE CLOSE POLICY IS THE MAC APP'S, NOT AN INVENTED ONE
 *
 * Ported from portable/mac/SPDFMacTabLifecycle.{h,mm} and its call sites in
 * ShenzhenPDFMac.mm, so the two frontends feel the same:
 *
 *   - Every selection is recorded in an activation history, most recent first,
 *     keyed on tab IDENTITY. Identity, not path or index, because tabs get
 *     reordered and two tabs may hold the same path; a history keyed on either
 *     would restore the wrong tab. (SPDFMacTabLifecycle compares with `==` on
 *     the object; here it is the stable per-tab pointer.)
 *   - Closing a tab that is NOT selected leaves the selection on the same TAB
 *     (its index shifts down when the closed tab was to its left) —
 *     ShenzhenPDFMac.mm:9140.
 *   - Closing the SELECTED tab picks a replacement. Ctrl+W and the close box
 *     ask for the DETERMINISTIC ADJACENT tab — the one to the right, or the one
 *     to the left when the closed tab was last (ShenzhenPDFMac.mm:9115 passes
 *     preferMostRecentActive:NO). Detaching a tab into its own window asks for
 *     the most recently active survivor instead (:9300). Hence the
 *     prefer_most_recent_active argument rather than one hard-coded rule.
 *   - MRU falls back to adjacent when history holds no survivor.
 *   - Closing the last tab leaves the selection at -1. What a frontend does
 *     then is its own business: the mac app closes the window when another
 *     ShenzhenPDF window exists and otherwise shows "Open a document".
 */
#ifndef SPDF_WIN_TABS_H
#define SPDF_WIN_TABS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Same ceiling the GTK frontend applies to a restored window
 * (SPDF_STATE_MAX_SESSION_TABS), so a session file that one frontend accepts
 * is not silently truncated differently by another. */
#define SPDF_WIN_TABS_MAX 64

/* "fitMode" as it appears in the shared session schema
 * (portable/linux/gtk4/spdf_state_internal.h:61). Persisted as an integer, so
 * these values are file format and may not be renumbered. */
typedef enum spdf_win_tab_fit {
    SPDF_WIN_TAB_FIT_CUSTOM = 0,
    SPDF_WIN_TAB_FIT_ACTUAL = 1,
    SPDF_WIN_TAB_FIT_WIDTH = 2,
    SPDF_WIN_TAB_FIT_HEIGHT = 3,
    SPDF_WIN_TAB_FIT_PAGE = 4
} spdf_win_tab_fit;

/* The per-tab view state, one field per session key. Doubles rather than
 * floats because that is what the file carries and what the mac and GTK
 * frontends round-trip; the canvas takes floats and the frontend narrows at
 * that boundary. `page` is 0-BASED here and in the file, matching the mac
 * schema and spdf_win_main.cpp's rule; the GTK reader migrates its own legacy
 * 1-based pages on read. */
/* "searchText": the tab's live find query, UTF-8. Each tab remembers its query
 * across switches and relaunches (readme: "Scrollbar heat-map ... each tab
 * remembers its query"), which is why it is view state and not app state.
 * Fixed storage so the view stays a plain value the model can memcpy; the find
 * engine caps its own query anyway (spdf_win_search_dup_query). */
#define SPDF_WIN_TAB_SEARCH_MAX 256
/* The shadow copy's path: SPDF_WIN_WATCHER_PATH_MAX, spelled here so this header
 * stays free of the watcher's. */
#define SPDF_WIN_TAB_PATH_MAX 1024

typedef struct spdf_win_tab_view {
    int page;
    double zoom;
    double custom_zoom;
    int fit_mode;
    double scroll_x;
    double scroll_y;
    int has_scroll_origin;
    char search_text[SPDF_WIN_TAB_SEARCH_MAX];
    /* --- a read-only source and its shadow copy (spdf_win_watcher.h) ---------
     * "readOnly", "workingPath", "roCopyFileSize", "roCopyModifiedAt": the
     * binding the watcher hands out when the tab is opened and takes back on
     * restore, so an unchanged source reopens its copy with no content read.
     * Written only when read_only is set, as the mac omits the keys otherwise. */
    int read_only;
    char working_path[SPDF_WIN_TAB_PATH_MAX];
    unsigned long long ro_copy_file_size;
    double ro_copy_modified_at;
    /* "preservesImageColors": with the dark reading theme on, leave THIS
     * document's photographs and figures in their own colours. Per document,
     * as the mac made it (SPDFDocumentTab.preservesImageColors, 42e8c9ca7): a
     * datasheet whose figures are colour-coded keeps them while the scan in the
     * next tab is recoloured whole. 1 or 0 once chosen; -1 for a tab read from
     * a session written before the choice was per-document, which the frontend
     * seeds with settings.yaml's darkThemePreservesImages -- the launch default
     * for a new document, exactly as the mac seeds it. init() says 1, the
     * mac's own default, so a tab that never meets the seed still has an answer. */
    int preserves_image_colors;
    /* RUNTIME ONLY, never written: the source was gone for the watcher's whole
     * grace period (SPDF_WIN_WATCH_MISSING) and the strip colours the tab red
     * (SpdfWinChromeTab::missing). Cleared by the reopen that follows a CHANGED. */
    int missing;
} spdf_win_tab_view;

/* zoom 1, custom_zoom 1, fit_mode 4 (page) — the same defaults
 * spdf_session_window_add_tab() applies in the GTK frontend. */
void spdf_win_tab_view_init(spdf_win_tab_view* view);

typedef struct spdf_win_tabs spdf_win_tabs;

/* Materialise the document for `path`. Returns an opaque handle the model then
 * owns, or NULL after filling err. Called at most once per tab per
 * materialisation; a NULL return is remembered as an error but not cached, so
 * selecting the tab again retries. */
typedef void* (*spdf_win_tab_open_fn)(void* user, const char* path, char* err, size_t err_len);
typedef void (*spdf_win_tab_close_fn)(void* user, void* document);

spdf_win_tabs* spdf_win_tabs_create(void);
void spdf_win_tabs_destroy(spdf_win_tabs* tabs);

/* Without hooks the model still works and simply never materialises anything —
 * which is the state every pure-policy test runs in. */
void spdf_win_tabs_set_document_hooks(spdf_win_tabs* tabs, spdf_win_tab_open_fn open_fn, spdf_win_tab_close_fn close_fn,
                                      void* user);

int spdf_win_tabs_count(const spdf_win_tabs* tabs);
/* -1 when there are no tabs. */
int spdf_win_tabs_selected_index(const spdf_win_tabs* tabs);

/* Add a tab WITHOUT selecting it and without opening anything. `title` may be
 * NULL, in which case the path's last component is used. Returns the new
 * index, or -1 (no path, at SPDF_WIN_TABS_MAX, or out of memory). */
int spdf_win_tabs_insert(spdf_win_tabs* tabs, int index, const char* path, const char* title);
int spdf_win_tabs_append(spdf_win_tabs* tabs, const char* path, const char* title);

/* First tab holding this exact path, or -1. Byte comparison: normalising a
 * Windows path is a frontend decision and doing it here would make two tabs
 * the user deliberately opened from different roots collapse into one. */
int spdf_win_tabs_index_of_path(const spdf_win_tabs* tabs, const char* path);

/* Select and materialise. Returns 1 when the selection moved, 0 otherwise.
 * Re-selecting the current tab still records the activation. */
int spdf_win_tabs_select(spdf_win_tabs* tabs, int index);

/* Select WITHOUT materialising — the restore path, and the one a frontend uses
 * when the first paint has not happened yet. */
int spdf_win_tabs_select_deferred(spdf_win_tabs* tabs, int index);

/* Ctrl+Tab / Ctrl+Shift+Tab: move `delta` places in tab order, wrapping. */
int spdf_win_tabs_select_relative(spdf_win_tabs* tabs, int delta);

/* Close, applying the policy in this file's header. Returns the index selected
 * afterwards, or -1 when nothing is left; returns -1 for an out-of-range
 * index too, so callers that care should check the count. */
int spdf_win_tabs_close(spdf_win_tabs* tabs, int index, int prefer_most_recent_active);

/* Reorder. The selection follows the TAB, not the index. */
int spdf_win_tabs_move(spdf_win_tabs* tabs, int from, int to);

const char* spdf_win_tabs_path(const spdf_win_tabs* tabs, int index);
const char* spdf_win_tabs_title(const spdf_win_tabs* tabs, int index);
int spdf_win_tabs_set_title(spdf_win_tabs* tabs, int index, const char* title);

/* Mutable view state, valid until the tab is closed. NULL for a bad index. */
spdf_win_tab_view* spdf_win_tabs_view(spdf_win_tabs* tabs, int index);
const spdf_win_tab_view* spdf_win_tabs_view_const(const spdf_win_tabs* tabs, int index);

/* The document, opening it through the hook on first use. NULL when there is
 * no hook, the index is bad, or the open failed (err is filled). */
void* spdf_win_tabs_document(spdf_win_tabs* tabs, int index, char* err, size_t err_len);
int spdf_win_tabs_is_materialized(const spdf_win_tabs* tabs, int index);
/* Hand the document back to the close hook and forget it; the tab and its view
 * state stay. Lets a frontend cap how many documents are open at once without
 * losing the reader's place. */
void spdf_win_tabs_release_document(spdf_win_tabs* tabs, int index);

/* How many times the open hook has been INVOKED over this model's life. The
 * lazy-restore assertion: restore a ten-tab session, and this must still read
 * 0 until something is selected. */
unsigned long long spdf_win_tabs_materialize_count(const spdf_win_tabs* tabs);

/* Whether a "Close Tab" command should be enabled, ported verbatim from
 * spdf_mac_tab_close_action_enabled() (SPDFMacTabLifecycle.mm): a document with
 * no tab strip is still closable, and an out-of-range selection is not. */
int spdf_win_tabs_close_enabled(int tab_count, int selected_index, int has_open_document);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_TABS_H */
