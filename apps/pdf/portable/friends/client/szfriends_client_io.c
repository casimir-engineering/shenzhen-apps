/* Shenzhen Friends client library: hello, reading and dispatching helper frames, sending intents.
 *
 * Frames are parsed with cJSON_ParseWithLengthOpts because a frame inside the line buffer is not a C string the
 * parser may run past (README § protocol). The host receives each frame's own bytes, never a re-serialization,
 * so what it parses is exactly what the helper sent. */

#define _DARWIN_C_SOURCE 1 /* arc4random_buf */

#include "client/szfriends_client_internal.h"

#include "cJSON.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void szfriends_free(void *pointer) {
    free(pointer);
}

szfriends_status szfriends_client_token(char *out, size_t out_cap) {
    static const char hex[] = "0123456789abcdef";
    unsigned char bytes[16];
    size_t i;
    if (!out || out_cap < 33) return SZFRIENDS_ERR_INVALID_ARGUMENT;
#if defined(__APPLE__)
    arc4random_buf(bytes, sizeof bytes);
#else
    {
        int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
        if (fd < 0 || read(fd, bytes, sizeof bytes) != (ssize_t)sizeof bytes) {
            if (fd >= 0) close(fd);
            return SZFRIENDS_ERR_IO;
        }
        close(fd);
    }
#endif
    for (i = 0; i < sizeof bytes; i++) {
        out[2 * i] = hex[bytes[i] >> 4];
        out[2 * i + 1] = hex[bytes[i] & 15];
    }
    out[32] = '\0';
    return SZFRIENDS_OK;
}

