#pragma once

#include "spdf_win_print.h" /* spdf_win_print_allowed, for greying Print */

/* spdf_win_chrome_tabs_ui.h -- the TAB STRIP's commands: select, close, open,
 * the overflow menu and drag-to-reorder.
 *
 * Split out of spdf_win_chrome_actions.h, which had grown past the 500-line cap
 * (tools/file-size-limits.md) as the strip's three inert controls became live.
 * The seam is a real one rather than a convenience: everything here changes the
 * SET OF OPEN DOCUMENTS or their order, while what is left next door changes the
 * one document the reader is looking at. They meet at exactly two functions --
 * show_selected_tab() and spdf_win_tabs_app_remember(), both of which belong to
 * spdf_win_main.cpp and spdf_win_tabs_app.h respectively.
 *
 * Header-only and included from spdf_win_main.cpp AFTER `struct app` and
 * spdf_win_chrome_scene.h, and BEFORE spdf_win_chrome_actions.h, which calls
 * every function here from chrome_perform(). Same arrangement as
 * spdf_win_tabs_app.h and spdf_win_headless_viewport.h beside it; not part of
 * the port's public surface.
 */

/* The Open dialog and the tab overflow popup. Both are MODAL Win32 calls made
 * from a click, which is why they are reachable from here and not from
 * spdf_win_chrome_input.h: deciding what a click means must stay pure, and
 * running a nested message loop is the opposite of pure. */
#include "spdf_win_menu.h"
#include "spdf_win_recents.h" /* what a close and an open tell the reopen ring and the MRU list */

/* Close a tab from the strip. prefer_most_recent_active is 0, matching
 * ShenzhenPDFMac.mm:9115 -- the close box and Ctrl+W both ask for the
 * DETERMINISTIC ADJACENT survivor, and only detaching a tab into its own window
 * asks for the most recently active one (:9300). Getting that argument backwards
 * would make the close box feel like a different app from Ctrl+W. */
static int chrome_close_tab(app* a, int index) {
    int shown;
    if (!a->tabs || index < 0) return 0;
    /* Remembered for Reopen Last Closed Tab, and the watch and any shadow copy
     * released, while the model still has the path. The close box, Ctrl+W and
     * a middle-click all come through here; Close Other Tabs does the same two
     * per-tab steps in its own loop rather than paying for a canvas rebuild and
     * a session write per tab (spdf_win_cmd_window.h). */
    spdf_win_recents_note_closed(spdf_win_tabs_path(a->tabs, index));
    spdf_win_tabs_open_forget(a->tabs, index);
    if (index == spdf_win_tabs_selected_index(a->tabs)) spdf_win_tabs_app_remember(a->tabs, a->canvas);
    spdf_win_tabs_close(a->tabs, index, 0);
    /* THE LAST TAB CLOSING IS NOT THE APP QUITTING. macOS (spdf_win_tabs.h's
     * header, from ShenzhenPDFMac.mm): the window closes when another
     * ShenzhenPDF window exists, and otherwise stays open showing "Open a
     * document" -- the same empty window a bare launch opens. It used to quit
     * here, which on a one-window desktop meant Ctrl+W on the last tab was Quit.
     * Another window means another PROCESS, and the session file is where the
     * two know about each other. */
    if (spdf_win_tabs_count(a->tabs) == 0) {
        show_selected_tab(a); /* NULL canvas: the empty window's chrome */
        app_session_save(a);  /* removes this window from the file */
        if (spdf_win_session_other_windows(a->window_id) > 0 && a->window)
            PostMessageW((HWND)spdf_win_window_native_handle(a->window), WM_CLOSE, 0, 0);
        return 1;
    }
    shown = show_selected_tab(a);
    app_session_save(a);
    return shown;
}

static int chrome_select_tab(app* a, int index) {
    int shown;
    if (!a->tabs || index < 0 || index == spdf_win_tabs_selected_index(a->tabs)) return 0;
    spdf_win_tabs_app_remember(a->tabs, a->canvas);
    spdf_win_tabs_select_deferred(a->tabs, index);
    shown = show_selected_tab(a);
    app_session_save(a);
    return shown;
}

