/* Shenzhen Friends fake helper: what it answers to each client frame.
 *
 * Follows PROTOCOL.md where a view or the client library could notice: hello first or hello_required, version
 * negotiation with protocol_unsupported and the handover request, the snapshot before the reply of subscribe and
 * open_conversation, rev starting at 1 per subscription, the per-connection subscription limit, unknown intents.
 * It does not change state on its own (accept_offer leaves the offer waiting); tests script changes. */

#include "client/fake/szfriends_fake_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

void szf_fake_send_text(szf_fake_connection *connection, const char *text, size_t length) {
    size_t needed = connection->out_length + length;
    if (connection->out_offset > 0) {
        memmove(connection->out, connection->out + connection->out_offset,
                connection->out_length - connection->out_offset);
        connection->out_length -= connection->out_offset;
        connection->out_offset = 0;
        needed = connection->out_length + length;
    }
    if (needed > connection->out_capacity) {
        size_t capacity = connection->out_capacity ? connection->out_capacity : 4096;
        char *grown;
        while (capacity < needed) capacity *= 2;
        grown = (char *)realloc(connection->out, capacity);
        if (!grown) return; /* the client sees a missing frame; acceptable in a test fake */
        connection->out = grown;
        connection->out_capacity = capacity;
    }
    memcpy(connection->out + connection->out_length, text, length);
    connection->out_length += length;
}

void szf_fake_send_frame(szf_fake_connection *connection, cJSON *frame) {
    char *text = cJSON_PrintUnformatted(frame);
    cJSON_Delete(frame);
    if (!text) return;
    szf_fake_send_text(connection, text, strlen(text));
    szf_fake_send_text(connection, "\n", 1);
    free(text);
}

static cJSON *reply_ok(const char *re, cJSON *result) {
    cJSON *frame = cJSON_CreateObject();
    cJSON_AddStringToObject(frame, "type", "reply");
    if (re) cJSON_AddStringToObject(frame, "re", re);
    else cJSON_AddNullToObject(frame, "re");
    cJSON_AddTrueToObject(frame, "ok");
    cJSON_AddItemToObject(frame, "result", result ? result : cJSON_CreateObject());
    return frame;
}

static cJSON *reply_error(const char *re, const char *code, bool retryable, cJSON *details) {
    cJSON *frame = cJSON_CreateObject(), *error;
    cJSON_AddStringToObject(frame, "type", "reply");
    if (re) cJSON_AddStringToObject(frame, "re", re);
    else cJSON_AddNullToObject(frame, "re");
    cJSON_AddFalseToObject(frame, "ok");
    error = cJSON_AddObjectToObject(frame, "error");
    cJSON_AddStringToObject(error, "code", code);
    cJSON_AddNullToObject(error, "message"); /* protocol-level errors carry no text for people */
    cJSON_AddBoolToObject(error, "retryable", retryable);
    cJSON_AddItemToObject(error, "details", details ? details : cJSON_CreateObject());
    return frame;
}

static cJSON *goodbye(const char *reason, cJSON *error) {
    cJSON *frame = cJSON_CreateObject();
    cJSON_AddStringToObject(frame, "type", "goodbye");
    cJSON_AddStringToObject(frame, "reason", reason);
    cJSON_AddNullToObject(frame, "message");
    cJSON_AddNullToObject(frame, "successor");
    if (error) cJSON_AddItemToObject(frame, "error", error);
    else cJSON_AddNullToObject(frame, "error");
    return frame;
}

static cJSON *error_object(const char *code) {
    cJSON *error = cJSON_CreateObject();
    cJSON_AddStringToObject(error, "code", code);
    cJSON_AddNullToObject(error, "message");
    cJSON_AddFalseToObject(error, "retryable");
    cJSON_AddItemToObject(error, "details", cJSON_CreateObject());
    return error;
}

static const char *string_field(const cJSON *object, const char *key) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsString(item) ? item->valuestring : NULL;
}

static int int_field(const cJSON *object, const char *key, int fallback) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsNumber(item) ? (int)item->valuedouble : fallback;
}

