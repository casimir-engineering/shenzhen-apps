#pragma once
/* CORE-INTERNAL: Annotate's canvas model (docs/plans/annotate.md § 8 Core), shared by the spdf_paint_*.c units.
 * Frontends include spdf_paint.h only. Ownership by unit:
 *   spdf_paint_doc.c        the structs below: canvas, layers, objects, ids, z-order, selection mask, colours, the
 *                           composite and its tile cache, the generic object drawing dispatch (Core A)
 *   spdf_paint_ops.c        JSON parsing, schema validation, dispatch to spdf_paint_handlers.h, answers (Core A)
 *   spdf_paint_history.c    history steps and records (Core A)
 *   spdf_paint_transform.c  resize, skew, rotate, flip, crop, canvas resize, invert, black and white (Core A)
 *   spdf_paint_file.c       .szpaint, flatten, PNG out (Core A)
 *   spdf_paint_brush.c      Pencil, the nine brushes, Airbrush, Eraser, Color Eraser (Core B)
 *   spdf_paint_fill.c       flood fill, colour pick (Core B)
 *   spdf_paint_shapes.c     the 24 shapes and the arrow line as fz_paths, outline and fill styles (Core B)
 *   spdf_paint_text.c       text objects, the font resolver (Core B)
 *   spdf_paint_pdf.c        a PDF page as a canvas, annotations in and out (PDF)
 * Cross-unit entry points are declared at the end, grouped by the unit that implements them. */
#include "spdf_paint.h"

#include "mupdf/fitz.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_PAINT_TILE_SIZE 256      /* composite tiles and history snapshots, raster pixels */
#define SPDF_PAINT_PDF_RASTER_SCALE 2 /* raster pixels per point in a PDF page's drawing layers (§ 5 PDFs) */
#define SPDF_PAINT_CUSTOM_COLORS 10   /* custom palette slots (§ 2 Colors) */
#define SPDF_PAINT_NAME_MAX 128       /* layer names, UTF-8 bytes with the terminator */

/* ---- Enumerations, mirroring the schema's string values (spdf_paint_schema.c "$defs") ---- */

typedef enum spdf_paint_layer_kind {
    SPDF_PAINT_LAYER_BACKGROUND = 0, /* bottom; a picture's own pixels, or a PDF page (locked, no pixels of its own) */
    SPDF_PAINT_LAYER_RASTER = 1,     /* a layer ("Layer 1"): its pixels, which the pixel tools paint into, then the
                                        objects that follow it in the list (spdf_paint_groups.c) */
    SPDF_PAINT_LAYER_OBJECT = 2      /* one object, on the layer before it in the list; keeps its depth there */
} spdf_paint_layer_kind;

typedef enum spdf_paint_object_kind {
    SPDF_PAINT_OBJ_SHAPE = 0,     /* shape.add: the 24 shapes and the arrow line */
    SPDF_PAINT_OBJ_TEXT = 1,      /* text.add: a text box, editable any time */
    SPDF_PAINT_OBJ_PICTURE = 2,   /* picture.add, a pasted picture, or a selection that was lifted (select.lift) */
    SPDF_PAINT_OBJ_PEN = 3,       /* pen.add: Fill & Sign's smoothed vector line */
    SPDF_PAINT_OBJ_ARROW = 4,     /* arrow.add: Fill & Sign's arrow, both ends draggable */
    SPDF_PAINT_OBJ_FILL_TEXT = 5, /* PDF only: Fill & Sign's placed text (FreeText typewriter, comb cells as one) */
    SPDF_PAINT_OBJ_FILL_MARK = 6, /* PDF only: a check or a cross */
    SPDF_PAINT_OBJ_FILL_SIGNATURE = 7, /* PDF only: a signature or initials stamp */
    SPDF_PAINT_OBJ_FOREIGN = 8    /* PDF only: another reader's annotation: drawn, keeps its depth, locked */
} spdf_paint_object_kind;

