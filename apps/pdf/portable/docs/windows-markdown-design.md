# Windows Markdown — spike, decision and design

*Markdown track, 2026-09-02. Status: the MuPDF route holds; converter, opener,
Windows module and tests are committed on the track branch; integration is a
set of one-line patches listed in §7.*

## 0. The decision in one paragraph

Markdown on Windows is **md4c → GitHub-flavoured HTML with a generated
stylesheet → MuPDF's own HTML/CSS engine, laid out on A4**. From there a
Markdown file is an ordinary `spdf_document`: the canvas, search, selection,
outline, links, minimap, print, Save as PDF and Copy Page are the PDF code
paths, unchanged. The alternative in the port plan — a DirectWrite paginator
re-implementing the Mac's TextKit subsystem (≈18k lines, "comparable to the
entire rest of the frontend") — was not needed: the spike in §2 shows MuPDF
rendering every construct the README promises at fidelity a reader would
accept, with three cosmetic gaps (§3) that do not justify a second text
engine. This is consistent with the settled product decision: parity is the
same content, styling, features and behaviour, not the Mac's page breaks.

## 1. What was measured, and how

`portable/win/tests/md_html_probe.c` opens an `.html` directly through MuPDF
(or an `.md` through the core once the converter existed), lays it out on
595×842 pt at a chosen em, and writes one PNG per page plus the outline MuPDF
derives and the link rectangles on page 0. The first spike was a hand-written
HTML file carrying the exact CSS the converter now generates; the second was
the README-style fixture `portable/win/tests/fixtures/readme-style.md` through
the real pipeline; the third was this repository's own `readme.md` (HTML-heavy,
7 pages). Everything below was looked at, not inferred.

Engine facts confirmed by reading `mupdf/source/html/` (1.27.2) and then by
rendering: `@page{margin}`; `border-collapse`, per-cell borders and
backgrounds; `:nth-child`; the `align`/`bgcolor` presentational attributes;
`id` anchors resolved by `fz_resolve_link`; `<a href>` → `fz_load_links`
rectangles; `<h1>`–`<h6>` → `fz_load_outline` with page numbers; SVG images
(`fz_new_image_from_svg`); over-wide images shrunk to the column; `white-space:
pre-wrap` + `overflow-wrap: break-word`; built-in fonts Helvetica (sans),
Courier (mono), Charis SIL (serif) with Noto fallback for CJK. Not in the
property table: `border-radius`, `max-width`, `page-break-inside`.

## 2. Fidelity: what renders right

