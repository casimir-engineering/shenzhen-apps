/* The pictures of our annotations on a PDF page canvas, decoded whole and kept for the reader (spdf_paint_written.h).
 *
 * MuPDF keeps the pictures it decodes in its store, by picture and by part. When the reader draws a part of the page
 * that needs less than 90 % of a picture, it decodes that part only and scales it from the part's own edges, which
 * gives other pixels than the whole picture scaled; but it first looks for the whole picture in the store and, when it
 * is there, draws from it. So each picture our annotations show is decoded whole here, after each write back and
 * when a stroke starts, and held (a held entry stays in the store): the reader then draws them as the preview draws
 * them, whatever part of the page it draws again. The page canvas lets them go when it closes. */
#include "spdf_paint_pdf_internal.h"
#include "spdf_paint_written.h"

#include "spdf_core_document.h"

#include <stdlib.h>
#include <string.h>

typedef struct warm_list {
    fz_image** images;
    fz_pixmap** tiles; /* the whole pictures, decoded (two per image: its colours, its mask) */
    int count, cap;
} warm_list;

static void hold(fz_context* ctx, warm_list* list, fz_image* image) {
    if (!image) return;
    for (int i = 0; i < list->count; i++)
        if (list->images[i] == image) return;
    if (list->count == list->cap) {
        int cap = list->cap ? list->cap * 2 : 8;
        fz_image** images = realloc(list->images, (size_t)cap * sizeof(*images));
        if (images) list->images = images;
        fz_pixmap** tiles = images ? realloc(list->tiles, (size_t)cap * sizeof(*tiles)) : NULL;
        if (tiles) list->tiles = tiles;
        if (!images || !tiles) return;
        list->cap = cap;
    }
    fz_pixmap* tile = NULL;
    fz_try(ctx) tile = fz_get_pixmap_from_image(ctx, image, NULL, NULL, NULL, NULL);
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        return;
    }
    list->images[list->count] = fz_keep_image(ctx, image);
    list->tiles[list->count++] = tile;
}

static void drop_list(fz_context* ctx, warm_list* list) {
    if (!list) return;
    for (int i = 0; i < list->count; i++) {
        fz_drop_pixmap(ctx, list->tiles[i]);
        fz_drop_image(ctx, list->images[i]);
    }
    free(list->images);
    free(list->tiles);
    free(list);
}

/* The pictures one appearance draws (its own XObjects, one level of forms down). */
static void hold_appearance(fz_context* ctx, pdf_document* pdf, pdf_obj* form, warm_list* list, int depth) {
    pdf_obj* xobjects = pdf_dict_getp(ctx, form, "Resources/XObject");
    int n = pdf_dict_len(ctx, xobjects);
    for (int i = 0; i < n; i++) {
        pdf_obj* x = pdf_dict_get_val(ctx, xobjects, i);
        if (pdf_name_eq(ctx, pdf_dict_get(ctx, x, PDF_NAME(Subtype)), PDF_NAME(Form)) && depth < 1) {
            hold_appearance(ctx, pdf, x, list, depth + 1);
        } else if (pdf_is_image_stream(ctx, x)) {
            fz_image* image = NULL;
            fz_try(ctx) image = pdf_load_image(ctx, pdf, x);
            fz_catch(ctx) fz_ignore_error(ctx);
            if (!image) continue;
            hold(ctx, list, image);
            hold(ctx, list, image->mask);
            fz_drop_image(ctx, image);
        }
    }
}

void spdf_paint_pdf_warm(spdf_paint_doc* doc) {
    spdf_paint_pdf_state* st = doc ? spdf_paint_pdf_state_of(doc) : NULL;
    if (!st || !doc->pdf || !doc->ctx) return;
    fz_context* ctx = doc->ctx;
    warm_list* list = calloc(1, sizeof(*list));
    pdf_page* page = NULL;
    fz_var(page);
    if (!list) return;
    fz_try(ctx) {
        pdf_document* pdf = pdf_specifics(ctx, doc->pdf->doc);
        page = spdf_paint_pdf_load_page(doc);
        for (pdf_annot* a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a)) {
            pdf_obj* obj = pdf_annot_obj(ctx, a);
            if (!spdf_paint_pdf_has_prefix(spdf_paint_pdf_nm(ctx, obj), SPDF_PAINT_NM_PREFIX)) continue;
            pdf_obj* ap = pdf_dict_getp(ctx, obj, "AP/N");
            if (pdf_is_stream(ctx, ap)) hold_appearance(ctx, pdf, ap, list, 0);
        }
    }
    fz_always(ctx) pdf_drop_page(ctx, page);
    fz_catch(ctx) fz_ignore_error(ctx);
    drop_list(ctx, st->warm); /* after: a picture held before and still shown is never let go in between */
    st->warm = list;
}

void spdf_paint_pdf_warm_drop(spdf_paint_doc* doc) {
    spdf_paint_pdf_state* st = doc ? spdf_paint_pdf_state_of(doc) : NULL;
    if (!st) return;
    drop_list(doc->ctx, st->warm);
    st->warm = NULL;
}
