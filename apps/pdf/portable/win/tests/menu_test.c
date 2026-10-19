/* menu_test.c — pins portable/win/src/spdf_win_menu.h.
 *
 * WHAT IT IS FOR. The menu bar and the keyboard read ONE table, which is the
 * whole point of the table existing (spdf_win_menu.h's header, and
 * portable/linux/gtk4/spdf_shortcuts.c's before it). The failures that costs are
 * all failures of the table, not of Win32:
 *
 *   - an accelerator that is PRINTED next to an item but does not fire, or
 *     fires a different command. Ctrl+Shift+G is the case that matters: a
 *     modifier test that accepted a superset would make Find Previous fire Find
 *     Next, which reads as "the shortcut does nothing" because the next match is
 *     usually where the reader already was;
 *   - two rows claiming the same keystroke, where whichever is first silently
 *     wins forever;
 *   - a command with a menu row and no way to reach it, or with two menu rows,
 *     which draws the same item twice;
 *   - a WM_COMMAND id that collides with the tab overflow popup's ids, which
 *     would make choosing the ninth tab run a menu command.
 *
 * Every one of those is a property of a static array and needs no window, no
 * message pump and no menu handle -- so they are checked exhaustively here
 * rather than by opening menus. The Win32 half (spdf_win_menu.cpp) is not
 * compiled in: it is CreateMenu and TrackPopupMenu, which cannot be asserted
 * about without a desktop, and the session on this machine is locked.
 *
 * Header-only under test, so no `spdf-test-sources` line -- same as
 * chrome_input_test.c and tabstrip_geometry_test.c.
 */
#include "spdf_win_menu.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if ((int)(a) != (int)(b)) {                                                                                    \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- the shape of the table ---------------------------------------------- */

static void test_table_is_well_formed(void) {
    int n = 0, i, j;
    const SpdfWinMenuItem* t = spdf_win_menu_table(&n);
    CHECK(n > 0);

    for (i = 0; i < n; ++i) {
        if (t[i].command == SPDF_WIN_CMD_NONE) {
            /* A separator: no title, no key, and it belongs to a real menu (an
             * accelerator-only separator is meaningless). */
            CHECK(t[i].title == NULL);
            CHECK_EQI(t[i].key, 0);
            CHECK(t[i].menu != SPDF_WIN_MENU_NONE);
            continue;
        }
        CHECK(t[i].command > SPDF_WIN_CMD_NONE && t[i].command < SPDF_WIN_CMD_COUNT);
        if (t[i].menu == SPDF_WIN_MENU_NONE) {
            /* An accelerator-only row exists ONLY to add a second key; a title
             * on one would never be drawn and a row with neither does nothing. */
            CHECK(t[i].title == NULL);
            CHECK(t[i].key != 0);
            continue;
        }
        CHECK(t[i].menu > SPDF_WIN_MENU_NONE && t[i].menu < SPDF_WIN_MENU_COUNT);
        CHECK(t[i].title != NULL && t[i].title[0] != L'\0');
        /* A mnemonic, so every item is reachable from Alt. */
        CHECK(wcschr(t[i].title, L'&') != NULL);
        /* An item that prints an accelerator must have one, and one that has an
         * accelerator must print it -- the two halves whose disagreement is the
         * reason this table exists at all. */
        CHECK((t[i].accel != NULL) == (t[i].key != 0));
        /* A tab in the title would be read as the accelerator column separator
         * and split the name in two. */
        CHECK(wcschr(t[i].title, L'\t') == NULL);
    }

    /* No two rows claim the same keystroke. */
    for (i = 0; i < n; ++i) {
        if (!t[i].key) continue;
        for (j = i + 1; j < n; ++j) {
            if (!t[j].key) continue;
            CHECK(!(t[i].key == t[j].key && t[i].mods == t[j].mods));
        }
    }
}

