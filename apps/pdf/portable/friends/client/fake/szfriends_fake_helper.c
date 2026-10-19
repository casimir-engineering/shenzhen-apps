/* Shenzhen Friends fake helper: listening socket, connections, the poll thread and the scripting queue.
 *
 * Binds exactly as the real helper must (PROTOCOL.md § Transport): szfriends_socket_path(), the shared directory
 * check with create, an optional flock on helper.lock, then unlink and bind, and a uid check on every accepted
 * peer. Scripting calls from other threads go through a mutex-protected queue and a wake pipe, so connection
 * state is only ever touched by the fake's own thread. */

#define _DARWIN_C_SOURCE 1

#include "client/fake/szfriends_fake_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static void close_connection(szfriends_fake_helper *fake, int slot) {
    szf_fake_connection *connection = fake->connections[slot];
    if (!connection) return;
    szf_fake_remove_subscriptions(fake, connection->number);
    close(connection->fd);
    szfriends_line_reader_free(connection->reader);
    free(connection->out);
    free(connection);
    fake->connections[slot] = NULL;
    pthread_mutex_lock(&fake->mutex);
    fake->client_count--;
    if (fake->client_count == 0) fake->last_left_ms = szfriends_monotonic_ms();
    pthread_mutex_unlock(&fake->mutex);
}

/* Stops accepting clients and releases the socket and lock, as the old helper does in a handover. */
static void step_aside(szfriends_fake_helper *fake) {
    if (fake->listen_fd >= 0) {
        close(fake->listen_fd);
        fake->listen_fd = -1;
        unlink(fake->socket_path);
    }
    if (fake->lock_fd >= 0) {
        close(fake->lock_fd); /* closing releases the flock */
        fake->lock_fd = -1;
    }
    pthread_mutex_lock(&fake->mutex);
    fake->stepped_aside = true;
    pthread_mutex_unlock(&fake->mutex);
}

static void accept_clients(szfriends_fake_helper *fake) {
    for (;;) {
        int fd = accept(fake->listen_fd, NULL, NULL);
        szf_fake_connection *connection;
        int slot;
        if (fd < 0) return; /* EAGAIN: nobody else waiting */
        if (szfriends_socket_prepare(fd) != 0 || !szfriends_socket_peer_is_us(fd)) {
            close(fd); /* PROTOCOL.md § Transport: another user's process is closed without a word */
            continue;
        }
        for (slot = 0; slot < SZF_FAKE_MAX_CONNECTIONS && fake->connections[slot]; slot++) {
        }
        if (slot == SZF_FAKE_MAX_CONNECTIONS) {
            static const char refusal[] = "{\"type\":\"goodbye\",\"reason\":\"too_many_clients\",\"message\":null,"
                                          "\"successor\":null,\"error\":null}\n";
            szfriends_socket_write(fd, refusal, sizeof refusal - 1);
            close(fd);
            continue;
        }
        connection = (szf_fake_connection *)calloc(1, sizeof *connection);
        if (!connection || !(connection->reader = szfriends_line_reader_new(SZFRIENDS_MAX_FRAME_BYTES))) {
            free(connection);
            close(fd);
            continue;
        }
        connection->fd = fd;
        connection->number = ++fake->next_connection_number;
        fake->connections[slot] = connection;
        pthread_mutex_lock(&fake->mutex);
        fake->client_count++;
        fake->ever_had_client = true;
        pthread_mutex_unlock(&fake->mutex);
    }
}

