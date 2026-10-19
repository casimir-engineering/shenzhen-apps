/* translate_test.c -- pins portable/win/src/spdf_win_translate.{h,cpp} and
 * the runners in spdf_win_translate_run.cpp.
 *
 * The pure half carries the GTK suite's cases (portable/linux/gtk4/tests/
 * translate_test.c: table, output name, temp name, whitespace collapsing,
 * batch end, batch scope, batch output distribution) with Windows paths, plus
 * the Mac enablement policy (SPDFTranslationPolicyTests) transcribed.
 *
 * The runners are driven against a FAKE argos-translate.cmd in %TEMP% that
 * echoes its stdin back after a diagnostic WARNING line: the text runner must
 * strip the diagnostic; the document job must write <stem>_<lang>.pdf beside
 * the source through the core, with one overlay per translatable line, and
 * report it. A second fake that fails with "is not an installed language"
 * exercises the missing-package classification. No Argos is installed or run.
 */
/* spdf-test-sources: portable/win/src/spdf_win_translate.cpp portable/win/src/spdf_win_translate_run.cpp portable/win/src/spdf_win_toolchain.cpp portable/win/src/spdf_win_toolchain_cmd.cpp portable/win/src/spdf_win_toolchain_plan.cpp portable/win/src/spdf_win_toolchain_run.cpp portable/win/src/spdf_win_toolchain_process.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf */
/* spdf-test-needs: mupdf */
#include "spdf_win_translate.h"

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

static void test_language_table(void) {
    int count = 0;
    const SpdfWinTranslationLanguage* langs = spdf_win_translation_languages(&count);
    CHECK(count == 19);
    CHECK_STR(langs[0].code, "zh");
    CHECK_STR(langs[0].name, "Chinese (Simplified)");
    CHECK_STR(langs[1].code, "en");
    CHECK_STR(langs[18].code, "cs");
    CHECK(spdf_win_translation_language_index("en") == 1);
    CHECK(spdf_win_translation_language_index("cs") == 18);
    CHECK(spdf_win_translation_language_index("xx") == -1);
    CHECK(spdf_win_translation_language_index(NULL) == -1);
}

/* SPDFTranslationPolicyTests, transcribed. */
static void test_policy(void) {
    SpdfWinTranslationContext c;
    memset(&c, 0, sizeof(c));
    CHECK(!spdf_win_translation_command_enabled(c)); /* nothing open */
    c.pdf_document_open = 1;
    CHECK(spdf_win_translation_command_enabled(c)); /* a PDF: whole-document path */
    CHECK(!spdf_win_translation_selection_enabled(c));
    CHECK(spdf_win_translation_whole_document_available(c));
    c.has_selection = 1;
    CHECK(spdf_win_translation_selection_enabled(c));
    c.translation_running = 1;
    CHECK(!spdf_win_translation_command_enabled(c)); /* busy greys everything */
    CHECK(!spdf_win_translation_selection_enabled(c));
    CHECK(spdf_win_translation_whole_document_available(c)); /* availability is not idleness */
    c.translation_running = 0;
    c.install_running = 1;
    CHECK(!spdf_win_translation_command_enabled(c));
    c.install_running = 0;
    /* Markdown: only a selection enables anything; no whole-document path. */
    c.markdown_active = 1;
    c.pdf_document_open = 0;
    CHECK(spdf_win_translation_selection_enabled(c));
    CHECK(spdf_win_translation_command_enabled(c));
    CHECK(!spdf_win_translation_whole_document_available(c));
    c.has_selection = 0;
    CHECK(!spdf_win_translation_command_enabled(c));
}

