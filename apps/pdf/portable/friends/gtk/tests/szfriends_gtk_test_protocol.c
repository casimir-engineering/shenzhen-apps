/* The GTK structs against PROTOCOL.md's § Schemas blocks, both ways (display-free).
 *
 * Every rule of every block the views read must name a field of the matching table, of a compatible kind: nullable
 * where the protocol allows null, the referenced block for @type, every enum value known. And every field of a table
 * must be declared by its block, so the views never invent one. A protocol change the GTK views have not caught up
 * with fails here, naming the block and path, before any page can draw it wrong. */

#include "szfriends_gtk_support.h"

#include <string.h>

typedef struct {
    char *path;          /* without the block's prefix ("data.", "result.") */
    gboolean nullable;   /* some rule for this path allows null */
    GPtrArray *types;    /* every alternative named by any rule for this path */
} SZFGRule;

typedef struct {
    char *name;
    GPtrArray *rules; /* SZFGRule * */
} SZFGBlock;

static void rule_free(gpointer data) {
    SZFGRule *rule = data;
    g_free(rule->path);
    g_ptr_array_unref(rule->types);
    g_free(rule);
}

static void block_free(gpointer data) {
    SZFGBlock *block = data;
    g_free(block->name);
    g_ptr_array_unref(block->rules);
    g_free(block);
}

static SZFGRule *find_rule(SZFGBlock *block, const char *path) {
    for (guint i = 0; i < block->rules->len; i++) {
        SZFGRule *rule = g_ptr_array_index(block->rules, i);
        if (strcmp(rule->path, path) == 0) return rule;
    }
    return NULL;
}

/* `path[?]: type|type [when key=value]`, comments after `#` (PROTOCOL.md § Schemas, grammar). */
static void add_rule(SZFGBlock *block, const char *line, const char *prefix) {
    char *text = g_strdup(line), *hash = strchr(text, '#'), *colon;
    if (hash) *hash = '\0';
    g_strstrip(text);
    colon = strstr(text, ": ");
    if (!*text || !colon) {
        g_free(text);
        return;
    }
    *colon = '\0';
    char *path = text, *types = colon + 2, *when = strstr(types, " when ");
    if (when) *when = '\0';
    gsize length = strlen(path);
    if (length && path[length - 1] == '?') path[length - 1] = '\0';
    if (prefix && g_str_has_prefix(path, prefix)) path += strlen(prefix);
    SZFGRule *rule = find_rule(block, path);
    if (!rule) {
        rule = g_new0(SZFGRule, 1);
        rule->path = g_strdup(path);
        rule->types = g_ptr_array_new_with_free_func(g_free);
        g_ptr_array_add(block->rules, rule);
    }
    char **alternatives = g_strsplit(g_strstrip(types), "|", -1);
    for (char **a = alternatives; *a; a++) {
        if (strcmp(*a, "null") == 0) rule->nullable = TRUE;
        else g_ptr_array_add(rule->types, g_strdup(*a));
    }
    g_strfreev(alternatives);
    g_free(text);
}

static const char *block_prefix(const char *name) {
    if (g_str_has_prefix(name, "snapshot.")) return "data.";
    if (g_str_has_prefix(name, "result.")) return "result.";
    return NULL;
}

static GHashTable *read_blocks(const char *protocol_path) {
    GHashTable *blocks = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, block_free);
    char *text = NULL;
    EXPECT(g_file_get_contents(protocol_path, &text, NULL, NULL), "PROTOCOL.md reads");
    char **lines = g_strsplit(text ? text : "", "\n", -1);
    SZFGBlock *block = NULL;
    for (char **line = lines; *line; line++) {
        if (g_str_has_prefix(*line, "```schema ")) {
            block = g_new0(SZFGBlock, 1);
            block->name = g_strstrip(g_strdup(*line + strlen("```schema ")));
            block->rules = g_ptr_array_new_with_free_func(rule_free);
            g_hash_table_insert(blocks, block->name, block);
        } else if (g_str_has_prefix(*line, "```")) {
            block = NULL;
        } else if (block) {
            add_rule(block, *line, block_prefix(block->name));
        }
    }
    g_strfreev(lines);
    g_free(text);
    return blocks;
}

static const SZFriendsGtkField *field_named(const SZFriendsGtkType *type, const char *name) {
    for (gsize i = 0; type && i < type->n_fields; i++)
        if (strcmp(type->fields[i].name, name) == 0) return &type->fields[i];
    return NULL;
}

static gboolean enum_has(const SZFriendsGtkEnumNames *enums, const char *value) {
    for (gsize i = 0; enums && i < enums->count; i++)
        if (enums->names[i] && strcmp(enums->names[i], value) == 0) return TRUE;
    return FALSE;
}

