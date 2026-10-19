#pragma once

/* spdf_win_chrome_view_ui.h -- what a gesture or a key does to the VIEW of the
 * document: the router's layout, zoom in/out/at, page step, the fit cycle, the
 * reading theme, a trough click, and the canvas rebuild they share.
 *
 * Split out of spdf_win_chrome_actions.h when the wiring pass brought that
 * file to its 500-line cap (tools/file-size-limits.md asks for an extracted
 * file rather than a raised one). The seam is the one the three-layer note in
 * that header already draws: this file changes the one document the reader is
 * looking at, while what is left next door decides which handler a point
 * reaches and runs the gestures (chrome_perform, chrome_mouse). Every function
 * here is called from both the mouse router and the keymap
 * (spdf_win_chrome_commands.h), which is why they were never inside either.
 *
 * Header-only and included from spdf_win_chrome_actions.h only, after
 * `struct app`, spdf_win_chrome_scene.h (chrome_scroll_into) and
 * spdf_win_session_app.h (show_selected_tab). Not part of the port's public
 * surface.
 */

#include "spdf_win_panel.h"    /* an open tools panel follows the reading theme */
#include "spdf_win_annot.h"
#include "spdf_win_md_code.h" /* the code pills the router hit-tests */    /* the comment markers the router tests against */
#include "spdf_win_settings.h" /* the reading theme is written to settings.yaml */

/* The model the ROUTER needs, which is not the model the PAINTER needs.
 *
 * The strip's geometry keys on tab_count and selected_tab; the titles cost a
 * UTF-16 conversion per tab and are only needed to draw glyphs. WM_MOUSEMOVE
 * arrives on every pixel of pointer travel, so a move must not pay for strings
 * it will not draw. Everything that affects GEOMETRY is copied faithfully --
 * that is what makes this layout identical to the painter's. */
