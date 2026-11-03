#pragma once
/* An SVG picture as a one-page vector PDF, drawn by MuPDF's SVG renderer (mupdf/source/svg). The Mac reader shows
 * SVG images in Markdown this way (mac/SPDFMacSVGImage.mm) so that it draws them as the Windows reader does, whose
 * HTML engine uses the same renderer, and draws the page itself at every draw, so it stays sharp at any zoom. Each
 * call works in a MuPDF context of its own, so it may run on any thread. */
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The PDF's bytes, malloc'd and owned by the caller (free()), or NULL when `svg` is not an SVG MuPDF can draw. The
 * page is the SVG's own size in points, as its width, height and viewBox give it, and `width` and `height` (either
 * may be NULL) receive it exactly. External files the SVG refers to are not read. Its text extracts as the SVG's
 * text, also from a PDF that Quartz writes with the page drawn into it (spdf_svg_font.h). */
unsigned char* spdf_svg_image_pdf(const unsigned char* svg, size_t svg_len, size_t* pdf_len, float* width,
                                  float* height);

/* A vector picture for the dark reading theme: the first page of `pdf` (as spdf_svg_image_pdf makes, or a PDF a
 * document shows as a picture) with its colours, images and shadings put through the dark theme's luma remap
 * (spdf_recolor.h), the same remap the reader applies to a picture's pixels, so it looks as a recoloured bitmap
 * would and stays vector. Returned as spdf_svg_image_pdf returns, NULL on failure. */
unsigned char* spdf_svg_image_pdf_dark(const unsigned char* pdf, size_t pdf_len, size_t* out_len);

#ifdef __cplusplus
}
#endif
