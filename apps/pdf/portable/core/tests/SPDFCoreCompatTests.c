/* Regression tests for portable/core/spdf_win_compat.{h,c}.
 *
 * Deliberately free of MuPDF and of any toolkit, so this binary builds and runs
 * on macOS, Linux and in the Windows guest from day one.
 *
 * Two of the behaviours here are the silent Windows faults the port had to fix,
 * and both fail as wrong output rather than as a crash, which is why each gets
 * an explicit assertion:
 *
 *   1. create_temp_save_path() split the directory on '/' only, so a path like
 *      C:\Users\x\a.pdf yielded dir_len == 0 and the temp file was created in
 *      the process CWD instead of beside the document. Covered by the
 *      windows-regime path cases and by test_mkstemp_stays_in_directory().
 *
 *   2. rename() cannot replace an existing file on Windows, so every save over
 *      an existing PDF and every state rewrite failed. Covered by
 *      test_replace_over_existing_destination(). On POSIX this pins the
 *      contract; on Windows it is the actual proof that MoveFileExW replaced
 *      the broken call.
 */
#include "spdf_win_compat.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++g_failures;                              \
        }                                              \
    } while (0)

/* ------------------------------------------------------------- scaffolding */

/* A private directory for one run; NULL on failure. Caller frees. */
static char* make_scratch_dir(void) {
    char* path = (char*)malloc(SPDF_COMPAT_PATH_MAX);

    if (!path) return NULL;
    if (!spdf_compat_make_temp_dir(path, SPDF_COMPAT_PATH_MAX, "spdf-compat-tests.")) {
        free(path);
        return NULL;
    }
    return path;
}

static char* join(const char* dir, const char* leaf) {
    size_t len = strlen(dir) + strlen(leaf) + 2;
    char* path = (char*)malloc(len);

    if (!path) return NULL;
    snprintf(path, len, "%s" SPDF_PATH_SEP_STR "%s", dir, leaf);
    return path;
}

static int write_text(const char* path, const char* text) {
    FILE* f = fopen(path, "wb");
    size_t len = strlen(text);
    size_t written;

    if (!f) return 0;
    written = fwrite(text, 1, len, f);
    return fclose(f) == 0 && written == len;
}

/* Contents of `path`, or NULL when it cannot be read. Caller frees. */
static char* read_text(const char* path) {
    FILE* f = fopen(path, "rb");
    char* buffer;
    size_t got;

    if (!f) return NULL;
    buffer = (char*)malloc(4096);
    if (!buffer) {
        fclose(f);
        return NULL;
    }
    got = fread(buffer, 1, 4095, f);
    fclose(f);
    buffer[got] = '\0';
    return buffer;
}

static int file_exists(const char* path) {
    FILE* f = fopen(path, "rb");

    if (!f) return 0;
    fclose(f);
    return 1;
}

/* ------------------------------------------------------------- path splits */

/* The POSIX regime: '\' is an ordinary filename character and must never be
 * treated as a separator, or real POSIX paths would be truncated. */
static void test_posix_path_regime(void) {
    EXPECT(spdf_compat_path_dir_len_ex("/home/x/a.pdf", 0) == 8, "posix dir_len");
    EXPECT(strcmp(spdf_compat_path_basename_ex("/home/x/a.pdf", 0), "a.pdf") == 0, "posix basename");
    EXPECT(spdf_compat_path_dir_len_ex("a.pdf", 0) == 0, "posix bare dir_len");
    EXPECT(strcmp(spdf_compat_path_basename_ex("a.pdf", 0), "a.pdf") == 0, "posix bare basename");
    EXPECT(spdf_compat_path_dir_len_ex("weird\\name.pdf", 0) == 0, "posix backslash is not a separator");
    EXPECT(strcmp(spdf_compat_path_basename_ex("weird\\name.pdf", 0), "weird\\name.pdf") == 0,
           "posix backslash name kept whole");
    EXPECT(spdf_compat_path_dir_len_ex("", 0) == 0, "posix empty dir_len");
    EXPECT(spdf_compat_last_path_sep_ex(NULL, 0) == NULL, "posix NULL path");
}

