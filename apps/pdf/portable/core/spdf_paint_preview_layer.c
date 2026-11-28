/* A PDF page's drawing layer drawn as the reader will draw it once written (spdf_paint_written.h): one picture over
 * the layer's painted box, its colours and its coverage apart, as the file stores them; drawn through MuPDF where
 * that gives the reader's pixels whatever part is drawn (a picture drawn smaller than its pixels), and sampled here as
 * MuPDF samples from where the reader will start where it does not (a picture drawn at its size or larger). And a pen
 * line's piece the pixel Eraser leaves, as Fill & Sign's Ink appearance draws it. */
#include "spdf_paint_written.h"
#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* MuPDF's fixed point for sampling pictures (draw-affine.c) */
typedef int64_t affint;
#define PREC 14
#define ONE (((affint)1) << PREC)
#define MASK (ONE - 1)
#define HALF (((affint)1) << (PREC - 1))

void spdf_paint_written_picture_drop(fz_context* ctx, spdf_paint_written_picture* p) {
    fz_drop_image(ctx, p->image);
    fz_drop_image(ctx, p->mask);
    fz_drop_pixmap(ctx, p->colors);
    fz_drop_pixmap(ctx, p->coverage);
    memset(p, 0, sizeof(*p));
    p->box = p->stale = fz_empty_irect;
}

/* As pdf_add_image stores a picture with transparency: each colour divided by the coverage, in its integer steps. */
static void take(const fz_pixmap* src, spdf_paint_written_picture* p, fz_irect area) {
    area = fz_intersect_irect(area, p->box);
    for (int y = area.y0; y < area.y1; y++) {
        const unsigned char* s = src->samples + (size_t)y * src->stride + (size_t)area.x0 * 4;
        unsigned char* c = p->colors->samples + (size_t)(y - p->box.y0) * p->colors->stride + (size_t)(area.x0 - p->box.x0) * 3;
        unsigned char* m = p->coverage->samples + (size_t)(y - p->box.y0) * p->coverage->stride + (area.x0 - p->box.x0);
        for (int x = area.x0; x < area.x1; x++, s += 4, c += 3) {
            int a = s[3], inva = a ? 255 * 256 / a : 0;
            c[0] = (unsigned char)((s[0] * inva) >> 8), c[1] = (unsigned char)((s[1] * inva) >> 8);
            c[2] = (unsigned char)((s[2] * inva) >> 8), *m++ = (unsigned char)a;
        }
    }
}

/* The picture of `used`, made again when the box moved, else only what changed taken again. Throws. */
static void picture_of(fz_context* ctx, spdf_paint_written_picture* p, const fz_pixmap* src, fz_irect used) {
    if (!p->colors || memcmp(&p->box, &used, sizeof(used))) {
        spdf_paint_written_picture_drop(ctx, p);
        p->colors = fz_new_pixmap(ctx, fz_device_rgb(ctx), used.x1 - used.x0, used.y1 - used.y0, NULL, 0);
        p->coverage = fz_new_pixmap(ctx, NULL, used.x1 - used.x0, used.y1 - used.y0, NULL, 1);
        p->box = used;
        take(src, p, used);
        p->mask = fz_new_image_from_pixmap(ctx, p->coverage, NULL);
        p->image = fz_new_image_from_pixmap(ctx, p->colors, p->mask);
    } else if (!fz_is_empty_irect(p->stale)) {
        take(src, p, p->stale);
    }
    p->stale = fz_empty_irect;
}

/* Where each column (or row) of the drawn part samples the picture, as fz_paint_image_imp steps from `from`. */
typedef struct sample_axis { int i, f, in; } sample_axis;

static void axis(sample_axis* out, int n, int first, int from, affint start, affint step, affint size, int lerp) {
    for (int k = 0; k < n; k++) {
        affint t = start + (affint)(first + k - from) * step;
        sample_axis* a = &out[k];
        if (lerp) {
            a->in = t + HALF >= 0 && t + ONE < (size << PREC) + HALF;
            affint i = t >> PREC;
            a->i = (int)i, a->f = (int)(t & MASK);
        } else {
            affint i = t >> PREC;
            a->in = i >= 0 && i < size;
            a->i = (int)i, a->f = 0;
        }
    }
}

static inline int clampi(int v, int n) { return v < 0 ? 0 : v >= n ? n - 1 : v; }
static inline int lerp1(int a, int b, int f) { return a + (((b - a) * f) >> PREC); }

/* The picture drawn larger than (or at) its pixels: as MuPDF draws it, the coverage painted into a clip, the colours
 * into a copy of what is there, the copy laid through the clip; sampled as fz_paint_image_imp samples from where the
 * reader's drawing starts (`crop`), for the pixels of `clip`. ctm: the picture's, on whole pixels (gridfit). */
