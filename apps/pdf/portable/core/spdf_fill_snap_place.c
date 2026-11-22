/* spdf_fill_snap_place.c -- where text, marks and signatures go, answered from a page's geometry without touching the
 * document (spdf_fill_snap.h; the placement rule table is in docs/plans/fill-and-sign.md, CORE 3). */
#include "spdf_fill_snap.h"
#include "spdf_fill_items.h"
#include "spdf_fill_snap_internal.h"

#include "mupdf/fitz.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define DEFAULT_TEXT 11.0f

/* -- labels ----------------------------------------------------------------------------------------------------- */

/* The page text naming a target: on its row to the left, else just above, else inside it (top left). */
static void find_label(const spdf_snap_geometry* g, spdf_rect t, char* out, size_t len) {
    const spdf_snap_text_run* best = NULL;
    float best_score = 1e9f;
    int i;
    for (i = 0; i < g->run_count; ++i) {
        const spdf_snap_text_run* r = &g->runs[i];
        float score = 1e9f;
        float cy = (r->rect.y0 + r->rect.y1) * 0.5f;
        if (r->rect.x1 <= t.x0 + 4 && cy >= t.y0 - 4 && cy <= t.y1 + 4 && t.x0 - r->rect.x1 < 200)
            score = t.x0 - r->rect.x1;
        else if (r->rect.y1 <= t.y0 + 1 && t.y0 - r->rect.y1 < 14 && r->rect.x0 < t.x1 && r->rect.x1 > t.x0)
            score = 50 + t.y0 - r->rect.y1;
        else if (inside(t, r->rect.x0, cy, 0))
            score = 100 + r->rect.x0 - t.x0;
        if (score < best_score) best_score = score, best = r;
    }
    if (best) snprintf(out, len, "%s", best->text);
}

/* -- finding the target ----------------------------------------------------------------------------------------- */

static int is_checkbox(spdf_rect b) {
    float w = rw(b), h = rh(b);
    return w >= 5 && w <= 24 && h >= 5 && h <= 24 && w / h >= 0.75f && w / h <= 1.33f;
}

static float distance_to(spdf_rect r, float x, float y) {
    float dx = fmaxf(fmaxf(r.x0 - x, 0), x - r.x1), dy = fmaxf(fmaxf(r.y0 - y, 0), y - r.y1);
    return sqrtf(dx * dx + dy * dy);
}

static int find_checkbox(const spdf_snap_geometry* g, float x, float y, int with_comb_cells, spdf_rect* out) {
    float best = 4.01f;
    int i, k, found = 0;
    for (i = 0; i < g->box_count; ++i) {
        float d = distance_to(g->boxes[i], x, y);
        if (is_checkbox(g->boxes[i]) && d < best) best = d, *out = g->boxes[i], found = 1;
    }
    for (k = 0; with_comb_cells && k < g->comb_count; ++k)
        for (i = 0; i < g->combs[k].count; ++i) {
            float d = distance_to(g->combs[k].cells[i], x, y);
            if (d < best) best = d, *out = g->combs[k].cells[i], found = 1;
        }
    return found;
}

static int find_box(const spdf_snap_geometry* g, float x, float y, float max_h, spdf_rect* out) {
    float best = 1e12f;
    int i, found = 0;
    for (i = 0; i < g->box_count; ++i) {
        spdf_rect b = g->boxes[i];
        if (!inside(b, x, y, 1) || rh(b) < 6 || rh(b) > max_h || rw(b) < 12) continue;
        if (rw(b) * rh(b) < best) best = rw(b) * rh(b), *out = b, found = 1;
    }
    return found;
}

/* A cell of a ruled table: the nearest rules around the point, 8-80 pt high, with no text inside. */
static int find_cell(const spdf_snap_geometry* g, float x, float y, spdf_rect* out) {
    float top = -1e9f, bottom = 1e9f, left = -1e9f, right = 1e9f;
    int i;
    for (i = 0; i < g->hline_count; ++i) {
        spdf_snap_hline l = g->hlines[i];
        if (x < l.x0 - 1 || x > l.x1 + 1) continue;
        if (l.y < y && l.y > top) top = l.y;
        if (l.y > y && l.y < bottom) bottom = l.y;
    }
    for (i = 0; i < g->vline_count; ++i) {
        spdf_snap_vline l = g->vlines[i];
        if (y < l.y0 - 1 || y > l.y1 + 1) continue;
        if (l.x < x && l.x > left) left = l.x;
        if (l.x > x && l.x < right) right = l.x;
    }
    if (bottom - top < 8 || bottom - top > 80 || right - left < 12 || right - left > 600) return 0;
    *out = make_rect(left, top, right, bottom);
    for (i = 0; i < g->run_count; ++i)
        if (inside(*out, (g->runs[i].rect.x0 + g->runs[i].rect.x1) * 0.5f,
                   (g->runs[i].rect.y0 + g->runs[i].rect.y1) * 0.5f, -1))
            return 0;
    return 1;
}

