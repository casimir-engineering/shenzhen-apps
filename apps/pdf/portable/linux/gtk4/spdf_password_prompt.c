#include "spdf_password_prompt.h"

#include <string.h>

#include "spdf_password_controller.h"

struct _SpdfPasswordPrompt {
    gint refs;
    SpdfPasswordController* controller;
    GtkWindow* parent;
    gulong map_id;
    gulong close_id;
    AdwDialog* dialog;
    GtkPasswordEntry* entry;
    char* display_name;
    SpdfPasswordOpenReady ready;
    gpointer user_data;
    GDestroyNotify destroy;
    gboolean incorrect;
};

static SpdfPasswordPrompt* password_prompt_ref(SpdfPasswordPrompt* prompt) {
    g_atomic_int_inc(&prompt->refs);
    return prompt;
}

static void password_prompt_unref(SpdfPasswordPrompt* prompt) {
    if (!prompt || !g_atomic_int_dec_and_test(&prompt->refs)) return;
    if (prompt->entry) gtk_editable_set_text(GTK_EDITABLE(prompt->entry), "");
    g_clear_object(&prompt->entry);
    g_clear_object(&prompt->dialog);
    g_clear_object(&prompt->parent);
    g_free(prompt->display_name);
    if (prompt->destroy) prompt->destroy(prompt->user_data);
    g_free(prompt);
}

static void password_prompt_disconnect_parent(SpdfPasswordPrompt* prompt) {
    if (!prompt->parent) return;
    if (prompt->map_id) g_signal_handler_disconnect(prompt->parent, prompt->map_id);
    if (prompt->close_id) g_signal_handler_disconnect(prompt->parent, prompt->close_id);
    prompt->map_id = 0;
    prompt->close_id = 0;
}

static void password_controller_ready(spdf_document* document, SpdfPasswordCredential* credential, gboolean cancelled,
                                      const char* error, gpointer user_data) {
    SpdfPasswordPrompt* prompt = user_data;

    prompt->controller = NULL;
    password_prompt_disconnect_parent(prompt);
    if (prompt->ready) prompt->ready(document, credential, cancelled, error, prompt->user_data);
}

static void password_prompt_ask(SpdfPasswordPrompt* prompt);

static void password_controller_needs_secret(SpdfPasswordController* controller, gboolean incorrect,
                                             gpointer user_data) {
    SpdfPasswordPrompt* prompt = user_data;

    (void)controller;
    prompt->incorrect = incorrect;
    password_prompt_ask(prompt);
}

static void password_show_error(GtkWindow* parent, const char* heading, const char* detail) {
    GtkAlertDialog* alert = gtk_alert_dialog_new("%s", heading);
    gtk_alert_dialog_set_detail(alert, detail);
    gtk_alert_dialog_show(alert, parent && gtk_widget_get_mapped(GTK_WIDGET(parent)) ? parent : NULL);
    g_object_unref(alert);
}

gboolean spdf_password_require_permission(GtkWindow* parent, spdf_document* document, int permission,
                                          const char* heading) {
    const char* detail;

    if (document && spdf_has_permission(document, permission)) return TRUE;
    detail = permission == 'p'   ? "This PDF's permissions do not allow printing."
             : permission == 'c' ? "This PDF's permissions do not allow copying or text extraction."
             : permission == 'n' ? "This PDF's permissions do not allow annotations."
                                 : "This PDF's permissions do not allow editing.";
    password_show_error(parent, heading ? heading : "Action is not allowed", detail);
    return FALSE;
}

gboolean spdf_password_require_ocr(GtkWindow* parent, spdf_document* document) {
    if (document && spdf_is_password_protected(document)) {
        password_show_error(parent, "OCR is unavailable for this protected PDF",
                            "Save an intentionally unprotected copy, open that copy, and run OCR there.");
        return FALSE;
    }
    return spdf_password_require_permission(parent, document, 'e', "OCR is not allowed");
}

static void password_set_action_enabled(GActionMap* actions, const char* name, gboolean enabled) {
    GAction* action = actions ? g_action_map_lookup_action(actions, name) : NULL;
    if (action && G_IS_SIMPLE_ACTION(action)) g_simple_action_set_enabled(G_SIMPLE_ACTION(action), enabled);
}

void spdf_password_update_context_actions(GActionMap* actions, spdf_document* document, gboolean pdf,
                                          gboolean has_selection, gboolean has_annotation_target, gboolean has_comment,
                                          gboolean has_page) {
    SpdfPasswordPermissions permissions = spdf_password_permissions(document);

    password_set_action_enabled(actions, "copy", has_selection && permissions.copy);
    password_set_action_enabled(actions, "annot-add-comment", pdf && permissions.annotate && has_annotation_target);
    password_set_action_enabled(actions, "annot-add-highlight", pdf && permissions.annotate && has_selection);
    password_set_action_enabled(actions, "annot-edit-comment", pdf && permissions.annotate && has_comment);
    password_set_action_enabled(actions, "annot-delete-comment", pdf && permissions.annotate && has_comment);
    password_set_action_enabled(actions, "copy-page-pdf", permissions.copy && has_page);
    password_set_action_enabled(actions, "save-page-pdf", permissions.copy && has_page);
    password_set_action_enabled(actions, "rotate-cw", pdf && permissions.edit);
    password_set_action_enabled(actions, "rotate-ccw", pdf && permissions.edit);
}

