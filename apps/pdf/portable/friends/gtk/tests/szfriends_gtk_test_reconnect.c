/* The link across reconnects (display-free): connection_lost exactly once, every subscription sent again with its
 * filter and earlier-history count, the descriptor watch re-armed, retries driven by the tick timer, stop with
 * `disable`, and the launch-path spawn on a worker thread. */

#include "szfriends_gtk_support.h"

#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct {
    guint calls, snapshots;
    char *code;
} SZFGCount;

static void count_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)data, (void)rev;
    ((SZFGCount *)user_data)->snapshots++;
}

static void count_reply(JsonObject *result, const SZFriendsGtkError *error, gpointer user_data) {
    SZFGCount *count = user_data;
    (void)result;
    count->calls++;
    g_free(count->code);
    count->code = g_strdup(error ? error->code : "ok");
}

static gboolean got_snapshot(gpointer data) {
    return ((SZFGCount *)data)->snapshots > 0;
}

static gboolean got_reply(gpointer data) {
    return ((SZFGCount *)data)->calls > 0;
}

static gboolean badge_arrived(gpointer data) {
    return szfriends_gtk_link_badge(data) != NULL;
}

static void test_reconnect(void) {
    SZFGHarness *harness = szfg_harness_new("again", TRUE);
    SZFGCount list = {0}, conversation = {0}, pending = {0};
    if (!szfg_harness_ready(harness, 5000)) goto done;
    guint token = szfriends_gtk_link_subscribe(harness->link, "list", NULL, count_snapshot, &list, NULL);
    guint open = szfriends_gtk_link_open_conversation(harness->link, "c_mei", "m_mei_contract", count_snapshot,
                                                      &conversation, NULL);
    EXPECT(szfg_pump_until(got_snapshot, &list, 3000) && szfg_pump_until(got_snapshot, &conversation, 3000),
           "both subscriptions deliver");
    szfriends_gtk_link_set_filter(harness->link, token, "mei");
    szfriends_gtk_link_load_earlier(harness->link, open);
    szfg_pump_for(150);
    EXPECT(szfg_fake_frames(harness, "set_filter", "query", "mei") == 1, "the filter reaches the helper");
    int old_fd = szfriends_gtk_link_watched_fd(harness->link);
    szfriends_fake_helper_hold_replies(harness->fake, TRUE);
    szfriends_gtk_link_send(harness->link, szfriends_intent_ping(), count_reply, &pending, NULL);
    szfg_pump_for(100);
    EXPECT(pending.calls == 0, "the held intent waits for its reply");
    szfriends_fake_helper_hold_replies(harness->fake, FALSE);
    guint mark = harness->n_states;
    list.snapshots = conversation.snapshots = 0;
    szfriends_fake_helper_drop_clients(harness->fake); /* a crash: no goodbye */
    EXPECT(szfg_harness_wait_state(harness, SZFRIENDS_GTK_LINK_WAITING, mark, 3000), "the link notices the drop");
    EXPECT(szfg_pump_until(got_reply, &pending, 3000) && g_strcmp0(pending.code, "connection_lost") == 0,
           "the waiting intent gets connection_lost");
    EXPECT(szfg_harness_wait_state(harness, SZFRIENDS_GTK_LINK_READY, mark, 5000), "and reconnects by itself");
    EXPECT(szfg_pump_until(got_snapshot, &list, 3000) && szfg_pump_until(got_snapshot, &conversation, 3000),
           "every subscription is sent again and delivers on the same handler");
    szfg_pump_for(200);
    EXPECT(pending.calls == 1, "connection_lost ran once, though the library also reported it");
    EXPECT(szfg_fake_frames(harness, "subscribe", "view", "list") == 2, "the list was subscribed again");
    EXPECT(szfg_fake_frames(harness, "set_filter", "query", "mei") == 2, "with its filter");
    EXPECT(szfg_fake_frames(harness, "load_earlier", NULL, NULL) == 2, "and its earlier history");
    JsonObject *reopen = szfg_fake_last_frame(harness, "open_conversation");
    EXPECT(reopen && !json_object_has_member(reopen, "message_id"), "a highlight is asked for once, not on reconnect");
    if (reopen) json_object_unref(reopen);
    int new_fd = szfriends_gtk_link_watched_fd(harness->link);
    EXPECT(new_fd >= 0 && new_fd == szfriends_gtk_link_client_fd(harness->link),
           "the new connection's descriptor is watched (was %d, now %d)", old_fd, new_fd);
    /* A goodbye on purpose reconnects the same way. */
    mark = harness->n_states;
    szfriends_fake_helper_send_goodbye(harness->fake, "{\"type\":\"goodbye\",\"reason\":\"shutdown\",\"message\":null,"
                                                      "\"successor\":null,\"error\":null}");
    EXPECT(szfg_harness_wait_state(harness, SZFRIENDS_GTK_LINK_READY, mark, 5000), "back after a goodbye");
    EXPECT(szfriends_gtk_link_status_text(harness->link) == NULL, "the status line clears once connected");
done:
    szfg_harness_free(harness);
    g_free(pending.code);
}

