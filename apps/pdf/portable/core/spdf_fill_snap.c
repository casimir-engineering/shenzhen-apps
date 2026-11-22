/* spdf_fill_snap.c -- reads a page's rules, boxes and text once for Fill & Sign snapping (spdf_fill_snap.h).
 * spdf_fill_snap_clean.c tidies what it read; placement from that geometry is spdf_fill_snap_place.c. */
#include "spdf_fill_snap.h"
#include "spdf_core_document.h"
#include "spdf_fill_snap_internal.h"

#include "mupdf/pdf.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { SUBPATH_POINTS = 64, RUN_TEXT = 120, MAX_RUNS = 20000, MAX_BOXES = 20000 };
#define AXIS_SLOP 0.5f    /* a rule is horizontal when its ends differ by at most this in y */
#define MAX_STROKE 3.0f   /* thicker strokes are decoration, not rules */
#define THIN_FILL 2.5f    /* a filled rectangle this thin is a rule */

typedef struct {
    fz_device super;
    spdf_snap_geometry* g;
    int hcap, vcap, bcap, rcap;
    int segments, max_segments;
    /* the text run being built */
    int run_open, run_len;
    char run_text[RUN_TEXT + 8];
    fz_rect run_rect;
    float run_baseline, run_size, run_end;
    /* leaders: ____ and ..... */
    int lead_count, lead_char;
    float lead_x0, lead_x1, lead_baseline, lead_size;
    /* "[ ]" */
    int bracket_open;
    float bracket_x0, bracket_baseline;
    /* targets read from text (leaders, ballot boxes, "[ ]"): kept apart, as they survive the segment budget */
    spdf_snap_hline* text_lines;
    int text_line_count, text_line_cap;
    spdf_rect* text_boxes;
    int text_box_count, text_box_cap;
} snap_device;

