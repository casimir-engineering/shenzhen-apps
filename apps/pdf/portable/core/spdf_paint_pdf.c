/* A PDF page as an Annotate canvas (docs/plans/annotate.md § 5 PDFs, § 8 Core spdf_paint_pdf.c): the page rendered
 * as the locked Background (render only, at the scale asked), its annotations read into layers and objects (ours
 * from /SPDFAnnotate, Fill & Sign's from their /NM names, other readers' shown but locked), and every change written
 * back as the annotations of § 5 through MuPDF's annotation API and, for Fill & Sign's own items, its writing path
 * (spdf_fill_*), with depth as /Annots order. Never rewrites the page itself.
 *
 * WAVE 0 STUB (the PDF agent implements): every function answers SPDF_PAINT_ERR_NOT_IMPLEMENTED or does nothing. */
#include "spdf_paint_internal.h"

spdf_paint_doc* spdf_paint_open_pdf_page(spdf_document* pdf, int page_index, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(pdf); SPDF_PAINT_UNUSED(page_index);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return NULL;
}

int spdf_paint_pdf_page_index(const spdf_paint_doc* doc) {
    return doc && doc->kind == SPDF_PAINT_DOC_PDF ? doc->page_index : -1;
}

spdf_paint_status spdf_paint_pdf_write_back(spdf_paint_doc* doc, int* pages_changed, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(doc);
    if (pages_changed) *pages_changed = 0;
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_status spdf_paint_pdf_reload(spdf_paint_doc* doc, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(doc);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

int spdf_paint_pdf_page_has_items(spdf_document* pdf, int page_index, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(pdf); SPDF_PAINT_UNUSED(page_index); SPDF_PAINT_UNUSED(err); SPDF_PAINT_UNUSED(err_len);
    return 0;
}

spdf_paint_status spdf_paint_pdf_remove_all(spdf_document* pdf, char* err, size_t err_len) {
    SPDF_PAINT_UNUSED(pdf);
    spdf_paint_set_error(err, err_len, "Annotate is not built yet.");
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

/* ---- Internal (spdf_paint_internal.h) ---- */

int spdf_paint_pdf_draw_page(spdf_paint_doc* doc, fz_matrix ctm, fz_pixmap* dest, fz_irect clip, int dark) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(ctm); SPDF_PAINT_UNUSED(dest); SPDF_PAINT_UNUSED(clip);
    SPDF_PAINT_UNUSED(dark);
    return 0;
}

int spdf_paint_pdf_draw_annotation(spdf_paint_doc* doc, const spdf_paint_object* object, fz_matrix ctm,
                                   fz_pixmap* dest, fz_irect clip, float opacity) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(object); SPDF_PAINT_UNUSED(ctm); SPDF_PAINT_UNUSED(dest);
    SPDF_PAINT_UNUSED(clip); SPDF_PAINT_UNUSED(opacity);
    return 0;
}

void spdf_paint_pdf_note_change(spdf_paint_doc* doc, spdf_paint_layer* layer) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer);
}

void spdf_paint_pdf_note_order(spdf_paint_doc* doc) { SPDF_PAINT_UNUSED(doc); }
