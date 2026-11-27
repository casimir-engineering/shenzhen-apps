/* Annotate's Fill and Color picker (docs/plans/annotate.md § 2 Tools, § 8 Core spdf_paint_fill.c): scanline flood fill
 * with tolerance, contiguous or everywhere, bounded by the edges you see (every visible layer and object, the PDF page
 * included) and painted into the active raster layer; colour pick from what you see or the active layer. The
 * paint.fill handler sends a click on an object to the object: a shape gets a solid fill (a line its colour), a text
 * box an opaque background, a pen line or arrow its colour, a picture is filled within its own pixels. */
#include "spdf_paint_brush_engine.h"
#include "spdf_paint_handlers.h"
#include "spdf_paint_model.h"
#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <string.h>

static int channel(spdf_paint_color c, int shift) { return (int)((c >> shift) & 0xFF); }

static spdf_paint_color unpremultiply(const unsigned char* p) {
    unsigned a = p[3], r, g, b;
    if (!a) return 0;
    r = (p[0] * 255u + a / 2) / a, g = (p[1] * 255u + a / 2) / a, b = (p[2] * 255u + a / 2) / a;
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;
    return (r << 24) | (g << 16) | (b << 8) | a;
}

static fz_irect union_box(fz_irect a, fz_irect b) {
    if (fz_is_empty_irect(a)) return b;
    if (b.x0 < a.x0) a.x0 = b.x0;
    if (b.y0 < a.y0) a.y0 = b.y0;
    if (b.x1 > a.x1) a.x1 = b.x1;
    if (b.y1 > a.y1) a.y1 = b.y1;
    return a;
}

static int match_at(const unsigned char* p, const int* t, int tol);
static int inside_sel(const fz_pixmap* sel, int x, int y);

/* The pixels like the seed one (premultiplied channels within tol), joined to it or anywhere; 1 = filled. The
 * selection, when given, bounds the fill too. Returns the mask (fz_free) and its used box, NULL when out of memory. */
static unsigned char* flood_region(fz_context* ctx, const unsigned char* rgba, ptrdiff_t stride, int w, int h, int sx,
                                   int sy, int tol, int contiguous, const fz_pixmap* sel, fz_irect* used) {
    unsigned char* mask = fz_calloc_no_throw(ctx, (size_t)w * (size_t)h, 1);
    const unsigned char* t = rgba + sy * stride + sx * 4;
    int target[4] = {t[0], t[1], t[2], t[3]}, x, y;
    int* stack = NULL;
    size_t top = 0, cap = 0;
    *used = fz_empty_irect;
#define MATCH(X, Y) (match_at(rgba + (Y) * stride + (X) * 4, target, tol) && inside_sel(sel, X, Y))
#define MARK(X, Y) (mask[(size_t)(Y) * w + (X)])
    if (!mask) return NULL;
    if (!contiguous) {
        for (y = 0; y < h; ++y)
            for (x = 0; x < w; ++x)
                if (MATCH(x, y)) MARK(x, y) = 1, *used = union_box(*used, fz_make_irect(x, y, x + 1, y + 1));
        return mask;
    }
    if (!MATCH(sx, sy)) return mask;
    cap = 1024, stack = fz_malloc_no_throw(ctx, cap * 2 * sizeof(int));
    if (!stack) return fz_free(ctx, mask), NULL;
    stack[top * 2] = sx, stack[top * 2 + 1] = sy, ++top;
    while (top) {
        int xl, xr, row, dy;
        --top, x = stack[top * 2], y = stack[top * 2 + 1];
        if (MARK(x, y) || !MATCH(x, y)) continue;
        for (xl = x; xl > 0 && !MARK(xl - 1, y) && MATCH(xl - 1, y); --xl) {}
        for (xr = x; xr < w - 1 && !MARK(xr + 1, y) && MATCH(xr + 1, y); ++xr) {}
        memset(&MARK(xl, y), 1, (size_t)(xr - xl + 1));
        *used = union_box(*used, fz_make_irect(xl, y, xr + 1, y + 1));
        for (dy = -1; dy <= 1; dy += 2) { /* the start of every run of like pixels above and below */
            int in_run = 0;
            row = y + dy;
            if (row < 0 || row >= h) continue;
            for (x = xl; x <= xr; ++x) {
                int ok = !MARK(x, row) && MATCH(x, row);
                if (ok && !in_run) {
                    if (top == cap) {
                        int* grown = fz_realloc_no_throw(ctx, stack, cap * 4 * sizeof(int));
                        if (!grown) return fz_free(ctx, stack), fz_free(ctx, mask), NULL;
                        stack = grown, cap *= 2;
                    }
                    stack[top * 2] = x, stack[top * 2 + 1] = row, ++top;
                }
                in_run = ok;
            }
        }
    }
#undef MATCH
#undef MARK
    fz_free(ctx, stack);
    return mask;
}

