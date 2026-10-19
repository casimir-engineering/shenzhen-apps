/* SZFriendsGtkLink routes: subscriptions that survive reconnects, replies matched to intents, the shared badge.
 * Mirrors mac/SZFriendsHelperLink.m so both toolkits keep the same guarantees. */

#include "gtk/szfriends_gtk_link_private.h"
#include "gtk/szfriends_gtk_internal.h"

static void sub_free(gpointer data) {
    SZFriendsGtkLinkSub *sub = data;
    if (sub->destroy) sub->destroy(sub->user_data);
    g_free(sub->view);
    g_free(sub->conversation_id);
    g_free(sub->message_id);
    g_free(sub->filter);
    g_free(sub->server_id);
    g_strfreev(sub->message_ids);
    g_free(sub);
}

static void reply_free(gpointer data) {
    SZFriendsGtkLinkReply *reply = data;
    if (reply->destroy) reply->destroy(reply->user_data);
    g_free(reply->frame_id);
    g_free(reply->fail_code);
    g_free(reply);
}

static void on_badge(JsonObject *data, gint64 rev, gpointer user_data);

void szfriends_gtk_link_routes_init(SZFriendsGtkLink *link) {
    link->subs = g_ptr_array_new_with_free_func(sub_free);
    link->by_server = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    link->subscribe_frames = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    link->abandoned_frames = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    link->early = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)json_object_unref);
    link->replies = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    link->requests = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, reply_free);
    g_queue_init(&link->failures);
    link->badge_watches = g_ptr_array_new_with_free_func(szfriends_gtk_link_watch_free);
    /* One badge subscription for every window's button (the helper allows 32 per connection). */
    link->badge_token = szfriends_gtk_link_subscribe(link, "badge", NULL, on_badge, link, NULL);
}

void szfriends_gtk_link_routes_clear(SZFriendsGtkLink *link) {
    if (link->failure_idle) g_source_remove(link->failure_idle);
    link->failure_idle = 0;
    g_queue_clear(&link->failures);
    g_hash_table_unref(link->replies);
    g_hash_table_unref(link->requests); /* destroy notifies run; reply functions do not */
    g_hash_table_unref(link->by_server);
    g_hash_table_unref(link->subscribe_frames);
    g_hash_table_unref(link->abandoned_frames);
    g_hash_table_unref(link->early);
    g_ptr_array_free(link->subs, TRUE);
    g_ptr_array_free(link->badge_watches, TRUE);
    szfriends_gtk_badge_snapshot_free(link->badge);
}

static SZFriendsGtkLinkSub *find_sub(SZFriendsGtkLink *link, guint token) {
    for (guint i = 0; i < link->subs->len; i++) {
        SZFriendsGtkLinkSub *sub = g_ptr_array_index(link->subs, i);
        if (sub->token == token) return sub;
    }
    return NULL;
}

/* Sends one intent now. Returns the frame id or NULL with the client-side code. */
static char *send_now(SZFriendsGtkLink *link, szfriends_intent *intent, const char **code) {
    char id[32] = {0};
    szfriends_status status = SZFRIENDS_ERR_NOT_READY;
    if (!intent) {
        *code = "invalid_field";
        return NULL;
    }
    if (!link->client || link->state != SZFRIENDS_GTK_LINK_READY) {
        szfriends_intent_free(intent);
        *code = "not_ready";
        return NULL;
    }
    szfriends_gtk_link_ref(link);
    status = szfriends_client_send_intent(link->client, intent, id, sizeof id);
    szfriends_gtk_link_after_call(link);
    szfriends_gtk_link_unref(link);
    if (status == SZFRIENDS_OK) return g_strdup(id);
    *code = status == SZFRIENDS_ERR_NOT_READY ? "not_ready"
            : status == SZFRIENDS_ERR_FRAME_TOO_LARGE ? "frame_too_large" : "internal";
    return NULL;
}

