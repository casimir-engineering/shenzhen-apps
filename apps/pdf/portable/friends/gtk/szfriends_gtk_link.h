/* Shenzhen Friends GTK views: the link as the views see it (internal to gtk/; hosts use szfriends_gtk.h).
 *
 * Wraps client/szfriends_client.h on the GLib main loop, like mac/SZFriendsHelperLink.h on the main run loop:
 *   - one client per process; its descriptor is watched with g_unix_fd_add_full and re-armed on every state change,
 *     because the descriptor changes across reconnects; a timeout fires when szfriends_client_next_tick_ms() says;
 *   - library callbacks are queued and handled after the library call returns, so a handler may subscribe, send or
 *     stop without re-entering the library;
 *   - subscriptions keep a local token across reconnects: after every READY each is sent again (with its filter and
 *     load_earlier count), because helper subscription ids never survive a reconnect (PROTOCOL.md § Lifecycle);
 *   - replies are routed by frame id and every reply function runs exactly once: with the helper's reply, with
 *     not_ready when sent while not READY (on an idle, never re-entrantly), or with connection_lost when the
 *     connection drops first. Client-side errors carry the connection line as their message.
 * Everything runs on the main context's thread. */

#ifndef SZFRIENDS_GTK_LINK_H
#define SZFRIENDS_GTK_LINK_H

#include "gtk/szfriends_gtk.h"
#include "gtk/szfriends_gtk_snapshot.h"

#include "client/szfriends_client.h"

G_BEGIN_DECLS

typedef enum {
    SZFRIENDS_GTK_LINK_IDLE,
    SZFRIENDS_GTK_LINK_CONNECTING,
    SZFRIENDS_GTK_LINK_READY,
    SZFRIENDS_GTK_LINK_WAITING,     /* reconnecting: views keep their last snapshot and show the status line */
    SZFRIENDS_GTK_LINK_INCOMPATIBLE
} SZFriendsGtkLinkState;

/* `data` is the snapshot's data object, valid during the call (ref it to keep it). */
typedef void (*SZFriendsGtkSnapshotFunc)(JsonObject *data, gint64 rev, gpointer user_data);
/* Exactly one of `result` (the reply's result object) and `error` is set. Both are valid during the call. */
typedef void (*SZFriendsGtkReplyFunc)(JsonObject *result, const SZFriendsGtkError *error, gpointer user_data);
typedef void (*SZFriendsGtkStateFunc)(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer user_data);
typedef void (*SZFriendsGtkBadgeFunc)(SZFriendsGtkLink *link, const SZFriendsGtkBadgeSnapshot *badge,
                                      gpointer user_data);

SZFriendsGtkLinkState szfriends_gtk_link_get_state(SZFriendsGtkLink *link);
/* The client library's line while not READY ("Starting Friends…"), naming the app when the person must act; NULL
 * when READY or idle, where nothing needs saying. */
const char *szfriends_gtk_link_status_text(SZFriendsGtkLink *link);
/* welcome.strings (PROTOCOL.md § Static strings); "" when absent, so a view shows nothing rather than invent text. */
const char *szfriends_gtk_link_string(SZFriendsGtkLink *link, const char *key);
gboolean szfriends_gtk_link_helper_has_capability(SZFriendsGtkLink *link, const char *capability);
/* The host as copied at link_new (members past the host's struct_size are NULL). */
const SZFriendsGtkHost *szfriends_gtk_link_host(SZFriendsGtkLink *link);

/* Subscriptions. The token stays valid across reconnects until unsubscribed; `destroy` runs on unsubscribe or
 * link_free. open_conversation also marks the conversation read while subscribed: hold it only while on screen. */
guint szfriends_gtk_link_subscribe(SZFriendsGtkLink *link, const char *view, const char *conversation_id,
                                   SZFriendsGtkSnapshotFunc func, gpointer user_data, GDestroyNotify destroy);
guint szfriends_gtk_link_subscribe_message_status(SZFriendsGtkLink *link, const char *const *message_ids,
                                                  gsize count, SZFriendsGtkSnapshotFunc func, gpointer user_data,
                                                  GDestroyNotify destroy);
guint szfriends_gtk_link_open_conversation(SZFriendsGtkLink *link, const char *conversation_id,
                                           const char *message_id, SZFriendsGtkSnapshotFunc func, gpointer user_data,
                                           GDestroyNotify destroy);
void szfriends_gtk_link_set_filter(SZFriendsGtkLink *link, guint token, const char *query);
void szfriends_gtk_link_load_earlier(SZFriendsGtkLink *link, guint token);
void szfriends_gtk_link_unsubscribe(SZFriendsGtkLink *link, guint token);

/* Sends `intent` (consumed; NULL fails as invalid_field). Returns a request id for forget_reply, never 0. */
guint szfriends_gtk_link_send(SZFriendsGtkLink *link, szfriends_intent *intent, SZFriendsGtkReplyFunc func,
                              gpointer user_data, GDestroyNotify destroy);
/* A page going away: its reply function will not run; `destroy` runs now. */
void szfriends_gtk_link_forget_reply(SZFriendsGtkLink *link, guint request);

guint szfriends_gtk_link_add_state_watch(SZFriendsGtkLink *link, SZFriendsGtkStateFunc func, gpointer user_data,
                                         GDestroyNotify destroy);
void szfriends_gtk_link_remove_state_watch(SZFriendsGtkLink *link, guint watch);

/* The badge every button shows, from one `badge` subscription the link holds for all windows (the helper limits
 * subscriptions per connection). NULL before the first snapshot. Watches run after each change. */
const SZFriendsGtkBadgeSnapshot *szfriends_gtk_link_badge(SZFriendsGtkLink *link);
guint szfriends_gtk_link_add_badge_watch(SZFriendsGtkLink *link, SZFriendsGtkBadgeFunc func, gpointer user_data);
void szfriends_gtk_link_remove_badge_watch(SZFriendsGtkLink *link, guint watch);

/* For tests: the descriptor currently watched (-1 for none) and the client's own. */
int szfriends_gtk_link_watched_fd(SZFriendsGtkLink *link);
int szfriends_gtk_link_client_fd(SZFriendsGtkLink *link);

G_END_DECLS

#endif /* SZFRIENDS_GTK_LINK_H */
