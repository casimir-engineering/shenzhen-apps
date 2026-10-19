/* spdf_win_search_map_input.h — the minimap's INPUT policy, ported from the
 * GTK4 frontend: strip-scroll, the discrete-wheel page cap, and the
 * long-document viewport drag.
 *
 * WHY A SECOND MINIMAP HEADER. spdf_win_minimap.h transcribes the GEOMETRY half
 * of portable/linux/gtk4/spdf_minimap_internal.h and says in its own header what
 * it deliberately left out: "the kinetic scroll decay, the long-document drag
 * scale, the wheel-notch cap and the directional page stride. Those are INPUT
 * policy, they belong with whoever owns WM_MOUSEWHEEL and the drag state
 * machine ... a small, mechanical addition when the input layer wants them."
 * The input layer wants them now, and that header is at its size cap, so the
 * addition lands here -- same GTK original, same transcription rule, same
 * differential (portable/win/tests/minimap_differential.c compiles both headers
 * beside the GTK one and compares with `==`).
 *
 *   spdf_win_minimap_document_delta_for_strip_scroll <- spdf_minimap_document_delta_for_strip_scroll
 *   spdf_win_minimap_document_top_for_strip_scroll   <- spdf_minimap_document_top_for_strip_scroll
 *   spdf_win_minimap_directional_page_stride         <- spdf_minimap_directional_page_stride
 *   spdf_win_minimap_document_top_capped_for_discrete_wheel
 *                                                    <- spdf_minimap_document_top_capped_for_discrete_wheel
 *   spdf_win_minimap_total_height_pt / _use_long_document_drag / _smoothstep /
 *   _long_drag_scale / _drag_thumb_height             <- the same five
 *
 * All of them trace to macOS: commit db9515802 (SPDFMacMinimapWindow.mm) for the
 * strip-scroll model -- a scroll over the minimap moves the STRIP by the gesture
 * distance and the document follows at maxDoc/maxStrip -- and
 * longDocumentDragScaleForDeltaY / longDocumentViewportDragThumbHeight for the
 * accelerated drag on documents over 16,000 pt tall.
 *
 * NOT PORTED, and why: the kinetic decay (spdf_minimap_kinetic_step). GTK
 * animates a fling itself because its scroll controller only reports the
 * velocity; WM_MOUSEWHEEL has no fling phase and Windows precision touchpads
 * deliver their own inertia as ordinary wheel messages, so a second decay here
 * would double the momentum. The wheel-line constant that GTK multiplies a
 * discrete notch by is kept, because the cap below is expressed in strip pixels.
 *
 * WHAT CHANGED IN THE PORT: types only. glib's MAX/MIN/CLAMP become the
 * spdf_win_*_d helpers spdf_win_layout.h spells out with glib's exact tie and NaN
 * behaviour; gboolean becomes int. UNITS are those of the caller: strip
 * quantities in the minimap panel's device pixels, document quantities in the
 * canvas's content pixels, page sizes in PDF points.
 */
#ifndef SPDF_WIN_SEARCH_MAP_INPUT_H
#define SPDF_WIN_SEARCH_MAP_INPUT_H

#include <math.h>

#include "spdf_win_minimap.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Long-document drag thresholds (Mac constants). */
#define SPDF_WIN_MINIMAP_LONG_DOC_HEIGHT_PT 16000.0
#define SPDF_WIN_MINIMAP_DRAG_FINE_SPEED 180.0
#define SPDF_WIN_MINIMAP_DRAG_FULL_SPEED 300.0

/* One discrete wheel notch, in strip px (GTK4's wheel unit; Mac line height). */
#define SPDF_WIN_MINIMAP_WHEEL_POINTS_PER_LINE 32.0

/* ---------------------------------------------------------------------------
 * Strip-scroll model (Mac db9515802): a plain scroll over the minimap moves
 * the STRIP by the gesture distance and the document follows at the scrollbar
 * ratio maxDocScroll/maxStripScroll, so the strip tracks the fingers 1:1 by
 * construction (its offset is derived from the document position). When the
 * whole strip fits, the scale falls back to documentHeight/contentHeight so
 * the gesture still moves the viewport indicator by its own distance. */
