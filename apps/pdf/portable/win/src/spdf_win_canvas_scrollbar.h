/* spdf_win_canvas_scrollbar.h — what a scrollbar needs from the canvas, and
 * nothing else.
 *
 * Extracted from spdf_win_canvas.cpp under the repo's 500-line cap
 * (tools/file-size-limits.md) when the visible page learned to render
 * off-thread. It is a header included by exactly one translation unit -- the
 * arrangement spdf_win_tabs_app.h and spdf_win_render_core.h already use, and
 * for the same reason: a new .cpp would have to be added to a source list that
 * lives in another track's file.
 *
 * Included MID-FILE, on purpose. Both functions below need current_page_of()
 * and spdf_win_canvas_scroll_to(), which are above the include site, and the
 * reading order of the .cpp -- geometry, then scrolling, then the scrollbar's
 * view of it, then rendering -- is the order it was in before the split.
 *
 * The whole contract, and the reason it is fractions rather than offsets, is in
 * spdf_win_canvas.h beside spdf_win_canvas_scroll: `visible` IS the thumb's
 * proportional length and `pos` IS where it sits in its travel, both unitless,
 * so the chrome needs no notion of a PDF point, a zoom or a page.
 */
#ifndef SPDF_WIN_CANVAS_SCROLLBAR_H
#define SPDF_WIN_CANVAS_SCROLLBAR_H

/* One axis of spdf_win_canvas_scroll_state(). `visible` saturates at 1 when the
 * viewport is at least as big as the content, which is the case the scroller
 * draws as a full-length thumb; `pos` is 0 there rather than 0/0. */
static void scroll_fractions(double content, double viewport, double offset, float* pos, float* visible) {
    double travel;
    if (!(content > 0.0) || !(viewport > 0.0) || viewport >= content) {
        *pos = 0.0f;
        *visible = 1.0f;
        return;
    }
    *visible = (float)(viewport / content);
    travel = content - viewport;
    *pos = (float)spdf_win_clamp_d(offset / travel, 0.0, 1.0);
}

/* THE HORIZONTAL AXIS IS THE CURRENT PAGE'S, NOT THE CANVAS'S, and the reason
 * is spdf_win_hscroll_clamp's policy rather than a preference.
 *
 * The canvas is always at least `widest page + 2 * 22 pt` wide, so at FIT WIDTH
 * -- where spdf_win_fit_width_zoom makes the page exactly the viewport's width
 * -- the content is permanently 44 px wider than the viewport. By the clamp's
 * own `scrollable` flag that is horizontally scrollable, but the clamp then PINS
 * a page that fits the viewport centred, so the offset never moves: a trough
 * drawn from that flag would be present on every ordinary document with a thumb
 * that cannot be dragged. What the reader can actually pan is the CURRENT page,
 * when that page is wider than the viewport, and this returns exactly that
 * range.
 *
 * NOTE the distinction from spdf_win_layout.h:349-355, which warns that keying
 * scrollable on the current page was the June GTK defect. That warning is about
 * the canvas's WIDTH -- one wide sheet must not blow the viewport up and push
 * narrower pages off screen -- and the width here is still the canvas's,
 * untouched. This is only about whether there is anything to drag.
 *
 * Returns 0 when the current page fits, leaving the outputs alone. */
static int h_pan_range(const spdf_win_canvas* canvas, double* out_min, double* out_travel, double* out_page_w) {
    const SpdfWinRect* r;
    int page = current_page_of(canvas);
    if (canvas->layout.count <= 0 || page < 0 || page >= canvas->layout.count) return 0;
    r = &canvas->layout.rects[page];
    if (r->w <= (double)canvas->vp_w + 0.5) return 0;
    *out_min = r->x;
    *out_travel = r->w - (double)canvas->vp_w;
    *out_page_w = r->w;
    return 1;
}

void spdf_win_canvas_scroll_state(const spdf_win_canvas* canvas, spdf_win_canvas_scroll* out) {
    double min_x = 0.0, travel = 0.0, page_w = 0.0;
    if (!out) return;
    out->v_pos = 0.0f;
    out->v_visible = 1.0f;
    out->h_pos = 0.0f;
    out->h_visible = 1.0f;
    out->h_scrollable = 0;
    if (!canvas) return;
    scroll_fractions(canvas->layout.canvas_h, (double)canvas->vp_h, canvas->scroll_y, &out->v_pos, &out->v_visible);
    if (!h_pan_range(canvas, &min_x, &travel, &page_w)) return;
    out->h_scrollable = 1;
    scroll_fractions(page_w, (double)canvas->vp_w, canvas->scroll_x - min_x, &out->h_pos, &out->h_visible);
}

int spdf_win_canvas_scroll_to_fraction(spdf_win_canvas* canvas, int vertical, float pos) {
    double min_x = 0.0, travel = 0.0, page_w = 0.0;
    if (!canvas) return 0;
    if (!(pos >= 0.0f)) pos = 0.0f; /* also catches NaN */
    if (pos > 1.0f) pos = 1.0f;
    if (vertical) {
        travel = canvas->layout.canvas_h - (double)canvas->vp_h;
        if (!(travel > 0.0)) return 0;
        return spdf_win_canvas_scroll_to(canvas, (float)canvas->scroll_x, (float)((double)pos * travel));
    }
    /* The same range spdf_win_canvas_scroll_state() reported the thumb against,
     * so a thumb dragged to a fraction lands where that fraction was drawn. */
    if (!h_pan_range(canvas, &min_x, &travel, &page_w)) return 0;
    return spdf_win_canvas_scroll_to(canvas, (float)(min_x + (double)pos * travel), (float)canvas->scroll_y);
}

#endif /* SPDF_WIN_CANVAS_SCROLLBAR_H */
