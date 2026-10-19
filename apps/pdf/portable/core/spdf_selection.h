#ifndef SPDF_SELECTION_H
#define SPDF_SELECTION_H

#include "mupdf/fitz.h"
#include "shenzhen_pdf_core.h"

/* Core-private bridge: keeps spdf_document opaque outside its owning module. */
int spdf_selection_document_access(spdf_document* doc, int page_index, fz_context** ctx_out, fz_document** doc_out,
                                   char* err, size_t err_len);

/* Word-selection character classes. CJK scripts have no inter-word spaces, so
   double-click word selection expands runs of same-class characters instead of
   relying on space delimiters alone. */
typedef enum spdf_word_char_class {
    SPDF_WORD_CHAR_SPACE = 0,    /* whitespace, including U+3000 */
    SPDF_WORD_CHAR_CJK = 1,      /* Han, kana, Hangul, bopomofo */
    SPDF_WORD_CHAR_CJK_PUNCT = 2 /* 、。《》 etc.; never joins a run */,
    SPDF_WORD_CHAR_OTHER = 3     /* Latin and everything else; space-delimited */
} spdf_word_char_class;

spdf_word_char_class spdf_word_char_classify(int c);

/* 1 when characters a and b belong to the same double-click word run. */
int spdf_word_chars_join(int a, int b);

/* OCR text layers (e.g. Tesseract's glyphless font) have empty glyph outlines,
   so accurate-bbox extraction collapses their quads onto the baseline. Rebuild
   a usable perpendicular extent from the character size and line direction so
   hit-testing and highlight geometry work. Quads with no advance are left
   alone (they stay flagged as incomplete geometry). */
void spdf_selection_repair_collapsed_quads(fz_stext_page* page);

#endif
