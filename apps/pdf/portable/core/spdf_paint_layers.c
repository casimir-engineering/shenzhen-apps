/* Annotate's layers and depth (docs/plans/annotate.md § 1 Layers panel, § 3, § 6 Layers and Colours): the layer
 * handlers, ordering (shared with object.order), merging down (shared with object.merge_down), and the colours. The
 * Background stays at the bottom; on a PDF page it is the page itself, and nothing here changes it. */
#include "spdf_paint_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char k_page_locked[] = "The page itself can't be changed.";

static spdf_paint_status find_layer(spdf_paint_call* call, spdf_paint_layer** out) {
    double id = 0;
    spdf_paint_arg_number(call, "id", &id);
    *out = spdf_paint_layer_find(call->doc, (spdf_paint_id)id);
    if (!*out) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no layer %u.", (unsigned)id);
    return SPDF_PAINT_OK;
}

static spdf_paint_status refuse_background(spdf_paint_call* call, spdf_paint_layer* layer, const char* why) {
    if (spdf_paint_layer_is_page(call->doc, layer))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, k_page_locked);
    return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "%s", why);
}

static spdf_paint_status refuse_locked(spdf_paint_call* call) {
    return spdf_paint_call_fail(call, SPDF_PAINT_ERR_LOCKED,
                                "This annotation was made in another app and can't be changed here.");
}

/* The box of a pixmap's pixels that are not fully transparent (empty when none). */
static fz_irect content_box(const fz_pixmap* pix) {
    fz_irect box = {pix->w, pix->h, 0, 0};
    for (int y = 0; y < pix->h; y++) {
        const unsigned char* p = pix->samples + y * pix->stride;
        for (int x = 0; x < pix->w; x++, p += 4) {
            if (!p[3]) continue;
            if (x < box.x0) box.x0 = x;
            if (x >= box.x1) box.x1 = x + 1;
            if (y < box.y0) box.y0 = y;
            if (y >= box.y1) box.y1 = y + 1;
        }
    }
    if (box.x1 <= box.x0) box.x0 = box.y0 = box.x1 = box.y1 = 0;
    return box;
}

/* ---- Depth ---- */

static int in_ids(const spdf_paint_id* ids, int count, spdf_paint_id id) {
    for (int i = 0; i < count; i++)
        if (ids[i] == id) return 1;
    return 0;
}

static void move_layer(spdf_paint_doc* doc, int from, int to) {
    if (from == to) return;
    spdf_paint_layer* layer = doc->layers[from];
    if (from < to) memmove(doc->layers + from, doc->layers + from + 1, (size_t)(to - from) * sizeof(*doc->layers));
    else memmove(doc->layers + to + 1, doc->layers + to, (size_t)(from - to) * sizeof(*doc->layers));
    doc->layers[to] = layer;
}

spdf_paint_status spdf_paint_order_layers(spdf_paint_call* call, const spdf_paint_id* ids, int count,
                                          const cJSON* to) {
    spdf_paint_doc* doc = call->doc;
    for (int i = 0; i < count; i++) {
        int index = spdf_paint_layer_index(doc, ids[i]);
        if (index < 0) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no layer %u.", ids[i]);
        if (index == 0) return refuse_background(call, doc->layers[0], "The Background stays at the bottom.");
    }
    spdf_paint_history_save_order(doc);
    const char* where = cJSON_GetStringValue(to);
    int top = doc->layer_count - 1;
    if (where && !strcmp(where, "front")) {
        for (int i = 1, moved = 0; i <= top - moved;)
            if (in_ids(ids, count, doc->layers[i]->id)) { move_layer(doc, i, top); moved++; } else i++;
    } else if (where && !strcmp(where, "back")) {
        for (int i = top, moved = 0; i >= 1 + moved;)
            if (in_ids(ids, count, doc->layers[i]->id)) { move_layer(doc, i, 1); moved++; } else i--;
    } else if (where && !strcmp(where, "forward")) {
        for (int i = top - 1; i >= 1; i--)
            if (in_ids(ids, count, doc->layers[i]->id) && !in_ids(ids, count, doc->layers[i + 1]->id))
                move_layer(doc, i, i + 1);
    } else if (where && !strcmp(where, "backward")) {
        for (int i = 2; i <= top; i++)
            if (in_ids(ids, count, doc->layers[i]->id) && !in_ids(ids, count, doc->layers[i - 1]->id))
                move_layer(doc, i, i - 1);
    } else if (cJSON_IsNumber(to)) {
        spdf_paint_layer** moving = malloc((size_t)count * sizeof(*moving));
        if (!moving) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
        int n = 0;
        for (int i = 1; i < doc->layer_count;) {
            if (!in_ids(ids, count, doc->layers[i]->id)) { i++; continue; }
            moving[n++] = doc->layers[i];
            memmove(doc->layers + i, doc->layers + i + 1, (size_t)(doc->layer_count - i - 1) * sizeof(*doc->layers));
            doc->layer_count--;
        }
        int at = (int)to->valuedouble + 1;
        if (at > doc->layer_count) at = doc->layer_count;
        if (at < 1) at = 1;
        for (int k = 0; k < n; k++) spdf_paint_layer_insert(doc, moving[k], at + k);
        free(moving);
    } else
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT,
                                    "\"to\" is front, forward, backward, back or a position.");
    spdf_paint_damage_all(doc);
    return SPDF_PAINT_OK;
}

