/* Annotate's canvas model (docs/plans/annotate.md § 8 Core, spdf_paint_doc.c): the canvas, layers, objects, ids,
 * z-order, the selection's bookkeeping, colours and damage. The composite lives in spdf_paint_composite.c, the
 * Selection handlers in spdf_paint_select.c, Layers and Colours in spdf_paint_layers.c, Objects in
 * spdf_paint_objects.c. */
#include "spdf_paint_model.h"

#include "spdf_fill_ink_geometry.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SPDF_PAINT_STORE_BYTES ((size_t)64 << 20)

void spdf_paint_set_error(char* err, size_t err_len, const char* message) {
    if (err && err_len) snprintf(err, err_len, "%s", message ? message : "");
}

static int size_ok(int width, int height, char* err, size_t err_len) {
    if (width < 1 || height < 1 || width > SPDF_PAINT_MAX_SIDE || height > SPDF_PAINT_MAX_SIDE ||
        (uint64_t)width * (uint64_t)height > SPDF_PAINT_MAX_PIXELS) {
        spdf_paint_set_error(err, err_len, "A canvas can be from 1 x 1 to 16384 x 16384 pixels, 268 million at most.");
        return 0;
    }
    return 1;
}

fz_pixmap* spdf_paint_pixmap_new(fz_context* ctx, int w, int h) {
    fz_pixmap* pix = NULL;
    fz_try(ctx) {
        pix = fz_new_pixmap(ctx, fz_device_rgb(ctx), w > 0 ? w : 1, h > 0 ? h : 1, NULL, 1);
        fz_clear_pixmap(ctx, pix);
    }
    fz_catch(ctx) { fz_ignore_error(ctx); pix = NULL; }
    return pix;
}

void spdf_paint_color_bytes(spdf_paint_color color, unsigned char out[4]) {
    unsigned a = color & 0xFF;
    out[0] = (unsigned char)(((color >> 24) & 0xFF) * a / 255);
    out[1] = (unsigned char)(((color >> 16) & 0xFF) * a / 255);
    out[2] = (unsigned char)(((color >> 8) & 0xFF) * a / 255);
    out[3] = (unsigned char)a;
}

static void fill_pixmap(fz_pixmap* pix, spdf_paint_color color) {
    unsigned char c[4];
    spdf_paint_color_bytes(color, c);
    for (int y = 0; y < pix->h; y++) {
        unsigned char* p = pix->samples + y * pix->stride;
        for (int x = 0; x < pix->w; x++, p += 4) memcpy(p, c, 4);
    }
}

/* ---- Lifecycle ---- */

spdf_paint_doc* spdf_paint_doc_new(fz_context* ctx, int owns_ctx, spdf_paint_doc_kind kind, int width, int height) {
    if (!ctx) return NULL;
    spdf_paint_doc* doc = calloc(1, sizeof(*doc));
    if (!doc) return NULL;
    doc->ctx = ctx;
    doc->owns_ctx = owns_ctx;
    doc->kind = kind;
    doc->raster_scale = kind == SPDF_PAINT_DOC_PDF ? SPDF_PAINT_PDF_RASTER_SCALE : 1;
    doc->dpi = 72.0f;
    doc->has_alpha = 1;
    doc->color1 = 0x000000FFu;
    doc->color2 = 0xFFFFFFFFu;
    doc->next_id = 1;
    doc->page_index = -1;
    doc->history.limit = SPDF_PAINT_HISTORY_CAP;
    spdf_paint_set_size(doc, width, height);
    return doc;
}

static spdf_paint_doc* new_raster_doc(spdf_paint_doc_kind kind, int width, int height, char* err, size_t err_len) {
    if (!size_ok(width, height, err, err_len)) return NULL;
    fz_context* ctx = fz_new_context(NULL, NULL, SPDF_PAINT_STORE_BYTES);
    spdf_paint_doc* doc = ctx ? spdf_paint_doc_new(ctx, 1, kind, width, height) : NULL;
    spdf_paint_layer* bg = doc ? spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_BACKGROUND, "Background", 0) : NULL;
    if (bg) bg->pixels = spdf_paint_pixmap_new(ctx, width, height);
    if (!bg || !bg->pixels) {
        if (doc) spdf_paint_close(doc);
        else if (ctx) fz_drop_context(ctx);
        spdf_paint_set_error(err, err_len, "There is not enough memory for a canvas this size.");
        return NULL;
    }
    doc->active = bg->id;
    return doc;
}

