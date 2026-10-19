#pragma once

/* The window's LIFECYCLE -- register the class, create it, show it, tick it,
 * run the message loop, destroy it -- for spdf_win_window.cpp only.
 *
 * Same arrangement as spdf_win_window_target.h, _input.h, _caption.h, _frame.h
 * and _tooltip.h beside it: header-only, included from exactly one translation
 * unit, and not part of the port's public surface. It sits at the BOTTOM of
 * that file rather than beside the others because it depends on window_proc()
 * -- RegisterClassExW needs the procedure, and the procedure needs every
 * handler above it.
 *
 * It moved out when the deferred-launch one-shot (spdf_win_window_set_once)
 * took spdf_win_window.cpp past the 500-line cap; tools/file-size-limits.md
 * asks for an extracted file rather than a raised one, and this is the seam
 * that was already implicit in the file -- everything above is what a window
 * DOES with a message, and everything here is how one comes to exist and stop
 * existing.
 *
 * THE THREE TIMERS ARE ALL SET HERE (the ids are next to `struct
 * spdf_win_window`): the periodic tick, the one-shot, and the tooltip's delay,
 * which spdf_win_window_tooltip.h arms. WM_TIMER routes all three in
 * window_proc.
 */

static int register_class(HINSTANCE instance) {
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    /* Redraw the whole client area on any size change: the page is centred, so
     * a horizontal resize moves pixels that a partial invalidation would
     * leave stale. */
    /* CS_DBLCLKS: without it Windows never sends WM_LBUTTONDBLCLK and there is
     * no way to know a click was a double at all -- double-click-to-select-a-
     * word is not implementable without it, and adding it later silently changes
     * which message every second click arrives as. */
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
    wc.lpfnWndProc = window_proc;
    wc.hInstance = instance;
    /* MAKEINTRESOURCEW, not IDC_ARROW: guest-build.cmd does not define
     * UNICODE, so IDC_ARROW expands to the ANSI MAKEINTRESOURCEA and will not
     * convert to LoadCursorW's LPCWSTR. Same trap as the *A/*W entry points,
     * one level down in the macros. */
    wc.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512 /* IDC_ARROW */));
    wc.hbrBackground = NULL; /* see WM_ERASEBKGND */
    wc.lpszClassName = kWindowClass;

    if (RegisterClassExW(&wc)) return 1;
    return GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

/* Here rather than beside the HWND accessors because kWindowClass is the string
 * register_class() above hands RegisterClassExW: one definition, so the name a
 * caller compares against is by construction the name the class has. */
const wchar_t* spdf_win_window_class_name(void) { return kWindowClass; }

spdf_win_window* spdf_win_window_create(spdf_win_d2d* d2d, const wchar_t* title, int client_px_w, int client_px_h,
                                        spdf_win_scene_fn scene_fn, spdf_win_input_fn input_fn, void* user, char* err,
                                        size_t err_len) {
    if (err && err_len) err[0] = '\0';
    if (!d2d) return NULL;

    HINSTANCE instance = GetModuleHandleW(NULL);
    if (!register_class(instance)) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "RegisterClassExW failed (%lu)", GetLastError());
        return NULL;
    }

    spdf_win_window* window = (spdf_win_window*)calloc(1, sizeof(*window));
    if (!window) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "out of memory");
        return NULL;
    }
    window->d2d = d2d;
    window->scene_fn = scene_fn;
    window->input_fn = input_fn;
    window->user = user;
    window->dpi = USER_DEFAULT_SCREEN_DPI;

    if (client_px_w < 200) client_px_w = 200;
    if (client_px_h < 200) client_px_h = 200;
    RECT rc = {0, 0, client_px_w, client_px_h};
    AdjustWindowRectEx(&rc, WS_OVERLAPPEDWINDOW, FALSE, 0);

    window->hwnd = CreateWindowExW(0, kWindowClass, title ? title : L"ShenzhenPDF", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                                   CW_USEDEFAULT, rc.right - rc.left, rc.bottom - rc.top, NULL, NULL, instance,
                                   window);
    if (!window->hwnd) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "CreateWindowExW failed (%lu)", GetLastError());
        free(window);
        return NULL;
    }

    /* Now that there is an HWND we can ask which monitor it landed on. The
     * frame was sized in 96-dpi units, so on a 2x display resize it once
     * rather than leaving a half-size window. */
    spdf_win_launch_mark("hwnd-created");
    window->dpi = window_dpi(window->hwnd);
    window->client_px_w = client_px_w;
    window->client_px_h = client_px_h;
    resize_to_client(window);
    /* The strip is the title bar: hand DWM the caption region so it keeps
     * drawing the shadow, the rounded corners and the frame around a window
     * whose caption is now client area (spdf_win_window_caption.h). */
    extend_frame_into_strip(window);
    /* THE DROP TARGET. One call, and the only reason it is not in
     * register_class() is that it is a property of the window rather than of the
     * class. WM_DROPFILES is the old shell drop protocol rather than
     * IDropTarget: it delivers exactly what this app wants (a list of paths) and
     * costs no COM, no reference counting and no second object to keep alive. */
    DragAcceptFiles(window->hwnd, TRUE);
    return window;
}

