// spdf_ocr.c — OCR flow for the GTK4 shell. Contract + GTK3 provenance map in
// spdf_ocr.h.

#include "spdf_ocr.h"

#include <errno.h>
#include <glib/gstdio.h>
#include <string.h>

/* ===========================================================================
 * Pure logic (glib only). Everything above the SPDF_OCR_TESTING guard is
 * exercised by tests/ocr_test.c.
 * ======================================================================== */

/* GTK3 OCR_LANGUAGE_OPTIONS / Mac spdf_ocr_languages(), verbatim. */
static const SpdfOcrLanguage k_ocr_languages[] = {
    {"chi_sim+eng", "Chinese Simplified + English"},
    {"chi_sim", "Chinese Simplified"},
    {"chi_tra+eng", "Chinese Traditional + English"},
    {"chi_tra", "Chinese Traditional"},
    {"eng", "English"},
    /* Top 10 most-spoken languages by total speakers (English and Mandarin above). */
    {"hin", "Hindi"},
    {"spa", "Spanish"},
    {"fra", "French"},
    {"ara", "Arabic"},
    {"ben", "Bengali"},
    {"por", "Portuguese"},
    {"rus", "Russian"},
    {"urd", "Urdu"},
    /* Large European languages (English, Spanish, French, Portuguese, Russian above). */
    {"deu", "German"},
    {"ita", "Italian"},
    {"pol", "Polish"},
    {"ukr", "Ukrainian"},
    {"nld", "Dutch"},
    {"ron", "Romanian"},
};

const SpdfOcrLanguage* spdf_ocr_languages(int* count) {
    if (count) *count = (int)G_N_ELEMENTS(k_ocr_languages);
    return k_ocr_languages;
}

int spdf_ocr_language_index(const char* code) {
    if (!code || !*code) return -1;
    for (guint i = 0; i < G_N_ELEMENTS(k_ocr_languages); ++i)
        if (g_strcmp0(k_ocr_languages[i].code, code) == 0) return (int)i;
    return -1;
}

char** spdf_ocr_build_argv(const char* tool, const char* language, guint jobs, gboolean has_text, gboolean force_ocr,
                           const char* input_path, const char* output_path) {
    GPtrArray* argv = g_ptr_array_new();

    g_ptr_array_add(argv, g_strdup(tool));
    g_ptr_array_add(argv, g_strdup("--jobs"));
    g_ptr_array_add(argv, g_strdup_printf("%u", MAX(1u, jobs)));
    g_ptr_array_add(argv, g_strdup("--rotate-pages"));
    g_ptr_array_add(argv, g_strdup("--optimize"));
    g_ptr_array_add(argv, g_strdup("1"));
    g_ptr_array_add(argv, g_strdup("-l"));
    g_ptr_array_add(argv, g_strdup(language));
    if (!has_text) {
        g_ptr_array_add(argv, g_strdup("--deskew"));
        if (force_ocr) g_ptr_array_add(argv, g_strdup("--force-ocr"));
    } else {
        g_ptr_array_add(argv, g_strdup("--redo-ocr"));
    }
    g_ptr_array_add(argv, g_strdup(input_path));
    g_ptr_array_add(argv, g_strdup(output_path));
    g_ptr_array_add(argv, NULL);
    return (char**)g_ptr_array_free(argv, FALSE);
}

SpdfOcrVerdict spdf_ocr_validation_verdict(gboolean run_ok, int output_has_text, gboolean input_had_text,
                                           gboolean forced) {
    if (!run_ok) return SPDF_OCR_FAIL_ERROR;
    if (output_has_text > 0) return SPDF_OCR_SWAP;
    if (output_has_text < 0) return SPDF_OCR_FAIL_ERROR;
    /* Completed but produced no selectable text. Image-only PDFs get one
     * forced retry (journal item 37); redo runs and forced runs fail. */
    if (!input_had_text && !forced) return SPDF_OCR_RETRY_FORCE;
    return SPDF_OCR_FAIL_NO_TEXT;
}

