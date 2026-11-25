/* Annotate's undo and redo (docs/plans/annotate.md § 4, § 8 Core spdf_paint_history.c): raster changes as 256 x 256
 * tile snapshots, object and layer changes as before/after copies, one step per operation, 1 GB cap per canvas
 * (oldest steps dropped first), the saved point for the dirty state, and the history.undo / history.redo handlers.
 *
 * Each record keeps the state before the change (taken when the unit asks, before it changes anything) and the state
 * after (taken when the step closes). Undo applies a step's records last to first with their "before", redo first to
 * last with their "after"; every record finds its layer by id, so records survive layers being replaced. */
#include "spdf_paint_model.h"

#include <stdlib.h>
#include <string.h>

static size_t pixmap_bytes(const fz_pixmap* pix) { return pix ? (size_t)pix->w * pix->h * pix->n : 0; }

static size_t layer_bytes(const spdf_paint_layer* layer) {
    if (!layer) return 0;
    size_t bytes = sizeof(*layer) + pixmap_bytes(layer->pixels);
    if (layer->object && layer->object->kind == SPDF_PAINT_OBJ_PICTURE)
        bytes += pixmap_bytes(layer->object->u.picture.pixels);
    return bytes + 256;
}

static int is_pdf(const spdf_paint_doc* doc) { return doc->kind == SPDF_PAINT_DOC_PDF; }

static spdf_paint_record* find_record(spdf_paint_step* step, spdf_paint_record_kind kind, spdf_paint_id id) {
    for (int i = 0; i < step->count; i++)
        if (step->records[i].kind == kind && step->records[i].layer == id) return &step->records[i];
    return NULL;
}

static int added_in_step(spdf_paint_step* step, spdf_paint_id id) {
    spdf_paint_record* r = find_record(step, SPDF_PAINT_REC_LAYER, id);
    return r && !r->u.layer.before;
}

static spdf_paint_record* add_record(spdf_paint_doc* doc, spdf_paint_record_kind kind, spdf_paint_id id) {
    spdf_paint_step* step = doc->history.open;
    if (step->count == step->cap) {
        int cap = step->cap ? step->cap * 2 : 8;
        spdf_paint_record* grown = realloc(step->records, (size_t)cap * sizeof(*grown));
        if (!grown) return NULL;
        step->records = grown;
        step->cap = cap;
    }
    spdf_paint_record* r = &step->records[step->count++];
    memset(r, 0, sizeof(*r));
    r->kind = kind;
    r->layer = id;
    return r;
}

static fz_pixmap* copy_box(fz_context* ctx, const fz_pixmap* src, fz_irect box) {
    fz_pixmap* tile = NULL;
    fz_try(ctx) {
        tile = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), box, NULL, 1);
        for (int y = box.y0; y < box.y1; y++)
            memcpy(tile->samples + (y - box.y0) * tile->stride, src->samples + y * src->stride + box.x0 * 4,
                   (size_t)(box.x1 - box.x0) * 4);
    }
    fz_catch(ctx) { fz_ignore_error(ctx); tile = NULL; }
    return tile;
}

static fz_irect tile_box(const spdf_paint_doc* doc, int tx, int ty) {
    int T = SPDF_PAINT_TILE_SIZE;
    fz_irect box = {tx * T, ty * T, tx * T + T, ty * T + T};
    fz_irect all = {0, 0, doc->width * doc->raster_scale, doc->height * doc->raster_scale};
    return fz_intersect_irect(box, all);
}

/* ---- Recording ---- */

void spdf_paint_history_begin(spdf_paint_doc* doc, const char* op_json) {
    if (!doc || doc->history.open) return;
    spdf_paint_step* step = calloc(1, sizeof(*step));
    if (!step) return;
    step->op = op_json ? strdup(op_json) : NULL;
    doc->history.open = step;
}

