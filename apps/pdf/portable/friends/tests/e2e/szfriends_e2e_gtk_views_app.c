/* friends-one-identity-check: the app that plays Shenzhen Files with the real GTK Friends views.
 *
 * It hosts Friends as Shenzhen Files' adapter does (patches/friends-host-adapter.patch in Shenzhen Files): at launch
 * szfriends_gtk_spawn_helper_async() for the helper its bundle embeds, then one link for the process, started after
 * the first window, with the helper's version and build number in its hello and no state directory of its own, so the
 * client library's default (the person's Friends home under $HOME) decides where the helper is. The window's Friends
 * button and dropdown are the real ones; the dropdown's presenter shows nothing, and its content is laid out in a
 * window that is realized but never mapped. The quiet interposer (gtk/tests/szfriends_gtk_quiet.c) keeps GDK from
 * making this process a foreground app, so nothing reaches the Dock or takes focus. The scenario copies this program
 * into a test app bundle (Shenzhen Files.app/Contents/MacOS/) and drives it with the lines of
 * szfriends_e2e_appkit_app.m.
 *
 * Usage: szfriends-e2e-gtk-views-app <embedded helper executable> <helper version> <helper build number> */

#define _DARWIN_C_SOURCE 1

#include "gtk/szfriends_gtk.h"
#include "gtk/szfriends_gtk_conversation.h"
#include "gtk/szfriends_gtk_dropdown.h"
#include "gtk/szfriends_gtk_link.h"

#include <ApplicationServices/ApplicationServices.h>
#include <adwaita.h>
#include <glib-unix.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int szfriends_gtk_quiet_transform_calls(void); /* gtk/tests/szfriends_gtk_quiet.c */

typedef struct {
    SZFriendsGtkLink *link;
    GMainLoop *loop;
    GString *input;
    guint input_source;
    GtkWidget *window, *button, *content_window;
    SZFriendsGtkDropdown *dropdown;
} SZFOGtkApp;

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

static void reply_event(const char *tag, gboolean ok, JsonObject *result, const char *code) {
    JsonObject *event = json_object_new();
    json_object_set_string_member(event, "event", "reply");
    json_object_set_string_member(event, "tag", tag ? tag : "");
    json_object_set_boolean_member(event, "ok", ok);
    if (result) json_object_set_object_member(event, "result", result);
    else json_object_set_null_member(event, "result");
    json_object_set_string_member(event, "code", code ? code : "");
    emit(event);
}

static void on_reply(JsonObject *result, const SZFriendsGtkError *error, gpointer user_data) {
    reply_event(user_data, result != NULL, result ? json_object_ref(result) : NULL,
                error && error->code ? error->code : "");
}

static const char *string_member(JsonObject *object, const char *key) {
    return object && json_object_has_member(object, key) ? json_object_get_string_member_with_default(object, key, NULL)
                                                         : NULL;
}

/* ---- The real views ------------------------------------------------------------------------------------------ */

static void present_nothing(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)dropdown, (void)data;
}

static void dismiss_now(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)data;
    szfriends_gtk_dropdown_presenter_closed(dropdown);
}

static void pump_for(guint ms) {
    gint64 until = g_get_monotonic_time() + (gint64)ms * 1000;
    while (g_get_monotonic_time() < until) g_main_context_iteration(NULL, FALSE), g_usleep(2000);
}

static gboolean pump_until(gboolean (*condition)(gpointer), gpointer data, guint ms) {
    gint64 until = g_get_monotonic_time() + (gint64)ms * 1000;
    while (!condition(data)) {
        if (g_get_monotonic_time() > until) return FALSE;
        g_main_context_iteration(NULL, FALSE);
        g_usleep(2000);
    }
    return TRUE;
}

/* The dropdown's content, laid out at the dropdown's size in its never-mapped window. */
static void layout(SZFOGtkApp *app) {
    GtkWidget *content = szfriends_gtk_dropdown_get_content(app->dropdown);
    if (!app->content_window) {
        app->content_window = gtk_window_new();
        gtk_window_set_child(GTK_WINDOW(app->content_window), content);
        gtk_widget_realize(app->content_window);
    }
    if (!gtk_widget_get_mapped(content)) gtk_widget_map(content);
    int minimum = 0, natural = 0;
    gtk_widget_measure(content, GTK_ORIENTATION_VERTICAL, 400, &minimum, &natural, NULL, NULL);
    gtk_widget_allocate(content, 400, MAX(640, minimum), -1, NULL);
}

