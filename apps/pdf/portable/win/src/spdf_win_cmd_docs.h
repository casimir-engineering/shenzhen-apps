#pragma once

/* COMMAND HANDLERS: documents: recents, favorites, the palette, the shell
 * commands on the document's path, reload, and the Open dialog's folder.
 *
 * Header-only, included from spdf_win_chrome_commands.h only, after the app
 * struct, the chrome model and the input types are complete -- the same
 * arrangement as every other *_commands/*_actions header in this port. Owned
 * by the documents track (portable/docs/windows-feature-matrix.md items 9, 12,
 * 16); the other tracks have their own and none of them edits command_perform().
 *
 * WHAT IS REACHABLE FROM HERE, and used: `app`, chrome_open_wide() and
 * chrome_select_tab() (spdf_win_chrome_tabs_ui.h), show_selected_tab() and
 * report() (spdf_win_main.cpp), spdf_win_tabs_app_remember(), doc_action_for()
 * and SpdfWinDocAction (spdf_win_chrome_commands.h, defined above the include).
 * A command the palette chose is POSTED as a WM_COMMAND rather than performed,
 * for the reason chrome_app_menu() gives: command_perform() is defined below
 * this include, and the posted route is the one every other entry takes.
 *
 * Return 1 when the command was consumed, 0 to let it fall through. */

#include "spdf_win_favorites.h"
#include "spdf_win_palette.h"
#include "spdf_win_paths.h" /* the UTF-8 <-> UTF-16 converters the tab model's paths cross */
#include "spdf_win_recents.h"
#include "spdf_win_shell.h"

static HWND docs_hwnd(app* a) { return a->window ? (HWND)spdf_win_window_native_handle(a->window) : NULL; }

static const char* docs_selected_path(app* a) {
    int sel = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
    return sel < 0 ? NULL : spdf_win_tabs_path(a->tabs, sel);
}

/* Open a UTF-8 path in a tab (or select its tab) -- chrome_open_wide notes it as
 * recent -- and land on `page` when one is asked for. The page goes where the tab model puts
 * a restored page: into pending_page for the first paint when the canvas was
 * just built, straight to the canvas when the tab was already showing. */
static int docs_open_utf8(app* a, const char* utf8, int page) {
    wchar_t* wide;
    int changed, index;
    if (!a->tabs || !utf8 || !*utf8) return 0;
    wide = spdf_win_utf16_dup_from_utf8(utf8);
    if (!wide) return 0;
    changed = chrome_open_wide(a, wide);
    free(wide);
    index = spdf_win_tabs_index_of_path(a->tabs, utf8);
    if (index < 0) return changed; /* at the tab cap, or out of memory */
    if (page >= 0) {
        if (a->pending_page >= 0) a->pending_page = page;
        else if (a->canvas) changed |= spdf_win_canvas_scroll_to_page(a->canvas, page);
    }
    return changed;
}

/* File > Open... / Open in New Tab: the picker, started where the policy says. */
static int docs_open_dialog(app* a) {
    char dir[SPDF_WIN_RECENTS_PATH_MAX];
    wchar_t start[SPDF_WIN_RECENTS_PATH_MAX];
    wchar_t path[1024];
    char* utf8;
    int changed;
    if (!a->window) return 0;
    chrome_release_capture(a);
    start[0] = 0;
    if (spdf_win_shell_open_start_dir(docs_selected_path(a), spdf_win_recents_path(0), dir, sizeof(dir)))
        spdf_win_utf16_from_utf8(dir, (spdf_wchar*)start, sizeof(start) / sizeof(start[0]));
    else
        spdf_win_shell_home_dir(start, (int)(sizeof(start) / sizeof(start[0])));
    if (!spdf_win_menu_open_dialog_in(docs_hwnd(a), start, path, (int)(sizeof(path) / sizeof(path[0])))) return 0;
    utf8 = spdf_win_utf8_dup_from_utf16((const spdf_wchar*)path);
    changed = docs_open_utf8(a, utf8, -1);
    free(utf8);
    return changed;
}

