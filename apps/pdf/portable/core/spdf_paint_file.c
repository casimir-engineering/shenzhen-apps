/* Annotate's files (docs/plans/annotate.md § 5, § 8 Core spdf_paint_file.c): .szpaint projects (a ZIP written with
 * MuPDF's fz_zip_writer: manifest.json plus one PNG per raster layer and Picture object; shapes and text stored as
 * their parameters and drawn again on load), the flattened picture the frontend encodes into the file, PNGs for
 * doc.render, and the doc.render handler.
 *
 * manifest.json, version 2: {"format":"shenzhen-paint","version":2,"kind":"picture"|"canvas","width","height","dpi",
 * "transparent","color1","color2","custom":[10 colours or null],"active":id,"layers":[bottom to top: {"id","kind":
 * "background"|"layer","name","visible","opacity" (percent),"locked","png":"layers/<id>.png" when it has pixels,
 * "objects":[back to front: {"id","kind":"object","name" (empty: named after its object),"visible","opacity",
 * "png" (a picture's pixels),"object":{"type", and its settings as object.update names them}}]}]}.
 * Version 1 (before layers held objects) listed every object as a layer of its own, "raster" for layers; it reads
 * with each object on the layer below it, and objects right above the Background on a new "Layer 1". */
#include "spdf_paint_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SPDF_PAINT_STORE_BYTES ((size_t)64 << 20)

spdf_paint_status spdf_paint_flatten(spdf_paint_doc* doc, spdf_paint_color matte, spdf_bitmap* out, char* err,
                                     size_t err_len) {
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    options.scale = 1.0f;
    options.matte = matte;
    return spdf_paint_render(doc, &options, out, err, err_len);
}

static fz_pixmap* bitmap_pixmap(fz_context* ctx, spdf_bitmap* bitmap) {
    fz_pixmap* pix = NULL;
    fz_try(ctx) pix = fz_new_pixmap_with_data(ctx, fz_device_rgb(ctx), bitmap->width, bitmap->height, NULL, 1,
                                              bitmap->stride, bitmap->rgba);
    fz_catch(ctx) { fz_ignore_error(ctx); pix = NULL; }
    return pix;
}

spdf_paint_status spdf_paint_render_png(spdf_paint_doc* doc, const spdf_paint_render_options* options,
                                        const char* path, char* err, size_t err_len) {
    spdf_bitmap bitmap;
    spdf_paint_status status = spdf_paint_render(doc, options, &bitmap, err, err_len);
    if (status != SPDF_PAINT_OK) return status;
    fz_context* ctx = doc->ctx;
    fz_pixmap* pix = bitmap_pixmap(ctx, &bitmap);
    status = SPDF_PAINT_ERR_IO;
    fz_try(ctx) {
        if (pix) { fz_save_pixmap_as_png(ctx, pix, path); status = SPDF_PAINT_OK; }
    }
    fz_always(ctx) fz_drop_pixmap(ctx, pix);
    fz_catch(ctx) fz_ignore_error(ctx);
    spdf_free_bitmap(&bitmap);
    if (status != SPDF_PAINT_OK) spdf_paint_set_error(err, err_len, "The picture could not be written there.");
    return status;
}

/* ---- Writing a project ---- */

static void add_png(fz_context* ctx, fz_zip_writer* zip, const char* name, fz_pixmap* pix) {
    fz_buffer* png = fz_new_buffer_from_pixmap_as_png(ctx, pix, fz_default_color_params);
    fz_try(ctx) fz_write_zip_entry(ctx, zip, name, png, 0);
    fz_always(ctx) fz_drop_buffer(ctx, png);
    fz_catch(ctx) fz_rethrow(ctx);
}

