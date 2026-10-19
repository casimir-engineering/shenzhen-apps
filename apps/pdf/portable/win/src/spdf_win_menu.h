/* spdf_win_menu.h — every command the Windows shell can be asked to run, as
 * data: one table of (command, menu, title, accelerator).
 *
 * WHAT THIS IS. The Win32 answer to portable/linux/gtk4/spdf_shortcuts.c, which
 * is "the single registry of every GAction name in the GTK4 shell, with
 * accelerators (Mac map, Cmd -> Ctrl) and the F1 cheat sheet, which is a
 * GtkShortcutsWindow generated from the same table so the two can never drift
 * apart". Same discipline, same reason: the menu bar, the keyboard and (later) a
 * command palette must offer exactly one set of commands, and the only way that
 * survives edits is for all three to read one table.
 *
 * WHY THE TABLE IS PURE AND HEADER-ONLY, when the thing it builds is an HMENU.
 * spdf_win_chrome.h's second rule -- "hit-testing and painting agree only if
 * they call the same functions" -- has a keyboard analogue: the accelerator
 * PRINTED next to a menu item and the accelerator that actually FIRES agree only
 * if they come from the same row. So the row carries both, and matching a
 * keystroke to a command is a pure function a plain C test can drive with no
 * window, no menu and no message pump (portable/win/tests/menu_test.c). Only the
 * HMENU construction, the popup menus and the file dialog need Win32, and those
 * live in spdf_win_menu.cpp.
 *
 * THE GROUPING AND THE TITLES ARE macOS'S, transcribed from
 * portable/mac/ShenzhenPDFMac.mm:2112-2424 -- File, Go To, Zoom, View, Edit,
 * Settings, in that order and with those item titles -- minus the commands this
 * port does not have yet. Nothing here is invented: an item exists only if the
 * command behind it exists.
 *
 * THE ACCELERATORS ARE Cmd -> Ctrl, which is the mapping the GTK4 frontend
 * already made once (spdf_shortcuts.c:2). Where macOS uses Option (its page
 * navigation: Option+arrows) the Windows spelling is Alt, which is the same
 * physical key in the same role. Three deliberate departures from a literal
 * transcription, each one following GTK4's existing choice rather than inventing
 * a third answer:
 *
 *   - 100% is Ctrl+0, not Ctrl+4 (macOS's Cmd+4). GTK4: win.zoom-actual.
 *   - Previous/Next Tab are Ctrl+PageUp / Ctrl+PageDown, not Ctrl+Left/Right,
 *     which on Windows are word-motion keys. GTK4: win.prev-tab / win.next-tab.
 *     Ctrl+Tab and Ctrl+Shift+Tab keep working as they already did.
 *   - Toggle Side Panel is F9. GTK4: win.sidebar. macOS binds no key.
 *
 * ONE BEHAVIOUR CHANGE THIS TABLE MAKES ON PURPOSE. The Windows keymap had
 * Ctrl+1 = Fit Width and Ctrl+2 = Fit Page, which is neither macOS's order
 * (Cmd+1 Fit Page, Cmd+2 Fit Width, Cmd+3 Fit Height) nor GTK4's (identical to
 * macOS). It is now macOS's, because a menu that PRINTS an accelerator makes the
 * disagreement visible and a reader who uses two of the three frontends would
 * hit it immediately.
 */
#ifndef SPDF_WIN_MENU_H
#define SPDF_WIN_MENU_H

#include <stddef.h> /* NULL, and nothing else -- this header takes no Win32 */
#include <wchar.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_MENU_INLINE __inline
#else
#define SPDF_WIN_MENU_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* --- keys ----------------------------------------------------------------
 *
 * The numeric VK_* values, spelled out rather than taken from <windows.h>, so
 * this header stays free of Win32 exactly as spdf_win_chrome.h and
 * spdf_win_tabstrip.h are. They are ABI: WM_KEYDOWN's wParam is these numbers,
 * and they have not changed since Win16. Letter and digit keys are their ASCII
 * uppercase code, which is also what WM_KEYDOWN reports. */
