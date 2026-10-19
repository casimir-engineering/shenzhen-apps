// spdf_default_reader.c — default-PDF-reader registration (Wave D). Contract,
// Mac provenance and the pure/live split in spdf_default_reader.h.

#include "spdf_default_reader.h"

#include <string.h>

/* ---------------------------------------------------------------------------
 * Pure logic (glib only). */

gboolean spdf_default_reader_should_prompt(gboolean desktop_installed, gboolean is_default,
                                           gboolean prompt_dismissed, gboolean already_prompted) {
    return desktop_installed && !is_default && !prompt_dismissed && !already_prompted;
}

gboolean spdf_default_reader_output_is_us(const char* xdg_mime_output) {
    char* trimmed;
    gboolean us;

    if (!xdg_mime_output || !*xdg_mime_output) return FALSE;
    trimmed = g_strstrip(g_strdup(xdg_mime_output));
    us = strcmp(trimmed, SPDF_DEFAULT_READER_DESKTOP_ID) == 0;
    g_free(trimmed);
    return us;
}

#ifndef SPDF_DEFAULT_READER_TESTING

#include "spdf_app.h"

/* ---------------------------------------------------------------------------
 * Live half. */

static gboolean g_reader_prompted; /* once per process, like the Mac launch prompt */

static SpdfApp* reader_window_app(SpdfWindow* win) {
    GtkApplication* app = win ? gtk_window_get_application(GTK_WINDOW(win)) : NULL;
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

static SpdfSettings* reader_settings(SpdfWindow* win) {
    SpdfApp* app = reader_window_app(win);
    return app ? spdf_state_settings(spdf_app_get_state(app)) : NULL;
}

static void reader_persist_dismissed(SpdfWindow* win) {
    SpdfApp* app = reader_window_app(win);
    SpdfSettings* settings = app ? spdf_state_settings(spdf_app_get_state(app)) : NULL;

    if (!settings || settings->default_reader_prompt_dismissed) return;
    settings->default_reader_prompt_dismissed = TRUE;
    spdf_state_save_settings(spdf_app_get_state(app));
}

/* shenzhenpdf.desktop present in any XDG applications dir? Source builds run
 * without one — the prompt must skip silently then. */
static gboolean reader_desktop_installed(void) {
    const char* const* dirs = g_get_system_data_dirs();
    char* path;
    gboolean found;

    path = g_build_filename(g_get_user_data_dir(), "applications", SPDF_DEFAULT_READER_DESKTOP_ID, NULL);
    found = g_file_test(path, G_FILE_TEST_IS_REGULAR);
    g_free(path);
    for (int i = 0; !found && dirs && dirs[i]; ++i) {
        path = g_build_filename(dirs[i], "applications", SPDF_DEFAULT_READER_DESKTOP_ID, NULL);
        found = g_file_test(path, G_FILE_TEST_IS_REGULAR);
        g_free(path);
    }
    return found;
}

/* --- async xdg-mime plumbing ------------------------------------------------
 * Every flow is: run xdg-mime, get stdout + exit status, continue. The window
 * rides the closure as a strong ref; a window closed mid-flight (application
 * unset by gtk_window_destroy) drops the continuation silently. */

typedef void (*ReaderQueryDone)(SpdfWindow* win, gboolean ok, const char* stdout_text, gpointer user_data);

typedef struct {
    SpdfWindow* win; /* owned ref */
    ReaderQueryDone done;
    gpointer user_data;
} ReaderExec;

static void reader_exec_finished(GObject* source, GAsyncResult* result, gpointer user_data) {
    ReaderExec* exec = user_data;
    GSubprocess* proc = G_SUBPROCESS(source);
    char* out = NULL;
    GError* error = NULL;
    gboolean ok = g_subprocess_communicate_utf8_finish(proc, result, &out, NULL, &error);

    if (ok) ok = g_subprocess_get_successful(proc);
    if (gtk_window_get_application(GTK_WINDOW(exec->win)))
        exec->done(exec->win, ok, out ? out : "", exec->user_data);
    g_clear_error(&error);
    g_free(out);
    g_object_unref(exec->win);
    g_free(exec);
}

static void reader_exec(SpdfWindow* win, const char* const* argv, ReaderQueryDone done, gpointer user_data) {
    GError* error = NULL;
    GSubprocess* proc = g_subprocess_newv(argv, G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE,
                                          &error);
    ReaderExec* exec;

    if (!proc) {
        /* No xdg-mime (bare containers): behave like a failed run. */
        if (done) done(win, FALSE, "", user_data);
        g_clear_error(&error);
        return;
    }
    exec = g_new0(ReaderExec, 1);
    exec->win = g_object_ref(win);
    exec->done = done;
    exec->user_data = user_data;
    g_subprocess_communicate_utf8_async(proc, NULL, NULL, reader_exec_finished, exec);
    g_object_unref(proc);
}

static void reader_query_default(SpdfWindow* win, ReaderQueryDone done, gpointer user_data) {
    const char* argv[] = {"xdg-mime", "query", "default", "application/pdf", NULL};
    reader_exec(win, argv, done, user_data);
}

static void reader_set_default(SpdfWindow* win, ReaderQueryDone done, gpointer user_data) {
    const char* argv[] = {"xdg-mime", "default", SPDF_DEFAULT_READER_DESKTOP_ID, "application/pdf", NULL};
    reader_exec(win, argv, done, user_data);
}

/* --- make-default flow (shared by the prompt and the menu action) ----------- */

static void make_default_verified(SpdfWindow* win, gboolean ok, const char* stdout_text, gpointer user_data) {
    (void)user_data;
    if (ok && spdf_default_reader_output_is_us(stdout_text))
        spdf_window_show_toast(win, "Shenzhen PDF is now the default PDF reader");
    else
        spdf_window_show_toast(win, "Could not set the default PDF reader (xdg-mime failed)");
}

static void make_default_set_done(SpdfWindow* win, gboolean ok, const char* stdout_text, gpointer user_data) {
    (void)stdout_text;
    (void)user_data;
    if (!ok) {
        spdf_window_show_toast(win, "Could not set the default PDF reader (xdg-mime failed)");
        return;
    }
    /* xdg-mime exits 0 even on some silent failures — verify by re-query
     * (the Mac port re-checks LSCopyDefaultRoleHandler the same way). */
    reader_query_default(win, make_default_verified, NULL);
}

static void reader_make_default(SpdfWindow* win) {
    reader_set_default(win, make_default_set_done, NULL);
}

/* --- one-time prompt --------------------------------------------------------- */

static void prompt_response(AdwAlertDialog* dialog, const char* response, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);

    (void)dialog;
    /* Mac fromLaunch semantics: showing the prompt once dismisses it forever,
     * whichever button (or Escape) ends it. */
    reader_persist_dismissed(win);
    if (g_strcmp0(response, "make-default") == 0) reader_make_default(win);
}

