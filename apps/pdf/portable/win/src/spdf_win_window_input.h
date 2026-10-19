#pragma once

/* Win32 message -> spdf_win_input translation, for spdf_win_window.cpp only.
 *
 * NOT A NEW LAYER. Every function here was in spdf_win_window.cpp and does
 * exactly what it did there; it moved out when routing the mouse through the
 * chrome pushed that file to its 500-line cap, and tools/file-size-limits.md
 * asks for an extracted file rather than a raised one. Same arrangement as
 * spdf_win_tabs_app.h and spdf_win_headless_viewport.h: header-only, included
 * from exactly one translation unit, AFTER `struct spdf_win_window` because it
 * dereferences it, and not part of the port's public surface.
 *
 * WHAT BELONGS HERE: turning a Win32 message into the small vocabulary
 * spdf_win_window.h declares -- filling in the fields every event carries,
 * converting WM_MOUSEWHEEL's screen point to client space, honouring the user's
 * SPI_GETWHEELSCROLLLINES, asking for a WM_MOUSELEAVE. WHAT DOES NOT: any
 * decision about what an event MEANS. That belongs to the caller, and the window
 * proc next door is the only thing that calls these.
 */

/* What one wheel event is worth in pixels and in zoom -- pure, and therefore
 * tested (portable/win/tests/wheel_input_test.c). See its header for the
 * precision-touchpad case, which is the reason it is not inline below. */
#include "spdf_win_wheel.h"

/* Fills in the fields every event carries and dispatches. Returns non-zero when
 * the handler changed the view, and invalidates when it did. */
static int dispatch(spdf_win_window* window, spdf_win_input* input) {
    RECT rc = {0, 0, 0, 0};

    if (!window->input_fn) return 0;
    GetClientRect(window->hwnd, &rc);
    input->view_px_w = (unsigned)(rc.right - rc.left);
    input->view_px_h = (unsigned)(rc.bottom - rc.top);
    /* VK_MENU is the Alt key, whose name in the VK table is a fossil of the
     * days when Alt opened menus and nothing else. macOS's page navigation is on
     * Option, which is the same key in the same role, so the accelerators need
     * this bit. */
    input->mods = (GetKeyState(VK_CONTROL) < 0 ? SPDF_WIN_MOD_CTRL : 0u) |
                  (GetKeyState(VK_SHIFT) < 0 ? SPDF_WIN_MOD_SHIFT : 0u) |
                  (GetKeyState(VK_MENU) < 0 ? SPDF_WIN_MOD_ALT : 0u);
    /* So the handler can divide the client area exactly as the painter did. */
    input->dpi_scale = spdf_win_window_dpi_scale(window);
    if (!window->input_fn(window->user, input)) return 0;
    InvalidateRect(window->hwnd, NULL, FALSE);
    return 1;
}

/* THE CLICK COUNT, accumulated. See spdf_win_window.h's `click_count`.
 *
 * The rule is one line and covers every length of series: a press that is soon
 * enough and near enough to the previous one continues it, and anything else
 * starts a new one. That works BECAUSE Win32 alternates the two messages -- a
 * quadruple click is DOWN, DBLCLK, DOWN, DBLCLK -- so the count is simply how
 * many presses have landed in the same place in a row, whatever Windows chose to
 * call each of them.
 *
 * GetMessageTime, not GetTickCount: the count must be decided by when the click
 * HAPPENED, not by when a busy UI thread got round to it. SM_CXDOUBLECLK is the
 * full width of the double-click rectangle, hence the halves. */
