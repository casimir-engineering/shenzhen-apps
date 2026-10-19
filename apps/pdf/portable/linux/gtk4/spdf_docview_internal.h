/* Pure layout / zoom-anchor / clamp / cache logic for the GTK4 document
 * canvas. glib-only (no GTK includes) so the linux/gtk4/tests sources compile
 * the exact shipping logic against glib alone. Everything is static inline;
 * spdf_docview.c and spdf_render.c both include this header.
 *
 * Ported semantics (provenance in the GTK3 file, portable/linux/ShenzhenPDFGtk.c):
 *   spdf_capped_render_zoom          <- capped_render_zoom
 *   spdf_layout_*                    <- render_current_page slot build +
 *                                       configure_page_image margins (22/13);
 *                                       every page is centered on the canvas
 *                                       midline (Mac SPDFDocumentView layout),
 *                                       which kills the June centering bug class
 *   spdf_layout_page_nearest_center  <- scroll_page_center_nearest
 *   spdf_fit_*_zoom                  <- render_current_page fit branch
 *   spdf_zoom_anchor_*               <- capture_zoom_anchor / zoom_anchor_scroll_idle,
 *                                       re-based into DOCUMENT space (page + PDF
 *                                       point). The June defect (zoom-anchor drift
 *                                       on pixel-capped giant sheets) came from
 *                                       anchoring against slot allocations that
 *                                       were rounded through capped_render_zoom;
 *                                       this layout never bakes the byte cap into
 *                                       geometry, so the anchor is exact.
 *   spdf_hscroll_clamp               <- clamp_horizontal_scroll. The scrollbar
 *                                       policy derives from the TOTAL content
 *                                       width vs the allocation (June bug fix),
 *                                       never from the current page alone.
 *   spdf_lru_*                       <- minimap_thumbnail_store/lookup +
 *                                       minimap_thumbnails_evict_over_budget,
 *                                       generalized for the render texture cache.
 */
#pragma once

#include <glib.h>
#include <math.h>

#include "shenzhen_pdf_core.h" /* spdf_rect (header-only use; tests do not link the core) */

G_BEGIN_DECLS

/* ---------------------------------------------------------------------------
 * Render byte cap. A single decoded page bitmap never exceeds this; the
 * render texture cache also defaults its total budget to it. */
#define SPDF_MAX_RENDER_SURFACE_BYTES ((gsize)(96 * 1024 * 1024))

/* Reduce the render zoom so the page bitmap never exceeds max_bytes; the
 * texture is drawn stretched back to the layout size, so geometry never
 * changes. Port of GTK3 capped_render_zoom. */
static inline double spdf_capped_render_zoom_for_cap(double render_zoom, double page_width,
                                                     double page_height, double max_bytes) {
    double bytes = page_width * page_height * render_zoom * render_zoom * 4.0;
    if (render_zoom <= 0.0 || page_width <= 0.0 || page_height <= 0.0) return render_zoom;
    if (bytes <= max_bytes) return render_zoom;
    return render_zoom * sqrt(max_bytes / bytes);
}

static inline double spdf_capped_render_zoom(double render_zoom, double page_width, double page_height) {
    return spdf_capped_render_zoom_for_cap(render_zoom, page_width, page_height,
                                           (double)SPDF_MAX_RENDER_SURFACE_BYTES);
}

/* ---------------------------------------------------------------------------
 * Continuous vertical layout. All coordinates are widget-content pixels
 * ("document space" at the current zoom, before the scroll translation). */

typedef struct {
    double width;  /* PDF points */
    double height; /* PDF points */
} SpdfPageSizePt;

typedef struct {
    double x;
    double y;
    double w;
    double h;
} SpdfPageRect;

typedef struct {
    SpdfPageRect* rects;
    int count;
    double canvas_w;
    double canvas_h;
} SpdfLayout;

/* GTK3 configure_page_image margins: 22px horizontal, 13px vertical per slot
 * (so 26px between pages, 13px above the first / below the last). */
