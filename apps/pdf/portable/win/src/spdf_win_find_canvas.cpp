/* The canvas's NAVIGATION surface for search and the map: scroll to a match,
 * read a page's slot, learn the viewport, re-measure a rotated page, select a
 * whole page. See the "navigation for search and the map" section of
 * spdf_win_canvas.h for each contract.
 *
 * WHY A FOURTH CANVAS TRANSLATION UNIT: spdf_win_canvas.cpp is at the repo's
 * 500-line cap and the rule is extraction over cap bumps
 * (tools/file-size-limits.md). The seam is the same one the prefetch and
 * selection units took -- one subject, one file, one shared private header --
 * and the subject here is "move the view to something the search found", which
 * is the search & map track's, hence the prefix.
 *
 * NOTHING HERE RE-DERIVES GEOMETRY. Every rect is the layout's own
 * (spdf_win_layout.h, the de-glib'd GTK port), every scroll goes through
 * spdf_win_canvas_scroll_to() and therefore through the same clamp the wheel
 * uses, and the select-all runs the same three gesture calls the pointer does.
 */
#include "spdf_win_canvas_internal.h"

int spdf_win_canvas_scroll_to_rect(spdf_win_canvas* canvas, int page_index, spdf_rect rect) {
    const SpdfWinRect* slot;
    double rx, ry, rw, rh, cx, cy;

    if (!canvas || page_index < 0 || page_index >= canvas->page_count) return 0;
    /* Empty or inverted rect: the page, top-aligned, as macOS's own fallback. */
    if (!(rect.x1 > rect.x0) || !(rect.y1 > rect.y0)) return spdf_win_canvas_scroll_to_page(canvas, page_index);
    if (spdf_win_canvas_ensure_measured(canvas, page_index)) spdf_win_canvas_relayout(canvas);
    if (page_index >= canvas->layout.count) return 0;
    slot = &canvas->layout.rects[page_index];

    /* Page space -> content space: the slot's origin plus the rect scaled by the
     * zoom, which is what the compose layer does to place the page's bitmap and
     * what the overlay mapping does to place the highlight over it. */
    rx = slot->x + (double)rect.x0 * canvas->zoom;
    ry = slot->y + (double)rect.y0 * canvas->zoom;
    rw = ((double)rect.x1 - (double)rect.x0) * canvas->zoom;
    rh = ((double)rect.y1 - (double)rect.y0) * canvas->zoom;
    cx = rx + rw * 0.5;
    cy = ry + rh * 0.5;
    return spdf_win_canvas_scroll_to(canvas, (float)(cx - (double)canvas->vp_w * 0.5),
                                     (float)(cy - (double)canvas->vp_h * 0.5));
}

int spdf_win_canvas_page_rect(const spdf_win_canvas* canvas, int page_index, double* x, double* y, double* w,
                              double* h) {
    const SpdfWinRect* slot;
    if (!canvas || page_index < 0 || page_index >= canvas->layout.count) return 0;
    slot = &canvas->layout.rects[page_index];
    if (x) *x = slot->x;
    if (y) *y = slot->y;
    if (w) *w = slot->w;
    if (h) *h = slot->h;
    return 1;
}

void spdf_win_canvas_viewport(const spdf_win_canvas* canvas, unsigned* w, unsigned* h) {
    if (w) *w = canvas ? canvas->vp_w : 0u;
    if (h) *h = canvas ? canvas->vp_h : 0u;
}

int spdf_win_canvas_visible_range(const spdf_win_canvas* canvas, int* first, int* last) {
    int f = 0, l = 0;
    if (!canvas || canvas->page_count <= 0) return 0;
    if (!spdf_win_layout_visible_range(&canvas->layout, canvas->scroll_y, canvas->scroll_y + (double)canvas->vp_h,
                                       &f, &l)) {
        f = l = spdf_win_canvas_current_page(canvas);
    }
    if (l >= canvas->page_count) l = canvas->page_count - 1;
    if (f < 0) f = 0;
    if (first) *first = f;
    if (last) *last = l;
    return 1;
}

int spdf_win_canvas_page_changed(spdf_win_canvas* canvas, int page_index) {
    char err[128];
    float w = 0.0f, h = 0.0f;

    if (!canvas || page_index < 0 || page_index >= canvas->page_count) return 0;
    /* The page's new size, measured now whether or not the viewport had
     * reached it: a rotated page that kept its estimate would lay out at the
     * old aspect until scrolled to. On failure the old size stands. */
    if (spdf_page_size(canvas->doc, page_index, &w, &h, err, sizeof(err)) && w > 0.0f && h > 0.0f) {
        canvas->sizes[page_index].width = w;
        canvas->sizes[page_index].height = h;
    }
    /* Every cached bitmap is the OLD orientation of some page -- the rotated
     * one, or a neighbour whose slot moved. The whole cache goes rather than a
     * key-by-key hunt through every zoom this page was rendered at: a rotation
     * is a rare, deliberate command, and a stale page after it would be a
     * defect the reader sees. The generation bump makes any prefetch in flight
     * arrive as superseded rather than be adopted. */
    spdf_win_lru_remove_all(&canvas->cache);
    if (canvas->service) spdf_win_render_service_bump_generation(canvas->service);
    spdf_win_links_invalidate(canvas->links);
    spdf_win_canvas_clear_selection(canvas);
    spdf_win_canvas_relayout(canvas);
    return 1;
}

int spdf_win_canvas_select_page(spdf_win_canvas* canvas, int page_index) {
    const spdf_win_page_draw* draw = NULL;
    float x0, y0, x1, y1;
    int i, changed;

    if (!canvas) return 0;
    for (i = 0; i < canvas->draws_count; ++i)
        if (canvas->draws[i].page_index == page_index) draw = &canvas->draws[i];
    if (!draw || !(draw->dest_w > 2.0f && draw->dest_h > 2.0f)) return 0;

    /* One device pixel inside each corner, so both endpoints are genuinely ON
     * the page (the gutter is not the page) and the range spans every glyph.
     * A drag far past the slop, then a release, exactly as the pointer does. */
    x0 = draw->dest_x + 1.0f;
    y0 = draw->dest_y + 1.0f;
    x1 = draw->dest_x + draw->dest_w - 1.0f;
    y1 = draw->dest_y + draw->dest_h - 1.0f;
    changed = spdf_win_canvas_pointer_press(canvas, x0, y0, 1u);
    changed |= spdf_win_canvas_pointer_drag(canvas, x1, y1);
    spdf_win_canvas_pointer_release(canvas, NULL);
    return changed | spdf_win_canvas_has_selection(canvas);
}
