#pragma once

/* COMMAND HANDLERS: windows, presentation and full screen, sessions and settings.
 *
 * Header-only, included from spdf_win_chrome_commands.h only, after the app
 * struct, the chrome model and the input types are complete -- the same
 * arrangement as every other *_commands/*_actions header in this port. Owned
 * by the parity track of that name (portable/docs/windows-feature-matrix.md);
 * the other tracks have their own and none of them edits command_perform().
 *
 * Return 1 when the command was consumed, 0 to let it fall through.
 *
 * WHAT IS CLAIMED HERE AND WHY. Presentation (F5) and Full Screen (F11) are
 * this track's own. New Window and Move Tab to New Window are the multi-window
 * half: one process per window, the session file as the hand-over
 * (spdf_win_session_detach_tab). Keep Image Colors is the setting the View
 * menu already ticks from SPDF_RENDER_PRESERVE_IMAGES. Print is claimed too,
 * ahead of command_perform()'s own case, because the scaling choice (Fit /
 * Actual Size / Custom) lives in settings.yaml and the switch next door passes
 * a hard-coded default; claiming it here is how the choice reaches the job and
 * persists without editing that file. Close Other Tabs is claimed for the
 * plainest reason: nothing claimed it, so the menu row did nothing at all.
 */

#include "spdf_win_settings.h"

/* The canvas rect for a client area, with no event to hand: what the launch
 * uses to place the restored view before the window has ever painted. Here
 * because chrome_layout_for_input() is defined in spdf_win_chrome_actions.h
 * and only spdf_win_main.cpp's main() calls this, after every include. */
static void app_canvas_viewport(app* a, unsigned client_w, unsigned client_h, float dpi_scale, unsigned* out_w,
                                unsigned* out_h) {
    spdf_win_input in;
    SpdfWinChromeModel model;
    SpdfWinChromeLayout l;
    memset(&in, 0, sizeof(in));
    in.view_px_w = client_w;
    in.view_px_h = client_h;
    in.dpi_scale = dpi_scale;
    chrome_layout_for_input(a, &in, &model, &l);
    if (out_w) *out_w = (unsigned)l.canvas.w;
    if (out_h) *out_h = (unsigned)l.canvas.h;
}

/* Settings > Keep Image Colors in Dark Theme -- for THIS DOCUMENT. It used to
 * flip the one global setting; it now flips the selected tab's own choice, as
 * the mac's row does (-toggleDarkThemePreservesImages:, 42e8c9ca7): a datasheet
 * whose figures are colour-coded keeps them while the scan in the next tab is
 * recoloured whole. The choice is written to the session it will be restored
 * from (b551b24a9: the tab's keep-image-colors did not survive a relaunch until
 * the session writer carried it), and settings.yaml's darkThemePreservesImages
 * is left as it is -- it is the default a NEW document starts from
 * (spdf_win_tabs_app_seed_view), not this document's choice. The menu ticks
 * the row whatever the theme; the canvas is rebuilt only while dark, where the
 * choice means anything, over the same document with the reader's place kept
 * (chrome_rebuild_canvas). */
static int cmd_window_toggle_keep_image_colors(app* a) {
    spdf_win_tab_view* view = a->tabs ? spdf_win_tabs_view(a->tabs, spdf_win_tabs_selected_index(a->tabs)) : NULL;
    if (!view) return 0;
    view->preserves_image_colors = view->preserves_image_colors != 0 ? 0 : 1;
    a->render_flags = app_render_flags_for_selected_tab(a);
    app_session_save(a);
    if (!(a->render_flags & SPDF_RENDER_DARK_THEME)) return 1; /* nothing on screen changes; the tick did */
    return chrome_rebuild_canvas(a);
}

/* File > Print..., with the scaling choice. Loaded from settings.yaml, shown as
 * a page in the print dialog (spdf_win_print_scaling.h), and written back when
 * the reader printed -- which is when a choice was made.
 *
 * The page goes too: Windows' own dialog is watchdogged and may hand over to
 * the port's (spdf_win_print_dialog.h), whose "Current page" greys itself out
 * unless it is told which page that is. */
static int cmd_window_print(app* a) {
    SpdfWinDocAction act;
    spdf_win_settings* s = spdf_win_settings_shared();
    spdf_win_print_choice choice;
    char err[512] = {0};
    spdf_win_print_status status;
    if (!doc_action_for(a, &act)) return 0;
    choice.mode = (spdf_win_print_scaling_mode)s->print_scaling_mode;
    choice.custom_scale = s->print_custom_scale;
    status = spdf_win_print_document_for_view(act.hwnd, act.doc, act.path, &choice, act.page, err, sizeof(err));
    if (status == SPDF_WIN_PRINT_OK &&
        ((int)choice.mode != s->print_scaling_mode || choice.custom_scale != s->print_custom_scale)) {
        s->print_scaling_mode = (int)choice.mode;
        s->print_custom_scale = choice.custom_scale;
        spdf_win_settings_commit();
    }
    doc_action_report(a, err);
    return 1;
}

