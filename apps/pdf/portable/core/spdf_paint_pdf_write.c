/* Writing a PDF page canvas back into its page (docs/plans/annotate.md § 5 PDFs table): every layer and object that
 * changed since the model and the file last agreed (spdf_paint_pdf_internal.h), as the annotation the table names,
 * each with an appearance stream other readers draw; then /Annots put in the canvas's depth order (first = back).
 * Drawing layers, pictures, text boxes and textured shapes are Stamps or FreeText with a picture appearance (2x the
 * page resolution, text 4x); solid shapes are Square, Circle, Polygon or Ink with a vector appearance; Fill & Sign's
 * items, pen lines and arrows go through spdf_fill_* (spdf_paint_pdf_fill.c). Visibility is the Hidden flag and
 * opacity /CA (also inside our appearances, which MuPDF draws without applying /CA). Never touches the page itself.
 * The caller saves (Fill & Sign's commit cycle). */
#include "spdf_paint_pdf_internal.h"
#include "spdf_paint_pdf_layers.h"

#include "spdf_core_document.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void spdf_paint_pdf_set_appearance(fz_context* ctx, pdf_annot* annot, fz_display_list* list, fz_rect r) {
    fz_matrix page_ctm, flip = {1, 0, 0, -1, -r.x0, r.y1}, form;
    pdf_page_transform(ctx, pdf_annot_page(ctx, annot), NULL, &page_ctm);
    /* The list is page space as displayed; MuPDF flips it into the form's space. The form's /Matrix takes that back
     * to page space, then to PDF space: upright on a rotated page, and the form's box lands exactly on /Rect. */
    form = fz_concat(fz_invert_matrix(flip), fz_invert_matrix(page_ctm));
    pdf_dict_put_rect(ctx, pdf_annot_obj(ctx, annot), PDF_NAME(Rect), fz_transform_rect(r, fz_invert_matrix(page_ctm)));
    pdf_set_annot_appearance_from_display_list(ctx, annot, "N", NULL, form, list);
}

/* ---- What our objects look like ---- */

static fz_matrix canvas_to_pixels(fz_rect r, float scale) {
    return fz_concat(fz_translate(-r.x0, -r.y0), fz_scale(scale, scale));
}

/* An image placed over page rect r, as a list (opacity applied). */
static fz_display_list* image_list(fz_context* ctx, fz_pixmap* pixmap, fz_matrix image_ctm, fz_rect r, float opacity) {
    fz_display_list* volatile list = NULL;
    fz_device* volatile dev = NULL;
    fz_image* volatile image = NULL;
    fz_try(ctx) {
        list = fz_new_display_list(ctx, r);
        dev = fz_new_list_device(ctx, list);
        image = fz_new_image_from_pixmap(ctx, pixmap, NULL);
        fz_fill_image(ctx, dev, image, image_ctm, opacity, fz_default_color_params);
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_image(ctx, image);
        fz_drop_device(ctx, dev);
    }
    fz_catch(ctx) {
        fz_drop_display_list(ctx, list);
        fz_rethrow(ctx);
    }
    return list;
}

/* The object drawn by the core (Core B's drawers) into a picture of its bounds at `scale` pixels per point. */
static fz_pixmap* object_pixels(spdf_paint_doc* doc, const spdf_paint_object* object, fz_rect r, float scale) {
    fz_context* ctx = doc->ctx;
    int w = (int)ceilf((r.x1 - r.x0) * scale), h = (int)ceilf((r.y1 - r.y0) * scale);
    fz_pixmap* p = fz_new_pixmap(ctx, fz_device_rgb(ctx), fz_maxi(w, 1), fz_maxi(h, 1), NULL, 1);
    fz_clear_pixmap(ctx, p);
    fz_try(ctx) spdf_paint_object_draw(doc, object, canvas_to_pixels(r, scale), p, fz_pixmap_bbox(ctx, p), 1.0f);
    fz_catch(ctx) {
        fz_drop_pixmap(ctx, p);
        fz_rethrow(ctx);
    }
    return p;
}