/* --- ANOTHER WINDOW IS ANOTHER PROCESS -----------------------------------
 *
 * spdf_win_chrome_model.h states the rule -- "one window per process
 * (multi-window is multi-process, per session.yaml's window ids)" -- and this
 * is where it is kept. File > New Window starts a second ShenzhenPDF.exe with
 * `--new-window` (an empty window, a fresh id); Move Tab to New Window and a
 * tab torn off the strip write the tab into session.yaml under a new id first
 * (spdf_win_session_detach_tab) and start the exe with `--window <id>`, which
 * restores exactly that one. --state-dir is passed along when this process
 * was given one, so a test's two windows share the test's file.
 *
 * CreateProcessW on our own image (GetModuleFileNameW), no shell, no working
 * directory: the child needs nothing from the environment that it does not
 * read from session.yaml. Returns 1 when the process started. */
static int app_spawn_window(app* a, const char* utf8_window_id) {
    wchar_t exe[MAX_PATH * 4];
    wchar_t cmd[MAX_PATH * 8];
    wchar_t id[SPDF_WIN_SESSION_ID_MAX];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    int ok;
    if (!GetModuleFileNameW(NULL, exe, (DWORD)(sizeof(exe) / sizeof(exe[0])))) return 0;
    if (utf8_window_id && *utf8_window_id) {
        if (MultiByteToWideChar(CP_UTF8, 0, utf8_window_id, -1, id, (int)(sizeof(id) / sizeof(id[0]))) <= 0) return 0;
        _snwprintf_s(cmd, _TRUNCATE, L"\"%s\" --window %s", exe, id);
    } else {
        _snwprintf_s(cmd, _TRUNCATE, L"\"%s\" --new-window", exe);
    }
    if (a->state_dir[0]) {
        size_t n = wcslen(cmd);
        _snwprintf_s(cmd + n, sizeof(cmd) / sizeof(cmd[0]) - n, _TRUNCATE, L" --state-dir \"%s\"", a->state_dir);
    }
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));
    ok = CreateProcessW(exe, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi) ? 1 : 0;
    if (ok) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    return ok;
}

/* Detach tab `index` into a new window. The order matters and is the mac's
 * (:9300, -detachTabAtIndex:): the tab's view is written back if it is the one
 * showing, the hand-over goes to disk under a new id, THIS window drops the tab
 * and saves itself -- so the file is consistent before the child reads it --
 * and only then is the child started. Closing the detached tab asks for the
 * MOST RECENTLY ACTIVE survivor, not the adjacent one: that is the one place
 * spdf_win_tabs_close's second argument is 1. A window with one tab does not
 * detach it; that would be two windows where the reader had one.
 *
 * THIS IS THE DESTINATION, NOT THE GESTURE. File > Move Tab to New Window
 * arrives here directly; a tab dragged off the strip arrives here only if the
 * reader lets go outside every tab bar, because the drag can still be slid back
 * or dropped into another window first. That whole gesture is
 * chrome_detach_tab() in spdf_win_tabs_handoff.h, included at the foot of this
 * file, and it is what spdf_win_chrome_actions.h's drag arm calls. */
static int chrome_detach_tab_into_new_window(app* a, int index) {
    spdf_win_session_frame frame;
    char new_id[SPDF_WIN_SESSION_ID_MAX];
    if (!a->tabs || index < 0 || index >= spdf_win_tabs_count(a->tabs) || spdf_win_tabs_count(a->tabs) < 2) return 0;
    if (index == spdf_win_tabs_selected_index(a->tabs)) spdf_win_tabs_app_remember(a->tabs, a->canvas);
    /* The new window opens the size of this one, cascaded a little, so it is
     * visibly a second window and not this one moved. */
    frame = app_session_frame(a);
    if (frame.w > 0) {
        frame.x += 40;
        frame.y += 40;
    }
    if (!spdf_win_session_detach_tab(a->tabs, index, &frame, new_id, sizeof(new_id))) return 0;
    /* Unwatched, not forgotten: the copy (if any) is the child process's now. */
    spdf_win_tabs_open_unwatch(spdf_win_tabs_path(a->tabs, index));
    spdf_win_tabs_close(a->tabs, index, 1);
    show_selected_tab(a);
    app_session_save(a);
    app_spawn_window(a, new_id);
    return 1;
}

