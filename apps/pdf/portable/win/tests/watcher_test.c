/* watcher_test.c — spdf_win_watcher.{h,cpp} and spdf_win_watcher_shadow.cpp
 * against the real filesystem, with a real message loop and no window.
 *
 * WHAT IS PROVED. A write to a watched file reaches the subscriber's callback
 * on the calling thread, once, after the debounce; the app's own save does not
 * (note_self_save advances the baseline); a deleted file is reported MISSING
 * after the grace period; an unwatched file reports nothing. A read-only
 * source resolves to a shadow copy under the (overridden) state directory with
 * the ro-<sha256>.<ext> name, a primed restore binding makes an unchanged
 * source REUSE that copy with no content read (the copy's bytes are left as
 * planted), a changed source refreshes it, release deletes it and refuses to
 * delete anything outside the copies directory, and the sweep keeps what is
 * referenced or recent.
 *
 * Everything lives under %TEMP%\spdf_watcher_test; the state directory is
 * redirected there so %APPDATA%\ShenzhenPDF is never touched. The watcher needs
 * a message loop because its callbacks are delivered through a message-only
 * window on the creating thread -- which is the point, and is what a test
 * without a window can still pump.
 */
/* spdf-test-sources: portable/win/src/spdf_win_watcher.cpp portable/win/src/spdf_win_watcher_shadow.cpp portable/win/src/spdf_win_paths.c */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include "spdf_win_paths.h"
#include "spdf_win_watcher.h"
#include "spdf_win_watcher_logic.h"

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

static int write_file(const char* utf8, const char* text) {
    spdf_wchar* wide = spdf_win_utf16_dup_from_utf8(utf8);
    HANDLE h;
    DWORD written = 0;
    BOOL ok;
    if (!wide) return 0;
    SetFileAttributesW(wide, FILE_ATTRIBUTE_NORMAL);
    h = CreateFileW(wide, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wide);
    if (h == INVALID_HANDLE_VALUE) return 0;
    ok = WriteFile(h, text, (DWORD)strlen(text), &written, NULL);
    CloseHandle(h);
    return ok && written == strlen(text);
}

static int read_file(const char* utf8, char* out, size_t cap) {
    spdf_wchar* wide = spdf_win_utf16_dup_from_utf8(utf8);
    HANDLE h;
    DWORD got = 0;
    if (!wide) return 0;
    h = CreateFileW(wide, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0,
                    NULL);
    free(wide);
    if (h == INVALID_HANDLE_VALUE) return 0;
    ReadFile(h, out, (DWORD)(cap - 1), &got, NULL);
    CloseHandle(h);
    out[got] = 0;
    return 1;
}

static void set_read_only(const char* utf8, int on) {
    spdf_wchar* wide = spdf_win_utf16_dup_from_utf8(utf8);
    if (wide) SetFileAttributesW(wide, on ? FILE_ATTRIBUTE_READONLY : FILE_ATTRIBUTE_NORMAL);
    free(wide);
}

static void delete_file(const char* utf8) {
    spdf_wchar* wide = spdf_win_utf16_dup_from_utf8(utf8);
    if (wide) {
        SetFileAttributesW(wide, FILE_ATTRIBUTE_NORMAL);
        DeleteFileW(wide);
    }
    free(wide);
}

/* Pump messages for up to `ms`, or until `*flag` reaches `want`. */
static void pump_until(volatile int* flag, int want, int ms) {
    ULONGLONG deadline = GetTickCount64() + (ULONGLONG)ms;
    while (GetTickCount64() < deadline && *flag < want) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
}

typedef struct Seen {
    volatile int changed;
    volatile int missing;
    char last_path[SPDF_WIN_WATCHER_PATH_MAX];
    DWORD thread;
} Seen;

static void on_event(void* user, const char* path, int event) {
    Seen* s = (Seen*)user;
    if (event == SPDF_WIN_WATCH_CHANGED) s->changed++;
    if (event == SPDF_WIN_WATCH_MISSING) s->missing++;
    strcpy(s->last_path, path);
    s->thread = GetCurrentThreadId();
}

