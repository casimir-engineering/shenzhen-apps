/* spdf_fill_snap_clean.c -- tidies the rules and boxes spdf_fill_snap.c read from a page: joins dashed rules, drops
 * link underlines, page frames and real fields, turns small squares drawn as four rules into boxes, and finds rows of
 * character boxes (spdf_fill_snap.h). */
#include "spdf_fill_snap_internal.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define MERGE_GAP 3.0f

static int cmp_hline(const void* a, const void* b) {
    const spdf_snap_hline *p = (const spdf_snap_hline*)a, *q = (const spdf_snap_hline*)b;
    return p->y < q->y ? -1 : p->y > q->y ? 1 : p->x0 < q->x0 ? -1 : p->x0 > q->x0;
}
static int cmp_hline_x(const void* a, const void* b) {
    const spdf_snap_hline *p = (const spdf_snap_hline*)a, *q = (const spdf_snap_hline*)b;
    return p->x0 < q->x0 ? -1 : p->x0 > q->x0;
}
static int cmp_vline(const void* a, const void* b) {
    const spdf_snap_vline *p = (const spdf_snap_vline*)a, *q = (const spdf_snap_vline*)b;
    return p->x < q->x ? -1 : p->x > q->x ? 1 : p->y0 < q->y0 ? -1 : p->y0 > q->y0;
}
static int cmp_vline_y(const void* a, const void* b) {
    const spdf_snap_vline *p = (const spdf_snap_vline*)a, *q = (const spdf_snap_vline*)b;
    return p->y0 < q->y0 ? -1 : p->y0 > q->y0;
}
static int cmp_box(const void* a, const void* b) {
    const spdf_rect *p = (const spdf_rect*)a, *q = (const spdf_rect*)b;
    float py = roundf(p->y0), qy = roundf(q->y0);
    return py < qy ? -1 : py > qy ? 1 : p->x0 < q->x0 ? -1 : p->x0 > q->x0;
}
static int cmp_run(const void* a, const void* b) {
    const spdf_snap_text_run *p = (const spdf_snap_text_run*)a, *q = (const spdf_snap_text_run*)b;
    return p->baseline < q->baseline ? -1 : p->baseline > q->baseline;
}

/* Collinear pieces (dashed, dotted, or drawn cell by cell) become one rule. */
static void merge_hlines(spdf_snap_geometry* g) {
    int i, start, out = 0;
    qsort(g->hlines, (size_t)g->hline_count, sizeof(*g->hlines), cmp_hline);
    for (start = 0; start < g->hline_count;) {
        int end = start + 1;
        while (end < g->hline_count && g->hlines[end].y - g->hlines[start].y <= 0.5f) ++end;
        qsort(g->hlines + start, (size_t)(end - start), sizeof(*g->hlines), cmp_hline_x);
        for (i = start; i < end; ++i) {
            spdf_snap_hline l = g->hlines[i];
            if (out > 0 && fabsf(g->hlines[out - 1].y - l.y) <= 0.5f && l.x0 <= g->hlines[out - 1].x1 + MERGE_GAP)
                g->hlines[out - 1].x1 = fmaxf(g->hlines[out - 1].x1, l.x1);
            else g->hlines[out++] = l;
        }
        start = end;
    }
    g->hline_count = out;
}

static void merge_vlines(spdf_snap_geometry* g) {
    int i, start, out = 0;
    qsort(g->vlines, (size_t)g->vline_count, sizeof(*g->vlines), cmp_vline);
    for (start = 0; start < g->vline_count;) {
        int end = start + 1;
        while (end < g->vline_count && g->vlines[end].x - g->vlines[start].x <= 0.5f) ++end;
        qsort(g->vlines + start, (size_t)(end - start), sizeof(*g->vlines), cmp_vline_y);
        for (i = start; i < end; ++i) {
            spdf_snap_vline l = g->vlines[i];
            if (out > 0 && fabsf(g->vlines[out - 1].x - l.x) <= 0.5f && l.y0 <= g->vlines[out - 1].y1 + MERGE_GAP)
                g->vlines[out - 1].y1 = fmaxf(g->vlines[out - 1].y1, l.y1);
            else g->vlines[out++] = l;
        }
        start = end;
    }
    g->vline_count = out;
}

