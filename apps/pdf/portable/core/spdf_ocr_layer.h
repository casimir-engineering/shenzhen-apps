#ifndef SPDF_OCR_LAYER_H
#define SPDF_OCR_LAYER_H

/* Text recognised on a PDF's pages by the macOS reader (Apple's text recognition), written into a copy as an
 * invisible text layer, the way OCRmyPDF writes Tesseract's: the pages look exactly as before, and their text selects,
 * copies and finds. Each word is stretched over its box. Nothing else in the file changes (comments, links, forms and
 * chapters stay). */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A word's box is in page coordinates as the reader shows the page (points, from the top left, rotation applied). */
typedef struct spdf_ocr_word {
    int page_index;
    float x0, y0, x1, y1;
    const char* text; /* UTF-8 */
    int space_after;  /* another word of the line follows: a space separates them in copied and found text */
} spdf_ocr_word;

/* Reads the PDF at `source` and writes it with the words to `destination` (a new file). Returns 1, or 0 with `err`. */
int spdf_save_pdf_with_ocr_words(const char* source, const char* destination, const spdf_ocr_word* words, int count,
                                 char* err, size_t err_len);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_OCR_LAYER_H */
