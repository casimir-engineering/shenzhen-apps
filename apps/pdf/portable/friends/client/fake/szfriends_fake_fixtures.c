/* Shenzhen Friends fake helper: loads the golden fixtures it serves.
 *
 * The default view snapshots are the files the README names for the mockup states; every conversation-*.json
 * and details-*.json is indexed by its conversation_id so open_conversation and a details subscription find the
 * right person. Successful replies come from fixtures/replies/<intent>.json. */

#include "client/fake/szfriends_fake_internal.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* PROTOCOL.md § Intents, version 1.0. An intent missing here is answered with unknown_intent, as the helper
 * answers one outside the negotiated version. */
static const char *const known_intents[] = {
    "ping", "activate", "subscribe", "unsubscribe", "set_filter", "open_conversation", "load_earlier",
    "send_message", "send_files", "cancel_transfer", "accept_offer", "decline_offer", "retry_item",
    "accept_request", "decline_request", "cancel_request", "send_request", "add_by_id", "block", "unblock",
    "remove_friend", "mark_verified", "accept_key_change", "set_name", "set_picture", "set_auto_accept",
    "dismiss_banner", "start_visibility", "stop_visibility", "search_messages", "assistant_open_scope",
    "assistant_search", "assistant_read", "assistant_close_scope", "delete_history", "reset_friends", "disable",
    "cancel_message", "add_from_mention", "open_link", "add_from_link", "receive_link", "make_download_link",
    "reset_friend_link", "revoke_link", "join_profile", "enter_join_code", "cancel_join", "approve_join", "deny_join",
    "revoke_device", "rename_device", "fetch_from_device",
};

bool szf_fake_is_intent(const char *type) {
    size_t i;
    for (i = 0; i < sizeof known_intents / sizeof known_intents[0]; i++)
        if (strcmp(type, known_intents[i]) == 0) return true;
    return false;
}

