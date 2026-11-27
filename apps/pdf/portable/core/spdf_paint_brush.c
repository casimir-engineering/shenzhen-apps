/* Annotate's pixel tools (docs/plans/annotate.md § 2 Tools and Brushes, § 8 Core spdf_paint_brush.c): the brush
 * engine's masks and coverage primitives, the plain nibs (Pencil, Brush, Calligraphy brush 1 and 2, Marker, the
 * erasers' square), and one stroke painted into a raster layer: Pencil hard-edged, every brush antialiased, the
 * Eraser painting transparency (Color 2 on a layer without alpha), the Color Eraser replacing Color 1 with Color 2.
 * The textured brushes are in spdf_paint_brush_tex.c, the paint.stroke handler in spdf_paint_brush_op.c.
 *
 * A stroke never darkens where it crosses itself (its coverage is built first, then laid down once at its opacity);
 * two strokes over each other build up, as paint does. Pixels go into the given raster layer only: never into an
 * object, never into a locked layer (a PDF page). */
#include "spdf_paint_brush_engine.h"

#include <math.h>
#include <string.h>

static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }

int spdf_brush_mask_init(fz_context* ctx, spdf_brush_mask* mask, fz_irect box) {
    memset(mask, 0, sizeof(*mask));
    if (fz_is_empty_irect(box)) return 1;
    mask->box = box;
    mask->w = box.x1 - box.x0;
    mask->h = box.y1 - box.y0;
    mask->a = fz_calloc_no_throw(ctx, (size_t)mask->w * (size_t)mask->h, 1);
    return mask->a != NULL;
}

void spdf_brush_mask_drop(fz_context* ctx, spdf_brush_mask* mask) {
    if (!mask) return;
    fz_free(ctx, mask->a);
    memset(mask, 0, sizeof(*mask));
}

static void put_max(spdf_brush_mask* m, int x, int y, float v) {
    unsigned char* p;
    int q;
    if (x < m->box.x0 || y < m->box.y0 || x >= m->box.x1 || y >= m->box.y1) return;
    q = (int)(clampf(v, 0, 1) * 255.0f + 0.5f);
    p = m->a + (size_t)(y - m->box.y0) * (size_t)m->w + (size_t)(x - m->box.x0);
    if (q > *p) *p = (unsigned char)q;
}

/* ---- Coverage primitives ---- */

void spdf_brush_capsule(spdf_brush_mask* m, fz_point a, float ra, fz_point b, float rb, int hard, float alpha,
                        spdf_brush_shade shade, void* user) {
    float rmax = fmaxf(ra, rb), dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
    int x0 = (int)floorf(fminf(a.x, b.x) - rmax - 1), x1 = (int)ceilf(fmaxf(a.x, b.x) + rmax + 1);
    int y0 = (int)floorf(fminf(a.y, b.y) - rmax - 1), y1 = (int)ceilf(fmaxf(a.y, b.y) + rmax + 1);
    int x, y;
    if (!m->a || rmax <= 0 || alpha <= 0) return;
    if (x0 < m->box.x0) x0 = m->box.x0;
    if (y0 < m->box.y0) y0 = m->box.y0;
    if (x1 > m->box.x1) x1 = m->box.x1;
    if (y1 > m->box.y1) y1 = m->box.y1;
    for (y = y0; y < y1; ++y) {
        float py = y + 0.5f;
        for (x = x0; x < x1; ++x) {
            float px = x + 0.5f, t = 0, cx, cy, d, r, cov;
            if (len2 > 1e-12f) t = clampf(((px - a.x) * dx + (py - a.y) * dy) / len2, 0, 1);
            cx = a.x + t * dx, cy = a.y + t * dy;
            d = hypotf(px - cx, py - cy);
            r = ra + (rb - ra) * t;
            if (hard) cov = d <= r ? 1.0f : 0.0f;
            else cov = clampf(r + 0.5f - d, 0, 1) * fminf(1.0f, 2.0f * r);
            if (cov <= 0) continue;
            if (shade) cov *= shade(user, px, py, t);
            put_max(m, x, y, cov * alpha);
        }
    }
}