static void paint_sampled(fz_context* ctx, fz_pixmap* dest, fz_irect clip, fz_irect crop, fz_matrix at, fz_matrix ctm,
                          const spdf_paint_written_picture* p, int alpha) {
    const fz_pixmap *col = p->colors, *cov = p->coverage;
    int sw = col->w, sh = col->h;
    fz_irect from = fz_intersect_irect(fz_irect_from_rect(fz_transform_rect(fz_unit_rect, ctm)), crop);
    from = fz_intersect_irect(from, fz_irect_from_rect(fz_transform_rect(fz_unit_rect, at)));
    fz_irect area = fz_intersect_irect(fz_intersect_irect(from, clip), fz_pixmap_bbox(ctx, dest));
    if (fz_is_empty_irect(area) || alpha <= 0) return;
    int lerp = 0;
    if (sqrtf(ctm.a * ctm.a + ctm.b * ctm.b) > sw) lerp = 1;
    if (sqrtf(ctm.c * ctm.c + ctm.d * ctm.d) > sh) lerp = 1;
    if (sqrtf(ctm.a * ctm.a + ctm.b * ctm.b) > sw * 2) lerp = 0; /* no /Interpolate: nearest at large sizes */
    if (sqrtf(ctm.c * ctm.c + ctm.d * ctm.d) > sh * 2) lerp = 0;
    fz_matrix inv = fz_invert_matrix(fz_pre_scale(ctm, 1.0f / sw, 1.0f / sh));
    affint fa = (affint)(inv.a *= ONE);
    affint fd = (affint)(inv.d *= ONE);
    inv.b *= ONE, inv.c *= ONE, inv.e *= ONE, inv.f *= ONE;
    int x = from.x0, y = from.y0;
    affint u = (int)((inv.a * x) + (inv.c * y) + inv.e + ((inv.a + inv.c) * .5f));
    affint v = (int)((inv.b * x) + (inv.d * y) + inv.f + ((inv.b + inv.d) * .5f));
    if (lerp) u -= HALF, v -= HALF;
    int w = area.x1 - area.x0, h = area.y1 - area.y0;
    sample_axis* cols = malloc((size_t)(w + h) * sizeof(*cols));
    if (!cols) return;
    sample_axis* rows = cols + w;
    axis(cols, w, area.x0, x, u, fa, sw, lerp);
    axis(rows, h, area.y0, y, v, fd, sh, lerp);
    int n = dest->n, keep = 255 - alpha;
    for (int r = 0; r < h; r++) {
        const sample_axis* ry = &rows[r];
        if (!ry->in) continue;
        unsigned char* d = dest->samples + (size_t)(area.y0 + r - dest->y) * dest->stride + (size_t)(area.x0 - dest->x) * n;
        int y0 = clampi(ry->i, sh), y1 = clampi(ry->i + 1, sh);
        const unsigned char *c0 = col->samples + (size_t)y0 * col->stride, *c1 = col->samples + (size_t)y1 * col->stride;
        const unsigned char *m0 = cov->samples + (size_t)y0 * cov->stride, *m1 = cov->samples + (size_t)y1 * cov->stride;
        for (int k = 0; k < w; k++, d += n) {
            const sample_axis* cx = &cols[k];
            if (!cx->in) continue;
            int m, c[3];
            if (lerp) {
                int x0 = clampi(cx->i, sw), x1 = clampi(cx->i + 1, sw), uf = cx->f, vf = ry->f;
                m = lerp1(lerp1(m0[x0], m0[x1], uf), lerp1(m1[x0], m1[x1], uf), vf);
                for (int j = 0; j < 3; j++)
                    c[j] = lerp1(lerp1(c0[x0 * 3 + j], c0[x1 * 3 + j], uf), lerp1(c1[x0 * 3 + j], c1[x1 * 3 + j], uf), vf);
            } else {
                m = m0[cx->i];
                for (int j = 0; j < 3; j++) c[j] = c0[cx->i * 3 + j];
            }
            int ma = FZ_EXPAND(m);
            if (ma == 0) continue;
            for (int j = 0; j < 3; j++) {
                int over = alpha == 255 ? c[j] : fz_mul255(c[j], alpha) + fz_mul255(d[j], keep);
                d[j] = (unsigned char)(ma == 256 ? over : FZ_BLEND(over, d[j], ma));
            }
            if (dest->alpha) {
                int a = alpha == 255 ? 255 : alpha + fz_mul255(d[3], keep);
                d[3] = (unsigned char)(ma == 256 ? a : FZ_BLEND(a, d[3], ma));
            }
        }
    }
    free(cols);
}

