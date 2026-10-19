/* Pure-logic tests for spdf_default_reader.c (glib only, no GTK — the live
 * half is compiled out via SPDF_DEFAULT_READER_TESTING). Under test: the
 * prompt decision table (Mac promptToMakeDefaultPDFReaderIfNeededOnLaunch
 * gates + the Linux source-build gate) and the xdg-mime output match. */
#define SPDF_DEFAULT_READER_TESTING 1

#include "../spdf_default_reader.c"

/* --- decision table ------------------------------------------------------------ */

static void test_should_prompt(void) {
    /* The one prompting row: installed, not default, never dismissed, not
     * yet prompted this run. */
    g_assert_true(spdf_default_reader_should_prompt(TRUE, FALSE, FALSE, FALSE));

    /* Source build (no desktop entry): always silent. */
    g_assert_false(spdf_default_reader_should_prompt(FALSE, FALSE, FALSE, FALSE));

    /* Already the default: nothing to offer. */
    g_assert_false(spdf_default_reader_should_prompt(TRUE, TRUE, FALSE, FALSE));

    /* Dismissed persists forever (settings key defaultReaderPromptDismissed,
     * same name as the Mac writer). */
    g_assert_false(spdf_default_reader_should_prompt(TRUE, FALSE, TRUE, FALSE));

    /* At most once per process, like the Mac launch prompt. */
    g_assert_false(spdf_default_reader_should_prompt(TRUE, FALSE, FALSE, TRUE));

    /* Every gate closed stays closed. */
    g_assert_false(spdf_default_reader_should_prompt(FALSE, TRUE, TRUE, TRUE));
}

/* --- xdg-mime output match ------------------------------------------------------ */

static void test_output_is_us(void) {
    /* xdg-mime prints the desktop id with a trailing newline. */
    g_assert_true(spdf_default_reader_output_is_us("shenzhenpdf.desktop\n"));
    g_assert_true(spdf_default_reader_output_is_us("shenzhenpdf.desktop"));
    g_assert_true(spdf_default_reader_output_is_us("  shenzhenpdf.desktop \n"));

    /* Anyone else — including near-misses — is not us. */
    g_assert_false(spdf_default_reader_output_is_us("org.gnome.Evince.desktop\n"));
    g_assert_false(spdf_default_reader_output_is_us("shenzhenpdf\n"));
    g_assert_false(spdf_default_reader_output_is_us("shenzhenpdf.desktop.bak\n"));
    g_assert_false(spdf_default_reader_output_is_us("a shenzhenpdf.desktop\n"));

    /* No default registered / query failed: empty output. */
    g_assert_false(spdf_default_reader_output_is_us(""));
    g_assert_false(spdf_default_reader_output_is_us("\n"));
    g_assert_false(spdf_default_reader_output_is_us(NULL));
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/default-reader/should-prompt", test_should_prompt);
    g_test_add_func("/default-reader/output-is-us", test_output_is_us);
    return g_test_run();
}
