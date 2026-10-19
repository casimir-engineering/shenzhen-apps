/* spdf_win_chrome_input.h — what a mouse event over the chrome MEANS.
 *
 * WHAT THIS IS: one pure function that turns (how the client area is divided,
 * what the chrome is showing, where the pointer is, which button) into an
 * ACTION plus the hover state the painter needs. No Win32, no Direct2D, no app
 * state, no allocation, header-only -- the third member of the family
 * spdf_win_chrome.h and spdf_win_tabstrip.h belong to, and testable the same way
 * (portable/win/tests/chrome_input_test.c).
 *
 * WHY IT IS A SEPARATE LAYER, given that the window could just hit-test inline.
 *
 *   1. spdf_win_chrome.h says the reason out loud: "Hit-testing and painting
 *      must agree exactly. On macOS they do because AppKit owns both; here they
 *      agree only if they call the same functions." Everything below calls
 *      spdf_win_chrome_hit(), spdf_win_tabstrip_hit(), spdf_win_tabstrip_close_hit()
 *      and spdf_win_toolbar_hit() -- the same four the painters use -- and
 *      derives nothing of its own. Re-deriving would mean re-deriving their bug
 *      fixes too (portable/docs/windows-port-plan.md §2.3).
 *   2. A window proc cannot be tested. This can: a click at (x, y) on a
 *      hand-built layout must produce a named action, and that assertion needs
 *      no HWND, no desktop and no document -- which is the only kind of evidence
 *      this port has ever been able to collect in bulk.
 *   3. Which control does what is PRODUCT POLICY, and spdf_win_window.h already
 *      states the rule for that: "the caller owns the keymap: which key means
 *      'next page' is product policy, not window plumbing." A mouse map is the
 *      same thing. So the window translates messages, this header names the
 *      meaning, and spdf_win_main.cpp performs it.
 *
 * WHAT IT DELIBERATELY DOES NOT DO: it does not touch the canvas, the tab model,
 * or the chrome model. It reports SPDF_WIN_CA_CANVAS and lets the caller run the
 * existing pan/zoom path unchanged, which is what keeps drag-to-pan and
 * Ctrl+wheel exactly as they were everywhere the chrome is not.
 *
 * COORDINATES. Client device pixels in, matching WM_LBUTTONDOWN's own space and
 * the space every rect in SpdfWinChromeLayout is expressed in. The canvas is a
 * SUB-RECT of the client now, so a caller forwarding a point to the canvas must
 * subtract layout->canvas.x/y first: spdf_win_chrome_input_canvas_x/y() below do
 * that conversion so no caller has to remember to. Getting it wrong makes a
 * cursor-anchored zoom drift by the sidebar's width.
 */
#ifndef SPDF_WIN_CHROME_INPUT_H
#define SPDF_WIN_CHROME_INPUT_H

#include "spdf_win_chrome.h"
/* The sidebar's own bands and the segment control's geometry come in through
 * spdf_win_sidebar_input.h below, which costs this header <windows.h>; accepted
 * for the reason that header's comment gives -- the alternative is a split
 * hit-test. */
#include "spdf_win_chrome_scroll.h"
#include "spdf_win_chrome_toolbar.h"
#include "spdf_win_tabstrip.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_CI_INLINE __inline
#else
#define SPDF_WIN_CI_INLINE inline
#endif

/* Which button produced the event. NONE is a bare move -- the hover case, which
 * still needs routing because it is what lights the tab strip's hover branches
 * and what chooses the cursor. */
typedef enum spdf_win_chrome_button {
    SPDF_WIN_CB_NONE = 0,
    SPDF_WIN_CB_LEFT,
    SPDF_WIN_CB_MIDDLE
} spdf_win_chrome_button;

/* What the caller should do. Named after the INTENT, not after the control, so
 * the keyboard and the mouse can converge on the same handler -- the zoom pill
 * and VK_ADD both mean SPDF_WIN_CA_ZOOM_IN, and spdf_win_main.cpp's existing
 * `+`/`-` logic is reused rather than restated. */