static fz_rect object_box(const spdf_paint_object* o) {
    spdf_rect b = o->bounds;
    if (!(b.x1 > b.x0 && b.y1 > b.y0)) b = o->place.rect;
    return fz_make_rect(floorf(b.x0) - 1, floorf(b.y0) - 1, ceilf(b.x1) + 1, ceilf(b.y1) + 1);
}

static int solid_shape(const spdf_paint_shape_params* s) {
    return (s->outline.style == SPDF_PAINT_STYLE_NONE || s->outline.style == SPDF_PAINT_STYLE_SOLID) &&
           (s->fill.style == SPDF_PAINT_STYLE_NONE || s->fill.style == SPDF_PAINT_STYLE_SOLID);
}

static int open_shape(spdf_paint_shape shape) {
    return shape == SPDF_PAINT_SHAPE_LINE || shape == SPDF_PAINT_SHAPE_CURVE || shape == SPDF_PAINT_SHAPE_ARROW_LINE;
}

/* A solid shape as vectors: the core's path, filled with the fill colour, stroked with the outline. */
static fz_display_list* shape_list(fz_context* ctx, const spdf_paint_object* o, fz_rect r, float opacity) {
    const spdf_paint_shape_params* s = &o->u.shape;
    fz_display_list* volatile list = NULL;
    fz_device* volatile dev = NULL;
    fz_path* volatile path = NULL;
    fz_stroke_state* volatile stroke = NULL;
    fz_try(ctx) {
        float rgb[3];
        list = fz_new_display_list(ctx, r);
        dev = fz_new_list_device(ctx, list);
        path = spdf_paint_shape_path(ctx, &o->place, s);
        if (path && s->fill.style == SPDF_PAINT_STYLE_SOLID && !open_shape(s->shape)) {
            spdf_paint_pdf_rgb(s->fill.color, rgb);
            fz_fill_path(ctx, dev, path, 0, fz_identity, fz_device_rgb(ctx), rgb,
                         opacity * (float)(s->fill.color & 0xFF) / 255.0f, fz_default_color_params);
        }
        if (path && s->outline.style == SPDF_PAINT_STYLE_SOLID && s->outline.width > 0) {
            stroke = fz_new_stroke_state(ctx);
            stroke->linewidth = s->outline.width;
            stroke->linejoin = open_shape(s->shape) ? FZ_LINEJOIN_ROUND : FZ_LINEJOIN_MITER;
            stroke->start_cap = stroke->end_cap = stroke->dash_cap = open_shape(s->shape) ? FZ_LINECAP_ROUND : FZ_LINECAP_BUTT;
            spdf_paint_pdf_rgb(s->outline.color, rgb);
            fz_stroke_path(ctx, dev, path, stroke, fz_identity, fz_device_rgb(ctx), rgb,
                           opacity * (float)(s->outline.color & 0xFF) / 255.0f, fz_default_color_params);
        }
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        fz_drop_stroke_state(ctx, stroke);
        fz_drop_path(ctx, path);
        fz_drop_device(ctx, dev);
    }
    fz_catch(ctx) {
        fz_drop_display_list(ctx, list);
        fz_rethrow(ctx);
    }
    return list;
}

/* Where a Picture's own pixels go: the unit square through flips, the box, then the rotation about its centre. */
static fz_matrix picture_matrix(const spdf_paint_placement* p) {
    float w = p->rect.x1 - p->rect.x0, h = p->rect.y1 - p->rect.y0;
    float cx = 0.5f * (p->rect.x0 + p->rect.x1), cy = 0.5f * (p->rect.y0 + p->rect.y1);
    fz_matrix m = fz_make_matrix(p->flip_h ? -1 : 1, 0, 0, p->flip_v ? -1 : 1, p->flip_h ? 1 : 0, p->flip_v ? 1 : 0);
    m = fz_concat(m, fz_scale(w, h));
    m = fz_concat(m, fz_translate(p->rect.x0 - cx, p->rect.y0 - cy));
    m = fz_concat(m, fz_rotate(p->rotation));
    return fz_concat(m, fz_translate(cx, cy));
}

