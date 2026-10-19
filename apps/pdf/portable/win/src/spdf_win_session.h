/* spdf_win_session.h — the open set, across launches.
 *
 * Reads and writes the SAME session.yaml the mac and GTK apps do, through the
 * SAME codec (portable/core/spdf_yaml.c) and the same file shell
 * (spdf_win_state.h). THERE IS NO WINDOWS SERIALIZER HERE. What this file adds
 * over spdf_win_state is only the shape of the session document — which keys
 * mean what — and it takes that shape verbatim from the two shipping
 * frontends:
 *
 *   { "version": 2,
 *     "windows": [
 *       { "id": "<per-window session id>",
 *         "frame": { "x":…, "y":…, "width":…, "height":… },
 *         "display": { "name": "\\\\.\\DISPLAY2", "x":…, … },   (this port only)
 *         "focusedAt": 812345678.0,
 *         "selectedTab": 0,
 *         "tabs": [ { "path": "…", "title": "…", "page": 0, "zoom": 1.0000,
 *                     "customZoom": 1.0000, "fitMode": 4, "viewMode": 1,
 *                     "scrollX": 0.0000, "scrollY": 0.0000,
 *                     "hasScrollOrigin": false, "preservesImageColors": true,
 *                     … } ] } ] }
 *
 * (mac: ShenzhenPDFMac.mm -sessionWindowState/-loadSessionWindowState:, GTK:
 * portable/linux/gtk4/spdf_state.c session_window_to_json/parse_session_window.
 * `page` is 0-BASED, and "viewMode" is what tells the GTK reader so — its own
 * GTK3-era files were 1-based and carried no viewMode, and it migrates on that
 * key's absence. Omitting it would shift every restored page by one on Linux.)
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS FILE REFUSES TO DO
 *
 * 1. It never opens a document. Restore is METADATA ONLY: paths and view
 *    state land in the tab model and nothing else happens. See spdf_win_tabs.h;
 *    the whole point is that a fifteen-tab session costs the same at launch as
 *    a one-tab session.
 *
 * 2. It never writes over a session it could not read. A session.yaml that is
 *    present but unreadable — antivirus lock, sharing violation, a permissions
 *    blip — reports SPDF_WIN_SESSION_UNREADABLE on restore, and a save in that
 *    state writes NOTHING and returns 0. This is the failure the state layer
 *    was already hardened against (spdf_win_state.h, "SILENT FAILURE IF
 *    WRONG"), and the session file is where it would hurt most: one unlucky
 *    half second at launch would otherwise replace every open document with an
 *    empty set, permanently.
 *
 * 3. It never discards another window's state, and it does not discard the
 *    parts of a tab it does not model. ShenzhenPDF runs one process per window
 *    and merges on write under session.lock; windows belonging to other
 *    processes are copied through byte for byte. Within OUR window, a tab's
 *    keys that this port does not model (whatever a newer mac or Linux build
 *    writes) are carried forward from the matching on-disk tab rather than
 *    dropped, so opening a mac user's session on Windows and quitting does not
 *    silently erase state. searchText, readOnly, workingPath and the roCopy*
 *    keys, once carried this way, are modelled since the 2026-09-02 wave.
 */
#ifndef SPDF_WIN_SESSION_H
#define SPDF_WIN_SESSION_H

#include "spdf_win_tabs.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Same ceiling the GTK frontend applies (SPDF_STATE_MAX_SESSION_WINDOWS). */
#define SPDF_WIN_SESSION_MAX_WINDOWS 16

/* Room for the generated window id plus a NUL. */
#define SPDF_WIN_SESSION_ID_MAX 64

typedef enum spdf_win_session_status {
    /* At least one tab was restored into the model. */
    SPDF_WIN_SESSION_RESTORED = 0,
    /* Nothing usable on disk: no file, or content this build cannot parse.
     * Start with an empty set; saving over it is correct and expected. */
    SPDF_WIN_SESSION_ABSENT = 1,
    /* A session file IS there and could not be read. The model is left
     * untouched and MUST NOT be saved over it — see the header. */
    SPDF_WIN_SESSION_UNREADABLE = 2
} spdf_win_session_status;

