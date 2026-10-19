#pragma once

/* spdf_win_search_map_ui.h -- what the POINTER does over the MINIMAP: click to
 * jump, drag the viewport, wheel the strip.
 *
 * Header-only and included from spdf_win_chrome_field_ui.h (so it reaches
 * spdf_win_main.cpp after `struct app` and before spdf_win_chrome_actions.h,
 * whose chrome_perform() and chrome_mouse() call the four handlers below). The
 * search & map track's, hence the prefix; it sits beside
 * spdf_win_chrome_canvas_ui.h, which is the same shape for the page.
 *
 * WHAT IT HIT-TESTS: THE FRAME THE PAINTER DREW. spdf_win_search_map.h records
 * the strip, the content offset and the viewport band of the last paint; every
 * handler here reads that frame and the canvas's live layout, and derives
 * nothing of its own -- the same argument spdf_win_canvas_selection.cpp makes
 * for hit-testing `draws`. The document-side arrays (each page's slot) come
 * from spdf_win_canvas_page_rect, the strip side from the frame, and the two
 * meet in the ported spdf_win_minimap_* mappings, differentially tested.
 *
 * THE GESTURES, transcribed from the GTK4 minimap (spdf_minimap.c
 * minimap_drag_begin/update/end, minimap_scroll, minimap_center_document_at,
 * minimap_follow_horizontal), which is itself the macOS one:
 *
 *   press     remembers the point and whether it landed on the viewport band;
 *             on a long document (> 16,000 pt) it also places the drag thumb.
 *   move      under 3 px of travel is still a click. Past it: on the band, the
 *             grabbed point keeps its offset from the band's centre (a 1:1
 *             drag), accelerated through the long-document thumb model on a
 *             long document; off the band, the document is scrubbed to the
 *             point under the pointer.
 *   release   with no movement is CLICK-TO-JUMP: the viewport centres on the
 *             page point under the pointer (Mac minimapViewDidRequestCenterOnPage).
 *   wheel     moves the STRIP by the wheel distance and the document follows at
 *             maxDoc/maxStrip (Mac db9515802), capped to one page per discrete
 *             notch; Ctrl+wheel never reaches here -- it is SPDF_WIN_INPUT_ZOOM
 *             and zooms the document as it does everywhere.
 *
 * Centring iterates to a fixed point because content_top depends on the scroll
 * it produces, exactly as GTK's MINIMAP_CENTER_ITERATIONS loop and the Mac's
 * documentPointForMinimapCenterPoint do. Horizontal follow puts the page x
 * under the pointer under the viewport's centre, when there is anything to pan.
 */

#include "spdf_win_search_map.h"
#include "spdf_win_search_map_input.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SPDF_WIN_MAP_DRAG_THRESHOLD 3.0  /* px; GTK MINIMAP_DRAG_THRESHOLD, the Mac's press-vs-drag slop */
#define SPDF_WIN_MAP_CENTER_ITERATIONS 8 /* GTK MINIMAP_CENTER_ITERATIONS <- Mac documentPointForMinimapCenterPoint */

/* Everything one gesture step needs, acquired fresh from the frame and the
 * canvas -- O(page count) arithmetic, into buffers reused across steps so a
 * drag does not allocate per pixel. */
typedef struct SpdfWinMapInput {
    SpdfWinMapFrame f;
    double* doc_x;
    double* doc_y;
    double* doc_w;
    double* doc_h;
    int count;
    double doc_top;
    double doc_visible_h;
    double doc_upper;
    double doc_left;
    double doc_visible_w;
    double panel_h;
    double available; /* panel height less the edge inset, the strip's scrollable height */
} SpdfWinMapInput;

static struct {
    double* buf;
    int cap;
    /* the drag */
    int armed;
    float press_x, press_y;
    int moved;
    int dragging_viewport;
    double off_cx, off_cy;
    float last_y;
    LARGE_INTEGER last_t;
    double thumb_top;
} g_map;

