/* Windows compatibility shims for portable/core.
 *
 * portable/core is otherwise platform-neutral: UTF-8 `const char*` paths in,
 * `spdf_bitmap` out, no toolkit types, no threading primitives. The handful of
 * POSIX calls it does make are collected behind this header so the core .c
 * files stay free of `#ifdef` sprawl, and so each divergence is documented in
 * exactly one place with the reason it exists.
 *
 * BUILD ARRANGEMENT. On POSIX every shim below is a `static inline` wrapper
 * over the libc call it replaces, so macOS and Linux need no extra object file
 * and no build-system change. On Windows the non-trivial shims are declared
 * here and implemented in spdf_win_compat.c, which must be added to the
 * Windows build alongside the other core sources. spdf_win_compat.c compiles
 * to an empty translation unit on POSIX, so adding it to a POSIX build is
 * harmless but unnecessary.
 *
 * SEPARATOR POLICY. `\` is a perfectly legal character inside a POSIX
 * filename, so treating it as a separator there would corrupt real paths.
 * It is therefore a separator only under _WIN32. Every helper that splits a
 * path comes in two forms: the plain one applies the host policy, and the
 * `_ex` one takes the policy as an argument so tests can exercise the Windows
 * regime from a POSIX host (see tests/SPDFCoreCompatTests.c).
 */
#ifndef SPDF_WIN_COMPAT_H
#define SPDF_WIN_COMPAT_H

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#ifdef _WIN32
#include <io.h>
#include <process.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_MSC_VER) && !defined(__cplusplus) && _MSC_VER < 1900
#define SPDF_COMPAT_INLINE __inline
#else
#define SPDF_COMPAT_INLINE inline
#endif

#ifdef _WIN32
/* Windows accepts both separators in every path-taking API, and real paths
 * arrive with either: `C:\Users\x\a.pdf` from the shell and the file dialogs,
 * `C:/Users/x/a.pdf` from URLs, config files and cross-platform tooling. */
#define SPDF_COMPAT_BACKSLASH_IS_SEP 1
#define SPDF_PATH_SEP_CHAR '\\'
#define SPDF_PATH_SEP_STR "\\"
#else
#define SPDF_COMPAT_BACKSLASH_IS_SEP 0
#define SPDF_PATH_SEP_CHAR '/'
#define SPDF_PATH_SEP_STR "/"
#endif

/* MSVC's <limits.h> defines no PATH_MAX, and its _MAX_PATH is the legacy
 * 260-byte limit that modern long paths exceed. The core's own path buffers are
 * 1024, so callers share that rather than a platform-dependent size. */
#define SPDF_COMPAT_PATH_MAX 1024

/* --------------------------------------------------------------- snprintf */

/* Did an snprintf() call produce a COMPLETE, NUL-terminated string in a buffer
 * of `cap` bytes? Pass its return value as `written`.
 *
 * snprintf has THREE outcomes, and code that tests only two of them is wrong:
 *
 *   written >= 0 && written < cap  the whole string was written and terminated
 *   written >= cap                 truncated; the buffer holds a valid prefix
 *   written < 0                    encoding error; C99 7.21.6.5 leaves the
 *                                  buffer contents INDETERMINATE, so it may
 *                                  carry no NUL at all
 *
 * The third arm is the one that gets dropped, because `%s` of a `char*` cannot
 * produce it on any libc the app ships against today. That makes it a latent
 * defect rather than a live one -- but a buffer with no terminator handed to a
 * path-taking call reads out of bounds, and the sites that make these calls
 * rename the user's state files. Every caller in portable/core goes through
 * this predicate so the arm cannot be dropped again one site at a time.
 *
 * `cap == 0` is never a success: snprintf writes nothing, not even the NUL. */
static SPDF_COMPAT_INLINE int spdf_compat_snprintf_ok(int written, size_t cap) {
    return written >= 0 && cap > 0 && (size_t)written < cap;
}

/* ------------------------------------------------------------------ paths */

static SPDF_COMPAT_INLINE int spdf_compat_is_path_sep_ex(char c, int backslash_is_sep) {
    return c == '/' || (backslash_is_sep && c == '\\');
}

