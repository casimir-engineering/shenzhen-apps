/* Annotate's operations as data (docs/plans/annotate.md § 6): the argument schema of every operation as JSON
 * Schema text, and the operation table (family, flags, document kinds, route, summary). spdf_paint_schema_build.c
 * builds the one JSON Schema document from the two (spdf_paint_schema). A new operation is one table row plus one
 * "operations" entry here and a handler in spdf_paint_handlers.h; it then appears in szpdf, the assistant and MCP.
 *
 * The argument schemas hold only "properties", "required" and "anyOf" (and "x-include" / "x-anyOf", which copy a
 * block of k_shared in); the builder adds "type", "description" (the table's summary), "op" as a const, "page" for
 * the operations that act on a PDF page, "additionalProperties": false and the x- fields. Sizes are canvas units:
 * pixels on pictures and canvases, points on PDF pages. Opacity and tolerance are percents. Colours are "#RRGGBB" or
 * "#RRGGBBAA". */
#include "spdf_paint_handlers.h"

#include <string.h>

/* JSON written as JSON: the preprocessor turns the tokens into one string literal (quotes and backslashes escaped,
 * whitespace collapsed). Rules: no parenthesis outside a string, no macro names, one JSON string per C line. */
#define SPDF_JSON(...) #__VA_ARGS__

const char spdf_paint_schema_defs_text[] = SPDF_JSON(
"$defs": {
  "page": {"type": "integer", "minimum": 1, "description": "PDF page, from 1"},
  "id": {"type": "integer", "minimum": 1, "description": "a layer or object id from doc.state or an answer"},
  "ids": {"type": "array", "items": {"$ref": "#/$defs/id"}, "minItems": 1},
  "color": {"type": "string", "pattern": "^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"},
  "colorOrTransparent": {"anyOf": [{"const": "transparent"}, {"$ref": "#/$defs/color"}]},
  "point": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 3,
    "description": "[x, y] or [x, y, pressure 0-1], from the top-left corner, y down"},
  "points": {"type": "array", "items": {"$ref": "#/$defs/point"}, "minItems": 1},
  "rect": {"type": "object", "additionalProperties": false, "required": ["x", "y", "w", "h"],
    "properties": {"x": {"type": "number"}, "y": {"type": "number"},
      "w": {"type": "number", "exclusiveMinimum": 0}, "h": {"type": "number", "exclusiveMinimum": 0}}},
  "scope": {"enum": ["auto", "image", "selection", "object"], "default": "auto",
    "description": "auto: the selection or the selected object if any, else the whole picture"},
  "anchor": {"enum": ["top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom",
    "bottom-right"], "default": "top-left"},
  "style": {"enum": ["none", "solid", "crayon", "marker", "oil", "natural_pencil", "watercolor"]},
  "outline": {"type": "object", "additionalProperties": false,
    "properties": {"style": {"$ref": "#/$defs/style", "default": "solid"},
      "color": {"$ref": "#/$defs/color", "description": "default Color 1"},
      "width": {"type": "number", "minimum": 1, "maximum": 50, "default": 3}}},
  "fill": {"type": "object", "additionalProperties": false,
    "properties": {"style": {"$ref": "#/$defs/style", "default": "none"},
      "color": {"$ref": "#/$defs/color", "description": "default Color 2"}}},
  "shape": {"enum": ["line", "curve", "oval", "rectangle", "rounded_rectangle", "polygon", "triangle",
    "right_triangle", "diamond", "pentagon", "hexagon", "right_arrow", "left_arrow", "up_arrow", "down_arrow",
    "star4", "star5", "star6", "rounded_callout", "oval_callout", "cloud_callout", "heart", "lightning",
    "arrow_line"]},
  "brush": {"enum": ["pencil", "brush", "calligraphy1", "calligraphy2", "airbrush", "oil", "crayon", "marker",
    "natural_pencil", "watercolor", "eraser", "color_eraser"]},
  "depth": {"anyOf": [{"enum": ["front", "forward", "backward", "back"]},
    {"type": "integer", "minimum": 0, "description": "position from the bottom, 0 = just above the Background"}]},
  "opacity": {"type": "number", "minimum": 0, "maximum": 100, "description": "percent"},
  "align": {"enum": ["left", "center", "right"], "default": "left"},
  "tool": {"enum": ["select", "rect_select", "freeform_select", "pen", "arrow", "pencil", "fill", "text_box",
    "eraser", "color_picker", "magnifier", "brush", "calligraphy1", "calligraphy2", "airbrush", "oil", "crayon",
    "marker", "natural_pencil", "watercolor", "shape", "form_text", "form_mark", "form_signature"]},
  "format": {"enum": ["png", "jpeg", "heic", "tiff", "bmp", "gif", "szpaint"]}
});

