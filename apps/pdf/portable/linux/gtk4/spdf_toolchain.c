// spdf_toolchain.c — shared toolchain infrastructure for OCR + translation.
// See spdf_toolchain.h for the contract and GTK3 provenance map.

#include "spdf_toolchain.h"

#include <string.h>

/* ===========================================================================
 * Pure logic (glib only). Everything above the SPDF_TOOLCHAIN_TESTING guard
 * is exercised by tests/toolchain_test.c.
 * ======================================================================== */

/* --- package-manager command table (GTK3 ocr_install_script /
 * translate_install_script, one row per manager) ------------------------- */

typedef struct {
    const char* probe;              /* command -v name */
    const char* install_format;     /* printf format, %s = package list */
    const char* ocr_tool_packages;
    const char* chinese_traineddata_packages;
    const char* argos_packages;
} pm_row;

static const pm_row k_pm_table[SPDF_PKG_MANAGER_COUNT] = {
    [SPDF_PKG_APT] = {"apt-get", "pkexec /bin/sh -c 'apt-get update && apt-get install -y %s'",
                      "ocrmypdf tesseract-ocr", "tesseract-ocr-chi-sim tesseract-ocr-chi-tra", "argos-translate"},
    [SPDF_PKG_DNF] = {"dnf", "pkexec dnf install -y %s", "ocrmypdf tesseract",
                      "tesseract-langpack-chi_sim tesseract-langpack-chi_tra", "argos-translate"},
    [SPDF_PKG_PACMAN] = {"pacman", "pkexec pacman -S --needed --noconfirm %s", "ocrmypdf tesseract",
                         "tesseract-data-chi_sim tesseract-data-chi_tra", "argos-translate"},
    [SPDF_PKG_ZYPPER] = {"zypper", "pkexec zypper --non-interactive install %s", "ocrmypdf tesseract-ocr",
                         "tesseract-ocr-traineddata-chinese_simplified tesseract-ocr-traineddata-chinese_traditional",
                         "argos-translate"},
};

static gboolean pm_valid(SpdfPackageManager pm) {
    return pm >= 0 && pm < SPDF_PKG_MANAGER_COUNT;
}

const char* spdf_toolchain_pm_probe(SpdfPackageManager pm) {
    return pm_valid(pm) ? k_pm_table[pm].probe : NULL;
}

const char* spdf_toolchain_ocr_tool_packages(SpdfPackageManager pm) {
    return pm_valid(pm) ? k_pm_table[pm].ocr_tool_packages : NULL;
}

const char* spdf_toolchain_chinese_traineddata_packages(SpdfPackageManager pm) {
    return pm_valid(pm) ? k_pm_table[pm].chinese_traineddata_packages : NULL;
}

const char* spdf_toolchain_argos_packages(SpdfPackageManager pm) {
    return pm_valid(pm) ? k_pm_table[pm].argos_packages : NULL;
}

char* spdf_toolchain_pm_install_command(SpdfPackageManager pm, const char* packages) {
    if (!pm_valid(pm) || !packages || !*packages) return NULL;
    return g_strdup_printf(k_pm_table[pm].install_format, packages);
}

/* --- Tesseract language helpers (GTK3 @7184-@7246) ----------------------- */

char** spdf_ocr_language_components(const char* language) {
    return g_strsplit(language && *language ? language : "eng", "+", -1);
}

gboolean spdf_ocr_language_uses_extra_traineddata(const char* language) {
    gboolean extra = FALSE;
    char** parts = spdf_ocr_language_components(language);
    for (int i = 0; parts && parts[i]; i++) {
        if (g_strcmp0(parts[i], "eng") != 0) {
            extra = TRUE;
            break;
        }
    }
    g_strfreev(parts);
    return extra;
}

char* spdf_ocr_language_shell_list(const char* language) {
    char** parts = spdf_ocr_language_components(language);
    char* joined = g_strjoinv(" ", parts);
    g_strfreev(parts);
    return joined;
}

