/* friends-e2e-check, two apps on one helper: the app that plays ShenzhenPDF.
 *
 * It hosts Friends the way ShenzhenPDF's AppKit link does: one client from the C client library, its descriptor
 * polled and its timers ticked from the app's loop, the embedded helper spawned by the library when nothing answers,
 * and every subscription sent again after each READY. The scenario copies it into a test app bundle
 * (ShenzhenPDF.app/Contents/MacOS/, beside Contents/Helpers/Shenzhen Friends.app), so the helper sees an app that
 * really carries the build it names, and drives it over stdin and stdout, one JSON object per line.
 *
 * Usage: szfriends-e2e-client-app <embedded helper executable> <helper version> <helper build number>
 * The state directory is SZFRIENDS_STATE_DIR, as for any unsigned build.
 *
 * Commands: {"cmd":"list"}, {"cmd":"open","conversation_id":…}, {"cmd":"send","conversation_id":…,"text":…,
 * "client_token":…,"tag":…}, {"cmd":"quit"}.
 * Events: {"event":"state","state":"ready","helper_pid":…}, {"event":"welcome","frame":…},
 * {"event":"snapshot","view":…,"data":…}, {"event":"reply","tag":…,"ok":…,"result":…,"code":…},
 * {"event":"goodbye","frame":…}. */

#define _DARWIN_C_SOURCE 1

#include "client/szfriends_client.h"

#include "cJSON.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define SZFE2E_MAX_OPEN 8
#define SZFE2E_MAX_TAGS 64

typedef struct {
    szfriends_client *client;
    bool listed, resubscribe;
    char open[SZFE2E_MAX_OPEN][72];
    int open_count;
    char tag_ids[SZFE2E_MAX_TAGS][32], tags[SZFE2E_MAX_TAGS][32];
    int tag_count;
} szfe2e_app;

static void emit(cJSON *event) {
    char *text = cJSON_PrintUnformatted(event);
    if (text) {
        fputs(text, stdout);
        fputc('\n', stdout);
        fflush(stdout);
        free(text);
    }
    cJSON_Delete(event);
}

/* The helper at the other end of the client's socket, as the kernel reports it. */
static int helper_pid(szfriends_client *client) {
    int fd = szfriends_client_fd(client);
    pid_t pid = 0;
    socklen_t length = sizeof pid;
    if (fd < 0 || getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) != 0) return 0;
    return (int)pid;
}

static const char *state_name(szfriends_connection_state state) {
    switch (state) {
    case SZFRIENDS_CONNECTION_IDLE: return "idle";
    case SZFRIENDS_CONNECTION_CONNECTING: return "connecting";
    case SZFRIENDS_CONNECTION_HANDSHAKING: return "handshaking";
    case SZFRIENDS_CONNECTION_READY: return "ready";
    case SZFRIENDS_CONNECTION_WAITING: return "waiting";
    case SZFRIENDS_CONNECTION_INCOMPATIBLE: return "incompatible";
    }
    return "unknown";
}

static void on_state(void *context, szfriends_connection_state state) {
    szfe2e_app *app = (szfe2e_app *)context;
    cJSON *event = cJSON_CreateObject();
    cJSON_AddStringToObject(event, "event", "state");
    cJSON_AddStringToObject(event, "state", state_name(state));
    cJSON_AddNumberToObject(event, "helper_pid", state == SZFRIENDS_CONNECTION_READY ? helper_pid(app->client) : 0);
    emit(event);
    /* Subscription ids never survive a reconnect (PROTOCOL.md § Lifecycle): sent again from the loop, outside the
     * library's callback, as the AppKit link queues it. */
    if (state == SZFRIENDS_CONNECTION_READY) app->resubscribe = true;
}

static const char *tag_for(szfe2e_app *app, const char *id) {
    int i;
    for (i = 0; id && i < app->tag_count; i++)
        if (strcmp(app->tag_ids[i], id) == 0) return app->tags[i];
    return NULL;
}

