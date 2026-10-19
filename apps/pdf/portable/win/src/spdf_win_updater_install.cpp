/* spdf_win_updater_install.cpp — where the updater keeps its files, how it
 * locks its store, and the self-replacing swap.
 *
 * THE SWAP, and why it is shaped as it is. Windows will not let a mapped
 * executable be overwritten or deleted, but it WILL let it be renamed -- the
 * image stays mapped from the renamed file. So the sequence is the one the
 * GTK user-local install uses (spdf_updater.c:1677) with rename() spelled
 * MoveFileExW:
 *
 *   1. copy the verified download to <exe>.new, on the exe's own volume, so
 *      that step 3 is a same-volume rename and therefore atomic;
 *   2. MoveFileExW(<exe>, <exe>.old)             the running app keeps running
 *   3. MoveFileExW(<exe>.new, <exe>)             the new app is in place
 *      on failure: MoveFileExW(<exe>.old, <exe>) and the working install is
 *      back, byte for byte, because nothing ever wrote INTO it.
 *
 * <exe>.old is KEPT on purpose. The relaunched process runs
 * spdf_win_updater_consume_pending(): if it is the version the store promised,
 * updateOk is written and .old is deleted; if it is not -- the swap did not
 * take, or the user copied the old exe back -- .old stays where the user can
 * find it and the app says so. An orphaned .old with no pending tag is swept
 * once it is an hour old. This is the macOS .old lifecycle, unchanged.
 *
 * FILES. %LOCALAPPDATA%\ShenzhenPDF\updates\ holds update.json, update.lock
 * and the per-tag download directories. LOCAL, not roaming (%APPDATA%, where
 * settings.yaml lives): "checked today" and "downloaded 20 MB" are facts about
 * this machine, and a roaming profile that carried them to another machine
 * would skip that machine's check.
 */
#include "spdf_win_updater.h"
#include "spdf_win_updater_internal.h"

#include <windows.h>
#include <shlobj.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

static wchar_t g_dir_override[MAX_PATH];

static void set_err(char* err, size_t err_len, const char* msg) {
    if (!err || !err_len) return;
    strncpy_s(err, err_len, msg, _TRUNCATE);
}

/* --- files ----------------------------------------------------------------- */

int spdf_win_updater_read_file(const wchar_t* path, char** out, size_t* out_len, size_t max_bytes) {
    HANDLE file;
    LARGE_INTEGER size;
    char* buf;
    DWORD got = 0;
    size_t total = 0;

    if (out) *out = NULL;
    if (out_len) *out_len = 0;
    if (!path || !out) return 0;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 0 || (unsigned long long)size.QuadPart > max_bytes) {
        CloseHandle(file);
        return 0;
    }
    buf = (char*)malloc((size_t)size.QuadPart + 1);
    if (!buf) {
        CloseHandle(file);
        return 0;
    }
    while (total < (size_t)size.QuadPart) {
        DWORD want = (DWORD)((size_t)size.QuadPart - total > 0x10000000u ? 0x10000000u : (size_t)size.QuadPart - total);
        if (!ReadFile(file, buf + total, want, &got, NULL) || got == 0) break;
        total += got;
    }
    CloseHandle(file);
    buf[total] = '\0';
    *out = buf;
    if (out_len) *out_len = total;
    return 1;
}

int spdf_win_updater_write_file(const wchar_t* path, const char* data, size_t len) {
    wchar_t tmp[MAX_PATH + 8];
    HANDLE file;
    DWORD wrote = 0;

    if (!path) return 0;
    _snwprintf_s(tmp, _countof(tmp), _TRUNCATE, L"%s.tmp", path);
    file = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    if (len && (!WriteFile(file, data, (DWORD)len, &wrote, NULL) || wrote != len)) {
        CloseHandle(file);
        DeleteFileW(tmp);
        return 0;
    }
    FlushFileBuffers(file);
    CloseHandle(file);
    if (!MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(tmp);
        return 0;
    }
    return 1;
}