static void password_prompt_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    SpdfPasswordPrompt* prompt = user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    char* password = prompt->entry ? g_strdup(gtk_editable_get_text(GTK_EDITABLE(prompt->entry))) : NULL;

    if (prompt->entry) gtk_editable_set_text(GTK_EDITABLE(prompt->entry), "");
    g_clear_object(&prompt->entry);
    g_clear_object(&prompt->dialog);
    if (prompt->controller && g_strcmp0(response, "unlock") == 0)
        spdf_password_controller_submit(prompt->controller, password ? password : "");
    else if (prompt->controller)
        spdf_password_controller_cancel(prompt->controller);
    if (password) {
        memset(password, 0, strlen(password));
        g_free(password);
    }
    password_prompt_unref(prompt);
}

static void password_prompt_show(SpdfPasswordPrompt* prompt) {
    GtkWidget* entry;

    if (!prompt->controller || prompt->dialog) return;
    prompt->dialog = g_object_ref_sink(
        adw_alert_dialog_new("Password Required", prompt->incorrect ? "Incorrect password. Try again." : NULL));
    if (!prompt->incorrect)
        adw_alert_dialog_format_body(ADW_ALERT_DIALOG(prompt->dialog), "Enter the password to open %s.",
                                     prompt->display_name && *prompt->display_name ? prompt->display_name : "this PDF");
    entry = gtk_password_entry_new();
    gtk_password_entry_set_show_peek_icon(GTK_PASSWORD_ENTRY(entry), FALSE);
    gtk_widget_set_hexpand(entry, TRUE);
    adw_alert_dialog_set_extra_child(ADW_ALERT_DIALOG(prompt->dialog), entry);
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(prompt->dialog), "cancel", "_Cancel", "unlock", "_Unlock", NULL);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(prompt->dialog), "unlock", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(prompt->dialog), "unlock");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(prompt->dialog), "cancel");
    adw_dialog_set_focus(prompt->dialog, entry);
    prompt->entry = g_object_ref(GTK_PASSWORD_ENTRY(entry));
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(prompt->dialog), prompt->parent ? GTK_WIDGET(prompt->parent) : NULL, NULL,
                            password_prompt_response, password_prompt_ref(prompt));
}

static void password_parent_mapped(GtkWidget* widget, gpointer user_data) {
    SpdfPasswordPrompt* prompt = user_data;

    (void)widget;
    if (prompt->map_id) g_signal_handler_disconnect(prompt->parent, prompt->map_id);
    prompt->map_id = 0;
    password_prompt_show(prompt);
}

static void password_prompt_ask(SpdfPasswordPrompt* prompt) {
    if (!prompt->parent || gtk_widget_get_mapped(GTK_WIDGET(prompt->parent))) {
        password_prompt_show(prompt);
        return;
    }
    if (!prompt->map_id)
        prompt->map_id = g_signal_connect(prompt->parent, "map", G_CALLBACK(password_parent_mapped), prompt);
    gtk_window_present(prompt->parent);
}

static gboolean password_parent_closed(GtkWindow* parent, gpointer user_data) {
    (void)parent;
    spdf_password_prompt_cancel(user_data);
    return FALSE;
}

SpdfPasswordPrompt* spdf_password_open_async(GtkWindow* parent, const char* source_path, const char* open_path,
                                             SpdfPasswordCredential* credential, SpdfPasswordOpenReady ready,
                                             gpointer user_data, GDestroyNotify destroy) {
    SpdfPasswordPrompt* prompt;
    char* canonical;

    g_return_val_if_fail(open_path && *open_path, NULL);
    prompt = g_new0(SpdfPasswordPrompt, 1);
    prompt->refs = 1;
    prompt->parent = parent ? g_object_ref(parent) : NULL;
    canonical = g_canonicalize_filename(source_path && *source_path ? source_path : open_path, NULL);
    prompt->display_name = g_path_get_basename(canonical);
    g_free(canonical);
    prompt->ready = ready;
    prompt->user_data = user_data;
    prompt->destroy = destroy;
    prompt->controller =
        spdf_password_controller_new(source_path, open_path, credential, password_controller_needs_secret,
                                     password_controller_ready, prompt, (GDestroyNotify)password_prompt_unref);
    if (!prompt->controller) {
        password_prompt_unref(prompt);
        return NULL;
    }
    if (parent)
        prompt->close_id = g_signal_connect(parent, "close-request", G_CALLBACK(password_parent_closed), prompt);
    spdf_password_controller_start(prompt->controller);
    return prompt;
}

void spdf_password_prompt_cancel(SpdfPasswordPrompt* prompt) {
    gboolean had_dialog;

    if (!prompt || !prompt->controller) return;
    had_dialog = prompt->dialog != NULL;
    if (had_dialog) password_prompt_ref(prompt);
    spdf_password_controller_cancel(prompt->controller);
    if (had_dialog) {
        if (prompt->dialog) adw_dialog_force_close(prompt->dialog);
        password_prompt_unref(prompt);
    }
}