typedef enum spdf_win_chrome_action {
    SPDF_WIN_CA_NONE = 0,
    /* Not chrome. Run the document's own pan/zoom path, in CANVAS-LOCAL
     * coordinates. */
    SPDF_WIN_CA_CANVAS,
    SPDF_WIN_CA_SELECT_TAB,   /* `index` */
    SPDF_WIN_CA_CLOSE_TAB,    /* `index` */
    SPDF_WIN_CA_NEW_TAB,      /* the strip's `+` */
    SPDF_WIN_CA_TAB_OVERFLOW, /* the strip's `…` */
    /* The TOOLBAR's `…`. Opens the whole app menu as a popup, which is where
     * the menu lives now that there is no menu bar -- see
     * spdf_win_menu_app_popup(). Distinct from TAB_OVERFLOW above: that one
     * lists documents, this one lists commands. */
    SPDF_WIN_CA_APP_MENU,
    /* The EMPTY canvas's "Open a PDF…" button (spdf_win_chrome_empty.h), posted
     * as SPDF_WIN_CMD_OPEN -- the command Ctrl+O and the strip's `+` also post. */
    SPDF_WIN_CA_OPEN_DOC,
    SPDF_WIN_CA_PREV_PAGE,
    SPDF_WIN_CA_NEXT_PAGE,
    SPDF_WIN_CA_ZOOM_OUT,
    SPDF_WIN_CA_ZOOM_IN,
    SPDF_WIN_CA_CYCLE_FIT, /* the fit popup, until there is a real menu */
    SPDF_WIN_CA_TOGGLE_SIDEBAR,
    SPDF_WIN_CA_TOGGLE_MINIMAP,
    SPDF_WIN_CA_TOGGLE_THEME,
    /* THE THREE TYPEABLE FIELDS. A click on one gives it the keyboard; the
     * characters then arrive as SPDF_WIN_INPUT_CHAR and are applied with
     * spdf_win_chrome_text.h. Three actions rather than one carrying a field id
     * because the caller stores the focus and nothing else, and an id kept
     * beside it is an id that can go stale against it -- the same reasoning the
     * two scroller drags already state below. */
    SPDF_WIN_CA_FOCUS_FIND,
    SPDF_WIN_CA_FOCUS_PAGE,
    SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER,
    /* The find group's other two controls, which had nowhere to go while the
     * query came from the environment. */
    SPDF_WIN_CA_TOGGLE_REGEX,
    SPDF_WIN_CA_FIND_PREV,
    SPDF_WIN_CA_FIND_NEXT,
    /* A click on a row of the sidebar's list. Chapters: `index` is the row,
     * which the caller turns into a page through the content provider (the
     * router must not resolve it on a mouse move). Comments and Search: `index`
     * is the LIST-LOCAL Y in device px, scroll included -- see
     * spdf_win_sidebar_input.h for why. */
    SPDF_WIN_CA_SIDEBAR_ROW,
    /* A click on the Chapters / Comments / Search segment control. `index` is
     * the segment, which IS the section number (0, 1, 2). */
    SPDF_WIN_CA_SIDEBAR_SECTION,
    /* A LEFT PRESS INSIDE THE MINIMAP STRIP. Click-to-jump or viewport drag is
     * the caller's call, against the frame the strip was painted from
     * (spdf_win_search_map.h). Names the region, like CANVAS; never pans. */
    SPDF_WIN_CA_MINIMAP,
    /* THE MINIMAP DRAG IN PROGRESS. THE ROUTER NEVER RETURNS THIS: the caller
     * arms it on top of a MINIMAP press, as DRAG_TAB and CANVAS_SELECT are. */
    SPDF_WIN_CA_MINIMAP_DRAG,
    /* The toolbar's OCR and translate buttons: the caller posts SPDF_WIN_CMD_OCR
     * / _TRANSLATE_SELECTION so another track's handler gets them through the
     * one command switch like every other route in. */
    SPDF_WIN_CA_OCR,
    SPDF_WIN_CA_TRANSLATE_SELECTION,
    /* The Markdown A−/A＋ pill, posted as SPDF_WIN_CMD_MD_TEXT_SMALLER /
     * _LARGER so the pill and View > Smaller/Larger Text are one handler. The
     * pill is in the row only on a Markdown tab, so these never arrive on a
     * PDF -- but the commands are inert there anyway
     * (spdf_win_md_commands.h). */
    SPDF_WIN_CA_MD_TEXT_SMALLER,
    SPDF_WIN_CA_MD_TEXT_LARGER,
    /* A press on a split divider. The caller then follows the pointer and asks
     * spdf_win_chrome_sidebar_drag_pt() / _minimap_drag_pt() for the new width,
     * which clamp exactly as macOS's NSSplitView does. */
    SPDF_WIN_CA_DRAG_SIDEBAR,
    SPDF_WIN_CA_DRAG_MINIMAP,
    /* A press on a scroller's THUMB. Like the divider drags this only arms the
     * gesture; the caller then feeds pointer deltas to
     * spdf_win_scroll_drag_pos(). Two actions rather than one with the axis in a
     * field because the caller stores the armed action and nothing else -- an
     * axis kept beside it is an axis that can go stale against it. */
    SPDF_WIN_CA_DRAG_VSCROLL,
    SPDF_WIN_CA_DRAG_HSCROLL,
    /* A TAB BEING DRAGGED TO A NEW POSITION. THE ROUTER NEVER RETURNS THIS: a
     * press on a tab is a SELECT_TAB, which must happen immediately (macOS
     * selects on mouse-down), and the reorder is a gesture the CALLER arms on
     * top of it. It is in this enum rather than in a second one because the
     * caller stores exactly one "what is the pointer doing" value, and the
     * cursor enum next door already carries SPDF_WIN_CC_SIZEALL on the same
     * terms -- "produced by the caller's drag state rather than by the router". */
    SPDF_WIN_CA_DRAG_TAB,
    /* A LEFT DRAG OVER THE PAGE THAT IS SELECTING TEXT rather than panning.
     * Like SPDF_WIN_CA_DRAG_TAB above, THE ROUTER NEVER RETURNS THIS: a press on
     * the page is SPDF_WIN_CA_CANVAS, and which of the two gestures it becomes
     * depends on whether there is text under the pointer -- a question about the
     * DOCUMENT, which this header knows nothing about and must not learn. The
     * caller asks the canvas and stores the answer here. See
     * spdf_win_chrome_canvas_ui.h. */
    SPDF_WIN_CA_CANVAS_SELECT,
    /* A click on the trough, before or after the thumb. Instantaneous, so the
     * AXIS comes from `part` (VSCROLL or HSCROLL), which the hit always carries.
     * "BACK" is up on the vertical scroller and left on the horizontal one. */
    SPDF_WIN_CA_SCROLL_PAGE_BACK,
    SPDF_WIN_CA_SCROLL_PAGE_FORWARD,
    /* A LEFT PRESS ON A COMMENT MARKER'S BADGE: `index` is the comment to edit
     * (spdf_win_annot_marks.h). For a CANVAS hit, `index` is the comment under
     * the pointer for the hover preview, or -1. */
    SPDF_WIN_CA_ANNOT_EDIT,
    /* A LEFT PRESS ON A MARKDOWN CODE BOX'S PILLS: `index` is the fence
     * (spdf_win_md_code_marks.h). Tested before the badge and before the point
     * reaches the canvas as text, which is the mac's precedence and what stops
     * a click on a pill from starting a text selection. */
    SPDF_WIN_CA_MD_CODE_COPY,
    SPDF_WIN_CA_MD_CODE_LANGUAGE
} spdf_win_chrome_action;

