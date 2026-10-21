/* Shenzhen Friends GTK views on several computers (internal to gtk/; PROTOCOL.md § Devices, § Joining). Mirrors
 * mac/SZFriendsDevices.h: the join page a new computer shows, and the profile's "Your computers". The list's join rows
 * and removed notice are the list page's (szfriends_gtk_list_page_private.h). Every word comes from a snapshot. */

#ifndef SZFRIENDS_GTK_DEVICES_H
#define SZFRIENDS_GTK_DEVICES_H

#include "gtk/szfriends_gtk_details_page.h"

G_BEGIN_DECLS

/* ---- The join page (szfriends_gtk_join_page.c) ------------------------------------------------------------ */

/* Registers SZFRIENDS_GTK_PAGE_JOIN: the title and message, the Friends ID field while idle, the code field from
 * waiting on (disabled while a code is checked), why the last code did not work or a refused intent's words, and
 * the helper's actions (Cancel, Start again). */
void szfriends_gtk_join_page_register(SZFriendsGtkLink *link);
/* The join page's column, in points: as wide as the dropdown up to this, centred and no wider past it. */
#define SZFRIENDS_GTK_JOIN_COLUMN 400
typedef struct {
    GtkWidget *title, *message, *id_entry, *id_button, *code_entry, *code_button, *error, *actions;
    GtkWidget *route, *route_glyph, *route_label; /* the route line: checking and joined, while a session is live */
    guint snapshots; /* applied so far, so the suite knows a scripted one arrived */
} SZFriendsGtkJoinParts;
const SZFriendsGtkJoinParts *szfriends_gtk_join_page_parts(SZFriendsGtkPage *page); /* NULL for any other page */
/* What Return in each field does: join_profile with the typed ID, enter_join_code with the typed code. */
void szfriends_gtk_join_page_submit_id(SZFriendsGtkPage *page);
void szfriends_gtk_join_page_submit_code(SZFriendsGtkPage *page);

/* ---- Your computers in the profile (szfriends_gtk_profile_devices.c) -------------------------------------- */

/* Hidden until a snapshot has `devices`. Each computer with its name, system and last connection (a dot by its
 * state), Rename on this computer's row and Remove… on the others with the helper's confirmation, then how to add
 * one. `held` holds the profile snapshot. */
GtkWidget *szfriends_gtk_profile_devices_new(SZFriendsGtkPage *page);
void szfriends_gtk_profile_devices_apply(GtkWidget *devices, SZFriendsGtkDetailsHeld *held);
/* Escape: closes the rename field or turns an armed button back; TRUE when it did. */
gboolean szfriends_gtk_profile_devices_escape(GtkWidget *devices);
typedef struct {
    GtkWidget *title, *rows, *note /* how to add one */, *rename_button, *rename_box, *rename_entry, *save_button, *rename_error;
} SZFriendsGtkProfileDevicesParts;
const SZFriendsGtkProfileDevicesParts *szfriends_gtk_profile_devices_parts(GtkWidget *devices);
/* Opens the rename field on this computer's name; Save (or Return) sends rename_device with what was typed. */
void szfriends_gtk_profile_devices_begin_rename(GtkWidget *devices);
void szfriends_gtk_profile_devices_save(GtkWidget *devices);
/* The longest prefix of `text` within `max_bytes` of UTF-8 that ends on a whole character (display-free). */
char *szfriends_gtk_utf8_prefix(const char *text, gsize max_bytes);

G_END_DECLS

#endif /* SZFRIENDS_GTK_DEVICES_H */