char* spdf_ocr_failure_message(const char* detail) {
    if (!detail || !*detail) return g_strdup("OCRmyPDF exited with an error.");

    if (strstr(detail, "--redo-ocr") && strstr(detail, "not compatible")) {
        return g_strdup(
            "OCRmyPDF rejected --redo-ocr for this PDF or OCRmyPDF version.\n\n"
            "The PDF already has text, and this OCRmyPDF build cannot redo OCR on it. "
            "Try updating OCRmyPDF, or run OCR on a copy without existing text.");
    }

    if (strstr(detail, "Traceback")) {
        return g_strdup(
            "OCRmyPDF crashed while processing this PDF.\n\n"
            "This looks like an OCRmyPDF compatibility error. Try updating OCRmyPDF and "
            "Tesseract, or run OCRmyPDF from a terminal to see the full traceback.");
    }

    return g_strdup(detail);
}

char* spdf_ocr_backup_candidate(const char* path, int index) {
    char* dir;
    char* base;
    char* dot;
    char* stem;
    const char* ext;
    char* name;
    char* candidate;

    if (!path || !*path) return NULL;
    dir = g_path_get_dirname(path);
    base = g_path_get_basename(path);
    dot = strrchr(base, '.');
    stem = dot ? g_strndup(base, (gsize)(dot - base)) : g_strdup(base);
    ext = dot && dot[1] ? dot + 1 : "pdf";
    if (index <= 0)
        name = g_strdup_printf("%s_backup.%s", stem, ext);
    else
        name = g_strdup_printf("%s_backup_%d.%s", stem, index + 1, ext);
    candidate = g_build_filename(dir, name, NULL);
    g_free(name);
    g_free(stem);
    g_free(base);
    g_free(dir);
    return candidate;
}

char* spdf_ocr_temp_path(const char* path, guint32 nonce) {
    char* dir;
    char* base;
    char* name;
    char* tmp;

    if (!path || !*path) return NULL;
    dir = g_path_get_dirname(path);
    base = g_path_get_basename(path);
    name = g_strdup_printf(".%s.ocr-%u.pdf", base, nonce);
    tmp = g_build_filename(dir, name, NULL);
    g_free(name);
    g_free(base);
    g_free(dir);
    return tmp;
}

#ifndef SPDF_OCR_TESTING
#include "spdf_password_prompt.h"

/* ===========================================================================
 * GTK flow.
 * ======================================================================== */

#include "spdf_annot.h"
#include "spdf_app.h"
#include "spdf_toolchain.h"

/* --- window-level running state ------------------------------------------ */

static gboolean ocr_is_running(SpdfWindow* win) {
    return g_object_get_data(G_OBJECT(win), "spdf-ocr-running") != NULL;
}

static void ocr_set_running(SpdfWindow* win, gboolean running) {
    GAction* action = g_action_map_lookup_action(G_ACTION_MAP(win), "ocr");
    g_object_set_data(G_OBJECT(win), "spdf-ocr-running", GINT_TO_POINTER(running ? 1 : 0));
    if (action && G_IS_SIMPLE_ACTION(action)) g_simple_action_set_enabled(G_SIMPLE_ACTION(action), !running);
}

static gboolean ocr_tab_alive(SpdfWindow* win, SpdfTab* tab) {
    int count;

    if (!win || !tab || !SPDF_IS_WINDOW(win)) return FALSE;
    count = spdf_window_tab_count(win);
    for (int i = 0; i < count; ++i)
        if (spdf_window_tab_at(win, i) == tab) return TRUE;
    return FALSE;
}

static void ocr_show_error(SpdfWindow* win, const char* heading, const char* detail) {
    GtkAlertDialog* alert = gtk_alert_dialog_new("%s", heading);
    gtk_alert_dialog_set_detail(alert, detail && *detail ? detail : "Unknown error.");
    gtk_alert_dialog_show(alert, win && SPDF_IS_WINDOW(win) ? GTK_WINDOW(win) : NULL);
    g_object_unref(alert);
}

