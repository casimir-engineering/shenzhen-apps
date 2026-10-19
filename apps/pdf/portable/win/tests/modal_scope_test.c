/* modal_scope_test.c -- NO DIALOG MAY LEAVE THE MAIN WINDOW DISABLED.
 *
 * WHY THIS EXISTS. A disabled Win32 window cannot be activated by a click, by
 * Alt+Tab, or by SetForegroundWindow. It still repaints, still answers WM_NULL,
 * and is never marked "not responding" -- so an app whose main window has been
 * left disabled by a dialog that is invisible, off-screen, on another thread or
 * never shown at all looks EXACTLY like the report this file was written for:
 * "the app was never responsive to any user input and not even focusable".
 * Nothing in the suite could see that state, because every existing dialog test
 * passes a NULL owner and so never disables anything.
 *
 * FOUR THINGS ARE CHECKED, in increasing cost:
 *
 *   1. THE PLACEMENT ARITHMETIC, headless. spdf_win_modal_place_point() is pure,
 *      so a dialog centred on an owner near a screen edge, an owner on a second
 *      monitor, and a dialog larger than the work area are all decided here with
 *      no window at all.
 *
 *   2. THE SCOPE, against a real owner window: it disables, it re-enables, a
 *      NESTED scope does not re-enable early, closing twice is harmless, and a
 *      scope opened from a thread that does NOT own the window refuses to
 *      disable it -- the cross-thread disable is the failure mode with no way
 *      out, so the scope declines it rather than performing it.
 *
 *   3. THE REAL PLACEMENT, against a real owner: the dialog rectangle ends up
 *      inside the owner's monitor work area, not at the primary monitor's
 *      cascade position.
 *
 *   4. THE REGRESSION, and the reason for the whole round. File > Print calls
 *      PrintDlgExW on a thread it is allowed to wedge in and watches for a
 *      window to appear; the owner is disabled for that wait. The watchdog used
 *      to treat ANY new visible window of this process as "the dialog is up" and
 *      then stopped its clock FOREVER. But the calling thread keeps pumping
 *      during the wait, and what it dispatches puts windows up -- the updater's
 *      task dialog is on a timer that fires into exactly that pump. One such
 *      window, appearing and closing again while PrintDlgExW never returns, left
 *      the main window disabled with nothing on screen and no way back. This
 *      case creates that window deliberately, from another thread, and asserts
 *      the call still comes back and the owner is enabled afterwards.
 *
 * IT OPENS TWO WINDOWS ON THE DESKTOP FOR A FEW SECONDS, the same deliberate
 * cost properties_dialog_test.c and print_watchdog_test.c already pay. Both are
 * destroyed, and a hard timeout kills the process rather than letting this test
 * become the hang it tests for.
 *
 * ON A LOCKED WORKSTATION no window can be created at all: the test exits 68,
 * which run-tests-native.sh records as BLOCKED rather than as a pass or a fail.
 * Nothing would have been learned about this code either way.
 */
/* spdf-test-sources: portable/win/src/spdf_win_print_dialog_system.cpp */
#include <windows.h>

#include "../src/spdf_win_modal_scope.h"
#include "../src/spdf_win_print_dialog.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define OWNER_CLASS L"SpdfWinModalScopeTestOwner"
#define INTRUDER_CLASS L"SpdfWinModalScopeTestIntruder"

static HWND g_owner;
static volatile LONG g_stop_closing;
static volatile LONG g_intruder_seen;

/* --- 1. the placement arithmetic, with no windows at all ------------------- */

static RECT rect_of(int l, int t, int r, int b) {
    RECT x;
    x.left = l;
    x.top = t;
    x.right = r;
    x.bottom = b;
    return x;
}

static int inside(POINT p, int w, int h, RECT work) {
    return p.x >= work.left && p.y >= work.top && p.x + w <= work.right && p.y + h <= work.bottom;
}

