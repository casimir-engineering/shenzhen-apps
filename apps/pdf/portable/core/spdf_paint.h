#pragma once
/* Annotate's canvas: every tool of docs/plans/annotate.md on pictures, blank canvases and PDF pages, in plain C on
 * MuPDF (no AppKit). The Mac, GTK and Windows frontends drive it through ONE entry point, spdf_paint_apply, with the
 * JSON operations of § 6; the rest of this header is what a frontend needs around it: making and closing canvases,
 * drawing them, history, saving, and the PDF page bridge.
 *
 * Who implements what (§ 9): spdf_paint_doc.c, _ops.c, _history.c, _file.c, _transform.c (Core A); _brush.c, _fill.c,
 * _shapes.c, _text.c (Core B); _pdf.c (PDF); _schema.c holds the operation schema and table (wave 0).
 *
 * Coordinates. A picture or blank canvas is measured in its own pixels, origin top-left, y down. A PDF page canvas is
 * measured in PDF points from the page's top-left corner as displayed (rotation applied, the same page space as
 * spdf_fill_items.h); its raster layers hold 2 pixels per point. "Canvas units" below means one or the other.
 *
 * Pixels. Every buffer this header hands out is premultiplied RGBA8, sRGB, rows top to bottom (spdf_bitmap from
 * shenzhen_pdf_core.h; free with spdf_free_bitmap). Colours in and out of operations are "#RRGGBB" or "#RRGGBBAA",
 * not premultiplied; spdf_paint_color below is the same thing as a number, 0xRRGGBBAA.
 *
 * Threading. A canvas belongs to one thread at a time, like spdf_document (the Mac uses the main thread). A PDF page
 * canvas borrows its spdf_document's fz_context and so follows that document's thread. The schema calls are safe from
 * any thread after the first spdf_paint_schema() returned.
 *
 * Launch. Nothing here runs until a frontend calls it: no static initialiser, no font or file touched before then. */
#include "shenzhen_pdf_core.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_PAINT_SCHEMA_VERSION 1
#define SPDF_PAINT_FILE_VERSION 2        /* .szpaint manifest "version" (1: before layers held objects) */
#define SPDF_PAINT_DEFAULT_SIZE 1000     /* File > New Canvas: 1000 x 1000 px */
#define SPDF_PAINT_MAX_SIDE 16384        /* canvas handles and canvas.resize: at most 16384 x 16384 */
#define SPDF_PAINT_MAX_PIXELS 268435456u /* ... and 268 M pixels */
#define SPDF_PAINT_HISTORY_CAP ((size_t)1 << 30) /* 1 GB of history per canvas, oldest steps dropped first */
/* /NM of every annotation Annotate writes into a PDF that Fill & Sign did not already name (spdf_fill_items.h):
 * spdf-annotate-layer-<uuid> for a drawing layer, spdf-annotate-<kind>-<uuid> for an object. */
#define SPDF_PAINT_NM_PREFIX "spdf-annotate-"
#define SPDF_PAINT_LAYER_NM_PREFIX "spdf-annotate-layer-"
/* The private dictionary key on those annotations holding their editing parameters (§ 5 PDFs). */
#define SPDF_PAINT_PDF_KEY "SPDFAnnotate"

typedef struct spdf_paint_doc spdf_paint_doc; /* one canvas: a picture, a blank canvas or one PDF page */
typedef uint32_t spdf_paint_color;            /* 0xRRGGBBAA, not premultiplied */
typedef uint32_t spdf_paint_id;               /* a layer or object id, unique in its canvas, never reused; 0 = none */

/* What a canvas is. A text document (Markdown, plain text, EPUB...) never gets a canvas: the frontend answers its
 * operations itself with spdf_paint_check_op, which refuses all but doc.save_as_pdf with needs_pdf. */
