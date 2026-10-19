/* What every page shares (szfriends_gtk_list_page.h): the pages' stylesheet; the one table of ways out of the views
 * (clipboard, URIs, the image chooser, Settings' dialog); the one confirmation, a card over the dropdown or a dialog
 * in Settings; running an action; action buttons and plain-text labels. Mirrors mac/SZFriendsContext.m's
 * performAction and the confirmation card of mac/SZFriendsDropdownContent.m. */

#include "gtk/szfriends_gtk_link_private.h"
#include "gtk/szfriends_gtk_list_page.h"

#include <adwaita.h>
#include <string.h>

/* ---- Stylesheet ---------------------------------------------------------------------------------- */

/* The AppKit views' metrics (mac/SZFriendsListPage.m, SZFriendsRowView.m), in the views' colour tokens so a host's
 * appearance_css restyles these too. Colours only through tokens: no media query is needed for dark. Secondary text
 * is @szfriends_secondary_text (.szfriends-secondary, .szfriends-caption), never libadwaita's .dimmed: its 55 %
 * opacity measures 3.2:1 on white, under the 4.5:1 that text of 11 to 13 px needs. */
static const char list_css[] =
    ".szfriends-list-search { margin: 0 6px; }\n"
    ".szfriends-tabs { margin: 2px 12px 8px 12px; }\n"
    ".szfriends-notice { border-radius: 8px; padding: 10px; margin: 0 12px 8px 12px; }\n"
    ".szfriends-notice.send { border: 1.5px dashed alpha(@szfriends_accent, 0.7); }\n"
    ".szfriends-notice.banner { background-color: alpha(@szfriends_warning, 0.14); }\n"
    ".szfriends-notice.prompt { background-color: @szfriends_field_background; }\n"
    ".szfriends-notice-title { font-weight: 600; }\n"
    ".szfriends-caption { font-size: 0.85em; color: @szfriends_secondary_text; }\n"
    ".szfriends-secondary { color: @szfriends_secondary_text; }\n"
    ".szfriends-empty-title { font-weight: 600; }\n"
    "button.szfriends-link { color: @szfriends_accent; font-weight: 600; padding: 2px 4px; min-height: 0; }\n"
    "szfriends-row { border-radius: 8px; margin: 0 6px; padding-right: 8px; }\n"
    "szfriends-row.clickable:hover { background-color: @szfriends_hover; }\n"
    "szfriends-row:focus-visible { outline: 2px solid alpha(@szfriends_accent, 0.5); outline-offset: -2px; }\n"
    "szfriends-row.drop-accept { background-color: @szfriends_selection;\n"
    "  box-shadow: inset 0 0 0 1.5px @szfriends_accent; }\n"
    "szfriends-row.drop-refuse { background-color: alpha(@szfriends_warning, 0.18); }\n"
    "szfriends-row.dimmed .szfriends-row-fade { opacity: 0.4; }\n"
    "szfriends-row.muted szfriends-avatar { opacity: 0.45; }\n"
    "szfriends-row.muted .szfriends-row-title { color: @szfriends_secondary_text; }\n"
    ".szfriends-row-title { font-weight: 600; }\n"
    ".szfriends-row-subtitle, .szfriends-row-status { color: @szfriends_secondary_text; }\n"
    ".szfriends-row-subtitle.waiting { color: @szfriends_accent; }\n"
    ".szfriends-row-time { color: @szfriends_secondary_text; font-size: 0.85em; }\n"
    ".szfriends-row-bar { background-color: @szfriends_accent; border-radius: 2px; min-width: 3px; }\n"
    ".szfriends-row-dot { background-color: @szfriends_accent; border-radius: 4px; min-width: 7px;\n"
    "  min-height: 7px; }\n"
    ".szfriends-pill { background-color: @szfriends_accent; color: @szfriends_background; font-weight: bold;\n"
    "  font-size: 10px; border-radius: 4px; padding: 1px 5px; }\n"
    ".szfriends-pill.drop { font-size: 12px; padding: 2px 5px; }\n"
    ".szfriends-pill.warning { background-color: @szfriends_warning; }\n"
    ".szfriends-route { color: @szfriends_offline_route; }\n"
    ".szfriends-route.local { color: @szfriends_local_route; }\n"
    ".szfriends-route.online { color: @szfriends_online_route; }\n"
    ".szfriends-id-check { color: @szfriends_success; }\n"
    "button.szfriends-row-action { min-width: 28px; min-height: 28px; padding: 0; border-radius: 14px;\n"
    "  background: none; box-shadow: none; color: @szfriends_text; }\n"
    "button.szfriends-row-action:hover { background-color: @szfriends_hover; }\n"
    "button.szfriends-row-action.accept { color: @szfriends_success; }\n"
    "button.szfriends-row-action.block, button.szfriends-row-action.armed { color: @szfriends_destructive; }\n"
    "button.szfriends-row-action.armed { padding: 0 10px 0 8px; font-weight: bold; font-size: 12px;\n"
    "  background-color: mix(@szfriends_background, @szfriends_destructive, 0.12);\n"
    "  box-shadow: inset 0 0 0 1px alpha(@szfriends_destructive, 0.6); }\n"
    ".szfriends-footer { border-top: 1px solid @szfriends_separator; padding: 10px 12px; }\n"
    "button.szfriends-footer-button { padding: 2px 6px; min-height: 0; }\n"
    "button.szfriends-footer-button label { font-weight: normal; }\n"
    "button.szfriends-footer-button label.szfriends-footer-name { font-weight: 600; }\n"
    ".szfriends-visibility.visible { background-color: alpha(@szfriends_accent, 0.12); border-radius: 8px;\n"
    "  border: 1px solid alpha(@szfriends_accent, 0.45); padding: 12px; }\n"
    ".szfriends-countdown { font-size: 20px; font-weight: 600; font-feature-settings: \"tnum\"; }\n"
    ".szfriends-alert { background-color: alpha(@szfriends_warning, 0.14); border-radius: 8px;\n"
    "  border: 1px solid alpha(@szfriends_warning, 0.45); padding: 12px; }\n"
    ".szfriends-people-header { font-weight: 600; font-size: 0.85em; color: @szfriends_secondary_text; }\n"
    ".szfriends-confirm { margin: 0 16px; }\n"
    /* Several computers: a join request waits for the person like a request row; its code is read digit by digit. */
    ".szfriends-join-request { background-color: alpha(@szfriends_accent, 0.08); border-radius: 10px;\n"
    "  border: 1px solid alpha(@szfriends_accent, 0.5); padding: 12px; margin: 0 12px 8px 12px; }\n"
    ".szfriends-join-code { font-size: 28px; font-weight: 600; font-feature-settings: \"tnum\"; }\n"
    ".szfriends-device-dot { border-radius: 5px; min-width: 8px; min-height: 8px;\n"
    "  border: 1px solid @szfriends_secondary_text; }\n"
    ".szfriends-device-dot.connected { background-color: @szfriends_success; border-color: @szfriends_success; }\n"
    ".szfriends-confirm-face { padding: 16px; }\n"
    /* Text actions (Remove friend, Block, Use your own picture) start where the column's words start, as AppKit
     * draws them: no side padding, so their notes need no indent to sit under them. Armed, a pill gets its padding
     * back with its fill. */
    "button.flat.szfriends-text-action { padding-left: 0; padding-right: 0; min-width: 0; }\n";

