/* Undo and redo, applied (spdf_paint_history.c records the steps): each record puts back its "before" (undo, last
 * record first) or its "after" (redo, first record first), finding its layer by id; then the active layer and the
 * selection are made valid again, and a PDF page canvas is told what to write back. */
#include "spdf_paint_model.h"

#include <string.h>

static int is_pdf(const spdf_paint_doc* doc) { return doc->kind == SPDF_PAINT_DOC_PDF; }

static fz_irect tile_box(const spdf_paint_doc* doc, int tx, int ty) {
    int T = SPDF_PAINT_TILE_SIZE;
    fz_irect box = {tx * T, ty * T, tx * T + T, ty * T + T};
    fz_irect all = {0, 0, doc->width * doc->raster_scale, doc->height * doc->raster_scale};
    return fz_intersect_irect(box, all);
}


static void put_tile(spdf_paint_doc* doc, spdf_paint_layer* layer, const spdf_paint_tile_snapshot* snap,
                     const fz_pixmap* src) {
    fz_irect box = tile_box(doc, snap->tx, snap->ty);
    if (fz_is_empty_irect(box) || (!src && !layer->pixels)) return;
    fz_pixmap* pix = spdf_paint_layer_pixels(doc, layer);
    if (!pix) return;
    box = fz_intersect_irect(box, fz_pixmap_bbox(doc->ctx, pix));
    for (int y = box.y0; y < box.y1; y++) {
        unsigned char* d = pix->samples + y * pix->stride + box.x0 * 4;
        int inside = src && y >= src->y && y < src->y + src->h;
        if (!inside) { memset(d, 0, (size_t)(box.x1 - box.x0) * 4); continue; }
        int x1 = box.x1 < src->x + src->w ? box.x1 : src->x + src->w;
        memcpy(d, src->samples + (y - src->y) * src->stride + (box.x0 - src->x) * 4, (size_t)(x1 - box.x0) * 4);
    }
    float rs = (float)doc->raster_scale;
    spdf_rect r = {box.x0 / rs, box.y0 / rs, box.x1 / rs, box.y1 / rs};
    spdf_paint_damage(doc, r);
}

static void put_layer(spdf_paint_doc* doc, spdf_paint_id id, const spdf_paint_layer* state, int index) {
    spdf_paint_layer* existing = spdf_paint_layer_find(doc, id);
    if (existing) spdf_paint_changed(doc, existing, (spdf_rect){0, 0, 0, 0});
    if (!state) {
        if (existing) spdf_paint_layer_free(doc->ctx, spdf_paint_layer_detach(doc, id));
        return;
    }
    spdf_paint_layer* copy = spdf_paint_layer_clone(doc->ctx, state, 1);
    if (!copy) return;
    if (existing) {
        doc->layers[spdf_paint_layer_index(doc, id)] = copy;
        spdf_paint_layer_free(doc->ctx, existing);
    } else spdf_paint_layer_insert(doc, copy, index);
    spdf_paint_changed(doc, copy, (spdf_rect){0, 0, 0, 0});
}

static void put_order(spdf_paint_doc* doc, const spdf_paint_id* ids, int count) {
    int at = 0;
    for (int i = 0; i < count; i++) {
        int index = spdf_paint_layer_index(doc, ids[i]);
        if (index < 0) continue;
        spdf_paint_layer* layer = doc->layers[index];
        memmove(doc->layers + at + 1, doc->layers + at, (size_t)(index - at) * sizeof(*doc->layers));
        doc->layers[at++] = layer;
    }
    spdf_paint_damage_all(doc);
}

static void put_canvas(spdf_paint_doc* doc, int w, int h, float dpi, const spdf_paint_layer* layers, int count) {
    if (count < 0) { doc->dpi = dpi; doc->generation++; return; }
    for (int i = 0; i < doc->layer_count; i++) spdf_paint_layer_free(doc->ctx, doc->layers[i]);
    doc->layer_count = 0;
    for (int i = 0; i < count; i++) {
        spdf_paint_layer* copy = spdf_paint_layer_clone(doc->ctx, &layers[i], 1);
        if (copy) spdf_paint_layer_insert(doc, copy, doc->layer_count);
    }
    doc->dpi = dpi;
    spdf_paint_set_size(doc, w, h);
}

