/* The join page (szfriends_gtk_devices.h; PROTOCOL.md § Joining, snapshot.join). Mirrors mac/SZFriendsJoinPage.m: a
 * new computer asks to use the person's existing profile by its Friends ID, then types the code one of the person's
 * other computers shows. */

#include "gtk/szfriends_gtk_devices.h"
#include "gtk/szfriends_gtk_internal.h"

#include <adwaita.h>

#include <string.h>

typedef struct {
    SZFriendsGtkPage *page;
    SZFriendsGtkJoinParts parts;
    SZFriendsGtkJoinSnapshot *join; /* the latest; the action buttons point into it */
    char *reply_error;              /* a refused intent's words, until the state changes */
    guint token;
} SZFriendsGtkJoinPage;

static SZFriendsGtkJoinPage *join_of(SZFriendsGtkPage *page) {
    return page && szfriends_gtk_page_get_kind(page) == SZFRIENDS_GTK_PAGE_JOIN ? szfriends_gtk_page_get_data(page)
                                                                                 : NULL;
}

static void show_error(SZFriendsGtkJoinPage *join, const char *text, gboolean announce) {
    szfriends_gtk_details_label_set(join->parts.error, text);
    if (announce) szfriends_gtk_details_announce(join->parts.error, text);
}

/* A refused join_profile, enter_join_code or action says why where the error shows; the buttons work again. */
static void replied_on_page(SZFriendsGtkPage *page, JsonObject *result, const SZFriendsGtkError *error) {
    (void)result;
    SZFriendsGtkJoinPage *join = join_of(page);
    if (!join) return;
    gtk_widget_set_sensitive(join->parts.id_button, TRUE);
    gtk_widget_set_sensitive(join->parts.code_button, !join->join || !join->join->code_field ||
                                                          join->join->code_field->enabled);
    if (!error || !error->message || !*error->message) return;
    g_free(join->reply_error);
    join->reply_error = g_strdup(error->message);
    show_error(join, join->reply_error, TRUE);
}

static void action_replied(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    GWeakRef *ref = data;
    GtkWidget *widget = g_weak_ref_get(ref);
    SZFriendsGtkPage *page = szfriends_gtk_page_from_widget(widget);
    if (page && (result || error)) replied_on_page(page, result, error);
    if (widget) g_object_unref(widget);
    g_weak_ref_clear(ref);
    g_free(ref);
}

static void action_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkJoinPage *join = data;
    const SZFriendsGtkAction *action = g_object_get_data(G_OBJECT(button), "szfriends-action");
    if (!action) return;
    GWeakRef *ref = g_new0(GWeakRef, 1);
    g_weak_ref_init(ref, szfriends_gtk_page_get_widget(join->page));
    szfriends_gtk_perform(szfriends_gtk_page_get_link(join->page), szfriends_gtk_page_get_dropdown(join->page),
                          GTK_WIDGET(button), action, NULL, action_replied, ref); /* the reply frees `ref` */
}

static char *typed(GtkWidget *entry) {
    return g_strstrip(g_strdup(gtk_editable_get_text(GTK_EDITABLE(entry))));
}

void szfriends_gtk_join_page_submit_id(SZFriendsGtkPage *page) {
    SZFriendsGtkJoinPage *join = join_of(page);
    if (!join || !gtk_widget_get_visible(join->parts.id_entry)) return;
    char *id = typed(join->parts.id_entry);
    /* The button rests until the reply, so a double press asks once; the snapshot before it shows what follows. */
    if (*id) {
        gtk_widget_set_sensitive(join->parts.id_button, FALSE);
        szfriends_gtk_details_send(page, szfriends_intent_join_profile(id), replied_on_page);
    }
    g_free(id);
}

void szfriends_gtk_join_page_submit_code(SZFriendsGtkPage *page) {
    SZFriendsGtkJoinPage *join = join_of(page);
    if (!join || !gtk_widget_get_visible(join->parts.code_entry) || !gtk_widget_get_sensitive(join->parts.code_entry))
        return;
    char *code = typed(join->parts.code_entry);
    if (*code) {
        gtk_widget_set_sensitive(join->parts.code_button, FALSE);
        szfriends_gtk_details_send(page, szfriends_intent_enter_join_code(code), replied_on_page);
    }
    g_free(code);
}

static void id_activated(GtkWidget *widget, gpointer data) {
    (void)widget;
    szfriends_gtk_join_page_submit_id(((SZFriendsGtkJoinPage *)data)->page);
}

static void code_activated(GtkWidget *widget, gpointer data) {
    (void)widget;
    szfriends_gtk_join_page_submit_code(((SZFriendsGtkJoinPage *)data)->page);
}

