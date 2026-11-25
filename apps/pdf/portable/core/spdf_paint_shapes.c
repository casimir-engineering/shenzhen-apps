/* Annotate's shapes (docs/plans/annotate.md § 2 Shapes, § 8 Core spdf_paint_shapes.c): the 24 shapes of Paint and
 * the arrow line as fz_paths, outline and fill styles (solid through fz_fill_path / fz_stroke_path on MuPDF's draw
 * device; crayon, marker, oil, natural pencil and watercolor by masking the brush textures with the path), their
 * bounds, and the shape.add handler.
 *
 * WAVE 0 STUB (Core B implements): every function answers SPDF_PAINT_ERR_NOT_IMPLEMENTED or nothing. */
#include "spdf_paint_handlers.h"

fz_path* spdf_paint_shape_path(fz_context* ctx, const spdf_paint_placement* place,
                               const spdf_paint_shape_params* shape) {
    SPDF_PAINT_UNUSED(ctx); SPDF_PAINT_UNUSED(place); SPDF_PAINT_UNUSED(shape);
    return NULL;
}

int spdf_paint_shape_draw(spdf_paint_doc* doc, const spdf_paint_placement* place, const spdf_paint_shape_params* shape,
                          fz_matrix ctm, fz_pixmap* dest, fz_irect clip, float opacity) {
    SPDF_PAINT_UNUSED(doc); SPDF_PAINT_UNUSED(place); SPDF_PAINT_UNUSED(shape); SPDF_PAINT_UNUSED(ctm);
    SPDF_PAINT_UNUSED(dest); SPDF_PAINT_UNUSED(clip); SPDF_PAINT_UNUSED(opacity);
    return 0;
}

spdf_rect spdf_paint_shape_bounds(const spdf_paint_placement* place, const spdf_paint_shape_params* shape) {
    SPDF_PAINT_UNUSED(shape);
    return place ? place->rect : (spdf_rect){0, 0, 0, 0};
}

spdf_paint_shape spdf_paint_shape_from_name(const char* name) {
    SPDF_PAINT_UNUSED(name);
    return SPDF_PAINT_SHAPE_COUNT;
}

const char* spdf_paint_shape_name(spdf_paint_shape shape) {
    SPDF_PAINT_UNUSED(shape);
    return NULL;
}

SPDF_PAINT_STUB_HANDLER(spdf_paint_op_shape_add)
