/* Annotate's pixel tools (docs/plans/annotate.md § 2 Tools and Brushes, § 8 Core spdf_paint_brush.c): Pencil (hard
 * edged, no antialiasing), Brush, Calligraphy brush 1 and 2, Airbrush, Oil brush, Crayon, Marker, Natural pencil,
 * Watercolor brush, Eraser and Color Eraser, as a stamp model with seeded noise (the same seed paints the same
 * pixels), and the paint.stroke handler. Pixels go into the active raster layer, never into an object, and on a PDF
 * page never into the page.
 *
 * WAVE 0 STUB (Core B implements): every function answers SPDF_PAINT_ERR_NOT_IMPLEMENTED. */
#include "spdf_paint_handlers.h"

spdf_paint_status spdf_paint_brush_stroke(spdf_paint_doc* doc, spdf_paint_layer* layer,
                                          const spdf_paint_stroke_args* args, spdf_rect* damage) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(layer); SPDF_PAINT_UNUSED(args); SPDF_PAINT_UNUSED(damage);
    return SPDF_PAINT_ERR_NOT_IMPLEMENTED;
}

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_paint_stroke)