static SPDF_COMPAT_INLINE int spdf_compat_is_path_sep(char c) {
    return spdf_compat_is_path_sep_ex(c, SPDF_COMPAT_BACKSLASH_IS_SEP);
}

/* Last separator in `path`, or NULL when the path carries no directory part. */
static SPDF_COMPAT_INLINE const char* spdf_compat_last_path_sep_ex(const char* path, int backslash_is_sep) {
    const char* found = NULL;
    const char* cursor;

    if (!path) return NULL;
    for (cursor = path; *cursor; ++cursor)
        if (spdf_compat_is_path_sep_ex(*cursor, backslash_is_sep)) found = cursor;
    return found;
}

static SPDF_COMPAT_INLINE const char* spdf_compat_last_path_sep(const char* path) {
    return spdf_compat_last_path_sep_ex(path, SPDF_COMPAT_BACKSLASH_IS_SEP);
}

/* Length of the directory prefix of `path`, including its trailing separator;
 * 0 when the path is bare, so `path + dir_len` always names the leaf. */
static SPDF_COMPAT_INLINE size_t spdf_compat_path_dir_len_ex(const char* path, int backslash_is_sep) {
    const char* sep = spdf_compat_last_path_sep_ex(path, backslash_is_sep);
    return sep ? (size_t)(sep - path + 1) : (size_t)0;
}

static SPDF_COMPAT_INLINE size_t spdf_compat_path_dir_len(const char* path) {
    return spdf_compat_path_dir_len_ex(path, SPDF_COMPAT_BACKSLASH_IS_SEP);
}

static SPDF_COMPAT_INLINE const char* spdf_compat_path_basename_ex(const char* path, int backslash_is_sep) {
    const char* sep = spdf_compat_last_path_sep_ex(path, backslash_is_sep);
    return sep ? sep + 1 : path;
}

static SPDF_COMPAT_INLINE const char* spdf_compat_path_basename(const char* path) {
    return spdf_compat_path_basename_ex(path, SPDF_COMPAT_BACKSLASH_IS_SEP);
}

/* Writes "<system temp directory><sep><prefix>XXXXXX" into `out`, ready for
 * spdf_compat_mkdtemp(). Returns out, or NULL when it would not fit.
 *
 * The suites used to hardcode "/tmp/...", which simply does not exist on
 * Windows, so mkdtemp() there would fail on the path before it ever failed on
 * the missing function. TMPDIR is macOS's spelling, TEMP and TMP are Windows'. */
static SPDF_COMPAT_INLINE char* spdf_compat_temp_template(char* out, size_t out_len, const char* prefix) {
    static const char* names[] = {"TMPDIR", "TEMP", "TMP"};
    const char* root = "/tmp";
    size_t root_len;
    size_t i;
    int written;

    if (!out || out_len == 0 || !prefix) return NULL;
    for (i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        const char* value = getenv(names[i]);
        if (value && *value) {
            root = value;
            break;
        }
    }
    /* A trailing separator on the root would double up in the join. */
    root_len = strlen(root);
    while (root_len && spdf_compat_is_path_sep(root[root_len - 1])) --root_len;

    written = snprintf(out, out_len, "%.*s" SPDF_PATH_SEP_STR "%sXXXXXX", (int)root_len, root, prefix);
    if (!spdf_compat_snprintf_ok(written, out_len)) return NULL;
    return out;
}

/* --------------------------------------------------------------- file lock */

/* One exclusive advisory lock on a lock file. Only one of the two members is
 * live per platform; the struct is declared identically on both so callers
 * never need an `#ifdef` around a local variable. */
typedef struct spdf_compat_file_lock {
    int fd;       /* POSIX: the open lock-file descriptor, -1 when unheld. */
    void* handle; /* Windows: the HANDLE, kept as void* to keep windows.h out
                   * of a header included by every core translation unit. */
} spdf_compat_file_lock;

/* ------------------------------------------------------------------- calls */

#ifdef _WIN32

/* Implemented in spdf_win_compat.c. Each is documented there with the reason
 * the POSIX call it replaces is wrong on Windows rather than merely absent. */
