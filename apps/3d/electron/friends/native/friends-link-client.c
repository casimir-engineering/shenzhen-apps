/* The Friends client object of Shenzhen 3D's addon: the pinned client library driven from the main process's libuv
 * loop (friends-link.c says how), with start, stop, close, send and state for JavaScript. */

#include "friends-link.h"

#include <uv.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "client/szfriends_client.h"

static const char *state_name(szfriends_connection_state state) {
    switch (state) {
    case SZFRIENDS_CONNECTION_CONNECTING: return "connecting";
    case SZFRIENDS_CONNECTION_HANDSHAKING: return "handshaking";
    case SZFRIENDS_CONNECTION_READY: return "ready";
    case SZFRIENDS_CONNECTION_WAITING: return "waiting";
    case SZFRIENDS_CONNECTION_INCOMPATIBLE: return "incompatible";
    case SZFRIENDS_CONNECTION_IDLE:
    default: return "idle";
    }
}

/* ---- Client ------------------------------------------------------------------------------------------------- */

typedef struct Event {
    bool frame;
    szfriends_connection_state state;
    char *json;
    size_t length;
} Event;

typedef struct Link {
    napi_env env;
    napi_ref self;     /* strong while open, so a running client is never collected; weak once closed */
    napi_ref callback; /* onEvents(events) */
    napi_async_context async;
    szfriends_client *client;
    uv_loop_t *loop;
    uv_timer_t *timer;
    uv_poll_t *poll;
    int poll_fd;
    bool rearm;
    bool poll_failed;
    Event *events;
    size_t count, cap;
    bool closed;
    int dispatching;
    bool free_pending;
} Link;

static void free_handle(uv_handle_t *handle) { free(handle); }

static void push_event(Link *link, bool frame, szfriends_connection_state state, const char *json, size_t length) {
    if (link->count == link->cap) {
        size_t cap = link->cap ? link->cap * 2 : 16;
        Event *events = realloc(link->events, cap * sizeof *events);
        if (!events) return;
        link->events = events;
        link->cap = cap;
    }
    Event *event = &link->events[link->count];
    event->frame = frame;
    event->state = state;
    event->json = NULL;
    event->length = 0;
    if (frame) {
        event->json = malloc(length + 1);
        if (!event->json) return;
        memcpy(event->json, json, length);
        event->json[length] = '\0';
        event->length = length;
    }
    link->count++;
}

static void on_frame(void *context, const char *json, size_t length) { push_event(context, true, 0, json, length); }

static void on_state(void *context, szfriends_connection_state state) {
    Link *link = context;
    link->rearm = true; /* the descriptor may be new even when its number is not */
    push_event(link, false, state, NULL, 0);
}

static void clear_events(Link *link) {
    for (size_t i = 0; i < link->count; i++) free(link->events[i].json);
    link->count = 0;
}

static void link_release(napi_env env, Link *link) {
    if (link->events) {
        clear_events(link);
        free(link->events);
    }
    if (link->callback) napi_delete_reference(env, link->callback);
    if (link->async) napi_async_destroy(env, link->async);
    free(link);
}

static void poll_cb(uv_poll_t *handle, int status, int events);
static void timer_cb(uv_timer_t *handle);

static void rearm_poll(Link *link) {
    int fd = link->client ? szfriends_client_fd(link->client) : -1;
    if (!link->rearm && fd == link->poll_fd && (link->poll || fd < 0)) return;
    link->rearm = false;
    if (link->poll) {
        uv_poll_stop(link->poll);
        link->poll->data = NULL;
        uv_close((uv_handle_t *)link->poll, free_handle);
        link->poll = NULL;
    }
    link->poll_fd = fd;
    link->poll_failed = false;
    if (fd < 0) return;
    uv_poll_t *poll = calloc(1, sizeof *poll);
    if (poll && uv_poll_init(link->loop, poll, fd) == 0) {
        poll->data = link;
        uv_unref((uv_handle_t *)poll);
        if (uv_poll_start(poll, UV_READABLE | UV_DISCONNECT, poll_cb) == 0) {
            link->poll = poll;
            return;
        }
        uv_close((uv_handle_t *)poll, free_handle);
    } else {
        free(poll);
    }
    /* Fall back to reading on short ticks rather than going deaf: on_readable never blocks. */
    link->poll_failed = true;
}

static void schedule(Link *link) {
    if (link->closed || !link->timer) return;
    int64_t ms = link->client ? szfriends_client_next_tick_ms(link->client, szfriends_monotonic_ms()) : -1;
    if (link->count) ms = 0;
    if (link->poll_failed && (ms < 0 || ms > 15)) ms = 15;
    if (ms < 0) uv_timer_stop(link->timer);
    else uv_timer_start(link->timer, timer_cb, (uint64_t)ms, 0);
}

