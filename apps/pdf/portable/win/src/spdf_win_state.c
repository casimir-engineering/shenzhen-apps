/* spdf_win_state.c — see spdf_win_state.h for the contract.
 *
 * The YAML/JSON conversion is entirely portable/core's (spdf_yaml.h); the only
 * platform code here is opening, replacing and locking files. The POSIX branch
 * is not dead weight: it is what lets portable/win/tests/state_test.c drive the
 * real read/write/lock paths on macOS against the real codec, so the round-trip
 * is verified before a Windows toolchain exists.
 */
#include "spdf_win_state.h"

#include "spdf_win_paths.h"
#include "spdf_win_compat.h"
#include "spdf_yaml.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- platform file IO ---------------------------------------------------- */

/* Every read_file_limited() below reports one of these through *status_out and
 * the caller must honour the FAILED/ABSENT distinction; see the header. */
#define READ_RESULT(status_out, value) \
    do {                               \
        if (status_out) *(status_out) = (value); \
    } while (0)

#if defined(_WIN32)

#include <windows.h>

/* Both halves of every path this module touches go through here: UTF-8 in,
 * extended-length UTF-16 out. Nothing below calls a narrow CRT file function,
 * because narrow CRT paths are interpreted in the process ANSI code page and
 * would mangle a non-ASCII profile name. */
static int widen_path(const char* utf8, wchar_t* out, size_t out_units) {
    char extended[SPDF_WIN_PATH_MAX];
    if (!spdf_win_path_to_extended(utf8, extended, sizeof(extended))) return 0;
    return spdf_win_utf16_from_utf8(extended, out, out_units) != SPDF_WIN_CONV_ERROR;
}

/* Which Win32 open errors mean "there is genuinely nothing here". Everything
 * else -- ERROR_SHARING_VIOLATION and ERROR_ACCESS_DENIED above all, which is
 * what an antivirus scan or an indexer holding the handle looks like -- means
 * the file may well exist and be full of the user's state. */
static spdf_win_state_read_status open_error_status(DWORD error) {
    switch (error) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:
        case ERROR_INVALID_NAME:
        case ERROR_BAD_NETPATH:
        case ERROR_BAD_PATHNAME:
            return SPDF_WIN_STATE_READ_ABSENT;
        default:
            return SPDF_WIN_STATE_READ_FAILED;
    }
}

static char* read_file_limited(const char* path, size_t* len_out,
                               spdf_win_state_read_status* status_out) {
    wchar_t wide[SPDF_WIN_PATH_MAX];
    HANDLE h;
    LARGE_INTEGER size;
    DWORD got = 0;
    char* data;

    if (len_out) *len_out = 0;
    READ_RESULT(status_out, SPDF_WIN_STATE_READ_FAILED);
    /* A path this module cannot even spell is not evidence that the file is
     * missing, so it stays FAILED. */
    if (!widen_path(path, wide, SPDF_WIN_PATH_MAX)) return NULL;
    h = CreateFileW(wide, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        READ_RESULT(status_out, open_error_status(GetLastError()));
        return NULL;
    }
    if (!GetFileSizeEx(h, &size)) {
        CloseHandle(h);
        return NULL;
    }
    if (size.QuadPart > SPDF_WIN_STATE_MAX_BYTES) {
        /* Oversized is a property of the content, like unparseable: the
         * inherited policy treats it as absent and lets defaults apply. */
        CloseHandle(h);
        READ_RESULT(status_out, SPDF_WIN_STATE_READ_ABSENT);
        return NULL;
    }
    data = (char*)malloc((size_t)size.QuadPart + 1);
    if (!data) {
        CloseHandle(h);
        return NULL;
    }
    if (size.QuadPart > 0 && (!ReadFile(h, data, (DWORD)size.QuadPart, &got, NULL) ||
                              got != (DWORD)size.QuadPart)) {
        CloseHandle(h);
        free(data);
        return NULL;
    }
    CloseHandle(h);
    data[(size_t)size.QuadPart] = 0;
    if (len_out) *len_out = (size_t)size.QuadPart;
    READ_RESULT(status_out, SPDF_WIN_STATE_READ_OK);
    return data;
}