static SpdfApp* ocr_window_app(SpdfWindow* win) {
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

/* Reload the tab's document from disk after OCR rewrote the file: fresh
 * main-thread doc, render cache dropped (worker docs re-open keyed on
 * path+mtime+size), view relayout, same page, session persisted. Mirrors
 * spdf_annot.c's annot_reload_document (GTK3 open_path_at_page semantics). */
static void ocr_reload_tab(SpdfWindow* win, SpdfTab* tab, int page) {
    char err[1024] = "";
    spdf_document* doc = spdf_password_open_document(tab->path, tab->credential, NULL, NULL, err, sizeof(err));
    SpdfApp* app;

    if (doc) {
        if (tab->doc) spdf_close(tab->doc);
        tab->doc = doc;
    } else {
        ocr_show_error(win, "Could not reload document after OCR", err);
    }
    if (tab->render) spdf_render_service_invalidate(tab->render);
    if (tab->view) {
        spdf_doc_view_document_changed(tab->view);
        spdf_doc_view_goto_page(tab->view, page);
    }
    app = ocr_window_app(win);
    if (app) spdf_app_save_session(app);
}

/* --- the run context ------------------------------------------------------ */

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;    /* validated with ocr_tab_alive before use */
    char* tool;
    char* path;
    char* tmp_path;
    char* language;
    char* language_label;
    char* tessdata_parent; /* TESSDATA_PREFIX, or NULL */
    int page_index;
    gboolean has_text;               /* the source had a text layer (redo path) */
    gboolean forced;                 /* current attempt uses --force-ocr */
    SpdfToolchainProgress* progress; /* ref held */
    GCancellable* cancellable;       /* ref held */
} OcrRun;

static void ocr_run_free(OcrRun* run) {
    ocr_set_running(run->win, FALSE);
    g_object_unref(run->win);
    g_free(run->tool);
    g_free(run->path);
    g_free(run->tmp_path);
    g_free(run->language);
    g_free(run->language_label);
    g_free(run->tessdata_parent);
    spdf_toolchain_progress_unref(run->progress);
    g_object_unref(run->cancellable);
    g_free(run);
}

static void ocr_run_fail(OcrRun* run, const char* heading, char* message /* owned */) {
    g_remove(run->tmp_path);
    spdf_toolchain_progress_close(run->progress);
    ocr_show_error(run->win, heading, message);
    g_free(message);
    ocr_run_free(run);
}

static void ocr_spawn_attempt(OcrRun* run);

/* --- output validation (journal item 37, off the main thread) ------------- */

static void ocr_validate_thread(GTask* task, gpointer source, gpointer task_data, GCancellable* cancellable) {
    const char* path = (const char*)task_data;
    char err[1024] = "";
    spdf_document* doc;
    int has_text;

    (void)source;
    (void)cancellable;
    doc = spdf_password_open_document(path, NULL, NULL, NULL, err, sizeof(err));
    if (!doc) {
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_FAILED, "%s",
                                err[0] ? err : "Could not open the OCR output.");
        return;
    }
    has_text = spdf_document_has_text(doc, 0, err, sizeof(err));
    spdf_close(doc);
    if (has_text < 0)
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_FAILED, "%s",
                                err[0] ? err : "Could not inspect the OCR output.");
    else
        g_task_return_int(task, has_text);
}

static void ocr_validated(GObject* source, GAsyncResult* result, gpointer user_data) {
    OcrRun* run = (OcrRun*)user_data;
    GError* error = NULL;
    gssize has_text = g_task_propagate_int(G_TASK(result), &error);
    SpdfOcrVerdict verdict;

    (void)source;
    if (error) {
        char* message = g_strdup(error->message);
        g_error_free(error);
        ocr_run_fail(run, "OCR failed", message);
        return;
    }

    verdict = spdf_ocr_validation_verdict(TRUE, (int)has_text, run->has_text, run->forced);
    switch (verdict) {
        case SPDF_OCR_SWAP:
            if (g_rename(run->tmp_path, run->path) != 0) {
                ocr_run_fail(run, "OCR failed", g_strdup_printf("Could not install OCR output: %s", g_strerror(errno)));
                return;
            }
            spdf_toolchain_progress_close(run->progress);
            if (ocr_tab_alive(run->win, run->tab)) {
                ocr_reload_tab(run->win, run->tab, run->page_index);
                spdf_window_add_toast(run->win, "OCR complete.");
            }
            ocr_run_free(run);
            return;
        case SPDF_OCR_RETRY_FORCE:
            g_remove(run->tmp_path);
            run->forced = TRUE;
            spdf_toolchain_progress_append_log(
                run->progress, "\nNo selectable text was detected; retrying with forced image OCR...\n");
            spdf_toolchain_progress_set_message(run->progress, "Retrying with forced image OCR...");
            ocr_spawn_attempt(run);
            return;
        case SPDF_OCR_FAIL_NO_TEXT:
        default:
            ocr_run_fail(run, "OCR failed",
                         g_strdup("OCRmyPDF completed, but no selectable text was detected in the output PDF. "
                                  "The original file was left unchanged."));
            return;
    }
}

