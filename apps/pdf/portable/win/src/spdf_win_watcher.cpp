/* spdf_win_watcher.cpp — the Win32 half of spdf_win_watcher.h: one
 * ReadDirectoryChangesW thread per watch, a message-only window on the UI
 * thread where the debounce and the grace timers run, and the shadow-copy
 * store under <state dir>\ReadOnlyCopies. Every decision comes from
 * spdf_win_watcher_logic.h. */
#include "spdf_win_watcher.h"

#include "spdf_win_palette_filter.h" /* spdf_win_palette_canonical_path: the one canonical form */
#include "spdf_win_paths.h"
#include "spdf_win_watcher_logic.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "user32.lib")

namespace {

const UINT kMsgChanged = WM_APP + 0x57; /* wParam = watch id, lParam = FILE_ACTION_* */
const wchar_t* const kClassName = L"ShenzhenPDF.Watcher";
const int kMaxWatches = 64; /* SPDF_WIN_TABS_MAX */

struct Watch {
    int id;
    char path[SPDF_WIN_WATCHER_PATH_MAX];
    wchar_t* wdir;
    wchar_t* wname;
    spdf_win_watcher_fn fn;
    void* user;
    HWND hwnd;
    HANDLE dir;
    HANDLE thread;
    HANDLE stop;
    HANDLE io_event;
    SpdfWinWatcherDebounce debounce;
    int debounce_armed;
    int retry_count;
    int retry_armed;
    unsigned long long baseline_size;
    double baseline_mtime;
    int have_baseline;
    int missing_reported;
};

struct spdf_win_watcher_impl {
    HWND hwnd;
    Watch* watches[kMaxWatches];
    int count;
    int next_id;
};

long long now_us() { return (long long)GetTickCount64() * 1000LL; }

double filetime_seconds(const FILETIME& ft) {
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    return (double)(u.QuadPart - 116444736000000000ULL) / 1e7;
}

wchar_t* widen(const char* utf8) { return utf8 ? spdf_win_utf16_dup_from_utf8(utf8) : NULL; }

/* --- the worker ----------------------------------------------------------- */

DWORD WINAPI watch_thread(LPVOID param) {
    Watch* w = (Watch*)param;
    alignas(DWORD) unsigned char buffer[16 * 1024];
    HANDLE waits[2] = {w->io_event, w->stop};
    for (;;) {
        OVERLAPPED ov;
        DWORD bytes = 0;
        memset(&ov, 0, sizeof(ov));
        ov.hEvent = w->io_event;
        if (!ReadDirectoryChangesW(w->dir, buffer, sizeof(buffer), FALSE,
                                   FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE |
                                       FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_CREATION,
                                   NULL, &ov, NULL))
            break;
        if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) != WAIT_OBJECT_0) {
            CancelIoEx(w->dir, &ov);
            GetOverlappedResult(w->dir, &ov, &bytes, TRUE);
            break;
        }
        if (!GetOverlappedResult(w->dir, &ov, &bytes, FALSE)) break;
        if (bytes == 0) {
            /* The buffer overflowed: something happened, we do not know what.
             * Report a change and let the stat comparison decide. */
            PostMessageW(w->hwnd, kMsgChanged, (WPARAM)w->id, (LPARAM)FILE_ACTION_MODIFIED);
            continue;
        }
        const FILE_NOTIFY_INFORMATION* info = (const FILE_NOTIFY_INFORMATION*)buffer;
        for (;;) {
            size_t units = info->FileNameLength / sizeof(wchar_t);
            if (units == wcslen(w->wname) && _wcsnicmp(info->FileName, w->wname, units) == 0)
                PostMessageW(w->hwnd, kMsgChanged, (WPARAM)w->id, (LPARAM)info->Action);
            if (!info->NextEntryOffset) break;
            info = (const FILE_NOTIFY_INFORMATION*)((const unsigned char*)info + info->NextEntryOffset);
        }
    }
    return 0;
}

