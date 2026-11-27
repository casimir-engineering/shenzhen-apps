/* Annotate's composite (docs/plans/annotate.md § 8 Core): every visible layer and object bottom to top, opacity
 * applied, into premultiplied RGBA, at any scale and region; the 256 x 256 tile cache of pictures and canvases at
 * scale 1; layer thumbnails; and drawing the objects Core A owns (pictures, pen lines, arrows). Shapes and text are
 * drawn by Core B, a PDF page and its foreign annotations by the PDF bridge. */
#include "spdf_paint_model.h"

#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SPDF_PAINT_TILE_BUDGET 1024 /* cached tiles kept at most (256 MB) */

fz_matrix spdf_paint_placement_matrix(const spdf_paint_placement* p) {
    float cx = (p->rect.x0 + p->rect.x1) / 2, cy = (p->rect.y0 + p->rect.y1) / 2;
    fz_matrix m = fz_translate(-cx, -cy);
    m = fz_concat(m, fz_scale(p->flip_h ? -1.0f : 1.0f, p->flip_v ? -1.0f : 1.0f));
    m = fz_concat(m, fz_rotate(p->rotation));
    return fz_concat(m, fz_translate(cx, cy));
}

static void clear_box(fz_pixmap* dest, fz_irect box) {
    for (int y = box.y0; y < box.y1; y++)
        memset(dest->samples + (y - dest->y) * dest->stride + (box.x0 - dest->x) * 4, 0, (size_t)(box.x1 - box.x0) * 4);
}

static inline unsigned mul255(unsigned a, unsigned b) {
    unsigned t = a * b + 128;
    return (t + (t >> 8)) >> 8;
}

void spdf_paint_draw_raster(spdf_paint_doc* doc, fz_pixmap* src, fz_pixmap* dest, fz_irect clip, float scale,
                            float opacity, int nearest) {
    fz_context* ctx = doc->ctx;
    clip = fz_intersect_irect(clip, fz_pixmap_bbox(ctx, dest));
    if (fz_is_empty_irect(clip) || opacity <= 0) return;
    unsigned op = (unsigned)(fminf(opacity, 1.0f) * 255 + 0.5f);
    if (fabsf(scale - (float)doc->raster_scale) < 1e-5f) {
        clip = fz_intersect_irect(clip, fz_pixmap_bbox(ctx, src));
        for (int y = clip.y0; y < clip.y1; y++) {
            const unsigned char* s = src->samples + (y - src->y) * src->stride + (clip.x0 - src->x) * 4;
            unsigned char* d = dest->samples + (y - dest->y) * dest->stride + (clip.x0 - dest->x) * 4;
            for (int x = clip.x0; x < clip.x1; x++, s += 4, d += 4) {
                unsigned sa = op == 255 ? s[3] : mul255(s[3], op);
                if (!sa) continue;
                if (sa == 255) { memcpy(d, s, 4); continue; }
                unsigned keep = 255 - sa;
                for (int c = 0; c < 3; c++)
                    d[c] = (unsigned char)((op == 255 ? s[c] : mul255(s[c], op)) + mul255(d[c], keep));
                d[3] = (unsigned char)(sa + mul255(d[3], keep));
            }
        }
        return;
    }
    fz_device* dev = NULL;
    fz_image* image = NULL;
    fz_pixmap* part = NULL;
    fz_var(dev);
    fz_var(image);
    fz_var(part);
    fz_try(ctx) {
        dev = fz_new_draw_device_with_bbox(ctx, fz_identity, dest, &clip);
        if (nearest) fz_enable_device_hints(ctx, dev, FZ_DONT_INTERPOLATE_IMAGES);
        float k = scale / (float)doc->raster_scale;
        /* Shrinking by a whole factor (the view's tiles: 1/2, 1/4, ...): only the source pixels under the clip, cut on
         * that factor's grid with two output pixels' margin, so every output pixel averages the same pixels as from
         * the whole layer. A tile of an 8000 px picture at a low zoom is drawn from its own part instead of scaling
         * the whole layer for every tile. Any other scale draws from the whole layer. */
        fz_irect need = fz_pixmap_bbox(ctx, src);
        int factor = (int)lroundf(1.0f / k);
        if (k < 1 && factor > 1 && fabsf(factor * k - 1.0f) < 1e-4f) {
            fz_irect cut = {(clip.x0 - 2) * factor, (clip.y0 - 2) * factor, (clip.x1 + 2) * factor,
                            (clip.y1 + 2) * factor};
            need = fz_intersect_irect(cut, need);
        }
        if (!fz_is_empty_irect(need)) {
            /* A view of those pixels, not a copy (fz_new_pixmap_from_pixmap misplaces a sub-area's columns). */
            part = fz_new_pixmap_with_data(ctx, src->colorspace, need.x1 - need.x0, need.y1 - need.y0, NULL, src->alpha,
                                           src->stride, src->samples + (size_t)(need.y0 - src->y) * src->stride +
                                                            (size_t)(need.x0 - src->x) * src->n);
            image = fz_new_image_from_pixmap(ctx, part, NULL);
            fz_matrix place = fz_scale((need.x1 - need.x0) * k, (need.y1 - need.y0) * k);
            place.e = need.x0 * k, place.f = need.y0 * k;
            fz_fill_image(ctx, dev, image, place, opacity, fz_default_color_params);
        }
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_image(ctx, image);
        fz_drop_pixmap(ctx, part);
        fz_drop_device(ctx, dev);
    }
    fz_catch(ctx) fz_ignore_error(ctx);
}

