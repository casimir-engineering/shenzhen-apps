// spdf_translate.c — selection + whole-document translation for the GTK4
// shell. Contract, GTK3 provenance map and the list of ported/skipped
// 78072bf55 refinements live in spdf_translate.h.

#include "spdf_translate.h"

#include <string.h>

/* ===========================================================================
 * Pure logic (glib only). Everything above the SPDF_TRANSLATE_TESTING guard
 * is exercised by tests/translate_test.c.
 * ======================================================================== */

/* GTK3 k_translation_languages / Mac spdf_translation_languages, verbatim. */
static const SpdfTranslationLanguage k_translation_languages[] = {
    {"zh", "Chinese (Simplified)"},
    {"en", "English"},
    {"fr", "French"},
    {"de", "German"},
    {"es", "Spanish"},
    {"it", "Italian"},
    {"pt", "Portuguese"},
    {"ru", "Russian"},
    {"ja", "Japanese"},
    {"ko", "Korean"},
    {"ar", "Arabic"},
    {"hi", "Hindi"},
    {"nl", "Dutch"},
    {"pl", "Polish"},
    {"tr", "Turkish"},
    {"vi", "Vietnamese"},
    {"id", "Indonesian"},
    {"uk", "Ukrainian"},
    {"cs", "Czech"},
};

const SpdfTranslationLanguage* spdf_translation_languages(int* count) {
    if (count) *count = (int)G_N_ELEMENTS(k_translation_languages);
    return k_translation_languages;
}

int spdf_translation_language_index(const char* code) {
    if (!code || !*code) return -1;
    for (guint i = 0; i < G_N_ELEMENTS(k_translation_languages); ++i)
        if (g_strcmp0(k_translation_languages[i].code, code) == 0) return (int)i;
    return -1;
}

const char* spdf_translate_suffix_for_language(const char* target_language) {
    if (!target_language || !*target_language) return "translated";
    if (g_strcmp0(target_language, "en") == 0) return "english";
    return target_language;
}

char* spdf_translate_output_path(const char* path, const char* target_language) {
    char* dir;
    char* base;
    char* dot;
    char* stem;
    char* name;
    char* output;

    if (!path || !*path) return NULL;
    dir = g_path_get_dirname(path);
    base = g_path_get_basename(path);
    dot = strrchr(base, '.');
    stem = dot ? g_strndup(base, (gsize)(dot - base)) : g_strdup(base);
    name = g_strdup_printf("%s_%s.pdf", stem, spdf_translate_suffix_for_language(target_language));
    output = g_build_filename(dir, name, NULL);
    g_free(name);
    g_free(stem);
    g_free(base);
    g_free(dir);
    return output;
}

char* spdf_translate_temp_path(const char* path, guint32 nonce) {
    char* dir;
    char* base;
    char* name;
    char* output;

    if (!path || !*path) return NULL;
    dir = g_path_get_dirname(path);
    base = g_path_get_basename(path);
    name = g_strdup_printf(".%s.translate-%u.pdf", base, nonce);
    output = g_build_filename(dir, name, NULL);
    g_free(name);
    g_free(base);
    g_free(dir);
    return output;
}

char* spdf_translate_collapse_whitespace(const char* text) {
    GString* out = g_string_new("");
    gboolean pending_space = FALSE;

    for (const char* p = text ? text : ""; *p; ++p) {
        if (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == '\f' || *p == '\v') {
            if (out->len) pending_space = TRUE;
            continue;
        }
        if (pending_space) {
            g_string_append_c(out, ' ');
            pending_space = FALSE;
        }
        g_string_append_c(out, *p);
    }
    return g_string_free(out, FALSE);
}

int spdf_translate_batch_end(const SpdfTranslateBatchItem* items, int count, int start, int budget) {
    int end;

    if (!items || start < 0 || start >= count) return count;
    /* The first page group always fits, even when it alone exceeds the
     * budget — a batch must cover whole page groups (Mac batching). */
    end = start + 1;
    while (end < count && items[end].page == items[start].page) end++;
    while (end < count && end - start < budget) {
        int next_page = items[end].page;
        int next_end = end + 1;
        while (next_end < count && items[next_end].page == next_page) next_end++;
        if (next_end - start > budget) break;
        end = next_end;
    }
    return end;
}

char* spdf_translate_batch_scope(const SpdfTranslateBatchItem* items, int count, int start, int end) {
    gboolean has_outline = FALSE;
    gboolean has_comment = FALSE;
    int first_page = -1;
    int last_page = -1;
    char* pages = NULL;
    const char* extras = NULL;

    for (int i = start; i < end && i < count; ++i) {
        if (items[i].kind == 1) {
            has_outline = TRUE;
        } else if (items[i].kind == 2) {
            has_comment = TRUE;
        } else {
            if (first_page < 0) first_page = items[i].page;
            last_page = items[i].page;
        }
    }
    if (first_page >= 0) {
        pages = first_page == last_page ? g_strdup_printf("page %d", first_page + 1)
                                        : g_strdup_printf("pages %d-%d", first_page + 1, last_page + 1);
    }
    if (has_outline && has_comment)
        extras = "chapters and comments";
    else if (has_outline)
        extras = "chapter titles";
    else if (has_comment)
        extras = "comments";

    if (pages && extras) {
        char* combined = g_strdup_printf("%s and %s", pages, extras);
        g_free(pages);
        return combined;
    }
    if (pages) return pages;
    return g_strdup(extras ? extras : "text");
}

void spdf_translate_apply_batch_output(char** result_lines, int start, int end, const char* batch_output) {
    char** output_lines = g_strsplit(batch_output ? batch_output : "", "\n", -1);
    int output_count = 0;

    while (output_lines && output_lines[output_count]) output_count++;
    for (int i = start; i < end; ++i) {
        int local = i - start;
        const char* line = local < output_count ? output_lines[local] : "";
        g_free(result_lines[i]);
        result_lines[i] = g_strdup(line && *line ? line : " ");
    }
    if (output_count > end - start && end > start) {
        /* Fold extra output lines into the batch's last line, space-joined:
         * embedded newlines would shift every later overlay (78072bf55). */
        GString* tail = g_string_new(result_lines[end - 1]);
        char* flattened;
        for (int i = end - start; i < output_count; ++i) {
            if (!output_lines[i][0]) continue;
            if (tail->len) g_string_append_c(tail, ' ');
            g_string_append(tail, output_lines[i]);
        }
        flattened = g_string_free(tail, FALSE);
        g_strdelimit(flattened, "\n", ' ');
        g_free(result_lines[end - 1]);
        result_lines[end - 1] = flattened;
    }
    g_strfreev(output_lines);
}

#ifndef SPDF_TRANSLATE_TESTING
#include "spdf_password_prompt.h"

/* ===========================================================================
 * GTK flow.
 * ======================================================================== */

#include <cairo-pdf.h>
#include <errno.h>
#include <glib/gstdio.h>

#include "spdf_annot.h"
#include "spdf_app.h"
#include "spdf_toolchain.h"

#define MAX_TRANSLATE_TEXT_BYTES (16 * 1024 * 1024) /* GTK3 cap */
#define TRANSLATE_ERROR_DETAIL_MAX 1200             /* Mac error truncation */

/* --- window-level running state ------------------------------------------- */

static gboolean translate_is_busy(SpdfWindow* win) {
    return g_object_get_data(G_OBJECT(win), "spdf-translate-busy") != NULL;
}

static void translate_set_busy(SpdfWindow* win, gboolean busy) {
    GAction* action = g_action_map_lookup_action(G_ACTION_MAP(win), "translate");
    g_object_set_data(G_OBJECT(win), "spdf-translate-busy", GINT_TO_POINTER(busy ? 1 : 0));
    if (action && G_IS_SIMPLE_ACTION(action)) g_simple_action_set_enabled(G_SIMPLE_ACTION(action), !busy);
}