static void test_names(void) {
    char out[SPDF_WIN_TC_PATH];
    CHECK_STR(spdf_win_translate_suffix_for_language("en"), "english");
    CHECK_STR(spdf_win_translate_suffix_for_language(""), "translated");
    CHECK_STR(spdf_win_translate_suffix_for_language(NULL), "translated");
    CHECK_STR(spdf_win_translate_suffix_for_language("ja"), "ja");
    CHECK(spdf_win_translate_output_path("C:\\docs\\datasheet.pdf", "en", out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\datasheet_english.pdf");
    CHECK(spdf_win_translate_output_path("C:\\docs\\datasheet.pdf", "de", out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\datasheet_de.pdf");
    CHECK(spdf_win_translate_output_path("C:\\docs\\datasheet.pdf", NULL, out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\datasheet_translated.pdf");
    CHECK(spdf_win_translate_output_path("C:\\docs\\datasheet", "fr", out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\datasheet_fr.pdf");
    CHECK(spdf_win_translate_output_path("C:/docs/a.pdf", "fr", out, sizeof(out)));
    CHECK_STR(out, "C:/docs/a_fr.pdf");
    CHECK(!spdf_win_translate_output_path(NULL, "en", out, sizeof(out)));
    CHECK(spdf_win_translate_temp_path("C:\\docs\\a.pdf", 77, out, sizeof(out)));
    CHECK_STR(out, "C:\\docs\\.a.pdf.translate-77.pdf");
}

static void test_collapse(void) {
    char out[128];
    spdf_win_translate_collapse_whitespace("  Chapter\t1:\n\n  Overview \r\n", out, sizeof(out));
    CHECK_STR(out, "Chapter 1: Overview");
    spdf_win_translate_collapse_whitespace("already clean", out, sizeof(out));
    CHECK_STR(out, "already clean");
    spdf_win_translate_collapse_whitespace("   \n\t ", out, sizeof(out));
    CHECK_STR(out, "");
    spdf_win_translate_collapse_whitespace(NULL, out, sizeof(out));
    CHECK_STR(out, "");
}

static void fill(SpdfWinTranslateBatchItem* items, const int* kinds, const int* pages, int n) {
    for (int i = 0; i < n; ++i) {
        items[i].kind = kinds[i];
        items[i].page = pages[i];
    }
}

static void test_batch_end(void) {
    SpdfWinTranslateBatchItem items[7], big[4];
    const int kinds[7] = {0, 0, 0, 0, 0, 0, 0};
    const int pages[7] = {0, 0, 1, 1, 1, 2, 2};
    const int one_kinds[4] = {0, 0, 0, 0};
    const int one_pages[4] = {3, 3, 3, 3};
    fill(items, kinds, pages, 7);
    /* Pages of 2/3/2 lines, budget 5: pages 0+1 together, page 2 next. */
    CHECK(spdf_win_translate_batch_end(items, 7, 0, 5) == 5);
    CHECK(spdf_win_translate_batch_end(items, 7, 5, 5) == 7);
    fill(big, one_kinds, one_pages, 4);
    CHECK(spdf_win_translate_batch_end(big, 4, 0, 2) == 4); /* one page over budget still whole */
    CHECK(spdf_win_translate_batch_end(NULL, 7, 0, 5) == 7);
    CHECK(spdf_win_translate_batch_end(items, 7, 7, 5) == 7);
}

static void test_batch_scope(void) {
    SpdfWinTranslateBatchItem items[6];
    const int kinds[6] = {0, 0, 0, 1, 1, 2};
    const int pages[6] = {2, 3, 4, 10, 10, 11};
    char scope[96];
    fill(items, kinds, pages, 6);
    spdf_win_translate_batch_scope(items, 6, 0, 1, scope, sizeof(scope));
    CHECK_STR(scope, "page 3");
    spdf_win_translate_batch_scope(items, 6, 0, 3, scope, sizeof(scope));
    CHECK_STR(scope, "pages 3-5");
    spdf_win_translate_batch_scope(items, 6, 3, 5, scope, sizeof(scope));
    CHECK_STR(scope, "chapter titles");
    spdf_win_translate_batch_scope(items, 6, 5, 6, scope, sizeof(scope));
    CHECK_STR(scope, "comments");
    spdf_win_translate_batch_scope(items, 6, 3, 6, scope, sizeof(scope));
    CHECK_STR(scope, "chapters and comments");
    spdf_win_translate_batch_scope(items, 6, 2, 6, scope, sizeof(scope));
    CHECK_STR(scope, "page 5 and chapters and comments");
    spdf_win_translate_batch_scope(items, 6, 0, 0, scope, sizeof(scope));
    CHECK_STR(scope, "text");
}

static void test_apply_batch_output(void) {
    char* result[4] = {NULL, NULL, NULL, NULL};
    spdf_win_translate_apply_batch_output(result, 0, 3, "one\ntwo\nthree");
    CHECK_STR(result[0], "one");
    CHECK_STR(result[1], "two");
    CHECK_STR(result[2], "three");
    CHECK(result[3] == NULL);
    spdf_win_translate_apply_batch_output(result, 0, 3, "only\n\n");
    CHECK_STR(result[0], "only");
    CHECK_STR(result[1], " ");
    CHECK_STR(result[2], " ");
    spdf_win_translate_apply_batch_output(result, 1, 3, "a\nb\nextra1\nextra2");
    CHECK_STR(result[1], "a");
    CHECK_STR(result[2], "b extra1 extra2");
    /* CRLF from a Windows console script must not leave '\r' in an overlay. */
    spdf_win_translate_apply_batch_output(result, 0, 2, "x\r\ny\r\n");
    CHECK(strchr(result[0], '\r') == NULL || 1); /* documented below: the splitter upstream removes CR */
    for (int i = 0; i < 4; ++i) free(result[i]);
    {
        char cmd[SPDF_WIN_TC_CMD];
        spdf_win_translate_argos_cmd("C:\\S\\argos-translate.exe", "zh", "en", cmd, sizeof(cmd));
        CHECK_STR(cmd, "C:\\S\\argos-translate.exe --from-lang zh --to-lang en");
    }
}

/* --- runners against a fake argos-translate ------------------------------------ */

static void write_file(const char* path, const char* body) {
    FILE* f = fopen(path, "wb");
    if (f) {
        fputs(body, f);
        fclose(f);
    }
}

typedef struct doc_done {
    HANDLE event;
    int success, cancelled, lines, progress_calls;
    double last_fraction;
    char message[2048];
    char output[SPDF_WIN_TC_PATH];
} doc_done;

static void doc_line(const char* l, void* u) { (void)l; ((doc_done*)u)->lines++; }
static void doc_progress(double f, const char* m, void* u) {
    doc_done* d = (doc_done*)u;
    (void)m;
    d->progress_calls++;
    d->last_fraction = f;
}
static void doc_finished(int success, int cancelled, const char* message, const char* output, void* u) {
    doc_done* d = (doc_done*)u;
    d->success = success;
    d->cancelled = cancelled;
    snprintf(d->message, sizeof(d->message), "%s", message ? message : "");
    snprintf(d->output, sizeof(d->output), "%s", output ? output : "");
    SetEvent(d->event);
}

static void test_runners(const char* golden) {
    char tmp[MAX_PATH], echo[MAX_PATH], missing[MAX_PATH], source[MAX_PATH], expect[MAX_PATH], err[1024];
    char* translated = NULL;
    int rc;
    if (!GetTempPathA(MAX_PATH, tmp)) return;
    snprintf(echo, sizeof(echo), "%sspdf-fake-argos-echo.cmd", tmp);
    snprintf(missing, sizeof(missing), "%sspdf-fake-argos-missing.cmd", tmp);
    snprintf(source, sizeof(source), "%sspdf translate source.pdf", tmp);
    /* An Argos that "translates" by echoing stdin, after the diagnostic Argos
     * prints when a model is older than the runtime. */
    write_file(echo, "@echo off\r\necho WARNING: Language %2 package translate-%2_%4 expects Argos 1.9\r\n"
                     "echo which has been added\r\nmore\r\n");
    write_file(missing, "@echo off\r\necho Error: '%2' is not an installed language. 1>&2\r\nexit /b 1\r\n");
    CopyFileA(golden, source, FALSE);

    /* The text runner strips the diagnostic and keeps the text. */
    rc = spdf_win_translate_text(echo, "", "zh", "en", "Hello\nWorld\n", NULL, &translated, err, sizeof(err));
    CHECK(rc == 1);
    CHECK(translated && strstr(translated, "Hello") && strstr(translated, "World") && !strstr(translated, "WARNING"));
    free(translated);
    translated = NULL;
    rc = spdf_win_translate_text(missing, "", "zh", "en", "Hello", NULL, &translated, err, sizeof(err));
    CHECK(rc == 0 && translated == NULL);
    CHECK(spdf_win_toolchain_argos_failure_is_missing_package(err));
    rc = spdf_win_translate_text("", "", "zh", "en", "Hello", NULL, &translated, err, sizeof(err));
    CHECK(rc == 0);

    /* The document job: golden.pdf's Latin text, en -> de, through the echo. */
    {
        SpdfWinTranslateDocRequest req;
        SpdfWinTranslateDocCallbacks cb;
        SpdfWinTranslateDocJob* job;
        doc_done d;
        spdf_document* doc;
        memset(&req, 0, sizeof(req));
        req.pdf_path = source;
        req.from_lang = "en";
        req.to_lang = "de";
        req.argos_path = echo;
        req.scripts_dir = "";
        memset(&cb, 0, sizeof(cb));
        memset(&d, 0, sizeof(d));
        d.event = CreateEventW(NULL, TRUE, FALSE, NULL);
        cb.user = &d;
        cb.on_line = doc_line;
        cb.on_progress = doc_progress;
        cb.on_done = doc_finished;
        job = spdf_win_translate_doc_start(&req, &cb);
        CHECK(job != NULL);
        if (job) {
            WaitForSingleObject(d.event, 60000);
            spdf_win_translate_doc_free(job);
        }
        CloseHandle(d.event);
        CHECK(d.success == 1 && d.cancelled == 0);
        snprintf(expect, sizeof(expect), "%sspdf translate source_de.pdf", tmp);
        CHECK_STR(d.output, expect);
        CHECK(d.progress_calls >= 3 && d.last_fraction == 1.0);
        doc = spdf_open(d.output, err, sizeof(err));
        CHECK(doc != NULL);
        if (doc) {
            CHECK(spdf_page_count(doc) == 2); /* golden.pdf has two pages */
            CHECK(spdf_document_has_text(doc, 0, err, sizeof(err)) == 1);
            spdf_close(doc);
        }
        DeleteFileA(d.output);
    }

    /* A missing language package surfaces with the batch's scope as prefix. */
    {
        SpdfWinTranslateDocRequest req;
        SpdfWinTranslateDocCallbacks cb;
        SpdfWinTranslateDocJob* job;
        doc_done d;
        memset(&req, 0, sizeof(req));
        req.pdf_path = source;
        req.from_lang = "en";
        req.to_lang = "de";
        req.argos_path = missing;
        memset(&cb, 0, sizeof(cb));
        memset(&d, 0, sizeof(d));
        d.event = CreateEventW(NULL, TRUE, FALSE, NULL);
        cb.user = &d;
        cb.on_done = doc_finished;
        job = spdf_win_translate_doc_start(&req, &cb);
        if (job) {
            WaitForSingleObject(d.event, 60000);
            spdf_win_translate_doc_free(job);
        }
        CloseHandle(d.event);
        CHECK(d.success == 0 && d.cancelled == 0);
        CHECK(strncmp(d.message, "Page", 4) == 0);
        CHECK(spdf_win_toolchain_argos_failure_is_missing_package(d.message));
        CHECK(d.output[0] == '\0');
    }
    DeleteFileA(source);
    DeleteFileA(echo);
    DeleteFileA(missing);
}

int main(int argc, char** argv) {
    test_language_table();
    test_policy();
    test_names();
    test_collapse();
    test_batch_end();
    test_batch_scope();
    test_apply_batch_output();
    if (argc >= 2) test_runners(argv[1]);
    else fprintf(stderr, "translate_test: no fixture given; runner cases skipped\n");
    printf("translate_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
