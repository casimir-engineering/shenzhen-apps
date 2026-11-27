/* Annotate's layers and the objects they hold (docs/plans/annotate.md § Decisions "Layers and objects").
 *
 * The stack stays one list, bottom to top: the base layer (a picture's or canvas's Background, a PDF's page), then
 * each layer followed by its objects, back to front. A layer (SPDF_PAINT_LAYER_RASTER) has its own pixels, which the
 * pixel tools paint into, drawn under its objects; an object belongs to the nearest layer below it in the list. The
 * base layer holds no objects. A layer's visibility, opacity and lock apply to its objects too.
 *
 * Every document starts with the base layer and one layer, "Layer 1", which takes every object and the drawing until
 * the person adds more. Here: the bookkeeping of that grouping, the object.layer operation (move objects to another
 * layer), object.duplicate (each copy just above its object) and doc.state's nested "layers". */
#include "spdf_paint_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char spdf_paint_first_layer_name[] = "Layer 1";

/* ---- Grouping ---- */

int spdf_paint_is_layer(const spdf_paint_layer* entry) {
    return entry && entry->kind != SPDF_PAINT_LAYER_OBJECT;
}

int spdf_paint_owner_index(const spdf_paint_doc* doc, int index) {
    if (!doc || index < 0 || index >= doc->layer_count) return -1;
    for (int i = index; i >= 0; i--) {
        const spdf_paint_layer* l = doc->layers[i];
        if (l->kind == SPDF_PAINT_LAYER_RASTER) return i;
        if (l->kind == SPDF_PAINT_LAYER_BACKGROUND) return i == index ? i : -1;
    }
    return -1;
}

spdf_paint_layer* spdf_paint_owner(spdf_paint_doc* doc, const spdf_paint_layer* entry) {
    int i = entry ? spdf_paint_owner_index(doc, spdf_paint_layer_index(doc, entry->id)) : -1;
    return i < 0 ? NULL : doc->layers[i];
}

int spdf_paint_group_end(const spdf_paint_doc* doc, int layer_index) {
    int i = layer_index + 1;
    while (i < doc->layer_count && doc->layers[i]->kind == SPDF_PAINT_LAYER_OBJECT) i++;
    return i;
}

int spdf_paint_layer_ordinal(const spdf_paint_doc* doc, int layer_index) {
    int n = 0;
    for (int i = 1; i <= layer_index && i < doc->layer_count; i++) n += doc->layers[i]->kind == SPDF_PAINT_LAYER_RASTER;
    return n;
}

int spdf_paint_entry_shown(const spdf_paint_doc* doc, int index) {
    if (index < 0 || index >= doc->layer_count || !doc->layers[index]->visible) return 0;
    int owner = spdf_paint_owner_index(doc, index);
    return owner < 0 || doc->layers[owner]->visible;
}

float spdf_paint_entry_opacity(const spdf_paint_doc* doc, int index) {
    if (index < 0 || index >= doc->layer_count) return 1.0f;
    float own = doc->layers[index]->opacity;
    int owner = spdf_paint_owner_index(doc, index);
    return owner >= 0 && owner != index ? own * doc->layers[owner]->opacity : own;
}

int spdf_paint_entry_locked(const spdf_paint_doc* doc, int index) {
    if (index < 0 || index >= doc->layer_count) return 1;
    const spdf_paint_layer* l = doc->layers[index];
    if (l->locked || (l->object && l->object->kind == SPDF_PAINT_OBJ_FOREIGN)) return 1;
    int owner = spdf_paint_owner_index(doc, index);
    return owner >= 0 && owner != index && doc->layers[owner]->locked;
}

static int first_layer_index(const spdf_paint_doc* doc) {
    for (int i = 1; i < doc->layer_count; i++)
        if (doc->layers[i]->kind == SPDF_PAINT_LAYER_RASTER) return i;
    return -1;
}

/* A new layer right above the base layer and its index, or -1. */
static int make_first_layer(spdf_paint_doc* doc) {
    spdf_paint_layer* layer = spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, spdf_paint_first_layer_name,
                                                   doc->layer_count ? doc->layers[0]->id : 0);
    return layer ? spdf_paint_layer_index(doc, layer->id) : -1;
}

spdf_paint_layer* spdf_paint_home_layer(spdf_paint_doc* doc) {
    int active = spdf_paint_layer_index(doc, doc->active);
    int owner = spdf_paint_owner_index(doc, active);
    if (owner > 0 && doc->layers[owner]->kind == SPDF_PAINT_LAYER_RASTER) return doc->layers[owner];
    int first = first_layer_index(doc);
    if (first < 0) first = make_first_layer(doc);
    return first < 0 ? NULL : doc->layers[first];
}