static void welcome_client(szfriends_fake_helper *fake, szf_fake_connection *connection, const cJSON *hello,
                           const char *id) {
    const cJSON *protocol = cJSON_GetObjectItemCaseSensitive(hello, "protocol");
    const cJSON *embedded = cJSON_GetObjectItemCaseSensitive(hello, "embedded_helper");
    int major = 0, minor = 0;
    bool newer = false;
    cJSON *welcome, *helper, *helper_protocol, *negotiated;

    if (cJSON_IsObject(embedded)) {
        const cJSON *embedded_protocol = cJSON_GetObjectItemCaseSensitive(embedded, "protocol");
        int embedded_major = int_field(embedded_protocol, "major", 0);
        int embedded_minor = int_field(embedded_protocol, "minor", 0);
        const cJSON *build = cJSON_GetObjectItemCaseSensitive(embedded, "build_number");
        double embedded_build = cJSON_IsNumber(build) ? build->valuedouble : 0;
        /* PROTOCOL.md § Handshake, handover request: protocol major, then minor, then build number. */
        newer = embedded_major != fake->major ? embedded_major > fake->major
              : embedded_minor != fake->minor ? embedded_minor > fake->minor
                                              : embedded_build > (double)fake->build_number;
        if (newer && !fake->handover_at) {
            const char *version = string_field(embedded, "version");
            free(fake->handover_version);
            fake->handover_version = strdup(version ? version : "");
            fake->handover_build = embedded_build;
            fake->handover_at = szfriends_monotonic_ms() + (uint64_t)fake->handover_delay_ms;
        }
    }
    if (!szfriends_negotiate(fake->major, fake->minor, fake->min_major, int_field(protocol, "major", 0),
                             int_field(protocol, "minor", 0), int_field(protocol, "min_major", 0), &major, &minor)) {
        cJSON *details = cJSON_CreateObject();
        cJSON_AddNumberToObject(details, "helper_major", fake->major);
        cJSON_AddNumberToObject(details, "helper_min_major", fake->min_major);
        if (newer) cJSON_AddStringToObject(details, "handover", "scheduled");
        szf_fake_send_frame(connection, reply_error(id, "protocol_unsupported", false, details));
        szf_fake_send_frame(connection, goodbye("protocol_error", error_object("protocol_unsupported")));
        connection->closing = true;
        return;
    }
    welcome = cJSON_Duplicate(fake->welcome, 1);
    cJSON_ReplaceItemInObjectCaseSensitive(welcome, "re", cJSON_CreateString(id));
    negotiated = cJSON_CreateObject();
    cJSON_AddNumberToObject(negotiated, "major", major);
    cJSON_AddNumberToObject(negotiated, "minor", minor);
    cJSON_ReplaceItemInObjectCaseSensitive(welcome, "protocol", negotiated);
    helper = cJSON_GetObjectItemCaseSensitive(welcome, "helper");
    if (fake->version) cJSON_ReplaceItemInObjectCaseSensitive(helper, "version", cJSON_CreateString(fake->version));
    if (fake->build_number)
        cJSON_ReplaceItemInObjectCaseSensitive(helper, "build_number", cJSON_CreateNumber((double)fake->build_number));
    helper_protocol = cJSON_CreateObject();
    cJSON_AddNumberToObject(helper_protocol, "major", fake->major);
    cJSON_AddNumberToObject(helper_protocol, "minor", fake->minor);
    cJSON_ReplaceItemInObjectCaseSensitive(helper, "protocol", helper_protocol);
    cJSON_ReplaceItemInObjectCaseSensitive(helper, "pid", cJSON_CreateNumber((double)getpid()));
    cJSON_ReplaceItemInObjectCaseSensitive(welcome, "handover", cJSON_CreateString(newer ? "scheduled" : "none"));
    szf_fake_send_frame(connection, welcome);
    connection->greeted = true;
}

/* Rows (list) or people (nearby) whose title contains the query, ASCII case-insensitively. Enough for views'
 * tests; the real helper matches names and IDs through the catalog's rules. */
static void apply_filter(cJSON *data, const char *view, const char *query) {
    const char *key = strcmp(view, "list") == 0 ? "rows" : "people";
    cJSON *items = cJSON_GetObjectItemCaseSensitive(data, key);
    cJSON *item = items ? items->child : NULL;
    size_t query_length = strlen(query);
    cJSON_ReplaceItemInObjectCaseSensitive(data, "query", cJSON_CreateString(query));
    if (query_length == 0) return;
    while (item) {
        cJSON *next = item->next;
        const char *title = string_field(item, "title");
        bool match = false;
        size_t i;
        for (i = 0; title && !match && title[i]; i++) match = strncasecmp(title + i, query, query_length) == 0;
        if (!match) cJSON_Delete(cJSON_DetachItemViaPointer(items, item));
        item = next;
    }
}