/* Every command reachable, exactly once, from exactly one menu. */
static void test_every_command_has_one_menu_row(void) {
    int n = 0, i, c;
    const SpdfWinMenuItem* t = spdf_win_menu_table(&n);

    for (c = SPDF_WIN_CMD_NONE + 1; c < SPDF_WIN_CMD_COUNT; ++c) {
        int rows = 0;
        for (i = 0; i < n; ++i)
            if (t[i].command == c && t[i].menu != SPDF_WIN_MENU_NONE) ++rows;
        CHECK_EQI(rows, 1);
        CHECK(spdf_win_menu_item_for_command(c) != NULL);
    }
    CHECK(spdf_win_menu_item_for_command(SPDF_WIN_CMD_NONE) == NULL);
    CHECK(spdf_win_menu_item_for_command(SPDF_WIN_CMD_COUNT + 99) == NULL);

    /* Every menu the enum names has a title, and every row's menu is one of
     * them -- a row in a menu with no title would be built into nothing. */
    for (i = SPDF_WIN_MENU_NONE + 1; i < SPDF_WIN_MENU_COUNT; ++i) CHECK(spdf_win_menu_title(i) != NULL);
    CHECK(spdf_win_menu_title(SPDF_WIN_MENU_NONE) == NULL);
    CHECK(spdf_win_menu_title(SPDF_WIN_MENU_COUNT) == NULL);
}

/* --- the keyboard -------------------------------------------------------- */

static void test_every_accelerator_round_trips(void) {
    int n = 0, i;
    const SpdfWinMenuItem* t = spdf_win_menu_table(&n);
    for (i = 0; i < n; ++i) {
        if (!t[i].key || t[i].command == SPDF_WIN_CMD_NONE) continue;
        CHECK_EQI(spdf_win_menu_command_for_key(t[i].key, t[i].mods), t[i].command);
    }
}

/* THE MODIFIERS MUST MATCH EXACTLY. Every one of these pairs is a real command
 * that a subset test would collapse into its neighbour. */
static void test_modifiers_are_exact(void) {
    CHECK_EQI(spdf_win_menu_command_for_key('G', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_FIND_NEXT);
    CHECK_EQI(spdf_win_menu_command_for_key('G', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT), SPDF_WIN_CMD_FIND_PREV);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_TAB, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_NEXT_TAB);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_TAB, SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT),
              SPDF_WIN_CMD_PREV_TAB);
    /* The Markdown text size shares the zoom keys and differs by Alt alone:
     * Ctrl+- zooms, Ctrl+Alt+- shrinks the text. A modifier test that ignored
     * Alt would make every A- press a zoom out. */
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_MINUS, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_ZOOM_OUT);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_MINUS, SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_ALT),
              SPDF_WIN_CMD_MD_TEXT_SMALLER);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_PLUS, SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_ALT),
              SPDF_WIN_CMD_MD_TEXT_LARGER);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_PLUS, SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT),
              SPDF_WIN_CMD_ZOOM_IN);
    /* Presentation has two keys, F5 on the menu and the mac's Shift+Ctrl+F as
     * an accelerator-only row; Ctrl+F alone is still Find. */
    CHECK_EQI(spdf_win_menu_command_for_key('F', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT), SPDF_WIN_CMD_PRESENTATION);
    CHECK_EQI(spdf_win_menu_command_for_key('F', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_FIND);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_F5, 0), SPDF_WIN_CMD_PRESENTATION);
    /* Both live on the View menu and grey without a document, like the zooms. */
    CHECK(spdf_win_menu_item_for_command(SPDF_WIN_CMD_MD_TEXT_SMALLER)->menu == SPDF_WIN_MENU_VIEW);
    CHECK(spdf_win_menu_item_for_command(SPDF_WIN_CMD_MD_TEXT_LARGER)->menu == SPDF_WIN_MENU_VIEW);
    {
        SpdfWinMenuState st;
        memset(&st, 0, sizeof(st));
        CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_MD_TEXT_LARGER, &st));
        st.has_document = 1;
        CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_MD_TEXT_LARGER, &st));
    }

    /* AN UNMODIFIED KEY IS NOT AN ACCELERATOR, which is what lets the same key
     * be typed into the find field. Every letter and digit in the table, bare,
     * must come back as nothing. */
    CHECK_EQI(spdf_win_menu_command_for_key('O', 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key('F', 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key('W', 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key('1', 0), SPDF_WIN_CMD_NONE);
    /* And Ctrl+Alt+O is not Ctrl+O: AltGr on a European layout reports both,
     * and it is how a reader types @ or #. */
    CHECK_EQI(spdf_win_menu_command_for_key('O', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_ALT), SPDF_WIN_CMD_NONE);
    /* A modifier bit this table does not speak (the Windows key, say) must not
     * lose the accelerator -- only the three it knows are compared. */
    CHECK_EQI(spdf_win_menu_command_for_key('O', SPDF_WIN_ACCEL_CTRL | 0x40u), SPDF_WIN_CMD_OPEN);
    /* Key 0 is "no key"; a row with no accelerator must never be matched. */
    CHECK_EQI(spdf_win_menu_command_for_key(0, 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key(0, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_NONE);
}

/* The zoom keys have three spellings between them and every one has to work:
 * Ctrl+= (the unshifted key), Ctrl++ (the same key shifted, which is what the
 * menu prints) and the numeric keypad. */
static void test_zoom_has_every_spelling(void) {
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_PLUS, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_ZOOM_IN);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_PLUS, SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT),
              SPDF_WIN_CMD_ZOOM_IN);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_ADD, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_ZOOM_IN);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_MINUS, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_ZOOM_OUT);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_SUBTRACT, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_ZOOM_OUT);
}