static void prompt_query_done(SpdfWindow* win, gboolean ok, const char* stdout_text, gpointer user_data) {
    AdwAlertDialog* dialog;

    (void)user_data;
    if (!ok) return; /* no xdg-mime — try again some other run */
    if (spdf_default_reader_output_is_us(stdout_text)) {
        /* Already default: persist the dismissal quietly (Mac launch path). */
        reader_persist_dismissed(win);
        return;
    }
    dialog = ADW_ALERT_DIALOG(adw_alert_dialog_new("Make Shenzhen PDF your default PDF reader?",
                                                   "PDF files opened from your file manager will open "
                                                   "in Shenzhen PDF."));
    adw_alert_dialog_add_responses(dialog, "not-now", "Not Now", "make-default", "Make Default", NULL);
    adw_alert_dialog_set_response_appearance(dialog, "make-default", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(dialog, "make-default");
    adw_alert_dialog_set_close_response(dialog, "not-now");
    g_signal_connect_object(dialog, "response", G_CALLBACK(prompt_response), win, 0);
    adw_dialog_present(ADW_DIALOG(dialog), GTK_WIDGET(win));
}

static gboolean prompt_check_idle(gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfSettings* settings = reader_settings(win);

    if (!gtk_window_get_application(GTK_WINDOW(win))) return G_SOURCE_REMOVE; /* closed already */
    if (!spdf_default_reader_should_prompt(reader_desktop_installed(), FALSE /* async check next */,
                                           settings ? settings->default_reader_prompt_dismissed : TRUE,
                                           FALSE /* g_reader_prompted checked before scheduling */))
        return G_SOURCE_REMOVE;
    reader_query_default(win, prompt_query_done, NULL);
    return G_SOURCE_REMOVE;
}

void spdf_default_reader_note_document_opened(SpdfWindow* win) {
    SpdfSettings* settings;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    /* Inside Flatpak, `xdg-mime default ...` (if present at all in the
     * runtime) edits the SANDBOX's mimeapps.list, not the host's — the
     * registration silently does nothing. Skip the prompt; making this work
     * would need a host-side portal (no default-handler portal exists yet). */
    if (spdf_running_in_flatpak()) return;
    if (g_reader_prompted) return;
    settings = reader_settings(win);
    if (settings && settings->default_reader_prompt_dismissed) return;
    g_reader_prompted = TRUE;
    /* Low priority: runs after the freshly opened document painted, so the
     * prompt never delays the first page (launch-speed rule). */
    g_idle_add_full(G_PRIORITY_LOW, prompt_check_idle, g_object_ref(win), g_object_unref);
}

/* --- win.make-default (hamburger menu; always available) --------------------- */

static void action_query_done(SpdfWindow* win, gboolean ok, const char* stdout_text, gpointer user_data) {
    (void)user_data;
    if (ok && spdf_default_reader_output_is_us(stdout_text)) {
        spdf_window_show_toast(win, "Shenzhen PDF is already the default PDF reader");
        return;
    }
    reader_make_default(win);
}

static void action_make_default(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);

    (void)action;
    (void)parameter;
    if (spdf_running_in_flatpak()) {
        /* Same sandbox limitation as the prompt path (see
         * spdf_default_reader_note_document_opened); the menu action gives
         * feedback instead of silently editing the sandbox's mimeapps.list. */
        spdf_window_show_toast(win, "Inside Flatpak, choose the default PDF app in your "
                                    "system Settings (Apps → Default Apps)");
        return;
    }
    if (!reader_desktop_installed()) {
        /* Menu path gives feedback where the automatic prompt stays silent. */
        spdf_window_show_toast(win, "shenzhenpdf.desktop is not installed — install the package to register");
        return;
    }
    reader_query_default(win, action_query_done, NULL);
}

void spdf_default_reader_install(SpdfWindow* win) {
    static const GActionEntry entries[] = {
        {"make-default", action_make_default, NULL, NULL, NULL, {0}},
    };

    g_return_if_fail(SPDF_IS_WINDOW(win));
    g_action_map_add_action_entries(G_ACTION_MAP(win), entries, G_N_ELEMENTS(entries), win);
}

#endif /* SPDF_DEFAULT_READER_TESTING */