#define SPDF_PAGE_MARGIN_H 22.0
#define SPDF_PAGE_MARGIN_V 13.0

static inline void spdf_layout_clear(SpdfLayout* layout) {
    if (!layout) return;
    g_free(layout->rects);
    layout->rects = NULL;
    layout->count = 0;
    layout->canvas_w = 0.0;
    layout->canvas_h = 0.0;
}

/* Builds the per-page slot rects: each slot hugs its own page's aspect
 * (page size * zoom, nothing else) and is centered on the canvas midline.
 * The canvas is as wide as max(viewport, widest page + margins), so a
 * mixed-size document keeps every page's center on one vertical axis. */
static inline void spdf_layout_compute(SpdfLayout* layout, const SpdfPageSizePt* sizes, int count,
                                       double zoom, double viewport_w, double margin_h, double margin_v) {
    double widest = 0.0;
    double y = margin_v;

    if (!layout) return;
    if (count != layout->count) {
        g_free(layout->rects);
        layout->rects = count > 0 ? g_new0(SpdfPageRect, count) : NULL;
        layout->count = count;
    }
    for (int i = 0; i < count; ++i) {
        double w = MAX(1.0, sizes[i].width * zoom);
        if (w > widest) widest = w;
    }
    layout->canvas_w = MAX(viewport_w, widest + 2.0 * margin_h);
    for (int i = 0; i < count; ++i) {
        double w = MAX(1.0, sizes[i].width * zoom);
        double h = MAX(1.0, sizes[i].height * zoom);
        layout->rects[i].x = (layout->canvas_w - w) * 0.5;
        layout->rects[i].y = y;
        layout->rects[i].w = w;
        layout->rects[i].h = h;
        y += h + 2.0 * margin_v;
    }
    layout->canvas_h = count > 0 ? y - margin_v : 0.0;
}

/* Binary search over the (monotonically increasing) page centers for the
 * page whose center is nearest y_mid; earlier page wins ties. Port of GTK3
 * scroll_page_center_nearest. */
static inline int spdf_layout_page_nearest_center(const SpdfLayout* layout, double y_mid) {
    int lo = 0;
    int hi;

    if (!layout || layout->count <= 0) return -1;
    hi = layout->count - 1;
    while (lo < hi) {
        int mid = lo + (hi - lo) / 2;
        double center = layout->rects[mid].y + layout->rects[mid].h * 0.5;
        if (center < y_mid) lo = mid + 1;
        else hi = mid;
    }
    if (lo > 0) {
        double prev = layout->rects[lo - 1].y + layout->rects[lo - 1].h * 0.5;
        double cur = layout->rects[lo].y + layout->rects[lo].h * 0.5;
        if (fabs(prev - y_mid) <= fabs(cur - y_mid)) lo--;
    }
    return lo;
}

/* Pages intersecting the vertical band [y0, y1] (slot rects, margins
 * excluded). Returns FALSE when nothing intersects. */
static inline gboolean spdf_layout_visible_range(const SpdfLayout* layout, double y0, double y1,
                                                 int* first, int* last) {
    int lo;
    int hi;

    if (!layout || layout->count <= 0 || y1 <= y0) return FALSE;
    lo = spdf_layout_page_nearest_center(layout, y0);
    hi = spdf_layout_page_nearest_center(layout, y1);
    while (lo > 0 && layout->rects[lo - 1].y + layout->rects[lo - 1].h > y0) lo--;
    while (lo < layout->count - 1 && layout->rects[lo].y + layout->rects[lo].h <= y0) lo++;
    while (hi < layout->count - 1 && layout->rects[hi + 1].y < y1) hi++;
    while (hi > 0 && layout->rects[hi].y >= y1) hi--;
    if (layout->rects[lo].y >= y1 || layout->rects[lo].y + layout->rects[lo].h <= y0) return FALSE;
    if (first) *first = lo;
    if (last) *last = MAX(lo, hi);
    return TRUE;
}

