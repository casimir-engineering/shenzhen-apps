/* Pure strip-layout / viewport-mapping / thumbnail-window math for the GTK4
 * minimap. glib-only (no GTK includes) so the linux/gtk4/tests sources compile
 * the exact shipping logic against glib alone (same pattern as
 * spdf_docview_internal.h, which this header reuses for SpdfPageSizePt,
 * SpdfPageRect, SpdfLayout and the byte-bounded LRU). spdf_minimap.c is the
 * only GTK consumer.
 *
 * Ported semantics:
 *   spdf_minimap_median_width /
 *   spdf_minimap_point_scale          <- Mac SPDFMacMinimapView baseWidth +
 *                                        layoutPointScaleForUsableWidth (median
 *                                        base, kMinimapMaxWidthRatio 2.5 cap so
 *                                        one giant page cannot shrink the rest)
 *   spdf_minimap_strip_compute        <- Mac ensureMiniLayoutCacheForScale:gap:
 *                                        (per-page width clamped to the usable
 *                                        strip, height follows the clamped
 *                                        width so aspect is preserved) + GTK3
 *                                        minimap_measure (ShenzhenPDFGtk.c
 *                                        @5453)
 *   spdf_minimap_content_top          <- Mac layoutScale:... contentTop (center
 *                                        when the strip fits, else 8 - offset)
 *                                        == GTK3 minimap_measure content_top
 *   spdf_minimap_strip_visible_range  <- Mac visiblePageIndexesWithPaddingScreens
 *                                        via the shared spdf_layout_visible_range
 *   spdf_minimap_strip_y_for_document_y /
 *   spdf_minimap_document_y_for_strip_y
 *                                     <- Mac miniRectForDocumentIntersection +
 *                                        documentPointForUnscrolledMiniPoint
 *                                        (page-interior fractions preserved,
 *                                        gaps map onto gaps)
 *   spdf_minimap_viewport_rect        <- Mac unscrolledVisibleRectForScale
 *                                        (union of per-page miniRect
 *                                        intersections, -2 inset, so the
 *                                        indicator narrows when zoomed in;
 *                                        full-width >= 10px band fallback =
 *                                        GTK3 continuous branch)
 *   spdf_minimap_marker_y             <- Mac drawSearchRects page-fraction
 *                                        placement, reduced to the GTK4 tick
 *                                        model (3px tick pinned inside the slot)
 *   spdf_minimap_document_top_for_strip_scroll
 *                                     <- Mac commit db9515802
 *                                        (SPDFMacMinimapWindow.mm): scrolling ON
 *                                        the minimap moves the STRIP by the
 *                                        gesture distance and the document
 *                                        follows at maxDoc/maxStrip scale
 *   spdf_minimap_thumb_window_*       <- Mac SPDFMacMinimapWindow.mm
 *                                        spdf_minimap_window_* (visible range +
 *                                        30 extra pages, 15-page recenter
 *                                        hysteresis, 30-page evict slack)
 *   spdf_minimap_long_drag_scale /
 *   spdf_minimap_drag_thumb_height    <- Mac longDocumentDragScaleForDeltaY +
 *                                        longDocumentViewportDragThumbHeight
 *                                        (thumb sized against the TRACK) ==
 *                                        GTK3 minimap_long_document_drag_scale
 */
#pragma once

#include <glib.h>
#include <math.h>

#include "spdf_docview_internal.h"

G_BEGIN_DECLS

/* Strip geometry (Mac constants; the GTK3 file shared them). */
#define SPDF_MINIMAP_GAP 4.0         /* px between thumbnails */
#define SPDF_MINIMAP_SIDE_INSET 18.0 /* usable width = widget width - 18 */
#define SPDF_MINIMAP_EDGE_INSET 16.0 /* available height = widget height - 16 */
#define SPDF_MINIMAP_TOP_PAD 8.0     /* content top when the strip overflows */
#define SPDF_MINIMAP_MAX_WIDTH_RATIO 2.5

/* Thumbnail store budget (GTK3 MINIMAP_THUMB_MAX_BYTES). */
#define SPDF_MINIMAP_THUMB_MAX_BYTES ((gsize)32 * 1024 * 1024)

