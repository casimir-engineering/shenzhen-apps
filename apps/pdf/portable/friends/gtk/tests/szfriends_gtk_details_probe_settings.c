/* The Settings section offscreen, against the fake helper: subscribed only while on screen, every row plain text
 * (use-markup off, a name with markup characters shown as typed), the name sent only when changed, Copy, Show in
 * Finder through the host, a switch per friend behind Choose friends…, Delete history and Reset Friends sent only
 * after their confirmations and with the fields PROTOCOL.md asks for, and the link's line while the helper is away.
 * Renders light and dark with the friends' switches out. */

#include "szfriends_gtk_details_probe.h"

#include <string.h>

typedef struct {
    GtkWidget *window, *section;
} SZFGSection;

static SZFGSection open_section(SZFGHarness *harness) {
    SZFGSection section = {NULL, szfriends_gtk_settings_section_new(harness->link)};
    section.window = szfg_probe_window(section.section);
    guint before = szfg_fake_frames(harness, "subscribe", "view", "settings");
    /* Mapped as the host's Settings would show it, before any layout, so a render shows the snapshot's rows. */
    gtk_widget_map(section.section);
    EXPECT(szfg_wait_frames(harness, "subscribe", "view", "settings", before + 1), "subscribed once on screen");
    EXPECT(szfg_wait_label(section.section, "Accept files automatically"), "the settings snapshot is drawn");
    return section;
}

static void close_section(SZFGSection *section) {
    gtk_window_destroy(GTK_WINDOW(section->window));
    szfg_pump_for(20);
}

static void count_rows(GtkWidget *root, guint *rows, guint *markup, guint *switches) {
    if (ADW_IS_PREFERENCES_ROW(root)) {
        (*rows)++;
        if (adw_preferences_row_get_use_markup(ADW_PREFERENCES_ROW(root))) (*markup)++;
        if (ADW_IS_SWITCH_ROW(root)) (*switches)++;
    }
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child))
        count_rows(child, rows, markup, switches);
}

static GtkWidget *switch_row(GtkWidget *root, const char *title) {
    if (ADW_IS_SWITCH_ROW(root) && !g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(root)), title))
        return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = switch_row(child, title);
        if (found) return found;
    }
    return NULL;
}

static void test_rows(SZFGHarness *harness, GtkWidget *section) {
    guint rows = 0, markup = 0, switches = 0;
    count_rows(section, &rows, &markup, &switches);
    EXPECT(rows == 6 && markup == 0 && switches == 0, "six plain-text rows, the switches folded away (%u, %u, %u)",
           rows, markup, switches);
    GtkWidget *name = szfg_find_named(section, "szfriends.settings.name");
    EXPECT(name && !g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(name)), "Raph"), "the name in its field");
    g_signal_emit_by_name(name, "activate");
    gtk_editable_set_text(GTK_EDITABLE(name), "Raph L.");
    g_signal_emit_by_name(name, "activate");
    EXPECT(szfg_wait_frames(harness, "set_name", "name", "Raph L.", 1) &&
               szfg_fake_frames(harness, "set_name", NULL, NULL) == 1, "only a changed name is sent");
    /* While the person types, a snapshot leaves the field alone; leaving it commits (the probe plays the focus). */
    GtkEventController *focus = NULL;
    GListModel *controllers = gtk_widget_observe_controllers(name);
    for (guint i = 0; i < g_list_model_get_n_items(controllers) && !focus; i++) {
        GtkEventController *candidate = g_list_model_get_item(controllers, i);
        if (GTK_IS_EVENT_CONTROLLER_FOCUS(candidate)) focus = candidate;
        g_object_unref(candidate);
    }
    g_object_unref(controllers);
    EXPECT(focus != NULL, "the name field watches focus");
    if (focus) g_signal_emit_by_name(focus, "enter");
    gtk_editable_set_text(GTK_EDITABLE(name), "Ra");
    JsonObject *data = szfg_fixture_data("snapshots/settings.json");
    json_object_set_string_member(json_object_get_object_member(data, "id"), "note", "Share it with friends.");
    szfg_script_view(harness, "settings", data);
    json_object_unref(data);
    EXPECT(szfg_wait_label(section, "Share it with friends.") &&
               !g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(name)), "Ra"), "a snapshot leaves typing alone");
    if (focus) g_signal_emit_by_name(focus, "leave");
    EXPECT(szfg_wait_frames(harness, "set_name", "name", "Ra", 1), "leaving the field sends it");
    EXPECT(szfg_find_label(section, "cottage-violet") != NULL, "your ID");
    g_signal_emit_by_name(szfg_find_named(section, "szfriends.settings.copy"), "clicked");
    EXPECT(szfg_outside.copied && !strcmp(g_ptr_array_index(szfg_outside.copied, 0), "cottage-violet"), "Copy");
    GtkWidget *show = szfg_find_named(section, "szfriends.settings.received");
    EXPECT(show && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(show)), "Show in Finder"), "the received folder");
    if (show) g_signal_emit_by_name(show, "clicked");
    EXPECT(szfg_outside.revealed && !g_strcmp0(g_ptr_array_index(szfg_outside.revealed, 0), "/Users/raph/Downloads"),
           "shown through the host");
    /* Where received files go: the folder's name under "Save received files to", and Change… opens the folder
     * dialog at that folder and sends the folder picked. */
    EXPECT(szfg_find_label(section, "Save received files to") && szfg_find_label(section, "Downloads"),
           "Save received files to: Downloads");
    GtkWidget *change = szfg_find_named(section, "szfriends.settings.received_change");
    EXPECT(change && gtk_widget_get_visible(change) && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(change)), "Change…"),
           "Change… beside Show in Finder");
    g_free(szfg_outside.chosen);
    szfg_outside.chosen = g_strdup("/home/raph/From friends");
    guint calls = szfg_outside.chooser_calls;
    if (change) g_signal_emit_by_name(change, "clicked");
    EXPECT(szfg_outside.chooser_calls == calls + 1 && !g_strcmp0(szfg_outside.folder_start, "/Users/raph/Downloads"),
           "the folder dialog opens at the folder: %s", szfg_outside.folder_start ? szfg_outside.folder_start : "");
    EXPECT(szfg_wait_frames(harness, "set_received_folder", "path", "/home/raph/From friends", 1),
           "set_received_folder with the folder picked");
    g_clear_pointer(&szfg_outside.chosen, g_free);
}

