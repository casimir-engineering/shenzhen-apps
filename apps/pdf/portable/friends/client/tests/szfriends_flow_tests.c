/* Subscriptions and every intent, end to end through the client library and the fake helper's socket. */

#include "szfriends_test_support.h"

#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <unistd.h>

static const char *str(const cJSON *object, const char *key) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsString(item) ? item->valuestring : NULL;
}

static const char *str_or_empty(const cJSON *object, const char *key) {
    const char *value = str(object, key);
    return value ? value : "";
}

static szft_client *ready_client(const char *state, szfriends_fake_helper **fake_out) {
    szft_client_options options;
    szft_client *harness;
    *fake_out = szft_fake_start(state, 0, 0, 0, 0, false);
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    harness = szft_client_new(&options);
    szfriends_client_start(harness->client);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 5000), "READY");
    return harness;
}

/* Sends `intent` and waits for its reply; returns the reply's index, and the index of the first snapshot that
 * arrived for it (before the reply), when asked. */
static long round_trip(szft_client *harness, szfriends_intent *intent, char *id, long *snapshot_index) {
    size_t from = harness->frame_count;
    long reply = -1;
    szfriends_status status = szfriends_client_send_intent(harness->client, intent, id, 24);
    EXPECT(status == SZFRIENDS_OK, "send: %s", szfriends_status_name(status));
    EXPECT(szft_wait_frame(harness, from, "reply", id, 3000, &reply), "reply to %s", id);
    if (snapshot_index) *snapshot_index = szft_find_frame(harness, from, "snapshot", NULL);
    return reply;
}

static cJSON *data_of(szft_client *harness, long index) {
    cJSON *frame = szft_frame_json(harness, index);
    cJSON *data = cJSON_DetachItemFromObjectCaseSensitive(frame, "data");
    cJSON_Delete(frame);
    return data;
}

static bool data_matches_fixture(szft_client *harness, long index, const char *fixture) {
    cJSON *data = data_of(harness, index), *expected = szft_read_json(fixture);
    bool same = data && expected && cJSON_Compare(data, cJSON_GetObjectItemCaseSensitive(expected, "data"), 1);
    cJSON_Delete(data);
    cJSON_Delete(expected);
    return same;
}

static void test_subscription_flow(void) {
    char *state = szft_temp_dir("subscribe");
    szfriends_fake_helper *fake;
    szft_client *harness = ready_client(state, &fake);
    char id[24], subscription[24];
    long reply, snapshot = -1, next = -1;
    cJSON *frame, *data;
    size_t from;

    reply = round_trip(harness, szfriends_intent_subscribe("list", NULL), id, &snapshot);
    frame = szft_frame_json(harness, reply);
    snprintf(subscription, sizeof subscription, "%s",
             str_or_empty(cJSON_GetObjectItemCaseSensitive(frame, "result"), "subscription"));
    cJSON_Delete(frame);
    EXPECT(subscription[0], "subscribe result names the subscription");
    EXPECT(snapshot >= 0 && snapshot < reply, "the first snapshot precedes the reply (PROTOCOL.md § Snapshots)");
    frame = szft_frame_json(harness, snapshot);
    EXPECT(frame && strcmp(str(frame, "subscription"), subscription) == 0 && strcmp(str(frame, "view"), "list") == 0 &&
               cJSON_GetObjectItemCaseSensitive(frame, "rev")->valuedouble == 1,
           "snapshot names the subscription, view and rev 1");
    cJSON_Delete(frame);
    EXPECT(data_matches_fixture(harness, snapshot, "snapshots/list.json"), "list snapshot is the fixture");

    /* A scripted state change reaches the subscriber as the next rev. */
    from = harness->frame_count;
    szfriends_fake_helper_set_view_fixture(fake, "list", "list-id-changed.json");
    EXPECT(szft_wait_frame(harness, from, "snapshot", NULL, 3000, &next), "state change pushed");
    frame = szft_frame_json(harness, next);
    EXPECT(frame && cJSON_GetObjectItemCaseSensitive(frame, "rev")->valuedouble == 2, "rev 2");
    cJSON_Delete(frame);
    EXPECT(data_matches_fixture(harness, next, "snapshots/list-id-changed.json"), "the id-changed list");

    /* set_filter on the original list keeps only matching rows. */
    szfriends_fake_helper_set_view_fixture(fake, "list", "list.json");
    reply = round_trip(harness, szfriends_intent_set_filter(subscription, "mei"), id, NULL);
    /* The fixture swap above publishes too; the filtered snapshot is the last one before the reply. */
    for (next = reply - 1; next >= 0 && szft_find_frame(harness, (size_t)next, "snapshot", NULL) != next; next--) {
    }
    EXPECT(next >= 0, "filtered snapshot before the reply");
    data = data_of(harness, next);
    EXPECT(data && cJSON_GetArraySize(cJSON_GetObjectItemCaseSensitive(data, "rows")) == 1 &&
               strcmp(str(data, "query"), "mei") == 0,
           "filtered to one row");
    cJSON_Delete(data);

    /* After unsubscribing nothing more arrives for it. */
    round_trip(harness, szfriends_intent_unsubscribe(subscription), id, NULL);
    from = harness->frame_count;
    szfriends_fake_helper_set_view_fixture(fake, "list", "list-id-changed.json");
    szft_pump(harness, NULL, NULL, 200);
    EXPECT(szft_find_frame(harness, from, "snapshot", NULL) < 0, "no snapshot after unsubscribe");

    /* Subscription ids never survive a reconnect: the host subscribes again from on_state(READY). */
    harness->resubscribe_view = "badge";
    from = harness->frame_count;
    szfriends_fake_helper_drop_clients(fake);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_WAITING, 3000), "dropped");
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 3000), "back");
    EXPECT(szft_wait_frame(harness, from, "reply", harness->resubscribe_id, 3000, &reply), "resubscribed");
    frame = szft_frame_json(harness, reply);
    EXPECT(frame && strcmp(str(cJSON_GetObjectItemCaseSensitive(frame, "result"), "subscription"), subscription) != 0,
           "a fresh subscription id");
    cJSON_Delete(frame);

    /* open_conversation with a message highlights it; a details subscription for someone unknown is not found. */
    reply = round_trip(harness, szfriends_intent_open_conversation("c_mei", "m_a4109f52"), id, &snapshot);
    data = data_of(harness, snapshot);
    EXPECT(data && str(data, "highlight_item_id") && strcmp(str(data, "highlight_item_id"), "m_a4109f52") == 0,
           "highlight_item_id set");
    cJSON_Delete(data);
    reply = round_trip(harness, szfriends_intent_subscribe("details", "c_nobody"), id, NULL);
    frame = szft_frame_json(harness, reply);
    EXPECT(frame && strcmp(str(cJSON_GetObjectItemCaseSensitive(frame, "error"), "code"), "not_found") == 0,
           "unknown conversation: not_found");
    cJSON_Delete(frame);
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