void spdf_brush_convex(spdf_brush_mask* m, const fz_point* p, int n, int hard, float alpha, spdf_brush_shade shade,
                       void* user) {
    float nx[16], ny[16], nc[16], area = 0;
    float bx0 = p[0].x, by0 = p[0].y, bx1 = p[0].x, by1 = p[0].y;
    int i, k = 0, x, y, x0, y0, x1, y1;
    if (!m->a || n < 3 || n > 16 || alpha <= 0) return;
    for (i = 0; i < n; ++i) {
        const fz_point *u = &p[i], *v = &p[(i + 1) % n];
        area += u->x * v->y - v->x * u->y;
        bx0 = fminf(bx0, u->x), by0 = fminf(by0, u->y), bx1 = fmaxf(bx1, u->x), by1 = fmaxf(by1, u->y);
    }
    for (i = 0; i < n; ++i) { /* inward unit normals, so the signed distance is positive inside */
        const fz_point *u = &p[i], *v = &p[(i + 1) % n];
        float ex = v->x - u->x, ey = v->y - u->y, len = hypotf(ex, ey);
        if (len < 1e-6f) continue;
        nx[k] = (area > 0 ? -ey : ey) / len;
        ny[k] = (area > 0 ? ex : -ex) / len;
        nc[k] = -(nx[k] * u->x + ny[k] * u->y);
        ++k;
    }
    if (k < 3) return;
    x0 = (int)floorf(bx0 - 1), y0 = (int)floorf(by0 - 1), x1 = (int)ceilf(bx1 + 1), y1 = (int)ceilf(by1 + 1);
    if (x0 < m->box.x0) x0 = m->box.x0;
    if (y0 < m->box.y0) y0 = m->box.y0;
    if (x1 > m->box.x1) x1 = m->box.x1;
    if (y1 > m->box.y1) y1 = m->box.y1;
    for (y = y0; y < y1; ++y) {
        float py = y + 0.5f;
        for (x = x0; x < x1; ++x) {
            float px = x + 0.5f, sd = 1e9f, cov;
            for (i = 0; i < k; ++i) sd = fminf(sd, nx[i] * px + ny[i] * py + nc[i]);
            cov = hard ? (sd >= 0 ? 1.0f : 0.0f) : clampf(sd + 0.5f, 0, 1);
            if (cov <= 0) continue;
            if (shade) cov *= shade(user, px, py, 0.5f);
            put_max(m, x, y, cov * alpha);
        }
    }
}

/* Convex hull (monotone chain) of up to 16 points; returns the hull's size, hull[] in order. */
static int hull_of(fz_point* pts, int n, fz_point* hull) {
    int i, j, k = 0;
    for (i = 1; i < n; ++i) { /* insertion sort by x, then y */
        fz_point v = pts[i];
        for (j = i - 1; j >= 0 && (pts[j].x > v.x || (pts[j].x == v.x && pts[j].y > v.y)); --j) pts[j + 1] = pts[j];
        pts[j + 1] = v;
    }
#define CROSS(o, a, b) (((a).x - (o).x) * ((b).y - (o).y) - ((a).y - (o).y) * ((b).x - (o).x))
    for (i = 0; i < n; ++i) {
        while (k >= 2 && CROSS(hull[k - 2], hull[k - 1], pts[i]) <= 0) --k;
        hull[k++] = pts[i];
    }
    for (i = n - 2, j = k + 1; i >= 0; --i) {
        while (k >= j && CROSS(hull[k - 2], hull[k - 1], pts[i]) <= 0) --k;
        hull[k++] = pts[i];
    }
#undef CROSS
    return k > 1 ? k - 1 : k;
}

/* ---- Plain nibs ---- */

static fz_point dev_point(const spdf_brush_job* job, int i) {
    fz_point p = {job->points[i].x, job->points[i].y};
    return fz_transform_point(p, job->to_device);
}

static float pressure_at(const spdf_brush_job* job, int i) {
    float p = job->points[i].pressure;
    return p > 0 && p <= 1 ? p : 1.0f;
}

