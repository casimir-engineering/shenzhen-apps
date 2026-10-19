/* password_flow_test.c — pins spdf_win_password_flow.h, the toolkit-free half
 * of the password prompt, with the GTK original's own cases transcribed
 * (portable/linux/gtk4/tests/password_lifecycle_test.c): startup waits for a
 * mapped parent, a command-line open without a parent prompts at once, a wrong
 * password re-asks and says so, cancel stops, a cancelled or failed reload
 * keeps the live document and its baseline, and the staging path has the
 * private "ro-<32 hex>.<ext>" shape. The dialog itself (spdf_win_password.cpp)
 * cannot be shown on a locked workstation and is not compiled in.
 *
 * Header-only under test, so no `spdf-test-sources` line.
 */
#include "spdf_win_password_flow.h"

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

static void test_startup_waits_for_mapped_parent(void) {
    SpdfWinPasswordFlow flow;
    spdf_win_password_flow_init(&flow, 1, 0);
    CHECK(spdf_win_password_flow_opened(&flow, SPDF_OPEN_PASSWORD_REQUIRED) == SPDF_WIN_PASSWORD_PRESENT_PARENT);
    CHECK(flow.awaiting_parent);
    CHECK(spdf_win_password_flow_parent_ready(&flow) == SPDF_WIN_PASSWORD_ASK);
    CHECK(flow.parent_mapped);
    CHECK(!flow.incorrect);
    /* parent_ready with nothing awaited is a programming error, reported as FAILED. */
    CHECK(spdf_win_password_flow_parent_ready(&flow) == SPDF_WIN_PASSWORD_FAILED);
}

static void test_command_line_without_parent_can_prompt(void) {
    SpdfWinPasswordFlow flow;
    spdf_win_password_flow_init(&flow, 0, 0);
    CHECK(flow.parent_mapped);
    CHECK(spdf_win_password_flow_opened(&flow, SPDF_OPEN_PASSWORD_REQUIRED) == SPDF_WIN_PASSWORD_ASK);
}

static void test_wrong_password_retries_and_cancel_stops(void) {
    SpdfWinPasswordFlow flow;
    spdf_win_password_flow_init(&flow, 1, 1);
    CHECK(spdf_win_password_flow_opened(&flow, SPDF_OPEN_PASSWORD_REQUIRED) == SPDF_WIN_PASSWORD_ASK);
    CHECK(!flow.incorrect);
    CHECK(spdf_win_password_flow_opened(&flow, SPDF_OPEN_BAD_PASSWORD) == SPDF_WIN_PASSWORD_ASK);
    CHECK(flow.incorrect);
    CHECK(spdf_win_password_flow_opened(&flow, SPDF_OPEN_OK) == SPDF_WIN_PASSWORD_DONE);
    CHECK(spdf_win_password_flow_opened(&flow, SPDF_OPEN_ERROR) == SPDF_WIN_PASSWORD_FAILED);
    spdf_win_password_flow_init(&flow, 1, 1);
    CHECK(spdf_win_password_flow_opened(&flow, SPDF_OPEN_PASSWORD_REQUIRED) == SPDF_WIN_PASSWORD_ASK);
    CHECK(spdf_win_password_flow_cancel(&flow) == SPDF_WIN_PASSWORD_CANCELLED);
    CHECK(!flow.awaiting_parent);
    /* NULL is tolerated everywhere and reads as failure. */
    CHECK(spdf_win_password_flow_opened(NULL, SPDF_OPEN_OK) == SPDF_WIN_PASSWORD_FAILED);
    CHECK(spdf_win_password_flow_parent_ready(NULL) == SPDF_WIN_PASSWORD_FAILED);
    CHECK(spdf_win_password_flow_cancel(NULL) == SPDF_WIN_PASSWORD_FAILED);
    spdf_win_password_flow_init(NULL, 1, 1);
}

static void test_reload_policy_preserves_on_cancel_and_error(void) {
    SpdfWinPasswordReloadPolicy policy = spdf_win_password_reload_policy(0, 1);
    CHECK(!policy.replace_live_state);
    CHECK(!policy.advance_baseline);
    CHECK(policy.retry_pending);
    policy = spdf_win_password_reload_policy(0, 0);
    CHECK(!policy.replace_live_state);
    CHECK(!policy.advance_baseline);
    CHECK(policy.retry_pending);
    policy = spdf_win_password_reload_policy(1, 0);
    CHECK(policy.replace_live_state);
    CHECK(policy.advance_baseline);
    CHECK(!policy.retry_pending);
}

static void test_reload_staging_path_shape(void) {
    char out[256];
    const char* hex = "0123456789abcdef0123456789abcdef";
    CHECK(spdf_win_password_reload_staging_path("C:\\state\\ReadOnlyCopies", "C:\\docs\\report.pdf", hex, out, sizeof(out)));
    CHECK_STR(out, "C:\\state\\ReadOnlyCopies\\ro-0123456789abcdef0123456789abcdef.pdf");
    CHECK(strlen(out) - strlen("C:\\state\\ReadOnlyCopies\\") == strlen("ro-") + 32 + strlen(".pdf"));
    /* A trailing separator on the directory is not doubled. */
    CHECK(spdf_win_password_reload_staging_path("C:\\tmp\\", "C:\\docs\\report.pdf", hex, out, sizeof(out)));
    CHECK_STR(out, "C:\\tmp\\ro-0123456789abcdef0123456789abcdef.pdf");
    /* The extension is the LAST component's; a dot in a directory does not count. */
    CHECK(spdf_win_password_reload_staging_path("C:\\tmp", "C:\\docs.v2\\report", hex, out, sizeof(out)));
    CHECK_STR(out, "C:\\tmp\\ro-0123456789abcdef0123456789abcdef");
    CHECK(spdf_win_password_reload_staging_path("C:\\tmp", "/docs/sheet.PDF", hex, out, sizeof(out)));
    CHECK_STR(out, "C:\\tmp\\ro-0123456789abcdef0123456789abcdef.PDF");
    CHECK(spdf_win_password_reload_staging_path("C:\\tmp", NULL, hex, out, sizeof(out)));
    CHECK_STR(out, "C:\\tmp\\ro-0123456789abcdef0123456789abcdef");
    CHECK(!spdf_win_password_reload_staging_path("", "x.pdf", hex, out, sizeof(out)));
    CHECK(!spdf_win_password_reload_staging_path(NULL, "x.pdf", hex, out, sizeof(out)));
    CHECK(!spdf_win_password_reload_staging_path("C:\\tmp", "x.pdf", "short", out, sizeof(out)));
    CHECK(!spdf_win_password_reload_staging_path("C:\\tmp", "x.pdf", hex, out, 20));
    CHECK_STR(out, "");
    CHECK(!spdf_win_password_reload_staging_path("C:\\tmp", "x.pdf", hex, NULL, 0));
}

int main(void) {
    test_startup_waits_for_mapped_parent();
    test_command_line_without_parent_can_prompt();
    test_wrong_password_retries_and_cancel_stops();
    test_reload_policy_preserves_on_cancel_and_error();
    test_reload_staging_path_shape();
    printf("password_flow_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
