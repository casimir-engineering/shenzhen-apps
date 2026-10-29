/* Intent builders against fixtures/intents.jsonl: every line is rebuilt through the public builders from its own
 * field values, and the builder's fields must equal the line's (minus type and id). A builder that drifts from
 * PROTOCOL.md's schema, which friends-protocol-check validates the fixture against, fails here. */

#include "szfriends_test_support.h"

#include <stdlib.h>
#include <string.h>

static const char *str(const cJSON *object, const char *key) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsString(item) ? item->valuestring : NULL;
}

static int64_t num(const cJSON *object, const char *key, int64_t fallback) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsNumber(item) ? (int64_t)item->valuedouble : fallback;
}

/* Converts the fixture's file objects; strings point into `array`, which outlives the call. */
static size_t files_from(const cJSON *array, szfriends_file *files, szfriends_revision *revisions, size_t cap) {
    const cJSON *item;
    size_t count = 0;
    cJSON_ArrayForEach(item, array) {
        const cJSON *revision = cJSON_GetObjectItemCaseSensitive(item, "revision");
        if (count == cap) break;
        memset(&files[count], 0, sizeof files[count]);
        files[count].path = str(item, "path");
        files[count].display_name = str(item, "display_name");
        if (cJSON_IsObject(revision)) {
            revisions[count].source = str(revision, "source");
            revisions[count].document_id = str(revision, "document_id");
            revisions[count].revision_id = str(revision, "revision_id");
            revisions[count].label = str(revision, "label");
            revisions[count].sha256 = str(revision, "sha256");
            revisions[count].size = (uint64_t)num(revision, "size", 0);
            files[count].revision = &revisions[count];
        }
        count++;
    }
    return count;
}

szfriends_intent *szft_intent_from_fixture(const cJSON *line) {
    const char *type = str(line, "type");
    szfriends_file files[8];
    szfriends_revision revisions[8];
    size_t count;
    if (!type) return NULL;
#define ONE(name, key) if (strcmp(type, #name) == 0) return szfriends_intent_##name(str(line, key))
    ONE(unsubscribe, "subscription");
    ONE(load_earlier, "subscription");
    ONE(cancel_transfer, "transfer_id");
    ONE(accept_offer, "transfer_id");
    ONE(decline_offer, "transfer_id");
    ONE(retry_item, "item_id");
    ONE(cancel_message, "message_id");
    ONE(accept_request, "conversation_id");
    ONE(decline_request, "conversation_id");
    ONE(cancel_request, "conversation_id");
    ONE(send_request, "nearby_id");
    ONE(add_by_id, "friends_id");
    ONE(block, "conversation_id");
    ONE(unblock, "conversation_id");
    ONE(mark_verified, "conversation_id");
    ONE(accept_key_change, "conversation_id");
    ONE(set_name, "name");
    ONE(dismiss_banner, "kind");
    ONE(assistant_close_scope, "scope_id");
    ONE(join_profile, "friends_id");
    ONE(enter_join_code, "code");
    ONE(approve_join, "join_id");
    ONE(deny_join, "join_id");
    ONE(revoke_device, "device_id");
    ONE(rename_device, "name");
    ONE(fetch_from_device, "transfer_id");
    ONE(fetch_from_friend, "transfer_id");
    ONE(boost_transfer, "transfer_id");
    ONE(skip_boost, "transfer_id");
    ONE(set_received_folder, "path");
#undef ONE
    if (strcmp(type, "remove_friend") == 0) {
        szfriends_intent *removal = szfriends_intent_remove_friend(str(line, "conversation_id"));
        if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(line, "delete_history")))
            removal = szfriends_intent_with_confirm_option(removal, "delete_history");
        return removal;
    }
    if (strcmp(type, "ping") == 0) return szfriends_intent_ping();
    if (strcmp(type, "set_focus") == 0) return szfriends_intent_set_focus(str(line, "conversation_id"));
    if (strcmp(type, "set_notifications") == 0) {
#define SWITCH(key) (cJSON_IsBool(cJSON_GetObjectItemCaseSensitive(line, key)) ? \
                     (int)cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(line, key)) : -1)
        return szfriends_intent_set_notifications(SWITCH("enabled"), SWITCH("preview"), SWITCH("background"));
