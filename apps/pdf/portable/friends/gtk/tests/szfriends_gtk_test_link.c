/* The link against the fake helper over a real socket, driven by the GLib main loop (display-free): the hello it
 * sends, snapshots routed to their subscriptions, replies routed by id and run exactly once, not_ready on an idle,
 * the static strings and the drag strings built from them. Reconnects are in szfriends_gtk_test_reconnect.c. */

#include "szfriends_gtk_support.h"
#include "gtk/szfriends_gtk_drops.h"

#include <string.h>

typedef struct {
    guint calls;
    gint64 rev;
    JsonObject *data;
    char *code, *message;
    gboolean ok, destroyed;
} SZFGRecord;

static void record_clear(SZFGRecord *record) {
    if (record->data) json_object_unref(record->data);
    g_free(record->code);
    g_free(record->message);
    memset(record, 0, sizeof *record);
}

static void on_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    SZFGRecord *record = user_data;
    record->calls++;
    record->rev = rev;
    if (record->data) json_object_unref(record->data);
    record->data = json_object_ref(data);
}

static void on_reply(JsonObject *result, const SZFriendsGtkError *error, gpointer user_data) {
    SZFGRecord *record = user_data;
    record->calls++;
    record->ok = result != NULL && error == NULL;
    g_free(record->code);
    g_free(record->message);
    record->code = g_strdup(error ? error->code : NULL);
    record->message = g_strdup(error ? error->message : NULL);
}

static void on_destroy(gpointer user_data) {
    ((SZFGRecord *)user_data)->destroyed = TRUE;
}

static gboolean called(gpointer data) {
    return ((SZFGRecord *)data)->calls > 0;
}

static gboolean fixture_data_equal(JsonObject *data, const char *fixture) {
    JsonObject *frame = szfg_fixture(fixture);
    if (!frame || !data) return FALSE;
    JsonNode *a = json_node_init_object(json_node_alloc(), data);
    JsonNode *b = json_node_init_object(json_node_alloc(), json_object_get_object_member(frame, "data"));
    gboolean same = json_node_equal(a, b);
    json_node_unref(a);
    json_node_unref(b);
    json_object_unref(frame);
    return same;
}

typedef struct {
    guint self, victim, victim_calls, after_calls;
} SZFGWatchRace;

/* On READY: removes itself and the victim registered after the next watch. */
static void remover(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    SZFGWatchRace *race = data;
    if (state != SZFRIENDS_GTK_LINK_READY || !race->self) return;
    szfriends_gtk_link_remove_state_watch(link, race->self);
    szfriends_gtk_link_remove_state_watch(link, race->victim);
    race->self = race->victim = 0;
}

static void after(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    (void)link;
    if (state == SZFRIENDS_GTK_LINK_READY) ((SZFGWatchRace *)data)->after_calls++;
}

static void victim(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    (void)link;
    if (state == SZFRIENDS_GTK_LINK_READY) ((SZFGWatchRace *)data)->victim_calls++;
}

