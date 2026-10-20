/* The Friends part of the host's Settings, under the host's own "Enable Shenzhen Friends" switch and disclosure
 * (szfriends_gtk_details_page.h; szfriends_gtk_settings_section_new in szfriends_gtk.h). Mirrors
 * mac/SZFriendsSettingsSection.m: the `settings` snapshot as rows of libadwaita preference groups (the name friends
 * see, your ID with Copy, where received files go with Change… and Show, automatic acceptance with a switch per friend, then Delete history and
 * Reset Friends behind their confirmations). The subscription is held only while the section is on screen, and
 * while the helper does not answer the rows keep their last values under the link's status line. */

#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_details_page.h"
#include "gtk/szfriends_gtk_internal.h"

#include <adwaita.h>

typedef struct {
    SZFriendsGtkPage *page;
    guint token, state_watch;
    SZFriendsGtkDetailsHeld *held;
    GtkWidget *status, *group, *danger;
    GtkWidget *name_row, *name_entry, *id_row, *id_value, *copy, *received_row, *received_change, *received_button;
    GtkWidget *auto_row, *change, *history_row, *history_button, *reset_row, *reset_button;
    GPtrArray *friend_rows;
    gboolean editing_name, applying;
} SZFriendsGtkSettings;

static const SZFriendsGtkSettingsSnapshot *shown(SZFriendsGtkSettings *settings) {
    return szfriends_gtk_details_held_value(settings->held);
}

/* Titles and subtitles are plain text: a note can name friends ("From Mei Lin and Daniel Ortiz…"). */
static GtkWidget *plain_row(GType type) {
    GtkWidget *row = g_object_new(type, NULL);
    adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row), FALSE);
    return row;
}

static void set_row(GtkWidget *row, const char *title, const char *subtitle) {
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), title ? title : "");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(row), subtitle ? subtitle : "");
}

static GtkWidget *suffix_button(GtkWidget *row, const char *name, GCallback clicked, gpointer data) {
    GtkWidget *button = gtk_button_new();
    gtk_widget_set_name(button, name);
    gtk_widget_set_valign(button, GTK_ALIGN_CENTER);
    g_signal_connect(button, "clicked", clicked, data);
    adw_action_row_add_suffix(ADW_ACTION_ROW(row), button);
    return button;
}

/* ---- The name ---------------------------------------------------------------------------------------- */

static void commit_name(SZFriendsGtkSettings *settings) {
    const SZFriendsGtkSettingsSnapshot *snapshot = shown(settings);
    szfriends_intent *intent = snapshot ? szfriends_gtk_details_name_intent(
                                              gtk_editable_get_text(GTK_EDITABLE(settings->name_entry)),
                                              snapshot->name.value)
                                        : NULL;
    if (intent) szfriends_gtk_details_send(settings->page, intent, NULL);
}

static void name_activated(GtkEntry *entry, gpointer data) {
    (void)entry;
    commit_name(data);
}

/* Typing is never overwritten by a snapshot; leaving the field commits it, as Return does. */
static void name_entered(GtkEventControllerFocus *focus, gpointer data) {
    (void)focus;
    ((SZFriendsGtkSettings *)data)->editing_name = TRUE;
}

static void name_left(GtkEventControllerFocus *focus, gpointer data) {
    (void)focus;
    SZFriendsGtkSettings *settings = data;
    settings->editing_name = FALSE;
    commit_name(settings);
}

/* ---- Automatic acceptance per friend ------------------------------------------------------------------- */

static void friend_toggled(GObject *row, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    SZFriendsGtkSettings *settings = data;
    const char *conversation = g_object_get_data(row, "szfriends-conversation");
    if (settings->applying || !conversation) return;
    gboolean enabled = adw_switch_row_get_active(ADW_SWITCH_ROW(row));
    szfriends_gtk_details_send(settings->page, szfriends_intent_set_auto_accept(conversation, enabled), NULL);
}

/* One switch per friend under the summary while Choose friends… is pressed. Rows stay when the snapshot names the same
 * friends in the same order, so a switch the person just used keeps its focus. */