#undef SWITCH
    }
    if (strcmp(type, "allow_notifications") == 0) return szfriends_intent_allow_notifications();
    if (strcmp(type, "test_notification_response") == 0)
        return szfriends_intent_test_notification_response(str(line, "key"), str(line, "action"), str(line, "text"));
    if (strcmp(type, "activate") == 0) return szfriends_intent_activate();
    if (strcmp(type, "start_visibility") == 0) return szfriends_intent_start_visibility();
    if (strcmp(type, "stop_visibility") == 0) return szfriends_intent_stop_visibility();
    if (strcmp(type, "disable") == 0) return szfriends_intent_disable();
    if (strcmp(type, "reset_friends") == 0) return szfriends_intent_reset_friends();
    if (strcmp(type, "cancel_join") == 0) return szfriends_intent_cancel_join();
    if (strcmp(type, "subscribe") == 0 && str(line, "view") && strcmp(str(line, "view"), "message_status") == 0) {
        const cJSON *ids = cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(line, "params"),
                                                            "message_ids"), *id;
        const char *list[16];
        count = 0;
        cJSON_ArrayForEach(id, ids) if (count < 16) list[count++] = id->valuestring;
        return szfriends_intent_subscribe_message_status(list, count);
    }
    if (strcmp(type, "subscribe") == 0)
        return szfriends_intent_subscribe(str(line, "view"),
                                          str(cJSON_GetObjectItemCaseSensitive(line, "params"), "conversation_id"));
    if (strcmp(type, "set_filter") == 0)
        return szfriends_intent_set_filter(str(line, "subscription"), str(line, "query"));
    if (strcmp(type, "open_conversation") == 0)
        return szfriends_intent_open_conversation(str(line, "conversation_id"), str(line, "message_id"));
    if (strcmp(type, "send_message") == 0 || strcmp(type, "send_files") == 0) {
        bool message = strcmp(type, "send_message") == 0;
        szfriends_intent *sent;
        count = files_from(cJSON_GetObjectItemCaseSensitive(line, message ? "attachments" : "files"), files, revisions,
                           8);
        sent = message ? szfriends_intent_send_message(str(line, "conversation_id"), str(line, "text"),
                                                       str(line, "client_token"), files, count)
                       : szfriends_intent_send_files(str(line, "conversation_id"), files, count,
                                                     str(line, "client_token"));
        if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(line, "via_assistant")))
            sent = szfriends_intent_via_assistant(sent);
        if (message && cJSON_IsArray(cJSON_GetObjectItemCaseSensitive(line, "mentions"))) {
            const cJSON *mention;
            const char *list[20];
            count = 0;
            cJSON_ArrayForEach(mention, cJSON_GetObjectItemCaseSensitive(line, "mentions"))
                if (count < 20) list[count++] = str(mention, "conversation_id");
            sent = szfriends_intent_with_mentions(sent, list, count);
        }
        return sent;
    }
    if (strcmp(type, "set_picture") == 0) {
        const cJSON *picture = cJSON_GetObjectItemCaseSensitive(line, "picture");
        const cJSON *crop = cJSON_GetObjectItemCaseSensitive(picture, "crop");
        szfriends_crop box;
        box.x = num(crop, "x", 0);
        box.y = num(crop, "y", 0);
        box.side = num(crop, "side", 0);
        if (strcmp(str(picture, "kind"), "animal") == 0)
            return szfriends_intent_set_picture_animal(num(picture, "set", 0), num(picture, "index", 0));
        if (str(picture, "data_base64"))
            return szfriends_intent_set_picture_image_data(str(picture, "data_base64"),
                                                           cJSON_IsObject(crop) ? &box : NULL);
        return szfriends_intent_set_picture_image_path(str(picture, "path"), cJSON_IsObject(crop) ? &box : NULL);
    }
    if (strcmp(type, "set_auto_accept") == 0)
        return szfriends_intent_set_auto_accept(str(line, "conversation_id"),
                                                cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(line, "enabled")));
    if (strcmp(type, "search_messages") == 0)
        return szfriends_intent_search_messages(str(line, "query"), str(line, "conversation_id"),
                                                num(line, "limit", 0));
    if (strcmp(type, "assistant_open_scope") == 0) {
        const cJSON *scope = cJSON_GetObjectItemCaseSensitive(line, "scope");
        const cJSON *ids = cJSON_GetObjectItemCaseSensitive(scope, "conversation_ids"), *id;
        const char *list[16];
        count = 0;
        if (strcmp(str(scope, "kind"), "all") == 0) return szfriends_intent_assistant_open_scope_all();
        cJSON_ArrayForEach(id, ids) if (count < 16) list[count++] = id->valuestring;
        return szfriends_intent_assistant_open_scope_conversations(list, count);
    }
    if (strcmp(type, "assistant_search") == 0)
        return szfriends_intent_assistant_search(str(line, "scope_id"), str(line, "query"), num(line, "limit", 0));
    if (strcmp(type, "assistant_read") == 0)
        return szfriends_intent_assistant_read(str(line, "scope_id"), str(line, "message_id"), num(line, "before", -1),
                                               num(line, "after", -1));
    if (strcmp(type, "delete_history") == 0) return szfriends_intent_delete_history(str(line, "conversation_id"));
    if (strcmp(type, "add_from_mention") == 0)
        return szfriends_intent_add_from_mention(str(line, "friends_id"), str(line, "identity_key"), str(line, "name"));
    if (strcmp(type, "open_link") == 0) return szfriends_intent_open_link(str(line, "payload"));
    if (strcmp(type, "add_from_link") == 0) return szfriends_intent_add_from_link(str(line, "payload"));
    if (strcmp(type, "receive_link") == 0) return szfriends_intent_receive_link(str(line, "payload"));
    if (strcmp(type, "reset_friend_link") == 0) return szfriends_intent_reset_friend_link();
    if (strcmp(type, "revoke_link") == 0) return szfriends_intent_revoke_link(str(line, "link_id"));
    if (strcmp(type, "make_download_link") == 0) {
        cJSON *object = cJSON_GetObjectItemCaseSensitive(line, "file");
        szfriends_file file;
        memset(&file, 0, sizeof file);
        file.path = str(object, "path");
        file.display_name = str(object, "display_name");
        return szfriends_intent_make_download_link(&file, num(line, "expires_days", 0));
    }
    return NULL;
}

