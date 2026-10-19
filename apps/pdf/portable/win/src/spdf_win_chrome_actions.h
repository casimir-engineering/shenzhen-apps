#pragma once

/* For the scroller geometry the router and the painter share, and for
 * spdf_win_chrome_scroll_set_hot() -- the one piece of chrome state that travels
 * from input to painter as a setter rather than in the model. See the long note
 * on it in spdf_win_chrome_paint.h. */
#include "spdf_win_chrome_paint.h"
#include "spdf_win_chrome_scroll.h"
/* The drop indicator and the detach test, for the tab drag below. */
#include "spdf_win_tabs_drag.h"
/* Performing what spdf_win_chrome_input.h decided.
 *
 * Internal to the Windows frontend and header-only, like spdf_win_tabs_app.h and
 * spdf_win_headless_viewport.h beside it, and for the same two reasons those give:
 * it depends on `struct app`, so it must be included from spdf_win_main.cpp after
 * that struct; and spdf_win_main.cpp is at its 500-line cap, where
 * tools/file-size-limits.md asks for an extracted file rather than a raised one.
 *
 * THE THREE-LAYER SPLIT, and why the middle layer exists at all:
 *
 *   spdf_win_window.cpp   translates Win32 messages. Owns the HWND, the capture
 *                         and the cursor. Knows no document and no chrome.
 *   spdf_win_chrome_input.h  decides what a point MEANS. Pure, testable, knows
 *                         no app.
 *   this file             does it. Knows both, and is the only file that does.
 *
 * Its paint-time other half -- chrome_inputs_for(), chrome_scroll_into() and
 * scene_for_window() -- is in spdf_win_chrome_scene.h, which spdf_win_main.cpp
 * includes just before this one. Two of those are called from here; see that
 * file's header for where the seam is and why it falls there.
 *
 * That is the same shape spdf_win_window.h already imposed on the keyboard --
 * "the caller owns the keymap: which key means 'next page' is product policy,
 * not window plumbing" -- extended to the mouse, which is now a device that can
 * land on eight different things.
 *
 * TWO INVARIANTS THIS FILE EXISTS TO HOLD.
 *
 * 1. The chrome is laid out here with the SAME function and the SAME inputs the
 *    painter used, so a click lands on the rect that was drawn. Not a cached
 *    layout from the last paint: a cache is stale for exactly one event after a
 *    resize, and a divider that resizes the wrong panel for one frame is the kind
 *    of bug that gets blamed on the divider.
 *
 * 2. Canvas coordinates are CANVAS-LOCAL. The canvas is laid out against
 *    chrome_layout.canvas.w/h, so every canvas API -- and above all
 *    spdf_win_canvas_zoom_at()'s anchor -- has its origin at the canvas's own
 *    corner. Before the chrome existed that corner was the window's, and the
 *    window passed client coordinates straight through; with the sidebar open
 *    they are 245 px apart, and a Ctrl+wheel zoom fed the un-translated point
 *    anchors on a document point that is not under the cursor. Every conversion
 *    here goes through spdf_win_chrome_input_canvas_x/y() so there is one place
 *    to be wrong.
 */

/* The scroller's hover/press state, pushed to the painter and reported as
 * "changed" so a hover can decide whether it is worth a repaint. Normalised
 * BEFORE the comparison, because spdf_win_chrome_scroll_set_hot() normalises
 * anything that is not a scroller to NONE -- comparing the raw part against the
 * stored one would then report a change on every pointer move over the canvas
 * and repaint the window continuously. */
static int chrome_set_scroll_hot(spdf_win_chrome_part bar, int part, int pressed) {
    int had_bar = 0, had_part = 0, had_pressed = 0;
    if (bar != SPDF_WIN_CHROME_VSCROLL && bar != SPDF_WIN_CHROME_HSCROLL) {
        bar = SPDF_WIN_CHROME_NONE;
        part = SPDF_WIN_SCROLL_NONE;
        pressed = 0;
    }
    pressed = pressed ? 1 : 0;
    spdf_win_chrome_scroll_hot(&had_bar, &had_part, &had_pressed);
    if (had_bar == (int)bar && had_part == part && had_pressed == pressed) return 0;
    spdf_win_chrome_scroll_set_hot((int)bar, part, pressed);
    return 1;
}