static int map_acquire(app* a, SpdfWinMapInput* mi) {
    unsigned vw = 0, vh = 0;
    int i;
    memset(mi, 0, sizeof(*mi));
    if (!a->canvas || !spdf_win_map_frame_current(&mi->f) || !mi->f.strip || mi->f.page_count <= 0) return 0;
    if (mi->f.page_count != spdf_win_canvas_page_count(a->canvas)) return 0; /* the frame is another document's */
    mi->count = mi->f.page_count;
    if (g_map.cap < mi->count * 4) {
        double* grown = (double*)realloc(g_map.buf, sizeof(double) * (size_t)mi->count * 4u);
        if (!grown) return 0;
        g_map.buf = grown;
        g_map.cap = mi->count * 4;
    }
    mi->doc_x = g_map.buf;
    mi->doc_y = g_map.buf + mi->count;
    mi->doc_w = g_map.buf + mi->count * 2;
    mi->doc_h = g_map.buf + mi->count * 3;
    for (i = 0; i < mi->count; ++i)
        if (!spdf_win_canvas_page_rect(a->canvas, i, &mi->doc_x[i], &mi->doc_y[i], &mi->doc_w[i], &mi->doc_h[i]))
            return 0;
    spdf_win_canvas_viewport(a->canvas, &vw, &vh);
    mi->doc_top = spdf_win_canvas_scroll_y(a->canvas);
    mi->doc_left = spdf_win_canvas_scroll_x(a->canvas);
    mi->doc_visible_h = (double)vh;
    mi->doc_visible_w = (double)vw;
    mi->doc_upper = spdf_win_canvas_content_h(a->canvas);
    mi->panel_h = mi->f.panel.h;
    mi->available = spdf_win_max_d(1.0, mi->panel_h - spdf_win_chrome_px(SPDF_WIN_MINIMAP_EDGE_INSET, mi->f.dpi_scale));
    return 1;
}

/* Pan so the strip x fraction of the page holding doc_center_y lands under the
 * viewport centre, when the page is wider than the viewport (GTK
 * minimap_follow_horizontal; the clamp decides "when"). */
static void map_follow_horizontal(app* a, const SpdfWinMapInput* mi, double doc_center_y, double strip_x,
                                  double target_top) {
    int i;
    for (i = 0; i < mi->count; ++i) {
        double frac, doc_x;
        const SpdfWinRect* r = &mi->f.strip->rects[i];
        if (doc_center_y < mi->doc_y[i] || doc_center_y > mi->doc_y[i] + mi->doc_h[i]) continue;
        frac = spdf_win_clamp_d((strip_x - r->x) / spdf_win_max_d(1.0, r->w), 0.0, 1.0);
        doc_x = mi->doc_x[i] + frac * mi->doc_w[i];
        spdf_win_canvas_scroll_to(a->canvas, (float)(doc_x - mi->doc_visible_w * 0.5), (float)target_top);
        return;
    }
    spdf_win_canvas_scroll_to(a->canvas, (float)mi->doc_left, (float)target_top);
}

/* Centre the viewport on the document point under a PANEL-LOCAL strip point
 * (GTK minimap_center_document_at). */
static int map_center_document_at(app* a, const SpdfWinMapInput* mi, double panel_x, double panel_y) {
    double content_top = mi->f.content_top;
    double max_scroll = spdf_win_max_d(0.0, mi->doc_upper - mi->doc_visible_h);
    double doc_yv = mi->doc_top + mi->doc_visible_h * 0.5;
    double target = mi->doc_top;
    float s = mi->f.dpi_scale;
    int k;

    if (panel_y <= 0.0) {
        target = 0.0;
    } else if (panel_y >= mi->panel_h - 1.0) {
        target = max_scroll;
    } else {
        for (k = 0; k < SPDF_WIN_MAP_CENTER_ITERATIONS; ++k) {
            double fraction;
            doc_yv = spdf_win_minimap_document_y_for_strip_y(mi->f.strip, mi->doc_y, mi->doc_h, mi->count,
                                                             panel_y - content_top);
            target = spdf_win_clamp_d(doc_yv - mi->doc_visible_h * 0.5, 0.0, max_scroll);
            fraction = max_scroll > 0.0 ? target / max_scroll : 0.0;
            content_top = spdf_win_minimap_content_top(mi->f.strip->content_h, mi->panel_h,
                                                       spdf_win_chrome_px(SPDF_WIN_MINIMAP_EDGE_INSET, s),
                                                       spdf_win_chrome_px(SPDF_WIN_MINIMAP_TOP_PAD, s), fraction);
        }
    }
    map_follow_horizontal(a, mi, doc_yv, panel_x, target);
    return 1;
}