typedef struct {
    SZFOGtkApp *app;
    const char *conversation_id;
} SZFOWant;

static gboolean conversation_on_top(gpointer data) {
    SZFOWant *want = data;
    SZFriendsGtkPage *page = szfriends_gtk_dropdown_get_top_page(want->app->dropdown);
    if (!page || szfriends_gtk_page_get_kind(page) != SZFRIENDS_GTK_PAGE_CONVERSATION) return FALSE;
    SZFriendsGtkConversation *state = szfriends_gtk_conversation_page_state(page);
    return state && state->composer && g_strcmp0(szfriends_gtk_page_get_argument(page), want->conversation_id) == 0;
}

static SZFriendsGtkPage *show_conversation(SZFOGtkApp *app, const char *conversation_id) {
    SZFOWant want = {app, conversation_id};
    if (!szfriends_gtk_dropdown_is_open(app->dropdown)) szfriends_gtk_dropdown_open(app->dropdown);
    if (!conversation_on_top(&want)) szfriends_gtk_dropdown_open_conversation(app->dropdown, conversation_id, NULL);
    layout(app);
    if (!pump_until(conversation_on_top, &want, 10000)) return NULL;
    pump_for(100);
    layout(app);
    return szfriends_gtk_dropdown_get_top_page(app->dropdown);
}

static void collect_labels(GtkWidget *root, JsonArray *texts) {
    if (!root || !gtk_widget_get_visible(root)) return;
    if (GTK_IS_LABEL(root)) {
        const char *text = gtk_label_get_text(GTK_LABEL(root));
        if (text && *text) json_array_add_string_element(texts, text);
    } else if (GTK_IS_TEXT_VIEW(root)) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(root));
        GtkTextIter start, end;
        gtk_text_buffer_get_bounds(buffer, &start, &end);
        char *text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
        if (text && *text) json_array_add_string_element(texts, text);
        g_free(text);
    }
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child))
        collect_labels(child, texts);
}

static GtkTextBuffer *composer_buffer(SZFriendsGtkPage *page) {
    SZFriendsGtkConversation *state = szfriends_gtk_conversation_page_state(page);
    return gtk_text_view_get_buffer(GTK_TEXT_VIEW(szfriends_gtk_composer_get_text_view(state->composer)));
}

/* The text view's own key handler, as GTK runs it for a key press of Return. */
static gboolean press_return(SZFriendsGtkPage *page) {
    SZFriendsGtkConversation *state = szfriends_gtk_conversation_page_state(page);
    GtkWidget *view = szfriends_gtk_composer_get_text_view(state->composer);
    GListModel *controllers = gtk_widget_observe_controllers(view);
    gboolean handled = FALSE;
    for (guint i = 0; i < g_list_model_get_n_items(controllers) && !handled; i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_EVENT_CONTROLLER_KEY(controller) &&
            gtk_event_controller_get_propagation_phase(controller) == GTK_PHASE_CAPTURE)
            g_signal_emit_by_name(controller, "key-pressed", GDK_KEY_Return, 36, 0, &handled);
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    return handled;
}

static gboolean composer_empty(gpointer data) {
    return gtk_text_buffer_get_char_count(composer_buffer(data)) == 0;
}

static void ui_type(SZFOGtkApp *app, const char *conversation_id, const char *text, const char *tag) {
    SZFriendsGtkPage *page = show_conversation(app, conversation_id);
    if (!page) {
        reply_event(tag, FALSE, NULL, "no_conversation");
        return;
    }
    GtkTextBuffer *buffer = composer_buffer(page);
    gtk_widget_grab_focus(szfriends_gtk_composer_get_text_view(szfriends_gtk_conversation_page_state(page)->composer));
    /* One character at a time, as typing inserts them, then Return. */
    for (const char *p = text; *p; p = g_utf8_next_char(p))
        gtk_text_buffer_insert_at_cursor(buffer, p, (int)(g_utf8_next_char(p) - p));
    gboolean handled = press_return(page);
    gboolean sent = handled && pump_until(composer_empty, page, 10000);
    reply_event(tag, sent, NULL, sent ? NULL : handled ? "not_sent" : "return_not_handled");
}

