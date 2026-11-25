/* A PDF page as an Annotate canvas (docs/plans/annotate.md § 5 PDFs, § 8 Core spdf_paint_pdf.c): the page rendered
 * as the locked Background (render only, at the scale asked), and its annotations read into layers and objects in
 * /Annots order (back to front): ours from /SPDFAnnotate, Fill & Sign's from their /NM names (spdf_fill_load_items),
 * other readers' shown but locked. Writing back is spdf_paint_pdf_write.c; the sync model is described in
 * spdf_paint_pdf_internal.h. Never rewrites the page itself. */
#include "spdf_paint_model.h"
#include "spdf_paint_pdf_internal.h"

#include "spdf_core_document.h"
#include "spdf_fill_items.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

int spdf_paint_pdf_has_prefix(const char* text, const char* prefix) {
    return text && strncmp(text, prefix, strlen(prefix)) == 0;
}

const char* spdf_paint_pdf_nm(fz_context* ctx, pdf_obj* annot) {
    return pdf_to_text_string(ctx, pdf_dict_gets(ctx, annot, "NM"));
}

/* ---- Bookkeeping ---- */

spdf_paint_pdf_state* spdf_paint_pdf_state_of(spdf_paint_doc* doc) { return doc ? doc->pdf_state : NULL; }

spdf_paint_pdf_entry* spdf_paint_pdf_entry_for(spdf_paint_doc* doc, spdf_paint_id layer) {
    spdf_paint_pdf_state* st = spdf_paint_pdf_state_of(doc);
    int i;
    for (i = 0; st && i < st->count; ++i)
        if (st->entries[i].layer == layer) return &st->entries[i];
    return NULL;
}

static spdf_paint_pdf_entry* entry_by_identity(spdf_paint_doc* doc, const char* nm, int object_number) {
    spdf_paint_pdf_state* st = spdf_paint_pdf_state_of(doc);
    int i;
    for (i = 0; st && i < st->count; ++i) {
        spdf_paint_pdf_entry* e = &st->entries[i];
        if (nm && e->nm && strcmp(e->nm, nm) == 0) return e;
        if (!nm && object_number && e->object_number == object_number) return e;
    }
    return NULL;
}

spdf_paint_pdf_entry* spdf_paint_pdf_entry_add(spdf_paint_doc* doc, spdf_paint_id layer, spdf_paint_pdf_origin origin,
                                               const char* nm, int object_number) {
    spdf_paint_pdf_state* st = doc->pdf_state;
    spdf_paint_pdf_entry* e;
    if (st->count == st->cap) {
        int cap = st->cap ? st->cap * 2 : 16;
        spdf_paint_pdf_entry* grown = (spdf_paint_pdf_entry*)realloc(st->entries, (size_t)cap * sizeof(*grown));
        if (!grown) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
        st->entries = grown, st->cap = cap;
    }
    e = &st->entries[st->count++];
    memset(e, 0, sizeof(*e));
    e->layer = layer, e->origin = origin, e->object_number = object_number;
    e->nm = nm ? spdf_paint_pdf_strdup(nm) : NULL;
    return e;
}

void spdf_paint_pdf_entry_set(spdf_paint_doc* doc, spdf_paint_pdf_entry* entry, char* model, char* file) {
    SPDF_PAINT_UNUSED(doc);
    if (model) free(entry->model), entry->model = model;
    if (file) free(entry->file), entry->file = file;
}

void spdf_paint_pdf_entry_remove(spdf_paint_doc* doc, spdf_paint_pdf_entry* entry) {
    spdf_paint_pdf_state* st = doc->pdf_state;
    int i = (int)(entry - st->entries);
    free(entry->nm), free(entry->model), free(entry->file);
    memmove(&st->entries[i], &st->entries[i + 1], (size_t)(st->count - i - 1) * sizeof(*entry));
    --st->count;
}