typedef enum spdf_paint_doc_kind {
    SPDF_PAINT_DOC_PICTURE = 1,  /* a picture file: its pixels are the Background, and every tool can change them */
    SPDF_PAINT_DOC_CANVAS = 2,   /* File > New Canvas, or a .szpaint project */
    SPDF_PAINT_DOC_PDF = 4,      /* one PDF page: its Background is the page itself, locked */
    SPDF_PAINT_DOC_TEXT = 8      /* a text document (no canvas; used in the operation table only) */
} spdf_paint_doc_kind;
#define SPDF_PAINT_DOC_RASTER (SPDF_PAINT_DOC_PICTURE | SPDF_PAINT_DOC_CANVAS)
#define SPDF_PAINT_DOC_ANY_CANVAS (SPDF_PAINT_DOC_PICTURE | SPDF_PAINT_DOC_CANVAS | SPDF_PAINT_DOC_PDF)

/* Return codes. Every call returns SPDF_PAINT_OK or one of these; the JSON answer of an operation carries the
 * matching "error" string (spdf_paint_status_code) and a plain sentence for the person or agent. */
typedef enum spdf_paint_status {
    SPDF_PAINT_OK = 0,
    SPDF_PAINT_ERR_NOT_IMPLEMENTED = -1, /* "not_implemented": wave 0 stubs */
    SPDF_PAINT_ERR_INVALID_JSON = -2,    /* "invalid_json" */
    SPDF_PAINT_ERR_UNKNOWN_OP = -3,      /* "unknown_op" */
    SPDF_PAINT_ERR_INVALID_ARGUMENT = -4,/* "invalid_argument": fails the operation's argument schema */
    SPDF_PAINT_ERR_PAGE_LOCKED = -5,     /* "page_locked": "The page itself can't be changed." */
    SPDF_PAINT_ERR_NEEDS_PDF = -6,       /* "needs_pdf": "Save this document as a PDF to annotate it." */
    SPDF_PAINT_ERR_PDF_ONLY = -7,        /* "pdf_only": a form operation on a picture or canvas */
    SPDF_PAINT_ERR_NOT_FOUND = -8,       /* "not_found": no layer or object with that id */
    SPDF_PAINT_ERR_TOO_LARGE = -9,       /* "too_large": over SPDF_PAINT_MAX_SIDE / _MAX_PIXELS */
    SPDF_PAINT_ERR_NOTHING_SELECTED = -10, /* "nothing_selected" */
    SPDF_PAINT_ERR_NOTHING_TO_UNDO = -11,  /* "nothing_to_undo" (also redo) */
    SPDF_PAINT_ERR_NO_SIGNATURE = -12,   /* "no_signature": form.signature_place, none saved; agents never draw one */
    SPDF_PAINT_ERR_LOCKED = -13,         /* "locked": another reader's annotation, shown but not editable */
    SPDF_PAINT_ERR_IO = -14,             /* "io_error": a file could not be read or written */
    SPDF_PAINT_ERR_NO_MEMORY = -15,      /* "no_memory" */
    SPDF_PAINT_ERR_FRONTEND = -16,       /* "frontend_only": the frontend answers this operation (route below) */
    SPDF_PAINT_ERR_FAILED = -17          /* "failed": anything else; the message says what */
} spdf_paint_status;

/* "not_implemented", "page_locked", ... for a status; "ok" for SPDF_PAINT_OK. Static strings. */
const char* spdf_paint_status_code(spdf_paint_status status);

/* ---------------------------------------------------------------------------------------------------------------
 * Canvas lifecycle (spdf_paint_doc.c; PDF pages in spdf_paint_pdf.c)
 * --------------------------------------------------------------------------------------------------------------- */

/* Pixels handed in by a frontend: a decoded picture, a pasted picture. Premultiplied RGBA8 unless `straight`. */
typedef struct spdf_paint_pixels {
    int width, height, stride;
    const unsigned char* rgba;
    int straight; /* 1: alpha not premultiplied (ImageIO gives premultiplied, cJSON PNGs give straight) */
} spdf_paint_pixels;

