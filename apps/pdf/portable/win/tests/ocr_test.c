/* ocr_test.c -- pins portable/win/src/spdf_win_ocr.{h,cpp}.
 *
 * The pure half carries the GTK suite's cases (portable/linux/gtk4/tests/
 * ocr_test.c) with Windows paths: the 19-language table, the OCRmyPDF command
 * line in its three shapes, the jobs floor, the validation verdict, the
 * failure-message classifier, backup numbering, the temp name, and the child
 * environment.
 *
 * The worker is driven against a FAKE ocrmypdf.cmd written into %TEMP% that
 * copies a fixture over its output argument -- golden.pdf, which has a text
 * layer, so the core's validation says SWAP; and a copy of golden.pdf with
 * every text operation stripped (spdf_delete_all_text), so the first attempt
 * says RETRY_FORCE and the forced one FAIL_NO_TEXT, leaving the original
 * untouched. The two host-side file operations (backup copy, MoveFileEx swap)
 * run on a scratch copy. No real tesseract, no ocrmypdf.
 */
/* spdf-test-sources: portable/win/src/spdf_win_ocr.cpp portable/win/src/spdf_win_toolchain.cpp portable/win/src/spdf_win_toolchain_cmd.cpp portable/win/src/spdf_win_toolchain_plan.cpp portable/win/src/spdf_win_toolchain_run.cpp portable/win/src/spdf_win_toolchain_process.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf */
/* spdf-test-needs: mupdf */
#include "spdf_win_ocr.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shenzhen_pdf_core.h"

static int g_failures = 0;
static int g_checks = 0;

static void fail(const char* what, const char* file, int line) {
    fprintf(stderr, "FAIL %s (%s:%d)\n", what, file, line);
    ++g_failures;
}

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) fail(#cond, __FILE__, __LINE__);                                                                   \
    } while (0)

