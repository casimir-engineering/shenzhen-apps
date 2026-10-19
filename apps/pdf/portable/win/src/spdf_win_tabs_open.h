/* spdf_win_tabs_open.h — the tab model's document hook, in full: the password
 * prompt, the read-only shadow copy, the watch on the source, and the binding
 * that ties a restored tab back to its copy.
 *
 * Header-only and included by spdf_win_tabs_app.h, which hands the two hooks
 * below to spdf_win_tabs_set_document_hooks(). Before `struct app` exists, so
 * nothing here knows the window; what it needs of it -- the HWND a prompt is
 * modal to -- is set once the window exists (spdf_win_tabs_open_set_owner),
 * and the FIRST document is opened before then, with no owner, which
 * spdf_win_password.h allows. Not part of the port's public surface.
 *
 * THE ORDER, from spdf_win_watcher.h's own wiring note, transcribed:
 *
 *   open      resolve the source (a read-only file gets a private copy in
 *             <state dir>\ReadOnlyCopies, refreshed only when the source's
 *             stat changed), open the COPY or the source through the
 *             interactive opener (a password is asked for as often as the
 *             core wants; a Markdown path never meets the prompt), record the
 *             binding on the tab's view, then WATCH THE SOURCE -- never the
 *             copy: the copy is ours and never changes under us.
 *   restore   spdf_win_tabs_open_prime() hands every persisted binding to the
 *             watcher before any tab is shown, so an unchanged source reopens
 *             its copy without a content read (the lazy-restore promise kept
 *             for read-only files too).
 *   on_change the app's half (spdf_win_watch_app.h): a CHANGED reopens
 *             through this same hook -- which is what refreshes a stale copy
 *             -- and keeps the reader's place; a MISSING marks the tab.
 *   self save spdf_win_tabs_open_note_self_save() after the app wrote the
 *             file, so the write is not reported back as a change.
 *   close     spdf_win_tabs_open_forget(): unwatch, and on a DELIBERATE close
 *             release the copy unless another tab renders from it. A tab torn
 *             off into another window is only unwatched: the copy is now
 *             that process's.
 *
 * Process-wide state, like the Markdown options and the find session, because
 * there is one window per process (spdf_win_chrome_model.h). UI thread only.
 */
#ifndef SPDF_WIN_TABS_OPEN_H
#define SPDF_WIN_TABS_OPEN_H

#include "spdf_win_launch_profile.h" /* SPDF-LAUNCH markers; free when unset */
#include "spdf_win_password.h"
#include "spdf_win_tabs.h"
#include "spdf_win_watcher.h"

#include <string.h>

static spdf_win_watcher* g_tabs_watcher;      /* NULL until spdf_win_tabs_open_start_watching */
static void* g_tabs_owner;                     /* the HWND prompts are modal to; NULL before the window */
static spdf_win_watcher_fn g_tabs_on_change;   /* the app's handler, and its user */
static void* g_tabs_on_change_user;
static int g_tabs_open_cancelled;              /* the last hook call ended in the reader cancelling */

/* One watch per SOURCE path. Keyed by path rather than by tab index because
 * tabs move and close; the app opens one tab per path, so the key is unique. */
typedef struct SpdfWinTabWatch {
    char path[SPDF_WIN_WATCHER_PATH_MAX];
    int id;
} SpdfWinTabWatch;
static SpdfWinTabWatch g_tabs_watches[SPDF_WIN_TABS_MAX];
static int g_tabs_watch_count;

static void spdf_win_tabs_open_configure(spdf_win_watcher_fn on_change, void* user) {
    g_tabs_on_change = on_change;
    g_tabs_on_change_user = user;
}

static void spdf_win_tabs_open_set_owner(void* hwnd) { g_tabs_owner = hwnd; }

/* Creates the watcher's message-only window on this thread. Idempotent. A
 * failure leaves g_tabs_watcher NULL and every file simply does not
 * auto-reload, as spdf_win_watcher.h says of a directory that cannot be
 * watched. */
static void spdf_win_tabs_open_start_watching(void) {
    if (!g_tabs_watcher) g_tabs_watcher = spdf_win_watcher_create();
}

/* Stops every watch (joining the worker threads) -- after the tab model is
 * gone, so no callback can land on a closed tab. */
static void spdf_win_tabs_open_stop_watching(void) {
    if (g_tabs_watcher) spdf_win_watcher_destroy(g_tabs_watcher);
    g_tabs_watcher = NULL;
    g_tabs_watch_count = 0;
}

/* 1 when the LAST open hook call returned NULL because the reader cancelled
 * the password prompt: nothing to report, unlike a file that would not open. */
static int spdf_win_tabs_open_cancelled(void) { return g_tabs_open_cancelled; }

static int tabs_watch_index(const char* path) {
    int i;
    if (!path) return -1;
    for (i = 0; i < g_tabs_watch_count; ++i)
        if (strcmp(g_tabs_watches[i].path, path) == 0) return i;
    return -1;
}

static void tabs_watch(const char* path) {
    int id;
    if (!g_tabs_watcher || !path || !*path || tabs_watch_index(path) >= 0 || g_tabs_watch_count >= SPDF_WIN_TABS_MAX)
        return;
    id = spdf_win_watcher_watch(g_tabs_watcher, path, g_tabs_on_change, g_tabs_on_change_user);
    if (id <= 0) return; /* the directory cannot be watched; the file is still usable */
    strncpy_s(g_tabs_watches[g_tabs_watch_count].path, sizeof(g_tabs_watches[0].path), path, _TRUNCATE);
    g_tabs_watches[g_tabs_watch_count].id = id;
    ++g_tabs_watch_count;
}