/* § 2 Shapes, in Paint's order, then the arrow line. Schema strings: "line", "curve", "oval", "rectangle",
 * "rounded_rectangle", "polygon", "triangle", "right_triangle", "diamond", "pentagon", "hexagon", "right_arrow",
 * "left_arrow", "up_arrow", "down_arrow", "star4", "star5", "star6", "rounded_callout", "oval_callout",
 * "cloud_callout", "heart", "lightning", "arrow_line". */
typedef enum spdf_paint_shape {
    SPDF_PAINT_SHAPE_LINE, SPDF_PAINT_SHAPE_CURVE, SPDF_PAINT_SHAPE_OVAL, SPDF_PAINT_SHAPE_RECTANGLE,
    SPDF_PAINT_SHAPE_ROUNDED_RECTANGLE, SPDF_PAINT_SHAPE_POLYGON, SPDF_PAINT_SHAPE_TRIANGLE,
    SPDF_PAINT_SHAPE_RIGHT_TRIANGLE, SPDF_PAINT_SHAPE_DIAMOND, SPDF_PAINT_SHAPE_PENTAGON, SPDF_PAINT_SHAPE_HEXAGON,
    SPDF_PAINT_SHAPE_RIGHT_ARROW, SPDF_PAINT_SHAPE_LEFT_ARROW, SPDF_PAINT_SHAPE_UP_ARROW, SPDF_PAINT_SHAPE_DOWN_ARROW,
    SPDF_PAINT_SHAPE_STAR4, SPDF_PAINT_SHAPE_STAR5, SPDF_PAINT_SHAPE_STAR6, SPDF_PAINT_SHAPE_ROUNDED_CALLOUT,
    SPDF_PAINT_SHAPE_OVAL_CALLOUT, SPDF_PAINT_SHAPE_CLOUD_CALLOUT, SPDF_PAINT_SHAPE_HEART, SPDF_PAINT_SHAPE_LIGHTNING,
    SPDF_PAINT_SHAPE_ARROW_LINE,
    SPDF_PAINT_SHAPE_COUNT
} spdf_paint_shape;

/* Outline and fill styles (§ 2 Shapes): "none", "solid", "crayon", "marker", "oil", "natural_pencil", "watercolor". */
typedef enum spdf_paint_style {
    SPDF_PAINT_STYLE_NONE, SPDF_PAINT_STYLE_SOLID, SPDF_PAINT_STYLE_CRAYON, SPDF_PAINT_STYLE_MARKER,
    SPDF_PAINT_STYLE_OIL, SPDF_PAINT_STYLE_NATURAL_PENCIL, SPDF_PAINT_STYLE_WATERCOLOR
} spdf_paint_style;

/* paint.stroke "tool" (§ 6 Pixels), in the schema's order. */
typedef enum spdf_paint_brush {
    SPDF_PAINT_BRUSH_PENCIL, SPDF_PAINT_BRUSH_BRUSH, SPDF_PAINT_BRUSH_CALLIGRAPHY1, SPDF_PAINT_BRUSH_CALLIGRAPHY2,
    SPDF_PAINT_BRUSH_AIRBRUSH, SPDF_PAINT_BRUSH_OIL, SPDF_PAINT_BRUSH_CRAYON, SPDF_PAINT_BRUSH_MARKER,
    SPDF_PAINT_BRUSH_NATURAL_PENCIL, SPDF_PAINT_BRUSH_WATERCOLOR, SPDF_PAINT_BRUSH_ERASER,
    SPDF_PAINT_BRUSH_COLOR_ERASER,
    SPDF_PAINT_BRUSH_COUNT
} spdf_paint_brush;

typedef enum spdf_paint_align {
    SPDF_PAINT_ALIGN_LEFT, SPDF_PAINT_ALIGN_CENTER, SPDF_PAINT_ALIGN_RIGHT
} spdf_paint_align;

/* image.* "scope": "auto" (the selection or selected object if any, else the whole picture), "image", "selection",
 * "object". On a PDF, "image" and an "auto" with nothing selected mean every added layer and object, never the page. */