void spdf_paint_pdf_close(spdf_paint_doc* doc) {
    spdf_paint_pdf_state* st = spdf_paint_pdf_state_of(doc);
    int i;
    if (!st) return;
    for (i = 0; i < st->count; ++i) free(st->entries[i].nm), free(st->entries[i].model), free(st->entries[i].file);
    free(st->entries);
    spdf_paint_pdf_retired_free(st);
    fz_drop_display_list(doc->ctx, st->page_list);
    free(st);
    doc->pdf_state = NULL;
}

pdf_page* spdf_paint_pdf_load_page(spdf_paint_doc* doc) {
    pdf_document* pdf = pdf_specifics(doc->ctx, doc->pdf->doc);
    if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only PDF pages can be annotated.");
    return pdf_load_page(doc->ctx, pdf, doc->page_index);
}

/* ---- Layers made or dropped by a read ---- */

static void drop_layer(spdf_paint_doc* doc, int index) {
    spdf_paint_layer* layer = doc->layers[index];
    spdf_paint_layer_free(doc->ctx, layer); /* Core A's: structs with free, strings and pixels with fz */
    memmove(&doc->layers[index], &doc->layers[index + 1], (size_t)(doc->layer_count - index - 1) * sizeof(*doc->layers));
    --doc->layer_count;
}

static void set_layer_name(spdf_paint_layer* layer, const char* name) {
    if (!name || !*name) return;
    strncpy(layer->name, name, SPDF_PAINT_NAME_MAX - 1);
    layer->name[SPDF_PAINT_NAME_MAX - 1] = 0;
}

/* A new object layer, or the existing one's object emptied for new parameters (same id, same place in the stack). */
static spdf_paint_object* object_for(spdf_paint_doc* doc, spdf_paint_layer** layer, spdf_paint_object_kind kind) {
    spdf_paint_id id = 0;
    spdf_paint_object* object;
    if (*layer) {
        spdf_paint_object_free(doc->ctx, (*layer)->object);
        object = (spdf_paint_object*)calloc(1, sizeof(*object)); /* freed with free(), as Core A's */
        if (!object) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
        object->kind = kind;
        (*layer)->object = object;
        return object;
    }
    object = spdf_paint_object_new(doc, kind, &id);
    *layer = spdf_paint_layer_find(doc, id);
    if (!object || !*layer) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Couldn't add an object to the page.");
    return object;
}

static spdf_rect page_rect_of(fz_context* ctx, pdf_obj* annot, fz_matrix page_ctm) {
    fz_rect r = fz_transform_rect(pdf_dict_get_rect(ctx, annot, PDF_NAME(Rect)), page_ctm);
    spdf_rect out = {r.x0, r.y0, r.x1, r.y1};
    return out;
}

static void read_visibility(fz_context* ctx, pdf_obj* annot, spdf_paint_layer* layer) {
    layer->visible = !(pdf_dict_get_int(ctx, annot, PDF_NAME(F)) & PDF_ANNOT_IS_HIDDEN);
    layer->opacity = pdf_dict_get_real_default(ctx, annot, PDF_NAME(CA), 1);
}

/* ---- Our annotations: the image in their appearance ---- */

static fz_pixmap* canvas_pixmap(spdf_paint_doc* doc) {
    fz_pixmap* p = fz_new_pixmap(doc->ctx, fz_device_rgb(doc->ctx), doc->width * doc->raster_scale,
                                 doc->height * doc->raster_scale, NULL, 1);
    fz_clear_pixmap(doc->ctx, p);
    return p;
}

