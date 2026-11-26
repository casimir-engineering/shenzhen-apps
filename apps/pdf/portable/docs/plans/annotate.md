# Annotate

Status: specified 2026-11-25 on `feat/pdf-paint` (off origin/main b77e5a81). Not built yet.

Raph's requests (2026-11-25):
- "extend the annotation tool to replicate all functions of microsoft paint when an image is open. + on top of the app
  should also give the option to have a blank canvas, default 1000x1000px, can be resized by hand. by default it is
  transparent (slight checkerboard to represent) and saved in png. [...] Add the concept of background and foreground
  / depth for objects that can be moved by right click. Make sure the agents can use all the tools always."
- Then: "paint mode should actually be annotation mode, all tools should be available in all docs, just that text
  based docs will first ask to save as pdf and you can't erase the base pdf of course".

So there is one mode, **Annotate**, the Fill & Sign mode grown into it: every Paint tool, plus Fill & Sign's form,
mark and signature tools, on every document. A picture's own pixels can be painted; a PDF's page is the locked
background under the annotations; a text document (Markdown, plain text, EPUB and the other formats the app reads)
is first saved as a PDF.

Standing rules that apply: intuitive first; nothing new before the first frame (launch must not get slower); no tests
or suites added to the repo, one real-UI check at the end (screenshots from the first frame on); release only on
Raph's word; everything Fill & Sign does today keeps working (forms auto-on, Tab, marks, signatures, pen, arrow,
eraser, select, the two Remove commands, the writable copy, Collection).

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
| One mode | **Annotate** replaces the Fill & Sign button and mode: same place in the toolbar, same ⌥⌘F, a pencil-and-brush icon, named "Annotate". It has every tool of § 2 on every document. On a PDF it also has Fill & Sign's form tools (Text, ✓ ✗, Signature) as its first group, and a PDF with a fillable form still opens with Annotate on | Raph: "paint mode should actually be annotation mode, all tools should be available in all docs" |
| Pictures | PNG, JPEG, GIF, BMP, TIFF, HEIC, WebP, camera RAW: the Background layer is the picture's own pixels and every tool can change it (erase, fill, crop, resize, rotate) | Paint |
| PDFs | Each page is a canvas. Its **Background is the page itself, locked**: nothing erases, fills, crops, lifts or recolours it. Pixel tools paint into a drawing layer above the page (made on the first stroke), the Eraser erases only what was added, Fill floods inside the edges you see but paints into the drawing layer, the colour picker reads what you see. Crop, resize, rotate, flip, invert, skew and clear apply to a selection, objects or added layers, never to the page. Canvas size is the page size and can't be dragged | "you can't erase the base pdf of course" |
| Text documents | Markdown, plain text and every other format that is not a picture or a PDF (EPUB, XPS, CBZ, FB2, SVG): turning Annotate on asks first: "To annotate this document, save it as a PDF." [Save as PDF…] [Cancel]. Save as PDF uses the app's existing PDF export (what printing would make), the Save panel defaults to the same folder and name with .pdf, the PDF opens in a new tab beside it with Annotate on. The original is never changed | Raph: "text based docs will first ask to save as pdf" |
| Blank canvas | **File > New Canvas** (⌘N; ⌥⌘N if ⌘N is taken) opens a tab "Untitled canvas": 1000 x 1000 px, transparent, Annotate on. A checkerboard shows where it is transparent. Its right edge, bottom edge and corner drag to resize it | Raph's defaults |
| Layers and depth | Every canvas is a stack: the **Background** at the bottom, raster layers, and **objects** on top. An object is a shape, line, curve, arrow, pen line, text box, picture (pasted, inserted, or a selection that was moved) or, on a PDF, a placed text, mark or signature. Each object is its own layer, so it keeps its depth and stays editable: right-click it for Bring to Front, Bring Forward, Send Backward, Send to Back, Merge Down, Duplicate, Delete | Windows 11 Paint has layers but turns shapes into pixels as soon as you click away; Raph asked for depth you can change later, by right-click |
| Pen and pixel tools | Fill & Sign's **Pen** and **Arrow** stay: vector lines, each an object, sharp at any zoom and on paper (Tools group). Paint's **Pencil**, nine **brushes**, **Airbrush**, **Eraser**, **Color Eraser** and **Fill** paint pixels into the **active raster layer** and never into an object | Both are useful: a pen line you can move, a brush stroke with texture |
| Right button | Right-click without moving, or Control-click: the context menu of what is under the pointer (an object, the selection, or the canvas). Right-drag with a pixel tool or a shape tool: draws with Color 2, as in Paint | Both of Paint's uses of the right button, told apart by movement (4 pt) |
| Saving a picture | ⌘S, Done, closing the tab, switching to another document or quitting writes the flattened picture into the file, in its own format, with its metadata. Collection keeps the version before the first write, as image rotation does. No "save changes?" question for a file that exists | The app already writes Fill & Sign and rotations into the file; Collection is the undo across sessions |
| Saving a PDF | As Fill & Sign does today: changes are written into the PDF (or its writable copy) after a short pause, as annotations, so every PDF reader shows them (§ 5) | Unchanged behaviour, extended to the new tools |
| Saving a canvas | The first ⌘S asks where (Save panel, PNG chosen, "Untitled.png"); afterwards it is a picture tab like any other. Closing a canvas that was never saved asks Save / Don't Save / Cancel (the only question). Quitting keeps it for next launch | Raph: "saved in png"; a never-saved canvas has nowhere to go without asking |
| Layers kept | Pictures: layers and objects are kept beside the picture, in `<state>/Annotate/<hash of path>.szpaint`, and come back when the same file is opened again unchanged (size and modification time match). File > Save As offers **Shenzhen Paint project (.szpaint)** to keep them in a file of your choice; the app opens `.szpaint` files. PDFs: kept in the PDF itself (§ 5) | Matches Paint's `.paint` project files; reopening keeps objects movable |
| Formats that can't be written | WebP, camera RAW and animated GIF or HEIC: Annotate works on a copy and the first save asks where, PNG chosen. The palette says so: "Annotate saves a copy of this picture as PNG." | ImageIO can't write WebP or RAW; flattening an animation would lose frames |
| JPEG | Written at quality 0.92 with the original metadata and colour profile. Transparent pixels are flattened onto white | Same as Paint and Preview |
| One set of operations | Every change, from a click, a menu, a key, `szpdf`, the AI assistant or MCP, is one **operation** (§ 6), applied by one function, undone by one stack per tab. The UI never changes a document any other way | "Make sure the agents can use all the tools always": parity by construction, not by a list kept in step |
| Where the code lives | The canvas model and every pixel operation in the portable C core (`core/spdf_paint_*.c`), drawing with MuPDF's own draw device (antialiased paths, strokes and text into `fz_pixmap`s); PDF pages read and written with MuPDF's annotation API next to the existing Fill & Sign core. The Mac UI in AppKit, the Fill & Sign controller, overlay and palette grown rather than duplicated | GTK and Windows get it later with no second engine |
| Launch | Nothing runs before first paint: no Annotate object, file or font is touched until Annotate is opened, a form PDF is detected (as today), or a `.szpaint` or canvas tab is restored | Raph's standing rule |