static void apply(SZFriendsGtkJoinPage *join, SZFriendsGtkJoinSnapshot *snapshot) {
    SZFriendsGtkJoinParts *parts = &join->parts;
    SZFriendsGtkJoinState previous = join->join ? join->join->state : SZFRIENDS_GTK_JOIN_UNKNOWN;
    gboolean code_was_shown = gtk_widget_get_visible(parts->code_entry);
    if (previous != snapshot->state) g_clear_pointer(&join->reply_error, g_free);
    szfriends_gtk_details_label_set(parts->title, snapshot->title);
    szfriends_gtk_details_label_set(parts->message, snapshot->message);
    szfriends_gtk_page_set_name(join->page, snapshot->title);
    const SZFriendsGtkJoinIdField *id_field = snapshot->id_field;
    gtk_widget_set_visible(parts->id_entry, id_field != NULL);
    gtk_widget_set_visible(parts->id_button, id_field != NULL);
    gtk_entry_set_placeholder_text(GTK_ENTRY(parts->id_entry), id_field ? id_field->placeholder : NULL);
    if (id_field) {
        gtk_button_set_label(GTK_BUTTON(parts->id_button), id_field->button);
        gtk_accessible_update_property(GTK_ACCESSIBLE(parts->id_entry), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                       id_field->placeholder, -1);
    }
    const SZFriendsGtkJoinCodeField *code = snapshot->code_field;
    /* A new code field starts empty; a wrong code empties it for the next try. */
    if ((code && !code_was_shown) || (snapshot->error && g_strcmp0(snapshot->error, join->join ? join->join->error
                                                                                                 : NULL)))
        gtk_editable_set_text(GTK_EDITABLE(parts->code_entry), "");
    gtk_widget_set_visible(parts->code_entry, code != NULL);
    gtk_widget_set_visible(parts->code_button, code != NULL);
    gtk_entry_set_placeholder_text(GTK_ENTRY(parts->code_entry), code ? code->placeholder : NULL);
    gtk_widget_set_sensitive(parts->code_entry, code && code->enabled);
    gtk_widget_set_sensitive(parts->code_button, code && code->enabled);
    if (code) {
        gtk_button_set_label(GTK_BUTTON(parts->code_button), code->button);
        gtk_accessible_update_property(GTK_ACCESSIBLE(parts->code_entry), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                       code->placeholder, -1);
    }
    gboolean new_error = snapshot->error && g_strcmp0(snapshot->error, join->join ? join->join->error : NULL);
    show_error(join, snapshot->error ? snapshot->error : join->reply_error, new_error);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(parts->actions))) gtk_box_remove(GTK_BOX(parts->actions), child);
    for (gsize i = 0; i < snapshot->n_actions; i++) {
        const SZFriendsGtkAction *action = &snapshot->actions[i];
        if (!szfriends_gtk_action_is_known(action->action) || !*action->label) continue;
        GtkWidget *button = gtk_button_new_with_label(action->label);
        gtk_widget_set_name(button, "szfriends.join.action");
        gtk_widget_set_size_request(button, 96, -1);
        if (action->style == SZFRIENDS_GTK_STYLE_PRIMARY) gtk_widget_add_css_class(button, "suggested-action");
        g_object_set_data(G_OBJECT(button), "szfriends-action", (gpointer)action);
        g_signal_connect(button, "clicked", G_CALLBACK(action_clicked), join);
        gtk_box_append(GTK_BOX(parts->actions), button);
    }
    gtk_widget_set_visible(parts->actions, gtk_widget_get_first_child(parts->actions) != NULL);
    if (join->join) szfriends_gtk_join_snapshot_free(join->join);
    join->join = snapshot; /* after the buttons: the old ones pointed into it and are gone */
    parts->snapshots++;
}

static void on_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    apply(user_data, szfriends_gtk_join_snapshot_parse(data));
}

static GtkWidget *centered(GtkWidget *label) {
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    gtk_label_set_xalign(GTK_LABEL(label), 0.5f);
    return label;
}

static void join_free(gpointer data) {
    SZFriendsGtkJoinPage *join = data;
    if (join->join) szfriends_gtk_join_snapshot_free(join->join);
    g_free(join->reply_error);
    g_free(join);
}