gboolean spdf_toolchain_list_output_has_language(const char* output, const char* language) {
    gboolean has_all = TRUE;
    char** parts = spdf_ocr_language_components(language);
    if (!parts || !parts[0]) has_all = FALSE;
    for (int i = 0; has_all && parts[i]; i++) {
        gboolean found = FALSE;
        char** lines = g_strsplit(output ? output : "", "\n", -1);
        for (int j = 0; lines && lines[j]; j++) {
            char* trimmed = g_strstrip(lines[j]);
            if (g_strcmp0(trimmed, parts[i]) == 0) {
                found = TRUE;
                break;
            }
        }
        g_strfreev(lines);
        has_all = found;
    }
    g_strfreev(parts);
    return has_all;
}

/* --- install plan + scripts ---------------------------------------------- */

void spdf_toolchain_ocr_install_plan(gboolean have_ocrmypdf,
                                     gboolean have_tesseract,
                                     gboolean language_ready,
                                     const char* language,
                                     SpdfOcrInstallPlan* plan) {
    if (!plan) return;
    plan->install_tools = !have_ocrmypdf || !have_tesseract;
    /* The distro Chinese langpacks are only worth attempting when the
     * language actually needs non-eng traineddata (GTK3 `extra` flag). */
    plan->install_chinese_packs = spdf_ocr_language_uses_extra_traineddata(language);
    /* The script's per-language loop self-checks, so the download phase is
     * requested whenever the language is not already covered. */
    plan->download_traineddata = !language_ready;
}

/* One `elif command -v <probe>` branch per manager, generated from the table
 * so the script and the tested command table can never drift apart. */
static void append_pm_dispatch(GString* script, const char* (*packages_for)(SpdfPackageManager), gboolean or_true) {
    for (int pm = 0; pm < SPDF_PKG_MANAGER_COUNT; pm++) {
        char* command = spdf_toolchain_pm_install_command((SpdfPackageManager)pm, packages_for((SpdfPackageManager)pm));
        g_string_append_printf(script, "  %s command -v %s >/dev/null 2>&1; then\n", pm == 0 ? "if" : "elif",
                               k_pm_table[pm].probe);
        g_string_append_printf(script, "    %s%s\n", command, or_true ? " || true" : "");
        g_free(command);
    }
}

char* spdf_toolchain_ocr_install_script(const char* language) {
    char* language_list = spdf_ocr_language_shell_list(language);
    char* quoted_languages = g_shell_quote(language_list);
    gboolean extra = spdf_ocr_language_uses_extra_traineddata(language);
    GString* script = g_string_new("set -e\n");

    g_string_append_printf(script, "OCR_LANGS=%s\n", quoted_languages);
    g_string_append(script,
                    "DATA_HOME=\"${XDG_DATA_HOME:-$HOME/.local/share}\"\n"
                    "TESS_PARENT=\"$DATA_HOME/shenzhenpdf/tesseract\"\n"
                    "mkdir -p \"$TESS_PARENT/tessdata\"\n"
                    "if ! command -v ocrmypdf >/dev/null 2>&1 || ! command -v tesseract >/dev/null 2>&1; then\n"
                    "  if ! command -v pkexec >/dev/null 2>&1; then echo 'pkexec is required to install OCR "
                    "packages.'; exit 1; fi\n");
    append_pm_dispatch(script, spdf_toolchain_ocr_tool_packages, FALSE);
    g_string_append(script,
                    "  else\n"
                    "    echo 'No supported package manager found (apt, dnf, pacman, zypper).'\n"
                    "    exit 1\n"
                    "  fi\n"
                    "fi\n");
    g_string_append_printf(script, "if [ \"%d\" = \"1\" ] && command -v pkexec >/dev/null 2>&1; then\n",
                           extra ? 1 : 0);
    append_pm_dispatch(script, spdf_toolchain_chinese_traineddata_packages, TRUE);
    g_string_append(script,
                    "  fi\n"
                    "fi\n"
                    "download_lang() {\n"
                    "  lang=\"$1\"\n"
                    "  url=\"https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/$lang.traineddata\"\n"
                    "  dest=\"$TESS_PARENT/tessdata/$lang.traineddata\"\n"
                    "  echo \"Downloading $lang traineddata...\"\n"
                    "  if command -v curl >/dev/null 2>&1; then curl -LfsS \"$url\" -o \"$dest\"; "
                    "elif command -v wget >/dev/null 2>&1; then wget -q \"$url\" -O \"$dest\"; "
                    "else echo 'curl or wget is required to download OCR language data.'; return 1; fi\n"
                    "}\n"
                    "for lang in $OCR_LANGS; do\n"
                    "  if command -v tesseract >/dev/null 2>&1 && tesseract --list-langs 2>/dev/null | grep -qx "
                    "\"$lang\"; then "
                    "echo \"Tesseract language $lang is installed.\"; "
                    "elif [ -f \"$TESS_PARENT/tessdata/$lang.traineddata\" ]; then "
                    "echo \"Bundled Shenzhen PDF language $lang is installed.\"; "
                    "else download_lang \"$lang\"; fi\n"
                    "done\n"
                    "command -v ocrmypdf >/dev/null 2>&1\n"
                    "command -v tesseract >/dev/null 2>&1\n");
    g_free(quoted_languages);
    g_free(language_list);
    return g_string_free(script, FALSE);
}

