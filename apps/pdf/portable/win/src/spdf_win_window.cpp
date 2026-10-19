/* Win32 window + message pump. See spdf_win_window.h for the layering rule.
 *
 * Every Win32 call here is an explicit *W call. guest-build.cmd does not
 * define UNICODE, so the undecorated names would silently resolve to the ANSI
 * variants and mangle every non-ASCII document title -- the exact class of bug
 * windows-port-plan.md sec 2.2 warns about ("Call *W APIs exclusively; never
 * *A").
 */
#include "spdf_win_window.h"

/* For SPDF_WIN_MENU_ID_BASE alone. WM_COMMAND's low word is a number the two
 * files have to agree about; the table it indexes stays entirely next door. */
#include "spdf_win_menu.h"
/* For spdf_win_chrome_caption_set_state() alone: the three caption facts only
 * an HWND knows (maximized, hovered button, held button), pushed to the model
 * the chrome painter reads. See spdf_win_window_caption.h. */
#include "spdf_win_chrome_model.h"
/* The launch-health counters. One call at the top of window_proc and one after
 * EndPaint; both are a switch and an InterlockedIncrement, and the whole reason
 * they are here is that "the window received no input at all" and "the window
 * received the input and did nothing with it" look identical from outside.
 * spdf_win_health.h says what is done with them. */
#include "spdf_win_health.h"
#include "spdf_win_launch_profile.h" /* SPDF-LAUNCH markers; free when unset */

#include <windowsx.h> /* GET_X_LPARAM / GET_Y_LPARAM */
#include <shellapi.h> /* DragAcceptFiles / DragQueryFileW / DragFinish */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "user32.lib")

static const wchar_t kWindowClass[] = L"ShenzhenPDFWindow";

struct spdf_win_window {
    HWND hwnd;
    spdf_win_d2d* d2d;
    ID2D1HwndRenderTarget* target;
    spdf_win_scene_fn scene_fn;
    spdf_win_input_fn input_fn;
    void* user;
    UINT dpi;
    int exit_code;
    /* The CLIENT area that was asked for, in 96-dpi pixels. Kept because two
     * later events -- the DPI of the monitor the window actually landed on, and
     * a menu bar being installed -- both change the FRAME needed to deliver it,
     * and neither can recover the request from the window. */
    int client_px_w;
    int client_px_h;
    /* The multi-click series in progress: how many presses have landed in the
     * same place in a row, and when and where the last one was. See
     * next_click_count() in spdf_win_window_input.h. */
    unsigned click_count;
    DWORD last_click_time;
    LONG last_click_x;
    LONG last_click_y;

    /* Which button, if any, is held with the capture. The authority, not
     * GetCapture(): a capture can be taken away (an Alt+Tab, a system modal) and
     * the WM_CAPTURECHANGED that follows must end the gesture, or the next mouse
     * move a second later applies the distance travelled in between. WHAT the
     * gesture means is the caller's now; the capture is the Win32 half. */
    int pressed; /* spdf_win_chrome_button; SPDF_WIN_CB_NONE when nothing is */

    /* A WM_MOUSELEAVE HAS BEEN ASKED FOR AND HAS NOT ARRIVED. Set by
     * track_mouse_leave(), which only WM_MOUSEMOVE calls because that is the one
     * message that proves the pointer is in this client area; cleared by
     * WM_MOUSELEAVE. It exists so the request is made once per entry -- and, more
     * importantly, so the leave handler cannot ask again: TrackMouseEvent called
     * with the pointer OUTSIDE hwndTrack posts WM_MOUSELEAVE straight back, which
     * is a message loop with no exit. See track_mouse_leave() in
     * spdf_win_window_input.h. */
    int tracking_leave;

    /* THE CAPTION IS OURS (spdf_win_window_caption.h). Whether the window is
     * maximized, and which of the three drawn caption buttons the pointer is over
     * or holding, as spdf_win_caption_button. Mirrored into the chrome model
     * through spdf_win_chrome_caption_set_state() whenever any of them changes. */
    int maximized;
    int caption_hot;
    int caption_pressed;

    /* FULL SCREEN (spdf_win_window_frame.h). The placement to go back to, valid
     * only while `fullscreen` is set. */
    int fullscreen;
    WINDOWPLACEMENT placement;