static gboolean translate_tab_alive(SpdfWindow* win, SpdfTab* tab) {
    int count;

    if (!win || !tab || !SPDF_IS_WINDOW(win)) return FALSE;
    count = spdf_window_tab_count(win);
    for (int i = 0; i < count; ++i)
        if (spdf_window_tab_at(win, i) == tab) return TRUE;
    return FALSE;
}

static void translate_show_error(SpdfWindow* win, const char* heading, const char* detail) {
    GtkAlertDialog* alert = gtk_alert_dialog_new("%s", heading);
    char* truncated = NULL;

    if (detail && strlen(detail) > TRANSLATE_ERROR_DETAIL_MAX) {
        truncated = g_strndup(detail, TRANSLATE_ERROR_DETAIL_MAX);
        detail = truncated;
    }
    gtk_alert_dialog_set_detail(alert, detail && *detail ? detail : "Argos exited with an error.");
    gtk_alert_dialog_show(alert, win && SPDF_IS_WINDOW(win) ? GTK_WINDOW(win) : NULL);
    g_object_unref(alert);
    g_free(truncated);
}

static SpdfApp* translate_window_app(SpdfWindow* win) {
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

static SpdfSettings* translate_settings(SpdfWindow* win) {
    SpdfApp* app = translate_window_app(win);
    return app ? spdf_state_settings(spdf_app_get_state(app)) : NULL;
}

static void translate_persist_languages(SpdfWindow* win, const char* from, const char* to) {
    SpdfApp* app = translate_window_app(win);
    if (!app) return;
    SpdfState* state = spdf_app_get_state(app);
    SpdfSettings* settings = spdf_state_settings(state);
    spdf_state_set_string(&settings->translate_source_language, from);
    spdf_state_set_string(&settings->translate_target_language, to);
    spdf_state_save_settings(state);
}

/* --- language dropdowns ------------------------------------------------------
 * GTK3 populate_translation_language_combo: the 19 table entries as
 * "Name (code)", plus a "Custom (code)" row when the persisted code is not in
 * the table. codes_out (strv-owned GPtrArray) maps row -> code. */

static GtkWidget* translate_language_dropdown(const char* selected_code, GPtrArray** codes_out) {
    int count = 0;
    const SpdfTranslationLanguage* languages = spdf_translation_languages(&count);
    GtkStringList* labels = gtk_string_list_new(NULL);
    GPtrArray* codes = g_ptr_array_new_with_free_func(g_free);
    GtkWidget* dropdown;
    int selected = -1;

    for (int i = 0; i < count; ++i) {
        char* label = g_strdup_printf("%s (%s)", languages[i].name, languages[i].code);
        gtk_string_list_append(labels, label);
        g_free(label);
        g_ptr_array_add(codes, g_strdup(languages[i].code));
        if (g_strcmp0(selected_code, languages[i].code) == 0) selected = i;
    }
    if (selected < 0 && selected_code && *selected_code) {
        char* label = g_strdup_printf("Custom (%s)", selected_code);
        gtk_string_list_append(labels, label);
        g_free(label);
        g_ptr_array_add(codes, g_strdup(selected_code));
        selected = (int)codes->len - 1;
    }
    dropdown = gtk_drop_down_new(G_LIST_MODEL(labels), NULL);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(dropdown), selected >= 0 ? (guint)selected : 0);
    if (codes_out)
        *codes_out = codes;
    else
        g_ptr_array_unref(codes);
    return dropdown;
}

static const char* translate_dropdown_code(GtkDropDown* dropdown, GPtrArray* codes) {
    guint selected = gtk_drop_down_get_selected(dropdown);
    if (selected == GTK_INVALID_LIST_POSITION || selected >= codes->len) return NULL;
    return (const char*)g_ptr_array_index(codes, selected);
}

/* ===========================================================================
 * Selection translation dialog (Mac buildSelectionTranslationPanelIfNeeded in
 * libadwaita idiom).
 * ======================================================================== */

typedef struct {
    SpdfWindow* win; /* ref held */
    GtkWindow* dialog;
    GtkDropDown* from_dd;
    GtkDropDown* to_dd;
    GPtrArray* from_codes;
    GPtrArray* to_codes;
    GtkTextView* input;
    GtkTextView* output;
    GtkLabel* status;
    GtkButton* translate_button;
    guint generation;
    gboolean running;
    gboolean offered_installer;
} SelectionPanel;

static void selection_panel_free(gpointer data) {
    SelectionPanel* panel = (SelectionPanel*)data;
    g_ptr_array_unref(panel->from_codes);
    g_ptr_array_unref(panel->to_codes);
    g_object_unref(panel->win);
    g_free(panel);
}

static SelectionPanel* selection_panel_from_dialog(GtkWindow* dialog) {
    return (SelectionPanel*)g_object_get_data(G_OBJECT(dialog), "spdf-selection-panel");
}

static void selection_panel_set_status(SelectionPanel* panel, const char* text) {
    gtk_label_set_text(panel->status, text ? text : "");
}

static char* selection_panel_input_text(SelectionPanel* panel) {
    GtkTextBuffer* buffer = gtk_text_view_get_buffer(panel->input);
    GtkTextIter start_iter;
    GtkTextIter end_iter;
    char* text;

    gtk_text_buffer_get_bounds(buffer, &start_iter, &end_iter);
    text = gtk_text_buffer_get_text(buffer, &start_iter, &end_iter, FALSE);
    g_strstrip(text);
    return text;
}

static void selection_panel_run(SelectionPanel* panel, gboolean offered_installer);

/* Argos run in a GTask thread; results routed back through the dialog ref so
 * a closed dialog just drops them. */
typedef struct {
    GtkWindow* dialog; /* ref held */
    guint generation;
    char* tool;
    char* from_lang;
    char* to_lang;
    char* text;
    gboolean offered_installer;
} SelectionRun;

static void selection_run_free(SelectionRun* run) {
    g_object_unref(run->dialog);
    g_free(run->tool);
    g_free(run->from_lang);
    g_free(run->to_lang);
    g_free(run->text);
    g_free(run);
}

static void selection_run_thread(GTask* task, gpointer source, gpointer task_data, GCancellable* cancellable) {
    SelectionRun* run = (SelectionRun*)task_data;
    const char* argv[] = {run->tool, "--from-lang", run->from_lang, "--to-lang", run->to_lang, NULL};
    char* stdout_text = NULL;
    char* stderr_text = NULL;
    GError* error = NULL;

    (void)source;
    (void)cancellable;
    if (!spdf_toolchain_run_capture(argv, NULL, run->text, NULL, &stdout_text, &stderr_text, &error) || !stdout_text ||
        !stdout_text[0]) {
        const char* detail = error && error->message       ? error->message
                             : stderr_text && *stderr_text ? stderr_text
                             : stdout_text && *stdout_text ? stdout_text
                                                           : "Argos Translate exited with an error.";
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_FAILED, "%s", detail);
    } else {
        char* cleaned = spdf_toolchain_strip_argos_diagnostics(stdout_text);
        g_task_return_pointer(task, cleaned, g_free);
    }
    g_clear_error(&error);
    g_free(stdout_text);
    g_free(stderr_text);
}

static void selection_offer_package_install(SelectionPanel* panel, const char* from_lang, const char* to_lang);