static void test_change_missing_and_self_save(const char* dir) {
    char doc[SPDF_WIN_PATH_MAX], other[SPDF_WIN_PATH_MAX];
    spdf_win_watcher* w;
    Seen seen;
    int id;
    memset(&seen, 0, sizeof(seen));
    spdf_win_path_join(dir, "watched.pdf", doc, sizeof(doc));
    spdf_win_path_join(dir, "other.pdf", other, sizeof(other));
    CHECK(write_file(doc, "%PDF-1.4 one"));
    CHECK(write_file(other, "%PDF-1.4 other"));

    w = spdf_win_watcher_create();
    CHECK(w != NULL);
    if (!w) return;
    id = spdf_win_watcher_watch(w, doc, on_event, &seen);
    CHECK(id > 0);
    CHECK(spdf_win_watcher_count(w) == 1);
    /* Nothing happened: nothing is reported, however long we wait. */
    pump_until(&seen.changed, 1, 700);
    CHECK(seen.changed == 0);
    /* A sibling changing is not our file. */
    CHECK(write_file(other, "%PDF-1.4 other changed"));
    pump_until(&seen.changed, 1, 900);
    CHECK(seen.changed == 0);
    /* Our file changes: one CHANGED, on this thread, after the debounce. */
    Sleep(20); /* NTFS mtime resolution is 100 ns; the size changes anyway */
    CHECK(write_file(doc, "%PDF-1.4 one, longer"));
    pump_until(&seen.changed, 1, 3000);
    CHECK(seen.changed == 1);
    CHECK(seen.thread == GetCurrentThreadId());
    CHECK(strcmp(seen.last_path, doc) == 0);
    /* A burst of writes coalesces into one report. */
    seen.changed = 0;
    CHECK(write_file(doc, "%PDF-1.4 burst 1"));
    Sleep(50);
    CHECK(write_file(doc, "%PDF-1.4 burst 22"));
    Sleep(50);
    CHECK(write_file(doc, "%PDF-1.4 burst 333"));
    pump_until(&seen.changed, 1, 3000);
    pump_until(&seen.changed, 2, 900); /* and nothing more follows */
    CHECK(seen.changed == 1);
    /* The app's own save: the baseline moves, nothing is reported. */
    seen.changed = 0;
    CHECK(write_file(doc, "%PDF-1.4 saved by the app"));
    spdf_win_watcher_note_self_save(w, id);
    pump_until(&seen.changed, 1, 1200);
    CHECK(seen.changed == 0);
    /* Deleted: MISSING after the grace period, once. */
    delete_file(doc);
    pump_until(&seen.missing, 1, 4000);
    CHECK(seen.missing == 1);
    pump_until(&seen.missing, 2, 700);
    CHECK(seen.missing == 1);
    /* Recreated: CHANGED again. */
    CHECK(write_file(doc, "%PDF-1.4 back"));
    pump_until(&seen.changed, 1, 3000);
    CHECK(seen.changed == 1);
    /* Unwatched: silence. */
    spdf_win_watcher_unwatch(w, id);
    CHECK(spdf_win_watcher_count(w) == 0);
    seen.changed = 0;
    CHECK(write_file(doc, "%PDF-1.4 after unwatch"));
    pump_until(&seen.changed, 1, 900);
    CHECK(seen.changed == 0);
    /* Bad arguments. */
    CHECK(spdf_win_watcher_watch(w, "", on_event, &seen) == 0);
    CHECK(spdf_win_watcher_watch(w, "no-directory.pdf", on_event, &seen) == 0);
    CHECK(spdf_win_watcher_watch(NULL, doc, on_event, &seen) == 0);
    spdf_win_watcher_unwatch(w, 12345);
    spdf_win_watcher_destroy(w);
    spdf_win_watcher_destroy(NULL);
    delete_file(doc);
    delete_file(other);
}