/* The view commands -- the router's layout, zoom, page step, fit cycle, theme,
 * trough click -- shared with the keymap, in their own file since this one
 * reached its cap. */
#include "spdf_win_chrome_view_ui.h"
/* The comment flows -- add, edit, delete, hover, the canvas's context menu --
 * in their own file for the same reason; they call chrome_rebuild_canvas. */
#include "spdf_win_chrome_annot_ui.h"

/* Do it. `l` is the layout the hit was computed against, so a handler that needs
 * geometry -- the zoom pill's anchor, a divider's clamp -- uses the same rects
 * the click was tested against. */
static int chrome_perform(app* a, const SpdfWinChromeHit* hit, const SpdfWinChromeLayout* l) {
    switch (hit->action) {
        case SPDF_WIN_CA_FOCUS_FIND: return chrome_focus(a, SPDF_WIN_FOCUS_FIND);
        case SPDF_WIN_CA_FOCUS_PAGE: return chrome_focus(a, SPDF_WIN_FOCUS_PAGE);
        case SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER: return chrome_focus(a, SPDF_WIN_FOCUS_SIDEBAR_FILTER);
        case SPDF_WIN_CA_TOGGLE_REGEX:
            a->find_regex = !a->find_regex;
            chrome_find_push(a);
            return 1;
        case SPDF_WIN_CA_FIND_PREV: return chrome_find_step(a, -1);
        case SPDF_WIN_CA_FIND_NEXT: return chrome_find_step(a, 1);
        case SPDF_WIN_CA_SIDEBAR_ROW: return chrome_sidebar_row(a, hit->index);
        case SPDF_WIN_CA_SIDEBAR_SECTION: return chrome_sidebar_section(a, hit->index);
        /* Click-to-edit on a comment marker's badge (GTK annot_marker_click_pressed). */
        case SPDF_WIN_CA_MD_CODE_COPY:
            /* The fence's source to the clipboard, and the pill says "Copied"
             * for 1.2 s (spdf_win_md_code.h). A failed copy shows nothing,
             * deliberately: there is nothing the reader could do about it. */
            return spdf_win_md_code_copy(hit->index) ? 1 : 0;
        case SPDF_WIN_CA_MD_CODE_LANGUAGE:
            /* The picker's popup window is not written yet -- only its model is
             * (spdf_win_md_code.h: the filter, the catalog order, the per-fence
             * override). Consumed rather than ignored so the click cannot start
             * a text selection under the pill; it does nothing else until the
             * list exists. */
            return 0;
        case SPDF_WIN_CA_ANNOT_EDIT: return annot_edit(a, hit->index);
        /* A press on the minimap arms the strip gesture (spdf_win_search_map_ui.h);
         * the moves and the release below finish it. */
        case SPDF_WIN_CA_MINIMAP: return minimap_press(a, hit, l);
        /* Two toolbar buttons whose handlers belong to the tools track: posted
         * as commands, so they arrive through command_perform like the menu. */
        case SPDF_WIN_CA_OCR: return chrome_post_command(a, SPDF_WIN_CMD_OCR);
        case SPDF_WIN_CA_TRANSLATE_SELECTION: return chrome_post_command(a, SPDF_WIN_CMD_TRANSLATE_SELECTION);
        /* The Markdown text-size pill, posted for the same reason: the handler
         * lives past this header's include point (spdf_win_md_commands.h), and
         * going through the command switch is what makes the pill and the two
         * View menu rows literally the same code. */
        case SPDF_WIN_CA_MD_TEXT_SMALLER: return chrome_post_command(a, SPDF_WIN_CMD_MD_TEXT_SMALLER);
        case SPDF_WIN_CA_MD_TEXT_LARGER: return chrome_post_command(a, SPDF_WIN_CMD_MD_TEXT_LARGER);
        case SPDF_WIN_CA_SCROLL_PAGE_BACK: return chrome_scroll_page(a, hit, l, 0);
        case SPDF_WIN_CA_SCROLL_PAGE_FORWARD: return chrome_scroll_page(a, hit, l, 1);
        case SPDF_WIN_CA_SELECT_TAB: return chrome_select_tab(a, hit->index);
        case SPDF_WIN_CA_CLOSE_TAB: return chrome_close_tab(a, hit->index);
        case SPDF_WIN_CA_PREV_PAGE: return chrome_step_page(a, -1);
        case SPDF_WIN_CA_NEXT_PAGE: return chrome_step_page(a, 1);
        case SPDF_WIN_CA_ZOOM_IN: return chrome_zoom_step(a, l, 1);
        case SPDF_WIN_CA_ZOOM_OUT: return chrome_zoom_step(a, l, 0);
        case SPDF_WIN_CA_CYCLE_FIT: return chrome_cycle_fit(a);
        case SPDF_WIN_CA_TOGGLE_THEME: return chrome_toggle_theme(a);
        case SPDF_WIN_CA_TOGGLE_SIDEBAR: a->show_sidebar = !a->show_sidebar; return 1;
        case SPDF_WIN_CA_TOGGLE_MINIMAP: a->show_minimap = !a->show_minimap; return 1;
        /* A divider or thumb press changes nothing by itself; the width or the
         * scroll position follows the pointer on the moves that come after, so
         * this only arms the drag. (The thumb's PRESSED look is a repaint, and
         * chrome_mouse() below asks for that separately.) */
        case SPDF_WIN_CA_DRAG_SIDEBAR:
        case SPDF_WIN_CA_DRAG_MINIMAP:
        case SPDF_WIN_CA_DRAG_VSCROLL:
        case SPDF_WIN_CA_DRAG_HSCROLL: return 0;
        /* The strip's `+` and `...`, both live: the first POSTS File > Open, so
         * the picker it gets is the documents track's (start folder, recents)
         * through command_perform like Ctrl+O -- one dialog however it is
         * reached; the second drops a real Win32 popup listing every tab.
         * Neither falls through to the canvas, which is what has kept a press on
         * either from panning the document all along. */
        case SPDF_WIN_CA_NEW_TAB: return chrome_post_command(a, SPDF_WIN_CMD_OPEN);
        /* The empty canvas's "Open a PDF…" button, and the SAME command as the
         * `+` above it and as Ctrl+O -- which is the point. An empty window's
         * only affordance must reach the documents track's real picker, with its
         * start folder and its recents, and not a second dialog that drifts from
         * it (spdf_win_chrome_empty.h). */
        case SPDF_WIN_CA_OPEN_DOC: return chrome_post_command(a, SPDF_WIN_CMD_OPEN);
        case SPDF_WIN_CA_TAB_OVERFLOW: return chrome_tab_overflow(a, l);
        case SPDF_WIN_CA_APP_MENU: return chrome_app_menu(a, l);
        default: return 0;
    }
}