static void selection_run_finished(GObject* source, GAsyncResult* result, gpointer user_data) {
    SelectionRun* run = (SelectionRun*)user_data;
    SelectionPanel* panel = selection_panel_from_dialog(run->dialog);
    GError* error = NULL;
    char* translated = g_task_propagate_pointer(G_TASK(result), &error);

    (void)source;
    if (!panel || panel->generation != run->generation) {
        g_clear_error(&error);
        g_free(translated);
        selection_run_free(run);
        return;
    }
    panel->running = FALSE;
    gtk_widget_set_sensitive(GTK_WIDGET(panel->translate_button), TRUE);
    if (error) {
        /* Mac parity: the first failure offers an argospm language-package
         * install, then the translation resumes automatically. */
        if (!run->offered_installer) {
            selection_panel_set_status(panel, error->message);
            selection_offer_package_install(panel, run->from_lang, run->to_lang);
        } else {
            selection_panel_set_status(panel, error->message);
        }
        g_error_free(error);
    } else {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(panel->output), translated ? translated : "", -1);
        selection_panel_set_status(panel, "Translation complete.");
    }
    g_free(translated);
    selection_run_free(run);
}

typedef struct {
    GtkWindow* dialog; /* ref held */
    char* from_lang;
    char* to_lang;
} SelectionInstallCtx;

static void selection_install_ctx_free(SelectionInstallCtx* ctx) {
    g_object_unref(ctx->dialog);
    g_free(ctx->from_lang);
    g_free(ctx->to_lang);
    g_free(ctx);
}

static void selection_package_install_done(gboolean success, const char* output, gpointer user_data) {
    SelectionInstallCtx* ctx = (SelectionInstallCtx*)user_data;
    SelectionPanel* panel = selection_panel_from_dialog(ctx->dialog);

    (void)output;
    if (panel) {
        if (success) {
            selection_panel_run(panel, TRUE);
        } else {
            selection_panel_set_status(panel, "Translation package installation failed.");
        }
    }
    selection_install_ctx_free(ctx);
}

static void selection_package_install_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    SelectionInstallCtx* ctx = (SelectionInstallCtx*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    SelectionPanel* panel = selection_panel_from_dialog(ctx->dialog);
    char* package;
    char* script;
    char* initial_log;

    if (g_strcmp0(response, "install") != 0 || !panel) {
        if (panel) selection_panel_set_status(panel, "Translation package is required.");
        selection_install_ctx_free(ctx);
        return;
    }
    package = spdf_toolchain_argos_package_name(ctx->from_lang, ctx->to_lang);
    script = g_strdup_printf(
        "export PATH=\"$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"\n"
        "exec argospm install %s\n",
        package);
    initial_log = g_strdup_printf("Running argospm install %s...\n", package);
    spdf_toolchain_run_install_script(ctx->dialog, "Installing Translation Package", "Installing language package",
                                      initial_log, script, selection_package_install_done, ctx);
    g_free(initial_log);
    g_free(script);
    g_free(package);
}

static void selection_offer_package_install(SelectionPanel* panel, const char* from_lang, const char* to_lang) {
    SelectionInstallCtx* ctx = g_new0(SelectionInstallCtx, 1);
    char* package = spdf_toolchain_argos_package_name(from_lang, to_lang);
    AdwDialog* dialog;

    ctx->dialog = g_object_ref(panel->dialog);
    ctx->from_lang = g_strdup(from_lang);
    ctx->to_lang = g_strdup(to_lang);
    dialog = adw_alert_dialog_new("Install Argos language package?", NULL);
    adw_alert_dialog_format_body(ADW_ALERT_DIALOG(dialog),
                                 "The offline %s to %s package may be missing. Shenzhen PDF can ask argospm to "
                                 "install %s, then continue translation.",
                                 from_lang, to_lang, package ? package : "it");
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "install", "_Install", NULL);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "install", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "install");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(panel->dialog), NULL,
                            selection_package_install_response, ctx);
    g_free(package);
}

static void selection_argos_install_done(gboolean success, const char* output, gpointer user_data) {
    SelectionInstallCtx* ctx = (SelectionInstallCtx*)user_data;
    SelectionPanel* panel = selection_panel_from_dialog(ctx->dialog);
    char* tool = spdf_toolchain_find_tool("argos-translate");

    (void)output;
    if (panel) {
        if (success && tool)
            selection_panel_run(panel, FALSE);
        else
            selection_panel_set_status(panel, "Argos installation failed.");
    }
    g_free(tool);
    selection_install_ctx_free(ctx);
}

static void selection_argos_install_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    SelectionInstallCtx* ctx = (SelectionInstallCtx*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    SelectionPanel* panel = selection_panel_from_dialog(ctx->dialog);
    char* script;

    if (g_strcmp0(response, "install") != 0 || !panel) {
        selection_install_ctx_free(ctx);
        return;
    }
    script = spdf_toolchain_argos_install_script();
    spdf_toolchain_run_install_script(ctx->dialog, "Installing Translation Support", "Installing Argos Translate",
                                      "Preparing Argos Translate installer...\n", script, selection_argos_install_done,
                                      ctx);
    g_free(script);
}

static void selection_panel_run(SelectionPanel* panel, gboolean offered_installer) {
    const char* from = translate_dropdown_code(panel->from_dd, panel->from_codes);
    const char* to = translate_dropdown_code(panel->to_dd, panel->to_codes);
    char* text;
    char* tool;
    SelectionRun* run;
    GTask* task;

    if (panel->running) {
        selection_panel_set_status(panel, "A translation task is already running.");
        return;
    }
    if (!from || !to || g_strcmp0(from, to) == 0) {
        selection_panel_set_status(panel, "Choose different source and target languages.");
        return;
    }
    translate_persist_languages(panel->win, from, to);
    text = selection_panel_input_text(panel);
    if (!text || !*text) {
        selection_panel_set_status(panel, "Input text is empty.");
        g_free(text);
        return;
    }

    tool = spdf_toolchain_find_tool("argos-translate");
    if (!tool) {
        SelectionInstallCtx* ctx = g_new0(SelectionInstallCtx, 1);
        AdwDialog* dialog;

        g_free(text);
        ctx->dialog = g_object_ref(panel->dialog);
        ctx->from_lang = g_strdup(from);
        ctx->to_lang = g_strdup(to);
        dialog = adw_alert_dialog_new("Install translation support?",
                                      "Shenzhen PDF uses Argos Translate locally for offline translation. "
                                      "Install it, then continue translation.");
        adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "install", "_Install", NULL);
        adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "install", ADW_RESPONSE_SUGGESTED);
        adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "install");
        adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
        adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(panel->dialog), NULL,
                                selection_argos_install_response, ctx);
        return;
    }

    panel->running = TRUE;
    panel->generation++;
    gtk_widget_set_sensitive(GTK_WIDGET(panel->translate_button), FALSE);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(panel->output), "", -1);
    selection_panel_set_status(panel, "Translating locally with Argos...");

    run = g_new0(SelectionRun, 1);
    run->dialog = g_object_ref(panel->dialog);
    run->generation = panel->generation;
    run->tool = tool;
    run->from_lang = g_strdup(from);
    run->to_lang = g_strdup(to);
    run->text = text;
    run->offered_installer = offered_installer;

    task = g_task_new(NULL, NULL, selection_run_finished, run);
    g_task_set_task_data(task, run, NULL); /* freed in selection_run_finished */
    g_task_run_in_thread(task, selection_run_thread);
    g_object_unref(task);
}

static void selection_translate_clicked(GtkButton* button, gpointer user_data) {
    SelectionPanel* panel = selection_panel_from_dialog(GTK_WINDOW(user_data));
    (void)button;
    if (panel) selection_panel_run(panel, FALSE);
}

static GtkWidget* selection_text_frame(GtkTextView** view_out, gboolean editable) {
    GtkWidget* scroll = gtk_scrolled_window_new();
    GtkWidget* view = gtk_text_view_new();

    gtk_text_view_set_editable(GTK_TEXT_VIEW(view), editable);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(view), 8);
    gtk_text_view_set_right_margin(GTK_TEXT_VIEW(view), 8);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(view), 6);
    gtk_text_view_set_bottom_margin(GTK_TEXT_VIEW(view), 6);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), view);
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_widget_add_css_class(scroll, "card");
    if (view_out) *view_out = GTK_TEXT_VIEW(view);
    return scroll;
}

