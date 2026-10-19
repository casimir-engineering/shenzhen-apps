/* Pure-logic tests for spdf_watcher.c (glib only, no GTK — the GIO/GTK half
 * of the module is compiled out via SPDF_WATCHER_TESTING). Under test:
 * the debounce/coalesce rule (Mac SPDFMacFileWatcher timer re-arm), the
 * shadow-copy naming/containment rules (Mac readOnlyCopyFileNameForSourcePath
 * digest naming), the read-only detection decision table + real probe, the
 * copy-reuse / stat-differs comparisons and the orphan-sweep rule. */
#define SPDF_WATCHER_TESTING 1

#include "../spdf_watcher_logic.c"

#include <unistd.h>

/* --- debounce/coalesce ------------------------------------------------------ */

static void test_debounce_coalesce(void) {
    SpdfWatcherDebounce d = {0};
    const gint64 delay = 500 * 1000; /* 500ms in us */

    /* Idle: nothing fires. */
    g_assert_false(spdf_watcher_debounce_fire(&d, 1000));

    /* A burst of events keeps pushing the deadline back (trailing edge). */
    g_assert_cmpint(spdf_watcher_debounce_event(&d, 0, delay), ==, delay);
    g_assert_cmpint(spdf_watcher_debounce_event(&d, 100 * 1000, delay), ==, 600 * 1000);
    g_assert_cmpint(spdf_watcher_debounce_event(&d, 450 * 1000, delay), ==, 950 * 1000);

    /* Not yet due. */
    g_assert_false(spdf_watcher_debounce_fire(&d, 949 * 1000));
    /* Due: fires exactly once, then resets to idle. */
    g_assert_true(spdf_watcher_debounce_fire(&d, 950 * 1000));
    g_assert_false(spdf_watcher_debounce_fire(&d, 951 * 1000));

    /* A new event re-arms. */
    spdf_watcher_debounce_event(&d, 2000 * 1000, delay);
    g_assert_false(spdf_watcher_debounce_fire(&d, 2000 * 1000 + delay - 1));
    g_assert_true(spdf_watcher_debounce_fire(&d, 2000 * 1000 + delay));
}

/* --- shadow-copy naming ------------------------------------------------------ */

static void test_shadow_copy_name(void) {
    char* a = spdf_watcher_shadow_copy_name("/docs/Manual.pdf");
    char* a_again = spdf_watcher_shadow_copy_name("/docs/Manual.pdf");
    char* a_dotted = spdf_watcher_shadow_copy_name("/docs/./Manual.pdf");
    char* b = spdf_watcher_shadow_copy_name("/docs/Other.pdf");
    char* no_ext = spdf_watcher_shadow_copy_name("/docs/Manual");
    char* upper = spdf_watcher_shadow_copy_name("/docs/SHEET.PDF");

    /* Deterministic: an unchanged source reclaims the same copy across
     * relaunches (Mac digest naming). */
    g_assert_cmpstr(a, ==, a_again);
    /* Lexical canonicalization: dot segments do not change the identity. */
    g_assert_cmpstr(a, ==, a_dotted);
    /* Distinct sources -> distinct copies (no worker-cache collision). */
    g_assert_cmpstr(a, !=, b);

    /* Format: ro-<32 hex>.<ext>; missing extension defaults to pdf. */
    g_assert_true(g_str_has_prefix(a, "ro-"));
    g_assert_cmpuint(strlen(a), ==, 3 + 32 + 1 + 3);
    g_assert_true(g_str_has_suffix(a, ".pdf"));
    g_assert_true(g_str_has_suffix(no_ext, ".pdf"));
    g_assert_true(g_str_has_suffix(upper, ".PDF")); /* extension kept as-is */
    for (int i = 3; i < 3 + 32; ++i) g_assert_true(g_ascii_isxdigit(a[i]));

    g_assert_null(spdf_watcher_shadow_copy_name(NULL));
    g_assert_null(spdf_watcher_shadow_copy_name(""));

    g_free(a);
    g_free(a_again);
    g_free(a_dotted);
    g_free(b);
    g_free(no_ext);
    g_free(upper);
}