/* A drawing layer: its Stamp's picture back into a canvas-sized pixmap at /Box. */
static void read_raster(spdf_paint_doc* doc, pdf_document* pdf, pdf_obj* annot, pdf_obj* ours, spdf_paint_layer* layer) {
    fz_context* ctx = doc->ctx;
    pdf_obj* box = pdf_dict_gets(ctx, ours, "Box");
    fz_pixmap* image = spdf_paint_pdf_appearance_pixels(ctx, pdf, annot);
    fz_pixmap* canvas;
    int x0 = pdf_array_get_int(ctx, box, 0), y0 = pdf_array_get_int(ctx, box, 1), y, w, h;
    fz_drop_pixmap(ctx, layer->pixels);
    layer->pixels = canvas = canvas_pixmap(doc);
    if (!image) return;
    w = fz_mini(image->w, canvas->w - x0), h = fz_mini(image->h, canvas->h - y0);
    for (y = 0; y < h && x0 >= 0 && y0 >= 0; ++y)
        if (w > 0)
            memcpy(canvas->samples + (size_t)(y0 + y) * canvas->stride + (size_t)x0 * 4,
                   image->samples + (size_t)y * image->stride, (size_t)w * 4);
    layer->pdf_used = fz_make_irect(x0, y0, x0 + fz_maxi(w, 0), y0 + fz_maxi(h, 0));
    fz_drop_pixmap(ctx, image);
}

static void read_ours(spdf_paint_doc* doc, pdf_document* pdf, pdf_obj* annot, spdf_paint_layer** layer) {
    fz_context* ctx = doc->ctx;
    pdf_obj* ours = pdf_dict_gets(ctx, annot, SPDF_PAINT_PDF_KEY);
    const char* kind = pdf_to_text_string(ctx, pdf_dict_gets(ctx, ours, "Kind"));
    const char* name = pdf_to_text_string(ctx, pdf_dict_gets(ctx, ours, "Name"));
    if (strcmp(kind, "layer") == 0) {
        if (!*layer) *layer = spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, name, 0);
        if (!*layer) fz_throw(ctx, FZ_ERROR_SYSTEM, "Couldn't add a layer to the page.");
        read_raster(doc, pdf, annot, ours, *layer);
    } else {
        spdf_paint_object_kind k = strcmp(kind, "text") == 0      ? SPDF_PAINT_OBJ_TEXT
                                   : strcmp(kind, "picture") == 0 ? SPDF_PAINT_OBJ_PICTURE
                                                                  : SPDF_PAINT_OBJ_SHAPE;
        const char* text = pdf_to_text_string(ctx, pdf_dict_gets(ctx, ours, "Args"));
        cJSON* args = cJSON_Parse(text);
        spdf_paint_object* object;
        fz_try(ctx) {
            object = object_for(doc, layer, k);
            spdf_paint_pdf_object_from_args(ctx, object, args);
            if (k == SPDF_PAINT_OBJ_PICTURE) object->u.picture.pixels = spdf_paint_pdf_appearance_pixels(ctx, pdf, annot);
            object->pdf_nm = fz_strdup(ctx, spdf_paint_pdf_nm(ctx, annot));
            spdf_paint_object_update_bounds(object);
        }
        fz_always(ctx) cJSON_Delete(args);
        fz_catch(ctx) fz_rethrow(ctx);
    }
    fz_free(ctx, (*layer)->pdf_nm);
    (*layer)->pdf_nm = fz_strdup(ctx, spdf_paint_pdf_nm(ctx, annot));
    set_layer_name(*layer, name);
}

/* ---- Fill & Sign's items, as objects of this model ---- */

static const spdf_fill_item* fill_item(const spdf_fill_items* items, const char* group, spdf_rect* bounds, int* cells) {
    const spdf_fill_item* first = NULL;
    int i;
    *cells = 0;
    for (i = 0; i < items->count; ++i) {
        const spdf_fill_item* it = &items->items[i];
        if (strcmp(it->group, group) != 0) continue;
        if (!first) first = it, *bounds = it->rect;
        bounds->x0 = fminf(bounds->x0, it->rect.x0), bounds->y0 = fminf(bounds->y0, it->rect.y0);
        bounds->x1 = fmaxf(bounds->x1, it->rect.x1), bounds->y1 = fmaxf(bounds->y1, it->rect.y1);
        ++*cells;
    }
    return first;
}

