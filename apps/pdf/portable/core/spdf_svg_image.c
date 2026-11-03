/* spdf_svg_image.c -- see spdf_svg_image.h. */
#include "spdf_svg_image.h"

#include "spdf_recolor.h"
#include "spdf_svg_font.h"

#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#include <stdlib.h>
#include <string.h>

unsigned char* spdf_svg_image_pdf(const unsigned char* svg, size_t svg_len, size_t* pdf_len, float* width,
                                  float* height) {
    fz_context* ctx;
    fz_buffer* input = NULL;
    fz_buffer* output = NULL;
    fz_output* out = NULL;
    fz_document* doc = NULL;
    fz_page* page = NULL;
    pdf_document* pdf = NULL;
    pdf_obj* resources = NULL;
    pdf_obj* page_obj = NULL;
    fz_buffer* contents = NULL;
    unsigned char* result = NULL;
    volatile size_t result_len = 0;
    fz_rect bounds = fz_empty_rect;

    if (pdf_len) *pdf_len = 0;
    if (width) *width = 0;
    if (height) *height = 0;
    if (!svg || !svg_len || !pdf_len) return NULL;
    ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) return NULL;
    fz_var(input);
    fz_var(output);
    fz_var(out);
    fz_var(doc);
    fz_var(page);
    fz_var(pdf);
    fz_var(resources);
    fz_var(page_obj);
    fz_var(contents);
    fz_var(result);
    fz_var(bounds);

    fz_try(ctx) {
        fz_device* dev;
        pdf_write_options write = pdf_default_write_options;
        unsigned char* data;
        size_t len;

        fz_register_document_handlers(ctx);
        input = fz_new_buffer_from_copied_data(ctx, svg, svg_len);
        /* No directory: an <image> naming a file stays empty rather than reading from disk. */
        doc = fz_open_document_with_buffer(ctx, "image/svg+xml", input);
        page = fz_load_page(ctx, doc, 0);
        bounds = fz_bound_page(ctx, page);
        if (fz_is_empty_rect(bounds)) fz_throw(ctx, FZ_ERROR_FORMAT, "empty SVG");

        /* As fz_new_pdf_writer would, but with the document in hand to fix its fonts before it is written. */
        pdf = pdf_create_document(ctx);
        dev = pdf_page_write(ctx, pdf, bounds, &resources, &contents);
        fz_try(ctx) {
            fz_run_page(ctx, page, dev, fz_identity, NULL);
            fz_close_device(ctx, dev);
        }
        fz_always(ctx) fz_drop_device(ctx, dev);
        fz_catch(ctx) fz_rethrow(ctx);
        page_obj = pdf_add_page(ctx, pdf, bounds, 0, resources, contents);
        pdf_insert_page(ctx, pdf, -1, page_obj);
        spdf_svg_fonts_to_opentype(ctx, pdf);

        output = fz_new_buffer(ctx, 16 * 1024);
        out = fz_new_output_with_buffer(ctx, output);
        pdf_parse_write_options(ctx, &write, "compress");
        pdf_write_document(ctx, pdf, out, &write);
        fz_close_output(ctx, out);

        len = fz_buffer_storage(ctx, output, &data);
        result = (unsigned char*)malloc(len ? len : 1);
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "out of memory");
        memcpy(result, data, len);
        result_len = len;
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, page_obj);
        pdf_drop_obj(ctx, resources);
        fz_drop_buffer(ctx, contents);
        pdf_drop_document(ctx, pdf);
        fz_drop_output(ctx, out);
        fz_drop_buffer(ctx, output);
        fz_drop_page(ctx, page);
        fz_drop_document(ctx, doc);
        fz_drop_buffer(ctx, input);
    }
    fz_catch(ctx) {
        free(result);
        result = NULL;
        result_len = 0;
    }
    fz_drop_context(ctx);
    *pdf_len = result_len;
    if (result && width) *width = bounds.x1 - bounds.x0;
    if (result && height) *height = bounds.y1 - bounds.y0;
    return result;
}

/* One colour through the dark theme's remap, as spdf_recolor_rgba remaps a pixel of it. */
static void spdf_svg_dark_rgb(const spdf_recolor_table* table, float rgb[3]) {
    unsigned char pixel[4];
    int c;
    for (c = 0; c < 3; c++) pixel[c] = (unsigned char)(fz_clamp(rgb[c], 0, 1) * 255 + 0.5f);
    pixel[3] = 255;
    spdf_recolor_rgba(pixel, 1, 1, 4, table);
    for (c = 0; c < 3; c++) rgb[c] = pixel[c] / 255.0f;
}

static void spdf_svg_dark_color(fz_context* ctx, void* opaque, pdf_obj** cs_obj, int* n, float color[FZ_MAX_COLORS]) {
    float rgb[3] = {0, 0, 0};
    fz_colorspace* cs;
    if (pdf_name_eq(ctx, *cs_obj, PDF_NAME(Pattern)) ||
        pdf_name_eq(ctx, pdf_dict_get(ctx, *cs_obj, PDF_NAME(Type)), PDF_NAME(Pattern)) || *n == 0)
        return;
    cs = pdf_load_colorspace(ctx, *cs_obj);
    fz_try(ctx) fz_convert_color(ctx, cs, color, fz_device_rgb(ctx), rgb, NULL, fz_default_color_params);
    fz_always(ctx) fz_drop_colorspace(ctx, cs);
    fz_catch(ctx) fz_rethrow(ctx);
    spdf_svg_dark_rgb((const spdf_recolor_table*)opaque, rgb);
    pdf_drop_obj(ctx, *cs_obj);
    *cs_obj = PDF_NAME(DeviceRGB);
    *n = 3;
    memcpy(color, rgb, sizeof rgb);
}

