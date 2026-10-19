#pragma once

/* COMMAND HANDLERS: comments -- highlight the selection, add a note, edit,
 * delete, set the author -- and Properties with the real comment count.
 *
 * Header-only, included from spdf_win_chrome_commands.h only, after the app
 * struct, the chrome model, the input types and spdf_win_chrome_actions.h
 * (whose spdf_win_chrome_annot_ui.h holds the flows these call) are complete.
 * Owned by the annotations track (portable/docs/windows-feature-matrix.md
 * gap 11); none of the other tracks' handlers edits command_perform().
 *
 * Return 1 when the command was consumed, 0 to let it fall through.
 *
 * WHAT EACH ONE DOES, with its original:
 *
 *   HIGHLIGHT_SELECTION  a highlight annotation over the selected text with
 *                        the typed comment, prefilled with the selection (GTK
 *                        action_add_highlight; mac addComment: with a
 *                        selection). Nothing selected: nothing happens.
 *   ADD_COMMENT          the same with a selection; without one, a note at
 *                        the last clicked point on the page (GTK
 *                        action_add_comment, mac addComment: at
 *                        _contextPagePoint).
 *   EDIT_COMMENT         the comment under the pointer, else the one under
 *                        the last click (mac commentIndexForEditAction:).
 *   DELETE_COMMENT       the same target, after the mac's confirmation. Its
 *                        keys are Delete and Backspace, BARE, and a bare key
 *                        also belongs to a focused field: when one has the
 *                        keyboard the keystroke is handed to the field's own
 *                        editing (chrome_field_key) and no comment is touched,
 *                        which is exactly what key_for_window's step 2 would
 *                        have done had the accelerator not matched first.
 *   SET_COMMENT_AUTHOR   settings.yaml commentAuthor (mac setCommentAuthor:).
 *   PROPERTIES           claimed here so the Statistics group shows the REAL
 *                        comment count (and loads the chapter count itself,
 *                        -1) where the fallback switch passed two zeros; the
 *                        case that remains there is now unreachable.
 */

static int spdf_win_cmd_annot_perform(app* a, int command, const spdf_win_input* in) {
    switch (command) {
        case SPDF_WIN_CMD_HIGHLIGHT_SELECTION: return annot_add(a, 1);
        case SPDF_WIN_CMD_ADD_COMMENT: return annot_add(a, 0);
        case SPDF_WIN_CMD_EDIT_COMMENT: return annot_edit(a, annot_target_comment());
        case SPDF_WIN_CMD_DELETE_COMMENT:
            if (a->focus != SPDF_WIN_FOCUS_NONE && in && in->kind == SPDF_WIN_INPUT_KEY) return chrome_field_key(a, in);
            return annot_delete(a, annot_target_comment());
        case SPDF_WIN_CMD_SET_COMMENT_AUTHOR: return annot_set_author(a);
        case SPDF_WIN_CMD_PROPERTIES: {
            SpdfWinDocAction act;
            char utf8_path[1024] = {0};
            if (!doc_action_for(a, &act)) return 0;
            WideCharToMultiByte(CP_UTF8, 0, act.path, -1, utf8_path, (int)sizeof(utf8_path), NULL, NULL);
            spdf_win_properties_show_for_document(act.hwnd, act.doc, act.path, act.page, -1,
                                                  spdf_win_annot_count(act.doc, utf8_path));
            return 0; /* nothing on screen changed */
        }
        default: return 0;
    }
}