static void test_probes(const char* dir) {
    char doc[SPDF_WIN_PATH_MAX], missing[SPDF_WIN_PATH_MAX];
    unsigned long long size = 0;
    double mtime = 0.0;
    spdf_win_path_join(dir, "probe.pdf", doc, sizeof(doc));
    spdf_win_path_join(dir, "nope.pdf", missing, sizeof(missing));
    CHECK(write_file(doc, "%PDF-1.4"));
    CHECK(spdf_win_watcher_stat(doc, &size, &mtime));
    CHECK(size == strlen("%PDF-1.4"));
    CHECK(mtime > 1.7e9); /* after 2023 */
    CHECK(!spdf_win_watcher_stat(missing, &size, &mtime));
    CHECK(!spdf_win_watcher_stat(dir, &size, &mtime)); /* a directory is not a file */
    CHECK(!spdf_win_watcher_stat(NULL, &size, &mtime));
    CHECK(!spdf_win_watcher_source_is_read_only(doc));
    CHECK(!spdf_win_watcher_source_is_read_only(dir));
    CHECK(!spdf_win_watcher_source_is_read_only(missing));
    CHECK(!spdf_win_watcher_source_is_read_only(NULL));
    CHECK(!spdf_win_watcher_source_is_read_only(""));
    set_read_only(doc, 1);
    CHECK(spdf_win_watcher_source_is_read_only(doc));
    set_read_only(doc, 0);
    CHECK(!spdf_win_watcher_source_is_read_only(doc));
    delete_file(doc);
}