static void test_path_is_shadow_in(void) {
    const char* dir = "/home/u/.local/share/shenzhenpdf/ReadOnlyCopies";
    char* name = spdf_watcher_shadow_copy_name("/docs/Manual.pdf");
    char* good = g_build_filename(dir, name, NULL);
    char* nested = g_build_filename(dir, "sub", name, NULL);
    char* elsewhere = g_build_filename("/tmp", name, NULL);

    g_assert_true(spdf_watcher_path_is_shadow_in(good, dir));
    /* Lexical canonicalization on both sides. */
    g_assert_true(spdf_watcher_path_is_shadow_in(good, "/home/u/.local/share/shenzhenpdf/./ReadOnlyCopies"));
    /* Must live DIRECTLY in the copies dir. */
    g_assert_false(spdf_watcher_path_is_shadow_in(nested, dir));
    g_assert_false(spdf_watcher_path_is_shadow_in(elsewhere, dir));
    /* Must match the ro-<32 hex>.<ext> shape. */
    g_assert_false(spdf_watcher_path_is_shadow_in("/home/u/.local/share/shenzhenpdf/ReadOnlyCopies/x.pdf", dir));
    g_assert_false(spdf_watcher_path_is_shadow_in("/home/u/.local/share/shenzhenpdf/ReadOnlyCopies/ro-zz.pdf", dir));
    g_assert_false(spdf_watcher_path_is_shadow_in(
        "/home/u/.local/share/shenzhenpdf/ReadOnlyCopies/ro-0123456789abcdef0123456789abcdef", dir));
    g_assert_false(spdf_watcher_path_is_shadow_in(NULL, dir));
    g_assert_false(spdf_watcher_path_is_shadow_in(good, NULL));
    g_assert_false(spdf_watcher_path_is_shadow_in("", dir));

    g_free(elsewhere);
    g_free(nested);
    g_free(good);
    g_free(name);
}

/* --- read-only detection ------------------------------------------------------ */

static void test_read_only_verdict(void) {
    /* Decision table (Mac sourcePathIsReadOnly contract): only an existing
     * regular file the process cannot write is read-only; missing or
     * non-regular is NOT read-only (missing-file UI owns those). */
    g_assert_true(spdf_watcher_read_only_verdict(TRUE, TRUE, FALSE));
    g_assert_false(spdf_watcher_read_only_verdict(TRUE, TRUE, TRUE));
    g_assert_false(spdf_watcher_read_only_verdict(FALSE, FALSE, FALSE));
    g_assert_false(spdf_watcher_read_only_verdict(TRUE, FALSE, FALSE));
    g_assert_false(spdf_watcher_read_only_verdict(TRUE, FALSE, TRUE));
}

static void test_read_only_probe(void) {
    /* Real probe in a temp dir. chmod-based denial is meaningless for root
     * (docker builds run as root), so those cases are skipped there — same
     * pattern as tests/annot_preflight_test.c. */
    char* dir = g_dir_make_tmp("spdf-watcher-test-XXXXXX", NULL);
    char* pdf_path;

    g_assert_nonnull(dir);
    pdf_path = g_build_filename(dir, "doc.pdf", NULL);
    g_assert_true(g_file_set_contents(pdf_path, "%PDF-1.4", -1, NULL));

    /* Writable regular file: not read-only. */
    g_assert_false(spdf_watcher_source_is_read_only(pdf_path));
    /* Directory: never read-only (non-regular). */
    g_assert_false(spdf_watcher_source_is_read_only(dir));
    /* Missing: never read-only. */
    {
        char* missing = g_build_filename(dir, "nope.pdf", NULL);
        g_assert_false(spdf_watcher_source_is_read_only(missing));
        g_free(missing);
    }
    g_assert_false(spdf_watcher_source_is_read_only(NULL));
    g_assert_false(spdf_watcher_source_is_read_only(""));

    if (geteuid() != 0) {
        g_assert_cmpint(g_chmod(pdf_path, 0444), ==, 0);
        g_assert_true(spdf_watcher_source_is_read_only(pdf_path));
        /* A read-only directory does not make the FILE read-only (in-place
         * writes to the file still succeed; only sibling writes fail). */
        g_assert_cmpint(g_chmod(pdf_path, 0644), ==, 0);
        g_assert_cmpint(g_chmod(dir, 0555), ==, 0);
        g_assert_false(spdf_watcher_source_is_read_only(pdf_path));
        g_assert_cmpint(g_chmod(dir, 0755), ==, 0);
    }

    g_unlink(pdf_path);
    g_rmdir(dir);
    g_free(pdf_path);
    g_free(dir);
}

