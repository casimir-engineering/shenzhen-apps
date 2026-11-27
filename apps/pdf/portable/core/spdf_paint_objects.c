/* Annotate's objects (docs/plans/annotate.md § 3, § 6 Objects, Pen and arrow): making, copying and freeing objects,
 * their bounds, and the handlers of pen.add, arrow.add, erase.lines, picture.add, object.update, object.move,
 * object.transform, object.order, object.merge_down, object.duplicate and object.delete. Every object is its own
 * layer, so it keeps its depth. shape.add and text.add are Core B's (spdf_paint_shapes.c, spdf_paint_text.c). */
#include "spdf_paint_model.h"

#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ---- Lifecycle ---- */

spdf_paint_object* spdf_paint_object_new(spdf_paint_doc* doc, spdf_paint_object_kind kind, spdf_paint_id* id_out) {
    if (id_out) *id_out = 0;
    spdf_paint_object* o = doc ? calloc(1, sizeof(*o)) : NULL;
    if (!o) return NULL;
    o->kind = kind;
    int at = spdf_paint_object_insert_index(doc, NULL); /* on top of the active layer's objects */
    spdf_paint_layer* layer =
        spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_OBJECT, NULL, at > 0 ? doc->layers[at - 1]->id : 0);
    if (!layer) { free(o); return NULL; }
    layer->object = o;
    if (id_out) *id_out = layer->id;
    return o;
}

void spdf_paint_object_free(fz_context* ctx, spdf_paint_object* o) {
    if (!o) return;
    switch (o->kind) {
    case SPDF_PAINT_OBJ_SHAPE: fz_free(ctx, o->u.shape.points); break;
    case SPDF_PAINT_OBJ_TEXT:
        fz_free(ctx, o->u.text.utf8);
        fz_free(ctx, o->u.text.font);
        fz_free(ctx, o->u.text.resolved_font);
        break;
    case SPDF_PAINT_OBJ_PICTURE: fz_drop_pixmap(ctx, o->u.picture.pixels); break;
    case SPDF_PAINT_OBJ_PEN:
    case SPDF_PAINT_OBJ_ARROW: fz_free(ctx, o->u.line.points); break;
    case SPDF_PAINT_OBJ_FILL_TEXT:
    case SPDF_PAINT_OBJ_FILL_MARK:
    case SPDF_PAINT_OBJ_FILL_SIGNATURE:
        fz_free(ctx, o->u.fill.nm);
        fz_free(ctx, o->u.fill.text);
        break;
    case SPDF_PAINT_OBJ_FOREIGN: break;
    }
    fz_free(ctx, o->pdf_nm);
    free(o);
}

static char* dup(fz_context* ctx, const char* s) {
    char* copy = NULL;
    if (!s) return NULL;
    fz_try(ctx) copy = fz_strdup(ctx, s);
    fz_catch(ctx) { fz_ignore_error(ctx); copy = NULL; }
    return copy;
}

spdf_paint_object* spdf_paint_object_clone(fz_context* ctx, const spdf_paint_object* o) {
    if (!o) return NULL;
    spdf_paint_object* c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    *c = *o;
    c->pdf_nm = dup(ctx, o->pdf_nm);
    switch (o->kind) {
    case SPDF_PAINT_OBJ_SHAPE:
        c->u.shape.points = spdf_paint_points_copy(ctx, o->u.shape.points, o->u.shape.point_count);
        if (!c->u.shape.points) c->u.shape.point_count = 0;
        break;
    case SPDF_PAINT_OBJ_TEXT:
        c->u.text.utf8 = dup(ctx, o->u.text.utf8);
        c->u.text.font = dup(ctx, o->u.text.font);
        c->u.text.resolved_font = dup(ctx, o->u.text.resolved_font);
        break;
    case SPDF_PAINT_OBJ_PICTURE:
        c->u.picture.pixels = NULL;
        fz_try(ctx) if (o->u.picture.pixels) c->u.picture.pixels = fz_clone_pixmap(ctx, o->u.picture.pixels);
        fz_catch(ctx) fz_ignore_error(ctx);
        break;
    case SPDF_PAINT_OBJ_PEN:
    case SPDF_PAINT_OBJ_ARROW:
        c->u.line.points = spdf_paint_points_copy(ctx, o->u.line.points, o->u.line.point_count);
        if (!c->u.line.points) c->u.line.point_count = 0;
        break;
    case SPDF_PAINT_OBJ_FILL_TEXT:
    case SPDF_PAINT_OBJ_FILL_MARK:
    case SPDF_PAINT_OBJ_FILL_SIGNATURE:
        c->u.fill.nm = dup(ctx, o->u.fill.nm);
        c->u.fill.text = dup(ctx, o->u.fill.text);
        break;
    case SPDF_PAINT_OBJ_FOREIGN: break;
    }
    return c;
}