| Construct | Verdict | Evidence |
|---|---|---|
| Headings, hairline underline under H1/H2, GitHub palette (#1F2328 text, #59636E muted, #0969DA links) | Right | `windows-captures/03-markdown-light.png` |
| Blockquote with 4 px left rule, muted text; callout title line | Right | 03 |
| Nested lists with disc / circle / square, ordered lists with `start`, task lists ☑/☐ | Right | 03 |
| Tables: hairline grid, #EAEEF2 header band, #FAFBFC zebra rows, content-sized columns, long cells wrapping inside their column, per-column alignment | Right | 03 (page 1), first spike |
| Fenced code: one continuous filled box with border, 31-language syntax colours, long lines wrapped inside the box, box fill carried across a page split | Right (square corners, see §3) | `05-markdown-code-light.png`, first spike pages 2–3 |
| Inline code chips, `<kbd>` caps, `<sub>`/`<sup>`, `~~del~~`, emphasis | Right | 03 |
| Links: external clickable, `#anchor` resolved to the heading's page through `spdf_link_at_point` | Right | markdown_open_test |
| Local images inside the document's folder, as centred figures with title-or-alt captions; inline images keep their flow | Right | `06-markdown-page3-light.png` |
| SVG badges with `width`/`height` in a centred `<div align>` | Right | 03 |
| README HTML through the whitelist: `<div align>`, `<p align>`, `<kbd>`, `<sub>`, `<details>` expanded behind a bold ▸ line, `onclick`/`style`/`<script>`/`<iframe>` stripped | Right | 05 ("Details"), SPDFCoreMarkdownTests |
| Horizontal rules | Right | 05 |
| LaTeX subset: Greek, operators, `^`/`_`, `\frac` (vulgar or slash), `\sqrt`, `\text`, display math centred and larger | Right, same subset as macOS | 06 |
| CJK and Hangul fallback | Right | 03 |
| Outline = H1–H3 with page numbers; H4–H6 excluded (as macOS) | Right | 03 sidebar, markdown_open_test |
| Search finds words on the right page and returns rectangles | Right | markdown_open_test |
| Dark rendition: #1E1E1E paper, #DCDDDE ink, #7F6DF2 purple links, #262626 code surfaces, dark-tuned syntax colours — a genuine palette, not a remap | Right | `04-markdown-dark.png` |
| Export: `spdf_export_pdf` writes vector, searchable pages; page count matches; always the light rendition | Right | markdown_open_test |
| Text size: em 5.5–33 pt (scale 0.5–3.0) relays the document; landscape swaps the sheet | Right | markdown_open_test |
| Real-world README (this repo's) | Right; `.webp` falls back to `[image]` (§3) | `C:\spdf-build\track-md\scratch\readme-render\readme.md-p-0*.png` |

Performance (Release, x64, this machine): the fixture opens **both** renditions
and renders its 4 pages to PNG at 1.5× in ~0.5 s total; the 7-page repository
README in ~0.9 s. Open alone is a fraction of that; no measurement suggested
the layout cost needs the Mac's background-pagination machinery.

## 3. What MuPDF does not do, and the supplement for each

Measured, not guessed. None is a fundamental; none justifies the DirectWrite
route.

| Gap | Effect | Supplement | Phase |
|---|---|---|---|
| No `border-radius` | Code boxes and `<kbd>` have square corners | Accept. A rounded box could be a `<img>` background pre-rendered per box size, but corners are not worth an image per block | — |
| No `page-break-inside: avoid`; `<thead>` not repeated after a split | A table row never splits (MuPDF keeps a line whole) but the header is not re-drawn on the continuation page; a code box continues without a closing rule at the break | Accept for now. A converter pre-pass cannot know page positions; a post-pass over the laid-out `fz_html` boxes could duplicate the header row — MuPDF-internal, deferred | C |
| No colour emoji | 🚀 renders as a monochrome Noto glyph | Accept; the Mac uses Apple Color Emoji, MuPDF has no colour font path | — |
| No WebP decoder | `.webp` images show as `[image]` (this repo's README uses WebP) | **DONE** (§9.1): `spdf_win_md_webp.{h,cpp}` decodes through WIC into a PNG in the same cache the https fetch fills, and the converter's new `local_image` hook rewrites the source to `.spdf-remote/<name>` | C |
| No interactive controls inside the page | No in-place language picker, no copy button on code blocks | **Mostly done (§9.3)**: the row is drawn and routable — but found from an `id` on each `<pre>` and one `spdf_markdown_resolve_anchor`, NOT from the structured text, which would have been a heuristic. Per-fence overrides are in `spdf_markdown_options`. Left: the picker's popup window | C |
| Diagram fences (`mermaid`, `sequence`, `flow`) | Highlighted code box — the documented fallback on macOS too | **The SVG supplement in this row is WITHDRAWN — see §9.2.** The spike renders correctly and as vector, but an SVG's `<text>` is unreachable to `fz_stext`, the export rasterizes it, and MuPDF's CSS cannot position a text overlay over it. The route that satisfies the promise is a small vendored-MuPDF patch (run a display-list image's list instead of filling it), and the fallback holds until then | D |
| Dark rendition draws images in their original colours | Matches "Keep Image Colors"; the Mac darkens images by default | Apply `spdf_recolor` to image regions only (the inverse of the existing `page_recolor_exclusions`) when the setting is off | C |
| `<details>` always expanded | Same as macOS | — | — |
| Remote images need a reopen after the download | First view shows `[Image: alt]` placeholders; the fetch completes, the tab re-shows | This is the Mac's shape too (lazy load, then rerender); wiring in §7 | B |

## 4. Architecture

```
  .md  ──read──▶  spdf_markdown_body_html()  ──▶ <body> HTML
                    │ md4c (GitHub dialect + LaTeX spans + wikilinks)
                    │ spdf_markdown_html.c   raw HTML through the whitelist
                    │ spdf_markdown_lex.c    31-language tokens -> <span class="hk">
                    │ spdf_markdown_math.c   LaTeX subset -> <i>/<sup>/<sub>
                    ▼
  spdf_markdown_document_html(body, dark)  ──▶ <!DOCTYPE html>…<style>palette</style>…
                    ▼                                 (two palettes, one geometry)
  fz_open_document_with_stream_and_dir(ctx, "html", stream, DIR)
  fz_layout_document(doc, 595, 842, 11pt × scale)      DIR = the .md's folder
                    ▼                                        + cache under .spdf-remote/
  spdf_document { doc = light, dark_doc = dark }  ──▶ every existing core call
```

**The converter is pure** (`spdf_markdown.c`, `_support.c`, `_html.c`,
`_lang.c`, `_lex.c`, `_math.c`; 2,300 lines, each under the 500-line cap): no
I/O, no globals, no MuPDF; same bytes out for the same bytes in, which is what
`SPDFCoreMarkdownTests` pins. Its one outward call is the remote-image hook,
and it only asks "is this URL cached, as what file name".

**Two renditions, one pagination.** The stylesheet is one template with
`$role` colour tokens filled from two palettes (the exact sRGB values of
`SPDFMarkdownTheme.mm`). Nothing else differs, so both layouts break pages
identically; the test diffs the two stylesheets and asserts every difference
is a `#RRGGBB`. The opener additionally checks the page counts agree and
drops the dark rendition if they ever did not.

**The core change** (`shenzhen_pdf_core.c`, whose cap is frozen and "may not
grow"): `struct spdf_document` moved verbatim into the core-internal
`spdf_core_document.h` so `spdf_markdown_open.c` can construct one — the file
shrinks by 19 lines net and the cap follows it down in
`tools/file-size-limits.tsv`. The one new field is `dark_doc`; the render
paths select it under `SPDF_RENDER_DARK_THEME` (`render_document()`), clear the
paper to `spdf_recolor_default_dark_theme().paper_rgb`, key the display-list
cache on the rendition, skip the lightness remap when a native dark rendition
exists, and `spdf_close` drops it. Every other format leaves `dark_doc` NULL
and behaves byte-for-byte as before (the seven native core suites still pass).

**The export rule holds by construction.** Print, Save As, Copy Page pass no
theme flag (`spdf_win_export_render_flags()` is `SPDF_RENDER_DEFAULT`), so
they never see `dark_doc`; `spdf_export_pdf` reads `doc->doc` explicitly.
`markdown_open_test` renders with and without the flag and asserts the
flagless picture is the light one.

**Security posture.** Nothing is evaluated anywhere. The whitelist swallows
`script/style/iframe/object/embed/form/input/select/textarea/button/video/
audio/svg/math/canvas/link/meta/template/noscript/head/title/base/frame`,
including their content and across md4c fragments (an inline `<script>`
opened in one text run keeps swallowing until its close tag). Only
`href/src/alt/title/align/width/height/start/colspan/rowspan/id` are read;
`href` must be http/https/mailto/relative/`#`; image sources must be relative
paths without `..`, drive letters or leading slashes, or https URLs the cache
already holds — and MuPDF's directory archive is the second fence. Budgets:
64 MiB input (the Mac's), md4c's own nesting limits, a 16-deep capture stack.

### 4.1 The additive core API (appended to `shenzhen_pdf_core.h`)

```c
typedef int (*spdf_markdown_image_hook)(void* user, const char* url, char* cache_name_out, size_t cap);
typedef struct spdf_markdown_options {
    float text_scale;          /* A-/A+; clamped [0.5, 3.0]; 1.0 = 11pt body */
    int landscape;             /* A4 landscape */
    int dark_rendition;        /* also lay out the Obsidian palette */
    spdf_markdown_image_hook remote_image; void* remote_image_user;
    const char* remote_image_dir;  /* mounted as .spdf-remote/ */
} spdf_markdown_options;
spdf_markdown_options spdf_markdown_default_options(void);
int  spdf_path_is_markdown(const char* path);
spdf_document* spdf_open_markdown(const char* path, const spdf_markdown_options*, char* err, size_t err_len);
int  spdf_export_pdf(spdf_document* doc, const char* path, int page_index /* -1 = all */, char* err, size_t err_len);
```

`spdf_open()` deliberately does **not** dispatch on the extension: a frontend
opts in per call, so macOS (its own reader) and Linux (today) see no change.
Linux gains Markdown by adding the seven units and md4c to its link line and
calling `spdf_open_markdown` for `.md` paths.

## 5. The Windows module

`portable/win/src/spdf_win_md.{h,cpp}` — `spdf_win_md_open_any(path)` is
`spdf_open` for everything but `.md`/`.markdown`; the text scale lives here,
persisted as settings.yaml `markdownFontScale` (the macOS key, two decimals,
clamped, stepped 10 %); `spdf_win_md_options_generation()` lets a long-lived
worker handle notice it is stale. Why process-wide: the core allows one handle
per thread, so the canvas, its render workers, the search worker and the
thumbnail strip each open the document — and they must paginate identically.

`spdf_win_md_images.{h,cpp}` — `%LocalAppData%\ShenzhenPDF\markdown-images`,
file name = FNV-1a-64 of the URL + the URL's extension (`.svg` kept because
MuPDF sniffs SVG from the name). The lookup is a stat, never a socket; misses
are remembered; `spdf_win_md_images_fetch_pending(hwnd, msg)` downloads them on
one background thread over WinHTTP (https only, https-only redirects, 20 s,
20 MB, `image/*`, atomic writes) and posts one message.

`spdf_win_md_commands.h` — the handlers the toolbar pill and menu rows call:
`spdf_win_md_command_text_step(a, ±1)` (persist, then re-show the tab, which
rebuilds the canvas and its workers over a fresh handle at the new em, the
path a tab switch already takes), `spdf_win_md_command_after_open` (start the
fetch), `spdf_win_md_command_images_arrived` (re-show).

## 6. Tests and how to run them

```
export SPDF_OUT='C:\spdf-build\track-md' SPDF_MUPDF_LIBDIR='C:\spdf-build\mupdf'
bash portable/win/tests/run-tests-native.sh --filter core       # 7 suites PASS + win.markdown_core_test PASS (qpdf BLOCKED as before)
bash portable/win/tests/run-tests-native.sh --filter markdown   # markdown_core_test, markdown_open_test PASS
bash portable/win/tests/run-tests-native.sh --filter md_win     # md_win_test PASS
bash tools/check-file-sizes.sh                                  # passes; core cap lowered to 3362
```

- `portable/core/tests/SPDFCoreMarkdownTests.c` — the converter byte for
  byte: slugs and de-duplication, H4 demotion, inline spans, link policy,
  image policy (relative / `..` / absolute / drive / `data:` / https with and
  without the hook / a hook answer that escapes the cache dir), figures and
  captions, task lists, table alignment, code fences (highlighted, unknown,
  diagram fallback, plain), the 31-entry catalog and aliases, every lexer
  family, the sanitizer (swallow across fragments, `<details>`, attributes
  dropped, `<font>` unwrapped, comments), math, front matter, BOM, entities,
  callouts, stylesheet colour-only diff, determinism, a 200 KB input.
  Runs under the harness today through the shim `win/tests/markdown_core_test.c`.
- `portable/win/tests/markdown_open_test.c` — the fixture through the core
  (§2 table's last rows), plus export round-trip, out-of-range page refused,
  1.6× produces more pages, landscape page size, the remote hook against a
  scratch cache, missing/empty path errors.
- `portable/win/tests/md_win_test.c` — the Windows module (§5), no network.
- Fixture: `portable/win/tests/fixtures/readme-style.md` (+ `md-icon.png`,
  `md-badge.svg`); captures 03–06 in `portable/docs/windows-captures/`.

## 7. Patch requests (other tracks' files; exact text)

All eight open sites take the same one-identifier change plus one include.
The build for the captures above was made with exactly these applied locally
and then reverted.

**Include** — first line of each of the seven files below:
`#include "spdf_win_md.h"`

| File | Old | New |
|---|---|---|
| `portable/win/src/spdf_win_main.cpp:151` | `a->doc = spdf_open(a->path, err, sizeof(err));` | `a->doc = spdf_win_md_open_any(a->path, err, sizeof(err));` |
| `portable/win/src/spdf_win_tabs_app.h:43` | `return spdf_open(path, err, err_len);` | `return spdf_win_md_open_any(path, err, err_len);` |
| `portable/win/src/spdf_win_render.c:283` | `g_slot_doc = spdf_open(path, err, err_len);` | `g_slot_doc = spdf_win_md_open_any(path, err, err_len);` |
| `portable/win/src/spdf_win_chrome_content.cpp:196` | `b->doc = spdf_open(b->path, err, sizeof(err));` | `b->doc = spdf_win_md_open_any(b->path, err, sizeof(err));` |
| `portable/win/src/spdf_win_chrome_thumbs.cpp:81` | `spdf_document* doc = spdf_open(s->path, err, sizeof(err));` | `spdf_document* doc = spdf_win_md_open_any(s->path, err, sizeof(err));` |
| `portable/win/src/spdf_win_chrome_thumbs.cpp:118` | `s->size_doc = spdf_open(s->path, err, sizeof(err));` | `s->size_doc = spdf_win_md_open_any(s->path, err, sizeof(err));` |
| `portable/win/src/spdf_win_search.cpp:212` | `doc = spdf_open(job->path, err, sizeof(err));` | `doc = spdf_win_md_open_any(job->path, err, sizeof(err));` |
| `portable/win/src/spdf_win_print.cpp:223` | `own_doc = spdf_open(utf8, open_err, sizeof(open_err));` | `own_doc = spdf_win_md_open_any(utf8, open_err, sizeof(open_err));` |

**Render worker staleness** — `spdf_win_render.c:281`, `core_doc()`: the cached
per-thread handle is reused when the path matches; after a text-size change
the canvas is rebuilt (workers exit, handles close), so no change is required
for correctness today. If workers ever outlive a canvas, compare
`spdf_win_md_options_generation()` alongside the path.

**Commands** — `spdf_win_main.cpp:239`: after
`#include "spdf_win_chrome_actions.h"` add
`#include "spdf_win_md_commands.h"`. In `spdf_win_menu.h`'s command enum add
`SPDF_WIN_CMD_MD_TEXT_SMALLER, SPDF_WIN_CMD_MD_TEXT_LARGER` before
`SPDF_WIN_CMD_COUNT`; in `spdf_win_menu_table.h` (View menu) two rows
`{SPDF_WIN_CMD_MD_TEXT_SMALLER, SPDF_WIN_MENU_VIEW, L"Smaller &Text", L"Ctrl+Alt+-", ...}` /
`{SPDF_WIN_CMD_MD_TEXT_LARGER, SPDF_WIN_MENU_VIEW, L"Larger Te&xt", L"Ctrl+Alt+=", ...}`
(accelerators at the coordinator's discretion; macOS binds the pill only);
in `spdf_win_chrome_commands.h` next to `SPDF_WIN_CMD_TOGGLE_THEME`:
`case SPDF_WIN_CMD_MD_TEXT_SMALLER: return spdf_win_md_command_text_step(a, -1);`
`case SPDF_WIN_CMD_MD_TEXT_LARGER: return spdf_win_md_command_text_step(a, +1);`.
Toolbar (`spdf_win_chrome_toolbar.h` / `.cpp` / `chrome_input.h`): one pill
`SPDF_WIN_TB_MD_TEXT_PILL` of `SPDF_WIN_TB_PILL_W` placed after the zoom pill
(position 10 in the macOS row, "A−" / "A＋" labels, shown only when
`spdf_win_md_selected_tab_is_markdown(a)`), its two cells dispatching the two
commands above. Launch: call `spdf_win_md_load_settings()` once before the
first tab is shown. Window procedure: `case SPDF_WIN_MD_WM_IMAGES_ARRIVED:
spdf_win_md_command_images_arrived(a); return 0;`, and after a successful
`show_selected_tab(a)` at open, `spdf_win_md_command_after_open(a, hwnd)`.

**Export paths** — `spdf_win_export.cpp` (`spdf_win_export_save_document_as`,
`..._save_page_as`) and `spdf_win_clipboard_page.cpp` (Copy Page): when
`spdf_path_is_markdown(utf8 path)`, call
`spdf_export_pdf(doc, path, -1 /* or page_index */, err, len)` instead of
`spdf_save_document` / `spdf_save_single_page_pdf`, which are PDF-only and
would report "Only PDF documents can be copied as PDF." Copy Page Image and
Print need nothing: they render through the flagless path.

**Build lists** —
`portable/win/build-native.cmd:100`:
old `for %%F in (shenzhen_pdf_core.c spdf_selection.c spdf_selection_support.c spdf_recolor.c spdf_yaml.c spdf_win_compat.c) do call :add_source "portable\core\%%F"`
new `for %%F in (shenzhen_pdf_core.c spdf_selection.c spdf_selection_support.c spdf_recolor.c spdf_yaml.c spdf_win_compat.c spdf_markdown.c spdf_markdown_support.c spdf_markdown_html.c spdf_markdown_lang.c spdf_markdown_lex.c spdf_markdown_math.c spdf_markdown_open.c) do call :add_source "portable\core\%%F"`
plus, on the next line, `call :add_source "ext\md4c\md4c.c"`.
Until this lands, `app.build` on the integrated branch fails at link with
unresolved `spdf_open_markdown`/`spdf_path_is_markdown` — loud, not silent.
`portable/win/tests/run-tests-native.sh`, `CORE_SUITES`: add
`"SPDFCoreMarkdownTests|-|portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c ext/md4c/md4c.c|"`
(then `win/tests/markdown_core_test.c` may be deleted).
`portable/Makefile`, `linux-gtk4` target (line 463): append
`core/spdf_markdown.c core/spdf_markdown_support.c core/spdf_markdown_html.c core/spdf_markdown_lang.c core/spdf_markdown_lex.c core/spdf_markdown_math.c core/spdf_markdown_open.c ../ext/md4c/md4c.c`
to the compile line when Linux takes Markdown (optional today: the core builds
without them). macOS needs nothing: its reader stays; `spdf_core_document.h`
is included by the core `.c` from the same directory.

**Docs** — `portable/docs/windows-captures/README.md` table, three rows:
`03-markdown-light.png` (the fixture, page 1, light), `04-markdown-dark.png`
(the same, `--dark`: the Obsidian palette), `05-markdown-code-light.png`
(page 2: syntax-coloured code boxes), `06-markdown-page3-light.png` (page 3
through the probe: figure, caption, math). `portable/docs/windows-feature-matrix.md`
Markdown row: PARTIAL — everything but diagrams, the in-page language picker /
copy button, WebP, and the toolbar pill.

## 8. Phased plan

**A — done on this branch.** Converter, opener, two renditions, export, the
Windows module, three test suites, fixture, captures, this memo.

**B — integration (coordinator, §7 patches; ~half a day).** The eight open
sites; the commands header, enum, menu rows, toolbar pill; `load_settings` at
launch; the images-arrived message and the after-open fetch; Save As / Save
Page As / Copy Page routing through `spdf_export_pdf`; build lists. After B a
Markdown tab is a first-class tab in the shipped exe.

**C — parity polish (this track; 2–3 days).** Rotate → `landscape` per tab
(the option exists; per-tab state as macOS's `markdownLandscape`, reopen on
toggle). Dark-theme images darkened unless "Keep Image Colors" (image-region
recolor). WebP → PNG through WIC into the cache. In-page language picker and
copy button as a Direct2D overlay over code-box rectangles with a per-fence
override map into the converter. Table header repetition after a split
(post-layout box walk). Math depth: `\overline`/radical rule via `border-top`
on an inline span if MuPDF honours it (untested), matrices as tables.

**D — diagrams (separate estimate).** ~~Port the Mac's parsers and layered graph
layout to C emitting SVG into a tree archive; decide whether diagram labels must
be searchable text or image pixels are acceptable.~~ **Re-scoped by the spike in
§9.2, which answered the question the second half of that sentence deferred: on
this engine SVG labels can only ever be pixels, and pixels are not acceptable
because the readme and 26.8.31-1 promise selectable labels in as many words.** D
is now two pieces, in this order: **D1**, the vendored-MuPDF patch that makes a
display-list image run rather than rasterize (a public accessor plus a branch in
the HTML draw path — small, benefits every SVG, and testable by inverting
`md_svg_text_test`); then **D2**, the engine port itself. D2 is bigger than §8
guessed: the Mac side is 4,783 lines across 18 units, of which the layered layout
(`SPDFMarkdownDiagramLayout.mm`, 468 lines, already C++ with plain structs), the
edge routing (369) and the parsers (1,124 across five kinds) transliterate almost
line for line, while text measurement (`CTTypesetterSuggestLineBreak` plus font
metrics) needs a real replacement — it is what every box size and every
label-containment proof rests on. Call it ~5,000 lines of C plus ~2,500 of ported
tests, and note that those tests assert *properties* (no node overlaps, ranks
monotone, no fan self-crossing, labels inside their outlines, drawn-within-size,
determinism), so they will validate a C port that agrees with the Mac's
pixels nowhere.

**Linux for free.** Add the units to the `linux-gtk4` link line and dispatch
`.md` to `spdf_open_markdown`; everything in §2 applies unchanged.

## 9. Phase C, as it lands

### 9.1 WebP through WIC — done

`![](shot.webp)` used to reach MuPDF's `load_html_image()`, fail to decode and
leave the literal word `[image]` on the page (`mupdf/source/html/html-parse.c
:714`); MuPDF 1.27 has `load-png/jpeg/gif/bmp/tiff/jpx/psd/pnm/jbig2/jxr.c` and
no `load-webp.c`. Windows itself can read WebP — WIC gained the "Microsoft Webp
Decoder" in Windows 10 1809 — so the frontend decodes the file and writes a PNG
into the cache directory MuPDF has already mounted.

**The core seam is one hook, appended to `spdf_markdown_options`:**

```c
spdf_markdown_image_hook local_image;   /* same signature as remote_image */
void* local_image_user;
const char* document_dir;               /* filled by spdf_open_markdown */
```

`spdf_markdown_resolve_image` offers a document-relative source to the hook when
its extension is one MuPDF cannot decode (a one-entry table: `.webp`), joining it
to `document_dir` first so the hook sees an absolute path; the answer is a bare
cache file name and is rewritten to `.spdf-remote/<name>` through the same
`mount_cache_name()` the https branch now shares — a name with a separator or a
`..` is refused for a local image exactly as for a remote one. **A refusal falls
straight through to the plain relative path**, so a Windows without the codec
still shows the `[image]` it always did, with no dialog and no retry loop. With
no hook installed nothing changes at all, which is what keeps macOS and Linux
byte-identical.

**`spdf_win_md_webp.{h,cpp}`** is the frontend half: a `.webp` name or a
`RIFF....WEBP` byte sniff selects a file; the cache name is FNV-1a-64 of the
case-folded absolute path plus the file's byte size and last-write time, so
editing the picture changes the name and the stale PNG is simply never asked for
again; the write is a per-thread `.part` moved into place, which is what makes it
safe for the several threads that open a Markdown document at once. The
remote-image lookup runs the same call over a file it downloaded, so a badge
served as WebP from a URL ending `.svg` is transcoded too — the bytes decide, not
the URL.

Proof: `md_webp_test` (the pure gates, the transcode, the cache reuse, and
`spdf_search_page(doc, 0, "[image]")` == 0 with the hook and == 2 without it, so
the assertion cannot pass vacuously), `SPDFCoreMarkdownTests`'
`test_local_image_transcode` (the pure rewrite, the path join with and without a
trailing separator, the escaping answer refused, each requirement disabling the
hook on its own), fixtures `webp-figure.md` + `md-shot.webp`. Rendered:
`C:\spdf-build\track-mdpolish\scratch\webp-after.png` (light),
`webp-dark.png`, and `readme-webp.png` — this repository's own README, whose
`macos-main-window.webp` screenshot is now a picture instead of a word.

### 9.2 The diagram route: the SVG spike, and why §3's row is wrong

§3's diagram row and §8's phase D proposed emitting **SVG into a
`fz_tree_archive` beside the document**, and hedged the label question with "the
Mac's 'labels are canonical text' promise needs a text overlay on top, which is
the trade-off to decide then". **The spike says there is no trade-off to decide:
the SVG route cannot keep the labels, and no text overlay is possible in this
engine.** Measured, not inferred — `md_svg_text_test` and the four renders below.

**What the SVG route does give.** A hand-written stand-in for a diagram emitter's
output (`portable/win/tests/fixtures/md-diagram.svg`: two node shapes, a rounded
rect and a stadium, a routed elbow, an arrowhead, a diamond, three labels) drawn
through the real pipeline as `![](md-diagram.svg)` renders **correctly and as
vector**. At 4× zoom the strokes, the corner arcs and the label glyphs are
resampling-free (`C:\spdf-build\track-mdpolish\scratch\svg-zoom4.png`). The
figure is centred, captioned and paginated like any other image, so the
"page-sized figures" work of 26.9.2-1 would come for free. The screen half of
26.8.31-1's promise is therefore reachable.

**What it does not give — three findings.**

1. **Labels are not searchable or selectable.** A label word that appears nowhere
   in the prose (`Kumquatlabel`) returns **no matches**, while the prose control
   word on the same page (`Aardvark`) returns exactly one — so the search works
   and the picture is what is opaque to it
   (`scratch\svg-find-unique.png`; the earlier `scratch\svg-find-label.png` shows
   the same thing from the other side: a word in *both* the prose and the picture
   reports "match 1 of 1", not 2). `spdf_extract_page_text_lines` agrees, which
   means the document map, Select All and translate agree too.
2. **The exported PDF is worse, not equal.** `spdf_export_pdf` writes the figure
   as an **image XObject** (`/Image` is in the bytes) and the label text is not in
   the content stream at all. So export loses both halves at once: not selectable
   *and* not vector — the opposite of "it stays selectable in the exported PDF".
3. **Why, and why an overlay cannot rescue it.** `<img src="*.svg">` goes to
   `fz_new_image_from_svg` (`mupdf/source/html/html-parse.c:670`), which builds a
   display list and then wraps it in an `fz_image`
   (`fz_new_image_from_display_list`, `mupdf/source/svg/svg-doc.c:241,258`). The
   HTML layout draws that box with `fz_fill_image`, and `fz_stext` never descends
   into an image — the glyphs are painted, never recorded. An **inline** `<svg>`
   is not an escape: `gen2_image_svg` (`html-parse.c:1310`) takes the identical
   road. And a text overlay cannot be positioned over the picture, because
   MuPDF's CSS has **no `position`, `top`, `left`, `float` or `transform`**
   (`mupdf/source/html/css-apply.c` — the property table has none of them). The
   engine is a pure block/inline flow engine; there is no way to put a glyph at a
   chosen (x, y) over a figure.

**The verdict.** Shipping the SVG route as designed would put pictures on the
page that look right and are, to search, selection, the map, translate and every
exported PDF, blank rectangles — while the readme and release 26.8.31-1 promise
the opposite in as many words. That is exactly the "shipping pixels silently"
outcome the track was told not to take, so phase D as written is **withdrawn**.

**The route that can work, and what it costs.** The text is not lost, only
unrecorded: the SVG's display list contains real `fz_fill_text` calls, and it is
kept alive inside the image (`fz_display_list_image { fz_image super; fz_matrix
transform; fz_display_list *list; }`, `mupdf/source/fitz/image.c:1645`). So the
fix is to make the HTML layout **run that display list under the box's transform**
instead of filling a pixmap of it. Then the same `fz_stext` pass that reads the
prose reads the labels, at their drawn positions, in place — and the PDF writer
receives vector operators and real glyphs, satisfying all three promises at once,
for every SVG in every Markdown document rather than only for diagrams. The cost
is a **vendored-MuPDF patch of two small pieces**: a public accessor for a
display-list image's list (there is none today; the struct is private to
`image.c`), and a branch in the HTML draw path that prefers it. `ext/_patches`
already exists for exactly this kind of change. Until that lands, a diagram fence
stays the syntax-highlighted code box it is today — which is also macOS's
documented fallback, so nothing regresses and nothing is claimed that is not
true.

`md_svg_text_test` keeps all of the above executable, including the control. **A
failure in it is good news**: it would mean the engine had learned to extract SVG
text, and the SVG route could then be taken as originally designed.

### 9.3 The code box's in-page controls — the row, drawn and routable

26.8.29-2 promises "a quiet language control in the box header" and 26.9.2-1 "a
copy button to the left of its language picker". There are no HTML widgets here
— the page is a picture MuPDF drew — so both are canvas chrome: a Direct2D pill
over the page, hit-tested against the very rectangles that were drawn.

**Finding a fence on the page, without looking at the picture.** The converter
now puts `id="spdf-code-N"` on every `<pre>`, and `spdf_markdown_scan_fences()`
(`portable/core/spdf_markdown_fences.c`) numbers the same N — both walk md4c
with identical flags after the identical BOM and front-matter skip, so fence N
and anchor `#spdf-code-N` are the same block **by construction**, not by a
geometric match. One `spdf_markdown_resolve_anchor()` per fence then gives the
page and the y, once per document rather than once per paint.
`SPDFCoreMarkdownTests`' agreement case counts the converter's anchors against
the scan's fences over one document, so the two cannot drift apart quietly.

Two traps, both measured rather than reasoned about:

- **MuPDF's HTML anchor y is in CONTENT space.** `htdoc_resolve_link`
  (`mupdf/source/html/html-doc.c:65-70`) divides by `html->page_h`, the
  *printable* height, and never adds `html->page_margin[T]` — unlike
  `fz_load_html_links`, which does (`html-outline.c:138-143`). A caller
  comparing it with a rendered page is a whole 60pt top margin out, and the
  symptom looks exactly like an off-by-one-element bug: in the first capture
  every pill sat on the *previous* block. `spdf_markdown_resolve_anchor` adds
  the margin once, and `SPDF_MARKDOWN_PAGE_MARGIN_TOP_PT` /
  `_SIDE_PT` / `SPDF_MARKDOWN_CODE_BOX_PADDING_PT` are exported beside the
  anchor prefix so a frontend never has to guess the generated stylesheet's own
  geometry.
- **What the anchor points at is the first line's baseline**, not the box's
  edge: `find_box_target` returns `find_first_content(box)->y`
  (`html-outline.c:149-206`). So the row is placed at `anchor − 12pt` (the box's
  own padding) and lifted to rest **on** the box's top edge with a 2px lip
  inside it. A row centred on that edge covered the first four characters of
  code; a row inside the box covered a whole line.

**The horizontal extent** is the stylesheet's text column — 61pt in from each
edge of the sheet, in points and so independent of the A-/A+ text size. That is
an approximation in one case only, a fence nested inside a list, where the real
box is indented and the pills sit a little wide of it. Reconstructing the box
from the laid-out text's rectangles would cost a structured-text pass per fence
to buy a few points, and nothing else in the reader depends on the number.

**Geometry is published, not queried**, exactly as `spdf_win_annot.h` states and
for the same reason: the paint that drew the pills hands the router each
rectangle in client device pixels (`spdf_win_md_code_publish_geometry`), and
`spdf_win_md_code_marks.h` — pure, header-only, the shape of
`spdf_win_annot_marks.h` — tests points against those. Painting and hit-testing
cannot disagree because they are the same numbers.

**Nothing reaches print or export**, by construction rather than by a check:
the pills are drawn only in the canvas phase of a *scene*, and print, Save as
PDF and Copy Page render through `spdf_export_pdf` and the flagless render path,
which never build one. `md_code_test` pins the other half of the cost model too
— a PDF tab finds no fences and publishes no marks, so it pays nothing.

**The picker's list** is `spdf_markdown_language_matches(index, query)`: a
case-insensitive substring of a language's id, display name or aliases, which is
`-languagesMatchingQuery:`'s rule, keeping the catalog's own sorted-by-name
order rather than a fuzzy score. The choice is recorded as a per-fence override
(`spdf_markdown_options.language_overrides`, honoured in `close_code`), which
beats the fence's info string *and* the rule that leaves a diagram fence
uncoloured; `"plain"` tokenises to nothing, which is how Plain Text clears
highlighting. Recording one bumps the options generation, so every handle that
reopens the document paginates identically — the same contract a text-size
change has.

Rendered, with the two patch requests below applied locally and then reverted
(the §7 precedent): `C:\spdf-build\track-mdpolish\scratch\code-pills-light.png`
and `code-pills-dark.png` — page 2 of `readme-style.md`, six code boxes, each
with **Copy** on the left of its top edge and its own language (C, Python, JSON,
YAML, Shell, Plain Text) with a ▾ on the right, in the light and Obsidian-dark
palettes, covering no code in either.

#### Patch requests (other tracks' files; exact text)

**1. `portable/win/src/spdf_win_d2d.cpp`** — one include beside the other
overlay include, and one call after the overlays. `spdf_win_md_code_paint.cpp`
is already in the app build (the source list is a wildcard over
`portable\win\src\*.cpp`), so it compiles today and only the call is missing.

| Old | New |
|---|---|
| `#include "spdf_win_d2d_overlay.h" /* draw_overlays; needs only the scene */` | `#include "spdf_win_d2d_overlay.h" /* draw_overlays; needs only the scene */`<br>`#include "spdf_win_md_code_paint.h"` |
| `    draw_overlays(target, scene);` | `    draw_overlays(target, scene);`<br>`    spdf_win_md_code_paint(target, scene);` |

**2. `portable/win/src/spdf_win_chrome_scene.h`** — one include, and one block
at the end of `chrome_publish_comments()`, which is already the function that
resolves the selected tab's document and publishes per-paint geometry:

`#include "spdf_win_annot.h"` → `#include "spdf_win_annot.h"` + a new line
`#include "spdf_win_md_code.h"`

and, after the two `spdf_win_annot_*` lines that close that function:

```c
    {
        char md_err[256] = {0};
        const char* md_path = NULL;
        spdf_document* md_doc = NULL;
        if (a->tabs) {
            int sel = spdf_win_tabs_selected_index(a->tabs);
            if (sel >= 0) {
                md_path = spdf_win_tabs_path(a->tabs, sel);
                md_doc = (spdf_document*)spdf_win_tabs_document(a->tabs, sel, md_err, sizeof(md_err));
            }
        } else {
            md_path = a->path;
            md_doc = a->doc;
        }
        spdf_win_md_code_frame(md_doc, md_path, scene, layout->canvas.x, layout->canvas.y,
                               spdf_win_canvas_zoom(a->canvas));
    }
```

`spdf_win_md_code_frame()` carries the policy (sync only when the path or the
options generation changed; clear when there is no document), so the call site
holds none. The early `if (!a->canvas)` return above it should also gain
`spdf_win_md_code_frame(NULL, NULL, NULL, 0.0f, 0.0f, 1.0f);` beside the
existing `spdf_win_annot_publish_geometry(NULL, ...)`, so a frame with no canvas
clears the marks rather than leaving the last document's.

**3. `portable/win/src/spdf_win_chrome_input.h`** — the routing, which is the
one piece not yet drawn from a capture. After the enum and hit struct are
complete, `#include "spdf_win_md_code_marks.h"`, and inside the canvas branch —
**before** the comment-badge test and before the point is offered to the canvas
as text, which is the mac's precedence
(`SPDFMacMarkdownPageCanvas.mm`: copy button, then language control, then
`characterIndexAtPoint`) — call

```c
    int md_copy = 0;
    int md_fence = spdf_win_md_code_mark_at(spdf_win_md_code_marks(&md_count), md_count, x, y, &md_copy);
```

and return a new action rather than `SPDF_WIN_CA_CANVAS`, so a click on a pill
never starts a text selection. Two commands then: the copy button calls
`spdf_win_md_code_copy(md_fence)` (clipboard plus the 1.2 s "Copied" title, with
a failed copy showing no feedback at all), and the language pill opens the
picker.

**What is left.** The picker's *popup window* — a small owner-drawn list
anchored to the pill, filtering through `spdf_markdown_language_matches` as the
reader types, arrow keys and Enter, Escape to dismiss — is not written. Its
model is (the filter predicate, the catalog's order, the override map and the
generation bump, all pinned by `md_code_test` and `SPDFCoreMarkdownTests`), and
choosing a language already re-highlights the fence on the next open; only the
Win32 shell that turns a click on the pill into a choice is missing. Until it
lands the pill draws and hit-tests but has nothing to open, so patch request 3
should wire the copy button first and leave the language pill inert rather than
route it somewhere that does nothing.
