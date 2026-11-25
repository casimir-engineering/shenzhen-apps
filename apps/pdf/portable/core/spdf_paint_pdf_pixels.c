/* The PDF page bridge's pixels (docs/plans/annotate.md § 5 PDFs): the page itself drawn as the locked Background
 * (its contents and form fields, on white paper, recoloured for the dark reading theme on screen), other readers'
 * annotations and Fill & Sign's items drawn from their appearance streams, and the picture inside one of our
 * appearances read back as premultiplied RGBA. */
#include "spdf_paint_pdf_internal.h"

#include "spdf_core_document.h"

#include <string.h>

static pdf_obj* find_image(fz_context* ctx, pdf_obj* xobject, int depth) {
    pdf_obj* xobjects = pdf_dict_getp(ctx, xobject, "Resources/XObject");
    int i;
    for (i = 0; i < pdf_dict_len(ctx, xobjects); ++i) {
        pdf_obj* x = pdf_dict_get_val(ctx, xobjects, i);
        if (pdf_dict_get(ctx, x, PDF_NAME(Subtype)) == PDF_NAME(Image)) return x;
        if (depth < 2 && (x = find_image(ctx, x, depth + 1))) return x;
    }
    return NULL;
}

/* The appearance's picture as premultiplied RGBA, alpha from its SMask. */
fz_pixmap* spdf_paint_pdf_appearance_pixels(fz_context* ctx, pdf_document* pdf, pdf_obj* annot) {
    pdf_obj* kept = pdf_dict_gets(ctx, pdf_dict_gets(ctx, annot, SPDF_PAINT_PDF_KEY), "AP"); /* hidden */
    pdf_obj* image_obj = find_image(ctx, kept ? kept : pdf_dict_getp(ctx, annot, "AP/N"), 0);
    fz_image* volatile image = NULL;
    fz_pixmap* volatile base = NULL;
    fz_pixmap* volatile mask = NULL;
    fz_pixmap* volatile out = NULL;
    if (!image_obj) return NULL;
    fz_try(ctx) {
        int x, y, w, h;
        image = pdf_load_image(ctx, pdf, image_obj);
        base = fz_get_pixmap_from_image(ctx, image, NULL, NULL, NULL, NULL);
        if (base->n != 3 + base->alpha || base->colorspace != fz_device_rgb(ctx)) {
            fz_pixmap* rgb = fz_convert_pixmap(ctx, base, fz_device_rgb(ctx), NULL, NULL, fz_default_color_params, 1);
            fz_drop_pixmap(ctx, base);
            base = rgb;
        }
        w = base->w, h = base->h;
        if (image->mask) {
            mask = fz_get_pixmap_from_image(ctx, image->mask, NULL, NULL, NULL, NULL);
            if (mask->w != w || mask->h != h) {
                fz_pixmap* scaled = fz_scale_pixmap(ctx, mask, 0, 0, (float)w, (float)h, NULL);
                fz_drop_pixmap(ctx, mask);
                mask = scaled;
            }
        }
        out = fz_new_pixmap(ctx, fz_device_rgb(ctx), w, h, NULL, 1);
        for (y = 0; y < h; ++y) {
            const unsigned char* s = base->samples + (size_t)y * base->stride;
            const unsigned char* m = mask ? mask->samples + (size_t)y * mask->stride : NULL;
            unsigned char* d = out->samples + (size_t)y * out->stride;
            for (x = 0; x < w; ++x, s += base->n, d += 4) {
                int a = m ? m[(size_t)x * mask->n] : base->alpha ? s[3] : 255;
                if (base->alpha && m) a = a * s[3] / 255;
                d[0] = (unsigned char)(base->alpha ? s[0] : s[0] * a / 255);
                d[1] = (unsigned char)(base->alpha ? s[1] : s[1] * a / 255);
                d[2] = (unsigned char)(base->alpha ? s[2] : s[2] * a / 255);
                d[3] = (unsigned char)a;
            }
        }
    }
    fz_always(ctx) {
        fz_drop_pixmap(ctx, mask);
        fz_drop_pixmap(ctx, base);
        fz_drop_image(ctx, image);
    }
    fz_catch(ctx) {
        fz_drop_pixmap(ctx, out);
        fz_rethrow(ctx);
    }
    return out;
}

/* ---- Drawing the locked page and other annotations ---- */

