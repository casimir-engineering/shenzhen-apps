#pragma once

/* THE MENU TABLE -- every row of every menu, in display order, for
 * spdf_win_menu.h only.
 *
 * Not a new layer: this array lived inline in spdf_win_menu.h and moved out
 * when the release-note audit's pre-declared rows pushed that header past its
 * 500-line cap (tools/file-size-limits.md asks for an extracted file rather
 * than a raised one). It is included from exactly one place, right where the
 * array used to be, after the SpdfWinMenuItem type and the command enum it
 * depends on.
 *
 * WHY THIS IS A GOOD SEAM AND NOT JUST A CUT: the rows are the one thing every
 * parity track wants to touch and nothing else in spdf_win_menu.h is -- so the
 * table gets a file that can be owned by the track that builds the runtime
 * Recents and Favorites entries, while the enum, the enable rules and the
 * popup builder stay put. A row with a command nobody handles yet is inert:
 * command_perform() falls through to 'return 0'.
 *
 * Row shape: {command, menu, L"&Title" (NULL = separator), L"accelerator
 * label", key (a char or an SPDF_WIN_KEY_*), SPDF_WIN_ACCEL_* modifiers,
 * checkable}. Accelerators follow the macOS notes with Cmd -> Ctrl. */

static const SpdfWinMenuItem k_spdf_win_menu[] = {
    /* --- File --------------------------------------------------------- */
    {SPDF_WIN_CMD_OPEN, SPDF_WIN_MENU_FILE, L"&Open...", L"Ctrl+O", 'O', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NEW_TAB, SPDF_WIN_MENU_FILE, L"Open in New &Tab...", L"Ctrl+T", 'T', SPDF_WIN_ACCEL_CTRL, 0},
    /* macOS File > Open Path... (Cmd+Shift+O): a typed path for a file the
     * picker cannot reach conveniently -- a UNC share, a pasted path. */
    {SPDF_WIN_CMD_OPEN_PATH, SPDF_WIN_MENU_FILE, L"Open Pat&h...", L"Ctrl+Shift+O", 'O',
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_FILE, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_SAVE_AS, SPDF_WIN_MENU_FILE, L"&Save As...", L"Ctrl+S", 'S', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_SAVE_PAGE_AS, SPDF_WIN_MENU_FILE, L"Save &Page As...", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_PRINT, SPDF_WIN_MENU_FILE, L"&Print...", L"Ctrl+P", 'P', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_FILE, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_PROPERTIES, SPDF_WIN_MENU_FILE, L"P&roperties...", L"Ctrl+I", 'I', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_FILE, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_CLOSE_TAB, SPDF_WIN_MENU_FILE, L"&Close", L"Ctrl+W", 'W', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_CLOSE_OTHER_TABS, SPDF_WIN_MENU_FILE, L"Close &Other Tabs", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_REOPEN_CLOSED_TAB, SPDF_WIN_MENU_FILE, L"Reopen Last Closed Ta&b", L"Ctrl+Shift+T", 'T', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_FILE, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_NEW_WINDOW, SPDF_WIN_MENU_FILE, L"New &Window", L"Ctrl+N", 'N', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_MOVE_TAB_TO_WINDOW, SPDF_WIN_MENU_FILE, L"&Move Tab to New Window", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_FILE, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_SHOW_IN_FOLDER, SPDF_WIN_MENU_FILE, L"Show in &Folder", NULL, 0, 0, 0},
    /* GTK4 win.copy-path / win.open-in-browser, the two neighbours of
     * win.show-in-folder in spdf_shortcuts.c's Tools group. */
    {SPDF_WIN_CMD_COPY_PATH, SPDF_WIN_MENU_FILE, L"Cop&y Path", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_OPEN_IN_BROWSER, SPDF_WIN_MENU_FILE, L"Open in Bro&wser", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_RELOAD, SPDF_WIN_MENU_FILE, L"Re&load", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_SET_DEFAULT_READER, SPDF_WIN_MENU_FILE, L"Make &Default PDF Reader", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_CHECK_UPDATES, SPDF_WIN_MENU_FILE, L"Check for &Updates...", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_FILE, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_QUIT, SPDF_WIN_MENU_FILE, L"&Quit Shenzhen PDF", L"Ctrl+Q", 'Q', SPDF_WIN_ACCEL_CTRL, 0},

    /* --- Go To -------------------------------------------------------- */
    {SPDF_WIN_CMD_FIRST_PAGE, SPDF_WIN_MENU_GO, L"&First Page", L"Alt+Up", SPDF_WIN_KEY_UP, SPDF_WIN_ACCEL_ALT, 0},
    {SPDF_WIN_CMD_PREV_PAGE, SPDF_WIN_MENU_GO, L"&Previous Page", L"Alt+Left", SPDF_WIN_KEY_LEFT, SPDF_WIN_ACCEL_ALT,
     0},
    {SPDF_WIN_CMD_NEXT_PAGE, SPDF_WIN_MENU_GO, L"&Next Page", L"Alt+Right", SPDF_WIN_KEY_RIGHT, SPDF_WIN_ACCEL_ALT, 0},
    {SPDF_WIN_CMD_LAST_PAGE, SPDF_WIN_MENU_GO, L"&Last Page", L"Alt+Down", SPDF_WIN_KEY_DOWN, SPDF_WIN_ACCEL_ALT, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_GO, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_GOTO_PAGE, SPDF_WIN_MENU_GO, L"&Go To Page...", L"Ctrl+L", 'L', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_PALETTE, SPDF_WIN_MENU_GO, L"&Command Palette...", L"Ctrl+K", 'K', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_GO, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_ADD_FAVORITE, SPDF_WIN_MENU_GO, L"Add to &Favorites", L"Ctrl+D", 'D', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_OPEN_RECENT, SPDF_WIN_MENU_GO, L"Open &Recent", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_GO, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_PREV_TAB, SPDF_WIN_MENU_GO, L"Previous &Tab", L"Ctrl+PgUp", SPDF_WIN_KEY_PRIOR,
     SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NEXT_TAB, SPDF_WIN_MENU_GO, L"Next Ta&b", L"Ctrl+PgDn", SPDF_WIN_KEY_NEXT, SPDF_WIN_ACCEL_CTRL, 0},

    /* --- Zoom --------------------------------------------------------- */
    {SPDF_WIN_CMD_ZOOM_IN, SPDF_WIN_MENU_ZOOM, L"Zoom &In", L"Ctrl++", SPDF_WIN_KEY_OEM_PLUS, SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_ZOOM_OUT, SPDF_WIN_MENU_ZOOM, L"Zoom &Out", L"Ctrl+-", SPDF_WIN_KEY_OEM_MINUS, SPDF_WIN_ACCEL_CTRL,
     0},
    {SPDF_WIN_CMD_ZOOM_ACTUAL, SPDF_WIN_MENU_ZOOM, L"&100%", L"Ctrl+0", '0', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_ZOOM, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_FIT_PAGE, SPDF_WIN_MENU_ZOOM, L"Fit &Page", L"Ctrl+1", '1', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_FIT_WIDTH, SPDF_WIN_MENU_ZOOM, L"Fit &Width", L"Ctrl+2", '2', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_FIT_HEIGHT, SPDF_WIN_MENU_ZOOM, L"Fit &Height", L"Ctrl+3", '3', SPDF_WIN_ACCEL_CTRL, 0},

    /* --- View --------------------------------------------------------- */
    {SPDF_WIN_CMD_TOGGLE_SIDEBAR, SPDF_WIN_MENU_VIEW, L"Show &Side Panel", L"F9", SPDF_WIN_KEY_F9, 0, 1},
    {SPDF_WIN_CMD_TOGGLE_MINIMAP, SPDF_WIN_MENU_VIEW, L"Show &Minimap", NULL, 0, 0, 1},
    {SPDF_WIN_CMD_TOGGLE_THEME, SPDF_WIN_MENU_VIEW, L"&Dark Reading Theme", L"Ctrl+Shift+I", 'I',
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 1},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_VIEW, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_PRESENTATION, SPDF_WIN_MENU_VIEW, L"&Presentation", L"F5", SPDF_WIN_KEY_F5, 0, 0},
    {SPDF_WIN_CMD_FULLSCREEN, SPDF_WIN_MENU_VIEW, L"F&ull Screen", L"F11", SPDF_WIN_KEY_F11, 0, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_VIEW, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_ROTATE_CW, SPDF_WIN_MENU_VIEW, L"&Rotate Clockwise", L"Ctrl+R", 'R', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_ROTATE_CCW, SPDF_WIN_MENU_VIEW, L"Rotate &Anticlockwise", L"Ctrl+Shift+R", 'R', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_VIEW, NULL, NULL, 0, 0, 0},
    /* The Markdown reader's A-/A+ (ShenzhenPDFMac.mm Cmd+Alt+-/=): 10% of the
     * base size per press, persisted as markdownFontScale. Ctrl+Alt so they
     * cannot collide with the zoom accelerators on the same two keys. */
    {SPDF_WIN_CMD_MD_TEXT_SMALLER, SPDF_WIN_MENU_VIEW, L"Smaller Te&xt", L"Ctrl+Alt+-", SPDF_WIN_KEY_OEM_MINUS,
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_ALT, 0},
    {SPDF_WIN_CMD_MD_TEXT_LARGER, SPDF_WIN_MENU_VIEW, L"&Larger Text", L"Ctrl+Alt+=", SPDF_WIN_KEY_OEM_PLUS,
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_ALT, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_VIEW, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_SHORTCUTS, SPDF_WIN_MENU_VIEW, L"&Keyboard Shortcuts", L"F1", SPDF_WIN_KEY_F1, 0, 0},
    {SPDF_WIN_CMD_ABOUT, SPDF_WIN_MENU_VIEW, L"A&bout Shenzhen PDF", NULL, 0, 0, 0},

    /* --- Edit --------------------------------------------------------- */
    /* macOS has a plain "Copy" on Cmd+C for its own text fields and a separate
     * "Copy Selected Document Text" with no key (:2346, :2350). There is one
     * selection to copy on Windows -- the document's -- so the two are one item,
     * on Ctrl+C, which is also GTK4's win.copy. */
    {SPDF_WIN_CMD_COPY, SPDF_WIN_MENU_EDIT, L"&Copy", L"Ctrl+C", 'C', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_EDIT, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_COPY_PAGE, SPDF_WIN_MENU_EDIT, L"Copy &Page", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_COPY_PAGE_TEXT, SPDF_WIN_MENU_EDIT, L"Copy Page &Text", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_COPY_PAGE_IMAGE, SPDF_WIN_MENU_EDIT, L"Copy Page &Image", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_EDIT, NULL, NULL, 0, 0, 0},
    /* Comments (the annotations track). GTK's context menu lists Add Comment,
     * Add Highlight Comment, Edit Comment, Delete Comment (spdf_annot.c:1116);
     * neither original binds a key to them, so the two accelerators are this
     * port's: Ctrl+Shift+H and Ctrl+Shift+M are free of every other row, and
     * Delete over a marker is the desktop's own gesture. */
    {SPDF_WIN_CMD_HIGHLIGHT_SELECTION, SPDF_WIN_MENU_EDIT, L"&Highlight Selection...", L"Ctrl+Shift+H", 'H',
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    {SPDF_WIN_CMD_ADD_COMMENT, SPDF_WIN_MENU_EDIT, L"Add Co&mment...", L"Ctrl+Shift+M", 'M',
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    {SPDF_WIN_CMD_EDIT_COMMENT, SPDF_WIN_MENU_EDIT, L"&Edit Comment...", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_DELETE_COMMENT, SPDF_WIN_MENU_EDIT, L"&Delete Comment...", L"Del", SPDF_WIN_KEY_DELETE, 0, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_EDIT, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_SELECT_ALL, SPDF_WIN_MENU_EDIT, L"Select &All", L"Ctrl+A", 'A', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_PASTE_SEARCH, SPDF_WIN_MENU_EDIT, L"&Paste to Search", L"Ctrl+V", 'V', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_EDIT, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_OCR, SPDF_WIN_MENU_EDIT, L"Make Searchable (&OCR)...", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_TRANSLATE_SELECTION, SPDF_WIN_MENU_EDIT, L"&Translate Selection...", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_TRANSLATE_DOCUMENT, SPDF_WIN_MENU_EDIT, L"Translate &Document...", NULL, 0, 0, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_EDIT, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_FIND, SPDF_WIN_MENU_EDIT, L"&Find", L"Ctrl+F", 'F', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_FIND_NEXT, SPDF_WIN_MENU_EDIT, L"Find &Next", L"Ctrl+G", 'G', SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_FIND_PREV, SPDF_WIN_MENU_EDIT, L"Find &Previous", L"Ctrl+Shift+G", 'G',
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_EDIT, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_FIND_REGEX, SPDF_WIN_MENU_EDIT, L"&Regex", NULL, 0, 0, 1},
    {SPDF_WIN_CMD_FIND_REGEX_MULTILINE, SPDF_WIN_MENU_EDIT, L"Regex Matches Across &Lines", NULL, 0, 0, 1},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_EDIT, NULL, NULL, 0, 0, 0},
    /* The mac's last Edit item (:2096), same title, same place. */
    {SPDF_WIN_CMD_SET_COMMENT_AUTHOR, SPDF_WIN_MENU_EDIT, L"Set A&uthor for Comments...", NULL, 0, 0, 0},

    /* --- Settings ------------------------------------------------------
     *
     * macOS's own Settings menu (ShenzhenPDFMac.mm:2112-2149): four toggles,
     * then the state files, then Reveal Settings Folder, in that order and with
     * those titles. Every row writes settings.yaml through
     * spdf_win_settings_shared() + _commit() and nothing else, which is why
     * they are all live with no document open.
     *
     * KEEP IMAGE COLORS MOVED HERE FROM THE VIEW MENU, where it was the only
     * settings row this port had. It sat next to Dark Reading Theme, which
     * reads well, but macOS has it here and a Settings menu missing one of
     * macOS's four toggles is a menu a reader has to be told about. Dark
     * Reading Theme stays on View: it is the state of THIS window, not a
     * preference for the next document.
     *
     * ONE OF THE FIVE STATE FILES, not five rows. The mac lists settings.yaml,
     * session.yaml, documents.yaml, favorites.yaml and bookmarks.yaml; the last
     * has no Windows counterpart at all (spdf_win_state.h says why) and the
     * middle three are records the app writes, not preferences a reader edits.
     * settings.yaml is the one the mac gives a key to, and it keeps it:
     * Cmd+, -> Ctrl+, which is also where Windows readers look for settings. */
    {SPDF_WIN_CMD_TOGGLE_DEFAULT_SIDEBAR, SPDF_WIN_MENU_SETTINGS, L"Open New Documents with &Side Panel", NULL, 0, 0,
     1},
    {SPDF_WIN_CMD_TOGGLE_DEFAULT_MINIMAP, SPDF_WIN_MENU_SETTINGS, L"Open New Documents with &Map", NULL, 0, 0, 1},
    {SPDF_WIN_CMD_TOGGLE_KEEP_IMAGE_COLORS, SPDF_WIN_MENU_SETTINGS, L"&Keep Image Colors in Dark Theme", NULL, 0, 0, 1},
    {SPDF_WIN_CMD_TOGGLE_SEARCH_NEAREST, SPDF_WIN_MENU_SETTINGS, L"Search Jumps to &Nearest Result", NULL, 0, 0, 1},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_SETTINGS, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_OPEN_SETTINGS_FILE, SPDF_WIN_MENU_SETTINGS, L"&Open settings.yaml...", L"Ctrl+,",
     SPDF_WIN_KEY_OEM_COMMA, SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_NONE, SPDF_WIN_MENU_SETTINGS, NULL, NULL, 0, 0, 0},
    {SPDF_WIN_CMD_REVEAL_SETTINGS_FOLDER, SPDF_WIN_MENU_SETTINGS, L"&Reveal Settings Folder", NULL, 0, 0, 0},

    /* --- accelerator-only rows ----------------------------------------
     *
     * The keypad and the shifted-'=' spellings of zoom, which GTK4 also carries
     * as extra accels on the same actions (spdf_shortcuts.c win.zoom-in has
     * three). They fire but are not drawn: a menu that lists "Zoom In" twice
     * reads as a bug. */
    {SPDF_WIN_CMD_ZOOM_IN, SPDF_WIN_MENU_NONE, NULL, NULL, SPDF_WIN_KEY_ADD, SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_ZOOM_OUT, SPDF_WIN_MENU_NONE, NULL, NULL, SPDF_WIN_KEY_SUBTRACT, SPDF_WIN_ACCEL_CTRL, 0},
    /* Ctrl+Tab and Ctrl+Shift+Tab, which this port already had before there was
     * a menu and which readers coming from a browser reach for first. The menu
     * PRINTS Ctrl+PageUp / Ctrl+PageDown, following GTK4; both work. */
    {SPDF_WIN_CMD_NEXT_TAB, SPDF_WIN_MENU_NONE, NULL, NULL, SPDF_WIN_KEY_TAB, SPDF_WIN_ACCEL_CTRL, 0},
    {SPDF_WIN_CMD_PREV_TAB, SPDF_WIN_MENU_NONE, NULL, NULL, SPDF_WIN_KEY_TAB,
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    /* Ctrl+Shift+= IS Ctrl++ on a US layout: the '+' glyph is the shifted '=',
     * and WM_KEYDOWN reports the unshifted VK either way. Without this row the
     * accelerator the menu PRINTS is the one that does not work. */
    {SPDF_WIN_CMD_ZOOM_IN, SPDF_WIN_MENU_NONE, NULL, NULL, SPDF_WIN_KEY_OEM_PLUS,
     SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    /* Shift+Ctrl+F is the mac's other Presentation key (ShenzhenPDFMac.mm:13432
     * "F5 / Shift+Cmd+F"); the menu prints F5. */
    {SPDF_WIN_CMD_PRESENTATION, SPDF_WIN_MENU_NONE, NULL, NULL, 'F', SPDF_WIN_ACCEL_CTRL | SPDF_WIN_ACCEL_SHIFT, 0},
    /* Backspace deletes the comment under the pointer as Delete does; the menu
     * prints Del. Both are bare keys: the handler hands them to the focused
     * field first (spdf_win_cmd_annot.h), so typing is untouched. */
    {SPDF_WIN_CMD_DELETE_COMMENT, SPDF_WIN_MENU_NONE, NULL, NULL, SPDF_WIN_KEY_BACK, 0, 0}
};
