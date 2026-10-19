/* spdf_win_annot_dialog.h — the three prompts the comment commands need: the
 * editor (author + text), the author-only prompt behind "Set Author for
 * Comments...", and the delete confirmation.
 *
 * THE SAME SHAPE AS THE PROPERTIES AND ABOUT BOXES, for the same reasons those
 * give (spdf_win_properties_dialog.cpp, spdf_win_about.cpp): no resource
 * script and no dialog template, because build-native.cmd discovers .c/.cpp
 * and nothing else; a plain window with child controls and a local modal loop
 * that disables exactly one parent; the caption dark when the reading theme is
 * (spdf_win_about_dark_caption, DWMWA_USE_IMMERSIVE_DARK_MODE) so a dark
 * window does not open a white-capped sheet. The labels and controls are
 * macOS's promptForCommentEditorWithTitle: (ShenzhenPDFMac.mm:11762-11810):
 * "Author" over a one-line field, "Comment" over a multi-line one, the button
 * titled by the caller ("Add" / "Save") and Cancel; both values come back
 * trimmed of surrounding whitespace, as the mac trims them.
 *
 * KEYS. Escape cancels. Return in the AUTHOR field or on a button commits, as
 * a dialog's default button does; Return in the COMMENT field is a new line
 * (ES_WANTRETURN, the mac's NSTextView does the same), so Ctrl+Return commits
 * from there. Tab moves between the controls.
 *
 * UNTESTED ON A LOCKED WORKSTATION, said plainly as the other two say it:
 * no window can be created while the lock screen is up, so these return 0
 * then and nothing is written. The pure logic they wrap -- what the comment
 * text becomes, which comment is edited -- is in spdf_win_annot_model.h and
 * pinned without a window.
 */
#ifndef SPDF_WIN_ANNOT_DIALOG_H
#define SPDF_WIN_ANNOT_DIALOG_H

#ifdef __cplusplus
extern "C" {
#endif

/* The editor. `author` and `text` are in/out UTF-16 buffers of the given
 * capacities (units), pre-filled by the caller and overwritten with the
 * trimmed values on OK. Returns 1 on OK, 0 on Cancel or when no window could
 * be created. `parent` is an HWND (or NULL). */
int spdf_win_annot_dialog_edit(void* parent, int dark, const wchar_t* title, const wchar_t* ok_label,
                               wchar_t* author, int author_cap, wchar_t* text, int text_cap);

/* "Set Author for Comments": one field, "New comments will use this author."
 * (:11886-11887). Same return; `author` in/out, trimmed. */
int spdf_win_annot_dialog_author(void* parent, int dark, wchar_t* author, int author_cap);

/* "Delete Comment?" with `detail` (spdf_win_annot_delete_detail's text),
 * Delete as the non-default button. 1 to delete. */
int spdf_win_annot_dialog_confirm_delete(void* parent, int dark, const wchar_t* detail);

/* Strip leading and trailing whitespace in place; returns the new length. */
int spdf_win_annot_dialog_trim(wchar_t* text);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_ANNOT_DIALOG_H */