/* ---- Merging ---- */

spdf_paint_status spdf_paint_merge_object_down(spdf_paint_call* call, spdf_paint_layer* layer) {
    spdf_paint_doc* doc = call->doc;
    int index = spdf_paint_layer_index(doc, layer->id);
    int below = spdf_paint_paintable_below(doc, index);
    if (below < 0) {
        if (doc->kind != SPDF_PAINT_DOC_PDF)
            return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "There is no layer below to merge into.");
        spdf_paint_layer* drawing =
            spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, "Drawing", doc->layers[index - 1]->id);
        if (!drawing) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
        below = spdf_paint_layer_index(doc, drawing->id);
    }
    spdf_paint_layer* target = doc->layers[below];
    fz_pixmap* pix = spdf_paint_layer_pixels(doc, target);
    if (!pix) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    spdf_paint_object_update_bounds(layer->object);
    fz_irect box = spdf_paint_raster_box(doc, layer->object->bounds);
    spdf_paint_history_save_pixels(doc, target, box);
    spdf_paint_history_save_active(doc);
    float rs = (float)doc->raster_scale;
    spdf_paint_object_draw(doc, layer->object, fz_scale(rs, rs), pix, box, layer->opacity);
    spdf_paint_layer_delete(doc, layer);
    doc->active = target->id;
    spdf_paint_changed(doc, target, (spdf_rect){box.x0 / rs, box.y0 / rs, box.x1 / rs, box.y1 / rs});
    cJSON_AddNumberToObject(call->reply, "into", target->id);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_layer_merge_down(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (layer->kind == SPDF_PAINT_LAYER_BACKGROUND)
        return refuse_background(call, layer, "Nothing is below the Background.");
    if (layer->locked) return refuse_locked(call);
    if (layer->object) return spdf_paint_merge_object_down(call, layer);
    int below = spdf_paint_paintable_below(doc, spdf_paint_layer_index(doc, layer->id));
    if (below < 0) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, k_page_locked);
    spdf_paint_layer* target = doc->layers[below];
    if (layer->pixels) {
        fz_irect box = content_box(layer->pixels);
        fz_pixmap* pix = spdf_paint_layer_pixels(doc, target);
        if (!pix) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
        spdf_paint_history_save_pixels(doc, target, box);
        spdf_paint_draw_raster(doc, layer->pixels, pix, box, (float)doc->raster_scale, layer->opacity, 0);
    }
    spdf_paint_history_save_active(doc);
    spdf_paint_layer_delete(doc, layer);
    doc->active = target->id;
    spdf_paint_damage_all(doc);
    cJSON_AddNumberToObject(call->reply, "into", target->id);
    return SPDF_PAINT_OK;
}

/* ---- Layer handlers ---- */