void spdf_paint_draw_layer_as_written(spdf_paint_doc* doc, spdf_paint_layer* layer, fz_pixmap* dest, fz_irect clip,
                                      float scale, float opacity) {
    fz_context* ctx = doc->ctx;
    fz_pixmap* src = layer->pixels;
    fz_irect used, crop;
    if (!spdf_paint_live_used(doc, layer, &used))
        used = layer->pdf_dirty || fz_is_empty_irect(layer->pdf_used)
                   ? spdf_paint_pixels_used(src, fz_make_irect(0, 0, src->w, src->h)) : layer->pdf_used;
    used = fz_intersect_irect(used, fz_make_irect(0, 0, src->w, src->h));
    if (fz_is_empty_irect(used) || opacity <= 0) return;
    spdf_paint_written_picture own, *p = spdf_paint_live_picture(doc, layer);
    memset(&own, 0, sizeof(own));
    if (!p) p = &own;
    float rs = (float)doc->raster_scale;
    fz_rect r = {used.x0 / rs, used.y0 / rs, used.x1 / rs, used.y1 / rs};
    fz_matrix at = fz_concat(fz_concat(fz_scale(r.x1 - r.x0, r.y1 - r.y0), fz_translate(r.x0, r.y0)), fz_scale(scale, scale));
    fz_device* dev = NULL;
    fz_var(dev);
    fz_try(ctx) {
        picture_of(ctx, p, src, used);
        fz_matrix ctm = fz_gridfit_matrix(0, at);
        int dw = (int)sqrtf(ctm.a * ctm.a + ctm.b * ctm.b), dh = (int)sqrtf(ctm.c * ctm.c + ctm.d * ctm.d);
        int smaller = dw < p->colors->w && dh < p->colors->h; /* fz_draw_fill_image scales it first */
        if (!smaller && ctm.b == 0 && ctm.c == 0 && ctm.a > 0 && ctm.d > 0 && spdf_paint_live_reader_crop(doc, scale, &crop)) {
            paint_sampled(ctx, dest, clip, crop, at, ctm, p, (int)(opacity * 255));
        } else {
            dev = fz_new_draw_device_with_bbox(ctx, fz_identity, dest, &clip);
            fz_clip_image_mask(ctx, dev, p->mask, at, fz_transform_rect(fz_unit_rect, at));
            fz_fill_image(ctx, dev, p->image, at, opacity, fz_default_color_params);
            fz_pop_clip(ctx, dev);
            fz_close_device(ctx, dev);
        }
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        if (p == &own) spdf_paint_written_picture_drop(ctx, &own);
    }
    fz_catch(ctx) fz_ignore_error(ctx);
}

/* A piece as the reader will draw it once written into the page: Fill & Sign's Ink appearance, its points joined by
 * straight lines with round ends and joins; an arrow's head a second line through its tip. */
void spdf_paint_draw_line_as_written(spdf_paint_doc* doc, const spdf_paint_object* o, fz_matrix ctm, fz_pixmap* dest,
                            fz_irect clip, float opacity) {
    fz_context* ctx = doc->ctx;
    const spdf_paint_point* p = o->u.line.points;
    int n = o->u.line.point_count;
    spdf_paint_color c = o->u.line.color;
    float rgb[3] = {((c >> 24) & 0xFF) / 255.0f, ((c >> 16) & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f};
    fz_device* dev = NULL;
    fz_path* path = NULL;
    fz_stroke_state* stroke = NULL;
    fz_var(dev), fz_var(path), fz_var(stroke);
    if (n < 1) return;
    fz_try(ctx) {
        path = fz_new_path(ctx);
        fz_moveto(ctx, path, p[0].x, p[0].y);
        for (int i = 1; i < n; i++) fz_lineto(ctx, path, p[i].x, p[i].y);
        if (n == 1) fz_lineto(ctx, path, p[0].x, p[0].y);
        if (o->kind == SPDF_PAINT_OBJ_ARROW && n >= 2) {
            spdf_fill_point head[3];
            spdf_ink_arrow_head((spdf_fill_point){p[0].x, p[0].y}, (spdf_fill_point){p[n - 1].x, p[n - 1].y},
                                o->u.line.width, head);
            fz_moveto(ctx, path, head[0].x, head[0].y);
            fz_lineto(ctx, path, head[1].x, head[1].y);
            fz_lineto(ctx, path, head[2].x, head[2].y);
        }
        stroke = fz_new_stroke_state(ctx);
        stroke->linewidth = o->u.line.width;
        stroke->start_cap = stroke->end_cap = stroke->dash_cap = FZ_LINECAP_ROUND;
        stroke->linejoin = FZ_LINEJOIN_ROUND;
        dev = fz_new_draw_device_with_bbox(ctx, fz_identity, dest, &clip);
        fz_stroke_path(ctx, dev, path, stroke, ctm, fz_device_rgb(ctx), rgb, (c & 0xFF) / 255.0f * opacity,
                       fz_default_color_params);
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_path(ctx, path);
        fz_drop_stroke_state(ctx, stroke);
    }
    fz_catch(ctx) fz_ignore_error(ctx);
}
