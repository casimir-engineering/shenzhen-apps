/* What every page shares (szfriends_gtk_list_page.h): the one table of ways out of the views (clipboard, URIs, the
 * image chooser, Settings' dialog); the one confirmation, a card over the dropdown or a dialog in Settings; running
 * an action; action buttons and plain-text labels. The pages' stylesheet is in szfriends_gtk_list_style.c. Mirrors
 * mac/SZFriendsContext.m's performAction and the confirmation card of mac/SZFriendsDropdownContent.m. */

#include "gtk/szfriends_gtk_link_private.h"
#include "gtk/szfriends_gtk_list_page.h"

#include <adwaita.h>
#include <string.h>

/* ---- The ways out -------------------------------------------------------------------------------- */

static SZFriendsGtkSeams seams;

void szfriends_gtk_set_seams(const SZFriendsGtkSeams *replacement) {
    if (replacement) seams = *replacement;
    else memset(&seams, 0, sizeof seams);
}

void szfriends_gtk_copy_text(GtkWidget *source, const char *text) {
    if (!text || !*text) return;
    if (seams.copy_text) seams.copy_text(source, text, seams.data);
    else gdk_clipboard_set_text(gtk_widget_get_clipboard(source), text);
}

static GtkWindow *window_of(GtkWidget *widget) {
    GtkRoot *root = widget ? gtk_widget_get_root(widget) : NULL;
    return root && GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL;
}

void szfriends_gtk_open_uri(GtkWidget *source, const char *uri) {
    if (!uri) return;
    if (seams.open_uri) {
        seams.open_uri(source, uri, seams.data);
        return;
    }
    GtkUriLauncher *launcher = gtk_uri_launcher_new(uri);
    gtk_uri_launcher_launch(launcher, window_of(source), NULL, NULL, NULL);
    g_object_unref(launcher);
}

typedef struct {
    SZFriendsGtkChosen chosen;
    gpointer data;
} SZFriendsGtkChoosing;

static void file_chosen(GObject *dialog, GAsyncResult *result, gpointer data) {
    SZFriendsGtkChoosing *choosing = data;
    GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(dialog), result, NULL);
    char *path = file ? g_file_get_path(file) : NULL;
    choosing->chosen(path, choosing->data);
    g_free(path);
    if (file) g_object_unref(file);
    g_free(choosing);
}

static void folder_chosen(GObject *dialog, GAsyncResult *result, gpointer data) {
    SZFriendsGtkChoosing *choosing = data;
    GFile *file = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(dialog), result, NULL);
    char *path = file ? g_file_get_path(file) : NULL;
    choosing->chosen(path, choosing->data);
    g_free(path);
    if (file) g_object_unref(file);
    g_free(choosing);
}

void szfriends_gtk_choose_folder(GtkWidget *source, const char *start, SZFriendsGtkChosen chosen, gpointer data) {
    if (seams.choose_folder) {
        seams.choose_folder(source, start, chosen, data, seams.data);
        return;
    }
    GtkFileDialog *dialog = gtk_file_dialog_new();
    if (start && *start) {
        GFile *folder = g_file_new_for_path(start);
        gtk_file_dialog_set_initial_folder(dialog, folder);
        g_object_unref(folder);
    }
    SZFriendsGtkChoosing *choosing = g_new0(SZFriendsGtkChoosing, 1);
    *choosing = (SZFriendsGtkChoosing){chosen, data};
    gtk_file_dialog_select_folder(dialog, window_of(source), NULL, folder_chosen, choosing);
    g_object_unref(dialog);
}

