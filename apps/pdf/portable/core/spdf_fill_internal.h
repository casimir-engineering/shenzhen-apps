#pragma once
/* CORE-INTERNAL: helpers spdf_fill_items.c shares with spdf_fill_signature.c. */
#include "spdf_fill_items.h"

#include "mupdf/pdf.h"

#include <stddef.h>

void spdf_fill_set_error(char* err, size_t err_len, const char* message);
/* Page in range and an /NM of ours; fills err otherwise. */
int spdf_fill_check_args(spdf_document* doc, int page_index, const char* nm, char* err, size_t err_len);
/* Loads a PDF page for writing; throws when the document is not a PDF or its owner forbids annotating. */
pdf_page* spdf_fill_load_page(spdf_document* doc, int page_index);
/* /NM, the Print flag, the author when given, then the appearance. */
void spdf_fill_finish_item(fz_context* ctx, pdf_annot* annot, const char* nm, const char* author);
fz_rect spdf_fill_to_fz(spdf_rect rect);
/* After a stamp (a signature) is written or its /Rect changes, and after pdf_update_annot: its appearance's /Matrix
 * maps the /BBox onto the /Rect's size, so readers that draw the appearance at its BBox size without fitting it to
 * the Rect (Finder's previews) show it at the size it was placed. Other annotations are left alone. */
void spdf_fill_fit_stamp_appearance(fz_context* ctx, pdf_annot* annot);
