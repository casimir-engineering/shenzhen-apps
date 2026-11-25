/* spdf_fill_items.c -- text, marks and signatures placed by Fill & Sign (spdf_fill_items.h). */
#include "spdf_fill_items.h"
#include "spdf_core_document.h"
#include "spdf_fill_identity.h"
#include "spdf_fill_ink_geometry.h"
#include "spdf_fill_internal.h"

#include "mupdf/pdf.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { ANNOT_FLAG_PRINT = 1 << 2 };

/* write_variable_text in MuPDF's FreeText appearance: first baseline 0.8 x size under the top, 1.2 x size leading. */
#define FILL_TEXT_ASCENT 0.8f
#define FILL_TEXT_LEADING 1.2f

void spdf_fill_set_error(char* err, size_t err_len, const char* message) {
    if (err && err_len) snprintf(err, err_len, "%s", message ? message : "");
}

spdf_rect spdf_fill_text_rect(float x, float baseline, float width, float size, int lines) {
    spdf_rect r;
    if (lines < 1) lines = 1;
    r.x0 = x;
    r.x1 = x + (width > size ? width : size);
    r.y0 = baseline - FILL_TEXT_ASCENT * size;
    r.y1 = r.y0 + FILL_TEXT_LEADING * size * (float)lines;
    return r;
}

float spdf_fill_text_baseline(spdf_rect rect, float size) {
    return rect.y0 + FILL_TEXT_ASCENT * size;
}

fz_rect spdf_fill_to_fz(spdf_rect r) {
    return fz_make_rect(fminf(r.x0, r.x1), fminf(r.y0, r.y1), fmaxf(r.x0, r.x1), fmaxf(r.y0, r.y1));
}

static spdf_rect from_fz(fz_rect r) {
    spdf_rect out;
    out.x0 = r.x0, out.y0 = r.y0, out.x1 = r.x1, out.y1 = r.y1;
    return out;
}

static const char* annot_nm(fz_context* ctx, pdf_annot* annot) {
    return pdf_to_text_string(ctx, pdf_dict_gets(ctx, pdf_annot_obj(ctx, annot), "NM"));
}

/* Our name, the Print flag and, for text, the author: what every placed item carries. */
void spdf_fill_finish_item(fz_context* ctx, pdf_annot* annot, const char* nm, const char* author) {
    pdf_obj* obj = pdf_annot_obj(ctx, annot);
    pdf_dict_puts_drop(ctx, obj, "NM", pdf_new_text_string(ctx, nm));
    pdf_set_annot_flags(ctx, annot, ANNOT_FLAG_PRINT);
    if (author && *author) pdf_set_annot_author(ctx, annot, author);
    pdf_update_annot(ctx, annot);
}

pdf_page* spdf_fill_load_page(spdf_document* doc, int page_index) {
    pdf_document* pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only PDF documents can be filled in.");
    if (!spdf_owner_allows(doc, FZ_PERMISSION_ANNOTATE))
        fz_throw(doc->ctx, FZ_ERROR_ARGUMENT, "This PDF's owner doesn't allow filling it in.");
    return pdf_load_page(doc->ctx, pdf, page_index);
}

int spdf_fill_check_args(spdf_document* doc, int page_index, const char* nm, char* err, size_t err_len) {
    spdf_fill_set_error(err, err_len, "");
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        spdf_fill_set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    if (!nm || strncmp(nm, SPDF_FILL_NM_PREFIX, sizeof(SPDF_FILL_NM_PREFIX) - 1) != 0) {
        spdf_fill_set_error(err, err_len, "Fill items need a name starting with " SPDF_FILL_NM_PREFIX ".");
        return 0;
    }
    return 1;
}

static void set_text_props(fz_context* ctx, pdf_annot* annot, const char* utf8, float size) {
    const float black[1] = {0};
    if (utf8) {
        pdf_set_annot_contents(ctx, annot, utf8);
        if (spdf_text_contains_han(utf8)) pdf_set_annot_language(ctx, annot, FZ_LANG_zh_Hans);
        else pdf_set_annot_language(ctx, annot, FZ_LANG_UNSET);
    }
    if (size > 0) pdf_set_annot_default_appearance(ctx, annot, "Helv", fminf(fmaxf(size, 4.0f), 144.0f), 1, black);
}