typedef enum spdf_paint_scope {
    SPDF_PAINT_SCOPE_AUTO, SPDF_PAINT_SCOPE_IMAGE, SPDF_PAINT_SCOPE_SELECTION, SPDF_PAINT_SCOPE_OBJECT
} spdf_paint_scope;

/* ---- Value types ---- */

typedef struct spdf_paint_point {
    float x, y;
    float pressure; /* 0-1; 1 when the input had none */
} spdf_paint_point;

typedef struct spdf_paint_stroke_style {
    spdf_paint_style style;
    spdf_paint_color color;
    float width; /* canvas units */
} spdf_paint_stroke_style;

typedef struct spdf_paint_fill_style {
    spdf_paint_style style;
    spdf_paint_color color;
} spdf_paint_fill_style;

/* Placement shared by every object: its box in canvas units before rotation, then rotation (degrees, clockwise,
 * about the box centre) and flips. bounds is the rotated box's axis-aligned bounds, kept up to date by
 * spdf_paint_object_update_bounds, for hit tests, damage and doc.state. */
typedef struct spdf_paint_placement {
    spdf_rect rect;
    float rotation;
    int flip_h, flip_v;
} spdf_paint_placement;

typedef struct spdf_paint_shape_params {
    spdf_paint_shape shape;
    spdf_paint_point* points; /* line, arrow_line: 2; curve: 4 (ends, then the two bends); polygon: corners. Others:
                                 none (drawn from the placement rect) */
    int point_count;
    spdf_paint_point tail;    /* callouts: the tail tip (its own handle) */
    spdf_paint_stroke_style outline;
    spdf_paint_fill_style fill;
} spdf_paint_shape_params;

typedef struct spdf_paint_text_params {
    char* utf8;
    char* font;               /* family as asked */
    char* resolved_font;      /* the face used: a file path from the resolver, or "Helvetica"/"Times"/"Courier" */
    float size;               /* points, 8-400 */
    int bold, italic, underline, strikethrough;
    spdf_paint_align align;
    spdf_paint_color color;
    spdf_paint_color background; /* 0: transparent */
    int grows;                /* made by a click: the box grows with the text */
} spdf_paint_text_params;

typedef struct spdf_paint_picture_params {
    fz_pixmap* pixels;        /* premultiplied RGBA, its own resolution; scaled into the placement rect when drawn */
} spdf_paint_picture_params;

typedef struct spdf_paint_line_params { /* pen and arrow */
    spdf_paint_point* points; /* pen: the smoothed line; arrow: tail, tip */
    int point_count;
    spdf_paint_color color;
    float width;
} spdf_paint_line_params;

/* A Fill & Sign item on a PDF page, as an object of this model (§ 5: "objects of this model as they are"). The core
 * keeps what it needs to draw, hit-test and order it; the item itself stays written by spdf_fill_*. */
typedef struct spdf_paint_fill_params {
    char* nm;                 /* full /NM (spdf_fill_items.h); a comb entry: its group name */
    int fill_kind;            /* spdf_fill_kind */
    char* text;               /* text items */
    float font_size;
} spdf_paint_fill_params;

typedef struct spdf_paint_foreign_params {
    int object_number;        /* the annotation's indirect object */
    char subtype[32];         /* "Highlight", "Link", ... */
} spdf_paint_foreign_params;

typedef struct spdf_paint_object {
    spdf_paint_object_kind kind;
    spdf_paint_placement place;
    spdf_rect bounds;
    union {
        spdf_paint_shape_params shape;
        spdf_paint_text_params text;
        spdf_paint_picture_params picture;
        spdf_paint_line_params line;
        spdf_paint_fill_params fill;
        spdf_paint_foreign_params foreign;
    } u;
    /* PDF pages: the annotation this object was read from or written to (/NM), and whether it changed since. */
    char* pdf_nm;
    int pdf_dirty;
} spdf_paint_object;