/* File > New Canvas (canvas.new): width x height, filled with `background` (0x00000000 = transparent). One raster
 * layer, "Background". NULL on failure with err. */
spdf_paint_doc* spdf_paint_new_canvas(int width, int height, spdf_paint_color background, char* err, size_t err_len);

/* New Canvas's sizes (spdf_paint_presets.c): name (canvas.new's `preset`), label, group ("Paper", "Screen", ...),
 * words a search also matches, and the size, in millimetres for paper (pixels at the canvas's resolution) or pixels. */
typedef struct spdf_paint_canvas_preset {
    const char* name;
    const char* label;
    const char* group;
    const char* aliases;
    double width, height;
    int paper;
} spdf_paint_canvas_preset;
#define SPDF_PAINT_DEFAULT_PPI 300.0 /* paper's resolution when none is given */
enum { SPDF_PAINT_AS_LISTED = 0, SPDF_PAINT_PORTRAIT = 1, SPDF_PAINT_LANDSCAPE = 2 };
const spdf_paint_canvas_preset* spdf_paint_canvas_presets(size_t* count);
/* Their names, comma-separated, for help texts. */
const char* spdf_paint_canvas_preset_names(void);
/* By name or label, ignoring case, spaces and underscores ("A4", "full_hd"); NULL if none. */
const spdf_paint_canvas_preset* spdf_paint_canvas_preset_named(const char* name);
/* Its pixels at `ppi` (paper only; <= 0: SPDF_PAINT_DEFAULT_PPI), turned for `orientation` and held to the limits. */
void spdf_paint_canvas_preset_pixels(const spdf_paint_canvas_preset* preset, double ppi, int orientation, int* width,
                                     int* height);
/* A picture as decoded by the frontend (SPDFMacAnnotateImageIO on the Mac): its pixels become the "Background" layer,
 * which every tool may change. dpi 0 means 72. has_alpha 0 tells the core the format has no alpha, so erasing and
 * lifting there leave Color 2 (§ 2 Eraser, Rectangular selection). */
spdf_paint_doc* spdf_paint_open_picture(const spdf_paint_pixels* pixels, float dpi, int has_alpha, char* err,
                                        size_t err_len);
/* Frees the canvas and its history. NULL is fine. A PDF page canvas must be closed before its spdf_document. */
void spdf_paint_close(spdf_paint_doc* doc);

spdf_paint_doc_kind spdf_paint_kind(const spdf_paint_doc* doc);
/* Canvas size in canvas units (pixels, or points on a PDF page) and its resolution (pictures: dots per inch). */
void spdf_paint_size(const spdf_paint_doc* doc, int* width, int* height);
float spdf_paint_dpi(const spdf_paint_doc* doc);

/* ---------------------------------------------------------------------------------------------------------------
 * Operations (spdf_paint_ops.c; the schema and table in spdf_paint_schema.c)
 * --------------------------------------------------------------------------------------------------------------- */

/* What the frontend worked out before an operation flagged SPDF_PAINT_OP_NEEDS_INPUT, NULL members when nothing:
 * - picture: picture.add {path} or {clipboard:true}, decoded by the frontend (HEIC, RAW and the pasteboard are not
 *   the core's); the core then ignores path and clipboard. {png_base64} needs no input.
 * - mask: image.remove_background, the subject mask (macOS Vision on the Mac) of the flattened scope the frontend
 *   was given by doc.render: one byte per pixel, mask_width x mask_height, 255 = subject (kept), 0 = made
 *   transparent. The core scales it onto the scope's pixels. */
typedef struct spdf_paint_apply_input {
    const spdf_paint_pixels* picture;
    const unsigned char* mask;
    int mask_width, mask_height, mask_stride;
} spdf_paint_apply_input;

