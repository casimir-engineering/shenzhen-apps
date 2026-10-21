/* SZFriendsGtkLink: the C client library driven from the GLib main loop (szfriends_gtk_link.h).
 *
 * The library never calls back from a thread of its own (client/szfriends_client.h, threading). Its callbacks only
 * queue what happened; the queue is handled right after the library call returns, in order, so a snapshot handler
 * that subscribes or a state watch that stops the link never re-enters the library mid-dispatch (the AppKit
 * transport defers to the next turn of the main queue for the same reason). The descriptor changes on every
 * reconnect, so the watch is re-armed after every state change and whenever the number differs. */

#include "gtk/szfriends_gtk_link_private.h"
#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_internal.h"

#include <glib-unix.h>
#include <string.h>

typedef struct {
    gboolean is_state;
    szfriends_connection_state state;
    char *json;
    gsize length;
} SZFriendsGtkLinkEvent;

typedef struct {
    GtkWindow *window; /* weak */
    GtkWidget *button;
    SZFriendsGtkLink *link;
} SZFriendsGtkLinkWindow;

static void rearm(SZFriendsGtkLink *link, gboolean force);

/* ---- The host, copied ---------------------------------------------------------------------------- */

static const char *own_string(SZFriendsGtkLink *link, const char *text) {
    if (!text) return NULL;
    char *copy = g_strdup(text);
    g_ptr_array_add(link->owned, copy);
    return copy;
}

static const char *const *own_strv(SZFriendsGtkLink *link, const char *const *strings) {
    if (!strings) return NULL;
    char **copy = g_strdupv((char **)strings);
    g_ptr_array_add(link->owned, copy);
    g_ptr_array_add(link->owned, NULL); /* marks the entry before it as a strv for free_owned */
    return (const char *const *)copy;
}

static void free_owned(GPtrArray *owned) {
    for (guint i = 0; i < owned->len; i++) {
        gboolean strv = i + 1 < owned->len && g_ptr_array_index(owned, i + 1) == NULL;
        if (strv) g_strfreev(g_ptr_array_index(owned, i++));
        else g_free(g_ptr_array_index(owned, i));
    }
    g_ptr_array_free(owned, TRUE);
}

static void copy_host(SZFriendsGtkLink *link, const SZFriendsGtkHost *host) {
    memcpy(&link->host, host, MIN(host->struct_size, sizeof link->host));
    link->host.struct_size = sizeof link->host;
    SZFriendsGtkHost *h = &link->host;
    h->app_id = own_string(link, h->app_id);
    h->app_name = own_string(link, h->app_name);
    h->app_version = own_string(link, h->app_version);
    h->reveal_in_name = own_string(link, h->reveal_in_name);
    h->helper_path = own_string(link, h->helper_path);
    h->helper_version = own_string(link, h->helper_version);
    h->attach_placeholder = own_string(link, h->attach_placeholder);
    h->appearance_css = own_string(link, h->appearance_css);
    h->animals_manifest_path = own_string(link, h->animals_manifest_path);
    h->url_scheme = own_string(link, h->url_scheme);
    h->capabilities = own_strv(link, h->capabilities);
    h->open_formats = own_strv(link, h->open_formats);
    if (h->extra_drop_types && h->n_extra_drop_types) {
        GType *types = g_memdup2(h->extra_drop_types, h->n_extra_drop_types * sizeof(GType));
        g_ptr_array_add(link->owned, types);
        h->extra_drop_types = types;
    } else {
        h->extra_drop_types = NULL;
        h->n_extra_drop_types = 0;
    }
}

