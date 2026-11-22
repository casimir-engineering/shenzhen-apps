/* Recognised text laid over a picture: see spdf_picture_text.h. */
#include "spdf_picture_text.h"
#include "spdf_core_document.h"

#include <stdlib.h>
#include <string.h>

static spdf_picture_text_wants wants_text;
static spdf_picture_text_lookup lookup_text;

typedef struct pt_document {
    fz_document super;
    fz_document* inner;
    char* path;
} pt_document;

typedef struct pt_page {
    fz_page super;
    fz_page* inner;
} pt_page;

/* Each character takes an equal share of its word's box, drawn in Courier: every glyph of a monospaced face has the
 * same advance (0.6 em), so the share is exact and selection highlights land on the letters (MuPDF's own OCR device
 * does the same). A character Courier lacks is glyph 0, which keeps that advance; the text, not the glyph, is what
 * selection and search read. */
static void show_run(fz_context* ctx, fz_text* text, fz_font* font, const char* utf8, float x0, float x1, float top,
                     float bottom, int space_after) {
    int chars[512];
    int count = 0;
    const char* p = utf8;
    float ascender = fz_font_ascender(ctx, font), descender = fz_font_descender(ctx, font);
    float em = (bottom - top) / (ascender - descender > 0.1f ? ascender - descender : 1.0f);
    float step, baseline;
    int i;

    while (*p && count < (int)(sizeof(chars) / sizeof(chars[0]))) {
        int c;
        p += fz_chartorune(&c, p);
        chars[count++] = c;
    }
    if (!count || x1 <= x0 || bottom <= top) return;
    step = (x1 - x0) / count;
    baseline = bottom + descender * em; /* page space runs down; the descender is negative */
    for (i = 0; i < count; ++i) {
        fz_matrix trm = fz_make_matrix(step / 0.6f, 0, 0, -em, x0 + step * i, baseline);
        fz_show_glyph(ctx, text, font, trm, fz_encode_character(ctx, font, chars[i]), chars[i], 0, 0, FZ_BIDI_LTR,
                      FZ_LANG_UNSET);
    }
    /* The space to the next word of the line, in the same run: a space shown on its own, at another scale, starts
     * a span MuPDF's text extraction drops, and the copied line read "twowords". */
    if (space_after) {
        fz_matrix trm = fz_make_matrix(step / 0.6f, 0, 0, -em, x1, baseline);
        fz_show_glyph(ctx, text, font, trm, fz_encode_character(ctx, font, ' '), ' ', 0, 0, FZ_BIDI_LTR, FZ_LANG_UNSET);
    }
}

static void run_words(fz_context* ctx, pt_document* doc, pt_page* page, fz_device* dev, fz_matrix ctm) {
    spdf_picture_word* words = NULL;
    fz_text* text = NULL;
    fz_font* font = NULL;
    fz_rect box;
    float width, height;
    int count, i;

    count = lookup_text(doc->path, page->super.number, &words);
    if (count <= 0 || !words) {
        free(words);
        return;
    }
    fz_var(text);
    fz_var(font);
    fz_try(ctx) {
        box = fz_bound_page(ctx, page->inner);
        width = box.x1 - box.x0;
        height = box.y1 - box.y0;
        font = fz_new_base14_font(ctx, "Courier");
        text = fz_new_text(ctx);
        for (i = 0; i < count; ++i) {
            const spdf_picture_word* word = &words[i];
            float x0 = box.x0 + word->x0 * width, x1 = box.x0 + word->x1 * width;
            float top = box.y0 + word->y0 * height, bottom = box.y0 + word->y1 * height;
            show_run(ctx, text, font, word->text, x0, x1, top, bottom, i + 1 < count && words[i + 1].line == word->line);
        }
        fz_ignore_text(ctx, dev, text, ctm);
    }
    fz_always(ctx) {
        fz_drop_text(ctx, text);
        fz_drop_font(ctx, font);
        free(words);
    }
    fz_catch(ctx) {
        /* The picture already drew; text that can't be laid over it is left out rather than failing the page. */
        fz_report_error(ctx);
    }
}

