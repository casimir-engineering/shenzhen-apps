/* The Nearby tab (szfriends_gtk_list_page.h; mirrors mac/SZFriendsNearbyPane.m): the visibility card, the one alert
 * or quiet note, and people as each method reports them.
 *
 * While visible the helper sends a snapshot every second for the countdown, so everything here is created once and
 * updated in place, rows are reused by position, and buttons keep their hover and focus across the ticks. Each
 * method's own state is the people header's tooltip: the alert and the note already say what matters, and say it
 * as the helper wrote it, distinguishing searching, nobody visible and each unavailable method. */

#include "gtk/szfriends_gtk_glyphs.h"
#include "gtk/szfriends_gtk_list_page.h"

typedef struct {
    SZFriendsGtkNearbyParts parts;
    SZFriendsGtkLink *link;
    SZFriendsGtkDropdown *dropdown;
    GtkWidget *box, *visibility_top, *visibility_side, *side, *people_box, *header;
    SZFriendsGtkNearbySnapshot *snapshot;
} SZFriendsGtkNearbyPane;

static SZFriendsGtkNearbyPane *pane_of(GtkWidget *box) {
    return box ? g_object_get_data(G_OBJECT(box), "szfriends-nearby") : NULL;
}

static void perform(SZFriendsGtkNearbyPane *pane, GtkWidget *source, const SZFriendsGtkAction *action,
                    const SZFriendsGtkActionIds *ids) {
    szfriends_gtk_perform(pane->link, pane->dropdown, source, action, ids, NULL, NULL);
}

static void visibility_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkNearbyPane *pane = data;
    if (pane->snapshot) perform(pane, GTK_WIDGET(button), pane->snapshot->visibility.action, NULL);
}

static void alert_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkNearbyPane *pane = data;
    if (pane->snapshot && pane->snapshot->alert) perform(pane, GTK_WIDGET(button), pane->snapshot->alert->action, NULL);
}

static void note_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkNearbyPane *pane = data;
    if (pane->snapshot && pane->snapshot->note) perform(pane, GTK_WIDGET(button), pane->snapshot->note->action, NULL);
}

static const SZFriendsGtkNearbyPerson *person_for(SZFriendsGtkNearbyPane *pane, GtkWidget *row) {
    for (guint i = 0; pane->snapshot && i < pane->parts.rows->len && i < pane->snapshot->n_people; i++)
        if (g_ptr_array_index(pane->parts.rows, i) == row) return &pane->snapshot->people[i];
    return NULL;
}

static void person_activated(GtkWidget *row, gpointer data) {
    SZFriendsGtkNearbyPane *pane = data;
    const char *conversation_id = szfriends_gtk_row_get_conversation_id(row);
    if (conversation_id && pane->dropdown) szfriends_gtk_dropdown_open_conversation(pane->dropdown, conversation_id,
                                                                                    NULL);
}

static void person_request(GtkWidget *row, gpointer data) {
    SZFriendsGtkNearbyPane *pane = data;
    const SZFriendsGtkNearbyPerson *person = person_for(pane, row);
    if (!person) return;
    SZFriendsGtkActionIds ids = {.nearby_id = person->nearby_id};
    perform(pane, row, person->action, &ids);
}

/* ---- Applying a snapshot ------------------------------------------------------------------------- */

static void apply_visibility(SZFriendsGtkNearbyPane *pane, const SZFriendsGtkVisibility *visibility) {
    SZFriendsGtkNearbyParts *parts = &pane->parts;
    gboolean visible = visibility->state == SZFRIENDS_GTK_VISIBILITY_VISIBLE;
    szfriends_gtk_list_label_set(parts->visibility_title, visibility->title);
    szfriends_gtk_list_label_set(parts->visibility_body, visibility->body);
    /* Visible: the countdown card, remaining time large over Stop. Otherwise the full-width action first, then
     * what it does under it. Two buttons, one shown, so neither moves between parents every second. */
    if (visible) gtk_widget_add_css_class(parts->visibility, "visible");
    else gtk_widget_remove_css_class(parts->visibility, "visible");
    gboolean side = szfriends_gtk_list_action_button_set(pane->visibility_side, visible ? visibility->action : NULL);
    gboolean top = szfriends_gtk_list_action_button_set(pane->visibility_top, visible ? NULL : visibility->action);
    parts->visibility_button = side ? pane->visibility_side : top ? pane->visibility_top : NULL;
    szfriends_gtk_list_label_set(parts->countdown, visible ? visibility->remaining_label : NULL);
    const char *spoken = visibility->remaining_accessibility_label;
    if (visible && spoken && *spoken)
        gtk_accessible_update_property(GTK_ACCESSIBLE(parts->countdown), GTK_ACCESSIBLE_PROPERTY_LABEL, spoken, -1);
    gtk_widget_set_visible(pane->side, visible);
}

