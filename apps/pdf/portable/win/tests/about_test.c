/* about_test.c — the About box's text, and the identity constants it shares
 * with the version resource and the updater.
 *
 * What would go wrong without it: the About box saying one version while the
 * exe's Properties sheet says another and the updater compares a third. All
 * three read spdf_win_about_version.h, and this pins that the About text
 * really is built from those constants, that the release tag they spell has
 * the four-field YY.M.D-BUILD shape the updater's health check demands, and
 * that the OS line is readable on this machine. No window is opened.
 */
/* spdf-test-sources: portable/win/src/spdf_win_about.cpp portable/win/src/spdf_win_updater_version.c */
#include "spdf_win_about.h"
#include "spdf_win_about_version.h"
#include "spdf_win_updater.h"

#include <stdio.h>
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

static void test_text(void) {
    char text[1024];
    char small_[16];
    int n = spdf_win_about_text("Windows 11 build 26100, x64", text, sizeof(text));

    CHECK(n > 0 && n == (int)strlen(text));
    CHECK(strncmp(text, "Shenzhen PDF\n", 13) == 0);
    CHECK(strstr(text, "Version " SPDF_WIN_VERSION_STR " (build " SPDF_WIN_BUILD_STR ")\n") != NULL);
    CHECK(strstr(text, "Rendering: MuPDF ") != NULL);
    CHECK(strstr(text, "\nWindows 11 build 26100, x64\n") != NULL);
    CHECK(strstr(text, SPDF_WIN_COPYRIGHT) != NULL);
    /* No OS line: the line is omitted, not left blank. */
    n = spdf_win_about_text(NULL, text, sizeof(text));
    CHECK(n > 0 && strstr(text, "\n\n") == NULL);
    CHECK(strstr(text, "Windows") == NULL);
    /* Truncation is bounded and terminated. */
    n = spdf_win_about_text(NULL, small_, sizeof(small_));
    CHECK(n == (int)sizeof(small_) - 1 && small_[sizeof(small_) - 1] == '\0');
    CHECK(spdf_win_about_text(NULL, NULL, 0) == 0);
}

static void test_identity_constants(void) {
    char numeric[32];
    /* The tag the updater compares against GitHub has four numeric fields,
     * and the fields agree with the numbers the .rc puts in VERSIONINFO. */
    CHECK(spdf_win_updater_versions_match_release_target(SPDF_WIN_RELEASE_TAG, SPDF_WIN_RELEASE_TAG));
    snprintf(numeric, sizeof(numeric), "%d.%d.%d-%d", SPDF_WIN_VERSION_YEAR, SPDF_WIN_VERSION_MONTH,
             SPDF_WIN_VERSION_DAY, SPDF_WIN_VERSION_BUILD);
    CHECK(strcmp(numeric, SPDF_WIN_RELEASE_TAG) == 0);
    CHECK(strcmp(SPDF_WIN_VERSION_STR "-" SPDF_WIN_BUILD_STR, SPDF_WIN_RELEASE_TAG) == 0);
    snprintf(numeric, sizeof(numeric), "%d.%d.%d.%d", SPDF_WIN_VERSION_YEAR, SPDF_WIN_VERSION_MONTH,
             SPDF_WIN_VERSION_DAY, SPDF_WIN_VERSION_BUILD);
    CHECK(strcmp(numeric, SPDF_WIN_FILE_VERSION_STR) == 0);
    CHECK(spdf_win_updater_compare_versions(SPDF_WIN_RELEASE_TAG, SPDF_WIN_VERSION_STR) > 0); /* build > none */
    CHECK(strlen(SPDF_WIN_PROGID) > 0 && strchr(SPDF_WIN_PROGID, '.') != NULL);
    CHECK(strlen(SPDF_WIN_APP_USER_MODEL_ID) < 128); /* the documented cap on an AppUserModelID */
    CHECK(SPDF_WIN_RES_ICON_APP == 1 && SPDF_WIN_RES_MANIFEST == 1);
}

static void test_os_build(void) {
    char os[128];
    CHECK(spdf_win_about_os_build(os, sizeof(os)));
    CHECK(strncmp(os, "Windows ", 8) == 0);
    CHECK(strstr(os, " build ") != NULL);
    printf("about_test: %s\n", os);
    CHECK(!spdf_win_about_os_build(NULL, 0));
}

int main(void) {
    test_text();
    test_identity_constants();
    test_os_build();
    printf("about_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