/* ---- Objects Core A draws ---- */

static void draw_picture(spdf_paint_doc* doc, const spdf_paint_object* o, fz_matrix ctm, fz_pixmap* dest,
                         fz_irect clip, float opacity) {
    fz_context* ctx = doc->ctx;
    if (!o->u.picture.pixels) return;
    const spdf_rect* r = &o->place.rect;
    fz_matrix m = fz_concat(fz_scale(r->x1 - r->x0, r->y1 - r->y0), fz_translate(r->x0, r->y0));
    m = fz_concat(fz_concat(m, spdf_paint_placement_matrix(&o->place)), ctm);
    fz_device* dev = NULL;
    fz_image* image = NULL;
    fz_var(dev);
    fz_var(image);
    fz_try(ctx) {
        dev = fz_new_draw_device_with_bbox(ctx, fz_identity, dest, &clip);
        image = fz_new_image_from_pixmap(ctx, o->u.picture.pixels, NULL);
        fz_fill_image(ctx, dev, image, m, opacity, fz_default_color_params);
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_image(ctx, image);
        fz_drop_device(ctx, dev);
    }
    fz_catch(ctx) fz_ignore_error(ctx);
}

static fz_point pt(spdf_fill_point p) { fz_point q = {p.x, p.y}; return q; }

static fz_path* line_path(fz_context* ctx, const spdf_paint_object* o) {
    const spdf_paint_line_params* line = &o->u.line;
    fz_path* path = fz_new_path(ctx);
    if (o->kind == SPDF_PAINT_OBJ_ARROW && line->point_count >= 2) {
        spdf_fill_point tail = {line->points[0].x, line->points[0].y};
        spdf_fill_point tip = {line->points[line->point_count - 1].x, line->points[line->point_count - 1].y};
        spdf_fill_point head[3];
        spdf_ink_arrow_head(tail, tip, line->width, head);
        fz_moveto(ctx, path, tail.x, tail.y);
        fz_lineto(ctx, path, tip.x, tip.y);
        fz_moveto(ctx, path, pt(head[0]).x, pt(head[0]).y);
        fz_lineto(ctx, path, pt(head[1]).x, pt(head[1]).y);
        fz_lineto(ctx, path, pt(head[2]).x, pt(head[2]).y);
        return path;
    }
    const spdf_paint_point* p = line->points;
    int n = line->point_count;
    fz_moveto(ctx, path, p[0].x, p[0].y);
    if (n == 1) { fz_lineto(ctx, path, p[0].x, p[0].y); return path; }
    spdf_fill_point out[64];
    for (int i = 0; i + 1 < n; i++) {
        spdf_fill_point p0 = {p[i > 0 ? i - 1 : i].x, p[i > 0 ? i - 1 : i].y}, p1 = {p[i].x, p[i].y};
        spdf_fill_point p2 = {p[i + 1].x, p[i + 1].y}, p3 = {p[i + 2 < n ? i + 2 : i + 1].x, p[i + 2 < n ? i + 2 : i + 1].y};
        int k = spdf_ink_flatten_segment(p0, p1, p2, p3, 0.2f, 4.0f, out, 64);
        for (int j = 0; j < k; j++) fz_lineto(ctx, path, out[j].x, out[j].y);
    }
    return path;
}