/* --- the OCRmyPDF subprocess ----------------------------------------------- */

static void ocr_line_cb(const char* line, gpointer user_data) {
    OcrRun* run = (OcrRun*)user_data;
    spdf_toolchain_progress_append_log(run->progress, line);
    spdf_toolchain_progress_append_log(run->progress, "\n");
}

static void ocr_exit_cb(gboolean success, const char* collected_output, gpointer user_data) {
    OcrRun* run = (OcrRun*)user_data;

    if (g_cancellable_is_cancelled(run->cancellable)) {
        g_remove(run->tmp_path);
        spdf_toolchain_progress_close(run->progress);
        if (SPDF_IS_WINDOW(run->win)) spdf_window_add_toast(run->win, "OCR canceled.");
        ocr_run_free(run);
        return;
    }
    if (!success) {
        ocr_run_fail(run, "OCR failed", spdf_ocr_failure_message(collected_output));
        return;
    }
    /* Process success is not document success: validate the output with the
     * core text extractor before touching the original (journal item 37). */
    {
        GTask* task = g_task_new(NULL, NULL, ocr_validated, run);
        spdf_toolchain_progress_set_message(run->progress, "Validating OCR output...");
        g_task_set_task_data(task, g_strdup(run->tmp_path), g_free);
        g_task_run_in_thread(task, ocr_validate_thread);
        g_object_unref(task);
    }
}

static void ocr_spawn_attempt(OcrRun* run) {
    char** argv = spdf_ocr_build_argv(run->tool, run->language, g_get_num_processors(), run->has_text, run->forced,
                                      run->path, run->tmp_path);
    char** envp = NULL;
    GError* error = NULL;
    gboolean spawned;

    if (run->tessdata_parent) {
        envp = g_get_environ();
        envp = g_environ_setenv(envp, "TESSDATA_PREFIX", run->tessdata_parent, TRUE);
    }
    spawned = spdf_toolchain_spawn_streaming((const char* const*)argv, (const char* const*)envp, run->cancellable,
                                             ocr_line_cb, ocr_exit_cb, run, &error);
    g_strfreev(envp);
    g_strfreev(argv);
    if (!spawned) {
        char* message = g_strdup(error && error->message ? error->message : "Could not start OCRmyPDF.");
        g_clear_error(&error);
        ocr_run_fail(run, "OCR failed", message);
    }
}

static void ocr_run_start(SpdfWindow* win, SpdfTab* tab, const char* tool_owned, const char* language,
                          const char* language_label, gboolean has_text) {
    OcrRun* run = g_new0(OcrRun, 1);
    char* running_message;

    run->win = g_object_ref(win);
    run->tab = tab;
    run->tool = (char*)tool_owned;
    run->path = g_strdup(tab->path);
    run->tmp_path = spdf_ocr_temp_path(tab->path, g_random_int());
    run->language = g_strdup(language);
    run->language_label = g_strdup(language_label);
    run->tessdata_parent = spdf_toolchain_tessdata_parent_for_language(language);
    run->page_index = tab->view ? spdf_doc_view_current_page(tab->view) : 0;
    run->has_text = has_text;
    run->cancellable = g_cancellable_new();
    run->progress = spdf_toolchain_progress_new(GTK_WINDOW(win), "OCR", "Running OCR", run->cancellable);

    ocr_set_running(win, TRUE);
    running_message = g_strdup_printf("OCR running (%s)...", language_label ? language_label : language);
    spdf_toolchain_progress_set_message(run->progress, running_message);
    spdf_toolchain_progress_append_log(run->progress, running_message);
    spdf_toolchain_progress_append_log(run->progress, "\n");
    g_free(running_message);
    ocr_spawn_attempt(run);
}