static void read_fill(spdf_paint_doc* doc, const spdf_fill_item* it, spdf_rect bounds, spdf_paint_layer** layer) {
    fz_context* ctx = doc->ctx;
    static const char* const names[] = {"Text", "Check", "Cross", "Signature", "Initials", "Pen line", "Arrow"};
    spdf_paint_object* o;
    if (it->kind == SPDF_FILL_PEN || it->kind == SPDF_FILL_ARROW) {
        int i;
        o = object_for(doc, layer, it->kind == SPDF_FILL_PEN ? SPDF_PAINT_OBJ_PEN : SPDF_PAINT_OBJ_ARROW);
        o->u.line.points = fz_malloc_array(ctx, it->point_count > 0 ? it->point_count : 1, spdf_paint_point);
        for (i = 0; i < it->point_count; ++i) {
            o->u.line.points[i].x = it->points[i].x, o->u.line.points[i].y = it->points[i].y;
            o->u.line.points[i].pressure = 1;
        }
        o->u.line.point_count = it->point_count;
        o->u.line.color = spdf_paint_pdf_from_rgb(it->rgb, 3);
        o->u.line.width = it->width;
    } else {
        o = object_for(doc, layer, it->kind == SPDF_FILL_TEXT                                ? SPDF_PAINT_OBJ_FILL_TEXT
                                   : it->kind == SPDF_FILL_CHECK || it->kind == SPDF_FILL_CROSS ? SPDF_PAINT_OBJ_FILL_MARK
                                                                                              : SPDF_PAINT_OBJ_FILL_SIGNATURE);
        o->u.fill.nm = fz_strdup(ctx, it->group);
        o->u.fill.fill_kind = (int)it->kind;
        o->u.fill.text = it->text ? fz_strdup(ctx, it->text) : NULL;
        o->u.fill.font_size = it->font_size;
    }
    o->place.rect = bounds;
    o->pdf_nm = fz_strdup(ctx, it->group);
    spdf_paint_object_update_bounds(o);
    o->bounds = bounds;
    if (it->kind == SPDF_FILL_TEXT && it->text && *it->text) {
        char name[SPDF_PAINT_NAME_MAX];
        snprintf(name, sizeof name, "Text: %.60s", it->text);
        set_layer_name(*layer, name);
    } else if ((int)it->kind >= 0 && (int)it->kind <= SPDF_FILL_ARROW) {
        set_layer_name(*layer, names[it->kind]);
    }
}

static void read_foreign(spdf_paint_doc* doc, pdf_obj* annot, fz_matrix page_ctm, spdf_paint_layer** layer) {
    fz_context* ctx = doc->ctx;
    spdf_paint_object* o = object_for(doc, layer, SPDF_PAINT_OBJ_FOREIGN);
    const char* subtype = pdf_to_name(ctx, pdf_dict_get(ctx, annot, PDF_NAME(Subtype)));
    o->u.foreign.object_number = pdf_to_num(ctx, annot);
    snprintf(o->u.foreign.subtype, sizeof o->u.foreign.subtype, "%s", subtype);
    o->place.rect = o->bounds = page_rect_of(ctx, annot, page_ctm);
    (*layer)->locked = 1;
    set_layer_name(*layer, subtype);
}

/* ---- One pass over /Annots ---- */

static int unmodelled(fz_context* ctx, pdf_obj* annot) {
    pdf_obj* subtype = pdf_dict_get(ctx, annot, PDF_NAME(Subtype));
    return !pdf_is_dict(ctx, annot) || subtype == PDF_NAME(Widget) || subtype == PDF_NAME(Link) ||
           subtype == PDF_NAME(Popup);
}

/* The model's stack in the file's order: Background, then the annotations' layers as /Annots has them; a layer the
 * file doesn't hold (never written) stays just above the layer it was above. */
