// spdf_sidebar.c — the left side panel (Wave B): Chapters (outline tree),
// Comments (tab comment cache) and Search results (chapter-grouped matches
// with snippets from SpdfSearchController), plus the win.sidebar stateful
// action (F9 / header toggle) with per-document visibility persisted through
// the state API (documents.json "showSidebar") and the persisted panel width
// (settings "sidebarWidth", 140–560).
//
// Widget choice: GtkPaned, not AdwOverlaySplitView. The split view sizes its
// sidebar by fraction (min/max-sidebar-width + sidebar-width-fraction) and
// offers no drag handle, so the persisted 140–560 px sidebarWidth cannot
// round-trip through it; GtkPaned's pixel position maps 1:1 onto the stored
// setting and gives GNOME-standard drag resizing (clamped on notify::position).
//
// Provenance: GTK3 chapters/comments sidebar (ShenzhenPDFGtk.c
// rebuild_sidebar @2099, add_sidebar_row @2051, deferred metadata load
// @2605 — population stays off the tab-switch paint path via a low-priority
// idle); Mac search-results sidebar (ShenzhenPDFMac.mm
// rebuildSearchSidebarItems @9500, chapter attribution via the match
// chapter_index the search controller computes, commit 073c483ef) with the
// current chapter following page-changed.
#pragma once

#include "spdf_internal.h"
#include "spdf_window.h"

G_BEGIN_DECLS

// Persisted width clamp (settings.json "sidebarWidth", GTK3 parity).
#define SPDF_SIDEBAR_MIN_WIDTH 140
#define SPDF_SIDEBAR_MAX_WIDTH 560

// Builds the window's split layout: returns a GtkPaned with the side panel
// as start child and `content` (the tab view) as end child. Registers the
// stateful win.sidebar action (replacing the Wave A stub), connects itself
// to the tab view's selection/page signals and to the annotations module's
// comments-changed hook. Called once from spdf_window_init; the caller packs
// the returned widget as its toolbar-view content.
GtkWidget* spdf_sidebar_new(SpdfWindow* win, GtkWidget* content);

// Releases the outline cache appended to SpdfTab and drops any sidebar
// references to the tab. Called from spdf_tab_close (mirrors
// spdf_annot_tab_closing).
void spdf_sidebar_tab_closing(SpdfTab* tab);

G_END_DECLS
