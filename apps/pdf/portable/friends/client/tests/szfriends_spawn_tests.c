/* Connect-or-spawn and handover with real processes: the fake helper executable stands in for the helper. It
 * takes helper.lock, so these tests also show duplicates exiting, and it exits 500 ms after its last client
 * (SZFRIENDS_FAKE_IDLE_EXIT_MS, set by main), so nothing outlives the suite. Loopback Unix sockets only. */

#define _DARWIN_C_SOURCE 1

#include "szfriends_test_support.h"

#include "client/szfriends_client_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct spawn_call {
    const char *helper_path, *state_dir;
    szfriends_status status;
    pid_t pid;
} spawn_call;

static void *spawn_thread(void *argument) {
    spawn_call *call = (spawn_call *)argument;
    call->status = szfriends_spawn_helper(call->helper_path, call->state_dir, &call->pid);
    return NULL;
}

/* szfriends_spawn_helper from a background thread, as the launch path calls it. */
static szfriends_status spawn_in_background(const char *helper_path, const char *state_dir, pid_t *pid) {
    pthread_t thread;
    spawn_call call;
    memset(&call, 0, sizeof call);
    call.helper_path = helper_path;
    call.state_dir = state_dir;
    pthread_create(&thread, NULL, spawn_thread, &call);
    pthread_join(thread, NULL);
    if (pid) *pid = call.pid;
    return call.status;
}

static bool helper_answers(const char *state_dir, int timeout_ms) {
    char socket_path[SZFRIENDS_PATH_CAP];
    uint64_t deadline = szfriends_monotonic_ms() + (uint64_t)timeout_ms;
    szfriends_socket_path(state_dir, socket_path, sizeof socket_path, NULL);
    while (szfriends_monotonic_ms() < deadline) {
        if (szfriends_probe_socket(socket_path) == SZFRIENDS_OK) return true;
        szft_sleep_ms(20);
    }
    return false;
}

/* True once no helper holds the state directory's lock: every helper this test started has exited. */
static bool all_helpers_exited(const char *state_dir, int timeout_ms) {
    char lock_path[SZFRIENDS_PATH_CAP + 16];
    uint64_t deadline = szfriends_monotonic_ms() + (uint64_t)timeout_ms;
    snprintf(lock_path, sizeof lock_path, "%s/helper.lock", state_dir);
    while (szfriends_monotonic_ms() < deadline) {
        int fd = open(lock_path, O_RDWR | O_CLOEXEC);
        if (fd < 0) return true;
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            close(fd);
            return true;
        }
        close(fd);
        szft_sleep_ms(25);
    }
    return false;
}

static void test_spawn_helper(void) {
    char *state = szft_temp_dir("spawn");
    pid_t pid = -1, second = -1;
    szft_client_options options;
    szft_client *harness;

    EXPECT(szfriends_spawn_helper(szft_fake_exe, state, &pid) == SZFRIENDS_ERR_INVALID_ARGUMENT && pid == 0,
           "refuses the main thread and spawns nothing");
    EXPECT(spawn_in_background(NULL, state, &pid) == SZFRIENDS_ERR_INVALID_ARGUMENT, "no helper path");
    EXPECT(spawn_in_background(szft_fake_exe, state, &pid) == SZFRIENDS_OK && pid > 0, "spawned (pid %d)", (int)pid);
    EXPECT(helper_answers(state, 5000), "the spawned helper listens");
    EXPECT(spawn_in_background(szft_fake_exe, state, &second) == SZFRIENDS_OK && second == 0,
           "a running helper answers, so nothing is spawned");

    memset(&options, 0, sizeof options);
    options.state_dir = state;
    harness = szft_client_new(&options);
    szfriends_client_start(harness->client);
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 5000), "a client reaches the spawned helper");
    szfriends_client_stop(harness->client, true);
    szft_client_free(harness);
    EXPECT(all_helpers_exited(state, 5000), "the helper exits after its last client");
    /* The detached reaper waited for it: no zombie remains under our pid. */
    {
        uint64_t deadline = szfriends_monotonic_ms() + 2000;
        while (kill(pid, 0) == 0 && szfriends_monotonic_ms() < deadline) szft_sleep_ms(20);
        EXPECT(kill(pid, 0) != 0 && errno == ESRCH, "reaped");
    }
    szft_remove_tree(state);
    free(state);
}

static void test_concurrent_spawns(void) {
    char *state = szft_temp_dir("race");
    pthread_t threads[8];
    spawn_call calls[8];
    int i, alive = 0, spawned = 0;
    uint64_t deadline;
    for (i = 0; i < 8; i++) {
        memset(&calls[i], 0, sizeof calls[i]);
        calls[i].helper_path = szft_fake_exe;
        calls[i].state_dir = state;
        pthread_create(&threads[i], NULL, spawn_thread, &calls[i]);
    }
    for (i = 0; i < 8; i++) pthread_join(threads[i], NULL);
    for (i = 0; i < 8; i++) {
        EXPECT(calls[i].status == SZFRIENDS_OK, "spawn %d: %s", i, szfriends_status_name(calls[i].status));
        spawned += calls[i].pid > 0;
    }
    EXPECT(spawned >= 1, "at least one spawn");
    EXPECT(helper_answers(state, 5000), "one helper listens");
    /* Duplicates find helper.lock held and exit at once; exactly one keeps running. */
    deadline = szfriends_monotonic_ms() + 3000;
    do {
        alive = 0;
        for (i = 0; i < 8; i++) alive += calls[i].pid > 0 && kill(calls[i].pid, 0) == 0;
        if (alive <= 1) break;
        szft_sleep_ms(25);
    } while (szfriends_monotonic_ms() < deadline);
    EXPECT(alive == 1, "exactly one helper survives (%d alive of %d spawned)", alive, spawned);
    EXPECT(all_helpers_exited(state, 6000), "and it exits on its own");
    szft_remove_tree(state);
    free(state);
}

