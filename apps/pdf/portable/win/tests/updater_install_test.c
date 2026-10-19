/* updater_install_test.c — the self-replacing swap and the relaunch health
 * check, on temp files, with the update store redirected to a temp directory.
 *
 * WHAT IT PROVES:
 *   1. stage_beside() copies the download to <exe>.new on the exe's volume
 *      and refuses to clobber nothing (a missing source fails).
 *   2. swap_exe() leaves <exe> holding the NEW bytes and <exe>.old holding
 *      the OLD bytes, and nothing else; a swap with a missing stage fails
 *      with the install untouched; a swap whose second rename cannot happen
 *      rolls back so <exe> still holds the old bytes.
 *   3. The swap works while the "installed" file is held open for execution
 *      the way a running exe is (FILE_SHARE_DELETE is not what an image gets;
 *      a mapped image can be renamed but not overwritten), which is checked
 *      by mapping the fake exe with CreateFileMapping before swapping.
 *   4. consume_pending() over a real update.json in the temp store:
 *        pending == running  -> 1, updateOk written, pendingTag cleared, .old deleted
 *        pending != running  -> -1, pendingTag cleared, .old KEPT
 *        no pending          -> 0, an .old older than an hour swept, a fresh one kept
 *   5. with_locked_store() round-trips through the file, and a second
 *      exclusive lock waits rather than corrupting (checked by holding the
 *      lock from a thread and timing the main thread's entry).
 *
 * Exit code is the whole signal. Cleans up after itself.
 */
/* spdf-test-sources: portable/win/src/spdf_win_updater_install.cpp portable/win/src/spdf_win_updater_store.c portable/win/src/spdf_win_updater_version.c */
#include <windows.h>

#include "spdf_win_updater.h"
#include "spdf_win_updater_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                      \
    do {                                                                                 \
        ++g_checks;                                                                      \
        if (!(cond)) {                                                                   \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);             \
            ++g_failures;                                                                \
        }                                                                                \
    } while (0)

static wchar_t g_dir[MAX_PATH];

static void path_in(wchar_t* out, size_t cap, const wchar_t* name) {
    _snwprintf_s(out, cap, _TRUNCATE, L"%s\\%s", g_dir, name);
}

static int write_text(const wchar_t* path, const char* text) {
    return spdf_win_updater_write_file(path, text, strlen(text));
}

static int read_is(const wchar_t* path, const char* want) {
    char* text = NULL;
    size_t len = 0;
    int ok;
    if (!spdf_win_updater_read_file(path, &text, &len, 1 << 20)) return 0;
    ok = strcmp(text, want) == 0;
    free(text);
    return ok;
}