int spdf_compat_replace_file(const char* src, const char* dst);
int spdf_compat_mkstemp(char* template_path);
char* spdf_compat_mkdtemp(char* template_path);
int spdf_compat_rmdir(const char* path);
int spdf_compat_close(int fd);
int spdf_compat_unlink(const char* path);
FILE* spdf_compat_fopen(const char* path, const char* mode);
char* spdf_compat_strdup(const char* text);
long spdf_compat_getpid(void);
int spdf_compat_file_mtime(const char* path, long long* out_sec, long* out_nsec);
int spdf_compat_lock_acquire(const char* path, spdf_compat_file_lock* lock);
void spdf_compat_lock_release(spdf_compat_file_lock* lock);
double spdf_compat_monotonic_ms(void);

#else

/* POSIX rename() already replaces an existing destination atomically within a
 * filesystem, which is exactly the guarantee the save paths depend on. */
static SPDF_COMPAT_INLINE int spdf_compat_replace_file(const char* src, const char* dst) {
    return rename(src, dst);
}

static SPDF_COMPAT_INLINE int spdf_compat_mkstemp(char* template_path) {
    return mkstemp(template_path);
}

static SPDF_COMPAT_INLINE char* spdf_compat_mkdtemp(char* template_path) {
    return mkdtemp(template_path);
}

static SPDF_COMPAT_INLINE int spdf_compat_rmdir(const char* path) {
    return rmdir(path);
}

static SPDF_COMPAT_INLINE int spdf_compat_close(int fd) {
    return close(fd);
}

static SPDF_COMPAT_INLINE int spdf_compat_unlink(const char* path) {
    return unlink(path);
}

static SPDF_COMPAT_INLINE FILE* spdf_compat_fopen(const char* path, const char* mode) {
    return fopen(path, mode);
}

static SPDF_COMPAT_INLINE char* spdf_compat_strdup(const char* text) {
    return strdup(text);
}

static SPDF_COMPAT_INLINE long spdf_compat_getpid(void) {
    return (long)getpid();
}

/* Modification time split into seconds and nanoseconds. The nanosecond field
 * is what lets the state re-migration heuristic distinguish two writes inside
 * the same second; Windows cannot supply it (see spdf_win_compat.c). */
static SPDF_COMPAT_INLINE int spdf_compat_file_mtime(const char* path, long long* out_sec, long* out_nsec) {
    struct stat st;

    if (!path || !out_sec || !out_nsec) return 0;
    if (stat(path, &st) != 0) return 0;
#ifdef __APPLE__
    *out_sec = (long long)st.st_mtimespec.tv_sec;
    *out_nsec = (long)st.st_mtimespec.tv_nsec;
#else
    *out_sec = (long long)st.st_mtim.tv_sec;
    *out_nsec = (long)st.st_mtim.tv_nsec;
#endif
    return 1;
}

/* Blocking exclusive lock on a lock file, created if absent. Returns 1 when
 * the lock is held. */
static SPDF_COMPAT_INLINE int spdf_compat_lock_acquire(const char* path, spdf_compat_file_lock* lock) {
    if (!path || !lock) return 0;
    lock->handle = NULL;
    lock->fd = open(path, O_CREAT | O_RDWR, 0600);
    if (lock->fd < 0) return 0;
    if (flock(lock->fd, LOCK_EX) != 0) {
        close(lock->fd);
        lock->fd = -1;
        return 0;
    }
    return 1;
}

static SPDF_COMPAT_INLINE void spdf_compat_lock_release(spdf_compat_file_lock* lock) {
    if (!lock || lock->fd < 0) return;
    flock(lock->fd, LOCK_UN);
    close(lock->fd);
    lock->fd = -1;
}

/* Monotonic milliseconds for the timing the probes print. */
static SPDF_COMPAT_INLINE double spdf_compat_monotonic_ms(void) {
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0.0;
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

#endif /* _WIN32 */

/* ------------------------------------------------------- composite helpers */

/* Creates a fresh private directory under the system temp directory and writes
 * its path into `out`. Returns out, or NULL on failure. Defined after both
 * branches above so it can call whichever spdf_compat_mkdtemp() is in play. */
static SPDF_COMPAT_INLINE char* spdf_compat_make_temp_dir(char* out, size_t out_len, const char* prefix) {
    if (!spdf_compat_temp_template(out, out_len, prefix)) return NULL;
    return spdf_compat_mkdtemp(out);
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_COMPAT_H */