/* Hands every queued event to JavaScript in one call. Runs only from libuv callbacks, outside any library call. */
static void flush(Link *link) {
    if (!link->count || !link->callback) return;
    napi_env env = link->env;
    napi_handle_scope scope;
    if (napi_open_handle_scope(env, &scope) != napi_ok) return;
    napi_value events, callback, global, item, value;
    size_t count = link->count;
    napi_create_array_with_length(env, count, &events);
    for (size_t i = 0; i < count; i++) {
        Event *event = &link->events[i];
        napi_create_object(env, &item);
        if (event->frame) {
            napi_set_named_property(env, item, "type", make_string(env, "frame"));
            napi_create_string_utf8(env, event->json ? event->json : "", event->length, &value);
            napi_set_named_property(env, item, "json", value);
        } else {
            napi_set_named_property(env, item, "type", make_string(env, "state"));
            napi_set_named_property(env, item, "state", make_string(env, state_name(event->state)));
        }
        napi_set_element(env, events, (uint32_t)i, item);
    }
    clear_events(link);
    if (link->client) {
        /* The text for the state now, with the app named where the person has to act. */
        napi_set_named_property(env, events, "stateText", make_string(env, szfriends_client_state_text(link->client)));
    }
    napi_get_reference_value(env, link->callback, &callback);
    napi_get_global(env, &global);
    link->dispatching++;
    napi_status status = napi_make_callback(env, link->async, global, callback, 1, &events, NULL);
    link->dispatching--;
    if (status == napi_pending_exception) {
        napi_value ignored;
        napi_get_and_clear_last_exception(env, &ignored);
    }
    napi_close_handle_scope(env, scope);
}

static void after_loop_call(Link *link) {
    if (link->closed) return;
    rearm_poll(link);
    flush(link);
    if (link->free_pending && !link->dispatching) {
        link_release(link->env, link);
        return;
    }
    if (!link->closed) {
        rearm_poll(link);
        schedule(link);
    }
}

static void poll_cb(uv_poll_t *handle, int status, int events) {
    (void)status;
    (void)events;
    Link *link = handle->data;
    if (!link || link->closed || !link->client) return;
    szfriends_client_on_readable(link->client);
    after_loop_call(link);
}

static void timer_cb(uv_timer_t *handle) {
    Link *link = handle->data;
    if (!link || link->closed) return;
    if (link->client) {
        if (link->poll_failed) szfriends_client_on_readable(link->client);
        szfriends_client_tick(link->client, szfriends_monotonic_ms());
    }
    after_loop_call(link);
}

/* After a call from JavaScript: events it produced are delivered on the next loop turn, never re-entrantly. */
static void after_js_call(Link *link) {
    if (link->closed) return;
    rearm_poll(link);
    schedule(link);
}

static void close_link(Link *link) {
    if (link->closed) return;
    link->closed = true;
    if (link->client) {
        szfriends_client_stop(link->client, false);
        szfriends_client_free(link->client);
        link->client = NULL;
    }
    if (link->poll) {
        uv_poll_stop(link->poll);
        link->poll->data = NULL;
        uv_close((uv_handle_t *)link->poll, free_handle);
        link->poll = NULL;
    }
    if (link->timer) {
        uv_timer_stop(link->timer);
        link->timer->data = NULL;
        uv_close((uv_handle_t *)link->timer, free_handle);
        link->timer = NULL;
    }
    clear_events(link);
    if (link->self) napi_reference_unref(link->env, link->self, NULL);
}

static void finalize_link(napi_env env, void *data, void *hint) {
    (void)hint;
    Link *link = data;
    close_link(link);
    if (link->self) {
        napi_delete_reference(env, link->self);
        link->self = NULL;
    }
    if (link->dispatching) link->free_pending = true;
    else link_release(env, link);
}

static Link *unwrap(napi_env env, napi_callback_info info, size_t *argc, napi_value *argv) {
    napi_value self;
    Link *link = NULL;
    if (napi_get_cb_info(env, info, argc, argv, &self, NULL) != napi_ok) return NULL;
    if (napi_unwrap(env, self, (void **)&link) != napi_ok) return NULL;
    return link;
}

static napi_value link_start(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    Link *link = unwrap(env, info, &argc, NULL);
    if (!link || link->closed) return make_string(env, "closed");
    szfriends_status status = szfriends_client_start(link->client);
    after_js_call(link);
    return make_string(env, szfriends_status_name(status));
}

