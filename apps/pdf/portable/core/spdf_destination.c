/* spdf_destination.c -- a PDF's named destinations (spdf_destination.h). */
#include "spdf_destination.h"
#include "spdf_core_document.h"

#include "mupdf/pdf.h"


int spdf_named_destination_page(spdf_document* doc, const char* name) {
    int page = -1;
    if (!doc || !doc->doc || !name || !*name) return -1;
    pdf_document* pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf) return -1;
    pdf_obj* needle = NULL;
    fz_var(needle);
    fz_try(doc->ctx) {
        needle = pdf_new_text_string(doc->ctx, name);
        pdf_obj* dest = pdf_lookup_dest(doc->ctx, pdf, needle);
        if (pdf_is_dict(doc->ctx, dest)) dest = pdf_dict_get(doc->ctx, dest, PDF_NAME(D));
        if (pdf_is_array(doc->ctx, dest)) page = pdf_lookup_page_number(doc->ctx, pdf, pdf_array_get(doc->ctx, dest, 0));
    }
    fz_always(doc->ctx) {
        pdf_drop_obj(doc->ctx, needle);
    }
    fz_catch(doc->ctx) {
        fz_ignore_error(doc->ctx);
        page = -1;
    }
    return page >= 0 && page < doc->page_count ? page : -1;
}
