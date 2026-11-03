#pragma once
/* A CFF font program cut down to the glyphs a picture draws (core/spdf_svg_font.h).
 *
 * MuPDF embeds the whole font program of every font a page uses: 30-50 KB for each of its URW fonts and the full
 * 19 MB Source Han Serif when an SVG has Chinese, Japanese or Korean text. This keeps only the glyphs asked for and
 * numbers them from 0 in the order given. Each charstring is written out with its subroutines inlined, so no
 * subroutine is kept; the outlines, hints and widths stay exactly as they were. A CID-keyed font stays CID-keyed (its
 * own Private DICT for each glyph, CID = new glyph id); a name-keyed font keeps its glyph names. */

#include "mupdf/fitz.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The CFF program `cff` with only glyphs `gids[0..count)`, glyph `gids[i]` becoming glyph i (gids[0] should be 0,
 * .notdef), named `name`. Throws when the program is one this does not handle (an accented glyph built with seac, a
 * charstring with arithmetic, a broken table): the caller keeps the whole font then. */
fz_buffer* spdf_cff_subset(fz_context* ctx, const unsigned char* cff, size_t len, const int* gids, int count,
                           const char* name);

#ifdef __cplusplus
}
#endif