static void order_layers(spdf_paint_doc* doc, const spdf_paint_id* order, int count) {
    spdf_paint_layer** sorted = (spdf_paint_layer**)calloc((size_t)doc->layer_count, sizeof(*sorted));
    int n = 0, i, j;
    if (!sorted) return;
    sorted[n++] = doc->layers[0];
    for (i = 0; i < count; ++i) {
        int k = spdf_paint_layer_index(doc, order[i]);
        if (k > 0) sorted[n++] = doc->layers[k];
    }
    for (i = 1; i < doc->layer_count; ++i) {
        spdf_paint_layer* l = doc->layers[i];
        int placed = 0, at = n;
        for (j = 0; j < n && !placed; ++j) placed = sorted[j] == l;
        if (placed) continue;
        for (j = 0; j < n; ++j)
            if (sorted[j] == doc->layers[i - 1]) at = j + 1;
        memmove(&sorted[at + 1], &sorted[at], (size_t)(n - at) * sizeof(*sorted));
        sorted[at] = l, ++n;
    }
    memcpy(doc->layers, sorted, (size_t)n * sizeof(*sorted));
    free(sorted);
}

void spdf_paint_pdf_read(spdf_paint_doc* doc, int reload) {
    fz_context* ctx = doc->ctx;
    spdf_paint_pdf_state* st = doc->pdf_state;
    pdf_page* volatile page = NULL;
    spdf_fill_items items = {0};
    spdf_paint_id* volatile order = NULL;
    char err[256];
    int i, changed = !reload;
    for (i = 0; i < st->count; ++i) st->entries[i].seen = 0;
    if (!spdf_fill_load_items(doc->pdf, doc->page_index, &items, err, sizeof err)) fz_throw(ctx, FZ_ERROR_FORMAT, "%s", err);
    fz_try(ctx) {
        pdf_document* pdf;
        pdf_obj* annots;
        fz_matrix page_ctm;
        int n, count = 0;
        page = spdf_paint_pdf_load_page(doc);
        pdf = page->doc;
        pdf_page_transform(ctx, page, NULL, &page_ctm);
        annots = pdf_dict_get(ctx, page->obj, PDF_NAME(Annots));
        n = pdf_array_len(ctx, annots);
        order = (spdf_paint_id*)calloc((size_t)(n + 1), sizeof(spdf_paint_id));
        if (!order) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        for (i = 0; i < n; ++i) {
            pdf_obj* annot = pdf_array_get(ctx, annots, i);
            const char* nm = spdf_paint_pdf_nm(ctx, annot);
            spdf_paint_pdf_origin origin;
            const spdf_fill_item* item = NULL;
            spdf_rect bounds = {0, 0, 0, 0};
            spdf_paint_pdf_entry* e;
            spdf_paint_layer* layer = NULL;
            char *fp, *model;
            int cells = 0, num = pdf_to_num(ctx, annot);
            if (unmodelled(ctx, annot)) continue;
            if (spdf_paint_pdf_has_prefix(nm, SPDF_PAINT_NM_PREFIX) && pdf_dict_gets(ctx, annot, SPDF_PAINT_PDF_KEY))
                origin = SPDF_PAINT_PDF_OURS;
            else if (spdf_paint_pdf_has_prefix(nm, SPDF_FILL_NM_PREFIX)) {
                int k;
                origin = SPDF_PAINT_PDF_FILL;
                for (k = 0; k < items.count && !item; ++k)
                    if (strcmp(items.items[k].nm, nm) == 0) item = &items.items[k];
                if (!item) continue;
                nm = item->group;
                if (entry_by_identity(doc, nm, 0) && entry_by_identity(doc, nm, 0)->seen) continue; /* a later comb cell */
                item = fill_item(&items, nm, &bounds, &cells);
            } else if (num > 0) {
                origin = SPDF_PAINT_PDF_FOREIGN, nm = NULL;
            } else {
                continue;
            }
            e = entry_by_identity(doc, nm, origin == SPDF_PAINT_PDF_FOREIGN ? num : 0);
            fp = spdf_paint_pdf_annot_fingerprint(ctx, annot);
            if (cells > 1) { /* a comb entry changes when any cell does: count and box in its fingerprint */
                char extra[96], *joined;
                snprintf(extra, sizeof extra, "|%d|%.2f %.2f %.2f %.2f", cells, bounds.x0, bounds.y0, bounds.x1, bounds.y1);
                joined = (char*)malloc(strlen(fp) + strlen(extra) + 1);
                if (joined) strcpy(joined, fp), strcat(joined, extra), free(fp), fp = joined;
            }
            if (e) layer = spdf_paint_layer_find(doc, e->layer);
            if (e && layer && e->file && strcmp(e->file, fp) == 0) {
                free(fp);
                e->seen = 1;
                order[count++] = e->layer;
                continue;
            }
            changed = 1;
            if (origin == SPDF_PAINT_PDF_OURS) read_ours(doc, pdf, annot, &layer);
            else if (origin == SPDF_PAINT_PDF_FILL) read_fill(doc, item, bounds, &layer);
            else read_foreign(doc, annot, page_ctm, &layer);
            read_visibility(ctx, annot, layer);
            if (!e) spdf_paint_pdf_revive(doc, nm, origin == SPDF_PAINT_PDF_FOREIGN ? num : 0, layer);
            if (!e) e = spdf_paint_pdf_entry_add(doc, layer->id, origin, nm, origin == SPDF_PAINT_PDF_FOREIGN ? num : 0);
            model = spdf_paint_pdf_layer_state(doc, layer);
            spdf_paint_pdf_entry_set(doc, e, model, fp);
            e->seen = 1;
            if (origin == SPDF_PAINT_PDF_OURS) {
                unsigned rev = (unsigned)pdf_to_int(ctx, pdf_dict_gets(ctx, pdf_dict_gets(ctx, annot, SPDF_PAINT_PDF_KEY), "Rev"));
                if (rev > st->rev) st->rev = rev;
            }
            order[count++] = layer->id;
        }
        for (i = st->count - 1; i >= 0; --i) { /* gone from the file: gone from the canvas */
            spdf_paint_pdf_entry* e = &st->entries[i];
            int index;
            if (e->seen) continue;
            index = spdf_paint_layer_index(doc, e->layer);
            if (index > 0) spdf_paint_pdf_retire(doc, e), drop_layer(doc, index);
            if (doc->active == e->layer) doc->active = 0;
            spdf_paint_pdf_entry_remove(doc, e);
            changed = 1;
        }
        order_layers(doc, order, count);
    }
    fz_always(ctx) {
        free(order);
        spdf_free_fill_items(&items);
        pdf_drop_page(ctx, page);
    }
    fz_catch(ctx) fz_rethrow(ctx);
    if (changed) {
        spdf_paint_damage_all(doc);
        ++doc->generation;
    }
}