/* File > Close Other Tabs. The menu row existed with no handler anywhere, so
 * the item was drawn, enabled, and inert -- the reader's only way to clear a
 * crowded strip was N presses of Ctrl+W, each of which also moves the
 * selection.
 *
 * DESCENDING, COMPARING AGAINST THE ORIGINAL INDEX. spdf_win_tabs_close()
 * shifts every index ABOVE the closed one down by one and leaves the ones below
 * it alone, so a descending walk never revisits a tab that has moved. `keep`
 * itself shifts down as tabs to its left go, but it is only ever compared
 * against indices that are already known to be other tabs: those above it were
 * visited before any shift could reach it, and those below it are below it
 * whatever it has shifted to. The model half of that arithmetic is pinned in
 * portable/win/tests/tabs_test.c (test_close_others_keeps_the_selected_tab).
 *
 * NOT ONE chrome_close_tab() PER TAB. That function rebuilds the canvas and
 * writes session.yaml on every call, so routing twenty tabs through it would
 * throw the kept document's page cache away twenty times and hit the disk
 * twenty times to reach the same end state. The two things it does that MUST
 * happen per tab -- note the path for Reopen Last Closed Tab, and release the
 * watch and any shadow copy while the model still has the path -- are done per
 * tab here; the two that need happen once are done once, after.
 *
 * The kept tab's canvas is not rebuilt at all: it is the same document at the
 * same place, and only the strip's geometry changed. */
static int cmd_window_close_other_tabs(app* a) {
    int keep, i, closed = 0;
    if (!a->tabs) return 0;
    keep = spdf_win_tabs_selected_index(a->tabs);
    if (keep < 0) return 0;
    for (i = spdf_win_tabs_count(a->tabs) - 1; i >= 0; --i) {
        if (i == keep) continue;
        spdf_win_recents_note_closed(spdf_win_tabs_path(a->tabs, i));
        spdf_win_tabs_open_forget(a->tabs, i);
        spdf_win_tabs_close(a->tabs, i, 0);
        closed = 1;
    }
    if (!closed) return 0; /* one tab, or none: nothing to do and nothing to redraw */
    app_session_save(a);
    return 1;
}

/* --- RECEIVING A TAB DRAGGED IN FROM ANOTHER WINDOW ------------------------
 *
 * The other half of spdf_win_tabs_handoff.h, which explains the whole gesture
 * and why the three messages below are WM_COMMANDs. This window is not dragging
 * anything: it is being told that a tab is over its bar, that it no longer is,
 * or that it has been let go there.
 *
 * WHERE THE POINTER IS, ASKED OF WINDOWS. The messages carry no coordinates --
 * SPDF_WIN_INPUT_COMMAND has none to carry -- so the position comes from
 * GetCursorPos at the moment the message is handled. That is not a compromise:
 * the indicator has to be drawn where the pointer is when the frame appears,
 * and a position stamped a few milliseconds earlier by the other process would
 * be the wrong one to draw.
 *
 * THE INDICATOR IS THE REORDER DRAG'S. a->drag_tab and a->drop_slot are what
 * spdf_win_chrome_paint.cpp reads for the yellow line; setting both here draws
 * exactly the line a local reorder draws, at the gap the drop will use, with no
 * second field and no painter change. drag_tab is only a "there is a drag" flag
 * to the painter -- nothing else reads it -- and every existing path that ends
 * a gesture already clears both. */
static int cmd_window_drag_indicator(app* a, int slot) {
    if (slot == a->drop_slot && (slot < 0) == (a->drag_tab < 0)) return 0;
    a->drop_slot = slot;
    a->drag_tab = slot >= 0 ? spdf_win_ts_imax(0, spdf_win_tabs_selected_index(a->tabs)) : -1;
    return 1;
}

static int cmd_window_drag_over(app* a) {
    POINT pt;
    double strip_x = 0.0, strip_w = 0.0;
    HWND hwnd = a->window ? (HWND)spdf_win_window_native_handle(a->window) : NULL;
    if (!hwnd || !GetCursorPos(&pt)) return 0;
    if (!handoff_strip_hit(hwnd, pt, &strip_x, &strip_w)) return cmd_window_drag_indicator(a, -1);
    return cmd_window_drag_indicator(a, spdf_win_tabstrip_drop_slot(strip_w, spdf_win_tabs_count(a->tabs),
                                                                    spdf_win_tabs_selected_index(a->tabs), strip_x));
}

/* The tab was let go over this window's bar. It is parked in session.yaml under
 * the hand-off id and this window's job is to take it out, put it where the
 * indicator said, and show it -- keeping the page, zoom and search text the
 * other window recorded, which is the whole promise of the gesture.
 *
 * The slot is the one the LAST drag-over computed, so the tab lands in the gap
 * the reader was looking at rather than wherever the pointer has drifted to
 * between the release and this message. */