## 1. The window

Annotate is the Fill & Sign palette grown: it stays at the top of the page area, two rows, the second showing the
options of the chosen tool, and keeps the room it reserves above the pages (`topReserve`). On a picture or canvas
the canvas sits in the page area, centred, with the checkerboard under transparent pixels. On a PDF the pages scroll
as today and each page is its own canvas; the tools act on the page under the pointer, and the Layers panel and
status bar follow the page that was last touched (or the page most in view).

**Row 1 (always):** on a PDF first the Fill & Sign group (Text, ✓ | ✗, Signature ▾, and "3 of 12 filled" when the
PDF has a form), then on every document: Selection ▾ · Image group · Tools group (Pen, Arrow, Pencil, Fill, Text box,
Eraser, Color picker, Magnifier) · Brushes ▾ · Shapes ▾ · Color 1 / Color 2 · palette · Layers · Done. On a narrow
window, groups collapse to their icons, then into a "More" menu, Done always last and named. The copy note of Fill &
Sign ("You're filling in a copy…") stays, worded for annotations where it applies: "You're annotating a copy,
because the original can't be changed. Choose File > Save As... to put it where you want."

**Row 2 (options of the chosen tool):** size slider with its value (px on pictures, pt on PDFs), opacity slider (Pencil
and brushes), and the tool's own options (below). Shapes add Outline ▾ and Fill ▾. Text box adds the text bar. Pen and
Arrow keep their colours and widths of today, and also take Color 1 and the size slider.

**Layers panel:** a sidebar on the right of the canvas (the minimap's place while Annotate is on; the minimap comes
back on Done), shown by the Layers button or ⇧⌘L. Top of the list is front. Each row: thumbnail, name ("Background",
"Page 3" on a PDF, "Drawing", "Layer 2", "Rectangle", "Text: Hello", "Picture", "Pen line", "Signature"), eye
(hide/show), and while selected an opacity slider. A PDF page's Background row shows a lock and has no eye, opacity or
delete. Drag rows to
reorder (= depth). Buttons under the list: New Layer, Duplicate, Merge Down, Delete. The active raster layer is marked
with a brush badge; selecting an object row selects that object on the canvas.

