/* spdf_win_tabs_app.h — the glue between the tab/session model and the app's
 * one canvas.
 *
 * Header-only and included by exactly one translation unit
 * (spdf_win_main.cpp). It is a header rather than a .cpp for two reasons:
 * spdf_win_main.cpp is at its line cap and this work does not belong inside it,
 * and a new .cpp would have to be added to the app's source list, which lives
 * in another track's file. Nothing here is part of the port's public surface;
 * silent_failure_support.h and spdf_win_session_json.h are the same
 * arrangement.
 *
 * This is the ONLY place where the model layer and the Win32/Direct2D layer
 * meet. spdf_win_tabs.h and spdf_win_session.h own no Win32 and no Direct2D on
 * purpose, so that the close policy and the session schema can be tested
 * headlessly; that separation only holds if the glue lives outside them, which
 * is here.
 *
 * The shape it imposes on the frontend:
 *
 *   - The MODEL owns documents. spdf_win_tabs opens one through the hook below
 *     the first time a tab is shown, and closes it when the tab closes.
 *   - main.cpp owns ONE canvas, belonging to whichever tab is selected.
 *     Switching tabs destroys it and builds a new one over the new tab's
 *     document. A canvas per tab would be nicer to switch to and would hold
 *     every tab's page cache resident; one canvas is the version that keeps a
 *     restored fifteen-tab session honest about memory as well as about
 *     startup time.
 *   - Restoring a session costs paths and view state and NOTHING else. The
 *     document behind a tab is opened the first time that tab is shown, which
 *     for every tab but one is never.
 *
 * WHAT A TAB REMEMBERS, AND HOW IT COMES BACK. remember() writes the whole
 * view -- page, zoom, the fit mode as one of the schema's five values (not
 * collapsed to width/custom as it once was), the scroll offset, and the live
 * find query -- into the tab. apply_view() puts it back on a canvas that has a
 * viewport: fit mode first, then the page (which measures the pages above it,
 * so the layout is exact there), then the exact offset. That order is what
 * makes "resume exactly where you left off" exact rather than page-accurate,
 * and it is also what the theme toggle relies on to keep the reader's place
 * while it rebuilds the canvas.
 */
#ifndef SPDF_WIN_TABS_APP_H
#define SPDF_WIN_TABS_APP_H

#include "spdf_win_canvas.h"
#include "spdf_win_launch_profile.h" /* SPDF-LAUNCH markers; free when unset */
#include "spdf_win_recents.h"   /* the launch document is a recent document */
#include "spdf_win_tabs_open.h" /* the document hooks: password, shadow copy, watch */
#include "spdf_win_chrome_model.h" /* spdf_win_find_query_utf8: the query the tab remembers */
#include "spdf_win_session.h"
#include "spdf_win_settings.h" /* darkThemePreservesImages: the default a new document's own choice starts from */

/* The model's document hooks -- the password prompt, the read-only shadow copy
 * and the watch on the source -- are spdf_win_tabs_open.h's, included above.
 * The core allows one spdf_document per thread and the canvas takes its own
 * path for the render workers, so the hook opens one handle and that is all. */

/* The two enums, mapped both ways. The canvas's is the runtime's; the tab's is
 * the FILE FORMAT (spdf_state_internal.h:61) and may not be renumbered, which
 * is why the map is spelled out rather than cast. */
static int tabs_app_fit_for_zoom_mode(spdf_win_zoom_mode mode) {
    switch (mode) {
        case SPDF_WIN_ZOOM_FIT_WIDTH: return SPDF_WIN_TAB_FIT_WIDTH;
        case SPDF_WIN_ZOOM_FIT_HEIGHT: return SPDF_WIN_TAB_FIT_HEIGHT;
        case SPDF_WIN_ZOOM_FIT_PAGE: return SPDF_WIN_TAB_FIT_PAGE;
        case SPDF_WIN_ZOOM_ACTUAL: return SPDF_WIN_TAB_FIT_ACTUAL;
        default: return SPDF_WIN_TAB_FIT_CUSTOM;
    }
}

static spdf_win_zoom_mode tabs_app_zoom_mode_for_fit(int fit) {
    switch (fit) {
        case SPDF_WIN_TAB_FIT_WIDTH: return SPDF_WIN_ZOOM_FIT_WIDTH;
        case SPDF_WIN_TAB_FIT_HEIGHT: return SPDF_WIN_ZOOM_FIT_HEIGHT;
        case SPDF_WIN_TAB_FIT_PAGE: return SPDF_WIN_ZOOM_FIT_PAGE;
        case SPDF_WIN_TAB_FIT_ACTUAL: return SPDF_WIN_ZOOM_ACTUAL;
        default: return SPDF_WIN_ZOOM_FREE;
    }
}

/* Write the reader's current place back into the selected tab, so a tab switch
 * and the session file both remember it. The find query comes from the
 * process-wide find bridge, which holds the SELECTED tab's query -- show()
 * below is what makes that true on every switch. */