static int write_file_replacing(const char* path, const char* temp_path, const char* text,
                                size_t len) {
    wchar_t wide_temp[SPDF_WIN_PATH_MAX];
    wchar_t wide_dest[SPDF_WIN_PATH_MAX];
    HANDLE h;
    DWORD written = 0;

    if (!widen_path(temp_path, wide_temp, SPDF_WIN_PATH_MAX)) return 0;
    if (!widen_path(path, wide_dest, SPDF_WIN_PATH_MAX)) return 0;
    h = CreateFileW(wide_temp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    if ((len > 0 && (!WriteFile(h, text, (DWORD)len, &written, NULL) || written != (DWORD)len)) ||
        !FlushFileBuffers(h)) {
        CloseHandle(h);
        DeleteFileW(wide_temp);
        return 0;
    }
    CloseHandle(h);
    /* MOVEFILE_REPLACE_EXISTING is the whole point: a plain rename() fails on
     * Windows when the destination exists, which is every save after the
     * first. See windows-port-plan.md risk 3. */
    if (!MoveFileExW(wide_temp, wide_dest, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(wide_temp);
        return 0;
    }
    return 1;
}

static unsigned long current_pid(void) { return (unsigned long)GetCurrentProcessId(); }

struct spdf_win_state_session_lock {
    HANDLE handle;
};

/* How long the UI thread may wait for another window's process to let go of
 * session.lock before it gives up on the lock. An honest hold is one read and
 * one write-through replace of session.yaml -- single-digit milliseconds on
 * an SSD, tens on a disk -- so anything still holding it after this is a
 * process that is not going to release it on a human timescale: suspended
 * under a debugger, frozen while Error Reporting collects it, or wedged. See
 * lock_file_exclusive(). Measured with another process holding the lock
 * (windows-native-observations.md section 13): before, the window was hung
 * from the first save until that process let go; with this bound it pauses
 * once per save and goes on. */
#define SPDF_WIN_STATE_LOCK_WAIT_MS 1000
#define SPDF_WIN_STATE_LOCK_POLL_MS 10

static void* lock_file_exclusive(const char* path) {
    wchar_t wide[SPDF_WIN_PATH_MAX];
    OVERLAPPED ov;
    HANDLE h;
    ULONGLONG started;
    struct spdf_win_state_session_lock* lock;

    if (!widen_path(path, wide, SPDF_WIN_PATH_MAX)) return NULL;
    h = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    memset(&ov, 0, sizeof(ov));
    /* NEVER AN UNBOUNDED WAIT ON THE UI THREAD. Every session save runs on
     * the window's thread -- a tab switch, the thirty-second tick, exit -- and
     * without LOCKFILE_FAIL_IMMEDIATELY this call parks that thread inside the
     * kernel until whichever OTHER ShenzhenPDF process holds session.lock
     * lets go. A holder that has stalled (Windows Error Reporting suspends a
     * hung process while it collects it; so does a debugger) then takes every
     * live window down with it, each one a "cross-process hang" to the shell
     * (WER's AppHangXProcB1) and none of them the process at fault. So the
     * lock is asked for without waiting, in short steps, for at most
     * SPDF_WIN_STATE_LOCK_WAIT_MS; past that the caller proceeds as it always
     * has when the lock could not be had at all (spdf_win_session.cpp treats
     * a NULL lock as "save anyway"), because a merge lost to a wedged sibling
     * is repaired by the next save and a window that never answers again is
     * not. Sleep() rather than an overlapped wait: the handle is synchronous,
     * and ten milliseconds of granularity is far below anything a reader can
     * feel. */
    started = GetTickCount64();
    while (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, MAXDWORD, MAXDWORD, &ov)) {
        DWORD error = GetLastError();
        if ((error != ERROR_LOCK_VIOLATION && error != ERROR_IO_PENDING) ||
            GetTickCount64() - started >= SPDF_WIN_STATE_LOCK_WAIT_MS) {
            CloseHandle(h);
            return NULL;
        }
        Sleep(SPDF_WIN_STATE_LOCK_POLL_MS);
    }
    lock = (struct spdf_win_state_session_lock*)malloc(sizeof(*lock));
    if (!lock) {
        UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &ov);
        CloseHandle(h);
        return NULL;
    }
    lock->handle = h;
    return lock;
}

static void unlock_file(void* opaque) {
    struct spdf_win_state_session_lock* lock = (struct spdf_win_state_session_lock*)opaque;
    OVERLAPPED ov;
    if (!lock) return;
    memset(&ov, 0, sizeof(ov));
    UnlockFileEx(lock->handle, 0, MAXDWORD, MAXDWORD, &ov);
    CloseHandle(lock->handle);
    free(lock);
}

#else /* POSIX */

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

/* The POSIX counterpart of open_error_status(). ENOENT/ENOTDIR are the only
 * two errnos that actually assert nothing is there; EACCES, EPERM, EMFILE,
 * EIO and friends all leave the file's contents unknown. */
static spdf_win_state_read_status errno_status(int err) {
    return (err == ENOENT || err == ENOTDIR) ? SPDF_WIN_STATE_READ_ABSENT
                                             : SPDF_WIN_STATE_READ_FAILED;
}

