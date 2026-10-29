/* Shenzhen Friends client library: what the intent builders share (szfriends_intents.c, szfriends_intents_links.c),
 * the intent itself and the helpers that fill its fields. Internal to the client library. */

#ifndef SZFRIENDS_INTENT_BUILD_H
#define SZFRIENDS_INTENT_BUILD_H

#include "client/szfriends_client_internal.h"

#include "cJSON.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

struct szfriends_intent {
    char type[32];
    cJSON *fields;
};

static inline szfriends_intent *intent_new(const char *type) {
    szfriends_intent *intent = (szfriends_intent *)calloc(1, sizeof *intent);
    if (!intent) return NULL;
    strncpy(intent->type, type, sizeof intent->type - 1);
    intent->fields = cJSON_CreateObject();
    if (!intent->fields) {
        free(intent);
        return NULL;
    }
    return intent;
}

/* Adds a string, or fails the whole intent when cJSON runs out of memory; NULL values are the caller's bug. */
static inline bool add_string(szfriends_intent *intent, const char *key, const char *value) {
    return value && cJSON_AddStringToObject(intent->fields, key, value) != NULL;
}

static inline szfriends_intent *finish(szfriends_intent *intent, bool ok) {
    if (ok) return intent;
    szfriends_intent_free(intent);
    return NULL;
}

/* An intent whose only field is one required string, which is most of them. */
static inline szfriends_intent *one_string(const char *type, const char *key, const char *value) {
    szfriends_intent *intent;
    if (!value) return NULL;
    intent = intent_new(type);
    return intent ? finish(intent, add_string(intent, key, value)) : NULL;
}

static inline szfriends_intent *no_fields(const char *type) {
    return intent_new(type);
}

static inline cJSON *file_object(const szfriends_file *file) {
    cJSON *object;
    if (!file || !file->path) return NULL;
    object = cJSON_CreateObject();
    if (!object) return NULL;
    cJSON_AddStringToObject(object, "path", file->path);
    if (file->display_name) cJSON_AddStringToObject(object, "display_name", file->display_name);
    if (file->revision) {
        const szfriends_revision *r = file->revision;
        cJSON *revision;
        if (!r->source || !r->document_id || !r->revision_id) {
            cJSON_Delete(object);
            return NULL;
        }
        revision = cJSON_AddObjectToObject(object, "revision");
        cJSON_AddStringToObject(revision, "source", r->source);
        cJSON_AddStringToObject(revision, "document_id", r->document_id);
        cJSON_AddStringToObject(revision, "revision_id", r->revision_id);
        if (r->label) cJSON_AddStringToObject(revision, "label", r->label);
        if (r->sha256) cJSON_AddStringToObject(revision, "sha256", r->sha256);
        cJSON_AddNumberToObject(revision, "size", (double)r->size);
    } else {
        cJSON_AddNullToObject(object, "revision");
    }
    return object;
}

static inline bool add_files(szfriends_intent *intent, const char *key, const szfriends_file *files, size_t count) {
    cJSON *array;
    size_t i;
    if (count > 0 && !files) return false;
    array = cJSON_AddArrayToObject(intent->fields, key);
    if (!array) return false;
    for (i = 0; i < count; i++) {
        cJSON *object = file_object(&files[i]);
        if (!object) return false;
        cJSON_AddItemToArray(array, object);
    }
    return true;
}

#endif