static void draw_line(spdf_paint_doc* doc, const spdf_paint_object* o, fz_matrix ctm, fz_pixmap* dest, fz_irect clip,
                      float opacity) {
    fz_context* ctx = doc->ctx;
    if (o->u.line.point_count <= 0) return;
    spdf_paint_color c = o->u.line.color;
    float rgb[3] = {((c >> 24) & 0xFF) / 255.0f, ((c >> 16) & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f};
    float alpha = (c & 0xFF) / 255.0f * opacity;
    fz_device* dev = NULL;
    fz_path* path = NULL;
    fz_stroke_state* stroke = NULL;
    fz_var(dev);
    fz_var(path);
    fz_var(stroke);
    fz_try(ctx) {
        path = line_path(ctx, o);
        stroke = fz_new_stroke_state(ctx);
        stroke->linewidth = o->u.line.width;
        stroke->start_cap = stroke->end_cap = stroke->dash_cap = FZ_LINECAP_ROUND;
        stroke->linejoin = FZ_LINEJOIN_ROUND;
        dev = fz_new_draw_device_with_bbox(ctx, fz_identity, dest, &clip);
        fz_stroke_path(ctx, dev, path, stroke, fz_concat(spdf_paint_placement_matrix(&o->place), ctm),
                       fz_device_rgb(ctx), rgb, alpha, fz_default_color_params);
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_path(ctx, path);
        fz_drop_stroke_state(ctx, stroke);
    }
    fz_catch(ctx) fz_ignore_error(ctx);
}

int spdf_paint_object_draw(spdf_paint_doc* doc, const spdf_paint_object* o, fz_matrix ctm, fz_pixmap* dest,
                           fz_irect clip, float opacity) {
    if (!doc || !o || !dest) return 0;
    switch (o->kind) {
    case SPDF_PAINT_OBJ_SHAPE: return spdf_paint_shape_draw(doc, &o->place, &o->u.shape, ctm, dest, clip, opacity);
    case SPDF_PAINT_OBJ_TEXT: return spdf_paint_text_draw(doc, &o->place, &o->u.text, ctm, dest, clip, opacity);
    case SPDF_PAINT_OBJ_PICTURE: draw_picture(doc, o, ctm, dest, clip, opacity); return 1;
    case SPDF_PAINT_OBJ_PEN:
    case SPDF_PAINT_OBJ_ARROW: draw_line(doc, o, ctm, dest, clip, opacity); return 1;
    default: return spdf_paint_pdf_draw_annotation(doc, o, ctm, dest, clip, opacity);
    }
}

/* ---- The composite ---- */

static int in_list(const spdf_paint_id* ids, int count, spdf_paint_id id) {
    for (int i = 0; i < count; i++)
        if (ids[i] == id) return 1;
    return 0;
}

void spdf_paint_composite_into(spdf_paint_doc* doc, fz_pixmap* dest, fz_irect clip, float scale, unsigned flags,
                               const spdf_paint_id* filter, int filter_count) {
    clip = fz_intersect_irect(clip, fz_pixmap_bbox(doc->ctx, dest));
    if (fz_is_empty_irect(clip)) return;
    clear_box(dest, clip);
    int nearest = (flags & SPDF_PAINT_RENDER_NEAREST) && scale > (float)doc->raster_scale;
    spdf_paint_layer* owner = NULL; /* the layer the objects that follow are on: its eye and opacity apply to them */
    for (int i = 0; i < doc->layer_count; i++) {
        spdf_paint_layer* layer = doc->layers[i];
        if (layer->kind != SPDF_PAINT_LAYER_OBJECT) owner = layer->kind == SPDF_PAINT_LAYER_RASTER ? layer : NULL;
        int listed = in_list(filter, filter_count, layer->id) || (owner && in_list(filter, filter_count, owner->id));
        if (filter_count > 0 ? !listed : !layer->visible || (owner && !owner->visible)) continue;
        float opacity = layer->object && owner ? layer->opacity * owner->opacity : layer->opacity;
        if ((flags & SPDF_PAINT_RENDER_HIDE_SELECTION) &&
            in_list(doc->selection.objects, doc->selection.object_count, layer->id))
            continue;
        if (spdf_paint_layer_is_page(doc, layer)) {
            if (!(flags & SPDF_PAINT_RENDER_SKIP_LOCKED_BACKGROUND))
                spdf_paint_pdf_draw_page(doc, fz_scale(scale, scale), dest, clip,
                                         (flags & SPDF_PAINT_RENDER_DARK_PAGE) != 0);
            continue;
        }
        if (layer->object) spdf_paint_object_draw(doc, layer->object, fz_scale(scale, scale), dest, clip, opacity);
        else if (layer->pixels) spdf_paint_draw_raster(doc, layer->pixels, dest, clip, scale, opacity, nearest);
    }
}

static void trim_tiles(spdf_paint_doc* doc, fz_irect keep) {
    spdf_paint_tile_cache* cache = &doc->tiles;
    int count = 0;
    for (int i = 0; i < cache->tiles_x * cache->tiles_y; i++) count += cache->tiles[i].composite != NULL;
    if (count <= SPDF_PAINT_TILE_BUDGET) return;
    for (int i = 0; i < cache->tiles_x * cache->tiles_y; i++) {
        spdf_paint_tile* tile = &cache->tiles[i];
        if (!tile->composite) continue;
        if (!fz_is_empty_irect(fz_intersect_irect(fz_pixmap_bbox(doc->ctx, tile->composite), keep))) continue;
        fz_drop_pixmap(doc->ctx, tile->composite);
        tile->composite = NULL;
        tile->valid = 0;
    }
}

static int composite_from_tiles(spdf_paint_doc* doc, fz_pixmap* dest) {
    fz_context* ctx = doc->ctx;
    spdf_paint_tile_cache* cache = &doc->tiles;
    fz_irect want = fz_intersect_irect(fz_pixmap_bbox(ctx, dest), spdf_paint_raster_box(doc, spdf_paint_canvas_rect(doc)));
    clear_box(dest, fz_intersect_irect(fz_pixmap_bbox(ctx, dest), fz_pixmap_bbox(ctx, dest)));
    if (fz_is_empty_irect(want)) return 1;
    trim_tiles(doc, want);
    int T = SPDF_PAINT_TILE_SIZE;
    for (int ty = want.y0 / T; ty * T < want.y1; ty++)
        for (int tx = want.x0 / T; tx * T < want.x1; tx++) {
            spdf_paint_tile* tile = &cache->tiles[ty * cache->tiles_x + tx];
            fz_irect box = {tx * T, ty * T, tx * T + T, ty * T + T};
            box = fz_intersect_irect(box, spdf_paint_raster_box(doc, spdf_paint_canvas_rect(doc)));
            if (!tile->composite) {
                fz_try(ctx) tile->composite = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), box, NULL, 1);
                fz_catch(ctx) { fz_ignore_error(ctx); return 0; }
                tile->valid = 0;
            }
            if (!tile->valid) {
                spdf_paint_composite_into(doc, tile->composite, box, 1.0f, 0, NULL, 0);
                tile->valid = 1;
            }
            fz_irect part = fz_intersect_irect(box, want);
            for (int y = part.y0; y < part.y1; y++)
                memcpy(dest->samples + (y - dest->y) * dest->stride + (part.x0 - dest->x) * 4,
                       tile->composite->samples + (y - box.y0) * tile->composite->stride + (part.x0 - box.x0) * 4,
                       (size_t)(part.x1 - part.x0) * 4);
        }
    return 1;
}

