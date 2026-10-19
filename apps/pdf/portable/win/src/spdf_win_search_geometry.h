#pragma once

/* Internal to spdf_win_search.cpp -- included by it, at the point where the
 * session struct is already complete, and by nobody else. Same arrangement and
 * the same reason as spdf_win_d2d_overlay.h and spdf_win_d2d_png.h: the file it
 * belongs to is at its size cap (tools/file-size-limits.md, which asks for a
 * focused file rather than a raised one), and this is the part that comes out
 * cleanly -- everything here reads the session and produces PIXELS, while what
 * is left there is the session's threading and lifecycle.
 *
 * An internal header rather than a second translation unit precisely so the
 * session struct stays private to one .cpp. Exposing it to get a file split
 * would trade a size limit for an encapsulation one, which is the worse deal.
 *
 * THE TWO MAPPINGS, both of which turn a match in PDF points into something on
 * the screen and neither of which has a GTK4 original to be differentially
 * tested against -- so both are covered instead by
 * portable/win/tests/find_overlay_test.c against a real document and a
 * hand-built scene:
 *
 *   rebuild_marks()  -- match -> a fraction of the document's height, for the
 *                       scrollbar heat-map, thinned as macOS thins it.
 *   apply_overlays() -- match -> a rectangle in canvas-local device pixels, for
 *                       the highlights the compose path draws over the pages.
 */

/* --- marks --------------------------------------------------------------- */

/* Document-height fractions for every match, then macOS's 1.5 pt thinning.
 *
 * THE FRACTIONS ARE AN APPROXIMATION, AND HERE IS THE BOUND. The document
 * layout is recomputed at ZOOM 1.0, not at the zoom the reader is actually
 * looking at, so a tick's fraction is not exactly where the live scroller would
 * put it.
 *
 * Why it is wrong at all: page margins are content-space and deliberately NOT
 * zoom- or DPI-scaled (spdf_win_layout.h says so in its own words), so the
 * pages grow with zoom while the 26 px between them does not. The margins'
 * share of the document therefore shrinks as the reader zooms in, and every
 * fraction after the first page drifts by that difference.
 *
 * How wrong: bounded by the margins' total share of the document height, which
 * is 26 px per page against a page of ~800 px at zoom 1 -- about 3%, falling
 * toward 0 as zoom rises. On an 800 px trough that is at most ~2 px of tick
 * position, or under one tick's own height, and it is a POSITION error only: no
 * tick appears, disappears, or changes order because of it. A short document
 * with very small pages is the worst case, and it is also the case where the
 * whole trough is barely scrollable.
 *
 * Why it has not been fixed: the exact answer needs the canvas's live layout,
 * which means the model builder reading a field on another track's struct at
 * paint time. A sub-tick position error is the better trade. If that coupling
 * ever becomes cheap -- if the scene starts carrying the layout, say -- pass the
 * live zoom in here instead of the 1.0 below and this whole comment goes away.
 * Do not "fix" it by scaling the margins; they are content-space on purpose. */
/* The minimap strip's markers: one (page, fraction-of-page-height) per match,
 * in match order, so the strip painter places each tick inside its page's own
 * slot with spdf_win_minimap_marker_y -- the GTK4 minimap's tick model, where
 * the position inside a page is EXACT rather than the scroller's whole-document
 * approximation, because the strip draws pages, not a lane. `sizes` is the
 * measured (or borrowed) page-size array rebuild_marks() already holds. */
