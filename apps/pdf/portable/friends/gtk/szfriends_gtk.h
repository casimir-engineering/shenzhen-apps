/* Shenzhen Friends GTK views: what a GTK host (Shenzhen Files) calls. The host's contract is szfriends_gtk_host.h.
 *
 * GTK 4.22, libadwaita 1.9 and json-glib, C. The views render PROTOCOL.md snapshots and send intents only through
 * client/szfriends_client.h; they never include service/, mac/ or AppKit (tests/containment-check.sh). Link
 * libszfriends_gtk.a (views, client library, cJSON) with `pkg-config --libs gtk4 libadwaita-1 json-glib-1.0`.
 *
 * Lifecycle in a host, all on the main thread:
 *   launch          szfriends_set_signing_policy() (team-signed builds), then, while Friends is on,
 *                   szfriends_gtk_spawn_helper_async(): connect-or-spawn on a worker thread, never waited for.
 *   first window    link = szfriends_gtk_link_new(&host); szfriends_gtk_link_start(link); after it has mapped, so
 *                   nothing of Friends runs before first paint.
 *   each window     szfriends_gtk_link_add_window(link, window): one Friends button, handed to install_button.
 *   Friends off     szfriends_gtk_link_stop(link, TRUE): sends `disable`, removes every button.
 *   shutdown        szfriends_gtk_link_free(link). */

#ifndef SZFRIENDS_GTK_H
#define SZFRIENDS_GTK_H

#include "gtk/szfriends_gtk_host.h"

G_BEGIN_DECLS

typedef struct _SZFriendsGtkLink SZFriendsGtkLink;

/* Connect-or-spawn for the embedded helper (ADR 0002) on a GTask worker thread, never the calling thread: the
 * client library refuses the main thread on macOS, and launch may not wait for Friends. Returns at once. */
void szfriends_gtk_spawn_helper_async(const char *helper_path);

/* One link per process: every window's button shares it (Nautilus windows live in one process). Copies `host`
 * (strings included), so the host may free its own copy. NULL when a required member is missing or struct_size is
 * below SZFRIENDS_GTK_HOST_MIN_SIZE. */
SZFriendsGtkLink *szfriends_gtk_link_new(const SZFriendsGtkHost *host);
/* Connects from the main loop: watches the client's descriptor and runs its timers. */
void szfriends_gtk_link_start(SZFriendsGtkLink *link);
/* Disconnects. friends_disabled: the person turned Friends off in this app, so `disable` goes first (the helper
 * exits when no other app needs it) and every button installed through add_window is removed. Intents waiting for
 * their replies get connection_lost. */
void szfriends_gtk_link_stop(SZFriendsGtkLink *link, gboolean friends_disabled);
/* Stops without sending `disable` and frees. Replies still waiting are dropped without being called. Free it after
 * the windows and buttons it served: a page leaving the screen releases its subscriptions through the link. */
void szfriends_gtk_link_free(SZFriendsGtkLink *link);

/* The Friends button for `window`: icon, badge, drop target, and the window's own dropdown. The host places it
 * (or uses add_window); destroying the button releases that window's dropdown. */
GtkWidget *szfriends_gtk_button_new(SZFriendsGtkLink *link, GtkWindow *window);
/* Creates `window`'s button and hands it to host->install_button; once per window, forgotten when the window is
 * destroyed. remove_window hands it to host->remove_button. */
void szfriends_gtk_link_add_window(SZFriendsGtkLink *link, GtkWindow *window);
void szfriends_gtk_link_remove_window(SZFriendsGtkLink *link, GtkWindow *window);

/* The Friends section of the host's Settings while Friends is on (the `settings` view), as a widget to place in an
 * AdwPreferencesPage. The host adds its own "Enable Shenzhen Friends" switch and disclosure beside it. */
GtkWidget *szfriends_gtk_settings_section_new(SZFriendsGtkLink *link);

/* ---- Links (PROTOCOL.md § Links) ----------------------------------------------------------------------- */

/* Defined while these views have links, so a host built against an older copy of them compiles without its link
 * items. */
#define SZFRIENDS_GTK_LINKS 1

/* TRUE while the helper is connected and announces "links": only then may a host offer Copy Download Link. */
gboolean szfriends_gtk_link_offers_links(SZFriendsGtkLink *link);
/* Opens the dropdown of `window` (added with link_add_window; NULL: the first window) on the link page, for the
 * payload of <scheme>://friends/link#<payload> after the host's own strict check. The page asks the helper and acts
 * only when the person presses one of the card's buttons. */
void szfriends_gtk_show_link(SZFriendsGtkLink *link, GtkWindow *window, const char *payload);
/* Copy Download Link for `item`, valid `days` (1, 7 or 30): make_download_link, then the link on the clipboard of
 * `source`'s display. `done` runs once with the words to show (the helper's message, or its error's; NULL when it gave
 * none) and whether the link was copied. */
typedef void (*SZFriendsGtkLinkCopied)(const char *message, gboolean copied, gpointer data);
void szfriends_gtk_copy_download_link(SZFriendsGtkLink *link, GtkWidget *source, const SZFriendsGtkHostItem *item,
                                      int days, SZFriendsGtkLinkCopied done, gpointer data);

G_END_DECLS

#endif /* SZFRIENDS_GTK_H */
