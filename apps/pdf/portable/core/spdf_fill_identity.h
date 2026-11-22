#pragma once
/* CORE-INTERNAL (needs MuPDF). Whether an annotation is something Fill & Sign placed, or typewriter text placed by
 * another app's fill tool: neither is a comment. Header-only so shenzhen_pdf_core.c (through spdf_comment_review.h)
 * needs no new object file on any platform. */
#include "spdf_fill_items.h"

#include "mupdf/pdf.h"

#include <string.h>

static inline int spdf_annot_obj_is_fill_item(fz_context* ctx, pdf_obj* annot) {
    const char* nm = pdf_to_text_string(ctx, pdf_dict_gets(ctx, annot, "NM")); /* not in MuPDF's name table */
    if (strncmp(nm, SPDF_FILL_NM_PREFIX, sizeof(SPDF_FILL_NM_PREFIX) - 1) == 0) return 1;
    return pdf_name_eq(ctx, pdf_dict_get(ctx, annot, PDF_NAME(IT)), PDF_NAME(FreeTextTypeWriter));
}
