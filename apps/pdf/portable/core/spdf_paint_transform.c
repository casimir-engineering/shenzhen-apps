/* Annotate's whole-picture and scoped transforms (docs/plans/annotate.md § 2 Image group, § 8 Core
 * spdf_paint_transform.c): resize (Lanczos down, bilinear up), skew, rotate (any angle), flip, crop, canvas resize,
 * invert, black and white, clear, and applying the frontend's subject mask; the Canvas and Image handlers. On a PDF
 * page none of these touch the page: scope "image" means the added layers and objects, and canvas.resize answers
 * page_locked.
 *
 * WAVE 0 STUB (Core A implements): every function answers SPDF_PAINT_ERR_NOT_IMPLEMENTED or does nothing. */
#include "spdf_paint_handlers.h"

fz_pixmap* spdf_paint_scale_pixmap(fz_context* ctx, const fz_pixmap* src, int w, int h) {
    SPDF_PAINT_UNUSED(ctx); SPDF_PAINT_UNUSED(src); SPDF_PAINT_UNUSED(w); SPDF_PAINT_UNUSED(h);
    return NULL;
}

fz_pixmap* spdf_paint_rotate_pixmap(fz_context* ctx, const fz_pixmap* src, float degrees) {
    SPDF_PAINT_UNUSED(ctx); SPDF_PAINT_UNUSED(src); SPDF_PAINT_UNUSED(degrees);
    return NULL;
}

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_canvas_resize)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_canvas_properties)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_image_resize)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_image_skew)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_image_rotate)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_image_flip)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_image_crop)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_image_invert)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_image_clear)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_image_remove_background)
