/* Annotate's Fill and Color picker (docs/plans/annotate.md § 2 Tools, § 8 Core spdf_paint_fill.c): scanline flood
 * fill with tolerance, contiguous or everywhere, bounded by the edges you see (every visible layer, the PDF page
 * included) and painted into the active raster layer (Fill clicked on a shape fills the shape: the handler sends that
 * to the object instead); colour pick from what you see or the active layer. The paint.fill and color.pick handlers.
 *
 * WAVE 0 STUB (Core B implements): every function answers SPDF_PAINT_ERR_NOT_IMPLEMENTED. */
#include "spdf_paint_handlers.h"

spdf_paint_status spdf_paint_flood_fill(spdf_paint_doc* doc, spdf_paint_layer* layer, const spdf_paint_fill_args* args,
                                        spdf_rect* damage) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer); SPDF_PAINT_UNUSED(args); SPDF_PAINT_UNUSED(damage);
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

spdf_paint_status spdf_paint_pick_color(spdf_paint_doc* doc, float x, float y, int from_visible,
                                        spdf_paint_color* out) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(x); SPDF_PAINT_UNUSED(y); SPDF_PAINT_UNUSED(from_visible);
    if (out) *out = 0;
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_paint_fill)
SPDF_PAINT_STUB_HANDLER(spdf_paint_op_color_pick)