#define SPDF_WIN_KEY_BACK 0x08   /* VK_BACK */
#define SPDF_WIN_KEY_TAB 0x09    /* VK_TAB */
#define SPDF_WIN_KEY_RETURN 0x0D /* VK_RETURN */
#define SPDF_WIN_KEY_ESCAPE 0x1B /* VK_ESCAPE */
#define SPDF_WIN_KEY_PRIOR 0x21  /* VK_PRIOR, Page Up */
#define SPDF_WIN_KEY_NEXT 0x22   /* VK_NEXT, Page Down */
#define SPDF_WIN_KEY_END 0x23    /* VK_END */
#define SPDF_WIN_KEY_HOME 0x24   /* VK_HOME */
#define SPDF_WIN_KEY_LEFT 0x25   /* VK_LEFT */
#define SPDF_WIN_KEY_UP 0x26     /* VK_UP */
#define SPDF_WIN_KEY_RIGHT 0x27  /* VK_RIGHT */
#define SPDF_WIN_KEY_DOWN 0x28   /* VK_DOWN */
#define SPDF_WIN_KEY_DELETE 0x2E /* VK_DELETE */
#define SPDF_WIN_KEY_ADD 0x6B    /* VK_ADD, numeric keypad */
#define SPDF_WIN_KEY_SUBTRACT 0x6D /* VK_SUBTRACT */
#define SPDF_WIN_KEY_F9 0x78     /* VK_F9 */
#define SPDF_WIN_KEY_F5 0x74     /* VK_F5: presentation, as the readme says */
#define SPDF_WIN_KEY_F11 0x7A    /* VK_F11: full screen */
#define SPDF_WIN_KEY_F1 0x70     /* VK_F1: keyboard shortcuts */
#define SPDF_WIN_KEY_OEM_PLUS 0xBB  /* VK_OEM_PLUS, the '=' key on a US layout */
#define SPDF_WIN_KEY_OEM_COMMA 0xBC /* VK_OEM_COMMA: Ctrl+, the mac's Cmd+, */
#define SPDF_WIN_KEY_OEM_MINUS 0xBD /* VK_OEM_MINUS */

/* The modifier bits, matching spdf_win_window.h's SPDF_WIN_MOD_* exactly so a
 * spdf_win_input's `mods` can be handed to spdf_win_menu_command_for_key()
 * unconverted. Two spellings of the same three bits would be one conversion
 * function away from a Shift that silently means Ctrl. */
#define SPDF_WIN_ACCEL_CTRL 0x1u
#define SPDF_WIN_ACCEL_SHIFT 0x2u
#define SPDF_WIN_ACCEL_ALT 0x4u

/* --- commands ------------------------------------------------------------
 *
 * The value IS the WM_COMMAND id, offset by SPDF_WIN_MENU_ID_BASE. Renumbering
 * is free (nothing persists these), but the ORDER is the menu's visual order,
 * which is the same convention spdf_win_chrome_toolbar.h states for its items. */
