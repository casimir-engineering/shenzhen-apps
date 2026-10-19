/* When the fake helper applies scripting: before each client frame, not before each read (szfriends_fake_helper.h).
 *
 * A test that holds replies between two intents expects the second to be held. The fake used to apply scripting only
 * before each read(), so a second intent that reached it in the same read loop as the first was answered anyway; the
 * GTK views' suite hit this every time under AddressSanitizer (wave 6a). Here the timing is exact rather than lucky:
 * a hook on the fake's own thread, run as it is about to handle the first intent, holds replies and writes the second
 * intent behind it, exactly as a test thread calling hold_replies between two sends would. */

#define _DARWIN_C_SOURCE 1

#include "szfriends_test_support.h"

#include "client/fake/szfriends_fake_internal.h"

#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct {
    int fd;
    bool fired;
} szft_hold_race;

/* On the fake's thread, just before it handles ping 2: hold, then write ping 3 behind it. */
static void hold_between_frames(szfriends_fake_helper *fake, const char *line, size_t length, void *data) {
    static const char next[] = "{\"type\":\"ping\",\"id\":\"3\"}\n";
    szft_hold_race *race = (szft_hold_race *)data;
    cJSON *frame;
    const cJSON *id;
    if (race->fired) return;
    frame = cJSON_ParseWithLength(line, length);
    id = cJSON_GetObjectItemCaseSensitive(frame, "id");
    if (cJSON_IsString(id) && strcmp(id->valuestring, "2") == 0) {
        race->fired = true;
        szfriends_fake_helper_hold_replies(fake, true);
        if (write(race->fd, next, sizeof next - 1) != (ssize_t)(sizeof next - 1)) race->fired = false;
    }
    cJSON_Delete(frame);
}

static int connect_raw(const char *state) {
    char path[SZFRIENDS_PATH_CAP];
    struct sockaddr_un address;
    bool fallback = false;
    int fd;
    if (szfriends_socket_path(state, path, sizeof path, &fallback) != SZFRIENDS_OK) return -1;
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, strlen(path) + 1);
    if (connect(fd, (struct sockaddr *)&address, (socklen_t)sizeof address) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool send_line(int fd, const char *line) {
    size_t length = strlen(line);
    return write(fd, line, length) == (ssize_t)length;
}

/* Appends what arrives to `seen` until it holds the reply (or welcome) to `re`; false after `timeout_ms`. */
static bool wait_for_re(int fd, char *seen, size_t capacity, const char *re, int timeout_ms) {
    char needle[48];
    uint64_t deadline = szfriends_monotonic_ms() + (uint64_t)timeout_ms;
    snprintf(needle, sizeof needle, "\"re\":\"%s\"", re);
    while (!strstr(seen, needle)) {
        struct pollfd pfd = {fd, POLLIN, 0};
        uint64_t now = szfriends_monotonic_ms();
        size_t used = strlen(seen);
        ssize_t got;
        if (now >= deadline || used + 1 >= capacity) return false;
        if (poll(&pfd, 1, (int)(deadline - now)) <= 0) continue;
        got = read(fd, seen + used, capacity - used - 1);
        if (got <= 0) return false;
        seen[used + (size_t)got] = '\0';
    }
    return true;
}

/* What came after the welcome, which is long and says nothing about the pings. */
static const char *after_welcome(const char *seen) {
    const char *line_end = strchr(seen, '\n');
    return line_end ? line_end + 1 : seen;
}

static void test_hold_applies_per_frame(void) {
    static const char hello[] =
        "{\"type\":\"hello\",\"id\":\"1\",\"protocol\":{\"major\":1,\"minor\":0,\"min_major\":1},\"client\":{"
        "\"app_id\":\"com.example.fake-tests\",\"app_name\":\"Fake Tests\",\"app_version\":\"1\",\"toolkit\":"
        "\"appkit\",\"reveal_in\":\"Finder\",\"pid\":1},\"embedded_helper\":null,\"capabilities\":[],"
        "\"open_formats\":[],\"locale\":\"en\"}\n";
    char *state = szft_temp_dir("hold");
    szfriends_fake_helper *fake = szft_fake_start(state, 0, 0, 0, 0, false);
    char *seen = (char *)calloc(1, 65536);
    szft_hold_race race = {-1, false};
    if (!fake || !seen) goto done;
    race.fd = connect_raw(state);
    EXPECT(race.fd >= 0, "a raw client connects to the fake");
    if (race.fd < 0) goto done;
    szf_fake_set_frame_hook(fake, hold_between_frames, &race);
    EXPECT(send_line(race.fd, hello) && wait_for_re(race.fd, seen, 65536, "1", 5000), "welcomed: %s", seen);
    EXPECT(send_line(race.fd, "{\"type\":\"ping\",\"id\":\"2\"}\n") && wait_for_re(race.fd, seen, 65536, "2", 5000),
           "ping 2, written before the hold, is answered: %s", after_welcome(seen));
    EXPECT(race.fired, "the hook held replies and wrote ping 3 while the fake was handling ping 2");
    szfriends_fake_helper_hold_replies(fake, false);
    EXPECT(send_line(race.fd, "{\"type\":\"ping\",\"id\":\"4\"}\n") && wait_for_re(race.fd, seen, 65536, "4", 5000),
           "ping 4, written after the release, is answered: %s", after_welcome(seen));
    EXPECT(!strstr(seen, "\"re\":\"3\""), "ping 3 was written after hold_replies(true) returned, so it stays held "
           "even though the fake read it in the same loop as ping 2: %s", after_welcome(seen));
    EXPECT(szfriends_fake_helper_frame_count(fake) == 4, "the fake received hello and pings 2, 3 and 4 (%zu frames)",
           szfriends_fake_helper_frame_count(fake));
done:
    if (fake) szf_fake_set_frame_hook(fake, NULL, NULL);
    if (race.fd >= 0) close(race.fd);
    if (fake) szfriends_fake_helper_stop(fake);
    free(seen);
    szft_remove_tree(state);
    free(state);
}

void szft_run_fake_script_tests(void) {
    test_hold_applies_per_frame();
}