/* The Windows regime, exercised from any host. dir_len == 0 here is exactly
 * the bug: it sent the save temp file to the CWD instead of the document's
 * directory, which then broke the atomic replace that ends the save. */
static void test_windows_path_regime(void) {
    EXPECT(spdf_compat_path_dir_len_ex("C:\\Users\\x\\a.pdf", 1) == 11, "windows backslash dir_len");
    EXPECT(strcmp(spdf_compat_path_basename_ex("C:\\Users\\x\\a.pdf", 1), "a.pdf") == 0, "windows backslash basename");
    EXPECT(spdf_compat_path_dir_len_ex("C:/Users/x/a.pdf", 1) == 11, "windows forward-slash dir_len");
    EXPECT(strcmp(spdf_compat_path_basename_ex("C:/Users/x/a.pdf", 1), "a.pdf") == 0, "windows forward-slash basename");
    /* Mixed separators are normal: shell and file dialogs hand back '\', while
     * config files, URLs and cross-platform tooling hand back '/'. */
    EXPECT(spdf_compat_path_dir_len_ex("C:\\Users/x\\a.pdf", 1) == 11, "windows mixed dir_len");
    EXPECT(strcmp(spdf_compat_path_basename_ex("C:\\Users/x\\a.pdf", 1), "a.pdf") == 0, "windows mixed basename");
    EXPECT(spdf_compat_path_dir_len_ex("C:\\a.pdf", 1) == 3, "windows drive-root dir_len");
    EXPECT(spdf_compat_path_dir_len_ex("\\\\server\\share\\a.pdf", 1) == 15, "windows UNC dir_len");
    EXPECT(spdf_compat_path_dir_len_ex("a.pdf", 1) == 0, "windows bare dir_len");
    EXPECT(spdf_compat_is_path_sep_ex('\\', 1) && spdf_compat_is_path_sep_ex('/', 1), "windows separators");
    EXPECT(!spdf_compat_is_path_sep_ex('\\', 0), "posix separators");
}

/* The unparameterised helpers must follow the host policy, so the core picks up
 * the right regime without any caller-side #ifdef. */
static void test_host_regime_matches_platform(void) {
    const char* mixed = "C:\\dir/file.pdf";

    EXPECT(spdf_compat_path_dir_len(mixed) == spdf_compat_path_dir_len_ex(mixed, SPDF_COMPAT_BACKSLASH_IS_SEP),
           "host dir_len follows host policy");
    EXPECT(spdf_compat_is_path_sep('\\') == SPDF_COMPAT_BACKSLASH_IS_SEP, "host backslash policy");
    EXPECT(spdf_compat_is_path_sep('/'), "forward slash is a separator everywhere");
    EXPECT(spdf_compat_is_path_sep(SPDF_PATH_SEP_CHAR), "host separator constant is a separator");
    EXPECT(strlen(SPDF_PATH_SEP_STR) == 1 && SPDF_PATH_SEP_STR[0] == SPDF_PATH_SEP_CHAR, "separator constants agree");
}

/* --------------------------------------------------------- atomic replace */

/* THE SAVE BUG. Both PDF save paths and the YAML state writer finish by moving
 * a temp file over a destination that already exists. rename() refuses that on
 * Windows, so every such save failed -- silently, as a returned error string. */
static void test_replace_over_existing_destination(const char* dir) {
    char* src = join(dir, "replace-src.txt");
    char* dst = join(dir, "replace-dst.txt");
    char* got;

    if (!src || !dst) {
        EXPECT(0, "out of memory");
        free(src);
        free(dst);
        return;
    }
    EXPECT(write_text(dst, "ORIGINAL"), "seed destination");
    EXPECT(write_text(src, "REPLACEMENT"), "seed source");
    EXPECT(spdf_compat_replace_file(src, dst) == 0, "replace over an existing destination must succeed");

    got = read_text(dst);
    EXPECT(got && strcmp(got, "REPLACEMENT") == 0, "destination now holds the replacement");
    free(got);
    EXPECT(!file_exists(src), "source is consumed by the move");

    spdf_compat_unlink(dst);
    free(src);
    free(dst);
}