typedef enum spdf_win_command {
    SPDF_WIN_CMD_NONE = 0,

    /* File (:2155-2197) */
    SPDF_WIN_CMD_OPEN,      /* "Open..."  */
    SPDF_WIN_CMD_NEW_TAB,   /* GTK4 win.new-tab; the strip's `+` and Ctrl+T */
    SPDF_WIN_CMD_CLOSE_TAB, /* "Close"    */
    SPDF_WIN_CMD_QUIT,      /* "Quit Shenzhen PDF" */
    /* Export, print and properties. Greying: only PRINT is gated, on the
     * document's own print flag -- the three Copy Page items never are, because
     * spdf_has_permission(doc,'c') returns 1 by product decision
     * (shenzhen_pdf_core.h:209-214) and this frontend must not add a copy gate. */
    SPDF_WIN_CMD_SAVE_AS,
    SPDF_WIN_CMD_SAVE_PAGE_AS,
    SPDF_WIN_CMD_PRINT,
    SPDF_WIN_CMD_PROPERTIES,

    /* Go To (:2200-2245) */
    SPDF_WIN_CMD_FIRST_PAGE,
    SPDF_WIN_CMD_PREV_PAGE,
    SPDF_WIN_CMD_NEXT_PAGE,
    SPDF_WIN_CMD_LAST_PAGE,
    SPDF_WIN_CMD_GOTO_PAGE, /* "Go To Page..." -- focuses the page field */
    SPDF_WIN_CMD_PREV_TAB,
    SPDF_WIN_CMD_NEXT_TAB,

    /* Zoom (:2247-2261) */
    SPDF_WIN_CMD_ZOOM_IN,
    SPDF_WIN_CMD_ZOOM_OUT,
    SPDF_WIN_CMD_ZOOM_ACTUAL,
    SPDF_WIN_CMD_FIT_PAGE,
    SPDF_WIN_CMD_FIT_WIDTH,
    SPDF_WIN_CMD_FIT_HEIGHT,

    /* View (:2263-2318) */
    SPDF_WIN_CMD_TOGGLE_SIDEBAR,
    SPDF_WIN_CMD_TOGGLE_MINIMAP,
    SPDF_WIN_CMD_TOGGLE_THEME,

    /* Edit (:2342-2365) */
    SPDF_WIN_CMD_COPY, /* "Copy Selected Document Text"; GTK4 win.copy */
    SPDF_WIN_CMD_FIND,
    SPDF_WIN_CMD_FIND_NEXT,
    SPDF_WIN_CMD_FIND_PREV,
    SPDF_WIN_CMD_FIND_REGEX,
    /* macOS and GTK both publish Copy Page as a standalone ONE-PAGE PDF plus its
     * path, not as text; Copy Page Text is the separate, additional item. */
    SPDF_WIN_CMD_COPY_PAGE,
    SPDF_WIN_CMD_COPY_PAGE_TEXT,
    SPDF_WIN_CMD_COPY_PAGE_IMAGE,

    /* --- pre-declared for the parity tracks (release-note audit, 2026-09-02) --
     * Declared here in one pass so several tracks can land handlers without any
     * of them editing this header -- the same seam discipline that kept the
     * scrollbar and find tracks out of each other's files. An id with no handler
     * is inert: command_perform() falls through to `return 0`. */
    SPDF_WIN_CMD_NEW_WINDOW,          /* File: a second window, its own tabs (multi-window session) */
    SPDF_WIN_CMD_MOVE_TAB_TO_WINDOW,  /* File: detach the current tab into a new window */
    SPDF_WIN_CMD_REOPEN_CLOSED_TAB,   /* File: Ctrl+Shift+T, like a browser (26.7.9) */
    SPDF_WIN_CMD_CLOSE_OTHER_TABS,
    SPDF_WIN_CMD_SHOW_IN_FOLDER,      /* File: reveal in Explorer (the file-manager preference's Windows form) */
    SPDF_WIN_CMD_RELOAD,              /* File: re-read a changed document now (auto-reload does it unasked) */
    SPDF_WIN_CMD_SET_DEFAULT_READER,  /* File: register .pdf with the shell */
    SPDF_WIN_CMD_CHECK_UPDATES,       /* File: the daily GitHub-releases check, run now */
    SPDF_WIN_CMD_PRESENTATION,        /* View: chrome-free full-screen, F5 / Shift+Ctrl+F */
    SPDF_WIN_CMD_FULLSCREEN,          /* View: F11 */
    SPDF_WIN_CMD_TOGGLE_KEEP_IMAGE_COLORS, /* View: Settings > Keep Image Colors in Dark Theme */
    SPDF_WIN_CMD_PALETTE,             /* Go To: Ctrl+K command palette */
    SPDF_WIN_CMD_ADD_FAVORITE,        /* Go To: star the current page */
    SPDF_WIN_CMD_OPEN_RECENT,         /* Go To: the Recents submenu is built at runtime; this is its anchor */
    SPDF_WIN_CMD_OCR,                 /* Edit: make an image-only PDF searchable, on-device */
    SPDF_WIN_CMD_TRANSLATE_SELECTION, /* Edit: translate the selection, on-device */
    SPDF_WIN_CMD_TRANSLATE_DOCUMENT,  /* Edit: write <name>_<lang>.pdf */
    SPDF_WIN_CMD_SELECT_ALL,          /* Edit: Ctrl+A */
    SPDF_WIN_CMD_PASTE_SEARCH,        /* Edit: Ctrl+V while reading searches the clipboard text (26.7.17) */
    SPDF_WIN_CMD_FIND_REGEX_MULTILINE,/* Edit: patterns may span line and paragraph breaks */
    SPDF_WIN_CMD_ROTATE_CW,           /* View: rotate the page clockwise, Ctrl+R as on macOS */
    SPDF_WIN_CMD_ROTATE_CCW,          /* View: anticlockwise, Ctrl+Shift+R */
    SPDF_WIN_CMD_SHORTCUTS,           /* View: the keyboard-shortcuts sheet, F1 */
    SPDF_WIN_CMD_ABOUT,               /* View: About Shenzhen PDF */

    /* The documents track's own three (spdf_win_cmd_docs.h). */
    SPDF_WIN_CMD_OPEN_PATH,           /* File: type a path, Ctrl+Shift+O as on macOS */
    SPDF_WIN_CMD_COPY_PATH,           /* File: the document's path to the clipboard; GTK4 win.copy-path */
    SPDF_WIN_CMD_OPEN_IN_BROWSER,     /* File: the document in the default browser; GTK4 win.open-in-browser */

    /* The Markdown track's two (spdf_win_md_commands.h): the A-/A+ text size,
     * on the View menu with the mac's Cmd+Alt+-/= as Ctrl+Alt+-/=. */
    SPDF_WIN_CMD_MD_TEXT_SMALLER,
    SPDF_WIN_CMD_MD_TEXT_LARGER,

    /* The annotations track's five (spdf_win_cmd_annot.h). The mac menu has
     * only "Set Author for Comments..." (:2096); its add/edit/delete are
     * context-menu items, as are GTK's four (spdf_annot.c:1116-1119). Here
     * they are Edit-menu rows too, so they have accelerators and a place on
     * the F1 sheet. */
    SPDF_WIN_CMD_HIGHLIGHT_SELECTION, /* Edit: a highlight annotation over the selection, with a comment */
    SPDF_WIN_CMD_ADD_COMMENT,         /* Edit: a note at the clicked point; a highlight when text is selected */
    SPDF_WIN_CMD_EDIT_COMMENT,        /* Edit: the comment under the pointer or last clicked */
    SPDF_WIN_CMD_DELETE_COMMENT,      /* Edit: Delete / Backspace over a marker */
    SPDF_WIN_CMD_SET_COMMENT_AUTHOR,  /* Edit: settings.yaml commentAuthor */

    /* The settings track's five (spdf_win_cmd_shell.h), which with Keep Image
     * Colors are macOS's whole Settings menu (:2112-2149) -- minus its four
     * other state files, which have no menu row here for the reason
     * spdf_win_state.h gives about bookmarks.yaml: a row per file is a mac
     * habit, and settings.yaml is the one a reader edits by hand. */
    SPDF_WIN_CMD_TOGGLE_DEFAULT_SIDEBAR,   /* defaultSidebarVisibleForNewDocuments */
    SPDF_WIN_CMD_TOGGLE_DEFAULT_MINIMAP,   /* defaultMinimapVisibleForNewDocuments */
    SPDF_WIN_CMD_TOGGLE_SEARCH_NEAREST,    /* searchJumpsToNearestResult */
    SPDF_WIN_CMD_OPEN_SETTINGS_FILE,       /* settings.yaml in the shell's editor, Ctrl+, */
    SPDF_WIN_CMD_REVEAL_SETTINGS_FOLDER,   /* the state directory in Explorer */

    SPDF_WIN_CMD_COUNT
} spdf_win_command;

