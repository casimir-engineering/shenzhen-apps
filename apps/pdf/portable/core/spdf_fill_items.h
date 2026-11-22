#pragma once
/* Things placed on any page by Fill & Sign: typed text, check and cross marks, signatures and initials, pen lines
 * and arrows (docs/plans/fill-and-sign.md, CORE 2 and "Pen and arrow").
 *
 * What goes into the PDF, so every reader shows it the same way:
 * - text: a FreeText annotation with /IT /FreeTextTypeWriter (what Acrobat's Fill & Sign writes), no border, no fill,
 *   /DA "/Helv <size> Tf 0 g"; comb text is one such annotation per cell;
 * - check and cross: an Ink annotation (one three-point stroke for a check, two diagonals for a cross), round caps;
 * - signature and initials: a Stamp drawn from filled vector outlines, or from a PNG for a picture;
 * - pen line: an Ink annotation with one dense polyline, its colour and width, round caps (spdf_fill_ink.h);
 * - arrow: an Ink annotation with two strokes, the shaft (tail, tip) and an open head through the tip.
 * Each carries /NM, which is how we find our own items again (no private keys):
 *   text and marks   spdf-fill-<uuid>
 *   comb text cells  <group nm>-c00, -c01, ...
 *   signatures       spdf-fill-sig-<signature id>-<uuid>
 *   initials         spdf-fill-ini-<signature id>-<uuid>
 *   pen lines        spdf-fill-pen-<uuid>
 *   arrows           spdf-fill-arrow-<uuid>
 * The caller makes the uuid; a signature id never contains '-' (it ends at the first one). Comments (spdf_load_comments and everything numbered by it) never list these items.
 *
 * Coordinates are page space (points, top-left origin, y down, rotation applied). Writes go to the main-thread
 * document and drop the core's cached drawing of that page; the caller saves with spdf_save_document. Every call
 * returns 1, or 0 with err. */
#include "shenzhen_pdf_core.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_FILL_NM_PREFIX "spdf-fill-"
#define SPDF_FILL_SIGNATURE_NM_PREFIX "spdf-fill-sig-"
#define SPDF_FILL_INITIALS_NM_PREFIX "spdf-fill-ini-"
#define SPDF_FILL_PEN_NM_PREFIX "spdf-fill-pen-"
#define SPDF_FILL_ARROW_NM_PREFIX "spdf-fill-arrow-"

typedef struct spdf_fill_point {
    float x, y;
} spdf_fill_point;

typedef enum spdf_fill_kind {
    SPDF_FILL_TEXT = 0,
    SPDF_FILL_CHECK = 1,
    SPDF_FILL_CROSS = 2,
    SPDF_FILL_SIGNATURE = 3,
    SPDF_FILL_INITIALS = 4,
    SPDF_FILL_PEN = 5,
    SPDF_FILL_ARROW = 6
} spdf_fill_kind;

typedef struct spdf_fill_item {
    spdf_fill_kind kind;
    int page_index;
    spdf_rect rect;  /* text: the text box (see spdf_fill_text_rect); marks: the square they were drawn in; signatures:
                        the stamp; pen lines and arrows: their bounds, width and head included */
    float font_size; /* text only */
    char* nm;        /* full /NM */
    char* group;     /* comb cells: the nm without "-cNN" (shared by all cells of one entry); otherwise equal to nm */
    int cell;        /* comb cells: NN; otherwise -1 */
    char* text;      /* text only: /Contents (UTF-8); NULL otherwise */
    /* Pen lines and arrows only: colour (0-1), width in points, and the line (an arrow: tail then tip). */
    float rgb[3];
    float width;
    spdf_fill_point* points;
    int point_count;
} spdf_fill_item;

typedef struct spdf_fill_items {
    spdf_fill_item* items;
    int count;
} spdf_fill_items;

