/* szfriends-fake-helper: the fake helper as a process, for view development and spawn tests.
 *
 * Behaves like the real helper where a client can tell: takes helper.lock and exits 0 when another helper holds
 * it, serves the fixtures on the state directory's socket, exits 10 s after its last client leaves or 30 s
 * after start when no client ever came, and exits after handing over. The client library can spawn it in place
 * of the real helper: it needs no arguments, reading SZFRIENDS_STATE_DIR like the helper and the rest from
 * SZFRIENDS_FAKE_* variables.
 *
 * Options (each also from the environment):
 *   --state-dir DIR      SZFRIENDS_STATE_DIR        default: the Friends state directory
 *   --fixtures DIR       SZFRIENDS_FAKE_FIXTURES    required: portable/friends/fixtures
 *   --build N            SZFRIENDS_FAKE_BUILD       welcome.helper.build_number
 *   --version V          SZFRIENDS_FAKE_VERSION     welcome.helper.version
 *   --protocol M.m       SZFRIENDS_FAKE_PROTOCOL    protocol spoken (default this library's)
 *   --min-major N        SZFRIENDS_FAKE_MIN_MAJOR
 *   --idle-exit-ms N     SZFRIENDS_FAKE_IDLE_EXIT_MS     default 10000
 *   --first-client-ms N  SZFRIENDS_FAKE_FIRST_CLIENT_MS  default 30000
 *
 * Scripting commands on stdin, one per line: "view <view> <fixture file>", "data <view> <json>",
 * "reply <intent> <json>" ("-" restores the fixture), "goodbye <json>", "drop", "quit". */

#define _DARWIN_C_SOURCE 1

#include "client/fake/szfriends_fake_helper.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t terminate_requested;

static void on_terminate(int signal_number) {
    (void)signal_number;
    terminate_requested = 1;
}

static const char *option(int argc, char **argv, const char *flag, const char *variable) {
    int i;
    for (i = 1; i + 1 < argc; i++)
        if (strcmp(argv[i], flag) == 0) return argv[i + 1];
    return getenv(variable);
}

static void run_command(szfriends_fake_helper *fake, char *line, bool *quit) {
    char *verb = line, *name, *rest;
    size_t length = strlen(line);
    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) line[--length] = '\0';
    name = strchr(verb, ' ');
    if (name) *name++ = '\0';
    rest = name ? strchr(name, ' ') : NULL;
    if (rest) *rest++ = '\0';
    if (strcmp(verb, "quit") == 0) *quit = true;
    else if (strcmp(verb, "drop") == 0) szfriends_fake_helper_drop_clients(fake);
    else if (strcmp(verb, "goodbye") == 0 && name) {
        if (rest) rest[-1] = ' '; /* the JSON may contain spaces: rejoin it */
        szfriends_fake_helper_send_goodbye(fake, name);
    } else if (strcmp(verb, "view") == 0 && name && rest) szfriends_fake_helper_set_view_fixture(fake, name, rest);
    else if (strcmp(verb, "data") == 0 && name && rest) szfriends_fake_helper_set_view_data(fake, name, rest);
    else if (strcmp(verb, "reply") == 0 && name && rest)
        szfriends_fake_helper_set_reply(fake, name, strcmp(rest, "-") == 0 ? NULL : rest);
    else fprintf(stderr, "szfriends-fake-helper: unknown command '%s'\n", verb);
}

int main(int argc, char **argv) {
    szfriends_fake_helper_config config;
    szfriends_fake_helper *fake = NULL;
    char state[SZFRIENDS_PATH_CAP];
    const char *value;
    long idle_exit_ms, first_client_ms;
    uint64_t started;
    char line[65536];
    size_t line_length = 0;
    bool stdin_open = true, quit = false;
    szfriends_status status;

    memset(&config, 0, sizeof config);
    value = option(argc, argv, "--state-dir", SZFRIENDS_ENV_STATE_DIR);
    if (value && value[0] == '/') {
        snprintf(state, sizeof state, "%s", value);
    } else if (szfriends_default_state_dir(state, sizeof state) != SZFRIENDS_OK) {
        fprintf(stderr, "szfriends-fake-helper: no state directory\n");
        return 2;
    }
    config.state_dir = state;
    config.fixtures_dir = option(argc, argv, "--fixtures", "SZFRIENDS_FAKE_FIXTURES");
    if (!config.fixtures_dir) {
        fprintf(stderr, "usage: %s --fixtures <portable/friends/fixtures> [--state-dir DIR] ...\n", argv[0]);
        return 2;
    }
    value = option(argc, argv, "--build", "SZFRIENDS_FAKE_BUILD");
    if (value) config.build_number = strtoull(value, NULL, 10);
    config.version = option(argc, argv, "--version", "SZFRIENDS_FAKE_VERSION");
    value = option(argc, argv, "--protocol", "SZFRIENDS_FAKE_PROTOCOL");
    if (value && sscanf(value, "%d.%d", &config.protocol_major, &config.protocol_minor) != 2)
        config.protocol_major = config.protocol_minor = 0;
    value = option(argc, argv, "--min-major", "SZFRIENDS_FAKE_MIN_MAJOR");
    if (value) config.protocol_min_major = atoi(value);
    value = option(argc, argv, "--idle-exit-ms", "SZFRIENDS_FAKE_IDLE_EXIT_MS");
    idle_exit_ms = value ? atol(value) : 10000;
    value = option(argc, argv, "--first-client-ms", "SZFRIENDS_FAKE_FIRST_CLIENT_MS");
    first_client_ms = value ? atol(value) : 30000;
    config.take_lock = true;

    signal(SIGTERM, on_terminate);
    signal(SIGINT, on_terminate);
    signal(SIGPIPE, SIG_IGN);
    status = szfriends_fake_helper_start(&config, &fake);
    if (status != SZFRIENDS_OK) {
        /* PROTOCOL.md § Transport, single instance: a duplicate exits 0 at once. */
        if (status == SZFRIENDS_ERR_IO && (errno == EWOULDBLOCK || errno == EAGAIN)) return 0;
        fprintf(stderr, "szfriends-fake-helper: cannot start (%s)\n", szfriends_status_name(status));
        return 1;
    }
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK);
    started = szfriends_monotonic_ms();
    while (!quit && !terminate_requested) {
        struct pollfd in = {STDIN_FILENO, POLLIN, 0};
        int64_t idle = szfriends_fake_helper_idle_ms(fake);
        if (idle >= 0 && idle >= idle_exit_ms) break;
        if (idle == -2 && (long)(szfriends_monotonic_ms() - started) >= first_client_ms) break;
        if (szfriends_fake_helper_stepped_aside(fake) && szfriends_fake_helper_client_count(fake) == 0) break;
        if (poll(&in, stdin_open ? 1 : 0, 50) > 0 && (in.revents & (POLLIN | POLLHUP))) {
            ssize_t n = read(STDIN_FILENO, line + line_length, sizeof line - 1 - line_length);
            if (n <= 0) {
                if (n == 0 || (errno != EAGAIN && errno != EINTR)) stdin_open = false;
                continue;
            }
            line_length += (size_t)n;
            line[line_length] = '\0';
            for (;;) {
                char *newline = strchr(line, '\n');
                size_t used;
                if (!newline) break;
                *newline = '\0';
                run_command(fake, line, &quit);
                used = (size_t)(newline - line) + 1;
                memmove(line, line + used, line_length - used + 1);
                line_length -= used;
            }
            if (line_length == sizeof line - 1) line_length = 0; /* an overlong command is dropped */
        }
    }
    szfriends_fake_helper_stop(fake);
    return 0;
}