static void test_shadow_copies(const char* dir) {
    char src[SPDF_WIN_PATH_MAX], copies[SPDF_WIN_PATH_MAX], stranger[SPDF_WIN_PATH_MAX], first_copy[SPDF_WIN_PATH_MAX];
    char content[128];
    SpdfWinWatcherResolution res;
    const char* referenced[1];
    spdf_win_path_join(dir, "locked.pdf", src, sizeof(src));
    spdf_win_path_join(dir, "stranger.pdf", stranger, sizeof(stranger));
    CHECK(write_file(src, "%PDF-1.4 locked v1"));
    CHECK(write_file(stranger, "%PDF-1.4 not a copy"));

    /* Writable: no copy, zeroed resolution. */
    memset(&res, 1, sizeof(res));
    CHECK(!spdf_win_watcher_resolve_open(src, &res));
    CHECK(!res.read_only && res.working_path[0] == 0);
    /* Missing: also 0. */
    CHECK(!spdf_win_watcher_resolve_open("C:\\no\\such\\spdf.pdf", &res));
    CHECK(!spdf_win_watcher_resolve_open(NULL, &res));
    CHECK(!spdf_win_watcher_resolve_open(src, NULL));

    /* Read-only: a copy appears in the copies directory, named by digest. */
    set_read_only(src, 1);
    CHECK(spdf_win_watcher_resolve_open(src, &res));
    CHECK(res.read_only);
    CHECK(res.working_path[0] != 0);
    CHECK(spdf_win_watcher_copies_dir(0, copies, sizeof(copies)));
    CHECK(strncmp(res.working_path, copies, strlen(copies)) == 0);
    CHECK(spdf_win_watcher_is_shadow_path(res.working_path));
    CHECK(!spdf_win_watcher_is_shadow_path(src));
    CHECK(!spdf_win_watcher_is_shadow_path(stranger));
    CHECK(res.copy_file_size == strlen("%PDF-1.4 locked v1"));
    CHECK(res.copy_modified_at > 1.7e9);
    CHECK(read_file(res.working_path, content, sizeof(content)));
    CHECK(strcmp(content, "%PDF-1.4 locked v1") == 0);
    strcpy(first_copy, res.working_path);
    /* The copy itself is writable (the read-only bit did not travel). */
    CHECK(!spdf_win_watcher_source_is_read_only(first_copy));

    /* Unchanged source + primed binding: the SAME copy, reused without a
     * content read -- proven by planting bytes in the copy and finding them
     * still there. */
    CHECK(write_file(first_copy, "PLANTED"));
    spdf_win_watcher_prime_restore(src, first_copy, res.copy_file_size, res.copy_modified_at);
    CHECK(spdf_win_watcher_resolve_open(src, &res));
    CHECK(strcmp(res.working_path, first_copy) == 0);
    CHECK(read_file(first_copy, content, sizeof(content)));
    CHECK(strcmp(content, "PLANTED") == 0);
    /* The binding was consumed: a second resolve refreshes the copy. */
    CHECK(spdf_win_watcher_resolve_open(src, &res));
    CHECK(read_file(res.working_path, content, sizeof(content)));
    CHECK(strcmp(content, "%PDF-1.4 locked v1") == 0);
    /* A changed source with a stale binding refreshes too. */
    set_read_only(src, 0);
    Sleep(20);
    CHECK(write_file(src, "%PDF-1.4 locked v2 longer"));
    set_read_only(src, 1);
    spdf_win_watcher_prime_restore(src, first_copy, 5, 1.0);
    CHECK(spdf_win_watcher_resolve_open(src, &res));
    CHECK(res.copy_file_size == strlen("%PDF-1.4 locked v2 longer"));
    CHECK(read_file(res.working_path, content, sizeof(content)));
    CHECK(strcmp(content, "%PDF-1.4 locked v2 longer") == 0);
    /* A primed binding with no working path is ignored. */
    spdf_win_watcher_prime_restore(src, "", 1, 1.0);
    spdf_win_watcher_prime_restore(src, NULL, 1, 1.0);

    /* Release: gone when unshared, kept when shared, never outside the dir. */
    spdf_win_watcher_release_copy(first_copy, 1);
    CHECK(read_file(first_copy, content, sizeof(content)));
    spdf_win_watcher_release_copy(stranger, 0);
    CHECK(read_file(stranger, content, sizeof(content)));
    spdf_win_watcher_release_copy(first_copy, 0);
    CHECK(!read_file(first_copy, content, sizeof(content)));
    spdf_win_watcher_release_copy(NULL, 0);

    /* The sweep: a fresh copy is kept (recency); an old unreferenced one goes;
     * an old referenced one stays. */
    CHECK(spdf_win_watcher_resolve_open(src, &res));
    strcpy(first_copy, res.working_path);
    spdf_win_watcher_sweep_orphans(NULL, 0);
    CHECK(read_file(first_copy, content, sizeof(content))); /* touched seconds ago */
    {
        /* Age it: set its write time two minutes back. */
        spdf_wchar* wide = spdf_win_utf16_dup_from_utf8(first_copy);
        HANDLE h = wide ? CreateFileW(wide, FILE_WRITE_ATTRIBUTES, 0, NULL, OPEN_EXISTING, 0, NULL) : INVALID_HANDLE_VALUE;
        if (h != INVALID_HANDLE_VALUE) {
            FILETIME ft;
            ULARGE_INTEGER u;
            GetSystemTimeAsFileTime(&ft);
            u.LowPart = ft.dwLowDateTime;
            u.HighPart = ft.dwHighDateTime;
            u.QuadPart -= 120ULL * 10000000ULL;
            ft.dwLowDateTime = u.LowPart;
            ft.dwHighDateTime = u.HighPart;
            SetFileTime(h, NULL, NULL, &ft);
            CloseHandle(h);
        }
        free(wide);
    }
    referenced[0] = first_copy;
    spdf_win_watcher_sweep_orphans(referenced, 1);
    CHECK(read_file(first_copy, content, sizeof(content)));
    spdf_win_watcher_sweep_orphans(NULL, 0);
    CHECK(!read_file(first_copy, content, sizeof(content)));

    set_read_only(src, 0);
    delete_file(src);
    delete_file(stranger);
}

/* THE WORKER'S HALF OF THE RESOLUTION.
 *
 * Every open in the process goes through one hook, and that hook has to give a
 * search worker, a thumbnail store or a link scanner the SAME bytes the canvas
 * is showing -- which for a read-only source is the shadow copy, not the
 * source (spdf_win_open_app.h). It cannot call resolve_open() to find out:
 * that one writes files and mutates the binding table, on a UI thread, and the
 * hook is called from a dozen workers at once. So there is a lookup-only form,
 * and these are its four answers.
 *
 * The stale-copy case is the one worth reading twice. A copy whose source has
 * since MOVED ON is still the right answer: the canvas is holding that copy's
 * bytes until the watcher reports the change and reloads, so a worker that
 * read the newer source would disagree with the page on screen -- the same bug
 * this fixes, pointing the other way. Proven by planting bytes in the copy and
 * finding that the lookup still names it. */