static int cmd_window_drag_drop(app* a) {
    char path[SPDF_WIN_TAB_PATH_MAX];
    char title[SPDF_WIN_TAB_PATH_MAX];
    spdf_win_tab_view view;
    int start = 0, visible = 0, at, slot = a->drop_slot;
    double strip_w = 0.0;
    POINT pt;
    HWND hwnd = a->window ? (HWND)spdf_win_window_native_handle(a->window) : NULL;

    cmd_window_drag_indicator(a, -1);
    if (!a->tabs) return 1;
    if (!spdf_win_session_handoff_take(path, sizeof(path), title, sizeof(title), &view)) return 1;

    /* The slot is among the VISIBLE tabs, so it needs the visible window's
     * start before it means an index (spdf_win_tabstrip_insert_index). A drop
     * with no remembered slot -- the release beat every drag-over -- appends. */
    if (slot >= 0 && hwnd && GetCursorPos(&pt) && handoff_strip_hit(hwnd, pt, NULL, &strip_w))
        spdf_win_tabstrip_visible_range(strip_w, spdf_win_tabs_count(a->tabs), spdf_win_tabs_selected_index(a->tabs),
                                        &start, &visible);
    at = slot >= 0 ? spdf_win_tabstrip_insert_index(start, slot, spdf_win_tabs_count(a->tabs))
                   : spdf_win_tabs_count(a->tabs);
    /* Where the reader is in the tab being left, before the selection moves. */
    spdf_win_tabs_app_remember(a->tabs, a->canvas);
    at = spdf_win_tabs_insert(a->tabs, at, path, title[0] ? title : NULL);
    if (at < 0) {
        /* THE TAB MUST NOT VANISH. This window is at SPDF_WIN_TABS_MAX (or out
         * of memory) and the other one has already let go, so the document
         * would be gone from the desktop with nobody holding it. Give it a
         * window of its own instead -- the same destination a release outside
         * every tab bar reaches. */
        spdf_win_tabs* one = spdf_win_tabs_create();
        char id[SPDF_WIN_SESSION_ID_MAX];
        if (!one) return 1;
        if (spdf_win_tabs_append(one, path, title[0] ? title : NULL) == 0) {
            *spdf_win_tabs_view(one, 0) = view;
            spdf_win_tabs_select_deferred(one, 0);
            spdf_win_session_new_window_id(id, sizeof(id));
            if (spdf_win_session_detach_tab_as(one, 0, NULL, id)) app_spawn_window(a, id);
        }
        spdf_win_tabs_destroy(one);
        return 1;
    }
    *spdf_win_tabs_view(a->tabs, at) = view;
    /* A tab handed over by a window that had no Keep Image Colors of its own
     * takes the default here, as a restored one does. */
    spdf_win_tabs_app_seed_view(spdf_win_tabs_view(a->tabs, at));
    /* The read-only binding travels with the tab, so the watcher must know
     * about the shadow copy BEFORE the tab is shown -- the same order the
     * session restore uses (spdf_win_tabs_open_prime). */
    spdf_win_tabs_open_prime(a->tabs);
    spdf_win_recents_note_opened(path, title[0] ? title : NULL);
    spdf_win_tabs_select_deferred(a->tabs, at);
    show_selected_tab(a);
    app_session_save(a);
    return 1;
}

static int spdf_win_cmd_window_perform(app* a, int command, const spdf_win_input* in) {
    (void)in;
    switch (command) {
        /* Another window's tab drag, over this one. Claimed here because this is
         * the multi-window track's file and these are multi-window messages;
         * see the note above. */
        case SPDF_WIN_TABS_CMD_DRAG_OVER: return cmd_window_drag_over(a);
        case SPDF_WIN_TABS_CMD_DRAG_LEAVE: return cmd_window_drag_indicator(a, -1);
        case SPDF_WIN_TABS_CMD_DRAG_DROP: return cmd_window_drag_drop(a);
        case SPDF_WIN_CMD_PRESENTATION:
            /* macOS refuses with no document (:13433 hasActiveDocument); a
             * presentation of nothing is a black screen with no way to know why. */
            if (!a->presentation && !a->canvas) return 0;
            return app_set_presentation(a, !a->presentation);
        case SPDF_WIN_CMD_FULLSCREEN: return app_toggle_fullscreen(a);
        case SPDF_WIN_CMD_NEW_WINDOW: return app_spawn_window(a, NULL);
        case SPDF_WIN_CMD_MOVE_TAB_TO_WINDOW:
            /* The DESTINATION, not the gesture: a menu row has no pointer to
             * follow, so it goes straight to a new window rather than through
             * the drag (spdf_win_chrome_tabs_ui.h). */
            return a->tabs ? chrome_detach_tab_into_new_window(a, spdf_win_tabs_selected_index(a->tabs)) : 0;
        case SPDF_WIN_CMD_CLOSE_OTHER_TABS: return cmd_window_close_other_tabs(a);
        case SPDF_WIN_CMD_TOGGLE_KEEP_IMAGE_COLORS: return cmd_window_toggle_keep_image_colors(a);
        case SPDF_WIN_CMD_PRINT: return cmd_window_print(a);
        default: return 0;
    }
}
