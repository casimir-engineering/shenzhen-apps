#pragma once
/* CORE-INTERNAL (Core B): the brush engine shared by spdf_paint_brush.c (strokes into a raster layer),
 * spdf_paint_brush_tex.c (the textured brushes and the noise they use) and spdf_paint_shapes*.c (the textured
 * outline and fill styles of § 2 Shapes, "masking the brush textures with the path").
 *
 * A stroke is built as a coverage mask (one byte per device pixel, 0-255) over a box of device pixels, then
 * composited by the caller: into a layer with the colour and the stroke's opacity, or into a shape's picture. Building
 * the whole stroke first is what keeps a stroke from darkening where it overlaps itself (Brush, Marker, Pencil), while
 * two strokes laid over each other still build up as paint does.
 *
 * Everything random is drawn from `seed` and from positions in stroke space (canvas units, or a shape's own frame),
 * never from device pixels, so the same operation paints the same pixels at any zoom, in any tile, on replay. */
#include "spdf_paint_internal.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_brush_mask {
    fz_irect box;        /* device pixels the mask covers */
    int w, h;
    unsigned char* a;    /* w * h coverage bytes, row by row */
} spdf_brush_mask;

typedef struct spdf_brush_job {
    spdf_paint_brush tool;
    const spdf_paint_point* points; /* stroke space */
    int count;
    float size;          /* stroke-space units: the nib's diameter (Pencil, Brush, Airbrush...) or side (Marker, Eraser) */
    uint32_t seed;
    fz_matrix to_device; /* stroke space -> device pixels */
    int steady;          /* a shape's outline: the Oil brush never runs out of paint along it */
} spdf_brush_job;

/* ---- spdf_paint_brush.c ---- */

/* Allocates a zeroed mask over box (empty box: a mask with no pixels). 0 when out of memory. */
int spdf_brush_mask_init(fz_context* ctx, spdf_brush_mask* mask, fz_irect box);
void spdf_brush_mask_drop(fz_context* ctx, spdf_brush_mask* mask);
/* The device box the job may touch (nib, texture wobble and blur included). */
fz_irect spdf_brush_job_reach(const spdf_brush_job* job);
/* Builds the job's coverage into mask (zeroed over its box). Every tool, the erasers' square nib included. */
void spdf_brush_render(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* mask);

/* Coverage primitives, combined with the mask by max (a stroke never darkens itself). `shade`, when set, scales the
 * coverage of each pixel: it gets the pixel centre in device space and t, 0-1 along the segment. */
typedef float (*spdf_brush_shade)(void* user, float x, float y, float t);
void spdf_brush_capsule(spdf_brush_mask* m, fz_point a, float ra, fz_point b, float rb, int hard, float alpha,
                        spdf_brush_shade shade, void* user);
/* A convex polygon (any winding), antialiased or hard-edged (pixel centres inside). */
void spdf_brush_convex(spdf_brush_mask* m, const fz_point* p, int n, int hard, float alpha, spdf_brush_shade shade,
                       void* user);

/* How a stroke's coverage is laid into a layer: colour, transparency (the Eraser), or Color 1 made Color 2. */
typedef enum spdf_brush_lay_mode { SPDF_BRUSH_PAINT, SPDF_BRUSH_ERASE, SPDF_BRUSH_REPLACE_COLOR } spdf_brush_lay_mode;
/* The mode and colour a stroke lays with on `layer` (the Eraser paints Color 2 on a layer without alpha). */
spdf_brush_lay_mode spdf_brush_lay_mode_for(const spdf_paint_doc* doc, const spdf_paint_layer* layer,
                                            const spdf_paint_stroke_args* args, spdf_paint_color* color);
/* Lays the mask's coverage over `box` of dest at the stroke's opacity, inside the selection mask when there is one. */
void spdf_brush_lay(fz_pixmap* dest, const spdf_brush_mask* m, fz_irect box, spdf_brush_lay_mode mode,
                    spdf_paint_color color, spdf_paint_color replacement, float opacity, const fz_pixmap* sel);
/* The stroke's coverage, built already (a live stroke's), laid into the layer as spdf_paint_brush_stroke lays it. */
spdf_paint_status spdf_paint_brush_lay_mask(spdf_paint_doc* doc, spdf_paint_layer* layer,
                                            const spdf_paint_stroke_args* args, const spdf_brush_mask* mask,
                                            fz_irect box, spdf_rect* damage);

/* ---- spdf_paint_brush_tex.c ---- */

