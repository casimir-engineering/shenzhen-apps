/* Annotate's selection (docs/plans/annotate.md § 2 Selection, § 6 Selection): a pixel mask at raster resolution
 * (rectangle, free-form lasso, all, inverted), the selected objects, deleting what is selected, and lifting the
 * selected pixels into a Picture object (the transparent-selection rule: pixels of Color 2 stay behind; the hole is
 * transparent, or Color 2 on a picture whose format has no alpha). On a PDF page only the drawing layers are
 * selected from; the page itself never changes. */
#include "spdf_paint_model.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>


static void clear_pixels(spdf_paint_doc* doc) {
    spdf_paint_selection* s = &doc->selection;
    fz_drop_pixmap(doc->ctx, s->mask);
    s->mask = NULL;
    fz_free(doc->ctx, s->outline);
    s->outline = NULL;
    s->outline_count = 0;
    s->bounds = (fz_irect){0, 0, 0, 0};
    s->active = s->object_count > 0;
}

static void set_outline(spdf_paint_doc* doc, const spdf_paint_point* points, int count) {
    spdf_paint_selection* s = &doc->selection;
    fz_free(doc->ctx, s->outline);
    s->outline = spdf_paint_points_copy(doc->ctx, points, count);
    s->outline_count = s->outline ? count : 0;
}

/* A new mask over box (raster pixels), all 0; replaces the selection's pixels, deselects objects. */
static fz_pixmap* new_mask(spdf_paint_call* call, fz_irect box) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_select_objects(doc, NULL, 0);
    clear_pixels(doc);
    if (fz_is_empty_irect(box)) return NULL;
    fz_pixmap* mask = NULL;
    fz_try(doc->ctx) {
        mask = fz_new_pixmap_with_bbox(doc->ctx, NULL, box, NULL, 1);
        fz_clear_pixmap(doc->ctx, mask);
    }
    fz_catch(doc->ctx) { fz_ignore_error(doc->ctx); mask = NULL; }
    doc->selection.mask = mask;
    doc->selection.bounds = box;
    doc->selection.active = mask != NULL;
    return mask;
}

