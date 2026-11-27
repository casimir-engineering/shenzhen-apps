#pragma once
/* CORE-INTERNAL (Core A): helpers shared by the units of the canvas model, history, files and transforms, which
 * spdf_paint_internal.h does not declare. Other units may use them too; nothing here is a frontend API.
 *
 * Conventions every unit follows:
 * - Strings and arrays inside objects (points, text, font, nm) are allocated with fz_malloc/fz_strdup on doc->ctx;
 *   spdf_paint_object_free releases them with fz_free.
 * - A layer's pixels cover the whole canvas at raster scale, x = y = 0. The selection mask (n = 1) covers only its
 *   bounds: its x, y are its place in raster pixels, and outside it nothing is selected.
 * - An empty layer name means "named after what it holds" (spdf_paint_layer_display_name): "Rectangle", "Text: Hi".
 * - Pen lines and arrows keep rotation and flips baked into their points; place.rect is their points' box. */
#include "spdf_paint_handlers.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- spdf_paint_doc.c ---- */

fz_pixmap* spdf_paint_pixmap_new(fz_context* ctx, int w, int h); /* RGBA, transparent, x = y = 0 */
/* The layer's pixels, made (transparent, canvas-sized) when it had none; NULL for object layers and a PDF page. */
fz_pixmap* spdf_paint_layer_pixels(spdf_paint_doc* doc, spdf_paint_layer* layer);
/* Pixels the pixel tools may change: a raster layer, or a picture's or canvas's Background. */
int spdf_paint_layer_paintable(const spdf_paint_doc* doc, const spdf_paint_layer* layer);
int spdf_paint_layer_is_page(const spdf_paint_doc* doc, const spdf_paint_layer* layer); /* a PDF page's Background */
/* The nearest paintable layer below index, or -1. */
int spdf_paint_paintable_below(const spdf_paint_doc* doc, int index);
spdf_paint_layer* spdf_paint_layer_clone(fz_context* ctx, const spdf_paint_layer* layer, int with_pixels);
void spdf_paint_layer_free(fz_context* ctx, spdf_paint_layer* layer);
/* Takes the layer out of the stack (no history, not freed). */
spdf_paint_layer* spdf_paint_layer_detach(spdf_paint_doc* doc, spdf_paint_id id);
void spdf_paint_layer_insert(spdf_paint_doc* doc, spdf_paint_layer* layer, int index);
/* Removes and frees a layer, recording it on the open history step, fixing the active layer and the selection. */
void spdf_paint_layer_delete(spdf_paint_doc* doc, spdf_paint_layer* layer);
void spdf_paint_layer_display_name(const spdf_paint_doc* doc, const spdf_paint_layer* layer, char* out, size_t cap);
const char* spdf_paint_layer_kind_name(spdf_paint_layer_kind kind);
const char* spdf_paint_object_kind_name(spdf_paint_object_kind kind);
/* Sets the canvas size (canvas units) and resets the composite cache; layers are the caller's. */
void spdf_paint_set_size(spdf_paint_doc* doc, int width, int height);
void spdf_paint_tiles_free(spdf_paint_doc* doc);
/* After a change to `layer` (NULL: the whole canvas): damage, generation and, on a PDF page, the bridge's note. */
void spdf_paint_changed(spdf_paint_doc* doc, spdf_paint_layer* layer, spdf_rect rect);
spdf_rect spdf_paint_canvas_rect(const spdf_paint_doc* doc);
spdf_rect spdf_paint_points_box(const spdf_paint_point* points, int count);
int spdf_paint_object_has_points(const spdf_paint_object* object); /* pen, arrow, line, curve, polygon, arrow line */
spdf_paint_point* spdf_paint_points_copy(fz_context* ctx, const spdf_paint_point* points, int count);
/* The topmost visible object at (x, y) within slop canvas units; 0 when none. */
spdf_paint_id spdf_paint_hit_object(spdf_paint_doc* doc, float x, float y, float slop);
/* Selected objects: replaces the list (ids that are not objects are dropped), clears it, drops missing ids. */
void spdf_paint_select_objects(spdf_paint_doc* doc, const spdf_paint_id* ids, int count);
void spdf_paint_selection_free(fz_context* ctx, spdf_paint_selection* selection);
void spdf_paint_selection_copy(fz_context* ctx, spdf_paint_selection* dst, const spdf_paint_selection* src);
void spdf_paint_selection_prune(spdf_paint_doc* doc);
/* Mask value 0-255 at raster pixel (x, y): 255 everywhere when there is no pixel selection. */
int spdf_paint_mask_at(const fz_pixmap* mask, int x, int y);
/* Premultiplied RGBA bytes of a colour. */
void spdf_paint_color_bytes(spdf_paint_color color, unsigned char out[4]);

