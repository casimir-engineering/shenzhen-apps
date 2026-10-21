/* set_focus (PROTOCOL.md § Notifications; szfriends_gtk_internal.h): the helper posts no notification for the
 * conversation the person is looking at. That is the conversation a window's dropdown shows while it is open on a
 * conversation page and the window is the active one; closing the dropdown, going to another page or switching to
 * another window or app makes it none. The link sends each change once, only to a helper announcing `notifications`,
 * and names it again after a reconnect, since the helper drops it with the connection. */

#include "gtk/szfriends_gtk_dropdown_private.h"
#include "gtk/szfriends_gtk_link_private.h"

static gboolean (*window_is_active)(GtkWindow *window) = gtk_window_is_active;

void szfriends_gtk_focus_set_active_func(gboolean (*is_active)(GtkWindow *window)) {
    window_is_active = is_active ? is_active : gtk_window_is_active;
}

/* The conversation `dropdown` shows to the person now, or NULL. */
static const char *shown_conversation(SZFriendsGtkDropdown *dropdown) {
    SZFriendsGtkPage *page = dropdown->open ? dropdown->presented_page : NULL;
    if (!page || !dropdown->window || !window_is_active(dropdown->window)) return NULL;
    if (szfriends_gtk_page_get_kind(page) != SZFRIENDS_GTK_PAGE_CONVERSATION) return NULL;
    return szfriends_gtk_page_get_argument(page);
}

void szfriends_gtk_focus_update(SZFriendsGtkLink *link) {
    if (!link || link->closed || link->state != SZFRIENDS_GTK_LINK_READY ||
        !szfriends_gtk_link_helper_has_capability(link, "notifications"))
        return;
    const char *focused = NULL;
    for (guint i = 0; link->focus_dropdowns && i < link->focus_dropdowns->len && !focused; i++)
        focused = shown_conversation(g_ptr_array_index(link->focus_dropdowns, i));
    if (!g_strcmp0(focused, link->focus_sent)) return;
    g_free(link->focus_sent);
    link->focus_sent = g_strdup(focused);
    szfriends_gtk_link_send(link, szfriends_intent_set_focus(focused), NULL, NULL, NULL);
}

void szfriends_gtk_focus_connected(SZFriendsGtkLink *link, gboolean ready) {
    g_clear_pointer(&link->focus_sent, g_free); /* a new connection starts with no focus */
    if (ready) szfriends_gtk_focus_update(link);
}

const char *szfriends_gtk_focus_sent(SZFriendsGtkLink *link) {
    return link ? link->focus_sent : NULL;
}

static void activity_changed(GObject *window, GParamSpec *pspec, gpointer data) {
    (void)window, (void)pspec;
    SZFriendsGtkDropdown *dropdown = data;
    szfriends_gtk_focus_update(dropdown->link);
}

void szfriends_gtk_focus_add_dropdown(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown) {
    if (!link->focus_dropdowns) link->focus_dropdowns = g_ptr_array_new();
    g_ptr_array_add(link->focus_dropdowns, dropdown);
    if (dropdown->window)
        g_signal_connect(dropdown->window, "notify::is-active", G_CALLBACK(activity_changed), dropdown);
}

void szfriends_gtk_focus_remove_dropdown(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown) {
    if (dropdown->window) g_signal_handlers_disconnect_by_func(dropdown->window, activity_changed, dropdown);
    if (link->focus_dropdowns) g_ptr_array_remove(link->focus_dropdowns, dropdown);
    /* A window closed on a conversation: nothing is shown any more. */
    szfriends_gtk_focus_update(link);
}

void szfriends_gtk_focus_clear(SZFriendsGtkLink *link) {
    g_clear_pointer(&link->focus_dropdowns, g_ptr_array_unref);
    g_clear_pointer(&link->focus_sent, g_free);
}

/* ---- For hosts: where a notification's click goes ------------------------------------------------------------ */

void szfriends_gtk_show_conversation(SZFriendsGtkLink *link, GtkWindow *window, const char *conversation_id) {
    if (!link) return;
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_dropdown_for_button(szfriends_gtk_link_window_button(link, window));
    if (!dropdown) return;
    szfriends_gtk_dropdown_open(dropdown);
    if (conversation_id && *conversation_id) szfriends_gtk_dropdown_open_conversation(dropdown, conversation_id, NULL);
    else szfriends_gtk_dropdown_pop_to_list(dropdown);
}