**Status bar** (bottom of the page area while Annotate is on): pointer position, selection or object size, canvas or
page size (px on pictures, pt on PDFs, with the page number), Fit, zoom percentage menu, zoom slider. Toggle: View >
Status Bar.

**View:** zoom 12.5 %–800 % (⌘+ / ⌘- / ⌘0 actual size / ⌘9 fit, the app's existing zoom keys), pinch, ⌥-scroll;
pixels are drawn sharp (nearest neighbour) above 100 %. View > Rulers (⇧⌘R) shows px rulers on top and left. View >
Gridlines (⌘') draws a 1 px grid from 400 %. View > Full Screen (the app's). View > Thumbnail shows a small floating
view of the whole picture while zoomed in.

**Checkerboard:** 8 x 8 screen-pt squares, #FFFFFF / #E8E8E8 in light appearance, #3C3C3C / #323232 in dark; only on
screen, never in a saved file or a page picture.

**Canvas handles** (pictures and canvases, not PDFs): the right edge, the bottom edge and the bottom-right corner each show a small square handle. Drag
one: a dotted outline follows, the status bar shows the new size; release resizes the canvas (anchored top-left; new
area transparent). Shift keeps the ratio on the corner. Minimum 1 x 1, maximum 16384 x 16384 and 268 M pixels.

## 2. Tools

Every tool's settings (size, opacity, brush, shape styles, font) are remembered in `<state>/Annotate/settings.json`
(Fill & Sign's `drawing.json` is read once into it), read the first time Annotate opens, written on change.

Every tool works on every document. On a PDF page "the active raster layer" is that page's drawing layer (made on the
first stroke, named "Drawing"), and anything that would change the Background changes nothing there: those commands
are greyed out, with a tooltip "The page itself can't be changed."

### Selection ▾

| Item | Behaviour |
|---|---|
| Select (S) | Fill & Sign's Select: click an object to select it, drag a box from empty canvas to select every object it touches. Pressed again: Rectangular selection, then Free-form selection |
| Rectangular selection | Drag a marching-ants rectangle; Shift makes it square. Drag inside it to move: the pixels lift out of the active layer into a new **Picture** object at the same place (the hole is transparent, or Color 2 when "Transparent selection" is off and the layer has no alpha, as Paint) |
| Free-form selection | Drag a lasso; closes itself on release. On a PDF, a pixel selection selects from the drawing layers only (Copy takes what you see, page included) |
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
| Pen (P) | Fill & Sign's pen, unchanged: smoothed vector lines, each line an object (moves, restyles, erases as today), Color 1 or the four Fill & Sign colours, width 1/2/4 or the size slider |
| Arrow (A) | Fill & Sign's arrow, unchanged: a vector arrow object, both ends draggable |
| Pencil (N) | Hard-edged freehand pixels, no antialiasing, 1–20 px (default 1); Shift draws straight lines; opacity |
| Fill (F) | Flood fill from the click with Color 1 (right-click: Color 2) on the active raster layer, bounded by the edges you see (all visible layers, the PDF page included). Option: Tolerance 0–100 % (default 0, Paint), Contiguous (on; off = replace that colour everywhere, classic Shift-fill). Fill clicked on an object fills the object's own fill (a shape gets solid fill) |
| Text box (⇧T; T where there is no Fill & Sign Text) | Drag a box (or click for a growing box). Text bar: font family, size (8–400 pt), Bold ⌘B, Italic ⌘I, Underline ⌘U, Strikethrough, alignment left/centre/right, Color 1 for text, background Transparent or Opaque (Color 2). The text is a **Text object**: double-click to edit again, any time. (Fill & Sign's form Text, T on a PDF, stays as it is: snaps to fields and lines, one line, form-sized) |
| Eraser (E) | Pressed again: switches between Fill & Sign's **Whole lines** (removes whole pen lines and arrows it touches) and **Pixels**: a square eraser 4–100 px painting transparency into the active raster layer (Color 2 where the layer has no alpha), which also cuts pen lines it crosses (Fill & Sign's "Parts"). Right-drag: **Color Eraser** — replaces only Color 1 pixels with Color 2 (classic). Never touches a PDF page |
| Color picker (I) | Click: Color 1 from what you see; right-click: Color 2. Option: Pick from all layers / active layer. Returns to the previous tool after one pick, as Paint |
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
  object shows its box, eight handles and a rotation handle; drag to move, handles to resize, rotation handle to rotate
  (Shift: 15° steps). Resizing keeps the proportions unless Shift is held (a corner keeps the opposite corner in place,
  an edge the opposite edge, centred across; a line flat in one direction has no proportions to keep). Every object
  resizes: shapes, text boxes (the text reflows in the new box), pictures (pasted, inserted or lifted), pen lines and
  arrows, on pictures, canvases and PDF pages; several selected objects resize together, keeping their places in the
  box around them. One resize is one `object.transform` with the new `rect`, undone in one step, and agents resize the
  same way. On a PDF, Select is Fill & Sign's for its own items and Annotate's for shapes, text boxes, pictures and pen
  lines. Double-click edits a text box, a curve's points or a polygon's corners.
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

Key letters work while the canvas has the keyboard and no text box is being typed in, as Fill & Sign's do today. Fill
& Sign's keep their meaning (P Pen, A Arrow, E Eraser, S Select, T Text on a PDF); the new ones: N Pencil, B Brush (B
again cycles brushes), F Fill, I Color picker, Z Magnifier, U Shapes (U again cycles), L Line, ⇧T Text box, X swap
colours, D default colours, [ and ] size. Any ⌘ shortcut above that the app already uses for
something else keeps the app's meaning; the UI agent lists clashes and picks the fallback (⌥ added) in
`Annotate keys` below.

