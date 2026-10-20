/* Every fixture parses into the GTK structs and serializes back to exactly what it was (display-free).
 *
 * The round trip writes only the fields the parser recorded as present, so a fixture field the tables do not know is
 * missing from the copy and fails here with its path, and a value parsed into the wrong slot or as the wrong type
 * differs. Together with the PROTOCOL.md comparison (szfriends_gtk_test_protocol.c) this is how the GTK views keep up
 * with every view the helper publishes. */

#include "szfriends_gtk_support.h"

#include <string.h>

static void expect_round_trip(const char *what, const SZFriendsGtkType *type, JsonObject *object) {
    gpointer value = szfriends_gtk_value_parse(type, object);
    JsonNode *copy = szfg_serialize(type, value);
    JsonNode *original = json_node_init_object(json_node_alloc(), object);
    GString *where = g_string_new("");
    gboolean same = szfg_json_equal(original, copy, where);
    EXPECT(same, "%s: the %s struct does not reproduce the fixture at %s", what, type->name ? type->name : "?",
           where->len ? where->str : "(top)");
    g_string_free(where, TRUE);
    json_node_unref(original);
    json_node_unref(copy);
    szfriends_gtk_value_free(type, value);
}

/* A frame without its "type": the structs are the frames' bodies, chosen by type. */
static JsonObject *frame_body(JsonObject *frame) {
    JsonObject *body = json_object_new();
    GList *members = json_object_get_members(frame);
    for (GList *m = members; m; m = m->next)
        if (strcmp(m->data, "type") != 0)
            json_object_set_member(body, m->data, json_node_copy(json_object_get_member(frame, m->data)));
    g_list_free(members);
    return body;
}

static void test_snapshot_fixtures(void) {
    GPtrArray *names = szfg_fixture_names("snapshots");
    EXPECT(names->len >= 13, "every snapshot fixture is found (%u)", names->len);
    GHashTable *views = g_hash_table_new(g_str_hash, g_str_equal);
    for (guint i = 0; i < names->len; i++) {
        const char *name = g_ptr_array_index(names, i);
        JsonObject *frame = szfg_fixture(name);
        if (!frame) continue;
        SZFriendsGtkSnapshotFrame *envelope = szfriends_gtk_snapshot_frame_parse(frame);
        const SZFriendsGtkType *type = szfriends_gtk_view_type(envelope->view);
        EXPECT(type != NULL, "%s: view %s has a struct", name, envelope->view);
        EXPECT(envelope->data != NULL && envelope->rev >= 1, "%s: envelope parsed", name);
        if (type && envelope->data) {
            expect_round_trip(name, type, envelope->data);
            g_hash_table_add(views, (gpointer)type->name);
        }
        JsonObject *body = frame_body(frame);
        expect_round_trip(name, &szfriends_gtk_type_snapshot_frame, body);
        json_object_unref(body);
        szfriends_gtk_snapshot_frame_free(envelope);
        json_object_unref(frame);
    }
    /* Every view the views render has a fixture behind it, so none goes untested. */
    const char *expected[] = {"snapshot.badge", "snapshot.list", "snapshot.nearby", "snapshot.conversation",
                              "snapshot.details", "snapshot.profile", "snapshot.settings", "snapshot.message_status",
                              "snapshot.join", "snapshot.received"};
    for (gsize i = 0; i < G_N_ELEMENTS(expected); i++)
        EXPECT(g_hash_table_contains(views, expected[i]), "a fixture covers %s", expected[i]);
    g_hash_table_unref(views);
    g_ptr_array_unref(names);
}