/* Runs sorted by baseline: the first index whose baseline is >= y. */
static int first_run_at(const spdf_snap_geometry* g, float y) {
    int lo = 0, hi = g->run_count;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (g->runs[mid].baseline < y) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

/* Link underlines and strike-throughs: rules with page text over more than half their length. */
static int rule_is_under_text(const spdf_snap_geometry* g, spdf_snap_hline l) {
    float covered = 0;
    int i;
    for (i = first_run_at(g, l.y - 15); i < g->run_count && g->runs[i].baseline <= l.y + 58; ++i) {
        spdf_rect r = g->runs[i].rect;
        if (l.y < r.y0 || l.y > r.y1 + 0.5f) continue;
        covered += fmaxf(0, fminf(l.x1, r.x1) - fmaxf(l.x0, r.x0));
    }
    return covered > 0.5f * (l.x1 - l.x0);
}

static int on_widget(const spdf_snap_geometry* g, spdf_rect r) {
    int i;
    for (i = 0; i < g->widget_count; ++i) {
        spdf_rect w = g->widgets[i];
        float ix = fminf(r.x1, w.x1 + 2) - fmaxf(r.x0, w.x0 - 2), iy = fminf(r.y1, w.y1 + 2) - fmaxf(r.y0, w.y0 - 2);
        if (ix > 0.5f * rw(r) && iy >= 0 && (rh(r) < 1 || iy > 0.5f * rh(r))) return 1;
    }
    return 0;
}

static void add_comb(fz_context* ctx, spdf_snap_geometry* g, const spdf_rect* cells, int count) {
    spdf_snap_comb* combs = (spdf_snap_comb*)realloc(g->combs, (size_t)(g->comb_count + 1) * sizeof(*combs));
    spdf_rect* copy = (spdf_rect*)malloc((size_t)count * sizeof(spdf_rect));
    if (combs) g->combs = combs;
    if (!combs || !copy) {
        free(copy);
        fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    }
    memcpy(copy, cells, (size_t)count * sizeof(spdf_rect));
    g->combs[g->comb_count].cells = copy;
    g->combs[g->comb_count++].count = count;
}

/* A rule with five or more evenly spaced ticks rising from it is a row of character boxes; the rule itself goes. */
static void find_tick_combs(fz_context* ctx, spdf_snap_geometry* g) {
    enum { MAX_TICKS = 100 };
    float xs[MAX_TICKS], tick_h = 0;
    spdf_rect cells[MAX_TICKS];
    int i, k, n;
    for (i = 0; i < g->hline_count; ++i) {
        spdf_snap_hline* l = &g->hlines[i];
        float step, h;
        if (l->x1 - l->x0 < 30) continue;
        for (k = n = 0; k < g->vline_count && n < MAX_TICKS; ++k) { /* vlines are sorted by x */
            spdf_snap_vline v = g->vlines[k];
            if (fabsf(v.y1 - l->y) > 1.5f || v.x < l->x0 - 1 || v.x > l->x1 + 1) continue;
            if (v.y1 - v.y0 < 3 || v.y1 - v.y0 > 24) continue;
            xs[n++] = v.x, tick_h = v.y1 - v.y0;
        }
        if (n < 5) continue;
        step = (xs[n - 1] - xs[0]) / (float)(n - 1);
        if (step < 6 || step > 40) continue;
        for (k = 1; k < n; ++k)
            if (fabsf(xs[k] - xs[k - 1] - step) > 0.25f * step) break;
        if (k < n) continue;
        h = clampf(fmaxf(tick_h, 0.9f * step), 6, 24);
        for (k = 0; k + 1 < n; ++k) cells[k] = make_rect(xs[k], l->y - h, xs[k + 1], l->y);
        add_comb(ctx, g, cells, n - 1);
        l->x1 = l->x0; /* dropped by the length filter */
    }
}

/* A vertical rule at x running from y0 to y1 (within 1 pt), shortened to nothing once used. */
static spdf_snap_vline* rule_down(spdf_snap_geometry* g, float x, float y0, float y1) {
    int i;
    for (i = 0; i < g->vline_count; ++i) {
        spdf_snap_vline* v = &g->vlines[i];
        if (fabsf(v->x - x) <= 1 && v->y0 <= y0 + 1 && v->y1 >= y1 - 1 && v->y1 - v->y0 <= y1 - y0 + 2) return v;
    }
    return NULL;
}

/* A small square drawn as four separate rules (as some programs draw checkboxes) is a box; its rules go. */
static void find_ruled_squares(fz_context* ctx, spdf_snap_geometry* g) {
    int i, j;
    for (i = 0; i < g->hline_count; ++i) { /* hlines are sorted by y */
        spdf_snap_hline* top = &g->hlines[i];
        float w = top->x1 - top->x0;
        if (w < 5 || w > 24) continue;
        for (j = i + 1; j < g->hline_count && g->hlines[j].y - top->y <= 24; ++j) {
            spdf_snap_hline* bottom = &g->hlines[j];
            spdf_snap_vline *left, *right;
            spdf_rect* boxes;
            float h = bottom->y - top->y;
            if (h < 5 || w / h < 0.75f || w / h > 1.33f || fabsf(bottom->x0 - top->x0) > 1 ||
                fabsf(bottom->x1 - top->x1) > 1)
                continue;
            left = rule_down(g, top->x0, top->y, bottom->y), right = rule_down(g, top->x1, top->y, bottom->y);
            if (!left || !right) continue;
            boxes = (spdf_rect*)realloc(g->boxes, (size_t)(g->box_count + 1) * sizeof(*boxes));
            if (!boxes) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
            g->boxes = boxes;
            g->boxes[g->box_count++] = make_rect(top->x0, top->y, top->x1, bottom->y);
            top->x1 = top->x0, bottom->x1 = bottom->x0; /* dropped by the length filter */
            left->y1 = left->y0, right->y1 = right->y0;
            break;
        }
    }
}

/* Four or more equal boxes side by side are character boxes. */
static void find_box_combs(fz_context* ctx, spdf_snap_geometry* g) {
    int i = 0, out = 0;
    qsort(g->boxes, (size_t)g->box_count, sizeof(*g->boxes), cmp_box);
    while (i < g->box_count) {
        int j = i + 1;
        spdf_rect a = g->boxes[i];
        if (rh(a) >= 6 && rh(a) <= 40 && rw(a) >= 5 && rw(a) <= 40) {
            while (j < g->box_count) {
                spdf_rect p = g->boxes[j - 1], q = g->boxes[j];
                if (fabsf(q.y0 - a.y0) > 1 || fabsf(q.y1 - a.y1) > 1 || fabsf(rw(q) - rw(a)) > 1) break;
                if (q.x0 - p.x1 < -1 || q.x0 - p.x1 > 2) break;
                ++j;
            }
        }
        if (j - i >= 4) {
            add_comb(ctx, g, g->boxes + i, j - i);
            i = j;
            continue;
        }
        g->boxes[out++] = g->boxes[i++];
    }
    g->box_count = out;
}

void spdf_snap_finish_geometry(fz_context* ctx, spdf_snap_geometry* g) {
    int i, out;
    float pw = rw(g->page), ph = rh(g->page);
    qsort(g->runs, (size_t)g->run_count, sizeof(*g->runs), cmp_run);
    merge_hlines(g);
    merge_vlines(g);
    find_tick_combs(ctx, g);
    find_ruled_squares(ctx, g);
    for (i = out = 0; i < g->hline_count; ++i) {
        spdf_snap_hline l = g->hlines[i];
        if (l.x1 - l.x0 < 8 || rule_is_under_text(g, l) || on_widget(g, make_rect(l.x0, l.y, l.x1, l.y))) continue;
        g->hlines[out++] = l;
    }
    g->hline_count = out;
    for (i = out = 0; i < g->box_count; ++i) {
        spdf_rect b = g->boxes[i];
        if ((rw(b) > 0.8f * pw && rh(b) > 0.8f * ph) || on_widget(g, b)) continue; /* page frames, real fields */
        g->boxes[out++] = b;
    }
    g->box_count = out;
    find_box_combs(ctx, g);
}
