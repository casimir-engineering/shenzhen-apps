/* Annotate's single path for every change (docs/plans/annotate.md § 6, § 8 Core spdf_paint_ops.c): JSON parsing and
 * validation against spdf_paint_schema (cJSON, spdf_paint_validate.c), the document-kind rules (needs_pdf, pdf_only,
 * page_locked), the dispatch table to spdf_paint_handlers.h, history steps around undoable operations, the answers,
 * the argument readers and the doc.state handler. */
#include "spdf_paint_model.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char* spdf_paint_status_code(spdf_paint_status status) {
    switch (status) {
    case SPDF_PAINT_OK: return "ok";
    case SPDF_PAINT_ERR_NOT_IMPLEMENTED: return "not_implemented";
    case SPDF_PAINT_ERR_INVALID_JSON: return "invalid_json";
    case SPDF_PAINT_ERR_UNKNOWN_OP: return "unknown_op";
    case SPDF_PAINT_ERR_INVALID_ARGUMENT: return "invalid_argument";
    case SPDF_PAINT_ERR_PAGE_LOCKED: return "page_locked";
    case SPDF_PAINT_ERR_NEEDS_PDF: return "needs_pdf";
    case SPDF_PAINT_ERR_PDF_ONLY: return "pdf_only";
    case SPDF_PAINT_ERR_NOT_FOUND: return "not_found";
    case SPDF_PAINT_ERR_TOO_LARGE: return "too_large";
    case SPDF_PAINT_ERR_NOTHING_SELECTED: return "nothing_selected";
    case SPDF_PAINT_ERR_NOTHING_TO_UNDO: return "nothing_to_undo";
    case SPDF_PAINT_ERR_NO_SIGNATURE: return "no_signature";
    case SPDF_PAINT_ERR_LOCKED: return "locked";
    case SPDF_PAINT_ERR_IO: return "io_error";
    case SPDF_PAINT_ERR_NO_MEMORY: return "no_memory";
    case SPDF_PAINT_ERR_FRONTEND: return "frontend_only";
    case SPDF_PAINT_ERR_FAILED: return "failed";
    }
    return "failed";
}

static const char* default_message(spdf_paint_status status) {
    switch (status) {
    case SPDF_PAINT_ERR_NOT_IMPLEMENTED: return "This isn't available yet.";
    case SPDF_PAINT_ERR_PAGE_LOCKED: return "The page itself can't be changed.";
    case SPDF_PAINT_ERR_NEEDS_PDF: return "Save this document as a PDF to annotate it.";
    case SPDF_PAINT_ERR_NOTHING_SELECTED: return "Nothing is selected.";
    case SPDF_PAINT_ERR_NO_MEMORY: return "There is not enough memory.";
    case SPDF_PAINT_ERR_FRONTEND: return "The app carries this out, not the canvas.";
    default: return "That didn't work.";
    }
}

char* spdf_paint_error_json(spdf_paint_status status, const char* message) {
    cJSON* answer = cJSON_CreateObject();
    if (!answer) return NULL;
    cJSON_AddBoolToObject(answer, "ok", 0);
    cJSON_AddStringToObject(answer, "error", spdf_paint_status_code(status));
    cJSON_AddStringToObject(answer, "message", message && message[0] ? message : default_message(status));
    char* text = cJSON_PrintUnformatted(answer);
    cJSON_Delete(answer);
    return text;
}

/* Strings from this API come from cJSON's allocator (malloc by default). */
void spdf_paint_free(void* p) { cJSON_free(p); }

/* ---- Checking ---- */

static spdf_paint_status kind_rule(const spdf_paint_op_info* op, spdf_paint_doc_kind kind, const char** message) {
    if (op->kinds & kind) return SPDF_PAINT_OK;
    if (kind == SPDF_PAINT_DOC_TEXT) {
        *message = "Save this document as a PDF to annotate it.";
        return SPDF_PAINT_ERR_NEEDS_PDF;
    }
    if (op->kinds == SPDF_PAINT_DOC_PDF) {
        *message = "This works on PDFs only.";
        return SPDF_PAINT_ERR_PDF_ONLY;
    }
    if (kind == SPDF_PAINT_DOC_PDF) {
        *message = "The page itself can't be changed.";
        return SPDF_PAINT_ERR_PAGE_LOCKED;
    }
    *message = "This document can be annotated as it is.";
    return SPDF_PAINT_ERR_INVALID_ARGUMENT;
}