/* --- pre-run prompts (backup for PDFs that already have text) -------------- */

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
    char* tool; /* owned; handed to the run */
    char* language;
    char* language_label;
} OcrPending;

static void ocr_pending_free(OcrPending* p) {
    g_object_unref(p->win);
    g_free(p->tool);
    g_free(p->language);
    g_free(p->language_label);
    g_free(p);
}

static char* ocr_make_backup_path(const char* path) {
    for (int index = 0;; index++) {
        char* candidate = spdf_ocr_backup_candidate(path, index);
        if (!candidate) return NULL;
        if (!g_file_test(candidate, G_FILE_TEST_EXISTS)) return candidate;
        g_free(candidate);
    }
}

static void ocr_backup_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    OcrPending* p = (OcrPending*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    char* backup;
    GFile* src;
    GFile* dst;
    GError* copy_error = NULL;

    if (g_strcmp0(response, "ocr") != 0 || !ocr_tab_alive(p->win, p->tab)) {
        ocr_pending_free(p);
        return;
    }

    /* GTK3: copy <stem>_backup.pdf next to the original before OCR replaces
     * a PDF that already had selectable text. */
    backup = ocr_make_backup_path(p->tab->path);
    src = g_file_new_for_path(p->tab->path);
    dst = g_file_new_for_path(backup);
    if (!g_file_copy(src, dst, G_FILE_COPY_NONE, NULL, NULL, NULL, &copy_error)) {
        ocr_show_error(p->win, "Could not create OCR backup", copy_error ? copy_error->message : "");
        g_clear_error(&copy_error);
        g_object_unref(src);
        g_object_unref(dst);
        g_free(backup);
        ocr_pending_free(p);
        return;
    }
    g_object_unref(src);
    g_object_unref(dst);
    g_free(backup);

    ocr_run_start(p->win, p->tab, g_steal_pointer(&p->tool), p->language, p->language_label, TRUE);
    ocr_pending_free(p);
}

/* Continuation invoked by spdf_annot_preflight once the PDF is writable in
 * place (data = OcrPending, ownership transferred). */
static void ocr_preflight_cont(SpdfWindow* win, SpdfTab* tab, gpointer data) {
    OcrPending* p = (OcrPending*)data;
    char err[1024] = "";
    int has_text;

    (void)win;
    (void)tab;
    has_text = spdf_document_has_text(p->tab->doc, 0, err, sizeof(err));
    if (has_text < 0) {
        ocr_show_error(p->win, "Could not inspect document text", err);
        ocr_pending_free(p);
        return;
    }
    if (has_text > 0) {
        AdwDialog* dialog = adw_alert_dialog_new("This PDF already contains selectable text.",
                                                 "Shenzhen PDF will make a backup before OCR replaces it.");
        adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "ocr", "_OCR and Backup", NULL);
        adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "ocr", ADW_RESPONSE_SUGGESTED);
        adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "ocr");
        adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
        adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(p->win), NULL, ocr_backup_response, p);
        return;
    }
    ocr_run_start(p->win, p->tab, g_steal_pointer(&p->tool), p->language, p->language_label, FALSE);
    ocr_pending_free(p);
}

/* --- toolchain detection + one-click install -------------------------------- */

typedef struct {
    SpdfWindow* win; /* ref held */
    char* language;
    char* language_label;
} OcrInstallCtx;

static void ocr_install_ctx_free(OcrInstallCtx* ctx) {
    ocr_set_running(ctx->win, FALSE);
    g_object_unref(ctx->win);
    g_free(ctx->language);
    g_free(ctx->language_label);
    g_free(ctx);
}

