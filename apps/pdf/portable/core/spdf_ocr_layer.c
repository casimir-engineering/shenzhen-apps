/* An invisible text layer written into a PDF copy: see spdf_ocr_layer.h. */
#include "spdf_ocr_layer.h"

#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FONT_NAME "SPDFRecognizedText"

/* Every code maps to the character it is: <0000>..<FFFF> as one range per high byte (a bfrange may only vary its last
 * byte), the surrogate block left out. */
static fz_buffer* identity_to_unicode(fz_context* ctx) {
    fz_buffer* buf = fz_new_buffer(ctx, 8192);
    int high, in_block = 0;
    fz_append_string(ctx, buf,
                     "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
                     "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
                     "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
                     "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
    for (high = 0; high < 256; ++high) {
        if (high >= 0xD8 && high <= 0xDF) continue;
        if (in_block == 0) {
            int left = 0, h;
            for (h = high; h < 256 && left < 100; ++h)
                if (h < 0xD8 || h > 0xDF) ++left;
            fz_append_printf(ctx, buf, "%d beginbfrange\n", left);
        }
        fz_append_printf(ctx, buf, "<%02X00> <%02XFF> <%02X00>\n", high, high, high);
        if (++in_block == 100 || high == 255) {
            fz_append_string(ctx, buf, "endbfrange\n");
            in_block = 0;
        }
    }
    fz_append_string(ctx, buf, "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
    return buf;
}

/* A Type 0 font whose codes are the characters themselves (two bytes each, Identity-H), each half an em wide, with no
 * glyphs embedded: the text is never drawn (render mode 3), only read. */
static pdf_obj* add_font(fz_context* ctx, pdf_document* pdf) {
    pdf_obj *font = NULL, *cid = NULL, *descriptor = NULL, *info = NULL, *descendants = NULL, *bbox = NULL;
    fz_buffer* cmap = NULL;
    pdf_obj* result = NULL;
    fz_var(font);
    fz_var(cid);
    fz_var(descriptor);
    fz_var(info);
    fz_var(descendants);
    fz_var(bbox);
    fz_var(cmap);
    fz_try(ctx) {
        descriptor = pdf_new_dict(ctx, pdf, 8);
        pdf_dict_put(ctx, descriptor, PDF_NAME(Type), PDF_NAME(FontDescriptor));
        pdf_dict_put_name(ctx, descriptor, PDF_NAME(FontName), FONT_NAME);
        pdf_dict_put_int(ctx, descriptor, PDF_NAME(Flags), 4);
        bbox = pdf_new_array(ctx, pdf, 4);
        pdf_array_push_int(ctx, bbox, 0);
        pdf_array_push_int(ctx, bbox, -200);
        pdf_array_push_int(ctx, bbox, 500);
        pdf_array_push_int(ctx, bbox, 800);
        pdf_dict_put(ctx, descriptor, PDF_NAME(FontBBox), bbox);
        pdf_dict_put_int(ctx, descriptor, PDF_NAME(ItalicAngle), 0);
        pdf_dict_put_int(ctx, descriptor, PDF_NAME(Ascent), 800);
        pdf_dict_put_int(ctx, descriptor, PDF_NAME(Descent), -200);
        pdf_dict_put_int(ctx, descriptor, PDF_NAME(CapHeight), 700);
        pdf_dict_put_int(ctx, descriptor, PDF_NAME(StemV), 80);

        info = pdf_new_dict(ctx, pdf, 3);
        pdf_dict_put_string(ctx, info, PDF_NAME(Registry), "Adobe", 5);
        pdf_dict_put_string(ctx, info, PDF_NAME(Ordering), "Identity", 8);
        pdf_dict_put_int(ctx, info, PDF_NAME(Supplement), 0);

        cid = pdf_new_dict(ctx, pdf, 8);
        pdf_dict_put(ctx, cid, PDF_NAME(Type), PDF_NAME(Font));
        pdf_dict_put(ctx, cid, PDF_NAME(Subtype), PDF_NAME(CIDFontType2));
        pdf_dict_put_name(ctx, cid, PDF_NAME(BaseFont), FONT_NAME);
        pdf_dict_put(ctx, cid, PDF_NAME(CIDSystemInfo), info);
        pdf_dict_put_drop(ctx, cid, PDF_NAME(FontDescriptor), pdf_add_object(ctx, pdf, descriptor));
        pdf_dict_put_int(ctx, cid, PDF_NAME(DW), 500);

        descendants = pdf_new_array(ctx, pdf, 1);
        pdf_array_push_drop(ctx, descendants, pdf_add_object(ctx, pdf, cid));

        cmap = identity_to_unicode(ctx);
        font = pdf_new_dict(ctx, pdf, 6);
        pdf_dict_put(ctx, font, PDF_NAME(Type), PDF_NAME(Font));
        pdf_dict_put(ctx, font, PDF_NAME(Subtype), PDF_NAME(Type0));
        pdf_dict_put_name(ctx, font, PDF_NAME(BaseFont), FONT_NAME);
        pdf_dict_put(ctx, font, PDF_NAME(Encoding), PDF_NAME(Identity_H));
        pdf_dict_put(ctx, font, PDF_NAME(DescendantFonts), descendants);
        pdf_dict_put_drop(ctx, font, PDF_NAME(ToUnicode), pdf_add_stream(ctx, pdf, cmap, NULL, 0));
        result = pdf_add_object(ctx, pdf, font);
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, font);
        pdf_drop_obj(ctx, cid);
        pdf_drop_obj(ctx, descriptor);
        pdf_drop_obj(ctx, info);
        pdf_drop_obj(ctx, descendants);
        pdf_drop_obj(ctx, bbox);
        fz_drop_buffer(ctx, cmap);
    }
    fz_catch(ctx) fz_rethrow(ctx);
    return result;
}

/* One word, as hex UTF-16 codes, stretched over its box: `origin` is where its baseline starts, `run` the box's
 * reading direction and length, `up` its height, all in PDF space (so a rotated page's words run the way they show). */
static void append_word(fz_context* ctx, fz_buffer* buf, const char* utf8, int space_after, fz_point origin, fz_point run,
                        fz_point up) {
    int codes = 0;
    const char* p;
    float scale;
    for (p = utf8; *p;) {
        int c;
        p += fz_chartorune(&c, p);
        if (c > 0 && c < 0x10000 && (c < 0xD800 || c > 0xDFFF)) ++codes;
    }
    if (!codes) return;
    scale = 2.0f / codes; /* each code is half an em: the word's codes fill `run` exactly */
    fz_append_printf(ctx, buf, "%g %g %g %g %g %g Tm <", run.x * scale, run.y * scale, up.x, up.y,
                     origin.x + up.x * 0.2f, origin.y + up.y * 0.2f);
    for (p = utf8; *p;) {
        int c;
        p += fz_chartorune(&c, p);
        if (c > 0 && c < 0x10000 && (c < 0xD800 || c > 0xDFFF)) fz_append_printf(ctx, buf, "%04X", c);
    }
    /* Past the box, where the gap to the next word is: selection and search read "two words", not "twowords". */
    if (space_after) fz_append_string(ctx, buf, "0020");
    fz_append_string(ctx, buf, "> Tj\n");
}

/* The page's existing content between q and Q, so whatever state it leaves can't move the layer, then the layer. */
static void add_page_layer(fz_context* ctx, pdf_document* pdf, pdf_page* page, pdf_obj* font,
                           const spdf_ocr_word* words, int count) {
    fz_matrix page_ctm, to_pdf;
    fz_rect mediabox;
    pdf_obj *resources, *fonts, *contents, *array = NULL;
    fz_buffer *pre = NULL, *layer = NULL;
    char name[32];
    int i, n = 0;

    fz_var(array);
    fz_var(pre);
    fz_var(layer);
    fz_try(ctx) {
        pdf_page_transform(ctx, page, &mediabox, &page_ctm);
        to_pdf = fz_invert_matrix(page_ctm);

        resources = pdf_dict_get(ctx, page->obj, PDF_NAME(Resources));
        if (!resources) {
            pdf_obj* inherited = pdf_dict_get_inheritable(ctx, page->obj, PDF_NAME(Resources));
            resources = inherited ? pdf_copy_dict(ctx, inherited) : pdf_new_dict(ctx, pdf, 2);
            pdf_dict_put_drop(ctx, page->obj, PDF_NAME(Resources), resources);
        }
        fonts = pdf_dict_get(ctx, resources, PDF_NAME(Font));
        if (!fonts) fonts = pdf_dict_put_dict(ctx, resources, PDF_NAME(Font), 2);
        do snprintf(name, sizeof name, "SPDFOCR%d", n++);
        while (pdf_dict_gets(ctx, fonts, name));
        pdf_dict_puts(ctx, fonts, name, font);

        layer = fz_new_buffer(ctx, 4096);
        fz_append_printf(ctx, layer, "Q\nq\nBT\n3 Tr\n/%s 1 Tf\n", name);
        for (i = 0; i < count; ++i) {
            const spdf_ocr_word* w = &words[i];
            fz_point a = fz_transform_point_xy(w->x0, w->y1, to_pdf);
            fz_point b = fz_transform_point_xy(w->x1, w->y1, to_pdf);
            fz_point c = fz_transform_point_xy(w->x0, w->y0, to_pdf);
            if (!w->text || !*w->text || w->x1 <= w->x0 || w->y1 <= w->y0) continue;
            append_word(ctx, layer, w->text, w->space_after, a, fz_make_point(b.x - a.x, b.y - a.y),
                        fz_make_point(c.x - a.x, c.y - a.y));
        }
        fz_append_string(ctx, layer, "ET\nQ\n");

        pre = fz_new_buffer_from_copied_data(ctx, (const unsigned char*)"q\n", 2);
        array = pdf_new_array(ctx, pdf, 4);
        pdf_array_push_drop(ctx, array, pdf_add_stream(ctx, pdf, pre, NULL, 0));
        contents = pdf_dict_get(ctx, page->obj, PDF_NAME(Contents));
        if (pdf_is_array(ctx, contents))
            for (i = 0; i < pdf_array_len(ctx, contents); ++i) pdf_array_push(ctx, array, pdf_array_get(ctx, contents, i));
        else if (contents)
            pdf_array_push(ctx, array, contents);
        pdf_array_push_drop(ctx, array, pdf_add_stream(ctx, pdf, layer, NULL, 0));
        pdf_dict_put(ctx, page->obj, PDF_NAME(Contents), array);
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, array);
        fz_drop_buffer(ctx, pre);
        fz_drop_buffer(ctx, layer);
    }
    fz_catch(ctx) fz_rethrow(ctx);
}

