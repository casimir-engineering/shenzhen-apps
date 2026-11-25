/* Annotate's pixel transforms (docs/plans/annotate.md § 2 Image group, § 8 Core spdf_paint_transform.c): resize
 * (Lanczos down, bilinear up, separable), rotate by any angle, any affine map (skew), exact quarter turns and flips,
 * placing a pixmap on a bigger or smaller one (canvas resize, crop), invert and black and white. All on premultiplied
 * RGBA pixmaps; the handlers that use them live in spdf_paint_transform_ops.c. */
#include "spdf_paint_model.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static inline unsigned char clamp_byte(float v) { return v <= 0 ? 0 : v >= 255 ? 255 : (unsigned char)(v + 0.5f); }

static float lanczos3(float x) {
    x = fabsf(x);
    if (x < 1e-6f) return 1.0f;
    if (x >= 3.0f) return 0.0f;
    float px = (float)M_PI * x;
    return 3.0f * sinf(px) * sinf(px / 3.0f) / (px * px);
}

typedef struct contrib {
    int first, count;
    float* weights;
} contrib;

/* Weights from src_len samples to dst_len: Lanczos 3 when shrinking, bilinear when growing. */
static contrib* make_contribs(int src_len, int dst_len) {
    contrib* list = calloc((size_t)dst_len, sizeof(*list));
    if (!list) return NULL;
    float ratio = (float)src_len / dst_len;
    int shrink = ratio > 1.0f;
    float support = shrink ? 3.0f * ratio : 1.0f;
    for (int i = 0; i < dst_len; i++) {
        float center = (i + 0.5f) * ratio - 0.5f;
        int first = (int)floorf(center - support) + 1, last = (int)ceilf(center + support) - 1;
        if (!shrink) { first = (int)floorf(center); last = first + 1; }
        int count = last - first + 1;
        list[i].weights = calloc((size_t)count, sizeof(float));
        if (!list[i].weights) return list;
        float total = 0;
        for (int k = 0; k < count; k++) {
            float d = (first + k) - center;
            float w = shrink ? lanczos3(d / ratio) : fmaxf(0.0f, 1.0f - fabsf(d));
            list[i].weights[k] = w;
            total += w;
        }
        for (int k = 0; k < count && total != 0; k++) list[i].weights[k] /= total;
        list[i].first = first;
        list[i].count = count;
    }
    return list;
}

static void free_contribs(contrib* list, int n) {
    for (int i = 0; list && i < n; i++) free(list[i].weights);
    free(list);
}

static void fix_premultiplied(unsigned char* p) {
    for (int c = 0; c < 3; c++)
        if (p[c] > p[3]) p[c] = p[3];
}

/* One axis: horizontal (rows keep their height) or vertical. */
static fz_pixmap* scale_axis(fz_context* ctx, const fz_pixmap* src, int len, int horizontal) {
    int src_len = horizontal ? src->w : src->h;
    fz_pixmap* dst = spdf_paint_pixmap_new(ctx, horizontal ? len : src->w, horizontal ? src->h : len);
    contrib* list = dst ? make_contribs(src_len, len) : NULL;
    if (!list) { fz_drop_pixmap(ctx, dst); return NULL; }
    int lines = horizontal ? src->h : src->w;
    for (int line = 0; line < lines; line++)
        for (int i = 0; i < len; i++) {
            float acc[4] = {0, 0, 0, 0};
            for (int k = 0; k < list[i].count; k++) {
                int j = list[i].first + k;
                j = j < 0 ? 0 : j >= src_len ? src_len - 1 : j;
                const unsigned char* s = horizontal ? src->samples + line * src->stride + j * 4
                                                    : src->samples + j * src->stride + line * 4;
                float w = list[i].weights[k];
                for (int c = 0; c < 4; c++) acc[c] += s[c] * w;
            }
            unsigned char* d = horizontal ? dst->samples + line * dst->stride + i * 4
                                          : dst->samples + i * dst->stride + line * 4;
            for (int c = 0; c < 4; c++) d[c] = clamp_byte(acc[c]);
            fix_premultiplied(d);
        }
    free_contribs(list, len);
    return dst;
}

