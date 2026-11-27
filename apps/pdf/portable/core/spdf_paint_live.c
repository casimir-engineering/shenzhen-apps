/* A stroke being drawn (spdf_paint.h, "A stroke being drawn"): what the release's paint.stroke or erase.lines will do,
 * shown while the button is held, so the release changes nothing on screen.
 *
 * Pixels: the stroke's coverage grows point by point (spdf_brush_run) and is laid into the active layer itself over
 * what changed, from the layer's own pixels as they were (kept per 256 x 256 tile the first time the stroke reaches
 * one), so every drawing of the canvas shows it through the usual compositing, layers above and below included. The
 * release lays the same coverage into the same pixels; anything else puts the pixels back first.
 * Lines: the pixel Eraser's cuts are worked out as the operation will cut (spdf_paint_line_cut) and the pieces drawn
 * in the line's place; the lines the whole-line eraser will take are not drawn. The objects themselves are left
 * alone until the release. */
#include "spdf_paint_brush_engine.h"
#include "spdf_paint_model.h"
#include "spdf_paint_written.h"
#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>


typedef struct live_line {
    spdf_paint_id id;
    spdf_paint_object** pieces; /* what the pixel Eraser leaves of it */
    int count;
    int cut, faded; /* faded: taken by the whole-line eraser, not drawn */
} live_line;

typedef struct spdf_paint_live spdf_paint_live;
struct spdf_paint_live {
    int lines_only;               /* erase.lines */
    float size;                   /* the eraser's size, canvas units */
    spdf_paint_stroke_args args;  /* paint.stroke's, its points apart */
    spdf_paint_id layer;
    float scale;                  /* raster pixels per canvas unit */
    spdf_brush_run* run;
    spdf_brush_mask committed, shown; /* over the layer's pixels */
    spdf_brush_lay_mode mode;
    spdf_paint_color color;
    unsigned char** saved;        /* the layer's pixels before the stroke, per tile */
    int tiles_x, tiles_y;
    fz_irect laid;                /* where the stroke is laid in the layer */
    fz_irect used;                /* a PDF page: the layer's painted box, as its write back will find it */
    int used_moved;               /* ... changed: the reader draws the whole layer's part of what it redraws anew */
    fz_irect marked;              /* raster pixels the stroke covers: what the release reports changed */
    spdf_rect lines_changed;      /* the lines it cuts or takes, as the release reports them */
    spdf_paint_written_picture picture; /* a PDF page: the layer as it will be written (spdf_paint_written.h) */
    spdf_rect crop;               /* ... and the part the reader's release draws again, at crop_scale */
    float crop_scale;
    fz_pixmap* paper;             /* the page over that part, drawn whole (spdf_paint_live_paper) */
    spdf_paint_point* points;
    int count, cap;
    live_line* lines;
    int line_count, line_cap;
};

static fz_irect join(fz_irect a, fz_irect b) {
    if (fz_is_empty_irect(a)) return b;
    if (fz_is_empty_irect(b)) return a;
    return fz_make_irect(a.x0 < b.x0 ? a.x0 : b.x0, a.y0 < b.y0 ? a.y0 : b.y0, a.x1 > b.x1 ? a.x1 : b.x1,
                         a.y1 > b.y1 ? a.y1 : b.y1);
}

static spdf_rect join_rect(spdf_rect a, spdf_rect b) {
    if (a.x1 <= a.x0 || a.y1 <= a.y0) return b;
    if (b.x1 <= b.x0 || b.y1 <= b.y0) return a;
    return (spdf_rect){fminf(a.x0, b.x0), fminf(a.y0, b.y0), fmaxf(a.x1, b.x1), fmaxf(a.y1, b.y1)};
}

static spdf_paint_layer* live_layer(spdf_paint_doc* doc) {
    spdf_paint_layer* layer = doc->live ? spdf_paint_layer_find(doc, doc->live->layer) : NULL;
    return layer && layer->pixels && layer->pixels->n == 4 ? layer : NULL;
}

/* ---- The layer's pixels ---- */

