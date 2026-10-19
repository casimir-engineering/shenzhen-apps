/* The page builders every link starts with (szfriends_gtk_internal.h): the list with its Friends and Nearby tabs
 * (szfriends_gtk_list_page.h), a conversation (szfriends_gtk_conversation.h), and a friend's details, your profile and
 * the host's Settings section (szfriends_gtk_details_page.h). The shell around them (navigation, back arrow, title,
 * Escape, lifetimes) is szfriends_gtk_page.c's and the dropdown's.
 *
 * Every kind first gets an empty frame, so a kind added to SZFriendsGtkPageKind before its page exists says nothing
 * rather than words the helper's catalog does not have (README § Four layers). */

#include "gtk/szfriends_gtk_conversation.h"
#include "gtk/szfriends_gtk_details_page.h"
#include "gtk/szfriends_gtk_devices.h"
#include "gtk/szfriends_gtk_internal.h"
#include "gtk/szfriends_gtk_list_page.h"

static void build_empty(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(content, TRUE);
    szfriends_gtk_page_set_content(page, content);
}

void szfriends_gtk_pages_register_builtin(SZFriendsGtkLink *link) {
    static const SZFriendsGtkPageClass empty = {build_empty, NULL, NULL, NULL};
    for (int kind = 0; kind < SZFRIENDS_GTK_PAGE_KIND_COUNT; kind++)
        szfriends_gtk_register_page(link, (SZFriendsGtkPageKind)kind, &empty, NULL);
    szfriends_gtk_register_page(link, SZFRIENDS_GTK_PAGE_LIST, &szfriends_gtk_list_page_class, NULL);
    szfriends_gtk_register_page(link, SZFRIENDS_GTK_PAGE_CONVERSATION, &szfriends_gtk_conversation_page_class, NULL);
    szfriends_gtk_details_page_register(link);
    szfriends_gtk_profile_page_register(link);
    szfriends_gtk_settings_section_register(link);
    szfriends_gtk_link_card_register(link);
    szfriends_gtk_join_page_register(link);
}
