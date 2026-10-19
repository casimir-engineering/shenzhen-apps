/* spdf_win_md_reload.h -- re-read a Markdown document OFF the UI thread after
 * its file changed on disk, and hand the finished document back.
 *
 * WHAT THIS IS THE PORT OF. macOS 26.9.4-1 (7c609c997, e6f900f7f, 301348473,
 * b44018932): a Markdown document reloads when its file changes, IN PLACE --
 * rendered in the background, swapped in complete, the reader's place kept,
 * nothing blanked. The Windows watcher (spdf_win_watch_app.h) used the PDF route
 * for every file: destroy the canvas, release the tab's document, re-show the
 * tab. For a PDF that is right -- a document handle genuinely has to be
 * reopened -- and for a Markdown file it means md4c, the HTML conversion and
 * MuPDF's whole layout run on the UI thread inside the watcher's callback, with
 * every derived store (thumbnails, search, panels) rebuilt from nothing. The
 * mac's fix is the shape adopted here: the re-read is a RERENDER whose source is
 * the file, done where a render belongs, and the canvas keeps drawing the last
 * good document until the new one is ready to swap under the viewport
 * (spdf_win_canvas_replace_document).
 *
 * THE MECHANISM. begin() starts one thread that runs spdf_win_md_open_any() --
 * the same opener every worker uses, so the module's text scale, orientation and
 * language overrides apply exactly as they would to a tab switch -- and parks
 * the result here. It then posts `message` to `notify`; the window turns any
 * WM_APP message into SPDF_WIN_INPUT_APP_MESSAGE, and the handler
 * (spdf_win_md_command_reloaded) calls take(). A document is a single MuPDF
 * context and is used by ONE thread at a time; opened on the worker and handed
 * over untouched, it is the UI thread's from take() onwards, which is the same
 * contract the tab model's own open honours.
 *
 * SUPERSESSION, the way the mac's _renderGeneration works: a begin() while a
 * read is in flight makes that read's result stale -- when it lands it is
 * closed, not parked -- so a file saved three times in a second yields one swap,
 * of the last contents. A read that FAILS (deleted, or caught mid-write by an
 * editor that truncates first) parks nothing: take() returns NULL and the
 * reader keeps the last good document, which the mac's Reload category states
 * as the rule; a file that is really gone is still the watcher's MISSING case.
 *
 * Process-wide, like the rest of spdf_win_md.h, because there is one window per
 * process. take() is UI-thread; begin() is UI-thread; the parking is locked.
 * Pinned by portable/win/tests/md_reload_test.c with no window: the result can
 * be polled with take() as well as announced, which is what makes the thread
 * testable.
 */
#ifndef SPDF_WIN_MD_RELOAD_H
#define SPDF_WIN_MD_RELOAD_H

#include "shenzhen_pdf_core.h"

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

/* WM_APP + 0x0D45: "the re-read of the Markdown file is ready". Beside
 * SPDF_WIN_MD_WM_IMAGES_ARRIVED (0x0D45's neighbour) in spdf_win_md_commands.h,
 * and renumbered with it: the old 0x4D45 was 0xCD45, above the WM_APP..0xBFFF
 * range the window forwards, so a Markdown file that changed on disk was
 * re-read off-thread and the result never reached the window. */
#define SPDF_WIN_MD_WM_RELOADED (WM_APP + 0x0D45)

/* Start a background re-read of `utf8_path` with the module's current options.
 * Any read already in flight is superseded (its result is discarded when it
 * lands) and any parked result not yet taken is dropped. `notify` may be NULL,
 * in which case nothing is posted and the caller polls take(). Returns 1 when
 * the thread was started, 0 on a NULL/empty path or when the thread could not
 * be created. */
int spdf_win_md_reload_begin(const char* utf8_path, HWND notify, UINT message);

/* The finished document from the most recent begin(), or NULL when none has
 * landed yet, the read failed, or it was superseded. Ownership passes to the
 * caller (spdf_close, or hand it to spdf_win_canvas_replace_document, which
 * then owns it). `path_out` receives the path it was read from; may be NULL. */
spdf_document* spdf_win_md_reload_take(char* path_out, size_t path_cap);

/* 1 while a re-read is running. For the app's shutdown and for tests. */
int spdf_win_md_reload_in_flight(void);

/* Wait for the running re-read, if any, and drop its result. Idempotent. */
void spdf_win_md_reload_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_MD_RELOAD_H */
