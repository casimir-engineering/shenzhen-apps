# Windows Launch Performance — Measured, Diagnosed, Ranked

The requirement is that launch "feels instant". This document says what that
means in milliseconds for this app, where the time actually goes on Windows
(measured, not inferred), what was fixed, what the fix is worth, and what is
left for whom. Everything here was measured on 2026-09-02 on the native box
(Ryzen 5 6600U, Radeon 680M iGPU, driver 32.0.12033.1030, Windows 11 26200,
one 144-dpi display, 32 GB) with the tooling the same change adds:

- `portable/win/src/spdf_win_launch_profile.h` — the in-process timeline
  (`SPDF-LAUNCH <ms> <phase>`, from process creation);
- `portable/win/measure-launch.ps1` — the external harness (polled, DPI-aware,
  N runs, medians, cold copies, session-restore fixtures);
- `portable/win/tests/make_launch_fixtures.py` — the 120-page and image-heavy
  fixtures;
- `portable/win/tests/run-tests-native.launch.sh` — the `launch.budget` case.

Section 1 defines the bar. Section 2 is the measured baseline. Section 3 is
the diagnosis. Section 4 is what landed, with before/after. Section 5 is the
ranked plan for the owned files. Section 6 is the tooling, including two traps
that cost time. Section 7 maps the macOS strategy's phases onto Windows.

## 1. What "feels instant" means here, in numbers

Three moments matter, all measured from the kernel's process-creation
timestamp, which is the earliest instant the double-click can be blamed on
the app:

| moment | what the reader sees | bar |
|---|---|---|
| **window visible** | the frame appears | **< 100 ms** |
| **first page** | the page and its chrome are on screen | **< 150 ms warm** |
| **settled** | nothing is still churning that will make the first scroll stutter | first scroll never waits |

The 100 ms figure is the classic perceptual budget for a response to feel
immediate; the 150 ms first-page bar is argued for below rather than assumed.
The floor on this machine is not the app: a 140 KB console program that does
nothing takes **13-16 ms** from process creation to `main()`
(`launch_premain_probe`, six runs), and the AMD driver's D3D device creation
costs **50-160 ms** per device (Section 3.2). A first page under 150 ms warm
therefore requires that the GPU device is never on the UI thread's critical
path and that nothing the document does not need runs before the first frame.
Both are achievable; the second is already true.

**The window-visible bar is met today (37-49 ms) and was never the problem.**
The observations' "window visible 45-88 ms" (§4.8) measured `ShowWindow`; the
client area behind that frame stayed blank for another 130-230 ms, which no
external stopwatch had seen because the sampler that tried returned blank
frames (Section 6.2 says why).

## 2. Baseline: where the time goes

Median of 7 warm launches each, `ShenzhenPDF.exe` built from 731606aae with
only the timeline markers added, window 1680x1200 physical (1120x800 at 144
dpi). Milliseconds from process creation. The desktop was **locked** for every
measurement in this document (LockApp.exe present, see 6.3); the in-process
marks do not depend on compositing, but the final `EndDraw` may behave
differently on a composited desktop and should be re-measured once unlocked.

