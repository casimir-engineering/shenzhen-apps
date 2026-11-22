#pragma once
/* Fill & Sign's pen lines and arrows, and the changes that act on several placed items at once (moving a selection,
 * removing a selection or everything): docs/plans/fill-and-sign.md, "Pen and arrow".
 *
 * A pen line is one Ink annotation with one polyline; an arrow is one Ink annotation whose first stroke is the shaft
 * (tail, tip) and whose second is an open head through the tip (spdf_ink_arrow_head), so both look the same in every
 * reader and move, erase and change colour through the same code. Both carry /C, a /BS width, the Print flag and our
 * /NM (spdf_fill_items.h). Writes go to the main-thread document and drop the core's drawing of the page; the caller
 * saves. Every call returns 1, or 0 with err (spdf_fill_pages_with_items: a count, or -1). */
#include "spdf_fill_items.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_fill_stroke {
    spdf_fill_kind kind; /* SPDF_FILL_PEN or SPDF_FILL_ARROW */
    const char* nm;      /* spdf-fill-pen-<uuid> or spdf-fill-arrow-<uuid> */
    float rgb[3];
    float width;         /* points */
    const spdf_fill_point* points; /* a pen line: at least one point; an arrow: tail and tip */
    int point_count;
} spdf_fill_stroke;

int spdf_fill_add_strokes(spdf_document* doc, int page_index, const spdf_fill_stroke* strokes, int count, char* err,
                          size_t err_len);
/* Removes every item of ours on the page named in nms (a comb entry's group name removes all its cells). Names no
 * longer on the page are skipped. */
int spdf_fill_delete_items(spdf_document* doc, int page_index, const char* const* nms, int count, char* err,
                           size_t err_len);
/* Moves the named items by (dx, dy): pen lines, arrows and marks move every point, text and signatures their box
 * (a signature keeps its drawing). */
int spdf_fill_move_items(spdf_document* doc, int page_index, const char* const* nms, int count, float dx, float dy,
                         char* err, size_t err_len);
/* New colour and width for the named pen lines and arrows (other items are left alone). */
int spdf_fill_restyle_strokes(spdf_document* doc, int page_index, const char* const* nms, int count, const float rgb[3],
                              float width, char* err, size_t err_len);
/* Moves an arrow's ends; its head is drawn again at the new tip. */
int spdf_fill_set_arrow_ends(spdf_document* doc, int page_index, const char* nm, spdf_fill_point tail,
                             spdf_fill_point tip, char* err, size_t err_len);
/* The pages holding at least one annotation whose /NM starts with prefix, in order, read from each page's /Annots
 * without loading the page. Writes at most max; returns how many pages hold one (may exceed max), or -1. */
int spdf_fill_pages_with_items(spdf_document* doc, const char* prefix, int* pages, int max, char* err, size_t err_len);

#ifdef __cplusplus
}
#endif