static cJSON* manifest(spdf_paint_doc* doc) {
    cJSON* m = cJSON_CreateObject();
    cJSON_AddStringToObject(m, "format", "shenzhen-paint");
    cJSON_AddNumberToObject(m, "version", SPDF_PAINT_FILE_VERSION);
    cJSON_AddStringToObject(m, "kind", doc->kind == SPDF_PAINT_DOC_PICTURE ? "picture" : "canvas");
    cJSON_AddNumberToObject(m, "width", doc->width);
    cJSON_AddNumberToObject(m, "height", doc->height);
    cJSON_AddNumberToObject(m, "dpi", doc->dpi);
    cJSON_AddBoolToObject(m, "transparent", doc->has_alpha);
    cJSON_AddItemToObject(m, "color1", spdf_paint_color_json(doc->color1));
    cJSON_AddItemToObject(m, "color2", spdf_paint_color_json(doc->color2));
    cJSON* custom = cJSON_AddArrayToObject(m, "custom");
    for (int i = 0; i < SPDF_PAINT_CUSTOM_COLORS; i++)
        cJSON_AddItemToArray(custom, doc->custom[i] ? spdf_paint_color_json(doc->custom[i]) : cJSON_CreateNull());
    cJSON_AddNumberToObject(m, "active", doc->active);
    cJSON* layers = cJSON_AddArrayToObject(m, "layers");
    cJSON* objects = NULL;
    for (int i = 0; i < doc->layer_count; i++) {
        const spdf_paint_layer* layer = doc->layers[i];
        cJSON* l = cJSON_CreateObject();
        cJSON_AddNumberToObject(l, "id", layer->id);
        cJSON_AddStringToObject(l, "kind", spdf_paint_layer_kind_name(layer->kind));
        cJSON_AddStringToObject(l, "name", layer->name);
        cJSON_AddBoolToObject(l, "visible", layer->visible);
        cJSON_AddNumberToObject(l, "opacity", layer->opacity * 100.0);
        if (layer->locked) cJSON_AddTrueToObject(l, "locked");
        int has_png = layer->pixels || (layer->object && layer->object->kind == SPDF_PAINT_OBJ_PICTURE &&
                                         layer->object->u.picture.pixels);
        if (has_png) {
            char name[64];
            snprintf(name, sizeof(name), "layers/%u.png", (unsigned)layer->id);
            cJSON_AddStringToObject(l, "png", name);
        }
        if (layer->object) cJSON_AddItemToObject(l, "object", spdf_paint_object_json(doc, layer->object, 1));
        if (!layer->object) {
            cJSON_AddItemToArray(layers, l);
            objects = layer->kind == SPDF_PAINT_LAYER_RASTER ? cJSON_AddArrayToObject(l, "objects") : NULL;
        } else cJSON_AddItemToArray(objects ? objects : layers, l);
    }
    return m;
}

spdf_paint_status spdf_paint_project_bytes(spdf_paint_doc* doc, unsigned char** out, size_t* out_len, char* err,
                                           size_t err_len) {
    *out = NULL;
    *out_len = 0;
    if (!doc || doc->kind == SPDF_PAINT_DOC_PDF) {
        spdf_paint_set_error(err, err_len, "A PDF page keeps its annotations in the PDF itself.");
        return SPDF_PAINT_ERR_INVALID_ARGUMENT;
    }
    fz_context* ctx = doc->ctx;
    fz_buffer* buf = NULL;
    fz_buffer* json_buf = NULL;
    fz_zip_writer* zip = NULL;
    char* json = NULL;
    spdf_paint_status status = SPDF_PAINT_ERR_IO;
    fz_var(buf);
    fz_var(json_buf);
    fz_var(zip);
    fz_var(json);
    fz_try(ctx) {
        buf = fz_new_buffer(ctx, 1 << 16);
        zip = fz_new_zip_writer_with_output(ctx, fz_new_output_with_buffer(ctx, buf));
        cJSON* m = manifest(doc);
        json = cJSON_Print(m);
        cJSON_Delete(m);
        if (!json) fz_throw(ctx, FZ_ERROR_SYSTEM, "manifest");
        json_buf = fz_new_buffer_from_copied_data(ctx, (const unsigned char*)json, strlen(json));
        fz_write_zip_entry(ctx, zip, "manifest.json", json_buf, 1);
        for (int i = 0; i < doc->layer_count; i++) {
            spdf_paint_layer* layer = doc->layers[i];
            fz_pixmap* pix = layer->pixels;
            if (!pix && layer->object && layer->object->kind == SPDF_PAINT_OBJ_PICTURE) pix = layer->object->u.picture.pixels;
            if (!pix) continue;
            char name[64];
            snprintf(name, sizeof(name), "layers/%u.png", (unsigned)layer->id);
            add_png(ctx, zip, name, pix);
        }
        fz_close_zip_writer(ctx, zip);
        unsigned char* data = NULL;
        size_t len = fz_buffer_storage(ctx, buf, &data);
        *out = malloc(len ? len : 1);
        if (!*out) fz_throw(ctx, FZ_ERROR_SYSTEM, "memory");
        memcpy(*out, data, len);
        *out_len = len;
        status = SPDF_PAINT_OK;
    }
    fz_always(ctx) {
        fz_drop_zip_writer(ctx, zip);
        fz_drop_buffer(ctx, json_buf);
        fz_drop_buffer(ctx, buf);
        cJSON_free(json);
    }
    fz_catch(ctx) { fz_ignore_error(ctx); spdf_paint_set_error(err, err_len, "The project could not be written."); }
    return status;
}