static void translate_selection_open(SpdfWindow* win, const char* selected_text) {
    SelectionPanel* panel = g_new0(SelectionPanel, 1);
    SpdfSettings* settings = translate_settings(win);
    GtkWidget* window = adw_window_new();
    GtkWidget* toolbar_view = adw_toolbar_view_new();
    GtkWidget* header = adw_header_bar_new();
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    GtkWidget* language_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget* from_label = gtk_label_new("From");
    GtkWidget* to_label = gtk_label_new("To");
    GtkWidget* from_dd;
    GtkWidget* to_dd;
    GtkWidget* translate_button = gtk_button_new_with_label("Translate");
    GtkWidget* input_label = gtk_label_new("Input");
    GtkWidget* output_label = gtk_label_new("Translation");
    GtkWidget* status = gtk_label_new("");
    GtkWidget* input_scroll;
    GtkWidget* output_scroll;

    panel->win = g_object_ref(win);
    panel->dialog = GTK_WINDOW(window);

    from_dd = translate_language_dropdown(
        settings && settings->translate_source_language ? settings->translate_source_language : "zh",
        &panel->from_codes);
    to_dd = translate_language_dropdown(
        settings && settings->translate_target_language ? settings->translate_target_language : "en", &panel->to_codes);
    panel->from_dd = GTK_DROP_DOWN(from_dd);
    panel->to_dd = GTK_DROP_DOWN(to_dd);
    panel->status = GTK_LABEL(status);
    panel->translate_button = GTK_BUTTON(translate_button);

    gtk_window_set_title(GTK_WINDOW(window), "Translate Selection");
    gtk_window_set_default_size(GTK_WINDOW(window), 680, 540);
    gtk_window_set_transient_for(GTK_WINDOW(window), GTK_WINDOW(win));

    gtk_widget_set_hexpand(from_dd, TRUE);
    gtk_widget_set_hexpand(to_dd, TRUE);
    gtk_widget_add_css_class(translate_button, "suggested-action");
    gtk_box_append(GTK_BOX(language_row), from_label);
    gtk_box_append(GTK_BOX(language_row), from_dd);
    gtk_box_append(GTK_BOX(language_row), to_label);
    gtk_box_append(GTK_BOX(language_row), to_dd);
    gtk_box_append(GTK_BOX(language_row), translate_button);

    gtk_label_set_xalign(GTK_LABEL(input_label), 0.0f);
    gtk_widget_add_css_class(input_label, "heading");
    gtk_label_set_xalign(GTK_LABEL(output_label), 0.0f);
    gtk_widget_add_css_class(output_label, "heading");
    gtk_label_set_xalign(GTK_LABEL(status), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(status), PANGO_ELLIPSIZE_MIDDLE);
    gtk_widget_add_css_class(status, "dim-label");

    input_scroll = selection_text_frame(&panel->input, TRUE);
    output_scroll = selection_text_frame(&panel->output, FALSE);

    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);
    gtk_widget_set_margin_top(box, 12);
    gtk_widget_set_margin_bottom(box, 12);
    gtk_box_append(GTK_BOX(box), language_row);
    gtk_box_append(GTK_BOX(box), input_label);
    gtk_box_append(GTK_BOX(box), input_scroll);
    gtk_box_append(GTK_BOX(box), output_label);
    gtk_box_append(GTK_BOX(box), output_scroll);
    gtk_box_append(GTK_BOX(box), status);

    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar_view), header);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar_view), box);
    adw_window_set_content(ADW_WINDOW(window), toolbar_view);

    g_object_set_data_full(G_OBJECT(window), "spdf-selection-panel", panel, selection_panel_free);
    g_signal_connect(translate_button, "clicked", G_CALLBACK(selection_translate_clicked), window);

    if (selected_text && *selected_text)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(panel->input), selected_text, -1);
    selection_panel_set_status(panel, "Preparing translation...");
    gtk_window_present(GTK_WINDOW(window));
    selection_panel_run(panel, FALSE);
}

/* ===========================================================================
 * Whole-document translation.
 * ======================================================================== */

typedef struct {
    int kind; /* 0 body, 1 outline, 2 comment */
    int page;
    int index; /* outline pre-order index / visible comment index */
    spdf_rect bounds;
    float font_size;
} TranslateDocItem;

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;    /* validated with translate_tab_alive before use */
    char* tool;
    SpdfPasswordSource source;
    char* from_lang;
    char* to_lang;
    char* output_path;
    char* tmp_pdf_path;
    gboolean offered_installer;
    SpdfToolchainProgress* progress; /* ref held */
    GCancellable* cancellable;       /* ref held */
    /* worker results */
    gboolean success;
    gboolean canceled;
    char* message;
} TranslateDocJob;
static void translate_doc_job_free(TranslateDocJob* job) {
    g_object_unref(job->win);
    g_free(job->tool);
    spdf_password_source_clear(&job->source);
    g_free(job->from_lang);
    g_free(job->to_lang);
    g_free(job->output_path);
    g_free(job->tmp_pdf_path);
    spdf_toolchain_progress_unref(job->progress);
    g_object_unref(job->cancellable);
    g_free(job->message);
    g_free(job);
}

/* --- worker → main-thread progress ---------------------------------------- */

typedef struct {
    SpdfToolchainProgress* progress; /* ref held */
    double fraction;
    char* message;
} TranslateProgressUpdate;

static gboolean translate_progress_idle(gpointer data) {
    TranslateProgressUpdate* update = (TranslateProgressUpdate*)data;

    if (update->fraction >= 0.0) spdf_toolchain_progress_set_fraction(update->progress, update->fraction);
    if (update->message) {
        spdf_toolchain_progress_set_message(update->progress, update->message);
        spdf_toolchain_progress_append_log(update->progress, update->message);
        spdf_toolchain_progress_append_log(update->progress, "\n");
    }
    spdf_toolchain_progress_unref(update->progress);
    g_free(update->message);
    g_free(update);
    return G_SOURCE_REMOVE;
}

static void translate_queue_progress(TranslateDocJob* job, double fraction, const char* message) {
    TranslateProgressUpdate* update = g_new0(TranslateProgressUpdate, 1);
    update->progress = spdf_toolchain_progress_ref(job->progress);
    update->fraction = fraction;
    update->message = g_strdup(message);
    g_idle_add(translate_progress_idle, update);
}

/* --- item collection (78072bf55: body lines + chapters + comments, all
 * through the per-item script filter) --------------------------------------- */

