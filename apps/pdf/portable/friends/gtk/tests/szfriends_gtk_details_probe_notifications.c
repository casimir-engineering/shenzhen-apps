/* Settings' Notifications block offscreen (PROTOCOL.md § Notifications): absent without the helper's block; the
 * helper's words on two switches, each sent back alone with set_notifications; the permission's note and its one
 * button (Open System Settings opens the helper's own notification settings on macOS and nothing elsewhere; Allow
 * sends allow_notifications); Android's background switch only when the snapshot carries it. */

#include "szfriends_gtk_details_probe.h"

#include <string.h>

static JsonObject *last_frame(SZFGHarness *harness, const char *type) {
    return szfg_fake_last_frame(harness, type);
}

/* The newest set_notifications carries exactly `field` = `value`. */
static gboolean sent_alone(SZFGHarness *harness, const char *field, gboolean value) {
    JsonObject *frame = last_frame(harness, "set_notifications");
    if (!frame) return FALSE;
    static const char *const fields[] = {"enabled", "preview", "background"};
    gboolean ok = json_object_has_member(frame, field) && json_object_get_boolean_member(frame, field) == value;
    for (gsize i = 0; i < G_N_ELEMENTS(fields); i++)
        if (strcmp(fields[i], field) != 0) ok &= !json_object_has_member(frame, fields[i]);
    json_object_unref(frame);
    return ok;
}

/* Visible up to the section (the probe's window itself is never shown). */
static GtkWidget *section_root;

static gboolean shown(GtkWidget *widget) {
    for (GtkWidget *w = widget; w && w != section_root; w = gtk_widget_get_parent(w))
        if (!gtk_widget_get_visible(w)) return FALSE;
    return widget != NULL;
}

static guint uri_count(void) {
    return szfg_outside.uris ? szfg_outside.uris->len : 0;
}

static void toggle(GtkWidget *row) {
    adw_switch_row_set_active(ADW_SWITCH_ROW(row), !adw_switch_row_get_active(ADW_SWITCH_ROW(row)));
}

static void test_block(SZFGHarness *harness, GtkWidget *section) {
    section_root = section;
    GtkWidget *heading = szfg_find_named(section, "szfriends.settings.notifications");
    EXPECT(!heading, "no Notifications rows from a helper without them");
    szfriends_fake_helper_set_view_fixture(harness->fake, "settings", "views-notifications-settings.json");
    EXPECT(szfg_wait_label(section, "Notifications"), "the block arrives with its heading");
    heading = szfg_find_named(section, "szfriends.settings.notifications");
    GtkWidget *enabled = szfg_find_named(section, "szfriends.settings.notifications.enabled");
    GtkWidget *preview = szfg_find_named(section, "szfriends.settings.notifications.preview");
    GtkWidget *permission = szfg_find_named(section, "szfriends.settings.notifications.permission");
    GtkWidget *background = szfg_find_named(section, "szfriends.settings.notifications.background");
    EXPECT(shown(heading) && enabled && preview && permission && background, "heading and rows");
    if (!enabled || !preview || !permission || !background) return;
    EXPECT(!g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(enabled)), "Show notifications") &&
               adw_switch_row_get_active(ADW_SWITCH_ROW(enabled)) &&
               !adw_preferences_row_get_use_markup(ADW_PREFERENCES_ROW(enabled)), "Show notifications, on");
    EXPECT(!g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(preview)), "Show message text") &&
               g_str_has_prefix(adw_action_row_get_subtitle(ADW_ACTION_ROW(preview)), "When this is off") &&
               !adw_switch_row_get_active(ADW_SWITCH_ROW(preview)), "Show message text, off, with its note");
    EXPECT(shown(permission) && !g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(permission)),
                                           "Notifications from Shenzhen Friends are off in System Settings."),
           "the permission's note");
    EXPECT(!gtk_widget_get_visible(background), "no background switch off Android");
    guint sent = szfg_fake_frames(harness, "set_notifications", NULL, NULL);
    toggle(preview);
    EXPECT(szfg_wait_frames(harness, "set_notifications", NULL, NULL, sent + 1) &&
               sent_alone(harness, "preview", TRUE), "Show message text sends preview alone");
    toggle(enabled);
    EXPECT(szfg_wait_frames(harness, "set_notifications", NULL, NULL, sent + 2) &&
               sent_alone(harness, "enabled", FALSE), "Show notifications sends enabled alone");

    GtkWidget *button = szfg_find_named(section, "szfriends.settings.notifications.action");
    EXPECT(button && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(button)), "Open System Settings"),
           "Open System Settings beside the note");
    guint uris = uri_count();
    if (button) szfg_press(button, 1);
