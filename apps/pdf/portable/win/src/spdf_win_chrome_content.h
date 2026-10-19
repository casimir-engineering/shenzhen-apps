/* spdf_win_chrome_content.h — what the sidebar and the minimap actually SHOW.
 *
 * The chrome painters were given geometry (spdf_win_chrome.h) and colours
 * (spdf_win_chrome_theme.h) but no content: the sidebar drew grey bars where
 * chapter titles go and the minimap drew grey lines where thumbnails go. This
 * header is the content layer, and it is deliberately a separate file from both
 * of them because content has a different lifetime from a frame: an outline is
 * loaded once per document and a thumbnail arrives from a worker thread
 * milliseconds or seconds after the frame that first wanted it.
 *
 * THREE RULES SHAPE EVERYTHING BELOW.
 *
 *   1. NOTHING HERE MAY RENDER ON THE PAINT PATH. A painter may only LOOK UP a
 *      thumbnail; producing one is a request to spdf_win_render.h's worker pool,
 *      and a page whose thumbnail has not arrived draws the placeholder. So
 *      every accessor is O(1)-ish and none of them can block. This is the
 *      standing speed rule, and it is why `thumb` returns an int rather than
 *      pixels-or-else.
 *
 *   2. NOTHING HERE MAY RUN ON THE LAUNCH PATH. The outline is loaded on the
 *      first paint that actually needs a chapter list -- not at open -- so
 *      --render-png, the probe, presentation mode and a hidden sidebar pay
 *      exactly nothing. The thumbnail service starts no threads until the first
 *      thumbnail is requested (spdf_win_render.h spawns workers lazily for the
 *      same reason).
 *
 *   3. THE PAINTERS TAKE THIS AS A PARAMETER. spdf_win_chrome_paint.h's ctx
 *      cannot carry it (that header belongs to another track), so
 *      spdf_win_chrome_paint_panels() resolves the provider ONCE at the top and
 *      threads it down as an argument. No drawing function reads it from ambient
 *      state -- see the note on spdf_win_chrome_content_current() for the exact
 *      shape of that seam and what is meant to replace it.
 *
 * C-compatible on purpose: no Direct2D types appear here. The Chapters list's
 * own half -- its rows, bands, disclosure geometry and the outline -> rows
 * builder -- is spdf_win_sidebar_rows.h, included below, so
 * portable/win/tests/sidebar_rows_test.c compiles it as plain C with no render
 * target in sight; this file is the seam and the folding calls.
 */
#ifndef SPDF_WIN_CHROME_CONTENT_H
#define SPDF_WIN_CHROME_CONTENT_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <wchar.h>

#include "spdf_win_chrome.h"
#include "spdf_win_layout.h"          /* SpdfWinPageSizePt */
#include "spdf_win_sidebar_rows.h"    /* the Chapters list: rows, bands, builder */