| case | window visible | first page (`first-compose-end`) | of which: HWND target | page render | texture upload | EndDraw | CPU ms 700 ms after first page |
|---|---|---|---|---|---|---|---|
| golden.pdf (2 KB, 2 pages) | 45 | **199** | 94 | 18 | 9 | 10 | 219 |
| outline.pdf (6 KB, 4 pages, outline) | 39 | **178** | 79 | 15 | 10 | 8 | 203 |
| pages120.pdf (120 text pages, 12 chapters) | 43 | **189** | 82 | 18 | 10 | 13 | 359 |
| images.pdf (6 pages, 11 MB image each) | 49 | **281** | 117 | 65 | 11 | 13 | 484 |
| NASA scan (4.8 MB, the observations' document) | 41 | **202** | 79 | 34 | 12 | 12 | 984 |
| bare launch, nothing to restore | 41 | 143 | 80 | — | — | 12 | 94 |
| session restore, 5 tabs of outline.pdf | 37 | **167** | 79 | 14 | 10 | 8 | 188 |
| outline.pdf, `--dark` | 40 | 178 | 87 | 16 | 8 | 8 | 172 |

The fixed part of the timeline, the same on every document (outline.pdf run):

```
SPDF-LAUNCH      17.5ms d2d-create-begin       <- loader, CRT, static imports, arg parse
SPDF-LAUNCH      20.6ms com-initialized        3.1  CoInitializeEx
SPDF-LAUNCH      20.7ms d2d-factory            0.1
SPDF-LAUNCH      22.9ms wic-factory            2.2  CoCreateInstance(WIC) -- window never uses it
SPDF-LAUNCH      23.1ms dwrite-factory         0.2
SPDF-LAUNCH      23.4ms session-restore-begin
SPDF-LAUNCH      27.4ms session-restored 0     4.0  for an ABSENT session.yaml
SPDF-LAUNCH      29.0ms spdf-open-end          1.6  MuPDF context + open
SPDF-LAUNCH      29.2ms canvas-created         0.2  page 0 measured, nothing else
SPDF-LAUNCH      33.6ms hwnd-created           4.4  RegisterClass + CreateWindowExW
SPDF-LAUNCH      50.2ms show-window-returned  16.6  ShowWindow: frame on screen, client BLANK
SPDF-LAUNCH      50.2ms first-paint-begin
SPDF-LAUNCH     129.6ms first-hwnd-target     79.4  CreateHwndRenderTarget = D3D device + driver
SPDF-LAUNCH     131.1ms outline-doc-opened     1.4  the panels' own spdf_open
SPDF-LAUNCH     131.3ms outline-loaded 6       0.2
SPDF-LAUNCH     132.4ms thumbs-doc-opened      1.0  the thumbnail store's own spdf_open
SPDF-LAUNCH     134.6ms thumbs-sweep-end 4     (on its thread)
SPDF-LAUNCH     149.6ms first-page-render-end 15.0  MuPDF, synchronous, 1091x1412
SPDF-LAUNCH     149.9ms first-compose-begin
SPDF-LAUNCH     159.8ms first-chrome-painted   9.9  incl. thumbs service + 6 worker spawns
SPDF-LAUNCH     169.9ms first-page-texture    10.1  swizzle + CreateBitmap upload
SPDF-LAUNCH     177.8ms first-compose-end      7.8  EndDraw = first Present
SPDF-LAUNCH     178.7ms first-thumbnail-adopted
```

Headless, for scale (`--render-png golden.pdf 0 2`, PNG on disk): 109 ms to the
texture, of which 52 ms is the software WIC render target's own first draw --
the same "first device" tax in its software form.

**Cold** (fresh copy of the exe under a new name, unbuffered write so it is
not in the file cache; 3 runs, measured while another track was building, so
treat as indicative): pre-main 74 ms (Defender scans the new 40 MB file;
warm 17), `CreateHwndRenderTarget` **385 ms**, first texture upload 100 ms,
first EndDraw 151 ms, first page **872 ms**. The GPU driver keys its shader
cache on the executable: a never-seen exe pays for compiling Direct2D's
pipeline shaders at device creation and first draws. That is the real cold
start on Windows and it is per *binary identity* -- one launch per install or
update, not per boot.

## 3. Diagnosis

### 3.1 The document is not the problem

Every document-proportional cost together -- `spdf_open` (1.5 ms), the panels'
second and third `spdf_open` (1-1.5 ms each), the outline (0.2-1 ms), page-0
measurement (0.1 ms; 1.1 ms on the 120-page file), the synchronous first-page
render (15-65 ms), the texture upload (8-12 ms) -- is **30-80 ms** of a
170-280 ms first page. The canvas does not sweep page sizes (it measures page 0
and estimates the rest; `spdf_win_canvas.cpp:164-173`), so a 120-page file
opens in the same time as a 4-page one, and the minimap's size sweep runs on
its own thread (2-5 ms for 4-120 pages, done before the first page render
finishes). Session restore with 5 tabs materialises one document and costs
what a single-tab launch costs (167 vs 178 ms). The strategy doc's Phase 2
(exact page-geometry cache) has nothing to save on Windows: there is no
all-pages sweep to remove.

### 3.2 The GPU device is the problem, and it sits inside the first paint

`ID2D1Factory::CreateHwndRenderTarget` costs 79-117 ms warm because the first
hardware target a Direct2D factory makes creates its D3D device, and on this
driver device creation is slow. `launch_gpu_probe` (three runs, in-process,
isolated):

| step | ms |
|---|---|
| `D3D11CreateDevice(HARDWARE)`, first in the process | 96-158 |
| the same again (driver already loaded) | 51-89 |
| `D3D11CreateDevice(WARP)` | 3-5 |
| `CreateHwndRenderTarget`, first for the factory (two D3D devices already exist) | 56-76 |
| a second `CreateHwndRenderTarget` on the same factory | **0.6-2.5** |
| `ID2D1Factory1::CreateDevice(IDXGIDevice)` on an existing device | 3-6 |
| `CreateSwapChainForHwnd` + `CreateBitmapFromDxgiSurface` | 4.5 |
| first `EndDraw`+`Present` on that chain | 1.2-1.8 |

Two conclusions. A D3D11 device made on a worker does **not** make Direct2D's
own device cheaper (E1, measured: the UI thread still paid 45 ms after the
worker's 60-100 ms). But a factory shares one device across all its hardware
targets, and `launch_gpu_probe2` shows a `MULTI_THREADED` factory shares it
across threads: after a worker creates a throwaway target on a hidden window,
the UI thread's real target costs **0.4-0.5 ms** and its first `EndDraw`
1.8-2.2 ms. That is the fix in Section 4.1.

### 3.3 Does the window appear before or after the page?

Before, by 130-230 ms. `ShowWindow` returns at ~40-60 ms with the frame on
screen; `UpdateWindow` then runs the first `WM_PAINT` synchronously, and that
paint is where the target, the panels' documents, the page render and the first
present all happen. The reader sees an empty window fill in. Whether that is
better or worse than a window that appears complete 100 ms later is a design
call for the windows track; Section 5.1 gives the numbers for both.

### 3.4 The post-first-paint burst

Within 700 ms of the first page the process has burned 200-1000 ms of CPU on
23 threads: two render pools of `cores/2 = 6` workers each (the canvas's
prefetch pool and the thumbnail store's), each worker opening its own MuPDF
document, plus the size sweep. On the NASA scan that is ~1 s of CPU while the
reader's hand is reaching for the wheel. Nothing here blocks the UI thread,
and thumbnails landing invalidate at most a repaint each, but on a laptop it is
fan noise and it competes with the first scroll's synchronous render of the
next page. The strategy's Phase 4 (tiers) applies: thumbnails are Tier 2 and
inactive-tab work Tier 3/4; today everything starts inside the first paint.

## 4. What landed (unowned files), before/after

### 4.1 GPU prewarm — `spdf_win_gpu_prewarm.h`, `spdf_win_d2d.cpp`

The Direct2D factory is created `MULTI_THREADED`; right after the factories
exist, the windowed path (one call in `spdf_win_main.cpp`, in the patch) starts
a worker that creates a hidden 64x64 window and a throwaway
`HwndRenderTarget` on it with the same properties `spdf_win_window.cpp` uses,
then parks until `spdf_win_d2d_destroy`. The UI thread's real target then
shares the device. The first frame's pixels are unchanged: same call, same
properties, same device type; `d2d.compose-*` and a byte comparison of seven
headless frames (light/dark chrome on outline.pdf, golden.pdf, images.pdf, and
the alpha fixture through `--render-png`) are identical to the baseline.

Interleaved A/B, median of 7 launches per cell, base (markers only) vs
E1c (this section) vs E2 (Section 5.1, the owned-file half), run back to back
per document on a box where other tracks were running tests throughout
(total CPU load gated at <= 45% before each cell, never quiet), so absolute
numbers are ~20% above Section 2's and the comparison within a row is what
counts. "first page" is `first-compose-end`; "page render done" is when the
synchronous MuPDF render finished, both from process creation.

| case | build | window visible | first page | HWND target ready | page render done | prewarm done |
|---|---|---|---|---|---|---|
| outline.pdf | base | 46 | **217** | 165 | 190 | — |
| | E1c | 36 | **166** | 120 | 143 | 120 |
| | E2 | 155 | **151** | 125 | 58 | 124 |
| images.pdf | base | 41 | **242** | 150 | 216 | — |
| | E1c | 56 | 290 (load spike: paint began at 74 vs 52) | 180 | 260 | 180 |
| | E2 | 170 | **164** | 137 | 101 | 136 |
| NASA scan | base | 50 | **264** | 176 | 236 | — |
| | E1c | 44 | **227** | 140 | 198 | 140 |
| | E2 | 183 | **179** | 148 | 110 | 148 |
| bare | base | 49 | 181 | 169 | — | — |
| | E1c | 42 | 168 | 140 | — | 140 |
| | E2 | 154 | 151 | 135 | — | 135 |
| restore, 5 tabs | base | 41 | **182** | 138 | 158 | — |
| | E1c | 42 | 206 | 140 | 165 | 139 |
| | E2 | 194 | 189 | 161 | 78 | 160 |

What the columns say. With the prewarm alone (E1c) the UI thread's target
costs ~1 ms but the first paint still *waits* for the worker (target ready ==
prewarm done, every row), so the gain is only the 20-30 ms of session/open/
window work that overlapped it, and under load it drowns in noise (images,
restore). With E2's reordering the page is rendered *while* the device is
being made (render done 58-110 ms, before prewarm done at 124-160), and the
first page lands 15-30 ms after the device: **-30% on outline (217 -> 151),
-32% on images (242 -> 164), -32% on the NASA scan (264 -> 179)**. The floor
that remains is the driver's device creation itself, 90-125 ms on this loaded
box and 80 ms quiet (Section 3.2): with E2 the first page is `prewarm-done +
compose`, so on a quiet machine it should sit at 110-140 ms -- under the
150 ms bar -- and on this box under load it sat at 151-189.

### 4.2 Lazy WIC factory — `spdf_win_d2d.cpp`, `spdf_win_d2d_png.h`

`CoCreateInstance(CLSID_WICImagingFactory)` cost 2.2-2.8 ms on every launch
and the window never uses WIC; it is created on the first `spdf_win_d2d_wic()`
call (PNG writers, clipboard, export). The PNG writer reached into `d2d->wic`
directly and the first build of this crashed every headless path; the identity
check caught it, and it now goes through the accessor.

### 4.3 Fast RGBA->BGRA swizzle — `spdf_win_d2d.cpp`

One 32-bit load and store per pixel at alpha 255 instead of three per-channel
selects; byte-identical output (pinned by the comparison above, including the
alpha fixture's premultiply branch). Worth ~1-2 ms of the 8-12 ms first
texture upload; the rest is `CreateBitmap` itself.

### 4.4 Not landed, and why

- **Moving the outline/thumbnail `spdf_open`s off the first paint**: 2-3 ms
  total, and the sidebar's chapter list in the first frame would change
  (guardrail). Not worth it.
- **Delay-loading `WindowsCodecs.dll` / `COMDLG32.dll`**: the whole pre-main
  is 5-8 ms above a bare exe's floor; not worth a linker-flag change in the
  shell track's file.
- **WARP**: a software device is 4 ms to create and would put the first page
  under 100 ms today, but §4.3 of the observations shows hardware and software
  Direct2D disagree on resampled pixels; changing the window's renderer is a
  product decision, not a launch fix.

## 5. Ranked plan for the owned files (patch in `windows-launch-profile.patch`)

1. **Paint before `ShowWindow`, and build the scene before the target**
   (windows track, `spdf_win_window.cpp` -- both hunks are in the patch and
   measured above as E2). Two changes to `paint()`/`spdf_win_window_show()`:
   the scene (page render, outline, panels) is built *before*
   `ensure_target()`, so the CPU work runs while the prewarm worker is still
   making the device instead of queueing behind it; and the first frame is
   painted and presented while the window is still hidden, so `ShowWindow`
   reveals a window that already has its page. Measured: first page 217 ->
   151 (outline), 242 -> 164 (images), 264 -> 179 (NASA scan), and the
   blank-client interval goes from 130-230 ms to zero -- the window appears
   ~110 ms later than today's empty frame, complete. `UpdateWindow` still runs
   a second paint from warm caches (a few ms) so the visible surface is
   current even if the hidden present was discarded. Trade-off for the track
   to own: today's empty frame at 40 ms versus a complete window at ~150.
   `spdf_win_window.cpp` is at the 500-line cap (499 with the markers); the
   patch takes it to 521, so applying it means extracting something first --
   the caption or input header split that file already practises.

2. **Prerender the first page while the GPU device is being made** (search
   track, `spdf_win_canvas*`; windows track, `spdf_win_main.cpp`). The
   synchronous first-page render is 15-65 ms and the render pool is idle until
   the first paint. A prerender at the system DPI and the initial client size
   -- the mac's "retarget the prerender" -- would land in the LRU under the
   key `ensure_page` looks up; a DPI mismatch is a cache miss and today's path.
   Exact by construction.
3. **Tier the post-first-paint work** (thumbs store, render pool sizing):
   start the thumbnail service after the first frame is presented rather than
   inside it, and give it 2 workers rather than `cores/2`. `spdf_win_render.c`
   is at the 500-line cap; the worker count needs an API or the file split.
4. **Session restore for an absent file costs 4-5 ms** (`spdf_win_state.c` /
   `spdf_win_paths.c`): `SHGetKnownFolderPath` plus a directory create for a
   file that is not there. Resolve lazily or cache; small but on every launch.
5. **`SPDF_STATE_DIR`** (mac commit c2799808b added it for exactly this): the
   harness backs up and restores the user's live `session.yaml` around every
   run because the state directory cannot be redirected; an override honoured
   only from `main()` would remove that risk.

### 3.5 Aside: an idle instance that is not idle

While gating the A/B on machine load, the user's running published instance
(`C:\spdf-build\ShenzhenPDF.exe`, pid 8240, started 16:12) was burning
4.25 s of CPU per 5 s -- ~85% of a core -- with 23 threads, after five hours
idle; a fresh instance of this tree on outline.pdf burns 0 ms in the same
window (`idle-probe`: 0 ms over two 5 s samples, 3 s after launch). Whatever
that instance is doing (a repaint/thumbnail loop against its document is the
obvious suspect), it is not launch and it is not reproduced here, but it is
the kind of thing that makes a machine feel slow at the next launch, and it
was not killed (it is the user's).

## 6. Tooling

### 6.1 The in-process timeline

`SPDF_WIN_LAUNCH_PROFILE=1` (stderr) or `=<file>` (append). One env check per
process; off, every mark is one load and one compare. Marks are relative to the
kernel's process-creation timestamp via `GetProcessTimes` + `QueryPerformance
Counter`, so they share an origin with an external stopwatch that reads
`Process.StartTime`. Insertion points, all applied here except where the file
is another track's (those are in the patch):

| mark | file:line | owner |
|---|---|---|
| `d2d-create-begin`, `com-initialized`, `d2d-factory`, `wic-factory`, `dwrite-factory` | `spdf_win_d2d.cpp` `spdf_win_d2d_create` | landed |
| `first-compose-begin`, `first-chrome-painted`, `first-page-texture`, `first-compose-draws-issued`, `first-compose-end` | `spdf_win_d2d.cpp` `spdf_win_paint`/`page_texture` (ONCE) | landed |
| `outline-open-begin`, `outline-doc-opened`, `outline-loaded N`, `thumbs-counted` | `spdf_win_chrome_content.cpp` | landed |
| `thumbs-open-begin`, `thumbs-doc-opened`, `thumbs-sweep-begin/end N`, `thumbs-service-created`, `first-thumbnail-adopted` | `spdf_win_chrome_thumbs.cpp` | landed |
| `gpu-prewarm-begin/done` | `spdf_win_gpu_prewarm.h` | landed |
| `session-restore-begin`, `session-restored N`, `spdf-open-begin/end`, `canvas-created` | `spdf_win_tabs_app.h` | patch (windows) |
| `hwnd-created`, `show-window-returned`, `update-window-returned`, `first-paint-begin`, `first-hwnd-target`, `first-scene-built`, `first-paint-end` | `spdf_win_window.cpp` | patch (windows) |
| `canvas-create-begin`, `canvas-page0-measured`, `first-page-render-begin/end WxH` | `spdf_win_canvas.cpp` | patch (search) |
| the prewarm call | `spdf_win_main.cpp:439` | patch (windows) |

`spdf_win_main.cpp` (499 lines) and `spdf_win_render.c` (499) carry no marks:
the ratchet has no room, and the process-creation origin already covers
everything before `d2d-create-begin`.

### 6.2 Why the earlier PrintWindow sampler returned blank frames

Three independent causes, and the harness handles each:

1. `PrintWindow` without `PW_RENDERFULLCONTENT` returns black for a Direct2D
   client; with `PW_CLIENTONLY | PW_RENDERFULLCONTENT` it returns a flat client
   for this window on every sample (measured, forever). The whole-window form
   with `PW_RENDERFULLCONTENT` alone -- what `screenshot-window.ps1` uses --
   then cropped to the client rectangle is the one that works.
2. A host that is not per-monitor DPI aware gets virtualised rectangles and
   captures a crop (observations §5.1).
3. Until the first `WM_PAINT` completes the client **is** blank: the window is
   visible ~130-230 ms before it has content. The first non-blank sample *is*
   the measurement, so the harness bounds blank-sampling to 2.5 s rather than
   treating a blank frame as a failure.

Each whole-window sample costs 30-50 ms at 1702x1211, so the external first-
pixels number has that granularity; the in-process `first-compose-end` mark is
the precise one and the harness reports both.

### 6.3 The lock guard missed the Windows 11 lock screen

Both capture scripts checked for `LogonUI.exe`; this machine was locked with
only `LockApp.exe` running, the control capture came back as one flat colour,
and `screenshot-window.ps1`'s pixel backstop was what said so. Both scripts
now check `LogonUI, LockApp`. The harness proceeds without the sampler when
locked (the in-process timeline needs no compositing) and refuses (68) only
when a budget was asked for.

### 6.4 Two PowerShell traps in the harness's own history

Variables are case-insensitive: `$runs = @()` silently overwrote the typed
`[int]$Runs` parameter, and `$exe = Join-Path ...` overwrote `$Exe`, making the
cold copy read its own destination. Both presented as unrelated type errors.
And the session guard had a hole: a bare launch that exits with no tabs writes
`windows: []` with no window id in it, so the "is this file ours?" test did
not recognise it and left the user's session file empty (their live instance
rewrites it on quit, so nothing was lost, and the earliest backup was put
back). An empty session after a run now counts as ours.

## 7. The macOS strategy's phases, on Windows

| phase | applies? | why |
|---|---|---|
| 1 Measure precisely | done | this change |
| 2 Exact page-geometry cache | **no** | the canvas never sweeps pages; the sweep that exists is off-thread and 2-5 ms |
| 3 Simplify layout stabilisation | no | one relayout per first paint; nothing repeated |
| 4 Stage post-first-paint work | **yes** | 23 threads and 0.2-1 s of CPU start inside the first paint (3.4) |
| 5 Binary hygiene | marginal | pre-main is 5-8 ms over a bare exe warm; cold, Defender's scan of a new 40 MB file is ~55 ms once per install; the GPU shader cache dominates cold start, not the image |
| 6 Display lists / copy reduction | later | the texture upload is 8-12 ms; the swizzle half is gone |
| (Windows-only) GPU device off the critical path | **the item** | Section 3.2, 4.1, 5.1 |

## 8. Measured again once the patch was applied (2026-09-03, wiring pass 2)

The prewarm call and E2 are in the tree. Medians of 7 warm launches each,
`measure-launch.ps1` against `C:\spdf-build\track-wiring2\ShenzhenPDF.exe`, same
machine, **still locked** (LockApp.exe, so the external first-pixels sampler is
BLOCKED and the `launch.budget` case with it — §6.3; the in-process timeline
needs no compositing). Milliseconds from process creation.

| case | window visible (external) | page render done | prewarm done | HWND target | first page (`first-compose-end`) | pre-show paint done | ShowWindow returned |
|---|---|---|---|---|---|---|---|
| outline.pdf | 146 | 73 | 118 | 118 | **142** | 142 | 155 |
| golden.pdf | 163 | 88 | 124 | 125 | **157** | 157 | 172 |
| bare launch | 137 | — | 115 | 116 | **131** | 131 | 148 |

Both mechanisms are visible in the outline.pdf row and both do exactly what
Section 4.1 predicted. The synchronous page render finishes at 73 ms, 45 ms
BEFORE the GPU device is ready at 118 — so on this build the document costs the
launch nothing at all: its work is spent inside a wait that existed anyway. And
the UI thread's own `CreateHwndRenderTarget` costs **0.4 ms** (118.1, after a
prewarm that finished at 117.7) where the baseline paid 79-117 ms on that line.

Against Section 2's baseline: first page 178 → **142** on outline.pdf and 199 →
157 on golden.pdf, under the 150 ms bar for the document the profile was written
against. The window now appears at ~145 ms rather than ~40 — and appears
**complete**: `pre-show-paint-done` precedes `show-window-returned` in every
run, so the blank-client interval that used to be 130-230 ms is zero by
construction rather than by measurement. What remains is the driver's device
creation itself (79-95 ms of prewarm here), which is Section 5's outstanding
item and not this pass's.

Not re-measured, and blocked for the same reason as before: the external
first-pixels number, and therefore `launch.budget`, needs a composited desktop.

## 9. Measured unlocked (2026-09-03, live-verification pass)

The two things §8 left blocked were the external **first-page-pixels** number
and the `launch.budget` case, both because a locked desktop is not composited.
The workstation was unlocked for this pass, so both have real numbers for the
first time. Section 8 is not rewritten; this is what the same harness says on a
composited desktop at HEAD `0fb7d8d92`, which is a **later build** than §8's
`track-wiring2`.

Medians of 7 warm and 7 cold launches per document, `measure-launch.ps1` against
`C:\spdf-build\track-live\ShenzhenPDF.exe`, milliseconds from the kernel's
process-creation time. Every launch carried a private `--state-dir` and the
harness ran with `APPDATA` redirected, so the reader's real session was neither
read nor written — which is why these numbers say nothing about session restore.

| case | window visible | **first client pixels (external)** | first-compose-end | page render done | prewarm done | HWND target | ShowWindow returned | WM_CLOSE → exit |
|---|---|---|---|---|---|---|---|---|
| golden.pdf, warm | 182 | **274** | 178 | 94 | 135 | 136 | 204 | 78 |
| golden.pdf, cold | 310 | **412** | 304 | 111 | 185 | 185 | 328 | 99 |
| outline.pdf, warm | 192 | **278** | 182 | 87 | 146 | 147 | 213 | 77 |
| outline.pdf, cold | 302 | **404** | 291 | 84 | 172 | 172 | 321 | 87 |
| pages120.pdf, warm | 181 | **273** | 174 | 87 | 137 | 137 | 201 | 80 |
| pages120.pdf, cold | 304 | **406** | 300 | 95 | 181 | 182 | 325 | 100 |
| images.pdf, warm | 240 | **345** | 234 | 187 | 162 | 188 | 269 | 91 |
| images.pdf, cold | 370 | **479** | 364 | 194 | 217 | 218 | 393 | 107 |

`launch.budget`'s own invocation (outline.pdf, 5 runs, the suite's 300 ms /
600 ms tripwires) reports **`budget=OK`, exit 0** — window median 174 ms, first
page 171 ms, first client pixels 265 ms. It was run with a private
`--state-dir` added, which is the one way it differs from
`run-tests-native.launch.sh`'s form; that case launches against the real
`%APPDATA%` on purpose and this pass was not allowed to.

**Four things the numbers say.**

**1. The external first-pixels figure carries ~100 ms of the sampler's own
cost, and cannot be compared with the in-process mark.** `sampler cost per
frame` was 89-110 ms in every row: a `PrintWindow` of a 1680×1200 window plus a
48×48 colour walk. The sampler therefore quantises to about one frame, and
`first client pixels` lands one sample-cost after `show-window-returned` in
every single row (274 vs 204, 278 vs 213, 345 vs 269 …). It is an **upper
bound** on when pixels appeared, not a measurement of it. `first-compose-end`
remains the number to track; the sampler's value is that it proves pixels
arrive at all, which is exactly what the lock made unprovable.

**2. First page is 174-182 ms warm here, against §8's 142 ms — and the whole
difference is the GPU driver, not the app.** `first-compose-end` tracks
`gpu-prewarm-done` + ~35 ms in every row, and prewarm ranged from **132 ms to
190 ms across this session** (§8 saw 118, §3.2 documents 50-160 ms for this
driver). The app's own work did not move: the synchronous page render still
finishes at 84-95 ms on text documents, 40-60 ms *before* the device is ready,
and `CreateHwndRenderTarget` on the UI thread still costs **0.4-1.2 ms**. Both
of the launch track's fixes hold live.

The drift is real and worth naming: repeating outline.pdf warm three times over
the session gave prewarm 146 → 174 → 190 ms and first page 182 → 220 → 235 ms,
monotonically, on a machine that was doing *less* each time. A control run with
the sampler disabled (`-SamplerTimeoutMs 0`) was **slower**, not faster, so the
sampler is not the cause. The likely one is thermal or driver state on a 6600U
laptop after ~90 device creations in half an hour. **Anyone comparing against
§8's 142 ms must re-measure §8's own build in the same sitting**; a single
median from a different afternoon is not comparable at this resolution.

**3. A composited desktop does not slow the app's own compose.** That was §2's
open question about `EndDraw` behaving differently once DWM is really
presenting. It does not: `first-page-render-end`, the render → prewarm gap and
the 0.4 ms HWND target are all indistinguishable from §8's. The extra
milliseconds are all in prewarm.

**4. An image-heavy document is the one case where the document IS on the
critical path.** In every text row the page render finishes before the GPU
device is ready, so the document costs the launch nothing — §8's conclusion.
`images.pdf` inverts it: prewarm finishes at 162 ms and the page render at
187 ms, so the first frame waits 25 ms on the document, and first page lands at
234 ms rather than 174. One 1700×2200 inflate plus a 2:1 downscale is enough to
take the lead. Section 5's first-page-prerender item would pay for itself here
and nowhere else.

**Cold is ~120 ms of constant overhead, not the 872 ms §4 recorded.** Every cold
row sits 100-130 ms above its warm twin, with the increase split between
`Process.Start` (2-3 ms → 16-21 ms) and prewarm. `measure-launch.ps1 -Cold`
writes an unbuffered copy under a fresh name each run, which defeats the image
cache but not Defender's reputation cache or the driver's shader cache once the
first such copy has been seen — so this measures cold *paging*, and the
once-per-binary-identity 872 ms remains a separate, larger effect. Two cold runs
did show it starting: single-run maxima of 1,057 ms (pages120) and 779 ms
(images) against medians of 304 and 370.