/* Parses and checks `json` for `kind`; *root (to cJSON_Delete) and *op on success, msg on failure. */
static spdf_paint_status prepare(const char* json, spdf_paint_doc_kind kind, cJSON** root,
                                 const spdf_paint_op_info** op, char* msg, size_t cap) {
    *root = NULL;
    *op = NULL;
    cJSON* tree = json ? cJSON_Parse(json) : NULL;
    if (!cJSON_IsObject(tree)) {
        cJSON_Delete(tree);
        snprintf(msg, cap, "The operation isn't a JSON object.");
        return SPDF_PAINT_ERR_INVALID_JSON;
    }
    const char* name = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(tree, "op"));
    const spdf_paint_op_info* info = spdf_paint_op_find(name);
    if (!info) {
        snprintf(msg, cap, name ? "There is no operation named \"%s\"." : "Name the operation in \"op\".%s",
                 name ? name : "");
        cJSON_Delete(tree);
        return SPDF_PAINT_ERR_UNKNOWN_OP;
    }
    if (!spdf_paint_validate(tree, spdf_paint_schema_operation(info->name), spdf_paint_schema_defs(), msg, cap)) {
        cJSON_Delete(tree);
        return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    }
    const char* rule = NULL;
    spdf_paint_status status = kind_rule(info, kind, &rule);
    if (status == SPDF_PAINT_OK && kind == SPDF_PAINT_DOC_PDF && (info->flags & SPDF_PAINT_OP_NEEDS_PAGE) &&
        !cJSON_GetObjectItemCaseSensitive(tree, "page")) {
        status = SPDF_PAINT_ERR_INVALID_ARGUMENT;
        rule = "Say which page it is for: \"page\", from 1.";
    }
    if (status != SPDF_PAINT_OK) {
        snprintf(msg, cap, "%s", rule);
        cJSON_Delete(tree);
        return status;
    }
    *root = tree;
    *op = info;
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_check_op(const char* json, spdf_paint_doc_kind kind, const spdf_paint_op_info** op_out,
                                      char** result_json) {
    char msg[512];
    cJSON* root = NULL;
    const spdf_paint_op_info* op = NULL;
    spdf_paint_status status = prepare(json, kind, &root, &op, msg, sizeof(msg));
    cJSON_Delete(root);
    if (op_out) *op_out = op;
    if (result_json) *result_json = status == SPDF_PAINT_OK ? NULL : spdf_paint_error_json(status, msg);
    return status;
}

/* ---- Dispatch ---- */

static const struct { const char* name; spdf_paint_handler handler; } k_handlers[] = {
    {"canvas.resize", spdf_paint_op_canvas_resize}, {"canvas.properties", spdf_paint_op_canvas_properties},
    {"image.resize", spdf_paint_op_image_resize}, {"image.skew", spdf_paint_op_image_skew},
    {"image.rotate", spdf_paint_op_image_rotate}, {"image.flip", spdf_paint_op_image_flip},
    {"image.crop", spdf_paint_op_image_crop}, {"image.invert", spdf_paint_op_image_invert},
    {"image.clear", spdf_paint_op_image_clear}, {"image.remove_background", spdf_paint_op_image_remove_background},
    {"select.rect", spdf_paint_op_select_rect}, {"select.freeform", spdf_paint_op_select_freeform},
    {"select.all", spdf_paint_op_select_all}, {"select.none", spdf_paint_op_select_none},
    {"select.invert", spdf_paint_op_select_invert}, {"select.delete", spdf_paint_op_select_delete},
    {"select.lift", spdf_paint_op_select_lift}, {"select.transparent", spdf_paint_op_select_transparent},
    {"select.objects", spdf_paint_op_select_objects},
    {"pen.add", spdf_paint_op_pen_add}, {"arrow.add", spdf_paint_op_arrow_add},
    {"erase.lines", spdf_paint_op_erase_lines}, {"paint.stroke", spdf_paint_op_paint_stroke},
    {"paint.fill", spdf_paint_op_paint_fill}, {"color.pick", spdf_paint_op_color_pick},
    {"shape.add", spdf_paint_op_shape_add}, {"text.add", spdf_paint_op_text_add},
    {"picture.add", spdf_paint_op_picture_add}, {"object.update", spdf_paint_op_object_update},
    {"object.move", spdf_paint_op_object_move}, {"object.transform", spdf_paint_op_object_transform},
    {"object.order", spdf_paint_op_object_order}, {"object.merge_down", spdf_paint_op_object_merge_down},
    {"object.duplicate", spdf_paint_op_object_duplicate}, {"object.delete", spdf_paint_op_object_delete},
    {"object.layer", spdf_paint_op_object_layer},
    {"layer.add", spdf_paint_op_layer_add}, {"layer.duplicate", spdf_paint_op_layer_duplicate},
    {"layer.delete", spdf_paint_op_layer_delete}, {"layer.merge_down", spdf_paint_op_layer_merge_down},
    {"layer.set", spdf_paint_op_layer_set}, {"layer.order", spdf_paint_op_layer_order},
    {"layer.activate", spdf_paint_op_layer_activate}, {"colors.set", spdf_paint_op_colors_set},
    {"palette.set_custom", spdf_paint_op_palette_set_custom}, {"history.undo", spdf_paint_op_history_undo},
    {"history.redo", spdf_paint_op_history_redo}, {"doc.state", spdf_paint_op_doc_state},
    {"doc.render", spdf_paint_op_doc_render},
};