/* ---------------------------------------------------------------------------
 * Fit-mode zoom. Port of the render_current_page fit branch: fit-width and
 * fit-page use no padding (GTK3 zeroed the margins in those modes), the
 * result is clamped to the zoom bounds. Returns 0.0 when the viewport is too
 * small to trust (GTK3 guard: allocation <= 80) so callers keep the current
 * zoom. */
#define SPDF_MIN_ZOOM 0.10
#define SPDF_MAX_ZOOM 8.0

static inline double spdf_fit_width_zoom(double page_w, double viewport_w) {
    if (page_w <= 0.0 || viewport_w <= 80.0) return 0.0;
    return CLAMP(viewport_w / page_w, SPDF_MIN_ZOOM, SPDF_MAX_ZOOM);
}

static inline double spdf_fit_page_zoom(double page_w, double page_h, double viewport_w, double viewport_h) {
    if (page_w <= 0.0 || page_h <= 0.0 || viewport_w <= 80.0 || viewport_h <= 80.0) return 0.0;
    return CLAMP(MIN(viewport_w / page_w, viewport_h / page_h), SPDF_MIN_ZOOM, SPDF_MAX_ZOOM);
}

/* Mac fit-mode popup "Fit Height" (SPDFFitModeHeight): the page height fills
 * the viewport height. */
static inline double spdf_fit_height_zoom(double page_h, double viewport_h) {
    if (page_h <= 0.0 || viewport_h <= 80.0) return 0.0;
    return CLAMP(viewport_h / page_h, SPDF_MIN_ZOOM, SPDF_MAX_ZOOM);
}

/* ---------------------------------------------------------------------------
 * Cursor-anchored zoom, in document space. The anchor is a (page, PDF point)
 * pair plus the viewport point it sat under; after a relayout at the new zoom
 * the scroll is re-derived so that document point returns under the same
 * viewport point. Because slot rects are pure page*zoom (the render byte cap
 * only shrinks textures, never geometry), the anchor is exact on giant
 * pixel-capped sheets too. */
typedef struct {
    gboolean valid;
    int page;
    double page_x; /* PDF points */
    double page_y;
    double viewport_x;
    double viewport_y;
} SpdfZoomAnchor;

/* Resolves a viewport point to the nearest page (clamped to its bounds when
 * the point is over the margins). Port of capture_zoom_anchor. Fails open:
 * anchor->valid stays FALSE without a resolvable page. */
static inline void spdf_zoom_anchor_capture(SpdfZoomAnchor* anchor, const SpdfLayout* layout,
                                            const SpdfPageSizePt* sizes, double zoom, double viewport_x,
                                            double viewport_y, double scroll_x, double scroll_y) {
    double content_x = viewport_x + scroll_x;
    double content_y = viewport_y + scroll_y;
    int best_page = -1;
    double best_distance = 0.0;
    double anchor_x;
    double anchor_y;
    const SpdfPageRect* best = NULL;

    if (!anchor) return;
    anchor->valid = FALSE;
    if (!layout || layout->count <= 0 || zoom <= 0.0) return;

    for (int i = 0; i < layout->count; ++i) {
        const SpdfPageRect* rect = &layout->rects[i];
        double dx = 0.0;
        double dy = 0.0;
        double distance;
        if (content_x < rect->x) dx = rect->x - content_x;
        else if (content_x > rect->x + rect->w) dx = content_x - (rect->x + rect->w);
        if (content_y < rect->y) dy = rect->y - content_y;
        else if (content_y > rect->y + rect->h) dy = content_y - (rect->y + rect->h);
        distance = dx * dx + dy * dy;
        if (best_page < 0 || distance < best_distance) {
            best_page = i;
            best_distance = distance;
            best = rect;
        }
        if (distance == 0.0) break;
    }
    if (best_page < 0 || !best) return;

    anchor_x = MAX(best->x, MIN(content_x, best->x + best->w));
    anchor_y = MAX(best->y, MIN(content_y, best->y + best->h));
    anchor_x = (anchor_x - best->x) / zoom;
    anchor_y = (anchor_y - best->y) / zoom;
    if (sizes) {
        anchor_x = MAX(0.0, MIN(anchor_x, sizes[best_page].width));
        anchor_y = MAX(0.0, MIN(anchor_y, sizes[best_page].height));
    }
    anchor->page = best_page;
    anchor->page_x = anchor_x;
    anchor->page_y = anchor_y;
    anchor->viewport_x = viewport_x;
    anchor->viewport_y = viewport_y;
    anchor->valid = TRUE;
}