/* macOS's own fit order, which the Windows keymap used to have back to front:
 * Cmd+1 Fit Page, Cmd+2 Fit Width, Cmd+3 Fit Height (ShenzhenPDFMac.mm:2254-2258)
 * and GTK4's win.fit-page / fit-width / fit-height identically. */
static void test_fit_keys_match_the_other_two_frontends(void) {
    CHECK_EQI(spdf_win_menu_command_for_key('1', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_FIT_PAGE);
    CHECK_EQI(spdf_win_menu_command_for_key('2', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_FIT_WIDTH);
    CHECK_EQI(spdf_win_menu_command_for_key('3', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_FIT_HEIGHT);
    CHECK_EQI(spdf_win_menu_command_for_key('0', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_ZOOM_ACTUAL);
}

/* macOS puts page navigation on Option+arrows (:2210-2229); Alt is the same key
 * in the same role, and the bare arrows must stay with the document -- they are
 * how a reader scrolls. */
static void test_page_navigation_is_on_alt(void) {
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_UP, SPDF_WIN_ACCEL_ALT), SPDF_WIN_CMD_FIRST_PAGE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_DOWN, SPDF_WIN_ACCEL_ALT), SPDF_WIN_CMD_LAST_PAGE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_LEFT, SPDF_WIN_ACCEL_ALT), SPDF_WIN_CMD_PREV_PAGE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_RIGHT, SPDF_WIN_ACCEL_ALT), SPDF_WIN_CMD_NEXT_PAGE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_UP, 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_DOWN, 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_LEFT, 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_RIGHT, 0), SPDF_WIN_CMD_NONE);
    /* Page Up / Page Down likewise: bare they page the DOCUMENT, with Ctrl they
     * change tab. */
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_PRIOR, 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_NEXT, 0), SPDF_WIN_CMD_NONE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_PRIOR, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_PREV_TAB);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_NEXT, SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_NEXT_TAB);
}

/* --- ids ----------------------------------------------------------------- */

/* The two id ranges must not overlap: a WM_COMMAND is one number, and the tab
 * popup's ids and the menu's are both read out of it. */