/* Arguments several operations share, copied into an operation's "properties" by "x-include" (not emitted). */
const char spdf_paint_schema_shared_text[] = SPDF_JSON(
"textProps": {
  "text": {"type": "string"}, "font": {"type": "string", "description": "font family, default the system font"},
  "size": {"type": "number", "minimum": 8, "maximum": 400, "default": 24, "description": "points"},
  "bold": {"type": "boolean", "default": false}, "italic": {"type": "boolean", "default": false},
  "underline": {"type": "boolean", "default": false}, "strikethrough": {"type": "boolean", "default": false},
  "align": {"$ref": "#/$defs/align"}, "color": {"$ref": "#/$defs/color", "description": "default Color 1"},
  "background": {"$ref": "#/$defs/colorOrTransparent", "default": "transparent"}},
"shapeProps": {
  "shape": {"$ref": "#/$defs/shape"}, "rect": {"$ref": "#/$defs/rect"},
  "points": {"$ref": "#/$defs/points",
    "description": "line and arrow_line: the two ends; curve: the ends, then the two bends; polygon: the corners"},
  "rotation": {"type": "number", "default": 0, "description": "degrees, clockwise"},
  "outline": {"$ref": "#/$defs/outline"}, "fill": {"$ref": "#/$defs/fill"},
  "tail": {"$ref": "#/$defs/point", "description": "callouts: where the tail points"}},
"idOrIds": [{"required": ["id"]}, {"required": ["ids"]}]
);

const char spdf_paint_schema_image_text[] = SPDF_JSON(
  "canvas.new": {"properties": {"width": {"type": "integer", "minimum": 1, "maximum": 16384, "default": 1000},
    "height": {"type": "integer", "minimum": 1, "maximum": 16384, "default": 1000},
    "background": {"$ref": "#/$defs/colorOrTransparent", "default": "transparent"}}},
  "canvas.resize": {"required": ["width", "height"],
    "properties": {"width": {"type": "integer", "minimum": 1, "maximum": 16384},
      "height": {"type": "integer", "minimum": 1, "maximum": 16384}, "anchor": {"$ref": "#/$defs/anchor"},
      "fill": {"$ref": "#/$defs/colorOrTransparent", "default": "transparent"}}},
  "canvas.properties": {"properties": {"dpi": {"type": "number", "exclusiveMinimum": 0},
    "blackAndWhite": {"type": "boolean"}}},
  "image.resize": {"anyOf": [{"required": ["width"]}, {"required": ["height"]}, {"required": ["percent"]}],
    "properties": {"width": {"type": "integer", "minimum": 1}, "height": {"type": "integer", "minimum": 1},
      "percent": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
      "keepRatio": {"type": "boolean", "default": true}, "scope": {"$ref": "#/$defs/scope"}}},
  "image.skew": {"properties": {"horizontal": {"type": "number", "minimum": -89, "maximum": 89, "default": 0},
    "vertical": {"type": "number", "minimum": -89, "maximum": 89, "default": 0},
    "scope": {"$ref": "#/$defs/scope"}}},
  "image.rotate": {"required": ["degrees"], "properties": {"degrees": {"type": "number", "description": "clockwise"},
    "scope": {"$ref": "#/$defs/scope"}}},
  "image.flip": {"required": ["axis"], "properties": {"axis": {"enum": ["horizontal", "vertical"]},
    "scope": {"$ref": "#/$defs/scope"}}},
  "image.crop": {"properties": {"rect": {"$ref": "#/$defs/rect", "description": "default the selection's box"}}},
  "image.invert": {"properties": {"scope": {"$ref": "#/$defs/scope"}}},
  "image.clear": {"properties": {}},
  "image.remove_background": {"properties": {"scope": {"$ref": "#/$defs/scope"}}},
  "select.rect": {"required": ["x", "y", "w", "h"],
    "properties": {"x": {"type": "number"}, "y": {"type": "number"},
      "w": {"type": "number", "exclusiveMinimum": 0}, "h": {"type": "number", "exclusiveMinimum": 0}}},
  "select.freeform": {"required": ["points"], "properties": {"points": {"$ref": "#/$defs/points", "minItems": 3}}},
  "select.all": {"properties": {}},
  "select.none": {"properties": {}},
  "select.invert": {"properties": {}},
  "select.delete": {"properties": {}},
  "select.lift": {"properties": {}},
  "select.transparent": {"required": ["on"], "properties": {"on": {"type": "boolean"}}},
  "select.objects": {"required": ["ids"], "properties": {"ids": {"type": "array", "items": {"$ref": "#/$defs/id"}}}}
);