static spdf_rect transformed(spdf_rect r, fz_matrix m) {
    fz_rect fr = fz_transform_rect(fz_make_rect(r.x0, r.y0, r.x1, r.y1), m);
    spdf_rect out = {fr.x0, fr.y0, fr.x1, fr.y1};
    return out;
}

void spdf_paint_object_update_bounds(spdf_paint_object* o) {
    if (!o) return;
    fz_matrix m = spdf_paint_placement_matrix(&o->place);
    if (o->kind == SPDF_PAINT_OBJ_SHAPE) {
        o->bounds = spdf_paint_shape_bounds(&o->place, &o->u.shape);
        if (o->bounds.x1 <= o->bounds.x0 && o->bounds.y1 <= o->bounds.y0) o->bounds = transformed(o->place.rect, m);
        return;
    }
    if (o->kind != SPDF_PAINT_OBJ_PEN && o->kind != SPDF_PAINT_OBJ_ARROW) {
        o->bounds = transformed(o->place.rect, m);
        return;
    }
    const spdf_paint_line_params* line = &o->u.line;
    spdf_rect r = spdf_paint_points_box(line->points, line->point_count);
    float half = line->width / 2 + 1;
    if (o->kind == SPDF_PAINT_OBJ_ARROW && line->point_count >= 2) {
        spdf_fill_point tail = {line->points[0].x, line->points[0].y}, head[3];
        spdf_fill_point tip = {line->points[line->point_count - 1].x, line->points[line->point_count - 1].y};
        spdf_ink_arrow_head(tail, tip, line->width, head);
        for (int i = 0; i < 3; i++) {
            r.x0 = fminf(r.x0, head[i].x); r.y0 = fminf(r.y0, head[i].y);
            r.x1 = fmaxf(r.x1, head[i].x); r.y1 = fmaxf(r.y1, head[i].y);
        }
    }
    r.x0 -= half; r.y0 -= half; r.x1 += half; r.y1 += half;
    o->bounds = transformed(r, m);
}

/* ---- Shared by the handlers ---- */

static spdf_paint_status find_object(spdf_paint_call* call, spdf_paint_id id, spdf_paint_layer** out) {
    spdf_paint_layer* layer = spdf_paint_layer_find(call->doc, id);
    *out = layer;
    if (!layer || !layer->object)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no object %u.", (unsigned)id);
    if (layer->locked || layer->object->kind == SPDF_PAINT_OBJ_FOREIGN)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_LOCKED,
                                    "This annotation was made in another app and can't be changed here.");
    if (spdf_paint_entry_locked(call->doc, spdf_paint_layer_index(call->doc, id)))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_LOCKED, "This object's layer is locked.");
    return SPDF_PAINT_OK;
}

static void line_points_set(spdf_paint_object* o) {
    o->place.rect = spdf_paint_points_box(o->u.line.points, o->u.line.point_count);
    spdf_paint_object_update_bounds(o);
}

static spdf_paint_status reply_new(spdf_paint_call* call, spdf_paint_object* o, spdf_paint_id id) {
    spdf_paint_layer* layer = spdf_paint_layer_find(call->doc, id);
    spdf_paint_object_update_bounds(o);
    spdf_paint_changed(call->doc, layer, o->bounds);
    cJSON_AddNumberToObject(call->reply, "id", id);
    return SPDF_PAINT_OK;
}

