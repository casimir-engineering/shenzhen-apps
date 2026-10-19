/* Your computers in the profile (szfriends_gtk_devices.h; PROTOCOL.md § Devices, type.device_row). Mirrors
 * mac/SZFriendsYourComputers.m: each computer with its name, system and last connection, Rename on this computer's
 * row, Remove… on the others with the helper's confirmation, then how to add one. Hidden without `devices`. */

#include "gtk/szfriends_gtk_devices.h"

#include <string.h>

typedef struct {
    SZFriendsGtkPage *page;
    SZFriendsGtkDetailsHeld *held;
    SZFriendsGtkProfileDevicesParts parts;
    gboolean renaming;
} SZFriendsGtkProfileDevicesView;

static SZFriendsGtkProfileDevicesView *view_of(GtkWidget *box) {
    return box ? g_object_get_data(G_OBJECT(box), "szfriends-devices") : NULL;
}

static const SZFriendsGtkProfileDevices *devices_of(SZFriendsGtkProfileDevicesView *view) {
    const SZFriendsGtkProfileSnapshot *profile = view->held ? szfriends_gtk_details_held_value(view->held) : NULL;
    return profile ? profile->devices : NULL;
}

static const SZFriendsGtkDeviceRow *this_computer(SZFriendsGtkProfileDevicesView *view) {
    const SZFriendsGtkProfileDevices *devices = devices_of(view);
    for (gsize i = 0; devices && i < devices->n_rows; i++)
        if (devices->rows[i].this_computer && devices->rows[i].rename) return &devices->rows[i];
    return NULL;
}

char *szfriends_gtk_utf8_prefix(const char *text, gsize max_bytes) {
    if (!text) return g_strdup("");
    if (strlen(text) <= max_bytes) return g_strdup(text);
    const char *end = text;
    while (*end) {
        const char *next = g_utf8_next_char(end);
        if ((gsize)(next - text) > max_bytes) break;
        end = next;
    }
    return g_strndup(text, (gsize)(end - text));
}

static void set_renaming(SZFriendsGtkProfileDevicesView *view, gboolean renaming) {
    view->renaming = renaming;
    gtk_widget_set_visible(view->parts.rename_box, renaming);
    gtk_widget_set_visible(view->parts.rename_button, !renaming && this_computer(view) != NULL);
    if (!renaming) szfriends_gtk_details_label_set(view->parts.rename_error, NULL);
}

void szfriends_gtk_profile_devices_begin_rename(GtkWidget *box) {
    SZFriendsGtkProfileDevicesView *view = view_of(box);
    const SZFriendsGtkDeviceRow *row = view ? this_computer(view) : NULL;
    if (!row || view->renaming) return;
    gtk_editable_set_text(GTK_EDITABLE(view->parts.rename_entry), row->name);
    set_renaming(view, TRUE);
    gtk_widget_grab_focus(view->parts.rename_entry);
}

static void renamed(SZFriendsGtkPage *page, JsonObject *result, const SZFriendsGtkError *error) {
    (void)page, (void)result;
    /* The reply finds the view through the page's profile box, which may have gone meanwhile. */
    GtkWidget *box = g_object_get_data(G_OBJECT(szfriends_gtk_page_get_widget(page)), "szfriends-devices-box");
    SZFriendsGtkProfileDevicesView *view = view_of(box);
    if (!view) return;
    gtk_widget_set_sensitive(view->parts.save_button, TRUE);
    if (!error) {
        set_renaming(view, FALSE);
        return;
    }
    szfriends_gtk_details_label_set(view->parts.rename_error, error->message);
    szfriends_gtk_details_announce(view->parts.rename_error, error->message);
}

void szfriends_gtk_profile_devices_save(GtkWidget *box) {
    SZFriendsGtkProfileDevicesView *view = view_of(box);
    if (!view || !view->renaming) return;
    gtk_widget_set_sensitive(view->parts.save_button, FALSE);
    const char *name = gtk_editable_get_text(GTK_EDITABLE(view->parts.rename_entry));
    szfriends_gtk_details_send(view->page, szfriends_intent_rename_device(name), renamed);
}

gboolean szfriends_gtk_profile_devices_escape(GtkWidget *box) {
    SZFriendsGtkProfileDevicesView *view = view_of(box);
    if (!view) return FALSE;
    if (view->renaming) {
        set_renaming(view, FALSE);
        return TRUE;
    }
    return szfriends_gtk_details_disarm(view->parts.rows);
}