/* ---- Our annotations ---- */

static pdf_annot* find_annot(fz_context* ctx, pdf_page* page, const char* nm) {
    pdf_annot* a;
    for (a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a))
        if (strcmp(spdf_paint_pdf_nm(ctx, pdf_annot_obj(ctx, a)), nm) == 0) return a;
    return NULL;
}

static void put_points(fz_context* ctx, pdf_obj* array, const spdf_paint_point* pts, int n, fz_matrix to_pdf) {
    int i;
    for (i = 0; i < n; ++i) {
        fz_point p = fz_transform_point(fz_make_point(pts[i].x, pts[i].y), to_pdf);
        pdf_array_push_real(ctx, array, p.x);
        pdf_array_push_real(ctx, array, p.y);
    }
}

/* The annotation's own properties for the layer: /NM, flags, /CA, /SPDFAnnotate (version, kind, name, the operation
 * arguments, a revision), and per subtype what other readers use when they redraw it themselves. */
static void put_ours(spdf_paint_doc* doc, pdf_annot* annot, const spdf_paint_layer* layer, const char* nm,
                     const char* kind, const char* args, fz_irect box) {
    fz_context* ctx = doc->ctx;
    pdf_obj* obj = pdf_annot_obj(ctx, annot);
    pdf_obj* ours;
    int index = spdf_paint_layer_index(doc, layer->id);
    float opacity = spdf_paint_entry_opacity(doc, index); /* its own times its layer's, as drawn */
    pdf_dict_puts_drop(ctx, obj, "NM", pdf_new_text_string(ctx, nm));
    /* Hidden, and its drawing kept aside (spdf_paint_pdf_stash_appearance): Quick Look draws hidden annotations. */
    pdf_dict_put_int(ctx, obj, PDF_NAME(F), spdf_paint_entry_shown(doc, index) ? PDF_ANNOT_IS_PRINT : PDF_ANNOT_IS_HIDDEN);
    pdf_dict_put(ctx, obj, PDF_NAME(P), pdf_annot_page(ctx, annot)->obj);
    if (opacity < 1) pdf_dict_put_real(ctx, obj, PDF_NAME(CA), opacity);
    ours = pdf_dict_puts_dict(ctx, obj, SPDF_PAINT_PDF_KEY, 6);
    pdf_dict_puts_drop(ctx, ours, "V", pdf_new_int(ctx, SPDF_PAINT_PDF_VERSION));
    pdf_dict_puts_drop(ctx, ours, "Kind", pdf_new_text_string(ctx, kind));
    pdf_dict_puts_drop(ctx, ours, "Name", pdf_new_text_string(ctx, layer->name));
    if (args) pdf_dict_puts_drop(ctx, ours, "Args", pdf_new_text_string(ctx, args));
    pdf_dict_puts_drop(ctx, ours, "Rev", pdf_new_int(ctx, (int64_t)++doc->pdf_state->rev));
    spdf_paint_pdf_put_layer_record(doc, obj, layer);
    if (!fz_is_empty_irect(box)) {
        pdf_obj* b = pdf_new_array(ctx, pdf_get_bound_document(ctx, obj), 4);
        pdf_dict_puts_drop(ctx, ours, "Box", b);
        pdf_array_push_int(ctx, b, box.x0), pdf_array_push_int(ctx, b, box.y0);
        pdf_array_push_int(ctx, b, box.x1), pdf_array_push_int(ctx, b, box.y1);
    }
}