static gboolean translate_collect_items(TranslateDocJob* job, GArray* items, /* TranslateDocItem */
                                        GPtrArray* src_lines,                /* char*, one per item */
                                        char** message_out) {
    char err[1024] = "";
    spdf_document* doc;
    int page_count;
    spdf_translation_script source_script = spdf_translation_script_for_language(job->from_lang);
    spdf_translation_script target_script = spdf_translation_script_for_language(job->to_lang);
    spdf_outline outline;
    spdf_comments comments;

    if (message_out) *message_out = NULL;
    doc = spdf_password_source_open(&job->source, err, sizeof(err));
    if (!doc) {
        if (message_out) *message_out = g_strdup(err[0] ? err : "Could not open document for translation.");
        return FALSE;
    }
    page_count = spdf_page_count(doc);

    for (int page = 0; page < page_count; ++page) {
        spdf_text_lines lines;
        memset(&lines, 0, sizeof(lines));
        if (!spdf_extract_page_text_lines(doc, page, &lines, err, sizeof(err))) {
            if (message_out)
                *message_out = g_strdup_printf("Could not extract text from page %d: %s", page + 1,
                                               err[0] ? err : "Unknown error");
            spdf_free_text_lines(&lines);
            spdf_close(doc);
            return FALSE;
        }
        for (int i = 0; i < lines.count; ++i) {
            TranslateDocItem item;
            if (!lines.items[i].text || !*lines.items[i].text) continue;
            /* Per-item translate/skip decision shared with the core; skipped
             * blocks stay untouched — no spawn, no overlay (78072bf55). */
            if (!spdf_translation_should_translate(lines.items[i].text, source_script, target_script)) continue;
            item.kind = 0;
            item.page = page;
            item.index = -1;
            item.bounds = lines.items[i].bounds;
            item.font_size = lines.items[i].font_size;
            g_array_append_val(items, item);
            g_ptr_array_add(src_lines, g_strdup(lines.items[i].text));
        }
        spdf_free_text_lines(&lines);
    }

    /* Chapter (outline) titles, collapsed to single lines, grouped as one
     * batch page after the last body page. */
    memset(&outline, 0, sizeof(outline));
    if (spdf_load_outline(doc, &outline, err, sizeof(err))) {
        for (int i = 0; i < outline.count; ++i) {
            char* title = spdf_translate_collapse_whitespace(outline.items[i].title);
            TranslateDocItem item;
            if (!*title || !spdf_translation_should_translate(title, source_script, target_script)) {
                g_free(title);
                continue;
            }
            item.kind = 1;
            item.page = page_count;
            item.index = i;
            memset(&item.bounds, 0, sizeof(item.bounds));
            item.font_size = 0.0f;
            g_array_append_val(items, item);
            g_ptr_array_add(src_lines, title);
        }
        spdf_free_outline(&outline);
    }

    /* Comment texts, one group after the outline titles. */
    memset(&comments, 0, sizeof(comments));
    if (spdf_load_comments(doc, &comments, err, sizeof(err))) {
        for (int i = 0; i < comments.count; ++i) {
            char* body = spdf_translate_collapse_whitespace(comments.items[i].text);
            TranslateDocItem item;
            if (!*body || comments.items[i].index < 0 ||
                !spdf_translation_should_translate(body, source_script, target_script)) {
                g_free(body);
                continue;
            }
            item.kind = 2;
            item.page = page_count + 1;
            item.index = comments.items[i].index;
            memset(&item.bounds, 0, sizeof(item.bounds));
            item.font_size = 0.0f;
            g_array_append_val(items, item);
            g_ptr_array_add(src_lines, body);
        }
        spdf_free_comments(&comments);
    }

    spdf_close(doc);
    return TRUE;
}

/* --- GTK3 fallback: external text extraction + cairo text PDF -------------- */

static char* translate_fallback_extract_text(const char* path, GCancellable* cancellable, char** message_out) {
    static const char* tools[][8] = {
        {"pdftotext", "-layout", NULL /* path */, "-", NULL},
        {"mutool", "draw", "-F", "txt", "-o", "-", NULL /* path */, NULL},
    };
    const int path_slot[] = {2, 6};

    if (message_out) *message_out = NULL;
    for (guint t = 0; t < G_N_ELEMENTS(tools); ++t) {
        char* tool = spdf_toolchain_find_tool(tools[t][0]);
        const char* argv[8];
        char* output = NULL;
        char* stderr_text = NULL;
        GError* error = NULL;
        gboolean ok;

        if (!tool) continue;
        for (int i = 0; i < 8; ++i) argv[i] = tools[t][i];
        argv[0] = tool;
        argv[path_slot[t]] = path;
        ok = spdf_toolchain_run_capture(argv, NULL, NULL, cancellable, &output, &stderr_text, &error);
        if (ok && output && output[0]) {
            g_free(stderr_text);
            g_free(tool);
            g_clear_error(&error);
            return output;
        }
        if (message_out && !*message_out && stderr_text && *stderr_text) *message_out = g_strdup(stderr_text);
        g_clear_error(&error);
        g_free(output);
        g_free(stderr_text);
        g_free(tool);
    }
    if (message_out && !*message_out)
        *message_out = g_strdup(
            "Full-document translation needs a document text extraction API, pdftotext, or mutool. "
            "Select text and translate the selection, or install poppler-utils/mupdf-tools.");
    return NULL;
}

static gboolean translate_fallback_next_line(cairo_t* cr, double* y, double page_height, double margin,
                                             double line_height) {
    *y += line_height;
    if (*y <= page_height - margin) return FALSE;
    cairo_show_page(cr);
    *y = margin;
    return TRUE;
}

/* Port of the GTK3 write_translated_text_pdf cairo pipeline (@8243): a fresh
 * A4 text PDF with the translated paragraphs word-wrapped. Used only when the
 * core cannot extract positioned text lines from the source document. */
static gboolean translate_fallback_write_pdf(const char* path, const char* source_path, const char* target_language,
                                             const char* text, char** message_out) {
    const double page_width = 595.0;
    const double page_height = 842.0;
    const double margin = 48.0;
    const double line_height = 15.0;
    cairo_surface_t* surface;
    cairo_t* cr;
    cairo_status_t status;
    char* title;
    char* heading;
    char* valid_text;
    char** paragraphs;
    double y = margin;
    int language_index = spdf_translation_language_index(target_language);

    if (message_out) *message_out = NULL;
    surface = cairo_pdf_surface_create(path, page_width, page_height);
    cr = cairo_create(surface);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 13.0);
    title = g_path_get_basename(source_path);
    heading = language_index >= 0
                  ? g_strdup_printf("Translated to %s", spdf_translation_languages(NULL)[language_index].name)
                  : g_strdup("Translated document");
    cairo_move_to(cr, margin, y);
    cairo_show_text(cr, heading);
    y += line_height;
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 9.0);
    cairo_move_to(cr, margin, y);
    cairo_show_text(cr, title ? title : "");
    y += line_height * 1.4;
    cairo_set_font_size(cr, 11.0);

    valid_text = g_utf8_make_valid(text ? text : "", -1);
    paragraphs = g_strsplit(valid_text, "\n", -1);
    for (int i = 0; paragraphs[i]; ++i) {
        char* paragraph = g_strstrip(paragraphs[i]);
        char** words;
        GString* line;

        if (!*paragraph) {
            translate_fallback_next_line(cr, &y, page_height, margin, line_height);
            continue;
        }

        words = g_strsplit_set(paragraph, " \t\r", -1);
        line = g_string_new("");
        for (int word_index = 0; words[word_index]; ++word_index) {
            cairo_text_extents_t extents;
            char* candidate;
            if (!*words[word_index]) continue;
            candidate =
                line->len ? g_strdup_printf("%s %s", line->str, words[word_index]) : g_strdup(words[word_index]);
            cairo_text_extents(cr, candidate, &extents);
            if (line->len && extents.x_advance > page_width - margin * 2.0) {
                cairo_move_to(cr, margin, y);
                cairo_show_text(cr, line->str);
                translate_fallback_next_line(cr, &y, page_height, margin, line_height);
                g_string_assign(line, words[word_index]);
            } else {
                g_string_assign(line, candidate);
            }
            g_free(candidate);
        }
        if (line->len) {
            cairo_move_to(cr, margin, y);
            cairo_show_text(cr, line->str);
            translate_fallback_next_line(cr, &y, page_height, margin, line_height);
        }
        g_string_free(line, TRUE);
        g_strfreev(words);
    }

    cairo_destroy(cr);
    cairo_surface_finish(surface);
    status = cairo_surface_status(surface);
    cairo_surface_destroy(surface);
    g_strfreev(paragraphs);
    g_free(valid_text);
    g_free(heading);
    g_free(title);

    if (status != CAIRO_STATUS_SUCCESS) {
        if (message_out) *message_out = g_strdup(cairo_status_to_string(status));
        return FALSE;
    }
    return TRUE;
}

/* --- the worker ------------------------------------------------------------ */

static gboolean translate_doc_finished(gpointer data); /* main-thread epilogue */

