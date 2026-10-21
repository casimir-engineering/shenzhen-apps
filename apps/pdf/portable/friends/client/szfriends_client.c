/* Shenzhen Friends client library: the connection's life, from start to stop, and its timers.
 *
 * Everything runs on the host's thread, driven by szfriends_client_on_readable() and szfriends_client_tick();
 * the library starts no thread except the detached spawner (szfriends_spawn.c). Frames, hello and sending live
 * in szfriends_client_io.c. */

#define _DARWIN_C_SOURCE 1

#include "client/szfriends_client_internal.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

uint64_t szfriends_monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u;
}

const char *szfriends_connection_state_text(szfriends_connection_state state) {
    /* Read by the person who opened Friends while it is not answering. They wonder whether it works and whether
     * they must do something; only INCOMPATIBLE asks anything of them. */
    switch (state) {
    case SZFRIENDS_CONNECTION_CONNECTING:
    case SZFRIENDS_CONNECTION_HANDSHAKING: return "Starting Friends…";
    case SZFRIENDS_CONNECTION_WAITING: return "Reconnecting to Friends…";
    case SZFRIENDS_CONNECTION_INCOMPATIBLE:
        /* Only reached when the running helper is newer than this app's (an older one would hand over), so
         * updating this app is the true remedy. szfriends_client_state_text() names the app. */
        return "Another app on this computer uses a newer version of Friends. Update this app to use Friends.";
    case SZFRIENDS_CONNECTION_IDLE:
    case SZFRIENDS_CONNECTION_READY: return "";
    }
    return "";
}

static char *copy_or_null(const char *value, bool *failed) {
    char *copy;
    if (!value) return NULL;
    copy = strdup(value);
    if (!copy) *failed = true;
    return copy;
}

static char **copy_list(const char *const *values, size_t count, bool *failed) {
    char **copy;
    size_t i;
    if (!values || count == 0) return NULL;
    copy = (char **)calloc(count, sizeof *copy);
    if (!copy) {
        *failed = true;
        return NULL;
    }
    for (i = 0; i < count; i++) copy[i] = copy_or_null(values[i] ? values[i] : "", failed);
    return copy;
}

static void free_list(char **values, size_t count) {
    size_t i;
    if (!values) return;
    for (i = 0; i < count; i++) free(values[i]);
    free(values);
}

szfriends_client *szfriends_client_new(const szfriends_client_config *config) {
    szfriends_client *client;
    bool failed = false;
    if (!config || !config->app_id || !config->app_name || !config->app_version || !config->toolkit ||
        !config->reveal_in)
        return NULL;
    client = (szfriends_client *)calloc(1, sizeof *client);
    if (!client) return NULL;
    client->fd = -1;
    client->state_dir = copy_or_null(config->state_dir, &failed);
    client->helper_path = copy_or_null(config->helper_path, &failed);
    client->helper_version = copy_or_null(config->helper_version, &failed);
    client->helper_build_number = config->helper_build_number;
    client->helper_major = config->helper_protocol_major ? config->helper_protocol_major : SZFRIENDS_PROTOCOL_MAJOR;
    client->helper_minor = config->helper_protocol_major ? config->helper_protocol_minor : SZFRIENDS_PROTOCOL_MINOR;
    client->app_id = copy_or_null(config->app_id, &failed);
    client->app_name = copy_or_null(config->app_name, &failed);
    client->app_version = copy_or_null(config->app_version, &failed);
    client->toolkit = copy_or_null(config->toolkit, &failed);
    client->reveal_in = copy_or_null(config->reveal_in, &failed);
    client->locale = copy_or_null(config->locale ? config->locale : "en", &failed);
    client->url_scheme = copy_or_null(config->url_scheme, &failed);
    client->capabilities = copy_list(config->capabilities, config->capability_count, &failed);
    client->capability_count = client->capabilities ? config->capability_count : 0;
    client->open_formats = copy_list(config->open_formats, config->open_format_count, &failed);
    client->open_format_count = client->open_formats ? config->open_format_count : 0;
    client->on_frame = config->on_frame;
    client->on_state = config->on_state;
    client->context = config->context;
    client->next_id = 1;
    client->goodbye_delay_ms = -1;
    client->backoff_ms = SZFRIENDS_RETRY_FIRST_MS;
    client->mono_base = szfriends_monotonic_ms();
    client->host_base = client->mono_base; /* until told otherwise, assume the host passes CLOCK_MONOTONIC */
    client->random_state = (uint32_t)(client->mono_base ^ ((uint64_t)getpid() << 16) ^ (uintptr_t)client);
    if (!client->random_state) client->random_state = 0x9e3779b9u;
    client->reader = szfriends_line_reader_new(SZFRIENDS_MAX_FRAME_BYTES);
    if (client->app_name) {
        /* The person reading it has to update something, so say which app: "this app" makes them guess when both
         * ShenzhenPDF and Shenzhen Files are open. */
        static const char format[] = "Another app on this computer uses a newer version of Friends. Update %s to "
                                     "use Friends.";
        size_t length = sizeof format + strlen(client->app_name);
        client->incompatible_text = (char *)malloc(length);
        if (client->incompatible_text) snprintf(client->incompatible_text, length, format, client->app_name);
        else failed = true;
    }
    if (failed || !client->reader) {
        szfriends_client_free(client);
        return NULL;
    }
    return client;
}

