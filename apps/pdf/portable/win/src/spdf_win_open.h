/* spdf_win_open.h — the ONE call every by-path open in the Windows frontend goes
 * through, and the hook that decides what it does.
 *
 * WHY A SEAM AND NOT A DIRECT CALL. spdf_win_md.h asks every open site -- the
 * headless path, the render workers, the search worker, the thumbnail strip,
 * the outline bridge, the link worker, the print job -- to call
 * spdf_win_md_open_any() so a Markdown path opens as pages. Those sites live
 * in seven translation units that portable/win/tests links WITHOUT the
 * Markdown module: spdf_win_render.c alone is linked by three tests and keeps
 * a pthread branch so its scheduling can run under ThreadSanitizer, which a
 * dependency on a WinHTTP image cache and the settings directory would end.
 * So the sites call THIS, which is spdf_open() until somebody says otherwise,
 * and spdf_win_main.cpp says otherwise once, first thing:
 *
 *   spdf_win_open_set_hook(spdf_win_md_open_any);
 *
 * One identifier per site, no other change, and a test binary that never
 * installs a hook opens exactly what it opened before. The hook is the
 * process's, like the Markdown options it dispatches to
 * (spdf_win_md.h: "WHY THE OPTIONS ARE PROCESS-WIDE"), and for the same
 * reason: every handle open on a document must agree on how it was opened.
 *
 * NOT for the tab model's own open. That one prompts for a password
 * (spdf_win_password.h) and resolves read-only sources to a shadow copy
 * (spdf_win_watcher.h); it calls this for the Markdown branch and the core's
 * spdf_open_with_password for the rest. Pure C over the core; no Win32.
 */
#ifndef SPDF_WIN_OPEN_H
#define SPDF_WIN_OPEN_H

#include "shenzhen_pdf_core.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The same contract as spdf_open(): NULL with err filled on failure. */
typedef spdf_document* (*spdf_win_open_fn)(const char* utf8_path, char* err, size_t err_len);

/* Open through the hook; spdf_open() when none is installed. Callable from
 * any thread: the hook is set once at launch and read thereafter. */
spdf_document* spdf_win_open_document(const char* utf8_path, char* err, size_t err_len);

/* Install the process's opener. NULL restores spdf_open(). Call before any
 * worker thread exists; the frontend calls it at the top of main(). */
void spdf_win_open_set_hook(spdf_win_open_fn fn);
/* The installed hook, or NULL for the default. For tests. */
spdf_win_open_fn spdf_win_open_hook(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_OPEN_H */