static char* read_file_limited(const char* path, size_t* len_out,
                               spdf_win_state_read_status* status_out) {
    char native[SPDF_WIN_PATH_MAX];
    struct stat st;
    FILE* f;
    char* data;
    size_t got;

    if (len_out) *len_out = 0;
    READ_RESULT(status_out, SPDF_WIN_STATE_READ_FAILED);
    if (!spdf_win_path_to_native(path, native, sizeof(native))) return NULL;
    if (stat(native, &st) != 0) {
        READ_RESULT(status_out, errno_status(errno));
        return NULL;
    }
    /* Something non-regular is occupying the name -- a directory, a device.
     * Not absent, and emphatically not something to replace with defaults. */
    if (!S_ISREG(st.st_mode)) return NULL;
    if (st.st_size > SPDF_WIN_STATE_MAX_BYTES) {
        READ_RESULT(status_out, SPDF_WIN_STATE_READ_ABSENT);
        return NULL;
    }
    f = fopen(native, "rb");
    if (!f) {
        READ_RESULT(status_out, errno_status(errno));
        return NULL;
    }
    data = (char*)malloc((size_t)st.st_size + 1);
    if (!data) {
        fclose(f);
        return NULL;
    }
    got = fread(data, 1, (size_t)st.st_size, f);
    fclose(f);
    if (got != (size_t)st.st_size) {
        free(data);
        return NULL;
    }
    data[got] = 0;
    if (len_out) *len_out = got;
    READ_RESULT(status_out, SPDF_WIN_STATE_READ_OK);
    return data;
}

static int write_file_replacing(const char* path, const char* temp_path, const char* text,
                                size_t len) {
    char native[SPDF_WIN_PATH_MAX];
    char native_temp[SPDF_WIN_PATH_MAX];
    FILE* f;
    int ok;

    if (!spdf_win_path_to_native(path, native, sizeof(native))) return 0;
    if (!spdf_win_path_to_native(temp_path, native_temp, sizeof(native_temp))) return 0;
    f = fopen(native_temp, "wb");
    if (!f) return 0;
    ok = (len == 0 || fwrite(text, 1, len, f) == len);
    if (fclose(f) != 0) ok = 0;
    if (!ok || rename(native_temp, native) != 0) {
        remove(native_temp);
        return 0;
    }
    return 1;
}

static unsigned long current_pid(void) { return (unsigned long)getpid(); }

struct spdf_win_state_session_lock {
    int fd;
};