typedef struct spdf_paint_layer {
    spdf_paint_id id;
    spdf_paint_layer_kind kind;
    char name[SPDF_PAINT_NAME_MAX]; /* "Background", "Page 3", "Layer 1", "Rectangle", "Text: Hello" ... */
    int visible;
    float opacity;            /* 0-1 */
    int locked;               /* a PDF page's Background and other readers' annotations: nothing changes them; a
                                 layer the person locked: neither it nor its objects change */
    fz_pixmap* pixels;        /* raster and picture Background: premultiplied RGBA covering the whole canvas at
                                 raster_scale (NULL for a PDF Background, an object layer, or a raster layer nothing
                                 painted into yet) */
    spdf_paint_object* object;/* object layers */
    /* PDF pages: the drawing layer's Stamp /NM, the pixel box it covers, and whether its pixels changed. */
    char* pdf_nm;
    fz_irect pdf_used;
    int pdf_dirty;
} spdf_paint_layer;

/* The marching ants: a mask at raster resolution (n = 1, alpha 0-255), or a lifted selection, which is an object
 * (select.lift returns its id) and no longer a mask. */
typedef struct spdf_paint_selection {
    int active;
    fz_pixmap* mask;          /* NULL when no pixel selection */
    fz_irect bounds;          /* mask's used box, raster pixels */
    spdf_paint_point* outline;/* rect corners or the lasso, canvas units, for the ants */
    int outline_count;
    int transparent;          /* select.transparent: pixels equal to Color 2 stay behind when lifted */
    spdf_paint_id* objects;   /* selected objects (Shift-click, Option-drag box), front to back */
    int object_count;
} spdf_paint_selection;

typedef struct spdf_paint_tile {
    fz_pixmap* composite;     /* the tile's composite at raster scale; NULL until drawn */
    int valid;
} spdf_paint_tile;

/* Composite cache, pictures and canvases at scale 1: tiles_x x tiles_y tiles of SPDF_PAINT_TILE_SIZE. A change
 * invalidates the tiles under its damage; spdf_paint_render recomposites only those. */
typedef struct spdf_paint_tile_cache {
    int tiles_x, tiles_y;
    spdf_paint_tile* tiles;
} spdf_paint_tile_cache;

/* ---- History (spdf_paint_history.c) ---- */

typedef enum spdf_paint_record_kind {
    SPDF_PAINT_REC_TILES = 0,   /* pixels of one layer: before/after copies of the 256 x 256 tiles touched */
    SPDF_PAINT_REC_OBJECT = 1,  /* an object's parameters before and after (add: before NULL; delete: after NULL) */
    SPDF_PAINT_REC_LAYER = 2,   /* a layer added or deleted, with its pixels (add: before NULL; delete: after NULL) */
    SPDF_PAINT_REC_LAYER_PROPS = 3, /* name, visibility, opacity */
    SPDF_PAINT_REC_ORDER = 4,   /* the whole bottom-to-top id order before and after */
    SPDF_PAINT_REC_CANVAS = 5,  /* size, dpi, and every layer's pixels: crop, canvas resize, whole-image transforms */
    SPDF_PAINT_REC_ACTIVE = 6   /* the active layer and the selection, so undo puts them back with the pixels */
} spdf_paint_record_kind;

typedef struct spdf_paint_tile_snapshot {
    int tx, ty;
    fz_pixmap* before;        /* NULL: the tile was empty (no pixmap yet) */
    fz_pixmap* after;
} spdf_paint_tile_snapshot;

typedef struct spdf_paint_record {
    spdf_paint_record_kind kind;
    spdf_paint_id layer;
    union {
        struct { spdf_paint_tile_snapshot* tiles; int count; } tiles;
        struct { spdf_paint_layer* before; spdf_paint_layer* after; int index_before, index_after; } layer;
        struct { spdf_paint_id* before; spdf_paint_id* after; int count_before, count_after; } order;
        struct { int w_before, h_before, w_after, h_after; float dpi_before, dpi_after;
                 spdf_paint_layer* layers_before; int count_before; spdf_paint_layer* layers_after; int count_after; }
            canvas;
        struct { spdf_paint_id active_before, active_after; spdf_paint_selection before, after; } active;
    } u;
    size_t bytes;             /* counted against the history cap */
} spdf_paint_record;

