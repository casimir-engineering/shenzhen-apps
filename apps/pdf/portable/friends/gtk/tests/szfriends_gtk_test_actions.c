/* Intents built from parsed snapshots: every action in every fixture becomes the intent PROTOCOL.md says, with the
 * id of the object it sits on, and files become the file objects intents.jsonl shows (display-free). */

#include "szfriends_gtk_support.h"
#include "gtk/szfriends_gtk_actions.h"

#include <pango/pango.h>

#include <string.h>

static GHashTable *jsonl_examples; /* intent type -> JsonObject (one line of intents.jsonl) */
static guint intents_checked;

static void load_examples(void) {
    jsonl_examples = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)json_object_unref);
    char *path = szfg_fixture_path("intents.jsonl"), *text = NULL;
    EXPECT(g_file_get_contents(path, &text, NULL, NULL), "intents.jsonl reads");
    char **lines = g_strsplit(text ? text : "", "\n", -1);
    for (char **line = lines; *line; line++) {
        JsonObject *object = **line ? szfriends_gtk_json_object_from_text(*line, -1) : NULL;
        const char *type = object ? json_object_get_string_member_with_default(object, "type", NULL) : NULL;
        if (type && !g_hash_table_contains(jsonl_examples, type))
            g_hash_table_insert(jsonl_examples, g_strdup(type), json_object_ref(object));
        if (object) json_object_unref(object);
    }
    g_strfreev(lines);
    g_free(text);
    g_free(path);
}

/* The built intent has the action's name as its type, the expected id, and the same fields as the example. */
static void expect_intent(const char *where, szfriends_intent *intent, const char *type, const char *key,
                          const char *value, gboolean exact) {
    EXPECT(intent != NULL, "%s: %s builds an intent", where, type);
    if (!intent) return;
    EXPECT(strcmp(szfriends_intent_type(intent), type) == 0, "%s: intent type %s", where, type);
    char *json = szfriends_intent_fields_json(intent);
    JsonObject *fields = szfriends_gtk_json_object_from_text(json, -1);
    if (key) EXPECT(fields && g_strcmp0(json_object_get_string_member_with_default(fields, key, NULL), value) == 0,
                    "%s: %s carries %s %s (%s)", where, type, key, value, json);
    JsonObject *example = g_hash_table_lookup(jsonl_examples, type);
    EXPECT(example != NULL, "%s: intents.jsonl has an example of %s", where, type);
    if (example && fields && exact) {
        GList *keys = json_object_get_members(example);
        for (GList *k = keys; k; k = k->next)
            if (strcmp(k->data, "type") && strcmp(k->data, "id"))
                EXPECT(json_object_has_member(fields, k->data), "%s: %s has the example's field %s (%s)", where, type,
                       (const char *)k->data, json);
        g_list_free(keys);
        EXPECT(json_object_get_size(fields) + 2 == json_object_get_size(example),
               "%s: %s has exactly the example's fields (%s)", where, type, json);
    }
    if (fields) json_object_unref(fields);
    szfriends_free(json);
    szfriends_intent_free(intent);
    intents_checked++;
}

