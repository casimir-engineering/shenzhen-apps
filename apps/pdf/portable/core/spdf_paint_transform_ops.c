/* The Canvas and Image operations (docs/plans/annotate.md § 2 Image group, § 6 Canvas and Image): canvas.resize,
 * canvas.properties, image.resize, image.skew, image.rotate, image.flip, image.crop, image.invert, image.clear and
 * image.remove_background, each with the scope rule: "auto" is the pixel selection (lifted into a Picture object
 * first, as Paint does) or the selected objects if any, else the whole picture. On a PDF page "the whole picture" is
 * every added layer and object inside the page, which itself never changes; crop and canvas size answer page_locked. */
#include "spdf_paint_model.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif


static int is_pdf(const spdf_paint_doc* doc) { return doc->kind == SPDF_PAINT_DOC_PDF; }

static int is_line(const spdf_paint_object* o) { return o->kind == SPDF_PAINT_OBJ_PEN || o->kind == SPDF_PAINT_OBJ_ARROW; }

/* ---- Scope ---- */

typedef struct targets {
    spdf_paint_id* ids; /* objects to change; NULL: the whole picture */
    int count;
    int pixels;         /* the pixel selection, in place (invert, remove background) */
} targets;

static spdf_paint_status resolve_scope(spdf_paint_call* call, targets* t, int in_place) {
    spdf_paint_doc* doc = call->doc;
    memset(t, 0, sizeof(*t));
    spdf_paint_scope scope = spdf_paint_arg_scope(call);
    spdf_paint_selection* s = &doc->selection;
    if (scope == SPDF_PAINT_SCOPE_SELECTION || (scope == SPDF_PAINT_SCOPE_AUTO && s->mask)) {
        if (!s->mask) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOTHING_SELECTED, "Nothing is selected.");
        if (in_place) { t->pixels = 1; return SPDF_PAINT_OK; }
        spdf_paint_id id = 0;
        if (spdf_paint_lift_selection(call, &id) != SPDF_PAINT_OK) return call->status;
        cJSON_AddNumberToObject(call->reply, "id", id);
    } else if (scope == SPDF_PAINT_SCOPE_IMAGE || (scope == SPDF_PAINT_SCOPE_AUTO && !s->object_count))
        return SPDF_PAINT_OK;
    if (!s->object_count) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOTHING_SELECTED, "Select an object first.");
    t->ids = malloc((size_t)s->object_count * sizeof(*t->ids));
    if (!t->ids) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    for (int i = 0; i < s->object_count; i++) {
        spdf_paint_layer* layer = spdf_paint_layer_find(doc, s->objects[i]);
        if (layer && (layer->locked || layer->object->kind == SPDF_PAINT_OBJ_FOREIGN)) {
            free(t->ids);
            t->ids = NULL;
            return spdf_paint_call_fail(call, SPDF_PAINT_ERR_LOCKED,
                                        "This annotation was made in another app and can't be changed here.");
        }
        if (layer) t->ids[t->count++] = layer->id;
    }
    return SPDF_PAINT_OK;
}

/* ---- Mapping objects ---- */

static void map_points(spdf_paint_point* p, int n, fz_matrix m) {
    for (int i = 0; i < n; i++) {
        fz_point q = fz_transform_point_xy(p[i].x, p[i].y, m);
        p[i].x = q.x;
        p[i].y = q.y;
    }
}

/* Moves an object through m (canvas units), its own size times (sx, sy), turned by rot, flipped (1 h, 2 v); line
 * widths and text sizes times size_scale. */