/* Replaces the fixture's subscription id with a live one of the right kind, so the round trip succeeds. */
static void use_live_subscription(cJSON *line, const char *list, const char *conversation, const char *details) {
    const char *type = str(line, "type");
    const char *live = NULL;
    if (strcmp(type, "set_filter") == 0) live = list;
    else if (strcmp(type, "load_earlier") == 0) live = conversation;
    else if (strcmp(type, "unsubscribe") == 0) live = details;
    if (live) cJSON_ReplaceItemInObjectCaseSensitive(line, "subscription", cJSON_CreateString(live));
}

static void subscription_of(szft_client *harness, long reply, char *out) {
    cJSON *frame = szft_frame_json(harness, reply);
    snprintf(out, 24, "%s", str_or_empty(cJSON_GetObjectItemCaseSensitive(frame, "result"), "subscription"));
    cJSON_Delete(frame);
}

static void test_every_intent_round_trip(void) {
    char *state = szft_temp_dir("intents");
    szfriends_fake_helper *fake;
    szft_client *harness = ready_client(state, &fake);
    char path[4096], text[16384], id[24], list[24], conversation[24], details[24];
    FILE *file;
    size_t count = 0;

    subscription_of(harness, round_trip(harness, szfriends_intent_subscribe("list", NULL), id, NULL), list);
    subscription_of(harness, round_trip(harness, szfriends_intent_open_conversation("c_mei", NULL), id, NULL),
                    conversation);
    subscription_of(harness, round_trip(harness, szfriends_intent_subscribe("details", "c_mei"), id, NULL), details);
    snprintf(path, sizeof path, "%s/intents.jsonl", szft_fixtures);
    file = fopen(path, "r");
    while (file && fgets(text, sizeof text, file)) {
        cJSON *line = cJSON_Parse(text), *frame, *sent, *expected_reply;
        char reply_fixture[128], *sent_text;
        const char *type;
        long reply, snapshot = -1;
        size_t frames_at_fake;
        if (!line) continue;
        use_live_subscription(line, list, conversation, details);
        type = str(line, "type");
        frames_at_fake = szfriends_fake_helper_frame_count(fake);
        reply = round_trip(harness, szft_intent_from_fixture(line), id, &snapshot);
        frame = szft_frame_json(harness, reply);
        EXPECT(frame && cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(frame, "ok")), "%s succeeds", type);

        /* What crossed the socket is the fixture line, apart from the id the library chose. */
        sent_text = szfriends_fake_helper_copy_frame(fake, frames_at_fake);
        sent = cJSON_Parse(sent_text);
        cJSON_ReplaceItemInObjectCaseSensitive(sent, "id", cJSON_CreateString("x"));
        cJSON_ReplaceItemInObjectCaseSensitive(line, "id", cJSON_CreateString("x"));
        EXPECT(szft_json_equivalent(sent, line), "%s sent as the fixture: %s", type, sent_text);

        snprintf(reply_fixture, sizeof reply_fixture, "replies/%s.json", type);
        if (strcmp(type, "subscribe") == 0 || strcmp(type, "open_conversation") == 0) {
            EXPECT(snapshot >= 0 && snapshot < reply, "%s: snapshot before reply", type);
        } else {
            char reply_path[4096];
            snprintf(reply_path, sizeof reply_path, "%s/%s", szft_fixtures, reply_fixture);
            if (access(reply_path, R_OK) == 0) {
                expected_reply = szft_read_json(reply_fixture);
                EXPECT(cJSON_Compare(cJSON_GetObjectItemCaseSensitive(frame, "result"),
                                     cJSON_GetObjectItemCaseSensitive(expected_reply, "result"), 1),
                       "%s result is the fixture's", type);
                cJSON_Delete(expected_reply);
            } else {
                const cJSON *result = cJSON_GetObjectItemCaseSensitive(frame, "result");
                EXPECT(cJSON_IsObject(result) && !result->child, "%s: empty result", type);
            }
        }
        szfriends_free(sent_text);
        cJSON_Delete(sent);
        cJSON_Delete(frame);
        cJSON_Delete(line);
        count++;
    }
    if (file) fclose(file);
    EXPECT(count >= 67, "every intent line ran (%zu)", count);

    /* A scripted error reply reaches the host as the fixture's failed reply. */
    {
        cJSON *error_frame = szft_read_json("frames/reply-error.json"), *frame;
        char *error_text = cJSON_PrintUnformatted(error_frame);
        long reply;
        szfriends_fake_helper_set_reply(fake, "accept_offer", error_text);
        reply = round_trip(harness, szfriends_intent_accept_offer("t_kenji_site"), id, NULL);
        frame = szft_frame_json(harness, reply);
        EXPECT(frame && strcmp(str(cJSON_GetObjectItemCaseSensitive(frame, "error"), "code"), "disk_full") == 0,
               "scripted disk_full");
        cJSON_Delete(frame);
        szfriends_free(error_text);
        cJSON_Delete(error_frame);
    }
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