static gboolean translate_run_argos(TranslateDocJob* job, const char* input, char** translated_out,
                                    char** failure_out) {
    const char* argv[] = {job->tool, "--from-lang", job->from_lang, "--to-lang", job->to_lang, NULL};
    char* stdout_text = NULL;
    char* stderr_text = NULL;
    GError* error = NULL;
    gboolean ok;

    *translated_out = NULL;
    *failure_out = NULL;
    ok = spdf_toolchain_run_capture(argv, NULL, input, job->cancellable, &stdout_text, &stderr_text, &error);
    if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) || g_cancellable_is_cancelled(job->cancellable)) {
        job->canceled = TRUE;
        *failure_out = g_strdup("Translation canceled.");
    } else if (!ok || !stdout_text || !stdout_text[0]) {
        const char* detail = error && error->message       ? error->message
                             : stderr_text && *stderr_text ? stderr_text
                             : stdout_text && *stdout_text ? stdout_text
                                                           : "Argos Translate exited with an error.";
        *failure_out = g_strdup(detail);
    } else {
        *translated_out = spdf_toolchain_strip_argos_diagnostics(stdout_text);
    }
    g_clear_error(&error);
    g_free(stdout_text);
    g_free(stderr_text);
    return *translated_out != NULL;
}

static gpointer translate_doc_thread(gpointer data) {
    TranslateDocJob* job = (TranslateDocJob*)data;
    GArray* items = g_array_new(FALSE, FALSE, sizeof(TranslateDocItem));
    GPtrArray* src_lines = g_ptr_array_new_with_free_func(g_free);
    char** result_lines = NULL;
    char* detail = NULL;
    gsize total_bytes = 0;
    int count;

    translate_queue_progress(job, 0.02, "Extracting document text...");
    if (!translate_collect_items(job, items, src_lines, &detail)) {
        job->message = detail ? detail : g_strdup("Could not prepare translation.");
        detail = NULL;
        goto done;
    }
    count = (int)items->len;

    if (count == 0) {
        /* GTK3 fallback: some PDFs expose text only to external extractors.
         * One Argos spawn over the whole text, then a fresh cairo text PDF. */
        char* text = job->source.credential
                         ? NULL
                         : translate_fallback_extract_text(job->source.path, job->cancellable, &detail);
        char* translated = NULL;
        char* failure = NULL;

        if (!text) {
            job->message = detail ? detail
                                  : g_strdup(
                                        "No text block, chapter title or comment in this document needs "
                                        "translation for the selected languages.");
            detail = NULL;
            goto done;
        }
        if (strlen(text) > MAX_TRANSLATE_TEXT_BYTES) {
            job->message = g_strdup("The extracted text is too large to translate in this build.");
            g_free(text);
            goto done;
        }
        translate_queue_progress(job, 0.10, "Translating document text...");
        if (!translate_run_argos(job, text, &translated, &failure)) {
            job->message = failure;
            g_free(text);
            goto done;
        }
        g_free(text);
        translate_queue_progress(job, 0.93, "Writing translated PDF...");
        if (!translate_fallback_write_pdf(job->tmp_pdf_path, job->source.path, job->to_lang, translated, &detail)) {
            job->message = detail ? detail : g_strdup("Could not write translated PDF.");
            detail = NULL;
            g_free(translated);
            goto done;
        }
        g_free(translated);
    } else {
        for (guint i = 0; i < src_lines->len; ++i)
            total_bytes += strlen((const char*)g_ptr_array_index(src_lines, i)) + 1;
        if (total_bytes > MAX_TRANSLATE_TEXT_BYTES) {
            job->message = g_strdup("The extracted text is too large to translate in this build.");
            goto done;
        }

        result_lines = g_new0(char*, count);
        {
            /* kind/page shadow array for the pure batching helpers. */
            SpdfTranslateBatchItem* batch_items = g_new0(SpdfTranslateBatchItem, count);
            int start = 0;

            for (int i = 0; i < count; ++i) {
                const TranslateDocItem* item = &g_array_index(items, TranslateDocItem, i);
                batch_items[i].kind = item->kind;
                batch_items[i].page = item->page;
            }

            while (start < count) {
                int end = spdf_translate_batch_end(batch_items, count, start, SPDF_TRANSLATE_BATCH_LINE_BUDGET);
                char* scope = spdf_translate_batch_scope(batch_items, count, start, end);
                GString* batch_input = g_string_new("");
                char* translated = NULL;
                char* failure = NULL;
                char progress_text[192];

                if (g_cancellable_is_cancelled(job->cancellable)) {
                    job->canceled = TRUE;
                    job->message = g_strdup("Translation canceled.");
                    g_free(scope);
                    g_string_free(batch_input, TRUE);
                    break;
                }
                g_snprintf(progress_text, sizeof(progress_text), "Translating %s (%d of %d text items)...", scope,
                           start, count);
                translate_queue_progress(job, 0.05 + 0.85 * ((double)start / MAX(1, count)), progress_text);

                for (int i = start; i < end; ++i) {
                    g_string_append(batch_input, (const char*)g_ptr_array_index(src_lines, i));
                    g_string_append_c(batch_input, '\n');
                }
                if (!translate_run_argos(job, batch_input->str, &translated, &failure)) {
                    if (!job->canceled && failure) {
                        /* "Page 3: ..." / "Chapter titles: ..." error prefix. */
                        char* prefix = g_strdup(scope);
                        if (prefix[0]) prefix[0] = g_ascii_toupper(prefix[0]);
                        job->message = g_strdup_printf("%s: %s", prefix, failure);
                        g_free(prefix);
                        g_free(failure);
                    } else {
                        job->message = failure;
                    }
                    g_free(scope);
                    g_string_free(batch_input, TRUE);
                    break;
                }
                spdf_translate_apply_batch_output(result_lines, start, end, translated);
                g_free(translated);
                g_string_free(batch_input, TRUE);
                start = end;
                g_snprintf(progress_text, sizeof(progress_text), "Translated %s (%d of %d text items).", scope, start,
                           count);
                translate_queue_progress(job, 0.05 + 0.85 * ((double)start / MAX(1, count)), progress_text);
                g_free(scope);
            }
            g_free(batch_items);
            if (job->message) goto done;
        }

        /* Write the translated copy: body overlays via spdf_translated_line,
         * chapter titles + comment texts via spdf_save_translated_copy_full
         * (78072bf55). Arrays stay index-sorted because items were collected
         * in load order. */
        translate_queue_progress(job, 0.93, "Writing translated PDF...");
        {
            char err[1024] = "";
            spdf_document* save_doc = spdf_password_source_open(&job->source, err, sizeof(err));
            spdf_translated_line* lines;
            spdf_translated_text* outline_titles;
            spdf_translated_text* comment_texts;
            GPtrArray* retained = g_ptr_array_new_with_free_func(g_free);
            int line_count = 0;
            int outline_count = 0;
            int comment_count = 0;
            gboolean wrote;

            if (!save_doc) {
                job->message = g_strdup(err[0] ? err : "Could not reopen document to save translation.");
                g_ptr_array_unref(retained);
                goto done;
            }
            lines = g_new0(spdf_translated_line, count);
            outline_titles = g_new0(spdf_translated_text, count);
            comment_texts = g_new0(spdf_translated_text, count);
            for (int i = 0; i < count; ++i) {
                const TranslateDocItem* item = &g_array_index(items, TranslateDocItem, i);
                const char* line_text = result_lines[i] && result_lines[i][0] ? result_lines[i] : " ";
                if (item->kind == 1) {
                    /* Titles must stay single-line; keep the original when
                     * Argos produced nothing for this line. */
                    char* title = spdf_translate_collapse_whitespace(line_text);
                    if (!*title) {
                        g_free(title);
                        continue;
                    }
                    g_ptr_array_add(retained, title);
                    outline_titles[outline_count].index = item->index;
                    outline_titles[outline_count].text = title;
                    outline_count++;
                } else if (item->kind == 2) {
                    char* body = g_strdup(line_text);
                    g_strstrip(body);
                    if (!*body) {
                        g_free(body);
                        continue;
                    }
                    g_ptr_array_add(retained, body);
                    comment_texts[comment_count].index = item->index;
                    comment_texts[comment_count].text = body;
                    comment_count++;
                } else {
                    lines[line_count].page_index = item->page;
                    lines[line_count].bounds = item->bounds;
                    lines[line_count].font_size = item->font_size;
                    lines[line_count].opaque_background = SPDF_TRANSLATION_BACKGROUND_OPAQUE;
                    lines[line_count].text = line_text;
                    line_count++;
                }
            }
            wrote = spdf_save_translated_copy_full(save_doc, job->tmp_pdf_path, lines, line_count, outline_titles,
                                                   outline_count, comment_texts, comment_count, err, sizeof(err));
            spdf_close(save_doc);
            g_free(lines);
            g_free(outline_titles);
            g_free(comment_texts);
            g_ptr_array_unref(retained);
            if (!wrote) {
                job->message = g_strdup(err[0] ? err : "Could not write translated PDF.");
                goto done;
            }
        }
    }

    if (g_rename(job->tmp_pdf_path, job->output_path) != 0) {
        job->message = g_strdup("Could not move translated PDF into place.");
        g_remove(job->tmp_pdf_path);
        goto done;
    }
    job->success = TRUE;
    job->message = g_strdup("Translated document opened.");
    translate_queue_progress(job, 1.0, "Translation complete.");

done:
    if (!job->success) g_remove(job->tmp_pdf_path);
    g_free(detail);
    if (result_lines) {
        for (int i = 0; i < (int)items->len; ++i) g_free(result_lines[i]);
        g_free(result_lines);
    }
    g_array_unref(items);
    g_ptr_array_unref(src_lines);
    g_idle_add(translate_doc_finished, job);
    return NULL;
}