/* Cursors as an enum rather than as an HCURSOR, so this header stays free of
 * user32 and a test can assert "the pointer over a divider asks for the
 * left-right resize cursor" with no window. macOS uses resizeLeftRight over its
 * dividers (SPDFMacUIHelpers.mm:425-431); IDC_SIZEWE is the same thing. */
typedef enum spdf_win_chrome_cursor {
    SPDF_WIN_CC_ARROW = 0,
    SPDF_WIN_CC_SIZEWE,
    /* IDC_SIZEALL, shown while a drag is panning the document. Produced by the
     * caller's drag state rather than by the router below: a point over the
     * canvas is an arrow until a button goes down on it. */
    SPDF_WIN_CC_SIZEALL,
    /* IDC_IBEAM over selectable text and IDC_HAND over a link. Also produced by
     * the CALLER rather than by the router: what is under a canvas point is a
     * question about the document, and this header knows nothing about
     * documents. The caller asks spdf_win_canvas_cursor_at() and overwrites the
     * router's SPDF_WIN_CC_ARROW with the answer. */
    SPDF_WIN_CC_IBEAM,
    SPDF_WIN_CC_HAND
} spdf_win_chrome_cursor;

/* WHAT THE POINT IS TO THE WINDOW MANAGER, as opposed to the app. The strip is
 * the title bar (spdf_win_tabstrip.h's header), so a point in it is one of
 * three things to Win32: ours (a tab, its close box, the `+`, the overflow --
 * HTCLIENT, and the click never moves the window), empty title bar (HTCAPTION:
 * a drag moves the window, a double-click toggles maximize -- macOS's
 * SPDFMacWindowChrome policy exactly, handoff §3.6), or one of the three caption
 * buttons (HTMINBUTTON / HTMAXBUTTON / HTCLOSE, which is what makes Windows 11's
 * Snap Layouts flyout appear over OUR maximize button). Everything below the
 * strip is CLIENT. The window's WM_NCHITTEST maps these onto the HT codes and
 * knows nothing else; the router decides here, from the same geometry the
 * painter draws, so the drag region is exactly the pixels that look empty. */