static void test_goodbye_and_stop(void) {
    char *state = szft_temp_dir("goodbye");
    szfriends_fake_helper *fake;
    szft_client *harness = ready_client(state, &fake);
    size_t from = harness->frame_count, frames_at_fake;
    char *last;
    int64_t next;

    /* Reset Friends: reconnect at once. */
    szfriends_fake_helper_send_goodbye(fake, "{\"type\":\"goodbye\",\"reason\":\"reset\",\"message\":null,"
                                             "\"successor\":null,\"error\":null}");
    /* Read without ticking, so the retry the goodbye scheduled is still pending when inspected. */
    {
        uint64_t deadline = szfriends_monotonic_ms() + 3000;
        while (szfriends_client_fd(harness->client) >= 0 && szfriends_monotonic_ms() < deadline) {
            struct pollfd readable;
            readable.fd = szfriends_client_fd(harness->client);
            readable.events = POLLIN;
            readable.revents = 0;
            if (poll(&readable, 1, 20) > 0) szfriends_client_on_readable(harness->client);
        }
    }
    EXPECT(szft_find_frame(harness, from, "goodbye", NULL) >= 0, "goodbye delivered to the host");
    next = szfriends_client_next_tick_ms(harness->client, szfriends_monotonic_ms());
    EXPECT(next >= 0 && next <= 5 && szfriends_client_fd(harness->client) < 0, "reset reconnects at once (%lld)",
           (long long)next);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 3000), "READY after reset");

    /* Turning Friends off in this app sends disable, then returns to IDLE. */
    frames_at_fake = szfriends_fake_helper_frame_count(fake);
    EXPECT(szfriends_client_stop(harness->client, true) == SZFRIENDS_OK, "stop");
    EXPECT(szfriends_client_state(harness->client) == SZFRIENDS_CONNECTION_IDLE, "IDLE");
    EXPECT(szfriends_client_fd(harness->client) < 0 &&
               szfriends_client_next_tick_ms(harness->client, szfriends_monotonic_ms()) == -1,
           "nothing left to do");
    szft_sleep_ms(200);
    last = szfriends_fake_helper_copy_frame(fake, frames_at_fake);
    EXPECT(last && strstr(last, "\"type\":\"disable\""), "the helper received disable: %s", last ? last : "-");
    szfriends_free(last);
    EXPECT(szfriends_client_on_readable(harness->client) == SZFRIENDS_ERR_CLOSED, "stopped client is closed");
    EXPECT(szfriends_client_stop(harness->client, true) == SZFRIENDS_OK, "stop twice");
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

void szft_run_flow_tests(void) {
    test_subscription_flow();
    test_every_intent_round_trip();
    test_goodbye_and_stop();
}
