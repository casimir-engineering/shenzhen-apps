/* spdf_fill_ink_geometry.c -- smoothing, distances, box tests, erasing and arrow heads for pen lines
 * (spdf_fill_ink_geometry.h). Pure C, no MuPDF. */
#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static spdf_fill_point pt(float x, float y) {
    spdf_fill_point p;
    p.x = x, p.y = y;
    return p;
}

static float dist(spdf_fill_point a, spdf_fill_point b) {
    return hypotf(b.x - a.x, b.y - a.y);
}

static spdf_fill_point lerp(spdf_fill_point a, spdf_fill_point b, float t) {
    return pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
}

/* -- smoothing ---------------------------------------------------------------------------------------------------- */

/* The point at knot t on the line through a (at knot ta) and b (at tb). */
static spdf_fill_point at_knot(spdf_fill_point a, spdf_fill_point b, float ta, float tb, float t) {
    if (tb - ta < 1e-9f) return a;
    return lerp(a, b, (t - ta) / (tb - ta));
}

/* Barry and Goldman's pyramid for a Catmull-Rom curve with knots k[0..3], evaluated at t in [k1, k2]. */
static spdf_fill_point catmull_rom(const spdf_fill_point p[4], const float k[4], float t) {
    spdf_fill_point a1 = at_knot(p[0], p[1], k[0], k[1], t);
    spdf_fill_point a2 = at_knot(p[1], p[2], k[1], k[2], t);
    spdf_fill_point a3 = at_knot(p[2], p[3], k[2], k[3], t);
    spdf_fill_point b1 = at_knot(a1, a2, k[0], k[2], t);
    spdf_fill_point b2 = at_knot(a2, a3, k[1], k[3], t);
    return at_knot(b1, b2, k[1], k[2], t);
}

int spdf_ink_flatten_segment(spdf_fill_point p0, spdf_fill_point p1, spdf_fill_point p2, spdf_fill_point p3,
                             float tolerance, float max_step, spdf_fill_point* out, int max_out) {
    spdf_fill_point p[4];
    float k[4], chord, deviation;
    int i, n;
    if (!out || max_out < 1) return 0;
    p[0] = p0, p[1] = p1, p[2] = p2, p[3] = p3;
    k[0] = 0;
    for (i = 1; i < 4; ++i) k[i] = k[i - 1] + fmaxf(sqrtf(dist(p[i - 1], p[i])), 1e-3f); /* centripetal: alpha 0.5 */
    chord = dist(p1, p2);
    deviation = dist(catmull_rom(p, k, 0.5f * (k[1] + k[2])), lerp(p1, p2, 0.5f));
    n = (int)ceilf(chord / fmaxf(max_step, 0.01f));
    if (tolerance > 0 && deviation > tolerance) {
        int bend = (int)ceilf(sqrtf(deviation / tolerance)); /* a curve's sag falls with the square of the pieces */
        if (bend > n) n = bend;
    }
    if (n < 1) n = 1;
    if (n > 256) n = 256;
    if (n > max_out) n = max_out;
    for (i = 1; i < n; ++i) out[i - 1] = catmull_rom(p, k, k[1] + (k[2] - k[1]) * (float)i / (float)n);
    out[n - 1] = p2;
    return n;
}

/* -- thinning ----------------------------------------------------------------------------------------------------- */

static float segment_distance(spdf_fill_point p, spdf_fill_point a, spdf_fill_point b) {
    float dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy, t;
    if (len2 < 1e-12f) return dist(p, a);
    t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    return dist(p, pt(a.x + t * dx, a.y + t * dy));
}

int spdf_ink_simplify(spdf_fill_point* points, int count, float tolerance) {
    unsigned char* keep;
    int* stack;
    int top = 0, i, kept = 0;
    if (!points || count <= 2) return count < 0 ? 0 : count;
    keep = (unsigned char*)calloc((size_t)count, 1);
    stack = (int*)malloc(sizeof(int) * 2 * (size_t)count);
    if (!keep || !stack) {
        free(keep);
        free(stack);
        return count;
    }
    keep[0] = keep[count - 1] = 1;
    stack[top++] = 0, stack[top++] = count - 1;
    while (top > 0) {
        int last = stack[--top], first = stack[--top], far = -1;
        float worst = tolerance;
        for (i = first + 1; i < last; ++i) {
            float d = segment_distance(points[i], points[first], points[last]);
            if (d > worst) worst = d, far = i;
        }
        if (far < 0) continue;
        keep[far] = 1;
        stack[top++] = first, stack[top++] = far;
        stack[top++] = far, stack[top++] = last;
    }
    for (i = 0; i < count; ++i)
        if (keep[i]) points[kept++] = points[i];
    free(keep);
    free(stack);
    return kept;
}

/* -- distances and boxes ------------------------------------------------------------------------------------------ */

