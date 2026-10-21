/* Helpers for friends-gtk-check (szfriends_gtk_support.h). */

#include "szfriends_gtk_support.h"

#include <glib/gstdio.h>
#include <string.h>
#include <unistd.h>

int szfg_failures;
const char *szfg_fixtures;
static int unexpected_warnings;
static gboolean warnings_expected;

static GLogWriterOutput log_writer(GLogLevelFlags level, const GLogField *fields, gsize n_fields, gpointer data) {
    (void)data;
    if ((level & (G_LOG_LEVEL_WARNING | G_LOG_LEVEL_CRITICAL | G_LOG_LEVEL_ERROR)) && !warnings_expected) {
        unexpected_warnings++;
        fprintf(stderr, "UNEXPECTED LOG ");
    }
    return g_log_writer_default(level, fields, n_fields, NULL); /* debug output only with G_MESSAGES_DEBUG */
}

void szfg_watch_logs(void) {
    g_log_set_writer_func(log_writer, NULL, NULL);
}

void szfg_expect_warnings(gboolean expected) {
    warnings_expected = expected;
}

int szfg_unexpected_warnings(void) {
    return unexpected_warnings;
}

char *szfg_temp_dir(const char *label) {
    char *template = g_strdup_printf("szfg-%s-XXXXXX", label);
    GError *error = NULL;
    char *path = g_dir_make_tmp(template, &error);
    g_free(template);
    EXPECT(path != NULL, "temporary directory: %s", error ? error->message : "?");
    g_clear_error(&error);
    if (path) g_chmod(path, 0700);
    return path;
}

void szfg_remove_tree(const char *path) {
    if (!path) return;
    GDir *dir = g_dir_open(path, 0, NULL);
    const char *name;
    while (dir && (name = g_dir_read_name(dir))) {
        char *child = g_build_filename(path, name, NULL);
        if (g_file_test(child, G_FILE_TEST_IS_DIR) && !g_file_test(child, G_FILE_TEST_IS_SYMLINK))
            szfg_remove_tree(child);
        else
            g_unlink(child);
        g_free(child);
    }
    if (dir) g_dir_close(dir);
    g_rmdir(path);
}

char *szfg_fixture_path(const char *relative) {
    return g_build_filename(szfg_fixtures, relative, NULL);
}

JsonObject *szfg_fixture(const char *relative) {
    char *path = szfg_fixture_path(relative), *text = NULL;
    gsize length = 0;
    JsonObject *object = NULL;
    if (g_file_get_contents(path, &text, &length, NULL)) object = szfriends_gtk_json_object_from_text(text, length);
    EXPECT(object != NULL, "fixture %s reads as a JSON object", relative);
    g_free(text);
    g_free(path);
    return object;
}