static void chrome_layout_for_input(app* a, const spdf_win_input* in, SpdfWinChromeModel* model,
                                    SpdfWinChromeLayout* layout) {
    memset(model, 0, sizeof(*model));
    model->dark = (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    /* Presenting collapses the bands and hides both panels, exactly as the
     * painter's model does (spdf_win_chrome_model_build). */
    model->presentation = a->presentation;
    /* The EFFECTIVE visibility and the SECTION, as the painter resolved them
     * (spdf_win_chrome_scene.h chrome_sidebar_decide): a sidebar the paint
     * collapsed because the document has nothing to list must not keep taking
     * clicks, and the Search section's list is not the Chapters section's rows. */
    model->show_sidebar = a->presentation ? 0 : (a->show_sidebar && spdf_win_sidebar_effective_visible());
    model->sidebar_section = spdf_win_sidebar_section();
    /* AND NO MINIMAP WITH NO DOCUMENT, which macOS forces the same way
     * (-setMinimapActuallyVisible:, ShenzhenPDFMac.mm:9137, is
     * `visible && [self hasActiveDocument]`). Before this the empty window drew
     * a bare strip down its right-hand edge with nothing in it, and the Map
     * switch that could not change anything sat next to it looking on. */
    model->show_minimap = a->presentation ? 0 : (a->show_minimap && a->canvas != NULL);
    model->sidebar_w = a->sidebar_w;
    model->minimap_w = a->minimap_w;
    model->hot_tab = a->hot_tab;
    model->hot_close = a->hot_close;
    model->drag_tab = a->drag_tab;
    model->drop_slot = a->drop_slot;
    model->focus = a->focus;
    model->tab_count = a->tabs ? spdf_win_tabs_count(a->tabs) : 0;
    model->selected_tab = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
    /* search_active IS GEOMETRY: it raises the sidebar's minimum width from 176
     * to 216 pt (spdf_win_chrome_clamp_sidebar_pt, macOS :3138-3144), so a
     * router that left it zeroed while a query was live would hit-test a narrow
     * sidebar against the wider one that was drawn. The painter's model gets the
     * same answer from spdf_win_find_fill_model, which sets it from whether the
     * query is non-empty -- which is exactly this test. */
    model->search_active = a->find_text[0] != L'\0';
    /* markdown IS GEOMETRY too, and for the sharper version of the same reason:
     * the A−/A＋ pill takes 64 pt out of the middle of the toolbar, so a router
     * that left this zeroed on a Markdown tab would send every click right of
     * the zoom pill to the wrong control. */
    model->markdown = spdf_win_md_selected_tab_is_markdown(a);
    /* WHETHER THERE IS A DOCUMENT AT ALL, which the router needs for the same
     * reason it needs `markdown`: the painter greys the row's document-dependent
     * controls when there is none (spdf_win_chrome_empty.h), and a router that
     * left this at memset's zero would refuse the WHOLE toolbar on every
     * document this app opens -- or, read the other way, would accept a click on
     * every control the painter had just drawn dead. Same fields, same source as
     * the painter's chrome_inputs_for(); neither is read by
     * spdf_win_chrome_layout(), so no rect moves. */
    model->page_index = a->canvas ? spdf_win_canvas_current_page(a->canvas) : -1;
    model->page_count = a->canvas ? spdf_win_canvas_page_count(a->canvas) : 0;
    /* The sidebar's list, as it was drawn last frame. sidebar_scroll_y is 0
     * because nothing scrolls the list yet; when something does, it must be
     * carried here too or a click will land a row or two out. */
    model->sidebar_row_count = a->sidebar_rows;
    model->sidebar_scroll_y = 0.0f;
    /* The comment markers the last paint published, in client px, so a press
     * on a badge is routed to the badge that was drawn (spdf_win_annot_marks.h). */
    model->annot_marks = spdf_win_annot_marks(&model->annot_mark_count);
    model->md_code_marks = spdf_win_md_code_marks(&model->md_code_mark_count);
    /* The scroller fractions ARE geometry here: h_scrollable decides whether the
     * horizontal trough exists (and so how tall the canvas is), and the two
     * `pos`/`visible` pairs decide where each thumb sits. A router that left them
     * zeroed would hit-test against a full-length thumb at the top of a trough
     * that the painter drew a fifth of the way down. */
    chrome_scroll_into(a, model);
    spdf_win_chrome_layout(model, in->view_px_w, in->view_px_h, in->dpi_scale, layout);
    /* THE CANVAS VIEWPORT, REMEMBERED. Every input event lays the chrome out
     * here before anything acts on it, so by the time a click or a key switches
     * tabs the app knows the rect the next canvas will be laid out against --
     * which is what lets show_selected_tab() put a restored scroll offset back
     * before the first paint rather than losing it (spdf_win_tabs_app_apply_view). */
    if (layout->canvas.w > 0.0f && layout->canvas.h > 0.0f) {
        a->view_w = (unsigned)layout->canvas.w;
        a->view_h = (unsigned)layout->canvas.h;
        a->view_dpi = layout->dpi_scale;
    }
}

/* Zoom about the CANVAS's centre, by the same factors the `+`/`-` keys use.
 *
 * One function for the keys and for the toolbar's zoom pill, because two copies
 * of "1.25" and "0.8" is two chances for a zoom-in that a zoom-out cannot undo.
 * The two are exact reciprocals (1.25 * 0.8 == 1.0), which is why they are the
 * pair rather than 1.25 and 1/1.25. */
static int chrome_zoom_step(app* a, const SpdfWinChromeLayout* l, int zoom_in) {
    if (!a->canvas) return 0;
    spdf_win_canvas_zoom_at(a->canvas, zoom_in ? 1.25f : 0.8f, l->canvas.w * 0.5f, l->canvas.h * 0.5f);
    return 1;
}

/* Ctrl+wheel, anchored under the cursor.
 *
 * THE BUG THIS FUNCTION EXISTS TO NOT HAVE: spdf_win_canvas_zoom_at() takes a
 * VIEWPORT point, and the viewport is the canvas -- but WM_MOUSEWHEEL gives a
 * CLIENT point. The two were the same before the chrome existed, and the window
 * passed the client point straight through. With the sidebar open they are 245 px
 * apart, so the un-translated point would anchor the zoom a sidebar's width to
 * the left of the cursor and the document would visibly slide out from under the
 * pointer -- worse the further from the canvas's left edge you zoom.
 *
 * Clamped into the canvas, so a Ctrl+wheel with the pointer over the toolbar or a
 * side panel still zooms about the nearest point of the page rather than about a
 * negative coordinate. */
static int chrome_zoom_at_client(app* a, const spdf_win_input* in) {
    SpdfWinChromeModel model;
    SpdfWinChromeLayout l;
    float vx, vy;
    if (!a->canvas) return 0;
    chrome_layout_for_input(a, in, &model, &l);
    vx = spdf_win_chrome_input_canvas_x(&l, in->x);
    vy = spdf_win_chrome_input_canvas_y(&l, in->y);
    vx = spdf_win_chrome_max(0.0f, spdf_win_chrome_min(vx, l.canvas.w));
    vy = spdf_win_chrome_max(0.0f, spdf_win_chrome_min(vy, l.canvas.h));
    spdf_win_canvas_zoom_at(a->canvas, in->factor, vx, vy);
    return 1;
}

/* The page pill. macOS's chevrons move the READING POSITION by one page, so this
 * is scroll_to_page and not a scroll by a viewport: at fit-page they coincide, at
 * fit-width on a tall page they do not, and "next page" must mean the next page. */
static int chrome_step_page(app* a, int delta) {
    int page;
    if (!a->canvas) return 0;
    page = spdf_win_canvas_current_page(a->canvas) + delta;
    if (page < 0 || page >= spdf_win_canvas_page_count(a->canvas)) return 0;
    return spdf_win_canvas_scroll_to_page(a->canvas, page);
}

/* The fit popup, WITHOUT a popup.
 *
 * macOS opens an NSPopUpButton with four items; a real Win32 menu is a separate
 * piece of work (TrackPopupMenu, its own message loop, keyboard navigation), and
 * a control that looks live and does nothing is worse than one that cycles. So a
 * click advances through the modes in the popup's own order (:3006-3011), and
 * that is now ALL FOUR of them: the cycle used to skip Fit Height because
 * spdf_win_canvas.h had no such mode, even though the toolbar could draw the
 * label and spdf_win_layout.h had carried spdf_win_fit_height_zoom() all along.
 * A custom zoom re-enters the cycle at Fit Width, which is where macOS's own
 * selectItem lands a custom zoom (:10504-10505). */
static int chrome_cycle_fit(app* a) {
    spdf_win_zoom_mode next;
    if (!a->canvas) return 0;
    switch (spdf_win_canvas_zoom_mode(a->canvas)) {
        case SPDF_WIN_ZOOM_FIT_WIDTH: next = SPDF_WIN_ZOOM_FIT_HEIGHT; break;
        case SPDF_WIN_ZOOM_FIT_HEIGHT: next = SPDF_WIN_ZOOM_FIT_PAGE; break;
        case SPDF_WIN_ZOOM_FIT_PAGE: next = SPDF_WIN_ZOOM_ACTUAL; break;
        default: next = SPDF_WIN_ZOOM_FIT_WIDTH; break;
    }
    spdf_win_canvas_set_zoom_mode(a->canvas, next);
    return 1;
}

/* REBUILD THE CANVAS OVER THE SAME DOCUMENT WITH THE CURRENT RENDER FLAGS. The
 * canvas takes its flags at construction and has no setter, so a theme change
 * is a rebuild -- which is exactly what a tab switch already does, so the path
 * is proven rather than new. The reader's place survives WHOLE: remember()
 * writes the fit mode, the page and the exact offset into the tab's view, and
 * show_selected_tab() puts them back against the viewport the last event laid
 * out (spdf_win_tabs_app_apply_view). It used to keep only the page. */
static int chrome_rebuild_canvas(app* a) {
    if (!a->canvas) return 0;
    spdf_win_tabs_app_remember(a->tabs, a->canvas);
    if (a->window) spdf_win_window_set_dark_frame(a->window, (a->render_flags & SPDF_RENDER_DARK_THEME) != 0);
    /* An OPEN tools panel follows the theme too. It is a separate top-level
     * window with its own brushes, so nothing in this repaint reaches it; the
     * setter is a no-op when no panel exists and when the theme did not change
     * (spdf_win_panel.cpp), which is why it can sit on the plain path. A panel
     * opened later gets the theme from its request. */
    spdf_win_panel_set_dark((a->render_flags & SPDF_RENDER_DARK_THEME) != 0);
    return show_selected_tab(a);
}

/* The reading-theme button. Dark comes with THIS document's Keep Image Colors,
 * which show_selected_tab() composes into the flags on the rebuild below
 * (app_render_flags_for_selected_tab) -- the choice is per document now, not
 * the setting's. The theme itself is WRITTEN to settings.yaml as
 * "markdownTheme" -- the mac's key, kept on purpose -- so the next launch opens
 * in it rather than following the system again.
 *
 * The window frame follows, or `--dark`'s own fix -- a light caption around a
 * #121212 canvas -- comes straight back the first time anyone presses this. */
static int chrome_toggle_theme(app* a) {
    spdf_win_settings* s = spdf_win_settings_shared();
    int dark = !(a->render_flags & SPDF_RENDER_DARK_THEME);
    a->render_flags &= ~(unsigned)SPDF_RENDER_DARK_THEME;
    if (dark) a->render_flags |= SPDF_RENDER_DARK_THEME;
    s->theme = dark ? SPDF_WIN_THEME_DARK : SPDF_WIN_THEME_LIGHT;
    spdf_win_settings_commit();
    /* WITH NO DOCUMENT THIS STILL WORKS, and that is the point rather than a
     * tolerance. It used to `return 0` on a NULL canvas, which made the one
     * toolbar button macOS does NOT disable with no document (it is absent from
     * -updateControls's list, :10218-10248, because a reading theme is a SETTING
     * and not a property of the document) the one button on the empty window
     * that looked live and was not. There is no canvas to rebuild, so the frame,
     * the tools panel and the repaint are all that is owed -- and settings.yaml
     * has the choice either way, so the next launch opens in it. */
    if (!a->canvas) {
        if (a->window) spdf_win_window_set_dark_frame(a->window, dark);
        spdf_win_panel_set_dark(dark);
        return 1;
    }
    return chrome_rebuild_canvas(a);
}

/* A click on the trough, above or below the thumb. A VIEWPORT, less a tenth --
 * the same 0.9 factor Page Down uses in spdf_win_main.cpp's keymap, deliberately
 * shared as a number rather than as a function because the two differ in axis
 * and the overlap is one literal. Sharing the LITERAL is what stops a trough
 * click and Page Down from covering different distances, which is the kind of
 * difference a reader feels without being able to name. */
static int chrome_scroll_page(app* a, const SpdfWinChromeHit* hit, const SpdfWinChromeLayout* l, int forward) {
    float step;
    if (!a->canvas) return 0;
    if (hit->part == SPDF_WIN_CHROME_HSCROLL) {
        step = l->canvas.w * 0.9f;
        return spdf_win_canvas_scroll_by(a->canvas, forward ? step : -step, 0.0f);
    }
    step = l->canvas.h * 0.9f;
    return spdf_win_canvas_scroll_by(a->canvas, 0.0f, forward ? step : -step);
}
