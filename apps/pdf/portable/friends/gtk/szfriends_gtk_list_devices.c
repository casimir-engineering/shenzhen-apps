/* What the list shows for several computers (szfriends_gtk_list_page_private.h; PROTOCOL.md § Devices, § Joining).
 * Mirrors mac/SZFriendsJoinRequestView.m: "This computer was removed" with Start Over, then each request to join this
 * profile with Approve and Deny, then the code to type on the new computer; and the name prompt's "Use my existing
 * profile". A removed computer offers no Add by ID and no Nearby tab: it can add nobody and look for nobody. */

#include "gtk/szfriends_gtk_details_page.h"
#include "gtk/szfriends_gtk_list_page_private.h"

typedef struct {
    GtkWidget *card, *title, *subtitle, *code, *code_note, *buttons;
} SZFriendsGtkJoinCard;

typedef struct {
    SZFriendsGtkDetailsHeld *held; /* the list snapshot the buttons' actions live in */
    GPtrArray *cards;              /* SZFriendsGtkJoinCard * */
} SZFriendsGtkListDevices;

static void devices_free(gpointer data) {
    SZFriendsGtkListDevices *devices = data;
    g_clear_pointer(&devices->held, szfriends_gtk_details_held_unref);
    g_ptr_array_unref(devices->cards);
    g_free(devices);
}

/* Use my existing profile…: the join page, or Reset Friends with its confirmation first (the list's `join`). */
static void join_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkListPage *list = data;
    SZFriendsGtkListDevices *devices = g_object_get_data(G_OBJECT(list->parts.devices), "szfriends-devices");
    const SZFriendsGtkListSnapshot *snapshot = devices->held ? szfriends_gtk_details_held_value(devices->held) : NULL;
    if (snapshot && snapshot->join)
        szfriends_gtk_perform(list->link, list->dropdown, GTK_WIDGET(button), &snapshot->join->action, NULL, NULL,
                              NULL);
}

void szfriends_gtk_list_build_devices(SZFriendsGtkListPage *list, GtkWidget *content) {
    SZFriendsGtkListParts *parts = &list->parts;
    SZFriendsGtkListDevices *devices = g_new0(SZFriendsGtkListDevices, 1);
    devices->cards = g_ptr_array_new_with_free_func(g_free);
    parts->devices = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_name(parts->devices, "szfriends.list.devices");
    g_object_set_data_full(G_OBJECT(parts->devices), "szfriends-devices", devices, devices_free);
    parts->removed = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(parts->removed, "szfriends-notice");
    gtk_widget_add_css_class(parts->removed, "banner");
    parts->removed_title = szfriends_gtk_list_label("szfriends-notice-title");
    parts->removed_body = szfriends_gtk_list_label(NULL);
    parts->removed_slot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_margin_top(parts->removed_slot, 4);
    gtk_box_append(GTK_BOX(parts->removed), parts->removed_title);
    gtk_box_append(GTK_BOX(parts->removed), parts->removed_body);
    gtk_box_append(GTK_BOX(parts->removed), parts->removed_slot);
    parts->join_requests = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_box_append(GTK_BOX(parts->devices), parts->removed);
    gtk_box_append(GTK_BOX(parts->devices), parts->join_requests);
    gtk_widget_set_visible(parts->devices, FALSE);
    gtk_box_insert_child_after(GTK_BOX(content), parts->devices, parts->banner); /* above the name field */
    /* Under the name field: the one way to this computer's side of joining. */
    parts->prompt_join = gtk_button_new_with_label("");
    gtk_widget_add_css_class(parts->prompt_join, "flat");
    gtk_widget_add_css_class(parts->prompt_join, "accent");
    gtk_widget_add_css_class(parts->prompt_join, "szfriends-text-action");
    gtk_widget_set_halign(parts->prompt_join, GTK_ALIGN_START);
    gtk_widget_set_name(parts->prompt_join, "szfriends.list.join");
    g_signal_connect(parts->prompt_join, "clicked", G_CALLBACK(join_clicked), list);
    gtk_widget_set_visible(parts->prompt_join, FALSE);
    gtk_box_append(GTK_BOX(parts->prompt), parts->prompt_join);
}