static void rebuild_page_marks(SpdfWinFindSession* s, const SpdfWinPageSizePt* sizes, int size_count) {
    unsigned i, count = spdf_win_search_match_list_count(&s->list);
    int n = 0;
    s->page_mark_count = 0;
    if (count == 0 || !sizes) return;
    if ((int)count > s->page_mark_capacity) {
        SpdfWinFindPageMark* grown =
            (SpdfWinFindPageMark*)realloc(s->page_marks, sizeof(SpdfWinFindPageMark) * (size_t)count);
        if (!grown) return;
        s->page_marks = grown;
        s->page_mark_capacity = (int)count;
    }
    for (i = 0; i < count; ++i) {
        const SpdfWinSearchMatch* m = spdf_win_search_match_list_get(&s->list, i);
        double page_h;
        if (!m || m->page < 0 || m->page >= size_count) continue;
        page_h = sizes[m->page].height;
        s->page_marks[n].page = m->page;
        s->page_marks[n].fraction =
            page_h > 0.0 ? (float)spdf_win_search_clamp(((double)m->rect.y0 + (double)m->rect.y1) * 0.5 / page_h,
                                                        0.0, 1.0)
                         : 0.0f;
        n++;
    }
    s->page_mark_count = n;
}

static void rebuild_marks(SpdfWinFindSession* s) {
    SpdfWinLayout layout;
    unsigned i, count;
    int n = 0;

    s->mark_count = 0;
    s->active_mark = -1;
    s->page_mark_count = 0;
    count = spdf_win_search_match_list_count(&s->list);
    if (count == 0) return;

    memset(&layout, 0, sizeof(layout));
    {
        SpdfWinPageSizePt* sizes;
        int size_count;
        EnterCriticalSection(&s->lock);
        size_count = s->size_count;
        sizes = size_count > 0 ? (SpdfWinPageSizePt*)malloc(sizeof(SpdfWinPageSizePt) * (size_t)size_count) : NULL;
        if (sizes) memcpy(sizes, s->sizes, sizeof(SpdfWinPageSizePt) * (size_t)size_count);
        LeaveCriticalSection(&s->lock);
        if (!sizes) return;
        /* An unmeasured page borrows page 0, so a partial sweep still lays out. */
        for (i = 0; i < (unsigned)size_count; ++i)
            if (!(sizes[i].width > 0.0 && sizes[i].height > 0.0)) sizes[i] = sizes[0];
        if (!(sizes[0].width > 0.0 && sizes[0].height > 0.0)) {
            sizes[0].width = 612.0;
            sizes[0].height = 792.0;
        }
        rebuild_page_marks(s, sizes, size_count);
        spdf_win_layout_compute(&layout, sizes, size_count, 1.0, 0.0, SPDF_WIN_PAGE_MARGIN_H, SPDF_WIN_PAGE_MARGIN_V);
        free(sizes);
    }
    if (layout.count <= 0 || layout.canvas_h <= 0.0) {
        spdf_win_layout_clear(&layout);
        return;
    }

    if ((int)count > s->raw_capacity) {
        float* grown = (float*)realloc(s->raw_marks, sizeof(float) * (size_t)count);
        if (!grown) {
            spdf_win_layout_clear(&layout);
            return;
        }
        s->raw_marks = grown;
        s->raw_capacity = (int)count;
        free(s->marks);
        s->marks = (float*)malloc(sizeof(float) * (size_t)count);
        if (!s->marks) {
            s->raw_capacity = 0;
            spdf_win_layout_clear(&layout);
            return;
        }
    }
    for (i = 0; i < count; ++i) {
        const SpdfWinSearchMatch* m = spdf_win_search_match_list_get(&s->list, i);
        double center;
        if (!m || m->page < 0 || m->page >= layout.count) continue;
        center = layout.rects[m->page].y + ((double)m->rect.y0 + (double)m->rect.y1) * 0.5;
        s->raw_marks[n++] = (float)spdf_win_search_marker_fraction(center, layout.canvas_h);
    }
    spdf_win_layout_clear(&layout);
    /* The 1.5 is macOS POINTS and the lane is DEVICE pixels, so the gap is
     * DPI-scaled -- at 150% two ticks 2 px apart are 1.33 pt apart and macOS
     * would have merged them. */
    s->mark_count = spdf_win_find_thin_marks(s->raw_marks, n, s->current, s->lane_h,
                                             (float)SPDF_WIN_CHROME_SCROLL_MARKER_MIN_GAP * s->dpi_scale, s->marks, n,
                                             &s->active_mark);
}