char* spdf_toolchain_argos_install_script(void) {
    GString* script = g_string_new(
        "set -e\n"
        "export PATH=\"$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"\n"
        "if command -v argos-translate >/dev/null 2>&1 && command -v argospm >/dev/null 2>&1; then exit 0; fi\n"
        "echo 'Installing Argos Translate...'\n"
        "if command -v pkexec >/dev/null 2>&1; then\n");
    append_pm_dispatch(script, spdf_toolchain_argos_packages, TRUE);
    g_string_append(script,
                    "  fi\n"
                    "fi\n"
                    "if ! command -v argos-translate >/dev/null 2>&1 || ! command -v argospm >/dev/null 2>&1; then\n"
                    "  if ! command -v python3 >/dev/null 2>&1; then echo 'python3 is required to install Argos "
                    "Translate.'; exit 1; fi\n"
                    "  python3 -m pip --version >/dev/null 2>&1 || python3 -m ensurepip --user >/dev/null 2>&1 || "
                    "true\n"
                    "  python3 -m pip install --user --upgrade argostranslate || "
                    "python3 -m pip install --user --break-system-packages --upgrade argostranslate\n"
                    "fi\n"
                    "command -v argos-translate >/dev/null 2>&1\n"
                    "command -v argospm >/dev/null 2>&1\n"
                    "echo 'Argos Translate installed. Install source-to-English language models with argospm if "
                    "needed.'\n");
    return g_string_free(script, FALSE);
}

/* --- Argos helpers (GTK3 @7971 + Mac missing-package classifier) --------- */

gboolean spdf_toolchain_is_argos_diagnostic_line(const char* line, gboolean previous_line_was_diagnostic) {
    char* trimmed;
    gboolean diagnostic;

    if (!line) return FALSE;
    trimmed = g_strdup(line);
    g_strstrip(trimmed);
    diagnostic = strstr(trimmed, "WARNING: Language ") && strstr(trimmed, " package ") && strstr(trimmed, " expects ");
    if (!diagnostic && previous_line_was_diagnostic)
        diagnostic = strcmp(trimmed, "added") == 0 || g_str_has_prefix(trimmed, "which has been added");
    g_free(trimmed);
    return diagnostic;
}

char* spdf_toolchain_strip_argos_diagnostics(const char* text) {
    char** lines;
    GString* cleaned;
    gboolean previous_line_was_diagnostic = FALSE;
    gboolean removed_any = FALSE;
    gboolean first_kept = TRUE;

    if (!text) return g_strdup("");
    lines = g_strsplit(text, "\n", -1);
    cleaned = g_string_new("");
    for (int i = 0; lines && lines[i]; ++i) {
        gboolean diagnostic = spdf_toolchain_is_argos_diagnostic_line(lines[i], previous_line_was_diagnostic);
        if (diagnostic) {
            previous_line_was_diagnostic = TRUE;
            removed_any = TRUE;
            continue;
        }
        previous_line_was_diagnostic = FALSE;
        if (!first_kept) g_string_append_c(cleaned, '\n');
        g_string_append(cleaned, lines[i]);
        first_kept = FALSE;
    }
    g_strfreev(lines);
    if (!removed_any) {
        g_string_free(cleaned, TRUE);
        return g_strdup(text);
    }
    return g_string_free(cleaned, FALSE);
}

