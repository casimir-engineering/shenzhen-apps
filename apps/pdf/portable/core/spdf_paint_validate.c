/* Checks an operation's arguments against its JSON Schema (spdf_paint_schema_operation): the subset the schema text
 * of spdf_paint_schema.c uses ($ref into $defs, anyOf, const, enum, type, minimum/maximum, exclusiveMinimum/Maximum,
 * minLength/maxLength, the colour pattern, items, minItems/maxItems, properties, required, additionalProperties false).
 * Failures answer one plain sentence naming the argument, for the person or agent who sent it. */
#include "spdf_paint_model.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

typedef struct check {
    const cJSON* defs;
    char* msg;
    size_t cap;
} check;

static int fail(check* c, const char* path, const char* what) {
    if (path && path[0]) snprintf(c->msg, c->cap, "\"%s\" %s.", path, what);
    else snprintf(c->msg, c->cap, "The operation %s.", what);
    return 0;
}

static const cJSON* resolve(check* c, const cJSON* schema) {
    for (int guard = 0; guard < 8; guard++) {
        const char* ref = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(schema, "$ref"));
        if (!ref || strncmp(ref, "#/$defs/", 8)) return schema;
        schema = cJSON_GetObjectItemCaseSensitive(c->defs, ref + 8);
    }
    return schema;
}

static int is_type(const cJSON* v, const char* type) {
    if (!strcmp(type, "object")) return cJSON_IsObject(v);
    if (!strcmp(type, "array")) return cJSON_IsArray(v);
    if (!strcmp(type, "string")) return cJSON_IsString(v);
    if (!strcmp(type, "boolean")) return cJSON_IsBool(v);
    if (!strcmp(type, "number")) return cJSON_IsNumber(v);
    if (!strcmp(type, "integer")) return cJSON_IsNumber(v) && v->valuedouble == floor(v->valuedouble);
    if (!strcmp(type, "null")) return cJSON_IsNull(v);
    return 1;
}

static const char* type_words(const char* type) {
    if (!strcmp(type, "object")) return "must be an object {...}";
    if (!strcmp(type, "array")) return "must be a list [...]";
    if (!strcmp(type, "string")) return "must be text";
    if (!strcmp(type, "boolean")) return "must be true or false";
    if (!strcmp(type, "integer")) return "must be a whole number";
    return "must be a number";
}

static int same(const cJSON* a, const cJSON* b) { return cJSON_Compare(a, b, 1); }

static int color_ok(const char* s) {
    size_t n = strlen(s);
    if (s[0] != '#' || (n != 7 && n != 9)) return 0;
    for (size_t i = 1; i < n; i++)
        if (!strchr("0123456789abcdefABCDEF", s[i])) return 0;
    return 1;
}

static int validate(check* c, const cJSON* v, const cJSON* schema, const char* path);

static void enum_words(const cJSON* list, char* out, size_t cap) {
    out[0] = 0;
    const cJSON* e = NULL;
    int first = 1;
    cJSON_ArrayForEach(e, list) {
        char* text = cJSON_IsString(e) ? NULL : cJSON_PrintUnformatted(e);
        size_t used = strlen(out);
        snprintf(out + used, cap - used, "%s%s", first ? "" : ", ", text ? text : e->valuestring);
        cJSON_free(text);
        first = 0;
    }
}

static int check_any_of(check* c, const cJSON* v, const cJSON* any, const char* path) {
    char saved[512];
    const cJSON* branch = NULL;
    int all_required = 1;
    cJSON_ArrayForEach(branch, any) {
        if (validate(c, v, branch, path)) return 1;
        const cJSON* r = cJSON_GetObjectItemCaseSensitive(branch, "required");
        all_required &= r && cJSON_GetArraySize(branch) == 1;
    }
    snprintf(saved, sizeof(saved), "%s", c->msg);
    if (!all_required) {
        /* One branch's own sentence reads best when the others are type alternatives (colour or "transparent"). */
        snprintf(c->msg, c->cap, "%s", saved);
        return 0;
    }
    char names[256] = "";
    cJSON_ArrayForEach(branch, any) {
        const cJSON* r = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(branch, "required"), 0);
        size_t used = strlen(names);
        snprintf(names + used, sizeof(names) - used, "%s\"%s\"", used ? " or " : "", cJSON_GetStringValue(r));
    }
    snprintf(c->msg, c->cap, "Give %s.", names);
    return 0;
}

static int check_object(check* c, const cJSON* v, const cJSON* schema, const char* path) {
    const cJSON* props = cJSON_GetObjectItemCaseSensitive(schema, "properties");
    const cJSON* req = NULL;
    cJSON_ArrayForEach(req, cJSON_GetObjectItemCaseSensitive(schema, "required"))
        if (cJSON_IsString(req) && !cJSON_GetObjectItemCaseSensitive(v, req->valuestring)) {
            char sub[160];
            snprintf(sub, sizeof(sub), "%s%s%s", path, path[0] ? "." : "", req->valuestring);
            return fail(c, sub, "is missing");
        }
    const cJSON* additional = cJSON_GetObjectItemCaseSensitive(schema, "additionalProperties");
    const cJSON* item = NULL;
    cJSON_ArrayForEach(item, v) {
        char sub[160];
        snprintf(sub, sizeof(sub), "%s%s%s", path, path[0] ? "." : "", item->string);
        const cJSON* ps = cJSON_GetObjectItemCaseSensitive(props, item->string);
        if (!ps) {
            if (cJSON_IsFalse(additional)) return fail(c, sub, "isn't an argument of this operation");
            continue;
        }
        if (!validate(c, item, ps, sub)) return 0;
    }
    return 1;
}