static void put_shape_semantics(fz_context* ctx, pdf_annot* annot, const spdf_paint_object* o, fz_matrix to_pdf) {
    const spdf_paint_shape_params* s = &o->u.shape;
    pdf_obj* obj = pdf_annot_obj(ctx, annot);
    pdf_obj* bs = pdf_dict_put_dict(ctx, obj, PDF_NAME(BS), 2);
    float rgb[3];
    pdf_dict_put_real(ctx, bs, PDF_NAME(W), s->outline.style == SPDF_PAINT_STYLE_NONE ? 0 : s->outline.width);
    spdf_paint_pdf_rgb(s->outline.color, rgb);
    if (s->outline.style != SPDF_PAINT_STYLE_NONE) pdf_dict_put_array(ctx, obj, PDF_NAME(C), 3);
    if (s->outline.style != SPDF_PAINT_STYLE_NONE) {
        pdf_obj* c = pdf_dict_get(ctx, obj, PDF_NAME(C));
        pdf_array_push_real(ctx, c, rgb[0]), pdf_array_push_real(ctx, c, rgb[1]), pdf_array_push_real(ctx, c, rgb[2]);
    }
    if (s->fill.style == SPDF_PAINT_STYLE_SOLID && !open_shape(s->shape)) {
        pdf_obj* ic = pdf_dict_put_array(ctx, obj, PDF_NAME(IC), 3);
        spdf_paint_pdf_rgb(s->fill.color, rgb);
        pdf_array_push_real(ctx, ic, rgb[0]), pdf_array_push_real(ctx, ic, rgb[1]), pdf_array_push_real(ctx, ic, rgb[2]);
    }
    if (pdf_annot_type(ctx, annot) == PDF_ANNOT_INK && s->point_count > 0) {
        pdf_obj* list = pdf_dict_put_array(ctx, obj, PDF_NAME(InkList), 1);
        put_points(ctx, pdf_array_push_array(ctx, list, (size_t)s->point_count * 2), s->points, s->point_count, to_pdf);
    } else if (pdf_annot_type(ctx, annot) == PDF_ANNOT_POLYGON) {
        fz_path* path = spdf_paint_shape_path(ctx, &o->place, s);
        fz_rect b = path ? fz_bound_path(ctx, path, NULL, fz_identity) : fz_empty_rect;
        spdf_paint_point corners[4] = {{b.x0, b.y0, 1}, {b.x1, b.y0, 1}, {b.x1, b.y1, 1}, {b.x0, b.y1, 1}};
        fz_drop_path(ctx, path);
        put_points(ctx, pdf_dict_put_array(ctx, obj, PDF_NAME(Vertices), 8), s->point_count >= 3 ? s->points : corners,
                   s->point_count >= 3 ? s->point_count : 4, to_pdf);
    }
}

static enum pdf_annot_type shape_subtype(const spdf_paint_shape_params* s) {
    if (!solid_shape(s)) return PDF_ANNOT_STAMP;
    if (open_shape(s->shape)) return PDF_ANNOT_INK;
    if (s->shape == SPDF_PAINT_SHAPE_RECTANGLE || s->shape == SPDF_PAINT_SHAPE_ROUNDED_RECTANGLE) return PDF_ANNOT_SQUARE;
    if (s->shape == SPDF_PAINT_SHAPE_OVAL) return PDF_ANNOT_CIRCLE;
    return PDF_ANNOT_POLYGON;
}

/* The used box of a drawing layer's pixels (raster pixels), empty when nothing is painted. */
static fz_irect used_box(const fz_pixmap* p) {
    fz_irect b = {p->w, p->h, 0, 0};
    int x, y;
    for (y = 0; y < p->h; ++y) {
        const unsigned char* row = p->samples + (size_t)y * p->stride + 3;
        for (x = 0; x < p->w; ++x)
            if (row[(size_t)x * 4]) {
                if (x < b.x0) b.x0 = x;
                if (x >= b.x1) b.x1 = x + 1;
                if (y < b.y0) b.y0 = y;
                if (y >= b.y1) b.y1 = y + 1;
            }
    }
    return b.x1 > b.x0 ? b : fz_empty_irect;
}

