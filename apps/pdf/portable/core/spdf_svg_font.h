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
 * and the drawing, do not change.
 *
 * MuPDF also embeds every font program whole, which made a chart with Chinese text 19 MB (Source Han Serif) and added
 * 30-50 KB per URW font. So the page is drawn with fonts cut down to the glyphs it uses (spdf_svg_run_page), already in
 * that OpenType form; the wrapping after the fact is left for a font that could not be cut down. */

#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Runs `page` into `dev`, a PDF-writing device (pdf_page_write), as fz_run_page does, but draws the text of every
 * font whose program is CFF (the URW fonts, Source Han for Chinese, Japanese and Korean, the Noto fallbacks) in an
 * OpenType font of only the glyphs the page draws (spdf_cff_subset.h), numbered from 0, with a cmap of the characters
 * they stand for. pdf_add_cid_font then embeds that font, with its own widths and ToUnicode map, rather than the whole
 * font program: a chart with Chinese text was 19 MB, the whole of Source Han Serif. The page runs twice, once to
 * see which glyphs each font draws. A font that cannot be cut down is drawn as it is (spdf_svg_fonts_to_opentype). */
void spdf_svg_run_page(fz_context* ctx, fz_page* page, fz_device* dev);

/* Wraps every Type0 font in `doc` whose font program is bare CFF, with a ToUnicode map, in OpenType. A font that
 * fails is left as it was: it still draws, only its text does not survive Quartz. */
void spdf_svg_fonts_to_opentype(fz_context* ctx, pdf_document* doc);

/* The OpenType font around the CFF program `cff`, whose glyph `g` has Unicode `unicode[g]` (0: none) and an advance of
 * `advance[g]` thousandths of an em. */
fz_buffer* spdf_sfnt_from_cff(fz_context* ctx, const unsigned char* cff, size_t cff_len, int glyphs,
                              const unsigned* unicode, const int* advance, const char* name, fz_rect bbox,
                              float ascender, float descender, int bold, int italic, int mono);

/* The 'CFF ' table of the OpenType font `font` (subfont `index` of a collection), or NULL when it has none. */
const unsigned char* spdf_sfnt_cff_table(const unsigned char* font, size_t len, int index, size_t* table_len);

#ifdef __cplusplus
}
#endif
