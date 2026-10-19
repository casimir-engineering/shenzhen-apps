// spdf_state.c extended contract — state persistence for the GTK4 frontend.
// Schema-compatible with the Mac app's YAML state files
// (settings.yaml / session.yaml / favorites.yaml / documents.yaml) and
// migration-compatible with the retired GTK3 frontend's JSON files, which
// live in the same directory ($XDG_CONFIG_HOME/shenzhenpdf) so upgrading
// users keep their state.
//
// Contract additions in this header are candidates for promotion into
// spdf_internal.h by integrator decision; spdf_state.c is the only
// implementation file.
#pragma once

#ifdef SPDF_STATE_TESTING
// Pure-logic test build: glib only, no GTK. GdkRectangle is layout-compatible
// with the real cairo_rectangle_int_t so the clamp logic is testable as-is.
#include <glib.h>
typedef struct {
    int x;
    int y;
    int width;
    int height;
} GdkRectangle;
typedef struct _SpdfState SpdfState;
// Seam functions normally declared in spdf_internal.h:
SpdfState* spdf_state_load(void);
void spdf_state_save_session(SpdfState* s);
void spdf_state_flush(SpdfState* s);
#else
#include "spdf_internal.h"
#endif

G_BEGIN_DECLS

// Limits shared with the GTK3 predecessor (state files must keep working).
#define SPDF_STATE_MAX_SESSION_WINDOWS 16
#define SPDF_STATE_MAX_SESSION_TABS 64
#define SPDF_STATE_MAX_RECENT_DOCUMENTS 10
#define SPDF_STATE_MAX_CLOSED_DOCUMENTS 10
#define SPDF_STATE_MAX_FAVORITES 4096
#define SPDF_STATE_MAX_FIND_QUERY_BYTES 2048
#define SPDF_STATE_MAX_CONFIG_JSON_BYTES (2 * 1024 * 1024)

#define SPDF_STATE_MIN_WINDOW_WIDTH 560
#define SPDF_STATE_MIN_WINDOW_HEIGHT 380
#define SPDF_STATE_MAX_WINDOW_WIDTH 4096
#define SPDF_STATE_MAX_WINDOW_HEIGHT 3072
#define SPDF_STATE_DEFAULT_WINDOW_WIDTH 1120
#define SPDF_STATE_DEFAULT_WINDOW_HEIGHT 800

// Coalesced write delay (dirty flags + timer + flush on quit; June 2026 fix).
#define SPDF_STATE_WRITE_DELAY_MS 1000

// Mac page-geometry cache validation (documents.json).
#define SPDF_STATE_PAGE_GEOMETRY_VERSION 1
#define SPDF_STATE_PAGE_GEOMETRY_MTIME_TOLERANCE 0.001

// ---------------------------------------------------------------------------
// Settings — every key the Mac writer persists that is meaningful on Linux,
// plus the GTK3-only extras (zoom, showFindMarkers) the Linux app keeps.
typedef struct {
    int fit_mode;                       // "fitMode" 0..4 (custom/actual/width/height/page)
    double zoom;                        // "zoom" (GTK3 extra), 0.10..8.0
    int sidebar_width;                  // "sidebarWidth" 140..560
    double minimap_width;               // "minimapWidth" 72..260
    gboolean default_sidebar_visible;   // "defaultSidebarVisibleForNewDocuments"
    gboolean default_minimap_visible;   // "defaultMinimapVisibleForNewDocuments"
    gboolean collapse_whitespace_on_copy;    // "collapseWhitespaceWhenCopyingText"
    gboolean search_jumps_to_nearest_result; // "searchJumpsToNearestResult"
    gboolean show_find_markers;              // "showFindMarkers" (GTK3 extra)
    gboolean show_shortcut_help_on_launch;   // "showShortcutHelpOnLaunch"
    gboolean auto_update_enabled;            // "autoUpdateEnabled"
    gboolean prevent_sleep_in_presentation;  // "preventSleepInPresentation"
    gboolean default_reader_prompt_dismissed; // "defaultReaderPromptDismissed"
    int print_scaling_mode;             // "printScalingMode" 0..2
    double print_custom_scale;          // "printCustomScale" 0.10..8.0
    int window_width;                   // "windowSize" { "width", "height" }
    int window_height;
    char* comment_author;               // "commentAuthor"
    char* skipped_update_version;       // "skippedUpdateVersion"
    char* translate_source_language;    // "translateSourceLanguage"
    char* translate_target_language;    // "translateTargetLanguage"
    // --- Wave C additions (spdf_ocr.c) --------------------------------------
    // "ocrLanguage": the last OCR language choice (Tesseract code, e.g.
    // "chi_sim+eng"). GTK4 extra: neither the GTK3 nor the Mac writer
    // persists this (their prompts always preselect the first entry); both
    // readers pass unknown keys through, so the schema stays compatible.
    char* ocr_language;
    // --- Wave D additions (spdf_app.c / spdf_resident.c) --------------------
    // "instantLaunchResident": resident instant-launch mode — the app holds
    // itself alive after the last window closes and installs a login
    // autostart entry (spec "Launch speed", default on). Linux-only key like
    // ocrLanguage: the Mac reader ignores it.
    gboolean instant_launch_resident;
    // --- Mac-only keys carried through Linux rewrites ------------------------
    // "fullDiskAccessPromptDismissed" / "permissionsWizardShown": macOS
    // permission-flow flags. The Linux app never uses them, but a
    // settings.json copied from (or shared with) the Mac app must not lose
    // them on a Linux rewrite — that would re-trigger the Mac prompts.
    // Written back only when present in the loaded file.
    gboolean mac_full_disk_prompt_dismissed;
    gboolean has_mac_full_disk_prompt_dismissed;
    gboolean mac_permissions_wizard_shown;
    gboolean has_mac_permissions_wizard_shown;
} SpdfSettings;

