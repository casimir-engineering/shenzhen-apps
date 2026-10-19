/* Pure-logic tests for spdf_ocr.c (glib only, no GTK/core — the GTK half is
 * compiled out via SPDF_OCR_TESTING): the 19-language table, OCRmyPDF argv
 * assembly (deskew / force / redo decision), the post-run validation verdict
 * (journal item 37), failure-message mapping, and backup/temp name
 * derivation. Expected values are byte-copies of the GTK3 behavior
 * (OCR_LANGUAGE_OPTIONS, run_ocr_attempt, ocr_worker, backup_path_for_pdf). */
#define SPDF_OCR_TESTING 1

#include "../spdf_ocr.c"

static void test_language_table(void) {
    int count = 0;
    const SpdfOcrLanguage* languages = spdf_ocr_languages(&count);

    g_assert_cmpint(count, ==, 19);
    /* The GTK3/Mac ordering: Chinese variants first, then English. */
    g_assert_cmpstr(languages[0].code, ==, "chi_sim+eng");
    g_assert_cmpstr(languages[0].label, ==, "Chinese Simplified + English");
    g_assert_cmpstr(languages[4].code, ==, "eng");
    g_assert_cmpstr(languages[count - 1].code, ==, "ron");

    g_assert_cmpint(spdf_ocr_language_index("chi_sim+eng"), ==, 0);
    g_assert_cmpint(spdf_ocr_language_index("eng"), ==, 4);
    g_assert_cmpint(spdf_ocr_language_index("ron"), ==, 18);
    g_assert_cmpint(spdf_ocr_language_index("nope"), ==, -1);
    g_assert_cmpint(spdf_ocr_language_index(NULL), ==, -1);
    g_assert_cmpint(spdf_ocr_language_index(""), ==, -1);
}

static char* join_argv(char** argv) {
    return g_strjoinv(" ", argv);
}

static void test_argv_image_only(void) {
    char** argv = spdf_ocr_build_argv("/usr/bin/ocrmypdf", "chi_sim+eng", 8, FALSE, FALSE, "/d/in.pdf", "/d/.tmp.pdf");
    char* joined = join_argv(argv);
    g_assert_cmpstr(joined, ==,
                    "/usr/bin/ocrmypdf --jobs 8 --rotate-pages --optimize 1 -l chi_sim+eng --deskew "
                    "/d/in.pdf /d/.tmp.pdf");
    g_free(joined);
    g_strfreev(argv);
}

static void test_argv_image_only_forced(void) {
    char** argv = spdf_ocr_build_argv("ocrmypdf", "eng", 4, FALSE, TRUE, "in.pdf", "out.pdf");
    char* joined = join_argv(argv);
    g_assert_cmpstr(joined, ==, "ocrmypdf --jobs 4 --rotate-pages --optimize 1 -l eng --deskew --force-ocr "
                                "in.pdf out.pdf");
    g_free(joined);
    g_strfreev(argv);
}

static void test_argv_redo(void) {
    /* A PDF with existing text uses --redo-ocr and never deskew/force. */
    char** argv = spdf_ocr_build_argv("ocrmypdf", "eng", 1, TRUE, TRUE, "in.pdf", "out.pdf");
    char* joined = join_argv(argv);
    g_assert_cmpstr(joined, ==, "ocrmypdf --jobs 1 --rotate-pages --optimize 1 -l eng --redo-ocr in.pdf out.pdf");
    g_free(joined);
    g_strfreev(argv);
}

static void test_argv_jobs_floor(void) {
    /* jobs is clamped to at least 1 (GTK3 MAX(1u, num_processors)). */
    char** argv = spdf_ocr_build_argv("ocrmypdf", "eng", 0, TRUE, FALSE, "a", "b");
    g_assert_cmpstr(argv[2], ==, "1");
    g_strfreev(argv);
}