fz_pixmap* spdf_paint_scale_pixmap(fz_context* ctx, const fz_pixmap* src, int w, int h) {
    if (!src || w < 1 || h < 1) return NULL;
    if (w == src->w && h == src->h) {
        fz_pixmap* copy = NULL;
        fz_try(ctx) copy = fz_clone_pixmap(ctx, src);
        fz_catch(ctx) { fz_ignore_error(ctx); copy = NULL; }
        if (copy) copy->x = copy->y = 0;
        return copy;
    }
    fz_pixmap* across = w == src->w ? NULL : scale_axis(ctx, src, w, 1);
    const fz_pixmap* mid = across ? across : src;
    if (w != src->w && !across) return NULL;
    fz_pixmap* out = h == src->h ? NULL : scale_axis(ctx, mid, h, 0);
    if (h == src->h) return across;
    fz_drop_pixmap(ctx, across);
    return out;
}

/* Bilinear sample at (x, y) in pixel coordinates (centres at .5), transparent outside. */
static void sample(const fz_pixmap* src, float x, float y, unsigned char out[4]) {
    x -= 0.5f;
    y -= 0.5f;
    int x0 = (int)floorf(x), y0 = (int)floorf(y);
    float fx = x - x0, fy = y - y0;
    float acc[4] = {0, 0, 0, 0};
    for (int k = 0; k < 4; k++) {
        int sx = x0 + (k & 1), sy = y0 + (k >> 1);
        if (sx < 0 || sy < 0 || sx >= src->w || sy >= src->h) continue;
        float w = ((k & 1) ? fx : 1 - fx) * ((k >> 1) ? fy : 1 - fy);
        const unsigned char* s = src->samples + sy * src->stride + sx * 4;
        for (int c = 0; c < 4; c++) acc[c] += s[c] * w;
    }
    for (int c = 0; c < 4; c++) out[c] = clamp_byte(acc[c]);
    fix_premultiplied(out);
}

fz_pixmap* spdf_paint_affine_pixmap(fz_context* ctx, const fz_pixmap* src, fz_matrix m, int w, int h) {
    fz_pixmap* dst = spdf_paint_pixmap_new(ctx, w, h);
    if (!dst) return NULL;
    fz_matrix inv = fz_invert_matrix(m);
    for (int y = 0; y < h; y++) {
        unsigned char* d = dst->samples + y * dst->stride;
        for (int x = 0; x < w; x++, d += 4) {
            fz_point p = fz_transform_point_xy(x + 0.5f, y + 0.5f, inv);
            if (p.x < -1 || p.y < -1 || p.x > src->w + 1 || p.y > src->h + 1) continue;
            sample(src, p.x, p.y, d);
        }
    }
    return dst;
}

fz_pixmap* spdf_paint_rotate_pixmap(fz_context* ctx, const fz_pixmap* src, float degrees) {
    float d = fmodf(degrees, 360.0f);
    if (d < 0) d += 360.0f;
    if (fmodf(d, 90.0f) == 0.0f) return spdf_paint_quarter_pixmap(ctx, src, (int)(d / 90.0f));
    double r = d * M_PI / 180.0;
    int w = (int)ceil(fabs(src->w * cos(r)) + fabs(src->h * sin(r)) - 1e-6);
    int h = (int)ceil(fabs(src->w * sin(r)) + fabs(src->h * cos(r)) - 1e-6);
    fz_matrix m = fz_concat(fz_concat(fz_translate(-src->w / 2.0f, -src->h / 2.0f), fz_rotate(d)),
                            fz_translate(w / 2.0f, h / 2.0f));
    return spdf_paint_affine_pixmap(ctx, src, m, w, h);
}