/* Bounded thumbnail window around the visible strip range (Mac). */
#define SPDF_MINIMAP_WINDOW_EXTRA_PAGES 30
#define SPDF_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES 15
#define SPDF_MINIMAP_WINDOW_EVICT_SLACK_PAGES 30

/* Long-document viewport drag (Mac; thresholds in PDF points / px per s). */
#define SPDF_MINIMAP_LONG_DOC_HEIGHT_PT 16000.0
#define SPDF_MINIMAP_DRAG_FINE_SPEED 180.0
#define SPDF_MINIMAP_DRAG_FULL_SPEED 300.0

/* Classic wheel notches -> strip px (Mac kMinimapWheelPointsPerLine). */
#define SPDF_MINIMAP_WHEEL_POINTS_PER_LINE 32.0

/* Search-hit tick height, same as the scrollbar heat-map lane. */
#define SPDF_MINIMAP_MARKER_TICK_H 3.0

/* ---------------------------------------------------------------------------
 * Strip layout: one rect per page in UNSCROLLED strip space (y starts at 0);
 * the widget adds content_top when drawing / hit-testing. */
typedef struct {
    SpdfPageRect* rects; /* owned; page-order, y monotonically increasing */
    int count;
    double content_h;
    double point_scale; /* strip px per PDF point for non-over-wide pages */
} SpdfMinimapStrip;

static inline void spdf_minimap_strip_clear(SpdfMinimapStrip* strip) {
    if (!strip) return;
    g_free(strip->rects);
    strip->rects = NULL;
    strip->count = 0;
    strip->content_h = 0.0;
    strip->point_scale = 0.0;
}

/* Median page width in PDF points; robust to a single huge-outlier page. */
static inline double spdf_minimap_median_width(const SpdfPageSizePt* sizes, int count) {
    double* widths;
    double median;

    if (!sizes || count <= 0) return 0.0;
    widths = g_new(double, count);
    for (int i = 0; i < count; ++i) widths[i] = MAX(1.0, sizes[i].width);
    for (int i = 1; i < count; ++i) { /* insertion sort; strips are small and this runs on relayout only */
        double v = widths[i];
        int j = i - 1;
        while (j >= 0 && widths[j] > v) {
            widths[j + 1] = widths[j];
            j--;
        }
        widths[j + 1] = v;
    }
    median = count % 2 == 1 ? widths[count / 2] : (widths[count / 2 - 1] + widths[count / 2]) * 0.5;
    g_free(widths);
    return median;
}

/* Shared points->strip-px scale: usable width over the widest page, but a
 * lone over-wide page is capped at 2.5x the median so it cannot shrink the
 * normal pages to unreadable squares. Uniform documents keep exactly
 * usable/widest (the widest page fills the strip). */
static inline double spdf_minimap_point_scale(const SpdfPageSizePt* sizes, int count, double usable) {
    double widest = 0.0;
    double median;
    double cap;
    double effective;

    if (!sizes || count <= 0 || usable <= 1.0) return 0.0;
    for (int i = 0; i < count; ++i) widest = MAX(widest, sizes[i].width);
    if (widest <= 0.0) return 0.0;
    median = spdf_minimap_median_width(sizes, count);
    cap = median > 0.0 ? SPDF_MINIMAP_MAX_WIDTH_RATIO * median : widest;
    effective = MIN(widest, cap);
    if (effective <= 0.0) effective = widest;
    return usable / effective;
}

/* Per-page strip rects: width = page width at the shared point scale, clamped
 * to the usable strip width; height follows the clamped width so every page
 * keeps its own aspect ratio; each rect is centered horizontally. */
