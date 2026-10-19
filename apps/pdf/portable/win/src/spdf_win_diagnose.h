#pragma once

/* spdf_win_diagnose.h — `ShenzhenPDF.exe --diagnose`: what every running copy of
 * this app looks like from outside, plus what the running copies wrote down
 * about themselves.
 *
 * WHY A SWITCH AND NOT A SCRIPT. The report this exists for -- "the app was
 * never responsive to any user input and not even focusable" -- arrives while
 * the bad window is still on screen, from a person who has a terminal and no
 * PowerShell probe checked out. `ShenzhenPDF.exe --diagnose` is one line they
 * can type and one block they can paste, and it needs no build, no repo and no
 * second tool. portable/win/measure-launch.ps1 and the launch.health case
 * measure the same things and prove more; they are for the harness, and this is
 * for the moment.
 *
 * WHAT IT CAN AND CANNOT SEE. Every window of class ShenzhenPDFWindow on the
 * desktop, whatever process owns it, is measured with the same line builder the
 * app's own launch-health.log uses (spdf_win_health.h) -- foreground, enabled,
 * visible, iconic, rect, monitor, on-screen, z-index, and IsHungAppWindow across
 * that process's windows. The in-process half of the line (the input counters,
 * the paint total, the UI heartbeat) belongs to the process that owns the
 * window, so it prints as `-` here and is read instead from that process's own
 * launch-health.log, which is dumped underneath.
 *
 * Header-only and included from spdf_win_main.cpp alone, like spdf_win_usage.h
 * and spdf_win_headless.h. Always exits 0: a diagnostic that can fail is a
 * diagnostic nobody trusts when it says nothing.
 */

#include "spdf_win_health_log.h" /* the line builder, the log's name and where it lives */
#include "spdf_win_paths.h"
#include "spdf_win_setup.h"  /* spdf_win_setup_portable_data_in: the other place a log can be */
#include "spdf_win_window.h" /* spdf_win_window_class_name(): one definition of the name */

/* The tail of one text file, printed with a heading, or a line saying it is not
 * there. `lines` is generous on purpose: a launch writes three lines and a
 * stalling one writes more, and the whole point is to see the run before the one
 * being complained about. */
static void diagnose_dump_log(const wchar_t* path, long lines) {
    HANDLE f;
    LARGE_INTEGER size;
    char header[SPDF_WIN_PATH_MAX];
    char utf8_path[SPDF_WIN_PATH_MAX];
    char* buf;
    DWORD read = 0;
    long i, seen = 0, start = 0;

    utf8_path[0] = '\0';
    WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8_path, (int)sizeof(utf8_path), NULL, NULL);
    f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) {
        _snprintf_s(header, sizeof(header), _TRUNCATE, "\n-- %s: not present\n", utf8_path);
        spdf_win_health_print(header);
        return;
    }
    if (!GetFileSizeEx(f, &size) || size.QuadPart <= 0 || size.QuadPart > 64 * 1024 * 1024) {
        CloseHandle(f);
        return;
    }
    buf = (char*)malloc((size_t)size.QuadPart + 1);
    if (!buf) {
        CloseHandle(f);
        return;
    }
    if (ReadFile(f, buf, (DWORD)size.QuadPart, &read, NULL) && read > 0) {
        buf[read] = '\0';
        for (i = (long)read - 1; i >= 0; --i) {
            if (buf[i] != '\n') continue;
            if (++seen > lines) {
                start = i + 1;
                break;
            }
        }
        _snprintf_s(header, sizeof(header), _TRUNCATE, "\n-- %s (%ld lines, showing the last %ld)\n", utf8_path, seen,
                    seen > lines ? lines : seen);
        spdf_win_health_print(header);
        spdf_win_health_print(buf + start);
    }
    free(buf);
    CloseHandle(f);
}

/* Every top-level window of the app's class, whoever owns it. Collected through
 * EnumWindows rather than through a process scan because the CLASS is the
 * app-specific fact -- a renamed exe still registers ShenzhenPDFWindow, and a
 * differently named exe that does not is not this app. */
typedef struct diagnose_scan {
    const wchar_t* cls;
    int found;
} diagnose_scan;