/* --- main-thread epilogue + argospm resume ---------------------------------- */

static void translate_doc_start(SpdfWindow* win, SpdfTab* tab, char* tool_owned, const char* from_lang,
                                const char* to_lang, gboolean offered_installer);

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
    char* from_lang;
    char* to_lang;
} TranslateRetryCtx;

static void translate_retry_ctx_free(TranslateRetryCtx* ctx) {
    g_object_unref(ctx->win);
    g_free(ctx->from_lang);
    g_free(ctx->to_lang);
    g_free(ctx);
}

static void translate_package_install_done(gboolean success, const char* output, gpointer user_data) {
    TranslateRetryCtx* ctx = (TranslateRetryCtx*)user_data;
    char* tool = spdf_toolchain_find_tool("argos-translate");

    (void)output;
    if (success && tool && translate_tab_alive(ctx->win, ctx->tab)) {
        translate_doc_start(ctx->win, ctx->tab, g_steal_pointer(&tool), ctx->from_lang, ctx->to_lang, TRUE);
    } else {
        if (SPDF_IS_WINDOW(ctx->win)) spdf_window_add_toast(ctx->win, "Translation package installation failed.");
    }
    g_free(tool);
    translate_retry_ctx_free(ctx);
}

static void translate_package_install_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    TranslateRetryCtx* ctx = (TranslateRetryCtx*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    char* package;
    char* script;
    char* initial_log;

    if (g_strcmp0(response, "install") != 0 || !SPDF_IS_WINDOW(ctx->win)) {
        translate_retry_ctx_free(ctx);
        return;
    }
    package = spdf_toolchain_argos_package_name(ctx->from_lang, ctx->to_lang);
    script = g_strdup_printf(
        "export PATH=\"$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"\n"
        "exec argospm install %s\n",
        package);
    initial_log = g_strdup_printf("Running argospm install %s...\n", package);
    spdf_toolchain_run_install_script(GTK_WINDOW(ctx->win), "Installing Translation Package",
                                      "Installing language package", initial_log, script,
                                      translate_package_install_done, ctx);
    g_free(initial_log);
    g_free(script);
    g_free(package);
}

static gboolean translate_doc_finished(gpointer data) {
    TranslateDocJob* job = (TranslateDocJob*)data;
    SpdfWindow* win = job->win;

    translate_set_busy(win, FALSE);
    spdf_toolchain_progress_close(job->progress);
    if (job->success) {
        if (SPDF_IS_WINDOW(win)) {
            char* base = g_path_get_basename(job->output_path);
            char* toast = g_strdup_printf("Translation saved: %s", base);
            spdf_window_open_path(win, job->output_path, 0, TRUE);
            spdf_window_add_toast(win, toast);
            g_free(toast);
            g_free(base);
        }
    } else if (job->canceled) {
        if (SPDF_IS_WINDOW(win)) spdf_window_add_toast(win, "Translation canceled.");
    } else if (!job->offered_installer && spdf_toolchain_argos_failure_is_missing_package(job->message) &&
               SPDF_IS_WINDOW(win) && translate_tab_alive(win, job->tab)) {
        /* Only missing-package failures get the argospm prompt; anything else
         * must show the real error (Mac 78072-era rule). */
        TranslateRetryCtx* ctx = g_new0(TranslateRetryCtx, 1);
        char* package = spdf_toolchain_argos_package_name(job->from_lang, job->to_lang);
        AdwDialog* dialog;

        ctx->win = g_object_ref(win);
        ctx->tab = job->tab;
        ctx->from_lang = g_strdup(job->from_lang);
        ctx->to_lang = g_strdup(job->to_lang);
        dialog = adw_alert_dialog_new("Install Argos language package?", NULL);
        adw_alert_dialog_format_body(ADW_ALERT_DIALOG(dialog),
                                     "The offline %s to %s package may be missing. Shenzhen PDF can ask argospm to "
                                     "install %s, then continue translation.",
                                     job->from_lang, job->to_lang, package ? package : "it");
        adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "install", "_Install", NULL);
        adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "install", ADW_RESPONSE_SUGGESTED);
        adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "install");
        adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
        adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, translate_package_install_response,
                                ctx);
        g_free(package);
    } else {
        translate_show_error(win, "Translation failed", job->message);
    }
    translate_doc_job_free(job);
    return G_SOURCE_REMOVE;
}

static void translate_doc_start(SpdfWindow* win, SpdfTab* tab, char* tool_owned, const char* from_lang,
                                const char* to_lang, gboolean offered_installer) {
    TranslateDocJob* job = g_new0(TranslateDocJob, 1);

    job->win = g_object_ref(win);
    job->tab = tab;
    job->tool = tool_owned;
    spdf_password_source_init(&job->source, tab->path, tab->credential);
    job->from_lang = g_strdup(from_lang);
    job->to_lang = g_strdup(to_lang);
    job->output_path = spdf_translate_output_path(tab->path, to_lang);
    job->tmp_pdf_path = spdf_translate_temp_path(tab->path, g_random_int());
    job->offered_installer = offered_installer;
    job->cancellable = g_cancellable_new();
    job->progress =
        spdf_toolchain_progress_new(GTK_WINDOW(win), "Translating", "Translating with Argos", job->cancellable);
    spdf_toolchain_progress_set_message(job->progress, "Preparing translation...");
    spdf_toolchain_progress_append_log(job->progress, "Preparing translation...\n");
    translate_set_busy(win, TRUE);
    g_thread_unref(g_thread_new("translate", translate_doc_thread, job));
}

/* --- language prompt --------------------------------------------------------- */

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
    char* tool; /* owned; handed to the job */
    GtkDropDown* from_dd;
    GtkDropDown* to_dd;
    GPtrArray* from_codes;
    GPtrArray* to_codes;
} TranslatePrompt;

