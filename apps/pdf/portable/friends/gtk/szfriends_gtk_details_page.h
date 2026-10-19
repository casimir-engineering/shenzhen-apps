/* Shenzhen Friends GTK views: a friend's details, your profile and the Settings section, and the action buttons they
 * draw PROTOCOL.md action objects with (internal to gtk/).
 *
 * Mirrors mac/SZFriendsDetailsPage.h, mac/SZFriendsProfilePage.m and mac/SZFriendsSettingsSection.h:
 *   - details: route, ID with Copy and the server's check, verification with comparison codes, a changed key, "Accept
 *     files from Mei automatically", received files, Remove (asks first) and Block (a second, separate click);
 *   - profile: the name friends see, the animal set and your own photo cropped to the circle, your ID with Copy (and
 *     its QR once the helper sends one), and adding someone by ID;
 *   - the Settings section: the `settings` snapshot as AdwPreferencesGroup rows, for the host's Settings window.
 * Every string comes from a snapshot or welcome.strings and is set as plain text: rows get use-markup FALSE. */

#ifndef SZFRIENDS_GTK_DETAILS_PAGE_H
#define SZFRIENDS_GTK_DETAILS_PAGE_H

#include "gtk/szfriends_gtk_list_page.h" /* every page's seams, confirmation, perform and arming */

G_BEGIN_DECLS

/* The page builders, registered by szfriends_gtk_pages_builtin.c. */
void szfriends_gtk_details_page_register(SZFriendsGtkLink *link);
void szfriends_gtk_profile_page_register(SZFriendsGtkLink *link);
void szfriends_gtk_settings_section_register(SZFriendsGtkLink *link);

/* ---- Copy, announcements and replies (szfriends_gtk_details_actions.c) ------------------------------------ */

/* Copies `text` and says so (welcome.strings `copied`) to assistive technology and, for a moment, on `button`. */
void szfriends_gtk_details_copy(SZFriendsGtkPage *page, GtkWidget *button, const char *text);
/* Speaks `text` (an answer that appears away from where the person is looking). */
void szfriends_gtk_details_announce(GtkWidget *widget, const char *text);

/* What the profile and Settings send, display-free: set_name only when the typed name differs from the snapshot's
 * (leaving the field unchanged sends nothing); add_by_id with the typed ID trimmed, NULL when nothing is left. */
szfriends_intent *szfriends_gtk_details_name_intent(const char *typed, const char *current);
szfriends_intent *szfriends_gtk_details_add_intent(const char *typed);

/* ---- Action buttons (szfriends_gtk_details_buttons.c) --------------------------------------------------------- */

/* A parsed snapshot shared by the widgets drawn from it: a button keeps the snapshot its action lives in, so an
 * unchanged button (its armed pill, its focus) survives the next snapshot. */
typedef struct _SZFriendsGtkDetailsHeld SZFriendsGtkDetailsHeld;
/* Takes `value`, freed with `type` when the last reference goes. */
SZFriendsGtkDetailsHeld *szfriends_gtk_details_held_new(const SZFriendsGtkType *type, gpointer value);
SZFriendsGtkDetailsHeld *szfriends_gtk_details_held_ref(SZFriendsGtkDetailsHeld *held);
void szfriends_gtk_details_held_unref(SZFriendsGtkDetailsHeld *held);
gpointer szfriends_gtk_details_held_value(SZFriendsGtkDetailsHeld *held);

/* Your links in the profile (szfriends_gtk_profile_links.c): hidden until a snapshot has `links`. `held` holds the
 * profile snapshot. */
GtkWidget *szfriends_gtk_profile_links_new(SZFriendsGtkPage *page);
void szfriends_gtk_profile_links_apply(GtkWidget *links, SZFriendsGtkDetailsHeld *held);

/* A button for one action object: its label and style, its `arm` (the shared rule of szfriends_gtk_row.h, on its
 * clock: the first click arms, a second separate click within arm.seconds sends, never a double-click's second half;
 * leaving the button or Escape turns it back) and its `confirm` (szfriends_gtk_confirm: a card over the dropdown, or
 * the system's dialog in Settings). NULL for an action this view does not know. Link and destructive styles are flat
 * text actions that start at the column's edge (.szfriends-text-action). */
GtkWidget *szfriends_gtk_details_button_new(SZFriendsGtkPage *page, SZFriendsGtkDetailsHeld *held,
                                            const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids);
/* TRUE when `button` draws the same action for the same ids, so it can stay. */
gboolean szfriends_gtk_details_button_matches(GtkWidget *button, const SZFriendsGtkAction *action,
                                              const SZFriendsGtkActionIds *ids);
gboolean szfriends_gtk_details_button_is_armed(GtkWidget *button);
/* Turns back every armed action button under `root`; TRUE when one was armed. Escape does this first, since
 * closing the dropdown under a "Block?" would leave the person unsure whether they blocked someone. */
gboolean szfriends_gtk_details_disarm(GtkWidget *root);

/* Sends `intent` (consumed) for `page`; `func` (optional) hears the reply only while the page still exists. */
typedef void (*SZFriendsGtkDetailsReply)(SZFriendsGtkPage *page, JsonObject *result, const SZFriendsGtkError *error);
guint szfriends_gtk_details_send(SZFriendsGtkPage *page, szfriends_intent *intent, SZFriendsGtkDetailsReply func);

/* A wrapping plain-text label with style `classes` ("szfriends-secondary", "heading", or NULL), hidden while its text
 * is empty. Secondary text is .szfriends-secondary or .szfriends-caption, never libadwaita's .dimmed (3.2:1). */
GtkWidget *szfriends_gtk_details_label(const char *classes);
void szfriends_gtk_details_label_set(GtkWidget *label, const char *text);

G_END_DECLS

#endif /* SZFRIENDS_GTK_DETAILS_PAGE_H */