/* Client capabilities this host earns (PROTOCOL.md § Capabilities) when it does not list them itself. */
static GPtrArray *derived_capabilities(const SZFriendsGtkHost *host) {
    GPtrArray *list = g_ptr_array_new();
    if (host->capabilities) {
        for (const char *const *c = host->capabilities; *c; c++) g_ptr_array_add(list, (gpointer)*c);
        return list;
    }
    if (host->attachable_items) g_ptr_array_add(list, "attach.items");
    g_ptr_array_add(list, "drop.files");
    if (host->n_extra_drop_types) g_ptr_array_add(list, "drop.tabs");
    /* The conversation page draws mention links, opens their cards and offers @ (szfriends_gtk_conversation.h), so
     * every GTK host can show mentions; without the claim each one would arrive as plain text. */
    g_ptr_array_add(list, "mentions");
    /* Every list row's menu (Remove), on right-click, a long press, Shift+F10 or Delete (szfriends_gtk_row_menu.c). */
    g_ptr_array_add(list, "list.menu");
    /* How each person nearby was found, as icons and words on their row (szfriends_gtk_row.c). */
    g_ptr_array_add(list, "nearby.found");
    /* Get again on a friend's file the person moved or deleted (szfriends_gtk_actions.c). */
    g_ptr_array_add(list, "files.again");
    /* set_focus while a focused window's dropdown shows a conversation (szfriends_gtk_focus.c). */
    g_ptr_array_add(list, "notifications.focus");
#ifdef __APPLE__
    /* macOS asks before showing notifications: the list's banner with Turn On and Not Now
     * (szfriends_gtk_list_notices.c). Linux needs no permission, so no ask. */
    g_ptr_array_add(list, "notifications.ask");
#endif
    return list;
}

/* "en_GB.UTF-8" -> "en-GB"; "C" and "POSIX" -> "en" (BCP 47, PROTOCOL.md § Handshake). */
char *szfriends_gtk_bcp47_locale(const char *posix) {
    if (!posix || !*posix || strcmp(posix, "C") == 0 || strcmp(posix, "POSIX") == 0) return g_strdup("en");
    char *copy = g_strndup(posix, strcspn(posix, ".@"));
    for (char *c = copy; *c; c++)
        if (*c == '_') *c = '-';
    return copy;
}

/* ---- Lifetime ------------------------------------------------------------------------------------ */

SZFriendsGtkLink *szfriends_gtk_link_new(const SZFriendsGtkHost *host) {
    if (!host || host->struct_size < SZFRIENDS_GTK_HOST_MIN_SIZE || !host->app_id || !host->app_name ||
        !host->app_version || !host->reveal_in_name)
        return NULL;
    SZFriendsGtkLink *link = g_new0(SZFriendsGtkLink, 1);
    link->refs = 1; /* the host's */
    link->owned = g_ptr_array_new();
    copy_host(link, host);
    link->watched_fd = -1;
    g_queue_init(&link->events);
    link->strings = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    link->state_watches = g_ptr_array_new_with_free_func(szfriends_gtk_link_watch_free);
    link->windows = g_ptr_array_new();
    szfriends_gtk_link_routes_init(link);
    szfriends_gtk_pages_register_builtin(link);
    return link;
}

void szfriends_gtk_link_ref(SZFriendsGtkLink *link) {
    link->refs++;
}

static void free_now(SZFriendsGtkLink *link);

void szfriends_gtk_link_unref(SZFriendsGtkLink *link) {
    if (--link->refs == 0) free_now(link);
}

static void teardown_client(SZFriendsGtkLink *link) {
    if (link->fd_watch) g_source_remove(link->fd_watch);
    if (link->tick_source) g_source_remove(link->tick_source);
    link->fd_watch = link->tick_source = 0;
    link->watched_fd = -1;
    if (link->client) szfriends_client_free(link->client);
    link->client = NULL;
}

static void event_free(gpointer data) {
    SZFriendsGtkLinkEvent *event = data;
    g_free(event->json);
    g_free(event);
}

static void forget_windows(SZFriendsGtkLink *link, gboolean tell_host);

static void free_now(SZFriendsGtkLink *link) {
    forget_windows(link, FALSE);
    teardown_client(link);
    g_queue_clear_full(&link->events, event_free);
    szfriends_gtk_link_routes_clear(link);
    szfriends_gtk_pages_unregister(link);
    szfriends_gtk_animal_set_free(link->animals);
    szfriends_gtk_focus_clear(link);
    g_ptr_array_free(link->state_watches, TRUE);
    g_ptr_array_free(link->windows, TRUE);
    g_hash_table_unref(link->strings);
    g_strfreev(link->helper_capabilities);
    g_free(link->status_text);
    free_owned(link->owned);
    g_free(link);
}