/* --- the UI-thread half ------------------------------------------------------ */

Watch* find_watch(spdf_win_watcher_impl* w, int id) {
    for (int i = 0; i < w->count; ++i)
        if (w->watches[i]->id == id) return w->watches[i];
    return NULL;
}

UINT_PTR debounce_timer_id(const Watch* w) { return (UINT_PTR)w->id * 2u; }
UINT_PTR retry_timer_id(const Watch* w) { return (UINT_PTR)w->id * 2u + 1u; }

void set_baseline(Watch* w) {
    w->have_baseline = spdf_win_watcher_stat(w->path, &w->baseline_size, &w->baseline_mtime);
}

void stop_retry(Watch* w) {
    if (w->retry_armed) KillTimer(w->hwnd, retry_timer_id(w));
    w->retry_armed = 0;
    w->retry_count = 0;
}

void begin_missing_grace(Watch* w) {
    if (w->retry_armed) return;
    w->retry_count = 0;
    w->retry_armed = SetTimer(w->hwnd, retry_timer_id(w), SPDF_WIN_WATCHER_MISSING_RETRY_MS, NULL) != 0;
}

void report_changed(Watch* w, unsigned long long size, double mtime) {
    w->baseline_size = size;
    w->baseline_mtime = mtime;
    w->have_baseline = 1;
    w->missing_reported = 0;
    if (w->fn) w->fn(w->user, w->path, SPDF_WIN_WATCH_CHANGED);
}

/* watch_check: reload only when disk differs from the baseline. */
void check(Watch* w) {
    unsigned long long size = 0;
    double mtime = 0.0;
    if (!spdf_win_watcher_stat(w->path, &size, &mtime)) {
        begin_missing_grace(w);
        return;
    }
    if (w->have_baseline && !spdf_win_watcher_stat_differs(size, mtime, w->baseline_size, w->baseline_mtime)) return;
    report_changed(w, size, mtime);
}

void debounce_kick(Watch* w) {
    spdf_win_watcher_debounce_event(&w->debounce, now_us(), (long long)SPDF_WIN_WATCHER_DEBOUNCE_MS * 1000LL);
    if (!w->debounce_armed)
        w->debounce_armed = SetTimer(w->hwnd, debounce_timer_id(w), SPDF_WIN_WATCHER_DEBOUNCE_MS, NULL) != 0;
    /* A change event supersedes any missing-grace loop in flight. */
    stop_retry(w);
}

void on_debounce_timer(Watch* w) {
    /* Not yet due (a later event moved the deadline): the timer runs again. */
    if (!spdf_win_watcher_debounce_fire(&w->debounce, now_us())) return;
    KillTimer(w->hwnd, debounce_timer_id(w));
    w->debounce_armed = 0;
    check(w);
}

void on_retry_timer(Watch* w) {
    unsigned long long size = 0;
    double mtime = 0.0;
    if (spdf_win_watcher_stat(w->path, &size, &mtime)) {
        /* Reappeared (an atomic replace landed): reload if it really changed. */
        stop_retry(w);
        if (!w->have_baseline || spdf_win_watcher_stat_differs(size, mtime, w->baseline_size, w->baseline_mtime))
            report_changed(w, size, mtime);
        return;
    }
    if (++w->retry_count >= SPDF_WIN_WATCHER_MISSING_RETRIES) {
        /* Stayed gone: the stale UI, once. The directory watch keeps watching
         * the name, so a later re-creation still reports a change. */
        stop_retry(w);
        if (!w->missing_reported && w->fn) w->fn(w->user, w->path, SPDF_WIN_WATCH_MISSING);
        w->missing_reported = 1;
    }
}

