// spdf_window.c + spdf_tab.c — AdwApplicationWindow shell (tab bar/view/
// overview, header bar, presentation mode) and the per-document tab model.
#pragma once

#include "spdf_internal.h"

G_BEGIN_DECLS

#define SPDF_TYPE_WINDOW (spdf_window_get_type())
G_DECLARE_FINAL_TYPE(SpdfWindow, spdf_window, SPDF, WINDOW, AdwApplicationWindow)

SpdfWindow* spdf_window_new(AdwApplication* app);

// Opens path in a new tab (or focuses an existing tab showing the same
// document), jumps to page_index (0-based) and selects the tab. Errors are
// reported to the user; returns NULL then. remember_recent is FALSE during
// session restore so restoring does not reshuffle recent.json.
SpdfTab* spdf_window_open_path(SpdfWindow* win, const char* path, int page_index, gboolean remember_recent);
typedef void (*SpdfWindowOpenReady)(SpdfTab* tab, gboolean cancelled, gpointer user_data);
SpdfPasswordPrompt* spdf_window_open_path_async(SpdfWindow* win, const char* path, int page_index,
                                                gboolean remember_recent, SpdfWindowOpenReady ready, gpointer user_data,
                                                GDestroyNotify destroy);

AdwTabView* spdf_window_get_tab_view(SpdfWindow* win);
SpdfTab* spdf_window_current_tab(SpdfWindow* win);
int spdf_window_tab_count(SpdfWindow* win);
SpdfTab* spdf_window_tab_at(SpdfWindow* win, int index);

void spdf_window_set_presentation(SpdfWindow* win, gboolean enable);
gboolean spdf_window_get_presentation(SpdfWindow* win);

void spdf_window_update_title(SpdfWindow* win);
void spdf_window_refresh_recents(SpdfWindow* win); // rebuilds the hamburger recents submenu
// Subtle notification via the window's AdwToastOverlay (watcher auto-reload
// etc.); safe no-op while the window is disposing. (Wave C)
void spdf_window_show_toast(SpdfWindow* win, const char* text);

// Wave C (OCR/translate): show a short-lived completion toast over the
// document area. No-op when the title is empty or the window is disposing.
void spdf_window_add_toast(SpdfWindow* win, const char* title);

// Session identity (session.json "id"). Restored windows keep their persisted
// id; new windows get one lazily on first session capture.
const char* spdf_window_get_session_id(SpdfWindow* win);
void spdf_window_set_session_id(SpdfWindow* win, const char* id);

// Called by spdf_tab_open right after the page↔tab link ("spdf-tab" object
// data) is set: AdwTabView emits page-attached and notify::selected-page
// INSIDE adw_tab_view_append — before the link exists — so the handlers keyed
// off tab_for_page() saw a NULL tab (docview page/zoom signals were never
// connected; the win.minimap action stayed disabled on the first tab).
void spdf_window_tab_linked(SpdfWindow* win, AdwTabPage* page);

// ---------------------------------------------------------------------------
// spdf_tab.c — beyond the contract entry points in spdf_internal.h.
// spdf_tab_open/spdf_tab_close are declared there.

// Read-only shadow-copy marker (orange indicator dot). The file-watcher
// module calls this; the tab only provides the mechanism.
void spdf_tab_set_read_only_shadow(SpdfTab* tab, gboolean read_only);
const char* spdf_tab_get_path(SpdfTab* tab);
// Tab label: embedded document title when present, else basename sans ".pdf".
char* spdf_tab_display_name(const SpdfTab* tab); // caller owns

G_END_DECLS