szfriends_status szfriends_client_flush(szfriends_client *client) {
    while (client->fd >= 0 && client->out_offset < client->out_length) {
        ssize_t written = szfriends_socket_write(client->fd, client->out + client->out_offset,
                                                 client->out_length - client->out_offset);
        if (written > 0) {
            client->out_offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return SZFRIENDS_OK;
        return SZFRIENDS_ERR_IO;
    }
    if (client->out_offset == client->out_length) client->out_offset = client->out_length = 0;
    return SZFRIENDS_OK;
}

szfriends_status szfriends_client_enqueue(szfriends_client *client, const char *frame, size_t length) {
    size_t needed;
    if (client->out_offset > 0) {
        memmove(client->out, client->out + client->out_offset, client->out_length - client->out_offset);
        client->out_length -= client->out_offset;
        client->out_offset = 0;
    }
    needed = client->out_length + length + 1;
    if (needed > client->out_capacity) {
        size_t capacity = client->out_capacity ? client->out_capacity : 4096;
        char *grown;
        while (capacity < needed) capacity *= 2;
        grown = (char *)realloc(client->out, capacity);
        if (!grown) return SZFRIENDS_ERR_NO_MEMORY;
        client->out = grown;
        client->out_capacity = capacity;
    }
    memcpy(client->out + client->out_length, frame, length);
    client->out[client->out_length + length] = '\n';
    client->out_length += length + 1;
    return SZFRIENDS_OK;
}

static cJSON *string_array(char **values, size_t count) {
    cJSON *array = cJSON_CreateArray();
    size_t i;
    for (i = 0; array && i < count; i++) cJSON_AddItemToArray(array, cJSON_CreateString(values[i]));
    return array;
}

szfriends_status szfriends_client_send_hello(szfriends_client *client) {
    cJSON *hello = cJSON_CreateObject();
    cJSON *protocol, *app, *embedded;
    char id[24];
    char *text;
    szfriends_status status;

    if (!hello) return SZFRIENDS_ERR_NO_MEMORY;
    client->hello_id = client->next_id++;
    snprintf(id, sizeof id, "%llu", (unsigned long long)client->hello_id);
    cJSON_AddStringToObject(hello, "type", "hello");
    cJSON_AddStringToObject(hello, "id", id);
    protocol = cJSON_AddObjectToObject(hello, "protocol");
    cJSON_AddNumberToObject(protocol, "major", SZFRIENDS_PROTOCOL_MAJOR);
    cJSON_AddNumberToObject(protocol, "minor", SZFRIENDS_PROTOCOL_MINOR);
    cJSON_AddNumberToObject(protocol, "min_major", SZFRIENDS_PROTOCOL_MIN_MAJOR);
    app = cJSON_AddObjectToObject(hello, "client");
    cJSON_AddStringToObject(app, "app_id", client->app_id);
    cJSON_AddStringToObject(app, "app_name", client->app_name);
    cJSON_AddStringToObject(app, "app_version", client->app_version);
    cJSON_AddStringToObject(app, "toolkit", client->toolkit);
    cJSON_AddStringToObject(app, "reveal_in", client->reveal_in);
    cJSON_AddNumberToObject(app, "pid", (double)getpid());
    if (client->helper_version) {
        cJSON *helper_protocol;
        embedded = cJSON_AddObjectToObject(hello, "embedded_helper");
        cJSON_AddStringToObject(embedded, "version", client->helper_version);
        cJSON_AddNumberToObject(embedded, "build_number", (double)client->helper_build_number);
        helper_protocol = cJSON_AddObjectToObject(embedded, "protocol");
        cJSON_AddNumberToObject(helper_protocol, "major", client->helper_major);
        cJSON_AddNumberToObject(helper_protocol, "minor", client->helper_minor);
    } else {
        cJSON_AddNullToObject(hello, "embedded_helper"); /* a test client: nothing to hand over to */
    }
    cJSON_AddItemToObject(hello, "capabilities", string_array(client->capabilities, client->capability_count));
    cJSON_AddItemToObject(hello, "open_formats", string_array(client->open_formats, client->open_format_count));
    cJSON_AddStringToObject(hello, "locale", client->locale);
    text = cJSON_PrintUnformatted(hello);
    cJSON_Delete(hello);
    if (!text) return SZFRIENDS_ERR_NO_MEMORY;
    status = szfriends_client_enqueue(client, text, strlen(text));
    free(text);
    if (status != SZFRIENDS_OK) return status;
    return szfriends_client_flush(client);
}

static bool pending_add(szfriends_client *client, uint64_t id) {
    if (client->pending_count == client->pending_capacity) {
        size_t capacity = client->pending_capacity ? client->pending_capacity * 2 : 16;
        uint64_t *grown = (uint64_t *)realloc(client->pending, capacity * sizeof *grown);
        if (!grown) return false;
        client->pending = grown;
        client->pending_capacity = capacity;
    }
    client->pending[client->pending_count++] = id;
    return true;
}

static void pending_remove(szfriends_client *client, const char *re) {
    char *end = NULL;
    unsigned long long id;
    size_t i;
    if (!re || !*re) return;
    id = strtoull(re, &end, 10);
    if (!end || *end) return;
    for (i = 0; i < client->pending_count; i++) {
        if (client->pending[i] != id) continue;
        client->pending[i] = client->pending[--client->pending_count];
        return;
    }
}

void szfriends_client_fail_pending(szfriends_client *client, bool deliver) {
    uint64_t *ids = client->pending;
    size_t count = client->pending_count, i;
    /* Detach the list first: a reply handler may try to send again (it gets NOT_READY) or stop the client. */
    client->pending = NULL;
    client->pending_count = client->pending_capacity = 0;
    for (i = 0; deliver && client->on_frame && i < count; i++) {
        char frame[256];
        /* connection_lost, never not_ready: the intent left this client and may have taken effect, while
         * not_ready promises nothing happened (PROTOCOL.md § Replies and errors; the frame equals
         * fixtures/frames/reply-connection-lost.json apart from re). */
        int length = snprintf(frame, sizeof frame,
                              "{\"type\":\"reply\",\"re\":\"%llu\",\"ok\":false,\"error\":{\"code\":"
                              "\"connection_lost\",\"message\":null,\"retryable\":true,\"details\":{}}}",
                              (unsigned long long)ids[i]);
        client->on_frame(client->context, frame, (size_t)length);
    }
    free(ids);
}

static const char *string_field(const cJSON *object, const char *key) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsString(item) ? item->valuestring : NULL;
}