/* ---- spdf_paint_history.c ---- */

void spdf_paint_history_save_dpi(spdf_paint_doc* doc); /* a canvas record of the resolution alone */
/* spdf_paint_history_apply.c: one step's records, undone (last first) or redone (first first). */
void spdf_paint_history_apply_step(spdf_paint_doc* doc, spdf_paint_step* step, int undo);

/* ---- spdf_paint_composite.c ---- */

/* The composite into dest (positioned in device pixels, `scale` device pixels per canvas unit), inside clip.
 * filter: only these ids (visibility ignored) when count > 0. */
void spdf_paint_composite_into(spdf_paint_doc* doc, fz_pixmap* dest, fz_irect clip, float scale, unsigned flags,
                               const spdf_paint_id* filter, int filter_count);
/* One raster layer's pixels over dest at `scale`, opacity 0-1. */
void spdf_paint_draw_raster(spdf_paint_doc* doc, fz_pixmap* src, fz_pixmap* dest, fz_irect clip, float scale,
                            float opacity, int nearest);
/* The placement's matrix: object canvas units -> canvas units (rotation and flips about the box centre). */
fz_matrix spdf_paint_placement_matrix(const spdf_paint_placement* place);
/* An RGBA copy of `pix` with alpha, premultiplied (any colourspace in). */
fz_pixmap* spdf_paint_pixmap_to_rgba(fz_context* ctx, fz_pixmap* pix);
/* Decodes a picture file's bytes (PNG, JPEG, ... what MuPDF reads) into an RGBA pixmap. */
fz_pixmap* spdf_paint_decode_picture(fz_context* ctx, fz_buffer* bytes);

/* ---- spdf_paint_objjson.c ---- */

/* exact 0 rounds numbers to 1/1000 (doc.state); 1 keeps them whole (the .szpaint manifest). */
cJSON* spdf_paint_object_json(const spdf_paint_doc* doc, const spdf_paint_object* object, int exact);
/* {"id","kind","name","visible","opacity","locked","bounds",...,"object"} for doc.state and the manifest. */
cJSON* spdf_paint_layer_json(const spdf_paint_doc* doc, const spdf_paint_layer* layer);
cJSON* spdf_paint_rect_json(spdf_rect rect);
cJSON* spdf_paint_point_json(spdf_paint_point point);
cJSON* spdf_paint_color_json(spdf_paint_color color);
/* Sets the object's settings from an object.update-style JSON object (the add operations' names); unknown names for
 * the object's kind fail with a sentence in msg. Colours default to the doc's when a style is first made solid. */
spdf_paint_status spdf_paint_object_apply_json(spdf_paint_doc* doc, spdf_paint_object* object, const cJSON* args,
                                               char* msg, size_t msg_cap);
int spdf_paint_json_rect(const cJSON* item, spdf_rect* out);
int spdf_paint_json_point(const cJSON* item, spdf_paint_point* out);
int spdf_paint_json_points(fz_context* ctx, const cJSON* item, spdf_paint_point** out, int* count);
int spdf_paint_json_color(const cJSON* item, spdf_paint_color* out);
const char* spdf_paint_style_name(spdf_paint_style style);
int spdf_paint_style_from_name(const char* name, spdf_paint_style* out);

/* ---- spdf_paint_validate.c ---- */

/* Checks `value` against the operation schema `schema` ($refs into defs); 0 and a sentence in msg when it fails. */
int spdf_paint_validate(const cJSON* value, const cJSON* schema, const cJSON* defs, char* msg, size_t msg_cap);

/* ---- spdf_paint_select.c ---- */

/* Lifts the pixel selection out of the active layer into a Picture object just above it (the transparent-selection
 * rule applied) and selects it; *id_out its id. Fails with page_locked on a PDF page with nothing drawn. */
spdf_paint_status spdf_paint_lift_selection(spdf_paint_call* call, spdf_paint_id* id_out);
/* select.objects {ids} (added to the schema by Core A): which objects are selected. */
spdf_paint_status spdf_paint_op_select_objects(spdf_paint_call* call);

/* ---- spdf_paint_layers.c ---- */

/* Moves the layers `ids` to `to` ("front", "forward", "backward", "back" or a position from the bottom, 0 just above
 * the Background), keeping their order; the Background never moves. */