static void test_every_fixture_line(void) {
    char path[4096];
    FILE *file;
    char line[16384];
    size_t lines = 0;
    snprintf(path, sizeof path, "%s/intents.jsonl", szft_fixtures);
    file = fopen(path, "r");
    EXPECT(file != NULL, "intents.jsonl");
    if (!file) return;
    while (fgets(line, sizeof line, file)) {
        cJSON *fixture = cJSON_Parse(line), *built_fields, *expected;
        szfriends_intent *intent;
        char *fields;
        if (!fixture) continue;
        lines++;
        intent = szft_intent_from_fixture(fixture);
        EXPECT(intent != NULL, "no builder reproduces %s", line);
        if (!intent) {
            cJSON_Delete(fixture);
            continue;
        }
        EXPECT(strcmp(szfriends_intent_type(intent), str(fixture, "type")) == 0, "type %s", str(fixture, "type"));
        fields = szfriends_intent_fields_json(intent);
        built_fields = cJSON_Parse(fields);
        expected = cJSON_Duplicate(fixture, 1);
        cJSON_DeleteItemFromObjectCaseSensitive(expected, "type");
        cJSON_DeleteItemFromObjectCaseSensitive(expected, "id");
        EXPECT(szft_json_equivalent(built_fields, expected), "builder for %s gave %s", str(fixture, "type"), fields);
        szfriends_free(fields);
        cJSON_Delete(built_fields);
        cJSON_Delete(expected);
        szfriends_intent_free(intent);
        cJSON_Delete(fixture);
    }
    fclose(file);
    EXPECT(lines >= 67, "read %zu intent lines", lines);
}

