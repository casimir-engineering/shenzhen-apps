/* shell_test.c — the Open dialog's start-folder policy (spdf_win_shell.h).
 *
 * 26.8.31-1: "Cmd+O native picker (starts in the document's folder)". The rule
 * has three steps -- the current document's folder, else the folder of the most
 * recently opened document, else the user's home -- and every step is a string
 * decision that needs no dialog, so it is pinned here and the dialog only
 * receives the answer (spdf_win_menu_open_dialog_in). The Win32 half of
 * spdf_win_shell.cpp -- Explorer, the clipboard, the browser, a modal prompt --
 * cannot be asserted about without a desktop and is not compiled in.
 *
 * Header-only under test, so no `spdf-test-sources` line.
 */
#include "spdf_win_shell.h"

#include <stdio.h>
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

#define CHECK_STR(got, want)                                                                                           \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (strcmp((got), (want)) != 0) {                                                                              \
            printf("FAIL %s:%d: \"%s\" != \"%s\"\n", __FILE__, __LINE__, (got), (want));                               \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static void test_dir_of(void) {
    char out[64];
    CHECK(spdf_win_shell_dir_of("C:\\docs\\sub\\a.pdf", out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\sub");
    CHECK(spdf_win_shell_dir_of("C:/docs/a.pdf", out, sizeof(out)));
    CHECK_STR(out, "C:/docs");
    /* The root keeps its separator: "C:" alone is drive-relative, not the root. */
    CHECK(spdf_win_shell_dir_of("C:\\a.pdf", out, sizeof(out)));
    CHECK_STR(out, "C:\\");
    CHECK(spdf_win_shell_dir_of("\\a.pdf", out, sizeof(out)));
    CHECK_STR(out, "\\");
    CHECK(spdf_win_shell_dir_of("\\\\server\\share\\a.pdf", out, sizeof(out)));
    CHECK_STR(out, "\\\\server\\share");
    CHECK(!spdf_win_shell_dir_of("a.pdf", out, sizeof(out)));
    CHECK_STR(out, "");
    CHECK(!spdf_win_shell_dir_of("", out, sizeof(out)));
    CHECK(!spdf_win_shell_dir_of(NULL, out, sizeof(out)));
    CHECK(!spdf_win_shell_dir_of("C:\\docs\\a.pdf", out, 4)); /* does not fit */
    CHECK_STR(out, "");
    CHECK(!spdf_win_shell_dir_of("C:\\docs\\a.pdf", NULL, 0));
}

static void test_start_dir_policy(void) {
    char out[64];
    /* 1. The current document's folder wins. */
    CHECK(spdf_win_shell_open_start_dir("C:\\work\\spec.pdf", "D:\\old\\x.pdf", out, sizeof(out)));
    CHECK_STR(out, "C:\\work");
    /* 2. No document: the most recently opened one's folder. */
    CHECK(spdf_win_shell_open_start_dir(NULL, "D:\\old\\x.pdf", out, sizeof(out)));
    CHECK_STR(out, "D:\\old");
    CHECK(spdf_win_shell_open_start_dir("", "D:\\old\\x.pdf", out, sizeof(out)));
    CHECK_STR(out, "D:\\old");
    /* 3. Neither: 0 means "home", resolved by the caller with the shell. */
    CHECK(!spdf_win_shell_open_start_dir(NULL, NULL, out, sizeof(out)));
    CHECK_STR(out, "");
    CHECK(!spdf_win_shell_open_start_dir("", "", out, sizeof(out)));
    /* A bare file name has no folder and does not stop the fallback. */
    CHECK(spdf_win_shell_open_start_dir("spec.pdf", "D:\\old\\x.pdf", out, sizeof(out)));
    CHECK_STR(out, "D:\\old");
    CHECK(!spdf_win_shell_open_start_dir("spec.pdf", "x.pdf", out, sizeof(out)));
}

int main(void) {
    test_dir_of();
    test_start_dir_policy();
    printf("shell_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