/* One mouse event, routed. Returns non-zero when the view changed.
 *
 * THE ORDER HERE IS THE POINT: everything is decided by
 * spdf_win_chrome_input_route() first, and the document's own pan is reached
 * only through SPDF_WIN_CA_CANVAS. That is what makes a press on the toolbar not
 * pan the page -- the failure this whole change was most likely to introduce. */
static int chrome_mouse(app* a, spdf_win_input* in) {
    SpdfWinChromeModel model;
    SpdfWinChromeLayout l;
    SpdfWinChromeHit hit;

    chrome_layout_for_input(a, in, &model, &l);
    /* No chrome while presenting: the pointer turns pages and nothing else. */
    if (a->presentation) return presentation_mouse(a, in);
    spdf_win_chrome_input_route(&l, &model, in->x, in->y, in->button, &hit);
    /* The right button outside presentation: the canvas's context menu
     * (spdf_win_chrome_annot_ui.h); nothing anywhere else. */
    if (in->kind == SPDF_WIN_INPUT_CONTEXT) return annot_context_menu(a, in, &hit);

    if (in->kind == SPDF_WIN_INPUT_CURSOR) {
        /* The window manager's half of the position query first: it depends on
         * the geometry alone, never on a drag, and WM_NCHITTEST reads it with
         * no button down. See spdf_win_chrome_nc. */
        in->nc = hit.nc;
        /* While a drag is running the cursor belongs to the DRAG, not to
         * wherever the pointer has got to: a divider drag that outran its
         * divider must keep the resize cursor, and a pan must keep IDC_SIZEALL
         * even as the page moves out from under the pointer. */
        if (a->drag == SPDF_WIN_CA_CANVAS) in->cursor = SPDF_WIN_CC_SIZEALL;
        /* A selection in progress keeps the I-beam, whatever it has been dragged
         * over -- including off the page entirely, which is how a reader selects
         * to the end of a paragraph. */
        else if (a->drag == SPDF_WIN_CA_CANVAS_SELECT) in->cursor = SPDF_WIN_CC_IBEAM;
        /* A thumb drag keeps the ARROW, which is what Windows and AppKit both
         * show over a scrollbar. Listed explicitly rather than left to the
         * `!= NONE` branch below, which would give it the divider's resize
         * cursor and make the trough look like a panel edge. */
        else if (a->drag == SPDF_WIN_CA_DRAG_VSCROLL || a->drag == SPDF_WIN_CA_DRAG_HSCROLL ||
                 a->drag == SPDF_WIN_CA_DRAG_TAB || a->drag == SPDF_WIN_CA_MINIMAP_DRAG)
            in->cursor = SPDF_WIN_CC_ARROW;
        else if (a->drag != SPDF_WIN_CA_NONE) in->cursor = SPDF_WIN_CC_SIZEWE;
        else in->cursor = hit.cursor;
        /* Over the PAGE, the document has the last word: see
         * canvas_cursor_override(). */
        if (a->drag == SPDF_WIN_CA_NONE && hit.action == SPDF_WIN_CA_CANVAS) canvas_cursor_override(a, in, &l);
        return 0; /* a cursor query must never cost a repaint */
    }

    if (in->kind == SPDF_WIN_INPUT_MOUSE_UP) {
        int moved = a->drag == SPDF_WIN_CA_DRAG_TAB ? chrome_drop_tab(a, &l, &model) : 0;
        /* A selection gesture ends HERE, and this is also where a link is
         * followed -- on the release, not the press, so a drag that began on a
         * link selects its text instead of navigating (spdf_win_canvas.h's own
         * behaviour, which only works if press/drag/release are all routed). A
         * button of NONE is a CANCELLED drag, not a release. */
        if (a->drag == SPDF_WIN_CA_CANVAS_SELECT) moved |= canvas_release(a, in->button == SPDF_WIN_CB_NONE);
        if (a->drag == SPDF_WIN_CA_MINIMAP_DRAG) moved |= minimap_release(a, in, &l);
        a->drag = SPDF_WIN_CA_NONE;
        a->drag_tab = -1;
        a->drop_slot = -1;
        /* The thumb stops looking held. Repaint only if it WAS -- a release over
         * the canvas must not cost a frame. */
        return moved | chrome_set_scroll_hot(hit.part, hit.scroll_part, 0);
    }

    if (in->kind == SPDF_WIN_INPUT_MOUSE_DOWN) {
        int scroll_drag = hit.action == SPDF_WIN_CA_DRAG_VSCROLL || hit.action == SPDF_WIN_CA_DRAG_HSCROLL;
        int selecting = 0;
        a->drag = hit.action == SPDF_WIN_CA_CANVAS || hit.action == SPDF_WIN_CA_DRAG_SIDEBAR ||
                          hit.action == SPDF_WIN_CA_DRAG_MINIMAP || scroll_drag
                      ? hit.action
                      : SPDF_WIN_CA_NONE;
        /* A press on the PAGE becomes one of two gestures, chosen from what is
         * under the pointer. canvas_press() sets a->drag to whichever it is; it
         * is the only thing allowed to overwrite the CANVAS value just assigned.
         * A press anywhere else -- including a press that gave a field the
         * keyboard -- takes the focus away from the toolbar, because that is what
         * clicking outside a text field means everywhere else on this desktop. */
        if (hit.action == SPDF_WIN_CA_CANVAS) selecting = canvas_press(a, in, &l);
        /* Where on the page, for a note added later without a selection. */
        if (hit.action == SPDF_WIN_CA_CANVAS || hit.action == SPDF_WIN_CA_ANNOT_EDIT) annot_note_canvas_press(in, &hit);
        if (hit.action != SPDF_WIN_CA_FOCUS_FIND && hit.action != SPDF_WIN_CA_FOCUS_PAGE &&
            hit.action != SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER && a->focus != SPDF_WIN_FOCUS_NONE) {
            a->focus = SPDF_WIN_FOCUS_NONE;
            selecting = 1;
        }
        /* For every other gesture drag_last_* is the PREVIOUS pointer position,
         * advanced on each move because a pan consumes deltas. A thumb drag needs
         * the ORIGIN instead: its position is pos_at_press + total travel /
         * thumb travel, computed fresh from the press each time, so that a drag
         * out past the end of the track and back returns to where it started
         * instead of accumulating rounding. So these two are left alone by the
         * scroll cases below, and drag_scroll_pos captures the fraction the thumb
         * had at the moment of the press. */
        a->drag_last_x = in->x;
        a->drag_last_y = in->y;
        if (scroll_drag)
            a->drag_scroll_pos = hit.action == SPDF_WIN_CA_DRAG_HSCROLL ? model.h_pos : model.v_pos;
        /* A press on a TAB both selects it (below, immediately, as macOS does)
         * and arms a reorder. Two things from one press, which is why the drag
         * state is set after the ternary rather than inside it: the router
         * cannot report SELECT_TAB and DRAG_TAB at once, and a press that only
         * armed the drag would leave the strip unresponsive to a plain click. */
        if (hit.action == SPDF_WIN_CA_SELECT_TAB) {
            a->drag = SPDF_WIN_CA_DRAG_TAB;
            a->drag_tab = hit.index;
            a->drop_slot = -1;
            a->drag_start_y = (in->y - l.tabstrip.y) / (l.dpi_scale > 0.0f ? l.dpi_scale : 1.0f);
        }
        return selecting | chrome_perform(a, &hit, &l) | chrome_set_scroll_hot(hit.part, hit.scroll_part, scroll_drag);
    }

    /* --- MOUSE_MOVE ----------------------------------------------------- */
    switch (a->drag) {
        /* Extending a selection. NOT a pan: it never reaches
         * spdf_win_canvas_scroll_by, so the page stays put under the growing
         * highlight. */
        case SPDF_WIN_CA_CANVAS_SELECT: return canvas_drag(a, in, &l);
        case SPDF_WIN_CA_MINIMAP_DRAG: return minimap_drag(a, in, &l);
        case SPDF_WIN_CA_DRAG_TAB: {
            /* THE TEAR-OFF. Once the pointer has left the strip by the mac's
             * margins (spdf_win_tabstrip_drag_detaches, :1012-1014) the drag
             * stops being a reorder: the tab goes to a new window and the
             * gesture stops being a reorder -- but it is still a drag:
             * chrome_detach_tab() (spdf_win_tabs_handoff.h) takes the capture
             * back and runs it to its end, whether that is slid back into this
             * bar, dropped on another window's bar, released outside every bar
             * into its own window, or cancelled.
             *
             * NO TAB-COUNT GUARD: a lone tab cannot become its own window (it
             * already is one) but it CAN be dropped on another window's bar,
             * and only chrome_detach_tab() can tell those two apart. */
            float s = l.dpi_scale > 0.0f ? l.dpi_scale : 1.0f;
            int slot;
            if (!spdf_win_chrome_rect_empty(l.tabstrip) &&
                spdf_win_tabstrip_drag_detaches(l.tabstrip.w / s, l.tabstrip.h / s, (in->x - l.tabstrip.x) / s,
                                                (in->y - l.tabstrip.y) / s, a->drag_start_y)) {
                int tab = a->drag_tab;
                a->drag = SPDF_WIN_CA_NONE;
                a->drag_tab = -1;
                a->drop_slot = -1;
                chrome_release_capture(a);
                return chrome_detach_tab(a, tab) | 1;
            }
            /* Only the SLOT is tracked while the pointer moves; the tab model is
             * not touched until the button comes up. Reordering live would make
             * every intermediate position a real move, and the reader would have
             * to land the tab exactly rather than merely release it in the right
             * gap. */
            slot = chrome_drop_slot_at(&l, &model, in->x);
            if (slot == a->drop_slot) return 0;
            a->drop_slot = slot;
            return 1;
        }
        case SPDF_WIN_CA_CANVAS: {
            /* Dragging the paper down scrolls the document up, so the scroll
             * delta is the negated cursor delta -- grab-and-pull, not
             * push-the-scrollbar. A DELTA, so it needs no origin translation;
             * only absolute points do. */
            float dx = a->drag_last_x - in->x;
            float dy = a->drag_last_y - in->y;
            a->drag_last_x = in->x;
            a->drag_last_y = in->y;
            return a->canvas ? spdf_win_canvas_scroll_by(a->canvas, dx, dy) : 0;
        }
        case SPDF_WIN_CA_DRAG_SIDEBAR:
            /* The clamp is macOS's own, transcribed in spdf_win_chrome.h, so a
             * width dragged here lands exactly where NSSplitView would put it. */
            a->sidebar_w = spdf_win_chrome_sidebar_drag_pt(&l, in->x, model.search_active);
            return 1;
        case SPDF_WIN_CA_DRAG_MINIMAP:
            a->minimap_w = spdf_win_chrome_minimap_drag_pt(&l, in->x);
            return 1;
        /* A THUMB DRAG, and note what it is NOT: it never reaches
         * spdf_win_canvas_scroll_by(), so it cannot be confused with a pan, and
         * the pointer may wander off the trough entirely (the capture keeps the
         * gesture alive) without the document following it sideways. The
         * position is recomputed from the press each time, so the thumb tracks
         * the cursor exactly and returns to its start if the cursor does. */
        case SPDF_WIN_CA_DRAG_VSCROLL:
        case SPDF_WIN_CA_DRAG_HSCROLL: {
            spdf_win_chrome_part part =
                a->drag == SPDF_WIN_CA_DRAG_HSCROLL ? SPDF_WIN_CHROME_HSCROLL : SPDF_WIN_CHROME_VSCROLL;
            SpdfWinScrollBar bar;
            float delta, pos;
            spdf_win_chrome_scroll_bar(&l, &model, part, &bar);
            delta = bar.axis == SPDF_WIN_SCROLL_H ? in->x - a->drag_last_x : in->y - a->drag_last_y;
            pos = spdf_win_scroll_drag_pos(bar.track, a->drag_scroll_pos, bar.visible,
                                           spdf_win_scroll_thumb_min(l.dpi_scale), delta, bar.axis);
            chrome_set_scroll_hot(part, SPDF_WIN_SCROLL_THUMB, 1);
            return a->canvas ? spdf_win_canvas_scroll_to_fraction(a->canvas, bar.axis == SPDF_WIN_SCROLL_V, pos) : 0;
        }
        default: break;
    }

    /* No drag: this is hover. Only a CHANGE repaints, or the pointer would
     * invalidate the window on every pixel it crosses. The scroller's hover is
     * evaluated first and unconditionally, because it is a change the tab
     * comparison below knows nothing about -- an early `return 0` there would
     * leave a thumb lit after the pointer had left it. */
    {
        int changed = chrome_set_scroll_hot(hit.part, hit.scroll_part, 0);
        /* The comment under the pointer: a tooltip, never a repaint. */
        annot_hover(a, &hit, in);
        if (hit.hot_tab == a->hot_tab && hit.hot_close == a->hot_close) return changed;
        if (hit.hot_tab != a->hot_tab) chrome_hover_tooltip(a, &l, hit.hot_tab);
        a->hot_tab = hit.hot_tab;
        a->hot_close = hit.hot_close;
        return 1;
    }
}
