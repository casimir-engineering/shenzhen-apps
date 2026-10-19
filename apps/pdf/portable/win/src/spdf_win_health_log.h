/* spdf_win_health_log.h — WHERE the health lines go, WHEN they are written, and
 * the one thread that can still write when the UI thread cannot.
 *
 * The measurement half is spdf_win_health.h next door; this is the recording
 * half. It is separate because the two answer different questions and because
 * either one alone would take the other past the 500-line cap
 * (tools/file-size-limits.md asks for an extracted file rather than a raised
 * cap, which is the same move spdf_win_usage.h and spdf_win_headless.h made).
 *
 * THE FILE. <state dir>\launch-health.log -- beside settings.yaml and
 * session.yaml, so --state-dir moves it with everything else and a test never
 * writes into the reader's own state. Plain text, one line per entry, appended,
 * trimmed to the last SPDF_WIN_HEALTH_KEEP_LINES entries when it grows past
 * SPDF_WIN_HEALTH_TRIM_BYTES. A log that grows without bound is a log somebody
 * eventually deletes; a log of the last few launches is one they paste.
 *
 * THE THREE TIMES: 1 s, 5 s and 30 s after the window is shown.
 *
 *   1 s   is the launch itself -- is this window in front, enabled, on a
 *         monitor, with no hung window in the process? The two defects of
 *         section 11 (a hung prewarm window, a window shown at z-index 1) were
 *         both visible at one second and invisible to everything else.
 *   5 s   is after the reader's first click or keystroke, so the input counters
 *         are the evidence that the messages arrived at all. "Not responsive"
 *         has two very different causes -- input that never reaches the window
 *         and input the window ignores -- and only these counters tell them
 *         apart.
 *   30 s  is the settled state, and it is what a still-open window looks like
 *         when the reader gave up and closed it.
 *
 * ONE-SHOT TIMERS WITH A CALLBACK, not spdf_win_window_set_once: that slot is
 * single and already spoken for (app_watch_sweep_once). SetTimer with a non-NULL
 * TIMERPROC is dispatched by DispatchMessage straight to the callback without
 * reaching window_proc, so these three need no case in the window's message
 * switch and cannot perturb its routing. They run on the UI thread, which is
 * what makes their line an honest in-process measurement.
 *
 * AND THE WATCHDOG, WHICH IS THE POINT. A timer on the UI thread proves the UI
 * thread is running by firing; it can never report a UI thread that has stopped.
 * So a plain thread wakes every second, compares spdf_win_health.heartbeat_tick
 * against now, and writes a `stall` line when the gap exceeds
 * SPDF_WIN_HEALTH_STALL_MS. That -- and only that -- is the instrument for a
 * blocked message pump, which is the leading explanation for a window that was
 * "never responsive to any user input". It writes at most one line per
 * SPDF_WIN_HEALTH_STALL_REPEAT_MS while the stall lasts and at most
 * SPDF_WIN_HEALTH_STALL_MAX in the life of the process, so a genuinely wedged
 * app leaves evidence rather than a gigabyte.
 *
 * A NESTED MODAL LOOP IS NOT A STALL. A system dialog turns its own pump, not
 * ours, so the heartbeat goes stale while one is up. That state is written as
 * `phase=modal`, once per dialog, and never as `stall` -- the reasoning is at
 * the check itself.
 */
#ifndef SPDF_WIN_HEALTH_LOG_H
#define SPDF_WIN_HEALTH_LOG_H

#include "spdf_win_health.h"
#include "spdf_win_paths.h" /* spdf_win_paths_state_file: the same directory settings.yaml uses */

#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_WIN_HEALTH_LOG_NAME "launch-health.log"
#define SPDF_WIN_HEALTH_KEEP_LINES 200
#define SPDF_WIN_HEALTH_TRIM_BYTES (192 * 1024)
#define SPDF_WIN_HEALTH_STALL_MS 3000
#define SPDF_WIN_HEALTH_STALL_REPEAT_MS 2000
#define SPDF_WIN_HEALTH_STALL_MAX 30

/* Timer ids for the three one-shots. Far away from the window's own 1, 2 and 3
 * (spdf_win_window.cpp) because they are set on the SAME HWND: a collision would
 * silently replace one of its timers. */
