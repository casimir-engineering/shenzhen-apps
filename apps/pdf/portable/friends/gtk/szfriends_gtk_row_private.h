/* SZFriendsGtkRow's state, shared by szfriends_gtk_row.c (what the row shows, clicks, construction) and
 * szfriends_gtk_row_drops.c (drags and drops, and whose row a press or a drag belongs to). Not for other files. */

#ifndef SZFRIENDS_GTK_ROW_PRIVATE_H
#define SZFRIENDS_GTK_ROW_PRIVATE_H

#include "gtk/szfriends_gtk_row.h"

G_BEGIN_DECLS

#define SZFRIENDS_GTK_TYPE_ROW (szfriends_gtk_row_get_type())
G_DECLARE_FINAL_TYPE(SZFriendsGtkRow, szfriends_gtk_row, SZFRIENDS_GTK, ROW, GtkWidget)

struct _SZFriendsGtkRow {
    GtkWidget parent;
    SZFriendsGtkLink *link;
    SZFriendsGtkRowFacts facts;
    char *conversation_id, *nearby_id, *drop_label, *drop_refusal, *route_label;
    gboolean clickable, dimmed, hovered, value_loaded, refusal_above;
    /* Rows are reused by position: `tenure` counts the people who have held this row, so a press or a drag that
     * began under one person is never completed for the next (security review, wave 6b). */
    guint tenure, press_tenure, drag_tenure;
    gboolean pressing, dragging;
    SZFriendsGtkDropVerdict verdict; /* of the files over the row now; NONE outside a drag */
    SZFriendsGtkRowDrop drop;
    SZFriendsGtkRowLook look;
    GtkWidget *lead, *bar, *dot, *avatar, *title, *check, *subtitle;
    GtkWidget *time_box, *time, *pill, *route, *actions, *accessory, *status, *drop_pill;
    GtkDropTarget *target;
    SZFriendsGtkRowHandlers handlers;
    gpointer handlers_data;
};

/* NULL for anything but a row. */
SZFriendsGtkRow *szfriends_gtk_row_of(GtkWidget *widget);
/* Shows what the facts, the drag and the fade say. */
void szfriends_gtk_row_refresh(SZFriendsGtkRow *row);
/* What a drag over the row means now: nothing once someone else holds the row. */
SZFriendsGtkRowDrop szfriends_gtk_row_drop_now(const SZFriendsGtkRow *row);
/* The drop target and the click gesture's press and release (szfriends_gtk_row_drops.c). */
void szfriends_gtk_row_install_targets(SZFriendsGtkRow *row);

G_END_DECLS

#endif /* SZFRIENDS_GTK_ROW_PRIVATE_H */