static napi_value link_stop(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    bool disabling = false;
    Link *link = unwrap(env, info, &argc, argv);
    if (!link || link->closed) return make_string(env, "closed");
    if (argc > 0) napi_get_value_bool(env, argv[0], &disabling);
    szfriends_status status = szfriends_client_stop(link->client, disabling);
    after_js_call(link);
    return make_string(env, szfriends_status_name(status));
}

static napi_value link_close(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    Link *link = unwrap(env, info, &argc, NULL);
    if (link) close_link(link);
    return NULL;
}

/* send(type, fieldsJson): {status, id}. The library adds "type" and a fresh "id"; the reply arrives as a frame. */
static napi_value link_send(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2], result;
    Link *link = unwrap(env, info, &argc, argv);
    napi_create_object(env, &result);
    if (!link || link->closed || argc < 2) {
        napi_set_named_property(env, result, "status", make_string(env, "closed"));
        return result;
    }
    size_t length = 0;
    char *type = string_arg(env, argv[0]);
    char *fields = NULL;
    if (napi_get_value_string_utf8(env, argv[1], NULL, 0, &length) == napi_ok && length <= SZFRIENDS_MAX_FRAME_BYTES) {
        fields = malloc(length + 1);
        if (fields && napi_get_value_string_utf8(env, argv[1], fields, length + 1, &length) != napi_ok) {
            free(fields);
            fields = NULL;
        }
    }
    char id[32] = {0};
    szfriends_status status = SZFRIENDS_ERR_FRAME_TOO_LARGE;
    if (type && fields) status = szfriends_client_send(link->client, type, fields, id, sizeof id);
    else if (fields) status = SZFRIENDS_ERR_INVALID_ARGUMENT;
    free(type);
    free(fields);
    napi_set_named_property(env, result, "status", make_string(env, szfriends_status_name(status)));
    if (status == SZFRIENDS_OK) napi_set_named_property(env, result, "id", make_string(env, id));
    after_js_call(link);
    return result;
}

static napi_value link_state(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    Link *link = unwrap(env, info, &argc, NULL);
    napi_value result;
    napi_create_object(env, &result);
    szfriends_connection_state state = link && link->client ? szfriends_client_state(link->client)
                                                            : SZFRIENDS_CONNECTION_IDLE;
    napi_set_named_property(env, result, "state", make_string(env, state_name(state)));
    napi_set_named_property(env, result, "text",
                            make_string(env, link && link->client ? szfriends_client_state_text(link->client) : ""));
    int major = 0, minor = 0;
    if (link && link->client) szfriends_client_protocol(link->client, &major, &minor);
    napi_value number;
    napi_create_int32(env, major, &number);
    napi_set_named_property(env, result, "major", number);
    napi_create_int32(env, minor, &number);
    napi_set_named_property(env, result, "minor", number);
    return result;
}

static char *config_string(napi_env env, napi_value object, const char *key) {
    napi_value value;
    bool has = false;
    if (napi_has_named_property(env, object, key, &has) != napi_ok || !has) return NULL;
    if (napi_get_named_property(env, object, key, &value) != napi_ok) return NULL;
    return string_arg(env, value);
}

/* A JavaScript array of strings as a C array; *count is set. NULL with *count 0 when absent. */
static char **config_strings(napi_env env, napi_value object, const char *key, size_t max, size_t *count) {
    napi_value value, item;
    bool has = false, array = false;
    uint32_t length = 0;
    *count = 0;
    if (napi_has_named_property(env, object, key, &has) != napi_ok || !has) return NULL;
    if (napi_get_named_property(env, object, key, &value) != napi_ok) return NULL;
    if (napi_is_array(env, value, &array) != napi_ok || !array) return NULL;
    napi_get_array_length(env, value, &length);
    if (length > max) length = (uint32_t)max;
    char **strings = calloc(length ? length : 1, sizeof *strings);
    if (!strings) return NULL;
    for (uint32_t i = 0; i < length; i++) {
        if (napi_get_element(env, value, i, &item) == napi_ok) {
            char *text = string_arg(env, item);
            if (text) strings[(*count)++] = text;
        }
    }
    return strings;
}

static void free_strings(char **strings, size_t count) {
    for (size_t i = 0; i < count; i++) free(strings[i]);
    free(strings);
}