static pdf_annot* new_text_annot(fz_context* ctx, pdf_page* page, spdf_rect rect, float size, const char* utf8) {
    pdf_annot* annot = pdf_create_annot(ctx, page, PDF_ANNOT_FREE_TEXT); /* page /Rotate, no border, Helv */
    pdf_set_annot_intent(ctx, annot, PDF_ANNOT_IT_FREETEXT_TYPEWRITER);
    pdf_set_annot_border_width(ctx, annot, 0);
    pdf_set_annot_rect(ctx, annot, spdf_fill_to_fz(rect));
    set_text_props(ctx, annot, utf8, size > 0 ? size : 11.0f);
    return annot;
}

int spdf_fill_add_text(spdf_document* doc, int page_index, spdf_rect rect, float size, const char* utf8, const char* nm,
                       const char* author, char* err, size_t err_len) {
    pdf_page* volatile page = NULL;
    pdf_annot* volatile annot = NULL;
    if (!spdf_fill_check_args(doc, page_index, nm, err, err_len)) return 0;
    fz_try(doc->ctx) {
        page = spdf_fill_load_page(doc, page_index);
        annot = new_text_annot(doc->ctx, page, rect, size, utf8 ? utf8 : "");
        spdf_fill_finish_item(doc->ctx, annot, nm, author);
    }
    fz_always(doc->ctx) {
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

int spdf_fill_add_comb_text(spdf_document* doc, int page_index, const spdf_rect* cells, int cell_count, float size,
                            const char* utf8, const char* group_nm, const char* author, char* err, size_t err_len) {
    pdf_page* volatile page = NULL;
    pdf_annot* volatile annot = NULL;
    if (!spdf_fill_check_args(doc, page_index, group_nm, err, err_len)) return 0;
    if (!cells || cell_count <= 0 || cell_count > 99 || !utf8) {
        spdf_fill_set_error(err, err_len, "No character boxes were supplied.");
        return 0;
    }
    fz_try(doc->ctx) {
        const char* s = utf8;
        int cell = 0;
        page = spdf_fill_load_page(doc, page_index);
        while (*s && cell < cell_count) {
            char one[8], nm[256];
            int rune, len = fz_chartorune(&rune, s);
            spdf_rect box = cells[cell];
            float baseline = (box.y0 + box.y1) * 0.5f + 0.35f * size;
            memcpy(one, s, (size_t)len);
            one[len] = 0;
            s += len;
            if (rune == ' ') {
                ++cell;
                continue;
            }
            snprintf(nm, sizeof nm, "%s-c%02d", group_nm, cell);
            annot = new_text_annot(doc->ctx, page, spdf_fill_text_rect(box.x0, baseline, box.x1 - box.x0, size, 1),
                                   size, one);
            pdf_set_annot_quadding(doc->ctx, annot, 1); /* centred in its cell */
            spdf_fill_finish_item(doc->ctx, annot, nm, author);
            pdf_drop_annot(doc->ctx, annot);
            annot = NULL;
            ++cell;
        }
    }
    fz_always(doc->ctx) {
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

/* -- marks ------------------------------------------------------------------------------------------------------ */

/* Fractions of the square: a check is one stroke, a cross two diagonals inset 20%. */
static const float check_shape[3][2] = {{0.15f, 0.55f}, {0.40f, 0.80f}, {0.85f, 0.20f}};
#define CROSS_INSET 0.2f

static void draw_mark(fz_context* ctx, pdf_annot* annot, fz_rect box, int cross) {
    const float black[3] = {0, 0, 0};
    float w = box.x1 - box.x0, h = box.y1 - box.y0;
    fz_point v[4];
    int counts[2];
    int i;
    if (cross) {
        float i0 = CROSS_INSET, i1 = 1.0f - CROSS_INSET;
        v[0] = fz_make_point(box.x0 + i0 * w, box.y0 + i0 * h), v[1] = fz_make_point(box.x0 + i1 * w, box.y0 + i1 * h);
        v[2] = fz_make_point(box.x0 + i1 * w, box.y0 + i0 * h), v[3] = fz_make_point(box.x0 + i0 * w, box.y0 + i1 * h);
        counts[0] = counts[1] = 2;
        pdf_set_annot_ink_list(ctx, annot, 2, counts, v);
    } else {
        for (i = 0; i < 3; ++i) v[i] = fz_make_point(box.x0 + check_shape[i][0] * w, box.y0 + check_shape[i][1] * h);
        counts[0] = 3;
        pdf_set_annot_ink_list(ctx, annot, 1, counts, v);
    }
    pdf_set_annot_border_width(ctx, annot, fmaxf(1.0f, 0.1f * fminf(w, h)));
    pdf_set_annot_color(ctx, annot, 3, black);
}

/* The square a mark was drawn in, from its strokes (page space), and whether it is a cross. */
static fz_rect mark_box(fz_context* ctx, pdf_annot* annot, int* cross) {
    fz_rect r = fz_empty_rect;
    int i, k, n = pdf_annot_ink_list_count(ctx, annot);
    for (i = 0; i < n; ++i)
        for (k = 0; k < pdf_annot_ink_list_stroke_count(ctx, annot, i); ++k)
            r = fz_include_point_in_rect(r, pdf_annot_ink_list_stroke_vertex(ctx, annot, i, k));
    *cross = n >= 2;
    if (r.x0 > r.x1 || r.y0 > r.y1) return fz_empty_rect; /* no strokes */
    if (*cross) {
        float w = (r.x1 - r.x0) / (1.0f - 2 * CROSS_INSET), h = (r.y1 - r.y0) / (1.0f - 2 * CROSS_INSET);
        return fz_make_rect(r.x0 - CROSS_INSET * w, r.y0 - CROSS_INSET * h, r.x0 - CROSS_INSET * w + w,
                            r.y0 - CROSS_INSET * h + h);
    } else {
        float w = (r.x1 - r.x0) / (check_shape[2][0] - check_shape[0][0]);
        float h = (r.y1 - r.y0) / (check_shape[1][1] - check_shape[2][1]);
        float x0 = r.x0 - check_shape[0][0] * w, y0 = r.y0 - check_shape[2][1] * h;
        return fz_make_rect(x0, y0, x0 + w, y0 + h);
    }
}

int spdf_fill_add_mark(spdf_document* doc, int page_index, spdf_rect box, int cross, const char* nm, char* err,
                       size_t err_len) {
    pdf_page* volatile page = NULL;
    pdf_annot* volatile annot = NULL;
    if (!spdf_fill_check_args(doc, page_index, nm, err, err_len)) return 0;
    fz_try(doc->ctx) {
        page = spdf_fill_load_page(doc, page_index);
        annot = pdf_create_annot(doc->ctx, page, PDF_ANNOT_INK);
        draw_mark(doc->ctx, annot, spdf_fill_to_fz(box), cross);
        spdf_fill_finish_item(doc->ctx, annot, nm, NULL);
    }
    fz_always(doc->ctx) {
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

/* -- changing, removing and listing ----------------------------------------------------------------------------- */

static pdf_annot* find_item(fz_context* ctx, pdf_page* page, const char* nm) {
    pdf_annot* annot;
    for (annot = pdf_first_annot(ctx, page); annot; annot = pdf_next_annot(ctx, annot))
        if (strcmp(annot_nm(ctx, annot), nm) == 0) return annot;
    fz_throw(ctx, FZ_ERROR_ARGUMENT, "This item is no longer on the page.");
    return NULL;
}

/* Length of the group part when nm ends in "-cNN" (a comb cell), else 0. */
static size_t comb_group_length(const char* nm, int* cell) {
    size_t len = strlen(nm), digits = 0;
    while (digits < len && nm[len - 1 - digits] >= '0' && nm[len - 1 - digits] <= '9') ++digits;
    if (digits < 2 || len < digits + 2 || nm[len - digits - 1] != 'c' || nm[len - digits - 2] != '-') return 0;
    if (cell) *cell = atoi(nm + len - digits);
    return len - digits - 2;
}

/* SPDF_FILL_PEN or SPDF_FILL_ARROW for a pen line's or arrow's name, else -1. */
static int drawing_kind(const char* nm) {
    if (strncmp(nm, SPDF_FILL_PEN_NM_PREFIX, sizeof(SPDF_FILL_PEN_NM_PREFIX) - 1) == 0) return SPDF_FILL_PEN;
    if (strncmp(nm, SPDF_FILL_ARROW_NM_PREFIX, sizeof(SPDF_FILL_ARROW_NM_PREFIX) - 1) == 0) return SPDF_FILL_ARROW;
    return -1;
}

typedef enum { EDIT_UPDATE, EDIT_MARK_KIND, EDIT_DELETE } fill_edit;

static int edit_item(spdf_document* doc, int page_index, const char* nm, fill_edit what, const spdf_rect* rect,
                     float size, const char* utf8, int cross, char* err, size_t err_len) {
    pdf_page* volatile page = NULL;
    if (!spdf_fill_check_args(doc, page_index, nm, err, err_len)) return 0;
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        pdf_annot* annot;
        page = spdf_fill_load_page(doc, page_index);
        if (what == EDIT_DELETE) {
            size_t n = strlen(nm);
            int found = 0;
            annot = pdf_first_annot(ctx, page);
            while (annot) {
                pdf_annot* next = pdf_next_annot(ctx, annot);
                const char* name = annot_nm(ctx, annot);
                if (strcmp(name, nm) == 0 || (comb_group_length(name, NULL) == n && strncmp(name, nm, n) == 0)) {
                    pdf_delete_annot(ctx, page, annot);
                    found = 1;
                }
                annot = next;
            }
            if (!found) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This item is no longer on the page.");
        } else {
            enum pdf_annot_type type;
            annot = find_item(ctx, page, nm);
            type = pdf_annot_type(ctx, annot);
            if (drawing_kind(nm) >= 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Pen lines and arrows move as a group.");
            if (what == EDIT_MARK_KIND || (type == PDF_ANNOT_INK && rect)) {
                int was_cross;
                fz_rect box = mark_box(ctx, annot, &was_cross);
                if (type != PDF_ANNOT_INK) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This item isn't a check or cross.");
                draw_mark(ctx, annot, rect ? spdf_fill_to_fz(*rect) : box, what == EDIT_MARK_KIND ? cross : was_cross);
            } else if (type == PDF_ANNOT_FREE_TEXT && utf8 && !*utf8) {
                pdf_delete_annot(ctx, page, annot);
                annot = NULL;
            } else {
                if (type == PDF_ANNOT_FREE_TEXT) set_text_props(ctx, annot, utf8, size);
                if (rect) pdf_set_annot_rect(ctx, annot, spdf_fill_to_fz(*rect)); /* a Stamp keeps its drawing */
            }
            if (annot) pdf_update_annot(ctx, annot);
            if (annot && rect) spdf_fill_fit_stamp_appearance(ctx, annot);
        }
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

int spdf_fill_update(spdf_document* doc, int page_index, const char* nm, const spdf_rect* rect_or_null, float size,
                     const char* utf8_or_null, char* err, size_t err_len) {
    return edit_item(doc, page_index, nm, EDIT_UPDATE, rect_or_null, size, utf8_or_null, 0, err, err_len);
}

int spdf_fill_set_mark_kind(spdf_document* doc, int page_index, const char* nm, int cross, char* err, size_t err_len) {
    return edit_item(doc, page_index, nm, EDIT_MARK_KIND, NULL, 0, NULL, cross, err, err_len);
}

int spdf_fill_delete(spdf_document* doc, int page_index, const char* nm_or_group, char* err, size_t err_len) {
    return edit_item(doc, page_index, nm_or_group, EDIT_DELETE, NULL, 0, NULL, 0, err, err_len);
}

static char* dup_text(fz_context* ctx, const char* text) {
    size_t len = strlen(text ? text : "");
    char* copy = (char*)malloc(len + 1);
    if (!copy) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    memcpy(copy, text ? text : "", len + 1);
    return copy;
}

/* A pen line's points (its first stroke) or an arrow's tail and tip (its shaft), colour and width. */
static void read_drawing(fz_context* ctx, pdf_annot* annot, spdf_fill_kind kind, spdf_fill_item* item) {
    float color[4] = {0, 0, 0, 0}, half;
    int i, n = 0, count = pdf_annot_ink_list_count(ctx, annot) > 0 ? pdf_annot_ink_list_stroke_count(ctx, annot, 0) : 0;
    item->kind = kind;
    if (kind == SPDF_FILL_ARROW && count > 2) count = 2;
    item->points = (spdf_fill_point*)calloc((size_t)(count > 0 ? count : 1), sizeof(spdf_fill_point));
    if (!item->points) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    for (i = 0; i < count; ++i) {
        fz_point p = pdf_annot_ink_list_stroke_vertex(ctx, annot, 0, i);
        item->points[i].x = p.x, item->points[i].y = p.y;
    }
    item->point_count = count;
    pdf_annot_color(ctx, annot, &n, color);
    for (i = 0; i < 3; ++i) item->rgb[i] = n == 3 ? color[i] : n == 1 ? color[0] : 0;
    item->width = pdf_annot_border_width(ctx, annot);
    half = 0.5f * item->width;
    item->rect = spdf_ink_bounds(item->points, count, half);
    if (kind == SPDF_FILL_ARROW && count == 2) {
        spdf_fill_point head[3];
        spdf_rect r;
        spdf_ink_arrow_head(item->points[0], item->points[1], item->width, head);
        r = spdf_ink_bounds(head, 3, half);
        item->rect.x0 = fminf(item->rect.x0, r.x0), item->rect.y0 = fminf(item->rect.y0, r.y0);
        item->rect.x1 = fmaxf(item->rect.x1, r.x1), item->rect.y1 = fmaxf(item->rect.y1, r.y1);
    }
}

static void read_item(fz_context* ctx, pdf_annot* annot, int page_index, spdf_fill_item* item) {
    enum pdf_annot_type type = pdf_annot_type(ctx, annot);
    const char* nm = annot_nm(ctx, annot);
    size_t group_len;
    item->page_index = page_index;
    item->cell = -1;
    item->nm = dup_text(ctx, nm);
    group_len = comb_group_length(nm, &item->cell);
    item->group = dup_text(ctx, nm);
    if (group_len) item->group[group_len] = 0;
    else item->cell = -1;
    if (type == PDF_ANNOT_INK && drawing_kind(nm) >= 0) {
        read_drawing(ctx, annot, (spdf_fill_kind)drawing_kind(nm), item);
        return;
    }
    if (type == PDF_ANNOT_INK) {
        int cross;
        item->rect = from_fz(mark_box(ctx, annot, &cross));
        item->kind = cross ? SPDF_FILL_CROSS : SPDF_FILL_CHECK;
        return;
    }
    item->rect = from_fz(pdf_annot_rect(ctx, annot));
    if (type == PDF_ANNOT_STAMP) {
        item->kind = strncmp(nm, SPDF_FILL_INITIALS_NM_PREFIX, sizeof(SPDF_FILL_INITIALS_NM_PREFIX) - 1) == 0
                         ? SPDF_FILL_INITIALS
                         : SPDF_FILL_SIGNATURE;
    } else {
        const char* font = NULL;
        float color[4];
        int n = 0;
        item->kind = SPDF_FILL_TEXT;
        pdf_annot_default_appearance(ctx, annot, &font, &item->font_size, &n, color);
        item->text = dup_text(ctx, pdf_annot_contents(ctx, annot));
    }
}

int spdf_fill_load_items(spdf_document* doc, int page_index, spdf_fill_items* out, char* err, size_t err_len) {
    pdf_document* pdf;
    pdf_page* volatile page = NULL;
    spdf_fill_set_error(err, err_len, "");
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        spdf_fill_set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf) return 1;
    fz_try(doc->ctx) {
        fz_context* ctx = doc->ctx;
        pdf_annot* annot;
        int total = 0;
        page = pdf_load_page(ctx, pdf, page_index);
        for (annot = pdf_first_annot(ctx, page); annot; annot = pdf_next_annot(ctx, annot))
            if (strncmp(annot_nm(ctx, annot), SPDF_FILL_NM_PREFIX, sizeof(SPDF_FILL_NM_PREFIX) - 1) == 0) ++total;
        if (total) {
            out->items = (spdf_fill_item*)calloc((size_t)total, sizeof(spdf_fill_item));
            if (!out->items) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
        for (annot = pdf_first_annot(ctx, page); annot && out->count < total; annot = pdf_next_annot(ctx, annot)) {
            enum pdf_annot_type type = pdf_annot_type(ctx, annot);
            if (strncmp(annot_nm(ctx, annot), SPDF_FILL_NM_PREFIX, sizeof(SPDF_FILL_NM_PREFIX) - 1) != 0) continue;
            if (type != PDF_ANNOT_FREE_TEXT && type != PDF_ANNOT_INK && type != PDF_ANNOT_STAMP) continue;
            read_item(ctx, annot, page_index, &out->items[out->count++]);
        }
    }
    fz_always(doc->ctx) pdf_drop_page(doc->ctx, page);
    fz_catch(doc->ctx) {
        spdf_fill_set_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_free_fill_items(out);
        return 0;
    }
    return 1;
}

void spdf_free_fill_items(spdf_fill_items* items) {
    int i;
    if (!items) return;
    for (i = 0; i < items->count; ++i) {
        free(items->items[i].nm);
        free(items->items[i].group);
        free(items->items[i].text);
        free(items->items[i].points);
    }
    free(items->items);
    memset(items, 0, sizeof(*items));
}