static void test_placement_pure(void) {
    RECT work = rect_of(0, 0, 1920, 1040);
    RECT second = rect_of(1920, -200, 4800, 1600); /* a taller display to the right */
    RECT owner;
    POINT p;

    /* Centred on the owner when there is room. */
    owner = rect_of(400, 200, 1400, 900);
    p = spdf_win_modal_place_point(owner, 1, work, 400, 300);
    CHECK(p.x == 700 && p.y == 400);
    CHECK(inside(p, 400, 300, work));

    /* An owner hard against the right and bottom edges: the dialog is pulled
     * back inside rather than half-drawn off the screen. */
    owner = rect_of(1500, 800, 1920, 1040);
    p = spdf_win_modal_place_point(owner, 1, work, 700, 500);
    CHECK(inside(p, 700, 500, work));
    CHECK(p.x == 1220 && p.y == 540);

    /* An owner against the left and top edges. */
    owner = rect_of(0, 0, 300, 200);
    p = spdf_win_modal_place_point(owner, 1, work, 700, 500);
    CHECK(inside(p, 700, 500, work));
    CHECK(p.x == 0 && p.y == 0);

    /* THE MULTI-MONITOR CASE, which is the one CW_USEDEFAULT gets wrong: an
     * owner on the second display keeps its dialog on the second display. */
    owner = rect_of(2400, 300, 3400, 1000);
    p = spdf_win_modal_place_point(owner, 1, second, 500, 400);
    CHECK(inside(p, 500, 400, second));
    CHECK(p.x >= 1920);

    /* A dialog LARGER than the work area is pinned to the top-left, where the
     * title bar and the first controls are, not to the bottom-right. */
    owner = rect_of(400, 200, 1400, 900);
    p = spdf_win_modal_place_point(owner, 1, work, 3000, 2000);
    CHECK(p.x == work.left && p.y == work.top);

    /* No owner: centred on the work area. */
    p = spdf_win_modal_place_point(rect_of(0, 0, 0, 0), 0, work, 400, 300);
    CHECK(p.x == 760 && p.y == 370);
    CHECK(inside(p, 400, 300, work));
}

/* --- the windows ---------------------------------------------------------- */

static LRESULT CALLBACK plain_proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcW(h, m, w, l); }

static int register_plain(const wchar_t* name) {
    WNDCLASSEXW cls;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = plain_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); /* IDC_ARROW */
    cls.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    cls.lpszClassName = name;
    return RegisterClassExW(&cls) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

/* --- 2. the scope, against a real owner ----------------------------------- */

/* A scope opened on a thread that does not own the window: it must NOT disable
 * it. A main window disabled from a foreign thread is the state with no way
 * out; a dialog that is merely not modal is one you can click your way past. */
static DWORD WINAPI foreign_scope(LPVOID unused) {
    SpdfWinModalScope s;
    (void)unused;
    spdf_win_modal_scope_begin(&s, g_owner);
    CHECK(s.wrong_thread == 1);
    CHECK(s.disabled == 0);
    CHECK(IsWindowEnabled(g_owner));
    spdf_win_modal_scope_end(&s);
    CHECK(IsWindowEnabled(g_owner));
    return 0;
}

static void test_scope(void) {
    SpdfWinModalScope outer;
    SpdfWinModalScope inner;
    HANDLE t;

    CHECK(IsWindowEnabled(g_owner));

    spdf_win_modal_scope_begin(&outer, g_owner);
    CHECK(outer.disabled == 1);
    CHECK(outer.wrong_thread == 0);
    CHECK(!IsWindowEnabled(g_owner));

    /* NESTED. The inner scope finds the owner already disabled, records that it
     * did not do it, and leaves it disabled on the way out -- otherwise a
     * message box opened from inside a dialog would un-modal the dialog. */
    spdf_win_modal_scope_begin(&inner, g_owner);
    CHECK(inner.disabled == 0);
    spdf_win_modal_scope_end(&inner);
    CHECK(!IsWindowEnabled(g_owner));

    spdf_win_modal_scope_end(&outer);
    CHECK(IsWindowEnabled(g_owner));
    /* Closing twice is a no-op, which is what makes an early close plus a
     * destructor safe. */
    spdf_win_modal_scope_end(&outer);
    CHECK(IsWindowEnabled(g_owner));

    /* A NULL owner is a scope that does nothing and still closes cleanly. */
    spdf_win_modal_scope_begin(&outer, NULL);
    CHECK(outer.disabled == 0);
    spdf_win_modal_scope_end(&outer);

    t = CreateThread(NULL, 0, foreign_scope, NULL, 0, NULL);
    if (t) {
        WaitForSingleObject(t, 5000);
        CloseHandle(t);
    }
    CHECK(IsWindowEnabled(g_owner));
}

/* --- 3. the real placement ------------------------------------------------ */

static void test_placement_real(void) {
    HWND dialog;
    RECT d;
    MONITORINFO mi;
    HMONITOR mon;

    dialog = CreateWindowExW(WS_EX_DLGMODALFRAME, INTRUDER_CLASS, L"modal placement",
                             WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, 520, 380, g_owner,
                             NULL, GetModuleHandleW(NULL), NULL);
    CHECK(dialog != NULL);
    if (!dialog) return;
    spdf_win_modal_place_on_owner(dialog, g_owner);
    mon = MonitorFromWindow(g_owner, MONITOR_DEFAULTTONEAREST);
    memset(&mi, 0, sizeof(mi));
    mi.cbSize = sizeof(mi);
    if (mon && GetMonitorInfoW(mon, &mi) && GetWindowRect(dialog, &d)) {
        printf("modal_scope: placed at %ld,%ld %ldx%ld in work area %ld,%ld..%ld,%ld\n", d.left, d.top,
               d.right - d.left, d.bottom - d.top, mi.rcWork.left, mi.rcWork.top, mi.rcWork.right, mi.rcWork.bottom);
        CHECK(d.left >= mi.rcWork.left && d.top >= mi.rcWork.top);
        CHECK(d.right <= mi.rcWork.right && d.bottom <= mi.rcWork.bottom);
    }
    DestroyWindow(dialog);
}