/* Where MuPDF draws typed text inside its box, so an editor laid over the page lines up with the saved result: the
 * first baseline sits 0.8 x size below the top of the box, lines are 1.2 x size apart, and the text starts at the left
 * edge. spdf_fill_text_rect gives the box for one line whose baseline starts at (x, baseline); lines > 1 grow it
 * downwards. spdf_fill_text_baseline is the inverse. Pure. */
spdf_rect spdf_fill_text_rect(float x, float baseline, float width, float size, int lines);
float spdf_fill_text_baseline(spdf_rect rect, float size);

/* Text whose box is `rect` (from spdf_fill_text_rect). `size` 8-72 pt. Text with Chinese characters is tagged zh-Hans
 * so MuPDF picks a Chinese font. `author` becomes /T (may be NULL). */
int spdf_fill_add_text(spdf_document* doc, int page_index, spdf_rect rect, float size, const char* utf8, const char* nm,
                       const char* author, char* err, size_t err_len);
/* One character per cell: the n-th UTF-8 character of utf8 goes centred into cells[n], named <group_nm>-cNN. Extra
 * characters are dropped; spaces leave their cell empty. */
int spdf_fill_add_comb_text(spdf_document* doc, int page_index, const spdf_rect* cells, int cell_count, float size,
                            const char* utf8, const char* group_nm, const char* author, char* err, size_t err_len);
/* A check (cross = 0) or cross (cross = 1) drawn inside the square `box`, line width max(1, 0.1 x side), black. */
int spdf_fill_add_mark(spdf_document* doc, int page_index, spdf_rect box, int cross, const char* nm, char* err,
                       size_t err_len);
/* A signature from filled outlines. Each path is SVG-like with absolute commands only (M L C Q Z, numbers separated by
 * spaces or commas) in a box one unit high and `aspect` units wide, y down; all paths are filled non-zero in `rgb`
 * (0-1). `rect` should have the same aspect; the drawing is stretched into it otherwise. Moving or resizing later keeps
 * this drawing (only /Rect changes). */
int spdf_fill_add_signature_paths(spdf_document* doc, int page_index, spdf_rect rect, float aspect,
                                  const char* const* paths, int path_count, const float rgb[3], const char* nm,
                                  char* err, size_t err_len);
/* A signature from a picture (PNG with transparency). Placing the same signature id again reuses the image already in
 * the document, so a ten-page contract carries the picture once. */
int spdf_fill_add_signature_png(spdf_document* doc, int page_index, spdf_rect rect, const unsigned char* png,
                                size_t png_len, const char* nm, char* err, size_t err_len);

/* Changes one placed item, found by its /NM on page_index. rect_or_null moves or resizes it (marks are redrawn in the
 * new square; signatures keep their drawing); size > 0 changes the text size; utf8_or_null replaces the text (an
 * empty string deletes a text item). Pen lines and arrows are refused: they move with spdf_fill_move_items. */
int spdf_fill_update(spdf_document* doc, int page_index, const char* nm, const spdf_rect* rect_or_null, float size,
                     const char* utf8_or_null, char* err, size_t err_len);
/* Turns a mark into a check (cross = 0) or a cross (cross = 1), keeping its square. */
int spdf_fill_set_mark_kind(spdf_document* doc, int page_index, const char* nm, int cross, char* err, size_t err_len);
/* Removes the item named nm_or_group, or every comb cell of that group. */
int spdf_fill_delete(spdf_document* doc, int page_index, const char* nm_or_group, char* err, size_t err_len);
/* Every item of ours on one page, in /Annots order (read on a worker document). */
int spdf_fill_load_items(spdf_document* doc, int page_index, spdf_fill_items* out, char* err, size_t err_len);
void spdf_free_fill_items(spdf_fill_items* items);

/* File > Save Final Copy: writes out_path as a copy of source in which every filled field and every item of ours is
 * drawn into the page and is no longer editable; comments, links and the rest stay as they are. Opens its own
 * document (password may be NULL), so it can run on any thread. out_path must differ from source. */
int spdf_save_final_copy(const char* source, const char* password, const char* out_path, char* err, size_t err_len);

#ifdef __cplusplus
}
#endif
