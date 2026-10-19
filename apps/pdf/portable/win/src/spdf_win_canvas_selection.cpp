/* The canvas's pointer gesture: text selection, the cursor, and following a
 * link. See spdf_win_canvas.h's "text selection and links" section for the
 * public surface and spdf_win_canvas_internal.h for why the state lives on the
 * canvas.
 *
 * WHY THIS IS A THIRD CANVAS TRANSLATION UNIT rather than more of
 * spdf_win_canvas.cpp: that file is at 475 of the repo's 500 lines and the rule
 * is extraction over cap bumps (tools/file-size-limits.md). The seam is the
 * same one spdf_win_canvas_prefetch.cpp took -- one subject, one file, one
 * shared private header.
 *
 * THE PAGE LIST IS THE LAST BUILT FRAME'S, and that is on purpose rather than a
 * shortcut. `canvas->draws` is exactly what the reader is looking at when they
 * click, in exactly the coordinates the click arrives in, so a hit test against
 * it cannot disagree with what was drawn -- not at a fractional zoom, not on a
 * byte-capped foldout whose texture is smaller than its slot, and not on a
 * frame where a page was still being measured. Deriving the geometry a second
 * time from the layout would be a second chance to be wrong. The cost is that a
 * click before the first paint selects nothing, which is a click at a moment
 * when there is nothing on screen to select.
 *
 * `canvas->measured` -- NOT `canvas->page_count` -- is passed as the page-size
 * count everywhere below, so a page whose size is still page 1's estimate
 * resolves to no hit rather than to a wrong PDF point. build_scene() measures
 * forward until the visible range stops moving, so every page in `draws` is
 * already measured and the guard never fires in practice; it fires only if that
 * invariant is ever broken, which is exactly when a silent wrong answer would
 * be worst.
 */
#include "spdf_win_canvas_internal.h"

/* Win32's drag slop. GTK passes ONE threshold and compares it against each axis
 * separately (spdf_win_selection_drag_threshold_crossed keeps that rule);
 * Windows publishes two, which are equal on every default configuration. Taking
 * the larger keeps the port's single-threshold shape without ever starting a
 * drag Windows itself would not have started. Device pixels, like everything
 * else that crosses this file's boundary. */
static double drag_threshold(void) {
    int cx = GetSystemMetrics(SM_CXDRAG);
    int cy = GetSystemMetrics(SM_CYDRAG);
    int v = cx > cy ? cx : cy;
    return v > 0 ? (double)v : 4.0;
}

/* Lazy: a document nobody clicks on allocates nothing. */
static int ensure_state(spdf_win_canvas* canvas) {
    if (!canvas) return 0;
    if (!canvas->selection) {
        canvas->selection = spdf_win_selection_new();
        canvas->press_page = -1;
    }
    if (!canvas->links) {
        canvas->links = spdf_win_links_new();
        /* The path lets the cache run its text-URL worker over a handle of its
         * own (spdf_win_links.h section 2). A NULL path -- the headless probe --
         * leaves hover with annotation links only, as before. */
        spdf_win_links_set_source(canvas->links, canvas->path);
    }
    return canvas->selection != NULL;
}

static void drop_nav(spdf_win_canvas* canvas) {
    if (!canvas || !canvas->nav_valid) return;
    spdf_free_link_target(&canvas->nav);
    canvas->nav_valid = 0;
}

void spdf_win_canvas_selection_teardown(spdf_win_canvas* canvas) {
    if (!canvas) return;
    drop_nav(canvas);
    spdf_win_selection_free(canvas->selection);
    canvas->selection = NULL;
    spdf_win_links_free(canvas->links);
    canvas->links = NULL;
    canvas->press_page = -1;
}

/* --- the gesture ---------------------------------------------------------- */

int spdf_win_canvas_pointer_press(spdf_win_canvas* canvas, float x, float y, unsigned click_count) {
    spdf_win_page_point hit;
    int over_link = 0;

    if (!ensure_state(canvas)) return 0;
    drop_nav(canvas);
    canvas->press_page = -1;

    if (spdf_win_selection_point_on_page(canvas->draws, canvas->draws_count, canvas->sizes, canvas->measured, x, y,
                                         &hit) &&
        hit.inside) {
        /* Only a point genuinely INSIDE a page can be over a link: the nearest-
         * page clamp exists to make a drag behave, not to let a click on the
         * gutter follow the link nearest to it. */
        canvas->press_page = hit.page_index;
        canvas->press_page_x = hit.x;
        canvas->press_page_y = hit.y;
        over_link = spdf_win_links_hit(canvas->links, canvas->doc, hit.page_index, hit.x, hit.y);
    }
    return spdf_win_selection_press(canvas->selection, canvas->doc, canvas->draws, canvas->draws_count, canvas->sizes,
                                    canvas->measured, x, y, click_count, over_link);
}

int spdf_win_canvas_pointer_drag(spdf_win_canvas* canvas, float x, float y) {
    if (!canvas || !canvas->selection) return 0;
    return spdf_win_selection_drag(canvas->selection, canvas->doc, canvas->draws, canvas->draws_count, canvas->sizes,
                                   canvas->measured, x, y, drag_threshold());
}

