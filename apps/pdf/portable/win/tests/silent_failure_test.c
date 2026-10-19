/* silent_failure_test.c — the three "plausible wrong answer instead of an
 * error" defects QC recorded as F5, F6 and F7, each pinned by an assertion that
 * fails against the code as it was.
 *
 * Every check here is about a WRONG ANSWER, never a missing feature:
 *
 *   F7  a state file that could not be READ must not be reported as a state
 *       file that is not THERE, because the next save then writes defaults over
 *       the user's real settings, session and recent-files list, and reports
 *       success while doing it.
 *   F6  CreateDirectoryW answers ERROR_ALREADY_EXISTS for a plain FILE sitting
 *       at the directory's name. Reading that as "the directory exists" hands
 *       back a state directory that is not a directory.
 *   F5  spdf_compat_mkstemp() used the narrow _mktemp_s/_sopen_s on UTF-8
 *       bytes, so saving an edited PDF from a directory outside the machine's
 *       ANSI code page fails or lands somewhere else.
 *
 * COMPILES AGAINST BOTH HEADERS ON PURPOSE. The status assertions are guarded
 * by SPDF_WIN_STATE_HAS_READ_STATUS so this file also builds against the
 * pre-fix spdf_win_state.h; the behavioural assertions around them use only the
 * long-standing API, so a pre-fix build compiles, runs, and FAILS. That is the
 * demonstration, and it is why the guard is here rather than a hard #include.
 *
 * Harness plumbing lives in silent_failure_support.h.
 *
 * Native (macOS/Linux):
 *   cc -std=c99 -O2 -Wall -Wextra -Werror -Iportable/core \
 *      -o build/silent_failure_test portable/win/tests/silent_failure_test.c \
 *      portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c \
 *      portable/core/spdf_yaml.c
 *   ./build/silent_failure_test ; echo $?     # 0 = pass
 *
 * Guest (Windows/MSVC/ARM64), or just portable/win/tests/t7-verify.sh:
 *   portable/win/vm-build.sh --run silent_failure_test \
 *      portable/win/tests/silent_failure_test.c portable/win/src/spdf_win_state.c \
 *      portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c \
 *      portable/core/spdf_win_compat.c
 *
 * Exit code is the whole signal: 0 pass, 1 fail.
 */
/* spdf-test-sources: portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS /* getenv/fopen in the POSIX half of the harness */
#endif

#include "silent_failure_support.h"

#include "../src/spdf_win_state.h"

#include "spdf_win_compat.h"

/* --- F7: unreadable is not absent, and must not be overwritten ------------ */

static const char* const kRealSettings = "{\"recentFiles\":[\"/Users/a.pdf\"],\"zoom\":1.25}";
static const char* const kDefaults = "{\"zoom\":1}";

static void test_unreadable_state_survives_the_next_save(const char* dir) {
    char path[SPDF_WIN_PATH_MAX];
    unreadable_guard guard;
    char* before;
    char* after;
    int wrote;

    if (!spdf_win_path_join(dir, "settings.yaml", path, sizeof(path))) {
        check(0, "F7: compose the settings path");
        return;
    }
    remove_file(path);
    if (!spdf_win_state_write_json_at(path, kRealSettings)) {
        check(0, "F7: seed a real settings.yaml");
        return;
    }
    before = read_whole(path);
    check(before != NULL && strstr(before, "recentFiles") != NULL,
          "F7: the seeded settings.yaml holds the user's recent files");

    if (!make_unreadable(path, &guard)) {
        note("F7 SKIPPED: this environment would not deny a read (root? exotic filesystem?)");
        free(before);
        remove_file(path);
        return;
    }

#ifdef SPDF_WIN_STATE_HAS_READ_STATUS
    {
        spdf_win_state_read_status status = SPDF_WIN_STATE_READ_OK;
        char* json = spdf_win_state_read_json_at_checked(path, &status);
        check(json == NULL, "F7: an unreadable file yields no JSON");
        check(status == SPDF_WIN_STATE_READ_FAILED,
              "F7: an unreadable file reports READ_FAILED, not READ_ABSENT");
        free(json);
    }
#else
    note("F7: pre-fix header — no read status to check; the overwrite assertion below is the test");
#endif

    /* THE ASSERTION. Pre-fix this returns 1 after replacing the user's file
     * with defaults; the loss is silent and permanent. */
    wrote = spdf_win_state_write_json_at(path, kDefaults);
    check(wrote == 0, "F7: a save refuses to run while the existing state is unreadable");

    make_readable(path, &guard);
    after = read_whole(path);
    check(after != NULL, "F7: the settings file is still there afterwards");
    check(after != NULL && strstr(after, "recentFiles") != NULL,
          "F7: the user's recent files survived the save attempt");
    check(after != NULL && before != NULL && strcmp(after, before) == 0,
          "F7: the settings file is byte-for-byte what it was");
    free(before);
    free(after);
    remove_file(path);
}