static void each_tile(spdf_paint_live* live, fz_irect box, fz_pixmap* pix, int save, int restore) {
    const int T = SPDF_PAINT_TILE_SIZE;
    box = fz_intersect_irect(box, fz_make_irect(0, 0, pix->w, pix->h));
    if (fz_is_empty_irect(box)) return;
    for (int ty = box.y0 / T; ty * T < box.y1 && ty < live->tiles_y; ty++)
        for (int tx = box.x0 / T; tx * T < box.x1 && tx < live->tiles_x; tx++) {
            unsigned char** tile = &live->saved[ty * live->tiles_x + tx];
            fz_irect part = fz_intersect_irect(box, fz_make_irect(tx * T, ty * T, tx * T + T, ty * T + T));
            if (save && !*tile) {
                fz_irect all = fz_intersect_irect(fz_make_irect(tx * T, ty * T, tx * T + T, ty * T + T),
                                                  fz_make_irect(0, 0, pix->w, pix->h));
                *tile = malloc((size_t)T * T * 4);
                if (!*tile) continue;
                for (int y = all.y0; y < all.y1; y++)
                    memcpy(*tile + (size_t)(y - ty * T) * T * 4 + (size_t)(all.x0 - tx * T) * 4,
                           pix->samples + (size_t)y * pix->stride + (size_t)all.x0 * 4, (size_t)(all.x1 - all.x0) * 4);
            }
            if (restore && *tile)
                for (int y = part.y0; y < part.y1; y++)
                    memcpy(pix->samples + (size_t)y * pix->stride + (size_t)part.x0 * 4,
                           *tile + (size_t)(y - ty * T) * T * 4 + (size_t)(part.x0 - tx * T) * 4,
                           (size_t)(part.x1 - part.x0) * 4);
        }
}

/* The composite tiles the core keeps (spdf_paint_composite.c) over box are drawn again on their next use. */
static void stale_tiles(spdf_paint_doc* doc, fz_irect box) {
    spdf_paint_tile_cache* cache = &doc->tiles;
    if (!cache->tiles || fz_is_empty_irect(box)) return;
    for (int ty = box.y0 / SPDF_PAINT_TILE_SIZE; ty < cache->tiles_y && ty * SPDF_PAINT_TILE_SIZE < box.y1; ty++)
        for (int tx = box.x0 / SPDF_PAINT_TILE_SIZE; tx < cache->tiles_x && tx * SPDF_PAINT_TILE_SIZE < box.x1; tx++)
            if (ty >= 0 && tx >= 0) cache->tiles[ty * cache->tiles_x + tx].valid = 0;
}

fz_irect spdf_paint_pixels_used(const fz_pixmap* p, fz_irect within) {
    fz_irect b = fz_empty_irect;
    within = fz_intersect_irect(within, fz_make_irect(0, 0, p->w, p->h));
    for (int y = within.y0; y < within.y1; ++y) {
        const unsigned char* row = p->samples + (size_t)y * p->stride + 3;
        for (int x = within.x0; x < within.x1; ++x)
            if (row[(size_t)x * 4]) {
                if (fz_is_empty_irect(b)) b = fz_make_irect(x, y, x + 1, y + 1);
                else {
                    if (x < b.x0) b.x0 = x;
                    if (x >= b.x1) b.x1 = x + 1;
                    b.y1 = y + 1;
                }
            }
    }
    return b;
}

int spdf_paint_live_used(const spdf_paint_doc* doc, const spdf_paint_layer* layer, fz_irect* used) {
    if (!doc->live || doc->live->layer != layer->id || doc->kind != SPDF_PAINT_DOC_PDF) return 0;
    *used = doc->live->used;
    return 1;
}