/* --- overlays ------------------------------------------------------------ */

void spdf_win_find_apply_overlays_for(SpdfWinFindSession* s, struct spdf_win_scene* scene) {
    spdf_win_scene* sc = (spdf_win_scene*)scene;
    unsigned total;
    int need, n = 0, i;
    spdf_win_overlay active_ring;
    int has_active = 0;

    if (!sc) return;
    sc->overlays = NULL;
    sc->overlay_count = 0;
    if (!s || !sc->pages || sc->page_count <= 0) return;
    total = spdf_win_search_match_list_count(&s->list);
    if (total == 0) return;

    /* The trough height for the next frame's mark thinning: the vertical
     * scroller is as tall as the canvas, and after build_scene target_px_h IS
     * the canvas viewport (spdf_win_d2d.h's note -- client_px_h is the window).
     * Stale by one frame on a resize, which can only change whether two ticks
     * 1.5 px apart merge. */
    if (sc->target_px_h > 0) s->lane_h = (float)sc->target_px_h;
    if (sc->dpi_scale > 0.0f) s->dpi_scale = sc->dpi_scale;

    /* One per visible match, plus one ring for the active one. */
    need = (int)total + 1;
    if (need > s->overlay_capacity) {
        spdf_win_overlay* grown = (spdf_win_overlay*)realloc(s->overlays, sizeof(*grown) * (size_t)need);
        if (!grown) return;
        s->overlays = grown;
        s->overlay_capacity = need;
    }

    for (i = 0; i < sc->page_count; ++i) {
        const spdf_win_page_draw* pd = &sc->pages[i];
        double pw = 0.0, ph = 0.0;
        double sx, sy;
        unsigned m;

        if (!(pd->dest_w > 0.0f && pd->dest_h > 0.0f)) continue;
        EnterCriticalSection(&s->lock);
        if (s->sizes && pd->page_index >= 0 && pd->page_index < s->size_count) {
            pw = s->sizes[pd->page_index].width;
            ph = s->sizes[pd->page_index].height;
        }
        LeaveCriticalSection(&s->lock);
        if (!(pw > 0.0 && ph > 0.0)) continue;
        sx = (double)pd->dest_w / pw;
        sy = (double)pd->dest_h / ph;

        for (m = 0; m < total && n < s->overlay_capacity - 1; ++m) {
            const SpdfWinSearchMatch* match = spdf_win_search_match_list_get(&s->list, m);
            spdf_win_overlay* o;
            if (!match || match->page != pd->page_index) continue;
            o = &s->overlays[n++];
            o->page_index = match->page;
            o->x = pd->dest_x + (float)((double)match->rect.x0 * sx);
            o->y = pd->dest_y + (float)((double)match->rect.y0 * sy);
            o->w = (float)(((double)match->rect.x1 - (double)match->rect.x0) * sx);
            o->h = (float)(((double)match->rect.y1 - (double)match->rect.y0) * sy);
            o->kind = SPDF_WIN_OVERLAY_SEARCH_MATCH;
            o->alpha = 1.0f;
            /* The active match's ring is held back and appended LAST, because
             * the overlay painter draws in array order and the ring must sit on
             * top of every fill -- including the fills of matches on later
             * pages. */
            if ((int)m == s->current) {
                active_ring = *o;
                active_ring.kind = SPDF_WIN_OVERLAY_SEARCH_ACTIVE;
                has_active = 1;
            }
        }
    }
    if (has_active && n < s->overlay_capacity) s->overlays[n++] = active_ring;
    s->overlay_count = n;
    sc->overlays = n > 0 ? s->overlays : NULL;
    sc->overlay_count = n;
}
