/* Per-window dropdown state: drafts, scroll positions, the send picker, the drop hint and the overlay. Kept in the
 * dropdown, not the pages, so reopening returns to the view left with drafts and scroll kept (brief § Interface). */

#include "gtk/szfriends_gtk_dropdown_private.h"

void szfriends_gtk_dropdown_notify(SZFriendsGtkDropdown *dropdown) {
    for (guint i = 0; i < dropdown->watches->len; i++) {
        SZFriendsGtkDropdownWatch *watch = &g_array_index(dropdown->watches, SZFriendsGtkDropdownWatch, i);
        ((void (*)(SZFriendsGtkDropdown *, gpointer))watch->func)(dropdown, watch->user_data);
    }
}

SZFriendsGtkDropdown *szfriends_gtk_dropdown_for_button(GtkWidget *button) {
    return button ? g_object_get_data(G_OBJECT(button), "szfriends-dropdown") : NULL;
}

SZFriendsGtkLink *szfriends_gtk_dropdown_get_link(SZFriendsGtkDropdown *dropdown) {
    return dropdown->link;
}

GtkWindow *szfriends_gtk_dropdown_get_window(SZFriendsGtkDropdown *dropdown) {
    return dropdown->window;
}

SZFriendsGtkDraft *szfriends_gtk_dropdown_get_draft(SZFriendsGtkDropdown *dropdown, const char *conversation_id) {
    g_return_val_if_fail(conversation_id, NULL);
    SZFriendsGtkDraft *draft = g_hash_table_lookup(dropdown->drafts, conversation_id);
    if (!draft) {
        draft = g_new0(SZFriendsGtkDraft, 1);
        draft->text = g_strdup("");
        draft->items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
        g_hash_table_insert(dropdown->drafts, g_strdup(conversation_id), draft);
    }
    return draft;
}

double szfriends_gtk_dropdown_get_scroll(SZFriendsGtkDropdown *dropdown, const char *key) {
    double *value = key ? g_hash_table_lookup(dropdown->scroll, key) : NULL;
    return value ? *value : 0;
}

void szfriends_gtk_dropdown_set_scroll(SZFriendsGtkDropdown *dropdown, const char *key, double value) {
    if (!key) return;
    double *slot = g_new(double, 1);
    *slot = value;
    g_hash_table_insert(dropdown->scroll, g_strdup(key), slot);
}

void szfriends_gtk_dropdown_begin_send_picker(SZFriendsGtkDropdown *dropdown, GPtrArray *items) {
    if (!items || !items->len) return;
    GPtrArray *copy = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    GPtrArray *names = g_ptr_array_new();
    for (guint i = 0; i < items->len; i++) {
        SZFriendsGtkHostItem *item = g_ptr_array_index(items, i);
        g_ptr_array_add(copy, szfriends_gtk_host_item_copy(item));
        if (item->title && *item->title) g_ptr_array_add(names, item->title);
    }
    char *title = szfriends_gtk_send_picker_title(dropdown->link, (const char *const *)names->pdata, names->len,
                                                  items->len);
    g_ptr_array_free(names, TRUE);
    szfriends_gtk_dropdown_open(dropdown);
    szfriends_gtk_dropdown_pop_to_list(dropdown);
    szfriends_gtk_dropdown_set_drop_hint(dropdown, NULL);
    if (dropdown->send_items) g_ptr_array_unref(dropdown->send_items);
    dropdown->send_items = copy;
    g_free(dropdown->send_title);
    dropdown->send_title = title;
    szfriends_gtk_dropdown_notify(dropdown);
}

GPtrArray *szfriends_gtk_dropdown_get_send_items(SZFriendsGtkDropdown *dropdown) {
    return dropdown->send_items;
}

const char *szfriends_gtk_dropdown_get_send_title(SZFriendsGtkDropdown *dropdown) {
    return dropdown->send_title;
}

void szfriends_gtk_dropdown_finish_send_picker(SZFriendsGtkDropdown *dropdown) {
    if (!dropdown->send_items) return;
    g_clear_pointer(&dropdown->send_items, g_ptr_array_unref);
    g_clear_pointer(&dropdown->send_title, g_free);
    szfriends_gtk_dropdown_notify(dropdown);
}

void szfriends_gtk_dropdown_set_drop_hint(SZFriendsGtkDropdown *dropdown, const char *hint) {
    const char *value = hint && *hint ? hint : NULL;
    if (g_strcmp0(value, dropdown->drop_hint) == 0) return;
    g_free(dropdown->drop_hint);
    dropdown->drop_hint = g_strdup(value);
    szfriends_gtk_dropdown_notify(dropdown);
}

const char *szfriends_gtk_dropdown_get_drop_hint(SZFriendsGtkDropdown *dropdown) {
    return dropdown->drop_hint;
}

guint szfriends_gtk_dropdown_add_watch(SZFriendsGtkDropdown *dropdown, GCallback func, gpointer user_data) {
    SZFriendsGtkDropdownWatch watch = {++dropdown->next_watch, func, user_data};
    g_array_append_val(dropdown->watches, watch);
    return watch.id;
}

void szfriends_gtk_dropdown_remove_watch(SZFriendsGtkDropdown *dropdown, guint id) {
    for (guint i = 0; i < dropdown->watches->len; i++)
        if (g_array_index(dropdown->watches, SZFriendsGtkDropdownWatch, i).id == id) {
            g_array_remove_index(dropdown->watches, i);
            return;
        }
}

void szfriends_gtk_dropdown_set_overlay(SZFriendsGtkDropdown *dropdown, GtkWidget *overlay) {
    if (dropdown->overlay == overlay) return;
    if (dropdown->overlay) gtk_overlay_remove_overlay(GTK_OVERLAY(dropdown->content), dropdown->overlay);
    dropdown->overlay = NULL;
    if (!overlay) return;
    szfriends_gtk_dropdown_get_content(dropdown);
    dropdown->overlay = overlay;
    gtk_overlay_add_overlay(GTK_OVERLAY(dropdown->content), overlay);
}

GtkWidget *szfriends_gtk_dropdown_get_overlay(SZFriendsGtkDropdown *dropdown) {
    return dropdown->overlay;
}