static fz_pixmap* crop(fz_context* ctx, const fz_pixmap* p, fz_irect box) {
    fz_pixmap* out = fz_new_pixmap(ctx, fz_device_rgb(ctx), box.x1 - box.x0, box.y1 - box.y0, NULL, 1);
    int y;
    for (y = box.y0; y < box.y1; ++y)
        memcpy(out->samples + (size_t)(y - box.y0) * out->stride, p->samples + (size_t)y * p->stride + (size_t)box.x0 * 4,
               (size_t)(box.x1 - box.x0) * 4);
    return out;
}

/* Deletes the annotation named nm, if any. */
static void delete_named(fz_context* ctx, pdf_page* page, const char* nm) {
    pdf_annot* a = nm ? find_annot(ctx, page, nm) : NULL;
    if (a) pdf_delete_annot(ctx, page, a);
}

/* One of our layers (a drawing layer) or objects (shape, text box, picture), written again under its /NM. Returns
 * the annotation (borrowed) or NULL when there is nothing to write (an empty drawing layer). */
static pdf_annot* write_ours(spdf_paint_doc* doc, pdf_page* page, spdf_paint_layer* layer, const char* nm) {
    fz_context* ctx = doc->ctx;
    spdf_paint_object* o = layer->object;
    fz_display_list* volatile list = NULL;
    fz_pixmap* volatile pixels = NULL;
    pdf_annot* volatile annot = NULL;
    char* volatile args = NULL;
    fz_matrix page_ctm;
    int index = spdf_paint_layer_index(doc, layer->id);
    float opacity = spdf_paint_entry_opacity(doc, index);
    pdf_page_transform(ctx, page, NULL, &page_ctm);
    delete_named(ctx, page, nm);
    fz_try(ctx) {
        float scale = (float)doc->raster_scale;
        fz_irect box = fz_empty_irect;
        fz_rect r;
        const char* kind;
        enum pdf_annot_type type = PDF_ANNOT_STAMP;
        if (layer->kind == SPDF_PAINT_LAYER_RASTER) {
            kind = "layer";
            box = layer->pixels ? used_box(layer->pixels) : fz_empty_irect;
            if (fz_is_empty_irect(box)) break;
            pixels = crop(ctx, layer->pixels, box);
            r = fz_make_rect(box.x0 / scale, box.y0 / scale, box.x1 / scale, box.y1 / scale);
            list = image_list(ctx, pixels, fz_concat(fz_scale(r.x1 - r.x0, r.y1 - r.y0), fz_translate(r.x0, r.y0)), r,
                              opacity);
            layer->pdf_used = box;
        } else {
            cJSON* json = spdf_paint_pdf_object_args(o);
            char* text = json ? cJSON_PrintUnformatted(json) : NULL;
            args = spdf_paint_pdf_strdup(text ? text : "{}");
            cJSON_free(text);
            cJSON_Delete(json);
            r = object_box(o);
            if (o->kind == SPDF_PAINT_OBJ_PICTURE) {
                kind = "picture";
                if (!o->u.picture.pixels) break;
                list = image_list(ctx, o->u.picture.pixels, picture_matrix(&o->place), r, opacity);
            } else if (o->kind == SPDF_PAINT_OBJ_TEXT) {
                kind = "text", type = PDF_ANNOT_FREE_TEXT;
                pixels = object_pixels(doc, o, r, SPDF_PAINT_PDF_TEXT_SCALE);
                list = image_list(ctx, pixels, fz_concat(fz_scale(r.x1 - r.x0, r.y1 - r.y0), fz_translate(r.x0, r.y0)),
                                  r, opacity);
            } else {
                kind = "shape", type = shape_subtype(&o->u.shape);
                if (type != PDF_ANNOT_STAMP) {
                    list = shape_list(ctx, o, r, opacity);
                } else {
                    pixels = object_pixels(doc, o, r, scale);
                    list = image_list(ctx, pixels, fz_concat(fz_scale(r.x1 - r.x0, r.y1 - r.y0), fz_translate(r.x0, r.y0)),
                                      r, opacity);
                }
            }
        }
        annot = pdf_create_annot_raw(ctx, page, type);
        put_ours(doc, annot, layer, nm, kind, args, box);
        if (type == PDF_ANNOT_STAMP) pdf_dict_put_name(ctx, pdf_annot_obj(ctx, annot), PDF_NAME(Name), "SPDFAnnotate");
        if (type == PDF_ANNOT_FREE_TEXT) {
            char da[64], color[10];
            float rgb[3];
            spdf_paint_pdf_rgb(o->u.text.color, rgb);
            spdf_paint_pdf_color_text(o->u.text.color, color);
            snprintf(da, sizeof da, "/Helv %.1f Tf %.3f %.3f %.3f rg", o->u.text.size, rgb[0], rgb[1], rgb[2]);
            pdf_dict_put_text_string(ctx, pdf_annot_obj(ctx, annot), PDF_NAME(Contents), o->u.text.utf8 ? o->u.text.utf8 : "");
            pdf_dict_put_string(ctx, pdf_annot_obj(ctx, annot), PDF_NAME(DA), da, strlen(da));
        } else if (o && o->kind == SPDF_PAINT_OBJ_SHAPE && type != PDF_ANNOT_STAMP) {
            put_shape_semantics(ctx, annot, o, fz_invert_matrix(page_ctm));
        }
        spdf_paint_pdf_set_appearance(ctx, annot, list, r);
        if (!spdf_paint_entry_shown(doc, index)) spdf_paint_pdf_stash_appearance(ctx, page->doc, pdf_annot_obj(ctx, annot), 1);
        pdf_clean_obj(ctx, pdf_annot_obj(ctx, annot)); /* our appearance stays: MuPDF redraws dirty annotations */
    }
    fz_always(ctx) {
        free(args);
        fz_drop_pixmap(ctx, pixels);
        fz_drop_display_list(ctx, list);
    }
    fz_catch(ctx) fz_rethrow(ctx);
    if (o) {
        fz_free(ctx, o->pdf_nm);
        o->pdf_nm = fz_strdup(ctx, nm);
    }
    fz_free(ctx, layer->pdf_nm);
    layer->pdf_nm = fz_strdup(ctx, nm);
    return annot;
}

