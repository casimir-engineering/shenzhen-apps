/* Annotate's undo and redo (docs/plans/annotate.md § 4, § 8 Core spdf_paint_history.c): raster changes as 256 x 256
 * tile snapshots, object changes as before/after parameter copies, one step per operation, 1 GB cap per canvas
 * (oldest steps dropped first), the saved point for the dirty state, and the history.undo / history.redo handlers.
 *
 * WAVE 0 STUB (Core A implements): every function answers SPDF_PAINT_ERR_NOT_IMPLEMENTED or does nothing. */
#include "spdf_paint_handlers.h"

/* ---- Public ---- */

spdf_paint_status spdf_paint_undo(spdf_paint_doc* doc, int steps) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(steps);
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_status spdf_paint_redo(spdf_paint_doc* doc, int steps) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(steps);
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

int spdf_paint_can_undo(const spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); return 0; }

int spdf_paint_can_redo(const spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); return 0; }

const char* spdf_paint_undo_name(const spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); return NULL; }

const char* spdf_paint_redo_name(const spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); return NULL; }

const char* spdf_paint_last_operation(const spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); return NULL; }

void spdf_paint_set_history_cap(spdf_paint_doc* doc, size_t bytes) { SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(bytes); }

size_t spdf_paint_history_bytes(const spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); return 0; }

int spdf_paint_is_dirty(const spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); return 0; }

void spdf_paint_mark_saved(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }

/* ---- Internal (spdf_paint_internal.h) ---- */

void spdf_paint_history_begin(spdf_paint_doc* doc, const char* op_json) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(op_json);
}

void spdf_paint_history_end(spdf_paint_doc* doc, int keep) { SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(keep); }

void spdf_paint_history_save_pixels(spdf_paint_doc* doc, spdf_paint_layer* layer, fz_irect box) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer); SPDF_PAINT_UNUSED(box);
}

void spdf_paint_history_save_object(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer);
}

void spdf_paint_history_save_layer_props(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer);
}

void spdf_paint_history_save_order(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }

void spdf_paint_history_save_canvas(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }

void spdf_paint_history_save_active(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }

void spdf_paint_history_added_layer(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer);
}

void spdf_paint_history_removing_layer(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer);
}

void spdf_paint_history_free(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }

/* ---- Handlers ---- */

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_history_undo)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_history_redo)
