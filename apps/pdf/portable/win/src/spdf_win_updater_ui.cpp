/* spdf_win_updater_ui.cpp — the updater's timers and dialogs: the part that is
 * wired to the app. Everything it decides with, it decides through the pure
 * functions in spdf_win_updater.h; the network and file work is
 * spdf_win_updater_work.cpp, on threads this file starts.
 *
 * THREADING, in one paragraph. The UI thread owns a MESSAGE-ONLY window
 * (HWND_MESSAGE) that this module creates for itself, so the app's own window
 * procedure never has to learn a timer id or a custom message: the two timers
 * fire into it, and the worker threads PostMessage their results to it. The
 * worker thread does the network and the file I/O and touches no window; the
 * UI thread shows every dialog. There is at most one worker at a time.
 *
 * WHAT RUNS WHEN.
 *   start_background(hwnd)   arms a 5 s one-shot and an hourly timer; returns
 *   5 s later                the relaunch health check (consume_pending), then
 *                            the daily gate, then -- if the gate opened -- a
 *                            silent check on a worker
 *   every hour               the daily gate again (a window kept open for days
 *                            keeps checking; a laptop asleep past the gate
 *                            catches up on the first tick after it wakes)
 *   Check for Updates...     a check that bypasses the gate and the snooze and
 *                            reports every outcome
 *
 * THE INSTALL is always on consent: the prompt offers Install Now / Later.
 * Then it asks to restart; Restart Now closes the window (the session is
 * saved by the normal quit path) and relaunches the exe from an atexit
 * handler, after that save. "Later" takes effect on the next launch, where
 * the health check confirms pendingTag.
 */
#include "spdf_win_updater.h"

#include "spdf_win_modal_scope.h"
#include "spdf_win_updater_internal.h"

#include <windows.h>
#include <commctrl.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "comctl32.lib")

#define UPD_TIMER_FIRST 1
#define UPD_TIMER_CADENCE 2

static struct {
    HWND main;
    HWND sink;
    HANDLE worker;
    volatile long cancel;
    int started;
    int relaunch_at_exit;
    wchar_t self_exe[MAX_PATH];
} g;

static const wchar_t* k_sink_class = L"SpdfWinUpdaterSink";

/* --- dialogs ------------------------------------------------------------------ */

static void utf8_to_wide(const char* in, wchar_t* out, size_t cap) {
    if (!in || MultiByteToWideChar(CP_UTF8, 0, in, -1, out, (int)cap) <= 0) out[0] = L'\0';
}

/* A dialog with named buttons: TaskDialogIndirect (common controls 6, which
 * the manifest declares) falling back to MessageBox when it is unavailable.
 * Returns the index of the chosen button, or -1. */
static int ask(const wchar_t* title, const wchar_t* heading, const wchar_t* body, const wchar_t* const* buttons,
               int count, int question) {
    TASKDIALOGCONFIG cfg;
    TASKDIALOG_BUTTON tb[4];
    int pressed = 0;
    int i;
    /* THE OWNER MAY BE GONE. g.main is remembered at start-up and never
     * cleared; a task dialog parented on a destroyed HWND fails, and the
     * MessageBox fallback below fails with it, leaving nothing on screen and no
     * answer. NULL is a dialog with no owner, which is worse-looking and works.
     *
     * THE SCOPE, not because TaskDialog forgets to re-enable -- it does not --
     * but because it never disabled anything when it FAILED to appear, and
     * because Windows does not reliably hand the activation back to the owner
     * afterwards. Every exit from this function now does both.
     * (spdf_win_modal_scope.h, and section 14 of
     * portable/docs/windows-native-observations.md.) */
    HWND owner = g.main && IsWindow(g.main) ? g.main : NULL;
    SpdfWinModalGuard modal(owner);

    memset(&cfg, 0, sizeof(cfg));
    cfg.cbSize = sizeof(cfg);
    cfg.hwndParent = owner;
    cfg.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW | TDF_SIZE_TO_CONTENT;
    cfg.pszWindowTitle = title;
    cfg.pszMainInstruction = heading;
    cfg.pszContent = body;
    cfg.pszMainIcon = question ? TD_INFORMATION_ICON : TD_WARNING_ICON;
    for (i = 0; i < count && i < 4; ++i) {
        tb[i].nButtonID = 100 + i;
        tb[i].pszButtonText = buttons[i];
    }
    cfg.pButtons = tb;
    cfg.cButtons = (UINT)(count < 4 ? count : 4);
    cfg.nDefaultButton = 100;
    if (SUCCEEDED(TaskDialogIndirect(&cfg, &pressed, NULL, NULL))) return pressed >= 100 ? pressed - 100 : -1;
    /* No common controls 6 (a test binary, or a very old system): the first
     * two buttons become Yes/No, the rest is not offered. */
    {
        wchar_t text[4096];
        int rc;
        _snwprintf_s(text, _countof(text), _TRUNCATE, L"%s\n\n%s", heading, body ? body : L"");
        if (count <= 1) {
            MessageBoxW(owner, text, title, MB_OK | (question ? MB_ICONINFORMATION : MB_ICONWARNING));
            return 0;
        }
        rc = MessageBoxW(owner, text, title, MB_YESNO | MB_ICONQUESTION);
        return rc == IDYES ? 0 : 1;
    }
}

