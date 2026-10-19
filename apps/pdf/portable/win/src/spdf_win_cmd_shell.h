#pragma once

/* COMMAND HANDLERS: the shell: updater, default reader, about, shortcuts, and
 * the Settings menu.
 *
 * Header-only, included from spdf_win_chrome_commands.h only, after the app
 * struct, the chrome model and the input types are complete -- the same
 * arrangement as every other *_commands/*_actions header in this port. Owned
 * by the parity track of that name (portable/docs/windows-feature-matrix.md);
 * the other tracks have their own and none of them edits command_perform().
 *
 * Return 1 when the command was consumed, 0 to let it fall through.
 *
 * WHAT EACH ONE DOES, and where the decision lives:
 *   ABOUT              spdf_win_about.h        version/build/core from the one
 *                                              header the .rc also reads
 *   SHORTCUTS (F1)     spdf_win_shortcuts.h    generated from spdf_win_menu_table()
 *   SET_DEFAULT_READER spdf_win_assoc.h        HKCU registration + the Settings
 *                                              page; the ONLY registry writer
 *                                              here, and only on this command
 *   CHECK_UPDATES      spdf_win_updater.h      the check now, result shown
 *
 * All four are modal against the main window and none of them touches the
 * document, so they need no chrome layout and no scene invalidation: the
 * window repaints itself when the dialog closes.
 *
 * --- AND THE SETTINGS MENU -------------------------------------------------
 *
 * macOS's Settings menu (ShenzhenPDFMac.mm:2112-2149), which this port had the
 * whole MODEL of -- eleven keys read, clamped, carried through and persisted by
 * spdf_win_settings.h, pinned by settings_test.c -- and one menu row of. The
 * other five rows are here.
 *
 * WHY HERE AND NOT IN spdf_win_cmd_window.h, where Keep Image Colors already
 * is. Three of them are one line of settings.yaml each and could live anywhere;
 * the other two are the shell -- ShellExecuteW and SHOpenFolderAndSelectItems,
 * which is what this file is for. Splitting five rows of one menu across two
 * files to save one #include would make the menu harder to find than the code.
 * Keep Image Colors stays where it is because it ALSO changes a render flag and
 * rebuilds the canvas, which is that file's business, not this one's.
 *
 * A TOGGLE IS A WRITE AND A COMMIT, AND NOTHING ELSE. Neither
 * defaultSidebarVisibleForNewDocuments nor defaultMinimapVisibleForNewDocuments
 * touches the window that is open: they are read once per launch, where
 * spdf_win_main.cpp seeds a->show_sidebar / a->show_minimap from them, and
 * changing one mid-session must NOT reach in and move the reader's panels --
 * that is what F9 is for, and the mac's toggle does not either
 * (toggleDefaultSidebarForNewDocuments: sets the flag and saves, :15701).
 * searchJumpsToNearestResult is read live at every search
 * (spdf_win_chrome_field_ui.h), so writing it IS the whole change. So all three
 * return 1 having redrawn nothing, which is correct and is why they look too
 * short to be doing anything.
 *
 * COMMIT BEFORE OPENING THE FILE. spdf_win_settings_commit() is what makes
 * settings.yaml exist -- a reader who has never changed a setting has no file
 * -- and it is also how the mac does it (openStateFile: calls
 * savePersistentState first, then writes an empty document if the file is still
 * absent). If the commit is refused, the file on disk is one this build could
 * not read, and opening it in an editor is the single most useful thing that
 * can happen next: the reader can see what is wrong with it. So the open is
 * attempted either way, and only a path that cannot be resolved at all stops
 * it. */

#include "spdf_win_about.h"
#include "spdf_win_assoc.h"
#include "spdf_win_paths.h"
#include "spdf_win_settings.h"
#include "spdf_win_shell.h"
#include "spdf_win_shortcuts.h"
#include "spdf_win_state.h"
#include "spdf_win_updater.h"

/* One settings.yaml boolean, flipped and persisted. */
static int cmd_shell_toggle_setting(int* field) {
    if (!field) return 0;
    *field = !*field;
    spdf_win_settings_commit();
    return 1;
}

/* Settings > Open settings.yaml... (Ctrl+,). */
static int cmd_shell_open_settings_file(void) {
    char path[1024];
    spdf_win_settings_commit();
    if (!spdf_win_paths_state_file(SPDF_WIN_STATE_SETTINGS, path, sizeof(path))) return 0;
    return spdf_win_shell_open_with_default_app(path) ? 1 : 0;
}

/* Settings > Reveal Settings Folder. spdf_win_paths_state_dir() creates the
 * directory if it is not there yet, so Explorer is never asked to open a folder
 * that does not exist -- which is the state a reader who has changed nothing is
 * actually in. */
static int cmd_shell_reveal_settings_folder(void) {
    char dir[1024];
    if (!spdf_win_paths_state_dir(dir, sizeof(dir))) return 0;
    return spdf_win_shell_reveal_folder(dir) ? 1 : 0;
}

static int spdf_win_cmd_shell_perform(app* a, int command, const spdf_win_input* in) {
    void* hwnd = a && a->window ? spdf_win_window_native_handle(a->window) : NULL;
    int dark = a && (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    spdf_win_settings* s = spdf_win_settings_shared();
    (void)in;
    switch (command) {
        case SPDF_WIN_CMD_ABOUT: spdf_win_about_show(hwnd, dark); return 1;
        case SPDF_WIN_CMD_SHORTCUTS: spdf_win_shortcuts_show(hwnd, dark); return 1;
        case SPDF_WIN_CMD_SET_DEFAULT_READER: spdf_win_assoc_make_default(hwnd); return 1;
        case SPDF_WIN_CMD_CHECK_UPDATES: spdf_win_updater_check_interactive(hwnd); return 1;
        case SPDF_WIN_CMD_TOGGLE_DEFAULT_SIDEBAR: return cmd_shell_toggle_setting(&s->default_sidebar_visible);
        case SPDF_WIN_CMD_TOGGLE_DEFAULT_MINIMAP: return cmd_shell_toggle_setting(&s->default_minimap_visible);
        case SPDF_WIN_CMD_TOGGLE_SEARCH_NEAREST: return cmd_shell_toggle_setting(&s->search_jumps_to_nearest_result);
        case SPDF_WIN_CMD_OPEN_SETTINGS_FILE: return cmd_shell_open_settings_file();
        case SPDF_WIN_CMD_REVEAL_SETTINGS_FOLDER: return cmd_shell_reveal_settings_folder();
        default: return 0;
    }
}