static int docs_open_path(app* a) {
    wchar_t path[1024];
    char* utf8;
    int changed, rc;
    chrome_release_capture(a);
    rc = spdf_win_shell_open_path_dialog(docs_hwnd(a), path, (int)(sizeof(path) / sizeof(path[0])));
    if (rc != 1) return 0;
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) {
        wchar_t message[1200];
        _snwprintf_s(message, _TRUNCATE, L"There is no file at\n%s", path);
        report(message, a->window != NULL);
        return 0;
    }
    utf8 = spdf_win_utf8_dup_from_utf16((const spdf_wchar*)path);
    changed = docs_open_utf8(a, utf8, -1);
    free(utf8);
    return changed;
}

/* Open Recent > the i-th entry. A file that has gone is reported once and
 * dropped from the list, which is what the mac's openRecentDocument: does. */
static int docs_open_recent(app* a, int index) {
    char path[SPDF_WIN_RECENTS_PATH_MAX];
    const char* recent = spdf_win_recents_path(index);
    wchar_t* wide;
    if (!recent) return 0;
    strcpy_s(path, sizeof(path), recent); /* the list may move under us */
    wide = spdf_win_utf16_dup_from_utf8(path);
    if (wide && GetFileAttributesW(wide) == INVALID_FILE_ATTRIBUTES) {
        wchar_t message[1200];
        _snwprintf_s(message, _TRUNCATE, L"%s\n\nno longer exists; it was removed from Open Recent.", wide);
        free(wide);
        spdf_win_recents_remove(path);
        report(message, a->window != NULL);
        return 0;
    }
    free(wide);
    return docs_open_utf8(a, path, -1);
}

static int docs_reopen_closed(app* a) {
    char path[SPDF_WIN_RECENTS_PATH_MAX];
    if (!spdf_win_recents_pop_closed(path, sizeof(path))) return 0;
    return docs_open_utf8(a, path, -1);
}

/* Ctrl+D: the current page, as on macOS (Cmd+D) and GTK (win.favorite-page). */
static int docs_toggle_favorite(app* a) {
    const char* path = docs_selected_path(a);
    int sel = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
    if (!path || !a->canvas || sel < 0) return 0;
    spdf_win_favorites_toggle_page(path, spdf_win_tabs_title(a->tabs, sel), spdf_win_canvas_current_page(a->canvas));
    return 0; /* nothing on screen changes; the palette shows the result */
}

/* File > Reload: drop the tab's document and let show_selected_tab() open it
 * again through the model's hook, on the page the reader was on. The canvas is
 * rebuilt because a canvas holds one document (spdf_win_tabs_app.h). */
static int docs_reload(app* a) {
    int sel = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
    if (sel < 0 || !a->canvas) return 0;
    spdf_win_tabs_app_remember(a->tabs, a->canvas);
    spdf_win_canvas_destroy(a->canvas);
    a->canvas = NULL;
    spdf_win_tabs_release_document(a->tabs, sel);
    return show_selected_tab(a) || 1; /* the old canvas is gone either way */
}

/* The same state the app menu is synced from, so the palette hides exactly the
 * commands the menu greys (the mac hides invalid menu commands, 30be87712). */