gboolean spdf_toolchain_argos_failure_is_missing_package(const char* failure) {
    if (!failure) return FALSE;
    return strstr(failure, "is not an installed language") != NULL || strstr(failure, "No package") != NULL;
}

char* spdf_toolchain_argos_package_name(const char* from_lang, const char* to_lang) {
    if (!from_lang || !*from_lang || !to_lang || !*to_lang) return NULL;
    return g_strdup_printf("translate-%s_%s", from_lang, to_lang);
}

#ifndef SPDF_TOOLCHAIN_TESTING

/* ===========================================================================
 * Probing + subprocess seam (GTK/GIO).
 * ======================================================================== */

#include <gio/gio.h>

char* spdf_toolchain_find_tool(const char* name) {
    return g_find_program_in_path(name);
}

char* spdf_toolchain_custom_tessdata_parent(void) {
    return g_build_filename(g_get_user_data_dir(), "shenzhenpdf", "tesseract", NULL);
}

gboolean spdf_toolchain_tessdata_parent_has_language(const char* parent, const char* language) {
    gboolean has_all = TRUE;
    char** parts = spdf_ocr_language_components(language);
    if (!parts || !parts[0]) has_all = FALSE;
    for (int i = 0; has_all && parts[i]; i++) {
        char* filename = g_strdup_printf("%s.traineddata", parts[i]);
        char* path = g_build_filename(parent, "tessdata", filename, NULL);
        has_all = g_file_test(path, G_FILE_TEST_IS_REGULAR);
        g_free(path);
        g_free(filename);
    }
    g_strfreev(parts);
    return has_all;
}

gboolean spdf_toolchain_tesseract_has_language(const char* language) {
    char* tesseract = spdf_toolchain_find_tool("tesseract");
    gboolean has_language = FALSE;

    if (tesseract) {
        const char* argv[] = {tesseract, "--list-langs", NULL};
        char* stdout_text = NULL;
        char* stderr_text = NULL;
        /* --list-langs historically printed to stderr; check both. */
        if (spdf_toolchain_run_capture(argv, NULL, NULL, NULL, &stdout_text, &stderr_text, NULL)) {
            char* combined = g_strdup_printf("%s\n%s", stdout_text ? stdout_text : "", stderr_text ? stderr_text : "");
            has_language = spdf_toolchain_list_output_has_language(combined, language);
            g_free(combined);
        }
        g_free(stdout_text);
        g_free(stderr_text);
    }
    if (!has_language) {
        char* parent = spdf_toolchain_custom_tessdata_parent();
        has_language = spdf_toolchain_tessdata_parent_has_language(parent, language);
        g_free(parent);
    }
    g_free(tesseract);
    return has_language;
}

char* spdf_toolchain_tessdata_parent_for_language(const char* language) {
    char* parent = spdf_toolchain_custom_tessdata_parent();
    if (spdf_toolchain_tessdata_parent_has_language(parent, language)) return parent;
    g_free(parent);
    return NULL;
}

static void toolchain_force_exit_subprocess(GCancellable* cancellable, gpointer user_data) {
    (void)cancellable;
    g_subprocess_force_exit(G_SUBPROCESS(user_data));
}

