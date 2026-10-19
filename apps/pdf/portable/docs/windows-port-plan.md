# Windows Port — Scope, Architecture & Phased Plan

Date: 2026-08-31. Branch: `master`. Host: macOS/arm64, guest: Windows 11 ARM64
in Parallels. Companion to `gtk4-parity-spec.md`, which is the precedent for
this kind of port and the source of most of the effort calibration below.

Every number here was measured against the tree at HEAD. Paths are repo-relative.

---

## 0. Status as of 2026-08-31 06:45 — read this first

This plan was written at 03:22, before any Windows code existed. Sections 1–3
and 5–8 are the *original scoping* and have held up well; they are left as
written except where a specific number turned out wrong. **Section 4's phase
status has been rewritten against what actually landed**, and §1's effort table
now carries a revised estimate.

| Phase | Planned | Actual |
|---|---|---|
| **0** Toolchain | in flight | **complete** — MuPDF 1.27.2 native ARM64, 646 objects, all `AA64` |
| **1** Window + real page | the 7-hour target | **complete at the core-and-pixels layer; unproven at the window layer** (see below) |
| **2** Continuous canvas | "substantially complete" | **complete**, differentially tested against the GTK4 original |
| **3** Worker render pipeline | "begun" | **complete** — pool, coalescing, cancellation, byte-capped LRU, prefetch |
| **4** Shell: tabs, state, multi-window | later | **state layer complete; tabs/session in flight** |
| **5–8** | later | not started |

**Elapsed: 3h14m** (first commit `aa07138b3` 03:22, last `2bff74d7c` 06:36),
against a 7-hour budget. Phases 1–3 came in at roughly half the planned time.
§1's revised estimate explains at length why that speedup **does not
extrapolate** to what remains.

### The caveat that outranks everything else in this document

> **Nobody has seen a window open.**

Phase 1's stated done-bar is *"the window opens, the page is visible and
correctly scaled to the client area, resizing repaints, DPI scaling is correct
on a 2× display, and closing exits 0."* All five criteria are interactive.
`prlctl exec` runs in the SYSTEM session, which has no interactive desktop —
this plan's own risk 9 predicted it. So Phase 1 is marked complete on a
**generous reading**: the core renders byte-identically, the Direct2D compose
path produces correct pixels headlessly, and the fit geometry is verified
numerically — but *the window itself* has never been observed by anyone, in any
session. Not opening, not repainting, not closing.

QC's verdict, which must survive into every future revision of this file:
**complete at the core-and-pixels layer, unproven at the window layer, and
unprovable from here.** Closing it needs a human at the VM's GUI or an
interactive-session automation route that does not exist yet. It is the single
most important limitation of this whole effort, and it applies to Phases 2, 3
and 4 exactly as much as to Phase 1 — every one of them is verified by exit
code and pixel comparison, never by use.

### Verification state

- `portable/win/tests/run-tests.sh` → **20 cases, 0 failed, 0 blocked, exit 0**
  (~50 s). Inventory in `portable/win/README.md`.
- `portable/win/tests/qc/probe-staleness-check.sh` → **exit 0**, both defects fixed.
- `tools/check-file-sizes.sh` → **green** (112 exact caps; the maintained-file
  count moves as tracks land files, so it is not pinned here).
- QC findings F1–F14: **twelve fixed, F3 and parts of F15 still open.** See
  `windows-port-qc.md` for per-finding status and fixing commits.
- Hard-won environment knowledge lives in **one** place: the numbered gotchas
  1–20 in `portable/win/README.md`. Add to that list, not to this file.

---

## 1. Scope verdict

### What "1:1 with macOS" actually means

The macOS frontend is **~30,700 lines of production AppKit** outside Markdown,
plus **~18,100 lines of Markdown subsystem** (`portable/mac/markdown/` at 11,528
LOC over 64 files, and `portable/mac/SPDFMacMarkdown*` at 6,555 LOC). More than
half of the non-Markdown total is a single file: `portable/mac/ShenzhenPDFMac.mm`
is **16,882 lines**, one `ShenzhenMacDelegate` implementation running from line
595 to EOF, and it is where OCR, translation, the command palette, presentation
mode, the sidebar, find, session restore and the permissions wizard all live as
method blocks rather than as files you can port one at a time.

Under that sits `portable/core/` — 5,980 LOC, 349-line header, ~54 exported
functions, no platform types. The mac app binds **48 of them** and only **7
non-Markdown mac files include a core header at all**. The boundary is genuinely
narrow and genuinely portable. The port cost is not the core. It is the
frontend rewrite, and the frontend rewrite is nearly all of the work.

### The calibration that matters

`portable/docs/gtk4-parity-journal.md` records exactly this exercise, done once
already. Reaching near-parity on Linux took:

- a **two-day autonomous session** using **five waves of parallel worktree
  agents** (journal lines 3–10),
- producing 24 modules / ~26,200 LOC production + 26 test suites,
- while **porting from an existing GTK3 frontend** — the Linux semantics had
  already been derived once,
- and it still needed follow-up sessions on 07-22 and 07-23 (journal §§
  "follow-up session", "2026-07-23 session") to close shell chrome and sidebar
  gaps,
- and it is *still* missing eight macOS features, including the dark reading
  theme (`SPDF_RENDER_DARK_THEME` and `spdf_recolor` appear **zero times**
  anywhere in `portable/linux/gtk4/`) and the entire Markdown subsystem.

Windows starts from a worse position than Linux did: no predecessor frontend to
port semantics from, a build and test chain being constructed in the same
session, MSVC/ARM64 instead of a mature `gcc`/`pkg-config` ecosystem, and a
toolkit (Win32) that hands you far less for free than GTK4 + libadwaita did.

### The honest numbers

| Target | Estimated 03:22 | **Actual / revised 06:45** |
|---|---|---|
| **Phase 1** — a window that opens a real PDF and renders a real page | 2–3 h | ~1.5 h to headless pixels; **window layer still unverified** |
| **Phase 2** — continuous scrolling canvas with the shipping geometry | 3–5 h | ~1 h |
| **Phase 3** — worker render pipeline | (unbudgeted in this push) | ~0.5 h |
| **This push** — Phases 1–3 complete, Phase 4 begun | 7 h, 6 parallel agents | **3h14m, ~7 tracks** |
| Parity with the **GTK4** frontend (everything except Markdown and the 8 GTK4 gaps) | 4–6 multi-agent days | **3.5–6 days** — see below |
| True **1:1 with macOS**, Markdown included | a further 4–8 days | **unchanged: 4–8 days** |
| Verifying the **window layer** at all | not budgeted | **not costed; needs a human or new infrastructure** |

### The revised estimate, and why the observed 2× speedup does not extrapolate

Measured output of this push: **5,021 LOC** of Windows frontend production code,
**3,072 LOC** of test C, **2,468 LOC** of harness shell/Python, **1,799 LOC** of
build plumbing, plus the `portable/core` POSIX shim — about **12,900 lines in
3h14m** across roughly seven parallel tracks.