static void send_subscribe(SZFriendsGtkLink *link, SZFriendsGtkLinkSub *sub) {
    szfriends_intent *intent = NULL;
    if (sub->kind == SZFRIENDS_GTK_SUB_CONVERSATION)
        intent = szfriends_intent_open_conversation(sub->conversation_id, sub->message_id);
    else if (sub->kind == SZFRIENDS_GTK_SUB_MESSAGE_STATUS)
        intent = szfriends_intent_subscribe_message_status((const char *const *)sub->message_ids,
                                                           g_strv_length(sub->message_ids));
    else
        intent = szfriends_intent_subscribe(sub->view, sub->conversation_id);
    const char *code = NULL;
    char *frame = send_now(link, intent, &code);
    if (frame) g_hash_table_insert(link->subscribe_frames, frame, GUINT_TO_POINTER(sub->token));
}

static guint add_sub(SZFriendsGtkLink *link, SZFriendsGtkLinkSub *sub) {
    sub->token = ++link->next_token;
    g_ptr_array_add(link->subs, sub);
    if (link->state == SZFRIENDS_GTK_LINK_READY) send_subscribe(link, sub);
    return sub->token;
}

static SZFriendsGtkLinkSub *new_sub(SZFriendsGtkLinkSubKind kind, SZFriendsGtkSnapshotFunc func, gpointer data,
                                    GDestroyNotify destroy) {
    SZFriendsGtkLinkSub *sub = g_new0(SZFriendsGtkLinkSub, 1);
    sub->kind = kind;
    sub->func = func;
    sub->user_data = data;
    sub->destroy = destroy;
    return sub;
}

guint szfriends_gtk_link_subscribe(SZFriendsGtkLink *link, const char *view, const char *conversation_id,
                                   SZFriendsGtkSnapshotFunc func, gpointer data, GDestroyNotify destroy) {
    g_return_val_if_fail(link && view && func, 0);
    SZFriendsGtkLinkSub *sub = new_sub(SZFRIENDS_GTK_SUB_VIEW, func, data, destroy);
    sub->view = g_strdup(view);
    sub->conversation_id = g_strdup(conversation_id);
    return add_sub(link, sub);
}

guint szfriends_gtk_link_subscribe_message_status(SZFriendsGtkLink *link, const char *const *message_ids,
                                                  gsize count, SZFriendsGtkSnapshotFunc func, gpointer data,
                                                  GDestroyNotify destroy) {
    g_return_val_if_fail(link && message_ids && count && func, 0);
    SZFriendsGtkLinkSub *sub = new_sub(SZFRIENDS_GTK_SUB_MESSAGE_STATUS, func, data, destroy);
    sub->view = g_strdup("message_status");
    sub->message_ids = g_new0(char *, count + 1);
    for (gsize i = 0; i < count; i++) sub->message_ids[i] = g_strdup(message_ids[i]);
    return add_sub(link, sub);
}

guint szfriends_gtk_link_open_conversation(SZFriendsGtkLink *link, const char *conversation_id,
                                           const char *message_id, SZFriendsGtkSnapshotFunc func, gpointer data,
                                           GDestroyNotify destroy) {
    g_return_val_if_fail(link && conversation_id && func, 0);
    SZFriendsGtkLinkSub *sub = new_sub(SZFRIENDS_GTK_SUB_CONVERSATION, func, data, destroy);
    sub->view = g_strdup("conversation");
    sub->conversation_id = g_strdup(conversation_id);
    sub->message_id = g_strdup(message_id);
    return add_sub(link, sub);
}

void szfriends_gtk_link_set_filter(SZFriendsGtkLink *link, guint token, const char *query) {
    SZFriendsGtkLinkSub *sub = link ? find_sub(link, token) : NULL;
    if (!sub) return;
    g_free(sub->filter);
    sub->filter = g_strdup(query ? query : "");
    if (sub->server_id)
        szfriends_gtk_link_send(link, szfriends_intent_set_filter(sub->server_id, sub->filter), NULL, NULL, NULL);
}

void szfriends_gtk_link_load_earlier(SZFriendsGtkLink *link, guint token) {
    SZFriendsGtkLinkSub *sub = link ? find_sub(link, token) : NULL;
    if (!sub) return;
    sub->earlier_count++;
    if (sub->server_id) szfriends_gtk_link_send(link, szfriends_intent_load_earlier(sub->server_id), NULL, NULL, NULL);
}

