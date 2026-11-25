/* spdf_fill_signature.c -- signatures and initials placed by Fill & Sign, and Save Final Copy (spdf_fill_items.h). */
#include "spdf_fill_items.h"
#include "spdf_core_document.h"
#include "spdf_fill_identity.h"
#include "spdf_fill_internal.h"

#include "mupdf/pdf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* -- signatures ------------------------------------------------------------------------------------------------- */

/* Absolute M L C Q Z only; after M further pairs are lines, as in SVG. Scaled by `scale`. */
static void parse_outline(fz_context* ctx, fz_path* path, const char* s, float scale) {
    char cmd = 0;
    while (*s) {
        float v[6];
        int need, i;
        char* end;
        if (*s == ' ' || *s == ',' || *s == '\n' || *s == '\t' || *s == '\r') {
            ++s;
            continue;
        }
        if ((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z')) {
            cmd = *s++;
            if (cmd == 'Z' || cmd == 'z') {
                fz_closepath(ctx, path);
                cmd = 0;
            }
            continue;
        }
        need = cmd == 'M' || cmd == 'L' ? 2 : cmd == 'Q' ? 4 : cmd == 'C' ? 6 : 0;
        if (!need) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The signature drawing could not be read.");
        for (i = 0; i < need; ++i) {
            while (*s == ' ' || *s == ',') ++s;
            v[i] = strtof(s, &end) * scale;
            if (end == s) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The signature drawing could not be read.");
            s = end;
        }
        if (cmd == 'M') fz_moveto(ctx, path, v[0], v[1]), cmd = 'L';
        else if (cmd == 'L') fz_lineto(ctx, path, v[0], v[1]);
        else if (cmd == 'Q') fz_quadto(ctx, path, v[0], v[1], v[2], v[3]);
        else fz_curveto(ctx, path, v[0], v[1], v[2], v[3], v[4], v[5]);
    }
}

void spdf_fill_fit_stamp_appearance(fz_context* ctx, pdf_annot* annot) {
    pdf_obj* ap;
    pdf_page* page;
    fz_rect box, rect, turned;
    fz_matrix m;
    float w, h;
    int rotate = 0;
    if (pdf_annot_type(ctx, annot) != PDF_ANNOT_STAMP) return;
    ap = pdf_dict_getp(ctx, pdf_annot_obj(ctx, annot), "AP/N");
    if (!pdf_is_stream(ctx, ap)) return;
    box = pdf_dict_get_rect(ctx, ap, PDF_NAME(BBox));
    rect = pdf_annot_rect(ctx, annot);
    if (!(box.x1 - box.x0 > 0.001f && box.y1 - box.y0 > 0.001f && rect.x1 > rect.x0 && rect.y1 > rect.y0)) return;
    /* On a page shown turned (/Rotate), the drawing turns too, to stand upright as the page is shown, as typed text
     * does. pdf_annot_rect gives the Rect as the page is shown, so its width and height are the drawing's. */
    page = pdf_annot_page(ctx, annot);
    if (page) rotate = pdf_dict_get_inheritable_int(ctx, page->obj, PDF_NAME(Rotate));
    rotate = ((rotate % 360) + 360) % 360 / 90 * 90;
    w = rect.x1 - rect.x0, h = rect.y1 - rect.y0;
    m = fz_concat(fz_translate(-box.x0, -box.y0), fz_scale(w / (box.x1 - box.x0), h / (box.y1 - box.y0)));
    m = fz_concat(m, fz_rotate((float)rotate));
    turned = fz_transform_rect(box, m);
    m = fz_concat(m, fz_translate(-turned.x0, -turned.y0));
    pdf_dict_put_matrix(ctx, ap, PDF_NAME(Matrix), m);
}

/* A Stamp keeps our drawing when moved: MuPDF only redraws stamps with a standard /Name. */
static pdf_annot* new_signature_annot(fz_context* ctx, pdf_page* page, spdf_rect rect) {
    pdf_annot* annot = pdf_create_annot(ctx, page, PDF_ANNOT_STAMP);
    pdf_set_annot_icon_name(ctx, annot, "Signature");
    pdf_dict_del(ctx, pdf_annot_obj(ctx, annot), PDF_NAME(C));
    pdf_set_annot_rect(ctx, annot, spdf_fill_to_fz(rect));
    return annot;
}

int spdf_fill_add_signature_paths(spdf_document* doc, int page_index, spdf_rect rect, float aspect,
                                  const char* const* paths, int path_count, const float rgb[3], const char* nm,
                                  char* err, size_t err_len) {
    const float unit = 100.0f; /* drawing units per signature height: precise numbers in the content stream */
    pdf_page* volatile page = NULL;
    pdf_annot* volatile annot = NULL;
    fz_display_list* volatile list = NULL;
    fz_device* volatile dev = NULL;
    fz_path* volatile path = NULL;
    if (!spdf_fill_check_args(doc, page_index, nm, err, err_len)) return 0;
    if (!paths || path_count <= 0 || !(aspect > 0.01f && aspect < 100.0f)) {
        spdf_fill_set_error(err, err_len, "The signature has no drawing.");
        return 0;
    }
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        float color[3] = {rgb ? rgb[0] : 0, rgb ? rgb[1] : 0, rgb ? rgb[2] : 0};
        int i;
        page = spdf_fill_load_page(doc, page_index);
        path = fz_new_path(ctx);
        for (i = 0; i < path_count; ++i)
            if (paths[i]) parse_outline(ctx, path, paths[i], unit);
        list = fz_new_display_list(ctx, fz_make_rect(0, 0, aspect * unit, unit));
        dev = fz_new_list_device(ctx, list);
        fz_fill_path(ctx, dev, path, 0, fz_identity, fz_device_rgb(ctx), color, 1.0f, fz_default_color_params);
        fz_close_device(ctx, dev);
        annot = new_signature_annot(ctx, page, rect);
        pdf_set_annot_appearance_from_display_list(ctx, annot, "N", NULL, fz_identity, list);
        spdf_fill_finish_item(ctx, annot, nm, NULL);
        spdf_fill_fit_stamp_appearance(ctx, annot);
    }
    fz_always(doc->ctx) {
        fz_drop_device(doc->ctx, dev);
        fz_drop_display_list(doc->ctx, list);
        fz_drop_path(doc->ctx, path);
        pdf_drop_annot(doc->ctx, annot);
        pdf_drop_page(doc->ctx, page);
    }
    fz_catch(doc->ctx) {
        spdf_fill_set_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_drop_page_list_cache(doc, page_index);
        return 0;
    }
    spdf_drop_page_list_cache(doc, page_index);
    return 1;
}