static inline void spdf_minimap_strip_compute(SpdfMinimapStrip* strip, const SpdfPageSizePt* sizes, int count,
                                              double widget_w) {
    double usable = MAX(1.0, widget_w - SPDF_MINIMAP_SIDE_INSET);
    double scale = spdf_minimap_point_scale(sizes, count, usable);
    double y = 0.0;

    if (!strip) return;
    if (count != strip->count) {
        g_free(strip->rects);
        strip->rects = count > 0 ? g_new0(SpdfPageRect, count) : NULL;
        strip->count = count;
    }
    strip->point_scale = scale;
    if (count <= 0 || scale <= 0.0) {
        strip->content_h = 0.0;
        return;
    }
    for (int i = 0; i < count; ++i) {
        double src_w = MAX(1.0, sizes[i].width);
        double src_h = MAX(1.0, sizes[i].height);
        double w = MAX(1.0, MIN(src_w * scale, usable));
        double h = MAX(1.0, w * (src_h / src_w));
        strip->rects[i].x = floor((widget_w - w) * 0.5);
        strip->rects[i].y = y;
        strip->rects[i].w = w;
        strip->rects[i].h = h;
        y += h + SPDF_MINIMAP_GAP;
    }
    strip->content_h = y - SPDF_MINIMAP_GAP;
}

/* Where the strip content starts in widget space: centered when it fits the
 * widget, otherwise 8px minus the scroll-proportional offset so the strip
 * tracks the document position. */
static inline double spdf_minimap_content_top(double content_h, double widget_h, double scroll_fraction) {
    double available = MAX(1.0, widget_h - SPDF_MINIMAP_EDGE_INSET);
    if (content_h < available) return floor((widget_h - content_h) * 0.5);
    scroll_fraction = CLAMP(scroll_fraction, 0.0, 1.0);
    return SPDF_MINIMAP_TOP_PAD - scroll_fraction * (content_h - available);
}

/* Pages whose strip rect intersects the unscrolled band [y0, y1]. */
static inline gboolean spdf_minimap_strip_visible_range(const SpdfMinimapStrip* strip, double y0, double y1,
                                                        int* first, int* last) {
    SpdfLayout layout;
    if (!strip || strip->count <= 0) return FALSE;
    layout.rects = strip->rects;
    layout.count = strip->count;
    layout.canvas_w = 0.0;
    layout.canvas_h = strip->content_h;
    return spdf_layout_visible_range(&layout, y0, y1, first, last);
}

/* ---------------------------------------------------------------------------
 * Document space <-> strip space. doc_y/doc_h are the document-space page
 * slot rows (content px at the current zoom, page-order, parallel to
 * strip->rects). A y inside a page maps fraction-preserving into its strip
 * rect; a y in a gap maps proportionally into the strip gap; outside the
 * content it clamps to the strip ends. */
static inline double spdf_minimap_strip_y_for_document_y(const SpdfMinimapStrip* strip, const double* doc_y,
                                                         const double* doc_h, int count, double y) {
    int lo = 0;
    int hi = count - 1;

    if (!strip || strip->count != count || count <= 0 || !doc_y || !doc_h) return 0.0;
    if (y <= doc_y[0]) return strip->rects[0].y;
    if (y >= doc_y[count - 1] + doc_h[count - 1]) return strip->rects[count - 1].y + strip->rects[count - 1].h;
    while (lo < hi) { /* last page starting at or before y */
        int mid = lo + (hi - lo + 1) / 2;
        if (doc_y[mid] <= y) lo = mid;
        else hi = mid - 1;
    }
    if (y <= doc_y[lo] + doc_h[lo]) {
        double frac = doc_h[lo] > 0.0 ? (y - doc_y[lo]) / doc_h[lo] : 0.0;
        return strip->rects[lo].y + CLAMP(frac, 0.0, 1.0) * strip->rects[lo].h;
    }
    /* In the gap between lo and lo+1. */
    {
        double gap_start = doc_y[lo] + doc_h[lo];
        double gap_len = MAX(1.0, doc_y[lo + 1] - gap_start);
        double frac = CLAMP((y - gap_start) / gap_len, 0.0, 1.0);
        double strip_gap_start = strip->rects[lo].y + strip->rects[lo].h;
        return strip_gap_start + frac * MAX(0.0, strip->rects[lo + 1].y - strip_gap_start);
    }
}