static void spdf_win_tabs_app_remember(spdf_win_tabs* tabs, spdf_win_canvas* canvas) {
    spdf_win_tab_view* view = spdf_win_tabs_view(tabs, spdf_win_tabs_selected_index(tabs));
    const char* query;
    if (!view || !canvas) return;
    view->page = spdf_win_canvas_current_page(canvas);
    view->zoom = (double)spdf_win_canvas_zoom(canvas);
    view->custom_zoom = view->zoom;
    view->fit_mode = tabs_app_fit_for_zoom_mode(spdf_win_canvas_zoom_mode(canvas));
    view->scroll_x = (double)spdf_win_canvas_scroll_x(canvas);
    view->scroll_y = (double)spdf_win_canvas_scroll_y(canvas);
    view->has_scroll_origin = 1;
    query = spdf_win_find_query_utf8();
    strncpy_s(view->search_text, sizeof(view->search_text), query ? query : "", _TRUNCATE);
}

/* Put a tab's remembered view onto its canvas. Needs the canvas's viewport --
 * fit zooms and the scroll clamp are functions of it -- so the caller passes
 * the canvas rect it last laid the chrome out against. Returns 1 when it
 * placed the view; 0 (nothing touched) with no canvas, no view or no viewport
 * yet, in which case the first paint's pending_page path places the page and
 * the offset is lost -- the pre-existing behaviour, now the fallback. */
static int spdf_win_tabs_app_apply_view(spdf_win_tabs* tabs, spdf_win_canvas* canvas, unsigned view_w,
                                        unsigned view_h, float dpi_scale) {
    const spdf_win_tab_view* view = spdf_win_tabs_view_const(tabs, spdf_win_tabs_selected_index(tabs));
    spdf_win_zoom_mode mode;
    if (!view || !canvas || view_w == 0 || view_h == 0) return 0;
    spdf_win_canvas_set_viewport(canvas, view_w, view_h, dpi_scale);
    mode = tabs_app_zoom_mode_for_fit(view->fit_mode);
    if (mode == SPDF_WIN_ZOOM_FREE) {
        if (view->zoom > 0.0) spdf_win_canvas_set_zoom_at(canvas, (float)view->zoom, 0.0f, 0.0f);
    } else {
        spdf_win_canvas_set_zoom_mode(canvas, mode);
    }
    /* The page first: it measures every page above it, so the offset that
     * follows lands on an exact layout rather than an estimated one. */
    spdf_win_canvas_scroll_to_page(canvas, view->page);
    if (view->has_scroll_origin) spdf_win_canvas_scroll_to(canvas, (float)view->scroll_x, (float)view->scroll_y);
    return 1;
}

/* A NEW tab -- one the reader just opened, as opposed to one restored from a
 * file -- starts at FIT WIDTH, which is what this frontend has opened every
 * document at since Phase 1 and what every pixel case and verify-phase1.ps1
 * compare against. The view's own default (spdf_win_tab_view_init) is fit
 * page, the mac and GTK default, and is right for a restored tab whose file
 * carries no fitMode; it is not the launch behaviour here. One place for the
 * rule, used by the launch document and by File > Open alike. */
/* KEEP IMAGE COLORS IS THE DOCUMENT'S OWN (spdf_win_tab_view::preserves_image_colors).
 * A tab that has no choice yet -- one the reader just opened, one restored
 * from a session written before the choice was per-document, one handed over
 * by such a window -- takes the launch default from settings.yaml
 * "darkThemePreservesImages", exactly as the mac seeds a new tab
 * (-seedKeepImageColorsForNewTab:, 42e8c9ca7). So an existing global choice is
 * not discarded, and the Settings row is what a NEW document starts from. */
static void spdf_win_tabs_app_seed_view(spdf_win_tab_view* view) {
    if (view && view->preserves_image_colors < 0)
        view->preserves_image_colors = spdf_win_settings_shared()->dark_theme_preserves_images ? 1 : 0;
}

static void spdf_win_tabs_app_seed_views(spdf_win_tabs* tabs) {
    int i, count = spdf_win_tabs_count(tabs);
    for (i = 0; i < count; ++i) spdf_win_tabs_app_seed_view(spdf_win_tabs_view(tabs, i));
}

static int spdf_win_tabs_app_append(spdf_win_tabs* tabs, const char* utf8_path) {
    int index = spdf_win_tabs_append(tabs, utf8_path, NULL);
    spdf_win_tab_view* view = spdf_win_tabs_view(tabs, index);
    if (view) {
        view->fit_mode = SPDF_WIN_TAB_FIT_WIDTH;
        view->preserves_image_colors = -1; /* a new document: the Settings default, seeded now */
        spdf_win_tabs_app_seed_view(view);
    }
    return index;
}

/* Point the canvas at the selected tab, materialising that tab's document if
 * this is the first time it has been shown. Returns non-zero when there is
 * something to draw. */