void spdf_paint_map_object(spdf_paint_object* o, fz_matrix m, float sx, float sy, float rot, int flip, float size_scale) {
    if (spdf_paint_object_has_points(o)) {
        spdf_paint_point* p = is_line(o) ? o->u.line.points : o->u.shape.points;
        int n = is_line(o) ? o->u.line.point_count : o->u.shape.point_count;
        map_points(p, n, m);
        o->place.rect = spdf_paint_points_box(p, n);
        if (is_line(o)) o->u.line.width *= size_scale;
        else o->u.shape.outline.width *= size_scale;
        spdf_paint_object_update_bounds(o);
        return;
    }
    spdf_rect r = o->place.rect;
    fz_point c = fz_transform_point_xy((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2, m);
    float w = (r.x1 - r.x0) * sx / 2, h = (r.y1 - r.y0) * sy / 2;
    o->place.rect = (spdf_rect){c.x - w, c.y - h, c.x + w, c.y + h};
    if (flip) {
        if (flip == 1) o->place.flip_h = !o->place.flip_h;
        else o->place.flip_v = !o->place.flip_v;
        o->place.rotation = -o->place.rotation;
    }
    o->place.rotation = fmodf(o->place.rotation + rot, 360.0f);
    if (o->kind == SPDF_PAINT_OBJ_SHAPE) {
        map_points(&o->u.shape.tail, 1, m);
        o->u.shape.outline.width *= size_scale;
    }
    if (o->kind == SPDF_PAINT_OBJ_TEXT) o->u.text.size *= size_scale;
    spdf_paint_object_update_bounds(o);
}

/* Slants (any linear map) a Picture object's own pixels, keeping its box centre and its pixels' scale. */
static int bake_picture(spdf_paint_doc* doc, spdf_paint_object* o, fz_matrix about) {
    fz_pixmap* src = o->u.picture.pixels;
    if (!src) return 1;
    about.e = about.f = 0;
    /* In the picture's own space: its turn and flips undone, the map applied, then put back. */
    fz_matrix own = spdf_paint_placement_matrix(&o->place);
    own.e = own.f = 0;
    about = fz_concat(fz_concat(own, about), fz_invert_matrix(own));
    spdf_rect r = o->place.rect;
    float cx = (r.x0 + r.x1) / 2, cy = (r.y0 + r.y1) / 2;
    fz_rect box = fz_transform_rect(fz_make_rect(0, 0, (float)src->w, (float)src->h), about);
    int w = (int)ceilf(box.x1 - box.x0), h = (int)ceilf(box.y1 - box.y0);
    fz_pixmap* out = spdf_paint_affine_pixmap(doc->ctx, src, fz_concat(about, fz_translate(-box.x0, -box.y0)), w, h);
    if (!out) return 0;
    float kx = (r.x1 - r.x0) / src->w, ky = (r.y1 - r.y0) / src->h;
    fz_drop_pixmap(doc->ctx, src);
    o->u.picture.pixels = out;
    o->place.rect = (spdf_rect){cx - w * kx / 2, cy - h * ky / 2, cx + w * kx / 2, cy + h * ky / 2};
    spdf_paint_object_update_bounds(o);
    return 1;
}

/* An object's own change about its box centre (selected objects, a lifted selection). */
static spdf_paint_status change_object(spdf_paint_call* call, spdf_paint_layer* layer, fz_matrix about, float sx,
                                       float sy, float rot, int flip, int skew) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_object* o = layer->object;
    int pointed = spdf_paint_object_has_points(o);
    if (skew && !pointed && o->kind != SPDF_PAINT_OBJ_PICTURE)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT,
                                    "Only pictures, selections and lines can be slanted.");
    spdf_paint_history_save_object(doc, layer);
    spdf_paint_object_update_bounds(o);
    spdf_paint_damage(doc, o->bounds);
    spdf_rect r = o->place.rect;
    float cx = (r.x0 + r.x1) / 2, cy = (r.y0 + r.y1) / 2;
    fz_matrix m = fz_concat(fz_concat(fz_translate(-cx, -cy), about), fz_translate(cx, cy));
    if (skew && !pointed) {
        if (!bake_picture(doc, o, about))
            return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    } else if (sx != 1 || sy != 1) {
        if (pointed) spdf_paint_map_object(o, fz_concat(fz_concat(fz_translate(-r.x0, -r.y0), fz_scale(sx, sy)),
                                             fz_translate(r.x0, r.y0)), sx, sy, 0, 0, 1);
        else o->place.rect = (spdf_rect){r.x0, r.y0, r.x0 + (r.x1 - r.x0) * sx, r.y0 + (r.y1 - r.y0) * sy};
        spdf_paint_object_update_bounds(o);
    } else spdf_paint_map_object(o, m, 1, 1, rot, flip, 1);
    spdf_paint_damage(doc, o->bounds);
    return SPDF_PAINT_OK;
}