/* The stroke as shown, laid over `box` of the layer as it was. */
static void relay(spdf_paint_doc* doc, spdf_paint_live* live, fz_irect box) {
    spdf_paint_layer* layer = live_layer(doc);
    if (!layer || fz_is_empty_irect(box)) return;
    each_tile(live, box, layer->pixels, 1, 1);
    box = fz_intersect_irect(box, fz_make_irect(0, 0, layer->pixels->w, layer->pixels->h));
    { /* what the stroke covers, as spdf_paint_brush_lay_mask will find it: only a change at its edge or past it moves
       * it (the end of a stroke being drawn may draw back) */
        fz_irect m = live->marked, scan = fz_is_empty_irect(m) || box.x0 <= m.x0 || box.y0 <= m.y0 || box.x1 >= m.x1 ||
                                                  box.y1 >= m.y1 ? join(m, box) : fz_empty_irect;
        if (!fz_is_empty_irect(scan)) live->marked = fz_empty_irect;
        for (int y = scan.y0; y < scan.y1; ++y)
            for (int x = scan.x0; x < scan.x1; ++x)
                if (live->shown.a[(size_t)(y - live->shown.box.y0) * live->shown.w + (size_t)(x - live->shown.box.x0)])
                    live->marked = join(live->marked, fz_make_irect(x, y, x + 1, y + 1));
    }
    spdf_brush_lay(layer->pixels, &live->shown, box, live->mode, live->color, live->args.color2,
                   fminf(fmaxf(live->args.opacity, 0), 1), live->args.mask);
    live->laid = join(live->laid, box);
    live->picture.stale = join(live->picture.stale, box);
    stale_tiles(doc, box);
    if (doc->kind == SPDF_PAINT_DOC_PDF) { /* the painted box: only a change at its edge or past it moves it */
        fz_irect u = live->used;
        if (fz_is_empty_irect(u) || box.x0 <= u.x0 || box.y0 <= u.y0 || box.x1 >= u.x1 || box.y1 >= u.y1)
            live->used = spdf_paint_pixels_used(layer->pixels, join(u, box));
        if (memcmp(&u, &live->used, sizeof(u))) live->used_moved = 1;
    }
}

static void free_live(spdf_paint_doc* doc, spdf_paint_live* live) {
    fz_context* ctx = doc->ctx;
    for (int i = 0; i < live->tiles_x * live->tiles_y && live->saved; i++) free(live->saved[i]);
    free(live->saved);
    spdf_brush_run_drop(ctx, live->run);
    spdf_brush_mask_drop(ctx, &live->committed);
    spdf_brush_mask_drop(ctx, &live->shown);
    spdf_paint_written_picture_drop(ctx, &live->picture);
    fz_drop_pixmap(ctx, live->paper);
    for (int i = 0; i < live->line_count; i++) spdf_paint_line_pieces_free(ctx, live->lines[i].pieces, live->lines[i].count);
    free(live->lines);
    free(live->points);
    free(live);
}

/* Everything back as it was; what changed on screen (canvas units) into *changed. */
static void put_back(spdf_paint_doc* doc, spdf_rect* changed) {
    spdf_paint_live* live = doc->live;
    spdf_paint_layer* layer = live_layer(doc);
    spdf_rect all = {0, 0, 0, 0};
    if (!live) return;
    if (layer) each_tile(live, live->laid, layer->pixels, 0, 1);
    stale_tiles(doc, live->laid);
    if (!fz_is_empty_irect(live->laid))
        all = (spdf_rect){live->laid.x0 / live->scale, live->laid.y0 / live->scale, live->laid.x1 / live->scale,
                          live->laid.y1 / live->scale};
    for (int i = 0; i < live->line_count; i++) {
        spdf_paint_layer* l = spdf_paint_layer_find(doc, live->lines[i].id);
        if (!l || !l->object) continue;
        float grow = l->object->u.line.width / 2 + 26;
        spdf_rect b = l->object->bounds;
        all = join_rect(all, (spdf_rect){b.x0 - grow, b.y0 - grow, b.x1 + grow, b.y1 + grow});
    }
    if (live->line_count) stale_tiles(doc, spdf_paint_raster_box(doc, all));
    if (changed) *changed = all;
    doc->live = NULL;
    free_live(doc, live);
}

