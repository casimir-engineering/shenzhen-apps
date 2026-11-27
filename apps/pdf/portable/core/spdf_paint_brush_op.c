/* The paint.stroke operation (docs/plans/annotate.md § 6 Pixels): Pencil, the nine brushes, Airbrush, Eraser and
 * Color Eraser into the active layer (on a PDF page Layer 1 or the one the person picked; never the page, nor a locked
 * layer), clipped to the selection when there is one. The pixel Eraser also cuts the pen lines and arrows it crosses,
 * as Fill & Sign's "Parts" eraser does: what it rubs out of a line is gone, the pieces left stay lines at the same
 * depth, an arrow keeps its head on the piece that still ends at its tip. */
#include "spdf_paint_brush_engine.h"
#include "spdf_paint_handlers.h"
#include "spdf_paint_model.h"
#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

static const char* const k_tools[SPDF_PAINT_BRUSH_COUNT] = {
    "pencil", "brush", "calligraphy1", "calligraphy2", "airbrush", "oil", "crayon", "marker", "natural_pencil",
    "watercolor", "eraser", "color_eraser"};

static spdf_paint_brush tool_from_name(const char* name) {
    int i;
    for (i = 0; name && i < SPDF_PAINT_BRUSH_COUNT; ++i)
        if (!strcmp(name, k_tools[i])) return (spdf_paint_brush)i;
    return SPDF_PAINT_BRUSH_COUNT;
}

static spdf_rect line_bounds(const spdf_paint_point* p, int n) {
    spdf_rect r = {p[0].x, p[0].y, p[0].x, p[0].y};
    int i;
    for (i = 1; i < n; ++i) {
        r.x0 = fminf(r.x0, p[i].x), r.y0 = fminf(r.y0, p[i].y);
        r.x1 = fmaxf(r.x1, p[i].x), r.y1 = fmaxf(r.y1, p[i].y);
    }
    return r;
}

static void damage_line(spdf_paint_doc* doc, const spdf_paint_object* o) {
    spdf_rect b = o->bounds;
    float grow = o->u.line.width / 2 + 26; /* an arrow's head reaches up to 24 past its tip */
    if (b.x1 <= b.x0 && b.y1 <= b.y0 && o->u.line.point_count) b = line_bounds(o->u.line.points, o->u.line.point_count);
    spdf_paint_damage(doc, (spdf_rect){b.x0 - grow, b.y0 - grow, b.x1 + grow, b.y1 + grow});
}

static void set_line_points(fz_context* ctx, spdf_paint_object* o, const spdf_fill_point* p, int n) {
    int i;
    fz_free(ctx, o->u.line.points);
    o->u.line.points = fz_malloc(ctx, (size_t)n * sizeof(spdf_paint_point));
    o->u.line.point_count = n;
    for (i = 0; i < n; ++i) o->u.line.points[i] = (spdf_paint_point){p[i].x, p[i].y, 1};
    o->place.rect = line_bounds(o->u.line.points, n);
    spdf_paint_object_update_bounds(o);
}

/* Takes `layer` out of the stack and frees it; the history record made first keeps a copy for undo. */
static void unlink_layer(spdf_paint_doc* doc, spdf_paint_layer* layer) { spdf_paint_layer_delete(doc, layer); }

/* Moves the layer `id` to sit at index `to` (bottom = 0). */
static void place_layer(spdf_paint_doc* doc, spdf_paint_id id, int to) {
    int at = spdf_paint_layer_index(doc, id);
    spdf_paint_layer* l;
    if (at < 0 || to < 0 || to >= doc->layer_count || at == to) return;
    l = doc->layers[at];
    if (at < to) memmove(&doc->layers[at], &doc->layers[at + 1], (size_t)(to - at) * sizeof(doc->layers[0]));
    else memmove(&doc->layers[to + 1], &doc->layers[to], (size_t)(at - to) * sizeof(doc->layers[0]));
    doc->layers[to] = l;
}

/* A pen line on a picture or canvas as it is drawn (spdf_paint_composite.c's line_path: its own points joined by
 * flattened curves), and which of those points are its own. */
