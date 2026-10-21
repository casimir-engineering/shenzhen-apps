/* Actions and attachments to intents (szfriends_gtk_actions.h). */

#include "gtk/szfriends_gtk_actions.h"

#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <sys/utsname.h>
#endif

typedef enum {
    TAKES_NOTHING, TAKES_CONVERSATION, TAKES_NEARBY, TAKES_TRANSFER, TAKES_ITEM, TAKES_KIND, TAKES_MESSAGE,
    TAKES_OWN_FIELDS, CLIENT_SIDE
} SZFriendsGtkActionTakes;

/* Which id each intent action takes (PROTOCOL.md § Shared objects, action); mirrors mac/SZFriendsContext.m. */
static SZFriendsGtkActionTakes action_takes(SZFriendsGtkActionKind action) {
    switch (action) {
    case SZFRIENDS_GTK_ACTION_ACCEPT_REQUEST:
    case SZFRIENDS_GTK_ACTION_DECLINE_REQUEST:
    case SZFRIENDS_GTK_ACTION_CANCEL_REQUEST:
    case SZFRIENDS_GTK_ACTION_BLOCK:
    case SZFRIENDS_GTK_ACTION_UNBLOCK:
    case SZFRIENDS_GTK_ACTION_REMOVE_FRIEND:
    case SZFRIENDS_GTK_ACTION_MARK_VERIFIED:
    case SZFRIENDS_GTK_ACTION_ACCEPT_KEY_CHANGE:
    case SZFRIENDS_GTK_ACTION_DELETE_HISTORY: return TAKES_CONVERSATION;
    case SZFRIENDS_GTK_ACTION_SEND_REQUEST: return TAKES_NEARBY;
    case SZFRIENDS_GTK_ACTION_ADD_FROM_MENTION:
    case SZFRIENDS_GTK_ACTION_ADD_FROM_LINK:
    case SZFRIENDS_GTK_ACTION_RECEIVE_LINK:
    case SZFRIENDS_GTK_ACTION_REVOKE_LINK:
    case SZFRIENDS_GTK_ACTION_REVOKE_DEVICE:
    case SZFRIENDS_GTK_ACTION_JOIN_PROFILE:
    case SZFRIENDS_GTK_ACTION_APPROVE_JOIN:
    case SZFRIENDS_GTK_ACTION_DENY_JOIN: return TAKES_OWN_FIELDS;
    case SZFRIENDS_GTK_ACTION_ACCEPT_OFFER:
    case SZFRIENDS_GTK_ACTION_DECLINE_OFFER:
    case SZFRIENDS_GTK_ACTION_CANCEL_TRANSFER:
    case SZFRIENDS_GTK_ACTION_FETCH_FROM_DEVICE: return TAKES_TRANSFER;
    case SZFRIENDS_GTK_ACTION_RETRY_ITEM: return TAKES_ITEM;
    case SZFRIENDS_GTK_ACTION_DISMISS_BANNER: return TAKES_KIND;
    case SZFRIENDS_GTK_ACTION_CANCEL_MESSAGE: return TAKES_MESSAGE;
    case SZFRIENDS_GTK_ACTION_START_VISIBILITY:
    case SZFRIENDS_GTK_ACTION_STOP_VISIBILITY:
    case SZFRIENDS_GTK_ACTION_ACTIVATE:
    case SZFRIENDS_GTK_ACTION_RESET_FRIENDS:
    case SZFRIENDS_GTK_ACTION_RESET_FRIEND_LINK:
    case SZFRIENDS_GTK_ACTION_CANCEL_JOIN: return TAKES_NOTHING;
    case SZFRIENDS_GTK_ACTION_OPEN_FILE:
    case SZFRIENDS_GTK_ACTION_SHOW_FILE:
    case SZFRIENDS_GTK_ACTION_OPEN_SETTINGS:
    case SZFRIENDS_GTK_ACTION_CHOOSE_RECEIVED_FOLDER:
    case SZFRIENDS_GTK_ACTION_OPEN_JOIN:
    case SZFRIENDS_GTK_ACTION_UNKNOWN: break;
    }
    return CLIENT_SIDE;
}