typedef enum spdf_win_chrome_nc {
    SPDF_WIN_NC_CLIENT = 0,
    SPDF_WIN_NC_CAPTION,
    SPDF_WIN_NC_MINIMIZE,
    SPDF_WIN_NC_MAXIMIZE,
    SPDF_WIN_NC_CLOSE
} spdf_win_chrome_nc;

typedef struct SpdfWinChromeHit {
    spdf_win_chrome_action action;
    int index; /* tab index for SELECT_TAB / CLOSE_TAB, else -1 */
    spdf_win_chrome_part part;
    /* spdf_win_chrome_nc: the window manager's view of the point. Independent of
     * `button`, because WM_NCHITTEST asks before any button is down. */
    int nc;
    /* Straight into SpdfWinChromeModel::hot_tab / hot_close, so the painter's
     * existing hover branches light up without the caller deciding anything.
     * -1 when nothing is hovered, which is the value the model documents. */
    int hot_tab;
    int hot_close;
    /* Which part of the scroller under the pointer, as spdf_win_scroll_part, or
     * SPDF_WIN_SCROLL_NONE when the pointer is not on one. Reported for a bare
     * hover as well as for a press, because it is what lights the thumb --
     * the caller hands it to spdf_win_chrome_scroll_set_hot(). */
    spdf_win_scroll_part scroll_part;
    spdf_win_chrome_cursor cursor;
} SpdfWinChromeHit;

/* The sidebar, toolbar and empty-canvas cases, extracted for the size ratchet;
 * all three need the types above. */
#include "spdf_win_chrome_toolbar_route.h"
#include "spdf_win_sidebar_input.h"
#include "spdf_win_annot_marks.h"
#include "spdf_win_md_code_marks.h" /* the canvas case: comment markers, same reason */

/* The band, the track and the two fractions for one scroller, picked by part.
 * A helper rather than an if-else at each of the four call sites (the router
 * below, the drag, the hover repaint and the test), because picking vscroll's
 * rect with hscroll's fraction is a bug that produces a thumb in a plausible
 * place and is therefore invisible until someone drags it. */
typedef struct SpdfWinScrollBar {
    SpdfWinChromeRect band;
    SpdfWinChromeRect track;
    float pos;
    float visible;
    int axis; /* spdf_win_scroll_axis */
} SpdfWinScrollBar;