static int find_underline(const spdf_snap_geometry* g, float x, float y, float radius, float above,
                          spdf_snap_hline* out) {
    float best = 1e9f, xslop = fmaxf(10, radius);
    int i, found = 0;
    for (i = 0; i < g->hline_count; ++i) {
        spdf_snap_hline l = g->hlines[i];
        float score;
        if (l.x1 - l.x0 < 12 || x < l.x0 - xslop || x > l.x1 + xslop || y < l.y - above || y > l.y + 4) continue;
        score = l.y >= y ? l.y - y : 2 * (y - l.y);
        if (score < best) best = score, *out = l, found = 1;
    }
    return found;
}

/* Free height above a rule over [x0, x1]: up to the nearest text or rule, or 0 when nothing is within 40 pt. */
static float free_gap_above(const spdf_snap_geometry* g, spdf_snap_hline l, float x0) {
    float gap = 40;
    int i, found = 0;
    for (i = 0; i < g->run_count; ++i) {
        spdf_rect r = g->runs[i].rect;
        if (r.y1 > l.y - 0.5f || r.x1 <= x0 || r.x0 >= l.x1 || l.y - r.y1 >= gap) continue;
        gap = l.y - r.y1, found = 1;
    }
    for (i = 0; i < g->hline_count; ++i) {
        spdf_snap_hline o = g->hlines[i];
        if (o.y >= l.y - 0.5f || o.x1 <= x0 || o.x0 >= l.x1 || l.y - o.y >= gap) continue;
        gap = l.y - o.y, found = 1;
    }
    return found ? gap : 0;
}

/* -- placing ---------------------------------------------------------------------------------------------------- */

static spdf_rect centred_square(spdf_rect area, float side) {
    float cx = (area.x0 + area.x1) * 0.5f, cy = (area.y0 + area.y1) * 0.5f;
    return make_rect(cx - side * 0.5f, cy - side * 0.5f, cx + side * 0.5f, cy + side * 0.5f);
}

static spdf_rect fit_aspect(spdf_rect area, float aspect, float inset) {
    float w = rw(area) - 2 * inset, h = rh(area) - 2 * inset;
    if (w <= 0 || h <= 0) w = rw(area), h = rh(area);
    if (w / h > aspect) w = h * aspect;
    else h = w / aspect;
    return make_rect((area.x0 + area.x1 - w) * 0.5f, (area.y0 + area.y1 - h) * 0.5f, (area.x0 + area.x1 + w) * 0.5f,
                     (area.y0 + area.y1 + h) * 0.5f);
}

static void place_in_area(const spdf_snap_geometry* g, spdf_rect area, spdf_snap_purpose purpose, float aspect,
                          spdf_snap_result* out) {
    float size = clampf(0.65f * rh(area), 8, 12), x = area.x0 + 3;
    int i;
    out->font_size = size;
    if (purpose == SPDF_SNAP_FOR_SIGNATURE) {
        out->place = fit_aspect(area, aspect, 2);
        return;
    }
    if (purpose == SPDF_SNAP_FOR_MARK || out->place_mark) {
        out->place = centred_square(area, out->kind == SPDF_SNAP_CHECKBOX ? 0.8f * fminf(rw(area), rh(area)) : size);
        out->font_size = rh(out->place);
        return;
    }
    for (i = 0; i < g->run_count; ++i) { /* a label inside the box: write after it */
        spdf_rect r = g->runs[i].rect;
        if (inside(area, r.x0, (r.y0 + r.y1) * 0.5f, 0) && r.x1 + 3 > x && r.x1 + 3 < area.x1 - 2 * size)
            x = r.x1 + 3;
    }
    out->baseline = (area.y0 + area.y1) * 0.5f + 0.35f * size;
    out->place = spdf_fill_text_rect(x, out->baseline, area.x1 - 3 - x, size, 1);
}