static bool integer_field(const cJSON *object, const char *key, double *out) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    if (!cJSON_IsNumber(item)) return false;
    *out = item->valuedouble;
    return true;
}

static bool welcome_is_acceptable(szfriends_client *client, const cJSON *frame) {
    const cJSON *protocol = cJSON_GetObjectItemCaseSensitive(frame, "protocol");
    char id[24];
    double major, minor;
    snprintf(id, sizeof id, "%llu", (unsigned long long)client->hello_id);
    if (!string_field(frame, "re") || strcmp(string_field(frame, "re"), id) != 0) return false;
    if (!integer_field(protocol, "major", &major) || !integer_field(protocol, "minor", &minor)) return false;
    if (major < SZFRIENDS_PROTOCOL_MIN_MAJOR || major > SZFRIENDS_PROTOCOL_MAJOR || minor < 0) return false;
    if ((int)major == SZFRIENDS_PROTOCOL_MAJOR && minor > SZFRIENDS_PROTOCOL_MINOR) return false;
    client->negotiated_major = (int)major;
    client->negotiated_minor = (int)minor;
    return true;
}

/* PROTOCOL.md § Lifecycle, handover: our helper takes over at once when it is at least the successor's build;
 * otherwise we give the successor 10 s to appear before spawning ours, so Friends keeps working if the newer
 * app quit meanwhile. */
static void note_goodbye(szfriends_client *client, const cJSON *frame) {
    const char *reason = string_field(frame, "reason");
    if (!reason) return;
    if (strcmp(reason, "handover") == 0) {
        const cJSON *successor = cJSON_GetObjectItemCaseSensitive(frame, "successor");
        double build = 0;
        bool known = integer_field(successor, "build_number", &build);
        if (client->helper_path && client->helper_version && known &&
            (double)client->helper_build_number >= build) {
            client->spawn_now = true;
            client->handover_wait_until = 0;
        } else {
            client->handover_wait_until = szfriends_client_now(client) + SZFRIENDS_HANDOVER_WAIT_MS;
        }
        client->goodbye_delay_ms = SZFRIENDS_RETRY_FIRST_MS;
        client->backoff_ms = SZFRIENDS_RETRY_FIRST_MS;
    } else if (strcmp(reason, "reset") == 0) {
        client->goodbye_delay_ms = 0; /* Reset Friends: reconnect and subscribe again at once */
    }
}

static szfriends_status protocol_failure(szfriends_client *client) {
    szfriends_client_disconnect(client, true);
    return SZFRIENDS_ERR_PROTOCOL;
}