void spdf_paint_live_settle(spdf_paint_doc* doc) {
    if (doc && doc->live) put_back(doc, NULL);
}

void spdf_paint_live_cancel(spdf_paint_doc* doc, spdf_rect* changed) {
    if (changed) *changed = (spdf_rect){0, 0, 0, 0};
    if (doc && doc->live) put_back(doc, changed);
}

int spdf_paint_live_active(const spdf_paint_doc* doc) { return doc && doc->live; }

spdf_paint_written_picture* spdf_paint_live_picture(spdf_paint_doc* doc, const spdf_paint_layer* layer) {
    return doc && doc->live && !doc->live->lines_only && layer && doc->live->layer == layer->id ? &doc->live->picture
                                                                                                 : NULL;
}

void spdf_paint_live_set_reader_crop(spdf_paint_doc* doc, spdf_rect region, float scale) {
    if (doc && doc->live) doc->live->crop = region, doc->live->crop_scale = scale;
}

int spdf_paint_live_reader_crop(const spdf_paint_doc* doc, float scale, fz_irect* crop) {
    const spdf_paint_live* live = doc ? doc->live : NULL;
    spdf_rect r = live ? live->crop : (spdf_rect){0, 0, 0, 0};
    if (!live || fabsf(live->crop_scale - scale) > 1e-4f || r.x1 <= r.x0 || r.y1 <= r.y0) return 0;
    const float e = 1e-3f; /* on the pixels spdf_paint_render_placed draws the region on */
    crop->x0 = (int)floorf(r.x0 * scale + e), crop->y0 = (int)floorf(r.y0 * scale + e);
    crop->x1 = crop->x0 + (int)ceilf((r.x1 - r.x0) * scale - e), crop->y1 = crop->y0 + (int)ceilf((r.y1 - r.y0) * scale - e);
    return 1;
}

fz_pixmap* spdf_paint_live_paper(spdf_paint_doc* doc, float scale, fz_irect box) {
    fz_irect crop;
    spdf_paint_live* live = doc ? doc->live : NULL;
    if (!live || !doc->pdf || !spdf_paint_live_reader_crop(doc, scale, &crop) || box.x0 < crop.x0 ||
        box.y0 < crop.y0 || box.x1 > crop.x1 || box.y1 > crop.y1)
        return NULL;
    fz_pixmap* p = live->paper;
    if (p && p->x == crop.x0 && p->y == crop.y0 && p->w == crop.x1 - crop.x0 && p->h == crop.y1 - crop.y0) return p;
    fz_drop_pixmap(doc->ctx, live->paper);
    live->paper = NULL;
    fz_try(doc->ctx) p = fz_new_pixmap_with_bbox(doc->ctx, fz_device_rgb(doc->ctx), crop, NULL, 0);
    fz_catch(doc->ctx) {
        fz_ignore_error(doc->ctx);
        return NULL;
    }
    if (!spdf_paint_pdf_draw_page(doc, fz_scale(scale, scale), p, crop, 0)) {
        fz_drop_pixmap(doc->ctx, p);
        return NULL;
    }
    return live->paper = p;
}

int spdf_paint_live_written(const spdf_paint_doc* doc, spdf_rect* changed) {
    spdf_paint_live* live = doc ? doc->live : NULL;
    *changed = (spdf_rect){0, 0, 0, 0};
    if (!live) return 0;
    if (!fz_is_empty_irect(live->marked))
        *changed = (spdf_rect){live->marked.x0 / live->scale, live->marked.y0 / live->scale,
                               live->marked.x1 / live->scale, live->marked.y1 / live->scale};
    *changed = join_rect(*changed, live->lines_changed);
    return changed->x1 > changed->x0;
}

