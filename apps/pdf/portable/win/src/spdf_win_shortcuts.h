/* spdf_win_shortcuts.h — the Keyboard Shortcuts sheet (F1), GENERATED from the
 * menu table.
 *
 * THE DATA SOURCE IS spdf_win_menu_table(), BY DESIGN. portable/linux/gtk4/
 * spdf_shortcuts.c builds its GtkShortcutsWindow from the same table that
 * registers its actions "so the two can never drift apart", and the Windows
 * menu header adopts the same discipline for the menu and the keymap. A
 * cheat sheet typed by hand would be the third copy, and the one nobody
 * updates: the row that says F9 opens the sidebar would still say so after
 * someone rebinds it. Here it cannot, because there is no row -- there is a
 * function over the table.
 *
 * WHAT IS LISTED. Every row that DRAWS in a menu and carries a printed
 * accelerator, grouped by its menu in menu order, with the & mnemonic and the
 * trailing "..." removed from the title (a sheet says "Open", a menu says
 * "&Open..."). Accelerator-only rows (Ctrl+Tab, the keypad +/-) are alternate
 * keys for commands already listed and are folded in as "or" spellings, so
 * the sheet says "Ctrl+PgDn or Ctrl+Tab" for Next Tab rather than listing it
 * twice or losing the second key. Items with no key (Save Page As, Reload) are
 * not shortcuts and are not listed.
 *
 * PLUS ONE GROUP THE TABLE CANNOT KNOW: the reading keys the canvas handles
 * directly (arrows, Page Up/Down, Home/End, Space, Escape) are not commands and
 * have no table row. They are the fixed appendix below, kept short and kept
 * here so the sheet has one source file, and checked by shortcuts_test.c not
 * to collide with any table accelerator.
 *
 * PURE: no Win32 in this header. The window that draws the rows is
 * spdf_win_shortcuts.cpp; portable/win/tests/shortcuts_test.c pins the rows.
 */
#ifndef SPDF_WIN_SHORTCUTS_H
#define SPDF_WIN_SHORTCUTS_H

#include <stddef.h>
#include <wchar.h>

#include "spdf_win_menu.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_SC_INLINE __inline
#else
#define SPDF_WIN_SC_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_WIN_SHORTCUT_TITLE_MAX 64
#define SPDF_WIN_SHORTCUT_ACCEL_MAX 48
#define SPDF_WIN_SHORTCUT_MAX_ROWS 96

typedef struct SpdfWinShortcutRow {
    const wchar_t* group; /* "File", "Go To", ... or "Reading" for the appendix; no mnemonic */
    wchar_t title[SPDF_WIN_SHORTCUT_TITLE_MAX];
    wchar_t accel[SPDF_WIN_SHORTCUT_ACCEL_MAX]; /* "Ctrl+PgDn or Ctrl+Tab" */
    int command;                                /* SPDF_WIN_CMD_NONE for an appendix row */
} SpdfWinShortcutRow;

/* The reading keys: what the canvas does with a keystroke no accelerator
 * claimed. Not commands, so not in the table; listed so the sheet is complete. */
typedef struct SpdfWinShortcutFixed {
    const wchar_t* title;
    const wchar_t* accel;
    unsigned key;  /* the VK the row describes, for the collision check; 0 for "several" */
    unsigned mods;
} SpdfWinShortcutFixed;

/* Transcribed from the document branch of key_for_window()
 * (spdf_win_chrome_commands.h): a line is 60 px, a screen is 90% of the
 * canvas, and the bare +/- keys zoom exactly as the toolbar pill does. */
static const SpdfWinShortcutFixed k_spdf_win_shortcuts_reading[] = {
    {L"Scroll a line", L"Up / Down / Left / Right", SPDF_WIN_KEY_DOWN, 0},
    {L"Scroll a screen", L"PgDn / Space, PgUp", SPDF_WIN_KEY_NEXT, 0},
    {L"Start / end of document", L"Home / End", SPDF_WIN_KEY_HOME, 0},
    {L"Zoom in / out", L"+ / -", SPDF_WIN_KEY_OEM_PLUS, 0},
    {L"Dismiss the find field or the selection; close the window", L"Esc", SPDF_WIN_KEY_ESCAPE, 0},
};

/* "&Open..." -> "Open"; "&&" -> "&". Returns the number of characters written. */
static SPDF_WIN_SC_INLINE int spdf_win_shortcuts_clean_title(const wchar_t* in, wchar_t* out, size_t out_len) {
    size_t n = 0;
    if (!out || !out_len) return 0;
    out[0] = L'\0';
    if (!in) return 0;
    for (; *in && n + 1 < out_len; ++in) {
        if (*in == L'&') {
            if (in[1] == L'&') out[n++] = *++in; /* a literal ampersand */
            continue;                            /* the mnemonic marker */
        }
        out[n++] = *in;
    }
    out[n] = L'\0';
    while (n && out[n - 1] == L'.') out[--n] = L'\0'; /* the trailing "..." */
    while (n && out[n - 1] == L' ') out[--n] = L'\0';
    return (int)n;
}

/* The Windows spelling of an accelerator-only row's key, for the "or" suffix.
 * Only the keys the table actually uses that way; anything else is skipped. */