static void check_action(const char *where, const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids) {
    const char *name = szfriends_gtk_action_name(action->action);
    EXPECT(szfriends_gtk_action_is_known(action->action) && name, "%s: action is known", where);
    if (!name) return;
    if (szfriends_gtk_action_is_client_side(action->action)) {
        EXPECT(szfriends_gtk_intent_for_action(action, ids) == NULL, "%s: %s stays in the view", where, name);
        if (action->action == SZFRIENDS_GTK_ACTION_OPEN_SETTINGS)
            EXPECT(szfriends_gtk_settings_uri(action->settings_target) != NULL, "%s: a settings page to open", where);
        else
            EXPECT(*action->path == '/', "%s: %s has the file's path", where, name);
        return;
    }
    const char *key = NULL, *value = NULL;
    switch (action->action) {
    case SZFRIENDS_GTK_ACTION_SEND_REQUEST: key = "nearby_id", value = ids->nearby_id; break;
    case SZFRIENDS_GTK_ACTION_ACCEPT_OFFER:
    case SZFRIENDS_GTK_ACTION_DECLINE_OFFER:
    case SZFRIENDS_GTK_ACTION_CANCEL_TRANSFER:
    case SZFRIENDS_GTK_ACTION_FETCH_FROM_DEVICE: key = "transfer_id", value = ids->transfer_id; break;
    case SZFRIENDS_GTK_ACTION_REVOKE_DEVICE: key = "device_id", value = action->device_id; break;
    case SZFRIENDS_GTK_ACTION_APPROVE_JOIN:
    case SZFRIENDS_GTK_ACTION_DENY_JOIN: key = "join_id", value = action->join_id; break;
    case SZFRIENDS_GTK_ACTION_JOIN_PROFILE: key = "friends_id", value = action->friends_id; break;
    case SZFRIENDS_GTK_ACTION_RETRY_ITEM: key = "item_id", value = ids->item_id; break;
    case SZFRIENDS_GTK_ACTION_CANCEL_MESSAGE: key = "message_id", value = ids->message_id; break;
    case SZFRIENDS_GTK_ACTION_DISMISS_BANNER: key = "kind", value = ids->kind; break;
    case SZFRIENDS_GTK_ACTION_ADD_FROM_MENTION: key = "identity_key", value = action->identity_key; break;
    case SZFRIENDS_GTK_ACTION_ADD_FROM_LINK:
    case SZFRIENDS_GTK_ACTION_RECEIVE_LINK: key = "payload", value = action->payload; break;
    case SZFRIENDS_GTK_ACTION_REVOKE_LINK: key = "link_id", value = action->link_id; break;
    case SZFRIENDS_GTK_ACTION_START_VISIBILITY:
    case SZFRIENDS_GTK_ACTION_STOP_VISIBILITY:
    case SZFRIENDS_GTK_ACTION_RESET_FRIEND_LINK:
    case SZFRIENDS_GTK_ACTION_CANCEL_JOIN:
    case SZFRIENDS_GTK_ACTION_RESET_FRIENDS: break;
    default: key = "conversation_id", value = ids->conversation_id; break;
    }
    expect_intent(where, szfriends_gtk_intent_for_action(action, ids), name, key, value, TRUE);
}

static void check_actions(const char *where, const SZFriendsGtkAction *actions, gsize n,
                          const SZFriendsGtkActionIds *ids) {
    for (gsize i = 0; i < n; i++) check_action(where, &actions[i], ids);
}

static void walk_list(const char *name, SZFriendsGtkListSnapshot *list) {
    for (gsize i = 0; i < list->n_rows; i++) {
        SZFriendsGtkActionIds ids = {.conversation_id = list->rows[i].conversation_id};
        for (gsize a = 0; a < list->rows[i].n_actions; a++) {
            SZFriendsGtkActionKind kind = list->rows[i].actions[a].action;
            expect_intent(name, szfriends_gtk_intent_for_action_kind(kind, &ids), szfriends_gtk_action_name(kind),
                          "conversation_id", ids.conversation_id, TRUE);
        }
    }
    if (list->banner && list->banner->action) {
        const char *kind = list->banner->kind == SZFRIENDS_GTK_BANNER_ID_CHANGED ? "id_changed" : NULL;
        SZFriendsGtkActionIds ids = {.kind = kind};
        check_action(name, list->banner->action, &ids);
    }
    /* Several computers: Start Over, and each join row's Approve, Deny or Cancel with its own join_id. */
    SZFriendsGtkActionIds none = {0};
    if (list->removed) check_action(name, &list->removed->action, &none);
    for (gsize i = 0; i < list->n_join_requests; i++)
        check_actions(name, list->join_requests[i].actions, list->join_requests[i].n_actions, &none);
}

static void walk_conversation(const char *name, SZFriendsGtkConversationSnapshot *conversation) {
    SZFriendsGtkActionIds view = {.conversation_id = conversation->conversation_id};
    for (gsize i = 0; i < conversation->n_items; i++) {
        SZFriendsGtkConversationItem *item = &conversation->items[i];
        SZFriendsGtkActionIds ids = {.conversation_id = conversation->conversation_id, .transfer_id = item->transfer_id,
                                     .item_id = item->item_id, .message_id = item->item_id};
        check_actions(name, item->actions, item->n_actions, &ids);
        for (gsize m = 0; m < item->n_mentions; m++)
            if (item->mentions[m].card) {
                SZFriendsGtkActionIds card = {.conversation_id = item->mentions[m].card->conversation_id};
                check_actions(name, item->mentions[m].card->actions, item->mentions[m].card->n_actions, &card);
            }
    }
    if (conversation->request) check_actions(name, conversation->request->actions, conversation->request->n_actions,
                                             &view);
}

