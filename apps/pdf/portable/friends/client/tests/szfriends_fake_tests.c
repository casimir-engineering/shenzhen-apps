/* The client library against the in-process fake helper: handshake, version mismatch, reconnection with backoff
 * and synthesized replies, frames at and over the 8 MiB cap, an unsafe socket directory. */

#include "szfriends_test_support.h"

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static szft_client *ready_client(const char *state, szfriends_fake_helper **fake_out) {
    szft_client_options options;
    szft_client *harness;
    *fake_out = szft_fake_start(state, 0, 0, 0, 0, false);
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    options.helper_version = "26.10.12-1";
    options.helper_build = 26101201; /* the welcome fixture's build: no handover */
    harness = szft_client_new(&options);
    EXPECT(szfriends_client_start(harness->client) == SZFRIENDS_OK, "start");
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 5000), "READY against the fake");
    return harness;
}

static void test_handshake(void) {
    char *state = szft_temp_dir("handshake");
    szfriends_fake_helper *fake;
    szft_client *harness = ready_client(state, &fake);
    cJSON *welcome = szft_frame_json(harness, 0), *hello_fixture, *hello_sent;
    char *sent;
    int major = -1, minor = -1;

    EXPECT(welcome && strcmp(cJSON_GetObjectItemCaseSensitive(welcome, "type")->valuestring, "welcome") == 0,
           "the welcome is the first frame the host sees");
    EXPECT(harness->state_count == 3 && harness->states[0] == SZFRIENDS_CONNECTION_CONNECTING &&
               harness->states[1] == SZFRIENDS_CONNECTION_HANDSHAKING &&
               harness->states[2] == SZFRIENDS_CONNECTION_READY,
           "CONNECTING, HANDSHAKING, READY (%zu states)", harness->state_count);
    szfriends_client_protocol(harness->client, &major, &minor);
    EXPECT(major == 1 && minor == 0, "negotiated 1.0 (%d.%d)", major, minor);

    /* The hello the library sent is the hello fixture, apart from the pid and the id it chose. */
    sent = szfriends_fake_helper_copy_frame(fake, 0);
    hello_sent = cJSON_Parse(sent);
    hello_fixture = szft_read_json("frames/hello.json");
    cJSON_ReplaceItemInObjectCaseSensitive(cJSON_GetObjectItemCaseSensitive(hello_fixture, "client"), "pid",
                                           cJSON_CreateNumber(0));
    cJSON_ReplaceItemInObjectCaseSensitive(cJSON_GetObjectItemCaseSensitive(hello_sent, "client"), "pid",
                                           cJSON_CreateNumber(0));
    cJSON_ReplaceItemInObjectCaseSensitive(hello_fixture, "id", cJSON_CreateString("x"));
    cJSON_ReplaceItemInObjectCaseSensitive(hello_sent, "id", cJSON_CreateString("x"));
    EXPECT(cJSON_Compare(hello_sent, hello_fixture, 1), "hello matches the fixture: %s", sent);
    EXPECT(szfriends_client_next_tick_ms(harness->client, szfriends_monotonic_ms()) == -1, "idle when READY");

    cJSON_Delete(hello_fixture);
    cJSON_Delete(hello_sent);
    szfriends_free(sent);
    cJSON_Delete(welcome);
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

static void test_not_ready_and_send_validation(void) {
    char *state = szft_temp_dir("notready");
    szft_client_options options;
    szft_client *harness;
    szfriends_fake_helper *fake;
    char id[24];
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    harness = szft_client_new(&options);
    EXPECT(szfriends_client_send(harness->client, "ping", NULL, id, sizeof id) == SZFRIENDS_ERR_NOT_READY,
           "intents never queue in the client");
    szft_client_free(harness);

    harness = ready_client(state, &fake);
    EXPECT(szfriends_client_send(harness->client, "hello", NULL, id, sizeof id) == SZFRIENDS_ERR_INVALID_ARGUMENT,
           "hello is not an intent");
    EXPECT(szfriends_client_send(harness->client, "Ping", NULL, id, sizeof id) == SZFRIENDS_ERR_INVALID_ARGUMENT,
           "intent names are lowercase");
    EXPECT(szfriends_client_send(harness->client, "ping", "[1]", id, sizeof id) == SZFRIENDS_ERR_INVALID_ARGUMENT,
           "fields must be an object");
    EXPECT(szfriends_client_send(harness->client, "ping", "{\"id\":\"9\"}", id, sizeof id) ==
               SZFRIENDS_ERR_INVALID_ARGUMENT,
           "fields cannot carry an id");
    EXPECT(szfriends_client_send(harness->client, "ping", NULL, id, 1) == SZFRIENDS_ERR_INVALID_ARGUMENT,
           "id buffer too small");
    EXPECT(szfriends_client_send(harness->client, "ping", NULL, id, sizeof id) == SZFRIENDS_OK && id[0], "ping");
    EXPECT(szft_wait_frame(harness, 0, "reply", id, 3000, NULL), "ping answered");
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

static void test_version_mismatch(void) {
    char *state = szft_temp_dir("version");
    szfriends_fake_helper *fake = szft_fake_start(state, 3, 0, 3, 0, false);
    szft_client_options options;
    szft_client *harness;
    long reply = -1;
    cJSON *frame;
    int64_t next;
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    options.helper_version = "26.10.12-1";
    options.helper_build = 1; /* older than the fake: no handover to offer */
    harness = szft_client_new(&options);
    szfriends_client_start(harness->client);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_INCOMPATIBLE, 5000), "INCOMPATIBLE");
    EXPECT(szft_wait_frame(harness, 0, "reply", "1", 100, &reply), "protocol_unsupported reached the host");
    frame = szft_frame_json(harness, reply);
    EXPECT(frame && strcmp(cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(frame, "error"), "code")
                               ->valuestring,
                           "protocol_unsupported") == 0,
           "error code");
    next = szfriends_client_next_tick_ms(harness->client, szfriends_monotonic_ms());
    EXPECT(next > 20000 && next <= 30000, "quiet retry in about 30 s (%lld)", (long long)next);
    EXPECT(!szft_saw_state(harness, 0, SZFRIENDS_CONNECTION_READY), "never READY");
    {
        int major = -1;
        szfriends_client_protocol(harness->client, &major, NULL);
        EXPECT(major == 0, "no negotiated protocol");
    }
    cJSON_Delete(frame);
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);

    /* A helper a minor ahead negotiates down to ours. */
    fake = szft_fake_start(state, 1, 4, 1, 0, false);
    harness = szft_client_new(&options);
    szfriends_client_start(harness->client);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 5000), "READY with a 1.4 helper");
    {
        int major = -1, minor = -1;
        szfriends_client_protocol(harness->client, &major, &minor);
        EXPECT(major == 1 && minor == 0, "1.0 negotiated with a 1.4 helper (%d.%d)", major, minor);
    }
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