LRESULT CALLBACK watcher_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    spdf_win_watcher_impl* w = (spdf_win_watcher_impl*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (msg == WM_NCCREATE) {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)((CREATESTRUCTW*)lparam)->lpCreateParams);
        return TRUE;
    }
    if (!w) return DefWindowProcW(hwnd, msg, wparam, lparam);
    if (msg == kMsgChanged) {
        Watch* watch = find_watch(w, (int)wparam);
        if (!watch) return 0; /* a message from a watch that has since been stopped */
        if (lparam == FILE_ACTION_REMOVED || lparam == FILE_ACTION_RENAMED_OLD_NAME) begin_missing_grace(watch);
        else debounce_kick(watch);
        return 0;
    }
    if (msg == WM_TIMER) {
        Watch* watch = find_watch(w, (int)(wparam / 2u));
        if (!watch) {
            KillTimer(hwnd, (UINT_PTR)wparam);
            return 0;
        }
        if (wparam & 1u) on_retry_timer(watch);
        else on_debounce_timer(watch);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

void stop_watch(Watch* w) {
    if (w->thread) {
        SetEvent(w->stop);
        if (w->dir != INVALID_HANDLE_VALUE) CancelIoEx(w->dir, NULL);
        WaitForSingleObject(w->thread, INFINITE);
        CloseHandle(w->thread);
    }
    if (w->debounce_armed) KillTimer(w->hwnd, debounce_timer_id(w));
    stop_retry(w);
    if (w->dir != INVALID_HANDLE_VALUE) CloseHandle(w->dir);
    if (w->stop) CloseHandle(w->stop);
    if (w->io_event) CloseHandle(w->io_event);
    free(w->wdir);
    free(w->wname);
    free(w);
}

} /* namespace */

/* --- lifecycle --------------------------------------------------------------- */

spdf_win_watcher* spdf_win_watcher_create(void) {
    static ATOM registered = 0;
    spdf_win_watcher_impl* w = (spdf_win_watcher_impl*)calloc(1, sizeof(*w));
    if (!w) return NULL;
    if (!registered) {
        WNDCLASSEXW wc;
        memset(&wc, 0, sizeof(wc));
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = watcher_proc;
        wc.hInstance = GetModuleHandleW(NULL);
        wc.lpszClassName = kClassName;
        registered = RegisterClassExW(&wc);
        if (!registered) {
            free(w);
            return NULL;
        }
    }
    /* HWND_MESSAGE: a window that receives messages and is never shown. */
    w->hwnd = CreateWindowExW(0, kClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, GetModuleHandleW(NULL), w);
    if (!w->hwnd) {
        free(w);
        return NULL;
    }
    w->next_id = 1;
    return (spdf_win_watcher*)w;
}

void spdf_win_watcher_destroy(spdf_win_watcher* handle) {
    spdf_win_watcher_impl* w = (spdf_win_watcher_impl*)handle;
    if (!w) return;
    for (int i = 0; i < w->count; ++i) stop_watch(w->watches[i]);
    w->count = 0;
    DestroyWindow(w->hwnd);
    free(w);
}