static spdf_paint_status add_line(spdf_paint_call* call, spdf_paint_object_kind kind, spdf_paint_point* points,
                                  int count) {
    spdf_paint_color color = 0x000000FFu;
    double width = 2;
    spdf_paint_arg_color(call, "color", &color);
    spdf_paint_arg_number(call, "width", &width);
    spdf_paint_id id = 0;
    spdf_paint_object* o = spdf_paint_object_new(call->doc, kind, &id);
    if (!o) {
        fz_free(call->doc->ctx, points);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    }
    o->u.line.points = points;
    o->u.line.point_count = count;
    o->u.line.color = color;
    o->u.line.width = (float)width;
    line_points_set(o);
    return reply_new(call, o, id);
}

spdf_paint_status spdf_paint_op_pen_add(spdf_paint_call* call) {
    spdf_paint_point* points = NULL;
    int count = 0;
    spdf_paint_arg_points(call, "points", &points, &count);
    if (!count) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "A pen line needs points.");
    return add_line(call, SPDF_PAINT_OBJ_PEN, points, count);
}

spdf_paint_status spdf_paint_op_arrow_add(spdf_paint_call* call) {
    spdf_paint_point ends[2];
    if (!spdf_paint_json_point(cJSON_GetObjectItemCaseSensitive(call->args, "tail"), &ends[0]) ||
        !spdf_paint_json_point(cJSON_GetObjectItemCaseSensitive(call->args, "tip"), &ends[1]))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "An arrow needs a tail and a tip.");
    spdf_paint_point* points = spdf_paint_points_copy(call->doc->ctx, ends, 2);
    if (!points) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    return add_line(call, SPDF_PAINT_OBJ_ARROW, points, 2);
}

static spdf_fill_point* fill_points(const spdf_paint_point* points, int count) {
    spdf_fill_point* out = malloc((size_t)(count ? count : 1) * sizeof(*out));
    for (int i = 0; out && i < count; i++) { out[i].x = points[i].x; out[i].y = points[i].y; }
    return out;
}

spdf_paint_status spdf_paint_op_erase_lines(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_point* points = NULL;
    int count = 0;
    double size = 10;
    spdf_paint_arg_points(call, "points", &points, &count);
    spdf_paint_arg_number(call, "size", &size);
    spdf_fill_point* swath = fill_points(points, count);
    fz_free(doc->ctx, points);
    if (!swath) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    cJSON* removed = cJSON_AddArrayToObject(call->reply, "removed");
    for (int i = doc->layer_count - 1; i >= 0; i--) {
        spdf_paint_layer* layer = doc->layers[i];
        spdf_paint_object* o = layer->object;
        if (!o || layer->locked || (o->kind != SPDF_PAINT_OBJ_PEN && o->kind != SPDF_PAINT_OBJ_ARROW)) continue;
        spdf_fill_point* line = fill_points(o->u.line.points, o->u.line.point_count);
        float d = line ? spdf_ink_polyline_distance(line, o->u.line.point_count, swath, count) : 1e9f;
        free(line);
        if (d > (float)size / 2 + o->u.line.width / 2) continue;
        cJSON_AddItemToArray(removed, cJSON_CreateNumber(layer->id));
        spdf_paint_layer_delete(doc, layer);
        if (i > doc->layer_count) i = doc->layer_count;
    }
    free(swath);
    return SPDF_PAINT_OK;
}

/* ---- picture.add ---- */

static int b64_value(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62;
    if (c == '/' || c == '_') return 63;
    return -1;
}