static void test_validation_verdict(void) {
    /* Text found in the output: install it. */
    g_assert_cmpint(spdf_ocr_validation_verdict(TRUE, 1, FALSE, FALSE), ==, SPDF_OCR_SWAP);
    g_assert_cmpint(spdf_ocr_validation_verdict(TRUE, 1, TRUE, FALSE), ==, SPDF_OCR_SWAP);
    g_assert_cmpint(spdf_ocr_validation_verdict(TRUE, 1, FALSE, TRUE), ==, SPDF_OCR_SWAP);
    /* Image-only source, first attempt, no text: one forced retry. */
    g_assert_cmpint(spdf_ocr_validation_verdict(TRUE, 0, FALSE, FALSE), ==, SPDF_OCR_RETRY_FORCE);
    /* Forced attempt still empty, or a redo run: hard no-text failure. */
    g_assert_cmpint(spdf_ocr_validation_verdict(TRUE, 0, FALSE, TRUE), ==, SPDF_OCR_FAIL_NO_TEXT);
    g_assert_cmpint(spdf_ocr_validation_verdict(TRUE, 0, TRUE, FALSE), ==, SPDF_OCR_FAIL_NO_TEXT);
    /* Validation error or process failure. */
    g_assert_cmpint(spdf_ocr_validation_verdict(TRUE, -1, FALSE, FALSE), ==, SPDF_OCR_FAIL_ERROR);
    g_assert_cmpint(spdf_ocr_validation_verdict(FALSE, 1, FALSE, FALSE), ==, SPDF_OCR_FAIL_ERROR);
}

static void test_failure_message(void) {
    char* generic = spdf_ocr_failure_message("some stderr text");
    char* empty = spdf_ocr_failure_message(NULL);
    char* redo = spdf_ocr_failure_message("ERROR: --redo-ocr is not compatible with this PDF");
    char* crash = spdf_ocr_failure_message("Traceback (most recent call last):\n  File ...");

    g_assert_cmpstr(generic, ==, "some stderr text");
    g_assert_cmpstr(empty, ==, "OCRmyPDF exited with an error.");
    g_assert_nonnull(strstr(redo, "OCRmyPDF rejected --redo-ocr"));
    g_assert_nonnull(strstr(crash, "OCRmyPDF crashed while processing this PDF."));
    g_free(generic);
    g_free(empty);
    g_free(redo);
    g_free(crash);
}

static void test_backup_candidate(void) {
    char* first = spdf_ocr_backup_candidate("/docs/manual.pdf", 0);
    char* second = spdf_ocr_backup_candidate("/docs/manual.pdf", 1);
    char* third = spdf_ocr_backup_candidate("/docs/manual.pdf", 2);
    char* no_ext = spdf_ocr_backup_candidate("/docs/manual", 0);
    char* other_ext = spdf_ocr_backup_candidate("/docs/manual.PDF", 0);

    /* GTK3 numbering: plain _backup first, then _backup_2, _backup_3... */
    g_assert_cmpstr(first, ==, "/docs/manual_backup.pdf");
    g_assert_cmpstr(second, ==, "/docs/manual_backup_2.pdf");
    g_assert_cmpstr(third, ==, "/docs/manual_backup_3.pdf");
    g_assert_cmpstr(no_ext, ==, "/docs/manual_backup.pdf");
    g_assert_cmpstr(other_ext, ==, "/docs/manual_backup.PDF");
    g_assert_null(spdf_ocr_backup_candidate(NULL, 0));
    g_free(first);
    g_free(second);
    g_free(third);
    g_free(no_ext);
    g_free(other_ext);
}

static void test_temp_path(void) {
    char* tmp = spdf_ocr_temp_path("/docs/manual.pdf", 12345);
    g_assert_cmpstr(tmp, ==, "/docs/.manual.pdf.ocr-12345.pdf");
    g_free(tmp);
    g_assert_null(spdf_ocr_temp_path(NULL, 1));
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/ocr/language_table", test_language_table);
    g_test_add_func("/ocr/argv_image_only", test_argv_image_only);
    g_test_add_func("/ocr/argv_image_only_forced", test_argv_image_only_forced);
    g_test_add_func("/ocr/argv_redo", test_argv_redo);
    g_test_add_func("/ocr/argv_jobs_floor", test_argv_jobs_floor);
    g_test_add_func("/ocr/validation_verdict", test_validation_verdict);
    g_test_add_func("/ocr/failure_message", test_failure_message);
    g_test_add_func("/ocr/backup_candidate", test_backup_candidate);
    g_test_add_func("/ocr/temp_path", test_temp_path);
    return g_test_run();
}
