#pragma once
/* CORE-INTERNAL: the C entry of every operation spdf_paint_apply carries out (docs/plans/annotate.md § 6), one
 * function per operation, named spdf_paint_op_<family>_<name> after the operation ("paint.stroke" ->
 * spdf_paint_op_paint_stroke). spdf_paint_ops.c validates the JSON against the operation's argument schema
 * (spdf_paint_schema.c), opens a history step for an undoable operation, calls the handler from its dispatch table,
 * closes the step (rolled back when the handler failed) and prints the answer.
 *
 * A handler reads call->args (the whole operation object, already valid against its schema, defaults NOT filled in:
 * read them with the spdf_paint_arg_* helpers, which apply the schema's defaults), changes call->doc through the
 * units' entry points in spdf_paint_internal.h (which record history), adds its answer's fields to call->reply
 * ({"ok":true} already there) and returns SPDF_PAINT_OK, or fails with spdf_paint_call_fail. On a PDF page canvas,
 * anything that would change the page answers SPDF_PAINT_ERR_PAGE_LOCKED.
 *
 * Operations not declared here have no core handler (form.*, doc.save, doc.save_as, doc.save_as_pdf, doc.copy,
 * mode.set, view.*, tool.choose, canvas.new): spdf_paint_apply answers them SPDF_PAINT_ERR_FRONTEND. canvas.new makes
 * its canvas with spdf_paint_new_canvas. */
#include "spdf_paint_internal.h"

#include "cJSON.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_paint_call {
    spdf_paint_doc* doc;
    const cJSON* args;                   /* {"op": ..., arguments} */
    const spdf_paint_op_info* op;
    const spdf_paint_apply_input* input; /* never NULL: an all-NULL input when the caller gave none */
    cJSON* reply;                        /* the answer object, "ok" set */
    spdf_paint_status status;            /* set by spdf_paint_call_fail */
    char message[512];                   /* the answer's plain sentence on failure */
} spdf_paint_call;

typedef spdf_paint_status (*spdf_paint_handler)(spdf_paint_call* call);

/* Wave 0: a handler that is not written yet. Each unit replaces its lines with the real function. */
#define SPDF_PAINT_STUB_HANDLER(name) \
    spdf_paint_status name(spdf_paint_call* call) { SPDF_PAINT_UNUSED(call); return SPDF_PAINT_ERR_NOT_IMPLEMENTED; }

/* Fails the call: sets status and message (printf-style) and returns status, so `return spdf_paint_call_fail(...)`. */
spdf_paint_status spdf_paint_call_fail(spdf_paint_call* call, spdf_paint_status status, const char* format, ...);

/* Argument readers (spdf_paint_ops.c): the value, or the schema default when the argument is absent. A rect is
 * {"x","y","w","h"}, a point [x, y] or [x, y, pressure]; points/ids allocate with fz_malloc on doc->ctx (free with
 * fz_free). Each returns 1 when the argument was present, 0 when the default was used. */
int spdf_paint_arg_number(const spdf_paint_call* call, const char* name, double* out);
int spdf_paint_arg_bool(const spdf_paint_call* call, const char* name, int* out);
const char* spdf_paint_arg_string(const spdf_paint_call* call, const char* name); /* NULL when absent, no default */
int spdf_paint_arg_color(const spdf_paint_call* call, const char* name, spdf_paint_color* out); /* "transparent" = 0 */
int spdf_paint_arg_rect(const spdf_paint_call* call, const char* name, spdf_rect* out);
int spdf_paint_arg_points(const spdf_paint_call* call, const char* name, spdf_paint_point** out, int* count);
int spdf_paint_arg_ids(const spdf_paint_call* call, spdf_paint_id** out, int* count); /* "id" or "ids" */
spdf_paint_scope spdf_paint_arg_scope(const spdf_paint_call* call);
/* The operation's page (1-based in JSON) checked against the canvas: on a PDF page canvas it must be that page. */
spdf_paint_status spdf_paint_arg_check_page(spdf_paint_call* call);

/* The dispatch table (spdf_paint_ops.c): handler by operation name, NULL when the frontend answers it. */
spdf_paint_handler spdf_paint_handler_for(const char* op_name);

/* The built schema (spdf_paint_schema.c), for the validator: one operation's object schema ("properties",
 * "required", "anyOf", "additionalProperties": false; $refs point into the defs), and "$defs". NULL when unknown. */
const cJSON* spdf_paint_schema_operation(const char* name);
const cJSON* spdf_paint_schema_defs(void);

/* ---- Canvas (spdf_paint_transform.c) ---- */
spdf_paint_status spdf_paint_op_canvas_resize(spdf_paint_call* call);     /* {width, height, anchor, fill} */
spdf_paint_status spdf_paint_op_canvas_properties(spdf_paint_call* call); /* {dpi, blackAndWhite} */

/* ---- Image (spdf_paint_transform.c) ---- */
spdf_paint_status spdf_paint_op_image_resize(spdf_paint_call* call);  /* {width, height | percent, keepRatio, scope} */
spdf_paint_status spdf_paint_op_image_skew(spdf_paint_call* call);    /* {horizontal, vertical, scope} */
spdf_paint_status spdf_paint_op_image_rotate(spdf_paint_call* call);  /* {degrees, scope} */
spdf_paint_status spdf_paint_op_image_flip(spdf_paint_call* call);    /* {axis, scope} */
spdf_paint_status spdf_paint_op_image_crop(spdf_paint_call* call);    /* {rect?}: the selection's box when absent */
spdf_paint_status spdf_paint_op_image_invert(spdf_paint_call* call);  /* {scope} */
spdf_paint_status spdf_paint_op_image_clear(spdf_paint_call* call);   /* {} the active layer */
/* {scope}: applies input->mask (the frontend's subject mask); refused without one. */
spdf_paint_status spdf_paint_op_image_remove_background(spdf_paint_call* call);