/* Applies one operation, {"op": "<name>", ...arguments} (§ 6), to `doc`: validates it against the schema, applies it,
 * records it on the canvas's history when the op is SPDF_PAINT_OP_UNDOABLE, and writes the JSON answer to
 * *result_json ({"ok":true, ...} or {"ok":false,"error":"<code>","message":"<plain sentence>"}; free with
 * spdf_paint_free). *result_json is always set, even on failure. Returns the status the answer carries.
 * Every operation the core can carry out runs here, whatever its route (history.undo on a picture included); one that
 * needs the frontend (files, clipboard, window, Fill & Sign's form code) answers SPDF_PAINT_ERR_FRONTEND. */
spdf_paint_status spdf_paint_apply(spdf_paint_doc* doc, const char* json, char** result_json);
spdf_paint_status spdf_paint_apply_ex(spdf_paint_doc* doc, const char* json, const spdf_paint_apply_input* input,
                                      char** result_json);
/* Checks an operation without a canvas: valid JSON, a known op, arguments that fit its schema, and a document kind
 * that accepts it (a text document: needs_pdf for all but doc.save_as_pdf; a picture: pdf_only for form.*; a PDF:
 * page_locked for canvas.resize and canvas.properties). The frontend calls it before routing anything, so every
 * surface answers the same errors. On success *result_json is NULL and *op_out (if given) is the op's table entry;
 * on failure *result_json is the error answer. */
typedef struct spdf_paint_op_info spdf_paint_op_info;
spdf_paint_status spdf_paint_check_op(const char* json, spdf_paint_doc_kind kind, const spdf_paint_op_info** op_out,
                                      char** result_json);
/* {"ok":false,"error":code,"message":message} as a new string (free with spdf_paint_free). */
char* spdf_paint_error_json(spdf_paint_status status, const char* message);
void spdf_paint_free(void* p);

/* ---------------------------------------------------------------------------------------------------------------
 * The operation schema and table (spdf_paint_schema.c)
 * --------------------------------------------------------------------------------------------------------------- */

typedef enum spdf_paint_op_flags {
    SPDF_PAINT_OP_UNDOABLE = 1 << 0,  /* recorded on the history: one Cmd+Z undoes it */
    SPDF_PAINT_OP_READ_ONLY = 1 << 1, /* changes nothing (color.pick, doc.state, doc.render, form.state) */
    SPDF_PAINT_OP_UI_STATE = 1 << 2,  /* changes what the window shows or the tools hold, not the picture; never on the
                                         history (view.*, tool.choose, mode.set, colors.set, palette.set_custom, and
                                         the select.* that only draw the ants, as in Paint) */
    SPDF_PAINT_OP_NEEDS_PAGE = 1 << 3,/* on a PDF it takes "page" (1-based) and acts on that page's canvas */
    SPDF_PAINT_OP_NO_TARGET = 1 << 4, /* needs no open document (canvas.new) */
    SPDF_PAINT_OP_NEEDS_INPUT = 1 << 5/* the frontend may have to work something out first (spdf_paint_apply_input) */
} spdf_paint_op_flags;

/* Who carries an operation out once spdf_paint_check_op accepted it (the Mac: -applyOperation:tab:completion:). */
typedef enum spdf_paint_route {
    SPDF_PAINT_ROUTE_CANVAS = 0,     /* spdf_paint_apply on the tab's canvas (a picture's, or the named PDF page's) */
    SPDF_PAINT_ROUTE_FILL_ON_PDF = 1,/* on a PDF the existing Fill & Sign code (pen.add, arrow.add, erase.lines and
                                        form.*), elsewhere spdf_paint_apply */
    SPDF_PAINT_ROUTE_FRONTEND = 2    /* the frontend: files, the clipboard, tabs, the window, and the tab-wide history
                                        (doc.save*, doc.copy, mode.set, view.*, tool.choose, canvas.new, and
                                        history.undo/redo, which on a PDF span pages and Fill & Sign steps; on a picture
                                        the frontend passes them on to spdf_paint_apply) */
} spdf_paint_route;