/* Scroll targets that put the anchored document point back under the anchored
 * viewport point in the new layout, clamped to the scrollable range. Port of
 * zoom_anchor_scroll_idle. */
static inline gboolean spdf_zoom_anchor_apply(const SpdfZoomAnchor* anchor, const SpdfLayout* layout,
                                              double zoom, double viewport_w, double viewport_h,
                                              double* scroll_x, double* scroll_y) {
    const SpdfPageRect* rect;
    double target_h;
    double target_v;

    if (!anchor || !anchor->valid || !layout || anchor->page < 0 || anchor->page >= layout->count) return FALSE;
    rect = &layout->rects[anchor->page];
    target_h = rect->x + anchor->page_x * zoom - anchor->viewport_x;
    target_v = rect->y + anchor->page_y * zoom - anchor->viewport_y;
    target_h = MAX(0.0, MIN(target_h, MAX(0.0, layout->canvas_w - viewport_w)));
    target_v = MAX(0.0, MIN(target_v, MAX(0.0, layout->canvas_h - viewport_h)));
    if (scroll_x) *scroll_x = target_h;
    if (scroll_y) *scroll_y = target_v;
    return TRUE;
}

/* ---------------------------------------------------------------------------
 * Horizontal scroll clamp policy. Port of clamp_horizontal_scroll:
 *  - scrollable (scrollbar policy) derives from the TOTAL content width vs
 *    the allocation, never from the current page (June bug: with the policy
 *    keyed on the current page a document holding one wide sheet blew the
 *    viewport up to that width and pushed every narrower page off screen);
 *  - a current page that fits the viewport is pinned centered;
 *  - a wider page pans within its own bounds only. */
typedef struct {
    gboolean scrollable; /* content wider than the viewport: show the h scrollbar */
    double value;        /* clamped/centered adjustment value */
} SpdfHScrollClamp;

static inline SpdfHScrollClamp spdf_hscroll_clamp(const SpdfLayout* layout, int current_page,
                                                  double viewport_w, double value) {
    SpdfHScrollClamp result;
    const SpdfPageRect* rect;
    double max_value;

    result.scrollable = layout && layout->canvas_w > viewport_w + 0.5;
    result.value = value;
    if (!layout || layout->count <= 0 || viewport_w <= 1.0) return result;
    if (current_page < 0 || current_page >= layout->count) current_page = 0;
    rect = &layout->rects[current_page];
    if (rect->w <= 1.0) return result;

    if (rect->w <= viewport_w + 0.5) {
        result.value = rect->x + rect->w * 0.5 - viewport_w * 0.5;
    } else {
        double page_min = rect->x;
        double page_max = rect->x + rect->w - viewport_w;
        result.value = MAX(page_min, MIN(value, page_max));
    }
    max_value = MAX(0.0, layout->canvas_w - viewport_w);
    result.value = MAX(0.0, MIN(result.value, max_value));
    return result;
}

/* ---------------------------------------------------------------------------
 * Byte-bounded LRU cache. Port of the minimap thumbnail store generalized for
 * the render texture cache: keyed hash table, per-entry byte size, total kept
 * under a cap by evicting the least recently used entries — but never below
 * one entry, so a single oversized item is still usable. */
typedef struct {
    gpointer value;
    gsize bytes;
    guint64 last_used;
    GDestroyNotify destroy;
} SpdfLruEntry;

typedef struct {
    GHashTable* table; /* key (owned by table) -> SpdfLruEntry* */
    gsize cap_bytes;
    gsize total_bytes;
    guint64 use_counter;
    GDestroyNotify key_destroy;
    GDestroyNotify value_destroy;
} SpdfLruCache;