That is genuinely fast, and it is tempting to halve every remaining number. That
would be wrong, for four reasons that are specific rather than superstitious:

**1. About a third of what was built does not need building again.** The harness,
the MuPDF ARM64 build, the sync/robocopy chain, the exit-code contract and the
PNG comparator — roughly 4,300 LOC — are one-time infrastructure. Their cost is
already paid, which *is* a real and permanent speedup for what follows. This is
the one factor pushing the estimate down, and it is why the low end moves from 4
days to 3.5.

**2. Phases 1–3 were selected to be the parallelizable, headless-testable
part.** That was deliberate and correct (§5's dependency argument), but it means
the observed velocity is a measurement of the *easiest* third, not of the
average. Layout maths, an LRU and a thread pool are pure functions with
pre-existing GTK4 originals to diff against; six agents can work on them without
touching each other's files.

**3. What remains is chrome, and chrome is the opposite on every axis.** §2.4's
~1,300 widget/menu/dialog call sites are shared-state, single-window, and each
one needs painting *and* hit-testing written fresh because Win32 supplies
neither. Tab strips, sidebars, the command palette, find, print panels and file
dialogs contend for the same window and message pump — they parallelize badly,
which is exactly what the Phase 4 track is now discovering.

**4. None of it can be verified the way Phases 1–3 were.** A pure function is
diffed against its GTK4 twin; a byte-identical PNG settles a renderer. A tab
strip that responds to a drag has no equivalent oracle in a SYSTEM session. Every
chrome phase therefore carries verification debt that Phases 1–3 did not, and
that debt is currently *unpriced* because no one has costed the interactive
route.

**Net: GTK4-parity moves from 4–6 days to 3.5–6 days** — the low end pulled in
by the one-time infrastructure win, the high end held because the remaining work
is the part that resists parallelism. **Markdown stays at 4–8 days**; nothing in
this push made it cheaper, and §3's line-breaking parity trap is untouched.

And one line item the original table simply lacked: **verifying the window layer
is not on this schedule at all.** It is not hard work, but it cannot be done by
an agent in this environment, so it must be scheduled against a human.

**So: seven hours does not produce a 1:1 port, and no plan that claims otherwise
is honest.** What seven hours produces is a real, running, native Windows
ShenzhenPDF that opens a PDF you hand it, renders pages through the shipping
core, scrolls and zooms using the same geometry the Linux frontend ships, and is
verified headlessly from macOS by exit code and by pixel comparison against the
macOS renderer. That is the foundation everything else is built on, and it is
worth far more than a wider layer of scaffolding.

**Do not reuse `src/`.** The inherited SumatraPDF Win32 tree is 352 files /
140,727 LOC and contains **zero** references to `shenzhen_pdf_core` or any
`spdf_` symbol. It is a different application with a different document engine.
It is not a shortcut.

---

## 2. Layer map

### 2.1 Reused as-is from `portable/core`

`portable/core/shenzhen_pdf_core.h` is already platform-neutral: UTF-8 `const
char*` paths in, `spdf_bitmap` (width/height/stride/RGBA) out. No Win32, AppKit
or GTK types. Critically, the core contains **no threading primitives at all** —
`grep` for `pthread`, `dispatch`, `<thread>` across `portable/core/*.c` returns
nothing. Concurrency is entirely the frontend's business, under the contract at
`portable/core/shenzhen_pdf_core.c:40-43`: one `spdf_document` per thread, no
locking inside.

Reused unchanged:

- `spdf_recolor.c` (262 LOC) — includes only `<string.h>`. Already **proven
  byte-identical** between macOS/clang/arm64 and Windows/MSVC/ARM64 by
  `portable/win/verify.sh` step 1+3. The dark reading theme therefore lands on
  Windows for free, which is more than the GTK4 frontend has.
- `spdf_selection.c` / `spdf_selection_support.c` (558 LOC) — pure math over
  MuPDF structured text.
- The `spdf_yaml_from_json` / `spdf_json_from_yaml` codec (`spdf_yaml.c`
  lines 1–1025) — pure string work.
- Cooperative render cancellation (`spdf_render_token_*`,
  `shenzhen_pdf_core.h:144-156`) — an `fz_cookie` abort flag, thread-agnostic.

### 2.2 Needs a thin platform shim (the complete list)

This is the entire POSIX surface of the core. It is small, and every site is
named:

| Site | Problem on Windows | Fix |
|---|---|---|
| `core/shenzhen_pdf_core.c:18` | `#include <unistd.h>` does not exist under MSVC | `#ifdef _WIN32` guard |
| `core/shenzhen_pdf_core.c:2416` | `strrchr(path, '/')` in `create_temp_save_path` — a path like `C:\Users\x\a.pdf` yields `dir_len == 0`, so the temp file is created in the **CWD, not next to the document** | accept `\\` and `/` |
| `core/shenzhen_pdf_core.c:2429` | `mkstemp()` — no MSVC equivalent | `_mktemp_s` + `_sopen_s`, or `GetTempFileNameW` |
| `core/shenzhen_pdf_core.c:2403`, `:2485` | `rename(temp, path)` **fails when the destination exists** on Windows. These are the "remove all text" and `spdf_save_document` paths — **saving an edited PDF would fail every time** | `MoveFileExW(..., MOVEFILE_REPLACE_EXISTING)` |
| `core/shenzhen_pdf_core.c:136` | `path_basename` splits on `'/'` only — window titles show the full path | accept both separators |
| `core/spdf_yaml.c:7,11,13` | `<fcntl.h>`, `<sys/file.h>`, `<unistd.h>` | guarded |
| `core/spdf_yaml.c:1051-1057` | `st_mtimespec` / `st_mtim` nanosecond mtime, `#ifdef __APPLE__`/`#else` — Windows has neither | third branch on `_stat64`'s `st_mtime` (second resolution; note the precision loss in the re-migration heuristic) |
| `core/spdf_yaml.c:1089` | `getpid()` | `_getpid()` |
| `core/spdf_yaml.c:1096,1100` | `unlink()` | `_unlink()` |
| `core/spdf_yaml.c:1099`, `:1123` | `rename()` replace-existing again | `MoveFileExW` |
| `core/spdf_yaml.c:1131-1133,1144-1145` | `open(O_CREAT\|O_RDWR, 0600)` + `flock(LOCK_EX)` in `spdf_state_migrate_dir` — **no `flock` on Windows** | `CreateFileW` + `LockFileEx`, or a named mutex |
| `core/spdf_yaml.c:1130,1139,1140` | hardcoded `"%s/%s"` path joins | separator constant |
| `core/tests/SPDFRecolorProbe.c:30-34` | `clock_gettime(CLOCK_MONOTONIC)` — not in the MSVC UCRT | `QueryPerformanceCounter` |

That is **13 sites**. Two of them (`rename` replace-existing, the `'/'` split)
are silent correctness bugs rather than compile errors, so they must be fixed
deliberately rather than discovered when a user loses an edited PDF.

Also needed as shims, outside the core: an application-data directory
(`%APPDATA%\ShenzhenPDF\` in place of `~/Library/Application Support/ShenzhenPDF/`
and `~/.config/shenzhenpdf/`), and UTF-8 ⇄ UTF-16 conversion at every Win32 API
boundary — the core speaks UTF-8 `char*`, Win32 speaks `WCHAR*`. Call
`*W` APIs exclusively; never `*A`.

### 2.3 Reusable logic already sitting in the GTK4 frontend

This is the most valuable and least obvious asset in the repo. The GTK4 frontend
deliberately factored its reasoning out of its widgets. **40 files, 5,432 LOC,
contain zero references to `gtk_`/`gdk_`/`gsk_`/`adw_`/`cairo_`/`pango_`** — of
which 3,873 LOC live in five `*_internal.h` headers as **83 `static inline`
functions**, and `portable/Makefile:464-465` proves the point: the GTK4 test
binaries link **glib and OpenSSL only** — no GTK, no MuPDF.

| Header | LOC | `static inline` fns | What it owns |
|---|---|---|---|
| `spdf_docview_internal.h` | 512 | 28 | continuous layout, fit zooms, **document-space zoom anchoring**, horizontal clamp, 96 MB render cap, LRU cache, cursor regions |
| `spdf_minimap_internal.h` | 549 | 27 | strip geometry, thumbnail budget, viewport indicator, hit markers |
| `spdf_search_internal.h` | 255 | 15 | match indexing, nearest-match, snippet extraction, heat-map ticks |
| `spdf_sidebar_internal.h` | 278 | 10 | chapter attribution, result grouping |
| `spdf_props_internal.h` | 228 | 7 | metadata formatting |

The header comment at `spdf_docview_internal.h:1-31` documents each function's
provenance back to the macOS implementation *and* the specific bugs the current
formulation fixes (the June zoom-anchor drift on pixel-capped giant sheets, the
scrollbar-policy-from-total-width fix). Re-deriving this from scratch on Windows
would mean re-deriving those bugs too.

**Its glib dependency is small and unevenly distributed.**
`spdf_docview_internal.h` — the one Phases 2–3 need — uses only: typedefs
(`gsize`, `gboolean`, `gpointer`, `guint`), `g_free`/`g_new0`, one
`g_array_append_vals`, and **`GHashTable` (9 calls) confined entirely to
`spdf_lru_*`**. The layout / fit / zoom-anchor / clamp math is effectively
typedef-only. The search, sidebar and props headers additionally pull `GString`,
`GDateTime`, and `g_utf8_*` casefolding.

**Recommendation: do not take a glib dependency on Windows.** Port these headers
into `portable/win/src/` behind a small `spdf_win_compat.h` that provides the
typedefs and the ~10 trivial helpers, phase by phase as each header is actually
needed. Rationale: the whole surface is ~45 glib functions; a vcpkg glib on
ARM64 Windows adds several MB of DLLs and a supply-chain dependency against an
app whose headline promise is instant launch; and Phase 2 needs almost none of
it. The LRU's hash table is either ~150 lines of open addressing or
`std::unordered_map`.

### 2.4 Must be written fresh for Win32

Everything else. To size it honestly: the GTK4 frontend makes **443 distinct**
toolkit calls, and by namespace the distribution is `gtk_` **1013 references**,
`adw_` **273**, `cairo_` 138, `gdk_` **29**, `gsk_` 1, `graphene_` 7.

Read that carefully. **The drawing surface is trivial** — `spdf_render.c`, the
whole worker render pipeline, touches exactly three GDK functions
(`gdk_memory_texture_new`, `gdk_texture_get_width/height`); the Direct2D
equivalent is `ID2D1RenderTarget::CreateBitmap` from the same RGBA buffer. **The
cost is the ~1,300 widget, menu, dialog and event call sites** — tab strip,
sidebar, palette, toolbars, dialogs, print panel, file pickers. GTK4 got
`AdwTabView` (native drag reorder, continuous-drag detach/reattach, overview) for
free; Win32 gives none of that.

Fresh Win32 work, in the order the phases need it:

- window class, message pump, DPI awareness (per-monitor v2), Direct2D device
  and swap chain, WM_PAINT → present
- scroll/wheel/pinch input, kinetic pan, cursor regions
- worker render pool (Win32 thread pool or `std::thread`), per-thread documents,
  main-thread adoption via a posted message
- tab strip (custom-drawn), header bar, menus (`HMENU` or custom), keyboard
  accelerator table with the `Cmd → Ctrl` remap
- sidebar, minimap, find bar, command palette — all custom-drawn
- file dialogs (`IFileOpenDialog`), printing (`IPrintDocumentPackageTarget` or
  `StartDoc`/`EndDoc`), clipboard, shell integration, default-app registration
  (`IApplicationAssociationRegistration` / the Default Apps settings deep link —
  Windows does not permit silent association changes the way `xdg-mime` does)
- file watching (`ReadDirectoryChangesW` in place of FSEvents/`GFileMonitor`)
- updater install path — Authenticode + a self-replacing exe or MSIX, replacing
  both the macOS notarized `.app` swap and the Linux `pkexec dpkg -i`. The
  updater's *verification* core is portable: `spdf_updater.c` uses OpenSSL
  `EVP_PKEY_ED25519` + `EVP_blake2b512` and its minisign parser is marked pure
  (`spdf_updater.c:102`).

---

## 3. Technology recommendation

### Recommendation: plain Win32 + Direct2D + DirectWrite. No XAML, no Qt.

C++17 compiled with MSVC, the core included as `extern "C"`. Four reasons, in
descending weight.

**1. Startup cost is the product's headline promise, and it decides this.**
`readme.md` leads with "Launches instantly", and
`portable/docs/launch-performance-strategy.md:16-24` records that the team
already treats bundling one extra dynamic library (`libcrypto.3.dylib`) as
measurable launch damage. The GTK4 journal then supplies the empirical warning:
an **empty** `AdwApplicationWindow` maps in **285–465 ms**, the first
`gtk_window_present` of a process blocks **240–470 ms** on fonts/glyph
atlas/CSS/shaders, and closing that gap required inventing an entire resident-
process architecture (`spdf_resident.c`) to reach ~60 ms. WinUI 3 carries the
Windows App SDK — a large redistributable with XAML framework initialization on
the cold path, i.e. the same class of floor GTK4 hit. Qt drags 15–30 MB of
runtime and its own style stack. `user32`/`d2d1`/`dwrite` are already mapped
into every Windows process; the empty-window floor is single-digit milliseconds.
Choosing a heavy toolkit means paying the resident-mode tax on day one.

**2. It composes with the reuse layer.** §2.3's 5,432 reusable lines are plain
C. A Win32/C++ frontend `#include`s them. A WinUI 3 frontend is C# or C++/WinRT
over XAML, which would put a P/Invoke or WinRT projection boundary across the
*scroll hot path* — precisely the path `architecture.md` §9 says must stay
O(1)-ish per event.

**3. Text rendering.** DirectWrite is CoreText's peer — the same class of engine,
with direct analogues for the four things the Markdown engine actually needs
(§4): `IDWriteTextLayout::GetMetrics` for measurement,
`GetLineMetrics`/`HitTestTextRange` for line fragments,
`HitTestTextPosition` for character offsets, and `ID2D1RenderTarget::DrawTextLayout`
for drawing. Qt's text stack is a step down from DirectWrite for this work. WinUI
3 uses DirectWrite underneath but hides the layout object you need.

**4. It is the only option that tests headlessly, which decides whether an agent
can work at all.** Direct2D renders into a `ID2D1RenderTarget` created over a WIC
bitmap with **no HWND, no window, no GPU, no desktop session**. The entire
compose path — page image, drop shadow, selection highlights, minimap strip — is
therefore exercisable from `prlctl exec` and dumped to a PNG. Qt offscreen
rendering needs a `QGuiApplication` and the offscreen platform plugin; WinUI 3
effectively cannot render headlessly at all. Given `agents.md`'s standing rule —
"Do not launch, quit, or screenshot the app to verify your work… verify
headlessly" — and given that `prlctl exec` runs in the **SYSTEM session** (per
the comment in `portable/win/sync-to-vm.sh`, where the interactive `Z:` mapping
does not even exist), a stack that cannot render without a desktop is a stack
that cannot be developed by an agent here.

**Design consequence, and it is load-bearing:** `spdf_win_d2d.c` must expose
`spdf_win_paint(ID2D1RenderTarget*, ...)`, called identically by the window's
`WM_PAINT` and by the headless probe. If painting ever requires an `HWND`, the
headless test strategy collapses.

### The honest trade-off

This choice **trades a substantially larger chrome-writing cost for a launch
profile and a headless testability the alternatives cannot deliver.** Every tab,
every sidebar row, every palette entry is custom-drawn and custom-hit-tested. It
is the single biggest reason full parity is weeks rather than days.

The mitigation is real, though: most of that chrome's *behavior* already exists
as toolkit-free logic — `spdf_minimap_internal.h` (27 inline functions),
`spdf_search_internal.h` (15), `spdf_sidebar_internal.h` (10), and on the macOS
side `SPDFMacPaletteResults.mm` (palette matching), `SPDFMacFindNearest.mm`,
`SPDFMacTabStripGeometry.mm`, `SPDFMacCursorRegions.mm`,
`SPDFMacPropertiesFormat.mm`. What Win32 must supply is *painting and
hit-testing*, not re-derived behavior.

### On the Markdown engine — what porting it actually means

`portable/mac/markdown/README.md` is the contract, and it is more portable than
"64 files of CoreText" suggests. Measured:

- **~40,000 LOC of the dependency stack is already portable C**: `ext/md4c/`
  (6,462 LOC, the actual CommonMark parser) and `ext/gumbo-parser/` (33,356 LOC,
  the HTML5 parser). Both compile anywhere. Note `sync-to-vm.sh` already stages
  `ext/`.
- **CoreText is confined to 5 implementation files**, behind one shared
  constructor: `SPDFMarkdownCreateFragmentLine` (`SPDFMarkdownPaginator.h:22`,
  implemented `SPDFMarkdownPaginatorDrawing.mm:28-66`). Everything else calls
  only `CTLineGetTypographicBounds`, `CTLineGetOffsetForStringIndex`,
  `CTLineDraw`. `CTFont` appears zero times.
- **Text is measured in exactly four places**: `SPDFMarkdownPaginator.mm:359-394`,
  `SPDFMarkdownTableLayout.mm:101-142`, `SPDFMarkdownDiagramModel.mm:207-243`,
  `SPDFMarkdownImageRowBand.mm:19-77`. Drawing is confined to four `.mm` files.
- **~5,600 LOC (49%) is platform-free logic** — parsers, 31-language lexers, the
  Gumbo sanitizing whitelist, and the diagram subsystem's parsers + graph layout.
  The diagram split is architectural, not incidental: the 7 parsers
  (`SPDFMarkdownDiagramInternal.h:219-227`, 1,060 LOC) and the layered graph
  layout (`SPDFMarkdownDiagramLayout.mm`, 209 LOC) touch **no** AppKit or Core
  Graphics symbol, and `SPDFMarkdownDiagram.h` returns **geometry, not pixels** —
  shapes carry a semantic *role*, never a color, so one layout serves both
  themes. Rasterization is a single function in `SPDFMarkdownDiagramBand.mm`.

Two hard truths, though:

**(a) "Platform-free" here means free of AppKit, not free of Foundation.** Those
5,600 lines are Objective-C++ saturated with `NSString` (652 references),
`NSArray` (227) and `NSDictionary` (49). Porting is a mechanical but voluminous
translation to C++ `std::u16string`/containers. Nothing is hard; everything takes
time.

**(b) The line-breaking engine defines the public coordinate space, and it is
TextKit, not CoreText.** `SPDFMarkdownPaginator.mm:359-394` builds an
`NSTextStorage`/`NSLayoutManager`/`NSTextContainer` and calls
`enumerateLineFragmentsForGlyphRange:`. Per `markdown/README.md:28-45`, the
resulting `attributedString` is *the only user-visible coordinate space* — search
matches, heading ranges, selection and pagination are all ranges into it. A
DirectWrite reimplementation will **not** reproduce TextKit's fragment
boundaries.

So the honest position: **"1:1" for Markdown must mean same content, same
styling, same feature set, internally consistent coordinates — not the same page
breaks as macOS.** Chasing byte-identical line breaking across two independent
text engines is unwinnable and would sink the port. Every guarantee in the README
still holds on Windows, because consumers index into the *Windows-produced*
string. This needs to be an explicit product decision, not a discovery.

Estimated cost of the Markdown subsystem alone: comparable to the entire rest of
the frontend. **Out of scope for Phases 1–7.**

---

## 4. Phased plan

**Status annotations added 06:45.** The file lists below were written before the
code existed and named several files that were ultimately created at different
paths or with different extensions; where that happened, the planned name is
struck through and the real one given. This matters because those wrong paths
were being copied forward into other documents.

### Phase 0 — Toolchain — **COMPLETE**

Delivered: MuPDF 1.27.2 built natively for ARM64 in the guest (417 + 229
objects, every one `AA64`), linked against `portable/core`, with a page render
byte-identical to macOS. `sync-to-vm.sh` stages `mupdf`. `verify.sh` → exit 0.

Two things the plan got wrong here, both worth recording because they cost time:

- **`mupdf.sln` was not used and would not have worked.** The plan (and risk 1)
  assumed its 619 ARM64 references meant MSBuild would handle this with no new
  project files. In fact its feature set differs from the Mac build's and would
  drift silently; worse, `mupdf/scripts/bin2coff.c`'s ARM64 output does not link
  at all (unaligned size symbols, `LNK2048`, systemic across ~3/4 of the 182
  font blobs). The build description is instead derived mechanically from
  `make -n` inside `mupdf/` with `portable/Makefile`'s own arguments.
- **MSVC cannot compile MuPDF's embedded font resources.** `cl.exe` needs
  multiple GB of heap per MB of string literal and `SourceHanSerif-Regular.ttc.c`
  is 103 MB. The blobs are embedded from their original binaries by
  `portable/win/mupdf-bin2coff.c` instead. Nothing in the plan anticipated this.

*(Original text follows.)*

### Phase 0 — Toolchain (as planned, T0)

**Goal.** MuPDF and the core compile and link in the guest; the macOS→guest
build chain propagates exit codes.

**Already delivered:** `portable/win/sync-to-vm.sh` (stages `portable/core`,
`portable/win`, `ext` into `~/Documents/spdf-win`, visible in the guest as
`\\Mac\Home\Documents\spdf-win`), `vm-build.sh [--run] <target> <src>...`,
`guest-build.cmd`, `verify.sh`.

**Remaining:** add `mupdf` to `SUBTREES` in `sync-to-vm.sh`, and build
`libmupdf` for ARM64. `mupdf/platform/win32/mupdf.sln` already carries **619
ARM64 references** and `libmupdf.vcxproj` has **54**, so MSBuild handles this
without new project files.

**Done means:** `vm-build.sh --run core_smoke portable/core/shenzhen_pdf_core.c …`
opens a PDF in the guest and prints its page count, exit 0.

**Headless test:** `portable/win/verify.sh` already proves (1) byte-identical
pure-C output across hosts, (2) `vm-build.sh` exits non-zero on a broken source,
(3) exits zero on a good one. Extend with a fourth step that opens a fixture PDF.

---

### Phase 1 — A window rendering a real PDF page — **COMPLETE AT THE PIXEL LAYER, UNPROVEN AT THE WINDOW LAYER**

**Goal.** `ShenzhenPDF.exe some.pdf` opens a native window and displays page 1,
rendered by `spdf_render_page_rgba_opts` through Direct2D. Not scaffolding: end
to end, core to pixels.

**Files created** — planned vs. actual, because the planned paths were wrong and
got copied into other docs:

| planned | actual |
|---|---|
| `portable/win/src/spdf_win_main.c` | `portable/win/src/spdf_win_main.cpp` (C++) |
| `spdf_win_window.{h,c}` | `spdf_win_window.{h,cpp}` |
| `spdf_win_d2d.{h,c}` | `spdf_win_d2d.{h,cpp}` |
| `portable/win/src/spdf_win_compat.{h,c}` | **`portable/core/spdf_win_compat.{h,c}`** — it shims the *core*, so it lives with the core, and must appear in every Windows source list |
| `portable/win/src/spdf_win_probe.c` | `portable/win/spdf_win_probe.c` (not under `src/`) |

**Done means:** the window opens, the page is visible and correctly scaled to
the client area, resizing repaints, DPI scaling is correct on a 2× display, and
closing exits 0. No scrolling required.

**Against that bar, honestly:** *"correctly scaled to the client area"* is now
true and verified numerically — `--render-window-png golden.pdf 0 900 700`
reports `zoom=4.500000` and draws the 200 pt page at 900 px, filling the
viewport. It was **not** true for several hours (QC F4: `fit_zoom()` clamped at
100%, so a small page opened postage-stamp sized while the correctly-ported
`spdf_win_layout.h` sat unused beside it). The other four criteria — opens,
repaints on resize, DPI on a 2× display, exits 0 on close — **remain unobserved
by anyone** and cannot be observed from a SYSTEM session. See §0.

What is genuinely proven instead: the same `spdf_win_paint` compose path runs
headlessly into a WIC-backed `ID2D1RenderTarget`, writes a PNG, and produces
byte-identical output to macOS in both plain and dark themes.

**Headless test.** `spdf_win_probe.exe <pdf> <page> <zoom> <out.png>` runs the
*same* `spdf_win_paint()` into a WIC-backed `ID2D1RenderTarget` and writes a PNG.
Compare against the macOS reference from `portable/core/tests/SPDFRecolorProbe.c`,
which already renders through the shipping core path and writes PNGs via
`fz_save_pixmap_as_png`. Non-zero exit on mismatch beyond tolerance (§6).

---

### Phase 2 — Continuous scrolling canvas — **COMPLETE**

**Goal.** Multi-page continuous layout, wheel and drag scrolling, fit modes,
cursor-anchored zoom, the horizontal clamp, and the crop regime for oversized
pages.

**Files created:** `portable/win/src/spdf_win_layout.h` (the de-glib'd port of
`spdf_docview_internal.h`) landed as planned. ~~`spdf_win_canvas.{h,c}`~~ →
`spdf_win_canvas.{h,cpp}` plus `spdf_win_canvas_internal.h` and
`spdf_win_canvas_prefetch.cpp` (split to stay under the 500-line cap — risk 11
arriving as predicted, and handled the way §5 asks rather than by an exception).

The three planned test files ~~`layout_test.c`, `zoom_anchor_test.c`,
`clamp_test.c`~~ landed as **one** `portable/win/tests/layout_geometry_test.c`,
plus `gtk_differential.{c,h}` and `gtk_differential_cache.c` — which do
something better than the plan asked for: rather than asserting the same
*expected values* as the GTK4 suite, they compile
`portable/linux/gtk4/spdf_docview_internal.h` and the Windows port into one
binary and assert the two implementations agree function by function, at exact
equality (a one-ulp difference in a transcription is still a transcription
error). Measured: **397,099 comparisons, 0 mismatches.** A hand-copied list of
expected constants would not have caught what that catches.

**But it is not in the gating suite.** `gtk_differential.c` is not named
`*_test.c`, so `run-tests.sh` does not discover it; it runs only from
`portable/win/tests/t3-verify.sh`, which is a separate **7-case** run:

```sh
bash portable/win/tests/t3-verify.sh    # 7 cases, 0 failed, exit 0
#   differential.gtk4    397099 comparisons, 0 mismatches
#   transcript.layout    byte-identical across clang/arm64 and MSVC/ARM64 (82 lines)
#   transcript.lru       byte-identical across clang/arm64 and MSVC/ARM64 (25 lines)
```

So the strongest correctness evidence the layout port has is **not** part of the
20-case suite that gates everything else. Anyone touching `spdf_win_layout.h`
must run `t3-verify.sh` by hand or they will not learn they broke it. Folding it
into the runner is cheap and should happen.

**Done means:** a 100-page mixed-size document scrolls smoothly; every page is
centred on the canvas midline (`architecture.md` §4.1); cursor-anchored zoom
keeps the anchored point under the cursor; a 10900×7539 pt sheet enters the crop
regime rather than attempting a 96 MB+ bitmap.

**Headless test:** port `portable/linux/gtk4/tests/layout_test.c`,
`zoom_anchor_test.c`, `clamp_policy_test.c` to run under `vm-build.sh --run`,
asserting identical values to the Linux suite. These are pure math — they need
neither MuPDF nor a window.

---

### Phase 3 — Worker render pipeline — **COMPLETE**

**Goal.** Off-thread rendering with per-thread documents, display-list caching,
cancellation tokens, the 96 MB byte cap, LRU eviction, current-page-first
priority, and neighbour prefetch.

**Files:** `spdf_win_render.{h,c}`, `spdf_win_lru.{h,c}` as planned;
~~`tests/lru_test.c`~~ → `tests/lru_cache_test.c`; `tests/render_service_test.c`
as planned.

The 96 MB cap (`spdf_win_capped_render_zoom`) is applied on the canvas and
prefetch paths. It is **not** applied on `--render-png`, which remains
unbounded — acceptable for a test-facing interface, worth knowing before it
becomes user-facing.

**Done means:** the invariants in `architecture.md` §3.3–§3.6 hold — render
concurrency capped at ~3–4, the completion callback fires exactly once per token
including on cancellation, and adoption on the main thread does no O(n) work.

**Headless test:** the render service driven from a console harness with no
window; assert callback-exactly-once under concurrent cancellation, and assert
peak RSS stays under the cap while walking a 500-page document.

---

### Phase 4 — Shell: tabs, state, multi-window — **STATE COMPLETE, TABS IN FLIGHT**
State via `spdf_yaml`, byte-compatible with the mac and Linux schemas
(`settings.yaml`, `session.yaml`, `documents.yaml`, `favorites.yaml`) under
`%APPDATA%\ShenzhenPDF\`. Test: round-trip a session written by the mac app.

**Landed:** `spdf_win_paths.{h,c}` (`SHGetKnownFolderPath`, UTF-8⇄UTF-16) and
`spdf_win_state.{h,c}`, covered by `win.paths_test`, `win.state_test` and
`win.silent_failure_test`. State reads now distinguish ABSENT from FAILED and
refuse to overwrite on FAILED (QC F7) — without that, one antivirus lock at the
wrong moment silently replaced the user's settings, session and recent files
with defaults, reporting success as it did so.

**In flight at the time of writing:** `spdf_win_tabs.{h,cpp}` and
`spdf_win_session.h` exist in the working tree but are **not committed**, so
none of the numbers in §0 or §1 include them.

**Known gap:** `session.lock` is declared and documented in
`spdf_win_state.h:94-96` and implemented, but `spdf_win_state_write_json_at`
does read-compare-write without taking it, and nothing outside the tests calls
`spdf_win_state_session_lock_acquire`. Untriggerable with one window; a
lost-session bug the day multi-window lands — which is this phase.

### Phase 5 — Find, sidebar, minimap
Ports `spdf_search_internal.h`, `spdf_sidebar_internal.h`,
`spdf_minimap_internal.h`. Test: the corresponding GTK4 test suites, re-run.

### Phase 6 — Selection, links, annotations, printing, export, dark theme
The dark reading theme is nearly free — it is one render flag
(`shenzhen_pdf_core.h:168`) over `spdf_recolor.c`, already proven bit-identical
on Windows. Test: `SPDFCoreRenderThemeTests.c` and `SPDFCoreSelectionTests.c`
run in the guest.

### Phase 7 — Subsystems: OCR, translation, updater, default reader
Each is frontend-only and platform-specific by nature. The updater's crypto core
ports; its install path does not.

### Phase 8 — Markdown
A separate project. See §3.

---

## 5. The first seven hours — parallel work breakdown

Six tracks. **The single largest failure mode is two agents editing one file**,
so ownership is exclusive and stated per file. Two rules are absolute:

> **`portable/core/**` is owned by T1 alone this session.**
> **`portable/win/*.sh`, `*.cmd` and `portable/win/smoke/**` are owned by T0
> alone.** No other track may edit them, not even a one-line change.

A track owns its own `portable/win/tests/<name>_test.c`. Only T4 owns the runner.

Every new source file must stay **under 500 lines** (`tools/file-size-limits.md`);
a 501–1000 line file needs a justified entry in `tools/file-size-limits.tsv`.
Design under the cap rather than asking for an exception.

| Track | Owns (exclusive) | Deliverable |
|---|---|---|
| **T0** *(running)* | `portable/win/sync-to-vm.sh`, `vm-build.sh`, `guest-build.cmd`, `verify.sh`, `smoke/**`, `portable/win/README.md` | `mupdf` added to `SUBTREES`; `libmupdf` ARM64 via MSBuild; `verify.sh` step 4 opens a PDF in the guest |
| **T1** | `portable/core/**` (all 13 sites in §2.2), ~~`portable/win/src/spdf_win_compat.{h,c}`~~ → **`portable/core/spdf_win_compat.{h,c}`**, ~~`portable/win/tests/compat_test.c`~~ → `portable/core/tests/SPDFCoreCompatTests.c` | Core compiles clean under MSVC **and still clean under clang** (`make -C portable core-selection-tests` stays green); `MoveFileExW` replace-semantics; `LockFileEx` migration lock; both path separators |
| **T2** | `spdf_win_main.cpp`, `spdf_win_window.{h,cpp}`, `spdf_win_d2d.{h,cpp}` (all landed as C++, not C) | **Phase 1**: the window that shows a real page. `spdf_win_paint(ID2D1RenderTarget*, …)` must not require an `HWND` |
| **T3** | `portable/win/src/spdf_win_layout.h`, `spdf_win_lru.{h,c}`, `portable/win/tests/layout_geometry_test.c`, `lru_cache_test.c`, `gtk_differential*.c` (the four planned files landed as two, plus the differential harness) | The de-glib'd port of `spdf_docview_internal.h`, with the four GTK4 test suites passing in the guest with identical values |
| **T4** | `portable/win/tests/run-tests.sh`, ~~`portable/win/tools/compare_png.py`~~ → `portable/win/tests/compare_png.py`, ~~`portable/win/src/spdf_win_probe.c`~~ → `portable/win/spdf_win_probe.c`, ~~`portable/win/fixtures/**`~~ → `portable/win/tests/fixtures/**` | Headless harness: exit-code runner, PNG comparator with a *measured* tolerance, macOS reference PNGs |
| **T5** | `portable/win/src/spdf_win_render.{h,c}`, `portable/win/tests/render_service_test.c` | Worker pool, per-thread documents, tokens, callback-exactly-once |
| **T6** | `portable/win/src/spdf_win_paths.{h,c}`, `spdf_win_state.{h,c}`, `portable/win/tests/paths_test.c` | `%APPDATA%\ShenzhenPDF\`, UTF-8⇄UTF-16 helpers, YAML state round-trip against a mac-written `session.yaml` |

### Dependency management — how the stall is avoided

The obvious risk is that everyone waits on T0 for a working MuPDF. Three things
prevent it:

1. **T1, T3, T4, T6 need no MuPDF and no window.** They are pure C. Each can
   compile-check on macOS with `cc` *and* in the guest with
   `vm-build.sh <target> <sources>` from hour zero — `verify.sh` has already
   proven that pure C behaves identically on both.
2. **T2's Phase 1 milestone deliberately depends on nothing.** It renders page 1
   only, synchronously, on the UI thread, with a direct
   `spdf_render_page_rgba_opts` call — **no T3 layout header, no T5 render
   service**. Integration happens in the second half, after both have landed.
   This is the whole reason Phase 1 is "page 1" and not "a scrolling document".
3. **T5 develops against a stub renderer** (a function returning a synthetic RGBA
   gradient) until MuPDF links, then swaps in the real call. The pool, the
   tokens and the callback contract are all testable against the stub.

### Rough timeline

| Hours | T0 | T1 | T2 | T3 | T4 | T5 | T6 |
|---|---|---|---|---|---|---|---|
| 0–1 | mupdf staging + MSBuild | shim + core `#ifdef`s | window class, D2D device, blank window | layout header port | runner + comparator | pool skeleton vs stub | `%APPDATA%` paths |
| 1–3 | libmupdf ARM64 green | `MoveFileExW`, `LockFileEx` | **Phase 1: real page on screen** | zoom anchor + clamp tests green | macOS reference PNGs | tokens, callback-once | YAML round-trip |
| 3–5 | verify.sh step 4 | core tests green both hosts | integrate T3 layout → scroll | LRU + hash map | first Win↔mac PNG diff, tolerance set | real `spdf_*` calls | state schema tests |
| 5–7 | support | support | zoom + crop regime; wire T5 | support | full suite by exit code | prefetch + eviction | support |

**Committed at hour 7:** Phase 1 complete and proven by pixel comparison; Phase
2 substantially complete; Phase 3 partial. Everything else is Phases 4–8.

---

## 6. Testing strategy

Everything below runs from macOS. Nothing requires opening the VM's desktop, and
per `agents.md` nothing launches, quits or screenshots the macOS app.

**1. Exit codes are the signal.** `vm-build.sh`'s stated one invariant is that it
exits with the guest's real exit code — verified in its own header comment
(`exit /b 7` in the guest yields `$? == 7` on the Mac), which is why it uses no
`set -e`, no pipes around the `prlctl` call, and no trailing command.
`guest-build.cmd` reserves codes 90+ for infrastructure failures so they are
distinguishable from `cl.exe`'s 2. Honour `agents.md`: **redirect to a file and
check `$?`; never `| grep -c passed`**, which reports grep's status and can make
a failed compile look green.

**2. `portable/core`'s existing test targets are free Windows conformance.**
Six suites — `SPDFCoreOutlineTests`, `SPDFCorePasswordTests`,
`SPDFCoreRecolorTests`, `SPDFCoreRenderThemeTests`, `SPDFCoreSelectionTests`,
`SPDFCoreCJKSelectionTests` (2,035 LOC in `portable/core/tests/`) — are pure C
over MuPDF with `main()`s and no UI. The moment `libmupdf` links in the guest,
`vm-build.sh --run` builds and runs each of them on Windows. That is a
substantial, already-written cross-platform correctness suite for essentially
zero cost, and it should be wired up in Phase 0/1 rather than treated as later
work. `SPDFCoreRecolorTests` needs no MuPDF at all and can run on day one.

**Status: only three of the six are actually wired.** `run-tests.sh`'s
`CORE_SUITES` holds `SPDFCoreRecolorTests`, `SPDFCoreCompatTests` and
`SPDFCoreSaveTests` (the third of which, per QC F2, had never once launched
until 06:32 — the harness pasted its argument onto the closing quote of the
`.exe` path, so cmd rejected the command line and the failure was reported as a
bug in `portable/core`). `SPDFCoreOutlineTests`, `SPDFCorePasswordTests`,
`SPDFCoreRenderThemeTests`, `SPDFCoreSelectionTests` and
`SPDFCoreCJKSelectionTests` are still not registered. The "essentially zero
cost" claim above is correct and still unclaimed; this is the cheapest
outstanding win in the port.

**3. Golden images against the macOS renderer.** `SPDFRecolorProbe.c` is already
the pattern `agents.md` asks for — "a probe binary that writes PNGs you sample
programmatically" — rendering through the shipping core path and writing via
MuPDF's own portable `fz_save_pixmap_as_png`. `spdf_win_probe.c` mirrors it.

*Be honest about the tolerance.* `verify.sh` has proven **byte-identical** output
for pure integer C (`spdf_recolor.c`) between clang/arm64 and MSVC/ARM64. MuPDF's
rasterizer is largely fixed-point and both hosts are ARM64 IEEE-754, so
byte-identity is plausible — **but it must be measured in Phase 1, not assumed.**
`compare_png.py` should therefore report max per-channel delta and mean absolute
error, fail hard on any structural difference (dimensions, stride), and have its
tolerance threshold set from the first measurement with the measured value
recorded in a comment. If the delta is zero, pin it at zero.

**Measured, and pinned at zero.** Both fixtures come back byte-identical from
the guest, so `probe-cases.sh` passes `--strict` and `--strict` *decides* the
case. For a while it ran "for the report only" while the loose provisional
defaults (MAE 1.5, 2% bad pixels) actually decided pass/fail — a regression
staying inside those would have passed a comparison known to be bit-exact
(QC F9). The loose numbers survive only as a diagnostic scale, consulted after
strict has already failed.

**One flag makes this work and must not be removed:** `-ffp-contract=off` on the
macOS side. clang fuses `a*b + c` into a single FMA — one rounding step — where
MSVC under `/fp:precise` does not, so without it the two hosts disagree in the
last bit and a zero tolerance goes red. Same arithmetic, same hardware, different
contraction. See gotcha 19 in `portable/win/README.md`.

Compare at three levels, in this order:
- **core output** — `spdf_render_page_rgba_opts` bytes, Windows vs macOS. Any
  difference here is a core or MuPDF-build problem, before any UI is involved.
- **compose output** — the full `spdf_win_paint()` into a WIC bitmap: page image,
  shadow, highlights, minimap strip. This is the layer Direct2D makes uniquely
  testable, and the reason for the no-`HWND` design rule.
- **geometry** — the ported layout/zoom/clamp functions asserted against the same
  expected values as `portable/linux/gtk4/tests/layout_test.c` and
  `zoom_anchor_test.c`. Cheapest and highest-signal of the three.

**4. Screenshot-level capture, later and manually.**
`portable/linux/dev/capture.sh` is the Linux precedent (xdotool + ImageMagick
under XWayland). The Windows analogue is PowerShell driving `PrintWindow`. It
needs an **interactive** session, which `prlctl exec`'s SYSTEM session is not, so
keep it out of the automated loop and use it only for the occasional human
sanity check.

---

## 7. Risks

**How they actually turned out** (added 06:45). The table below is the original
assessment; this is the scorecard:

| # | Outcome |
|---|---|
| 1 | **Materialised, and the mitigation was wrong.** MuPDF did build ARM64, but not via `mupdf.sln` — see Phase 0 above. No fallback to x64 emulation was needed. |
| 2 | Avoided exactly as designed; `mupdf` was added to `SUBTREES` by T0. |
| 3, 4, 5 | All three real, all three fixed and covered by `SPDFCoreSaveTests` / `SPDFCoreCompatTests`. |
| 6 | **Did not materialise** — byte-identical on both fixtures. But only because `-ffp-contract=off` is set; see §6. |
| 7 | **Materialised twice as a *git* collision, not a file collision.** Two tracks used `git add -A` and silently reverted another track's work. Ownership tables do not protect you from a greedy `git add`. Use `git add -- <your own paths>` and check `git status` after committing. |
| 8 | Avoided; the phase ordering worked. |
| 9 | **Materialised, and is the port's defining limitation.** See §0. The mitigation (never require an `HWND` to paint) worked perfectly and is why anything is verifiable at all — but "interactive screenshots stay a manual step" turned out to mean *no one has ever seen the window*. |
| 10 | Held; Markdown untouched. |
| 11 | **Materialised** — `spdf_win_render.c` hit 732 lines mid-flight (QC F10) and `spdf_win_canvas` outgrew the cap. Both were split rather than exempted, as §5 asks. Ratchet is green. |
| 12 | Held. macOS is unregressed: `mac-app`, 28 suites and both Markdown runners all exit 0. |
| 13 | Materialised as predicted and shimmed early. |

One risk the plan did not list and should have: **the documentation drifting out
of sync with the tree faster than anyone could read it.** Agents that cannot see
each other, several killed mid-sentence by a spend limit, left this file and
`portable/win/README.md` asserting things that a later chapter of the same file
disproved — most starkly a README that claimed "no Windows render exists" two
hundred lines before the chapter proving one did. Docs written in flight need a
reconciliation pass against the tree before anyone trusts them.

*(Original risk table follows.)*

| # | Risk | Mitigation |
|---|---|---|
| 1 | **MuPDF will not build ARM64 in the guest.** Blocks Phase 1 and every render test. | `mupdf.sln` already carries 619 ARM64 references and `libmupdf.vcxproj` 54 — MSBuild should work with no new project files. Fallback: build x64 and run under Windows-on-ARM emulation; slower, still correct. Owned by T0, started first. |
| 2 | **`sync-to-vm.sh` does not stage `mupdf`.** `SUBTREES` is `portable/core portable/win ext`, so MuPDF sources are invisible in the guest. | One-line change — but in a file **only T0 may edit**. Assigned explicitly rather than left for whoever notices. Exactly the collision class this plan is designed against. |
| 3 | **`rename()` silently breaks PDF saving.** `shenzhen_pdf_core.c:2403,2485` and `spdf_yaml.c:1099,1123` fail whenever the destination exists — a user would lose an edited PDF, not see a compile error. | T1 replaces all four with `MoveFileExW(..., MOVEFILE_REPLACE_EXISTING)`; `compat_test.c` asserts overwrite-existing succeeds. |
| 4 | **`create_temp_save_path` writes to the wrong directory.** `shenzhen_pdf_core.c:2416` splits on `'/'` only, so a `C:\…` path yields `dir_len == 0` and the temp file lands in the CWD — which may be on a different volume, making the subsequent rename fail. | T1 accepts both separators; test with a Windows-style absolute path. |
| 5 | **No `flock`.** `spdf_yaml.c:1131-1133` guards state migration across the app's per-window processes. | `CreateFileW` + `LockFileEx`, or a named mutex. Test by racing two processes at one directory. |
| 6 | **Golden images diverge on floating point** between clang/arm64 and MSVC/ARM64. | Measure in Phase 1 before writing any assertion; set the tolerance from evidence and record the measured value. Never assert byte-identity on faith. |
| 7 | **Overlapping file ownership between concurrent agents.** The main way this fails. | §5's exclusive ownership table; `portable/core` → T1 only; `portable/win/*.sh|cmd` → T0 only; each track owns its own test file, T4 owns the runner. |
| 8 | **Phase 1 stalls waiting on Phases 2–3.** | Phase 1 is deliberately page-1-only, synchronous, with no layout header and no render service. T5 develops against a stub renderer. Four of six tracks need neither MuPDF nor a window. |
| 9 | **`prlctl exec` runs in the SYSTEM session**, where interactive GUI behaviour and the `Z:` mapping do not exist. | Never require an `HWND` to paint: `spdf_win_paint(ID2D1RenderTarget*, …)` serves both the window and the WIC-backed probe. Interactive screenshots stay a manual step. |
| 10 | **Scope creep into Markdown.** 18,100 LOC with an unwinnable line-breaking parity trap (§3). | Explicitly out of scope for Phases 1–7. The pagination-parity decision is escalated to the product owner *before* any work starts, not discovered mid-port. |
| 11 | **The 500-line file cap** is hit late and forces churn. | Every track is told at kickoff; files are designed under the cap. Prefer extracting a focused file over requesting an exception (`agents.md`). |
| 12 | **Regressing macOS or Linux while editing shared code.** T1 touches `portable/core`, which both shipping frontends depend on. | Every T1 change is `#ifdef _WIN32`-guarded or separator-agnostic, and T1's done-bar includes the existing macOS core suites still passing by exit code. |
| 13 | **`clock_gettime` is absent from the MSVC UCRT** (`SPDFRecolorProbe.c:30-34`), so the probe pattern will not compile as-is. | `QueryPerformanceCounter` behind the compat shim; caught early because T4 ports the probe in hour 0–1. |

---

## 8. What Windows gets that Linux does not

Worth recording, because it inverts the usual assumption that a third frontend is
strictly behind:

- **The dark reading theme.** `SPDF_RENDER_DARK_THEME`, `SPDF_RENDER_PRESERVE_IMAGES`
  and `spdf_recolor` appear **zero times** in `portable/linux/gtk4/`. On Windows
  it is one render flag over code already proven bit-identical there — so the
  app's most recent headline feature can ship on Windows before it ships on Linux.
- **A render pipeline whose whole toolkit surface is three functions.**
  `spdf_render.c` touches only `gdk_memory_texture_new` and
  `gdk_texture_get_width/height`; `ID2D1RenderTarget::CreateBitmap` over the same
  RGBA buffer is a direct swap.
- **Genuinely headless UI testing.** Neither AppKit nor GTK4 can render the
  compose path without a display server. Direct2D over WIC can, which means the
  Windows frontend can be developed to a standard of automated visual
  verification the other two frontends never had.
