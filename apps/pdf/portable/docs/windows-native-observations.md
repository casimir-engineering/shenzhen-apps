# Windows Port — First Observations From a Real Desktop

Written 2026-09-01 on a **native Windows x64 desktop**, continuing from
`portable/docs/windows-port-handoff.md` (HEAD at handoff `19cb2f6a8`; this work
starts at `2a3afd434`).

The handoff's §0 said the thing that mattered most:

> **Nobody has ever seen a ShenzhenPDF window open on Windows.**

Somebody has now. This file is the evidence, written in the order the handoff's
§7 asked for it, and it corrects several claims that could only be checked by
looking.

---

## 0. The headline

**A ShenzhenPDF window opens on Windows, renders the page correctly, repaints on
resize, scales correctly on a fractional-DPI display, and exits 0.**

All five of Phase 1's done-criteria were listed as unobserved. All five now pass,
in **both** light and dark, reproducibly, by exit code:

```
portable\win\verify-phase1.ps1 -Exe <exe> -Pdf <pdf>          # 7 passed, 0 failed  exit 0
portable\win\verify-phase1.ps1 -Exe <exe> -Pdf <pdf> -Dark    # 7 passed, 0 failed  exit 0
```

And the strongest single result, because it retroactively justifies the port's
whole verification strategy:

> **The window's client area is BYTE-IDENTICAL to the headless compose path** at
> the same viewport and the same DPI scale — 0 differing pixels out of 816,912,
> in light and in dark.

`spdf_win_d2d.h`'s rule that `spdf_win_paint()` must never require an `HWND` was
taken on faith for the entire port. It is now measured: the offscreen pixel tests
really are evidence about the real window. Nobody could show that before, and
every pixel test in this repo was worth less until it was shown.

---

## 1. This is not the machine the port was written for

When this was written, everything in `portable/win/README.md` and the handoff
assumed an **ARM64** Windows 11 guest in Parallels, reached over `prlctl exec`,
with a toolchain in `C:\BuildTools` and MuPDF prebuilt in `C:\spdf-build\mupdf`.
None of that was true here. (`portable/win/README.md` has since been rewritten
native-first and the Parallels route moved to its own chapter; the handoff has
not, and should be read as history.)

| | Docs assume | This machine |
|---|---|---|
| CPU / target | Windows 11 **ARM64** (`AA64`) | **x64** (`8664`), AMD Ryzen 5 6600U |
| Toolchain root | `C:\BuildTools` | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |
| MSVC | 19.44 / 14.44.35207, `HostARM64\arm64` | same toolset, `Hostx64\x64` |
| Windows SDK | 10.0.26100.0 present | **absent** — had to be installed |
| MuPDF libs | prebuilt, present | **absent** — had to be built |
| `make` | present on the Mac side | **absent** (installed: GNU make 4.4.1) |
| Display | unknown, assumed 1× / 2× | **144 dpi (150%)** — fractional |

Two consequences that change what the documents mean:

**The byte-identity claim was ARM64 ↔ ARM64.** §1.3's "the rendered page is
byte-identical to macOS, tolerance pinned at zero" was measured between an ARM64
Mac and an ARM64 guest. Reproducing it here would be **x64 ↔ ARM64**, which is a
different and unproven claim — SSE versus NEON float behaviour is a new variable,
and the existing `-ffp-contract=off` note (gotcha 19) is about exactly this class
of last-bit difference. **Do not assume the zero tolerance carries to x64 until
someone measures it.** Nothing in this session measured it, because it needs a
Mac.

**The fractional DPI is a gift.** The plan asked for "DPI scaling is correct on a
2× display". 150% is a *harder* test than 200%: it produces fractional layout and
fractional stroke widths, and it found a real defect that 1× or 2× would have
hidden (§4.1). macOS backing scales are only ever 1× or 2×, so this is a class of
bug the macOS source cannot warn you about.

### 1.1 New environment gotchas

Add these to `portable/win/README.md`'s numbered list rather than here.

- **`NoDefaultCurrentDirectoryInExePath=1` is set on this machine.** `cmd` will
  not find `foo.cmd` in the working directory; scripts must be invoked by
  absolute path or `.\foo.cmd`. Cost: one confusing "is not recognized as an
  internal or external command" for a file that was plainly there.
- **`vcvarsall.bat` prints `'vswhere.exe' is not recognized` on stderr here and
  still returns 0.** It is noise, caused by the item above. Judge it by exit code
  and by `VSCMD_ARG_TGT_ARCH`, never by its output.
- **`mupdf/generated/` is not needed on Windows at all.** The handoff (§2.3) and
  `mupdf-gen-ninja.sh`'s exit-70 guard imply it is a build input. It is not: it
  holds only the font and hyphenation hexdumps, which the Windows build replaces
  with bin2coff over the original binaries. Every *other* `generate:` target in
  `mupdf/Makefile` — 7 ICC headers, `util.js.h`, `css-properties.h`, and all 71
  cmap headers — is **already committed** and present. The guard's real job is a
  symbol cross-check, not a dependency.
- **Do not glob MuPDF's fonts.** There are **185** font binaries on disk; the
  Makefile embeds **181**. The four extras are CharisSIL *design sources*. `make -n`
  excludes them for free; a structural glob would have embedded 4 MB of the wrong
  thing.
- **Argument quoting bit twice, in two different tools.** PowerShell's
  `Start-Process -ArgumentList` does not quote for you, so a path containing
  spaces arrives as several arguments. This produced a VS installer that silently
  used `--installPath C:\Program`, and an app that "could not open the file" with
  exit 64 when the file was fine. Both were harness bugs wearing a product bug's
  clothes.

---

## 2. What the window actually looks like