/* THE OPEN RECENT SUBMENU'S IDS. Its rows are built at popup time from
 * spdf_win_recents (they change with every open), so they cannot be table rows;
 * they are WM_COMMAND ids in a range of their own above every table command,
 * SPDF_WIN_MENU_ID_BASE + FIRST + i for the i-th most recent document. A
 * handler tests the range; nothing else knows these numbers. */
#define SPDF_WIN_CMD_OPEN_RECENT_FIRST 0x100
#define SPDF_WIN_CMD_OPEN_RECENT_LAST 0x109 /* ten entries, the mac's kRecentDocumentLimit */

/* Which top-level menu an item belongs to. NONE is an ACCELERATOR-ONLY row: a
 * second key for a command that already has a menu item (Ctrl+= as well as
 * Ctrl++), which must fire but must not appear twice in the menu. */
typedef enum spdf_win_menu_id {
    SPDF_WIN_MENU_NONE = 0,
    SPDF_WIN_MENU_FILE,
    SPDF_WIN_MENU_GO,
    SPDF_WIN_MENU_ZOOM,
    SPDF_WIN_MENU_VIEW,
    SPDF_WIN_MENU_EDIT,
    SPDF_WIN_MENU_SETTINGS,
    SPDF_WIN_MENU_COUNT
} spdf_win_menu_id;

