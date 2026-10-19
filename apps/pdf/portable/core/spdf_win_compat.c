/* Windows implementations of the portable/core POSIX shims.
 *
 * See spdf_win_compat.h for the build arrangement: on POSIX every shim is a
 * static inline in the header and this translation unit is empty, so only the
 * Windows build needs to compile this file.
 *
 * Every path here goes through the *W entry points. The core speaks UTF-8
 * `char*` everywhere; the *A entry points would decode those bytes with the
 * process ANSI code page, which mangles any document whose path contains a
 * non-ASCII character. */

#include "spdf_win_compat.h"

#ifdef _WIN32

#include <errno.h>
#include <direct.h>
#include <fcntl.h>
#include <share.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <wchar.h>
#include <windows.h>

/* UTF-8 -> UTF-16. Caller frees. NULL on empty input or conversion failure. */
static WCHAR* spdf_compat_widen(const char* utf8) {
    int needed;
    WCHAR* wide;

    if (!utf8) return NULL;
    needed = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (needed <= 0) return NULL;
    wide = (WCHAR*)malloc((size_t)needed * sizeof(WCHAR));
    if (!wide) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, needed) <= 0) {
        free(wide);
        return NULL;
    }
    return wide;
}

/* Map a Win32 error onto the errno the callers already report through
 * strerror(), so a Windows failure message reads like the POSIX one. */
static int spdf_compat_errno_from_win32(DWORD error) {
    switch (error) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:
            return ENOENT;
        case ERROR_ACCESS_DENIED:
        case ERROR_SHARING_VIOLATION:
            return EACCES;
        case ERROR_FILE_EXISTS:
        case ERROR_ALREADY_EXISTS:
            return EEXIST;
        case ERROR_DISK_FULL:
            return ENOSPC;
        case ERROR_NOT_SAME_DEVICE:
            return EXDEV;
        default:
            return EIO;
    }
}

/* WHY THIS EXISTS. The C library's rename() on Windows -- and MoveFileW, which
 * it is built on -- fails with ERROR_ALREADY_EXISTS whenever the destination
 * already exists. POSIX rename() replaces it. Both save paths in
 * shenzhen_pdf_core.c write to a temp file next to the document and then move
 * it over the original, and the state writer in spdf_yaml.c does the same, so
 * on Windows the plain call would fail on *every* save over an existing file
 * and every state rewrite -- silently, since the callers only surface an error
 * string. MOVEFILE_REPLACE_EXISTING restores the POSIX guarantee.
 *
 * MOVEFILE_COPY_ALLOWED is the fallback for the cross-volume case (a temp file
 * that could not be placed next to the destination); it is a copy-then-delete
 * rather than an atomic swap, so MOVEFILE_WRITE_THROUGH is paired with it to
 * make the call return only once the destination is on disk. Within one volume
 * -- the normal case, since create_temp_save_path puts the temp file in the
 * document's own directory -- the replace is atomic.
 *
 * Returns 0 on success and -1 with errno set, matching rename(). */
int spdf_compat_replace_file(const char* src, const char* dst) {
    WCHAR* wide_src = spdf_compat_widen(src);
    WCHAR* wide_dst = spdf_compat_widen(dst);
    BOOL ok = FALSE;
    DWORD error = ERROR_INVALID_PARAMETER;

    if (wide_src && wide_dst) {
        ok = MoveFileExW(wide_src, wide_dst,
                         MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH);
        if (!ok) error = GetLastError();
    }
    free(wide_src);
    free(wide_dst);
    if (ok) return 0;
    errno = spdf_compat_errno_from_win32(error);
    return -1;
}

/* WHY THIS EXISTS. mkstemp() is not in the MSVC UCRT. _wmktemp_s only picks a
 * name -- it does not create the file -- so the create must be done here with
 * _O_EXCL to keep mkstemp's "created by us, exclusively" guarantee. _wmktemp_s
 * also destroys the template's X placeholders on failure and draws from a
 * small name space, so each attempt works on a fresh copy of the template.
 *
 * SILENT FAILURE IF WRONG: this is the one shim that used to reach for the
 * narrow _mktemp_s/_sopen_s pair, on bytes that are UTF-8. The narrow CRT
 * decodes them with the process ANSI code page (CP1252 on the reference guest),
 * so a template built from a document directory outside CP1252 -- Greek,
 * Cyrillic, CJK, most emoji -- names a directory that does not exist. The
 * create then fails, or worse succeeds somewhere else, and the caller
 * (create_temp_save_path, i.e. every Save of an edited PDF) reports a generic
 * write error or drops a mojibake temp file beside the user's document: the
 * user's edits do not reach disk and nothing says which character did it.
 * Widening first is what the rest of this file already does.
 *
 * Returns an open descriptor, or -1 with errno set, matching mkstemp(). */
