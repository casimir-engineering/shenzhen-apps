/* Annotate's textured brushes (docs/plans/annotate.md § 2 Brushes): Airbrush, Oil brush, Crayon, Natural pencil and
 * Watercolor brush, the seeded noise they are made of, Watercolor's wet look and the hatching that gives shapes their
 * textured fills. Each is modelled on its Windows Paint namesake:
 *   Airbrush        fine dots sprayed in a disc; one burst per input point, so it builds up where the pointer rests
 *                   and thins out where it moves fast (density by time and speed)
 *   Oil brush       a row of bristles, each with its own width, tone and load of paint; the load runs out along the
 *                   stroke at a different rate per bristle, so long strokes end streaky and broken
 *   Crayon          wax on grainy paper: the paper's grain (fixed to the canvas) stays uncovered, about 40 %
 *   Natural pencil  a thin graphite line with a fine grain, lighter the faster it is drawn
 *   Watercolor      a wobbly soft edge, pigment pooled in a darker rim, a light middle; strokes over each other darken
 * Noise is sampled in stroke space and every random choice comes from the seed, so a replay paints the same pixels.
 * The strokes themselves are walked in spdf_paint_brush_live.c, point by point, so a stroke being drawn shows them. */
#include "spdf_paint_brush_engine.h"

#include <math.h>
#include <string.h>

static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }

/* ---- Noise ---- */

uint32_t spdf_brush_hash(int32_t x, int32_t y, uint32_t seed) {
    uint32_t h = (uint32_t)x * 0x8da6b343u ^ (uint32_t)y * 0xd8163841u ^ (seed + 0x9e3779b9u) * 0xcb1ab31fu;
    h ^= h >> 16, h *= 0x7feb352du, h ^= h >> 15, h *= 0x846ca68bu, h ^= h >> 16;
    return h;
}

float spdf_brush_hash01(int32_t x, int32_t y, uint32_t seed) {
    return (float)(spdf_brush_hash(x, y, seed) >> 8) * (1.0f / 16777216.0f);
}

float spdf_brush_noise(float x, float y, uint32_t seed) {
    float fx = floorf(x), fy = floorf(y), tx = x - fx, ty = y - fy;
    int32_t ix = (int32_t)fx, iy = (int32_t)fy;
    float a = spdf_brush_hash01(ix, iy, seed), b = spdf_brush_hash01(ix + 1, iy, seed);
    float c = spdf_brush_hash01(ix, iy + 1, seed), d = spdf_brush_hash01(ix + 1, iy + 1, seed);
    tx = tx * tx * (3 - 2 * tx), ty = ty * ty * (3 - 2 * ty);
    return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty;
}

float spdf_brush_fbm(float x, float y, uint32_t seed, int octaves) {
    float sum = 0, amp = 1, norm = 0;
    int i;
    for (i = 0; i < octaves; ++i, amp *= 0.5f, x *= 2.03f, y *= 2.03f) {
        sum += spdf_brush_noise(x, y, seed + (uint32_t)i * 101u) * amp;
        norm += amp;
    }
    return norm > 0 ? sum / norm : 0;
}

uint32_t spdf_brush_default_seed(const spdf_paint_point* points, int count) {
    uint32_t h = 2166136261u;
    int i;
    for (i = 0; i < count; ++i)
        h = spdf_brush_hash((int32_t)lrintf(points[i].x * 16), (int32_t)lrintf(points[i].y * 16), h);
    return h;
}

/* ---- Watercolor ---- */

/* Box blur in place (radius r, two passes each way, close to a Gaussian); pixels outside count as empty. */
static int blur(fz_context* ctx, unsigned char* a, int w, int h, int r) {
    int* acc = fz_malloc_no_throw(ctx, (size_t)(w > h ? w : h) * sizeof(int) + sizeof(int));
    unsigned char* line = fz_malloc_no_throw(ctx, (size_t)(w > h ? w : h));
    int pass, x, y, len, stride, i, k;
    if (!acc || !line || r < 1) {
        fz_free(ctx, acc), fz_free(ctx, line);
        return r < 1;
    }
    for (pass = 0; pass < 4; ++pass) {
        int horizontal = pass % 2 == 0, lines = horizontal ? h : w;
        len = horizontal ? w : h, stride = horizontal ? 1 : w;
        for (y = 0; y < lines; ++y) {
            unsigned char* base = horizontal ? a + (size_t)y * w : a + y;
            for (i = 0; i < len; ++i) line[i] = base[(size_t)i * stride];
            acc[0] = 0;
            for (i = 0; i < len; ++i) acc[i + 1] = acc[i] + line[i];
            for (x = 0; x < len; ++x) {
                int lo = x - r < 0 ? 0 : x - r, hi = x + r + 1 > len ? len : x + r + 1;
                k = (acc[hi] - acc[lo]) / (2 * r + 1);
                base[(size_t)x * stride] = (unsigned char)k;
            }
        }
    }
    fz_free(ctx, acc), fz_free(ctx, line);
    return 1;
}

void spdf_brush_wet(fz_context* ctx, spdf_brush_mask* m, float radius, fz_matrix from_device, uint32_t seed) {
    spdf_brush_wet_part(ctx, m, radius, from_device, seed, m->box);
}