/* WM_COMMAND ids start here. Above every standard control id and far below the
 * 0xF000 range Windows reserves for system commands (SC_*). */
#define SPDF_WIN_MENU_ID_BASE 0x400

/* The tab overflow popup's ids: base + tab index. A separate range so a stray
 * WM_COMMAND can never be read as both a tab and a command. */
#define SPDF_WIN_MENU_TAB_ID_BASE 0x800
#define SPDF_WIN_MENU_TAB_ID_MAX 0x8ff

typedef struct SpdfWinMenuItem {
    int command;       /* spdf_win_command; SPDF_WIN_CMD_NONE marks a separator */
    int menu;          /* spdf_win_menu_id; NONE means accelerator-only */
    const wchar_t* title;  /* with the & mnemonic Win32 wants; NULL for a separator */
    const wchar_t* accel;  /* what the menu PRINTS, or NULL */
    unsigned key;      /* 0 when the item has no accelerator */
    unsigned mods;
    /* Drawn with a check mark, and CheckMenuItem'd from SpdfWinMenuState below.
     * macOS does the same three through -validateMenuItem: (:2266-2280). */
    int checkable;
} SpdfWinMenuItem;

/* The table. Order is menu order; a separator is a row whose command is NONE.
 *
 * `static` in a header gives each translation unit its own copy, which is what
 * the rest of this port's pure headers already do (spdf_win_chrome.h's inline
 * functions) and costs a few hundred bytes in the two files that include it. */

/* The rows themselves; see that header for why they live apart. */
#include "spdf_win_menu_table.h"

static SPDF_WIN_MENU_INLINE const SpdfWinMenuItem* spdf_win_menu_table(int* out_count) {
    if (out_count) *out_count = (int)(sizeof(k_spdf_win_menu) / sizeof(k_spdf_win_menu[0]));
    return k_spdf_win_menu;
}

/* The title of a top-level menu, with its mnemonic. macOS's own six, in macOS's
 * own order (:2155, :2200, :2247, :2263, :2342, :2112 -- Settings comes after
 * Edit there too, and last here because Help has no menu of its own). */
static SPDF_WIN_MENU_INLINE const wchar_t* spdf_win_menu_title(int menu) {
    switch (menu) {
        case SPDF_WIN_MENU_FILE: return L"&File";
        case SPDF_WIN_MENU_GO: return L"&Go To";
        case SPDF_WIN_MENU_ZOOM: return L"&Zoom";
        case SPDF_WIN_MENU_VIEW: return L"&View";
        case SPDF_WIN_MENU_EDIT: return L"&Edit";
        case SPDF_WIN_MENU_SETTINGS: return L"&Settings";
        default: return NULL;
    }
}

/* THE ONE ENTRY POINT FOR THE KEYBOARD.
 *
 * Returns the command a keystroke runs, or SPDF_WIN_CMD_NONE.
 *
 * `mods` MUST MATCH EXACTLY, and that is the point rather than an omission:
 * Ctrl+Shift+G is a different command from Ctrl+G, so a subset test would let
 * Find Previous fire Find Next -- and it must be the FIRST row that matches, so
 * that a more-modified row placed later can never be shadowed. Both are checked
 * in portable/win/tests/menu_test.c. */
static SPDF_WIN_MENU_INLINE int spdf_win_menu_command_for_key(unsigned key, unsigned mods) {
    int i, n = 0;
    const SpdfWinMenuItem* table = spdf_win_menu_table(&n);
    if (!key) return SPDF_WIN_CMD_NONE;
    /* Only the three bits this table speaks. A caller that also reports, say, a
     * Windows key must not thereby lose every accelerator. */
    mods &= (SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT | SPDF_WIN_ACCEL_ALT);
    for (i = 0; i < n; ++i) {
        if (!table[i].key || table[i].command == SPDF_WIN_CMD_NONE) continue;
        if (table[i].key == key && table[i].mods == mods) return table[i].command;
    }
    return SPDF_WIN_CMD_NONE;
}