/* An id for a window that has no session identity yet, in the same spirit as
 * the GTK frontend's "gtk-<pid>-<time>" and the mac app's per-window UUID:
 * unique across the concurrently running processes that share the file. */
void spdf_win_session_new_window_id(char* out, size_t out_len);

/* Populate `tabs` from session.yaml. `window_id` selects which window to
 * restore; NULL or "" takes the window the reader was last using -- the one
 * with the newest "focusedAt", the first in the file when no entry has one --
 * which is what a plain launch wants: the process that launches is the one
 * that takes the foreground, so the window it restores is the one that comes
 * back in front (mac: spdf_session_focused_window_index, 5776dd6cf). Picking
 * the first entry made that whichever window happened to be written first.
 *
 * Restores paths, titles and view state, sets the persisted selection with
 * spdf_win_tabs_select_deferred() — so NO DOCUMENT IS OPENED — and, when
 * out_window_id is non-NULL, writes back the id of the window it restored so a
 * later save updates that same window rather than growing a new one.
 *
 * `tabs` is only appended to on success; on ABSENT or UNREADABLE it is left
 * exactly as it was. */
spdf_win_session_status spdf_win_session_restore(spdf_win_tabs* tabs, const char* window_id, char* out_window_id,
                                                 size_t out_len);

/* Merge `tabs` into session.yaml as the window `window_id`, under the
 * cross-process session lock. A model with no tabs REMOVES that window from
 * the file (the mac app's -removeSessionStateForCurrentWindow).
 *
 * Returns 1 on success, 0 when the state directory cannot be resolved, the
 * existing file is present but unreadable, or the write fails. A 0 means
 * nothing was written; retrying later is always safe. */
int spdf_win_session_save(const spdf_win_tabs* tabs, const char* window_id);

/* --- the window's frame ---------------------------------------------------
 *
 * "frame": { "x", "y", "width", "height" } on the window object -- the mac
 * writes its NSWindow frame in points, GTK its size in pixels; this port writes
 * the window's normal placement in virtual-screen device pixels
 * (spdf_win_window_get_placement). Cross-platform the numbers mean little (a
 * mac screen's y grows upward), which is why the window layer judges a frame
 * against the attached displays before showing it there -- and, since the
 * 26.9.4-3 port, NEVER clamps it on the way in: a frame whose display is
 * missing is parked centred on the main display and the parked position is
 * never what gets saved (spdf_win_placement.h). `w`/`h` <= 0 means "no frame".
 *
 * "display": { "name", "x", "y", "width", "height" } beside it is this port's
 * own: the MONITORINFOEXW device name and monitor rectangle the frame was on,
 * so "the display it was left on" has an identity and not just a position. A
 * mac file has none and restores from the frame alone; a mac save drops it. */
typedef struct spdf_win_session_frame {
    int x, y, w, h;
    char display[32]; /* "" when unknown */
    int display_x, display_y, display_w, display_h;
} spdf_win_session_frame;

/* As spdf_win_session_restore(), and also reads the window's frame into
 * `out_frame` when there is one (else w = h = 0). NULL is allowed. */
spdf_win_session_status spdf_win_session_restore_ex(spdf_win_tabs* tabs, const char* window_id, char* out_window_id,
                                                    size_t out_len, spdf_win_session_frame* out_frame);

/* As spdf_win_session_save(), writing `frame` as the window's frame. NULL, or a
 * frame with w or h <= 0, keeps whatever frame the file already had for this
 * window -- so a save that knows nothing about geometry never moves a mac
 * user's window. */
int spdf_win_session_save_ex(const spdf_win_tabs* tabs, const char* window_id, const spdf_win_session_frame* frame);

/* --- which window the reader was last using ---------------------------------
 *
 * "focusedAt" on the window object: when this window last had the foreground,
 * in the mac's own unit -- seconds since 2001-01-01 UTC, NSDate's reference
 * date -- so a file both apps write compares the same way. Stamped only when
 * `focused_now` says the window IS the foreground window at the time of the
 * save (a restored sibling is the foreground window of its own process too,
 * and must not stamp itself); otherwise the entry keeps the stamp it had on
 * disk, or 0 when it never had one. save_ex() is save_focused(..., 0). */
int spdf_win_session_save_focused(const spdf_win_tabs* tabs, const char* window_id,
                                  const spdf_win_session_frame* frame, int focused_now);

/* Every window id in the file, in file order, the hand-off parking spot
 * excluded, up to `max`. Returns how many. What a session-restore launch spawns
 * its siblings from -- all of them at once, right after its own restore, so
 * they reach the screen together rather than a launch apart. 0 for no file. */
int spdf_win_session_window_ids(char ids[][SPDF_WIN_SESSION_ID_MAX], int max);

/* --- detaching a tab into a new window -------------------------------------
 *
 * ONE PROCESS PER WINDOW, so tearing a tab off the strip means: write that tab
 * into session.yaml as a NEW window under a fresh id, remove it from this
 * window, and start a second ShenzhenPDF.exe that restores that id
 * (`--window <id>`). The file is the hand-over -- the same file the two
 * processes will keep merging into under session.lock from then on -- so
 * nothing else has to be invented for the second process to find its
 * document, its page and its zoom. macOS detaches in-process
 * (SPDFMacTabStripView.mm:788-836, -detachTabAtIndex:); GTK hands the page to a
 * fresh AdwTabView (spdf_window.c:391). Both keep the tab's whole view state,
 * and so does this.
 *
 * Writes the window under the lock and returns 1 with the new id in
 * `out_new_id`; the caller then closes the tab locally (with
 * prefer_most_recent_active, as :9300 does for a detach) and spawns the
 * process. 0 and nothing written for a bad index, an unreadable file or a
 * failed write -- the tab stays where it is. */
int spdf_win_session_detach_tab(const spdf_win_tabs* tabs, int index, const spdf_win_session_frame* frame,
                                char* out_new_id, size_t out_len);

/* --- handing a tab to a window that ALREADY EXISTS --------------------------
 *
 * The same file, the same one-tab window object, one difference: the id is not
 * a new window's, it is the WELL-KNOWN PARKING SPOT below, and no process is
 * started. The source parks the tab, drops it locally and posts a message to
 * the window under the pointer; that window takes it back out, inserts it and
 * removes the entry. macOS hands the live tab over on a pasteboard inside one
 * process (SPDFMacTabStripView.mm:885-925, -performDragOperation:); one process
 * per window here means the hand-over has to be a file, and this is the file
 * that already exists for exactly this purpose.
 *
 * WHY ONE FIXED ID RATHER THAN A FRESH ONE. There is one pointer, so there is
 * at most one tab in flight on the desktop, and the receiving window has to
 * know which entry is for it without being told a number it has no channel to
 * receive. A fixed id also makes a crashed hand-over recoverable rather than
 * permanent: an entry left here is INVISIBLE to a plain launch (find_window
 * skips it) and is not counted by spdf_win_session_other_windows(), so a stale
 * one cannot restore itself as a window or keep an empty window alive. */
#define SPDF_WIN_SESSION_HANDOFF_ID "tab-handoff"

/* As spdf_win_session_detach_tab(), writing the window under `window_id`
 * instead of a generated one. */
int spdf_win_session_detach_tab_as(const spdf_win_tabs* tabs, int index, const spdf_win_session_frame* frame,
                                   const char* window_id);

/* Take the parked tab back: fills `out_path`, `out_title` and `out_view` from
 * the hand-off entry and REMOVES that entry. Returns 1 when a tab came back, 0
 * when there was nothing parked (and nothing is written). */
int spdf_win_session_handoff_take(char* out_path, size_t path_len, char* out_title, size_t title_len,
                                  spdf_win_tab_view* out_view);

/* Remove the hand-off entry without taking it: what the source calls when the
 * drop it parked a tab for did not happen. Safe with nothing parked. */
void spdf_win_session_handoff_discard(void);

/* How many windows OTHER than `window_id` the file holds: the mac app's "does
 * another ShenzhenPDF window exist" (spdf_win_tabs.h's header), which decides
 * whether closing the last tab closes the window or leaves it empty. One
 * process per window, so the file is the only place the answer lives. 0 for no
 * file or an unreadable one. */
int spdf_win_session_other_windows(const char* window_id);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SESSION_H */
