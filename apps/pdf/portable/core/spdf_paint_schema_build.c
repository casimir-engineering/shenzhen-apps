/* The one JSON Schema document of Annotate's operations (spdf_paint.h, spdf_paint_schema), built on first use from
 * the argument schemas and the operation table of spdf_paint_schema.c, and kept for the life of the process. Split
 * from spdf_paint_schema.c so the schema text can grow there. */
#include "spdf_paint_handlers.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* spdf_paint_schema.c: bare JSON members ("$defs": {...}; "name": {...}, ...). */
extern const char spdf_paint_schema_defs_text[];
extern const char spdf_paint_schema_shared_text[];
extern const char spdf_paint_schema_image_text[];
extern const char spdf_paint_schema_drawing_text[];
extern const char spdf_paint_schema_document_text[];

static const char* route_name(spdf_paint_route route) {
    switch (route) {
    case SPDF_PAINT_ROUTE_CANVAS: return "canvas";
    case SPDF_PAINT_ROUTE_FILL_ON_PDF: return "fill_on_pdf";
    case SPDF_PAINT_ROUTE_FRONTEND: return "frontend";
    }
    return "canvas";
}

/* The built document (spdf_paint.h: the first call happens on one thread). */
static cJSON* g_tree;
static char* g_text;

/* "x-include": [block names] copies those blocks' properties in; "x-anyOf": a block name sets "anyOf" to it. */
static void resolve_shared(cJSON* schema, cJSON* properties, const cJSON* shared) {
    cJSON* include = cJSON_DetachItemFromObjectCaseSensitive(schema, "x-include");
    const cJSON* name = NULL;
    cJSON_ArrayForEach(name, include) {
        const cJSON* block = cJSON_GetObjectItemCaseSensitive(shared, cJSON_GetStringValue(name));
        const cJSON* property = NULL;
        cJSON_ArrayForEach(property, block)
            if (!cJSON_GetObjectItemCaseSensitive(properties, property->string))
                cJSON_AddItemToObject(properties, property->string, cJSON_Duplicate(property, 1));
    }
    cJSON_Delete(include);
    cJSON* any_of = cJSON_DetachItemFromObjectCaseSensitive(schema, "x-anyOf");
    if (cJSON_IsString(any_of)) {
        const cJSON* block = cJSON_GetObjectItemCaseSensitive(shared, any_of->valuestring);
        if (block) cJSON_AddItemToObject(schema, "anyOf", cJSON_Duplicate(block, 1));
    }
    cJSON_Delete(any_of);
}

/* One operation's schema: its argument schema from the text, completed from its table row. */
static cJSON* build_operation(const spdf_paint_op_info* op, cJSON* args, const cJSON* shared) {
    cJSON* schema = args ? args : cJSON_CreateObject();
    cJSON_AddStringToObject(schema, "type", "object");
    cJSON_AddStringToObject(schema, "description", op->summary);
    cJSON* properties = cJSON_GetObjectItemCaseSensitive(schema, "properties");
    if (!properties) properties = cJSON_AddObjectToObject(schema, "properties");
    resolve_shared(schema, properties, shared);
    cJSON* op_const = cJSON_CreateObject();
    cJSON_AddStringToObject(op_const, "const", op->name);
    cJSON_AddItemToObject(properties, "op", op_const);
    if ((op->flags & SPDF_PAINT_OP_NEEDS_PAGE) && !cJSON_GetObjectItemCaseSensitive(properties, "page")) {
        cJSON* page = cJSON_CreateObject();
        cJSON_AddStringToObject(page, "$ref", "#/$defs/page");
        cJSON_AddStringToObject(page, "description", "PDFs: the page it acts on, from 1 (required there)");
        cJSON_AddItemToObject(properties, "page", page);
    }
    cJSON* required = cJSON_GetObjectItemCaseSensitive(schema, "required");
    if (!required) required = cJSON_AddArrayToObject(schema, "required");
    cJSON_AddItemToArray(required, cJSON_CreateString("op"));
    cJSON_AddBoolToObject(schema, "additionalProperties", 0);
    cJSON_AddStringToObject(schema, "x-family", op->family);
    cJSON* kinds = cJSON_AddArrayToObject(schema, "x-kinds");
    for (unsigned bit = SPDF_PAINT_DOC_PICTURE; bit <= SPDF_PAINT_DOC_TEXT; bit <<= 1)
        if (op->kinds & bit)
            cJSON_AddItemToArray(kinds, cJSON_CreateString(spdf_paint_kind_name((spdf_paint_doc_kind)bit)));
    cJSON_AddStringToObject(schema, "x-route", route_name(op->route));
    cJSON_AddBoolToObject(schema, "x-undoable", (op->flags & SPDF_PAINT_OP_UNDOABLE) != 0);
    cJSON_AddBoolToObject(schema, "x-readOnly", (op->flags & SPDF_PAINT_OP_READ_ONLY) != 0);
    cJSON_AddBoolToObject(schema, "x-uiState", (op->flags & SPDF_PAINT_OP_UI_STATE) != 0);
    cJSON_AddBoolToObject(schema, "x-needsPage", (op->flags & SPDF_PAINT_OP_NEEDS_PAGE) != 0);
    return schema;
}