void szfriends_gtk_choose_image(GtkWidget *source, const char *title, SZFriendsGtkChosen chosen, gpointer data) {
    if (seams.choose_image) {
        seams.choose_image(source, title, chosen, data, seams.data);
        return;
    }
    GtkFileDialog *dialog = gtk_file_dialog_new();
    if (title && *title) gtk_file_dialog_set_title(dialog, title);
    /* The formats the helper takes for a picture (avatars/README.md § Photos), so the dialog offers only those. */
    GtkFileFilter *filter = gtk_file_filter_new();
    static const char *const types[] = {"image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"};
    for (gsize i = 0; i < G_N_ELEMENTS(types); i++) gtk_file_filter_add_mime_type(filter, types[i]);
    static const char *const suffixes[] = {"jpg", "jpeg", "png", "heic", "heif", "webp"};
    for (gsize i = 0; i < G_N_ELEMENTS(suffixes); i++) gtk_file_filter_add_suffix(filter, suffixes[i]);
    gtk_file_dialog_set_default_filter(dialog, filter);
    g_object_unref(filter);
    SZFriendsGtkChoosing *choosing = g_new0(SZFriendsGtkChoosing, 1);
    *choosing = (SZFriendsGtkChoosing){chosen, data};
    gtk_file_dialog_open(dialog, window_of(source), NULL, file_chosen, choosing);
    g_object_unref(dialog);
}

/* ---- Confirmations ------------------------------------------------------------------------------- */

typedef struct {
    SZFriendsGtkRun run;
    SZFriendsGtkRunTicked run_ticked; /* instead of run: also told whether the option was ticked */
    gboolean ticked;
    gpointer data;
    GDestroyNotify destroy;
} SZFriendsGtkQuestion;

static void question_free(gpointer data) {
    SZFriendsGtkQuestion *question = data;
    if (question->destroy) question->destroy(question->data);
    g_free(question);
}

/* Runs once: the closure is emptied first, so tearing down the card or dialog afterwards frees only its own. */
static void question_answered(SZFriendsGtkQuestion *question) {
    SZFriendsGtkQuestion taken = *question;
    *question = (SZFriendsGtkQuestion){0};
    if (taken.run_ticked) taken.run_ticked(taken.ticked, taken.data);
    else if (taken.run) taken.run(taken.data);
    if (taken.destroy) taken.destroy(taken.data);
}

static void question_answered_cb(gpointer data) {
    question_answered(data);
}

/* The question's option as a checkbox, unticked, or NULL when it has none this view can send. */
static GtkWidget *option_check(const SZFriendsGtkConfirm *confirm) {
    if (!szfriends_gtk_confirm_option_known(confirm)) return NULL;
    GtkWidget *check = gtk_check_button_new_with_label(confirm->option->label);
    gtk_widget_set_name(check, "szfriends.confirmation.option");
    return check;
}

static void take_ticked(SZFriendsGtkQuestion *question, GtkWidget *check) {
    question->ticked = check && gtk_check_button_get_active(GTK_CHECK_BUTTON(check));
}

static void alert_response(AdwAlertDialog *dialog, const char *response, gpointer data) {
    if (g_strcmp0(response, "confirm")) return;
    take_ticked(data, g_object_get_data(G_OBJECT(dialog), "szfriends-option"));
    question_answered(data);
}

static void system_confirm(GtkWidget *source, const SZFriendsGtkConfirm *confirm, gboolean destructive,
                           SZFriendsGtkQuestion *question) {
    AdwDialog *dialog = adw_alert_dialog_new(NULL, NULL);
    AdwAlertDialog *alert = ADW_ALERT_DIALOG(dialog);
    /* The question can name a friend: plain text, as everywhere else. */
    adw_alert_dialog_set_heading_use_markup(alert, FALSE);
    adw_alert_dialog_set_body_use_markup(alert, FALSE);
    adw_alert_dialog_set_heading(alert, confirm->title);
    adw_alert_dialog_set_body(alert, confirm->body);
    adw_alert_dialog_add_response(alert, "cancel", confirm->cancel_label);
    adw_alert_dialog_add_response(alert, "confirm", confirm->confirm_label);
    adw_alert_dialog_set_response_appearance(alert, "confirm",
                                             destructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(alert, "cancel");
    adw_alert_dialog_set_close_response(alert, "cancel");
    GtkWidget *check = option_check(confirm);
    if (check) {
        adw_alert_dialog_set_extra_child(alert, check);
        g_object_set_data(G_OBJECT(dialog), "szfriends-option", check);
    }
    g_object_set_data_full(G_OBJECT(dialog), "szfriends-question", question, question_free);
    g_signal_connect(dialog, "response", G_CALLBACK(alert_response), question);
    adw_dialog_present(dialog, source);
}

static void veil_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)data;
    /* The dimming libadwaita's own dialogs use, a little deeper in dark where the pages are already dark. */
    AdwStyleManager *style = adw_style_manager_get_for_display(gtk_widget_get_display(GTK_WIDGET(area)));
    cairo_set_source_rgba(cr, 0, 0, 0.02, adw_style_manager_get_dark(style) ? 0.45 : 0.25);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);
}