struct spdf_paint_op_info {
    const char* name;      /* "paint.stroke" */
    const char* family;    /* "Pixels": the § 6 table row it belongs to */
    unsigned flags;        /* spdf_paint_op_flags */
    unsigned kinds;        /* spdf_paint_doc_kind bits that accept it */
    spdf_paint_route route;
    const char* summary;   /* one plain sentence, for help and tool descriptions */
};

/* The whole § 6 list as one JSON Schema document (draft 2020-12): {"$schema", "$id", "version", "$defs": the shared
 * types, "type":"object", "required":["op"], "properties":{"op":{"enum":[every name]}}, "operations": {name: an
 * object schema of that operation's arguments, plus "description" (the table's summary), "x-family", "x-kinds"
 * (["picture","canvas","pdf","text"]), "x-route" ("canvas" | "fill_on_pdf" | "frontend"), "x-undoable",
 * "x-readOnly", "x-uiState", "x-needsPage"}}. A validator checks "op", then operations[op].
 * `szpdf annotate schema`, the assistant's tool descriptions and the MCP server are generated from it. Built on the
 * first call from the argument schemas in spdf_paint_schema.c and the operation table, then kept for the life of the
 * process (make that first call on one thread); never NULL. */
const char* spdf_paint_schema(void);
/* The operation table, in § 6 order. */
int spdf_paint_op_count(void);
const spdf_paint_op_info* spdf_paint_op_at(int index);
const spdf_paint_op_info* spdf_paint_op_find(const char* name); /* NULL when unknown */
/* One operation's entry of "operations" as new JSON text ($defs references left as they are), or NULL when unknown;
 * `szpdf annotate schema <op>`. Free with spdf_paint_free. */
char* spdf_paint_op_schema_json(const char* name);
/* "picture", "canvas", "pdf", "text" for one kind bit; NULL otherwise. */
const char* spdf_paint_kind_name(spdf_paint_doc_kind kind);

/* ---------------------------------------------------------------------------------------------------------------
 * Drawing the canvas (spdf_paint_doc.c composites; Core B draws strokes, shapes and text into it)
 * --------------------------------------------------------------------------------------------------------------- */

typedef enum spdf_paint_render_flags {
    SPDF_PAINT_RENDER_SKIP_LOCKED_BACKGROUND = 1 << 0, /* a PDF page: everything above the page, which the reader
                                                          already draws (the overlay case) */
    SPDF_PAINT_RENDER_NEAREST = 1 << 1,      /* scale > 1: sharp pixels (nearest neighbour), the canvas above 100 % */
    SPDF_PAINT_RENDER_HIDE_SELECTION = 1 << 2,/* leave out a lifted selection being dragged (the view draws it live) */
    SPDF_PAINT_RENDER_DARK_PAGE = 1 << 3,    /* a PDF page's Background drawn in the reading theme (screen only) */
    SPDF_PAINT_RENDER_SELECTED_ONLY = 1 << 4,/* only what the pixel selection covers (a lasso's shape): Copy */
    SPDF_PAINT_RENDER_DARK_KEEP_IMAGES = 1 << 5 /* spdf_paint_render_placed, dark: pictures keep their colours */
} spdf_paint_render_flags;

typedef struct spdf_paint_render_options {
    spdf_rect region;               /* canvas units; an empty rect means the whole canvas */
    float scale;                    /* output pixels per canvas unit; 0 means 1 */
    unsigned flags;                 /* spdf_paint_render_flags */
    const spdf_paint_id* layers;    /* only these layers and objects (doc.render {layers}); NULL: every visible one */
    int layer_count;
    spdf_paint_color matte;         /* 0: keep transparency; else composited onto this opaque colour */
} spdf_paint_render_options;

/* The composite of `region` at `scale` into a new premultiplied RGBA bitmap of ceil(region size x scale) pixels:
 * visible layers and objects, bottom to top, opacity applied; never the checkerboard, the ants or handles (the
 * frontend draws those). Pictures and canvases are served from the 256 x 256 tile cache at scale 1. */
