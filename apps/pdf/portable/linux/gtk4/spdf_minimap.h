// spdf_minimap.c — the document map (minimap): a per-tab thumbnail strip on
// the right side of the page content (Mac trailing-edge placement) with a
// draggable viewport rectangle, click-to-jump, the post-freeze strip-scroll
// model (Mac db9515802: scrolling ON the minimap moves the STRIP and the
// document follows at strip scale), search-hit ticks and current-page
// emphasis. Thumbnails render through the tab's SpdfRenderService at warm
// priority into a widget-local 32MB LRU (GTK3 minimap thumbnail store), and
// only a bounded window of pages around the visible strip range is ever
// rendered/kept (Mac SPDFMacMinimapWindow), so the strip scales to
// arbitrarily long documents.
//
// Provenance: GTK3 minimap (ShenzhenPDFGtk.c minimap_draw @5639,
// button press/motion/release @5966-6041, thumbnail store/evict @2665,
// scroll @6042 superseded by the Mac strip-scroll model); Mac
// SPDFMacMinimapView.mm + SPDFMacMinimapWindow.mm.
//
// Visibility is per-document (documents.json "showMinimap", Mac schema) with
// settings "defaultMinimapVisibleForNewDocuments" for documents never seen
// before; the stateful win.minimap action drives the header-bar toggle.
// Neither GTK3 nor the Mac app bind a key to the toggle, so win.minimap has
// no accelerator (registry entry only).
#pragma once

#include "spdf_internal.h"
#include "spdf_window.h"

G_BEGIN_DECLS

#define SPDF_TYPE_MINIMAP (spdf_minimap_get_type())
G_DECLARE_FINAL_TYPE(SpdfMinimap, spdf_minimap, SPDF, MINIMAP, GtkDrawingArea)

// Builds the strip for a tab and resolves its initial visibility from
// documents.json / the settings default into tab->show_minimap. Called from
// spdf_tab_open; the widget is owned by the tab's widget tree and detaches
// itself (signals via g_signal_connect_object, render contexts orphaned in
// dispose) when the page closes.
GtkWidget* spdf_minimap_new(SpdfTab* tab);

// Registers the stateful win.minimap action and keeps its state following the
// selected tab. Called from spdf_window_init after the tab view exists.
void spdf_minimap_install(SpdfWindow* win);

// Shows/hides the tab's minimap. persist writes the choice into
// documents.json (user toggles persist; session restore passes FALSE).
// Also refreshes the owning window's action state.
void spdf_minimap_set_visible(SpdfTab* tab, gboolean show, gboolean persist);

// Re-reads the selected tab into the win.minimap action state (enabled +
// boolean state). Cheap; called on tab selection changes.
void spdf_minimap_window_sync(SpdfWindow* win);

// The document behind the tab was rewritten in place or retargeted (rotate /
// OCR / Save As): drop every cached thumbnail and orphan in-flight thumbnail
// renders (the old render service may already be gone, so no cancels are
// issued against it). Called next to spdf_doc_view_document_changed.
void spdf_minimap_document_changed(SpdfTab* tab);

G_END_DECLS