spdf_paint_doc* spdf_paint_new_canvas(int width, int height, spdf_paint_color background, char* err, size_t err_len) {
    spdf_paint_doc* doc = new_raster_doc(SPDF_PAINT_DOC_CANVAS, width, height, err, err_len);
    if (doc && background) fill_pixmap(doc->layers[0]->pixels, background);
    return doc;
}

spdf_paint_doc* spdf_paint_open_picture(const spdf_paint_pixels* pixels, float dpi, int has_alpha, char* err,
                                        size_t err_len) {
    if (!pixels || !pixels->rgba || pixels->stride < pixels->width * 4) {
        spdf_paint_set_error(err, err_len, "The picture has no pixels.");
        return NULL;
    }
    spdf_paint_doc* doc = new_raster_doc(SPDF_PAINT_DOC_PICTURE, pixels->width, pixels->height, err, err_len);
    if (!doc) return NULL;
    fz_pixmap* pix = doc->layers[0]->pixels;
    for (int y = 0; y < pixels->height; y++) {
        const unsigned char* s = pixels->rgba + (size_t)y * pixels->stride;
        unsigned char* d = pix->samples + y * pix->stride;
        if (!pixels->straight) { memcpy(d, s, (size_t)pixels->width * 4); continue; }
        for (int x = 0; x < pixels->width; x++, s += 4, d += 4) {
            d[0] = (unsigned char)(s[0] * s[3] / 255);
            d[1] = (unsigned char)(s[1] * s[3] / 255);
            d[2] = (unsigned char)(s[2] * s[3] / 255);
            d[3] = s[3];
        }
    }
    doc->dpi = dpi > 0 ? dpi : 72.0f;
    doc->has_alpha = has_alpha ? 1 : 0;
    return doc;
}

void spdf_paint_close(spdf_paint_doc* doc) {
    if (!doc) return;
    fz_context* ctx = doc->ctx;
    spdf_paint_history_free(doc);
    for (int i = 0; i < doc->layer_count; i++) spdf_paint_layer_free(ctx, doc->layers[i]);
    free(doc->layers);
    spdf_paint_selection_free(ctx, &doc->selection);
    spdf_paint_tiles_free(doc);
    int owns = doc->owns_ctx;
    free(doc);
    if (owns) fz_drop_context(ctx);
}

spdf_paint_doc_kind spdf_paint_kind(const spdf_paint_doc* doc) { return doc ? doc->kind : SPDF_PAINT_DOC_CANVAS; }

void spdf_paint_size(const spdf_paint_doc* doc, int* width, int* height) {
    if (width) *width = doc ? doc->width : 0;
    if (height) *height = doc ? doc->height : 0;
}

float spdf_paint_dpi(const spdf_paint_doc* doc) { return doc ? doc->dpi : 72.0f; }

uint64_t spdf_paint_generation(const spdf_paint_doc* doc) { return doc ? doc->generation : 0; }

int spdf_paint_take_damage(spdf_paint_doc* doc, spdf_rect* changed) {
    if (!doc || !doc->has_damage) return 0;
    if (changed) *changed = doc->damage;
    doc->has_damage = 0;
    return 1;
}

spdf_paint_id spdf_paint_object_at(spdf_paint_doc* doc, float x, float y, float slop) {
    return doc ? spdf_paint_hit_object(doc, x, y, slop) : 0;
}

/* ---- Size, tiles, damage ---- */

void spdf_paint_tiles_free(spdf_paint_doc* doc) {
    spdf_paint_tile_cache* cache = &doc->tiles;
    for (int i = 0; i < cache->tiles_x * cache->tiles_y; i++)
        if (cache->tiles[i].composite) fz_drop_pixmap(doc->ctx, cache->tiles[i].composite);
    free(cache->tiles);
    memset(cache, 0, sizeof(*cache));
}