static void test_hello_and_strings(void) {
    SZFGHarness *harness = szfg_harness_new("hello", TRUE);
    /* Watches removed mid-run (a window closing on a state change): the rest still run, the removed stay silent. */
    SZFGWatchRace race = {0, 0, 0, 0};
    race.self = szfriends_gtk_link_add_state_watch(harness->link, remover, &race, NULL);
    szfriends_gtk_link_add_state_watch(harness->link, after, &race, NULL);
    race.victim = szfriends_gtk_link_add_state_watch(harness->link, victim, &race, NULL);
    EXPECT(szfriends_gtk_link_string(harness->link, "button_label")[0] == '\0', "no strings before the welcome");
    if (!szfg_harness_ready(harness, 5000)) goto done;
    EXPECT(race.after_calls == 1 && race.victim_calls == 0, "a watch removed during a run is not called, and the "
           "one after the remover still is (%u, %u)", race.after_calls, race.victim_calls);
    JsonObject *hello = szfg_fake_last_frame(harness, "hello");
    JsonObject *client = hello ? json_object_get_object_member(hello, "client") : NULL;
    EXPECT(client && strcmp(json_object_get_string_member(client, "toolkit"), "gtk4") == 0, "hello says gtk4");
    EXPECT(client && strcmp(json_object_get_string_member(client, "reveal_in"), "Shenzhen Files") == 0 &&
               strcmp(json_object_get_string_member(client, "app_name"), "Shenzhen Files") == 0,
           "hello names the app and where received files are shown");
    EXPECT(hello && json_object_get_null_member(hello, "embedded_helper"), "no embedded helper: never wins handover");
    JsonArray *capabilities = hello ? json_object_get_array_member(hello, "capabilities") : NULL;
    EXPECT(capabilities && json_array_get_length(capabilities) == 2 &&
               strcmp(json_array_get_string_element(capabilities, 0), "drop.files") == 0 &&
               strcmp(json_array_get_string_element(capabilities, 1), "mentions") == 0,
           "a host without # items or tabs claims drop.files, and mentions, which the views draw");
    if (hello) json_object_unref(hello);
    EXPECT(strcmp(szfriends_gtk_link_string(harness->link, "button_label"), "Friends") == 0, "welcome strings");
    EXPECT(strcmp(szfriends_gtk_link_string(harness->link, "no_such_key"), "") == 0, "an absent key reads as \"\"");
    EXPECT(szfriends_gtk_link_helper_has_capability(harness->link, "messages.status"), "helper capabilities");
    EXPECT(szfriends_gtk_link_status_text(harness->link) == NULL, "nothing to say while READY");
    EXPECT(szfriends_gtk_link_watched_fd(harness->link) >= 0 &&
               szfriends_gtk_link_watched_fd(harness->link) == szfriends_gtk_link_client_fd(harness->link),
           "the client's descriptor is watched");
    /* The drag strings, filled only where PROTOCOL.md § Static strings says. */
    const char *one[] = {"Site photos.pdf"}, *two[] = {"Site photos.pdf", "Plan.pdf"};
    char *title = szfriends_gtk_send_picker_title(harness->link, one, 1, 1);
    EXPECT(g_strcmp0(title, "Send Site photos.pdf to…") == 0, "one named file: %s", title);
    g_free(title);
    title = szfriends_gtk_send_picker_title(harness->link, two, 2, 2);
    EXPECT(g_strcmp0(title, "Send Site photos.pdf and 1 more to…") == 0, "named and more: %s", title);
    g_free(title);
    title = szfriends_gtk_send_picker_title(harness->link, NULL, 0, 3);
    EXPECT(g_strcmp0(title, "Send 3 files to…") == 0, "counted when names are unknown: %s", title);
    g_free(title);
    title = szfriends_gtk_send_picker_title(harness->link, NULL, 0, 1);
    EXPECT(g_strcmp0(title, "Send 1 file to…") == 0, "one unnamed file: %s", title);
    g_free(title);
    EXPECT(strcmp(szfriends_gtk_drop_refusal(harness->link, SZFRIENDS_GTK_DROP_REFUSE_FOLDER),
                  "Folders can’t be sent yet") == 0, "folders refused with the helper's words");
    EXPECT(strcmp(szfriends_gtk_drop_refusal(harness->link, SZFRIENDS_GTK_DROP_ACCEPT), "") == 0, "files: nothing");
    EXPECT(strcmp(szfriends_gtk_drop_refusal(harness->link, SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE),
                  szfriends_gtk_link_string(harness->link, "drop_not_a_file")) == 0,
           "links and special files refused with the helper's words, never the views' own");
    /* Filled in one pass (security review, wave 6a): a placeholder inside a file name shows as itself. */
    const char *odd[] = {"{count} {name}.pdf", "Plan.pdf"};
    title = szfriends_gtk_send_picker_title(harness->link, odd, 2, 2);
    EXPECT(g_strcmp0(title, "Send {count} {name}.pdf and 1 more to…") == 0, "a placeholder in a name: %s", title);
    g_free(title);
done:
    szfg_harness_free(harness);
}