// ---------------------------------------------------------------------------
// Session — multi-window, per-window tabs + selected tab + geometry.
typedef struct {
    char* path;
    char* title;
    int page;                     // 0-based (Mac schema; GTK3 files migrated on read)
    double zoom;
    double custom_zoom;
    int fit_mode;                 // 0..4
    double scroll_x;
    double scroll_y;
    gboolean has_scroll_origin;
    char* search_text;
    gboolean search_regex;
    gboolean search_regex_multiline;
    int find_match_index;
    gboolean show_sidebar;
    gboolean show_minimap;
    gboolean has_show_sidebar;    // key present in the stored tab object
    gboolean has_show_minimap;
    gboolean read_only;           // read-only shadow copy (orange dot)
    char* working_path;
    guint64 ro_copy_file_size;
    double ro_copy_modified_at;
} SpdfSessionTab;

typedef struct {
    char* id;
    GdkRectangle frame;
    gboolean has_frame;
    int selected_tab;
    GPtrArray* tabs;              // SpdfSessionTab*, owned
} SpdfSessionWindow;

// ---------------------------------------------------------------------------
// Favorites (favorites.json, Mac schema: top-level array).
typedef struct {
    char* type;                   // "page" or "document"
    char* path;
    char* title;
    char* name;
    char** labels;                // NULL-terminated strv, may be NULL
    int page;                     // 0-based
    gint64 created;               // seconds since epoch
} SpdfFavorite;

// ---------------------------------------------------------------------------
// Per-document view state (documents.json, keyed by canonical path).
typedef struct {
    char* path;
    char* title;
    gboolean show_sidebar;
    gboolean show_minimap;
    gboolean has_show_sidebar;
    gboolean has_show_minimap;
    gint64 updated_at;            // seconds since epoch
    // Page-geometry cache, valid only when geometry_page_count > 0.
    guint64 geometry_file_size;
    double geometry_modified_at;  // seconds since epoch, sub-second precision
    int geometry_version;
    int geometry_page_count;
    double* page_geometry;        // width,height pairs; 2 * geometry_page_count
} SpdfDocState;

// ---------------------------------------------------------------------------
// Lifecycle. spdf_state_load() (declared in spdf_internal.h) reads ONLY
// settings.yaml and session.yaml — one stat+read each — so it stays cheap on
// the launch path. favorites.yaml / documents.yaml load lazily on first use.
SpdfState* spdf_state_load_from_dir(const char* config_dir); // tests, detached launches
void spdf_state_free(SpdfState* s);
const char* spdf_state_config_dir(SpdfState* s);
const char* spdf_state_file_path(SpdfState* s, const char* name); // "settings.yaml" etc.

