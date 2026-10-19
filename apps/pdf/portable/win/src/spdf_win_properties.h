/* spdf_win_properties.h — the document-properties dialog (Ctrl+I): the model,
 * the "Copy All" transcript and the window that shows them.
 *
 * A PORT, ROW FOR ROW, of SPDFMacPropertiesPanel.mm and its Linux counterpart
 * portable/linux/gtk4/spdf_props.c: the same four groups in the same order
 * (Document, Dates, File, Statistics), the same rows, the same omissions
 * (a metadata row with an empty value is not shown) and the same transcript
 * format ("Section\n  Label: Value"). The VALUE FORMATTING is
 * spdf_win_props_format.h, which is a transcription of the shared helper both
 * of those use and is compared against it exactly by
 * portable/win/tests/props_differential.c.
 *
 * THE MODEL IS SEPARATE FROM THE WINDOW, and that is the whole reason this
 * file is shaped the way it is. spdf_win_properties_collect() takes a document
 * and produces an array of (section, label, value) strings with no HWND, no
 * COM and no message loop; the dialog in spdf_win_properties_dialog.cpp then
 * draws that array. On a LOCKED WORKSTATION no dialog can be shown at all, so
 * everything worth checking — which rows appear, what they say, what the
 * transcript looks like — is reachable by properties_test.c without one.
 *
 * WHAT THE CORE DOES NOT EXPOSE, said plainly rather than worked around:
 *
 *   - FONTS. The macOS panel has no font list either; nothing in
 *     shenzhen_pdf_core.h enumerates fonts, and adding a second metadata
 *     reader beside spdf_lookup_metadata to get one would be exactly the
 *     duplication this port is meant to avoid. Absent on all three platforms.
 *   - WORD COUNT. macOS shows a "Text" row filled in asynchronously by walking
 *     every page on a worker with its own document handle
 *     (SPDFMacPropertiesPanel.mm startWordCountForPath:). GTK deliberately
 *     omits it and says so in spdf_props.c's own comment. So does this: the
 *     walk costs one full text extraction of the whole document, which is
 *     precisely the kind of work the port's speed rule forbids doing because a
 *     panel happened to open. spdf_win_page_text_utf8() is there if the shell
 *     ever wants it on a worker.
 *   - PAGE COUNT PER SIZE. Like both originals, the panel reports the CURRENT
 *     page's size, not a survey of every page. outline.pdf's page 2 is a
 *     1224 pt foldout, so "the document's page size" is not a well-defined
 *     thing to report.
 *
 * NOTHING RUNS UNTIL THE DIALOG IS ASKED FOR. Collecting reads metadata,
 * one page size and (only when the caller passes -1) the outline and comment
 * counts. No page is rendered, no text is extracted, and none of it happens at
 * launch or at open — properties_test.c pins the render count at zero by
 * checking spdf_last_render_stats() is untouched across a collect.
 */
#ifndef SPDF_WIN_PROPERTIES_H
#define SPDF_WIN_PROPERTIES_H

#include <windows.h>

#include "shenzhen_pdf_core.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_WIN_PROPS_MAX_ROWS 40
#define SPDF_WIN_PROPS_SECTION_MAX 32
#define SPDF_WIN_PROPS_LABEL_MAX 40
#define SPDF_WIN_PROPS_VALUE_MAX 1024

/* One row. `section` repeats on every row of a group rather than nesting the
 * model, because the dialog draws a flat list and a two-level structure would
 * be shape for its own sake. All three fields are UTF-8. */
typedef struct spdf_win_props_row {
    char section[SPDF_WIN_PROPS_SECTION_MAX];
    char label[SPDF_WIN_PROPS_LABEL_MAX];
    char value[SPDF_WIN_PROPS_VALUE_MAX];
} spdf_win_props_row;

typedef struct spdf_win_properties {
    spdf_win_props_row rows[SPDF_WIN_PROPS_MAX_ROWS];
    int count;
} spdf_win_properties;

/* Build the model. `path` names the file on disk (for Location, Size and the
 * on-disk dates) and may be NULL. `page_index` selects which page's size is
 * reported. `outline_count` and `comment_count` are the caller's cached
 * counts — pass -1 for either to have this load it from the document, which is
 * what a caller with no sidebar open does.
 *
 * Returns the number of rows written, or 0 for a NULL document. */
int spdf_win_properties_collect(spdf_document* doc, const wchar_t* path, int page_index, int outline_count,
                                int comment_count, spdf_win_properties* out);

/* The "Copy All" transcript: "Section\n  Label: Value\n", groups separated by a
 * blank line — byte for byte the format macOS copies and GTK copies, so a
 * properties dump pasted into a bug report reads the same whichever app
 * produced it. Returns the number of bytes written excluding the NUL, or 0. */
int spdf_win_properties_transcript(const spdf_win_properties* props, char* out, size_t out_len);

/* Show the dialog. Returns 1 when it was shown and dismissed, 0 when it could
 * not be created — which is what happens on a locked workstation, and is
 * reported rather than swallowed. */
int spdf_win_properties_show(HWND parent, const spdf_win_properties* props);

/* Collect and show in one call, the shape a menu item wants. */
int spdf_win_properties_show_for_document(HWND parent, spdf_document* doc, const wchar_t* path, int page_index,
                                          int outline_count, int comment_count);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_PROPERTIES_H */