static void place_on_line(const spdf_snap_geometry* g, spdf_snap_hline l, float x, spdf_snap_purpose purpose,
                          float aspect, spdf_snap_result* out) {
    float gap, size, start = x - l.x0 <= 40 || x >= l.x1 - 4 ? l.x0 + 2 : x;
    gap = free_gap_above(g, l, start);
    size = gap > 0 ? clampf(0.75f * gap, 8, 12) : DEFAULT_TEXT;
    out->font_size = size;
    out->target = make_rect(l.x0, l.y - 1.2f * size, l.x1, l.y + 1);
    if (purpose == SPDF_SNAP_FOR_SIGNATURE) {
        float h = clampf(2.2f * size, 18, 48), w = h * aspect, x0;
        if (w > l.x1 - l.x0) w = l.x1 - l.x0, h = w / aspect;
        x0 = clampf(x - w * 0.5f, l.x0, l.x1 - w);
        out->place = make_rect(x0, l.y + 0.15f * h - h, x0 + w, l.y + 0.15f * h);
    } else if (purpose == SPDF_SNAP_FOR_MARK) {
        float cx = clampf(x, l.x0 + size * 0.5f, l.x1 - size * 0.5f);
        out->place = make_rect(cx - size * 0.5f, l.y - 2 - size, cx + size * 0.5f, l.y - 2);
    } else {
        out->baseline = l.y - 2;
        out->place = spdf_fill_text_rect(start, out->baseline, l.x1 - start, size, 1);
    }
}

static void place_free(const spdf_snap_geometry* g, float x, float y, spdf_snap_purpose purpose, float aspect,
                       spdf_snap_result* out) {
    out->kind = SPDF_SNAP_NONE;
    out->font_size = purpose == SPDF_SNAP_FOR_MARK ? 10 : DEFAULT_TEXT;
    if (purpose == SPDF_SNAP_FOR_SIGNATURE) {
        out->place = make_rect(x - 75, y - 75 / aspect, x + 75, y + 75 / aspect);
    } else if (purpose == SPDF_SNAP_FOR_MARK) {
        out->place = make_rect(x - 5, y - 5, x + 5, y + 5);
    } else {
        float width = fminf(g->page.x1 - 18 - x, 250);
        out->baseline = y;
        out->place = spdf_fill_text_rect(x, y, fmaxf(width, 40), DEFAULT_TEXT, 1);
    }
    out->target = out->place;
}

spdf_snap_kind spdf_snap_resolve(const spdf_snap_geometry* g, float x, float y, float radius,
                                 spdf_snap_purpose purpose, float aspect, spdf_snap_result* out) {
    spdf_rect r;
    spdf_snap_hline line;
    int i, k;
    if (!out) return SPDF_SNAP_NONE;
    memset(out, 0, sizeof(*out));
    if (!g) return SPDF_SNAP_NONE;
    if (!(aspect > 0.05f)) aspect = 3;
    radius = fmaxf(radius, 6);
    for (i = 0; i < g->widget_count; ++i)
        if (inside(g->widgets[i], x, y, 1)) {
            out->kind = SPDF_SNAP_FIELD;
            out->target = out->place = g->widgets[i];
            return out->kind;
        }
    for (k = 0; purpose == SPDF_SNAP_FOR_TEXT && k < g->comb_count; ++k) {
        spdf_snap_comb c = g->combs[k];
        spdf_rect all = make_rect(c.cells[0].x0, c.cells[0].y0, c.cells[c.count - 1].x1, c.cells[c.count - 1].y1);
        if (!inside(all, x, y, 2)) continue;
        out->kind = SPDF_SNAP_COMB;
        out->target = all;
        out->cells = c.cells, out->cell_count = c.count;
        out->font_size = clampf(0.65f * rh(c.cells[0]), 8, 12);
        out->baseline = (c.cells[0].y0 + c.cells[0].y1) * 0.5f + 0.35f * out->font_size;
        out->place = c.cells[0];
        find_label(g, all, out->label, sizeof out->label);
        return out->kind;
    }
    if (find_checkbox(g, x, y, purpose != SPDF_SNAP_FOR_TEXT, &r)) {
        out->kind = SPDF_SNAP_CHECKBOX;
        out->place_mark = purpose == SPDF_SNAP_FOR_TEXT;
    } else if (find_box(g, x, y, purpose == SPDF_SNAP_FOR_SIGNATURE ? 150 : 80, &r)) {
        out->kind = SPDF_SNAP_BOX;
    } else if (find_cell(g, x, y, &r)) {
        out->kind = SPDF_SNAP_CELL;
    }
    if (out->kind != SPDF_SNAP_NONE) {
        out->target = r;
        find_label(g, r, out->label, sizeof out->label);
        place_in_area(g, r, purpose, aspect, out);
        return out->kind;
    }
    if (find_underline(g, x, y, radius, purpose == SPDF_SNAP_FOR_SIGNATURE ? 40 : 18, &line)) {
        out->kind = SPDF_SNAP_UNDERLINE;
        find_label(g, make_rect(line.x0, line.y - 14, line.x1, line.y), out->label, sizeof out->label);
        place_on_line(g, line, x, purpose, aspect, out);
        return out->kind;
    }
    place_free(g, x, y, purpose, aspect, out);
    return out->kind;
}