static void test_id_ranges_do_not_overlap(void) {
    CHECK(SPDF_WIN_MENU_ID_BASE + SPDF_WIN_CMD_COUNT < SPDF_WIN_MENU_TAB_ID_BASE);
    CHECK(SPDF_WIN_MENU_TAB_ID_BASE < SPDF_WIN_MENU_TAB_ID_MAX);
    /* Clear of the SC_* system commands, which arrive as WM_SYSCOMMAND but are
     * conventionally kept out of an application's id space anyway. */
    CHECK(SPDF_WIN_MENU_TAB_ID_MAX < 0xF000);
    /* The popup can address at least as many tabs as the strip can draw. */
    CHECK(SPDF_WIN_MENU_TAB_ID_MAX - SPDF_WIN_MENU_TAB_ID_BASE + 1 >= 64);
}

/* --- greying and ticking ------------------------------------------------- */

/* The documents track's rows and ids: Open Path... on Ctrl+Shift+O (macOS
 * Cmd+Shift+O), the three shell commands and Reload greyed without a document,
 * and the Open Recent submenu's id range -- above every table command, below
 * the tab overflow's range, so a WM_COMMAND can be read as exactly one thing. */
static void test_documents_track_rows(void) {
    SpdfWinMenuState st;
    CHECK_EQI(spdf_win_menu_command_for_key('O', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT), SPDF_WIN_CMD_OPEN_PATH);
    CHECK_EQI(spdf_win_menu_command_for_key('O', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_OPEN);
    CHECK_EQI(spdf_win_menu_command_for_key('D', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_ADD_FAVORITE);
    CHECK_EQI(spdf_win_menu_command_for_key('K', SPDF_WIN_ACCEL_CTRL), SPDF_WIN_CMD_PALETTE);
    CHECK_EQI(spdf_win_menu_command_for_key('T', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT),
              SPDF_WIN_CMD_REOPEN_CLOSED_TAB);
    CHECK(spdf_win_menu_item_for_command(SPDF_WIN_CMD_COPY_PATH) != NULL);
    CHECK(spdf_win_menu_item_for_command(SPDF_WIN_CMD_OPEN_IN_BROWSER) != NULL);
    CHECK(spdf_win_menu_item_for_command(SPDF_WIN_CMD_OPEN_RECENT)->menu == SPDF_WIN_MENU_GO);

    memset(&st, 0, sizeof(st));
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_SHOW_IN_FOLDER, &st));
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_COPY_PATH, &st));
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_OPEN_IN_BROWSER, &st));
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_RELOAD, &st));
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_ADD_FAVORITE, &st));
    /* The ways INTO a document stay live with none open. */
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_OPEN_PATH, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_REOPEN_CLOSED_TAB, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_PALETTE, &st));
    st.has_document = 1;
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_SHOW_IN_FOLDER, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_RELOAD, &st));

    CHECK(SPDF_WIN_CMD_OPEN_RECENT_FIRST >= SPDF_WIN_CMD_COUNT);
    CHECK(SPDF_WIN_CMD_OPEN_RECENT_LAST - SPDF_WIN_CMD_OPEN_RECENT_FIRST + 1 == 10);
    CHECK(SPDF_WIN_MENU_ID_BASE + SPDF_WIN_CMD_OPEN_RECENT_LAST < SPDF_WIN_MENU_TAB_ID_BASE);
}

