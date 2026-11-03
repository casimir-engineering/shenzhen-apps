#pragma once
/* Text in the PDF of an SVG picture (spdf_svg_image.h) that Quartz can still read back.
 *
 * MuPDF draws SVG text in its built-in fonts (Nimbus Sans for Helvetica, Arial and sans-serif, and the other URW
 * base-14 clones), which are bare CFF programs: the PDF embeds each as a CIDFontType0C font program with Identity-H
 * codes and a ToUnicode map. Every reader gets the text back from that PDF. But the reader draws the picture through
 * Quartz (CGContextDrawPDFPage), and when Quartz writes the page into another PDF (export, print to PDF) it embeds
 * the font again and drops the ToUnicode map, keeping only the glyph ids: copied text came out shifted ("5PUBM" for
 * "Total"). Quartz does write a ToUnicode map for an OpenType font, from the font's own cmap. So each bare CFF font
 * program is wrapped here in a minimal OpenType font (the same CFF plus cmap, head, hhea, hmtx, maxp, OS/2, name and
 * post), whose cmap is the ToUnicode map MuPDF wrote, turned round. Glyph ids, and so the content stream, the widths
 * and the drawing, do not change. */

#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Wraps every Type0 font in `doc` whose font program is bare CFF, with a ToUnicode map, in OpenType. A font that
 * fails is left as it was: it still draws, only its text does not survive Quartz. */
void spdf_svg_fonts_to_opentype(fz_context* ctx, pdf_document* doc);

#ifdef __cplusplus
}
#endif