#ifdef __APPLE__
    EXPECT(uri_count() == uris + 1 &&
               !g_strcmp0(g_ptr_array_index(szfg_outside.uris, uris),
                          "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                          "?id=com.intuition.shenzhenfriends"),
           "it opens the helper's own notification settings");
#else
    EXPECT(uri_count() == uris, "no system page to open here");
#endif

    /* Not asked yet: Allow; nothing to say; and a phone's background switch. */
    JsonObject *data = szfg_fixture_data("snapshots/views-notifications-settings.json");
    JsonObject *notifications = json_object_get_object_member(data, "notifications");
    json_object_set_string_member(notifications, "note", "");
    JsonObject *allow = json_object_new();
    json_object_set_string_member(allow, "action", "allow_notifications");
    json_object_set_string_member(allow, "label", "Allow");
    json_object_set_string_member(allow, "style", "primary");
    json_object_set_object_member(notifications, "action", allow);
    JsonObject *stay = json_object_new();
    json_object_set_string_member(stay, "label", "Stay reachable in the background");
    json_object_set_string_member(stay, "note", "Keeps Friends running.");
    json_object_set_boolean_member(stay, "value", FALSE);
    json_object_set_object_member(notifications, "background", stay);
    szfg_script_view(harness, "settings", data);
    json_object_unref(data);
    EXPECT(szfg_wait_label(section, "Stay reachable in the background") || shown(background),
           "the background switch arrives");
    EXPECT(shown(background) && !g_strcmp0(adw_action_row_get_subtitle(ADW_ACTION_ROW(background)),
                                           "Keeps Friends running."), "with its note");
    button = szfg_find_named(section, "szfriends.settings.notifications.action");
    EXPECT(button && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(button)), "Allow") && shown(permission) &&
               !g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(permission)), ""),
           "Allow alone on the permission's row");
    guint allows = szfg_fake_frames(harness, "allow_notifications", NULL, NULL);
    if (button) szfg_press(button, 1);
    EXPECT(szfg_wait_frames(harness, "allow_notifications", NULL, NULL, allows + 1), "Allow asks");
    sent = szfg_fake_frames(harness, "set_notifications", NULL, NULL);
    toggle(background);
    EXPECT(szfg_wait_frames(harness, "set_notifications", NULL, NULL, sent + 1) &&
               sent_alone(harness, "background", TRUE), "the background switch sends background alone");

    /* Nothing to say and nothing to do: no permission row. Then a helper without the block: none of it. */
    data = szfg_fixture_data("snapshots/views-notifications-settings.json");
    notifications = json_object_get_object_member(data, "notifications");
    json_object_set_string_member(notifications, "note", "");
    json_object_set_null_member(notifications, "action");
    json_object_set_string_member(notifications, "label", "Notifications here");
    szfg_script_view(harness, "settings", data);
    json_object_unref(data);
    EXPECT(szfg_wait_label(section, "Notifications here") && !gtk_widget_get_visible(permission) &&
               !gtk_widget_get_visible(background), "an empty note without an action draws no row");
    sent = szfg_fake_frames(harness, "set_notifications", NULL, NULL);
    szfriends_fake_helper_set_view_fixture(harness->fake, "settings", "settings.json");
    szfg_pump_for(300);
    EXPECT(!shown(heading) && !shown(enabled), "a snapshot without notifications hides the block");
    EXPECT(szfg_fake_frames(harness, "set_notifications", NULL, NULL) == sent,
           "showing a snapshot sends nothing back");
}

void szfg_run_settings_notification_probes(void) {
    SZFGHarness *harness = szfg_details_harness("settings-notify");
    szfg_outside_install();
    szfriends_fake_helper_set_view_fixture(harness->fake, "settings", "settings.json");
    GtkWidget *section = szfriends_gtk_settings_section_new(harness->link);
    GtkWidget *window = szfg_probe_window(section);
    gtk_widget_map(section);
    EXPECT(szfg_wait_label(section, "Accept files automatically"), "the settings snapshot is drawn");
    test_block(harness, section);
    gtk_window_destroy(GTK_WINDOW(window));
    szfg_pump_for(20);
    szfg_outside_uninstall();
    szfg_harness_free(harness);
}