static bool two_hellos(szft_client *harness, void *argument) {
    szfriends_fake_helper *fake = (szfriends_fake_helper *)argument;
    size_t i, hellos = 0;
    (void)harness;
    for (i = 0; i < szfriends_fake_helper_frame_count(fake); i++) {
        char *frame = szfriends_fake_helper_copy_frame(fake, i);
        hellos += frame && strstr(frame, "\"type\":\"hello\"") != NULL;
        szfriends_free(frame);
    }
    return hellos >= 2;
}

/* A helper that answers hello with an error but keeps the connection open must not hold the client in
 * HANDSHAKING until the 10 s timeout: the client ends the attempt and retries with its normal backoff. */
static void test_hello_rejected(void) {
    char *state = szft_temp_dir("hellofail");
    szfriends_fake_helper *fake = szft_fake_start(state, 0, 0, 0, 0, false);
    szft_client_options options;
    szft_client *harness;
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    szfriends_fake_helper_set_reply(fake, "hello", "{\"type\":\"reply\",\"re\":\"x\",\"ok\":false,\"error\":"
                                                   "{\"code\":\"invalid_field\",\"message\":null,\"retryable\":false,"
                                                   "\"details\":{\"field\":\"client.toolkit\"}}}");
    harness = szft_client_new(&options);
    szfriends_client_start(harness->client);
    EXPECT(szft_wait_frame(harness, 0, "reply", "1", 3000, NULL), "the hello error reaches the host");
    EXPECT(szft_pump(harness, two_hellos, fake, 2000), "a second attempt within 2 s, not after the 10 s timeout");
    EXPECT(!szft_saw_state(harness, 0, SZFRIENDS_CONNECTION_READY), "never READY");
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

static bool fake_saw_frames(szft_client *harness, void *argument) {
    (void)harness;
    return szfriends_fake_helper_frame_count((szfriends_fake_helper *)argument) >= 2;
}

static void test_reconnect(void) {
    char *state = szft_temp_dir("reconnect");
    szfriends_fake_helper *fake;
    szft_client *harness = ready_client(state, &fake);
    char id[24];
    size_t states_before, frames_before;
    long reply = -1;
    cJSON *frame, *lost;
    int64_t next;

    /* A crash with an intent outstanding: the host still gets exactly one reply for it. */
    szfriends_fake_helper_hold_replies(fake, true);
    EXPECT(szfriends_client_send_intent(harness->client, szfriends_intent_ping(), id, sizeof id) == SZFRIENDS_OK,
           "ping sent");
    EXPECT(szft_pump(harness, fake_saw_frames, fake, 3000), "the fake received the ping");
    states_before = harness->state_count;
    frames_before = harness->frame_count;
    szfriends_fake_helper_drop_clients(fake);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_WAITING, 3000), "WAITING after a crash");
    next = szfriends_client_next_tick_ms(harness->client, szfriends_monotonic_ms());
    EXPECT(next >= 0 && next <= 63, "first retry within 50 ms plus jitter (%lld)", (long long)next);
    EXPECT(szft_wait_frame(harness, frames_before, "reply", id, 100, &reply), "synthesized reply for the ping");
    frame = szft_frame_json(harness, reply);
    /* The synthesized reply is the connection_lost fixture apart from re, which names the ping: the intent left
     * this client, so it may have taken effect (PROTOCOL.md § Replies and errors), unlike not_ready. */
    lost = szft_read_json("frames/reply-connection-lost.json");
    EXPECT(frame && lost, "the reply and the fixture parse");
    if (frame && lost) {
        cJSON_ReplaceItemInObjectCaseSensitive(lost, "re", cJSON_CreateString(id));
        EXPECT(cJSON_Compare(frame, lost, true), "the reply equals reply-connection-lost.json apart from re");
    }
    cJSON_Delete(lost);
    cJSON_Delete(frame);
    szfriends_fake_helper_hold_replies(fake, false);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 3000), "READY again");
    EXPECT(szft_saw_state(harness, states_before, SZFRIENDS_CONNECTION_HANDSHAKING), "handshook again");
    EXPECT(szft_find_frame(harness, (size_t)reply + 1, "reply", id) == -1, "exactly one reply for the ping");
    szft_client_free(harness);

    /* With nobody listening and nothing to spawn, retries back off 50, 100, 200 ... ms up to 2 s. */
    szfriends_fake_helper_stop(fake);
    {
        szft_client_options options;
        int64_t delays[8];
        int i;
        memset(&options, 0, sizeof options);
        options.state_dir = state;
        harness = szft_client_new(&options);
        szfriends_client_start(harness->client);
        EXPECT(szfriends_client_state(harness->client) == SZFRIENDS_CONNECTION_CONNECTING,
               "CONNECTING before the first READY, not WAITING");
        delays[0] = szfriends_client_next_tick_ms(harness->client, szfriends_monotonic_ms());
        for (i = 1; i < 8; i++) {
            szft_sleep_ms((int)delays[i - 1] + 1);
            szfriends_client_tick(harness->client, szfriends_monotonic_ms());
            delays[i] = szfriends_client_next_tick_ms(harness->client, szfriends_monotonic_ms());
        }
        EXPECT(delays[0] >= 45 && delays[0] <= 63, "first delay %lld", (long long)delays[0]);
        EXPECT(delays[1] >= 95 && delays[1] <= 126, "second delay %lld", (long long)delays[1]);
        EXPECT(delays[2] >= 195 && delays[2] <= 251, "third delay %lld", (long long)delays[2]);
        for (i = 0; i < 8; i++) EXPECT(delays[i] <= 2000, "delay %d capped (%lld)", i, (long long)delays[i]);
        EXPECT(delays[7] >= 1990, "reaches the 2 s cap (%lld)", (long long)delays[7]);
        szft_client_free(harness);
    }
    szft_remove_tree(state);
    free(state);
}

