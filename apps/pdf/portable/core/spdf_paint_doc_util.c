/* Annotate's canvas model, continued (spdf_paint_doc.c): layer and object names as the Layers panel shows them,
 * points and hit tests, and the selection's bookkeeping (which objects are selected, copies, the mask lookup). */
#include "spdf_paint_model.h"

#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Names ---- */

const char* spdf_paint_object_kind_name(spdf_paint_object_kind kind) {
    static const char* names[] = {"shape", "text", "picture", "pen", "arrow", "fill_text", "fill_mark",
                                  "fill_signature", "foreign"};
    return (unsigned)kind < sizeof(names) / sizeof(names[0]) ? names[kind] : "shape";
}

static void text_name(const char* text, char* out, size_t cap) {
    char line[40];
    size_t n = 0;
    while (text && text[n] && text[n] != '\n' && n < 30) n++;
    int cut = text && text[n] && text[n] != '\n';
    while (cut && n > 0 && ((unsigned char)text[n] & 0xC0) == 0x80) n--;
    memcpy(line, text ? text : "", n);
    line[n] = 0;
    snprintf(out, cap, "Text: %s%s", line, cut ? "\xE2\x80\xA6" : "");
}

static void shape_name(spdf_paint_shape shape, char* out, size_t cap) {
    static const struct { spdf_paint_shape shape; const char* name; } special[] = {
        {SPDF_PAINT_SHAPE_STAR4, "Four-point star"}, {SPDF_PAINT_SHAPE_STAR5, "Five-point star"},
        {SPDF_PAINT_SHAPE_STAR6, "Six-point star"}, {SPDF_PAINT_SHAPE_ROUNDED_CALLOUT, "Rounded rectangular callout"}};
    for (size_t i = 0; i < sizeof(special) / sizeof(special[0]); i++)
        if (special[i].shape == shape) { snprintf(out, cap, "%s", special[i].name); return; }
    const char* name = spdf_paint_shape_name(shape);
    snprintf(out, cap, "%s", name ? name : "shape");
    for (char* p = out; *p; p++) if (*p == '_') *p = ' ';
    if (out[0] >= 'a' && out[0] <= 'z') out[0] = (char)(out[0] - 'a' + 'A');
}

void spdf_paint_layer_display_name(const spdf_paint_doc* doc, const spdf_paint_layer* layer, char* out, size_t cap) {
    SPDF_PAINT_UNUSED(doc);
    if (layer->name[0]) { snprintf(out, cap, "%s", layer->name); return; }
    const spdf_paint_object* o = layer->object;
    if (layer->kind == SPDF_PAINT_LAYER_BACKGROUND) { snprintf(out, cap, "Background"); return; }
    if (!o) { snprintf(out, cap, "Layer"); return; }
    switch (o->kind) {
    case SPDF_PAINT_OBJ_SHAPE: shape_name(o->u.shape.shape, out, cap); return;
    case SPDF_PAINT_OBJ_TEXT: text_name(o->u.text.utf8, out, cap); return;
    case SPDF_PAINT_OBJ_PICTURE: snprintf(out, cap, "Picture"); return;
    case SPDF_PAINT_OBJ_PEN: snprintf(out, cap, "Pen line"); return;
    case SPDF_PAINT_OBJ_ARROW: snprintf(out, cap, "Arrow"); return;
    case SPDF_PAINT_OBJ_FILL_TEXT: text_name(o->u.fill.text, out, cap); return;
    case SPDF_PAINT_OBJ_FILL_MARK: snprintf(out, cap, o->u.fill.fill_kind == 2 ? "Cross" : "Check"); return;
    case SPDF_PAINT_OBJ_FILL_SIGNATURE:
        snprintf(out, cap, o->u.fill.fill_kind == 4 ? "Initials" : "Signature");
        return;
    case SPDF_PAINT_OBJ_FOREIGN:
        snprintf(out, cap, "%s", o->u.foreign.subtype[0] ? o->u.foreign.subtype : "Annotation");
        return;
    }
    snprintf(out, cap, "Object");
}

/* ---- Points and hit tests ---- */

spdf_rect spdf_paint_points_box(const spdf_paint_point* points, int count) {
    spdf_rect r = {0, 0, 0, 0};
    for (int i = 0; i < count; i++) {
        if (!i) { r.x0 = r.x1 = points[i].x; r.y0 = r.y1 = points[i].y; continue; }
        r.x0 = fminf(r.x0, points[i].x); r.y0 = fminf(r.y0, points[i].y);
        r.x1 = fmaxf(r.x1, points[i].x); r.y1 = fmaxf(r.y1, points[i].y);
    }
    return r;
}

int spdf_paint_object_has_points(const spdf_paint_object* o) {
    if (!o) return 0;
    if (o->kind == SPDF_PAINT_OBJ_PEN || o->kind == SPDF_PAINT_OBJ_ARROW) return 1;
    if (o->kind != SPDF_PAINT_OBJ_SHAPE || o->u.shape.point_count <= 0) return 0;
    spdf_paint_shape s = o->u.shape.shape;
    return s == SPDF_PAINT_SHAPE_LINE || s == SPDF_PAINT_SHAPE_CURVE || s == SPDF_PAINT_SHAPE_POLYGON ||
           s == SPDF_PAINT_SHAPE_ARROW_LINE;
}