static unsigned next_click_count(spdf_win_window* window, LPARAM lparam) {
    DWORD now = (DWORD)GetMessageTime();
    LONG x = GET_X_LPARAM(lparam), y = GET_Y_LPARAM(lparam);
    int near_enough = labs(x - window->last_click_x) <= GetSystemMetrics(SM_CXDOUBLECLK) / 2 &&
                      labs(y - window->last_click_y) <= GetSystemMetrics(SM_CYDOUBLECLK) / 2;
    int soon_enough = (DWORD)(now - window->last_click_time) <= GetDoubleClickTime();

    if (soon_enough && near_enough && window->click_count > 0) window->click_count += 1;
    else window->click_count = 1;
    window->last_click_time = now;
    window->last_click_x = x;
    window->last_click_y = y;
    return window->click_count;
}

/* ASK FOR ONE WM_MOUSELEAVE -- AND ONLY WHILE THE POINTER IS INSIDE.
 *
 * A hover highlight that is lit when the pointer leaves stays lit unless Win32
 * is asked for a WM_MOUSELEAVE; AppKit clears that free. But TrackMouseEvent is
 * only meaningful while the pointer is over hwndTrack: called when it is NOT,
 * USER32 posts WM_MOUSELEAVE back IMMEDIATELY, by documented design.
 *
 * This used to be armed from dispatch_mouse() for every SPDF_WIN_INPUT_MOUSE_MOVE
 * -- including the synthetic (-1, -1) move the WM_MOUSELEAVE case itself sends to
 * clear the hot flags. That closed a loop with no exit: leave -> arm -> leave,
 * posted messages, at the speed of the pump, for as long as the pointer was
 * outside the window. The pump never went idle, so USER32 never reached the
 * point where it SYNTHESISES WM_PAINT (it does that only for an otherwise empty
 * queue), and posted messages outrank hardware input, so keystrokes starved too.
 * That is the whole of the "click Open a PDF and everything freezes" report: the
 * shell's Open dialog appears -- under the pointer, hence outside this window --
 * constructs itself correctly, erases its children, and then never receives the
 * WM_PAINT that would fill them in, so it stands there as white rectangles while
 * the process spins. Section 20 of portable/docs/windows-native-observations.md
 * is the measurement.
 *
 * So the arming lives HERE and is called from WM_MOUSEMOVE only -- the one
 * message that proves the pointer is in this client area -- and `tracking_leave`
 * makes it once per entry rather than once per move. WM_MOUSELEAVE clears the
 * flag and asks for nothing. dispatch_mouse() no longer arms anything, which is
 * what makes the loop unreachable rather than merely absent. (The caption's
 * TME_NONCLIENT tracker in spdf_win_window_caption.h is armed from
 * WM_NCMOUSEMOVE and never from WM_NCMOUSELEAVE, so it has the same property.) */
static void track_mouse_leave(spdf_win_window* window) {
    TRACKMOUSEEVENT tme;
    if (window->tracking_leave) return;
    tme.cbSize = sizeof(tme);
    tme.dwFlags = TME_LEAVE;
    tme.hwndTrack = window->hwnd;
    tme.dwHoverTime = 0;
    if (!TrackMouseEvent(&tme)) return;
    window->tracking_leave = 1;
}

/* One mouse event out to the handler, in CLIENT device pixels -- which is what
 * every mouse message but WM_MOUSEWHEEL carries (see on_wheel). */
static int dispatch_mouse(spdf_win_window* window, spdf_win_input_kind kind, int button, LPARAM lparam) {
    spdf_win_input input;
    memset(&input, 0, sizeof(input));
    input.kind = kind;
    input.button = button;
    if (kind == SPDF_WIN_INPUT_MOUSE_DOWN) input.click_count = window->click_count;
    input.x = (float)GET_X_LPARAM(lparam);
    input.y = (float)GET_Y_LPARAM(lparam);
    input.cursor = SPDF_WIN_CC_ARROW;
    return dispatch(window, &input);
}

/* The user's own SPI_GETWHEELSCROLLLINES, including its WHEEL_PAGESCROLL
 * spelling of "a screenful". Asked on every event rather than cached because it
 * is a live setting and a wheel event is not a hot path. What a notch is WORTH
 * is spdf_win_wheel.h's, which is pure and therefore tested. */
