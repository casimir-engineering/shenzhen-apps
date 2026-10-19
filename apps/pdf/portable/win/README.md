# The Windows port: `portable/win/`

A native Win32 + Direct2D ShenzhenPDF frontend on the same portable C core the
macOS and GTK4 apps use. Application sources under `src/`, the headless test
harness under `tests/`, the live-window tooling and the build plumbing at the
top level.

**Everything below is measured in this repository, on a native x64 Windows 11
desktop, and stated in the tense the tree is actually in.** This file has twice
been the last place a reader learned something false about the port; a claim
here without a command behind it is a defect, not prose.

## What changed, and why the old framing is gone

Two sentences ran the top of this file for months and both are now wrong:

- *"…compiles and runs all of it inside a Parallels Windows VM, driven entirely
  from the macOS command line."* That route exists and still works — its scripts
  are in this directory and it has its own chapter below — but it is no longer
  the primary one. The port is developed and tested **on the Windows box that
  owns the checkout**, natively, in Git Bash and `cmd`.
- *"Nobody has seen a ShenzhenPDF window open on Windows."* Somebody has.
  `portable/win/verify-phase1.ps1` reports **7 passed, 0 failed, exit 0** in
  light and in dark, the window's client area is byte-identical to the headless
  compose at the same viewport and DPI, and six live captures are committed in
  `portable/docs/windows-captures/`. See `portable/docs/windows-native-observations.md`
  §0 and §4.6 — including §4.6's warning that a **locked** workstation produces
  a black capture that looks exactly like a window that painted nothing.

The port's architectural rule survived both changes and is what made the second
one worth having: **`spdf_win_paint()` must never require an `HWND`.** The
window's `WM_PAINT` and the headless probe call the same compose path, which is
why the offscreen pixel tests turned out to be evidence about the real window
rather than about a parallel code path.

## TL;DR — the native commands

Run these from the repo root. **Address every `.cmd` by path**: this box sets
`NoDefaultCurrentDirectoryInExePath=1`, so a bare `build-native.cmd` is not
found even from the directory holding it.

```sh
portable\win\mupdf-native-build.cmd          # libmupdf for x64 (~70 s clean)
portable\win\mupdf-arch-check-native.cmd     # every member is 8664 (x64)
portable\win\build-native.cmd                # ShenzhenPDF.exe
bash portable/win/tests/run-tests-native.sh  # the whole suite; exit 0 only if everything ran and passed
bash portable/win/tests/run-tests-native.sh --list   # the case inventory, no build
```

Two environment variables control where everything lands, and both matter as
soon as more than one agent or worktree is building:

| variable | default | what it is |
|---|---|---|
| `SPDF_OUT` | `C:\spdf-build` | build output: `ShenzhenPDF.exe`, `obj-<target>\`, the harness's scratch |

**Where the app lands.** Every successful build of the app target also copies it
to `dist\ShenzhenPDF-win-x64.exe` in the checkout -- one predictable place, the
name a release carries, beside where the macOS build leaves `ShenzhenPDF.app`.
That is the copy to run. `%SPDF_OUT%` is a working directory: the app sits
there among forty test executables and their object directories, a parallel
build points it somewhere else entirely, and nothing prunes it, so which
`ShenzhenPDF.exe` you find there depends on what ran last. `dist\` is
git-ignored; `portable\win\package-release.cmd` writes the same name plus its
`.sha256` sidecar for a release.
| `SPDF_MUPDF_LIBDIR` | `%SPDF_OUT%\mupdf` | where `libmupdf.lib` and `libmupdf-third.lib` are looked for |

**`SPDF_OUT` is the isolation boundary; `SPDF_MUPDF_LIBDIR` is why it can be.**
Two builds sharing one `SPDF_OUT` overwrite each other's exe and objects, and
the user's own running instance holds a lock on `ShenzhenPDF.exe` that makes the
link fail for everyone else. So a parallel track sets `SPDF_OUT` somewhere
private — and would then have to rebuild the 74 MB of MuPDF too, because the
default derives `SPDF_MUPDF_LIBDIR` from it. Point `SPDF_MUPDF_LIBDIR` at the
shared prebuilt copy instead and the private build costs seconds:

```sh
export SPDF_OUT='C:\spdf-build-mytrack'
export SPDF_MUPDF_LIBDIR='C:\spdf-build\mupdf'
```

`run-tests-native.lib.sh` documents the same pair at its definition, and
`build-native.cmd --help` prints them. Nothing here is written to `C:\` itself.

## Installing, or not

**`ShenzhenPDF.exe` is already a portable app, and that is the recommended way
to use it.** One statically-linked `/MT` image, ~41 MB, MuPDF embedded: no DLLs,
no VC redistributable, nothing to register before it will start. Download it,
double-click it, run it. **There is no installer binary and no NSIS, WiX, MSI or
MSIX** — every one of them would exist to copy a single file. So there is
nothing to build here beyond `build-native.cmd`, and
`portable/win/package-release.cmd` produces the release asset:
`dist\ShenzhenPDF-win-x64.exe` plus its `.sha256` sidecar, which is exactly the
layout the updater already looks for (`spdf_win_updater.h`).

**The exe is its own installer** (`portable/win/src/spdf_win_setup.h`), through
two flags. Both are per-user: **HKCU only, no administrator rights, nothing
written outside your profile.**

```bat
ShenzhenPDF.exe --install                          :: optional
ShenzhenPDF.exe --uninstall [--quiet] [--purge]
ShenzhenPDF.exe --portable                         :: state beside the exe
```

`--install` writes exactly four things, and nothing else:

| what | where |
|---|---|
| the program | `%LOCALAPPDATA%\Programs\ShenzhenPDF\ShenzhenPDF.exe` (`FOLDERID_UserProgramFiles`) |
| a Start Menu shortcut | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ShenzhenPDF.lnk` (`IShellLinkW`) |
| the `.pdf` handler | `HKCU\Software\Classes\ShenzhenPDF.Document` + `Capabilities` + `RegisteredApplications` — the *existing* `spdf_win_assoc_register_under()`, pointed at the **installed** path so deleting the download does not break the association |
| the Apps list entry | `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\ShenzhenPDF`, whose `UninstallString` is `"<installed exe>" --uninstall` — Windows' own Uninstall button runs the app |

It then relaunches the installed copy, passing through any file argument. Run it
**again from the installed copy** and the copy step is skipped: that is the
repair/upgrade path, and it is idempotent.

`--uninstall` removes those four and nothing more. A running exe cannot delete
itself, so when it is run from the installed copy — which is what the Apps
list's Uninstall button does — a detached `cmd /c` retry loop removes the
directory once the process exits, falling back to
`MoveFileExW(MOVEFILE_DELAY_UNTIL_REBOOT)`; the completion message says which
happened. **`%APPDATA%\ShenzhenPDF` (settings, session, recents, favorites) is
KEPT** unless `--purge` is passed, and the message says so. Your documents are
never touched. To undo an install by hand instead: delete the install folder,
delete the `.lnk`, and `reg delete` the `Uninstall\ShenzhenPDF` key and the
association keys above.

**When a window misbehaves, the app has already written it down.** Every
windowed launch appends one line to `<state dir>\launch-health.log` at 1 s, 5 s
and 30 s after the window is shown — foreground, enabled, visible, iconic, rect,
monitor, on-screen, z-index, hung windows of the process, modal state, the input
messages the window procedure received, paints completed, and the UI thread's
heartbeat — plus a `stall` line from a watchdog thread whenever that heartbeat
goes older than three seconds, which is the one thing no UI-thread timer can
report. A nested modal loop makes the heartbeat go stale too and is **not** a
stall: while one of our own dialogs is up the watchdog writes one `modal` line
and then stays quiet, so a `stall` line means a pump that is genuinely stuck.
It costs an `InterlockedIncrement` per counted message and a
`GetTickCount64` per turn of the message loop
(`portable/win/src/spdf_win_health.h`, `spdf_win_health_log.h`).

```bat
ShenzhenPDF.exe --diagnose > health.txt    :: every live window + every log's tail
ShenzhenPDF.exe --print-layout 1680 1200 1.5   :: where each toolbar control is
```