int spdf_win_canvas_pointer_release(spdf_win_canvas* canvas, spdf_win_canvas_link_nav* out_nav) {
    int follow;
    int page;

    if (out_nav) {
        out_nav->kind = SPDF_LINK_NONE;
        out_nav->page_index = -1;
        out_nav->uri = NULL;
    }
    if (!canvas || !canvas->selection) return 0;
    follow = spdf_win_selection_release(canvas->selection);
    if (!follow || canvas->press_page < 0) return 0;

    drop_nav(canvas);
    if (spdf_win_links_target_at(canvas->doc, canvas->press_page, canvas->press_page_x, canvas->press_page_y,
                                 &canvas->nav) != 1)
        return 0;
    canvas->nav_valid = 1;
    if (out_nav) {
        out_nav->kind = (int)canvas->nav.kind;
        out_nav->page_index = canvas->nav.page_index;
        out_nav->uri = canvas->nav.uri;
    }
    if (canvas->nav.kind == SPDF_LINK_INTERNAL && canvas->nav.page_index >= 0) {
        /* The canvas can perform this itself, so it does: handing the page back
         * for the shell to feed straight into a scroll would be a round trip
         * that can only be got wrong.
         *
         * TOP-ALIGNED AT THE DESTINATION'S OWN Y, not at the target page's top:
         * spdf_win_links.h section 3 holds the arithmetic and the reasons, and
         * a destination that names only a page still lands exactly where
         * spdf_win_canvas_scroll_to_page() would put it -- which is what
         * portable/win/tests/link_destination_test.c checks against that call
         * rather than against a repetition of it.
         *
         * The clamp is spdf_win_canvas_scroll_to()'s, so this lands inside the
         * same travel the wheel does; the measure-then-relayout is the same
         * pair scroll_to_page runs, because a page the viewport has never
         * reached carries page 1's size as an estimate and has no slot worth
         * offsetting from. */
        page = canvas->nav.page_index;
        if (page >= canvas->page_count) return 0;
        if (spdf_win_canvas_ensure_measured(canvas, page)) spdf_win_canvas_relayout(canvas);
        if (page >= canvas->layout.count) return 0;
        return spdf_win_canvas_scroll_to(
            canvas, (float)canvas->scroll_x,
            (float)spdf_win_link_destination_scroll_y(canvas->layout.rects[page].y,
                                                      spdf_win_link_destination_page_y(&canvas->nav), canvas->zoom));
    }
    return 0;
}

void spdf_win_canvas_pointer_cancel(spdf_win_canvas* canvas) {
    if (!canvas || !canvas->selection) return;
    spdf_win_selection_cancel(canvas->selection);
}

/* --- the cursor ----------------------------------------------------------- */

spdf_win_canvas_cursor spdf_win_canvas_cursor_at(spdf_win_canvas* canvas, float x, float y, int want_text_cursor) {
    spdf_win_page_point hit;
    SpdfWinCursorRegionKind kind;

    if (!ensure_state(canvas)) return SPDF_WIN_CANVAS_CURSOR_ARROW;
    if (!spdf_win_selection_point_on_page(canvas->draws, canvas->draws_count, canvas->sizes, canvas->measured, x, y,
                                          &hit))
        return SPDF_WIN_CANVAS_CURSOR_ARROW;
    /* The gutter is not the page. */
    if (!hit.inside) return SPDF_WIN_CANVAS_CURSOR_ARROW;
    kind = spdf_win_links_region_at(canvas->links, canvas->doc, hit.page_index, want_text_cursor, hit.x, hit.y);
    if (kind == SPDF_WIN_CURSOR_REGION_LINK) return SPDF_WIN_CANVAS_CURSOR_HAND;
    if (kind == SPDF_WIN_CURSOR_REGION_TEXT) return SPDF_WIN_CANVAS_CURSOR_TEXT;
    return SPDF_WIN_CANVAS_CURSOR_ARROW;
}

/* --- copy, read back, clear ----------------------------------------------- */

int spdf_win_canvas_copy_selection(spdf_win_canvas* canvas) {
    const char* text;

    if (!canvas || !canvas->selection) return 0;
    text = spdf_win_selection_text(canvas->selection);
    if (!text || !text[0]) return 0;
    return spdf_win_clipboard_put_utf8(text);
}

const char* spdf_win_canvas_selection_text(const spdf_win_canvas* canvas) {
    return canvas ? spdf_win_selection_text(canvas->selection) : NULL;
}

int spdf_win_canvas_has_selection(const spdf_win_canvas* canvas) {
    return canvas ? spdf_win_selection_has_text(canvas->selection) : 0;
}

int spdf_win_canvas_clear_selection(spdf_win_canvas* canvas) {
    int had;
    if (!canvas || !canvas->selection) return 0;
    had = spdf_win_selection_has_text(canvas->selection);
    spdf_win_selection_clear(canvas->selection);
    drop_nav(canvas);
    canvas->press_page = -1;
    return had;
}

/* --- overlays ------------------------------------------------------------- */

int spdf_win_canvas_selection_rects(const spdf_win_canvas* canvas, int* page_index, spdf_rect* rects, int max) {
    int n = 0;
    const spdf_rect* src;
    if (page_index) *page_index = -1;
    if (!canvas || !canvas->selection || !spdf_win_selection_has_text(canvas->selection)) return 0;
    src = spdf_win_selection_rects(canvas->selection, &n);
    if (!src || n <= 0) return 0;
    if (page_index) *page_index = spdf_win_selection_page(canvas->selection);
    if (n > max) n = max;
    if (rects && n > 0) memcpy(rects, src, sizeof(spdf_rect) * (size_t)n);
    return n;
}

void spdf_win_canvas_apply_selection_overlays(spdf_win_canvas* canvas, spdf_win_scene* scene) {
    if (!canvas || !canvas->selection) return;
    spdf_win_selection_compose_overlays(canvas->selection, canvas->draws, canvas->draws_count, canvas->sizes,
                                        canvas->measured, scene);
}