static void test_subscriptions_and_replies(void) {
    SZFGHarness *harness = szfg_harness_new("routes", TRUE);
    SZFGRecord list = {0}, reply = {0}, error = {0}, forgotten = {0};
    if (!szfg_harness_ready(harness, 5000)) goto done;
    guint token = szfriends_gtk_link_subscribe(harness->link, "list", NULL, on_snapshot, &list, NULL);
    EXPECT(szfg_pump_until(called, &list, 3000), "the list snapshot arrives");
    EXPECT(list.rev == 1 && fixture_data_equal(list.data, "snapshots/list.json"), "the list is the fixture, rev 1");
    EXPECT(szfriends_gtk_link_badge(harness->link) && szfriends_gtk_link_badge(harness->link)->count == 2,
           "the shared badge subscription delivered the count");
    EXPECT(szfg_fake_frames(harness, "subscribe", "view", "badge") == 1, "one badge subscription for every window");
    szfriends_gtk_link_send(harness->link, szfriends_intent_accept_offer("t_kenji_site"), on_reply, &reply, NULL);
    EXPECT(szfg_pump_until(called, &reply, 3000) && reply.ok && reply.calls == 1, "accept_offer's reply routed");
    szfriends_fake_helper_set_reply(harness->fake, "block",
        "{\"type\":\"reply\",\"re\":\"0\",\"ok\":false,\"error\":{\"code\":\"stale\",\"message\":\"Lena changed "
        "her request meanwhile.\",\"retryable\":false,\"details\":{}}}");
    szfriends_gtk_link_send(harness->link, szfriends_intent_block("c_lena"), on_reply, &error, NULL);
    EXPECT(szfg_pump_until(called, &error, 3000) && g_strcmp0(error.code, "stale") == 0 &&
               g_strcmp0(error.message, "Lena changed her request meanwhile.") == 0,
           "an error reply carries the helper's code and words");
    guint request = szfriends_gtk_link_send(harness->link, szfriends_intent_ping(), on_reply, &forgotten, on_destroy);
    szfriends_gtk_link_forget_reply(harness->link, request);
    EXPECT(forgotten.destroyed, "forgetting a reply releases its data at once");
    szfg_pump_for(150);
    EXPECT(forgotten.calls == 0, "a forgotten reply never runs");
    /* Unsubscribing before the subscribe's reply: the reply then unsubscribes the helper's id at once. */
    guint early = szfriends_gtk_link_subscribe(harness->link, "nearby", NULL, on_snapshot, &list, NULL);
    szfriends_gtk_link_unsubscribe(harness->link, early);
    szfg_pump_for(200);
    EXPECT(szfg_fake_frames(harness, "unsubscribe", NULL, NULL) == 1, "the abandoned subscription is released");
    szfriends_gtk_link_unsubscribe(harness->link, token);
    szfg_pump_for(100);
    EXPECT(szfg_fake_frames(harness, "unsubscribe", NULL, NULL) == 2, "unsubscribe reaches the helper");
done:
    szfg_harness_free(harness);
    record_clear(&list);
    record_clear(&reply);
    record_clear(&error);
    record_clear(&forgotten);
}

static void test_not_ready(void) {
    SZFGHarness *harness = szfg_harness_new("idle", FALSE);
    SZFGRecord reply = {0};
    szfriends_gtk_link_send(harness->link, szfriends_intent_ping(), on_reply, &reply, on_destroy);
    EXPECT(reply.calls == 0, "not_ready is never delivered re-entrantly");
    EXPECT(szfg_pump_until(called, &reply, 1000) && g_strcmp0(reply.code, "not_ready") == 0, "not_ready on the idle");
    szfg_pump_for(50);
    EXPECT(reply.calls == 1 && reply.destroyed, "exactly once, then released");
    record_clear(&reply);
    szfriends_gtk_link_send(harness->link, NULL, on_reply, &reply, NULL);
    EXPECT(szfg_pump_until(called, &reply, 1000) && g_strcmp0(reply.code, "invalid_field") == 0,
           "a NULL intent fails as invalid_field");
    record_clear(&reply);
    szfg_harness_free(harness);
    SZFriendsGtkHost incomplete = {.struct_size = sizeof incomplete, .app_id = "x", .app_name = "x"};
    EXPECT(szfriends_gtk_link_new(&incomplete) == NULL, "a host without its identity is refused");
    incomplete.struct_size = 8;
    EXPECT(szfriends_gtk_link_new(&incomplete) == NULL, "a host struct too small to read is refused");
}

void szfg_run_link_tests(void) {
    test_hello_and_strings();
    test_subscriptions_and_replies();
    test_not_ready();
}
