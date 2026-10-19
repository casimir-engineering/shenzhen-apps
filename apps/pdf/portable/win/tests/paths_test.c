/* paths_test.c — portable/win/src/spdf_win_paths.{h,c}.
 *
 * Everything here runs natively on macOS, which is the point: the UTF-8/UTF-16
 * converter and the path composer are the code that ships on Windows, not a
 * portable stand-in for it, so a mojibake bug is caught on the host rather than
 * discovered on a Windows machine with a non-ASCII user name.
 *
 * Native (macOS/Linux):
 *   cc -std=c99 -O2 -Wall -Wextra -Werror \
 *      -o build/paths_test portable/win/tests/paths_test.c portable/win/src/spdf_win_paths.c
 *   ./build/paths_test ; echo $?     # 0 = pass
 *
 * Guest (Windows/MSVC/ARM64), which additionally exercises SHGetKnownFolderPath
 * and CreateDirectoryW:
 *   portable/win/vm-build.sh --run paths_test \
 *      portable/win/tests/paths_test.c portable/win/src/spdf_win_paths.c
 *
 * Exit code is the whole signal: 0 pass, 1 fail. Do not judge this by grepping
 * the output.
 */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS /* getenv, for the scratch directory */
#endif

#include "../src/spdf_win_paths.h"

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

/* --- UTF-16 <-> UTF-8 ---------------------------------------------------- */

/* The non-ASCII user names that actually break Windows ports, one per class:
 * Latin-1 accents (2-byte UTF-8), CJK (3-byte), Cyrillic (2-byte), and an
 * astral-plane emoji (4-byte UTF-8 / a UTF-16 surrogate pair). A profile
 * directory really can contain any of these. */
static void test_roundtrip_non_ascii(void) {
    static const char* const names[] = {
        "Raphael",
        "Rapha\xc3\xabl",               /* Raphaël, U+00EB */
        "Ren\xc3\xa9 M\xc3\xbcller",   /* René Müller */
        "\xe5\xbc\xa0\xe4\xbc\x9f",    /* 张伟 */
        "\xd0\x94\xd0\xbc\xd0\xb8\xd1\x82\xd1\x80\xd0\xb8\xd0\xb9", /* Дмитрий */
        "\xf0\x9f\x93\x84 docs",       /* U+1F4C4, a surrogate pair in UTF-16 */
    };
    size_t i;

    for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        spdf_wchar wide[128];
        char back[256];
        char path[512];
        char roundtrip[512];
        size_t units, bytes;

        units = spdf_win_utf16_from_utf8(names[i], wide, 128);
        check(units != SPDF_WIN_CONV_ERROR, "utf8 -> utf16 of a real user name");
        bytes = spdf_win_utf8_from_utf16(wide, back, sizeof(back));
        check(bytes != SPDF_WIN_CONV_ERROR, "utf16 -> utf8 back");
        check_str(back, names[i], "UTF-8 -> UTF-16 -> UTF-8 is lossless");
        check(bytes == strlen(names[i]), "byte count matches");

        /* And the same through a full composed state path, which is where the
         * conversion is actually used. */
        check(spdf_win_path_join("C:\\Users", names[i], path, sizeof(path)),
              "join a non-ASCII profile name");
        units = spdf_win_utf16_from_utf8(path, wide, 128);
        check(units != SPDF_WIN_CONV_ERROR, "widen the composed path");
        check(spdf_win_utf8_from_utf16(wide, roundtrip, sizeof(roundtrip)) != SPDF_WIN_CONV_ERROR,
              "narrow the composed path");
        check_str(roundtrip, path, "composed non-ASCII path survives the boundary");
    }

    /* The surrogate pair really is a pair, not two lone units. */
    {
        spdf_wchar wide[16];
        check(spdf_win_utf16_from_utf8("\xf0\x9f\x93\x84", wide, 16) == 2,
              "U+1F4C4 is two UTF-16 code units");
        check(wide[0] == 0xD83D && wide[1] == 0xDCC4, "surrogate pair values");
    }
}