// Coalesced writes: the save_* entry points only mark dirty and arm a
// SPDF_STATE_WRITE_DELAY_MS timer; the timer serializes on the caller's
// thread and hands the payload to a worker for the atomic write
// (g_file_set_contents_full, consistent/atomic-rename mode). Callers may
// invoke them on every mutation — including scroll settle — without I/O cost.
// spdf_state_flush() (declared in spdf_internal.h) cancels the timer, joins
// the worker and writes everything dirty synchronously (quit path).
void spdf_state_save_settings(SpdfState* s);
void spdf_state_save_favorites(SpdfState* s);
void spdf_state_save_documents(SpdfState* s);
// spdf_state_save_session(s) is declared in spdf_internal.h.
void spdf_state_set_suppress_session_write(SpdfState* s, gboolean suppress);

// --- settings ---------------------------------------------------------------
SpdfSettings* spdf_state_settings(SpdfState* s); // mutate, then spdf_state_save_settings
void spdf_state_set_string(char** field, const char* value); // g_free + g_strdup helper

// --- session restore snapshot (as read at launch) ---------------------------
guint spdf_state_session_window_count(SpdfState* s);
const SpdfSessionWindow* spdf_state_session_window(SpdfState* s, guint index);
const SpdfSessionWindow* spdf_state_session_window_by_id(SpdfState* s, const char* id);

// --- session live updates ----------------------------------------------------
// Window agent builds a snapshot and hands it over (ownership transfers);
// merge-on-write keeps other processes' windows (flock on session.lock, same
// protocol as the GTK3 + Mac apps).
SpdfSessionWindow* spdf_session_window_new(const char* id); // NULL id => fresh "gtk-<pid>-<us>"
void spdf_session_window_free(SpdfSessionWindow* w);
SpdfSessionTab* spdf_session_window_add_tab(SpdfSessionWindow* w); // zeroed + sane defaults
void spdf_state_update_session_window(SpdfState* s, SpdfSessionWindow* w); // takes ownership, marks dirty
void spdf_state_remove_session_window(SpdfState* s, const char* id);       // deliberate close

// --- recents (persisted inside settings.json "recentlyOpened") ---------------
int spdf_state_recent_count(SpdfState* s);
const char* spdf_state_recent_path(SpdfState* s, int index);
void spdf_state_add_recent(SpdfState* s, const char* path);    // dedupe, MRU-first, cap 10
void spdf_state_remove_recent(SpdfState* s, const char* path);

// --- closed-documents ring (in-memory, parity with GTK3 + Mac) ---------------
void spdf_state_remember_closed(SpdfState* s, const char* path);
char* spdf_state_pop_closed(SpdfState* s); // caller frees; NULL when empty
int spdf_state_closed_count(SpdfState* s);

// --- favorites (lazy: first call reads favorites.json) -----------------------
guint spdf_state_favorite_count(SpdfState* s);
const SpdfFavorite* spdf_state_favorite(SpdfState* s, guint index);
void spdf_state_add_favorite(SpdfState* s, const SpdfFavorite* favorite); // copies, dedupes like Mac
gboolean spdf_state_remove_favorite(SpdfState* s, guint index);

// --- per-document view state (lazy: first call reads documents.json) ---------
const SpdfDocState* spdf_state_document_lookup(SpdfState* s, const char* path);
void spdf_state_document_update(SpdfState* s, const SpdfDocState* doc_state); // upsert copy, stamps updatedAt
// Pure validation, mirrors the Mac page-geometry cache + GTK3 park/restore:
// version, exact size, mtime within tolerance, page count, finite positive dims.
gboolean spdf_doc_state_geometry_valid(const SpdfDocState* doc_state,
                                       guint64 file_size,
                                       double modified_at,
                                       int page_count);
// stat() helper: size + mtime (sub-second) for geometry validation / watcher.
gboolean spdf_state_stat_file(const char* path, guint64* size, double* modified_at);

// --- window geometry clamp (fixes June defect #3: restore off-workarea) ------
// Pure: clamps *frame into workarea — size limited to the workarea (and the
// hard 4096x3072 / 560x380 caps), origin clamped inside; frames with less
// than 80x80 px visible are centered instead. Invalid workarea (w/h <= 0)
// only applies the hard size caps.
void spdf_state_clamp_geometry(const GdkRectangle* workarea, GdkRectangle* frame);
#ifndef SPDF_STATE_TESTING
// Convenience wrapper: GTK4 has no gdk_monitor_get_workarea, so the monitor
// geometry is the best available workarea approximation on Wayland.
void spdf_state_clamp_geometry_for_monitor(GdkMonitor* monitor, GdkRectangle* frame);
#endif

G_END_DECLS