static void apply_people(SZFriendsGtkNearbyPane *pane, const SZFriendsGtkNearbySnapshot *snapshot) {
    GPtrArray *rows = pane->parts.rows;
    while (rows->len > snapshot->n_people) {
        gtk_box_remove(GTK_BOX(pane->people_box), g_ptr_array_index(rows, rows->len - 1));
        g_ptr_array_remove_index(rows, rows->len - 1);
    }
    static const SZFriendsGtkRowHandlers handlers = {person_activated, NULL, NULL, person_request};
    while (rows->len < snapshot->n_people) {
        GtkWidget *row = szfriends_gtk_row_new(pane->link);
        szfriends_gtk_row_set_handlers(row, &handlers, pane);
        gtk_box_append(GTK_BOX(pane->people_box), row);
        g_ptr_array_add(rows, row);
    }
    for (gsize i = 0; i < snapshot->n_people; i++)
        szfriends_gtk_row_set_nearby_person(g_ptr_array_index(rows, i), &snapshot->people[i]);
}

static void apply_header(SZFriendsGtkNearbyPane *pane, const SZFriendsGtkNearbySnapshot *snapshot) {
    SZFriendsGtkNearbyParts *parts = &pane->parts;
    gtk_label_set_text(GTK_LABEL(parts->people_label), szfriends_gtk_link_string(pane->link, "people_nearby"));
    gtk_widget_set_visible(parts->status, snapshot->status != NULL);
    gtk_label_set_text(GTK_LABEL(parts->status_label), snapshot->status ? snapshot->status->label : "");
    GString *methods = g_string_new(NULL);
    for (gsize i = 0; i < snapshot->n_methods; i++) {
        const char *label = snapshot->methods[i].label;
        if (!label || !*label) continue;
        if (methods->len) g_string_append_c(methods, '\n');
        g_string_append(methods, label);
    }
    gtk_widget_set_tooltip_text(pane->header, methods->len ? methods->str : NULL);
    g_string_free(methods, TRUE);
}

void szfriends_gtk_nearby_pane_apply(GtkWidget *box, SZFriendsGtkNearbySnapshot *snapshot) {
    SZFriendsGtkNearbyPane *pane = pane_of(box);
    if (!pane || !snapshot) {
        if (snapshot) szfriends_gtk_nearby_snapshot_free(snapshot);
        return;
    }
    if (pane->snapshot) szfriends_gtk_nearby_snapshot_free(pane->snapshot);
    pane->snapshot = snapshot;
    SZFriendsGtkNearbyParts *parts = &pane->parts;
    apply_visibility(pane, &snapshot->visibility);
    const SZFriendsGtkAlert *alert = snapshot->alert;
    gtk_widget_set_visible(parts->alert, alert != NULL);
    szfriends_gtk_list_label_set(parts->alert_title, alert ? alert->title : NULL);
    szfriends_gtk_list_label_set(parts->alert_body, alert ? alert->body : NULL);
    szfriends_gtk_list_action_button_set(parts->alert_button, alert ? alert->action : NULL);
    const SZFriendsGtkNote *note = snapshot->note;
    gtk_widget_set_visible(parts->note, note != NULL);
    szfriends_gtk_list_label_set(parts->note_text, note ? note->text : NULL);
    szfriends_gtk_list_action_button_set(parts->note_button, note ? note->action : NULL);
    apply_header(pane, snapshot);
    apply_people(pane, snapshot);
    const SZFriendsGtkEmpty *empty = snapshot->empty;
    gtk_widget_set_visible(parts->empty, empty != NULL);
    gtk_widget_set_visible(parts->empty_glyph, empty && empty->kind == SZFRIENDS_GTK_EMPTY_SEARCHING);
    szfriends_gtk_list_label_set(parts->empty_title, empty ? empty->title : NULL);
    szfriends_gtk_list_label_set(parts->empty_body, empty ? empty->body : NULL);
}

