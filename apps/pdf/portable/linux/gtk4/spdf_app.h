// spdf_app.c — AdwApplication subclass: launch path, command-line documents,
// session restore, recents, reopen-closed ring. Private header for the shell
// modules (spdf_main.c, spdf_window.c, spdf_tab.c, spdf_shortcuts.c).
// Persistence goes through the spdf_state.c API (spdf_state_internal.h).
#pragma once

#include "spdf_internal.h"
#include "spdf_state_internal.h"

G_BEGIN_DECLS

#define SPDF_TYPE_APP (spdf_app_get_type())
G_DECLARE_FINAL_TYPE(SpdfApp, spdf_app, SPDF, APP, AdwApplication)

#define SPDF_APP_ID "com.intuition.shenzhenpdf"
#define SPDF_APP_DISPLAY_NAME "Shenzhen PDF"
// Release identity, compared against GitHub release tags ("YY.M.DD-BUILD")
// by spdf_updater.c and shown in the about dialog. cut-release.sh must bump
// these alongside the Mac Info.plist locations.
#define SPDF_APP_VERSION "26.10.20"
#define SPDF_APP_BUILD "1"
#define SPDF_CLOSED_RING_CAPACITY 10
#define SPDF_RECENT_MENU_LIMIT 10

SpdfApp* spdf_app_new(void);
SpdfState* spdf_app_get_state(SpdfApp* app); // lazy spdf_state_load()
void spdf_app_remember_recent(SpdfApp* app, const char* path);
void spdf_app_remember_closed(SpdfApp* app, const char* path);
char* spdf_app_pop_closed(SpdfApp* app); // caller owns; NULL when ring empty
gboolean spdf_app_has_closed(SpdfApp* app);
void spdf_app_save_session(SpdfApp* app); // snapshot all windows into SpdfState
// WM close (Alt+F4/titlebar ×): save the full session, then close every
// window so the whole app goes away; the next activate restores everything.
// `keep` (may be NULL) is the window whose close-request is already in
// flight — it is skipped here and destroyed by GTK when the handler returns.
void spdf_app_close_all_windows(SpdfApp* app, SpdfWindow* keep);
// --- resident instant-launch (Wave D) ---------------------------------------
// The last window is being deliberately closed. Under the resident hold the
// process lives on with everything per-window/per-tab already torn down; this
// only returns freed heap to the OS (small idle RSS) — the "no session
// resurrection" rule needs no flag because restore only ever runs on the
// first open of a process (see spdf_app_activate).
void spdf_app_notify_last_window_closed(SpdfApp* app);

// ---------------------------------------------------------------------------
// spdf_shortcuts.c — the single registry of every GAction name, its accels
// and its F1 cheat-sheet entry. Actions without accels still appear here so
// the table stays the authoritative list.
typedef struct spdf_shortcut_entry {
    const char* action;    // detailed action name, e.g. "win.open"
    const char* accels[3]; // NULL-padded accelerator strings
    const char* group;     // GtkShortcutsWindow group title; NULL = hidden
    const char* title;     // human-readable description
} SpdfShortcutEntry;

const SpdfShortcutEntry* spdf_shortcuts_table(int* count);
void spdf_shortcuts_install(GtkApplication* app);
void spdf_shortcuts_present_window(GtkWindow* parent); // F1 cheat sheet

G_END_DECLS
