/* tools_e2e_probe.c -- drives the power tools' REAL flow from a console, the
 * same functions the panel calls in the same order, so the end-to-end proof
 * (install the toolchain through our own plan, OCR an image-only PDF, verify
 * the text layer with the core; install Argos, translate a text) can be run
 * and logged from a shell -- and so it can be re-run later by anyone.
 *
 *   tools_e2e_probe probe [language]
 *       print what spdf_win_toolchain_probe() finds and the OCR install plan
 *   tools_e2e_probe install-ocr <language>
 *       run the OCR install plan step by step, streaming the log; exit 0 when
 *       a re-probe finds nothing missing
 *   tools_e2e_probe ocr <pdf> <language>
 *       run OCR on the file IN PLACE (backup first when it has text), swap the
 *       validated output in, report whether the core now finds text
 *   tools_e2e_probe install-argos <from> <to>
 *       run the Argos install plan including the translate-<from>_<to> package
 *   tools_e2e_probe translate <from> <to> <text...|@utf8-file>
 *       translate the text through Argos and print the result
 *
 * NOT a test: it changes the machine (that is the point) and needs the network
 * for the install modes. Its name is deliberately not *_test.c so the harness
 * never discovers it. Build it with build-native.cmd and the source list in
 * tools_e2e.sh beside it.
 */
#include "spdf_win_ocr.h"
#include "spdf_win_toolchain.h"
#include "spdf_win_translate.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shenzhen_pdf_core.h"

static void say(const char* line, void* user) {
    (void)user;
    printf("%s\n", line);
    fflush(stdout);
}

static void print_probe(const SpdfWinToolchainState* st) {
    for (int t = 0; t < SPDF_WIN_TOOL_COUNT; ++t)
        printf("  %-20s %s\n", spdf_win_tool_exe((spdf_win_tool)t), st->path[t][0] ? st->path[t] : "(missing)");
    for (int i = 0; i < st->missing_language_count; ++i) printf("  missing language     %s\n", st->missing_languages[i]);
}

static int run_plan(const SpdfWinToolchainPlan* plan, const SpdfWinToolchainRoots* roots) {
    if (plan->count == 0) {
        printf("nothing to install\n");
        return 1;
    }
    for (int i = 0; i < plan->count; ++i) printf("plan[%d] kind=%d %s\n", i, plan->steps[i].kind, plan->steps[i].label);
    for (int i = 0; i < plan->count; ++i) {
        if (!spdf_win_toolchain_run_step(&plan->steps[i], roots, NULL, say, NULL)) {
            printf("STEP FAILED: %s\n", plan->steps[i].label);
            return 0;
        }
    }
    return 1;
}

typedef struct done {
    HANDLE event;
    int success, cancelled;
    char message[2048], output[SPDF_WIN_TC_PATH];
} done;

static void on_status(const char* s, void* u) { (void)u; printf("[status] %s\n", s); fflush(stdout); }
static void on_done(int success, int cancelled, const char* message, const char* output, void* u) {
    done* d = (done*)u;
    d->success = success;
    d->cancelled = cancelled;
    snprintf(d->message, sizeof(d->message), "%s", message ? message : "");
    snprintf(d->output, sizeof(d->output), "%s", output ? output : "");
    SetEvent(d->event);
}

static int has_text(const char* path) {
    char err[512] = "";
    spdf_document* doc = spdf_open(path, err, sizeof(err));
    int has;
    if (!doc) {
        printf("core could not open %s: %s\n", path, err);
        return -1;
    }
    has = spdf_document_has_text(doc, 0, err, sizeof(err));
    spdf_close(doc);
    return has;
}