long long spdf_win_updater_now_epoch(void) {
    FILETIME ft;
    ULARGE_INTEGER u;
    GetSystemTimeAsFileTime(&ft);
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    /* 100 ns ticks since 1601 -> seconds since 1970. */
    return (long long)(u.QuadPart / 10000000ULL) - 11644473600LL;
}

int spdf_win_updater_self_exe(wchar_t* out, size_t out_len) {
    DWORD n;
    if (!out || !out_len) return 0;
    n = GetModuleFileNameW(NULL, out, (DWORD)out_len);
    return n > 0 && n < out_len;
}

/* --- the directory ----------------------------------------------------------- */

void spdf_win_updater_set_dir_override(const wchar_t* dir) {
    if (dir) wcsncpy_s(g_dir_override, _countof(g_dir_override), dir, _TRUNCATE);
    else g_dir_override[0] = L'\0';
}

int spdf_win_updater_dir(wchar_t* out, size_t out_len) {
    wchar_t* local = NULL;
    if (!out || !out_len) return 0;
    if (g_dir_override[0]) {
        wcsncpy_s(out, out_len, g_dir_override, _TRUNCATE);
    } else {
        if (SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, NULL, &local) != S_OK || !local) return 0;
        _snwprintf_s(out, out_len, _TRUNCATE, L"%s\\ShenzhenPDF\\updates", local);
        CoTaskMemFree(local);
    }
    /* Create both levels; ERROR_ALREADY_EXISTS is the normal case. */
    {
        wchar_t parent[MAX_PATH];
        wchar_t* slash;
        wcsncpy_s(parent, _countof(parent), out, _TRUNCATE);
        slash = wcsrchr(parent, L'\\');
        if (slash) {
            *slash = L'\0';
            CreateDirectoryW(parent, NULL);
        }
        if (!CreateDirectoryW(out, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return 0;
    }
    return 1;
}

/* --- the locked store --------------------------------------------------------- */

int spdf_win_updater_with_locked_store(spdf_win_store_mutator mutator, void* user) {
    wchar_t dir[MAX_PATH];
    wchar_t lock_path[MAX_PATH + 16];
    wchar_t store_path[MAX_PATH + 16];
    HANDLE lock;
    OVERLAPPED ov;
    char* text = NULL;
    size_t len = 0;
    spdf_win_update_store store;
    int changed;
    int ok = 1;

    if (!mutator) return 0;
    if (!spdf_win_updater_dir(dir, _countof(dir))) return 0;
    _snwprintf_s(lock_path, _countof(lock_path), _TRUNCATE, L"%s\\update.lock", dir);
    _snwprintf_s(store_path, _countof(store_path), _TRUNCATE, L"%s\\update.json", dir);

    lock = CreateFileW(lock_path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                       OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (lock == INVALID_HANDLE_VALUE) return 0;
    memset(&ov, 0, sizeof(ov));
    /* Exclusive, blocking, on one byte: LockFileEx is flock(LOCK_EX) here, and
     * the other frontends' update.lock is the same idea by the same name. */
    if (!LockFileEx(lock, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &ov)) {
        CloseHandle(lock);
        return 0;
    }

    spdf_win_updater_read_file(store_path, &text, &len, 1024 * 1024);
    spdf_win_update_store_parse(text, (long)len, &store);
    free(text);
    changed = mutator(&store, user);
    if (changed) {
        char* json = spdf_win_update_store_serialize(&store);
        ok = json && spdf_win_updater_write_file(store_path, json, strlen(json));
        free(json);
    }
    spdf_win_update_store_clear(&store);

    UnlockFileEx(lock, 0, 1, 0, &ov);
    CloseHandle(lock);
    return ok;
}

/* --- staging and the swap ------------------------------------------------------- */

int spdf_win_updater_stage_beside(const wchar_t* exe, const wchar_t* src, wchar_t* out_staged, size_t out_len,
                                  char* err, size_t err_len) {
    if (err && err_len) err[0] = '\0';
    if (!exe || !src || !out_staged || !out_len) {
        set_err(err, err_len, "could not resolve the running binary path");
        return 0;
    }
    _snwprintf_s(out_staged, out_len, _TRUNCATE, L"%s.new", exe);
    DeleteFileW(out_staged); /* sweep a stale stage */
    if (!CopyFileW(src, out_staged, TRUE)) {
        set_err(err, err_len, "could not stage the new binary next to the installed one (is the install "
                              "folder writable?)");
        return 0;
    }
    return 1;
}

int spdf_win_updater_swap_exe(const wchar_t* exe, const wchar_t* staged, char* err, size_t err_len) {
    wchar_t old_path[MAX_PATH + 8];

    if (err && err_len) err[0] = '\0';
    if (!exe || !staged) {
        set_err(err, err_len, "could not resolve the running binary path");
        return 0;
    }
    if (GetFileAttributesW(staged) == INVALID_FILE_ATTRIBUTES) {
        set_err(err, err_len, "the staged binary is missing");
        return 0;
    }
    _snwprintf_s(old_path, _countof(old_path), _TRUNCATE, L"%s.old", exe);
    DeleteFileW(old_path); /* sweep a stale move-aside; fails harmlessly if it is still mapped */
    if (!MoveFileExW(exe, old_path, MOVEFILE_REPLACE_EXISTING)) {
        set_err(err, err_len, "the installed binary could not be moved aside (is the install folder writable?)");
        return 0;
    }
    if (!MoveFileExW(staged, exe, 0)) {
        /* Rollback: the working install returns, untouched. */
        MoveFileExW(old_path, exe, 0);
        set_err(err, err_len, "the new binary could not be moved into place; the previous version was restored");
        return 0;
    }
    return 1;
}

/* --- the relaunch health check -------------------------------------------------- */

typedef struct consume_args {
    const char* running;
    char* out_tag;
    size_t out_len;
    int result; /* 1 confirmed, -1 mismatch, 0 nothing pending */
} consume_args;

static int consume_mutator(spdf_win_update_store* store, void* user) {
    consume_args* args = (consume_args*)user;
    if (!store->pending_tag || !*store->pending_tag) {
        args->result = 0;
        return 0;
    }
    if (args->out_tag && args->out_len) strncpy_s(args->out_tag, args->out_len, store->pending_tag, _TRUNCATE);
    if (spdf_win_updater_versions_match_release_target(store->pending_tag, args->running)) {
        free(store->update_ok);
        store->update_ok = store->pending_tag;
        store->pending_tag = NULL;
        args->result = 1;
    } else {
        /* We are still (or again) the old build: the swap did not take, or the
         * user restored manually. Clear the state, keep .old. */
        free(store->pending_tag);
        store->pending_tag = NULL;
        args->result = -1;
    }
    return 1;
}

int spdf_win_updater_consume_pending(const wchar_t* exe, const char* running, char* out_tag, size_t out_len) {
    consume_args args;
    wchar_t old_path[MAX_PATH + 8];

    if (out_tag && out_len) out_tag[0] = '\0';
    args.running = running;
    args.out_tag = out_tag;
    args.out_len = out_len;
    args.result = 0;
    if (!spdf_win_updater_with_locked_store(consume_mutator, &args)) return 0;
    if (!exe) return args.result;
    _snwprintf_s(old_path, _countof(old_path), _TRUNCATE, L"%s.old", exe);
    if (args.result == 1) {
        DeleteFileW(old_path); /* healthy: the recovery copy has done its job */
    } else if (args.result == 0) {
        /* No update in flight: sweep an aged orphaned .old, never a fresh one
         * (a swap may be seconds old in another process). */
        WIN32_FILE_ATTRIBUTE_DATA info;
        if (GetFileAttributesExW(old_path, GetFileExInfoStandard, &info)) {
            ULARGE_INTEGER m;
            long long mtime;
            m.LowPart = info.ftLastWriteTime.dwLowDateTime;
            m.HighPart = info.ftLastWriteTime.dwHighDateTime;
            mtime = (long long)(m.QuadPart / 10000000ULL) - 11644473600LL;
            if (spdf_win_updater_now_epoch() - mtime > SPDF_WIN_UPDATER_STALE_OLD_SECONDS) DeleteFileW(old_path);
        }
    }
    return args.result;
}