gboolean szfriends_gtk_action_is_known(SZFriendsGtkActionKind action) {
    return action != SZFRIENDS_GTK_ACTION_UNKNOWN && szfriends_gtk_action_name(action) != NULL;
}

gboolean szfriends_gtk_action_is_client_side(SZFriendsGtkActionKind action) {
    return szfriends_gtk_action_is_known(action) && action_takes(action) == CLIENT_SIDE;
}

static const char *present(const char *value) {
    return value && *value ? value : NULL;
}

szfriends_intent *szfriends_gtk_intent_for_action_kind(SZFriendsGtkActionKind action,
                                                       const SZFriendsGtkActionIds *ids) {
    static const SZFriendsGtkActionIds none = {0};
    if (!ids) ids = &none;
    const char *conversation = present(ids->conversation_id);
    switch (action) {
    case SZFRIENDS_GTK_ACTION_ACCEPT_REQUEST: return szfriends_intent_accept_request(conversation);
    case SZFRIENDS_GTK_ACTION_DECLINE_REQUEST: return szfriends_intent_decline_request(conversation);
    case SZFRIENDS_GTK_ACTION_CANCEL_REQUEST: return szfriends_intent_cancel_request(conversation);
    case SZFRIENDS_GTK_ACTION_BLOCK: return szfriends_intent_block(conversation);
    case SZFRIENDS_GTK_ACTION_UNBLOCK: return szfriends_intent_unblock(conversation);
    case SZFRIENDS_GTK_ACTION_REMOVE_FRIEND: return szfriends_intent_remove_friend(conversation);
    case SZFRIENDS_GTK_ACTION_MARK_VERIFIED: return szfriends_intent_mark_verified(conversation);
    case SZFRIENDS_GTK_ACTION_ACCEPT_KEY_CHANGE: return szfriends_intent_accept_key_change(conversation);
    /* Without a conversation it deletes all history: only Settings offers that, behind its confirmation. */
    case SZFRIENDS_GTK_ACTION_DELETE_HISTORY: return szfriends_intent_delete_history(conversation);
    case SZFRIENDS_GTK_ACTION_SEND_REQUEST: return szfriends_intent_send_request(present(ids->nearby_id));
    case SZFRIENDS_GTK_ACTION_ACCEPT_OFFER: return szfriends_intent_accept_offer(present(ids->transfer_id));
    case SZFRIENDS_GTK_ACTION_DECLINE_OFFER: return szfriends_intent_decline_offer(present(ids->transfer_id));
    case SZFRIENDS_GTK_ACTION_CANCEL_TRANSFER: return szfriends_intent_cancel_transfer(present(ids->transfer_id));
    case SZFRIENDS_GTK_ACTION_RETRY_ITEM: return szfriends_intent_retry_item(present(ids->item_id));
    case SZFRIENDS_GTK_ACTION_DISMISS_BANNER: return szfriends_intent_dismiss_banner(present(ids->kind));
    case SZFRIENDS_GTK_ACTION_CANCEL_MESSAGE: return szfriends_intent_cancel_message(present(ids->message_id));
    case SZFRIENDS_GTK_ACTION_START_VISIBILITY: return szfriends_intent_start_visibility();
    case SZFRIENDS_GTK_ACTION_STOP_VISIBILITY: return szfriends_intent_stop_visibility();
    case SZFRIENDS_GTK_ACTION_ACTIVATE: return szfriends_intent_activate();
    case SZFRIENDS_GTK_ACTION_RESET_FRIENDS: return szfriends_intent_reset_friends();
    case SZFRIENDS_GTK_ACTION_RESET_FRIEND_LINK: return szfriends_intent_reset_friend_link();
    case SZFRIENDS_GTK_ACTION_FETCH_FROM_DEVICE: return szfriends_intent_fetch_from_device(present(ids->transfer_id));
    case SZFRIENDS_GTK_ACTION_CANCEL_JOIN: return szfriends_intent_cancel_join();
    default: return NULL;
    }
}