spdf_paint_handler spdf_paint_handler_for(const char* op_name) {
    for (size_t i = 0; op_name && i < sizeof(k_handlers) / sizeof(k_handlers[0]); i++)
        if (!strcmp(k_handlers[i].name, op_name)) return k_handlers[i].handler;
    return NULL;
}

spdf_paint_status spdf_paint_apply(spdf_paint_doc* doc, const char* json, char** result_json) {
    return spdf_paint_apply_ex(doc, json, NULL, result_json);
}

spdf_paint_status spdf_paint_apply_ex(spdf_paint_doc* doc, const char* json, const spdf_paint_apply_input* input,
                                      char** result_json) {
    static const spdf_paint_apply_input no_input;
    spdf_paint_call call;
    memset(&call, 0, sizeof(call));
    cJSON* root = NULL;
    spdf_paint_status status = SPDF_PAINT_ERR_FAILED;
    if (!doc || !doc->ctx) snprintf(call.message, sizeof(call.message), "There is no canvas to change.");
    else status = prepare(json, doc->kind, &root, &call.op, call.message, sizeof(call.message));
    if (status == SPDF_PAINT_OK && doc->kind == SPDF_PAINT_DOC_PDF && (call.op->flags & SPDF_PAINT_OP_NEEDS_PAGE)) {
        double page = cJSON_GetNumberValue(cJSON_GetObjectItemCaseSensitive(root, "page"));
        if ((int)page != doc->page_index + 1) {
            status = SPDF_PAINT_ERR_INVALID_ARGUMENT;
            snprintf(call.message, sizeof(call.message), "This canvas is page %d, not page %d.", doc->page_index + 1,
                     (int)page);
        }
    }
    spdf_paint_handler handler = status == SPDF_PAINT_OK ? spdf_paint_handler_for(call.op->name) : NULL;
    if (status == SPDF_PAINT_OK && !handler) {
        status = SPDF_PAINT_ERR_FRONTEND;
        snprintf(call.message, sizeof(call.message), "The app carries out %s, not the canvas.", call.op->name);
    }
    cJSON* reply = NULL;
    if (status == SPDF_PAINT_OK) {
        call.doc = doc;
        call.args = root;
        call.input = input ? input : &no_input;
        call.reply = reply = cJSON_CreateObject();
        cJSON_AddTrueToObject(reply, "ok");
        int undoable = (call.op->flags & SPDF_PAINT_OP_UNDOABLE) != 0;
        if (undoable) {
            char* text = cJSON_PrintUnformatted(root);
            spdf_paint_history_begin(doc, text);
            cJSON_free(text);
        }
        status = handler(&call);
        if (status != SPDF_PAINT_OK && call.status == SPDF_PAINT_OK) call.status = status;
        if (undoable) spdf_paint_history_end(doc, status == SPDF_PAINT_OK);
    }
    if (result_json) {
        if (status == SPDF_PAINT_OK) *result_json = cJSON_PrintUnformatted(reply);
        else *result_json = spdf_paint_error_json(status, call.message);
    }
    cJSON_Delete(reply);
    cJSON_Delete(root);
    return status;
}