void szfriends_gtk_link_free(SZFriendsGtkLink *link) {
    if (!link || link->closed) return;
    /* Everything stops now; what is left waits only for the buttons and pages still holding the link. */
    link->closed = TRUE;
    forget_windows(link, FALSE);
    teardown_client(link);
    szfriends_gtk_link_unref(link);
}

/* ---- Library callbacks: queue only --------------------------------------------------------------- */

static void on_frame(void *context, const char *json, size_t length) {
    SZFriendsGtkLink *link = context;
    SZFriendsGtkLinkEvent *event = g_new0(SZFriendsGtkLinkEvent, 1);
    event->json = g_strndup(json, length);
    event->length = length;
    g_queue_push_tail(&link->events, event);
}

static void on_state(void *context, szfriends_connection_state state) {
    SZFriendsGtkLink *link = context;
    SZFriendsGtkLinkEvent *event = g_new0(SZFriendsGtkLinkEvent, 1);
    event->is_state = TRUE;
    event->state = state;
    g_queue_push_tail(&link->events, event);
    link->rearm_requested = TRUE;
}

static SZFriendsGtkLinkState map_state(szfriends_connection_state state) {
    switch (state) {
    case SZFRIENDS_CONNECTION_IDLE: return SZFRIENDS_GTK_LINK_IDLE;
    case SZFRIENDS_CONNECTION_CONNECTING:
    case SZFRIENDS_CONNECTION_HANDSHAKING: return SZFRIENDS_GTK_LINK_CONNECTING;
    case SZFRIENDS_CONNECTION_READY: return SZFRIENDS_GTK_LINK_READY;
    case SZFRIENDS_CONNECTION_WAITING: return SZFRIENDS_GTK_LINK_WAITING;
    case SZFRIENDS_CONNECTION_INCOMPATIBLE: return SZFRIENDS_GTK_LINK_INCOMPATIBLE;
    }
    return SZFRIENDS_GTK_LINK_WAITING;
}

static void set_state(SZFriendsGtkLink *link, szfriends_connection_state raw) {
    SZFriendsGtkLinkState state = map_state(raw), previous = link->state;
    /* The app-specific line ("Update Shenzhen Files to use Friends.") exists only while the client still is
     * INCOMPATIBLE; otherwise the generic line for the state this event reported. */
    const char *text = raw == SZFRIENDS_CONNECTION_INCOMPATIBLE && link->client &&
                               szfriends_client_state(link->client) == SZFRIENDS_CONNECTION_INCOMPATIBLE
                           ? szfriends_client_state_text(link->client)
                           : szfriends_connection_state_text(raw);
    char *status = text && *text && state != SZFRIENDS_GTK_LINK_READY ? g_strdup(text) : NULL;
    gboolean changed = state != previous || g_strcmp0(status, link->status_text) != 0;
    g_free(link->status_text);
    link->status_text = status;
    link->state = state;
    /* READY: subscriptions go out before the views hear of it, so what they send next follows them. */
    if (state == SZFRIENDS_GTK_LINK_READY && previous != SZFRIENDS_GTK_LINK_READY) {
        szfriends_gtk_link_routes_ready(link);
        /* The helper forgot this connection's focus with the old one: say it again when there is one. */
        szfriends_gtk_focus_connected(link, TRUE);
    }
    szfriends_gtk_link_watches_begin(link);
    for (guint i = 0; changed && i < link->state_watches->len; i++) {
        SZFriendsGtkLinkWatch *watch = g_ptr_array_index(link->state_watches, i);
        if (watch->func) ((SZFriendsGtkStateFunc)watch->func)(link, state, watch->user_data);
    }
    szfriends_gtk_link_watches_end(link);
    /* Leaving READY: waiting replies get connection_lost after the state change, as PROTOCOL.md § Intents says. */
    if (previous == SZFRIENDS_GTK_LINK_READY && state != SZFRIENDS_GTK_LINK_READY) {
        szfriends_gtk_focus_connected(link, FALSE);
        szfriends_gtk_link_routes_left_ready(link);
    }
}