uint32_t spdf_brush_hash(int32_t x, int32_t y, uint32_t seed);
float spdf_brush_hash01(int32_t x, int32_t y, uint32_t seed);
float spdf_brush_noise(float x, float y, uint32_t seed);              /* smooth value noise, 0-1 */
float spdf_brush_fbm(float x, float y, uint32_t seed, int octaves);   /* 0-1 */
/* The seed an operation gets when it names none: a hash of its points, so replay is the same without one. */
uint32_t spdf_brush_default_seed(const spdf_paint_point* points, int count);

/* ---- spdf_paint_brush_live.c ---- */

/* A stroke drawn point by point, so a stroke being drawn costs only its new part per point; spdf_brush_render is the
 * same run fed every point, so both paint the same pixels. spdf_brush_run_add draws into `committed` what no later
 * point changes; spdf_brush_run_show makes `shown` the stroke as it would end at the last point: `committed`, plus the
 * last bit of a stroke walked in steps (Oil, Crayon, Natural pencil, Watercolor), Watercolor's wet look, a plain
 * nib's dot while there is one point. *changed (may be NULL): the box of `shown` that changed since the last show.
 * Both masks cover the run's box; they may be one mask when nothing is shown before the last point (a whole stroke). */
typedef struct spdf_brush_run spdf_brush_run;
spdf_brush_run* spdf_brush_run_new(fz_context* ctx, const spdf_brush_job* job, fz_irect box); /* job's points unused */
int spdf_brush_run_add(fz_context* ctx, spdf_brush_run* run, const spdf_paint_point* points, int count,
                       spdf_brush_mask* committed);
int spdf_brush_run_show(fz_context* ctx, spdf_brush_run* run, const spdf_brush_mask* committed, spdf_brush_mask* shown,
                        fz_irect* changed);
void spdf_brush_run_drop(fz_context* ctx, spdf_brush_run* run);

void spdf_brush_render_airbrush(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* mask);
void spdf_brush_render_oil(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* mask);
void spdf_brush_render_crayon(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* mask);
void spdf_brush_render_natural_pencil(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* mask);
void spdf_brush_render_watercolor(fz_context* ctx, const spdf_brush_job* job, spdf_brush_mask* mask);
/* Watercolor's wet look on any coverage (a stroke, or a shape's fill area): soft irregular edge, darker rim, light
 * middle, a little granulation. `radius` is the stroke's half width in device pixels (sets the rim's width);
 * from_device maps device pixels back to stroke space for the noise. */
void spdf_brush_wet(fz_context* ctx, spdf_brush_mask* mask, float radius, fz_matrix from_device, uint32_t seed);

/* The same over `part` of the mask only (device pixels): what lies within the blurs' reach of it is read, the rest
 * of the mask left as it is. */
void spdf_brush_wet_part(fz_context* ctx, spdf_brush_mask* mask, float radius, fz_matrix from_device, uint32_t seed,
                         fz_irect part);

/* A textured fill (§ 2 Shapes Fill: crayon, marker, oil, natural pencil): back-and-forth strokes of that brush over
 * rect (stroke space), drawn through to_device into mask. The caller multiplies the result by the shape's area. */
void spdf_brush_hatch(fz_context* ctx, spdf_paint_brush tool, spdf_rect rect, float spacing, uint32_t seed,
                      fz_matrix to_device, spdf_brush_mask* mask);

/* ---- spdf_paint_shapes.c ---- */

/* An object's placement as a matrix: its own frame (the unrotated rect, canvas units) -> canvas, flips then rotation
 * about the rect's centre. */
fz_matrix spdf_paint_place_matrix(const spdf_paint_placement* place);
/* The shape's frame -> canvas: translate to the rect's top-left, then the placement matrix. */
fz_matrix spdf_paint_shape_frame(const spdf_paint_placement* place);
/* The shape's path in its frame (spdf_paint_shape_path is this through the frame matrix). */
fz_path* spdf_paint_shape_local_path(fz_context* ctx, const spdf_paint_placement* place,
                                     const spdf_paint_shape_params* shape);
int spdf_paint_shape_is_open(spdf_paint_shape shape);     /* line, curve, arrow line: no inside to fill */
int spdf_paint_shape_uses_points(spdf_paint_shape shape); /* drawn from its points: the open shapes and polygon */
int spdf_paint_shape_is_callout(spdf_paint_shape shape);
/* Whether (x, y), canvas units, is on the object: inside a closed shape, a text box or a picture, or within `slop`
 * of a line's stroke. */
int spdf_paint_object_hit(spdf_paint_doc* doc, const spdf_paint_object* object, float x, float y, float slop);

#ifdef __cplusplus
}
#endif
