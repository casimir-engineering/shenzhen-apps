/* spdf_win_health.h — WHAT STATE IS THIS WINDOW ACTUALLY IN, written down by
 * the app itself.
 *
 * WHY IT EXISTS. "The app was never responsive to any user input and not even
 * focusable", launched from dist\ShenzhenPDF-win-x64.exe. Nobody has been able
 * to reproduce it: launched again from a shell or from Explorer on the same
 * machine the window comes up foreground, enabled, not hung, answering WM_NULL,
 * and repainting under SendInput. Windows Error Reporting recorded no hang.
 * Every instrument this port has -- the headless compose, the PrintWindow
 * sampler, measure-launch.ps1's external health block -- can only measure a
 * launch someone is standing over. The one witness that is present EVERY time
 * is the process itself, and until this header it wrote nothing down.
 *
 * So it writes. Three lines per windowed launch (1 s, 5 s and 30 s after the
 * window is shown) into <state dir>\launch-health.log, plus a `stall` line from
 * a watchdog thread whenever the UI thread's heartbeat goes stale -- or a
 * `modal` line when a dialog of ours is what is holding the pump, which is not
 * a stall -- see spdf_win_health_log.h for the timers, the file and the
 * watchdog, and spdf_win_health_is_modal() below for the test. This header
 * is the MEASUREMENT half: the counters the window proc bumps, the heartbeat the
 * message loop stamps, and the one function that turns all of it plus a live
 * HWND into one greppable line.
 *
 * THE LINE IS MEASURED FROM TWO SIDES, and the split matters. Everything from
 * `fg=` onwards is asked of user32 about an HWND and needs no cooperation from
 * the thread that owns it -- GetForegroundWindow, IsWindowEnabled,
 * IsWindowVisible, IsIconic, GetWindowRect, MonitorFromWindow, the z-order walk
 * and IsHungAppWindow are all answered from the desktop's own state. NOTHING
 * HERE MAY SEND A MESSAGE (no GetWindowTextW, no SendMessage, no
 * GetWindowInfo-by-proxy): the watchdog calls this function precisely when the
 * UI thread has stopped pumping, and a send would then block the one thread
 * that is still able to report. The counters and the heartbeat are the other
 * side: they are in-process facts, and a --diagnose looking at ANOTHER process's
 * window prints `-` for them rather than guessing.
 *
 * ZERO COST WHEN NOTHING IS WRONG. The window proc's call is one switch and one
 * InterlockedIncrement on the messages that count and an immediate return on
 * every other; the message loop's heartbeat is one GetTickCount64 (a read of
 * KUSER_SHARED_DATA, no syscall) and one aligned 64-bit store. Nothing is
 * allocated and nothing is formatted until a line is due.
 *
 * HEADER-ONLY, ONE SHARED STATE, MANY TRANSLATION UNITS -- the same arrangement
 * spdf_win_launch_profile.h uses next door, and for the same reason: the
 * counters are bumped in spdf_win_window.cpp, the line is written from
 * spdf_win_launch_window.h and read again by --diagnose in spdf_win_main.cpp,
 * and none of those should have to route through a new .cpp and a new export.
 * MSVC only, like everything under portable/win/src.
 */
#ifndef SPDF_WIN_HEALTH_H
#define SPDF_WIN_HEALTH_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <stdio.h>
#include <string.h>

#include "spdf_win_about_version.h" /* SPDF_WIN_RELEASE_TAG: which build wrote the line */