static void test_client_spawns_when_nobody_listens(void) {
    char *state = szft_temp_dir("autospawn");
    szft_client_options options;
    szft_client *harness;
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    options.helper_path = szft_fake_exe;
    options.helper_version = "26.10.12-1";
    options.helper_build = 26101201;
    harness = szft_client_new(&options);
    EXPECT(szfriends_client_start(harness->client) == SZFRIENDS_OK, "start from the main thread");
    EXPECT(szft_wait_state(harness, SZFRIENDS_CONNECTION_READY, 5000), "spawned and connected");
    EXPECT(szft_saw_state(harness, 0, SZFRIENDS_CONNECTION_CONNECTING) &&
               !szft_saw_state(harness, 0, SZFRIENDS_CONNECTION_WAITING),
           "CONNECTING while the helper starts, never WAITING");
    szfriends_client_stop(harness->client, true);
    szft_client_free(harness);
    EXPECT(all_helpers_exited(state, 5000), "helper gone");
    szft_remove_tree(state);
    free(state);
}

/* A shell script that runs the fake executable as a helper of the given build. */
static char *helper_script(const char *directory, const char *name, unsigned build) {
    char path[4096];
    FILE *file;
    snprintf(path, sizeof path, "%s/%s", directory, name);
    file = fopen(path, "w");
    fprintf(file, "#!/bin/sh\nSZFRIENDS_FAKE_BUILD=%u exec \"%s\"\n", build, szft_fake_exe);
    fclose(file);
    chmod(path, 0700);
    return strdup(path);
}

static long welcome_build(szft_client *harness, size_t from) {
    long index = szft_find_frame(harness, from, "welcome", NULL), build = -1;
    cJSON *frame = szft_frame_json(harness, index);
    const cJSON *number = cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(frame, "helper"),
                                                           "build_number");
    if (cJSON_IsNumber(number)) build = (long)number->valuedouble;
    cJSON_Delete(frame);
    return build;
}

static void test_handover(void) {
    char *state = szft_temp_dir("handover"), *scripts = szft_temp_dir("scripts");
    char *newer = helper_script(scripts, "helper-200", 200), *older = helper_script(scripts, "helper-100", 100);
    szfriends_fake_helper *old_helper = szft_fake_start(state, 0, 0, 0, 100, true);
    szft_client_options options;
    szft_client *a, *b;
    long index = -1;
    cJSON *frame;

    /* B embeds build 100, the running helper's own: no handover from B, and older than the successor, so after
     * the handover it waits for the successor instead of spawning its own. */
    memset(&options, 0, sizeof options);
    options.state_dir = state;
    options.helper_path = older;
    options.helper_version = "v100";
    options.helper_build = 100;
    b = szft_client_new(&options);
    /* A embeds build 200, newer than the running 100: its hello asks the old helper to step aside. */
    options.helper_path = newer;
    options.helper_version = "v200";
    options.helper_build = 200;
    a = szft_client_new(&options);

    szfriends_client_start(b->client);
    EXPECT(szft_wait_state(b, SZFRIENDS_CONNECTION_READY, 5000), "B on the old helper");
    EXPECT(welcome_build(b, 0) == 100, "B welcomed by build 100");
    szfriends_client_start(a->client);
    EXPECT(szft_wait_state(a, SZFRIENDS_CONNECTION_READY, 5000), "A on the old helper");
    frame = szft_frame_json(a, szft_find_frame(a, 0, "welcome", NULL));
    EXPECT(frame && strcmp(cJSON_GetObjectItemCaseSensitive(frame, "handover")->valuestring, "scheduled") == 0,
           "the old helper schedules a handover for A");
    cJSON_Delete(frame);

    EXPECT(szft_wait_frame(a, 1, "goodbye", NULL, 3000, &index), "goodbye handover to A");
    EXPECT(szfriends_fake_helper_stepped_aside(old_helper), "the old helper stepped aside");
    EXPECT(szft_wait_state(a, SZFRIENDS_CONNECTION_READY, 5000) && welcome_build(a, (size_t)index) == 200,
           "A spawned its build-200 helper at once and reconnected");
    EXPECT(szft_wait_frame(b, 1, "goodbye", NULL, 3000, &index), "goodbye handover to B");
    EXPECT(szft_wait_state(b, SZFRIENDS_CONNECTION_READY, 6000) && welcome_build(b, (size_t)index) == 200,
           "B waited and joined the successor instead of starting its own build 100");

    szfriends_client_stop(a->client, false);
    szfriends_client_stop(b->client, false);
    szft_client_free(a);
    szft_client_free(b);
    szfriends_fake_helper_stop(old_helper);
    EXPECT(all_helpers_exited(state, 5000), "every helper exited");
    szft_remove_tree(state);
    szft_remove_tree(scripts);
    free(newer);
    free(older);
    free(state);
    free(scripts);
}

void szft_run_spawn_tests(void) {
    test_spawn_helper();
    test_concurrent_spawns();
    test_client_spawns_when_nobody_listens();
    test_handover();
}