static void pt_run_page(fz_context* ctx, fz_page* page_, fz_device* dev, fz_matrix ctm, fz_cookie* cookie) {
    pt_page* page = (pt_page*)page_;
    fz_run_page_contents(ctx, page->inner, dev, ctm, cookie);
    if (!cookie || !cookie->abort) run_words(ctx, (pt_document*)page_->doc, page, dev, ctm);
}

static void pt_run_annots(fz_context* ctx, fz_page* page_, fz_device* dev, fz_matrix ctm, fz_cookie* cookie) {
    fz_run_page_annots(ctx, ((pt_page*)page_)->inner, dev, ctm, cookie);
}

static fz_rect pt_bound_page(fz_context* ctx, fz_page* page_, fz_box_type box) {
    return fz_bound_page_box(ctx, ((pt_page*)page_)->inner, box);
}

static void pt_drop_page(fz_context* ctx, fz_page* page_) { fz_drop_page(ctx, ((pt_page*)page_)->inner); }

static fz_page* pt_load_page(fz_context* ctx, fz_document* doc_, int chapter, int number) {
    pt_document* doc = (pt_document*)doc_;
    fz_page* inner = fz_load_chapter_page(ctx, doc->inner, chapter, number);
    pt_page* page = NULL;
    fz_try(ctx) {
        page = fz_new_derived_page(ctx, pt_page, doc_);
        page->super.bound_page = pt_bound_page;
        page->super.run_page_contents = pt_run_page;
        page->super.run_page_annots = pt_run_annots;
        page->super.drop_page = pt_drop_page;
        page->inner = inner;
    }
    fz_catch(ctx) {
        fz_drop_page(ctx, inner);
        fz_rethrow(ctx);
    }
    return (fz_page*)page;
}

static int pt_count_chapters(fz_context* ctx, fz_document* doc_) {
    return fz_count_chapters(ctx, ((pt_document*)doc_)->inner);
}

static int pt_count_pages(fz_context* ctx, fz_document* doc_, int chapter) {
    return fz_count_chapter_pages(ctx, ((pt_document*)doc_)->inner, chapter);
}

static int pt_lookup_metadata(fz_context* ctx, fz_document* doc_, const char* key, char* buf, size_t size) {
    return fz_lookup_metadata(ctx, ((pt_document*)doc_)->inner, key, buf, size);
}

static void pt_drop_document(fz_context* ctx, fz_document* doc_) {
    pt_document* doc = (pt_document*)doc_;
    fz_drop_document(ctx, doc->inner);
    fz_free(ctx, doc->path);
}

/* The core's open hook (spdf_core_document.h): wraps a picture the frontend wants, hands anything else back as it is,
 * and never fails an open that MuPDF already made. */
static fz_document* wrap(fz_context* ctx, const char* path, fz_document* inner) {
    pt_document* doc = NULL;
    if (!inner || !path || !wants_text || !lookup_text || !wants_text(path)) return inner;
    fz_var(doc);
    fz_try(ctx) {
        doc = fz_new_derived_document(ctx, pt_document);
        doc->super.drop_document = pt_drop_document;
        doc->super.count_chapters = pt_count_chapters;
        doc->super.count_pages = pt_count_pages;
        doc->super.load_page = pt_load_page;
        doc->super.lookup_metadata = pt_lookup_metadata;
        doc->path = fz_strdup(ctx, path);
        doc->inner = inner;
    }
    fz_catch(ctx) {
        fz_report_error(ctx);
        if (doc) {
            doc->inner = NULL; /* still the caller's: returned below */
            fz_drop_document(ctx, &doc->super);
        }
        return inner;
    }
    return &doc->super;
}

void spdf_picture_text_install(spdf_picture_text_wants wants, spdf_picture_text_lookup lookup) {
    wants_text = wants;
    lookup_text = lookup;
    spdf_core_set_picture_text_hook(wrap);
}