#define SPDF_WIN_HEALTH_TIMER_1S 0x5DF1
#define SPDF_WIN_HEALTH_TIMER_5S 0x5DF2
#define SPDF_WIN_HEALTH_TIMER_30S 0x5DF3

/* <state dir>\launch-health.log as a UTF-16 path, ready for CreateFileW.
 * Returns 0 when the state directory cannot be resolved, which is the one case
 * where the app has nowhere to write and must simply carry on. */
static int spdf_win_health_log_path(wchar_t* out, size_t out_units) {
    char utf8[SPDF_WIN_PATH_MAX];
    if (!spdf_win_paths_state_file(SPDF_WIN_HEALTH_LOG_NAME, utf8, sizeof(utf8))) return 0;
    return MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, (int)out_units) > 0;
}

/* Keep the last SPDF_WIN_HEALTH_KEEP_LINES lines and drop the rest. Called only
 * when the file has actually grown past the threshold, so the read-rewrite costs
 * nothing on an ordinary launch. Best effort throughout: a log that could not be
 * trimmed is still a log worth appending to. */
static void spdf_win_health_trim(const wchar_t* path) {
    HANDLE f = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    LARGE_INTEGER size;
    char* buf;
    DWORD read = 0, written = 0;
    long i, lines = 0, start = 0;
    if (f == INVALID_HANDLE_VALUE) return;
    if (!GetFileSizeEx(f, &size) || size.QuadPart <= 0 || size.QuadPart > 64 * 1024 * 1024) {
        CloseHandle(f);
        return;
    }
    buf = (char*)malloc((size_t)size.QuadPart);
    if (!buf) {
        CloseHandle(f);
        return;
    }
    if (ReadFile(f, buf, (DWORD)size.QuadPart, &read, NULL) && read > 0) {
        /* Walk backwards counting newlines; `start` ends up at the first byte of
         * the KEEP_LINES-th line from the end. */
        for (i = (long)read - 1; i >= 0; --i) {
            if (buf[i] != '\n') continue;
            if (++lines > SPDF_WIN_HEALTH_KEEP_LINES) {
                start = i + 1;
                break;
            }
        }
        if (start > 0) {
            SetFilePointer(f, 0, NULL, FILE_BEGIN);
            WriteFile(f, buf + start, read - (DWORD)start, &written, NULL);
            SetEndOfFile(f);
        }
    }
    free(buf);
    CloseHandle(f);
}

/* Append one line. FILE_APPEND_DATA so two instances launching together
 * interleave whole lines rather than overwriting each other, and a named mutex
 * around the append-and-trim so a trim cannot land between another process's
 * seek and its write. Local\ scope: the log is per-session state, like the
 * desktop it describes. */
static void spdf_win_health_write(HWND hwnd, const char* phase) {
    wchar_t path[SPDF_WIN_PATH_MAX];
    char line[1600];
    HANDLE mutex, f;
    DWORD written = 0;
    LARGE_INTEGER size;
    int len;
    if (!hwnd || !spdf_win_health_log_path(path, sizeof(path) / sizeof(path[0]))) return;
    len = spdf_win_health_line(hwnd, phase, 1, line, sizeof(line));
    if (len <= 0) return;

    mutex = CreateMutexW(NULL, FALSE, L"Local\\ShenzhenPDF.launch-health");
    if (mutex) WaitForSingleObject(mutex, 2000);
    f = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) {
        WriteFile(f, line, (DWORD)len, &written, NULL);
        size.QuadPart = 0;
        GetFileSizeEx(f, &size);
        CloseHandle(f);
        if (size.QuadPart > SPDF_WIN_HEALTH_TRIM_BYTES) spdf_win_health_trim(path);
    }
    if (mutex) {
        ReleaseMutex(mutex);
        CloseHandle(mutex);
    }
}

/* --- the three one-shots ------------------------------------------------- */

static void CALLBACK spdf_win_health_timer(HWND hwnd, UINT msg, UINT_PTR id, DWORD tick) {
    (void)msg;
    (void)tick;
    KillTimer(hwnd, id);
    spdf_win_health_write(hwnd, id == SPDF_WIN_HEALTH_TIMER_1S    ? "1s"
                                : id == SPDF_WIN_HEALTH_TIMER_5S ? "5s"
                                                                 : "30s");
}