static void test_replace_onto_missing_destination(const char* dir) {
    char* src = join(dir, "fresh-src.txt");
    char* dst = join(dir, "fresh-dst.txt");
    char* got;

    if (!src || !dst) {
        EXPECT(0, "out of memory");
        free(src);
        free(dst);
        return;
    }
    EXPECT(write_text(src, "NEW"), "seed source");
    EXPECT(!file_exists(dst), "destination starts absent");
    EXPECT(spdf_compat_replace_file(src, dst) == 0, "replace onto a missing destination must succeed");
    got = read_text(dst);
    EXPECT(got && strcmp(got, "NEW") == 0, "destination holds the moved bytes");
    free(got);

    spdf_compat_unlink(dst);
    free(src);
    free(dst);
}

static void test_replace_reports_failure(const char* dir) {
    char* src = join(dir, "does-not-exist.txt");
    char* dst = join(dir, "unreachable.txt");

    if (!src || !dst) {
        EXPECT(0, "out of memory");
        free(src);
        free(dst);
        return;
    }
    EXPECT(spdf_compat_replace_file(src, dst) != 0, "replacing from a missing source must fail");
    EXPECT(!file_exists(dst), "a failed replace creates nothing");

    free(src);
    free(dst);
}

/* ------------------------------------------------------------ temp files */

/* create_temp_save_path() builds `<document directory><template>` and hands it
 * to this call, so the shim must create the file at exactly that path and leave
 * the directory prefix intact. If it ever relocated the file, the save would
 * end with a cross-volume move and lose its atomicity. */
static void test_mkstemp_stays_in_directory(const char* dir) {
    char* template_path = join(dir, ".shenzhenpdf-save-XXXXXX");
    size_t dir_len;
    int fd;

    if (!template_path) {
        EXPECT(0, "out of memory");
        return;
    }
    dir_len = spdf_compat_path_dir_len(template_path);
    EXPECT(dir_len == strlen(dir) + 1, "template carries the directory prefix");

    fd = spdf_compat_mkstemp(template_path);
    EXPECT(fd >= 0, "mkstemp shim opens a descriptor");
    if (fd >= 0) {
        EXPECT(spdf_compat_close(fd) == 0, "close shim succeeds");
        EXPECT(file_exists(template_path), "mkstemp shim created the file it named");
        EXPECT(spdf_compat_path_dir_len(template_path) == dir_len, "temp file stayed in the requested directory");
        EXPECT(strncmp(template_path, dir, strlen(dir)) == 0, "temp path still starts with the directory");
        EXPECT(strstr(template_path, "XXXXXX") == NULL, "template placeholders were substituted");
        EXPECT(spdf_compat_unlink(template_path) == 0, "unlink shim removes the temp file");
        EXPECT(!file_exists(template_path), "temp file is gone");
    }
    free(template_path);
}

/* ---------------------------------------------------------------- mtime */

static void test_file_mtime(const char* dir) {
    char* path = join(dir, "mtime.txt");
    char* missing = join(dir, "not-here.txt");
    long long sec = -1;
    long nsec = -1;

    if (!path || !missing) {
        EXPECT(0, "out of memory");
        free(path);
        free(missing);
        return;
    }
    EXPECT(spdf_compat_file_mtime(missing, &sec, &nsec) == 0, "missing file has no mtime");
    EXPECT(write_text(path, "x"), "seed mtime fixture");
    EXPECT(spdf_compat_file_mtime(path, &sec, &nsec) == 1, "existing file reports an mtime");
    /* Windows resolves only to the second, so nsec is legitimately 0 there;
     * the assertion is only that the pair is well-formed. */
    EXPECT(sec > 0, "mtime seconds are populated");
    EXPECT(nsec >= 0 && nsec < 1000000000L, "mtime nanoseconds are in range");
    EXPECT(spdf_compat_file_mtime(NULL, &sec, &nsec) == 0, "NULL path reports no mtime");

    spdf_compat_unlink(path);
    free(path);
    free(missing);
}