/* ---- The whole picture ---- */

typedef enum whole_kind { WHOLE_AFFINE, WHOLE_RESIZE, WHOLE_QUARTERS, WHOLE_FLIP } whole_kind;

typedef struct whole {
    whole_kind kind;
    fz_matrix m; /* canvas units, old -> new */
    int w, h;    /* new canvas size */
    float sx, sy, rot, size_scale;
    int flip, quarters;
    int skew; /* picture objects' own pixels are slanted too */
} whole;

static fz_pixmap* transform_layer(spdf_paint_doc* doc, const fz_pixmap* src, const whole* t) {
    fz_context* ctx = doc->ctx;
    int rs = doc->raster_scale, w = t->w * rs, h = t->h * rs;
    if (t->kind == WHOLE_RESIZE) {
        int sw = (int)lroundf(src->w * t->sx), sh = (int)lroundf(src->h * t->sy);
        fz_pixmap* scaled = spdf_paint_scale_pixmap(ctx, src, sw < 1 ? 1 : sw, sh < 1 ? 1 : sh);
        if (!scaled || (scaled->w == w && scaled->h == h)) return scaled;
        fz_pixmap* placed = spdf_paint_place_pixmap(ctx, scaled, w, h, 0, 0, NULL);
        fz_drop_pixmap(ctx, scaled);
        return placed;
    }
    if (t->kind == WHOLE_QUARTERS && !is_pdf(doc)) return spdf_paint_quarter_pixmap(ctx, src, t->quarters);
    if (t->kind == WHOLE_FLIP) {
        fz_pixmap* copy = NULL;
        fz_try(ctx) copy = fz_clone_pixmap(ctx, src);
        fz_catch(ctx) { fz_ignore_error(ctx); return NULL; }
        spdf_paint_flip_pixmap(copy, t->flip == 1);
        return copy;
    }
    fz_matrix mr = fz_concat(fz_concat(fz_scale(1.0f / rs, 1.0f / rs), t->m), fz_scale((float)rs, (float)rs));
    return spdf_paint_affine_pixmap(ctx, src, mr, w, h);
}

static spdf_paint_status transform_whole(spdf_paint_call* call, const whole* t) {
    spdf_paint_doc* doc = call->doc;
    if ((uint64_t)t->w * t->h > SPDF_PAINT_MAX_PIXELS || t->w > SPDF_PAINT_MAX_SIDE || t->h > SPDF_PAINT_MAX_SIDE)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_TOO_LARGE,
                                    "The picture would be larger than 16384 x 16384 pixels or 268 million pixels.");
    if (t->w < 1 || t->h < 1) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "The picture would vanish.");
    spdf_paint_history_save_canvas(doc);
    spdf_paint_history_save_active(doc);
    unsigned char fill[4];
    spdf_paint_color_bytes(doc->color2, fill);
    for (int i = 0; i < doc->layer_count; i++) {
        spdf_paint_layer* layer = doc->layers[i];
        if (layer->object) {
            if (layer->object->kind == SPDF_PAINT_OBJ_FOREIGN || layer->locked) continue;
            spdf_paint_map_object(layer->object, t->m, t->sx, t->sy, t->rot, t->flip, t->size_scale);
            if (t->skew && layer->object->kind == SPDF_PAINT_OBJ_PICTURE && !bake_picture(doc, layer->object, t->m))
                return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
            continue;
        }
        if (!layer->pixels) continue;
        fz_pixmap* out = transform_layer(doc, layer->pixels, t);
        if (!out) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
        if (layer->kind == SPDF_PAINT_LAYER_BACKGROUND && !doc->has_alpha) spdf_paint_flatten_onto(out, fill);
        fz_drop_pixmap(doc->ctx, layer->pixels);
        layer->pixels = out;
    }
    spdf_paint_selection_free(doc->ctx, &doc->selection);
    if (t->w != doc->width || t->h != doc->height) spdf_paint_set_size(doc, t->w, t->h);
    spdf_paint_damage_all(doc);
    cJSON_AddNumberToObject(call->reply, "width", doc->width);
    cJSON_AddNumberToObject(call->reply, "height", doc->height);
    return SPDF_PAINT_OK;
}