static int compare_pages(const void* a, const void* b) {
    const spdf_ocr_word* x = (const spdf_ocr_word*)a;
    const spdf_ocr_word* y = (const spdf_ocr_word*)b;
    return x->page_index < y->page_index ? -1 : x->page_index > y->page_index;
}

int spdf_save_pdf_with_ocr_words(const char* source, const char* destination, const spdf_ocr_word* words, int count,
                                 char* err, size_t err_len) {
    fz_context* ctx;
    pdf_document* volatile pdf = NULL;
    pdf_page* volatile page = NULL;
    pdf_obj* volatile font = NULL;
    spdf_ocr_word* sorted = NULL;
    int ok = 0;

    if (err && err_len) err[0] = '\0';
    if (!source || !destination || count < 0 || (count && !words)) return 0;
    ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) {
        if (err && err_len) snprintf(err, err_len, "Out of memory.");
        return 0;
    }
    sorted = (spdf_ocr_word*)malloc(sizeof(*sorted) * (size_t)(count ? count : 1));
    if (!sorted) {
        fz_drop_context(ctx);
        if (err && err_len) snprintf(err, err_len, "Out of memory.");
        return 0;
    }
    if (count) memcpy(sorted, words, sizeof(*sorted) * (size_t)count);
    /* qsort isn't stable, but a page's words keep their order through the page index tie: mergesort is. */
    mergesort(sorted, (size_t)count, sizeof(*sorted), compare_pages);
    fz_try(ctx) {
        pdf_write_options options = pdf_default_write_options;
        int start = 0, pages;
        pdf = pdf_open_document(ctx, source);
        if (pdf_needs_password(ctx, pdf)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF is protected by a password.");
        pages = pdf_count_pages(ctx, pdf);
        font = add_font(ctx, pdf);
        while (start < count) {
            int end = start;
            while (end < count && sorted[end].page_index == sorted[start].page_index) ++end;
            if (sorted[start].page_index >= 0 && sorted[start].page_index < pages) {
                page = pdf_load_page(ctx, pdf, sorted[start].page_index);
                add_page_layer(ctx, pdf, page, font, sorted + start, end - start);
                fz_drop_page(ctx, &page->super);
                page = NULL;
            }
            start = end;
        }
        options.do_compress = 1;
        options.do_garbage = 1;
        pdf_save_document(ctx, pdf, destination, &options);
        ok = 1;
    }
    fz_always(ctx) {
        if (page) fz_drop_page(ctx, &page->super);
        pdf_drop_obj(ctx, font);
        pdf_drop_document(ctx, pdf);
    }
    fz_catch(ctx) {
        if (err && err_len) snprintf(err, err_len, "%s", fz_caught_message(ctx));
    }
    free(sorted);
    fz_drop_context(ctx);
    return ok;
}