spdf_paint_status spdf_paint_render(spdf_paint_doc* doc, const spdf_paint_render_options* options, spdf_bitmap* out,
                                    char* err, size_t err_len);
/* A layer's or object's picture for the Layers panel, fitted inside max_side x max_side, aspect kept. A PDF page's
 * Background row shows the page (rendered at that size). */
spdf_paint_status spdf_paint_layer_thumbnail(spdf_paint_doc* doc, spdf_paint_id layer, int max_side, spdf_bitmap* out,
                                             char* err, size_t err_len);
/* Where the canvas changed since the last call (canvas units), so a view redraws only those tiles: 1 and *changed
 * set, or 0 when nothing changed. A change of size or of every layer reports the whole canvas. */
int spdf_paint_take_damage(spdf_paint_doc* doc, spdf_rect* changed);
/* The same, counted apart since the last call (the canvas view takes the other as the change happens): what a PDF
 * page's write back changes, so the reader draws only that part of the page again. */
int spdf_paint_take_written_damage(spdf_paint_doc* doc, spdf_rect* changed);
/* Live placement (spdf_paint_preview.c): a region (options->region, ->scale and ->flags; layers ignored) drawn as
 * spdf_paint_render does, with each listed object at a new box (rect, canvas units, as object.transform's) instead of
 * its own, and turned when `turns` is set (rotation: object.transform's), nothing changed: a resize, a move or a
 * rotation while the handle is held. On a PDF page what the document already holds is drawn from its annotations, as
 * the reader draws the page; with SPDF_PAINT_RENDER_DARK_PAGE the whole region is recoloured as the reader's dark
 * theme recolours a page, its pictures kept as they are with SPDF_PAINT_RENDER_DARK_KEEP_IMAGES. */
typedef struct spdf_paint_placed { spdf_paint_id id; spdf_rect rect; int turns; double rotation; } spdf_paint_placed;
spdf_paint_status spdf_paint_render_placed(spdf_paint_doc* doc, const spdf_paint_render_options* options,
                                           const spdf_paint_placed* placed, int count, spdf_bitmap* out, char* err,
                                           size_t err_len);
/* The topmost visible object under (x, y) in canvas units, within slop units of its line or box; 0 when none (Core A,
 * for the Select tool's clicks and right-click menus). */
spdf_paint_id spdf_paint_object_at(spdf_paint_doc* doc, float x, float y, float slop);
/* Bumped by every change (operations, undo, redo, a load). */
uint64_t spdf_paint_generation(const spdf_paint_doc* doc);

/* ---------------------------------------------------------------------------------------------------------------
 * History and dirty state (spdf_paint_history.c)
 * --------------------------------------------------------------------------------------------------------------- */

/* Undo or redo `steps` operations of this canvas. A tab with several canvases (a PDF's pages) keeps the order of its
 * steps itself and calls these on the right canvas (SPDFMacAnnotateSession). Returns NOTHING_TO_UNDO when there is
 * none; damage and generation follow. */
spdf_paint_status spdf_paint_undo(spdf_paint_doc* doc, int steps);
spdf_paint_status spdf_paint_redo(spdf_paint_doc* doc, int steps);
int spdf_paint_can_undo(const spdf_paint_doc* doc);
int spdf_paint_can_redo(const spdf_paint_doc* doc);
/* The op name of the step Cmd+Z would undo ("paint.stroke"), for Edit > Undo's title; NULL when none. Static/owned. */
const char* spdf_paint_undo_name(const spdf_paint_doc* doc);
const char* spdf_paint_redo_name(const spdf_paint_doc* doc);
/* The last undoable operation's JSON, for Edit > Repeat (F4); NULL when none. Owned by the canvas. */
const char* spdf_paint_last_operation(const spdf_paint_doc* doc);
/* Lowers the history cap (bytes) for this canvas; the default is SPDF_PAINT_HISTORY_CAP. */
void spdf_paint_set_history_cap(spdf_paint_doc* doc, size_t bytes);
size_t spdf_paint_history_bytes(const spdf_paint_doc* doc);