/* Inverse mapping: an unscrolled strip y back into document space. */
static inline double spdf_minimap_document_y_for_strip_y(const SpdfMinimapStrip* strip, const double* doc_y,
                                                         const double* doc_h, int count, double strip_y) {
    int lo = 0;
    int hi = count - 1;

    if (!strip || strip->count != count || count <= 0 || !doc_y || !doc_h) return 0.0;
    if (strip_y <= strip->rects[0].y) return doc_y[0];
    if (strip_y >= strip->rects[count - 1].y + strip->rects[count - 1].h)
        return doc_y[count - 1] + doc_h[count - 1];
    while (lo < hi) {
        int mid = lo + (hi - lo + 1) / 2;
        if (strip->rects[mid].y <= strip_y) lo = mid;
        else hi = mid - 1;
    }
    if (strip_y <= strip->rects[lo].y + strip->rects[lo].h) {
        double frac = strip->rects[lo].h > 0.0 ? (strip_y - strip->rects[lo].y) / strip->rects[lo].h : 0.0;
        return doc_y[lo] + CLAMP(frac, 0.0, 1.0) * doc_h[lo];
    }
    {
        double strip_gap_start = strip->rects[lo].y + strip->rects[lo].h;
        double strip_gap_len = MAX(1.0, strip->rects[lo + 1].y - strip_gap_start);
        double frac = CLAMP((strip_y - strip_gap_start) / strip_gap_len, 0.0, 1.0);
        double doc_gap_start = doc_y[lo] + doc_h[lo];
        return doc_gap_start + frac * MAX(0.0, doc_y[lo + 1] - doc_gap_start);
    }
}

/* Viewport indicator in unscrolled strip space for the visible document rect
 * [doc_left, doc_left + doc_visible_w] x [doc_top, doc_top + doc_visible_h].
 *
 * Vertical: fraction-preserving strip mapping (gaps map onto gaps), at least
 * 10px tall. Horizontal: union of the visible horizontal fraction of every
 * page the band touches, mapped into its strip rect and inset by -2 like the
 * Mac (unscrolledVisibleRectForScale unions miniRectForDocumentIntersection
 * rects, so zooming IN narrows the indicator; the old GTK3 continuous branch
 * kept it full-width at every zoom). Falls back to the full-width band when
 * no page intersects the document band. */
static inline void spdf_minimap_viewport_rect(const SpdfMinimapStrip* strip, const double* doc_x,
                                              const double* doc_y, const double* doc_w, const double* doc_h,
                                              int count, double doc_left, double doc_top, double doc_visible_w,
                                              double doc_visible_h, double widget_w, double* x, double* y,
                                              double* w, double* h) {
    double y0 = spdf_minimap_strip_y_for_document_y(strip, doc_y, doc_h, count, doc_top);
    double y1 = spdf_minimap_strip_y_for_document_y(strip, doc_y, doc_h, count, doc_top + doc_visible_h);
    double rx0 = 0.0;
    double rx1 = 0.0;
    gboolean has_page = FALSE;

    if (y) *y = y0;
    if (h) *h = MAX(10.0, y1 - y0);

    if (strip && strip->count == count && doc_x && doc_w && doc_visible_w > 0.0) {
        for (int i = 0; i < count; ++i) {
            double frac0;
            double frac1;
            double px0;
            double px1;
            if (doc_y[i] + doc_h[i] < doc_top || doc_y[i] > doc_top + doc_visible_h) continue;
            if (doc_w[i] <= 0.0) continue;
            frac0 = CLAMP((doc_left - doc_x[i]) / doc_w[i], 0.0, 1.0);
            frac1 = CLAMP((doc_left + doc_visible_w - doc_x[i]) / doc_w[i], 0.0, 1.0);
            if (frac1 <= frac0) continue; /* page fully off-screen horizontally */
            px0 = strip->rects[i].x + frac0 * strip->rects[i].w;
            px1 = strip->rects[i].x + frac1 * strip->rects[i].w;
            if (!has_page) {
                rx0 = px0;
                rx1 = px1;
                has_page = TRUE;
            } else {
                rx0 = MIN(rx0, px0);
                rx1 = MAX(rx1, px1);
            }
        }
    }
    if (has_page) {
        rx0 = MAX(0.0, rx0 - 2.0);
        rx1 = MIN(widget_w, rx1 + 2.0);
        if (x) *x = rx0;
        if (w) *w = MAX(1.0, rx1 - rx0);
    } else {
        if (x) *x = 5.0;
        if (w) *w = MAX(1.0, widget_w - 10.0);
    }
}

