/* friends-e2e-check, two apps on one helper: the app that plays Shenzhen Files.
 *
 * It hosts Friends through the GTK views' link (gtk/szfriends_gtk_link.h) on the GLib main loop, as Shenzhen Files'
 * adapter does, but display-free: it never calls gtk_init, opens no display and makes no widget, so it runs wherever
 * the harness runs and never shows anything. The link drives the C client library, spawns the embedded helper when
 * nothing answers and subscribes again after every READY by itself. The scenario copies this program into a test app
 * bundle (Shenzhen Files.app/Contents/MacOS/, beside Contents/Helpers/Shenzhen Friends.app) and drives it over stdin
 * and stdout with the same lines as szfriends_e2e_client_app.c.
 *
 * Usage: szfriends-e2e-gtk-app <embedded helper executable> <helper version> <helper build number>
 * The state directory is SZFRIENDS_STATE_DIR, as for any unsigned build. */

#define _DARWIN_C_SOURCE 1

#include "gtk/szfriends_gtk_link.h"

#include <glib-unix.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct {
    SZFriendsGtkLink *link;
    GMainLoop *loop;
    GString *input;
    guint input_source; /* 0 once the scenario has gone */
} SZFE2EGtkApp;

static void emit(JsonObject *event) {
    JsonNode *root = json_node_init_object(json_node_alloc(), event);
    JsonGenerator *generator = json_generator_new();
    json_generator_set_root(generator, root);
    gchar *text = json_generator_to_data(generator, NULL);
    fputs(text, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    g_free(text);
    g_object_unref(generator);
    json_node_unref(root);
    json_object_unref(event);
}

static const char *state_name(SZFriendsGtkLinkState state) {
    switch (state) {
    case SZFRIENDS_GTK_LINK_IDLE: return "idle";
    case SZFRIENDS_GTK_LINK_CONNECTING: return "connecting";
    case SZFRIENDS_GTK_LINK_READY: return "ready";
    case SZFRIENDS_GTK_LINK_WAITING: return "waiting";
    case SZFRIENDS_GTK_LINK_INCOMPATIBLE: return "incompatible";
    }
    return "unknown";
}

static void on_state(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    (void)data;
    pid_t pid = 0;
    socklen_t length = sizeof pid;
    int fd = szfriends_gtk_link_client_fd(link);
    /* The helper at the other end of the link's socket, as the kernel reports it. */
    if (state != SZFRIENDS_GTK_LINK_READY || fd < 0 || getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) != 0)
        pid = 0;
    JsonObject *event = json_object_new();
    json_object_set_string_member(event, "event", "state");
    json_object_set_string_member(event, "state", state_name(state));
    json_object_set_int_member(event, "helper_pid", pid);
    emit(event);
}

static void on_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    JsonObject *event = json_object_new();
    json_object_set_string_member(event, "event", "snapshot");
    json_object_set_string_member(event, "view", user_data);
    json_object_set_object_member(event, "data", json_object_ref(data));
    emit(event);
}

static void on_reply(JsonObject *result, const SZFriendsGtkError *error, gpointer user_data) {
    JsonObject *event = json_object_new();
    json_object_set_string_member(event, "event", "reply");
    json_object_set_string_member(event, "tag", user_data);
    json_object_set_boolean_member(event, "ok", result != NULL);
    if (result) json_object_set_object_member(event, "result", json_object_ref(result));
    else json_object_set_null_member(event, "result");
    json_object_set_string_member(event, "code", error && error->code ? error->code : "");
    emit(event);
}

static const char *string_member(JsonObject *object, const char *key) {
    return object ? json_object_get_string_member_with_default(object, key, NULL) : NULL;
}

/* One command line; FALSE for quit. */
static gboolean run_command(SZFE2EGtkApp *app, const char *line) {
    JsonNode *node = json_from_string(line, NULL);
    JsonObject *command = node && JSON_NODE_HOLDS_OBJECT(node) ? json_node_get_object(node) : NULL;
    const char *name = string_member(command, "cmd"), *conversation = string_member(command, "conversation_id");
    gboolean keep_going = TRUE;
    if (!name) {
        /* not a command: ignored, as a host ignores what it does not know */
    } else if (strcmp(name, "quit") == 0) {
        keep_going = FALSE;
    } else if (strcmp(name, "list") == 0) {
        szfriends_gtk_link_subscribe(app->link, "list", NULL, on_snapshot, (gpointer) "list", NULL);
    } else if (strcmp(name, "open") == 0 && conversation) {
        szfriends_gtk_link_open_conversation(app->link, conversation, NULL, on_snapshot, (gpointer) "conversation",
                                             NULL);
    } else if (strcmp(name, "send") == 0 && conversation) {
        const char *text = string_member(command, "text"), *token = string_member(command, "client_token");
        const char *tag = string_member(command, "tag");
        szfriends_intent *intent = szfriends_intent_send_message(conversation, text ? text : "", token, NULL, 0);
        szfriends_gtk_link_send(app->link, intent, on_reply, g_strdup(tag ? tag : ""), g_free);
    }
    if (node) json_node_unref(node);
    return keep_going;
}

static gboolean on_input(gint fd, GIOCondition condition, gpointer data) {
    SZFE2EGtkApp *app = data;
    char chunk[4096];
    ssize_t got = (condition & (G_IO_IN | G_IO_HUP)) ? read(fd, chunk, sizeof chunk) : 0;
    gboolean keep_going = got > 0; /* the scenario went away: so does the app */
    if (got > 0) g_string_append_len(app->input, chunk, got);
    char *newline;
    while (keep_going && (newline = strchr(app->input->str, '\n')) != NULL) {
        *newline = '\0';
        keep_going = run_command(app, app->input->str);
        g_string_erase(app->input, 0, newline - app->input->str + 1);
    }
    if (keep_going) return G_SOURCE_CONTINUE;
    app->input_source = 0;
    g_main_loop_quit(app->loop);
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <embedded helper> <helper version> <helper build number>\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    SZFriendsGtkHost host;
    memset(&host, 0, sizeof host);
    host.struct_size = sizeof host;
    host.app_id = "com.intuition.shenzhenfiles";
    host.app_name = "Shenzhen Files";
    host.app_version = "26.10.13";
    host.reveal_in_name = "Shenzhen Files";
    host.helper_path = argv[1];
    host.helper_version = argv[2];
    host.helper_build_number = g_ascii_strtoull(argv[3], NULL, 10);
    SZFE2EGtkApp app = {szfriends_gtk_link_new(&host), g_main_loop_new(NULL, FALSE), g_string_new(NULL), 0};
    if (!app.link) return 2;
    szfriends_gtk_link_add_state_watch(app.link, on_state, NULL, NULL);
    app.input_source = g_unix_fd_add(STDIN_FILENO, G_IO_IN | G_IO_HUP | G_IO_ERR, on_input, &app);
    szfriends_gtk_link_start(app.link);
    g_main_loop_run(app.loop);
    if (app.input_source) g_source_remove(app.input_source);
    szfriends_gtk_link_stop(app.link, FALSE);
    szfriends_gtk_link_free(app.link);
    g_main_loop_unref(app.loop);
    g_string_free(app.input, TRUE);
    return 0;
}
