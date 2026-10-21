/* Shenzhen Friends GTK views: the protocol's frames and a reply's results as plain C structs (PROTOCOL.md § Frames,
 * § Results).
 *
 * Internal; included by szfriends_gtk_snapshot.h after the views, under the same conventions (a `string|null` field
 * is NULL for null, an enum is 0 when unknown, arrays carry their count). */

#ifndef SZFRIENDS_GTK_SNAPSHOT_FRAMES_H
#define SZFRIENDS_GTK_SNAPSHOT_FRAMES_H

typedef struct { SZFriendsGtkPresence present; gint64 major, minor; } SZFriendsGtkVersion;
typedef struct { SZFriendsGtkPresence present; char *version; gint64 build_number; SZFriendsGtkVersion protocol;
                 gint64 pid; } SZFriendsGtkHelperInfo;
typedef struct { SZFriendsGtkPresence present; gint64 max_frame_bytes, max_message_bytes, max_files_per_send,
                 max_subscriptions; } SZFriendsGtkLimits;
typedef struct {
    SZFriendsGtkPresence present;
    char *re;
    SZFriendsGtkVersion protocol;
    SZFriendsGtkHelperInfo helper;
    SZFriendsGtkHandover handover;
    char **capabilities;        /* NULL-terminated */
    SZFriendsGtkLimits limits;
    GHashTable *strings;        /* welcome.strings: key -> label (PROTOCOL.md § Static strings) */
} SZFriendsGtkWelcome;
typedef struct { SZFriendsGtkPresence present; char *code, *message; gboolean retryable;
                 JsonObject *details; } SZFriendsGtkError;
typedef struct { SZFriendsGtkPresence present; char *re; gboolean ok; JsonObject *result;
                 SZFriendsGtkError *error; } SZFriendsGtkReply;
typedef struct { SZFriendsGtkPresence present; char *version; gint64 build_number; } SZFriendsGtkSuccessor;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkGoodbyeReason reason; char *message;
                 SZFriendsGtkSuccessor *successor; SZFriendsGtkError *error; } SZFriendsGtkGoodbye;
typedef struct { SZFriendsGtkPresence present; char *subscription, *view; gint64 rev;
                 JsonObject *data; } SZFriendsGtkSnapshotFrame;

typedef struct { SZFriendsGtkPresence present; char *subscription, *conversation_id; } SZFriendsGtkSubscribeResult;
typedef struct { SZFriendsGtkPresence present; char *message_id; char **transfer_ids; } SZFriendsGtkSendResult;
typedef struct { SZFriendsGtkPresence present; char *conversation_id, *message; } SZFriendsGtkAddByIdResult;
typedef struct { SZFriendsGtkPresence present; char *deadline; } SZFriendsGtkVisibilityResult;
/* open_link's card and make_download_link's link (PROTOCOL.md § Links). */
typedef enum { SZFRIENDS_GTK_LINK_CARD_UNKNOWN, SZFRIENDS_GTK_LINK_CARD_FRIEND, SZFRIENDS_GTK_LINK_CARD_DOWNLOAD
} SZFriendsGtkLinkCardKind;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkLinkCardKind kind; char *title, *subtitle, *note;
                 SZFriendsGtkAvatar *avatar; SZFriendsGtkAction *actions; gsize n_actions; } SZFriendsGtkLinkCard;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkLinkCard card; } SZFriendsGtkOpenLinkResult;
typedef struct { SZFriendsGtkPresence present; char *url, *link_id, *message; } SZFriendsGtkDownloadLinkResult;
typedef struct { SZFriendsGtkPresence present; char *conversation_id, *message_id, *conversation_title;
                 SZFriendsGtkAvatar avatar; char *sender_label, *time_label; SZFriendsGtkSegment *excerpt;
                 gsize n_excerpt; } SZFriendsGtkSearchHit;
typedef struct { SZFriendsGtkPresence present; SZFriendsGtkSearchHit *results; gsize n_results; gboolean more;
                 char *empty_label; } SZFriendsGtkSearchResult;

#endif /* SZFRIENDS_GTK_SNAPSHOT_FRAMES_H */
