/* Shenzhen Friends client library: one builder per intent (PROTOCOL.md § Intents and § Schemas, intent.*).
 *
 * C hosts (the GTK views) would otherwise assemble JSON with printf and get escaping wrong the first time a file
 * name holds a quote. Each builder mirrors its schema block; the tests rebuild every line of
 * fixtures/intents.jsonl with them, so a builder that drifts from the document fails there. */

#include "client/szfriends_client_internal.h"

#include "cJSON.h"

#include <stdlib.h>
#include <string.h>

struct szfriends_intent {
    char type[32];
    cJSON *fields;
};

static szfriends_intent *intent_new(const char *type) {
    szfriends_intent *intent = (szfriends_intent *)calloc(1, sizeof *intent);
    if (!intent) return NULL;
    strncpy(intent->type, type, sizeof intent->type - 1);
    intent->fields = cJSON_CreateObject();
    if (!intent->fields) {
        free(intent);
        return NULL;
    }
    return intent;
}

void szfriends_intent_free(szfriends_intent *intent) {
    if (!intent) return;
    cJSON_Delete(intent->fields);
    free(intent);
}

const char *szfriends_intent_type(const szfriends_intent *intent) {
    return intent ? intent->type : NULL;
}

char *szfriends_intent_fields_json(const szfriends_intent *intent) {
    return intent ? cJSON_PrintUnformatted(intent->fields) : NULL;
}

szfriends_status szfriends_client_send_intent(szfriends_client *client, szfriends_intent *intent, char *id_out,
                                              size_t id_out_cap) {
    char *fields;
    szfriends_status status;
    if (id_out && id_out_cap > 0) id_out[0] = '\0';
    if (!intent) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    fields = szfriends_intent_fields_json(intent);
    if (!fields) {
        szfriends_intent_free(intent);
        return SZFRIENDS_ERR_NO_MEMORY;
    }
    status = szfriends_client_send(client, intent->type, fields, id_out, id_out_cap);
    free(fields);
    szfriends_intent_free(intent);
    return status;
}

/* Adds a string, or fails the whole intent when cJSON runs out of memory; NULL values are the caller's bug. */
static bool add_string(szfriends_intent *intent, const char *key, const char *value) {
    return value && cJSON_AddStringToObject(intent->fields, key, value) != NULL;
}

static szfriends_intent *finish(szfriends_intent *intent, bool ok) {
    if (ok) return intent;
    szfriends_intent_free(intent);
    return NULL;
}

/* An intent whose only field is one required string, which is most of them. */
static szfriends_intent *one_string(const char *type, const char *key, const char *value) {
    szfriends_intent *intent;
    if (!value) return NULL;
    intent = intent_new(type);
    return intent ? finish(intent, add_string(intent, key, value)) : NULL;
}

static szfriends_intent *no_fields(const char *type) {
    return intent_new(type);
}

szfriends_intent *szfriends_intent_ping(void) { return no_fields("ping"); }
szfriends_intent *szfriends_intent_activate(void) { return no_fields("activate"); }
szfriends_intent *szfriends_intent_start_visibility(void) { return no_fields("start_visibility"); }
szfriends_intent *szfriends_intent_stop_visibility(void) { return no_fields("stop_visibility"); }
szfriends_intent *szfriends_intent_disable(void) { return no_fields("disable"); }