static void ocr_start_for_language(SpdfWindow* win, const char* language, const char* language_label);

static void ocr_install_done(gboolean success, const char* output, gpointer user_data) {
    OcrInstallCtx* ctx = (OcrInstallCtx*)user_data;
    char* tool = spdf_toolchain_find_tool("ocrmypdf");
    char* tesseract = spdf_toolchain_find_tool("tesseract");

    (void)output;
    if (success && tool && tesseract && spdf_toolchain_tesseract_has_language(ctx->language)) {
        /* GTK3 ocr_install_finished_idle: continue OCR automatically. */
        SpdfWindow* win = g_object_ref(ctx->win);
        char* language = g_strdup(ctx->language);
        char* label = g_strdup(ctx->language_label);
        ocr_install_ctx_free(ctx);
        ocr_start_for_language(win, language, label);
        g_object_unref(win);
        g_free(language);
        g_free(label);
    } else {
        /* The install window stays open with the log (toolchain runner). */
        if (SPDF_IS_WINDOW(ctx->win)) spdf_window_add_toast(ctx->win, "OCR installation failed.");
        ocr_install_ctx_free(ctx);
    }
    g_free(tool);
    g_free(tesseract);
}

static void ocr_install_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    OcrInstallCtx* ctx = (OcrInstallCtx*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    char* script;
    char* initial_log;

    if (g_strcmp0(response, "install") != 0 || !SPDF_IS_WINDOW(ctx->win)) {
        ocr_install_ctx_free(ctx);
        return;
    }
    ocr_set_running(ctx->win, TRUE); /* one installer at a time; resumed OCR re-clears */
    script = spdf_toolchain_ocr_install_script(ctx->language);
    initial_log = g_strdup_printf("Preparing OCR installer for %s...\n",
                                  ctx->language_label ? ctx->language_label : ctx->language);
    spdf_toolchain_run_install_script(GTK_WINDOW(ctx->win), "Installing OCR",
                                      "Installing OCRmyPDF, Tesseract, and language data", initial_log, script,
                                      ocr_install_done, ctx);
    g_free(initial_log);
    g_free(script);
}

/* GTK3 start_ocr_for_language: detect toolchain, offer install, then
 * preflight + prompts + run. */
static void ocr_start_for_language(SpdfWindow* win, const char* language, const char* language_label) {
    SpdfTab* tab = spdf_window_current_tab(win);
    char* tool;
    char* tesseract;
    gboolean language_ready;
    OcrPending* pending;

    if (!tab || !tab->doc || !tab->path || !spdf_annot_path_has_pdf_extension(tab->path)) return;
    if (ocr_is_running(win)) return;
    /* Protected inputs never reach external OCR tooling: credentials stay in
     * memory and are consumed only by typed core opens. */
    if (!spdf_password_require_ocr(GTK_WINDOW(win), tab->doc)) return;

    tool = spdf_toolchain_find_tool("ocrmypdf");
    tesseract = spdf_toolchain_find_tool("tesseract");
    language_ready = tesseract && spdf_toolchain_tesseract_has_language(language);
    if (!tool || !tesseract || !language_ready) {
        OcrInstallCtx* ctx = g_new0(OcrInstallCtx, 1);
        AdwDialog* dialog;

        ctx->win = g_object_ref(win);
        ctx->language = g_strdup(language);
        ctx->language_label = g_strdup(language_label);
        dialog =
            adw_alert_dialog_new(!tool || !tesseract ? "Install OCR support?" : "Install OCR language data?", NULL);
        adw_alert_dialog_format_body(ADW_ALERT_DIALOG(dialog),
                                     "Shenzhen PDF can install OCRmyPDF, Tesseract, and the %s traineddata, "
                                     "then continue OCR automatically when installation finishes.",
                                     language_label ? language_label : language);
        adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "install", "_Install", NULL);
        adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "install", ADW_RESPONSE_SUGGESTED);
        adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "install");
        adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
        adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, ocr_install_response, ctx);
        g_free(tool);
        g_free(tesseract);
        return;
    }
    g_free(tesseract);

    pending = g_new0(OcrPending, 1);
    pending->win = g_object_ref(win);
    pending->tab = tab;
    pending->tool = tool; /* ownership */
    pending->language = g_strdup(language);
    pending->language_label = g_strdup(language_label);
    /* Writable preflight shared with rotate/comments/translate (GTK3
     * prompt_save_as_before_modification, journal item 35). */
    spdf_annot_preflight(win, tab, "OCR", 'e', ocr_preflight_cont, pending, (GDestroyNotify)ocr_pending_free);
}