/* OPEN A DOCUMENT IN A NEW TAB. A path already open selects its tab instead of
 * opening a second one, which is spdf_win_tabs_app_start()'s own rule for the
 * launch document and the behaviour a reader expects from re-opening a file.
 *
 * The reader's place in the tab being left is written back FIRST, exactly as
 * every other tab switch in this file does, or returning to it lands on the page
 * it was opened at rather than the page it was left at. */
static int chrome_open_wide(app* a, const wchar_t* wpath) {
    char* utf8;
    int index;
    if (!a->tabs || !wpath || !wpath[0]) return 0;
    utf8 = utf8_from_wide(wpath);
    if (!utf8) return 0;
    index = spdf_win_tabs_index_of_path(a->tabs, utf8);
    if (index < 0) index = spdf_win_tabs_app_append(a->tabs, utf8); /* fit width, like the launch document */
    /* Every way in -- the picker, a drop, Open Path, a recent, the palette --
     * ends here, so this is where a document becomes a recent one. */
    if (index >= 0) spdf_win_recents_note_opened(utf8, spdf_win_tabs_title(a->tabs, index));
    free(utf8);
    if (index < 0) return 0; /* at SPDF_WIN_TABS_MAX, or out of memory */
    if (index == spdf_win_tabs_selected_index(a->tabs)) return 0;
    spdf_win_tabs_app_remember(a->tabs, a->canvas);
    spdf_win_tabs_select_deferred(a->tabs, index);
    index = show_selected_tab(a);
    app_session_save(a); /* a new tab is worth remembering before exit */
    return index;
}

/* GIVE THE MOUSE BACK BEFORE OPENING ANYTHING MODAL.
 *
 * Both of the modal calls below can be reached from a WM_LBUTTONDOWN -- the
 * strip's `+` and its `...` -- and at that moment spdf_win_window.cpp is holding
 * the mouse CAPTURE, because a press might have been the start of a drag.
 * TrackPopupMenu will not track correctly against a live capture, and a file
 * dialog opened under one leaves the press hanging: the button comes up over
 * another window, so the WM_LBUTTONUP that would have ended the gesture never
 * arrives here.
 *
 * ReleaseCapture() answers both. It synchronously sends WM_CAPTURECHANGED, which
 * the window turns into a CANCELLED press (spdf_win_window.h's SPDF_WIN_CB_NONE
 * contract) -- the exact path an Alt+Tab or a system modal already takes, so the
 * drag state is cleared by the code that exists to clear it rather than by a
 * second copy here. */
static void chrome_release_capture(app* a) {
    HWND hwnd = a->window ? (HWND)spdf_win_window_native_handle(a->window) : NULL;
    if (hwnd && GetCapture() == hwnd) ReleaseCapture();
}

static int chrome_open_dialog(app* a) {
    wchar_t path[1024];
    if (!a->window) return 0;
    chrome_release_capture(a);
    if (!spdf_win_menu_open_dialog(spdf_win_window_native_handle(a->window), path,
                                   (int)(sizeof(path) / sizeof(path[0]))))
        return 0;
    return chrome_open_wide(a, path);
}

/* The strip's `...`. Every tab, not only the hidden ones: macOS's overflow list
 * is the whole document list, and a menu that showed only what is off-screen
 * would change contents as the window is resized.
 *
 * The titles are the ones the LAST PAINT converted (a->chrome_tabs), so the menu
 * says exactly what the strip says and no conversion happens on the click. */