int spdf_paint_pdf_draw_page(spdf_paint_doc* doc, fz_matrix ctm, fz_pixmap* dest, fz_irect clip, int dark) {
    fz_context* ctx = doc->ctx;
    spdf_paint_pdf_state* st = spdf_paint_pdf_state_of(doc);
    pdf_page* volatile page = NULL;
    fz_device* volatile dev = NULL;
    int ok = 1;
    if (!st) return 0;
    clip = fz_intersect_irect(clip, fz_pixmap_bbox(ctx, dest));
    if (fz_is_empty_irect(clip)) return 1;
    fz_try(ctx) {
        if (!st->page_list) { /* the page and its form fields: everything the person can't change here */
            page = spdf_paint_pdf_load_page(doc);
            st->page_list = fz_new_display_list(ctx, pdf_bound_page(ctx, page, FZ_CROP_BOX));
            dev = fz_new_list_device(ctx, st->page_list);
            pdf_run_page_contents(ctx, page, dev, fz_identity, NULL);
            pdf_run_page_widgets(ctx, page, dev, fz_identity, NULL);
            fz_close_device(ctx, dev);
            fz_drop_device(ctx, dev);
            dev = NULL;
        }
        fz_clear_pixmap_rect_with_value(ctx, dest, 255, clip); /* white paper */
        dev = fz_new_draw_device_with_bbox(ctx, ctm, dest, &clip);
        /* the list is in page space (the device carries ctm): its cull rect too, or a small scale drops content */
        fz_run_display_list(ctx, st->page_list, dev, fz_identity,
                            fz_transform_rect(fz_rect_from_irect(clip), fz_invert_matrix(ctm)), NULL);
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        pdf_drop_page(ctx, page);
    }
    fz_catch(ctx) ok = 0;
    if (ok && dark && dest->n == 4) {
        spdf_recolor_table table;
        spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, spdf_recolor_default_dark_theme());
        spdf_recolor_rgba(dest->samples + (size_t)(clip.y0 - dest->y) * dest->stride + (size_t)(clip.x0 - dest->x) * 4,
                          clip.x1 - clip.x0, clip.y1 - clip.y0, (int)dest->stride, &table);
    }
    return ok;
}

int spdf_paint_pdf_draw_annotation(spdf_paint_doc* doc, const spdf_paint_object* object, fz_matrix ctm,
                                   fz_pixmap* dest, fz_irect clip, float opacity) {
    fz_context* ctx = doc->ctx;
    pdf_page* volatile page = NULL;
    fz_device* volatile dev = NULL;
    int ok = 1;
    if (!doc->pdf || !object) return 0;
    fz_try(ctx) {
        pdf_annot* annot;
        const char* group = object->kind == SPDF_PAINT_OBJ_FOREIGN ? NULL : object->pdf_nm;
        page = spdf_paint_pdf_load_page(doc);
        dev = fz_new_draw_device_with_bbox(ctx, fz_identity, dest, &clip);
        if (opacity < 1) fz_begin_group(ctx, dev, fz_rect_from_irect(clip), NULL, 1, 0, FZ_BLEND_NORMAL, opacity);
        for (annot = pdf_first_annot(ctx, page); annot; annot = pdf_next_annot(ctx, annot)) {
            pdf_obj* obj = pdf_annot_obj(ctx, annot);
            int match = group ? spdf_paint_pdf_has_prefix(spdf_paint_pdf_nm(ctx, obj), group)
                              : pdf_to_num(ctx, obj) == object->u.foreign.object_number;
            if (match) pdf_run_annot(ctx, annot, dev, ctm, NULL);
        }
        if (opacity < 1) fz_end_group(ctx, dev);
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        pdf_drop_page(ctx, page);
    }
    fz_catch(ctx) ok = 0;
    return ok;
}


/* ---- Questions the frontend asks ---- */

spdf_document* spdf_paint_pdf_document(const spdf_paint_doc* doc) {
    return doc && doc->kind == SPDF_PAINT_DOC_PDF ? doc->pdf : NULL;
}

spdf_paint_id spdf_paint_pdf_object_for_name(const spdf_paint_doc* doc, const char* nm) {
    int i;
    if (!doc || !nm || doc->kind != SPDF_PAINT_DOC_PDF) return 0;
    for (i = 0; i < doc->layer_count; ++i) {
        const spdf_paint_layer* l = doc->layers[i];
        const char* name = l->object ? l->object->pdf_nm : l->pdf_nm;
        if (name && strcmp(name, nm) == 0) return l->id;
    }
    return 0;
}

int spdf_paint_pdf_op_locked(const spdf_paint_doc* doc, const char* op) {
    int i, added = 0, raster = 0;
    const spdf_paint_layer* active = NULL;
    if (!op || (doc && doc->kind != SPDF_PAINT_DOC_PDF)) return 0;
    if (!strcmp(op, "canvas.resize") || !strcmp(op, "canvas.properties") || !strcmp(op, "image.crop")) return 1;
    for (i = 1; doc && i < doc->layer_count; ++i) {
        const spdf_paint_layer* l = doc->layers[i];
        if (l->locked) continue;
        ++added;
        if (l->kind == SPDF_PAINT_LAYER_RASTER) ++raster;
        if (l->id == doc->active) active = l;
    }
    if (!strcmp(op, "image.clear")) return !active || active->kind != SPDF_PAINT_LAYER_RASTER;
    if (!strcmp(op, "image.resize") || !strcmp(op, "image.skew") || !strcmp(op, "image.rotate") ||
        !strcmp(op, "image.flip") || !strcmp(op, "image.invert"))
        return added == 0;
    if (!strcmp(op, "select.lift") || !strcmp(op, "select.delete"))
        return !doc || (!raster && doc->selection.object_count == 0);
    if (!strcmp(op, "image.remove_background"))
        return !doc || (doc->selection.object_count == 0 && !(active && active->kind == SPDF_PAINT_LAYER_RASTER));
    return 0;
}