`--diagnose` prints one line per live window of class `ShenzhenPDFWindow` on the
desktop, whatever process owns it, then the tail of every `launch-health.log` it
can find, and exits 0. **Redirect it**: the exe is `/SUBSYSTEM:WINDOWS` and
writes to whatever standard output handle it inherited. `--print-layout` prints
the chrome bands and every toolbar control as `kind name x y w h` in client
device pixels, from the same layout the painter and the input router share — it
is how `portable/win/tests/launch-health.ps1` clicks the *button* rather than a
coordinate measured once. The field guide is section 17 of
`portable/docs/windows-native-observations.md`.

**Portable mode is explicit and self-contained.** A file named
`ShenzhenPDF.portable` next to the exe (or `--portable`) moves the state to
`<exe dir>\ShenzhenPDF-data`, so a copy on a USB stick carries its own session
instead of writing into the host machine's profile. `--state-dir` keeps
precedence over both.

**The first launch asks once** — *Run this copy* / *Install* / *Install and run
the installed app* — through a `TaskDialogIndirect` resolved at run time, and
then never asks again (`setupPromptAnswered` in `settings.yaml`; Esc records
nothing, so the question returns). **It is deliberately silent** for the
headless paths, for any of `--install`, `--uninstall`, `--quiet`, `--purge`,
`--portable` and `--state-dir`, when the portable marker is present, when
running from the install directory, when the app is already installed, and when
`SPDF_WIN_LAUNCH_PROFILE` or `SPDF_WIN_SETUP_NO_PROMPT` is set.
**If you add a tool that launches a real window, pass `--state-dir` or set
`SPDF_WIN_SETUP_NO_PROMPT=1`**: the dialog is modal and appears before the
window, so a tool that waits for a window would wait forever.
`measure-launch.ps1` and `drive-window.ps1` set it;
`screenshot-window.ps1` (and `verify-phase1.ps1` through it) already pass
`--state-dir`. The whole rule is one pure function,
`spdf_win_setup_first_run_action()`, and `setup_test.c` drives all 64
combinations of it.