/* SPDF_PAINT_RENDER_SELECTED_ONLY: everything outside the selection mask becomes transparent (premultiplied). */
static void keep_selected(spdf_paint_doc* doc, fz_pixmap* pix, float scale) {
    const fz_pixmap* mask = doc->selection.mask;
    float rs = (float)(doc->raster_scale > 0 ? doc->raster_scale : 1);
    for (int y = 0; y < pix->h; y++) {
        int my = (int)floorf((pix->y + y + 0.5f) / scale * rs) - (mask ? mask->y : 0);
        unsigned char* p = pix->samples + (size_t)y * pix->stride;
        for (int x = 0; x < pix->w; x++, p += 4) {
            int mx = (int)floorf((pix->x + x + 0.5f) / scale * rs) - (mask ? mask->x : 0);
            int m = mask && mx >= 0 && my >= 0 && mx < mask->w && my < mask->h ? mask->samples[my * mask->stride + mx] : 0;
            for (int c = 0; c < 4; c++) p[c] = (unsigned char)((p[c] * m + 127) / 255);
        }
    }
}

static void apply_matte(fz_pixmap* pix, spdf_paint_color matte) {
    unsigned char m[4];
    spdf_paint_color_bytes(matte | 0xFF, m);
    for (int y = 0; y < pix->h; y++) {
        unsigned char* p = pix->samples + y * pix->stride;
        for (int x = 0; x < pix->w; x++, p += 4) {
            unsigned keep = 255 - p[3];
            for (int c = 0; c < 3; c++) p[c] = (unsigned char)(p[c] + mul255(m[c], keep));
            p[3] = 255;
        }
    }
}