/* Search-hit tick y inside a page's strip rect: the match center's page-space
 * fraction, with the tick pinned fully inside the rect. */
static inline double spdf_minimap_marker_y(const SpdfPageRect* rect, double match_center_y_pt, double page_h_pt,
                                           double tick_h) {
    double frac = page_h_pt > 0.0 ? CLAMP(match_center_y_pt / page_h_pt, 0.0, 1.0) : 0.0;
    double y;
    if (!rect) return 0.0;
    y = rect->y + frac * rect->h - tick_h * 0.5;
    return CLAMP(y, rect->y, MAX(rect->y, rect->y + rect->h - tick_h));
}

/* ---------------------------------------------------------------------------
 * Strip-scroll model (Mac db9515802): a plain scroll over the minimap moves
 * the STRIP by the gesture distance and the document follows at the scrollbar
 * ratio maxDocScroll/maxStripScroll, so the strip tracks the fingers 1:1 by
 * construction (its offset is derived from the document position). When the
 * whole strip fits, the scale falls back to documentHeight/contentHeight so
 * the gesture still moves the viewport indicator by its own distance. */
static inline double spdf_minimap_document_delta_for_strip_scroll(double strip_dy, double strip_content_h,
                                                                  double strip_available_h, double doc_h,
                                                                  double doc_visible_h) {
    double max_doc_scroll = doc_h - doc_visible_h;
    double max_strip_scroll;
    double doc_per_strip_px;

    if (max_doc_scroll <= 0.0 || strip_content_h <= 0.0) return 0.0;
    max_strip_scroll = strip_content_h - strip_available_h;
    doc_per_strip_px = max_strip_scroll > 0.0 ? max_doc_scroll / max_strip_scroll : doc_h / strip_content_h;
    return strip_dy * doc_per_strip_px;
}

static inline double spdf_minimap_document_top_for_strip_scroll(double current_doc_top, double strip_dy,
                                                                double strip_content_h, double strip_available_h,
                                                                double doc_h, double doc_visible_h) {
    double delta = spdf_minimap_document_delta_for_strip_scroll(strip_dy, strip_content_h, strip_available_h, doc_h,
                                                                doc_visible_h);
    double max_doc_scroll = MAX(0.0, doc_h - doc_visible_h);
    return MAX(0.0, MIN(current_doc_top + delta, max_doc_scroll));
}

/* Directional page stride for a discrete wheel cap. Adjacent page origins
 * include the layout gap; document edges fall back to the current page height. */
static inline double spdf_minimap_directional_page_stride(int current_page, double proposed_doc_delta,
                                                          const double* doc_y, const double* doc_h, int page_count) {
    int page;
    int adjacent;
    double stride = 0.0;

    if (!doc_y || !doc_h || page_count <= 0 || fabs(proposed_doc_delta) <= 0.0001) return 0.0;
    page = CLAMP(current_page, 0, page_count - 1);
    adjacent = proposed_doc_delta > 0.0 ? page + 1 : page - 1;
    if (adjacent >= 0 && adjacent < page_count)
        stride = proposed_doc_delta > 0.0 ? doc_y[adjacent] - doc_y[page] : doc_y[page] - doc_y[adjacent];
    if (!isfinite(stride) || stride <= 0.0) stride = doc_h[page];
    return isfinite(stride) ? MAX(0.0, stride) : 0.0;
}

/* Limit one discrete wheel event to one directional page stride. Precise
 * trackpad input and the kinetic tail do not call this helper. */
static inline double spdf_minimap_document_top_capped_for_discrete_wheel(double current_doc_top,
                                                                         double proposed_doc_top, int current_page,
                                                                         const double* doc_y, const double* doc_h,
                                                                         int page_count, double doc_height,
                                                                         double doc_visible_height) {
    double delta = proposed_doc_top - current_doc_top;
    double stride = spdf_minimap_directional_page_stride(current_page, delta, doc_y, doc_h, page_count);
    double max_doc_scroll = MAX(0.0, doc_height - doc_visible_height);

    if (stride > 0.0 && fabs(delta) > stride) proposed_doc_top = current_doc_top + copysign(stride, delta);
    return MAX(0.0, MIN(proposed_doc_top, max_doc_scroll));
}