static void inform(const wchar_t* heading, const wchar_t* body, int warning) {
    const wchar_t* ok[] = {L"OK"};
    ask(L"Software Update", heading, body, ok, 1, !warning);
}

/* --- workers ------------------------------------------------------------------- */

static int worker_busy(void) {
    if (!g.worker) return 0;
    if (WaitForSingleObject(g.worker, 0) == WAIT_OBJECT_0) {
        CloseHandle(g.worker);
        g.worker = NULL;
        return 0;
    }
    return 1;
}

static void launch_check(int user_initiated) {
    spdf_win_check_outcome* out;
    if (worker_busy()) {
        if (user_initiated) inform(L"Already checking for updates.", NULL, 0);
        return;
    }
    out = (spdf_win_check_outcome*)calloc(1, sizeof(*out));
    if (!out) return;
    out->sink = g.sink;
    out->cancel = &g.cancel;
    out->user_initiated = user_initiated;
    g.cancel = 0;
    g.worker = CreateThread(NULL, 0, spdf_win_updater_check_thread, out, 0, NULL);
    if (!g.worker) free(out);
}

static void begin_install(const spdf_win_release_info* rel) {
    spdf_win_install_outcome* out;
    if (worker_busy()) return;
    out = (spdf_win_install_outcome*)calloc(1, sizeof(*out));
    if (!out) return;
    out->sink = g.sink;
    out->cancel = &g.cancel;
    wcsncpy_s(out->self_exe, _countof(out->self_exe), g.self_exe, _TRUNCATE);
    /* A deep copy: the check outcome that carried `rel` is freed on return. */
    out->release.tag = _strdup(rel->tag);
    out->release.asset_url = rel->asset_url ? _strdup(rel->asset_url) : NULL;
    out->release.sidecar_url = rel->sidecar_url ? _strdup(rel->sidecar_url) : NULL;
    out->release.asset_size = rel->asset_size;
    g.cancel = 0;
    g.worker = CreateThread(NULL, 0, spdf_win_updater_install_thread, out, 0, NULL);
    if (!g.worker) {
        spdf_win_release_info_clear(&out->release);
        free(out);
    }
}