/* ---- Public ---- */

spdf_paint_doc* spdf_paint_open_pdf_page(spdf_document* pdf, int page_index, char* err, size_t err_len) {
    fz_context* ctx;
    spdf_paint_doc* volatile doc = NULL;
    pdf_page* volatile page = NULL;
    if (!pdf || !pdf_specifics(pdf->ctx, pdf->doc)) {
        spdf_paint_set_error(err, err_len, "Only PDF pages can be annotated.");
        return NULL;
    }
    if (page_index < 0 || page_index >= pdf->page_count) {
        spdf_paint_set_error(err, err_len, "There is no such page.");
        return NULL;
    }
    ctx = pdf->ctx;
    fz_try(ctx) {
        fz_rect bounds;
        spdf_paint_layer* background;
        char name[32];
        page = pdf_load_page(ctx, pdf_specifics(ctx, pdf->doc), page_index);
        bounds = pdf_bound_page(ctx, page, FZ_CROP_BOX);
        doc = spdf_paint_doc_new(ctx, 0, SPDF_PAINT_DOC_PDF, (int)ceilf(bounds.x1 - bounds.x0 - 0.01f),
                                 (int)ceilf(bounds.y1 - bounds.y0 - 0.01f));
        if (!doc) fz_throw(ctx, FZ_ERROR_SYSTEM, "Couldn't open the page for annotating.");
        doc->pdf = pdf, doc->page_index = page_index, doc->raster_scale = SPDF_PAINT_PDF_RASTER_SCALE, doc->dpi = 72;
        doc->page_width = bounds.x1 - bounds.x0, doc->page_height = bounds.y1 - bounds.y0;
        doc->page_rotation = ((pdf_to_int(ctx, pdf_dict_get_inheritable(ctx, page->obj, PDF_NAME(Rotate))) % 360) + 360) % 360;
        doc->pdf_state = (spdf_paint_pdf_state*)calloc(1, sizeof(spdf_paint_pdf_state));
        if (!doc->pdf_state) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        snprintf(name, sizeof name, "Page %d", page_index + 1);
        background = doc->layer_count > 0 ? doc->layers[0]
                                          : spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_BACKGROUND, name, 0);
        if (!background) fz_throw(ctx, FZ_ERROR_SYSTEM, "Couldn't open the page for annotating.");
        background->kind = SPDF_PAINT_LAYER_BACKGROUND, background->locked = 1, background->visible = 1;
        background->opacity = 1;
        fz_drop_pixmap(ctx, background->pixels), background->pixels = NULL;
        set_layer_name(background, name);
        if (doc->active == background->id) doc->active = 0;
        spdf_paint_pdf_read(doc, 0);
        spdf_paint_pdf_live_add(doc);
    }
    fz_always(ctx) pdf_drop_page(ctx, page);
    fz_catch(ctx) {
        spdf_paint_set_error(err, err_len, fz_caught_message(ctx));
        if (doc) spdf_paint_close(doc);
        return NULL;
    }
    return doc;
}