/* The picture an earlier placement of the same signature put in the document: "spdf-fill-sig-<id>-" prefix, found
 * from the page dictionaries alone (no page loads). */
static pdf_obj* find_signature_image(fz_context* ctx, pdf_document* pdf, const char* nm) {
    size_t lead = sizeof(SPDF_FILL_SIGNATURE_NM_PREFIX) - 1; /* the initials prefix has the same length */
    const char* dash;
    size_t prefix_len;
    int p, i, pages = pdf_count_pages(ctx, pdf);
    if (strncmp(nm, SPDF_FILL_SIGNATURE_NM_PREFIX, lead) != 0 && strncmp(nm, SPDF_FILL_INITIALS_NM_PREFIX, lead) != 0)
        return NULL;
    dash = strchr(nm + lead, '-');
    if (!dash) return NULL;
    prefix_len = (size_t)(dash - nm) + 1;
    for (p = 0; p < pages; ++p) {
        pdf_obj* annots = pdf_dict_get(ctx, pdf_lookup_page_obj(ctx, pdf, p), PDF_NAME(Annots));
        for (i = 0; i < pdf_array_len(ctx, annots); ++i) {
            pdf_obj* a = pdf_array_get(ctx, annots, i);
            pdf_obj* xobjects;
            int k;
            if (pdf_dict_get(ctx, a, PDF_NAME(Subtype)) != PDF_NAME(Stamp)) continue;
            if (strncmp(pdf_to_text_string(ctx, pdf_dict_gets(ctx, a, "NM")), nm, prefix_len) != 0) continue;
            xobjects = pdf_dict_getp(ctx, a, "AP/N/Resources/XObject");
            for (k = 0; k < pdf_dict_len(ctx, xobjects); ++k)
                if (pdf_is_image_stream(ctx, pdf_dict_get_val(ctx, xobjects, k))) return pdf_dict_get_val(ctx, xobjects, k);
        }
    }
    return NULL;
}