/* ----------------------------------------------------------------- lock */

/* The state-migration guard. flock() does not exist on Windows; the shim uses
 * LockFileEx there. This asserts the portable contract both sides must honour:
 * acquire succeeds, release frees it, and the same path can be taken again. */
static void test_migration_lock(const char* dir) {
    char* path = join(dir, "migration.lock");
    spdf_compat_file_lock lock;
    spdf_compat_file_lock again;

    if (!path) {
        EXPECT(0, "out of memory");
        return;
    }
    EXPECT(spdf_compat_lock_acquire(path, &lock) == 1, "lock is acquired on a path that does not exist yet");
    EXPECT(file_exists(path), "acquiring the lock creates the lock file");
    spdf_compat_lock_release(&lock);
    EXPECT(spdf_compat_lock_acquire(path, &again) == 1, "lock can be re-acquired after release");
    spdf_compat_lock_release(&again);
    EXPECT(spdf_compat_lock_acquire("", &lock) == 0, "an unusable lock path fails rather than blocking");
    EXPECT(spdf_compat_lock_acquire(path, NULL) == 0, "a NULL lock is rejected");

    spdf_compat_unlink(path);
    free(path);
}

/* ------------------------------------------------------ temp directories */

/* The four legacy core suites used to hardcode "/tmp/<name>.XXXXXX", a path
 * that does not exist on Windows at all, so they could not have run in the
 * guest even with mkdtemp() available. These cover the replacement. */
/* ------------------------------------------------------------- snprintf */

/* spdf_compat_snprintf_ok() is the predicate every path-composing call in
 * portable/core routes through, and it exists because the third arm of
 * snprintf's contract kept getting dropped. spdf_yaml.c's migration backup
 * path had it INVERTED -- `snprintf(...) < (int)sizeof(backup)` is true for a
 * negative return -- so an encoding error would have handed
 * spdf_compat_replace_file() an indeterminate buffer and renamed the user's
 * state file to whatever the stack happened to hold. The negative arm is what
 * these assertions are really for; the truncation and success arms are pinned
 * alongside it so a future "simplification" cannot restore the old expression
 * and still pass.
 *
 * Returns are passed as literals rather than by calling snprintf, because no
 * libc the app ships against can be made to return a negative value for the
 * `%s`-of-a-`char*` formats these callers use. That is precisely why the arm
 * has to be tested directly: it is unreachable from the outside, which is what
 * let it stay wrong. */
static void test_snprintf_ok(void) {
    EXPECT(spdf_compat_snprintf_ok(0, 1) == 1, "an empty string fits a one-byte buffer");
    EXPECT(spdf_compat_snprintf_ok(5, 16) == 1, "a short string in a large buffer is complete");
    EXPECT(spdf_compat_snprintf_ok(15, 16) == 1, "a string exactly filling the buffer with its NUL is complete");
    EXPECT(spdf_compat_snprintf_ok(16, 16) == 0, "a string whose NUL does not fit is truncation, not success");
    EXPECT(spdf_compat_snprintf_ok(17, 16) == 0, "an over-long string is truncation");
    EXPECT(spdf_compat_snprintf_ok(-1, 16) == 0, "an encoding error is NOT success");
    EXPECT(spdf_compat_snprintf_ok(-1, 1024) == 0, "an encoding error is not success at any capacity");
    EXPECT(spdf_compat_snprintf_ok(-2147483647 - 1, 1024) == 0, "the most negative return is not success");
    EXPECT(spdf_compat_snprintf_ok(0, 0) == 0, "a zero-byte buffer never holds a terminated string");
    EXPECT(spdf_compat_snprintf_ok(-1, 0) == 0, "a zero-byte buffer plus an encoding error is not success");
}