/* --- 4. the print watchdog, with a window of our own in the way ------------ */

/* The intruder: a visible top-level window of this process, on a thread that is
 * not the one waiting, which appears and then goes away again while the print
 * dialog has not returned. It stands in for the updater's task dialog. */
static DWORD WINAPI intruder(LPVOID unused) {
    HWND win;
    MSG msg;
    ULONGLONG until;
    (void)unused;

    Sleep(800);
    win = CreateWindowExW(WS_EX_TOOLWINDOW, INTRUDER_CLASS, L"modal scope intruder",
                          WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VISIBLE, 80, 80, 360, 160, NULL, NULL,
                          GetModuleHandleW(NULL), NULL);
    if (!win) return 0;
    InterlockedExchange(&g_intruder_seen, 1);
    until = GetTickCount64() + 1500;
    while (GetTickCount64() < until) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(20);
    }
    DestroyWindow(win);
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

/* On a host where Windows' print dialog WORKS, something has to dismiss it.
 * Everything of ours is left alone. */
static BOOL CALLBACK close_stray(HWND hwnd, LPARAM param) {
    wchar_t cls[64];
    DWORD pid = 0;
    int* closed = (int*)param;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || hwnd == g_owner || !IsWindowVisible(hwnd)) return TRUE;
    if (GetClassNameW(hwnd, cls, 64) > 0 && (wcscmp(cls, INTRUDER_CLASS) == 0 || wcscmp(cls, OWNER_CLASS) == 0))
        return TRUE;
    PostMessageW(hwnd, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
    *closed += 1;
    return TRUE;
}

static DWORD WINAPI closer(LPVOID unused) {
    int closed = 0;
    (void)unused;
    while (!InterlockedCompareExchange(&g_stop_closing, 0, 0)) {
        Sleep(250);
        EnumWindows(close_stray, (LPARAM)&closed);
    }
    if (closed) printf("modal_scope: closed %d dialog window(s) that appeared\n", closed);
    return 0;
}

/* The hard stop. Before the fix the call below never returned and the owner
 * stayed disabled, so a bare assertion would have hung the suite instead of
 * failing it. */
static DWORD WINAPI hard_stop(LPVOID unused) {
    (void)unused;
    Sleep(45000);
    printf("FAIL spdf_win_print_system_dialog did not return within 45 s -- the owner is still disabled\n");
    fflush(stdout);
    TerminateProcess(GetCurrentProcess(), 1);
    return 0;
}

static void test_print_watchdog_with_intruder(void) {
    spdf_win_print_choice preset;
    spdf_win_print_system_result result;
    char err[512] = "";
    HANDLE t_intruder;
    HANDLE t_closer;
    ULONGLONG began;
    ULONGLONG elapsed;
    spdf_win_print_status status;

    preset.mode = SPDF_WIN_PRINT_SCALING_FIT;
    preset.custom_scale = 1.0;
    memset(&result, 0, sizeof(result));

    t_intruder = CreateThread(NULL, 0, intruder, NULL, 0, NULL);
    t_closer = CreateThread(NULL, 0, closer, NULL, 0, NULL);

    began = GetTickCount64();
    status = spdf_win_print_system_dialog(g_owner, 4, &preset, &result, err, sizeof(err));
    elapsed = GetTickCount64() - began;
    printf("modal_scope: print dialog returned %d after %llu ms, err=\"%s\"\n", (int)status,
           (unsigned long long)elapsed, err);

    /* The claim, and the only one that transfers to a machine nobody here has:
     * it came back, and the owner can be used again. */
    CHECK(elapsed < 40000);
    CHECK(IsWindowEnabled(g_owner));
    CHECK(InterlockedCompareExchange(&g_intruder_seen, 0, 0) == 1);
    if (status == SPDF_WIN_PRINT_OK) {
        free(result.pages);
        if (result.dc) DeleteDC(result.dc);
    }

    InterlockedExchange(&g_stop_closing, 1);
    if (t_intruder) {
        WaitForSingleObject(t_intruder, 10000);
        CloseHandle(t_intruder);
    }
    if (t_closer) {
        WaitForSingleObject(t_closer, 5000);
        CloseHandle(t_closer);
    }
}

/* --- the quit a nested loop must not eat --------------------------------- */
static void test_requeue_quit_body(void);


