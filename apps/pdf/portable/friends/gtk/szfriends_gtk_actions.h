/* Shenzhen Friends GTK views: the one place PROTOCOL.md actions and attachments become intents (internal to gtk/).
 *
 * Display-free, like mac/SZFriendsContext.m's action table: which id each action takes from the object carrying it,
 * which actions stay in the view (open_file, show_file, open_settings), and the file objects send_files and
 * send_message carry. */

#ifndef SZFRIENDS_GTK_ACTIONS_H
#define SZFRIENDS_GTK_ACTIONS_H

#include "gtk/szfriends_gtk_host.h"
#include "gtk/szfriends_gtk_snapshot.h"

#include "client/szfriends_client.h"

G_BEGIN_DECLS

/* The ids of the object an action sits on and of the view around it; NULL where there is none. */
typedef struct {
    const char *conversation_id; /* rows, request cards, details, key changes */
    const char *nearby_id;       /* Nearby strangers */
    const char *transfer_id;     /* transfer items */
    const char *item_id;         /* failed messages and transfers (retry_item) */
    const char *kind;            /* banners (dismiss_banner) */
    const char *message_id;      /* queued outgoing messages (cancel_message): the item's item_id */
} SZFriendsGtkActionIds;

/* Whether a view knows `action` at all; an unknown one is hidden (PROTOCOL.md § Principles). */
gboolean szfriends_gtk_action_is_known(SZFriendsGtkActionKind action);
/* open_file, show_file and open_settings go through the host or the system, never the helper. */
gboolean szfriends_gtk_action_is_client_side(SZFriendsGtkActionKind action);
/* The intent `action` sends with the id it takes from `ids`, or with its own fields (add_from_mention); NULL for a
 * client-side or unknown action, or when that id is missing (delete_history alone may go without one: all history).
 * reset_friends carries confirm "reset". */
szfriends_intent *szfriends_gtk_intent_for_action(const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids);
/* The intent a question's confirm button sends: `ticked` says the person ticked its option (confirm.option), and then
 * the intent also carries that option's field as true (remove_friend's delete_history). Unticked, or for an option
 * this view does not know, the same as szfriends_gtk_intent_for_action. */
szfriends_intent *szfriends_gtk_intent_for_answer(const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids,
                                                  gboolean ticked);
/* Whether a question's option is one this view can send, so only then is its checkbox shown. */
gboolean szfriends_gtk_confirm_option_known(const SZFriendsGtkConfirm *confirm);
/* The same for a list row's buttons, which carry only their kind (accept_request, decline_request, block). */
szfriends_intent *szfriends_gtk_intent_for_action_kind(SZFriendsGtkActionKind action,
                                                       const SZFriendsGtkActionIds *ids);

/* The System Settings page for a settings_target, or NULL where this platform has none. */
const char *szfriends_gtk_settings_uri(SZFriendsGtkSettingsTarget target);

/* A host item as the PROTOCOL.md file object: path, display_name (the title) and its revision when revision_json
 * holds a usable one. Owns its strings. */
typedef struct {
    szfriends_file file;
    szfriends_revision revision;
    GPtrArray *strings;
} SZFriendsGtkFile;

SZFriendsGtkFile *szfriends_gtk_file_new(const SZFriendsGtkHostItem *item);
void szfriends_gtk_file_free(SZFriendsGtkFile *file);
/* send_files and send_message from host items (SZFriendsGtkHostItem *); a fresh client_token when token is NULL. */
szfriends_intent *szfriends_gtk_intent_send_items(const char *conversation_id, GPtrArray *items, const char *token);
szfriends_intent *szfriends_gtk_intent_send_message(const char *conversation_id, const char *text, GPtrArray *items,
                                                    const char *token);

/* PROTOCOL.md rich text: the segments' text in order, and (when `attributes` is not NULL) bold for emphasis, a
 * highlight for search matches and an underline for links, as byte ranges. Set it with gtk_label_set_text and
 * gtk_label_set_attributes, never as markup. A link's destination stays in its segment, for the view's click. */
typedef struct _PangoAttrList PangoAttrList;
char *szfriends_gtk_rich_text(const SZFriendsGtkSegment *segments, gsize count, PangoAttrList **attributes);

G_END_DECLS

#endif /* SZFRIENDS_GTK_ACTIONS_H */