static fz_buffer* b64_decode(fz_context* ctx, const char* text) {
    fz_buffer* buf = fz_new_buffer(ctx, strlen(text) * 3 / 4 + 4);
    unsigned acc = 0;
    int bits = 0;
    for (const char* p = text; *p; p++) {
        int v = b64_value((unsigned char)*p);
        if (v < 0) continue;
        acc = (acc << 6) | (unsigned)v;
        bits += 6;
        if (bits >= 8) { bits -= 8; fz_append_byte(ctx, buf, (int)((acc >> bits) & 0xFF)); }
    }
    return buf;
}

static fz_pixmap* input_pixmap(fz_context* ctx, const spdf_paint_pixels* in) {
    fz_pixmap* pix = spdf_paint_pixmap_new(ctx, in->width, in->height);
    for (int y = 0; pix && y < in->height; y++) {
        const unsigned char* s = in->rgba + (size_t)y * in->stride;
        unsigned char* d = pix->samples + y * pix->stride;
        for (int x = 0; x < in->width; x++, s += 4, d += 4) {
            unsigned a = s[3];
            for (int c = 0; c < 3; c++) d[c] = in->straight ? (unsigned char)(s[c] * a / 255) : s[c];
            d[3] = (unsigned char)a;
        }
    }
    return pix;
}

spdf_paint_status spdf_paint_op_picture_add(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    fz_context* ctx = doc->ctx;
    fz_pixmap* pix = NULL;
    const char* b64 = spdf_paint_arg_string(call, "png_base64");
    const char* path = spdf_paint_arg_string(call, "path");
    if (call->input->picture && call->input->picture->rgba) pix = input_pixmap(ctx, call->input->picture);
    else if (b64 || path) {
        fz_buffer* bytes = NULL;
        fz_try(ctx) bytes = b64 ? b64_decode(ctx, b64) : fz_read_file(ctx, path);
        fz_catch(ctx) { fz_ignore_error(ctx); bytes = NULL; }
        if (bytes) pix = spdf_paint_decode_picture(ctx, bytes);
        fz_drop_buffer(ctx, bytes);
        if (!pix)
            return spdf_paint_call_fail(call, path && !b64 ? SPDF_PAINT_ERR_IO : SPDF_PAINT_ERR_INVALID_ARGUMENT,
                                        "The picture could not be read.");
    } else
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_FRONTEND, "The app reads the clipboard; there is no picture "
                                    "here.");
    if (!pix) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    float rs = (float)doc->raster_scale;
    spdf_rect rect = {0, 0, pix->w / rs, pix->h / rs};
    if (spdf_paint_arg_rect(call, "rect", &rect)) {}
    spdf_paint_id id = 0;
    spdf_paint_object* o = spdf_paint_object_new(doc, SPDF_PAINT_OBJ_PICTURE, &id);
    if (!o) { fz_drop_pixmap(ctx, pix); return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "No memory."); }
    o->u.picture.pixels = pix;
    o->place.rect = rect;
    spdf_paint_history_save_active(doc);
    spdf_paint_select_objects(doc, &id, 1);
    cJSON_AddNumberToObject(call->reply, "width", pix->w);
    cJSON_AddNumberToObject(call->reply, "height", pix->h);
    return reply_new(call, o, id);
}

/* ---- Changing objects ---- */

static void damage_object(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    spdf_paint_object_update_bounds(layer->object);
    spdf_paint_damage(doc, layer->object->bounds);
}

spdf_paint_status spdf_paint_op_object_update(spdf_paint_call* call) {
    double id = 0;
    spdf_paint_arg_number(call, "id", &id);
    spdf_paint_layer* layer = NULL;
    if (find_object(call, (spdf_paint_id)id, &layer) != SPDF_PAINT_OK) return call->status;
    spdf_paint_history_save_object(call->doc, layer);
    damage_object(call->doc, layer);
    spdf_paint_status status =
        spdf_paint_object_apply_json(call->doc, layer->object, call->args, call->message, sizeof(call->message));
    if (status != SPDF_PAINT_OK) { call->status = status; return status; }
    damage_object(call->doc, layer);
    return SPDF_PAINT_OK;
}

static void move_points(spdf_paint_point* p, int n, float dx, float dy) {
    for (int i = 0; i < n; i++) { p[i].x += dx; p[i].y += dy; }
}