static void test_existing_working_path(const char* dir) {
    char src[SPDF_WIN_PATH_MAX], found[SPDF_WIN_PATH_MAX], content[128];
    SpdfWinWatcherResolution res;
    spdf_win_path_join(dir, "worker-view.pdf", src, sizeof(src));
    CHECK(write_file(src, "%PDF-1.4 v1"));

    /* Writable, and no copy: the caller opens what it was given. */
    strcpy(found, "dirty");
    CHECK(!spdf_win_watcher_existing_working_path(src, found, sizeof(found)));
    CHECK(found[0] == 0); /* emptied, never left holding a stale answer */
    CHECK(!spdf_win_watcher_existing_working_path(NULL, found, sizeof(found)));
    CHECK(!spdf_win_watcher_existing_working_path(src, NULL, 0));
    CHECK(!spdf_win_watcher_existing_working_path("C:\\no\\such\\spdf.pdf", found, sizeof(found)));

    /* Read-only, once a copy exists: the copy, byte for byte the path
     * resolve_open() authored. */
    set_read_only(src, 1);
    CHECK(spdf_win_watcher_resolve_open(src, &res));
    CHECK(res.working_path[0] != 0);
    CHECK(spdf_win_watcher_existing_working_path(src, found, sizeof(found)));
    CHECK(strcmp(found, res.working_path) == 0);

    /* A STALE copy is still the answer. write_file() clears the read-only
     * attribute to do its write (it has to), so the bit goes back on after --
     * which is also what the real case looks like: the source is rewritten by
     * whatever owns it and is still not ours to write. */
    CHECK(write_file(res.working_path, "PLANTED"));
    set_read_only(src, 0);
    CHECK(write_file(src, "%PDF-1.4 v2 and longer"));
    set_read_only(src, 1);
    CHECK(spdf_win_watcher_existing_working_path(src, found, sizeof(found)));
    CHECK(strcmp(found, res.working_path) == 0);
    CHECK(read_file(found, content, sizeof(content)));
    CHECK(strcmp(content, "PLANTED") == 0);

    /* The copy is never resolved to a copy of itself: no recursion, whatever a
     * caller hands over. */
    CHECK(!spdf_win_watcher_existing_working_path(res.working_path, found, sizeof(found)));

    /* WRITABLE AGAIN, with the copy still on disk -- the state the first ten
     * seconds after a launch are in, before the orphan sweep runs. The source
     * is what the canvas opens now, so it must be what the workers open: a
     * lookup that answered from the leftover file would put every worker on a
     * document the reader is not looking at. */
    set_read_only(src, 0);
    CHECK(!spdf_win_watcher_existing_working_path(src, found, sizeof(found)));
    CHECK(found[0] == 0);
}

int main(int argc, char** argv) {
    char scratch[SPDF_WIN_PATH_MAX], state[SPDF_WIN_PATH_MAX], docs[SPDF_WIN_PATH_MAX];
    const char* base = argc > 1 ? argv[1] : NULL;
    if (!base || !*base) base = getenv("TEMP");
    if (!base || !*base) base = ".";
    if (!spdf_win_path_join(base, "spdf_watcher_test", scratch, sizeof(scratch))) return 1;
    if (!spdf_win_path_join(scratch, "state", state, sizeof(state))) return 1;
    if (!spdf_win_path_join(scratch, "docs", docs, sizeof(docs))) return 1;
    if (!spdf_win_paths_ensure_dir(state) || !spdf_win_paths_ensure_dir(docs)) {
        printf("FAIL: could not create %s\n", scratch);
        return 1;
    }
    spdf_win_paths_set_state_dir_override(state);

    test_probes(docs);
    test_shadow_copies(docs);
    test_existing_working_path(docs);
    test_change_missing_and_self_save(docs);

    spdf_win_paths_set_state_dir_override(NULL);
    printf("watcher_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