static void test_frame_fixtures(void) {
    GPtrArray *names = szfg_fixture_names("frames");
    guint checked = 0;
    for (guint i = 0; i < names->len; i++) {
        const char *name = g_ptr_array_index(names, i);
        JsonObject *frame = szfg_fixture(name);
        if (!frame) continue;
        const char *kind = json_object_get_string_member_with_default(frame, "type", "");
        const SZFriendsGtkType *type = strcmp(kind, "welcome") == 0   ? &szfriends_gtk_type_welcome
                                       : strcmp(kind, "reply") == 0   ? &szfriends_gtk_type_reply
                                       : strcmp(kind, "goodbye") == 0 ? &szfriends_gtk_type_goodbye
                                                                      : NULL;
        /* hello is the client's own frame, built by the client library; the views never read one. */
        EXPECT(type || strcmp(kind, "hello") == 0, "%s: helper frame type %s has a struct", name, kind);
        if (type) {
            JsonObject *body = frame_body(frame);
            expect_round_trip(name, type, body);
            json_object_unref(body);
            checked++;
        }
        json_object_unref(frame);
    }
    EXPECT(checked >= 7, "welcome, replies and goodbyes are all checked (%u)", checked);
    g_ptr_array_unref(names);
}

static const SZFriendsGtkType *result_type(const char *intent) {
    if (!strcmp(intent, "subscribe") || !strcmp(intent, "open_conversation"))
        return &szfriends_gtk_type_subscribe_result;
    if (!strcmp(intent, "send_message") || !strcmp(intent, "send_files")) return &szfriends_gtk_type_send_result;
    if (!strcmp(intent, "add_by_id") || !strcmp(intent, "add_from_mention") || !strcmp(intent, "add_from_link") ||
        !strcmp(intent, "receive_link"))
        return &szfriends_gtk_type_add_by_id_result;
    if (!strcmp(intent, "open_link")) return &szfriends_gtk_type_open_link_result;
    if (!strcmp(intent, "make_download_link")) return &szfriends_gtk_type_download_link_result;
    if (!strcmp(intent, "start_visibility")) return &szfriends_gtk_type_visibility_result;
    if (!strcmp(intent, "search_messages")) return &szfriends_gtk_type_search_result;
    return NULL;
}

static void test_reply_fixtures(void) {
    GPtrArray *names = szfg_fixture_names("replies");
    for (guint i = 0; i < names->len; i++) {
        const char *name = g_ptr_array_index(names, i);
        JsonObject *frame = szfg_fixture(name);
        if (!frame) continue;
        char *intent = g_path_get_basename(name);
        *strrchr(intent, '.') = '\0';
        JsonObject *body = frame_body(frame);
        expect_round_trip(name, &szfriends_gtk_type_reply, body);
        SZFriendsGtkReply *reply = szfriends_gtk_reply_parse(frame);
        const SZFriendsGtkType *type = result_type(intent);
        /* The assistant's results go to a host's AI tool layer, not to the views (PROTOCOL.md § Intents). */
        EXPECT(type || g_str_has_prefix(intent, "assistant_"), "%s: the views read this result", name);
        EXPECT(reply->ok && reply->result, "%s: a successful reply with a result", name);
        if (type && reply->result) expect_round_trip(name, type, reply->result);
        szfriends_gtk_reply_free(reply);
        json_object_unref(body);
        g_free(intent);
        json_object_unref(frame);
    }
    g_ptr_array_unref(names);
}