void spdf_paint_history_save_pixels(spdf_paint_doc* doc, spdf_paint_layer* layer, fz_irect box) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || !layer || added_in_step(step, layer->id) || fz_is_empty_irect(box)) return;
    if (is_pdf(doc)) spdf_paint_pdf_note_change(doc, layer);
    spdf_paint_record* r = find_record(step, SPDF_PAINT_REC_TILES, layer->id);
    if (!r && !(r = add_record(doc, SPDF_PAINT_REC_TILES, layer->id))) return;
    int T = SPDF_PAINT_TILE_SIZE;
    for (int ty = box.y0 / T; ty * T < box.y1; ty++)
        for (int tx = box.x0 / T; tx * T < box.x1; tx++) {
            int saved = 0;
            for (int i = 0; i < r->u.tiles.count && !saved; i++)
                saved = r->u.tiles.tiles[i].tx == tx && r->u.tiles.tiles[i].ty == ty;
            fz_irect tb = tile_box(doc, tx, ty);
            if (saved || fz_is_empty_irect(tb)) continue;
            spdf_paint_tile_snapshot* grown =
                realloc(r->u.tiles.tiles, (size_t)(r->u.tiles.count + 1) * sizeof(*grown));
            if (!grown) return;
            r->u.tiles.tiles = grown;
            spdf_paint_tile_snapshot* snap = &grown[r->u.tiles.count++];
            snap->tx = tx;
            snap->ty = ty;
            snap->before = layer->pixels ? copy_box(doc->ctx, layer->pixels, tb) : NULL;
            snap->after = NULL;
            r->bytes += pixmap_bytes(snap->before) + sizeof(*snap);
        }
}

void spdf_paint_history_save_object(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || !layer || find_record(step, SPDF_PAINT_REC_LAYER, layer->id) ||
        find_record(step, SPDF_PAINT_REC_OBJECT, layer->id))
        return;
    if (is_pdf(doc)) spdf_paint_pdf_note_change(doc, layer);
    spdf_paint_record* r = add_record(doc, SPDF_PAINT_REC_OBJECT, layer->id);
    if (!r) return;
    r->u.layer.before = spdf_paint_layer_clone(doc->ctx, layer, 1);
    r->u.layer.index_before = spdf_paint_layer_index(doc, layer->id);
    r->bytes += layer_bytes(r->u.layer.before);
}

void spdf_paint_history_save_layer_props(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || !layer || added_in_step(step, layer->id) || find_record(step, SPDF_PAINT_REC_LAYER_PROPS, layer->id))
        return;
    if (is_pdf(doc)) spdf_paint_pdf_note_change(doc, layer);
    spdf_paint_record* r = add_record(doc, SPDF_PAINT_REC_LAYER_PROPS, layer->id);
    if (!r) return;
    r->u.layer.before = spdf_paint_layer_clone(doc->ctx, layer, 0);
    r->bytes += sizeof(spdf_paint_layer);
}

static spdf_paint_id* order_ids(const spdf_paint_doc* doc) {
    spdf_paint_id* ids = malloc((size_t)(doc->layer_count ? doc->layer_count : 1) * sizeof(*ids));
    for (int i = 0; ids && i < doc->layer_count; i++) ids[i] = doc->layers[i]->id;
    return ids;
}

void spdf_paint_history_save_order(spdf_paint_doc* doc) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || find_record(step, SPDF_PAINT_REC_ORDER, 0)) return;
    if (is_pdf(doc)) spdf_paint_pdf_note_order(doc);
    spdf_paint_record* r = add_record(doc, SPDF_PAINT_REC_ORDER, 0);
    if (!r) return;
    r->u.order.before = order_ids(doc);
    r->u.order.count_before = doc->layer_count;
    r->bytes += (size_t)doc->layer_count * sizeof(spdf_paint_id);
}

static spdf_paint_layer* clone_stack(spdf_paint_doc* doc, int* count) {
    spdf_paint_layer* copies = calloc((size_t)(doc->layer_count ? doc->layer_count : 1), sizeof(*copies));
    *count = 0;
    for (int i = 0; copies && i < doc->layer_count; i++) {
        spdf_paint_layer* c = spdf_paint_layer_clone(doc->ctx, doc->layers[i], 1);
        if (!c) break;
        copies[i] = *c; /* the struct by value; its pixels, object and nm now belong to the array */
        free(c);
        (*count)++;
    }
    return copies;
}

static size_t stack_bytes(const spdf_paint_layer* layers, int count) {
    size_t bytes = 0;
    for (int i = 0; i < count; i++) bytes += layer_bytes(&layers[i]);
    return bytes;
}

void spdf_paint_history_save_canvas(spdf_paint_doc* doc) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || find_record(step, SPDF_PAINT_REC_CANVAS, 0)) return;
    if (is_pdf(doc)) spdf_paint_pdf_note_order(doc);
    spdf_paint_record* r = add_record(doc, SPDF_PAINT_REC_CANVAS, 0);
    if (!r) return;
    r->u.canvas.w_before = doc->width;
    r->u.canvas.h_before = doc->height;
    r->u.canvas.dpi_before = doc->dpi;
    r->u.canvas.layers_before = clone_stack(doc, &r->u.canvas.count_before);
    r->bytes += stack_bytes(r->u.canvas.layers_before, r->u.canvas.count_before);
}