spdf_paint_status spdf_paint_write_project(spdf_paint_doc* doc, const char* path, char* err, size_t err_len) {
    unsigned char* bytes = NULL;
    size_t len = 0;
    spdf_paint_status status = spdf_paint_project_bytes(doc, &bytes, &len, err, err_len);
    if (status != SPDF_PAINT_OK) return status;
    char temp[4096];
    snprintf(temp, sizeof(temp), "%s.szpaint-writing", path);
    FILE* f = fopen(temp, "wb");
    int ok = f && fwrite(bytes, 1, len, f) == len;
    if (f && fclose(f) != 0) ok = 0;
    free(bytes);
    if (!ok || rename(temp, path) != 0) {
        remove(temp);
        spdf_paint_set_error(err, err_len, "The project could not be saved there.");
        return SPDF_PAINT_ERR_IO;
    }
    return SPDF_PAINT_OK;
}

/* ---- Reading a project ---- */

static fz_pixmap* read_png(fz_context* ctx, fz_archive* zip, const char* name) {
    fz_buffer* buf = NULL;
    fz_pixmap* pix = NULL;
    fz_try(ctx) buf = fz_read_archive_entry(ctx, zip, name);
    fz_catch(ctx) { fz_ignore_error(ctx); return NULL; }
    pix = spdf_paint_decode_picture(ctx, buf);
    fz_drop_buffer(ctx, buf);
    return pix;
}

static spdf_paint_layer_kind layer_kind(const char* name) { /* "layer", and version 1's "raster" */
    if (name && !strcmp(name, "background")) return SPDF_PAINT_LAYER_BACKGROUND;
    if (name && !strcmp(name, "object")) return SPDF_PAINT_LAYER_OBJECT;
    return SPDF_PAINT_LAYER_RASTER;
}

static spdf_paint_object* read_object(spdf_paint_doc* doc, const cJSON* json) {
    const char* type = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(json, "type"));
    for (int k = SPDF_PAINT_OBJ_SHAPE; type && k <= SPDF_PAINT_OBJ_FOREIGN; k++) {
        if (strcmp(type, spdf_paint_object_kind_name((spdf_paint_object_kind)k))) continue;
        spdf_paint_object* o = calloc(1, sizeof(*o));
        if (!o) return NULL;
        o->kind = (spdf_paint_object_kind)k;
        if (k == SPDF_PAINT_OBJ_TEXT) o->u.text.size = 24;
        char msg[256];
        spdf_paint_object_apply_json(doc, o, json, msg, sizeof(msg));
        return o;
    }
    return NULL;
}

