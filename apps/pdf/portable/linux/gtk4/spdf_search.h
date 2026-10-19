// spdf_search.c — the search subsystem: SpdfSearchController (one per tab,
// incremental cancellable background search with regex/multiline, match list
// with snippets + chapter indices for the sidebar/minimap modules), the
// window search bar (GtkSearchBar: entry, live counter, regex + multiline
// toggles, prev/next), type-anywhere / paste-to-search / selection-to-search
// key behaviors and the scrollbar heat-map lane.
//
// Provenance: GTK3 incremental search + counter (ShenzhenPDFGtk.c
// start_find_for_current_query @5061, update_find_controls @1988,
// find_search_key_press + type-anywhere key_press @9575); Mac post-freeze
// behaviors (ShenzhenPDFMac.mm focusFind/paste:/startSearchForText @12123,
// documentEscapeKeyDown @10115, nearestFindMatchIndexToCurrentViewport
// @10438, findScrollbarMarkers @6188).
#pragma once

#include "spdf_internal.h"
#include "spdf_search_internal.h"
#include "spdf_window.h"

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// SpdfSearchController — one per tab (owned by SpdfTab, created in
// spdf_tab_open). All entry points are main-thread; the page scan runs on a
// worker thread over its own core document and delivers batches via idles.

#define SPDF_TYPE_SEARCH_CONTROLLER (spdf_search_controller_get_type())
G_DECLARE_FINAL_TYPE(SpdfSearchController, spdf_search_controller, SPDF, SEARCH_CONTROLLER, GObject)

SpdfSearchController* spdf_search_controller_new(SpdfTab* tab);

// Incremental query (debounced 120ms like GTK3, byte-capped at
// SPDF_SEARCH_MAX_QUERY_BYTES). Persists into tab->search_text. reveal:
// scroll to the chosen match when the search lands (typed queries — GTK3
// passed reveal=TRUE; tab restore passes FALSE to keep the viewport still).
void spdf_search_controller_set_query(SpdfSearchController* c, const char* query, gboolean reveal);
const char* spdf_search_controller_get_query(SpdfSearchController* c);

// Regex / regex-multiline (GTK3 semantics incl. graceful invalid-pattern
// failure: matches empty, spdf_search_controller_error() carries the parser
// message). Toggling re-runs the search preferring the current page (GTK3
// find_regex_toggled). Persist into tab->search_regex(_multiline).
void spdf_search_controller_set_regex(SpdfSearchController* c, gboolean regex);
gboolean spdf_search_controller_get_regex(SpdfSearchController* c);
void spdf_search_controller_set_multiline(SpdfSearchController* c, gboolean multiline);
gboolean spdf_search_controller_get_multiline(SpdfSearchController* c);

// Match list access (document order). spdf_search_controller_match fills
// *out with borrowed data (snippet owned by the controller, valid until the
// next matches-changed). chapter_index groups matches for the sidebar.
guint spdf_search_controller_match_count(SpdfSearchController* c);
gboolean spdf_search_controller_match(SpdfSearchController* c, guint index, SpdfSearchMatch* out);

// Current match. set_current scrolls the doc view to the match and refreshes
// the highlight overlays; next/prev wrap around (GTK3 find_step) and start a
// search first when the query has no results yet (Mac findFromCurrentForward).
int spdf_search_controller_current(SpdfSearchController* c); // -1 = none
void spdf_search_controller_set_current(SpdfSearchController* c, int index);
void spdf_search_controller_next(SpdfSearchController* c);
void spdf_search_controller_prev(SpdfSearchController* c);

// Live counter string ("", "0 / 0", "3 / 17" — GTK3 update_find_controls).
void spdf_search_controller_counter(SpdfSearchController* c, char* buf, gsize len);

gboolean spdf_search_controller_is_searching(SpdfSearchController* c);
const char* spdf_search_controller_error(SpdfSearchController* c); // NULL when none