/* A genuinely absent file must still read as absent and still be creatable —
 * the fix must not turn "you have no settings yet" into a refusal to save. */
static void test_absent_state_still_saves(const char* dir) {
    char path[SPDF_WIN_PATH_MAX];
    char* json;

    if (!spdf_win_path_join(dir, "documents.yaml", path, sizeof(path))) {
        check(0, "F7: compose the documents path");
        return;
    }
    remove_file(path);
#ifdef SPDF_WIN_STATE_HAS_READ_STATUS
    {
        spdf_win_state_read_status status = SPDF_WIN_STATE_READ_OK;
        json = spdf_win_state_read_json_at_checked(path, &status);
        check(json == NULL, "F7: a missing file yields no JSON");
        check(status == SPDF_WIN_STATE_READ_ABSENT, "F7: a missing file reports READ_ABSENT");
        free(json);
    }
#endif
    check(spdf_win_state_write_json_at(path, kRealSettings) == 1,
          "F7: a first save into an empty state directory still succeeds");
    json = read_whole(path);
    check(json != NULL && strstr(json, "recentFiles") != NULL, "F7: that save reached the disk");
    free(json);
    remove_file(path);
}

/* Corrupt CONTENT keeps the inherited policy: absent, defaults apply, and the
 * file is rewritten rather than preserved forever. The fix must not widen the
 * "refuse to write" rule to cover it. */
static void test_corrupt_content_is_still_absent(const char* dir) {
    char path[SPDF_WIN_PATH_MAX];
    char* json;

    if (!spdf_win_path_join(dir, "favorites.yaml", path, sizeof(path))) {
        check(0, "F7: compose the favorites path");
        return;
    }
    /* What a truncated write leaves behind: the header comment and nothing
     * else. spdf_json_from_yaml() rejects it, which is the corrupt-content
     * case, NOT an IO failure. */
    check(write_whole(path, "# ShenzhenPDF favorites \xe2\x80\x94 edit while the app is closed\n"),
          "F7: seed an unparseable favorites.yaml");
#ifdef SPDF_WIN_STATE_HAS_READ_STATUS
    {
        spdf_win_state_read_status status = SPDF_WIN_STATE_READ_OK;
        json = spdf_win_state_read_json_at_checked(path, &status);
        check(status != SPDF_WIN_STATE_READ_FAILED,
              "F7: unparseable content is not reported as an IO failure");
        free(json);
    }
#endif
    check(spdf_win_state_write_json_at(path, kRealSettings) == 1,
          "F7: a corrupt state file is still replaced, as mac and GTK do");
    json = read_whole(path);
    check(json != NULL && strstr(json, "recentFiles") != NULL,
          "F7: the replacement reached the disk");
    free(json);
    remove_file(path);
}

/* --- F6: a file squatting on the state directory's name ------------------- */

static void test_file_in_the_state_directorys_place(const char* dir) {
    char blocked[SPDF_WIN_PATH_MAX];
    char resolved[SPDF_WIN_PATH_MAX];
    char* content;

    if (!spdf_win_path_join(dir, "blocked-state-dir", blocked, sizeof(blocked))) {
        check(0, "F6: compose the blocked path");
        return;
    }
    remove_file(blocked);
    if (!write_whole(blocked, "this is a file, not a directory\n")) {
        check(0, "F6: place a file where the state directory should go");
        return;
    }

    check(spdf_win_paths_ensure_dir(blocked) == 0,
          "F6: ensure_dir fails when a FILE occupies the directory name");

    spdf_win_paths_set_state_dir_override(blocked);
    check(spdf_win_paths_state_dir(resolved, sizeof(resolved)) == 0,
          "F6: state_dir fails rather than returning a path that is not a directory");
    check(spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS, kRealSettings) == 0,
          "F6: a save through the blocked state directory reports failure");
    spdf_win_paths_set_state_dir_override(NULL);

    content = read_whole(blocked);
    check(content != NULL && strstr(content, "not a directory") != NULL,
          "F6: the file that was in the way is untouched");
    free(content);
    remove_file(blocked);
}