static void flush_connection(szfriends_fake_helper *fake, int slot) {
    szf_fake_connection *connection = fake->connections[slot];
    while (connection->out_offset < connection->out_length) {
        ssize_t written = szfriends_socket_write(connection->fd, connection->out + connection->out_offset,
                                                 connection->out_length - connection->out_offset);
        if (written > 0) {
            connection->out_offset += (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return;
        } else {
            close_connection(fake, slot);
            return;
        }
    }
    connection->out_offset = connection->out_length = 0;
    if (connection->closing) close_connection(fake, slot);
}

static bool drain_commands(szfriends_fake_helper *fake);

static void read_connection(szfriends_fake_helper *fake, int slot) {
    szf_fake_connection *connection = fake->connections[slot];
    char buffer[65536];
    for (;;) {
        ssize_t n = read(connection->fd, buffer, sizeof buffer);
        const char *line;
        size_t length;
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            close_connection(fake, slot);
            return;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (szfriends_line_reader_push(connection->reader, buffer, (size_t)n) != SZFRIENDS_OK) {
            /* PROTOCOL.md § Framing: goodbye protocol_error frame_too_large, then close. */
            static const char refusal[] =
                "{\"type\":\"goodbye\",\"reason\":\"protocol_error\",\"message\":null,\"successor\":null,"
                "\"error\":{\"code\":\"frame_too_large\",\"message\":null,\"retryable\":false,"
                "\"details\":{\"max_frame_bytes\":8388608}}}\n";
            szf_fake_send_text(connection, refusal, sizeof refusal - 1);
            connection->closing = true;
            return;
        }
        for (;;) {
            /* Scripting per frame, not per read: a command made before the client wrote a frame must apply to that
             * frame, even when the frame came in the same read() as an earlier one or in a later read() of this
             * loop. Draining only before each read let a hold made between two frames miss the second (wave 6a,
             * every time under AddressSanitizer). Every byte in the reader was read before this drain, so the
             * drain sees every command made before those bytes were written. It may close this connection (a
             * scripted drop), which frees the reader, so it runs before the next line is taken from it. */
            if (drain_commands(fake) || !fake->connections[slot]) return;
            if (connection->closing ||
                szfriends_line_reader_next(connection->reader, &line, &length) != SZFRIENDS_OK || !line)
                break;
            szf_fake_handle_line(fake, connection, line, length);
        }
        if (connection->closing) return;
    }
}

static void apply_command(szfriends_fake_helper *fake, szf_fake_command *command) {
    int slot;
    switch (command->kind) {
    case SZF_FAKE_VIEW_DATA: {
        cJSON *data = cJSON_Parse(command->json);
        const cJSON *id = cJSON_GetObjectItemCaseSensitive(data, "conversation_id");
        bool by_conversation = strcmp(command->name, "conversation") == 0 || strcmp(command->name, "details") == 0;
        if (!data) break;
        if (by_conversation) {
            cJSON *array = strcmp(command->name, "conversation") == 0 ? fake->conversations : fake->details;
            cJSON *old = szf_fake_find_by_conversation(array, cJSON_IsString(id) ? id->valuestring : NULL);
            char conversation[72];
            snprintf(conversation, sizeof conversation, "%s", cJSON_IsString(id) ? id->valuestring : "");
            if (old) cJSON_ReplaceItemViaPointer(array, old, data);
            else cJSON_AddItemToArray(array, data);
            szf_fake_publish_view(fake, command->name, conversation);
        } else {
            if (cJSON_GetObjectItemCaseSensitive(fake->views, command->name))
                cJSON_ReplaceItemInObjectCaseSensitive(fake->views, command->name, data);
            else
                cJSON_AddItemToObject(fake->views, command->name, data);
            szf_fake_publish_view(fake, command->name, NULL);
        }
        break;
    }
    case SZF_FAKE_REPLY:
        cJSON_DeleteItemFromObjectCaseSensitive(fake->scripted, command->name);
        if (command->json) cJSON_AddItemToObject(fake->scripted, command->name, cJSON_Parse(command->json));
        break;
    case SZF_FAKE_GOODBYE: {
        cJSON *frame = cJSON_Parse(command->json);
        const cJSON *reason = cJSON_GetObjectItemCaseSensitive(frame, "reason");
        bool handover = cJSON_IsString(reason) && strcmp(reason->valuestring, "handover") == 0;
        szf_fake_goodbye_all(fake, frame);
        if (handover) step_aside(fake);
        break;
    }
    case SZF_FAKE_RAW:
        for (slot = 0; slot < SZF_FAKE_MAX_CONNECTIONS; slot++)
            if (fake->connections[slot]) szf_fake_send_text(fake->connections[slot], command->bytes, command->length);
        break;
    case SZF_FAKE_DROP:
        for (slot = 0; slot < SZF_FAKE_MAX_CONNECTIONS; slot++) close_connection(fake, slot);
        break;
    case SZF_FAKE_HOLD:
    case SZF_FAKE_RELEASE:
        fake->holding = command->kind == SZF_FAKE_HOLD;
        break;
    }
}

static void run_handover(szfriends_fake_helper *fake) {
    cJSON *frame = cJSON_CreateObject(), *successor;
    cJSON_AddStringToObject(frame, "type", "goodbye");
    cJSON_AddStringToObject(frame, "reason", "handover");
    cJSON_AddNullToObject(frame, "message");
    successor = cJSON_AddObjectToObject(frame, "successor");
    cJSON_AddStringToObject(successor, "version", fake->handover_version ? fake->handover_version : "");
    cJSON_AddNumberToObject(successor, "build_number", fake->handover_build);
    cJSON_AddNullToObject(frame, "error");
    fake->handover_at = 0;
    szf_fake_goodbye_all(fake, frame);
    step_aside(fake);
}

/* Applies every queued scripting command in order; true when the fake is stopping. */
static bool drain_commands(szfriends_fake_helper *fake) {
    szf_fake_command *commands;
    bool stopping;
    pthread_mutex_lock(&fake->mutex);
    stopping = fake->stopping;
    commands = fake->commands;
    fake->commands = fake->commands_tail = NULL;
    pthread_mutex_unlock(&fake->mutex);
    while (commands) {
        szf_fake_command *next = commands->next;
        apply_command(fake, commands);
        szf_fake_free_command(commands);
        commands = next;
    }
    return stopping;
}

static void *fake_thread(void *argument) {
    szfriends_fake_helper *fake = (szfriends_fake_helper *)argument;
    for (;;) {
        struct pollfd fds[SZF_FAKE_MAX_CONNECTIONS + 2];
        int slots[SZF_FAKE_MAX_CONNECTIONS + 2];
        nfds_t count = 0, i;
        int timeout = 1000;

        if (drain_commands(fake)) break;
        if (fake->handover_at && szfriends_monotonic_ms() >= fake->handover_at) run_handover(fake);

        fds[count].fd = fake->wake[0];
        fds[count].events = POLLIN;
        slots[count++] = -1;
        if (fake->listen_fd >= 0) {
            fds[count].fd = fake->listen_fd;
            fds[count].events = POLLIN;
            slots[count++] = -2;
        }
        for (i = 0; i < SZF_FAKE_MAX_CONNECTIONS; i++) {
            szf_fake_connection *connection = fake->connections[i];
            if (!connection) continue;
            if (connection->closing && connection->out_offset >= connection->out_length) {
                close_connection(fake, (int)i);
                continue;
            }
            fds[count].fd = connection->fd;
            fds[count].events = (short)((connection->closing ? 0 : POLLIN) |
                                        (connection->out_offset < connection->out_length ? POLLOUT : 0));
            slots[count++] = (int)i;
        }
        if (fake->handover_at) {
            uint64_t now = szfriends_monotonic_ms();
            timeout = fake->handover_at > now ? (int)(fake->handover_at - now) : 0;
        }
        if (poll(fds, count, timeout) < 0 && errno != EINTR) break;
        /* Scripting first, so a command answers promptly when only the wake pipe woke this poll; frames themselves
         * see every earlier command through the drain before each one (read_connection). */
        if (drain_commands(fake)) break;
        for (i = 0; i < count; i++) {
            if (!fds[i].revents) continue;
            if (slots[i] == -1) {
                char drain[64];
                while (read(fake->wake[0], drain, sizeof drain) > 0) {
                }
            } else if (slots[i] == -2) {
                if (fake->listen_fd >= 0) accept_clients(fake);
            } else if (fake->connections[slots[i]] && fake->connections[slots[i]]->fd == fds[i].fd) {
                if (fds[i].revents & (POLLIN | POLLHUP | POLLERR)) read_connection(fake, slots[i]);
                if (fake->connections[slots[i]]) flush_connection(fake, slots[i]);
            }
        }
        for (i = 0; i < SZF_FAKE_MAX_CONNECTIONS; i++)
            if (fake->connections[i] && fake->connections[i]->out_offset < fake->connections[i]->out_length)
                flush_connection(fake, (int)i);
    }
    return NULL;
}

static void free_fake(szfriends_fake_helper *fake) {
    size_t i;
    cJSON_Delete(fake->welcome);
    cJSON_Delete(fake->views);
    cJSON_Delete(fake->details);
    cJSON_Delete(fake->conversations);
    cJSON_Delete(fake->replies);
    cJSON_Delete(fake->scripted);
    for (i = 0; i < fake->subscription_count; i++) free(fake->subscriptions[i].query);
    free(fake->subscriptions);
    for (i = 0; i < fake->frame_count; i++) free(fake->frames[i]);
    free(fake->frames);
    while (fake->commands) {
        szf_fake_command *next = fake->commands->next;
        szf_fake_free_command(fake->commands);
        fake->commands = next;
    }
    free(fake->handover_version);
    free(fake->state_dir);
    free(fake->fixtures_dir);
    free(fake->version);
    if (fake->wake[0] >= 0) close(fake->wake[0]);
    if (fake->wake[1] >= 0) close(fake->wake[1]);
    if (fake->listen_fd >= 0) close(fake->listen_fd);
    if (fake->lock_fd >= 0) close(fake->lock_fd);
    pthread_mutex_destroy(&fake->mutex);
    free(fake);
}

/* Only the fallback directory, and only when empty: rmdir refuses anything else, so a client's own files or a
 * second fake on the same state directory are never touched. */
static void remove_fallback_directory(const szfriends_fake_helper *fake) {
    char directory[SZFRIENDS_PATH_CAP];
    char *slash;
    if (!fake->socket_fallback || !fake->socket_path[0]) return;
    snprintf(directory, sizeof directory, "%s", fake->socket_path);
    slash = strrchr(directory, '/');
    if (!slash || slash == directory) return;
    *slash = '\0';
    rmdir(directory);
}

static szfriends_status bind_socket(szfriends_fake_helper *fake, const szfriends_fake_helper_config *config) {
    struct sockaddr_un address;
    szfriends_status status;
    size_t length;
    status = szfriends_socket_path(config->state_dir, fake->socket_path, sizeof fake->socket_path,
                                   &fake->socket_fallback);
    if (status != SZFRIENDS_OK) return status;
    status = szfriends_socket_directory_check(fake->socket_path, true);
    if (status != SZFRIENDS_OK) return status;
    if (config->take_lock) {
        char lock_path[SZFRIENDS_PATH_CAP + 16];
        snprintf(lock_path, sizeof lock_path, "%s/helper.lock", config->state_dir);
        /* The state directory itself, created 0700 like the real helper does; the fallback socket lives
         * elsewhere, so the check above may not have made it. */
        status = szfriends_socket_directory_check(lock_path, true);
        if (status != SZFRIENDS_OK) return status;
        fake->lock_fd = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
        if (fake->lock_fd < 0 || flock(fake->lock_fd, LOCK_EX | LOCK_NB) != 0) return SZFRIENDS_ERR_IO;
    }
    unlink(fake->socket_path); /* a stale socket from a crashed run; only the lock holder may do this */
    fake->listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fake->listen_fd < 0 || szfriends_socket_prepare(fake->listen_fd) != 0) return SZFRIENDS_ERR_IO;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    length = strlen(fake->socket_path);
    memcpy(address.sun_path, fake->socket_path, length + 1);
    if (bind(fake->listen_fd, (struct sockaddr *)&address, (socklen_t)sizeof address) != 0) return SZFRIENDS_ERR_IO;
    if (listen(fake->listen_fd, 64) != 0) return SZFRIENDS_ERR_IO;
    return SZFRIENDS_OK;
}

