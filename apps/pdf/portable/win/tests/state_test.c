/* state_test.c — portable/win/src/spdf_win_state.{h,c} against the real,
 * shared portable/core/spdf_yaml.c codec.
 *
 * The thing worth proving is not that this module can serialize — it must not
 * serialize at all — but that it puts the SAME bytes on disk as the mac and GTK
 * frontends, and reads theirs back. So the fixture below is a verbatim
 * mac-written session.yaml, and the JSON round-trip is asserted against it.
 *
 * Native (macOS/Linux):
 *   cc -std=c99 -O2 -Wall -Wextra -Werror -Iportable/core \
 *      -o build/state_test portable/win/tests/state_test.c \
 *      portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c \
 *      portable/core/spdf_yaml.c
 *   ./build/state_test ; echo $?     # 0 = pass
 *
 * Guest (Windows/MSVC/ARM64) — needs T1's core compat shim in the link line,
 * because spdf_yaml.c's flock/getpid/rename/mtime calls now route through it:
 *   portable/win/vm-build.sh --run state_test \
 *      portable/win/tests/state_test.c portable/win/src/spdf_win_state.c \
 *      portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c \
 *      portable/core/spdf_win_compat.c
 *
 * Exit code is the whole signal: 0 pass, 1 fail.
 */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS /* fopen/getenv in the POSIX half of the harness */
#endif

#include "scratch_leaf.h" /* a scratch leaf unique to this process */
#include "../src/spdf_win_paths.h"
#include "../src/spdf_win_state.h"

#include "spdf_yaml.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;

static void check(int ok, const char* what) {
    if (!ok) {
        printf("FAIL: %s\n", what);
        g_failures++;
    }
}

static void check_str(const char* got, const char* want, const char* what) {
    if (!got || strcmp(got, want) != 0) {
        printf("FAIL: %s\n  got  \"%s\"\n  want \"%s\"\n", what, got ? got : "(null)", want);
        g_failures++;
    }
}

/* A session.yaml as the mac app writes it (sorted keys, double-quoted strings,
 * 2-space indent, the standard header comment), including a non-ASCII document
 * path — the case that fails when a Windows port routes state through the
 * narrow CRT instead of the UTF-16 APIs. */
static const char* const kMacSessionYaml =
    "# ShenzhenPDF session \xe2\x80\x94 edit while the app is closed\n"
    "windows:\n"
    "  - tabs:\n"
    "      - page: 12\n"
    "        path: \"/Users/rapha\xc3\xabl/Documents/rapport financi\xc3\xa8r.pdf\"\n"
    "        zoom: 1.25\n"
    "      - page: 1\n"
    "        path: \"/Users/rapha\xc3\xabl/Documents/\xe5\xbc\xa0\xe4\xbc\x9f.pdf\"\n"
    "        zoom: 1\n"
    "    selectedTab: 0\n"
    "    windowId: \"win-1\"\n";

/* The harness opens files independently of the module under test, but it must
 * still be UTF-16-correct: the scratch directory below carries a non-ASCII leaf
 * on purpose, and a narrow fopen() would fail on it under the process ANSI code
 * page — turning a passing module into a failing test. This is the same trap
 * the module itself avoids by never calling a narrow CRT file function. */
#if defined(_WIN32)
static FILE* open_native(const char* path, const char* mode) {
    char extended[SPDF_WIN_PATH_MAX];
    spdf_wchar wide_mode[8];
    spdf_wchar* wide_path;
    FILE* f;
    if (!spdf_win_path_to_extended(path, extended, sizeof(extended))) return NULL;
    if (spdf_win_utf16_from_utf8(mode, wide_mode, 8) == SPDF_WIN_CONV_ERROR) return NULL;
    wide_path = spdf_win_utf16_dup_from_utf8(extended);
    if (!wide_path) return NULL;
    f = _wfopen(wide_path, wide_mode);
    free(wide_path);
    return f;
}