/* ---- Construction -------------------------------------------------------------------------------- */

static GtkWidget *centred(GtkWidget *label) {
    gtk_label_set_xalign(GTK_LABEL(label), 0.5f);
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    return label;
}

static void build_visibility(SZFriendsGtkNearbyPane *pane) {
    SZFriendsGtkNearbyParts *parts = &pane->parts;
    parts->visibility = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(parts->visibility, "szfriends-visibility");
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_hexpand(text, TRUE);
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER);
    pane->visibility_top = szfriends_gtk_list_action_button_new();
    gtk_widget_set_margin_bottom(pane->visibility_top, 6);
    parts->visibility_title = szfriends_gtk_list_label("szfriends-notice-title");
    parts->visibility_body = szfriends_gtk_list_label("szfriends-secondary");
    gtk_box_append(GTK_BOX(text), pane->visibility_top);
    gtk_box_append(GTK_BOX(text), parts->visibility_title);
    gtk_box_append(GTK_BOX(text), parts->visibility_body);
    pane->side = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_valign(pane->side, GTK_ALIGN_CENTER);
    parts->countdown = centred(gtk_label_new(NULL));
    gtk_widget_add_css_class(parts->countdown, "szfriends-countdown");
    pane->visibility_side = szfriends_gtk_list_action_button_new();
    gtk_box_append(GTK_BOX(pane->side), parts->countdown);
    gtk_box_append(GTK_BOX(pane->side), pane->visibility_side);
    gtk_box_append(GTK_BOX(parts->visibility), text);
    gtk_box_append(GTK_BOX(parts->visibility), pane->side);
    g_signal_connect(pane->visibility_top, "clicked", G_CALLBACK(visibility_clicked), pane);
    g_signal_connect(pane->visibility_side, "clicked", G_CALLBACK(visibility_clicked), pane);
}

static void build_cards(SZFriendsGtkNearbyPane *pane) {
    SZFriendsGtkNearbyParts *parts = &pane->parts;
    parts->alert = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(parts->alert, "szfriends-alert");
    parts->alert_title = szfriends_gtk_list_label("szfriends-notice-title");
    parts->alert_body = szfriends_gtk_list_label("szfriends-secondary");
    parts->alert_button = szfriends_gtk_list_action_button_new();
    gtk_widget_set_halign(parts->alert_button, GTK_ALIGN_START);
    gtk_widget_set_margin_top(parts->alert_button, 6);
    g_signal_connect(parts->alert_button, "clicked", G_CALLBACK(alert_clicked), pane);
    gtk_box_append(GTK_BOX(parts->alert), parts->alert_title);
    gtk_box_append(GTK_BOX(parts->alert), parts->alert_body);
    gtk_box_append(GTK_BOX(parts->alert), parts->alert_button);
    parts->note = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *info = szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_INFO, 16);
    gtk_widget_set_valign(info, GTK_ALIGN_START);
    gtk_widget_add_css_class(info, "szfriends-secondary");
    GtkWidget *note_text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(note_text, TRUE);
    parts->note_text = szfriends_gtk_list_label(NULL);
    parts->note_button = szfriends_gtk_list_action_button_new();
    gtk_widget_set_halign(parts->note_button, GTK_ALIGN_START);
    g_signal_connect(parts->note_button, "clicked", G_CALLBACK(note_clicked), pane);
    gtk_box_append(GTK_BOX(note_text), parts->note_text);
    gtk_box_append(GTK_BOX(note_text), parts->note_button);
    gtk_box_append(GTK_BOX(parts->note), info);
    gtk_box_append(GTK_BOX(parts->note), note_text);
}