/* -- Tab order -------------------------------------------------------------------------------------------------- */

static int cmp_target(const void* a, const void* b) {
    const spdf_snap_target *p = (const spdf_snap_target*)a, *q = (const spdf_snap_target*)b;
    float py = (p->rect.y0 + p->rect.y1) * 0.5f, qy = (q->rect.y0 + q->rect.y1) * 0.5f;
    return py < qy ? -1 : py > qy ? 1 : p->rect.x0 < q->rect.x0 ? -1 : p->rect.x0 > q->rect.x0;
}
static int cmp_target_x(const void* a, const void* b) {
    const spdf_snap_target *p = (const spdf_snap_target*)a, *q = (const spdf_snap_target*)b;
    return p->rect.x0 < q->rect.x0 ? -1 : p->rect.x0 > q->rect.x0;
}

/* A rule that meets a vertical rule belongs to a table, not a line to write on. */
static int rule_meets_vertical(const spdf_snap_geometry* g, spdf_snap_hline l) {
    int i;
    for (i = 0; i < g->vline_count; ++i) {
        spdf_snap_vline v = g->vlines[i];
        if (v.x >= l.x0 - 1 && v.x <= l.x1 + 1 && l.y >= v.y0 - 1 && l.y <= v.y1 + 1) return 1;
    }
    return 0;
}

int spdf_snap_targets_in_order(const spdf_snap_geometry* g, spdf_snap_target* out, int max) {
    spdf_snap_target* all;
    int i, n = 0, total, start;
    if (!g) return 0;
    total = g->box_count + g->comb_count + g->hline_count;
    if (total == 0) return 0;
    all = (spdf_snap_target*)calloc((size_t)total, sizeof(*all));
    if (!all) return 0;
    for (i = 0; i < g->box_count; ++i) {
        spdf_rect b = g->boxes[i];
        if (rh(b) < 5 || rh(b) > 80 || rw(b) < 5) continue;
        all[n].kind = is_checkbox(b) ? SPDF_SNAP_CHECKBOX : SPDF_SNAP_BOX;
        all[n].rect = b;
        all[n].probe_x = (b.x0 + b.x1) * 0.5f, all[n++].probe_y = (b.y0 + b.y1) * 0.5f;
    }
    for (i = 0; i < g->comb_count; ++i) {
        spdf_snap_comb c = g->combs[i];
        all[n].kind = SPDF_SNAP_COMB;
        all[n].rect = make_rect(c.cells[0].x0, c.cells[0].y0, c.cells[c.count - 1].x1, c.cells[c.count - 1].y1);
        all[n].probe_x = (c.cells[0].x0 + c.cells[0].x1) * 0.5f, all[n++].probe_y = (c.cells[0].y0 + c.cells[0].y1) * 0.5f;
    }
    for (i = 0; i < g->hline_count; ++i) {
        spdf_snap_hline l = g->hlines[i];
        if (l.x1 - l.x0 < 24 || l.x1 - l.x0 > 0.9f * rw(g->page) || rule_meets_vertical(g, l)) continue;
        all[n].kind = SPDF_SNAP_UNDERLINE;
        all[n].rect = make_rect(l.x0, l.y - 14, l.x1, l.y + 1);
        all[n].probe_x = l.x0 + 2, all[n++].probe_y = l.y - 3;
    }
    qsort(all, (size_t)n, sizeof(*all), cmp_target);
    for (start = 0; start < n;) { /* rows: centres within 4 pt, then left to right */
        int end = start + 1;
        float y0 = (all[start].rect.y0 + all[start].rect.y1) * 0.5f;
        while (end < n && (all[end].rect.y0 + all[end].rect.y1) * 0.5f - y0 <= 4) ++end;
        qsort(all + start, (size_t)(end - start), sizeof(*all), cmp_target_x);
        start = end;
    }
    for (i = 0; out && i < n && i < max; ++i) out[i] = all[i];
    free(all);
    return n;
}
