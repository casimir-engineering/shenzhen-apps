/* The Nearby tab against the fake helper: the visibility card with its countdown and Stop, kept across the ticks;
 * the quiet note and the alert, each with what to do; each method's state under the pointer; people, with Request
 * for strangers and their conversation for friends; and the empty states. */

#include "szfriends_gtk_list_probe.h"

#include <string.h>

static const char *text_of(GtkWidget *label) {
    return gtk_label_get_text(GTK_LABEL(label));
}

static gboolean nearby_snapshots(gpointer data) {
    SZFGList *list = data;
    return list->parts->nearby_snapshots > GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(list->window), "szfg-seen"));
}

/* Waits for the next Nearby snapshot after the ones already seen. */
static gboolean next_nearby(SZFGList *list) {
    g_object_set_data(G_OBJECT(list->window), "szfg-seen", GUINT_TO_POINTER(list->parts->nearby_snapshots));
    return szfg_pump_until(nearby_snapshots, list, 3000);
}

static SZFGList *open_nearby(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    szfg_list_wait_rows(list, 7);
    g_object_set_data(G_OBJECT(list->window), "szfg-seen", GUINT_TO_POINTER(list->parts->nearby_snapshots));
    adw_toggle_group_set_active_name(ADW_TOGGLE_GROUP(list->parts->tabs), "nearby");
    EXPECT(szfg_pump_until(nearby_snapshots, list, 3000), "Nearby arrives");
    return list;
}

static GtkWidget *person(const SZFriendsGtkNearbyParts *parts, guint index) {
    return index < parts->rows->len ? g_ptr_array_index(parts->rows, index) : NULL;
}

static void test_visible(SZFGHarness *harness) {
    SZFGList *list = open_nearby(harness);
    const SZFriendsGtkNearbyParts *parts = szfriends_gtk_nearby_pane_parts(list->parts->nearby);
    EXPECT(gtk_widget_has_css_class(parts->visibility, "visible") &&
               !g_strcmp0(text_of(parts->visibility_title), "You’re visible to people nearby") &&
               !g_strcmp0(text_of(parts->countdown), "4:12") &&
               szfg_accessible_label_is(parts->countdown, "4 minutes 12 seconds left"),
           "visible: the card with the time left, spoken in words");
    GtkWidget *stop = parts->visibility_button;
    EXPECT(stop && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(stop)), "Stop"), "and Stop");
    EXPECT(!gtk_widget_get_visible(parts->alert) && gtk_widget_get_visible(parts->note) &&
               !g_strcmp0(text_of(parts->note_text), "Bluetooth is off. People nearby without Wi-Fi won’t appear.") &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(parts->note_button)), "Open Bluetooth settings"),
           "one method off and others working: a quiet line, not an error");
    EXPECT(gtk_widget_get_visible(parts->status) && !g_strcmp0(text_of(parts->status_label), "Still looking") &&
               !g_strcmp0(text_of(parts->people_label), "People nearby"), "the people header, still looking");
    GtkWidget *header = gtk_widget_get_parent(parts->people_label);
    EXPECT(!g_strcmp0(gtk_widget_get_tooltip_text(header), "Looking on your network and over Wi-Fi\nBluetooth is off"),
           "each method's state under the pointer");
    EXPECT(parts->rows->len == 4, "four people (%u)", parts->rows->len);
    EXPECT(szfriends_gtk_row_get_look(person(parts, 0)).right == SZFRIENDS_GTK_ROW_RIGHT_STATUS &&
               szfriends_gtk_row_get_look(person(parts, 2)).right == SZFRIENDS_GTK_ROW_RIGHT_STATUS,
           "a friend and a request sent show their state");
    GtkWidget *request = szfriends_gtk_row_get_accessory(person(parts, 1));
    EXPECT(request && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(request)), "Request") &&
               gtk_widget_has_css_class(request, "suggested-action"), "a stranger has Request");
    szfriends_gtk_row_activate(person(parts, 1));
    EXPECT(szfriends_gtk_dropdown_get_depth(list->dropdown) == 1, "a stranger with no conversation opens nothing");

    guint requests = szfg_frames(harness, "send_request"), stops = szfg_frames(harness, "stop_visibility");
    g_signal_emit_by_name(request, "clicked");
    EXPECT(szfg_wait_frames(harness, "send_request", requests + 1), "Request sends a request");
    char *nearby_id = szfg_last_field(harness, "send_request", "nearby_id");
    EXPECT(!g_strcmp0(nearby_id, "n_7c1e"), "to Lena as Nearby knows her (%s)", nearby_id);
    g_free(nearby_id);
    g_signal_emit_by_name(stop, "clicked");
    EXPECT(szfg_wait_frames(harness, "stop_visibility", stops + 1), "Stop stops");
    g_clear_pointer(&szfg_opened, g_free);
    g_signal_emit_by_name(parts->note_button, "clicked");
    EXPECT(!g_strcmp0(szfg_opened, szfriends_gtk_settings_uri(SZFRIENDS_GTK_SETTINGS_BLUETOOTH)),
           "the note's action opens Bluetooth settings (%s)", szfg_opened);

    /* The countdown ticks every second; the card and its Stop stay the same widgets. */
    JsonObject *frame = szfg_fixture("snapshots/nearby-visible-bluetooth-off.json");
    JsonObject *data = json_object_get_object_member(frame, "data");
    json_object_set_string_member(json_object_get_object_member(data, "visibility"), "remaining_label", "4:11");
    JsonNode *node = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(node, data);
    char *text = json_to_string(node, FALSE);
    szfriends_fake_helper_set_view_data(harness->fake, "nearby", text);
    EXPECT(next_nearby(list) && !g_strcmp0(text_of(parts->countdown), "4:11") && parts->visibility_button == stop,
           "a tick updates the time in place");
    g_free(text);
    json_node_unref(node);
    json_object_unref(frame);
    szfriends_fake_helper_set_view_fixture(harness->fake, "nearby", "nearby-visible-bluetooth-off.json");

    szfriends_gtk_row_activate(person(parts, 0));
    SZFriendsGtkPage *top = szfriends_gtk_dropdown_get_top_page(list->dropdown);
    EXPECT(szfriends_gtk_page_get_kind(top) == SZFRIENDS_GTK_PAGE_CONVERSATION &&
               !g_strcmp0(szfriends_gtk_page_get_argument(top), "c_kenji"), "a friend nearby opens their chat");
    szfg_list_close(list);
}