#ifdef __cplusplus
extern "C" {
#endif

/* --- the minimap's thumbnails -------------------------------------------
 *
 * `thumb` is the only accessor a painter gets, and it is a LOOKUP: it returns 0
 * for a page whose thumbnail is not in the store yet and the painter draws the
 * grey placeholder. `request` is how the store learns which pages are on screen
 * so its bounded window (spdf_win_minimap.h) can follow them and queue what is
 * missing on the render pool. Neither one renders. */
typedef struct SpdfWinMinimapThumb {
    int width;
    int height;
    int stride;
    const unsigned char* rgba; /* borrowed; valid until the next request/drain */
    unsigned revision;         /* bumped when these pixels are replaced, so a
                                * cached device bitmap knows to be rebuilt */
} SpdfWinMinimapThumb;

typedef struct SpdfWinMinimapContent {
    const SpdfWinPageSizePt* sizes; /* page_count entries, PDF points */
    int page_count;
    int current_page;       /* the page whose slot gets the grey outline; -1 for none */
    double scroll_fraction; /* [0,1], drives content_top and the viewport band */
    double doc_h;           /* document height and viewport height in the same */
    double doc_visible_h;   /* unit; only their RATIO is used */
    int (*thumb)(void* ctx, int page, SpdfWinMinimapThumb* out);
    void (*request)(void* ctx, int first, int last, double panel_w, double side_inset, int dark);
    void* ctx;
} SpdfWinMinimapContent;

/* Both panels' content in one value, because the panels painter resolves it
 * once per frame and hands each half to its own painter. */
typedef struct SpdfWinChromePanelsContent {
    const SpdfWinSidebarContent* sidebar;
    const SpdfWinMinimapContent* minimap;
} SpdfWinChromePanelsContent;

/* THE SEAM, AND WHY IT IS SHAPED LIKE THIS.
 *
 * The right home for this is the scene: spdf_win_scene already carries
 * `chrome`, and one more pointer beside it would let spdf_win_main.cpp hand the
 * painters the outline and thumbnail store it already has a document for, with
 * no global anywhere. That is a field on a struct owned by another track, so it
 * is REQUESTED rather than taken (see this change's report).
 *
 * Until then: `attach` installs a provider, and `current` returns it.
 * spdf_win_chrome_paint_panels() calls `current` ONCE, at the top of the frame,
 * and passes the result down as an argument -- so the drawing code itself is
 * still pure, still takes everything as parameters, and still needs no HWND. A
 * provider that was never attached falls back to the built-in one in
 * spdf_win_chrome_content.cpp, which finds the document on the process command
 * line. That fallback is a temporary bridge and says so at its definition. */
void spdf_win_chrome_content_attach(const SpdfWinChromePanelsContent* content);
const SpdfWinChromePanelsContent* spdf_win_chrome_content_current(void);

/* Tells the bridge WHICH document is selected and where the reader is in it.
 * Called once per paint from the app, which is the only thing that knows.
 *
 * Without this the bridge guesses from the process command line, so the panels
 * kept showing the LAUNCH document after a Ctrl+Tab -- the sidebar listed the
 * wrong outline and the minimap the wrong thumbnails, while the canvas beside
 * them showed the right pages. Passing the canvas's live current page also makes
 * the minimap's current-page outline and viewport box follow scrolling instead
 * of pinning to the page the window opened on.
 *
 * `utf8_path` NULL or empty means "no document" (the last tab is closing) and
 * releases everything. A repeated call with the same path is a string compare
 * and two stores, because it runs every frame. Does nothing at all once a real
 * provider has been attached. */
void spdf_win_chrome_content_set_document(const char* utf8_path, int current_page);

/* THE FILTER FIELD'S TEXT, UTF-16, copied. NULL or empty means no filter, which
 * shows every row.
 *
 * WHAT THIS REPLACED: SPDF_SIDEBAR_FILTER, one getenv read on the first sidebar
 * paint, documented as temporary at its definition because no keyboard input
 * reached this track. The field is typeable now and the environment variable is
 * gone.
 *
 * Cheap to call on every keystroke and no-op when nothing changed: it compares,
 * copies at most 127 units, and marks the row list stale. The rebuild happens on
 * the next spdf_win_chrome_content_current(), i.e. on the paint that needs it,
 * and re-filters the outline already in memory rather than reopening the
 * document. Does nothing once a real provider has been attached. */
void spdf_win_chrome_content_set_filter(const wchar_t* filter);

/* Releases the document handle, the outline strings, the thumbnail store and
 * the render service the built-in provider owns, joining the store's threads.
 * Idempotent, and safe with nothing ever having been opened.
 *
 * NOBODY CALLS IT YET, and that is deliberate rather than forgotten. Its place
 * is beside spdf_win_chrome_paint_shutdown() in spdf_win_d2d_destroy(), which is
 * another track's file; requesting one line there is better than installing an
 * atexit handler from here, which would run during CRT teardown and could turn a
 * blocked worker into a hang on exit -- and `close.exits_zero` currently passes
 * without it, because the process teardown reclaims the threads anyway. See this
 * change's report. */
void spdf_win_chrome_content_shutdown(void);

/* --- folding (spdf_win_chrome_content.cpp) --------------------------------
 *
 * WHERE THE MEMORY IS KEPT is a seam, not a dependency. The provider asks a
 * SpdfWinChapterStore for the document's collapsed keys when it loads the
 * outline and hands them back on every change; spdf_win_chapter_state.cpp is
 * that store (chapters.yaml beside documents.yaml, and the mac's own record as
 * the fallback), and spdf_win_chapter_store_register.cpp REGISTERS it when
 * linked, which the app always is. A binary that does not link that unit --
 * the pixel tests, which link this provider for its rows and thumbnails --
 * folds for the session only and touches no file. The seam is what keeps the
 * state module's four translation units (spdf_win_state, spdf_win_paths,
 * spdf_yaml, spdf_win_compat) out of every painter test's link line;
 * portable/win/tests/sidebar_collapse_test.c links the store and proves the
 * memory survives a release and a reopen. */
typedef struct SpdfWinChapterStore {
    /* 1 and a malloc'd array (free with free_keys) when a record exists. */
    int (*load)(const char* utf8_path, char*** out_keys, int* out_count);
    /* Persist `count` keys for the path; 0 removes the record. */
    int (*save)(const char* utf8_path, const char* const* keys, int count);
    void (*free_keys)(char** keys, int count);
} SpdfWinChapterStore;
void spdf_win_chrome_content_set_chapter_store(const SpdfWinChapterStore* store);

/* THE PROVIDER'S HALF OF FOLDING, for spdf_win_chrome_content_fold.cpp: a view
 * of what the built-in provider holds -- the rows as shown, the outline's raw
 * levels, the collapsed keys -- and the one way to replace the keys. `view`
 * loads the outline if it has not been (a press is not the paint path) and
 * returns 0 when a real provider is attached or there is no outline. `apply`
 * takes ownership of a malloc'd key array, writes it through the store, and
 * marks the rows stale; the next spdf_win_chrome_content_current() -- the
 * paint that needs them -- rebuilds from the outline already in memory. */
typedef struct SpdfWinContentFoldView {
    const SpdfWinSidebarContent* sidebar; /* rows, counts, filter, scroll */
    const int* levels;                    /* the outline's raw levels, outline_count of them */
    int outline_count;
    const char* const* collapsed;
    int collapsed_count;
} SpdfWinContentFoldView;
int spdf_win_chrome_content_fold_view(SpdfWinContentFoldView* out);
void spdf_win_chrome_content_fold_apply(char** keys, int count);

/* The three ways the collapse state changes (spdf_win_chrome_content_fold.cpp),
 * all on the built-in provider's document and all written through the store so
 * a relaunch restores exactly what was collapsed. Return non-zero when
 * something changed. */

/* Fold or unfold the chapter at visible `row` (toggleChapterAtSidebarRow:). A
 * row without children, or out of range, changes nothing. */
int spdf_win_chrome_content_toggle_row(int row);

/* The one button: collapse every chapter while any is open, expand every one
 * once none is (toggleAllChapters:). Nothing nestable: nothing happens. */
int spdf_win_chrome_content_toggle_all(void);

/* A LEFT PRESS the router attributed to the Chapters list or its filter field,
 * refined against the content: on a row's disclosure triangle it folds that
 * row; on the toggle button's slot, while the button is up, it toggles all.
 * Returns 1 when it consumed the press, 0 when the caller should do what it
 * would have done -- navigate to the row, or focus the field. `row` is the
 * router's index for SPDF_WIN_CA_SIDEBAR_ROW and -1 for
 * SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER; `sidebar` the layout's panel rect the click
 * was routed against; x/y the press in the same client device pixels.
 *
 * WHY THE ROUTER DOES NOT DECIDE THIS ITSELF: the triangle's x depends on the
 * row's LEVEL and whether it has children, and the router has the model's row
 * count and nothing else -- resolving the content provider on a mouse move
 * would put an outline load on the pointer's path. On a press the content is
 * already warm, because the paint that drew the row resolved it. */
int spdf_win_chrome_content_sidebar_press(int row, SpdfWinChromeRect sidebar, float x, float y, float dpi_scale);


#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_CHROME_CONTENT_H */