/* Only the resolution (canvas.properties {dpi}): a canvas record without layers (count -1). */
void spdf_paint_history_save_dpi(spdf_paint_doc* doc) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || find_record(step, SPDF_PAINT_REC_CANVAS, 0)) return;
    spdf_paint_record* r = add_record(doc, SPDF_PAINT_REC_CANVAS, 0);
    if (!r) return;
    r->u.canvas.w_before = doc->width;
    r->u.canvas.h_before = doc->height;
    r->u.canvas.dpi_before = doc->dpi;
    r->u.canvas.count_before = -1;
}

void spdf_paint_history_save_active(spdf_paint_doc* doc) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || find_record(step, SPDF_PAINT_REC_ACTIVE, 0)) return;
    spdf_paint_record* r = add_record(doc, SPDF_PAINT_REC_ACTIVE, 0);
    if (!r) return;
    r->u.active.active_before = doc->active;
    spdf_paint_selection_copy(doc->ctx, &r->u.active.before, &doc->selection);
    r->bytes += pixmap_bytes(r->u.active.before.mask);
}

void spdf_paint_history_added_layer(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || !layer || find_record(step, SPDF_PAINT_REC_LAYER, layer->id)) return;
    if (is_pdf(doc)) { spdf_paint_pdf_note_change(doc, layer); spdf_paint_pdf_note_order(doc); }
    spdf_paint_record* r = add_record(doc, SPDF_PAINT_REC_LAYER, layer->id);
    if (r) r->u.layer.index_before = -1;
}

void spdf_paint_history_removing_layer(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    spdf_paint_step* step = doc ? doc->history.open : NULL;
    if (!step || !layer || find_record(step, SPDF_PAINT_REC_LAYER, layer->id)) return;
    if (is_pdf(doc)) { spdf_paint_pdf_note_change(doc, layer); spdf_paint_pdf_note_order(doc); }
    spdf_paint_record* r = add_record(doc, SPDF_PAINT_REC_LAYER, layer->id);
    if (!r) return;
    r->u.layer.before = spdf_paint_layer_clone(doc->ctx, layer, 1);
    r->u.layer.index_before = spdf_paint_layer_index(doc, layer->id);
    r->bytes += layer_bytes(r->u.layer.before);
}

/* ---- Freeing ---- */

static void free_stack(fz_context* ctx, spdf_paint_layer* layers, int count) {
    for (int i = 0; layers && i < count; i++) {
        fz_drop_pixmap(ctx, layers[i].pixels);
        spdf_paint_object_free(ctx, layers[i].object);
        fz_free(ctx, layers[i].pdf_nm);
    }
    free(layers);
}

static void free_record(fz_context* ctx, spdf_paint_record* r) {
    switch (r->kind) {
    case SPDF_PAINT_REC_TILES:
        for (int i = 0; i < r->u.tiles.count; i++) {
            fz_drop_pixmap(ctx, r->u.tiles.tiles[i].before);
            fz_drop_pixmap(ctx, r->u.tiles.tiles[i].after);
        }
        free(r->u.tiles.tiles);
        break;
    case SPDF_PAINT_REC_OBJECT:
    case SPDF_PAINT_REC_LAYER:
    case SPDF_PAINT_REC_LAYER_PROPS:
        spdf_paint_layer_free(ctx, r->u.layer.before);
        spdf_paint_layer_free(ctx, r->u.layer.after);
        break;
    case SPDF_PAINT_REC_ORDER:
        free(r->u.order.before);
        free(r->u.order.after);
        break;
    case SPDF_PAINT_REC_CANVAS:
        free_stack(ctx, r->u.canvas.layers_before, r->u.canvas.count_before);
        free_stack(ctx, r->u.canvas.layers_after, r->u.canvas.count_after);
        break;
    case SPDF_PAINT_REC_ACTIVE:
        spdf_paint_selection_free(ctx, &r->u.active.before);
        spdf_paint_selection_free(ctx, &r->u.active.after);
        break;
    }
}