/* ---------------------------------------------------------------------------
 * Kinetic strip-scroll momentum. The Mac gets momentum for free (AppKit
 * feeds momentumPhase scroll events through the same
 * sendStripScrollForEvent: path, SPDFMacMinimapView.mm); GTK only reports
 * the fling velocity ("decelerate" on a GTK_EVENT_CONTROLLER_SCROLL_KINETIC
 * controller), so the widget animates the decay itself on a frame-clock
 * tick. The decay model is GtkKineticScrolling's DECELERATING phase
 * (gtk/gtkkineticscrolling.c): per frame
 *     position += (1 - exp(-friction*dt)) * velocity / friction
 *     velocity *= exp(-friction*dt)
 * with the standard deceleration friction 4/s and the 1 px/s stop
 * threshold — a typical flick (a few hundred strip px/s) is spent after
 * roughly 1.5 s, matching GtkScrolledWindow's feel. */
#define SPDF_MINIMAP_KINETIC_FRICTION 4.0      /* GtkKineticScrolling DECELERATION_FRICTION, 1/s */
#define SPDF_MINIMAP_KINETIC_STOP_VELOCITY 1.0 /* strip px/s; below this the tail is invisible */

/* Advance the decay by dt seconds: returns the strip distance covered this
 * frame and decays *velocity in place. */
static inline double spdf_minimap_kinetic_step(double* velocity, double dt_s) {
    double exp_part;
    double delta;

    if (!velocity || !isfinite(dt_s) || dt_s <= 0.0) return 0.0;
    exp_part = exp(-SPDF_MINIMAP_KINETIC_FRICTION * dt_s);
    delta = (1.0 - exp_part) * *velocity / SPDF_MINIMAP_KINETIC_FRICTION;
    *velocity *= exp_part;
    return delta;
}

static inline gboolean spdf_minimap_kinetic_done(double velocity) {
    return fabs(velocity) < SPDF_MINIMAP_KINETIC_STOP_VELOCITY;
}

/* ---------------------------------------------------------------------------
 * Bounded thumbnail window (Mac SPDFMacMinimapWindow). Only pages inside the
 * window get thumbnails; the hysteresis band keeps the window steady while
 * scrolling within it. */
typedef struct {
    int start;
    int end; /* inclusive; end < start = invalid/empty */
} SpdfMinimapThumbWindow;

static inline SpdfMinimapThumbWindow spdf_minimap_thumb_window_empty(void) {
    SpdfMinimapThumbWindow window;
    window.start = 0;
    window.end = -1;
    return window;
}

static inline gboolean spdf_minimap_thumb_window_valid(SpdfMinimapThumbWindow window) {
    return window.start >= 0 && window.end >= window.start;
}

static inline gboolean spdf_minimap_thumb_window_contains(SpdfMinimapThumbWindow window, int page) {
    return spdf_minimap_thumb_window_valid(window) && page >= window.start && page <= window.end;
}

static inline SpdfMinimapThumbWindow spdf_minimap_thumb_window_for_visible_range(int page_count, int visible_first,
                                                                                 int visible_last,
                                                                                 SpdfMinimapThumbWindow previous) {
    SpdfMinimapThumbWindow window;

    if (page_count <= 0) return spdf_minimap_thumb_window_empty();
    if (visible_last < visible_first) {
        int swap = visible_first;
        visible_first = visible_last;
        visible_last = swap;
    }
    visible_first = CLAMP(visible_first, 0, page_count - 1);
    visible_last = CLAMP(visible_last, 0, page_count - 1);

    /* Hysteresis: keep the previous window while the visible range stays at
     * least the recenter margin inside both edges (band clamped to the
     * document, so sitting at the first/last page never forces a recenter).
     * A previous window from another (shorter) document fails the bounds
     * check and is recomputed. */
    if (spdf_minimap_thumb_window_valid(previous) && previous.end < page_count) {
        int margin_first = MAX(0, visible_first - SPDF_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES);
        int margin_last = MIN(page_count - 1, visible_last + SPDF_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES);
        if (margin_first >= previous.start && margin_last <= previous.end) return previous;
    }

    window.start = MAX(0, visible_first - SPDF_MINIMAP_WINDOW_EXTRA_PAGES);
    window.end = MIN(page_count - 1, visible_last + SPDF_MINIMAP_WINDOW_EXTRA_PAGES);
    return window;
}