static SPDF_WIN_CI_INLINE void spdf_win_chrome_scroll_bar(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m,
                                                          spdf_win_chrome_part part, SpdfWinScrollBar* out) {
    float s;
    if (!out) return;
    out->band = spdf_win_chrome_zero();
    out->track = spdf_win_chrome_zero();
    out->pos = 0.0f;
    out->visible = 0.0f;
    out->axis = SPDF_WIN_SCROLL_V;
    if (!l || !m) return;
    s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    if (part == SPDF_WIN_CHROME_HSCROLL) {
        out->band = l->hscroll;
        out->pos = m->h_pos;
        out->visible = m->h_visible;
        out->axis = SPDF_WIN_SCROLL_H;
    } else if (part == SPDF_WIN_CHROME_VSCROLL) {
        out->band = l->vscroll;
        out->pos = m->v_pos;
        out->visible = m->v_visible;
    } else {
        return;
    }
    out->track = spdf_win_scroll_track(out->band, s, out->axis);
}

/* A client point in CANVAS-LOCAL device pixels. The canvas was laid out against
 * the canvas rect's size (spdf_win_canvas_set_viewport is given
 * chrome_layout.canvas.w/h), so every canvas API -- scroll, and above all
 * spdf_win_canvas_zoom_at()'s anchor -- expects the origin at the canvas's
 * top-left corner and not at the window's. Before the chrome existed the two
 * were the same point and the window passed client coordinates straight through;
 * they are 245 px apart now with the sidebar open, and a Ctrl+wheel zoom fed the
 * un-translated point anchors on a document location that is not under the
 * cursor -- it drifts by exactly the offset. */
static SPDF_WIN_CI_INLINE float spdf_win_chrome_input_canvas_x(const SpdfWinChromeLayout* l, float client_x) {
    return l ? client_x - l->canvas.x : client_x;
}

static SPDF_WIN_CI_INLINE float spdf_win_chrome_input_canvas_y(const SpdfWinChromeLayout* l, float client_y) {
    return l ? client_y - l->canvas.y : client_y;
}

/* THE ONE ENTRY POINT.
 *
 * `out` is always fully written, so a caller may read every field after any
 * call. A NULL layout or model yields NONE with no hover, which is the state
 * before the first paint has laid anything out.
 *
 * Order of decisions, and why each is where it is:
 *
 *   dividers first -- spdf_win_chrome_hit() already tests them first because
 *   their grab area overlaps their neighbours', and re-ordering here would make
 *   them unusable;
 *
 *   inside the strip, the CLOSE box before the tab -- the close circle lies
 *   inside the tab, so testing the tab first would swallow every close click
 *   (spdf_win_tabstrip.h says this at spdf_win_tabstrip_close_hit);
 *
 *   the canvas LAST, and only ever as CANVAS, so the fall-through to pan/zoom
 *   happens exactly where the pages are drawn and nowhere else. A click on the
 *   toolbar must not pan the document. */