/* ---- Depth: /Annots in the canvas's order ---- */

static int pushed(fz_context* ctx, pdf_obj* list, pdf_obj* annot) {
    int i;
    for (i = 0; i < pdf_array_len(ctx, list); ++i)
        if (pdf_objcmp(ctx, pdf_array_get(ctx, list, i), annot) == 0) return 1;
    return 0;
}

static void push_matching(fz_context* ctx, pdf_obj* annots, pdf_obj* sorted, const spdf_paint_pdf_entry* e) {
    int i;
    size_t len = e->nm ? strlen(e->nm) : 0;
    for (i = 0; i < pdf_array_len(ctx, annots); ++i) {
        pdf_obj* a = pdf_array_get(ctx, annots, i);
        const char* nm = spdf_paint_pdf_nm(ctx, a);
        int match = e->origin == SPDF_PAINT_PDF_FOREIGN
                        ? pdf_to_num(ctx, a) == e->object_number
                        : strncmp(nm, e->nm, len) == 0 && (nm[len] == 0 || (e->origin == SPDF_PAINT_PDF_FILL &&
                                                                              strncmp(nm + len, "-c", 2) == 0));
        if (match && !pushed(ctx, sorted, a)) pdf_array_push(ctx, sorted, a);
    }
}

/* Returns 1 when the order changed. Form fields, links and pop-ups stay at the back in their own order; anything the
 * canvas doesn't know yet stays in front. */
