#pragma once

/* The caption, owned by the client area -- for spdf_win_window.cpp only.
 *
 * NOT A NEW LAYER, and the same arrangement as spdf_win_window_frame.h and
 * spdf_win_window_input.h beside it: header-only, included from exactly one
 * translation unit, AFTER `struct spdf_win_window` because it dereferences it,
 * and not part of the port's public surface. It is a separate file because the
 * window proc was at its 500-line cap and tools/file-size-limits.md asks for an
 * extracted file rather than a raised one -- and because this IS a subsystem:
 * WM_NCCALCSIZE, WM_NCHITTEST, the caption buttons' hover and press, the
 * maximized inset and the DWM frame extension all have to agree with each other
 * for the strip to behave as a title bar.
 *
 * WHAT THIS DOES, AND WHY. The reported defect was "a double top bar like it's
 * a window inside of a window": the OS caption sat ABOVE the 42 pt tab strip, so
 * the window had two header bands. macOS has one because its strip lives INSIDE
 * the title bar (SPDFWindow: titleVisibility Hidden, titlebarAppearsTransparent,
 * NSWindowStyleMaskFullSizeContentView). This file is the Win32 equivalent:
 *
 *   WM_NCCALCSIZE   removes the caption from the non-client area and keeps the
 *                   resize borders, so the client area starts at the frame's top
 *                   edge and the strip is the topmost thing on the window.
 *   WM_NCHITTEST    answers HTCAPTION for empty strip, HTCLIENT for a tab or a
 *                   control, HTMINBUTTON / HTMAXBUTTON / HTCLOSE for the three
 *                   buttons the chrome draws, and HTTOP for the resize band the
 *                   caption used to provide -- macOS's SPDFMacWindowChrome click
 *                   policy exactly (handoff §3.6): a click on empty title-bar
 *                   area drags, a double-click zooms, a click on a control never
 *                   does either. Returning the REAL HTMAXBUTTON is what makes
 *                   Windows 11's Snap Layouts flyout appear over our button.
 *   WM_NCMOUSE*     drive SpdfWinChromeModel::caption_hot / caption_pressed
 *                   through spdf_win_chrome_caption_set_state(), and perform
 *                   minimize / maximize / close on the release. Never passed to
 *                   DefWindowProc for our buttons, which would otherwise paint
 *                   the classic button over the strip.
 *
 * WHO DECIDES WHAT A POINT IS. Not this file. It knows no tabs and no chrome
 * geometry; it sends the same SPDF_WIN_INPUT_CURSOR position query WM_SETCURSOR
 * sends, and reads `nc` from the answer -- which spdf_win_chrome_input.h computed
 * from the same rects the painter drew. That is the whole reason the geometry
 * lives in pure headers: the pixel that closes the window is the pixel drawn
 * red, and the pixels that drag the window are exactly the ones that look empty.
 *
 * THE MAXIMIZED INSET. A maximized window is positioned so that its resize
 * borders lie OFF the monitor, on all four sides. DefWindowProc's NCCALCSIZE
 * normally hides that because the caption is taller than the border; once the
 * caption is gone, the client's top row would be the off-screen one and the top
 * of the strip would be clipped. So when maximized the client's top is moved
 * down by exactly the border, and the top resize band is not offered at all.
 * (Windows Terminal's NonClientIslandWindow does the same; it is the standard
 * answer.)
 */

#include <dwmapi.h> /* MARGINS; the function itself is resolved dynamically */

/* GetSystemMetricsForDpi arrived in Windows 10 1607, so it is resolved at run
 * time like GetDpiForWindow above; on anything older the 96-dpi metric is
 * scaled, which is what Windows itself does for a system-DPI-aware process. */
typedef int(WINAPI* get_system_metrics_for_dpi_fn)(int, UINT);

static int metric_for_dpi(int index, UINT dpi) {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    get_system_metrics_for_dpi_fn fn =
        user32 ? (get_system_metrics_for_dpi_fn)GetProcAddress(user32, "GetSystemMetricsForDpi") : NULL;
    if (fn) return fn(index, dpi);
    return MulDiv(GetSystemMetrics(index), (int)(dpi ? dpi : USER_DEFAULT_SCREEN_DPI), USER_DEFAULT_SCREEN_DPI);
}