szfriends_intent *szfriends_gtk_intent_for_action(const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids) {
    if (!action) return NULL;
    /* A mention's Add carries the friend's ID, key and name itself; they go as they are, never rebuilt
     * (PROTOCOL.md § Mentions). */
    if (action->action == SZFRIENDS_GTK_ACTION_ADD_FROM_MENTION)
        return szfriends_intent_add_from_mention(present(action->friends_id), present(action->identity_key),
                                                 present(action->name));
    /* A link's card and Your links carry the payload or link id themselves, sent as the helper wrote it. */
    if (action->action == SZFRIENDS_GTK_ACTION_ADD_FROM_LINK)
        return szfriends_intent_add_from_link(present(action->payload));
    if (action->action == SZFRIENDS_GTK_ACTION_RECEIVE_LINK)
        return szfriends_intent_receive_link(present(action->payload));
    if (action->action == SZFRIENDS_GTK_ACTION_REVOKE_LINK)
        return szfriends_intent_revoke_link(present(action->link_id));
    /* Several computers (PROTOCOL.md § Devices, § Joining): a device row's Remove, a join row's Approve and Deny, and
     * Start again carry their id or the ID asked for themselves. */
    if (action->action == SZFRIENDS_GTK_ACTION_REVOKE_DEVICE)
        return szfriends_intent_revoke_device(present(action->device_id));
    if (action->action == SZFRIENDS_GTK_ACTION_APPROVE_JOIN)
        return szfriends_intent_approve_join(present(action->join_id));
    if (action->action == SZFRIENDS_GTK_ACTION_DENY_JOIN) return szfriends_intent_deny_join(present(action->join_id));
    if (action->action == SZFRIENDS_GTK_ACTION_JOIN_PROFILE)
        return szfriends_intent_join_profile(present(action->friends_id));
    return szfriends_gtk_intent_for_action_kind(action->action, ids);
}

gboolean szfriends_gtk_confirm_option_known(const SZFriendsGtkConfirm *confirm) {
    return confirm && confirm->option && confirm->option->field == SZFRIENDS_GTK_CONFIRM_FIELD_DELETE_HISTORY;
}

szfriends_intent *szfriends_gtk_intent_for_answer(const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids,
                                                  gboolean ticked) {
    if (!action) return NULL;
    /* Only Remove offers "Also delete chat history"; anywhere else a ticked box adds nothing. */
    if (ticked && action->action == SZFRIENDS_GTK_ACTION_REMOVE_FRIEND &&
        szfriends_gtk_confirm_option_known(action->confirm))
        return szfriends_intent_with_confirm_option(szfriends_gtk_intent_for_action(action, ids), "delete_history");
    return szfriends_gtk_intent_for_action(action, ids);
}

#ifdef __APPLE__
/* macOS 13 (Darwin 22) renamed the Bluetooth and Wi-Fi panes; the privacy anchors are the same on 12 and later. */
static gboolean macos_13_or_later(void) {
    struct utsname name;
    return uname(&name) == 0 && atoi(name.release) >= 22;
}
#endif

const char *szfriends_gtk_settings_uri(SZFriendsGtkSettingsTarget target) {
#ifdef __APPLE__
    switch (target) {
    case SZFRIENDS_GTK_SETTINGS_LOCAL_NETWORK_PRIVACY:
        return "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork";
    case SZFRIENDS_GTK_SETTINGS_BLUETOOTH_PRIVACY:
        return "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth";
    case SZFRIENDS_GTK_SETTINGS_BLUETOOTH:
        return macos_13_or_later() ? "x-apple.systempreferences:com.apple.BluetoothSettings"
                                   : "x-apple.systempreferences:com.apple.preferences.Bluetooth";
    case SZFRIENDS_GTK_SETTINGS_WIFI:
        return macos_13_or_later() ? "x-apple.systempreferences:com.apple.wifi-settings-extension"
                                   : "x-apple.systempreferences:com.apple.preference.network?Wi-Fi";
    default: return NULL;
    }
#else
    (void)target;
    return NULL;
#endif
}