static spdf_fill_point* drawn_line(fz_context* ctx, const spdf_paint_object* o, int* count, unsigned char** own) {
    const spdf_paint_point* p = o->u.line.points;
    int n = o->u.line.point_count, cap = 1 + (n > 1 ? (n - 1) * 64 : 0), k = 0;
    spdf_fill_point* line = fz_malloc(ctx, (size_t)cap * sizeof(*line));
    *own = fz_calloc(ctx, (size_t)cap, 1);
    line[k] = (spdf_fill_point){p[0].x, p[0].y}, (*own)[k++] = 1;
    for (int i = 0; i + 1 < n; i++) {
        spdf_fill_point p0 = {p[i > 0 ? i - 1 : i].x, p[i > 0 ? i - 1 : i].y}, p1 = {p[i].x, p[i].y};
        spdf_fill_point p2 = {p[i + 1].x, p[i + 1].y}, p3 = {p[i + 2 < n ? i + 2 : i + 1].x, p[i + 2 < n ? i + 2 : i + 1].y};
        k += spdf_ink_flatten_segment(p0, p1, p2, p3, 0.2f, 4.0f, line + k, 64);
        (*own)[k - 1] = 1;
    }
    *count = k;
    return line;
}

/* A piece of a drawn line: its ends where the eraser stopped, and between them only the line's own points, so the
 * piece is drawn as the line was, but for the last bit before each cut. */
static int own_points(spdf_fill_point* run, int n, const spdf_fill_point* line, const unsigned char* own, int count,
                      int* from) {
    int k = 1, j = *from;
    for (int i = 1; i + 1 < n; i++) {
        while (j < count && (line[j].x != run[i].x || line[j].y != run[i].y)) j++;
        if (j < count && own[j]) run[k++] = run[i];
    }
    if (n > 1) run[k++] = run[n - 1];
    *from = j;
    return k;
}

int spdf_paint_line_cut(spdf_paint_doc* doc, const spdf_paint_object* o, const spdf_fill_point* swath, int swath_count,
                        float radius, spdf_paint_object*** out, int* out_count) {
    fz_context* ctx = doc->ctx;
    int arrow = o->kind == SPDF_PAINT_OBJ_ARROW, count = arrow && o->u.line.point_count > 2 ? 2 : o->u.line.point_count;
    int drawn = !arrow && doc->kind != SPDF_PAINT_DOC_PDF && count > 1; /* a PDF's lines are drawn point to point */
    int head_rubbed = 0, i, from = 0, ok;
    float reach = radius + o->u.line.width / 2;
    unsigned char* own = NULL;
    spdf_fill_point* line;
    spdf_ink_runs runs;
    spdf_fill_point* p;
    *out = NULL, *out_count = 0;
    if (count < 1) return 0;
    if (drawn) line = drawn_line(ctx, o, &count, &own);
    else {
        line = fz_malloc(ctx, (size_t)count * sizeof(spdf_fill_point));
        for (i = 0; i < count; ++i) line[i] = (spdf_fill_point){o->u.line.points[i].x, o->u.line.points[i].y};
    }
    if (arrow && count == 2) {
        spdf_fill_point head[3];
        spdf_ink_arrow_head(line[0], line[1], o->u.line.width, head);
        head_rubbed = spdf_ink_polyline_distance(head, 3, swath, swath_count) <= reach;
    }
    ok = spdf_ink_erase(line, count, swath, swath_count, reach, o->u.line.width, &runs);
    if (!ok || (!runs.touched && !head_rubbed)) {
        if (ok) spdf_ink_free_runs(&runs);
        fz_free(ctx, line), fz_free(ctx, own);
        return 0;
    }
    *out = fz_calloc(ctx, (size_t)(runs.run_count ? runs.run_count : 1), sizeof(**out));
    for (i = 0, p = runs.points; i < runs.run_count; p += runs.run_lengths[i], ++i) {
        int keeps_head = arrow && !head_rubbed && i == runs.run_count - 1 && runs.last_run_keeps_end;
        spdf_fill_point shaft[2] = {p[0], p[runs.run_lengths[i] - 1]};
        int n = keeps_head ? 2 : drawn ? own_points(p, runs.run_lengths[i], line, own, count, &from)
                                      : spdf_ink_simplify(p, runs.run_lengths[i], 0.05f);
        spdf_paint_object* piece = spdf_paint_object_clone(ctx, o);
        if (!piece) break;
        piece->kind = keeps_head ? SPDF_PAINT_OBJ_ARROW : SPDF_PAINT_OBJ_PEN;
        set_line_points(ctx, piece, keeps_head ? shaft : p, n);
        (*out)[(*out_count)++] = piece;
    }
    spdf_ink_free_runs(&runs);
    fz_free(ctx, line), fz_free(ctx, own);
    return 1;
}