spdf_paint_point* spdf_paint_points_copy(fz_context* ctx, const spdf_paint_point* points, int count) {
    if (!points || count <= 0) return NULL;
    spdf_paint_point* copy = NULL;
    fz_try(ctx) {
        copy = fz_malloc(ctx, (size_t)count * sizeof(*copy));
        memcpy(copy, points, (size_t)count * sizeof(*copy));
    }
    fz_catch(ctx) { fz_ignore_error(ctx); copy = NULL; }
    return copy;
}

static float line_distance(const spdf_paint_line_params* line, float x, float y) {
    spdf_fill_point stack[64];
    spdf_fill_point* pts = line->point_count <= 64 ? stack : malloc((size_t)line->point_count * sizeof(*pts));
    if (!pts) return 1e9f;
    for (int i = 0; i < line->point_count; i++) { pts[i].x = line->points[i].x; pts[i].y = line->points[i].y; }
    spdf_fill_point p = {x, y};
    float d = spdf_ink_distance_to_polyline(pts, line->point_count, p);
    if (pts != stack) free(pts);
    return d;
}

spdf_paint_id spdf_paint_hit_object(spdf_paint_doc* doc, float x, float y, float slop) {
    for (int i = doc->layer_count - 1; i >= 0; i--) {
        spdf_paint_layer* layer = doc->layers[i];
        spdf_paint_object* o = layer->object;
        if (!o || !layer->visible) continue;
        if (o->kind == SPDF_PAINT_OBJ_PEN || o->kind == SPDF_PAINT_OBJ_ARROW) {
            if (o->u.line.point_count && line_distance(&o->u.line, x, y) <= o->u.line.width / 2 + slop)
                return layer->id;
            continue;
        }
        fz_matrix inv = fz_invert_matrix(spdf_paint_placement_matrix(&o->place));
        fz_point p = fz_transform_point_xy(x, y, inv);
        spdf_rect r = o->place.rect;
        if (spdf_paint_object_has_points(o)) { spdf_paint_object_update_bounds(o); r = o->bounds; }
        if (p.x >= r.x0 - slop && p.x <= r.x1 + slop && p.y >= r.y0 - slop && p.y <= r.y1 + slop) return layer->id;
    }
    return 0;
}

/* ---- Selection bookkeeping ---- */

void spdf_paint_selection_free(fz_context* ctx, spdf_paint_selection* s) {
    fz_drop_pixmap(ctx, s->mask);
    fz_free(ctx, s->outline);
    fz_free(ctx, s->objects);
    int transparent = s->transparent;
    memset(s, 0, sizeof(*s));
    s->transparent = transparent;
}

void spdf_paint_selection_copy(fz_context* ctx, spdf_paint_selection* dst, const spdf_paint_selection* src) {
    *dst = *src;
    dst->mask = NULL;
    dst->outline = NULL;
    dst->objects = NULL;
    fz_try(ctx) {
        if (src->mask) dst->mask = fz_clone_pixmap(ctx, src->mask);
        if (src->outline_count) {
            dst->outline = fz_malloc(ctx, (size_t)src->outline_count * sizeof(*dst->outline));
            memcpy(dst->outline, src->outline, (size_t)src->outline_count * sizeof(*dst->outline));
        }
        if (src->object_count) {
            dst->objects = fz_malloc(ctx, (size_t)src->object_count * sizeof(*dst->objects));
            memcpy(dst->objects, src->objects, (size_t)src->object_count * sizeof(*dst->objects));
        }
    }
    fz_catch(ctx) fz_ignore_error(ctx);
    if (src->outline_count && !dst->outline) dst->outline_count = 0;
    if (src->object_count && !dst->objects) dst->object_count = 0;
}

void spdf_paint_select_objects(spdf_paint_doc* doc, const spdf_paint_id* ids, int count) {
    spdf_paint_selection* s = &doc->selection;
    fz_free(doc->ctx, s->objects);
    s->objects = NULL;
    s->object_count = 0;
    if (count <= 0) return;
    fz_try(doc->ctx) s->objects = fz_malloc(doc->ctx, (size_t)count * sizeof(*s->objects));
    fz_catch(doc->ctx) { fz_ignore_error(doc->ctx); return; }
    for (int i = 0; i < count; i++) {
        spdf_paint_layer* layer = spdf_paint_layer_find(doc, ids[i]);
        int dup = 0;
        for (int j = 0; j < s->object_count; j++) dup |= s->objects[j] == ids[i];
        if (layer && layer->object && !dup) s->objects[s->object_count++] = ids[i];
    }
}

void spdf_paint_selection_prune(spdf_paint_doc* doc) {
    spdf_paint_selection* s = &doc->selection;
    int kept = 0;
    for (int i = 0; i < s->object_count; i++) {
        spdf_paint_layer* layer = spdf_paint_layer_find(doc, s->objects[i]);
        if (layer && layer->object) s->objects[kept++] = s->objects[i];
    }
    s->object_count = kept;
    if (s->mask && (s->mask->x + s->mask->w > doc->width * doc->raster_scale ||
                    s->mask->y + s->mask->h > doc->height * doc->raster_scale)) {
        fz_drop_pixmap(doc->ctx, s->mask);
        s->mask = NULL;
        s->active = s->object_count > 0;
    }
}

int spdf_paint_mask_at(const fz_pixmap* mask, int x, int y) {
    if (!mask) return 255;
    x -= mask->x;
    y -= mask->y;
    if (x < 0 || y < 0 || x >= mask->w || y >= mask->h) return 0;
    return mask->samples[y * mask->stride + x];
}