static void test_enabled_and_checked_rules(void) {
    SpdfWinMenuState st;
    memset(&st, 0, sizeof(st));

    /* NO DOCUMENT: everything that acts on one is dead, and the three ways back
     * to a document are not. That is the state the app is in after the last tab
     * closes, and a File menu greyed out there is a dead end. */
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_NEXT_PAGE, &st));
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_ZOOM_IN, &st));
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_FIND, &st));
    CHECK(!spdf_win_menu_command_enabled(SPDF_WIN_CMD_CLOSE_TAB, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_OPEN, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_NEW_TAB, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_QUIT, &st));
    /* The view toggles do not need a document either: a reader may put the
     * panels where they want them before opening anything. */
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_TOGGLE_SIDEBAR, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_TOGGLE_MINIMAP, &st));

    st.has_document = 1;
    st.can_close_tab = 1;
    st.tab_count = 2;
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_NEXT_PAGE, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_FIND_PREV, &st));
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_CLOSE_TAB, &st));

    /* Nothing is ticked in a zeroed state, and each of the four checkables
     * follows its own flag and no one else's. */
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_SIDEBAR, &st));
    st.sidebar_visible = 1;
    CHECK(spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_SIDEBAR, &st));
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_MINIMAP, &st));
    st.minimap_visible = 1;
    st.dark_theme = 1;
    st.regex = 1;
    CHECK(spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_MINIMAP, &st));
    CHECK(spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_THEME, &st));
    CHECK(spdf_win_menu_command_checked(SPDF_WIN_CMD_FIND_REGEX, &st));
    /* A command that is not checkable is never checked, however the state
     * reads -- a tick beside "Open..." would be nonsense. */
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_OPEN, &st));
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_FIND, &st));

    /* A NULL state is "know nothing": everything enabled, nothing ticked. That
     * is what a menu built before the app has any state must look like, and it
     * must not crash. */
    CHECK(spdf_win_menu_command_enabled(SPDF_WIN_CMD_NEXT_PAGE, NULL));
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_SIDEBAR, NULL));
}

/* Only the checkable rows may be ticked, and every checkable row must have a
 * state that ticks it -- a check mark nothing can set is a check mark that is
 * always off. */
static void test_checkable_flag_matches_the_predicate(void) {
    SpdfWinMenuState all;
    int n = 0, i;
    const SpdfWinMenuItem* t = spdf_win_menu_table(&n);
    memset(&all, 0, sizeof(all));
    all.sidebar_visible = all.minimap_visible = all.dark_theme = all.regex = 1;
    all.keep_image_colors = 1;
    all.regex_multiline = 1;
    all.default_sidebar_new_docs = all.default_minimap_new_docs = all.search_nearest = 1;
    for (i = 0; i < n; ++i) {
        if (t[i].command == SPDF_WIN_CMD_NONE || t[i].menu == SPDF_WIN_MENU_NONE) continue;
        CHECK_EQI(spdf_win_menu_command_checked(t[i].command, &all) != 0, t[i].checkable != 0);
    }
}

/* THE SETTINGS MENU, which for a long time was one row of six.
 *
 * macOS's Settings menu (ShenzhenPDFMac.mm:2112-2149) is four toggles, then the
 * state files, then Reveal Settings Folder; this port has all four toggles, the
 * one state file a reader edits by hand, and the reveal. What can go wrong is
 * not Win32 -- it is the table:
 *
 *   - a toggle whose tick nothing can set, which is a row that lies about the
 *     setting behind it every time the setting is on -- and three of these four
 *     default to ON, so an always-unticked row would be wrong on a fresh
 *     install rather than merely wrong eventually;
 *   - Ctrl+, landing on some other command, or on nothing;
 *   - Keep Image Colors left on the View menu as well as here, which would draw
 *     it twice -- test_every_command_has_one_menu_row() catches that globally,
 *     and this pins WHERE the one row is;
 *   - a Settings row greyed with no document, which would hide the preferences
 *     exactly when a reader who has just closed everything goes looking. */