int spdf_compat_mkstemp(char* template_path) {
    WCHAR* wide_template;
    WCHAR* scratch;
    size_t len, units, i;
    int attempt;

    if (!template_path) {
        errno = EINVAL;
        return -1;
    }
    len = strlen(template_path);
    /* mkstemp() requires the six trailing placeholders; checking here is also
     * what lets the tail be copied back byte-for-byte below. */
    if (len < 6 || memcmp(template_path + len - 6, "XXXXXX", 6) != 0) {
        errno = EINVAL;
        return -1;
    }
    if (len >= SPDF_COMPAT_PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }

    wide_template = spdf_compat_widen(template_path);
    if (!wide_template) {
        errno = EINVAL;
        return -1;
    }
    units = wcslen(wide_template) + 1;
    scratch = (WCHAR*)malloc(units * sizeof(WCHAR));
    if (!scratch) {
        free(wide_template);
        errno = ENOMEM;
        return -1;
    }

    for (attempt = 0; attempt < 64; ++attempt) {
        int fd = -1;
        memcpy(scratch, wide_template, units * sizeof(WCHAR));
        if (_wmktemp_s(scratch, units) != 0) continue;
        if (_wsopen_s(&fd, scratch, _O_CREAT | _O_EXCL | _O_RDWR | _O_BINARY, _SH_DENYNO,
                      _S_IREAD | _S_IWRITE) == 0) {
            /* _wmktemp_s rewrites only the six trailing 'X', and substitutes
             * ASCII, so the UTF-8 spelling differs from the template in exactly
             * those six bytes -- no second conversion, and no way for a
             * round-trip to disturb the caller's buffer. */
            for (i = 0; i < 6; ++i) template_path[len - 6 + i] = (char)scratch[units - 7 + i];
            free(scratch);
            free(wide_template);
            return fd;
        }
        if (errno != EEXIST) {
            int saved = errno;
            free(scratch);
            free(wide_template);
            errno = saved;
            return -1;
        }
    }
    free(scratch);
    free(wide_template);
    errno = EEXIST;
    return -1;
}

/* WHY THIS EXISTS. mkdtemp() is not in the MSVC UCRT either. Same shape as the
 * mkstemp shim above: _mktemp_s names, _wmkdir creates, and creation is the
 * exclusivity check because _wmkdir fails with EEXIST on a directory that is
 * already there. Retries work from a fresh copy of the template because
 * _mktemp_s overwrites the placeholders even when it fails. */
char* spdf_compat_mkdtemp(char* template_path) {
    char scratch[SPDF_COMPAT_PATH_MAX];
    size_t len;
    int attempt;

    if (!template_path) {
        errno = EINVAL;
        return NULL;
    }
    len = strlen(template_path);
    if (len == 0 || len >= sizeof(scratch)) {
        errno = ENAMETOOLONG;
        return NULL;
    }

    for (attempt = 0; attempt < 64; ++attempt) {
        WCHAR* wide;
        int made;

        memcpy(scratch, template_path, len + 1);
        if (_mktemp_s(scratch, len + 1) != 0) continue;
        wide = spdf_compat_widen(scratch);
        if (!wide) {
            errno = EINVAL;
            return NULL;
        }
        made = _wmkdir(wide);
        free(wide);
        if (made == 0) {
            memcpy(template_path, scratch, len + 1);
            return template_path;
        }
        if (errno != EEXIST) return NULL;
    }
    errno = EEXIST;
    return NULL;
}

/* WHY THIS EXISTS. rmdir() is spelled _rmdir() in the UCRT, and the narrow form
 * would decode a non-ASCII temp path with the ANSI code page (see fopen). */
int spdf_compat_rmdir(const char* path) {
    WCHAR* wide = spdf_compat_widen(path);
    int result;

    if (!wide) {
        errno = EINVAL;
        return -1;
    }
    result = _wrmdir(wide);
    free(wide);
    return result;
}

int spdf_compat_close(int fd) {
    return _close(fd);
}

/* WHY THIS EXISTS. unlink() is spelled _unlink() in the UCRT; the unprefixed
 * name is deprecated and absent under a strict conformance mode. */
int spdf_compat_unlink(const char* path) {
    WCHAR* wide = spdf_compat_widen(path);
    int result;

    if (!wide) {
        errno = EINVAL;
        return -1;
    }
    result = _wunlink(wide);
    free(wide);
    return result;
}

/* WHY THIS EXISTS, AND IT FAILS SILENTLY. fopen() on Windows decodes its path
 * with the process ANSI code page, not UTF-8. A state file under a %APPDATA%
 * path containing any non-ASCII character -- an accented or non-Latin Windows
 * account name, which is entirely ordinary -- therefore just does not open, and
 * the callers read that as "no state yet" rather than as an error: the user
 * silently loses their session and settings on every launch. _wfopen takes
 * UTF-16, so the UTF-8 path the core carries survives the boundary intact. */