/* With nothing listening the link retries from its timer: the helper appearing later is found without any event. */
static void test_retry_by_timer(void) {
    SZFGHarness *harness = szfg_harness_new("later", FALSE);
    guint mark = harness->n_states;
    szfriends_gtk_link_start(harness->link);
    szfg_pump_for(300);
    EXPECT(szfriends_gtk_link_get_state(harness->link) == SZFRIENDS_GTK_LINK_CONNECTING,
           "still connecting with no helper");
    const char *status = szfriends_gtk_link_status_text(harness->link);
    EXPECT(status && *status, "the status line says what is happening");
    szfg_harness_start_fake(harness);
    EXPECT(szfg_harness_wait_state(harness, SZFRIENDS_GTK_LINK_READY, mark, 5000), "found once it listens");
    szfg_harness_free(harness);
}

static void test_stop(void) {
    SZFGHarness *harness = szfg_harness_new("stop", TRUE);
    SZFGCount pending = {0};
    if (!szfg_harness_ready(harness, 5000)) goto done;
    /* Hold only once the fake has read everything sent so far: it drains scripting before each read, so a frame
     * already waiting could be read together with the ping and answered before the hold applies. */
    EXPECT(szfg_pump_until(badge_arrived, harness->link, 3000), "the badge subscription was answered");
    szfriends_fake_helper_hold_replies(harness->fake, TRUE);
    szfriends_gtk_link_send(harness->link, szfriends_intent_ping(), count_reply, &pending, NULL);
    szfg_pump_for(100);
    szfriends_gtk_link_stop(harness->link, TRUE);
    EXPECT(pending.calls == 1 && g_strcmp0(pending.code, "connection_lost") == 0,
           "stopping ends waiting intents (%u calls, %s)", pending.calls, pending.code ? pending.code : "none");
    EXPECT(szfriends_gtk_link_get_state(harness->link) == SZFRIENDS_GTK_LINK_IDLE, "idle after stop");
    szfg_pump_for(200);
    EXPECT(szfg_fake_frames(harness, "disable", NULL, NULL) == 1, "Friends turned off tells the helper");
    EXPECT(szfriends_fake_helper_client_count(harness->fake) == 0, "and disconnects");
    szfriends_fake_helper_hold_replies(harness->fake, FALSE);
    guint mark = harness->n_states;
    szfriends_gtk_link_start(harness->link);
    EXPECT(szfg_harness_wait_state(harness, SZFRIENDS_GTK_LINK_READY, mark, 5000), "starting again reconnects");
done:
    szfg_harness_free(harness);
    g_free(pending.code);
}

static gboolean socket_answers(const char *state) {
    char path[SZFRIENDS_PATH_CAP];
    if (szfriends_socket_path(state, path, sizeof path, NULL) != SZFRIENDS_OK) return FALSE;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    g_strlcpy(address.sun_path, path, sizeof address.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    gboolean answered = fd >= 0 && connect(fd, (struct sockaddr *)&address, sizeof address) == 0;
    if (fd >= 0) close(fd);
    return answered;
}

static gboolean spawned(gpointer data) {
    return socket_answers(data);
}

/* Without connecting: every connection would restart the helper's idle timer. */
static gboolean exited(gpointer data) {
    char path[SZFRIENDS_PATH_CAP];
    return szfriends_socket_path(data, path, sizeof path, NULL) == SZFRIENDS_OK &&
           !g_file_test(path, G_FILE_TEST_EXISTS);
}

/* The launch path: the library refuses to spawn on the main thread, so a helper answering proves the work ran on the
 * worker thread. The fake exits once idle, leaving no process behind. */
static void test_spawn(const char *fake_exe) {
    char *state = szfg_temp_dir("spawn");
    g_setenv(SZFRIENDS_ENV_STATE_DIR, state, TRUE);
    g_setenv("SZFRIENDS_FAKE_FIXTURES", szfg_fixtures, TRUE);
    g_setenv("SZFRIENDS_FAKE_IDLE_EXIT_MS", "300", TRUE);
    g_setenv("SZFRIENDS_FAKE_FIRST_CLIENT_MS", "1500", TRUE);
    szfriends_gtk_spawn_helper_async(fake_exe);
    EXPECT(szfg_pump_until(spawned, state, 5000), "the helper was spawned off the main thread");
    EXPECT(szfg_pump_until(exited, state, 6000), "the spawned helper exits when nobody needs it");
    g_unsetenv("SZFRIENDS_FAKE_IDLE_EXIT_MS");
    g_unsetenv("SZFRIENDS_FAKE_FIRST_CLIENT_MS");
    szfg_pump_for(100);
    szfg_remove_tree(state);
    g_free(state);
}

void szfg_run_reconnect_tests(const char *fake_exe) {
    test_reconnect();
    test_retry_by_timer();
    test_stop();
    test_spawn(fake_exe);
}