static void test_settings_menu(void) {
    const int rows[] = {SPDF_WIN_CMD_TOGGLE_DEFAULT_SIDEBAR, SPDF_WIN_CMD_TOGGLE_DEFAULT_MINIMAP,
                        SPDF_WIN_CMD_TOGGLE_KEEP_IMAGE_COLORS, SPDF_WIN_CMD_TOGGLE_SEARCH_NEAREST,
                        SPDF_WIN_CMD_OPEN_SETTINGS_FILE, SPDF_WIN_CMD_REVEAL_SETTINGS_FOLDER};
    SpdfWinMenuState st;
    int i;

    /* All six on the Settings menu, which exists and has a title. */
    CHECK(spdf_win_menu_title(SPDF_WIN_MENU_SETTINGS) != NULL);
    for (i = 0; i < (int)(sizeof(rows) / sizeof(rows[0])); ++i) {
        const SpdfWinMenuItem* it = spdf_win_menu_item_for_command(rows[i]);
        CHECK(it != NULL);
        if (!it) continue;
        CHECK_EQI(it->menu, SPDF_WIN_MENU_SETTINGS);
    }
    /* Keep Image Colors moved OFF the View menu; Dark Reading Theme stayed,
     * because it is the state of THIS window and not a stored preference. */
    CHECK(spdf_win_menu_item_for_command(SPDF_WIN_CMD_TOGGLE_THEME)->menu == SPDF_WIN_MENU_VIEW);

    /* The mac's Cmd+, is Ctrl+, and it opens settings.yaml. */
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_COMMA, SPDF_WIN_ACCEL_CTRL),
              SPDF_WIN_CMD_OPEN_SETTINGS_FILE);
    CHECK_EQI(spdf_win_menu_command_for_key(SPDF_WIN_KEY_OEM_COMMA, 0), SPDF_WIN_CMD_NONE);
    /* And VK_OEM_COMMA is not one of the zoom keys, which is the mistake 0xBC
     * invites: it sits between VK_OEM_PLUS (0xBB) and VK_OEM_MINUS (0xBD), so a
     * one-digit slip in the #define would make Ctrl+, zoom. */
    CHECK_EQI(SPDF_WIN_KEY_OEM_COMMA, 0xBC);
    CHECK(SPDF_WIN_KEY_OEM_COMMA != SPDF_WIN_KEY_OEM_PLUS && SPDF_WIN_KEY_OEM_COMMA != SPDF_WIN_KEY_OEM_MINUS);

    /* NOT ONE OF THEM NEEDS A DOCUMENT. A preference about how the NEXT
     * document opens is at its most useful when none is open, and settings.yaml
     * exists whether or not anything is being read. */
    memset(&st, 0, sizeof(st));
    for (i = 0; i < (int)(sizeof(rows) / sizeof(rows[0])); ++i) CHECK(spdf_win_menu_command_enabled(rows[i], &st));

    /* Each of the three new toggles follows its own field and no one else's. */
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_DEFAULT_SIDEBAR, &st));
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_DEFAULT_MINIMAP, &st));
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_SEARCH_NEAREST, &st));
    st.default_sidebar_new_docs = 1;
    CHECK(spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_DEFAULT_SIDEBAR, &st));
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_DEFAULT_MINIMAP, &st));
    st.default_minimap_new_docs = 1;
    st.search_nearest = 1;
    CHECK(spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_DEFAULT_MINIMAP, &st));
    CHECK(spdf_win_menu_command_checked(SPDF_WIN_CMD_TOGGLE_SEARCH_NEAREST, &st));
    /* The two rows that DO something rather than record something are never
     * ticked, however the state reads -- a check mark beside "Reveal Settings
     * Folder" would claim the folder is revealed. */
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_OPEN_SETTINGS_FILE, &st));
    CHECK(!spdf_win_menu_command_checked(SPDF_WIN_CMD_REVEAL_SETTINGS_FOLDER, &st));
    CHECK(!spdf_win_menu_item_for_command(SPDF_WIN_CMD_OPEN_SETTINGS_FILE)->checkable);
    CHECK(!spdf_win_menu_item_for_command(SPDF_WIN_CMD_REVEAL_SETTINGS_FOLDER)->checkable);
}

int main(void) {
    test_table_is_well_formed();
    test_every_command_has_one_menu_row();
    test_every_accelerator_round_trips();
    test_modifiers_are_exact();
    test_zoom_has_every_spelling();
    test_fit_keys_match_the_other_two_frontends();
    test_page_navigation_is_on_alt();
    test_id_ranges_do_not_overlap();
    test_enabled_and_checked_rules();
    test_documents_track_rows();
    test_checkable_flag_matches_the_predicate();
    test_settings_menu();

    printf("menu_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
