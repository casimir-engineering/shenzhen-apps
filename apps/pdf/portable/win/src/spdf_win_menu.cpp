/* The Win32 half of spdf_win_menu.h: the menu bar built from the table, the tab
 * overflow popup, and the Open dialog.
 *
 * Every Win32 call here is an explicit *W call, for the reason
 * spdf_win_window.cpp's header gives: the build does not define UNICODE, so an
 * undecorated name resolves to the ANSI variant and mangles every non-ASCII
 * string -- and a tab title is exactly where a CJK or accented filename shows up.
 *
 * NOTHING HERE DECIDES ANYTHING. Which command a menu item runs, what it is
 * called and which key fires it are all in the table next door; this file turns
 * that table into HMENUs and turns a click back into a command id. That split is
 * spdf_win_chrome_input.h's, one device over: the pure layer names the meaning
 * and the Win32 layer moves the bits.
 */
#include "spdf_win_menu.h"

#include "spdf_win_paths.h"    /* UTF-8 -> UTF-16 for the recent paths */
#include "spdf_win_recents.h"  /* the Open Recent submenu's rows */
#include "spdf_win_settings.h" /* the Settings menu's three settings.yaml ticks */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <shobjidl.h>
#include <stdio.h>
#include <stdlib.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib") /* SHCreateItemFromParsingName */
#pragma comment(lib, "user32.lib")

namespace {

/* "&Open...\tCtrl+O". Win32 draws everything after the tab right-aligned in the
 * accelerator column, which is the only reason the accelerator is a separate
 * field in the table rather than being written into the title. */
void item_text(const SpdfWinMenuItem* it, wchar_t* out, size_t n) {
    if (it->accel) _snwprintf_s(out, n, _TRUNCATE, L"%s\t%s", it->title, it->accel);
    else _snwprintf_s(out, n, _TRUNCATE, L"%s", it->title);
}

/* COM, initialised for the duration of one dialog.
 *
 * S_FALSE means this thread was already an apartment and the reference count
 * went up, so it still has to come down -- only RPC_E_CHANGED_MODE leaves
 * nothing to release. Getting that pairing wrong is how a viewer that has opened
 * a file once fails to open one the second time. */
struct ComScope {
    bool owned;
    ComScope() {
        HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        owned = hr == S_OK || hr == S_FALSE;
    }
    ~ComScope() {
        if (owned) CoUninitialize();
    }
};

/* THE OPEN RECENT SUBMENU, built from the recents store at the moment the menu
 * is created -- which, since the app has no menu bar and shows the table as a
 * popup, is every time the `...` is clicked. So the list is always current and
 * nothing has to invalidate it. The mac's rebuildRecentlyOpenedMenu: the display
 * name (the path's last component) as the title, the whole path nowhere visible,
 * and a greyed "No Recent Documents" when the list is empty. */
HMENU recent_submenu() {
    HMENU sub = CreatePopupMenu();
    int count = spdf_win_recents_count();
    if (!sub) return NULL;
    if (count > SPDF_WIN_CMD_OPEN_RECENT_LAST - SPDF_WIN_CMD_OPEN_RECENT_FIRST + 1)
        count = SPDF_WIN_CMD_OPEN_RECENT_LAST - SPDF_WIN_CMD_OPEN_RECENT_FIRST + 1;
    if (count == 0) {
        AppendMenuW(sub, MF_STRING | MF_GRAYED, 0, L"No Recent Documents");
        return sub;
    }
    for (int i = 0; i < count; ++i) {
        const char* path = spdf_win_recents_path(i);
        wchar_t* wide = path ? spdf_win_utf16_dup_from_utf8(spdf_win_path_basename(path)) : NULL;
        wchar_t text[300];
        /* A '&' in a file name would become a mnemonic; doubling it prints it. */
        size_t n = 0;
        for (const wchar_t* p = wide ? wide : L"Untitled"; *p && n + 2 < sizeof(text) / sizeof(text[0]); ++p) {
            if (*p == L'&') text[n++] = L'&';
            text[n++] = *p;
        }
        text[n] = 0;
        free(wide);
        AppendMenuW(sub, MF_STRING, (UINT_PTR)(SPDF_WIN_MENU_ID_BASE + SPDF_WIN_CMD_OPEN_RECENT_FIRST + i), text);
    }
    return sub;
}

} /* namespace */

