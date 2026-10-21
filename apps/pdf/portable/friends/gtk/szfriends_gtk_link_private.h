/* Shenzhen Friends GTK link internals, shared by szfriends_gtk_link.c (the client on the main loop) and
 * szfriends_gtk_link_routes.c (subscriptions, replies, the badge). Not for views. */

#ifndef SZFRIENDS_GTK_LINK_PRIVATE_H
#define SZFRIENDS_GTK_LINK_PRIVATE_H

#include "gtk/szfriends_gtk_link.h"

G_BEGIN_DECLS

typedef enum {
    SZFRIENDS_GTK_SUB_VIEW, SZFRIENDS_GTK_SUB_CONVERSATION, SZFRIENDS_GTK_SUB_MESSAGE_STATUS
} SZFriendsGtkLinkSubKind;

typedef struct {
    guint token;
    SZFriendsGtkLinkSubKind kind;
    char *view, *conversation_id, *message_id, *filter, *server_id;
    char **message_ids;
    guint earlier_count;
    SZFriendsGtkSnapshotFunc func;
    gpointer user_data;
    GDestroyNotify destroy;
} SZFriendsGtkLinkSub;

typedef struct {
    guint request;
    char *frame_id;   /* NULL until sent, and for a client-side failure waiting for its idle */
    char *fail_code;  /* client-side failure to deliver on the idle */
    SZFriendsGtkReplyFunc func;
    gpointer user_data;
    GDestroyNotify destroy;
} SZFriendsGtkLinkReply;

typedef struct {
    guint id;
    gpointer func;
    gpointer user_data;
    GDestroyNotify destroy;
} SZFriendsGtkLinkWatch;

struct _SZFriendsGtkLink {
    SZFriendsGtkHost host;       /* deep copy; strings point into `owned` */
    GPtrArray *owned;            /* everything the copy allocated */
    szfriends_client *client;
    SZFriendsGtkLinkState state;
    char *status_text;
    guint fd_watch, tick_source, failure_idle;
    int watched_fd;
    gboolean rearm_requested;
    GQueue events;               /* library callbacks waiting to be handled */
    guint refs;                  /* the host's, each button's and page's, and every call on the stack */
    gboolean draining, closed;   /* closed: the host freed it; buttons and pages may still let go later */
    GHashTable *strings;         /* welcome.strings */
    char **helper_capabilities;
    GPtrArray *subs;             /* SZFriendsGtkLinkSub *, creation order */
    guint next_token, next_request, next_watch;
    GHashTable *by_server;       /* helper subscription id -> sub (not owned) */
    GHashTable *subscribe_frames; /* frame id -> token */
    GHashTable *abandoned_frames; /* frame id -> "" (unsubscribed before the reply) */
    GHashTable *early;           /* helper subscription id -> snapshot JsonObject (newest only) */
    GHashTable *replies;         /* frame id -> reply (not owned) */
    GHashTable *requests;        /* request id -> reply (owned) */
    GQueue failures;             /* replies waiting for their client-side failure idle */
    GPtrArray *state_watches, *badge_watches; /* SZFriendsGtkLinkWatch * */
    guint notifying;             /* watches running: removals only silence them until the run ends */
    guint badge_token;
    SZFriendsGtkBadgeSnapshot *badge;
    GPtrArray *windows;          /* SZFriendsGtkLinkWindow * (szfriends_gtk_link.c) */
    gpointer pages;              /* the page builders (szfriends_gtk_page.c) */
    gpointer animals;            /* the animal set, loaded on first use (szfriends_gtk_avatars.c) */
    gboolean animals_loaded;
    GPtrArray *focus_dropdowns;  /* every window's dropdown, not owned (szfriends_gtk_focus.c) */
    char *focus_sent;            /* the conversation set_focus last named on this connection; NULL: none */
};

/* szfriends_gtk_link.c */
/* Buttons and pages hold the link, so a host that frees it before its last window cannot leave them pointing at
 * freed memory; the memory goes with the last reference. */
void szfriends_gtk_link_ref(SZFriendsGtkLink *link);
void szfriends_gtk_link_unref(SZFriendsGtkLink *link);
/* Call after any library call: handles the queued callbacks, then re-arms the descriptor watch and the timer. */
void szfriends_gtk_link_after_call(SZFriendsGtkLink *link);

/* Watches may be removed from inside a watch (a window closed from a state change), so runs go through these. */
void szfriends_gtk_link_watches_begin(SZFriendsGtkLink *link);
void szfriends_gtk_link_watches_end(SZFriendsGtkLink *link);
void szfriends_gtk_link_watches_remove(SZFriendsGtkLink *link, GPtrArray *watches, guint id);

/* szfriends_gtk_link_routes.c */
void szfriends_gtk_link_routes_init(SZFriendsGtkLink *link);
void szfriends_gtk_link_routes_clear(SZFriendsGtkLink *link);
void szfriends_gtk_link_route_frame(SZFriendsGtkLink *link, JsonObject *frame);
/* State edges: leaving READY fails waiting replies with connection_lost; READY sends every subscription again. */
void szfriends_gtk_link_routes_left_ready(SZFriendsGtkLink *link);
void szfriends_gtk_link_routes_ready(SZFriendsGtkLink *link);

/* The button add_window made for `window` (NULL: the first window's), or NULL (szfriends_gtk_link.c). */
GtkWidget *szfriends_gtk_link_window_button(SZFriendsGtkLink *link, GtkWindow *window);

G_END_DECLS

#endif /* SZFRIENDS_GTK_LINK_PRIVATE_H */