static void on_frame(void *context, const char *json, size_t length) {
    szfe2e_app *app = (szfe2e_app *)context;
    cJSON *frame = cJSON_ParseWithLength(json, length), *event;
    const cJSON *type = cJSON_GetObjectItemCaseSensitive(frame, "type");
    if (!cJSON_IsString(type)) {
        cJSON_Delete(frame);
        return;
    }
    event = cJSON_CreateObject();
    if (strcmp(type->valuestring, "snapshot") == 0) {
        const cJSON *view = cJSON_GetObjectItemCaseSensitive(frame, "view");
        cJSON_AddStringToObject(event, "event", "snapshot");
        cJSON_AddStringToObject(event, "view", cJSON_IsString(view) ? view->valuestring : "");
        cJSON_AddItemToObject(event, "data", cJSON_DetachItemFromObjectCaseSensitive(frame, "data"));
        cJSON_Delete(frame);
    } else if (strcmp(type->valuestring, "reply") == 0) {
        const cJSON *re = cJSON_GetObjectItemCaseSensitive(frame, "re");
        const char *tag = tag_for(app, cJSON_IsString(re) ? re->valuestring : NULL);
        if (!tag) { /* a subscription's reply: its snapshots already said everything */
            cJSON_Delete(frame);
            cJSON_Delete(event);
            return;
        }
        const cJSON *ok = cJSON_GetObjectItemCaseSensitive(frame, "ok");
        const cJSON *code = cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(frame, "error"), "code");
        cJSON *result = cJSON_DetachItemFromObjectCaseSensitive(frame, "result");
        cJSON_AddStringToObject(event, "event", "reply");
        cJSON_AddStringToObject(event, "tag", tag);
        cJSON_AddBoolToObject(event, "ok", cJSON_IsTrue(ok));
        cJSON_AddItemToObject(event, "result", result ? result : cJSON_CreateNull());
        cJSON_AddStringToObject(event, "code", cJSON_IsString(code) ? code->valuestring : "");
        cJSON_Delete(frame);
    } else {
        cJSON_AddStringToObject(event, "event", type->valuestring); /* welcome, goodbye */
        cJSON_AddItemToObject(event, "frame", frame);
    }
    emit(event);
}

static void subscribe_all(szfe2e_app *app) {
    char id[32];
    int i;
    if (app->listed) szfriends_client_send_intent(app->client, szfriends_intent_subscribe("list", NULL), id, sizeof id);
    for (i = 0; i < app->open_count; i++)
        szfriends_client_send_intent(app->client, szfriends_intent_open_conversation(app->open[i], NULL), id,
                                     sizeof id);
}

static const char *string_field(const cJSON *object, const char *key) {
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsString(item) ? item->valuestring : NULL;
}

/* One command line; false for quit. */
static bool run_command(szfe2e_app *app, const char *line) {
    cJSON *command = cJSON_Parse(line);
    const char *name = string_field(command, "cmd"), *conversation = string_field(command, "conversation_id");
    char id[32];
    bool keep_going = true;
    if (!name) {
        /* not a command: ignored, as a host ignores what it does not know */
    } else if (strcmp(name, "quit") == 0) {
        keep_going = false;
    } else if (strcmp(name, "list") == 0) {
        app->listed = true;
        szfriends_client_send_intent(app->client, szfriends_intent_subscribe("list", NULL), id, sizeof id);
    } else if (strcmp(name, "open") == 0 && conversation && app->open_count < SZFE2E_MAX_OPEN) {
        snprintf(app->open[app->open_count++], sizeof app->open[0], "%s", conversation);
        szfriends_client_send_intent(app->client, szfriends_intent_open_conversation(conversation, NULL), id,
                                     sizeof id);
    } else if (strcmp(name, "send") == 0 && conversation && app->tag_count < SZFE2E_MAX_TAGS) {
        const char *text = string_field(command, "text"), *token = string_field(command, "client_token");
        const char *tag = string_field(command, "tag");
        szfriends_intent *intent = szfriends_intent_send_message(conversation, text ? text : "", token, NULL, 0);
        if (szfriends_client_send_intent(app->client, intent, id, sizeof id) == SZFRIENDS_OK && tag) {
            snprintf(app->tag_ids[app->tag_count], sizeof app->tag_ids[0], "%s", id);
            snprintf(app->tags[app->tag_count++], sizeof app->tags[0], "%s", tag);
        } else if (tag) {
            cJSON *event = cJSON_CreateObject();
            cJSON_AddStringToObject(event, "event", "reply");
            cJSON_AddStringToObject(event, "tag", tag);
            cJSON_AddFalseToObject(event, "ok");
            cJSON_AddNullToObject(event, "result");
            cJSON_AddStringToObject(event, "code", "not_ready"); /* intents never queue in the client */
            emit(event);
        }
    }
    cJSON_Delete(command);
    return keep_going;
}

