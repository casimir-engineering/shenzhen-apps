#pragma once

/* spdf_win_app.h -- `struct app`: the one window's state, which every glue
 * header in spdf_win_main.cpp's include chain depends on.
 *
 * Moved out of spdf_win_main.cpp, whole and unchanged, when the wiring pass
 * brought that file to its 500-line cap (tools/file-size-limits.md asks for an
 * extracted file rather than a raised one). It is the declaration and nothing
 * else: no function, no static, so the order of everything that follows it in
 * spdf_win_main.cpp -- spdf_win_window_doc.h, spdf_win_session_app.h, the
 * chrome headers, the command switch -- is exactly what it was. Included from
 * spdf_win_main.cpp only, right where the struct stood; not part of the port's
 * public surface. The fields' own comments say what each is for; the file
 * that owns a field's behaviour is named beside it.
 */

#include "spdf_win_canvas.h"
#include "spdf_win_chrome_model.h"
#include "spdf_win_paths.h"   /* SPDF_WIN_PATH_MAX */
#include "spdf_win_session.h" /* SPDF_WIN_SESSION_ID_MAX, spdf_win_session_frame */
#include "spdf_win_tabs.h"
#include "spdf_win_window.h"

struct app {
    spdf_document* doc;
    char* path; /* UTF-8, owned; the render workers open their own handle to it */
    spdf_win_canvas* canvas;
    unsigned render_flags;
    /* Applied on the first paint, not at open: the canvas cannot place a page
     * until it knows how big the viewport is, and the viewport is not known
     * until the window has been laid out. -1 once it has been honoured. */
    int pending_page;
    /* Windowed: documents come from the model, and `doc`/`path` stay NULL. */
    spdf_win_tabs* tabs;
    spdf_win_window* window; /* set once the window exists; NULL on the headless paths */
    char window_id[SPDF_WIN_SESSION_ID_MAX];
    wchar_t status[512];
    /* Chrome. Both panels are VISIBLE BY DEFAULT, matching macOS
     * (ShenzhenPDFMac.mm:836-840) -- the widths are 0 here, which asks
     * spdf_win_chrome.h for its defaults (240 and 126.5). Not yet persisted:
     * session.yaml already carries showSidebar and minimapWidth and they are
     * still passed through untouched. */
    SpdfWinChromeModel chrome;
    SpdfWinChromeTabStore chrome_tabs; /* owns the UTF-16 titles `chrome` borrows */
    int show_sidebar;
    int show_minimap;
    float sidebar_w;
    float minimap_w;
    /* Hover, so the tab strip's close boxes light up. -1 for none, which is what
     * SpdfWinChromeModel documents; kept here rather than recomputed per paint
     * because the pointer's position is not something a paint can ask for. */
    int hot_tab;
    int hot_close;
    /* The gesture in progress, and where the pointer last was. The WINDOW holds
     * the capture; the app holds the meaning, because whether a drag pans the
     * document or resizes a panel depends on where it started -- see
     * spdf_win_chrome_actions.h. SPDF_WIN_CA_NONE when no button is down. */
    spdf_win_chrome_action drag;
    float drag_last_x;
    float drag_last_y;
    /* The tab being dragged to a new position and the insertion slot under the
     * pointer, or -1 for neither. Both go straight into the chrome model, whose
     * fields of the same names document them and say why the drop indicator is
     * not drawn yet. */
    int drag_tab;
    int drop_slot;
    /* THE THREE TYPEABLE FIELDS and which of them has the keyboard.
     *
     * Here rather than in the chrome model because they are the app's state,
     * not a description of a frame: the model is rebuilt from scratch every
     * paint (spdf_win_chrome_scene.h) and a query rebuilt every paint would be
     * an empty query. The model borrows the page text and the focus from these.
     *
     * The find query is ALSO pushed to the process-wide find session
     * (spdf_win_find_set_query) and the filter to the panel content bridge
     * (spdf_win_chrome_content_set_filter); those two calls are what replaced the
     * SPDF_FIND_QUERY / SPDF_FIND_REGEX / SPDF_SIDEBAR_FILTER environment
     * bridges. Each caret is an index into its own buffer, in wchar_t. */
    int focus; /* spdf_win_text_focus */
    wchar_t find_text[256];
    int find_caret;
    int find_regex;
    wchar_t page_text[16];
    int page_caret;
    wchar_t filter_text[128];
    int filter_caret;
    /* How many rows the sidebar's list drew last frame, so the input router can
     * work out which one a click landed on without resolving the content
     * provider on the pointer's path. */
    int sidebar_rows;
    /* The menu bar (an HMENU), owned by the window once it is installed. NULL on
     * every headless path, where nothing calls spdf_win_menu_create(). */
    void* menu;
    /* The scroll fraction the thumb had when a scroller drag was armed. A thumb
     * drag is absolute -- press position plus total pointer travel -- rather
     * than an accumulation of per-move deltas, so this is the only extra state
     * it needs, and drag_last_x/y stay pinned to the press for it. */
    float drag_scroll_pos;

    /* --- presentation and full screen (spdf_win_cmd_window.h) ------------
     *
     * `presentation` is F5: the chrome collapsed, both panels hidden, fit page,
     * the window full screen (ShenzhenPDFMac.mm:13432). `fullscreen` is what
     * the WINDOW is in, whether from F5 or from F11 alone. The saved fields are
     * what presentation puts back on exit (_presentationPrevious*). */
    int presentation;
    int fullscreen;
    int saved_show_sidebar;
    int saved_show_minimap;
    spdf_win_zoom_mode saved_zoom_mode;
    float saved_zoom;
    /* THE CANVAS VIEWPORT LAST LAID OUT -- device pixels and the DPI scale --
     * recorded by chrome_layout_for_input() on every input event, so a tab
     * switch can put the restored scroll offset back BEFORE the first paint
     * (spdf_win_tabs_app_apply_view). Zero until something has been laid out. */
    unsigned view_w;
    unsigned view_h;
    float view_dpi;
    /* Where a tab drag began, in strip-local points, for the detach test
     * (spdf_win_tabstrip_drag_detaches). */
    float drag_start_y;
    /* --state-dir, kept so a spawned window inherits it. Empty otherwise. */
    wchar_t state_dir[SPDF_WIN_PATH_MAX];
    /* The frame at exit, read before the window is destroyed and written into
     * the session after. */
    spdf_win_session_frame exit_frame;
};