int spdf_paint_live_lay(spdf_paint_doc* doc, spdf_paint_layer* layer, const spdf_paint_stroke_args* args,
                        spdf_rect* damage, spdf_paint_status* status) {
    spdf_paint_live* live = doc->live;
    const spdf_paint_stroke_args* a = live ? &live->args : NULL;
    int same = live && !live->lines_only && live->layer == layer->id && a->tool == args->tool &&
               a->color == args->color && a->color2 == args->color2 && a->size == args->size &&
               a->opacity == args->opacity && a->seed == args->seed && a->mask == args->mask &&
               live->count == args->point_count;
    for (int i = 0; same && i < live->count; i++)
        same = live->points[i].x == args->points[i].x && live->points[i].y == args->points[i].y &&
               live->points[i].pressure == args->points[i].pressure;
    if (!live) return 0;
    if (!same || !layer->pixels) {
        put_back(doc, NULL);
        return 0;
    }
    each_tile(live, live->laid, layer->pixels, 0, 1); /* as it was, so the history keeps the pixels before */
    *status = spdf_paint_brush_lay_mask(doc, layer, args, &live->shown, live->laid, damage);
    doc->live = NULL;
    free_live(doc, live);
    return 1;
}

/* ---- Starting, and each new point ---- */

spdf_paint_status spdf_paint_live_begin(spdf_paint_doc* doc, const char* op_json, char* err, size_t err_len) {
    if (!doc || !doc->ctx) return SPDF_PAINT_ERR_FAILED;
    spdf_paint_live_settle(doc);
    cJSON* root = cJSON_Parse(op_json ? op_json : "");
    const char* name = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root, "op"));
    spdf_paint_live* live = calloc(1, sizeof(*live));
    spdf_paint_status st = SPDF_PAINT_OK;
    spdf_paint_layer* layer = NULL;
    if (!live) st = SPDF_PAINT_ERR_NO_MEMORY;
    else if (name && !strcmp(name, "erase.lines")) {
        double size = 10;
        const cJSON* v = cJSON_GetObjectItemCaseSensitive(root, "size");
        if (cJSON_IsNumber(v)) size = v->valuedouble;
        live->lines_only = 1, live->size = (float)size;
    } else if (!name || strcmp(name, "paint.stroke")) {
        st = SPDF_PAINT_ERR_INVALID_ARGUMENT;
    } else {
        spdf_paint_call call;
        memset(&call, 0, sizeof(call));
        call.doc = doc, call.args = root, call.op = spdf_paint_op_find("paint.stroke");
        spdf_paint_stroke_args_read(&call, &live->args);
        live->size = live->args.size;
        if (live->args.tool >= SPDF_PAINT_BRUSH_COUNT) st = SPDF_PAINT_ERR_INVALID_ARGUMENT;
        else if (!spdf_paint_active_pixels(doc, &layer) || !layer || layer->locked || layer->pixels->n != 4 ||
                 (doc->kind == SPDF_PAINT_DOC_PDF && layer->kind == SPDF_PAINT_LAYER_BACKGROUND))
            st = SPDF_PAINT_ERR_PAGE_LOCKED;
    }
    cJSON_Delete(root);
    if (st == SPDF_PAINT_OK && layer) {
        fz_irect box = fz_make_irect(0, 0, layer->pixels->w, layer->pixels->h);
        spdf_brush_job job;
        memset(&job, 0, sizeof(job));
        live->layer = layer->id;
        live->scale = doc->raster_scale > 0 ? (float)doc->raster_scale : 1.0f;
        job.tool = live->args.tool, job.size = fmaxf(live->args.size, 0.5f), job.seed = live->args.seed;
        job.to_device = fz_scale(live->scale, live->scale);
        live->mode = spdf_brush_lay_mode_for(doc, layer, &live->args, &live->color);
        live->tiles_x = (box.x1 + SPDF_PAINT_TILE_SIZE - 1) / SPDF_PAINT_TILE_SIZE;
        live->tiles_y = (box.y1 + SPDF_PAINT_TILE_SIZE - 1) / SPDF_PAINT_TILE_SIZE;
        live->saved = calloc((size_t)live->tiles_x * live->tiles_y, sizeof(*live->saved));
        live->laid = live->marked = live->picture.box = live->picture.stale = fz_empty_irect;
        live->used = doc->kind == SPDF_PAINT_DOC_PDF ? spdf_paint_pixels_used(layer->pixels, box) : fz_empty_irect;
        if (!live->saved || !spdf_brush_mask_init(doc->ctx, &live->committed, box) ||
            !spdf_brush_mask_init(doc->ctx, &live->shown, box) || !(live->run = spdf_brush_run_new(doc->ctx, &job, box)))
            st = SPDF_PAINT_ERR_NO_MEMORY;
    }
    if (st != SPDF_PAINT_OK) {
        if (live) free_live(doc, live);
        spdf_paint_set_error(err, err_len, st == SPDF_PAINT_ERR_NO_MEMORY ? "There isn't enough memory for this stroke."
                                           : st == SPDF_PAINT_ERR_PAGE_LOCKED ? "This layer can't be painted on."
                                                                              : "Only a stroke can be drawn live.");
        return st;
    }
    doc->live = live;
    if (doc->kind == SPDF_PAINT_DOC_PDF) spdf_paint_pdf_warm(doc); /* the reader's pictures as the preview draws them */
    return SPDF_PAINT_OK;
}