static void free_step(fz_context* ctx, spdf_paint_step* step) {
    for (int i = 0; i < step->count; i++) free_record(ctx, &step->records[i]);
    free(step->records);
    free(step->op);
    memset(step, 0, sizeof(*step));
}

void spdf_paint_history_free(spdf_paint_doc* doc) {
    spdf_paint_history* h = &doc->history;
    for (int i = 0; i < h->count; i++) free_step(doc->ctx, &h->steps[i]);
    free(h->steps);
    if (h->open) { free_step(doc->ctx, h->open); free(h->open); }
    size_t limit = h->limit;
    memset(h, 0, sizeof(*h));
    h->limit = limit;
}

static void capture_after(spdf_paint_doc* doc, spdf_paint_step* step) {
    for (int i = 0; i < step->count; i++) {
        spdf_paint_record* r = &step->records[i];
        spdf_paint_layer* layer = r->layer ? spdf_paint_layer_find(doc, r->layer) : NULL;
        switch (r->kind) {
        case SPDF_PAINT_REC_TILES:
            for (int t = 0; t < r->u.tiles.count && layer && layer->pixels; t++) {
                spdf_paint_tile_snapshot* snap = &r->u.tiles.tiles[t];
                fz_irect box = fz_intersect_irect(tile_box(doc, snap->tx, snap->ty),
                                                  fz_pixmap_bbox(doc->ctx, layer->pixels));
                if (!fz_is_empty_irect(box)) snap->after = copy_box(doc->ctx, layer->pixels, box);
                r->bytes += pixmap_bytes(snap->after);
            }
            break;
        case SPDF_PAINT_REC_OBJECT:
        case SPDF_PAINT_REC_LAYER:
            r->u.layer.after = layer ? spdf_paint_layer_clone(doc->ctx, layer, 1) : NULL;
            r->u.layer.index_after = spdf_paint_layer_index(doc, r->layer);
            r->bytes += layer_bytes(r->u.layer.after);
            break;
        case SPDF_PAINT_REC_LAYER_PROPS:
            r->u.layer.after = layer ? spdf_paint_layer_clone(doc->ctx, layer, 0) : NULL;
            r->bytes += sizeof(spdf_paint_layer);
            break;
        case SPDF_PAINT_REC_ORDER:
            r->u.order.after = order_ids(doc);
            r->u.order.count_after = doc->layer_count;
            r->bytes += (size_t)doc->layer_count * sizeof(spdf_paint_id);
            break;
        case SPDF_PAINT_REC_CANVAS:
            r->u.canvas.w_after = doc->width;
            r->u.canvas.h_after = doc->height;
            r->u.canvas.dpi_after = doc->dpi;
            if (r->u.canvas.count_before < 0) { r->u.canvas.count_after = -1; break; }
            r->u.canvas.layers_after = clone_stack(doc, &r->u.canvas.count_after);
            r->bytes += stack_bytes(r->u.canvas.layers_after, r->u.canvas.count_after);
            break;
        case SPDF_PAINT_REC_ACTIVE:
            r->u.active.active_after = doc->active;
            spdf_paint_selection_copy(doc->ctx, &r->u.active.after, &doc->selection);
            r->bytes += pixmap_bytes(r->u.active.after.mask);
            break;
        }
        step->bytes += r->bytes;
    }
}

static void enforce_cap(spdf_paint_doc* doc) {
    spdf_paint_history* h = &doc->history;
    while (h->bytes > h->limit && h->count > 1 && h->cursor > 1) {
        h->bytes -= h->steps[0].bytes;
        free_step(doc->ctx, &h->steps[0]);
        memmove(h->steps, h->steps + 1, (size_t)(h->count - 1) * sizeof(*h->steps));
        h->count--;
        h->cursor--;
        h->saved_cursor = h->saved_cursor > 0 ? h->saved_cursor - 1 : -1;
    }
}

void spdf_paint_history_end(spdf_paint_doc* doc, int keep) {
    spdf_paint_history* h = doc ? &doc->history : NULL;
    spdf_paint_step* step = h ? h->open : NULL;
    if (!step) return;
    h->open = NULL;
    if (!keep) spdf_paint_history_apply_step(doc, step, 1);
    if (!keep || !step->count) { free_step(doc->ctx, step); free(step); return; }
    capture_after(doc, step);
    for (int i = h->cursor; i < h->count; i++) { h->bytes -= h->steps[i].bytes; free_step(doc->ctx, &h->steps[i]); }
    h->count = h->cursor;
    if (h->saved_cursor > h->cursor) h->saved_cursor = -1;
    if (h->count == h->cap) {
        int cap = h->cap ? h->cap * 2 : 32;
        spdf_paint_step* grown = realloc(h->steps, (size_t)cap * sizeof(*grown));
        if (!grown) { free_step(doc->ctx, step); free(step); return; }
        h->steps = grown;
        h->cap = cap;
    }
    h->steps[h->count++] = *step;
    free(step);
    h->cursor = h->count;
    h->bytes += h->steps[h->count - 1].bytes;
    enforce_cap(doc);
}

