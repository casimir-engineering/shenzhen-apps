#pragma once

/* The tab strip's hover preview, as a Win32 tracking tooltip -- for
 * spdf_win_window.cpp only.
 *
 * Same arrangement as spdf_win_window_frame.h and spdf_win_window_caption.h
 * beside it: header-only, included from exactly one translation unit, AFTER
 * `struct spdf_win_window` because it dereferences it, and not part of the
 * port's public surface.
 *
 * WHY A SYSTEM TOOLTIP AND NOT PIXELS OF OUR OWN. macOS shows a borderless
 * NSPanel with the tab's full title when the pointer rests on a tab
 * (SPDFMacTabStripView.mm:317-345). The Windows equivalent that every reader
 * already knows is the tooltip, and a tooltip is a WINDOW: it floats over the
 * strip, it can overhang the frame, and it is drawn by the system in the
 * system's theme. Drawing it inside our own client area would clip it at the
 * window edge and put a text bubble on the paint path of every offscreen pixel
 * test in this port for a thing that only exists while a pointer hovers.
 *
 * TRACKING (TTF_TRACK | TTF_ABSOLUTE), because the strip's tabs are not child
 * windows and a tooltip needs either a control or an explicit position. The
 * caller says where; this file says when: after SPDF_WIN_TOOLTIP_DELAY_MS, so a
 * pointer crossing the strip on its way to the toolbar does not flash a path.
 */

#include <commctrl.h>
#pragma comment(lib, "comctl32.lib")

#define SPDF_WIN_TOOLTIP_DELAY_MS 600

static void tooltip_hide(spdf_win_window* window) {
    TOOLINFOW ti;
    if (!window->hwnd) return;
    KillTimer(window->hwnd, SPDF_WIN_TIMER_TOOLTIP);
    window->tooltip_text[0] = L'\0';
    if (!window->tooltip) return;
    memset(&ti, 0, sizeof(ti));
    ti.cbSize = sizeof(ti);
    ti.hwnd = window->hwnd;
    ti.uId = 1;
    SendMessageW(window->tooltip, TTM_TRACKACTIVATE, FALSE, (LPARAM)&ti);
}

static int tooltip_ensure(spdf_win_window* window) {
    INITCOMMONCONTROLSEX icc;
    TOOLINFOW ti;
    if (window->tooltip) return 1;
    icc.dwSize = sizeof(icc);
    icc.dwICC = ICC_WIN95_CLASSES;
    InitCommonControlsEx(&icc);
    /* Owned by our window (not a child), so it can overhang the frame and is
     * destroyed with it. TTS_ALWAYSTIP shows it whether or not we are active. */
    window->tooltip = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, TOOLTIPS_CLASSW, NULL,
                                      WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP, CW_USEDEFAULT, CW_USEDEFAULT,
                                      CW_USEDEFAULT, CW_USEDEFAULT, window->hwnd, NULL, GetModuleHandleW(NULL), NULL);
    if (!window->tooltip) return 0;
    memset(&ti, 0, sizeof(ti));
    ti.cbSize = sizeof(ti);
    ti.uFlags = TTF_TRACK | TTF_ABSOLUTE;
    ti.hwnd = window->hwnd;
    ti.uId = 1;
    ti.lpszText = window->tooltip_text;
    SendMessageW(window->tooltip, TTM_ADDTOOLW, 0, (LPARAM)&ti);
    /* A path can be long; wrap rather than run off the screen. */
    SendMessageW(window->tooltip, TTM_SETMAXTIPWIDTH, 0, (LPARAM)(int)(480.0f * spdf_win_window_dpi_scale(window)));
    return 1;
}

/* The delay elapsed with the text still wanted: show it. */
static void tooltip_fire(spdf_win_window* window) {
    TOOLINFOW ti;
    POINT pt;
    KillTimer(window->hwnd, SPDF_WIN_TIMER_TOOLTIP);
    if (!window->tooltip_text[0] || !tooltip_ensure(window)) return;
    memset(&ti, 0, sizeof(ti));
    ti.cbSize = sizeof(ti);
    ti.uFlags = TTF_TRACK | TTF_ABSOLUTE;
    ti.hwnd = window->hwnd;
    ti.uId = 1;
    ti.lpszText = window->tooltip_text;
    SendMessageW(window->tooltip, TTM_SETTOOLINFOW, 0, (LPARAM)&ti);
    pt.x = window->tooltip_x;
    pt.y = window->tooltip_y;
    ClientToScreen(window->hwnd, &pt);
    SendMessageW(window->tooltip, TTM_TRACKPOSITION, 0, (LPARAM)MAKELONG(pt.x, pt.y));
    SendMessageW(window->tooltip, TTM_TRACKACTIVATE, TRUE, (LPARAM)&ti);
}

void spdf_win_window_tooltip(spdf_win_window* window, const wchar_t* text, int x, int y) {
    if (!window || !window->hwnd) return;
    if (!text || !text[0]) {
        tooltip_hide(window);
        return;
    }
    /* Already showing or pending the same text at the same place: leave it. */
    if (wcscmp(window->tooltip_text, text) == 0 && window->tooltip_x == x && window->tooltip_y == y) return;
    tooltip_hide(window);
    wcsncpy_s(window->tooltip_text, text, _TRUNCATE);
    window->tooltip_x = x;
    window->tooltip_y = y;
    SetTimer(window->hwnd, SPDF_WIN_TIMER_TOOLTIP, SPDF_WIN_TOOLTIP_DELAY_MS, NULL);
}