/* One operation = one step = one Cmd+Z, however many records it made. */
typedef struct spdf_paint_step {
    char* op;                 /* the operation's JSON as applied (Edit > Repeat, the Undo menu title) */
    spdf_paint_record* records;
    int count, cap;
    size_t bytes;
} spdf_paint_step;

typedef struct spdf_paint_history {
    spdf_paint_step* steps;   /* oldest first */
    int count, cap;
    int cursor;               /* steps[0..cursor) are done; steps[cursor..count) can be redone */
    int saved_cursor;         /* cursor when last marked saved; -1 when that step was dropped */
    size_t bytes, limit;
    spdf_paint_step* open;    /* the step being recorded inside spdf_paint_apply, or NULL */
} spdf_paint_history;

/* ---- The canvas ---- */

struct spdf_paint_doc {
    fz_context* ctx;          /* own context (pictures, canvases), or the PDF document's (borrowed) */
    int owns_ctx;
    spdf_paint_doc_kind kind;
    int width, height;        /* canvas units */
    int raster_scale;         /* raster pixels per canvas unit: 1, or SPDF_PAINT_PDF_RASTER_SCALE on a PDF page */
    float dpi;
    int has_alpha;            /* the picture's format keeps alpha */

    spdf_paint_layer** layers;/* bottom to top; layers[0] is the Background */
    int layer_count, layer_cap;
    spdf_paint_id active;     /* the active raster layer (pixel tools paint here), 0 on a PDF before the first stroke */
    spdf_paint_id next_id;

    spdf_paint_selection selection;
    spdf_paint_color color1, color2;                          /* defaults black, white */
    spdf_paint_color custom[SPDF_PAINT_CUSTOM_COLORS];        /* 0 = empty slot */

    spdf_paint_tile_cache tiles;
    spdf_paint_history history;
    spdf_rect damage;         /* union since the last spdf_paint_take_damage */
    int has_damage;
    spdf_rect written_damage; /* union since the last spdf_paint_take_written_damage (a PDF page's write back) */
    int has_written_damage;
    uint64_t generation;
    struct spdf_paint_live* live; /* a stroke being drawn (spdf_paint_live.c), shown in every drawing, or NULL */

    /* PDF page canvases (spdf_paint_pdf.c). */
    spdf_document* pdf;       /* borrowed */
    int page_index;           /* -1 otherwise */
    int page_rotation;        /* 0, 90, 180, 270 */
    float page_width, page_height; /* points, as displayed */

    void* text_cache;         /* Core B: fonts loaded for text objects; spdf_paint_text_cache_drop frees them */
    struct spdf_paint_pdf_state* pdf_state; /* spdf_paint_pdf.c's own; freed by spdf_paint_pdf_close */
};

/* A frontend's error buffer, filled by the units on failure. */
void spdf_paint_set_error(char* err, size_t err_len, const char* message);
#define SPDF_PAINT_UNUSED(x) ((void)(x))

/* ---- Implemented by spdf_paint_doc.c (Core A), used by every unit ---- */

spdf_paint_doc* spdf_paint_doc_new(fz_context* ctx, int owns_ctx, spdf_paint_doc_kind kind, int width, int height);
/* Frees what the canvas made with its context and leaves it without one (see spdf_paint_doc.c). */
void spdf_paint_doc_release(spdf_paint_doc* doc);
/* spdf_paint_pdf_live.c: the open PDF page canvases, let go of when their document closes. */
void spdf_paint_pdf_live_add(spdf_paint_doc* doc);
void spdf_paint_pdf_live_remove(spdf_paint_doc* doc);
/* A new layer above `above` (0: on top) with a fresh id; raster layers get no pixels until first painted. */
spdf_paint_layer* spdf_paint_layer_new(spdf_paint_doc* doc, spdf_paint_layer_kind kind, const char* name,
                                       spdf_paint_id above);