static void handle_frame(SZFriendsGtkLink *link, const char *json, gsize length) {
    JsonObject *frame = szfriends_gtk_json_object_from_text(json, (gssize)length);
    if (!frame) return;
    if (g_strcmp0(json_object_get_string_member_with_default(frame, "type", ""), "welcome") == 0) {
        SZFriendsGtkWelcome *welcome = szfriends_gtk_welcome_parse(frame);
        g_hash_table_unref(link->strings);
        link->strings = g_hash_table_ref(welcome->strings);
        g_strfreev(link->helper_capabilities);
        link->helper_capabilities = g_strdupv(welcome->capabilities);
        szfriends_gtk_welcome_free(welcome);
        /* Whether the helper takes set_focus is known only now. */
        if (link->state == SZFRIENDS_GTK_LINK_READY) szfriends_gtk_focus_update(link);
    } else {
        szfriends_gtk_link_route_frame(link, frame);
    }
    json_object_unref(frame);
}

static void drain(SZFriendsGtkLink *link) {
    if (link->draining) return; /* the outer loop picks up what this call queued */
    link->draining = TRUE;
    SZFriendsGtkLinkEvent *event;
    while (!link->closed && (event = g_queue_pop_head(&link->events))) {
        if (event->is_state) set_state(link, event->state);
        else handle_frame(link, event->json, event->length);
        event_free(event);
    }
    link->draining = FALSE;
}

void szfriends_gtk_link_after_call(SZFriendsGtkLink *link) {
    szfriends_gtk_link_ref(link);
    drain(link);
    if (!link->closed) rearm(link, FALSE);
    szfriends_gtk_link_unref(link);
}

/* ---- The descriptor watch and the timer ---------------------------------------------------------- */

static gboolean on_readable(int fd, GIOCondition condition, gpointer data) {
    (void)fd, (void)condition;
    SZFriendsGtkLink *link = data;
    if (link->client) szfriends_client_on_readable(link->client);
    szfriends_gtk_link_after_call(link);
    return G_SOURCE_CONTINUE; /* a re-arm removed this source already when the descriptor changed */
}

static gboolean on_tick(gpointer data) {
    SZFriendsGtkLink *link = data;
    link->tick_source = 0;
    if (link->client) szfriends_client_tick(link->client, szfriends_monotonic_ms());
    szfriends_gtk_link_after_call(link);
    return G_SOURCE_REMOVE;
}

static void rearm(SZFriendsGtkLink *link, gboolean force) {
    if (!link->client) return;
    int fd = szfriends_client_fd(link->client);
    if (force || link->rearm_requested || fd != link->watched_fd) {
        /* Recreated even when the number is unchanged after a state change: a closed and reopened socket can
         * reuse the number, and the old watch must not survive the connection it was made for. */
        if (link->fd_watch) g_source_remove(link->fd_watch);
        link->fd_watch = 0;
        link->watched_fd = fd;
        link->rearm_requested = FALSE;
        if (fd >= 0)
            link->fd_watch = g_unix_fd_add_full(G_PRIORITY_DEFAULT, fd, G_IO_IN | G_IO_HUP | G_IO_ERR, on_readable,
                                                link, NULL);
    }
    if (link->tick_source) g_source_remove(link->tick_source);
    link->tick_source = 0;
    int64_t wait = szfriends_client_next_tick_ms(link->client, szfriends_monotonic_ms());
    if (wait >= 0) link->tick_source = g_timeout_add_full(G_PRIORITY_DEFAULT, (guint)MAX(wait, 1), on_tick, link, NULL);
}

/* ---- Start and stop ------------------------------------------------------------------------------ */

