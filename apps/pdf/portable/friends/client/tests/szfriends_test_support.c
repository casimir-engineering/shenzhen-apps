/* Shared helpers for the Friends client library tests (see szfriends_test_support.h). */

#define _DARWIN_C_SOURCE 1

#include "szfriends_test_support.h"

#include <errno.h>
#include <ftw.h>
#include <limits.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int szft_failures;
const char *szft_fixtures;
const char *szft_fake_exe;

char *szft_temp_dir(const char *label) {
    char path[PATH_MAX];
    const char *base = getenv("TMPDIR");
    char *made;
    snprintf(path, sizeof path, "%s/szft-%s-XXXXXX", base && *base ? base : "/tmp", label);
    made = mkdtemp(path);
    EXPECT(made != NULL, "mkdtemp %s: %s", path, strerror(errno));
    return made ? strdup(made) : NULL;
}

static int remove_entry(const char *path, const struct stat *info, int flag, struct FTW *walk) {
    (void)info;
    (void)flag;
    (void)walk;
    remove(path);
    return 0;
}

void szft_remove_tree(const char *path) {
    if (path) nftw(path, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
}

void szft_sleep_ms(int milliseconds) {
    struct timespec pause;
    pause.tv_sec = milliseconds / 1000;
    pause.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
    nanosleep(&pause, NULL);
}

cJSON *szft_read_json(const char *relative) {
    char path[PATH_MAX];
    FILE *file;
    char *text;
    long size;
    cJSON *json;
    snprintf(path, sizeof path, "%s/%s", szft_fixtures, relative);
    file = fopen(path, "rb");
    if (!file) {
        EXPECT(0, "cannot open fixture %s", path);
        return NULL;
    }
    fseek(file, 0, SEEK_END);
    size = ftell(file);
    fseek(file, 0, SEEK_SET);
    text = (char *)malloc((size_t)size + 1);
    if (fread(text, 1, (size_t)size, file) != (size_t)size) size = 0;
    fclose(file);
    text[size] = '\0';
    json = cJSON_Parse(text);
    free(text);
    EXPECT(json != NULL, "fixture %s does not parse", relative);
    return json;
}

bool szft_json_equivalent(const cJSON *a, const cJSON *b) {
    const cJSON *item;
    if (!a || !b) return a == b;
    if (cJSON_IsObject(a) && cJSON_IsObject(b)) {
        cJSON_ArrayForEach(item, a) {
            const cJSON *other = cJSON_GetObjectItemCaseSensitive(b, item->string);
            if (!other ? !cJSON_IsNull(item) : !szft_json_equivalent(item, other)) return false;
        }
        cJSON_ArrayForEach(item, b) {
            if (!cJSON_GetObjectItemCaseSensitive(a, item->string) && !cJSON_IsNull(item)) return false;
        }
        return true;
    }
    if (cJSON_IsArray(a) && cJSON_IsArray(b)) {
        const cJSON *x = a->child, *y = b->child;
        for (; x && y; x = x->next, y = y->next)
            if (!szft_json_equivalent(x, y)) return false;
        return !x && !y;
    }
    return cJSON_Compare(a, b, 1);
}

szfriends_fake_helper *szft_fake_start(const char *state_dir, int major, int minor, int min_major,
                                       uint64_t build, bool take_lock) {
    szfriends_fake_helper_config config;
    szfriends_fake_helper *fake = NULL;
    szfriends_status status;
    memset(&config, 0, sizeof config);
    config.state_dir = state_dir;
    config.fixtures_dir = szft_fixtures;
    config.protocol_major = major;
    config.protocol_minor = minor;
    config.protocol_min_major = min_major;
    config.build_number = build;
    config.take_lock = take_lock;
    status = szfriends_fake_helper_start(&config, &fake);
    EXPECT(status == SZFRIENDS_OK, "fake helper start: %s", szfriends_status_name(status));
    return fake;
}

static void on_frame(void *context, const char *json, size_t length) {
    szft_client *harness = (szft_client *)context;
    char *copy = (char *)malloc(length + 1);
    char **grown = (char **)realloc(harness->frames, (harness->frame_count + 1) * sizeof *grown);
    memcpy(copy, json, length);
    copy[length] = '\0';
    harness->frames = grown;
    harness->frames[harness->frame_count++] = copy;
}

static void on_state(void *context, szfriends_connection_state state) {
    szft_client *harness = (szft_client *)context;
    if (harness->state_count < sizeof harness->states / sizeof harness->states[0])
        harness->states[harness->state_count++] = (int)state;
    if (state == SZFRIENDS_CONNECTION_READY && harness->resubscribe_view) {
        /* PROTOCOL.md § Lifecycle: subscriptions never survive a reconnect; the host subscribes again here. */
        szfriends_status status = szfriends_client_send_intent(
            harness->client, szfriends_intent_subscribe(harness->resubscribe_view, NULL), harness->resubscribe_id,
            sizeof harness->resubscribe_id);
        EXPECT(status == SZFRIENDS_OK, "subscribe from on_state: %s", szfriends_status_name(status));
    }
}

szft_client *szft_client_new(const szft_client_options *options) {
    static const char *const capabilities[] = {"attach.items", "drop.files", "drop.tabs", "search.export"};
    static const char *const formats[] = {"pdf", "epub", "xps", "cbz", "md", "markdown"};
    szft_client *harness = (szft_client *)calloc(1, sizeof *harness);
    szfriends_client_config config;
    memset(&config, 0, sizeof config);
    config.state_dir = options->state_dir;
    config.helper_path = options->helper_path;
    config.helper_version = options->helper_version;
    config.helper_build_number = options->helper_build;
    config.app_id = "com.intuition.shenzhenpdf";
    config.app_name = "ShenzhenPDF";
    config.app_version = "26.10.12";
    config.toolkit = "appkit";
    config.reveal_in = "Finder";
    config.locale = "en-GB";
    config.capabilities = capabilities;
    config.capability_count = 4;
    config.open_formats = formats;
    config.open_format_count = 6;
    config.on_frame = on_frame;
    config.on_state = on_state;
    config.context = harness;
    harness->client = szfriends_client_new(&config);
    EXPECT(harness->client != NULL, "szfriends_client_new");
    return harness;
}

void szft_client_free(szft_client *harness) {
    size_t i;
    if (!harness) return;
    szfriends_client_free(harness->client);
    for (i = 0; i < harness->frame_count; i++) free(harness->frames[i]);
    free(harness->frames);
    free(harness);
}

bool szft_pump(szft_client *harness, bool (*done)(szft_client *, void *), void *argument, int timeout_ms) {
    uint64_t deadline = szfriends_monotonic_ms() + (uint64_t)timeout_ms;
    for (;;) {
        uint64_t now = szfriends_monotonic_ms();
        int64_t next;
        int wait;
        int fd;
        if (done && done(harness, argument)) return true;
        if (now >= deadline) return done ? done(harness, argument) : true;
        next = szfriends_client_next_tick_ms(harness->client, now);
        wait = (int)(deadline - now);
        if (next >= 0 && next < wait) wait = (int)next;
        if (wait > 20) wait = 20;
        fd = szfriends_client_fd(harness->client);
        if (fd >= 0) {
            struct pollfd readable = {fd, POLLIN, 0};
            if (poll(&readable, 1, wait) > 0) {
                szfriends_status status = szfriends_client_on_readable(harness->client);
                if (status != SZFRIENDS_OK) harness->last_error = status;
            }
        } else if (wait > 0) {
            szft_sleep_ms(wait);
        }
        szfriends_client_tick(harness->client, szfriends_monotonic_ms());
    }
}

static bool state_is(szft_client *harness, void *argument) {
    return szfriends_client_state(harness->client) == *(szfriends_connection_state *)argument;
}

bool szft_wait_state(szft_client *harness, szfriends_connection_state state, int timeout_ms) {
    return szft_pump(harness, state_is, &state, timeout_ms);
}

long szft_find_frame(szft_client *harness, size_t from, const char *type, const char *re) {
    size_t i;
    for (i = from; i < harness->frame_count; i++) {
        cJSON *frame = cJSON_Parse(harness->frames[i]);
        const cJSON *frame_type = cJSON_GetObjectItemCaseSensitive(frame, "type");
        const cJSON *frame_re = cJSON_GetObjectItemCaseSensitive(frame, "re");
        bool match = cJSON_IsString(frame_type) && strcmp(frame_type->valuestring, type) == 0 &&
                     (!re || (cJSON_IsString(frame_re) && strcmp(frame_re->valuestring, re) == 0));
        cJSON_Delete(frame);
        if (match) return (long)i;
    }
    return -1;
}

typedef struct frame_query {
    size_t from;
    const char *type, *re;
    long index;
} frame_query;

static bool frame_arrived(szft_client *harness, void *argument) {
    frame_query *query = (frame_query *)argument;
    query->index = szft_find_frame(harness, query->from, query->type, query->re);
    return query->index >= 0;
}

bool szft_wait_frame(szft_client *harness, size_t from, const char *type, const char *re, int timeout_ms,
                     long *index) {
    frame_query query;
    bool found;
    query.from = from;
    query.type = type;
    query.re = re;
    query.index = -1;
    found = szft_pump(harness, frame_arrived, &query, timeout_ms);
    if (index) *index = query.index;
    return found;
}

cJSON *szft_frame_json(szft_client *harness, long index) {
    if (index < 0 || (size_t)index >= harness->frame_count) return NULL;
    return cJSON_Parse(harness->frames[index]);
}

bool szft_saw_state(szft_client *harness, size_t from, szfriends_connection_state state) {
    size_t i;
    for (i = from; i < harness->state_count; i++)
        if (harness->states[i] == (int)state) return true;
    return false;
}

static const char *absolute(const char *path) {
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) {
        fprintf(stderr, "cannot resolve %s\n", path);
        exit(2);
    }
    return strdup(resolved);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <fixtures dir> <szfriends-fake-helper>\n", argv[0]);
        return 2;
    }
    szft_fixtures = absolute(argv[1]);
    szft_fake_exe = absolute(argv[2]);
    /* Helpers spawned by these tests must never outlive them for long, and must find the fixtures. */
    setenv("SZFRIENDS_FAKE_FIXTURES", szft_fixtures, 1);
    setenv("SZFRIENDS_FAKE_IDLE_EXIT_MS", "500", 1);
    setenv("SZFRIENDS_FAKE_FIRST_CLIENT_MS", "3000", 1);
    unsetenv("SZFRIENDS_FAKE_BUILD");

    szft_run_pure_tests();
    szft_run_intent_tests();
    szft_run_fake_tests();
    szft_run_fake_script_tests();
    szft_run_flow_tests();
    szft_run_spawn_tests();
    szft_run_signing_tests();
    if (szft_failures) {
        fprintf(stderr, "SZFriendsClientTests: %d failures\n", szft_failures);
        return 1;
    }
    printf("SZFriendsClientTests passed\n");
    return 0;
}