static live_line* line_entry(spdf_paint_live* live, spdf_paint_id id, int make) {
    for (int i = 0; i < live->line_count; i++)
        if (live->lines[i].id == id) return &live->lines[i];
    if (!make) return NULL;
    if (live->line_count == live->line_cap) {
        int cap = live->line_cap ? live->line_cap * 2 : 8;
        live_line* grown = realloc(live->lines, (size_t)cap * sizeof(*grown));
        if (!grown) return NULL;
        live->lines = grown, live->line_cap = cap;
    }
    live_line* e = &live->lines[live->line_count++];
    memset(e, 0, sizeof(*e));
    e->id = id;
    return e;
}

static spdf_fill_point* fill_points(const spdf_paint_point* p, int n) {
    spdf_fill_point* out = malloc((size_t)(n > 0 ? n : 1) * sizeof(*out));
    for (int i = 0; out && i < n; i++) out[i] = (spdf_fill_point){p[i].x, p[i].y};
    return out;
}

/* The pen lines and arrows the eraser reached with the points from `from` on: cut again (pixel Eraser), or taken
 * (whole lines), as the release's operation will. Returns what looks different (canvas units). */
static spdf_rect touch_lines(spdf_paint_doc* doc, spdf_paint_live* live, int from) {
    spdf_rect changed = {0, 0, 0, 0};
    spdf_fill_point* swath = fill_points(live->points, live->count);
    spdf_rect seg = spdf_paint_points_box(live->points + from, live->count - from);
    if (!swath) return changed;
    for (int i = 0; i < doc->layer_count; i++) {
        spdf_paint_layer* l = doc->layers[i];
        spdf_paint_object* o = l->object;
        if (l->kind != SPDF_PAINT_LAYER_OBJECT || !o || l->locked || (!live->lines_only && !l->visible) ||
            (o->kind != SPDF_PAINT_OBJ_PEN && o->kind != SPDF_PAINT_OBJ_ARROW) || o->u.line.point_count < 1)
            continue;
        float reach = live->size / 2 + o->u.line.width / 2 + 1, grow = o->u.line.width / 2 + 26;
        spdf_rect b = o->bounds;
        if (b.x1 <= b.x0 && b.y1 <= b.y0) b = spdf_paint_points_box(o->u.line.points, o->u.line.point_count);
        if (b.x1 < seg.x0 - reach || b.x0 > seg.x1 + reach || b.y1 < seg.y0 - reach || b.y0 > seg.y1 + reach) continue;
        spdf_rect shown = {b.x0 - grow, b.y0 - grow, b.x1 + grow, b.y1 + grow};
        if (live->lines_only) { /* as erase.lines: the line's own points, against the whole path */
            spdf_fill_point* line = fill_points(o->u.line.points, o->u.line.point_count);
            float d = line ? spdf_ink_polyline_distance(line, o->u.line.point_count, swath + from, live->count - from)
                           : 1e9f;
            free(line);
            live_line* e = d <= live->size / 2 + o->u.line.width / 2 ? line_entry(live, l->id, 1) : NULL;
            if (e && !e->faded) {
                spdf_paint_object_update_bounds(o); /* as the release's deletion reports it: the reader draws it again */
                e->faded = 1, changed = join_rect(changed, shown);
                live->lines_changed = join_rect(live->lines_changed, o->bounds);
                stale_tiles(doc, spdf_paint_raster_box(doc, shown));
            }
            continue;
        }
        spdf_paint_object** pieces = NULL;
        int count = 0;
        if (!spdf_paint_line_cut(doc, o, swath, live->count, live->size / 2, &pieces, &count)) continue;
        live_line* e = line_entry(live, l->id, 1);
        if (!e) {
            spdf_paint_line_pieces_free(doc->ctx, pieces, count);
            continue;
        }
        spdf_paint_line_pieces_free(doc->ctx, e->pieces, e->count);
        e->pieces = pieces, e->count = count, e->cut = 1;
        changed = join_rect(changed, shown);
        live->lines_changed = join_rect(live->lines_changed, shown);
        stale_tiles(doc, spdf_paint_raster_box(doc, shown));
    }
    free(swath);
    return changed;
}