spdf_paint_status spdf_paint_order_layers(spdf_paint_call* call, const spdf_paint_id* ids, int count,
                                          const cJSON* to);
/* Draws the object into the paintable layer below it (made on a PDF page when there is none) and deletes it. */
spdf_paint_status spdf_paint_merge_object_down(spdf_paint_call* call, spdf_paint_layer* layer);

/* ---- spdf_paint_groups.c: layers holding objects ---- */

extern const char spdf_paint_first_layer_name[]; /* "Layer 1" */
int spdf_paint_is_layer(const spdf_paint_layer* entry); /* the base layer or a layer, not an object */
/* The index of the layer holding entry `index`: itself for a layer or the base layer, else the nearest layer below;
 * -1 for an object with none under it. */
int spdf_paint_owner_index(const spdf_paint_doc* doc, int index);
spdf_paint_layer* spdf_paint_owner(spdf_paint_doc* doc, const spdf_paint_layer* entry);
int spdf_paint_group_end(const spdf_paint_doc* doc, int layer_index); /* one past the layer's last object */
int spdf_paint_layer_ordinal(const spdf_paint_doc* doc, int layer_index); /* 1 for the lowest layer */
/* As drawn: shown (its own eye and its layer's), opacity (its own times its layer's), locked (or its layer). */
int spdf_paint_entry_shown(const spdf_paint_doc* doc, int index);
float spdf_paint_entry_opacity(const spdf_paint_doc* doc, int index);
int spdf_paint_entry_locked(const spdf_paint_doc* doc, int index);
/* The layer new objects go into: the active one, else the lowest; "Layer 1" is made when there is none. */
spdf_paint_layer* spdf_paint_home_layer(spdf_paint_doc* doc);
/* Where a new object goes in the list: on top of the home layer (source NULL), at the bottom of `source` when it is a
 * layer (a lifted selection keeps its place), at the bottom of the lowest layer when `source` is the base layer. */
int spdf_paint_object_insert_index(spdf_paint_doc* doc, const spdf_paint_layer* source);
/* Old stacks (one object per layer): objects right above the base layer, or no layer at all, get a new "Layer 1"
 * just above the base layer. No history. 1 when it changed. */
int spdf_paint_normalize_layers(spdf_paint_doc* doc);
/* Fails the call for a layer the pixel tools can't change: a locked layer, else the PDF page. */
spdf_paint_status spdf_paint_fail_unpaintable(spdf_paint_call* call, const spdf_paint_layer* layer);
cJSON* spdf_paint_layers_json(const spdf_paint_doc* doc); /* doc.state "layers": each with its "objects" */
spdf_paint_status spdf_paint_op_object_layer(spdf_paint_call* call);

/* ---- spdf_paint_transform_ops.c ---- */

/* Moves an object through m (canvas units), its own size times (sx, sy), turned by rot degrees, flipped (1
 * horizontal, 2 vertical); line widths and text sizes times size_scale. Points of lines are mapped exactly. */
void spdf_paint_map_object(spdf_paint_object* o, fz_matrix m, float sx, float sy, float rot, int flip,
                           float size_scale);

/* ---- spdf_paint_transform.c ---- */

/* src (raster pixels) through m (src pixel space -> dst pixel space) into a new transparent w x h pixmap, bilinear. */
fz_pixmap* spdf_paint_affine_pixmap(fz_context* ctx, const fz_pixmap* src, fz_matrix m, int w, int h);
void spdf_paint_flip_pixmap(fz_pixmap* pix, int horizontal);
/* Exact quarter turns clockwise (1, 2, 3). New pixmap. */
fz_pixmap* spdf_paint_quarter_pixmap(fz_context* ctx, const fz_pixmap* src, int quarters);
/* A w x h pixmap holding src at (dx, dy), the rest `fill` (premultiplied bytes, NULL: transparent). */
fz_pixmap* spdf_paint_place_pixmap(fz_context* ctx, const fz_pixmap* src, int w, int h, int dx, int dy,
                                   const unsigned char* fill);
/* In place, inside box, weighted by mask (NULL: all): RGB inverted; black and white. */
void spdf_paint_invert_pixels(fz_pixmap* pix, fz_irect box, const fz_pixmap* mask);
void spdf_paint_black_white_pixels(fz_pixmap* pix);
/* Fills the transparent area of pix (only where alpha < 255) under `fill`, as a picture without alpha shows it. */
void spdf_paint_flatten_onto(fz_pixmap* pix, const unsigned char* fill);

#ifdef __cplusplus
}
#endif
