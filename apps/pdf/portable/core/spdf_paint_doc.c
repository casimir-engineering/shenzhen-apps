/* Annotate's canvas model (docs/plans/annotate.md § 8 Core, spdf_paint_doc.c): the canvas, layers, objects, ids,
 * z-order, the selection mask, colours, the composite and its tile cache, and the handlers of the Selection, Pen and
 * arrow, Objects (picture, update, move, transform, order, merge down, duplicate, delete), Layers and Colours
 * operations.
 *
 * WAVE 0 STUB (Core A implements): every function answers SPDF_PAINT_ERR_NOT_IMPLEMENTED or does nothing. */
#include "spdf_paint_handlers.h"

#include <stdio.h>
#include <string.h>

void spdf_paint_set_error(char* err, size_t err_len, const char* message) {
    if (err && err_len) snprintf(err, err_len, "%s", message ? message : "");
}

/* ---- Public ---- */

spdf_paint_doc* spdf_paint_new_canvas(int width, int height, spdf_paint_color background, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(width); SPDF_PAINT_UNUSED(height); SPDF_PAINT_UNUSED(background);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return NULL;
}

spdf_paint_doc* spdf_paint_open_picture(const spdf_paint_pixels* pixels, float dpi, int has_alpha, char* err,
                                        size_t err_len) {
    SPDF_PAINT_UNUSED(pixels); SPDF_PAINT_UNUSED(dpi); SPDF_PAINT_UNUSED(has_alpha);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return NULL;
}

void spdf_paint_close(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }

spdf_paint_doc_kind spdf_paint_kind(const spdf_paint_doc* doc) { return doc ? doc->kind : SPDF_PAINT_DOC_CANVAS; }

void spdf_paint_size(const spdf_paint_doc* doc, int* width, int* height) {
    if (width) *width = doc ? doc->width : 0;
    if (height) *height = doc ? doc->height : 0;
}

float spdf_paint_dpi(const spdf_paint_doc* doc) { return doc ? doc->dpi : 72.0f; }

spdf_paint_status spdf_paint_render(spdf_paint_doc* doc, const spdf_paint_render_options* options, spdf_bitmap* out,
                                    char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(options); SPDF_PAINT_UNUSED(out);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_status spdf_paint_layer_thumbnail(spdf_paint_doc* doc, spdf_paint_id layer, int max_side, spdf_bitmap* out,
                                             char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer); SPDF_PAINT_UNUSED(max_side); SPDF_PAINT_UNUSED(out);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

int spdf_paint_take_damage(spdf_paint_doc* doc, spdf_rect* changed) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(changed);
    return 0;
}

uint64_t spdf_paint_generation(const spdf_paint_doc* doc) { return doc ? doc->generation : 0; }

/* ---- Internal (spdf_paint_internal.h) ---- */

spdf_paint_doc* spdf_paint_doc_new(fz_context* ctx, int owns_ctx, spdf_paint_doc_kind kind, int width, int height) {
    SPDF_PAINT_UNUSED(ctx); SPDF_PAINT_UNUSED(owns_ctx); SPDF_PAINT_UNUSED(kind);
    SPDF_PAINT_UNUSED(width); SPDF_PAINT_UNUSED(height);
    return NULL;
}

spdf_paint_layer* spdf_paint_layer_new(spdf_paint_doc* doc, spdf_paint_layer_kind kind, const char* name,
                                       spdf_paint_id above) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(kind); SPDF_PAINT_UNUSED(name); SPDF_PAINT_UNUSED(above);
    return NULL;
}

spdf_paint_layer* spdf_paint_layer_find(spdf_paint_doc* doc, spdf_paint_id id) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(id);
    return NULL;
}

int spdf_paint_layer_index(const spdf_paint_doc* doc, spdf_paint_id id) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(id);
    return -1;
}

fz_pixmap* spdf_paint_active_pixels(spdf_paint_doc* doc, spdf_paint_layer** layer_out) {
    SPDF_PAINT_UNUSED(doc);
    if (layer_out) *layer_out = NULL;
    return NULL;
}

spdf_paint_object* spdf_paint_object_new(spdf_paint_doc* doc, spdf_paint_object_kind kind, spdf_paint_id* id_out) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(kind);
    if (id_out) *id_out = 0;
    return NULL;
}

void spdf_paint_object_free(fz_context* ctx, spdf_paint_object* object) {
    SPDF_PAINT_UNUSED(ctx); SPDF_PAINT_UNUSED(object);
}

spdf_paint_object* spdf_paint_object_clone(fz_context* ctx, const spdf_paint_object* object) {
    SPDF_PAINT_UNUSED(ctx); SPDF_PAINT_UNUSED(object);
    return NULL;
}

void spdf_paint_object_update_bounds(spdf_paint_object* object) { SPDF_PAINT_UNUSED(object); }

int spdf_paint_object_draw(spdf_paint_doc* doc, const spdf_paint_object* object, fz_matrix ctm, fz_pixmap* dest,
                           fz_irect clip, float opacity) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(object); SPDF_PAINT_UNUSED(ctm); SPDF_PAINT_UNUSED(dest);
    SPDF_PAINT_UNUSED(clip); SPDF_PAINT_UNUSED(opacity);
    return 0;
}

void spdf_paint_damage(spdf_paint_doc* doc, spdf_rect rect) { SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(rect); }

void spdf_paint_damage_all(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }

fz_irect spdf_paint_raster_box(const spdf_paint_doc* doc, spdf_rect rect) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(rect);
    fz_irect none = {0, 0, 0, 0};
    return none;
}

int spdf_paint_parse_color(const char* text, spdf_paint_color* out) {
    SPDF_PAINT_UNUSED(text); SPDF_PAINT_UNUSED(out);
    return 0;
}

void spdf_paint_format_color(spdf_paint_color color, char out[10]) {
    SPDF_PAINT_UNUSED(color);
    out[0] = 0;
}

/* ---- Handlers (spdf_paint_handlers.h) ---- */

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_select_rect)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_select_freeform)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_select_all)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_select_none)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_select_invert)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_select_delete)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_select_lift)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_select_transparent)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_pen_add)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_arrow_add)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_erase_lines)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_picture_add)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_object_update)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_object_move)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_object_transform)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_object_order)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_object_merge_down)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_object_duplicate)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_object_delete)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_layer_add)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_layer_duplicate)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_layer_delete)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_layer_merge_down)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_layer_set)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_layer_order)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_layer_activate)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_colors_set)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_palette_set_custom)
