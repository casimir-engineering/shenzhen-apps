/* Annotate's layers in a PDF (docs/plans/annotate.md § 5 PDFs, "Layers"): every annotation Annotate writes for an
 * object, and every Fill & Sign item it moves or changes, carries its layer in /SPDFAnnotate /Layer:
 *   << /Id (spdf-annotate-layer-<uuid>) /Name (Layer 2) /Order 2 /Visible true /Opacity 0.8 /Locked false >>
 * /Id is the layer's own name in the file: the /NM of the Stamp that holds its drawing, when it has one. A layer's
 * drawing is that Stamp; a layer with no drawing lives only in its objects' records. /Annots holds the layers in
 * order, each followed by its objects back to front, so other readers stack them the same way.
 *
 * Reading (spdf_paint_pdf.c calls spdf_paint_pdf_arrange after one pass over /Annots) rebuilds the layers from the
 * records: on opening, the layers in /Order with their names, visibility and opacity, every object on its layer. An
 * annotation with no record (written before layers held objects, by Fill & Sign alone, or by another app) goes on the
 * lowest layer, "Layer 1", where the page's first layer is made. On a reload (after a write, or another writer's
 * change) the canvas is the model: only annotations read again follow their record. */
#include "spdf_paint_model.h"
#include "spdf_paint_pdf_internal.h"
#include "spdf_paint_pdf_layers.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Records ---- */

static const char* key_of(const spdf_paint_layer* layer) {
    return layer && layer->pdf_nm && spdf_paint_pdf_has_prefix(layer->pdf_nm, SPDF_PAINT_LAYER_NM_PREFIX) &&
                   strlen(layer->pdf_nm) < 64
               ? layer->pdf_nm
               : "";
}

const char* spdf_paint_pdf_layer_key(const spdf_paint_layer* layer) { return key_of(layer); }

int spdf_paint_pdf_name_empty_layer(spdf_paint_doc* doc, spdf_paint_layer* layer, spdf_paint_pdf_entry* e) {
    if (layer->kind != SPDF_PAINT_LAYER_RASTER || layer->pixels || (e && e->file && e->file[0])) return 0;
    if (!e) {
        if (!key_of(layer)[0]) {
            char uuid[33], name[64];
            spdf_paint_pdf_uuid(uuid);
            snprintf(name, sizeof name, "%s%s", SPDF_PAINT_LAYER_NM_PREFIX, uuid);
            fz_free(doc->ctx, layer->pdf_nm);
            layer->pdf_nm = fz_strdup(doc->ctx, name);
        }
        e = spdf_paint_pdf_entry_add(doc, layer->id, SPDF_PAINT_PDF_OURS, layer->pdf_nm, 0);
    }
    e->seen = 1;
    spdf_paint_pdf_entry_set(doc, e, spdf_paint_pdf_layer_state(doc, layer), spdf_paint_pdf_strdup(""));
    return 1;
}

void spdf_paint_pdf_put_layer_record(spdf_paint_doc* doc, pdf_obj* annot, const spdf_paint_layer* entry) {
    fz_context* ctx = doc->ctx;
    int index = spdf_paint_layer_index(doc, entry->id), owner = spdf_paint_owner_index(doc, index);
    if (owner <= 0) return;
    const spdf_paint_layer* layer = doc->layers[owner];
    pdf_obj* ours = pdf_dict_gets(ctx, annot, SPDF_PAINT_PDF_KEY);
    if (!pdf_is_dict(ctx, ours)) ours = pdf_dict_puts_dict(ctx, annot, SPDF_PAINT_PDF_KEY, 2);
    pdf_obj* rec = pdf_dict_puts_dict(ctx, ours, "Layer", 5);
    pdf_dict_puts_drop(ctx, rec, "Id", pdf_new_text_string(ctx, key_of(layer)));
    pdf_dict_puts_drop(ctx, rec, "Name", pdf_new_text_string(ctx, layer->name));
    pdf_dict_puts_drop(ctx, rec, "Order", pdf_new_int(ctx, spdf_paint_layer_ordinal(doc, owner)));
    pdf_dict_puts(ctx, rec, "Visible", layer->visible ? PDF_TRUE : PDF_FALSE);
    pdf_dict_puts_drop(ctx, rec, "Opacity", pdf_new_real(ctx, layer->opacity));
    pdf_dict_puts(ctx, rec, "Locked", layer->locked ? PDF_TRUE : PDF_FALSE);
}

