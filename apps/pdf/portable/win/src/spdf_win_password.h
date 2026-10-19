/* spdf_win_password.h — opening a document that may be password-protected:
 * prompt, retry, cancel, and no persistence of any kind.
 *
 * WHAT THIS IS THE PORT OF. GTK4's spdf_password_prompt.c (the dialog),
 * spdf_password_controller.c (the attempt loop) and spdf_password_lifecycle.c
 * (the pure flow, carried here as spdf_win_password_flow.h), and the mac's
 * SPDFPasswordSheetController. The shape is the same on all three: open with no
 * password; if the core says a password is required, ask; if the core says the
 * password was wrong, ask again saying so; stop when the reader cancels; hand
 * back the open document.
 *
 * SYNCHRONOUS ON PURPOSE. GTK's controller runs each attempt on a worker
 * thread because the GTK main loop must not block. This port's open path is
 * already synchronous (spdf_win_tabs materialises a document on the UI thread
 * when a tab is first shown), so an asynchronous controller here would put the
 * password prompt on a different footing from the open it wraps. The prompt is
 * a modal dialog and the attempts happen between its appearances.
 *
 * THE PASSWORD NEVER LEAVES THIS MODULE'S STACK. It lives in one UTF-16 buffer
 * for the duration of an attempt, is narrowed to UTF-8 for the core in another
 * stack buffer, and both are SecureZeroMemory'd before the function returns --
 * on every path, including the error ones. Nothing here writes to a log, a
 * setting or the session file, and the API below has no way to ask for the
 * password back; the document, once authenticated, is the only artefact.
 * (The core remembers nothing either: spdf_open_with_password takes the
 * password by pointer for the duration of the call.)
 *
 * WHAT IS NOT HERE, and why. GTK and the mac keep a per-source credential so a
 * WATCHER RELOAD of a protected document can reopen it without asking again.
 * That would mean holding the password in process memory for the tab's
 * lifetime; the brief asks for process-memory-only, which this satisfies, and a
 * reload of a protected document simply prompts again -- through this same
 * function -- which is correct and merely less convenient. The place to add a
 * credential cache later is behind this API, not in front of it.
 */
#ifndef SPDF_WIN_PASSWORD_H
#define SPDF_WIN_PASSWORD_H

#include "shenzhen_pdf_core.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Open `utf8_path`, prompting for a password on `hwnd_owner` (an HWND, or NULL
 * for none) as often as the core asks. Returns 1 with *out set to the open
 * document, 0 when the reader cancelled (nothing to report; *out is NULL), -1
 * on an error with `err` filled (a file that is not a document, a prompt that
 * could not be shown on a locked workstation, ...). */
int spdf_win_open_document_interactive(void* hwnd_owner, const char* utf8_path, spdf_document** out, char* err,
                                       size_t err_len);

/* The number of prompts the last call showed. For a test that cannot show a
 * dialog to assert that a plain document showed none, and for nothing else. */
int spdf_win_password_last_prompt_count(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PASSWORD_H */