/* The schema text of spdf_paint_schema.c as one JSON object: {"$defs", "shared", "operations"}. */
static cJSON* parse_source(void) {
    size_t size = strlen(spdf_paint_schema_defs_text) + strlen(spdf_paint_schema_shared_text) +
                  strlen(spdf_paint_schema_image_text) + strlen(spdf_paint_schema_drawing_text) +
                  strlen(spdf_paint_schema_document_text) + 64;
    char* text = malloc(size);
    if (!text) return NULL;
    snprintf(text, size, "{%s, \"shared\": {%s}, \"operations\": {%s, %s, %s}}", spdf_paint_schema_defs_text,
             spdf_paint_schema_shared_text, spdf_paint_schema_image_text, spdf_paint_schema_drawing_text,
             spdf_paint_schema_document_text);
    cJSON* source = cJSON_Parse(text);
    free(text);
    return source;
}

static cJSON* build_tree(void) {
    cJSON* source = parse_source();
    if (!source) return NULL;
    cJSON* root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "$schema", "https://json-schema.org/draft/2020-12/schema");
    cJSON_AddStringToObject(root, "$id", "shenzhenpdf-annotate-operations");
    cJSON_AddStringToObject(root, "title", "ShenzhenPDF Annotate operations");
    cJSON_AddNumberToObject(root, "version", SPDF_PAINT_SCHEMA_VERSION);
    cJSON_AddItemToObject(root, "$defs", cJSON_DetachItemFromObjectCaseSensitive(source, "$defs"));
    cJSON_AddStringToObject(root, "type", "object");
    cJSON* required = cJSON_AddArrayToObject(root, "required");
    cJSON_AddItemToArray(required, cJSON_CreateString("op"));
    cJSON* op_property = cJSON_AddObjectToObject(cJSON_AddObjectToObject(root, "properties"), "op");
    cJSON* op_enum = cJSON_AddArrayToObject(op_property, "enum");
    cJSON* sources = cJSON_GetObjectItemCaseSensitive(source, "operations");
    const cJSON* shared = cJSON_GetObjectItemCaseSensitive(source, "shared");
    cJSON* operations = cJSON_AddObjectToObject(root, "operations");
    for (int i = 0; i < spdf_paint_op_count(); i++) {
        const spdf_paint_op_info* op = spdf_paint_op_at(i);
        cJSON_AddItemToArray(op_enum, cJSON_CreateString(op->name));
        cJSON* args = cJSON_DetachItemFromObjectCaseSensitive(sources, op->name);
        cJSON_AddItemToObject(operations, op->name, build_operation(op, args, shared));
    }
    cJSON_Delete(source);
    return root;
}

const char* spdf_paint_schema(void) {
    if (g_text) return g_text;
    if (!g_tree) g_tree = build_tree();
    g_text = g_tree ? cJSON_Print(g_tree) : NULL;
    /* Only a mistake in the schema text gets here; the answer still parses. */
    return g_text ? g_text : "{\"error\":\"The operation schema could not be built.\"}";
}

const cJSON* spdf_paint_schema_operation(const char* name) {
    spdf_paint_schema();
    if (!g_tree || !name) return NULL;
    return cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(g_tree, "operations"), name);
}

const cJSON* spdf_paint_schema_defs(void) {
    spdf_paint_schema();
    return g_tree ? cJSON_GetObjectItemCaseSensitive(g_tree, "$defs") : NULL;
}

char* spdf_paint_op_schema_json(const char* name) {
    const cJSON* op = spdf_paint_schema_operation(name);
    return op ? cJSON_Print(op) : NULL;
}