/* The resize border on each side: the visible frame plus the padded border
 * Windows adds to every resizable window since Vista (SM_CXPADDEDBORDER). This
 * is the part of the frame WM_NCCALCSIZE keeps. */
static int border_x_px(const spdf_win_window* window) {
    return metric_for_dpi(SM_CXFRAME, window->dpi) + metric_for_dpi(SM_CXPADDEDBORDER, window->dpi);
}

static int border_y_px(const spdf_win_window* window) {
    return metric_for_dpi(SM_CYFRAME, window->dpi) + metric_for_dpi(SM_CXPADDEDBORDER, window->dpi);
}

/* What the frame adds to a CLIENT size once the caption is the client's: the two
 * side borders and the bottom one. Nothing on top. This replaces
 * AdjustWindowRectEx, which would still add the caption it no longer has. */
static void frame_extents(const spdf_win_window* window, int* extra_w, int* extra_h) {
    *extra_w = 2 * border_x_px(window);
    *extra_h = border_y_px(window);
}

/* WM_GETMINMAXINFO: THE FLOOR THE USER CANNOT DRAG THROUGH. macOS sets
 * contentMinSize to 560 x 380 (ShenzhenPDFMac.mm:69-70) and Windows had nothing
 * at all, so the frame could be dragged down to a caption bar with a sliver of
 * chrome under it -- and spdf_win_chrome_layout() then starts dropping bands,
 * which is a graceful degradation meant for a squeezed panel rather than a
 * normal way to use the app.
 *
 * The constants are CLIENT-area points, so they are scaled by this window's DPI
 * and then grown into a FRAME size by frame_extents(): ptMinTrackSize is the
 * outer window, and clamping the outer window to a client-area number would
 * leave the client short by the borders on every machine. The 380 pt floor
 * INCLUDES the strip, exactly as macOS's contentMinSize does. */
static void min_track_size(const spdf_win_window* window, MINMAXINFO* mmi) {
    float s = spdf_win_window_dpi_scale(window);
    int extra_w = 0, extra_h = 0;
    frame_extents(window, &extra_w, &extra_h);
    mmi->ptMinTrackSize.x = (LONG)(SPDF_WIN_CHROME_MIN_CONTENT_W * s) + extra_w;
    mmi->ptMinTrackSize.y = (LONG)(SPDF_WIN_CHROME_MIN_CONTENT_H * s) + extra_h;
}

/* The band along the top of the client that resizes rather than drags. The
 * caption used to carry it; now the top SM_CYFRAME of the strip does. The
 * padded border is deliberately NOT included: the tab bodies start 7 pt down,
 * and 8 px at 150% would overlap them, where 6 px does not. */
static int top_resize_band_px(const spdf_win_window* window) {
    return metric_for_dpi(SM_CYFRAME, window->dpi);
}

/* DwmExtendFrameIntoClientArea, dynamically, for the reason
 * spdf_win_window_set_dark_frame() gives: one binary that starts everywhere.
 * The margin is the full caption height when windowed and nothing when
 * maximized -- Windows Terminal's arrangement, and the one that keeps DWM
 * drawing the shadow, the rounded corners and the 1 px frame around a window
 * whose caption it no longer owns. */
typedef HRESULT(WINAPI* dwm_extend_frame_fn)(HWND, const MARGINS*);

static void extend_frame_into_strip(spdf_win_window* window) {
    HMODULE dwmapi;
    dwm_extend_frame_fn extend;
    MARGINS m = {0, 0, 0, 0};
    if (!window->hwnd) return;
    dwmapi = LoadLibraryW(L"dwmapi.dll");
    if (!dwmapi) return;
    extend = (dwm_extend_frame_fn)GetProcAddress(dwmapi, "DwmExtendFrameIntoClientArea");
    if (extend) {
        /* Nothing when maximized or full screen: there is no frame to extend
         * into, and a non-zero margin over a borderless popup draws a DWM strip
         * along its top edge. */
        if (!window->maximized && !window->fullscreen)
            m.cyTopHeight = border_y_px(window) + metric_for_dpi(SM_CYCAPTION, window->dpi);
        extend(window->hwnd, &m);
    }
    FreeLibrary(dwmapi);
}

