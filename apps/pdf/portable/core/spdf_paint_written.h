/* A PDF page's drawing layer as the reader will draw it once written (spdf_paint_preview_layer.c), and what the
 * reader keeps of the pictures already written (spdf_paint_pdf_warm.c).
 *
 * The write back stores a drawing layer as one picture over its painted box, as MuPDF stores a picture with
 * transparency: the colours taken out of the coverage, and the coverage a picture of its own (pdf_add_image). The
 * reader draws it as MuPDF draws such a picture: the coverage as a clip, the colours under it, each scaled from the
 * box's own edges. A preview that blends before scaling, or scales the whole layer, differs at every soft edge.
 *
 * MuPDF's result also depends on the part of the page drawn. Two causes, both made the same on both sides:
 * - a picture taken in part when less than 90 % of it is needed: the reader finds the whole one, decoded and kept
 *   for it (spdf_paint_pdf_warm), and the preview draws whole pictures;
 * - a picture drawn larger than its pixels is sampled along each row from where the drawn part starts, the step
 *   rounded to 1/16384 of a pixel, so the same pixel samples differently from another start: the preview samples
 *   from where the reader's release will start (spdf_paint_live_set_reader_crop), as MuPDF does. */
#ifndef SPDF_PAINT_WRITTEN_H
#define SPDF_PAINT_WRITTEN_H

#include "spdf_paint_model.h"
#include "mupdf/pdf.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_paint_written_picture {
    fz_irect box;          /* raster pixels of the layer it holds (the painted box) */
    fz_irect stale;        /* raster pixels changed since they were taken */
    fz_pixmap* colors;     /* RGB, as the file stores them */
    fz_pixmap* coverage;   /* alpha only */
    fz_image *image, *mask;
} spdf_paint_written_picture;

void spdf_paint_written_picture_drop(fz_context* ctx, spdf_paint_written_picture* picture);

/* The layer drawn into dest over clip (device pixels at scale), as the reader will draw it once written. */
void spdf_paint_draw_layer_as_written(spdf_paint_doc* doc, spdf_paint_layer* layer, fz_pixmap* dest, fz_irect clip,
                                      float scale, float opacity);

/* A pen line or arrow (a piece the pixel Eraser leaves) as the reader draws it once written: Fill & Sign's Ink. */
void spdf_paint_draw_line_as_written(spdf_paint_doc* doc, const spdf_paint_object* o, fz_matrix ctm, fz_pixmap* dest,
                                     fz_irect clip, float opacity);

/* spdf_paint_live.c: the picture kept for the layer a stroke is being drawn into (NULL for any other layer), and the
 * part of the page the reader's release will draw again, in device pixels at `scale` (0 when not told). */
spdf_paint_written_picture* spdf_paint_live_picture(spdf_paint_doc* doc, const spdf_paint_layer* layer);
int spdf_paint_live_reader_crop(const spdf_paint_doc* doc, float scale, fz_irect* crop);
/* The page itself (no annotations) over that whole part, drawn once per part and kept (borrowed), when `box` lies in
 * it; else NULL. */
fz_pixmap* spdf_paint_live_paper(spdf_paint_doc* doc, float scale, fz_irect box);

/* spdf_paint_pdf_warm.c: every drawing layer's written picture decoded whole and kept for the reader (after each
 * write back, and when a stroke starts); spdf_paint_pdf_close lets them go. */
void spdf_paint_pdf_warm(spdf_paint_doc* doc);
void spdf_paint_pdf_warm_drop(spdf_paint_doc* doc);

#ifdef __cplusplus
}
#endif

#endif