spdf_paint_status spdf_paint_render(spdf_paint_doc* doc, const spdf_paint_render_options* options, spdf_bitmap* out,
                                    char* err, size_t err_len) {
    if (!doc || !doc->ctx || !out) {
        spdf_paint_set_error(err, err_len, "Nothing to draw.");
        return SPDF_PAINT_ERR_FAILED;
    }
    memset(out, 0, sizeof(*out));
    fz_context* ctx = doc->ctx;
    spdf_rect region = spdf_paint_canvas_rect(doc);
    float scale = 1.0f;
    unsigned flags = 0;
    const spdf_paint_id* filter = NULL;
    int filter_count = 0;
    spdf_paint_color matte = 0;
    if (options) {
        if (options->region.x1 > options->region.x0 && options->region.y1 > options->region.y0)
            region = options->region;
        if (options->scale > 0) scale = options->scale;
        flags = options->flags;
        filter = options->layers;
        filter_count = options->layers ? options->layer_count : 0;
        matte = options->matte;
    }
    fz_irect box;
    box.x0 = (int)floorf(region.x0 * scale);
    box.y0 = (int)floorf(region.y0 * scale);
    box.x1 = box.x0 + (int)ceilf((region.x1 - region.x0) * scale);
    box.y1 = box.y0 + (int)ceilf((region.y1 - region.y0) * scale);
    if (box.x1 <= box.x0) box.x1 = box.x0 + 1;
    if (box.y1 <= box.y0) box.y1 = box.y0 + 1;
    uint64_t pixels = (uint64_t)(box.x1 - box.x0) * (uint64_t)(box.y1 - box.y0);
    if (pixels > SPDF_PAINT_MAX_PIXELS) {
        spdf_paint_set_error(err, err_len, "That picture would be too large; use a smaller scale or region.");
        return SPDF_PAINT_ERR_TOO_LARGE;
    }
    fz_pixmap* dest = NULL;
    fz_try(ctx) dest = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), box, NULL, 1);
    fz_catch(ctx) { fz_ignore_error(ctx);
        spdf_paint_set_error(err, err_len, "There is not enough memory to draw this.");
        return SPDF_PAINT_ERR_NO_MEMORY;
    }
    int cached = (doc->kind & SPDF_PAINT_DOC_RASTER) && doc->tiles.tiles && fabsf(scale - 1.0f) < 1e-6f &&
                 !filter_count && !(flags & SPDF_PAINT_RENDER_HIDE_SELECTION);
    if (!cached || !composite_from_tiles(doc, dest))
        spdf_paint_composite_into(doc, dest, box, scale, flags, filter, filter_count);
    if (flags & SPDF_PAINT_RENDER_SELECTED_ONLY) keep_selected(doc, dest, scale);
    if (matte) apply_matte(dest, matte);
    out->width = dest->w;
    out->height = dest->h;
    out->stride = dest->w * 4;
    out->rgba = malloc((size_t)out->stride * out->height);
    if (out->rgba)
        for (int y = 0; y < dest->h; y++)
            memcpy(out->rgba + (size_t)y * out->stride, dest->samples + y * dest->stride, (size_t)out->stride);
    fz_drop_pixmap(ctx, dest);
    if (!out->rgba) {
        memset(out, 0, sizeof(*out));
        spdf_paint_set_error(err, err_len, "There is not enough memory to draw this.");
        return SPDF_PAINT_ERR_NO_MEMORY;
    }
    return SPDF_PAINT_OK;
}

/* What a layer's thumbnail shows: an object's own box, a raster layer's painted pixels (the canvas while it is
 * empty), the whole canvas for the Background, so small things stay visible in the Layers panel. */