static int validate(check* c, const cJSON* v, const cJSON* schema, const char* path) {
    schema = resolve(c, schema);
    if (!schema) return 1;
    /* anyOf ("rect" or "points") is checked last: a wrong value is named before a missing alternative. */
    const cJSON* any = cJSON_GetObjectItemCaseSensitive(schema, "anyOf");
    const cJSON* constant = cJSON_GetObjectItemCaseSensitive(schema, "const");
    if (constant && !same(v, constant)) {
        char* text = cJSON_PrintUnformatted(constant);
        char what[200];
        snprintf(what, sizeof(what), "must be %s", text ? text : "");
        cJSON_free(text);
        return fail(c, path, what);
    }
    const cJSON* list = cJSON_GetObjectItemCaseSensitive(schema, "enum");
    if (list) {
        const cJSON* e = NULL;
        int found = 0;
        cJSON_ArrayForEach(e, list) found |= same(v, e);
        if (!found) {
            char words[400], what[440];
            enum_words(list, words, sizeof(words));
            snprintf(what, sizeof(what), "must be one of: %s", words);
            return fail(c, path, what);
        }
    }
    const cJSON* type = cJSON_GetObjectItemCaseSensitive(schema, "type");
    if (cJSON_IsString(type) && !is_type(v, type->valuestring)) return fail(c, path, type_words(type->valuestring));
    if (cJSON_IsArray(type)) {
        const cJSON* t = NULL;
        int ok = 0;
        cJSON_ArrayForEach(t, type) ok |= cJSON_IsString(t) && is_type(v, t->valuestring);
        if (!ok) return fail(c, path, "has the wrong kind of value");
    }
    if (cJSON_IsNumber(v)) {
        const cJSON* lim;
        char what[80];
        if ((lim = cJSON_GetObjectItemCaseSensitive(schema, "minimum")) && v->valuedouble < lim->valuedouble)
            return snprintf(what, sizeof(what), "must be at least %g", lim->valuedouble), fail(c, path, what);
        if ((lim = cJSON_GetObjectItemCaseSensitive(schema, "maximum")) && v->valuedouble > lim->valuedouble)
            return snprintf(what, sizeof(what), "must be at most %g", lim->valuedouble), fail(c, path, what);
        if ((lim = cJSON_GetObjectItemCaseSensitive(schema, "exclusiveMinimum")) && v->valuedouble <= lim->valuedouble)
            return snprintf(what, sizeof(what), "must be more than %g", lim->valuedouble), fail(c, path, what);
        if ((lim = cJSON_GetObjectItemCaseSensitive(schema, "exclusiveMaximum")) && v->valuedouble >= lim->valuedouble)
            return snprintf(what, sizeof(what), "must be less than %g", lim->valuedouble), fail(c, path, what);
    }
    if (cJSON_IsString(v)) {
        const cJSON* lim;
        char what[80];
        size_t n = strlen(v->valuestring);
        if ((lim = cJSON_GetObjectItemCaseSensitive(schema, "maxLength")) && n > (size_t)lim->valuedouble)
            return snprintf(what, sizeof(what), "can be at most %g characters", lim->valuedouble), fail(c, path, what);
        if ((lim = cJSON_GetObjectItemCaseSensitive(schema, "minLength")) && n < (size_t)lim->valuedouble)
            return snprintf(what, sizeof(what), "needs at least %g characters", lim->valuedouble), fail(c, path, what);
        if (cJSON_GetObjectItemCaseSensitive(schema, "pattern") && !color_ok(v->valuestring))
            return fail(c, path, "must be a colour like \"#FF0000\" or \"#FF000080\"");
    }
    if (cJSON_IsArray(v)) {
        const cJSON* lim;
        char what[80];
        int n = cJSON_GetArraySize(v);
        if ((lim = cJSON_GetObjectItemCaseSensitive(schema, "minItems")) && n < (int)lim->valuedouble)
            return snprintf(what, sizeof(what), "needs at least %g items", lim->valuedouble), fail(c, path, what);
        if ((lim = cJSON_GetObjectItemCaseSensitive(schema, "maxItems")) && n > (int)lim->valuedouble)
            return snprintf(what, sizeof(what), "can have at most %g items", lim->valuedouble), fail(c, path, what);
        const cJSON* items = cJSON_GetObjectItemCaseSensitive(schema, "items");
        const cJSON* e = NULL;
        int i = 0;
        if (items) cJSON_ArrayForEach(e, v) {
            char sub[160];
            snprintf(sub, sizeof(sub), "%s[%d]", path, i++);
            if (!validate(c, e, items, sub)) return 0;
        }
    }
    if (cJSON_IsObject(v) && (cJSON_GetObjectItemCaseSensitive(schema, "properties") ||
                              cJSON_GetObjectItemCaseSensitive(schema, "required")) &&
        !check_object(c, v, schema, path))
        return 0;
    return !any || check_any_of(c, v, any, path);
}

int spdf_paint_validate(const cJSON* value, const cJSON* schema, const cJSON* defs, char* msg, size_t msg_cap) {
    check c = {defs, msg, msg_cap};
    if (msg && msg_cap) msg[0] = 0;
    return validate(&c, value, schema, "");
}
