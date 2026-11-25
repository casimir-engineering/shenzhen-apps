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
 * Noise is sampled in stroke space and every random choice comes from the seed, so a replay paints the same pixels. */
#include "spdf_paint_brush_engine.h"

#include <math.h>
#include <string.h>

static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }
static float smooth01(float e0, float e1, float v) {
    float t = clampf((v - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

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

typedef struct rng { uint32_t s; } rng;
static uint32_t rng_next(rng* r) {
    r->s ^= r->s << 13, r->s ^= r->s >> 17, r->s ^= r->s << 5;
    return r->s;
}
static float rng01(rng* r) { return (float)(rng_next(r) >> 8) * (1.0f / 16777216.0f); }
static rng rng_make(uint32_t seed, uint32_t salt) {
    rng r = {spdf_brush_hash((int32_t)seed, (int32_t)salt, 0x51ed270bu) | 1u};
    return r;
}

/* ---- Walking a stroke ---- */

typedef struct sample {
    fz_point p;      /* stroke space */
    float pressure;
    float dist;      /* stroke units from the start */
    float speed;     /* length of the input segment it lies on: the pointer's speed per input event */
    fz_point dir;    /* unit, stroke space */
} sample;

static float pressure_of(const spdf_paint_point* p) { return p->pressure > 0 && p->pressure <= 1 ? p->pressure : 1; }

/* Points every `step` stroke units along the input; NULL when out of memory. A single point gives one sample. */
static sample* resample(fz_context* ctx, const spdf_brush_job* job, float step, int* out_count) {
    float total = 0, dist = 0;
    int i, n = 0, cap;
    sample* s;
    fz_point dir = {1, 0};
    for (i = 1; i < job->count; ++i)
        total += hypotf(job->points[i].x - job->points[i - 1].x, job->points[i].y - job->points[i - 1].y);
    if (step <= 1e-3f) step = 1e-3f;
    if (total / step > 4e6f) step = total / 4e6f;
    cap = (int)(total / step) + job->count + 2;
    s = fz_malloc_no_throw(ctx, (size_t)cap * sizeof(sample));
    if (!s) return NULL;
    s[n++] = (sample){{job->points[0].x, job->points[0].y}, pressure_of(&job->points[0]), 0, 0, dir};
    for (i = 1; i < job->count; ++i) {
        const spdf_paint_point *a = &job->points[i - 1], *b = &job->points[i];
        float len = hypotf(b->x - a->x, b->y - a->y), at = step - fmodf(dist, step);
        if (len < 1e-6f) continue;
        dir = fz_make_point((b->x - a->x) / len, (b->y - a->y) / len);
        if (n == 1) s[0].dir = dir, s[0].speed = len;
        for (; at <= len && n < cap - 1; at += step) {
            float t = at / len;
            s[n++] = (sample){{a->x + (b->x - a->x) * t, a->y + (b->y - a->y) * t},
                              pressure_of(a) + (pressure_of(b) - pressure_of(a)) * t, dist + at, len, dir};
        }
        dist += len;
    }
    if (job->count > 1 && n < cap) { /* the stroke ends where the pointer stopped */
        const spdf_paint_point* e = &job->points[job->count - 1];
        float speed = n > 1 ? s[n - 1].speed : 0;
        s[n++] = (sample){{e->x, e->y}, pressure_of(e), dist, speed, dir};
    }
    *out_count = n;
    return s;
}

static fz_point to_dev(const spdf_brush_job* job, fz_point p) { return fz_transform_point(p, job->to_device); }

static void put_over(spdf_brush_mask* m, int x, int y, float v) {
    unsigned char* p;
    float cur;
    if (x < m->box.x0 || y < m->box.y0 || x >= m->box.x1 || y >= m->box.y1 || v <= 0) return;
    p = m->a + (size_t)(y - m->box.y0) * (size_t)m->w + (size_t)(x - m->box.x0);
    cur = *p / 255.0f;
    *p = (unsigned char)(clampf(cur + v * (1 - cur), 0, 1) * 255.0f + 0.5f);
}

/* ---- Airbrush ---- */

static void spray_dot(spdf_brush_mask* m, fz_point c, float r, float alpha) {
    int x, y, x0 = (int)floorf(c.x - r - 1), x1 = (int)ceilf(c.x + r + 1);
    int y0 = (int)floorf(c.y - r - 1), y1 = (int)ceilf(c.y + r + 1);
    for (y = y0; y < y1; ++y)
        for (x = x0; x < x1; ++x) {
            float d = hypotf(x + 0.5f - c.x, y + 0.5f - c.y), cov = clampf(r + 0.5f - d, 0, 1) * fminf(1, 2 * r);
            if (cov > 0) put_over(m, x, y, cov * alpha);
        }
}

void spdf_brush_render_airbrush(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m) {
    float ex = fz_matrix_expansion(job->to_device), R = fmaxf(job->size * 0.5f, 0.5f);
    float dots = clampf(0.55f * R * R, 6, 900), dot_r = fmaxf(0.5f, 0.5f * ex);
    rng r = rng_make(job->seed, 1);
    int i;
    (void)ctx;
    for (i = 0; i < job->count; ++i) { /* one burst per input point, shared out along the way from the last one */
        const spdf_paint_point *p = &job->points[i], *q = i ? &job->points[i - 1] : p;
        float len = hypotf(p->x - q->x, p->y - q->y), alpha = 0.42f * pressure_of(p);
        int parts = len > R * 0.5f ? (int)ceilf(len / (R * 0.5f)) : 1, k, d;
        if (parts > 400) parts = 400;
        for (k = 0; k < parts; ++k) {
            float t = (float)(k + 1) / parts;
            fz_point c = {q->x + (p->x - q->x) * t, q->y + (p->y - q->y) * t};
            int count = (int)fmaxf(1, dots / parts + rng01(&r));
            for (d = 0; d < count; ++d) {
                float rad = R * powf(rng01(&r), 0.62f), ang = rng01(&r) * 6.2831853f;
                fz_point at = {c.x + rad * cosf(ang), c.y + rad * sinf(ang)};
                spray_dot(m, to_dev(job, at), dot_r * (0.7f + 0.6f * rng01(&r)), alpha);
            }
        }
    }
}

/* ---- Oil brush ---- */

void spdf_brush_render_oil(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m) {
    enum { MAX_BRISTLES = 48 };
    float ex = fz_matrix_expansion(job->to_device), W = fmaxf(job->size, 1.0f);
    float off[MAX_BRISTLES], rad[MAX_BRISTLES], load[MAX_BRISTLES], runout[MAX_BRISTLES], tone[MAX_BRISTLES];
    fz_point prev[MAX_BRISTLES], nrm = {0, 1};
    int nb = (int)clampf(W / 1.6f + 3, 4, MAX_BRISTLES), b, i, n = 0;
    rng r = rng_make(job->seed, 2);
    sample* s;
    for (b = 0; b < nb; ++b) {
        off[b] = ((b + 0.5f) / nb - 0.5f) * W * 0.9f + (rng01(&r) - 0.5f) * (W / nb) * 0.6f;
        rad[b] = fmaxf(W / nb * (0.55f + 0.4f * rng01(&r)), 0.45f / ex);
        load[b] = 0.78f + 0.22f * rng01(&r);
        runout[b] = (job->steady ? 1e9f : 240 + 14 * W) * (0.55f + rng01(&r));
        tone[b] = 0.80f + 0.20f * rng01(&r);
    }
    s = resample(ctx, job, fmaxf(0.5f / ex, W / nb * 0.45f), &n);
    if (!s) return;
    for (i = 0; i < n; ++i) {
        fz_point want = {-s[i].dir.y, s[i].dir.x};
        if (i == 0) nrm = want;
        else { /* the bristles turn with the stroke, smoothly */
            float nx = nrm.x * 0.8f + want.x * 0.2f, ny = nrm.y * 0.8f + want.y * 0.2f, len = hypotf(nx, ny);
            if (len > 1e-4f) nrm = fz_make_point(nx / len, ny / len);
        }
        for (b = 0; b < nb; ++b) {
            float o = off[b] * (0.55f + 0.45f * s[i].pressure), l = load[b] * expf(-s[i].dist / runout[b]);
            float gap = spdf_brush_noise(s[i].dist * 0.18f / fmaxf(rad[b], 0.3f), b * 13.7f, job->seed);
            float a = tone[b] * clampf(l * 1.35f, 0, 1) * (0.86f + 0.14f * spdf_brush_noise(s[i].dist * 0.07f, b * 5.3f,
                                                                                               job->seed + 9));
            fz_point at = to_dev(job, fz_make_point(s[i].p.x + nrm.x * o, s[i].p.y + nrm.y * o));
            if (l < 0.5f) a *= smooth01(0.0f, 0.35f, (l - 0.12f) / 0.38f - gap + 0.5f); /* drying out: breaks up */
            if (i > 0 && a > 0.01f) spdf_brush_capsule(m, prev[b], rad[b] * ex, at, rad[b] * ex, 0, a, NULL, NULL);
            else if (n == 1) spdf_brush_capsule(m, at, rad[b] * ex, at, rad[b] * ex, 0, a, NULL, NULL);
            prev[b] = at;
        }
    }
    fz_free(ctx, s);
}

/* ---- Crayon and natural pencil: a nib whose cover is decided by the paper's grain ---- */

/* The paper's height at a stroke-space point, 0-1: graphite catches on a fine, even tooth; wax only on the tops of a
 * coarser one, so its valleys stay white in clumps. Fixed to the canvas (or the shape), like real paper. */
static float paper(fz_point s, int pencil) {
    if (pencil)
        return 0.35f * spdf_brush_hash01((int32_t)floorf(s.x * 2.2f), (int32_t)floorf(s.y * 2.2f), 77) +
               0.65f * spdf_brush_fbm(s.x * 0.9f, s.y * 0.9f, 78, 2);
    return 0.78f * spdf_brush_fbm(s.x * 0.30f, s.y * 0.30f, 91, 3) +
           0.22f * spdf_brush_hash01((int32_t)floorf(s.x * 0.9f), (int32_t)floorf(s.y * 0.9f), 92);
}

/* The nib's cover first (outer: the whole nib, at the pencil's strength; inner: the crayon's middle, pressed harder),
 * then the paper decides, once per pixel. */
static void render_grainy(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m, int pencil) {
    float ex = fz_matrix_expansion(job->to_device), half = pencil ? fmaxf(job->size * 0.28f, 0.45f)
                                                                     : fmaxf(job->size * 0.5f, 0.5f);
    fz_matrix from_device = fz_invert_matrix(job->to_device);
    spdf_brush_mask outer, inner;
    fz_point last = {0, 0};
    fz_rect used = fz_empty_rect;
    float last_r = 0;
    int i, n = 0, x, y;
    sample* s;
    if (!spdf_brush_mask_init(ctx, &outer, m->box)) return;
    if (!pencil && !spdf_brush_mask_init(ctx, &inner, m->box)) {
        spdf_brush_mask_drop(ctx, &outer);
        return;
    }
    s = resample(ctx, job, fmaxf(0.5f / ex, half * 0.5f), &n);
    for (i = 0; s && i < n; ++i) {
        fz_point at = to_dev(job, s[i].p);
        float wob = 0.86f + 0.18f * spdf_brush_noise(s[i].dist / (half * 1.7f + 0.5f), 3.1f, job->seed);
        float r = fmaxf(pencil ? 0.45f : 0.5f, half * s[i].pressure * wob * ex);
        float strength = pencil ? 0.30f + 0.62f / (1 + s[i].speed / 12) : 0.96f; /* pencil: lighter when fast */
        spdf_brush_capsule(&outer, i ? last : at, i ? last_r : r, at, r, 0, strength, NULL, NULL);
        if (!pencil) spdf_brush_capsule(&inner, i ? last : at, (i ? last_r : r) * 0.6f, at, r * 0.6f, 0, 1, NULL, NULL);
        used = fz_include_point_in_rect(used, fz_make_point(at.x - r - 1, at.y - r - 1));
        used = fz_include_point_in_rect(used, fz_make_point(at.x + r + 1, at.y + r + 1));
        last = at, last_r = r;
    }
    fz_free(ctx, s);
    {
        fz_irect box = fz_intersect_irect(fz_round_rect(used), m->box);
        for (y = box.y0; y < box.y1; ++y)
            for (x = box.x0; x < box.x1; ++x) {
                size_t k = (size_t)(y - m->box.y0) * m->w + (size_t)(x - m->box.x0);
                float a = outer.a[k] / 255.0f, b = pencil ? 0 : inner.a[k] / 255.0f, h, v;
                if (a <= 0 && b <= 0) continue;
                h = paper(fz_transform_point(fz_make_point(x + 0.5f, y + 0.5f), from_device), pencil);
                if (pencil) v = a * (0.45f + 0.55f * smooth01(0.25f, 0.65f, h));
                else v = fmaxf(a * smooth01(0.48f, 0.58f, h), b * 0.96f * smooth01(0.38f, 0.48f, h));
                if (v * 255 > m->a[k]) m->a[k] = (unsigned char)(fminf(v, 1) * 255 + 0.5f);
            }
    }
    spdf_brush_mask_drop(ctx, &outer);
    if (!pencil) spdf_brush_mask_drop(ctx, &inner);
}

void spdf_brush_render_crayon(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m) {
    render_grainy(ctx, job, m, 0);
}

void spdf_brush_render_natural_pencil(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m) {
    render_grainy(ctx, job, m, 1);
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
    size_t count = (size_t)m->w * (size_t)m->h, i;
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
            if (!spread[i]) { body[i] = 0; continue; }
            s = fz_transform_point(fz_make_point(m->box.x0 + x + 0.5f, m->box.y0 + y + 0.5f), from_device);
            n = spdf_brush_fbm(s.x / (units * 1.1f + 1), s.y / (units * 1.1f + 1), seed + 31, 2);
            float th = 0.40f + (n - 0.5f) * 0.42f;
            body[i] = (unsigned char)(clampf((spread[i] / 255.0f - th) / 0.09f + 0.5f, 0, 1) * 255 + 0.5f);
        }
    memcpy(spread, body, count);
    blur(ctx, spread, m->w, m->h, (int)fmaxf(1, radius * 0.38f));
    for (y = 0; y < m->h; ++y) /* pigment pools at the rim; the middle stays light, with a little granulation */
        for (x = 0; x < m->w; ++x) {
            fz_point s;
            float b = body[(size_t)y * m->w + x] / 255.0f, sp = spread[(size_t)y * m->w + x] / 255.0f;
            float rim = clampf((b - sp) * 2.6f, 0, 1);
            float gran;
            if (b <= 0) { m->a[(size_t)y * m->w + x] = 0; continue; }
            s = fz_transform_point(fz_make_point(m->box.x0 + x + 0.5f, m->box.y0 + y + 0.5f), from_device);
            gran = 0.86f + 0.14f * spdf_brush_fbm(s.x * 0.55f, s.y * 0.55f, seed + 57, 2);
            m->a[(size_t)y * m->w + x] = (unsigned char)(clampf(b * (0.30f + 0.55f * rim) * gran, 0, 1) * 255 + 0.5f);
        }
    fz_free(ctx, body), fz_free(ctx, spread);
}

void spdf_brush_render_watercolor(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* out) {
    /* Its own mask, so the wet edge is worked on this stroke alone, then merged (max) with what is there. */
    float ex = fz_matrix_expansion(job->to_device), R = fmaxf(job->size * 0.5f, 0.5f);
    fz_point last = {0, 0};
    float last_r = 0;
    int i, n = 0;
    size_t k, count;
    spdf_brush_mask mm, *m = &mm;
    sample* s;
    if (!spdf_brush_mask_init(ctx, m, out->box)) return;
    s = resample(ctx, job, fmaxf(0.5f / ex, R * 0.3f), &n);
    if (!s) {
        spdf_brush_mask_drop(ctx, m);
        return;
    }
    for (i = 0; i < n; ++i) {
        fz_point at = to_dev(job, s[i].p);
        float r = fmaxf(0.5f, R * s[i].pressure * (0.88f + 0.24f * spdf_brush_noise(s[i].dist / (R * 1.6f), 7.7f,
                                                                                   job->seed)) * ex);
        spdf_brush_capsule(m, i ? last : at, i ? last_r : r, at, r, 0, 1, NULL, NULL);
        last = at, last_r = r;
    }
    fz_free(ctx, s);
    spdf_brush_wet(ctx, m, R * ex, fz_invert_matrix(job->to_device), job->seed);
    count = (size_t)m->w * (size_t)m->h;
    for (k = 0; k < count; ++k)
        if (m->a[k] > out->a[k]) out->a[k] = m->a[k];
    spdf_brush_mask_drop(ctx, m);
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