static void walk_fixture(const char *name) {
    JsonObject *frame = szfg_fixture(name);
    if (!frame) return;
    const char *view = json_object_get_string_member_with_default(frame, "view", "");
    JsonObject *data = json_object_get_object_member(frame, "data");
    if (strcmp(view, "list") == 0) {
        SZFriendsGtkListSnapshot *list = szfriends_gtk_list_snapshot_parse(data);
        walk_list(name, list);
        szfriends_gtk_list_snapshot_free(list);
    } else if (strcmp(view, "conversation") == 0) {
        SZFriendsGtkConversationSnapshot *conversation = szfriends_gtk_conversation_snapshot_parse(data);
        walk_conversation(name, conversation);
        szfriends_gtk_conversation_snapshot_free(conversation);
    } else if (strcmp(view, "nearby") == 0) {
        SZFriendsGtkNearbySnapshot *nearby = szfriends_gtk_nearby_snapshot_parse(data);
        SZFriendsGtkActionIds none = {0};
        if (nearby->visibility.action) check_action(name, nearby->visibility.action, &none);
        if (nearby->alert && nearby->alert->action) check_action(name, nearby->alert->action, &none);
        if (nearby->note && nearby->note->action) check_action(name, nearby->note->action, &none);
        for (gsize i = 0; i < nearby->n_people; i++) {
            SZFriendsGtkActionIds ids = {.nearby_id = nearby->people[i].nearby_id,
                                         .conversation_id = nearby->people[i].conversation_id};
            if (nearby->people[i].action) check_action(name, nearby->people[i].action, &ids);
        }
        szfriends_gtk_nearby_snapshot_free(nearby);
    } else if (strcmp(view, "details") == 0) {
        SZFriendsGtkDetailsSnapshot *details = szfriends_gtk_details_snapshot_parse(data);
        SZFriendsGtkActionIds ids = {.conversation_id = details->conversation_id};
        check_actions(name, details->actions, details->n_actions, &ids);
        if (details->verification.action) check_action(name, details->verification.action, &ids);
        if (details->received && details->received->action) check_action(name, details->received->action, &ids);
        if (details->key_change)
            check_actions(name, details->key_change->actions, details->key_change->n_actions, &ids);
        szfriends_gtk_details_snapshot_free(details);
    } else if (strcmp(view, "profile") == 0) {
        /* Your links: Reset link and every Revoke, with the link id the action itself carries. */
        SZFriendsGtkProfileSnapshot *profile = szfriends_gtk_profile_snapshot_parse(data);
        SZFriendsGtkActionIds none = {0};
        if (profile->links) {
            check_action(name, &profile->links->friend_link.reset, &none);
            for (gsize i = 0; i < profile->links->n_downloads; i++)
                check_action(name, &profile->links->downloads[i].revoke, &none);
        }
        for (gsize i = 0; profile->devices && i < profile->devices->n_rows; i++)
            if (profile->devices->rows[i].remove) check_action(name, profile->devices->rows[i].remove, &none);
        szfriends_gtk_profile_snapshot_free(profile);
    } else if (strcmp(view, "join") == 0) {
        SZFriendsGtkJoinSnapshot *join = szfriends_gtk_join_snapshot_parse(data);
        SZFriendsGtkActionIds none = {0};
        check_actions(name, join->actions, join->n_actions, &none);
        szfriends_gtk_join_snapshot_free(join);
    } else if (strcmp(view, "settings") == 0) {
        SZFriendsGtkSettingsSnapshot *settings = szfriends_gtk_settings_snapshot_parse(data);
        SZFriendsGtkActionIds none = {0};
        if (settings->received.action) check_action(name, settings->received.action, &none);
        /* Change… is the view's own folder dialog: a client-side action, no intent of its own. */
        if (settings->received.change)
            EXPECT(szfriends_gtk_action_is_client_side(settings->received.change->action),
                   "%s: choose_received_folder is client-side", name);
        szfriends_gtk_settings_snapshot_free(settings);
    }
    json_object_unref(frame);
}