static int exists(const wchar_t* path) {
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

/* --- 1-3. staging and the swap ------------------------------------------ */

static void test_swap(void) {
    wchar_t exe[MAX_PATH], src[MAX_PATH], staged[MAX_PATH], old[MAX_PATH], missing[MAX_PATH];
    char err[256];
    HANDLE h, map;

    path_in(exe, MAX_PATH, L"App.exe");
    path_in(src, MAX_PATH, L"download.bin");
    path_in(old, MAX_PATH, L"App.exe.old");
    path_in(missing, MAX_PATH, L"nope.bin");
    CHECK(write_text(exe, "OLD BUILD"));
    CHECK(write_text(src, "NEW BUILD"));

    /* 1. staging */
    CHECK(!spdf_win_updater_stage_beside(exe, missing, staged, MAX_PATH, err, sizeof(err)));
    CHECK(err[0] != '\0');
    CHECK(spdf_win_updater_stage_beside(exe, src, staged, MAX_PATH, err, sizeof(err)));
    CHECK(wcscmp(staged + wcslen(staged) - 8, L".exe.new") == 0);
    CHECK(read_is(staged, "NEW BUILD"));

    /* 3. hold the "installed" exe open as the LOADER holds an image: opened
     * with FILE_SHARE_READ | FILE_SHARE_DELETE and mapped. That sharing mode is
     * why a running exe can be renamed (rename needs DELETE access, which the
     * loader's open permits) but not overwritten or unlinked (the mapped
     * section pins the data). Measured here rather than assumed: with
     * FILE_SHARE_READ alone the rename is refused, which is the first version
     * of this test and is NOT how Windows holds an image. */
    h = CreateFileW(exe, GENERIC_READ | GENERIC_EXECUTE, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    CHECK(h != INVALID_HANDLE_VALUE);
    map = h != INVALID_HANDLE_VALUE ? CreateFileMappingW(h, NULL, PAGE_READONLY, 0, 0, NULL) : NULL;
    CHECK(map != NULL);

    /* 2. the swap, with the old file mapped */
    CHECK(spdf_win_updater_swap_exe(exe, staged, err, sizeof(err)));
    CHECK(err[0] == '\0');
    CHECK(read_is(exe, "NEW BUILD"));
    CHECK(read_is(old, "OLD BUILD"));
    CHECK(!exists(staged));
    if (map) CloseHandle(map);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);

    /* A swap with no staged file: refused, install untouched. */
    CHECK(!spdf_win_updater_swap_exe(exe, staged, err, sizeof(err)));
    CHECK(strstr(err, "missing") != NULL);
    CHECK(read_is(exe, "NEW BUILD"));
    CHECK(read_is(old, "OLD BUILD")); /* the previous .old is not disturbed by a refused swap */

    /* Rollback: make the second rename impossible by staging a DIRECTORY
     * where the exe must land... simpler and deterministic: stage a file,
     * then make the target name un-creatable by holding the exe open with
     * DELETE sharing denied AND making the destination a directory. The
     * cleanest deterministic way: point `exe` at a name whose parent does
     * not exist so the first rename fails -- that exercises the "moved
     * aside" refusal -- and separately check the rollback by pre-creating a
     * directory at the exe path after moving it aside is not possible from
     * outside. So: first-rename failure is checked here; the second-rename
     * rollback is checked by locking the staged file's DELETE right. */
    {
        wchar_t bad_exe[MAX_PATH];
        path_in(bad_exe, MAX_PATH, L"no-such-dir\\App.exe");
        CHECK(write_text(src, "NEWER"));
        CHECK(spdf_win_updater_stage_beside(exe, src, staged, MAX_PATH, err, sizeof(err)));
        CHECK(!spdf_win_updater_swap_exe(bad_exe, staged, err, sizeof(err)));
        CHECK(strstr(err, "moved aside") != NULL);
        CHECK(read_is(exe, "NEW BUILD"));
        /* Second-rename rollback: hold the STAGED file open without
         * FILE_SHARE_DELETE, so MoveFileExW(staged -> exe) fails after the exe
         * was moved aside; the exe must come back. */
        h = CreateFileW(staged, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        CHECK(h != INVALID_HANDLE_VALUE);
        CHECK(!spdf_win_updater_swap_exe(exe, staged, err, sizeof(err)));
        CHECK(strstr(err, "previous version was restored") != NULL);
        CHECK(read_is(exe, "NEW BUILD")); /* rolled back: still the build that was there */
        if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
        DeleteFileW(staged);
    }
    DeleteFileW(old);
    DeleteFileW(exe);
    DeleteFileW(src);
}

/* --- 4. the relaunch health check --------------------------------------- */

static int set_pending(spdf_win_update_store* store, void* user) {
    free(store->pending_tag);
    store->pending_tag = _strdup((const char*)user);
    return 1;
}

static int read_back(spdf_win_update_store* store, void* user) {
    spdf_win_update_store* out = (spdf_win_update_store*)user;
    out->pending_tag = store->pending_tag ? _strdup(store->pending_tag) : NULL;
    out->update_ok = store->update_ok ? _strdup(store->update_ok) : NULL;
    return 0;
}

static void test_consume_pending(void) {
    wchar_t exe[MAX_PATH], old[MAX_PATH], store_path[MAX_PATH];
    char tag[64];
    spdf_win_update_store snap;

    path_in(exe, MAX_PATH, L"Relaunch.exe");
    path_in(old, MAX_PATH, L"Relaunch.exe.old");
    path_in(store_path, MAX_PATH, L"update.json");
    CHECK(write_text(exe, "NEW"));
    CHECK(write_text(old, "OLD"));

    /* Confirmed: the running version is the pending one. */
    CHECK(spdf_win_updater_with_locked_store(set_pending, (void*)"26.9.3-1"));
    CHECK(exists(store_path));
    CHECK(spdf_win_updater_consume_pending(exe, "26.9.3-1", tag, sizeof(tag)) == 1);
    CHECK(strcmp(tag, "26.9.3-1") == 0);
    CHECK(!exists(old)); /* the recovery copy has done its job */
    memset(&snap, 0, sizeof(snap));
    spdf_win_updater_with_locked_store(read_back, &snap);
    CHECK(snap.pending_tag == NULL);
    CHECK(snap.update_ok && strcmp(snap.update_ok, "26.9.3-1") == 0);
    spdf_win_update_store_clear(&snap);

    /* Mismatch: we came up as the old build. .old stays. */
    CHECK(write_text(old, "OLD"));
    CHECK(spdf_win_updater_with_locked_store(set_pending, (void*)"26.9.3-1"));
    CHECK(spdf_win_updater_consume_pending(exe, "26.9.2-1", tag, sizeof(tag)) == -1);
    CHECK(strcmp(tag, "26.9.3-1") == 0);
    CHECK(exists(old));
    memset(&snap, 0, sizeof(snap));
    spdf_win_updater_with_locked_store(read_back, &snap);
    CHECK(snap.pending_tag == NULL); /* cleared, so the next launch does not re-report */
    CHECK(snap.update_ok && strcmp(snap.update_ok, "26.9.3-1") == 0); /* the earlier confirmation survives */
    spdf_win_update_store_clear(&snap);

    /* Nothing pending: a fresh .old is left alone, an aged one is swept. */
    CHECK(spdf_win_updater_consume_pending(exe, "26.9.2-1", tag, sizeof(tag)) == 0);
    CHECK(tag[0] == '\0');
    CHECK(exists(old)); /* seconds old: kept */
    {
        HANDLE h = CreateFileW(old, FILE_WRITE_ATTRIBUTES, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        FILETIME ft;
        ULARGE_INTEGER u;
        GetSystemTimeAsFileTime(&ft);
        u.LowPart = ft.dwLowDateTime;
        u.HighPart = ft.dwHighDateTime;
        u.QuadPart -= (ULONGLONG)2 * 3600 * 10000000ULL; /* two hours ago */
        ft.dwLowDateTime = u.LowPart;
        ft.dwHighDateTime = u.HighPart;
        CHECK(h != INVALID_HANDLE_VALUE);
        if (h != INVALID_HANDLE_VALUE) {
            CHECK(SetFileTime(h, NULL, NULL, &ft));
            CloseHandle(h);
        }
    }
    CHECK(spdf_win_updater_consume_pending(exe, "26.9.2-1", tag, sizeof(tag)) == 0);
    CHECK(!exists(old)); /* swept */
    DeleteFileW(exe);
}

/* --- 5. the lock ---------------------------------------------------------- */

static DWORD WINAPI hold_lock_thread(LPVOID param) {
    /* Hold update.lock exclusively for 300 ms, the way another process
     * mid-mutation would. */
    wchar_t lock_path[MAX_PATH];
    HANDLE lock;
    OVERLAPPED ov;
    HANDLE* started = (HANDLE*)param;
    path_in(lock_path, MAX_PATH, L"update.lock");
    lock = CreateFileW(lock_path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    memset(&ov, 0, sizeof(ov));
    if (lock == INVALID_HANDLE_VALUE || !LockFileEx(lock, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &ov)) {
        SetEvent(*started);
        return 1;
    }
    SetEvent(*started);
    Sleep(300);
    UnlockFileEx(lock, 0, 1, 0, &ov);
    CloseHandle(lock);
    return 0;
}

static int bump_last_check(spdf_win_update_store* store, void* user) {
    store->last_check = *(long long*)user;
    return 1;
}

static int read_last_check(spdf_win_update_store* store, void* user) {
    *(long long*)user = store->last_check;
    return 0;
}

static void test_locked_store(void) {
    long long want = 1800000000LL, got = 0;
    HANDLE started = CreateEventW(NULL, TRUE, FALSE, NULL);
    HANDLE thread;
    DWORD t0, elapsed;

    CHECK(spdf_win_updater_with_locked_store(bump_last_check, &want));
    CHECK(spdf_win_updater_with_locked_store(read_last_check, &got));
    CHECK(got == want);

    thread = CreateThread(NULL, 0, hold_lock_thread, &started, 0, NULL);
    CHECK(thread != NULL);
    WaitForSingleObject(started, 5000);
    t0 = GetTickCount();
    want = 1800000001LL;
    CHECK(spdf_win_updater_with_locked_store(bump_last_check, &want));
    elapsed = GetTickCount() - t0;
    CHECK(elapsed >= 150); /* it WAITED for the other holder rather than racing it */
    WaitForSingleObject(thread, 5000);
    CloseHandle(thread);
    CloseHandle(started);
    got = 0;
    CHECK(spdf_win_updater_with_locked_store(read_last_check, &got));
    CHECK(got == want);
}

int main(void) {
    wchar_t tmp[MAX_PATH];
    CHECK(GetTempPathW(MAX_PATH, tmp) > 0);
    _snwprintf_s(g_dir, _countof(g_dir), _TRUNCATE, L"%sspdf-updater-install-%lu", tmp,
                 (unsigned long)GetCurrentProcessId());
    CHECK(CreateDirectoryW(g_dir, NULL) || GetLastError() == ERROR_ALREADY_EXISTS);
    spdf_win_updater_set_dir_override(g_dir);
    {
        wchar_t dir[MAX_PATH];
        CHECK(spdf_win_updater_dir(dir, MAX_PATH));
        CHECK(wcscmp(dir, g_dir) == 0);
    }

    test_swap();
    test_consume_pending();
    test_locked_store();

    /* Clean up: everything this test made lives under g_dir. */
    {
        wchar_t p[MAX_PATH];
        path_in(p, MAX_PATH, L"update.json");
        DeleteFileW(p);
        path_in(p, MAX_PATH, L"update.lock");
        DeleteFileW(p);
        RemoveDirectoryW(g_dir);
    }
    printf("updater_install_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