/* createClient(config, onEvents): a client object with start, stop, close, send and state. */
napi_value create_client(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2], object = NULL, name, fn;
    napi_valuetype type;
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) return NULL;
    if (napi_typeof(env, argv[1], &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, NULL, "createClient needs an event callback");
        return NULL;
    }
    Link *link = calloc(1, sizeof *link);
    if (!link) return NULL;
    link->env = env;
    link->poll_fd = -1;
    napi_value config = argv[0];
    char *state_dir = config_string(env, config, "stateDir");
    char *helper_path = config_string(env, config, "helperPath");
    char *helper_version = config_string(env, config, "helperVersion");
    char *app_id = config_string(env, config, "appId");
    char *app_name = config_string(env, config, "appName");
    char *app_version = config_string(env, config, "appVersion");
    char *toolkit = config_string(env, config, "toolkit");
    char *reveal_in = config_string(env, config, "revealIn");
    char *locale = config_string(env, config, "locale");
    char *url_scheme = config_string(env, config, "urlScheme");
    size_t capability_count = 0, format_count = 0;
    char **capabilities = config_strings(env, config, "capabilities", 64, &capability_count);
    char **formats = config_strings(env, config, "openFormats", SZFRIENDS_MAX_OPEN_FORMATS, &format_count);
    double build = 0;
    napi_value build_value;
    bool has_build = false;
    if (napi_has_named_property(env, config, "helperBuildNumber", &has_build) == napi_ok && has_build &&
        napi_get_named_property(env, config, "helperBuildNumber", &build_value) == napi_ok)
        napi_get_value_double(env, build_value, &build);

    szfriends_client_config c = {0};
    c.state_dir = state_dir;
    c.helper_path = helper_path;
    c.helper_version = helper_version ? helper_version : "0";
    /* Missing: build 0, which never wins a handover. */
    c.helper_build_number = build > 0 && build < 9007199254740992.0 ? (uint64_t)build : 0;
    c.helper_protocol_major = SZFRIENDS_PROTOCOL_MAJOR;
    c.helper_protocol_minor = SZFRIENDS_PROTOCOL_MINOR;
    c.app_id = app_id;
    c.app_name = app_name;
    c.app_version = app_version;
    c.toolkit = toolkit;
    c.reveal_in = reveal_in;
    c.locale = locale;
    c.url_scheme = url_scheme; /* NULL: hello carries no url_scheme */
    c.capabilities = (const char *const *)capabilities;
    c.capability_count = capability_count;
    c.open_formats = (const char *const *)formats;
    c.open_format_count = format_count;
    c.on_frame = on_frame;
    c.on_state = on_state;
    c.context = link;
    link->client = szfriends_client_new(&c); /* copies every string it keeps */
    free(state_dir);
    free(helper_path);
    free(helper_version);
    free(app_id);
    free(app_name);
    free(app_version);
    free(toolkit);
    free(reveal_in);
    free(locale);
    free(url_scheme);
    free_strings(capabilities, capability_count);
    free_strings(formats, format_count);
    if (!link->client) {
        free(link);
        napi_throw_error(env, NULL, "the Friends client needs appId, appName, appVersion, toolkit and revealIn");
        return NULL;
    }
    if (napi_get_uv_event_loop(env, &link->loop) != napi_ok) goto fail_client;
    link->timer = calloc(1, sizeof *link->timer);
    if (!link->timer || uv_timer_init(link->loop, link->timer) != 0) {
        free(link->timer);
        link->timer = NULL;
        goto fail_client;
    }
    link->timer->data = link;
    /* Friends never keeps a process alive by itself: Electron quits on its own terms, and so do test scripts. */
    uv_unref((uv_handle_t *)link->timer);
    CHECK(napi_create_reference(env, argv[1], 1, &link->callback));
    CHECK(napi_create_string_utf8(env, "szfriends.events", NAPI_AUTO_LENGTH, &name));
    CHECK(napi_async_init(env, NULL, name, &link->async));
    CHECK(napi_create_object(env, &object));
    const struct {
        const char *name;
        napi_callback callback;
    } methods[] = {{"start", link_start}, {"stop", link_stop},   {"close", link_close},
                   {"send", link_send},   {"state", link_state}};
    for (size_t i = 0; i < sizeof methods / sizeof methods[0]; i++) {
        CHECK(napi_create_function(env, methods[i].name, NAPI_AUTO_LENGTH, methods[i].callback, NULL, &fn));
        CHECK(napi_set_named_property(env, object, methods[i].name, fn));
    }
    CHECK(napi_wrap(env, object, link, finalize_link, NULL, NULL));
    CHECK(napi_create_reference(env, object, 1, &link->self));
    return object;
fail:
    close_link(link);
    link_release(env, link);
    return NULL;
fail_client:
    szfriends_client_free(link->client);
    free(link);
    return NULL;
}