void szfriends_gtk_link_unsubscribe(SZFriendsGtkLink *link, guint token) {
    SZFriendsGtkLinkSub *sub = link ? find_sub(link, token) : NULL;
    if (!sub) return;
    if (sub->server_id) {
        g_hash_table_remove(link->by_server, sub->server_id);
        szfriends_gtk_link_send(link, szfriends_intent_unsubscribe(sub->server_id), NULL, NULL, NULL);
    }
    /* A subscribe still in flight is answered later; its reply then unsubscribes at once. */
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, link->subscribe_frames);
    while (g_hash_table_iter_next(&iter, &key, &value))
        if (GPOINTER_TO_UINT(value) == token) {
            g_hash_table_insert(link->abandoned_frames, g_strdup(key), "");
            g_hash_table_iter_remove(&iter);
        }
    g_ptr_array_remove(link->subs, sub);
}

/* ---- Replies ------------------------------------------------------------------------------------- */

static void deliver(SZFriendsGtkLink *link, SZFriendsGtkLinkReply *reply, JsonObject *result,
                    const SZFriendsGtkError *error) {
    if (reply->frame_id) g_hash_table_remove(link->replies, reply->frame_id);
    SZFriendsGtkReplyFunc func = reply->func;
    gpointer data = reply->user_data;
    guint request = reply->request; /* the function may forget its own request, freeing `reply` */
    reply->func = NULL;
    szfriends_gtk_link_ref(link);
    if (func) func(result, error, data);
    g_hash_table_remove(link->requests, GUINT_TO_POINTER(request)); /* runs destroy */
    szfriends_gtk_link_unref(link);
}

/* Client-side errors carry the connection line, so a view can say why nothing happened (PROTOCOL.md § Replies). */
static void deliver_client_error(SZFriendsGtkLink *link, SZFriendsGtkLinkReply *reply, const char *code) {
    SZFriendsGtkError error = {0};
    error.code = (char *)code;
    error.message = link->status_text;
    error.retryable = TRUE;
    error.details = json_object_new();
    deliver(link, reply, NULL, &error);
    json_object_unref(error.details);
}

static gboolean run_failures(gpointer data) {
    SZFriendsGtkLink *link = data;
    link->failure_idle = 0;
    szfriends_gtk_link_ref(link);
    SZFriendsGtkLinkReply *reply;
    while (!link->closed && (reply = g_queue_pop_head(&link->failures)))
        deliver_client_error(link, reply, reply->fail_code);
    szfriends_gtk_link_unref(link);
    return G_SOURCE_REMOVE;
}

guint szfriends_gtk_link_send(SZFriendsGtkLink *link, szfriends_intent *intent, SZFriendsGtkReplyFunc func,
                              gpointer data, GDestroyNotify destroy) {
    if (!link) {
        szfriends_intent_free(intent);
        if (destroy) destroy(data);
        return 0;
    }
    SZFriendsGtkLinkReply *reply = g_new0(SZFriendsGtkLinkReply, 1);
    reply->request = ++link->next_request;
    reply->func = func;
    reply->user_data = data;
    reply->destroy = destroy;
    g_hash_table_insert(link->requests, GUINT_TO_POINTER(reply->request), reply);
    const char *code = NULL;
    reply->frame_id = send_now(link, intent, &code);
    if (reply->frame_id) {
        g_hash_table_insert(link->replies, g_strdup(reply->frame_id), reply);
    } else {
        /* Never re-entrantly: the view that sent may be mid-update (mac/SZFriendsHelperLink.m does the same). */
        reply->fail_code = g_strdup(code);
        g_queue_push_tail(&link->failures, reply);
        if (!link->failure_idle) link->failure_idle = g_idle_add(run_failures, link);
    }
    return reply->request;
}