void szfriends_gtk_link_start(SZFriendsGtkLink *link) {
    if (!link || link->client || link->closed) return;
    const SZFriendsGtkHost *host = &link->host;
    GPtrArray *capabilities = derived_capabilities(host);
    char *locale = szfriends_gtk_bcp47_locale(g_get_language_names()[0]);
    szfriends_client_config config = {0};
    config.helper_path = host->helper_path;
    config.helper_version = host->helper_version;
    config.helper_build_number = host->helper_build_number;
    config.helper_protocol_major = SZFRIENDS_PROTOCOL_MAJOR;
    config.helper_protocol_minor = SZFRIENDS_PROTOCOL_MINOR;
    config.app_id = host->app_id;
    config.app_name = host->app_name;
    config.app_version = host->app_version;
    config.toolkit = "gtk4";
    config.reveal_in = host->reveal_in_name;
    config.locale = locale;
    config.capabilities = (const char *const *)capabilities->pdata;
    config.capability_count = capabilities->len;
    config.open_formats = host->open_formats;
    config.open_format_count = host->open_formats ? g_strv_length((char **)host->open_formats) : 0;
    config.url_scheme = host->url_scheme;
    config.on_frame = on_frame;
    config.on_state = on_state;
    config.context = link;
    link->client = szfriends_client_new(&config); /* copies every string it keeps */
    g_ptr_array_free(capabilities, TRUE);
    g_free(locale);
    if (!link->client) return;
    szfriends_gtk_link_ref(link);
    szfriends_client_start(link->client);
    szfriends_gtk_link_after_call(link);
    if (!link->closed) rearm(link, TRUE);
    szfriends_gtk_link_unref(link);
}

void szfriends_gtk_link_stop(SZFriendsGtkLink *link, gboolean friends_disabled) {
    if (!link || !link->client) return;
    szfriends_gtk_link_ref(link);
    szfriends_client_stop(link->client, friends_disabled);
    szfriends_gtk_link_after_call(link); /* IDLE: waiting replies get connection_lost now */
    teardown_client(link);
    if (friends_disabled) forget_windows(link, TRUE);
    szfriends_gtk_link_unref(link);
}

/* ---- Getters and watches ------------------------------------------------------------------------- */

SZFriendsGtkLinkState szfriends_gtk_link_get_state(SZFriendsGtkLink *link) {
    return link ? link->state : SZFRIENDS_GTK_LINK_IDLE;
}

const char *szfriends_gtk_link_status_text(SZFriendsGtkLink *link) {
    return link ? link->status_text : NULL;
}

const char *szfriends_gtk_link_string(SZFriendsGtkLink *link, const char *key) {
    const char *value = link && key ? g_hash_table_lookup(link->strings, key) : NULL;
    return value ? value : "";
}

gboolean szfriends_gtk_link_helper_has_capability(SZFriendsGtkLink *link, const char *capability) {
    return link && link->helper_capabilities && capability &&
           g_strv_contains((const char *const *)link->helper_capabilities, capability);
}

const SZFriendsGtkHost *szfriends_gtk_link_host(SZFriendsGtkLink *link) {
    return link ? &link->host : NULL;
}

int szfriends_gtk_link_watched_fd(SZFriendsGtkLink *link) {
    return link && link->fd_watch ? link->watched_fd : -1;
}

int szfriends_gtk_link_client_fd(SZFriendsGtkLink *link) {
    return link && link->client ? szfriends_client_fd(link->client) : -1;
}

void szfriends_gtk_link_watch_free(gpointer data) {
    SZFriendsGtkLinkWatch *watch = data;
    if (watch->destroy) watch->destroy(watch->user_data);
    g_free(watch);
}

guint szfriends_gtk_link_add_state_watch(SZFriendsGtkLink *link, SZFriendsGtkStateFunc func, gpointer user_data,
                                         GDestroyNotify destroy) {
    SZFriendsGtkLinkWatch *watch = g_new0(SZFriendsGtkLinkWatch, 1);
    watch->id = ++link->next_watch;
    watch->func = (gpointer)func;
    watch->user_data = user_data;
    watch->destroy = destroy;
    g_ptr_array_add(link->state_watches, watch);
    return watch->id;
}

