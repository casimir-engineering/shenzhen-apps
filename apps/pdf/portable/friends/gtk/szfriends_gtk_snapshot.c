/* The one walker that parses and frees every struct in szfriends_gtk_snapshot.h from its field table.
 *
 * Lenient as PROTOCOL.md § Principles asks: unknown fields are ignored, a value of the wrong type reads as empty, an
 * unknown enum name reads as 0, so a newer helper or a damaged frame makes a view draw less, never crash. */

#include "gtk/szfriends_gtk_schema.h"

#include <string.h>

static void parse_object(const SZFriendsGtkType *type, JsonObject *object, guint8 *base);
static void free_object(const SZFriendsGtkType *type, guint8 *base);

static const char *node_string(JsonNode *node) {
    if (!node || !JSON_NODE_HOLDS_VALUE(node) || json_node_get_value_type(node) != G_TYPE_STRING) return NULL;
    return json_node_get_string(node);
}

static gboolean node_integer(JsonNode *node, gint64 *out) {
    if (!node || !JSON_NODE_HOLDS_VALUE(node)) return FALSE;
    GType type = json_node_get_value_type(node);
    if (type == G_TYPE_INT64) {
        *out = json_node_get_int(node);
        return TRUE;
    }
    if (type == G_TYPE_DOUBLE) {
        /* "1.0" is the same JSON number as 1; anything with a fraction is not an integer. */
        double value = json_node_get_double(node);
        if (value != (double)(gint64)value) return FALSE;
        *out = (gint64)value;
        return TRUE;
    }
    return FALSE;
}

static JsonObject *node_object(JsonNode *node) {
    return node && JSON_NODE_HOLDS_OBJECT(node) ? json_node_get_object(node) : NULL;
}

static void parse_array(const SZFriendsGtkField *field, JsonNode *node, guint8 *slot, guint8 *base) {
    JsonArray *array = node && JSON_NODE_HOLDS_ARRAY(node) ? json_node_get_array(node) : NULL;
    guint length = array ? json_array_get_length(array) : 0;
    guint8 *elements = length ? g_malloc0((gsize)length * field->type->size) : NULL;
    for (guint i = 0; i < length; i++)
        parse_object(field->type, node_object(json_array_get_element(array, i)), elements + i * field->type->size);
    *(guint8 **)slot = elements;
    *(gsize *)(base + field->count_offset) = length;
}

static char **parse_strings(JsonNode *node) {
    JsonArray *array = node && JSON_NODE_HOLDS_ARRAY(node) ? json_node_get_array(node) : NULL;
    GPtrArray *strings = g_ptr_array_new();
    for (guint i = 0; array && i < json_array_get_length(array); i++) {
        const char *value = node_string(json_array_get_element(array, i));
        if (value) g_ptr_array_add(strings, g_strdup(value));
    }
    g_ptr_array_add(strings, NULL);
    return (char **)g_ptr_array_free(strings, FALSE);
}

static GHashTable *parse_string_map(JsonObject *object) {
    GHashTable *map = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    if (!object) return map;
    JsonObjectIter iter;
    const char *key;
    JsonNode *value;
    json_object_iter_init(&iter, object);
    while (json_object_iter_next(&iter, &key, &value)) {
        const char *text = node_string(value);
        if (text) g_hash_table_insert(map, g_strdup(key), g_strdup(text));
    }
    return map;
}