static inline void spdf_lru_entry_free(gpointer data) {
    SpdfLruEntry* entry = (SpdfLruEntry*)data;
    if (!entry) return;
    if (entry->destroy && entry->value) entry->destroy(entry->value);
    g_free(entry);
}

static inline void spdf_lru_init(SpdfLruCache* cache, gsize cap_bytes, GHashFunc hash, GEqualFunc equal,
                                 GDestroyNotify key_destroy, GDestroyNotify value_destroy) {
    if (!cache) return;
    cache->table = g_hash_table_new_full(hash, equal, key_destroy, spdf_lru_entry_free);
    cache->cap_bytes = cap_bytes;
    cache->total_bytes = 0;
    cache->use_counter = 0;
    cache->key_destroy = key_destroy;
    cache->value_destroy = value_destroy;
}

static inline guint spdf_lru_size(const SpdfLruCache* cache) {
    return cache && cache->table ? g_hash_table_size(cache->table) : 0;
}

static inline gsize spdf_lru_bytes(const SpdfLruCache* cache) {
    return cache ? cache->total_bytes : 0;
}

static inline void spdf_lru_evict_over_budget(SpdfLruCache* cache) {
    if (!cache || !cache->table) return;
    while (cache->total_bytes > cache->cap_bytes && g_hash_table_size(cache->table) > 1) {
        GHashTableIter iter;
        gpointer key;
        gpointer value;
        gpointer oldest_key = NULL;
        SpdfLruEntry* oldest = NULL;
        g_hash_table_iter_init(&iter, cache->table);
        while (g_hash_table_iter_next(&iter, &key, &value)) {
            SpdfLruEntry* entry = (SpdfLruEntry*)value;
            if (!oldest || entry->last_used < oldest->last_used) {
                oldest = entry;
                oldest_key = key;
            }
        }
        if (!oldest) break;
        cache->total_bytes -= MIN(cache->total_bytes, oldest->bytes);
        g_hash_table_remove(cache->table, oldest_key);
    }
}

/* Looks up a value and bumps its recency. Returns NULL when absent. */
static inline gpointer spdf_lru_lookup(SpdfLruCache* cache, gconstpointer key) {
    SpdfLruEntry* entry;
    if (!cache || !cache->table) return NULL;
    entry = (SpdfLruEntry*)g_hash_table_lookup(cache->table, key);
    if (!entry) return NULL;
    entry->last_used = ++cache->use_counter;
    return entry->value;
}

/* Inserts (or replaces) an entry. Ownership of key and value transfers to the
 * cache; the previous value under the same key is destroyed. */
static inline void spdf_lru_insert(SpdfLruCache* cache, gpointer key, gpointer value, gsize bytes) {
    SpdfLruEntry* entry;
    if (!cache || !cache->table) return;
    entry = (SpdfLruEntry*)g_hash_table_lookup(cache->table, key);
    if (entry) {
        /* Replace in place; the table keeps its original key, the caller's
         * duplicate key is released. */
        cache->total_bytes -= MIN(cache->total_bytes, entry->bytes);
        if (entry->destroy && entry->value) entry->destroy(entry->value);
        entry->value = value;
        entry->bytes = bytes;
        entry->destroy = cache->value_destroy;
        entry->last_used = ++cache->use_counter;
        if (cache->key_destroy) cache->key_destroy(key);
    } else {
        entry = g_new0(SpdfLruEntry, 1);
        entry->value = value;
        entry->bytes = bytes;
        entry->destroy = cache->value_destroy;
        entry->last_used = ++cache->use_counter;
        g_hash_table_insert(cache->table, key, entry);
    }
    cache->total_bytes += bytes;
    spdf_lru_evict_over_budget(cache);
}

static inline void spdf_lru_set_cap(SpdfLruCache* cache, gsize cap_bytes) {
    if (!cache) return;
    cache->cap_bytes = cap_bytes;
    spdf_lru_evict_over_budget(cache);
}