/* `@name` refers to block type.name; the field's table must be that block's. */
static gboolean names_block(const SZFriendsGtkField *field, const char *reference) {
    char *want = g_strdup_printf("type.%s", reference + 1);
    gboolean same = field->type && field->type->name && strcmp(field->type->name, want) == 0;
    g_free(want);
    return same;
}

static void check_kind(const char *block, SZFGRule *rule, const SZFriendsGtkField *field, gboolean element) {
    SZFriendsGtkFieldKind kind = field->kind;
    gboolean ok = TRUE;
    for (guint i = 0; i < rule->types->len; i++) {
        const char *t = g_ptr_array_index(rule->types, i);
        if (element && kind == SZFRIENDS_GTK_FIELD_ARRAY && t[0] == '@')
            ok &= names_block(field, t);
        /* A list of enum values (found.methods) stays strings, so a value added later is skipped, not fatal. */
        else if (element && kind == SZFRIENDS_GTK_FIELD_STRINGS)
            ok &= strcmp(t, "string") == 0 || g_str_has_prefix(t, "enum(");
        else if (strcmp(t, "string") == 0)
            ok &= kind == (rule->nullable ? SZFRIENDS_GTK_FIELD_STRING_NULL : SZFRIENDS_GTK_FIELD_STRING) ||
                  kind == SZFRIENDS_GTK_FIELD_STRING_NULL;
        else if (strcmp(t, "integer") == 0)
            ok &= kind == SZFRIENDS_GTK_FIELD_OPT_INT || (!rule->nullable && kind == SZFRIENDS_GTK_FIELD_INT);
        else if (strcmp(t, "number") == 0) ok &= kind == SZFRIENDS_GTK_FIELD_NUMBER;
        else if (strcmp(t, "bool") == 0) ok &= kind == SZFRIENDS_GTK_FIELD_BOOL;
        else if (strcmp(t, "object") == 0)
            ok &= kind == SZFRIENDS_GTK_FIELD_OBJECT || kind == SZFRIENDS_GTK_FIELD_OBJECT_NULL ||
                  kind == SZFRIENDS_GTK_FIELD_JSON_OBJECT || kind == SZFRIENDS_GTK_FIELD_STRING_MAP;
        else if (strcmp(t, "array") == 0)
            ok &= kind == SZFRIENDS_GTK_FIELD_ARRAY || kind == SZFRIENDS_GTK_FIELD_STRINGS;
        else if (t[0] == '@')
            ok &= (kind == (rule->nullable ? SZFRIENDS_GTK_FIELD_OBJECT_NULL : SZFRIENDS_GTK_FIELD_OBJECT) ||
                   kind == SZFRIENDS_GTK_FIELD_OBJECT_NULL) &&
                  names_block(field, t);
        else if (g_str_has_prefix(t, "enum(")) {
            /* An error code stays a string for the views: they compare a few, and new codes need no change here. */
            if (kind == SZFRIENDS_GTK_FIELD_STRING) continue;
            ok &= kind == SZFRIENDS_GTK_FIELD_ENUM;
            char *list = g_strndup(t + 5, strlen(t) - 6);
            char **values = g_strsplit(list, ",", -1);
            for (char **v = values; kind == SZFRIENDS_GTK_FIELD_ENUM && *v; v++)
                EXPECT(enum_has(field->enums, *v), "PROTOCOL.md %s %s: value %s is not in the GTK enum", block,
                       rule->path, *v);
            for (gsize e = 0; kind == SZFRIENDS_GTK_FIELD_ENUM && e < field->enums->count; e++)
                EXPECT(!field->enums->names[e] || g_strv_contains((const char *const *)values, field->enums->names[e]),
                       "GTK enum value %s of %s %s is not in PROTOCOL.md", field->enums->names[e], block, rule->path);
            g_strfreev(values);
            g_free(list);
        }
    }
    EXPECT(ok, "PROTOCOL.md %s %s: the GTK field %s has an incompatible kind", block, rule->path, field->name);
}

/* Resolves one rule's path in `type`; the referenced blocks of @types are checked on their own. */
static void check_rule(const char *block, SZFGRule *rule, const SZFriendsGtkType *type) {
    char **parts = g_strsplit(rule->path, ".", -1);
    const SZFriendsGtkType *current = type;
    for (char **part = parts; *part; part++) {
        gboolean element = g_str_has_suffix(*part, "[]");
        char *name = element ? g_strndup(*part, strlen(*part) - 2) : g_strdup(*part);
        const SZFriendsGtkField *field = field_named(current, name);
        g_free(name);
        if (!field) {
            EXPECT(FALSE, "PROTOCOL.md %s %s has no field in the GTK %s struct", block, rule->path,
                   type->name ? type->name : "?");
            break;
        }
        if (field->kind == SZFRIENDS_GTK_FIELD_STRING_MAP || field->kind == SZFRIENDS_GTK_FIELD_JSON_OBJECT) break;
        if (!part[1]) {
            check_kind(block, rule, field, element);
            break;
        }
        current = field->type; /* an object or an array's element */
    }
    g_strfreev(parts);
}