static void remove_native(const char* path) {
    spdf_wchar* wide_path;
    char extended[SPDF_WIN_PATH_MAX];
    if (!spdf_win_path_to_extended(path, extended, sizeof(extended))) return;
    wide_path = spdf_win_utf16_dup_from_utf8(extended);
    if (!wide_path) return;
    _wremove(wide_path);
    free(wide_path);
}
#else
static FILE* open_native(const char* path, const char* mode) {
    char native[SPDF_WIN_PATH_MAX];
    if (!spdf_win_path_to_native(path, native, sizeof(native))) return NULL;
    return fopen(native, mode);
}

static void remove_native(const char* path) {
    char native[SPDF_WIN_PATH_MAX];
    if (spdf_win_path_to_native(path, native, sizeof(native))) remove(native);
}
#endif

static char* read_whole(const char* path) {
    long size;
    char* data;
    FILE* f = open_native(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    data = (char*)malloc((size_t)size + 1);
    if (!data) {
        fclose(f);
        return NULL;
    }
    if (fread(data, 1, (size_t)size, f) != (size_t)size) {
        fclose(f);
        free(data);
        return NULL;
    }
    fclose(f);
    data[size] = 0;
    return data;
}

static int write_whole(const char* path, const char* text) {
    size_t len = strlen(text);
    FILE* f = open_native(path, "wb");
    if (!f) return 0;
    if (fwrite(text, 1, len, f) != len) {
        fclose(f);
        return 0;
    }
    return fclose(f) == 0;
}

/* Reading a state file written by the mac app must yield the JSON the frontend
 * expects, non-ASCII paths intact. */
static void test_reads_a_mac_session(const char* dir) {
    char path[SPDF_WIN_PATH_MAX];
    char* json;

    check(spdf_win_path_join(dir, SPDF_WIN_STATE_SESSION, path, sizeof(path)), "session path");
    check(write_whole(path, kMacSessionYaml), "stage the mac-written session.yaml");

    json = spdf_win_state_read_json_at(path);
    check(json != NULL, "a mac-written session.yaml parses");
    if (json) {
        check(strstr(json, "\"windowId\":\"win-1\"") != NULL, "windowId survives");
        check(strstr(json, "\"selectedTab\":0") != NULL, "selectedTab survives");
        check(strstr(json, "\"zoom\":1.25") != NULL, "the zoom number is a verbatim token");
        check(strstr(json, "rapport financi\xc3\xa8r.pdf") != NULL,
              "a Latin-1-accented document path survives the read");
        check(strstr(json, "\xe5\xbc\xa0\xe4\xbc\x9f.pdf") != NULL,
              "a CJK document path survives the read");
        free(json);
    }
}

/* Write must go through the shared codec and produce exactly what the other
 * frontends produce: the standard header comment plus the codec's own emit. */
static void test_write_matches_the_shared_codec(const char* dir) {
    static const char* const json =
        "{\"markdownTheme\":\"obsidian\",\"recentLimit\":25,\"sidebarWidth\":260,\"viewMode\":1}";
    char path[SPDF_WIN_PATH_MAX];
    char header[128];
    char* expected;
    char* on_disk;
    char* back;

    check(spdf_win_path_join(dir, SPDF_WIN_STATE_SETTINGS, path, sizeof(path)), "settings path");
    check(spdf_win_state_write_json_at(path, json), "write settings");

    /* The reference is the codec called directly, with the header derived from
     * the bare file name — i.e. what ShenzhenPDFMac.mm writeStateObject:toFile:
     * would emit for the same object. */
    spdf_state_header_for_file(SPDF_WIN_STATE_SETTINGS, header, sizeof(header));
    expected = spdf_yaml_from_json(json, header);
    check(expected != NULL, "reference YAML");
    on_disk = read_whole(path);
    check(on_disk != NULL, "settings.yaml exists after the write");
    if (expected && on_disk) check_str(on_disk, expected, "written bytes match the shared codec");

    /* The header must name the file, not the path it happened to live at. */
    if (on_disk)
        check(strncmp(on_disk, "# ShenzhenPDF settings ", 23) == 0,
              "header comment is derived from the file name, not the full path");

    back = spdf_win_state_read_json_at(path);
    check_str(back, json, "JSON -> YAML -> JSON is lossless");

    free(expected);
    free(on_disk);
    free(back);
}

/* Every save after the first overwrites an existing file. On Windows a plain
 * rename() would fail here; this is the regression that guards MoveFileExW. */
static void test_overwrite_and_noop(const char* dir) {
    char path[SPDF_WIN_PATH_MAX];
    char* first;
    char* second;

    check(spdf_win_path_join(dir, SPDF_WIN_STATE_DOCUMENTS, path, sizeof(path)), "documents path");
    check(spdf_win_state_write_json_at(path, "{\"a\":{\"page\":1}}"), "first write");
    check(spdf_win_state_write_json_at(path, "{\"a\":{\"page\":2}}"),
          "second write replaces an existing file");
    first = spdf_win_state_read_json_at(path);
    check_str(first, "{\"a\":{\"page\":2}}", "the replacement won");

    /* A no-op save is skipped but still reports success. */
    check(spdf_win_state_write_json_at(path, "{\"a\":{\"page\":2}}"), "unchanged write succeeds");
    second = spdf_win_state_read_json_at(path);
    check_str(second, "{\"a\":{\"page\":2}}", "unchanged write left the file intact");

    /* No temp files are left behind by any of the above. */
    {
        char temp_glob[SPDF_WIN_PATH_MAX];
        char* leftover;
        check(spdf_win_path_join(dir, "documents.yaml.tmp.0", temp_glob, sizeof(temp_glob)), "tmp");
        leftover = read_whole(temp_glob);
        check(leftover == NULL, "no stray temp file with a zero pid");
        free(leftover);
    }
    free(first);
    free(second);
}

/* Corrupt / oversized / missing all behave as "absent", never as an error the
 * user sees, and never by deleting the file. */
static void test_unreadable_is_absent(const char* dir) {
    char path[SPDF_WIN_PATH_MAX];
    char* json;
    char* still_there;

    check(spdf_win_path_join(dir, SPDF_WIN_STATE_FAVORITES, path, sizeof(path)), "favorites path");
    check(write_whole(path, "windows:\n\t- tab: [unterminated\n"), "stage a corrupt file");
    json = spdf_win_state_read_json_at(path);
    check(json == NULL, "a corrupt state file reads as absent");
    free(json);
    still_there = read_whole(path);
    check(still_there != NULL, "a corrupt state file is left on disk, not deleted");
    free(still_there);

    {
        char missing[SPDF_WIN_PATH_MAX];
        check(spdf_win_path_join(dir, "does-not-exist.yaml", missing, sizeof(missing)), "missing");
        check(spdf_win_state_read_json_at(missing) == NULL, "a missing file reads as absent");
    }
    check(spdf_win_state_read_json_at(NULL) == NULL, "NULL path reads as absent");
    check(spdf_win_state_write_json_at(path, "not json at all") == 0,
          "unparseable JSON is refused rather than written");
}

/* The whole point of the module: the frontend never names a path itself. */
static void test_named_files_resolve_into_the_state_dir(const char* dir) {
    char* json;
    spdf_win_paths_set_state_dir_override(dir);
    check(spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS, "{\"viewMode\":1}"),
          "write by name into the state directory");
    json = spdf_win_state_read_json(SPDF_WIN_STATE_SETTINGS);
    check_str(json, "{\"viewMode\":1}", "read back by name");
    free(json);
    spdf_win_paths_set_state_dir_override(NULL);
}

