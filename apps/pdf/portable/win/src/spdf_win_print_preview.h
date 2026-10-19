/* spdf_win_print_preview.h — THE PRINT DIALOG'S PREVIEW: the sheet the driver
 * says it will feed, the border it cannot print on, and the page where the job
 * will actually put it. The arithmetic is spdf_win_print_preview_geom.h, which
 * is pure and tested with no window (portable/win/tests/print_preview_test.c);
 * this is the child window, the render and the page stepper.
 *
 * WHY IT EXISTS. Windows' own print dialog is what a reader here would normally
 * see and it has a preview; PrintDlgExW does not return on this host, so what a
 * reader actually sees is spdf_win_print_dialog.cpp (the measurement and the
 * whole argument are portable/docs/windows-print-dialog.md). A print dialog
 * with Fit / Actual Size / Custom % and no preview asks the reader to imagine
 * the answer. This is the answer.
 *
 * WHAT IT DRAWS, AND WHERE EVERY NUMBER COMES FROM:
 *
 *   the sheet     PHYSICALWIDTH / PHYSICALHEIGHT of a printer DC created from
 *                 the chosen printer AND the reader's DEVMODE, so dmPaperSize
 *                 and dmOrientation are already in it. A driver that reports no
 *                 full sheet falls back to the DEVMODE's own dmPaperWidth /
 *                 dmPaperLength (tenths of a mm, swapped for landscape).
 *   the border     PHYSICALOFFSETX / PHYSICALOFFSETY against HORZRES / VERTRES,
 *                 drawn as a hatched inset with the widest edge stated in
 *                 millimetres. It is SHOWN, not silently applied: a reader
 *                 should be able to see that a driver cannot print to the edge.
 *                 When the sheet had to be inferred the caveat line says the
 *                 border is an assumption.
 *   the page       spdf_win_print_dest_rect(), THE JOB'S OWN placement, scaled
 *                 down. Never a second implementation of it — see the geometry
 *                 header, and the test that pins it.
 *
 * IT NEVER BLOCKS, AND BOTH HALVES OF THAT HAD TO BE ARRANGED. The page bitmap
 * comes from the render service in spdf_win_render.h — its own worker, its own
 * document handle per the core's one-document-per-thread rule — keyed by (page,
 * preview zoom) in a small ring cache. Until a bitmap lands the sheet is drawn
 * empty with "Rendering…" under it. The SHEET is asked for on a worker too:
 * CreateICW on this machine's network printer takes 47 seconds and then fails,
 * and calling it from the printer combo's notification handler froze the whole
 * dialog for that long. Both answers arrive as PostMessages the window
 * procedure handles; nothing on the UI thread waits for MuPDF or for a driver.
 * See spdf_win_print_preview_sheet.cpp.
 *
 * ITS COLOURS ARE THE DOCUMENT'S. The render flags are
 * spdf_win_export_render_flags() and nothing else — the same rule print, Save
 * as PDF and Copy Page follow (spdf_win_export.h, pinned by
 * portable/win/tests/light_theme_test.c). A preview of a print must not carry
 * the dark reading theme any more than the print may. The window's own chrome
 * does follow the app theme, because it is part of the dialog.
 *
 * THE PAGE STEPPER walks the pages the current range covers, expanded by
 * spdf_win_print_expand_ranges() — the same expansion the job uses, so the
 * preview cannot show a page the job would not print. A one-page range has no
 * stepper at all rather than a pair of dead arrows.
 */
#ifndef SPDF_WIN_PRINT_PREVIEW_H
#define SPDF_WIN_PRINT_PREVIEW_H

#include <windows.h>

#include "shenzhen_pdf_core.h"
#include "spdf_win_print_dialog.h" /* the control ids, and the printer list */
#include "spdf_win_print_preview_geom.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Posted to the preview window by the render service's notify hook, from a
 * worker thread, when a bitmap is ready to be drained. Public because the
 * dialog's modal loop must not swallow it. */
#define SPDF_WIN_PREVIEW_WM_READY (WM_APP + 71)

typedef struct spdf_win_print_preview spdf_win_print_preview;

/* Create the preview as a child of `parent` at (x, y, w, h) DEVICE pixels.
 *
 * `doc` is the caller's own document handle and is used ONLY on the calling
 * thread, only for spdf_page_size(): the core allows one spdf_document per
 * thread, and the dialog runs on the thread that already owns this one.
 * `doc_path_utf8` is what the render workers open for themselves; NULL (or an
 * unreadable path) means no bitmap will ever arrive and the preview shows the
 * sheet and the placement alone, which is still an honest preview of the paper.
 * `dpi` is the dialog's, from GetDpiForWindow, so the stepper scales with it.
 * `printers` is the dialog's own list and must outlive the preview — it is
 * borrowed, not copied, because the preview is a child of the window that holds
 * it and cannot outlive that. `current_page` is 0-based, or negative when the
 * caller does not know it, and is what the "Current page" range means.
 *
 * Returns NULL when the child window could not be created; the dialog then
 * simply has no preview and everything else about it still works. */
spdf_win_print_preview* spdf_win_print_preview_create(HWND parent, int dark, int dpi, spdf_document* doc,
                                                      const char* doc_path_utf8,
                                                      const spdf_win_print_printers* printers, int page_count,
                                                      int current_page, int x, int y, int w, int h);

/* Cancels every render in flight, drains the callbacks and frees the cache.
 * Safe with NULL. */
void spdf_win_print_preview_destroy(spdf_win_print_preview* pv);

/* RE-READ EVERYTHING AND REPAINT. `dialog` is the print dialog window, whose
 * controls (SPDF_WIN_PD_ID_*, spdf_win_print_dialog.h) hold the printer, the
 * range and the scale; `devmode` is the one the reader edited in Properties, or
 * NULL for the driver's defaults. The printer DC is only re-created when the
 * printer or the DEVMODE actually changed, because opening one costs a driver
 * round trip and a scaling radio does not need a new sheet.
 *
 * Call it after any change a reader can make: the printer combo, the Properties
 * sheet, a range radio or field, a scaling radio, the percentage. */
void spdf_win_print_preview_sync(spdf_win_print_preview* pv, HWND dialog, const DEVMODEW* devmode);

/* The 0-based document page the preview is showing, or -1 when it has none.
 * For the test, and for a caller that wants to say which page that is. */
int spdf_win_print_preview_page(const spdf_win_print_preview* pv);

/* The sheet as last measured, for the test and for a caller that wants to name
 * the paper. Returns 0 when nothing has been measured yet. */
int spdf_win_print_preview_sheet(const spdf_win_print_preview* pv, spdf_win_preview_sheet* out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_PRINT_PREVIEW_H */