/* A left press on the strip: arm the gesture. Nothing moves until the pointer
 * does or is released. The point is a->drag_last_x/y, which chrome_mouse()
 * records before it performs the hit. */
static int minimap_press(app* a, const SpdfWinChromeHit* hit, const SpdfWinChromeLayout* l) {
    SpdfWinMapInput mi;
    double px_, py_;
    (void)hit;
    (void)l;
    g_map.armed = 0; /* buf/cap are kept: they are the reused arrays, not gesture state */
    g_map.moved = 0;
    g_map.dragging_viewport = 0;
    g_map.thumb_top = 0.0;
    if (!map_acquire(a, &mi)) return 0;
    px_ = a->drag_last_x - mi.f.panel.x;
    py_ = a->drag_last_y - mi.f.panel.y;
    g_map.armed = 1;
    g_map.press_x = (float)px_;
    g_map.press_y = (float)py_;
    g_map.last_y = (float)py_;
    QueryPerformanceCounter(&g_map.last_t);
    {
        /* The band as drawn, moved from unscrolled strip space to the panel. */
        double bx = mi.f.band.x, by = mi.f.band.y + mi.f.content_top, bw = mi.f.band.w, bh = mi.f.band.h;
        g_map.dragging_viewport = px_ >= bx && px_ <= bx + bw && py_ >= by && py_ <= by + bh;
        if (g_map.dragging_viewport) {
            g_map.off_cx = px_ - (bx + bw * 0.5);
            g_map.off_cy = py_ - (by + bh * 0.5);
            if (spdf_win_minimap_use_long_document_drag(mi.f.sizes, mi.count)) {
                double track_h = spdf_win_max_d(1.0, mi.panel_h - 2.0);
                double thumb_h = spdf_win_minimap_drag_thumb_height(mi.doc_visible_h, mi.doc_upper, track_h);
                double min_top = 1.0;
                double max_top = spdf_win_max_d(min_top, mi.panel_h - thumb_h - 1.0);
                double max_scroll = spdf_win_max_d(0.0, mi.doc_upper - mi.doc_visible_h);
                double fraction = max_scroll > 0.0 ? spdf_win_clamp_d(mi.doc_top / max_scroll, 0.0, 1.0) : 0.0;
                g_map.thumb_top = min_top + fraction * (max_top - min_top);
            }
        }
    }
    a->drag = SPDF_WIN_CA_MINIMAP_DRAG;
    return 0;
}

