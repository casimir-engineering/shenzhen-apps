/* spdf_win_layout.h — continuous-scroll page geometry for the Win32 frontend.
 *
 * WHAT THIS IS: a straight port of the GTK4 frontend's pure layout layer,
 * portable/linux/gtk4/spdf_docview_internal.h. Every function below has a
 * one-to-one counterpart there and is required to return bit-identical results
 * for identical inputs; portable/win/tests/layout_geometry_test.c pins those
 * numbers, and portable/win/tests/gtk_differential.c compares this header
 * against the real GTK one in a single binary -- run it natively with
 * portable/win/tests/layout-differential-native.cmd (395,514 comparisons, 0
 * mismatches). There is no layout_transcript_test.c; this header cited one for
 * a long time and no such file has ever existed.
 *
 *   spdf_win_capped_render_zoom*   <- spdf_capped_render_zoom*
 *   spdf_win_layout_*              <- spdf_layout_*
 *   spdf_win_fit_*_zoom            <- spdf_fit_*_zoom
 *   spdf_win_zoom_anchor_*         <- spdf_zoom_anchor_*
 *   spdf_win_hscroll_clamp         <- spdf_hscroll_clamp
 *   spdf_win_slot_needs_crop       <- spdf_slot_needs_crop
 *
 * The GTK layer in turn ports the mac SPDFDocumentView semantics, so the three
 * frontends agree on where a page sits, which pages a viewport shows, what
 * "fit width" means, and where a cursor-anchored zoom lands. That agreement is
 * the entire point: a bug fixed on one platform stays fixed on the others only
 * while the arithmetic is the same arithmetic.
 *
 * WHAT CHANGED IN THE PORT: types only. `graphene_rect_t`/`GdkRectangle` and
 * the glib integer typedefs are gone; this header includes nothing but the C
 * standard library and is compiled by both clang and MSVC as C and as C++.
 * `gboolean` becomes plain `int` (glib's own definition), `gsize` becomes
 * `size_t`, and glib's MAX/MIN/CLAMP macros become static inline functions with
 * glib's exact tie/NaN behaviour rather than the macros themselves, so a
 * `MAX(a, b++)` style double evaluation can never be introduced later.
 *
 * FLOATING POINT: nothing here is order-sensitive by accident, but the
 * transcript test's cross-toolchain byte-equality does depend on the host
 * compiler not fusing `a * b + c` into an FMA. MSVC under /fp:precise (the
 * guest build's setting) does not contract; clang does by default, so the macOS
 * side of that test compiles with -ffp-contract=off. Both compilers then
 * evaluate the same operations in the same order and IEEE-754 does the rest.
 *
 * Header-only on purpose. It has no state, no allocator policy beyond
 * malloc/free for the page-rect array, and both spdf_win_render.c and the
 * window/D2D code include it.
 */
#ifndef SPDF_WIN_LAYOUT_H
#define SPDF_WIN_LAYOUT_H

#include <math.h>
#include <stddef.h>
#include <stdlib.h>

/* MSVC accepts C99 `inline` in C mode only in its conforming preprocessor/
 * language modes; `__inline` has meant the same thing in every version and
 * costs nothing to spell. */
#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_INLINE __inline
#else
#define SPDF_WIN_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * glib arithmetic helpers, spelled out.
 *
 * glib defines MAX(a,b) as `((a) > (b) ? (a) : (b))` and
 * CLAMP(x,lo,hi) as `((x) > (hi) ? (hi) : ((x) < (lo) ? (lo) : (x)))`.
 * The comparison order matters at the edges: CLAMP with hi < lo yields hi, and
 * any comparison against NaN is false so MAX(NaN, b) is b. Reproducing the
 * expressions exactly keeps those corners identical to the GTK build. */

static SPDF_WIN_INLINE double spdf_win_max_d(double a, double b) {
    return a > b ? a : b;
}
static SPDF_WIN_INLINE double spdf_win_min_d(double a, double b) {
    return a < b ? a : b;
}
static SPDF_WIN_INLINE double spdf_win_clamp_d(double x, double lo, double hi) {
    return x > hi ? hi : (x < lo ? lo : x);
}

/* ---------------------------------------------------------------------------
 * Render byte cap. A single decoded page bitmap never exceeds this; the
 * rendered-page cache (spdf_win_lru.h) defaults its total budget to it too. */
#define SPDF_WIN_MAX_RENDER_SURFACE_BYTES ((size_t)(96 * 1024 * 1024))

/* Reduce the render zoom so the page bitmap never exceeds max_bytes. The
 * texture is drawn stretched back to the layout size, so GEOMETRY NEVER
 * CHANGES — that separation is what makes the zoom anchor exact on giant
 * pixel-capped sheets. Port of spdf_capped_render_zoom_for_cap. */
