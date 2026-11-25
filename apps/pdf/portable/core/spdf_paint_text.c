/* Annotate's text boxes (docs/plans/annotate.md § 2 Text box, § 8 Core spdf_paint_text.c): text objects drawn with
 * MuPDF fonts, the system font found through the frontend's resolver (spdf_paint_set_font_resolver; the Mac's uses
 * CoreText), a built-in substitute otherwise; bold, italic, underline, strikethrough, alignment, opaque background,
 * growing boxes; and the text.add handler.
 *
 * WAVE 0 STUB (Core B implements): the resolver is kept; everything else answers SPDF_PAINT_ERR_NOT_IMPLEMENTED. */
#include "spdf_paint_handlers.h"

/* Set once by the frontend before the first text object is drawn (spdf_paint.h). */
static spdf_paint_font_resolver g_resolver;
static void* g_resolver_user;

void spdf_paint_set_font_resolver(spdf_paint_font_resolver resolver, void* user) {
    g_resolver = resolver;
    g_resolver_user = user;
}

int spdf_paint_text_draw(spdf_paint_doc* doc, const spdf_paint_placement* place, const spdf_paint_text_params* text,
                         fz_matrix ctm, fz_pixmap* dest, fz_irect clip, float opacity) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(place); SPDF_PAINT_UNUSED(text); SPDF_PAINT_UNUSED(ctm);
    SPDF_PAINT_UNUSED(dest); SPDF_PAINT_UNUSED(clip); SPDF_PAINT_UNUSED(opacity);
    return 0;
}

int spdf_paint_text_measure(spdf_paint_doc* doc, const spdf_paint_text_params* text, float max_width, float* width,
                            float* height) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(text); SPDF_PAINT_UNUSED(max_width);
    if (width) *width = 0;
    if (height) *height = 0;
    return 0;
}

fz_font* spdf_paint_text_font(spdf_paint_doc* doc, spdf_paint_text_params* text) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(text);
    SPDF_PAINT_UNUSED(g_resolver); SPDF_PAINT_UNUSED(g_resolver_user);
    return NULL;
}

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_text_add)