static bool error_seen(szft_client *harness, void *argument) {
    return harness->last_error == *(szfriends_status *)argument;
}

static void test_frame_cap(void) {
    char *state = szft_temp_dir("cap");
    szfriends_fake_helper *fake;
    szft_client *harness = ready_client(state, &fake);
    const size_t cap = SZFRIENDS_MAX_FRAME_BYTES;
    static const char head[] = "{\"type\":\"snapshot\",\"pad\":\"";
    char *big = (char *)malloc(cap + 2);
    char *fields;
    char id[24];
    size_t frames_before = harness->frame_count, states_before;
    szfriends_status too_large = SZFRIENDS_ERR_FRAME_TOO_LARGE;
    long index = -1;

    /* Exactly 8 MiB without the newline is a valid frame. */
    memset(big, 'x', cap);
    memcpy(big, head, sizeof head - 1);
    big[cap - 2] = '"';
    big[cap - 1] = '}';
    big[cap] = '\n';
    szfriends_fake_helper_send_raw(fake, big, cap + 1);
    EXPECT(szft_wait_frame(harness, frames_before, "snapshot", NULL, 8000, &index), "an 8 MiB frame arrives");
    EXPECT(index >= 0 && strlen(harness->frames[index]) == cap, "delivered whole");
    EXPECT(szfriends_client_state(harness->client) == SZFRIENDS_CONNECTION_READY, "still READY");

    /* One byte more and the client stops buffering, closes and reconnects. */
    states_before = harness->state_count;
    memset(big, 'y', cap + 1);
    big[cap + 1] = '\n';
    szfriends_fake_helper_send_raw(fake, big, cap + 2);
    EXPECT(szft_pump(harness, error_seen, &too_large, 8000), "FRAME_TOO_LARGE reported");
    EXPECT(szft_saw_state(harness, states_before, SZFRIENDS_CONNECTION_WAITING), "closed");
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 3000), "and reconnected");

    /* The library never sends an over-cap frame. */
    fields = (char *)malloc(cap + 32);
    memcpy(fields, "{\"name\":\"", 9);
    memset(fields + 9, 'n', cap);
    memcpy(fields + 9 + cap - 12, "\"}", 3);
    EXPECT(szfriends_client_send(harness->client, "set_name", fields, id, sizeof id) == SZFRIENDS_ERR_FRAME_TOO_LARGE,
           "over-cap intent refused");
    free(fields);
    free(big);
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