/* Round nib; pressure scales a brush's size, never the Pencil's (hard). */
static void render_round(const spdf_brush_job* job, spdf_brush_mask* m, int hard, float alpha) {
    float ex = fz_matrix_expansion(job->to_device), floor_r = hard ? 0.5f : 0.35f;
    int i;
    for (i = 0; i < job->count; ++i) {
        int j = i + 1 < job->count ? i + 1 : i;
        float ra = fmaxf(floor_r, job->size * 0.5f * (hard ? 1 : pressure_at(job, i)) * ex);
        float rb = fmaxf(floor_r, job->size * 0.5f * (hard ? 1 : pressure_at(job, j)) * ex);
        spdf_brush_capsule(m, dev_point(job, i), ra, dev_point(job, j), rb, hard, alpha, NULL, NULL);
        if (job->count > 1 && j == job->count - 1) break;
    }
}

/* Pencil at one pixel: the pixels a line visits, as Paint's pencil (Bresenham). */
static void render_pixel_line(const spdf_brush_job* job, spdf_brush_mask* m) {
    int i;
    for (i = 0; i < job->count; ++i) {
        fz_point a = dev_point(job, i), b = dev_point(job, i + 1 < job->count ? i + 1 : i);
        int x0 = (int)floorf(a.x), y0 = (int)floorf(a.y), x1 = (int)floorf(b.x), y1 = (int)floorf(b.y);
        int dx = abs(x1 - x0), dy = -abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx + dy;
        for (;;) {
            int e2 = 2 * err;  /* both steps test the error from before either is taken, or the line can miss its end */
            put_max(m, x0, y0, 1.0f);
            if (x0 == x1 && y0 == y1) break;
            if (e2 >= dy) err += dy, x0 += sx;
            if (e2 <= dx) err += dx, y0 += sy;
        }
        if (job->count > 1 && i + 2 >= job->count) break;
    }
}

/* A nib that is a box (half extents hu along u, hv along v, in device pixels) swept from point to point: the hull of
 * the two boxes per segment. Calligraphy's flat nib, the Marker's chisel, the erasers' square. */
static void render_box_nib(const spdf_brush_job* job, spdf_brush_mask* m, fz_point u, fz_point v, float hu, float hv,
                           int scale_by_pressure, int hard, float alpha) {
    int i;
    for (i = 0; i < job->count; ++i) {
        int j = i + 1 < job->count ? i + 1 : i, c, n = 0;
        fz_point ends[2] = {dev_point(job, i), dev_point(job, j)}, pts[8], hull[9];
        float pr[2] = {scale_by_pressure ? pressure_at(job, i) : 1, scale_by_pressure ? pressure_at(job, j) : 1};
        for (c = 0; c < 2; ++c) {
            float a = hu * pr[c], b = hv;
            pts[n++] = fz_make_point(ends[c].x + u.x * a + v.x * b, ends[c].y + u.y * a + v.y * b);
            pts[n++] = fz_make_point(ends[c].x + u.x * a - v.x * b, ends[c].y + u.y * a - v.y * b);
            pts[n++] = fz_make_point(ends[c].x - u.x * a + v.x * b, ends[c].y - u.y * a + v.y * b);
            pts[n++] = fz_make_point(ends[c].x - u.x * a - v.x * b, ends[c].y - u.y * a - v.y * b);
        }
        n = hull_of(pts, 8, hull);
        if (n >= 3) spdf_brush_convex(m, hull, n, hard, alpha, NULL, NULL);
        if (job->count > 1 && j == job->count - 1) break;
    }
}

static fz_point unit_vector(fz_matrix m, float x, float y) {
    fz_point v = fz_transform_vector(fz_make_point(x, y), m);
    float len = hypotf(v.x, v.y);
    return len > 1e-6f ? fz_make_point(v.x / len, v.y / len) : fz_make_point(1, 0);
}

static void render_calligraphy(const spdf_brush_job* job, spdf_brush_mask* m, int slope_down) {
    /* The nib's edge as written: brush 1 runs from lower left to upper right (/), brush 2 from upper left (\). */
    float ex = fz_matrix_expansion(job->to_device), k = 0.70710678f;
    fz_point u = unit_vector(job->to_device, k, slope_down ? k : -k), v = fz_make_point(-u.y, u.x);
    float hu = fmaxf(0.5f, job->size * 0.5f * ex), hv = fmaxf(0.5f, job->size * 0.06f * ex);
    render_box_nib(job, m, u, v, hu, hv, 1, 0, 1.0f);
}