/* --- stat comparisons / copy reuse ------------------------------------------- */

static void test_stat_differs(void) {
    g_assert_false(spdf_watcher_stat_differs(100, 5.0, 100, 5.0));
    /* mtime within the JSON round-trip tolerance is "same". */
    g_assert_false(spdf_watcher_stat_differs(100, 5.0, 100, 5.0 + SPDF_WATCHER_MTIME_TOLERANCE / 2));
    g_assert_true(spdf_watcher_stat_differs(100, 5.0, 100, 5.0 + SPDF_WATCHER_MTIME_TOLERANCE * 2));
    g_assert_true(spdf_watcher_stat_differs(100, 5.0, 101, 5.0));
}

static void test_copy_reusable(void) {
    /* Mac "unchanged" branch: reuse needs the copy on disk, a recorded
     * binding, and a matching fresh source stat — then NO source content
     * read happens. */
    g_assert_true(spdf_watcher_copy_reusable(TRUE, 100, 5.0, 100, 5.0));
    g_assert_true(spdf_watcher_copy_reusable(TRUE, 100, 5.0, 100, 5.0 + SPDF_WATCHER_MTIME_TOLERANCE / 2));
    g_assert_false(spdf_watcher_copy_reusable(FALSE, 100, 5.0, 100, 5.0)); /* copy missing */
    g_assert_false(spdf_watcher_copy_reusable(TRUE, 0, 0.0, 100, 5.0));    /* no binding */
    g_assert_false(spdf_watcher_copy_reusable(TRUE, 100, 5.0, 100, 9.0));  /* source changed */
    g_assert_false(spdf_watcher_copy_reusable(TRUE, 100, 5.0, 250, 5.0));
}

/* --- orphan sweep ------------------------------------------------------------- */

static void test_sweep_rule(void) {
    const double now = 10000.0;

    /* Referenced by a live tab: always kept. */
    g_assert_false(spdf_watcher_sweep_should_delete(TRUE, now - 3600.0, now));
    /* Unreferenced and old: deleted. */
    g_assert_true(spdf_watcher_sweep_should_delete(FALSE, now - 3600.0, now));
    /* Unreferenced but touched within the recency window: kept (defends a
     * copy created concurrently during this launch — Mac 60s backstop). */
    g_assert_false(spdf_watcher_sweep_should_delete(FALSE, now - SPDF_WATCHER_SWEEP_RECENCY_S / 2, now));
    g_assert_false(spdf_watcher_sweep_should_delete(FALSE, now, now));
}

/* --- stat probe ---------------------------------------------------------------- */

static void test_stat_path(void) {
    char* dir = g_dir_make_tmp("spdf-watcher-stat-XXXXXX", NULL);
    char* path;
    guint64 size = 0;
    double mtime = 0.0;

    g_assert_nonnull(dir);
    path = g_build_filename(dir, "doc.pdf", NULL);
    g_assert_true(g_file_set_contents(path, "%PDF-1.4", -1, NULL));

    g_assert_true(spdf_watcher_stat_path(path, &size, &mtime));
    g_assert_cmpuint(size, ==, strlen("%PDF-1.4"));
    g_assert_cmpfloat(mtime, >, 0.0);
    g_assert_false(spdf_watcher_stat_path(NULL, &size, &mtime));
    {
        char* missing = g_build_filename(dir, "nope.pdf", NULL);
        g_assert_false(spdf_watcher_stat_path(missing, &size, &mtime));
        g_free(missing);
    }

    g_unlink(path);
    g_rmdir(dir);
    g_free(path);
    g_free(dir);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/watcher/debounce-coalesce", test_debounce_coalesce);
    g_test_add_func("/watcher/shadow-copy-name", test_shadow_copy_name);
    g_test_add_func("/watcher/path-is-shadow-in", test_path_is_shadow_in);
    g_test_add_func("/watcher/read-only-verdict", test_read_only_verdict);
    g_test_add_func("/watcher/read-only-probe", test_read_only_probe);
    g_test_add_func("/watcher/stat-differs", test_stat_differs);
    g_test_add_func("/watcher/copy-reusable", test_copy_reusable);
    g_test_add_func("/watcher/sweep-rule", test_sweep_rule);
    g_test_add_func("/watcher/stat-path", test_stat_path);
    return g_test_run();
}