/* THE SAME QUESTION ASKED OF A REAL KEYBOARD, which may not be a US one.
 *
 * A virtual-key code is a property of the LAYOUT: VK_OEM_MINUS is on no French
 * key at all, so every row above that names it was dead for a French reader.
 * spdf_win_menu_command_for_key_ex() adds the character match the macOS original
 * gets from AppKit for free, AFTER the exact match above and without changing
 * it. Read that header before touching either. */
#include "spdf_win_menu_layout.h"

/* The row that DRAWS a command, for a caller that wants its title or its
 * printed accelerator (the command palette, and the menu builder). NULL for a
 * command with no menu row. */
static SPDF_WIN_MENU_INLINE const SpdfWinMenuItem* spdf_win_menu_item_for_command(int command) {
    int i, n = 0;
    const SpdfWinMenuItem* table = spdf_win_menu_table(&n);
    /* SPDF_WIN_CMD_NONE is the SEPARATOR marker, not a command: without this
     * guard the first separator answers for it, and a caller asking for the
     * title of "no command" gets a row with a NULL title. */
    if (command == SPDF_WIN_CMD_NONE) return NULL;
    for (i = 0; i < n; ++i)
        if (table[i].command == command && table[i].menu != SPDF_WIN_MENU_NONE) return &table[i];
    return NULL;
}

/* --- what the menu shows about the app ----------------------------------
 *
 * Every check mark and every greyed item, gathered into a value so
 * spdf_win_menu_sync() takes no app pointer and a test can build one by hand --
 * the same reason SpdfWinChromeModel is a plain value type. */
typedef struct SpdfWinMenuState {
    int sidebar_visible;
    int minimap_visible;
    int dark_theme;
    /* Settings > Keep Image Colors in Dark Theme: SPDF_RENDER_PRESERVE_IMAGES is
     * set. Shown ticked whatever the theme, like the macOS Settings menu. */
    int keep_image_colors;
    /* The Settings menu's other three ticks. settings.yaml values rather than
     * app state, so spdf_win_menu_state_settings() fills them from the one
     * process-wide copy and spdf_win_menu_sync() calls it -- see there for why.
     * A caller may leave all three at 0; nothing else here reads them. */
    int default_sidebar_new_docs;
    int default_minimap_new_docs;
    int search_nearest;
    int regex;
    int regex_multiline;
    int can_close_tab;
    int tab_count; /* Close Other Tabs needs a second tab to close */
    int has_document;
    /* The document's OWN print flag. The only permission this menu honours.
     * spdf_has_permission(doc,'c') returns 1 unconditionally by product decision
     * (shenzhen_pdf_core.h:209-214) and this frontend must not add a copy gate,
     * so the three Copy Page items are never greyed on permissions -- only on
     * there being no document at all. Print is different: print, edit and
     * annotate still answer the document's own flags. */
    int can_print;
} SpdfWinMenuState;

/* The rules themselves -- the greying and the ticking; see that header for why
 * they live apart, and note that it needs SpdfWinMenuState above to be
 * complete, which is why the include sits here and not at the top. */
#include "spdf_win_menu_rules.h"

/* --- the Win32 half, in spdf_win_menu.cpp --------------------------------
 *
 * Handles are void* so this header needs no <windows.h>; every one of them is
 * an HMENU or an HWND and is documented as such at the parameter. */

/* Builds the whole bar from the table above. NULL on failure, which the caller
 * treats as "no menu bar" rather than as a fatal error: a viewer with no menu is
 * still a viewer. */
void* spdf_win_menu_create(void);
void spdf_win_menu_destroy(void* hmenu);

/* Applies the check marks and the greying. Cheap enough to call after every
 * command; it is a few CheckMenuItem/EnableMenuItem calls.
 *
 * It fills the three settings.yaml-backed ticks itself, through
 * spdf_win_menu_state_settings() below, so a caller building a state never has
 * to remember them. */
void spdf_win_menu_sync(void* hmenu, const SpdfWinMenuState* state);