static void translate_prompt_free(TranslatePrompt* prompt) {
    g_object_unref(prompt->from_dd);
    g_object_unref(prompt->to_dd);
    g_ptr_array_unref(prompt->from_codes);
    g_ptr_array_unref(prompt->to_codes);
    g_object_unref(prompt->win);
    g_free(prompt->tool);
    g_free(prompt);
}

static void translate_prompt_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    TranslatePrompt* prompt = (TranslatePrompt*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    const char* from;
    const char* to;

    if (g_strcmp0(response, "translate") != 0 || !translate_tab_alive(prompt->win, prompt->tab) ||
        translate_is_busy(prompt->win)) {
        translate_prompt_free(prompt);
        return;
    }
    from = translate_dropdown_code(prompt->from_dd, prompt->from_codes);
    to = translate_dropdown_code(prompt->to_dd, prompt->to_codes);
    if (!from || !to || g_strcmp0(from, to) == 0) {
        /* GTK3 rejected equal languages by not accepting the dialog. */
        spdf_window_add_toast(prompt->win, "Choose different source and target languages.");
        translate_prompt_free(prompt);
        return;
    }
    translate_persist_languages(prompt->win, from, to);
    translate_doc_start(prompt->win, prompt->tab, g_steal_pointer(&prompt->tool), from, to, FALSE);
    translate_prompt_free(prompt);
}

/* Continuation invoked by spdf_annot_preflight (data = TranslatePrompt shell
 * carrying the tool; the dropdowns are created here). */
static void translate_preflight_cont(SpdfWindow* win, SpdfTab* tab, gpointer data) {
    TranslatePrompt* prompt = (TranslatePrompt*)data;
    SpdfSettings* settings = translate_settings(win);
    GtkWidget* grid = gtk_grid_new();
    GtkWidget* from_label = gtk_label_new("From");
    GtkWidget* to_label = gtk_label_new("To");
    GtkWidget* from_dd;
    GtkWidget* to_dd;
    AdwDialog* dialog;

    (void)tab;
    from_dd = translate_language_dropdown(
        settings && settings->translate_source_language ? settings->translate_source_language : "zh",
        &prompt->from_codes);
    to_dd = translate_language_dropdown(
        settings && settings->translate_target_language ? settings->translate_target_language : "en",
        &prompt->to_codes);
    prompt->from_dd = GTK_DROP_DOWN(g_object_ref(from_dd));
    prompt->to_dd = GTK_DROP_DOWN(g_object_ref(to_dd));

    gtk_label_set_xalign(GTK_LABEL(from_label), 0.0f);
    gtk_label_set_xalign(GTK_LABEL(to_label), 0.0f);
    gtk_grid_set_row_spacing(GTK_GRID(grid), 8);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
    gtk_grid_attach(GTK_GRID(grid), from_label, 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), from_dd, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), to_label, 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), to_dd, 1, 1, 1, 1);
    gtk_widget_set_hexpand(from_dd, TRUE);
    gtk_widget_set_hexpand(to_dd, TRUE);

    dialog = adw_alert_dialog_new("Translate", "Translate the whole document with Argos Translate.");
    adw_alert_dialog_set_extra_child(ADW_ALERT_DIALOG(dialog), grid);
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "translate", "_Translate", NULL);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "translate", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "translate");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, translate_prompt_response, prompt);
}

static void translate_prompt_abandoned(gpointer data) {
    TranslatePrompt* prompt = (TranslatePrompt*)data;
    /* Preflight abandoned before the dropdowns were created. */
    g_object_unref(prompt->win);
    g_free(prompt->tool);
    g_free(prompt);
}

/* --- Argos-missing installer for the whole-document path --------------------- */

typedef struct {
    SpdfWindow* win; /* ref held */
} TranslateInstallCtx;

static void translate_argos_install_done(gboolean success, const char* output, gpointer user_data) {
    TranslateInstallCtx* ctx = (TranslateInstallCtx*)user_data;
    char* tool = spdf_toolchain_find_tool("argos-translate");
    char* argospm = spdf_toolchain_find_tool("argospm");

    (void)output;
    translate_set_busy(ctx->win, FALSE);
    if (success && tool && argospm && SPDF_IS_WINDOW(ctx->win)) {
        /* GTK3 translate_install_finished_idle: re-enter the translate flow. */
        g_action_group_activate_action(G_ACTION_GROUP(ctx->win), "translate", NULL);
    } else if (SPDF_IS_WINDOW(ctx->win)) {
        spdf_window_add_toast(ctx->win, "Translation support installation failed.");
    }
    g_free(tool);
    g_free(argospm);
    g_object_unref(ctx->win);
    g_free(ctx);
}

static void translate_argos_install_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    TranslateInstallCtx* ctx = (TranslateInstallCtx*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    char* script;

    if (g_strcmp0(response, "install") != 0 || !SPDF_IS_WINDOW(ctx->win)) {
        g_object_unref(ctx->win);
        g_free(ctx);
        return;
    }
    translate_set_busy(ctx->win, TRUE);
    script = spdf_toolchain_argos_install_script();
    spdf_toolchain_run_install_script(GTK_WINDOW(ctx->win), "Installing Translation Support",
                                      "Installing Argos Translate", "Preparing Argos Translate installer...\n", script,
                                      translate_argos_install_done, ctx);
    g_free(script);
}

/* --- entry point --------------------------------------------------------------
 * Mac translateDocument: a live selection opens the selection dialog; anything
 * else runs the whole-document pipeline (preflight, prompt, worker). */

static void action_translate(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    char* selected;
    char* tool;
    char* argospm;
    TranslatePrompt* prompt;

    (void)action;
    (void)parameter;
    if (!tab || !tab->doc || !tab->path || !spdf_annot_path_has_pdf_extension(tab->path)) return;
    if (translate_is_busy(win)) return;
    if (!spdf_password_require_permission(GTK_WINDOW(win), tab->doc, 'c', "Translation is not allowed")) return;

    selected = tab->view ? spdf_doc_view_copy_selection(tab->view) : NULL;
    if (selected) {
        char* collapsed = spdf_translate_collapse_whitespace(selected);
        g_free(selected);
        if (*collapsed) {
            translate_selection_open(win, collapsed);
            g_free(collapsed);
            return;
        }
        g_free(collapsed);
    }

    tool = spdf_toolchain_find_tool("argos-translate");
    argospm = spdf_toolchain_find_tool("argospm");
    if (!tool || !argospm) {
        TranslateInstallCtx* ctx = g_new0(TranslateInstallCtx, 1);
        AdwDialog* dialog;

        g_free(tool);
        g_free(argospm);
        ctx->win = g_object_ref(win);
        dialog = adw_alert_dialog_new("Install translation support?",
                                      "Shenzhen PDF can install Argos Translate, then continue the "
                                      "translation flow when installation finishes.");
        adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "install", "_Install", NULL);
        adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "install", ADW_RESPONSE_SUGGESTED);
        adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "install");
        adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
        adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, translate_argos_install_response, ctx);
        return;
    }
    g_free(argospm);

    prompt = g_new0(TranslatePrompt, 1);
    prompt->win = g_object_ref(win);
    prompt->tab = tab;
    prompt->tool = tool;
    /* Writable preflight shared with rotate/comments/OCR (journal item 35):
     * the translated copy is written next to the source document. */
    spdf_annot_preflight(win, tab, "Translate", 'c', translate_preflight_cont, prompt, translate_prompt_abandoned);
}

static const GActionEntry k_translate_actions[] = {
    {"translate", action_translate, NULL, NULL, NULL, {0}},
};

void spdf_translate_install(SpdfWindow* win) {
    g_return_if_fail(SPDF_IS_WINDOW(win));
    g_action_map_add_action_entries(G_ACTION_MAP(win), k_translate_actions, G_N_ELEMENTS(k_translate_actions), win);
}

#endif /* SPDF_TRANSLATE_TESTING */