    /* THE RESTORED PLACEMENT (spdf_win_window_frame.h, rules in
     * spdf_win_placement.h). `desired` is the frame the reader left, valid
     * while has_desired. `parked` says the window is showing a fallback because
     * that frame's display is missing, and parked_rect is the fallback we put
     * it at -- a normal rect that differs from it is the reader's own move,
     * which ends the parking. `placing` marks our own SetWindowPlacement /
     * SetWindowPos so their WM_WINDOWPOSCHANGED is not mistaken for one. */
    spdf_win_placement desired;
    int has_desired;
    int parked;
    RECT parked_rect;
    int placing;
    /* Whether this was the foreground window when WM_CLOSE arrived: the
     * answer spdf_win_window_is_foreground gives once the HWND is gone. */
    int foreground_at_close;

    /* The periodic tick (spdf_win_window_set_tick), or NULL. */
    spdf_win_tick_fn tick_fn;
    /* The pending one-shot (spdf_win_window_set_once), or NULL. Cleared before
     * it is called, so a handler that schedules another one-shot wins rather
     * than being overwritten by its own completion. */
    spdf_win_tick_fn once_fn;

    /* THE TOOLTIP (spdf_win_window_tooltip.h): the control, created on first
     * use, and the text waiting for the show delay to elapse. */
    HWND tooltip;
    wchar_t tooltip_text[512];
    int tooltip_x;
    int tooltip_y;
};

/* Timer ids. WM_TIMER carries the id in wParam; these three are the only
 * timers this window sets. */
#define SPDF_WIN_TIMER_TICK 1
#define SPDF_WIN_TIMER_TOOLTIP 2
#define SPDF_WIN_TIMER_ONCE 3

float spdf_win_window_dpi_scale(const spdf_win_window* window) {
    if (!window || window->dpi == 0) return 1.0f;
    return (float)window->dpi / (float)USER_DEFAULT_SCREEN_DPI;
}

/* The HWND render target and paint(). Depends on `struct spdf_win_window`
 * above, hence the position. */
#include "spdf_win_window_target.h"

/* Message-to-input translation: dispatch(), dispatch_mouse(), on_wheel() and
 * end_press(). Depends on `struct spdf_win_window` above, hence the position. */
#include "spdf_win_window_input.h"

/* The caption as client area: WM_NCCALCSIZE, WM_NCHITTEST, the caption buttons.
 * Depends on dispatch() above, hence the position. */
#include "spdf_win_window_caption.h"

/* The frame, the title, the dark frame, full screen and the menu bar. Depends
 * on frame_extents() above, hence the position. */
#include "spdf_win_window_frame.h"

/* The tab strip's hover preview. Depends on `struct spdf_win_window` and the
 * timer ids above. */