int spdf_paint_object_insert_index(spdf_paint_doc* doc, const spdf_paint_layer* source) {
    int at = source ? spdf_paint_layer_index(doc, source->id) : -1;
    if (at > 0 && doc->layers[at]->kind == SPDF_PAINT_LAYER_RASTER) return at + 1;  /* the bottom of that layer */
    spdf_paint_layer* home = source ? NULL : spdf_paint_home_layer(doc);
    if (home) return spdf_paint_group_end(doc, spdf_paint_layer_index(doc, home->id)); /* on top of it */
    int first = first_layer_index(doc);
    if (first < 0) first = make_first_layer(doc);
    return first < 0 ? -1 : first + 1;
}

int spdf_paint_normalize_layers(spdf_paint_doc* doc) {
    if (!doc || !doc->layer_count) return 0;
    if (doc->layer_count > 1 && doc->layers[1]->kind != SPDF_PAINT_LAYER_OBJECT && first_layer_index(doc) > 0) return 0;
    spdf_paint_layer* layer = calloc(1, sizeof(*layer));
    if (!layer) return 0;
    layer->id = doc->next_id++;
    layer->kind = SPDF_PAINT_LAYER_RASTER;
    layer->visible = 1;
    layer->opacity = 1.0f;
    snprintf(layer->name, sizeof(layer->name), "%s", spdf_paint_first_layer_name);
    for (int i = 0; i < doc->layer_count; i++) /* "Layer 1" taken by a layer above: this one is named as new ones */
        if (!strcmp(doc->layers[i]->name, layer->name)) snprintf(layer->name, sizeof(layer->name), "Layer %u", layer->id);
    spdf_paint_layer_insert(doc, layer, 1);
    if (spdf_paint_layer_index(doc, layer->id) != 1) { free(layer); return 0; }
    return 1;
}

spdf_paint_status spdf_paint_fail_unpaintable(spdf_paint_call* call, const spdf_paint_layer* layer) {
    if (layer && layer->kind == SPDF_PAINT_LAYER_RASTER && layer->locked)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_LOCKED, "This layer is locked; unlock it to change it.");
    return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, "The page itself can't be changed.");
}

/* ---- object.duplicate: a copy of each object just above it, the copies selected, all in one step ---- */

spdf_paint_status spdf_paint_op_object_duplicate(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_id* ids = NULL;
    int count = 0;
    spdf_paint_arg_ids(call, &ids, &count);
    spdf_paint_status status = SPDF_PAINT_OK;
    spdf_paint_layer* layer = NULL;
    for (int i = 0; i < count && status == SPDF_PAINT_OK; i++) status = spdf_paint_find_object(call, ids[i], &layer);
    cJSON* made = status == SPDF_PAINT_OK ? cJSON_AddArrayToObject(call->reply, "ids") : NULL;
    for (int i = 0; i < count && status == SPDF_PAINT_OK; i++) {
        layer = spdf_paint_layer_find(doc, ids[i]);
        spdf_paint_layer* copy = spdf_paint_layer_clone(doc->ctx, layer, 1);
        if (!copy || !copy->object) {
            spdf_paint_layer_free(doc->ctx, copy);
            status = spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
            break;
        }
        copy->id = doc->next_id++;
        fz_free(doc->ctx, copy->pdf_nm);
        copy->pdf_nm = NULL;
        fz_free(doc->ctx, copy->object->pdf_nm);
        copy->object->pdf_nm = NULL;
        if (copy->object->kind >= SPDF_PAINT_OBJ_FILL_TEXT && copy->object->kind <= SPDF_PAINT_OBJ_FILL_SIGNATURE) {
            fz_free(doc->ctx, copy->object->u.fill.nm);
            copy->object->u.fill.nm = NULL;
        }
        spdf_paint_layer_insert(doc, copy, spdf_paint_layer_index(doc, layer->id) + 1);
        spdf_paint_history_added_layer(doc, copy);
        spdf_paint_object_update_bounds(copy->object);
        spdf_paint_changed(doc, copy, copy->object->bounds);
        if (!i) cJSON_AddNumberToObject(call->reply, "id", copy->id);
        cJSON_AddItemToArray(made, cJSON_CreateNumber(copy->id));
        ids[i] = copy->id;  /* the copies become the selection */
    }
    if (status == SPDF_PAINT_OK) {
        spdf_paint_history_save_active(doc);
        spdf_paint_select_objects(doc, ids, count);
    }
    fz_free(doc->ctx, ids);
    return status;
}

/* ---- object.layer: objects into the layer above or below, or a given one ---- */

static spdf_paint_status move_failed(spdf_paint_call* call, spdf_paint_status code, const char* text) {
    return spdf_paint_call_fail(call, code, "%s", text);
}