static void render_marker(const spdf_brush_job* job, spdf_brush_mask* m) {
    /* Paint's marker: a broad, flat, square-ended tip; one even, see-through coat however often the stroke crosses
     * itself. The coat's strength is in the coverage so shape outlines and fills get the same look. */
    float ex = fz_matrix_expansion(job->to_device), h = fmaxf(0.5f, job->size * 0.5f * ex);
    render_box_nib(job, m, unit_vector(job->to_device, 1, 0), unit_vector(job->to_device, 0, 1), h, h * 0.62f, 1, 0,
                   0.62f);
}

static void render_square(const spdf_brush_job* job, spdf_brush_mask* m) {
    float ex = fz_matrix_expansion(job->to_device), h = fmaxf(0.5f, job->size * 0.5f * ex);
    render_box_nib(job, m, unit_vector(job->to_device, 1, 0), unit_vector(job->to_device, 0, 1), h, h, 0, 1, 1.0f);
}

fz_irect spdf_brush_job_reach(const spdf_brush_job* job) {
    float ex = fz_matrix_expansion(job->to_device), k = 0.5f, x0 = 1e30f, y0 = 1e30f, x1 = -1e30f, y1 = -1e30f, r;
    fz_irect box;
    int i;
    switch (job->tool) {
    case SPDF_PAINT_BRUSH_MARKER: case SPDF_PAINT_BRUSH_ERASER: case SPDF_PAINT_BRUSH_COLOR_ERASER: k = 0.75f; break;
    case SPDF_PAINT_BRUSH_CALLIGRAPHY1: case SPDF_PAINT_BRUSH_CALLIGRAPHY2: k = 0.6f; break;
    case SPDF_PAINT_BRUSH_OIL: case SPDF_PAINT_BRUSH_CRAYON: k = 0.62f; break;
    case SPDF_PAINT_BRUSH_WATERCOLOR: k = 1.25f; break;
    default: break;
    }
    r = job->size * k * ex + (job->tool == SPDF_PAINT_BRUSH_WATERCOLOR ? 8 : 3); /* the wet edge's blur, a small nib's too */
    for (i = 0; i < job->count; ++i) {
        fz_point p = dev_point(job, i);
        x0 = fminf(x0, p.x), y0 = fminf(y0, p.y), x1 = fmaxf(x1, p.x), y1 = fmaxf(y1, p.y);
    }
    if (job->count < 1) return fz_empty_irect;
    box.x0 = (int)floorf(x0 - r), box.y0 = (int)floorf(y0 - r), box.x1 = (int)ceilf(x1 + r), box.y1 = (int)ceilf(y1 + r);
    return box;
}

void spdf_brush_render(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* mask) {
    if (!job || job->count < 1 || !mask->a) return;
    switch (job->tool) {
    case SPDF_PAINT_BRUSH_PENCIL:
        if (job->size * fz_matrix_expansion(job->to_device) <= 1.01f) render_pixel_line(job, mask);
        else render_round(job, mask, 1, 1.0f);
        break;
    case SPDF_PAINT_BRUSH_BRUSH: render_round(job, mask, 0, 1.0f); break;
    case SPDF_PAINT_BRUSH_CALLIGRAPHY1: render_calligraphy(job, mask, 0); break;
    case SPDF_PAINT_BRUSH_CALLIGRAPHY2: render_calligraphy(job, mask, 1); break;
    case SPDF_PAINT_BRUSH_AIRBRUSH: spdf_brush_render_airbrush(ctx, job, mask); break;
    case SPDF_PAINT_BRUSH_OIL: spdf_brush_render_oil(ctx, job, mask); break;
    case SPDF_PAINT_BRUSH_CRAYON: spdf_brush_render_crayon(ctx, job, mask); break;
    case SPDF_PAINT_BRUSH_MARKER: render_marker(job, mask); break;
    case SPDF_PAINT_BRUSH_NATURAL_PENCIL: spdf_brush_render_natural_pencil(ctx, job, mask); break;
    case SPDF_PAINT_BRUSH_WATERCOLOR: spdf_brush_render_watercolor(ctx, job, mask); break;
    case SPDF_PAINT_BRUSH_ERASER: case SPDF_PAINT_BRUSH_COLOR_ERASER: render_square(job, mask); break;
    default: break;
    }
}