#ifdef __cplusplus
extern "C" {
#endif

/* Every counter the window proc keeps, plus the two timestamps. All ticks are
 * GetTickCount64()'s, which is monotonic, needs no syscall and survives a UI
 * thread that has stopped running -- the case this whole header is about. */
typedef struct spdf_win_health_state {
    volatile long lbuttondown;
    volatile long keydown;
    volatile long chars;
    volatile long mousemove;
    volatile long wheel;
    volatile long activate;
    volatile long setfocus;
    volatile long killfocus;
    volatile long paints;
    /* When the last input message of any kind arrived, and when the message
     * loop last went round. A 64-bit aligned load/store is atomic on x64, so
     * these are plain reads and writes rather than interlocked ones: the
     * watchdog wants "roughly when", not a serialisation point. */
    volatile LONG64 last_input_tick;
    volatile LONG64 heartbeat_tick;
    /* THE PUMP IS PARKED IN GetMessageW, which is health, not a stall: an idle
     * app waits there indefinitely and must not be reported as wedged. Only a
     * heartbeat that is stale while this is 0 -- the loop went into a handler
     * and has not come back -- is a stall. */
    volatile long idle;
    /* Set once by spdf_win_health_log_start(), so a heartbeat exists before the
     * pump has turned even once and a launch that wedges BEFORE the loop starts
     * is still reported. */
    volatile LONG64 shown_tick;
} spdf_win_health_state;

/* One instance per process, however many TUs include this header. */
__declspec(selectany) spdf_win_health_state spdf_win_health = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};

/* --- what the window proc and the message loop call ---------------------- */

/* One message, counted. Called from window_proc before anything else looks at
 * the message, so a handler that returns early still counts. Everything not in
 * the switch costs one compare. */
static void spdf_win_health_note_message(UINT msg) {
    spdf_win_health_state* h = &spdf_win_health;
    switch (msg) {
        case WM_LBUTTONDOWN:
        case WM_LBUTTONDBLCLK:
            InterlockedIncrement(&h->lbuttondown);
            break;
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN:
            InterlockedIncrement(&h->keydown);
            break;
        case WM_CHAR:
            InterlockedIncrement(&h->chars);
            break;
        case WM_MOUSEMOVE:
            InterlockedIncrement(&h->mousemove);
            break;
        case WM_MOUSEWHEEL:
        case WM_MOUSEHWHEEL:
            InterlockedIncrement(&h->wheel);
            break;
        case WM_ACTIVATE:
            InterlockedIncrement(&h->activate);
            break;
        case WM_SETFOCUS:
            InterlockedIncrement(&h->setfocus);
            break;
        case WM_KILLFOCUS:
            InterlockedIncrement(&h->killfocus);
            break;
        default:
            return;
    }
    h->last_input_tick = (LONG64)GetTickCount64();
}

/* A WM_PAINT that RETURNED -- called after EndPaint, so the count is frames
 * completed rather than frames asked for. The difference is the whole question
 * when a window is painting nothing. */
static void spdf_win_health_note_paint(void) { InterlockedIncrement(&spdf_win_health.paints); }

/* THE UI THREAD IS ALIVE, in two halves, from spdf_win_window_run's loop. A
 * timer that fires on the UI thread proves the thread is running BY FIRING, so
 * it can never report the one state that matters here; this stamp is what lets
 * a thread that is NOT the UI thread notice the pump has stopped -- and the
 * `idle` half is what keeps an app that is merely waiting for a message from
 * being reported as wedged.
 *
 * _wait: about to park in GetMessageW. _run: back, and about to dispatch.
 * _heartbeat: neither, for the one caller (the log's start) that just wants a
 * timestamp before the loop has run at all. */
static void spdf_win_health_pump_wait(void) {
    spdf_win_health.heartbeat_tick = (LONG64)GetTickCount64();
    spdf_win_health.idle = 1;
}

static void spdf_win_health_pump_run(void) {
    spdf_win_health.idle = 0;
    spdf_win_health.heartbeat_tick = (LONG64)GetTickCount64();
}

static void spdf_win_health_heartbeat(void) { spdf_win_health.heartbeat_tick = (LONG64)GetTickCount64(); }

/* --- clocks -------------------------------------------------------------- */

/* Milliseconds from PROCESS CREATION -- the kernel's timestamp, so this shares
 * an origin with spdf_win_launch_profile.h's timeline and with any stopwatch a
 * harness started before CreateProcess. */
