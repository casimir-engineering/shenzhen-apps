/* Shenzhen Friends client library: the builders for links, joining a profile, a person's devices, Get again and the
 * Wi-Fi Direct boost (PROTOCOL.md § Intents and § Schemas, intent.*), as szfriends_intents.c's. */

#include "client/szfriends_intent_build.h"

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
szfriends_intent *szfriends_intent_fetch_from_device(const char *id) {
    return one_string("fetch_from_device", "transfer_id", id);
}
szfriends_intent *szfriends_intent_fetch_from_friend(const char *id) {
    return one_string("fetch_from_friend", "transfer_id", id);
}
szfriends_intent *szfriends_intent_boost_transfer(const char *id) {
    return one_string("boost_transfer", "transfer_id", id);
}
szfriends_intent *szfriends_intent_skip_boost(const char *id) {
    return one_string("skip_boost", "transfer_id", id);
}
