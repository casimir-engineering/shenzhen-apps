/* spdf_win_annot.h — the annotations track's document-facing half: the comment
 * cache, the markers' geometry for this paint, the overlays that draw them, and
 * the Comments section's rows.
 *
 * WHAT THE OTHER TWO FRONTENDS DO, and what this keeps of each. GTK caches
 * spdf_load_comments per tab (spdf_annot.c annot_refresh_comments), pushes one
 * badge per comment to the doc view as a snapshot overlay, and rebuilds the
 * sidebar's comments pane from the cache through a hook; the mac keeps
 * `_comments` on the reader, hit-tests it on hover for the bubble
 * (SPDFMacDocumentView.mm updateHoveredCommentForEvent:) and lists it in
 * rebuildSidebar. Both draw the markers over the page, both read the cache on
 * the UI thread against the document the UI thread owns. So does this.
 *
 * ONE CACHE FOR THE PROCESS, like the find session and the panel bridge, because
 * there is one window per process and the paint sees one selected document. It
 * is keyed on (document handle, path) and re-read when either changes or when
 * the file's stat changes underneath -- which is what the watcher's reload
 * looks like from here, and the app's own save too. spdf_win_annot_invalidate()
 * forces the re-read the frame after a write.
 *
 * NOTHING HERE RUNS ON THE FIRST PAINT OF A DOCUMENT. spdf_load_comments loads
 * every page of the document to walk its annotations; on the launch path that
 * is the walk the launch budget forbids (windows-launch-performance.md). GTK
 * defers it to an idle; here the first sync for a new document ARMS the load
 * and reports it deferred, the caller invalidates, and the next frame loads --
 * so the first page is on screen before the walk begins, and the markers and
 * the Comments segment appear one frame later. A cache made dirty by a write
 * reloads at once: the reader is waiting on that one.
 *
 * GEOMETRY IS PUBLISHED, NOT QUERIED. The router knows no page; the paint that
 * drew the pages hands over each comment's mark in CLIENT device pixels
 * (spdf_win_annot_publish_geometry) and the router tests against those
 * (spdf_win_annot_marks.h) -- spdf_win_chrome.h's rule that hit-testing and
 * painting agree only if they use the same rects, applied here by making the
 * painted rects the tested rects. The overlay producer is the third in the
 * chain find -> selection -> comments and follows the same
 * "take the base, append, re-point" convention spdf_win_selection.h states.
 *
 * C-callable so the tests are plain C; implemented in spdf_win_annot.cpp.
 */
#ifndef SPDF_WIN_ANNOT_H
#define SPDF_WIN_ANNOT_H

#include "shenzhen_pdf_core.h"
#include "spdf_win_d2d.h"          /* spdf_win_scene, SpdfWinAnnotMark via spdf_win_chrome.h */
#include "spdf_win_sidebar_view.h" /* SpdfWinSidebarResultsView */

#ifdef __cplusplus
extern "C" {
#endif

/* --- the cache -------------------------------------------------------------- */

/* Sync the cache to the selected document. `frame` is the caller's paint
 * counter: a document seen for the first time in frame N loads in frame N+1
 * (see the header), and *out_deferred is set to 1 in frame N so the caller can
 * ask for that next frame. A dirty cache (after a write, or a changed stat)
 * loads at once. NULL doc releases everything. Returns the comment count. */
int spdf_win_annot_sync(spdf_document* doc, const char* utf8_path, unsigned frame, int* out_deferred);

/* The count, loading NOW when the cache is not current -- for a caller that
 * is about to show the number (Properties) rather than paint a frame. */
int spdf_win_annot_count(spdf_document* doc, const char* utf8_path);

/* The frame after a write: forget what is loaded so the next sync re-reads. */
void spdf_win_annot_invalidate(void);

/* The loaded comments (count 0 when nothing is loaded) and one by index. */
const spdf_comments* spdf_win_annot_comments(void);
const spdf_comment_item* spdf_win_annot_item(int comment_index);

/* The comment under the pointer as the last hover routed it, or -1 --
 * shared between the tooltip and the sidebar's highlighted row. */
void spdf_win_annot_set_hover(int comment_index);
int spdf_win_annot_hover(void);

/* --- this paint's geometry -------------------------------------------------- */

/* From the scene the canvas just built (pages in CANVAS-LOCAL px), the canvas
 * rect's client origin and the zoom (device px per PDF point), publish one
 * mark per comment on a drawn page (client px) and remember the page frames
 * for the inverse mapping below. Call once per paint, after build_scene. */
void spdf_win_annot_publish_geometry(const spdf_win_scene* scene, float canvas_x, float canvas_y, float zoom);
const SpdfWinAnnotMark* spdf_win_annot_marks(int* out_count);

/* A client point to (page, PDF points) against the last published frames.
 * Returns 1 when the point is inside a drawn page, 0 otherwise. */
int spdf_win_annot_client_to_page(float client_x, float client_y, int* page_index, float* page_x, float* page_y);

/* THE THIRD OVERLAY PRODUCER. Call after spdf_win_find_apply_overlays() and
 * spdf_win_canvas_apply_selection_overlays(): takes the scene's overlays as a
 * base, appends a COMMENT frame and a COMMENT_BADGE per comment on a drawn
 * page, and re-points the scene. The array is this module's and stays valid
 * until the next call. A no-op with nothing loaded. */
void spdf_win_annot_apply_overlays(spdf_win_scene* scene, float zoom);

/* --- the Comments section --------------------------------------------------- */

/* The rows: a HEADER "Page N" whenever the page changes (the Search
 * section's grouping rule over pages rather than chapters,
 * spdf_win_sidebar_group_append) and a MATCH row per comment -- title
 * "author: text" (GTK comments_rebuild), subtitle "<type> - Page N",
 * match_index = the comment index. `filter` is matched against the mac's
 * haystack (title, author, type, "p.N"). Rebuilt only when the cache or the
 * filter changed; the scroll offset is kept and clamped to `list_h_px`. The
 * current row is the hovered comment's. Returns a view valid until the next
 * build; NULL when nothing is loaded. */
const SpdfWinSidebarResultsView* spdf_win_annot_sidebar_build(const wchar_t* filter, float list_h_px, float dpi_scale);
/* Wheel over the list; non-zero when the offset moved. */
int spdf_win_annot_sidebar_scroll_by(float dy, float list_h_px, float dpi_scale);
/* The comment a LIST-LOCAL y (scroll included) lands on, or -1 for a header
 * or empty space -- through the same row heights the painter used. */
int spdf_win_annot_sidebar_comment_at(float local_y, float dpi_scale);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_ANNOT_H */
