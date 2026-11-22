/* spdf_fill_ink.c -- pen lines, arrows, and changes to several placed items at once (spdf_fill_ink.h). */
#include "spdf_fill_ink.h"
#include "spdf_core_document.h"
#include "spdf_fill_ink_geometry.h"
#include "spdf_fill_internal.h"

#include "mupdf/pdf.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static const char* annot_name(fz_context* ctx, pdf_annot* annot) {
    return pdf_to_text_string(ctx, pdf_dict_gets(ctx, pdf_annot_obj(ctx, annot), "NM"));
}

static int has_prefix(const char* s, const char* prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

/* name is one of nms, or a comb cell (<nm>-cNN) of one of them. */
static int name_listed(const char* name, const char* const* nms, int count) {
    int i;
    for (i = 0; i < count; ++i) {
        size_t n;
        const char* rest;
        if (!nms[i] || !*nms[i]) continue;
        n = strlen(nms[i]);
        if (strncmp(name, nms[i], n) != 0) continue;
        rest = name + n;
        if (!*rest) return 1;
        if (rest[0] == '-' && rest[1] == 'c' && rest[2] >= '0' && rest[2] <= '9') {
            const char* d = rest + 2;
            while (*d >= '0' && *d <= '9') ++d;
            if (!*d) return 1;
        }
    }
    return 0;
}

static int drawing_name(const char* name) {
    return has_prefix(name, SPDF_FILL_PEN_NM_PREFIX) || has_prefix(name, SPDF_FILL_ARROW_NM_PREFIX);
}

/* The strokes of a pen line (one polyline) or an arrow (shaft, then head). */
static void set_strokes(fz_context* ctx, pdf_annot* annot, int arrow, const spdf_fill_point* points, int count,
                        float width) {
    if (arrow) {
        spdf_fill_point head[3];
        fz_point v[5];
        int counts[2] = {2, 3}, i;
        spdf_ink_arrow_head(points[0], points[1], width, head);
        v[0] = fz_make_point(points[0].x, points[0].y);
        v[1] = fz_make_point(points[1].x, points[1].y);
        for (i = 0; i < 3; ++i) v[2 + i] = fz_make_point(head[i].x, head[i].y);
        pdf_set_annot_ink_list(ctx, annot, 2, counts, v);
    } else {
        fz_point* v = (fz_point*)fz_malloc(ctx, sizeof(fz_point) * (size_t)count);
        int i;
        for (i = 0; i < count; ++i) v[i] = fz_make_point(points[i].x, points[i].y);
        fz_try(ctx) pdf_set_annot_ink_list(ctx, annot, 1, &count, v);
        fz_always(ctx) fz_free(ctx, v);
        fz_catch(ctx) fz_rethrow(ctx);
    }
}

static void set_style(fz_context* ctx, pdf_annot* annot, const float rgb[3], float width) {
    float color[3];
    int i;
    for (i = 0; i < 3; ++i) color[i] = fminf(fmaxf(rgb[i], 0.0f), 1.0f);
    pdf_set_annot_color(ctx, annot, 3, color);
    pdf_set_annot_border_width(ctx, annot, fminf(fmaxf(width, 0.25f), 48.0f));
}

/* An arrow's tail and tip (its first stroke), or 0 when it has none. */
static int arrow_ends(fz_context* ctx, pdf_annot* annot, spdf_fill_point ends[2]) {
    int i;
    if (pdf_annot_ink_list_count(ctx, annot) < 1 || pdf_annot_ink_list_stroke_count(ctx, annot, 0) < 2) return 0;
    for (i = 0; i < 2; ++i) {
        fz_point p = pdf_annot_ink_list_stroke_vertex(ctx, annot, 0, i);
        ends[i].x = p.x, ends[i].y = p.y;
    }
    return 1;
}

/* -- one page at a time ------------------------------------------------------------------------------------------- */

typedef struct edit_args {
    const spdf_fill_stroke* strokes;
    const char* const* nms;
    int count;
    float dx, dy, width;
    const float* rgb;
    spdf_fill_point tail, tip;
} edit_args;

typedef void (*page_edit)(fz_context* ctx, pdf_page* page, const edit_args* args);

static int edit_page(spdf_document* doc, int page_index, page_edit edit, const edit_args* args, char* err,
                     size_t err_len) {
    pdf_page* volatile page = NULL;
    spdf_fill_set_error(err, err_len, "");
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        spdf_fill_set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    fz_try(doc->ctx) {
        page = spdf_fill_load_page(doc, page_index);
        edit(doc->ctx, page, args);
    }
    fz_always(doc->ctx) pdf_drop_page(doc->ctx, page);
    fz_catch(doc->ctx) {
        spdf_fill_set_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_drop_page_list_cache(doc, page_index);
        return 0;
    }
    spdf_drop_page_list_cache(doc, page_index);
    return 1;
}

static void add_strokes(fz_context* ctx, pdf_page* page, const edit_args* args) {
    pdf_annot* volatile annot = NULL;
    int i;
    for (i = 0; i < args->count; ++i) {
        const spdf_fill_stroke* s = &args->strokes[i];
        int arrow = s->kind == SPDF_FILL_ARROW;
        const char* prefix = arrow ? SPDF_FILL_ARROW_NM_PREFIX : SPDF_FILL_PEN_NM_PREFIX;
        if (!s->nm || !has_prefix(s->nm, prefix) || (s->kind != SPDF_FILL_PEN && !arrow))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Pen lines need a name starting with " SPDF_FILL_PEN_NM_PREFIX ".");
        if (!s->points || s->point_count < (arrow ? 2 : 1))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This line has no points.");
        fz_try(ctx) {
            annot = pdf_create_annot(ctx, page, PDF_ANNOT_INK);
            set_style(ctx, annot, s->rgb, s->width);
            set_strokes(ctx, annot, arrow, s->points, arrow ? 2 : s->point_count, s->width);
            spdf_fill_finish_item(ctx, annot, s->nm, NULL);
        }
        fz_always(ctx) {
            pdf_drop_annot(ctx, annot);
            annot = NULL;
        }
        fz_catch(ctx) fz_rethrow(ctx);
    }
}

static void delete_items(fz_context* ctx, pdf_page* page, const edit_args* args) {
    pdf_annot* annot = pdf_first_annot(ctx, page);
    while (annot) {
        pdf_annot* next = pdf_next_annot(ctx, annot);
        const char* name = annot_name(ctx, annot);
        if (has_prefix(name, SPDF_FILL_NM_PREFIX) && name_listed(name, args->nms, args->count))
            pdf_delete_annot(ctx, page, annot);
        annot = next;
    }
}

static void move_ink(fz_context* ctx, pdf_annot* annot, float dx, float dy) {
    int strokes = pdf_annot_ink_list_count(ctx, annot), total = 0, i, k, n = 0;
    int* counts;
    fz_point* v;
    if (strokes <= 0) return;
    for (i = 0; i < strokes; ++i) total += pdf_annot_ink_list_stroke_count(ctx, annot, i);
    counts = (int*)fz_malloc(ctx, sizeof(int) * (size_t)strokes);
    v = (fz_point*)fz_malloc_no_throw(ctx, sizeof(fz_point) * (size_t)(total > 0 ? total : 1));
    if (!v) {
        fz_free(ctx, counts);
        fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    }
    for (i = 0; i < strokes; ++i) {
        counts[i] = pdf_annot_ink_list_stroke_count(ctx, annot, i);
        for (k = 0; k < counts[i]; ++k) {
            fz_point p = pdf_annot_ink_list_stroke_vertex(ctx, annot, i, k);
            v[n++] = fz_make_point(p.x + dx, p.y + dy);
        }
    }
    fz_try(ctx) pdf_set_annot_ink_list(ctx, annot, strokes, counts, v);
    fz_always(ctx) {
        fz_free(ctx, counts);
        fz_free(ctx, v);
    }
    fz_catch(ctx) fz_rethrow(ctx);
}

static void move_items(fz_context* ctx, pdf_page* page, const edit_args* args) {
    pdf_annot* annot;
    for (annot = pdf_first_annot(ctx, page); annot; annot = pdf_next_annot(ctx, annot)) {
        const char* name = annot_name(ctx, annot);
        if (!has_prefix(name, SPDF_FILL_NM_PREFIX) || !name_listed(name, args->nms, args->count)) continue;
        if (pdf_annot_type(ctx, annot) == PDF_ANNOT_INK) {
            move_ink(ctx, annot, args->dx, args->dy);
        } else {
            fz_rect r = pdf_annot_rect(ctx, annot);
            r.x0 += args->dx, r.x1 += args->dx, r.y0 += args->dy, r.y1 += args->dy;
            pdf_set_annot_rect(ctx, annot, r); /* a Stamp keeps its drawing (spdf_fill_items.h) */
        }
        pdf_update_annot(ctx, annot);
    }
}

static void restyle(fz_context* ctx, pdf_page* page, const edit_args* args) {
    pdf_annot* annot;
    for (annot = pdf_first_annot(ctx, page); annot; annot = pdf_next_annot(ctx, annot)) {
        const char* name = annot_name(ctx, annot);
        spdf_fill_point ends[2];
        if (!drawing_name(name) || !name_listed(name, args->nms, args->count)) continue;
        if (pdf_annot_type(ctx, annot) != PDF_ANNOT_INK) continue;
        set_style(ctx, annot, args->rgb, args->width);
        /* The head's size follows the width. */
        if (has_prefix(name, SPDF_FILL_ARROW_NM_PREFIX) && arrow_ends(ctx, annot, ends))
            set_strokes(ctx, annot, 1, ends, 2, args->width);
        pdf_update_annot(ctx, annot);
    }
}

static void set_ends(fz_context* ctx, pdf_page* page, const edit_args* args) {
    pdf_annot* annot;
    for (annot = pdf_first_annot(ctx, page); annot; annot = pdf_next_annot(ctx, annot)) {
        spdf_fill_point ends[2];
        if (strcmp(annot_name(ctx, annot), args->nms[0]) != 0) continue;
        ends[0] = args->tail, ends[1] = args->tip;
        set_strokes(ctx, annot, 1, ends, 2, pdf_annot_border_width(ctx, annot));
        pdf_update_annot(ctx, annot);
        return;
    }
    fz_throw(ctx, FZ_ERROR_ARGUMENT, "This item is no longer on the page.");
}

/* -- the calls ---------------------------------------------------------------------------------------------------- */

int spdf_fill_add_strokes(spdf_document* doc, int page_index, const spdf_fill_stroke* strokes, int count, char* err,
                          size_t err_len) {
    edit_args args;
    memset(&args, 0, sizeof(args));
    args.strokes = strokes, args.count = strokes ? count : 0;
    return edit_page(doc, page_index, add_strokes, &args, err, err_len);
}

int spdf_fill_delete_items(spdf_document* doc, int page_index, const char* const* nms, int count, char* err,
                           size_t err_len) {
    edit_args args;
    memset(&args, 0, sizeof(args));
    args.nms = nms, args.count = nms ? count : 0;
    return edit_page(doc, page_index, delete_items, &args, err, err_len);
}

int spdf_fill_move_items(spdf_document* doc, int page_index, const char* const* nms, int count, float dx, float dy,
                         char* err, size_t err_len) {
    edit_args args;
    memset(&args, 0, sizeof(args));
    args.nms = nms, args.count = nms ? count : 0, args.dx = dx, args.dy = dy;
    return edit_page(doc, page_index, move_items, &args, err, err_len);
}

int spdf_fill_restyle_strokes(spdf_document* doc, int page_index, const char* const* nms, int count, const float rgb[3],
                              float width, char* err, size_t err_len) {
    edit_args args;
    memset(&args, 0, sizeof(args));
    args.nms = nms, args.count = nms ? count : 0, args.rgb = rgb, args.width = width;
    if (!rgb) {
        spdf_fill_set_error(err, err_len, "No colour was given.");
        return 0;
    }
    return edit_page(doc, page_index, restyle, &args, err, err_len);
}

int spdf_fill_set_arrow_ends(spdf_document* doc, int page_index, const char* nm, spdf_fill_point tail,
                             spdf_fill_point tip, char* err, size_t err_len) {
    edit_args args;
    memset(&args, 0, sizeof(args));
    if (!spdf_fill_check_args(doc, page_index, nm, err, err_len)) return 0;
    if (!has_prefix(nm, SPDF_FILL_ARROW_NM_PREFIX)) {
        spdf_fill_set_error(err, err_len, "This item isn't an arrow.");
        return 0;
    }
    args.nms = &nm, args.count = 1, args.tail = tail, args.tip = tip;
    return edit_page(doc, page_index, set_ends, &args, err, err_len);
}

int spdf_fill_pages_with_items(spdf_document* doc, const char* prefix, int* pages, int max, char* err, size_t err_len) {
    pdf_document* pdf;
    volatile int found = 0;
    spdf_fill_set_error(err, err_len, "");
    if (!doc || !prefix) {
        spdf_fill_set_error(err, err_len, "No document.");
        return -1;
    }
    pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf) return 0;
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        int i, k;
        for (i = 0; i < doc->page_count; ++i) {
            pdf_obj* annots = pdf_dict_get(ctx, pdf_lookup_page_obj(ctx, pdf, i), PDF_NAME(Annots));
            int n = pdf_array_len(ctx, annots);
            for (k = 0; k < n; ++k) {
                pdf_obj* annot = pdf_array_get(ctx, annots, k);
                if (!has_prefix(pdf_to_text_string(ctx, pdf_dict_gets(ctx, annot, "NM")), prefix)) continue;
                if (pages && found < max) pages[found] = i;
                found = found + 1;
                break;
            }
        }
    }
    fz_catch(doc->ctx) {
        spdf_fill_set_error(err, err_len, fz_caught_message(doc->ctx));
        return -1;
    }
    return found;
}