static void test_unsafe_directory(void) {
    char *state = szft_temp_dir("unsafe");
    char ipc[4096];
    szft_client_options options;
    szft_client *harness;
    snprintf(ipc, sizeof ipc, "%s/ipc", state);
    mkdir(ipc, 0755);
    chmod(ipc, 0755);
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    harness = szft_client_new(&options);
    EXPECT(szfriends_client_start(harness->client) == SZFRIENDS_ERR_UNSAFE_DIRECTORY,
           "a group-readable socket directory is refused and reported");
    EXPECT(szfriends_client_fd(harness->client) < 0, "nothing connected");
    EXPECT(szfriends_client_next_tick_ms(harness->client, szfriends_monotonic_ms()) >= 0, "keeps retrying");
    szft_client_free(harness);
    szft_remove_tree(state);
    free(state);
}

/* A state directory too deep for sun_path puts the socket in the per-user szfriends-<hash> directory. Stopping the
 * fake removes that directory too: the views' and the host adapter's suites run the fake on such paths, and every
 * run used to leave one behind in TMPDIR (wave-4 integration sweep). */
static void test_fallback_directory_removed(void) {
    char *root = szft_temp_dir("fallback");
    char state[4096], socket_path[SZFRIENDS_PATH_CAP], directory[SZFRIENDS_PATH_CAP];
    struct stat info;
    bool fallback = false;
    szft_client *harness;
    szfriends_fake_helper *fake;
    char *slash;
    snprintf(state, sizeof state, "%s/%s", root,
             "a-state-directory-name-long-enough-that-the-socket-path-cannot-fit-in-sun-path-on-macos");
    EXPECT(szfriends_socket_path(state, socket_path, sizeof socket_path, &fallback) == SZFRIENDS_OK && fallback,
           "the socket falls back: %s", socket_path);
    snprintf(directory, sizeof directory, "%s", socket_path);
    slash = strrchr(directory, '/');
    if (slash) *slash = '\0';
    harness = ready_client(state, &fake);
    EXPECT(stat(directory, &info) == 0 && S_ISDIR(info.st_mode), "the fake made %s", directory);
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);
    EXPECT(stat(directory, &info) != 0, "stopping the fake removed %s", directory);
    rmdir(directory); /* only reached when the check above failed: leave nothing behind either way */
    szft_remove_tree(root);
    free(root);
}