/* --- the watchdog -------------------------------------------------------- */

static DWORD WINAPI spdf_win_health_watchdog(LPVOID param) {
    HWND hwnd = (HWND)param;
    LONG64 last_report = 0;
    int reports = 0;
    int modal_reported = 0;
    for (;;) {
        LONG64 now, beat;
        Sleep(1000);
        /* The window is gone: so is the question. IsWindow does not send a
         * message, so a hung UI thread cannot block this check either. */
        if (!IsWindow(hwnd)) return 0;
        now = (LONG64)GetTickCount64();
        beat = spdf_win_health.heartbeat_tick;
        /* Parked in GetMessageW is health, not a stall: an idle reader's app
         * waits there for as long as the reader is away. Only a stale heartbeat
         * taken while the loop is INSIDE a dispatch counts. */
        if (spdf_win_health.idle) continue;
        if (!beat || now - beat < SPDF_WIN_HEALTH_STALL_MS) continue;
        /* A NESTED MODAL LOOP IS NOT A STALL, AND MUST NOT BE LOGGED AS ONE.
         *
         * A system dialog -- the shell's Open dialog, a TaskDialog, the print
         * dialog -- runs its OWN message loop and never returns to ours, so the
         * heartbeat goes stale for as long as it is up. The old code reported
         * that as `phase=stall`, once every two seconds: the one instrument this
         * port has for a genuinely wedged pump filled itself with false alarms
         * whenever a reader took a moment over a file picker, which is worse
         * than having no instrument at all.
         *
         * So the state is named. One `modal` line per episode -- enough to say
         * in the log that a dialog was up and from when -- and then silence
         * until the dialog goes away, which is when modal_reported clears and a
         * later real stall can still be reported. The `modal` line carries every
         * other field unchanged, including `owned`, so a reader can still see
         * WHICH window is in front of the disabled one. */
        if (spdf_win_health_is_modal(hwnd)) {
            if (!modal_reported) {
                modal_reported = 1;
                spdf_win_health_write(hwnd, "modal");
            }
            continue;
        }
        modal_reported = 0;
        if (reports >= SPDF_WIN_HEALTH_STALL_MAX) continue;
        if (last_report && now - last_report < SPDF_WIN_HEALTH_STALL_REPEAT_MS) continue;
        last_report = now;
        ++reports;
        /* `stall` carries the same fields as every other line -- the point is
         * that heartbeat_age_ms is now large, and that everything AROUND it
         * (foreground, enabled, hung, z-index, the counters that stopped
         * advancing) is captured at the moment the pump was stuck rather than
         * afterwards. A modal dialog was excluded above, so a line that says
         * `stall` now means a pump that is genuinely stuck. */
        spdf_win_health_write(hwnd, "stall");
    }
}

/* THE ONE CALL. Made once, from the windowed launch, right after the window is
 * shown (spdf_win_launch_window.h). Arms the three timers on the UI thread and
 * starts the watchdog. Never fails loudly: a launch that could not write its
 * own health log is still a launch that must open the document. */
static void spdf_win_health_log_start(void* native_hwnd) {
    HWND hwnd = (HWND)native_hwnd;
    HANDLE thread;
    if (!hwnd) return;
    spdf_win_health.shown_tick = (LONG64)GetTickCount64();
    spdf_win_health_heartbeat(); /* the pump has not turned yet; do not read as stalled */
    SetTimer(hwnd, SPDF_WIN_HEALTH_TIMER_1S, 1000, spdf_win_health_timer);
    SetTimer(hwnd, SPDF_WIN_HEALTH_TIMER_5S, 5000, spdf_win_health_timer);
    SetTimer(hwnd, SPDF_WIN_HEALTH_TIMER_30S, 30000, spdf_win_health_timer);
    thread = CreateThread(NULL, 64 * 1024, spdf_win_health_watchdog, hwnd, 0, NULL);
    if (thread) CloseHandle(thread);
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_HEALTH_LOG_H */