static SPDF_WIN_CI_INLINE void spdf_win_chrome_input_route(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m,
                                                          float x, float y, int button, SpdfWinChromeHit* out) {
    float s;
    if (!out) return;
    out->action = SPDF_WIN_CA_NONE;
    out->index = -1;
    out->part = SPDF_WIN_CHROME_NONE;
    out->hot_tab = -1;
    out->hot_close = -1;
    out->scroll_part = SPDF_WIN_SCROLL_NONE;
    out->cursor = SPDF_WIN_CC_ARROW;
    out->nc = SPDF_WIN_NC_CLIENT;
    if (!l || !m) return;

    s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    out->part = spdf_win_chrome_hit(l, x, y);

    switch (out->part) {
        case SPDF_WIN_CHROME_CAPTION: {
            /* The three buttons, in strip-local points like every other strip
             * hit. A point in the reserve that is on none of them (a reserve
             * rounded a pixel wider than three buttons) is empty title bar. No
             * app action ever: the window performs minimize/maximize/close
             * itself from the HT code, as Windows expects. */
            int b = spdf_win_tabstrip_caption_hit(l->tabstrip.w / s, l->tabstrip.h / s, (x - l->tabstrip.x) / s,
                                                  (y - l->tabstrip.y) / s);
            if (b == SPDF_WIN_CAPTION_MINIMIZE) out->nc = SPDF_WIN_NC_MINIMIZE;
            else if (b == SPDF_WIN_CAPTION_MAXIMIZE) out->nc = SPDF_WIN_NC_MAXIMIZE;
            else if (b == SPDF_WIN_CAPTION_CLOSE) out->nc = SPDF_WIN_NC_CLOSE;
            else out->nc = SPDF_WIN_NC_CAPTION;
            return;
        }

        case SPDF_WIN_CHROME_SIDEBAR_DIVIDER:
            out->cursor = SPDF_WIN_CC_SIZEWE;
            if (button == SPDF_WIN_CB_LEFT) out->action = SPDF_WIN_CA_DRAG_SIDEBAR;
            return;
        case SPDF_WIN_CHROME_MINIMAP_DIVIDER:
            out->cursor = SPDF_WIN_CC_SIZEWE;
            if (button == SPDF_WIN_CB_LEFT) out->action = SPDF_WIN_CA_DRAG_MINIMAP;
            return;

        case SPDF_WIN_CHROME_TABSTRIP: {
            /* The strip's transcribed arithmetic works in strip-local POINTS,
             * exactly as SPDFMacTabStripView does, so the pointer is divided by
             * the DPI scale rather than the metrics being multiplied by it --
             * spdf_win_tabstrip.h's UNITS paragraph states this is the intended
             * direction, and it is what the painter's inverse conversion pairs
             * with. Passing device pixels in would silently change every
             * threshold in that header (112, 320, the 40 pt close cutoff). */
            float xp = (x - l->tabstrip.x) / s;
            float yp = (y - l->tabstrip.y) / s;
            float strip_w = l->tabstrip.w / s;
            float strip_h = l->tabstrip.h / s;
            int close = spdf_win_tabstrip_close_hit(strip_w, m->tab_count, m->selected_tab, xp, yp);
            int tab = spdf_win_tabstrip_hit(strip_w, strip_h, m->tab_count, m->selected_tab, xp, yp);
            int on_plus = spdf_win_tabstrip_rect_contains(spdf_win_tabstrip_plus_rect(strip_w), xp, yp);
            int on_overflow =
                spdf_win_tabstrip_rect_contains(spdf_win_tabstrip_overflow_rect(strip_w, m->tab_count), xp, yp);

            if (close >= 0) out->hot_close = close;
            if (tab >= 0) out->hot_tab = tab;
            /* Title bar wherever there is no control -- with the tab's forgiving
             * 6 pt slop counted as the tab, so the pixels that select a tab and
             * the pixels that drag the window are complementary. Decided before
             * the button branches: WM_NCHITTEST asks with no button at all. */
            out->nc = (close >= 0 || tab >= 0 || on_plus || on_overflow) ? SPDF_WIN_NC_CLIENT : SPDF_WIN_NC_CAPTION;

            if (button == SPDF_WIN_CB_MIDDLE) {
                /* Middle-click closes a tab, which is macOS's behaviour and the
                 * desktop's. It closes the TAB, not the close box: aiming at a
                 * 16 pt circle with the middle button is not a gesture anyone
                 * makes. This is also why middle-drag can still pan -- the strip
                 * is the only place a middle button means something else. */
                if (tab >= 0) {
                    out->action = SPDF_WIN_CA_CLOSE_TAB;
                    out->index = tab;
                }
                return;
            }
            if (button != SPDF_WIN_CB_LEFT) return;
            if (close >= 0) {
                out->action = SPDF_WIN_CA_CLOSE_TAB;
                out->index = close;
                return;
            }
            if (tab >= 0) {
                out->action = SPDF_WIN_CA_SELECT_TAB;
                out->index = tab;
                return;
            }
            if (on_plus) {
                out->action = SPDF_WIN_CA_NEW_TAB;
                return;
            }
            if (on_overflow) out->action = SPDF_WIN_CA_TAB_OVERFLOW;
            return;
        }

        /* THE TOOLBAR: its eighteen controls and the halves of its pills, in
         * spdf_win_chrome_toolbar_route.h. */
        case SPDF_WIN_CHROME_TOOLBAR: spdf_win_toolbar_route(l, m, x, y, button, s, out); return;

        /* THE SIDEBAR: its segment control, its filter field and its list, in
         * spdf_win_sidebar_input.h. */
        case SPDF_WIN_CHROME_SIDEBAR: spdf_win_sidebar_route(l, m, x, y, button, s, out); return;

        /* THE MINIMAP STRIP. A left press is a minimap action -- click or drag,
         * the caller decides against the painted frame. Any other button, and a
         * bare hover (an arrow cursor, as over the canvas), does nothing. The
         * strip never falls through to the canvas: a press inside it must not
         * pan the document, which is what would happen if it did. */
        case SPDF_WIN_CHROME_MINIMAP:
            if (button == SPDF_WIN_CB_LEFT) out->action = SPDF_WIN_CA_MINIMAP;
            return;

        /* THE TWO SCROLLERS, and note where they sit in this switch: BEFORE the
         * canvas case, so a press on a trough can never fall through to
         * SPDF_WIN_CA_CANVAS and pan the document. They are inside the canvas
         * REGION, and the drag they arm looks superficially like a pan; getting
         * this order wrong would give a scroller that scrolls and pans at once.
         *
         * The cursor stays an ARROW over both. Windows does not change it over a
         * scrollbar and neither does AppKit, and a resize cursor over a trough
         * would suggest the panel edge next to it. */
        case SPDF_WIN_CHROME_VSCROLL:
        case SPDF_WIN_CHROME_HSCROLL: {
            SpdfWinScrollBar bar;
            spdf_win_chrome_scroll_bar(l, m, out->part, &bar);
            out->scroll_part = spdf_win_scroll_hit(bar.track, bar.pos, bar.visible, spdf_win_scroll_thumb_min(s), x, y,
                                                  bar.axis);
            if (button != SPDF_WIN_CB_LEFT) return;
            switch (out->scroll_part) {
                case SPDF_WIN_SCROLL_THUMB:
                    out->action = out->part == SPDF_WIN_CHROME_HSCROLL ? SPDF_WIN_CA_DRAG_HSCROLL
                                                                       : SPDF_WIN_CA_DRAG_VSCROLL;
                    return;
                case SPDF_WIN_SCROLL_TROUGH_BACK: out->action = SPDF_WIN_CA_SCROLL_PAGE_BACK; return;
                case SPDF_WIN_SCROLL_TROUGH_FORWARD: out->action = SPDF_WIN_CA_SCROLL_PAGE_FORWARD; return;
                /* The 2 pt inset at each end of the band is not part of the
                 * track. Swallowed, not forwarded: a 3 px strip that pans the
                 * document is worse than one that does nothing. */
                default: return;
            }
        }

        case SPDF_WIN_CHROME_CANVAS: {
            /* The code pills first, for the reason spdf_win_md_code_marks.h
             * gives: an action that is not SPDF_WIN_CA_CANVAS never reaches
             * canvas_press, so a click on a pill cannot begin a selection. */
            if (button == SPDF_WIN_CB_LEFT && m->md_code_mark_count > 0) {
                int md_copy = 0;
                int md_fence =
                    spdf_win_md_code_mark_at(m->md_code_marks, m->md_code_mark_count, x, y, &md_copy);
                if (md_fence >= 0) {
                    out->action = md_copy ? SPDF_WIN_CA_MD_CODE_COPY : SPDF_WIN_CA_MD_CODE_LANGUAGE;
                    out->index = md_fence;
                    return;
                }
            }
            /* The empty state's Open button first, for the same precedence
             * reason: it is drawn on this canvas (spdf_win_chrome_empty.h). */
            if (!spdf_win_chrome_empty_route(l, m, x, y, button, out)) spdf_win_annot_route(m, x, y, button, out);
            return;
        }

        /* Anything else -- a divider's dead pixel, the caption reserve's edge --
         * is swallowed rather than passed to the canvas. Swallowed, not
         * forwarded: a drag begun on a panel that panned the document would be
         * a worse bug than a panel that does nothing. */
        default: return;
    }
}

#endif /* SPDF_WIN_CHROME_INPUT_H */