static int write_order(spdf_paint_doc* doc, pdf_page* page) {
    fz_context* ctx = doc->ctx;
    pdf_obj* annots = pdf_dict_get(ctx, page->obj, PDF_NAME(Annots));
    pdf_obj* volatile sorted = NULL;
    int i, n = pdf_array_len(ctx, annots), changed = 0;
    if (n < 2) return 0;
    fz_try(ctx) {
        sorted = pdf_new_array(ctx, page->doc, n);
        for (i = 0; i < n; ++i) {
            pdf_obj* a = pdf_array_get(ctx, annots, i);
            pdf_obj* subtype = pdf_dict_get(ctx, a, PDF_NAME(Subtype));
            if (subtype == PDF_NAME(Widget) || subtype == PDF_NAME(Link) || subtype == PDF_NAME(Popup))
                pdf_array_push(ctx, sorted, a);
        }
        for (i = 1; i < doc->layer_count; ++i) {
            spdf_paint_pdf_entry* e = spdf_paint_pdf_entry_for(doc, doc->layers[i]->id);
            if (e) push_matching(ctx, annots, sorted, e);
        }
        for (i = 0; i < n; ++i)
            if (!pushed(ctx, sorted, pdf_array_get(ctx, annots, i))) pdf_array_push(ctx, sorted, pdf_array_get(ctx, annots, i));
        for (i = 0; i < n && !changed; ++i) changed = pdf_objcmp(ctx, pdf_array_get(ctx, annots, i), pdf_array_get(ctx, sorted, i)) != 0;
        if (changed) {
            for (i = 0; i < n; ++i) pdf_array_put(ctx, annots, i, pdf_array_get(ctx, sorted, i));
            pdf_sync_annots(ctx, page);
        }
    }
    fz_always(ctx) pdf_drop_obj(ctx, sorted);
    fz_catch(ctx) fz_rethrow(ctx);
    return changed;
}

/* ---- Public ---- */

/* spdf_paint_pdf_fill.c: Fill & Sign's items, pen lines and arrows through spdf_fill_*. */
int spdf_paint_pdf_write_fill(spdf_paint_doc* doc, spdf_paint_layer* layer, spdf_paint_pdf_entry** entry);
void spdf_paint_pdf_delete_fill(spdf_paint_doc* doc, const char* group);