fz_pixmap* spdf_paint_quarter_pixmap(fz_context* ctx, const fz_pixmap* src, int quarters) {
    quarters = ((quarters % 4) + 4) % 4;
    int W = src->w, H = src->h;
    fz_pixmap* dst = spdf_paint_pixmap_new(ctx, quarters % 2 ? H : W, quarters % 2 ? W : H);
    if (!dst) return NULL;
    for (int y = 0; y < H; y++) {
        const unsigned char* s = src->samples + y * src->stride;
        for (int x = 0; x < W; x++, s += 4) {
            int dx = x, dy = y;
            if (quarters == 1) { dx = H - 1 - y; dy = x; }
            else if (quarters == 2) { dx = W - 1 - x; dy = H - 1 - y; }
            else if (quarters == 3) { dx = y; dy = W - 1 - x; }
            memcpy(dst->samples + dy * dst->stride + dx * 4, s, 4);
        }
    }
    return dst;
}

void spdf_paint_flip_pixmap(fz_pixmap* pix, int horizontal) {
    if (horizontal) {
        for (int y = 0; y < pix->h; y++) {
            unsigned char* row = pix->samples + y * pix->stride;
            for (int a = 0, b = pix->w - 1; a < b; a++, b--) {
                unsigned char t[4];
                memcpy(t, row + a * 4, 4);
                memcpy(row + a * 4, row + b * 4, 4);
                memcpy(row + b * 4, t, 4);
            }
        }
        return;
    }
    size_t n = (size_t)pix->w * 4;
    unsigned char* t = malloc(n);
    if (!t) return;
    for (int a = 0, b = pix->h - 1; a < b; a++, b--) {
        memcpy(t, pix->samples + a * pix->stride, n);
        memcpy(pix->samples + a * pix->stride, pix->samples + b * pix->stride, n);
        memcpy(pix->samples + b * pix->stride, t, n);
    }
    free(t);
}

fz_pixmap* spdf_paint_place_pixmap(fz_context* ctx, const fz_pixmap* src, int w, int h, int dx, int dy,
                                   const unsigned char* fill) {
    fz_pixmap* dst = spdf_paint_pixmap_new(ctx, w, h);
    if (!dst) return NULL;
    if (fill && fill[3])
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) memcpy(dst->samples + y * dst->stride + x * 4, fill, 4);
    int x0 = dx > 0 ? dx : 0, x1 = dx + src->w < w ? dx + src->w : w;
    for (int y = dy > 0 ? dy : 0; y < h && y - dy < src->h && x1 > x0; y++)
        memcpy(dst->samples + y * dst->stride + x0 * 4, src->samples + (y - dy) * src->stride + (x0 - dx) * 4,
               (size_t)(x1 - x0) * 4);
    return dst;
}

void spdf_paint_invert_pixels(fz_pixmap* pix, fz_irect box, const fz_pixmap* mask) {
    box = fz_intersect_irect(box, fz_make_irect(0, 0, pix->w, pix->h));
    for (int y = box.y0; y < box.y1; y++) {
        unsigned char* p = pix->samples + y * pix->stride + box.x0 * 4;
        for (int x = box.x0; x < box.x1; x++, p += 4) {
            int m = spdf_paint_mask_at(mask, x, y);
            if (!m) continue;
            for (int c = 0; c < 3; c++) {
                int inv = p[3] - p[c];
                p[c] = (unsigned char)(p[c] + (inv - p[c]) * m / 255);
            }
        }
    }
}

void spdf_paint_black_white_pixels(fz_pixmap* pix) {
    for (int y = 0; y < pix->h; y++) {
        unsigned char* p = pix->samples + y * pix->stride;
        for (int x = 0; x < pix->w; x++, p += 4) {
            if (!p[3]) continue;
            float a = p[3] / 255.0f;
            float lum = (0.299f * p[0] + 0.587f * p[1] + 0.114f * p[2]) / a;
            unsigned char v = lum >= 128.0f ? p[3] : 0;
            p[0] = p[1] = p[2] = v;
        }
    }
}

void spdf_paint_flatten_onto(fz_pixmap* pix, const unsigned char* fill) {
    for (int y = 0; y < pix->h; y++) {
        unsigned char* p = pix->samples + y * pix->stride;
        for (int x = 0; x < pix->w; x++, p += 4) {
            if (p[3] == 255) continue;
            int keep = 255 - p[3];
            for (int c = 0; c < 4; c++) p[c] = (unsigned char)(p[c] + (fill[c] * keep + 127) / 255);
        }
    }
}