/* The JSON -> YAML migration is the core's; this proves the delegation and the
 * stem list are wired correctly. */
static void test_migration_delegates_to_the_core(const char* dir) {
    char json_path[SPDF_WIN_PATH_MAX];
    char yaml_path[SPDF_WIN_PATH_MAX];
    char* migrated;

    check(spdf_win_path_join(dir, "session.json", json_path, sizeof(json_path)), "legacy path");
    check(spdf_win_path_join(dir, SPDF_WIN_STATE_SESSION, yaml_path, sizeof(yaml_path)), "y");
    check(write_whole(json_path, "{\"windows\":[{\"windowId\":\"legacy\"}]}"), "stage legacy JSON");
    remove_native(yaml_path); /* an existing YAML file legitimately wins */

    check(spdf_win_state_migrate(dir) == 1, "exactly one file migrated");
    migrated = spdf_win_state_read_json_at(yaml_path);
    check_str(migrated, "{\"windows\":[{\"windowId\":\"legacy\"}]}", "migrated content matches");
    free(migrated);

    check(spdf_win_state_migrate(dir) == 0, "migration is idempotent");
    check(spdf_win_state_migrate("") == -1, "an empty directory is refused");
}

/* And the same migration in a directory whose name is not ASCII. This is a
 * separate case because it exercises somebody else's code: the core composes
 * "<dir>/<stem>.json" and opens it itself, so it has to be UTF-8-correct on
 * Windows independently of anything this module does. It is (T1's
 * spdf_compat_fopen routes through MultiByteToWideChar + _wfopen); asserting it
 * here means a regression there surfaces as a state-layer failure rather than
 * as a user under a non-ASCII profile silently losing their pre-YAML state. */