static void ui_texts(SZFOGtkApp *app, const char *conversation_id, const char *tag) {
    SZFriendsGtkPage *page = show_conversation(app, conversation_id);
    JsonObject *result = json_object_new();
    JsonArray *texts = json_array_new();
    if (page) {
        GtkWidget *history = szfriends_gtk_conversation_page_part(page, "stack");
        collect_labels(history ? history : szfriends_gtk_page_get_widget(page), texts);
    }
    json_object_set_array_member(result, "texts", texts);
    reply_event(tag, page != NULL, result, page ? NULL : "no_conversation");
}

static void ui_list(SZFOGtkApp *app, const char *tag) {
    if (!szfriends_gtk_dropdown_is_open(app->dropdown)) szfriends_gtk_dropdown_open(app->dropdown);
    szfriends_gtk_dropdown_pop_to_list(app->dropdown);
    layout(app);
    pump_for(150);
    layout(app);
    JsonObject *result = json_object_new();
    JsonArray *texts = json_array_new();
    SZFriendsGtkPage *page = szfriends_gtk_dropdown_get_top_page(app->dropdown);
    collect_labels(page ? szfriends_gtk_page_get_widget(page) : NULL, texts);
    json_object_set_array_member(result, "texts", texts);
    reply_event(tag, page != NULL, result, NULL);
}

/* ---- Commands ------------------------------------------------------------------------------------------------- */

/* One command line; FALSE for quit. */
static gboolean run_command(SZFOGtkApp *app, const char *line) {
    JsonNode *node = json_from_string(line, NULL);
    JsonObject *command = node && JSON_NODE_HOLDS_OBJECT(node) ? json_node_get_object(node) : NULL;
    const char *name = string_member(command, "cmd"), *conversation = string_member(command, "conversation_id");
    const char *tag = string_member(command, "tag");
    gboolean keep_going = TRUE;
    if (!name) {
        /* not a command: ignored */
    } else if (strcmp(name, "quit") == 0) {
        keep_going = FALSE;
    } else if (strcmp(name, "list") == 0 || strcmp(name, "profile") == 0) {
        szfriends_gtk_link_subscribe(app->link, name, NULL, on_snapshot, (gpointer)(strcmp(name, "list") ? "profile"
                                                                                                         : "list"),
                                     NULL);
    } else if (strcmp(name, "open") == 0 && conversation) {
        szfriends_gtk_link_open_conversation(app->link, conversation, NULL, on_snapshot, (gpointer) "conversation",
                                             NULL);
    } else if (strcmp(name, "send") == 0 && conversation) {
        const char *text = string_member(command, "text"), *token = string_member(command, "client_token");
        szfriends_intent *intent = szfriends_intent_send_message(conversation, text ? text : "", token, NULL, 0);
        szfriends_gtk_link_send(app->link, intent, on_reply, g_strdup(tag ? tag : ""), g_free);
    } else if (strcmp(name, "intent") == 0 && string_member(command, "type")) {
        /* The GTK link sends typed intents only: the few the scenarios use from this app. */
        const char *type = string_member(command, "type");
        JsonObject *fields =
            json_object_has_member(command, "fields") ? json_object_get_object_member(command, "fields") : NULL;
        szfriends_intent *intent = NULL;
        if (strcmp(type, "set_name") == 0) intent = szfriends_intent_set_name(string_member(fields, "name"));
        else if (strcmp(type, "delete_history") == 0)
            intent = szfriends_intent_delete_history(string_member(fields, "conversation_id"));
        else if (strcmp(type, "activate") == 0) intent = szfriends_intent_activate();
        if (intent) szfriends_gtk_link_send(app->link, intent, on_reply, g_strdup(tag ? tag : ""), g_free);
        else reply_event(tag, FALSE, NULL, "unsupported_intent");
    } else if (strcmp(name, "ui_type") == 0 && conversation) {
        ui_type(app, conversation, string_member(command, "text") ? string_member(command, "text") : "", tag);
    } else if (strcmp(name, "ui_texts") == 0 && conversation) {
        ui_texts(app, conversation, tag);
    } else if (strcmp(name, "ui_list") == 0) {
        ui_list(app, tag);
    } else if (strcmp(name, "paths") == 0) {
        /* Where this process's client library looks for Friends: the home and the socket it connects to. */
        char state[SZFRIENDS_PATH_CAP], socket_path[SZFRIENDS_PATH_CAP];
        gboolean found = szfriends_default_state_dir(state, sizeof state) == SZFRIENDS_OK &&
                         szfriends_socket_path(state, socket_path, sizeof socket_path, NULL) == SZFRIENDS_OK;
        JsonObject *result = NULL;
        if (found) {
            result = json_object_new();
            json_object_set_string_member(result, "state_dir", state);
            json_object_set_string_member(result, "socket_path", socket_path);
        }
        reply_event(tag, found, result, NULL);
    }
    if (node) json_node_unref(node);
    return keep_going;
}

