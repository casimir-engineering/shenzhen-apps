#pragma once

/* spdf_win_window_presentation.h -- presentation mode and full screen, the
 * app's half.
 *
 * Header-only and included from spdf_win_main.cpp after `struct app` and
 * spdf_win_chrome_scene.h, before spdf_win_chrome_actions.h (whose
 * chrome_mouse() routes to presentation_mouse() while presenting) and
 * spdf_win_cmd_window.h (whose F5 and F11 handlers call app_set_presentation()
 * and app_toggle_fullscreen()). Same arrangement as spdf_win_tabs_app.h beside
 * it; not part of the port's public surface.
 *
 * WHAT PRESENTATION IS, from -enterPresentationMode: (ShenzhenPDFMac.mm:13432)
 * and GTK's spdf_window_set_presentation (spdf_window.c:342): the window goes
 * full screen, every piece of chrome disappears (the strip and toolbar collapse
 * to nothing -- SpdfWinChromeModel::presentation, spdf_win_chrome.h:296 -- and
 * both panels hide), the document fits the page, the pointer turns pages, and
 * the display is kept awake when preventSleepInPresentation says so. Leaving
 * it puts back the fit mode and the two panels the reader had
 * (_presentationPreviousFitMode, _presentationPrevious*PreferredVisible).
 *
 * FULL SCREEN (F11) is the window half alone: the same borderless window with
 * the chrome kept. Both share spdf_win_window_set_fullscreen(), and an Escape
 * nothing else wanted leaves whichever the window is in
 * (spdf_win_window.h, the one key policy the window holds).
 */

/* The canvas's page step, restated here rather than reached through
 * chrome_step_page() in spdf_win_chrome_actions.h, which is included after
 * this file. Same clamp, same call. */
static int presentation_step_page(app* a, int delta) {
    int page;
    if (!a->canvas) return 0;
    page = spdf_win_canvas_current_page(a->canvas) + delta;
    if (page < 0 || page >= spdf_win_canvas_page_count(a->canvas)) return 0;
    return spdf_win_canvas_scroll_to_page(a->canvas, page);
}

/* The pointer in presentation mode, transcribed from
 * SPDFMacPresentationIntegration.mm:5-30: a left press advances, Ctrl+left
 * goes back, the right button goes back, the middle button advances. Nothing
 * else in the window is reachable -- there is no chrome -- so this replaces the
 * whole router while presenting, and the position query answers "arrow, the
 * app's" so no pixel is title bar. The right button arrives as
 * SPDF_WIN_INPUT_CONTEXT (spdf_win_window.h). */
static int presentation_mouse(app* a, spdf_win_input* in) {
    switch (in->kind) {
        case SPDF_WIN_INPUT_CURSOR:
            in->cursor = SPDF_WIN_CC_ARROW;
            in->nc = SPDF_WIN_NC_CLIENT;
            return 0;
        case SPDF_WIN_INPUT_MOUSE_DOWN:
            if (in->button == SPDF_WIN_CB_LEFT)
                return presentation_step_page(a, (in->mods & SPDF_WIN_MOD_CTRL) ? -1 : 1);
            if (in->button == SPDF_WIN_CB_MIDDLE) return presentation_step_page(a, 1);
            return 0;
        case SPDF_WIN_INPUT_CONTEXT: return presentation_step_page(a, -1);
        default: return 0;
    }
}

/* Enter or leave presentation. Returns 1 when the state changed. */
static int app_set_presentation(app* a, int on) {
    on = on ? 1 : 0;
    if (on == a->presentation) return 0;
    a->presentation = on;
    /* The process-wide mirror the paint-time model builder reads
     * (spdf_win_chrome_model_inputs_init); the input-time layout reads the
     * field on `a` directly. */
    spdf_win_chrome_presentation_set(on);
    a->focus = SPDF_WIN_FOCUS_NONE;
    if (on) {
        a->saved_show_sidebar = a->show_sidebar;
        a->saved_show_minimap = a->show_minimap;
        a->saved_zoom_mode = spdf_win_canvas_zoom_mode(a->canvas);
        a->saved_zoom = spdf_win_canvas_zoom(a->canvas);
        a->show_sidebar = 0;
        a->show_minimap = 0;
        if (a->canvas) spdf_win_canvas_set_zoom_mode(a->canvas, SPDF_WIN_ZOOM_FIT_PAGE);
        if (a->window && !a->fullscreen) spdf_win_window_set_fullscreen(a->window, 1);
        a->fullscreen = 1;
        if (spdf_win_settings_shared()->prevent_sleep_in_presentation) spdf_win_window_prevent_sleep(1);
    } else {
        spdf_win_window_prevent_sleep(0);
        a->show_sidebar = a->saved_show_sidebar;
        a->show_minimap = a->saved_show_minimap;
        if (a->canvas) {
            if (a->saved_zoom_mode == SPDF_WIN_ZOOM_FREE) spdf_win_canvas_set_zoom_at(a->canvas, a->saved_zoom, 0.0f, 0.0f);
            else spdf_win_canvas_set_zoom_mode(a->canvas, a->saved_zoom_mode);
        }
        if (a->window) spdf_win_window_set_fullscreen(a->window, 0);
        a->fullscreen = 0;
    }
    return 1;
}

/* F11, and the window's own "leave full screen" for an unwanted Escape: out of
 * presentation if that is what the window is in, else the plain toggle. */
static int app_toggle_fullscreen(app* a) {
    if (a->presentation) return app_set_presentation(a, 0);
    a->fullscreen = !a->fullscreen;
    if (a->window) spdf_win_window_set_fullscreen(a->window, a->fullscreen);
    return 1;
}