/* An inline object is declared through its members' paths ("data.name.label"). */
static gboolean has_rule_below(SZFGBlock *block, const char *path) {
    char *prefix = g_strdup_printf("%s.", path);
    gboolean found = FALSE;
    for (guint i = 0; i < block->rules->len && !found; i++)
        found = g_str_has_prefix(((SZFGRule *)g_ptr_array_index(block->rules, i))->path, prefix);
    g_free(prefix);
    return found;
}

/* The other way: every field of `type` (and of its inline objects) is declared by `block`. */
static void check_declared(SZFGBlock *block, const SZFriendsGtkType *type, const char *prefix) {
    for (gsize i = 0; i < type->n_fields; i++) {
        const SZFriendsGtkField *field = &type->fields[i];
        gboolean array = field->kind == SZFRIENDS_GTK_FIELD_ARRAY || field->kind == SZFRIENDS_GTK_FIELD_STRINGS;
        char *path = g_strdup_printf("%s%s", prefix, field->name);
        char *elements = g_strdup_printf("%s[]", path);
        gboolean inline_object = field->type && !field->type->name;
        EXPECT(find_rule(block, path) || (array && find_rule(block, elements)) ||
                   (inline_object && has_rule_below(block, array ? elements : path)),
               "GTK field %s of %s is not declared in PROTOCOL.md", path, block->name);
        if (field->type && !field->type->name) {
            char *inner = g_strdup_printf("%s.", array ? elements : path);
            check_declared(block, field->type, inner);
            g_free(inner);
        }
        g_free(elements);
        g_free(path);
    }
}

static void check_block(GHashTable *blocks, const char *name, const SZFriendsGtkType *type, gboolean reverse) {
    SZFGBlock *block = g_hash_table_lookup(blocks, name);
    EXPECT(block != NULL, "PROTOCOL.md has a %s block", name);
    if (!block) return;
    for (guint i = 0; i < block->rules->len; i++) {
        SZFGRule *rule = g_ptr_array_index(block->rules, i);
        if (strcmp(rule->path, "type") == 0 && g_str_has_prefix(name, "frame.")) continue; /* the frame's tag */
        check_rule(name, rule, type);
    }
    if (reverse) check_declared(block, type, "");
}

void szfg_run_protocol_coverage_tests(const char *protocol_path) {
    GHashTable *blocks = read_blocks(protocol_path);
    EXPECT(g_hash_table_size(blocks) > 40, "PROTOCOL.md's schema blocks are found (%u)", g_hash_table_size(blocks));
    /* Every named table mirrors one block exactly. */
    for (const SZFriendsGtkType *const *t = szfriends_gtk_named_types; *t; t++)
        check_block(blocks, (*t)->name, *t, TRUE);
    /* Blocks two intents share are read with one struct each; checked the first way only. */
    check_block(blocks, "result.subscribe", &szfriends_gtk_type_subscribe_result, FALSE);
    check_block(blocks, "result.send_files", &szfriends_gtk_type_send_result, FALSE);
    if (g_hash_table_contains(blocks, "result.add_from_mention"))
        check_block(blocks, "result.add_from_mention", &szfriends_gtk_type_add_by_id_result, TRUE);
    /* A link card's Add and Download answer as Add by ID does: the conversation, and what happens next. */
    check_block(blocks, "result.add_from_link", &szfriends_gtk_type_add_by_id_result, TRUE);
    check_block(blocks, "result.receive_link", &szfriends_gtk_type_add_by_id_result, TRUE);
    /* Every view, shared object and helper frame a view reads has a table; what only the client library or the
     * assistant's tool layer reads is listed here, so a new block cannot slip past unread. */
    static const char *const not_for_views[] = {"frame.hello", "frame.intent", "type.file", "type.revision",
                                                "result.assistant_open_scope", "result.assistant_search",
                                                "result.assistant_read", "result.subscribe", "result.send_files",
                                                "result.add_from_mention", "result.add_from_link",
                                                "result.receive_link", NULL};
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, blocks);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        const char *name = key;
        if (g_str_has_prefix(name, "intent.") || g_strv_contains(not_for_views, name)) continue;
        gboolean known = FALSE;
        for (const SZFriendsGtkType *const *t = szfriends_gtk_named_types; *t && !known; t++)
            known = strcmp((*t)->name, name) == 0;
        EXPECT(known, "PROTOCOL.md block %s has no GTK struct", name);
    }
    g_hash_table_unref(blocks);
}
