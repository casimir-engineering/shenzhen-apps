/* Shenzhen Friends GTK views: declarations shared between the files of gtk/ (internal; not for hosts or pages). */

#ifndef SZFRIENDS_GTK_INTERNAL_H
#define SZFRIENDS_GTK_INTERNAL_H

#include "gtk/szfriends_gtk_dropdown.h"

G_BEGIN_DECLS

/* The gresource (szfriends_gtk.gresource.xml): the two-people icon and the stylesheet. */
#define SZFRIENDS_GTK_RESOURCE_PREFIX "/com/intuition/shenzhenfriends/gtk"
#define SZFRIENDS_GTK_ICON_PEOPLE "szfriends-people-symbolic"

/* szfriends_gtk_link.c */
char *szfriends_gtk_bcp47_locale(const char *posix);
void szfriends_gtk_link_watch_free(gpointer watch);

/* szfriends_gtk_page.c */
void szfriends_gtk_pages_unregister(SZFriendsGtkLink *link);
SZFriendsGtkPage *szfriends_gtk_page_new(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown,
                                         SZFriendsGtkPageKind kind, const char *argument, const char *message_id);
void szfriends_gtk_page_set_presented(SZFriendsGtkPage *page, gboolean presented);
gboolean szfriends_gtk_page_escape(SZFriendsGtkPage *page);
/* The same conversation asked for again with a message to highlight: re-presents it with that message. */
void szfriends_gtk_page_highlight(SZFriendsGtkPage *page, const char *message_id);
SZFriendsGtkPage *szfriends_gtk_page_from_widget(GtkWidget *navigation_page);

/* szfriends_gtk_pages_builtin.c: the builders every link starts with (the views' own pages). */
void szfriends_gtk_pages_register_builtin(SZFriendsGtkLink *link);
/* szfriends_gtk_link_card.c: the link page. */
void szfriends_gtk_link_card_register(SZFriendsGtkLink *link);

/* szfriends_gtk_style.c: registers the resource, the icon path and the stylesheets once per display; the host's
 * appearance_css loads after the views' own so its @define-color wins. */
void szfriends_gtk_style_ensure(GdkDisplay *display, const SZFriendsGtkHost *host);
GResource *szfriends_gtk_resource(void);

/* szfriends_gtk_dropdown.c: created with the button, freed with it. */
SZFriendsGtkDropdown *szfriends_gtk_dropdown_new(SZFriendsGtkLink *link, GtkWindow *window, GtkWidget *anchor,
                                                 GtkMenuButton *menu_button);
void szfriends_gtk_dropdown_free(SZFriendsGtkDropdown *dropdown);
/* GtkMenuButton's create-popup hook: everything opening does, before the button shows its popover. */
void szfriends_gtk_dropdown_prepare_open(SZFriendsGtkDropdown *dropdown);

/* szfriends_gtk_focus.c: set_focus (PROTOCOL.md § Notifications). The focused conversation is the one a dropdown
 * shows while it is open on a conversation page in the active window; none otherwise. It is sent only when it
 * changes, only to a helper announcing `notifications`, and again after a reconnect when there is one. */
void szfriends_gtk_focus_add_dropdown(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_focus_remove_dropdown(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown);
void szfriends_gtk_focus_update(SZFriendsGtkLink *link);
/* READY (TRUE) or leaving it (FALSE): the helper's value went with the old connection. */
void szfriends_gtk_focus_connected(SZFriendsGtkLink *link, gboolean ready);
void szfriends_gtk_focus_clear(SZFriendsGtkLink *link);
/* Tests: what counts as the active window, since a window never mapped is never active. NULL: gtk_window_is_active.
 * After changing the answer, notify the window's "is-active" as GTK does. */
void szfriends_gtk_focus_set_active_func(gboolean (*is_active)(GtkWindow *window));
/* The conversation set_focus last named on this connection, NULL for none. */
const char *szfriends_gtk_focus_sent(SZFriendsGtkLink *link);

/* szfriends_gtk_button.c: what its drop controllers call, open to the suite so it can drive a drag without one. */
void szfriends_gtk_button_drag_enter(GtkWidget *anchor, GdkDrop *drop); /* starts the 500 ms spring */
void szfriends_gtk_button_drag_value(GtkWidget *anchor, const GValue *value);
void szfriends_gtk_button_drag_leave(GtkWidget *anchor);
gboolean szfriends_gtk_button_drop(GtkWidget *anchor, const GValue *value);
GtkWidget *szfriends_gtk_button_get_menu_button(GtkWidget *anchor);
GtkWidget *szfriends_gtk_button_get_badge(GtkWidget *anchor);
gboolean szfriends_gtk_button_is_highlighted(GtkWidget *anchor);
void szfriends_gtk_button_set_spring_delay(GtkWidget *anchor, guint milliseconds);

G_END_DECLS

#endif /* SZFRIENDS_GTK_INTERNAL_H */