/* The TOOLBAR's `...`: the whole app menu, as a popup.
 *
 * This is where the menu lives now that the app has no menu bar. The bar was a
 * strip macOS does not have -- its menus are in the system menu bar, not in the
 * window -- and on a dark desktop the Win32 bar stayed white however the process
 * was themed, which read as a second title bar. See spdf_win_menu_app_popup().
 *
 * THE CHOICE IS POSTED AS A WM_COMMAND rather than performed here, and that is
 * not indirection for its own sake: command_perform() lives in
 * spdf_win_chrome_commands.h, which spdf_win_main.cpp includes AFTER this file,
 * so it is not callable from here. Posting sends the choice down the same route
 * an accelerator already takes -- WM_COMMAND, then SPDF_WIN_INPUT_COMMAND, then
 * command_perform -- so a menu pick and a keystroke cannot diverge, which is
 * worth more than saving a message.
 *
 * Right-aligned under the button: it sits at the trailing end of the toolbar and
 * a left-aligned popup would hang off the window. */
static int chrome_app_menu(app* a, const SpdfWinChromeLayout* l) {
    SpdfWinToolbarLayout tb;
    SpdfWinMenuState st;
    SpdfWinChromeRect cell;
    POINT pt;
    void* hwnd = a->window ? spdf_win_window_native_handle(a->window) : NULL;
    float s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    int chosen;

    if (!hwnd) return 0;
    chrome_release_capture(a); /* a popup needs the mouse -- see chrome_release_capture */

    /* The same layout the painter used, so the popup hangs off the drawn cell.
     * The overflow button is placed by the BACKWARD walk, so the Markdown pill
     * cannot move it -- but the flag is passed rather than guessed, because
     * "this caller happens not to care" is not a fact a reader can check from
     * here and would stop being true the day a control moves. */
    spdf_win_toolbar_layout(l->toolbar, s, spdf_win_md_selected_tab_is_markdown(a), &tb);
    cell = tb.item[SPDF_WIN_TB_OVERFLOW];
    if (spdf_win_chrome_rect_empty(cell)) return 0;
    pt.x = (LONG)(cell.x + cell.w);
    pt.y = (LONG)(cell.y + cell.h);
    ClientToScreen((HWND)hwnd, &pt);

    /* The same state the bar was given, so the ticks and the greying match.
     * Built here rather than shared with chrome_sync_menu() for the include-order
     * reason above; the fields are all on `app`. */
    memset(&st, 0, sizeof(st));
    st.sidebar_visible = a->show_sidebar;
    st.minimap_visible = a->show_minimap;
    st.dark_theme = (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    st.keep_image_colors = (a->render_flags & SPDF_RENDER_PRESERVE_IMAGES) != 0;
    st.regex = a->find_regex;
    st.regex_multiline = spdf_win_find_regex_multiline();
    st.has_document = a->canvas != NULL;
    st.tab_count = spdf_win_tabs_count(a->tabs);
    st.can_close_tab = spdf_win_tabs_close_enabled(spdf_win_tabs_count(a->tabs), spdf_win_tabs_selected_index(a->tabs),
                                                   a->canvas != NULL);
    /* Only Print is permission-gated. The three Copy Page items never are:
     * spdf_has_permission(doc,'c') returns 1 by product decision and this
     * frontend must not add a copy gate. */
    if (a->tabs && a->canvas) {
        char err[256] = {0};
        int sel = spdf_win_tabs_selected_index(a->tabs);
        spdf_document* doc =
            sel < 0 ? NULL : (spdf_document*)spdf_win_tabs_document(a->tabs, sel, err, sizeof(err));
        st.can_print = doc ? spdf_win_print_allowed(doc) : 0;
    }

    chosen = spdf_win_menu_app_popup(hwnd, &st, pt.x, pt.y);
    if (chosen == SPDF_WIN_CMD_NONE) return 0;
    PostMessageW((HWND)hwnd, WM_COMMAND, (WPARAM)(SPDF_WIN_MENU_ID_BASE + chosen), 0);
    return 0; /* the repaint comes with the command */
}

static int chrome_tab_overflow(app* a, const SpdfWinChromeLayout* l) {
    const wchar_t* titles[SPDF_WIN_CHROME_MAX_TABS];
    SpdfWinTabRect r;
    POINT pt;
    void* hwnd = a->window ? spdf_win_window_native_handle(a->window) : NULL;
    float s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    int i, count = a->chrome_tabs.count, chosen;

    if (!hwnd || count <= 0) return 0;
    chrome_release_capture(a); /* see chrome_release_capture: a popup needs the mouse */
    for (i = 0; i < count; ++i) titles[i] = a->chrome_tabs.titles[i];
    /* Under the button's bottom-left corner, in the strip's own point space
     * converted back the way the painter converts it -- so the menu hangs off
     * the control that opened it at every DPI. */
    r = spdf_win_tabstrip_overflow_rect(l->tabstrip.w / s, count);
    pt.x = (LONG)(l->tabstrip.x + (float)r.x * s);
    pt.y = (LONG)(l->tabstrip.y + (float)(r.y + r.h) * s);
    ClientToScreen((HWND)hwnd, &pt);

    chosen = spdf_win_menu_tab_overflow(hwnd, titles, count, spdf_win_tabs_selected_index(a->tabs), pt.x, pt.y);
    if (chosen < 0) return 0;
    return chrome_select_tab(a, chosen);
}

/* --- TAB DRAG-TO-REORDER ------------------------------------------------
 *
 * BOTH HALVES ARE TRANSCRIBED, NOT DERIVED. spdf_win_tabstrip_drop_slot() is
 * macOS's spdf_tab_strip_drop_slot_for_x and spdf_win_tabstrip_move_index() is
 * its spdf_tab_strip_same_window_move_index -- including the part that is easy
 * to get wrong and hard to notice: BOTH gaps adjacent to the dragged tab
 * collapse to a no-op, because the slot indices past the source shift left by
 * one once the tab is lifted out. portable/docs/windows-port-plan.md 2.3's reuse
 * rule is the reason nothing here recomputes either: "re-deriving it would mean
 * re-deriving its bug fixes too".
 *
 * A slot is an insertion position among the VISIBLE tabs, so it is offset by the
 * visible window's start before it means anything to the tab model. */
static int chrome_drop_slot_at(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m, float client_x) {
    float s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    if (spdf_win_chrome_rect_empty(l->tabstrip)) return -1;
    return spdf_win_tabstrip_drop_slot(l->tabstrip.w / s, m->tab_count, m->selected_tab, (client_x - l->tabstrip.x) / s);
}

static int chrome_drop_tab(app* a, const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m) {
    int start = 0, visible = 0, to;
    float s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    if (!a->tabs || a->drag_tab < 0 || a->drop_slot < 0) return 0;
    spdf_win_tabstrip_visible_range(l->tabstrip.w / s, m->tab_count, m->selected_tab, &start, &visible);
    to = spdf_win_tabstrip_move_index(start + a->drop_slot, a->drag_tab, m->tab_count);
    if (to == a->drag_tab) return 0;
    /* The tab model moves the TAB and lets the selection follow it, which is
     * what keeps the document the reader is looking at on screen through a
     * reorder (spdf_win_tabs.h: "The selection follows the TAB, not the
     * index"). */
    return spdf_win_tabs_move(a->tabs, a->drag_tab, to);
}

/* THE REST OF THE GESTURE: a tab dragged off the bar, still held, and slid back
 * into this window's bar or into another window's. It defines
 * chrome_detach_tab(), which is what the drag arm next door calls, and it needs
 * everything above -- the tear-off destination, the window spawner and the
 * strip's own drop geometry -- so it comes last. */
#include "spdf_win_tabs_handoff.h"