## 5. Files

- **Opening:** a document opens as today (nothing new at open). Annotate loads a picture's layers only when it is
  turned on, or at once for a `.szpaint` file or a restored canvas tab; a PDF page's annotations are read as Fill &
  Sign reads its items today (per page, when Annotate is on).
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

### PDFs

Everything added to a PDF page is written into the PDF as annotations, in the page's `/Annots` order, which is the
depth order (first = back). Each carries its full editing parameters in a private dictionary `/SPDFAnnotate`
(version, kind, and the operation arguments that made it), so it can be edited again; other readers draw its
appearance stream. Fill & Sign's existing items (`spdf-fill-*` names, Ink pen lines and arrows, FreeText, stamps)
are objects of this model as they are, with no rewrite of files already filled.

| Layer or object | Written as |
|---|---|
| Drawing layer (pixels from Pencil, brushes, Airbrush, Fill, pixel erasing) | One `Stamp` annotation per drawing layer and page, its appearance an image XObject (RGBA, SMask for alpha) cropped to the pixels used, at 2x the page's resolution in points (Pencil stays hard-edged at that resolution); `/NM` `spdf-annotate-layer-<uuid>` |
| Pen line, Arrow | As today: `Ink` |
| Line, Arrow line, Curve | `Ink` with the drawn points (curves flattened for the appearance, control points in `/SPDFAnnotate`) |
| Rectangle, Rounded rectangle, Oval | `Square` / `Circle` with `/IC` fill and `/BS` width when the style is solid; textured outline or fill styles as a `Stamp` whose appearance is the drawn shape |
| Polygon, Triangle, Right triangle, Diamond, Pentagon, Hexagon, stars, block arrows, Heart, Lightning, callouts | `Polygon` (solid styles) or `Stamp` (textured), appearance always generated by us |
| Text box | `FreeText` with our appearance (font embedded as a subset where MuPDF allows, else a standard font substitute recorded in `/SPDFAnnotate`) |
| Picture | `Stamp` with an image appearance |
| Fill & Sign text, marks, signatures | As today |