spdf_paint_layer* spdf_paint_layer_find(spdf_paint_doc* doc, spdf_paint_id id);
int spdf_paint_layer_index(const spdf_paint_doc* doc, spdf_paint_id id); /* -1 when absent */
/* The active layer's pixels, made (canvas-sized, transparent) on first use; with an object or nothing active, its
 * layer or the lowest (Layer 1 made when there is none). NULL when it can't be painted (*layer_out: a locked layer). */
fz_pixmap* spdf_paint_active_pixels(spdf_paint_doc* doc, spdf_paint_layer** layer_out);
/* A new object of `kind` on top of the active layer's objects (spdf_paint_object_insert_index), its list entry named
 * after it ("Rectangle", "Text: Hello", "Picture", "Pen line", "Signature"). */
spdf_paint_object* spdf_paint_object_new(spdf_paint_doc* doc, spdf_paint_object_kind kind, spdf_paint_id* id_out);
void spdf_paint_object_free(fz_context* ctx, spdf_paint_object* object);
spdf_paint_object* spdf_paint_object_clone(fz_context* ctx, const spdf_paint_object* object);
void spdf_paint_object_update_bounds(spdf_paint_object* object);
/* Draws one object into dest (premultiplied RGBA) through ctm (object canvas units -> dest pixels), clipped to clip:
 * dispatches to the Core B drawers below and to picture/line drawing here. */
int spdf_paint_object_draw(spdf_paint_doc* doc, const spdf_paint_object* object, fz_matrix ctm, fz_pixmap* dest,
                           fz_irect clip, float opacity);
/* Adds to the pending damage (canvas units) and invalidates the tiles under it. */
void spdf_paint_damage(spdf_paint_doc* doc, spdf_rect rect);
void spdf_paint_damage_all(spdf_paint_doc* doc);
/* rect added to *into (spdf_paint_preview.c). */
void spdf_paint_union_damage(spdf_rect* into, int* has, spdf_rect rect);
/* Raster pixel box of a canvas-unit rect, clamped to the canvas. */
fz_irect spdf_paint_raster_box(const spdf_paint_doc* doc, spdf_rect rect);
/* "#RRGGBB" / "#RRGGBBAA" <-> spdf_paint_color. Parse returns 0 on a malformed string. */
int spdf_paint_parse_color(const char* text, spdf_paint_color* out);
void spdf_paint_format_color(spdf_paint_color color, char out[10]);

/* ---- Implemented by spdf_paint_history.c (Core A) ---- */

/* Inside spdf_paint_apply: every change of an undoable operation is recorded before it is made. */
void spdf_paint_history_begin(spdf_paint_doc* doc, const char* op_json);
void spdf_paint_history_end(spdf_paint_doc* doc, int keep); /* keep 0: the operation failed, roll its records back */
/* Call before changing pixels of `layer` inside `box` (raster pixels): snapshots the tiles not yet saved this step. */
void spdf_paint_history_save_pixels(spdf_paint_doc* doc, spdf_paint_layer* layer, fz_irect box);
void spdf_paint_history_save_object(spdf_paint_doc* doc, spdf_paint_layer* layer); /* before changing its object */
void spdf_paint_history_save_layer_props(spdf_paint_doc* doc, spdf_paint_layer* layer);
void spdf_paint_history_save_order(spdf_paint_doc* doc);
void spdf_paint_history_save_canvas(spdf_paint_doc* doc); /* before size changes or whole-canvas transforms */
void spdf_paint_history_save_active(spdf_paint_doc* doc);
void spdf_paint_history_added_layer(spdf_paint_doc* doc, spdf_paint_layer* layer);   /* after adding */
void spdf_paint_history_removing_layer(spdf_paint_doc* doc, spdf_paint_layer* layer);/* before removing */
void spdf_paint_history_free(spdf_paint_doc* doc);

/* ---- Implemented by spdf_paint_brush.c (Core B), called by the paint.stroke handler and the PDF bridge ---- */

