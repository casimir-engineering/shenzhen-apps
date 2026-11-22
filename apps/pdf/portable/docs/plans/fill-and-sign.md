# Fill & Sign

Status: planned 2026-11-22, branch `feat/pdf-fill-sign` (off origin/main 6708d8eb). Merged from three designs
(UX-first, PDF-engine-first, launch-performance-first). No code yet.

Raph's request: fill and sign documents, with a saved signature, optional default text, text that snaps to boxes
and underlines, check and cross marks (check by default) that snap to boxes, intuitive to use, switched on at once
when the PDF has a real form, no cost at launch (ideally a gain), testing only at the end.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Real forms | Values go into the PDF's own fields (`/V`, `/AS`) through MuPDF, which redraws their appearance | Every reader shows and edits them |
| Auto-on | A tab whose PDF has at least one fillable field opens with Fill & Sign on. "Fillable" = a text, checkbox, radio or choice field that is not read-only, or an unsigned signature field. An `/AcroForm` with empty `Fields` (6 of 9 sample PDFs), only signed signatures, or XFA only does not count | No false positives on Word/Acrobat exports or signed specs |
| Other PDFs | Toolbar button, Edit ▸ Fill & Sign (⌥⌘F) | ⌘F, ⇧⌘F, ⌃⌘F are taken; ⌘E is the macOS "Use Selection for Find" key |
| Placed text | `FreeText` with `/IT /FreeTextTypeWriter` (what Acrobat's Fill & Sign writes), border 0, no fill, `/DA "/Helv <size> Tf 0 g"` | Standard, editable in Acrobat and Preview |
| Check and cross | `Ink` annotation, two strokes, round caps | Every reader redraws it identically from `/InkList`; no font |
| Signature | `Stamp` with our own appearance: filled vector outlines for drawn and typed signatures (`pdf_set_annot_appearance_from_display_list`), `pdf_set_annot_stamp_image` for a picture | Crisp, small, colour can change; pictures keep their transparency |
| Identity | `/NM (spdf-fill-<uuid>)`; signatures `spdf-fill-sig-<sigid>-<uuid>`; comb cells `-c<NN>`. No private keys | `/NM` survives saves, renumbering and other editors |
| Comments | `spdf_comment_review.h` skips the `spdf-fill-` prefix and `FreeTextTypeWriter` | Fills never show as comments, in AI tools or szpdf |
| Saving | Like comments: each change goes into `_doc` at once, an incremental save follows 300 ms after the last change, flushed at once on Done, tab switch, close, quit, print, export, share and Copy Page. No Save button, no unsaved state | Matches the rest of the app |
| Collection | `collectionDidSavePath:` only on flush points (Done, tab switch, close, quit) and after 5 s of no edits | 30 Tab presses must not start 30 captures |
| Sending a clean copy | File ▸ Save Final Copy… writes a separate PDF where fills become part of the pages | For sending to someone; the working file stays editable |
| JavaScript | Never enabled | Safety and launch time; computed totals stay stale (risk) |
| Undo | One `NSUndoManager` per tab session with inverse operations, replayed through the same engine calls and save cycle | MuPDF's journal does not survive worker reloads |
| Signatures on the Mac | `<state>/Signatures/`, 0700 folder, 0600 files, atomic writes, no keychain | No blocking keychain prompts; Raph can choose the keychain later |
| Default text | Suggestions (My Details + saved texts + today's date) in the empty editor, ranked by the nearby label; a likely match is pre-highlighted but never written until Return | "Optional default text" without fields filling by accident |
| Snapping | Computed only in fill mode, visible pages ±1, on a background document, cancellable, with a segment budget | Free when unused; cheap on schematics |
| Launch | Nothing new before first paint except one toolbar button. Two gains: one document open instead of two for outline + comments (+ form summary), and the comment loader skips pages with no `/Annots` | Raph asked for no cost, ideally a gain |

## 1. User flows

### A. A PDF with a real form

1. The page paints exactly as today.
2. The post-paint Metadata stage reads the form summary (§ CORE 1). If fillable, Fill & Sign turns on for that tab:
   - fillable fields get a light accent tint (10% fill, 1 pt outline at 35%); required fields get a stronger
     outline; filled fields a lighter tint, so progress shows at a glance;
   - the palette fades in (150 ms) at the top centre of the page area; nothing reflows, fit and scroll stay;
   - the toolbar button shows as on;
   - keyboard focus is not taken: Space and arrows still scroll.
3. Click a text field: an editor sits exactly over it. Tab goes to the next field, Return commits a single-line
   field, Escape reverts. Font size follows `/DA` (0 = fit the height), MaxLen is enforced, comb fields space one
   character per cell, multiline wraps (Return adds a line, ⌘Return commits).
4. Checkbox or radio: click or Space toggles, with the form's own glyph. Radio clears its group (across pages).
5. Choice field: a native menu at the field; an editable combo also takes typing.
6. Unsigned signature field: click places the last-used signature fitted inside. With none saved, the signature
   sheet opens first. A signed signature field cannot be clicked.
7. Read-only fields: no tint, clicks do nothing, hover tooltip "This field can't be changed".
8. First form ever, the palette shows one line until the first edit: "Click a highlighted field to type. What you
   enter is saved as you go."
9. Done hides the palette and tints for this tab. Clicking a field afterwards turns the mode back on and focuses
   that field, so a click never does nothing.

### B. Any other PDF (flat form, scan, contract)

1. Toolbar **Fill & Sign** or ⌥⌘F opens the palette. Text selection pauses while a placing tool is active; Done
   brings it back.
2. **Text** is the default tool and is smart:
   - hover lights up the target under the pointer: a box or cell glows, an underline glows with a ghost caret at
     the baseline the text will use, a small square shows a faint ✓;
   - click a small square: places the current mark;
   - click an underline, box, cell or empty space: starts typing there, snapped (§ CORE 3);
   - ⌘ held while clicking or dragging turns snapping off.
3. **Mark** is a two-segment control [✓ | ✗], ✓ selected each time the palette opens. With Mark selected, every
   click places a mark (snapped into a box when there is one). Option-click places the other mark.
4. Clicking one of our marks removes it, like a checkbox. On a selected or hovered mark: X makes a cross, V a check,
   Space toggles. Right-click: Check, Cross, Remove.
5. Tab and ⇧Tab move through detected lines, boxes and empty table cells in reading order, so flat forms fill from
   the keyboard.

### C. Signing

- **First time:** Signature ▸ Add Signature… opens the sheet. After Use Signature, a translucent copy follows the
  pointer, snapped to sit on the nearest line or fit inside a box. Click places it; Escape drops it.
- **Returning:** the Signature button is split. Main click picks up the last-used signature, the next click places
  it: 2 clicks. The chevron menu shows saved signature thumbnails, an Initials section, Add Signature…, Add
  Initials…, and a Remove submenu.
- It is a picture of a signature, not a certificate signature. The UI never says "digital".

### D. Editing placed items

- Text: click to edit, drag to move (snaps again on drop), right-edge handle for width, corner handle scales the
  font. Empty on commit = deleted.
- Marks and signatures: click selects, corner handles resize with the aspect locked, drag moves.
- Delete removes the selection; arrows nudge 1 pt, ⇧arrows 10 pt; ⌘Z / ⇧⌘Z undo and redo every fill, place, move,
  resize, toggle and delete.

### E. Default text (suggestions)

- An empty editor shows a chip row under it: **Full name**, **Initials**, **today's date**, **email**, saved texts,
  and "Edit My Details…". Typing filters; ↓ then Return picks.
- Ranking uses the field name or tooltip, or the label text left of or above a flat target ("Name", "姓名", "Date",
  "日期", "Email", "Phone", "Initials"). A strong match is pre-highlighted: Return accepts it, typing replaces it, Tab
  leaves the field empty. Nothing is written without a keystroke.
- Editor context menu: "Save for Next Time" adds the current text.
- My Details: name (defaults to the comment author, `currentCommentAuthor`), initials (derived), email, date style
  (locale medium with a four-digit year; or 2026-11-22, 22/11/2026, 11/22/2026).

### F. Keyboard in fill mode

| Key | Action |
|---|---|
| Tab / ⇧Tab | Commit, next/previous field or target: `/Tabs` order when present, else page, then rows (y within 4 pt), then x |
| Return | Commit and go to next (single-line); multiline: new line, ⌘Return commits |
| Escape | 1st: revert edit. 2nd: deselect. 3rd: drop the tool or picked-up signature |
| Space | Toggle checkbox, radio or our mark |
| X / V | Cross / check on the focused mark |
| ⌥↓ | Open a choice field |
| ⌘+ / ⌘− while editing | Text size |
| ⌘Z / ⇧⌘Z | Undo / redo |

### G. Special documents

- **Already signed digitally** (signature fields signed): never auto-on. If the person turns it on, once per
  document: title "This PDF was signed digitally", body "If you fill it in, anyone who checks that signature will
  see the document changed after it was signed.", buttons "Fill In Anyway" / "Cancel". DocMDP P=1 refuses; P=2
  allows field values only (placed items refused with "This PDF only allows filling in its own fields."). When the
  file cannot be saved incrementally, edits go to the existing writable copy so the signature stays valid.
- **Owner forbids filling** (no `'f'` for fields / `'n'` for placed items): "This PDF's owner doesn't allow filling
  it in. Open it with the owner password to continue."
- **Read-only location, Collection, downloads:** the existing `ensureActivePDFCanBeModifiedForOperation:` makes a
  writable copy on the first commit; the session holds the value and re-applies it to the new `_doc`.
- **Hybrid AcroForm + XFA:** `/AcroForm/XFA` is removed on the first fill (as Preview and pdf.js do), otherwise
  Acrobat keeps showing the old XFA data. XFA-only: no auto-on; placed items still work.
- **Save failure:** the value stays on screen with a red outline, and "Couldn't save what you filled in" plus the
  detail.

## 2. UI text (all of it)

Written for the person filling in; no mechanism words. Nothing appears on success.

| Where | Text |
|---|---|
| Toolbar tooltip / accessibility | "Fill in and sign" / "Fill & Sign" |
| Menu | Edit ▸ "Fill & Sign" (⌥⌘F); File ▸ "Save Final Copy…" |
| Palette | "Text", ✓, ✗, "Signature", "Done"; forms: "3 of 12 filled", then "All required fields filled" |
| First-form hint | "Click a highlighted field to type. What you enter is saved as you go." |
| Sheet title | "New Signature" / "New Initials" |
| Sheet tabs | "Draw", "Type", "Picture" |
| Draw | Placeholder "Sign here with your trackpad or mouse"; ink [Black \| Blue]; "Clear" |
| Type | Name field prefilled from My Details, shown in installed script fonts (Snell Roundhand, Bradley Hand, Savoye LET, Apple Chancery) |
| Picture | "A photo or scan of your signature on white paper. The paper is removed." |
| Sheet footer | "Keep for next time" (on), "Saved on this Mac only.", "Cancel", "Use Signature" |
| Signature menu | "Add Signature…", "Add Initials…", "Remove" |
| Read-only field | "This field can't be changed" |
| Save Final Copy panel | "What you filled in becomes part of the pages, so it can no longer be changed." Default name "<name> (final).pdf" |
| Signed PDF, locked PDF, save failure | § 1 G |

## 3. Launch time

Nothing new runs before first paint except building one toolbar button (an NSButton whose symbol draws in
`drawRect`, like `SPDFToolbarToggleButton`, with the `spdf_ocr_toolbar_image`-style fallback if the `signature`
symbol is missing on macOS 12). No `+load`, no static initialisers, no new frameworks, no state file read at
launch. Controller, overlay, palette, editor, queue, signature store and snap code are created on first use.

Form detection costs one bounded walk of `Root/AcroForm/Fields` (measured 0.00–0.21 ms) inside a document open the
app already does after first paint. A session that never uses Fill & Sign never creates any of it.

Gains shipped with the feature:
1. **One open instead of two after first paint.** `loadOutlineForCurrentDocumentAsync` and
   `loadCommentsForCurrentDocumentAsync` (ShenzhenPDFMac.mm:7175, 7224) each open the file on `_preloadQueue`. They
   move to `mac/SPDFMacDocumentMetadataLoading.mm` as one `loadDocumentMetadataAsync` that opens once and loads the
   outline, comments and form summary. Saves 1–6 ms of CPU on typical files, about 41 ms on a 1691-page manual, at
   the moment people start scrolling. The old selectors stay as thin wrappers until callers move. This extraction
   also pays for every hook line in ShenzhenPDFMac.mm (about −90 net) and the cap in
   `apps/pdf/tools/file-size-limits.tsv` is lowered in the same change.
2. **Comment loading skips pages without annotations.** `spdf_load_comments` (shenzhen_pdf_core.c:1339) loads every
   page to read `/Annots`; it checks `pdf_lookup_page_obj(i)/Annots` first and skips. Net zero lines in the frozen
   file (fold into the existing `annots =` line or pay with a join).

Optional, phase U5 only if the gate shows no change: carry the form summary on `SPDFLaunchPrerenderResult` so a
restored form tab shows its tint in the first frame.

Measured and rejected: dropping linked frameworks (≤ 0.3 ms of a 145 ms launch).

## CORE (engine, plain C, shared with GTK and Windows later)

All new units include `spdf_core_document.h` like `spdf_destination.c`; each file ≤ 500 lines.
`shenzhen_pdf_core.c` does not grow. Makefile: `CORE_FILL_OBJS` with rules like `CORE_DESTINATION_OBJ`, added by
`CORE_OBJS += $(CORE_FILL_OBJS)` on its own line (the camera-RAW branch edits the `CORE_OBJS` line). Linux and
Windows source lists are left alone until a front end uses these files.

Threading: writes run on the main-thread `_doc`, as comments do. All reads (summary, page fields, our items, snap
geometry) run on a worker document: the metadata loader's for the summary, the fill queue's own document otherwise.

### Core as built (2026-11-22)

The headers are the contract; where they differ from the sketches below, the headers win:
- `spdf_form_set_*` return how many pages changed (>= 1, written ascending into `pages_changed`) or -1 with err.
  Widgets also carry `export_values` and the flags `SPDF_FIELD_HIDDEN` and `SPDF_FIELD_MULTI_SELECT`; the summary
  also carries `can_fill_fields`, `can_add_items` and `truncated`.
- `spdf_fill_add_text` takes the text box from `spdf_fill_text_rect(x, baseline, width, size, lines)` (MuPDF draws the
  first baseline 0.8 x size under the box top, 1.2 x size leading) and an `author`; comb text is
  `spdf_fill_add_comb_text(cells, …, group_nm, author)`; `spdf_fill_add_signature_paths` takes the drawing's `aspect`.
  A signature id never contains `-`. Items carry `group` and `cell` for comb cells.
- `spdf_snap_resolve(…, purpose, aspect, out)` also takes the signature aspect and reports `SPDF_SNAP_FIELD` when the
  point is on a real field; `spdf_snap_targets_in_order` writes `spdf_snap_target` (kind, rect, probe point).
- Signatures keep their drawing on move because the Stamp's `/Name` is `/Signature`, which MuPDF treats as non-standard
  and never redraws (`pdf_update_appearance`, MuPDF 1.27.2); picture signatures are redrawn from their image.
- Files: `spdf_form.c`, `spdf_fill_items.c` + `spdf_fill_signature.c` (signatures, Save Final Copy),
  `spdf_fill_snap.c` (reading the page) + `spdf_fill_snap_clean.c` + `spdf_fill_snap_place.c`; internal headers
  `spdf_fill_identity.h` (the comment filter, header-only so GTK and Windows link nothing new), `spdf_fill_internal.h`,
  `spdf_fill_snap_internal.h`. The render token's body moved to `spdf_core_document.h` so the snap pass can be
  cancelled with it.

### 1. Form detection and fields: `core/spdf_form.{h,c}` (~400 lines)

```c
typedef enum { SPDF_FORM_NONE, SPDF_FORM_FILLABLE, SPDF_FORM_SIGNED_ONLY, SPDF_FORM_XFA_ONLY } spdf_form_kind;
typedef struct { spdf_form_kind kind; int fillable_count, required_count, signed_count, unsigned_signature_count;
                 int has_xfa, incremental_ok, docmdp; } spdf_form_summary;
int  spdf_form_summary_read(spdf_document*, spdf_form_summary*, char* err, size_t);
     /* Root/AcroForm/Fields + /Kids, cap 4096 nodes, no page loads; incremental_ok = pdf_can_be_saved_incrementally;
        docmdp from /Perms */

typedef enum { SPDF_FIELD_TEXT, SPDF_FIELD_CHECKBOX, SPDF_FIELD_RADIO, SPDF_FIELD_COMBO, SPDF_FIELD_LIST,
               SPDF_FIELD_SIGNATURE } spdf_field_type;
enum { SPDF_FIELD_READ_ONLY=1, SPDF_FIELD_REQUIRED=2, SPDF_FIELD_MULTILINE=4, SPDF_FIELD_COMB=8, SPDF_FIELD_ON=16,
       SPDF_FIELD_SIGNED=32, SPDF_FIELD_EDITABLE_COMBO=64 };
typedef struct { int page_index, object_number, group_id, tab_index; spdf_rect rect; spdf_field_type type;
                 unsigned flags; int max_len; float font_size; char *name, *label, *value;
                 int option_count; char** options; } spdf_form_widget;
typedef struct { spdf_form_widget* items; int count; } spdf_form_widgets;
int  spdf_form_load_page_widgets(spdf_document*, int page, spdf_form_widgets*, char*, size_t);
void spdf_free_form_widgets(spdf_form_widgets*);
int  spdf_form_set_text  (spdf_document*, int page, int objnum, const char* utf8, int* pages_changed, int max, char*, size_t);
int  spdf_form_set_on    (spdf_document*, int page, int objnum, int on, int* pages_changed, int max, char*, size_t);
int  spdf_form_set_choice(spdf_document*, int page, int objnum, const char* utf8, int* pages_changed, int max, char*, size_t);
```

- Widgets via `pdf_first_widget`/`pdf_next_widget`, rects via `pdf_bound_widget` (page space, rotation included),
  label from `/TU`, DA size parsed from `/DA`, options from `pdf_choice_widget_options`.
- Setters: find the widget by `pdf_to_num`, refuse read-only, strip `/AcroForm/XFA` once, set the value
  (`pdf_set_text_field_value`, `pdf_toggle_widget`, `pdf_set_choice_field_value`), set language zh-Hans when the
  text has Han (`spdf_text_contains_han`) so MuPDF adds a CJK font, `pdf_update_page` and
  `spdf_drop_page_list_cache` for every page holding a widget of that field; `pages_changed` reports them (radio
  groups and same-name fields span pages).
- `NeedAppearances` left as found; no `pdf_enable_js`.

### 2. Placed items: `core/spdf_fill_items.{h,c}` (~450 lines)

```c
typedef enum { SPDF_FILL_TEXT, SPDF_FILL_CHECK, SPDF_FILL_CROSS, SPDF_FILL_SIGNATURE, SPDF_FILL_INITIALS } spdf_fill_kind;
int spdf_fill_add_text(spdf_document*, int page, spdf_rect, float size, const char* utf8, const char* nm, char*, size_t);
int spdf_fill_add_mark(spdf_document*, int page, spdf_rect box, int cross, const char* nm, char*, size_t);
int spdf_fill_add_signature_paths(spdf_document*, int page, spdf_rect, const char* const* paths, int path_count,
                                  const float rgb[3], const char* nm, char*, size_t);  /* M L C Q Z, unit-height box */
int spdf_fill_add_signature_png(spdf_document*, int page, spdf_rect, const unsigned char* png, size_t len,
                                const char* nm, char*, size_t);
int spdf_fill_update(spdf_document*, int page, const char* nm, const spdf_rect* rect_or_null,
                     float size, const char* utf8_or_null, char*, size_t);
int spdf_fill_set_mark_kind(spdf_document*, int page, const char* nm, int cross, char*, size_t);
int spdf_fill_delete(spdf_document*, int page, const char* nm_or_group, char*, size_t);
int spdf_fill_load_items(spdf_document*, int page, spdf_fill_items* out, char*, size_t); /* /NM starts "spdf-fill-" */
int spdf_annot_is_fill_item(fz_context*, pdf_obj* annot);                               /* used by comment filter */
int spdf_save_final_copy(const char* source, const char* password, const char* out_path, char*, size_t);
```

- Text: `pdf_set_annot_intent(FREETEXT_TYPEWRITER)`, border 0, no fill, `/Contents`, `/Lang` for Han, `/Rotate`
  = page rotation, `/T` = comment author, Print flag. Comb text: one FreeText per cell, shared group prefix.
- Check: polyline (0.15w,0.55h)→(0.40w,0.80h)→(0.85w,0.20h) of the box; cross: two diagonals inset 20%; width
  max(1 pt, 0.1·box), round caps, black.
- Signature: Stamp, rect keeps the aspect; picture variant reuses one image object per document
  (`pdf_set_annot_stamp_image_obj`). **Moving or resizing a Stamp writes `/Rect` only and must not regenerate the
  appearance** (the form XObject maps to the new rect via BBox/Matrix); the core agent verifies this in MuPDF 1.27.2,
  since a regenerated stamp loses the signature. Ink marks move by transforming `/InkList`.
- `spdf_save_final_copy`: own context, open, detach non-fill annotations, `pdf_bake_document(ctx, pdf, 1, 1)`,
  reattach, full save with garbage 3 and compression.
- Comment filter: `annot_type_should_surface` returns 0 for `spdf_annot_is_fill_item` or `FreeTextTypeWriter`
  (~+4 lines in `spdf_comment_review.h`).

### 3. Snap geometry: `core/spdf_fill_snap.{h,c}` (~450 lines)

```c
int  spdf_snap_geometry_load(spdf_document*, int page, int max_segments, spdf_render_token* cancel,
                             spdf_snap_geometry* out, char*, size_t);
void spdf_snap_geometry_free(spdf_snap_geometry*);
int  spdf_snap_resolve(const spdf_snap_geometry*, float x, float y, float radius,
                       spdf_snap_purpose /* TEXT | MARK | SIGNATURE */, spdf_snap_result* out); /* pure */
int  spdf_snap_targets_in_order(const spdf_snap_geometry*, spdf_rect* out, int max); /* for Tab on flat pages */
```

Extraction: one pass of a `fz_new_derived_device` (as `spdf_page_images.c`) over `fz_run_page_contents`, so
existing annotations and widgets are excluded, under a cancel cookie.
- `stroke_path` / `fill_path` → segments via `fz_walk_path` under the ctm. Horizontal |dy| ≤ 0.5, vertical
  |dx| ≤ 0.5, stroke ≤ 3 pt; curves ignored; a filled rect ≤ 2.5 pt thick is a line; larger fills (shading) ignored;
  closed axis-aligned four-point paths and `re` become boxes.
- `fill_text` → text runs (for label clearance, free height above a line, label ranking), runs of ≥ 3 `_` and
  ≥ 5 `.`/`…` as lines, ☐ □ ▢ ❏ and `[ ]` as boxes.
- Post-process: merge collinear segments with gaps ≤ 3 pt (dashed and dotted rules); drop lines with page text on
  > 50% of their length (link underlines, strike-through); drop page-sized frames and anything overlapping a widget;
  four or more equal boxes in a row (gap ≤ 2 pt) or ticks on a line form a **comb**.
- Table cells are resolved at click time: nearest horizontals above/below covering x and verticals left/right
  covering y give a cell when 8–80 pt high and empty of text.
- Budget: past 50k segments the pass stops with `truncated`; that page snaps to text-based targets only. Image-only
  pages yield nothing (raster fallback for scans is a later phase).

Placement rules (`spdf_snap_resolve`, search radius = 14 screen px converted to page points, ≥ 6 pt; priority: real
field, checkbox, box/cell, underline):

| Target | Text | Mark | Signature |
|---|---|---|---|
| Checkbox 5–24 pt, aspect 0.75–1.33 (within 4 pt) | Places the current mark instead | Centred, 80% of the box | Fit inside |
| Box or cell | Inset 3 pt (or after the label in the box), vertically centred, size clamp(0.65·h, 8, 12) | Centred at text size | Fit inside, aspect kept |
| Comb | One character per cell | n/a | n/a |
| Underline (click 18 pt above to 4 pt below, x ±10 pt) | Baseline 2 pt above; starts at line start + 2 pt if the click is within 40 pt of it, else at the click; size clamp(0.75·free gap, 8, 12), default 11; extends to the line end | Centred on the click at text size | Bottom 15% below the line, height clamp(2.2·line text size, 18, 48), no wider than the line |
| Nothing | Baseline at the click, 11 pt | At the click, 10 pt | 150 pt wide at the click |

## UI (Mac AppKit)

### UI as built (2026-11-22)

Where the Mac front end differs from the sketches below:
- **Toolbar:** the reader's toolbar is rebuilt by `SPDFMacWorkspaceChrome.mm`, so the Fill & Sign button is one more icon
  in its tools row (between Translate and Print, `signature` symbol), drawn "on" while the mode shows. The old
  overflow menu is no longer shown, so it gets no entry. Edit ▸ Fill & Sign (⌥⌘F) and File ▸ Save Final Copy… target
  a small object in `SPDFMacFillIntegration.mm` that validates them itself.
- **Overlay:** a subview of the reader's scroll view above its clip view (the size of the viewport, not of the
  document), so it never needs a huge layer; it maps page rects through the current `SPDFDocumentView` on every draw
  and forwards scroll, magnify and swipe gestures to it. It claims clicks only on pages while the mode shows.
- **Reads on the main-thread document:** a page's fields and our items are read from `_doc` (cheap, no render) and
  cached per page until a change on that page, so what is drawn always matches what was just written. Only snap
  geometry is read on a worker document (serial utility queue, cancellable, visible pages ±1).
- **Saving:** every commit saves at once (incremental when the file allows, as comments do) and redraws the changed
  pages synchronously from `_doc` in the same turn; there is no debounce and no unsaved state. What is being typed is
  written before the document is left (`rememberActiveTabState` hook). Collection gets `collectionDidSavePath:` 5 s
  after the last change of a burst, and the "before edit" protection runs once per burst.
- **Palette room:** while the palette shows, the document view keeps room above the first page (`topReserve`, the
  palette's height plus 18 pt, grown but not shrunk while it shows), so the top of a page is never stuck under it;
  page steps and reading positions count the viewport from below it, and Tab scrolls a target clear of it. When the
  document is the app's own copy of a file that couldn't be changed, the palette's second line says so and points to
  File ▸ Save As….
- **Snapping additions:** a small square drawn as four separate rules counts as a box (`find_ruled_squares`), and
  Tab lists the empty cells of ruled tables. MuPDF's "auto" size for one-line fields (text and combo) is capped at
  0.65 × the field height and 12 pt, as the editor shows it (`mupdf/source/pdf/pdf-appearance.c`, marked
  "ShenzhenPDF:").
- **Permissions:** Fill & Sign checks `can_fill_fields` / `can_add_items` from the summary itself, then runs the same
  writable-copy / Collection steps as `ensureActivePDFCanBeModifiedForOperation:` without its 'e'/'n' check, so a
  fill-only PDF can be filled.
- **Storage:** signatures, My Details, saved texts and "hint seen" live in `<state>/FillSign/` (index.json, `<id>.json`,
  `<id>.png`, details.json), not in the settings file.
- **Metadata loader:** the outline and comment loaders moved to `SPDFMacDocumentMetadataLoading.mm` and read both from one
  open; the form summary is read on the main-thread `_doc` at the same metadata stage (no extra open, no page load).
- **Not built yet:** dragging the palette, the right-edge width handle and corner font scaling of placed text
  (⌘+ / ⌘− while typing changes the size), the "Use the whole trackpad" drawing mode, date-style choice in My Details,
  the red outline on a failed save (an alert says it instead), and turning the mode back on by clicking a field after
  Done.

Files: `SPDFMacFillIntegration.{h,mm}` (reader category, host, menus, Save Final Copy), `SPDFMacFillController.{h,mm}`
(+ `+Edits.mm` changes and undo, `+Interaction.mm` clicks, editor, Tab, signatures, suggestions,
`SPDFMacFillControllerPrivate.h`), `SPDFMacFillOverlayView.{h,mm}` (+ `+Interaction.mm`, `SPDFMacFillOverlayViewPrivate.h`),
`SPDFMacFillEditor.{h,mm}`, `SPDFMacFillPalette.{h,mm}`, `SPDFMacFillModel.{h,mm}`, `SPDFMacSignatureStore.{h,mm}`,
`SPDFMacSignatureSheet.{h,mm}`, `SPDFMacSignatureOutlines.{h,mm}`, `SPDFMacDocumentMetadataLoading.mm`.

Size caps: `ShenzhenPDFMac.mm` (13861), `SPDFMacDocumentView.mm` (940), `SPDFMacDelegatePrivate.h` (637) and
`shenzhen_pdf_core.c` (2730) are at their caps. `SPDFMacDocumentView.mm` and `SPDFMacDelegatePrivate.h` do not
change: per-tab and per-window state lives in associated objects set from category files. Every line added to
`ShenzhenPDFMac.mm` is paid for by the metadata loader extraction (§ 3). New `.mm` files are picked up by the
`mac/*.mm` wildcard; each ≤ 500 lines.

### New files

| File | Role |
|---|---|
| `SPDFMacDocumentMetadataLoading.mm` | Merged outline + comments + form summary loader (§ 3), one open on `_preloadQueue`; hands the summary to `adoptFormSummary:forTab:` |
| `SPDFMacFillIntegration.mm` | `ShenzhenMacDelegate (SPDFMacFill)` category: `toggleFillAndSign:` + `validateMenuItem` cases; `spdf_fill_toolbar_button(self)` and `spdf_fill_install_menu_items(editMenu, fileMenu, self)` helpers (one call line each in ShenzhenPDFMac.mm); `addFillSignOverflowItemsToMenu:hiddenViews:` (pattern of `addReadingThemeOverflowItemsToMenu`); `adoptFormSummary:forTab:`; tab activate/deactivate; permission check (`'f'` fields, `'n'` placed items) before the existing read-only / writable-copy guard; signed-PDF and DocMDP checks; flush hooks |
| `SPDFMacFillController.h/.mm` | One per window, created on first use. Session per tab (associated object on `SPDFDocumentTab`: mode on/dismissed, tool, mark choice, selection, field and item caches keyed by size+mtime+page, pending values, undo manager). Fill queue (serial, utility QoS) with its own `spdf_document`, reopened on size/mtime change. Commit cycle, debounced save, Collection coalescing, undo, Tab order, writable-copy re-apply |
| `SPDFMacFillOverlayView.h/.mm` | Transparent flipped subview of the current `SPDFDocumentView`, same coordinates (`rectForPageAtIndex:`, `spdf_mac_page_rect_to_view_rect`). Draws tints, hover glow and ghost, selection handles, pending values. `hitTest:` claims only fields, our items, or any page point while a placing tool is active; everything else falls through to selection, links, comments and pan. Hidden during live zoom (commits first) and Presentation mode |
| `SPDFMacFillEditor.h/.mm` | Borderless NSTextView at field font × zoom, opaque field-colour background, comb kerning, theme ink colour under dark reading themes; suggestion chips; choice NSMenu |
| `SPDFMacFillPalette.h/.mm` | NSVisualEffectView pill, subview of `_documentContainer`, top centre, clear of minimap and side panel, draggable (position kept in settings under `fillSign`) |
| `SPDFMacSignatureStore.h/.mm` | `<SPDFMacStateDirectoryPath()>/Signatures/`: `index.json` `[{id, kind: signature\|initials, source: drawn\|typed\|picture, ink, aspect, created, lastUsed}]`, `<id>.json` outline paths (M L C Q Z, unit-height box, y down), `<id>.png` for pictures. 0700/0600, temp-then-rename, stat-checked on every use (each window is its own process). My Details and saved texts in the settings store under `fillSign` |
| `SPDFMacSignatureSheet.h/.mm` | Draw (pressure-to-width from `NSEvent.pressure`, Catmull-Rom smoothing, strokes turned into filled outlines), Type (script fonts, `CTFontCreatePathForGlyph` to outlines, so nothing is embedded), Picture (luminance threshold to alpha, auto-crop). Optional "Use the whole trackpad" mode with `NSTouch`, last |

### Edits to existing files

| File | Change |
|---|---|
| `ShenzhenPDFMac.mm` | −~95 (loaders moved out), +1 button helper, +1 `addArrangedSubview` after `_translateButton`, +1 in `updateControls`, +1 menu helper, +1 overflow hook; cap lowered in `apps/pdf/tools/file-size-limits.tsv` |
| `SPDFMacLaunchWorkIntegration.mm` | Metadata stage calls `loadDocumentMetadataAsync` |
| `SPDFMacInactivePreload.mm` | Fill the form summary from the document it already holds |
| `SPDFMacTabViewState.mm` | Detach / reattach the overlay in `replaceDocumentViewForTabSwitch` |
| `SPDFMacViewportRenderPriority.mm` | New `-rerenderPageAfterEdit:completion:`: keeps the current image, forces a high-priority render of that page from the saved file; completion drops the overlay's pending drawing in the same main-thread turn |
| `SPDFMacCloseDocument.mm`, `SPDFMacQuitFinishing.mm`, print / export / share / Copy Page entries, before the writable-copy move, reload from disk change | `flushFillEdits` (commit the editor, run the pending save), one line each |
| `SPDFMacWritableCopy.mm` | Permission helper taking the needed flag, so fields need `'f'`, not `'e'` |

### Commit cycle (no wrong frame)

1. First commit of a session: permission and signed checks, then `ensureActivePDFCanBeModifiedForOperation:@"filling
   in this form"`. If that moved the tab to a writable copy, re-apply the held value to the new `_doc`.
2. Engine call on `_doc`; record the inverse on the undo manager.
3. The overlay keeps drawing the committed value (opaque, so the old value never shows through).
4. Save 300 ms after the last commit (`spdf_save_document`, incremental when possible), then
   `refreshActiveTabCachedFileAttributesAfterSelfSave` and `rerenderPageAfterEdit:` for each changed page.
5. When the new page image arrives, the pending drawing goes in the same pass. No frame shows the field empty,
   doubled or old. If MuPDF's text sits a few points off the AppKit text, render that region from `_doc` as a patch
   (measure the main-thread cost first).
6. A save over 50 ms (a non-incremental first rewrite) switches that tab to saving on flush points only.
7. Undo manager answers only when the overlay or editor is first responder (standard Undo/Redo items with nil
   target, added to the Edit menu by the category); the Markdown and comment editors keep their own. Stack cleared
   on tab close or a change from outside.

## Orchestration (agents; testing only at the end)

Every brief carries: no pkill/killall/sudo (stop own PIDs), no `rm -rf` with variables, globs or `$(...)`, no
filesystem-wide searches, never touch Raph's running ShenzhenPDF, settings, Collection, keychain or Friends; no tests
or suite changes in the repo; new files ≤ 500 lines; no growth in capped files; stay out of the image-open, camera
RAW, OCR and Collection code; no push to main, no release; user-visible text exactly as § 2.

| Wave | Agent | Work | Depends on |
|---|---|---|---|
| 0 | Lead | Commit the three core headers and `SPDFMacFillController.h` interfaces exactly as above | — |
| 1 | CORE-A | `spdf_form.c`, `spdf_fill_items.c`, comment filter, comment-loader page skip, Makefile | 0 |
| 1 | CORE-B | `spdf_fill_snap.c` | 0 |
| 1 | UI-A | Metadata loader extraction and merge, summary in inactive preload, toolbar button, menus, overflow, cap lowering (sole owner of `ShenzhenPDFMac.mm`) | 0 |
| 1 | UI-S | Signature store and sheet | 0 |
| 2 | UI-B | Controller, overlay, editor, palette, commit cycle, re-render seam, flush hooks, real-form flow, then flat-page snapping, signatures placement, suggestions | 1 |
| 3 | Integrator | Build, static checks (§ Final check 1), `make file-size-ratchet-tests` | 2 |
| 4 | One verifier (Opus) | Final check below | 3 |

## Final check (once, at the end, nothing added to the repo)

One-off scripts in the scratchpad only.

1. **Static:** `otool -l` shows no new initialiser offsets, `__objc_nlclslist` or `__objc_nlcatlist` entries;
   `applicationDidFinishLaunching`, `loadPersistentState`, `SPDFMacStatePrefetch` and `main()` reference no Fill or
   Signature symbol; `apps/pdf/tools/check-file-sizes.sh`.
2. **Launch gate:** `make -C apps/pdf/portable mac-launch-performance-tests LAUNCH_PERF_BASELINE_RELEASE=latest`.
   Its scenarios have no form, so also: an isolated copy restoring a generated form PDF with `SPDF_LAUNCH_PROFILE=1`,
   compared with main (≤ 0.2 ms), and a mid-session open of a large manual showing one `spdf_open` fewer.
3. **Real UI:** a test copy with `HOME=/tmp/szfs`, `SPDF_STATE_DIR=/tmp/szfs/state`, Friends off, windows in the
   background, error dialogs stubbed, stopped by PID. Real clicks, typing, Tab, Return, Escape, ⌘Z on throwaway
   PDFs generated in the scratchpad: an AcroForm (text, comb, multiline, checkbox, radio across two pages, combo,
   list, unsigned signature field); a flat form with underlines, boxes, a table, `____` runs, ☐ glyphs and character
   boxes; a scan; a rotated page; an already-signed PDF; a fill-only-permission PDF; a read-only location; Chinese
   text; Collection on and off; reopen; quit during an edit. Screenshots from the first frame on, looked at as a
   first-time user.
4. **Files:** `mutool show` (`/V`, `/AS`, `/NM`, `/IT`, no `/XFA`), Comments panel empty, render through PDFKit (a
   one-off Swift script) and `qlmanage -t`, Save Final Copy checked the same way.

## Risks and open questions for Raph

- **Filling writes into the file you opened**, like comments. For a form someone sent, the original is protected
  only by Collection versions or the writable copy. Alternative: always fill into a copy for downloaded files.
- **Signatures are stored unencrypted** (0600) in the app's state folder. The keychain would match Preview but
  risks blocking prompts.
- **"Optional default text"** is read as suggestions that never fill on their own. Confirm.
- **Form scripts never run**: calculated totals and format checks stay stale in some tax and government forms.
- **Real checkboxes keep the form's own glyph**; ✗ applies only to marks we place.
- **Signature fields get a picture, not a certificate signature**; Acrobat may still list them as unsigned.
- **Stamp appearance on move** must not be regenerated by MuPDF (§ CORE 2); verify early.
- **CJK fonts** are not embedded (MuPDF references Song/Ming); Preview and Acrobat substitute, some printers may not.
  Later: embed subsets with the existing `spdf_cff_subset` code.
- **Snapping is heuristic**: tables, decorative rules and underlined headings can mislead; scans only get glyph
  targets and free placement. Tune on real forms during the final check.
- **Merge hot spots** with concurrent branches: `SPDFMacTabViewState.mm`, `SPDFMacLaunchWorkIntegration.mm`,
  `SPDFMacInactivePreload.mm`, the Makefile `CORE_OBJS` line.
- **GTK4 and Windows** get the core only; fills show there but cannot be edited. An `szpdf fields` / `szpdf fill`
  command is an easy follow-up.
- **agents.md vs Raph's rule**: agents.md asks for a laziness test; Raph's rule wins, laziness is shown by the
  one-off static and profile checks above. Say so in the commit.

## Pen and arrow

Status: designed 2026-11-22 on `feat/pdf-fill-sign` (off origin/main 450d1d89, Fill & Sign as built). No code yet.

Raph's request: "Also in fill and sign add an annotation tool with a pen and a few colors (red by default). You should
be able to CMD z, erase by line (default), erase by eraser, select tool width, select and move lines and group of lines
via box sélection, delete all pen annotations, remove all fill and sign annotations, arrow tool that is treated like
pens lines (you can move them afterwards etc...)" and "Of course CMD shift z, and CMD y redo". Standing: intuitive,
nothing new before the first frame, test only at the end.

### Decisions

| Topic | Decision | Why |
|---|---|---|
| Tools | Four icon buttons in the palette, one group after ✓ ✗: **Pen**, **Arrow**, **Eraser**, **Select** | Each is one click away, like Text and the marks; no hidden modes |
| Options | A second palette row, shown only while one of the four is chosen: colours, widths, eraser kind and size, and a bin | The first row stays as short as today plus four icons; nothing appears for people who only fill forms |
| Colours | Red (default), Blue, Green, Black; one choice shared by Pen and Arrow | "A few colours, red by default"; one choice is one thing to remember |
| Width | Thin 1 pt, Medium 2 pt (default), Thick 4 pt, in page points (lines scale with the page like the page's own lines) | Three visible samples beat a slider; page points keep a line the same on paper at any zoom |
| Remembered | Colour, width, eraser kind and size in `<state>/FillSign/drawing.json`, read the first time a drawing tool is chosen, written on change | Survives relaunch; nothing read at launch; same folder and 0600 rules as the rest of Fill & Sign |
| Pen in the PDF | One `Ink` annotation per line (pen down to pen up): `/InkList` with one dense polyline, `/C` RGB, `/BS /W` width, round caps and joins (MuPDF writes `1 J 1 j`), Print flag | Ink is what Preview, Acrobat and pdf.js draw identically, and what the check and cross marks already use |
| Arrow in the PDF | Also `Ink`, not `Line`: `/InkList [[tail tip] [barbL tip barbR]]` (shaft plus an open head), same colour, width, flags | Moves, erases, selects, recolours and undoes through exactly the same code as pen lines; every reader draws Ink from the same points, while a `Line` with `/LE` is redrawn by each reader with its own head size |
| Identity | `/NM (spdf-fill-pen-<uuid>)` and `/NM (spdf-fill-arrow-<uuid>)`; each piece the true eraser leaves gets a new uuid | Same `spdf-fill-` prefix as every fill item: found again after saves and in other editors, no private keys |
| Comments | Nothing to change: `spdf_annot_obj_is_fill_item` already hides every `spdf-fill-` annotation from the Comments panel, AI tools and szpdf | Pen lines are Fill & Sign marks, not comments; verify in the final check |
| Save Final Copy | Pen lines and arrows are baked like every other fill item (`hold_comments` keeps `spdf-fill-` items on the page) | No change needed; verify |
| Smoothing | Centripetal Catmull-Rom through the de-duplicated pointer samples, flattened as the line is drawn; stored as that flattened polyline, then thinned by 0.05 pt Douglas-Peucker | What is drawn live is what is stored, so the line never shifts when the page redraws; readers draw a polyline, so the curve must be in the points |
| Undo | The tab's existing `NSUndoManager` (one per tab session) gets every drawing change too: one stack for all of Fill & Sign. ⌘Z undo; ⇧⌘Z and ⌘Y redo | Raph's keys; ⌘Y is free (no menu item or key handler uses it, checked in `mac/`) |
| Saving | Same commit cycle as every fill: write to `_doc`, `fillSaveAndRedrawPages:` (incremental save, the changed page redrawn in the same turn). Pen lines and arrows drawn in quick succession are written together once the pointer has rested 0.35 s | As built there is no debounced save (every commit saves at once, only Collection waits 5 s); the short batch keeps handwriting from paying one page render per line |
| No wrong frame | Every gesture is drawn live by the overlay; the overlay keeps drawing a line until a page image that contains it is on screen; lines being erased or moved are covered with a wash of the paper colour clipped to the line's own outline until the page image without them is on screen | The page image and the overlay are never out of step in a way a person can see |
| Launch | Nothing new before the first frame: new code lives in Fill & Sign files created on first use; `drawing.json` is read on first use of a drawing tool | Raph's standing rule |

### Palette

```
[3 of 12 filled]  Text  ✓  ✗  |  ✎  ↗  ⌫  ⬚  |  Signature ˅  |  Done
                  ● ● ● ●   ─ ━ ▬   [bin]                    <- options row, only while Pen or Arrow is chosen
```

- First row: the four icons sit between the marks and Signature (symbols `pencil.tip`, `arrow.up.right`, `eraser`,
  `rectangle.dashed`), 30 pt wide each, so the palette grows by about 130 pt to ~545 pt. They are disabled where
  Text and the marks are (`can_add_items` = 0).
- When the page area is narrower than the palette, Text and Signature show icons only (`textformat`, `signature`)
  before anything else is squeezed; the progress text hides last.
- Options row (in place of the first-form hint, which hides while a drawing tool is chosen; the edited-copy note
  stays under it):
  - **Pen / Arrow:** four colour dots (16 pt, the chosen one ringed), three width samples drawn in the chosen colour,
    then the bin.
  - **Eraser:** a two-part control [Whole lines | Parts] (Whole lines chosen by default), three size circles shown only
    for Parts (8, 16, 32 screen points across), then the bin.
  - **Select:** colour dots and width samples, enabled when the selection holds lines or arrows: a click restyles
    them (one undo step) and becomes the remembered choice; then the bin.
- The palette's height grows by the options row; `topReserve` already grows with it while it shows.
- Palette buttons never take keyboard focus (`refusesFirstResponder`); after any palette click the overlay takes the
  keys back (`takeKeysFromPages`), so ⌘Z, Delete and the tool keys keep working.
- Opening the palette selects Text, as today. The chosen tool is kept per tab while the palette shows.

### Tools

**Pen.** Press, drag, release draws one line. A click without moving leaves a dot. Shift held: a straight line from
where the press began. The line starts on the page under the press; points beyond the page edge are clamped to it.
Fields of a real form do not react while Pen is chosen (the person chose to draw). Cursor: a dot of the line's width and
colour (at least 3 px), in a white ring.

**Arrow.** Press at the tail, release at the tip; Shift snaps the angle to 15° steps. Shorter than 4 screen points:
nothing is drawn. Head: an open chevron, each arm `clamp(4 + 3 x width, 6, 24)` pt at ±28° from the shaft, computed in
the core from tail, tip and width, so it is the same after a move or restyle. Cursor: crosshair.

**Eraser, whole lines (default).** Every pen line or arrow the eraser touches goes. "Touches" = the pointer's path
passes within `6 px / zoom + width/2` of the line. Touched lines fade at once (paper-colour wash at 85% clipped to
the line's outline) and are written as removed on release, as one change.

**Eraser, parts.** Rubs out only where it passes, splitting lines (§ True eraser). The cursor is a circle the size of the
eraser. Arrows: the part holding the tip stays an arrow; the cut-off tail part becomes a plain pen line; rubbing the
head itself removes the head and leaves a pen line.

**Select.**
- Click a line, arrow, typed text, mark or signature: selects it. Shift-click adds or removes. Double-click on typed text
  opens it for editing (a single click selects, unlike the Text tool).
- Drag on empty page: a box (1 pt accent outline, 8% fill). Everything the box touches is selected (forgiving for
  scribbles); with Option held, only what lies wholly inside. Shift adds to the selection. The box stays on the page
  where it started; a selection is on one page.
- Drag anything selected: moves the whole selection; drag something unselected: selects it alone and moves it.
  Nothing snaps while the Select tool moves things (the group keeps its layout). Comb text cells cannot be moved, as
  today, and are left out of box selections.
- One arrow selected on its own shows two round handles, at tail and tip; dragging one moves that end (head redrawn).
- Arrow keys move the selection 1 pt, Shift-arrows 10 pt; a run of key presses is one change, written when the keys
  are released.
- Delete or Backspace removes the selection; right-click shows "Remove", and for lines and arrows the colours.
- ⌘A (Edit ▸ Select All, which reaches the overlay as first responder) selects everything ours on the page in view.
- Selection is drawn as a 2 px accent halo along each line or around each item, plus a dashed box around the group.
- Escape: first ends a gesture in progress (nothing written), then clears the selection, then goes back to Text.

**Other tools and drawings.** With Text, ✓ ✗ or Signature chosen, pen lines and arrows ignore the pointer (hit tests
skip them), so text can be typed inside a circled area and marks placed on top of a scribble. The Eraser touches
only pen lines and arrows. Hit testing of lines is by distance to the polyline (bounding box first), never by the
bounding box alone, so a large circle does not capture clicks inside it.

### Keyboard

| Key | When | Action |
|---|---|---|
| P, A, E, S, T | Fill & Sign shows, the overlay has the keys, no text box open, no field or target focused by Tab | Pen, Arrow, Eraser (pressed again: switches Whole lines / Parts), Select, Text |
| ⌘Z | Overlay has the keys | Undo the last Fill & Sign change of this tab |
| ⇧⌘Z, ⌘Y | Overlay has the keys | Redo |
| ⌘Z / ⇧⌘Z / ⌘Y | Text box open | Undo / redo typing (the text view's own undo; ⌘Y added in `fillTextViewKeyEquivalent:`) |
| Delete, Backspace | Selection | Remove it |
| Arrows, ⇧arrows | Selection | Move 1 pt / 10 pt |
| ⌘A | Select tool | Select everything ours on the page in view |
| Escape | Drawing tools | End gesture → clear selection → back to Text |
| Shift while drawing | Pen / Arrow | Straight line / 15° steps |
| Option while boxing | Select | Only what lies wholly inside |

Checked for collisions: P, A, E, S, T are not used by Fill & Sign (X and V act only on a mark under the pointer or
selected, Space toggles); `handlesTypedKey:` claims these five only under the conditions above, so type-to-search and
typing into a Tab-focused field are untouched. ⌘Y: no `keyEquivalent:@"y"` in `mac/`, no key handler for it.
⌘P, ⌘A, ⌘S stay with the menus. The Edit menu has no Undo/Redo items today; adding app-wide ones would change every
other text view, so the keys stay in the overlay and the text box.

### Smoothing, in numbers

1. Each drag event gives a point in page space (`locateViewPoint:`); points closer than 0.75 screen px to the last kept
   one are dropped (coalesced trackpad events are fine: the curve fills the gaps).
2. Centripetal Catmull-Rom (alpha 0.5) through the kept points; each segment is flattened when the point after it
   arrives, into pieces whose chord deviates < 0.1 screen px (at least one piece per 1.5 pt). Live drawing = finished
   segments + a straight piece to the pointer; on release the last segment is finished the same way.
3. Stored: that polyline, thinned by Douglas-Peucker at 0.05 pt (invisible), at most 4000 points per line (a longer
   line continues as a new line, same style, same undo step).
4. Arrows are two points; no smoothing.

The pure geometry (smoothing, thinning, distance, box touch, erase split, arrow head) is plain C in the core so GTK and
Windows can reuse it later.

### True eraser: how lines split

- The eraser's path is the polyline of pointer samples (page space), radius `R = size/2 / zoom`.
- For each pen line or arrow shaft whose bounding box meets the swath: walk its polyline (already dense, ≤ 1.5 pt
  steps); a point is erased when its distance to the swath is ≤ `R + width/2` (so the round end cap stops at the
  edge of the swath). Each in/out change is refined by three bisections on that segment.
- Kept runs become new lines (new `/NM`, same colour and width); runs shorter than the line width are dropped. The
  original is removed. Arrows: the run ending at the tip keeps the head (new `spdf-fill-arrow-` name) unless the head
  itself was rubbed; other runs become `spdf-fill-pen-` lines.
- Live: the swath is shown as a paper-colour wash clipped to the outlines of the lines it crosses (page text under the
  ink is not washed). On release: one change removes the originals and adds the pieces, one undo step.

### Remove all

- **Edit ▸ Remove All Pen Lines and Arrows**, and the bin in the options row: every `spdf-fill-pen-` and
  `spdf-fill-arrow-` annotation on every page.
- **Edit ▸ Remove Everything Added with Fill & Sign**: every annotation whose `/NM` starts with `spdf-fill-`: typed
  text, checks, crosses, signatures, initials, pen lines, arrows. The PDF's own form fields keep their values ("added"
  vs "filled", as the palette's "3 of 12 filled" already says; see Risks).
- Both sit under Edit ▸ Fill & Sign, target `SPDFFillMenuTarget` and are enabled when `fillSignAvailable` and the PDF
  allows added items. No confirmation: each is one undo step, and Collection keeps the version before the burst.
- Pages are found without loading them (`/Annots` read through `pdf_lookup_page_obj`, as the comment loader's skip
  does); the specs of what is removed are read first (for undo), then one batch delete per page, one save, and the
  visible changed pages redrawn in that turn (the others render when shown, as today).

### Undo, one stack per tab

The session's `NSUndoManager` (`SPDFFillSession.undoManager`, one per tab) records every change, as it already does for
fields and placed items. Inverses replay the same engine calls through the same commit cycle, so an undo is saved and
redrawn like any change and survives a move to a writable copy (specs and `/NM`, not object numbers or held objects).

| Change | One undo step | Inverse |
|---|---|---|
| Pen line, arrow | per line | remove by `/NM` |
| Eraser drag (either kind) | per drag | remove the pieces, re-add the originals from their specs (same `/NM`) |
| Move by drag, arrow-key run, arrow end drag | per gesture | move back by −dx, −dy (or the old end) |
| Restyle selection | per click | old colour and width per line |
| Remove selection / Remove All Pen Lines and Arrows / Remove Everything Added | per command | re-add from specs (signatures through `usedSignatures`, as `deleteItem:` does) |

- A line still waiting for its batch to be written is taken back by ⌘Z without being written (its undo handler sees it
  is still pending and drops it); redo puts it back in the batch.
- Any undo or redo first writes what is pending, then acts.
- Explicit `beginUndoGrouping`/`endUndoGrouping` around each multi-call change (eraser, move of a mixed selection,
  remove all); the tracking loops already run inside one event, so `groupsByEvent` alone would also group them, but
  arrow-key runs span several events and need the explicit group.
- The stack is cleared when the tab closes or its file changes from outside, as today.

### Commit cycle for drawings (no wrong frame)

1. During a gesture only the overlay changes: the live line, the washes, the moved copies. Nothing is written.
2. On release (or key-up for nudges) the change goes into `_doc` through the core calls below and its undo is
   registered. Pen lines and arrows wait in a pending batch until the pointer has rested 0.35 s; every other change
   (and any of the triggers in 4) writes the batch first.
3. Writing = `change:write:` as today → `fillSaveAndRedrawPages:` → incremental save, the changed visible pages
   rendered from `_doc` in the same turn. In that same turn the overlay drops its live lines and washes for those pages.
4. The pending batch is also written before anything else can read the file: a tool change, Done, any ⌘ key reaching
   the overlay (`performKeyEquivalent:` writes, then lets the menu act: ⌘P, ⌘W, ⌘S…), the pointer leaving the pages
   (toolbar, sidebar), the window resigning key, and the existing `fillSignFlushEdits` (tab switch, close, quit,
   sessions), which now calls `flushPendingChanges` (editor + batch).
5. A stroke drawn by the overlay over a page image that already contains it is invisible (opaque, same width and
   colour), so the overlay keeps drawing a written line until a page image made after the write is installed, closing
   the race with a viewport tile requested before the write. The render seam passes the save generation.
6. The overlay's colours go through the same mapping as the page pixels: under the dark reading theme lines are
   recoloured as the page image will be, and the wash uses the theme's paper colour.
7. Live zoom hides the overlay today: a gesture cannot be in progress then; a pending batch is written when live zoom
   starts.

### CORE additions (plain C)

`spdf_fill_items.h` (contract):

```c
#define SPDF_FILL_PEN_NM_PREFIX   "spdf-fill-pen-"
#define SPDF_FILL_ARROW_NM_PREFIX "spdf-fill-arrow-"
typedef struct spdf_fill_point { float x, y; } spdf_fill_point;
/* spdf_fill_kind gains SPDF_FILL_PEN = 5, SPDF_FILL_ARROW = 6. spdf_fill_item gains, for those two:
   float rgb[3]; float width; spdf_fill_point* points; int point_count;   (arrow: points = {tail, tip}; rect = bounds
   including width and head) */
```

New `core/spdf_fill_ink.h` + `spdf_fill_ink.c` (~350 lines), writes on the main-thread document like the rest:

```c
typedef struct spdf_fill_stroke { spdf_fill_kind kind; const char* nm; float rgb[3]; float width;
                                  const spdf_fill_point* points; int point_count; } spdf_fill_stroke;
int spdf_fill_add_strokes(spdf_document*, int page, const spdf_fill_stroke*, int count, char* err, size_t);
int spdf_fill_delete_items(spdf_document*, int page, const char* const* nms, int count, char* err, size_t);
int spdf_fill_move_items(spdf_document*, int page, const char* const* nms, int count, float dx, float dy,
                         char* err, size_t);  /* Ink: every /InkList point; text and stamps: /Rect only */
int spdf_fill_restyle_strokes(spdf_document*, int page, const char* const* nms, int count, const float rgb[3],
                              float width, char* err, size_t);
int spdf_fill_set_arrow_ends(spdf_document*, int page, const char* nm, spdf_fill_point tail, spdf_fill_point tip,
                             char* err, size_t);
/* Pages holding items whose /NM starts with prefix, from /Annots without loading pages. */
int spdf_fill_pages_with_items(spdf_document*, const char* prefix, int* pages, int max, char* err, size_t);
```

New `core/spdf_fill_ink_geometry.h` + `.c` (~280 lines, pure, no MuPDF): Catmull-Rom flattening step,
Douglas-Peucker, point-to-polyline distance, polyline-touches-rect, polyline-inside-rect, erase split (returns runs),
arrow head points.

Edits:
- `spdf_fill_items.c`: `read_item` checks the pen and arrow prefixes before treating an Ink as a mark (today every
  `spdf-fill-` Ink is read as a check or cross) and fills points, colour, width; `spdf_free_fill_items` frees points;
  `spdf_fill_load_items` keeps reading Ink. About +25 lines (418 → ~445).
- `spdf_fill_update` with a rect on a pen line or arrow refuses (moves go through `spdf_fill_move_items`), so the mark
  path never redraws a line as a check.
- Makefile: the two objects added to `CORE_FILL_OBJS`. `shenzhen_pdf_core.c` and `spdf_comment_review.h` unchanged.

### Mac files

| File | Change |
|---|---|
| `SPDFMacFillModel.{h,mm}` | `SPDFFillTool` gains Pen, Arrow, Eraser, Select; `SPDFFillItem` gains colour, width, points, `isDrawing`; session gains the selection (set of `/NM`s and its page), eraser kind; `SPDFFillStroke` value object (+~45) |
| new `SPDFMacFillDrawingStyle.{h,mm}` (~150) | The four colours (sRGB: red 0.89 0.16 0.13, blue 0.11 0.37 0.86, green 0.14 0.58 0.27, black 0 0 0), three widths, three eraser sizes; reads and writes `<state>/FillSign/drawing.json` (temp-then-rename, 0600) through the signature store's folder |
| new `SPDFMacFillDrawingOptions.{h,mm}` (~260) | The options row: colour dots, width samples, eraser kind and sizes, bin; accessibility labels |
| new `SPDFMacFillController+Drawing.mm` (~450) | Drawing edits with undo (add, remove, erase split, move, restyle, arrow ends, remove all, remove everything), the pending batch and its 0.35 s timer, `flushPendingChanges`, selection model |
| new `SPDFMacFillOverlayView+Drawing.mm` (~480) | Pen, Arrow, Eraser and Select gestures (tracking loops), live smoothing, washes, rubber band, selection halos and arrow handles, cursors, nudges with key-up commit, ⌘A |
| `SPDFMacFillOverlayView.mm` (441) | Hooks only: `drawRect:` calls the drawing layer, `mouseDown:` hands drawing tools to the category, `itemAt:` skips drawings unless Select or Eraser, `performKeyEquivalent:` writes the batch; ≤ ~460 |
| `SPDFMacFillOverlayView+Interaction.mm` (206) | ⌘Y redo, tool letters, Escape tiers, Delete and arrows on a multi-item selection, `handlesTypedKey:` for P A E S T (+~40) |
| `SPDFMacFillPalette.mm` (263) | Four tool buttons, the options row host, narrow-width icon-only mode, `refusesFirstResponder` (+~70) |
| `SPDFMacFillController.{h,mm}` | Declares the Drawing category; `flushEditor` → `flushPendingChanges`; `activeDocumentChanged` writes the batch before dropping caches; render-generation hand-off to the overlay (+~25) |
| `SPDFMacFillEditor.mm` | ⌘Y → redo typing (+3) |
| `SPDFMacFillIntegration.mm` (353) | Two Edit menu items under Fill & Sign and their validation; `fillSignFlushEdits` calls `flushPendingChanges`; save generation passed after each save (+~30) |

`SPDFMacFillController+Edits.mm` (419) is not grown: the drawing edits live in their own category. No file in
`apps/pdf/tools/file-size-limits.tsv` changes; `ShenzhenPDFMac.mm`, `SPDFMacDocumentView.mm`, `shenzhen_pdf_core.c`
are not touched. Every file stays ≤ 500 lines.

### UI text (all of it)

| Where | Text |
|---|---|
| Tool tooltips | "Pen (P)", "Arrow (A)", "Eraser (E)", "Select (S)" |
| Tool accessibility labels | "Pen", "Arrow", "Eraser", "Select" |
| Colours | "Red", "Blue", "Green", "Black" |
| Widths | "Thin", "Medium", "Thick" |
| Eraser kind | "Whole lines" (tooltip "Erases every line you touch"), "Parts" (tooltip "Erases only where you rub") |
| Eraser sizes | "Small", "Medium", "Large" |
| Bin tooltip / label | "Remove all pen lines and arrows in this document" |
| Edit menu | "Remove All Pen Lines and Arrows", "Remove Everything Added with Fill & Sign" |
| Right-click on a selection | "Remove", and for lines and arrows the four colours |

No hint line, no success messages. Errors reuse "Couldn't save what you filled in".

### Final check additions (once, at the end, nothing added to the repo)

Same rig as before: a test copy with its own bundle id, `HOME=/tmp/szfs`, `SPDF_STATE_DIR=/tmp/szfs/state`, Friends
off, windows behind the desktop, the injected event driver, stopped by PID; throwaway PDFs in the scratchpad.

1. **Real use:** draw with each colour and width (real drags), Shift lines, arrows with Shift angles, dots; whole-line
   and parts erasing across several lines and an arrow (head kept, head rubbed); box selection (touch and Option
   inside), Shift-click, drag move, arrow-key runs, an arrow's end handles, Delete, restyle; P A E S T and Escape;
   ⌘Z through all of it, then ⇧⌘Z and ⌘Y back; both remove-all commands and their undo; quit within 0.35 s of a line
   and reopen (the line is there); a scan, a rotated page, the dark reading theme, a schematic page, a read-only
   location (writable copy, then undo still works).
2. **Frames:** capture the window during each gesture and through each release from the first frame on; pass only if
   no frame shows a line vanish, double, jump or change colour, nor an erased line come back.
3. **Files:** `mutool show` (`/Subtype /Ink`, `/NM` prefixes, `/InkList`, `/C`, `/BS`), the Comments panel stays
   empty, rendered through PDFKit (one-off Swift script) and `qlmanage -t`, and Save Final Copy.
4. **Launch:** the static checks of § Final check 1 again (no new initialisers; launch paths reference no new symbol).

### Orchestration

| Wave | Agent | Work |
|---|---|---|
| 0 | Lead | Commit the header contracts above (`spdf_fill_items.h` additions, `spdf_fill_ink.h`, `spdf_fill_ink_geometry.h`, the Drawing category declarations) |
| 1 | CORE | `spdf_fill_ink.c`, `spdf_fill_ink_geometry.c`, `read_item`, Makefile |
| 1 | UI-P | Palette, options row, drawing style store, tool keys |
| 2 | UI-D | Controller+Drawing and Overlay+Drawing: gestures, batch, undo, removal commands, menus, flush hooks |
| 3 | One verifier (Opus) | Build, `apps/pdf/tools/check-file-sizes.sh`, then the final check above |

Every brief carries the usual rules (no pkill/killall/sudo, no `rm -rf` with variables, globs or `$(...)`, no
filesystem-wide searches, never touch Raph's running app, settings, Collection, keychain or Friends, no tests added to
the repo, files ≤ 500 lines, no push, no release) and the UI text above verbatim.

### Risks and open questions for Raph

- **"Remove all Fill & Sign"** removes everything Fill & Sign added on top of the pages but leaves the form's own
  fields as filled. Should it also empty the fields? (They may hold what the sender pre-filled.)
- **Arrows are Ink, not Line annotations.** They look the same everywhere, but Acrobat lists them as pencil marks,
  not arrows, and its arrow properties don't apply.
- **One annotation per line.** A page of handwriting is hundreds of annotations; other readers' comment lists (Acrobat,
  Preview's sidebar) show each one. Merging a burst into one Ink with several strokes would shorten those lists but
  make erasing and moving single lines harder; kept per line.
- **Constant width.** Ink has one width per annotation, so trackpad pressure is ignored.
- **Overlay over a page that contains the same line** darkens antialiased edges very slightly until the overlay lets
  go; judged invisible, checked in the frame capture.
- **0.35 s batch:** a crash in that window loses the last lines; every way of leaving the page writes them first.