static SZFriendsGtkJoinCard *card_new(void) {
    SZFriendsGtkJoinCard *card = g_new0(SZFriendsGtkJoinCard, 1);
    card->card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_widget_add_css_class(card->card, "szfriends-join-request");
    card->title = szfriends_gtk_list_label("szfriends-notice-title");
    card->subtitle = szfriends_gtk_list_label("szfriends-secondary");
    /* The code is read off this screen and typed on the other: large tabular digits, selectable, read digit by
     * digit by assistive technology. */
    card->code = gtk_label_new(NULL);
    gtk_widget_add_css_class(card->code, "szfriends-join-code");
    gtk_label_set_selectable(GTK_LABEL(card->code), TRUE);
    gtk_widget_set_margin_top(card->code, 6);
    gtk_widget_set_margin_bottom(card->code, 6);
    card->code_note = szfriends_gtk_list_label("szfriends-secondary");
    card->buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(card->buttons, 6);
    for (GtkWidget **child = (GtkWidget *[]){card->title, card->subtitle, card->code, card->code_note, card->buttons,
                                            NULL};
         *child; child++)
        gtk_box_append(GTK_BOX(card->card), *child);
    return card;
}

/* One press approves: the button stays insensitive until the snapshot shows the code in its place, since a second press
 * before then would only ask again. */
static void approve_pressed(GtkButton *button, gpointer data) {
    (void)data;
    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
}

/* Keeps the buttons when the actions did not change, so a snapshot arriving between two clicks keeps "Deny?". */
static void card_buttons(SZFriendsGtkListPage *list, SZFriendsGtkListDevices *devices, SZFriendsGtkJoinCard *card,
                         const SZFriendsGtkJoinRequest *request) {
    gsize count = 0;
    gboolean same = TRUE;
    GtkWidget *child = gtk_widget_get_first_child(card->buttons);
    for (gsize i = 0; i < request->n_actions; i++) {
        if (!szfriends_gtk_action_is_known(request->actions[i].action)) continue;
        same = same && child && szfriends_gtk_details_button_matches(child, &request->actions[i], NULL);
        child = child ? gtk_widget_get_next_sibling(child) : NULL;
        count++;
    }
    if (same && !child) return;
    while ((child = gtk_widget_get_first_child(card->buttons))) gtk_box_remove(GTK_BOX(card->buttons), child);
    for (gsize i = 0; i < request->n_actions; i++) {
        GtkWidget *button = szfriends_gtk_details_button_new(list->page, devices->held, &request->actions[i], NULL);
        if (!button) continue;
        if (request->actions[i].action == SZFRIENDS_GTK_ACTION_APPROVE_JOIN) {
            g_signal_connect_after(button, "clicked", G_CALLBACK(approve_pressed), NULL);
        }
        gtk_box_append(GTK_BOX(card->buttons), button);
    }
    gtk_widget_set_visible(card->buttons, count > 0);
}