Tests: `setup_test` (the pure decisions — paths, argv, the "am I already
installed here?" comparison, the Apps-list value set, the first-run table),
`setup_registry_test` (the real registry writes, read back under a throwaway
`HKCU\Software\ShenzhenPDF-test-<pid>` key and deleted, exactly as
`assoc_test` does) and `setup_e2e_test` (a real `--install` and `--uninstall`
under `SPDF_WIN_SETUP_ROOT`, a **test-only** env override that redirects the
program folder, the Start Menu, the registry root *and* the state directory to a
scratch tree — so `--purge` cannot reach real settings — and which also runs the
installed copy so the detached self-delete is exercised for real).

## The machine and the toolchain

The native box, from `portable/docs/windows-native-observations.md` §1 — which
exists because **none** of the ARM64/Parallels assumptions in this file's older
revisions were true of it:

| | |
|---|---|
| Target | **x64** (`8664`), not ARM64 |
| CPU | AMD Ryzen 5 6600U, Radeon 680M iGPU |
| OS | Windows 11, build 10.0.26200 |
| Display | **144 dpi (150%)** — fractional, and a harder DPI test than 200% |
| Toolchain root | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |
| MSVC | **19.44 / toolset 14.44.35207**, `Hostx64\x64` |
| Windows SDK | 10.0.26100.0 |
| MuPDF | **1.27.2**, the tree vendored at `mupdf/`, built for x64 |

MSVC was chosen over MSYS2/MinGW because the app is Win32/Direct2D: MSVC is the
toolchain its headers, COM interfaces and `.rc` resources are written for. The
same toolset number appears on the ARM64 guest (`HostARM64\arm64`), which is
why the version alone never tells you which host you are on — `SPDF_ARCH` and
`mupdf-arch-check-native.cmd` do.

The fractional DPI is a gift rather than an inconvenience. 150% produces
fractional layout and fractional stroke widths, and it found a real defect that
1× or 2× would have hidden (observations §4.1): a `1.0f * dpi_scale` border
stroke landing on 1.5 device pixels and blurring. macOS backing scales are only
ever 1× or 2×, so the macOS source cannot warn you about this class of bug.

## The application sources

`portable/win/src/` — **178 files, 43,678 lines** (3,707 `.c`, 17,507 `.cpp`,
22,464 `.h`). `portable/win/` as a whole is 347 tracked files. Every file is
under the 500-line cap; `bash tools/check-file-sizes.sh` is green, and
`portable/win/mupdf-gen-ninja-native.sh` is the directory's one listed
exception (`tools/file-size-limits.tsv`).

Header-heavy on purpose: the toolkit-free logic — layout, tab-strip geometry,
minimap geometry, search, sidebar grouping, print maths, the palette filter, the
watcher policy, the menu table — lives in `static inline` headers so a test can
compile it beside the GTK4 or macOS original it was transcribed from and compare
the two in one binary. That is what the differentials below do.

By subsystem, with the files that own each:

| area | files |
|---|---|
| entry, window, frame, caption, presentation | `spdf_win_main.cpp`, `spdf_win_window*.{h,cpp}` |
| Direct2D device, compose, PNG encode, GPU prewarm | `spdf_win_d2d*.{h,cpp}`, `spdf_win_gpu_prewarm.h` |
| canvas, layout, render pool, LRU, prefetch | `spdf_win_canvas*`, `spdf_win_layout.h`, `spdf_win_render.{h,c}`, `spdf_win_lru.{h,c}` |
| chrome: strip, toolbar, sidebar, minimap, scrollbars, input router | `spdf_win_chrome*.{h,cpp}`, `spdf_win_tabstrip.h`, `spdf_win_tabs*` |
| find, results sidebar, heat-map, search map | `spdf_win_search*`, `spdf_win_chrome_find.*`, `spdf_win_sidebar_*` |
| Markdown through MuPDF's HTML engine | `spdf_win_md*.{h,cpp}` (+ `portable/core/spdf_markdown*.c`) |
| selection, links, clipboard, page export | `spdf_win_selection.*`, `spdf_win_links.*`, `spdf_win_clipboard_page.*`, `spdf_win_export.*` |
| menus, commands, palette, recents, favorites, shortcuts | `spdf_win_menu*`, `spdf_win_cmd_*.h`, `spdf_win_palette*`, `spdf_win_recents.*`, `spdf_win_favorites.*`, `spdf_win_shortcuts.*` |
| state: settings/session/documents/favorites YAML | `spdf_win_state.*`, `spdf_win_settings.*`, `spdf_win_session*`, `spdf_win_paths.*` |
| printing and properties | `spdf_win_print*`, `spdf_win_properties*`, `spdf_win_props_format.h` |
| password prompt, file watcher, shadow copy | `spdf_win_password*`, `spdf_win_watcher*` |
| OCR, translation, toolchain acquisition, the job panel | `spdf_win_ocr.*`, `spdf_win_translate*`, `spdf_win_toolchain*`, `spdf_win_panel*` |
| updater: feed, verify, install, store, UI, workers | `spdf_win_updater*` |
| shell: association, Explorer reveal, About, icon/manifest | `spdf_win_assoc.*`, `spdf_win_shell*`, `spdf_win_about*`, `../spdf_win.{rc,ico,manifest}` |
| the exe as its own installer: `--install` / `--uninstall` / `--portable`, the first-run question | `spdf_win_setup.{h,cpp}`, `spdf_win_setup_shell.h`, `spdf_win_setup_prompt.h`, `spdf_win_setup_first_run.h`, `../package-release.cmd` |
| launch instrumentation | `spdf_win_launch_profile.h`, `../measure-launch.ps1` |

`portable/core/spdf_win_compat.c` belongs in **every** Windows source list (see
gotcha 18). Note the path: it lives under `portable/core/`, not here.

## The headless test harness

`bash portable/win/tests/run-tests-native.sh` — one machine, Git Bash, no
Parallels, no `prlctl`, no `\\Mac` share. Its macOS-side sibling `run-tests.sh`
drives a VM and compares against references a Mac produces at test time.

**The inventory is 86 cases** (`--list`, exit 0, no build required), from
62 `*_test.c` files under `tests/` plus the core suites, the harness canaries,
the build case, the Direct2D composes, the launch budget and the cross-host
comparisons. `--list` is the only count worth quoting: adding
`tests/<name>_test.c` registers `win.<name>_test` automatically, so any number
written down elsewhere starts going stale the moment a track lands.

### Which core suites run here

`CORE_SUITES` in `run-tests-native.sh` registers **nine**:

| suite | prerequisite |
|---|---|
| `SPDFCoreRecolorTests`, `SPDFCoreCompatTests`, `SPDFCoreMarkdownTests` | none — pure C, no MuPDF |
| `SPDFCoreSaveTests`, `SPDFCoreOutlineTests`, `SPDFCoreRenderThemeTests`, `SPDFCoreSelectionTests`, `SPDFCoreCJKSelectionTests` | `libmupdf.lib` |
| `SPDFCorePasswordTests` | **`qpdf`**, to generate the encrypted fixtures (`winget install qpdf.qpdf`) |

An earlier revision of this file said "only three of the six suites are wired"
while listing five unwired ones. All of them are wired now; the count was wrong
in both directions and the arithmetic was wrong too. `SPDFCorePasswordTests` is
the only one that stays BLOCKED on a machine without `qpdf`, and it is BLOCKED
on this one.

### What cannot run without a Mac, and is still listed

`CROSS_HOST` records **seven** cases BLOCKED with the exact prerequisite:
`layout.differential`, `probe.png`, `alpha.png`, `d2d.exact-plain`,
`d2d.exact-dark`, `d2d.window-plain`, `d2d.window-dark`. They are the port's
strongest evidence — `d2d-cases.sh` and `probe-cases.sh` compile the reference
probe with `cc` on the Mac at test time rather than comparing against committed
images, and **no reference image is committed anywhere in `tests/`**. Quietly
dropping them is how a port stops being checked, so they are listed and blocked
instead. Committing macOS reference PNGs is the one change that unblocks the
lot.

`layout.differential`'s block is the softest of the seven and there is a native
substitute: `layout-differential-native.cmd`. See "the differentials" below.

`run-tests-native.d2d.sh` adds four Windows-internal substitutes named
`d2d.compose-*`. **They are named differently on purpose.** They prove strictly
less — probe (core → PNG) versus the app (core → D2D → WIC → PNG) cannot catch
a Windows-vs-macOS divergence — and letting a weaker test inherit a stronger
one's name is how this repo's documents drifted in the first place.

### Exit status

`run-tests-native.sh` exits **0** only when every selected case ran and passed;
**1** if any case failed; **2** if any case was *blocked* by a missing
prerequisite; **3** if a `--filter` matched nothing. Blocked is deliberately not
zero — a harness that reports success because it could not run anything is worse
than no harness, since everything layered on top of it inherits the lie. While
`libmupdf.lib` does not exist, a correct run exits 2 — and **on this box a
complete run exits 2 even with everything built**, because the seven cross-host
cases and `core.SPDFCorePasswordTests` cannot run here. Do not teach it to exit
0; use `--filter` to work on one area.

That status is proven rather than asserted:

- `harness.exit-code` builds `tests/exit_code_probe.c` and runs it with 0, 3 and
  42, checking each value arrives intact, then compiles `tests/never_compiles.c`
  and fails the run if the build returns 0.
- `--self-check` re-runs the script with a deliberate failure injected and
  refuses to proceed unless the runner's own exit status is non-zero.

Three habits keep it honest and none may be tidied away: no `set -e`; nothing
piped through `grep`/`tee` to decide pass or fail (a pipeline reports the *last*
command's status, so `prog | grep -c ok` is green when `prog` crashes); and the
final status computed from recorded results rather than from whatever ran last.

`app.build` is the case that reads `build-native.cmd`'s exit code as the whole
truth about whether the tree compiles. That script's contract is that its exit
code **is** `cl.exe`'s, verbatim; infrastructure failures use codes 64–93 so
they stay distinguishable from a genuine compile error (`cl.exe` returns 2).

### Adding a test for your track

Drop `portable/win/tests/<name>_test.c` in the directory — it is discovered
automatically as case `win.<name>_test`. Declare anything extra in the file:

```c
/* spdf-test-sources: portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf */
/* spdf-test-needs: mupdf */
```

Paths are repo-relative and are rewritten to native absolute paths for the exe.
`spdf-test-needs: mupdf` makes the case report BLOCKED instead of FAILED while
`libmupdf.lib` does not exist. No track needs to edit the runner to be run by it.

### The differentials — nine of them

The port rule (`windows-port-plan.md` §2.3) is that toolkit-free logic is
**transcribed and differentially tested**, never re-derived. Each script below
compiles the port and the original it came from into one binary, sweeps a matrix
of inputs through both and compares:

| script | against | measured |
|---|---|---|
| `layout-differential-native.cmd` | `spdf_docview_internal.h` | 395,514 comparisons, 0 mismatches |
| `minimap-differential-native.cmd` | `spdf_minimap_internal.h` | 131,503 comparisons, all identical |
| `search-differential-native.cmd` | `spdf_search_internal.h` | 37,440 comparisons, 0 differ |
| `selection-differential-native.cmd` | `spdf_selection_adapter.c` + cursor regions | 50,171 comparisons, 0 differ |
| `props-differential-native.cmd` | `spdf_props_internal.h` | 187,315 comparisons, 0 mismatches |
| `print-differential-native.cmd` | `spdf_print.c`'s pure half | 1,944,132 comparisons, 0 mismatches |
| `palette-differential-native.cmd` | the GTK palette's filter and ranking | landed with the palette port (`54b9f9a64`) |
| `sidebar-differential-native.cmd` | `spdf_sidebar_internal.h` result grouping | landed with the results sidebar (`a22c17cb4`) |
| `watcher-differential-native.cmd` | `spdf_watcher_logic.c` | landed with the watcher port (`3aa1a806b`) |

Each judges by exit code: `0` every comparison identical, `1` at least one
DIFFERs (a transcription error), `3` the matrix did not run. The counts above
are from the audit recorded in `portable/docs/windows-feature-matrix.md`; re-run
the script rather than trusting the number.

`layout.differential` had been BLOCKED as "needs glib" since the beginning, and
the block was softer than it looked (observations §4.4): the two headers need
glib's *typedefs*, `MAX`/`MIN`/`CLAMP` and `g_new0`/`g_free`, not the library.
`tests/glib_shim/glib.h` supplies exactly those, with glib's own macro bodies
character for character — the comparison order at the edges is part of what is
being checked. Same compiler on both sides, so a difference could only be a
transcription error. Proven to bite: perturbing the ported fit-width zoom by one
part in 10⁷ gives 17 mismatches. The two `spdf_lru_*` halves stay skipped,
because glib leaves hash iteration order unspecified and a shim would report
mismatches that are not transcription errors.

There are five more shim directories — `glib_shim_palette`, `_props`,
`_search`, `_sidebar`, `_watcher` — one per original, for the same reason.

### The live-window tooling

Offscreen tests cannot see focus, z-order, a console window, or the system
theme. Four defects only a person using the app could report got through every
green check for exactly that reason (observations §4.7). These scripts exist so
"look at the window" is a command:

| script | what it does |
|---|---|
| `verify-phase1.ps1` | turns the five window criteria into one exit code: compares the live client area against the headless compose at the same size **and the same DPI**. 7/7 light and dark. |
| `screenshot-window.ps1` | `PrintWindow` with `PW_RENDERFULLCONTENT` (mandatory for a D2D client area), enumerates windows by pid rather than trusting `MainWindowHandle`, reports the client offset so a capture can be cropped to what `spdf_win_paint` drew, and always closes the app it started. |
| `drive-window.ps1` | drives the live window with synthetic `PostMessage` mouse input and captures after each step. `PostMessage`, not `SendInput`, deliberately: a person may be sitting at this machine and `SendInput` would move their real cursor. |
| `drive-uia.ps1` | drives the app's **modal** windows — task dialogs, message boxes, the annotation and Properties dialogs — and captures them. UI Automation to find and read a dialog, `GetDlgItem` + `WM_SETTEXT`/`WM_COMMAND` to press it, `type:` (one `WM_CHAR` per character) for the app's self-drawn fields. It does **not** move the reader's cursor, and unlike `drive-window.ps1` it does **not** set `SPDF_WIN_SETUP_NO_PROMPT` — a modal dialog is the point. |
| `measure-launch.ps1` | polled, DPI-aware launch timing over N runs with medians, cold copies and session-restore fixtures. |

Why `drive-uia.ps1` exists beside `drive-window.ps1` rather than inside it:
`drive-window.ps1` clicks CLIENT COORDINATES, which is exactly right for chrome
the app paints itself and exactly wrong for a dialog, whose controls are child
windows this repo does not lay out — clicking them by coordinate means
hard-coding offsets into a layout Windows may change with a font, a language or
a DPI. A modal dialog also runs its own message loop, so the app's window stops
answering the "is it alive" probes at the same moment.

**A UIA client on this box cannot press a dialog button, and that is the client's
fault, not the app's.** Every child of every dialog — including the OK button of
a stock `MessageBoxW`, a plain `L"BUTTON"` in a plain `#32770` — surfaces to
`System.Windows.Automation` as `ControlType.Pane` with no `InvokePattern` and no
`ValuePattern`. Hence the `childtext:`/`childclick:` steps, which address a
control by the id the source names. **Never report a dialog as inaccessible on
that evidence** (`portable/docs/windows-native-observations.md` §10.3).

Three traps that cost real time and are worth knowing before writing a sixth
script:

**The capture host must be DPI-aware.** `powershell.exe` is not per-monitor DPI
aware, and when a DPI-unaware process calls `GetWindowRect`/`GetClientRect` on a
window owned by a per-monitor-aware one, Windows *virtualises* the answer — it
reported a 1680×1200 window as 1120×800. A bitmap of that size then captures
the top-left 1120×800 *physical* pixels: a crop at true scale, which looks
exactly like an app rendering ~1.5× too large and clipping. It reproduces every
time and it points straight at DPI handling. The app was correct the whole time.
`SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` at script start is what
makes every number in these files mean what it says.

**A locked workstation looks exactly like a broken window.** Windows does not
composite a locked session: the DWM-drawn title bar still appears in a capture
because DWM has it cached, but a GPU-backed Direct2D client area does not.
`verify-phase1` reported three hard failures with enormous deltas, *and it
reproduced* — including from a clean build of a known-good commit. Both scripts
now refuse to lie about it: `screenshot-window.ps1` checks for `LogonUI` before
launching and exits **68**, `verify-phase1.ps1` maps 68 to BLOCKED for the whole
run, and a pixel backstop covers the cases `LogonUI` does not name (disconnected
RDP, a sleeping display, a GPU reset). Neither check can turn a bad frame into a
pass; they only ever turn a FAIL into a BLOCKED. Full account in observations
§4.6.

**A harness may only close a pid it can prove it started.** Not "a process
called ShenzhenPDF.exe", and not "one that started after we did": the first
version of `drive-uia.ps1`'s cleanup used both of those and closed a
`C:\spdf-build\track-settings\ShenzhenPDF.exe` belonging to another agent's
build tree. The reader is at this machine and other tracks build on it, so the
test is a **pid absent from a snapshot taken before the launch** *and* an image
path this run launched. `verify-phase1.ps1` already learned the mis-reporting
half of this lesson (observations §4.7); §10.5 is the version where a harness
acted on it.

One more, milder: `SetProcessDpiAwarenessContext` succeeds once per process, so
a script that takes several captures from a single PowerShell session prints
`host_dpi_aware=True` for the first and `False` for the rest while remaining
fully aware. Do not read that `False` as the virtualisation trap above.
`verify-phase1.ps1` never sees it because it spawns a fresh `powershell -File`
per capture.

`verify-phase1.ps1` is also sensitive to the saved session: the window restores
the page each tab was on and the headless reference renders page 0, so a session
left behind by earlier clicking makes the two legitimately disagree. The live
checks now use a private state directory (`574287e3e`); the launch harness backs
up and restores the user's own `session.yaml` around every run.

### Launch, measured

`launch.budget` (`run-tests-native.launch.sh`) is a regression tripwire, not the
target: window ≤ 300 ms, first page ≤ 600 ms, median of five, BLOCKED rather
than FAILED when the workstation is locked. The target and the measured state
live in `portable/docs/windows-launch-performance.md`: the bar is **window
< 100 ms, first page < 150 ms warm**, and the measured warm baseline is **37–49
ms to a visible window and 143–281 ms to the first page**, against a floor of
13–16 ms from process creation to `main()` for a program that does nothing.

Cold is a different animal and worth knowing before anyone reports a bug:
first page ~**872 ms** for a never-seen executable, because the GPU driver keys
its shader cache on the *binary identity*. One launch per install pays it.

An earlier session concluded the app took a constant ~1.0 s to do anything
headless. It did not: PowerShell's `Start-Process -Wait -RedirectStandardOutput`
adds about a second of pipe teardown to every process it waits for. Polling
`$p.HasExited` with `t0` taken before launch is what produced the numbers above.

## Gotchas

Each of these cost real time; they are written down so they cost it once.
Numbers 1–9 are about the original macOS→VM route and are kept because that
route still exists; 10–20 apply to any Windows build; 21–24 are native-box
specific.

**1. `prlctl exec` runs as `nt authority\system`, not as the logged-in user.**
The mapped drive `Z:` that Parallels sets up for the interactive user does not
exist in that session. Guest tooling must use `\\Mac\Home\Documents\...`.

**2. `~/Projects` is not shared with the guest.** Parallels exposes only
`Desktop`, `Documents` and `Downloads`, which is the entire reason for the
staging directory under `~/Documents`.

**3. `%ERRORLEVEL%` in a `&` chain is expanded at PARSE time.** The whole line
is parsed before any of it runs, so this silently reports the errorlevel from
*before* the command:

```
cmd /c "some-failing-thing & echo RC=%ERRORLEVEL%"   -> RC=0     WRONG
cmd /c "some-failing-thing & if errorlevel 42 ..."   -> correct
```
Verified: `cmd /c exit 42 & echo INLINE=%ERRORLEVEL%` prints `INLINE=0`. Use
`if errorlevel N`, which is evaluated at runtime, or a separate script line.

**4. `if COND cmd & other` runs `other` unconditionally.** cmd parses the `&`
chain as a sibling command, not as part of the `if` body. So
`if errorlevel 8 echo failed & exit /b 90` exits 90 on *every* run. Every
conditional in `guest-build.cmd` and `build-native.cmd` uses a parenthesised
block for this reason. Do not "simplify" them back.

**5. robocopy's exit code is a bit field, and success is `< 8`.** `0` = nothing
to do, `1` = files copied, `2` = extras, `3` = both. A plain `if errorlevel 1`
would fail every build that actually copied something.

**6. `vcvarsall.bat` breaks when invoked inside a `prlctl` `&` chain.** It
prints `The system cannot find the path specified.` and sets no environment.
Inside a real `.cmd` file it works normally, which is why the build drivers are
script files rather than one-liners.

**7. macOS shell quoting.** `$` is expanded by the Mac shell and `&` separates
commands inside cmd, so guest command lines want **single** quotes on the macOS
side. Prefer putting the logic in a `.cmd` file on the share.

**8. The guest has no `head`, `grep`, `sed` or `git`.** Use `findstr`. Note
`findstr` sets errorlevel 1 on no-match, which makes it a reasonable exit-code
test but a poor thing to put mid-`&`-chain. (On the native box, Git Bash has all
of them — but a `.cmd` script still cannot assume it.)

**9. Build from a local directory, not from a share.** Measured over 4,442
staged files, warm on both sides: bulk header reads take **0.06 s locally vs
0.58 s over the share (~9×)**. A MuPDF-scale build opens headers thousands of
times, so `guest-build.cmd` copies first.

**10. MSVC dies on large string literals, not large arrays.** `fatal error
C1060: compiler is out of heap space`, memory-driven rather than a hard limit,
and therefore dependent on `-j`: the same file can compile alone and fail under
`-j8`. Do not spend time tuning parallelism — see "The font blob problem".

**11. `\"` in a response file must stay escaped.** `cl` parses a response file
with the same CRT `argv` rules as a command line, so a bare `"` is a grouping
quote it strips. `-DFT_CONFIG_OPTIONS_H="slimftoptions.h"` arrives as
`FT_CONFIG_OPTIONS_H=slimftoptions.h` and freetype fails with
`error C2006`. Keep the backslashes exactly as `make -n` prints them.

**12. ninja here does NOT put a shell between itself and the command.** A
trailing `>nul` arrives as an extra `argv` entry, not a redirection — which is
how `bin2coff` came to print its usage message 182 times instead of embedding
anything. Redirect from the `.cmd` wrapper instead, or not at all.

**13. `rsync --delete` PROTECTS files that are already excluded.** Changing an
exclude does not clean up what the old rule copied; `sync-to-vm.sh` needs
`--delete-excluded`, or 190 MB of `mupdf/generated/` lingers in the staging tree
forever.

**14. `robocopy /MIR` will delete build output that lives under its
destination.** `SPDF_OUT` is deliberately a sibling of the source tree, never a
child.

**15. Escape `:` in ninja paths.** Ninja treats `:` as a field separator in path
positions, so a Windows absolute path has to be written `C$:/spdf/mupdf/...`.
Inside a variable value (`flags = ...`) it needs no escaping.

**16. `ninja -k 0`.** Passed always. Without it ninja stops scheduling after the
first failure, and a 646-edge build reports one broken file per round trip.

**17. The guest has no `timeout`, and macOS `zsh` does not word-split unquoted
expansions.** Neither is a Windows problem; both cost time anyway.

**18. `portable/core/spdf_win_compat.c` belongs in EVERY Windows source list.**
It is the POSIX shim the core's own sources `#include "spdf_win_compat.h"` from
(`shenzhen_pdf_core.c`, `spdf_yaml.c`, and six of the core test suites), so
omitting it produces a wall of `LNK2019: unresolved external symbol
spdf_compat_*` rather than a compile error at the file that wanted it. It lives
under `portable/core/`, **not** `portable/win/src/` — this README said the
wrong path for a while and the file has only ever been in one place.

**19. `-ffp-contract=off` on the macOS side is load-bearing, not a workaround.**
It is why cross-host float results come back byte-identical. clang contracts
`a*b + c` into a single fused multiply-add — one rounding step instead of two —
while MSVC under `/fp:precise` does not fuse. Same IEEE-754 arithmetic, same
hardware, different results in the last bit, and a golden-image comparison
pinned at zero tolerance goes red. `tests/t3-verify.sh` builds the macOS side
with it for exactly this reason.

**20. The ANSI code page is 1252, not UTF-8.** Windows narrows the real UTF-16
command line to the ACP on the way into `char** argv`, so a CP1252-representable
path round-trips through a narrow `fopen` and anything outside CP1252 does not.
`harness.non-ascii-path` checks this rather than assuming it — assuming it wrong
is how a real failure in this port was first mis-diagnosed. See the section
below for the observed bytes.

**21. In Git Bash, `cmd /c` is not `cmd /c`.** MSYS path conversion rewrites the
argument `/c` to `C:\`, so `cmd /c foo.cmd` runs `cmd` with a directory as its
first argument: it does nothing at all and exits **0**. A build driver invoked
that way "succeeds in one second" having compiled nothing, and a `build exit=0`
read that way green-lit a commit that did not compile. From Git Bash use
**`cmd //c`**, or set `MSYS2_ARG_CONV_EXCL='*'` as `run-tests-native.sh` does.
Judge by an exit code, yes — but first make sure the exit code belongs to the
program you think ran.

**22. `NoDefaultCurrentDirectoryInExePath=1` is set on this box.** `cmd` will
not find `foo.cmd` in the working directory. Invoke scripts by absolute path or
`.\foo.cmd`. Nothing in `build-native.cmd` depends on the current directory: the
repo root is derived from `%~dp0` and every source is handed to `cl.exe` as an
absolute path.

**23. `vcvarsall.bat` prints `'vswhere.exe' is not recognized` on stderr here
and still returns 0.** It is noise caused by item 22. Judge it by exit code and
by `VSCMD_ARG_TGT_ARCH`, never by its output.

**24. Do not avoid `2>&1` here, but do not trust a redirected native stderr in
PowerShell 5.1 either**, and do not count processes by *name* to detect strays:
the user may have their own ShenzhenPDF instance open, and that instance also
holds a lock on the exe. A stray check must match by pid. Also: PowerShell's `&`
does not wait for a GUI-subsystem process, which once made `verify-phase1`
compare the whole client area and fail three criteria with no error message.

## What is and is not proven

The most important section in this file, and the easiest to skip.

**Proven, by exit code or by pixels, re-run on demand:**

- **A window opens**, renders the page correctly, repaints on resize, scales
  correctly on a fractional-DPI display, and exits 0 — in light and in dark,
  `verify-phase1.ps1` 7/7 both ways.
- **The window's client area is byte-identical to the headless compose** at the
  same viewport and DPI: 0 differing pixels of 816,912, light and dark. This is
  what makes every offscreen pixel test in this directory evidence about the
  real window.
- Every object in `libmupdf.lib`, `libmupdf-third.lib` and `ShenzhenPDF.exe` is
  the target architecture and not an emulated one (`8664` natively here, `AA64`
  on the ARM64 guest).
- The layout, zoom-anchor, clamp, minimap, search, selection, properties and
  print maths agree with the GTK4 originals, by differential — nine scripts.
- The render pool's callback-exactly-once and cancellation contracts hold.
- The state layer round-trips YAML, serialises concurrent writers under a lock,
  preserves other windows' keys, and refuses to overwrite state it could not read.
- `ShenzhenPDF.exe` composes a whole window scene — strip, toolbar, sidebar,
  canvas, heat-map, minimap — through Direct2D into a WIC bitmap with **no
  window**, and writes a PNG.
- Nine `portable/core` suites are registered in the native runner; the audit
  recorded the MuPDF-backed ones passing here, and only `SPDFCorePasswordTests`
  is structurally blocked, on `qpdf`.

**Not proven, and the honest reasons:**

- **x64 ↔ ARM64 render byte-identity.** The measured claim was ARM64 Mac ↔ ARM64
  guest. Reproducing it here would be x64 ↔ ARM64 — SSE versus NEON float
  behaviour is a new variable, and gotcha 19 is about exactly this class of
  last-bit difference. **Do not assume the zero tolerance carries to x64 until
  someone measures it.** It needs a Mac.
- **The seven cross-host comparisons**, for the same reason: no reference image
  is committed. Commit them, or accept that the port's strongest evidence exists
  only on one machine.
- **Interactive shells not driven by a script**: the Open and Save dialogs, a
  real drag & drop, a print job end to end on a real printer. Modal dialogs
  cannot run on a locked workstation, and a `drive-window.ps1` step should
  record one of each.
- **`d2d-cases.sh`'s `d2d.window-dark` is known to be flawed** and will fail
  when run from a Mac: it crops the composed frame to page 0's `dest` rect and
  compares against a chrome-free core render, but the dark theme deliberately
  draws its page border *inside* that rect. Measured on a synthetic 40×40 page:
  156 of 1600 pixels differ in dark, 0 in light, and 156 is exactly the 1-pixel
  perimeter. A flaw in the case's design, not in either renderer. Fix it before
  someone hunts a Direct2D bug that is not there.
- **GPU vs SOFTWARE resampling.** The window paints into a GPU target and the
  headless path into a SOFTWARE one, deliberately, because a harness host may
  have no display adapter. Where `DrawBitmap` resamples the two bilinear filters
  do not agree bit-for-bit (11.2% of pixels, max delta 43, at roughly a 5:1
  downscale). Every zero-tolerance case in this repo compares SOFTWARE against
  SOFTWARE and is unaffected; what they do not certify is the GPU window's
  resampled pixels, which is why `verify-phase1.ps1` decides on MAE ≤ 1.0 with a
  max-delta ceiling. Full numbers in observations §4.3.

The one-line summary that should survive every future edit: **the port is
verified at the core, geometry and pixel layers by differentials and exit codes,
verified at the window layer on one native x64 desktop, and not verified
across architectures or through interactive shells.**

### The guest's, and this box's, code page is 1252

`harness.non-ascii-path` checks this rather than assuming it, because assuming
it wrong is expensive: a harness that hands a UTF-8 path to a narrow `argv` gets
a file that does not exist and then blames the code under test. Observed, for a
directory named with an e-acute:

```
argv1-bytes 43 3A 5C ... 74 34 2D E9 64 69 72 5C 67 6F 6C 64 65 6E 2E 70 64 66
fopen ok                                  ^^ E9, not C3 A9
```

So CP1252-representable names round-trip; anything outside CP1252 will not, and
any narrow `fopen` in the port inherits that limit. The runner *reports* those
bytes rather than asserting them — the code page is a property of the machine,
and pinning `E9` would turn a differently configured Windows into a spurious
failure. `tests/non_ascii_path.ps1` is a script in the tree rather than an
inline `-Command`, and spells the character as `[char]0xE9` so the file itself
stays pure ASCII: a literal would be exposed to NFC/NFD normalisation on macOS,
making the test's own input depend on which machine checked the repo out.

### `spdf_win_probe.c` — one source, two hosts, one diff

The probe exercises `spdf_open`, `spdf_page_count`, `spdf_page_size` and
`spdf_render_page_rgba_opts` and prints a transcript whose only intended
consumer is `diff`. Every line must be reproducible across two compilers on two
operating systems, so it contains no timings, no pointers, no full paths
(basenames are split on both `/` and `\`), and only integer statistics — a
floating-point mean could differ in its last digit and turn a healthy run red.
It deliberately avoids `clock_gettime`, absent from the MSVC UCRT.

```sh
spdf_win_probe <document> [page] [zoom] [out.png] [plain|dark|dark-images|alpha]
```

**A failed PNG write is a failed run.** `write_png()` used to return `void`: it
caught the MuPDF throw, printed it to stderr, and returned, after which `main()`
printed `png <basename>` — a line that asserts the file exists — then `ok`, and
exited **0**. The exit code is the only signal the runner consults, so that
failure never happened as far as the harness was concerned. It now returns a
status and `main()` propagates it.

That mattered because it composed with a second defect into a complete
false-pass chain, worth spelling out since the port's headline claim rested on it:

> the Windows probe fails to render → it exits 0 anyway → the case records
> **PASS** → `fetch_probe_png.ps1` returns the **previous** run's image →
> the comparison checks last run's pixels against this run's reference and
> reports **byte-identical**.

Three independent guards now close it, and each one alone is enough: the probe
deletes its own output before rendering; `probe-cases.sh` clears the guest-side
artifact before the run and verifies it by exit code rather than assuming
(`del` reports success for a file it never found); and `fetch_probe_png.ps1`
removes the file once it has read it, so a second fetch with no intervening
render fails loudly. Deleting *after* a run would have closed nothing: the
hazard lives entirely in the window between a failed render and the next fetch.
`tests/qc/probe-staleness-check.sh` pins both halves and is green.

### `compare_png.py` — why one tolerance is not enough

A single MAE threshold has to be loose enough to tolerate two rasterisers
anti-aliasing the same glyph. Once it is that loose it will happily pass a
vertically flipped page, a BGRA page, or a half-scale render, because none of
those disturb the global statistics much. So the structural checks run first and
fail regardless of tolerance:

| check | the bug it catches |
|---|---|
| fully transparent / flat-colour output | the render target was never painted |
| flat-colour *reference* | the test itself is broken; fix it before trusting anything |
| vertical flip | a y-up rasteriser blitted into a y-down target |
| R/B channel swap | an RGBA core buffer read as BGRA |
| premultiplied vs straight alpha | the dark-halo bug this repo has already shipped once |
| transparent-pixel halo | the same bug in its invisible form — composited output looks perfect, and fringes the moment anything blends or filters the buffer |
| wrong scale | dimension ratio, DPI or device-pixel-ratio path |
| worst-block MAE | a small ruined region hiding inside a good whole-image average |

Only then does the tolerance apply, to two separate numbers: mean absolute error
of the image composited over white, and the fraction of pixels whose
per-channel delta exceeds `--delta`. It reports both, plus max channel delta,
the worst 16×16 block and its coordinates, a transparent-halo pixel count, and a
one-line diagnosis; `--json` writes the lot. `--strict` demands byte identity.

**The tolerance is pinned at zero, because zero is what was measured** between
macOS/clang/arm64 and Windows/MSVC/ARM64 — same pixels, same sha256, for both
fixtures — so the cross-host cases pass `--strict` and **`--strict` decides the
case**. It used to run "for the report only", with the case actually decided by
loose provisional defaults (mae 1.5, 2% bad pixels); a regression inside those
would have passed a comparison known to be bit-exact. The loose numbers survive
only as a diagnostic scale: once `--strict` has failed a case, a second loose run
says whether the drift is subtle or gross and names the bug. If byte-identity
ever becomes genuinely unattainable, record the newly observed numbers in
`compare_png.py` with the run that produced them. Never widen a threshold to
make a failing comparison pass.

`compare_png_selftest.py` is the argument that any of this can be trusted. It
mutates a synthetic reference with one known port bug at a time and asserts both
that the comparison fails *and* that the diagnosis names the right bug — a
comparator that fails everything would be as useless as one that passes
everything, so the unmutated and jitter cases must pass. 13 checks, including
decoding a real MuPDF-written PNG.

### The fixtures

`tests/fixtures/golden.pdf` is hand-assembled by `tests/make_fixture_pdf.py`
(no MuPDF, no reportlab — nothing that could drift and silently change the
golden image) and regenerates byte-for-byte. Every element earns its place: it
is asymmetric top-to-bottom so a vertical flip is unmissable, carries unequal
pure-red and pure-blue regions so a channel swap cannot be confused with the
flip, has text and hairlines so anti-aliasing differences show up somewhere real,
and its second page is a different size from its first. Its sha256 is
`56dd60224d1c17049b03fe7fd2de0296e376dde51ee13f1d8e579109355b7881`;
`alpha.pdf` is `d44f1dbffbad43b2e692dd61bcb6fb05502f7f933086de8dce5bf9a4bf92c64c`.
(`windows-port-handoff.md` §1.3 gives two other digests. Those are the *rendered
PNG* hashes, not the fixtures'. Do not "fix" the fixtures to match a doc —
`golden.pdf` has only ever had one commit and `.gitattributes` sets `* -text`.)

`tests/fixtures/alpha.pdf` exists because `golden.pdf` **cannot** do the other
half of the job. It paints an opaque white backdrop and renders fully opaque, and
premultiplying a fully opaque image is the identity transform — so the
comparator's two alpha guards, the pair aimed squarely at the premultiplied-alpha
halo this repo has already shipped once, could not fire on any real comparison
however broken the render was. Measured directly: premultiplying the
`golden.pdf` reference, and recolouring every one of its transparent pixels, both
still **pass** `--strict`. The same two mutations of the `alpha.pdf` reference
fail and are named correctly (`PREMULTIPLIED ALPHA` over 49,660 partially
transparent pixels; `TRANSPARENT-PIXEL HALO`, 84,690 px). The halo case shows why
it matters: it scores MAE **0.0000** and max channel delta **0**, so no
tolerance, no block check and no checksum over composited output can see it —
only a detector pointed at an image that actually has alpha.

It is compared through the probe's `alpha` mode rather than `plain`, and that is
a finding in itself: **no PDF fixture can produce a non-opaque render through the
shipping core entry point.** `spdf_render_page_rgba_opts` creates its pixmap with
`alpha=0` on all three of its paths and then writes a literal 255 into every
alpha byte. The core's output is opaque by construction, whatever the document
says — reasonable for a page renderer, but it means the alpha detectors could
never have been exercised by adding a fixture alone.

`tests/fixtures/outline.pdf` (`make_outline_fixture.py`) exists because no
committed fixture had a document outline, so the sidebar's chapter list, its
nesting and its UTF-8 titles were untestable. It carries an accented and a CJK
title — `Überblick mit Umlaut` and `第一章` — which is exactly what a narrow
CP1252 conversion mangles silently here. `make_launch_fixtures.py` adds a
120-page document and an image-heavy one for the launch budget.

---

# Building MuPDF for Windows

`libmupdf` builds natively for both targets: `mupdf-native-build.cmd` for x64 on
this box, `mupdf-build.sh` for ARM64 through the VM. Both derive their recipe
from `mupdf/Makefile` rather than from `mupdf/platform/win32/mupdf.sln`, and both
produce the same counts — **646 translation units in 14 flag groups, 417 + 229
objects**.

```sh
portable\win\mupdf-native-build.cmd --clean     # x64, ~70 s
portable\win\mupdf-arch-check-native.cmd        # every member 8664
portable\win\mupdf-native-linkcheck.cmd         # the archives actually link

portable/win/mupdf-build.sh                     # ARM64 via the VM, ~59 s cold
portable/win/mupdf-arch-check.sh                # every member AA64
portable/win/mupdf-render-check.sh              # renders on both hosts and diffs
```

## Which MuPDF, and where it comes from

**MuPDF 1.27.2**, the tree already vendored at `mupdf/` — the exact one
`portable/Makefile` builds the macOS app against (`MUPDF_DIR := ../mupdf`).
Nothing is downloaded and no second copy exists.

Two wrinkles worth knowing:

- **`mupdf/thirdparty/*` are symlinks into `ext/`** (`freetype -> ../../ext/freetype`
  and ten more). Parallels does not present macOS symlinks to Windows in a form
  robocopy or `cl.exe` can follow, so `sync-to-vm.sh` stages with
  `--copy-unsafe-links`. A native checkout has real directories and needs none of
  this.
- **`mupdf/generated/` is `.gitignore`d, and the Windows build does not need
  it.** It holds only the font and hyphenation hexdumps, which the Windows build
  replaces with bin2coff over the original binaries. Every *other* `generate:`
  target in `mupdf/Makefile` — 7 ICC headers, `util.js.h`, `css-properties.h`
  and all 71 cmap headers — is already committed and present. The VM generator's
  exit-70 guard reads `generated/` for a **symbol cross-check**, not as a
  dependency; the native generator does not need a prior macOS build at all.

## How the build description is produced

There is no checked-in `build.ninja` and no use of `mupdf.sln`. The generator
runs `make -n` **inside `mupdf/` with exactly the arguments `portable/Makefile`
uses**, and mechanically translates the printed compile lines into `cl.exe`
flags:

```sh
make -n build=release OUT=build/win-manifest-dryrun \
     ARCHFLAGS="-arch arm64" USE_SYSTEM_GLUT=yes brotli=no libs
```

This matters more than it looks. `mupdf.sln` does carry ARM64 configurations,
but its feature set is its own — barcode, tesseract, brotli, a different font
selection — and it would drift from the reference build silently, which is the
one failure this port cannot detect by looking at the output. Deriving the recipe
from the Makefile means changing `portable/Makefile`'s MuPDF arguments changes
the Windows build too, automatically. Unknown flags are a hard error rather than
a silent drop.

Flag translation, in full:

| POSIX | MSVC | note |
|---|---|---|
| `-O2` / `-O0` | `/O2` / `/Od` | |
| `-ffunction-sections` / `-fdata-sections` | `/Gy` / `/Gw` | |
| `-I…` | `-I…` | rewritten to the build tree's absolute paths |
| `-D…` | `-D…` | verbatim, **including the backslashes** (gotcha 11) |
| `-DHAVE_UNISTD_H` | *dropped* | MSVC has no `<unistd.h>`; zlib only uses it to decide whether to include it for `fdopen`, so no compressed byte changes |
| `-Wall -Wsign-compare …` | `/W3` (mupdf's own C), `/W1` (thirdparty), `/W0` (C++) | plus `/we4013`, below |
| `-std=gnu++11`, `-fno-exceptions`, `-fno-rtti`, `-fno-threadsafe-statics` | `/std:c++14 /EHs-c- /GR- /Zc:threadSafeInit-` | harfbuzz |
| `-pipe`, `-MMD`, `-MP`, `-mmacosx-version-min=…` | *dropped* | ninja uses `/showIncludes` for dependencies |

Everything also gets `/MT /utf-8 /Zc:inline /D_CRT_SECURE_NO_WARNINGS`, and
gumbo-parser additionally gets `-Ithirdparty/gumbo-parser/visualc/include`,
which is where gumbo keeps its MSVC `<strings.h>` shim — the same directory
`mupdf.sln`'s `libthirdparty` project adds for the same reason.

**`/we4013` is deliberate and load-bearing.** Under MSVC an implicit function
declaration is a *warning*, so a POSIX function that does not exist on Windows
compiles to a call returning `int` and fails at link time — or worse, links
against something unrelated. Promoting C4013 to an error over MuPDF's own 232
sources means a missing function stops the build at the file that wanted it. All
232 compile clean at `/W3` with it on.

## The font blob problem

**MSVC cannot compile MuPDF's embedded resources, and this is the one place the
Windows build deliberately differs from the POSIX one.**

On POSIX the 181 embedded fonts and the hyphenation dictionary arrive as
`generated/resources/**.c`: a chain of `"\xNN"` string literals per file, from
`mupdf/scripts/hexdump.sh`. `cl.exe` needs multiple GB of heap per megabyte of
literal. Measured in the VM (16 GB, 8 cores):

| `.c` size | result |
|---|---|
| under ~1.5 MB | compiles |
| ~1.5–4 MB | `fatal error C1060` under `-j8` |
| over ~4 MB | C1060 even at `-j1` |

and `generated/resources/fonts/han/SourceHanSerif-Regular.ttc.c` is **103 MB**.
There is no parallelism setting that makes that work.

So the blobs are embedded from their **original binaries** under
`mupdf/resources/` by `portable/win/mupdf-bin2coff.c`, which writes a COFF object
exporting `_binary_<name>` and `_binary_<name>_size` — the same interface
`hexdump.sh` produces, so MuPDF's sources link against it unchanged. The
embedded bytes are identical; only the route into the object file differs. The
generator derives each symbol name with hexdump.sh's own rule
(`sed 's/[.-]/_/g'`) **and then checks it against the second line of the `.c`
that hexdump.sh actually produced**, so a rename in either tool fails the
generator rather than the link.

**Do not glob the fonts.** There are **185** font binaries on disk and the
Makefile embeds **181**; the four extras are CharisSIL *design sources*.
`make -n` excludes them for free, and a structural glob would have embedded 4 MB
of the wrong thing.

**Why not `mupdf/scripts/bin2coff.c`, which exists and does exactly this?**
Because its ARM64 output does not link. It puts the size word immediately after
the data with no padding, so any blob whose length is not a multiple of 4 gets an
unaligned size symbol:

```
libmupdf.lib(hyphen.obj) : error LNK2048: relocation PAGEOFFSET_12L targeting
'_binary_hyph_all_zip_size' (0056EC03) is invalid for the instruction
(B9400102 at RVA 00055DEC) ... due to bad alignment of offset to target (C03);
expected to be 4 bytes aligned
```

AArch64's `LDR` (immediate) cannot address it, and roughly three quarters of the
182 blobs (181 fonts plus the hyphenation dictionary) have a length that is not
a multiple of 4 — systemic, not bad luck.
`mupdf-bin2coff.c` pads to 8 and puts the section in `.rdata` with 16-byte
alignment. It is ~200 lines and writes every COFF field byte by byte rather than
through packed structs, because COFF is fully specified and struct packing is not.

## What gets built

| | |
|---|---|
| `%SPDF_MUPDF_LIBDIR%\libmupdf.lib` | 58.5 MB, **417 objects** (MuPDF proper + the embedded blobs) |
| `%SPDF_MUPDF_LIBDIR%\libmupdf-third.lib` | 15.2 MB, **229 objects** (freetype, harfbuzz, libjpeg, lcms2, zlib, jbig2dec, openjpeg, mujs, gumbo, extract) |
| clean build | ~70 s native x64; 59 s through the VM for ARM64 |
| no-op rebuild | ~3 s |

There is no `libmupdf-pkcs7.lib`: the macOS build sets `HAVE_LIBCRYPTO=no` and
its `libmupdf-pkcs7.a` is 1,336 bytes of nothing. Signature verification is a
later phase's problem, and adding it here would be a difference from the
reference build.

## The linking interface — what other tracks get

**No track needs to edit any of the MuPDF scripts to link MuPDF.**
`build-native.cmd` already does all of this:

| | |
|---|---|
| include path | `mupdf\include`, `portable\core`, `portable\win\src` |
| libraries | `libmupdf.lib` and `libmupdf-third.lib` from `%SPDF_MUPDF_LIBDIR%`, linked **when they exist** |
| system libraries | `user32 gdi32 shell32 ole32 oleaut32 advapi32 shcore d2d1 dwrite windowscodecs uuid` (plus the shell/crypt/net libraries the later tracks need) |
| CRT | `/MT` — static, and `libmupdf.lib` is `/MT` too. Mixing CRTs here produces link errors that read like missing symbols |
| stack | `/STACK:8388608`, matching macOS's 8 MB main thread. Windows defaults to 1 MB and MuPDF's content-stream and CSS recursion can outrun that |
| subsystem | `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup` **for the app only**. Without it the linker defaults to CONSOLE because the entry point is `main()`, and the app opens a terminal window beside itself — a real user-reported defect (observations §4.7). Test binaries stay console programs because a harness reads their output; stdout still reaches a pipe or a file either way, verified both ways |
| resources | `portable\win\spdf_win.rc` via `rc.exe` — the icon, the version block and the per-monitor-v2 manifest |
| objects | `%SPDF_OUT%\obj-<target>\`, one directory per target — several repo sources share a basename (`buffer.c`, `image.c`, `util.c`) and a flat `/Fo` would have them overwrite each other |

"When they exist" is deliberate: tracks whose code is pure C keep building on a
machine where MuPDF has never been built, and get a one-line note instead of a
link failure. The linker only pulls the objects a symbol actually needs, so a
target that ignores MuPDF pays nothing.

## Proof it is the right architecture

Windows on ARM runs x64 under emulation without complaint, and an x64 host will
happily produce an x86 binary, so "it built and it ran" proves nothing about the
target. The arch checks run `dumpbin /headers` over both archives and assert that
**every** member reports the expected machine, failing on the first that does
not. One wrong object would still link on some paths and would make the whole
claim false.

## Proof the pixels match — and the limit of that proof

`portable/win/smoke/core_smoke.c` opens a PDF through
`portable/core/shenzhen_pdf_core.h`, prints the page count and page size, renders
a page, prints an FNV-1a digest of the pixels and nine sampled points, and
optionally dumps the raw RGBA. `mupdf-render-check.sh` builds it twice —
clang/arm64 against `mupdf/build/release-macos-arm64-12.0`, MSVC/ARM64 against
the guest's libraries — runs both on the same fixture and compares the report
*and* the raw bytes.

The fixture, `portable/win/smoke/smoke.pdf` (generated by `make_smoke_pdf.py`;
the root `.gitignore` excludes `*.pdf`), is chosen to load the code most likely
to diverge between two compilers: text in two base-14 faces at five sizes, a
bezier, a dashed stroked polyline, a rotated and scaled text matrix,
constant-alpha fills over other fills, and an upscaled inline RGB image.

```
   render zoom=2.0000 -> 600x800 stride=2400
   rgba fnv1a=b6f5f36846f24e18 bytes=1920000
   BYTE-IDENTICAL: 1920000 bytes of RGBA, macOS clang/arm64 == Windows MSVC/ARM64
```

Also byte-identical at page 1 zoom 1.0, page 0 zoom 3.5 and page 1 zoom 0.75.
Stride matched at every size.

**So the tolerance for core render comparisons is zero, and it should stay zero
— for ARM64 ↔ ARM64.** That is the pair of machines it was measured on. The
same measurement between this x64 box and an arm64 Mac has never been run, and
gotcha 19 is precisely about the last-bit differences a different vector unit and
a different fusion policy can produce. `mupdf-render-check.sh` prints differing
byte count, max per-channel delta and mean absolute error when a comparison
fails, so the missing measurement is one run away on a machine that has both.

---

# The original route: macOS host → Parallels ARM64 guest

This is how the port started and the scripts are still here and still work. Read
this chapter if you are on a Mac; skip it if you are on the Windows box.

The guest is **ARM64** Windows 11 in Parallels named exactly `Windows 11`
(override with `SPDF_VM_NAME`), with Visual Studio 2022 Build Tools 17.14.39
installed silently to `C:\BuildTools`, MSVC toolset 14.44.35207 in its
`HostARM64\arm64` flavour, Windows SDK 10.0.26100.0, CMake 3.31.6-msvc6 and
Ninja 1.12.1 (both from `VC.CMake.Project`, on `PATH` only *after*
`vcvarsall.bat` runs). `Microsoft.VisualStudio.Component.VC.Tools.ARM64` is the
load-bearing install component: the base `VCTools` workload on an ARM64 host
installs only `HostARM64\x64` and `HostARM64\x86` cross compilers, so without it
there is no way to build a native ARM64 binary.

```
  macOS repo                    ~/Documents/spdf-win          guest C:\spdf
  ──────────                    ────────────────────          ─────────────
  portable/core  ──┐
  portable/win   ──┼─ rsync ──▶  staging dir  ── robocopy ──▶  build source
  ext/, mupdf/   ──┘  (a)        = \\Mac\Home\...   (b)              │
                                                                 cl.exe (c)
                                            exit code ◀──────────────┘
```

| file | side | role |
|---|---|---|
| `sync-to-vm.sh` | macOS | (a) rsync the platform-independent subtrees into the staging dir |
| `guest-build.cmd` | guest | (b) robocopy share → `C:\spdf`, enter MSVC env, (c) compile |
| `vm-build.sh` | macOS | orchestrates both and **returns the guest's exit code** |
| `guest-info.cmd` | guest | prints toolchain versions and binary machine type |
| `verify.sh` | macOS | the end-to-end toolchain proof |
| `tests/run-tests.sh` | macOS | the VM-driving runner, and the only one that can produce the cross-host references |
| `smoke/recolor_smoke.c` | both | exercises `portable/core/spdf_recolor.c` |
| `smoke/broken.c` | guest | deliberately un-compilable; guards the exit-code contract |

`prlctl exec` propagates the guest's exit code faithfully — verified directly:
`exit /b 7` in the guest yields `$? == 7` on the Mac. `guest-build.cmd` ends with
`exit /b %CL_RC%`. `vm-build.sh` uses no `set -e`, no pipe around the `prlctl`
call, and nothing after it that would clobber `$?`. `verify.sh` step 2 compiles
`smoke/broken.c` and fails the whole run if the exit code is 0. Infrastructure
failures use distinct codes: `64` bad usage, `65` sync failed, `66`
unknown/unstaged source, `90` robocopy failed, `91` no vcvarsall, `92` vcvarsall
failed.

`verify.sh` builds `smoke/recolor_smoke.c` + `portable/core/spdf_recolor.c`
natively on macOS (clang, arm64) and in the VM (MSVC, ARM64), runs both, and
diffs. `spdf_recolor.c` is the ideal subject: pure C, no MuPDF, no platform
headers, and **no floating point** — every printed value is fixed by integer
arithmetic, so any difference is a real toolchain problem rather than acceptable
numerical drift. Current result: **61 lines, byte-identical.**

```sh
prlctl exec "Windows 11" cmd.exe /c "echo %PROCESSOR_ARCHITECTURE%"
prlctl exec "Windows 11" cmd.exe /c '\\Mac\Home\Documents\spdf-win\portable\win\guest-info.cmd'
```

Note that this route has **no interactive desktop**: `prlctl exec` runs in the
SYSTEM session. Everything about a real window — focus, z-order, input, menus,
the taskbar, file associations, the system theme — is unobservable from here,
which is why the native box exists and why this file's framing changed.

## Where to read next

| document | what it is for |
|---|---|
| `portable/docs/windows-feature-matrix.md` | every shipped feature vs. this tree, with a verdict and the evidence for it. The place to look before claiming a feature works |
| `portable/docs/windows-native-observations.md` | the native session's record: what the window looks like, the defects found by looking, the false positives, the reproduction commands |
| `portable/docs/windows-launch-performance.md` | the launch bar, the measured timeline and the ranked plan |
| `portable/docs/windows-markdown-design.md` | the Markdown spike, the MuPDF HTML-engine decision and the phased plan |
| `portable/docs/windows-port-plan.md`, `windows-port-handoff.md`, `windows-port-qc.md` | the original plan, handoff and QC findings. **Historical**: their feature status predates the parity wave and the matrix supersedes them |
| `portable/docs/windows-captures/` | the live screenshots, and the rule for adding to them |