static inline void spdf_lru_remove_all(SpdfLruCache* cache) {
    if (!cache || !cache->table) return;
    g_hash_table_remove_all(cache->table);
    cache->total_bytes = 0;
}

static inline void spdf_lru_deinit(SpdfLruCache* cache) {
    if (!cache || !cache->table) return;
    g_hash_table_destroy(cache->table);
    cache->table = NULL;
    cache->total_bytes = 0;
}

/* ---------------------------------------------------------------------------
 * Crop regime decision: pages taller/wider than 2x the viewport render only
 * the visible region at full scale (plus the capped whole-page base). */
static inline gboolean spdf_slot_needs_crop(const SpdfPageRect* rect, double viewport_w, double viewport_h) {
    if (!rect || viewport_w <= 0.0 || viewport_h <= 0.0) return FALSE;
    return rect->h > 2.0 * viewport_h || rect->w > 2.0 * viewport_w;
}

/* ---------------------------------------------------------------------------
 * Cursor regions. Port of the Mac model (SPDFMacCursorRegions.mm
 * spdf_cursor_region_at_point + ShenzhenPDFMac.mm
 * buildCursorRegionsForPageIfNeeded): per-page link and text-line rects in
 * page space (PDF points), built ONCE per page off the main thread — the
 * link set includes plain-text URLs (spdf_page_link_rects with
 * detect_text_links=1, which builds the page's stext and would stall the
 * main thread for hundreds of ms on dense pages). */

/* Matches spdf_link_at_point's 2pt text-URL slop (Mac kSPDFCursorLinkHitPadding),
 * so what hover shows as a hand is exactly what a click follows. */
#define SPDF_CURSOR_LINK_HIT_PADDING 2.0
/* Mac kSPDFCursorRegionMaxLinkRects. */
#define SPDF_CURSOR_REGION_MAX_LINK_RECTS 512

typedef enum {
    SPDF_CURSOR_REGION_NONE = 0,
    SPDF_CURSOR_REGION_LINK,
    SPDF_CURSOR_REGION_TEXT,
} SpdfCursorRegionKind;

static inline gboolean spdf_cursor_rect_empty(const spdf_rect* rect) {
    return !rect || rect->x1 <= rect->x0 || rect->y1 <= rect->y0;
}

/* Merge policy for the worker-built region arrays (Mac
 * buildCursorRegionsForPageIfNeeded skips NSIsEmptyRect rects): only
 * non-empty rects enter the cache, so a degenerate rect from the core can
 * never own a hit test. Returns TRUE when the rect was appended. */
static inline gboolean spdf_cursor_region_append_rect(GArray* rects /* spdf_rect */, const spdf_rect* rect) {
    if (!rects || spdf_cursor_rect_empty(rect)) return FALSE;
    g_array_append_vals(rects, rect, 1);
    return TRUE;
}

static inline gboolean spdf_cursor_rect_contains(const spdf_rect* rect, double x, double y, double slop) {
    return rect && x >= rect->x0 - slop && x <= rect->x1 + slop && y >= rect->y0 - slop && y <= rect->y1 + slop;
}

/* Link beats text beats none (SPDFMacCursorRegions.mm
 * spdf_cursor_region_at_point); only link rects get the padding slop. */
static inline SpdfCursorRegionKind spdf_cursor_region_at_point(const spdf_rect* links, guint link_count,
                                                               const spdf_rect* text, guint text_count, double x,
                                                               double y, double link_padding) {
    for (guint i = 0; i < link_count; ++i)
        if (spdf_cursor_rect_contains(&links[i], x, y, link_padding)) return SPDF_CURSOR_REGION_LINK;
    for (guint i = 0; i < text_count; ++i)
        if (spdf_cursor_rect_contains(&text[i], x, y, 0.0)) return SPDF_CURSOR_REGION_TEXT;
    return SPDF_CURSOR_REGION_NONE;
}

G_END_DECLS