Layer visibility on a PDF is the annotation's Hidden flag; layer opacity is `/CA`. Merge Down of an object into the
drawing layer rasterises it into that layer's image. The page itself is never rewritten. Writing follows Fill & Sign's
commit cycle (pending batch, 0.35 s rest, written before any other reader of the file, no wrong frame, writable copy
when the original can't be changed, Collection). Save Final Copy (flatten) keeps working and bakes these too.

### Text documents

Turning Annotate on for a Markdown, plain text or other non-PDF, non-picture document shows the question of §
Decisions. Save as PDF writes the PDF the app's print and `szpdf export-pdf` make, opens it in a new tab next to the
original, and turns Annotate on there. Cancel leaves Annotate off. The original tab stays as it was.

## 6. Operations (the single path for UI and agents)

One JSON object per operation: `{"op": "<name>", ...arguments}`. On a picture or canvas, coordinates are canvas
pixels, origin top-left, y down. On a PDF every operation that touches a page takes `page` (1-based) and coordinates in
PDF points from the page's top-left corner as displayed (rotation applied); an operation that would change the page
itself answers `{"ok":false,"error":"page_locked","message":"The page itself can't be changed."}`. On a text document
every operation but `doc.save_as_pdf {path?}` answers `needs_pdf` with "Save this document as a PDF to annotate it.".
Colours are `"#RRGGBB"` or `"#RRGGBBAA"`. Every operation is validated, applied by `spdf_paint_apply(doc,
json, &result)` in the core, recorded on the undo stack (except the read-only ones) and answers a JSON result
(`{"ok":true, ...}` or `{"ok":false,"error":"<code>","message":"<plain sentence>"}`). `spdf_paint_schema()` returns
the list below as JSON Schema; `szpdf annotate schema`, the assistant's tool descriptions and the MCP server are
generated from it, so a new operation appears everywhere at once.

| Family | Operations |
|---|---|
| Canvas | `canvas.new {width=1000, height=1000, background="transparent"\|"#RRGGBB"}`, `canvas.resize {width, height, anchor="top-left"…"bottom-right", fill="transparent"\|color}`, `canvas.properties {dpi, blackAndWhite}` |
| Image | `image.resize {width, height \| percent, keepRatio=true, scope="auto"\|"image"\|"selection"\|"object"}`, `image.skew {horizontal, vertical, scope}`, `image.rotate {degrees, scope}`, `image.flip {axis:"horizontal"\|"vertical", scope}`, `image.crop {rect?}`, `image.invert {scope}`, `image.clear`, `image.remove_background {scope}` |
| Selection | `select.rect {x,y,w,h}`, `select.freeform {points}`, `select.all`, `select.none`, `select.invert`, `select.delete`, `select.lift` (→ object id), `select.transparent {on}` |
| Pen and arrow | `pen.add {points, color, width}`, `arrow.add {tail, tip, color, width}` (Fill & Sign's vector items; edited, moved, erased and restyled with the object operations; `erase.lines {points, size}` removes whole pen lines and arrows it touches) |
| Pixels | `paint.stroke {tool:"pencil"\|"brush"\|"calligraphy1"\|"calligraphy2"\|"airbrush"\|"oil"\|"crayon"\|"marker"\|"natural_pencil"\|"watercolor"\|"eraser"\|"color_eraser", points:[[x,y,(pressure)],…], color?, size, opacity, seed?}`, `paint.fill {x, y, color?, tolerance=0, contiguous=true}`, `color.pick {x, y, from:"visible"\|"layer"}` (read-only) |
| Objects | `shape.add {shape, rect \| points, rotation=0, outline:{style,color,width}, fill:{style,color}}`, `text.add {rect, text, font, size, bold, italic, underline, strikethrough, align, color, background:"transparent"\|color}`, `picture.add {path \| clipboard:true \| png_base64, rect?}`, `object.update {id, …any add argument}`, `object.move {id \| ids, dx, dy}`, `object.transform {id, rect?, rotation?, flip?}`, `object.order {id \| ids, to:"front"\|"forward"\|"backward"\|"back"\|index}`, `object.merge_down {id}`, `object.duplicate {id}`, `object.delete {id \| ids}` |
| Layers | `layer.add {name?, above?}`, `layer.duplicate {id}`, `layer.delete {id}`, `layer.merge_down {id}`, `layer.set {id, name?, visible?, opacity?}`, `layer.order {id, to}`, `layer.activate {id}` |
| Colours | `colors.set {color1?, color2?}`, `palette.set_custom {index, color}`, `palette.save {path}` / `palette.load {path}` (Save Colors… / Get Colors…: `.json` or Paint `.pal`) |
| History | `history.undo {steps=1}`, `history.redo {steps=1}` |
| Forms (PDF) | `form.state` (read-only: fields with names, kinds, values, pages, rects; placed items; "3 of 12 filled"), `form.field_set {name, value}`, `form.text_add {page, x, y, text, size?}`, `form.mark_add {page, x, y, kind:"check"\|"cross"}`, `form.signature_place {page, rect, kind:"signature"\|"initials"}` (the person's saved signature; refused with `no_signature` when none is saved: agents never draw one), `form.remove_drawings`, `form.remove_everything`, `form.save_final_copy {path}` |
| Document | `doc.state` (read-only: size, dpi, layers and objects with ids, kinds, bounds and parameters, active layer, selection, colours, zoom, dirty, file and format), `doc.render {out, region?, scale?, layers?}` (read-only: a PNG to look at), `doc.save`, `doc.save_as {path, format, quality?}`, `doc.save_as_pdf {path?}` (text documents: makes and opens the PDF, answers its tab), `doc.copy {scope, out?}` (`out`: a PNG file instead of the clipboard, Copy to file…), `mode.set {on}` (Annotate on or off, Done) |
| View (UI state only, not undone) | `view.zoom {level \| "fit" \| "actual"}`, `view.set {rulers?, gridlines?, statusbar?, thumbnail?}`, `tool.choose {tool, options}` (what the palette shows) |

A brush stroke from the mouse is previewed locally and applied as one `paint.stroke` with all its points on release
(airbrush and the textured brushes take a `seed`, so replaying the operation gives the same pixels). A drag of an
object is one `object.move` on release. Text typing is one `object.update` when the box closes.

Fill & Sign's actions are these same operations: its Pen is `pen.add`, Arrow `arrow.add`, Whole-lines eraser
`erase.lines`, pixel eraser `paint.stroke {tool:"eraser"}`, Select's move and restyle `object.move` /
`object.update`, the two Remove commands `form.remove_drawings` / `form.remove_everything`, ⌘Z `history.undo`. One
undo stack per tab, as Fill & Sign has today.

### Agent surfaces

- **szpdf** (agent-interface.md): `szpdf canvas new [--width W] [--height H] [--background C] [--front]` → the new
  tab's id; `szpdf annotate <file|tab> <op> [--key value …]` (flags map to the operation's arguments, `--json '{…}'`
  takes them whole); `szpdf annotate <file|tab> --script ops.json` applies an array in order and stops at the first
  error, answering each result; `szpdf annotate <file|tab> state [--page N]`; `szpdf annotate schema [op]`. Annotate
  is turned on for the tab if it is off; the window does not come forward.
- **AI assistant** (SPDFMacAITools): `annotate_apply {target, ops:[…]}`, `annotate_state {target, page?}`,
  `annotate_look {target, page?, region?}` (returns the picture to the model), `canvas_new {width, height,
  background}`. Edits are undoable by the person with ⌘Z like their own, and listed in the chat.
- **MCP** (`shenzhen-pdf-mcp.py`): `annotate_apply`, `annotate_state`, `annotate_render`, `canvas_new`, all through the
  szpdf channel.

The parity check at the end lists every palette control, menu item, context menu item and key, and the operation it
sends; anything without one is a bug.

## 7. Not included

- **AI generation** (Cocreator, generative fill, generative erase, sticker generator): these send pictures to a
  service. The assistant can already do agent-driven edits through `annotate_apply`; a generative tool would need its
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
| `spdf_paint_pdf.c` | A PDF page as a canvas: the page rendered as the locked Background (render only, at the zoom asked), its annotations read into layers and objects (ours from `/SPDFAnnotate`, Fill & Sign's from their names, other readers' annotations shown but locked), and every change written back as the annotations of § 5 PDFs through the Fill & Sign core's writing path (`spdf_fill_*`), z-order as `/Annots` order |

Pixels are premultiplied RGBA8 `fz_pixmap`s, one per raster layer and per Picture object. The composite is cached in
tiles and recomposited only where changed. Each file stays under 500 lines (split further if needed).

### Mac (`mac/`)

The Fill & Sign controller, overlay and palette are grown, not duplicated: one mode, one per-window controller, one
overlay per document view, one palette, one undo stack per tab. New files carry the canvas-specific parts.

| File | Content |
|---|---|
| `SPDFMacFillController*` (existing, renamed in UI text only) | Stays the per-window controller of the mode: on/off, Done, auto-on for forms, flush hooks, undo per tab, the writable copy. Gains the single `-applyOperation:tab:completion:` that every control and agent surface uses (§ 6), routing Paint operations to the canvas session and form/pen/arrow operations to the existing Fill & Sign code |
| `SPDFMacAnnotateSession.{h,mm}` | Per tab: the core canvas (picture) or one core canvas per touched PDF page, tool, colours, selection; picture saving (flatten, encode, write, Collection), autosave of the `.szpaint` beside a picture 2 s after the last change; PDF pages written through the Fill & Sign commit cycle |
| `SPDFMacAnnotateCanvasView.{h,mm}` | Drawn by the overlay over a picture or each PDF page: composite tiles (sharp above 100 % on pictures), checkerboard, selection ants, object handles and rotation handle, live stroke preview, canvas handles, rulers and grid; gestures to operations |
| `SPDFMacFillPalette` (existing) + `SPDFMacAnnotatePaletteGroups.{h,mm}` | Rows 1 and 2 of § 1: the Fill & Sign group on PDFs, then every Paint group |
| `SPDFMacAnnotateLayersPanel.{h,mm}` | The Layers sidebar |
| `SPDFMacAnnotateSheets.mm` | Resize and skew, Canvas size and properties, Rotate by…, the text-document "Save as PDF" question |
| `SPDFMacAnnotateMenus.mm` | Menu items, context menus, keys, validation |
| `SPDFMacAnnotateImageIO.{h,mm}` | Decode a picture into the core canvas, encode the flattened picture, formats, metadata, the font resolver (CoreText → font file paths) |
| `SPDFMacAnnotateIntegration.{h,mm}` | The toolbar button renamed Annotate for every document, File > New Canvas, canvas tabs (state restore, Save panel), `.szpaint` opening, text documents → Save as PDF, tab close and quit hooks |
| `SPDFMacSzpdfAnnotate.mm`, `SPDFMacAIToolsAnnotate.mm` | `szpdf annotate`, `szpdf canvas` and the assistant tools, all through `applyOperation:` |

Edits to existing files are one line each where possible (menu table entries, the toolbar button, tab close and quit
flush hooks, the Makefile). `ShenzhenPDFMac.mm` does not grow. Every "Fill & Sign" the person sees becomes
"Annotate", except the form group's own label on PDFs ("Fill & Sign") and the Remove command "Remove Everything Added
with Annotate".

### Annotate keys

From the app's real key table (menus dumped from a running copy, 2026-11-25). Where the app already used a key it
keeps it, and Annotate takes the fallback with ⌥ added. Letters work while the page or canvas has the keyboard and
nothing is being typed (they are claimed before type-to-search starts); ⌘ keys are menu items.

| What | Spec | Used | Why it differs |
|---|---|---|---|
| Annotate on / off | ⌥⌘F | ⌥⌘F | Fill & Sign's item, renamed |
| File > New Canvas | ⌘N | ⌘N | free |
| File > Save | ⌘S | ⌘S | saves a picture or canvas Annotate changed; on every other document ⌘S keeps the app's meaning (Save As…) |
| File > Save As… | ⇧⌘S | ⇧⌘S | was ⌘S; ⌘S still reaches it everywhere but on pictures and canvases |
| Edit > Undo / Redo | ⌘Z / ⇧⌘Z, ⌘Y | ⌘Z / ⇧⌘Z, ⌘Y | free (Fill & Sign took them in its overlay; now menu items, history.undo / history.redo); text being typed keeps its own undo |
| Edit > Repeat | F4 | F4 | free |
| Cut / Copy / Paste / Select All | ⌘X / ⌘C / ⌘V / ⌘A | the same | the Edit menu's own items: they become doc.copy, select.delete, picture.add, select.all while a canvas tool is chosen, and keep their meaning otherwise |
| Paste from file… | ⇧⌥⌘V | ⇧⌥⌘V | free |
| Invert selection | ⇧⌘I | ⌥⇧⌘I | ⇧⌘I is View > Invert Image Colors in Dark Theme |
| Crop to selection | ⇧⌘X | ⇧⌘X | free |
| Resize and skew… | ⌥⌘I | ⌥⌘I | free |
| Invert colors | ⌃⌘I | ⌃⌘I | free |
| Canvas size and properties… | ⌥⌘C | ⌥⌘C | free |
| Clear image | ⇧⌘⌫ | ⇧⌘⌫ | free |
| Bring to Front / Bring Forward / Send Backward / Send to Back | ⌥⌘] / ⌘] / ⌘[ / ⌥⌘[ | the same (Edit > Arrange) | free |
| Duplicate | ⌘D | ⌥⌘D | ⌘D is Go To > Previous Document |
| View > Layers | ⇧⌘L | ⇧⌘L | free |
| View > Rulers | ⇧⌘R | ⌥⇧⌘R | ⇧⌘R is View > Rotate Anticlockwise |
| View > Gridlines | ⌘' | ⌘' | free |
| Zoom: actual size / fit | ⌘0 / ⌘9 | ⌘4 / ⌘1 | the spec asks for "the app's existing zoom keys": Zoom > 100 % is ⌘4 and Fit Page ⌘1 (⌘0 and ⌘9 were a mistake in the spec). With Annotate on a picture or canvas, 100 % (the toolbar, the status bar, ⌘4, the Magnifier) is one picture pixel per screen point, as Preview's actual size; the reader alone lays pictures out at 96 px to the inch |
| Text bar Bold / Italic / Underline | ⌘B / ⌘I / ⌘U | the same, inside the text box being typed in only | ⌘B is Favorite Current Page and ⌘I the reading theme: the text box takes them first (the key window's views see key equivalents before the menu bar), the app keeps them elsewhere |
| Pen, Arrow, Eraser, Select | P, A, E, S | the same | Fill & Sign's; E again: Whole lines / Pixels; S again: Rectangular, then Free-form selection |
| Fill & Sign Text (PDF) / Text box | T / ⇧T | T on a PDF is Fill & Sign's Text; ⇧T the Text box; T is the Text box on pictures and canvases | as the spec |
| Pencil, Brush, Fill, Color picker, Magnifier | N, B, F, I, Z | the same | B again cycles the brushes |
| Shapes, Line | U, L | the same | U again cycles Rectangle, Oval, Line, Arrow line |
| Swap colours / default colours | X / D | the same | X turns a focused or hovered mark into a cross, as in Fill & Sign; elsewhere it swaps |
| Size down / up | [ / ] | the same | one step (1 px or pt) within the tool's range |
| Delete, Escape, arrows | ⌫, Esc, ←↑→↓ | the same | act on Annotate's selection (Shift: 10) before the page scrolls; with Fill & Sign's tools they stay Fill & Sign's |

## 9. Orchestration

Every brief carries: no pkill/killall/sudo (stop own PIDs); no `rm -rf` with variables, globs or `$(...)`; no
filesystem-wide searches; never launch, quit or touch Raph's running ShenzhenPDF, its settings, Collection, keychain or
Friends; no tests or suite changes in the repo; new files ≤ 500 lines; no growth in capped files; work only in your
own worktree and branch; no push to main, no release; user-visible text exactly as written here.

| Wave | Agent | Work | Branch |
|---|---|---|---|
| 0 | Architect | Headers (`spdf_paint.h` with every operation's C entry, the internal structures, `SPDFMacAnnotateSession.h`, the controller's `applyOperation:`), the operation schema JSON, stubs that compile, Makefile and `CORE_OBJS` lines | `feat/pdf-paint` |
| 0 | Fill & Sign check | The Fill & Sign final check (fill-and-sign.md § Final check and § Pen and arrow), fixing every bug it finds; merged first by the integrator | `fix/fill-sign-final-check` |
| 1 | Core A | `spdf_paint_doc.c`, `_ops.c`, `_history.c`, `_file.c`, `_transform.c` | `paint/core-a` |
| 1 | Core B | `spdf_paint_brush.c`, `_fill.c`, `_shapes.c`, `_text.c` | `paint/core-b` |
| 1 | PDF | `spdf_paint_pdf.c`, the PDF page canvases in the overlay, routing of form/pen/arrow operations, the Fill & Sign items as objects with depth | `paint/pdf` |
| 1 | Mac UI A | Session, canvas view, ImageIO, integration (button, New Canvas, pictures saving, restore, text documents → PDF) | `paint/ui-a` |
| 1 | Mac UI B | Palette groups, layers panel, sheets, menus and keys, renaming to Annotate | `paint/ui-b` |
| 1 | Agents | `szpdf annotate/canvas`, assistant tools, MCP, agent-interface.md | `paint/agents` |
| 2 | Integrator | Merge the Fill & Sign fixes, then the six branches, build, size caps, static launch checks, a first run | `feat/pdf-paint` |
| 3 | Verifier | § Final check | — |
| 4 | Fixer | Every finding | `feat/pdf-paint` |

## 10. Final check (once, at the end, nothing added to the repo)

1. **Static:** no new initialiser or `+load`; `applicationDidFinishLaunching`, `loadPersistentState` and `main()`
   reference no Annotate symbol except the canvas-tab restore path, which runs only when such a tab exists;
   `apps/pdf/tools/check-file-sizes.sh`.
2. **Launch gate:** `make -C apps/pdf/portable mac-launch-performance-tests LAUNCH_PERF_BASELINE_RELEASE=latest`.
3. **Real UI** on an isolated test copy (own HOME and state folder outside /tmp, Friends off, windows in the
   background, stopped by PID), driven with real clicks, drags, keys and right-clicks, screenshots from the first frame
   on, looked at as a first-time user: every tool on a PNG with transparency, a JPEG, a HEIC, a WebP (copy), a GIF; a
   new canvas resized by its handles and saved as PNG (check alpha with `sips`/a pixel read); objects of each kind
   reordered by right-click and by the Layers panel; undo/redo across every operation; Save, close, reopen (objects
   come back); `.szpaint` Save As and open; quit during a stroke; a 8000 x 8000 picture (stroke latency, memory).
   PDFs: every tool on a page of a plain PDF and of a form PDF (Fill & Sign's flows as in fill-and-sign.md still
   pass); the page can't be erased, filled into, cropped or lifted; objects and Fill & Sign items reordered; the file
   checked with `mutool show` (annotation kinds, `/Annots` order, `/SPDFAnnotate`), drawn by PDFKit and `qlmanage -t`
   the same as in the app; reopen and edit again. A Markdown file: Annotate asks to save as PDF, the PDF opens with
   Annotate on, the Markdown is unchanged.
4. **Agents:** every operation in `szpdf annotate schema` applied through `szpdf` on a test canvas and on a PDF page,
   then the same script through the assistant tool and MCP, with the three results and renders identical; every
   `form.*` operation on a throwaway PDF form; `doc.save_as_pdf` on a Markdown file.
5. **Parity:** the list of UI controls and the operation each sends (§ 6); none without one.