static SPDF_WIN_INLINE double spdf_win_capped_render_zoom_for_cap(double render_zoom, double page_width,
                                                                  double page_height, double max_bytes) {
    double bytes = page_width * page_height * render_zoom * render_zoom * 4.0;
    if (render_zoom <= 0.0 || page_width <= 0.0 || page_height <= 0.0) return render_zoom;
    if (bytes <= max_bytes) return render_zoom;
    return render_zoom * sqrt(max_bytes / bytes);
}

static SPDF_WIN_INLINE double spdf_win_capped_render_zoom(double render_zoom, double page_width, double page_height) {
    return spdf_win_capped_render_zoom_for_cap(render_zoom, page_width, page_height,
                                               (double)SPDF_WIN_MAX_RENDER_SURFACE_BYTES);
}

/* ---------------------------------------------------------------------------
 * Continuous vertical layout. All coordinates are content pixels ("document
 * space" at the current zoom, before the scroll translation). */

typedef struct {
    double width;  /* PDF points */
    double height; /* PDF points */
} SpdfWinPageSizePt;

typedef struct {
    double x;
    double y;
    double w;
    double h;
} SpdfWinRect;

typedef struct {
    SpdfWinRect* rects;
    int count;
    double canvas_w;
    double canvas_h;
} SpdfWinLayout;

/* 22px horizontal and 13px vertical margin per slot (so 26px between pages,
 * 13px above the first and below the last), from GTK3 configure_page_image. */
#define SPDF_WIN_PAGE_MARGIN_H 22.0
#define SPDF_WIN_PAGE_MARGIN_V 13.0

static SPDF_WIN_INLINE void spdf_win_layout_clear(SpdfWinLayout* layout) {
    if (!layout) return;
    free(layout->rects);
    layout->rects = NULL;
    layout->count = 0;
    layout->canvas_w = 0.0;
    layout->canvas_h = 0.0;
}

/* Builds the per-page slot rects: each slot hugs its own page's aspect (page
 * size * zoom, nothing else) and is centred on the canvas midline. The canvas
 * is as wide as max(viewport, widest page + margins), so a mixed-size document
 * keeps every page's centre on one vertical axis.
 *
 * The reallocation rule is the GTK one: the array is reused whenever the page
 * count is unchanged. `g_new0` aborts on OOM where malloc returns NULL, so this
 * port adds the only behavioural difference in the file — a failed allocation
 * leaves an empty layout rather than terminating the process. */
static SPDF_WIN_INLINE void spdf_win_layout_compute(SpdfWinLayout* layout, const SpdfWinPageSizePt* sizes, int count,
                                                    double zoom, double viewport_w, double margin_h, double margin_v) {
    double widest = 0.0;
    double y = margin_v;
    int i;

    if (!layout) return;
    if (!sizes) count = 0;
    if (count != layout->count) {
        free(layout->rects);
        layout->rects = count > 0 ? (SpdfWinRect*)calloc((size_t)count, sizeof(SpdfWinRect)) : NULL;
        layout->count = count > 0 && !layout->rects ? 0 : count;
        count = layout->count;
    }
    for (i = 0; i < count; ++i) {
        double w = spdf_win_max_d(1.0, sizes[i].width * zoom);
        if (w > widest) widest = w;
    }
    layout->canvas_w = spdf_win_max_d(viewport_w, widest + 2.0 * margin_h);
    for (i = 0; i < count; ++i) {
        double w = spdf_win_max_d(1.0, sizes[i].width * zoom);
        double h = spdf_win_max_d(1.0, sizes[i].height * zoom);
        layout->rects[i].x = (layout->canvas_w - w) * 0.5;
        layout->rects[i].y = y;
        layout->rects[i].w = w;
        layout->rects[i].h = h;
        y += h + 2.0 * margin_v;
    }
    layout->canvas_h = count > 0 ? y - margin_v : 0.0;
}

/* Binary search over the (monotonically increasing) page centres for the page
 * whose centre is nearest y_mid; the earlier page wins ties. Port of
 * spdf_layout_page_nearest_center. */
static SPDF_WIN_INLINE int spdf_win_layout_page_nearest_center(const SpdfWinLayout* layout, double y_mid) {
    int lo = 0;
    int hi;

    if (!layout || layout->count <= 0) return -1;
    hi = layout->count - 1;
    while (lo < hi) {
        int mid = lo + (hi - lo) / 2;
        double center = layout->rects[mid].y + layout->rects[mid].h * 0.5;
        if (center < y_mid)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo > 0) {
        double prev = layout->rects[lo - 1].y + layout->rects[lo - 1].h * 0.5;
        double cur = layout->rects[lo].y + layout->rects[lo].h * 0.5;
        if (fabs(prev - y_mid) <= fabs(cur - y_mid)) lo--;
    }
    return lo;
}