static void apply_record(spdf_paint_doc* doc, spdf_paint_record* r, int undo) {
    spdf_paint_layer* layer = r->layer ? spdf_paint_layer_find(doc, r->layer) : NULL;
    switch (r->kind) {
    case SPDF_PAINT_REC_TILES:
        if (!layer) break;
        for (int i = 0; i < r->u.tiles.count; i++)
            put_tile(doc, layer, &r->u.tiles.tiles[i], undo ? r->u.tiles.tiles[i].before : r->u.tiles.tiles[i].after);
        break;
    case SPDF_PAINT_REC_OBJECT:
    case SPDF_PAINT_REC_LAYER:
        put_layer(doc, r->layer, undo ? r->u.layer.before : r->u.layer.after,
                  undo ? r->u.layer.index_before : r->u.layer.index_after);
        break;
    case SPDF_PAINT_REC_LAYER_PROPS: {
        const spdf_paint_layer* s = undo ? r->u.layer.before : r->u.layer.after;
        if (!layer || !s) break;
        memcpy(layer->name, s->name, sizeof(layer->name));
        layer->visible = s->visible;
        layer->opacity = s->opacity;
        layer->locked = s->locked;
        spdf_paint_changed(doc, layer, (spdf_rect){0, 0, 0, 0});
        break;
    }
    case SPDF_PAINT_REC_ORDER:
        if (undo) put_order(doc, r->u.order.before, r->u.order.count_before);
        else put_order(doc, r->u.order.after, r->u.order.count_after);
        break;
    case SPDF_PAINT_REC_CANVAS:
        if (undo)
            put_canvas(doc, r->u.canvas.w_before, r->u.canvas.h_before, r->u.canvas.dpi_before,
                       r->u.canvas.layers_before, r->u.canvas.count_before);
        else
            put_canvas(doc, r->u.canvas.w_after, r->u.canvas.h_after, r->u.canvas.dpi_after,
                       r->u.canvas.layers_after, r->u.canvas.count_after);
        break;
    case SPDF_PAINT_REC_ACTIVE: {
        int transparent = doc->selection.transparent;
        spdf_paint_selection_free(doc->ctx, &doc->selection);
        spdf_paint_selection_copy(doc->ctx, &doc->selection, undo ? &r->u.active.before : &r->u.active.after);
        doc->selection.transparent = transparent;
        doc->active = undo ? r->u.active.active_before : r->u.active.active_after;
        break;
    }
    }
    if (is_pdf(doc)) {
        layer = r->layer ? spdf_paint_layer_find(doc, r->layer) : NULL;
        if (layer) spdf_paint_pdf_note_change(doc, layer);
        if (r->kind != SPDF_PAINT_REC_TILES && r->kind != SPDF_PAINT_REC_ACTIVE) spdf_paint_pdf_note_order(doc);
    }
}

static void settle(spdf_paint_doc* doc) {
    spdf_paint_selection_prune(doc);
    spdf_paint_layer* active = spdf_paint_layer_find(doc, doc->active);
    if (!(active && active->kind == SPDF_PAINT_LAYER_RASTER) && !spdf_paint_layer_paintable(doc, active)) {
        doc->active = 0;
        for (int i = doc->layer_count - 1; i >= 0 && !doc->active; i--)
            if (spdf_paint_layer_paintable(doc, doc->layers[i])) doc->active = doc->layers[i]->id;
    }
}

void spdf_paint_history_apply_step(spdf_paint_doc* doc, spdf_paint_step* step, int undo) {
    if (undo)
        for (int i = step->count - 1; i >= 0; i--) apply_record(doc, &step->records[i], 1);
    else
        for (int i = 0; i < step->count; i++) apply_record(doc, &step->records[i], 0);
    settle(doc);
    doc->generation++;
}
