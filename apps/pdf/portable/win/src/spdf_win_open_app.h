#pragma once

/* spdf_win_open_app.h -- THE PROCESS OPENER the frontend installs into
 * spdf_win_open.h's seam. Two rules, in this order: open a read-only source's
 * WORKING COPY when one exists, and open a Markdown path as pages.
 *
 * WHY THE SECOND RULE NEEDED THE FIRST. spdf_win_open.h exists so that the
 * seven translation units that open documents by path -- the render pool, the
 * search worker, the thumbnail store, the outline bridge, the link scanner, the
 * print job, the headless paths -- need one identifier and no new
 * dependencies; spdf_win_render.c alone is linked by three tests, one of them
 * under ThreadSanitizer. The Markdown rule went in as the hook for exactly that
 * reason.
 *
 * The read-only rule has the same shape and was missing, with a visible
 * consequence. When a source cannot be written the tab opens a silent shadow
 * copy instead (spdf_win_watcher.h) and the CANVAS and its render workers are
 * handed that copy's path (spdf_win_tabs_open_render_path). Nothing handed it
 * to the workers that get their path from somewhere else -- so a search ran
 * over the SOURCE while the page on screen came from the copy. Identical bytes
 * most of the time and quietly wrong the moment they differ, which is the one
 * situation the copy exists for: the source is being rewritten under the app,
 * and a hit reported at page 40 of the new file is drawn onto page 40 of the
 * old one.
 *
 * ONE PLACE, NOT SEVEN. Putting it in the hook rather than at each open site
 * means a site added later cannot forget it, and means spdf_win_open.c stays
 * what it says it is: the seam, with no watcher and no Markdown in it.
 *
 * NOT resolve_open(), WHICH WOULD BE WRONG HERE. That function creates the copy
 * and consumes the session-restore binding, on a UI thread with no lock; the
 * hook is called from every worker in the process. spdf_win_watcher.h's note on
 * spdf_win_watcher_existing_working_path() has the full argument. This looks a
 * copy up and never makes one, so a path with no copy opens exactly what it
 * opened before -- including on the headless render paths, which must not start
 * writing into %APPDATA% to draw a PNG.
 *
 * NO RECURSION. A shadow copy hashes to a different name than itself and lives
 * in a writable directory, so asking about one answers no. The tab model's own
 * open therefore resolves once (in spdf_win_tabs_open.h, which needs the
 * creating form) and hands this the copy, which this leaves alone.
 *
 * Header-only, included by spdf_win_main.cpp only, before main().
 */

#include "spdf_win_md.h"      /* spdf_win_md_open_any: a .md path opens as pages */
#include "spdf_win_open.h"    /* ... and the seam both rules are installed into */
#include "spdf_win_watcher.h" /* spdf_win_watcher_existing_working_path */

static spdf_document* spdf_win_open_app_document(const char* utf8_path, char* err, size_t err_len) {
    char working[SPDF_WIN_WATCHER_PATH_MAX];
    if (utf8_path && spdf_win_watcher_existing_working_path(utf8_path, working, sizeof(working)))
        return spdf_win_md_open_any(working, err, err_len);
    return spdf_win_md_open_any(utf8_path, err, err_len);
}
