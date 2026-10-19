# Windows Port — Handoff

Written 2026-09-01 from the macOS host, for the agent that runs **natively on
Windows** and continues this port. Branch `master`, HEAD `19cb2f6a8`.

You are inheriting a port that was built entirely from a Mac, driving a
Parallels VM through `prlctl exec`. That constraint shaped every line of it and
it disappears the moment you start work. Read §0 before anything else.

Everything below was checked against the tree at HEAD. Paths are repo-relative
unless absolute. Where a claim rests on a specific line, the line is given.

---

## 0. The one fact that matters most

> **Nobody has ever seen a ShenzhenPDF window open on Windows.**

Not opening, not repainting on resize, not scaling on a 2× display, not closing.
`prlctl exec` runs as `nt authority\system`, which has no interactive desktop, so
every claim any document in this repo makes about Windows is a **build, an exit
code, or a pixel comparison of an offscreen render**. The port plan's own
summary, which has survived three revisions and should survive yours:

> **Complete at the core-and-pixels layer, unproven at the window layer, and
> unprovable from here.** (`portable/docs/windows-port-plan.md` §0;
> `portable/docs/windows-port-qc.md` §4; `portable/win/README.md`, "What is and
> is not proven".)

You are the first participant in this project who can open the window. **Do that
first** — before reading more code, before writing anything. §7 is the ordered
list; item 1 is "build it, run it, look at it."

The user's goal is now explicit and it is not "make it compile": **"I want the
programs to look similar."** Visual and behavioural parity with the macOS app is
the objective. §3 is the brief for that and is the heart of this document.

---

## 1. Where the port actually stands

### 1.1 What the product is

ShenzhenPDF is a native macOS (AppKit) tabbed reader for PDFs and Markdown, built
on a portable C core wrapping MuPDF 1.27.2, with a GTK4 Linux frontend sharing
that core. `portable/core/` is platform-neutral: UTF-8 `const char*` paths in,
`spdf_bitmap` (width/height/stride/RGBA) out, no toolkit types, **no threading
primitives at all** — concurrency is the frontend's business, one `spdf_document`
per thread, no locking inside (`portable/core/shenzhen_pdf_core.c:40-43`).

The Windows frontend is plain **Win32 + Direct2D + DirectWrite**, C++17 under
MSVC, the core included as `extern "C"`. The reasoning is
`portable/docs/windows-port-plan.md` §3 and it is worth knowing because it
constrains you: WinUI 3 and Qt were rejected on launch-time cost (the product's
headline promise is "Launches instantly") and because neither renders headlessly.

**The inherited SumatraPDF Win32 tree in `src/` is not this.** 352 files,
140,727 LOC, **zero** references to `shenzhen_pdf_core` or any `spdf_` symbol. It
is a different application with a different document engine. It is not a
shortcut, and `agents.md` says so.

### 1.2 Phase status

| Phase | State |
|---|---|
| **0** Toolchain | complete — MuPDF 1.27.2 built native ARM64, 646 objects, all `AA64` |
| **1** Window + real page | complete at the core-and-pixels layer, **unproven at the window layer** |
| **2** Continuous canvas | complete, differentially tested against the GTK4 original |
| **3** Worker render pipeline | complete — pool, coalescing, cancellation, byte-capped LRU, prefetch |
| **4** Shell: tabs, state, session | **model complete, chrome absent** — see §1.4 |
| **5** Find, sidebar, minimap | not started |
| **6** Selection, links, annotations, printing, export | not started |
| **7** OCR, translation, updater, default reader | not started |
| **8** Markdown | out of scope; see §4 |

### 1.3 What is proven, and how

`portable/win/tests/run-tests.sh` → **27 cases, 0 failed, 0 blocked, exit 0**
(~50 s), run from macOS against the guest. The inventory:

- 4 harness/host cases: `selftest.compare-png`, `layout.differential`,
  `harness.exit-code`, `harness.non-ascii-path`
- 8 probe cases: `probe.{mac,win,diff,png}`, `alpha.{mac,win,diff,png}`
- 4 Direct2D compose cases: `d2d.{exact,window}-{plain,dark}`
- 3 core suites: `core.SPDFCore{Recolor,Compat,Save}Tests`
- 8 auto-discovered `win.*_test` suites: layout_geometry, lru_cache, paths,
  render_service, session, silent_failure, state, tabs

Proven facts, each re-verifiable:

- **The rendered page is byte-identical to macOS**, on an opaque fixture
  (`golden.pdf`, sha256 `00432a55a58dbfe1…`) and an alpha-bearing one
  (`alpha.pdf`, sha256 `32c0e3b9de92eeeb…`, 49,660 partially transparent px).
  Tolerance is pinned at **zero** (`compare_png.py --strict` decides the case).
- **The Direct2D compose path is byte-identical too**, in both plain and dark,
  for `--render-png` (exact zoom) and for a `--render-window-png` frame cropped
  to the page rect the app itself printed (`portable/win/tests/d2d-cases.sh`).
  Proven to gate: substituting R for B in `rgba_to_bgra()` fails all four.
- **The binary is native ARM64** — every object in `libmupdf.lib`,
  `libmupdf-third.lib` and `ShenzhenPDF.exe` is `AA64`, not x64 emulated.
- **The layout maths equal the GTK4 originals.** `layout.differential` compiles
  `portable/linux/gtk4/spdf_docview_internal.h` and
  `portable/win/src/spdf_win_layout.h` into one binary and asserts exact
  equality function by function: **397,099 comparisons, 0 mismatches.**
- The render pool's callback-exactly-once and cancellation contracts hold; the
  state layer round-trips YAML and refuses to overwrite state it could not read.

Not proven, and not provable from macOS: **anything interactive.** A window
opening. A repaint. DPI on a 2× display. A real mouse event. A menu. A drag.

### 1.4 macOS vs Windows, feature by feature

This is the parity ledger. "Model" means the logic exists and is tested but
nothing draws it.

| | macOS | Windows today |
|---|---|---|
| Window frame | `SPDFWindow`, transparent titlebar, chrome views embedded in it | bare `WS_OVERLAPPEDWINDOW`, OS frame, `spdf_win_window.cpp:361` |
| Window title | per-tab, updated on switch | set once at `CreateWindowExW`; **no `SetWindowTextW` anywhere** |
| Frame follows the theme | system appearance, free | no `DWMWA_USE_IMMERSIVE_DARK_MODE`: a light frame around a dark canvas |
| Tab strip | `SPDFTabStripView`, 42 pt tall, drag/detach/reattach, overflow menu, read-only dot | **nothing drawn.** Model complete (`spdf_win_tabs.cpp`, mac-parity close policy); reachable only by Ctrl+Tab / Ctrl+W |
| Toolbar | `SPDFToolbarStackView`, 42 pt, 18 arranged subviews, overflow | **does not exist.** No child window is ever created |
| Sidebar | 240 pt default, **visible by default**, Chapters/Comments/(Search) segmented control, filter field | does not exist; `showSidebar` is carried through session.yaml untouched |
| Minimap | `SPDFMacMinimapView`, 126.5 pt default, **visible by default**, 72–260 resizable | does not exist |
| Find | toolbar search field, regex checkbox, count label, paired prev/next pill, in-page highlights, scrollbar heat-map | does not exist; `searchText` carried through untouched |
| Menus / accelerators | full menu bar, command palette (Cmd+K) | no `HMENU`, no accelerator table, no `WM_COMMAND` |
| Scrollbars | native, with search heat-map | none. `SpdfWinHScrollClamp.scrollable` is computed and discarded (`spdf_win_canvas.cpp:87-88`) |
| Continuous scroll canvas | yes | **yes** — same geometry, differentially tested |
| Cursor-anchored zoom | yes | **yes**, Ctrl+wheel, `powf(1.1f, notches)` |
| Fit width / page / actual | yes | **yes**, Ctrl+1 / Ctrl+2 / Ctrl+0 |
| Dark reading theme | toolbar toggle, Cmd+I, every tab, persisted | **`--dark` command-line flag only.** No toggle, no persistence, no OS-theme following |
| Keep Image Colors | View menu item, Cmd+Shift+I, **defaults ON** (`f27d28f6f`) | forced on whenever `--dark` is passed; not separable (`spdf_win_main.cpp:379-382`) |
| Session restore | multi-window, per-tab page/zoom/fit/scroll | **yes**, same `session.yaml`, cross-process merge under `session.lock`; **window geometry not persisted** |
| Open a file | Cmd+O, drag & drop, Finder association, recents, favorites | **command line only.** No `WM_DROPFILES`, no `IFileOpenDialog`, no association |
| Selection / links / annotations | yes | none — `WM_LBUTTONUP` only ends a drag |
| Printing, OCR, translation, updater | yes | none |
| Markdown | full subsystem, ~18,100 LOC | none, and out of scope (§4) |

The honest summary of the frontend as it stands: **a single window whose entire
client area is one Direct2D render target drawing a vertical strip of page
bitmaps on a flat background.** `spdf_win_paint()`
(`portable/win/src/spdf_win_d2d.cpp:292-339`) is the complete list of what the
app draws — a background clear, per page a one-band shade rect and a
`DrawBitmap`, and a centred DirectWrite message when there are no pages.

---

## 2. Building and running natively on Windows

### 2.1 What exists, and why you should stop using most of it

| script | side | what it did |
|---|---|---|
| `portable/win/sync-to-vm.sh` | macOS | rsync `portable/core`, `portable/win`, `ext`, `mupdf` into `~/Documents/spdf-win`, which the guest sees as `\\Mac\Home\Documents\spdf-win` |
| `portable/win/vm-build.sh` | macOS | `prlctl exec` the guest build and **return the guest's exit code** |
| `portable/win/guest-build.cmd` | guest | robocopy share → `C:\spdf`, enter the MSVC env, run `cl.exe` |
| `portable/win/mupdf-gen-ninja.sh` | macOS | generate `build.ninja` for libmupdf by parsing `make -n` from `mupdf/Makefile` |
| `portable/win/mupdf-build.cmd` | guest | run ninja over that description |
| `portable/win/tests/run-tests.sh` | macOS | the 27-case harness, orchestrating both sides |

All of that is a **remote-control layer you no longer need**. Natively you have
the repo on disk, a shell, and `cl.exe`. Keep the scripts (the macOS host may
still want them and they encode hard-won knowledge — see §6), but do not extend
them. **Write a native build script**; there is none, and its absence is the
single biggest friction in this tree. `portable/win/README.md` says so
explicitly: *"No CMake project and no source manifest exists for the app target,
so its translation units are spelled out by hand at every call site."*

### 2.2 The toolchain that is already installed

Measured in the guest and recorded in `portable/win/README.md` "Toolchain":

| Component | Version | Location |
|---|---|---|
| VS 2022 Build Tools | 17.14.39 | `C:\BuildTools` |
| MSVC | 19.44.35228 / toolset 14.44.35207 | `C:\BuildTools\VC\Tools\MSVC\14.44.35207\bin\HostARM64\arm64\cl.exe` |
| Windows SDK | 10.0.26100.0 | |
| CMake | 3.31.6-msvc6 | on `PATH` **only after `vcvarsall.bat`** |
| Ninja | 1.12.1 | same |

The guest is **Windows 11 on ARM64** (build 10.0.26200.8875,
`PROCESSOR_ARCHITECTURE=ARM64`). Windows on ARM runs x64 under emulation
happily, so a mis-targeted build *appears* to work while being slower and subtly
different. **`Microsoft.VisualStudio.Component.VC.Tools.ARM64` is load-bearing**:
the base `VCTools` workload on an ARM64 host installs only `HostARM64\x64` and
`HostARM64\x86` — ARM64-hosted *cross* compilers that emit x64/x86. Without that
component there is no `HostARM64\arm64` at all.

Verify what you produced, always:
`portable/win/mupdf-arch-check.cmd` (or `.sh`) prints the machine type; anything
but `AA64` is wrong. Passing a target without the `.exe` suffix exits 94 with a
clear message.

### 2.3 MuPDF

`libmupdf.lib` + `libmupdf-third.lib`, ARM64, `/MT`, live in `C:\spdf-build\mupdf`
in the guest — **check whether they are still there before rebuilding anything**;
the build takes ~59 s cold and the artefacts may already be on the machine you
are running on.

If you must rebuild, understand the arrangement before you touch it
(`portable/win/mupdf-gen-ninja.sh` header):

- **`mupdf/platform/win32/mupdf.sln` is not used and would not have worked.** It
  carries ARM64 configurations, but its feature set differs from the Mac build's
  and would drift silently — which would destroy the byte-identity claim that is
  the whole correctness story. The build description is instead derived
  mechanically from `make -n` inside `mupdf/` using `portable/Makefile`'s own
  arguments, so the two hosts compile the *same* MuPDF.
- **MSVC cannot compile MuPDF's embedded font resources.** `cl.exe` needs
  multiple GB of heap per MB of string literal and
  `generated/resources/fonts/han/SourceHanSerif-Regular.ttc.c` is 103 MB
  (`fatal error C1060`). `portable/win/mupdf-bin2coff.c` writes the original
  binary straight into a COFF object instead. MuPDF's own `scripts/bin2coff.c`
  is *not* used: its ARM64 output leaves the size word unaligned and fails
  `LNK2048` across roughly three quarters of the 182 font blobs.

`build.ninja` is generated by a **bash** script that shells out to `make -n`. On
Windows you will need Git Bash/MSYS for that, or you keep generating it on the
Mac, or you commit the generated description. Decide deliberately; do not
silently switch to `mupdf.sln`.

### 2.4 The link line

There is no source manifest. Today the app's translation units are listed by
hand (`portable/win/README.md` TL;DR, and `portable/win/tests/d2d-cases.sh`
discovers them from `portable/win/src` instead):

```
portable/win/src/spdf_win_main.cpp      spdf_win_window.cpp   spdf_win_d2d.cpp
portable/win/src/spdf_win_canvas.cpp    spdf_win_canvas_prefetch.cpp
portable/win/src/spdf_win_lru.c         spdf_win_paths.c      spdf_win_render.c
portable/win/src/spdf_win_state.c       spdf_win_tabs.cpp     spdf_win_session.cpp
portable/core/shenzhen_pdf_core.c       spdf_selection.c      spdf_selection_support.c
portable/core/spdf_recolor.c            spdf_yaml.c           portable/core/spdf_win_compat.c
```

**`portable/core/spdf_win_compat.c` belongs in EVERY Windows source list.** It is
the POSIX shim that `shenzhen_pdf_core.c:5` and `spdf_yaml.c:6` and six core test
suites `#include`; omitting it produces a wall of
`LNK2019: unresolved external symbol spdf_compat_*` rather than a compile error
at the file that wanted it. Note the path: **`portable/core/`, not
`portable/win/src/`.** The README claimed otherwise for a while and
`run-tests.sh`'s header comment still does.

Compile flags in use (`portable/win/guest-build.cmd:112-116`):

```
cl /nologo /W3 /O2 /MT /utf-8 /D_CRT_SECURE_NO_WARNINGS
   /I portable\core /I portable\win\src /I <mupdf>\include
   ... /link /STACK:8388608 <mupdf libs> <sys libs>
```

`/MT` is stated explicitly because `libmupdf.lib` is `/MT` too and mixing CRTs
produces link errors that read like missing symbols. `/STACK:8388608` matches
macOS's 8 MB main thread — Windows defaults to 1 MB and MuPDF's content-stream
and CSS recursion can outrun that on real files.

A CMake + Ninja project generating this, discovering `portable/win/src/*` and
hard-coding the `portable/core` list, is a morning's work and pays for itself
immediately. `d2d-cases.sh:101`'s discovery approach is the precedent: a track
adding a file must not break someone else's build line.

### 2.5 Running the app

```
ShenzhenPDF.exe <path.pdf>                                  windowed
ShenzhenPDF.exe --dark <path.pdf>                           windowed, dark reading theme
ShenzhenPDF.exe --render-png      <pdf> <page0> <zoom> <out.png>
ShenzhenPDF.exe --render-window-png <pdf> <page0> <w> <h>  <out.png>
```

Pages are **0-based everywhere** (`spdf_win_main.cpp:19-24`; this disagreed with
the probe for a while — QC F13). `--render-window-png` prints the geometry it
composed, which is how fit modes are checked without a window:

```
frame viewport=900x700 zoom=4.500000 scroll=247.0000,0.0000 content=1394.0000,1942.0000
frame draw page=0 dest=0.0000,13.0000 size=900.0000,1170.0000 bitmap=900x1170
```

Keys currently bound (`spdf_win_main.cpp:142-191`): arrows (60 px), PgDn/Space
(+0.9 viewport), PgUp, Home, End, `+`/`-` (×1.25 / ×0.8 about the centre),
Ctrl+0 actual, Ctrl+1 fit width, Ctrl+2 fit page, Ctrl+Tab / Ctrl+Shift+Tab,
Ctrl+W, Esc closes the window. Nothing else. Wheel scrolls (honouring
`SPI_GETWHEELSCROLLLINES`), Shift+wheel and the horizontal wheel pan, Ctrl+wheel
zooms about the cursor, left **and middle** drag pan.

### 2.6 Running the tests natively

`run-tests.sh` is a macOS-side orchestrator: it builds on both hosts, drives
`prlctl`, and compares against macOS reference PNGs the Mac produces. Natively,
roughly half of it is meaningless and the other half is the part you want.

- The **8 `win.*_test.c` suites** and the **3 core suites** are plain console
  binaries. Compile and run them directly; exit 0 is pass. Their extra
  translation units are declared in the sources themselves as
  `/* spdf-test-sources: … */`, `/* spdf-test-args: … */`,
  `/* spdf-test-needs: mupdf */` (`portable/win/README.md`, "Adding a test for
  your track").
- The **cross-host PNG comparisons** need macOS reference images. Either keep
  running those from the Mac, or commit the references. Do not quietly drop
  them: they are the port's strongest evidence.
- `layout.differential` needs glib and the GTK4 header; it is marked
  `/* spdf-test-host: mac */`-adjacent by not being named `*_test.c`. That naming
  is load-bearing and documented as such (`ec06609cb`).
- **Five** core suites remain unregistered and free: `SPDFCoreOutlineTests`,
  `SPDFCorePasswordTests`, `SPDFCoreRenderThemeTests`, `SPDFCoreSelectionTests`
  and `SPDFCoreCJKSelectionTests` are written, pure C over MuPDF, and absent from
  `CORE_SUITES`. Cheapest outstanding win in the port. (Both
  `windows-port-qc.md` §6.3 and `portable/win/README.md` call this "four" while
  listing five; it is five.)

Three habits in the harness may not be tidied away, and they apply to whatever
you write next: **no `set -e`; nothing piped through `grep`/`tee` to decide pass
or fail; the final status computed from recorded results.** A missing
prerequisite records **BLOCKED**, which exits 2 — never a silent skip.

---

## 3. The visual parity brief

This is the part nobody before you could act on. The goal is that a Windows
screenshot and a macOS screenshot of the same document look like the same
program.

### 3.1 Reference material you can actually see

You cannot see the macOS host. You **can** see these, and they are in the repo:

- `docs/images/portable/macos-main-window.webp` — the main window: tab strip
  with traffic lights and a read-only dot, the toolbar row, the Chapters/Comments
  sidebar with its filter field, the page canvas, the minimap strip on the right.
- `docs/images/portable/macos-multi-window.webp` — two windows side by side.
- `docs/images/portable/macos-search-highlights.webp` — chapter-grouped results,
  in-page highlights, the "2 / 19" counter.
- `docs/images/portable/macos-translate.webp` — the translate panel.

They are dated 2026-06-27 and the chrome has moved since (the mac window-chrome
files are under active edit right now). **When a screenshot and the source
disagree, the source wins.** `readme.md` is the product-level description of what
the app looks like and does, and it is kept current as a release gate.

### 3.2 The dark theme is a luma remap, not an inversion

This is the single most important behavioural fact about the reading theme, and
it is easy to break by "simplifying" it.

`portable/core/spdf_recolor.h:9-18` and `spdf_recolor.c:69-98`: for each pixel,
compute Rec.601 luma Y with integer weights that sum to exactly 256
(`SPDF_LUMA_R 77`, `SPDF_LUMA_G 150`, `SPDF_LUMA_B 29`, `spdf_recolor.c:5-9`),
then

```c
y = (77*r + 150*g + 29*b + 128) >> 8;              /* 0..255, white->255 */
px[i] = clamp8( c - y + ink[i] - (((y*span[i] + 127) * 32897) >> 23) );
```

where `ink = (220,221,222)` (`#DCDDDE`), `span = ink - paper = (190,191,192)`,
and `(v*32897)>>23` is an exact unsigned divide-by-255 for `v < 2^24`. Alpha is
untouched. White (Y=255) → `255-255+220-190 = 30` = `#1E1E1E`; black (Y=0) →
`220` = `#DCDDDE`.

Because **the same offset lands on all three channels**, the channel differences
(R−G, G−B) — the chroma — survive: a red warning stays red, a blue hyperlink
stays blue. A per-channel inversion (`fz_invert_pixmap`, `fz_tint_pixmap`,
SumatraPDF's `UpdateBitmapColors`) flips them to their complements. Those modes
exist in the enum (`SPDF_RECOLOR_TINT`, `SPDF_RECOLOR_INVERT`) **for comparison
and measurement only**; `SPDF_RECOLOR_LUMA_REMAP` is the shipping one. Costs one
dot product, three adds and three clamps per pixel; no table, no floating point.

Consequences you must preserve:

- The transform is **fused into `copy_pixmap_to_bitmap()`**
  (`shenzhen_pdf_core.c:557-582`), the single tail of every render path, so it
  rides the row while it is still in L1.
- It is **opt-in per render** (`SPDF_RENDER_DARK_THEME`,
  `shenzhen_pdf_core.h:168`), never a mode on the document — so print, export and
  Copy Page get the document's own colours by doing nothing.
- **Picture documents are never recoloured at all.** `spdf_recolor_path_is_picture()`
  (`spdf_recolor.c:156-189`) matches `cbz cbr cb7 cbt zip tar png jpg jpeg jpe
  jfif gif bmp tif tiff pnm pam pgm ppm pbm jxr hdp wdp jpx jp2 j2k psd webp`;
  anything else, including an unknown extension, is treated as a document. The
  decision is made once at open (`shenzhen_pdf_core.c:181-182`).
- `SPDF_RENDER_PRESERVE_IMAGES` (`:170`) leaves image regions in their original
  colours. Image bboxes come from one structured-text pass, cached 4 pages LRU,
  max 24 rects per page (`spdf_recolor.h:125-147`), and excluded spans are
  skipped entirely rather than recoloured and undone (`spdf_recolor.c:107-145`).
- **Except on a scan.** A page whose `image_backed` flag is set reports **zero**
  exclusions and is recoloured whole (`spdf_recolor.c:240-244`), so the setting
  can never silently turn dark mode off on a scanned document. The test
  (`shenzhen_pdf_core.c:1309-1320`): largest image ≥ 55% of the page area, or
  more than one image totalling ≥ 75%.
- **"Keep Image Colors in Dark Theme" now defaults to ON** (`f27d28f6f`).
  Settings-menu item at `ShenzhenPDFMac.mm:2391-2395`; persistence key
  `"darkThemePreservesImages"` in `settings.yaml` (written :2081, read :1458 and
  :609); the default is applied at `:1421` and again at `:609-610` for the
  pre-state launch prerender, and a stored key of any value overrides. Windows
  currently forces `PRESERVE_IMAGES` on whenever `--dark` is passed and offers no
  way to turn it off — matching the default by accident, not by design.
- The theme preference itself is `"markdownTheme"` = `"dark"` / `"light"`
  (`ShenzhenPDFMac.mm:1444-1446, 2080`), which keeps its legacy name although it
  now governs every format. Shortcut Shift+Cmd+I → Shift+Ctrl+I.

Two stale comments to ignore, not copy:
`portable/mac/SPDFMacMarkdownSession.h:34` and
`portable/mac/markdown/SPDFMarkdownPaginator.h:38` both still say the Keep Image
Colors default is NO. It is YES.

### 3.3 The palette, with exact values

All of these are literals in `portable/mac/markdown/SPDFMarkdownTheme.mm:23-49`,
one cached immutable palette per variant, built by `SPDFRGB()` (:3-8) as
**concrete sRGB** — never a dynamic or appearance colour, per `agents.md`'s
render-determinism rule. **They are the reading theme for the whole app, not just
Markdown** — `SPDFMacDocumentViewTheme.mm:68-71` reads the same object for the
PDF canvas. Provenance: light is GitHub-Primer, dark is Obsidian-default (:10-16).
The zero-argument class accessors (`+bodyTextColor` etc., :64-87) are aliases for
the **light** palette only — that is how print and export stay light.

| Role | Light | Dark | line |
|---|---|---|---|
| paper | `#FFFFFF` | `#1E1E1E` | :23 |
| paper border | `#D0D7DE` | `#333333` | :24 |
| viewport gutter (around the sheets) | *nil* — the frontend keeps its system gutter | `#121212` | :26 |
| draws paper shadow | **YES** | **NO** | :27 |
| body text (ink) | `#1F2328` | `#DCDDDE` | :28 |
| secondary text | `#59636E` | `#999999` | :29 |
| link | `#0969DA` | `#7F6DF2` | :30 |
| inline code chip | `#EFF1F2` | `#2A2A2A` | :31 |
| code box fill / stroke | `#F6F8FA` / `#D0D7DE` | `#262626` / `#363636` | :38-39 |
| code control fill / stroke / text | `#EAEEF2` / `#D0D7DE` / `#59636E` | `#2A2A2A` / `#363636` / `#999999` | :40-42 |
| heading rule, thematic break, table grid | `#D1D9E0` | `#333333` | :43-45 |
| table header fill / zebra stripe | `#EAEEF2` / `#FAFBFC` | `#262626` / `#232323` | :46-47 |
| image placeholder fill / stroke | `#F6F8FA` / `#D1D9E0` | `#262626` / `#333333` | :48-49 |
| syntax: comment / string / number / key / markup / keyword | `#59636E` / `#0A3069` / `#0550AE` / `#953800` / `#8250DF` / `#CF222E` | `#7F848E` / `#98C379` / `#D19A66` / `#E5C07B` / `#61AFEF` / `#C678DD` | :32-37 |

The recolor endpoints are the same pair: paper `#1E1E1E`, ink `#DCDDDE`
(`spdf_recolor.h:52-53`, `spdf_recolor.c:15-20`) — so a recoloured PDF page and a
dark Markdown page are byte-identical on background and body text.

**Selection and search colours are theme-independent and hard-coded**, in both
canvases. Do not route them through the palette:

| Role | Value | Cite |
|---|---|---|
| PDF selection overlay | `calibrated(0.40, 0.62, 0.86, 0.20)` | `SPDFMacDocumentView.mm:485`, alpha at `:11` |
| Markdown selection | `NSColor.selectedTextBackgroundColor` at alpha `0.42`, square fill | `SPDFMacMarkdownPageCanvas.mm:193-197` |
| All-matches highlight | `calibrated(1.0, 0.84, 0.12, 0.38)`, rounded radius `2.0` | `SPDFMacDocumentView.mm:467-473` |
| Active match outline | stroke `calibrated(0.94, 0.03, 0.02, α)`, rect inset `−2,−2`, `lineWidth 1.2`, α fades | `SPDFMacDocumentView.mm:475-482` |

The **light gutter is not a constant**. `SPDFMacDocumentViewTheme.mm:16-41`
builds a dynamic colour: take `NSColor.windowBackgroundColor`, resolve it to sRGB
for the current appearance, and blend **8% toward black** in light, **6%** in
dark, so the document region reads as a distinct surface below the surrounding
chrome. On Windows there is no `windowBackgroundColor`; pick the equivalent
system colour and apply the same relationship rather than copying a hex.

**What Windows uses today**, all in `spdf_win_d2d.cpp`:

| Role | Windows literal | line | vs macOS |
|---|---|---|---|
| surround, light | `ColorF(0.878, 0.878, 0.886)` ≈ `#E0E0E2` | :304 | hard-coded where macOS derives it from the system colour |
| surround, dark | `ColorF(0.129, 0.129, 0.137)` ≈ `#212123` | :302 | **wrong** — the dark gutter is `#121212`, and `#212123` is *lighter* than the paper it surrounds |
| paper placeholder, light | `ColorF(1,1,1)` = `#FFFFFF` | :329 | matches |
| paper placeholder, dark | `ColorF(0.114, 0.114, 0.122)` ≈ `#1D1D1F` | :329 | **off** — should be `#1E1E1E`, and it carries a blue tint the palette does not have |
| page shade | black at **10% alpha** | :328 | see §3.4 |
| message ink | `#595A5C` light / `#BFBFC2` dark | :282 | ad hoc; the palette's secondary text is `#59636E` / `#999999` |
| message font | Segoe UI, `15.0 × dpi_scale` | :267 | |

Two of those are visible defects on any dark document. Fix them from the palette,
not by eye.

### 3.4 Page presentation: margins, gaps, shadow vs border

macOS (`portable/mac/SPDFMacDocumentView.mm`):

- `kPageMargin = 44.0`, `kPageGap = 26.0` (:9-10), both zeroed in presentation
  mode (:221-222). The margin is consumed **halved**: the horizontal side margin
  is `spdf_mac_horizontal_canvas_margin(...) / 2.0` (:250) and the vertical outer
  inset is `spdf_mac_vertical_canvas_inset(..., pageMargin / 2.0)` (:247) — i.e.
  **22 pt per side** in each axis, with the vertical inset collapsing to 0 as the
  tallest page reaches the viewport height, and the side margin collapsing within
  one margin of exact fit so a near-fit page stays centred.
- **Every page is centred on the canvas midline**, within
  `max(viewportWidth, widestPage)` (:241) — so one giant schematic among normal
  pages shares their vertical axis instead of pinning them left
  (`portable/docs/architecture.md` §4.1).
- Fit collapse is a pure function, `portable/mac/SPDFMacFitGeometry.h:25-44`:
  vertical inset = `MAX(0, MIN(decorative, (viewportH − tallestH)/2))`, and for a
  **single page** `MAX(0, (viewportH − pageH)/2)`, i.e. vertically centred;
  horizontal margin = `MAX(0, MIN(decorative, viewportW − widestW))`.
- Page origins are pixel-snapped (`spdf_mac_pixel_snapped_origin`, :254-256).
- The page underlay is filled with the theme's `paperColor` before the bitmap —
  `#FFFFFF` light, **`#1E1E1E` dark, deliberately not white**, so a fractional
  zoom cannot show a white sliver around a recoloured page
  (`SPDFMacDocumentViewTheme.mm:59-66`).
- The drop shadow is a **cached** `NSShadow`: blur radius **12.0**, offset
  **(0, −2)**, colour black at **alpha 0.28** (:405-408). Cached because
  allocating it per page per frame was measurable on the trackpad scroll path.
- Light draws that shadow; **dark draws a 1 px `paperBorderColor` (`#333333`)
  frame instead**, stroked *after* the page content on
  `NSInsetRect(pageRect, 0.5, 0.5)` with `lineWidth 1.0`, skipped in presentation
  mode (`SPDFMacDocumentViewTheme.mm:44-58, 76-83`). The comment states the
  reason: on the `#121212` gutter a black shadow is invisible, so only one page
  edge would ever read.

The Markdown canvas uses **different** numbers, which is worth knowing so you do
not "unify" them: page gap `18.0`, canvas inset `24.0`
(`SPDFMacMarkdownPageCanvas.mm:11-12`), shadow black at alpha `0.22` /
blur `4.0` / offset `(0, −1)` (`SPDFMacMarkdownPageCanvas+Decorations.mm:49-61`),
zoom range `0.10 … 5.00` against the PDF side's `0.10 … 8.00`. Markdown pages are
A4 (`595.2756 × 841.8898`) with `61.2` pt margins
(`markdown/SPDFMarkdownPaginator.mm:12-19`).

Windows (`portable/win/src/spdf_win_layout.h:126-129`,
`spdf_win_d2d.cpp:235-260`):

- `SPDF_WIN_PAGE_MARGIN_H 22.0`, `SPDF_WIN_PAGE_MARGIN_V 13.0`, content-space and
  **not** DPI-scaled. So 22 per side horizontally (matches macOS), 26 between
  pages (matches `kPageGap`), but **13 above the first page and below the last**
  where macOS uses 22. These came from GTK4, which is where the differential
  pins them; changing them means changing the differential's expectation, so
  decide whether you are matching macOS or the GTK4 original and say which.
- Page rects are snapped to whole pixels (`floorf(x + 0.5f)`, :239-241) so
  Direct2D does not resample a blit that should have been exact.
- The "shadow" is **one flat rect**, black at 10% alpha, 2 px left/right, 0 top,
  3 px bottom, ×`dpi_scale` (:243-245). There is no blur and no stroked border.
- **It is drawn in both themes.** `scene->dark` switches only the paper brush;
  the shade brush is created unconditionally at :328 and passed for every page.
  This is QC finding F15's "dark-theme page separation" item, still open, and it
  reproduces exactly the defect macOS identified and fixed.

Zoom bounds agree: `[0.10, 8.0]` on both (`spdf_win_layout.h:231-232`, matching
GTK's `spdf_fit_page_zoom`). Fit modes use no padding. A slot more than 2× the
viewport enters the crop regime (:392); the render surface is capped at 96 MB
(`SPDF_WIN_MAX_RENDER_SURFACE_BYTES`, :84).

### 3.5 Window chrome to build, with the macOS metrics

Nothing in this section exists on Windows. Every one of these is custom-drawn and
custom-hit-tested in Win32 — that cost is the honest price of the technology
choice (`windows-port-plan.md` §3, "The honest trade-off").

**The window itself** — `ShenzhenPDFMac.mm:2912-2938`. Default content size
`1120 × 800`; minimum `560 × 380` (:69-70). `titleVisibility = Hidden`,
`titlebarAppearsTransparent = YES`, `NSWindowStyleMaskFullSizeContentView`,
`movable = NO`, `movableByWindowBackground = NO` — **the tab strip lives inside
the title bar**, which is why the strip's background is `clearColor` and why it
reserves space for the traffic lights. A restored size is clamped to
`[560 … min(2200, screenW−40)] × [380 … min(1600, screenH−40)]` (:189-196). Top
to bottom: tab strip (42) → toolbar (42) → `NSSplitView` (vertical, thin divider)
filling the rest (:3292-3312).

**Tab strip** — `portable/mac/SPDFMacTabStripView.mm`, height
`kTabStripHeight = 42.0` (`ShenzhenPDFMac.mm:68`), collapsed to 0 in presentation
mode (:13634). `kTabGap = 6.0`, `kTabMinVisibleWidth = 112.0`,
`kTabMaxWidth = 320.0`, `kTabControlWidth = 32.0` (:9-12).

- Each tab rect is `y = 7`, **height 28**, width `MAX(1, MIN(320,
  floor(available / count)))` (:124-129, :213-222).
- **Leading inset for the traffic lights**: `MAX(16.0, reservedLeadingInset)`,
  where the reserve is computed live as `NSMaxX(zoomButton) + 18.0`, falling back
  to `138.0` windowed and `16.0` fullscreen (:131-133;
  `ShenzhenPDFMac.mm:7320-7332`). On Windows the analogue is the *trailing*
  inset for minimise/maximise/close — the mirror image.
- Tab body: rounded rect **radius 7**. Selected fill `controlAccentColor @0.34`,
  stroke `controlAccentColor @0.95` `lineWidth 1.4`; unselected fill
  `controlBackgroundColor`, no stroke; a missing file goes red
  (`systemRedColor @0.36 / @0.22` fill, `@0.95 / @0.65` stroke) (:543-616).
- Title: `systemFontOfSize:12`, `labelColor` when selected else
  `secondaryLabelColor`, centred, **truncating middle**, left inset `12.0`, right
  inset `34.0` (:565-604).
- Read-only dot: `systemOrangeColor`, diameter `7.0`, left inset `6.0`, `2.5` gap
  to the title (so the title's inset becomes `15.5`) (:14-18, :580-593).
- Close button: 16.0 pt circle, right edge at `maxX − 26.0`, fill
  `labelColor @0.16` selected / `secondaryLabelColor @0.13`; the X strokes at
  `lineWidth 1.35` with ±3.2 pt arms (:397-400, :600-616).
- `+` button and overflow `…` button: both `32 × 28` at `y = 7`, **radius 9**,
  `controlBackgroundColor`; `+` is `systemFontOfSize:16`, the overflow draws three
  3 pt dots with a 3 pt gap at `labelColor @0.78` and a `separatorColor @0.45`
  outline (:135-149, :651-681).
- Hit targets are forgiving: `NSInsetRect(tabRect, −6.0, −10.0)` expanded to the
  full strip height (:224-230).
- Visible-tab capacity is `floor((areaWidth + 6) / (112 + 6))`, windowed around
  the selected tab (:161-193).
- **Drag:** in-window reorder animates through `visualRectForTabAtIndex:` — the
  dragged tab follows the pointer clamped to the tab area while neighbours shift
  one slot (:519-541). Cross-window drag uses pasteboard type
  `"com.intuition.shenzhenpdf.tab"` (:23) and draws a drop indicator **2.0 pt
  wide, full tab height, `systemYellowColor`, corner radius 1.0** in the target
  gap (:684-699; geometry in `SPDFMacTabStripGeometry.h:12-34`).

Behaviour to match: drag to reorder, drag out to detach into a new window,
middle-click to close, overflow into a "…" menu, same-name disambiguation. The
Windows tab **model** already implements the close and selection policy
transcribed from `ShenzhenPDFMac.mm:9115` (adjacent neighbour for Ctrl+W) and
`:9300` (most recently active survivor for a detach) — do not re-derive it,
draw it.

**Toolbar** — `SPDFToolbarStackView`, horizontal, `alignment CenterY`,
`spacing 4.0`, `edgeInsets (7, 6, 7, 6)`, height pinned to `42.0`
(`ShenzhenPDFMac.mm:2964-2968, 3293`). Arranged left to right (:3105-3122):

1. sidebar toggle ("Side Panel")
2. OCR button (icon, width 32) · 3. translate button (icon, width 32)
4. separator (`NSBox`, width 1)
5. page field (`NSTextField`, width 50, right-aligned, `systemFontOfSize:13`)
6. page-count label (`"/ N"`)
7. **page pill** — `chevron.left` / `chevron.right`
8. fit-mode popup (width 96, `size 13 Light`; `100%`, `Fit Width`, `Fit Height`,
   `Fit Page`)
9. **zoom pill** — `minus` / `plus`
10. **markdown font-size pill** — A− / A＋, hidden outside Markdown
11. reading-theme button — **single-segment pill**, width 32, `moon.stars` in
    light, `sun.max` in dark, template-tinted
12. search field (`SPDFFindSearchField`, placeholder "Find", width 88–141)
13. regex checkbox (width 68) · 14. find count label (width 64)
15. **find pill** — previous / next match
16. flexible spacer · 17. overflow `…` (width 30) · 18. minimap toggle ("Map")

Custom spacing `8.0` after the zoom pill, the reading-theme button and the search
field. **Overflow order** when the toolbar cannot fit (:2866-2909), collapsing
group by group until it does: `[ocr, translate, separator]`, `[findCountLabel]`,
`[findSegments]`, `[findRegexCheckbox]`,
`[markdownFontSizeSegments, readingThemeButton]`, `[fitModePopup, zoomSegments]`.
Hidden items become entries on the "…" menu.

The **pills** are the visual signature. `spdf_toolbar_segments()`
(`portable/mac/SPDFMacSupport.mm:325-352`) builds every one of them identically:
`NSSegmentedControl`, `NSSegmentStyleRounded`,
`NSSegmentSwitchTrackingMomentary` (no sticky selection), content hugging and
compression resistance both `Required` so they are never squeezed, one shared
action dispatched on `selectedSegment` (0 = leading, 1 = trailing).
`spdf_paired_toolbar_segments()` makes the two-segment form and
`spdf_single_toolbar_segment()` the one-segment form — deliberately the same
factory *"so a single-segment control and a paired one share background, height
and icon tint exactly"* (:324-325). Their radius and height are **system-drawn**,
not literals: on Windows you choose them, and the thing to match is the
*relationship* — one rounded capsule, a hairline divider between segments,
momentary press feedback, and a lone button that is visibly the same object as
half of a pair.

Two toolbar controls **are** custom-drawn on macOS, so their numbers transfer
directly (`portable/mac/SPDFMacUIHelpers.mm`):

- `SPDFToolbarToggleButton` (:144-246) — intrinsic size
  `(titleWidth + 50.0, 28.0)`, title at `systemFontOfSize:12 Light`; draw bounds
  `NSInsetRect(bounds, 1.0, 2.0)`; pressed background `labelColor @0.08` at
  **radius 7.0**; switch track `32.0 × 18.0` anchored 5 pt from `maxX`, fully
  rounded, fill white `@0.94` on / `secondaryLabelColor @0.22` off, stroke
  `separatorColor @0.55` `lineWidth 1.0`; knob 14.0 diameter inset 2 pt, fill
  `calibratedWhite:0.14` on / white `@0.96` off, stroke `shadowColor @0.18`;
  disabled alpha `0.44`; fires on mouse **down**.
- `SPDFToolbarMenuButton` (:250-306) — `30.0 × 28.0`, bounds inset `(1.0, 2.0)`,
  fill `labelColor @0.06` (`@0.13` highlighted), **radius 8.0**, outline
  `separatorColor @0.30` `lineWidth 1.0`, three 3.0 pt dots with 3.0 pt gaps at
  `labelColor @0.78`.

**Sidebar** — `kDefaultSidebarWidth = 240.0`, `kMinSidebarWidth = 176.0`,
`kMaxSidebarWidth = 320.0`, `kSearchSidebarMinWidth = 216.0`, max fraction `0.34`
of the split view (`ShenzhenPDFMac.mm:72-76`, clamps at :179-187). Divider width
`5.0` (:77-78), drawn as `windowBackgroundColor` with a 1 pt `separatorColor`
line down its centre and a `resizeLeftRight` cursor
(`SPDFMacUIHelpers.mm:425-431`).

- **Default visibility: VISIBLE** (`_defaultSidebarVisibleForNewDocuments = YES`,
  :836-838; persisted as `defaultSidebarVisibleForNewDocuments`, :1456).
- Sections are an `NSSegmentedControl`: Chapters (0), Comments (1), and **Search
  (2), which appears only while a query is live** (:3138-3144, :9603-9615).
  Segment widths are normalised to
  `floor(max(minSeg, (sidebarWidth − 16) / segments))` with `minSeg` 66.0 for
  three segments, 78.0 for two.
- Below it: a filter field (`NSSearchField`, "Filter Chapters" / "Filter
  Comments", hidden and disabled in Search mode) and a headerless
  `SPDFSidebarTableView`, `rowHeight 25.0`, single column width `230.0`
  (:3149-3213). Comment rows wrap to 3 lines with `5.0` vertical padding
  (:85-86). All the 8 pt insets are at :3181-3213.

**Minimap** — `kDefaultMinimapWidth = 126.5` (:71), persisted as
`settings["minimapWidth"]`, clamped `[72, 260]` on read (:1455) and
`[72, MAX(120, MIN(320, containerWidth × 0.35))]` on drag (:9535-9537). Divider
5.0, same drawing. **Default visibility: VISIBLE** (:837-840). Background
`windowBackgroundColor` plus a 1 pt `separatorColor` line at x = 0
(`SPDFMacMinimapView.mm:741-744`).

- Strip layout (:308-343): usable width `boundsWidth − 18.0`, **inter-page gap
  4.0**, top inset `8.0` when scrolled or vertically centred when the strip fits.
- Scale comes from the **median** page width, with any single page capped at
  `kMinimapMaxWidthRatio = 2.5×` the median (:113, :139-147); each page is
  centred horizontally, aspect preserved.
- Per page: white fill, then the thumbnail at `NSImageInterpolationLow`, or a
  placeholder of grey lines `calibratedWhite:0.76 @0.34` (:524-536, :606-607).
- Current-page outline: `calibratedWhite:0.75 @0.9`, rect outset 1 pt,
  `lineWidth 1.5` — deliberately grey so it does not compete with the viewport
  box (:664-675).
- Viewport rectangle: fill `calibrated(0.18, 0.55, 0.92, 0.18)` at **radius 4**,
  stroke `controlAccentColor` `lineWidth 1.2`, clipped to
  `NSInsetRect(bounds, 1, 1)` (:776-786).
- Search markers: minimum 2 pt wide × 3 pt tall, then width doubled about the
  centre; fill `calibrated(1.0, 0.86, 0.06, 0.88)` radius 1.5, stroke
  `calibrated(0.88, 0.08, 0.03, 0.96)` `lineWidth 1.1` (:557-578).
- Drag is 1:1 below `16000.0` pt of document height, then switches to
  `180.0` / `300.0` fine/full speeds (:12-15). Wheel is `32.0` points per line
  (:28), matching `kSPDFMouseWheelPointsPerLine` (`SPDFMacUIHelpers.mm:567`).
- The Markdown minimap is the *same view*, fed page proxies through
  `SPDFMacMarkdownMinimapModel`.

**Find** — the toolbar search field, plus:

- counter label, width 64, centred, `monospacedDigitSystemFontOfSize:12`,
  `secondaryLabelColor`; text is `""` with no query, `"..."` while searching,
  `"0 / 0"` on no match, else `"%ld / %ld"` (`ShenzhenPDFMac.mm:3081-3086,
  10631-10652`). The counter and the prev/next pill are hidden whenever the query
  is empty.
- **Scrollbar heat-map** — `SPDFFindMarkerScroller`, an `NSScroller` subclass
  used as the vertical scroller of both the PDF scroll view (:3225-3227) and the
  Markdown paged view. Drawing at `SPDFMacUIHelpers.mm:453-479`: track inset 2 pt
  top and bottom, marker x `slotMinX + 2.0`, width `MAX(2.0, slotWidth − 4.0)`;
  the **active** match is `calibrated(1.0, 0.38, 0.08, 0.95)` and **2 pt** tall,
  the others `calibrated(1.0, 0.86, 0.12, 0.82)` and **1 pt** tall; markers
  closer than 1.5 pt to the previous one are dropped. `autohidesScrollers = NO`
  on both scroll views so the trough is always visible.

The find *behaviour* is already toolkit-free in
`portable/linux/gtk4/spdf_search_internal.h` (15 `static inline` functions,
including the heat-map ticks) — port that header the way `spdf_win_layout.h`
ported `spdf_docview_internal.h`, and differentially test it the same way.

**The reuse rule for all of the above:** `portable/docs/windows-port-plan.md`
§2.3 measured **40 files / 5,432 LOC in `portable/linux/gtk4/` that contain zero
`gtk_`/`gdk_`/`cairo_`/`pango_` references**, of which 3,873 LOC are 83
`static inline` functions in five `*_internal.h` headers: docview (layout, fit,
zoom anchoring, clamp, cap, LRU, cursor regions), minimap (strip geometry,
thumbnail budget, viewport indicator, hit markers), search, sidebar, props. On
the macOS side the equivalents are `SPDFMacPaletteResults.mm`,
`SPDFMacFindNearest.mm`, `SPDFMacTabStripGeometry.mm`, `SPDFMacCursorRegions.mm`,
`SPDFMacPropertiesFormat.mm`. **Win32 must supply painting and hit-testing, not
re-derived behaviour.** Re-deriving it would mean re-deriving its bug fixes too.

One duplication to mirror carefully: `kPageMargin 44.0` / `kPageGap 26.0` are
declared **three times independently** —
`portable/mac/SPDFMacDocumentView.mm:9-10`,
`portable/mac/SPDFMacMinimapView.mm:7-8` and `ShenzhenPDFMac.mm:64-65` — and the
minimap's fallback document-rect maths (`SPDFMacMinimapView.mm:218-236`) depends
on them agreeing with the document view's. On Windows, define them once.

### 3.6 Chrome input policy, and what Windows has no counterpart for

`portable/mac/SPDFMacWindowChrome.{h,mm}` holds **no geometry** — it is pure input
policy, and it is being actively edited right now, so read it rather than this
summary. The rules as they stand, all worth reproducing:

- Single click on the title-bar area ⇒ window drag; double click ⇒ zoom, unless
  fullscreen or presentation (`SPDFMacWindowChrome.mm:6-18`).
- A click on any `NSControl` / `NSText` descendant is **never** a title-bar drag
  or zoom, unless the view opts back in by overriding `mouseDownCanMoveWindow`
  (:20-35). This is what lets the tab strip and the toolbar live inside the
  title bar without eating clicks.
- **Any click inside the window focuses it**, including clicks on the tab strip —
  selecting a tab, hitting its close box, middle-clicking to close — so a
  pinch or Ctrl+scroll zoom works immediately afterwards instead of needing a
  separate click in the page (`ad8f1c857`, `19cb2f6a8`, and
  `portable/docs/release-notes-next.md`).
- A wheel is a zoom only while Cmd or Ctrl is held **and the scroll is still
  actively scrolling** — a modifier pressed during inertial coast must not turn a
  coasting scroll into a zoom (`spdf_scroll_is_zoom_wheel`). Windows has no
  momentum phase on a mouse wheel, but it does on a precision touchpad.

Windows-side chrome with nothing to copy from macOS — do not skip these:

- The **OS title bar is not themed**. There is no
  `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` anywhere, so even with
  `--dark` the frame stays light against a dark canvas. macOS gets this from the
  system appearance for free.
- The window has **no icon, no taskbar identity, no file association**.
- There are **no scrollbars**. macOS shows native ones and overlays the search
  heat-map on them.

---

## 4. What is deliberately NOT 1:1 — do not "fix" these

**Markdown pagination cannot match macOS, and chasing it would sink the port.**
`portable/mac/markdown/SPDFMarkdownPaginator.mm:359-394` builds an
`NSTextStorage` / `NSLayoutManager` / `NSTextContainer` and calls
`enumerateLineFragmentsForGlyphRange:`. Per `portable/mac/markdown/README.md:28-45`
the resulting attributed string is **the only user-visible coordinate space** —
search matches, heading ranges, selection and pagination are all ranges into it.
DirectWrite will not reproduce TextKit's fragment boundaries. Every guarantee in
that README still holds on Windows because consumers index into the
*Windows-produced* string.

> **Parity for Markdown means: same content, same styling, same feature set,
> internally consistent coordinates — not the same page breaks.** This is a
> product decision already taken (`windows-port-plan.md` §3), not a discovery for
> you to make. Markdown is out of scope for Phases 1–7 regardless.

Also settled, and not to be relitigated:

- **Save panels stay native.** Picking a file has to hand the selection back to
  the app; no external file manager can. macOS uses the standard panel for
  Open…, the path prompt and every save; Windows uses `IFileOpenDialog` /
  `IFileSaveDialog`.
- **Print, Save as PDF, Copy Page and Copy Page Image always render the LIGHT
  theme**, even while the user is reading in dark. `SPDF_RENDER_DARK_THEME` is
  opt-in per render precisely so these get the document's own colours by doing
  nothing (`shenzhen_pdf_core.h:161-168`). A file that left the app with our dark
  paper baked in would be wrong everywhere it lands.
- **Copying is always allowed.** `spdf_has_permission(doc, 'c')` returns 1
  unconditionally, by product decision, with the reasoning at
  `shenzhen_pdf_core.h:209-214`: the PDF copy flag is an advisory request to the
  viewer, the document is already decrypted and on screen, general-purpose
  extractors ignore it, and honouring it only stopped a reader quoting a document
  they are looking at. Print, edit and annotate still answer the document's own
  flags. **Do not add a copy gate to the Windows frontend.**
- **Keyboard model:** Cmd → Ctrl, the same convention the GTK4 frontend uses.
- **Rendered colours are concrete sRGB constants, never appearance-dynamic**, so
  screen, print and export always produce the same page (`agents.md`).

---

## 5. The rules that still bind you

From `agents.md` and `tools/file-size-limits.md`. These are repo rules, not
macOS rules.

**The file-size ratchet.** `tools/check-file-sizes.sh` must exit 0; it currently
reports *865 maintained source files, 113 exact caps*. Maintained first-party
source defaults to **500 lines**. A cohesive 501–1000 line file needs an exact
`exception` entry in `tools/file-size-limits.tsv` with a concrete justification.
Files already over 1000 lines have exact `legacy` caps — they may shrink but
**may not grow**, and after a reduction you lower the cap in the same change.
`portable/mac/ShenzhenPDFMac.mm` is pinned at **16862** and
`portable/core/shenzhen_pdf_core.c` at **3381**; both are frozen pending
subsystem extraction. **Prefer extracting a focused file over raising a cap** —
that is how `spdf_win_render.c` (732 lines) and `spdf_win_canvas` were handled,
and why `spdf_win_headless.h` exists at all (§6 of that story is in `12cd51c5c`).

**Judge results by exit code, never by piping into `grep`.**
`run-tests.sh | grep -c passed` reports *grep's* status, so a failed compile looks
green. Redirect to a file and check `$?`.

**Keep the render path deterministic and explicit.** Theme variants, render
options and page configurations are threaded through as parameters, never read
from ambient app state deep inside rendering.

**Speed is a standing requirement.** A feature must cost nothing for documents
that do not use it, and nothing new may run on the launch path. Prove laziness
with a test rather than asserting it. (`readme.md` leads with "Launches
instantly"; `portable/docs/launch-performance-strategy.md` treats one extra
dynamic library as measurable damage.)

**Commit each meaningful, tested change set. Do not commit half-finished work.
Do not push without being asked.**

**Git hygiene, learned the expensive way.** Risk 7 in the port plan materialised
as a *git* collision: two tracks used `git add -A` and silently reverted another
track's work. **`git add -- <your own paths>`, then check `git status`.**

**Do not launch the macOS app.** Irrelevant where you are, but the discipline
behind it is not: the user has this software open while you work, and
interrupting them is the thing the rule exists to prevent. On Windows the
equivalent is: do not leave stray `ShenzhenPDF.exe` processes, message boxes or
maximised windows behind.

**The one architectural rule that must not be broken:**
`spdf_win_paint(ID2D1RenderTarget*, ...)` must **never require an `HWND`**. The
window's `WM_PAINT` and the headless probe call the same compose path
(`spdf_win_d2d.h`, first paragraph). If painting ever needs a window, every pixel
test in the port dies with it. `spdf_win_render_scene_to_png`
(`spdf_win_d2d.cpp:373-385`) creates a `D2D1_RENDER_TARGET_TYPE_SOFTWARE` WIC
target — SOFTWARE, not DEFAULT, explicitly because the SYSTEM session may have no
display adapter. Keep that too; you have a desktop now, but the Mac-side harness
does not.

---

## 6. Traps, each with its evidence

The numbered list lives in `portable/win/README.md` "Gotchas" (1–9) and
"Gotchas (in addition to 1–9 above)" (10–20). **Add to that list, not to this
file.** The ones that will still bite you natively:

**`%ERRORLEVEL%` in an `&` chain expands at PARSE time.** The whole line is
parsed before any of it runs. `cmd /c exit 42 & echo INLINE=%ERRORLEVEL%` prints
`INLINE=0`. Use `if errorlevel N`, which is evaluated at runtime. (Gotcha 3.)

**`if COND cmd & other` runs `other` unconditionally** — cmd parses `&` as a
sibling command, not part of the `if` body. So
`if errorlevel 8 echo failed & exit /b 90` exits 90 on *every* run. Every
conditional in `guest-build.cmd` is a parenthesised block for this reason.
(Gotcha 4.)

**robocopy's exit code is a bit field; success is `< 8`.** 0 = nothing to do,
1 = files copied, 2 = extras, 3 = both. `if errorlevel 1` would fail every build
that actually copied something. (Gotcha 5.) And **`robocopy /MIR` will delete
build output living under its destination** — `C:\spdf-build` is deliberately a
sibling of `C:\spdf`, never a child. (Gotcha 14.)

**`vcvarsall.bat` sets nothing inside a `prlctl &` chain.** It prints *"The
system cannot find the path specified"* and `cl` is then "not recognized"; inside
a real `.cmd` file it works normally. That is why `guest-build.cmd` and
`guest-info.cmd` are script files rather than one-liners. (Gotcha 6.) Natively
this becomes the ordinary rule: run `vcvarsall.bat arm64` in a shell that
persists, and remember CMake and Ninja are only on `PATH` afterwards.

**The guest ANSI code page is 1252, not UTF-8.** Windows narrows the real UTF-16
command line to the ACP on the way into `char** argv`, and `fopen` widens it back
the same way. Measured for a directory named with an e-acute:
`… 2D E9 64 69 72 …` — `E9`, not `C3 A9`. CP1252-representable names round-trip;
Greek, Cyrillic, CJK and most emoji do not. `CreateFileW` works where narrow
`fopen` fails. This is why the port calls `*W` APIs exclusively and why
`spdf_win_main.cpp:356` uses `CommandLineToArgvW`. It is also how a real failure
in this port was first **mis-diagnosed** — the harness handed the guest a UTF-8
path, got a file that did not exist, and blamed the code under test.
(Gotcha 20; `harness.non-ascii-path` reports the observed bytes rather than
pinning them, because the code page is a property of the machine.)

**`rename()` cannot replace an existing file on Windows.** Every state rewrite
after the first one overwrites an existing file, and saving an edited PDF does
too — so this is a *silent correctness bug*, not a compile error. The fix is
`MoveFileExW(..., MOVEFILE_REPLACE_EXISTING)`, wrapped as
`spdf_compat_replace_file` (`portable/core/spdf_win_compat.c`; users at
`spdf_yaml.c:1098` and the core save paths). Risks 3 and 4 of the port plan.

**`PATH_MAX` is undefined under MSVC and `_MAX_PATH` is the legacy 260.**
`spdf_win_compat.h:66-69` defines `SPDF_COMPAT_PATH_MAX 1024` to match the core's
own buffers. Note the open finding: the compat shim does **not** apply a `\\?\`
prefix, while `spdf_win_paths.c` builds extended-length paths for everything it
touches — so the core can compose paths Win32 rejects at 260 without
`LongPathsEnabled`.

**`strdup` warns C4996 and is NOT covered by `_CRT_SECURE_NO_WARNINGS`** — that
macro only silences the `*_s` replacements. The UCRT spelling is `_strdup`;
`spdf_compat_strdup` wraps it (`spdf_win_compat.c:276-281`).

**`clock_gettime`/`CLOCK_MONOTONIC` are absent from the MSVC UCRT.**
`QueryPerformanceCounter` is the documented monotonic source
(`spdf_win_compat.c:350-359`). This is what would have stopped
`portable/core/tests/SPDFRecolorProbe.c` compiling as-is.

**`-ffp-contract=off` on the macOS side is load-bearing, not a workaround.**
clang contracts `a*b + c` into a single fused multiply-add — one rounding step
instead of two — while MSVC under `/fp:precise` does not fuse. Same IEEE-754
arithmetic, same ARM64 hardware, different last bit, and a golden-image
comparison pinned at zero tolerance goes red.
`portable/win/tests/t3-verify.sh:41-47` builds the macOS side with it for exactly
this reason. **Do not remove it to "match the release flags"** — the release
flags are not being compared to anything. (Gotcha 19.)

**The core render path writes a literal 255 into every alpha byte** unless the
source pixmap carries alpha: `shenzhen_pdf_core.c:579` is
`opx[3] = alpha ? px[comps - 1] : 255;`. So an ordinary PDF render is fully
opaque, `alpha_min == alpha_max == 255`, and **premultiplying it is the identity
transform**. That is why `compare_png.py`'s premultiplied-alpha and
transparent-halo detectors — the pair aimed at a bug this repo has already
shipped once — could not fire on any real comparison, however broken the render
was. `tests/fixtures/alpha.pdf` and the probe's `alpha` mode exist solely to give
them something to detect (QC F8). If you touch the RGBA→BGRA conversion or the
premultiply in `spdf_win_d2d.cpp:166-187`, the alpha fixture is the test that
catches you.

**MSVC dies on large string literals, not large arrays** (`C1060: out of heap
space`), memory-driven so it depends on `-j`; **`\"` in a response file must stay
escaped**; **ninja here does not put a shell between itself and the command**, so
a trailing `>nul` arrives as an extra `argv` entry; **escape `:` in ninja paths**
(`C$:/spdf/...`); **`ninja -k 0` always**, or a 646-edge build reports one broken
file per round trip. (Gotchas 10–16.) Also: **the guest has no `head`, `grep`,
`sed`, `git` or `timeout`** — `findstr` is the substitute and it sets errorlevel
1 on no-match. (Gotchas 8, 17.)

**`rsync --delete` protects already-excluded files**, so changing an exclude
leaves 190 MB of `mupdf/generated/` in the staging tree forever;
`--delete-excluded` is required. (Gotcha 13. Mac-side, but it is the class of bug
that reappears in any mirror you write.)

---

## 7. What to do first, in order

**1. Build it, run it, look at it, and screenshot it beside the macOS app.**
This is the whole reason you exist on this machine. Open a real PDF windowed and
again with `--dark`, resize it, move it between displays if you have two, close
it. Then put your screenshot next to `docs/images/portable/macos-main-window.webp`
and write down every difference. Phase 1's stated done-bar — *the window opens,
the page is visible and correctly scaled to the client area, resizing repaints,
DPI scaling is correct on a 2× display, closing exits 0* — has five criteria and
**all five are still unobserved**. Close that first; it costs minutes and it is
the only item on this list that nobody else could ever do.

**2. Write down what you saw, in this file or a sibling, before fixing anything.**
Every previous document in this port was written by someone who could not see the
thing they were describing. Your observations are new evidence and they are worth
more than another round of code reading. If the window does *not* open, that is
the most valuable bug report in the project's history — capture the exact failure.

**3. Write a native build script.** Ten hand-listed translation units at every
call site is a tax on every subsequent step, and `portable/core/spdf_win_compat.c`
being omitted from one of them is a wall of `LNK2019` waiting to happen. CMake +
Ninja, sources discovered from `portable/win/src`, `portable/core` listed
explicitly.

**4. Get the tests running natively.** The 8 `win.*` suites and the 3 core
suites first — they are plain console binaries and they are your regression net
for everything below. Then decide what happens to the cross-host PNG cases
(§2.6). Then register the five unwired core suites: near-free conformance the
plan called out on day one and nobody has claimed.

**5. Fix the visual defects §3 already names**, because they are cheap, certain,
and each one is visible in your own screenshot:
   a. dark surround `#212123` → the palette's `#121212` gutter;
   b. dark paper placeholder `#1D1D1F` → `#1E1E1E`;
   c. the 10%-black shade rect drawn in dark → a 1 px `#333333` border, as
      `SPDFMacDocumentViewTheme.mm:44-58` does and explains;
   d. `SetWindowTextW` on tab switch, so the title stops lying;
   e. `DWMWA_USE_IMMERSIVE_DARK_MODE` on the frame in dark.

**6. Draw the tab strip.** The model is finished and tested; it is invisible.
This is the largest visible gap between the two apps and the one with the least
new logic behind it — 42 pt tall, `kTabGap 6`, `kTabMinVisibleWidth 112`,
`kTabMaxWidth 320`, close box `32`, read-only dot `7`.

**7. Draw the toolbar**, pills first (§3.5). Page field, page pill, fit-mode
popup, zoom pill get the app to "recognisably the same program" faster than
anything else on the list.

**8. Then Phase 5**: find, sidebar, minimap — porting
`spdf_search_internal.h`, `spdf_sidebar_internal.h`, `spdf_minimap_internal.h`
the way `spdf_win_layout.h` was ported, each with a differential test against the
GTK4 original. That pattern caught a one-ulp transcription error; it will catch
yours.

**A caution on estimates.** Phases 1–3 landed in about half their budget, and
`windows-port-plan.md` §1 explains at length why that **does not extrapolate**:
those phases were the parallelizable, headless-testable, pure-function third,
with GTK4 originals to diff against. What remains is chrome — shared-state,
single-window, painting and hit-testing written fresh, and until now unverifiable.
The plan's standing numbers are 3.5–6 multi-agent days to GTK4-level parity and a
further 4–8 for Markdown. Your ability to *see* the app removes the verification
debt, which is a real speedup; it does not remove the drawing.

---

## 8. Open items you inherit

**QC findings.** `portable/docs/windows-port-qc.md` §0 carries the status table.
F1–F14 are fixed (F3 by `833e0d527`, which added the four permanent
`d2d.*` comparison cases). **F15 is mostly open**, re-checked against HEAD:

| item | status at HEAD |
|---|---|
| `spdf_yaml.c` inverted `snprintf` guard | **FIXED** (`3b4ff3908`) — now `spdf_compat_snprintf_ok(...)`, which handles the negative return |
| `spdf_compat_widen` accepts malformed UTF-8 | **OPEN** — still no `MB_ERR_INVALID_CHARS`, while `spdf_win_paths.h:22-27` goes to real trouble to reject exactly this. The two files disagree about the same class of path |
| five narrow `remove(temp_path)` in the core save paths | **OPEN** — `shenzhen_pdf_core.c:2394, 2403, 2437, 2478, 2487`, return values ignored, on user document paths, at the moment a save has just failed. `spdf_compat_unlink` exists and `spdf_yaml.c` uses it |
| `spdf_win_probe.c` uses narrow `main(int, char**)` | **OPEN** (`:225`) — the port's own conformance oracle cannot be pointed at a non-CP1252 path |
| no `\\?\` prefix in `spdf_win_compat.c` | **OPEN** |
| no `FOLDERID_LocalAppData` anywhere | **OPEN** — macOS separates state from cache; whatever cache lands next will go into `%APPDATA%` and roam with the profile on a domain network |
| `session.lock` declared and never taken | **FIXED** (`8846deecb`) — `spdf_win_session.cpp:232` acquires it for the cross-process merge |
| dark-theme page separation draws a black shadow in both themes | **OPEN** — `spdf_win_d2d.cpp:328` creates the shade brush unconditionally. See §3.4 and §7.5c |
| 96 MB render cap not applied on `--render-png` | **FIXED** (`12cd51c5c`) — the cap now applies on the canvas path (`spdf_win_canvas.cpp:306`), the prefetch path (`spdf_win_canvas_prefetch.cpp:77`) and the single-page PNG path (`spdf_win_headless.h:27-33`). Measured: zoom 30 on a 200×260 pt page asked for 6000×7800 (187 MB) and now yields 4400×5720, exactly 96 MiB |

**Windows gaps not filed as findings**, found while writing this:

- `fit_mode` is **lossy on save** — `spdf_win_tabs_app.h:59-60` collapses every
  mode to fit-width or custom, so fit-page does not round-trip a restart.
- Window geometry is **never written** to `session.yaml`; an existing on-disk
  `frame` is carried through verbatim so a mac user's geometry survives
  (`spdf_win_session.cpp:204-209`).
- `spdf_win_state_migrate` (the one-time JSON→YAML migration) exists and is
  **never called from `main()`** (`spdf_win_state.c:401`).
- The session is written **only at process exit** — no periodic or coalesced
  writer, so a crash loses the session.
- The vertical outer margin disagrees with macOS: 13 vs 22 (§3.4).

**Cross-platform items that are not yours but are near you:**

- The **GTK frontend still has a dead copy gate**:
  `portable/linux/gtk4/spdf_window.c:747` reads
  `if (!tab || !tab->doc || !spdf_has_permission(tab->doc, 'c')) return;` even
  though `spdf_has_permission(_, 'c')` now always returns 1. Its source test
  **pins the gate's existence** —
  `portable/linux/gtk4/tests/password_source_test.sh:47` greps for that exact
  line — so removing it means changing the test in the same commit. This is the
  deliberate mirror of the macOS cleanup (`41db80ed6`), left in place on purpose.
  Do not remove it as a drive-by.
- The Linux frontend has **no dark reading theme at all**: `SPDF_RENDER_DARK_THEME`,
  `SPDF_RENDER_PRESERVE_IMAGES` and `spdf_recolor` appear zero times in
  `portable/linux/gtk4/`. Windows gets it for one render flag over code already
  proven bit-identical there, so the app's headline feature can ship on Windows
  before Linux.

---

## 9. The documents, and how far to trust each

| file | what it is | reliability |
|---|---|---|
| `portable/win/README.md` | toolchain, scripts, harness, MuPDF, **gotchas 1–20** | the most operationally useful file here. Reconciled against the tree at 06:45 on 08-31; its case count says 20, the suite is now 27 |
| `portable/docs/windows-port-plan.md` | phased plan, scoping, layer map, risks with a scorecard | honest and unusually good on *why*. §0 and §4's phase annotations are current; §5's hour-by-hour timeline is historical |
| `portable/docs/windows-port-qc.md` | adversarial audit, F1–F15 | trust §0's status table over the body text, which describes each defect **as it was found**. §8 above re-checks F15 against HEAD |
| `portable/docs/architecture.md` | the macOS rendering pipeline, view, scroll, zoom, minimap | the reference for *behaviour* you are matching |
| `portable/docs/gtk4-parity-spec.md` / `-journal.md` | the same exercise, done once already on Linux | the best available calibration for what a frontend port actually costs |
| `agents.md`, `portable/README.md`, `tools/file-size-limits.md` | the repo's own rules | binding; see §5 |
| `readme.md` | what the product ships, in the user's language | the closest thing to a visual spec in prose |

One risk the plan did not list and should have, quoted because it applies to
this file too: **the documentation drifted out of sync with the tree faster than
anyone could read it.** Agents that could not see each other left this repo
asserting things a later chapter of the same file disproved. When a document and
the tree disagree, **the tree wins** — and fix the document in the same commit.

### Corrections made while writing this

Small, but recorded so they are not copied forward again:

- The reading-theme hex values live in
  `portable/mac/markdown/SPDFMarkdownTheme.mm:23-49`, **not** in
  `SPDFMarkdownDecorations.h` — that header only declares the properties (its
  `viewportBackgroundColor` line carries the comment `// nil / #121212`).
- The 96 MB render-cap fix (`12cd51c5c`) applies to the **Windows** paths
  (`--render-png` joining the canvas and prefetch paths), not to macOS.
- `run-tests.sh` is **27 cases**, not the 20 that `portable/win/README.md` and
  `windows-port-plan.md` §0 still state; the extra seven are
  `layout.differential` (`ec06609cb`), the four `d2d.*` cases (`833e0d527`) and
  `win.tabs_test` / `win.session_test` (`8846deecb`).
- `ShenzhenPDFMac.mm` is **16862** lines at HEAD (the cap in
  `tools/file-size-limits.tsv:37`), not the 16882 quoted in
  `windows-port-plan.md` §1 and in `f27d28f6f`'s message — 20 lines came out with
  the copy-permission gates in `41db80ed6`.
- The unregistered core suites are **five**, not the four both
  `windows-port-qc.md` §6.3 and `portable/win/README.md` say while listing five.
- `session.lock` and the `--render-png` byte cap are listed as open in
  `windows-port-qc.md` §0; both were fixed after that table was written
  (`8846deecb`, `12cd51c5c`). §8 above is the current status.
- Two comments in the Markdown subsystem still state that "Keep Image Colors in
  Dark Theme" defaults to NO (`portable/mac/SPDFMacMarkdownSession.h:34`,
  `portable/mac/markdown/SPDFMarkdownPaginator.h:38`). It has defaulted to YES
  since `f27d28f6f`.
