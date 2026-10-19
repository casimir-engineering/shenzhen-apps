/* spdf_win_minimap.h — minimap strip geometry and thumbnail budget, for Win32.
 *
 * WHAT THIS IS: a straight port of the GTK4 minimap's pure layer,
 * portable/linux/gtk4/spdf_minimap_internal.h, which is itself a port of
 * portable/mac/SPDFMacMinimapView.mm. Same relationship, and same rule, as
 * spdf_win_layout.h has to spdf_docview_internal.h: every function here has a
 * one-to-one counterpart there and must return BIT-IDENTICAL results for
 * identical inputs.
 *
 *   spdf_win_minimap_median_width      <- spdf_minimap_median_width      <- baseWidth (:121-130)
 *   spdf_win_minimap_point_scale       <- spdf_minimap_point_scale       <- layoutPointScaleForUsableWidth (:136-147)
 *   spdf_win_minimap_strip_compute     <- spdf_minimap_strip_compute     <- ensureMiniLayoutCacheForScale (:168-202)
 *   spdf_win_minimap_content_top       <- spdf_minimap_content_top       <- layoutScale: contentTop (:337-338)
 *   spdf_win_minimap_strip_visible_range <- spdf_minimap_strip_visible_range
 *   spdf_win_minimap_strip_y_for_document_y / _document_y_for_strip_y
 *                                      <- the same two, <- miniRectForDocumentIntersection (:240-256)
 *   spdf_win_minimap_viewport_rect     <- spdf_minimap_viewport_rect     <- unscrolledVisibleRectForScale (:276-306)
 *   spdf_win_minimap_viewport_band     <- (the same function's fallback branch)
 *   spdf_win_minimap_marker_y          <- spdf_minimap_marker_y
 *   spdf_win_minimap_thumb_window_*    <- spdf_minimap_thumb_window_*    <- SPDFMacMinimapWindow.mm
 *   spdf_win_minimap_thumb_zoom        <- (GTK4 keeps this in spdf_minimap.c) <- thumbnailRenderZoomForPage (:149-159)
 *
 * WHAT IS DELIBERATELY NOT PORTED. The GTK4 header also carries the kinetic
 * scroll decay, the long-document drag scale, the wheel-notch cap and the
 * directional page stride. Those are INPUT policy, they belong with whoever
 * owns WM_MOUSEWHEEL and the drag state machine, and porting them here would
 * put two owners in one file. They are listed above the line in
 * spdf_minimap_internal.h and are a small, mechanical addition when the input
 * layer wants them.
 *
 * WHAT CHANGED IN THE PORT: types only, exactly as in spdf_win_layout.h.
 * `SpdfPageSizePt`/`SpdfPageRect`/`SpdfLayout` become that header's
 * `SpdfWinPageSizePt`/`SpdfWinRect`/`SpdfWinLayout` (same fields, same order),
 * `gboolean` becomes `int`, `gsize` becomes `size_t`, and glib's MAX/MIN/CLAMP
 * macros become the static inline functions spdf_win_layout.h already spells
 * out with glib's exact tie and NaN behaviour. `g_new0` aborts on OOM where
 * calloc returns NULL, so a failed allocation leaves an empty strip instead of
 * terminating the process -- the same single behavioural difference
 * spdf_win_layout.h documents.
 *
 * UNITS. Strip space is DEVICE PIXELS of the minimap panel, y = 0 at the top of
 * the UNSCROLLED strip; the caller adds `content_top` when drawing or
 * hit-testing. Page sizes are PDF points. The panel width passed in is the
 * minimap rect's device-pixel width, so the 18/16/8/4 pt insets must be
 * DPI-scaled by the caller before they get here -- which is why every function
 * that needs one takes it as an argument instead of reading the macro. The
 * macros below are the POINT values, unscaled, exactly as macOS states them.
 *
 * TESTED BY: portable/win/tests/minimap_geometry_test.c (assertions +
 * transcript) and portable/win/tests/minimap_differential.c, which compiles the
 * REAL portable/linux/gtk4/spdf_minimap_internal.h beside this header in one
 * MSVC binary and compares every function with `==`. See
 * portable/win/tests/minimap-differential-native.cmd.
 */
#ifndef SPDF_WIN_MINIMAP_H
#define SPDF_WIN_MINIMAP_H