static double spdf_win_health_ms_since_launch(void) {
    FILETIME created, exited, kernel, user, now;
    unsigned long long c, w;
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return 0.0;
    GetSystemTimePreciseAsFileTime(&now);
    c = ((unsigned long long)created.dwHighDateTime << 32) | created.dwLowDateTime;
    w = ((unsigned long long)now.dwHighDateTime << 32) | now.dwLowDateTime;
    return w > c ? (double)(w - c) / 10000.0 : 0.0;
}

/* UTC, to the millisecond, sortable and unambiguous. A local time would be
 * ambiguous twice a year in exactly the log a reader consults about a one-off. */
static void spdf_win_health_iso_now(char* out, size_t n) {
    SYSTEMTIME t;
    GetSystemTime(&t);
    _snprintf_s(out, n, _TRUNCATE, "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ", t.wYear, t.wMonth, t.wDay, t.wHour,
                t.wMinute, t.wSecond, t.wMilliseconds);
}

/* --- what the desktop knows about an HWND -------------------------------- */

/* Position among visible top-level windows larger than 200 px -- the same band
 * the shell's Alt+Tab list draws from, and the same walk measure-launch.ps1's
 * ZIndex does, so the two numbers are comparable. 0 = in front, -1 = not in the
 * walk at all (hidden, or too small). */
static int spdf_win_health_zindex(HWND target) {
    HWND h = GetTopWindow(NULL);
    int i = 0;
    while (h) {
        if (IsWindowVisible(h)) {
            RECT r;
            if (GetWindowRect(h, &r) && (r.right - r.left) > 200 && (r.bottom - r.top) > 200) {
                if (h == target) return i;
                ++i;
            }
        }
        h = GetWindow(h, GW_HWNDNEXT);
    }
    return -1;
}

/* The per-process walk, done once: how many top-level windows this process has,
 * how many of them IsHungAppWindow reports (true of an INVISIBLE window just the
 * same -- that is how the prewarm defect of section 11 hid), and whether any
 * window owned by `target` is up. A modal dialog disables its owner and enables
 * itself, which is exactly "the app does not respond to input" as a reader
 * experiences it, so the two facts are collected together. */
typedef struct spdf_win_health_windows {
    HWND target;
    DWORD pid;
    int count;
    int hung;
    int owned;        /* visible windows owned by target */
    int owned_enabled; /* ... that are enabled */
} spdf_win_health_windows;

static BOOL CALLBACK spdf_win_health_enum(HWND h, LPARAM param) {
    spdf_win_health_windows* w = (spdf_win_health_windows*)param;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != w->pid) return TRUE;
    ++w->count;
    if (IsHungAppWindow(h)) ++w->hung;
    if (h != w->target && GetWindow(h, GW_OWNER) == w->target && IsWindowVisible(h)) {
        ++w->owned;
        if (IsWindowEnabled(h)) ++w->owned_enabled;
    }
    return TRUE;
}

/* IS A MODAL DIALOG UP OVER `hwnd`? Disabled, with an enabled visible window of
 * ours owned by it. Asked of the desktop only -- no message is sent -- so the
 * watchdog may call it while the UI thread is not pumping, which is exactly when
 * it needs to know: a nested modal loop (a TaskDialog, a password prompt, the
 * shell's Open dialog) does not turn OUR pump, so the heartbeat goes stale and
 * looks like a wedged thread. It is not one, and the log must not say it is --
 * see spdf_win_health_log.h's watchdog. Same computation as the `modal=` field
 * of the line below, factored out so the two cannot disagree. */
static int spdf_win_health_is_modal(HWND hwnd) {
    spdf_win_health_windows walk;
    DWORD pid = 0;
    if (!hwnd || IsWindowEnabled(hwnd)) return 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (!pid) return 0;
    memset(&walk, 0, sizeof(walk));
    walk.target = hwnd;
    walk.pid = pid;
    EnumWindows(spdf_win_health_enum, (LPARAM)&walk);
    return walk.owned_enabled > 0;
}