void spdf_paint_set_size(spdf_paint_doc* doc, int width, int height) {
    spdf_paint_tiles_free(doc);
    doc->width = width;
    doc->height = height;
    int rs = doc->raster_scale > 0 ? doc->raster_scale : 1;
    int tx = (width * rs + SPDF_PAINT_TILE_SIZE - 1) / SPDF_PAINT_TILE_SIZE;
    int ty = (height * rs + SPDF_PAINT_TILE_SIZE - 1) / SPDF_PAINT_TILE_SIZE;
    if (tx > 0 && ty > 0 && (doc->kind & SPDF_PAINT_DOC_RASTER)) {
        doc->tiles.tiles = calloc((size_t)tx * ty, sizeof(spdf_paint_tile));
        if (doc->tiles.tiles) { doc->tiles.tiles_x = tx; doc->tiles.tiles_y = ty; }
    }
    spdf_paint_damage_all(doc);
}

spdf_rect spdf_paint_canvas_rect(const spdf_paint_doc* doc) {
    spdf_rect r = {0, 0, (float)doc->width, (float)doc->height};
    return r;
}

fz_irect spdf_paint_raster_box(const spdf_paint_doc* doc, spdf_rect rect) {
    int rs = doc->raster_scale, w = doc->width * rs, h = doc->height * rs;
    fz_irect box;
    box.x0 = (int)floorf(rect.x0 * rs);
    box.y0 = (int)floorf(rect.y0 * rs);
    box.x1 = (int)ceilf(rect.x1 * rs);
    box.y1 = (int)ceilf(rect.y1 * rs);
    if (box.x0 < 0) box.x0 = 0;
    if (box.y0 < 0) box.y0 = 0;
    if (box.x1 > w) box.x1 = w;
    if (box.y1 > h) box.y1 = h;
    if (box.x1 < box.x0) box.x1 = box.x0;
    if (box.y1 < box.y0) box.y1 = box.y0;
    return box;
}

void spdf_paint_damage(spdf_paint_doc* doc, spdf_rect rect) {
    if (!doc) return;
    doc->generation++;
    if (rect.x1 <= rect.x0 || rect.y1 <= rect.y0) return;
    if (!doc->has_damage) doc->damage = rect;
    else {
        doc->damage.x0 = fminf(doc->damage.x0, rect.x0);
        doc->damage.y0 = fminf(doc->damage.y0, rect.y0);
        doc->damage.x1 = fmaxf(doc->damage.x1, rect.x1);
        doc->damage.y1 = fmaxf(doc->damage.y1, rect.y1);
    }
    doc->has_damage = 1;
    spdf_paint_tile_cache* cache = &doc->tiles;
    if (!cache->tiles) return;
    fz_irect box = spdf_paint_raster_box(doc, rect);
    for (int ty = box.y0 / SPDF_PAINT_TILE_SIZE; ty < cache->tiles_y && ty * SPDF_PAINT_TILE_SIZE < box.y1; ty++)
        for (int tx = box.x0 / SPDF_PAINT_TILE_SIZE; tx < cache->tiles_x && tx * SPDF_PAINT_TILE_SIZE < box.x1; tx++)
            cache->tiles[ty * cache->tiles_x + tx].valid = 0;
}

void spdf_paint_damage_all(spdf_paint_doc* doc) { spdf_paint_damage(doc, spdf_paint_canvas_rect(doc)); }

void spdf_paint_changed(spdf_paint_doc* doc, spdf_paint_layer* layer, spdf_rect rect) {
    if (layer && layer->kind == SPDF_PAINT_LAYER_OBJECT && layer->object && rect.x1 <= rect.x0) {
        spdf_paint_object_update_bounds(layer->object);
        rect = layer->object->bounds;
    }
    if (!layer || rect.x1 <= rect.x0) rect = spdf_paint_canvas_rect(doc);
    spdf_paint_damage(doc, rect);
}

/* ---- Colours ---- */

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int spdf_paint_parse_color(const char* text, spdf_paint_color* out) {
    if (!text) return 0;
    if (!strcmp(text, "transparent")) { if (out) *out = 0; return 1; }
    size_t len = strlen(text);
    if (text[0] != '#' || (len != 7 && len != 9)) return 0;
    spdf_paint_color value = 0;
    for (size_t i = 1; i < len; i++) {
        int d = hex_digit(text[i]);
        if (d < 0) return 0;
        value = (value << 4) | (spdf_paint_color)d;
    }
    if (len == 7) value = (value << 8) | 0xFF;
    if (out) *out = value;
    return 1;
}