static void build_people(SZFriendsGtkNearbyPane *pane) {
    SZFriendsGtkNearbyParts *parts = &pane->parts;
    pane->header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_set_margin_start(pane->header, 18);
    gtk_widget_set_margin_end(pane->header, 18);
    gtk_widget_set_margin_top(pane->header, 4);
    parts->people_label = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(parts->people_label), 0);
    gtk_widget_set_hexpand(parts->people_label, TRUE);
    gtk_widget_add_css_class(parts->people_label, "szfriends-people-header");
    parts->status = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *arc = szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_ARC, 11);
    parts->status_label = gtk_label_new(NULL);
    gtk_widget_add_css_class(arc, "szfriends-secondary");
    gtk_widget_add_css_class(parts->status_label, "szfriends-caption");
    gtk_box_append(GTK_BOX(parts->status), arc);
    gtk_box_append(GTK_BOX(parts->status), parts->status_label);
    gtk_box_append(GTK_BOX(pane->header), parts->people_label);
    gtk_box_append(GTK_BOX(pane->header), parts->status);
    pane->people_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    parts->rows = g_ptr_array_new();
    parts->empty = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_top(parts->empty, 16);
    gtk_widget_set_margin_start(parts->empty, 40);
    gtk_widget_set_margin_end(parts->empty, 40);
    parts->empty_glyph = szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_ARC, 22);
    gtk_widget_add_css_class(parts->empty_glyph, "szfriends-secondary");
    gtk_widget_set_margin_bottom(parts->empty_glyph, 6);
    parts->empty_title = centred(szfriends_gtk_list_label("szfriends-empty-title"));
    parts->empty_body = centred(szfriends_gtk_list_label("szfriends-secondary"));
    gtk_box_append(GTK_BOX(parts->empty), parts->empty_glyph);
    gtk_box_append(GTK_BOX(parts->empty), parts->empty_title);
    gtk_box_append(GTK_BOX(parts->empty), parts->empty_body);
}

static void pane_free(gpointer data) {
    SZFriendsGtkNearbyPane *pane = data;
    if (pane->snapshot) szfriends_gtk_nearby_snapshot_free(pane->snapshot);
    g_ptr_array_unref(pane->parts.rows);
    g_free(pane);
}

GtkWidget *szfriends_gtk_nearby_pane_new(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown) {
    SZFriendsGtkNearbyPane *pane = g_new0(SZFriendsGtkNearbyPane, 1);
    pane->link = link;
    pane->dropdown = dropdown;
    pane->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_top(pane->box, 4);
    gtk_widget_set_margin_bottom(pane->box, 8);
    build_visibility(pane);
    build_cards(pane);
    build_people(pane);
    GtkWidget *padded[] = {pane->parts.visibility, pane->parts.alert, pane->parts.note};
    for (gsize i = 0; i < G_N_ELEMENTS(padded); i++) {
        gtk_widget_set_margin_start(padded[i], 12);
        gtk_widget_set_margin_end(padded[i], 12);
        gtk_box_append(GTK_BOX(pane->box), padded[i]);
    }
    gtk_widget_set_visible(pane->parts.alert, FALSE);
    gtk_widget_set_visible(pane->parts.note, FALSE);
    gtk_box_append(GTK_BOX(pane->box), pane->header);
    gtk_box_append(GTK_BOX(pane->box), pane->people_box);
    gtk_box_append(GTK_BOX(pane->box), pane->parts.empty);
    gtk_widget_set_visible(pane->parts.empty, FALSE);
    g_object_set_data_full(G_OBJECT(pane->box), "szfriends-nearby", pane, pane_free);
    return pane->box;
}

const SZFriendsGtkNearbySnapshot *szfriends_gtk_nearby_pane_snapshot(GtkWidget *box) {
    SZFriendsGtkNearbyPane *pane = pane_of(box);
    return pane ? pane->snapshot : NULL;
}

const SZFriendsGtkNearbyParts *szfriends_gtk_nearby_pane_parts(GtkWidget *box) {
    SZFriendsGtkNearbyPane *pane = pane_of(box);
    return pane ? &pane->parts : NULL;
}