/* Does the window rect overlap any monitor's WORK area? A window whose frame
 * sits entirely off every desktop is visible, enabled, not hung and completely
 * unreachable, which is one of the shapes the report could have. */
typedef struct spdf_win_health_onscreen {
    RECT rect;
    int hit;
} spdf_win_health_onscreen;

static BOOL CALLBACK spdf_win_health_monitor_enum(HMONITOR mon, HDC dc, LPRECT r, LPARAM param) {
    spdf_win_health_onscreen* o = (spdf_win_health_onscreen*)param;
    MONITORINFO mi;
    RECT hit;
    (void)dc;
    (void)r;
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(mon, &mi) && IntersectRect(&hit, &o->rect, &mi.rcWork)) o->hit = 1;
    return TRUE;
}

/* --- the line ------------------------------------------------------------ */

/* ONE LINE, `key=value` throughout so `findstr` and `grep` both work on it, and
 * so a field added later cannot shift a field a reader already knows how to
 * find. `phase` is the stable token that says which line this is ("1s", "5s",
 * "30s", "stall", "diagnose"). `in_process` is 0 when the HWND belongs to
 * ANOTHER process -- --diagnose measuring a second instance -- and the counters,
 * the paint total and the heartbeat then print as `-` rather than as this
 * process's own, which would be a quiet lie.
 *
 * Returns the length written. Never sends a message; see the header comment. */