int spdf_paint_pdf_read_layer_record(fz_context* ctx, pdf_obj* annot, spdf_paint_pdf_layer_record* out) {
    pdf_obj* rec = pdf_dict_gets(ctx, pdf_dict_gets(ctx, annot, SPDF_PAINT_PDF_KEY), "Layer");
    memset(out, 0, sizeof(*out));
    const char* key = pdf_to_text_string(ctx, pdf_dict_gets(ctx, rec, "Id"));
    if (!pdf_is_dict(ctx, rec) || !spdf_paint_pdf_has_prefix(key, SPDF_PAINT_LAYER_NM_PREFIX)) return 0;
    out->present = 1;
    snprintf(out->key, sizeof(out->key), "%s", key);
    snprintf(out->name, sizeof(out->name), "%s", pdf_to_text_string(ctx, pdf_dict_gets(ctx, rec, "Name")));
    out->order = pdf_to_int(ctx, pdf_dict_gets(ctx, rec, "Order"));
    out->visible = pdf_dict_gets(ctx, rec, "Visible") ? pdf_to_bool(ctx, pdf_dict_gets(ctx, rec, "Visible")) : 1;
    out->opacity = pdf_dict_gets(ctx, rec, "Opacity") ? pdf_to_real(ctx, pdf_dict_gets(ctx, rec, "Opacity")) : 1.0f;
    if (out->opacity < 0 || out->opacity > 1) out->opacity = 1;
    out->locked = pdf_to_bool(ctx, pdf_dict_gets(ctx, rec, "Locked"));
    return 1;
}

void spdf_paint_pdf_read_props(fz_context* ctx, pdf_obj* annot, spdf_paint_layer* layer,
                               const spdf_paint_pdf_layer_record* rec) {
    int hidden = (pdf_dict_get_int(ctx, annot, PDF_NAME(F)) & PDF_ANNOT_IS_HIDDEN) != 0;
    float opacity = pdf_dict_get_real_default(ctx, annot, PDF_NAME(CA), 1);
    if (layer->kind == SPDF_PAINT_LAYER_RASTER && rec && rec->present) { /* a layer's drawing: the layer's own */
        layer->visible = rec->visible, layer->opacity = rec->opacity, layer->locked = rec->locked;
        return;
    }
    if (rec && rec->present) { /* what the layer explains is the layer's: an object keeps the rest */
        layer->visible = rec->visible ? !hidden : 1;
        layer->opacity = rec->opacity > 0.001f ? fminf(1.0f, opacity / rec->opacity) : 1.0f;
        return;
    }
    layer->visible = !hidden;
    layer->opacity = opacity;
}

void spdf_paint_pdf_state_layer(spdf_paint_doc* doc, cJSON* s, const spdf_paint_layer* entry) {
    int index = spdf_paint_layer_index(doc, entry->id), owner = spdf_paint_owner_index(doc, index);
    cJSON_AddBoolToObject(s, "ev", spdf_paint_entry_shown(doc, index));
    cJSON_AddNumberToObject(s, "eo", floorf(spdf_paint_entry_opacity(doc, index) * 1000.0f + 0.5f));
    if (owner <= 0) return;
    const spdf_paint_layer* layer = doc->layers[owner];
    cJSON* l = cJSON_AddArrayToObject(s, "L");
    cJSON_AddItemToArray(l, cJSON_CreateString(key_of(layer)));
    cJSON_AddItemToArray(l, cJSON_CreateString(layer->name));
    cJSON_AddItemToArray(l, cJSON_CreateNumber(spdf_paint_layer_ordinal(doc, owner)));
    cJSON_AddItemToArray(l, cJSON_CreateBool(layer->visible));
    cJSON_AddItemToArray(l, cJSON_CreateNumber(floorf(layer->opacity * 1000.0f + 0.5f)));
    cJSON_AddItemToArray(l, cJSON_CreateBool(layer->locked));
}

/* ---- Finding a layer by its record ---- */

static spdf_paint_layer* layer_by_key(spdf_paint_doc* doc, const char* key) {
    for (int i = 1; key && *key && i < doc->layer_count; i++)
        if (doc->layers[i]->kind == SPDF_PAINT_LAYER_RASTER && !strcmp(key_of(doc->layers[i]), key)) return doc->layers[i];
    return NULL;
}