static void apply_requests(SZFriendsGtkListPage *list, SZFriendsGtkListDevices *devices,
                           const SZFriendsGtkListSnapshot *snapshot, gboolean removed) {
    GtkWidget *box = list->parts.join_requests;
    gsize count = removed ? 0 : snapshot->n_join_requests; /* a removed computer answers no request */
    while (devices->cards->len > count) {
        SZFriendsGtkJoinCard *card = g_ptr_array_index(devices->cards, devices->cards->len - 1);
        gtk_box_remove(GTK_BOX(box), card->card);
        g_ptr_array_remove_index(devices->cards, devices->cards->len - 1);
    }
    while (devices->cards->len < count) {
        SZFriendsGtkJoinCard *card = card_new();
        gtk_box_append(GTK_BOX(box), card->card);
        g_ptr_array_add(devices->cards, card);
    }
    for (gsize i = 0; i < count; i++) {
        const SZFriendsGtkJoinRequest *request = &snapshot->join_requests[i];
        SZFriendsGtkJoinCard *card = g_ptr_array_index(devices->cards, i);
        szfriends_gtk_list_label_set(card->title, request->title);
        szfriends_gtk_list_label_set(card->subtitle, request->subtitle);
        gtk_label_set_text(GTK_LABEL(card->code), request->code ? request->code : "");
        gtk_widget_set_visible(card->code, request->code && *request->code);
        if (request->code_accessibility_label)
            gtk_accessible_update_property(GTK_ACCESSIBLE(card->code), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                           request->code_accessibility_label, -1);
        szfriends_gtk_list_label_set(card->code_note, request->code_note);
        gtk_accessible_update_property(GTK_ACCESSIBLE(card->card), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                       request->accessibility_label, -1);
        card_buttons(list, devices, card, request);
    }
    gtk_widget_set_visible(box, count > 0);
}

void szfriends_gtk_list_apply_devices(SZFriendsGtkListPage *list, JsonObject *data) {
    SZFriendsGtkListParts *parts = &list->parts;
    SZFriendsGtkListDevices *devices = g_object_get_data(G_OBJECT(parts->devices), "szfriends-devices");
    SZFriendsGtkDetailsHeld *previous = devices->held;
    devices->held = szfriends_gtk_details_held_new(&szfriends_gtk_type_list_snapshot,
                                                   szfriends_gtk_list_snapshot_parse(data));
    const SZFriendsGtkListSnapshot *snapshot = szfriends_gtk_details_held_value(devices->held);
    gboolean removed = snapshot->state == SZFRIENDS_GTK_LIST_DEVICE_REMOVED;
    parts->device_removed = removed;
    const SZFriendsGtkDeviceRemoved *notice = snapshot->removed;
    gtk_widget_set_visible(parts->removed, notice != NULL);
    szfriends_gtk_list_label_set(parts->removed_title, notice ? notice->title : NULL);
    szfriends_gtk_list_label_set(parts->removed_body, notice ? notice->body : NULL);
    GtkWidget *start_over = gtk_widget_get_first_child(parts->removed_slot);
    if (start_over && (!notice || !szfriends_gtk_details_button_matches(start_over, &notice->action, NULL))) {
        gtk_box_remove(GTK_BOX(parts->removed_slot), start_over);
        start_over = NULL;
    }
    if (notice && !start_over) {
        start_over = szfriends_gtk_details_button_new(list->page, devices->held, &notice->action, NULL);
        if (start_over) gtk_box_append(GTK_BOX(parts->removed_slot), start_over);
    }
    apply_requests(list, devices, snapshot, removed);
    gtk_widget_set_visible(parts->devices, notice || (!removed && snapshot->n_join_requests));
    /* Shown in the name prompt (GTK draws the list's offer there only); its note is the tooltip. */
    const SZFriendsGtkJoinOffer *offer = snapshot->name_prompt ? snapshot->join : NULL;
    gboolean offered = offer && szfriends_gtk_action_is_known(offer->action.action);
    gtk_button_set_label(GTK_BUTTON(parts->prompt_join), offered ? offer->action.label : "");
    gtk_widget_set_tooltip_text(parts->prompt_join, offered ? offer->note : NULL);
    gtk_widget_set_visible(parts->prompt_join, offered);
    gtk_widget_set_visible(parts->tabs, !removed);
    if (removed && parts->showing_nearby) szfriends_gtk_list_page_show_nearby(list->page, FALSE);
    if (removed) gtk_widget_set_visible(szfriends_gtk_footer_parts(parts->footer)->add_button, FALSE);
    if (previous) szfriends_gtk_details_held_unref(previous);
}