static void test_files(void) {
    GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    g_ptr_array_add(items, szfriends_gtk_host_item_new("Site photos.pdf", "Selected in Downloads", "PDF",
                                                       "/Users/raph/Downloads/Site photos.pdf", NULL));
    g_ptr_array_add(items, szfriends_gtk_host_item_new("Contract.pdf", "", "PDF", "/tmp/c.pdf",
        "{\"source\":\"com.intuition.shenzhenfiles\",\"document_id\":\"d_1\",\"revision_id\":\"r_2\",\"size\":42}"));
    szfriends_intent *intent = szfriends_gtk_intent_send_items("c_mei", items, "0123456789abcdef0123456789abcdef");
    char *json = intent ? szfriends_intent_fields_json(intent) : NULL;
    JsonObject *fields = json ? szfriends_gtk_json_object_from_text(json, -1) : NULL;
    JsonArray *files = fields ? json_object_get_array_member(fields, "files") : NULL;
    EXPECT(files && json_array_get_length(files) == 2, "two items, two file objects (%s)", json ? json : "");
    if (files && json_array_get_length(files) == 2) {
        JsonObject *plain = json_array_get_object_element(files, 0), *bound = json_array_get_object_element(files, 1);
        EXPECT(json_object_get_null_member(plain, "revision"), "a plain file's revision is null (%s)", json);
        EXPECT(strcmp(json_object_get_string_member(plain, "display_name"), "Site photos.pdf") == 0, "name kept");
        JsonObject *revision = json_object_get_object_member(bound, "revision");
        EXPECT(revision && json_object_get_int_member(revision, "size") == 42 &&
                   strcmp(json_object_get_string_member(revision, "revision_id"), "r_2") == 0,
               "the bound revision travels with its file (%s)", json);
    }
    if (fields) json_object_unref(fields);
    szfriends_free(json);
    szfriends_intent_free(intent);
    expect_intent("send_message", szfriends_gtk_intent_send_message("c_mei", "Here", items, NULL), "send_message",
                  "text", "Here", FALSE);
    EXPECT(szfriends_gtk_intent_send_items("c_mei", NULL, NULL) == NULL, "no items, no send_files");
    g_ptr_array_unref(items);
}

/* Rich text is text plus byte ranges, never markup: a friend's "<b>" stays two characters and a bracket. */
static void test_rich_text(void) {
    JsonObject *frame = szfg_fixture("snapshots/conversation-kenji-offer.json");
    if (!frame) return;
    SZFriendsGtkConversationSnapshot *conversation =
        szfriends_gtk_conversation_snapshot_parse(json_object_get_object_member(frame, "data"));
    PangoAttrList *attributes = NULL;
    char *text = szfriends_gtk_rich_text(conversation->composer.hint, conversation->composer.n_hint, &attributes);
    EXPECT(g_str_has_prefix(text, "Type # to attach"), "the composer hint reads as its segments: %s", text);
    GSList *list = pango_attr_list_get_attributes(attributes);
    EXPECT(g_slist_length(list) == 1 && ((PangoAttribute *)list->data)->klass->type == PANGO_ATTR_WEIGHT &&
               ((PangoAttribute *)list->data)->start_index == 5 && ((PangoAttribute *)list->data)->end_index == 6,
           "only the emphasised # is bold");
    g_slist_free_full(list, (GDestroyNotify)pango_attribute_destroy);
    pango_attr_list_unref(attributes);
    g_free(text);
    SZFriendsGtkSegment hostile[] = {{.text = "<b>not bold</b> "}, {.text = "site", .url = "https://example.invalid"}};
    text = szfriends_gtk_rich_text(hostile, 2, &attributes);
    EXPECT(strcmp(text, "<b>not bold</b> site") == 0, "markup in a message stays text");
    list = pango_attr_list_get_attributes(attributes);
    EXPECT(g_slist_length(list) == 1 && ((PangoAttribute *)list->data)->start_index == 16,
           "the link is underlined where its words are");
    g_slist_free_full(list, (GDestroyNotify)pango_attribute_destroy);
    pango_attr_list_unref(attributes);
    g_free(text);
    szfriends_gtk_conversation_snapshot_free(conversation);
    json_object_unref(frame);
}

void szfg_run_action_tests(void) {
    test_rich_text();
    load_examples();
    GPtrArray *names = szfg_fixture_names("snapshots");
    for (guint i = 0; i < names->len; i++) walk_fixture(g_ptr_array_index(names, i));
    g_ptr_array_unref(names);
    EXPECT(intents_checked >= 25, "intents built from the fixtures (%u)", intents_checked);
    SZFriendsGtkActionIds none = {0};
    EXPECT(szfriends_gtk_intent_for_action_kind(SZFRIENDS_GTK_ACTION_BLOCK, &none) == NULL,
           "an action without its id sends nothing");
    EXPECT(szfriends_gtk_intent_for_action_kind(SZFRIENDS_GTK_ACTION_UNKNOWN, &none) == NULL, "unknown sends nothing");
    test_files();
    /* A link card's Add, from open_link's reply, sends the card's payload as it is. */
    JsonObject *reply = szfg_fixture("replies/open_link.json");
    SZFriendsGtkOpenLinkResult *link = szfriends_gtk_open_link_result_parse(json_object_get_object_member(reply,
                                                                                                         "result"));
    EXPECT(link->card.kind == SZFRIENDS_GTK_LINK_CARD_FRIEND && link->card.n_actions == 1, "the friend link's card");
    check_actions("replies/open_link.json", link->card.actions, link->card.n_actions, &none);
    szfriends_gtk_open_link_result_free(link);
    json_object_unref(reply);
    g_hash_table_unref(jsonl_examples);
}