static cJSON *data_for(szfriends_fake_helper *fake, const szf_fake_subscription *subscription) {
    cJSON *source = NULL, *data;
    if (strcmp(subscription->view, "conversation") == 0)
        source = szf_fake_find_by_conversation(fake->conversations, subscription->conversation_id);
    else if (strcmp(subscription->view, "details") == 0)
        source = szf_fake_find_by_conversation(fake->details, subscription->conversation_id);
    else
        source = cJSON_GetObjectItemCaseSensitive(fake->views, subscription->view);
    if (!source) return NULL;
    data = cJSON_Duplicate(source, 1);
    if (subscription->query && (strcmp(subscription->view, "list") == 0 || strcmp(subscription->view, "nearby") == 0))
        apply_filter(data, subscription->view, subscription->query);
    if (strcmp(subscription->view, "conversation") == 0) {
        cJSON *item;
        if (subscription->earlier_loaded)
            cJSON_ReplaceItemInObjectCaseSensitive(data, "has_earlier", cJSON_CreateFalse());
        if (subscription->message_id[0]) {
            cJSON_ReplaceItemInObjectCaseSensitive(data, "highlight_item_id",
                                                   cJSON_CreateString(subscription->message_id));
            cJSON_ArrayForEach(item, cJSON_GetObjectItemCaseSensitive(data, "items")) {
                const char *item_id = string_field(item, "item_id");
                cJSON_ReplaceItemInObjectCaseSensitive(
                    item, "highlighted", cJSON_CreateBool(item_id && strcmp(item_id, subscription->message_id) == 0));
            }
        }
    }
    return data;
}

static szf_fake_connection *connection_numbered(szfriends_fake_helper *fake, int number) {
    int i;
    for (i = 0; i < SZF_FAKE_MAX_CONNECTIONS; i++)
        if (fake->connections[i] && fake->connections[i]->number == number) return fake->connections[i];
    return NULL;
}

static void send_snapshot(szfriends_fake_helper *fake, szf_fake_subscription *subscription) {
    szf_fake_connection *connection = connection_numbered(fake, subscription->connection);
    cJSON *data = data_for(fake, subscription), *frame;
    if (!connection || !data) {
        cJSON_Delete(data);
        return;
    }
    frame = cJSON_CreateObject();
    cJSON_AddStringToObject(frame, "type", "snapshot");
    cJSON_AddStringToObject(frame, "subscription", subscription->id);
    cJSON_AddStringToObject(frame, "view", subscription->view);
    cJSON_AddNumberToObject(frame, "rev", (double)++subscription->rev);
    cJSON_AddItemToObject(frame, "data", data);
    szf_fake_send_frame(connection, frame);
}

void szf_fake_publish_view(szfriends_fake_helper *fake, const char *view, const char *conversation_id) {
    size_t i;
    for (i = 0; i < fake->subscription_count; i++) {
        szf_fake_subscription *subscription = &fake->subscriptions[i];
        if (strcmp(subscription->view, view) != 0) continue;
        if (conversation_id && strcmp(subscription->conversation_id, conversation_id) != 0) continue;
        send_snapshot(fake, subscription);
    }
}

void szf_fake_remove_subscriptions(szfriends_fake_helper *fake, int connection_number) {
    size_t i = 0;
    while (i < fake->subscription_count) {
        if (fake->subscriptions[i].connection != connection_number) {
            i++;
            continue;
        }
        free(fake->subscriptions[i].query);
        fake->subscriptions[i] = fake->subscriptions[--fake->subscription_count];
    }
}

static szf_fake_subscription *find_subscription(szfriends_fake_helper *fake, int connection, const char *id) {
    size_t i;
    for (i = 0; id && i < fake->subscription_count; i++)
        if (fake->subscriptions[i].connection == connection && strcmp(fake->subscriptions[i].id, id) == 0)
            return &fake->subscriptions[i];
    return NULL;
}