/* ---- Files --------------------------------------------------------------------------------------- */

static const char *keep(SZFriendsGtkFile *file, const char *text) {
    if (!text) return NULL;
    char *copy = g_strdup(text);
    g_ptr_array_add(file->strings, copy);
    return copy;
}

static const char *revision_string(SZFriendsGtkFile *file, JsonObject *object, const char *key) {
    JsonNode *node = json_object_get_member(object, key);
    if (!node || !JSON_NODE_HOLDS_VALUE(node) || json_node_get_value_type(node) != G_TYPE_STRING) return NULL;
    return keep(file, json_node_get_string(node));
}

SZFriendsGtkFile *szfriends_gtk_file_new(const SZFriendsGtkHostItem *item) {
    if (!item || !item->path) return NULL;
    SZFriendsGtkFile *file = g_new0(SZFriendsGtkFile, 1);
    file->strings = g_ptr_array_new_with_free_func(g_free);
    file->file.path = keep(file, item->path);
    file->file.display_name = item->title && *item->title ? keep(file, item->title) : NULL;
    JsonObject *revision = item->revision_json ? szfriends_gtk_json_object_from_text(item->revision_json, -1) : NULL;
    if (revision) {
        file->revision.source = revision_string(file, revision, "source");
        file->revision.document_id = revision_string(file, revision, "document_id");
        file->revision.revision_id = revision_string(file, revision, "revision_id");
        file->revision.label = revision_string(file, revision, "label");
        file->revision.sha256 = revision_string(file, revision, "sha256");
        JsonNode *size = json_object_get_member(revision, "size");
        if (size && JSON_NODE_HOLDS_VALUE(size) && json_node_get_value_type(size) == G_TYPE_INT64 &&
            json_node_get_int(size) >= 0)
            file->revision.size = (uint64_t)json_node_get_int(size);
        /* A revision without its identity binds nothing; the helper would refuse it, so send the plain file. */
        if (file->revision.source && file->revision.document_id && file->revision.revision_id)
            file->file.revision = &file->revision;
        json_object_unref(revision);
    }
    return file;
}

void szfriends_gtk_file_free(SZFriendsGtkFile *file) {
    if (!file) return;
    g_ptr_array_free(file->strings, TRUE);
    g_free(file);
}

static szfriends_intent *send_with_files(const char *conversation_id, const char *text, GPtrArray *items,
                                         const char *token) {
    char fresh[40] = {0};
    if (!token) {
        if (szfriends_client_token(fresh, sizeof fresh) != SZFRIENDS_OK) return NULL;
        token = fresh;
    }
    GPtrArray *files = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_file_free);
    for (guint i = 0; items && i < items->len; i++) {
        SZFriendsGtkFile *file = szfriends_gtk_file_new(g_ptr_array_index(items, i));
        if (file) g_ptr_array_add(files, file);
    }
    szfriends_file *array = g_new0(szfriends_file, MAX(files->len, 1));
    for (guint i = 0; i < files->len; i++) array[i] = ((SZFriendsGtkFile *)g_ptr_array_index(files, i))->file;
    szfriends_intent *intent = text ? szfriends_intent_send_message(conversation_id, text, token, array, files->len)
                               : files->len ? szfriends_intent_send_files(conversation_id, array, files->len, token)
                                            : NULL;
    g_free(array);
    g_ptr_array_free(files, TRUE);
    return intent;
}

szfriends_intent *szfriends_gtk_intent_send_items(const char *conversation_id, GPtrArray *items, const char *token) {
    return send_with_files(conversation_id, NULL, items, token);
}

szfriends_intent *szfriends_gtk_intent_send_message(const char *conversation_id, const char *text, GPtrArray *items,
                                                    const char *token) {
    return text ? send_with_files(conversation_id, text, items, token) : NULL;
}