/* Push the three caption facts to the model the painter reads, and repaint only
 * when something changed -- a hover that changes nothing must not cost a frame. */
static void caption_publish(spdf_win_window* window) {
    int had_max = 0, had_hot = 0, had_pressed = 0;
    spdf_win_chrome_caption_state(&had_max, &had_hot, &had_pressed);
    if (had_max == window->maximized && had_hot == window->caption_hot && had_pressed == window->caption_pressed)
        return;
    spdf_win_chrome_caption_set_state(window->maximized, window->caption_hot, window->caption_pressed);
    InvalidateRect(window->hwnd, NULL, FALSE);
}

static void caption_set(spdf_win_window* window, int hot, int pressed) {
    window->caption_hot = hot;
    window->caption_pressed = pressed;
    caption_publish(window);
}

/* WM_SIZE and WM_NCCALCSIZE both call this: NCCALCSIZE arrives BEFORE the WM_SIZE
 * that announces a maximize, and it needs the new state for the inset. */
static void sync_maximized(spdf_win_window* window) {
    int now = IsZoomed(window->hwnd) ? 1 : 0;
    if (now == window->maximized) return;
    window->maximized = now;
    extend_frame_into_strip(window);
    caption_publish(window);
}

/* --- WM_NCCALCSIZE -------------------------------------------------------- */

static LRESULT nc_calc_size(spdf_win_window* window, WPARAM wparam, LPARAM lparam) {
    /* Both forms put the window rect first: a bare RECT when wparam is FALSE,
     * NCCALCSIZE_PARAMS whose rgrc[0] is that rect when TRUE. */
    RECT* rc = (RECT*)lparam;
    LONG top = rc->top;
    LRESULT r = DefWindowProcW(window->hwnd, WM_NCCALCSIZE, wparam, lparam);
    /* DefWindowProc has now inset all four sides by the frame and the top by the
     * caption as well. Keep its left, right and bottom -- those are the resize
     * borders -- and give the top back. */
    if (wparam && r != 0) return r;
    rc->top = top;
    sync_maximized(window);
    if (window->maximized) rc->top += border_y_px(window);
    return 0;
}

/* --- WM_NCHITTEST --------------------------------------------------------- */

static LRESULT nc_hit_test(spdf_win_window* window, WPARAM wparam, LPARAM lparam) {
    POINT pt;
    RECT rc;
    spdf_win_input query;
    /* The borders first: DefWindowProc still owns left, right and bottom, and
     * anything it does not call client is its answer. */
    LRESULT def = DefWindowProcW(window->hwnd, WM_NCHITTEST, wparam, lparam);
    if (def != HTCLIENT) return def;

    pt.x = GET_X_LPARAM(lparam);
    pt.y = GET_Y_LPARAM(lparam);
    if (!ScreenToClient(window->hwnd, &pt) || !GetClientRect(window->hwnd, &rc)) return HTCLIENT;

    /* The top resize band, with its two corners. Not when maximized or full
     * screen: there is nothing to resize to, and the band would eat the top of
     * the strip. */
    if (!window->maximized && !window->fullscreen && pt.y < top_resize_band_px(window)) {
        int bx = border_x_px(window);
        if (pt.x < bx) return HTTOPLEFT;
        if (pt.x >= rc.right - bx) return HTTOPRIGHT;
        return HTTOP;
    }

    /* Everything else is the app's to name. The same position query
     * WM_SETCURSOR sends; a handler that does not answer leaves CLIENT. */
    if (!window->input_fn) return HTCLIENT;
    memset(&query, 0, sizeof(query));
    query.kind = SPDF_WIN_INPUT_CURSOR;
    query.button = window->pressed;
    query.cursor = SPDF_WIN_CC_ARROW;
    query.nc = SPDF_WIN_NC_CLIENT;
    query.x = (float)pt.x;
    query.y = (float)pt.y;
    dispatch(window, &query);
    switch (query.nc) {
        case SPDF_WIN_NC_CAPTION: return HTCAPTION;
        case SPDF_WIN_NC_MINIMIZE: return HTMINBUTTON;
        case SPDF_WIN_NC_MAXIMIZE: return HTMAXBUTTON;
        case SPDF_WIN_NC_CLOSE: return HTCLOSE;
        default: return HTCLIENT;
    }
}