spdf_paint_status spdf_paint_op_object_move(spdf_paint_call* call) {
    spdf_paint_id* ids = NULL;
    int count = 0;
    double dx = 0, dy = 0;
    spdf_paint_arg_ids(call, &ids, &count);
    spdf_paint_arg_number(call, "dx", &dx);
    spdf_paint_arg_number(call, "dy", &dy);
    spdf_paint_status status = SPDF_PAINT_OK;
    for (int i = 0; i < count && status == SPDF_PAINT_OK; i++) {
        spdf_paint_layer* layer = NULL;
        if ((status = find_object(call, ids[i], &layer)) != SPDF_PAINT_OK) break;
        spdf_paint_object* o = layer->object;
        spdf_paint_history_save_object(call->doc, layer);
        damage_object(call->doc, layer);
        o->place.rect.x0 += (float)dx; o->place.rect.x1 += (float)dx;
        o->place.rect.y0 += (float)dy; o->place.rect.y1 += (float)dy;
        if (o->kind == SPDF_PAINT_OBJ_PEN || o->kind == SPDF_PAINT_OBJ_ARROW)
            move_points(o->u.line.points, o->u.line.point_count, (float)dx, (float)dy);
        if (o->kind == SPDF_PAINT_OBJ_SHAPE) {
            move_points(o->u.shape.points, o->u.shape.point_count, (float)dx, (float)dy);
            move_points(&o->u.shape.tail, 1, (float)dx, (float)dy);
        }
        damage_object(call->doc, layer);
    }
    fz_free(call->doc->ctx, ids);
    return status;
}

/* Maps points from the box `from` onto `to` (a zero-sized side moves without scaling). */
static void map_points(spdf_paint_point* p, int n, spdf_rect from, spdf_rect to) {
    float fw = from.x1 - from.x0, fh = from.y1 - from.y0;
    for (int i = 0; i < n; i++) {
        p[i].x = fw > 1e-4f ? to.x0 + (p[i].x - from.x0) * (to.x1 - to.x0) / fw : p[i].x + (to.x0 - from.x0);
        p[i].y = fh > 1e-4f ? to.y0 + (p[i].y - from.y0) * (to.y1 - to.y0) / fh : p[i].y + (to.y0 - from.y0);
    }
}

static void transform_points(spdf_paint_point* p, int n, fz_matrix m) {
    for (int i = 0; i < n; i++) {
        fz_point q = fz_transform_point_xy(p[i].x, p[i].y, m);
        p[i].x = q.x;
        p[i].y = q.y;
    }
}

static fz_matrix about_center(spdf_rect r, fz_matrix m) {
    float cx = (r.x0 + r.x1) / 2, cy = (r.y0 + r.y1) / 2;
    return fz_concat(fz_concat(fz_translate(-cx, -cy), m), fz_translate(cx, cy));
}