static void sync_friends(SZFriendsGtkSettings *settings) {
    const SZFriendsGtkSettingsAutoAccept *automatic = &shown(settings)->auto_accept;
    gboolean showing = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(settings->change));
    gsize n = showing ? automatic->n_friends : 0;
    gboolean same = settings->friend_rows->len == n;
    for (gsize i = 0; same && i < n; i++)
        same = !g_strcmp0(g_object_get_data(settings->friend_rows->pdata[i], "szfriends-conversation"),
                          automatic->friends[i].conversation_id);
    if (!same) {
        for (guint i = 0; i < settings->friend_rows->len; i++)
            adw_preferences_group_remove(ADW_PREFERENCES_GROUP(settings->group), settings->friend_rows->pdata[i]);
        g_ptr_array_set_size(settings->friend_rows, 0);
        for (gsize i = 0; i < n; i++) {
            GtkWidget *row = plain_row(ADW_TYPE_SWITCH_ROW);
            g_object_set_data_full(G_OBJECT(row), "szfriends-conversation",
                                   g_strdup(automatic->friends[i].conversation_id), g_free);
            GtkWidget *avatar = szfriends_gtk_avatar_new(szfriends_gtk_page_get_link(settings->page), 22);
            adw_action_row_add_prefix(ADW_ACTION_ROW(row), avatar);
            g_object_set_data(G_OBJECT(row), "szfriends-avatar", avatar);
            g_signal_connect(row, "notify::active", G_CALLBACK(friend_toggled), settings);
            adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings->group), row);
            g_ptr_array_add(settings->friend_rows, row);
        }
    }
    settings->applying = TRUE;
    for (gsize i = 0; i < n; i++) {
        GtkWidget *row = settings->friend_rows->pdata[i];
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), automatic->friends[i].title);
        adw_switch_row_set_active(ADW_SWITCH_ROW(row), automatic->friends[i].enabled);
        szfriends_gtk_avatar_set(g_object_get_data(G_OBJECT(row), "szfriends-avatar"), &automatic->friends[i].avatar);
    }
    settings->applying = FALSE;
}

static void change_toggled(GtkToggleButton *button, gpointer data) {
    (void)button;
    SZFriendsGtkSettings *settings = data;
    if (settings->held) sync_friends(settings);
}

/* ---- Copy, Show, Delete history and Reset ---------------------------------------------------------------- */

static void copy_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkSettings *settings = data;
    if (settings->held) szfriends_gtk_details_copy(settings->page, GTK_WIDGET(button), shown(settings)->id.friends_id);
}

/* Change…: the folder dialog at the folder shown, then set_received_folder. A folder the helper refuses says why on
 * the status line; the row changes when the next snapshot names the new folder. */
static void folder_set(SZFriendsGtkPage *page, JsonObject *result, const SZFriendsGtkError *error) {
    (void)result;
    SZFriendsGtkSettings *settings = szfriends_gtk_page_get_data(page);
    if (settings) szfriends_gtk_details_label_set(settings->status, error ? error->message : NULL);
}

static void folder_chosen(const char *path, gpointer data) {
    SZFriendsGtkPage *page = data;
    if (path && *path) szfriends_gtk_details_send(page, szfriends_intent_set_received_folder(path), folder_set);
    g_object_unref(szfriends_gtk_page_get_widget(page));
}

static void received_change_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkSettings *settings = data;
    const SZFriendsGtkSettingsSnapshot *snapshot = shown(settings);
    if (!snapshot) return;
    /* The page stays alive until the dialog answers, as a confirmation holds it. */
    g_object_ref(szfriends_gtk_page_get_widget(settings->page));
    szfriends_gtk_choose_folder(GTK_WIDGET(button), snapshot->received.path, folder_chosen, settings->page);
}

/* What a confirmation runs once answered: the section's widget is held so its link stays alive until then. */
typedef struct {
    GtkWidget *widget;
    SZFriendsGtkPage *page;
    gboolean reset;
} SZFriendsGtkSettingsRun;

static void confirmed(gpointer data) {
    SZFriendsGtkSettingsRun *run = data;
    /* Settings offers only the whole history: delete_history without a conversation. Reset carries "reset". */
    szfriends_gtk_details_send(run->page, run->reset ? szfriends_intent_reset_friends()
                                                     : szfriends_intent_delete_history(NULL), NULL);
}

static void run_free(gpointer data) {
    SZFriendsGtkSettingsRun *run = data;
    g_object_unref(run->widget);
    g_free(run);
}

static void ask(SZFriendsGtkSettings *settings, GtkWidget *source, gboolean reset) {
    const SZFriendsGtkSettingsSnapshot *snapshot = shown(settings);
    if (!snapshot) return;
    SZFriendsGtkSettingsRun *run = g_new0(SZFriendsGtkSettingsRun, 1);
    run->widget = g_object_ref(szfriends_gtk_page_get_widget(settings->page));
    run->page = settings->page;
    run->reset = reset;
    const SZFriendsGtkConfirm *confirm = reset ? &snapshot->reset.confirm : &snapshot->history.confirm;
    szfriends_gtk_confirm(szfriends_gtk_page_get_dropdown(settings->page), source, confirm, FALSE, confirmed, run,
                          run_free);
}

static void history_clicked(GtkButton *button, gpointer data) {
    ask(data, GTK_WIDGET(button), FALSE);
}

static void reset_clicked(GtkButton *button, gpointer data) {
    ask(data, GTK_WIDGET(button), TRUE);
}

