#pragma once

/* COMMAND HANDLERS: search, match navigation, the results sidebar and the map.
 *
 * Header-only, included from spdf_win_chrome_commands.h only, after the app
 * struct, the chrome model and the input types are complete -- the same
 * arrangement as every other *_commands/*_actions header in this port. Owned
 * by the parity track of that name (portable/docs/windows-feature-matrix.md);
 * the other tracks have their own and none of them edits command_perform().
 *
 * Return 1 when the command was consumed, 0 to let it fall through.
 *
 * WHAT EACH ONE DOES, with its original:
 *
 *   FIND            Ctrl+F with a live selection searches for it at once, the
 *                   query replacing whatever was in the field (Mac focusFind,
 *                   ShenzhenPDFMac.mm:12134; GTK spdf_search_focus). With no
 *                   selection, or the selection already being the query, it
 *                   only gives the field the keyboard, as before.
 *   FIND_NEXT/PREV  step, and CENTRE the match (scrollToPageRect), not its page.
 *   FIND_REGEX_MULTILINE  toggles the process-wide flag; the running search
 *                   reruns on the next paint (toggleFindRegexMultiline :12171).
 *   PASTE_SEARCH    Ctrl+V with no field focused searches for the clipboard
 *                   text, trimmed and whitespace-collapsed (Mac paste: :12151);
 *                   with a field focused it pastes INTO the field, which is
 *                   what the field editor does on macOS.
 *   SELECT_ALL      Ctrl+A selects every glyph on the current page. Neither
 *                   original has a document-level Select All (the Mac menu
 *                   item reaches only text fields), so this is the Windows
 *                   reading of the pre-declared command: the whole visible
 *                   page, through the same gesture a drag across it performs.
 *   ROTATE_CW/CCW   rotate the current page in the document AND SAVE THE FILE,
 *                   as both originals do (rotateCurrentPageByDegrees :14875
 *                   saves; GTK annot_rotate_cont saves or reloads), then tell
 *                   the canvas, the find session and the panels the page
 *                   changed shape. A non-PDF, or a save that fails, is reported
 *                   and nothing on screen changes. EXCEPT MARKDOWN, where the
 *                   command turns the paper landscape and back, remembered per
 *                   file (spdf_win_md_command_rotate, 26.9.2-1 / 26.9.4-3).
 */

static int cmd_search_rotate(app* a, int degrees) {
    SpdfWinDocAction act;
    char err[512] = {0};
    char utf8_path[1024];
    /* A Markdown document has no page to rotate; its sheet turns instead. */
    if (spdf_win_md_selected_tab_is_markdown(a)) return spdf_win_md_command_rotate(a);
    if (!doc_action_for(a, &act)) return 0;
    if (WideCharToMultiByte(CP_UTF8, 0, act.path, -1, utf8_path, (int)sizeof(utf8_path), NULL, NULL) <= 0) return 0;
    if (!spdf_rotate_page(act.doc, act.page, degrees, err, sizeof(err)) ||
        !spdf_save_document(act.doc, utf8_path, err, sizeof(err))) {
        /* The in-memory rotation is undone when the save failed, so the file
         * and the view do not disagree; GTK reopens the document for the same
         * reason. */
        if (!err[0]) _snprintf_s(err, sizeof(err), _TRUNCATE, "Could not rotate page");
        doc_action_report(a, err);
        return 0;
    }
    /* Our own write: the watcher takes the new stat as its baseline rather than
     * reporting it back as a change and reloading the page we just rotated. */
    spdf_win_tabs_open_note_self_save(utf8_path);
    spdf_win_canvas_page_changed(a->canvas, act.page);
    /* The search's rects describe the old orientation; the thumbnails and the
     * outline bridge hold a handle to the old file. Both rebuild on the next
     * paint. */
    spdf_win_find_restart(spdf_win_find_shared());
    spdf_win_chrome_content_set_document(NULL, 0);
    return 1;
}

static int spdf_win_cmd_search_perform(app* a, int command, const spdf_win_input* in) {
    (void)in;
    switch (command) {
        case SPDF_WIN_CMD_FIND: return chrome_find_seed_from_selection(a);
        case SPDF_WIN_CMD_FIND_NEXT: return chrome_find_step(a, 1);
        case SPDF_WIN_CMD_FIND_PREV: return chrome_find_step(a, -1);
        case SPDF_WIN_CMD_FIND_REGEX_MULTILINE:
            spdf_win_find_set_regex_multiline(!spdf_win_find_regex_multiline());
            return 1; /* the next paint's fill_model reruns the search */
        case SPDF_WIN_CMD_PASTE_SEARCH: return chrome_paste_search(a);
        case SPDF_WIN_CMD_SELECT_ALL:
            if (!a->canvas) return 0;
            if (a->focus != SPDF_WIN_FOCUS_NONE) return 0; /* a field's own Select All is not a document one */
            return spdf_win_canvas_select_page(a->canvas, spdf_win_canvas_current_page(a->canvas));
        case SPDF_WIN_CMD_ROTATE_CW: return cmd_search_rotate(a, 90);
        case SPDF_WIN_CMD_ROTATE_CCW: return cmd_search_rotate(a, -90);
        default: return 0;
    }
}