static void card_cancel(GtkButton *button, gpointer data) {
    (void)button;
    szfriends_gtk_dropdown_set_overlay(data, NULL);
}

static void card_confirm(GtkButton *button, gpointer data) {
    GtkWidget *card = g_object_get_data(G_OBJECT(button), "szfriends-card");
    SZFriendsGtkQuestion *question = g_object_steal_data(G_OBJECT(card), "szfriends-question");
    if (question) take_ticked(question, g_object_get_data(G_OBJECT(card), "szfriends-option"));
    szfriends_gtk_dropdown_set_overlay(data, NULL);
    if (question) {
        question_answered(question);
        question_free(question);
    }
}

static GtkWidget *card_button(const char *label, const char *name, const char *style) {
    GtkWidget *button = gtk_button_new_with_label(label);
    gtk_widget_set_name(button, name);
    if (style) gtk_widget_add_css_class(button, style);
    return button;
}

/* The card over the dropdown's pages, as the AppKit dropdown draws it: the question, Cancel, and a confirm button
 * that is red for a destructive question, never the blue that means "go ahead". */
static GtkWidget *confirm_card(SZFriendsGtkDropdown *dropdown, const SZFriendsGtkConfirm *confirm,
                               gboolean destructive, SZFriendsGtkQuestion *question) {
    GtkWidget *overlay = gtk_overlay_new();
    gtk_widget_set_name(overlay, "szfriends.confirmation");
    GtkWidget *veil = gtk_drawing_area_new();
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(veil), veil_draw, NULL, NULL);
    gtk_widget_set_can_target(veil, TRUE); /* clicks around the card land on the veil, never on the page under it */
    gtk_overlay_set_child(GTK_OVERLAY(overlay), veil);
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(card, "card");
    gtk_widget_add_css_class(card, "szfriends-confirm");
    gtk_widget_set_overflow(card, GTK_OVERFLOW_HIDDEN);
    gtk_widget_set_halign(card, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(card, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(card, 340, -1);
    /* An opaque face: a card alone is translucent in dark, and the page under it must not show through. */
    GtkWidget *face = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(face, "view");
    gtk_widget_add_css_class(face, "szfriends-confirm-face");
    gtk_box_append(GTK_BOX(card), face);
    GtkWidget *title = szfriends_gtk_list_label("heading"), *body = szfriends_gtk_list_label("szfriends-secondary");
    szfriends_gtk_list_label_set(title, confirm->title);
    szfriends_gtk_list_label_set(body, confirm->body);
    gtk_box_append(GTK_BOX(face), title);
    gtk_box_append(GTK_BOX(face), body);
    GtkWidget *check = option_check(confirm);
    if (check) {
        gtk_widget_set_margin_top(check, 6);
        gtk_box_append(GTK_BOX(face), check);
        g_object_set_data(G_OBJECT(overlay), "szfriends-option", check);
    }
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(buttons, GTK_ALIGN_END);
    gtk_widget_set_margin_top(buttons, 10);
    GtkWidget *cancel = card_button(confirm->cancel_label, "szfriends.confirmation.cancel", NULL);
    g_signal_connect(cancel, "clicked", G_CALLBACK(card_cancel), dropdown);
    GtkWidget *ok = card_button(confirm->confirm_label, "szfriends.confirmation.confirm",
                                destructive ? "destructive-action" : "suggested-action");
    g_object_set_data(G_OBJECT(ok), "szfriends-card", overlay);
    g_signal_connect(ok, "clicked", G_CALLBACK(card_confirm), dropdown);
    gtk_box_append(GTK_BOX(buttons), cancel);
    gtk_box_append(GTK_BOX(buttons), ok);
    gtk_box_append(GTK_BOX(face), buttons);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), card);
    g_object_set_data_full(G_OBJECT(overlay), "szfriends-question", question, question_free);
    /* Keyboard focus moves into the question, so Escape (the shell's) withdraws it. Return answers it only when
     * nothing is lost: on a destructive question it rests on Cancel, as Settings' dialog defaults to Cancel. */
    g_object_set_data(G_OBJECT(overlay), "szfriends-focus", destructive ? cancel : ok);
    return overlay;
}