static int spdf_win_health_line(HWND hwnd, const char* phase, int in_process, char* out, size_t n) {
    char stamp[40];
    wchar_t wexe[MAX_PATH * 2];
    char exe[MAX_PATH * 4];
    char monitor[64];
    RECT rect;
    RECT mon_rect;
    spdf_win_health_windows walk;
    spdf_win_health_onscreen screen;
    HMONITOR mon;
    MONITORINFOEXW mi;
    DWORD pid = 0;
    LONG64 now = (LONG64)GetTickCount64();
    LONG64 beat = spdf_win_health.heartbeat_tick;
    LONG64 input = spdf_win_health.last_input_tick;
    int modal;

    spdf_win_health_iso_now(stamp, sizeof(stamp));
    exe[0] = '\0';
    if (GetModuleFileNameW(NULL, wexe, (DWORD)(sizeof(wexe) / sizeof(wexe[0]))))
        WideCharToMultiByte(CP_UTF8, 0, wexe, -1, exe, (int)sizeof(exe), NULL, NULL);

    memset(&rect, 0, sizeof(rect));
    GetWindowRect(hwnd, &rect);
    GetWindowThreadProcessId(hwnd, &pid);

    memset(&walk, 0, sizeof(walk));
    walk.target = hwnd;
    walk.pid = pid;
    if (pid) EnumWindows(spdf_win_health_enum, (LPARAM)&walk);
    /* Disabled with an enabled window of ours on top of it: a modal dialog, and
     * the reader's "it ignores every click" from the outside. */
    modal = (!IsWindowEnabled(hwnd) && walk.owned_enabled > 0) ? 1 : 0;

    strcpy_s(monitor, sizeof(monitor), "none");
    memset(&mon_rect, 0, sizeof(mon_rect));
    mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL);
    if (mon) {
        memset(&mi, 0, sizeof(mi));
        mi.cbSize = sizeof(mi);
        if (GetMonitorInfoW(mon, (MONITORINFO*)&mi)) {
            WideCharToMultiByte(CP_UTF8, 0, mi.szDevice, -1, monitor, (int)sizeof(monitor), NULL, NULL);
            mon_rect = mi.rcMonitor;
        }
    }
    screen.rect = rect;
    screen.hit = 0;
    EnumDisplayMonitors(NULL, NULL, spdf_win_health_monitor_enum, (LPARAM)&screen);

    if (in_process) {
        const spdf_win_health_state* h = &spdf_win_health;
        return _snprintf_s(
            out, n, _TRUNCATE,
            "%s at=%.1fs phase=%s pid=%lu hwnd=0x%08llX build=%s fg=%d enabled=%d visible=%d iconic=%d "
            "rect=%ld,%ld,%ld,%ld monitor=%s mon_rect=%ld,%ld,%ld,%ld onscreen=%d zindex=%d windows=%d hung=%d "
            "modal=%d owned=%d msg=lbdown:%ld,keydown:%ld,char:%ld,mousemove:%ld,wheel:%ld,activate:%ld,"
            "setfocus:%ld,killfocus:%ld paints=%ld last_input_age_ms=%lld heartbeat_age_ms=%lld pump=%s exe=%s\n",
            stamp, spdf_win_health_ms_since_launch() / 1000.0, phase ? phase : "?", (unsigned long)pid,
            (unsigned long long)(ULONG_PTR)hwnd, SPDF_WIN_RELEASE_TAG, GetForegroundWindow() == hwnd ? 1 : 0,
            IsWindowEnabled(hwnd) ? 1 : 0, IsWindowVisible(hwnd) ? 1 : 0, IsIconic(hwnd) ? 1 : 0, rect.left,
            rect.top, rect.right, rect.bottom, monitor, mon_rect.left, mon_rect.top, mon_rect.right,
            mon_rect.bottom, screen.hit, spdf_win_health_zindex(hwnd), walk.count, walk.hung, modal, walk.owned,
            h->lbuttondown, h->keydown, h->chars, h->mousemove, h->wheel, h->activate, h->setfocus, h->killfocus,
            h->paints, input ? (long long)(now - input) : -1LL, beat ? (long long)(now - beat) : -1LL,
            h->idle ? "idle" : "busy", exe);
    }
    return _snprintf_s(out, n, _TRUNCATE,
                       "%s at=- phase=%s pid=%lu hwnd=0x%08llX build=- fg=%d enabled=%d visible=%d iconic=%d "
                       "rect=%ld,%ld,%ld,%ld monitor=%s mon_rect=%ld,%ld,%ld,%ld onscreen=%d zindex=%d windows=%d "
                       "hung=%d modal=%d owned=%d msg=- paints=- last_input_age_ms=- heartbeat_age_ms=- pump=- "
                       "exe=-\n",
                       stamp, phase ? phase : "?", (unsigned long)pid, (unsigned long long)(ULONG_PTR)hwnd,
                       GetForegroundWindow() == hwnd ? 1 : 0, IsWindowEnabled(hwnd) ? 1 : 0,
                       IsWindowVisible(hwnd) ? 1 : 0, IsIconic(hwnd) ? 1 : 0, rect.left, rect.top, rect.right,
                       rect.bottom, monitor, mon_rect.left, mon_rect.top, mon_rect.right, mon_rect.bottom,
                       screen.hit, spdf_win_health_zindex(hwnd), walk.count, walk.hung, modal, walk.owned);
}

/* --- stdout for a /SUBSYSTEM:WINDOWS process ----------------------------- */

/* --diagnose and --print-layout print, and this exe has no console of its own.
 * A redirected parent (`app --diagnose > file`, and every PowerShell capture)
 * already hands us a standard output handle; an interactive `app --diagnose`
 * does not, and ATTACH_PARENT_PROCESS borrows the shell's. When neither works
 * the text is dropped rather than opening a console nobody asked for -- the
 * caller that wants it reliably redirects, which is what the test does. */
static void spdf_win_health_print(const char* text) {
    static int attached = 0;
    HANDLE out;
    DWORD written = 0;
    size_t len;
    if (!text || !*text) return;
    out = GetStdHandle(STD_OUTPUT_HANDLE);
    if ((out == NULL || out == INVALID_HANDLE_VALUE) && !attached) {
        attached = 1;
        if (AttachConsole(ATTACH_PARENT_PROCESS)) out = GetStdHandle(STD_OUTPUT_HANDLE);
    }
    if (out == NULL || out == INVALID_HANDLE_VALUE) return;
    len = strlen(text);
    WriteFile(out, text, (DWORD)len, &written, NULL);
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_HEALTH_H */
