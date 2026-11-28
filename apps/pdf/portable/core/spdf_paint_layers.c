/* Annotate's layers and depth (docs/plans/annotate.md § 1 Layers panel, § 3, § 6 Layers and Colours): the layer
 * handlers, ordering (shared with object.order), merging down (shared with object.merge_down), and the colours. The
 * Background stays at the bottom: it is the document (the page, the picture, the canvas's background), and nothing
 * here changes it. */
#include "spdf_paint_model.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static spdf_paint_status find_layer(spdf_paint_call* call, spdf_paint_layer** out) {
    double id = 0;
    spdf_paint_arg_number(call, "id", &id);
    *out = spdf_paint_layer_find(call->doc, (spdf_paint_id)id);
    if (!*out) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no layer %u.", (unsigned)id);
    return SPDF_PAINT_OK;
}

static spdf_paint_status refuse_base(spdf_paint_call* call) {
    return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, "%s", spdf_paint_base_locked_text(call->doc));
}

static spdf_paint_status refuse_locked(spdf_paint_call* call, const spdf_paint_layer* layer) {
    if (layer && layer->kind == SPDF_PAINT_LAYER_RASTER)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_LOCKED, "This layer is locked; unlock it first.");
    if (layer && layer->object && !layer->locked && layer->object->kind != SPDF_PAINT_OBJ_FOREIGN)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_LOCKED, "This object's layer is locked.");
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

/* Reorders n items (pointers) whose `moving` flags are set: "front", "back", "forward", "backward" or a position
 * from the bottom (into the items left once the moving ones are out). 0 when `to` isn't one of them. */
static int reorder(void** items, const unsigned char* moving, int n, const cJSON* to) {
    void** out = malloc((size_t)(n ? n : 1) * sizeof(*out));
    unsigned char* flags = malloc((size_t)(n ? n : 1));
    if (!out || !flags) { free(out); free(flags); return 0; }
    memcpy(flags, moving, (size_t)n);
    const char* where = cJSON_GetStringValue(to);
    int k = 0, ok = 1;
    if (where && (!strcmp(where, "front") || !strcmp(where, "back"))) {
        int front = !strcmp(where, "front");
        for (int pass = 0; pass < 2; pass++)
            for (int i = 0; i < n; i++)
                if ((flags[i] != 0) == (pass == front)) out[k++] = items[i];
    } else if (where && !strcmp(where, "forward")) {
        memcpy(out, items, (size_t)n * sizeof(*out));
        for (int i = n - 2; i >= 0; i--)
            if (flags[i] && !flags[i + 1]) {
                void* t = out[i]; out[i] = out[i + 1]; out[i + 1] = t;
                flags[i] = 0, flags[i + 1] = 1;
            }
    } else if (where && !strcmp(where, "backward")) {
        memcpy(out, items, (size_t)n * sizeof(*out));
        for (int i = 1; i < n; i++)
            if (flags[i] && !flags[i - 1]) {
                void* t = out[i]; out[i] = out[i - 1]; out[i - 1] = t;
                flags[i] = 0, flags[i - 1] = 1;
            }
    } else if (cJSON_IsNumber(to)) {
        int rest = 0;
        for (int i = 0; i < n; i++) rest += !flags[i];
        int at = (int)to->valuedouble;
        if (at > rest) at = rest;
        if (at < 0) at = 0;
        int seen = 0, placed = 0;
        for (int i = 0; i <= n; i++) {
            if (i < n && flags[i]) continue;
            if (seen == at && !placed) {
                for (int j = 0; j < n; j++)
                    if (flags[j]) out[k++] = items[j];
                placed = 1;
            }
            if (i < n) out[k++] = items[i], seen++;
        }
        if (k != n) ok = 0;
    } else ok = 0;
    if (ok) memcpy(items, out, (size_t)n * sizeof(*out));
    free(out);
    free(flags);
    return ok;
}

static spdf_paint_status bad_depth(spdf_paint_call* call) {
    return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT,
                                "\"to\" is front, forward, backward, back or a position.");
}