static void ask(SZFriendsGtkDropdown *dropdown, GtkWidget *source, const SZFriendsGtkConfirm *confirm,
                gboolean destructive, SZFriendsGtkQuestion *question) {
    destructive = destructive || confirm->destructive;
    if (dropdown) {
        GtkWidget *card = confirm_card(dropdown, confirm, destructive, question);
        szfriends_gtk_dropdown_set_overlay(dropdown, card);
        gtk_widget_grab_focus(g_object_get_data(G_OBJECT(card), "szfriends-focus"));
    } else if (seams.confirm) {
        seams.confirm(source, confirm, destructive, question_answered_cb, question, question_free, seams.data);
    } else {
        system_confirm(source, confirm, destructive, question);
    }
}

void szfriends_gtk_confirm(SZFriendsGtkDropdown *dropdown, GtkWidget *source, const SZFriendsGtkConfirm *confirm,
                           gboolean destructive, SZFriendsGtkRun run, gpointer run_data, GDestroyNotify run_destroy) {
    SZFriendsGtkQuestion *question = g_new0(SZFriendsGtkQuestion, 1);
    *question = (SZFriendsGtkQuestion){.run = run, .data = run_data, .destroy = run_destroy};
    ask(dropdown, source, confirm, destructive, question);
}

void szfriends_gtk_confirm_ticked(SZFriendsGtkDropdown *dropdown, GtkWidget *source,
                                  const SZFriendsGtkConfirm *confirm, gboolean destructive, SZFriendsGtkRunTicked run,
                                  gpointer run_data, GDestroyNotify run_destroy) {
    SZFriendsGtkQuestion *question = g_new0(SZFriendsGtkQuestion, 1);
    *question = (SZFriendsGtkQuestion){.run_ticked = run, .data = run_data, .destroy = run_destroy};
    ask(dropdown, source, confirm, destructive, question);
}

/* ---- Actions ------------------------------------------------------------------------------------- */

/* An intent waiting for its question's answer: it was built when the action was pressed, so it holds its own copy
 * of everything and outlives the snapshot that offered it. */
typedef struct {
    SZFriendsGtkLink *link;
    szfriends_intent *intent, *ticked; /* ticked: what goes when the question's option is ticked; NULL without one */
    SZFriendsGtkRun sending;
    SZFriendsGtkReplyFunc done;
    gpointer done_data;
} SZFriendsGtkPending;

static void pending_free(gpointer data) {
    SZFriendsGtkPending *pending = data;
    /* Cancelled, or the card went with the dropdown: whoever waits hears that nothing was sent. */
    szfriends_intent_free(pending->ticked);
    if (pending->intent) {
        szfriends_intent_free(pending->intent);
        if (pending->done) pending->done(NULL, NULL, pending->done_data);
    }
    szfriends_gtk_link_unref(pending->link);
    g_free(pending);
}

static void pending_send(gboolean ticked, gpointer data) {
    SZFriendsGtkPending *pending = data;
    szfriends_intent *intent = g_steal_pointer(&pending->intent), *other = g_steal_pointer(&pending->ticked);
    if (ticked && other) {
        szfriends_intent *unticked = intent;
        intent = other;
        other = unticked;
    }
    szfriends_intent_free(other);
    if (pending->sending) pending->sending(pending->done_data);
    szfriends_gtk_link_send(pending->link, intent, pending->done, pending->done_data, NULL);
}

void szfriends_gtk_perform(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown, GtkWidget *source,
                           const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids,
                           SZFriendsGtkReplyFunc done, gpointer done_data) {
    szfriends_gtk_perform_sending(link, dropdown, source, action, ids, NULL, done, done_data);
}