spdf_paint_status spdf_paint_live_add(spdf_paint_doc* doc, const float* xyp, int count, spdf_rect* changed) {
    spdf_paint_live* live = doc ? doc->live : NULL;
    spdf_rect all = {0, 0, 0, 0};
    if (changed) *changed = all;
    if (!live || !xyp || count < 1) return live ? SPDF_PAINT_OK : SPDF_PAINT_ERR_FAILED;
    if (live->count + count > live->cap) {
        int cap = live->cap ? live->cap * 2 : 256;
        while (cap < live->count + count) cap *= 2;
        spdf_paint_point* grown = realloc(live->points, (size_t)cap * sizeof(*grown));
        if (!grown) return SPDF_PAINT_ERR_NO_MEMORY;
        live->points = grown, live->cap = cap;
    }
    int from = live->count;
    for (int i = 0; i < count; i++)
        live->points[live->count++] = (spdf_paint_point){xyp[i * 3], xyp[i * 3 + 1], xyp[i * 3 + 2]};
    if (live->run) {
        fz_irect box = fz_empty_irect;
        spdf_brush_run_add(doc->ctx, live->run, live->points + from, count, &live->committed);
        spdf_brush_run_show(doc->ctx, live->run, &live->committed, &live->shown, &box);
        relay(doc, live, box);
        if (!fz_is_empty_irect(box))
            all = (spdf_rect){box.x0 / live->scale, box.y0 / live->scale, box.x1 / live->scale, box.y1 / live->scale};
    }
    if (live->lines_only || live->args.tool == SPDF_PAINT_BRUSH_ERASER)
        all = join_rect(all, touch_lines(doc, live, from > 0 ? from - 1 : 0));
    if (live->used_moved) { /* all the reader will draw again looks different */
        spdf_rect written;
        spdf_paint_live_written(doc, &written);
        all = join_rect(all, written);
        live->used_moved = 0;
    }
    if (changed) *changed = all;
    return SPDF_PAINT_OK;
}

/* ---- Drawing the lines it changes ---- */

int spdf_paint_live_draw_object(spdf_paint_doc* doc, const spdf_paint_layer* layer, fz_matrix ctm, fz_pixmap* dest,
                                fz_irect clip, float opacity) {
    live_line* e = doc && doc->live && layer && layer->object ? line_entry(doc->live, layer->id, 0) : NULL;
    if (!e || (!e->cut && !e->faded)) return 0;
    if (e->faded) return 1; /* gone, as the release leaves it */
    for (int i = 0; i < e->count; i++) {
        if (doc->kind == SPDF_PAINT_DOC_PDF) spdf_paint_draw_line_as_written(doc, e->pieces[i], ctm, dest, clip, opacity);
        else spdf_paint_object_draw(doc, e->pieces[i], ctm, dest, clip, opacity);
    }
    return 1;
}