void* spdf_win_menu_create(void) {
    HMENU bar = CreateMenu();
    int menu, i, n = 0;
    const SpdfWinMenuItem* table = spdf_win_menu_table(&n);

    if (!bar) return NULL;
    /* One pass per top-level menu rather than one pass over the table, so the
     * ORDER of the menu bar is spdf_win_menu_id's order and not an accident of
     * how the rows happen to be sorted. The rows are in menu order too; this
     * simply stops that from being load-bearing. */
    for (menu = SPDF_WIN_MENU_NONE + 1; menu < SPDF_WIN_MENU_COUNT; ++menu) {
        HMENU sub = CreatePopupMenu();
        const wchar_t* title = spdf_win_menu_title(menu);
        int added = 0;
        if (!sub) continue;
        for (i = 0; i < n; ++i) {
            wchar_t text[128];
            if (table[i].menu != menu) continue;
            if (table[i].command == SPDF_WIN_CMD_NONE) {
                /* A separator before anything has been added would draw a line
                 * against the top of the menu. */
                if (added) AppendMenuW(sub, MF_SEPARATOR, 0, NULL);
                continue;
            }
            item_text(&table[i], text, sizeof(text) / sizeof(text[0]));
            if (table[i].command == SPDF_WIN_CMD_OPEN_RECENT) {
                /* The anchor row becomes a submenu; its rows carry their own ids. */
                HMENU recents = recent_submenu();
                if (recents) AppendMenuW(sub, MF_STRING | MF_POPUP, (UINT_PTR)recents, text);
            } else {
                AppendMenuW(sub, MF_STRING, (UINT_PTR)(SPDF_WIN_MENU_ID_BASE + table[i].command), text);
            }
            ++added;
        }
        if (added && title) AppendMenuW(bar, MF_POPUP, (UINT_PTR)sub, title);
        else DestroyMenu(sub);
    }
    return bar;
}

void spdf_win_menu_destroy(void* hmenu) {
    if (hmenu) DestroyMenu((HMENU)hmenu);
}

void spdf_win_menu_state_settings(SpdfWinMenuState* st) {
    const spdf_win_settings* s;
    if (!st) return;
    s = spdf_win_settings_shared();
    st->default_sidebar_new_docs = s->default_sidebar_visible;
    st->default_minimap_new_docs = s->default_minimap_visible;
    st->search_nearest = s->search_jumps_to_nearest_result;
}

void spdf_win_menu_sync(void* hmenu, const SpdfWinMenuState* state) {
    HMENU bar = (HMENU)hmenu;
    SpdfWinMenuState filled;
    int i, n = 0;
    const SpdfWinMenuItem* table = spdf_win_menu_table(&n);

    if (!bar) return;
    /* A COPY, because the argument is const and the caller's state is not this
     * function's to edit. A NULL state is left NULL: it means "know nothing",
     * which must stay "everything enabled, nothing ticked" -- filling three
     * ticks into it would make a menu built before the app has any state the
     * one place those three are shown and nothing else is. */
    if (state) {
        filled = *state;
        spdf_win_menu_state_settings(&filled);
        state = &filled;
    }
    for (i = 0; i < n; ++i) {
        UINT id;
        if (table[i].command == SPDF_WIN_CMD_NONE || table[i].menu == SPDF_WIN_MENU_NONE) continue;
        id = (UINT)(SPDF_WIN_MENU_ID_BASE + table[i].command);
        /* MF_BYCOMMAND walks the whole tree from the bar, so neither call needs
         * to know which submenu the item ended up in. */
        EnableMenuItem(bar, id,
                       MF_BYCOMMAND | (spdf_win_menu_command_enabled(table[i].command, state) ? MF_ENABLED
                                                                                             : MF_GRAYED));
        if (table[i].checkable)
            CheckMenuItem(bar, id,
                          MF_BYCOMMAND |
                              (spdf_win_menu_command_checked(table[i].command, state) ? MF_CHECKED : MF_UNCHECKED));
    }
}