void szfriends_gtk_link_remove_state_watch(SZFriendsGtkLink *link, guint id) {
    if (link) szfriends_gtk_link_watches_remove(link, link->state_watches, id);
}

void szfriends_gtk_link_watches_begin(SZFriendsGtkLink *link) {
    link->notifying++;
}

static void sweep(GPtrArray *watches) {
    for (guint i = watches->len; i > 0; i--)
        if (!((SZFriendsGtkLinkWatch *)g_ptr_array_index(watches, i - 1))->func)
            g_ptr_array_remove_index(watches, i - 1);
}

void szfriends_gtk_link_watches_end(SZFriendsGtkLink *link) {
    if (--link->notifying) return;
    sweep(link->state_watches);
    sweep(link->badge_watches);
}

void szfriends_gtk_link_watches_remove(SZFriendsGtkLink *link, GPtrArray *watches, guint id) {
    for (guint i = 0; i < watches->len; i++) {
        SZFriendsGtkLinkWatch *watch = g_ptr_array_index(watches, i);
        if (watch->id != id) continue;
        if (!link->notifying) {
            g_ptr_array_remove_index(watches, i);
            return;
        }
        /* Silenced now, released after the run: the run is iterating this array. */
        watch->func = NULL;
        if (watch->destroy) watch->destroy(watch->user_data);
        watch->destroy = NULL;
        return;
    }
}

/* ---- One button per window ----------------------------------------------------------------------- */

static void window_gone(gpointer data, GObject *where_the_window_was) {
    SZFriendsGtkLinkWindow *entry = data;
    (void)where_the_window_was;
    g_ptr_array_remove(entry->link->windows, entry);
    g_free(entry);
}

void szfriends_gtk_link_add_window(SZFriendsGtkLink *link, GtkWindow *window) {
    if (!link || !window) return;
    for (guint i = 0; i < link->windows->len; i++)
        if (((SZFriendsGtkLinkWindow *)g_ptr_array_index(link->windows, i))->window == window) return;
    SZFriendsGtkLinkWindow *entry = g_new0(SZFriendsGtkLinkWindow, 1);
    entry->window = window;
    entry->link = link;
    entry->button = szfriends_gtk_button_new(link, window);
    g_object_weak_ref(G_OBJECT(window), window_gone, entry);
    g_ptr_array_add(link->windows, entry);
    if (link->host.install_button) link->host.install_button(link->host.host_data, window, entry->button);
}

static void drop_window(SZFriendsGtkLink *link, guint index, gboolean tell_host) {
    SZFriendsGtkLinkWindow *entry = g_ptr_array_index(link->windows, index);
    g_ptr_array_remove_index(link->windows, index);
    g_object_weak_unref(G_OBJECT(entry->window), window_gone, entry);
    if (tell_host && link->host.remove_button) link->host.remove_button(link->host.host_data, entry->window,
                                                                        entry->button);
    g_free(entry);
}

void szfriends_gtk_link_remove_window(SZFriendsGtkLink *link, GtkWindow *window) {
    for (guint i = 0; link && i < link->windows->len; i++)
        if (((SZFriendsGtkLinkWindow *)g_ptr_array_index(link->windows, i))->window == window) {
            drop_window(link, i, TRUE);
            return;
        }
}

GtkWidget *szfriends_gtk_link_window_button(SZFriendsGtkLink *link, GtkWindow *window) {
    for (guint i = 0; link && i < link->windows->len; i++) {
        SZFriendsGtkLinkWindow *entry = g_ptr_array_index(link->windows, i);
        if (!window || entry->window == window) return entry->button;
    }
    return NULL;
}

static void forget_windows(SZFriendsGtkLink *link, gboolean tell_host) {
    while (link->windows->len) drop_window(link, link->windows->len - 1, tell_host);
}