const char spdf_paint_schema_drawing_text[] = SPDF_JSON(
  "pen.add": {"required": ["points"],
    "properties": {"points": {"$ref": "#/$defs/points"}, "color": {"$ref": "#/$defs/color", "default": "#000000"},
      "width": {"type": "number", "minimum": 0.5, "maximum": 100, "default": 2}}},
  "arrow.add": {"required": ["tail", "tip"],
    "properties": {"tail": {"$ref": "#/$defs/point"}, "tip": {"$ref": "#/$defs/point"},
      "color": {"$ref": "#/$defs/color", "default": "#000000"},
      "width": {"type": "number", "minimum": 0.5, "maximum": 100, "default": 2}}},
  "erase.lines": {"required": ["points"],
    "properties": {"points": {"$ref": "#/$defs/points"},
      "size": {"type": "number", "minimum": 1, "maximum": 100, "default": 10}}},
  "paint.stroke": {"required": ["tool", "points"],
    "properties": {"tool": {"$ref": "#/$defs/brush"}, "points": {"$ref": "#/$defs/points"},
      "color": {"$ref": "#/$defs/color", "description": "default Color 1"},
      "size": {"type": "number", "minimum": 1, "maximum": 100,
        "description": "default 1 for the pencil, 4 for the erasers, 5 for brushes"},
      "opacity": {"$ref": "#/$defs/opacity", "default": 100},
      "seed": {"type": "integer", "minimum": 0, "maximum": 4294967295,
        "description": "airbrush and textured brushes: the same seed paints the same pixels"}}},
  "paint.fill": {"required": ["x", "y"],
    "properties": {"x": {"type": "number"}, "y": {"type": "number"},
      "color": {"$ref": "#/$defs/color", "description": "default Color 1"},
      "tolerance": {"type": "number", "minimum": 0, "maximum": 100, "default": 0},
      "contiguous": {"type": "boolean", "default": true}}},
  "color.pick": {"required": ["x", "y"],
    "properties": {"x": {"type": "number"}, "y": {"type": "number"},
      "from": {"enum": ["visible", "layer"], "default": "visible"}}},
  "shape.add": {"required": ["shape"], "anyOf": [{"required": ["rect"]}, {"required": ["points"]}],
    "x-include": ["shapeProps"], "properties": {}},
  "text.add": {"required": ["rect", "text"], "x-include": ["textProps"],
    "properties": {"rect": {"$ref": "#/$defs/rect"}}},
  "picture.add": {"anyOf": [{"required": ["path"]}, {"required": ["clipboard"]}, {"required": ["png_base64"]}],
    "properties": {"path": {"type": "string"}, "clipboard": {"const": true},
      "png_base64": {"type": "string", "contentEncoding": "base64"},
      "rect": {"$ref": "#/$defs/rect",
        "description": "default the top-left of the visible area, at the picture's own size"}}},
  "object.update": {"required": ["id"], "x-include": ["shapeProps", "textProps"],
    "properties": {"id": {"$ref": "#/$defs/id"}, "width": {"type": "number", "minimum": 0.5, "maximum": 100},
      "tip": {"$ref": "#/$defs/point"}}},
  "object.move": {"x-anyOf": "idOrIds", "required": ["dx", "dy"],
    "properties": {"id": {"$ref": "#/$defs/id"}, "ids": {"$ref": "#/$defs/ids"},
      "dx": {"type": "number"}, "dy": {"type": "number"}}},
  "object.transform": {"required": ["id"],
    "properties": {"id": {"$ref": "#/$defs/id"}, "rect": {"$ref": "#/$defs/rect"},
      "rotation": {"type": "number", "description": "degrees, clockwise"},
      "flip": {"enum": ["horizontal", "vertical"]}}},
  "object.order": {"x-anyOf": "idOrIds", "required": ["to"],
    "properties": {"id": {"$ref": "#/$defs/id"}, "ids": {"$ref": "#/$defs/ids"}, "to": {"$ref": "#/$defs/depth"}}},
  "object.merge_down": {"required": ["id"], "properties": {"id": {"$ref": "#/$defs/id"}}},
  "object.duplicate": {"required": ["id"], "properties": {"id": {"$ref": "#/$defs/id"}}},
  "object.delete": {"x-anyOf": "idOrIds",
    "properties": {"id": {"$ref": "#/$defs/id"}, "ids": {"$ref": "#/$defs/ids"}}}
);