static void test_conversion_is_strict(void) {
    spdf_wchar wide[16];
    char narrow[16];
    static const spdf_wchar lone_high[] = {0xD83D, 0};
    static const spdf_wchar lone_low[] = {0xDCC4, 0};
    static const spdf_wchar high_then_ascii[] = {0xD83D, 'a', 0};

    check(spdf_win_utf16_from_utf8("\xC0\xAF", wide, 16) == SPDF_WIN_CONV_ERROR,
          "overlong 2-byte form rejected");
    check(spdf_win_utf16_from_utf8("\xE0\x80\xAF", wide, 16) == SPDF_WIN_CONV_ERROR,
          "overlong 3-byte form rejected");
    check(spdf_win_utf16_from_utf8("\xED\xA0\xBD", wide, 16) == SPDF_WIN_CONV_ERROR,
          "CESU-8 surrogate rejected");
    check(spdf_win_utf16_from_utf8("\xF5\x80\x80\x80", wide, 16) == SPDF_WIN_CONV_ERROR,
          "scalar above U+10FFFF rejected");
    check(spdf_win_utf16_from_utf8("\xE4\xBC", wide, 16) == SPDF_WIN_CONV_ERROR,
          "truncated sequence rejected");
    check(spdf_win_utf16_from_utf8("\x80\x80", wide, 16) == SPDF_WIN_CONV_ERROR,
          "continuation byte in lead position rejected");

    check(spdf_win_utf8_from_utf16(lone_high, narrow, sizeof(narrow)) == SPDF_WIN_CONV_ERROR,
          "trailing unpaired high surrogate rejected");
    check(spdf_win_utf8_from_utf16(lone_low, narrow, sizeof(narrow)) == SPDF_WIN_CONV_ERROR,
          "leading low surrogate rejected");
    check(spdf_win_utf8_from_utf16(high_then_ascii, narrow, sizeof(narrow)) == SPDF_WIN_CONV_ERROR,
          "high surrogate followed by a non-surrogate rejected");

    /* Bounds: never truncate, always report. */
    check(spdf_win_utf16_from_utf8("abcdef", wide, 4) == SPDF_WIN_CONV_ERROR,
          "utf16 output overflow reported, not truncated");
    check(spdf_win_utf8_from_utf16(lone_high, narrow, 0) == SPDF_WIN_CONV_ERROR,
          "zero-size output reported");
    check(spdf_win_utf16_from_utf8("", wide, 4) == 0 && wide[0] == 0, "empty string");
}

static void test_allocating_variants(void) {
    static const spdf_wchar wide[] = {0x5F20, 0x4F1F, 0};
    char* utf8 = spdf_win_utf8_dup_from_utf16(wide);
    spdf_wchar* back;

    check_str(utf8, "\xe5\xbc\xa0\xe4\xbc\x9f", "dup utf16 -> utf8");
    back = spdf_win_utf16_dup_from_utf8(utf8 ? utf8 : "");
    check(back && back[0] == 0x5F20 && back[1] == 0x4F1F && back[2] == 0, "dup utf8 -> utf16");
    check(spdf_win_utf16_dup_from_utf8("\xC0\xAF") == NULL, "dup rejects malformed UTF-8");
    free(utf8);
    free(back);
}

/* --- path composition ---------------------------------------------------- */

static void test_join(void) {
    char out[64];

    check(spdf_win_path_join("C:\\Users\\bob", "settings.yaml", out, sizeof(out)), "join");
    check_str(out, "C:\\Users\\bob\\settings.yaml", "plain join");

    check(spdf_win_path_join("C:\\Users\\bob\\", "settings.yaml", out, sizeof(out)), "join");
    check_str(out, "C:\\Users\\bob\\settings.yaml", "trailing separator not doubled");

    check(spdf_win_path_join("C:\\Users\\bob", "\\settings.yaml", out, sizeof(out)), "join");
    check_str(out, "C:\\Users\\bob\\settings.yaml", "leading separator not doubled");

    check(spdf_win_path_join("C:/Users/bob", "settings.yaml", out, sizeof(out)), "join");
    check_str(out, "C:\\Users\\bob\\settings.yaml", "forward slashes normalised");

    check(spdf_win_path_join("", "settings.yaml", out, sizeof(out)), "join");
    check_str(out, "settings.yaml", "empty dir yields the name alone");

    check(spdf_win_path_join("C:\\Users\\bob", "a.yaml", out, 12) == 0,
          "overflow refused, not truncated");
}