#include "spdf_win_window_tooltip.h"

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    spdf_win_window* window = (spdf_win_window*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

    /* BEFORE the switch, so a message a handler returns early on is still
     * counted: the counters answer "did it arrive", not "was it used". */
    spdf_win_health_note_message(msg);

    if (msg == WM_NCCREATE) {
        CREATESTRUCTW* cs = (CREATESTRUCTW*)lparam;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    if (!window) return DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            BeginPaint(hwnd, &ps);
            paint(window);
            EndPaint(hwnd, &ps);
            /* AFTER EndPaint, so the count is frames COMPLETED. */
            spdf_win_health_note_paint();
            return 0;
        }
        /* D2D repaints the whole client area every time, so letting GDI erase
         * it first buys nothing but a flash of white on every resize. */
        case WM_ERASEBKGND:
            return 1;
        case WM_SIZE:
            if (wparam != SIZE_MINIMIZED && window->target)
                window->target->Resize(D2D1::SizeU(LOWORD(lparam), HIWORD(lparam)));
            sync_maximized(window);
            return 0;
        /* THE CAPTION IS CLIENT AREA. See spdf_win_window_caption.h for all
         * six of these; the first two are what make the strip the title bar,
         * the other four are the three buttons the chrome draws. */
        case WM_NCCALCSIZE:
            return nc_calc_size(window, wparam, lparam);
        case WM_NCHITTEST:
            return nc_hit_test(window, wparam, lparam);
        case WM_NCMOUSEMOVE:
            nc_mouse_move(window, wparam);
            break;
        case WM_NCMOUSELEAVE:
            nc_mouse_leave(window);
            break;
        case WM_NCLBUTTONDOWN:
        case WM_NCLBUTTONDBLCLK:
            if (nc_lbutton_down(window, wparam)) return 0;
            break;
        case WM_NCLBUTTONUP:
            if (nc_lbutton_up(window, wparam)) return 0;
            break;
        case WM_MOUSEWHEEL:
            on_wheel(window, wparam, lparam, false);
            return 0;
        case WM_MOUSEHWHEEL:
            on_wheel(window, wparam, lparam, true);
            return 0;
        /* WM_LBUTTONDBLCLK IS AN ORDINARY PRESS HERE, and it exists at all
         * because the class asks for CS_DBLCLKS. Windows delivers the second
         * click of a double as this message INSTEAD of a WM_LBUTTONDOWN, so a
         * window that does not handle it loses every even-numbered click -- a
         * double-click to select a word would drop half of itself. What makes it
         * a double rather than a single is the count, which next_click_count()
         * has already worked out. */
        case WM_LBUTTONDOWN:
        case WM_LBUTTONDBLCLK:
        case WM_MBUTTONDOWN:
            tooltip_hide(window); /* a press ends a hover */
            /* Capture first, so a handler that starts a drag has the pointer. */
            window->pressed = msg == WM_MBUTTONDOWN ? SPDF_WIN_CB_MIDDLE : SPDF_WIN_CB_LEFT;
            if (msg != WM_MBUTTONDOWN) next_click_count(window, lparam);
            SetCapture(hwnd);
            SetFocus(hwnd);
            dispatch_mouse(window, SPDF_WIN_INPUT_MOUSE_DOWN, window->pressed, lparam);
            return 0;
        case WM_MOUSEMOVE:
            /* The pointer is in the client, so no caption button is under it,
             * whatever WM_NCMOUSELEAVE did or did not say. */
            if (window->caption_hot != SPDF_WIN_CAPTION_NONE)
                caption_set(window, SPDF_WIN_CAPTION_NONE, window->caption_pressed);
            /* The pointer is HERE, which is what makes this the one place that
             * may ask for a WM_MOUSELEAVE at all -- see track_mouse_leave(). */
            track_mouse_leave(window);
            /* Unconditionally, not only while a button is down: hover state is
             * what lights the tab strip, and the handler decides if it changed. */
            dispatch_mouse(window, SPDF_WIN_INPUT_MOUSE_MOVE, window->pressed, lparam);
            return 0;
        case WM_MOUSELEAVE:
            /* The request is spent. NOTHING BELOW MAY ASK FOR ANOTHER: the
             * pointer is outside, and TrackMouseEvent from here posts this
             * message straight back (track_mouse_leave()). */
            window->tracking_leave = 0;
            /* A position no chrome contains, so the router clears every hot flag.
             * Not while a button is down: the capture keeps the gesture alive
             * outside the window and (-1, -1) would pan the whole way there. */
            if (window->pressed == SPDF_WIN_CB_NONE)
                dispatch_mouse(window, SPDF_WIN_INPUT_MOUSE_MOVE, SPDF_WIN_CB_NONE, (LPARAM)-1);
            tooltip_hide(window);
            return 0;
        /* The right button, as SPDF_WIN_INPUT_CONTEXT. No capture, no release:
         * see the enum. Consumed whether or not the handler wanted it -- with no
         * menu bar there is no WM_CONTEXTMENU anyone is waiting for. */
        case WM_RBUTTONDOWN:
            SetFocus(hwnd);
            dispatch_mouse(window, SPDF_WIN_INPUT_CONTEXT, SPDF_WIN_CB_NONE, lparam);
            return 0;
        case WM_TIMER:
            if (wparam == SPDF_WIN_TIMER_TICK && window->tick_fn) window->tick_fn(window->user);
            else if (wparam == SPDF_WIN_TIMER_TOOLTIP) tooltip_fire(window);
            else if (wparam == SPDF_WIN_TIMER_ONCE) {
                /* Killed and cleared BEFORE the call, so the one-shot cannot
                 * fire twice however long the handler takes and whatever it
                 * does to this window. */
                spdf_win_tick_fn fn = window->once_fn;
                KillTimer(hwnd, SPDF_WIN_TIMER_ONCE);
                window->once_fn = NULL;
                if (fn) fn(window->user);
            }
            return 0;
        case WM_LBUTTONUP:
            /* A caption button pressed and released over the client is a press
             * abandoned, not a click. */
            if (window->caption_pressed != SPDF_WIN_CAPTION_NONE)
                caption_set(window, SPDF_WIN_CAPTION_NONE, SPDF_WIN_CAPTION_NONE);
            end_press(window, SPDF_WIN_CB_LEFT, lparam);
            return 0;
        case WM_MBUTTONUP:
            end_press(window, SPDF_WIN_CB_MIDDLE, lparam);
            return 0;
        case WM_CAPTURECHANGED:
            /* lparam is the window that TOOK the capture, not a position, and
             * SPDF_WIN_CB_NONE already says "cancelled", not "clicked". */
            end_press(window, SPDF_WIN_CB_NONE, 0);
            return 0;
        case WM_SETCURSOR:
            if (LOWORD(lparam) == HTCLIENT) {
                /* Ask the handler: the answer is about the chrome, or during a
                 * drag about the drag. WM_SETCURSOR carries no position. */
                POINT pt = {0, 0};
                spdf_win_input query;
                UINT id = 32512; /* IDC_ARROW */
                memset(&query, 0, sizeof(query));
                query.kind = SPDF_WIN_INPUT_CURSOR;
                query.button = window->pressed;
                query.cursor = SPDF_WIN_CC_ARROW;
                if (GetCursorPos(&pt) && ScreenToClient(hwnd, &pt)) {
                    query.x = (float)pt.x;
                    query.y = (float)pt.y;
                    dispatch(window, &query);
                }
                if (query.cursor == SPDF_WIN_CC_SIZEWE) id = 32644;       /* IDC_SIZEWE */
                else if (query.cursor == SPDF_WIN_CC_SIZEALL) id = 32646; /* IDC_SIZEALL */
                else if (query.cursor == SPDF_WIN_CC_IBEAM) id = 32513;   /* IDC_IBEAM */
                else if (query.cursor == SPDF_WIN_CC_HAND) id = 32649;    /* IDC_HAND */
                SetCursor(LoadCursorW(NULL, MAKEINTRESOURCEW(id)));
                return TRUE;
            }
            break;
        case WM_GETMINMAXINFO:
            min_track_size(window, (MINMAXINFO*)lparam);
            return 0;
        case WM_DPICHANGED: {
            /* Windows hands us the rectangle the window should occupy on the
             * monitor it just moved to. Honouring it is what makes a drag
             * between a 1x and a 2x display keep the window physically the
             * same size instead of doubling. */
            window->dpi = HIWORD(wparam);
            RECT* suggested = (RECT*)lparam;
            /* NOT while a saved placement is being applied: that frame is
             * already in its own display's device pixels, and the suggested
             * rectangle would rescale it from the display it was created on --
             * a 1300-wide window came back 1300 * (144/96) and grew on every
             * relaunch. The DPI itself is still taken. */
            if (!window->placing) {
                placement_own_move(window, suggested);
            }
            extend_frame_into_strip(window); /* the caption height changed with the DPI */
            InvalidateRect(hwnd, NULL, FALSE);
            return 0;
        }
        /* A display came or went. If the window is parked because its own
         * display was missing and that frame can be shown now, put it back. */
        case WM_DISPLAYCHANGE:
            placement_displays_changed(window);
            break;
        /* Every position change, ours and the reader's; the placement code tells
         * them apart. `break`, not `return`: DefWindowProc turns this into the
         * WM_SIZE and WM_MOVE the rest of the window runs on. */
        case WM_WINDOWPOSCHANGED:
            placement_note_moved(window);
            break;
        /* Recorded HERE, where the window is still the one the reader closed:
         * DestroyWindow deactivates it before WM_DESTROY, so asking then always
         * says no. Then DefWindowProc destroys it. */
        case WM_CLOSE:
            window->foreground_at_close = GetForegroundWindow() == hwnd;
            break;
        case WM_COMMAND:
            /* A menu item, and nothing else: this window has no child controls,
             * so a WM_COMMAND with a non-zero lParam (a control) or a high word
             * of 1 (an accelerator table, which this port does not use -- see
             * spdf_win_menu.h) is not ours. */
            if (lparam == 0 && HIWORD(wparam) == 0 && LOWORD(wparam) >= SPDF_WIN_MENU_ID_BASE) {
                dispatch_value(window, SPDF_WIN_INPUT_COMMAND, (unsigned)(LOWORD(wparam) - SPDF_WIN_MENU_ID_BASE));
                return 0;
            }
            break;
        case WM_CHAR:
            /* Always consumed, handled or not. DefWindowProc does nothing with a
             * WM_CHAR for a window with no child controls, and a key the handler
             * declined is a key nobody wanted -- passing it on would only reach
             * the default beep. Menu mnemonics arrive as WM_SYSCHAR, which is
             * untouched. */
            dispatch_value(window, SPDF_WIN_INPUT_CHAR, (unsigned)wparam);
            return 0;
        case WM_DROPFILES:
            dispatch_drop(window, wparam);
            return 0;
        /* WM_SYSKEYDOWN as well as WM_KEYDOWN, because Alt+key arrives as the
         * former and macOS puts page navigation on Option+arrows. Anything the
         * handler declines falls through to DefWindowProc, which is what keeps
         * Alt+F opening the File menu and Alt+F4 closing the window. */
        case WM_SYSKEYDOWN:
        case WM_KEYDOWN: {
            spdf_win_input input;
            memset(&input, 0, sizeof(input));
            input.kind = SPDF_WIN_INPUT_KEY;
            input.key = (unsigned)wparam;
            /* THE SAME KEY AS THE ACTIVE LAYOUT SPELLS IT, and whether the
             * layout made text of it. Both are spdf_win_window.h's fields and
             * both are pure Win32 -- deciding what they MEAN is the keymap's,
             * which is the division this file already states for `key`. */
            input.key_char = key_char_for(hwnd, (unsigned)wparam);
            input.text_key = key_is_text(hwnd);
            if (dispatch(window, &input)) return 0;
            /* AN ESCAPE NOBODY WANTED. It used to close the window from here,
             * which macOS never does and which bit anyone who cancelled a search
             * twice (portable/docs/windows-feature-matrix.md, gap 2). Now it
             * leaves full screen when the window is in it -- the one key policy
             * this file holds, argued at spdf_win_window_set_fullscreen() -- and
             * otherwise does nothing at all. Pinned by window_keys_test.c. */
            if (msg == WM_KEYDOWN && wparam == VK_ESCAPE) {
                if (spdf_win_window_escape_leaves_fullscreen(window->fullscreen))
                    dispatch_value(window, SPDF_WIN_INPUT_COMMAND, (unsigned)SPDF_WIN_CMD_FULLSCREEN);
                return 0;
            }
            break;
        }
        case WM_DESTROY:
            window->pressed = SPDF_WIN_CB_NONE;
            if (GetCapture() == hwnd) ReleaseCapture();
            /* The tooltip is OWNED by this window, so Windows destroys it with
             * us; only the handle must stop being followed. */
            window->tooltip = NULL;
            spdf_win_window_prevent_sleep(0);
            /* The last placement, for the session save that runs after the
             * pump returns and the HWND is gone (spdf_win_window_get_frame). */
            if (!window->fullscreen) {
                window->placement.length = sizeof(window->placement);
                if (!GetWindowPlacement(hwnd, &window->placement)) window->placement.length = 0;
            }
            discard_target(window);
            window->hwnd = NULL;
            PostQuitMessage(window->exit_code);
            return 0;
        default:
            /* The app's own messages: see SPDF_WIN_INPUT_APP_MESSAGE. Nothing
             * below WM_APP and nothing in the registered-message range
             * (0xC000 and up) is ours to interpret. */
            if (msg >= WM_APP && msg < 0xC000) {
                dispatch_value(window, SPDF_WIN_INPUT_APP_MESSAGE, (unsigned)msg);
                return 0;
            }
            break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

/* The lifecycle: register_class(), create, show, the timers, the message loop
 * and destroy. LAST, because RegisterClassExW needs window_proc above. */
#include "spdf_win_window_lifecycle.h"