static void relaunch_at_exit(void) {
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    wchar_t cmd[MAX_PATH + 4];
    if (!g.relaunch_at_exit || !g.self_exe[0]) return;
    /* After main() returned: the session is saved, the lock released. The new
     * process restores it. */
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    _snwprintf_s(cmd, _countof(cmd), _TRUNCATE, L"\"%s\"", g.self_exe);
    if (CreateProcessW(g.self_exe, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

/* --- results, on the UI thread ----------------------------------------------------- */

static void on_check_done(spdf_win_check_outcome* out) {
    wchar_t heading[256];
    wchar_t body[4096];
    wchar_t wrun[64], wtag[64];

    utf8_to_wide(spdf_win_updater_running_version(), wrun, _countof(wrun));
    if (!out->ok) {
        if (out->user_initiated) {
            wchar_t werr[256];
            utf8_to_wide(out->err, werr, _countof(werr));
            inform(L"Could not check for updates.", werr, 1);
        }
    } else if (out->not_modified || !out->available) {
        if (out->user_initiated) {
            if (out->newer_but_missing_asset) {
                utf8_to_wide(out->release.tag, wtag, _countof(wtag));
                _snwprintf_s(body, _countof(body), _TRUNCATE,
                             L"Shenzhen PDF %s has been released, but it has no Windows build yet. You have %s.", wtag,
                             wrun);
                inform(L"No Windows update available.", body, 0);
            } else {
                _snwprintf_s(body, _countof(body), _TRUNCATE, L"Shenzhen PDF %s is the latest version.", wrun);
                inform(L"You're up to date.", body, 0);
            }
        }
    } else {
        /* The highlights as a bulleted list -- the 26.7.17-1 fix -- under the
         * version line, then Install Now / Later. */
        char* notes = spdf_win_updater_format_notes(out->release.notes);
        wchar_t wnotes[3000];
        const wchar_t* buttons[] = {L"Install Now", L"Later"};
        int choice;
        utf8_to_wide(out->release.tag, wtag, _countof(wtag));
        utf8_to_wide(notes ? notes : "", wnotes, _countof(wnotes));
        free(notes);
        _snwprintf_s(heading, _countof(heading), _TRUNCATE, L"Shenzhen PDF %s is available.", wtag);
        _snwprintf_s(body, _countof(body), _TRUNCATE,
                     L"You have %s.%s%s\n\nThe update is downloaded, verified against Shenzhen PDF's publisher "
                     L"certificate, and installed; you will be asked to restart.",
                     wrun, wnotes[0] ? L"\n\n" : L"", wnotes);
        choice = ask(L"Software Update", heading, body, buttons, 2, 1);
        if (choice == 0) begin_install(&out->release);
        else spdf_win_updater_snooze(out->release.tag);
    }
    spdf_win_release_info_clear(&out->release);
    free(out);
}

static void on_install_done(spdf_win_install_outcome* out) {
    wchar_t heading[256], wtag[64];
    utf8_to_wide(out->release.tag, wtag, _countof(wtag));
    if (!out->ok) {
        wchar_t werr[512];
        utf8_to_wide(out->err, werr, _countof(werr));
        inform(L"The update was not installed.", werr, 1);
    } else {
        const wchar_t* buttons[] = {L"Restart Now", L"Later"};
        _snwprintf_s(heading, _countof(heading), _TRUNCATE, L"Update %s installed.", wtag);
        if (ask(L"Software Update", heading,
                L"Restart Shenzhen PDF to finish updating. Your windows and tabs will be restored.", buttons, 2,
                1) == 0) {
            g.relaunch_at_exit = 1;
            atexit(relaunch_at_exit);
            if (g.main) PostMessageW(g.main, WM_CLOSE, 0, 0);
        }
    }
    spdf_win_release_info_clear(&out->release);
    free(out);
}

/* The relaunch health check, then the daily gate. */
static void health_check_then_daily(void) {
    char tag[64];
    int r = spdf_win_updater_consume_pending(g.self_exe, spdf_win_updater_running_version(), tag, sizeof(tag));
    if (r == 1) {
        wchar_t body[256], wtag[64];
        utf8_to_wide(tag, wtag, _countof(wtag));
        _snwprintf_s(body, _countof(body), _TRUNCATE, L"You're now on Shenzhen PDF %s.", wtag);
        inform(body, NULL, 0);
    } else if (r == -1) {
        wchar_t body[1024], wtag[64], wrun[64];
        utf8_to_wide(tag, wtag, _countof(wtag));
        utf8_to_wide(spdf_win_updater_running_version(), wrun, _countof(wrun));
        _snwprintf_s(body, _countof(body), _TRUNCATE,
                     L"The update to %s did not take: this is still Shenzhen PDF %s. The previous app is kept "
                     L"beside this one as\n%s.old\nfor recovery.",
                     wtag, wrun, g.self_exe);
        inform(L"The update did not complete.", body, 1);
    }
    if (spdf_win_updater_claim_daily_slot()) launch_check(0);
}

static LRESULT CALLBACK sink_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
        case WM_TIMER:
            if (wparam == UPD_TIMER_FIRST) {
                KillTimer(hwnd, UPD_TIMER_FIRST);
                health_check_then_daily();
                return 0;
            }
            if (wparam == UPD_TIMER_CADENCE) {
                if (spdf_win_updater_claim_daily_slot()) launch_check(0);
                return 0;
            }
            break;
        case SPDF_WIN_UPDATER_MSG_CHECK_DONE: on_check_done((spdf_win_check_outcome*)lparam); return 0;
        case SPDF_WIN_UPDATER_MSG_INSTALL_DONE: on_install_done((spdf_win_install_outcome*)lparam); return 0;
        default: break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static int ensure_sink(void* hwnd) {
    WNDCLASSEXW cls;
    if (hwnd) g.main = (HWND)hwnd;
    if (g.sink) return 1;
    if (!g.self_exe[0]) spdf_win_updater_self_exe(g.self_exe, _countof(g.self_exe));
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = sink_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.lpszClassName = k_sink_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return 0;
    g.sink = CreateWindowExW(0, k_sink_class, NULL, 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, GetModuleHandleW(NULL), NULL);
    return g.sink != NULL;
}

void spdf_win_updater_start_background(void* hwnd) {
    if (g.started) return;
    if (!ensure_sink(hwnd)) return;
    g.started = 1;
    /* Nothing runs on the launch path: the first disk read is IDLE_DELAY_MS
     * away, and the network check is on a worker after that. */
    SetTimer(g.sink, UPD_TIMER_FIRST, SPDF_WIN_UPDATER_IDLE_DELAY_MS, NULL);
    SetTimer(g.sink, UPD_TIMER_CADENCE, SPDF_WIN_UPDATER_CADENCE_MS, NULL);
}

void spdf_win_updater_check_interactive(void* hwnd) {
    if (!ensure_sink(hwnd)) {
        inform(L"Could not check for updates.", L"The updater could not start.", 1);
        return;
    }
    launch_check(1);
}