/* A whole-picture map m about the canvas: a picture or canvas grows to hold the result, a PDF page keeps its size
 * and the map is taken about its centre. */
static void fit_whole(const spdf_paint_doc* doc, whole* t, fz_matrix about) {
    float W = (float)doc->width, H = (float)doc->height;
    fz_matrix centered = fz_concat(fz_concat(fz_translate(-W / 2, -H / 2), about), fz_translate(W / 2, H / 2));
    if (is_pdf(doc)) { t->m = centered; t->w = doc->width; t->h = doc->height; return; }
    fz_rect box = fz_transform_rect(fz_make_rect(0, 0, W, H), about);
    t->w = (int)ceilf(box.x1 - box.x0 - 1e-3f);
    t->h = (int)ceilf(box.y1 - box.y0 - 1e-3f);
    t->m = fz_concat(about, fz_translate(-box.x0, -box.y0));
}

/* ---- Handlers ---- */

static spdf_paint_status for_targets(spdf_paint_call* call, targets* t, fz_matrix about, float sx, float sy, float rot,
                                     int flip, int skew) {
    spdf_paint_status status = SPDF_PAINT_OK;
    for (int i = 0; i < t->count && status == SPDF_PAINT_OK; i++) {
        spdf_paint_layer* layer = spdf_paint_layer_find(call->doc, t->ids[i]);
        if (layer) status = change_object(call, layer, about, sx, sy, rot, flip, skew);
    }
    free(t->ids);
    return status;
}

/* The new size from width / height / percent and keepRatio, for a w x h box. */
static void new_size(spdf_paint_call* call, float w, float h, float* nw, float* nh) {
    double width = 0, height = 0, percent = 0;
    int keep = 1;
    spdf_paint_arg_bool(call, "keepRatio", &keep);
    int has_w = spdf_paint_arg_number(call, "width", &width), has_h = spdf_paint_arg_number(call, "height", &height);
    if (spdf_paint_arg_number(call, "percent", &percent)) { *nw = w * (float)percent / 100; *nh = h * (float)percent / 100; return; }
    *nw = has_w ? (float)width : (keep && has_h ? w * (float)height / h : w);
    *nh = has_h ? (float)height : (keep && has_w ? h * (float)width / w : h);
}

spdf_paint_status spdf_paint_op_image_resize(spdf_paint_call* call) {
    targets t;
    if (resolve_scope(call, &t, 0) != SPDF_PAINT_OK) return call->status;
    if (t.ids) {
        spdf_paint_status status = SPDF_PAINT_OK;
        for (int i = 0; i < t.count && status == SPDF_PAINT_OK; i++) {
            spdf_paint_layer* layer = spdf_paint_layer_find(call->doc, t.ids[i]);
            spdf_rect r = layer->object->place.rect;
            float nw, nh;
            new_size(call, r.x1 - r.x0, r.y1 - r.y0, &nw, &nh);
            status = change_object(call, layer, fz_identity, nw / fmaxf(r.x1 - r.x0, 1e-3f),
                                   nh / fmaxf(r.y1 - r.y0, 1e-3f), 0, 0, 0);
        }
        free(t.ids);
        return status;
    }
    spdf_paint_doc* doc = call->doc;
    float nw, nh;
    new_size(call, (float)doc->width, (float)doc->height, &nw, &nh);
    whole w = {WHOLE_RESIZE, fz_identity, (int)lroundf(nw), (int)lroundf(nh), 1, 1, 0, 1, 0, 0, 0};
    if (is_pdf(doc)) { w.w = doc->width; w.h = doc->height; }
    w.sx = nw / doc->width;
    w.sy = nh / doc->height;
    w.m = fz_scale(w.sx, w.sy);
    w.size_scale = sqrtf(w.sx * w.sy);
    return transform_whole(call, &w);
}