#define CHECK_STR(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (strcmp((a), (b)) != 0) {                                                                                   \
            fprintf(stderr, "FAIL %s == \"%s\" (got \"%s\") (%s:%d)\n", #a, (b), (a), __FILE__, __LINE__);            \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- pure ------------------------------------------------------------------- */

static void test_language_table(void) {
    int count = 0;
    const SpdfWinOcrLanguage* langs = spdf_win_ocr_languages(&count);
    CHECK(count == 19);
    CHECK_STR(langs[0].code, "chi_sim+eng");
    CHECK_STR(langs[0].label, "Chinese Simplified + English");
    CHECK_STR(langs[4].code, "eng");
    CHECK_STR(langs[18].code, "ron");
    CHECK(spdf_win_ocr_language_index("eng") == 4);
    CHECK(spdf_win_ocr_language_index("chi_tra") == 3);
    CHECK(spdf_win_ocr_language_index("xx") == -1);
    CHECK(spdf_win_ocr_language_index(NULL) == -1);
}

static void test_command(void) {
    char cmd[SPDF_WIN_TC_CMD];
    spdf_win_ocr_command("C:\\S\\ocrmypdf.exe", 0, "chi_sim+eng", 8, 0, 0, "C:\\d\\in.pdf", "C:\\d\\.in.pdf.ocr-1.pdf", cmd,
                         sizeof(cmd));
    CHECK_STR(cmd, "C:\\S\\ocrmypdf.exe --jobs 8 --rotate-pages --optimize 1 -l chi_sim+eng --deskew C:\\d\\in.pdf "
                   "C:\\d\\.in.pdf.ocr-1.pdf");
    spdf_win_ocr_command("C:\\S\\ocrmypdf.exe", 0, "eng", 8, 0, 1, "in", "out", cmd, sizeof(cmd));
    CHECK(strstr(cmd, "--deskew --force-ocr in out") != NULL);
    spdf_win_ocr_command("C:\\S\\ocrmypdf.exe", 0, "eng", 8, 1, 0, "in", "out", cmd, sizeof(cmd));
    CHECK(strstr(cmd, " -l eng --redo-ocr in out") != NULL && !strstr(cmd, "--deskew"));
    /* jobs floor, python module form, quoting of a path with spaces. */
    spdf_win_ocr_command("C:\\Py Dir\\python.exe", 1, "eng", 0, 1, 0, "C:\\My Docs\\a b.pdf", "out", cmd, sizeof(cmd));
    CHECK_STR(cmd, "\"C:\\Py Dir\\python.exe\" -m ocrmypdf --jobs 1 --rotate-pages --optimize 1 -l eng --redo-ocr "
                   "\"C:\\My Docs\\a b.pdf\" out");
}

static void test_verdict(void) {
    CHECK(spdf_win_ocr_validation_verdict(1, 1, 0, 0) == SPDF_WIN_OCR_SWAP);
    CHECK(spdf_win_ocr_validation_verdict(1, 1, 1, 0) == SPDF_WIN_OCR_SWAP);
    CHECK(spdf_win_ocr_validation_verdict(1, 1, 0, 1) == SPDF_WIN_OCR_SWAP);
    CHECK(spdf_win_ocr_validation_verdict(1, 0, 0, 0) == SPDF_WIN_OCR_RETRY_FORCE);
    CHECK(spdf_win_ocr_validation_verdict(1, 0, 0, 1) == SPDF_WIN_OCR_FAIL_NO_TEXT);
    CHECK(spdf_win_ocr_validation_verdict(1, 0, 1, 0) == SPDF_WIN_OCR_FAIL_NO_TEXT);
    CHECK(spdf_win_ocr_validation_verdict(1, -1, 0, 0) == SPDF_WIN_OCR_FAIL_ERROR);
    CHECK(spdf_win_ocr_validation_verdict(0, 1, 0, 0) == SPDF_WIN_OCR_FAIL_ERROR);
}

static void test_failure_message(void) {
    char out[1024];
    spdf_win_ocr_failure_message("some stderr text", out, sizeof(out));
    CHECK_STR(out, "some stderr text");
    spdf_win_ocr_failure_message(NULL, out, sizeof(out));
    CHECK_STR(out, "OCRmyPDF exited with an error.");
    spdf_win_ocr_failure_message("ERROR: --redo-ocr is not compatible with this PDF", out, sizeof(out));
    CHECK(strstr(out, "OCRmyPDF rejected --redo-ocr") != NULL);
    spdf_win_ocr_failure_message("Traceback (most recent call last):\n  File ...", out, sizeof(out));
    CHECK(strstr(out, "OCRmyPDF crashed while processing this PDF.") != NULL);
}

static void test_names(void) {
    char out[SPDF_WIN_TC_PATH];
    CHECK(spdf_win_ocr_backup_candidate("C:\\docs\\manual.pdf", 0, out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\manual_backup.pdf");
    CHECK(spdf_win_ocr_backup_candidate("C:\\docs\\manual.pdf", 1, out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\manual_backup_2.pdf");
    CHECK(spdf_win_ocr_backup_candidate("C:\\docs\\manual.pdf", 2, out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\manual_backup_3.pdf");
    CHECK(spdf_win_ocr_backup_candidate("C:\\docs\\manual", 0, out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\manual_backup.pdf");
    CHECK(spdf_win_ocr_backup_candidate("C:\\docs\\manual.PDF", 0, out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\manual_backup.PDF");
    CHECK(spdf_win_ocr_backup_candidate("C:/docs/manual.pdf", 0, out, sizeof(out)));
    CHECK_STR(out, "C:/docs/manual_backup.pdf"); /* the caller's separator survives */
    CHECK(spdf_win_ocr_backup_candidate("manual.pdf", 0, out, sizeof(out)));
    CHECK_STR(out, "manual_backup.pdf");
    CHECK(!spdf_win_ocr_backup_candidate(NULL, 0, out, sizeof(out)));
    CHECK(spdf_win_ocr_temp_path("C:\\docs\\manual.pdf", 12345, out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\.manual.pdf.ocr-12345.pdf");
    CHECK(!spdf_win_ocr_temp_path(NULL, 1, out, sizeof(out)));
    CHECK(!spdf_win_ocr_backup_candidate("C:\\docs\\manual.pdf", 0, out, 8)); /* does not fit: refused, not cut */
}

static void test_env(void) {
    char env[SPDF_WIN_TC_ENV];
    size_t n = spdf_win_ocr_env("C:\\Program Files\\Tesseract-OCR", "C:\\gs\\bin", "", "C:\\L\\ShenzhenPDF\\tesseract", env,
                                sizeof(env));
    CHECK_STR(env, "PATH=C:\\Program Files\\Tesseract-OCR;C:\\gs\\bin");
    CHECK_STR(env + strlen(env) + 1, "TESSDATA_PREFIX=C:\\L\\ShenzhenPDF\\tesseract");
    CHECK(n == strlen("PATH=C:\\Program Files\\Tesseract-OCR;C:\\gs\\bin") + 1 +
                   strlen("TESSDATA_PREFIX=C:\\L\\ShenzhenPDF\\tesseract") + 1 + 1);
    n = spdf_win_ocr_env("", "", "", NULL, env, sizeof(env));
    CHECK(n == 1 && env[0] == '\0'); /* nothing to add: an empty block */
    n = spdf_win_ocr_env("", "", "C:\\S", NULL, env, sizeof(env));
    CHECK_STR(env, "PATH=C:\\S");
    CHECK(env[strlen(env) + 1] == '\0');
}

/* --- the worker against a fake ocrmypdf ---------------------------------------- */

typedef struct done_record {
    HANDLE event;
    int success, cancelled;
    char message[2048];
    char output[SPDF_WIN_TC_PATH];
    int lines;
    int saw_retry;
} done_record;

static void on_line(const char* line, void* user) {
    done_record* d = (done_record*)user;
    ++d->lines;
    if (strstr(line, "forced image OCR")) d->saw_retry = 1;
}
static void on_status(const char* line, void* user) { (void)line; (void)user; }
static void on_done(int success, int cancelled, const char* message, const char* output, void* user) {
    done_record* d = (done_record*)user;
    d->success = success;
    d->cancelled = cancelled;
    snprintf(d->message, sizeof(d->message), "%s", message ? message : "");
    snprintf(d->output, sizeof(d->output), "%s", output ? output : "");
    SetEvent(d->event);
}

static void write_fake(const char* path, const char* fixture) {
    FILE* f = fopen(path, "wb");
    if (!f) return;
    /* Last two arguments are input and output, whatever comes before them. */
    fprintf(f,
            "@echo off\r\nset \"IN=\"\r\nset \"OUT=\"\r\n:loop\r\nif \"%%~1\"==\"\" goto done\r\nset \"IN=%%OUT%%\"\r\n"
            "set \"OUT=%%~1\"\r\nshift\r\ngoto loop\r\n:done\r\necho fake ocrmypdf: tesseract on PATH = %%PATH%%\r\n"
            "copy /y \"%s\" \"%%OUT%%\" >nul\r\necho fake ocrmypdf wrote %%OUT%%\r\n",
            fixture);
    fclose(f);
}

static long file_size(const char* path) {
    FILE* f = fopen(path, "rb");
    long n;
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fclose(f);
    return n;
}

static int run_fake(const char* fake, const char* pdf, int input_has_text, done_record* d) {
    SpdfWinToolchainState tools;
    SpdfWinToolchainRoots roots;
    SpdfWinOcrRequest req;
    SpdfWinOcrCallbacks cb;
    SpdfWinOcrJob* job;
    memset(&tools, 0, sizeof(tools));
    memset(&roots, 0, sizeof(roots));
    strcpy(tools.path[SPDF_WIN_TOOL_OCRMYPDF], fake);
    strcpy(tools.path[SPDF_WIN_TOOL_TESSERACT], "C:\\Fake\\Tesseract-OCR\\tesseract.exe");
    memset(&req, 0, sizeof(req));
    req.pdf_path = pdf;
    req.language = "eng";
    req.language_label = "English";
    req.input_has_text = input_has_text;
    req.tools = &tools;
    req.roots = &roots;
    memset(&cb, 0, sizeof(cb));
    cb.user = d;
    cb.on_line = on_line;
    cb.on_status = on_status;
    cb.on_done = on_done;
    memset(d, 0, sizeof(*d));
    d->event = CreateEventW(NULL, TRUE, FALSE, NULL);
    job = spdf_win_ocr_start(&req, &cb);
    if (!job) return 0;
    WaitForSingleObject(d->event, 60000);
    spdf_win_ocr_free(job);
    CloseHandle(d->event);
    return 1;
}

static void test_worker(const char* golden) {
    char tmp[MAX_PATH], fake_text[MAX_PATH], fake_blank[MAX_PATH], scratch[MAX_PATH], backup[MAX_PATH], err[256];
    char alpha[MAX_PATH]; /* golden.pdf with every text operation stripped: the image-only stand-in */
    done_record d;
    long golden_size = file_size(golden), alpha_size;
    if (!GetTempPathA(MAX_PATH, tmp)) return;
    snprintf(fake_text, sizeof(fake_text), "%sspdf-fake-ocrmypdf-text.cmd", tmp);
    snprintf(fake_blank, sizeof(fake_blank), "%sspdf-fake-ocrmypdf-blank.cmd", tmp);
    snprintf(scratch, sizeof(scratch), "%sspdf ocr scratch.pdf", tmp); /* a space, on purpose */
    snprintf(alpha, sizeof(alpha), "%sspdf-ocr-notext.pdf", tmp);

    /* The fixtures are what the header says they are, or the cases below mean
     * nothing: golden has a text layer; the no-text one is made from it with
     * the core's own text stripper (the same call the app would use to re-OCR). */
    {
        spdf_document* doc = spdf_open(golden, err, sizeof(err));
        CHECK(doc && spdf_document_has_text(doc, 0, err, sizeof(err)) == 1);
        CHECK(doc && spdf_delete_all_text(doc, alpha, err, sizeof(err)) == 1);
        if (doc) spdf_close(doc);
        doc = spdf_open(alpha, err, sizeof(err));
        CHECK(doc && spdf_document_has_text(doc, 0, err, sizeof(err)) == 0);
        if (doc) spdf_close(doc);
    }
    alpha_size = file_size(alpha);
    write_fake(fake_text, golden);
    write_fake(fake_blank, alpha);
    CopyFileA(alpha, scratch, FALSE);
    CHECK(golden_size > 0 && alpha_size > 0 && golden_size != alpha_size);

    /* Text produced: the worker leaves the validated output beside the input. */
    CHECK(run_fake(fake_text, scratch, 0, &d));
    CHECK(d.success == 1 && d.cancelled == 0);
    CHECK_STR(d.message, "OCR complete.");
    CHECK(d.output[0] && strstr(d.output, ".spdf ocr scratch.pdf.ocr-") != NULL);
    CHECK(file_size(d.output) == golden_size);
    CHECK(file_size(scratch) == alpha_size); /* the original is untouched until the host swaps */
    CHECK(d.lines >= 3);
    /* The host's swap, with every handle closed. */
    err[0] = '\0';
    CHECK(spdf_win_ocr_install_output(d.output, scratch, err, sizeof(err)));
    CHECK(file_size(scratch) == golden_size);
    CHECK(file_size(d.output) == -1);

    /* No text produced: one forced retry, then failure with the original untouched. */
    CopyFileA(alpha, scratch, FALSE);
    CHECK(run_fake(fake_blank, scratch, 0, &d));
    CHECK(d.success == 0 && d.cancelled == 0);
    CHECK(d.saw_retry);
    CHECK(strstr(d.message, "no selectable text was detected") != NULL);
    CHECK(d.output[0] == '\0');
    CHECK(file_size(scratch) == alpha_size);

    /* Redo path: no retry, straight to the no-text failure. */
    CHECK(run_fake(fake_blank, scratch, 1, &d));
    CHECK(d.success == 0 && !d.saw_retry);

    /* Backup numbering on disk: _backup, then _backup_2. */
    err[0] = '\0';
    CHECK(spdf_win_ocr_write_backup(scratch, backup, sizeof(backup), err, sizeof(err)));
    CHECK(strstr(backup, "spdf ocr scratch_backup.pdf") != NULL);
    CHECK(file_size(backup) == alpha_size);
    CHECK(spdf_win_ocr_write_backup(scratch, backup, sizeof(backup), err, sizeof(err)));
    CHECK(strstr(backup, "spdf ocr scratch_backup_2.pdf") != NULL);
    DeleteFileA(backup);
    spdf_win_ocr_backup_candidate(scratch, 0, backup, sizeof(backup));
    DeleteFileA(backup);
    DeleteFileA(scratch);
    DeleteFileA(alpha);
    DeleteFileA(fake_text);
    DeleteFileA(fake_blank);
}

int main(int argc, char** argv) {
    test_language_table();
    test_command();
    test_verdict();
    test_failure_message();
    test_names();
    test_env();
    if (argc >= 2) test_worker(argv[1]);
    else fprintf(stderr, "ocr_test: no fixture given; worker cases skipped\n");
    printf("ocr_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