void spdf_paint_format_color(spdf_paint_color color, char out[10]) {
    if ((color & 0xFF) == 0xFF) snprintf(out, 10, "#%06X", (unsigned)(color >> 8));
    else snprintf(out, 10, "#%08X", (unsigned)color);
}

/* ---- Layers ---- */

const char* spdf_paint_layer_kind_name(spdf_paint_layer_kind kind) {
    switch (kind) {
    case SPDF_PAINT_LAYER_BACKGROUND: return "background";
    case SPDF_PAINT_LAYER_RASTER: return "raster";
    case SPDF_PAINT_LAYER_OBJECT: return "object";
    }
    return "raster";
}

int spdf_paint_layer_index(const spdf_paint_doc* doc, spdf_paint_id id) {
    if (!doc || !id) return -1;
    for (int i = 0; i < doc->layer_count; i++)
        if (doc->layers[i]->id == id) return i;
    return -1;
}

spdf_paint_layer* spdf_paint_layer_find(spdf_paint_doc* doc, spdf_paint_id id) {
    int i = spdf_paint_layer_index(doc, id);
    return i < 0 ? NULL : doc->layers[i];
}

int spdf_paint_layer_is_page(const spdf_paint_doc* doc, const spdf_paint_layer* layer) {
    return layer && layer->kind == SPDF_PAINT_LAYER_BACKGROUND && doc->kind == SPDF_PAINT_DOC_PDF;
}

int spdf_paint_layer_paintable(const spdf_paint_doc* doc, const spdf_paint_layer* layer) {
    if (!layer || layer->locked) return 0;
    return layer->kind == SPDF_PAINT_LAYER_RASTER ||
           (layer->kind == SPDF_PAINT_LAYER_BACKGROUND && doc->kind != SPDF_PAINT_DOC_PDF);
}

int spdf_paint_paintable_below(const spdf_paint_doc* doc, int index) {
    for (int i = index - 1; i >= 0; i--)
        if (spdf_paint_layer_paintable(doc, doc->layers[i])) return i;
    return -1;
}

fz_pixmap* spdf_paint_layer_pixels(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    if (!spdf_paint_layer_paintable(doc, layer)) return NULL;
    if (!layer->pixels)
        layer->pixels = spdf_paint_pixmap_new(doc->ctx, doc->width * doc->raster_scale,
                                              doc->height * doc->raster_scale);
    return layer->pixels;
}

void spdf_paint_layer_insert(spdf_paint_doc* doc, spdf_paint_layer* layer, int index) {
    if (doc->layer_count == doc->layer_cap) {
        int cap = doc->layer_cap ? doc->layer_cap * 2 : 8;
        spdf_paint_layer** grown = realloc(doc->layers, (size_t)cap * sizeof(*grown));
        if (!grown) return;
        doc->layers = grown;
        doc->layer_cap = cap;
    }
    if (index < 0 || index > doc->layer_count) index = doc->layer_count;
    memmove(doc->layers + index + 1, doc->layers + index, (size_t)(doc->layer_count - index) * sizeof(*doc->layers));
    doc->layers[index] = layer;
    doc->layer_count++;
}

spdf_paint_layer* spdf_paint_layer_detach(spdf_paint_doc* doc, spdf_paint_id id) {
    int i = spdf_paint_layer_index(doc, id);
    if (i < 0) return NULL;
    spdf_paint_layer* layer = doc->layers[i];
    memmove(doc->layers + i, doc->layers + i + 1, (size_t)(doc->layer_count - i - 1) * sizeof(*doc->layers));
    doc->layer_count--;
    return layer;
}

static void default_layer_name(const spdf_paint_doc* doc, char* out, size_t cap) {
    for (int n = 2;; n++) {
        snprintf(out, cap, "Layer %d", n);
        int used = 0;
        for (int i = 0; i < doc->layer_count && !used; i++) used = !strcmp(doc->layers[i]->name, out);
        if (!used) return;
    }
}