static void docs_menu_state(app* a, SpdfWinMenuState* st) {
    memset(st, 0, sizeof(*st));
    st->sidebar_visible = a->show_sidebar;
    st->minimap_visible = a->show_minimap;
    st->dark_theme = (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    st->keep_image_colors = (a->render_flags & SPDF_RENDER_PRESERVE_IMAGES) != 0;
    st->regex = a->find_regex;
    /* The Settings menu's three settings.yaml ticks. spdf_win_menu_sync()
     * fills these itself, but the palette draws its check marks straight from
     * spdf_win_menu_command_checked(), so it has to ask. */
    spdf_win_menu_state_settings(st);
    st->regex_multiline = spdf_win_find_regex_multiline();
    st->has_document = a->canvas != NULL;
    st->tab_count = spdf_win_tabs_count(a->tabs);
    st->can_close_tab = spdf_win_tabs_close_enabled(spdf_win_tabs_count(a->tabs), spdf_win_tabs_selected_index(a->tabs),
                                                    a->canvas != NULL);
    if (a->tabs && a->canvas) {
        SpdfWinDocAction act;
        st->can_print = doc_action_for(a, &act) ? spdf_win_print_allowed(act.doc) : 0;
    }
}

static int docs_palette(app* a) {
    SpdfWinPaletteOpenDoc docs[SPDF_WIN_TABS_MAX];
    SpdfWinPaletteModel* model;
    SpdfWinPaletteChoice choice;
    SpdfWinMenuState st;
    HWND hwnd = docs_hwnd(a);
    int i, count = a->tabs ? spdf_win_tabs_count(a->tabs) : 0, rc, changed = 0;
    if (!hwnd) return 0;
    chrome_release_capture(a);
    model = spdf_win_palette_model_create();
    if (!model) return 0;
    if (count > SPDF_WIN_TABS_MAX) count = SPDF_WIN_TABS_MAX;
    for (i = 0; i < count; ++i) {
        docs[i].path = spdf_win_tabs_path(a->tabs, i);
        docs[i].title = spdf_win_tabs_title(a->tabs, i);
    }
    spdf_win_palette_model_set_documents(model, docs, count, a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1);
    docs_menu_state(a, &st);
    spdf_win_palette_model_set_menu_state(model, &st);
    rc = spdf_win_palette_run(hwnd, (a->render_flags & SPDF_RENDER_DARK_THEME) != 0,
                              a->window ? spdf_win_window_dpi_scale(a->window) : 1.0f, model, &choice);
    spdf_win_palette_model_destroy(model);
    if (rc != 1) return 0;
    switch (choice.kind) {
        case SPDF_WIN_PALETTE_ROW_COMMAND:
            PostMessageW(hwnd, WM_COMMAND, (WPARAM)(SPDF_WIN_MENU_ID_BASE + choice.command), 0);
            break;
        case SPDF_WIN_PALETTE_ROW_OPEN_DOC: changed = chrome_select_tab(a, choice.doc); break;
        case SPDF_WIN_PALETTE_ROW_FAVORITE:
        case SPDF_WIN_PALETTE_ROW_RECENT: changed = docs_open_utf8(a, choice.path, choice.page); break;
        default: break;
    }
    return changed;
}

/* EVERY CLAIMED COMMAND RETURNS 1, whether or not the view changed: a 0 would
 * fall through to command_perform()'s own switch, and for Open that switch
 * still runs chrome_open_dialog() -- a cancelled picker would be followed by a
 * second picker. The cost of the rule is one repaint after a no-op, which is
 * nothing. CLOSE_TAB is not claimed: chrome_close_tab() notes the close for
 * Reopen Last Closed Tab, whichever route -- Ctrl+W or the close box -- ran it. */
static int spdf_win_cmd_docs_perform(app* a, int command, const spdf_win_input* in) {
    (void)in;
    if (command >= SPDF_WIN_CMD_OPEN_RECENT_FIRST && command <= SPDF_WIN_CMD_OPEN_RECENT_LAST) {
        docs_open_recent(a, command - SPDF_WIN_CMD_OPEN_RECENT_FIRST);
        return 1;
    }
    switch (command) {
        case SPDF_WIN_CMD_OPEN:
        case SPDF_WIN_CMD_NEW_TAB: docs_open_dialog(a); return 1;
        case SPDF_WIN_CMD_OPEN_PATH: docs_open_path(a); return 1;
        case SPDF_WIN_CMD_REOPEN_CLOSED_TAB: docs_reopen_closed(a); return 1;
        case SPDF_WIN_CMD_ADD_FAVORITE: docs_toggle_favorite(a); return 1;
        case SPDF_WIN_CMD_PALETTE: docs_palette(a); return 1;
        case SPDF_WIN_CMD_RELOAD: docs_reload(a); return 1;
        case SPDF_WIN_CMD_SHOW_IN_FOLDER: spdf_win_shell_show_in_folder(docs_selected_path(a)); return 1;
        case SPDF_WIN_CMD_COPY_PATH: spdf_win_shell_copy_text(docs_hwnd(a), docs_selected_path(a)); return 1;
        case SPDF_WIN_CMD_OPEN_IN_BROWSER: spdf_win_shell_open_in_browser(docs_selected_path(a)); return 1;
        default: return 0;
    }
}