/* The fake announces what the welcome fixture does (messages.status among it), or the capabilities a test gives it,
 * so a host's suite can also play a helper that cannot report delivery. */
static void test_capabilities(void) {
    char *state = szft_temp_dir("capabilities");
    szfriends_fake_helper_config config;
    szfriends_fake_helper *fake = NULL;
    szft_client_options options;
    szft_client *harness;
    cJSON *welcome, *capabilities;
    const cJSON *capability;
    bool announced = false;
    harness = ready_client(state, &fake);
    welcome = szft_frame_json(harness, 0);
    capabilities = cJSON_GetObjectItemCaseSensitive(welcome, "capabilities");
    cJSON_ArrayForEach(capability, capabilities) {
        if (cJSON_IsString(capability) && strcmp(capability->valuestring, "messages.status") == 0) announced = true;
    }
    EXPECT(announced, "the fixture's capabilities, messages.status among them");
    cJSON_Delete(welcome);
    szft_client_free(harness);
    szfriends_fake_helper_stop(fake);

    memset(&config, 0, sizeof config);
    config.state_dir = state;
    config.fixtures_dir = szft_fixtures;
    config.capabilities_json = "{}";
    EXPECT(szfriends_fake_helper_start(&config, &fake) == SZFRIENDS_ERR_INVALID_ARGUMENT && !fake,
           "capabilities are an array");
    config.capabilities_json = "[]";
    EXPECT(szfriends_fake_helper_start(&config, &fake) == SZFRIENDS_OK, "a helper with no capabilities");
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    options.helper_version = "26.10.12-1";
    options.helper_build = 26101201;
    harness = szft_client_new(&options);
    EXPECT(szfriends_client_start(harness->client) == SZFRIENDS_OK, "start");
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 5000), "READY against it");
    welcome = szft_frame_json(harness, 0);
    capabilities = cJSON_GetObjectItemCaseSensitive(welcome, "capabilities");
    EXPECT(cJSON_IsArray(capabilities) && cJSON_GetArraySize(capabilities) == 0, "announces none");
    cJSON_Delete(welcome);
    szft_client_free(harness);
    if (fake) szfriends_fake_helper_stop(fake);
    szft_remove_tree(state);
    free(state);
}

void szft_run_fake_tests(void) {
    test_handshake();
    test_not_ready_and_send_validation();
    test_version_mismatch();
    test_hello_rejected();
    test_reconnect();
    test_frame_cap();
    test_unsafe_directory();
    test_fallback_directory_removed();
    test_capabilities();
}