void szfriends_gtk_perform_sending(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown, GtkWidget *source,
                                   const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids,
                                   SZFriendsGtkRun sending, SZFriendsGtkReplyFunc done, gpointer done_data) {
    if (!action || !szfriends_gtk_action_is_known(action->action)) {
        if (done) done(NULL, NULL, done_data);
        return;
    }
    if (szfriends_gtk_action_is_client_side(action->action)) {
        const SZFriendsGtkHost *host = szfriends_gtk_link_host(link);
        GtkWindow *window = dropdown ? szfriends_gtk_dropdown_get_window(dropdown) : window_of(source);
        gboolean path = action->path && *action->path;
        if (action->action == SZFRIENDS_GTK_ACTION_OPEN_SETTINGS)
            szfriends_gtk_open_uri(source, szfriends_gtk_settings_uri(action->settings_target));
        else if (action->action == SZFRIENDS_GTK_ACTION_OPEN_FILE && path && host->open_received_file)
            host->open_received_file(host->host_data, window, action->path);
        else if (action->action == SZFRIENDS_GTK_ACTION_SHOW_FILE && path && host->reveal_file)
            host->reveal_file(host->host_data, window, action->path);
        else if (action->action == SZFRIENDS_GTK_ACTION_OPEN_JOIN && dropdown)
            szfriends_gtk_dropdown_open_join(dropdown);
        if (done) done(NULL, NULL, done_data);
        return;
    }
    szfriends_intent *intent = szfriends_gtk_intent_for_action(action, ids);
    if (!intent) {
        if (done) done(NULL, NULL, done_data);
        return;
    }
    if (!action->confirm) {
        if (sending) sending(done_data);
        szfriends_gtk_link_send(link, intent, done, done_data, NULL);
        return;
    }
    SZFriendsGtkPending *pending = g_new0(SZFriendsGtkPending, 1);
    szfriends_gtk_link_ref(link); /* the question can outlive the page that asked it */
    szfriends_intent *ticked = szfriends_gtk_confirm_option_known(action->confirm)
                                   ? szfriends_gtk_intent_for_answer(action, ids, TRUE) : NULL;
    *pending = (SZFriendsGtkPending){link, intent, ticked, sending, done, done_data};
    /* A destructive action's question is drawn destructive too, even from a helper that marks only the action. */
    szfriends_gtk_confirm_ticked(dropdown, source, action->confirm, action->style == SZFRIENDS_GTK_STYLE_DESTRUCTIVE,
                                 pending_send, pending, pending_free);
}

GtkWidget *szfriends_gtk_list_action_button_new(void) {
    GtkWidget *button = gtk_button_new_with_label("");
    gtk_widget_set_visible(button, FALSE);
    return button;
}

gboolean szfriends_gtk_list_action_button_set(GtkWidget *button, const SZFriendsGtkAction *action) {
    gboolean known = action && szfriends_gtk_action_is_known(action->action);
    gtk_widget_set_visible(button, known);
    if (!known) return FALSE;
    gtk_button_set_label(GTK_BUTTON(button), action->label);
    static const char *const styles[] = {"suggested-action", "destructive-action", "flat", "szfriends-link"};
    for (gsize i = 0; i < G_N_ELEMENTS(styles); i++) gtk_widget_remove_css_class(button, styles[i]);
    if (action->style == SZFRIENDS_GTK_STYLE_PRIMARY) gtk_widget_add_css_class(button, "suggested-action");
    if (action->style == SZFRIENDS_GTK_STYLE_DESTRUCTIVE) gtk_widget_add_css_class(button, "destructive-action");
    if (action->style == SZFRIENDS_GTK_STYLE_LINK) {
        gtk_widget_add_css_class(button, "flat");
        gtk_widget_add_css_class(button, "szfriends-link");
    }
    return TRUE;
}

GtkWidget *szfriends_gtk_list_label(const char *css_class) {
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_set_halign(label, GTK_ALIGN_FILL);
    if (css_class) gtk_widget_add_css_class(label, css_class);
    return label;
}

void szfriends_gtk_list_label_set(GtkWidget *label, const char *text) {
    gtk_label_set_text(GTK_LABEL(label), text ? text : ""); /* plain text: these are the helper's or a person's */
    gtk_widget_set_visible(label, text && *text);
}