static void test_denied(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_fixture(harness->fake, "nearby", "nearby-local-network-denied.json");
    SZFGList *list = open_nearby(harness);
    const SZFriendsGtkNearbyParts *parts = szfriends_gtk_nearby_pane_parts(list->parts->nearby);
    GtkWidget *start = parts->visibility_button;
    EXPECT(!gtk_widget_has_css_class(parts->visibility, "visible") && start &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(start)), "Make myself visible for 5 minutes") &&
               !gtk_widget_get_visible(parts->countdown) && gtk_widget_get_visible(parts->visibility_body),
           "hidden: the action first, what it does under it, no countdown");
    EXPECT(gtk_widget_get_visible(parts->alert) &&
               !g_strcmp0(text_of(parts->alert_title), "ShenzhenPDF can’t find people on your network") &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(parts->alert_button)), "Open Privacy Settings"),
           "the method most people rely on is off: the one card, with what to do");
    EXPECT(gtk_widget_get_visible(parts->note) && !gtk_widget_get_visible(parts->note_button) &&
               !g_strcmp0(text_of(parts->note_text), "Still looking over Bluetooth."), "and what Bluetooth is doing");
    EXPECT(!gtk_widget_get_visible(parts->status), "no status without one in the snapshot");
    g_clear_pointer(&szfg_opened, g_free);
    g_signal_emit_by_name(parts->alert_button, "clicked");
    EXPECT(!g_strcmp0(szfg_opened, szfriends_gtk_settings_uri(SZFRIENDS_GTK_SETTINGS_LOCAL_NETWORK_PRIVACY)),
           "Open Privacy Settings opens Local Network privacy (%s)", szfg_opened);
    guint starts = szfg_frames(harness, "start_visibility");
    g_signal_emit_by_name(start, "clicked");
    EXPECT(szfg_wait_frames(harness, "start_visibility", starts + 1), "the action makes the person visible");

    /* Nobody yet: the empty state says whether it is looking, never an empty successful search. */
    szfriends_fake_helper_set_view_data(harness->fake, "nearby",
        "{\"query\":\"\",\"visibility\":{\"state\":\"hidden\",\"title\":null,\"body\":null,\"remaining_label\":null,"
        "\"remaining_accessibility_label\":null,\"deadline\":null,\"action\":null},\"methods\":[],\"alert\":null,"
        "\"note\":null,\"status\":null,\"people\":[],\"empty\":{\"kind\":\"searching\",\"title\":\"Looking for "
        "people nearby…\",\"body\":null},\"footer\":{}}");
    EXPECT(next_nearby(list) && gtk_widget_get_visible(parts->empty) && gtk_widget_get_visible(parts->empty_glyph) &&
               !g_strcmp0(text_of(parts->empty_title), "Looking for people nearby…") &&
               !gtk_widget_get_visible(parts->empty_body) && parts->rows->len == 0 && !parts->visibility_button,
           "searching: the arc and the title, no body, no rows, no action it lacks");
    szfriends_fake_helper_set_view_data(harness->fake, "nearby",
        "{\"query\":\"\",\"visibility\":{\"state\":\"unavailable\",\"title\":null,\"body\":\"Nobody can see you.\","
        "\"action\":null},\"methods\":[],\"alert\":null,\"note\":null,\"status\":null,\"people\":[],\"empty\":"
        "{\"kind\":\"unavailable\",\"title\":\"Nearby isn’t working\",\"body\":\"Try again.\"},\"footer\":{}}");
    EXPECT(next_nearby(list) && !gtk_widget_get_visible(parts->empty_glyph) &&
               gtk_widget_get_visible(parts->empty_body), "unavailable: said plainly, without the searching arc");
    szfriends_fake_helper_set_view_fixture(harness->fake, "nearby", "nearby-visible-bluetooth-off.json");
    szfg_list_close(list);
}

void szfg_run_list_nearby_probes(SZFGHarness *harness) {
    test_visible(harness);
    test_denied(harness);
}