/* ---- Snapshots and the link's state --------------------------------------------------------------------- */

static void apply(SZFriendsGtkSettings *settings) {
    const SZFriendsGtkSettingsSnapshot *snapshot = shown(settings);
    set_row(settings->name_row, snapshot->name.label, snapshot->name.note);
    if (!settings->editing_name) gtk_editable_set_text(GTK_EDITABLE(settings->name_entry), snapshot->name.value);
    gtk_entry_set_placeholder_text(GTK_ENTRY(settings->name_entry), snapshot->name.placeholder);
    gtk_accessible_update_property(GTK_ACCESSIBLE(settings->name_entry), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   snapshot->name.label, -1);
    set_row(settings->id_row, snapshot->id.label, snapshot->id.note);
    gtk_label_set_text(GTK_LABEL(settings->id_value), snapshot->id.friends_id);
    gtk_button_set_label(GTK_BUTTON(settings->copy), snapshot->id.copy_label);
    /* The folder's name under the label, then the note (empty on a computer, so nothing more shows). */
    const SZFriendsGtkSettingsReceived *received = &snapshot->received;
    char *where = *received->value && *received->note ? g_strdup_printf("%s\n%s", received->value, received->note)
                                                       : g_strdup(*received->value ? received->value : received->note);
    set_row(settings->received_row, received->label, where);
    g_free(where);
    gtk_widget_set_tooltip_text(settings->received_row, received->path);
    const SZFriendsGtkAction *change = received->change;
    gboolean changeable = change && change->action == SZFRIENDS_GTK_ACTION_CHOOSE_RECEIVED_FOLDER;
    gtk_button_set_label(GTK_BUTTON(settings->received_change), changeable ? change->label : "");
    gtk_widget_set_visible(settings->received_change, changeable);
    gtk_widget_set_visible(settings->group, TRUE);
    gtk_widget_set_visible(settings->danger, TRUE);
    /* Show in Finder, or what the helper names for this app's files; an action this view does not know is hidden. */
    if (szfriends_gtk_details_button_matches(settings->received_button, snapshot->received.action, NULL)) {
        /* the same button stays */
    } else if (settings->received_button) {
        adw_action_row_remove(ADW_ACTION_ROW(settings->received_row), settings->received_button);
        settings->received_button = NULL;
    }
    if (!settings->received_button && snapshot->received.action)
        settings->received_button = szfriends_gtk_details_button_new(settings->page, settings->held,
                                                                     snapshot->received.action, NULL);
    if (settings->received_button && !gtk_widget_get_parent(settings->received_button)) {
        gtk_widget_set_name(settings->received_button, "szfriends.settings.received");
        gtk_widget_set_valign(settings->received_button, GTK_ALIGN_CENTER);
        adw_action_row_add_suffix(ADW_ACTION_ROW(settings->received_row), settings->received_button);
    }
    set_row(settings->auto_row, snapshot->auto_accept.label, snapshot->auto_accept.note);
    gtk_button_set_label(GTK_BUTTON(settings->change), snapshot->auto_accept.action_label);
    /* No friends, no switch to show: the row's note says where to turn it on. */
    gboolean choosable = snapshot->auto_accept.n_friends > 0;
    gtk_widget_set_visible(settings->change, choosable);
    if (!choosable) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(settings->change), FALSE);
    set_row(settings->history_row, snapshot->history.label, snapshot->history.note);
    gtk_button_set_label(GTK_BUTTON(settings->history_button), snapshot->history.action_label);
    set_row(settings->reset_row, snapshot->reset.label, snapshot->reset.note);
    gtk_button_set_label(GTK_BUTTON(settings->reset_button), snapshot->reset.action_label);
    sync_friends(settings);
}

static void on_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    SZFriendsGtkSettings *settings = user_data;
    SZFriendsGtkDetailsHeld *previous = settings->held;
    settings->held = szfriends_gtk_details_held_new(&szfriends_gtk_type_settings_snapshot,
                                                    szfriends_gtk_settings_snapshot_parse(data));
    apply(settings);
    szfriends_gtk_details_held_unref(previous);
}

/* While the helper does not answer, this line says why the rows do not change. */
static void state_changed(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    SZFriendsGtkSettings *settings = data;
    const char *text = state == SZFRIENDS_GTK_LINK_READY ? NULL : szfriends_gtk_link_status_text(link);
    szfriends_gtk_details_label_set(settings->status, text);
}

/* ---- The section ----------------------------------------------------------------------------------------- */

