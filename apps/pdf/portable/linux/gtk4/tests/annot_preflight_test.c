/* Pure-logic tests for spdf_annot.c's write-preflight and path rules (glib
 * only, no GTK — the GTK half of the module is compiled out via
 * SPDF_ANNOT_TESTING). The rules under test are ports of the GTK3 helpers:
 * path_has_pdf_extension, path_is_under_directory, path_is_in_temp_directory,
 * filename_with_pdf_extension, pdf_path_allows_same_folder_write and
 * prompt_save_as_before_modification's save-target rule (journal item 35),
 * plus copy_page_clicked's single-page file name build. */
#define SPDF_ANNOT_TESTING 1

#include "../spdf_annot.c"

#include <unistd.h>

static void test_pdf_extension(void) {
    g_assert_true(spdf_annot_path_has_pdf_extension("/a/b/doc.pdf"));
    g_assert_true(spdf_annot_path_has_pdf_extension("/a/b/DOC.PDF"));
    g_assert_true(spdf_annot_path_has_pdf_extension("/a/b/doc.PdF"));
    g_assert_false(spdf_annot_path_has_pdf_extension("/a/b/doc.pdf.bak"));
    g_assert_false(spdf_annot_path_has_pdf_extension("/a/b/doc"));
    g_assert_false(spdf_annot_path_has_pdf_extension("/a/b/pdf"));
    g_assert_false(spdf_annot_path_has_pdf_extension(NULL));
    g_assert_false(spdf_annot_path_has_pdf_extension(""));
}

static void test_path_is_under_directory(void) {
    g_assert_true(spdf_annot_path_is_under_directory("/tmp/x.pdf", "/tmp"));
    g_assert_true(spdf_annot_path_is_under_directory("/tmp", "/tmp"));
    g_assert_true(spdf_annot_path_is_under_directory("/tmp/a/b/c.pdf", "/tmp"));
    /* Prefix without a path-separator boundary is NOT containment. */
    g_assert_false(spdf_annot_path_is_under_directory("/tmpfiles/x.pdf", "/tmp"));
    /* Canonicalization: dot segments collapse before the check. */
    g_assert_true(spdf_annot_path_is_under_directory("/var/../tmp/x.pdf", "/tmp"));
    g_assert_false(spdf_annot_path_is_under_directory("/tmp/../home/u/x.pdf", "/tmp"));
    g_assert_false(spdf_annot_path_is_under_directory(NULL, "/tmp"));
    g_assert_false(spdf_annot_path_is_under_directory("/tmp/x", NULL));
    g_assert_false(spdf_annot_path_is_under_directory("", "/tmp"));
}

static void test_path_is_temp_in(void) {
    /* The GTK3 rule probes four roots: the injected tmp dir, /tmp, /var/tmp
     * and the injected runtime dir. */
    g_assert_true(spdf_annot_path_is_temp_in("/tmp/doc.pdf", "/custom/tmp", NULL));
    g_assert_true(spdf_annot_path_is_temp_in("/var/tmp/doc.pdf", "/custom/tmp", NULL));
    g_assert_true(spdf_annot_path_is_temp_in("/custom/tmp/doc.pdf", "/custom/tmp", NULL));
    g_assert_true(spdf_annot_path_is_temp_in("/run/user/1000/doc.pdf", "/custom/tmp", "/run/user/1000"));
    g_assert_false(spdf_annot_path_is_temp_in("/home/u/doc.pdf", "/custom/tmp", "/run/user/1000"));
    /* A NULL runtime dir must not blow up or match everything. */
    g_assert_false(spdf_annot_path_is_temp_in("/home/u/doc.pdf", "/custom/tmp", NULL));
}

static void test_filename_with_pdf_extension(void) {
    char* with = spdf_annot_filename_with_pdf_extension("/a/doc.pdf");
    char* added = spdf_annot_filename_with_pdf_extension("/a/doc");
    char* upper = spdf_annot_filename_with_pdf_extension("/a/DOC.PDF");

    g_assert_cmpstr(with, ==, "/a/doc.pdf");
    g_assert_cmpstr(added, ==, "/a/doc.pdf");
    g_assert_cmpstr(upper, ==, "/a/DOC.PDF"); /* existing extension kept as-is */
    g_assert_null(spdf_annot_filename_with_pdf_extension(NULL));
    g_assert_null(spdf_annot_filename_with_pdf_extension(""));
    g_free(with);
    g_free(added);
    g_free(upper);
}

static void test_single_page_filename(void) {
    char* named = spdf_annot_single_page_filename("/docs/Manual.pdf", 2);
    char* no_ext = spdf_annot_single_page_filename("/docs/Manual", 0);
    char* hidden = spdf_annot_single_page_filename("/docs/.pdf", 4);
    char* null_path = spdf_annot_single_page_filename(NULL, 9);

    /* GTK3 copy_page_clicked: basename sans extension, 1-based page. */
    g_assert_cmpstr(named, ==, "Manual - page 3.pdf");
    g_assert_cmpstr(no_ext, ==, "Manual - page 1.pdf");
    /* A leading dot is a hidden-file name, not an extension separator. */
    g_assert_cmpstr(hidden, ==, ".pdf - page 5.pdf");
    g_assert_cmpstr(null_path, ==, "Page - page 10.pdf");
    g_free(named);
    g_free(no_ext);
    g_free(hidden);
    g_free(null_path);
}