/* ---- Laying a stroke into a layer ---- */

static int channel(spdf_paint_color c, int shift) { return (int)((c >> shift) & 0xFF); }

/* The selection mask's value at a raster pixel: 255 inside, 0 outside or where it has no pixels. */
static int selection_at(const fz_pixmap* sel, int x, int y) {
    if (!sel) return 255;
    x -= sel->x, y -= sel->y;
    if (x < 0 || y < 0 || x >= sel->w || y >= sel->h) return 0;
    return sel->samples[(size_t)y * (size_t)sel->stride + (size_t)x * sel->n + (sel->n - 1)];
}

void spdf_brush_lay(fz_pixmap* dest, const spdf_brush_mask* m, fz_irect box, spdf_brush_lay_mode mode,
                    spdf_paint_color color, spdf_paint_color replacement, float opacity, const fz_pixmap* sel) {
    float cr = channel(color, 24), cg = channel(color, 16), cb = channel(color, 8), ca = channel(color, 0) / 255.0f;
    float rr = channel(replacement, 24), rg = channel(replacement, 16), rb = channel(replacement, 8);
    int x, y;
    for (y = box.y0; y < box.y1; ++y) {
        const unsigned char* mrow = m->a + (size_t)(y - m->box.y0) * (size_t)m->w;
        unsigned char* d = dest->samples + (size_t)(y - dest->y) * (size_t)dest->stride;
        for (x = box.x0; x < box.x1; ++x) {
            unsigned char* p = d + (size_t)(x - dest->x) * 4;
            float a = mrow[x - m->box.x0] / 255.0f * opacity * selection_at(sel, x, y) / 255.0f, k;
            if (a <= 0) continue;
            if (mode == SPDF_BRUSH_ERASE) {
                k = 1 - a;
                p[0] = (unsigned char)(p[0] * k + 0.5f), p[1] = (unsigned char)(p[1] * k + 0.5f);
                p[2] = (unsigned char)(p[2] * k + 0.5f), p[3] = (unsigned char)(p[3] * k + 0.5f);
            } else if (mode == SPDF_BRUSH_PAINT) {
                a *= ca, k = 1 - a;
                p[0] = (unsigned char)(cr * a + p[0] * k + 0.5f), p[1] = (unsigned char)(cg * a + p[1] * k + 0.5f);
                p[2] = (unsigned char)(cb * a + p[2] * k + 0.5f), p[3] = (unsigned char)(255 * a + p[3] * k + 0.5f);
            } else if (p[3]) { /* Color Eraser: Color 1 pixels (straight colour close to it) become Color 2 */
                float al = p[3] / 255.0f, sr = p[0] / al, sg = p[1] / al, sb = p[2] / al, w;
                float diff = fmaxf(fabsf(sr - cr), fmaxf(fabsf(sg - cg), fabsf(sb - cb)));
                w = clampf(1 - (diff - 16) / 32, 0, 1) * a;
                if (w <= 0) continue;
                p[0] = (unsigned char)clampf(((sr + (rr - sr) * w) * al) + 0.5f, 0, p[3]);
                p[1] = (unsigned char)clampf(((sg + (rg - sg) * w) * al) + 0.5f, 0, p[3]);
                p[2] = (unsigned char)clampf(((sb + (rb - sb) * w) * al) + 0.5f, 0, p[3]);
            }
        }
    }
}

/* The box of the mask's non-zero pixels inside `within`. */
static fz_irect used_box(const spdf_brush_mask* m, fz_irect within) {
    fz_irect u = fz_empty_irect;
    int x, y;
    within = fz_intersect_irect(within, m->box);
    for (y = within.y0; y < within.y1; ++y) {
        const unsigned char* row = m->a + (size_t)(y - m->box.y0) * (size_t)m->w;
        for (x = within.x0; x < within.x1; ++x) {
            if (!row[x - m->box.x0]) continue;
            if (fz_is_empty_irect(u)) u = fz_make_irect(x, y, x + 1, y + 1);
            else {
                if (x < u.x0) u.x0 = x;
                if (x >= u.x1) u.x1 = x + 1;
                if (y >= u.y1) u.y1 = y + 1;
            }
        }
    }
    return u;
}