const char spdf_paint_schema_document_text[] = SPDF_JSON(
  "layer.add": {"properties": {"name": {"type": "string", "maxLength": 120},
    "above": {"$ref": "#/$defs/id", "description": "default the active layer"}}},
  "layer.duplicate": {"required": ["id"], "properties": {"id": {"$ref": "#/$defs/id"}}},
  "layer.delete": {"required": ["id"], "properties": {"id": {"$ref": "#/$defs/id"}}},
  "layer.merge_down": {"required": ["id"], "properties": {"id": {"$ref": "#/$defs/id"}}},
  "layer.set": {"required": ["id"],
    "properties": {"id": {"$ref": "#/$defs/id"}, "name": {"type": "string", "maxLength": 120},
      "visible": {"type": "boolean"}, "opacity": {"$ref": "#/$defs/opacity"}}},
  "layer.order": {"required": ["id", "to"],
    "properties": {"id": {"$ref": "#/$defs/id"}, "to": {"$ref": "#/$defs/depth"}}},
  "layer.activate": {"required": ["id"], "properties": {"id": {"$ref": "#/$defs/id"}}},
  "colors.set": {"anyOf": [{"required": ["color1"]}, {"required": ["color2"]}],
    "properties": {"color1": {"$ref": "#/$defs/color"}, "color2": {"$ref": "#/$defs/color"}}},
  "palette.set_custom": {"required": ["index", "color"],
    "properties": {"index": {"type": "integer", "minimum": 0, "maximum": 9}, "color": {"$ref": "#/$defs/color"}}},
  "palette.save": {"required": ["path"], "properties": {"path": {"type": "string", "description": "a .json file, or .pal for Paint's palette format"}}},
  "palette.load": {"required": ["path"], "properties": {"path": {"type": "string", "description": "a .json or .pal file: its colours that are not among the 20 fill the custom slots"}}},
  "history.undo": {"properties": {"steps": {"type": "integer", "minimum": 1, "default": 1}}},
  "history.redo": {"properties": {"steps": {"type": "integer", "minimum": 1, "default": 1}}},
  "form.state": {"properties": {}},
  "form.field_set": {"required": ["name", "value"],
    "properties": {"name": {"type": "string"}, "value": {"type": ["string", "boolean"],
      "description": "text or choice; true or false for a checkbox; the option's name for a radio button"}}},
  "form.text_add": {"required": ["page", "x", "y", "text"],
    "properties": {"page": {"$ref": "#/$defs/page"}, "x": {"type": "number"}, "y": {"type": "number"},
      "text": {"type": "string"},
      "size": {"type": "number", "minimum": 8, "maximum": 72, "description": "default: sized to the field or line"}}},
  "form.mark_add": {"required": ["page", "x", "y", "kind"],
    "properties": {"page": {"$ref": "#/$defs/page"}, "x": {"type": "number"}, "y": {"type": "number"},
      "kind": {"enum": ["check", "cross"]}}},
  "form.signature_place": {"required": ["page", "rect"],
    "properties": {"page": {"$ref": "#/$defs/page"}, "rect": {"$ref": "#/$defs/rect"},
      "kind": {"enum": ["signature", "initials"], "default": "signature"}}},
  "form.remove_drawings": {"properties": {}},
  "form.remove_everything": {"properties": {}},
  "form.save_final_copy": {"required": ["path"], "properties": {"path": {"type": "string"}}},
  "doc.state": {"properties": {"page": {"$ref": "#/$defs/page",
    "description": "PDFs: that page's layers and objects"}}},
  "doc.render": {"required": ["out"],
    "properties": {"out": {"type": "string", "description": "path of the PNG to write"},
      "region": {"$ref": "#/$defs/rect"},
      "scale": {"type": "number", "exclusiveMinimum": 0, "maximum": 8, "default": 1},
      "layers": {"$ref": "#/$defs/ids", "description": "default every visible layer"}}},
  "doc.save": {"properties": {}},
  "doc.save_as": {"required": ["path"],
    "properties": {"path": {"type": "string"},
      "format": {"$ref": "#/$defs/format", "description": "default from the path's extension"},
      "quality": {"type": "number", "minimum": 0, "maximum": 1, "default": 0.92}}},
  "doc.save_as_pdf": {"properties": {"path": {"type": "string",
    "description": "default the same folder and name with .pdf"}}},
  "doc.copy": {"properties": {"scope": {"$ref": "#/$defs/scope"}, "out": {"type": "string", "description": "a PNG file to write instead of the clipboard (Copy to file)"}}},
  "mode.set": {"required": ["on"], "properties": {"on": {"type": "boolean"}}},
  "view.zoom": {"required": ["level"],
    "properties": {"level": {"anyOf": [{"type": "number", "minimum": 0.125, "maximum": 8},
      {"enum": ["fit", "actual"]}]}}},
  "view.set": {"properties": {"rulers": {"type": "boolean"}, "gridlines": {"type": "boolean"},
    "statusbar": {"type": "boolean"}, "thumbnail": {"type": "boolean"}}},
  "tool.choose": {"required": ["tool"],
    "properties": {"tool": {"$ref": "#/$defs/tool"}, "options": {"type": "object",
      "description": "named as in its operation: size, opacity, shape, outline, fill, eraser (lines, pixels)..."}}}
);