gboolean spdf_toolchain_run_capture(const char* const* argv,
                                    const char* const* envp,
                                    const char* stdin_text,
                                    GCancellable* cancellable,
                                    char** stdout_out,
                                    char** stderr_out,
                                    GError** error) {
    GSubprocessLauncher* launcher;
    GSubprocess* subprocess;
    GSubprocessFlags flags = G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE;
    gchar* stdout_text = NULL;
    gchar* stderr_text = NULL;
    gulong cancel_id = 0;
    gboolean ok;

    if (stdout_out) *stdout_out = NULL;
    if (stderr_out) *stderr_out = NULL;
    if (stdin_text) flags |= G_SUBPROCESS_FLAGS_STDIN_PIPE;

    launcher = g_subprocess_launcher_new(flags);
    if (envp) g_subprocess_launcher_set_environ(launcher, (gchar**)envp);
    subprocess = g_subprocess_launcher_spawnv(launcher, argv, error);
    g_object_unref(launcher);
    if (!subprocess) return FALSE;

    if (cancellable)
        cancel_id = g_cancellable_connect(cancellable, G_CALLBACK(toolchain_force_exit_subprocess), subprocess, NULL);
    ok = g_subprocess_communicate_utf8(subprocess, stdin_text, cancellable, &stdout_text, &stderr_text, error);
    if (cancellable && cancel_id) g_cancellable_disconnect(cancellable, cancel_id);
    if (stdout_out) *stdout_out = stdout_text;
    else g_free(stdout_text);
    if (stderr_out) *stderr_out = stderr_text;
    else g_free(stderr_text);
    ok = ok && g_subprocess_get_successful(subprocess);
    g_object_unref(subprocess);
    return ok;
}

/* --- streaming spawn ------------------------------------------------------ */

typedef struct {
    GSubprocess* subprocess;
    GDataInputStream* lines;
    GString* collected;
    GCancellable* cancellable;
    gulong cancel_id;
    SpdfToolchainLineFunc on_line;
    SpdfToolchainExitFunc on_exit;
    gpointer user_data;
    gboolean lines_done;
    gboolean wait_done;
    gboolean wait_success;
} streaming_ctx;

static void streaming_ctx_maybe_finish(streaming_ctx* ctx) {
    if (!ctx->lines_done || !ctx->wait_done) return;
    if (ctx->cancellable && ctx->cancel_id) g_cancellable_disconnect(ctx->cancellable, ctx->cancel_id);
    if (ctx->on_exit) ctx->on_exit(ctx->wait_success, ctx->collected->str, ctx->user_data);
    g_clear_object(&ctx->cancellable);
    g_object_unref(ctx->lines);
    g_object_unref(ctx->subprocess);
    g_string_free(ctx->collected, TRUE);
    g_free(ctx);
}

static void streaming_read_line_cb(GObject* source, GAsyncResult* result, gpointer user_data) {
    streaming_ctx* ctx = (streaming_ctx*)user_data;
    gsize length = 0;
    char* line = g_data_input_stream_read_line_finish_utf8(G_DATA_INPUT_STREAM(source), result, &length, NULL);

    if (!line) {
        ctx->lines_done = TRUE;
        streaming_ctx_maybe_finish(ctx);
        return;
    }
    g_string_append(ctx->collected, line);
    g_string_append_c(ctx->collected, '\n');
    if (ctx->on_line) ctx->on_line(line, ctx->user_data);
    g_free(line);
    g_data_input_stream_read_line_async(ctx->lines, G_PRIORITY_DEFAULT, NULL, streaming_read_line_cb, ctx);
}

static void streaming_wait_cb(GObject* source, GAsyncResult* result, gpointer user_data) {
    streaming_ctx* ctx = (streaming_ctx*)user_data;
    GError* error = NULL;

    ctx->wait_success = g_subprocess_wait_check_finish(G_SUBPROCESS(source), result, &error);
    if (ctx->cancellable && g_cancellable_is_cancelled(ctx->cancellable)) ctx->wait_success = FALSE;
    if (error) {
        g_string_append_printf(ctx->collected, "%s\n", error->message);
        g_error_free(error);
    }
    ctx->wait_done = TRUE;
    streaming_ctx_maybe_finish(ctx);
}