spdf_brush_lay_mode spdf_brush_lay_mode_for(const spdf_paint_doc* doc, const spdf_paint_layer* layer,
                                            const spdf_paint_stroke_args* args, spdf_paint_color* color) {
    *color = args->color;
    if (args->tool == SPDF_PAINT_BRUSH_COLOR_ERASER) return SPDF_BRUSH_REPLACE_COLOR;
    if (args->tool != SPDF_PAINT_BRUSH_ERASER) return SPDF_BRUSH_PAINT;
    if (layer->kind == SPDF_PAINT_LAYER_BACKGROUND && !doc->has_alpha) {
        *color = args->color2 | 0xFF;
        return SPDF_BRUSH_PAINT;
    }
    return SPDF_BRUSH_ERASE;
}

spdf_paint_status spdf_paint_brush_lay_mask(spdf_paint_doc* doc, spdf_paint_layer* layer,
                                            const spdf_paint_stroke_args* args, const spdf_brush_mask* mask,
                                            fz_irect box, spdf_rect* damage) {
    float scale = doc->raster_scale > 0 ? (float)doc->raster_scale : 1.0f;
    fz_irect used = used_box(mask, box);
    spdf_paint_color color;
    if (damage) *damage = (spdf_rect){0, 0, 0, 0};
    if (fz_is_empty_irect(used)) return SPDF_PAINT_OK;
    spdf_brush_lay_mode mode = spdf_brush_lay_mode_for(doc, layer, args, &color);
    spdf_paint_history_save_pixels(doc, layer, used);
    spdf_brush_lay(layer->pixels, mask, used, mode, color, args->color2, clampf(args->opacity, 0, 1), args->mask);
    if (damage) *damage = (spdf_rect){used.x0 / scale, used.y0 / scale, used.x1 / scale, used.y1 / scale};
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_brush_stroke(spdf_paint_doc* doc, spdf_paint_layer* layer,
                                          const spdf_paint_stroke_args* args, spdf_rect* damage) {
    fz_context* ctx;
    fz_pixmap* pix;
    spdf_brush_job job;
    spdf_brush_mask mask;
    fz_irect box;
    spdf_paint_status st;
    float scale;
    if (damage) *damage = (spdf_rect){0, 0, 0, 0};
    if (!doc || !layer || !args || !args->points || args->point_count < 1 || args->tool >= SPDF_PAINT_BRUSH_COUNT)
        return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    if (layer->locked || (doc->kind == SPDF_PAINT_DOC_PDF && layer->kind == SPDF_PAINT_LAYER_BACKGROUND))
        return SPDF_PAINT_ERR_PAGE_LOCKED;
    if (layer->kind == SPDF_PAINT_LAYER_OBJECT || !(pix = layer->pixels) || pix->n != 4) return SPDF_PAINT_ERR_FAILED;
    ctx = doc->ctx;
    scale = doc->raster_scale > 0 ? (float)doc->raster_scale : 1.0f;
    memset(&job, 0, sizeof(job));
    job.tool = args->tool, job.points = args->points, job.count = args->point_count;
    job.size = fmaxf(args->size, 0.5f), job.seed = args->seed, job.to_device = fz_scale(scale, scale);
    box = fz_intersect_irect(spdf_brush_job_reach(&job), fz_pixmap_bbox(ctx, pix));
    if (fz_is_empty_irect(box)) return SPDF_PAINT_OK;
    if (!spdf_brush_mask_init(ctx, &mask, box)) return SPDF_PAINT_ERR_NO_MEMORY;
    spdf_brush_render(ctx, &job, &mask);
    st = spdf_paint_brush_lay_mask(doc, layer, args, &mask, box, damage);
    spdf_brush_mask_drop(ctx, &mask);
    return st;
}