/* Changed since it was opened or last marked saved (undoing back to that point makes it clean again). */
int spdf_paint_is_dirty(const spdf_paint_doc* doc);
void spdf_paint_mark_saved(spdf_paint_doc* doc);

/* ---------------------------------------------------------------------------------------------------------------
 * Files (spdf_paint_file.c)
 * --------------------------------------------------------------------------------------------------------------- */

/* The flattened picture to write into the file: the composite at scale 1 over the whole canvas, visible layers and
 * objects only, opacity applied. matte 0 keeps alpha (PNG, TIFF, HEIC); JPEG and BMP pass 0xFFFFFFFF (white, as
 * § Decisions JPEG says). Premultiplied RGBA. */
spdf_paint_status spdf_paint_flatten(spdf_paint_doc* doc, spdf_paint_color matte, spdf_bitmap* out, char* err,
                                     size_t err_len);
/* .szpaint, version SPDF_PAINT_FILE_VERSION: a ZIP (fz_zip_writer) of manifest.json (canvas size, dpi, layers bottom
 * to top with kind, name, visibility, opacity, lock, each with its objects' kinds and parameters) and one PNG per layer
 * with pixels and Picture object (§ 5). Written to a temporary file beside `path`, then swapped in. A PDF page canvas
 * is refused. Version 1 projects (one object per layer) are read into the layers model. */
spdf_paint_status spdf_paint_write_project(spdf_paint_doc* doc, const char* path, char* err, size_t err_len);
/* Opens a .szpaint as a canvas (kind SPDF_PAINT_DOC_CANVAS), clean, with an empty history. */
spdf_paint_doc* spdf_paint_read_project(const char* path, char* err, size_t err_len);
/* The same bytes as a buffer (Collection keeps them; Save As writes them). *out is spdf_paint_free'd. */
spdf_paint_status spdf_paint_project_bytes(spdf_paint_doc* doc, unsigned char** out, size_t* out_len, char* err,
                                           size_t err_len);
/* Writes doc.render's PNG (the same pixels as spdf_paint_render) to `path`. */
spdf_paint_status spdf_paint_render_png(spdf_paint_doc* doc, const spdf_paint_render_options* options,
                                        const char* path, char* err, size_t err_len);

/* ---------------------------------------------------------------------------------------------------------------
 * Fonts (spdf_paint_text.c)
 * --------------------------------------------------------------------------------------------------------------- */

/* Text objects name a font family ("Helvetica Neue") and bold/italic. The core asks the frontend where that face's
 * file is: the resolver writes a path into path_out and the face index inside a collection into *face_index, and
 * returns 1, or 0 when it has no such font (the core then uses MuPDF's built-in Helvetica/Times/Courier substitute and
 * records it in the object). The Mac resolver uses CoreText (SPDFMacAnnotateImageIO). Set once, before the first text
 * object is drawn; NULL removes it. */
typedef int (*spdf_paint_font_resolver)(void* user, const char* family, int bold, int italic, char* path_out,
                                        size_t path_cap, int* face_index);
void spdf_paint_set_font_resolver(spdf_paint_font_resolver resolver, void* user);

/* ---------------------------------------------------------------------------------------------------------------
 * PDF page bridge (spdf_paint_pdf.c)
 * --------------------------------------------------------------------------------------------------------------- */

/* A PDF page as a canvas: the page is the locked Background (rendered, never changed), then its annotations read into
 * layers and objects in /Annots order (back to front): ours from /SPDFAnnotate, Fill & Sign's text, marks, signatures,
 * pen lines and arrows from their /NM as objects of the same model, other readers' annotations as locked objects that
 * keep their depth. Reads the main-thread document `pdf` (borrowed: it must outlive the canvas); page_index from 0.
 * The canvas is clean. */