void spdf_paint_line_pieces_free(fz_context* ctx, spdf_paint_object** pieces, int count) {
    for (int i = 0; i < count; i++) spdf_paint_object_free(ctx, pieces[i]);
    fz_free(ctx, pieces);
}

static int cut_line(spdf_paint_doc* doc, spdf_paint_layer* layer, const spdf_fill_point* swath, int swath_count,
                    float radius, int* order_saved) {
    fz_context* ctx = doc->ctx;
    spdf_paint_object* o = layer->object;
    spdf_paint_object** pieces = NULL;
    int count = 0, i, depth;
    if (!spdf_paint_line_cut(doc, o, swath, swath_count, radius, &pieces, &count)) return 0;
    damage_line(doc, o);
    if (doc->kind == SPDF_PAINT_DOC_PDF) spdf_paint_pdf_note_change(doc, layer);
    if (count == 0) {
        unlink_layer(doc, layer);
        spdf_paint_line_pieces_free(ctx, pieces, count);
        return 1;
    }
    spdf_paint_history_save_object(doc, layer);
    depth = spdf_paint_layer_index(doc, layer->id);
    for (i = 0; i < count; ++i) {
        spdf_paint_object* piece = o;
        spdf_paint_id id = layer->id;
        if (i > 0) {
            piece = spdf_paint_object_new(doc, pieces[i]->kind, &id);
            if (!piece) break;
            piece->u.line.color = o->u.line.color, piece->u.line.width = o->u.line.width;
            if (!*order_saved) spdf_paint_history_save_order(doc), *order_saved = 1;
            place_layer(doc, id, depth + i); /* the pieces keep the line's depth */
        }
        piece->kind = pieces[i]->kind;
        fz_free(ctx, piece->u.line.points);
        piece->u.line.points = spdf_paint_points_copy(ctx, pieces[i]->u.line.points, pieces[i]->u.line.point_count);
        piece->u.line.point_count = pieces[i]->u.line.point_count;
        piece->place.rect = pieces[i]->place.rect;
        spdf_paint_object_update_bounds(piece);
        damage_line(doc, piece);
        if (doc->kind == SPDF_PAINT_DOC_PDF) {
            spdf_paint_layer* l = spdf_paint_layer_find(doc, id);
            if (l) spdf_paint_pdf_note_change(doc, l);
        }
    }
    snprintf(layer->name, sizeof(layer->name), "%s", o->kind == SPDF_PAINT_OBJ_ARROW ? "Arrow" : "Pen line");
    spdf_paint_line_pieces_free(ctx, pieces, count);
    return 1;
}

/* The pen lines and arrows the pixel Eraser crossed, cut; returns how many lines changed. */
static int cut_pen_lines(spdf_paint_doc* doc, const spdf_paint_point* points, int n, float size) {
    fz_context* ctx = doc->ctx;
    spdf_fill_point* swath = fz_malloc(ctx, (size_t)n * sizeof(spdf_fill_point));
    spdf_paint_id* ids;
    int i, changed = 0, lines = 0, order_saved = 0;
    for (i = 0; i < n; ++i) swath[i] = (spdf_fill_point){points[i].x, points[i].y};
    ids = fz_malloc(ctx, (size_t)(doc->layer_count + 1) * sizeof(spdf_paint_id));
    for (i = 0; i < doc->layer_count; ++i) { /* the lines as they are now; cutting adds pieces we must not revisit */
        spdf_paint_layer* l = doc->layers[i];
        if (l->kind == SPDF_PAINT_LAYER_OBJECT && l->object && l->visible && !l->locked &&
            (l->object->kind == SPDF_PAINT_OBJ_PEN || l->object->kind == SPDF_PAINT_OBJ_ARROW))
            ids[lines++] = l->id;
    }
    for (i = 0; i < lines; ++i) {
        spdf_paint_layer* l = spdf_paint_layer_find(doc, ids[i]);
        if (l) changed += cut_line(doc, l, swath, n, size / 2, &order_saved);
    }
    fz_free(ctx, ids);
    fz_free(ctx, swath);
    return changed;
}

