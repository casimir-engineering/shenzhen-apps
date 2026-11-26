/* What a resize or a move looks like while the handle is still held (spdf_paint.h, "Live placement"): the composite
 * of a region with some objects drawn where the gesture would put them, nothing in the canvas changed. Also the
 * damage counted for a PDF page's write back, for the reader's redraw of only what changed.
 *
 * On a PDF page the region covers the reader's own picture of the page, so it is drawn as the reader draws it: the
 * objects that stay where they are, and an object only moved, from their annotations in the document (the reader's
 * pixels exactly; Annotate's own drawing of a pen line, say, is smoother than the line written into the file). An
 * object being resized is drawn by Annotate at its new box, as object.transform will write it. */
#include "spdf_paint_model.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* As object.transform's rect: a line's or a shape's own points follow the box. */
static void map_points(spdf_paint_point* p, int n, spdf_rect from, spdf_rect to) {
    float fw = from.x1 - from.x0, fh = from.y1 - from.y0;
    for (int i = 0; i < n; i++) {
        p[i].x = fw > 1e-4f ? to.x0 + (p[i].x - from.x0) * (to.x1 - to.x0) / fw : p[i].x + (to.x0 - from.x0);
        p[i].y = fh > 1e-4f ? to.y0 + (p[i].y - from.y0) * (to.y1 - to.y0) / fh : p[i].y + (to.y0 - from.y0);
    }
}

static spdf_paint_object* placed_copy(fz_context* ctx, const spdf_paint_object* object, spdf_rect to) {
    spdf_paint_object* copy = spdf_paint_object_clone(ctx, object);
    if (!copy) return NULL;
    if (copy->kind == SPDF_PAINT_OBJ_PEN || copy->kind == SPDF_PAINT_OBJ_ARROW) {
        map_points(copy->u.line.points, copy->u.line.point_count, copy->place.rect, to);
        copy->place.rect = spdf_paint_points_box(copy->u.line.points, copy->u.line.point_count);
    } else {
        if (copy->kind == SPDF_PAINT_OBJ_SHAPE) spdf_paint_shape_fit(&copy->u.shape, copy->place.rect, to);
        copy->place.rect = to;
    }
    spdf_paint_object_update_bounds(copy);
    return copy;
}

static const spdf_paint_placed* find_placed(const spdf_paint_placed* placed, int count, spdf_paint_id id) {
    for (int i = 0; i < count; i++)
        if (placed[i].id == id) return &placed[i];
    return NULL;
}

/* One object layer: from its annotation on a PDF page when it has one (moved by dx, dy), else drawn here. */
static void draw_object(spdf_paint_doc* doc, spdf_paint_layer* layer, const spdf_paint_placed* placed, fz_pixmap* dest,
                        fz_irect clip, float scale) {
    spdf_paint_object* o = layer->object;
    float w = o->place.rect.x1 - o->place.rect.x0, h = o->place.rect.y1 - o->place.rect.y0;
    int moved_only = !placed || (fabsf((placed->rect.x1 - placed->rect.x0) - w) < 1e-3f &&
                                 fabsf((placed->rect.y1 - placed->rect.y0) - h) < 1e-3f);
    int written = doc->pdf && (o->kind == SPDF_PAINT_OBJ_FOREIGN || (o->pdf_nm && o->pdf_nm[0]));
    if (written && moved_only) {
        float dx = placed ? placed->rect.x0 - o->place.rect.x0 : 0, dy = placed ? placed->rect.y0 - o->place.rect.y0 : 0;
        spdf_paint_object stand_in = *o;  /* drawn through its annotation, whatever Annotate calls it */
        if (stand_in.kind != SPDF_PAINT_OBJ_FOREIGN) stand_in.kind = SPDF_PAINT_OBJ_FILL_SIGNATURE;
        spdf_paint_pdf_draw_annotation(doc, &stand_in, fz_concat(fz_translate(dx, dy), fz_scale(scale, scale)), dest,
                                       clip, 1.0f);  /* the annotation carries the layer's opacity */
        return;
    }
    if (!placed) {
        spdf_paint_object_draw(doc, o, fz_scale(scale, scale), dest, clip, layer->opacity);
        return;
    }
    spdf_paint_object* copy = placed_copy(doc->ctx, o, placed->rect);
    if (!copy) return;
    spdf_paint_object_draw(doc, copy, fz_scale(scale, scale), dest, clip, layer->opacity);
    spdf_paint_object_free(doc->ctx, copy);
}