/* The helper takes at most max_bytes of UTF-8: what does not fit is never typed rather than refused later. */
static void rename_changed(GtkEditable *entry, gpointer data) {
    SZFriendsGtkProfileDevicesView *view = data;
    const SZFriendsGtkDeviceRow *row = this_computer(view);
    gsize max = row && row->rename->max_bytes > 0 ? (gsize)row->rename->max_bytes : 64;
    const char *text = gtk_editable_get_text(entry);
    if (strlen(text) <= max) return;
    char *fitting = szfriends_gtk_utf8_prefix(text, max);
    gtk_editable_set_text(entry, fitting);
    gtk_editable_set_position(entry, -1);
    g_free(fitting);
}

static void rename_clicked(GtkButton *button, gpointer data) {
    (void)button;
    szfriends_gtk_profile_devices_begin_rename(data);
}

static void save_clicked(GtkWidget *widget, gpointer data) {
    (void)widget;
    szfriends_gtk_profile_devices_save(data);
}

static void view_free(gpointer data) {
    SZFriendsGtkProfileDevicesView *view = data;
    g_clear_pointer(&view->held, szfriends_gtk_details_held_unref);
    g_object_unref(view->parts.rename_button);
    g_object_unref(view->parts.rename_box);
    g_free(view);
}

GtkWidget *szfriends_gtk_profile_devices_new(SZFriendsGtkPage *page) {
    SZFriendsGtkProfileDevicesView *view = g_new0(SZFriendsGtkProfileDevicesView, 1);
    view->page = page;
    SZFriendsGtkProfileDevicesParts *parts = &view->parts;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_name(box, "szfriends.profile.devices");
    g_object_set_data_full(G_OBJECT(box), "szfriends-devices", view, view_free);
    g_object_set_data(G_OBJECT(szfriends_gtk_page_get_widget(page)), "szfriends-devices-box", box);
    parts->title = szfriends_gtk_details_label("heading");
    parts->rows = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    parts->rename_button = gtk_button_new_with_label("");
    for (const char *const *name = (const char *const[]){"flat", "accent", "szfriends-text-action", NULL}; *name;
         name++)
        gtk_widget_add_css_class(parts->rename_button, *name);
    gtk_widget_set_valign(parts->rename_button, GTK_ALIGN_CENTER);
    gtk_widget_set_name(parts->rename_button, "szfriends.profile.devices.rename");
    g_signal_connect(parts->rename_button, "clicked", G_CALLBACK(rename_clicked), box);
    g_object_ref_sink(parts->rename_button); /* moved into this computer's row at each snapshot */
    parts->rename_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    GtkWidget *field = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    parts->rename_entry = gtk_entry_new();
    gtk_widget_set_hexpand(parts->rename_entry, TRUE);
    g_signal_connect(parts->rename_entry, "changed", G_CALLBACK(rename_changed), view);
    g_signal_connect(parts->rename_entry, "activate", G_CALLBACK(save_clicked), box);
    parts->save_button = gtk_button_new_with_label("");
    gtk_widget_add_css_class(parts->save_button, "suggested-action");
    g_signal_connect(parts->save_button, "clicked", G_CALLBACK(save_clicked), box);
    gtk_box_append(GTK_BOX(field), parts->rename_entry);
    gtk_box_append(GTK_BOX(field), parts->save_button);
    parts->rename_error = szfriends_gtk_details_label("error");
    gtk_box_append(GTK_BOX(parts->rename_box), field);
    gtk_box_append(GTK_BOX(parts->rename_box), parts->rename_error);
    gtk_widget_set_visible(parts->rename_box, FALSE);
    g_object_ref_sink(parts->rename_box); /* placed under this computer's row at each snapshot */
    parts->note = szfriends_gtk_details_label("szfriends-secondary");
    for (GtkWidget **child = (GtkWidget *[]){parts->title, parts->rows, parts->note, NULL}; *child; child++)
        gtk_box_append(GTK_BOX(box), *child);
    gtk_widget_set_visible(box, FALSE);
    return box;
}

/* One computer: a dot by its state, the name (this computer's in bold) over its system and last connection, and
 * Remove… or Rename at the trailing edge. The name and the line under it wrap rather than truncate. */