spdf_paint_status spdf_paint_pdf_write_back(spdf_paint_doc* doc, int* pages_changed, char* err, size_t err_len) {
    spdf_paint_pdf_state* st = spdf_paint_pdf_state_of(doc);
    fz_context* ctx;
    pdf_page* volatile page = NULL;
    int volatile changed = 0;
    if (pages_changed) *pages_changed = 0;
    if (!st || !doc->pdf) {
        spdf_paint_set_error(err, err_len, "This canvas is not a PDF page.");
        return SPDF_PAINT_ERR_FAILED;
    }
    ctx = doc->ctx;
    st->writing = 1;
    fz_try(ctx) {
        int i;
        page = spdf_paint_pdf_load_page(doc);
        for (i = 0; i < st->count; ++i) st->entries[i].seen = 0;
        for (i = 1; i < doc->layer_count; ++i) {
            spdf_paint_layer* layer = doc->layers[i];
            spdf_paint_pdf_entry* e = spdf_paint_pdf_entry_for(doc, layer->id);
            char* model = spdf_paint_pdf_layer_state(doc, layer);
            spdf_paint_object_kind ok = layer->object ? layer->object->kind : SPDF_PAINT_OBJ_SHAPE;
            int fill = layer->object && (ok == SPDF_PAINT_OBJ_PEN || ok == SPDF_PAINT_OBJ_ARROW ||
                                         ok == SPDF_PAINT_OBJ_FILL_TEXT || ok == SPDF_PAINT_OBJ_FILL_MARK ||
                                         ok == SPDF_PAINT_OBJ_FILL_SIGNATURE);
            if (e) e->seen = 1;
            if ((e && e->model && strcmp(e->model, model) == 0) || layer->kind == SPDF_PAINT_LAYER_BACKGROUND ||
                (layer->object && ok == SPDF_PAINT_OBJ_FOREIGN)) {
                free(model);
                continue;
            }
            if (spdf_paint_pdf_name_empty_layer(doc, layer, e)) { /* nothing in the file: only its name */
                free(model);
                continue;
            }
            free(model);
            if (!spdf_owner_allows(doc->pdf, FZ_PERMISSION_ANNOTATE))
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF's owner doesn't allow adding to it.");
            changed = 1;
            if (fill) {
                spdf_paint_pdf_write_fill(doc, layer, &e);
            } else {
                char name[64];
                pdf_annot* annot;
                if (e) snprintf(name, sizeof name, "%s", e->nm);
                else if (layer->kind == SPDF_PAINT_LAYER_RASTER && spdf_paint_pdf_layer_key(layer)[0])
                    snprintf(name, sizeof name, "%s", layer->pdf_nm); /* its name in its objects' records */
                else {
                    char uuid[33];
                    spdf_paint_pdf_uuid(uuid);
                    snprintf(name, sizeof name, "%s%s%s", layer->kind == SPDF_PAINT_LAYER_RASTER ? SPDF_PAINT_LAYER_NM_PREFIX
                                                                                                    : SPDF_PAINT_NM_PREFIX,
                             layer->kind == SPDF_PAINT_LAYER_RASTER ? "" : ok == SPDF_PAINT_OBJ_TEXT ? "text-"
                                                                       : ok == SPDF_PAINT_OBJ_PICTURE ? "picture-" : "shape-",
                             uuid);
                }
                annot = write_ours(doc, page, layer, name);
                if (!e) e = spdf_paint_pdf_entry_add(doc, layer->id, SPDF_PAINT_PDF_OURS, name, 0);
                e->seen = 1;
                spdf_paint_pdf_entry_set(doc, e, NULL, annot ? spdf_paint_pdf_annot_fingerprint(ctx, pdf_annot_obj(ctx, annot))
                                                             : spdf_paint_pdf_strdup(""));
            }
            if (e) spdf_paint_pdf_entry_set(doc, e, spdf_paint_pdf_layer_state(doc, layer), NULL);
        }
        for (i = st->count - 1; i >= 0; --i) { /* layers deleted on the canvas */
            spdf_paint_pdf_entry* e = &st->entries[i];
            if (e->seen) continue;
            if (e->origin == SPDF_PAINT_PDF_OURS) delete_named(ctx, page, e->nm), changed = 1;
            else if (e->origin == SPDF_PAINT_PDF_FILL) spdf_paint_pdf_delete_fill(doc, e->nm), changed = 1;
            spdf_paint_pdf_entry_remove(doc, e); /* another reader's: locked, it comes back on the next read */
        }
        if (write_order(doc, page)) changed = 1;
    }
    fz_always(ctx) {
        pdf_drop_page(ctx, page);
        st->writing = 0;
    }
    fz_catch(ctx) {
        spdf_paint_set_error(err, err_len, fz_caught_message(ctx));
        spdf_drop_page_list_cache(doc->pdf, doc->page_index);
        return SPDF_PAINT_ERR_FAILED;
    }
    if (changed) {
        spdf_drop_page_list_cache(doc->pdf, doc->page_index);
        fz_try(ctx) spdf_paint_pdf_read(doc, 1); /* Fill & Sign's items as the file now holds them */
        fz_catch(ctx) {
            spdf_paint_set_error(err, err_len, fz_caught_message(ctx));
            return SPDF_PAINT_ERR_FAILED;
        }
    }
    if (pages_changed) *pages_changed = changed;
    return SPDF_PAINT_OK;
}