static int spdf_win_tabs_app_show(spdf_win_tabs* tabs, spdf_win_canvas** canvas, unsigned render_flags,
                                  int* pending_page) {
    int index = spdf_win_tabs_selected_index(tabs);
    char err[256] = {0};
    spdf_document* doc = index < 0 ? NULL : (spdf_document*)spdf_win_tabs_document(tabs, index, err, sizeof(err));

    spdf_win_canvas_destroy(*canvas);
    /* The render workers open their own handles by path: for a read-only
     * source that is the shadow copy the document itself came from, so every
     * handle on the tab agrees on the bytes (spdf_win_tabs_open_render_path). */
    *canvas = doc ? spdf_win_canvas_create(doc, spdf_win_tabs_open_render_path(tabs, index), render_flags, err,
                                           sizeof(err))
                  : NULL;
    if (*canvas) spdf_win_launch_mark("canvas-created");
    /* The restored page is applied on the first paint, not here: the canvas
     * cannot place a page until it knows the viewport. apply_view() above does
     * better when the caller knows one. */
    *pending_page = *canvas ? spdf_win_tabs_view(tabs, index)->page : -1;
    return *canvas != NULL;
}

/* How a launch finds its tabs. */
typedef enum spdf_win_tabs_app_restore {
    SPDF_WIN_TABS_APP_RESTORE_FIRST = 0, /* a plain launch: the window the reader was last using */
    SPDF_WIN_TABS_APP_RESTORE_ID = 1,    /* --window <id>: the window another process handed over */
    SPDF_WIN_TABS_APP_RESTORE_NONE = 2   /* --new-window: nothing, a fresh empty window */
} spdf_win_tabs_app_restore;

/* Build the tab model for this window: last session's tabs as metadata (or
 * the named window's, or none), plus the document the app was launched with,
 * selected. `window_id` is IN for RESTORE_ID and OUT always; `out_frame` gets
 * the restored window's frame, or zeros. */
static spdf_win_tabs* spdf_win_tabs_app_start(const char* utf8_path, spdf_win_tabs_app_restore how, char* window_id,
                                              size_t id_len, spdf_win_session_frame* out_frame) {
    spdf_win_tabs* tabs = spdf_win_tabs_create();
    char want[SPDF_WIN_SESSION_ID_MAX];
    int index, restored = 0;
    if (out_frame) memset(out_frame, 0, sizeof(*out_frame));
    if (!tabs) return NULL;
    /* The hook's user is the model itself, so the open can write the read-only
     * binding onto the tab it materialised (spdf_win_tabs_open.h). */
    spdf_win_tabs_set_document_hooks(tabs, tabs_app_open_document, tabs_app_close_document, tabs);
    /* An UNREADABLE session leaves the model empty AND must not be saved over;
     * spdf_win_session_save() refuses on its own, so there is nothing to do
     * here but carry on with the launch document. */
    spdf_win_launch_mark("session-restore-begin");
    strncpy_s(want, sizeof(want), window_id ? window_id : "", _TRUNCATE);
    if (how == SPDF_WIN_TABS_APP_RESTORE_FIRST)
        restored = spdf_win_session_restore_ex(tabs, NULL, window_id, id_len, out_frame) == SPDF_WIN_SESSION_RESTORED;
    else if (how == SPDF_WIN_TABS_APP_RESTORE_ID && want[0])
        restored = spdf_win_session_restore_ex(tabs, want, window_id, id_len, out_frame) == SPDF_WIN_SESSION_RESTORED;
    /* A handed-over id that is not in the file keeps the id it was given, so
     * the parent's later merge and ours agree about which window this is. */
    if (!restored && !(how == SPDF_WIN_TABS_APP_RESTORE_ID && want[0])) spdf_win_session_new_window_id(window_id, id_len);
    /* A restored tab with no Keep Image Colors of its own takes the default. */
    spdf_win_tabs_app_seed_views(tabs);
    /* Every restored read-only binding goes to the watcher BEFORE any tab is
     * shown, so an unchanged source reopens its copy without a content read. */
    spdf_win_tabs_open_prime(tabs);
    spdf_win_launch_mark_n("session-restored", spdf_win_tabs_count(tabs));
    index = utf8_path ? spdf_win_tabs_index_of_path(tabs, utf8_path) : -1;
    if (index < 0 && utf8_path) index = spdf_win_tabs_app_append(tabs, utf8_path);
    /* The launch document is a recent document, like one the picker chose. */
    if (utf8_path && index >= 0) spdf_win_recents_note_opened(utf8_path, NULL);
    if (index < 0) index = spdf_win_tabs_selected_index(tabs);
    if (index >= 0) spdf_win_tabs_select_deferred(tabs, index);
    return tabs;
}

/* The exit save. `focused` is whether this was the foreground window when it
 * closed (spdf_win_window_is_foreground), which stamps it as the one a
 * relaunch brings back in front. */
static void spdf_win_tabs_app_finish(spdf_win_tabs* tabs, spdf_win_canvas* canvas, const char* window_id,
                                     const spdf_win_session_frame* frame, int focused) {
    if (!tabs) return;
    spdf_win_tabs_app_remember(tabs, canvas);
    spdf_win_session_save_focused(tabs, window_id, frame, focused);
    spdf_win_canvas_destroy(canvas);
    spdf_win_tabs_destroy(tabs);
}

#endif /* SPDF_WIN_TABS_APP_H */