static BOOL CALLBACK diagnose_enum(HWND h, LPARAM param) {
    diagnose_scan* s = (diagnose_scan*)param;
    wchar_t cls[128];
    char line[1600];
    if (!GetClassNameW(h, cls, (int)(sizeof(cls) / sizeof(cls[0])))) return TRUE;
    if (wcscmp(cls, s->cls) != 0) return TRUE;
    ++s->found;
    if (spdf_win_health_line(h, "diagnose", 0, line, sizeof(line)) > 0) spdf_win_health_print(line);
    return TRUE;
}

/* <exe dir>\ShenzhenPDF-data\launch-health.log, whether or not this invocation
 * resolves its state there. A reader whose complaint is about a copy on a USB
 * stick, running --diagnose from somewhere else, would otherwise be shown an
 * empty roaming log and told nothing. Returns 0 when there is no such path. */
static int diagnose_portable_log(wchar_t* out, size_t out_units) {
    wchar_t exe[SPDF_WIN_PATH_MAX];
    wchar_t data[SPDF_WIN_PATH_MAX];
    size_t n;
    if (!GetModuleFileNameW(NULL, exe, (DWORD)(sizeof(exe) / sizeof(exe[0])))) return 0;
    n = wcslen(exe);
    while (n > 0 && exe[n - 1] != L'\\' && exe[n - 1] != L'/') --n;
    if (n <= 1) return 0;
    exe[n - 1] = L'\0';
    if (!spdf_win_setup_portable_data_in(exe, data, SPDF_WIN_PATH_MAX)) return 0;
    return _snwprintf_s(out, out_units, _TRUNCATE, L"%s\\%hs", data, SPDF_WIN_HEALTH_LOG_NAME) > 0;
}

/* THE WHOLE REPORT. --state-dir, when it was given, has already installed its
 * override by the time this runs, so the log dumped below is the one that
 * launch belongs to -- which is what lets the launch.health case read its own
 * private log rather than the reader's. */
static int run_diagnose(void) {
    char text[SPDF_WIN_PATH_MAX * 2];
    wchar_t state_log[SPDF_WIN_PATH_MAX];
    wchar_t portable_log[SPDF_WIN_PATH_MAX];
    wchar_t exe[SPDF_WIN_PATH_MAX];
    char state[SPDF_WIN_PATH_MAX];
    char utf8_exe[SPDF_WIN_PATH_MAX];
    char stamp[40];
    diagnose_scan scan;
    int have_state;

    exe[0] = L'\0';
    utf8_exe[0] = '\0';
    if (GetModuleFileNameW(NULL, exe, (DWORD)(sizeof(exe) / sizeof(exe[0]))))
        WideCharToMultiByte(CP_UTF8, 0, exe, -1, utf8_exe, (int)sizeof(utf8_exe), NULL, NULL);
    spdf_win_health_iso_now(stamp, sizeof(stamp));
    _snprintf_s(text, sizeof(text), _TRUNCATE,
                "ShenzhenPDF --diagnose %s build=%s exe=%s\n"
                "(one line per live window of class ShenzhenPDFWindow, measured from outside; `-`\n"
                " fields are in-process facts only that window's own process can know -- read them\n"
                " from its launch-health.log below. Field guide: portable/docs/\n"
                " windows-native-observations.md section 17.)\n",
                stamp, SPDF_WIN_RELEASE_TAG, utf8_exe);
    spdf_win_health_print(text);

    scan.cls = spdf_win_window_class_name();
    scan.found = 0;
    EnumWindows(diagnose_enum, (LPARAM)&scan);
    if (scan.found == 0) spdf_win_health_print("no window of this class is open on this desktop\n");

    /* The state directory as THIS invocation resolves it: %APPDATA%\ShenzhenPDF
     * by default, the portable directory when the marker file sits next to the
     * exe, and whatever --state-dir named when it was given. */
    if (spdf_win_paths_state_dir(state, sizeof(state))) {
        _snprintf_s(text, sizeof(text), _TRUNCATE, "\nstate dir: %s\n", state);
        spdf_win_health_print(text);
    }
    have_state = spdf_win_health_log_path(state_log, sizeof(state_log) / sizeof(state_log[0]));
    if (have_state) diagnose_dump_log(state_log, 60);
    if (diagnose_portable_log(portable_log, sizeof(portable_log) / sizeof(portable_log[0])) &&
        !(have_state && _wcsicmp(portable_log, state_log) == 0))
        diagnose_dump_log(portable_log, 60);
    return 0;
}