static void parse_field(const SZFriendsGtkField *field, JsonNode *node, guint8 *base) {
    guint8 *slot = base + field->offset;
    gint64 integer = 0;
    switch (field->kind) {
    case SZFRIENDS_GTK_FIELD_STRING: {
        const char *text = node_string(node);
        *(char **)slot = g_strdup(text ? text : "");
        break;
    }
    case SZFRIENDS_GTK_FIELD_STRING_NULL:
        *(char **)slot = g_strdup(node_string(node));
        break;
    case SZFRIENDS_GTK_FIELD_BOOL:
        *(gboolean *)slot = node && JSON_NODE_HOLDS_VALUE(node) && json_node_get_value_type(node) == G_TYPE_BOOLEAN &&
                            json_node_get_boolean(node);
        break;
    case SZFRIENDS_GTK_FIELD_INT:
        *(gint64 *)slot = node_integer(node, &integer) ? integer : 0;
        break;
    case SZFRIENDS_GTK_FIELD_OPT_INT: {
        SZFriendsGtkOptInt *value = (SZFriendsGtkOptInt *)slot;
        value->set = node_integer(node, &integer);
        value->value = value->set ? integer : 0;
        break;
    }
    case SZFRIENDS_GTK_FIELD_NUMBER:
        if (node && JSON_NODE_HOLDS_VALUE(node) &&
            (json_node_get_value_type(node) == G_TYPE_DOUBLE || json_node_get_value_type(node) == G_TYPE_INT64))
            *(double *)slot = json_node_get_double(node);
        break;
    case SZFRIENDS_GTK_FIELD_ENUM:
        *(int *)slot = szfriends_gtk_enum_value(field->enums, node_string(node));
        break;
    case SZFRIENDS_GTK_FIELD_OBJECT:
        parse_object(field->type, node_object(node), slot);
        break;
    case SZFRIENDS_GTK_FIELD_OBJECT_NULL:
        if (node_object(node)) {
            guint8 *value = g_malloc0(field->type->size);
            parse_object(field->type, node_object(node), value);
            *(guint8 **)slot = value;
        }
        break;
    case SZFRIENDS_GTK_FIELD_ARRAY:
        parse_array(field, node, slot, base);
        break;
    case SZFRIENDS_GTK_FIELD_STRINGS:
        *(char ***)slot = parse_strings(node);
        break;
    case SZFRIENDS_GTK_FIELD_STRING_MAP:
        *(GHashTable **)slot = parse_string_map(node_object(node));
        break;
    case SZFRIENDS_GTK_FIELD_JSON_OBJECT:
        *(JsonObject **)slot = node_object(node) ? json_object_ref(node_object(node)) : NULL;
        break;
    }
}

/* Every struct starts with its presence mask; field i of the table owns bit i. */
static void parse_object(const SZFriendsGtkType *type, JsonObject *object, guint8 *base) {
    SZFriendsGtkPresence *present = (SZFriendsGtkPresence *)base;
    for (gsize i = 0; i < type->n_fields; i++) {
        const SZFriendsGtkField *field = &type->fields[i];
        JsonNode *node = object ? json_object_get_member(object, field->name) : NULL;
        if (node) *present |= (SZFriendsGtkPresence)1 << i;
        parse_field(field, node, base);
    }
}

static void free_object(const SZFriendsGtkType *type, guint8 *base) {
    for (gsize i = 0; i < type->n_fields; i++) {
        const SZFriendsGtkField *field = &type->fields[i];
        guint8 *slot = base + field->offset;
        switch (field->kind) {
        case SZFRIENDS_GTK_FIELD_STRING:
        case SZFRIENDS_GTK_FIELD_STRING_NULL:
            g_free(*(char **)slot);
            break;
        case SZFRIENDS_GTK_FIELD_OBJECT:
            free_object(field->type, slot);
            break;
        case SZFRIENDS_GTK_FIELD_OBJECT_NULL:
            if (*(guint8 **)slot) free_object(field->type, *(guint8 **)slot);
            g_free(*(guint8 **)slot);
            break;
        case SZFRIENDS_GTK_FIELD_ARRAY: {
            guint8 *elements = *(guint8 **)slot;
            gsize count = *(gsize *)(base + field->count_offset);
            for (gsize j = 0; j < count; j++) free_object(field->type, elements + j * field->type->size);
            g_free(elements);
            break;
        }
        case SZFRIENDS_GTK_FIELD_STRINGS:
            g_strfreev(*(char ***)slot);
            break;
        case SZFRIENDS_GTK_FIELD_STRING_MAP:
            if (*(GHashTable **)slot) g_hash_table_unref(*(GHashTable **)slot);
            break;
        case SZFRIENDS_GTK_FIELD_JSON_OBJECT:
            if (*(JsonObject **)slot) json_object_unref(*(JsonObject **)slot);
            break;
        default:
            break;
        }
    }
}

gpointer szfriends_gtk_value_parse(const SZFriendsGtkType *type, JsonObject *object) {
    if (!type) return NULL;
    guint8 *value = g_malloc0(type->size);
    parse_object(type, object, value);
    return value;
}

void szfriends_gtk_value_free(const SZFriendsGtkType *type, gpointer value) {
    if (!type || !value) return;
    free_object(type, value);
    g_free(value);
}

JsonObject *szfriends_gtk_json_object_from_text(const char *text, gssize length) {
    if (!text) return NULL;
    JsonParser *parser = json_parser_new_immutable();
    JsonObject *object = NULL;
    if (json_parser_load_from_data(parser, text, length, NULL)) {
        JsonNode *root = json_parser_get_root(parser);
        if (root && JSON_NODE_HOLDS_OBJECT(root)) object = json_object_ref(json_node_get_object(root));
    }
    g_object_unref(parser);
    return object;
}
