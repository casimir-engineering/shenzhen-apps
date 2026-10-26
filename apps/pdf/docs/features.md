# ShenzhenPDF — complete feature list

Everything the app does today, grouped by what you would be doing at the time.
The [readme](../readme.md) is the short version; this is the exhaustive one.

Platform tags: **mac** = macOS (AppKit), **linux** = GTK4 + libadwaita,
**win** = the native Win32 + Direct2D frontend in `portable/win/`. An untagged
entry works on all three. (See `portable/docs/windows-feature-matrix.md` for the
Windows frontend's feature-by-feature status.) No Windows binary is published
yet; the build is a single self-installing executable, `dist\ShenzhenPDF-win-x64.exe`.

- [Formats](#formats)
- [Opening documents](#opening)
- [Tabs and windows](#tabs)
- [Reading and navigation](#reading)
- [Search](#search)
- [Document map and scrollbar](#map)
- [Chapters, comments and the side panel](#sidepanel)
- [Markdown](#markdown)
- [Markdown syntax support](#markdown-syntax)
- [Diagrams](#diagrams)
- [Annotations](#annotations)
- [OCR](#ocr)
- [Translation](#translation)
- [Printing and export](#export)
- [Appearance and reading theme](#theme)
- [Speed](#speed)
- [Files, state and integration](#files)
- [Updates and verification](#updates)
- [Keyboard shortcuts](#shortcuts)

## <a id="formats"></a>Formats

| Format | Notes |
| --- | --- |
| PDF | The primary, most-polished path: text, links, outline, annotations, rotation, save, export |
| XPS, OpenXPS | `.xps`, `.oxps`, rendered through MuPDF |
| EPUB, MOBI, PalmDOC, FB2 | `.epub`, `.mobi`, `.prc`, `.pdb`, `.fb2`; reflowable e-books |
| Comic archives | `.cbz`, `.cbt`, image-containing `.zip` and `.tar`; original image colors |
| Text and source code **mac** | `.txt`, logs and source files for every language in the code-block highlighter; HTML/XHTML opens as highlighted code |
| Modern Office documents | `.docx`, `.xlsx`, `.pptx`, `.hwpx`; MuPDF's reflowed reading view, not Office editing or exact Office layout |
| Images | PNG, JPEG/JFIF, BMP, GIF, TIFF, JPEG 2000, JBIG2, Netpbm/PFM and PSD; original colors in dark mode |
| Vector images | `.svg`, `.svgz`; original colors in dark mode |
| Markdown | `.md`, `.markdown`, `.mdown` through the app's own paginated renderer **mac** |

On macOS, the Open dialog, Finder **Open With**, and file drops onto the reader,
empty workspace or tab bar use the same supported-format list. Multiple dropped
files open as tabs. Filenames remain complete in the sidebar; tab titles omit the
extension. Direct image files also receive bounded Collection thumbnails through
macOS ImageIO where that decoder is available. GIFs use MuPDF's static reading
representation rather than animated playback.

**Paste images (macOS)** — Cmd+V in the reader opens copied image files or PNG,
TIFF and JPEG clipboard pictures. Pasting inside a text field keeps its normal
behavior. Clipboard pictures have a red unsaved dot and survive session restoration
in app-owned storage. **Save As** offers the original image format or PDF and opens
the saved file. Image copies preserve the original bytes, including transparency,
metadata and animation; PDF includes every page exposed by the reader. **Copy as
PDF** copies the selected image page. Closing an unsaved image offers Save,
Don’t Save or Cancel, including group close and quitting; pending saves finish
before closing.

The bundled build does not include JPEG XR or RAR decoders, nor native HEIC/WebP,
legacy Office `.doc`/`.xls`/`.ppt`, or DRM removal. These are not advertised as
openable. ZIP/TAR support means comic/image archives, not arbitrary archive browsing.
Collection still stores the source bytes of additional formats; full-text indexing,
comparison and previews outside PDF, Markdown, text/source and common images remain limited.
Source files are literal: HTML tags, scripts, Markdown-looking syntax and resource
references stay visible as code. Source viewing never loads their referenced assets.
SVG resources are still read from the original document's folder; Collection does
not yet bundle SVG dependencies as it does for Markdown.

Text/source files share paginated search, copy, export, reading themes and Collection
history with Markdown. **A− / A+**, immediately to the right of zoom, changes text
size and reflows the pages; the existing text-size preference persists. Files use
UTF-8 or BOM-marked UTF-16/UTF-32. Binary data is rejected. Syntax highlighting uses
the same offline language catalog as fenced code blocks, including C/C++, Python,
JavaScript/TypeScript, Swift, Java, Rust, Go, HTML/XML, JSON and YAML. SVG keeps its
image viewer, and Markdown keeps its formatted document view.

Password-protected PDFs prompt for the password. On macOS, successfully entered
passwords are remembered in Keychain for Collection and matching originals; saved
PDFs remain encrypted. In-memory document credentials are released at quit.

Read-only sources (a file on a locked volume, a document opened from a
read-only location) are opened through a persisted shadow copy, so a relaunch
does not re-trigger the macOS access prompt.

## <a id="opening"></a>Opening documents

- **Open…** (<kbd>Cmd+O</kbd>) — the standard macOS panel, starting in the
  current document's folder, else your last opened one's, else home.
- **Open Path…** (<kbd>Cmd+Shift+O</kbd>) — type or paste a path; a file opens
  it, a folder opens the file browser there.
- **Drag and drop** onto the window or the tab strip.
- **Recents** — the last 25 documents, on the Recently Opened menu and
  findable in the command palette. The list lives in `settings.yaml`.
- **Reopen Last Closed** (<kbd>Cmd+Shift+T</kbd>) — brings a just-closed tab
  back with its view state.
- **Last opened and last viewed** **mac** — every document the app keeps (tabs,
  recents, Collection and History copies) remembers when it was last opened and
  when you last looked at it: its tab in front, in the app in front, for at least
  2 seconds. Kept in `activity.yaml`; dates from before this was recorded are
  estimated once from older records and marked as estimates.
- **Favorites** — star a page or a whole document, give it a name and optional
  search labels, and find it later from the command palette or *Manage
  Favorites*.
- **Command palette** (<kbd>Cmd+K</kbd>) — one search field over favorites,
  open documents, and commands.
- **Make ShenzhenPDF the default PDF reader** — one menu item, no System
  Settings trip.

## <a id="tabs"></a>Tabs and windows

<p align="center"><img src="images/portable/macos-multi-window.webp" alt="Two windows side by side, each with its own tabs, one showing a Markdown document and one a PDF" width="880"></p>

- **Compact tab strip** — every tab outlined, same-named files disambiguated by
  their folder. Grouped tabs scroll horizontally with mouse-wheel or two-finger
  trackpad input. Left/right `+N` tabs overlay fading edges and open lists of
  offscreen documents without moving the strip. Collapsed group
  names stay visible beside the expanded document lane when space permits;
  overflowing group names remain reachable by scrolling. Long titles keep their beginning and
  ending visible with a middle ellipsis; hovering reveals the close button without moving the title.
- **Drag to reorder**, drag out to **detach into a new window**, drag back to
  **reattach**. A detached tab keeps its page, zoom, scroll and search.
  Dropping a tab between groups joins the existing General group, revealing it
  if hidden. If General is absent, it is created at that drop position. The
  resulting group membership and order are saved with the session.
- **New tab or empty group** — the tab-strip **+** opens a compact menu. **New Group…**
  creates a named empty group without changing the document you are reading;
  the next newly opened document (or batch of documents) goes into it. Its name
  starts selected in the popup. Empty groups and the next-open destination survive
  relaunch in session YAML and remain manageable from the tab strip and Groups panel.
- **Group controls** — hover a group name for the hide eye; right-click **Rename Group…**
  opens the name popup anchored to the group. The All Groups
  picker has an eye toggle for showing or hiding each group without closing documents.
  Manual tab-strip scroll position is restored per window from session YAML.
- **Read-only dot** — a tab opened from a read-only source is marked.
- **Multi-window session restore** — every window comes back with its own tabs,
  selected tab, size and position, on the display it was left on. The window
  you were last using returns focused, and the others open alongside it rather
  than a launch later.
- **A stand-in position is never saved** — launch with a display missing and the
  window is shown somewhere visible for that session only; the position you
  left is kept until you move the window yourself, and the window returns to its
  display when it reappears.
- **Per-document view state** — page, zoom, fit mode, scroll position, search
  text, and (for Markdown) page orientation come back per file.

## Collection and version history **mac**

- First-use choice to keep local copies and history, with on/off, location, storage cap and management in Settings. Reading continues from original paths.
- Background capture after opening; reachable recent documents are imported when Collection is enabled. Identical content shares storage, while distinct documents retain separate histories.
- Immutable original and version copies, pre-edit protection, saved milestones and deliberate deletion of copies. Deleting Collection history never deletes source documents. History’s context menu deletes individual saved versions; the linked original offers **Delete all previous backups…**, retaining the latest saved copy. Collection’s bulk action uses that same scope. Manual deletion includes kept versions after confirmation.
- Editable Collection documents with version history. Opening a saved version creates or reuses a writable working file without modifying retained snapshots. Rename changes its Collection filename and title while preserving the original source reference. Older History rows offer Compare with Latest in their context menu; Collection omits this self-comparison command.
- PDF and Markdown comparison with old/new panes, red removals, green additions, linked scrolling/zoom, and clickable change markers. Inserted and deleted pages have blank counterparts.
- A missing original opens its editable Collection document in the same tab and group, preserving reading position. A red toolbar pill marks the missing original, beside a Locate button. Collection documents no longer use a special Backups group. Missing-original recovery remains available. Locate Original offers manual selection or a cancellable exact-hash search, sorted by modification date from oldest to newest.
- Manage Collection has Documents and Settings in the left sidebar. Documents uses one list view with small page previews, with no layout selector or thumbnail grid. It shows each document once using its latest saved copy; search stays inside Documents and searches only those copies, with page thumbnails and contextual highlighted matches. History opens PDF/Markdown versions for reading or editing, and offers comparison and copy export, plus Keep forever when a storage limit is active. Earlier versions are confined to History, where a Latest pill identifies the current saved version independently of selection. Query, selected version/page, expanded matches and browsing positions persist.
- **Keep forever / Stop keep forever** — available only when a storage limit is applied. Marks or unmarks a saved version for retention. While any version is kept, the document’s whole history is protected from automatic cleanup. Removing the last mark makes it eligible for cleanup; nothing is deleted immediately. Explicit manual deletion remains possible. Returning to unlimited storage hides these controls without clearing existing marks.
- Per-document Pause / Resume saving actions are no longer offered. Existing saved copies, retention marks and legacy capture preferences remain unchanged.
- New setup defaults to a dynamic budget of 80% of free space plus existing Collection storage, adjustable from 50–80%. Static and Unlimited are also available, and existing saved choices are preserved. Move location verifies the transfer before removing old stored files; editable documents require a destination on the same disk. Open location reveals the current folder. With a cap, cleanup ranks least-opened documents, prunes their oldest previous versions first, and only then removes final Collection copies. A kept version protects the entire history; originals are never deleted. Editable Collection working files and their histories are excluded from automatic cleanup so edits cannot be lost.
- Markdown copies include bounded local dependencies; unavailable assets are reported. Encrypted PDF bytes remain encrypted and are not indexed as plaintext.

## Document assistant **mac**

- Optional OpenRouter chat beside the document, opened through **Cmd+K → Return** with an empty search or the Chats sidebar. Saved conversations have searchable messages, timestamps, editable titles and folders; drag chats between folders or ask the assistant to organize them.
- Cited answers open retrieved passages with highlights. Image-capable models can inspect pages, crops and the visible document viewport on request. Brief supported answers can use pastel cards with **View evidence**; evidence provenance checks do not certify model interpretation. An answer that rests on one document shows a card under it with that page's thumbnail, the title and the page; clicking it opens the document there. A citation still opens its document after the tab is closed, including a saved revision opened from History; a document that has been deleted is named without a link.
- One cached background request supplies a summary, keywords, up to six tags and missing chapters in the selected AI language. Authored outlines remain authoritative; only eligible latest revisions are analyzed.
- Drop files or folders on the chat, or attach them with the paperclip: that chat's assistant can read them, and nothing beside them; other chats can't. Its sandboxed Python reads your documents exactly, including the images a PDF embeds at native resolution and pages rendered at a chosen dpi, so it measures pixels and data itself. It saves any file you ask for to Downloads, in a folder there if you like (reports, CSV, charts, a copy of a read-only document), with a card in the chat; it can't read Downloads, except what that chat saved. Long requests keep going while they make progress; if one stops early, its answer says what is left and **Continue** picks up from there.
- Ask by date: the assistant sees when each document was last opened and viewed, so "close any document I have not viewed since a week" closes exactly those tabs in one step, names the ones with no record, and one Undo reopens them all.
- Supported group, reader, comment, rename, metadata and chat-organization actions have guarded Undo/Redo. Requested OCR, translation and PDF jobs create separate outputs. Everything the assistant makes, including charts you save, goes to Downloads under a clear name (never replacing a file) and into Collection as **Made by the assistant**. Stop cancels future work; completed changes remain until undone.
- Four-step setup covers file access, Collection, OpenRouter and per-format default-reader choices. Keys remain in Keychain; cloud analysis waits for completed setup and a connected account. Usage spends provider credits and can be disabled.
- The [document assistant guide](../portable/docs/document-assistant.md) specifies privacy routing, model requirements, action limits and local job dependencies. The [CLI/MCP guide](../portable/docs/agent-interface.md) is a separate interface; chat tool names are not external MCP commands.

## <a id="reading"></a>Reading and navigation

- **Continuous scrolling** with page stepping that keeps your zoom and position.
- **Fit page / fit width / fit height / actual size / custom zoom**, with zoom
  presets and <kbd>Cmd</kbd>+scroll zoom — including in an unfocused window.
- **Option + scroll turns pages** **mac** — anywhere in the window, over the page
  or the minimap; behaves exactly like the page arrows and pages faster the
  faster you spin.
- **Go to page** (<kbd>Cmd+L</kbd>), first/last page, page-by-page arrows.
- **Internal links** follow instantly and land at the top of the target page;
  the pointer becomes a hand over a link and an I-beam over text.
- **Text selection and copy**, including *Copy Selected Document Text* and an
  optional *Replace Line Breaks When Copying Text*. Copying is always allowed —
  a PDF's own copy-permission flag never blocks it.
- **Rotate page** clockwise / anticlockwise (<kbd>Cmd+R</kbd> /
  <kbd>Cmd+Shift+R</kbd>). On a Markdown document the same commands turn the
  *paper* landscape, and the text stays upright. Writable raster images use the
  same shortcuts and save their orientation to disk; JPEG uses lossless orientation
  metadata. Editable Collection images support the same rotation commands.
- **Presentation mode** (<kbd>F5</kbd> or <kbd>Cmd+Shift+F</kbd>) — chrome-free
  full screen, pure black surround, optional sleep prevention.
- **File → Properties** (<kbd>Opt+I</kbd> on Mac) — available for every open file,
  including Markdown, source code, images and missing originals. Pictures show
  pixel dimensions, megapixels, embedded resolution, color model/profile, bit
  depth, transparency, orientation, frame count and camera metadata when present.
  Text documents show live page, heading, language and word/character statistics;
  vector artwork shows page dimensions without invented pixel resolution. PDFs
  retain author, producer, dates, permissions, page and annotation statistics.
  File size and location remain available for other formats. Metadata is read
  only when Properties is opened. The complete file path wraps without truncation
  and can be selected in full or in part for copying.
- **Auto-reload** — a document edited on disk refreshes in place, keeping your
  place. For Markdown the new render is prepared off-screen and swapped in
  complete, so nothing blanks or flashes.

## <a id="search"></a>Search

- **Cmd+K on Mac:** open document names, group names, first five open-text results, first five Collection names (excluding open documents), then first five Collection-text results. `col:` searches Collection names and text directly.
- **Responsive palette:** document and group names appear immediately. Text
  results arrive asynchronously from lazy, bounded caches; changed files invalidate
  cached text, and superseded queries cannot overwrite newer results. No indexing
  work is added to launch.
- **Cmd+H on Mac:** open the current document’s Version History panel. Also available from View → Version History.
- **Cmd+D on Mac:** return to the previous active document, including a recently closed tab; press twice to switch back. The shortcut also works while a search field is focused.

<p align="center"><img src="images/portable/macos-search-highlights.webp" alt="A search with in-page highlights, chapter-grouped results and a current / total counter" width="880"></p>

- **Type anywhere to search** — typing outside text fields opens Find. Escape
  clears Find and restores the preceding panel and its visibility, including in fullscreen.
- **Live match count** — a running "current / total" as you type, with every
  match highlighted in the page.
- **Find next / previous** (<kbd>Enter</kbd> / <kbd>Cmd+Enter</kbd>).
  <kbd>Shift+Enter</kbd> remains an alternate previous-result shortcut.
- **Regular expressions**, including **multiline** patterns that span line and
  paragraph breaks. An invalid pattern fails gracefully instead of clearing your
  results.
- **Nearest-result jump** — an optional setting makes a new search land on the
  match closest to where you are reading rather than at the top.
- **Per-tab memory** — each tab remembers its query across tab switches and
  relaunches.
- **Search across everything** — the command palette searches open documents and
  favorites at once.

## <a id="map"></a>Document map and scrollbar

- **Minimap** — a live thumbnail strip beside the page: drag the viewport to
  scroll, click to jump, <kbd>Cmd</kbd>+scroll to zoom. Scales to hundreds of
  pages, renders lazily, and follows the reading theme.
- **Search markers** — hits appear as yellow marks in the map.
- **Scrollbar heat-map** — the scrollbar doubles as a match density map, one
  tick per hit with the active one hotter.
- **Per-document map preference** — show or hide the map per document, with a
  default for newly opened ones; a single-page document hides it automatically.

## <a id="sidepanel"></a>Chapters, comments and the side panel

<p align="center"><img src="images/portable/macos-chapters.webp" alt="Nested chapters with disclosure arrows, the filter field and the expand / collapse all button" width="320"></p>

- **One document panel** — Chapters, Find, Comments and History, with a separate
  Groups control. Unavailable document tools retain their capability checks.
- **Group navigation** — entering Groups reveals the active document. Group
  headers stay visible while scrolling their documents, giving way at the next
  group boundary. Normal refreshes preserve your browsing position.
- **Nested chapters** **mac** — a PDF's outline and a Markdown document's
  headings both fold, with the traditional disclosure arrows on every parent.
- **One expand / collapse all button** at the end of the filter row, showing the
  action it will perform.
- **Per-document memory** — what you left collapsed comes back collapsed, per
  file, across launches.
- **Filter field** — filter chapters or comments as you type.
- **Chapter-grouped search results** — every match with a snippet, grouped under
  its chapter heading; click to jump. Context includes and highlights the actual
  matched occurrence, including regex matches and text spanning lines.
- **Per-document panel preference**, with a default for newly opened documents.

## <a id="markdown"></a>Markdown **mac**

<p align="center"><img src="images/portable/macos-markdown.webp" alt="A Markdown document as an A4 sheet with a native flowchart and a table" width="880"></p>

Markdown opens as real A4 sheets in the same reader as PDFs — same tabs,
chapters, map, search, zoom presets, presentation mode and export. There is no
web engine, no JavaScript, and no network in the rendering path.

- **GitHub-flavored typography and palette**, paginated onto sheets.
- **Numbered sheets** — every page carries "Page 2 of 10" right-aligned in its
  footer, on screen and in every print and export, drawn rather than typeset so
  it is never a search hit.
- **Live update** — edit the file in another app and the document re-renders in
  the background and swaps in complete, keeping your place.
- **Landscape paper** — the Rotate commands turn the sheet; wide tables, images
  and diagrams re-fit to it. Each file reopens on the sheet you last read it on.
- **Adjustable text size** (<kbd>A−</kbd> / <kbd>A＋</kbd>), remembered across
  documents.
- **Dark palette, not a filter** — an Obsidian-flavored dark theme (dark paper,
  purple accents, dark-tuned syntax colors) that lands on the same paper and
  body-text colors as a dark PDF page.
- **Everything is real text** — selectable, searchable with <kbd>Cmd+F</kbd>,
  and still text in an exported PDF. That includes labels inside diagrams.

### <a id="markdown-syntax"></a>Markdown syntax support

<p align="center"><img src="images/portable/macos-markdown-code.webp" alt="Inline LaTeX math and a highlighted C code block with its Copy button and language pill" width="620"></p>

Strict UTF-8 CommonMark through vendored MD4C, plus:

| Feature | Support |
| --- | --- |
| Headings `#`–`######` | Real navigable headings; feed the chapter list |
| Emphasis, strong, inline code | Yes |
| Strikethrough `~~…~~` | Yes (GFM) |
| Links and autolinks | Yes; titles become tooltips |
| Images, local | Relative paths inside the document's verified directory only |
| Images, remote | `https` only, lazily downloaded into a shared disk cache |
| Lists, ordered and unordered | Yes, with nesting depth and indentation |
| Task lists `- [ ]` / `- [x]` | Yes (GFM) |
| Tables | GFM tables with per-cell alignment, content-aware column widths, header band, zebra striping, hairline grid that closes at a page break |
| Fenced code | Continuous rounded box, 31 languages highlighted, language picker and copy button on every block |
| Indented code | Yes |
| Block quotes | Yes |
| Callouts | Obsidian-style `> [!note]` callouts |
| Thematic breaks | Yes |
| Front matter | Conservative Obsidian YAML front matter |
| Wikilinks `[[page]]` and aliases | Yes |
| LaTeX math | `$inline$` and `$$display$$`, typeset natively |
| Footnotes | Not supported |
| `<details>` collapsing | Renders always expanded, with a bold ▸ summary line |

**Inline HTML** renders natively through a strict sanitizing whitelist (vendored
Gumbo HTML5 parser). Nothing is ever evaluated:

- Inline: `b`/`strong`, `i`/`em`, `u`/`ins` (underline), `s`/`strike`/`del`
  (strikethrough), `mark` (highlight), `code`/`tt`/`samp`, `sub`/`sup`,
  `kbd` (as a key-cap chip), `br`, `a href` (http/https/mailto/anchor only),
  `img` (with `width`/`height` size hints).
- Block: `h1`–`h6`, `hr`, `p`/`div`/`center` with `align`, `blockquote`,
  `ul`/`ol`/`li`, `pre`, and simple `table`/`tr`/`th`/`td`. `details`/`summary`
  as above.
- Dropped entirely, content included: `script`, `style`, `iframe`, `object`,
  `embed`, forms and form controls, `video`, `audio`, inline `svg`, `math`,
  `canvas`, `link`, `meta`, and every event or style attribute.

**LaTeX math** is a native subset typesetter — no WebKit, no JavaScript, no
network: Greek letters and common operator, relation and arrow symbols map to
Unicode; `x^2` and `a_{ij}` become raised and lowered runs; `\frac` collapses to
a vulgar fraction or a fraction-slash form; `\sqrt` degrades to `√(…)`; `\text`
sets upright; spacing commands map to Unicode spaces; an unknown command degrades
to its visible `\name` in the code font. Content is never dropped, and whatever
is shown is searchable.

**Syntax highlighting** covers 31 languages — C, C++, C#, CSS, Dart, Go,
Haskell, HTML, Java, JavaScript, JSON, Kotlin, LaTeX, Lua, Markdown,
Objective-C, Perl, PHP, Python, R, Ruby, Rust, Scala, Shell, SQL, Swift, TOML,
TypeScript, XML, YAML, and Plain Text — chosen from a searchable picker anchored
to the block, which also clears highlighting.

### <a id="diagrams"></a>Diagrams

<p align="center"><img src="images/portable/macos-markdown-gantt.webp" alt="A mermaid gantt chart rendered as vector art" width="620"></p>

Fenced `mermaid`, `sequence` (js-sequence) and `flow` (flowchart.js) blocks
render as native vector artwork — parsing plus geometry, no web engine, no
JavaScript, no network, no bitmaps. They stay crisp at any zoom and export to
PDF as vector art.

| Diagram | Support |
| --- | --- |
| `graph` / `flowchart` | TD/TB/BT/LR/RL; rect, round, stadium, circle, diamond, subroutine shapes; labelled solid, dashed and thick edges; bidirectional arrows; layered layout with routed long edges and a non-crossing fan; `classDef` styling via `:::name` or `class a,b name` |
| `sequenceDiagram` | Participants and aliases, arrow variants, notes, activations, `alt`/`opt`/`loop`/`par`/`critical`/`rect` frames |
| `classDiagram` | Compartments and the UML relation set |
| `stateDiagram` / `stateDiagram-v2` | Yes |
| `pie` | Yes |
| `gantt` | `YYYY-MM-DD` dates, durations, `after` chains, `done`/`active`/`crit`; takes the full width of the page, landscape included |
| `sequence` fences | js-sequence grammar, including its `Title:` line |
| `flow` fences | flowchart.js grammar |

`<b>`/`<i>` inside a label render as real bold and italic runs, `<u>`/`<ins>`
underline and `<s>`/`<strike>`/`<del>` strike through them, `<br/>` breaks
the line, and labels are fitted to the shape they sit in. Author colors from
`classDef` are painted verbatim in the light theme and put through the same
luma remap as everything else in the dark one, so hues stay distinguishable. A
fence the renderer cannot draw keeps its ordinary highlighted code box.

## <a id="annotations"></a>Annotations

- **Highlight comments** — select text, add a comment anchored to the
  highlighted rectangles.
- **Text comments** — drop a comment at a point on the page.
- **Edit and delete** existing comments.
- **Comment author** — set once (*Set Author for Comments…*) and reused.
- **Comments panel** — every comment listed with its page, filterable, click to
  jump.
- Comments are saved into the PDF immediately, so any other reader sees them.

## <a id="ocr"></a>OCR — on-device **mac · linux**

- **Make a scanned PDF searchable** with OCRmyPDF + Tesseract, entirely on your
  machine. Nothing is uploaded.
- **Images to searchable PDFs (macOS)** — run OCR on any image format the reader opens,
  including multipage TIFF. A separate PDF is created; the source image stays unchanged.
- **Language choice up front** — Simplified or Traditional Chinese alone or with
  English, plus ~20 more; missing language data is fetched on demand.
- **One job per core**, deskews scans, backs up the original, and swaps in only
  confirmed text.
- **One-click toolchain install** — missing OCRmyPDF, Tesseract or a language
  pack is installed for you (Homebrew on macOS; apt/dnf/pacman/zypper on Linux)
  and the job resumes, with a live copyable log.
- **Delete All Text** — strip a bad OCR layer back out.

## <a id="translation"></a>Translation **mac · linux**

<p align="center"><img src="images/portable/macos-translate.webp" alt="A whole PDF translated offline from English to Chinese, opened beside the original" width="880"></p>

- **macOS: choose Local or AI** from the menu below Translate. Local keeps the existing Argos workflow.
- **AI translation** uses your OpenRouter connection and model. Review the source text, choose a searchable target language (your AI language by default), then send explicitly. Selection and whole-document text are supported; scanned pages need OCR first.
- AI results are editable and saved as a **new Markdown copy** in Downloads (kept in Collection when it is on), not a layout-preserving PDF. Nothing is overwritten. Progress and Cancel are available; failed or cancelled requests do not save partial files.
- AI requests run sequentially in small text chunks. Documents above 500,000 characters are rejected with a request to select a smaller passage, never silently truncated.
- **Argos Translate**, running locally across ~19 languages including Chinese.
  Text never leaves the machine.
- **Translate a selection** into a panel, or **a whole document**. On macOS this
  includes Markdown, plain text, source code, EPUB and other readable text documents.
  Non-PDF documents are rendered to a separate PDF before translation; the source stays unchanged.
- **Local whole-document mode writes a real PDF** (`<name>_<lang>.pdf`) with the
  translated text overlaid at each source line's position, and opens it when it
  finishes.
- **Cancellable mid-run**, with the same one-click toolchain install as OCR.

## <a id="export"></a>Printing and export

- **Native printing** through the standard macOS pipeline, with **Fit**,
  **Actual Size** and **Custom** scaling.
- **Save As** — save the document, including added comments and rotations.
- **Save as PDF** from a Markdown document, page for page with what is on
  screen.
- **Copy Page** and **Copy Page Image**.
- **Single-page PDF export** from the core.
- **Exports never carry the dark theme.** A file that leaves the reader keeps
  the document's own colors — for Markdown as much as for a PDF.

## <a id="theme"></a>Appearance and reading theme

<p align="center"><img src="images/portable/macos-dark-theme.webp" alt="The same page in the light and dark reading themes; colored chart bars keep their hues" width="880"></p>

- **One dark reading theme for every document** (<kbd>Cmd+I</kbd>) —
  PDF, XPS, EPUB and Markdown alike, onto the same soft `#1E1E1E` paper rather
  than pure black.
- **Lightness remap, not inversion** — a rendered page keeps its chroma, so a
  red warning stays red and a blue link stays blue.
- **Keep Image Colors in Dark Theme** (<kbd>Cmd+Shift+I</kbd>, View menu) —
  leaves photographs and figures
  untouched, **per document**, defaulting to on and remembered per file. Scanned
  pages (one big image) are darkened anyway, so the setting can never quietly
  switch dark mode off.
- **Standalone images and comic archives** retain their original colors when
  Keep Image Colors is enabled; disabling it applies the dark reading theme.
- **Page separation that works in the dark** — a white sheet with a drop shadow
  in light, a crisp hairline border in dark, in the page view and the minimap
  alike.

## <a id="speed"></a>Speed

- **Instant launch** — the first page of the document you are actually opening
  is prerendered during launch, before the window is built.
- **Priority rendering** — the visible page renders first at high priority;
  nearby pages and inactive tabs warm up quietly behind it, so tab switches are
  instant.
- **Cached display lists** and crop-to-viewport rendering make repeat renders
  cheap; a stale render aborts within milliseconds.
- **Bounded, cancellable search** — a large no-match scan stays responsive.
- **Compact C core** — ~93 KB wrapping statically linked MuPDF 1.27.2 behind a
  small stable ABI shared by both frontends. No Win32 emulation.

## <a id="files"></a>Files, state and integration

- **Human-readable YAML state** you can read, diff and edit:
  `settings.yaml`, `session.yaml`, `documents.yaml`, `favorites.yaml`,
  `bookmarks.yaml`, `activity.yaml` (**mac**). Existing JSON state migrates automatically, originals kept
  as `.migrated-backup`.
  macOS: `~/Library/Application Support/ShenzhenPDF/` · Linux:
  `~/.config/shenzhenpdf/`
- **Show in Folder** and **Copy Path** for the current document.
- **Shenzhen Files integration** **mac** — install Shenzhen Files and it becomes
  the app's file manager on its own; *Settings ▸ File Manager* switches back to
  Finder, an explicit choice always wins, and every launch falls back to Finder
  if it is missing. Picking a file always uses the standard macOS panel.
- **Open in Adobe Acrobat Reader** when it is installed.
- **Permissions wizard** — walks through the macOS grants the optional features
  need (Accessibility for out-of-focus pinch zoom, Full Disk Access), and never
  nags once dismissed.
- **Keyboard shortcuts panel**, searchable, optionally shown at launch.

## <a id="updates"></a>Updates and verification

- **Once-a-day background check** against GitHub Releases, kept off the launch
  path, and switchable off.
- **Offline verification before installing** — pinned Apple Developer ID (Team
  66LJ4BV7Q3), hardened runtime, bundle id, and stapled notarization.
- **Atomic swap with rollback** — a failed installation restores the working app
  immediately; a mismatched relaunch keeps and reveals the previous `.old` app
  for manual recovery.
- **Skip a version** and it stays skipped.
- **Linux** ships a minisign-verified updater for the deb and tarball builds.

## <a id="shortcuts"></a>Keyboard shortcuts

### Search

| Action | Keys |
| --- | --- |
| Start searching from the document | Type anywhere |
| Find in current document | <kbd>Cmd+F</kbd> |
| Next / previous result | <kbd>Enter</kbd> / <kbd>Shift+Enter</kbd> |
| Groups panel | <kbd>Cmd+G</kbd> |
| Find next / previous | <kbd>Enter</kbd> / <kbd>Cmd+Enter</kbd> |

### Favorites

| Action | Keys |
| --- | --- |
| Command palette (open documents, favorites, commands) | <kbd>Cmd+K</kbd> |
| Favorite current page | <kbd>Cmd+B</kbd> |
| Favorite current document | <kbd>Cmd+Shift+B</kbd> |

### Pages and view

| Action | Keys |
| --- | --- |
| First / last page | <kbd>Opt+↑</kbd> / <kbd>Opt+↓</kbd> |
| Previous / next page (always jumps a page) | <kbd>Opt+←</kbd> / <kbd>Opt+→</kbd> |
| Previous / next page (keeps zoom and position) | <kbd>←</kbd> / <kbd>→</kbd>, <kbd>Cmd+↑</kbd> / <kbd>Cmd+↓</kbd> |
| Previous or next page, wherever the pointer is | <kbd>Opt</kbd> + scroll wheel |
| Go to page | <kbd>Cmd+L</kbd> |
| Jump a page | <kbd>Shift</kbd> + arrow |
| Scroll up / down | <kbd>↑</kbd> / <kbd>↓</kbd> |
| Zoom in / out | <kbd>Cmd++</kbd> / <kbd>Cmd+-</kbd> |
| Fit page / width / height | <kbd>Cmd+1</kbd> / <kbd>Cmd+2</kbd> / <kbd>Cmd+3</kbd> |
| Actual size | <kbd>Cmd+4</kbd> |
| Invert colors (light or dark reading theme) | <kbd>Cmd+I</kbd> |
| Invert images with the page | <kbd>Cmd+Shift+I</kbd> |

### Tabs and tools

| Action | Keys |
| --- | --- |
| Reorder or detach tabs | Drag tabs |
| Previous / next tab | <kbd>Cmd+←</kbd> / <kbd>Cmd+→</kbd> |
| Open file | <kbd>Cmd+O</kbd> |
| Open path | <kbd>Cmd+Shift+O</kbd> |
| Reopen last closed document | <kbd>Cmd+Shift+T</kbd> |
| Document properties | <kbd>Opt+I</kbd> |
| Rotate clockwise / anticlockwise | <kbd>Cmd+R</kbd> / <kbd>Cmd+Shift+R</kbd> |
| Presentation mode | <kbd>F5</kbd> or <kbd>Cmd+Shift+F</kbd> |
| Leave presentation mode | <kbd>Esc</kbd> |

### Panels

| Action | Keys |
| --- | --- |
| Show or hide chapters and comments | View menu or the Side Panel toggle |
| Show or hide the map | View menu or the Map toggle |

## Platform support

| | macOS | Linux | Windows |
| --- | --- | --- | --- |
| Frontend | AppKit | GTK4 + libadwaita | Win32 + Direct2D (`portable/win/`), no published binary yet |
| Reading, tabs, session restore | Yes | Yes | Yes |
| Search, map, scrollbar heat-map | Yes | Yes | Yes |
| Command palette, favorites | Yes | Yes | Yes |
| Presentation mode, printing, properties | Yes | Yes | Yes (print preview; Windows' own dialog where it opens) |
| OCR and translation | Yes | Yes | Yes (winget Tesseract, pip OCRmyPDF, Argos in a venv) |
| Markdown renderer, diagrams, math | Yes | — | Markdown and math via MuPDF's HTML engine; diagrams still draw as code boxes |
| Nested chapters, Option+scroll paging | Yes | — | Yes (Alt+scroll) |
| Auto-updater | Developer ID + notarization | minisign (deb, tarball) | Authenticode, pending a signed release |

Linux additionally offers an optional resident mode for instant launches.

Windows is a single statically linked executable that launches in about 130 ms
to a window with its first page already painted, so it needs no resident mode.
Everything above marked "Yes" for Windows is pinned by the native test suite in
`portable/win/tests/`; the exhaustive per-feature status, with evidence, is
`portable/docs/windows-feature-matrix.md`.
