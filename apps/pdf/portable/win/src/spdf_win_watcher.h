/* spdf_win_watcher.h — a document changed on disk: notice it, coalesce it, tell
 * the tab; and read-only sources opened as a silent shadow copy.
 *
 * WHAT THIS IS THE PORT OF. GTK4's spdf_watcher.c (a GFileMonitor per tab,
 * 500 ms trailing-edge debounce, an authoritative size+mtime comparison against
 * a baseline so the app's own saves never self-trigger, a 5 x 250 ms grace
 * before a missing file is reported) and the mac's SPDFMacFileWatcher (FSEvents
 * on the PARENT DIRECTORY, keyed to the file name, because an atomic save --
 * write-temp then rename -- invalidates any handle on the original file). The
 * decisions are in spdf_win_watcher_logic.h; this file is the Win32 plumbing.
 *
 * THE WIN32 SHAPE. ReadDirectoryChangesW on the document's directory, from a
 * worker thread per watch that does nothing but wait and post; the events land
 * on the UI thread through a message-only window this module owns, where the
 * debounce timer runs and the subscriber's callback is invoked. So the tabs
 * layer subscribes with a plain callback and never sees a thread, a handle or a
 * message -- the same division spdf_win_render.c makes for the render workers.
 * The callback always runs on the thread that created the watcher.
 *
 * READ-ONLY SHADOW COPIES (26.6.27-2, mac commit 4492586ea): a source the
 * process cannot write is rendered from a private, persistent copy in
 * <state dir>\ReadOnlyCopies\ro-<sha256>.<ext>. The tab's IDENTITY -- its path,
 * title, recents entry, session entry -- stays on the source; only the path
 * handed to spdf_open changes. The copy is refreshed from the source only when
 * the source's stat changed; an unchanged source reopens the existing copy with
 * no content read. The session keys readOnly / workingPath / roCopyFileSize /
 * roCopyModifiedAt (already carried by session.yaml) are the binding this
 * module hands out and takes back on restore. Save As converts: the tab is
 * repointed at the written file and its copy is dropped when no other tab
 * shares it.
 *
 * WHAT THE TABS LAYER MUST DO -- the wiring, in order:
 *   open      r = spdf_win_watcher_resolve_open(path, &res);
 *             spdf_open(res.read_only && res.working_path[0] ? res.working_path : path)
 *             then spdf_win_watcher_watch(w, path, on_change, tab)
 *   restore   spdf_win_watcher_prime_restore(path, workingPath, roCopyFileSize,
 *             roCopyModifiedAt) BEFORE the tab is first shown
 *   on_change SPDF_WIN_WATCH_CHANGED: reopen through the same resolve (a
 *             shadow tab gets a refreshed copy), swap the document, keep the
 *             scroll; SPDF_WIN_WATCH_MISSING: mark the tab stale
 *   self save spdf_win_watcher_note_self_save(w, id) after the app wrote the file
 *   close     spdf_win_watcher_unwatch(w, id); on a DELIBERATE close also
 *             spdf_win_watcher_release_copy(working_path, shared_by_another_tab)
 *   Save As   spdf_win_watcher_release_copy(old working path, shared), then
 *             unwatch + watch the new path
 */
#ifndef SPDF_WIN_WATCHER_H
#define SPDF_WIN_WATCHER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_WIN_WATCHER_PATH_MAX 1024

typedef enum spdf_win_watch_event {
    SPDF_WIN_WATCH_CHANGED = 1, /* size or mtime differs from the baseline; the baseline is advanced */
    SPDF_WIN_WATCH_MISSING = 2  /* gone for the whole grace period; a later reappearance reports CHANGED */
} spdf_win_watch_event;

/* Runs on the watcher's creating thread. `utf8_path` is the SOURCE path the
 * watch was registered with. */
typedef void (*spdf_win_watcher_fn)(void* user, const char* utf8_path, int event);

typedef struct spdf_win_watcher spdf_win_watcher;

/* One per UI thread; creates the message-only window on the calling thread.
 * NULL when the window cannot be created. */
spdf_win_watcher* spdf_win_watcher_create(void);
/* Stops every watch (joining the worker threads) and destroys the window. */
void spdf_win_watcher_destroy(spdf_win_watcher* w);

/* Start watching `utf8_path` (the source, never the shadow copy). Takes the
 * file's current stat as the baseline. Returns a watch id > 0, or 0 when the
 * directory cannot be opened for notification (the file is still usable; it
 * simply will not auto-reload). */