/* Objects move within their own layer: each layer holding some of them is reordered on its own. */
static spdf_paint_status order_objects(spdf_paint_call* call, const spdf_paint_id* ids, int count, const cJSON* to) {
    spdf_paint_doc* doc = call->doc;
    unsigned char* moving = malloc((size_t)doc->layer_count + 1);
    if (!moving) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    spdf_paint_history_save_order(doc);
    int ok = 1;
    for (int g = 1; g < doc->layer_count && ok; g = spdf_paint_group_end(doc, g)) {
        int lo = g + 1, hi = spdf_paint_group_end(doc, g), any = 0;
        for (int i = lo; i < hi; i++) any |= moving[i - lo] = (unsigned char)in_ids(ids, count, doc->layers[i]->id);
        if (any) ok = reorder((void**)(doc->layers + lo), moving, hi - lo, to);
    }
    free(moving);
    if (!ok) return bad_depth(call);
    spdf_paint_damage_all(doc);
    return SPDF_PAINT_OK;
}

/* Layers move with their objects, among the layers; the base layer never moves. */
static spdf_paint_status order_groups(spdf_paint_call* call, const spdf_paint_id* ids, int count, const cJSON* to) {
    spdf_paint_doc* doc = call->doc;
    int n = 0, total = doc->layer_count;
    for (int g = 1; g < total; g = spdf_paint_group_end(doc, g)) n++;
    spdf_paint_layer*** blocks = malloc((size_t)(n ? n : 1) * sizeof(*blocks));
    int* sizes = malloc((size_t)(n ? n : 1) * sizeof(*sizes));
    unsigned char* moving = malloc((size_t)(n ? n : 1));
    spdf_paint_layer** copy = malloc((size_t)total * sizeof(*copy));
    if (!blocks || !sizes || !moving || !copy) {
        free(blocks); free(sizes); free(moving); free(copy);
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    }
    memcpy(copy, doc->layers, (size_t)total * sizeof(*copy));
    n = 0;
    for (int g = 1; g < total; g = spdf_paint_group_end(doc, g)) {
        blocks[n] = copy + g;
        sizes[n] = spdf_paint_group_end(doc, g) - g;
        moving[n++] = (unsigned char)in_ids(ids, count, doc->layers[g]->id);
    }
    void** order = malloc((size_t)(n ? n : 1) * sizeof(*order));
    int ok = order != NULL;
    for (int i = 0; ok && i < n; i++) order[i] = (void*)(intptr_t)i;
    if (ok) ok = reorder(order, moving, n, to);
    if (ok) {
        spdf_paint_history_save_order(doc);
        int at = 1;
        for (int i = 0; i < n; i++) {
            int b = (int)(intptr_t)order[i];
            memcpy(doc->layers + at, blocks[b], (size_t)sizes[b] * sizeof(*copy));
            at += sizes[b];
        }
    }
    free(order); free(blocks); free(sizes); free(moving); free(copy);
    if (!ok) return bad_depth(call);
    spdf_paint_damage_all(doc);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_order_layers(spdf_paint_call* call, const spdf_paint_id* ids, int count,
                                          const cJSON* to) {
    spdf_paint_doc* doc = call->doc;
    int objects = 0;
    for (int i = 0; i < count; i++) {
        int index = spdf_paint_layer_index(doc, ids[i]);
        if (index < 0) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no layer %u.", ids[i]);
        if (index == 0) return refuse_base(call);
        objects += doc->layers[index]->kind == SPDF_PAINT_LAYER_OBJECT;
    }
    if (objects && objects != count)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "Order layers and objects separately.");
    return objects ? order_objects(call, ids, count, to) : order_groups(call, ids, count, to);
}

/* ---- Merging ---- */

spdf_paint_status spdf_paint_merge_object_down(spdf_paint_call* call, spdf_paint_layer* layer) {
    spdf_paint_doc* doc = call->doc;
    int index = spdf_paint_layer_index(doc, layer->id);
    int below = spdf_paint_owner_index(doc, index); /* its layer's own pixels */
    if (below <= 0 || !spdf_paint_layer_paintable(doc, doc->layers[below]))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "There is no layer below to merge into.");
    spdf_paint_layer* target = doc->layers[below];
    fz_pixmap* pix = spdf_paint_layer_pixels(doc, target);
    if (!pix) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    spdf_paint_object_update_bounds(layer->object);
    fz_irect box = spdf_paint_raster_box(doc, layer->object->bounds);
    spdf_paint_history_save_pixels(doc, target, box);
    spdf_paint_history_save_active(doc);
    float rs = (float)doc->raster_scale;
    if (layer->visible) spdf_paint_object_draw(doc, layer->object, fz_scale(rs, rs), pix, box, layer->opacity);
    spdf_paint_layer_delete(doc, layer);
    doc->active = target->id;
    spdf_paint_changed(doc, target, (spdf_rect){box.x0 / rs, box.y0 / rs, box.x1 / rs, box.y1 / rs});
    cJSON_AddNumberToObject(call->reply, "into", target->id);
    return SPDF_PAINT_OK;
}