int spdf_win_menu_tab_overflow(void* hwnd, const wchar_t* const* titles, int count, int selected, int screen_x,
                               int screen_y) {
    HMENU popup;
    int i, chosen;
    int max = SPDF_WIN_MENU_TAB_ID_MAX - SPDF_WIN_MENU_TAB_ID_BASE + 1;

    if (!hwnd || !titles || count <= 0) return -1;
    if (count > max) count = max;
    popup = CreatePopupMenu();
    if (!popup) return -1;
    for (i = 0; i < count; ++i) {
        const wchar_t* t = titles[i] && titles[i][0] ? titles[i] : L"Untitled";
        AppendMenuW(popup, MF_STRING, (UINT_PTR)(SPDF_WIN_MENU_TAB_ID_BASE + i), t);
    }
    /* A RADIO mark, not a check: exactly one tab is selected, and macOS's own
     * overflow list marks the current document the same way. */
    if (selected >= 0 && selected < count)
        CheckMenuRadioItem(popup, (UINT)SPDF_WIN_MENU_TAB_ID_BASE, (UINT)(SPDF_WIN_MENU_TAB_ID_BASE + count - 1),
                           (UINT)(SPDF_WIN_MENU_TAB_ID_BASE + selected), MF_BYCOMMAND);

    /* TPM_RETURNCMD makes this a CALL rather than an event: the id comes back
     * here instead of arriving as a WM_COMMAND some time later, so the caller
     * that opened the menu is the caller that acts on it and no id has to be
     * kept alive across messages. TPM_NONOTIFY suppresses the WM_COMMAND that
     * would otherwise ALSO be posted, which would select the tab twice.
     *
     * SetForegroundWindow before, and the 0-length post after, are the
     * documented workaround for TrackPopupMenu's oldest defect: without them a
     * menu dismissed by clicking elsewhere can stay on screen. */
    SetForegroundWindow((HWND)hwnd);
    chosen = (int)TrackPopupMenu(popup, TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTALIGN | TPM_TOPALIGN, screen_x,
                                 screen_y, 0, (HWND)hwnd, NULL);
    PostMessageW((HWND)hwnd, WM_NULL, 0, 0);
    DestroyMenu(popup);

    if (chosen < SPDF_WIN_MENU_TAB_ID_BASE || chosen > SPDF_WIN_MENU_TAB_ID_MAX) return -1;
    return chosen - SPDF_WIN_MENU_TAB_ID_BASE;
}

int spdf_win_menu_app_popup(void* hwnd, const SpdfWinMenuState* state, int screen_x, int screen_y) {
    /* The bar, built and then shown as a popup rather than attached to a window.
     * spdf_win_menu_create() already produces the whole thing with its
     * submenus, the ids, the accelerator text and the separators, so this reuses
     * it verbatim: one table, one builder, and the popup cannot drift from what
     * the bar showed. */
    HMENU bar = (HMENU)spdf_win_menu_create();
    HMENU shell;
    int i, count, chosen;

    if (!bar) return SPDF_WIN_CMD_NONE;
    spdf_win_menu_sync(bar, state);

    /* A menu BAR cannot be tracked as a popup -- TrackPopupMenu wants a popup
     * menu -- so the top-level entries are re-hung as submenus of one
     * throwaway popup. The submenu HMENUs are borrowed, not copied, which is why
     * they are detached with RemoveMenu (NOT DeleteMenu, which would destroy
     * them) before the bar is freed. */
    shell = CreatePopupMenu();
    if (!shell) {
        spdf_win_menu_destroy(bar);
        return SPDF_WIN_CMD_NONE;
    }
    count = GetMenuItemCount(bar);
    for (i = 0; i < count; ++i) {
        wchar_t title[64];
        HMENU sub = GetSubMenu(bar, i);
        if (!sub) continue;
        title[0] = 0;
        GetMenuStringW(bar, (UINT)i, title, (int)(sizeof(title) / sizeof(title[0])), MF_BYPOSITION);
        AppendMenuW(shell, MF_STRING | MF_POPUP, (UINT_PTR)sub, title);
    }

    SetForegroundWindow((HWND)hwnd);
    chosen = (int)TrackPopupMenu(shell, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTALIGN | TPM_TOPALIGN, screen_x,
                                 screen_y, 0, (HWND)hwnd, NULL);
    PostMessageW((HWND)hwnd, WM_NULL, 0, 0);

    /* Detach before destroying either menu, or the submenus die twice. */
    for (i = GetMenuItemCount(shell) - 1; i >= 0; --i) RemoveMenu(shell, (UINT)i, MF_BYPOSITION);
    DestroyMenu(shell);
    spdf_win_menu_destroy(bar);

    if (chosen < SPDF_WIN_MENU_ID_BASE) return SPDF_WIN_CMD_NONE;
    return chosen - SPDF_WIN_MENU_ID_BASE;
}