szfriends_intent *szfriends_intent_subscribe(const char *view, const char *conversation_id) {
    szfriends_intent *intent;
    bool ok;
    if (!view) return NULL;
    intent = intent_new("subscribe");
    if (!intent) return NULL;
    ok = add_string(intent, "view", view);
    if (ok && conversation_id) {
        cJSON *params = cJSON_AddObjectToObject(intent->fields, "params");
        ok = params && cJSON_AddStringToObject(params, "conversation_id", conversation_id) != NULL;
    }
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_subscribe_message_status(const char *const *message_ids, size_t count) {
    szfriends_intent *intent;
    cJSON *params, *ids;
    size_t i;
    bool ok;
    /* The helper refuses an empty list or more than 16 ids; refusing here says so before anything is sent. */
    if (!message_ids || count == 0 || count > 16) return NULL;
    intent = intent_new("subscribe");
    if (!intent) return NULL;
    ok = add_string(intent, "view", "message_status");
    params = ok ? cJSON_AddObjectToObject(intent->fields, "params") : NULL;
    ids = params ? cJSON_AddArrayToObject(params, "message_ids") : NULL;
    ok = ok && ids;
    for (i = 0; ok && i < count; i++) {
        cJSON *id = message_ids[i] ? cJSON_CreateString(message_ids[i]) : NULL;
        ok = id != NULL;
        if (ok) cJSON_AddItemToArray(ids, id);
    }
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_unsubscribe(const char *subscription) {
    return one_string("unsubscribe", "subscription", subscription);
}

szfriends_intent *szfriends_intent_set_filter(const char *subscription, const char *query) {
    szfriends_intent *intent;
    if (!subscription || !query) return NULL;
    intent = intent_new("set_filter");
    return intent ? finish(intent, add_string(intent, "subscription", subscription) &&
                                       add_string(intent, "query", query))
                  : NULL;
}

szfriends_intent *szfriends_intent_open_conversation(const char *conversation_id, const char *message_id_or_null) {
    szfriends_intent *intent;
    bool ok;
    if (!conversation_id) return NULL;
    intent = intent_new("open_conversation");
    if (!intent) return NULL;
    ok = add_string(intent, "conversation_id", conversation_id);
    if (ok && message_id_or_null) ok = add_string(intent, "message_id", message_id_or_null);
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_load_earlier(const char *subscription) {
    return one_string("load_earlier", "subscription", subscription);
}

static cJSON *file_object(const szfriends_file *file) {
    cJSON *object;
    if (!file || !file->path) return NULL;
    object = cJSON_CreateObject();
    if (!object) return NULL;
    cJSON_AddStringToObject(object, "path", file->path);
    if (file->display_name) cJSON_AddStringToObject(object, "display_name", file->display_name);
    if (file->revision) {
        const szfriends_revision *r = file->revision;
        cJSON *revision;
        if (!r->source || !r->document_id || !r->revision_id) {
            cJSON_Delete(object);
            return NULL;
        }
        revision = cJSON_AddObjectToObject(object, "revision");
        cJSON_AddStringToObject(revision, "source", r->source);
        cJSON_AddStringToObject(revision, "document_id", r->document_id);
        cJSON_AddStringToObject(revision, "revision_id", r->revision_id);
        if (r->label) cJSON_AddStringToObject(revision, "label", r->label);
        if (r->sha256) cJSON_AddStringToObject(revision, "sha256", r->sha256);
        cJSON_AddNumberToObject(revision, "size", (double)r->size);
    } else {
        cJSON_AddNullToObject(object, "revision");
    }
    return object;
}

static bool add_files(szfriends_intent *intent, const char *key, const szfriends_file *files, size_t count) {
    cJSON *array;
    size_t i;
    if (count > 0 && !files) return false;
    array = cJSON_AddArrayToObject(intent->fields, key);
    if (!array) return false;
    for (i = 0; i < count; i++) {
        cJSON *object = file_object(&files[i]);
        if (!object) return false;
        cJSON_AddItemToArray(array, object);
    }
    return true;
}

szfriends_intent *szfriends_intent_send_message(const char *conversation_id, const char *text,
                                                const char *client_token, const szfriends_file *attachments,
                                                size_t attachment_count) {
    szfriends_intent *intent;
    bool ok;
    if (!conversation_id || !text || !client_token) return NULL;
    intent = intent_new("send_message");
    if (!intent) return NULL;
    ok = add_string(intent, "conversation_id", conversation_id) && add_string(intent, "text", text) &&
         add_string(intent, "client_token", client_token);
    if (ok && attachment_count > 0) ok = add_files(intent, "attachments", attachments, attachment_count);
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_send_files(const char *conversation_id, const szfriends_file *files,
                                              size_t file_count, const char *client_token) {
    szfriends_intent *intent;
    if (!conversation_id || !client_token || (file_count > 0 && !files)) return NULL;
    intent = intent_new("send_files");
    if (!intent) return NULL;
    return finish(intent, add_string(intent, "conversation_id", conversation_id) &&
                              add_files(intent, "files", files, file_count) &&
                              add_string(intent, "client_token", client_token));
}

szfriends_intent *szfriends_intent_via_assistant(szfriends_intent *intent) {
    bool sends;
    if (!intent) return NULL;
    sends = strcmp(intent->type, "send_message") == 0 || strcmp(intent->type, "send_files") == 0;
    /* Replaces an earlier mark rather than adding a second key: a frame with a duplicate key is ambiguous. */
    cJSON_DeleteItemFromObjectCaseSensitive(intent->fields, "via_assistant");
    return finish(intent, sends && cJSON_AddTrueToObject(intent->fields, "via_assistant") != NULL);
}

szfriends_intent *szfriends_intent_with_mentions(szfriends_intent *intent, const char *const *conversation_ids,
                                                 size_t count) {
    cJSON *mentions;
    size_t i;
    bool ok;
    if (!intent) return NULL;
    /* At most 20 per message (PROTOCOL.md § Limits); the helper would refuse more, so they are refused here first. */
    ok = strcmp(intent->type, "send_message") == 0 && count <= 20 && (count == 0 || conversation_ids);
    if (!ok || count == 0) return finish(intent, ok);
    cJSON_DeleteItemFromObjectCaseSensitive(intent->fields, "mentions");
    mentions = cJSON_AddArrayToObject(intent->fields, "mentions");
    ok = mentions != NULL;
    for (i = 0; ok && i < count; i++) {
        cJSON *mention = conversation_ids[i] ? cJSON_CreateObject() : NULL;
        ok = mention && cJSON_AddStringToObject(mention, "conversation_id", conversation_ids[i]) != NULL;
        if (mention && !ok) cJSON_Delete(mention);
        if (ok) cJSON_AddItemToArray(mentions, mention);
    }
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_cancel_transfer(const char *transfer_id) {
    return one_string("cancel_transfer", "transfer_id", transfer_id);
}
szfriends_intent *szfriends_intent_accept_offer(const char *transfer_id) {
    return one_string("accept_offer", "transfer_id", transfer_id);
}
szfriends_intent *szfriends_intent_decline_offer(const char *transfer_id) {
    return one_string("decline_offer", "transfer_id", transfer_id);
}
szfriends_intent *szfriends_intent_retry_item(const char *item_id) {
    return one_string("retry_item", "item_id", item_id);
}
szfriends_intent *szfriends_intent_cancel_message(const char *message_id) {
    return one_string("cancel_message", "message_id", message_id);
}
szfriends_intent *szfriends_intent_accept_request(const char *conversation_id) {
    return one_string("accept_request", "conversation_id", conversation_id);
}
szfriends_intent *szfriends_intent_decline_request(const char *conversation_id) {
    return one_string("decline_request", "conversation_id", conversation_id);
}
szfriends_intent *szfriends_intent_cancel_request(const char *conversation_id) {
    return one_string("cancel_request", "conversation_id", conversation_id);
}
szfriends_intent *szfriends_intent_send_request(const char *nearby_id) {
    return one_string("send_request", "nearby_id", nearby_id);
}
szfriends_intent *szfriends_intent_add_by_id(const char *friends_id) {
    return one_string("add_by_id", "friends_id", friends_id);
}
szfriends_intent *szfriends_intent_add_from_mention(const char *friends_id, const char *identity_key,
                                                    const char *name) {
    szfriends_intent *intent;
    if (!friends_id || !identity_key || !name) return NULL;
    intent = intent_new("add_from_mention");
    return intent ? finish(intent, add_string(intent, "friends_id", friends_id) &&
                                       add_string(intent, "identity_key", identity_key) &&
                                       add_string(intent, "name", name))
                  : NULL;
}
szfriends_intent *szfriends_intent_block(const char *conversation_id) {
    return one_string("block", "conversation_id", conversation_id);
}
szfriends_intent *szfriends_intent_unblock(const char *conversation_id) {
    return one_string("unblock", "conversation_id", conversation_id);
}
szfriends_intent *szfriends_intent_remove_friend(const char *conversation_id) {
    return one_string("remove_friend", "conversation_id", conversation_id);
}
szfriends_intent *szfriends_intent_mark_verified(const char *conversation_id) {
    return one_string("mark_verified", "conversation_id", conversation_id);
}
szfriends_intent *szfriends_intent_accept_key_change(const char *conversation_id) {
    return one_string("accept_key_change", "conversation_id", conversation_id);
}
szfriends_intent *szfriends_intent_set_name(const char *name) {
    return one_string("set_name", "name", name);
}
szfriends_intent *szfriends_intent_dismiss_banner(const char *kind) {
    return one_string("dismiss_banner", "kind", kind);
}
szfriends_intent *szfriends_intent_assistant_close_scope(const char *scope_id) {
    return one_string("assistant_close_scope", "scope_id", scope_id);
}

szfriends_intent *szfriends_intent_set_picture_animal(int64_t set, int64_t index) {
    szfriends_intent *intent = intent_new("set_picture");
    cJSON *picture;
    if (!intent) return NULL;
    picture = cJSON_AddObjectToObject(intent->fields, "picture");
    return finish(intent, picture && cJSON_AddStringToObject(picture, "kind", "animal") &&
                              cJSON_AddNumberToObject(picture, "set", (double)set) &&
                              cJSON_AddNumberToObject(picture, "index", (double)index));
}

static szfriends_intent *picture_image(const char *key, const char *value, const szfriends_crop *crop) {
    szfriends_intent *intent;
    cJSON *picture;
    bool ok;
    if (!value) return NULL;
    intent = intent_new("set_picture");
    if (!intent) return NULL;
    picture = cJSON_AddObjectToObject(intent->fields, "picture");
    ok = picture && cJSON_AddStringToObject(picture, "kind", "image") && cJSON_AddStringToObject(picture, key, value);
    if (ok && crop) {
        cJSON *box = cJSON_AddObjectToObject(picture, "crop");
        ok = box && cJSON_AddNumberToObject(box, "x", (double)crop->x) &&
             cJSON_AddNumberToObject(box, "y", (double)crop->y) &&
             cJSON_AddNumberToObject(box, "side", (double)crop->side);
    } else if (ok) {
        ok = cJSON_AddNullToObject(picture, "crop") != NULL;
    }
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_set_picture_image_data(const char *data_base64, const szfriends_crop *crop) {
    return picture_image("data_base64", data_base64, crop);
}

szfriends_intent *szfriends_intent_set_picture_image_path(const char *path, const szfriends_crop *crop) {
    return picture_image("path", path, crop);
}

szfriends_intent *szfriends_intent_set_auto_accept(const char *conversation_id, bool enabled) {
    szfriends_intent *intent;
    if (!conversation_id) return NULL;
    intent = intent_new("set_auto_accept");
    return intent ? finish(intent, add_string(intent, "conversation_id", conversation_id) &&
                                       cJSON_AddBoolToObject(intent->fields, "enabled", enabled))
                  : NULL;
}

szfriends_intent *szfriends_intent_set_received_folder(const char *path) {
    szfriends_intent *intent = path ? intent_new("set_received_folder") : NULL;
    return intent ? finish(intent, add_string(intent, "path", path)) : NULL;
}

szfriends_intent *szfriends_intent_search_messages(const char *query, const char *conversation_id_or_null,
                                                   int64_t limit) {
    szfriends_intent *intent;
    bool ok;
    if (!query) return NULL;
    intent = intent_new("search_messages");
    if (!intent) return NULL;
    ok = add_string(intent, "query", query);
    if (ok && conversation_id_or_null) ok = add_string(intent, "conversation_id", conversation_id_or_null);
    if (ok && limit > 0) ok = cJSON_AddNumberToObject(intent->fields, "limit", (double)limit) != NULL;
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_assistant_open_scope_conversations(const char *const *conversation_ids,
                                                                      size_t count) {
    szfriends_intent *intent;
    cJSON *scope, *ids;
    size_t i;
    bool ok;
    if (count > 0 && !conversation_ids) return NULL;
    intent = intent_new("assistant_open_scope");
    if (!intent) return NULL;
    scope = cJSON_AddObjectToObject(intent->fields, "scope");
    ok = scope && cJSON_AddStringToObject(scope, "kind", "conversations");
    ids = ok ? cJSON_AddArrayToObject(scope, "conversation_ids") : NULL;
    ok = ok && ids;
    for (i = 0; ok && i < count; i++) {
        cJSON *id = conversation_ids[i] ? cJSON_CreateString(conversation_ids[i]) : NULL;
        ok = id != NULL;
        if (ok) cJSON_AddItemToArray(ids, id);
    }
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_assistant_open_scope_all(void) {
    szfriends_intent *intent = intent_new("assistant_open_scope");
    cJSON *scope;
    if (!intent) return NULL;
    scope = cJSON_AddObjectToObject(intent->fields, "scope");
    return finish(intent, scope && cJSON_AddStringToObject(scope, "kind", "all"));
}

szfriends_intent *szfriends_intent_assistant_search(const char *scope_id, const char *query, int64_t limit) {
    szfriends_intent *intent;
    bool ok;
    if (!scope_id || !query) return NULL;
    intent = intent_new("assistant_search");
    if (!intent) return NULL;
    ok = add_string(intent, "scope_id", scope_id) && add_string(intent, "query", query);
    if (ok && limit > 0) ok = cJSON_AddNumberToObject(intent->fields, "limit", (double)limit) != NULL;
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_assistant_read(const char *scope_id, const char *message_id, int64_t before,
                                                  int64_t after) {
    szfriends_intent *intent;
    bool ok;
    if (!scope_id || !message_id) return NULL;
    intent = intent_new("assistant_read");
    if (!intent) return NULL;
    ok = add_string(intent, "scope_id", scope_id) && add_string(intent, "message_id", message_id);
    if (ok && before >= 0) ok = cJSON_AddNumberToObject(intent->fields, "before", (double)before) != NULL;
    if (ok && after >= 0) ok = cJSON_AddNumberToObject(intent->fields, "after", (double)after) != NULL;
    return finish(intent, ok);
}

szfriends_intent *szfriends_intent_delete_history(const char *conversation_id_or_null) {
    szfriends_intent *intent = intent_new("delete_history");
    if (!intent) return NULL;
    if (!conversation_id_or_null) return intent;
    return finish(intent, add_string(intent, "conversation_id", conversation_id_or_null));
}

szfriends_intent *szfriends_intent_reset_friends(void) {
    return one_string("reset_friends", "confirm", "reset");
}

/* Links (PROTOCOL.md § Links). Payloads go as the app received them; the helper parses them again. */
szfriends_intent *szfriends_intent_open_link(const char *payload) {
    return one_string("open_link", "payload", payload);
}

szfriends_intent *szfriends_intent_add_from_link(const char *payload) {
    return one_string("add_from_link", "payload", payload);
}

szfriends_intent *szfriends_intent_receive_link(const char *payload) {
    return one_string("receive_link", "payload", payload);
}

szfriends_intent *szfriends_intent_make_download_link(const szfriends_file *file, int64_t expires_days) {
    szfriends_intent *intent;
    cJSON *object;
    if (expires_days != 1 && expires_days != 7 && expires_days != 30) return NULL;
    object = file_object(file);
    if (!object) return NULL;
    intent = intent_new("make_download_link");
    if (!intent) {
        cJSON_Delete(object);
        return NULL;
    }
    cJSON_AddItemToObject(intent->fields, "file", object);
    return finish(intent, cJSON_AddNumberToObject(intent->fields, "expires_days", (double)expires_days) != NULL);
}

szfriends_intent *szfriends_intent_reset_friend_link(void) {
    return no_fields("reset_friend_link");
}

szfriends_intent *szfriends_intent_revoke_link(const char *link_id) {
    return one_string("revoke_link", "link_id", link_id);
}

/* One profile on several computers (PROTOCOL.md § Devices, § Joining): the helper reads the ID and the code as a
 * person typed them, and the ids come back as the snapshot gave them. */
szfriends_intent *szfriends_intent_join_profile(const char *id) {
    return one_string("join_profile", "friends_id", id);
}
szfriends_intent *szfriends_intent_enter_join_code(const char *code) {
    return one_string("enter_join_code", "code", code);
}
szfriends_intent *szfriends_intent_cancel_join(void) { return no_fields("cancel_join"); }
szfriends_intent *szfriends_intent_approve_join(const char *id) { return one_string("approve_join", "join_id", id); }
szfriends_intent *szfriends_intent_deny_join(const char *id) { return one_string("deny_join", "join_id", id); }
szfriends_intent *szfriends_intent_revoke_device(const char *id) {
    return one_string("revoke_device", "device_id", id);
}
szfriends_intent *szfriends_intent_rename_device(const char *name) {
    return one_string("rename_device", "name", name);
}
szfriends_intent *szfriends_intent_fetch_from_device(const char *transfer_id) {
    return one_string("fetch_from_device", "transfer_id", transfer_id);
}