void szfriends_client_free(szfriends_client *client) {
    if (!client) return;
    if (client->fd >= 0) close(client->fd);
    szfriends_line_reader_free(client->reader);
    free(client->out);
    free(client->pending);
    free(client->state_dir);
    free(client->helper_path);
    free(client->helper_version);
    free(client->app_id);
    free(client->app_name);
    free(client->incompatible_text);
    free(client->app_version);
    free(client->toolkit);
    free(client->reveal_in);
    free(client->locale);
    free(client->url_scheme);
    free_list(client->capabilities, client->capability_count);
    free_list(client->open_formats, client->open_format_count);
    free(client);
}

uint32_t szfriends_client_random(szfriends_client *client) {
#if defined(__APPLE__)
    (void)client;
    return arc4random();
#else
    /* xorshift32: jitter only needs to differ between processes, not to be unpredictable. */
    uint32_t x = client->random_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    client->random_state = x;
    return x;
#endif
}

uint64_t szfriends_client_now(const szfriends_client *client) {
    return client->host_base + (szfriends_monotonic_ms() - client->mono_base);
}

/* Takes the host's clock as the reference. When it disagrees with the estimate by more than a second the host
 * uses a different clock than assumed (its first tick), so pending deadlines move into its domain. */
static void observe_host_clock(szfriends_client *client, uint64_t now_ms) {
    uint64_t estimate = szfriends_client_now(client);
    int64_t shift = (int64_t)(now_ms - estimate);
    if (shift > 1000 || shift < -1000) {
        if (client->retry_scheduled) client->retry_at += (uint64_t)shift;
        if (client->handshake_deadline) client->handshake_deadline += (uint64_t)shift;
        if (client->handover_wait_until) client->handover_wait_until += (uint64_t)shift;
        if (client->spawned_before) client->last_spawn_at += (uint64_t)shift;
    }
    client->host_base = now_ms;
    client->mono_base = szfriends_monotonic_ms();
}

void szfriends_client_set_state(szfriends_client *client, szfriends_connection_state state) {
    /* While INCOMPATIBLE, quiet retries handshake again without telling the views, so the status line does not
     * flicker every 30 s; only success (READY) or a vanished helper ends it. */
    if (client->incompatible && state != SZFRIENDS_CONNECTION_READY && state != SZFRIENDS_CONNECTION_IDLE &&
        state != SZFRIENDS_CONNECTION_INCOMPATIBLE && client->state == SZFRIENDS_CONNECTION_INCOMPATIBLE)
        return;
    if (state == SZFRIENDS_CONNECTION_READY || state == SZFRIENDS_CONNECTION_IDLE) client->incompatible = false;
    if (state == SZFRIENDS_CONNECTION_INCOMPATIBLE) client->incompatible = true;
    if (client->state == state) return;
    client->state = state;
    if (client->on_state) client->on_state(client->context, state);
}

void szfriends_client_schedule_retry(szfriends_client *client, uint64_t delay_ms) {
    client->retry_scheduled = true;
    client->retry_at = szfriends_client_now(client) + delay_ms;
}

/* The next backoff delay: base plus up to a quarter of it, never above the cap; the base then doubles. */
static uint64_t next_backoff(szfriends_client *client) {
    uint64_t base = client->backoff_ms;
    uint64_t delay = base + (base >= 4 ? szfriends_client_random(client) % (base / 4 + 1) : 0);
    if (delay > SZFRIENDS_RETRY_CAP_MS) delay = SZFRIENDS_RETRY_CAP_MS;
    client->backoff_ms = base * 2 > SZFRIENDS_RETRY_CAP_MS ? SZFRIENDS_RETRY_CAP_MS : base * 2;
    return delay;
}