void szfriends_gtk_list_style_ensure(GtkWidget *widget) {
    GdkDisplay *display = widget ? gtk_widget_get_display(widget) : gdk_display_get_default();
    if (!display || g_object_get_data(G_OBJECT(display), "szfriends-list-style")) return;
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, list_css);
    /* The views' priority: the host's provider (one above) still redefines the tokens these rules use. */
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_set_data_full(G_OBJECT(display), "szfriends-list-style", provider, g_object_unref);
}

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
    if (taken.run) taken.run(taken.data);
    if (taken.destroy) taken.destroy(taken.data);
}

static void question_answered_cb(gpointer data) {
    question_answered(data);
}

static void alert_response(AdwAlertDialog *dialog, const char *response, gpointer data) {
    (void)dialog;
    if (!g_strcmp0(response, "confirm")) question_answered(data);
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

void szfriends_gtk_confirm(SZFriendsGtkDropdown *dropdown, GtkWidget *source, const SZFriendsGtkConfirm *confirm,
                           gboolean destructive, SZFriendsGtkRun run, gpointer run_data, GDestroyNotify run_destroy) {
    SZFriendsGtkQuestion *question = g_new0(SZFriendsGtkQuestion, 1);
    *question = (SZFriendsGtkQuestion){run, run_data, run_destroy};
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

/* ---- Actions ------------------------------------------------------------------------------------- */

/* An intent waiting for its question's answer: it was built when the action was pressed, so it holds its own copy
 * of everything and outlives the snapshot that offered it. */
typedef struct {
    SZFriendsGtkLink *link;
    szfriends_intent *intent;
    SZFriendsGtkReplyFunc done;
    gpointer done_data;
} SZFriendsGtkPending;

static void pending_free(gpointer data) {
    SZFriendsGtkPending *pending = data;
    /* Cancelled, or the card went with the dropdown: whoever waits hears that nothing was sent. */
    if (pending->intent) {
        szfriends_intent_free(pending->intent);
        if (pending->done) pending->done(NULL, NULL, pending->done_data);
    }
    szfriends_gtk_link_unref(pending->link);
    g_free(pending);
}

static void pending_send(gpointer data) {
    SZFriendsGtkPending *pending = data;
    szfriends_gtk_link_send(pending->link, g_steal_pointer(&pending->intent), pending->done, pending->done_data, NULL);
}

void szfriends_gtk_perform(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown, GtkWidget *source,
                           const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids,
                           SZFriendsGtkReplyFunc done, gpointer done_data) {
    if (!action || !szfriends_gtk_action_is_known(action->action)) return;
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
        if (done) done(NULL, NULL, done_data);
        return;
    }
    szfriends_intent *intent = szfriends_gtk_intent_for_action(action, ids);
    if (!intent) return;
    if (!action->confirm) {
        szfriends_gtk_link_send(link, intent, done, done_data, NULL);
        return;
    }
    SZFriendsGtkPending *pending = g_new0(SZFriendsGtkPending, 1);
    szfriends_gtk_link_ref(link); /* the question can outlive the page that asked it */
    *pending = (SZFriendsGtkPending){link, intent, done, done_data};
    /* A destructive action's question is drawn destructive too, even from a helper that marks only the action. */
    szfriends_gtk_confirm(dropdown, source, action->confirm, action->style == SZFRIENDS_GTK_STYLE_DESTRUCTIVE,
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