static SPDF_WIN_SC_INLINE const wchar_t* spdf_win_shortcuts_key_name(unsigned key) {
    switch (key) {
        case SPDF_WIN_KEY_TAB: return L"Tab";
        case SPDF_WIN_KEY_ADD: return L"Num +";
        case SPDF_WIN_KEY_SUBTRACT: return L"Num -";
        case SPDF_WIN_KEY_OEM_PLUS: return L"=";
        case SPDF_WIN_KEY_OEM_MINUS: return L"-";
        default: return NULL;
    }
}

static SPDF_WIN_SC_INLINE void spdf_win_shortcuts_append_alt(wchar_t* accel, size_t cap, unsigned key,
                                                             unsigned mods) {
    const wchar_t* name = spdf_win_shortcuts_key_name(key);
    wchar_t spelled[SPDF_WIN_SHORTCUT_ACCEL_MAX];
    if (!name) return;
    /* Ctrl+Shift+= IS Ctrl++ on a US layout -- the table carries it so the
     * printed accelerator fires (spdf_win_menu_table.h) -- so it is the same
     * chord, not a second spelling, and listing it would read as a bug. */
    if (key == SPDF_WIN_KEY_OEM_PLUS && (mods & SPDF_WIN_ACCEL_SHIFT)) return;
    spelled[0] = L'\0';
    if (mods & SPDF_WIN_ACCEL_CTRL) wcscat_s(spelled, SPDF_WIN_SHORTCUT_ACCEL_MAX, L"Ctrl+");
    if (mods & SPDF_WIN_ACCEL_SHIFT) wcscat_s(spelled, SPDF_WIN_SHORTCUT_ACCEL_MAX, L"Shift+");
    if (mods & SPDF_WIN_ACCEL_ALT) wcscat_s(spelled, SPDF_WIN_SHORTCUT_ACCEL_MAX, L"Alt+");
    wcscat_s(spelled, SPDF_WIN_SHORTCUT_ACCEL_MAX, name);
    if (wcsstr(accel, spelled)) return; /* the same spelling already printed (Ctrl+Shift+= IS Ctrl++) */
    if (wcslen(accel) + wcslen(spelled) + 5 > cap) return;
    wcscat_s(accel, cap, L" or ");
    wcscat_s(accel, cap, spelled);
}

/* THE SHEET. Fills `out` with at most `cap` rows and returns the count: the
 * menu rows first, in menu order, then the Reading appendix. */
static SPDF_WIN_SC_INLINE int spdf_win_shortcuts_build(SpdfWinShortcutRow* out, int cap) {
    int n = 0, i, j, table_n = 0;
    const SpdfWinMenuItem* table = spdf_win_menu_table(&table_n);
    int menu;

    if (!out || cap <= 0) return 0;
    for (menu = SPDF_WIN_MENU_NONE + 1; menu < SPDF_WIN_MENU_COUNT; ++menu) {
        wchar_t group[32];
        const wchar_t* group_title = NULL;
        spdf_win_shortcuts_clean_title(spdf_win_menu_title(menu), group, 32);
        for (i = 0; i < table_n && n < cap; ++i) {
            const SpdfWinMenuItem* row = &table[i];
            SpdfWinShortcutRow* r;
            if (row->menu != menu || row->command == SPDF_WIN_CMD_NONE || !row->accel || !row->title) continue;
            r = &out[n++];
            /* The group string must outlive this call: point at the menu title
             * constant's cleaned twin, which is stable per menu id. */
            group_title = spdf_win_menu_title(menu);
            r->group = group_title;
            r->command = row->command;
            spdf_win_shortcuts_clean_title(row->title, r->title, SPDF_WIN_SHORTCUT_TITLE_MAX);
            wcsncpy_s(r->accel, SPDF_WIN_SHORTCUT_ACCEL_MAX, row->accel, _TRUNCATE);
            /* Fold in the accelerator-only spellings of the same command. */
            for (j = 0; j < table_n; ++j)
                if (table[j].menu == SPDF_WIN_MENU_NONE && table[j].command == row->command && table[j].key)
                    spdf_win_shortcuts_append_alt(r->accel, SPDF_WIN_SHORTCUT_ACCEL_MAX, table[j].key, table[j].mods);
        }
    }
    for (i = 0; i < (int)(sizeof(k_spdf_win_shortcuts_reading) / sizeof(k_spdf_win_shortcuts_reading[0])) && n < cap;
         ++i) {
        SpdfWinShortcutRow* r = &out[n++];
        r->group = L"Reading";
        r->command = SPDF_WIN_CMD_NONE;
        wcsncpy_s(r->title, SPDF_WIN_SHORTCUT_TITLE_MAX, k_spdf_win_shortcuts_reading[i].title, _TRUNCATE);
        wcsncpy_s(r->accel, SPDF_WIN_SHORTCUT_ACCEL_MAX, k_spdf_win_shortcuts_reading[i].accel, _TRUNCATE);
    }
    return n;
}

/* The group's display name for a row: the menu title without its mnemonic, or
 * the appendix name as-is. */
static SPDF_WIN_SC_INLINE void spdf_win_shortcuts_group_name(const SpdfWinShortcutRow* row, wchar_t* out,
                                                             size_t out_len) {
    spdf_win_shortcuts_clean_title(row->group, out, out_len);
}

/* --- the window (spdf_win_shortcuts.cpp) ----------------------------------- */

/* Show the sheet, modal against `hwnd` (an HWND), in the dark or light chrome
 * theme. Returns 1 when shown and dismissed, 0 when no window could be
 * created. */
int spdf_win_shortcuts_show(void* hwnd, int dark);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SHORTCUTS_H */