FILE* spdf_compat_fopen(const char* path, const char* mode) {
    WCHAR* wide_path = spdf_compat_widen(path);
    WCHAR* wide_mode = spdf_compat_widen(mode);
    FILE* f = NULL;

    if (wide_path && wide_mode) f = _wfopen(wide_path, wide_mode);
    free(wide_path);
    free(wide_mode);
    return f;
}

/* WHY THIS EXISTS. strdup() is spelled _strdup() in the UCRT; the unprefixed
 * POSIX name warns as deprecated (C4996) and is not covered by
 * _CRT_SECURE_NO_WARNINGS, which only silences the *_s replacements. */
char* spdf_compat_strdup(const char* text) {
    return _strdup(text);
}

/* WHY THIS EXISTS. getpid() is spelled _getpid() in the UCRT. It is used only
 * to make a temp file name unique per process. */
long spdf_compat_getpid(void) {
    return (long)_getpid();
}

/* WHY THIS EXISTS. Windows has neither st_mtimespec (macOS) nor st_mtim
 * (Linux): the UCRT's struct _stat64 carries only whole-second st_mtime.
 *
 * PRECISION LOSS, and it is deliberate. The only consumer is the state
 * re-migration heuristic in spdf_yaml.c, which asks "is the JSON file strictly
 * newer than the YAML file?" to detect a downgrade-then-upgrade. With
 * second resolution, a JSON write in the *same second* as the YAML write is
 * reported as not-newer, so the migration is skipped. That errs on the safe
 * side -- the existing YAML is kept rather than being overwritten from a JSON
 * file of ambiguous age -- and the window is one second wide during a version
 * downgrade, which is not a hot path. */
int spdf_compat_file_mtime(const char* path, long long* out_sec, long* out_nsec) {
    struct _stat64 st;
    WCHAR* wide;
    int ok;

    if (!path || !out_sec || !out_nsec) return 0;
    wide = spdf_compat_widen(path);
    if (!wide) return 0;
    ok = _wstat64(wide, &st) == 0;
    free(wide);
    if (!ok) return 0;
    *out_sec = (long long)st.st_mtime;
    *out_nsec = 0;
    return 1;
}

/* WHY THIS EXISTS. There is no flock() on Windows. LockFileEx over a byte
 * range of an open handle is the closest equivalent and, unlike a named mutex,
 * it is released by the kernel if the process dies holding it -- which matters
 * because this lock guards a one-shot state migration that would otherwise
 * wedge every later launch. Without LOCKFILE_FAIL_IMMEDIATELY the call blocks
 * until the range is free, matching flock(LOCK_EX).
 *
 * The handle is opened with FILE_SHARE_READ | FILE_SHARE_WRITE so a second
 * process reaches LockFileEx and waits there, rather than failing to open the
 * file at all. */
int spdf_compat_lock_acquire(const char* path, spdf_compat_file_lock* lock) {
    WCHAR* wide;
    HANDLE handle;
    OVERLAPPED overlapped;

    if (!path || !lock) return 0;
    lock->fd = -1;
    lock->handle = NULL;
    wide = spdf_compat_widen(path);
    if (!wide) return 0;
    handle = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                         OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wide);
    if (handle == INVALID_HANDLE_VALUE) return 0;

    memset(&overlapped, 0, sizeof(overlapped));
    if (!LockFileEx(handle, LOCKFILE_EXCLUSIVE_LOCK, 0, MAXDWORD, MAXDWORD, &overlapped)) {
        CloseHandle(handle);
        return 0;
    }
    lock->handle = (void*)handle;
    return 1;
}

/* WHY THIS EXISTS. clock_gettime() and CLOCK_MONOTONIC are absent from the
 * MSVC UCRT. QueryPerformanceCounter is the documented monotonic source, and
 * its frequency is fixed for the lifetime of the process, so it is read once. */
double spdf_compat_monotonic_ms(void) {
    static LARGE_INTEGER frequency;
    LARGE_INTEGER counter;

    if (frequency.QuadPart == 0 && !QueryPerformanceFrequency(&frequency)) return 0.0;
    if (!QueryPerformanceCounter(&counter)) return 0.0;
    return (double)counter.QuadPart * 1000.0 / (double)frequency.QuadPart;
}

void spdf_compat_lock_release(spdf_compat_file_lock* lock) {
    OVERLAPPED overlapped;
    HANDLE handle;

    if (!lock || !lock->handle) return;
    handle = (HANDLE)lock->handle;
    memset(&overlapped, 0, sizeof(overlapped));
    UnlockFileEx(handle, 0, MAXDWORD, MAXDWORD, &overlapped);
    CloseHandle(handle);
    lock->handle = NULL;
}

#else

/* Empty on POSIX: every shim is a static inline in spdf_win_compat.h. The
 * typedef keeps this a valid, warning-free translation unit for builds that
 * compile the whole core source list regardless of platform. */
typedef int spdf_compat_translation_unit_is_empty_on_posix;

#endif /* _WIN32 */