static SPDF_WIN_INLINE double spdf_win_minimap_document_delta_for_strip_scroll(double strip_dy,
                                                                               double strip_content_h,
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

static SPDF_WIN_INLINE double spdf_win_minimap_document_top_for_strip_scroll(double current_doc_top, double strip_dy,
                                                                             double strip_content_h,
                                                                             double strip_available_h, double doc_h,
                                                                             double doc_visible_h) {
    double delta = spdf_win_minimap_document_delta_for_strip_scroll(strip_dy, strip_content_h, strip_available_h,
                                                                    doc_h, doc_visible_h);
    double max_doc_scroll = spdf_win_max_d(0.0, doc_h - doc_visible_h);
    return spdf_win_max_d(0.0, spdf_win_min_d(current_doc_top + delta, max_doc_scroll));
}

/* Directional page stride for a discrete wheel cap. Adjacent page origins
 * include the layout gap; document edges fall back to the current page height. */
static SPDF_WIN_INLINE double spdf_win_minimap_directional_page_stride(int current_page, double proposed_doc_delta,
                                                                       const double* doc_y, const double* doc_h,
                                                                       int page_count) {
    int page;
    int adjacent;
    double stride = 0.0;

    if (!doc_y || !doc_h || page_count <= 0 || fabs(proposed_doc_delta) <= 0.0001) return 0.0;
    page = spdf_win_minimap_clamp_i(current_page, 0, page_count - 1);
    adjacent = proposed_doc_delta > 0.0 ? page + 1 : page - 1;
    if (adjacent >= 0 && adjacent < page_count)
        stride = proposed_doc_delta > 0.0 ? doc_y[adjacent] - doc_y[page] : doc_y[page] - doc_y[adjacent];
    if (!isfinite(stride) || stride <= 0.0) stride = doc_h[page];
    return isfinite(stride) ? spdf_win_max_d(0.0, stride) : 0.0;
}

/* Limit one discrete wheel event to one directional page stride. Precise
 * trackpad input does not call this helper. */
static SPDF_WIN_INLINE double spdf_win_minimap_document_top_capped_for_discrete_wheel(
    double current_doc_top, double proposed_doc_top, int current_page, const double* doc_y, const double* doc_h,
    int page_count, double doc_height, double doc_visible_height) {
    double delta = proposed_doc_top - current_doc_top;
    double stride = spdf_win_minimap_directional_page_stride(current_page, delta, doc_y, doc_h, page_count);
    double max_doc_scroll = spdf_win_max_d(0.0, doc_height - doc_visible_height);

    if (stride > 0.0 && fabs(delta) > stride) proposed_doc_top = current_doc_top + copysign(stride, delta);
    return spdf_win_max_d(0.0, spdf_win_min_d(proposed_doc_top, max_doc_scroll));
}

/* ---------------------------------------------------------------------------
 * Long-document viewport drag. The drag thumb is sized as a fraction of the
 * TRACK (not of the strip content, which would overshoot and collapse the
 * drag range on 200+ page documents); slow drags move at a page-count-scaled
 * fine speed, fast drags accelerate to 1:1 through a smoothstep. */
static SPDF_WIN_INLINE double spdf_win_minimap_total_height_pt(const SpdfWinPageSizePt* sizes, int count) {
    double total = 0.0;
    int i;
    if (!sizes) return 0.0;
    for (i = 0; i < count; ++i) total += spdf_win_max_d(1.0, sizes[i].height);
    return total;
}

static SPDF_WIN_INLINE int spdf_win_minimap_use_long_document_drag(const SpdfWinPageSizePt* sizes, int count) {
    return spdf_win_minimap_total_height_pt(sizes, count) > SPDF_WIN_MINIMAP_LONG_DOC_HEIGHT_PT;
}

static SPDF_WIN_INLINE double spdf_win_minimap_smoothstep(double value) {
    value = spdf_win_clamp_d(value, 0.0, 1.0);
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}

static SPDF_WIN_INLINE double spdf_win_minimap_long_drag_scale(double delta_y, double delta_t, int page_count) {
    double speed;
    double acceleration;
    double page_scale;

    if (!isfinite(delta_t) || delta_t <= 0.0) delta_t = 1.0 / 60.0;
    delta_t = spdf_win_clamp_d(delta_t, 1.0 / 240.0, 1.0 / 15.0);
    speed = fabs(delta_y) / delta_t;
    acceleration = spdf_win_minimap_smoothstep((speed - SPDF_WIN_MINIMAP_DRAG_FINE_SPEED) /
                                               (SPDF_WIN_MINIMAP_DRAG_FULL_SPEED - SPDF_WIN_MINIMAP_DRAG_FINE_SPEED));
    /* glib's MAX(1, page_count) is an int MAX; the division then promotes. */
    page_scale = spdf_win_clamp_d(20.0 / (double)(page_count > 1 ? page_count : 1), 0.30, 0.72);
    return page_scale + acceleration * (1.0 - page_scale);
}

static SPDF_WIN_INLINE double spdf_win_minimap_drag_thumb_height(double doc_visible_h, double doc_h, double track_h) {
    double fraction = spdf_win_clamp_d(doc_visible_h / spdf_win_max_d(1.0, doc_h), 0.02, 1.0);
    return spdf_win_min_d(spdf_win_max_d(10.0, fraction * track_h), track_h);
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SEARCH_MAP_INPUT_H */