int spdf_fill_add_signature_png(spdf_document* doc, int page_index, spdf_rect rect, const unsigned char* png,
                                size_t png_len, const char* nm, char* err, size_t err_len) {
    pdf_page* volatile page = NULL;
    pdf_annot* volatile annot = NULL;
    fz_buffer* volatile buf = NULL;
    fz_image* volatile image = NULL;
    if (!spdf_fill_check_args(doc, page_index, nm, err, err_len)) return 0;
    if (!png || !png_len) {
        spdf_fill_set_error(err, err_len, "The signature has no picture.");
        return 0;
    }
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        pdf_obj* existing;
        page = spdf_fill_load_page(doc, page_index);
        existing = find_signature_image(ctx, page->doc, nm);
        annot = new_signature_annot(ctx, page, rect);
        if (existing) {
            pdf_set_annot_stamp_image_obj(ctx, annot, existing);
        } else {
            buf = fz_new_buffer_from_copied_data(ctx, png, png_len);
            image = fz_new_image_from_buffer(ctx, buf);
            pdf_set_annot_stamp_image(ctx, annot, image);
        }
        spdf_fill_finish_item(ctx, annot, nm, NULL);
        spdf_fill_fit_stamp_appearance(ctx, annot);
    }
    fz_always(doc->ctx) {
        fz_drop_image(doc->ctx, image);
        fz_drop_buffer(doc->ctx, buf);
        pdf_drop_annot(doc->ctx, annot);
        pdf_drop_page(doc->ctx, page);
    }
    fz_catch(doc->ctx) {
        spdf_fill_set_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_drop_page_list_cache(doc, page_index);
        return 0;
    }
    spdf_drop_page_list_cache(doc, page_index);
    return 1;
}

/* -- Save Final Copy -------------------------------------------------------------------------------------------- */

/* Takes every annotation that is neither a form field nor ours off the pages (kept in `held`, one array per page),
 * so baking draws only what was filled in; restore_comments puts them back afterwards. */
static pdf_obj* hold_comments(fz_context* ctx, pdf_document* pdf, int pages) {
    pdf_obj* held = pdf_new_array(ctx, pdf, pages);
    int p, i;
    fz_try(ctx) {
        for (p = 0; p < pages; ++p) {
            pdf_obj* annots = pdf_dict_get(ctx, pdf_lookup_page_obj(ctx, pdf, p), PDF_NAME(Annots));
            pdf_obj* keep = pdf_array_push_array(ctx, held, 4);
            for (i = 0; i < pdf_array_len(ctx, annots);) {
                pdf_obj* annot = pdf_array_get(ctx, annots, i);
                if (pdf_dict_get(ctx, annot, PDF_NAME(Subtype)) == PDF_NAME(Widget) ||
                    spdf_annot_obj_is_fill_item(ctx, annot)) {
                    ++i;
                    continue;
                }
                pdf_array_push(ctx, keep, annot);
                pdf_array_delete(ctx, annots, i);
            }
        }
    }
    fz_catch(ctx) {
        pdf_drop_obj(ctx, held);
        fz_rethrow(ctx);
    }
    return held;
}

static void restore_comments(fz_context* ctx, pdf_document* pdf, pdf_obj* held) {
    int p, i;
    for (p = 0; p < pdf_array_len(ctx, held); ++p) {
        pdf_obj* keep = pdf_array_get(ctx, held, p);
        pdf_obj* page = pdf_lookup_page_obj(ctx, pdf, p);
        pdf_obj* annots;
        if (pdf_array_len(ctx, keep) == 0) continue;
        annots = pdf_dict_get(ctx, page, PDF_NAME(Annots));
        if (!pdf_is_array(ctx, annots)) annots = pdf_dict_put_array(ctx, page, PDF_NAME(Annots), pdf_array_len(ctx, keep));
        for (i = 0; i < pdf_array_len(ctx, keep); ++i) pdf_array_push(ctx, annots, pdf_array_get(ctx, keep, i));
    }
}

int spdf_save_final_copy(const char* source, const char* password, const char* out_path, char* err, size_t err_len) {
    spdf_open_status status;
    spdf_document* doc;
    pdf_document* pdf;
    pdf_obj* volatile held = NULL;
    int ok = 1;

    spdf_fill_set_error(err, err_len, "");
    if (!source || !out_path || !*out_path || strcmp(source, out_path) == 0) {
        spdf_fill_set_error(err, err_len, "Choose a different name for the final copy.");
        return 0;
    }
    doc = spdf_open_with_password(source, password, &status, NULL, err, err_len);
    if (!doc) return 0;
    pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf) {
        spdf_fill_set_error(err, err_len, "Only PDF documents can be filled in.");
        spdf_close(doc);
        return 0;
    }
    fz_try(doc->ctx) {
        pdf_write_options options = pdf_default_write_options;
        int pages = pdf_count_pages(doc->ctx, pdf);
        held = hold_comments(doc->ctx, pdf, pages);
        pdf_bake_document(doc->ctx, pdf, 1, 1);
        restore_comments(doc->ctx, pdf, held);
        options.do_garbage = 3;
        options.do_compress = 1;
        options.do_compress_images = 1;
        options.do_compress_fonts = 1;
        pdf_save_document(doc->ctx, pdf, out_path, &options);
    }
    fz_always(doc->ctx) pdf_drop_obj(doc->ctx, held);
    fz_catch(doc->ctx) {
        spdf_fill_set_error(err, err_len, fz_caught_message(doc->ctx));
        remove(out_path);
        ok = 0;
    }
    spdf_close(doc);
    return ok;
}