Captured with `portable/win/screenshot-window.ps1` (new; see §5), at the macOS
default content size of 1120×800, on `what made apollo a success` (a NASA scan —
multi-page, image-backed, so it exercises the dark theme's scan path).

**Light.** The page is correctly fit to width, sharp, correctly positioned, on the
`#E0E0E2` surround. The document renders exactly as the headless path renders it.

**Dark.** The luma remap is visibly a remap and not an inversion — light ink on
dark paper with the page's own structure intact. Verified against the palette *in
a live window*, not in a unit test:

| Role | Measured in the window | Palette says |
|---|---|---|
| viewport gutter | `#121212` | `#121212` ✓ |
| page border, all four edges | `#333333` | `#333333` ✓ |
| page paper | `#1E1E1E` | `#1E1E1E` ✓ |

The OS title bar follows the theme (dark caption around a dark canvas), and the
title reads `apollo.pdf - Shenzhen PDF` — both of which were defects the handoff
listed and are now fixed.

### 2.1 The parity gap, seen rather than inferred

At first sight, placed beside `docs/images/portable/macos-main-window.webp`, the
Windows window was missing every piece of chrome the macOS app has. **That has
since been built** — tab strip, toolbar, sidebar and minimap now all draw, with
metrics transcribed from the macOS source and cited to the line, in both themes.

This section listed seven gaps when it was written. **Six of the seven have
since landed** (see §9 for the wave that closed them); the list is kept with
each item's disposition rather than deleted, because the ledger's value is that
it can be checked.

- ~~**Scrollbars.**~~ Landed in `099a68508`, with the search heat-map overlaid
  on them as macOS has it (`spdf_win_chrome_scroll.h`,
  `spdf_win_chrome_scrollbar.cpp`; `chrome_scroll_test`,
  `chrome_scroll_input_test`, `find_overlay_test` test_thin_marks).
- ~~**Find**, the regex checkbox, the match counter and the scrollbar
  heat-map.~~ Landed in `099a68508`, ported from
  `portable/linux/gtk4/spdf_search_internal.h` exactly as predicted and
  differentially tested against it — 37,440 comparisons, 0 differ
  (`search-differential-native.cmd`). Regex multiline is a real toggle since
  `95f1b1433`.
- **The Comments sidebar section** is still missing: Windows draws a "No
  Comments" placeholder and the core's annotation API has no caller. **OCR and
  translate landed** in `d52fadc22` (toolchain, jobs, panel, glue), with the
  first real installs' lessons in `1c5b5ddf3` and `443ee4603`.
- ~~**Menus and a command palette**: no `HMENU`, no accelerator table.~~ Menus
  landed in `86ae70cf3` as a popup from the toolbar's `…` — deliberately not a
  menu bar, because a Win32 bar cannot be themed (§4.7). The palette, Open
  Recent, reopen-closed and favorites landed in `f30842fdb`, with the filter and
  ranking ported from GTK and differentially tested (`54b9f9a64`).
- ~~**Open a file**: still command line only.~~ Landed in `86ae70cf3`
  (`IFileOpenDialog`, `WM_DROPFILES`, the `+` button and the overflow `…` now
  routed to real handlers). `.pdf` registration and the shell commands landed in
  `85ba7fad5`.
- ~~**The tab strip lives below the caption, not inside it.**~~ Hoisted: the
  client now owns `WM_NCCALCSIZE` and `WM_NCHITTEST` and paints its own caption
  buttons (`spdf_win_window_caption.h`, `spdf_win_chrome_caption.h`;
  `chrome_nc_test` 5,552 hit checks, `chrome_caption_paint_test`). The window has
  one header band, as macOS does. What remains is cosmetic — see §7 item 1.
- **Selection, links, printing** all landed (`86ae70cf3`, `e8cba79fa`), each with
  a differential against its original: selection 50,171 comparisons / 0 differ,
  print maths 1,944,132 / 0 mismatches. **Annotations are still untouched** and
  are the largest remaining reading gap; they also block the Properties dialog's
  comment count, which is passed as 0.

### 2.2 One thing the ledger did not mention

**The initial window size is driven by page 0's dimensions, and it is wrong for
small pages.** `initial_client_size()` (`spdf_win_main.cpp:242-252`) uses the
page size plus margins. Opening the 200×260 pt `golden.pdf` fixture produced a
**244×286** window — smaller than the caption buttons need, so Windows clipped
them. macOS instead opens at a fixed `1120 × 800` with a `560 × 380` minimum
(`ShenzhenPDFMac.mm:2912-2938`, `:69-70`) and clamps a restored size into
`[560 … min(2200, screenW−40)] × [380 … min(1600, screenH−40)]`.

Windows applies **no minimum at all**. This is a parity gap and a usability bug,
and it is only visible if you open a small document — which no headless test does.

---

## 3. Test results, natively

`portable/win/tests/run-tests-native.sh` — new, because `run-tests.sh` is a
macOS-side orchestrator that drives `prlctl`.

As measured in this session (2026-09-01):

```
37 cases, 29 passed, 0 failed, 8 blocked        exit 2 (BLOCKED is not a pass)
```

**That count is a snapshot and has moved twice since.** The audit in
`windows-feature-matrix.md` recorded 56 cases at `5677cc628`, and the parity wave
of 2026-09-02 (§9) took the inventory to **86** — `bash
portable/win/tests/run-tests-native.sh --list`, which needs no build and is the
only number worth quoting, because a track that drops
`tests/<name>_test.c` in the directory registers a case without touching the
runner. Do not copy a case count into another document; cite `--list`.

Newly passing here and previously registered nowhere: **all five orphaned core
suites** — `SPDFCoreOutlineTests`, `SPDFCoreRenderThemeTests`,
`SPDFCoreSelectionTests`, `SPDFCoreCJKSelectionTests` pass;
`SPDFCorePasswordTests` is BLOCKED only because it needs `qpdf` to generate
encrypted fixtures (`winget install qpdf.qpdf`). The handoff called this "the
cheapest outstanding win in the port"; it was. `CORE_SUITES` now registers
**nine**: the Markdown track added `SPDFCoreMarkdownTests`, which needs no MuPDF
at all.

The 8 blocked cases are honest blocks, each naming its missing prerequisite:
`layout.differential` needs glib and the GTK4 headers; the 7 cross-host PNG cases
need a **macOS host**, because `d2d-cases.sh` and `probe-cases.sh` do not compare
against committed references — they **compile the reference probe with `cc` on the
Mac at test time**. There is no committed reference image anywhere in
`portable/win/tests/`. (`portable/docs/windows-captures/` holds live screenshots, but
they are a RECORD, not test references -- a chrome screenshot pins four
subsystems at once and would fail for reasons unrelated to whatever changed.) Any plan to run the port's strongest evidence off a Mac has
to commit references first.

`layout.differential` no longer needs a Mac: §4.4's shim closed it, and
`portable/win/tests/layout-differential-native.cmd` runs it natively. It stays in
`CROSS_HOST` because the runner's own `layout.differential` case is the
macOS-driven one; the native script is the substitute and reports 395,514
comparisons, 0 mismatches. So the structural block on this box is **seven
cross-host cases plus the password suite**, and a complete run exits 2 even with
everything built.

### 3.1 Salvaging the Direct2D cases without a Mac

The four `d2d.*` cases' reference is just "a correct render of this page produced
without Direct2D" — and `spdf_win_probe.c` is portable C with zero Direct2D
references. So the same comparison runs entirely on Windows: probe (core → PNG)
versus the app (core → D2D → WIC → PNG). Four new cases, `d2d.compose-*`, all
byte-identical under `--strict` at tolerance 0.

They are **deliberately named differently**. They prove strictly less than the
cross-host cases — they cannot catch a Windows-vs-macOS divergence — and letting
a weaker test inherit a stronger one's name is how this repo's documents drifted
in the first place. Both sets are listed; the cross-host four stay BLOCKED.

### 3.2 A latent failure in the existing macOS-side `d2d.window-dark`

Found while checking whether the dark-theme fixes broke anything, and it matters
to whoever next runs `run-tests.sh` **from the Mac**:

`d2d_window_case` crops the composed canvas frame to page 0's printed `dest` rect
and compares it against a bare, chrome-free core render. macOS's dark theme
deliberately draws its page border **inside** that rect. So the moment the
Windows build draws the dark page border — which it now does, correctly — that
case must fail, in exactly the page's outermost ring.

Measured on a synthetic 40×40 page: **156 of 1600** pixels differ in dark, 0 in
light, and 156 is exactly the 1-pixel perimeter. This is a flaw in the case's
design, not in either renderer. `d2d-cases.sh` was **not** modified. The native
substitute handles it by asserting the frame is uniformly the colour the theme
declares and then comparing the interior — so the border is *tested*, not
tolerated. The macOS-side case needs the same treatment.

---

## 4. Defects found by looking, and fixed

The five the handoff named in §7.5 are all done and all verified in a live window
(§2). Two more were found by looking, both invisible to every existing test.

### 4.1 The dark page border blurred at fractional DPI

`draw_canvas_page()` drew the border with `strokeWidth = 1.0f * dpi_scale`. At
150% that is **1.5 device pixels**, which cannot land on the pixel grid however
it is inset: it covered one full row and half of the next, and the half-covered
row came out `#282828` against `#1E1E1E` paper. A blurry hairline where the whole
point of the hairline is crispness.

Fixed by rounding the stroke to whole device pixels. Measured after: rows 13 and
14 are both exactly `#333333`, row 15 exactly `#1E1E1E` — no blended row.

macOS cannot warn you about this. AppKit backing scales are 1× and 2×, where a
1 pt `lineWidth` is already 1 or 2 whole pixels. Windows' 125/150/175% steps are
why it needs saying, and it is the second time in this file that a Windows-only
DPI step has produced a defect (the first being §1's whole framing).

**An honest correction about how this was diagnosed.** I first attributed the
blur to the GPU window target (`D2D1_RENDER_TARGET_TYPE_DEFAULT`) rasterising
strokes differently from the headless SOFTWARE target. That was wrong. The real
cause of the *discrepancy* was my own comparison: I was rendering the headless
reference at `dpi_scale = 1.0` and comparing it against a `1.5` window, and the
border width is legitimately DPI-scaled. Page **layout** is DPI-independent here
(`dpi_scale` reaches only the LRU key and "actual size"), which is why the flawed
comparison passed for a long time and then failed only in dark — in light the
shade band falls outside the visible page rect on a tall page. A comparison that
passes in one theme and fails in the other looks exactly like a dark-theme bug.
`verify-phase1.ps1` now passes `--dpi` to the headless render, and the fix above
stands on its own merits: the 1.5 px stroke really did blur on screen.

### 4.2 No minimum window size

See §2.2. Not fixed in this session; filed here so it is not lost.

---

### 4.3 GPU and software Direct2D do not agree on resampling

Measured while checking the chrome against the headless compose, and it changes
what the port's pixel tests can be said to prove.

The window paints into an HWND target created with
`D2D1_RENDER_TARGET_TYPE_DEFAULT` (GPU). `spdf_win_render_scene_to_png` uses
`D2D1_RENDER_TARGET_TYPE_SOFTWARE`, deliberately, because the harness host may
have no display adapter. Where `DrawBitmap` resamples, the two rasterisers'
bilinear filters do not agree bit-for-bit, and disagree more the further the
scale is from 1:1:

| case | differing | max delta | MAE |
|---|---|---|---|
| 1426 px bitmap into a 1425.6 px slot | 0.76% | 2 | — |
| ~1000 px bitmap into a 208 px canvas | 11.2% | 43 | 0.60 |

Established rather than assumed: two runs of the same **window** are
byte-identical to each other, two runs of the **headless** path are
byte-identical to each other, and every differing pixel lies inside the page
bitmap — the gutter above it matches exactly, 0 of 2704 px.

**What this does and does not affect.** Every zero-tolerance case in this repo
compares SOFTWARE against SOFTWARE (`spdf_win_probe` versus
`--render-window-png`), so all of them are unaffected. What they do **not**
certify is the GPU window's resampled pixels. `verify-phase1.ps1` therefore
decides on MAE ≤ 1.0 with a max-delta ceiling, and says so in the script: a wrong
zoom, origin, fit mode, theme colour or a stale texture moves the mean by tens,
which is two orders of magnitude above the noise.

### 4.4 A "needs glib" block was softer than it looked

`layout.differential` has always been BLOCKED with "needs glib and the GTK4
headers". That is true of glib the **library** and not of the two pure headers
this port transcribes: they need typedefs, `MAX`/`MIN`/`CLAMP` and
`g_new0`/`g_free` and nothing else.

A shim supplying exactly those — with glib's own macro bodies character for
character, because the comparison order at the edges is part of what is being
checked — lets the **real** `portable/linux/gtk4/spdf_minimap_internal.h`
compile under MSVC beside the port in one binary: **131,503 comparisons, all
identical**, across strip layout, median/scale, hit-testing, both
document↔strip mappings, the viewport rect and the marker ticks. Same compiler
on both sides, so a difference could only be a transcription error.

`portable/win/tests/glib_shim/glib.h` is that shim. The same trick should
unblock `layout.differential` itself.

### 4.5 `verify-phase1.ps1` is sensitive to the saved session

`%APPDATA%\ShenzhenPDF\session.yaml` remembers the page each tab was on. The
window restores it; the headless reference renders page 0. So a session left
behind by earlier clicking makes the two legitimately disagree, and it presents
as three real failures with large deltas. Delete the session before a run, or
accept that the first run after any interactive poking is meaningless.


### 4.6 A locked workstation looks exactly like a broken window

The most convincing false positive this port has produced, and it cost a second
investigation after §5.1's.

Windows does not composite a locked session. The DWM-drawn title bar still
appears in a capture, because DWM has it cached, but a Direct2D client area
backed by a GPU surface does not: `PrintWindow` returns black or stale pixels,
and `CopyFromScreen` returns black for the **entire screen**.

What that presents as: the window paints nothing, `verify-phase1` reports three
hard failures with enormous deltas, and **it reproduces** — including from a
clean build of a known-good commit in a throwaway worktree. Commit `640ee4c3d`,
measured at 7 passed / 0 failed earlier the same day with a correct screenshot,
produced an identical black frame once the machine locked.

The tell was in hand the whole time and was misread as a curiosity: **the
offscreen compose of the very same binary stayed perfect.** Under this port's
own central rule — `spdf_win_paint()` needs no desktop — that is evidence *for*
the app, not a detail beside the failure. A regression that predates the commit
that supposedly caused it is not a regression.

There is an irony worth keeping. The entire reason nobody had ever seen this
window is that `prlctl exec` runs in a session with no interactive desktop. This
machine has one — until it locks.

Both scripts now refuse to lie about it. `screenshot-window.ps1` checks for
`LogonUI` **before** launching the app and exits **68**; `verify-phase1.ps1` maps
68 to BLOCKED for the whole run. A pixel backstop covers the cases `LogonUI` does
not name (disconnected RDP, a sleeping display, a GPU reset), and it samples the
**client** area rather than the framed window — because that distinction is
exactly what defeated the first attempt at the guard: with the title bar
composited and the client blank, the whole-window count was 7 distinct colours
and passed a naive uniformity test while the client area was 2.

Neither check can turn a bad frame into a pass. They only ever turn a FAIL into
a BLOCKED, which is the distinction the harness's BLOCKED convention exists for.

**Confirmed by unlocking.** The same commit, on the same machine, an hour later
with the workstation unlocked:

```
phase1[light]: 7 passed, 0 failed, 0 blocked   exit 0
phase1[dark]:  7 passed, 0 failed, 0 blocked   exit 0
```

Black while locked, green while unlocked, nothing changed in between. That closes
the diagnosis rather than leaving it as a plausible story, and the live captures
in portable/docs/windows-captures/ were taken in the same session.


### 4.7 Four defects only a person using the app could report

Reported 2026-09-02 from actual use, after every automated check in this port was
green: *"cannot be focussed or interacted with; runs from a terminal window that
stays open; does not respect the system theme; a double top bar like it's a
window inside of a window."* None of the four is visible in a `PrintWindow`
capture, which is why they survived.

**The terminal window.** The exe was linked `/SUBSYSTEM:CONSOLE` — confirmed by
reading the PE header (`Subsystem=3`) — because the entry point is `main()` and
no subsystem was ever specified. Now `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`,
for the app only; the test binaries stay console programs because a harness reads
their output. stdout still reaches a pipe or a file (subsystem controls only
whether a console is *allocated*), verified both ways before trusting it.

**The system theme.** This machine is set to dark and the app shipped light
unless told otherwise. It now reads `AppsUseLightTheme`. The ordering mattered
and was got wrong once: the canvas takes its render flags at construction, so
applying the theme after `spdf_win_tabs_app_show()` left the pages light while
the caption and thumbnails went dark. Headless paths deliberately do **not**
follow it, or every pixel comparison would depend on the developer's registry;
`--dark` and `--light` both override.

**The double top bar.** Half of it was a Win32 menu bar, which **cannot** be
themed: `SetPreferredAppMode(AllowDark)` darkens popup menus but not the bar,
measured — it stayed white between a dark caption and dark chrome. macOS keeps
its menus in the system menu bar, so an in-window strip was a bar macOS never
had; it is gone, and the toolbar's `…` opens the same menu. The other half is
the OS caption above the tab strip — macOS puts the strip *inside* the title bar
— and that integration is a separate change.

**"Cannot be focussed"** was not the app. Every measurement said healthy —
responding, enabled, answering `WM_NULL`, a `PostMessage`'d click toggling the
sidebar — yet physical clicks did nothing. `WindowFromPoint` across the app's
rect returned the **Claude desktop app** every time: maximized, foreground, and
the *parent* of the automation that launched the app, so the window opened
behind it and every real click landed on Claude. `PostMessage` and `PrintWindow`
ignore z-order, which is exactly why the automated evidence lied. Same session,
same user, same integrity, same desktop — the launch *parent* was the problem,
not the launch context. The real-world path (double-click the exe) has no such
parent, and was impossible: the app exited 64 without a document. It now
launches bare, restoring the session or opening an empty window.

Two harness lessons from the same afternoon: PowerShell's `&` does not wait for a
GUI-subsystem process, so `verify-phase1` silently compared the whole client and
failed three criteria with no error message; and a stray-process check that
counts by *name* fails whenever the user has their own instance open. Both fixed.


### 4.8 The phantom second: launch is ~50 ms, the tool that timed it was not

Setting out to make launch "feel instant", the first measurement said the
app took a constant ~1.0 s to do anything headless: `--render-png` on a
1.8 KB two-page fixture, `--render-window-png --chrome`, even a *missing
file* all came in at 1,011-1,029 ms, while the window itself appeared in
45-88 ms. A constant that survives removing the document is not document
work; the suspicion was a fixed wait at exit.

It was neither. The runs were timed with PowerShell's
`Start-Process -Wait -RedirectStandardOutput`, and that cmdlet adds about a
second of pipe teardown to every process it waits for. Polling
`$p.HasExited` instead, with `t0` taken before launch (`$p.StartTime` is
invalid once the process is gone):

| path (warm, published build) | polled |
|---|---|
| usage text and exit 64 (no factory, no MuPDF) | 30 ms |
| `--render-png` golden.pdf, PNG on disk and process gone | 57-124 ms |
| window visible, outline.pdf | 45-88 ms |
| WM_CLOSE to process gone | 16-39 ms |

So there is no stall to remove: process start to a visible window is a
few tens of milliseconds, an order of magnitude under the GTK profile's
769 ms `first-window-present` (`gtk4-captures/launch-profile.txt`) that
motivated Linux's resident mode. What is *not* yet measured is
launch-to-first-page-pixels: the ad-hoc PrintWindow sampler written for
it returned blank frames (the repo's `screenshot-window.ps1`, which makes
its host DPI-aware and waits for settle, is the capture path that works),
so the number the reader actually feels still needs an in-process
timeline. That is the launch track's first deliverable, not another shell
stopwatch.

The lesson generalises: two other tool-layer artefacts in the same
session produced false conclusions -- in Git Bash, `cmd /c` has its `/c`
rewritten to `C:\` by MSYS path conversion, so a build driver "succeeds
in one second" having run nothing (use `cmd //c`), and a `build exit=0`
read that way green-lit a commit that did not compile. Judge by an exit
code, yes -- but first make sure the exit code belongs to the program you
think ran.

## 5. New tooling, and why each exists

| file | why |
|---|---|
| `portable/win/screenshot-window.ps1` | Makes "look at the window" a command. `PrintWindow` with `PW_RENDERFULLCONTENT` (mandatory for a D2D client area), enumerates windows by pid rather than trusting `MainWindowHandle`, reports the client offset so a capture can be cropped to exactly what `spdf_win_paint` drew, and **always** closes the app it started. |
| `portable/win/verify-phase1.ps1` | Turns Phase 1's five criteria into one exit code. Compares the live client area against the headless compose at the same size *and the same DPI*. |
| `portable/win/build-native.cmd` | The native build the port never had. Discovers `portable/win/src/*`, lists `portable/core/*` explicitly, links MuPDF when present. |
| `portable/win/tests/run-tests-native.sh` (+ `.lib.sh`, `.d2d.sh`) | The harness, natively. Honours the in-file `spdf-test-*` directives, registers the five orphaned core suites, BLOCKS rather than skips. |
| `portable/win/mupdf-gen-ninja-native.sh`, `mupdf-native-build.cmd`, `mupdf-arch-check-native.cmd`, `mupdf-native-linkcheck.c/.cmd` | MuPDF for x64, still derived from `mupdf/Makefile`'s own recipe via `make -n` so both hosts compile the same MuPDF. 646 translation units in 14 flag groups, 417 + 229 objects — the same counts as the ARM64 build. |
| `portable/win/src/spdf_win_tabstrip.h` + `tests/tabstrip_geometry_test.c` | Tab-strip geometry transcribed from `SPDFMacTabStripView.mm` and `SPDFMacTabStripGeometry.h`, toolkit-free and header-only, 741 assertions. |
| `portable/win/src/spdf_win_chrome*.{h,cpp}` + `tests/chrome_geometry_test.c` | The chrome itself: how the client area divides (3807 assertions), the theme, the painters (strip / toolbar / sidebar / minimap), the model, the input router (94,240 assertions). All HWND-free, so `--render-window-png --chrome` composes the whole window offscreen. |
| `portable/win/src/spdf_win_minimap.h` + `tests/minimap_differential.c`, `tests/glib_shim/` | The GTK4 minimap geometry, ported and then differentially tested against the **real** GTK header under MSVC: 131,503 comparisons, all identical. See §4.4. |
| `portable/win/tests/layout-differential-native.cmd` | Runs `gtk_differential.c` natively — **395,514 comparisons, 0 mismatches**. This is the port's strongest test and had been BLOCKED as "needs glib" since the beginning. Proven to bite: perturbing the ported fit-width zoom by one part in 10⁷ gives 17 mismatches. The two `spdf_lru_*` halves stay skipped, because glib leaves hash iteration order unspecified and a shim would report mismatches that are not transcription errors. |
| `portable/win/src/spdf_win_search.*`, `spdf_win_chrome_find.*` + `tests/search_differential.c` | Find/search, with the GTK4 search header ported and differentially tested: 37,440 comparisons, 0 differ. |
| `portable/win/src/spdf_win_window_caption.h`, `spdf_win_chrome_caption.h` + `tests/chrome_nc_test.c`, `tests/chrome_caption_paint_test.c` | The client-owned caption: `WM_NCCALCSIZE`, `WM_NCHITTEST` from the painter's own geometry, and the three caption buttons painted from model state so the paint path still needs no `HWND`. 5,552 hit-test checks; the button pixels pinned in both themes. |
| `portable/win/drive-window.ps1` | Drives the live window with synthetic `PostMessage` mouse input and captures after each step. `PostMessage`, not `SendInput`, deliberately: the user is sitting at this machine and `SendInput` would move their real cursor. |
| `portable/win/tests/fixtures/outline.pdf` + `make_outline_fixture.py` | No committed fixture had a document outline, and neither does the NASA scan — so the sidebar's chapter list, its nesting and its UTF-8 titles were untestable. This one carries an accented and a CJK title, which is what a narrow CP1252 conversion mangles silently here. |

### 5.1 The capture host must be DPI-aware — this cost real time

`powershell.exe` is not per-monitor DPI aware. When a DPI-unaware process calls
`GetWindowRect`/`GetClientRect` on a window owned by a per-monitor-aware process,
Windows **virtualises** the answer: it reported a 1680×1200 window as 1120×800.
Allocating a bitmap of that virtualised size and calling `PrintWindow` then
captures only the window's top-left 1120×800 *physical* pixels — a crop at true
scale.

That produces an extremely convincing false positive: the page appears ~1.5×
too large and clipped, the ratio equals the DPI scale, and it reproduces every
time. It points straight at the app's DPI handling, which is precisely the
criterion nobody had ever verified. **The app was correct the whole time.**
`SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` at script start is what
makes every number in this file mean what it says.

Anyone writing a Windows capture harness for this project needs to know this
before they write it, which is why it has a section rather than a footnote.

---

## 6. Corrections to `windows-port-handoff.md`

Verified against the tree; the tree wins.

- **The fixture SHA256s are wrong.** §1.3 gives `golden.pdf` as
  `00432a55a58dbfe1…` and `alpha.pdf` as `32c0e3b9de92eeeb…`. Actual:
  `56dd60224d1c17049b03fe7fd2de0296e376dde51ee13f1d8e579109355b7881` and
  `d44f1dbffbad43b2e692dd61bcb6fb05502f7f933086de8dce5bf9a4bf92c64c`. Not stale:
  `golden.pdf` has only ever had **one** commit. Confirmed intact, not mangled by
  a Windows checkout — `.gitattributes` sets `* -text` and `git hash-object`
  matches the committed blob. Do not "fix" the fixtures to match the doc.
- **§3.3's line numbers for the surround colours moved**: dark is `:303` and
  light `:305` at HEAD, not `:302`/`:304`. Everything else §3.3/§3.4 cites was
  accurate.
- **Windows' window title was wrong in two more ways** than "it never updates":
  it used an em dash and `ShenzhenPDF` with no space, where macOS uses
  `"<name> - Shenzhen PDF"`.
- **§3.5's tab stroke description is incomplete**: the tree is
  `lineWidth = selected ? 1.4 : 1.0`, and an unselected non-missing tab is not
  stroked at all.
- **`spdf_win_layout.h`'s header referenced `portable/win/tests/layout_transcript_test.c`,
  which does not exist and never has.** Fixed: the header now cites
  `layout_geometry_test.c` for the numbers and `gtk_differential.c` (run by
  `layout-differential-native.cmd`) for the comparison against the real GTK
  header, and says plainly that no transcript test exists.
- The handoff's own §3.1 misses two useful reference sets that are committed:
  `portable/docs/gtk4-captures/` (24 PNGs) and `portable/docs/linux-captures/`
  (13 PNGs). They are the GTK4 frontend, not macOS, but they are real screenshots
  of the same document behaviour.

---

## 7. What I would do next, in order

**Six of these nine are done.** Each is marked with the commit that did it
rather than deleted, so the list stays checkable and so a reader can see which
predictions in it held. The three that remain all need a machine this one is
not.

1. ~~Scrollbars~~, ~~Find~~ and ~~the tab strip into the title bar~~ — **done**
   (`099a68508`, `86ae70cf3`). The window has one header band, as macOS does;
   the "double top bar" is closed. The two cosmetic remainders named here — no
   1 px top border when windowed, and the maximized edge — are closed too:
   `extend_frame_into_strip()` in `spdf_win_window_caption.h` calls
   `DwmExtendFrameIntoClientArea` with the full caption height when windowed
   (which is what keeps DWM drawing the shadow, the rounded corners and the 1 px
   frame) and with nothing when maximized or full screen, because a non-zero
   margin over a borderless popup draws a DWM strip along its top edge.
2. ~~**Find.**~~ **Done** (`099a68508`), and the prediction held exactly:
   `spdf_search_internal.h` was ported the way `spdf_win_layout.h` was and
   differentially tested with §4.4's shim — 37,440 comparisons, 0 differ. The
   results half followed in `a22c17cb4`/`5e0afbe7b` with its own differential.
3. ~~**A minimum window size and a sane default** (§2.2).~~ **Done**
   (`099a68508`, extended by `c8c8ed557`): `WM_GETMINMAXINFO` → `min_track_size`
   in `spdf_win_window.cpp`, and `initial_client_size()` in
   `spdf_win_session_app.h` now clamps a restored or default size into
   `[MIN_CONTENT … RESTORE_MAX]` against the monitor's **work** area, defaulting
   to macOS's 1120×800 with a 560×380 floor. §2.2's 244×286 window with clipped
   caption buttons cannot happen again.
4. ~~**Wire the sidebar's row clicks.**~~ **Done** (`5e0afbe7b`), along with the
   segmented Chapters/Comments/Search control, the results rows and their
   snippets. The Comments section is still a placeholder because annotations are
   not ported.
5. ~~**`SPDF_WIN_ZOOM_FIT_HEIGHT` on the canvas.**~~ **Done** (`099a68508`);
   `--fit height` is a real mode and `menu_test test_fit_keys_match_the_other_two_frontends`
   pins the accelerators against the other two frontends.
6. **Commit macOS reference PNGs** — still open, and now the largest single
   verification gap. §3 makes the cost concrete: seven cases are blocked on it
   permanently for anyone without a Mac, and they are the only cases that can
   catch a Windows-vs-macOS divergence.
7. **Fix `d2d-cases.sh`'s `d2d.window-dark`** — still open. `d2d-cases.sh` has
   not been touched since `833e0d527`, so the flaw §3.2 measured is still there
   and will fire the moment someone runs the suite from a Mac. Fix it before
   they hunt a Direct2D bug that is not there.
8. **Measure x64 ↔ ARM64 byte-identity**, or restate the claim as ARM64-only —
   still open, and needs a machine with both. It is written as a property of the
   port and is really a property of one pair of machines.
9. ~~**Move the tab strip into the caption.**~~ **Done** — see item 1. It was a
   subsystem, as predicted: `WM_NCCALCSIZE`, `WM_NCHITTEST` from the painter's
   own geometry and three caption buttons painted from model state, so the paint
   path still needs no `HWND`. `chrome_nc_test` runs 5,552 hit-test checks and
   `chrome_caption_paint_test` pins the button pixels in both themes.

---

## 8. Reproducing everything in this file

```
portable\win\mupdf-native-build.cmd --clean          :: MuPDF, x64, ~70 s
portable\win\mupdf-arch-check-native.cmd             :: all 646 members 8664
portable\win\build-native.cmd                        :: ShenzhenPDF.exe
bash portable/win/tests/run-tests-native.sh --list   :: the inventory: 92 cases
bash portable/win/tests/run-tests-native.sh          :: the run; exit 2 here (7 cross-host + qpdf)
portable\win\verify-phase1.ps1 -Exe %SPDF_OUT%\ShenzhenPDF.exe -Pdf <a.pdf>
portable\win\verify-phase1.ps1 -Exe %SPDF_OUT%\ShenzhenPDF.exe -Pdf <a.pdf> -Dark
```

Set `SPDF_OUT` to a private directory if another track is building, and point
`SPDF_MUPDF_LIBDIR` at the shared `C:\spdf-build\mupdf` so the private build does
not have to rebuild 74 MB of MuPDF. The user's own running instance holds a lock
on `ShenzhenPDF.exe`, so a shared `SPDF_OUT` fails to link rather than
mysteriously testing yesterday's binary. `portable/win/README.md` has the table.

From Git Bash, `cmd /c` is **`cmd //c`**: MSYS rewrites a bare `/c` to `C:\`, so
`cmd /c build-native.cmd` runs nothing and exits 0 (§4.8). Every one of the
commands above is judged by its exit code, and none of them decides anything by
piping output through `grep`.

---

## 9. The parity wave of 2026-09-02

Seven tracks were developed in parallel worktrees and merged into `master` on
2026-09-02, taking the port from "the chrome draws" to "most of the reader
works". Each merge is a first-parent merge commit with the track's own commits
under it; `git log --merges --first-parent` lists them in reverse order.

| merge | track | what landed, and what pins it |
|---|---|---|
| `32e4271c9` (+ `b5c21bb3a`) | **Markdown** | Markdown opens as paginated pages through **MuPDF's HTML engine** rather than a transcription of the 18,138-LOC AppKit reader (`portable/core/spdf_markdown*.c`, `spdf_win_md*`). Pinned by `SPDFCoreMarkdownTests` (no MuPDF needed), `markdown_core_test`, `markdown_open_test`, `md_win_test`; the decision and the phased plan are in `windows-markdown-design.md`, and four live Markdown captures are in `windows-captures/` |
| `2a1a452d8` | **Search** | the chapter-grouped **results sidebar**, centred scroll-to-match, a **clickable** minimap, type-anywhere search, and a pointing hand over plain-text URLs. A new `sidebar-differential-native.cmd` compares the result grouping against `spdf_sidebar_internal.h`, and the minimap's input policy was folded into the existing minimap differential (`minimap_differential_input.h`); plus `sidebar_rows_test`, `find_overlay_test`, `link_test`, `canvas_selection_test` |
| `76a51bbb1` | **Docs/state** | `documents.yaml` and `favorites.yaml` written the way the other two frontends write them; the **palette** with Open Recent, reopen-last-closed and favorites; **password prompts** and the **file watcher** (auto-reload, read-only shadow copy). `palette-differential-native.cmd` and `watcher-differential-native.cmd` compare the ported halves against their GTK originals; `palette_filter_test`, `palette_model_test`, `recents_test`, `password_test`, `password_flow_test`, `watcher_logic_test`, `watcher_test` |
| `a9348b0b3` | **Window** | **presentation mode**, full screen, a **second window**, session fidelity (frame, query, detaching), `settings.yaml` read and written, print **scaling** UI — and the one-line fix that stops **Escape closing the window** when nothing is focused, which §7's predecessor list called a real usability hazard. `settings_test`, `session_frame_test`, `window_keys_test`, `print_scaling_dialog_test` |
| `68bb691b6` | **Shell** | the exe's **identity** (icon, per-monitor-v2 manifest, version block, About box), `.pdf` **registration**, the F1 **shortcuts sheet generated from the menu table**, Explorer reveal and the other shell commands, and the **auto-updater** ported with Authenticode trust and a self-replacing exe. `about_test`, `assoc_test`, `shortcuts_test`, `shell_test`, `shell_windows_test`, `updater_feed_test`, `updater_verify_test`, `updater_install_test`, `updater_store_test` |
| `5b224fd11` | **Tools** | **OCR and translation**: toolchain acquisition, job running, the live-log panel and the glue. The first real installs cost two revisions — Ghostscript dropped, Argos put in a venv, the tools' data kept out of `AppData`, `TESSDATA_PREFIX` completed. `ocr_test`, `translate_test`, `toolchain_test`, `toolchain_run_test`, plus the `tools_e2e.sh` and `tools_panel.sh` probes |
| `03fa9f15a` | **Launch** | launch **measured** from process creation to first page (§4.8 left this as the open question), the Direct2D device created on a worker before the first paint needs it, and a `launch.budget` case in the suite. `windows-launch-performance.md` carries the bar, the baseline, the diagnosis and the patch for files other tracks own |

Two things the wave changed about how to read the rest of this file:

- **The counts moved.** 37 cases in §3 → 56 at the audit → **86** today. LOC
  under `portable/win/src/` went from 5,021 (the number
  `portable/win/README.md` carried for months) to **46,968** across 195 files,
  and the differentials from six to **nine**.
- **`windows-feature-matrix.md` is the feature-status authority**, audited
  against a built and run tree rather than from memory. §2.1 and §7 above are
  now a record of what this session predicted and how it turned out; where they
  disagree with the matrix, the matrix is newer. The handoff's §1.4 ledger and
  the plan's §0/§4 phase status are older than both.

---

## 10. The live-verification pass of 2026-09-03

Every visual claim in this port had been checked headless; §4.6 records why the
live half kept coming back BLOCKED — the workstation was locked for the whole
parity wave, and a locked session is not composited. **This section is that pass
re-run unlocked**, at HEAD `0fb7d8d92`, against a build made for it
(`SPDF_OUT=C:\spdf-build\track-live`). It replaces no earlier section; where it
contradicts one, it says so.

Same machine as §1: x64 Ryzen 5 6600U, Radeon 680M, Windows 11 26200, one
144 dpi (150%) display, 2880×1800 physical.

### 10.1 Phase 1 is 7/7 in both themes, on a composited desktop

```
verify-phase1.ps1 -Exe <track-live exe> -Pdf portable\win\tests\fixtures\outline.pdf
    light:  7 passed, 0 failed, 0 blocked   exit 0
    -Dark:  7 passed, 0 failed, 0 blocked   exit 0
```

Criterion by criterion, identical in both: the window opens (352 ms light /
377 ms dark to a visible `ShenzhenPDFWindow` titled `outline.pdf - Shenzhen
PDF`); the host is per-monitor-v2; the **canvas region 368,126,509,663 matches
the headless compose** inside the script's MAE ceiling; DPI is correct at
144 dpi (1.5×); all three resize sizes (900×700, 1300×900, 700×520) repaint
correctly against their own headless renders; `WM_CLOSE` exits 0; and nothing
this run started was left behind.

Nothing had to be fixed to get there. **All three failures the last locked run
reported were the black frame and only the black frame** — which is what §4.6
predicted and what could not be shown until now.

### 10.2 A defect only a live window could find: `--find` is dead on the windowed path

`--find <text>` on a **windowed** launch does nothing at HEAD. The find field
stays empty, the sidebar's Search segment never appears, and no match is
highlighted. `--render-window-png --chrome --find fixture` — the headless path —
is unaffected, which is why no test caught it and why capture
`07-search-section-headless.png` looks right.

The proof is in the captures directory's own history:
`windows-captures/01-window-light.png`, taken 2026-09-01 with the same flag on
the same fixture, shows `fixture` in the field, the Search segment present, the
match ringed and the scroller's heat-map ticks. `08-window-light.png`, taken
today with the same command, shows none of it. **01 is deliberately left in
place as the before-picture.**

One line causes it. `main()` parses `--find` into `a.find_text`
(`spdf_win_main.cpp:265`) and pushes it (`:292`), and then, inside session
restore, calls `app_restore_find_text(&a)` (`:417`), whose first act is

```c
a->find_text[0] = L'\0';
```

before refilling the field from the *selected tab's* remembered `search_text`
(`spdf_win_session_app.h:59-68`). A tab opened by this launch has none, so the
command line's query is overwritten with the empty string before the first
paint. The per-tab query restore is right and wanted — it is what makes Ctrl+Tab
bring back the query you left in a document — it simply has no case for "the
command line already asked for one". Not fixed here: this pass owns no source
file. The fix belongs with whoever owns `spdf_win_main.cpp`, and its shape is to
let an argv-supplied query win over an empty remembered one.

The feature itself is fine, which is the useful half of the report: typed into
the field (`drive-uia.ps1 cmd:26` then `type:fixture`) the whole thing works
live — four results grouped under their chapter headings with "match *n* of 4",
the active match ringed red over yellow, ticks on the scroller and yellow marker
bars inside the minimap thumbnails. That is
`windows-captures/11-search-results-live.png`, the first live picture of the
Search section; 07 could only be composed offscreen.

### 10.3 Modal windows, driven for real (gap 16)

`windows-feature-matrix.md` gap 16 — "modal windows verified live" — was the
largest hole in the port's evidence, and `drive-window.ps1` is the wrong tool
for it: it clicks CLIENT COORDINATES, which is right for chrome the app paints
itself and wrong for a dialog whose controls are child windows this repo does
not lay out, and a modal dialog runs its own message loop, so the app's window
stops answering the "is it alive" probes at the same moment.

`portable/win/drive-uia.ps1` is the new tool: UI Automation to find and read the
dialog, control ids to press it, `PrintWindow` to capture it, and it never moves
the reader's cursor. Driven and captured this pass:

| dialog | class | driven | evidence |
|---|---|---|---|
| Keyboard Shortcuts (F1) | `SpdfWinShortcutsSheet` | opened by `cmd:55`, dismissed by Escape | `15-shortcuts-sheet.png` |
| About | `SpdfWinAboutBox` | `cmd:56`, Escape | `16-about-box.png` — 26.9.2 (build 1), MuPDF 1.27.2 |
| Add Comment | `SpdfWinAnnotDialog` | `cmd:63` after a page click, both fields typed, **Add pressed** | `14-add-comment-dialog.png`, then `12-comments-sidebar.png` |
| `--install`'s completion box | `#32770` | **OK pressed**, process exited 0 | §10.4 |

The annotation chain is the one worth stating whole, because it is what the
matrix's annotations row lists as untested: a click on the page, Add Comment,
author and text typed, Add — and then a note marker on the page, a `Page 1`
group header in the **Comments** section, and a `Reviewer: Check this heading
agains…` / `Text - Page 1` row under it. The whole flow, live, end to end. It
also settles where the annotation goes: **into the document**, which grew from
6,449 to 7,264 bytes. Never run this against a committed fixture in place; the
one that was is restored and re-checked against `make_outline_fixture.py`'s own
output (`sha256 d757157117610c4d…`).

**One trap, and it is a trap for the report rather than for the app.** Through
`System.Windows.Automation` on this box, every child of every dialog comes back
as `ControlType.Pane` with the control id as its `AutomationId`, the window text
as its `Name`, and **no `InvokePattern` and no `ValuePattern`** — so a
UIA-pattern driver can press nothing. That looks exactly like an accessibility
defect in the app's dialogs, and it is not: `--install`'s **stock `MessageBoxW`**
reports its OK button — a plain `L"BUTTON"` in a plain `#32770`, the most
accessible control in Windows — the same way, `type=Pane name='OK' id='2'
invokable=False`. When the OS's own message box comes back like that, the missing
piece is the standard-control proxy providers on the client side.
**Do not report these dialogs as inaccessible on this evidence.** They are built
from real `L"EDIT"` and `L"BUTTON"` children
(`spdf_win_annot_dialog.cpp:203-243`); `drive-uia.ps1` presses them by control id
through `GetDlgItem`, and its `tree` step still prints what UIA can see, which is
how the limitation was found.

A second trap, cheap to hit and expensive to notice: `GetWindowTextW` on another
process's EDIT control returns the CACHED window text, not the field's content.
`childtext:1101=Reviewer` reported `text='sagan'` and had worked perfectly — the
capture shows `Reviewer`. Judge a `WM_SETTEXT` by the picture or by the outcome,
never by reading it back that way.

### 10.4 The first-run dialog: still not drivable, and the gate is why

**This is the one deliverable of the pass that could not be met, and it is no
longer the lock's fault.** The task was to press the three command links of the
"Run this copy / Install / Install and run" TaskDialog for real. It cannot be
done on this machine without writing into the reader's live
`%APPDATA%\ShenzhenPDF`, and the reason is a deliberate line in the gate.

The dialog appears only when `spdf_win_setup_first_run_action()` returns ASK,
which needs all six of its inputs to say "ask"
(`spdf_win_setup_first_run.h`). Five were confirmed absent by measurement: no
`--install/--uninstall/--quiet/--purge/--portable/--state-dir` on the command
line, no `ShenzhenPDF.portable` beside the exe (a scratch copy alone in an
otherwise empty directory), not running from the install directory, and nothing
installed — `%LOCALAPPDATA%\Programs\ShenzhenPDF`, the per-user Start Menu
`.lnk`, `HKCU\…\Uninstall\ShenzhenPDF` and the ProgID were all verified absent
before and after. The sixth is `answered`, read from `settings.yaml`'s
`setupPromptAnswered`.

A bare launch of that scratch copy — the one intentional bare launch, killed
while modal so nothing could be committed — **went straight to a window.** So
`setupPromptAnswered` is already true in the real state directory, written by
the setup track's own live verification of the install cycle (whose matrix row
records that it "verified live on the real per-user locations and fully restored
afterwards"). Clearing it means writing the reader's `settings.yaml`.

And the redirection that exists for exactly this kind of test cannot help,
because it suppresses the very thing it would isolate:

```c
/* spdf_win_setup.cpp:418-423 */
if (!explicit_flag &&
    (GetEnvironmentVariableW(SPDF_WIN_SETUP_NO_PROMPT_ENV, NULL, 0) > 0 ||
     GetEnvironmentVariableW(SPDF_WIN_SETUP_PROFILE_ENV, NULL, 0) > 0 ||
     GetEnvironmentVariableW(SPDF_WIN_SETUP_ROOT_ENV, NULL, 0) > 0))
    explicit_flag = 1;
```

`SPDF_WIN_SETUP_ROOT` redirects the install directory, the Start Menu, the
registry and the purge target — and is itself a reason not to ask. `--state-dir`
would redirect the settings the answer is remembered in, and is also a reason
not to ask. **So "the prompt is shown" and "nothing real is written" are
mutually exclusive as the gate stands**, and after the first answer on any
machine the dialog becomes permanently unreachable there. That is a testability
defect, not a correctness one: the truth table is right and `setup_test.c`
covers all 64 rows.

The smallest honest fix is a suppressor that redirection can distinguish from
intent — treat `SPDF_WIN_SETUP_ROOT` as "redirect but still ask", or add an
`SPDF_WIN_SETUP_FORCE_PROMPT` honoured only alongside it. Either would make the
three links pressable with nothing real on the line. Until then there is no
capture of this dialog, and the `11-first-run-dialog.png` this pass was asked
for does not exist.

**What was driven instead**, all under `SPDF_WIN_SETUP_ROOT` pointed at a
scratch directory, which exercises every consequence the three links have except
the remembered answer:

| the link | what it does | what was verified live |
|---|---|---|
| **Install** | `spdf_win_setup_install(quiet, NULL, 0)` | `--install --quiet` exit **0**; `<root>\Programs\ShenzhenPDF\ShenzhenPDF.exe` (41,620,480 bytes); `<root>\Start Menu\Programs\ShenzhenPDF.lnk` whose `IShellLinkW` target and working directory read back as the installed exe and its folder; ten `Uninstall\ShenzhenPDF` values incl. `DisplayVersion 26.9.2`, `EstimatedSize 40645`, `UninstallString "…" --uninstall`, `NoModify`/`NoRepair` 1; the whole ProgID tree (`ShenzhenPDF.Document`, `Applications\ShenzhenPDF.exe`, `.pdf\OpenWithProgids`, `RegisteredApplications`, `ShenzhenPDF\Capabilities`). **No window opened** — asserted with an `expect-no-dialog` step, not assumed. Run again without `--quiet`, its completion `MessageBoxW` was captured and its **OK pressed**, exit 0 |
| **Install and run** | the same with `relaunch = 1` | the relaunch is suppressed under the redirection **on purpose** (`spdf_win_setup.cpp:207`: "an installed copy pointed at a scratch directory is not a thing anyone wants to see start"), so the second half was verified by launching `<root>\Programs\ShenzhenPDF\ShenzhenPDF.exe` directly: it opens a window titled `outline.pdf - Shenzhen PDF`, raises no dialog (it *is* the installed copy, so the gate does not ask), and exits 0 |
| **Run this copy** | remember the answer, then run | the "run" half is every other launch in this pass. **The "remember" half is not verified**: it writes `setupPromptAnswered` into the active state directory and is reachable only from the dialog |

Then `--uninstall --quiet --purge`, exit **0**, and the machine proved clean.
Gone: the install directory, the installed exe, the `.lnk`, the `Uninstall` key,
`ShenzhenPDF.Document`, `Applications\ShenzhenPDF.exe`, the `Capabilities` tree,
the `RegisteredApplications` value, and the redirected state directory the purge
was aimed at. **Ten keys survive and all ten are correct**: they are empty shared
containers — `Software\Classes\.pdf\OpenWithProgids`,
`Software\RegisteredApplications`, `…\CurrentVersion\Uninstall` and their
parents — holding no value at all. On a real profile those belong to the shell,
not to the app, and an uninstaller that deleted them would be the bug.

The real per-user locations were verified absent before the cycle and absent
after: no install directory, no Start Menu `.lnk`, no
`HKCU\…\Uninstall\ShenzhenPDF`, no `ShenzhenPDF.Document`, no
`ShenzhenPDF.pdf`, no `RegisteredApplications` value. The scratch root and the
`HKCU\Software\ShenzhenPDF-setup-test` key were both deleted afterwards.

One asymmetry found while setting the purge up, worth knowing before writing a
test against it: `SPDF_WIN_SETUP_ROOT` redirects `setup_state_dir()`, which is
what `--purge` deletes and what the completion message names, but it does **not**
redirect the app's runtime state directory — `spdf_win_paths.c`'s
`resolve_roaming_dir()` calls `SHGetKnownFolderPath(FOLDERID_RoamingAppData)`
and knows nothing about the variable. So a redirected app writes its session and
settings to the REAL `%APPDATA%\ShenzhenPDF` while a redirected `--purge` aims at
`<root>\Roaming\ShenzhenPDF`, which nothing ever fills. The purge above had to be
given a file to delete before it could be seen to delete one.

### 10.5 Two harness bugs of this pass's own making, both worth keeping

**A name-based process sweep closed another track's app.** The first version of
`drive-uia.ps1`'s cleanup enumerated `Get-Process -Name ShenzhenPDF` and closed
anything newer than its own launch. It found and closed a
`C:\spdf-build\track-settings\ShenzhenPDF.exe` belonging to another agent's build
tree. This is §4.7's trap — the one that made `verify-phase1.ps1` report a false
leak — in a worse form, because that one only mis-reported and this one acted.
The rule that follows is not "compare start times": it is that a harness may only
close a pid that was **absent from a snapshot taken before its own launch** *and*
whose image path is one this run launched. `drive-uia.ps1` now requires both.

**A PowerShell function returns its output stream.** A capture helper that wrote
three `Write-Output` lines and then `return 0` handed the caller a four-element
array; `if ($rc)` read it as true and `exit $rc` threw. The visible symptom was a
run that stopped silently mid-way with no error text and a stale exit code —
which reads exactly like the app hanging. Step results now travel in a
script-scope variable.

A third, milder one: `SetProcessDpiAwarenessContext` succeeds once per process,
so a script taking several captures from one PowerShell session reports
`host_dpi_aware=True` for the first and `False` for the rest while remaining
fully aware. `verify-phase1.ps1` never sees this because it spawns a fresh
`powershell -File` per capture. Do not read that second `False` as §5.1's
virtualisation trap.

### 10.6 What is still not verifiable, and why

- **The first-run dialog's three command links** — §10.4. Needs a gate change,
  not an unlocked desktop.
- **"Run this copy" remembering the answer** — same cause.
- **The Open and Save pickers, and a print job end to end.** Not attempted:
  the pickers are shell dialogs that would browse the reader's own filesystem,
  and printing needs a printer. `drive-uia.ps1` is now the tool for the first two
  when someone wants them.
- **x64 ↔ ARM64 render identity** — still needs a Mac (§1); being unlocked
  changes nothing about it.
- **The reader's live state directory was modified during this pass, and not by
  it.** `%APPDATA%\ShenzhenPDF\documents.yaml` and `settings.yaml` changed at
  18:29-18:30 while this pass ran. Every launch here carried an explicit
  `--state-dir` (visible in each harness's echoed `args=` line) except the two
  `--install`/`--uninstall` invocations, which return before the settings layer
  is reached (`spdf_win_main.cpp:127-132`), and the one bare launch, which was
  killed while modal eleven minutes earlier. Other agents were building and
  launching the app on this machine at the time and are the likely author. It was
  not checked by reading the files, and should not be: they are the reader's.


## 11. Two launch defects a person found that no test did (2026-09-05)

"When I launch the app from dist I can't interact with it at all, not even
focus it with Alt+Tab." Every test was green; the app's own window was visible,
enabled, foreground and answering messages. Two defects, both from the launch
work merged the day before:

1. The GPU prewarm created a top-level WS_OVERLAPPEDWINDOW on a worker thread
   and then parked that thread forever without pumping. To Windows that is a
   HUNG window for the life of the process: every desktop broadcast stalls on
   it for its timeout, the shell's enumeration of the process slows to the
   same timeout, and activating the app's real window becomes unreliable.
   Measured with IsHungAppWindow: true from seconds after launch until exit,
   on that window and the IME window it owned. It is now a WS_POPUP tool
   window (excluded from Alt+Tab and the taskbar by definition) whose thread
   parks in MsgWaitForMultipleObjects and dispatches what arrives.
2. spdf_win_window_show() never asked for the foreground. ShowWindow maps a
   window; it does not decide who is in front, and the launch now does about
   145 ms of work before showing anything so the window appears complete.
   The launching window had the foreground back by then and the app arrived
   at z-order position 1, underneath it, with a sliver to click. It now calls
   SetForegroundWindow, BringWindowToTop and SetFocus, and flashes the
   taskbar button when the system refuses.

Verified from Explorer with another app maximized and focused: before, the
app sat at z-index 1 behind it; after, z-index 0, foreground, and still there
two seconds later, with no hung window in the process.

The lesson for the harness: headless composes and even live captures cannot
see a z-order or a hung-window problem. A launch check that asserts "is the
foreground window AND at z-index 0 AND no window of the process is hung"
would have caught both in the launch budget case. It now does: `measure-launch.ps1`
records, per run and while the window is up, whether it is the foreground window,
its z-index among Alt+Tab-sized visible top-level windows, and how many windows
of the process `IsHungAppWindow` reports. Before the two fixes this case would
have read "1 hung window, z-index 1"; after, "5/5 in front, 0 hung".

What it JUDGES took a second pass to get right, and the first version was wrong
in a way worth keeping written down. Foreground is reported and not judged:
Windows grants it only to a process launched BY the foreground process, which a
harness under a shell under an editor never is, so it reads 0/5 here while a
hand launch is 5/5. The first version then judged z-order as if it were
independent -- and failed the case 0/5 on a healthy window, because a process
that may not take the foreground also may not be raised above the window that
holds it. On this machine the editor's own window sits at z-index 0 for as long
as a session is open, so nothing the harness launches can ever be in front of
it. The defect actually seen in section 11 was narrower than "not in front": it
was activation GRANTED and the window still not raised. So z-order is judged
only over the runs that took the foreground, and reported for the rest. A hung
window needs no such qualification and remains a hard failure at one.

## 12. The upstream parity wave (2026-09-06)

The macOS behaviours from 26.9.3 through 26.9.5-1 that section (d) of the
feature matrix listed, ported in three tracks: nested chapters with
per-document collapse memory and the single Expand/Collapse button, the
minimap following the reading theme (merge 386590a08); windows reopening on
their display with the last-used one focused and siblings opening together,
Keep Image Colors per document (merge 340ce34f6); Alt+wheel paging by wheel
distance and in-place Markdown reload (in flight). Each verified from a clean
build: full suite with only the seven macOS-host cases blocked, ratchet green,
sidebar differential unchanged at 15,203/0.

## 13. Everything the UI thread waits on, and what it waited on that it did not control (2026-09-07)

"The app was never responsive to any user input and not even focusable",
reported twice over two days after two different builds of the dist exe. The
same exe launched here -- from PowerShell and through Explorer -- gave a
healthy window every time: foreground, z-index 0, `IsHungAppWindow` false,
`WM_NULL` answered in under a millisecond, real `SendInput` clicks and keys
repainting it. Windows Error Reporting had meanwhile filed two hangs of the
build-tree exe (`AppHang_ShenzhenPDF.exe_*`, 2026-09-02 13:14 and 2026-09-03
07:06) with ConsentKey **AppHangXProcB1**: the UI thread was blocked on
ANOTHER PROCESS when the shell ghosted the window. No dump was kept. So the
question this pass answers is not "what does the window do at launch" but
"what can the window's thread ever wait on that is not its own", and the
method is an audit of every wait, then a measurement of each one that could
last.

### 13.1 The inventory

Every blocking construct reachable from the window's thread -- the window
procedure, paint, the two timers, the watcher's callbacks, render completion,
the thumbnail store, the print watchdog, the updater sink, the session and
settings writes, and every dialog and nested loop -- with what it waits on,
who else can hold that, and how long it can last. Line numbers are this
tree's after the fixes below.

| Site | Waits on | Held or answered by | Worst case before | Now |
|---|---|---|---|---|
| `spdf_win_state.c:184` `lock_file_exclusive()` -- every session save: tab open/close/select, the 30 s tick (`app_tick`), exit | `LockFileEx` on `<state dir>\session.lock`, exclusive, no `LOCKFILE_FAIL_IMMEDIATELY` | ANY OTHER ShenzhenPDF WINDOW: a window is a process here, and every one merges into the same file under this lock | forever (measured, 13.2) | polled with `LOCKFILE_FAIL_IMMEDIATELY` for at most 1 s, then the save proceeds unlocked |
| `spdf_win_render.c:343` `spdf_win_render_service_free()` -- every canvas teardown: tab switch, reload from disk, theme flip, exit; also the thumbnail pool | join of every render worker, `INFINITE` | a worker inside `spdf_render_page`: cancellation is a `fz_cookie` MuPDF checks between operators, so normally milliseconds, but one image decode is not interruptible | one uninterruptible decode: seconds on a large JPX/JBIG2 page | 500 ms, then the service is abandoned to its last worker, which frees it |
| `spdf_win_links.cpp:99` `spdf_win_links_free()` -- every canvas teardown | `WaitForSingleObject(thread, INFINITE)` | the text-URL worker inside `spdf_page_link_rects(detect_text_links = 1)` -- a structured-text pass of one page -- or its first `spdf_win_open_document` | seconds on a dense or a large document | no join: the block is reference-counted and the worker frees it when it finds the canvas gone |
| `spdf_win_chrome_thumbs.cpp:233` `spdf_win_thumbs_free()` -- `spdf_win_chrome_content_shutdown()`, i.e. every reload and every document change | `WaitForSingleObject(size_thread, 5000)` | the sizing sweep inside its own `spdf_win_open_document` (the sweep checks `stop` only between pages) | 5 s | no wait: reference-counted like the links |
| `spdf_win_assoc.cpp:162`, `spdf_win_setup.cpp:284,337` `SHChangeNotify(SHCNF_FLUSH)` -- File > Make Default PDF Reader, --install, --uninstall | Explorer taking delivery of the notification | explorer.exe | as long as Explorer takes; a hung Explorer, forever -- a textbook AppHangXProcB1 | `SHCNF_FLUSHNOWAIT` |
| `spdf_win_watcher.cpp:222` `stop_watch()` -- unwatch on tab close, reload, exit | join of the `ReadDirectoryChangesW` thread, `INFINITE` | the thread is parked in `WaitForMultipleObjects(io_event, stop)` and `SetEvent(stop)` + `CancelIoEx` wake it | the kernel's I/O cancel: milliseconds on a local disk | unchanged |
| `spdf_win_watcher.cpp:303` `spdf_win_watcher_watch()`, and `spdf_win_watcher_stat()` from the debounce and retry timers | `CreateFileW` on the document's directory, `GetFileAttributesExW` on the file | the file system; on a share whose server has gone, the SMB redirector's reconnect | tens of seconds per call on a dead share; milliseconds locally | unchanged: the path is the reader's own document, and every other open of it in the app has the same exposure |
| `spdf_win_md_reload.cpp:100` `spdf_win_md_reload_shutdown()` -- exit, after the window is destroyed | join of the Markdown re-read thread, `INFINITE` | md4c + the HTML conversion + MuPDF's layout of one document | seconds on a large Markdown file, as a lingering process with no window | unchanged: never a hung window |
| `spdf_win_gpu_prewarm.h:163` `spdf_win_gpu_prewarm_finish()` -- `spdf_win_d2d_destroy`, exit | join of the prewarm thread | a thread parked in `MsgWaitForMultipleObjects` on the finish event, pumping | milliseconds | unchanged (section 11 made it pump) |
| `spdf_win_print_dialog_system.cpp:271-297` PrintDlgEx watchdog | `MsgWaitForMultipleObjects(50 ms)` in a pumping loop; `:297` `INFINITE` only after the thread has already won the hand-off race | the dialog thread | the watchdog's own bound; `:297` microseconds | unchanged |
| `spdf_win_search.cpp:380` `spdf_win_find_session_free()` | spin with `Sleep(1)` until the workers exit | one page's search | one page | unchanged: nothing in the app calls it (the shared session lives for the process) |
| `spdf_win_panel_jobs.cpp:37` `join_worker()` -- OCR / translate panel, on the same thread | `WaitForSingleObject(worker, INFINITE)` | the job thread; cancel is `TerminateProcess` + `WaitForSingleObject(process, 5000)` in `spdf_win_toolchain_process.cpp:294` | ~5 s after a cancel, while the panel is up | unchanged |
| `spdf_win_selection.cpp:372,404`, `spdf_win_clipboard_page.cpp:234`, `spdf_win_shell.cpp:152` `OpenClipboard` retries | the clipboard owner letting go | another process mid-copy | 200 / 100 / 50 ms, bounded | unchanged |
| `spdf_win_selection.cpp:408` `GetClipboardData(CF_UNICODETEXT)` -- paste into a field | `WM_RENDERFORMAT` to the clipboard owner when it used delayed rendering; synchronous, no timeout | the process that last copied | as long as that process takes; a hung owner stalls the paste | unchanged: user-initiated, and there is no asynchronous form |
| `spdf_win_shell.cpp:73,100,114,120,192,197`, `spdf_win_assoc.cpp:165,166`, `spdf_win_chrome_canvas_ui.h:118` `ShellExecuteW` -- reveal in Explorer, open in browser, follow a link, the Settings page | `ShellExecute` behaves as `SEE_MASK_NOASYNC`: it waits out the DDE conversation with the target | Explorer, the browser, the URL handler | the shell's DDE timeout when the target is hung (tens of seconds) | unchanged: every one is a click the reader just made, and the fix (`ShellExecuteExW` + `SEE_MASK_ASYNCOK`) touches nine sites in three tracks' files |
| the modal loops: `TrackPopupMenu`, `IFileOpenDialog`, `TaskDialogIndirect` / `MessageBoxW`, the about / annotation / shortcuts / properties / print dialogs' `GetMessageW` loops, the tab drag in `spdf_win_tabs_handoff.h:277` | messages | -- | they pump; the tab drag asks foreign windows only through `WindowFromPoint`, `GetClientRect`, `ScreenToClient` and `GetDpiForWindow`, none of which sends, and talks to them only by `PostMessageW` | unchanged |
| the locks shared with workers: `svc->lock` (render), `links->lock`, the find session's, the thumbnail store's, the preview measurer's, the Markdown reload's SRW lock | a critical section | a worker | every one is held for a queue or pointer operation and RELEASED around the render, the text pass, the search and the measure (`spdf_win_render.c` "Renders ... run with the lock RELEASED"; `spdf_win_links.cpp` copies the page number out and the rects in) | microseconds | unchanged |
| `spdf_win_canvas_prefetch.cpp:212` `spdf_win_canvas_settle()` `Sleep(2)` loop | render completion | -- | headless probe only, by its own comment | unchanged |
| `spdf_win_launch_profile.h:105` `SwitchToThread` spin | a mark being written on another thread | -- | microseconds | unchanged |

Not on the list: `spdf_compat_lock_acquire()` in `portable/core/spdf_win_compat.c`
is the same blocking `LockFileEx`, but its only caller is the YAML migration
`spdf_state_migrate_dir()`, which the Windows frontend never runs at runtime
(only `state_test.c` does). No `SendMessage` to a window of another process
exists anywhere in `portable/win/src`; the only cross-process synchronous calls
were the two shell ones above.

### 13.2 The one that reproduces the report's class

Two windows are two processes, and both save `session.yaml` under
`session.lock`. Holding that lock from a third process -- a PowerShell
`FileStream.Lock` on the whole range, shared read/write exactly as the app
opens it -- and launching the tree's exe against that state directory:

| | before (`ShenzhenPDF-baseline.exe`) | after |
|---|---|---|
| window, first 30 s | up at 798 ms, 114 pings answered, max 0.63 ms | up at 228 ms, every ping answered |
| the 30 s session tick | the UI thread enters `LockFileEx` and stays: **11 consecutive `WM_NULL` timeouts (500 ms each), `IsHungAppWindow` = true** | one pause of at most `SPDF_WIN_STATE_LOCK_WAIT_MS` (1 s): 1 timeout out of 136 pings, the next answered in 164 ms, `IsHungAppWindow` false (with the constant at 2 s it was 2 timeouts) |
| `WM_CLOSE` while the lock is held | the window is destroyed, the exit save blocks on the lock, the process is **still running 6 s later**, 26 threads all in `Wait` | exits in 1,093 ms: the bound, then the unlocked save |
| release the lock | exits 6.1 s after `WM_CLOSE`, i.e. the instant the lock went | already gone |

That is a hung window, ghosted by the shell, on a process that has done
nothing wrong -- which is what AppHangXProcB1 says, and the hang stays
exactly as long as the other process holds the lock. What made the other
process hold it is not recoverable from the reports (no dump), and an honest
hold is milliseconds; what can hold it for minutes is a process suspended
while Windows Error Reporting collects it, or under a debugger, or itself
hung inside the save -- which is a way for one wedged old build to take down
every later window that shares its state directory. The fix (`spdf_win_state.c`)
asks for the lock with `LOCKFILE_FAIL_IMMEDIATELY` in 10 ms steps for at most
`SPDF_WIN_STATE_LOCK_WAIT_MS` and then saves anyway, which is what the code
already did when the lock file could not be opened at all; a merge lost to a
wedged sibling is repaired at the next save, and a window that never answers
again is not.

The report itself said "from the start". On this tree the first save under
the lock is the first tab change or the 30 s tick, not the launch, and the
launch's own health is section 11's -- so this is the mechanism of the class
WER recorded, measured; it is not a proof of what the reader's two builds
were waiting on.

### 13.3 The flood: `window.stress`

The suite never drove a window for longer than a launch, so a thread that
pumps for two seconds and then parks was invisible to it.
`portable/win/tests/stress-window.ps1` (case `window.stress`, registered
beside `launch.budget`) launches the built exe on a private copy of
`outline.pdf` with a private `--state-dir`, takes the foreground, and for 20 s
sends real input through `SendInput` -- wheel, PageDown/Up, Home/End,
Ctrl+plus/minus, Ctrl+F and typing, Escape, the sidebar toggle button,
resizes through `SetWindowPos(SWP_ASYNCWINDOWPOS)` -- while rewriting the
open file every 2 s (in place, then through a temp file, alternately) so the
watcher's reload, the canvas teardown and the render-worker join run under
load. Every 250 ms it asserts `SendMessageTimeout(WM_NULL, SMTO_ABORTIFHUNG |
SMTO_BLOCK, 500)` answers and no window of the process is hung; at the end,
that Home then PageDown change more than 2 % of the client pixels
(`PrintWindow`, `PW_RENDERFULLCONTENT`) and that `WM_CLOSE` ends the process
inside 10 s. The harness sends nothing synchronous of its own -- `MoveWindow`
would have hung the harness on the very defect it measures -- and only the
ping has a timeout, which is the assertion.

Measured on this machine, 1400x900 window, 150 %:

| | baseline | fixed |
|---|---|---|
| actions / rewrites | 80 / 9 | 80 / 9 |
| pings answered | 80 of 80 | 80 of 80 |
| ping max / mean | 5.46 / 0.17 ms | 0.52 / 0.15 ms |
| hung samples | 0 | 0 |
| Home then PageDown at the end | 123,283 px of 1,225,042 changed | 123,283 px |
| `WM_CLOSE` to exit | 120 ms | 344 ms |

The flood alone does not stall this tree: the nine reloads join render
workers that cancel within a frame and a link worker that is idle, and the
lock is uncontended. That is why 13.2 is a separate measurement -- the stall
needs a second holder, and the flood does not create one. The case's value is
as the tripwire that was missing: any wait that grows past 500 ms on this
path, or any input that stops repainting, now fails the suite.

Two things the harness itself had to learn on a shared desktop. A first run
reported "PageDown changed 0 px" against a perfectly live window: another
agent's ShenzhenPDF window (a different pid, the same class) had taken the
foreground mid-flood and the final keystrokes went to it. The harness now
re-takes the foreground before every keyboard action, checks `WindowFromPoint`
before every pointer action, counts what it had to skip as `obstructed`,
records who held the foreground and where the app's keyboard focus was
(`GetGUIThreadInfo`), and reports a foreground it cannot get back as BLOCKED
(exit 69) rather than as the app's failure. And PowerShell's comma binds
tighter than `%`, so an index computed inside a `-f` argument list silently
shortened the list; it is computed on its own line.
---

## 14. A disabled main window is indistinguishable from a hung app (2026-09-07)

The report was: **"the app was never responsive to any user input and not even
focusable"**, launched from `dist\ShenzhenPDF-win-x64.exe`. Nobody could
reproduce it. Launched from PowerShell or from Explorer, the window comes up
foreground, enabled, not hung, answers `WM_NULL`, and repaints under `SendInput`
clicks and keys.

There is one state that produces exactly that description and passes every one
of those checks:

> **A main window that is DISABLED, with no visible dialog in front of it.**

`EnableWindow(hwnd, FALSE)` does not stop the window painting, does not stop it
answering messages, and does not make Windows mark the process "not responding".
It only makes the window refuse input — and a disabled window **cannot be
activated**, not by a click, not by Alt+Tab, not by `SetForegroundWindow`. So it
is not focusable either. Every dialog in this port disables its owner. If the
dialog that did the disabling is invisible, off-screen, on a thread that is not
answering, or never appeared at all, the app is a picture of itself.

This section is the inventory of every place that can happen, the one place it
actually did, and what now makes it structurally impossible.

### 13.1 The inventory

Every site that disables a window of ours or runs a modal loop, with the thread
it runs on and what happens when the dialog function fails.

**Our own windows, our own modal loop** — each of these created a window,
called `EnableWindow(parent, FALSE)` by hand, ran a `GetMessageW` loop, and
re-enabled after it:

| site | thread | on failure | placement |
| --- | --- | --- | --- |
| `spdf_win_about.cpp` About | UI (`SPDF_WIN_CMD_ABOUT`) | `CreateWindowExW` fails *before* the disable | `CW_USEDEFAULT` |
| `spdf_win_annot_dialog.cpp` comment/author | UI (`spdf_win_chrome_annot_ui.h`) | same | `CW_USEDEFAULT` |
| `spdf_win_print_dialog.cpp` our print dialog | UI (`SPDF_WIN_CMD_PRINT`) | same | `CW_USEDEFAULT` |
| `spdf_win_properties_dialog.cpp` Properties | UI (`spdf_win_cmd_annot.h`) | same | `CW_USEDEFAULT`, and `WS_VISIBLE` at creation |
| `spdf_win_shortcuts.cpp` Keyboard Shortcuts | UI (`SPDF_WIN_CMD_SHORTCUTS`) | same | `CW_USEDEFAULT` |

None of the five could strand the owner through an early return: the only
failure path is window creation, which returns before anything is disabled. Two
weaknesses were real, though. **`CW_USEDEFAULT` cascades onto the PRIMARY
monitor, not the owner's** — with the app on a second display that is a modal
dialog the reader cannot see in front of a window they cannot click, which is
the reported symptom exactly. And each one called `SetForegroundWindow(parent)`
unconditionally on the way out, which takes the foreground back from whatever
application the reader had switched to meanwhile.

**System dialogs owned by one of our windows** — comdlg32, comctl32 and the
print drivers do their own disable/enable, and none of them leaves an owner
disabled when the call fails:

| site | thread | on failure |
| --- | --- | --- |
| `spdf_win_print_dialog_system.cpp` `PrintDlgExW` | **worker**, owner disabled from the UI thread | **see 13.2** |
| `spdf_win_print_dialog_system.cpp` `PrintDlgW` (classic) | UI, owner = our print dialog | returns FALSE, owner untouched |
| `spdf_win_print_dialog_run.cpp` `DocumentPropertiesW DM_IN_PROMPT` | UI, owner = our print dialog | returns non-`IDOK` |
| `spdf_win_updater_ui.cpp` `ask()`/`inform()` | UI — the sink is `HWND_MESSAGE`, created by `ensure_sink()` on the UI thread from `spdf_win_launch_window.h`, so its timers *and* the worker threads' posted results are both dispatched there | `TaskDialogIndirect` returns `E_*` without a common-controls-6 context, then `MessageBoxW` |
| `spdf_win_shell_dialog.h` `DialogBoxIndirectParamW` (password, Open Path) | UI (`spdf_win_tabs_open.h`) | returns −1, having disabled nothing |
| `spdf_win_annot_dialog.cpp`, `spdf_win_assoc.cpp`, `spdf_win_panel_jobs.cpp` `MessageBoxW` | UI thread of the owner in each case | returns 0 |

**No owner at all, so nothing to strand**: `spdf_win_setup_prompt.h` (the
first-run TaskDialog and its `MessageBoxW` fallback), `spdf_win_setup.cpp:57`
and `:323`, `spdf_win_window_doc.h:39`. **Its own modal loop and no
`EnableWindow`**: `TrackPopupMenu` in `spdf_win_menu.cpp` and
`spdf_win_chrome_annot_ui.h`. And the search found **no calls at all** to
`GetOpenFileNameW`, `GetSaveFileNameW`, `IFileDialog`, `PageSetupDlgW` or
`DoDragDrop` in `portable/win/src` — the only occurrences of the last two are
prose in comments explaining why they are not used.

### 13.2 The one site that could leave the window disabled forever, and did

`spdf_win_print_system_dialog()` is the only place where the dialog runs on a
**worker** thread while the owner is disabled by the **UI** thread. That is
deliberate and documented (`spdf_win_print_dialog.h`): on this host `PrintDlgExW`
with a valid `hwndOwner` never returns and creates no window, so it is called on
a thread it is allowed to wedge in, and a watchdog gives up after
`SPDF_WIN_PRINT_DIALOG_WATCHDOG_MS` = 4 s.

The watchdog decided "the dialog is up, stop the clock" from a snapshot of the
process's visible top-level windows: **any** new one counted. The comment
justifying that said the app creates nothing during the wait, "the calling
thread is in this loop and the parent is disabled". Both halves are wrong:

- the calling thread is in that loop **pumping its own queue** —
  `MsgWaitForMultipleObjects` + `PeekMessageW`/`DispatchMessageW` — so anything
  the UI thread was going to do, it still does. The updater's sink window lives
  on that thread; its 5-second one-shot and its hourly tick both fire into that
  pump, and `on_check_done()` puts a task dialog up from inside it;
- the parent being disabled does not stop a *second* window of this process
  (another app window, a tools panel) from putting a menu or a message box up.

Once one of those windows appeared, `window_up` latched at 1, the clock stopped,
and the loop waited on an event that on this host is never signalled. When the
window closed again there was nothing left on screen — and the main window was
disabled, painting, answering, and unfocusable. Indefinitely.

**Measured**, by `portable/win/tests/modal_scope_test.c` (case 4: a visible
top-level window of this process, created on another thread 800 ms into the
wait and destroyed 1.5 s later):

```
before   FAIL spdf_win_print_system_dialog did not return within 45 s -- the owner is still disabled
after    modal_scope: print dialog returned 4 after 6375 ms, err="Windows' print dialog did not open within 4 seconds."
         modal_scope_test: 31 checks, 0 failures
```

6375 ms is 800 + 1500 + the re-armed 4000, which is the fix behaving exactly as
described. Two changes, belt and braces:

1. **The calling thread's own windows are never the print dialog.** The snapshot
   and the sweep both skip windows whose thread is the one doing the waiting.
   That is precisely the updater case, and it is now not even a pause.
2. **The clock is re-armed when the window that stopped it goes away.** A window
   that appears and then closes while `PrintDlgExW` has still not returned was
   never the dialog. This is the general fix: it covers a second app window, a
   menu, a tooltip, anything nobody has thought of.

### 13.3 `spdf_win_modal_scope.h`, so it cannot come back

The five hand-written copies of

```c
if (parent) was_enabled = IsWindowEnabled(parent);
if (parent && was_enabled) EnableWindow(parent, FALSE);
...
if (parent && was_enabled) { EnableWindow(parent, TRUE); SetForegroundWindow(parent); }
```

are now one scope, `SpdfWinModalGuard`, used by all five plus the print
watchdog and the updater's `ask()`. A scope cannot be left: the destructor runs
on the early return, on the exception, and on the watchdog giving up. It adds
three things the copies did not have:

- **the owner's thread.** `EnableWindow` works across threads, so a dialog run on
  a worker against a main-window owner disables that owner from a thread that
  does not own it. No site does that today; if one is ever added the scope
  **refuses the disable** rather than performing it, and says so through
  `OutputDebugStringW`. A dialog that is merely not modal is a bug you can click
  your way out of; a main window disabled from a foreign thread is not.
- **activation, conditionally.** The owner gets `SetActiveWindow` +
  `SetForegroundWindow` back — Windows does not reliably return it after a
  cross-thread dialog or after one that failed to appear — but **only** if this
  process held the foreground when the scope opened and still holds it now, and
  never if the owner is minimised. A dialog finishing in the background no
  longer yanks the reader out of another application.
- **nesting.** A scope that finds the owner already disabled records that it did
  not do it and leaves it disabled on the way out, so a message box opened from
  inside a dialog cannot un-modal the dialog.

`spdf_win_modal_place_point()` is the placement, pure and therefore testable
headlessly: centre on the owner, then clamp into **the owner's monitor's** work
area, pulling the right and bottom edges in first so a dialog larger than the
work area is pinned to the top-left, where the title bar and the first controls
are. All five of our dialogs now place themselves with it before they are shown
— Properties lost its `WS_VISIBLE` at creation so that it is placed before it
appears rather than jumping afterwards.

The updater's `ask()` gained one more thing: `g.main` is remembered at start-up
and **never cleared**, so a task dialog parented on a destroyed HWND fails, and
the `MessageBoxW` fallback fails with it — no dialog, no answer, and the update
silently not offered. It is now validated with `IsWindow()` and degrades to an
unowned dialog.

### 13.4 The entry path, checked and found sound

The first-run prompt (`spdf_win_setup_prompt.h`,
`SPDF_WIN_SETUP_ALLOW_PROMPT=1` with a fresh `--state-dir`) runs **before the
main window exists**, with a `NULL` owner: there is nothing to leave disabled.
Answering "Run this copy" with a document on the command line then goes through
`spdf_win_window_show_ex()`, which is already `ShowWindow` **and** an explicit
`SetForegroundWindow` (`spdf_win_window_lifecycle.h`) — so the window claims the
foreground back from the Explorer window that got it while the prompt was up.
Nothing to fix.

### 13.5 The test

`portable/win/tests/modal_scope_test.c`, registered automatically as
`win.modal_scope_test`. Four cases in increasing cost: the placement arithmetic
headless (edges, a second monitor, an oversized dialog, no owner); the scope
against a real owner window (disable, re-enable, nesting, double close, and a
scope opened from a foreign thread refusing to disable); the real placement
landing inside the owner's monitor work area; and the regression of 13.2. A hard
timeout kills the process at 45 s rather than letting the test become the hang
it tests for, and on a **locked workstation** — where no window can be created
at all — it exits **68**, which `run-tests-native.sh` now records as BLOCKED for
every `win.*` case, the code `run-tests-native.launch.sh` already used.
## 15. The input path is device- and layout-dependent (2026-09-07)

Section 11 fixed the two ways the app's window arrived un-clickable. The report
behind it said something a little wider than z-order -- "never responsive to any
user input" -- and the reporter's machine differs from the harness in three more
ways at once: a French AZERTY layout is loaded, the pointer is a precision
touchpad rather than a mouse, and the display is at 150%. Synthetic input misses
all three, because SendInput sends US virtual-key codes and wheel deltas of
exactly 120. So each was measured against the real thing.

### (a) VK_OEM_MINUS is on no French key. Zoom Out had no accelerator.

The accelerator table (`spdf_win_menu_table.h`) names its keys by VIRTUAL-KEY
code, and a virtual-key code is a property of the LAYOUT, not of the keyboard.
Measured on this machine against `LoadKeyboardLayoutW(L"0000040C")`:

| VK | US (00000409) | FR (0000040C) |
| --- | --- | --- |
| `0xBD` VK_OEM_MINUS | scan 0x0C, `-` | **scan 0x00 -- not on the layout** |
| `0x36` VK_6 | `6` | `-` |
| `0xBB` VK_OEM_PLUS | `=` | `=` |
| `0xBC` VK_OEM_COMMA | `,` | `,` |
| `0xBF` VK_OEM_2 | `/` | `:` |
| `0x30` VK_0 | `0` | `a-grave` (the digit is Shift) |

`MapVirtualKeyExW(VK_OEM_MINUS, MAPVK_VK_TO_VSC, hkl)` returns 0 for the French
layout: no key on a French keyboard produces that code at all. So every table
row keyed on it was dead for a French reader -- **Zoom Out (Ctrl+-)** and
**Smaller Text (Ctrl+Alt+-)** -- and so was the bare `-` in `key_for_window()`'s
keymap. The `-` key they press reports VK_6, which no row named. Zoom In
survived only because VK_OEM_PLUS happens to sit on both layouts.

The macOS original does not have this problem, and the way it avoids it is the
fix: `ShenzhenPDFMac.mm:1963-1964` binds Zoom In and Zoom Out with
`keyEquivalent:@"+"` and `keyEquivalent:@"-"` -- CHARACTERS, which AppKit matches
against what the active layout produces. The port now carries the same thing.
`spdf_win_input` gained `key_char`, the character the pressed key produces on the
active layout with no modifiers, from `MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR)`;
`spdf_win_menu_layout.h` matches it AFTER the exact virtual-key match, so the US
path is what it always was (asserted over every row of the table) and the
fallback can only add. `MAPVK_VK_TO_CHAR` and not `ToUnicode`: `ToUnicode`
consumes the kernel's pending dead-key state, so calling it on every WM_KEYDOWN
would eat the accent a reader had begun composing in the find field.

Two smaller things came with it. A digit row now also matches with Shift on a
layout that shifts its digits -- `key_char` is not the digit there, which is how
the case is recognised, and on US the rule is inert. And the bare `+`/`-` keys
now require no Ctrl or Alt: the old switch tested the virtual-key code and never
looked at `mods`, so Ctrl+Alt+Shift+= zoomed.

### (b) AltGr is Ctrl+Alt, and the port had two Ctrl+Alt accelerators.

On every European layout AltGr is reported as Ctrl+Alt. Measured on FR: AltGr+`=`
is `}`, AltGr+`0` is `@`, AltGr+`4` is `{`, AltGr+`5` is `[`. The table's Smaller
/ Larger Text rows are Ctrl+Alt+`-`/`=`, from the mac's Cmd+Alt -- where Option
is not AltGr. So **a French reader typing `}` -- in the find field, in the page
field, anywhere -- also resized the Markdown text**, and the `}` was inserted as
well. This is a porting incompatibility rather than a transcription error: the
original has nothing to say about it.

Settled in the only direction that can be right: a keystroke the layout turns
into a character is text, and text is not an accelerator. `spdf_win_input` gained
`text_key`, and the window answers it from the QUEUE rather than from the layout.
`TranslateMessage` runs before `DispatchMessageW`, so by the time a WM_KEYDOWN
reaches the window procedure the WM_CHAR it produces is already sitting there,
and `PeekMessageW(..., WM_CHAR, WM_CHAR, PM_NOREMOVE)` reads it without taking
it -- no `ToUnicodeEx`, no dead-key side effect, no version gate. It gates ONLY
the Ctrl+Alt rows: Ctrl+F queues a WM_CHAR too (0x06), and gating on that would
disable the whole table, so the test is `>= 0x20` -- the same one
`spdf_win_chrome_text.h` applies to what it will insert.

Neither `key_char` nor `text_key` is cached, so WM_INPUTLANGCHANGE needs no
handler: a reader who switches layout mid-session gets the new answer on the
next keystroke, because both are asked of the ACTIVE layout each time. The IME
is likewise untouched -- the port never calls `ImmAssociateContext`, so every
window keeps its default context and DefWindowProc's WM_IME_* handling turns a
composition into the WM_CHARs the find field already accepts. One gap remains
and is cosmetic rather than a swallow: nothing calls `ImmSetCompositionWindow`,
so a CJK candidate list appears at the window's origin instead of under the
caret in the field being typed into. Recorded here rather than fixed; it needs
the caret's screen position, which only the chrome painter knows.

### (c) The pointer path was already device-independent. Measured, not assumed.

Nothing in `portable/win/src` calls `EnableMouseInPointer`,
`RegisterTouchWindow`, `SetWindowFeedbackSetting` or `GetMessageExtraInfo`, none
of it looks for `MOUSEEVENTF_FROMTOUCH`, and there is no
WM_POINTER*/WM_TOUCH/WM_GESTURE handler -- so Windows' default mouse synthesis
for touch and pen is untouched and nothing drops an injected message. Two-finger
tap arrives as WM_RBUTTONDOWN and is already routed.

The wheel is the part that needed work, and not because it was wrong. A
Precision Touchpad does not send notches: it reports the finger's travel as a
stream of small arbitrary deltas (3, 8, 17), sends its inertial tail the same
way, and delivers PINCH as Ctrl+wheel with those same small deltas. The
arithmetic in `on_wheel` was already fractional and therefore correct -- but it
was inline in a window procedure, which cannot be tested, so nothing said so. It
moved to `spdf_win_wheel.h` (pure, no Win32) and `wheel_input_test.c` now pins
the properties that matter: a delta of 1 moves the view by more than the canvas's
0.01 px "did anything change" threshold at every scroll-lines setting; 120 deltas
of 1 travel exactly as far as one delta of 120; a realistic burst summing to 120
does too; 120 pinch steps of 1 compose to exactly one notch's zoom factor; and
the notch formula agrees with `spdf_win_page_wheel.h`'s independent copy at every
DPI and setting, so Alt+wheel cannot come to page at a different rate than the
wheel scrolls.

### (d) DPI hit-testing parity holds at 96, 120, 144 and 192. It is not the bug.

Painter and router take the SAME `dpi_scale` from the same place --
`spdf_win_window_dpi_scale(window)`, which is `window->dpi / 96`, filled into
`spdf_win_scene` in `spdf_win_window_target.h` and into `spdf_win_input` in
`spdf_win_window_input.h`. The Direct2D target is created at 96 dpi, so DIPs are
device pixels and there is no second scale anywhere; the router receives client
device pixels, which is the unit every rect in `SpdfWinChromeLayout` is expressed
in. That is the structural argument. `dpi_hit_parity_test.c` is the measurement:
for every toolbar control (both halves of all four pills), the sidebar's
segments, its filter field and its list rows, and the five bands, it takes the
rect the PAINTER would draw and asserts that the whole router --
`spdf_win_chrome_input_route`, band classification included -- names that
control, at all four DPIs, on a window sized in real device pixels. 255 checks,
0 failures. Nothing is off at 150%.

### (e) Nothing in the port can make the window uninteractable.

The five ways a Win32 window is visible and takes no input are
`WS_EX_TRANSPARENT`, `WS_EX_LAYERED` with alpha 0, `WS_EX_NOACTIVATE`,
`WS_DISABLED`, and answering `MA_NOACTIVATE` to WM_MOUSEACTIVATE (or eating
WM_NCACTIVATE). A grep across `portable/win/src` for `GWL_EXSTYLE`,
`SetLayeredWindowAttributes`, `WM_MOUSEACTIVATE` and `WM_NCACTIVATE` finds
exactly one hit: `spdf_win_gpu_prewarm.h`'s offscreen 64x64 `WS_EX_TOOLWINDOW |
WS_EX_NOACTIVATE` popup, which is never shown and dies with its worker
(section 11). The Markdown swap's "held transparent while it settles" is not a
transparent window at all -- `spdf_win_canvas_swap.cpp` keeps drawing the old
document and simply never composes an empty frame -- and the tab hand-off drag
takes a capture and releases it, touching no style.

`EnableWindow` is a different matter and was read rather than grepped past: the
five owner-modal dialogs (About, Keyboard Shortcuts, Properties, the comment
editor, the print dialog) each disable the parent while they are up, which is
the standard pattern and also the standard way to leave a main window
permanently dead. All five were checked line by line and all five are correctly
paired: the disable happens only after the dialog window exists, the re-enable
is the statement immediately after the modal loop, and there is no `return`
between them. One thing near it is worth recording and is NOT fixed here --
those loops end on `GetMessageW(...) > 0`, which is also how WM_QUIT arrives,
and they consume it rather than re-posting it, so a quit that lands while a
modal is up would never reach the outer pump.

`window_activation_test.c` is the live half: a real app window, and after
create, show, full screen, leaving full screen, maximize and restore the extended
style carries none of the three bits, the window stays enabled,
`WindowFromPoint` over the canvas returns it, WM_MOUSEACTIVATE answers
`MA_ACTIVATE` and WM_NCACTIVATE is not eaten. It also drives the new `text_key`
through the real queue: a posted WM_KEYDOWN with a `}` behind it reports text,
one with 0x06 behind it does not. 26 checks. What it cannot reach is stated
rather than glossed -- the Markdown reload and the hand-off drag live on `struct
app`, which no test can build; what stands for them is the invariant above plus
the sweep over every transition the window performs itself.

### What this leaves

(a) and (b) are real and are fixed. Either alone makes the app feel broken to a
French reader, and (b) makes typing in the find field do something alarming. But
neither makes an app take NO input, so neither is the whole of the original
report -- section 11's two launch defects remain the best explanation for that,
and the reporter had not run a build containing them. (c), (d) and (e) are
negative results, recorded as such: the pointer path, the DPI path and the
window's activation state were measured and are not where the input went.

Reproduce the layout measurements without the app: `keyboard_layout_test.c` does
them itself with `LoadKeyboardLayoutW` + `VkKeyScanExW` + `MapVirtualKeyExW`, and
SKIPS with a printed reason on a machine where the French layout is not
installed, so the evidence is either collected or its absence is said out loud.
## 16. The launches that leave no window to use (2026-09-07)

"The app was never responsive to any user input and not even focusable",
twice in two days from `dist\ShenzhenPDF-win-x64.exe`, on a state nobody
else has. A plain launch here is healthy every time (section 11's probe:
foreground, enabled, z-index 0, answers WM_NULL), so this pass went through
the restore track that merged after those two fixes -- windows reopened on
their saved display, the last-used one focused, the others started as
`--behind` processes -- and put each way it could go wrong on the desktop, with
a session.yaml written for it into a private `--state-dir` and a probe that
enumerates every process running from the exe (the launch AND its siblings):
each window's visibility, enabled and hung state, rect, monitor and work-area
overlap, z-index among Alt+Tab-sized windows, and what WindowFromPoint finds
at its centre. 2880 x 1800 at 150%, work area 2880 x 1728.

What holds, measured: two or three saved windows with distinct, equal, absent,
negative, absurd (`1e300`) or non-numeric `focusedAt`; the focused window's
document missing, or its only document missing, or held open with no sharing
by another process (the tab opens empty, the window still claims the front);
a file argument on top of a two-window session; two launches 60 ms apart
(four processes, the first launch's focused window in front, the rest behind);
an exit while maximized (the normal frame is what is saved and restored); a
frame on a display that is not attached, or wholly off screen with no display
named (centred on the main display, the saved frame kept). In every one of
these exactly one window was foreground and topmost, and every window was
enabled, unhung and clickable at its centre.

Three things do not hold.

1. **A `--behind` sibling can come up OVER the focused window.**
   SW_SHOWNOACTIVATE withholds activation and nothing else: the window keeps
   the z-position CreateWindowExW gave it, which is the top. The design has
   the focused window claim the foreground and BringWindowToTop while the
   siblings show NOACTIVATE, and that is correct only when every sibling shows
   FIRST. Measured with a third process started `--window <id> --behind` three
   seconds after the launch: it came up at z-index 0 at the exact frame of the
   focused window (z-index 1, still foreground, still holding the keyboard).
   A window nobody can see has the focus; the window they can see is not
   active. Which finishes first is decided by the documents -- a launch on a
   session whose focused window holds a slow document and whose other window
   holds a small one runs the race the wrong way every time (see 4 below). The
   sibling now places itself: `spdf_win_window_show_ex(window, 0)` finds the
   frontmost visible window of the app's class already on the desktop,
   whichever process owns it, and shows with `SetWindowPos(hwnd, front, ...
   SWP_NOACTIVATE | SWP_SHOWWINDOW)`, directly beneath it; with none yet it
   shows on top, inactive, and the focused window's BringWindowToTop passes it.
   After: the late sibling at z-index 2, the focused window z-index 0 and
   foreground, its centre its own.

2. **A saved frame with a 60 x 28 corner on screen came back as that corner.**
   `spdf_win_placement.h` applied a frame exactly whenever its display was
   attached at its saved rectangle, whatever the frame overlapped -- the
   identity rule was meant for a frame on a second display, and it also
   admitted a frame dragged almost entirely off its own. Frame 2820,1700 on a
   2880 x 1800 display: visible=True, foreground=True, 60 x 28 of it inside the
   work area (most of that under the taskbar). Focused and, to a person,
   absent.

3. **A saved frame with its title bar above the display came back as a strip.**
   Frame y = -1100, height 1211: 1702 x 111 of it inside the work area, which
   passes the 80 x 80 visibility rule, with the tab strip -- the only title bar
   this window has, and the only thing to drag it by -- 1100 px above the
   screen. Windows' own SetWindowPlacement pulls a frame that misses every
   monitor back to the nearest edge (measured: x = 3500 came back at 1178,
   y = -1500 at 0) and leaves one that touches a monitor alone, so the partial
   cases were ours.

   Both are one rule now (rule 4 in `spdf_win_placement.h`): a frame is applied
   as saved only when it is REACHABLE -- 80 x 80 inside a work area with its top
   edge inside that work area. Otherwise it is parked: clamped whole into the
   work area of its home display (the one it overlaps most, else the one it
   names when that is attached), keeping the reader's size and as much of the
   position as fits; with no home, centred on the main display as before. The
   parked rect is still not what is saved: after each of these launches the
   file kept 2820,1700 and 228,-1100. After: the corner frame at 1178,517
   (whole), the strip frame at 228,0 (whole), both foreground.

4. **The first paint has no budget, and the siblings show while it runs.** The
   window paints its first frame before ShowWindow so it appears complete; on
   a page with 400,000 stroked paths that frame took longer than 45 s, during
   which the focused window was hidden and IsHungAppWindow-hung while its
   sibling was on screen, inactive, with nobody in the foreground. A reader
   sees an app that opened a window it did not focus, and a second window that
   arrives whenever it arrives and takes the foreground then. Not fixed here:
   it is the canvas's first-frame rule (spdf_win_canvas_set_async_visible
   starts async rendering from the SECOND frame), and a bound on it is a
   rendering decision, not a placement one. Recorded so the next report of a
   window that "never" appears is read against it.

   FIXED IN SECTION 18: the first frame now has a 250 ms budget, and the same
   400,000-path page puts its window up in 325 ms instead of 4.5 s. Finding it
   also turned up why no repaint had ever arrived for an asynchronous render.

Pinned: `placement_test.c` section 4 (reachable, home display, clamp, resolve,
parked flag, on this desktop's geometry) and `launch.invariant`
(`portable/win/launch-invariant.ps1`), which writes the four sessions --
behind, sliver, strip, gone -- on the live display geometry, launches each,
starts the late sibling for the first, and asserts every window of the app
enabled, unhung and reachable with the focused window topmost; parked
scenarios also assert the file still holds the saved frame after exit. Against
the pre-fix dist exe it fails 4 assertions (topmost is the late sibling; the
corner and the strip unreachable); against the fix it passes. BLOCKED (68) on
a locked workstation, like `launch.budget`. The foreground is reported and not
judged, for section 11's reason.

Not reproduced, and not verifiable here: a launch while another application
holds the foreground lock (SetForegroundWindow refused). The code path after a
refusal still shows, raises and flashes, and the window is enabled; forcing
the refusal needs a foreground process with recent input, which a harness on
this desktop is not. Nor is the reporter's own session known -- the three
defects above are the only launches found on which a person could see a window
of the app and not use it.
## 17. The app now writes down what state it came up in (2026-09-07)

"The app was never responsive to any user input and not even focusable",
launched from `dist\ShenzhenPDF-win-x64.exe`. Nobody has reproduced it. The same
exe launched from PowerShell and from Explorer on this machine gives a healthy
window every time -- foreground, enabled, not hung, answering WM_NULL, and
repainting under SendInput -- and Windows Error Reporting recorded no hang of
it. Section 11's two defects were found because someone was standing over the
bad launch with a probe; this one is not reproducible, so nobody will be.

Every instrument this port had can only measure a launch someone is watching. So
the app is now its own witness.

### What it writes, and when

Every windowed launch appends to `<state dir>\launch-health.log` -- beside
settings.yaml and session.yaml, so `--state-dir` moves it with everything else
and a test never writes into the reader's own state. One line each at **1 s, 5 s
and 30 s** after the window is shown (one-shot `SetTimer` callbacks on the UI
thread, so they need no case in the window procedure), plus a **`stall`** line
from a watchdog thread whenever the UI thread's heartbeat is older than three
seconds. The file is trimmed to its last 200 lines when it passes 192 KB.

One real line, from a launch on this machine:

```
2026-09-06T17:53:01.095Z at=5.3s phase=5s pid=16128 hwnd=0x009F0864 build=26.9.2-1
fg=1 enabled=1 visible=1 iconic=0 rect=380,380,2082,1591 monitor=\\.\DISPLAY1
mon_rect=0,0,2880,1800 onscreen=1 zindex=0 windows=5 hung=0 modal=0 owned=0
msg=lbdown:1,keydown:6,char:4,mousemove:2,wheel:0,activate:1,setfocus:1,killfocus:0
paints=10 last_input_age_ms=156 heartbeat_age_ms=0 pump=busy
exe=C:\spdf-build\health\ShenzhenPDF.exe
```

(one line in the file; wrapped here). How to read it:

| field | what it answers |
| --- | --- |
| `at=` / `phase=` | seconds since **process creation** (the kernel's timestamp, the same origin `SPDF-LAUNCH` marks use), and which of the four lines this is |
| `fg=` `enabled=` `visible=` `iconic=` | the four states a reader means by "it does not respond". `fg=0` is section 11's defect 2; `enabled=0` is a modal dialog somewhere |
| `rect=` `monitor=` `mon_rect=` `onscreen=` | where the window is, which display it is on, and whether its frame overlaps **any** monitor's work area. `onscreen=0` is a window that is visible, enabled, healthy and entirely off the desktop |
| `zindex=` | position among visible top-level windows larger than 200 px, 0 = in front. Section 11's defect 2 read 1. -1 means it is not in that walk at all |
| `windows=` `hung=` | every top-level window of this process, and how many `IsHungAppWindow` reports. Section 11's defect 1 read `hung=2` -- and both were invisible windows |
| `modal=` `owned=` | visible windows owned by this one, and whether one of them is enabled while this one is not, i.e. a modal dialog holding the app |
| `msg=` | messages the window procedure has **received**, counted before any handler runs. This is the field that separates "the input never arrived" from "the input arrived and nothing happened", which is the whole question |
| `paints=` | `WM_PAINT`s that returned, counted after `EndPaint` |
| `last_input_age_ms=` `heartbeat_age_ms=` | ms since the last input message, and since the message loop last went round |
| `pump=` | `idle` = parked in `GetMessageW` (healthy, however long); `busy` = inside a dispatch. A timer line always says `busy`, because a timer callback IS a dispatch |

### Why the watchdog is a separate thread

A timer that fires on the UI thread proves the UI thread is running **by
firing**, so no UI-thread timer can ever report a blocked pump -- the exact
failure the report describes. `spdf_win_window_run` therefore stamps a heartbeat
in two halves (about to park in `GetMessageW`; back and about to dispatch), and a
plain thread wakes every second and writes a `stall` line when the heartbeat is
stale *while the loop is inside a dispatch*. Parked in `GetMessageW` is health,
not a stall: an idle app waits there for as long as the reader is away.

A modal dialog looks like a stall too, and deliberately: it runs its own message
loop and never returns to ours, which is exactly what "the window ignores every
click" feels like. The line says which -- `modal=1` with `owned>0` is a dialog,
`modal=0` with `owned=0` is a pump that is genuinely stuck.

### Reading it back: `--diagnose`

`ShenzhenPDF.exe --diagnose` prints one line per live window of class
`ShenzhenPDFWindow` on the desktop, whatever process owns it, then the tail of
every `launch-health.log` it can find (the resolved state directory, and
`<exe dir>\ShenzhenPDF-data`), then exits 0. It is one line to type while the
bad window is still on screen and one block to paste. The in-process half of the
line (`msg=`, `paints=`, `heartbeat_age_ms=`, `pump=`) prints as `-` for another
process's window and is read from that process's own log below it.

The exe is `/SUBSYSTEM:WINDOWS` and has no console of its own, so it writes to
whatever standard output handle it inherited, borrowing the parent's console
when there is none. **Redirect it** (`ShenzhenPDF.exe --diagnose > health.txt`)
if nothing appears: measured on this machine, the same call captures its output
from an interactive prompt but not from inside a `powershell -File` script.

### The test that would have caught it: `launch.health`

`launch.budget` proves a window appeared and painted. It cannot prove the window
reacts, because it never touches it -- and that is precisely the gap the report
lives in. `launch.health` (portable/win/tests/launch-health.ps1) launches the
built exe on `golden.pdf` with a private `--state-dir`, then sends **real
input** through `SendInput`: PageDown, a click on the toolbar's next-page
button, then Ctrl+F with `the` typed into it. Each must change more than 1% of
the window's `PrintWindow(PW_RENDERFULLCONTENT)` capture (0.1% for the find
sequence, which may only light the toolbar). Then it reads the app's own log
back and asserts the 1 s line says foreground, enabled, visible, not iconic, not
hung, z-index 0, a monitor found, on screen, not modal, and that the input
counters and the paint total have moved by the 5 s line.

Three things it does that are worth keeping:

1. **The click coordinate comes from the app.** `--print-layout W H SCALE`
   prints the chrome bands and every toolbar control as `kind name x y w h`,
   from the same pure layout the painter draws and the input router hit-tests
   (`spdf_win_chrome_toolbar.h`), with pills resolved into the halves that map
   to commands (`action next-page ...`). The test clicks the *button*, not a
   coordinate someone measured once at 150% on one machine.
2. **It asks for the foreground before the 1 s line is written.** Windows grants
   the foreground to a process launched *by* the foreground process, and a
   harness under a shell under an editor never is one, so the app's own
   `SetForegroundWindow` is correctly refused (measure-launch.ps1 measures 0/5
   here against 5/5 for a hand launch). Asking on its behalf turns `fg=` and
   `zindex=` into an assertion worth making: not "was it granted the
   foreground", which is the system's decision, but "given it, does it hold it
   and stay on top".
3. **It refuses to type into somebody else's window.** Before every action it
   re-checks that the app is the foreground window and that `WindowFromPoint` at
   the click target belongs to the app's process; a locked workstation, or a
   desktop it cannot come to the front of, exits 68 and reads BLOCKED. Real
   input goes to whoever is in front, and typing into another application is
   worse than not testing.

One flake is known and mitigated: if the pointer is left over the tab strip from
a previous run, the strip's hover preview -- an owned, always-on-top window of
the same process -- catches the click, which the failing runs' `owned=1` gives
away. The case parks the pointer over the canvas before it starts. When it does
fail it runs `--diagnose` against the still-open window and prints it, so the
next unreproducible thing is diagnosed the first time rather than the third.

## 18. The first paint had no budget, and the repaint that would have saved it was never delivered (2026-09-07)

Section 16 item 4 left one launch unfixed: the window paints its first frame
before `ShowWindow`, so on a slow page there is no window at all for as long as
that page takes. Measured on this desktop (2880 x 1800 at 150%, work area
2880 x 1728) against fixtures generated for it -- one page carrying N stroked
subpaths, `x y m x y l S` each, so MuPDF walks N display-list nodes and strokes
N times. The generator is a 60-line script; the files it writes (5 MB and
26 MB) are not in the repo.

| launch | window on screen | page on screen |
| --- | --- | --- |
| `outline.pdf`, before | 132 ms | 122 ms |
| `outline.pdf`, after | 133 ms | 123 ms |
| 400,000 paths, before | 4518 ms | 4503 ms |
| 400,000 paths, after | **325 ms** | 5090 ms |
| 2,000,000 paths, before | 35343 ms | 35326 ms |
| 2,000,000 paths, after | **358 ms** | 28895-37739 ms |

Medians of 10 runs for `outline.pdf`, interleaved between the two builds; 3 runs
for 400,000 paths and 2 for 2,000,000. The heavy fixtures vary run to run far
more than `outline.pdf` does -- the first measurement of the 400,000-path page,
taken while another track was building, was 8.6 s rather than 4.5 s -- so read
their absolute numbers as a scale, not a constant. "Window on screen" is a host
poll for a visible top-level window of the process. "Page on screen" is the
app's own
`first-compose-end` before and the new `first-page-scene` mark after -- the
first composed frame that had a page draw in it, a distinction the old timeline
did not need because its first frame always had one.

Before the fix, and for the whole of those 4.5 and 35 seconds, the process was
`IsHungAppWindow`-hung with no window of its own on screen. That is the report,
word for word: never responsive to any user input, and not even focusable.

### The bound is 250 ms, and why that number

`spdf_win_canvas_set_first_frame_budget()` gives the first frame of a launch a
budget: the page is asked of T5's worker pool at VISIBLE priority and waited
for, on the UI thread, for at most that long. Inside the budget the launch is
unchanged -- same pixels, one render, presented before the same `ShowWindow`.
Past it the frame comes back with no page draws and the canvas's status line
("Opening…"), the window goes up, and the pool's completion brings the page in.

250 ms is longer than the whole healthy launch measured here -- 122 ms to a
composed page, of which the page render is 39 ms -- and longer than the 145 ms
the launch doc records, so nothing that is fast today waits any differently. The
worst case it admits is a window at about 350 ms: the 60-100 ms before the first
frame, plus the budget, plus a compose with no page texture to upload. A tenth
of a second either way would do as well; what matters is that it is clear of a
healthy render and inside the time a person will wait for a window.

Waiting on the UI thread is what `spdf_win_canvas_settle()` forbids in terms,
and this is the one place it is allowed, for reasons that are written at the
wait: there is no window yet, so there is no message to pump and nothing else
this thread could be doing; the wait is bounded; and what it buys is that the
UNBOUNDED wait never happens.

**The fast path is free because the wait is spent inside a wait that already
existed.** The timeline puts `gpu-prewarm-done` 41 ms after the page render
ends, and the first compose cannot start before the GPU device is ready. Moving
the render to a worker costs the pool's own document open plus the Sleep(1)
granularity of the poll -- measured as `first-scene-built` moving from 77 ms to
89 ms -- and all of it is absorbed: the window and first-composed-page medians
are 132/122 ms before and 133/123 ms after.

### The repaint was never delivered, and never had been

With the budget in place the heavy launch put its window up in 325 ms and then
never drew the page -- not in 200 seconds. The window was healthy throughout
(`launch-health.log`: enabled, visible, unhung, z-index 0) and its `paints`
count stopped at 3. Marks added to the canvas's notify hook showed the pool
finishing at 6.2 s and calling the hook with `notify_armed=1`, and the results
being drained only at shutdown 30 s later.

`SPDF_WIN_WM_RENDER_READY` was `WM_APP + 0x5244` -- "RD" as a mnemonic, 0xD244
as a number. The window procedure's default case forwards `msg >= WM_APP && msg
< 0xC000` and nothing above, because 0xC000 up is the `RegisterWindowMessage`
range and not the app's to interpret. Every one of those posts went to
`DefWindowProc`. **The same mistake was in all three app messages**:
`SPDF_WIN_MD_WM_IMAGES_ARRIVED` ("MD", 0xCD44) and `SPDF_WIN_MD_WM_RELOADED`
("ME", 0xCD45) too. So a Markdown file rewritten on disk was re-read off-thread
and the result never reached the window, remote images never turned their
placeholders into pictures, and an asynchronous visible-page render never asked
for the repaint that shows it -- which is exactly what `spdf_win_canvas.h`
warned would happen without a notify: "the reader keeps looking at the soft
stand-in until they move the mouse". Nobody noticed, because until this change
every one of those cases had a stand-in to look at and a mouse to move. The
first frame of a fresh document has neither.

All three are now `WM_APP` plus a number under 0x4000, and
`SPDF_WIN_APP_MSG_OK(name, msg)` beside each `#define` fails the build for a
number outside the routable range. A comment would not have caught this one:
the mnemonic looked deliberate.

### Two smaller things the measurements forced

1. **No neighbour prefetch while a frame is still waiting for its own page.**
   `build_scene` asked for pages `last + 1` and `first - 1` at the end of every
   frame, deferred ones included, so a second heavy render ran beside the one
   somebody was waiting for. Two MuPDF renders of a 400,000-path page share one
   machine's memory bandwidth: the page landed at 6435 ms with the neighbour
   and at 5090 ms without it. The neighbours are asked for on the first frame
   that has something in it, a few milliseconds later, which for a page nobody
   has scrolled to is soon enough.
2. **A frame with no page draws keeps its message.** `scene_for_window` assigned
   `scene->message = a->status[0] ? a->status : NULL` unconditionally after a
   `build_scene` that returned 0, throwing away the message the canvas had just
   put there. Harmless while the only such frame was a broken document; wrong
   the moment one can also mean "still rendering". The app's status still
   outranks the canvas's, but only when it has one.

### What is pinned, and what is not

`win.canvas_async_test` builds the same first frame twice, on the same document
at the same zoom -- once unbounded, once with a 1 ms budget -- and requires the
bounded one to cost less than half the unbounded one, with no page draws, a
non-empty message, and nothing rendered on the calling thread. No wall-clock
constant appears in the assertion: the unbounded run is the constant. A second
canvas at a normal zoom pins the recovery -- the pool finishes, the `ready` hook
rings, and the next frame is whole. It is headless, so it needs no desktop and
blocks for nothing. The zoom for the bounded pair is pushed to the render byte
cap, which is how a slow page comes out of a fixture small enough to commit;
that is also why the recovery is a separate canvas, since at the cap one page
fills the whole 96 MB bitmap cache and the neighbour evicts it as fast as it
arrives.

Not verified here: what the deferred frame LOOKS like. This machine's screen
saver ran throughout, and while a window can still be shown on that desktop,
`PrintWindow` returns a flat client area for a Direct2D surface --
`screenshot-window.ps1` exits 68 and says so. The status frame's appearance
rests on the compose layer's existing message path, which the no-document launch
has always used and the `d2d` cases cover.

Not changed, deliberately: a TAB SWITCH into a heavy document still renders its
first frame on the UI thread. It has a window, so it is a freeze rather than an
absence, and `show_selected_tab`'s promise that a switch "lands finished" is a
different decision from this one. The machinery is one call away if that promise
is ever traded.

## 19. The empty window was not unresponsive; it was dishonest (2026-09-07)

Sections 13-17 each found a real defect behind the same report -- "the app was
never responsive to any user input and not even focusable", from a double-click
on `dist\ShenzhenPDF-win-x64.exe`. None of them was what was on the screen. This
is what was.

His `%APPDATA%\ShenzhenPDF\session.yaml` holds `windows: []` and his
`settings.yaml` holds `recentlyOpened: []`, so there is nothing to restore and
the app comes up in its EMPTY state. That state drew the full toolbar exactly as
it draws it with a document open -- the Side Panel switch, the two power tools, a
page field, `/ 0`, the page arrows, the Fit Width popup, the zoom pill, the
reading-theme button, the Find field, the Regex box, the overflow `...` and the
Map switch accent-filled and ON -- at full contrast, every one of them inert.
Down the right edge was a minimap strip with nothing in it. The only affordance
was one line of grey text: "No document open â€” Ctrl+O to open one, or drop a PDF
here".

Measured on that window, at 1, 5 and 30 seconds after launch: foreground,
`IsWindowEnabled` true, `IsHungAppWindow` false, on screen, z-order 0, answering
`WM_NULL` via `SendMessageTimeout` in 0 ms. Ctrl+O reached the keymap and put a
real system `#32770 'Open'` dialog on screen. The window was healthy the whole
time.

So the defect is not a window that does not respond. It is a window on which
thirteen controls respond to nothing, drawn identically to the same thirteen
controls when they work. A person who clicks the page arrow, drags the zoom and
flicks the Side Panel switch has performed a complete, correct test of the
application and has been told, three times, that it is broken. No crash test, no
`launch.health` probe and no responsiveness measurement can see that, because
every one of them passes.

### What the original does, and where that is written

macOS never presents an open panel at launch. `-performStartupDocumentWork`
(`portable/mac/ShenzhenPDFMac.mm:845-877`) has three arms -- paths on the command
line, tabs to restore, and neither -- and the third is
`[self showEmptyDocumentViewWithMessage:@"Open a document"]` (`:860-862`). There
is no `applicationOpenUntitledFile:` and no `applicationShouldOpenUntitledFile:`
in the tree; the only `NSOpenPanel` is `SPDFMacFileBrowsing.mm:12-20`, reachable
from File > Open, from the tab strip's `+` and from a typed path that turns out
to be a folder.

The window is built and shown unconditionally, before any document work
(`:737-769`), and the toolbar is built in full. Enablement is then imperative,
control by control, in `-updateControls` (`:10218-10248`):
`_sidebarToggleButton`, `_pageField`, both `_zoomSegments`, `_fitModePopup`,
`_searchField`, `_findRegexCheckbox`, `_ocrButton`, `_minimapToggleButton` and
both `_pageSegments` (`:10188-10189`) all take `hasDoc`. The page field's text
becomes `@""`, the count label reads `/ 0`, and the minimap is force-hidden
whatever the preference says (`-setMinimapActuallyVisible:` is
`visible && [self hasActiveDocument]`, `:9137`, called with `NO` at `:5267`).
`-validateMenuItem:` greys every command except a whitelist that is mostly ways
IN -- `openDocument:`, `openRecentDocument:`, `showAboutPanel:` (`:16317-16325`)
-- and then `if (!hasDoc) return action == @selector(unimplementedMenuItem:);`
(`:16424`). The placeholder itself is 16 pt medium `secondaryLabelColor`, one
centred line at midY - 18 (`SPDFMacDocumentView.mm:509-530`).

The GTK original is the same policy with less decoration: a presented window with
zero tabs and no file dialog (`spdf_app.c:340-379`), `update_page_controls`
desensitising the same row (`spdf_window.c:142-160`), `"/ â€“"` for the count, and
`"No Recent Documents"` appended with no action name so GTK renders it
insensitive.

So the port had the STRUCTURE right -- full window, full toolbar, one centred
line -- and had simply never ported the enablement pass. That is the whole of the
visual defect.

### The one place this port cannot follow, and what it does instead

macOS's way out of the empty state is File > Open in the menu bar. This port has
no menu bar: the menu moved into the toolbar's `...` overflow button when the tab
strip became the title bar (`spdf_win_chrome_input.h`, `SPDF_WIN_CA_APP_MENU`). A
three-dot button is not a discoverable way to open a document, and naming a
keyboard shortcut in grey text is not an affordance -- it is a fact the reader has
to already have. So the empty canvas gets a primary "Open a PDFâ€¦" button, routed
to `SPDF_WIN_CMD_OPEN`: the same command Ctrl+O and the strip's `+` post, so
there is one open dialog however it is reached. The placeholder shrinks to "No
document open" -- as short as the mac's own -- and the drop hint moves under the
button.

### Where the two sides agree

The router used to be unable to ask the question at all.
`chrome_layout_for_input()` builds the model the input router hit-tests against,
and it `memset`s it and then fills only the fields that affect GEOMETRY -- so
`page_count` was 0 on every event, with a document open or not. Gating the row on
it without fixing that would have refused the entire toolbar of every document
this app opens. Both page fields are filled from the canvas now, beside
`markdown`, which is there for exactly the same reason.

With that, `spdf_win_chrome_empty.h` holds one predicate
(`spdf_win_toolbar_item_enabled`) and one rect
(`spdf_win_chrome_empty_open_rect`), and the painter and the router each call
both. A control the painter dims is a control the router reports as "not a
target"; a button the painter draws is a button the router routes. That is
`spdf_win_chrome.h`'s standing rule -- "hit-testing and painting must agree
exactly ... here they agree only if they call the same functions" -- applied to
state rather than to position.

Every handler behind those thirteen controls already refused a NULL canvas, so a
click on a dimmed arrow was already inert. It was inert BY ACCIDENT, four files
away, and the press still took the focus off whatever had it and still cost a
frame. Refusing it in the router is what makes the dimming true rather than
decorative.

### Three controls stay live, and one had to be repaired to earn it

The overflow `...` is this port's File menu and the thing an empty window most
needs; its own greying is `spdf_win_menu_rules.h`'s and already reads
`has_document`. The separator is a hairline of decoration. The reading-theme
button is the interesting one: macOS does not disable it, because a reading theme
is a setting and not a property of the document -- but on Windows
`chrome_toggle_theme()` opened with `if (!a->canvas) return 0;`, so it was the one
button on the empty window that looked live and was not. It flips the setting and
repaints without a canvas now. `settings.yaml` gets the choice either way, so the
next launch opens in it.

The Map switch went the other way. It was drawn accent-filled and ON next to a
strip with nothing in it -- the loudest false promise in the row. Both the switch
and the strip now follow the document, which is what `:10236` and `:9137` do
together.

### Measured, before and after

| | before | after |
| --- | --- | --- |
| document-dependent controls at full contrast | 13 | 0 |
| clicks on them the router accepts | 13 | 0 |
| empty minimap strip | drawn | gone |
| ways to open a document without knowing a shortcut | 0 | 1 (mouse, Tab, Enter) |
| with-document window, 1120 x 800 at 144 dpi | -- | **byte-identical** |

The last row is the one that matters for the layout: the same fixture captured
through `screenshot-window.ps1` from both builds differs in zero pixels, and the
layout differential reports 0 mismatches in 395,514 comparisons. The disable is a
colour and a refusal; no rect moved, at 1.0, 1.25, 1.5 or 2.0 scale, which
`empty_state_test.c` asserts edge by edge for every item in the row.

### The keyboard, and why the button is in the focus enum

Tab with no document focuses the button and Return or Space presses it.
`SPDF_WIN_FOCUS_OPEN` joins `spdf_win_text_focus` -- the enum of the three
typeable fields -- as its one member that is not a field, because that enum is
already where the window keeps "what does the keyboard belong to", and a second
variable beside it is a variable that can go stale against it.
`chrome_focused_field()` returns 0 for it, so no edit call can be handed a NULL
buffer.

Tab with a document open is left exactly as it was: unbound. A focus ring order
over eighteen toolbar controls is a feature this port has not written, and
half-writing it here would be worse than not having it.

Ctrl+F and Ctrl+G now do nothing on an empty window. macOS keeps `focusFind:` on
its always-enabled whitelist even while it disables the field itself, and this
port takes the field's word for it: a control drawn dead must not be focusable by
any route, or the fix reappears as an accent focus ring on a grey field. That is a
deliberate divergence and it is the one that leaves nothing on screen
contradicting itself.

### Driven with real input

The probe launches the exe with `SPDF_WIN_SETUP_NO_PROMPT=1` and a private
`--state-dir`, sizes the window, checks it is foreground before sending anything,
then drives it with `SendInput` and enumerates every window of the process
afterwards. Three ways in were exercised on the built binary and all three put a
real `#32770 'Open'` dialog on screen, enabled and on-screen, which the probe then
cancels:

| gesture | result |
| --- | --- |
| click at the button's centre | `#32770 'Open'` at 91,80-1531,980 |
| Tab, Return | `#32770 'Open'` at 92,80-1532,980 |
| Tab, Space | `#32770 'Open'` at 92,80-1532,980 |
| Tab alone | focus ring drawn, no dialog |
| Ctrl+O (unchanged) | `#32770 'Open'` |

The reading-theme button was driven the same way, and it is the cleanest single
measurement in this section because it is the same click on both builds:

| build | click on the reading-theme button of the EMPTY window |
| --- | --- |
| before | **0 pixels changed** |
| after | client area 11,0-1109,789 changed -- the window is in the other theme |

One measurement worth writing down because it cost twenty minutes: the FIRST run
of a freshly built exe missed the Tab. The probe sends Tab 900 ms after the
window appears, and a cold binary's first launch is still settling then -- a
Ctrl+O sent later in the same run worked. It reproduced as "the keyboard route
does not work" and was a warm-up artefact. Interleave runs, or launch the binary
once before measuring it.

### One suite case fails here and it is the desktop, not the code

`launch.budget` records FAIL on this machine with
`health=FAIL the window was in front (z-index 0) in only 0 of 5 runs`, while its
actual budgets pass with room to spare -- 145 ms to a window against 300, 141 ms
to a page against 600. `ZIndex()` counts position among visible top-level windows
wider and taller than 200 px, and while an agent session is open the Claude
desktop window sits at z=0 and holds the foreground, so a process the harness
launches can never come to the front. Windows' foreground-activation rules are
doing exactly what they are meant to.

Measured both ways, because "it is environmental" is a claim and not a
measurement:

| | in-harness `--filter launch.budget` | `measure-launch.ps1` run directly, same 300/600 budgets, 5 runs |
| --- | --- | --- |
| this branch | FAIL, 0/5 in front | `health=OK budget=OK`, 5/5 in front |
| the same branch with the change stashed | FAIL, 0/5 in front | `health=OK budget=OK`, 5/5 in front |

Identical on both trees, so it is not this change; and it passes on both trees
the moment the launching process is itself in the foreground.
`launch.invariant`, whose whole job is "the focused window on top", passes in the
harness -- it activates the windows it checks rather than relying on a launch to
do it. `launch.health` and `window.stress` pass too.

### What is not covered

The button's PIXELS are not pinned by a headless expectation.
`empty_state_test.c` asserts its geometry, its hit test and its route, all of
which are pure; the drawing is a `static` function in
`spdf_win_chrome_empty_paint.h` reached only through
`spdf_win_chrome_paint_all()`, so it is on the headless compose path but no `d2d`
case names it. The before/after captures are the evidence for the appearance.

Also not covered: the empty state's vertical scroller. It is still drawn, with a
full-length thumb in a trough that scrolls nothing. That is macOS's behaviour
too -- `autohidesScrollers = NO` on both its scroll views -- so it was left alone
rather than folded into this change.

## 20. The Open dialog was starved of its first paint by our own message loop (2026-09-07)

"When you click open pdf, then everything freezes." From the empty state, the
`Open a PDF…` button -- or Ctrl+O -- put a real `#32770 'Open'` on screen with
its title bar and its dark navigation pane painted, and everything else a flat
white rectangle: the file list, the `File name` box, the file-type combo, and the
Open and Cancel buttons, all blank, indefinitely.

### It was never a hang, and that is why nothing caught it

Measured for 30 s with the dialog up:

| | |
| --- | --- |
| dialog `SendMessageTimeout(WM_NULL)` | 0 ms |
| dialog `IsHungAppWindow` | false |
| main window ping / hung / `Process.Responding` | 0 ms / false / true |
| threads, top-level windows | 33, 21 |
| `launch-health.log` | `phase=stall … modal=1 owned=1`, every 2 s |

A control on the same desktop, same 2880x1800 at 150%: `powershell.exe -Sta`
showing `System.Windows.Forms.OpenFileDialog` -- which is the same
`IFileOpenDialog` -- rendered perfectly. So it was this app.

### The dialog was whole; only the pixels were missing

Walked from a worker thread while `Show()` was in its nested loop, every child
existed, was visible, was enabled and had a sane rect: `DUIViewWndClassName`,
`DirectUIHWND`, `NamespaceTreeControl`, `SysTreeView32 'Navigation Pane'`,
`SHELLDLL_DefView 'ShellView'`, the breadcrumb `ToolbarWindow32`, the
`ComboBoxEx32`, the buttons. GDI and USER handles were 164 and 157 -- nowhere
near a quota. Three measurements then separated "cannot draw" from "was not
asked to":

| | distinct colours | near-white |
| --- | --- | --- |
| the dialog's client, off the screen | 13 | 77.2% |
| `PrintWindow(dlg, dc, PW_RENDERFULLCONTENT)` | 4584 | 0.7% |
| the screen again, after one `RedrawWindow` with `RDW_INVALIDATE`, `RDW_ALLCHILDREN` and `RDW_UPDATENOW` | 4886 | 0.5% |

The dialog draws itself correctly the moment anything invalidates it, and then
stays correct. Sampling the screen every 400 ms from the click showed content at
t=412 ms (720 colours, 0.1% white) and the blank state from t=873 ms onwards: the
window was erased on being shown and never painted again.

A `WH_CALLWNDPROC` + `WH_GETMESSAGE` pair on the UI thread said why. At
t=547 ms `WM_SHOWWINDOW` reached the `#32770` and `WM_NCPAINT` + `WM_ERASEBKGND`
went to every window in its tree; between t=562 ms and the forced repaint at
t=4000 ms **no `WM_PAINT` was generated for any of them**. `WM_PAINT` is not
posted, it is SYNTHESISED by `GetMessage`/`PeekMessage` for a window with an
update region -- and only when the queue holds nothing else.

### What the queue held

Two facts, measured together, name it. First, the process was burning CPU while
the dialog sat there doing nothing: **1484 ms of processor time over 1504 ms of
wall clock**, one core pinned. Second, the same hooks with the message whitelist
removed end in an unbroken run of one message, retrieved by the pump, in the same
millisecond, forever:

```
t=1313ms post 0x02A3   hwnd=…4F0112 cls=ShenzhenPDFWindow w=0x0 l=0x0
t=1313ms post 0x02A3   hwnd=…4F0112 cls=ShenzhenPDFWindow w=0x0 l=0x0
…
```

`0x02A3` is `WM_MOUSELEAVE`, on our own window. The loop was four lines of our
own code:

- `window_proc`'s `WM_MOUSELEAVE` case sent a synthetic `(-1, -1)` mouse move
  through `dispatch_mouse()` to clear the chrome's hot flags;
- `dispatch_mouse()` armed `TrackMouseEvent(TME_LEAVE)` for every
  `SPDF_WIN_INPUT_MOUSE_MOVE`, including that one;
- `TrackMouseEvent` called while the pointer is NOT over `hwndTrack` posts
  `WM_MOUSELEAVE` back immediately -- documented behaviour, not a quirk;
- so: leave, arm, leave, at the speed of the pump, for as long as the pointer was
  outside the window.

The Open dialog appears UNDER the pointer, which is by definition outside our
window, so it arrives into a queue that is never empty and never gets the paint
it needs. Two further consequences follow from the same fact and were both
reported separately: posted messages outrank hardware input in `GetMessage`'s
order, so **keystrokes starved too** -- Escape on the Ctrl+Shift+O `Open Path`
dialog did nothing, measured: dialog still up, main window still disabled -- and
our own window stopped repainting as well, which is the whole of "everything
freezes".

Every other hypothesis was tested and eliminated first, each with a measurement:
COM apartment (the UI thread is `MAINSTA`, a proper STA; `CoGetApartmentType`
logged at the call site), the owner window (`Show(NULL)`, a plain
`WS_OVERLAPPEDWINDOW` owner, and hiding the main window all still blank -- note
`Show(NULL)` is not ownerless, comdlg32 falls back to `GetActiveWindow()`), the
custom `WM_NCCALCSIZE` frame, the GPU prewarm, `SetPreferredAppMode(AllowDark)`,
the embedded manifest, PerMonitorV2, Common Controls 6, Direct2D with a live
`ID2D1HwndRenderTarget`, every `SetFileTypes` / `SetOptions` / `SetTitle` /
`SetFolder` call on the dialog, every feature the launch arms after the window is
shown, and draining the queue before `Show()` (it refills instantly). The one
thing that DID render was `Show()` on a fresh STA worker with its own pump -- a
thread whose queue is not being flooded -- which is what pointed at the pump
rather than at the dialog. `portable/win/tests/open_dialog_probe.cpp` is the
standalone half of that bisection: it shows the same dialog with each app
ingredient switchable, and it renders in every combination, which is what proved
the fault was ours.

### The fix

`TrackMouseEvent` is now called from one place, `track_mouse_leave()` in
`spdf_win_window_input.h`, reached only from `WM_MOUSEMOVE` -- the one message
that proves the pointer is in our client area -- and guarded by a
`tracking_leave` flag so it is armed once per entry. `WM_MOUSELEAVE` clears the
flag and asks for nothing. `dispatch_mouse()` no longer arms anything, which is
what makes the loop unreachable rather than merely absent. The caption's
`TME_NONCLIENT` tracker in `spdf_win_window_caption.h` already had that shape:
armed from `WM_NCMOUSEMOVE`, never from `WM_NCMOUSELEAVE`.

After: the dialog's client is 4957 distinct colours and 0.6% near-white, the
process burns 0 ms of CPU while it sits there, Escape closes the `Open Path`
dialog and re-enables the window, and a typed path plus Enter opens the document
(title `Shenzhen PDF` to `golden.pdf - Shenzhen PDF`, 98% of pixels changed).

### The watchdog was crying wolf

While the dialog was up, `spdf_win_health_log.h`'s watchdog wrote `phase=stall`
every two seconds, because a nested modal loop does not turn OUR pump so the
heartbeat goes stale. A nested modal loop is not a stall, and the one instrument
this port has for a genuinely wedged pump must not fill itself with false alarms
every time a reader takes a moment over a file picker. The watchdog now asks
`spdf_win_health_is_modal()` -- disabled window with an enabled visible window of
ours owned by it, the same computation as the line's `modal=` field, and no
message sent -- and writes one `phase=modal` line per episode instead, then stays
quiet until the dialog goes away. A `stall` line now means a stall.

### The case that would have caught it

`dialog.open` (`portable/win/tests/open-dialog.ps1`, registered beside
`launch.health` and `window.stress`). It launches the built exe bare, finds the
empty state's accent button BY COLOUR so a changed constant cannot make it click
somewhere harmless, clicks it, and then measures the DIALOG'S OWN client pixels:
distinct colours and flat white, over the whole client and over the bottom band
alone, because the bottom band is only 15% of the pixels and a whole-client
threshold could pass with the buttons blank. It also measures the CPU the process
burns while the dialog is idle -- the cause, not the symptom -- types a real path
in and asserts the document opens, and reads `launch-health.log` back to assert
no false `stall`. BLOCKED (68) on a locked workstation, the screen saver's
desktop, or a desktop that refuses the window the foreground.

Verdict on master: FAIL on all five assertions -- `distinct=13 near_white=77%`,
bottom band `distinct=12`, `cpu=1484 ms over 1504 ms`, dialog never closed, five
`phase=stall` lines. On this branch: all five pass.