static szf_fake_subscription *add_subscription(szfriends_fake_helper *fake, szf_fake_connection *connection,
                                               const char *view, const char *conversation_id) {
    szf_fake_subscription *subscription;
    size_t i, mine = 0;
    for (i = 0; i < fake->subscription_count; i++) mine += fake->subscriptions[i].connection == connection->number;
    if (mine >= SZF_FAKE_MAX_SUBSCRIPTIONS) return NULL;
    if (fake->subscription_count == fake->subscription_capacity) {
        size_t capacity = fake->subscription_capacity ? fake->subscription_capacity * 2 : 16;
        szf_fake_subscription *grown =
            (szf_fake_subscription *)realloc(fake->subscriptions, capacity * sizeof *grown);
        if (!grown) return NULL;
        fake->subscriptions = grown;
        fake->subscription_capacity = capacity;
    }
    subscription = &fake->subscriptions[fake->subscription_count++];
    memset(subscription, 0, sizeof *subscription);
    snprintf(subscription->id, sizeof subscription->id, "s_%ld", ++fake->next_subscription_number);
    subscription->connection = connection->number;
    snprintf(subscription->view, sizeof subscription->view, "%s", view);
    if (conversation_id) snprintf(subscription->conversation_id, sizeof subscription->conversation_id, "%s",
                                  conversation_id);
    return subscription;
}

static cJSON *field_error(const char *field) {
    cJSON *details = cJSON_CreateObject();
    cJSON_AddStringToObject(details, "field", field);
    return details;
}

static void handle_subscribe(szfriends_fake_helper *fake, szf_fake_connection *connection, const cJSON *frame,
                             const char *id, bool conversation) {
    const char *view = conversation ? "conversation" : string_field(frame, "view");
    const cJSON *params = cJSON_GetObjectItemCaseSensitive(frame, "params");
    const char *conversation_id = conversation ? string_field(frame, "conversation_id")
                                               : string_field(params, "conversation_id");
    const char *message_id = string_field(frame, "message_id");
    static const char *const views[] = {"badge", "list", "nearby", "details", "profile", "settings", "message_status",
                                        "join"};
    szf_fake_subscription probe, *subscription;
    cJSON *result;
    size_t i;
    bool known = conversation;

    for (i = 0; view && !known && i < sizeof views / sizeof views[0]; i++) known = strcmp(view, views[i]) == 0;
    if (!known || (conversation && !conversation_id) || (view && strcmp(view, "details") == 0 && !conversation_id)) {
        szf_fake_send_frame(connection, reply_error(id, "invalid_field", false,
                                                    field_error(conversation || known ? "conversation_id" : "view")));
        return;
    }
    memset(&probe, 0, sizeof probe);
    snprintf(probe.view, sizeof probe.view, "%s", view);
    if (conversation_id) snprintf(probe.conversation_id, sizeof probe.conversation_id, "%s", conversation_id);
    {
        cJSON *data = data_for(fake, &probe);
        if (!data) {
            szf_fake_send_frame(connection, reply_error(id, "not_found", false, NULL));
            return;
        }
        cJSON_Delete(data);
    }
    subscription = add_subscription(fake, connection, view, conversation_id);
    if (!subscription) {
        szf_fake_send_frame(connection, reply_error(id, "too_many_subscriptions", false, NULL));
        return;
    }
    if (message_id) snprintf(subscription->message_id, sizeof subscription->message_id, "%s", message_id);
    send_snapshot(fake, subscription); /* PROTOCOL.md § Snapshots: the first snapshot precedes the reply */
    result = cJSON_CreateObject();
    cJSON_AddStringToObject(result, "subscription", subscription->id);
    if (conversation) cJSON_AddStringToObject(result, "conversation_id", conversation_id);
    szf_fake_send_frame(connection, reply_ok(id, result));
}