static void test_required_arguments_and_escaping(void) {
    szfriends_file file;
    szfriends_intent *intent;
    char *fields;
    cJSON *parsed;
    memset(&file, 0, sizeof file);
    EXPECT(szfriends_intent_accept_offer(NULL) == NULL, "NULL transfer id");
    EXPECT(szfriends_intent_send_message("c", NULL, "t", NULL, 0) == NULL, "NULL text");
    EXPECT(szfriends_intent_send_message("c", "hi", NULL, NULL, 0) == NULL, "NULL token");
    EXPECT(szfriends_intent_send_files("c", &file, 1, "t") == NULL, "file without a path");
    EXPECT(szfriends_intent_subscribe(NULL, NULL) == NULL, "NULL view");
    {
        /* message_status takes 1 to 16 ids (PROTOCOL.md § Views); anything else is refused before it is sent. */
        const char *ids[17] = {"m_1", "m_2", "m_3", "m_4", "m_5", "m_6", "m_7", "m_8", "m_9",
                               "m_10", "m_11", "m_12", "m_13", "m_14", "m_15", "m_16", "m_17"};
        const char *with_null[2] = {"m_1", NULL};
        intent = szfriends_intent_subscribe_message_status(ids, 16);
        EXPECT(intent != NULL, "16 message ids");
        szfriends_intent_free(intent);
        EXPECT(szfriends_intent_subscribe_message_status(ids, 17) == NULL, "17 message ids");
        EXPECT(szfriends_intent_subscribe_message_status(ids, 0) == NULL, "no message ids");
        EXPECT(szfriends_intent_subscribe_message_status(NULL, 1) == NULL, "NULL message ids");
        EXPECT(szfriends_intent_subscribe_message_status(with_null, 2) == NULL, "a NULL message id");
    }
    /* Only the two sending intents carry via_assistant; any other is refused rather than sent with a stray key. */
    EXPECT(szfriends_intent_via_assistant(szfriends_intent_accept_offer("t_1")) == NULL, "via_assistant on accept");
    EXPECT(szfriends_intent_via_assistant(NULL) == NULL, "via_assistant on NULL");
    {
        /* A confirm's option sets its field on the intent it belongs to, once, and nowhere else. */
        char *json;
        intent = szfriends_intent_with_confirm_option(
            szfriends_intent_with_confirm_option(szfriends_intent_remove_friend("c_mei"), "delete_history"),
            "delete_history");
        json = szfriends_intent_fields_json(intent);
        EXPECT(json && strcmp(json, "{\"conversation_id\":\"c_mei\",\"delete_history\":true}") == 0, "%s",
               json ? json : "(null)");
        free(json);
        szfriends_intent_free(intent);
        EXPECT(szfriends_intent_with_confirm_option(szfriends_intent_block("c_mei"), "delete_history") == NULL,
               "delete_history on block");
        EXPECT(szfriends_intent_with_confirm_option(szfriends_intent_remove_friend("c_mei"), "enabled") == NULL,
               "an unknown option field");
        EXPECT(szfriends_intent_with_confirm_option(szfriends_intent_remove_friend("c_mei"), NULL) == NULL,
               "a NULL field");
        EXPECT(szfriends_intent_with_confirm_option(NULL, "delete_history") == NULL, "option on NULL");
    }
    {
        /* Mentions ride on send_message only, 0 to 20 of them, none NULL (PROTOCOL.md § Mentions). */
        const char *ids[21] = {"c_1", "c_2", "c_3", "c_4", "c_5", "c_6", "c_7", "c_8", "c_9", "c_10", "c_11",
                               "c_12", "c_13", "c_14", "c_15", "c_16", "c_17", "c_18", "c_19", "c_20", "c_21"};
        const char *with_null[2] = {"c_1", NULL};
        intent = szfriends_intent_with_mentions(szfriends_intent_send_message("c", "\xef\xbf\xbc", "t", NULL, 0),
                                                ids, 20);
        EXPECT(intent != NULL, "20 mentions");
        szfriends_intent_free(intent);
        intent = szfriends_intent_with_mentions(szfriends_intent_send_message("c", "hi", "t", NULL, 0), ids, 0);
        fields = intent ? szfriends_intent_fields_json(intent) : NULL;
        EXPECT(fields && !strstr(fields, "mentions"), "no mentions, no field: %s", fields ? fields : "(null)");
        szfriends_free(fields);
        szfriends_intent_free(intent);
        EXPECT(szfriends_intent_with_mentions(szfriends_intent_send_message("c", "x", "t", NULL, 0), ids, 21) == NULL,
               "21 mentions");
        EXPECT(szfriends_intent_with_mentions(szfriends_intent_send_message("c", "x", "t", NULL, 0), with_null, 2) ==
                   NULL,
               "a NULL conversation id");
        EXPECT(szfriends_intent_with_mentions(szfriends_intent_send_files("c", &file, 0, "t"), ids, 1) == NULL,
               "mentions on send_files");
        EXPECT(szfriends_intent_add_from_mention("bonfire-otter", NULL, "Leo") == NULL, "add_from_mention without key");
        file.path = "/tmp/a.pdf";
        EXPECT(szfriends_intent_make_download_link(&file, 2) == NULL, "a download link for 2 days");
        EXPECT(szfriends_intent_make_download_link(NULL, 7) == NULL, "a download link for no file");
        EXPECT(szfriends_intent_open_link(NULL) == NULL && szfriends_intent_revoke_link(NULL) == NULL, "NULL links");
        file.path = NULL;
    }
    /* The device and join builders need what the person typed or the id the snapshot gave (PROTOCOL.md § Devices). */
    EXPECT(!szfriends_intent_join_profile(NULL) && !szfriends_intent_enter_join_code(NULL) &&
               !szfriends_intent_approve_join(NULL) && !szfriends_intent_deny_join(NULL) &&
               !szfriends_intent_revoke_device(NULL) && !szfriends_intent_rename_device(NULL) &&
               !szfriends_intent_fetch_from_device(NULL) && !szfriends_intent_fetch_from_friend(NULL),
           "device and join intents without their field");
    EXPECT(!szfriends_intent_set_received_folder(NULL), "a received folder needs its path");
    EXPECT(szfriends_client_send_intent(NULL, NULL, NULL, 0) == SZFRIENDS_ERR_INVALID_ARGUMENT, "NULL intent");

    /* A name and text with quotes, backslashes, a line break and non-ASCII characters survive the round trip. */
    file.path = "/Users/raph/Desktop/\"Quoted\" \\ name 合同.pdf";
    intent = szfriends_intent_send_message("c_mei", "line one\nline \"two\" – 合同", "0123456789abcdef", &file, 1);
    fields = szfriends_intent_fields_json(intent);
    parsed = cJSON_Parse(fields);
    EXPECT(parsed && strcmp(str(parsed, "text"), "line one\nline \"two\" – 合同") == 0, "text escaping: %s", fields);
    EXPECT(parsed && strcmp(str(cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(parsed, "attachments"), 0), "path"),
                            file.path) == 0,
           "path escaping");
    EXPECT(fields && !strchr(fields, '\n'), "compact: no raw line feed in a frame");
    cJSON_Delete(parsed);
    szfriends_free(fields);
    szfriends_intent_free(intent);
}

void szft_run_intent_tests(void) {
    test_every_fixture_line();
    test_required_arguments_and_escaping();
}