// Clears query, matches, highlights and error (Escape semantics).
void spdf_search_controller_clear(SpdfSearchController* c);

// Re-runs the persisted query without moving the viewport, preferring the
// stored tab->find_match_index (lazy session re-run; GTK3 deferred find on
// tab activation). No-op without a query.
void spdf_search_controller_refresh(SpdfSearchController* c);

// Cancels everything and forgets the tab; called by spdf_tab_close right
// before dropping its reference. Any in-flight worker results are discarded.
void spdf_search_controller_detach(SpdfSearchController* c);

// Signals:
//   "matches-changed" ()     — match list replaced/extended (also on clear
//                              and on failed search; check error()).
//   "current-changed" (int)  — current index moved (also -1 on clear).

// ---------------------------------------------------------------------------
// Per-tab widgets (called from spdf_tab.c).

// Thin heat-map lane overlaying the vertical scrollbar of the tab's
// scrolled window: one tick per match, proportional document layout, the
// current tick hotter (Mac findScrollbarMarkers + GTK3 draw_find_marker
// colors). Honors the showFindMarkers setting. Non-interactive.
GtkWidget* spdf_search_markers_new(SpdfTab* tab);

// ---------------------------------------------------------------------------
// Per-window search bar + key behaviors (called from spdf_window.c).

// Builds the GtkSearchBar (entry, counter label, prev/next, Regex +
// Multiline toggles — GTK3 had no case toggle: core search is always
// FZ_SEARCH_IGNORE_CASE) and wires: two-way toggle<->bar visibility binding,
// tab switching, type-anywhere (window-level printable keys), Ctrl+V
// paste-to-search, Escape handling. The caller packs the returned bar into
// its toolbar view.
GtkWidget* spdf_search_bar_new(SpdfWindow* win, GtkToggleButton* search_toggle);

// win.search (Ctrl+F): with a live selection, search it immediately
// (selection-to-search, Mac focusFind); otherwise reveal the bar, prefill
// from tab->search_text on first open (lazy session re-run, GTK3 tab switch),
// focus the entry and select-all.
void spdf_search_focus(SpdfWindow* win);

// win.find-next / win.find-prev on the current tab.
void spdf_search_find_next(SpdfWindow* win);
void spdf_search_find_prev(SpdfWindow* win);

// Escape in the canvas: clears the active search (query + highlights), hides
// the bar, refocuses the canvas. Returns TRUE when there was a search to
// clear (Mac documentEscapeKeyDown).
gboolean spdf_search_dismiss(SpdfWindow* win);

// Refresh the bar from the (newly selected) tab's controller.
void spdf_search_bar_sync(SpdfWindow* win);

// ---------------------------------------------------------------------------
// Doc-view integration, implemented in spdf_docview.c (search section there;
// declared here so spdf_internal.h stays untouched by this module).

// Hand the current match set to the view. pages/rects are parallel arrays in
// document order (page-space rects); the view copies them. current indexes
// into the arrays (-1 = none). All matches draw pale yellow, the current one
// hot yellow, in snapshot like the selection overlay.
void spdf_doc_view_set_search_matches(SpdfDocView* v, const int* pages, const spdf_rect* rects, int count,
                                      int current);
void spdf_doc_view_set_search_current(SpdfDocView* v, int current);

// Scroll so the match rect is centered in the viewport (Mac
// scrollToPageRect:pageIndex:), clamped to the scrollable range.
void spdf_doc_view_scroll_to_match(SpdfDocView* v, int page, const spdf_rect* rect);

// Layout accessors for nearest-match + heat-map math: the page slot rect in
// document space (content px at the current zoom) and the inclusive visible
// page range. Both return FALSE when the layout is not ready.
gboolean spdf_doc_view_page_slot(SpdfDocView* v, int page, double* x, double* y, double* w, double* h);
gboolean spdf_doc_view_visible_pages(SpdfDocView* v, int* first, int* last);

G_END_DECLS