void spdf_win_window_show(spdf_win_window* window) { spdf_win_window_show_ex(window, 1); }

/* The frontmost visible window of this class on the desktop that is not
 * `self`, whichever process owns it, or NULL. GetTopWindow walks the z-order
 * from the top; the class name is the one register_class() gave every window
 * of every ShenzhenPDF process, so a sibling can find the window it is meant
 * to stay behind without an id, a pipe or a shared handle. */
static HWND frontmost_other_app_window(HWND self) {
    HWND h;
    wchar_t cls[64];
    for (h = GetTopWindow(NULL); h; h = GetWindow(h, GW_HWNDNEXT)) {
        if (h == self || !IsWindowVisible(h)) continue;
        if (GetClassNameW(h, cls, (int)(sizeof(cls) / sizeof(cls[0]))) && wcscmp(cls, kWindowClass) == 0) return h;
    }
    return NULL;
}

void spdf_win_window_show_ex(spdf_win_window* window, int claim_foreground) {
    if (!window || !window->hwnd) return;
    /* THE FIRST FRAME IS PAINTED BEFORE THE WINDOW IS SHOWN.
     *
     * Measured (portable/docs/windows-launch-performance.md): ShowWindow puts
     * the frame on screen ~40 ms after process creation and the client area
     * then stays BLANK until the first WM_PAINT completes -- 130-230 ms later
     * on the baseline. A window that appears empty and fills in later reads as
     * "loading"; one that appears complete reads as instant even when it
     * appears a little later. So the target is created and the first frame
     * presented while the window is still hidden -- the swap chain keeps it --
     * and ShowWindow reveals a window that already has its page. UpdateWindow
     * then repaints from warm caches (page bitmap and texture are both cached),
     * which costs a few milliseconds and guarantees the shown surface is
     * current even if the hidden present was discarded. */
    paint(window);
    spdf_win_launch_mark("pre-show-paint-done");
    if (claim_foreground) {
        ShowWindow(window->hwnd, SW_SHOWNORMAL);
    } else {
        /* A SIBLING SHOWS BEHIND THE WINDOW THAT IS MEANT TO BE IN FRONT -- AND
         * "NOT ACTIVATED" IS NOT "BEHIND".
         *
         * SW_SHOWNOACTIVATE withholds activation and nothing else: a window
         * shown that way keeps the z-position CreateWindowExW gave it, which
         * is the TOP. Measured (windows-native-observations.md, section 16):
         * a --behind sibling whose window was created after the focused
         * window had claimed the foreground came up at z-index 0, over that
         * window and at its exact frame, while the focused window kept the
         * activation and the keyboard underneath it. Every keystroke went to
         * a window nobody could see; the one they could see was not active.
         * Which window's launch finishes first is a race the documents
         * decide -- the sibling's short document against the focused
         * window's long one -- so the sibling has to place itself.
         *
         * SetWindowPos with an insert-after handle does the show and the
         * placement in one step: directly beneath the frontmost window of
         * this class already on the desktop, whichever process owns it. When
         * there is none yet (this sibling won the race) it is shown where it
         * is, on top and inactive, and the focused window's own
         * BringWindowToTop below passes it a moment later. */
        HWND front = frontmost_other_app_window(window->hwnd);
        if (front)
            SetWindowPos(window->hwnd, front, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
        else
            ShowWindow(window->hwnd, SW_SHOWNOACTIVATE);
    }
    spdf_win_launch_mark("show-window-returned");
    UpdateWindow(window->hwnd);
    spdf_win_launch_mark("update-window-returned");
    if (!claim_foreground) return;

    /* AND THEN ASK FOR THE FOREGROUND, WHICH ShowWindow DOES NOT.
     *
     * ShowWindow maps the window; it does not decide who is in front.
     * Ordinarily that does not matter, because Windows hands a newly launched
     * process the right to take the foreground and the first window it shows
     * takes it. But that grant is not open-ended: it lapses when the launching
     * application's input goes elsewhere, and this app now does real work --
     * open the document, build the scene, render and present the first frame,
     * about 145 ms of it -- BEFORE it shows anything, precisely so the window
     * appears complete rather than blank. By the time ShowWindow runs, the
     * window that launched us can easily have the foreground back, and the app
     * then appears BEHIND it, unfocused, with only a sliver visible. Reported
     * as "I can't interact with it at all, not even focus it with alt tab" --
     * from a maximized window, that sliver is all there is to click.
     *
     * So the window asks, the way any application does after showing its main
     * window. SetForegroundWindow may still refuse -- the foreground lock is
     * the system's to enforce and another app may legitimately own it -- and
     * refusing is not an error worth reporting: FlashWindowEx then does what
     * Windows itself does in that case and marks the taskbar button, so the
     * reader can see where the window went. BringWindowToTop covers the case
     * where activation is granted without a raise (a foreground window sitting
     * below another in the z-order is a state this has actually been observed
     * in), and SetFocus puts the caret in the window rather than nowhere. */
    SetForegroundWindow(window->hwnd);
    BringWindowToTop(window->hwnd);
    SetFocus(window->hwnd);
    if (GetForegroundWindow() != window->hwnd) {
        FLASHWINFO flash;
        flash.cbSize = sizeof(flash);
        flash.hwnd = window->hwnd;
        flash.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
        flash.uCount = 3;
        flash.dwTimeout = 0;
        FlashWindowEx(&flash);
    }
}

void spdf_win_window_invalidate(spdf_win_window* window) {
    if (window && window->hwnd) InvalidateRect(window->hwnd, NULL, FALSE);
}

void spdf_win_window_set_tick(spdf_win_window* window, unsigned ms, spdf_win_tick_fn fn) {
    if (!window || !window->hwnd) return;
    window->tick_fn = ms ? fn : NULL;
    if (ms && fn) SetTimer(window->hwnd, SPDF_WIN_TIMER_TICK, ms, NULL);
    else KillTimer(window->hwnd, SPDF_WIN_TIMER_TICK);
}

void spdf_win_window_set_once(spdf_win_window* window, unsigned ms, spdf_win_tick_fn fn) {
    if (!window || !window->hwnd) return;
    window->once_fn = ms ? fn : NULL;
    if (ms && fn) SetTimer(window->hwnd, SPDF_WIN_TIMER_ONCE, ms, NULL);
    else KillTimer(window->hwnd, SPDF_WIN_TIMER_ONCE);
}

int spdf_win_window_run(spdf_win_window* window) {
    MSG msg;
    if (!window) return 1;
    for (;;) {
        BOOL got;
        /* THE PUMP'S HEARTBEAT, in two halves, and the halves are the point.
         * A thread parked in GetMessageW is IDLE, not stuck, and could sit
         * there for an hour; a thread that has not come back from
         * DispatchMessageW for three seconds is stuck. So the loop says which
         * of the two it is entering, and the watchdog thread in
         * spdf_win_health_log.h only reports a stall against the second. This
         * is the one instrument that can see a blocked UI thread at all: a
         * timer on THIS thread proves the thread runs by firing. Two aligned
         * stores and one GetTickCount64 (a read of KUSER_SHARED_DATA, no
         * syscall) per message. */
        spdf_win_health_pump_wait();
        got = GetMessageW(&msg, NULL, 0, 0);
        spdf_win_health_pump_run();
        /* GetMessageW's third state is -1, and it leaves msg untouched. Reading
         * msg.wParam then would hand the shell a garbage exit code, which is
         * exactly the signal every headless check in this port relies on. */
        if (got == -1) return 73;
        if (got == 0) return (int)msg.wParam;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

void spdf_win_window_destroy(spdf_win_window* window) {
    if (!window) return;
    discard_target(window);
    if (window->hwnd) {
        HWND hwnd = window->hwnd;
        window->hwnd = NULL;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        DestroyWindow(hwnd);
    }
    free(window);
}
