#pragma once
/* An SVG picture as a one-page vector PDF, drawn by MuPDF's SVG renderer (mupdf/source/svg). The Mac reader shows
 * SVG images in Markdown this way (mac/SPDFMacSVGImage.mm) so that it draws them as the Windows reader does, whose
 * HTML engine uses the same renderer. Each call works in a MuPDF context of its own, so it may run on any thread. */
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The PDF's bytes, malloc'd and owned by the caller (free()), or NULL when `svg` is not an SVG MuPDF can draw. The
 * page is the SVG's own size in points, as its width, height and viewBox give it, and `width` and `height` (either
 * may be NULL) receive it exactly. External files the SVG refers to are not read. */
unsigned char* spdf_svg_image_pdf(const unsigned char* svg, size_t svg_len, size_t* pdf_len, float* width,
                                  float* height);

#ifdef __cplusplus
}
#endif