gboolean spdf_toolchain_spawn_streaming(const char* const* argv,
                                        const char* const* envp,
                                        GCancellable* cancellable,
                                        SpdfToolchainLineFunc on_line,
                                        SpdfToolchainExitFunc on_exit,
                                        gpointer user_data,
                                        GError** error) {
    GSubprocessLauncher* launcher =
        g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_MERGE);
    GSubprocess* subprocess;
    streaming_ctx* ctx;

    if (envp) g_subprocess_launcher_set_environ(launcher, (gchar**)envp);
    subprocess = g_subprocess_launcher_spawnv(launcher, argv, error);
    g_object_unref(launcher);
    if (!subprocess) return FALSE;

    ctx = g_new0(streaming_ctx, 1);
    ctx->subprocess = subprocess;
    ctx->lines = g_data_input_stream_new(g_subprocess_get_stdout_pipe(subprocess));
    ctx->collected = g_string_new("");
    ctx->on_line = on_line;
    ctx->on_exit = on_exit;
    ctx->user_data = user_data;
    if (cancellable) {
        ctx->cancellable = g_object_ref(cancellable);
        ctx->cancel_id =
            g_cancellable_connect(cancellable, G_CALLBACK(toolchain_force_exit_subprocess), subprocess, NULL);
    }
    g_data_input_stream_read_line_async(ctx->lines, G_PRIORITY_DEFAULT, NULL, streaming_read_line_cb, ctx);
    /* wait uses no cancellable: the exit must always be observed, even after
     * a cancel force-exits the child. */
    g_subprocess_wait_check_async(subprocess, NULL, streaming_wait_cb, ctx);
    return TRUE;
}

/* ===========================================================================
 * Shared progress window.
 * ======================================================================== */

struct _SpdfToolchainProgress {
    int refs;
    GtkWindow* window; /* NULL after destroy */
    GtkLabel* message;
    GtkProgressBar* bar;
    GtkTextView* log;
    GtkButton* action_button; /* Cancel while running, Close when finished */
    GCancellable* cancellable;
    guint pulse_id;
    gboolean finished;
    gboolean pulsing;
};

static gboolean progress_pulse_tick(gpointer data) {
    SpdfToolchainProgress* p = (SpdfToolchainProgress*)data;
    if (!p->window || !p->pulsing || p->finished) {
        p->pulse_id = 0;
        return G_SOURCE_REMOVE;
    }
    gtk_progress_bar_pulse(p->bar);
    return G_SOURCE_CONTINUE;
}

static gboolean progress_close_request(GtkWindow* window, gpointer user_data) {
    SpdfToolchainProgress* p = (SpdfToolchainProgress*)user_data;
    (void)window;
    /* GTK3 block_dialog_delete: no closing while the job runs. */
    return p->finished ? GDK_EVENT_PROPAGATE : GDK_EVENT_STOP;
}

static void progress_window_destroyed(GtkWidget* widget, gpointer user_data) {
    SpdfToolchainProgress* p = (SpdfToolchainProgress*)user_data;
    (void)widget;
    if (p->pulse_id) {
        g_source_remove(p->pulse_id);
        p->pulse_id = 0;
    }
    p->window = NULL;
    p->message = NULL;
    p->bar = NULL;
    p->log = NULL;
    p->action_button = NULL;
    spdf_toolchain_progress_unref(p);
}

static void progress_action_clicked(GtkButton* button, gpointer user_data) {
    SpdfToolchainProgress* p = (SpdfToolchainProgress*)user_data;
    if (p->finished) {
        spdf_toolchain_progress_close(p);
        return;
    }
    if (p->cancellable) g_cancellable_cancel(p->cancellable);
    gtk_button_set_label(button, "Canceling...");
    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
}