#include <math.h>
#include <stdlib.h>

#include "spdf_win_layout.h" /* SpdfWinPageSizePt, SpdfWinRect, SpdfWinLayout, clamp helpers */

#ifdef __cplusplus
extern "C" {
#endif

/* Strip geometry, in POINTS (SPDFMacMinimapView.mm:308-343, :112). */
#define SPDF_WIN_MINIMAP_GAP 4.0         /* between thumbnails */
#define SPDF_WIN_MINIMAP_SIDE_INSET 18.0 /* usable width = panel width - 18 */
#define SPDF_WIN_MINIMAP_EDGE_INSET 16.0 /* available height = panel height - 16 */
#define SPDF_WIN_MINIMAP_TOP_PAD 8.0     /* content top once the strip overflows */
#define SPDF_WIN_MINIMAP_MAX_WIDTH_RATIO 2.5

/* Thumbnail store budget, GTK4's MINIMAP_THUMB_MAX_BYTES. Small on purpose:
 * these are ~100x140 px pictures and the window below bounds how many exist. */
#define SPDF_WIN_MINIMAP_THUMB_MAX_BYTES ((size_t)32 * 1024 * 1024)

/* Bounded thumbnail window around the visible strip range. */
#define SPDF_WIN_MINIMAP_WINDOW_EXTRA_PAGES 30
#define SPDF_WIN_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES 15
#define SPDF_WIN_MINIMAP_WINDOW_EVICT_SLACK_PAGES 30

/* Search-hit tick height, same as the scrollbar heat-map lane. */
#define SPDF_WIN_MINIMAP_MARKER_TICK_H 3.0

/* One rect per page in unscrolled strip space, y monotonically increasing. */
typedef struct SpdfWinMinimapStrip {
    SpdfWinRect* rects; /* owned */
    int count;
    double content_h;
    double point_scale; /* strip px per PDF point for non-over-wide pages */
} SpdfWinMinimapStrip;

static SPDF_WIN_INLINE void spdf_win_minimap_strip_clear(SpdfWinMinimapStrip* strip) {
    if (!strip) return;
    free(strip->rects);
    strip->rects = NULL;
    strip->count = 0;
    strip->content_h = 0.0;
    strip->point_scale = 0.0;
}

/* Median page width in PDF points. Insertion sort: strips are small and this
 * runs on relayout only, and it is the sort the GTK header uses, so the tie
 * behaviour on equal widths is the same one. */
static SPDF_WIN_INLINE double spdf_win_minimap_median_width(const SpdfWinPageSizePt* sizes, int count) {
    double* widths;
    double median;
    int i;

    if (!sizes || count <= 0) return 0.0;
    widths = (double*)malloc(sizeof(double) * (size_t)count);
    if (!widths) return 0.0;
    for (i = 0; i < count; ++i) widths[i] = spdf_win_max_d(1.0, sizes[i].width);
    for (i = 1; i < count; ++i) {
        double v = widths[i];
        int j = i - 1;
        while (j >= 0 && widths[j] > v) {
            widths[j + 1] = widths[j];
            j--;
        }
        widths[j + 1] = v;
    }
    median = count % 2 == 1 ? widths[count / 2] : (widths[count / 2 - 1] + widths[count / 2]) * 0.5;
    free(widths);
    return median;
}

/* THE ONE THAT MATTERS ON A REAL DOCUMENT. Points -> strip px: usable width
 * over the widest page, except that a lone over-wide page is capped at 2.5x the
 * MEDIAN width so a single foldout cannot shrink every normal page to an
 * unreadable square. A uniform document keeps exactly usable/widest, so the
 * widest page fills the strip. */
static SPDF_WIN_INLINE double spdf_win_minimap_point_scale(const SpdfWinPageSizePt* sizes, int count, double usable) {
    double widest = 0.0;
    double median;
    double cap;
    double effective;
    int i;

    if (!sizes || count <= 0 || usable <= 1.0) return 0.0;
    for (i = 0; i < count; ++i) widest = spdf_win_max_d(widest, sizes[i].width);
    if (widest <= 0.0) return 0.0;
    median = spdf_win_minimap_median_width(sizes, count);
    cap = median > 0.0 ? SPDF_WIN_MINIMAP_MAX_WIDTH_RATIO * median : widest;
    effective = spdf_win_min_d(widest, cap);
    if (effective <= 0.0) effective = widest;
    return usable / effective;
}

/* Per-page strip rects: width = page width at the shared point scale, CLAMPED
 * to the usable strip width; height follows the clamped width so every page
 * keeps its own aspect; each rect centred horizontally in the panel.
 * `panel_w` and `gap` are device pixels. */
static SPDF_WIN_INLINE void spdf_win_minimap_strip_compute(SpdfWinMinimapStrip* strip, const SpdfWinPageSizePt* sizes,
                                                           int count, double panel_w, double side_inset, double gap) {
    double usable = spdf_win_max_d(1.0, panel_w - side_inset);
    double scale = spdf_win_minimap_point_scale(sizes, count, usable);
    double y = 0.0;
    int i;

    if (!strip) return;
    if (!sizes) count = 0;
    if (count != strip->count) {
        free(strip->rects);
        strip->rects = count > 0 ? (SpdfWinRect*)calloc((size_t)count, sizeof(SpdfWinRect)) : NULL;
        strip->count = count > 0 && !strip->rects ? 0 : count;
        count = strip->count;
    }
    strip->point_scale = scale;
    if (count <= 0 || scale <= 0.0) {
        strip->content_h = 0.0;
        return;
    }
    for (i = 0; i < count; ++i) {
        double src_w = spdf_win_max_d(1.0, sizes[i].width);
        double src_h = spdf_win_max_d(1.0, sizes[i].height);
        double w = spdf_win_max_d(1.0, spdf_win_min_d(src_w * scale, usable));
        double h = spdf_win_max_d(1.0, w * (src_h / src_w));
        strip->rects[i].x = floor((panel_w - w) * 0.5);
        strip->rects[i].y = y;
        strip->rects[i].w = w;
        strip->rects[i].h = h;
        y += h + gap;
    }
    strip->content_h = y - gap;
}

/* Where the strip starts in panel space: CENTRED when the whole strip fits,
 * otherwise the 8 pt top pad minus the scroll-proportional offset, so the strip
 * tracks the document. */
static SPDF_WIN_INLINE double spdf_win_minimap_content_top(double content_h, double panel_h, double edge_inset,
                                                           double top_pad, double scroll_fraction) {
    double available = spdf_win_max_d(1.0, panel_h - edge_inset);
    if (content_h < available) return floor((panel_h - content_h) * 0.5);
    scroll_fraction = spdf_win_clamp_d(scroll_fraction, 0.0, 1.0);
    return top_pad - scroll_fraction * (content_h - available);
}

/* Pages whose strip rect intersects the unscrolled band [y0, y1]. */
static SPDF_WIN_INLINE int spdf_win_minimap_strip_visible_range(const SpdfWinMinimapStrip* strip, double y0, double y1,
                                                                int* first, int* last) {
    SpdfWinLayout layout;
    if (!strip || strip->count <= 0) return 0;
    layout.rects = strip->rects;
    layout.count = strip->count;
    layout.canvas_w = 0.0;
    layout.canvas_h = strip->content_h;
    return spdf_win_layout_visible_range(&layout, y0, y1, first, last);
}

/* Document space <-> strip space. doc_y/doc_h are the document-space page slot
 * rows (content px at the current zoom, page-order, parallel to strip->rects).
 * A y inside a page maps fraction-preserving into its strip rect; a y in a gap
 * maps proportionally onto the strip gap; outside, it clamps to the ends. */
static SPDF_WIN_INLINE double spdf_win_minimap_strip_y_for_document_y(const SpdfWinMinimapStrip* strip,
                                                                      const double* doc_y, const double* doc_h,
                                                                      int count, double y) {
    int lo = 0;
    int hi = count - 1;

    if (!strip || strip->count != count || count <= 0 || !doc_y || !doc_h) return 0.0;
    if (y <= doc_y[0]) return strip->rects[0].y;
    if (y >= doc_y[count - 1] + doc_h[count - 1]) return strip->rects[count - 1].y + strip->rects[count - 1].h;
    while (lo < hi) { /* last page starting at or before y */
        int mid = lo + (hi - lo + 1) / 2;
        if (doc_y[mid] <= y)
            lo = mid;
        else
            hi = mid - 1;
    }
    if (y <= doc_y[lo] + doc_h[lo]) {
        double frac = doc_h[lo] > 0.0 ? (y - doc_y[lo]) / doc_h[lo] : 0.0;
        return strip->rects[lo].y + spdf_win_clamp_d(frac, 0.0, 1.0) * strip->rects[lo].h;
    }
    {
        double gap_start = doc_y[lo] + doc_h[lo];
        double gap_len = spdf_win_max_d(1.0, doc_y[lo + 1] - gap_start);
        double frac = spdf_win_clamp_d((y - gap_start) / gap_len, 0.0, 1.0);
        double strip_gap_start = strip->rects[lo].y + strip->rects[lo].h;
        return strip_gap_start + frac * spdf_win_max_d(0.0, strip->rects[lo + 1].y - strip_gap_start);
    }
}

static SPDF_WIN_INLINE double spdf_win_minimap_document_y_for_strip_y(const SpdfWinMinimapStrip* strip,
                                                                      const double* doc_y, const double* doc_h,
                                                                      int count, double strip_y) {
    int lo = 0;
    int hi = count - 1;

    if (!strip || strip->count != count || count <= 0 || !doc_y || !doc_h) return 0.0;
    if (strip_y <= strip->rects[0].y) return doc_y[0];
    if (strip_y >= strip->rects[count - 1].y + strip->rects[count - 1].h) return doc_y[count - 1] + doc_h[count - 1];
    while (lo < hi) {
        int mid = lo + (hi - lo + 1) / 2;
        if (strip->rects[mid].y <= strip_y)
            lo = mid;
        else
            hi = mid - 1;
    }
    if (strip_y <= strip->rects[lo].y + strip->rects[lo].h) {
        double frac = strip->rects[lo].h > 0.0 ? (strip_y - strip->rects[lo].y) / strip->rects[lo].h : 0.0;
        return doc_y[lo] + spdf_win_clamp_d(frac, 0.0, 1.0) * doc_h[lo];
    }
    {
        double strip_gap_start = strip->rects[lo].y + strip->rects[lo].h;
        double strip_gap_len = spdf_win_max_d(1.0, strip->rects[lo + 1].y - strip_gap_start);
        double frac = spdf_win_clamp_d((strip_y - strip_gap_start) / strip_gap_len, 0.0, 1.0);
        double doc_gap_start = doc_y[lo] + doc_h[lo];
        return doc_gap_start + frac * spdf_win_max_d(0.0, doc_y[lo + 1] - doc_gap_start);
    }
}

/* Viewport indicator in unscrolled strip space. Vertical: fraction-preserving
 * strip mapping, at least 10 px tall. Horizontal: the union of the visible
 * horizontal fraction of every page the band touches, mapped into its strip
 * rect and outset by 2 -- so zooming IN narrows the indicator, which is the
 * whole reason macOS unions per-page intersections instead of drawing a band. */
static SPDF_WIN_INLINE void spdf_win_minimap_viewport_rect(const SpdfWinMinimapStrip* strip, const double* doc_x,
                                                           const double* doc_y, const double* doc_w,
                                                           const double* doc_h, int count, double doc_left,
                                                           double doc_top, double doc_visible_w, double doc_visible_h,
                                                           double panel_w, double* x, double* y, double* w,
                                                           double* h) {
    double y0 = spdf_win_minimap_strip_y_for_document_y(strip, doc_y, doc_h, count, doc_top);
    double y1 = spdf_win_minimap_strip_y_for_document_y(strip, doc_y, doc_h, count, doc_top + doc_visible_h);
    double rx0 = 0.0;
    double rx1 = 0.0;
    int has_page = 0;
    int i;

    if (y) *y = y0;
    if (h) *h = spdf_win_max_d(10.0, y1 - y0);

    if (strip && strip->count == count && doc_x && doc_w && doc_visible_w > 0.0) {
        for (i = 0; i < count; ++i) {
            double frac0;
            double frac1;
            double px0;
            double px1;
            if (doc_y[i] + doc_h[i] < doc_top || doc_y[i] > doc_top + doc_visible_h) continue;
            if (doc_w[i] <= 0.0) continue;
            frac0 = spdf_win_clamp_d((doc_left - doc_x[i]) / doc_w[i], 0.0, 1.0);
            frac1 = spdf_win_clamp_d((doc_left + doc_visible_w - doc_x[i]) / doc_w[i], 0.0, 1.0);
            if (frac1 <= frac0) continue; /* page fully off-screen horizontally */
            px0 = strip->rects[i].x + frac0 * strip->rects[i].w;
            px1 = strip->rects[i].x + frac1 * strip->rects[i].w;
            if (!has_page) {
                rx0 = px0;
                rx1 = px1;
                has_page = 1;
            } else {
                rx0 = spdf_win_min_d(rx0, px0);
                rx1 = spdf_win_max_d(rx1, px1);
            }
        }
    }
    if (has_page) {
        rx0 = spdf_win_max_d(0.0, rx0 - 2.0);
        rx1 = spdf_win_min_d(panel_w, rx1 + 2.0);
        if (x) *x = rx0;
        if (w) *w = spdf_win_max_d(1.0, rx1 - rx0);
    } else {
        if (x) *x = 5.0;
        if (w) *w = spdf_win_max_d(1.0, panel_w - 10.0);
    }
}

/* The fallback the function above falls back TO, on its own, for a caller that
 * has the scroll fraction but not the per-page document rects
 * (SPDFMacMinimapView.mm:300-306: x = 5, width = panel - 10, height sized by
 * the visible fraction of the document, top by the scroll fraction). */
static SPDF_WIN_INLINE SpdfWinRect spdf_win_minimap_viewport_band(double panel_w, double content_h, double doc_h,
                                                                  double doc_visible_h, double scroll_fraction) {
    SpdfWinRect r;
    double fraction = spdf_win_clamp_d(doc_visible_h / spdf_win_max_d(1.0, doc_h), 0.02, 1.0);
    double height = spdf_win_max_d(10.0, fraction * content_h);
    double top = spdf_win_clamp_d(scroll_fraction, 0.0, 1.0) * spdf_win_max_d(0.0, content_h - height);
    if (top + height > content_h) top = spdf_win_max_d(0.0, content_h - height);
    r.x = 5.0;
    r.y = top;
    r.w = spdf_win_max_d(1.0, panel_w - 10.0);
    r.h = height;
    return r;
}

/* Search-hit tick y inside a page's strip rect, pinned fully inside it. */
static SPDF_WIN_INLINE double spdf_win_minimap_marker_y(const SpdfWinRect* rect, double match_center_y_pt,
                                                        double page_h_pt, double tick_h) {
    double frac = page_h_pt > 0.0 ? spdf_win_clamp_d(match_center_y_pt / page_h_pt, 0.0, 1.0) : 0.0;
    double y;
    if (!rect) return 0.0;
    y = rect->y + frac * rect->h - tick_h * 0.5;
    return spdf_win_clamp_d(y, rect->y, spdf_win_max_d(rect->y, rect->y + rect->h - tick_h));
}

/* Click hit-test in unscrolled strip space: the y band decides the page, x is
 * clamped into the rect. */
static SPDF_WIN_INLINE int spdf_win_minimap_page_hit(const SpdfWinMinimapStrip* strip, double x, double y_unscrolled,
                                                     int* page, double* x_fraction, double* y_fraction) {
    int i;
    if (!strip) return 0;
    for (i = 0; i < strip->count; ++i) {
        const SpdfWinRect* rect = &strip->rects[i];
        if (y_unscrolled < rect->y || y_unscrolled > rect->y + rect->h) continue;
        if (page) *page = i;
        if (x_fraction) *x_fraction = spdf_win_clamp_d((x - rect->x) / spdf_win_max_d(1.0, rect->w), 0.0, 1.0);
        if (y_fraction) *y_fraction = spdf_win_clamp_d((y_unscrolled - rect->y) / spdf_win_max_d(1.0, rect->h), 0.0, 1.0);
        return 1;
    }
    return 0;
}

/* --- the thumbnail budget ------------------------------------------------
 *
 * THIS IS THE PART THAT MAKES THE FEATURE FREE. Only pages inside the window
 * ever get a thumbnail; everything else draws the placeholder. The hysteresis
 * band keeps the window steady while scrolling inside it, so a scroll does not
 * churn 60 renders per frame. */
typedef struct SpdfWinMinimapThumbWindow {
    int start;
    int end; /* inclusive; end < start means empty */
} SpdfWinMinimapThumbWindow;

static SPDF_WIN_INLINE SpdfWinMinimapThumbWindow spdf_win_minimap_thumb_window_empty(void) {
    SpdfWinMinimapThumbWindow window;
    window.start = 0;
    window.end = -1;
    return window;
}

static SPDF_WIN_INLINE int spdf_win_minimap_thumb_window_valid(SpdfWinMinimapThumbWindow window) {
    return window.start >= 0 && window.end >= window.start;
}

static SPDF_WIN_INLINE int spdf_win_minimap_thumb_window_contains(SpdfWinMinimapThumbWindow window, int page) {
    return spdf_win_minimap_thumb_window_valid(window) && page >= window.start && page <= window.end;
}

static SPDF_WIN_INLINE int spdf_win_minimap_clamp_i(int v, int lo, int hi) {
    return v > hi ? hi : (v < lo ? lo : v);
}

static SPDF_WIN_INLINE SpdfWinMinimapThumbWindow spdf_win_minimap_thumb_window_for_visible_range(
    int page_count, int visible_first, int visible_last, SpdfWinMinimapThumbWindow previous) {
    SpdfWinMinimapThumbWindow window;

    if (page_count <= 0) return spdf_win_minimap_thumb_window_empty();
    if (visible_last < visible_first) {
        int swap = visible_first;
        visible_first = visible_last;
        visible_last = swap;
    }
    visible_first = spdf_win_minimap_clamp_i(visible_first, 0, page_count - 1);
    visible_last = spdf_win_minimap_clamp_i(visible_last, 0, page_count - 1);

    /* Keep the previous window while the visible range stays at least the
     * recenter margin inside both edges (the band is clamped to the document,
     * so sitting on the first or last page never forces a recenter). A previous
     * window from a longer document fails the bounds check and is recomputed. */
    if (spdf_win_minimap_thumb_window_valid(previous) && previous.end < page_count) {
        int margin_first = visible_first - SPDF_WIN_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES;
        int margin_last = visible_last + SPDF_WIN_MINIMAP_WINDOW_RECENTER_MARGIN_PAGES;
        if (margin_first < 0) margin_first = 0;
        if (margin_last > page_count - 1) margin_last = page_count - 1;
        if (margin_first >= previous.start && margin_last <= previous.end) return previous;
    }

    window.start = visible_first - SPDF_WIN_MINIMAP_WINDOW_EXTRA_PAGES;
    if (window.start < 0) window.start = 0;
    window.end = visible_last + SPDF_WIN_MINIMAP_WINDOW_EXTRA_PAGES;
    if (window.end > page_count - 1) window.end = page_count - 1;
    return window;
}

static SPDF_WIN_INLINE int spdf_win_minimap_thumb_window_should_evict(SpdfWinMinimapThumbWindow window, int page) {
    if (!spdf_win_minimap_thumb_window_valid(window)) return 0;
    return page < window.start - SPDF_WIN_MINIMAP_WINDOW_EVICT_SLACK_PAGES ||
           page > window.end + SPDF_WIN_MINIMAP_WINDOW_EVICT_SLACK_PAGES;
}

/* The zoom one page's thumbnail is rendered at: its CLAMPED display width over
 * its point width, so an over-wide page renders to the strip width and a normal
 * page renders at the shared point scale. Never larger than the slot, which is
 * what keeps a thumbnail a thumbnail (SPDFMacMinimapView.mm:149-159). */
static SPDF_WIN_INLINE double spdf_win_minimap_thumb_zoom(const SpdfWinPageSizePt* sizes, int count, int page,
                                                          double panel_w, double side_inset) {
    double usable = panel_w - side_inset;
    double scale;
    double display_w;
    if (!sizes || page < 0 || page >= count || sizes[page].width <= 0.0) return 0.0;
    if (usable <= 1.0) return 0.0;
    scale = spdf_win_minimap_point_scale(sizes, count, usable);
    if (scale <= 0.0) return 0.0;
    display_w = spdf_win_min_d(sizes[page].width * scale, usable);
    return display_w / sizes[page].width;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_MINIMAP_H */
