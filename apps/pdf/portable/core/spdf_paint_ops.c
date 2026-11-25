/* Annotate's single path for every change (docs/plans/annotate.md § 6, § 8 Core spdf_paint_ops.c): JSON parsing and
 * validation against spdf_paint_schema (cJSON), the dispatch table to spdf_paint_handlers.h, history steps around
 * undoable operations, the answers, and the doc.state handler.
 *
 * WAVE 0 STUB (Core A implements). Only the answer helpers are real, so every surface already gets well-formed
 * {"ok":false,"error":"not_implemented",...} answers end to end. */
#include "spdf_paint_handlers.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

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

char* spdf_paint_error_json(spdf_paint_status status, const char* message) {
    cJSON* answer = cJSON_CreateObject();
    if (!answer) return NULL;
    cJSON_AddBoolToObject(answer, "ok", 0);
    cJSON_AddStringToObject(answer, "error", spdf_paint_status_code(status));
    cJSON_AddStringToObject(answer, "message", message ? message : "");
    char* text = cJSON_PrintUnformatted(answer);
    cJSON_Delete(answer);
    return text;
}

/* Strings from this API come from cJSON's allocator (malloc by default). */
void spdf_paint_free(void* p) { cJSON_free(p); }

spdf_paint_status spdf_paint_apply(spdf_paint_doc* doc, const char* json, char** result_json) {
    return spdf_paint_apply_ex(doc, json, NULL, result_json);
}

spdf_paint_status spdf_paint_apply_ex(spdf_paint_doc* doc, const char* json, const spdf_paint_apply_input* input,
                                      char** result_json) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(json); SPDF_PAINT_UNUSED(input);
    if (result_json) *result_json = spdf_paint_error_json(SPDF_PAINT_ERR_NOT_IMPLEMENTED, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_status spdf_paint_check_op(const char* json, spdf_paint_doc_kind kind, const spdf_paint_op_info** op_out,
                                      char** result_json) {
    SPDF_PAINT_UNUSED(json); SPDF_PAINT_UNUSED(kind);
    if (op_out) *op_out = NULL;
    if (result_json) *result_json = spdf_paint_error_json(SPDF_PAINT_ERR_NOT_IMPLEMENTED, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
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

int spdf_paint_arg_number(const spdf_paint_call* call, const char* name, double* out) {
    SPDF_PAINT_UNUSED(call); SPDF_PAINT_UNUSED(name); SPDF_PAINT_UNUSED(out);
    return 0;
}

int spdf_paint_arg_bool(const spdf_paint_call* call, const char* name, int* out) {
    SPDF_PAINT_UNUSED(call); SPDF_PAINT_UNUSED(name); SPDF_PAINT_UNUSED(out);
    return 0;
}

const char* spdf_paint_arg_string(const spdf_paint_call* call, const char* name) {
    SPDF_PAINT_UNUSED(call); SPDF_PAINT_UNUSED(name);
    return NULL;
}

int spdf_paint_arg_color(const spdf_paint_call* call, const char* name, spdf_paint_color* out) {
    SPDF_PAINT_UNUSED(call); SPDF_PAINT_UNUSED(name); SPDF_PAINT_UNUSED(out);
    return 0;
}

int spdf_paint_arg_rect(const spdf_paint_call* call, const char* name, spdf_rect* out) {
    SPDF_PAINT_UNUSED(call); SPDF_PAINT_UNUSED(name); SPDF_PAINT_UNUSED(out);
    return 0;
}

int spdf_paint_arg_points(const spdf_paint_call* call, const char* name, spdf_paint_point** out, int* count) {
    SPDF_PAINT_UNUSED(call); SPDF_PAINT_UNUSED(name);
    if (out) *out = NULL;
    if (count) *count = 0;
    return 0;
}

int spdf_paint_arg_ids(const spdf_paint_call* call, spdf_paint_id** out, int* count) {
    SPDF_PAINT_UNUSED(call);
    if (out) *out = NULL;
    if (count) *count = 0;
    return 0;
}

spdf_paint_scope spdf_paint_arg_scope(const spdf_paint_call* call) {
    SPDF_PAINT_UNUSED(call);
    return SPDF_PAINT_SCOPE_AUTO;
}

spdf_paint_status spdf_paint_arg_check_page(spdf_paint_call* call) {
    SPDF_PAINT_UNUSED(call);
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_handler spdf_paint_handler_for(const char* op_name) {
    SPDF_PAINT_UNUSED(op_name);
    return NULL;
}

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_doc_state)