/* --- F5: mkstemp outside the ANSI code page ------------------------------- */

/* "Ωмега-日本語": Greek, Cyrillic and Japanese, none of which CP1252 — the
 * reference guest's measured ANSI code page — can represent. "Raphaël" would
 * NOT do here: every character in it is in CP1252, which is exactly why the
 * narrow shim passed the earlier non-ASCII checks and still lost this one. */
#define NON_ANSI_DIR "\xce\xa9\xd0\xbc\xd0\xb5\xd0\xb3\xd0\xb0-\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"

static void test_mkstemp_outside_the_ansi_code_page(const char* base) {
    char dir[SPDF_WIN_PATH_MAX];
    char joined[SPDF_WIN_PATH_MAX];
    char tmpl[SPDF_COMPAT_PATH_MAX];
    char kept[SPDF_COMPAT_PATH_MAX];
    size_t len;
    int fd;

    if (!spdf_win_path_join(base, NON_ANSI_DIR, dir, sizeof(dir))) {
        check(0, "F5: compose the non-CP1252 directory path");
        return;
    }
    if (!spdf_win_paths_ensure_dir(dir)) {
        check(0, "F5: create the non-CP1252 directory (UTF-16 path, so this must work)");
        return;
    }
    /* The same shape create_temp_save_path() builds beside the user's PDF.
     * Reduced to the host's own separators afterwards, because mkstemp() is a
     * host call: on macOS a '\' is an ordinary filename character and the whole
     * composed path would become one leaf. */
    if (!spdf_win_path_join(dir, ".shenzhenpdf-save-XXXXXX", joined, sizeof(joined)) ||
        !spdf_win_path_to_native(joined, tmpl, sizeof(tmpl))) {
        check(0, "F5: compose the temp template");
        return;
    }
    len = strlen(tmpl);
    memcpy(kept, tmpl, len + 1);

    fd = spdf_compat_mkstemp(tmpl);
    check(fd >= 0, "F5: mkstemp succeeds in a directory outside the ANSI code page");
    if (fd < 0) return;
    check(spdf_compat_close(fd) == 0, "F5: the descriptor closes");

    check(strlen(tmpl) == len, "F5: the template kept its length");
    check(memcmp(tmpl, kept, len - 6) == 0,
          "F5: only the six placeholders changed — the directory part is intact");
    check(memcmp(tmpl + len - 6, "XXXXXX", 6) != 0, "F5: the placeholders were filled in");
    /* The one that catches a narrow create: the file must exist at the path the
     * caller is now holding, not at some ANSI-decoded neighbour of it. */
    check(path_exists(tmpl), "F5: the temp file exists at the UTF-8 path mkstemp reported");

    check(spdf_compat_unlink(tmpl) == 0, "F5: the temp file is removable by that same path");
    check(!path_exists(tmpl), "F5: and it is gone");
}

/* --- drive ---------------------------------------------------------------- */

int main(int argc, char** argv) {
    char scratch[SPDF_WIN_PATH_MAX];
    char dir[SPDF_WIN_PATH_MAX];
    const char* base = argc > 1 ? argv[1] : NULL;

    printf("silent-failure regression tests (F5, F6, F7)\n");
    if (!base || !*base) {
#if defined(_WIN32)
        base = getenv("TEMP");
#else
        base = getenv("TMPDIR");
#endif
    }
    if (!base || !*base) base = ".";
    if (!spdf_win_path_join(base, "spdf_silent_failure_test", scratch, sizeof(scratch))) return 1;
    /* The proven non-ASCII scratch pattern. Note this leaf IS representable in
     * CP1252; the F5 case deliberately goes further. */
    if (!spdf_win_path_join(scratch, "Rapha\xc3\xabl", dir, sizeof(dir))) return 1;
    if (!spdf_win_paths_ensure_dir(dir)) {
        printf("FAIL: could not create the scratch directory under %s\n", scratch);
        return 1;
    }

    test_unreadable_state_survives_the_next_save(dir);
    test_absent_state_still_saves(dir);
    test_corrupt_content_is_still_absent(dir);
    test_file_in_the_state_directorys_place(dir);
    test_mkstemp_outside_the_ansi_code_page(dir);

    if (g_failures) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
