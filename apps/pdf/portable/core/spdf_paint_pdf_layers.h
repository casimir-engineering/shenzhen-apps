#pragma once
/* CORE-INTERNAL: Annotate's layers in a PDF (spdf_paint_pdf_layers.c): the /SPDFAnnotate /Layer record each
 * annotation carries, and the stack rebuilt from them after a read. docs/plans/annotate.md § 5 PDFs. */
#include "spdf_paint_model.h"
#include "spdf_paint_pdf_internal.h"

#include "cJSON.h"
#include "mupdf/pdf.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_paint_pdf_layer_record {
    int present;
    char key[96];                   /* /Id: the layer's name in the file (spdf-annotate-layer-<uuid>) */
    char name[SPDF_PAINT_NAME_MAX]; /* "Layer 2" */
    int order;                      /* 1 for the lowest layer */
    int visible;
    float opacity;
    int locked;
} spdf_paint_pdf_layer_record;

/* One annotation of a read, in /Annots order. */
typedef struct spdf_paint_pdf_placed {
    spdf_paint_id layer;            /* its entry in the canvas */
    int reread;                     /* read again now (new, or changed in the file): its record decides its layer */
    int fresh;                      /* new in the canvas */
    spdf_paint_pdf_layer_record record;
    spdf_paint_layer* on;           /* scratch: the layer it goes on */
} spdf_paint_pdf_placed;

/* The layer's name in the file (spdf-annotate-layer-<uuid>), "" before it has one. */
const char* spdf_paint_pdf_layer_key(const spdf_paint_layer* layer);
/* A layer with no drawing on its way to the file: nothing is written, it only gets its name (for its objects' records)
 * and its entry. 0 for anything else (written as usual). */
int spdf_paint_pdf_name_empty_layer(spdf_paint_doc* doc, spdf_paint_layer* layer, spdf_paint_pdf_entry* e);
/* Writes the record of entry's layer into the annotation's /SPDFAnnotate (made when it has none). */
void spdf_paint_pdf_put_layer_record(spdf_paint_doc* doc, pdf_obj* annot, const spdf_paint_layer* entry);
/* Reads it; 0 (and *out cleared) when the annotation has none. */
int spdf_paint_pdf_read_layer_record(fz_context* ctx, pdf_obj* annot, spdf_paint_pdf_layer_record* out);
/* Visibility and opacity from /F and /CA: a layer's drawing takes its record's; an object keeps what its layer
 * doesn't explain (hidden only while the layer is shown, its share of /CA). */
void spdf_paint_pdf_read_props(fz_context* ctx, pdf_obj* annot, spdf_paint_layer* layer,
                               const spdf_paint_pdf_layer_record* rec);
/* Adds the entry's layer (name in the file, name, order, visibility, opacity) and how it is drawn to a layer state
 * (spdf_paint_pdf_layer_state), so a change to the layer writes its objects again. */
void spdf_paint_pdf_state_layer(spdf_paint_doc* doc, cJSON* s, const spdf_paint_layer* entry);
/* The layer a record names: found by its /Id; else, on a first read, the page's own unnamed Layer 1; else a new one. */
spdf_paint_layer* spdf_paint_pdf_layer_for(spdf_paint_doc* doc, const spdf_paint_pdf_layer_record* rec, int first_read);
/* The layer a drawing Stamp (/NM nm) belongs to: by its record, else (written before layers held objects) the layer
 * with that name in the file, the page's unnamed Layer 1 on a first read, or a new layer named `name`. */
spdf_paint_layer* spdf_paint_pdf_layer_for_drawing(spdf_paint_doc* doc, const char* nm, const char* name,
                                                   const spdf_paint_pdf_layer_record* rec, int first_read);
spdf_paint_layer* spdf_paint_pdf_lowest_layer(spdf_paint_doc* doc); /* made when there is none */
/* The stack after a read: layers (in /Order on a first read), each followed by its objects in the file's order. */
void spdf_paint_pdf_arrange(spdf_paint_doc* doc, spdf_paint_pdf_placed* placed, int count, int first_read);

#ifdef __cplusplus
}
#endif