/* Deletes a layer and every object on it (top first), each recorded on the open step. */
static void delete_group(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    int g = spdf_paint_layer_index(doc, layer->id);
    for (int i = spdf_paint_group_end(doc, g) - 1; i > g; i--) spdf_paint_layer_delete(doc, doc->layers[i]);
    spdf_paint_layer_delete(doc, layer);
}

spdf_paint_status spdf_paint_op_layer_merge_down(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (spdf_paint_layer_is_base(layer)) return refuse_base(call);
    if (layer->object) {
        if (spdf_paint_entry_locked(doc, spdf_paint_layer_index(doc, layer->id))) return refuse_locked(call, layer);
        return spdf_paint_merge_object_down(call, layer);
    }
    if (layer->locked) return refuse_locked(call, layer);
    int g = spdf_paint_layer_index(doc, layer->id), below = g - 1;
    while (below > 0 && doc->layers[below]->kind != SPDF_PAINT_LAYER_RASTER) below--;
    spdf_paint_layer* target = doc->layers[below];
    if (!spdf_paint_layer_paintable(doc, target))
        return spdf_paint_layer_is_base(target) ? refuse_base(call) : refuse_locked(call, target);
    float rs = (float)doc->raster_scale;
    spdf_paint_history_save_active(doc);
    if (layer->pixels && layer->visible) {
        fz_irect box = content_box(layer->pixels);
        fz_pixmap* pix = spdf_paint_layer_pixels(doc, target);
        if (!pix) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
        spdf_paint_history_save_pixels(doc, target, box);
        spdf_paint_draw_raster(doc, layer->pixels, pix, box, rs, layer->opacity, 0);
    }
    /* into the layer below: its objects stay objects, on top of that layer's, as they looked */
    int end = spdf_paint_group_end(doc, g);
    spdf_paint_history_save_order(doc);
    for (int i = g + 1; i < end; i++) {
        spdf_paint_layer* o = doc->layers[i];
        spdf_paint_history_save_layer_props(doc, o);
        o->opacity *= layer->opacity;
        if (!layer->visible) o->visible = 0;
    }
    spdf_paint_layer_delete(doc, layer); /* its objects now follow the layer below */
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
    int at = above ? spdf_paint_layer_index(doc, (spdf_paint_id)above) : doc->layer_count - 1;
    if (at < 0) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no layer %u.", (unsigned)above);
    int owner = spdf_paint_owner_index(doc, at);
    at = owner > 0 ? spdf_paint_group_end(doc, owner) : owner == 0 ? 1 : doc->layer_count; /* above it and its objects */
    spdf_paint_history_save_active(doc);
    spdf_paint_layer* layer = spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, spdf_paint_arg_string(call, "name"),
                                                   doc->layers[at - 1]->id);
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
    /* a picture's or canvas's Background is copied into a layer of its own, which the tools may change */
    if (spdf_paint_layer_is_page(doc, layer)) return refuse_base(call);
    int g = spdf_paint_layer_index(doc, layer->id);
    int end = layer->kind == SPDF_PAINT_LAYER_RASTER ? spdf_paint_group_end(doc, g) : g + 1, at = end;
    spdf_paint_id first = 0;
    for (int i = g; i < end; i++) { /* the layer, then a copy of each of its objects above it */
        spdf_paint_layer* copy = spdf_paint_layer_clone(doc->ctx, doc->layers[i], 1);
        if (!copy) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
        if (i == g) {
            char name[SPDF_PAINT_NAME_MAX];
            spdf_paint_layer_display_name(doc, layer, name, sizeof(name));
            snprintf(copy->name, sizeof(copy->name), "%.110s copy", name);
            copy->kind = SPDF_PAINT_LAYER_RASTER;
            copy->locked = 0;
        }
        copy->id = doc->next_id++;
        fz_free(doc->ctx, copy->pdf_nm);
        copy->pdf_nm = NULL;
        if (copy->object) {
            fz_free(doc->ctx, copy->object->pdf_nm);
            copy->object->pdf_nm = NULL;
            if (copy->object->kind >= SPDF_PAINT_OBJ_FILL_TEXT && copy->object->kind <= SPDF_PAINT_OBJ_FILL_SIGNATURE) {
                fz_free(doc->ctx, copy->object->u.fill.nm);
                copy->object->u.fill.nm = NULL;
            }
        }
        if (!first) first = copy->id;
        spdf_paint_layer_insert(doc, copy, at++);
        spdf_paint_history_added_layer(doc, copy);
    }
    spdf_paint_history_save_active(doc);
    doc->active = first;
    spdf_paint_damage_all(doc);
    cJSON_AddNumberToObject(call->reply, "id", first);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_layer_delete(spdf_paint_call* call) {
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (spdf_paint_layer_is_base(layer)) return refuse_base(call);
    if (layer->locked) return refuse_locked(call, layer);
    spdf_paint_history_save_active(call->doc);
    if (layer->object) spdf_paint_layer_delete(call->doc, layer);
    else delete_group(call->doc, layer);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_layer_set(spdf_paint_call* call) {
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (spdf_paint_layer_is_base(layer)) return refuse_base(call);
    int is_layer = layer->kind != SPDF_PAINT_LAYER_OBJECT;
    if (layer->locked && !is_layer) return refuse_locked(call, layer); /* a layer the person locked can be unlocked */
    int locked = layer->locked;
    spdf_paint_arg_bool(call, "locked", &locked);
    if (locked && !is_layer)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "Lock the layer the object is on.");
    spdf_paint_history_save_layer_props(call->doc, layer);
    const char* name = spdf_paint_arg_string(call, "name");
    int visible = layer->visible;
    double opacity = layer->opacity * 100.0;
    if (name) snprintf(layer->name, sizeof(layer->name), "%s", name);
    spdf_paint_arg_bool(call, "visible", &visible);
    spdf_paint_arg_number(call, "opacity", &opacity);
    layer->visible = visible ? 1 : 0;
    layer->opacity = (float)(opacity / 100.0);
    layer->locked = locked ? 1 : 0;
    if (layer->locked) spdf_paint_selection_prune(call->doc);
    if (is_layer) spdf_paint_damage_all(call->doc); /* its objects change with it */
    else spdf_paint_changed(call->doc, layer, (spdf_rect){0, 0, 0, 0});
    if (call->doc->kind == SPDF_PAINT_DOC_PDF) /* every object on it is written again with the layer's record */
        for (int i = spdf_paint_layer_index(call->doc, layer->id) + 1;
             is_layer && i < spdf_paint_group_end(call->doc, spdf_paint_layer_index(call->doc, layer->id)); i++)
            spdf_paint_pdf_note_change(call->doc, call->doc->layers[i]);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_layer_order(spdf_paint_call* call) {
    spdf_paint_layer* layer = NULL;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (layer->object && spdf_paint_entry_locked(call->doc, spdf_paint_layer_index(call->doc, layer->id)))
        return refuse_locked(call, layer);
    return spdf_paint_order_layers(call, &layer->id, 1, cJSON_GetObjectItemCaseSensitive(call->args, "to"));
}

spdf_paint_status spdf_paint_op_layer_activate(spdf_paint_call* call) {
    spdf_paint_layer* layer = NULL;
    spdf_paint_doc* doc = call->doc;
    if (find_layer(call, &layer) != SPDF_PAINT_OK) return call->status;
    if (spdf_paint_layer_is_base(layer)) return refuse_base(call);
    if (layer->object) { /* an object's row (Layers panel, context menus): selects it; its layer becomes active */
        spdf_paint_layer* owner = spdf_paint_owner(doc, layer);
        spdf_paint_select_objects(doc, &layer->id, 1);
        if (owner && owner->kind == SPDF_PAINT_LAYER_RASTER) doc->active = owner->id;
        doc->generation++;
        return SPDF_PAINT_OK;
    }
    if (layer->kind != SPDF_PAINT_LAYER_RASTER && !spdf_paint_layer_paintable(doc, layer))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "This layer can't be painted into.");
    doc->active = layer->id;
    doc->generation++;
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