void spdf_brush_wet_part(fz_context* ctx, spdf_brush_mask* m, float radius, fz_matrix from_device, uint32_t seed,
                         fz_irect part) {
    size_t count = (size_t)m->w * (size_t)m->h, i;
    int r2 = (int)fmaxf(1, radius * 0.38f);
    fz_irect need = fz_intersect_irect(fz_expand_irect(part, 2 * r2 + 1), m->box); /* what the second blur reads */
    float units = radius * fz_matrix_expansion(from_device);
    unsigned char *body, *spread;
    int x, y;
    if (!m->a || !count) return;
    body = fz_malloc_no_throw(ctx, count), spread = fz_malloc_no_throw(ctx, count);
    if (!body || !spread) {
        fz_free(ctx, body), fz_free(ctx, spread);
        return;
    }
    memcpy(spread, m->a, count);
    blur(ctx, spread, m->w, m->h, (int)fmaxf(1, radius * 0.22f));
    for (y = 0; y < m->h; ++y) /* the wet edge: where the paint spread to, decided by a wobbling threshold */
        for (x = 0; x < m->w; ++x) {
            fz_point s;
            float n;
            i = (size_t)y * m->w + x;
            if (!spread[i] || x + m->box.x0 < need.x0 || x + m->box.x0 >= need.x1 || y + m->box.y0 < need.y0 ||
                y + m->box.y0 >= need.y1) { body[i] = 0; continue; }
            s = fz_transform_point(fz_make_point(m->box.x0 + x + 0.5f, m->box.y0 + y + 0.5f), from_device);
            n = spdf_brush_fbm(s.x / (units * 1.1f + 1), s.y / (units * 1.1f + 1), seed + 31, 2);
            float th = 0.40f + (n - 0.5f) * 0.42f;
            body[i] = (unsigned char)(clampf((spread[i] / 255.0f - th) / 0.09f + 0.5f, 0, 1) * 255 + 0.5f);
        }
    memcpy(spread, body, count);
    blur(ctx, spread, m->w, m->h, r2);
    for (y = 0; y < m->h; ++y) /* pigment pools at the rim; the middle stays light, with a little granulation */
        for (x = 0; x < m->w; ++x) {
            fz_point s;
            float b = body[(size_t)y * m->w + x] / 255.0f, sp = spread[(size_t)y * m->w + x] / 255.0f;
            float rim = clampf((b - sp) * 2.6f, 0, 1);
            float gran;
            if (x + m->box.x0 < part.x0 || x + m->box.x0 >= part.x1 || y + m->box.y0 < part.y0 || y + m->box.y0 >= part.y1)
                continue; /* not asked for: left as it is */
            if (b <= 0) { m->a[(size_t)y * m->w + x] = 0; continue; }
            s = fz_transform_point(fz_make_point(m->box.x0 + x + 0.5f, m->box.y0 + y + 0.5f), from_device);
            gran = 0.86f + 0.14f * spdf_brush_fbm(s.x * 0.55f, s.y * 0.55f, seed + 57, 2);
            m->a[(size_t)y * m->w + x] = (unsigned char)(clampf(b * (0.30f + 0.55f * rim) * gran, 0, 1) * 255 + 0.5f);
        }
    fz_free(ctx, body), fz_free(ctx, spread);
}

/* ---- Hatching for textured fills ---- */

void spdf_brush_hatch(fz_context* ctx, spdf_paint_brush tool, spdf_rect rect, float spacing, uint32_t seed,
                      fz_matrix to_device, spdf_brush_mask* m) {
    /* Oil and marker: back-and-forth strokes across; crayon and pencil: diagonal strokes, as a hand would shade. */
    int diagonal = tool == SPDF_PAINT_BRUSH_CRAYON || tool == SPDF_PAINT_BRUSH_NATURAL_PENCIL, row = 0, k, steps;
    float cx = (rect.x0 + rect.x1) / 2, cy = (rect.y0 + rect.y1) / 2;
    float half = hypotf(rect.x1 - rect.x0, rect.y1 - rect.y0) / 2 + spacing * 2, off;
    fz_point dir = diagonal ? fz_make_point(0.70710678f, -0.70710678f) : fz_make_point(1, 0);
    fz_point across = {-dir.y, dir.x};
    spdf_paint_point pts[256];
    if (spacing < 0.5f) spacing = 0.5f;
    if (!diagonal) half = (rect.x1 - rect.x0) / 2 + spacing * 2;
    steps = (int)clampf(2 * half / 6.0f, 2, 255);
    for (off = -(diagonal ? half : (rect.y1 - rect.y0) / 2 + spacing); off <= (diagonal ? half : (rect.y1 - rect.y0) /
                                                                          2 + spacing); off += spacing, ++row) {
        spdf_brush_job job;
        float dirn = row % 2 ? -1.0f : 1.0f, tilt = diagonal ? 0 : spacing * 0.35f;
        for (k = 0; k <= steps; ++k) {
            float t = (float)k / steps * 2 - 1, along = t * half * dirn;
            pts[k].x = cx + dir.x * along + across.x * (off + tilt * t * dirn);
            pts[k].y = cy + dir.y * along + across.y * (off + tilt * t * dirn);
            pts[k].pressure = 1;
        }
        memset(&job, 0, sizeof(job));
        job.tool = tool, job.points = pts, job.count = steps + 1, job.seed = seed + (uint32_t)row * 7919u;
        job.size = spacing * (tool == SPDF_PAINT_BRUSH_NATURAL_PENCIL ? 1.5f : tool == SPDF_PAINT_BRUSH_MARKER ? 1.9f : 1.45f);
        job.to_device = to_device;
        if (fz_is_empty_irect(fz_intersect_irect(spdf_brush_job_reach(&job), m->box))) continue;
        spdf_brush_render(ctx, &job, m);
    }
}