static int read_layer(spdf_paint_doc* doc, fz_archive* zip, const cJSON* l) {
    spdf_paint_layer* layer = calloc(1, sizeof(*layer));
    if (!layer) return 0;
    layer->id = (spdf_paint_id)cJSON_GetNumberValue(cJSON_GetObjectItemCaseSensitive(l, "id"));
    layer->kind = layer_kind(cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(l, "kind")));
    const char* name = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(l, "name"));
    snprintf(layer->name, sizeof(layer->name), "%s", name ? name : "");
    const cJSON* visible = cJSON_GetObjectItemCaseSensitive(l, "visible");
    const cJSON* opacity = cJSON_GetObjectItemCaseSensitive(l, "opacity");
    layer->visible = visible ? cJSON_IsTrue(visible) : 1;
    layer->opacity = cJSON_IsNumber(opacity) ? (float)(opacity->valuedouble / 100.0) : 1.0f;
    layer->locked = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(l, "locked"));
    const char* png = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(l, "png"));
    fz_pixmap* pix = png ? read_png(doc->ctx, zip, png) : NULL;
    if (layer->kind == SPDF_PAINT_LAYER_OBJECT) {
        layer->object = read_object(doc, cJSON_GetObjectItemCaseSensitive(l, "object"));
        if (!layer->object) { fz_drop_pixmap(doc->ctx, pix); free(layer); return 1; } /* an unknown kind: skipped */
        if (layer->object->kind == SPDF_PAINT_OBJ_PICTURE) layer->object->u.picture.pixels = pix;
        else fz_drop_pixmap(doc->ctx, pix);
        spdf_paint_object_update_bounds(layer->object);
    } else if (pix && (pix->w != doc->width || pix->h != doc->height)) {
        layer->pixels = spdf_paint_place_pixmap(doc->ctx, pix, doc->width, doc->height, 0, 0, NULL);
        fz_drop_pixmap(doc->ctx, pix);
    } else layer->pixels = pix;
    if (!layer->id || spdf_paint_layer_find(doc, layer->id)) layer->id = doc->next_id;
    if (layer->id >= doc->next_id) doc->next_id = layer->id + 1;
    if (layer->kind == SPDF_PAINT_LAYER_BACKGROUND && doc->layer_count) layer->kind = SPDF_PAINT_LAYER_RASTER;
    spdf_paint_layer_insert(doc, layer, doc->layer_count);
    return 1;
}

spdf_paint_doc* spdf_paint_read_project(const char* path, char* err, size_t err_len) {
    fz_context* ctx = fz_new_context(NULL, NULL, SPDF_PAINT_STORE_BYTES);
    if (!ctx) { spdf_paint_set_error(err, err_len, "There is not enough memory."); return NULL; }
    fz_archive* zip = NULL;
    fz_buffer* buf = NULL;
    fz_var(zip);
    fz_var(buf);
    fz_try(ctx) {
        zip = fz_open_zip_archive(ctx, path);
        buf = fz_read_archive_entry(ctx, zip, "manifest.json");
        fz_terminate_buffer(ctx, buf);
    }
    fz_catch(ctx) { fz_ignore_error(ctx);
        fz_drop_buffer(ctx, buf);
        fz_drop_archive(ctx, zip);
        fz_drop_context(ctx);
        spdf_paint_set_error(err, err_len, "This isn't a Shenzhen Paint project, or it can't be read.");
        return NULL;
    }
    unsigned char* data = NULL;
    fz_buffer_storage(ctx, buf, &data);
    cJSON* m = cJSON_Parse((const char*)data);
    fz_drop_buffer(ctx, buf);
    int version = (int)cJSON_GetNumberValue(cJSON_GetObjectItemCaseSensitive(m, "version"));
    int w = (int)cJSON_GetNumberValue(cJSON_GetObjectItemCaseSensitive(m, "width"));
    int h = (int)cJSON_GetNumberValue(cJSON_GetObjectItemCaseSensitive(m, "height"));
    const char* kind = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(m, "kind"));
    spdf_paint_doc* doc = NULL;
    if (m && version >= 1 && version <= SPDF_PAINT_FILE_VERSION && w >= 1 && h >= 1 && w <= SPDF_PAINT_MAX_SIDE &&
        h <= SPDF_PAINT_MAX_SIDE && (uint64_t)w * h <= SPDF_PAINT_MAX_PIXELS)
        doc = spdf_paint_doc_new(ctx, 1, kind && !strcmp(kind, "picture") ? SPDF_PAINT_DOC_PICTURE : SPDF_PAINT_DOC_CANVAS,
                                 w, h);
    const cJSON* l = NULL;
    const cJSON* list = doc ? cJSON_GetObjectItemCaseSensitive(m, "layers") : NULL;
    cJSON_ArrayForEach(l, list) {
        read_layer(doc, zip, l);
        const cJSON* o = NULL; /* version 2: the layer's objects follow it */
        cJSON_ArrayForEach(o, cJSON_GetObjectItemCaseSensitive(l, "objects")) read_layer(doc, zip, o);
    }
    fz_drop_archive(ctx, zip);
    if (!doc || !doc->layer_count || doc->layers[0]->kind != SPDF_PAINT_LAYER_BACKGROUND) {
        cJSON_Delete(m);
        if (doc) spdf_paint_close(doc);
        else fz_drop_context(ctx);
        spdf_paint_set_error(err, err_len, version > SPDF_PAINT_FILE_VERSION
                                               ? "This project was made by a newer ShenzhenPDF."
                                               : "This isn't a Shenzhen Paint project, or it can't be read.");
        return NULL;
    }
    const cJSON* dpi = cJSON_GetObjectItemCaseSensitive(m, "dpi");
    if (cJSON_IsNumber(dpi) && dpi->valuedouble > 0) doc->dpi = (float)dpi->valuedouble;
    doc->has_alpha = !cJSON_IsFalse(cJSON_GetObjectItemCaseSensitive(m, "transparent"));
    spdf_paint_json_color(cJSON_GetObjectItemCaseSensitive(m, "color1"), &doc->color1);
    spdf_paint_json_color(cJSON_GetObjectItemCaseSensitive(m, "color2"), &doc->color2);
    for (int i = 0; i < SPDF_PAINT_CUSTOM_COLORS; i++)
        spdf_paint_json_color(cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(m, "custom"), i), &doc->custom[i]);
    spdf_paint_normalize_layers(doc); /* a version 1 project: its objects on a layer */
    doc->active = (spdf_paint_id)cJSON_GetNumberValue(cJSON_GetObjectItemCaseSensitive(m, "active"));
    spdf_paint_layer* active = spdf_paint_layer_find(doc, doc->active);
    if (!active || active->kind == SPDF_PAINT_LAYER_OBJECT || active->kind == SPDF_PAINT_LAYER_BACKGROUND)
        active = spdf_paint_home_layer(doc); /* new drawing goes on Layer 1, as in a new document */
    doc->active = active ? active->id : doc->layers[0]->id;
    if (!doc->layers[0]->pixels) doc->layers[0]->pixels = spdf_paint_pixmap_new(ctx, w, h);
    cJSON_Delete(m);
    spdf_paint_damage_all(doc);
    return doc;
}