/* Pages intersecting the vertical band [y0, y1] (slot rects, margins excluded).
 * Returns 0 when nothing intersects. Port of spdf_layout_visible_range. */
static SPDF_WIN_INLINE int spdf_win_layout_visible_range(const SpdfWinLayout* layout, double y0, double y1, int* first,
                                                         int* last) {
    int lo;
    int hi;

    if (!layout || layout->count <= 0 || y1 <= y0) return 0;
    lo = spdf_win_layout_page_nearest_center(layout, y0);
    hi = spdf_win_layout_page_nearest_center(layout, y1);
    while (lo > 0 && layout->rects[lo - 1].y + layout->rects[lo - 1].h > y0) lo--;
    while (lo < layout->count - 1 && layout->rects[lo].y + layout->rects[lo].h <= y0) lo++;
    while (hi < layout->count - 1 && layout->rects[hi + 1].y < y1) hi++;
    while (hi > 0 && layout->rects[hi].y >= y1) hi--;
    if (layout->rects[lo].y >= y1 || layout->rects[lo].y + layout->rects[lo].h <= y0) return 0;
    if (first) *first = lo;
    if (last) *last = lo > hi ? lo : hi;
    return 1;
}

/* ---------------------------------------------------------------------------
 * Fit-mode zoom. Fit-width and fit-page use no padding (GTK3 zeroed the margins
 * in those modes) and clamp to the zoom bounds. Returns 0.0 when the viewport
 * is too small to trust (the GTK3 `allocation <= 80` guard) so callers keep the
 * zoom they already have rather than snapping to something absurd during the
 * first layout pass of a window that has not been sized yet. */
#define SPDF_WIN_MIN_ZOOM 0.10
#define SPDF_WIN_MAX_ZOOM 8.0

static SPDF_WIN_INLINE double spdf_win_fit_width_zoom(double page_w, double viewport_w) {
    if (page_w <= 0.0 || viewport_w <= 80.0) return 0.0;
    return spdf_win_clamp_d(viewport_w / page_w, SPDF_WIN_MIN_ZOOM, SPDF_WIN_MAX_ZOOM);
}

static SPDF_WIN_INLINE double spdf_win_fit_page_zoom(double page_w, double page_h, double viewport_w,
                                                     double viewport_h) {
    if (page_w <= 0.0 || page_h <= 0.0 || viewport_w <= 80.0 || viewport_h <= 80.0) return 0.0;
    return spdf_win_clamp_d(spdf_win_min_d(viewport_w / page_w, viewport_h / page_h), SPDF_WIN_MIN_ZOOM,
                            SPDF_WIN_MAX_ZOOM);
}

/* Mac fit-mode popup "Fit Height" (SPDFFitModeHeight). */
static SPDF_WIN_INLINE double spdf_win_fit_height_zoom(double page_h, double viewport_h) {
    if (page_h <= 0.0 || viewport_h <= 80.0) return 0.0;
    return spdf_win_clamp_d(viewport_h / page_h, SPDF_WIN_MIN_ZOOM, SPDF_WIN_MAX_ZOOM);
}

/* ---------------------------------------------------------------------------
 * Cursor-anchored zoom, in DOCUMENT space. The anchor is a (page, PDF point)
 * pair plus the viewport point it sat under; after a relayout at the new zoom
 * the scroll is re-derived so that document point returns under the same
 * viewport point. Because slot rects are pure page*zoom — the render byte cap
 * only shrinks textures, never geometry — the anchor is exact on giant
 * pixel-capped sheets too, which is the defect this design was written to
 * remove on the GTK side. */
typedef struct {
    int valid;
    int page;
    double page_x; /* PDF points */
    double page_y;
    double viewport_x;
    double viewport_y;
} SpdfWinZoomAnchor;

/* Resolves a viewport point to the nearest page, clamped to that page's bounds
 * when the point is over the margins. Fails open: `valid` stays 0 when no page
 * can be resolved. Port of spdf_zoom_anchor_capture. */