int spdf_paint_pdf_page_index(const spdf_paint_doc* doc) {
    return doc && doc->kind == SPDF_PAINT_DOC_PDF ? doc->page_index : -1;
}

spdf_paint_status spdf_paint_pdf_reload(spdf_paint_doc* doc, char* err, size_t err_len) {
    spdf_paint_pdf_state* st = spdf_paint_pdf_state_of(doc);
    if (!st || !doc->pdf) {
        spdf_paint_set_error(err, err_len, "This canvas is not a PDF page.");
        return SPDF_PAINT_ERR_FAILED;
    }
    if (st->writing) return SPDF_PAINT_OK;
    fz_drop_display_list(doc->ctx, st->page_list);
    st->page_list = NULL; /* form values may have changed: the page is drawn again */
    fz_try(doc->ctx) spdf_paint_pdf_read(doc, 1);
    fz_catch(doc->ctx) {
        spdf_paint_set_error(err, err_len, fz_caught_message(doc->ctx));
        return SPDF_PAINT_ERR_FAILED;
    }
    return SPDF_PAINT_OK;
}

int spdf_paint_pdf_page_has_items(spdf_document* pdf, int page_index, char* err, size_t err_len) {
    pdf_document* doc = pdf ? pdf_specifics(pdf->ctx, pdf->doc) : NULL;
    int found = 0;
    if (!doc) return 0;
    fz_try(pdf->ctx) {
        pdf_obj* annots = pdf_dict_get(pdf->ctx, pdf_lookup_page_obj(pdf->ctx, doc, page_index), PDF_NAME(Annots));
        int i;
        for (i = 0; i < pdf_array_len(pdf->ctx, annots) && !found; ++i)
            found = spdf_paint_pdf_has_prefix(spdf_paint_pdf_nm(pdf->ctx, pdf_array_get(pdf->ctx, annots, i)),
                                              SPDF_PAINT_NM_PREFIX);
    }
    fz_catch(pdf->ctx) {
        spdf_paint_set_error(err, err_len, fz_caught_message(pdf->ctx));
        return -1;
    }
    return found;
}

void spdf_paint_pdf_note_change(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    SPDF_PAINT_UNUSED(doc); /* write_back compares every layer with what was written: nothing to remember here */
    if (layer) layer->pdf_dirty = 1;
}

void spdf_paint_pdf_note_order(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }
