/* Pure-logic tests for spdf_resident.c (glib only, no GTK — the live half is
 * compiled out via SPDF_RESIDENT_TESTING). Under test: the autostart Exec
 * value decision (deb name vs argv0-resolved path), the .desktop content
 * assembly, and the Exec staleness check that gates rewrites. */
#define SPDF_RESIDENT_TESTING 1

#include "../spdf_resident.c"

/* --- Exec value decision ------------------------------------------------------ */

static void test_autostart_exec(void) {
    char* exec;

    /* deb install: PATH resolves "shenzhenpdf" to this very binary -> the
     * bare name (survives package upgrades replacing the file). */
    exec = spdf_resident_autostart_exec("/usr/bin/shenzhenpdf", "/usr/bin/shenzhenpdf");
    g_assert_cmpstr(exec, ==, "shenzhenpdf");
    g_free(exec);

    /* user-local install, not in PATH -> the resolved absolute path. */
    exec = spdf_resident_autostart_exec("/home/u/.local/opt/shenzhenpdf", NULL);
    g_assert_cmpstr(exec, ==, "/home/u/.local/opt/shenzhenpdf");
    g_free(exec);

    /* A DIFFERENT shenzhenpdf in PATH must not shadow this binary. */
    exec = spdf_resident_autostart_exec("/home/u/.local/opt/shenzhenpdf", "/usr/bin/shenzhenpdf");
    g_assert_cmpstr(exec, ==, "/home/u/.local/opt/shenzhenpdf");
    g_free(exec);

    /* Paths with spaces come back shell-quoted so Exec parses as one arg. */
    exec = spdf_resident_autostart_exec("/home/u/My Apps/shenzhenpdf", NULL);
    g_assert_cmpstr(exec, ==, "'/home/u/My Apps/shenzhenpdf'");
    g_free(exec);

    /* Unresolvable self (/proc unreadable): best effort falls back to the
     * installed name rather than writing a broken entry. */
    exec = spdf_resident_autostart_exec(NULL, "/usr/bin/shenzhenpdf");
    g_assert_cmpstr(exec, ==, "shenzhenpdf");
    g_free(exec);
    exec = spdf_resident_autostart_exec("", NULL);
    g_assert_cmpstr(exec, ==, "shenzhenpdf");
    g_free(exec);
}

/* --- content assembly --------------------------------------------------------- */

static void test_autostart_content(void) {
    char* content = spdf_resident_autostart_content("shenzhenpdf");

    g_assert_nonnull(content);
    g_assert_true(g_str_has_prefix(content, "[Desktop Entry]\n"));
    g_assert_nonnull(strstr(content, "\nType=Application\n"));
    g_assert_nonnull(strstr(content, "\nExec=shenzhenpdf --resident\n"));
    /* Session managers rewrite exactly these keys to toggle entries; write
     * them explicitly so a fresh install starts enabled. */
    g_assert_nonnull(strstr(content, "\nHidden=false\n"));
    g_assert_nonnull(strstr(content, "\nX-GNOME-Autostart-enabled=true\n"));
    /* OnlyShowIn deliberately absent: the entry runs on every desktop. */
    g_assert_null(strstr(content, "OnlyShowIn"));
    g_assert_true(g_str_has_suffix(content, "\n"));
    g_free(content);

    /* Quoted path flows through verbatim. */
    content = spdf_resident_autostart_content("'/home/u/My Apps/shenzhenpdf'");
    g_assert_nonnull(strstr(content, "\nExec='/home/u/My Apps/shenzhenpdf' --resident\n"));
    g_free(content);

    /* No sane exec -> no content (caller skips the write). */
    g_assert_null(spdf_resident_autostart_content(NULL));
    g_assert_null(spdf_resident_autostart_content(""));
}

/* --- staleness ---------------------------------------------------------------- */

static void test_autostart_stale(void) {
    char* current = spdf_resident_autostart_content("shenzhenpdf");

    /* Missing/empty file must be written. */
    g_assert_true(spdf_resident_autostart_stale(NULL, "shenzhenpdf"));
    g_assert_true(spdf_resident_autostart_stale("", "shenzhenpdf"));

    /* Freshly written content is never stale against its own exec. */
    g_assert_false(spdf_resident_autostart_stale(current, "shenzhenpdf"));

    /* The binary moved (deb -> user-local or vice versa): stale. */
    g_assert_true(spdf_resident_autostart_stale(current, "/home/u/.local/opt/shenzhenpdf"));
    g_assert_true(
        spdf_resident_autostart_stale("[Desktop Entry]\nExec=/old/place/shenzhenpdf --resident\n", "shenzhenpdf"));

    /* Exec missing --resident (hand-edited): stale — the entry would cold-
     * launch a window at login instead of starting held. */
    g_assert_true(spdf_resident_autostart_stale("[Desktop Entry]\nExec=shenzhenpdf\n", "shenzhenpdf"));

    /* Only Exec decides: users may edit cosmetic keys freely. */
    g_assert_false(spdf_resident_autostart_stale(
        "[Desktop Entry]\nName=Renamed by user\nExec=shenzhenpdf --resident\nX-Custom=1\n", "shenzhenpdf"));

    /* Trailing whitespace / CRLF on the Exec line is tolerated. */
    g_assert_false(spdf_resident_autostart_stale("Exec=shenzhenpdf --resident \n", "shenzhenpdf"));
    g_assert_false(spdf_resident_autostart_stale("Exec=shenzhenpdf --resident\r\n", "shenzhenpdf"));
    /* ...but an Exec line missing its newline (truncated write) still counts. */
    g_assert_false(spdf_resident_autostart_stale("Exec=shenzhenpdf --resident", "shenzhenpdf"));

    /* A commented-out or prefixed line is not an Exec line. */
    g_assert_true(spdf_resident_autostart_stale("#Exec=shenzhenpdf --resident\n", "shenzhenpdf"));

    /* No sane exec value: never claim stale (nothing sane to write). */
    g_assert_false(spdf_resident_autostart_stale(current, NULL));
    g_assert_false(spdf_resident_autostart_stale(NULL, ""));

    g_free(current);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/resident/autostart-exec", test_autostart_exec);
    g_test_add_func("/resident/autostart-content", test_autostart_content);
    g_test_add_func("/resident/autostart-stale", test_autostart_stale);
    return g_test_run();
}