int spdf_win_menu_open_dialog(void* hwnd, wchar_t* out_path, int out_len) {
    return spdf_win_menu_open_dialog_in(hwnd, NULL, out_path, out_len);
}

int spdf_win_menu_open_dialog_in(void* hwnd, const wchar_t* start_dir, wchar_t* out_path, int out_len) {
    ComScope com;
    IFileOpenDialog* dialog = NULL;
    IShellItem* item = NULL;
    PWSTR wide = NULL;
    HRESULT hr;
    int ok = 0;

    /* The formats spdf_open() accepts, in the order spdf_win_chrome_model.cpp's
     * strip_known_extension() lists them, plus an all-files escape hatch --
     * MuPDF sniffs content as well as extension, so a .pdf saved as .bin is
     * still openable and a dialog that hides it would be lying. */
    static const COMDLG_FILTERSPEC types[] = {
        {L"Documents", L"*.pdf;*.xps;*.epub;*.mobi;*.fb2;*.cbz;*.cbr;*.cb7;*.cbt;*.md;*.markdown"},
        {L"PDF", L"*.pdf"},
        {L"All Files", L"*.*"}};

    if (!out_path || out_len < 2) return 0;
    out_path[0] = L'\0';
    if (!com.owned) {
        /* RPC_E_CHANGED_MODE: some other component already made this thread a
         * multithreaded apartment. CoCreateInstance still works there, so the
         * dialog is attempted anyway; only the CoUninitialize is skipped. */
    }

    hr = CoCreateInstance(CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr) || !dialog) return 0;

    dialog->SetFileTypes((UINT)(sizeof(types) / sizeof(types[0])), types);
    dialog->SetFileTypeIndex(1);
    dialog->SetTitle(L"Open");
    {
        /* FOS_FORCEFILESYSTEM: a selection this app cannot open with a path --
         * a search result, a library item, a device -- is refused by the dialog
         * rather than handed back as something spdf_open() would fail on. */
        DWORD flags = 0;
        if (SUCCEEDED(dialog->GetOptions(&flags))) dialog->SetOptions(flags | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
    }
    if (start_dir && start_dir[0]) {
        /* SetFolder, not SetDefaultFolder: the policy is "start HERE", every
         * time, and SetDefaultFolder yields to the shell's per-app memory of
         * the last folder used, which is exactly what the policy replaces. A
         * folder that no longer exists fails to resolve and the dialog opens
         * where it would have anyway. */
        IShellItem* folder = NULL;
        if (SUCCEEDED(SHCreateItemFromParsingName(start_dir, NULL, IID_PPV_ARGS(&folder))) && folder) {
            dialog->SetFolder(folder);
            folder->Release();
        }
    }

    hr = dialog->Show((HWND)hwnd);
    if (SUCCEEDED(hr) && SUCCEEDED(dialog->GetResult(&item)) && item) {
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &wide)) && wide) {
            if (wcslen(wide) < (size_t)out_len) {
                wcscpy_s(out_path, (size_t)out_len, wide);
                ok = 1;
            }
            CoTaskMemFree(wide);
        }
        item->Release();
    }
    dialog->Release();
    return ok;
}
