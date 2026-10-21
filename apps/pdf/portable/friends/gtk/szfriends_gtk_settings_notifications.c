/* The Notifications block of the Settings section (szfriends_gtk_details_page.h; PROTOCOL.md § Notifications,
 * snapshot.settings `notifications`): this device's "Show notifications" and "Show message text" switches, each sent
 * back alone with set_notifications, the permission's note with its one action (Allow, or Open System Settings), and
 * the Android-only "Stay reachable in the background" switch when a snapshot carries it. Every word is the helper's;
 * a note it leaves empty and a block it leaves out draw nothing. The rows are made with the first snapshot that has
 * the block, so a helper without notifications adds no row at all. */

#include "gtk/szfriends_gtk_details_page.h"
#include "gtk/szfriends_gtk_internal.h"

#include <adwaita.h>

typedef struct {
    SZFriendsGtkPage *page;
    GtkWidget *box, *heading, *group, *enabled, *preview, *permission, *permission_button, *background;
    gboolean applying;
} SZFriendsGtkNotificationsBlock;

#define BLOCK_KEY "szfriends-settings-notifications"

static GtkWidget *plain_row(GType type, const char *name) {
    GtkWidget *row = g_object_new(type, NULL);
    adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row), FALSE);
    gtk_widget_set_name(row, name);
    return row;
}

static void set_row(GtkWidget *row, const char *title, const char *subtitle) {
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), title ? title : "");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(row), subtitle ? subtitle : "");
}

/* One switch changed: set_notifications carries only that switch's field. */
static void toggled(GObject *row, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    SZFriendsGtkNotificationsBlock *block = data;
    if (block->applying) return;
    int value = adw_switch_row_get_active(ADW_SWITCH_ROW(row)) ? 1 : 0;
    int enabled = -1, preview = -1, background = -1;
    if (GTK_WIDGET(row) == block->enabled) enabled = value;
    else if (GTK_WIDGET(row) == block->preview) preview = value;
    else background = value;
    szfriends_gtk_details_send(block->page, szfriends_intent_set_notifications(enabled, preview, background), NULL);
}

static GtkWidget *switch_row(SZFriendsGtkNotificationsBlock *block, const char *name) {
    GtkWidget *row = plain_row(ADW_TYPE_SWITCH_ROW, name);
    g_signal_connect(row, "notify::active", G_CALLBACK(toggled), block);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(block->group), row);
    return row;
}

static void make_rows(SZFriendsGtkNotificationsBlock *block) {
    block->heading = szfriends_gtk_details_label("heading");
    gtk_widget_set_name(block->heading, "szfriends.settings.notifications");
    block->group = adw_preferences_group_new();
    block->enabled = switch_row(block, "szfriends.settings.notifications.enabled");
    block->preview = switch_row(block, "szfriends.settings.notifications.preview");
    block->permission = plain_row(ADW_TYPE_ACTION_ROW, "szfriends.settings.notifications.permission");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(block->group), block->permission);
    block->background = switch_row(block, "szfriends.settings.notifications.background");
    gtk_box_append(GTK_BOX(block->box), block->heading);
    gtk_box_append(GTK_BOX(block->box), block->group);
}

/* The permission's one button; the same button stays while the snapshot names the same action. */
static void apply_action(SZFriendsGtkNotificationsBlock *block, SZFriendsGtkDetailsHeld *held,
                         const SZFriendsGtkAction *action) {
    if (szfriends_gtk_details_button_matches(block->permission_button, action, NULL)) return;
    if (block->permission_button) {
        adw_action_row_remove(ADW_ACTION_ROW(block->permission), block->permission_button);
        block->permission_button = NULL;
    }
    if (!action) return;
    block->permission_button = szfriends_gtk_details_button_new(block->page, held, action, NULL);
    if (!block->permission_button) return;
    gtk_widget_set_name(block->permission_button, "szfriends.settings.notifications.action");
    gtk_widget_set_valign(block->permission_button, GTK_ALIGN_CENTER);
    adw_action_row_add_suffix(ADW_ACTION_ROW(block->permission), block->permission_button);
}

void szfriends_gtk_settings_notifications_apply(GtkWidget *widget, SZFriendsGtkDetailsHeld *held) {
    SZFriendsGtkNotificationsBlock *block = g_object_get_data(G_OBJECT(widget), BLOCK_KEY);
    const SZFriendsGtkSettingsSnapshot *snapshot = held ? szfriends_gtk_details_held_value(held) : NULL;
    const SZFriendsGtkSettingsNotifications *notifications = snapshot ? snapshot->notifications : NULL;
    gtk_widget_set_visible(widget, notifications != NULL);
    if (!notifications) return;
    if (!block->group) make_rows(block);
    block->applying = TRUE;
    szfriends_gtk_details_label_set(block->heading, notifications->label);
    set_row(block->enabled, notifications->enabled.label, NULL);
    adw_switch_row_set_active(ADW_SWITCH_ROW(block->enabled), notifications->enabled.value);
    set_row(block->preview, notifications->preview.label, notifications->preview.note);
    adw_switch_row_set_active(ADW_SWITCH_ROW(block->preview), notifications->preview.value);
    apply_action(block, held, notifications->action);
    /* The permission's line: what the helper says, with its button; nothing when it has neither. */
    set_row(block->permission, notifications->note, NULL);
    gtk_widget_set_visible(block->permission, *notifications->note || block->permission_button);
    const SZFriendsGtkSettingsNotedSwitch *background = notifications->background;
    gtk_widget_set_visible(block->background, background != NULL);
    if (background) {
        set_row(block->background, background->label, background->note);
        adw_switch_row_set_active(ADW_SWITCH_ROW(block->background), background->value);
    }
    block->applying = FALSE;
}

GtkWidget *szfriends_gtk_settings_notifications_new(SZFriendsGtkPage *page) {
    SZFriendsGtkNotificationsBlock *block = g_new0(SZFriendsGtkNotificationsBlock, 1);
    block->page = page;
    block->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_visible(block->box, FALSE);
    g_object_set_data_full(G_OBJECT(block->box), BLOCK_KEY, block, g_free);
    return block->box;
}