static GtkWidget *device_row(SZFriendsGtkProfileDevicesView *view, const SZFriendsGtkDeviceRow *row) {
    GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_accessible_update_property(GTK_ACCESSIBLE(line), GTK_ACCESSIBLE_PROPERTY_LABEL, row->accessibility_label, -1);
    GtkWidget *dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(dot, "szfriends-device-dot");
    if (row->state == SZFRIENDS_GTK_DEVICE_CONNECTED) gtk_widget_add_css_class(dot, "connected");
    gtk_widget_set_valign(dot, GTK_ALIGN_START);
    gtk_widget_set_margin_top(dot, 5);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    gtk_widget_set_hexpand(text, TRUE);
    GtkWidget *name = szfriends_gtk_details_label(row->this_computer ? "heading" : NULL);
    gtk_widget_set_name(name, "szfriends.profile.devices.name");
    szfriends_gtk_details_label_set(name, row->name);
    GtkWidget *detail = szfriends_gtk_details_label("szfriends-secondary");
    gtk_widget_set_name(detail, "szfriends.profile.devices.detail");
    szfriends_gtk_details_label_set(detail, row->detail);
    gtk_box_append(GTK_BOX(text), name);
    gtk_box_append(GTK_BOX(text), detail);
    gtk_box_append(GTK_BOX(line), dot);
    gtk_box_append(GTK_BOX(line), text);
    if (row->remove) {
        GtkWidget *remove = szfriends_gtk_details_button_new(view->page, view->held, row->remove, NULL);
        if (remove) {
            gtk_widget_set_valign(remove, GTK_ALIGN_CENTER);
            gtk_widget_set_name(remove, "szfriends.profile.devices.remove");
            char *spoken = g_strdup_printf("%s, %s", row->remove->label, row->name);
            gtk_accessible_update_property(GTK_ACCESSIBLE(remove), GTK_ACCESSIBLE_PROPERTY_LABEL, spoken, -1);
            g_free(spoken);
            gtk_box_append(GTK_BOX(line), remove);
        }
    } else if (row->this_computer && row->rename) {
        gtk_box_append(GTK_BOX(line), view->parts.rename_button);
    }
    return line;
}

void szfriends_gtk_profile_devices_apply(GtkWidget *box, SZFriendsGtkDetailsHeld *held) {
    SZFriendsGtkProfileDevicesView *view = view_of(box);
    if (!view) return;
    SZFriendsGtkDetailsHeld *previous = view->held;
    view->held = held ? szfriends_gtk_details_held_ref(held) : NULL;
    const SZFriendsGtkProfileDevices *devices = devices_of(view);
    SZFriendsGtkProfileDevicesParts *parts = &view->parts;
    gtk_widget_set_visible(box, devices != NULL);
    GtkWidget *child;
    GtkWidget *rename_parent = gtk_widget_get_parent(parts->rename_button);
    if (rename_parent) gtk_box_remove(GTK_BOX(rename_parent), parts->rename_button);
    if (gtk_widget_get_parent(parts->rename_box)) gtk_box_remove(GTK_BOX(parts->rows), parts->rename_box);
    while ((child = gtk_widget_get_first_child(parts->rows))) gtk_box_remove(GTK_BOX(parts->rows), child);
    const SZFriendsGtkDeviceRow *here = this_computer(view);
    if (devices) {
        szfriends_gtk_details_label_set(parts->title, devices->title);
        szfriends_gtk_details_label_set(parts->note, devices->note);
        for (gsize i = 0; i < devices->n_rows; i++) {
            gtk_box_append(GTK_BOX(parts->rows), device_row(view, &devices->rows[i]));
            if (&devices->rows[i] == here) gtk_box_append(GTK_BOX(parts->rows), parts->rename_box);
        }
    }
    if (here) {
        gtk_button_set_label(GTK_BUTTON(parts->rename_button), here->rename->label);
        gtk_entry_set_placeholder_text(GTK_ENTRY(parts->rename_entry), here->rename->placeholder);
        gtk_accessible_update_property(GTK_ACCESSIBLE(parts->rename_entry), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                       here->rename->placeholder, -1);
        gtk_button_set_label(GTK_BUTTON(parts->save_button), here->rename->button_label);
    }
    set_renaming(view, view->renaming && here != NULL);
    if (previous) szfriends_gtk_details_held_unref(previous);
}

const SZFriendsGtkProfileDevicesParts *szfriends_gtk_profile_devices_parts(GtkWidget *box) {
    SZFriendsGtkProfileDevicesView *view = view_of(box);
    return view ? &view->parts : NULL;
}