int main(int argc, char** argv) {
    SpdfWinToolchainRoots roots;
    SpdfWinToolchainState st;
    SpdfWinToolchainPlan plan;
    const char* mode = argc > 1 ? argv[1] : "probe";

    spdf_win_toolchain_roots_from_env(&roots);
    printf("roots: ProgramFiles=%s LOCALAPPDATA=%s user_scripts=%s\n", roots.program_files, roots.local_appdata,
           roots.user_scripts[0] ? roots.user_scripts : "(none)");

    if (strcmp(mode, "probe") == 0) {
        const char* language = argc > 2 ? argv[2] : "eng";
        spdf_win_toolchain_probe(&roots, language, &st);
        print_probe(&st);
        spdf_win_toolchain_ocr_plan(&st, &roots, language, &plan);
        for (int i = 0; i < plan.count; ++i) printf("ocr plan[%d] kind=%d %s\n", i, plan.steps[i].kind, plan.steps[i].label);
        spdf_win_toolchain_argos_plan(&st, &roots, "zh", "en", 0, &plan);
        for (int i = 0; i < plan.count; ++i) printf("argos plan[%d] kind=%d %s\n", i, plan.steps[i].kind, plan.steps[i].label);
        return 0;
    }
    if (strcmp(mode, "install-ocr") == 0) {
        const char* language = argc > 2 ? argv[2] : "eng";
        spdf_win_toolchain_probe(&roots, language, &st);
        print_probe(&st);
        spdf_win_toolchain_ocr_plan(&st, &roots, language, &plan);
        if (!run_plan(&plan, &roots)) return 1;
        spdf_win_toolchain_roots_from_env(&roots);
        spdf_win_toolchain_probe(&roots, language, &st);
        printf("after install:\n");
        print_probe(&st);
        spdf_win_toolchain_ocr_plan(&st, &roots, language, &plan);
        printf("remaining plan steps: %d\n", plan.count);
        return plan.count == 0 ? 0 : 1;
    }
    if (strcmp(mode, "ocr") == 0 && argc > 3) {
        const char* pdf = argv[2];
        const char* language = argv[3];
        SpdfWinOcrRequest req;
        SpdfWinOcrCallbacks cb;
        SpdfWinOcrJob* job;
        done d;
        char err[512] = "", backup[SPDF_WIN_TC_PATH];
        int before = has_text(pdf);
        printf("before: has_text=%d\n", before);
        spdf_win_toolchain_probe(&roots, language, &st);
        spdf_win_toolchain_ocr_plan(&st, &roots, language, &plan);
        if (plan.count) {
            printf("toolchain incomplete; run install-ocr first\n");
            return 2;
        }
        if (before > 0) {
            if (!spdf_win_ocr_write_backup(pdf, backup, sizeof(backup), err, sizeof(err))) {
                printf("backup failed: %s\n", err);
                return 1;
            }
            printf("backup: %s\n", backup);
        }
        memset(&req, 0, sizeof(req));
        req.pdf_path = pdf;
        req.language = language;
        req.language_label = language;
        req.input_has_text = before > 0;
        req.tools = &st;
        req.roots = &roots;
        memset(&cb, 0, sizeof(cb));
        cb.user = &d;
        cb.on_line = say;
        cb.on_status = on_status;
        cb.on_done = on_done;
        memset(&d, 0, sizeof(d));
        d.event = CreateEventW(NULL, TRUE, FALSE, NULL);
        job = spdf_win_ocr_start(&req, &cb);
        if (!job) {
            printf("could not start OCR\n");
            return 1;
        }
        WaitForSingleObject(d.event, INFINITE);
        spdf_win_ocr_free(job);
        printf("done: success=%d cancelled=%d message=%s output=%s\n", d.success, d.cancelled, d.message, d.output);
        if (!d.success) return 1;
        if (!spdf_win_ocr_install_output(d.output, pdf, err, sizeof(err))) {
            printf("swap failed: %s\n", err);
            return 1;
        }
        printf("after: has_text=%d\n", has_text(pdf));
        return has_text(pdf) == 1 ? 0 : 1;
    }
    if (strcmp(mode, "install-argos") == 0 && argc > 3) {
        spdf_win_toolchain_probe(&roots, NULL, &st);
        print_probe(&st);
        spdf_win_toolchain_argos_plan(&st, &roots, argv[2], argv[3], 1, &plan);
        if (!run_plan(&plan, &roots)) return 1;
        spdf_win_toolchain_roots_from_env(&roots);
        spdf_win_toolchain_probe(&roots, NULL, &st);
        printf("after install:\n");
        print_probe(&st);
        return spdf_win_toolchain_has(&st, SPDF_WIN_TOOL_ARGOS_TRANSLATE) ? 0 : 1;
    }
    if (strcmp(mode, "translate") == 0 && argc > 4) {
        char text[4096] = "", err[2048] = "";
        char* out = NULL;
        int rc;
        if (argv[4][0] == '@') {
            /* "@file": UTF-8 from a file, because main()'s argv is the ANSI
             * code page and CJK on a 1252 console would arrive as '?'. */
            FILE* f = fopen(argv[4] + 1, "rb");
            size_t n = f ? fread(text, 1, sizeof(text) - 1, f) : 0;
            if (f) fclose(f);
            text[n] = '\0';
        } else {
            for (int i = 4; i < argc; ++i) {
                size_t n = strlen(text);
                snprintf(text + n, sizeof(text) - n, "%s%s", n ? " " : "", argv[i]);
            }
        }
        spdf_win_toolchain_probe(&roots, NULL, &st);
        rc = spdf_win_translate_text(st.path[SPDF_WIN_TOOL_ARGOS_TRANSLATE], roots.user_scripts, argv[2], argv[3], text,
                                     NULL, &out, err, sizeof(err));
        printf("rc=%d\n", rc);
        if (rc > 0) printf("translation: %s\n", out);
        else printf("error: %s (missing package: %d)\n", err, spdf_win_toolchain_argos_failure_is_missing_package(err));
        free(out);
        return rc > 0 ? 0 : 1;
    }
    fprintf(stderr, "usage: see the header of tools_e2e_probe.c\n");
    return 64;
}