void szfriends_gtk_link_forget_reply(SZFriendsGtkLink *link, guint request) {
    SZFriendsGtkLinkReply *reply = link ? g_hash_table_lookup(link->requests, GUINT_TO_POINTER(request)) : NULL;
    if (!reply) return;
    if (reply->frame_id) g_hash_table_remove(link->replies, reply->frame_id);
    g_queue_remove(&link->failures, reply);
    g_hash_table_remove(link->requests, GUINT_TO_POINTER(request));
}

void szfriends_gtk_link_routes_left_ready(SZFriendsGtkLink *link) {
    /* The intent may or may not have reached the helper; sends carry a client_token, so a retry is safe. The
     * library's own connection_lost frames for these ids then find nothing, so each reply still runs once. */
    g_hash_table_remove_all(link->subscribe_frames);
    g_hash_table_remove_all(link->abandoned_frames);
    /* One at a time, looked up afresh: a reply function may forget another pending request. Sends made from one
     * fail as not_ready on the idle, so this ends. */
    while (!link->closed && g_hash_table_size(link->replies)) {
        GHashTableIter iter;
        gpointer key, value;
        g_hash_table_iter_init(&iter, link->replies);
        if (!g_hash_table_iter_next(&iter, &key, &value)) break;
        deliver_client_error(link, value, "connection_lost");
    }
}

void szfriends_gtk_link_routes_ready(SZFriendsGtkLink *link) {
    g_hash_table_remove_all(link->by_server);
    g_hash_table_remove_all(link->early);
    /* A copy: a handler run from send_subscribe's queue may add or remove subscriptions. */
    GPtrArray *tokens = g_ptr_array_new();
    for (guint i = 0; i < link->subs->len; i++) {
        SZFriendsGtkLinkSub *sub = g_ptr_array_index(link->subs, i);
        g_clear_pointer(&sub->server_id, g_free);
        g_ptr_array_add(tokens, GUINT_TO_POINTER(sub->token));
    }
    for (guint i = 0; i < tokens->len && link->state == SZFRIENDS_GTK_LINK_READY; i++) {
        SZFriendsGtkLinkSub *sub = find_sub(link, GPOINTER_TO_UINT(g_ptr_array_index(tokens, i)));
        if (sub) send_subscribe(link, sub);
    }
    g_ptr_array_free(tokens, TRUE);
}

static void subscription_reply(SZFriendsGtkLink *link, guint token, gboolean abandoned, SZFriendsGtkReply *reply) {
    SZFriendsGtkSubscribeResult *result = szfriends_gtk_subscribe_result_parse(reply->result);
    char *server = reply->ok && *result->subscription ? g_strdup(result->subscription) : NULL;
    szfriends_gtk_subscribe_result_free(result);
    if (!server) return; /* views keep their last snapshot; the next reconnect subscribes again */
    JsonObject *early = g_hash_table_lookup(link->early, server);
    if (early) json_object_ref(early);
    g_hash_table_remove(link->early, server);
    SZFriendsGtkLinkSub *sub = abandoned ? NULL : find_sub(link, token);
    if (!sub) {
        szfriends_gtk_link_send(link, szfriends_intent_unsubscribe(server), NULL, NULL, NULL);
    } else {
        sub->server_id = g_strdup(server);
        g_clear_pointer(&sub->message_id, g_free); /* a highlight belongs to the moment it was asked for */
        g_hash_table_insert(link->by_server, g_strdup(server), sub);
        guint sub_token = sub->token;
        if (early) {
            SZFriendsGtkSnapshotFrame *frame = szfriends_gtk_snapshot_frame_parse(early);
            if (frame->data) sub->func(frame->data, frame->rev, sub->user_data);
            szfriends_gtk_snapshot_frame_free(frame);
        }
        sub = find_sub(link, sub_token); /* the handler may have unsubscribed */
        if (sub && sub->filter && *sub->filter)
            szfriends_gtk_link_send(link, szfriends_intent_set_filter(server, sub->filter), NULL, NULL, NULL);
        for (guint i = 0; sub && i < sub->earlier_count; i++)
            szfriends_gtk_link_send(link, szfriends_intent_load_earlier(server), NULL, NULL, NULL);
    }
    if (early) json_object_unref(early);
    g_free(server);
}