int spdf_paint_stroke_args_read(spdf_paint_call* call, spdf_paint_stroke_args* args) {
    spdf_paint_doc* doc = call->doc;
    double v;
    int seeded;
    memset(args, 0, sizeof(*args));
    args->tool = tool_from_name(spdf_paint_arg_string(call, "tool"));
    if (!spdf_paint_arg_color(call, "color", &args->color)) args->color = doc->color1;
    args->color2 = doc->color2;
    args->size = args->tool == SPDF_PAINT_BRUSH_PENCIL ? 1
               : args->tool == SPDF_PAINT_BRUSH_ERASER || args->tool == SPDF_PAINT_BRUSH_COLOR_ERASER ? 4 : 5;
    if (spdf_paint_arg_number(call, "size", &v)) args->size = (float)v;
    args->opacity = spdf_paint_arg_number(call, "opacity", &v) ? (float)(v / 100.0) : 1.0f;
    seeded = spdf_paint_arg_number(call, "seed", &v);
    args->seed = seeded ? (uint32_t)v : 0;
    args->mask = doc->selection.active ? doc->selection.mask : NULL;
    return seeded;
}

spdf_paint_status spdf_paint_op_paint_stroke(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_stroke_args args;
    spdf_paint_layer* layer = NULL;
    spdf_paint_point* points = NULL;
    spdf_paint_status st;
    spdf_rect damage;
    int count = 0, cut = 0, seeded = spdf_paint_stroke_args_read(call, &args);
    if (args.tool == SPDF_PAINT_BRUSH_COUNT)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "There is no tool with that name.");
    st = spdf_paint_arg_check_page(call);
    if (st != SPDF_PAINT_OK) return call->message[0] ? st : spdf_paint_call_fail(call, st, "That page is not here.");
    if (!spdf_paint_arg_points(call, "points", &points, &count) || count < 1)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "A stroke needs at least one point.");
    if (!seeded) args.seed = spdf_brush_default_seed(points, count);
    args.points = points, args.point_count = count;
    if (!spdf_paint_active_pixels(doc, &layer) || !layer) {
        fz_free(doc->ctx, points);
        spdf_paint_live_settle(doc);
        if (layer && layer->locked) return spdf_paint_fail_unpaintable(call, layer);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_FAILED, "There is no layer to paint into.");
    }
    /* The stroke drawn while the button was held is the stroke: its pixels are laid as they were shown. */
    if (!spdf_paint_live_lay(doc, layer, &args, &damage, &st)) st = spdf_paint_brush_stroke(doc, layer, &args, &damage);
    if (st == SPDF_PAINT_OK && args.tool == SPDF_PAINT_BRUSH_ERASER) {
        fz_try(doc->ctx) cut = cut_pen_lines(doc, points, count, args.size);
        fz_catch(doc->ctx) st = SPDF_PAINT_ERR_NO_MEMORY;
    }
    fz_free(doc->ctx, points);
    if (st == SPDF_PAINT_ERR_PAGE_LOCKED)
        return spdf_paint_call_fail(call, st, "The page itself can't be changed.");
    if (st == SPDF_PAINT_ERR_NO_MEMORY)
        return spdf_paint_call_fail(call, st, "There isn't enough memory for this stroke.");
    if (st != SPDF_PAINT_OK) return spdf_paint_call_fail(call, st, "This layer can't be painted on.");
    if (damage.x1 > damage.x0 && damage.y1 > damage.y0) {
        spdf_paint_damage(doc, damage);
        if (doc->kind == SPDF_PAINT_DOC_PDF) spdf_paint_pdf_note_change(doc, layer);
    }
    cJSON_AddNumberToObject(call->reply, "layer", layer->id);
    cJSON_AddNumberToObject(call->reply, "seed", args.seed);
    if (cut) cJSON_AddNumberToObject(call->reply, "linesCut", cut);
    return SPDF_PAINT_OK;
}