static void* lock_file_exclusive(const char* path) {
    char native[SPDF_WIN_PATH_MAX];
    struct spdf_win_state_session_lock* lock;
    int fd;

    if (!spdf_win_path_to_native(path, native, sizeof(native))) return NULL;
    fd = open(native, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return NULL;
    if (flock(fd, LOCK_EX) != 0) {
        close(fd);
        return NULL;
    }
    lock = (struct spdf_win_state_session_lock*)malloc(sizeof(*lock));
    if (!lock) {
        flock(fd, LOCK_UN);
        close(fd);
        return NULL;
    }
    lock->fd = fd;
    return lock;
}

static void unlock_file(void* opaque) {
    struct spdf_win_state_session_lock* lock = (struct spdf_win_state_session_lock*)opaque;
    if (!lock) return;
    flock(lock->fd, LOCK_UN);
    close(lock->fd);
    free(lock);
}

#endif

/* --- the codec boundary -------------------------------------------------- */

char* spdf_win_state_read_json_at_checked(const char* path, spdf_win_state_read_status* status) {
    char* yaml;
    char* json;
    spdf_win_state_read_status read_status = SPDF_WIN_STATE_READ_FAILED;

    READ_RESULT(status, SPDF_WIN_STATE_READ_FAILED);
    if (!path || !*path) return NULL;
    yaml = read_file_limited(path, NULL, &read_status);
    if (!yaml) {
        READ_RESULT(status, read_status);
        return NULL;
    }
    json = spdf_json_from_yaml(yaml);
    free(yaml);
    /* The bytes were obtained; only the codec refused them. That is the
     * corrupt-file case the mac and GTK frontends have always treated as
     * "absent, defaults apply" -- deterministic, so a rewrite is the documented
     * recovery rather than data loss. Note the contrast with a failed OPEN
     * above, which never lands here. */
    READ_RESULT(status, json ? SPDF_WIN_STATE_READ_OK : SPDF_WIN_STATE_READ_ABSENT);
    return json;
}

char* spdf_win_state_read_json_at(const char* path) {
    return spdf_win_state_read_json_at_checked(path, NULL);
}

int spdf_win_state_write_json_at(const char* path, const char* json_text) {
    char header[128];
    char temp_path[SPDF_WIN_PATH_MAX];
    char* yaml;
    char* existing;
    size_t yaml_len, existing_len = 0;
    spdf_win_state_read_status read_status = SPDF_WIN_STATE_READ_FAILED;
    int ok;

    if (!path || !*path || !json_text) return 0;
    /* Reduce to the bare file name first: spdf_state_header_for_file() splits
     * on '/' only, so a Windows path would yield a header comment built from
     * the whole "C:\Users\..." prefix instead of "settings". The mac frontend
     * passes a bare name here for the same reason. */
    spdf_state_header_for_file(spdf_win_path_basename(path), header, sizeof(header));
    yaml = spdf_yaml_from_json(json_text, header);
    if (!yaml) return 0;
    yaml_len = strlen(yaml);

    /* Skip a no-op save, as the mac app does, so the coalesced writer does not
     * rewrite settings.yaml on every scroll-driven state tick.
     *
     * SILENT FAILURE IF WRONG: this read has a second job the comparison does
     * not advertise. If it comes back FAILED -- the file is locked by an
     * antivirus scan, a backup agent has it open, a permission changed under us
     * -- then what is on disk is unknown, and the replace below would drop
     * whatever this process happens to hold in memory (on a cold start, the
     * defaults) on top of the user's real settings, session and recent-files
     * list. It would report success while doing it. Refusing the write costs
     * one skipped tick; the caller writes again on the next one, and by then
     * the lock is usually gone. */
    existing = read_file_limited(path, &existing_len, &read_status);
    if (read_status == SPDF_WIN_STATE_READ_FAILED) {
        free(existing);
        free(yaml);
        return 0;
    }
    if (existing) {
        int same = existing_len == yaml_len && memcmp(existing, yaml, yaml_len) == 0;
        free(existing);
        if (same) {
            free(yaml);
            return 1;
        }
    }

    if (!spdf_compat_snprintf_ok(snprintf(temp_path, sizeof(temp_path), "%s.tmp.%lu", path, current_pid()),
                                 sizeof(temp_path))) {
        free(yaml);
        return 0;
    }
    ok = write_file_replacing(path, temp_path, yaml, yaml_len);
    free(yaml);
    return ok;
}

char* spdf_win_state_read_json_checked(const char* name, spdf_win_state_read_status* status) {
    char path[SPDF_WIN_PATH_MAX];
    READ_RESULT(status, SPDF_WIN_STATE_READ_FAILED);
    /* An unresolvable state directory is FAILED, not ABSENT: after the F6 fix
     * this is what a file squatting on the state directory's name looks like,
     * and answering "absent" there is how the settings got overwritten. */
    if (!spdf_win_paths_state_file(name, path, sizeof(path))) return NULL;
    return spdf_win_state_read_json_at_checked(path, status);
}

char* spdf_win_state_read_json(const char* name) {
    return spdf_win_state_read_json_checked(name, NULL);
}

int spdf_win_state_write_json(const char* name, const char* json_text) {
    char path[SPDF_WIN_PATH_MAX];
    if (!spdf_win_paths_state_file(name, path, sizeof(path))) return 0;
    return spdf_win_state_write_json_at(path, json_text);
}

/* --- startup ------------------------------------------------------------- */

int spdf_win_state_migrate(const char* dir) {
    /* Stem list and order copied from the GTK frontend (spdf_state.c
     * migrate_stems); the mac app adds "bookmarks", which is App Sandbox only. */
    static const char* const stems[] = {"settings", "session", "documents", "favorites"};
    char native[SPDF_WIN_PATH_MAX];
    if (!dir || !*dir) return -1;
    /* spdf_state_migrate_dir() joins with a literal '/'. Win32 accepts that, so
     * on Windows this conversion is the identity and the mixed-separator result
     * opens fine; off Windows it is what lets the native test drive the real
     * core migration against a '\'-composed directory. The core opens the
     * legacy JSON itself, UTF-8-correctly, via spdf_compat_fopen(). */
    if (!spdf_win_path_to_native(dir, native, sizeof(native))) return -1;
    return spdf_state_migrate_dir(native, stems, (int)(sizeof(stems) / sizeof(stems[0])));
}

int spdf_win_state_migrate_default(void) {
    char dir[SPDF_WIN_PATH_MAX];
    if (!spdf_win_paths_state_dir(dir, sizeof(dir))) return -1;
    return spdf_win_state_migrate(dir);
}

/* --- cross-process session guard ----------------------------------------- */

spdf_win_state_session_lock* spdf_win_state_session_lock_acquire(const char* dir) {
    char path[SPDF_WIN_PATH_MAX];
    if (!spdf_win_path_join(dir, "session.lock", path, sizeof(path))) return NULL;
    return (spdf_win_state_session_lock*)lock_file_exclusive(path);
}

void spdf_win_state_session_lock_release(spdf_win_state_session_lock* lock) { unlock_file(lock); }