spdf_paint_status spdf_paint_op_image_skew(spdf_paint_call* call) {
    double hd = 0, vd = 0;
    spdf_paint_arg_number(call, "horizontal", &hd);
    spdf_paint_arg_number(call, "vertical", &vd);
    fz_matrix about = {1, (float)tan(vd * M_PI / 180), (float)tan(hd * M_PI / 180), 1, 0, 0};
    targets t;
    if (resolve_scope(call, &t, 0) != SPDF_PAINT_OK) return call->status;
    if (t.ids) return for_targets(call, &t, about, 1, 1, 0, 0, 1);
    whole w = {WHOLE_AFFINE, fz_identity, 0, 0, 1, 1, 0, 1, 0, 0, 1};
    fit_whole(call->doc, &w, about);
    return transform_whole(call, &w);
}

spdf_paint_status spdf_paint_op_image_rotate(spdf_paint_call* call) {
    double degrees = 0;
    spdf_paint_arg_number(call, "degrees", &degrees);
    float d = fmodf((float)degrees, 360.0f);
    if (d < 0) d += 360.0f;
    targets t;
    if (resolve_scope(call, &t, 0) != SPDF_PAINT_OK) return call->status;
    if (t.ids) return for_targets(call, &t, fz_rotate(d), 1, 1, d, 0, 0);
    whole w = {WHOLE_AFFINE, fz_identity, 0, 0, 1, 1, d, 1, 0, 0, 0};
    if (fmodf(d, 90.0f) == 0.0f) { w.kind = WHOLE_QUARTERS; w.quarters = (int)(d / 90.0f); }
    fit_whole(call->doc, &w, fz_rotate(d));
    if (w.kind == WHOLE_QUARTERS && !is_pdf(call->doc) && w.quarters % 2) {
        w.w = call->doc->height;
        w.h = call->doc->width;
    }
    return transform_whole(call, &w);
}

spdf_paint_status spdf_paint_op_image_flip(spdf_paint_call* call) {
    const char* axis = spdf_paint_arg_string(call, "axis");
    int flip = axis && !strcmp(axis, "vertical") ? 2 : 1;
    fz_matrix about = fz_scale(flip == 1 ? -1.0f : 1.0f, flip == 2 ? -1.0f : 1.0f);
    targets t;
    if (resolve_scope(call, &t, 0) != SPDF_PAINT_OK) return call->status;
    if (t.ids) return for_targets(call, &t, about, 1, 1, 0, flip, 0);
    whole w = {WHOLE_FLIP, fz_identity, 0, 0, 1, 1, 0, 1, flip, 0, 0};
    fit_whole(call->doc, &w, about);
    return transform_whole(call, &w);
}

/* The layer the image group changes in place: the active one, never a PDF page. */
static spdf_paint_layer* image_layer(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_layer* layer = spdf_paint_layer_find(doc, doc->active);
    if (!spdf_paint_layer_paintable(doc, layer) || !spdf_paint_layer_pixels(doc, layer)) {
        spdf_paint_fail_unpaintable(call, layer);
        return NULL;
    }
    return layer;
}

static spdf_paint_color invert_color(spdf_paint_color c) { return (~c & 0xFFFFFF00u) | (c & 0xFF); }