/* THE SETTINGS-MENU TICKS THAT ARE NOT APP STATE: default_sidebar_new_docs,
 * default_minimap_new_docs and search_nearest, read from the one process-wide
 * spdf_win_settings_shared() copy and written into `st`.
 *
 * WHY THE MENU FETCHES THESE RATHER THAN BEING TOLD THEM. They are not facts
 * about a window -- they are three booleans in one file, of which the process
 * has exactly one copy, so a caller passing a different value would be
 * describing a settings.yaml that does not exist. That is the same call
 * recent_submenu() already makes in spdf_win_menu.cpp, and for the same reason:
 * a store read at the moment the menu is shown is always current and nothing
 * has to invalidate it. Everything a WINDOW knows -- the panels, the theme, the
 * tab count, the document's print flag -- is still passed in, because two
 * windows disagree about all of it.
 *
 * Callers that show these commands somewhere OTHER than through
 * spdf_win_menu_sync() (the Ctrl+K palette, which draws its own check marks
 * from spdf_win_menu_command_checked) must call this on their state. Declared
 * here but defined in the .cpp, which is what keeps spdf_win_menu.h free of
 * spdf_win_settings.h -- and menu_test.c free of a state directory. */
void spdf_win_menu_state_settings(SpdfWinMenuState* st);

/* The tab strip's overflow `...`. Shows every tab, radio-marks the selected one,
 * and returns the index the user chose or -1. Modal: TrackPopupMenu runs its own
 * loop, which is why this is a call and not an event. */
int spdf_win_menu_tab_overflow(void* hwnd, const wchar_t* const* titles, int count, int selected, int screen_x,
                               int screen_y);

/* THE WHOLE MENU AS A POPUP, hung off the toolbar's `...` button.
 *
 * WHY THE APP HAS NO MENU BAR. macOS's menus live in the SYSTEM menu bar at the
 * top of the screen -- they are not part of the window at all -- so an in-window
 * menu strip is a bar macOS does not have, and it showed: dark caption, then a
 * white Win32 menu strip, then dark chrome, reported from actual use as "a
 * double top bar like it's a window inside of a window".
 *
 * It cannot be fixed by theming. SetPreferredAppMode(AllowDark) darkens POPUP
 * menus but not the menu BAR, which the frame draws; making that dark means
 * owner-drawing the strip and taking over its measurement, keyboard navigation
 * and accessibility. Measured here, not assumed: with dark mode on and the
 * system set to dark, the bar stayed white.
 *
 * So the bar is gone and the same table is shown from the `...` overflow the
 * toolbar already had -- which is also what every modern Windows app of this
 * shape does (Edge, VS Code, Explorer all dropped the menu bar for an overflow),
 * and the button was already drawn and inert. Nothing is lost: every command
 * keeps its accelerator, because the keymap resolves those itself and never
 * depended on the bar (spdf_win_chrome_commands.h).
 *
 * Returns the chosen spdf_win_command, or SPDF_WIN_CMD_NONE. Takes the same
 * state the bar took, so ticks and greying are identical -- including that Print
 * greys on the document's own print flag while the Copy Page items never do.
 * Modal, like the tab overflow beside it. */
int spdf_win_menu_app_popup(void* hwnd, const SpdfWinMenuState* state, int screen_x, int screen_y);

/* Ctrl+O / the strip's `+` / the File menu. IFileOpenDialog, with the PDF and
 * e-book types this app opens. Returns 1 and fills `out_path` (UTF-16, NUL
 * terminated), or 0 when the user cancelled or the dialog could not be created.
 *
 * NATIVE ON PURPOSE. portable/docs/windows-port-handoff.md section 4: "Picking a
 * file has to hand the selection back to the app; no external file manager
 * can." */
int spdf_win_menu_open_dialog(void* hwnd, wchar_t* out_path, int out_len);

/* The same dialog, opened in `start_dir` (UTF-16; NULL or empty for the
 * shell's own default). The FOLDER POLICY -- the current document's folder,
 * else the last opened document's, else the user's home (26.8.31-1) -- is
 * decided by spdf_win_shell_open_start_dir() and passed in here, so this file
 * stays a dialog and knows nothing about tabs or recents. */
int spdf_win_menu_open_dialog_in(void* hwnd, const wchar_t* start_dir, wchar_t* out_path, int out_len);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_MENU_H */