/* Malformed input draws less, never crashes: wrong types read as empty, required strings are never NULL. */
static void test_lenient_parsing(void) {
    JsonObject *object = szfriends_gtk_json_object_from_text(
        "{\"rows\":[{\"title\":7,\"avatar\":\"x\",\"actions\":[{\"action\":\"teleport\"}],\"waiting\":[]},null],"
        "\"footer\":null,\"banner\":{\"kind\":\"id_changed\"},\"empty\":3}", -1);
    EXPECT(object != NULL, "the malformed list still parses as JSON");
    SZFriendsGtkListSnapshot *list = szfriends_gtk_list_snapshot_parse(object);
    EXPECT(list->n_rows == 2 && list->rows[0].title && !*list->rows[0].title, "a number for a string reads as \"\"");
    EXPECT(list->rows[0].avatar.initials && list->rows[0].avatar.kind == SZFRIENDS_GTK_AVATAR_UNKNOWN,
           "a string for an object reads as an empty object");
    EXPECT(list->rows[0].n_actions == 1 && list->rows[0].actions[0].action == SZFRIENDS_GTK_ACTION_UNKNOWN,
           "an unknown action name reads as unknown, so the view hides it");
    EXPECT(list->rows[0].waiting == NULL && list->empty == NULL, "a wrong type for a nullable object reads as null");
    EXPECT(list->rows[1].conversation_id && list->footer.friends_id, "null elements and objects read as empty");
    EXPECT(list->banner && list->banner->kind == SZFRIENDS_GTK_BANNER_ID_CHANGED && list->banner->text &&
               list->banner->action == NULL, "a partial banner keeps what it has");
    szfriends_gtk_list_snapshot_free(list);
    json_object_unref(object);
    EXPECT(szfriends_gtk_json_object_from_text("[1,2]", -1) == NULL, "a frame that is not an object is refused");
    EXPECT(szfriends_gtk_json_object_from_text("{\"a\":", -1) == NULL, "a truncated frame is refused");
    EXPECT(szfriends_gtk_view_type("teleport") == NULL, "an unknown view has no struct");
    SZFriendsGtkListSnapshot *empty = szfriends_gtk_list_snapshot_parse(NULL);
    EXPECT(empty && empty->query && empty->n_rows == 0, "no data parses as an empty view");
    szfriends_gtk_list_snapshot_free(empty);
}

/* A few values read through the typed structs, as the pages will read them. */
static void test_typed_values(void) {
    JsonObject *frame = szfg_fixture("snapshots/list.json");
    if (!frame) return;
    SZFriendsGtkListSnapshot *list = szfriends_gtk_list_snapshot_parse(json_object_get_object_member(frame, "data"));
    EXPECT(list->n_rows > 0 && strcmp(list->rows[0].conversation_id, "c_lena") == 0, "first row is Lena");
    EXPECT(list->rows[0].waiting && list->rows[0].waiting->kind == SZFRIENDS_GTK_WAITING_REQUEST,
           "Lena's row waits for an answer to a request");
    EXPECT(list->rows[0].n_actions == 3 && list->rows[0].actions[2].action == SZFRIENDS_GTK_ACTION_BLOCK &&
               list->rows[0].actions[2].arm && list->rows[0].actions[2].arm->seconds == 4,
           "Block on the row is armed for 4 seconds");
    EXPECT(list->rows[0].drop_label == NULL && list->rows[0].drop_refusal && *list->rows[0].drop_refusal,
           "a request refuses drops and says why");
    EXPECT(list->rows[0].avatar.kind == SZFRIENDS_GTK_AVATAR_ANIMAL && list->rows[0].avatar.index == 3,
           "Lena's avatar is animal 3");
    szfriends_gtk_list_snapshot_free(list);
    json_object_unref(frame);
    frame = szfg_fixture("snapshots/profile-unreserved.json");
    if (!frame) return;
    SZFriendsGtkProfileSnapshot *profile =
        szfriends_gtk_profile_snapshot_parse(json_object_get_object_member(frame, "data"));
    EXPECT(profile->picture.selected_index.set && profile->picture.selected_index.value == 0,
           "selected index 0 is set, not mistaken for null");
    EXPECT(profile->id.state == SZFRIENDS_GTK_ID_UNRESERVED && profile->id.qr_payload == NULL, "M1 shows no QR");
    szfriends_gtk_profile_snapshot_free(profile);
    json_object_unref(frame);
}

void szfg_run_snapshot_tests(void) {
    test_snapshot_fixtures();
    test_frame_fixtures();
    test_reply_fixtures();
    test_lenient_parsing();
    test_typed_values();
}