spdf_paint_status spdf_paint_op_image_invert(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    targets t;
    if (resolve_scope(call, &t, 1) != SPDF_PAINT_OK) return call->status;
    for (int i = 0; i < t.count; i++) {
        spdf_paint_layer* layer = spdf_paint_layer_find(doc, t.ids[i]);
        spdf_paint_object* o = layer ? layer->object : NULL;
        if (!o) continue;
        spdf_paint_history_save_object(doc, layer);
        if (o->kind == SPDF_PAINT_OBJ_PICTURE && o->u.picture.pixels)
            spdf_paint_invert_pixels(o->u.picture.pixels, fz_make_irect(0, 0, o->u.picture.pixels->w,
                                                                        o->u.picture.pixels->h), NULL);
        else if (o->kind == SPDF_PAINT_OBJ_SHAPE) {
            o->u.shape.outline.color = invert_color(o->u.shape.outline.color);
            o->u.shape.fill.color = invert_color(o->u.shape.fill.color);
        } else if (o->kind == SPDF_PAINT_OBJ_TEXT) {
            o->u.text.color = invert_color(o->u.text.color);
            if (o->u.text.background) o->u.text.background = invert_color(o->u.text.background);
        } else if (is_line(o)) o->u.line.color = invert_color(o->u.line.color);
        spdf_paint_changed(doc, layer, (spdf_rect){0, 0, 0, 0});
    }
    if (t.ids) { free(t.ids); return SPDF_PAINT_OK; }
    spdf_paint_layer* layer = image_layer(call);
    if (!layer) return call->status;
    fz_irect box = t.pixels ? doc->selection.bounds : fz_make_irect(0, 0, layer->pixels->w, layer->pixels->h);
    spdf_paint_history_save_pixels(doc, layer, box);
    spdf_paint_invert_pixels(layer->pixels, box, t.pixels ? doc->selection.mask : NULL);
    spdf_paint_damage_all(doc);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_image_clear(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_layer* layer = image_layer(call);
    if (!layer) return call->status;
    spdf_paint_history_save_pixels(doc, layer, fz_make_irect(0, 0, layer->pixels->w, layer->pixels->h));
    fz_clear_pixmap(doc->ctx, layer->pixels);
    if (layer->kind == SPDF_PAINT_LAYER_BACKGROUND && !doc->has_alpha) {
        unsigned char fill[4];
        spdf_paint_color_bytes(doc->color2, fill);
        spdf_paint_flatten_onto(layer->pixels, fill);
    }
    spdf_paint_damage_all(doc);
    return SPDF_PAINT_OK;
}

/* Multiplies alpha inside box of pix by the frontend's mask, stretched over the box. */
static void apply_mask(fz_pixmap* pix, fz_irect box, const spdf_paint_apply_input* in) {
    int bw = box.x1 - box.x0, bh = box.y1 - box.y0;
    for (int y = box.y0; y < box.y1; y++) {
        int my = (int)((y - box.y0 + 0.5f) * in->mask_height / bh);
        const unsigned char* mrow = in->mask + (size_t)(my < in->mask_height ? my : in->mask_height - 1) * in->mask_stride;
        unsigned char* p = pix->samples + y * pix->stride + box.x0 * 4;
        for (int x = box.x0; x < box.x1; x++, p += 4) {
            int mx = (int)((x - box.x0 + 0.5f) * in->mask_width / bw);
            unsigned m = mrow[mx < in->mask_width ? mx : in->mask_width - 1];
            for (int c = 0; c < 4; c++) p[c] = (unsigned char)((p[c] * m + 127) / 255);
        }
    }
}

spdf_paint_status spdf_paint_op_image_remove_background(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    const spdf_paint_apply_input* in = call->input;
    if (!in->mask || in->mask_width < 1 || in->mask_height < 1)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_FRONTEND,
                                    "The app finds the subject first; ask for this through the app.");
    targets t;
    if (resolve_scope(call, &t, 1) != SPDF_PAINT_OK) return call->status;
    for (int i = 0; i < t.count; i++) {
        spdf_paint_layer* layer = spdf_paint_layer_find(doc, t.ids[i]);
        spdf_paint_object* o = layer ? layer->object : NULL;
        if (!o || o->kind != SPDF_PAINT_OBJ_PICTURE || !o->u.picture.pixels) {
            free(t.ids);
            return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "Only a picture's background can be "
                                        "removed.");
        }
        spdf_paint_history_save_object(doc, layer);
        apply_mask(o->u.picture.pixels, fz_make_irect(0, 0, o->u.picture.pixels->w, o->u.picture.pixels->h), in);
        spdf_paint_changed(doc, layer, (spdf_rect){0, 0, 0, 0});
    }
    if (t.ids) { free(t.ids); return SPDF_PAINT_OK; }
    spdf_paint_layer* layer = image_layer(call);
    if (!layer) return call->status;
    fz_irect box = t.pixels ? doc->selection.bounds : fz_make_irect(0, 0, layer->pixels->w, layer->pixels->h);
    spdf_paint_history_save_pixels(doc, layer, box);
    apply_mask(layer->pixels, box, in);
    spdf_paint_damage_all(doc);
    return SPDF_PAINT_OK;
}