static int match_at(const unsigned char* p, const int* t, int tol) {
    return abs(p[0] - t[0]) <= tol && abs(p[1] - t[1]) <= tol && abs(p[2] - t[2]) <= tol && abs(p[3] - t[3]) <= tol;
}

static int inside_sel(const fz_pixmap* sel, int x, int y) {
    if (!sel) return 1;
    x -= sel->x, y -= sel->y;
    if (x < 0 || y < 0 || x >= sel->w || y >= sel->h) return 0;
    return sel->samples[(size_t)y * sel->stride + (size_t)x * sel->n + (sel->n - 1)] >= 128;
}

/* Lays `color` (replacing what was there) into dest where mask is set, over box. */
static void lay_fill(fz_pixmap* dest, const unsigned char* mask, int mw, fz_irect box, spdf_paint_color color) {
    unsigned a = (unsigned)channel(color, 0);
    unsigned char px[4] = {(unsigned char)((channel(color, 24) * a + 127) / 255),
                           (unsigned char)((channel(color, 16) * a + 127) / 255),
                           (unsigned char)((channel(color, 8) * a + 127) / 255), (unsigned char)a};
    int x, y;
    for (y = box.y0; y < box.y1; ++y)
        for (x = box.x0; x < box.x1; ++x)
            if (mask[(size_t)y * mw + x]) memcpy(dest->samples + (size_t)y * dest->stride + (size_t)x * 4, px, 4);
}

static int tolerance_bytes(float tolerance) {
    float t = tolerance < 0 ? 0 : tolerance > 1 ? 1 : tolerance;
    return (int)lrintf(t * 255);
}