static int minimap_drag(app* a, const spdf_win_input* in, const SpdfWinChromeLayout* l) {
    SpdfWinMapInput mi;
    double x, y;
    (void)l;
    if (!g_map.armed || !map_acquire(a, &mi)) return 0;
    x = in->x - mi.f.panel.x;
    y = in->y - mi.f.panel.y;
    if (!g_map.moved) {
        double dx = x - g_map.press_x, dy = y - g_map.press_y;
        if (sqrt(dx * dx + dy * dy) < SPDF_WIN_MAP_DRAG_THRESHOLD * (mi.f.dpi_scale > 0.0f ? mi.f.dpi_scale : 1.0f))
            return 0;
        g_map.moved = 1;
    }
    if (g_map.dragging_viewport && spdf_win_minimap_use_long_document_drag(mi.f.sizes, mi.count)) {
        /* Mac accelerated long-document drag: the thumb moves on a track. */
        double track_h = spdf_win_max_d(1.0, mi.panel_h - 2.0);
        double thumb_h = spdf_win_minimap_drag_thumb_height(mi.doc_visible_h, mi.doc_upper, track_h);
        double min_top = 1.0;
        double max_top = spdf_win_max_d(min_top, mi.panel_h - thumb_h - 1.0);
        LARGE_INTEGER now, freq;
        double delta_t, delta_y, scale, fraction, max_scroll;
        QueryPerformanceCounter(&now);
        QueryPerformanceFrequency(&freq);
        delta_t = (double)(now.QuadPart - g_map.last_t.QuadPart) / (double)(freq.QuadPart > 0 ? freq.QuadPart : 1);
        delta_y = y - g_map.last_y;
        scale = spdf_win_minimap_long_drag_scale(delta_y, delta_t, mi.count);
        max_scroll = spdf_win_max_d(0.0, mi.doc_upper - mi.doc_visible_h);
        g_map.thumb_top = spdf_win_clamp_d(g_map.thumb_top + delta_y * scale, min_top, max_top);
        g_map.last_y = (float)y;
        g_map.last_t = now;
        fraction = max_top <= min_top ? 0.0 : (g_map.thumb_top - min_top) / (max_top - min_top);
        map_follow_horizontal(a, &mi, fraction * max_scroll + mi.doc_visible_h * 0.5, x - g_map.off_cx,
                              fraction * max_scroll);
        return 1;
    }
    if (g_map.dragging_viewport) return map_center_document_at(a, &mi, x - g_map.off_cx, y - g_map.off_cy);
    return map_center_document_at(a, &mi, x, y); /* scrub */
}

static int minimap_release(app* a, const spdf_win_input* in, const SpdfWinChromeLayout* l) {
    SpdfWinMapInput mi;
    int changed = 0;
    (void)in;
    (void)l;
    if (g_map.armed && !g_map.moved && map_acquire(a, &mi)) {
        int page = -1;
        double x_fraction = 0.5, y_fraction = 0.0;
        if (spdf_win_minimap_page_hit(mi.f.strip, g_map.press_x, g_map.press_y - mi.f.content_top, &page, &x_fraction,
                                      &y_fraction) &&
            page >= 0 && page < mi.count) {
            double target_y = mi.doc_y[page] + y_fraction * mi.doc_h[page];
            map_follow_horizontal(a, &mi, target_y, mi.f.strip->rects[page].x + x_fraction * mi.f.strip->rects[page].w,
                                  target_y - mi.doc_visible_h * 0.5);
            changed = 1;
        }
    }
    g_map.armed = 0;
    g_map.moved = 0;
    g_map.dragging_viewport = 0;
    return changed;
}

/* A wheel over the strip. `in->dy` is the document distance the window would
 * have scrolled (device px, positive = down); here it is the STRIP distance,
 * so the strip moves with the wheel as the scrollbar's thumb would and the
 * document follows at the maxDoc/maxStrip ratio -- then capped to one page
 * stride, because WM_MOUSEWHEEL is a discrete notch even from a touchpad and a
 * notch that flung a 500-page document to its end was the defect the cap
 * exists for. */
static int minimap_wheel(app* a, const spdf_win_input* in) {
    SpdfWinMapInput mi;
    double new_top;
    if (!map_acquire(a, &mi)) return 0;
    new_top = spdf_win_minimap_document_top_for_strip_scroll(mi.doc_top, (double)in->dy, mi.f.strip->content_h,
                                                             mi.available, mi.doc_upper, mi.doc_visible_h);
    new_top = spdf_win_minimap_document_top_capped_for_discrete_wheel(
        mi.doc_top, new_top, spdf_win_canvas_current_page(a->canvas), mi.doc_y, mi.doc_h, mi.count, mi.doc_upper,
        mi.doc_visible_h);
    return spdf_win_canvas_scroll_to(a->canvas, (float)mi.doc_left, (float)new_top);
}