typedef struct spdf_paint_stroke_args {
    spdf_paint_brush tool;
    const spdf_paint_point* points; /* canvas units */
    int point_count;
    spdf_paint_color color;   /* Color 1, or Color 2 for a right-drag (the caller picks) */
    spdf_paint_color color2;  /* the Color Eraser's replacement, and the Eraser's colour on a layer without alpha */
    float size;               /* canvas units */
    float opacity;            /* 0-1 */
    uint32_t seed;            /* airbrush and textured brushes: same seed, same pixels */
    const fz_pixmap* mask;    /* the selection mask to clip to, or NULL */
} spdf_paint_stroke_args;

/* Paints one stroke into `layer`'s pixels (raster scale applied), recording history first; *damage is the canvas
 * rect touched. The Eraser on a PDF erases only the drawing layer, never the page. */
spdf_paint_status spdf_paint_brush_stroke(spdf_paint_doc* doc, spdf_paint_layer* layer,
                                          const spdf_paint_stroke_args* args, spdf_rect* damage);

/* ---- Implemented by spdf_paint_fill.c (Core B) ---- */

typedef struct spdf_paint_fill_args {
    float x, y;               /* canvas units */
    spdf_paint_color color;
    float tolerance;          /* 0-1 (the schema's 0-100 %) */
    int contiguous;
} spdf_paint_fill_args;

/* The area a Fill click covers, bounded by what was drawn (every visible layer and object above the base layer; the
 * page, picture or canvas background under them is not an edge and is never filled), as a new RGBA pixmap of the
 * fill colour (*out, raster pixels) and its place (*rect, canvas units). SPDF_PAINT_ERR_NOTHING_SELECTED when the
 * click is on the document itself (an empty area that reaches the edge of the canvas, outside any pixel selection);
 * OK with *out NULL when nothing matched. */
spdf_paint_status spdf_paint_fill_region(spdf_paint_doc* doc, const spdf_paint_fill_args* args, fz_pixmap** out,
                                         spdf_rect* rect);
/* The colour at a canvas point: from the visible composite (from_visible 1) or the active layer alone. */
spdf_paint_status spdf_paint_pick_color(spdf_paint_doc* doc, float x, float y, int from_visible,
                                        spdf_paint_color* out);

/* ---- Implemented by spdf_paint_shapes.c (Core B) ---- */

/* The shape's outline path in canvas units (placement rect, rotation and flips applied). */
fz_path* spdf_paint_shape_path(fz_context* ctx, const spdf_paint_placement* place,
                               const spdf_paint_shape_params* shape);
/* Fill then outline into dest through ctm; textured styles mask the brush textures with the path. */
int spdf_paint_shape_draw(spdf_paint_doc* doc, const spdf_paint_placement* place, const spdf_paint_shape_params* shape,
                          fz_matrix ctm, fz_pixmap* dest, fz_irect clip, float opacity);
/* Rotated bounds including the outline's width (and an arrowhead). */
spdf_rect spdf_paint_shape_bounds(const spdf_paint_placement* place, const spdf_paint_shape_params* shape);
spdf_paint_shape spdf_paint_shape_from_name(const char* name); /* SPDF_PAINT_SHAPE_COUNT when unknown */
const char* spdf_paint_shape_name(spdf_paint_shape shape);
/* Moves and scales a shape's own points (line, arrow line, curve, polygon) and a callout's tail, all kept in canvas
 * units, from one placement rect to another: object.move and object.transform call it with the old and new rect
 * before setting the new one. Rotation and flips need nothing: they apply about the rect's centre when drawn. */
void spdf_paint_shape_fit(spdf_paint_shape_params* shape, spdf_rect from, spdf_rect to);

/* ---- Implemented by spdf_paint_text.c (Core B) ---- */

int spdf_paint_text_draw(spdf_paint_doc* doc, const spdf_paint_placement* place, const spdf_paint_text_params* text,
                         fz_matrix ctm, fz_pixmap* dest, fz_irect clip, float opacity);