static void test_migration_under_a_non_ascii_directory(const char* dir) {
    char json_path[SPDF_WIN_PATH_MAX];
    char yaml_path[SPDF_WIN_PATH_MAX];
    char* migrated;

    check(spdf_win_path_join(dir, "documents.json", json_path, sizeof(json_path)), "legacy path");
    check(spdf_win_path_join(dir, SPDF_WIN_STATE_DOCUMENTS, yaml_path, sizeof(yaml_path)), "y");
    check(write_whole(json_path, "{\"a\":{\"page\":3}}"), "stage legacy JSON, non-ASCII dir");
    remove_native(yaml_path);

    check(spdf_win_state_migrate(dir) == 1, "one file migrated under a non-ASCII directory");
    migrated = spdf_win_state_read_json_at(yaml_path);
    check_str(migrated, "{\"a\":{\"page\":3}}", "migrated content matches, non-ASCII dir");
    free(migrated);
}

/* session.lock exists so the per-window processes can merge session.yaml. */
static void test_session_lock(const char* dir) {
    spdf_win_state_session_lock* lock = spdf_win_state_session_lock_acquire(dir);
    char probe[SPDF_WIN_PATH_MAX];
    char* contents;

    check(lock != NULL, "session lock acquired");
    check(spdf_win_path_join(dir, "session.lock", probe, sizeof(probe)), "lock path");
    contents = read_whole(probe);
    check(contents != NULL, "session.lock was created next to session.yaml");
    free(contents);
    spdf_win_state_session_lock_release(lock);
    /* Releasing then re-acquiring in the same process must not deadlock. */
    lock = spdf_win_state_session_lock_acquire(dir);
    check(lock != NULL, "session lock re-acquired after release");
    spdf_win_state_session_lock_release(lock);
    spdf_win_state_session_lock_release(NULL); /* must be a no-op */
}

int main(int argc, char** argv) {
    char dir[SPDF_WIN_PATH_MAX];
    char ascii_dir[SPDF_WIN_PATH_MAX];

    printf("spdf_win_state tests\n");
    if (!spdf_test_state_dir(argc, argv, "spdf_state_test", SPDF_TEST_SCRATCH_STEM, dir, sizeof(dir)) ||
        !spdf_test_state_dir(argc, argv, "spdf_state_test", "ascii", ascii_dir, sizeof(ascii_dir))) {
        printf("FAIL: could not create the scratch directories\n");
        return 1;
    }
    if (!spdf_win_paths_ensure_dir(dir) || !spdf_win_paths_ensure_dir(ascii_dir)) {
        return 1;
    }

    test_reads_a_mac_session(dir);
    test_write_matches_the_shared_codec(dir);
    test_overwrite_and_noop(dir);
    test_unreadable_is_absent(dir);
    test_named_files_resolve_into_the_state_dir(dir);
    test_migration_delegates_to_the_core(ascii_dir);
    test_migration_under_a_non_ascii_directory(dir);
    test_session_lock(dir);

    if (g_failures) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