static spdf_rect thumbnail_region(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    spdf_rect all = spdf_paint_canvas_rect(doc);
    if (layer->object) {
        spdf_paint_object_update_bounds(layer->object);
        spdf_rect b = layer->object->bounds;
        float pad = fmaxf(2.0f, 0.05f * fmaxf(b.x1 - b.x0, b.y1 - b.y0));
        return b.x1 > b.x0 && b.y1 > b.y0 ? (spdf_rect){b.x0 - pad, b.y0 - pad, b.x1 + pad, b.y1 + pad} : all;
    }
    if (layer->kind == SPDF_PAINT_LAYER_BACKGROUND || !layer->pixels) return all;
    const fz_pixmap* p = layer->pixels;
    int x0 = p->w, y0 = p->h, x1 = -1, y1 = -1;
    for (int y = 0; y < p->h; y++) {
        const unsigned char* row = p->samples + (size_t)y * p->stride;
        for (int x = 0; x < p->w; x++)
            if (row[x * 4 + 3]) {
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                y1 = y;
            }
    }
    if (x1 < 0) return all;
    float rs = (float)doc->raster_scale, pad = 2.0f;
    return (spdf_rect){x0 / rs - pad, y0 / rs - pad, (x1 + 1) / rs + pad, (y1 + 1) / rs + pad};
}

spdf_paint_status spdf_paint_layer_thumbnail(spdf_paint_doc* doc, spdf_paint_id layer, int max_side, spdf_bitmap* out,
                                             char* err, size_t err_len) {
    spdf_paint_layer* found = doc && doc->ctx ? spdf_paint_layer_find(doc, layer) : NULL;
    if (!found) {
        spdf_paint_set_error(err, err_len, "There is no such layer.");
        return SPDF_PAINT_ERR_NOT_FOUND;
    }
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.region = thumbnail_region(doc, found);
    float side = fmaxf(options.region.x1 - options.region.x0, options.region.y1 - options.region.y0);
    options.scale = side > 0 && max_side > 0 ? fminf((float)max_side / side, 4.0f) : 1.0f;
    options.layers = &layer;
    options.layer_count = 1;
    return spdf_paint_render(doc, &options, out, err, err_len);
}

/* ---- Pictures in ---- */

fz_pixmap* spdf_paint_pixmap_to_rgba(fz_context* ctx, fz_pixmap* pix) {
    fz_pixmap* rgb = NULL;
    fz_pixmap* rgba = NULL;
    fz_var(rgb);
    fz_try(ctx) {
        if (pix->colorspace == fz_device_rgb(ctx) || (pix->colorspace && fz_colorspace_is_rgb(ctx, pix->colorspace)))
            rgb = fz_keep_pixmap(ctx, pix);
        else
            rgb = fz_convert_pixmap(ctx, pix, fz_device_rgb(ctx), NULL, NULL, fz_default_color_params, 1);
        rgba = fz_new_pixmap(ctx, fz_device_rgb(ctx), rgb->w, rgb->h, NULL, 1);
        for (int y = 0; y < rgb->h; y++) {
            const unsigned char* s = rgb->samples + y * rgb->stride;
            unsigned char* d = rgba->samples + y * rgba->stride;
            for (int x = 0; x < rgb->w; x++, s += rgb->n, d += 4) {
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
                d[3] = rgb->alpha ? s[3] : 255;
            }
        }
    }
    fz_always(ctx) fz_drop_pixmap(ctx, rgb);
    fz_catch(ctx) { fz_ignore_error(ctx); rgba = NULL; }
    return rgba;
}

fz_pixmap* spdf_paint_decode_picture(fz_context* ctx, fz_buffer* bytes) {
    fz_image* image = NULL;
    fz_pixmap* pix = NULL;
    fz_pixmap* rgba = NULL;
    fz_var(image);
    fz_var(pix);
    fz_try(ctx) {
        image = fz_new_image_from_buffer(ctx, bytes);
        pix = fz_get_pixmap_from_image(ctx, image, NULL, NULL, NULL, NULL);
        rgba = spdf_paint_pixmap_to_rgba(ctx, pix);
    }
    fz_always(ctx) {
        fz_drop_pixmap(ctx, pix);
        fz_drop_image(ctx, image);
    }
    fz_catch(ctx) { fz_ignore_error(ctx); rgba = NULL; }
    return rgba;
}
