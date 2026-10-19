#pragma once

/* spdf_win_annot_marks.h -- what a mouse event over the CANVAS means once
 * there are comment markers on it: a press on a badge opens the editor, a
 * pointer over an annotation's bounds names it for the hover preview, and
 * everything else is still the document's own pan/select.
 *
 * The canvas case of spdf_win_chrome_input_route(), extracted the way
 * spdf_win_sidebar_input.h was and for the same two reasons: the router is at
 * its 500-line cap (tools/file-size-limits.md asks for a file, not a raised
 * cap), and the rule belongs beside the geometry it tests. Same discipline as
 * its caller: pure, header-only, no app state, no document -- the marks arrive
 * in the MODEL, already in client device pixels, published by the paint that
 * drew them (spdf_win_annot.h spdf_win_annot_publish_geometry), so a badge is
 * hit where it was drawn. Included by spdf_win_chrome_input.h only, after the
 * action enum and the hit struct it fills are complete.
 *
 * THE ORDER IS GTK'S. spdf_annot.c attaches the badge gesture in the CAPTURE
 * phase and claims the sequence, "so the selection/link drag gesture never
 * starts on a badge" (:1223-1239); here the badge is tested before the caller
 * gets to ask the canvas whether the point is over text, which is the same
 * precedence. Only the BADGE opens the editor -- the whole annotation stays
 * selectable text, exactly as that comment says.
 *
 * The comparisons are inclusive (<=) because the GTK hit tests are
 * (spdf_annot.c:242, :255-256) and the marks carry the slop already.
 */

/* The comment whose mark contains (x, y): the badge only when `badge_only`,
 * else the inflated bounds. First match wins, as in the originals. -1 for none. */
static SPDF_WIN_CI_INLINE int spdf_win_annot_mark_at(const SpdfWinAnnotMark* marks, int count, float x, float y,
                                                     int badge_only) {
    int i;
    if (!marks) return -1;
    for (i = 0; i < count; ++i) {
        const SpdfWinAnnotMark* m = &marks[i];
        int hit = badge_only ? (x >= m->bx0 && x <= m->bx1 && y >= m->by0 && y <= m->by1)
                             : (x >= m->x0 && x <= m->x1 && y >= m->y0 && y <= m->y1);
        if (hit) return m->comment_index;
    }
    return -1;
}

/* The canvas case. `index` carries the comment under the pointer for every
 * button (the hover preview reads it off a bare move); a LEFT press on a
 * badge becomes SPDF_WIN_CA_ANNOT_EDIT with that comment in `index`. */
static SPDF_WIN_CI_INLINE void spdf_win_annot_route(const SpdfWinChromeModel* m, float x, float y, int button,
                                                    SpdfWinChromeHit* out) {
    int badge;
    out->action = SPDF_WIN_CA_CANVAS;
    out->index = spdf_win_annot_mark_at(m->annot_marks, m->annot_mark_count, x, y, 0);
    if (button != SPDF_WIN_CB_LEFT) return;
    badge = spdf_win_annot_mark_at(m->annot_marks, m->annot_mark_count, x, y, 1);
    if (badge >= 0) {
        out->action = SPDF_WIN_CA_ANNOT_EDIT;
        out->index = badge;
    }
}