/* The box a growing text box needs for its text (width and height in canvas units). */
int spdf_paint_text_measure(spdf_paint_doc* doc, const spdf_paint_text_params* text, float max_width, float* width,
                            float* height);
/* The face for (family, bold, italic): through the frontend's resolver, else a built-in substitute. Records the
 * choice in text->resolved_font. Dropped by the caller. */
fz_font* spdf_paint_text_font(spdf_paint_doc* doc, spdf_paint_text_params* text);
/* Frees doc->text_cache (the fonts loaded for this canvas's text objects): spdf_paint_close calls it first. */
void spdf_paint_text_cache_drop(spdf_paint_doc* doc);

/* ---- Implemented by spdf_paint_transform.c (Core A), used by handlers and the bridge ---- */

/* Scales a pixmap to w x h (Lanczos down, bilinear up). New pixmap. */
fz_pixmap* spdf_paint_scale_pixmap(fz_context* ctx, const fz_pixmap* src, int w, int h);
/* Rotates by any angle about its centre into a pixmap big enough for the result; transparent corners. */
fz_pixmap* spdf_paint_rotate_pixmap(fz_context* ctx, const fz_pixmap* src, float degrees);

/* What a layer shows (canvas units): an object's bounds, the whole canvas for a drawing (spdf_paint_doc_util.c). */
spdf_rect spdf_paint_layer_box(spdf_paint_doc* doc, spdf_paint_layer* layer);

/* ---- spdf_paint_live.c: a stroke being drawn ---- */

/* Puts back what a stroke being drawn changed and forgets it (any change but its own release, undo, closing). */
void spdf_paint_live_settle(spdf_paint_doc* doc);
/* paint.stroke: when it is the stroke being drawn, lays it as shown (*status set) and returns 1; else settles, 0. */
int spdf_paint_live_lay(spdf_paint_doc* doc, spdf_paint_layer* layer, const spdf_paint_stroke_args* args,
                        spdf_rect* damage, spdf_paint_status* status);
/* An object layer the stroke being drawn changes (a pen line cut, a line the whole-line eraser takes), drawn as it
 * will be: returns 1 when it drew it (or drew nothing: the line goes), 0 to draw the object as it is. */
/* The box of pixels with any alpha (raster pixels, inside `within`), empty when none: what a PDF page's drawing
 * layer writes. While a stroke is drawn into a PDF page's layer, that box as it is now (1), else 0. */
fz_irect spdf_paint_pixels_used(const fz_pixmap* pixels, fz_irect within);
int spdf_paint_live_used(const spdf_paint_doc* doc, const spdf_paint_layer* layer, fz_irect* used);
int spdf_paint_live_draw_object(spdf_paint_doc* doc, const spdf_paint_layer* layer, fz_matrix ctm, fz_pixmap* dest,
                                fz_irect clip, float opacity);

/* ---- Implemented by spdf_paint_pdf.c (PDF), called by Core A ---- */

/* The page itself into dest (the locked Background) at ctm: render only, never a change. */
int spdf_paint_pdf_draw_page(spdf_paint_doc* doc, fz_matrix ctm, fz_pixmap* dest, fz_irect clip, int dark);
/* A Fill & Sign item or another reader's annotation, drawn from its appearance stream. */
int spdf_paint_pdf_draw_annotation(spdf_paint_doc* doc, const spdf_paint_object* object, fz_matrix ctm,
                                   fz_pixmap* dest, fz_irect clip, float opacity);
/* Marks what must be written on the next spdf_paint_pdf_write_back (called by Core A after every change on a PDF
 * page canvas, including undo and redo). */
void spdf_paint_pdf_note_change(spdf_paint_doc* doc, spdf_paint_layer* layer);
void spdf_paint_pdf_note_order(spdf_paint_doc* doc);
/* Frees what the bridge keeps for a PDF page canvas (spdf_paint_close calls it first; harmless on other canvases). */
void spdf_paint_pdf_close(spdf_paint_doc* doc);

#ifdef __cplusplus
}
#endif
