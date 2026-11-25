# Paint

Status: specified 2026-11-25 on `feat/pdf-paint` (off origin/main b77e5a81). Not built yet.

Raph's request (2026-11-25): "extend the annotation tool to replicate all functions of microsoft paint when an image is
open. + on top of the app should also give the option to have a blank canvas, default 1000x1000px, can be resized by
hand. by default it is transparent (slight checkerboard to represent) and saved in png. [...] Add the concept of
background and foreground / depth for objects that can be moved by right click. Make sure the agents can use all the
tools always."

Standing rules that apply: intuitive first; nothing new before the first frame (launch must not get slower); no tests
or suites added to the repo, one real-UI check at the end (screenshots from the first frame on); release only on
Raph's word; Fill & Sign on PDFs keeps working exactly as it does.

## References

What "all functions of Microsoft Paint" means here, gathered on 2026-11-25:

- **Windows 11 Paint** (version 11.25xx, screenshot of the ribbon taken in the Windows 11 VM, kept in the session
  scratchpad as `win11-paint-ribbon.png`). Ribbon groups, left to right: Selection, Image, Tools, Brushes, Shapes
  (with Outline, Fill and Size), Colors, Copilot, Layers. Left of the canvas: a size slider and an opacity slider for
  the current tool. Status bar: pointer position, selection size, canvas size, Fit to window, zoom percentage, zoom
  slider. Canvas handles on its edges. Menus: File, Edit, View; Undo/Redo and Save in the title row.
- **2025 additions** (Windows Insider Blog, 17 Sep 2025, Paint 11.2508.361.0, via secondary coverage): `.paint`
  project files that keep layers and transparency (File > Save as project), and a per-tool opacity slider for
  Pencil and Brush. Earlier: layers panel and transparent canvas (2023), background removal (2023).
- **Classic Paint as recreated by JS Paint** (jspaint.app, menus read 2026-11-25). Tools: Free-Form Select, Select,
  Eraser/Color Eraser, Fill With Color, Pick Color, Magnifier, Pencil, Brush, Airbrush, Text, Line, Curve, Rectangle,
  Polygon, Ellipse, Rounded Rectangle. Image menu: Flip/Rotate, Stretch/Skew, Invert Colors, Attributes, Clear Image,
  Draw Opaque. Colors menu: Edit Colors, Get Colors, Save Colors. Edit: Undo, Repeat, Cut, Copy, Paste, Clear
  Selection, Select All, Copy To, Paste From. View: Tool Box, Color Box, Status Bar, Text Toolbar, Zoom, View Bitmap,
  Fullscreen.