static void test_root_len(void) {
    check(spdf_win_path_root_len("C:\\dir\\f") == 3, "drive root");
    check(spdf_win_path_root_len("c:/dir") == 3, "drive root, forward slash");
    check(spdf_win_path_root_len("C:file") == 2, "drive-relative root");
    check(spdf_win_path_root_len("\\dir") == 1, "rooted, no drive");
    check(spdf_win_path_root_len("\\\\srv\\share\\f") == 12, "UNC root");
    check(spdf_win_path_root_len("\\\\srv\\share") == 11, "UNC root, no trailing separator");
    check(spdf_win_path_root_len("\\\\srv") == 0, "incomplete UNC has no root");
    check(spdf_win_path_root_len("\\\\?\\C:\\d") == 7, "extended drive root");
    check(spdf_win_path_root_len("\\\\?\\UNC\\srv\\share\\f") == 18, "extended UNC root");
    check(spdf_win_path_root_len("dir\\f") == 0, "relative");
    check(spdf_win_path_root_len("") == 0, "empty");

    check(spdf_win_path_is_absolute("C:\\d"), "drive path is absolute");
    check(spdf_win_path_is_absolute("\\\\srv\\share\\f"), "UNC path is absolute");
    check(!spdf_win_path_is_absolute("dir\\f"), "relative path is not absolute");
    check(!spdf_win_path_is_absolute("C:f"), "drive-relative path is not absolute");
}

static void test_extended(void) {
    char out[128];

    check(spdf_win_path_to_extended("C:\\Users\\bob\\a.yaml", out, sizeof(out)), "extend drive");
    check_str(out, "\\\\?\\C:\\Users\\bob\\a.yaml", "drive path gains the prefix");

    check(spdf_win_path_to_extended("\\\\srv\\share\\a.yaml", out, sizeof(out)), "extend UNC");
    check_str(out, "\\\\?\\UNC\\srv\\share\\a.yaml", "UNC path gains the UNC prefix");

    check(spdf_win_path_to_extended("\\\\?\\C:\\a", out, sizeof(out)), "already extended");
    check_str(out, "\\\\?\\C:\\a", "an extended path is not double-prefixed");

    check(spdf_win_path_to_extended("rel\\a", out, sizeof(out)), "relative");
    check_str(out, "rel\\a", "a relative path passes through");

    check(spdf_win_path_to_extended("C:/Users/bob/a", out, sizeof(out)), "extend + normalise");
    check_str(out, "\\\\?\\C:\\Users\\bob\\a", "forward slashes normalised while extending");

    check(spdf_win_path_to_extended("C:\\Users\\bob\\a", out, 8) == 0, "overflow refused");
}

/* MAX_PATH is 260; the prefix is what makes a path beyond it openable at all,
 * so prove the composer actually gets there. */
static void test_long_path(void) {
    char deep[SPDF_WIN_PATH_MAX];
    char out[SPDF_WIN_PATH_MAX];
    spdf_wchar wide[SPDF_WIN_PATH_MAX];
    size_t i, len = 0;

    len += (size_t)snprintf(deep, sizeof(deep), "C:\\Users\\Raphael");
    for (i = 0; i < 40; i++) len += (size_t)snprintf(deep + len, sizeof(deep) - len, "\\a_directory_component");
    len += (size_t)snprintf(deep + len, sizeof(deep) - len, "\\settings.yaml");
    check(len > 260, "the fixture really is longer than MAX_PATH");

    check(spdf_win_path_to_extended(deep, out, sizeof(out)), "extend a >MAX_PATH path");
    check(strncmp(out, "\\\\?\\C:\\", 7) == 0, "long path carries the extended prefix");
    check(strlen(out) == len + 4, "extending adds exactly the four prefix bytes");
    check(spdf_win_utf16_from_utf8(out, wide, SPDF_WIN_PATH_MAX) == strlen(out),
          "the long path widens for CreateFileW");
}

static void test_basename(void) {
    check_str(spdf_win_path_basename("C:\\Users\\bob\\settings.yaml"), "settings.yaml",
              "basename splits on backslash");
    check_str(spdf_win_path_basename("/home/bob/settings.yaml"), "settings.yaml",
              "basename splits on forward slash");
    check_str(spdf_win_path_basename("settings.yaml"), "settings.yaml", "bare name");
    check_str(spdf_win_path_basename("C:\\dir\\"), "", "trailing separator yields empty");
}

/* --- the state directory ------------------------------------------------- */