static void maybe_spawn(szfriends_client *client) {
    uint64_t now = szfriends_client_now(client);
    if (!client->helper_path) return;
    if (!client->spawn_now) {
        if (client->handover_wait_until && now < client->handover_wait_until) return;
        if (client->spawned_before && now - client->last_spawn_at < SZFRIENDS_SPAWN_THROTTLE_MS) return;
    }
    if (szfriends_spawn_detached(client->helper_path, client->state_dir) == SZFRIENDS_OK) {
        client->spawned_before = true;
        client->last_spawn_at = now;
        client->spawn_now = false;
    }
}

/* One connection attempt. Returns a status worth logging; reschedules itself on failure. */
static szfriends_status attempt_connect(szfriends_client *client) {
    struct sockaddr_un address;
    szfriends_status status;
    int fd;

    client->retry_scheduled = false;
    if (!client->socket_path_ready) {
        char state[SZFRIENDS_PATH_CAP];
        status = SZFRIENDS_OK;
        if (!client->state_dir)
            status = szfriends_default_state_dir(state, sizeof state);
        else if (strlen(client->state_dir) >= sizeof state)
            status = SZFRIENDS_ERR_PATH_TOO_LONG;
        else
            memcpy(state, client->state_dir, strlen(client->state_dir) + 1);
        if (status == SZFRIENDS_OK)
            status = szfriends_socket_path(state, client->socket_path, sizeof client->socket_path, NULL);
        if (status != SZFRIENDS_OK) {
            szfriends_client_schedule_retry(client, next_backoff(client));
            return status;
        }
        client->socket_path_ready = true;
    }
    if (!client->incompatible)
        szfriends_client_set_state(client, client->ever_ready ? SZFRIENDS_CONNECTION_WAITING
                                                              : SZFRIENDS_CONNECTION_CONNECTING);
    status = szfriends_socket_directory_check(client->socket_path, false);
    fd = -1;
    if (status == SZFRIENDS_OK) fd = szfriends_socket_open_connected(client->socket_path, &address, &status);
    if (fd < 0) {
        if (status == SZFRIENDS_ERR_NO_HELPER) {
            /* The newer helper we were incompatible with is gone: start ours, visibly. */
            if (client->incompatible) {
                client->incompatible = false;
                szfriends_client_set_state(client, client->ever_ready ? SZFRIENDS_CONNECTION_WAITING
                                                                      : SZFRIENDS_CONNECTION_CONNECTING);
            }
            maybe_spawn(client);
        }
        szfriends_client_schedule_retry(client, client->incompatible ? SZFRIENDS_INCOMPATIBLE_RETRY_MS
                                                                     : next_backoff(client));
        return status == SZFRIENDS_ERR_NO_HELPER ? SZFRIENDS_OK : status;
    }
    client->fd = fd;
    client->generation++;
    client->handshaking = true;
    client->unsupported_seen = false;
    client->handshake_deadline = szfriends_client_now(client) + SZFRIENDS_HANDSHAKE_TIMEOUT_MS;
    szfriends_client_set_state(client, SZFRIENDS_CONNECTION_HANDSHAKING);
    if (client->fd < 0) return SZFRIENDS_OK; /* the state callback stopped us */
    status = szfriends_client_send_hello(client);
    if (status != SZFRIENDS_OK) {
        szfriends_client_disconnect(client, false);
        return status;
    }
    return SZFRIENDS_OK;
}

szfriends_status szfriends_client_start(szfriends_client *client) {
    if (!client) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    if (client->started) return SZFRIENDS_OK;
    client->started = true;
    client->backoff_ms = SZFRIENDS_RETRY_FIRST_MS;
    return attempt_connect(client);
}

/* Closes the connection and schedules the next attempt. Intents still waiting get synthesized replies when
 * `deliver_replies` is set (a drop the host did not ask for). */