spdf_paint_doc* spdf_paint_open_pdf_page(spdf_document* pdf, int page_index, char* err, size_t err_len);
int spdf_paint_pdf_page_index(const spdf_paint_doc* doc); /* -1 when the canvas is not a PDF page */
/* Writes every layer and object changed since the last write back into the page as the annotations of § 5 (a Stamp
 * per drawing layer, Ink, Square, Circle, Polygon, FreeText, Stamp), in depth order as /Annots order, each with its
 * /SPDFAnnotate parameters, through the Fill & Sign core's writing path (spdf_fill_*) for its own items. Does not save:
 * the caller saves with spdf_save_document in Fill & Sign's commit cycle. *pages_changed (may be NULL) is 1 when the
 * page's annotations changed. */
spdf_paint_status spdf_paint_pdf_write_back(spdf_paint_doc* doc, int* pages_changed, char* err, size_t err_len);
/* The page's annotations changed under the canvas (Fill & Sign wrote or undid an item, the file was reloaded): reads
 * them again, keeping ids of the objects still there and the drawing layers' pixels. */
spdf_paint_status spdf_paint_pdf_reload(spdf_paint_doc* doc, char* err, size_t err_len);
/* The document a PDF page canvas reads (NULL for other canvases): after a move to a writable copy the tab's document
 * is another one, and its canvases must be opened again on it. */
spdf_document* spdf_paint_pdf_document(const spdf_paint_doc* doc);
/* The id of the object written as /NM `nm` (a Fill & Sign item's name or comb group, or one of ours), 0 when none:
 * the answer of an operation the Fill & Sign code carried out (pen.add -> its new pen line's id). */
spdf_paint_id spdf_paint_pdf_object_for_name(const spdf_paint_doc* doc, const char* nm);
/* On a PDF page canvas: 1 when operation `op` (a § 6 name) has nothing to act on but the page itself here (canvas.resize,
 * canvas.properties, image.crop always; image.clear with no drawing layer active; the whole-picture image commands
 * with nothing added; select.lift, select.delete and image.remove_background with nothing to take them), so the UI
 * greys the command with "The page itself can't be changed." and the core answers page_locked. 0 elsewhere. */
int spdf_paint_pdf_op_locked(const spdf_paint_doc* doc, const char* op);
/* Whether the page holds anything Annotate wrote (an /NM starting SPDF_PAINT_NM_PREFIX), without loading it; for the
 * reader's "has added items" checks. 1, 0, or -1 with err. */
int spdf_paint_pdf_page_has_items(spdf_document* pdf, int page_index, char* err, size_t err_len);
/* Removes everything Annotate wrote on every page (Edit > Remove Everything Added with Annotate, with Fill & Sign's
 * own removal); the caller saves. */
spdf_paint_status spdf_paint_pdf_remove_all(spdf_document* pdf, char* err, size_t err_len);
/* The same with undo: *removed (may be NULL when nothing was there) keeps what was removed, independent of `pdf`
 * (it survives a move to a writable copy); pages (0-based, at most max_pages) and *page_count say which pages
 * changed. spdf_paint_pdf_restore_removed puts it all back at its depth; the caller saves. */
typedef struct spdf_paint_pdf_removed spdf_paint_pdf_removed;
spdf_paint_status spdf_paint_pdf_remove_all_ex(spdf_document* pdf, spdf_paint_pdf_removed** removed, int* pages,
                                               int max_pages, int* page_count, char* err, size_t err_len);
spdf_paint_status spdf_paint_pdf_restore_removed(spdf_document* pdf, const spdf_paint_pdf_removed* removed, int* pages,
                                                 int max_pages, int* page_count, char* err, size_t err_len);
void spdf_paint_pdf_free_removed(spdf_paint_pdf_removed* removed);

#ifdef __cplusplus
}
#endif