spdf_paint_status spdf_paint_flood_fill(spdf_paint_doc* doc, spdf_paint_layer* layer, const spdf_paint_fill_args* args,
                                        spdf_rect* damage) {
    spdf_paint_render_options options;
    spdf_bitmap seen = {0, 0, 0, NULL};
    fz_pixmap* pix;
    unsigned char* mask;
    fz_irect used;
    char err[256];
    float scale;
    int sx, sy;
    spdf_paint_status st;
    if (damage) *damage = (spdf_rect){0, 0, 0, 0};
    if (!doc || !layer || !args) return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    if (layer->locked || (doc->kind == SPDF_PAINT_DOC_PDF && layer->kind == SPDF_PAINT_LAYER_BACKGROUND))
        return SPDF_PAINT_ERR_PAGE_LOCKED;
    if (layer->kind == SPDF_PAINT_LAYER_OBJECT || !(pix = layer->pixels) || pix->n != 4) return SPDF_PAINT_ERR_FAILED;
    scale = doc->raster_scale > 0 ? (float)doc->raster_scale : 1.0f;
    sx = (int)floorf(args->x * scale), sy = (int)floorf(args->y * scale);
    if (sx < 0 || sy < 0 || sx >= pix->w || sy >= pix->h) return SPDF_PAINT_OK;
    memset(&options, 0, sizeof(options));
    options.scale = scale;
    st = spdf_paint_render(doc, &options, &seen, err, sizeof(err)); /* the edges you see, page included */
    if (st != SPDF_PAINT_OK) return st;
    if (seen.width < pix->w || seen.height < pix->h) {
        spdf_free_bitmap(&seen);
        return SPDF_PAINT_ERR_FAILED;
    }
    mask = flood_region(doc->ctx, seen.rgba, seen.stride, pix->w, pix->h, sx, sy, tolerance_bytes(args->tolerance),
                        args->contiguous, doc->selection.active ? doc->selection.mask : NULL, &used);
    spdf_free_bitmap(&seen);
    if (!mask) return SPDF_PAINT_ERR_NO_MEMORY;
    if (!fz_is_empty_irect(used)) {
        spdf_paint_history_save_pixels(doc, layer, used);
        lay_fill(pix, mask, pix->w, used, args->color);
        if (damage) *damage = (spdf_rect){used.x0 / scale, used.y0 / scale, used.x1 / scale, used.y1 / scale};
    }
    fz_free(doc->ctx, mask);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_pick_color(spdf_paint_doc* doc, float x, float y, int from_visible,
                                        spdf_paint_color* out) {
    float scale;
    int px, py;
    if (out) *out = 0;
    if (!doc || !out) return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    scale = doc->raster_scale > 0 ? (float)doc->raster_scale : 1.0f;
    px = (int)floorf(x * scale), py = (int)floorf(y * scale);
    if (x < 0 || y < 0 || x >= doc->width || y >= doc->height) return SPDF_PAINT_OK;
    if (from_visible) {
        spdf_paint_render_options options;
        spdf_bitmap one = {0, 0, 0, NULL};
        char err[256];
        spdf_paint_status st;
        memset(&options, 0, sizeof(options));
        options.region = (spdf_rect){px / scale, py / scale, (px + 1) / scale, (py + 1) / scale};
        options.scale = scale;
        st = spdf_paint_render(doc, &options, &one, err, sizeof(err));
        if (st != SPDF_PAINT_OK) return st;
        if (one.rgba && one.width > 0 && one.height > 0) *out = unpremultiply(one.rgba);
        spdf_free_bitmap(&one);
    } else {
        spdf_paint_layer* layer = spdf_paint_layer_find(doc, doc->active);
        fz_pixmap* pix = layer ? layer->pixels : NULL;
        if (pix && pix->n == 4 && px - pix->x < pix->w && py - pix->y < pix->h && px >= pix->x && py >= pix->y)
            *out = unpremultiply(pix->samples + (size_t)(py - pix->y) * pix->stride + (size_t)(px - pix->x) * 4);
    }
    return SPDF_PAINT_OK;
}

/* ---- A click on an object ---- */

/* The object under (x, y), the topmost first, if nothing painted lies over it there; NULL for pixels. */
static spdf_paint_layer* object_at(spdf_paint_doc* doc, float x, float y) {
    float scale = doc->raster_scale > 0 ? (float)doc->raster_scale : 1.0f;
    int i, px = (int)floorf(x * scale), py = (int)floorf(y * scale);
    for (i = doc->layer_count - 1; i >= 0; --i) {
        spdf_paint_layer* l = doc->layers[i];
        if (!l->visible) continue;
        if (l->kind != SPDF_PAINT_LAYER_OBJECT) {
            fz_pixmap* p = l->pixels;
            if (l->kind == SPDF_PAINT_LAYER_BACKGROUND) return NULL;
            if (p && px >= p->x && py >= p->y && px < p->x + p->w && py < p->y + p->h &&
                p->samples[(size_t)(py - p->y) * p->stride + (size_t)(px - p->x) * 4 + 3] >= 128)
                return NULL; /* paint over the objects below: the fill is for those pixels */
            continue;
        }
        if (l->locked || !l->object || l->object->kind >= SPDF_PAINT_OBJ_FILL_TEXT) continue; /* Fill & Sign's own */
        if (spdf_paint_object_hit(doc, l->object, x, y, 2)) return l;
    }
    return NULL;
}

static spdf_paint_status fill_picture(spdf_paint_doc* doc, spdf_paint_layer* l, float x, float y,
                                      const spdf_paint_fill_args* args) {
    spdf_paint_object* o = l->object;
    fz_pixmap* pix = o->u.picture.pixels;
    fz_point local = fz_transform_point(fz_make_point(x, y), fz_invert_matrix(spdf_paint_place_matrix(&o->place)));
    spdf_rect r = o->place.rect;
    unsigned char* mask;
    fz_irect used;
    int sx, sy;
    if (!pix || pix->n != 4 || r.x1 <= r.x0 || r.y1 <= r.y0) return SPDF_PAINT_OK;
    sx = (int)floorf((local.x - r.x0) / (r.x1 - r.x0) * pix->w), sy = (int)floorf((local.y - r.y0) / (r.y1 - r.y0) * pix->h);
    if (sx < 0 || sy < 0 || sx >= pix->w || sy >= pix->h) return SPDF_PAINT_OK;
    mask = flood_region(doc->ctx, pix->samples, pix->stride, pix->w, pix->h, sx, sy, tolerance_bytes(args->tolerance),
                        args->contiguous, NULL, &used);
    if (!mask) return SPDF_PAINT_ERR_NO_MEMORY;
    if (!fz_is_empty_irect(used)) {
        spdf_paint_history_save_object(doc, l);
        lay_fill(pix, mask, pix->w, used, args->color);
    }
    fz_free(doc->ctx, mask);
    return SPDF_PAINT_OK;
}

static spdf_paint_status fill_object(spdf_paint_doc* doc, spdf_paint_layer* l, const spdf_paint_fill_args* args) {
    spdf_paint_object* o = l->object;
    if (o->kind == SPDF_PAINT_OBJ_PICTURE) return fill_picture(doc, l, args->x, args->y, args);
    spdf_paint_history_save_object(doc, l);
    switch (o->kind) {
    case SPDF_PAINT_OBJ_SHAPE:
        if (spdf_paint_shape_is_open(o->u.shape.shape)) o->u.shape.outline.color = args->color;
        else o->u.shape.fill.style = SPDF_PAINT_STYLE_SOLID, o->u.shape.fill.color = args->color;
        break;
    case SPDF_PAINT_OBJ_TEXT: o->u.text.background = args->color; break;
    case SPDF_PAINT_OBJ_PEN: case SPDF_PAINT_OBJ_ARROW: o->u.line.color = args->color; break;
    default: break;
    }
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_paint_fill(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_fill_args args;
    spdf_paint_layer *layer = NULL, *hit;
    spdf_paint_status st;
    spdf_rect damage = {0, 0, 0, 0};
    double v;
    int b = 1;
    st = spdf_paint_arg_check_page(call);
    if (st != SPDF_PAINT_OK) return call->message[0] ? st : spdf_paint_call_fail(call, st, "That page is not here.");
    memset(&args, 0, sizeof(args));
    spdf_paint_arg_number(call, "x", &v), args.x = (float)v;
    spdf_paint_arg_number(call, "y", &v), args.y = (float)v;
    if (!spdf_paint_arg_color(call, "color", &args.color)) args.color = doc->color1;
    args.tolerance = spdf_paint_arg_number(call, "tolerance", &v) ? (float)(v / 100.0) : 0.0f;
    spdf_paint_arg_bool(call, "contiguous", &b), args.contiguous = b;
    if ((hit = object_at(doc, args.x, args.y))) {
        fz_try(doc->ctx) st = fill_object(doc, hit, &args);
        fz_catch(doc->ctx) st = SPDF_PAINT_ERR_NO_MEMORY;
        if (st != SPDF_PAINT_OK) return spdf_paint_call_fail(call, st, "There isn't enough memory to fill this.");
        spdf_paint_object_update_bounds(hit->object);
        spdf_paint_damage(doc, hit->object->bounds);
        if (doc->kind == SPDF_PAINT_DOC_PDF) spdf_paint_pdf_note_change(doc, hit);
        cJSON_AddNumberToObject(call->reply, "object", hit->id);
        return SPDF_PAINT_OK;
    }
    if (!spdf_paint_active_pixels(doc, &layer) || !layer)
        return layer ? spdf_paint_fail_unpaintable(call, layer)
                     : spdf_paint_call_fail(call, SPDF_PAINT_ERR_FAILED, "There is no layer to fill into.");
    st = spdf_paint_flood_fill(doc, layer, &args, &damage);
    if (st == SPDF_PAINT_ERR_PAGE_LOCKED) return spdf_paint_call_fail(call, st, "The page itself can't be changed.");
    if (st == SPDF_PAINT_ERR_NO_MEMORY) return spdf_paint_call_fail(call, st, "There isn't enough memory to fill this.");
    if (st != SPDF_PAINT_OK) return spdf_paint_call_fail(call, st, "This layer can't be filled.");
    if (damage.x1 > damage.x0) {
        spdf_paint_damage(doc, damage);
        if (doc->kind == SPDF_PAINT_DOC_PDF) spdf_paint_pdf_note_change(doc, layer);
    }
    cJSON_AddNumberToObject(call->reply, "layer", layer->id);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_color_pick(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    const char* from = spdf_paint_arg_string(call, "from");
    spdf_paint_color color = 0;
    spdf_paint_status st;
    char text[10];
    double x = 0, y = 0;
    st = spdf_paint_arg_check_page(call);
    if (st != SPDF_PAINT_OK) return call->message[0] ? st : spdf_paint_call_fail(call, st, "That page is not here.");
    spdf_paint_arg_number(call, "x", &x), spdf_paint_arg_number(call, "y", &y);
    st = spdf_paint_pick_color(doc, (float)x, (float)y, !from || strcmp(from, "layer") != 0, &color);
    if (st != SPDF_PAINT_OK) return spdf_paint_call_fail(call, st, "The colour there can't be read.");
    spdf_paint_format_color(color, text);
    cJSON_AddStringToObject(call->reply, "color", text);
    return SPDF_PAINT_OK;
}