static szfriends_status dispatch(szfriends_client *client, const char *text, size_t length) {
    const char *end = NULL;
    cJSON *frame = cJSON_ParseWithLengthOpts(text, length, &end, 0);
    const char *type;
    unsigned generation = client->generation;

    if (!frame || !cJSON_IsObject(frame)) {
        cJSON_Delete(frame);
        return protocol_failure(client);
    }
    while (end && end < text + length && (*end == ' ' || *end == '\t' || *end == '\r')) end++;
    type = string_field(frame, "type");
    if (!type || (end && end != text + length)) {
        cJSON_Delete(frame);
        return protocol_failure(client);
    }

    if (strcmp(type, "welcome") == 0) {
        if (!client->handshaking) { /* a second welcome means nothing; ignore it */
            cJSON_Delete(frame);
            return SZFRIENDS_OK;
        }
        if (!welcome_is_acceptable(client, frame)) {
            cJSON_Delete(frame);
            szfriends_client_disconnect(client, true);
            return SZFRIENDS_ERR_VERSION;
        }
        cJSON_Delete(frame);
        client->handshaking = false;
        client->handshake_deadline = 0;
        client->ever_ready = true;
        client->backoff_ms = SZFRIENDS_RETRY_FIRST_MS;
        client->spawn_now = false;
        client->handover_wait_until = 0;
        client->unsupported_seen = false;
        /* The welcome first, so the host has the static strings before views react to READY. */
        if (client->on_frame) client->on_frame(client->context, text, length);
        if (generation != client->generation) return SZFRIENDS_OK;
        szfriends_client_set_state(client, SZFRIENDS_CONNECTION_READY);
        return SZFRIENDS_OK;
    }
    if (strcmp(type, "reply") == 0) {
        const char *re = string_field(frame, "re");
        char hello[24];
        snprintf(hello, sizeof hello, "%llu", (unsigned long long)client->hello_id);
        if (client->handshaking && re && strcmp(re, hello) == 0) {
            const cJSON *error = cJSON_GetObjectItemCaseSensitive(frame, "error");
            const char *code = string_field(error, "code");
            const char *handover = string_field(cJSON_GetObjectItemCaseSensitive(error, "details"), "handover");
            if (code && strcmp(code, "protocol_unsupported") == 0) {
                if (handover && strcmp(handover, "scheduled") == 0) {
                    /* Our helper is the newer one and the old helper is stepping aside: spawn ours at once. */
                    client->spawn_now = client->helper_path != NULL;
                } else {
                    client->unsupported_seen = true;
                }
            }
            /* A hello that failed for any reason ends this attempt now, rather than at the handshake timeout. */
            cJSON_Delete(frame);
            if (client->on_frame) client->on_frame(client->context, text, length);
            if (generation == client->generation) szfriends_client_disconnect(client, true);
            return SZFRIENDS_OK;
        } else {
            pending_remove(client, re);
        }
    } else if (strcmp(type, "goodbye") == 0) {
        note_goodbye(client, frame);
        cJSON_Delete(frame);
        if (client->on_frame) client->on_frame(client->context, text, length);
        if (generation == client->generation) szfriends_client_disconnect(client, true);
        return SZFRIENDS_OK;
    }
    cJSON_Delete(frame);
    /* Snapshots, replies and anything newer than this library: the host ignores what it does not know. */
    if (client->on_frame) client->on_frame(client->context, text, length);
    return SZFRIENDS_OK;
}

szfriends_status szfriends_client_on_readable(szfriends_client *client) {
    char buffer[65536];
    unsigned generation;
    int reads;
    if (!client) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    if (client->fd < 0) return client->started ? SZFRIENDS_OK : SZFRIENDS_ERR_CLOSED;
    generation = client->generation;
    /* Bounded per call so one chatty helper cannot starve the host's run loop; the descriptor stays readable
     * and the host calls again. */
    for (reads = 0; reads < 64; reads++) {
        ssize_t n = read(client->fd, buffer, sizeof buffer);
        szfriends_status status;
        const char *line;
        size_t length;
        if (n == 0) { /* EOF: a crash, or the close after a goodbye already handled */
            szfriends_client_disconnect(client, true);
            return SZFRIENDS_OK;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            szfriends_client_disconnect(client, true);
            return SZFRIENDS_ERR_IO;
        }
        status = szfriends_line_reader_push(client->reader, buffer, (size_t)n);
        if (status != SZFRIENDS_OK) {
            /* PROTOCOL.md § Framing: stop buffering at once; close and reconnect. */
            szfriends_client_disconnect(client, true);
            return status;
        }
        for (;;) {
            const char *start;
            status = szfriends_line_reader_next(client->reader, &line, &length);
            if (status != SZFRIENDS_OK || !line) break;
            start = line;
            while (length > 0 && (*start == ' ' || *start == '\t' || *start == '\r')) {
                start++;
                length--;
            }
            while (length > 0 && (start[length - 1] == ' ' || start[length - 1] == '\t' ||
                                  start[length - 1] == '\r'))
                length--;
            if (length == 0) continue;
            status = dispatch(client, start, length);
            if (generation != client->generation || status != SZFRIENDS_OK) return status;
        }
    }
    if (client->out_offset < client->out_length && szfriends_client_flush(client) != SZFRIENDS_OK) {
        szfriends_client_disconnect(client, true);
        return SZFRIENDS_ERR_IO;
    }
    return SZFRIENDS_OK;
}