static void spdf_win_tabs_open_unwatch(const char* path) {
    int i = tabs_watch_index(path);
    if (i < 0) return;
    spdf_win_watcher_unwatch(g_tabs_watcher, g_tabs_watches[i].id);
    memmove(&g_tabs_watches[i], &g_tabs_watches[i + 1], (size_t)(g_tabs_watch_count - i - 1) * sizeof(g_tabs_watches[0]));
    --g_tabs_watch_count;
}

/* The app itself wrote `path` (Rotate saves in place): the new stat becomes the
 * baseline so the write is not reported as an external change. */
static void spdf_win_tabs_open_note_self_save(const char* path) {
    int i = tabs_watch_index(path);
    if (i >= 0) spdf_win_watcher_note_self_save(g_tabs_watcher, g_tabs_watches[i].id);
}

/* Whether a tab OTHER than `except` renders from `working_path`. */
static int tabs_open_copy_shared(const spdf_win_tabs* tabs, int except, const char* working_path) {
    int i, count = spdf_win_tabs_count(tabs);
    for (i = 0; i < count; ++i) {
        const spdf_win_tab_view* v = i == except ? NULL : spdf_win_tabs_view_const(tabs, i);
        if (v && v->read_only && v->working_path[0] && strcmp(v->working_path, working_path) == 0) return 1;
    }
    return 0;
}

/* The path the RENDER WORKERS open their own handles from: the shadow copy
 * when the document itself came from one, so every handle on the tab agrees
 * on the bytes; else the tab's own path. The tab's IDENTITY -- title, recents,
 * session entry -- stays on the source throughout (spdf_win_watcher.h). */
static const char* spdf_win_tabs_open_render_path(const spdf_win_tabs* tabs, int index) {
    const spdf_win_tab_view* v = spdf_win_tabs_view_const(tabs, index);
    return v && v->read_only && v->working_path[0] ? v->working_path : spdf_win_tabs_path(tabs, index);
}

/* A DELIBERATE close of tab `index`: unwatch, and drop its copy unless another
 * tab shares it. Before spdf_win_tabs_close(), while the path is still there. */
static void spdf_win_tabs_open_forget(spdf_win_tabs* tabs, int index) {
    const spdf_win_tab_view* v = spdf_win_tabs_view_const(tabs, index);
    const char* path = spdf_win_tabs_path(tabs, index);
    if (path) spdf_win_tabs_open_unwatch(path);
    if (v && v->read_only && v->working_path[0])
        spdf_win_watcher_release_copy(v->working_path, tabs_open_copy_shared(tabs, index, v->working_path));
}

/* Session restore: every persisted binding, primed BEFORE the first show. */
static void spdf_win_tabs_open_prime(const spdf_win_tabs* tabs) {
    int i, count = spdf_win_tabs_count(tabs);
    for (i = 0; i < count; ++i) {
        const spdf_win_tab_view* v = spdf_win_tabs_view_const(tabs, i);
        if (v && v->read_only && v->working_path[0])
            spdf_win_watcher_prime_restore(spdf_win_tabs_path(tabs, i), v->working_path, v->ro_copy_file_size,
                                           v->ro_copy_modified_at);
    }
}

/* --- the hooks -------------------------------------------------------------- */

/* `user` is the tab model, so the binding can be written onto the tab's view.
 * Returns NULL with err EMPTY when the reader cancelled a password prompt --
 * the model remembers an error but caches nothing, so selecting the tab again
 * asks again -- and NULL with err filled for a file that would not open. */
static void* tabs_app_open_document(void* user, const char* path, char* err, size_t err_len) {
    spdf_win_tabs* tabs = (spdf_win_tabs*)user;
    SpdfWinWatcherResolution res;
    spdf_document* doc = NULL;
    spdf_win_tab_view* view;
    int read_only = spdf_win_watcher_resolve_open(path, &res);
    const char* open_path = read_only && res.working_path[0] ? res.working_path : path;
    int rc;

    /* The launch timeline's `spdf-open-*` pair. It brackets the WHOLE hook, not
     * just spdf_open() inside it: the resolve above and the shadow copy it can
     * order are part of what a launch waits for, and the timeline exists to
     * account for the wall clock rather than for one call. Free when
     * SPDF_WIN_LAUNCH_PROFILE is unset -- one load and one compare. */
    spdf_win_launch_mark("spdf-open-begin");
    rc = spdf_win_open_document_interactive(g_tabs_owner, open_path, &doc, err, err_len);
    spdf_win_launch_mark("spdf-open-end");

    g_tabs_open_cancelled = rc == 0;
    if (rc == 0 && err && err_len) err[0] = 0;
    view = tabs ? spdf_win_tabs_view(tabs, spdf_win_tabs_index_of_path(tabs, path)) : NULL;
    if (view) {
        view->read_only = read_only;
        strncpy_s(view->working_path, sizeof(view->working_path), read_only ? res.working_path : "", _TRUNCATE);
        view->ro_copy_file_size = res.copy_file_size;
        view->ro_copy_modified_at = res.copy_modified_at;
        view->missing = 0; /* it is there: we just opened it */
    }
    if (doc) tabs_watch(path);
    return doc;
}

static void tabs_app_close_document(void* user, void* document) {
    (void)user;
    if (document) spdf_close((spdf_document*)document);
}

#endif /* SPDF_WIN_TABS_OPEN_H */
