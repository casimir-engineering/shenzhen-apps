/* Shenzhen Friends GTK dropdown internals, shared by szfriends_gtk_dropdown.c (the popover and navigation) and
 * szfriends_gtk_dropdown_state.c (per-window state). Not for pages. */

#ifndef SZFRIENDS_GTK_DROPDOWN_PRIVATE_H
#define SZFRIENDS_GTK_DROPDOWN_PRIVATE_H

#include "gtk/szfriends_gtk_drops.h"
#include "gtk/szfriends_gtk_internal.h"

#include <adwaita.h>

G_BEGIN_DECLS

typedef struct {
    guint id;
    GCallback func;
    gpointer user_data;
} SZFriendsGtkDropdownWatch;

struct _SZFriendsGtkDropdown {
    SZFriendsGtkLink *link;
    GtkWindow *window;
    GtkWidget *anchor;       /* what the host placed: the button and its badge */
    GtkMenuButton *menu_button;
    GtkWidget *popover;      /* the app's presenter: made on first open */
    GtkWidget *content, *nav, *status, *overlay;
    GtkGesture *outside_click;
    SZFriendsGtkPage *presented_page; /* weak through its widget */
    SZFriendsGtkPresenter presenter;
    gpointer presenter_data;
    gboolean open;
    GHashTable *drafts, *scroll;
    GPtrArray *send_items;
    char *send_title, *drop_hint;
    GArray *watches;
    guint next_watch, state_watch;
};

/* Runs every watch: the send picker or the drop hint changed. */
void szfriends_gtk_dropdown_notify(SZFriendsGtkDropdown *dropdown);

G_END_DECLS

#endif /* SZFRIENDS_GTK_DROPDOWN_PRIVATE_H */