static gint compare_names(gconstpointer a, gconstpointer b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

GPtrArray *szfg_fixture_names(const char *directory) {
    GPtrArray *names = g_ptr_array_new_with_free_func(g_free);
    char *path = szfg_fixture_path(directory);
    GDir *dir = g_dir_open(path, 0, NULL);
    const char *name;
    while (dir && (name = g_dir_read_name(dir)))
        if (g_str_has_suffix(name, ".json")) g_ptr_array_add(names, g_build_filename(directory, name, NULL));
    if (dir) g_dir_close(dir);
    g_free(path);
    g_ptr_array_sort(names, compare_names);
    return names;
}

gboolean szfg_pump_until(gboolean (*done)(gpointer data), gpointer data, int timeout_ms) {
    gint64 deadline = g_get_monotonic_time() + (gint64)timeout_ms * 1000;
    while (!done(data)) {
        if (g_get_monotonic_time() >= deadline) return done(data);
        if (!g_main_context_iteration(NULL, FALSE)) g_usleep(2000);
    }
    return TRUE;
}

static gboolean never(gpointer data) {
    (void)data;
    return FALSE;
}

void szfg_pump_for(int milliseconds) {
    szfg_pump_until(never, NULL, milliseconds);
}

/* ---- Serializing through the tables -------------------------------------------------------------- */

static JsonNode *serialize_field(const SZFriendsGtkField *field, const guint8 *base) {
    const guint8 *slot = base + field->offset;
    JsonNode *node = json_node_new(JSON_NODE_VALUE);
    switch (field->kind) {
    case SZFRIENDS_GTK_FIELD_STRING:
    case SZFRIENDS_GTK_FIELD_STRING_NULL:
        if (*(char *const *)slot) json_node_set_string(node, *(char *const *)slot);
        else json_node_init_null(node);
        break;
    case SZFRIENDS_GTK_FIELD_BOOL: json_node_set_boolean(node, *(const gboolean *)slot); break;
    case SZFRIENDS_GTK_FIELD_INT: json_node_set_int(node, *(const gint64 *)slot); break;
    case SZFRIENDS_GTK_FIELD_OPT_INT: {
        const SZFriendsGtkOptInt *value = (const SZFriendsGtkOptInt *)slot;
        if (value->set) json_node_set_int(node, value->value);
        else json_node_init_null(node);
        break;
    }
    case SZFRIENDS_GTK_FIELD_NUMBER: json_node_set_double(node, *(const double *)slot); break;
    case SZFRIENDS_GTK_FIELD_ENUM: {
        const char *name = szfriends_gtk_enum_name(field->enums, *(const int *)slot);
        if (name) json_node_set_string(node, name);
        else json_node_init_null(node);
        break;
    }
    case SZFRIENDS_GTK_FIELD_OBJECT:
        json_node_unref(node);
        return szfg_serialize(field->type, slot);
    case SZFRIENDS_GTK_FIELD_OBJECT_NULL:
        json_node_unref(node);
        if (*(gconstpointer const *)slot) return szfg_serialize(field->type, *(gconstpointer const *)slot);
        return json_node_init_null(json_node_alloc());
    case SZFRIENDS_GTK_FIELD_ARRAY: {
        JsonArray *array = json_array_new();
        const guint8 *elements = *(const guint8 *const *)slot;
        gsize count = *(const gsize *)(base + field->count_offset);
        for (gsize i = 0; i < count; i++)
            json_array_add_element(array, szfg_serialize(field->type, elements + i * field->type->size));
        json_node_init_array(node, array);
        json_array_unref(array);
        break;
    }
    case SZFRIENDS_GTK_FIELD_STRINGS: {
        JsonArray *array = json_array_new();
        for (char *const *s = *(char **const *)slot; s && *s; s++) json_array_add_string_element(array, *s);
        json_node_init_array(node, array);
        json_array_unref(array);
        break;
    }
    case SZFRIENDS_GTK_FIELD_STRING_MAP: {
        JsonObject *object = json_object_new();
        GHashTableIter iter;
        gpointer key, value;
        g_hash_table_iter_init(&iter, *(GHashTable *const *)slot);
        while (g_hash_table_iter_next(&iter, &key, &value)) json_object_set_string_member(object, key, value);
        json_node_init_object(node, object);
        json_object_unref(object);
        break;
    }
    case SZFRIENDS_GTK_FIELD_JSON_OBJECT:
        if (*(JsonObject *const *)slot) json_node_init_object(node, *(JsonObject *const *)slot);
        else json_node_init_null(node);
        break;
    }
    return node;
}

JsonNode *szfg_serialize(const SZFriendsGtkType *type, gconstpointer value) {
    const guint8 *base = value;
    SZFriendsGtkPresence present = *(const SZFriendsGtkPresence *)base;
    JsonObject *object = json_object_new();
    for (gsize i = 0; i < type->n_fields; i++)
        if (present & ((SZFriendsGtkPresence)1 << i))
            json_object_set_member(object, type->fields[i].name, serialize_field(&type->fields[i], base));
    JsonNode *node = json_node_init_object(json_node_alloc(), object);
    json_object_unref(object);
    return node;
}

gboolean szfg_json_equal(JsonNode *a, JsonNode *b, GString *where) {
    /* A member or element only one side has: json_node_equal() takes no NULL. */
    if (!a || !b) return a == b;
    if (json_node_equal(a, b)) return TRUE;
    /* Narrow the difference down for the failure message. */
    if (a && b && JSON_NODE_HOLDS_OBJECT(a) && JSON_NODE_HOLDS_OBJECT(b)) {
        JsonObject *x = json_node_get_object(a), *y = json_node_get_object(b);
        GList *keys = g_list_concat(json_object_get_members(x), json_object_get_members(y));
        for (GList *key = keys; key; key = key->next) {
            gsize mark = where->len;
            g_string_append_printf(where, ".%s", (const char *)key->data);
            if (!szfg_json_equal(json_object_get_member(x, key->data), json_object_get_member(y, key->data), where)) {
                g_list_free(keys);
                return FALSE;
            }
            g_string_truncate(where, mark);
        }
        g_list_free(keys);
    } else if (a && b && JSON_NODE_HOLDS_ARRAY(a) && JSON_NODE_HOLDS_ARRAY(b)) {
        JsonArray *x = json_node_get_array(a), *y = json_node_get_array(b);
        guint n = MAX(json_array_get_length(x), json_array_get_length(y));
        for (guint i = 0; i < n; i++) {
            gsize mark = where->len;
            g_string_append_printf(where, "[%u]", i);
            JsonNode *p = i < json_array_get_length(x) ? json_array_get_element(x, i) : NULL;
            JsonNode *q = i < json_array_get_length(y) ? json_array_get_element(y, i) : NULL;
            if (!szfg_json_equal(p, q, where)) return FALSE;
            g_string_truncate(where, mark);
        }
    }
    return FALSE;
}

/* ---- The link harness ---------------------------------------------------------------------------- */

static void record_state(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    SZFGHarness *harness = data;
    (void)link;
    if (harness->n_states < G_N_ELEMENTS(harness->states)) harness->states[harness->n_states++] = state;
}

static SZFGHarness *harness_new(const char *label, const char *url_scheme) {
    SZFGHarness *harness = g_new0(SZFGHarness, 1);
    harness->state = szfg_temp_dir(label);
    g_setenv(SZFRIENDS_ENV_STATE_DIR, harness->state, TRUE);
    harness->host.struct_size = sizeof harness->host;
    harness->host.app_id = "com.intuition.shenzhenfiles";
    harness->host.app_name = "Shenzhen Files";
    harness->host.app_version = "26.10.13";
    harness->host.reveal_in_name = "Shenzhen Files";
    harness->host.url_scheme = url_scheme;
    harness->link = szfriends_gtk_link_new(&harness->host);
    szfriends_gtk_link_add_state_watch(harness->link, record_state, harness, NULL);
    return harness;
}

static gboolean start_fake(SZFGHarness *harness, const char *capabilities_json) {
    szfriends_fake_helper_config config = {0};
    config.state_dir = harness->state;
    config.fixtures_dir = szfg_fixtures;
    config.capabilities_json = capabilities_json;
    szfriends_status status = szfriends_fake_helper_start(&config, &harness->fake);
    EXPECT(status == SZFRIENDS_OK, "fake helper starts: %s", szfriends_status_name(status));
    return status == SZFRIENDS_OK;
}

SZFGHarness *szfg_harness_new(const char *label, gboolean start) {
    SZFGHarness *harness = harness_new(label, NULL);
    if (start) start_fake(harness, NULL);
    return harness;
}

SZFGHarness *szfg_harness_new_custom(const char *label, const char *url_scheme, const char *capabilities_json) {
    SZFGHarness *harness = harness_new(label, url_scheme);
    start_fake(harness, capabilities_json);
    return harness;
}

gboolean szfg_harness_start_fake(SZFGHarness *harness) {
    return start_fake(harness, NULL);
}

typedef struct {
    SZFGHarness *harness;
    SZFriendsGtkLinkState state;
    guint from;
} SZFGStateWait;

static gboolean saw_state(gpointer data) {
    SZFGStateWait *wait = data;
    for (guint i = wait->from; i < wait->harness->n_states; i++)
        if (wait->harness->states[i] == wait->state) return TRUE;
    return FALSE;
}

gboolean szfg_harness_wait_state(SZFGHarness *harness, SZFriendsGtkLinkState state, guint from, int timeout_ms) {
    SZFGStateWait wait = {harness, state, from};
    return szfg_pump_until(saw_state, &wait, timeout_ms);
}

gboolean szfg_harness_ready(SZFGHarness *harness, int timeout_ms) {
    guint from = harness->n_states;
    szfriends_gtk_link_start(harness->link);
    gboolean ready = szfg_harness_wait_state(harness, SZFRIENDS_GTK_LINK_READY, from, timeout_ms);
    EXPECT(ready, "the link reaches READY");
    return ready;
}

void szfg_harness_free(SZFGHarness *harness) {
    if (!harness) return;
    szfriends_gtk_link_free(harness->link);
    if (harness->fake) szfriends_fake_helper_stop(harness->fake);
    szfg_remove_tree(harness->state);
    g_free(harness->state);
    g_free(harness);
}

static JsonObject *fake_frame(SZFGHarness *harness, size_t index) {
    char *text = szfriends_fake_helper_copy_frame(harness->fake, index);
    JsonObject *frame = text ? szfriends_gtk_json_object_from_text(text, -1) : NULL;
    szfriends_free(text);
    return frame;
}

guint szfg_fake_frames(SZFGHarness *harness, const char *type, const char *key, const char *value) {
    guint count = 0;
    size_t total = harness->fake ? szfriends_fake_helper_frame_count(harness->fake) : 0;
    for (size_t i = 0; i < total; i++) {
        JsonObject *frame = fake_frame(harness, i);
        if (frame && g_strcmp0(json_object_get_string_member_with_default(frame, "type", ""), type) == 0 &&
            (!key || g_strcmp0(json_object_get_string_member_with_default(frame, key, NULL), value) == 0))
            count++;
        if (frame) json_object_unref(frame);
    }
    return count;
}

JsonObject *szfg_fake_last_frame(SZFGHarness *harness, const char *type) {
    size_t total = harness->fake ? szfriends_fake_helper_frame_count(harness->fake) : 0;
    for (size_t i = total; i > 0; i--) {
        JsonObject *frame = fake_frame(harness, i - 1);
        if (frame && g_strcmp0(json_object_get_string_member_with_default(frame, "type", ""), type) == 0) return frame;
        if (frame) json_object_unref(frame);
    }
    return NULL;
}