/* ---- Handler support (spdf_paint_handlers.h) ---- */

spdf_paint_status spdf_paint_call_fail(spdf_paint_call* call, spdf_paint_status status, const char* format, ...) {
    call->status = status;
    va_list args;
    va_start(args, format);
    vsnprintf(call->message, sizeof(call->message), format ? format : "", args);
    va_end(args);
    return status;
}

/* The schema's default for an argument (through a $ref), or NULL. */
static const cJSON* arg_default(const spdf_paint_call* call, const char* name) {
    const cJSON* op = spdf_paint_schema_operation(call->op ? call->op->name : NULL);
    const cJSON* p = cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(op, "properties"), name);
    const cJSON* d = cJSON_GetObjectItemCaseSensitive(p, "default");
    const char* ref = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(p, "$ref"));
    if (!d && ref && !strncmp(ref, "#/$defs/", 8))
        d = cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(spdf_paint_schema_defs(), ref + 8),
                                             "default");
    return d;
}

static const cJSON* arg(const spdf_paint_call* call, const char* name, int* present) {
    const cJSON* v = cJSON_GetObjectItemCaseSensitive(call->args, name);
    *present = v != NULL;
    return v ? v : arg_default(call, name);
}

int spdf_paint_arg_number(const spdf_paint_call* call, const char* name, double* out) {
    int present;
    const cJSON* v = arg(call, name, &present);
    if (cJSON_IsNumber(v)) *out = v->valuedouble;
    return present;
}

int spdf_paint_arg_bool(const spdf_paint_call* call, const char* name, int* out) {
    int present;
    const cJSON* v = arg(call, name, &present);
    if (cJSON_IsBool(v)) *out = cJSON_IsTrue(v);
    return present;
}

const char* spdf_paint_arg_string(const spdf_paint_call* call, const char* name) {
    return cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(call->args, name));
}

int spdf_paint_arg_color(const spdf_paint_call* call, const char* name, spdf_paint_color* out) {
    int present;
    const cJSON* v = arg(call, name, &present);
    if (cJSON_IsString(v)) spdf_paint_parse_color(v->valuestring, out);
    return present;
}

int spdf_paint_arg_rect(const spdf_paint_call* call, const char* name, spdf_rect* out) {
    return spdf_paint_json_rect(cJSON_GetObjectItemCaseSensitive(call->args, name), out);
}

int spdf_paint_arg_points(const spdf_paint_call* call, const char* name, spdf_paint_point** out, int* count) {
    return spdf_paint_json_points(call->doc->ctx, cJSON_GetObjectItemCaseSensitive(call->args, name), out, count);
}

int spdf_paint_arg_ids(const spdf_paint_call* call, spdf_paint_id** out, int* count) {
    *out = NULL;
    *count = 0;
    const cJSON* one = cJSON_GetObjectItemCaseSensitive(call->args, "id");
    const cJSON* many = cJSON_GetObjectItemCaseSensitive(call->args, "ids");
    int n = cJSON_IsNumber(one) ? 1 : cJSON_IsArray(many) ? cJSON_GetArraySize(many) : 0;
    if (!n) return 0;
    fz_try(call->doc->ctx) *out = fz_malloc(call->doc->ctx, (size_t)n * sizeof(**out));
    fz_catch(call->doc->ctx) { fz_ignore_error(call->doc->ctx); return 0; }
    if (cJSON_IsNumber(one)) (*out)[(*count)++] = (spdf_paint_id)one->valuedouble;
    else {
        const cJSON* e = NULL;
        cJSON_ArrayForEach(e, many) if (cJSON_IsNumber(e)) (*out)[(*count)++] = (spdf_paint_id)e->valuedouble;
    }
    return 1;
}

