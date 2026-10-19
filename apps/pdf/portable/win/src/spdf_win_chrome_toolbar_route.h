#pragma once

/* spdf_win_chrome_toolbar_route.h -- what a mouse event over the TOOLBAR means:
 * which of the row's eighteen controls, and for a pill which half. Plus, since
 * the empty state landed, the one control that is not in the row at all: the
 * "Open a PDF…" button in an empty canvas, whose geometry and whose whole policy
 * are in spdf_win_chrome_empty.h and whose ROUTE is at the bottom of this file --
 * here rather than there because turning a point into an action needs the enum
 * and the hit struct, and that header is deliberately reachable from the
 * PAINTERS too, which have neither.
 *
 * The toolbar case of spdf_win_chrome_input_route(), extracted when the
 * Markdown A−/A＋ pill took the router past the repo's 500-line cap
 * (tools/file-size-limits.md asks for a file, not a raised cap) -- the same
 * move, for the same reason, as spdf_win_sidebar_input.h beside it, and
 * included from the same place: spdf_win_chrome_input.h only, after the action
 * enum and the hit struct this fills are complete.
 *
 * Same rules as its caller: pure, header-only, no app state, and the row's
 * geometry comes from spdf_win_toolbar_layout() -- the function the painter
 * draws with, called here with the SAME model field -- so a click lands on what
 * was drawn. That last clause is the whole reason this file is not allowed to
 * decide anything about the row for itself: `m->markdown` adds a 64 pt pill in
 * the middle of the toolbar, and a router that assumed either answer would
 * hit-test every control after the zoom pill in the wrong place on half the
 * documents this app opens.
 */

/* Which controls a window with no document may offer, and where its one button
 * is. Included HERE rather than from spdf_win_chrome_input.h so the dependency
 * sits with the code that uses it; the header is #pragma once and reachable from
 * the painters too, so this costs nothing twice. */
#include "spdf_win_chrome_empty.h"

static SPDF_WIN_CI_INLINE void spdf_win_toolbar_route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m,
                                                      float x, float y, int button, float s, SpdfWinChromeHit* out) {
    SpdfWinToolbarLayout tb;
    int segment = 0;
    spdf_win_toolbar_item item;

    if (button != SPDF_WIN_CB_LEFT) return;
    spdf_win_toolbar_layout(l->toolbar, s, m->markdown, &tb);
    item = spdf_win_toolbar_hit(&tb, x, y, &segment);
    /* A CONTROL DRAWN DISABLED IS NOT A TARGET. With no document open the
     * painter greys most of this row (spdf_win_chrome_empty.h transcribes
     * macOS's -updateControls list), and it is not enough for those controls to
     * happen to do nothing: every handler below would refuse a NULL canvas
     * anyway, so a click on a dimmed arrow was already inert -- but inert BY
     * ACCIDENT, four files away, and the press still took the focus off whatever
     * had it and still cost a repaint. Refused HERE, from the same test the
     * painter dimmed with, a dimmed control reports "not a target" and the point
     * is swallowed by the bar exactly as a click between two controls is. */
    if (!spdf_win_toolbar_item_enabled(m, item)) return;
    switch (item) {
        case SPDF_WIN_TB_SIDEBAR_TOGGLE: out->action = SPDF_WIN_CA_TOGGLE_SIDEBAR; return;
        case SPDF_WIN_TB_MINIMAP_TOGGLE: out->action = SPDF_WIN_CA_TOGGLE_MINIMAP; return;
        case SPDF_WIN_TB_READING_THEME: out->action = SPDF_WIN_CA_TOGGLE_THEME; return;
        case SPDF_WIN_TB_PAGE_PILL:
            /* chevron.left / chevron.right, in that order (:2996-3000). */
            out->action = segment == 0 ? SPDF_WIN_CA_PREV_PAGE : SPDF_WIN_CA_NEXT_PAGE;
            return;
        case SPDF_WIN_TB_ZOOM_PILL:
            /* minus / plus, in that order (:3026-3030). */
            out->action = segment == 0 ? SPDF_WIN_CA_ZOOM_OUT : SPDF_WIN_CA_ZOOM_IN;
            return;
        case SPDF_WIN_TB_MD_TEXT_PILL:
            /* A− / A＋, in that order, and the pill is in the row only on a
             * Markdown tab -- so this arm is unreachable on a PDF rather than
             * inert on one. The caller posts the command, as the two power
             * tools below do. */
            out->action = segment == 0 ? SPDF_WIN_CA_MD_TEXT_SMALLER : SPDF_WIN_CA_MD_TEXT_LARGER;
            return;
        case SPDF_WIN_TB_FIT_POPUP: out->action = SPDF_WIN_CA_CYCLE_FIT; return;
        case SPDF_WIN_TB_OVERFLOW: out->action = SPDF_WIN_CA_APP_MENU; return;
        /* The two power tools. Their handlers belong to another track; the
         * caller posts the command (spdf_win_chrome_field_ui.h
         * chrome_post_command). */
        case SPDF_WIN_TB_OCR: out->action = SPDF_WIN_CA_OCR; return;
        case SPDF_WIN_TB_TRANSLATE: out->action = SPDF_WIN_CA_TRANSLATE_SELECTION; return;
        /* The two text fields and the two find controls. All four were drawn and
         * inert while the query and the page number could only be changed from
         * outside the app. */
        case SPDF_WIN_TB_FIND_FIELD: out->action = SPDF_WIN_CA_FOCUS_FIND; return;
        case SPDF_WIN_TB_PAGE_FIELD: out->action = SPDF_WIN_CA_FOCUS_PAGE; return;
        case SPDF_WIN_TB_FIND_REGEX: out->action = SPDF_WIN_CA_TOGGLE_REGEX; return;
        case SPDF_WIN_TB_FIND_PILL:
            /* chevron.up / chevron.down -- previous match, then next, the order
             * macOS's find segments use (:3073-3079). */
            out->action = segment == 0 ? SPDF_WIN_CA_FIND_PREV : SPDF_WIN_CA_FIND_NEXT;
            return;
        default: return;
    }
}

/* WHAT A POINT IN THE EMPTY CANVAS MEANS. Returns 1 when the point belongs to
 * the "Open a PDF…" button, which is when the caller must not go on to route it
 * as canvas.
 *
 * IT CLAIMS THE POINT FOR EVERY BUTTON AND FOR A BARE HOVER TOO, not just for a
 * left press. That is the rule the minimap strip and the two scrollers already
 * follow in spdf_win_chrome_input.h: a press inside a control must never fall
 * through and become a document gesture. There is no document to pan here, so
 * the practical difference is nil today -- and it is the kind of nil that stops
 * being nil the first time anything else is drawn on this canvas. */
static SPDF_WIN_CI_INLINE int spdf_win_chrome_empty_route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m,
                                                          float x, float y, int button, SpdfWinChromeHit* out) {
    if (!out || !spdf_win_chrome_empty_open_hit(l, m, x, y)) return 0;
    if (button == SPDF_WIN_CB_LEFT) out->action = SPDF_WIN_CA_OPEN_DOC;
    return 1;
}