/* --- language selector ------------------------------------------------------ */

typedef struct {
    SpdfWindow* win; /* ref held */
    GtkDropDown* dropdown;
} OcrLanguagePrompt;

static void ocr_language_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    OcrLanguagePrompt* prompt = (OcrLanguagePrompt*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);

    if (g_strcmp0(response, "run") == 0 && SPDF_IS_WINDOW(prompt->win)) {
        int count = 0;
        const SpdfOcrLanguage* languages = spdf_ocr_languages(&count);
        guint selected = gtk_drop_down_get_selected(prompt->dropdown);
        SpdfApp* app = ocr_window_app(prompt->win);

        if (selected >= (guint)count) selected = 0;
        /* Persist the choice ("ocrLanguage", GTK4 extra — see
         * spdf_state_internal.h). */
        if (app) {
            SpdfState* state = spdf_app_get_state(app);
            spdf_state_set_string(&spdf_state_settings(state)->ocr_language, languages[selected].code);
            spdf_state_save_settings(state);
        }
        ocr_start_for_language(prompt->win, languages[selected].code, languages[selected].label);
    }
    g_object_unref(prompt->dropdown);
    g_object_unref(prompt->win);
    g_free(prompt);
}

static void action_ocr(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    int count = 0;
    const SpdfOcrLanguage* languages = spdf_ocr_languages(&count);
    GtkStringList* labels;
    GtkWidget* dropdown;
    AdwDialog* dialog;
    OcrLanguagePrompt* prompt;
    SpdfApp* app;
    int preselect = 0;

    (void)action;
    (void)parameter;
    if (!tab || !tab->doc || !tab->path || !spdf_annot_path_has_pdf_extension(tab->path)) return;
    if (ocr_is_running(win)) return;
    /* Recheck after installer and language-selection delays. */
    if (!spdf_password_require_ocr(GTK_WINDOW(win), tab->doc)) return;

    labels = gtk_string_list_new(NULL);
    for (int i = 0; i < count; ++i) gtk_string_list_append(labels, languages[i].label);
    dropdown = gtk_drop_down_new(G_LIST_MODEL(labels), NULL);

    app = ocr_window_app(win);
    if (app) {
        SpdfSettings* settings = spdf_state_settings(spdf_app_get_state(app));
        int index = spdf_ocr_language_index(settings->ocr_language);
        if (index >= 0) preselect = index;
    }
    gtk_drop_down_set_selected(GTK_DROP_DOWN(dropdown), (guint)preselect);

    dialog = adw_alert_dialog_new("OCR language", "Choose the language data Tesseract should use for this PDF.");
    adw_alert_dialog_set_extra_child(ADW_ALERT_DIALOG(dialog), dropdown);
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "run", "_Run OCR", NULL);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "run", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "run");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");

    prompt = g_new0(OcrLanguagePrompt, 1);
    prompt->win = g_object_ref(win);
    prompt->dropdown = GTK_DROP_DOWN(g_object_ref(dropdown));
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, ocr_language_response, prompt);
}

static const GActionEntry k_ocr_actions[] = {
    {"ocr", action_ocr, NULL, NULL, NULL, {0}},
};

void spdf_ocr_install(SpdfWindow* win) {
    g_return_if_fail(SPDF_IS_WINDOW(win));
    g_action_map_add_action_entries(G_ACTION_MAP(win), k_ocr_actions, G_N_ELEMENTS(k_ocr_actions), win);
}

#endif /* SPDF_OCR_TESTING */