int spdf_win_watcher_watch(spdf_win_watcher* handle, const char* utf8_path, spdf_win_watcher_fn fn, void* user) {
    spdf_win_watcher_impl* w = (spdf_win_watcher_impl*)handle;
    Watch* watch;
    wchar_t* wide;
    wchar_t* slash;
    if (!w || !utf8_path || !*utf8_path || w->count >= kMaxWatches) return 0;
    wide = widen(utf8_path);
    if (!wide) return 0;
    slash = wcsrchr(wide, L'\\');
    {
        wchar_t* fwd = wcsrchr(wide, L'/');
        if (fwd && (!slash || fwd > slash)) slash = fwd;
    }
    if (!slash || !slash[1]) {
        free(wide);
        return 0;
    }
    watch = (Watch*)calloc(1, sizeof(*watch));
    if (!watch) {
        free(wide);
        return 0;
    }
    watch->dir = INVALID_HANDLE_VALUE; /* calloc's 0 is not the "no handle" value */
    watch->wname = _wcsdup(slash + 1);
    /* The directory, root kept: "C:\a.pdf" watches "C:\". */
    if (slash == wide || (slash == wide + 2 && wide[1] == L':')) slash[1] = 0;
    else slash[0] = 0;
    watch->wdir = wide;
    watch->dir = CreateFileW(watch->wdir, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    if (!watch->wname || watch->dir == INVALID_HANDLE_VALUE) {
        stop_watch(watch);
        return 0;
    }
    strncpy_s(watch->path, sizeof(watch->path), utf8_path, _TRUNCATE);
    watch->id = w->next_id++;
    watch->fn = fn;
    watch->user = user;
    watch->hwnd = w->hwnd;
    watch->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    watch->io_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    set_baseline(watch);
    watch->thread = watch->stop && watch->io_event ? CreateThread(NULL, 0, watch_thread, watch, 0, NULL) : NULL;
    if (!watch->thread) {
        stop_watch(watch);
        return 0;
    }
    w->watches[w->count++] = watch;
    return watch->id;
}

void spdf_win_watcher_unwatch(spdf_win_watcher* handle, int id) {
    spdf_win_watcher_impl* w = (spdf_win_watcher_impl*)handle;
    if (!w) return;
    for (int i = 0; i < w->count; ++i) {
        if (w->watches[i]->id != id) continue;
        stop_watch(w->watches[i]);
        memmove(&w->watches[i], &w->watches[i + 1], (size_t)(w->count - i - 1) * sizeof(w->watches[0]));
        w->count--;
        return;
    }
}

void spdf_win_watcher_note_self_save(spdf_win_watcher* handle, int id) {
    Watch* watch = handle ? find_watch((spdf_win_watcher_impl*)handle, id) : NULL;
    if (watch) set_baseline(watch);
}

int spdf_win_watcher_count(const spdf_win_watcher* handle) {
    return handle ? ((const spdf_win_watcher_impl*)handle)->count : 0;
}

/* --- probes ------------------------------------------------------------------ */

int spdf_win_watcher_stat(const char* utf8_path, unsigned long long* size, double* mtime) {
    WIN32_FILE_ATTRIBUTE_DATA data;
    wchar_t* wide = widen(utf8_path);
    BOOL ok;
    if (!wide || !wide[0]) {
        free(wide);
        return 0;
    }
    ok = GetFileAttributesExW(wide, GetFileExInfoStandard, &data);
    free(wide);
    if (!ok || (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) return 0;
    if (size) *size = ((unsigned long long)data.nFileSizeHigh << 32) | data.nFileSizeLow;
    if (mtime) *mtime = filetime_seconds(data.ftLastWriteTime);
    return 1;
}

int spdf_win_watcher_source_is_read_only(const char* utf8_path) {
    WIN32_FILE_ATTRIBUTE_DATA data;
    wchar_t* wide = widen(utf8_path);
    int exists, regular, writable = 0;
    if (!wide || !wide[0]) {
        free(wide);
        return 0;
    }
    exists = GetFileAttributesExW(wide, GetFileExInfoStandard, &data) != 0;
    regular = exists && !(data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
    if (regular) {
        if (data.dwFileAttributes & FILE_ATTRIBUTE_READONLY) {
            writable = 0;
        } else {
            /* Open for write without truncating: an ACL or a read-only volume
             * answers ERROR_ACCESS_DENIED; a sharing violation means writable
             * in principle, which is what the verdict is about. */
            HANDLE h = CreateFileW(wide, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                                   OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
            if (h != INVALID_HANDLE_VALUE) {
                CloseHandle(h);
                writable = 1;
            } else {
                writable = GetLastError() != ERROR_ACCESS_DENIED && GetLastError() != ERROR_WRITE_PROTECT;
            }
        }
    }
    free(wide);
    return spdf_win_watcher_read_only_verdict(exists, regular, writable);
}