static UINT wheel_lines(void) {
    UINT lines = 3;
    SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    return lines;
}

/* Mouse wheel, both axes. Ctrl zooms at the cursor; Shift turns a vertical
 * wheel horizontal, which is the Windows convention for a one-axis mouse.
 *
 * THE DELTA IS NOT ASSUMED TO BE A MULTIPLE OF 120. A Windows Precision
 * Touchpad reports the finger's travel, so it sends a stream of small arbitrary
 * deltas -- and its pinch arrives here too, as Ctrl + wheel. Every conversion
 * below is fractional (spdf_win_wheel.h); rounding a notch count to an integer
 * would make every one of those events worth exactly nothing, which is a view
 * that will not move for a reader who has no mouse. */
static void on_wheel(spdf_win_window* window, WPARAM wparam, LPARAM lparam, bool horizontal) {
    spdf_win_input input;
    POINT pt;
    int delta = GET_WHEEL_DELTA_WPARAM(wparam);
    RECT rc = {0, 0, 0, 0};

    memset(&input, 0, sizeof(input));
    /* WM_MOUSEWHEEL carries SCREEN coordinates, unlike every other mouse
     * message in this file. Converting is not optional: the un-converted point
     * would anchor a Ctrl+wheel zoom to wherever the window happens to sit on
     * the desktop. */
    pt.x = GET_X_LPARAM(lparam);
    pt.y = GET_Y_LPARAM(lparam);
    ScreenToClient(window->hwnd, &pt);
    input.x = (float)pt.x;
    input.y = (float)pt.y;

    if (!horizontal && (GET_KEYSTATE_WPARAM(wparam) & MK_CONTROL)) {
        input.kind = SPDF_WIN_INPUT_ZOOM;
        /* Geometric, so N notches out exactly undo N notches in -- and so a
         * pinch delivered as forty small deltas lands on the same zoom as one
         * notch of the same travel. */
        input.factor = spdf_win_wheel_zoom_factor(delta);
        dispatch(window, &input);
        return;
    }

    GetClientRect(window->hwnd, &rc);
    float step = spdf_win_wheel_distance_px(delta, wheel_lines(), spdf_win_window_dpi_scale(window),
                                            (unsigned)(rc.bottom - rc.top));
    input.kind = SPDF_WIN_INPUT_SCROLL;
    if (horizontal || (GET_KEYSTATE_WPARAM(wparam) & MK_SHIFT)) input.dx = horizontal ? step : -step;
    else input.dy = -step;
    dispatch(window, &input);
}

/* --- the keyboard, the menu and the drop target -------------------------- */

/* THE CHARACTER A VIRTUAL-KEY CODE STANDS FOR ON THE ACTIVE LAYOUT, or 0.
 *
 * spdf_win_input::key_char, and the whole of why it exists is next to that
 * field: a virtual-key code is a property of the layout, and VK_OEM_MINUS is on
 * no French key at all. MapVirtualKeyW answers for the layout of the thread that
 * owns the window -- which is this thread -- so a reader who switches layouts
 * mid-session gets the new answer on the next keystroke with no WM_INPUTLANGCHANGE
 * bookkeeping of our own.
 *
 * MAPVK_VK_TO_CHAR (2), NOT ToUnicode: ToUnicode CONSUMES the kernel's pending
 * dead-key state, so calling it on every WM_KEYDOWN would silently eat the
 * accent a reader had just started composing in the find field. MapVirtualKeyW
 * has no state at all. Its high bit marks a dead key, which is not a character
 * anyone can bind, so it is reported as none.
 *
 * `hwnd` is unused today and named for the contract: this answer is about a
 * window's thread's layout, not about the process. */
