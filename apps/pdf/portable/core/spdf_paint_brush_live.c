/* A brush stroke drawn point by point (spdf_paint_brush_engine.h, "spdf_brush_run"): what a stroke being drawn shows
 * costs only its new part, and the whole stroke at once (spdf_brush_render) is the same run fed every point, so the
 * stroke shown while the button is held is the stroke the release paints, pixel for pixel.
 *
 * The plain nibs (Pencil, Brush, Calligraphy, Marker, the erasers) draw each new segment as the whole stroke does.
 * The Airbrush sprays one burst per point from one random sequence, kept from point to point. Oil, Crayon, Natural
 * pencil and Watercolor walk the stroke in even steps: every step taken is final (`committed`), but the stroke as it
 * would end at the last point (its last bit, from the last step to the point, and Watercolor's wet edge around it) is
 * drawn again at each show, into `shown` only. Textures: spdf_paint_brush_tex.c. */
#include "spdf_paint_brush_engine.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_BRISTLES = 48 };

static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }
static float smooth01(float e0, float e1, float v) {
    float t = clampf((v - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}
static float pressure_of(const spdf_paint_point* p) { return p->pressure > 0 && p->pressure <= 1 ? p->pressure : 1; }
static fz_point to_dev(const spdf_brush_job* job, fz_point p) { return fz_transform_point(p, job->to_device); }
static fz_irect around(fz_point c, float r) {
    return fz_make_irect((int)floorf(c.x - r), (int)floorf(c.y - r), (int)ceilf(c.x + r), (int)ceilf(c.y + r));
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

typedef struct sample {
    fz_point p;      /* stroke space */
    float pressure;
    float dist;      /* stroke units from the start */
    float speed;     /* length of the input segment it lies on: the pointer's speed per input event */
    fz_point dir;    /* unit, stroke space */
} sample;

/* What a brush that walks the stroke carries from one step to the next. */
typedef struct walk {
    int i;                          /* steps taken */
    fz_point nrm, prev[MAX_BRISTLES]; /* Oil: the bristles' direction and where each was */
    fz_point last;                  /* Crayon, pencil, Watercolor: the nib's last place (device) and size */
    float last_r;
} walk;

struct spdf_brush_run {
    spdf_brush_job job;      /* its points are not used: they come through spdf_brush_run_add */
    fz_irect box;
    float ex;
    int count;               /* points so far */
    spdf_paint_point last;   /* the last of them */
    /* Walking (Oil, Crayon, Natural pencil, Watercolor): a step every `step` units along the input. */
    float step, dist, speed; /* how far the input has gone; the last step's speed */
    fz_point dir;            /* the last segment's direction */
    sample s0;               /* the first step: takes the direction and speed of the segment the second lies on */
    int walked;              /* steps handed to the brush, s0 included */
    walk w;
    /* Airbrush */
    rng r;
    float R, dots, dot_r;
    /* Oil */
    int nb;
    float off[MAX_BRISTLES], rad[MAX_BRISTLES], load[MAX_BRISTLES], runout[MAX_BRISTLES], tone[MAX_BRISTLES];
    /* Crayon and pencil: the nib's cover before the paper decides (outer, inner); Watercolor: its coverage before the
     * wet look (outer). */
    spdf_brush_mask outer, inner;
    float half;
    int pencil;
    fz_irect pending;        /* committed pixels changed since the last show */
    fz_irect tail;           /* what the last show drew beyond `committed` */
};

static int walks(spdf_paint_brush tool) {
    return tool == SPDF_PAINT_BRUSH_OIL || tool == SPDF_PAINT_BRUSH_CRAYON || tool == SPDF_PAINT_BRUSH_NATURAL_PENCIL ||
           tool == SPDF_PAINT_BRUSH_WATERCOLOR;
}

static fz_irect join(fz_irect a, fz_irect b) {
    if (fz_is_empty_irect(a)) return b;
    if (fz_is_empty_irect(b)) return a;
    return fz_make_irect(a.x0 < b.x0 ? a.x0 : b.x0, a.y0 < b.y0 ? a.y0 : b.y0, a.x1 > b.x1 ? a.x1 : b.x1,
                         a.y1 > b.y1 ? a.y1 : b.y1);
}
static void grow(fz_irect* into, fz_irect r) { *into = join(*into, r); }

static void copy_box(spdf_brush_mask* to, const spdf_brush_mask* from, fz_irect box) {
    box = fz_intersect_irect(fz_intersect_irect(box, to->box), from->box);
    if (to == from || fz_is_empty_irect(box)) return;
    for (int y = box.y0; y < box.y1; ++y)
        memcpy(to->a + (size_t)(y - to->box.y0) * to->w + (box.x0 - to->box.x0),
               from->a + (size_t)(y - from->box.y0) * from->w + (box.x0 - from->box.x0), (size_t)(box.x1 - box.x0));
}

/* ---- Airbrush: fine dots sprayed in a disc, one burst per point, shared out along the way from the last one ---- */

static void put_over(spdf_brush_mask* m, int x, int y, float v) {
    unsigned char* p;
    float cur;
    if (x < m->box.x0 || y < m->box.y0 || x >= m->box.x1 || y >= m->box.y1 || v <= 0) return;
    p = m->a + (size_t)(y - m->box.y0) * (size_t)m->w + (size_t)(x - m->box.x0);
    cur = *p / 255.0f;
    *p = (unsigned char)(clampf(cur + v * (1 - cur), 0, 1) * 255.0f + 0.5f);
}

static void spray_dot(spdf_brush_mask* m, fz_point c, float r, float alpha) {
    int x, y, x0 = (int)floorf(c.x - r - 1), x1 = (int)ceilf(c.x + r + 1);
    int y0 = (int)floorf(c.y - r - 1), y1 = (int)ceilf(c.y + r + 1);
    for (y = y0; y < y1; ++y)
        for (x = x0; x < x1; ++x) {
            float d = hypotf(x + 0.5f - c.x, y + 0.5f - c.y), cov = clampf(r + 0.5f - d, 0, 1) * fminf(1, 2 * r);
            if (cov > 0) put_over(m, x, y, cov * alpha);
        }
}

static fz_irect spray(spdf_brush_run* run, const spdf_paint_point* q, const spdf_paint_point* p, spdf_brush_mask* m) {
    float len = hypotf(p->x - q->x, p->y - q->y), alpha = 0.42f * pressure_of(p), R = run->R;
    int parts = len > R * 0.5f ? (int)ceilf(len / (R * 0.5f)) : 1, k, d;
    fz_irect box = fz_empty_irect;
    if (parts > 400) parts = 400;
    for (k = 0; k < parts; ++k) {
        float t = (float)(k + 1) / parts;
        fz_point c = {q->x + (p->x - q->x) * t, q->y + (p->y - q->y) * t};
        int count = (int)fmaxf(1, run->dots / parts + rng01(&run->r));
        for (d = 0; d < count; ++d) {
            float rad = R * powf(rng01(&run->r), 0.62f), ang = rng01(&run->r) * 6.2831853f;
            fz_point at = to_dev(&run->job, fz_make_point(c.x + rad * cosf(ang), c.y + rad * sinf(ang)));
            float r = run->dot_r * (0.7f + 0.6f * rng01(&run->r));
            spray_dot(m, at, r, alpha);
            grow(&box, around(at, r + 2));
        }
    }
    return box;
}

/* ---- The brushes that walk the stroke ---- */

/* Oil: a row of bristles, each with its own width, tone and load of paint that runs out along the stroke. `alone`:
 * the stroke is this one step (a click). Returns the box drawn. */
static fz_irect oil_step(spdf_brush_run* run, walk* w, const sample* s, int alone, spdf_brush_mask* m) {
    const spdf_brush_job* job = &run->job;
    float ex = run->ex;
    fz_point want = {-s->dir.y, s->dir.x};
    fz_irect box = fz_empty_irect;
    if (w->i == 0) w->nrm = want;
    else { /* the bristles turn with the stroke, smoothly */
        float nx = w->nrm.x * 0.8f + want.x * 0.2f, ny = w->nrm.y * 0.8f + want.y * 0.2f, len = hypotf(nx, ny);
        if (len > 1e-4f) w->nrm = fz_make_point(nx / len, ny / len);
    }
    for (int b = 0; b < run->nb; ++b) {
        float o = run->off[b] * (0.55f + 0.45f * s->pressure), l = run->load[b] * expf(-s->dist / run->runout[b]);
        float gap = spdf_brush_noise(s->dist * 0.18f / fmaxf(run->rad[b], 0.3f), b * 13.7f, job->seed);
        float a = run->tone[b] * clampf(l * 1.35f, 0, 1) *
                  (0.86f + 0.14f * spdf_brush_noise(s->dist * 0.07f, b * 5.3f, job->seed + 9));
        fz_point at = to_dev(job, fz_make_point(s->p.x + w->nrm.x * o, s->p.y + w->nrm.y * o));
        float r = run->rad[b] * ex;
        if (l < 0.5f) a *= smooth01(0.0f, 0.35f, (l - 0.12f) / 0.38f - gap + 0.5f); /* drying out: breaks up */
        if (w->i > 0 && a > 0.01f) {
            spdf_brush_capsule(m, w->prev[b], r, at, r, 0, a, NULL, NULL);
            grow(&box, join(around(w->prev[b], r + 2), around(at, r + 2)));
        } else if (alone) {
            spdf_brush_capsule(m, at, r, at, r, 0, a, NULL, NULL);
            grow(&box, around(at, r + 2));
        }
        w->prev[b] = at;
    }
    w->i++;
    return box;
}

/* Crayon, Natural pencil and Watercolor: where the nib is at a step (device) and its radius. */
static void nib(const spdf_brush_run* run, const sample* s, fz_point* at, float* r, float* strength) {
    const spdf_brush_job* job = &run->job;
    *at = to_dev(job, s->p);
    if (job->tool == SPDF_PAINT_BRUSH_WATERCOLOR) {
        float R = run->R;
        *r = fmaxf(0.5f, R * s->pressure * (0.88f + 0.24f * spdf_brush_noise(s->dist / (R * 1.6f), 7.7f, job->seed)) *
                             run->ex);
        return;
    }
    float half = run->half, wob = 0.86f + 0.18f * spdf_brush_noise(s->dist / (half * 1.7f + 0.5f), 3.1f, job->seed);
    *r = fmaxf(run->pencil ? 0.45f : 0.5f, half * s->pressure * wob * run->ex);
    *strength = run->pencil ? 0.30f + 0.62f / (1 + s->speed / 12) : 0.96f; /* pencil: lighter when fast */
}

/* The paper's height at a stroke-space point, 0-1: graphite catches on a fine, even tooth; wax only on the tops of a
 * coarser one, so its valleys stay white in clumps. Fixed to the canvas (or the shape), like real paper. */
static float paper(fz_point s, int pencil) {
    if (pencil)
        return 0.35f * spdf_brush_hash01((int32_t)floorf(s.x * 2.2f), (int32_t)floorf(s.y * 2.2f), 77) +
               0.65f * spdf_brush_fbm(s.x * 0.9f, s.y * 0.9f, 78, 2);
    return 0.78f * spdf_brush_fbm(s.x * 0.30f, s.y * 0.30f, 91, 3) +
           0.22f * spdf_brush_hash01((int32_t)floorf(s.x * 0.9f), (int32_t)floorf(s.y * 0.9f), 92);
}

/* The nib's cover (outer: the whole nib, at the pencil's strength; inner: the crayon's middle, pressed harder), then
 * the paper decides, per pixel, into m (kept where m is already darker). */
static void grain(const spdf_brush_run* run, const spdf_brush_mask* outer, const spdf_brush_mask* inner, fz_irect box,
                  spdf_brush_mask* m) {
    fz_matrix from_device = fz_invert_matrix(run->job.to_device);
    box = fz_intersect_irect(box, m->box);
    for (int y = box.y0; y < box.y1; ++y)
        for (int x = box.x0; x < box.x1; ++x) {
            size_t ko = (size_t)(y - outer->box.y0) * outer->w + (size_t)(x - outer->box.x0);
            size_t k = (size_t)(y - m->box.y0) * m->w + (size_t)(x - m->box.x0);
            float a = outer->a[ko] / 255.0f, b = run->pencil ? 0 : inner->a[ko] / 255.0f, h, v;
            if (a <= 0 && b <= 0) continue;
            h = paper(fz_transform_point(fz_make_point(x + 0.5f, y + 0.5f), from_device), run->pencil);
            if (run->pencil) v = a * (0.45f + 0.55f * smooth01(0.25f, 0.65f, h));
            else v = fmaxf(a * smooth01(0.48f, 0.58f, h), b * 0.96f * smooth01(0.38f, 0.48f, h));
            if (v * 255 > m->a[k]) m->a[k] = (unsigned char)(fminf(v, 1) * 255 + 0.5f);
        }
}

/* One step of a nib brush into its cover (outer, inner); returns the box it reaches. */
static fz_irect cover_step(spdf_brush_run* run, walk* w, const sample* s, spdf_brush_mask* outer, spdf_brush_mask* inner) {
    fz_point at;
    float r, strength = 1;
    nib(run, s, &at, &r, &strength);
    int wet = run->job.tool == SPDF_PAINT_BRUSH_WATERCOLOR, first = w->i == 0;
    spdf_brush_capsule(outer, first ? at : w->last, first ? r : w->last_r, at, r, 0, wet ? 1 : strength, NULL, NULL);
    if (!wet && !run->pencil)
        spdf_brush_capsule(inner, first ? at : w->last, (first ? r : w->last_r) * 0.6f, at, r * 0.6f, 0, 1, NULL, NULL);
    fz_irect box = around(at, r + 1);
    if (!first) box = join(box, around(w->last, w->last_r + 1));
    w->last = at, w->last_r = r, w->i++;
    return box;
}

/* A step taken for good. */
static void commit_step(spdf_brush_run* run, const sample* s, spdf_brush_mask* committed) {
    fz_irect box;
    if (run->job.tool == SPDF_PAINT_BRUSH_OIL) box = oil_step(run, &run->w, s, 0, committed);
    else {
        box = cover_step(run, &run->w, s, &run->outer, &run->inner);
        if (run->job.tool != SPDF_PAINT_BRUSH_WATERCOLOR) grain(run, &run->outer, &run->inner, box, committed);
    }
    grow(&run->pending, fz_intersect_irect(box, run->box));
}

/* Resampling, as the whole stroke is walked: a step every `step` units, the first point a step of its own. */
static void walk_to(spdf_brush_run* run, const spdf_paint_point* a, const spdf_paint_point* b, spdf_brush_mask* m) {
    float len = hypotf(b->x - a->x, b->y - a->y), at;
    if (len < 1e-6f) return;
    run->dir = fz_make_point((b->x - a->x) / len, (b->y - a->y) / len);
    if (run->walked == 0) run->s0.dir = run->dir, run->s0.speed = len;
    for (at = run->step - fmodf(run->dist, run->step); at <= len; at += run->step) {
        float t = at / len;
        sample s = {{a->x + (b->x - a->x) * t, a->y + (b->y - a->y) * t},
                    pressure_of(a) + (pressure_of(b) - pressure_of(a)) * t, run->dist + at, len, run->dir};
        if (run->walked == 0) commit_step(run, &run->s0, m), run->walked = 1;
        commit_step(run, &s, m);
        run->walked++;
        run->speed = len;
    }
    run->dist += len;
}

/* The steps still to come if the stroke ended here: s0 when nothing was walked yet, and the last point. */
static int tail_steps(const spdf_brush_run* run, sample out[2]) {
    int n = 0;
    if (run->walked == 0) out[n++] = run->s0;
    if (run->count > 1)
        out[n++] = (sample){{run->last.x, run->last.y}, pressure_of(&run->last), run->dist,
                            run->walked > 1 ? run->speed : 0, run->dir};
    return n;
}

/* What the tail's steps of a nib brush cover: the nib where it is now, and where each step takes it. */
static fz_irect tail_reach(const spdf_brush_run* run, const sample* tail, int n) {
    fz_irect reach = run->w.i > 0 ? around(run->w.last, run->w.last_r + 1) : fz_empty_irect;
    for (int i = 0; i < n; ++i) {
        fz_point at;
        float r, strength;
        nib(run, &tail[i], &at, &r, &strength);
        grow(&reach, around(at, r + 1));
    }
    return reach;
}

/* ---- The run ---- */

spdf_brush_run* spdf_brush_run_new(fz_context* ctx, const spdf_brush_job* job, fz_irect box) {
    spdf_brush_run* run = fz_calloc_no_throw(ctx, 1, sizeof(*run));
    if (!run) return NULL;
    run->job = *job, run->job.points = NULL, run->job.count = 0;
    run->box = box, run->ex = fz_matrix_expansion(job->to_device);
    run->pending = run->tail = fz_empty_irect;
    float ex = run->ex, W = fmaxf(job->size, 1.0f);
    run->R = fmaxf(job->size * 0.5f, 0.5f);
    switch (job->tool) {
    case SPDF_PAINT_BRUSH_AIRBRUSH:
        run->dots = clampf(0.55f * run->R * run->R, 6, 900), run->dot_r = fmaxf(0.5f, 0.5f * ex);
        run->r = rng_make(job->seed, 1);
        break;
    case SPDF_PAINT_BRUSH_OIL: {
        rng r = rng_make(job->seed, 2);
        run->nb = (int)clampf(W / 1.6f + 3, 4, MAX_BRISTLES);
        for (int b = 0; b < run->nb; ++b) {
            run->off[b] = ((b + 0.5f) / run->nb - 0.5f) * W * 0.9f + (rng01(&r) - 0.5f) * (W / run->nb) * 0.6f;
            run->rad[b] = fmaxf(W / run->nb * (0.55f + 0.4f * rng01(&r)), 0.45f / ex);
            run->load[b] = 0.78f + 0.22f * rng01(&r);
            run->runout[b] = (job->steady ? 1e9f : 240 + 14 * W) * (0.55f + rng01(&r));
            run->tone[b] = 0.80f + 0.20f * rng01(&r);
        }
        run->step = fmaxf(0.5f / ex, W / run->nb * 0.45f);
        break;
    }
    case SPDF_PAINT_BRUSH_CRAYON: case SPDF_PAINT_BRUSH_NATURAL_PENCIL: case SPDF_PAINT_BRUSH_WATERCOLOR: {
        int wet = job->tool == SPDF_PAINT_BRUSH_WATERCOLOR;
        run->pencil = job->tool == SPDF_PAINT_BRUSH_NATURAL_PENCIL;
        run->half = run->pencil ? fmaxf(job->size * 0.28f, 0.45f) : fmaxf(job->size * 0.5f, 0.5f);
        run->step = wet ? fmaxf(0.5f / ex, run->R * 0.3f) : fmaxf(0.5f / ex, run->half * 0.5f);
        if (!spdf_brush_mask_init(ctx, &run->outer, box) ||
            (!wet && !run->pencil && !spdf_brush_mask_init(ctx, &run->inner, box))) {
            spdf_brush_run_drop(ctx, run);
            return NULL;
        }
        break;
    }
    default: break;
    }
    if (run->step > 0 && run->step <= 1e-3f) run->step = 1e-3f;
    return run;
}

void spdf_brush_run_drop(fz_context* ctx, spdf_brush_run* run) {
    if (!run) return;
    spdf_brush_mask_drop(ctx, &run->outer);
    spdf_brush_mask_drop(ctx, &run->inner);
    fz_free(ctx, run);
}

int spdf_brush_run_add(fz_context* ctx, spdf_brush_run* run, const spdf_paint_point* points, int count,
                       spdf_brush_mask* committed) {
    const spdf_brush_job* job = &run->job;
    if (!run || count < 1) return 1;
    if (job->tool == SPDF_PAINT_BRUSH_AIRBRUSH) {
        for (int i = 0; i < count; ++i) {
            grow(&run->pending, fz_intersect_irect(spray(run, run->count ? &run->last : &points[i], &points[i],
                                                         committed), run->box));
            run->last = points[i], run->count++;
        }
    } else if (walks(job->tool)) {
        for (int i = 0; i < count; ++i) {
            if (run->count == 0) run->s0 = (sample){{points[0].x, points[0].y}, pressure_of(&points[0]), 0, 0, {1, 0}};
            else walk_to(run, &run->last, &points[i], committed);
            run->last = points[i], run->count++;
        }
    } else { /* the segments from the last point through the new ones, as the whole stroke draws them */
        spdf_paint_point* seg = fz_malloc_no_throw(ctx, (size_t)(count + 1) * sizeof(*seg));
        int n = 0;
        if (!seg) return 0;
        if (run->count) seg[n++] = run->last;
        memcpy(seg + n, points, (size_t)count * sizeof(*seg));
        n += count;
        if (n > 1) {
            spdf_brush_job part = *job;
            part.points = seg, part.count = n;
            spdf_brush_render(ctx, &part, committed);
            grow(&run->pending, fz_intersect_irect(spdf_brush_job_reach(&part), run->box));
        }
        run->last = points[count - 1], run->count += count;
        fz_free(ctx, seg);
    }
    return 1;
}

/* Watercolor: the wet look worked again over `area` from its coverage, with the tail's steps added; what lies within
 * `reach` of the area counts, the wet edge reaching no further. */
static void show_wet(fz_context* ctx, spdf_brush_run* run, const sample* tail, int n, fz_irect area, int reach,
                     spdf_brush_mask* shown) {
    spdf_brush_mask work;
    fz_irect wide = fz_intersect_irect(fz_expand_irect(area, reach), run->box);
    if (fz_is_empty_irect(area) || !spdf_brush_mask_init(ctx, &work, wide)) return;
    copy_box(&work, &run->outer, wide);
    walk w = run->w;
    for (int i = 0; i < n; ++i) cover_step(run, &w, &tail[i], &work, NULL);
    spdf_brush_wet_part(ctx, &work, run->R * run->ex, fz_invert_matrix(run->job.to_device), run->job.seed, area);
    copy_box(shown, &work, area);
    spdf_brush_mask_drop(ctx, &work);
}

int spdf_brush_run_show(fz_context* ctx, spdf_brush_run* run, const spdf_brush_mask* committed,
                        spdf_brush_mask* shown, fz_irect* changed) {
    const spdf_brush_job* job = &run->job;
    fz_irect was = run->tail, drawn = fz_empty_irect;
    sample tail[2];
    int n = walks(job->tool) ? tail_steps(run, tail) : 0;
    if (job->tool == SPDF_PAINT_BRUSH_WATERCOLOR) {
        /* The blur's reach: both blurs, two passes each way (spdf_brush_wet). */
        float radius = run->R * run->ex;
        int reach = 2 * (int)fmaxf(1, radius * 0.22f) + 2 * (int)fmaxf(1, radius * 0.38f) + 1;
        drawn = tail_reach(run, tail, n);
        fz_irect area = run->pending;
        grow(&area, was), grow(&area, drawn);
        area = fz_intersect_irect(fz_expand_irect(area, reach), run->box);
        show_wet(ctx, run, tail, n, area, reach, shown);
        run->tail = fz_intersect_irect(drawn, run->box);
        if (changed) *changed = area;
        run->pending = fz_empty_irect;
        return 1;
    }
    fz_irect copy = run->pending;
    grow(&copy, was);
    copy_box(shown, committed, copy);
    if (job->tool == SPDF_PAINT_BRUSH_OIL) {
        walk w = run->w;
        for (int i = 0; i < n; ++i) grow(&drawn, oil_step(run, &w, &tail[i], n == 1 && run->walked == 0, shown));
    } else if (n > 0) { /* Crayon, pencil: the tail's cover over what is there, then the paper */
        walk w = run->w;
        spdf_brush_mask outer, inner;
        fz_irect reach = fz_intersect_irect(tail_reach(run, tail, n), run->box);
        if (!fz_is_empty_irect(reach) && spdf_brush_mask_init(ctx, &outer, reach)) {
            memset(&inner, 0, sizeof(inner));
            if (run->pencil || spdf_brush_mask_init(ctx, &inner, reach)) {
                copy_box(&outer, &run->outer, reach);
                if (!run->pencil) copy_box(&inner, &run->inner, reach);
                for (int i = 0; i < n; ++i) cover_step(run, &w, &tail[i], &outer, &inner);
                grain(run, &outer, &inner, reach, shown);
                drawn = reach;
            }
            spdf_brush_mask_drop(ctx, &outer);
            spdf_brush_mask_drop(ctx, &inner);
        }
    } else if (run->count == 1 && job->tool != SPDF_PAINT_BRUSH_AIRBRUSH) { /* a plain nib's click: its dot */
        spdf_brush_job dot = *job;
        dot.points = &run->last, dot.count = 1;
        spdf_brush_render(ctx, &dot, shown);
        drawn = spdf_brush_job_reach(&dot);
    }
    run->tail = fz_intersect_irect(drawn, run->box);
    if (changed) {
        *changed = copy;
        grow(changed, run->tail);
    }
    run->pending = fz_empty_irect;
    return 1;
}

/* ---- The whole stroke at once ---- */

static void render_whole(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* mask) {
    spdf_brush_run* run = spdf_brush_run_new(ctx, job, mask->box);
    if (!run) return;
    spdf_brush_run_add(ctx, run, job->points, job->count, mask);
    spdf_brush_run_show(ctx, run, mask, mask, NULL);
    spdf_brush_run_drop(ctx, run);
}

void spdf_brush_render_airbrush(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m) { render_whole(ctx, job, m); }
void spdf_brush_render_oil(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m) { render_whole(ctx, job, m); }
void spdf_brush_render_crayon(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m) { render_whole(ctx, job, m); }
void spdf_brush_render_natural_pencil(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* m) {
    render_whole(ctx, job, m);
}

/* Watercolor's own mask, so the wet edge is worked on this stroke alone, then merged (max) with what is there. */
void spdf_brush_render_watercolor(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* out) {
    spdf_brush_mask m;
    if (!spdf_brush_mask_init(ctx, &m, out->box)) return;
    render_whole(ctx, job, &m);
    size_t count = (size_t)m.w * (size_t)m.h;
    for (size_t k = 0; k < count; ++k)
        if (m.a[k] > out->a[k]) out->a[k] = m.a[k];
    spdf_brush_mask_drop(ctx, &m);
}