static void test_friends(SZFGHarness *harness, GtkWidget *section) {
    GtkWidget *change = szfg_find_named(section, "szfriends.settings.change");
    EXPECT(change && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(change)), "Choose friends…"), "Choose friends…");
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(change), TRUE);
    guint rows = 0, markup = 0, switches = 0;
    count_rows(section, &rows, &markup, &switches);
    GtkWidget *mei = switch_row(section, "Mei Lin"), *kenji = switch_row(section, "Kenji Sato");
    EXPECT(switches == 5 && markup == 0 && mei && kenji && adw_switch_row_get_active(ADW_SWITCH_ROW(mei)) &&
               !adw_switch_row_get_active(ADW_SWITCH_ROW(kenji)), "a plain-text switch per friend, as the helper says");
    if (kenji) adw_switch_row_set_active(ADW_SWITCH_ROW(kenji), TRUE);
    EXPECT(szfg_wait_frames(harness, "set_auto_accept", "conversation_id", "c_kenji", 1), "a switch asks the helper");
    JsonObject *frame = szfg_fake_last_frame(harness, "set_auto_accept");
    EXPECT(frame && json_object_get_boolean_member(frame, "enabled"), "to accept Kenji's files automatically");
    if (frame) json_object_unref(frame);
    JsonObject *data = szfg_fixture_data("snapshots/settings.json");
    JsonObject *automatic = json_object_get_object_member(data, "auto_accept");
    JsonObject *first = json_array_get_object_element(json_object_get_array_member(automatic, "friends"), 0);
    json_object_set_string_member(first, "title", "<b>Mei</b> & Lin");
    szfg_script_view(harness, "settings", data);
    json_object_unref(data);
    gboolean shown = FALSE;
    for (int i = 0; i < 300 && !shown; i++, szfg_pump_for(10)) shown = switch_row(section, "<b>Mei</b> & Lin") != NULL;
    EXPECT(shown, "a name with markup characters is shown as typed");
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(change), FALSE);
    rows = markup = switches = 0;
    count_rows(section, &rows, &markup, &switches);
    EXPECT(switches == 0, "and fold away again");
    /* No friends: nothing to choose, so no button. */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(change), TRUE);
    JsonObject *lonely = szfg_fixture_data("snapshots/settings.json");
    JsonObject *nobody = json_object_get_object_member(lonely, "auto_accept");
    json_object_set_array_member(nobody, "friends", json_array_new());
    json_object_set_string_member(nobody, "note", "Turn it on for a friend in their details.");
    szfg_script_view(harness, "settings", lonely);
    json_object_unref(lonely);
    for (int i = 0; i < 300 && gtk_widget_get_visible(change); i++) szfg_pump_for(10);
    rows = markup = switches = 0;
    count_rows(section, &rows, &markup, &switches);
    EXPECT(!gtk_widget_get_visible(change) && switches == 0, "no friends, no Choose friends…");
    JsonObject *again = szfg_fixture_data("snapshots/settings.json");
    szfg_script_view(harness, "settings", again);
    json_object_unref(again);
    for (int i = 0; i < 300 && !gtk_widget_get_visible(change); i++) szfg_pump_for(10);
    EXPECT(gtk_widget_get_visible(change), "friends again, Choose friends… again");
}