/* ---- Selection (spdf_paint_doc.c) ---- */
spdf_paint_status spdf_paint_op_select_rect(spdf_paint_call* call);     /* {x, y, w, h} */
spdf_paint_status spdf_paint_op_select_freeform(spdf_paint_call* call); /* {points} */
spdf_paint_status spdf_paint_op_select_all(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_select_none(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_select_invert(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_select_delete(spdf_paint_call* call);   /* selected pixels to transparent, or objects */
spdf_paint_status spdf_paint_op_select_lift(spdf_paint_call* call);     /* answers {"id": the new Picture object} */
spdf_paint_status spdf_paint_op_select_transparent(spdf_paint_call* call); /* {on} */

/* ---- Pen and arrow (spdf_paint_doc.c; on a PDF the Mac routes these to Fill & Sign) ---- */
spdf_paint_status spdf_paint_op_pen_add(spdf_paint_call* call);     /* {points, color, width} -> {"id"} */
spdf_paint_status spdf_paint_op_arrow_add(spdf_paint_call* call);   /* {tail, tip, color, width} -> {"id"} */
spdf_paint_status spdf_paint_op_erase_lines(spdf_paint_call* call); /* {points, size} -> {"removed": [ids]} */

/* ---- Pixels (spdf_paint_brush.c, spdf_paint_fill.c) ---- */
spdf_paint_status spdf_paint_op_paint_stroke(spdf_paint_call* call); /* {tool, points, color?, size, opacity, seed?} */
spdf_paint_status spdf_paint_op_paint_fill(spdf_paint_call* call);   /* {x, y, color?, tolerance, contiguous} */
spdf_paint_status spdf_paint_op_color_pick(spdf_paint_call* call);   /* {x, y, from} -> {"color": "#RRGGBBAA"} */

/* ---- Objects (spdf_paint_shapes.c, spdf_paint_text.c, spdf_paint_doc.c) ---- */
spdf_paint_status spdf_paint_op_shape_add(spdf_paint_call* call);   /* -> {"id"} */
/* The shape.add / text.add arguments (shapeProps, textProps) read into an object of that kind, defaults from the
 * canvas (Color 1, Color 2) and the schema (Core B, spdf_paint_shapes_draw.c / spdf_paint_text.c). update 0: a new
 * object, every argument or its default; update 1 (object.update): only the arguments present change. Sets the
 * placement rect (a line's or polygon's rect is its points' bounds; a text box grows to fit its text) and the
 * bounds. On failure the object is unchanged and the call's message says why. */
spdf_paint_status spdf_paint_shape_read_args(spdf_paint_call* call, spdf_paint_object* object, int update);
spdf_paint_status spdf_paint_text_read_args(spdf_paint_call* call, spdf_paint_object* object, int update);
spdf_paint_status spdf_paint_op_text_add(spdf_paint_call* call);    /* -> {"id"} */
spdf_paint_status spdf_paint_op_picture_add(spdf_paint_call* call); /* input->picture or png_base64 -> {"id"} */
spdf_paint_status spdf_paint_op_object_update(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_object_move(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_object_transform(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_object_order(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_object_merge_down(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_object_duplicate(spdf_paint_call* call); /* -> {"id", "ids"} */
spdf_paint_status spdf_paint_op_object_delete(spdf_paint_call* call);

/* ---- Layers (spdf_paint_doc.c) ---- */
spdf_paint_status spdf_paint_op_layer_add(spdf_paint_call* call);       /* -> {"id"} */
spdf_paint_status spdf_paint_op_layer_duplicate(spdf_paint_call* call); /* -> {"id"} */
spdf_paint_status spdf_paint_op_layer_delete(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_layer_merge_down(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_layer_set(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_layer_order(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_layer_activate(spdf_paint_call* call);

/* ---- Colours (spdf_paint_doc.c) ---- */
spdf_paint_status spdf_paint_op_colors_set(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_palette_set_custom(spdf_paint_call* call);

/* ---- History (spdf_paint_history.c): one canvas's history; a PDF tab's frontend picks the canvas ---- */
spdf_paint_status spdf_paint_op_history_undo(spdf_paint_call* call); /* {steps} */
spdf_paint_status spdf_paint_op_history_redo(spdf_paint_call* call);

/* ---- Document (spdf_paint_ops.c, spdf_paint_file.c) ---- */
/* {page?} -> size, dpi, layers and objects bottom to top (ids, kinds, names, bounds, parameters, visible, opacity,
 * locked), active layer, selection, colours, custom palette, dirty, canUndo/canRedo. The frontend adds file, format,
 * zoom and tool. */
spdf_paint_status spdf_paint_op_doc_state(spdf_paint_call* call);
spdf_paint_status spdf_paint_op_doc_render(spdf_paint_call* call); /* {out, region?, scale?, layers?} -> {"path"} */

#ifdef __cplusplus
}
#endif
