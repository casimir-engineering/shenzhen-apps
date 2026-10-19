/* spdf_win_export.h — leaving the app: Save As, Save Page As, the file names
 * those two propose, and THE ONE RULE every path that produces a file or a
 * clipboard payload obeys.
 *
 * ===========================================================================
 * THE LIGHT-THEME RULE
 * ===========================================================================
 * Print, Save as PDF, Save Page as PDF, Copy Page and Copy Page Image ALWAYS
 * render the LIGHT theme, even while the reader is looking at a dark page.
 *
 * portable/docs/windows-port-handoff.md section 4, settled:
 *
 *     SPDF_RENDER_DARK_THEME is opt-in per render precisely so these get the
 *     document's own colours by doing nothing. A file that left the app with
 *     our dark paper baked in would be wrong everywhere it lands.
 *
 * The core says the same at shenzhen_pdf_core.h:161-168 and spdf_recolor.h
 * closes with "It is a SCREEN transform only: print and export never opt in."
 * macOS says it in SPDFMacReadingThemeIntegration.mm:22 and enforces it by
 * re-rendering a cached dark page before Copy Page Image
 * (SPDFMacMarkdownFileActions.mm:110-130).
 *
 * "Do nothing" is the correct implementation and is also the one that rots:
 * a future reader threading `a->render_flags` into a print or export call
 * would produce code that looks MORE consistent than the code that is right.
 * So the rule is given a NAME here rather than being an absence, every export
 * path calls it, and portable/win/tests/light_theme_test.c fails if it ever
 * returns anything but SPDF_RENDER_DEFAULT — checked twice, once on the flag
 * word and once on the actual PIXELS of a page rendered through it, so a
 * change that routed around the function is caught as well as one that
 * changed it.
 *
 * There is deliberately no parameter. A function that COULD be asked for the
 * reading theme is a function someone will eventually ask.
 *
 * ===========================================================================
 * NATIVE SAVE PANELS, settled in the same section: "Picking a file has to hand
 * the selection back to the app; no external file manager can." So this uses
 * IFileSaveDialog, the modern shell dialog, and nothing else.
 *
 * WHAT IS PURE AND WHAT IS NOT. Everything above the "dialogs" divider takes
 * strings and returns strings: no COM, no document, no window, no disk. That
 * is what lets portable/win/tests/page_export_test.c drive the whole naming
 * and extension policy on a LOCKED WORKSTATION, where IFileSaveDialog cannot
 * be shown at all. The dialog functions below it are a thin shell around
 * those, so the untestable part is as small as it can be made.
 */
#ifndef SPDF_WIN_EXPORT_H
#define SPDF_WIN_EXPORT_H

#include <windows.h>

#include "shenzhen_pdf_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* --- 1. the light-theme rule --------------------------------------------- */

/* The render flags every file-producing and clipboard-producing path passes.
 * Always SPDF_RENDER_DEFAULT. See this file's header. */
unsigned spdf_win_export_render_flags(void);

/* --- 2. pure naming ------------------------------------------------------- */

/* The file name inside a path: the character after the last '\\', '/' or ':',
 * or the whole string when there is none. Returns a pointer INTO `path`, never
 * NULL for a non-NULL argument. */
const wchar_t* spdf_win_export_file_name(const wchar_t* path);

/* The file name with its extension removed ("golden.pdf" -> "golden"), into
 * `out`. A leading dot is not an extension (".profile" stays ".profile"), which
 * is the same rule g_path_get_basename + strrchr gives the GTK original and
 * -stringByDeletingPathExtension gives the Mac one. Returns 1 on success. */
int spdf_win_export_file_stem(const wchar_t* path, wchar_t* out, int out_cap);

/* "<stem> - page N.pdf", N being page_index + 1 — byte for byte the name macOS
 * writes (SPDFMacMarkdownFileActions.mm:161) and GTK writes
 * (spdf_annot_single_page_filename), so the same page copied on three machines
 * arrives with the same name. An empty or extension-only source falls back to
 * the stem "Page", exactly as both originals do. Returns 1 on success. */
int spdf_win_export_page_file_name(const wchar_t* doc_path, int page_index, wchar_t* out, int out_cap);

/* Append ".pdf" unless the path already ends in one, case-insensitively — the
 * port of spdf_annot_filename_with_pdf_extension. A save dialog can return a
 * name the user typed without an extension, and writing "report" instead of
 * "report.pdf" produces a file Windows will not open. Returns 1 on success, 0
 * when the result would not fit (in which case `out` is left empty). */