static unsigned key_char_for(HWND hwnd, unsigned vk) {
    UINT ch = MapVirtualKeyW(vk, 2 /* MAPVK_VK_TO_CHAR */);
    (void)hwnd;
    if (ch == 0 || (ch & 0x80000000u)) return 0; /* none, or a dead key */
    ch &= 0x7FFFFFFFu;
    /* Letters come back uppercase already; the guard is for a layout that does
     * not, so the keymap can compare against 'A'..'Z' without a case rule. */
    if (ch >= L'a' && ch <= L'z') ch -= 32;
    return ch < 0x10000u ? (unsigned)ch : 0u;
}

/* WHETHER THIS KEYSTROKE IS TEXT: spdf_win_input::text_key.
 *
 * Asked of the QUEUE rather than of the layout, and that is the cheap, exact
 * and side-effect-free way to ask it. The pump calls TranslateMessage before
 * DispatchMessageW (spdf_win_window_lifecycle.h), so by the time this WM_KEYDOWN
 * reaches the window procedure the WM_CHAR it produces -- if it produces one --
 * is ALREADY sitting in this thread's queue. PM_NOREMOVE looks without taking:
 * the WM_CHAR still arrives afterwards and still reaches the find field.
 *
 * Printable only. Ctrl+F also queues a WM_CHAR (0x06), and treating that as text
 * would disable every accelerator in the table; 0x20 and up is the same test
 * spdf_win_chrome_text.h applies to what it will insert.
 *
 * A caller that posts WM_KEYDOWN without TranslateMessage -- a test harness --
 * gets 0, which is the behaviour this port had before the field existed. */
static int key_is_text(HWND hwnd) {
    MSG next;
    if (!PeekMessageW(&next, hwnd, WM_CHAR, WM_CHAR, PM_NOREMOVE)) return 0;
    return next.wParam >= 0x20 && next.wParam != 0x7F;
}

/* One of the three events that carry nothing but a number. Shared because the
 * only difference between them is the kind, and three near-identical eight-line
 * functions is three places for a missing memset. */
static int dispatch_value(spdf_win_window* window, spdf_win_input_kind kind, unsigned value) {
    spdf_win_input input;
    memset(&input, 0, sizeof(input));
    input.kind = kind;
    input.key = value;
    return dispatch(window, &input);
}

/* WM_DROPFILES, one event per file.
 *
 * The order is Windows' own, which for a multi-selection is the order the files
 * were selected in rather than the order they appear on screen; there is no
 * other order available, and a caller that opens each in a tab wants them all
 * regardless. DragFinish is mandatory -- the HDROP is a global allocation the
 * receiver owns, and leaking one leaks it for the life of the process. */
static void dispatch_drop(spdf_win_window* window, WPARAM wparam) {
    HDROP drop = (HDROP)wparam;
    UINT count, i;
    if (!drop) return;
    count = DragQueryFileW(drop, 0xFFFFFFFFu, NULL, 0);
    for (i = 0; i < count; ++i) {
        wchar_t path[MAX_PATH * 4];
        spdf_win_input input;
        if (DragQueryFileW(drop, i, path, (UINT)(sizeof(path) / sizeof(path[0]))) == 0) continue;
        memset(&input, 0, sizeof(input));
        input.kind = SPDF_WIN_INPUT_DROP_FILE;
        input.text = path;
        dispatch(window, &input);
    }
    DragFinish(drop);
    /* The window that received a drop is not necessarily the active one -- a
     * drag from Explorer does not activate its target -- and a viewer that has
     * just been given a document and stayed behind Explorer looks broken. */
    SetForegroundWindow(window->hwnd);
}

/* End a press. `button` is the one that came up, or SPDF_WIN_CB_NONE for a
 * CANCELLATION -- the distinction spdf_win_window.h documents. */
static void end_press(spdf_win_window* window, int button, LPARAM lparam) {
    if (window->pressed == SPDF_WIN_CB_NONE) return;
    window->pressed = SPDF_WIN_CB_NONE;
    dispatch_mouse(window, SPDF_WIN_INPUT_MOUSE_UP, button, lparam);
    if (GetCapture() == window->hwnd) ReleaseCapture();
}
