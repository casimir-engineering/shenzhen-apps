/* spdf_win_md_code_marks.h -- routing a canvas click to a code box's controls.
 *
 * The sibling of spdf_win_annot_marks.h and deliberately the same shape: pure,
 * header-only, no app state and no document. The marks arrive already in CLIENT
 * DEVICE PIXELS, published by the paint that drew the pills
 * (spdf_win_md_code.h), so a pill is hit exactly where it was drawn -- which is
 * spdf_win_chrome.h's rule that painting and hit-testing agree only when they
 * use the same rectangles, obeyed by making them literally the same numbers.
 *
 * THE ORDER, and why. Inside the canvas the code controls are tested FIRST,
 * before a comment badge and before the canvas asks whether the point is over
 * text. That is the mac's precedence (SPDFMacMarkdownPageCanvas.mm:340-360 tries
 * the copy button, then the language control, then characterIndexAtPoint), and
 * it is what stops a click on a pill from starting a text selection: the router
 * returns an action that is not SPDF_WIN_CA_CANVAS, so canvas_press is never
 * called for it. Within the row the copy button wins over the language pill,
 * because their hit rectangles both carry 7px of slop and could overlap on a
 * narrow column -- and the copy button is the one that cannot be reached any
 * other way (the picker also has a menu row).
 *
 * The comparisons are inclusive, as in spdf_win_annot_marks.h, and the marks
 * carry their slop already.
 *
 * Included by spdf_win_chrome_input.h only, after the action enum and the hit
 * struct it fills are complete.
 */
#ifndef SPDF_WIN_MD_CODE_MARKS_H
#define SPDF_WIN_MD_CODE_MARKS_H

#include "spdf_win_chrome_state.h" /* SpdfWinMdCodeMark */

/* The router defines this before including us; a standalone test does not. */
#ifndef SPDF_WIN_CI_INLINE
#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_CI_INLINE __inline
#else
#define SPDF_WIN_CI_INLINE inline
#endif
#endif

/* Which control of which fence is under (x, y). Returns the fence index and
 * writes 1 to *out_copy for the copy button, 0 for the language pill; -1 when
 * the point is over neither. First match wins. */
static SPDF_WIN_CI_INLINE int spdf_win_md_code_mark_at(const SpdfWinMdCodeMark* marks, int count, float x, float y,
                                                       int* out_copy) {
    int i;
    if (out_copy) *out_copy = 0;
    if (!marks) return -1;
    for (i = 0; i < count; ++i) {
        const SpdfWinMdCodeMark* m = &marks[i];
        /* A stood-down copy button is an all-zero rectangle, which the width
         * test below rejects before the point test can match the origin. */
        if (m->cx1 > m->cx0 && x >= m->cx0 && x <= m->cx1 && y >= m->cy0 && y <= m->cy1) {
            if (out_copy) *out_copy = 1;
            return m->fence_index;
        }
        if (x >= m->lx0 && x <= m->lx1 && y >= m->ly0 && y <= m->ly1) return m->fence_index;
    }
    return -1;
}

#endif /* SPDF_WIN_MD_CODE_MARKS_H */