SpdfToolchainProgress* spdf_toolchain_progress_new(GtkWindow* parent,
                                                   const char* title,
                                                   const char* heading,
                                                   GCancellable* cancellable) {
    SpdfToolchainProgress* p = g_new0(SpdfToolchainProgress, 1);
    GtkWidget* window = adw_window_new();
    GtkWidget* toolbar_view = adw_toolbar_view_new();
    GtkWidget* header = adw_header_bar_new();
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    GtkWidget* heading_label = gtk_label_new(heading);
    GtkWidget* message_label = gtk_label_new("");
    GtkWidget* bar = gtk_progress_bar_new();
    GtkWidget* scroll = gtk_scrolled_window_new();
    GtkWidget* log = gtk_text_view_new();
    GtkWidget* button_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);

    p->refs = 2; /* one for the caller, one owned by the window */
    p->window = GTK_WINDOW(window);
    p->message = GTK_LABEL(message_label);
    p->bar = GTK_PROGRESS_BAR(bar);
    p->log = GTK_TEXT_VIEW(log);
    p->cancellable = cancellable ? g_object_ref(cancellable) : NULL;
    p->pulsing = TRUE;

    gtk_window_set_title(GTK_WINDOW(window), title);
    gtk_window_set_default_size(GTK_WINDOW(window), 640, 380);
    gtk_window_set_modal(GTK_WINDOW(window), TRUE);
    if (parent) gtk_window_set_transient_for(GTK_WINDOW(window), parent);
    adw_header_bar_set_show_end_title_buttons(ADW_HEADER_BAR(header), FALSE);
    adw_header_bar_set_show_start_title_buttons(ADW_HEADER_BAR(header), FALSE);

    gtk_label_set_xalign(GTK_LABEL(heading_label), 0.0f);
    gtk_widget_add_css_class(heading_label, "heading");
    gtk_label_set_xalign(GTK_LABEL(message_label), 0.0f);
    gtk_label_set_wrap(GTK_LABEL(message_label), TRUE);
    gtk_widget_add_css_class(message_label, "dim-label");
    gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(bar), FALSE);

    gtk_text_view_set_editable(GTK_TEXT_VIEW(log), FALSE);
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(log), TRUE);
    gtk_text_view_set_cursor_visible(GTK_TEXT_VIEW(log), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(log), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(log), 6);
    gtk_text_view_set_right_margin(GTK_TEXT_VIEW(log), 6);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), log);
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_widget_add_css_class(scroll, "card");

    if (cancellable) {
        GtkWidget* cancel = gtk_button_new_with_label("Cancel");
        p->action_button = GTK_BUTTON(cancel);
        gtk_widget_set_halign(cancel, GTK_ALIGN_END);
        gtk_widget_set_hexpand(cancel, TRUE);
        g_signal_connect(cancel, "clicked", G_CALLBACK(progress_action_clicked), p);
        gtk_box_append(GTK_BOX(button_row), cancel);
    }

    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);
    gtk_widget_set_margin_top(box, 12);
    gtk_widget_set_margin_bottom(box, 12);
    gtk_box_append(GTK_BOX(box), heading_label);
    gtk_box_append(GTK_BOX(box), message_label);
    gtk_box_append(GTK_BOX(box), bar);
    gtk_box_append(GTK_BOX(box), scroll);
    gtk_box_append(GTK_BOX(box), button_row);

    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar_view), header);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar_view), box);
    adw_window_set_content(ADW_WINDOW(window), toolbar_view);

    g_signal_connect(window, "close-request", G_CALLBACK(progress_close_request), p);
    g_signal_connect(window, "destroy", G_CALLBACK(progress_window_destroyed), p);
    p->pulse_id = g_timeout_add(120, progress_pulse_tick, p);
    gtk_window_present(GTK_WINDOW(window));
    return p;
}

SpdfToolchainProgress* spdf_toolchain_progress_ref(SpdfToolchainProgress* p) {
    g_atomic_int_inc(&p->refs);
    return p;
}

void spdf_toolchain_progress_unref(SpdfToolchainProgress* p) {
    if (!p || !g_atomic_int_dec_and_test(&p->refs)) return;
    g_clear_object(&p->cancellable);
    g_free(p);
}

void spdf_toolchain_progress_append_log(SpdfToolchainProgress* p, const char* text) {
    GtkTextBuffer* buffer;
    GtkTextIter end;

    if (!p->log || !text || !*text) return;
    buffer = gtk_text_view_get_buffer(p->log);
    gtk_text_buffer_get_end_iter(buffer, &end);
    gtk_text_buffer_insert(buffer, &end, text, -1);
    gtk_text_buffer_get_end_iter(buffer, &end);
    gtk_text_view_scroll_to_iter(p->log, &end, 0.0, FALSE, 0.0, 1.0);
}

void spdf_toolchain_progress_set_message(SpdfToolchainProgress* p, const char* message) {
    if (p->message) gtk_label_set_text(p->message, message ? message : "");
}