int spdf_win_watcher_watch(spdf_win_watcher* w, const char* utf8_path, spdf_win_watcher_fn fn, void* user);
void spdf_win_watcher_unwatch(spdf_win_watcher* w, int id);
/* The app itself wrote the file: take the new stat as the baseline so the write
 * is not reported as an external change. */
void spdf_win_watcher_note_self_save(spdf_win_watcher* w, int id);
/* How many watches are live. For tests. */
int spdf_win_watcher_count(const spdf_win_watcher* w);

/* --- stat and read-only probes ---------------------------------------------- */

/* Size and mtime (seconds since the epoch, 100 ns resolution) of a regular
 * file. Returns 0 when it cannot be stat'd or is a directory. */
int spdf_win_watcher_stat(const char* utf8_path, unsigned long long* size, double* mtime);
/* spdf_watcher_source_is_read_only: an existing regular file this process
 * cannot open for writing (the read-only attribute, an ACL, a read-only
 * volume). Missing or a directory is NOT read-only. The probe opens for write
 * without truncating and closes at once. */
int spdf_win_watcher_source_is_read_only(const char* utf8_path);

/* --- shadow copies ----------------------------------------------------------- */

typedef struct SpdfWinWatcherResolution {
    int read_only;                                 /* 1: the source cannot be written */
    char working_path[SPDF_WIN_WATCHER_PATH_MAX]; /* the copy to open, or "" (open the source: copy failed) */
    unsigned long long copy_file_size;             /* the source stat the copy reflects */
    double copy_modified_at;
} SpdfWinWatcherResolution;

/* Decide what to open for `source`. Returns 1 when the source is read-only and
 * fills the binding (working_path may be empty when the copy could not be
 * written: open the source directly, as the mac does). Returns 0 for a writable
 * or missing source with *out zeroed. Consumes a primed restore binding. */
int spdf_win_watcher_resolve_open(const char* utf8_source, SpdfWinWatcherResolution* out);

/* THE COPY THAT ALREADY EXISTS FOR `utf8_source`, if there is one: fills `out`
 * and returns 1, else empties it and returns 0.
 *
 * WHY THIS IS NOT spdf_win_watcher_resolve_open(). Everything in the process
 * that opens a document by path -- the search worker, the thumbnail store, the
 * outline bridge, the link scanner, the render pool -- has to open the same
 * bytes the canvas is showing, or a search hit lands on the wrong page of a
 * document that changed under the app. But those opens happen on WORKER
 * THREADS, several at once, and resolve_open() is a UI-thread function in three
 * separate ways: it mutates the primed-restore table with no lock, it CREATES
 * the copy (so N workers would race to author it, and the random staged
 * fallback would leave N orphans behind), and consuming a primed binding on a
 * worker would spend the session-restore adoption that the UI thread's own open
 * is about to need. So this is the half a worker may call: a pure question
 * about the filesystem, no state touched, no file written, safe from any
 * thread and at any time.
 *
 * IT DELIBERATELY DOES NOT CHECK THAT THE COPY IS STILL CURRENT. A stale copy
 * is exactly what the caller wants: the canvas is holding that copy's bytes
 * until the watcher reports the change and reloads, and until then a worker
 * that "helpfully" read the newer source would disagree with the page on
 * screen -- which is the bug this exists to fix, in reverse.
 *
 * The read-only test is what keeps a copy left behind by an earlier session
 * from capturing a file that has since become writable; it is only reached
 * when a copy is actually there, so the common open pays one stat. */
int spdf_win_watcher_existing_working_path(const char* utf8_source, char* out, size_t out_cap);

/* Session restore: the persisted binding for `source`, adopted by the next
 * resolve so an unchanged source reuses its copy without a content read. */
void spdf_win_watcher_prime_restore(const char* utf8_source, const char* utf8_working_path,
                                    unsigned long long copy_file_size, double copy_modified_at);

/* Drop a copy the tab no longer needs (deliberate close, Save As), unless
 * another tab still references the same file. */
void spdf_win_watcher_release_copy(const char* utf8_working_path, int still_referenced);

/* 1 when `path` lies in the copies directory with the shadow shape, so recents
 * and favorites can refuse it. */
int spdf_win_watcher_is_shadow_path(const char* utf8_path);

/* Delete every copy in the directory that no live tab references and that was
 * not touched in the last 60 s (the mac's deferred launch sweep). `referenced`
 * are working paths in use. */
void spdf_win_watcher_sweep_orphans(const char* const* referenced, int count);

/* <state dir>\ReadOnlyCopies, created when `create`. For tests. */
int spdf_win_watcher_copies_dir(int create, char* out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_WATCHER_H */