static inline gboolean spdf_minimap_thumb_window_should_evict(SpdfMinimapThumbWindow window, int page) {
    if (!spdf_minimap_thumb_window_valid(window)) return FALSE;
    return page < window.start - SPDF_MINIMAP_WINDOW_EVICT_SLACK_PAGES ||
           page > window.end + SPDF_MINIMAP_WINDOW_EVICT_SLACK_PAGES;
}

/* ---------------------------------------------------------------------------
 * Long-document viewport drag. The drag thumb is sized as a fraction of the
 * TRACK (not of the strip content, which would overshoot and collapse the
 * drag range on 200+ page documents); slow drags move at a page-count-scaled
 * fine speed, fast drags accelerate to 1:1 through a smoothstep. */
static inline double spdf_minimap_total_height_pt(const SpdfPageSizePt* sizes, int count) {
    double total = 0.0;
    if (!sizes) return 0.0;
    for (int i = 0; i < count; ++i) total += MAX(1.0, sizes[i].height);
    return total;
}

static inline gboolean spdf_minimap_use_long_document_drag(const SpdfPageSizePt* sizes, int count) {
    return spdf_minimap_total_height_pt(sizes, count) > SPDF_MINIMAP_LONG_DOC_HEIGHT_PT;
}

static inline double spdf_minimap_smoothstep(double value) {
    value = CLAMP(value, 0.0, 1.0);
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}

static inline double spdf_minimap_long_drag_scale(double delta_y, double delta_t, int page_count) {
    double speed;
    double acceleration;
    double page_scale;

    if (!isfinite(delta_t) || delta_t <= 0.0) delta_t = 1.0 / 60.0;
    delta_t = CLAMP(delta_t, 1.0 / 240.0, 1.0 / 15.0);
    speed = fabs(delta_y) / delta_t;
    acceleration = spdf_minimap_smoothstep((speed - SPDF_MINIMAP_DRAG_FINE_SPEED) /
                                           (SPDF_MINIMAP_DRAG_FULL_SPEED - SPDF_MINIMAP_DRAG_FINE_SPEED));
    page_scale = CLAMP(20.0 / MAX(1, page_count), 0.30, 0.72);
    return page_scale + acceleration * (1.0 - page_scale);
}

static inline double spdf_minimap_drag_thumb_height(double doc_visible_h, double doc_h, double track_h) {
    double fraction = CLAMP(doc_visible_h / MAX(1.0, doc_h), 0.02, 1.0);
    return MIN(MAX(10.0, fraction * track_h), track_h);
}

/* ---------------------------------------------------------------------------
 * Click hit-test in unscrolled strip space (Mac pageHitForMiniPoint: y band
 * decides the page, x is clamped into the rect). */
static inline gboolean spdf_minimap_page_hit(const SpdfMinimapStrip* strip, double x, double y_unscrolled,
                                             int* page, double* x_fraction, double* y_fraction) {
    if (!strip) return FALSE;
    for (int i = 0; i < strip->count; ++i) {
        const SpdfPageRect* rect = &strip->rects[i];
        if (y_unscrolled < rect->y || y_unscrolled > rect->y + rect->h) continue;
        if (page) *page = i;
        if (x_fraction) *x_fraction = CLAMP((x - rect->x) / MAX(1.0, rect->w), 0.0, 1.0);
        if (y_fraction) *y_fraction = CLAMP((y_unscrolled - rect->y) / MAX(1.0, rect->h), 0.0, 1.0);
        return TRUE;
    }
    return FALSE;
}

G_END_DECLS