Everything in those lists is in this spec except what § Not included names, with the reason.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Where | An image tab (PNG, JPEG, GIF, BMP, TIFF, HEIC, WebP, camera RAW) gets **Paint** where a PDF gets Fill & Sign: the same toolbar button and ⌥⌘F, named "Paint" with a brush icon. PDFs and Markdown are unchanged | One place to look for "draw on this"; Raph called the Fill & Sign tools "the annotation tool" |
| Blank canvas | **File > New Canvas** (⌘N; ⌥⌘N if ⌘N is taken) opens a tab "Untitled canvas": 1000 x 1000 px, transparent, Paint on. A checkerboard shows where it is transparent. Its edges and corner drag to resize it | Raph's defaults |
| Layers and depth | Every picture is a stack: the **Background** at the bottom (the image's own pixels), raster layers, and **objects** on top. An object is a shape, line, curve, arrow, text box or picture (pasted, inserted, or a selection that was moved). Each object is its own layer, so it keeps its depth and stays editable: right-click it for Bring to Front, Bring Forward, Send Backward, Send to Back, Merge Down, Duplicate, Delete | Windows 11 Paint has layers but turns shapes into pixels as soon as you click away; Raph asked for depth you can change later, by right-click |
| Pixel tools | Pencil, the nine brushes, Airbrush, Eraser, Color Eraser and Fill paint into the **active raster layer** (the Background unless another raster layer is chosen in Layers). They never paint into an object | Paint's model; an object stays a clean, movable thing |
| Right button | Right-click without moving, or Control-click: the context menu of what is under the pointer (an object, the selection, or the canvas). Right-drag with a pixel tool or a shape tool: draws with Color 2, as in Paint | Both of Paint's uses of the right button, told apart by movement (4 pt) |
| Saving an image | ⌘S, Done, closing the tab, switching to another document or quitting writes the flattened picture into the file, in its own format, with its metadata. Collection keeps the version before the first write, as image rotation does. No "save changes?" question for a file that exists | The app already writes Fill & Sign and rotations into the file; Collection is the undo across sessions |
| Saving a canvas | The first ⌘S asks where (Save panel, PNG chosen, "Untitled.png"); afterwards it is an image tab like any other. Closing a canvas that was never saved asks Save / Don't Save / Cancel (the only question). Quitting keeps it for next launch | Raph: "saved in png"; a never-saved canvas has nowhere to go without asking |
| Layers kept | Layers and objects are kept beside the picture, in `<state>/Paint/<hash of path>.szpaint`, and come back when the same file is opened again unchanged (size and modification time match). File > Save As offers **Shenzhen Paint project (.szpaint)** to keep them in a file of your choice; ShenzhenPDF opens `.szpaint` files | Matches Paint's `.paint` project files; reopening keeps objects movable |
| Formats that can't be written | WebP, camera RAW and animated GIF or HEIC: Paint works on a copy and the first save asks where, PNG chosen. The palette says so: "Paint saves a copy of this picture as PNG." | ImageIO can't write WebP or RAW; flattening an animation would lose frames |
| JPEG | Written at quality 0.92 with the original metadata and colour profile. Transparent pixels are flattened onto white | Same as Paint and Preview |
| One set of operations | Every change, from a click, a menu, a key, `szpdf`, the AI assistant or MCP, is one **paint operation** (§ Operations), applied by one function, undone by one stack. The UI never changes the picture any other way | "Make sure the agents can use all the tools always": parity by construction, not by a list kept in step |
| Where the code lives | The picture model and every pixel operation in the portable C core (`core/spdf_paint_*.c`), drawing with MuPDF's own draw device (antialiased paths, strokes and text into `fz_pixmap`s). The Mac UI in AppKit | GTK and Windows get Paint later with no second engine; MuPDF already draws paths and text well |
| Launch | Nothing runs before first paint: no Paint object, file or font is touched until Paint is opened or a `.szpaint` or canvas tab is restored | Raph's standing rule |
| Fill & Sign for agents | The same parity rule is extended to Fill & Sign: its pen, arrow, eraser, select, text, marks, signatures and the Remove commands become `fill.*` operations reachable from `szpdf`, the assistant and MCP | "agents can use all the tools always" |

## 1. The window

Paint reuses the Fill & Sign palette at the top of the page area: two rows, the second showing the options of the
chosen tool. The canvas sits in the page area as the picture does today, centred, with the checkerboard under
transparent pixels.

**Row 1 (always):** Selection ▾ · Image group · Tools group · Brushes ▾ · Shapes ▾ · Color 1 / Color 2 · palette ·
Layers · Done. On a narrow window, groups collapse to their icons, then into a "More" menu, Done always last and named.

**Row 2 (options of the chosen tool):** size slider with its value in px, opacity slider (Pencil and brushes), and the
tool's own options (below). Shapes add Outline ▾ and Fill ▾. Text adds the text bar.

**Layers panel:** a sidebar on the right of the canvas (the minimap's place while Paint is on; the minimap comes back
on Done), shown by the Layers button or ⇧⌘L. Top of the list is front. Each row: thumbnail, name ("Background",
"Layer 2", "Rectangle", "Text: Hello", "Picture"), eye (hide/show), and while selected an opacity slider. Drag rows to
reorder (= depth). Buttons under the list: New Layer, Duplicate, Merge Down, Delete. The active raster layer is marked
with a brush badge; selecting an object row selects that object on the canvas.

**Status bar** (bottom of the page area while Paint is on): pointer position in px, selection or object size in px,
canvas size in px, Fit, zoom percentage menu, zoom slider. Toggle: View > Status Bar.

**View:** zoom 12.5 %–800 % (⌘+ / ⌘- / ⌘0 actual size / ⌘9 fit, the app's existing zoom keys), pinch, ⌥-scroll;
pixels are drawn sharp (nearest neighbour) above 100 %. View > Rulers (⇧⌘R) shows px rulers on top and left. View >
Gridlines (⌘') draws a 1 px grid from 400 %. View > Full Screen (the app's). View > Thumbnail shows a small floating
view of the whole picture while zoomed in.

**Checkerboard:** 8 x 8 screen-pt squares, #FFFFFF / #E8E8E8 in light appearance, #3C3C3C / #323232 in dark; only on
screen, never in a saved file or a page picture.

**Canvas handles:** the right edge, the bottom edge and the bottom-right corner each show a small square handle. Drag
one: a dotted outline follows, the status bar shows the new size; release resizes the canvas (anchored top-left; new
area transparent). Shift keeps the ratio on the corner. Minimum 1 x 1, maximum 16384 x 16384 and 268 M pixels.

## 2. Tools

Every tool's settings (size, opacity, brush, shape styles, font) are remembered in `<state>/Paint/settings.json`,
read the first time Paint opens, written on change.

### Selection ▾

| Item | Behaviour |
|---|---|
| Rectangular selection (S) | Drag a marching-ants rectangle; Shift makes it square. Drag inside it to move: the pixels lift out of the active layer into a new **Picture** object at the same place (the hole is transparent, or Color 2 when "Transparent selection" is off and the layer has no alpha, as Paint) |
| Free-form selection (S again) | Drag a lasso; closes itself on release |
| Select all (⌘A) | The whole canvas |
| Invert selection (⇧⌘I) | |
| Delete (⌫) | Clears the selected pixels of the active layer to transparent; with an object selected, deletes it |
| Transparent selection (toggle) | When on, pixels equal to Color 2 are left behind when a selection is lifted (classic "Draw Opaque" off) |
| Crop to selection (⇧⌘X) | Canvas becomes the selection's bounding box; objects keep their place relative to it |
| Esc | Deselect; a lifted selection stays an object |
| Copy / Cut / Paste (⌘C / ⌘X / ⌘V) | Copy puts the selection (or the selected object, flattened) on the clipboard as PNG and TIFF. Paste makes a Picture object at the top-left of the visible area, selected, ready to drag. A pasted picture larger than the canvas asks "Make the canvas bigger to fit?" (Yes / No), as Paint |
| Paste from file… (⇧⌥⌘V) / drop a picture file | A Picture object |
| Copy to file… | Saves the selection as PNG |

Selection handles resize the selection's pixels once lifted (it is an object then). A selection and an object both
take the arrow keys (1 px, Shift 10 px).

### Image group

| Item | Behaviour |
|---|---|
| Crop | Same as Crop to selection |
| Resize and skew… (⌥⌘I) | Sheet: Resize by Percentage / Pixels, Horizontal, Vertical, Maintain aspect ratio (on); Skew (degrees) Horizontal, Vertical (−89…89). Applies to the selection or selected object if any, else to the whole picture (every layer and object scaled) |
| Rotate ▾ | Rotate right 90°, Rotate left 90°, Rotate 180°, and Rotate by… (any angle, classic). Same scope rule |
| Flip ▾ | Flip vertical, Flip horizontal. Same scope rule |
| Invert colors (⇧⌘⌥I is taken? use ⌃⌘I) | Inverts RGB of the selection, the selected object or the active layer |
| Remove background | macOS Vision's subject mask (macOS 14+) on the active layer or selected picture: makes everything outside the main subject transparent. Hidden on older macOS. Runs on this Mac, nothing leaves it |
| Canvas size and properties… (⌥⌘C) | Sheet: Width, Height (px; also cm and inches at the picture's dpi), Anchor (9-way), Resolution (dpi), "Transparent" (on: new area transparent; off: Color 2), Black and white (converts on OK). The classic Attributes dialog |
| Clear image (⇧⌘⌫) | Active layer to transparent (Background to Color 2 if the format has no alpha) |

### Tools group

| Tool (key) | Behaviour and options |
|---|---|
| Pencil (P) | Hard-edged freehand, no antialiasing, 1–20 px (default 1); Shift draws straight lines; opacity |
| Fill (F) | Flood fill from the click with Color 1 (right-click: Color 2) on the active layer. Option: Tolerance 0–100 % (default 0, Paint), Contiguous (on; off = replace that colour everywhere, classic Shift-fill). Fill clicked on an object fills the object's own fill (a shape gets solid fill) |
| Text (T) | Drag a box (or click for a growing box). Text bar: font family, size (8–400 pt), Bold ⌘B, Italic ⌘I, Underline ⌘U, Strikethrough, alignment left/centre/right, Color 1 for text, background Transparent or Opaque (Color 2). The text is a **Text object**: double-click to edit again, any time |
| Eraser (E) | Square eraser 4–100 px painting transparency into the active layer (Color 2 where the layer has no alpha). Right-drag: **Color Eraser** — replaces only Color 1 pixels with Color 2 (classic) |
| Color picker (I) | Click: Color 1 from the visible (flattened) pixels; right-click: Color 2. Option: Pick from all layers / active layer. Returns to the previous tool after one pick, as Paint |
| Magnifier (Z) | Click zooms in at the point (100 → 200 → 400 → 800 %), right-click or ⌥-click zooms out |

### Brushes ▾ (B; B again cycles)

All brushes paint into the active raster layer with Color 1 (right-drag Color 2), size 1–100 px (default 5), opacity
1–100 %, Shift for straight segments. Pressure from a tablet scales size (brushes) or opacity (airbrush).

| Brush | Look (core implements each as a stamp or path model) |
|---|---|
| Brush | Round, antialiased, hard edge |
| Calligraphy brush 1 | Flat nib at 45° |
| Calligraphy brush 2 | Flat nib at 135° |
| Airbrush | Random dots in a disc, density by time and speed |
| Oil brush | Streaky bristles with paint running out along the stroke |
| Crayon | Grainy paper texture, low coverage |
| Marker | Flat, semi-transparent, overlaps within one stroke do not darken |
| Natural pencil | Thin, grainy, lighter with speed |
| Watercolor brush | Soft wet edge, darker rim, overlaps darken |

Classic brush shapes (round, square, slash, backslash in 3 sizes) are covered by Brush and the calligraphy brushes.

### Shapes ▾ (U; U again cycles Rectangle, Oval, Line, Arrow)

Drag to draw; Shift constrains (square, circle, 45° lines). While drawn, the shape is a selected object with eight
handles and a rotation handle; it stays an object (layer) after you click away. Outline ▾: No outline, Solid color,
Crayon, Marker, Oil, Natural pencil, Watercolor. Fill ▾: No fill, Solid color, Crayon, Marker, Oil, Natural pencil,
Watercolor. Outline uses Color 1, fill Color 2, as in Paint. Size 1–50 px (default 3).

Shapes, in Paint's order: Line, Curve, Oval, Rectangle, Rounded rectangle, Polygon, Triangle, Right triangle,
Diamond, Pentagon, Hexagon, Right arrow, Left arrow, Up arrow, Down arrow, Four-point star, Five-point star,
Six-point star, Rounded rectangular callout, Oval callout, Cloud callout, Heart, Lightning; plus **Arrow line** (a line
with an arrowhead, the Fill & Sign arrow, ends draggable).

- **Curve:** drag the line, then click-drag twice to bend it (two control points, classic); Return ends early.
- **Polygon:** click each corner, double-click or click the first point to close.
- **Callouts:** the tail tip has its own handle.

### Colors

Color 1 and Color 2 swatches (click to choose which one the palette sets; X swaps them; D resets to black/white).
Palette: 20 colours in two rows as Paint (black, grey 50 %, dark red, red, orange, yellow, green, turquoise, indigo,
purple / white, grey 25 %, brown, rose, gold, light yellow, lime, light turquoise, blue-grey, lavender), then 10
custom slots. Left-click a swatch sets Color 1, right-click Color 2. **Edit colors** opens the macOS colour panel
(wheel, sliders, hex, eyedropper); the result goes into the next empty custom slot. Colours > Save Colors… / Get
Colors… write and read a palette (`.json` and Paint/RIFF `.pal`). Every colour has alpha.

## 3. Objects and depth

- An object is selected by clicking it with the Selection tool (or any shape tool, or by its Layers row). A selected
  object shows its box, eight handles and a rotation handle; drag to move, handles to resize (Shift keeps ratio),
  rotation handle to rotate (Shift: 15° steps). Double-click edits a text box, a curve's points or a polygon's
  corners.
- Right-click an object: **Bring to Front** (⌥⌘]), **Bring Forward** (⌘]), **Send Backward** (⌘[), **Send to Back**
  (⌥⌘[), Merge Down (into the layer below it; becomes pixels), Duplicate (⌘D), Delete, Flip Horizontal, Flip Vertical,
  Rotate Right, Rotate Left, Outline ▸ / Fill ▸ / Size ▸ (shapes), Edit Text (text), Copy, Cut.
- Right-click the canvas (no object): Paste, Select All, New Layer, Canvas Size and Properties…, Remove Background.
- Right-click the selection: Cut, Copy, Delete, Crop to Selection, Invert Selection, Lift to Object, Flip/Rotate.
- Several objects: Shift-click or drag a box with the Selection tool starting on empty canvas while ⌥ is held
  (without ⌥ the drag is a pixel selection); move, depth and delete apply to all.
- An object's opacity is its layer's opacity (Layers panel slider).

## 4. Edit, history and keys

Undo ⌘Z, Redo ⇧⌘Z and ⌘Y, unlimited within 1 GB of history per tab (oldest steps dropped first; History is per tab
and survives switching tabs, not quitting). Edit > Repeat (F4) repeats the last operation (classic). Escape cancels
the gesture in progress.

Key letters (P, F, T, E, I, Z, S, B, U, L line, X, D, [ and ] for size) work while the canvas has the keyboard and no
text box is being typed in, like Fill & Sign's P A E S T. Any ⌘ shortcut above that the app already uses for
something else keeps the app's meaning; the UI agent lists clashes and picks the fallback (⌥ added) in
`Paint keys` below.

## 5. Files

- **Opening:** an image opens as today (nothing new at open). Paint loads its layers only when Paint is turned on,
  or at once for a `.szpaint` file or a restored canvas tab.
- **`.szpaint`:** a ZIP (MuPDF's `fz_zip_writer`) holding `manifest.json` (canvas size, dpi, layers bottom to top with
  kind, name, visibility, opacity, and for objects their kind and parameters) and one PNG per raster layer and per
  Picture object. Shapes and text are stored as parameters, drawn again on load. Version 1.
- **Writing the picture:** flattened (visible layers and objects, opacity applied), encoded off the main thread with
  ImageIO, written to a temporary file in the same folder and swapped in, as `SPDFRotateImageAtPath` does. Collection
  is told before (`collectionProtectPath`) and after (`collectionDidSavePath`).
- **Save As…** (⇧⌘S): PNG, JPEG, HEIC, TIFF, BMP, GIF, Shenzhen Paint project. The tab then shows the new file.
- **Export** to PDF keeps working through the app's existing export of a picture tab.
- **Set as Desktop Picture** (File menu, image tabs): `NSWorkspace setDesktopImageURL` with the saved file.
- **Print** prints the flattened picture through the existing print path.

## 6. Operations (the single path for UI and agents)

One JSON object per operation: `{"op": "<name>", ...arguments}`. Coordinates are canvas pixels, origin top-left,
y down. Colours are `"#RRGGBB"` or `"#RRGGBBAA"`. Every operation is validated, applied by `spdf_paint_apply(doc,
json, &result)` in the core, recorded on the undo stack (except the read-only ones) and answers a JSON result
(`{"ok":true, ...}` or `{"ok":false,"error":"<code>","message":"<plain sentence>"}`). `spdf_paint_schema()` returns
the list below as JSON Schema; `szpdf paint schema`, the assistant's tool descriptions and the MCP server are
generated from it, so a new operation appears everywhere at once.

| Family | Operations |
|---|---|
| Canvas | `canvas.new {width=1000, height=1000, background="transparent"\|"#RRGGBB"}`, `canvas.resize {width, height, anchor="top-left"…"bottom-right", fill="transparent"\|color}`, `canvas.properties {dpi, blackAndWhite}` |
| Image | `image.resize {width, height \| percent, keepRatio=true, scope="auto"\|"image"\|"selection"\|"object"}`, `image.skew {horizontal, vertical, scope}`, `image.rotate {degrees, scope}`, `image.flip {axis:"horizontal"\|"vertical", scope}`, `image.crop {rect?}`, `image.invert {scope}`, `image.clear`, `image.remove_background {scope}` |
| Selection | `select.rect {x,y,w,h}`, `select.freeform {points}`, `select.all`, `select.none`, `select.invert`, `select.delete`, `select.lift` (→ object id), `select.transparent {on}` |
| Pixels | `paint.stroke {tool:"pencil"\|"brush"\|"calligraphy1"\|"calligraphy2"\|"airbrush"\|"oil"\|"crayon"\|"marker"\|"natural_pencil"\|"watercolor"\|"eraser"\|"color_eraser", points:[[x,y,(pressure)],…], color?, size, opacity, seed?}`, `paint.fill {x, y, color?, tolerance=0, contiguous=true}`, `color.pick {x, y, from:"visible"\|"layer"}` (read-only) |
| Objects | `shape.add {shape, rect \| points, rotation=0, outline:{style,color,width}, fill:{style,color}}`, `text.add {rect, text, font, size, bold, italic, underline, strikethrough, align, color, background:"transparent"\|color}`, `picture.add {path \| clipboard:true \| png_base64, rect?}`, `object.update {id, …any add argument}`, `object.move {id \| ids, dx, dy}`, `object.transform {id, rect?, rotation?, flip?}`, `object.order {id \| ids, to:"front"\|"forward"\|"backward"\|"back"\|index}`, `object.merge_down {id}`, `object.duplicate {id}`, `object.delete {id \| ids}` |
| Layers | `layer.add {name?, above?}`, `layer.duplicate {id}`, `layer.delete {id}`, `layer.merge_down {id}`, `layer.set {id, name?, visible?, opacity?}`, `layer.order {id, to}`, `layer.activate {id}` |
| Colours | `colors.set {color1?, color2?}`, `palette.set_custom {index, color}` |
| History | `history.undo {steps=1}`, `history.redo {steps=1}` |
| Document | `doc.state` (read-only: size, dpi, layers and objects with ids, kinds, bounds and parameters, active layer, selection, colours, zoom, dirty, file and format), `doc.render {out, region?, scale?, layers?}` (read-only: a PNG to look at), `doc.save`, `doc.save_as {path, format, quality?}`, `doc.copy {scope}` |
| View (UI state only, not undone) | `view.zoom {level \| "fit" \| "actual"}`, `view.set {rulers?, gridlines?, statusbar?, thumbnail?}`, `tool.choose {tool, options}` (what the palette shows) |

A brush stroke from the mouse is previewed locally and applied as one `paint.stroke` with all its points on release
(airbrush and the textured brushes take a `seed`, so replaying the operation gives the same pixels). A drag of an
object is one `object.move` on release. Text typing is one `object.update` when the box closes.

**Fill & Sign operations** (PDF tabs), the same way: `fill.state`, `fill.field_set {name, value}`,
`fill.text_add {page, x, y, text, size?}`, `fill.mark_add {page, x, y, kind:"check"\|"cross"}`, `fill.signature_place
{page, rect, kind:"signature"\|"initials"}`, `fill.pen {page, points, color, width}`, `fill.arrow {page, tail, tip,
color, width}`, `fill.erase {page, points, mode:"lines"\|"parts", size}`, `fill.move {ids, dx, dy}`, `fill.restyle
{ids, color?, width?}`, `fill.delete {ids}`, `fill.remove_drawings`, `fill.remove_everything`, `fill.undo`,
`fill.redo`, `fill.done`. Page coordinates in PDF points, origin top-left of the page.

### Agent surfaces

- **szpdf** (agent-interface.md): `szpdf canvas new [--width W] [--height H] [--background C] [--front]` → the new
  tab's id; `szpdf paint <file|tab> <op> [--key value …]` (flags map to the operation's arguments, `--json '{…}'`
  takes them whole); `szpdf paint <file|tab> --script ops.json` applies an array in order and stops at the first
  error, answering each result; `szpdf paint <file|tab> state`; `szpdf paint schema [op]`; the same for `szpdf fill`.
  Paint is turned on for the tab if it is off; the window does not come forward.
- **AI assistant** (SPDFMacAITools): `paint_apply {target, ops:[…]}`, `paint_state {target}`, `paint_look {target,
  region?}` (returns the picture to the model), `canvas_new {width, height, background}`, `fill_sign_apply`,
  `fill_sign_state`. Edits are undoable by the person with ⌘Z like their own, and listed in the chat.
- **MCP** (`shenzhen-pdf-mcp.py`): `paint_apply`, `paint_state`, `paint_render`, `canvas_new`, `fill_sign_apply`,
  `fill_sign_state`, all through the szpdf channel.

The parity check at the end lists every palette control, menu item, context menu item and key, and the operation it
sends; anything without one is a bug.

## 7. Not included

- **AI generation** (Cocreator, generative fill, generative erase, sticker generator): these send pictures to a
  service. The assistant can already do agent-driven edits through `paint_apply`; a generative tool would need its
  own decision on data leaving the Mac. Not in this round.
- **Object select** (AI selection of a subject): covered by Remove background (Vision, on this Mac) plus the
  free-form selection. Not in this round.
- **Upload to Imgur, Multi-user, Speech recognition, Head tracker** (JS Paint extras): not Paint features.
- **Black-and-white dithering patterns** beyond a plain conversion.
- GTK and Windows UI: they get the core and can open `.szpaint` read-only later; not in this round.

## 8. Architecture

### Core (plain C, `core/`, no AppKit)

| File | Content |
|---|---|
| `spdf_paint.h` | Public API: document create/open/close, `spdf_paint_apply`, `spdf_paint_schema`, render the composite (or a region, at a scale) into an RGBA buffer, read layer thumbnails, undo/redo, dirty state, `.szpaint` read/write, flatten for saving |
| `spdf_paint_doc.c` | Document, layers, objects, ids, z-order, selection mask, colours, settings |
| `spdf_paint_ops.c` | JSON parsing and validation (cJSON), dispatch, results, schema |
| `spdf_paint_history.c` | Undo/redo: raster changes as 256 x 256 tile snapshots, object changes as before/after parameter copies; 1 GB cap |
| `spdf_paint_brush.c` | Pencil, the nine brushes, airbrush, eraser, color eraser; stamp model with seeded noise |
| `spdf_paint_fill.c` | Flood fill (scanline, tolerance, contiguous or global), colour pick |
| `spdf_paint_shapes.c` | The 24 shapes as `fz_path`s, outline and fill styles (solid via `fz_fill_path`/`fz_stroke_path`, textured styles by masking the brush textures with the path) |
| `spdf_paint_text.c` | Text objects drawn with MuPDF fonts; system fonts looked up by the Mac layer and passed as file paths (`spdf_paint_set_font_resolver`) |
| `spdf_paint_transform.c` | Resize (Lanczos down, bilinear up), skew, rotate (any angle), flip, crop, canvas resize, invert, black and white |
| `spdf_paint_file.c` | `.szpaint` ZIP read/write, flatten |

Pixels are premultiplied RGBA8 `fz_pixmap`s, one per raster layer and per Picture object. The composite is cached in
tiles and recomposited only where changed. Each file stays under 500 lines (split further if needed).

### Mac (`mac/`)

| File | Content |
|---|---|
| `SPDFMacPaintController.{h,mm}` | One per window, like `SPDFMacFillController`: the session per tab (core document, tool, colours, selection, zoom), turning Paint on and off, Done, saving (flatten, encode, write, Collection), autosave of the `.szpaint` beside it 2 s after the last change, the single `applyOperation:` all UI goes through |
| `SPDFMacPaintCanvasView.{h,mm}` | The canvas over the page area: draws the composite tiles, checkerboard, selection ants, object handles, live stroke preview, canvas handles, rulers and grid; gestures to operations |
| `SPDFMacPaintPalette.{h,mm}` | Rows 1 and 2, built like `SPDFMacFillPalette` |
| `SPDFMacPaintLayersPanel.{h,mm}` | The Layers sidebar |
| `SPDFMacPaintSheets.mm` | Resize and skew, Canvas size and properties, Rotate by… |
| `SPDFMacPaintMenus.mm` | Menu items, context menus, keys, validation |
| `SPDFMacPaintImageIO.{h,mm}` | Decode a file into the core document, encode the flattened picture, formats, metadata, font resolver |
| `SPDFMacPaintIntegration.{h,mm}` | The toolbar button and ⌥⌘F for image tabs, File > New Canvas, canvas tabs (state restore, Save panel), `.szpaint` opening, tab close and quit hooks |
| `SPDFMacSzpdfPaint.mm`, `SPDFMacAIToolsPaint.mm` | `szpdf paint`, `szpdf canvas`, `szpdf fill` and the assistant tools, all through `applyOperation:` / the Fill & Sign equivalent |

Edits to existing files are one line each where possible (menu table entries, toolbar button kind for image tabs,
tab close and quit flush hooks, the Makefile). `ShenzhenPDFMac.mm` does not grow.

### Paint keys

(Filled in by the UI agent from the app's real key table: each shortcut above, the one used, and why if it differs.)

## 9. Orchestration

Every brief carries: no pkill/killall/sudo (stop own PIDs); no `rm -rf` with variables, globs or `$(...)`; no
filesystem-wide searches; never launch, quit or touch Raph's running ShenzhenPDF, its settings, Collection, keychain or
Friends; no tests or suite changes in the repo; new files ≤ 500 lines; no growth in capped files; work only in your
own worktree and branch; no push to main, no release; user-visible text exactly as written here.

| Wave | Agent | Work | Branch |
|---|---|---|---|
| 0 | Architect | Headers (`spdf_paint.h` with every operation's C entry, `SPDFMacPaintController.h`), the operation schema JSON, stubs that compile, Makefile and `CORE_OBJS` lines | `feat/pdf-paint` |
| 1 | Fill & Sign check | The Fill & Sign final check (fill-and-sign.md § Final check and § Pen and arrow), fixing every bug it finds | `fix/fill-sign-final-check` |
| 1 | Core A | `spdf_paint_doc.c`, `_ops.c`, `_history.c`, `_file.c`, `_transform.c` | `paint/core-a` |
| 1 | Core B | `spdf_paint_brush.c`, `_fill.c`, `_shapes.c`, `_text.c` | `paint/core-b` |
| 1 | Mac UI A | Controller, canvas view, ImageIO, integration (button, New Canvas, saving, restore) | `paint/ui-a` |
| 1 | Mac UI B | Palette, layers panel, sheets, menus and keys | `paint/ui-b` |
| 1 | Agents | `szpdf paint/canvas/fill`, assistant tools, MCP, `fill.*` operations over Fill & Sign, agent-interface.md | `paint/agents` |
| 2 | Integrator | Merge the five paint branches, build, size caps, static launch checks, a first run on a throwaway canvas | `feat/pdf-paint` |
| 3 | Verifier | § Final check | — |
| 4 | Fixer | Every finding | `feat/pdf-paint` |

## 10. Final check (once, at the end, nothing added to the repo)

1. **Static:** no new initialiser or `+load`; `applicationDidFinishLaunching`, `loadPersistentState` and `main()`
   reference no Paint symbol except the canvas-tab restore path, which runs only when such a tab exists;
   `apps/pdf/tools/check-file-sizes.sh`.
2. **Launch gate:** `make -C apps/pdf/portable mac-launch-performance-tests LAUNCH_PERF_BASELINE_RELEASE=latest`.
3. **Real UI** on an isolated test copy (own HOME and state folder outside /tmp, Friends off, windows in the
   background, stopped by PID), driven with real clicks, drags, keys and right-clicks, screenshots from the first frame
   on, looked at as a first-time user: every tool on a PNG with transparency, a JPEG, a HEIC, a WebP (copy), a GIF; a
   new canvas resized by its handles and saved as PNG (check alpha with `sips`/a pixel read); objects of each kind
   reordered by right-click and by the Layers panel; undo/redo across every operation; Save, close, reopen (objects
   come back); `.szpaint` Save As and open; quit during a stroke; a 8000 x 8000 picture (stroke latency, memory).
4. **Agents:** every operation in `szpdf paint schema` applied through `szpdf` on a test canvas, then the same script
   through the assistant tool and MCP, with the three results and renders identical; every `fill.*` operation on a
   throwaway PDF form.
5. **Parity:** the list of UI controls and the operation each sends (§ 6); none without one.