spdf_paint_scope spdf_paint_arg_scope(const spdf_paint_call* call) {
    int present;
    const char* s = cJSON_GetStringValue(arg(call, "scope", &present));
    if (s && !strcmp(s, "image")) return SPDF_PAINT_SCOPE_IMAGE;
    if (s && !strcmp(s, "selection")) return SPDF_PAINT_SCOPE_SELECTION;
    if (s && !strcmp(s, "object")) return SPDF_PAINT_SCOPE_OBJECT;
    return SPDF_PAINT_SCOPE_AUTO;
}

spdf_paint_status spdf_paint_arg_check_page(spdf_paint_call* call) {
    if (call->doc->kind != SPDF_PAINT_DOC_PDF) return SPDF_PAINT_OK;
    double page = 0;
    spdf_paint_arg_number(call, "page", &page);
    if ((int)page == call->doc->page_index + 1) return SPDF_PAINT_OK;
    return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "This canvas is page %d, not page %d.",
                                call->doc->page_index + 1, (int)page);
}

/* ---- doc.state ---- */

spdf_paint_status spdf_paint_op_doc_state(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    cJSON* r = call->reply;
    cJSON_AddStringToObject(r, "kind", spdf_paint_kind_name(doc->kind));
    if (doc->kind == SPDF_PAINT_DOC_PDF) cJSON_AddNumberToObject(r, "page", doc->page_index + 1);
    cJSON_AddNumberToObject(r, "width", doc->width);
    cJSON_AddNumberToObject(r, "height", doc->height);
    cJSON_AddStringToObject(r, "units", doc->kind == SPDF_PAINT_DOC_PDF ? "pt" : "px");
    cJSON_AddNumberToObject(r, "dpi", doc->dpi);
    cJSON_AddBoolToObject(r, "transparent", doc->has_alpha);
    cJSON_AddItemToObject(r, "layers", spdf_paint_layers_json(doc)); /* bottom to top, each with its objects */
    if (doc->active) cJSON_AddNumberToObject(r, "active", doc->active);
    else cJSON_AddNullToObject(r, "active");
    const spdf_paint_selection* s = &doc->selection;
    cJSON* sel = cJSON_AddObjectToObject(r, "selection");
    cJSON_AddBoolToObject(sel, "active", s->mask != NULL); /* a pixel selection is there */
    float rs = (float)doc->raster_scale;
    if (s->mask)
        cJSON_AddItemToObject(sel, "bounds", spdf_paint_rect_json((spdf_rect){s->bounds.x0 / rs, s->bounds.y0 / rs,
                                                                          s->bounds.x1 / rs, s->bounds.y1 / rs}));
    else cJSON_AddNullToObject(sel, "bounds");
    cJSON* outline = cJSON_AddArrayToObject(sel, "outline");
    for (int i = 0; s->mask && i < s->outline_count; i++) cJSON_AddItemToArray(outline, spdf_paint_point_json(s->outline[i]));
    cJSON* objects = cJSON_AddArrayToObject(sel, "objects");
    for (int i = 0; i < s->object_count; i++) cJSON_AddItemToArray(objects, cJSON_CreateNumber(s->objects[i]));
    cJSON_AddBoolToObject(sel, "transparent", s->transparent);
    cJSON_AddItemToObject(r, "color1", spdf_paint_color_json(doc->color1));
    cJSON_AddItemToObject(r, "color2", spdf_paint_color_json(doc->color2));
    cJSON* custom = cJSON_AddArrayToObject(r, "custom");
    for (int i = 0; i < SPDF_PAINT_CUSTOM_COLORS; i++)
        cJSON_AddItemToArray(custom, doc->custom[i] ? spdf_paint_color_json(doc->custom[i]) : cJSON_CreateNull());
    cJSON_AddBoolToObject(r, "dirty", spdf_paint_is_dirty(doc));
    cJSON_AddBoolToObject(r, "canUndo", spdf_paint_can_undo(doc));
    cJSON_AddBoolToObject(r, "canRedo", spdf_paint_can_redo(doc));
    const char* undo = spdf_paint_undo_name(doc);
    const char* redo = spdf_paint_redo_name(doc);
    if (undo) cJSON_AddStringToObject(r, "undo", undo);
    if (redo) cJSON_AddStringToObject(r, "redo", redo);
    return SPDF_PAINT_OK;
}