/* Flags and kinds, short (#undef'd below). */
#define U SPDF_PAINT_OP_UNDOABLE
#define R SPDF_PAINT_OP_READ_ONLY
#define S SPDF_PAINT_OP_UI_STATE
#define P SPDF_PAINT_OP_NEEDS_PAGE
#define N SPDF_PAINT_OP_NO_TARGET
#define I SPDF_PAINT_OP_NEEDS_INPUT
#define RASTER SPDF_PAINT_DOC_RASTER
#define ANYC SPDF_PAINT_DOC_ANY_CANVAS
#define PDF SPDF_PAINT_DOC_PDF
#define TEXT SPDF_PAINT_DOC_TEXT
#define CANVAS SPDF_PAINT_ROUTE_CANVAS
#define FILL SPDF_PAINT_ROUTE_FILL_ON_PDF
#define FRONT SPDF_PAINT_ROUTE_FRONTEND

static const spdf_paint_op_info k_ops[] = {
    {"canvas.new", "Canvas", N, ANYC | TEXT, FRONT, "Opens a new blank canvas in a new tab with Annotate on (1000 x "
     "1000 px, transparent unless a background is given) and answers its tab."},
    {"canvas.resize", "Canvas", U, RASTER, CANVAS,
     "Changes the canvas size, keeping the picture at the anchor; the new area is transparent or the given colour."},
    {"canvas.properties", "Canvas", U, RASTER, CANVAS, "Sets the picture's resolution, or turns it black and white."},
    {"image.resize", "Image", U | P, ANYC, CANVAS,
     "Resizes the selection, the selected object or the whole picture, by pixels or by percent."},
    {"image.skew", "Image", U | P, ANYC, CANVAS, "Slants the selection, the selected object or the whole picture."},
    {"image.rotate", "Image", U | P, ANYC, CANVAS,
     "Rotates the selection, the selected object or the whole picture by any angle, clockwise."},
    {"image.flip", "Image", U | P, ANYC, CANVAS, "Flips the selection, the selected object or the whole picture."},
    {"image.crop", "Image", U | P, ANYC, CANVAS,
     "Crops the canvas to the rectangle, or to the selection's box; objects keep their place in the picture."},
    {"image.invert", "Image", U | P, ANYC, CANVAS,
     "Inverts the colours of the selection, the selected object or the active layer."},
    {"image.clear", "Image", U | P, ANYC, CANVAS,
     "Clears the active layer to transparent (to Color 2 on a picture that can't be transparent)."},
    {"image.remove_background", "Image", U | P | I, ANYC, CANVAS, "Makes everything outside the main subject "
     "transparent, on the active layer or the selected picture (macOS 14 or later, done on this Mac)."},
    {"select.rect", "Selection", S | P, ANYC, CANVAS, "Selects a rectangle of pixels."},
    {"select.freeform", "Selection", S | P, ANYC, CANVAS, "Selects the pixels inside a freehand outline, closed for "
     "you."},
    {"select.all", "Selection", S | P, ANYC, CANVAS, "Selects the whole canvas."},
    {"select.none", "Selection", S | P, ANYC, CANVAS, "Removes the selection; a lifted selection stays an object."},
    {"select.invert", "Selection", S | P, ANYC, CANVAS,
     "Selects everything that was not selected, and nothing that was."},
    {"select.delete", "Selection", U | P, ANYC, CANVAS,
     "Clears the selected pixels of the active layer to transparent, or deletes the selected objects."},
    {"select.lift", "Selection", U | P, ANYC, CANVAS,
     "Lifts the selected pixels out of the active layer into a new Picture object and answers its id."},
    {"select.transparent", "Selection", S, ANYC, CANVAS,
     "When on, pixels of Color 2 are left behind when a selection is lifted."},
    {"select.objects", "Selection", S | P, ANYC, CANVAS, "Selects these objects (an empty list selects none), so "
     "the image operations and Delete act on them."},
    {"pen.add", "Pen and arrow", U | P, ANYC, FILL,
     "Adds a pen line: a smooth vector line through the points that stays an object you can move and restyle."},
    {"arrow.add", "Pen and arrow", U | P, ANYC, FILL, "Adds an arrow from tail to tip; both ends can be moved later."},
    {"erase.lines", "Pen and arrow", U | P, ANYC, FILL, "Removes every pen line and arrow the eraser's path touches."},
    {"paint.stroke", "Pixels", U | P, ANYC, CANVAS, "Paints one stroke into the active layer with the pencil, a "
     "brush, the airbrush, the eraser or the color eraser."},
    {"paint.fill", "Pixels", U | P, ANYC, CANVAS,
     "Fills the area around a point with a colour, up to the edges you see."},
    {"color.pick", "Pixels", R | P, ANYC, CANVAS,
     "Reads the colour at a point, from what you see or from the active layer."},
    {"shape.add", "Objects", U | P, ANYC, CANVAS,
     "Adds a shape: one of 24 shapes or an arrow line, with an outline and a fill; it stays an object."},
    {"text.add", "Objects", U | P, ANYC, CANVAS, "Adds a text box, which can be edited again at any time."},
    {"picture.add", "Objects", U | P | I, ANYC, CANVAS,
     "Adds a picture from a file, the clipboard or PNG data, as an object."},
    {"object.update", "Objects", U | P, ANYC, CANVAS,
     "Changes any of an object's own settings, named as when it was added."},
    {"object.move", "Objects", U | P, ANYC, CANVAS, "Moves objects by dx and dy."},
    {"object.transform", "Objects", U | P, ANYC, CANVAS, "Sets an object's box or rotation, or flips it."},
    {"object.order", "Objects", U | P, ANYC, CANVAS,
     "Changes the depth of objects: to the front, forward, backward, to the back, or to a position."},
    {"object.merge_down", "Objects", U | P, ANYC, CANVAS, "Turns an object into pixels of the layer below it."},
    {"object.duplicate", "Objects", U | P, ANYC, CANVAS,
     "Copies an object just above itself and answers the copy's id."},
    {"object.delete", "Objects", U | P, ANYC, CANVAS, "Deletes objects."},
    {"layer.add", "Layers", U | P, ANYC, CANVAS, "Adds an empty layer and answers its id."},
    {"layer.duplicate", "Layers", U | P, ANYC, CANVAS, "Copies a layer just above itself and answers the copy's id."},
    {"layer.delete", "Layers", U | P, ANYC, CANVAS, "Deletes a layer; a PDF page itself can't be deleted."},
    {"layer.merge_down", "Layers", U | P, ANYC, CANVAS, "Merges a layer into the layer below it."},
    {"layer.set", "Layers", U | P, ANYC, CANVAS, "Renames a layer, shows or hides it, or changes its opacity."},
    {"layer.order", "Layers", U | P, ANYC, CANVAS,
     "Moves a layer to the front, forward, backward, to the back, or to a position."},
    {"layer.activate", "Layers", S | P, ANYC, CANVAS,
     "Makes a layer the one the pencil, brushes, fill and eraser paint into."},
    {"colors.set", "Colours", S, ANYC, CANVAS,
     "Sets Color 1 (what the tools draw with) and Color 2 (the right button's colour, and shapes' fill)."},
    {"palette.set_custom", "Colours", S, ANYC, CANVAS, "Puts a colour in one of the 10 custom colour slots."},
    {"palette.save", "Colours", R, ANYC, FRONT, "Writes the palette and the custom colours to a .json or Paint .pal file."},
    {"palette.load", "Colours", S, ANYC, FRONT, "Reads colours from a .json or Paint .pal file into the custom slots."},
    {"history.undo", "History", 0, ANYC, FRONT, "Undoes the last changes made in this tab, by anyone."},
    {"history.redo", "History", 0, ANYC, FRONT, "Redoes changes that were undone."},
    {"form.state", "Forms", R, PDF, FILL, "Lists the PDF's form fields (names, kinds, values, pages, boxes), what "
     "has been placed on it, and how many fields are filled."},
    {"form.field_set", "Forms", U, PDF, FILL, "Fills in a field of the PDF's own form, found by its name."},
    {"form.text_add", "Forms", U, PDF, FILL, "Places text on a page, as Fill & Sign's Text tool does."},
    {"form.mark_add", "Forms", U, PDF, FILL, "Places a check or a cross on a page."},
    {"form.signature_place", "Forms", U, PDF, FILL,
     "Places the person's saved signature or initials on a page; refused when none is saved."},
    {"form.remove_drawings", "Forms", U, PDF, FILL, "Removes every pen line and arrow from the PDF."},
    {"form.remove_everything", "Forms", U, PDF, FILL,
     "Removes everything added with Annotate and puts the form's fields back as they were."},
    {"form.save_final_copy", "Forms", R, PDF, FILL,
     "Saves a copy of the PDF with everything added drawn into its pages, no longer editable."},
    {"doc.state", "Document", R, ANYC, CANVAS, "Describes the document: size, layers and objects with their ids and "
     "settings, selection, colours, zoom, unsaved changes, file and format."},
    {"doc.render", "Document", R | P, ANYC, CANVAS,
     "Writes a PNG of what the canvas shows (or of a region or some layers, at a scale), to look at."},
    {"doc.save", "Document", 0, ANYC, FRONT,
     "Writes the changes into the file; a canvas never saved needs doc.save_as."},
    {"doc.save_as", "Document", 0, ANYC, FRONT, "Saves under a new name as PNG, JPEG, HEIC, TIFF, BMP, GIF or a "
     "Shenzhen Paint project; the tab then shows the new file."},
    {"doc.save_as_pdf", "Document", 0, TEXT, FRONT, "Text documents: saves the document as a PDF, opens it in a new "
     "tab with Annotate on, and answers that tab."},
    {"doc.copy", "Document", R | P, ANYC, FRONT,
     "Copies the selection, the selected object or the whole picture to the clipboard, or into a PNG file (out)."},
    {"mode.set", "Document", S, ANYC, FRONT, "Turns Annotate on, or off as Done does."},
    {"view.zoom", "View", S, ANYC, FRONT, "Zooms to a level (0.125 to 8), to fit the window, or to actual size."},
    {"view.set", "View", S, ANYC, FRONT,
     "Shows or hides the rulers, the gridlines, the status bar and the thumbnail."},
    {"tool.choose", "View", S, ANYC, FRONT, "Chooses the tool, and its options, that the palette shows."},
};

#undef U
#undef R
#undef S
#undef P
#undef N
#undef I
#undef RASTER
#undef ANYC
#undef PDF
#undef TEXT
#undef CANVAS
#undef FILL
#undef FRONT

int spdf_paint_op_count(void) { return (int)(sizeof(k_ops) / sizeof(k_ops[0])); }

const spdf_paint_op_info* spdf_paint_op_at(int index) {
    return index >= 0 && index < spdf_paint_op_count() ? &k_ops[index] : NULL;
}

const spdf_paint_op_info* spdf_paint_op_find(const char* name) {
    if (!name) return NULL;
    for (int i = 0; i < spdf_paint_op_count(); i++)
        if (!strcmp(k_ops[i].name, name)) return &k_ops[i];
    return NULL;
}

const char* spdf_paint_kind_name(spdf_paint_doc_kind kind) {
    switch (kind) {
    case SPDF_PAINT_DOC_PICTURE: return "picture";
    case SPDF_PAINT_DOC_CANVAS: return "canvas";
    case SPDF_PAINT_DOC_PDF: return "pdf";
    case SPDF_PAINT_DOC_TEXT: return "text";
    }
    return NULL;
}