int spdf_win_export_with_pdf_extension(const wchar_t* path, wchar_t* out, int out_cap);

/* 1 when the path already ends in ".pdf", case-insensitively. */
int spdf_win_export_has_pdf_extension(const wchar_t* path);

/* --- 3. dialogs and the writes they drive --------------------------------- */

/* Run IFileSaveDialog with a single "PDF Document (*.pdf)" filter and
 * `default_name` pre-filled, and write the chosen path (already run through
 * spdf_win_export_with_pdf_extension) into `out`.
 *
 * Returns 1 when the user chose a path, 0 when they cancelled, and -1 when the
 * dialog could not be shown at all — which is NOT the same thing and must not
 * be reported to the user as a cancellation. On a locked workstation this is
 * the -1 case; `hr_out`, when non-NULL, receives the HRESULT so a caller (and
 * a test) can say WHY rather than guessing. */
int spdf_win_export_choose_save_path(HWND parent, const wchar_t* title, const wchar_t* default_name, wchar_t* out,
                                     int out_cap, HRESULT* hr_out);

/* Save the whole document to a user-chosen path (spdf_save_document).
 * `doc_path` supplies the proposed file name only. Returns 1 on success, 0 on
 * cancellation or failure; `err` receives the core's message when the write
 * itself failed and is left empty on a cancellation.
 *
 * `out_saved_utf8` (may be NULL, and is left empty unless the write SUCCEEDED)
 * receives the path actually written, UTF-8. The caller needs it for one
 * reason: the reader may have chosen the document's OWN path, and the file
 * watcher has to be told the app made that write or it reports it as an
 * external change and reloads the tab underneath them
 * (spdf_win_watcher_note_self_save). Returning "where did it go" is the
 * dialog's answer to give -- the caller cannot re-derive it, since only the
 * dialog knows what the reader typed. */
int spdf_win_export_save_document_as(HWND parent, spdf_document* doc, const wchar_t* doc_path, char* err,
                                     size_t err_len, char* out_saved_utf8, size_t out_saved_cap);

/* Save ONE page as a standalone PDF (spdf_save_single_page_pdf). Same return
 * contract, and the same `out_saved_utf8`: a one-page save can land on the
 * open document's own path too (a one-page document, or a reader who meant
 * Save As). */
int spdf_win_export_save_page_as(HWND parent, spdf_document* doc, const wchar_t* doc_path, int page_index, char* err,
                                 size_t err_len, char* out_saved_utf8, size_t out_saved_cap);

/* --- 4. the copy scratch directory ---------------------------------------- */

/* %TEMP%\ShenzhenPDF-copy, created if missing, into `out`. The same location
 * macOS uses (NSTemporaryDirectory()/ShenzhenPDF-copy) and GTK uses
 * (g_get_tmp_dir()/ShenzhenPDF-copy) for the single-page PDF that Copy Page
 * puts on the clipboard. Returns 1 on success.
 *
 * NOTHING IS CREATED UNTIL A COPY HAPPENS. This is called from the Copy Page
 * action and from nowhere else — not at launch, not on open — so a reader who
 * never copies a page never pays a directory creation, and the launch path is
 * untouched. page_export_test.c pins that by checking the directory does not
 * exist until the first call. */
int spdf_win_export_copy_scratch_dir(wchar_t* out, int out_cap);

/* --- 5. UTF-8 for the core ------------------------------------------------ */

/* Wide path -> the UTF-8 the core and MuPDF expect. MuPDF opens every path
 * through fz_fopen_utf8 on Windows (mupdf/source/fitz/output.c:291) and the
 * core through spdf_compat_fopen, which widens with CP_UTF8 — so UTF-8 is the
 * correct encoding here and CP_ACP would silently fail on a path containing a
 * character the machine's code page cannot represent. Returns the number of
 * bytes written including the NUL, or 0. */
int spdf_win_export_utf8_path(const wchar_t* path, char* out, int out_len);

/* 1 when `doc_path` names a Markdown file (spdf_path_is_markdown on its UTF-8
 * form). Save As, Save Page As and Copy Page write such a document through
 * spdf_export_pdf rather than the byte-preserving PDF saves. */
int spdf_win_export_source_is_markdown(const wchar_t* doc_path);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_EXPORT_H */