int main(int argc, char **argv) {
    static const char *const capabilities[] = {"attach.items", "drop.files", "drop.tabs"};
    static const char *const formats[] = {"pdf", "md"};
    szfriends_client_config config;
    szfe2e_app app;
    char buffer[65536];
    size_t used = 0;
    bool running = true;
    if (argc != 4) {
        fprintf(stderr, "usage: %s <embedded helper> <helper version> <helper build number>\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    memset(&app, 0, sizeof app);
    memset(&config, 0, sizeof config);
    config.helper_path = argv[1];
    config.helper_version = argv[2];
    config.helper_build_number = strtoull(argv[3], NULL, 10);
    config.helper_protocol_major = SZFRIENDS_PROTOCOL_MAJOR;
    config.helper_protocol_minor = SZFRIENDS_PROTOCOL_MINOR;
    config.app_id = "com.intuition.shenzhenpdf";
    config.app_name = "ShenzhenPDF";
    config.app_version = "26.10.13";
    config.toolkit = "appkit";
    config.reveal_in = "Finder";
    config.capabilities = capabilities;
    config.capability_count = sizeof capabilities / sizeof capabilities[0];
    config.open_formats = formats;
    config.open_format_count = sizeof formats / sizeof formats[0];
    config.on_frame = on_frame;
    config.on_state = on_state;
    config.context = &app;
    app.client = szfriends_client_new(&config);
    if (!app.client) return 2;
    szfriends_client_start(app.client);
    while (running) {
        struct pollfd fds[2];
        nfds_t count = 1;
        int client_fd = szfriends_client_fd(app.client);
        int64_t wait = szfriends_client_next_tick_ms(app.client, szfriends_monotonic_ms());
        fds[0].fd = STDIN_FILENO;
        fds[0].events = POLLIN;
        fds[0].revents = 0;
        if (client_fd >= 0) {
            fds[1].fd = client_fd;
            fds[1].events = POLLIN;
            fds[1].revents = 0;
            count = 2;
        }
        if (poll(fds, count, wait < 0 || wait > 100 ? 100 : (int)wait) < 0 && errno != EINTR) break;
        if (fds[0].revents) {
            ssize_t got = read(STDIN_FILENO, buffer + used, sizeof buffer - used - 1);
            char *line, *newline;
            if (got <= 0) break; /* the scenario went away: so does the app */
            used += (size_t)got;
            buffer[used] = '\0';
            line = buffer;
            while (running && (newline = strchr(line, '\n')) != NULL) {
                *newline = '\0';
                running = run_command(&app, line);
                line = newline + 1;
            }
            used = strlen(line);
            memmove(buffer, line, used + 1);
            if (used == sizeof buffer - 1) break; /* no command is this long */
        }
        if (count == 2 && fds[1].revents && szfriends_client_fd(app.client) == client_fd)
            szfriends_client_on_readable(app.client);
        szfriends_client_tick(app.client, szfriends_monotonic_ms());
        if (app.resubscribe && szfriends_client_state(app.client) == SZFRIENDS_CONNECTION_READY) {
            app.resubscribe = false;
            subscribe_all(&app);
        }
    }
    szfriends_client_stop(app.client, false);
    szfriends_client_free(app.client);
    return 0;
}