char *szf_fake_read_file(const char *path, size_t *length_out) {
    FILE *file = fopen(path, "rb");
    char *bytes;
    long size;
    if (!file) return NULL;
    if (fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    bytes = (char *)malloc((size_t)size + 1);
    if (bytes && fread(bytes, 1, (size_t)size, file) != (size_t)size) {
        free(bytes);
        bytes = NULL;
    }
    fclose(file);
    if (!bytes) return NULL;
    bytes[size] = '\0';
    if (length_out) *length_out = (size_t)size;
    return bytes;
}

static cJSON *read_json(const char *directory, const char *subdirectory, const char *name) {
    char path[SZFRIENDS_PATH_CAP * 2];
    size_t length = 0;
    char *text;
    cJSON *json;
    snprintf(path, sizeof path, "%s/%s/%s", directory, subdirectory, name);
    text = szf_fake_read_file(path, &length);
    if (!text) return NULL;
    json = cJSON_ParseWithLength(text, length);
    free(text);
    return json;
}

cJSON *szf_fake_find_by_conversation(cJSON *array, const char *conversation_id) {
    cJSON *item;
    if (!conversation_id) return NULL;
    cJSON_ArrayForEach(item, array) {
        const cJSON *id = cJSON_GetObjectItemCaseSensitive(item, "conversation_id");
        if (cJSON_IsString(id) && strcmp(id->valuestring, conversation_id) == 0) return item;
    }
    return NULL;
}

static bool has_prefix(const char *name, const char *prefix) {
    return strncmp(name, prefix, strlen(prefix)) == 0;
}

static bool has_json_suffix(const char *name) {
    size_t length = strlen(name);
    return length > 5 && strcmp(name + length - 5, ".json") == 0;
}

/* Moves frame.data out of a snapshot fixture; NULL when the file is not a snapshot of `view`. */
static cJSON *take_data(cJSON *frame, const char *view) {
    const cJSON *frame_view = cJSON_GetObjectItemCaseSensitive(frame, "view");
    if (!cJSON_IsString(frame_view) || strcmp(frame_view->valuestring, view) != 0) return NULL;
    return cJSON_DetachItemFromObjectCaseSensitive(frame, "data");
}

static szfriends_status load_snapshots(szfriends_fake_helper *fake) {
    /* The mockup state each view starts in (README § Fixtures). */
    static const char *const defaults[][2] = {
        {"badge", "badge.json"},       {"list", "list.json"},         {"nearby", "nearby-visible-bluetooth-off.json"},
        {"profile", "profile-unreserved.json"}, {"settings", "settings.json"},
        /* Whatever ids are asked for: the fake replays fixtures, and the welcome announces messages.status. */
        {"message_status", "message-status.json"},
        /* A new computer's side of joining, before an ID is typed (PROTOCOL.md § Joining). */
        {"join", "join-idle.json"},
    };
    char directory[SZFRIENDS_PATH_CAP * 2];
    DIR *listing;
    struct dirent *entry;
    size_t i;

    for (i = 0; i < sizeof defaults / sizeof defaults[0]; i++) {
        cJSON *frame = read_json(fake->fixtures_dir, "snapshots", defaults[i][1]);
        cJSON *data = frame ? take_data(frame, defaults[i][0]) : NULL;
        cJSON_Delete(frame);
        if (!data) return SZFRIENDS_ERR_IO;
        cJSON_AddItemToObject(fake->views, defaults[i][0], data);
    }
    snprintf(directory, sizeof directory, "%s/snapshots", fake->fixtures_dir);
    listing = opendir(directory);
    if (!listing) return SZFRIENDS_ERR_IO;
    while ((entry = readdir(listing)) != NULL) {
        bool conversation = has_prefix(entry->d_name, "conversation-");
        bool details = has_prefix(entry->d_name, "details-");
        cJSON *frame, *data;
        if ((!conversation && !details) || !has_json_suffix(entry->d_name)) continue;
        frame = read_json(fake->fixtures_dir, "snapshots", entry->d_name);
        data = frame ? take_data(frame, conversation ? "conversation" : "details") : NULL;
        cJSON_Delete(frame);
        if (!data) continue;
        cJSON_AddItemToArray(conversation ? fake->conversations : fake->details, data);
    }
    closedir(listing);
    return SZFRIENDS_OK;
}

static szfriends_status load_replies(szfriends_fake_helper *fake) {
    char directory[SZFRIENDS_PATH_CAP * 2];
    DIR *listing;
    struct dirent *entry;
    snprintf(directory, sizeof directory, "%s/replies", fake->fixtures_dir);
    listing = opendir(directory);
    if (!listing) return SZFRIENDS_ERR_IO;
    while ((entry = readdir(listing)) != NULL) {
        char intent[128];
        size_t length = strlen(entry->d_name);
        cJSON *frame;
        if (!has_json_suffix(entry->d_name) || length - 5 >= sizeof intent) continue;
        memcpy(intent, entry->d_name, length - 5);
        intent[length - 5] = '\0';
        frame = read_json(fake->fixtures_dir, "replies", entry->d_name);
        if (frame) cJSON_AddItemToObject(fake->replies, intent, frame);
    }
    closedir(listing);
    return SZFRIENDS_OK;
}

szfriends_status szf_fake_load_fixtures(szfriends_fake_helper *fake) {
    szfriends_status status;
    fake->views = cJSON_CreateObject();
    fake->details = cJSON_CreateArray();
    fake->conversations = cJSON_CreateArray();
    fake->replies = cJSON_CreateObject();
    fake->scripted = cJSON_CreateObject();
    if (!fake->views || !fake->details || !fake->conversations || !fake->replies || !fake->scripted)
        return SZFRIENDS_ERR_NO_MEMORY;
    fake->welcome = read_json(fake->fixtures_dir, "frames", "welcome.json");
    if (!cJSON_IsObject(fake->welcome)) return SZFRIENDS_ERR_IO;
    status = load_snapshots(fake);
    if (status != SZFRIENDS_OK) return status;
    return load_replies(fake);
}