static void build(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkSettings *settings = g_new0(SZFriendsGtkSettings, 1);
    settings->page = page;
    settings->friend_rows = g_ptr_array_new();
    szfriends_gtk_page_set_data(page, settings, g_free);
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 24);
    /* The section sits in the host's Settings window, which may open before any Friends button styled the display. */
    szfriends_gtk_style_ensure(gtk_widget_get_display(box), szfriends_gtk_link_host(link));
    szfriends_gtk_list_style_ensure(box);
    settings->status = szfriends_gtk_details_label("szfriends-secondary");
    gtk_box_append(GTK_BOX(box), settings->status);
    settings->group = adw_preferences_group_new();
    settings->name_row = plain_row(ADW_TYPE_ACTION_ROW);
    settings->name_entry = gtk_entry_new();
    gtk_widget_set_name(settings->name_entry, "szfriends.settings.name");
    gtk_widget_set_size_request(settings->name_entry, 220, -1);
    gtk_widget_set_valign(settings->name_entry, GTK_ALIGN_CENTER);
    g_signal_connect(settings->name_entry, "activate", G_CALLBACK(name_activated), settings);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(name_entered), settings);
    g_signal_connect(focus, "leave", G_CALLBACK(name_left), settings);
    gtk_widget_add_controller(settings->name_entry, focus);
    adw_action_row_add_suffix(ADW_ACTION_ROW(settings->name_row), settings->name_entry);
    settings->id_row = plain_row(ADW_TYPE_ACTION_ROW);
    settings->id_value = gtk_label_new(NULL);
    gtk_widget_add_css_class(settings->id_value, "heading");
    adw_action_row_add_suffix(ADW_ACTION_ROW(settings->id_row), settings->id_value);
    settings->copy = suffix_button(settings->id_row, "szfriends.settings.copy", G_CALLBACK(copy_clicked), settings);
    settings->received_row = plain_row(ADW_TYPE_ACTION_ROW);
    settings->received_change = suffix_button(settings->received_row, "szfriends.settings.received_change",
                                              G_CALLBACK(received_change_clicked), settings);
    settings->auto_row = plain_row(ADW_TYPE_ACTION_ROW);
    settings->change = gtk_toggle_button_new();
    gtk_widget_set_name(settings->change, "szfriends.settings.change");
    gtk_widget_set_valign(settings->change, GTK_ALIGN_CENTER);
    g_signal_connect(settings->change, "toggled", G_CALLBACK(change_toggled), settings);
    adw_action_row_add_suffix(ADW_ACTION_ROW(settings->auto_row), settings->change);
    GtkWidget *rows[] = {settings->name_row, settings->id_row, settings->received_row, settings->auto_row};
    for (gsize i = 0; i < G_N_ELEMENTS(rows); i++) adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings->group),
                                                                              rows[i]);
    /* Deleting and starting over apart from everyday settings, as GNOME's own preferences keep them. */
    settings->danger = adw_preferences_group_new();
    settings->history_row = plain_row(ADW_TYPE_ACTION_ROW);
    settings->history_button = suffix_button(settings->history_row, "szfriends.settings.history",
                                             G_CALLBACK(history_clicked), settings);
    settings->reset_row = plain_row(ADW_TYPE_ACTION_ROW);
    settings->reset_button = suffix_button(settings->reset_row, "szfriends.settings.reset", G_CALLBACK(reset_clicked),
                                           settings);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings->danger), settings->history_row);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(settings->danger), settings->reset_row);
    gtk_box_append(GTK_BOX(box), settings->group);
    gtk_box_append(GTK_BOX(box), settings->danger);
    /* Nothing to show until the first snapshot: empty rows would read as settings without names. */
    gtk_widget_set_visible(settings->group, FALSE);
    gtk_widget_set_visible(settings->danger, FALSE);
    settings->state_watch = szfriends_gtk_link_add_state_watch(link, state_changed, settings, NULL);
    state_changed(link, szfriends_gtk_link_get_state(link), settings);
    szfriends_gtk_page_set_content(page, box);
}

static void presented(SZFriendsGtkPage *page, gboolean presented, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkSettings *settings = szfriends_gtk_page_get_data(page);
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    if (presented && !settings->token) {
        settings->token = szfriends_gtk_link_subscribe(link, "settings", NULL, on_snapshot, settings, NULL);
    } else if (!presented && settings->token) {
        szfriends_gtk_link_unsubscribe(link, settings->token);
        settings->token = 0;
    }
}

static void dispose(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkSettings *settings = szfriends_gtk_page_get_data(page);
    szfriends_gtk_link_remove_state_watch(szfriends_gtk_page_get_link(page), settings->state_watch);
    g_ptr_array_unref(settings->friend_rows);
    g_clear_pointer(&settings->held, szfriends_gtk_details_held_unref);
}

void szfriends_gtk_settings_section_register(SZFriendsGtkLink *link) {
    static const SZFriendsGtkPageClass klass = {build, presented, NULL, dispose};
    szfriends_gtk_register_page(link, SZFRIENDS_GTK_PAGE_SETTINGS, &klass, NULL);
}