static void test_confirmed(SZFGHarness *harness, GtkWidget *section) {
    GtkWidget *history = szfg_find_named(section, "szfriends.settings.history");
    GtkWidget *reset = szfg_find_named(section, "szfriends.settings.reset");
    EXPECT(history && reset && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(history)), "Delete history…") &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(reset)), "Reset Friends…"), "the two buttons");
    g_signal_emit_by_name(history, "clicked");
    EXPECT(szfg_outside.confirms && szfg_outside.confirms->len == 1 &&
               !strcmp(g_ptr_array_index(szfg_outside.confirms, 0), "Delete all conversation history? (destructive)") &&
               szfg_fake_frames(harness, "delete_history", NULL, NULL) == 0,
           "Delete history asks first, as a destructive question, and sends nothing yet");
    /* The helper's question word for word: what goes and what stays, for every chat, as each friend's details say. */
    EXPECT(szfg_outside.confirm_bodies && szfg_outside.confirm_bodies->len == 1 &&
               !strcmp(g_ptr_array_index(szfg_outside.confirm_bodies, 0),
                       "Your messages and file history with every friend are deleted from this computer, and anything "
                       "still waiting to go won’t be sent. You keep your friends, and they keep their own copies of "
                       "your chats. Files you received stay where they were saved."),
           "it says what goes and what stays");
    szfg_outside_answer(TRUE);
    EXPECT(szfg_wait_frames(harness, "delete_history", NULL, NULL, 1), "confirmed, it deletes");
    JsonObject *frame = szfg_fake_last_frame(harness, "delete_history");
    EXPECT(frame && !json_object_has_member(frame, "conversation_id"), "all history: no conversation named");
    if (frame) json_object_unref(frame);
    g_signal_emit_by_name(reset, "clicked");
    szfg_outside_answer(FALSE);
    szfg_pump_for(100);
    EXPECT(szfg_fake_frames(harness, "reset_friends", NULL, NULL) == 0, "Cancel resets nothing");
    g_signal_emit_by_name(reset, "clicked");
    EXPECT(szfg_outside.confirms && szfg_outside.confirms->len == 3 &&
               !strcmp(g_ptr_array_index(szfg_outside.confirms, 2), "Reset Friends? (destructive)"),
           "Reset asks every time");
    szfg_outside_answer(TRUE);
    EXPECT(szfg_wait_frames(harness, "reset_friends", "confirm", "reset", 1), "confirmed, it resets, saying so");
}

static gboolean status_visible(gpointer data) {
    GtkWidget *status = gtk_widget_get_first_child(gtk_widget_get_first_child(data));
    return gtk_widget_get_visible(status) && *gtk_label_get_text(GTK_LABEL(status));
}

static gboolean status_hidden(gpointer data) {
    return !status_visible(data);
}

static void test_status(SZFGHarness *harness, GtkWidget *section) {
    EXPECT(status_hidden(section), "nothing to say while the helper answers");
    szfriends_fake_helper_drop_clients(harness->fake);
    EXPECT(szfg_pump_until(status_visible, section, 3000), "the link's line while it does not");
    EXPECT(szfg_pump_until(status_hidden, section, 5000), "gone once it answers again");
    EXPECT(szfg_wait_label(section, "Accept files automatically"), "the rows kept their values throughout");
}

static void render_fresh(SZFGHarness *harness, gboolean dark, const char *name) {
    szfg_set_dark(dark);
    szfriends_fake_helper_set_view_fixture(harness->fake, "settings", "settings.json");
    szfg_pump_for(50);
    SZFGSection section = open_section(harness);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(szfg_find_named(section.section, "szfriends.settings.change")),
                                 TRUE);
    GdkTexture *texture = szfg_render(section.window, 560, -1, name);
    g_object_unref(texture);
    close_section(&section);
    szfg_set_dark(FALSE);
}

void szfg_run_settings_probes(void) {
    SZFGHarness *harness = szfg_details_harness("settings");
    szfg_outside_install();
    render_fresh(harness, FALSE, "settings-light");
    render_fresh(harness, TRUE, "settings-dark");
    szfriends_fake_helper_set_view_fixture(harness->fake, "settings", "settings.json");
    SZFGSection section = open_section(harness);
    test_rows(harness, section.section);
    test_friends(harness, section.section);
    test_confirmed(harness, section.section);
    test_status(harness, section.section);
    guint unsubscribed = szfg_fake_frames(harness, "unsubscribe", NULL, NULL);
    gtk_widget_unmap(section.section);
    EXPECT(szfg_wait_frames(harness, "unsubscribe", NULL, NULL, unsubscribed + 1), "off screen, it lets go");
    close_section(&section);
    szfg_outside_uninstall();
    szfg_harness_free(harness);
}