spdf_paint_status spdf_paint_op_layer_add(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    double above = doc->active;
    spdf_paint_arg_number(call, "above", &above);
    if (above && !spdf_paint_layer_find(doc, (spdf_paint_id)above))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no layer %u.", (unsigned)above);
    spdf_paint_history_save_active(doc);
    spdf_paint_layer* layer =
        spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, spdf_paint_arg_string(call, "name"), (spdf_paint_id)above);
    if (!layer) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    doc->active = layer->id;
    doc->generation++;
    cJSON_AddNumberToObject(call->reply, "id", layer->id);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_layer_duplicate(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (layer->object) return spdf_paint_op_object_duplicate(call);
    if (spdf_paint_layer_is_page(doc, layer)) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, k_page_locked);
    spdf_paint_layer* copy = spdf_paint_layer_clone(doc->ctx, layer, 1);
    if (!copy) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    char name[SPDF_PAINT_NAME_MAX];
    spdf_paint_layer_display_name(doc, layer, name, sizeof(name));
    snprintf(copy->name, sizeof(copy->name), "%.110s copy", name);
    copy->id = doc->next_id++;
    copy->kind = SPDF_PAINT_LAYER_RASTER;
    fz_free(doc->ctx, copy->pdf_nm);
    copy->pdf_nm = NULL;
    spdf_paint_layer_insert(doc, copy, spdf_paint_layer_index(doc, layer->id) + 1);
    spdf_paint_history_added_layer(doc, copy);
    spdf_paint_history_save_active(doc);
    doc->active = copy->id;
    spdf_paint_damage_all(doc);
    cJSON_AddNumberToObject(call->reply, "id", copy->id);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_layer_delete(spdf_paint_call* call) {
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (layer->kind == SPDF_PAINT_LAYER_BACKGROUND)
        return refuse_background(call, layer, "The Background can't be deleted; clear it instead.");
    if (layer->locked) return refuse_locked(call);
    spdf_paint_history_save_active(call->doc);
    spdf_paint_layer_delete(call->doc, layer);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_layer_set(spdf_paint_call* call) {
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (spdf_paint_layer_is_page(call->doc, layer))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, k_page_locked);
    if (layer->locked) return refuse_locked(call);
    spdf_paint_history_save_layer_props(call->doc, layer);
    const char* name = spdf_paint_arg_string(call, "name");
    int visible = layer->visible;
    double opacity = layer->opacity * 100.0;
    if (name) snprintf(layer->name, sizeof(layer->name), "%s", name);
    spdf_paint_arg_bool(call, "visible", &visible);
    spdf_paint_arg_number(call, "opacity", &opacity);
    layer->visible = visible ? 1 : 0;
    layer->opacity = (float)(opacity / 100.0);
    spdf_paint_changed(call->doc, layer, (spdf_rect){0, 0, 0, 0});
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_layer_order(spdf_paint_call* call) {
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (layer->locked && layer->kind != SPDF_PAINT_LAYER_BACKGROUND) return refuse_locked(call);
    return spdf_paint_order_layers(call, &layer->id, 1, cJSON_GetObjectItemCaseSensitive(call->args, "to"));
}

spdf_paint_status spdf_paint_op_layer_activate(spdf_paint_call* call) {
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (spdf_paint_layer_is_page(call->doc, layer))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, k_page_locked);
    if (!spdf_paint_layer_paintable(call->doc, layer))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT,
                                    "Objects aren't painted into; choose a layer of pixels.");
    call->doc->active = layer->id;
    call->doc->generation++;
    return SPDF_PAINT_OK;
}

/* ---- Colours ---- */

static void reply_colors(spdf_paint_call* call) {
    cJSON_AddItemToObject(call->reply, "color1", spdf_paint_color_json(call->doc->color1));
    cJSON_AddItemToObject(call->reply, "color2", spdf_paint_color_json(call->doc->color2));
}

spdf_paint_status spdf_paint_op_colors_set(spdf_paint_call* call) {
    spdf_paint_arg_color(call, "color1", &call->doc->color1);
    spdf_paint_arg_color(call, "color2", &call->doc->color2);
    reply_colors(call);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_palette_set_custom(spdf_paint_call* call) {
    double index = 0;
    spdf_paint_color color = 0;
    spdf_paint_arg_number(call, "index", &index);
    spdf_paint_arg_color(call, "color", &color);
    if (index < 0 || index >= SPDF_PAINT_CUSTOM_COLORS)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "\"index\" is 0 to 9.");
    call->doc->custom[(int)index] = color;
    cJSON* custom = cJSON_AddArrayToObject(call->reply, "custom");
    for (int i = 0; i < SPDF_PAINT_CUSTOM_COLORS; i++)
        cJSON_AddItemToArray(custom, call->doc->custom[i] ? spdf_paint_color_json(call->doc->custom[i]) : cJSON_CreateNull());
    return SPDF_PAINT_OK;
}