static void test_state_dir_composition(void) {
    char out[SPDF_WIN_PATH_MAX];

    check(spdf_win_paths_state_dir_in("C:\\Users\\bob\\AppData\\Roaming", out, sizeof(out)),
          "compose state dir");
    check_str(out, "C:\\Users\\bob\\AppData\\Roaming\\ShenzhenPDF",
              "%APPDATA%\\ShenzhenPDF, matching the mac support directory name");

    /* The failure that matters: a roaming folder under a non-ASCII profile. */
    check(spdf_win_paths_state_dir_in("C:\\Users\\Rapha\xc3\xabl\\AppData\\Roaming", out, sizeof(out)),
          "compose state dir under a non-ASCII profile");
    check_str(out, "C:\\Users\\Rapha\xc3\xabl\\AppData\\Roaming\\ShenzhenPDF",
              "non-ASCII profile name is preserved verbatim");

    check(spdf_win_paths_state_dir_in("", out, sizeof(out)) == 0, "empty roaming dir refused");
    check(spdf_win_paths_state_dir_in("C:\\Users\\bob\\AppData\\Roaming", out, 10) == 0,
          "state dir overflow refused");
}

/* Creates a real directory tree and a real file path through the same code the
 * app uses. On Windows this exercises CreateDirectoryW on an extended path. */
static void test_state_dir_creation(const char* scratch) {
    char base[SPDF_WIN_PATH_MAX];
    char dir[SPDF_WIN_PATH_MAX];
    char file[SPDF_WIN_PATH_MAX];
    char expected[SPDF_WIN_PATH_MAX];

    check(spdf_win_path_join(scratch, "nested\\deeper", base, sizeof(base)), "scratch base");
    check(spdf_win_paths_state_dir_in(base, expected, sizeof(expected)), "expected state dir");

    spdf_win_paths_set_state_dir_override(expected);
    check(spdf_win_paths_state_dir(dir, sizeof(dir)), "resolve + create the state directory");
    check_str(dir, expected, "the override is what gets returned");
    /* mkdir -p really ran: a second call is a no-op and still succeeds. */
    check(spdf_win_paths_state_dir(dir, sizeof(dir)), "state directory creation is idempotent");

    check(spdf_win_paths_state_file("settings.yaml", file, sizeof(file)), "state file path");
    check(strlen(file) == strlen(expected) + strlen("\\settings.yaml"), "state file path length");
    check(strcmp(spdf_win_path_basename(file), "settings.yaml") == 0, "state file basename");

    spdf_win_paths_set_state_dir_override(NULL);
}

/* The real thing, guest-only: SHGetKnownFolderPath(FOLDERID_RoamingAppData)
 * rather than the %APPDATA% environment variable, which is spoofable and is
 * simply absent in the SYSTEM session `prlctl exec` runs in — so this assertion
 * is exactly what a getenv-based implementation would fail. The directory it
 * creates is the app's own %APPDATA%\ShenzhenPDF. */
static void test_real_known_folder(void) {
#if defined(_WIN32)
    char dir[SPDF_WIN_PATH_MAX];
    size_t len, suffix = strlen("\\" SPDF_WIN_APP_DIR_NAME);

    check(spdf_win_paths_state_dir(dir, sizeof(dir)), "SHGetKnownFolderPath resolved the state dir");
    len = strlen(dir);
    check(spdf_win_path_is_absolute(dir), "the resolved state dir is an absolute path");
    check(len > suffix && strcmp(dir + len - suffix, "\\" SPDF_WIN_APP_DIR_NAME) == 0,
          "the resolved state dir ends in \\ShenzhenPDF");
    printf("note: resolved state directory %s\n", dir);
#endif
}

int main(int argc, char** argv) {
    const char* scratch = argc > 1 ? argv[1] : NULL;

    printf("spdf_win_paths tests\n");
    test_roundtrip_non_ascii();
    test_conversion_is_strict();
    test_allocating_variants();
    test_join();
    test_root_len();
    test_extended();
    test_long_path();
    test_basename();
    test_state_dir_composition();
    test_real_known_folder();

    if (!scratch) {
#if defined(_WIN32)
        scratch = getenv("TEMP");
#else
        scratch = getenv("TMPDIR");
#endif
    }
    if (scratch && *scratch) {
        char root[SPDF_WIN_PATH_MAX];
        if (spdf_win_path_join(scratch, "spdf_paths_test", root, sizeof(root)))
            test_state_dir_creation(root);
    } else {
        printf("note: no scratch directory, skipped directory creation\n");
    }

    if (g_failures) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
