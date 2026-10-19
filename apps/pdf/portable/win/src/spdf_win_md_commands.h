/* spdf_win_md_commands.h -- what the A-/A+ pill and the image cache do to the
 * window: the Markdown commands, in the shape spdf_win_chrome_commands.h's
 * switch expects.
 *
 * Header-only and included by spdf_win_main.cpp AFTER `struct app` and
 * spdf_win_chrome_actions.h (it calls show_selected_tab and
 * spdf_win_tabs_app_remember) and BEFORE spdf_win_chrome_commands.h, which
 * dispatches to it. Same arrangement as the other chrome_*.h headers beside
 * it; not part of the port's public surface.
 *
 * WHY A TEXT-SIZE CHANGE IS A TAB RE-SHOW. The size is the em MuPDF laid the
 * document out at, so changing it means a new layout, and every handle open on
 * the document -- the canvas, its render workers, the thumbnail strip -- must
 * move to the new one together or their page numbers disagree.
 * show_selected_tab() is exactly that already: it destroys the canvas (and
 * with it the worker threads and their per-thread handles), reopens the tab's
 * document through the tabs hook (spdf_win_md_open_any, which reads the new
 * scale), and builds a fresh canvas that puts the reader back on the page it
 * was on. The reader's page is written back first so the reopened document
 * lands where they were, as a tab switch does. No new machinery, and a PDF tab
 * is untouched: the commands are inert on it.
 *
 * REMOTE IMAGES ARRIVE THE SAME WAY. When the background fetch has filled the
 * cache, its window message re-shows the tab; the converter now finds the
 * files and the placeholders become pictures. spdf_win_md_command_images_arrived
 * is that handler, and spdf_win_md_command_after_open starts the fetch after a
 * Markdown tab is shown -- both one call each from main.cpp.
 */
#ifndef SPDF_WIN_MD_COMMANDS_H
#define SPDF_WIN_MD_COMMANDS_H

#include "spdf_win_chrome_content.h" /* the panels rebuild after a reload */
#include "spdf_win_chrome_find.h"    /* so does the search */
#include "spdf_win_md.h"
#include "spdf_win_md_images.h"
#include "spdf_win_md_reload.h"      /* the off-thread re-read this file installs */

/* WM_APP + 0x0D44: "remote images landed in the cache". Posted by the
 * fetch thread to the main window; main.cpp routes it to
 * spdf_win_md_command_images_arrived.
 *
 * It was WM_APP + 0x4D44 ("MD"), i.e. 0xCD44, which is above the WM_APP..0xBFFF
 * range the window forwards -- so this message was posted and dropped, and the
 * placeholders never became pictures until something else caused a re-show. The
 * same mistake in three places; SPDF_WIN_APP_MSG_OK now catches it at compile
 * time (spdf_win_window.h). */
#define SPDF_WIN_MD_WM_IMAGES_ARRIVED (WM_APP + 0x0D44)
SPDF_WIN_APP_MSG_OK(spdf_win_md_images_arrived_is_routable, SPDF_WIN_MD_WM_IMAGES_ARRIVED);
SPDF_WIN_APP_MSG_OK(spdf_win_md_reloaded_is_routable, SPDF_WIN_MD_WM_RELOADED);

/* Is the selected tab a Markdown document? The commands below are no-ops on
 * anything else, so a PDF reader never pays for them. */
static int spdf_win_md_selected_tab_is_markdown(app* a) {
    int index = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
    const char* path = index >= 0 ? spdf_win_tabs_path(a->tabs, index) : a->path;
    return spdf_path_is_markdown(path);
}

/* Re-lay the selected Markdown tab out at the current options, keeping the
 * reader's page. Returns 1 when something was redrawn. */
static int spdf_win_md_command_reopen(app* a) {
    if (!a->canvas || !spdf_win_md_selected_tab_is_markdown(a)) return 0;
    spdf_win_tabs_app_remember(a->tabs, a->canvas);
    return show_selected_tab(a);
}

/* A- (direction -1) / A+ (+1). Persists the new size, then re-shows the tab.
 * At a limit nothing changes and nothing is redrawn. */
static int spdf_win_md_command_text_step(app* a, int direction) {
    if (!spdf_win_md_selected_tab_is_markdown(a)) return 0;
    if (!spdf_win_md_text_scale_step(direction)) return 0;
    spdf_win_md_save_settings();
    return spdf_win_md_command_reopen(a);
}

