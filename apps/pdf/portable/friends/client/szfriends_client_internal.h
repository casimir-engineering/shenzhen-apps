/* Shenzhen Friends client library internals, shared by its source files and by the fake helper in client/fake/.
 * Not a public header: hosts use szfriends_client.h only. */

#ifndef SZFRIENDS_CLIENT_INTERNAL_H
#define SZFRIENDS_CLIENT_INTERNAL_H

#include "client/szfriends_client.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/un.h>

/* Reconnection schedule (PROTOCOL.md § Lifecycle): first retry 50 ms, doubling, capped at 2 s, plus up to a
 * quarter of the base as jitter so a crowd of windows does not reconnect in lockstep; never above the cap. */
#define SZFRIENDS_RETRY_FIRST_MS 50
#define SZFRIENDS_RETRY_CAP_MS 2000
/* A helper that accepted but never answers hello is stuck; drop it and retry rather than wait forever. */
#define SZFRIENDS_HANDSHAKE_TIMEOUT_MS 10000
/* PROTOCOL.md § Lifecycle, handover: a client whose helper is older than the successor waits this long for the
 * successor to appear before spawning its own. */
#define SZFRIENDS_HANDOVER_WAIT_MS 10000
/* No common major and no handover: the running helper is newer than ours. Retry quietly, because the newer app
 * may quit and leave room for our helper. */
#define SZFRIENDS_INCOMPATIBLE_RETRY_MS 30000
/* Spawning again while a just-spawned helper is still starting only creates duplicates that exit at once. */
#define SZFRIENDS_SPAWN_THROTTLE_MS 500
/* While output waits for socket space, the host is asked to tick this often (it does not watch writability). */
#define SZFRIENDS_FLUSH_TICK_MS 5
/* Unwritten output beyond this means the helper stopped reading; refuse more rather than queue it. */
#define SZFRIENDS_MAX_PENDING_OUTPUT ((size_t)16 * 1024 * 1024)

struct szfriends_client {
    /* Copied from the config. */
    char *state_dir;
    char *helper_path;
    char *helper_version;
    uint64_t helper_build_number;
    int helper_major, helper_minor;
    char *app_id, *app_name, *app_version, *toolkit, *reveal_in, *locale, *url_scheme;
    char **capabilities;
    size_t capability_count;
    char **open_formats;
    size_t open_format_count;
    void (*on_frame)(void *context, const char *json, size_t length);
    void (*on_state)(void *context, szfriends_connection_state state);
    void *context;
    char *incompatible_text; /* the INCOMPATIBLE line naming config.app_name (szfriends_client_state_text) */

    char socket_path[SZFRIENDS_PATH_CAP];
    bool socket_path_ready;

    szfriends_connection_state state;
    bool started;
    int fd;
    bool handshaking;
    szfriends_line_reader *reader;
    char *out;
    size_t out_offset, out_length, out_capacity;

    uint64_t next_id;
    uint64_t hello_id;
    uint64_t *pending; /* ids of intents waiting for their reply */
    size_t pending_count, pending_capacity;
    int negotiated_major, negotiated_minor;

    bool ever_ready;
    bool incompatible;         /* INCOMPATIBLE reported; quiet retries keep it until a welcome */
    bool unsupported_seen;     /* protocol_unsupported on this connection, no handover scheduled */
    bool spawn_now;            /* our embedded helper is the successor of a handover: spawn at once */
    bool retry_scheduled;
    uint64_t retry_at;
    int64_t goodbye_delay_ms;  /* chosen by a goodbye for the next retry (reset: 0); -1 means backoff */
    uint64_t backoff_ms;
    uint64_t handshake_deadline;
    uint64_t handover_wait_until;
    bool spawned_before;
    uint64_t last_spawn_at;

    /* Host clock estimate: host_base was the host's now_ms when mono_base was CLOCK_MONOTONIC. */
    uint64_t host_base, mono_base;
    /* Bumped whenever the connection is opened or closed, so code after a callback can tell the callback
     * stopped or restarted the client and must not touch the old connection. */
    unsigned generation;
    uint32_t random_state;
};

/* Socket helpers (szfriends_socket.c). */
int szfriends_socket_prepare(int fd);                /* non-blocking, close-on-exec, no SIGPIPE; 0 on success */
int szfriends_socket_open_connected(const char *path, struct sockaddr_un *address, szfriends_status *status);
bool szfriends_socket_peer_is_us(int fd);
ssize_t szfriends_socket_write(int fd, const void *bytes, size_t length); /* never raises SIGPIPE */
szfriends_status szfriends_probe_socket(const char *socket_path);

/* Signing policy (szfriends_signing.c): true when the helper on `fd` may be trusted under the policy the host set,
 * which in a team-signed app means its audit token passed the host's verifier. Called after the uid check. */
bool szfriends_peer_signature_allowed(int fd);

/* Spawning (szfriends_spawn.c). */
szfriends_status szfriends_spawn_process(const char *helper_path, const char *state_dir, pid_t *pid_out);
szfriends_status szfriends_spawn_detached(const char *helper_path, const char *state_dir);

/* Client internals split across szfriends_client.c and szfriends_client_io.c. */
uint64_t szfriends_client_now(const szfriends_client *client);
void szfriends_client_set_state(szfriends_client *client, szfriends_connection_state state);
void szfriends_client_disconnect(szfriends_client *client, bool deliver_replies);
void szfriends_client_schedule_retry(szfriends_client *client, uint64_t delay_ms);
szfriends_status szfriends_client_send_hello(szfriends_client *client);
szfriends_status szfriends_client_flush(szfriends_client *client);
szfriends_status szfriends_client_enqueue(szfriends_client *client, const char *frame, size_t length);
void szfriends_client_fail_pending(szfriends_client *client, bool deliver);
void szfriends_client_handle_frame(szfriends_client *client, const char *line, size_t length);
uint32_t szfriends_client_random(szfriends_client *client);

/* Version negotiation (PROTOCOL.md § Version negotiation), shared with the fake helper so both apply the same
 * rule: highest major both accept, then the lower minor. false when there is none. */
bool szfriends_negotiate(int helper_major, int helper_minor, int helper_min_major, int client_major,
                         int client_minor, int client_min_major, int *major_out, int *minor_out);

#endif /* SZFRIENDS_CLIENT_INTERNAL_H */