#define GROW(ctx, arr, count, cap, type)                                                                              \
    do {                                                                                                              \
        if ((count) >= (cap)) {                                                                                       \
            int next_cap = (cap) ? (cap) * 2 : 64;                                                                    \
            type* grown = (type*)realloc((arr), (size_t)next_cap * sizeof(type)); /* freed with free() */         \
            if (!grown) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");                                              \
            (arr) = grown;                                                                                            \
            (cap) = next_cap;                                                                                         \
        }                                                                                                             \
    } while (0)

static void add_hline(fz_context* ctx, snap_device* d, float x0, float x1, float y) {
    if (d->g->truncated) return;
    if (++d->segments > d->max_segments) {
        d->g->truncated = 1;
        return;
    }
    GROW(ctx, d->g->hlines, d->g->hline_count, d->hcap, spdf_snap_hline);
    d->g->hlines[d->g->hline_count].x0 = fminf(x0, x1);
    d->g->hlines[d->g->hline_count].x1 = fmaxf(x0, x1);
    d->g->hlines[d->g->hline_count++].y = y;
}

static void add_vline(fz_context* ctx, snap_device* d, float x, float y0, float y1) {
    if (d->g->truncated) return;
    if (++d->segments > d->max_segments) {
        d->g->truncated = 1;
        return;
    }
    GROW(ctx, d->g->vlines, d->g->vline_count, d->vcap, spdf_snap_vline);
    d->g->vlines[d->g->vline_count].x = x;
    d->g->vlines[d->g->vline_count].y0 = fminf(y0, y1);
    d->g->vlines[d->g->vline_count++].y1 = fmaxf(y0, y1);
}

static void add_box(fz_context* ctx, snap_device* d, fz_rect r) {
    if (d->g->truncated || d->g->box_count >= MAX_BOXES) return;
    GROW(ctx, d->g->boxes, d->g->box_count, d->bcap, spdf_rect);
    d->g->boxes[d->g->box_count].x0 = r.x0, d->g->boxes[d->g->box_count].y0 = r.y0;
    d->g->boxes[d->g->box_count].x1 = r.x1, d->g->boxes[d->g->box_count++].y1 = r.y1;
}

static void add_segment(fz_context* ctx, snap_device* d, fz_point a, fz_point b) {
    if (fabsf(a.y - b.y) <= AXIS_SLOP && fabsf(a.x - b.x) >= 2) add_hline(ctx, d, a.x, b.x, (a.y + b.y) * 0.5f);
    else if (fabsf(a.x - b.x) <= AXIS_SLOP && fabsf(a.y - b.y) >= 2) add_vline(ctx, d, (a.x + b.x) * 0.5f, a.y, b.y);
}

/* A filled or stroked axis-aligned rectangle: thin ones are rules, others boxes (stroked) or ignored (filled). */
static void add_rect(fz_context* ctx, snap_device* d, fz_rect r, int stroke) {
    float w = r.x1 - r.x0, h = r.y1 - r.y0;
    if (h <= THIN_FILL && w >= 2) add_hline(ctx, d, r.x0, r.x1, (r.y0 + r.y1) * 0.5f);
    else if (w <= THIN_FILL && h >= 2) add_vline(ctx, d, (r.x0 + r.x1) * 0.5f, r.y0, r.y1);
    else if (stroke) add_box(ctx, d, r);
}

typedef struct {
    snap_device* d;
    fz_matrix ctm;
    int stroke, curved, closed, n;
    fz_point pts[SUBPATH_POINTS];
} path_walk;

static int axis_rect(const fz_point* p, int n, fz_rect* out) {
    int i;
    if (n == 5 && fabsf(p[4].x - p[0].x) <= AXIS_SLOP && fabsf(p[4].y - p[0].y) <= AXIS_SLOP) n = 4;
    if (n != 4) return 0;
    for (i = 0; i < 4; ++i) {
        fz_point a = p[i], b = p[(i + 1) % 4];
        if (fabsf(a.x - b.x) > AXIS_SLOP && fabsf(a.y - b.y) > AXIS_SLOP) return 0;
    }
    *out = fz_make_rect(fminf(fminf(p[0].x, p[1].x), p[2].x), fminf(fminf(p[0].y, p[1].y), p[2].y),
                        fmaxf(fmaxf(p[0].x, p[1].x), p[2].x), fmaxf(fmaxf(p[0].y, p[1].y), p[2].y));
    return out->x1 - out->x0 > 0.1f || out->y1 - out->y0 > 0.1f;
}

static void flush_subpath(fz_context* ctx, path_walk* w) {
    fz_rect r;
    int i;
    if (w->n >= 2 && !w->curved) {
        if (w->closed && axis_rect(w->pts, w->n, &r)) add_rect(ctx, w->d, r, w->stroke);
        else if (!w->closed && w->n == 5 && axis_rect(w->pts, w->n, &r)) add_rect(ctx, w->d, r, w->stroke);
        else if (w->stroke) {
            for (i = 1; i < w->n; ++i) add_segment(ctx, w->d, w->pts[i - 1], w->pts[i]);
            if (w->closed) add_segment(ctx, w->d, w->pts[w->n - 1], w->pts[0]);
        }
    }
    w->n = 0, w->curved = 0, w->closed = 0;
}

static void walk_moveto(fz_context* ctx, void* arg, float x, float y) {
    path_walk* w = (path_walk*)arg;
    flush_subpath(ctx, w);
    w->pts[w->n++] = fz_transform_point(fz_make_point(x, y), w->ctm);
}

static void walk_lineto(fz_context* ctx, void* arg, float x, float y) {
    path_walk* w = (path_walk*)arg;
    if (w->n == SUBPATH_POINTS) { /* a long polyline is never a box: emit what we have and carry on */
        fz_point last = w->pts[w->n - 1];
        int i;
        if (w->stroke && !w->curved)
            for (i = 1; i < w->n; ++i) add_segment(ctx, w->d, w->pts[i - 1], w->pts[i]);
        w->n = 0;
        w->pts[w->n++] = last;
    }
    w->pts[w->n++] = fz_transform_point(fz_make_point(x, y), w->ctm);
}

static void walk_curveto(fz_context* ctx, void* arg, float x1, float y1, float x2, float y2, float x3, float y3) {
    path_walk* w = (path_walk*)arg;
    (void)x1, (void)y1, (void)x2, (void)y2;
    w->curved = 1;
    walk_lineto(ctx, arg, x3, y3);
}

static void walk_closepath(fz_context* ctx, void* arg) {
    path_walk* w = (path_walk*)arg;
    w->closed = 1;
    flush_subpath(ctx, w);
}

static void walk_rectto(fz_context* ctx, void* arg, float x0, float y0, float x1, float y1) {
    path_walk* w = (path_walk*)arg;
    fz_point a = fz_transform_point(fz_make_point(x0, y0), w->ctm), c = fz_transform_point(fz_make_point(x1, y1), w->ctm);
    fz_point b = fz_transform_point(fz_make_point(x1, y0), w->ctm);
    flush_subpath(ctx, w);
    if ((fabsf(a.x - b.x) <= AXIS_SLOP || fabsf(a.y - b.y) <= AXIS_SLOP))
        add_rect(ctx, w->d, fz_make_rect(fminf(a.x, c.x), fminf(a.y, c.y), fmaxf(a.x, c.x), fmaxf(a.y, c.y)), w->stroke);
}

static const fz_path_walker snap_walker = {walk_moveto, walk_lineto, walk_curveto, walk_closepath,
                                           NULL,        NULL,        NULL,         walk_rectto};

static void run_path(fz_context* ctx, snap_device* d, const fz_path* path, fz_matrix ctm, int stroke) {
    path_walk w;
    if (d->g->truncated) return;
    memset(&w, 0, sizeof(w));
    w.d = d, w.ctm = ctm, w.stroke = stroke;
    fz_walk_path(ctx, path, &snap_walker, &w);
    flush_subpath(ctx, &w);
}

static void dev_fill_path(fz_context* ctx, fz_device* dev, const fz_path* path, int even_odd, fz_matrix ctm,
                          fz_colorspace* cs, const float* color, float alpha, fz_color_params params) {
    (void)even_odd, (void)cs, (void)color, (void)params;
    if (alpha > 0.05f) run_path(ctx, (snap_device*)dev, path, ctm, 0);
}

static void dev_stroke_path(fz_context* ctx, fz_device* dev, const fz_path* path, const fz_stroke_state* stroke,
                            fz_matrix ctm, fz_colorspace* cs, const float* color, float alpha, fz_color_params params) {
    (void)cs, (void)color, (void)params;
    if (alpha > 0.05f && stroke->linewidth * fz_matrix_expansion(ctm) <= MAX_STROKE)
        run_path(ctx, (snap_device*)dev, path, ctm, 1);
}

/* -- text ------------------------------------------------------------------------------------------------------- */

static void flush_run(fz_context* ctx, snap_device* d) {
    spdf_snap_text_run* run;
    if (!d->run_open) return;
    d->run_open = 0;
    if (d->run_len == 0 || d->g->run_count >= MAX_RUNS) return;
    GROW(ctx, d->g->runs, d->g->run_count, d->rcap, spdf_snap_text_run);
    run = &d->g->runs[d->g->run_count];
    memset(run, 0, sizeof(*run));
    run->text = (char*)malloc((size_t)d->run_len + 1);
    if (!run->text) return;
    memcpy(run->text, d->run_text, (size_t)d->run_len);
    run->text[d->run_len] = 0;
    run->rect.x0 = d->run_rect.x0, run->rect.y0 = d->run_rect.y0;
    run->rect.x1 = d->run_rect.x1, run->rect.y1 = d->run_rect.y1;
    run->baseline = d->run_baseline;
    run->size = d->run_size;
    d->g->run_count++;
}

/* Three underscores or five dots in a row make a line to write on. */
static void flush_leader(fz_context* ctx, snap_device* d) {
    int enough = d->lead_char == '_' ? d->lead_count >= 3 : d->lead_count >= 5;
    if (d->lead_count && enough) {
        spdf_snap_hline* l;
        GROW(ctx, d->text_lines, d->text_line_count, d->text_line_cap, spdf_snap_hline);
        l = &d->text_lines[d->text_line_count++];
        l->x0 = d->lead_x0, l->x1 = d->lead_x1;
        l->y = d->lead_baseline + (d->lead_char == '_' ? 0.12f * d->lead_size : 0.0f);
    }
    d->lead_count = 0;
}

static void add_text_box(fz_context* ctx, snap_device* d, float x0, float y0, float x1, float y1) {
    if (d->text_box_count >= MAX_BOXES) return;
    GROW(ctx, d->text_boxes, d->text_box_count, d->text_box_cap, spdf_rect);
    d->text_boxes[d->text_box_count].x0 = x0, d->text_boxes[d->text_box_count].y0 = y0;
    d->text_boxes[d->text_box_count].x1 = x1, d->text_boxes[d->text_box_count++].y1 = y1;
}

static void add_glyph_box(fz_context* ctx, snap_device* d, float x0, float x1, float baseline, float size) {
    float side = fminf(x1 - x0, 0.75f * size);
    float cx = (x0 + x1) * 0.5f;
    add_text_box(ctx, d, cx - side * 0.5f, baseline - 0.1f * size - side, cx + side * 0.5f, baseline - 0.1f * size);
}

static void add_glyph(fz_context* ctx, snap_device* d, int ucs, fz_point origin, float width, float size) {
    float x1 = origin.x + width;
    int leader = ucs == '_' ? '_' : (ucs == '.' || ucs == 0x2026) ? '.' : 0;
    if (leader) {
        int dots = ucs == 0x2026 ? 3 : 1;
        if (d->lead_count && (d->lead_char != leader || fabsf(origin.y - d->lead_baseline) > 0.3f * size ||
                              origin.x - d->lead_x1 > 0.5f * size))
            flush_leader(ctx, d);
        if (!d->lead_count) {
            flush_run(ctx, d);
            d->lead_char = leader, d->lead_x0 = origin.x, d->lead_baseline = origin.y, d->lead_size = size;
        }
        d->lead_count += dots;
        d->lead_x1 = x1;
        return;
    }
    if (d->lead_count) flush_leader(ctx, d);
    if (ucs == 0x2610 || ucs == 0x25A1 || ucs == 0x25A2 || ucs == 0x274F) {
        add_glyph_box(ctx, d, origin.x, x1, origin.y, size);
        flush_run(ctx, d);
        return;
    }
    if (ucs == '[') d->bracket_open = 1, d->bracket_x0 = origin.x, d->bracket_baseline = origin.y;
    else if (ucs == ']' && d->bracket_open && fabsf(origin.y - d->bracket_baseline) < 0.3f * size &&
             x1 - d->bracket_x0 < 2.5f * size) {
        add_text_box(ctx, d, d->bracket_x0, origin.y - 0.75f * size, x1, origin.y + 0.2f * size);
        d->bracket_open = 0;
    } else if (ucs != ' ') d->bracket_open = 0;

    if (d->run_open && (fabsf(origin.y - d->run_baseline) > 0.3f * size || origin.x < d->run_end - 0.5f * size ||
                        origin.x - d->run_end > 2.5f * size))
        flush_run(ctx, d);
    if (!d->run_open) {
        if (ucs == ' ') return;
        d->run_open = 1, d->run_len = 0, d->run_baseline = origin.y, d->run_size = size;
        d->run_rect = fz_make_rect(origin.x, origin.y - 0.8f * size, x1, origin.y + 0.2f * size);
    } else if (origin.x - d->run_end > 0.6f * size && d->run_len < RUN_TEXT && d->run_text[d->run_len - 1] != ' ') {
        d->run_text[d->run_len++] = ' ';
    }
    if (d->run_len < RUN_TEXT) d->run_len += fz_runetochar(d->run_text + d->run_len, ucs);
    d->run_rect = fz_include_point_in_rect(d->run_rect, fz_make_point(x1, origin.y + 0.2f * size));
    d->run_rect = fz_include_point_in_rect(d->run_rect, fz_make_point(origin.x, origin.y - 0.8f * size));
    d->run_end = x1;
    if (size > d->run_size) d->run_size = size;
}

static void run_text(fz_context* ctx, snap_device* d, const fz_text* text, fz_matrix ctm) {
    const fz_text_span* span;
    int i;
    for (span = text->head; span; span = span->next) {
        fz_matrix trm = fz_concat(span->trm, ctm);
        float size = fz_matrix_expansion(trm);
        if (span->wmode || size < 1 || trm.a <= 0 || fabsf(trm.b) > 0.1f * size || fabsf(trm.c) > 0.1f * size) continue;
        for (i = 0; i < span->len; ++i) {
            const fz_text_item* it = &span->items[i];
            if (it->ucs < 0) continue;
            add_glyph(ctx, d, it->ucs, fz_transform_point(fz_make_point(it->x, it->y), ctm), it->adv * trm.a, size);
        }
    }
}

static void dev_fill_text(fz_context* ctx, fz_device* dev, const fz_text* text, fz_matrix ctm, fz_colorspace* cs,
                          const float* color, float alpha, fz_color_params params) {
    (void)cs, (void)color, (void)alpha, (void)params;
    run_text(ctx, (snap_device*)dev, text, ctm);
}

static void dev_ignore_text(fz_context* ctx, fz_device* dev, const fz_text* text, fz_matrix ctm) {
    run_text(ctx, (snap_device*)dev, text, ctm); /* invisible text: an OCR layer still names the fields */
}

/* -- clean-up after the pass ------------------------------------------------------------------------------------ */

/* Past the segment budget the drawing is only partly read: drop it and keep what the text gave. */
static void take_text_targets(fz_context* ctx, snap_device* d) {
    spdf_snap_geometry* g = d->g;
    int i;
    if (g->truncated) g->hline_count = g->vline_count = g->box_count = 0;
    for (i = 0; i < d->text_line_count; ++i) {
        GROW(ctx, g->hlines, g->hline_count, d->hcap, spdf_snap_hline);
        g->hlines[g->hline_count++] = d->text_lines[i];
    }
    for (i = 0; i < d->text_box_count; ++i) {
        GROW(ctx, g->boxes, g->box_count, d->bcap, spdf_rect);
        g->boxes[g->box_count++] = d->text_boxes[i];
    }
}

static void read_widgets(fz_context* ctx, fz_page* page, spdf_snap_geometry* g) {
    pdf_page* pdf = pdf_page_from_fz_page(ctx, page);
    pdf_annot* w;
    int n = 0;
    if (!pdf) return;
    for (w = pdf_first_widget(ctx, pdf); w; w = pdf_next_widget(ctx, w)) ++n;
    if (!n) return;
    g->widgets = (spdf_rect*)malloc((size_t)n * sizeof(spdf_rect));
    if (!g->widgets) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    for (w = pdf_first_widget(ctx, pdf); w && g->widget_count < n; w = pdf_next_widget(ctx, w)) {
        fz_rect r = pdf_bound_widget(ctx, w);
        spdf_rect* out = &g->widgets[g->widget_count++];
        out->x0 = r.x0, out->y0 = r.y0, out->x1 = r.x1, out->y1 = r.y1;
    }
}

void spdf_snap_geometry_free(spdf_snap_geometry* g) {
    int i;
    if (!g) return;
    for (i = 0; i < g->run_count; ++i) free(g->runs[i].text);
    for (i = 0; i < g->comb_count; ++i) free(g->combs[i].cells);
    free(g->hlines), free(g->vlines), free(g->boxes), free(g->combs), free(g->runs), free(g->widgets);
    memset(g, 0, sizeof(*g));
}

int spdf_snap_geometry_load(spdf_document* doc, int page_index, int max_segments, spdf_render_token* cancel,
                            spdf_snap_geometry* out, char* err, size_t err_len) {
    fz_page* volatile page = NULL;
    snap_device* volatile dev = NULL;
    fz_cookie local;
    fz_cookie* cookie = cancel ? &cancel->cookie : &local;
    volatile int cancelled = 0;

    if (err && err_len) err[0] = 0;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    memset(&local, 0, sizeof(local));
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        if (err && err_len) snprintf(err, err_len, "Page index is out of range.");
        return -1;
    }
    out->page_index = page_index;
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        fz_rect bounds;
        page = fz_load_page(ctx, doc->doc, page_index);
        bounds = fz_bound_page(ctx, page);
        out->page.x0 = bounds.x0, out->page.y0 = bounds.y0, out->page.x1 = bounds.x1, out->page.y1 = bounds.y1;
        dev = fz_new_derived_device(ctx, snap_device);
        dev->super.fill_path = dev_fill_path;
        dev->super.stroke_path = dev_stroke_path;
        dev->super.fill_text = dev_fill_text;
        dev->super.ignore_text = dev_ignore_text;
        dev->g = out;
        dev->max_segments = max_segments > 0 ? max_segments : 50000;
        fz_run_page_contents(ctx, page, &dev->super, fz_identity, cookie);
        flush_leader(ctx, dev);
        flush_run(ctx, dev);
        fz_close_device(ctx, &dev->super);
        cancelled = cookie->abort != 0;
        if (!cancelled) {
            take_text_targets(ctx, dev);
            read_widgets(ctx, page, out);
            spdf_snap_finish_geometry(ctx, out);
        }
    }
    fz_always(doc->ctx) {
        if (dev) free(dev->text_lines), free(dev->text_boxes);
        fz_drop_device(doc->ctx, (fz_device*)dev);
        fz_drop_page(doc->ctx, page);
    }
    fz_catch(doc->ctx) {
        cancelled = cookie->abort != 0;
        if (!cancelled && err && err_len) snprintf(err, err_len, "%s", fz_caught_message(doc->ctx));
        spdf_snap_geometry_free(out);
        return cancelled ? 0 : -1;
    }
    if (cancelled) {
        spdf_snap_geometry_free(out);
        return 0;
    }
    return 1;
}