/* The lowest layer no record named yet: the page's own "Layer 1" while a first read hasn't given it a name. */
static spdf_paint_layer* unclaimed(spdf_paint_doc* doc) {
    for (int i = 1; i < doc->layer_count; i++)
        if (doc->layers[i]->kind == SPDF_PAINT_LAYER_RASTER && !key_of(doc->layers[i])[0]) return doc->layers[i];
    return NULL;
}

static void claim(spdf_paint_doc* doc, spdf_paint_layer* layer, const spdf_paint_pdf_layer_record* rec) {
    fz_free(doc->ctx, layer->pdf_nm);
    layer->pdf_nm = fz_strdup(doc->ctx, rec->key);
    if (rec->name[0]) snprintf(layer->name, sizeof(layer->name), "%s", rec->name);
    layer->visible = rec->visible, layer->opacity = rec->opacity, layer->locked = rec->locked;
}

spdf_paint_layer* spdf_paint_pdf_layer_for(spdf_paint_doc* doc, const spdf_paint_pdf_layer_record* rec, int first_read) {
    spdf_paint_layer* layer = rec && rec->present ? layer_by_key(doc, rec->key) : NULL;
    if (layer || !rec || !rec->present) return layer;
    layer = first_read && rec->order <= 1 ? unclaimed(doc) : NULL; /* the lowest layer is the page's own Layer 1 */
    if (!layer) layer = spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, rec->name[0] ? rec->name : NULL, 0);
    if (layer) claim(doc, layer, rec);
    return layer;
}

spdf_paint_layer* spdf_paint_pdf_layer_for_drawing(spdf_paint_doc* doc, const char* nm, const char* name,
                                                   const spdf_paint_pdf_layer_record* rec, int first_read) {
    if (rec && rec->present) {
        spdf_paint_pdf_layer_record own = *rec; /* its /Id is its /NM */
        snprintf(own.key, sizeof(own.key), "%s", nm);
        return spdf_paint_pdf_layer_for(doc, &own, first_read);
    }
    spdf_paint_layer* layer = layer_by_key(doc, nm);
    if (layer) return layer;
    layer = first_read ? unclaimed(doc) : NULL; /* written before layers held objects: Layer 1's drawing */
    if (!layer) layer = spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, name && *name ? name : NULL, 0);
    if (layer) fz_free(doc->ctx, layer->pdf_nm), layer->pdf_nm = fz_strdup(doc->ctx, nm);
    return layer;
}

spdf_paint_layer* spdf_paint_pdf_lowest_layer(spdf_paint_doc* doc) {
    for (int i = 1; i < doc->layer_count; i++)
        if (doc->layers[i]->kind == SPDF_PAINT_LAYER_RASTER) return doc->layers[i];
    return spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, spdf_paint_first_layer_name, doc->layers[0]->id);
}

/* ---- Arranging the stack after a read ---- */

typedef struct group {
    spdf_paint_layer* layer;
    double sort;              /* /Order on a first read; the canvas's own order otherwise */
    spdf_paint_layer** items; /* its objects, back to front */
    int count;
} group;

static group* group_of(group* groups, int n, const spdf_paint_layer* layer) {
    for (int i = 0; i < n; i++)
        if (groups[i].layer == layer) return &groups[i];
    return NULL;
}

static int by_sort(const void* a, const void* b) {
    double d = ((const group*)a)->sort - ((const group*)b)->sort;
    return d < 0 ? -1 : d > 0;
}

