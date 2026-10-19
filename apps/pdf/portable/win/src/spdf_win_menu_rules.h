#pragma once

/* THE GREYING AND THE TICKING -- which commands a given SpdfWinMenuState
 * enables, and which of them it ticks. For spdf_win_menu.h only.
 *
 * Not a new layer, and the second cut of exactly the kind spdf_win_menu_table.h
 * describes: these two switches lived inline in spdf_win_menu.h and moved out
 * when the Settings menu's rows pushed that header past its 500-line cap
 * (tools/file-size-limits.md asks for an extracted file rather than a raised
 * one). Included from exactly one place, right where they used to be, after
 * SpdfWinMenuState -- which both of them take -- is complete.
 *
 * WHY THIS IS A GOOD SEAM. The table is "the one thing every parity track wants
 * to touch"; these rules are the second. A track that adds a checkable row adds
 * a row THERE and a case HERE and nothing else, so the two files a parity track
 * edits are now the two files that are only ever edited by parity tracks, while
 * the command enum, the keyboard lookup and the Win32 builder stay put.
 *
 * BOTH ARE PURE, and that is load-bearing rather than tidy: the greying rule and
 * the check-mark rule are what portable/win/tests/menu_test.c asserts
 * exhaustively over the whole table -- that only a `checkable` row can ever be
 * ticked, and that every `checkable` row HAS a state which ticks it, a check
 * mark nothing can set being a check mark that is always off. Neither needs a
 * window, a menu handle or a state directory.
 *
 * A NULL state means "know nothing": everything enabled, nothing ticked, which
 * is what a menu built before the app has any state must look like. */

/* Whether an item should be enabled given that state. Pure, so the greying rule
 * is testable; spdf_win_menu_sync() applies it. */
static SPDF_WIN_MENU_INLINE int spdf_win_menu_command_enabled(int command, const SpdfWinMenuState* st) {
    if (!st) return 1;
    switch (command) {
        case SPDF_WIN_CMD_CLOSE_TAB: return st->can_close_tab != 0;
        case SPDF_WIN_CMD_CLOSE_OTHER_TABS: return st->tab_count > 1;
        /* Everything that needs a document to act on. Open, New Tab and Quit
         * deliberately stay live with no document -- they are the way out of
         * that state. */
        case SPDF_WIN_CMD_FIRST_PAGE:
        case SPDF_WIN_CMD_PREV_PAGE:
        case SPDF_WIN_CMD_NEXT_PAGE:
        case SPDF_WIN_CMD_LAST_PAGE:
        case SPDF_WIN_CMD_GOTO_PAGE:
        case SPDF_WIN_CMD_ZOOM_IN:
        case SPDF_WIN_CMD_ZOOM_OUT:
        case SPDF_WIN_CMD_ZOOM_ACTUAL:
        case SPDF_WIN_CMD_FIT_PAGE:
        case SPDF_WIN_CMD_FIT_WIDTH:
        case SPDF_WIN_CMD_FIT_HEIGHT:
        case SPDF_WIN_CMD_COPY:
        case SPDF_WIN_CMD_FIND:
        case SPDF_WIN_CMD_FIND_NEXT:
        case SPDF_WIN_CMD_FIND_PREV:
        case SPDF_WIN_CMD_SAVE_AS:
        case SPDF_WIN_CMD_SAVE_PAGE_AS:
        case SPDF_WIN_CMD_PROPERTIES:
        case SPDF_WIN_CMD_COPY_PAGE:
        case SPDF_WIN_CMD_COPY_PAGE_TEXT:
        case SPDF_WIN_CMD_COPY_PAGE_IMAGE:
        /* The documents track's: each acts on the current document's PATH. */
        case SPDF_WIN_CMD_SHOW_IN_FOLDER:
        case SPDF_WIN_CMD_COPY_PATH:
        case SPDF_WIN_CMD_OPEN_IN_BROWSER:
        case SPDF_WIN_CMD_RELOAD:
        case SPDF_WIN_CMD_ADD_FAVORITE:
        /* The Markdown text size re-lays the selected document out; inert on a
         * PDF tab (spdf_win_md_command_text_step) but greyed with no tab at all. */
        case SPDF_WIN_CMD_MD_TEXT_SMALLER:
        case SPDF_WIN_CMD_MD_TEXT_LARGER:
        /* The comment commands act on the current document; whether there IS
         * a comment under the pointer is the handler's to answer, not a
         * greying rule -- the menu has no pointer. Set Author is a setting
         * and stays live with no document at all. */
        case SPDF_WIN_CMD_HIGHLIGHT_SELECTION:
        case SPDF_WIN_CMD_ADD_COMMENT:
        case SPDF_WIN_CMD_EDIT_COMMENT:
        case SPDF_WIN_CMD_DELETE_COMMENT: return st->has_document != 0;
        /* The print job is refused before any dialog appears when the document
         * forbids it; greying the item says so before the reader asks. */
        case SPDF_WIN_CMD_PRINT: return st->has_document != 0 && st->can_print != 0;
        /* THE WHOLE SETTINGS MENU STAYS LIVE WITH NO DOCUMENT, deliberately and
         * like macOS's (-validateMenuItem: at :16427 lets openSettingsFile: and
         * revealSettingsFolder: through unconditionally). A preference about how
         * the NEXT document opens is at its most useful when none is open, and
         * settings.yaml exists whether or not anything is being read. */
        default: return 1;
    }
}

/* Whether a checkable item is ticked. */
static SPDF_WIN_MENU_INLINE int spdf_win_menu_command_checked(int command, const SpdfWinMenuState* st) {
    if (!st) return 0;
    switch (command) {
        case SPDF_WIN_CMD_TOGGLE_SIDEBAR: return st->sidebar_visible != 0;
        case SPDF_WIN_CMD_TOGGLE_MINIMAP: return st->minimap_visible != 0;
        case SPDF_WIN_CMD_TOGGLE_THEME: return st->dark_theme != 0;
        case SPDF_WIN_CMD_TOGGLE_KEEP_IMAGE_COLORS: return st->keep_image_colors != 0;
        case SPDF_WIN_CMD_TOGGLE_DEFAULT_SIDEBAR: return st->default_sidebar_new_docs != 0;
        case SPDF_WIN_CMD_TOGGLE_DEFAULT_MINIMAP: return st->default_minimap_new_docs != 0;
        case SPDF_WIN_CMD_TOGGLE_SEARCH_NEAREST: return st->search_nearest != 0;
        case SPDF_WIN_CMD_FIND_REGEX: return st->regex != 0;
        case SPDF_WIN_CMD_FIND_REGEX_MULTILINE: return st->regex_multiline != 0;
        default: return 0;
    }
}