/* ---- doc.render ---- */

spdf_paint_status spdf_paint_op_doc_render(spdf_paint_call* call) {
    spdf_paint_render_options options;
    memset(&options, 0, sizeof(options));
    double scale = 1;
    spdf_paint_arg_number(call, "scale", &scale);
    options.scale = (float)scale;
    spdf_paint_arg_rect(call, "region", &options.region);
    spdf_paint_id* ids = NULL;
    int count = 0;
    const cJSON* layers = cJSON_GetObjectItemCaseSensitive(call->args, "layers");
    int n = cJSON_GetArraySize(layers);
    if (n > 0 && (ids = malloc((size_t)n * sizeof(*ids)))) {
        const cJSON* e = NULL;
        cJSON_ArrayForEach(e, layers) ids[count++] = (spdf_paint_id)e->valuedouble;
        options.layers = ids;
        options.layer_count = count;
    }
    const char* out = spdf_paint_arg_string(call, "out");
    char err[256] = "";
    spdf_paint_status status = spdf_paint_render_png(call->doc, &options, out, err, sizeof(err));
    free(ids);
    if (status != SPDF_PAINT_OK) return spdf_paint_call_fail(call, status, "%s", err);
    float w = options.region.x1 > options.region.x0 ? options.region.x1 - options.region.x0 : (float)call->doc->width;
    float h = options.region.y1 > options.region.y0 ? options.region.y1 - options.region.y0 : (float)call->doc->height;
    cJSON_AddStringToObject(call->reply, "path", out);
    cJSON_AddNumberToObject(call->reply, "width", (int)(w * scale + 0.999));
    cJSON_AddNumberToObject(call->reply, "height", (int)(h * scale + 0.999));
    return SPDF_PAINT_OK;
}
