/* Annotate's Fill and Color picker (docs/plans/annotate.md § 2 Tools, § 8 Core spdf_paint_fill.c). paint.fill sends a
 * click on an object to the object: a shape gets a solid fill (a line its colour), a text box an opaque background, a
 * pen line or arrow its colour, a picture (a Fill made before included) is filled within its own pixels. Anywhere else
 * a scanline flood fill (tolerance, contiguous or everywhere) bounded by what was drawn on the layers makes a new
 * "Fill" object, a picture of that area in the colour; the base layer (the page, picture or canvas background) is
 * never an edge and is never filled. Colour pick from what you see or the active layer. */
#include "spdf_paint_brush_engine.h"
#include "spdf_paint_handlers.h"
#include "spdf_paint_model.h"
#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char spdf_paint_fill_object_name[] = "Fill";

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

/* Lays `color` (replacing what was there) into dest where mask is set, over box; mask rows are mw wide and start at
 * (mx, my) of dest's coordinates. */
static void lay_fill(fz_pixmap* dest, const unsigned char* mask, int mw, int mx, int my, fz_irect box,
                     spdf_paint_color color) {
    unsigned a = (unsigned)channel(color, 0);
    unsigned char px[4] = {(unsigned char)((channel(color, 24) * a + 127) / 255),
                           (unsigned char)((channel(color, 16) * a + 127) / 255),
                           (unsigned char)((channel(color, 8) * a + 127) / 255), (unsigned char)a};
    int x, y;
    for (y = box.y0; y < box.y1; ++y)
        for (x = box.x0; x < box.x1; ++x)
            if (mask[(size_t)(y + my) * mw + (x + mx)])
                memcpy(dest->samples + (size_t)y * dest->stride + (size_t)x * 4, px, 4);
}

static int tolerance_bytes(float tolerance) {
    float t = tolerance < 0 ? 0 : tolerance > 1 ? 1 : tolerance;
    return (int)lrintf(t * 255);
}

/* Grows the filled area into the soft edge of what bounds it (pixels drawn partly transparent, an antialiased line's
 * rim), `passes` pixels deep, so the fill meets the line with no gap of the document showing between them. */
static void grow_into_edges(unsigned char* mask, const unsigned char* rgba, ptrdiff_t stride, int w, int h, int passes,
                            fz_irect* used) {
    for (int pass = 1; pass <= passes; pass++) {
        fz_irect box = fz_intersect_irect(fz_make_irect(used->x0 - 1, used->y0 - 1, used->x1 + 1, used->y1 + 1),
                                          fz_make_irect(0, 0, w, h));
        for (int y = box.y0; y < box.y1; y++)
            for (int x = box.x0; x < box.x1; x++) {
                size_t i = (size_t)y * w + x;
                if (mask[i] || rgba[y * stride + x * 4 + 3] == 255) continue;
                int near = (x > 0 && mask[i - 1] == 1) || (x + 1 < w && mask[i + 1] == 1) ||
                           (y > 0 && mask[i - w] == 1) || (y + 1 < h && mask[i + w] == 1);
                if (near) mask[i] = (unsigned char)(pass + 1);
            }
        for (int y = box.y0; y < box.y1; y++) /* this pass's pixels count as filled for the next */
            for (int x = box.x0; x < box.x1; x++)
                if (mask[(size_t)y * w + x] == pass + 1) mask[(size_t)y * w + x] = 1;
        *used = box;
    }
}

static int touches_edge(fz_irect used, int w, int h) {
    return used.x0 <= 0 || used.y0 <= 0 || used.x1 >= w || used.y1 >= h;
}