spdf_paint_status spdf_paint_render_placed(spdf_paint_doc* doc, const spdf_paint_render_options* options,
                                           const spdf_paint_placed* placed, int count, spdf_bitmap* out, char* err,
                                           size_t err_len) {
    if (!doc || !doc->ctx || !out || !options) {
        spdf_paint_set_error(err, err_len, "Nothing to draw.");
        return SPDF_PAINT_ERR_FAILED;
    }
    memset(out, 0, sizeof(*out));
    fz_context* ctx = doc->ctx;
    float scale = options->scale > 0 ? options->scale : 1.0f;
    spdf_rect region = options->region;
    fz_irect box = {(int)floorf(region.x0 * scale), (int)floorf(region.y0 * scale), 0, 0};
    box.x1 = box.x0 + (int)ceilf((region.x1 - region.x0) * scale);
    box.y1 = box.y0 + (int)ceilf((region.y1 - region.y0) * scale);
    if (box.x1 <= box.x0 || box.y1 <= box.y0 ||
        (uint64_t)(box.x1 - box.x0) * (uint64_t)(box.y1 - box.y0) > SPDF_PAINT_MAX_PIXELS) {
        spdf_paint_set_error(err, err_len, "Nothing to draw.");
        return SPDF_PAINT_ERR_FAILED;
    }
    fz_pixmap* dest = NULL;
    fz_try(ctx) dest = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), box, NULL, 1);
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        spdf_paint_set_error(err, err_len, "There is not enough memory to draw this.");
        return SPDF_PAINT_ERR_NO_MEMORY;
    }
    fz_clear_pixmap(ctx, dest);
    int nearest = (options->flags & SPDF_PAINT_RENDER_NEAREST) && scale > (float)doc->raster_scale;
    for (int i = 0; i < doc->layer_count; i++) {  /* as spdf_paint_composite_into, bottom to top */
        spdf_paint_layer* layer = doc->layers[i];
        if (!layer->visible) continue;
        if (spdf_paint_layer_is_page(doc, layer)) {
            if (!(options->flags & SPDF_PAINT_RENDER_SKIP_LOCKED_BACKGROUND))
                spdf_paint_pdf_draw_page(doc, fz_scale(scale, scale), dest, box,
                                         (options->flags & SPDF_PAINT_RENDER_DARK_PAGE) != 0);
        } else if (layer->object) {
            const spdf_paint_placed* at = layer->locked ? NULL : find_placed(placed, count, layer->id);
            draw_object(doc, layer, at, dest, box, scale);
        } else if (layer->pixels) {
            spdf_paint_draw_raster(doc, layer->pixels, dest, box, scale, layer->opacity, nearest);
        }
    }
    out->width = dest->w;
    out->height = dest->h;
    out->stride = dest->w * 4;
    out->rgba = malloc((size_t)out->stride * out->height);
    if (out->rgba)
        for (int y = 0; y < dest->h; y++)
            memcpy(out->rgba + (size_t)y * out->stride, dest->samples + (size_t)y * dest->stride, (size_t)out->stride);
    fz_drop_pixmap(ctx, dest);
    if (!out->rgba) {
        memset(out, 0, sizeof(*out));
        spdf_paint_set_error(err, err_len, "There is not enough memory to draw this.");
        return SPDF_PAINT_ERR_NO_MEMORY;
    }
    return SPDF_PAINT_OK;
}

void spdf_paint_union_damage(spdf_rect* into, int* has, spdf_rect rect) {
    if (!*has) *into = rect;
    else {
        into->x0 = fminf(into->x0, rect.x0);
        into->y0 = fminf(into->y0, rect.y0);
        into->x1 = fmaxf(into->x1, rect.x1);
        into->y1 = fmaxf(into->y1, rect.y1);
    }
    *has = 1;
}

int spdf_paint_take_written_damage(spdf_paint_doc* doc, spdf_rect* changed) {
    if (!doc || !doc->has_written_damage) return 0;
    if (changed) *changed = doc->written_damage;
    doc->has_written_damage = 0;
    return 1;
}