/* spdf_win_modal_requeue_quit's whole job, checked on this thread's own queue.
 * Headless: it needs no window, because the message it forwards is a THREAD
 * message. Each case drains first, so one case cannot pass on the leftovers of
 * another. */
static int quit_in_queue(int* code) {
    MSG msg;
    if (!PeekMessageW(&msg, NULL, WM_QUIT, WM_QUIT, PM_REMOVE)) return 0;
    if (code) *code = (int)msg.wParam;
    return 1;
}

static void drain_queue(void) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) continue;
    }
}

/* ON ITS OWN THREAD, and that is not fastidiousness. WM_QUIT is a THREAD
 * message and PostQuitMessage sets a flag on the thread that posted it, so
 * exercising it on the thread that later runs test_print_watchdog_with_intruder
 * leaves that flag where the watchdog's own pump can find it: measured, the
 * watchdog case then failed with "did not return within 45 s -- the owner is
 * still disabled", which is the very defect it exists to catch. A test may not
 * hand the next test a queue it did not expect. */
static DWORD WINAPI requeue_quit_thread(LPVOID unused) {
    (void)unused;
    test_requeue_quit_body();
    return 0;
}

static void test_requeue_quit(void) {
    HANDLE t = CreateThread(NULL, 0, requeue_quit_thread, NULL, 0, NULL);
    if (!t) {
        printf("BLOCKED modal-scope: could not create the requeue thread, GetLastError=%lu\n",
               (unsigned long)GetLastError());
        return;
    }
    WaitForSingleObject(t, 30000);
    CloseHandle(t);
}

static void test_requeue_quit_body(void) {
    MSG msg;
    int code;

    /* GetMessageW answered 0, so a WM_QUIT was consumed and its exit code must
     * come back out. The exit code travels: an app told to quit with 3 must not
     * quit with 0. */
    drain_queue();
    memset(&msg, 0, sizeof(msg));
    msg.message = WM_QUIT;
    msg.wParam = 3;
    spdf_win_modal_requeue_quit(0, &msg);
    code = -1;
    CHECK(quit_in_queue(&code) == 1);
    CHECK(code == 3);

    /* The ordinary way out: the loop ended because the dialog finished, and
     * GetMessageW's last answer was a real message. Nothing may be posted --
     * inventing a WM_QUIT here would close the app every time a dialog closed,
     * which is the opposite failure and a far worse one. */
    drain_queue();
    memset(&msg, 0, sizeof(msg));
    msg.message = WM_KEYDOWN;
    spdf_win_modal_requeue_quit(1, &msg);
    CHECK(quit_in_queue(NULL) == 0);

    /* -1 is GetMessageW's error return, not a quit. */
    drain_queue();
    memset(&msg, 0, sizeof(msg));
    spdf_win_modal_requeue_quit(-1, &msg);
    CHECK(quit_in_queue(NULL) == 0);

    /* A NULL msg with got == 0 still has to forward SOMETHING: the quit was
     * real even if the caller kept no copy of it. */
    drain_queue();
    spdf_win_modal_requeue_quit(0, NULL);
    code = -1;
    CHECK(quit_in_queue(&code) == 1);
    CHECK(code == 0);
    drain_queue();
}

int main(void) {
    HANDLE stop;
    int code;

    test_placement_pure();

    if (!register_plain(OWNER_CLASS) || !register_plain(INTRUDER_CLASS)) {
        printf("BLOCKED modal-scope: window classes could not be registered, GetLastError=%lu\n",
               (unsigned long)GetLastError());
        return 68;
    }
    g_owner = CreateWindowExW(0, OWNER_CLASS, L"modal scope test owner", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 60, 60, 640,
                              360, NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!g_owner) {
        /* No window station: a locked session or a service context. */
        printf("BLOCKED modal-scope: no owner window could be created, GetLastError=%lu\n",
               (unsigned long)GetLastError());
        printf("modal_scope_test: %d checks, %d failures (placement only)\n", g_checks, g_failures);
        return g_failures ? 1 : 68;
    }

    stop = CreateThread(NULL, 0, hard_stop, NULL, 0, NULL);
    test_requeue_quit();
    test_scope();
    test_placement_real();
    test_print_watchdog_with_intruder();
    if (stop) CloseHandle(stop); /* left to expire; the process exits first */

    DestroyWindow(g_owner);
    printf("modal_scope_test: %d checks, %d failures\n", g_checks, g_failures);
    code = g_failures ? 1 : 0;
    fflush(stdout);
    /* print_watchdog_test.c's rule, for the same reason: on this host a thread
     * of this process is still inside comdlg32 and never will not be, and
     * returning through the CRT's exit with a thread stuck in a system call is
     * the one way this test could become the hang it is testing for. */
    TerminateProcess(GetCurrentProcess(), (UINT)code);
    return code;
}
