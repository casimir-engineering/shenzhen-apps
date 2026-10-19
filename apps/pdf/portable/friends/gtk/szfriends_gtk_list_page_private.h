/* The list page's state, shared by szfriends_gtk_list_page.c (tabs, subscriptions, rows) and
 * szfriends_gtk_list_notices.c (what sits above the rows). Not for other pages. */

#ifndef SZFRIENDS_GTK_LIST_PAGE_PRIVATE_H
#define SZFRIENDS_GTK_LIST_PAGE_PRIVATE_H

#include "gtk/szfriends_gtk_list_page.h"

G_BEGIN_DECLS

#define SZFRIENDS_GTK_LIST_MAGIC 0x6c697374u /* the page's data is ours, not a test builder's */

typedef struct {
    guint32 magic;
    SZFriendsGtkListParts parts;
    SZFriendsGtkPage *page;
    SZFriendsGtkLink *link;
    SZFriendsGtkDropdown *dropdown;
    GtkWidget *rows_box, *empty, *friends_scroll, *nearby_scroll;
    SZFriendsGtkListSnapshot *list; /* the latest, read when the banner's button is pressed */
    guint dropdown_watch, state_watch;
} SZFriendsGtkListPage;

/* "Send 2 files to…" or the drop hint, the banner and the name field, in `content` above the rows. */
void szfriends_gtk_list_build_notices(SZFriendsGtkListPage *list, GtkWidget *content);
void szfriends_gtk_list_apply_notices(SZFriendsGtkListPage *list, const SZFriendsGtkListSnapshot *snapshot);
/* The dropdown's watch: the send picker or the drop hint changed. Also fades the rows that refuse files. */
void szfriends_gtk_list_update_send_notice(SZFriendsGtkDropdown *dropdown, gpointer list);
void szfriends_gtk_list_dim_rows(SZFriendsGtkListPage *list);
/* Several computers (szfriends_gtk_list_devices.c): the removed notice and the join requests above the rows, the name
 * prompt's join link; applied after the footer, since a removed computer shows no Add by ID and no Nearby tab. */
void szfriends_gtk_list_build_devices(SZFriendsGtkListPage *list, GtkWidget *content);
void szfriends_gtk_list_apply_devices(SZFriendsGtkListPage *list, JsonObject *data);

G_END_DECLS

#endif /* SZFRIENDS_GTK_LIST_PAGE_PRIVATE_H */