spdf_paint_status spdf_paint_op_object_transform(spdf_paint_call* call) {
    double id = 0, rotation = 0;
    spdf_paint_arg_number(call, "id", &id);
    spdf_paint_layer* layer = NULL;
    if (find_object(call, (spdf_paint_id)id, &layer) != SPDF_PAINT_OK) return call->status;
    spdf_paint_object* o = layer->object;
    spdf_paint_history_save_object(call->doc, layer);
    damage_object(call->doc, layer);
    int line = o->kind == SPDF_PAINT_OBJ_PEN || o->kind == SPDF_PAINT_OBJ_ARROW;
    spdf_rect rect;
    if (spdf_paint_arg_rect(call, "rect", &rect)) {
        if (line) map_points(o->u.line.points, o->u.line.point_count, o->place.rect, rect);
        else if (o->kind == SPDF_PAINT_OBJ_SHAPE) {
            map_points(o->u.shape.points, o->u.shape.point_count, o->place.rect, rect);
            map_points(&o->u.shape.tail, 1, o->place.rect, rect);
        }
        o->place.rect = rect;
    }
    if (spdf_paint_arg_number(call, "rotation", &rotation)) {
        if (line) transform_points(o->u.line.points, o->u.line.point_count, about_center(o->place.rect, fz_rotate((float)rotation)));
        else o->place.rotation = (float)fmod(rotation, 360.0);
    }
    const char* flip = spdf_paint_arg_string(call, "flip");
    if (flip) {
        int h = !strcmp(flip, "horizontal");
        if (line)
            transform_points(o->u.line.points, o->u.line.point_count,
                             about_center(o->place.rect, fz_scale(h ? -1.0f : 1.0f, h ? 1.0f : -1.0f)));
        else {
            if (h) o->place.flip_h = !o->place.flip_h;
            else o->place.flip_v = !o->place.flip_v;
            o->place.rotation = -o->place.rotation;
        }
    }
    if (line) line_points_set(o);
    damage_object(call->doc, layer);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_object_order(spdf_paint_call* call) {
    spdf_paint_id* ids = NULL;
    int count = 0;
    spdf_paint_arg_ids(call, &ids, &count);
    spdf_paint_status status = SPDF_PAINT_OK;
    for (int i = 0; i < count && status == SPDF_PAINT_OK; i++) {
        spdf_paint_layer* layer = NULL;
        status = find_object(call, ids[i], &layer);
    }
    if (status == SPDF_PAINT_OK)
        status = spdf_paint_order_layers(call, ids, count, cJSON_GetObjectItemCaseSensitive(call->args, "to"));
    fz_free(call->doc->ctx, ids);
    return status;
}

spdf_paint_status spdf_paint_op_object_merge_down(spdf_paint_call* call) {
    double id = 0;
    spdf_paint_arg_number(call, "id", &id);
    spdf_paint_layer* layer = NULL;
    if (find_object(call, (spdf_paint_id)id, &layer) != SPDF_PAINT_OK) return call->status;
    return spdf_paint_merge_object_down(call, layer);
}

spdf_paint_status spdf_paint_op_object_duplicate(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    double id = 0;
    spdf_paint_arg_number(call, "id", &id);
    spdf_paint_layer* layer = NULL;
    if (find_object(call, (spdf_paint_id)id, &layer) != SPDF_PAINT_OK) return call->status;
    spdf_paint_layer* copy = spdf_paint_layer_clone(doc->ctx, layer, 1);
    if (!copy || !copy->object) {
        spdf_paint_layer_free(doc->ctx, copy);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    }
    copy->id = doc->next_id++;
    fz_free(doc->ctx, copy->pdf_nm);
    copy->pdf_nm = NULL;
    fz_free(doc->ctx, copy->object->pdf_nm);
    copy->object->pdf_nm = NULL;
    if (copy->object->kind >= SPDF_PAINT_OBJ_FILL_TEXT && copy->object->kind <= SPDF_PAINT_OBJ_FILL_SIGNATURE) {
        fz_free(doc->ctx, copy->object->u.fill.nm);
        copy->object->u.fill.nm = NULL;
    }
    spdf_paint_layer_insert(doc, copy, spdf_paint_layer_index(doc, layer->id) + 1);
    spdf_paint_history_added_layer(doc, copy);
    spdf_paint_history_save_active(doc);
    spdf_paint_select_objects(doc, &copy->id, 1);
    return reply_new(call, copy->object, copy->id);
}

spdf_paint_status spdf_paint_op_object_delete(spdf_paint_call* call) {
    spdf_paint_id* ids = NULL;
    int count = 0;
    spdf_paint_arg_ids(call, &ids, &count);
    spdf_paint_status status = SPDF_PAINT_OK;
    for (int i = 0; i < count && status == SPDF_PAINT_OK; i++) {
        spdf_paint_layer* layer = NULL;
        if ((status = find_object(call, ids[i], &layer)) == SPDF_PAINT_OK) spdf_paint_layer_delete(call->doc, layer);
    }
    fz_free(call->doc->ctx, ids);
    return status;
}