/* --- the caption buttons' mouse ------------------------------------------- */

/* The HT code in a WM_NC* message's wparam, as a caption button, or NONE. */
static int caption_button_for(WPARAM hit) {
    switch (hit) {
        case HTMINBUTTON: return SPDF_WIN_CAPTION_MINIMIZE;
        case HTMAXBUTTON: return SPDF_WIN_CAPTION_MAXIMIZE;
        case HTCLOSE: return SPDF_WIN_CAPTION_CLOSE;
        default: return SPDF_WIN_CAPTION_NONE;
    }
}

/* WM_NCMOUSEMOVE. Hover lights the button; asking for WM_NCMOUSELEAVE is what
 * puts it out again when the pointer leaves the window or enters the client. */
static void nc_mouse_move(spdf_win_window* window, WPARAM hit) {
    TRACKMOUSEEVENT tme;
    tme.cbSize = sizeof(tme);
    tme.dwFlags = TME_LEAVE | TME_NONCLIENT;
    tme.hwndTrack = window->hwnd;
    tme.dwHoverTime = 0;
    TrackMouseEvent(&tme);
    caption_set(window, caption_button_for(hit), window->caption_pressed);
}

/* WM_NCLBUTTONDOWN / WM_NCLBUTTONDBLCLK. Ours if it is on one of our buttons:
 * returns non-zero and the caller must NOT call DefWindowProc, which would draw
 * the classic button. A press on HTCAPTION is not ours -- DefWindowProc turns it
 * into the move loop, and a double-click into SC_MAXIMIZE / SC_RESTORE. */
static int nc_lbutton_down(spdf_win_window* window, WPARAM hit) {
    int b = caption_button_for(hit);
    if (b == SPDF_WIN_CAPTION_NONE) return 0;
    caption_set(window, b, b);
    return 1;
}

/* WM_NCLBUTTONUP. The action happens on the RELEASE, and only over the button
 * that was pressed -- pressing close and letting go over minimize does nothing,
 * as it does on every Windows window. */
static int nc_lbutton_up(spdf_win_window* window, WPARAM hit) {
    int pressed = window->caption_pressed;
    int b = caption_button_for(hit);
    if (pressed == SPDF_WIN_CAPTION_NONE) return b != SPDF_WIN_CAPTION_NONE;
    caption_set(window, b, SPDF_WIN_CAPTION_NONE);
    if (b != pressed) return 1;
    switch (b) {
        case SPDF_WIN_CAPTION_MINIMIZE: ShowWindow(window->hwnd, SW_MINIMIZE); break;
        case SPDF_WIN_CAPTION_MAXIMIZE: ShowWindow(window->hwnd, window->maximized ? SW_RESTORE : SW_MAXIMIZE); break;
        /* PostMessage, not DestroyWindow: WM_CLOSE is the path every other close
         * takes (Escape, Alt+F4, the taskbar), and it is what runs the session
         * save on the way out. */
        case SPDF_WIN_CAPTION_CLOSE: PostMessageW(window->hwnd, WM_CLOSE, 0, 0); break;
        default: break;
    }
    return 1;
}

/* The pointer left the non-client area -- for the client, or for another
 * window. Either way nothing of ours is hovered or held any more. */
static void nc_mouse_leave(spdf_win_window* window) {
    caption_set(window, SPDF_WIN_CAPTION_NONE, SPDF_WIN_CAPTION_NONE);
}