static SPDF_WIN_INLINE void spdf_win_zoom_anchor_capture(SpdfWinZoomAnchor* anchor, const SpdfWinLayout* layout,
                                                         const SpdfWinPageSizePt* sizes, double zoom, double viewport_x,
                                                         double viewport_y, double scroll_x, double scroll_y) {
    double content_x = viewport_x + scroll_x;
    double content_y = viewport_y + scroll_y;
    int best_page = -1;
    double best_distance = 0.0;
    double anchor_x;
    double anchor_y;
    const SpdfWinRect* best = NULL;
    int i;

    if (!anchor) return;
    anchor->valid = 0;
    if (!layout || layout->count <= 0 || zoom <= 0.0) return;

    for (i = 0; i < layout->count; ++i) {
        const SpdfWinRect* rect = &layout->rects[i];
        double dx = 0.0;
        double dy = 0.0;
        double distance;
        if (content_x < rect->x)
            dx = rect->x - content_x;
        else if (content_x > rect->x + rect->w)
            dx = content_x - (rect->x + rect->w);
        if (content_y < rect->y)
            dy = rect->y - content_y;
        else if (content_y > rect->y + rect->h)
            dy = content_y - (rect->y + rect->h);
        distance = dx * dx + dy * dy;
        if (best_page < 0 || distance < best_distance) {
            best_page = i;
            best_distance = distance;
            best = rect;
        }
        if (distance == 0.0) break;
    }
    if (best_page < 0 || !best) return;

    anchor_x = spdf_win_max_d(best->x, spdf_win_min_d(content_x, best->x + best->w));
    anchor_y = spdf_win_max_d(best->y, spdf_win_min_d(content_y, best->y + best->h));
    anchor_x = (anchor_x - best->x) / zoom;
    anchor_y = (anchor_y - best->y) / zoom;
    if (sizes) {
        anchor_x = spdf_win_max_d(0.0, spdf_win_min_d(anchor_x, sizes[best_page].width));
        anchor_y = spdf_win_max_d(0.0, spdf_win_min_d(anchor_y, sizes[best_page].height));
    }
    anchor->page = best_page;
    anchor->page_x = anchor_x;
    anchor->page_y = anchor_y;
    anchor->viewport_x = viewport_x;
    anchor->viewport_y = viewport_y;
    anchor->valid = 1;
}

/* Scroll targets that put the anchored document point back under the anchored
 * viewport point in the new layout, clamped to the scrollable range. Returns 0
 * when the anchor cannot be applied. Port of spdf_zoom_anchor_apply. */
static SPDF_WIN_INLINE int spdf_win_zoom_anchor_apply(const SpdfWinZoomAnchor* anchor, const SpdfWinLayout* layout,
                                                      double zoom, double viewport_w, double viewport_h,
                                                      double* scroll_x, double* scroll_y) {
    const SpdfWinRect* rect;
    double target_h;
    double target_v;

    if (!anchor || !anchor->valid || !layout || anchor->page < 0 || anchor->page >= layout->count) return 0;
    rect = &layout->rects[anchor->page];
    target_h = rect->x + anchor->page_x * zoom - anchor->viewport_x;
    target_v = rect->y + anchor->page_y * zoom - anchor->viewport_y;
    target_h = spdf_win_max_d(0.0, spdf_win_min_d(target_h, spdf_win_max_d(0.0, layout->canvas_w - viewport_w)));
    target_v = spdf_win_max_d(0.0, spdf_win_min_d(target_v, spdf_win_max_d(0.0, layout->canvas_h - viewport_h)));
    if (scroll_x) *scroll_x = target_h;
    if (scroll_y) *scroll_y = target_v;
    return 1;
}

/* ---------------------------------------------------------------------------
 * Horizontal scroll clamp policy. Port of spdf_hscroll_clamp:
 *  - `scrollable` (the scrollbar's visibility) derives from the TOTAL content
 *    width versus the viewport, NEVER from the current page. Keying it on the
 *    current page is the June GTK defect: one wide sheet in a document blew the
 *    viewport up to that width and pushed every narrower page off screen.
 *  - a current page that fits the viewport is pinned centred;
 *  - a wider page pans within its own bounds only. */
typedef struct {
    int scrollable; /* content wider than the viewport: show the h scrollbar */
    double value;   /* clamped/centred scroll offset */
} SpdfWinHScrollClamp;

static SPDF_WIN_INLINE SpdfWinHScrollClamp spdf_win_hscroll_clamp(const SpdfWinLayout* layout, int current_page,
                                                                  double viewport_w, double value) {
    SpdfWinHScrollClamp result;
    const SpdfWinRect* rect;
    double max_value;

    result.scrollable = layout && layout->canvas_w > viewport_w + 0.5 ? 1 : 0;
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
        result.value = spdf_win_max_d(page_min, spdf_win_min_d(value, page_max));
    }
    max_value = spdf_win_max_d(0.0, layout->canvas_w - viewport_w);
    result.value = spdf_win_max_d(0.0, spdf_win_min_d(result.value, max_value));
    return result;
}

/* ---------------------------------------------------------------------------
 * Crop regime decision: a slot taller or wider than 2x the viewport renders
 * only the visible region at full scale, on top of the byte-capped whole-page
 * base texture. Port of spdf_slot_needs_crop. */
static SPDF_WIN_INLINE int spdf_win_slot_needs_crop(const SpdfWinRect* rect, double viewport_w, double viewport_h) {
    if (!rect || viewport_w <= 0.0 || viewport_h <= 0.0) return 0;
    return rect->h > 2.0 * viewport_h || rect->w > 2.0 * viewport_w ? 1 : 0;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_LAYOUT_H */