static void route_reply(SZFriendsGtkLink *link, JsonObject *frame) {
    SZFriendsGtkReply *reply = szfriends_gtk_reply_parse(frame);
    gpointer token = NULL;
    if (!reply->re) {
        szfriends_gtk_reply_free(reply);
        return;
    }
    gboolean subscribing = g_hash_table_lookup_extended(link->subscribe_frames, reply->re, NULL, &token);
    gboolean abandoned = g_hash_table_contains(link->abandoned_frames, reply->re);
    if (subscribing || abandoned) {
        g_hash_table_remove(link->subscribe_frames, reply->re);
        g_hash_table_remove(link->abandoned_frames, reply->re);
        subscription_reply(link, GPOINTER_TO_UINT(token), abandoned, reply);
    } else {
        SZFriendsGtkLinkReply *pending = g_hash_table_lookup(link->replies, reply->re);
        if (pending && reply->ok) {
            JsonObject *result = reply->result ? json_object_ref(reply->result) : json_object_new();
            deliver(link, pending, result, NULL);
            json_object_unref(result);
        } else if (pending && reply->error) {
            deliver(link, pending, NULL, reply->error);
        } else if (pending) {
            deliver_client_error(link, pending, "internal");
        }
    }
    szfriends_gtk_reply_free(reply);
}

static void route_snapshot(SZFriendsGtkLink *link, JsonObject *object) {
    SZFriendsGtkSnapshotFrame *frame = szfriends_gtk_snapshot_frame_parse(object);
    SZFriendsGtkLinkSub *sub = g_hash_table_lookup(link->by_server, frame->subscription);
    if (sub && frame->data) {
        sub->func(frame->data, frame->rev, sub->user_data);
    } else if (*frame->subscription && frame->data) {
        /* The first snapshot precedes its subscribe reply (PROTOCOL.md § Snapshots), so it waits for the mapping;
         * only the newest matters, since snapshots are complete. */
        g_hash_table_insert(link->early, g_strdup(frame->subscription), json_object_ref(object));
    }
    szfriends_gtk_snapshot_frame_free(frame);
}

void szfriends_gtk_link_route_frame(SZFriendsGtkLink *link, JsonObject *frame) {
    const char *type = json_object_get_string_member_with_default(frame, "type", "");
    if (g_strcmp0(type, "reply") == 0) route_reply(link, frame);
    else if (g_strcmp0(type, "snapshot") == 0) route_snapshot(link, frame);
    /* goodbye: the library reconnects by itself and reports the state; nothing for the views to do. */
}

/* ---- The shared badge ---------------------------------------------------------------------------- */

static void on_badge(JsonObject *data, gint64 rev, gpointer user_data) {
    SZFriendsGtkLink *link = user_data;
    (void)rev;
    szfriends_gtk_badge_snapshot_free(link->badge);
    link->badge = szfriends_gtk_badge_snapshot_parse(data);
    szfriends_gtk_link_watches_begin(link);
    for (guint i = 0; i < link->badge_watches->len; i++) {
        SZFriendsGtkLinkWatch *watch = g_ptr_array_index(link->badge_watches, i);
        if (watch->func) ((SZFriendsGtkBadgeFunc)watch->func)(link, link->badge, watch->user_data);
    }
    szfriends_gtk_link_watches_end(link);
}

const SZFriendsGtkBadgeSnapshot *szfriends_gtk_link_badge(SZFriendsGtkLink *link) {
    return link ? link->badge : NULL;
}

guint szfriends_gtk_link_add_badge_watch(SZFriendsGtkLink *link, SZFriendsGtkBadgeFunc func, gpointer user_data) {
    SZFriendsGtkLinkWatch *watch = g_new0(SZFriendsGtkLinkWatch, 1);
    watch->id = ++link->next_watch;
    watch->func = (gpointer)func;
    watch->user_data = user_data;
    g_ptr_array_add(link->badge_watches, watch);
    return watch->id;
}

void szfriends_gtk_link_remove_badge_watch(SZFriendsGtkLink *link, guint id) {
    if (link) szfriends_gtk_link_watches_remove(link, link->badge_watches, id);
}