void spdf_toolchain_progress_set_fraction(SpdfToolchainProgress* p, double fraction) {
    p->pulsing = FALSE;
    if (p->bar) gtk_progress_bar_set_fraction(p->bar, CLAMP(fraction, 0.0, 1.0));
}

void spdf_toolchain_progress_finish(SpdfToolchainProgress* p, gboolean success, const char* message) {
    p->finished = TRUE;
    p->pulsing = FALSE;
    if (p->bar) gtk_progress_bar_set_fraction(p->bar, success ? 1.0 : 0.0);
    if (message && *message) {
        spdf_toolchain_progress_set_message(p, message);
        spdf_toolchain_progress_append_log(p, message);
        spdf_toolchain_progress_append_log(p, "\n");
    }
    if (p->action_button) {
        gtk_button_set_label(p->action_button, "Close");
        gtk_widget_set_sensitive(GTK_WIDGET(p->action_button), TRUE);
    } else if (p->window) {
        GtkWidget* close_button = gtk_button_new_with_label("Close");
        GtkWidget* toolbar_view = gtk_window_get_child(p->window);
        GtkWidget* box = toolbar_view ? adw_toolbar_view_get_content(ADW_TOOLBAR_VIEW(toolbar_view)) : NULL;
        if (box) {
            gtk_widget_set_halign(close_button, GTK_ALIGN_END);
            p->action_button = GTK_BUTTON(close_button);
            g_signal_connect(close_button, "clicked", G_CALLBACK(progress_action_clicked), p);
            gtk_box_append(GTK_BOX(box), close_button);
        }
    }
}

void spdf_toolchain_progress_close(SpdfToolchainProgress* p) {
    p->finished = TRUE;
    if (p->window) gtk_window_destroy(p->window);
}

/* --- install-script convenience runner ------------------------------------ */

typedef struct {
    SpdfToolchainProgress* progress; /* ref held */
    SpdfToolchainScriptDone done;
    gpointer user_data;
} script_run_ctx;

static void script_line_cb(const char* line, gpointer user_data) {
    script_run_ctx* ctx = (script_run_ctx*)user_data;
    spdf_toolchain_progress_append_log(ctx->progress, line);
    spdf_toolchain_progress_append_log(ctx->progress, "\n");
}

static void script_exit_cb(gboolean success, const char* collected_output, gpointer user_data) {
    script_run_ctx* ctx = (script_run_ctx*)user_data;

    if (success) {
        spdf_toolchain_progress_close(ctx->progress);
    } else {
        spdf_toolchain_progress_finish(ctx->progress, FALSE,
                                       "Installation failed. The log above can be selected and copied.");
    }
    if (ctx->done) ctx->done(success, collected_output, ctx->user_data);
    spdf_toolchain_progress_unref(ctx->progress);
    g_free(ctx);
}

void spdf_toolchain_run_install_script(GtkWindow* parent,
                                       const char* title,
                                       const char* heading,
                                       const char* initial_log,
                                       const char* script,
                                       SpdfToolchainScriptDone done,
                                       gpointer user_data) {
    const char* argv[] = {"/bin/sh", "-c", script, NULL};
    script_run_ctx* ctx = g_new0(script_run_ctx, 1);
    GError* error = NULL;

    ctx->progress = spdf_toolchain_progress_new(parent, title, heading, NULL);
    ctx->done = done;
    ctx->user_data = user_data;
    if (initial_log && *initial_log) spdf_toolchain_progress_append_log(ctx->progress, initial_log);

    if (!spdf_toolchain_spawn_streaming(argv, NULL, NULL, script_line_cb, script_exit_cb, ctx, &error)) {
        spdf_toolchain_progress_finish(ctx->progress, FALSE,
                                       error && error->message ? error->message : "Could not start the installer.");
        if (ctx->done) ctx->done(FALSE, error && error->message ? error->message : "", ctx->user_data);
        g_clear_error(&error);
        spdf_toolchain_progress_unref(ctx->progress);
        g_free(ctx);
    }
}

#endif /* SPDF_TOOLCHAIN_TESTING */
