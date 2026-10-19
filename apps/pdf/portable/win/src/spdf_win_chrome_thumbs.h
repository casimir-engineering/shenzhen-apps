/* spdf_win_chrome_thumbs.h — the minimap's thumbnail store.
 *
 * THE WHOLE POINT OF THIS FILE IS THAT THE PAINTER NEVER RENDERS. macOS keeps a
 * bounded window of minimap images and falls back to a cheap placeholder outside
 * it (SPDFMacMinimapView.mm:762-770 says exactly why: drawing full page bitmaps
 * in the minimap forces whole-image decodes that cost >100 ms across a strip).
 * This is that policy on Windows, built out of machinery that already exists:
 *
 *   - spdf_win_render.h's worker pool does the rendering, at WARM priority, with
 *     coalescing, generation invalidation and cooperative cancellation. Its
 *     threads are spawned lazily on the first request, so a document whose
 *     minimap is hidden -- and every headless --render-png -- starts none.
 *   - spdf_win_lru.h holds the finished RGBA under a byte cap
 *     (SPDF_WIN_MINIMAP_THUMB_MAX_BYTES, 32 MB, GTK4's figure).
 *   - spdf_win_minimap.h's thumb window decides WHICH pages may have one at all,
 *     with the 15-page hysteresis that stops a scroll from re-queueing the world
 *     every frame.
 *
 * PAGE SIZES ARE MEASURED OFF THE UI THREAD. The strip needs every page's size
 * in points, and measuring a page means loading it. Doing that for a 117-page
 * scan on the first paint would put a visible stall exactly where the launch
 * path is. So one dedicated thread with its own spdf_document sweeps the
 * document and publishes sizes as it goes, and until a page is measured the
 * strip uses page 0's size for it -- which is macOS's own placeholder geometry
 * pass (ShenzhenPDFMac.mm:5352-5370, fallback 612x792).
 *
 * All of the UI-thread entry points are cheap and none of them blocks:
 * `lookup` is an LRU probe, `request` moves a window and posts at most a
 * handful of tasks, `drain` is O(1) per completion.
 */
#ifndef SPDF_WIN_CHROME_THUMBS_H
#define SPDF_WIN_CHROME_THUMBS_H

#include "spdf_win_chrome_content.h" /* SpdfWinMinimapThumb */
#include "spdf_win_layout.h"         /* SpdfWinPageSizePt */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpdfWinThumbStore SpdfWinThumbStore;

/* `utf8_path` is copied. Opens nothing, starts nothing, allocates one struct:
 * the document handle, the sizing thread and the render service all appear on
 * first use. NULL on allocation failure, and every function below tolerates a
 * NULL store so a failed store degrades to placeholders. */
SpdfWinThumbStore* spdf_win_thumbs_new(const char* utf8_path);
void spdf_win_thumbs_free(SpdfWinThumbStore* store);

/* Page count, or 0 while it is not known yet. Cheap after the first call. */
int spdf_win_thumbs_page_count(SpdfWinThumbStore* store);

/* Fills `out` with `count` page sizes in PDF points, using page 0's size (or
 * 612x792) for pages the sizing sweep has not reached. Returns how many are
 * REAL measurements, which is only used for diagnostics and for deciding
 * whether the strip is still converging. */
int spdf_win_thumbs_page_sizes(SpdfWinThumbStore* store, SpdfWinPageSizePt* out, int count);

/* UI thread. Adopts finished renders into the cache. Returns how many. */
int spdf_win_thumbs_drain(SpdfWinThumbStore* store);

/* UI thread, paint path. An LRU probe: 1 and `out` filled when this page's
 * thumbnail exists, 0 when it does not (draw the placeholder). Never renders,
 * never waits. */
int spdf_win_thumbs_lookup(SpdfWinThumbStore* store, int page, SpdfWinMinimapThumb* out);

/* UI thread, paint path. Moves the bounded window to cover [first, last] and
 * queues the pages inside it that have neither pixels nor a render in flight.
 * `dark` selects the render flags; changing it drops the cache, because a
 * light-theme thumbnail beside a dark-theme canvas is the defect
 * spdf_win_render.h's flags-in-the-key rule exists to prevent. */
void spdf_win_thumbs_request(SpdfWinThumbStore* store, const SpdfWinPageSizePt* sizes, int count, int first, int last,
                            double panel_w, double side_inset, int dark);

/* Diagnostics, for the report and for the tests: how many thumbnails have been
 * adopted, and how many render tasks the pool has started. Never used to make a
 * drawing decision. */
unsigned long long spdf_win_thumbs_stat_ready(SpdfWinThumbStore* store);
unsigned long long spdf_win_thumbs_stat_started(SpdfWinThumbStore* store);

/* TEMPORARY, and the only line in this track that knows a window exists.
 * A thumbnail arrives on a worker thread milliseconds to seconds after the
 * frame that asked for it, so something has to ask for a repaint or the strip
 * stays grey until the next mouse move. The canvas does this by PostMessage-ing
 * the HWND its window layer handed it; this track has no such handle, so the
 * store remembers the top-level windows of the thread that PAINTS and
 * invalidates them when a thumbnail lands. Call this from the paint path (it is
 * a no-op after the first call, and a no-op in a headless process, where the
 * painting thread owns no windows). spdf_win_paint() itself still needs no
 * HWND: this is the store's side channel, not the painter's. */
void spdf_win_thumbs_note_paint_thread(SpdfWinThumbStore* store);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_CHROME_THUMBS_H */