static spdf_paint_status reply_selection(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    float rs = (float)doc->raster_scale;
    fz_irect b = doc->selection.bounds;
    doc->generation++;
    if (doc->selection.mask)
        cJSON_AddItemToObject(call->reply, "bounds", spdf_paint_rect_json((spdf_rect){b.x0 / rs, b.y0 / rs, b.x1 / rs, b.y1 / rs}));
    else cJSON_AddNullToObject(call->reply, "bounds");
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_select_rect(spdf_paint_call* call) {
    double x = 0, y = 0, w = 0, h = 0;
    spdf_paint_arg_number(call, "x", &x);
    spdf_paint_arg_number(call, "y", &y);
    spdf_paint_arg_number(call, "w", &w);
    spdf_paint_arg_number(call, "h", &h);
    spdf_rect r = {(float)x, (float)y, (float)(x + w), (float)(y + h)};
    fz_pixmap* mask = new_mask(call, spdf_paint_raster_box(call->doc, r));
    if (mask) {
        memset(mask->samples, 255, (size_t)mask->stride * mask->h);
        spdf_paint_point corners[4] = {{r.x0, r.y0, 1}, {r.x1, r.y0, 1}, {r.x1, r.y1, 1}, {r.x0, r.y1, 1}};
        set_outline(call->doc, corners, 4);
    }
    return reply_selection(call);
}

static int cmp_float(const void* a, const void* b) {
    float d = *(const float*)a - *(const float*)b;
    return d < 0 ? -1 : d > 0;
}

spdf_paint_status spdf_paint_op_select_freeform(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_point* points = NULL;
    int n = 0;
    spdf_paint_arg_points(call, "points", &points, &n);
    float rs = (float)doc->raster_scale;
    fz_pixmap* mask = n >= 3 ? new_mask(call, spdf_paint_raster_box(doc, spdf_paint_points_box(points, n))) : NULL;
    float* xs = mask ? malloc((size_t)n * sizeof(float)) : NULL;
    for (int y = 0; xs && y < mask->h; y++) {
        float fy = (mask->y + y + 0.5f) / rs;
        int k = 0;
        for (int i = 0, j = n - 1; i < n; j = i++) {
            float yi = points[i].y, yj = points[j].y;
            if ((yi <= fy && fy < yj) || (yj <= fy && fy < yi))
                xs[k++] = points[i].x + (fy - yi) * (points[j].x - points[i].x) / (yj - yi);
        }
        qsort(xs, (size_t)k, sizeof(float), cmp_float);
        unsigned char* row = mask->samples + y * mask->stride;
        for (int p = 0; p + 1 < k; p += 2)
            for (int x = 0; x < mask->w; x++) {
                float fx = (mask->x + x + 0.5f) / rs;
                if (fx >= xs[p] && fx < xs[p + 1]) row[x] = 255;
            }
    }
    free(xs);
    if (mask) set_outline(doc, points, n);
    fz_free(doc->ctx, points);
    return reply_selection(call);
}

static void select_whole(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    fz_pixmap* mask = new_mask(call, spdf_paint_raster_box(doc, spdf_paint_canvas_rect(doc)));
    if (!mask) return;
    memset(mask->samples, 255, (size_t)mask->stride * mask->h);
    spdf_rect r = spdf_paint_canvas_rect(doc);
    spdf_paint_point corners[4] = {{r.x0, r.y0, 1}, {r.x1, r.y0, 1}, {r.x1, r.y1, 1}, {r.x0, r.y1, 1}};
    set_outline(doc, corners, 4);
}

spdf_paint_status spdf_paint_op_select_all(spdf_paint_call* call) {
    select_whole(call);
    return reply_selection(call);
}

spdf_paint_status spdf_paint_op_select_none(spdf_paint_call* call) {
    spdf_paint_select_objects(call->doc, NULL, 0);
    clear_pixels(call->doc);
    return reply_selection(call);
}

spdf_paint_status spdf_paint_op_select_invert(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    fz_pixmap* old = doc->selection.mask ? fz_keep_pixmap(doc->ctx, doc->selection.mask) : NULL;
    select_whole(call);
    fz_pixmap* mask = doc->selection.mask;
    if (old && mask) {
        fz_irect used = {mask->w, mask->h, 0, 0};
        for (int y = 0; y < mask->h; y++)
            for (int x = 0; x < mask->w; x++) {
                int v = 255 - spdf_paint_mask_at(old, x, y);
                mask->samples[y * mask->stride + x] = (unsigned char)v;
                if (!v) continue;
                if (x < used.x0) used.x0 = x;
                if (x >= used.x1) used.x1 = x + 1;
                if (y < used.y0) used.y0 = y;
                if (y >= used.y1) used.y1 = y + 1;
            }
        if (fz_is_empty_irect(used)) clear_pixels(doc);
        else doc->selection.bounds = used;
    }
    fz_drop_pixmap(doc->ctx, old);
    return reply_selection(call);
}

spdf_paint_status spdf_paint_op_select_transparent(spdf_paint_call* call) {
    int on = 0;
    spdf_paint_arg_bool(call, "on", &on);
    call->doc->selection.transparent = on ? 1 : 0;
    cJSON_AddBoolToObject(call->reply, "on", on);
    return SPDF_PAINT_OK;
}

/* select.objects {ids}: which objects are selected (Select tool clicks, Shift-click, an Option-drag box). */
spdf_paint_status spdf_paint_op_select_objects(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_id* ids = NULL;
    int count = 0;
    spdf_paint_arg_ids(call, &ids, &count);
    clear_pixels(doc);
    spdf_paint_select_objects(doc, ids, count);
    doc->selection.active = doc->selection.object_count > 0;
    fz_free(doc->ctx, ids);
    cJSON* list = cJSON_AddArrayToObject(call->reply, "objects");
    for (int i = 0; i < doc->selection.object_count; i++)
        cJSON_AddItemToArray(list, cJSON_CreateNumber(doc->selection.objects[i]));
    doc->generation++;
    return SPDF_PAINT_OK;
}

static int has_pixels_in(const fz_pixmap* pix, fz_irect box) {
    box = fz_intersect_irect(box, fz_make_irect(0, 0, pix->w, pix->h));
    for (int y = box.y0; y < box.y1; y++) {
        const unsigned char* p = pix->samples + (size_t)y * pix->stride + (size_t)box.x0 * 4 + 3;
        for (int x = box.x0; x < box.x1; x++, p += 4)
            if (*p) return 1;
    }
    return 0;
}

/* The layer a pixel selection works on, or NULL with call failed (a PDF page with nothing drawn on it): the active
 * layer, or when it has nothing inside the selection the nearest layer under it that has (on a picture, usually the
 * picture itself), so a part of the picture can be lifted, moved and resized while Layer 1 is active. */
static spdf_paint_layer* selection_layer(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_layer* layer = NULL;
    spdf_paint_active_pixels(doc, &layer);
    if (!layer || !spdf_paint_layer_pixels(doc, layer)) {
        spdf_paint_fail_unpaintable(call, layer);
        return NULL;
    }
    const spdf_paint_selection* s = &doc->selection;
    if (s->mask && !has_pixels_in(layer->pixels, s->bounds))
        for (int i = spdf_paint_layer_index(doc, layer->id) - 1; i >= 0; i--) {
            spdf_paint_layer* below = doc->layers[i];
            if (below->kind == SPDF_PAINT_LAYER_OBJECT || !below->visible || !spdf_paint_layer_paintable(doc, below) ||
                !below->pixels)
                continue;
            if (has_pixels_in(below->pixels, s->bounds)) return below;
        }
    return layer;
}

static int hole_is_color2(const spdf_paint_doc* doc, const spdf_paint_layer* layer) {
    return layer->kind == SPDF_PAINT_LAYER_BACKGROUND && !doc->has_alpha;
}

/* Replaces the masked pixels of layer by hole (premultiplied), weighted by the mask, inside box. */
static void punch(fz_pixmap* pix, const fz_pixmap* mask, fz_irect box, const unsigned char* hole,
                  const unsigned char* keep_color) {
    for (int y = box.y0; y < box.y1; y++) {
        unsigned char* d = pix->samples + y * pix->stride + box.x0 * 4;
        for (int x = box.x0; x < box.x1; x++, d += 4) {
            unsigned m = (unsigned)spdf_paint_mask_at(mask, x, y);
            if (!m || (keep_color && !memcmp(d, keep_color, 4))) continue;
            for (int c = 0; c < 4; c++) d[c] = (unsigned char)((d[c] * (255 - m) + hole[c] * m + 127) / 255);
        }
    }
}

spdf_paint_status spdf_paint_op_select_delete(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_selection* s = &doc->selection;
    if (!s->mask && s->object_count) {
        spdf_paint_history_save_active(doc);
        while (s->object_count) {
            spdf_paint_layer* layer = spdf_paint_layer_find(doc, s->objects[0]);
            if (layer && (layer->locked || layer->object->kind == SPDF_PAINT_OBJ_FOREIGN))
                return spdf_paint_call_fail(call, SPDF_PAINT_ERR_LOCKED,
                                            "This annotation was made in another app and can't be changed here.");
            if (layer) spdf_paint_layer_delete(doc, layer);
            else spdf_paint_selection_prune(doc);
        }
        return SPDF_PAINT_OK;
    }
    if (!s->mask) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOTHING_SELECTED, "Nothing is selected.");
    spdf_paint_layer* layer = selection_layer(call);
    if (!layer) return call->status;
    fz_irect box = fz_intersect_irect(s->bounds, fz_pixmap_bbox(doc->ctx, layer->pixels));
    unsigned char hole[4] = {0, 0, 0, 0};
    if (hole_is_color2(doc, layer)) spdf_paint_color_bytes(doc->color2, hole);
    spdf_paint_history_save_pixels(doc, layer, box);
    spdf_paint_history_save_active(doc);
    punch(layer->pixels, s->mask, box, hole, NULL);
    float rs = (float)doc->raster_scale;
    spdf_paint_changed(doc, layer, (spdf_rect){box.x0 / rs, box.y0 / rs, box.x1 / rs, box.y1 / rs});
    clear_pixels(doc);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_lift_selection(spdf_paint_call* call, spdf_paint_id* id_out) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_selection* s = &doc->selection;
    *id_out = 0;
    if (!s->mask) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOTHING_SELECTED, "Nothing is selected.");
    spdf_paint_layer* layer = selection_layer(call);
    if (!layer) return call->status;
    fz_pixmap* src = layer->pixels;
    fz_irect box = fz_intersect_irect(s->bounds, fz_pixmap_bbox(doc->ctx, src));
    if (fz_is_empty_irect(box)) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOTHING_SELECTED, "Nothing is selected.");
    fz_pixmap* pix = spdf_paint_pixmap_new(doc->ctx, box.x1 - box.x0, box.y1 - box.y0);
    if (!pix) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    unsigned char keep[4], hole[4] = {0, 0, 0, 0};
    spdf_paint_color_bytes(doc->color2, keep);
    const unsigned char* keep_color = s->transparent ? keep : NULL;
    if (!s->transparent && hole_is_color2(doc, layer)) memcpy(hole, keep, 4);
    for (int y = box.y0; y < box.y1; y++) {
        const unsigned char* p = src->samples + y * src->stride + box.x0 * 4;
        unsigned char* d = pix->samples + (y - box.y0) * pix->stride;
        for (int x = box.x0; x < box.x1; x++, p += 4, d += 4) {
            unsigned m = (unsigned)spdf_paint_mask_at(s->mask, x, y);
            if (!m || (keep_color && !memcmp(p, keep_color, 4))) continue;
            for (int c = 0; c < 4; c++) d[c] = (unsigned char)((p[c] * m + 127) / 255);
        }
    }
    spdf_paint_history_save_pixels(doc, layer, box);
    spdf_paint_history_save_active(doc);
    punch(src, s->mask, box, hole, keep_color);
    spdf_paint_id id = 0;
    spdf_paint_object* o = spdf_paint_object_new(doc, SPDF_PAINT_OBJ_PICTURE, &id);
    if (!o) { fz_drop_pixmap(doc->ctx, pix); return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "No memory."); }
    o->u.picture.pixels = pix;
    float rs = (float)doc->raster_scale;
    o->place.rect = (spdf_rect){box.x0 / rs, box.y0 / rs, box.x1 / rs, box.y1 / rs};
    spdf_paint_object_update_bounds(o);
    spdf_paint_layer* object_layer = spdf_paint_layer_detach(doc, id);
    spdf_paint_layer_insert(doc, object_layer, spdf_paint_object_insert_index(doc, layer)); /* its place: just above */
    clear_pixels(doc);
    spdf_paint_select_objects(doc, &id, 1);
    s->active = 1;
    spdf_paint_changed(doc, layer, o->place.rect);
    *id_out = id;
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_select_lift(spdf_paint_call* call) {
    spdf_paint_id id = 0;
    spdf_paint_status status = spdf_paint_lift_selection(call, &id);
    if (status == SPDF_PAINT_OK) cJSON_AddNumberToObject(call->reply, "id", id);
    return status;
}
