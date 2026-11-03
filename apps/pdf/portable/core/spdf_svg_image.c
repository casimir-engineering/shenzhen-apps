/* spdf_svg_image.c -- see spdf_svg_image.h. */
#include "spdf_svg_image.h"

#include "mupdf/fitz.h"

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
    fz_document_writer* writer = NULL;
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
    fz_var(writer);
    fz_var(result);
    fz_var(bounds);

    fz_try(ctx) {
        fz_device* dev;
        unsigned char* data;
        size_t len;

        fz_register_document_handlers(ctx);
        input = fz_new_buffer_from_copied_data(ctx, svg, svg_len);
        /* No directory: an <image> naming a file stays empty rather than reading from disk. */
        doc = fz_open_document_with_buffer(ctx, "image/svg+xml", input);
        page = fz_load_page(ctx, doc, 0);
        bounds = fz_bound_page(ctx, page);
        if (fz_is_empty_rect(bounds)) fz_throw(ctx, FZ_ERROR_FORMAT, "empty SVG");

        output = fz_new_buffer(ctx, 16 * 1024);
        out = fz_new_output_with_buffer(ctx, output);
        writer = fz_new_pdf_writer_with_output(ctx, out, "compress");
        out = NULL; /* the writer owns it now */
        dev = fz_begin_page(ctx, writer, bounds);
        fz_run_page(ctx, page, dev, fz_identity, NULL);
        fz_end_page(ctx, writer);
        fz_close_document_writer(ctx, writer);

        len = fz_buffer_storage(ctx, output, &data);
        result = (unsigned char*)malloc(len ? len : 1);
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "out of memory");
        memcpy(result, data, len);
        result_len = len;
    }
    fz_always(ctx) {
        fz_drop_document_writer(ctx, writer);
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
