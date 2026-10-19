#ifndef SPDF_DOCUMENT_EXPORT_H
#define SPDF_DOCUMENT_EXPORT_H
#include "spdf_core_document.h"

/* Shared all-format PDF writer. macOS does not link the Windows Markdown
 * opener, so its document tools use this same implementation directly. */
static inline void spdf_document_export_error(char* error, size_t length, const char* message) {
    if (error && length) snprintf(error, length, "%s", message ? message : "Unknown error");
}

static inline int spdf_document_export_pdf(spdf_document* doc, const char* path, int page_index, char* err, size_t err_len) {
    fz_document_writer* writer = NULL;
    fz_page* page = NULL;
    int first, last, i;

    spdf_document_export_error(err, err_len, "");
    if (!doc || !path || !*path) {
        spdf_document_export_error(err, err_len, "No document path was supplied.");
        return 0;
    }
    if (page_index >= doc->page_count || page_index < -1) {
        spdf_document_export_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    first = page_index < 0 ? 0 : page_index;
    last = page_index < 0 ? doc->page_count - 1 : page_index;

    fz_var(writer);
    fz_var(page);
    fz_try(doc->ctx) {
        writer = fz_new_document_writer(doc->ctx, path, "pdf", "compress");
        for (i = first; i <= last; ++i) {
            fz_device* dev;
            page = fz_load_page(doc->ctx, doc->doc, i); /* doc->doc: always the light rendition */
            dev = fz_begin_page(doc->ctx, writer, fz_bound_page(doc->ctx, page));
            fz_run_page(doc->ctx, page, dev, fz_identity, NULL);
            fz_end_page(doc->ctx, writer);
            fz_drop_page(doc->ctx, page);
            page = NULL;
        }
        fz_close_document_writer(doc->ctx, writer);
    }
    fz_always(doc->ctx) {
        fz_drop_page(doc->ctx, page);
        fz_drop_document_writer(doc->ctx, writer);
    }
    fz_catch(doc->ctx) {
        spdf_document_export_error(err, err_len, fz_caught_message(doc->ctx));
        fz_ignore_error(doc->ctx);
        return 0;
    }
    return 1;
}

#endif