static void handle_intent(szfriends_fake_helper *fake, szf_fake_connection *connection, const cJSON *frame,
                          const char *type, const char *id) {
    const cJSON *scripted = cJSON_GetObjectItemCaseSensitive(fake->scripted, type);
    const cJSON *fixture;
    szf_fake_subscription *subscription;

    if (!szf_fake_is_intent(type)) {
        szf_fake_send_frame(connection, reply_error(id, "unknown_intent", false, NULL));
        return;
    }
    if (scripted) {
        cJSON *reply = cJSON_Duplicate(scripted, 1);
        cJSON_ReplaceItemInObjectCaseSensitive(reply, "re", cJSON_CreateString(id));
        szf_fake_send_frame(connection, reply);
        return;
    }
    if (strcmp(type, "subscribe") == 0 || strcmp(type, "open_conversation") == 0) {
        handle_subscribe(fake, connection, frame, id, strcmp(type, "open_conversation") == 0);
        return;
    }
    if (strcmp(type, "unsubscribe") == 0 || strcmp(type, "set_filter") == 0 || strcmp(type, "load_earlier") == 0) {
        subscription = find_subscription(fake, connection->number, string_field(frame, "subscription"));
        if (!subscription) {
            szf_fake_send_frame(connection, reply_error(id, "not_found", false, NULL));
            return;
        }
        if (strcmp(type, "unsubscribe") == 0) {
            free(subscription->query);
            *subscription = fake->subscriptions[--fake->subscription_count];
        } else if (strcmp(type, "set_filter") == 0) {
            const char *query = string_field(frame, "query");
            free(subscription->query);
            subscription->query = strdup(query ? query : "");
            send_snapshot(fake, subscription);
        } else {
            subscription->earlier_loaded = true;
            send_snapshot(fake, subscription);
        }
        szf_fake_send_frame(connection, reply_ok(id, NULL));
        return;
    }
    fixture = cJSON_GetObjectItemCaseSensitive(fake->replies, type);
    if (fixture) {
        cJSON *reply = cJSON_Duplicate(fixture, 1);
        cJSON_ReplaceItemInObjectCaseSensitive(reply, "re", cJSON_CreateString(id));
        szf_fake_send_frame(connection, reply);
        return;
    }
    szf_fake_send_frame(connection, reply_ok(id, NULL));
}

void szf_fake_handle_line(szfriends_fake_helper *fake, szf_fake_connection *connection, const char *line,
                          size_t length) {
    cJSON *frame = cJSON_ParseWithLength(line, length);
    const char *type = string_field(frame, "type");
    const char *id = string_field(frame, "id");
    szf_fake_frame_hook hook;
    void *hook_data;

    pthread_mutex_lock(&fake->mutex);
    hook = fake->frame_hook;
    hook_data = fake->frame_hook_data;
    if (fake->frame_count == fake->frame_capacity) {
        size_t capacity = fake->frame_capacity ? fake->frame_capacity * 2 : 64;
        char **grown = (char **)realloc(fake->frames, capacity * sizeof *grown);
        if (grown) {
            fake->frames = grown;
            fake->frame_capacity = capacity;
        }
    }
    if (fake->frame_count < fake->frame_capacity) {
        char *copy = (char *)malloc(length + 1);
        if (copy) {
            memcpy(copy, line, length);
            copy[length] = '\0';
            fake->frames[fake->frame_count++] = copy;
        }
    }
    pthread_mutex_unlock(&fake->mutex);
    if (hook) hook(fake, line, length, hook_data); /* outside the lock: a hook may script the fake */

    if (!cJSON_IsObject(frame) || !type || !id || !id[0] || strlen(id) > 32) {
        szf_fake_send_frame(connection, goodbye("protocol_error", error_object("bad_frame")));
        connection->closing = true;
    } else if (!connection->greeted) {
        const cJSON *scripted = cJSON_GetObjectItemCaseSensitive(fake->scripted, "hello");
        if (strcmp(type, "hello") == 0 && scripted) {
            /* A scripted answer to hello (an invalid_field reply, say); the connection stays open, as a helper
             * answering a bad field does, so the client must end the attempt itself. */
            cJSON *reply = cJSON_Duplicate(scripted, 1);
            cJSON_ReplaceItemInObjectCaseSensitive(reply, "re", cJSON_CreateString(id));
            szf_fake_send_frame(connection, reply);
        } else if (strcmp(type, "hello") == 0) {
            welcome_client(fake, connection, frame, id);
        } else {
            szf_fake_send_frame(connection, reply_error(id, "hello_required", false, NULL));
            connection->closing = true;
        }
    } else if (!fake->holding) {
        handle_intent(fake, connection, frame, type, id);
    }
    cJSON_Delete(frame);
}

void szf_fake_goodbye_all(szfriends_fake_helper *fake, cJSON *frame) {
    int i;
    for (i = 0; i < SZF_FAKE_MAX_CONNECTIONS; i++) {
        szf_fake_connection *connection = fake->connections[i];
        if (!connection) continue;
        szf_fake_send_frame(connection, cJSON_Duplicate(frame, 1));
        connection->closing = true;
    }
    cJSON_Delete(frame);
}
