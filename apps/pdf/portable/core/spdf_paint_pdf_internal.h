#pragma once
/* CORE-INTERNAL: what the PDF page bridge's units share (spdf_paint_pdf.c reads a page into a canvas and draws it,
 * spdf_paint_pdf_write.c writes the canvas back, spdf_paint_pdf_params.c turns layers and objects into the JSON kept
 * in /SPDFAnnotate and compared between writes, spdf_paint_pdf_remove.c removes and restores Annotate's annotations).
 * docs/plans/annotate.md § 5 PDFs.
 *
 * Sync model. The canvas is the editing model; the page's /Annots are the file. Every model layer that lives in the
 * PDF has an entry here: the identity of its annotation (our /NM, Fill & Sign's /NM or comb group, another reader's
 * object number), the layer's state when the two last agreed (`model`), and the annotation's fingerprint when last
 * seen (`file`). spdf_paint_pdf_write_back compares the model with `model` (so it writes only what changed, whatever
 * made the change: an operation, undo, redo) and spdf_paint_pdf_reload compares the file with `file` (so a change
 * Fill & Sign or another writer made is read in, and nothing else is touched). Layers with no entry were never in the
 * PDF; entries whose layer is gone are annotations to delete. */
#include "spdf_paint_internal.h"

#include "cJSON.h"
#include "mupdf/pdf.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_PAINT_PDF_VERSION 1
#define SPDF_PAINT_PDF_TEXT_SCALE 4 /* raster pixels per point of a text box's appearance (sharp on paper) */

typedef enum spdf_paint_pdf_origin {
    SPDF_PAINT_PDF_OURS = 0,    /* /NM spdf-annotate-...: written by Annotate, parameters in /SPDFAnnotate */
    SPDF_PAINT_PDF_FILL = 1,    /* /NM spdf-fill-...: Fill & Sign's own item, written through spdf_fill_* */
    SPDF_PAINT_PDF_FOREIGN = 2  /* another reader's annotation: shown, keeps its depth, never changed */
} spdf_paint_pdf_origin;

typedef struct spdf_paint_pdf_entry {
    spdf_paint_id layer;
    spdf_paint_pdf_origin origin;
    char* nm;         /* ours and Fill & Sign's: /NM (a comb entry: its group name); foreign: NULL */
    int object_number;/* foreign: the annotation's indirect object */
    char* model;      /* spdf_paint_pdf_layer_state when model and file last agreed */
    char* file;       /* spdf_paint_pdf_annot_fingerprint when the file was last read or written */
    int seen;         /* scratch, during a write or reload */
} spdf_paint_pdf_entry;

typedef struct spdf_paint_pdf_state {
    spdf_paint_pdf_entry* entries;
    int count, cap;
    fz_display_list* page_list; /* the page itself (contents and form widgets), for the locked Background */
    unsigned rev;               /* /SPDFAnnotate /Rev counter of this canvas */
    int writing;                /* inside write_back: reload requests from the Fill & Sign calls are ignored */
} spdf_paint_pdf_state;

/* ---- spdf_paint_pdf.c ---- */
spdf_paint_pdf_state* spdf_paint_pdf_state_of(spdf_paint_doc* doc);
spdf_paint_pdf_entry* spdf_paint_pdf_entry_for(spdf_paint_doc* doc, spdf_paint_id layer);
spdf_paint_pdf_entry* spdf_paint_pdf_entry_add(spdf_paint_doc* doc, spdf_paint_id layer, spdf_paint_pdf_origin origin,
                                               const char* nm, int object_number);
void spdf_paint_pdf_entry_remove(spdf_paint_doc* doc, spdf_paint_pdf_entry* entry);
void spdf_paint_pdf_entry_set(spdf_paint_doc* doc, spdf_paint_pdf_entry* entry, char* model, char* file); /* takes */
/* The page to read or write; throws. */
pdf_page* spdf_paint_pdf_load_page(spdf_paint_doc* doc);
/* /NM of an annotation dictionary ("" when none). */
const char* spdf_paint_pdf_nm(fz_context* ctx, pdf_obj* annot);
int spdf_paint_pdf_has_prefix(const char* text, const char* prefix);
/* The annotations of the page in /Annots order, read into the model (first open: everything new; reload: merged). */
void spdf_paint_pdf_read(spdf_paint_doc* doc, int reload);

/* ---- spdf_paint_pdf_pixels.c ---- */
/* The picture inside one of our appearances (a drawing layer's or a Picture's), premultiplied RGBA; NULL if none. */
fz_pixmap* spdf_paint_pdf_appearance_pixels(fz_context* ctx, pdf_document* pdf, pdf_obj* annot);

/* ---- spdf_paint_pdf_params.c ---- */
/* A layer's whole state as one string (kind, name, visibility, opacity, parameters, a hash of its pixels), for
 * comparing; malloc'd. */
char* spdf_paint_pdf_layer_state(spdf_paint_doc* doc, const spdf_paint_layer* layer);
/* The parameters of one of our objects (shape, text, picture placement) as the operation arguments that make it:
 * shape.add / text.add / picture.add {rect, rotation, flip...}; and back. */
cJSON* spdf_paint_pdf_object_args(const spdf_paint_object* object);
int spdf_paint_pdf_object_from_args(fz_context* ctx, spdf_paint_object* object, const cJSON* args);
/* An annotation's fingerprint: what would show that it changed (our /Rev; Fill & Sign's rect, text, points, colour;
 * anyone's flags and opacity). malloc'd. */
char* spdf_paint_pdf_annot_fingerprint(fz_context* ctx, pdf_obj* annot);
uint64_t spdf_paint_pdf_hash_pixmap(fz_context* ctx, const fz_pixmap* pixmap);
void spdf_paint_pdf_color_text(spdf_paint_color color, char out[10]);
int spdf_paint_pdf_color_parse(const char* text, spdf_paint_color* out);
void spdf_paint_pdf_rgb(spdf_paint_color color, float rgb[3]);
spdf_paint_color spdf_paint_pdf_from_rgb(const float* rgb, int n);
char* spdf_paint_pdf_strdup(const char* text); /* malloc */

/* ---- spdf_paint_pdf_write.c ---- */
/* Places the canvas units rect `r` (page space) on the page as an annotation's /Rect and gives it an appearance drawn
 * from `list` (page space too), upright as the page is displayed, opacity inside the appearance. */
void spdf_paint_pdf_set_appearance(fz_context* ctx, pdf_annot* annot, fz_display_list* list, fz_rect r);
/* A new uuid-like suffix (32 hex digits). */
void spdf_paint_pdf_uuid(char out[33]);

/* ---- spdf_paint_pdf_fill.c ---- */
/* A hidden annotation's drawing kept in /SPDFAnnotate /AP and an empty one in its place (hide), or put back: Quick
 * Look draws hidden annotations, so hiding them must also take their drawing away. */
void spdf_paint_pdf_stash_appearance(fz_context* ctx, pdf_document* doc, pdf_obj* annot, int hide);

/* ---- spdf_paint_pdf_remove.c ---- */
/* A copy of one annotation on the same page under a new /NM (Fill & Sign items duplicated on the canvas); returns the
 * new annotation (kept). */
pdf_annot* spdf_paint_pdf_clone_annot(fz_context* ctx, pdf_page* page, pdf_obj* source, const char* nm);

#ifdef __cplusplus
}
#endif