static void spdf_svg_dark_image(fz_context* ctx, void* opaque, fz_image** image, fz_matrix ctm, pdf_obj* obj) {
    const spdf_recolor_table* table = (const spdf_recolor_table*)opaque;
    fz_image* original = *image;
    fz_pixmap* pix;
    fz_pixmap* rgb = NULL;
    (void)ctm;
    (void)obj;
    if (original->imagemask) return; /* drawn in the fill colour, which is remapped already */
    pix = fz_get_unscaled_pixmap_from_image(ctx, original);
    fz_var(rgb);
    fz_try(ctx) {
        int x, y, c;
        rgb = fz_convert_pixmap(ctx, pix, fz_device_rgb(ctx), NULL, NULL, fz_default_color_params, 1);
        for (y = 0; y < rgb->h; y++) {
            unsigned char* p = rgb->samples + (size_t)y * rgb->stride;
            for (x = 0; x < rgb->w; x++, p += rgb->n) {
                /* Pixmap alpha is premultiplied: remap the colour itself, as the Markdown recolour does. */
                unsigned a = rgb->alpha ? p[3] : 255;
                unsigned char pixel[4] = {0, 0, 0, 255};
                if (a == 0) continue;
                for (c = 0; c < 3; c++) pixel[c] = (unsigned char)fz_mini(255, (p[c] * 255 + a / 2) / a);
                spdf_recolor_rgba(pixel, 1, 1, 4, table);
                for (c = 0; c < 3; c++) p[c] = (unsigned char)((pixel[c] * a + 127) / 255);
            }
        }
        *image = fz_new_image_from_pixmap(ctx, rgb, original->mask);
        fz_drop_image(ctx, original);
    }
    fz_always(ctx) {
        fz_drop_pixmap(ctx, rgb);
        fz_drop_pixmap(ctx, pix);
    }
    fz_catch(ctx) fz_rethrow(ctx);
}

static void spdf_svg_dark_vertex(fz_context* ctx, void* opaque, fz_colorspace* dst_cs, float* d, fz_colorspace* src_cs,
                                 const float* s) {
    (void)dst_cs;
    fz_convert_color(ctx, src_cs, s, fz_device_rgb(ctx), d, NULL, fz_default_color_params);
    spdf_svg_dark_rgb((const spdf_recolor_table*)opaque, d);
}

static pdf_recolor_vertex* spdf_svg_dark_shade(fz_context* ctx, void* opaque, fz_colorspace* src_cs,
                                               fz_colorspace** dst_cs) {
    (void)opaque;
    (void)src_cs;
    *dst_cs = fz_device_rgb(ctx);
    return spdf_svg_dark_vertex;
}

unsigned char* spdf_svg_image_pdf_dark(const unsigned char* pdf, size_t pdf_len, size_t* out_len) {
    fz_context* ctx;
    fz_buffer* input = NULL;
    fz_buffer* output = NULL;
    fz_output* out = NULL;
    fz_stream* stream = NULL;
    pdf_document* doc = NULL;
    pdf_page* page = NULL;
    unsigned char* result = NULL;
    volatile size_t result_len = 0;
    spdf_recolor_table table;

    if (out_len) *out_len = 0;
    if (!pdf || !pdf_len || !out_len) return NULL;
    spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, spdf_recolor_default_dark_theme());
    ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) return NULL;
    fz_var(input);
    fz_var(output);
    fz_var(out);
    fz_var(stream);
    fz_var(doc);
    fz_var(page);
    fz_var(result);

    fz_try(ctx) {
        pdf_filter_options options = {0};
        pdf_filter_factory filters[2] = {{0}};
        pdf_color_filter_options colors = {0};
        pdf_write_options write = pdf_default_write_options;
        unsigned char* data;
        size_t len;

        input = fz_new_buffer_from_copied_data(ctx, pdf, pdf_len);
        stream = fz_open_buffer(ctx, input);
        doc = pdf_open_document_with_stream(ctx, stream);
        page = pdf_load_page(ctx, doc, 0);
        colors.opaque = &table;
        colors.color_rewrite = spdf_svg_dark_color;
        colors.image_rewrite = spdf_svg_dark_image;
        colors.shade_rewrite = spdf_svg_dark_shade;
        filters[0].filter = pdf_new_color_filter;
        filters[0].options = &colors;
        options.filters = filters;
        options.recurse = 1;
        pdf_filter_page_contents(ctx, doc, page, &options);

        output = fz_new_buffer(ctx, pdf_len + 1024);
        out = fz_new_output_with_buffer(ctx, output);
        write.do_compress = 1;
        write.do_garbage = 1; /* drops the original content stream */
        pdf_write_document(ctx, doc, out, &write);
        fz_close_output(ctx, out);

        len = fz_buffer_storage(ctx, output, &data);
        result = (unsigned char*)malloc(len ? len : 1);
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "out of memory");
        memcpy(result, data, len);
        result_len = len;
    }
    fz_always(ctx) {
        fz_drop_output(ctx, out);
        fz_drop_buffer(ctx, output);
        fz_drop_page(ctx, (fz_page*)page);
        pdf_drop_document(ctx, doc);
        fz_drop_stream(ctx, stream);
        fz_drop_buffer(ctx, input);
    }
    fz_catch(ctx) {
        free(result);
        result = NULL;
        result_len = 0;
    }
    fz_drop_context(ctx);
    *out_len = result_len;
    return result;
}