static void test_same_folder_write_verdict(void) {
    /* Truth table of pdf_path_allows_same_folder_write: temp always loses,
     * then both the file and its directory must be writable. */
    g_assert_true(spdf_annot_same_folder_write_allowed(FALSE, TRUE, TRUE));
    g_assert_false(spdf_annot_same_folder_write_allowed(TRUE, TRUE, TRUE));
    g_assert_false(spdf_annot_same_folder_write_allowed(FALSE, FALSE, TRUE));
    g_assert_false(spdf_annot_same_folder_write_allowed(FALSE, TRUE, FALSE));
    g_assert_false(spdf_annot_same_folder_write_allowed(TRUE, FALSE, FALSE));
}

static void test_save_target_acceptable(void) {
    /* prompt_save_as_before_modification's loop: the chosen target must keep
     * a .pdf extension and must not land back in a temp directory. */
    g_assert_true(spdf_annot_save_target_acceptable("/home/u/out.pdf", "/custom/tmp", "/run/user/1000"));
    g_assert_false(spdf_annot_save_target_acceptable("/tmp/out.pdf", "/custom/tmp", NULL));
    g_assert_false(spdf_annot_save_target_acceptable("/var/tmp/out.pdf", "/custom/tmp", NULL));
    g_assert_false(spdf_annot_save_target_acceptable("/custom/tmp/out.pdf", "/custom/tmp", NULL));
    g_assert_false(spdf_annot_save_target_acceptable("/run/user/1000/out.pdf", "/custom/tmp", "/run/user/1000"));
    g_assert_false(spdf_annot_save_target_acceptable("/home/u/out.txt", "/custom/tmp", NULL));
    g_assert_false(spdf_annot_save_target_acceptable("/home/u/out", "/custom/tmp", NULL));
    g_assert_false(spdf_annot_save_target_acceptable(NULL, "/custom/tmp", NULL));
    g_assert_false(spdf_annot_save_target_acceptable("", "/custom/tmp", NULL));
}

static void test_temp_directory_probe(void) {
    /* The probing wrapper must reject anything under the real tmp dir. */
    char* dir = g_dir_make_tmp("spdf-annot-test-XXXXXX", NULL);
    char* pdf_path;

    g_assert_nonnull(dir);
    pdf_path = g_build_filename(dir, "doc.pdf", NULL);
    g_assert_true(g_file_set_contents(pdf_path, "%PDF-1.4", -1, NULL));
    g_assert_true(spdf_annot_path_is_in_temp_directory(pdf_path));
    g_assert_false(spdf_annot_pdf_path_allows_same_folder_write(pdf_path));
    g_unlink(pdf_path);
    g_rmdir(dir);
    g_free(pdf_path);
    g_free(dir);
}

static void test_writable_probe(void) {
    /* Real-permission probe outside the temp dirs. chmod-based denial is
     * meaningless for root (docker builds run as root), so only the positive
     * case is asserted there. */
    char* cwd = g_get_current_dir();
    char* dir = g_build_filename(cwd, "annot-preflight-test-dir", NULL);
    char* pdf_path = g_build_filename(dir, "doc.pdf", NULL);

    g_assert_cmpint(g_mkdir_with_parents(dir, 0755), ==, 0);
    g_assert_true(g_file_set_contents(pdf_path, "%PDF-1.4", -1, NULL));
    g_assert_false(spdf_annot_path_is_in_temp_directory(pdf_path));
    g_assert_true(spdf_annot_pdf_path_allows_same_folder_write(pdf_path));

    if (geteuid() != 0) {
        g_assert_cmpint(g_chmod(pdf_path, 0444), ==, 0);
        g_assert_false(spdf_annot_pdf_path_allows_same_folder_write(pdf_path));
        g_assert_cmpint(g_chmod(pdf_path, 0644), ==, 0);
        g_assert_cmpint(g_chmod(dir, 0555), ==, 0);
        g_assert_false(spdf_annot_pdf_path_allows_same_folder_write(pdf_path));
        g_assert_cmpint(g_chmod(dir, 0755), ==, 0);
    }

    g_unlink(pdf_path);
    g_rmdir(dir);
    g_free(pdf_path);
    g_free(dir);
    g_free(cwd);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/annot/pdf-extension", test_pdf_extension);
    g_test_add_func("/annot/path-under-directory", test_path_is_under_directory);
    g_test_add_func("/annot/path-is-temp", test_path_is_temp_in);
    g_test_add_func("/annot/filename-with-pdf-extension", test_filename_with_pdf_extension);
    g_test_add_func("/annot/single-page-filename", test_single_page_filename);
    g_test_add_func("/annot/same-folder-write-verdict", test_same_folder_write_verdict);
    g_test_add_func("/annot/save-target-acceptable", test_save_target_acceptable);
    g_test_add_func("/annot/temp-directory-probe", test_temp_directory_probe);
    g_test_add_func("/annot/writable-probe", test_writable_probe);
    return g_test_run();
}