/* ---- Public ---- */

spdf_paint_status spdf_paint_undo(spdf_paint_doc* doc, int steps) {
    if (!doc || doc->history.cursor <= 0) return SPDF_PAINT_ERR_NOTHING_TO_UNDO;
    for (int i = 0; i < (steps > 0 ? steps : 1) && doc->history.cursor > 0; i++)
        spdf_paint_history_apply_step(doc, &doc->history.steps[--doc->history.cursor], 1);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_redo(spdf_paint_doc* doc, int steps) {
    if (!doc || doc->history.cursor >= doc->history.count) return SPDF_PAINT_ERR_NOTHING_TO_UNDO;
    for (int i = 0; i < (steps > 0 ? steps : 1) && doc->history.cursor < doc->history.count; i++)
        spdf_paint_history_apply_step(doc, &doc->history.steps[doc->history.cursor++], 0);
    return SPDF_PAINT_OK;
}

int spdf_paint_can_undo(const spdf_paint_doc* doc) { return doc && doc->history.cursor > 0; }

int spdf_paint_can_redo(const spdf_paint_doc* doc) { return doc && doc->history.cursor < doc->history.count; }

static const char* step_name(const spdf_paint_step* step) {
    cJSON* json = step && step->op ? cJSON_Parse(step->op) : NULL;
    const spdf_paint_op_info* op = spdf_paint_op_find(cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(json, "op")));
    cJSON_Delete(json);
    return op ? op->name : NULL;
}

const char* spdf_paint_undo_name(const spdf_paint_doc* doc) {
    return spdf_paint_can_undo(doc) ? step_name(&doc->history.steps[doc->history.cursor - 1]) : NULL;
}

const char* spdf_paint_redo_name(const spdf_paint_doc* doc) {
    return spdf_paint_can_redo(doc) ? step_name(&doc->history.steps[doc->history.cursor]) : NULL;
}

const char* spdf_paint_last_operation(const spdf_paint_doc* doc) {
    return spdf_paint_can_undo(doc) ? doc->history.steps[doc->history.cursor - 1].op : NULL;
}

void spdf_paint_set_history_cap(spdf_paint_doc* doc, size_t bytes) {
    if (!doc) return;
    doc->history.limit = bytes;
    enforce_cap(doc);
}

size_t spdf_paint_history_bytes(const spdf_paint_doc* doc) { return doc ? doc->history.bytes : 0; }

int spdf_paint_is_dirty(const spdf_paint_doc* doc) { return doc && doc->history.cursor != doc->history.saved_cursor; }

void spdf_paint_mark_saved(spdf_paint_doc* doc) {
    if (doc) doc->history.saved_cursor = doc->history.cursor;
}

/* ---- Handlers ---- */

static spdf_paint_status history_op(spdf_paint_call* call, int undo) {
    double steps = 1;
    spdf_paint_arg_number(call, "steps", &steps);
    int before = call->doc->history.cursor;
    spdf_paint_status status = undo ? spdf_paint_undo(call->doc, (int)steps) : spdf_paint_redo(call->doc, (int)steps);
    if (status != SPDF_PAINT_OK)
        return spdf_paint_call_fail(call, status, undo ? "There is nothing to undo." : "There is nothing to redo.");
    int moved = call->doc->history.cursor - before;
    cJSON_AddNumberToObject(call->reply, undo ? "undone" : "redone", moved < 0 ? -moved : moved);
    cJSON_AddBoolToObject(call->reply, "canUndo", spdf_paint_can_undo(call->doc));
    cJSON_AddBoolToObject(call->reply, "canRedo", spdf_paint_can_redo(call->doc));
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_history_undo(spdf_paint_call* call) { return history_op(call, 1); }

spdf_paint_status spdf_paint_op_history_redo(spdf_paint_call* call) { return history_op(call, 0); }