spdf_paint_layer* spdf_paint_layer_new(spdf_paint_doc* doc, spdf_paint_layer_kind kind, const char* name,
                                       spdf_paint_id above) {
    if (!doc) return NULL;
    spdf_paint_layer* layer = calloc(1, sizeof(*layer));
    if (!layer) return NULL;
    layer->id = doc->next_id++;
    layer->kind = kind;
    layer->visible = 1;
    layer->opacity = 1.0f;
    if (name) snprintf(layer->name, sizeof(layer->name), "%s", name);
    else if (kind == SPDF_PAINT_LAYER_RASTER) default_layer_name(doc, layer->name, sizeof(layer->name));
    int index = doc->layer_count;
    if (kind == SPDF_PAINT_LAYER_BACKGROUND) index = 0;
    else if (above) {
        int at = spdf_paint_layer_index(doc, above);
        if (at >= 0) index = at + 1;
    }
    if (index == 0 && kind != SPDF_PAINT_LAYER_BACKGROUND && doc->layer_count) index = 1;
    int before = doc->layer_count;
    spdf_paint_layer_insert(doc, layer, index);
    if (doc->layer_count == before) { free(layer); return NULL; }
    spdf_paint_history_added_layer(doc, layer);
    return layer;
}

fz_pixmap* spdf_paint_active_pixels(spdf_paint_doc* doc, spdf_paint_layer** layer_out) {
    spdf_paint_layer* layer = spdf_paint_layer_find(doc, doc->active);
    if (!spdf_paint_layer_paintable(doc, layer)) {
        layer = NULL;
        for (int i = doc->layer_count - 1; i >= 0 && !layer; i--)
            if (spdf_paint_layer_paintable(doc, doc->layers[i])) layer = doc->layers[i];
        if (!layer && doc->kind == SPDF_PAINT_DOC_PDF)
            layer = spdf_paint_layer_new(doc, SPDF_PAINT_LAYER_RASTER, "Drawing", 0);
        if (layer) doc->active = layer->id;
    }
    if (layer_out) *layer_out = layer;
    return layer ? spdf_paint_layer_pixels(doc, layer) : NULL;
}

spdf_paint_layer* spdf_paint_layer_clone(fz_context* ctx, const spdf_paint_layer* layer, int with_pixels) {
    spdf_paint_layer* copy = calloc(1, sizeof(*copy));
    if (!copy) return NULL;
    *copy = *layer;
    copy->pixels = NULL;
    copy->object = NULL;
    copy->pdf_nm = NULL;
    fz_try(ctx) {
        if (with_pixels && layer->pixels) copy->pixels = fz_clone_pixmap(ctx, layer->pixels);
        if (layer->pdf_nm) copy->pdf_nm = fz_strdup(ctx, layer->pdf_nm);
    }
    fz_catch(ctx) fz_ignore_error(ctx);
    if (layer->object) copy->object = spdf_paint_object_clone(ctx, layer->object);
    return copy;
}

void spdf_paint_layer_free(fz_context* ctx, spdf_paint_layer* layer) {
    if (!layer) return;
    fz_drop_pixmap(ctx, layer->pixels);
    spdf_paint_object_free(ctx, layer->object);
    fz_free(ctx, layer->pdf_nm);
    free(layer);
}

void spdf_paint_layer_delete(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    int index = spdf_paint_layer_index(doc, layer->id);
    if (index < 0) return;
    spdf_paint_history_removing_layer(doc, layer);
    spdf_rect damage = spdf_paint_canvas_rect(doc);
    if (layer->object) { spdf_paint_object_update_bounds(layer->object); damage = layer->object->bounds; }
    spdf_paint_layer_detach(doc, layer->id);
    if (doc->active == layer->id) {
        int below = spdf_paint_paintable_below(doc, index);
        doc->active = below >= 0 ? doc->layers[below]->id : 0;
        for (int i = index; !doc->active && i < doc->layer_count; i++)
            if (spdf_paint_layer_paintable(doc, doc->layers[i])) doc->active = doc->layers[i]->id;
    }
    spdf_paint_layer_free(doc->ctx, layer);
    spdf_paint_selection_prune(doc);
    spdf_paint_damage(doc, damage);
}
