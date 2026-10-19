// spdf_watcher.c — per-tab file watching (auto-reload on disk change) and
// read-only shadow-copy tabs for the GTK4 shell (Wave C).
//
// Ported semantics (Mac):
//   SPDFMacFileWatcher.mm — event watch + 0.4s debounce on top of FSEvents'
//   0.1s latency (~0.5s effective coalescing; SPDF_WATCHER_DEBOUNCE_MS below
//   matches that), owner-side authoritative mtime/size check so the app's own
//   writes never self-trigger, ~1.25s missing-file grace (5 x 250ms) before
//   the stale UI.
//   ShenzhenPDFMac.mm "Read-only shadow copy" section (commit 4492586ea,
//   released in 023dda616) — a read-only SOURCE renders from a private,
//   persistent per-tab copy (ReadOnlyCopies/ro-<sha256>.<ext>); identity
//   (tab->path, title, recents, session) stays on the source; the copy is
//   refreshed from source content only when the source stat actually changed;
//   deliberate tab close deletes an unshared copy; a launch sweep removes
//   orphans (60s recency backstop); Save-As converts the tab to a writable
//   file and drops the copy; session persists the SOURCE path plus the
//   binding (Mac schema keys readOnly/workingPath/roCopyFileSize/
//   roCopyModifiedAt).
//
// Linux divergences (deliberate, documented in the module):
//   - every tab gets a GFileMonitor (inotify is cheap and silent; the Mac
//     watches only the active tab and re-checks the rest on window focus);
//   - read-only detection is g_access(W_OK) on a regular file (covers mode
//     bits, ACLs and read-only mounts via EROFS); the Mac needs a bare lstat
//     to avoid the "access data from other apps" prompt — no such prompt
//     exists on Linux, so the copy is purely a writability shield.
#pragma once

#ifndef SPDF_WATCHER_TESTING
#include "spdf_window.h"

G_BEGIN_DECLS

// Lifecycle (spdf_tab.c). Attach after the tab is fully built (monitors
// tab->path — the SOURCE); detach from spdf_tab_close (also frees the
// watcher-owned SpdfTab fields). Deliberate close (the user closed the tab,
// as opposed to window teardown/quit) additionally deletes an unshared
// shadow copy — the Mac keeps copies across quit so session restore reopens
// them without touching the source.
void spdf_watcher_tab_attached(SpdfTab* tab);
void spdf_watcher_tab_detached(SpdfTab* tab);
void spdf_watcher_tab_deliberate_close(SpdfTab* tab);

// Save-As retargeted tab->path at a writable file: drop the shadow binding
// (delete the copy when unshared), clear the orange dot and re-point the
// monitor at the new path. Called from spdf_annot.c's retarget tail.
void spdf_watcher_tab_repoint(SpdfTab* tab);

// The app itself wrote tab->path in place (comment save): refresh the
// baseline stat so the watcher sees disk == baseline and does not treat the
// write as an external change (Mac refreshActiveTabCachedFileAttributes...).
void spdf_watcher_note_self_save(SpdfTab* tab);

// Retry a changed protected source after the user explicitly returns to a
// tab whose prior password prompt was canceled or failed.
void spdf_watcher_retry_pending(SpdfTab* tab);

// Open-path resolution (spdf_tab_open): returns TRUE when source_path is
// read-only. On TRUE, *out carries the working-copy binding to install on
// the tab; out->working_path may be NULL when the copy could not be written
// (open the source directly, Mac fallback). On FALSE, *out is zeroed.
typedef struct {
    char* working_path;     // owned by caller; the shadow copy to open
    guint64 copy_file_size; // source stat the copy reflects
    double copy_modified_at;
} SpdfWatcherResolution;
gboolean spdf_watcher_resolve_open(const char* source_path, SpdfWatcherResolution* out);

// Session restore: adopt the persisted binding for source_path so the next
// spdf_watcher_resolve_open on it reuses the same copy when the source is
// unchanged (Mac: loadSelectedTab's workingPath-keyed adoption). Consumed by
// the first resolve; safe to call with empty/NULL working_path.
void spdf_watcher_prime_restore(const char* source_path, const char* working_path, guint64 copy_file_size,
                                double copy_modified_at);

// TRUE when path points into the shadow-copies directory (other modules use
// this to keep temp copies out of recents/favorites/etc.).
gboolean spdf_watcher_is_shadow_path(const char* path);

G_END_DECLS
#else
#include <glib.h>
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Pure logic (glib only — no GTK, no probing beyond the two wrappers noted),
// exercised by tests/watcher_test.c.

// Effective Mac coalescing: 0.4s debounce + 0.1s FSEvents latency.
#define SPDF_WATCHER_DEBOUNCE_MS 500
// Mac missing-file grace: 5 x 0.25s before the stale UI.
#define SPDF_WATCHER_MISSING_RETRY_MS 250
#define SPDF_WATCHER_MISSING_RETRIES 5
// Orphan sweep skips copies touched in the last 60s (Mac recency backstop).
#define SPDF_WATCHER_SWEEP_RECENCY_S 60.0
// Stat comparison tolerance: roCopyModifiedAt round-trips JSON at 6 decimals.
#define SPDF_WATCHER_MTIME_TOLERANCE 0.001

// Trailing-edge debounce (every event pushes the deadline back, matching the
// Mac timer re-arm): fire_at_us == 0 means idle.
typedef struct {
    gint64 fire_at_us;
} SpdfWatcherDebounce;
// Record an event at now_us; returns the new deadline (now + delay).
gint64 spdf_watcher_debounce_event(SpdfWatcherDebounce* d, gint64 now_us, gint64 delay_us);
// TRUE exactly once when the deadline passed with no newer event; resets.
gboolean spdf_watcher_debounce_fire(SpdfWatcherDebounce* d, gint64 now_us);

// Deterministic copy filename bound to the (lexically canonicalized) source
// path: "ro-<first 16 bytes of SHA-256, hex>.<ext>" — same construction as
// the Mac readOnlyCopyFileNameForSourcePath, so an unchanged source reclaims
// the same copy across relaunches. NULL for a NULL/empty path.
char* spdf_watcher_shadow_copy_name(const char* source_path);

// TRUE when path lives directly in copies_dir and matches the ro-<hex>.<ext>
// naming (the pure rule behind spdf_watcher_is_shadow_path).
gboolean spdf_watcher_path_is_shadow_in(const char* path, const char* copies_dir);

// Read-only decision: only an existing regular file the process cannot write
// is read-only. Missing/non-regular is NOT read-only (the missing-file UI
// owns that case — Mac sourcePathIsReadOnly contract).
gboolean spdf_watcher_read_only_verdict(gboolean exists, gboolean is_regular, gboolean writable);

// Copy-reuse rule (Mac resolveWorkingPath "unchanged" branch): the copy is
// reusable iff it exists, a binding was recorded (bound_mtime > 0) and the
// fresh source stat matches the stat the copy reflects.
gboolean spdf_watcher_copy_reusable(gboolean copy_exists, guint64 bound_size, double bound_mtime, guint64 source_size,
                                    double source_mtime);

// Authoritative "did the file really change" comparison (size + mtime within
// tolerance). The debounced callback checks this against the baseline so the
// app's own saves never self-trigger a reload.
gboolean spdf_watcher_stat_differs(guint64 a_size, double a_mtime, guint64 b_size, double b_mtime);

// Orphan-sweep rule: delete iff unreferenced by any live tab AND not touched
// within the recency window (defends copies created mid-launch).
gboolean spdf_watcher_sweep_should_delete(gboolean referenced, double copy_mtime, double now);

// ---------------------------------------------------------------------------
// Thin probing wrappers over the pure rules (g_stat/g_access).
gboolean spdf_watcher_source_is_read_only(const char* path);
gboolean spdf_watcher_stat_path(const char* path, guint64* size, double* modified_at);

G_END_DECLS