static void build(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkJoinPage *join = g_new0(SZFriendsGtkJoinPage, 1);
    join->page = page;
    szfriends_gtk_page_set_data(page, join, join_free);
    szfriends_gtk_list_style_ensure(szfriends_gtk_page_get_widget(page));
    SZFriendsGtkJoinParts *parts = &join->parts;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(box, 20);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_valign(box, GTK_ALIGN_START);
    parts->title = centered(szfriends_gtk_details_label("title-3"));
    parts->message = centered(szfriends_gtk_details_label("szfriends-secondary"));
    GtkWidget *id_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(id_row, 8);
    parts->id_entry = gtk_entry_new();
    gtk_widget_set_name(parts->id_entry, "szfriends.join.id");
    gtk_widget_set_hexpand(parts->id_entry, TRUE);
    g_signal_connect(parts->id_entry, "activate", G_CALLBACK(id_activated), join);
    parts->id_button = gtk_button_new_with_label("");
    gtk_widget_add_css_class(parts->id_button, "suggested-action");
    g_signal_connect(parts->id_button, "clicked", G_CALLBACK(id_activated), join);
    gtk_box_append(GTK_BOX(id_row), parts->id_entry);
    gtk_box_append(GTK_BOX(id_row), parts->id_button);
    /* The code is read off the other screen digit by digit: large tabular digits, centred. */
    parts->code_entry = gtk_entry_new();
    gtk_widget_set_name(parts->code_entry, "szfriends.join.code");
    gtk_widget_add_css_class(parts->code_entry, "szfriends-join-code");
    gtk_entry_set_alignment(GTK_ENTRY(parts->code_entry), 0.5f);
    gtk_entry_set_input_purpose(GTK_ENTRY(parts->code_entry), GTK_INPUT_PURPOSE_DIGITS);
    gtk_widget_set_margin_top(parts->code_entry, 8);
    g_signal_connect(parts->code_entry, "activate", G_CALLBACK(code_activated), join);
    parts->code_button = gtk_button_new_with_label("");
    gtk_widget_add_css_class(parts->code_button, "suggested-action");
    gtk_widget_set_halign(parts->code_button, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(parts->code_button, 120, -1);
    g_signal_connect(parts->code_button, "clicked", G_CALLBACK(code_activated), join);
    for (GtkWidget **field = (GtkWidget *[]){parts->id_entry, parts->id_button, parts->code_entry,
                                            parts->code_button, NULL};
         *field; field++)
        gtk_widget_set_visible(*field, FALSE);
    parts->error = centered(szfriends_gtk_details_label("error"));
    gtk_widget_set_name(parts->error, "szfriends.join.error");
    parts->actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(parts->actions, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(parts->actions, 8);
    gtk_widget_set_visible(parts->actions, FALSE);
    for (GtkWidget **child = (GtkWidget *[]){parts->title, parts->message, id_row, parts->code_entry,
                                            parts->code_button, parts->error, parts->actions, NULL};
         *child; child++)
        gtk_box_append(GTK_BOX(box), *child);
    /* One readable column whatever width the host gives the dropdown: the full width up to the dropdown's own
     * 400 points, centred and no wider past it, so the code field stays the size of a code. */
    GtkWidget *clamp = adw_clamp_new();
    adw_clamp_set_maximum_size(ADW_CLAMP(clamp), SZFRIENDS_GTK_JOIN_COLUMN);
    adw_clamp_set_tightening_threshold(ADW_CLAMP(clamp), SZFRIENDS_GTK_JOIN_COLUMN);
    adw_clamp_set_unit(ADW_CLAMP(clamp), ADW_LENGTH_UNIT_PX); /* the dropdown's own unit; sp grows with the font */
    gtk_widget_set_valign(clamp, GTK_ALIGN_START);
    adw_clamp_set_child(ADW_CLAMP(clamp), box);
    szfriends_gtk_page_set_content(page, clamp);
}

static void presented(SZFriendsGtkPage *page, gboolean presented, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkJoinPage *join = join_of(page);
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    if (!join) return;
    if (presented && !join->token) {
        join->token = szfriends_gtk_link_subscribe(link, "join", NULL, on_snapshot, join, NULL);
        gtk_widget_grab_focus(join->parts.id_entry);
    } else if (!presented && join->token) {
        szfriends_gtk_link_unsubscribe(link, join->token);
        join->token = 0;
    }
}

void szfriends_gtk_join_page_register(SZFriendsGtkLink *link) {
    static const SZFriendsGtkPageClass klass = {build, presented, NULL, NULL};
    szfriends_gtk_register_page(link, SZFRIENDS_GTK_PAGE_JOIN, &klass, NULL);
}

const SZFriendsGtkJoinParts *szfriends_gtk_join_page_parts(SZFriendsGtkPage *page) {
    SZFriendsGtkJoinPage *join = join_of(page);
    return join ? &join->parts : NULL;
}