spdf_paint_status spdf_paint_op_object_layer(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    spdf_paint_id* ids = NULL;
    int count = 0;
    spdf_paint_arg_ids(call, &ids, &count);
    const char* to = spdf_paint_arg_string(call, "to");
    double target_id = 0;
    spdf_paint_arg_number(call, "layer", &target_id);
    spdf_paint_status status = SPDF_PAINT_OK;
    int target = -1, up = to && !strcmp(to, "above");
    if (!to && !target_id) {
        fz_free(doc->ctx, ids);
        return move_failed(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "Say where: \"to\" above or below, or a \"layer\".");
    }
    for (int i = 0; i < count && status == SPDF_PAINT_OK; i++) {
        int index = spdf_paint_layer_index(doc, ids[i]);
        if (index < 0 || doc->layers[index]->kind != SPDF_PAINT_LAYER_OBJECT)
            status = spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no object %u.", (unsigned)ids[i]);
        else if (spdf_paint_entry_locked(doc, index))
            status = move_failed(call, SPDF_PAINT_ERR_LOCKED, "This object is locked, or on a locked layer.");
        else if (!target_id && i == 0) { /* above or below the first object's layer */
            int owner = spdf_paint_owner_index(doc, index);
            for (int k = up ? spdf_paint_group_end(doc, owner) : owner - 1; target < 0 && k > 0 && k < doc->layer_count;
                 k += up ? 1 : -1)
                if (doc->layers[k]->kind == SPDF_PAINT_LAYER_RASTER) target = k;
            if (target < 0)
                status = move_failed(call, SPDF_PAINT_ERR_INVALID_ARGUMENT,
                                     up ? "There is no layer above this one." : "There is no layer below this one.");
        }
    }
    if (status == SPDF_PAINT_OK && target_id) {
        target = spdf_paint_layer_index(doc, (spdf_paint_id)target_id);
        if (target == 0)
            status = move_failed(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "Objects can't go on the base layer.");
        else if (target < 0 || doc->layers[target]->kind == SPDF_PAINT_LAYER_OBJECT)
            status = spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOT_FOUND, "There is no layer %u.", (unsigned)target_id);
    }
    if (status == SPDF_PAINT_OK && target > 0 && doc->layers[target]->locked)
        status = move_failed(call, SPDF_PAINT_ERR_LOCKED, "That layer is locked.");
    if (status != SPDF_PAINT_OK || target <= 0) {
        fz_free(doc->ctx, ids);
        return status ? status : move_failed(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "Name objects to move.");
    }
    spdf_paint_layer* into = doc->layers[target];
    spdf_paint_history_save_order(doc);
    /* Taken out in their stacking order, then put back together: up, at the bottom of the layer above (nearest to
     * where they were); down, on top of the layer below; into a given layer, on its top. */
    spdf_paint_layer** moving = malloc((size_t)count * sizeof(*moving));
    int n = 0;
    for (int i = 1; moving && i < doc->layer_count;) {
        int picked = 0;
        for (int k = 0; k < count && !picked; k++) picked = doc->layers[i]->id == ids[k];
        if (!picked) { i++; continue; }
        moving[n++] = doc->layers[i];
        memmove(doc->layers + i, doc->layers + i + 1, (size_t)(doc->layer_count - i - 1) * sizeof(*doc->layers));
        doc->layer_count--;
    }
    if (!moving) {
        fz_free(doc->ctx, ids);
        return move_failed(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
    }
    int at = spdf_paint_layer_index(doc, into->id), end = spdf_paint_group_end(doc, at);
    double position = -1; /* from the bottom of that layer's objects (the Layers panel's drop) */
    if (spdf_paint_arg_number(call, "position", &position) && position >= 0)
        at = at + 1 + (position < end - at - 1 ? (int)position : end - at - 1);
    else at = up && !target_id ? at + 1 : end;
    for (int k = 0; k < n; k++) spdf_paint_layer_insert(doc, moving[k], at + k);
    free(moving);
    fz_free(doc->ctx, ids);
    spdf_paint_damage_all(doc);
    cJSON_AddNumberToObject(call->reply, "layer", into->id);
    return SPDF_PAINT_OK;
}

/* ---- doc.state "layers": each layer with its objects ---- */

cJSON* spdf_paint_layers_json(const spdf_paint_doc* doc) {
    cJSON* layers = cJSON_CreateArray();
    cJSON* objects = NULL;
    for (int i = 0; i < doc->layer_count; i++) {
        const spdf_paint_layer* l = doc->layers[i];
        cJSON* entry = spdf_paint_layer_json(doc, l);
        if (l->kind != SPDF_PAINT_LAYER_OBJECT) {
            cJSON_AddItemToArray(layers, entry);
            objects = l->kind == SPDF_PAINT_LAYER_RASTER ? cJSON_AddArrayToObject(entry, "objects") : NULL;
            if (objects) cJSON_AddNumberToObject(entry, "position", spdf_paint_layer_ordinal(doc, i) - 1);
            continue;
        }
        if (objects) cJSON_AddItemToArray(objects, entry);
        else cJSON_AddItemToArray(layers, entry); /* not expected: the stack is normalised on every way in */
    }
    return layers;
}