/* ROTATE ON A MARKDOWN TAB TURNS THE PAPER (26.9.2-1, mac e775e1d35; per file
 * since 26.9.4-3, mac 5776dd6cf). There is no page to rotate in a document
 * MuPDF laid out itself, and rotating the picture would put the text on its
 * side; the mac turns the sheet landscape instead, and back, whichever way the
 * command turns, and now remembers that against the file. Here the file's
 * orientation is flipped in the module's table, persisted, and the tab is
 * re-laid out through the same re-show A-/A+ takes -- the options are read at
 * open time by every handle, so the canvas and its workers agree on the sheet.
 *
 * The reader lands on the top of the page they were on rather than at the same
 * absolute offset: a landscape sheet holds a different amount of text, so an
 * offset in device pixels would name a different page after the turn, while
 * the page index is the nearer of the two guesses. (The mac re-anchors by the
 * text under the viewport, which this frontend has no interactive string to
 * do.) Returns 1 when redrawn; 0 on a PDF tab, which cmd_search_rotate then
 * rotates in the document as before. */
static int spdf_win_md_command_rotate(app* a) {
    int index = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
    const char* path = index >= 0 ? spdf_win_tabs_path(a->tabs, index) : NULL;
    spdf_win_tab_view* view;
    if (!a->canvas || !path || !spdf_path_is_markdown(path)) return 0;
    spdf_win_md_toggle_landscape(path);
    spdf_win_tabs_app_remember(a->tabs, a->canvas);
    view = spdf_win_tabs_view(a->tabs, index);
    if (view) view->has_scroll_origin = 0; /* the page, not the offset: see above */
    return show_selected_tab(a);
}

/* Call once a tab has been shown: if the open recorded https images that were
 * not in the cache, fetch them in the background; the completion message
 * re-shows the tab. Harmless on a PDF tab (nothing is pending). */
static void spdf_win_md_command_after_open(app* a, HWND window) {
    if (!spdf_win_md_selected_tab_is_markdown(a)) return;
    spdf_win_md_images_fetch_pending(window, SPDF_WIN_MD_WM_IMAGES_ARRIVED);
}

/* The SPDF_WIN_MD_WM_IMAGES_ARRIVED handler. */
static int spdf_win_md_command_images_arrived(app* a) {
    return spdf_win_md_command_reopen(a);
}

/* THE SPDF_WIN_MD_WM_RELOADED HANDLER: the file changed on disk, the re-read
 * finished off-thread (spdf_win_md_reload.h, started by spdf_win_watch_app.h),
 * and the new document is swapped under the canvas -- zoom and offset kept, no
 * empty frame (spdf_win_canvas_replace_document). This is the mac's
 * -installRenderedDocument:preserveCurrentState:YES, at the one place in this
 * frontend that can do it.
 *
 * The TAB's own handle is now the old bytes. It is released rather than
 * swapped, because the tab model materialises documents through its open hook
 * and has no adopt: the canvas owns the new document, and the next thing that
 * asks the tab for one (Save As, Print, a switch away and back) opens the file
 * as it is then -- one open, at the moment it is needed, instead of a stale
 * handle answering forever. Released AFTER the swap, while the canvas no longer
 * borrows it.
 *
 * The reader may have moved on while the read ran: a different tab selected, or
 * the tab closed. The result is then closed and dropped -- that tab reopens from
 * disk whenever it is shown -- rather than swapped under a document it does not
 * describe. */
static int spdf_win_md_command_reloaded(app* a) {
    char path[1024];
    const char* selected_path;
    int index;
    spdf_document* doc = spdf_win_md_reload_take(path, sizeof(path));
    if (!doc) return 0; /* a failed read keeps the last good document on screen */
    index = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
    selected_path = index >= 0 ? spdf_win_tabs_path(a->tabs, index) : NULL;
    if (!a->canvas || !selected_path || strcmp(selected_path, path) != 0 ||
        !spdf_win_canvas_replace_document(a->canvas, doc)) {
        spdf_close(doc);
        return 0;
    }
    spdf_win_tabs_release_document(a->tabs, index);
    /* The search's rects and the panels' handles describe the old text; both
     * rebuild on the next paint, as after Rotate and after a PDF reload. */
    spdf_win_find_restart(spdf_win_find_shared());
    spdf_win_chrome_content_set_document(NULL, 0);
    /* The new text may reference remote images the cache does not have yet. */
    if (a->window) spdf_win_md_command_after_open(a, (HWND)spdf_win_window_native_handle(a->window));
    return 1;
}

#endif /* SPDF_WIN_MD_COMMANDS_H */