void szfriends_client_disconnect(szfriends_client *client, bool deliver_replies) {
    szfriends_connection_state next;
    uint64_t delay;
    if (client->fd >= 0) close(client->fd);
    client->fd = -1;
    client->generation++;
    client->handshaking = false;
    client->handshake_deadline = 0;
    client->out_offset = client->out_length = 0;
    client->negotiated_major = client->negotiated_minor = 0;
    szfriends_line_reader_free(client->reader);
    client->reader = szfriends_line_reader_new(SZFRIENDS_MAX_FRAME_BYTES);
    if (!client->started) {
        szfriends_client_fail_pending(client, false);
        return;
    }
    if (client->unsupported_seen) {
        client->unsupported_seen = false;
        next = SZFRIENDS_CONNECTION_INCOMPATIBLE;
        delay = SZFRIENDS_INCOMPATIBLE_RETRY_MS;
    } else {
        next = client->ever_ready ? SZFRIENDS_CONNECTION_WAITING : SZFRIENDS_CONNECTION_CONNECTING;
        delay = client->goodbye_delay_ms >= 0 ? (uint64_t)client->goodbye_delay_ms : next_backoff(client);
    }
    client->goodbye_delay_ms = -1;
    szfriends_client_schedule_retry(client, delay);
    {
        unsigned generation = client->generation;
        szfriends_client_set_state(client, next);
        if (generation != client->generation || !client->started) return;
    }
    szfriends_client_fail_pending(client, deliver_replies);
}

szfriends_status szfriends_client_stop(szfriends_client *client, bool friends_disabled) {
    if (!client) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    if (client->fd >= 0 && client->state == SZFRIENDS_CONNECTION_READY && friends_disabled) {
        char id[24];
        if (szfriends_client_send(client, "disable", NULL, id, sizeof id) == SZFRIENDS_OK) {
            /* Best effort: give the frame a short chance to leave. If it cannot, the helper still exits after its
             * grace period because this client is gone. */
            uint64_t deadline = szfriends_monotonic_ms() + 200;
            while (client->out_offset < client->out_length && szfriends_monotonic_ms() < deadline) {
                if (szfriends_client_flush(client) != SZFRIENDS_OK) break;
                if (client->out_offset < client->out_length) usleep(2000);
            }
        }
    }
    client->started = false;
    client->retry_scheduled = false;
    client->goodbye_delay_ms = -1;
    client->spawn_now = false;
    client->handover_wait_until = 0;
    client->incompatible = false;
    client->ever_ready = false;
    if (client->fd >= 0) szfriends_client_disconnect(client, false);
    szfriends_client_fail_pending(client, false);
    szfriends_client_set_state(client, SZFRIENDS_CONNECTION_IDLE);
    return SZFRIENDS_OK;
}

szfriends_connection_state szfriends_client_state(const szfriends_client *client) {
    return client ? client->state : SZFRIENDS_CONNECTION_IDLE;
}

const char *szfriends_client_state_text(const szfriends_client *client) {
    if (!client) return "";
    if (client->state == SZFRIENDS_CONNECTION_INCOMPATIBLE && client->incompatible_text)
        return client->incompatible_text;
    return szfriends_connection_state_text(client->state);
}

int szfriends_client_fd(const szfriends_client *client) {
    return client ? client->fd : -1;
}

void szfriends_client_protocol(const szfriends_client *client, int *major, int *minor) {
    bool ready = client && client->state == SZFRIENDS_CONNECTION_READY;
    if (major) *major = ready ? client->negotiated_major : 0;
    if (minor) *minor = ready ? client->negotiated_minor : 0;
}

void szfriends_client_tick(szfriends_client *client, uint64_t now_ms) {
    if (!client) return;
    observe_host_clock(client, now_ms);
    if (!client->started) return;
    if (client->fd >= 0) {
        if (client->out_offset < client->out_length && szfriends_client_flush(client) != SZFRIENDS_OK) {
            szfriends_client_disconnect(client, true);
            return;
        }
        if (client->handshaking && client->handshake_deadline && now_ms >= client->handshake_deadline)
            szfriends_client_disconnect(client, true);
        return;
    }
    if (client->retry_scheduled && now_ms >= client->retry_at) attempt_connect(client);
}

int64_t szfriends_client_next_tick_ms(const szfriends_client *client, uint64_t now_ms) {
    int64_t best = -1;
    if (!client || !client->started) return -1;
#define SZF_CONSIDER(deadline)                                                       \
    do {                                                                             \
        int64_t wait = (deadline) > now_ms ? (int64_t)((deadline) - now_ms) : 0;      \
        if (wait > SZFRIENDS_INCOMPATIBLE_RETRY_MS) wait = SZFRIENDS_INCOMPATIBLE_RETRY_MS; \
        if (best < 0 || wait < best) best = wait;                                    \
    } while (0)
    if (client->fd >= 0) {
        if (client->out_offset < client->out_length) SZF_CONSIDER(now_ms + SZFRIENDS_FLUSH_TICK_MS);
        if (client->handshaking && client->handshake_deadline) SZF_CONSIDER(client->handshake_deadline);
    } else if (client->retry_scheduled) {
        SZF_CONSIDER(client->retry_at);
    }
#undef SZF_CONSIDER
    return best;
}