static gboolean on_input(gint fd, GIOCondition condition, gpointer data) {
    SZFOGtkApp *app = data;
    char chunk[4096];
    ssize_t got = (condition & (G_IO_IN | G_IO_HUP)) ? read(fd, chunk, sizeof chunk) : 0;
    gboolean keep_going = got > 0; /* the scenario went away: so does the app */
    if (got > 0) g_string_append_len(app->input, chunk, got);
    char *newline;
    while (keep_going && (newline = strchr(app->input->str, '\n')) != NULL) {
        *newline = '\0';
        char *line = g_strdup(app->input->str);
        g_string_erase(app->input, 0, newline - app->input->str + 1);
        keep_going = run_command(app, line);
        g_free(line);
    }
    if (keep_going) return G_SOURCE_CONTINUE;
    app->input_source = 0;
    g_main_loop_quit(app->loop);
    return G_SOURCE_REMOVE;
}

static void install_button(gpointer data, GtkWindow *window, GtkWidget *button) {
    (void)window, (void)button, (void)data;
}

static void remove_button(gpointer data, GtkWindow *window, GtkWidget *button) {
    (void)window, (void)button, (void)data;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <embedded helper> <helper version> <helper build number>\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    /* Before GDK opens the display: prove the interposer stops it from making this a foreground app. */
    int before = szfriends_gtk_quiet_transform_calls();
    TransformProcessType(NULL, 0);
    if (szfriends_gtk_quiet_transform_calls() != before + 1) {
        fprintf(stderr, "%s: the quiet interposer is not active; not opening a display\n", argv[0]);
        return 2;
    }
    if (!gtk_init_check()) {
        fprintf(stderr, "%s: no display; this app needs a logged-in session\n", argv[0]);
        return 2;
    }
    adw_init();
    /* The launch path: connect-or-spawn on a worker thread, never waited for. */
    szfriends_gtk_spawn_helper_async(argv[1]);

    SZFriendsGtkHost host;
    memset(&host, 0, sizeof host);
    host.struct_size = sizeof host;
    host.app_id = "com.intuition.shenzhenfiles";
    host.app_name = "Shenzhen Files";
    host.app_version = "26.10.20";
    host.reveal_in_name = "Shenzhen Files";
    host.helper_path = argv[1];
    host.helper_version = argv[2];
    host.helper_build_number = g_ascii_strtoull(argv[3], NULL, 10);
    host.install_button = install_button;
    host.remove_button = remove_button;
    SZFOGtkApp app = {0};
    app.link = szfriends_gtk_link_new(&host);
    app.loop = g_main_loop_new(NULL, FALSE);
    app.input = g_string_new(NULL);
    if (!app.link) return 2;
    szfriends_gtk_link_add_state_watch(app.link, on_state, NULL, NULL);
    /* The window's own Friends button and dropdown, as Files makes them; never mapped. */
    app.window = gtk_window_new();
    app.button = szfriends_gtk_button_new(app.link, GTK_WINDOW(app.window));
    gtk_window_set_child(GTK_WINDOW(app.window), app.button);
    app.dropdown = szfriends_gtk_dropdown_for_button(app.button);
    static const SZFriendsGtkPresenter presenter = {present_nothing, dismiss_now};
    szfriends_gtk_dropdown_set_presenter(app.dropdown, &presenter, NULL);
    app.input_source = g_unix_fd_add(STDIN_FILENO, G_IO_IN | G_IO_HUP | G_IO_ERR, on_input, &app);
    szfriends_gtk_link_start(app.link);
    g_main_loop_run(app.loop);
    if (app.input_source) g_source_remove(app.input_source);
    szfriends_gtk_link_stop(app.link, FALSE);
    return 0;
}