spdf_paint_status spdf_paint_fill_region(spdf_paint_doc* doc, const spdf_paint_fill_args* args, fz_pixmap** out,
                                         spdf_rect* rect) {
    spdf_paint_render_options options;
    spdf_bitmap seen = {0, 0, 0, NULL};
    spdf_paint_id* drawn;
    unsigned char* mask;
    fz_irect used;
    char err[256];
    float scale;
    int w, h, sx, sy, count = 0, empty_seed;
    spdf_paint_status st;
    *out = NULL;
    *rect = (spdf_rect){0, 0, 0, 0};
    scale = doc->raster_scale > 0 ? (float)doc->raster_scale : 1.0f;
    w = (int)lrintf(doc->width * scale), h = (int)lrintf(doc->height * scale);
    sx = (int)floorf(args->x * scale), sy = (int)floorf(args->y * scale);
    if (sx < 0 || sy < 0 || sx >= w || sy >= h) return SPDF_PAINT_OK;
    /* The edges are what was drawn: every shown layer and object above the base layer (none: an empty list, which
     * draws nothing, so a transparent page of edges). */
    drawn = malloc(sizeof(*drawn) * (size_t)(doc->layer_count + 1));
    if (!drawn) return SPDF_PAINT_ERR_NO_MEMORY;
    for (int i = 1; i < doc->layer_count; i++)
        if (spdf_paint_entry_shown(doc, i)) drawn[count++] = doc->layers[i]->id;
    if (!count) drawn[count++] = (spdf_paint_id)-1; /* no such id: nothing drawn */
    memset(&options, 0, sizeof(options));
    options.scale = scale;
    options.layers = drawn, options.layer_count = count;
    st = spdf_paint_render(doc, &options, &seen, err, sizeof(err));
    free(drawn);
    if (st != SPDF_PAINT_OK) return st;
    if (seen.width < w || seen.height < h) {
        spdf_free_bitmap(&seen);
        return SPDF_PAINT_ERR_FAILED;
    }
    empty_seed = seen.rgba[(size_t)sy * seen.stride + (size_t)sx * 4 + 3] == 0;
    mask = flood_region(doc->ctx, seen.rgba, seen.stride, w, h, sx, sy, tolerance_bytes(args->tolerance),
                        args->contiguous, doc->selection.active ? doc->selection.mask : NULL, &used);
    if (mask && !fz_is_empty_irect(used) && !doc->selection.active)
        grow_into_edges(mask, seen.rgba, seen.stride, w, h, 2 * (int)scale, &used);
    spdf_free_bitmap(&seen);
    if (!mask) return SPDF_PAINT_ERR_NO_MEMORY;
    /* An empty area open to the edge of the canvas is the document itself, unless a pixel selection bounds it. */
    if (!fz_is_empty_irect(used) && empty_seed && !doc->selection.active && touches_edge(used, w, h)) {
        fz_free(doc->ctx, mask);
        return SPDF_PAINT_ERR_NOTHING_SELECTED;
    }
    if (!fz_is_empty_irect(used)) {
        fz_pixmap* pix = NULL;
        fz_try(doc->ctx) {
            pix = spdf_paint_pixmap_new(doc->ctx, used.x1 - used.x0, used.y1 - used.y0);
            lay_fill(pix, mask, w, used.x0, used.y0, fz_make_irect(0, 0, pix->w, pix->h), args->color);
        }
        fz_catch(doc->ctx) {
            fz_ignore_error(doc->ctx);
            fz_drop_pixmap(doc->ctx, pix);
            pix = NULL;
        }
        if (!pix) { fz_free(doc->ctx, mask); return SPDF_PAINT_ERR_NO_MEMORY; }
        *out = pix;
        *rect = (spdf_rect){used.x0 / scale, used.y0 / scale, used.x1 / scale, used.y1 / scale};
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
        lay_fill(pix, mask, pix->w, 0, 0, used, args->color);
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
    spdf_paint_layer* hit;
    spdf_paint_status st;
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
    /* Anywhere else: the area bounded by what was drawn becomes a Fill object of its own on the active layer, on top
     * of its objects, as a new shape would be; the document under the drawing is never filled. */
    spdf_paint_layer* home = spdf_paint_home_layer(doc);
    if (!home) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_FAILED, "There is no layer to fill on.");
    if (home->locked) return spdf_paint_fail_unpaintable(call, home);
    fz_pixmap* pix = NULL;
    spdf_rect rect;
    st = spdf_paint_fill_region(doc, &args, &pix, &rect);
    if (st == SPDF_PAINT_ERR_NOTHING_SELECTED)
        return spdf_paint_call_fail(call, st, "Fill fills shapes and closed outlines you drew. Click inside one.");
    if (st == SPDF_PAINT_ERR_NO_MEMORY) return spdf_paint_call_fail(call, st, "There isn't enough memory to fill this.");
    if (st != SPDF_PAINT_OK) return spdf_paint_call_fail(call, st, "This area can't be filled.");
    if (!pix) return SPDF_PAINT_OK;
    spdf_paint_id id = 0;
    spdf_paint_object* o = spdf_paint_object_new(doc, SPDF_PAINT_OBJ_PICTURE, &id);
    if (!o) {
        fz_drop_pixmap(doc->ctx, pix);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There isn't enough memory to fill this.");
    }
    o->u.picture.pixels = pix;
    o->place.rect = rect;
    spdf_paint_layer* entry = spdf_paint_layer_find(doc, id);
    snprintf(entry->name, sizeof(entry->name), "%s", spdf_paint_fill_object_name);
    spdf_paint_history_save_active(doc);
    spdf_paint_object_update_bounds(o);
    spdf_paint_changed(doc, entry, o->bounds);
    cJSON_AddNumberToObject(call->reply, "id", id);
    cJSON_AddNumberToObject(call->reply, "layer", home->id);
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