szfriends_status szfriends_fake_helper_start(const szfriends_fake_helper_config *config,
                                             szfriends_fake_helper **fake_out) {
    szfriends_fake_helper *fake;
    szfriends_status status;
    if (fake_out) *fake_out = NULL;
    if (!config || !config->state_dir || !config->fixtures_dir || !fake_out) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    fake = (szfriends_fake_helper *)calloc(1, sizeof *fake);
    if (!fake) return SZFRIENDS_ERR_NO_MEMORY;
    fake->listen_fd = fake->lock_fd = fake->wake[0] = fake->wake[1] = -1;
    pthread_mutex_init(&fake->mutex, NULL);
    fake->state_dir = strdup(config->state_dir);
    fake->fixtures_dir = strdup(config->fixtures_dir);
    fake->version = config->version ? strdup(config->version) : NULL;
    fake->major = config->protocol_major ? config->protocol_major : SZFRIENDS_PROTOCOL_MAJOR;
    fake->minor = config->protocol_major ? config->protocol_minor : SZFRIENDS_PROTOCOL_MINOR;
    fake->min_major = config->protocol_min_major ? config->protocol_min_major : SZFRIENDS_PROTOCOL_MIN_MAJOR;
    fake->handover_delay_ms = config->handover_delay_ms > 0 ? config->handover_delay_ms : 100;
    status = szf_fake_load_fixtures(fake);
    if (status == SZFRIENDS_OK && config->capabilities_json) {
        cJSON *capabilities = cJSON_Parse(config->capabilities_json);
        if (cJSON_IsArray(capabilities)) {
            cJSON_ReplaceItemInObjectCaseSensitive(fake->welcome, "capabilities", capabilities);
        } else {
            cJSON_Delete(capabilities);
            status = SZFRIENDS_ERR_INVALID_ARGUMENT;
        }
    }
    if (status == SZFRIENDS_OK && !fake->build_number) {
        const cJSON *build = cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(fake->welcome, "helper"),
                                                              "build_number");
        fake->build_number = config->build_number ? config->build_number
                                                  : (cJSON_IsNumber(build) ? (uint64_t)build->valuedouble : 1);
    }
    if (status == SZFRIENDS_OK) status = bind_socket(fake, config);
    if (status == SZFRIENDS_OK && pipe(fake->wake) != 0) status = SZFRIENDS_ERR_IO;
    if (status == SZFRIENDS_OK) {
        fcntl(fake->wake[0], F_SETFL, O_NONBLOCK);
        fcntl(fake->wake[1], F_SETFL, O_NONBLOCK);
        if (pthread_create(&fake->thread, NULL, fake_thread, fake) != 0) status = SZFRIENDS_ERR_IO;
    }
    if (status != SZFRIENDS_OK) {
        int saved = errno;
        if (fake->listen_fd >= 0) unlink(fake->socket_path);
        remove_fallback_directory(fake);
        free_fake(fake);
        errno = saved;
        return status;
    }
    *fake_out = fake;
    return SZFRIENDS_OK;
}

void szfriends_fake_helper_stop(szfriends_fake_helper *fake) {
    int slot;
    if (!fake) return;
    pthread_mutex_lock(&fake->mutex);
    fake->stopping = true;
    pthread_mutex_unlock(&fake->mutex);
    if (write(fake->wake[1], "x", 1) < 0) {
        /* already full: the thread wakes anyway */
    }
    pthread_join(fake->thread, NULL);
    for (slot = 0; slot < SZF_FAKE_MAX_CONNECTIONS; slot++) close_connection(fake, slot);
    if (fake->listen_fd >= 0) unlink(fake->socket_path);
    remove_fallback_directory(fake);
    free_fake(fake);
}
