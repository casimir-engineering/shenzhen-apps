/* canvas.resize, canvas.properties and image.crop (docs/plans/annotate.md § 2 Image group, § 6 Canvas and Image): the
 * operations that change the canvas itself, so a PDF page (whose size is the page's) answers page_locked. Objects keep
 * their place in the picture; the new area of the Background takes the fill colour. */
#include "spdf_paint_model.h"

#include <string.h>

static const char k_page_locked[] = "The page itself can't be changed.";

static int is_pdf(const spdf_paint_doc* doc) { return doc->kind == SPDF_PAINT_DOC_PDF; }

spdf_paint_status spdf_paint_op_image_crop(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    if (is_pdf(doc)) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, k_page_locked);
    spdf_rect r;
    if (!spdf_paint_arg_rect(call, "rect", &r)) {
        if (!doc->selection.mask)
            return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NOTHING_SELECTED, "Select the area to crop to first.");
        fz_irect b = doc->selection.bounds;
        r = (spdf_rect){(float)b.x0, (float)b.y0, (float)b.x1, (float)b.y1};
    }
    fz_irect box = spdf_paint_raster_box(doc, r);
    if (fz_is_empty_irect(box))
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_INVALID_ARGUMENT, "That area is outside the picture.");
    spdf_paint_history_save_canvas(doc);
    spdf_paint_history_save_active(doc);
    int w = box.x1 - box.x0, h = box.y1 - box.y0;
    for (int i = 0; i < doc->layer_count; i++) {
        spdf_paint_layer* layer = doc->layers[i];
        if (layer->object) {
            spdf_paint_map_object(layer->object, fz_translate((float)-box.x0, (float)-box.y0), 1, 1, 0, 0, 1);
            continue;
        }
        if (!layer->pixels) continue;
        fz_pixmap* out = spdf_paint_place_pixmap(doc->ctx, layer->pixels, w, h, -box.x0, -box.y0, NULL);
        if (!out) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
        fz_drop_pixmap(doc->ctx, layer->pixels);
        layer->pixels = out;
    }
    spdf_paint_selection_free(doc->ctx, &doc->selection);
    spdf_paint_set_size(doc, w, h);
    cJSON_AddNumberToObject(call->reply, "width", w);
    cJSON_AddNumberToObject(call->reply, "height", h);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_canvas_resize(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    if (is_pdf(doc)) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, k_page_locked);
    double width = doc->width, height = doc->height;
    spdf_paint_color background = 0;
    spdf_paint_arg_number(call, "width", &width);
    spdf_paint_arg_number(call, "height", &height);
    spdf_paint_arg_color(call, "fill", &background);
    int w = (int)width, h = (int)height;
    if ((uint64_t)w * h > SPDF_PAINT_MAX_PIXELS)
        return spdf_paint_call_fail(call, SPDF_PAINT_ERR_TOO_LARGE, "A canvas can hold 268 million pixels at most.");
    const char* anchor = spdf_paint_arg_string(call, "anchor");
    if (!anchor) anchor = "top-left";
    int dx = strstr(anchor, "right") ? w - doc->width : strstr(anchor, "left") ? 0 : (w - doc->width) / 2;
    int dy = !strncmp(anchor, "bottom", 6) ? h - doc->height : !strncmp(anchor, "top", 3) ? 0 : (h - doc->height) / 2;
    spdf_paint_history_save_canvas(doc);
    spdf_paint_history_save_active(doc);
    unsigned char fill[4];
    spdf_paint_color_bytes(background, fill);
    for (int i = 0; i < doc->layer_count; i++) {
        spdf_paint_layer* layer = doc->layers[i];
        if (layer->object) {
            spdf_paint_map_object(layer->object, fz_translate((float)dx, (float)dy), 1, 1, 0, 0, 1);
            continue;
        }
        if (!layer->pixels) continue;
        fz_pixmap* out = spdf_paint_place_pixmap(doc->ctx, layer->pixels, w, h, dx, dy,
                                                 layer->kind == SPDF_PAINT_LAYER_BACKGROUND ? fill : NULL);
        if (!out) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_NO_MEMORY, "There is not enough memory.");
        fz_drop_pixmap(doc->ctx, layer->pixels);
        layer->pixels = out;
    }
    spdf_paint_selection_free(doc->ctx, &doc->selection);
    spdf_paint_set_size(doc, w, h);
    cJSON_AddNumberToObject(call->reply, "width", w);
    cJSON_AddNumberToObject(call->reply, "height", h);
    return SPDF_PAINT_OK;
}

spdf_paint_status spdf_paint_op_canvas_properties(spdf_paint_call* call) {
    spdf_paint_doc* doc = call->doc;
    if (is_pdf(doc)) return spdf_paint_call_fail(call, SPDF_PAINT_ERR_PAGE_LOCKED, k_page_locked);
    double dpi = doc->dpi;
    int bw = 0;
    if (spdf_paint_arg_number(call, "ppi", &dpi) || spdf_paint_arg_number(call, "dpi", &dpi)) {
        spdf_paint_history_save_dpi(doc);
        doc->dpi = (float)dpi;
    }
    if (spdf_paint_arg_bool(call, "blackAndWhite", &bw) && bw)
        for (int i = 0; i < doc->layer_count; i++) {
            spdf_paint_layer* layer = doc->layers[i];
            if (layer->pixels) {
                spdf_paint_history_save_pixels(doc, layer, fz_make_irect(0, 0, layer->pixels->w, layer->pixels->h));
                spdf_paint_black_white_pixels(layer->pixels);
            } else if (layer->object && layer->object->kind == SPDF_PAINT_OBJ_PICTURE && layer->object->u.picture.pixels) {
                spdf_paint_history_save_object(doc, layer);
                spdf_paint_black_white_pixels(layer->object->u.picture.pixels);
            }
        }
    spdf_paint_damage_all(doc);
    cJSON_AddNumberToObject(call->reply, "dpi", doc->dpi);
    return SPDF_PAINT_OK;
}