static bool valid_type(const char *type) {
    const char *p;
    if (!type || !*type || strcmp(type, "hello") == 0) return false;
    for (p = type; *p; p++)
        if (!((*p >= 'a' && *p <= 'z') || *p == '_')) return false;
    return true;
}

szfriends_status szfriends_client_send(szfriends_client *client, const char *type, const char *fields_json,
                                       char *id_out, size_t id_out_cap) {
    cJSON *fields = NULL, *frame;
    char id[24];
    char *text;
    size_t length;
    szfriends_status status;

    if (id_out && id_out_cap > 0) id_out[0] = '\0';
    if (!client || !valid_type(type)) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    if (client->state != SZFRIENDS_CONNECTION_READY || client->fd < 0) return SZFRIENDS_ERR_NOT_READY;
    if (fields_json) {
        const char *end = NULL;
        size_t fields_length = strlen(fields_json);
        if (fields_length > SZFRIENDS_MAX_FRAME_BYTES) return SZFRIENDS_ERR_FRAME_TOO_LARGE;
        fields = cJSON_ParseWithLengthOpts(fields_json, fields_length, &end, 0);
        while (end && *end && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n')) end++;
        if (!cJSON_IsObject(fields) || (end && *end) || cJSON_GetObjectItemCaseSensitive(fields, "type") ||
            cJSON_GetObjectItemCaseSensitive(fields, "id")) {
            cJSON_Delete(fields);
            return SZFRIENDS_ERR_INVALID_ARGUMENT;
        }
    }
    snprintf(id, sizeof id, "%llu", (unsigned long long)client->next_id);
    if (id_out && id_out_cap < strlen(id) + 1) {
        cJSON_Delete(fields);
        return SZFRIENDS_ERR_INVALID_ARGUMENT;
    }
    frame = cJSON_CreateObject();
    if (!frame) {
        cJSON_Delete(fields);
        return SZFRIENDS_ERR_NO_MEMORY;
    }
    /* type and id first so logs read naturally; the fields follow in the caller's order. */
    cJSON_AddStringToObject(frame, "type", type);
    cJSON_AddStringToObject(frame, "id", id);
    while (fields && fields->child) {
        cJSON *item = cJSON_DetachItemViaPointer(fields, fields->child);
        cJSON_AddItemToObject(frame, item->string, item);
    }
    cJSON_Delete(fields);
    text = cJSON_PrintUnformatted(frame);
    cJSON_Delete(frame);
    if (!text) return SZFRIENDS_ERR_NO_MEMORY;
    length = strlen(text);
    if (length > SZFRIENDS_MAX_FRAME_BYTES) {
        free(text);
        return SZFRIENDS_ERR_FRAME_TOO_LARGE;
    }
    if (client->out_length - client->out_offset + length + 1 > SZFRIENDS_MAX_PENDING_OUTPUT) {
        free(text);
        return SZFRIENDS_ERR_NOT_READY;
    }
    if (!pending_add(client, client->next_id)) {
        free(text);
        return SZFRIENDS_ERR_NO_MEMORY;
    }
    status = szfriends_client_enqueue(client, text, length);
    free(text);
    if (status != SZFRIENDS_OK) {
        client->pending_count--;
        return status;
    }
    client->next_id++;
    if (id_out) memcpy(id_out, id, strlen(id) + 1);
    /* A write error is left for the next tick or read to turn into a disconnect: handling it here would run the
     * host's callbacks from inside its own send call. */
    szfriends_client_flush(client);
    return SZFRIENDS_OK;
}
