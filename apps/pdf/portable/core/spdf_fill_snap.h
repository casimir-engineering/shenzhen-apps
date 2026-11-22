#pragma once
/* Where typed text, marks and signatures land on a page without real form fields: the page's own drawing is read
 * once for underlines, boxes, character boxes, small squares and table rules, then every hover or click is answered
 * from that geometry without touching the document (docs/plans/fill-and-sign.md, CORE 3).
 *
 * spdf_snap_geometry_load runs on a worker document (never the main-thread one), is cancellable through the render
 * token, and stops collecting after max_segments line segments (truncated = 1; the page then snaps to what was found
 * so far plus text-based targets). Everything else here is pure and cheap enough for mouse moves.
 *
 * Coordinates are page space (points, top-left origin, y down, rotation applied). */
#include "shenzhen_pdf_core.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_snap_hline { /* horizontal rule: underline, table rule, box edge */
    float x0, x1, y;
} spdf_snap_hline;

typedef struct spdf_snap_vline { /* vertical rule: table rule, tick of a comb */
    float x, y0, y1;
} spdf_snap_vline;

typedef struct spdf_snap_text_run { /* a run of page text on one baseline, for clearance and labels */
    spdf_rect rect;
    float baseline;
    float size;
    char* text; /* UTF-8 */
} spdf_snap_text_run;

typedef struct spdf_snap_comb { /* four or more equal character boxes in a row */
    spdf_rect* cells;
    int count;
} spdf_snap_comb;

typedef struct spdf_snap_geometry {
    int page_index;
    spdf_rect page;   /* page bounds */
    spdf_snap_hline* hlines;
    int hline_count;
    spdf_snap_vline* vlines;
    int vline_count;
    spdf_rect* boxes; /* closed rectangles (drawn, or glyphs such as a ballot box or "[ ]"), comb cells excluded */
    int box_count;
    spdf_snap_comb* combs;
    int comb_count;
    spdf_snap_text_run* runs;
    int run_count;
    spdf_rect* widgets; /* the page's real form fields: never snapped to here (the field itself takes the click) */
    int widget_count;
    int truncated;
} spdf_snap_geometry;

/* Reads the page's drawing (its content only: existing annotations and form fields are not part of it). Returns 1, 0
 * when cancelled (out empty, no err), or -1 with err. */
int spdf_snap_geometry_load(spdf_document* doc, int page_index, int max_segments, spdf_render_token* cancel,
                            spdf_snap_geometry* out, char* err, size_t err_len);
void spdf_snap_geometry_free(spdf_snap_geometry* geometry);

typedef enum spdf_snap_purpose {
    SPDF_SNAP_FOR_TEXT = 0,
    SPDF_SNAP_FOR_MARK = 1,
    SPDF_SNAP_FOR_SIGNATURE = 2
} spdf_snap_purpose;

typedef enum spdf_snap_kind {
    SPDF_SNAP_NONE = 0,      /* nothing nearby: free placement at the point */
    SPDF_SNAP_CHECKBOX = 1,  /* a small square, 5-24 pt */
    SPDF_SNAP_BOX = 2,       /* a drawn box */
    SPDF_SNAP_CELL = 3,      /* a table cell made of separate rules */
    SPDF_SNAP_COMB = 4,      /* character boxes */
    SPDF_SNAP_UNDERLINE = 5, /* a line to write on (rule, ____ or .....) */
    SPDF_SNAP_FIELD = 6      /* the point is on a real form field: let the field take it */
} spdf_snap_kind;

typedef struct spdf_snap_result {
    spdf_snap_kind kind;
    spdf_rect target;   /* what to light up on hover: the box, cell, comb, field, or for an underline a strip from
                           the line up to the text height */
    spdf_rect place;    /* text: its box (spdf_fill_text_rect); mark: the square to draw in; signature: the stamp
                           rect, aspect kept */
    float baseline;     /* text: first baseline */
    float font_size;    /* text and marks: the size to use */
    int place_mark;     /* text purpose on a small square: place the current mark there instead of typing */
    const spdf_rect* cells; /* comb: its cells (owned by the geometry), cell_count of them; else NULL */
    int cell_count;
    char label[160];    /* the nearest page text to the left of or above the target, for ranking suggestions; may be
                           empty */
} spdf_snap_result;

/* Placement for a click or hover at (x, y). radius: how far to look, in page points (the caller converts its 14 screen
 * pixels; at least 6). aspect: signature width / height (ignored for text and marks). Priority: real field, small
 * square, box or cell, underline, nothing. Returns the kind (also in out->kind). Pure. */
spdf_snap_kind spdf_snap_resolve(const spdf_snap_geometry* geometry, float x, float y, float radius,
                                 spdf_snap_purpose purpose, float aspect, spdf_snap_result* out);

typedef struct spdf_snap_target {
    spdf_snap_kind kind;
    spdf_rect rect;  /* as spdf_snap_result.target */
    float probe_x;   /* a point that spdf_snap_resolve maps back onto this target */
    float probe_y;
} spdf_snap_target;

/* Targets for Tab and Shift-Tab on a page without fields: drawn boxes, small squares, character boxes, lines to write
 * on and the empty cells of ruled tables, in reading order (rows whose centres are within 4 pt, then left to right).
 * Writes up to max (out may be NULL to count), returns the total count. Pure. */
int spdf_snap_targets_in_order(const spdf_snap_geometry* geometry, spdf_snap_target* out, int max);

#ifdef __cplusplus
}
#endif