void spdf_paint_pdf_arrange(spdf_paint_doc* doc, spdf_paint_pdf_placed* placed, int count, int first_read) {
    int total = doc->layer_count, n = 0, i, j;
    group* groups = calloc((size_t)total, sizeof(*groups));
    spdf_paint_layer** items = calloc((size_t)total + 1, sizeof(*items));
    spdf_paint_layer** owner_was = calloc((size_t)total + 1, sizeof(*owner_was));
    unsigned char* taken = calloc((size_t)total + 1, 1);
    if (!groups || !items || !owner_was || !taken) goto done;
    for (j = 0; j < count; j++) /* the layers the records name: found, the page's own Layer 1, or made */
        if (placed[j].reread && placed[j].record.present) spdf_paint_pdf_layer_for(doc, &placed[j].record, first_read);
    if (doc->layer_count != total) { /* layers were made: the scratch arrays are sized again */
        total = doc->layer_count;
        free(groups), free(items), free(owner_was), free(taken);
        groups = calloc((size_t)total, sizeof(*groups));
        items = calloc((size_t)total + 1, sizeof(*items));
        owner_was = calloc((size_t)total + 1, sizeof(*owner_was));
        taken = calloc((size_t)total + 1, 1);
        if (!groups || !items || !owner_was || !taken) goto done;
    }
    for (i = 1; i < total; i++) { /* the layers, and the layer each object is on now */
        spdf_paint_layer* l = doc->layers[i];
        int owner = spdf_paint_owner_index(doc, i);
        owner_was[i] = owner > 0 ? doc->layers[owner] : NULL;
        if (l->kind != SPDF_PAINT_LAYER_RASTER) continue;
        groups[n].layer = l, groups[n].sort = n, groups[n].items = items, n++;
    }
    if (!n) goto done; /* not expected: the page's Layer 1 is made before the first read */
    if (first_read) { /* the file's order: a layer without a record stays just above the one before it */
        double last = -1;
        for (i = 0; i < n; i++) {
            double order = -1;
            for (j = 0; j < count && order < 0; j++)
                if (placed[j].record.present && !strcmp(placed[j].record.key, key_of(groups[i].layer)))
                    order = placed[j].record.order;
            groups[i].sort = order >= 0 ? order : last + 0.001;
            last = groups[i].sort;
        }
        qsort(groups, (size_t)n, sizeof(*groups), by_sort);
    }
    /* Which layer each object goes on: its record (read now), else where it is, else the lowest. */
    for (j = 0; j < count; j++) {
        int index = spdf_paint_layer_index(doc, placed[j].layer);
        if (index <= 0 || doc->layers[index]->kind != SPDF_PAINT_LAYER_OBJECT) continue;
        spdf_paint_layer* on = NULL;
        if (placed[j].reread && placed[j].record.present) on = layer_by_key(doc, placed[j].record.key);
        if (!on && !placed[j].fresh) on = owner_was[index];
        placed[j].on = on ? on : groups[0].layer;
    }
    /* Back to front within each layer: the file's order, and what isn't in the file just above what it was above. */
    int k = 0;
    for (i = 0; i < n; i++) {
        groups[i].items = items + k;
        for (j = 0; j < count; j++) {
            int index = spdf_paint_layer_index(doc, placed[j].layer);
            if (index <= 0 || taken[index] || placed[j].on != groups[i].layer) continue;
            groups[i].items[groups[i].count++] = doc->layers[index], taken[index] = 1, k++;
        }
    }
    for (i = 1; i < total; i++) {
        spdf_paint_layer* l = doc->layers[i];
        if (l->kind != SPDF_PAINT_LAYER_OBJECT || taken[i]) continue;
        group* g = group_of(groups, n, owner_was[i]);
        if (!g) g = &groups[0];
        int at = 0; /* after the object it followed, when that one is on the same layer */
        for (j = 0; j < g->count; j++)
            if (g->items[j] == doc->layers[i - 1]) at = j + 1;
        /* Groups are laid out in one array: make room by moving the later groups up one. */
        spdf_paint_layer** end = items + k;
        spdf_paint_layer** slot = g->items + at;
        memmove(slot + 1, slot, (size_t)(end - slot) * sizeof(*slot));
        *slot = l, g->count++, k++, taken[i] = 1;
        for (j = (int)(g - groups) + 1; j < n; j++) groups[j].items++;
    }
    { /* the base layer, then each layer and its objects */
        spdf_paint_layer** out = calloc((size_t)total, sizeof(*out));
        int m = 0;
        if (!out) goto done;
        out[m++] = doc->layers[0];
        for (i = 0; i < n; i++) {
            out[m++] = groups[i].layer;
            for (j = 0; j < groups[i].count; j++) out[m++] = groups[i].items[j];
        }
        if (m == total) memcpy(doc->layers, out, (size_t)total * sizeof(*out));
        free(out);
    }
done:
    free(groups);
    free(items);
    free(owner_was);
    free(taken);
}