static void test_temp_template(void) {
    char buffer[SPDF_COMPAT_PATH_MAX];
    char tiny[8];
    size_t len;

    EXPECT(spdf_compat_temp_template(buffer, sizeof(buffer), "spdf-template-") == buffer, "template is produced");
    len = strlen(buffer);
    EXPECT(len > 6, "template is longer than its placeholder");
    EXPECT(strcmp(buffer + len - 6, "XXXXXX") == 0, "template ends in six placeholders");
    EXPECT(strstr(buffer, "spdf-template-") != NULL, "template carries the caller's prefix");
    EXPECT(spdf_compat_path_dir_len(buffer) > 0, "template names a directory to create in");
    /* No doubled separator when the temp root already ends in one. */
    EXPECT(strstr(buffer, SPDF_PATH_SEP_STR SPDF_PATH_SEP_STR) == NULL, "template has no doubled separator");
    EXPECT(spdf_compat_temp_template(tiny, sizeof(tiny), "far-too-long-a-prefix-") == NULL,
           "an overlong template is refused rather than truncated");
    EXPECT(spdf_compat_temp_template(NULL, 0, "x") == NULL, "a NULL buffer is refused");
}

static void test_make_and_remove_temp_dir(void) {
    char first[SPDF_COMPAT_PATH_MAX];
    char second[SPDF_COMPAT_PATH_MAX];
    char* probe;

    EXPECT(spdf_compat_make_temp_dir(first, sizeof(first), "spdf-dir-a.") == first, "temp directory created");
    EXPECT(spdf_compat_make_temp_dir(second, sizeof(second), "spdf-dir-a.") == second, "second temp directory");
    EXPECT(strcmp(first, second) != 0, "two runs get distinct directories");
    EXPECT(strstr(first, "XXXXXX") == NULL, "placeholders were substituted");

    probe = join(first, "inside.txt");
    EXPECT(probe && write_text(probe, "x"), "the created directory is writable");
    EXPECT(spdf_compat_rmdir(first) != 0, "a non-empty directory is not removed");
    if (probe) EXPECT(spdf_compat_unlink(probe) == 0, "probe file removed");
    free(probe);

    EXPECT(spdf_compat_rmdir(first) == 0, "an empty directory is removed");
    EXPECT(spdf_compat_rmdir(second) == 0, "the second directory is removed");
    EXPECT(spdf_compat_rmdir(first) != 0, "removing a directory twice fails");
}

/* --------------------------------------------------------------- timing */

static void test_monotonic_clock(void) {
    double first = spdf_compat_monotonic_ms();
    double second;
    volatile unsigned long spin = 0;
    unsigned long i;

    for (i = 0; i < 2000000UL; ++i) spin += i;
    second = spdf_compat_monotonic_ms();
    EXPECT(first > 0.0, "monotonic clock returns a positive reading");
    EXPECT(second >= first, "monotonic clock never runs backwards");
}

int main(void) {
    char* dir = make_scratch_dir();

    test_posix_path_regime();
    test_windows_path_regime();
    test_host_regime_matches_platform();
    test_snprintf_ok();
    test_temp_template();
    test_make_and_remove_temp_dir();
    test_monotonic_clock();

    if (!dir) {
        fprintf(stderr, "FAIL could not create a scratch directory\n");
        return 1;
    }
    test_replace_over_existing_destination(dir);
    test_replace_onto_missing_destination(dir);
    test_replace_reports_failure(dir);
    test_mkstemp_stays_in_directory(dir);
    test_file_mtime(dir);
    test_migration_lock(dir);

    /* Every file above is named and removed by the test that made it, so the
     * scratch directory itself is empty by now and can go. */
    EXPECT(spdf_compat_rmdir(dir) == 0, "scratch directory is empty and removable");
    free(dir);

    if (g_failures) {
        fprintf(stderr, "SPDFCoreCompatTests: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("SPDFCoreCompatTests: all checks passed\n");
    return 0;
}