float spdf_ink_distance_to_polyline(const spdf_fill_point* points, int count, spdf_fill_point p) {
    float best;
    int i;
    if (!points || count <= 0) return INFINITY;
    best = dist(p, points[0]);
    for (i = 1; i < count; ++i) {
        float d = segment_distance(p, points[i - 1], points[i]);
        if (d < best) best = d;
    }
    return best;
}

static float cross(spdf_fill_point o, spdf_fill_point a, spdf_fill_point b) {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

static int segments_cross(spdf_fill_point a, spdf_fill_point b, spdf_fill_point c, spdf_fill_point d) {
    float d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

static float segments_distance(spdf_fill_point a, spdf_fill_point b, spdf_fill_point c, spdf_fill_point d) {
    float best;
    if (segments_cross(a, b, c, d)) return 0;
    best = segment_distance(a, c, d);
    best = fminf(best, segment_distance(b, c, d));
    best = fminf(best, segment_distance(c, a, b));
    return fminf(best, segment_distance(d, a, b));
}

float spdf_ink_polyline_distance(const spdf_fill_point* a, int na, const spdf_fill_point* b, int nb) {
    float best = INFINITY;
    int i, k;
    if (!a || !b || na <= 0 || nb <= 0) return INFINITY;
    if (na == 1) return spdf_ink_distance_to_polyline(b, nb, a[0]);
    if (nb == 1) return spdf_ink_distance_to_polyline(a, na, b[0]);
    for (i = 1; i < na; ++i)
        for (k = 1; k < nb; ++k) {
            float d = segments_distance(a[i - 1], a[i], b[k - 1], b[k]);
            if (d < best) best = d;
            if (best <= 0) return 0;
        }
    return best;
}

spdf_rect spdf_ink_bounds(const spdf_fill_point* points, int count, float half_width) {
    spdf_rect r = {0, 0, 0, 0};
    int i;
    if (!points || count <= 0) return r;
    r.x0 = r.x1 = points[0].x;
    r.y0 = r.y1 = points[0].y;
    for (i = 1; i < count; ++i) {
        r.x0 = fminf(r.x0, points[i].x), r.x1 = fmaxf(r.x1, points[i].x);
        r.y0 = fminf(r.y0, points[i].y), r.y1 = fmaxf(r.y1, points[i].y);
    }
    r.x0 -= half_width, r.y0 -= half_width, r.x1 += half_width, r.y1 += half_width;
    return r;
}

static int point_in_rect(spdf_fill_point p, spdf_rect r) {
    return p.x >= r.x0 && p.x <= r.x1 && p.y >= r.y0 && p.y <= r.y1;
}

/* Liang-Barsky: whether the segment a-b meets rect r. */
static int segment_meets_rect(spdf_fill_point a, spdf_fill_point b, spdf_rect r) {
    float t0 = 0, t1 = 1, dx = b.x - a.x, dy = b.y - a.y;
    float p[4] = {-dx, dx, -dy, dy}, q[4] = {a.x - r.x0, r.x1 - a.x, a.y - r.y0, r.y1 - a.y};
    int i;
    for (i = 0; i < 4; ++i) {
        if (fabsf(p[i]) < 1e-12f) {
            if (q[i] < 0) return 0;
            continue;
        }
        float t = q[i] / p[i];
        if (p[i] < 0) {
            if (t > t1) return 0;
            if (t > t0) t0 = t;
        } else {
            if (t < t0) return 0;
            if (t < t1) t1 = t;
        }
    }
    return 1;
}

int spdf_ink_touches_rect(const spdf_fill_point* points, int count, float half_width, spdf_rect rect) {
    spdf_rect grown = rect;
    int i;
    if (!points || count <= 0) return 0;
    grown.x0 -= half_width, grown.y0 -= half_width, grown.x1 += half_width, grown.y1 += half_width;
    if (point_in_rect(points[0], grown)) return 1;
    for (i = 1; i < count; ++i)
        if (segment_meets_rect(points[i - 1], points[i], grown)) return 1;
    return 0;
}

int spdf_ink_inside_rect(const spdf_fill_point* points, int count, float half_width, spdf_rect rect) {
    spdf_rect b;
    if (!points || count <= 0) return 0;
    b = spdf_ink_bounds(points, count, half_width);
    return b.x0 >= rect.x0 && b.y0 >= rect.y0 && b.x1 <= rect.x1 && b.y1 <= rect.y1;
}

/* -- arrows ------------------------------------------------------------------------------------------------------- */

void spdf_ink_arrow_head(spdf_fill_point tail, spdf_fill_point tip, float width, spdf_fill_point out[3]) {
    float dx = tail.x - tip.x, dy = tail.y - tip.y, len = hypotf(dx, dy);
    float barb = fminf(fmaxf(4.0f + 3.0f * width, 6.0f), 24.0f);
    float c = cosf(28.0f * 3.14159265f / 180.0f), s = sinf(28.0f * 3.14159265f / 180.0f);
    if (len < 1e-6f) dx = -1, dy = 0, len = 1;
    dx /= len, dy /= len; /* from the tip back along the shaft */
    out[0] = pt(tip.x + barb * (dx * c - dy * s), tip.y + barb * (dx * s + dy * c));
    out[1] = tip;
    out[2] = pt(tip.x + barb * (dx * c + dy * s), tip.y + barb * (-dx * s + dy * c));
}

/* -- erasing ------------------------------------------------------------------------------------------------------ */

typedef struct eraser {
    const spdf_fill_point* swath;
    int count;
    float reach;
    spdf_rect bounds; /* the swath grown by reach: points outside it are never erased */
} eraser;

static int erased(const eraser* e, spdf_fill_point p) {
    if (!point_in_rect(p, e->bounds)) return 0;
    return spdf_ink_distance_to_polyline(e->swath, e->count, p) <= e->reach;
}

typedef struct run_buffer {
    spdf_ink_runs* out;
    int total, point_cap, run_cap; /* points written, room for points and runs */
    int in_run, run_from;          /* a run is open, and where its points start */
    float min_length;
    int ok;
} run_buffer;

static void push_point(run_buffer* b, spdf_fill_point p) {
    if (!b->ok) return;
    if (b->total == b->point_cap) {
        int cap = b->point_cap ? b->point_cap * 2 : 64;
        spdf_fill_point* grown = (spdf_fill_point*)realloc(b->out->points, sizeof(spdf_fill_point) * (size_t)cap);
        if (!grown) {
            b->ok = 0;
            return;
        }
        b->out->points = grown, b->point_cap = cap;
    }
    b->out->points[b->total++] = p;
}

static void start_run(run_buffer* b, spdf_fill_point p) {
    b->in_run = 1;
    b->run_from = b->total;
    push_point(b, p);
}

/* Closes the open run: kept when it is at least min_length long, dropped otherwise. Returns whether it was kept. */
static int end_run(run_buffer* b) {
    spdf_ink_runs* o = b->out;
    float length = 0;
    int i, n = b->total - b->run_from;
    if (!b->in_run || !b->ok) return 0;
    b->in_run = 0;
    for (i = b->run_from + 1; i < b->total; ++i) length += dist(o->points[i - 1], o->points[i]);
    if (n < 2 || length < b->min_length) {
        b->total = b->run_from;
        return 0;
    }
    if (o->run_count == b->run_cap) {
        int cap = b->run_cap ? b->run_cap * 2 : 8;
        int* grown = (int*)realloc(o->run_lengths, sizeof(int) * (size_t)cap);
        if (!grown) {
            b->ok = 0;
            return 0;
        }
        o->run_lengths = grown, b->run_cap = cap;
    }
    o->run_lengths[o->run_count++] = n;
    return 1;
}

int spdf_ink_erase(const spdf_fill_point* line, int count, const spdf_fill_point* swath, int swath_count, float reach,
                   float min_length, spdf_ink_runs* out) {
    eraser e;
    run_buffer b;
    float step;
    int i, k, was;
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!line || count <= 0 || !swath || swath_count <= 0) return 1;
    e.swath = swath, e.count = swath_count, e.reach = reach;
    e.bounds = spdf_ink_bounds(swath, swath_count, reach);
    memset(&b, 0, sizeof(b));
    b.out = out, b.min_length = min_length, b.ok = 1;
    step = fminf(1.0f, fmaxf(0.25f, reach * 0.5f));
    was = erased(&e, line[0]);
    out->touched = was;
    if (!was) start_run(&b, line[0]);
    for (i = 1; i < count && b.ok; ++i) {
        spdf_fill_point a = line[i - 1], c = line[i];
        int pieces = (int)ceilf(dist(a, c) / step);
        float t_prev = 0;
        if (pieces < 1) pieces = 1;
        if (pieces > 100000) pieces = 100000;
        for (k = 1; k <= pieces; ++k) {
            float t = (float)k / (float)pieces, lo = t_prev, hi = t;
            int now = erased(&e, lerp(a, c, t)), n;
            if (now != was) {
                /* Three halvings put the cut within an eighth of a step of the swath's edge. */
                for (n = 0; n < 3; ++n) {
                    float mid = 0.5f * (lo + hi);
                    if (erased(&e, lerp(a, c, mid)) == was) lo = mid;
                    else hi = mid;
                }
                out->touched = 1;
                if (was) start_run(&b, lerp(a, c, hi));
                else {
                    push_point(&b, lerp(a, c, lo));
                    end_run(&b);
                }
            }
            if (!now && k == pieces) push_point(&b, c);
            was = now;
            t_prev = t;
        }
    }
    out->last_run_keeps_end = b.in_run && end_run(&b);
    if (!b.ok) {
        spdf_ink_free_runs(out);
        return 0;
    }
    return 1;
}

void spdf_ink_free_runs(spdf_ink_runs* runs) {
    if (!runs) return;
    free(runs->points);
    free(runs->run_lengths);
    memset(runs, 0, sizeof(*runs));
}
