# Windows Port — Quality Control Report

Date: 2026-08-31. Branch `master`, HEAD `1f13d192a`. Host macOS/arm64, guest
`Windows 11` (Parallels, ARM64), MSVC 19.44, MuPDF 1.27.2 ARM64.

Written by the QC track. **Nothing here is taken from another track's report.**
Every claim below was re-run from this machine; where a claim did not reproduce
the reproduction command is given so the next person can check the checker.

Two notes on scope. First, the working tree was being actively edited by the
Phase 2/3 tracks while this audit ran — `spdf_win_canvas.h`, `spdf_win_layout.h`,
`spdf_win_lru.*`, `spdf_win_render.*` and a rewritten `spdf_win_main.cpp` all
appeared between 06:01 and 06:10. Findings were originally labelled
**[committed]** or **[in flight]** accordingly, because an in-flight tree that
does not compile is a normal Tuesday and a committed one is not. Second, per the
standing rule the macOS app was never launched, quit or screenshotted; every
macOS result below is a build or a test binary's exit code.

> **Labelling changed 06:45.** Those two labels described *where the defect
> lived*, not *whether it was fixed*, and readers were taking `[committed]` to
> mean "handled" — F3 was `[committed]` and completely unfixed. Every finding now
> carries an explicit **FIXED / OPEN** status and its fixing commit. See §0.
> The body text of each finding is left as originally written, describing the
> defect as it was found; the status line above it is the current truth.

---

## 0. Finding status as of 06:45 — added by the documentation reconciliation pass

The original report labelled findings `[committed]` or `[in flight]`, meaning
*"was this defect in committed code or in a tree someone was still editing"*.
That is **not** the same as "has it been fixed", and the two were being read as
the same thing — F3 was labelled `[committed]` and is entirely unfixed. Each
finding now carries an explicit status and, where fixed, the commit that fixed
it. Every status below was re-verified against the tree, not taken from a
report.

| # | Finding | Status | Commit | How this was verified |
|---|---|---|---|---|
| F1 | Stale-pixel false pass | **FIXED** | `abfd37255` | `qc/probe-staleness-check.sh` exit 0; both defects named green |
| F2 | `SPDFCoreSaveTests` never ran | **FIXED** | `abfd37255` | `core.SPDFCoreSaveTests` PASS in the 20-case run |
| F3 | Nothing compares the Direct2D output | **OPEN** | — | `spdf_win_probe.c` has **zero** D2D references; no `d2d`/compose case in `--list`; suite is 20 cases and none of them is this |
| F4 | Fit never magnifies | **FIXED** | `647d9390f` | `--render-window-png … 900 700` → `zoom=4.500000`, page drawn 900 px wide in a 900 px viewport |
| F5 | `mkstemp` shim used narrow paths | **FIXED** | `2bff74d7c` | `win.silent_failure_test` PASS |
| F6 | `mkdir_one` accepted a file | **FIXED** | `2bff74d7c` | `win.silent_failure_test` PASS |
| F7 | Silent state overwrite | **FIXED** | `2bff74d7c` | `win.silent_failure_test` + `win.state_test` PASS |
| F8 | Alpha detectors could not fire | **FIXED** | `abfd37255` | `alpha.png` PASS over 49,660 partially transparent px, alpha 0–255 |
| F9 | Tolerance `UNMEASURED` | **FIXED** | `abfd37255` | `probe.png`/`alpha.png` decided by `--strict` |
| F10 | File-size ratchet red | **FIXED** | `e53d24466` | `tools/check-file-sizes.sh` passes; `spdf_win_render.c` landed at 499 lines, under the cap |
| F11 | Stale unregistered binaries counted as passes | **RESOLVED IN REPORTING** | — | The runner never counted them; the claim table that did is superseded by the measured 20-case list. The stale `.exe`s may still sit in the guest — do not read `C:\spdf-build\*.exe` as evidence of anything |
| F12 | README contradicts itself | **FIXED** | `abfd37255` + this commit | The harness chapter was fixed at 06:32; the README's **opening paragraph** still said *"No application code lives here yet"* and *"MuPDF itself has never been built here"* until this commit |
| F13 | Entry points disagree on page numbering | **FIXED** | `647d9390f` | `spdf_win_main.cpp:19-24` now documents 0-based everywhere and matches the probe |
| F14 | Working tree does not compile | **FIXED** | — | Tree clean; the full app target builds and links, exit 0, and renders a PNG (command in `portable/win/README.md`) |
| F15 | Assorted smaller items | **MOSTLY OPEN** | partial | Itemised below |

**Twelve of fifteen fixed. F3 is open, F15 is mostly open, F11 needs no code.**

### F15 item-by-item, re-checked

| item | status |
|---|---|
| `spdf_yaml.c:1120` inverted `snprintf` guard | **OPEN** — still `< (int)sizeof(backup)` with no `n >= 0` arm. Ships on macOS and Linux too |
| `spdf_compat_widen` accepts malformed UTF-8 | **OPEN** — still no `MB_ERR_INVALID_CHARS` |
| Five narrow `remove(temp_path)` in core save paths | **OPEN** — all five still at `shenzhen_pdf_core.c:2394, 2403, 2437, 2478, 2487` |
| `spdf_win_probe.c` uses narrow `main(int, char**)` | **OPEN** — the port's own conformance oracle still cannot be pointed at a non-CP1252 path |
| No `\\?\` prefix in `spdf_win_compat.c`; `SPDF_COMPAT_PATH_MAX` 1024 | **OPEN** |
| No `FOLDERID_LocalAppData` anywhere | **OPEN** |
| `session.lock` declared and never taken | **OPEN** — implemented and tested, but `spdf_win_state_write_json_at` does not take it and only the tests call `spdf_win_state_session_lock_acquire`. Lands as a real bug when Phase 4's multi-window does |
| Dark-theme page separation draws a black shadow in both themes | **OPEN** — `scene->dark` switches the *paper* brush only; the 10%-black `shade` brush is used in both themes |
| 96 MB render cap never applied | **PARTLY FIXED** — `spdf_win_capped_render_zoom` is now called from `spdf_win_canvas.cpp:306` and `spdf_win_canvas_prefetch.cpp:77`; `--render-png` is still unbounded |

### One correction to this report's own scope

§5 below records the file-size ratchet as failing. It passes now (F10). §4's
conclusion about Phase 1 stands unchanged and is the most important paragraph in
this file — **complete at the core-and-pixels layer, unproven at the window
layer, and unprovable from here.** Nobody in any session has seen a window open.

---

## 1. The headline claims

| Claim | Verdict |
|---|---|
| Cross-host probe transcript byte-identical between macOS clang/arm64 and Windows MSVC/ARM64 | **CONFIRMED** — but it is **43 lines, not 42** |
| Rendered PNG byte-identical, sha256 `00432a55a58dbfe1…`, 0 differing pixels | **CONFIRMED**, independently |
| `ShenzhenPDF.exe` is native ARM64 (`machine=0xAA64`) | **CONFIRMED** |
| `SPDFCoreCompatTests`, `core_compat_yaml`, `paths_test`, `state_test`, `SPDFCoreRecolorTests`, `recolor_smoke` pass in the guest | **CONFIRMED** (with a caveat on two of them — F11) |
| `SPDFCoreSaveTests` passes | **NOT CONFIRMED at audit time — it did not run at all.** See F2. *Now fixed (`abfd37255`) and passing in the 20-case run.* |

### What I did to confirm them

**Transcript.** Ran `portable/win/tests/run-tests.sh` end to end. `probe.diff`
passed; `diff portable/win/build/t4/probe-{mac,win}.txt` is empty. `wc -l` on
either transcript reports **43**, not 42. Trivial, but it is the sort of number
that gets copied forward, so: 43.

**PNG.** The two files the harness produced hash identically:

```
00432a55a58dbfe102815d796b8f547c39306791c89ce567ef1d17ac45d44eac  mac/probe-page.png
00432a55a58dbfe102815d796b8f547c39306791c89ce567ef1d17ac45d44eac  win/probe-page.png
```

That alone would only prove the harness copied a file, so I pulled the image out
of the guest myself, by hand, without using the harness's Mac-side plumbing:

```sh
prlctl exec "Windows 11" powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File '\\Mac\Home\Documents\spdf-win\portable\win\tests\fetch_probe_png.ps1'
# 10367 bytes, PNG magic intact
# sha256 00432a55a58dbfe102815d796b8f547c39306791c89ce567ef1d17ac45d44eac
```

The bytes sitting in the Windows guest really are the bytes macOS produced. This
claim is solid, and it is the most valuable single fact in the port.

**ARM64.** `portable/win/mupdf-arch-check.sh ShenzhenPDF.exe` → exit 0:
`libmupdf.lib 417 objects AA64`, `libmupdf-third.lib 229 objects AA64`,
`ShenzhenPDF.exe 1 objects AA64`. (Passing the target without the `.exe` suffix
exits 94 with a clear message — correct, if mildly surprising.)

**`portable/win/verify.sh`** → exit 0. The recolor transcript is 61 lines and
byte-identical across hosts, matching `portable/win/README.md`. The raw-RGBA
render check reports `BYTE-IDENTICAL: 1920000 bytes`.

---

## 2. Findings, most severe first

### F1 — The probe pipeline can report "byte-identical" against stale pixels — **FIXED** (`abfd37255`)

**Severity: highest. This is the one that makes the port's headline claim
falsifiable rather than proven, on any future run.**

Two defects compose into a complete false-pass chain.

*Defect A — `spdf_win_probe.c` writes no PNG, says it did, and exits 0.*
`write_png()` (`portable/win/spdf_win_probe.c:76-97`) returns `void`. It catches
the MuPDF exception, prints it to stderr, and returns. `main()` then prints the
`png <basename>` line — which asserts the file exists — and `ok`, and returns 0.

```
$ portable/win/build/t4/spdf_win_probe_mac …/golden.pdf 0 2.0 /nonexistent-dir/out.png plain
exit=0
stdout: … png out.png / ok
stderr: probe: png write failed: cannot open file '/nonexistent-dir/out.png'
```

Same in the guest, exit **0**, stdout `png probe-page.png` then `ok`.

*Defect B — the guest's PNG is never deleted before the run that produces it.*
`probe-cases.sh:55-56` deletes the two Mac-side copies and the staging-tree copy.
It does not delete `C:\spdf-build\probe-page.png`, which is the file the probe
writes and the file `fetch_probe_png.ps1` reads back. The Mac cannot reach `C:\`
through the share, so this needs its own `prlctl exec … del`.

*Composed:* the Windows probe fails to render → exits 0 → `probe.win` records
PASS → `fetch_probe_png.ps1` returns the **previous** run's image → `probe.png`
compares last run's Windows pixels against this run's macOS reference and reports
`byte-identical`. A genuine Windows render regression is invisible for as long as
the stale file survives.

Proven end to end, and pinned as a regression test at
**`portable/win/tests/qc/probe-staleness-check.sh`** (currently exits 1 on both
defects; it will go green when they are fixed):

```
FAIL  defect 1: the probe could not write its PNG yet exited 0.
      It printed 'ok' as well.
      It printed 'png probe-page.png' for a file it did not write.
FAIL  defect 2: C:\spdf-build\probe-page.png survived a failed run unchanged
      (00432a55a58dbfe1…)  fetch_probe_png.ps1 would return it as this run's render.
```

`probe-cases.sh`'s own header says it best: *"Stale artifacts are the quietest
way for a test suite to start lying."* The intent is right; the guest-side half
of the deletion is missing, and the probe's exit code does not mean what the
runner assumes it means.

**Cost:** the port's central correctness claim silently stops being checked.

---

### F2 — `SPDFCoreSaveTests` never runs; the harness reports it as a code failure — **FIXED** (`abfd37255`)

`harness-lib.sh`'s `guest_run()` concatenates the argument string directly onto
the closing quote of the executable path, with no separating space:

```bash
prlctl exec "$VM_NAME" cmd.exe /c 'cd /d "'"$GUEST_SCRATCH"'" && "'"$GUEST_OUT"'\'"$target"'.exe"'"$args"
```

`CORE_SUITES`' fourth field for this suite is `%SCRATCH%`, which expands with no
leading space, so cmd receives:

```
"C:\spdf-build\SPDFCoreSaveTests.exe"C:\spdf-build\scratch
```

and answers *"The filename, directory name, or volume label syntax is
incorrect."* The binary is never launched. Reproduced verbatim, then with one
space added:

```
without space: exit 1, "The filename, directory name, or volume label syntax is incorrect."
with    space: exit 0, "SPDFCoreSaveTests: all checks passed"
```

So the suite genuinely passes and the claim is *directionally* true — but as
measured by the harness it is red, and it is red for a reason that has nothing to
do with the code under test. The full run reports:

```
FAIL  core.SPDFCoreSaveTests   exited 1 in the guest
run-tests: 12 cases, 1 failed, 0 blocked   →  exit 1
```

`case_win_tests()` builds its arguments correctly (`guest_args="$guest_args …"`,
always leading with a space); only the `CORE_SUITES` path is wrong, which is why
exactly one case broke and the two argument-less core suites did not.

**Cost:** the only suite that exercises the Windows save path — `rename`
replace-existing, `create_temp_save_path`, the CWD-leak check, i.e. risks 3 and 4
of the port plan — has never actually been run by the harness. And a harness
defect is being reported as a defect in `portable/core`, which sends the reader
to the wrong file.

---

### F3 — Nothing compares the Direct2D output. Phase 1's stated headless test does not exist — **STILL OPEN**

The port plan, §Phase 1 "Headless test", says:

> `spdf_win_probe.exe <pdf> <page> <zoom> <out.png>` runs the *same*
> `spdf_win_paint()` into a WIC-backed `ID2D1RenderTarget` and writes a PNG.

It does not. `spdf_win_probe.c` includes only `shenzhen_pdf_core.h` and
`mupdf/fitz.h`; it contains zero references to Direct2D, WIC or
`spdf_win_paint`, and it writes its PNG with `fz_save_pixmap_as_png`. Confirmed
by inspection and by `grep -rln "D2D\|d2d1\|spdf_win_paint" portable/win/tests/`,
which returns **nothing**.

What the byte-identical PNG therefore proves is that `portable/core` + MuPDF
agree across the two toolchains. That is real and valuable. It says nothing about
`spdf_win_d2d.cpp` — the RGBA→BGRA swap, the premultiply, the stride handling,
the fit-to-target scaling. §6 of the plan asks for comparison at three levels
(core output, compose output, geometry); **only level 1 is wired up.**

The capability exists and is unused: `ShenzhenPDF.exe` has `--render-png` and
`--render-window-png`, and `spdf_win_d2d.h:125` exports
`spdf_win_render_scene_to_png`. Nothing in `run-tests.sh` invokes any of it.

**So I ran the missing comparison.** Rendering `golden.pdf` through the D2D/WIC
path in the guest and comparing against the macOS core reference:

```
plain: compare_png --strict → exit 0, byte-identical
dark : compare_png          → exit 0, byte-identical
```

**The D2D path is correct.** It was simply never checked, by anyone, until now.
That is a coverage hole rather than a bug — but it is precisely the hole the
comparator was built to cover (F8), and "Phase 1 proven end to end" is not an
honest description of a render path with no test pointed at it.

---

### F4 — Fit-to-window never magnifies: a small page opens postage-stamp sized — **FIXED** (`647d9390f`)

`spdf_win_main.cpp`'s `fit_zoom()` clamps with `if (zoom > s) zoom = s;` — never
above 100%. GTK4's `spdf_fit_page_zoom` (`spdf_docview_internal.h:187-190`)
clamps to `[0.10, 8.0]` and magnifies freely; macOS does the same.

I did not take this on trust. Composing the window scene at 900×700 through the
shipping code:

```sh
ShenzhenPDF.exe --render-window-png golden.pdf 1 900 700 out.png
```

The 200×260 pt page renders at roughly 200×264 px — 100% — marooned in the grey
surround of a 900×700 canvas. On Linux and macOS the same page fills the window.

Three further numeric divergences from the same function: a `32.0f * dpi_scale`
margin subtracted where GTK zeroes margins in fit modes; a floor of `0.02` vs
GTK's `0.10`; and no `viewport <= 80` guard, so the first layout pass of an
unsized window snaps to a garbage zoom instead of holding. Separately, the
per-side margin disagrees *between two Windows files*: `16.0f * s`
(`spdf_win_d2d.cpp:230`) against 22 horizontal / 13 vertical
(`spdf_win_layout.h:124-125`, matching GTK) against a flat unscaled `32.0f`
(`spdf_win_main.cpp:190-191`).

Worth recording clearly: the ported `spdf_win_layout.h` **is** a faithful,
differentially-tested port of `spdf_docview_internal.h`. The shipping code just
does not include it. The good work exists and is bypassed.

**Cost:** open an A6 ticket or a 200 pt receipt maximised and Windows shows it
tiny where the other two frontends fill the window.

---

### F5 — `spdf_compat_mkstemp` is the one shim that uses narrow paths — **FIXED** (`2bff74d7c`)

`portable/core/spdf_win_compat.c:123-125` calls `_mktemp_s` and `_sopen_s` on
`scratch`, which holds **UTF-8 bytes** copied from `template_path` — the path
`create_temp_save_path` built from the user's own document directory. Both are
the narrow CRT entry points and decode through the ANSI code page, which this
guest's own `harness.non-ascii-path` case measures as **CP1252**.

The asymmetry is self-evident twelve lines below: `spdf_compat_mkdtemp` widens
and calls `_wmkdir`. And the file's own header claims *"Every path here goes
through the `*W` entry points."*

**Cost:** saving an edited PDF from a directory whose name is outside CP1252 —
Greek, Cyrillic, CJK, most emoji — either fails or drops a mojibake temp file
next to the document. This is risk 3/4 of the port plan in a new disguise, and
it is exactly the failure class the shim was written to eliminate. It is also
the one thing `SPDFCoreSaveTests` might have caught, and `SPDFCoreSaveTests` does
not run (F2).

---

### F6 — `mkdir_one` reports success when a *file* occupies the directory name — **FIXED** (`2bff74d7c`)

`portable/win/src/spdf_win_paths.c:299-300`:

```c
    if (CreateDirectoryW(wide, NULL)) return 1;
    return GetLastError() == ERROR_ALREADY_EXISTS;
```

`CreateDirectoryW` sets `ERROR_ALREADY_EXISTS` when a **file** — not a directory
— sits at that path. `spdf_win_paths_state_dir` then returns 1 with a path that
is not a directory, and every later `CreateFileW` beneath it fails with
`ERROR_PATH_NOT_FOUND`, which F7 turns into "you have no settings".

The POSIX branch thirty lines down gets it right (`spdf_win_paths.c:329`:
`stat(...) == 0 && S_ISDIR(st.st_mode)`), so the two branches of the same
function disagree — and the POSIX branch is the one a macOS-hosted reading of
this file exercises. Needs the matching `GetFileAttributesW` +
`FILE_ATTRIBUTE_DIRECTORY` check.

---

### F7 — A transient state-read failure is indistinguishable from "no state", and the next save overwrites it — **FIXED** (`2bff74d7c`)

`spdf_win_state.c:34-65`'s `read_file_limited` returns `NULL` for a widen
failure, a `CreateFileW` failure (including a transient antivirus lock or sharing
violation), a `GetFileSizeEx` failure, a file over 2 MB, a `malloc` failure, and
a short read. `spdf_win_state_read_json_at:238` collapses all of them into
`NULL`, which `spdf_win_state.h:23-24` defines as *"absent, defaults apply."*
The coalesced writer then re-reads to skip a no-op (`:266-274`), gets `NULL`
again, and writes the defaults over the real file.

**Cost:** one antivirus lock at the wrong moment silently discards the recent
files list, every window position, and the session. The mac/GTK precedent covers
"corrupt file"; neither covers "I/O error", and no caller can tell the two apart.

---

### F8 — The comparator's two alpha guards are inert against the only real image comparison — **FIXED** (`abfd37255`)

I attacked `compare_png.py` directly with my own mutations of the real reference
PNG rather than trusting its self-test. It is **sound**:

| mutation | exit | diagnosis |
|---|---|---|
| identical (control) | 0 | byte-identical |
| blank white, opaque | 1 | BLANK OUTPUT (flat colour) |
| blank fully transparent | 1 | BLANK OUTPUT (alpha 0) |
| vertical flip | 1 | VERTICAL FLIP, names the fix |
| R/B channel swap | 1 | R/B CHANNEL SWAP |
| half scale | 1 | WRONG SCALE, 0.5× |
| transparent-pixel halo | 1 | TRANSPARENT-PIXEL HALO, 8000 px |
| one 40×40 block destroyed | 1 | LOCALISED DAMAGE (worst-block) |
| 1-row vertical shift | 1 | TOLERANCE + LOCALISED DAMAGE |
| missing file | 2 | decode error |

All five bugs named in the brief are caught, plus two I added. No complaints
about the comparator itself.

**The problem is what it is pointed at.** `golden.pdf` renders **fully opaque** —
I measured `alpha_min == alpha_max == 255`, `partial_px 0`,
`transparent_colored_px 0`. Premultiplying a fully opaque image is the identity
transform, so the premultiplied-alpha detector and the transparent-halo detector
— the two aimed squarely at the bug this repo has already shipped once — cannot
fire on the only real comparison in the suite. I verified this: premultiplying
the reference produces a byte-identical image that passes even `--strict`.

Compounding with F3: those two detectors are aimed at a class of bug that only
the Direct2D path can commit (it declares
`DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED` at
`spdf_win_d2d.cpp:212` and `:388`, and converts by hand), and no test compares
Direct2D output at all. The guard is doubly disconnected from the thing it
guards.

**Fix:** give the fixture a partially transparent region, and point the
comparison at `--render-png` output as well as the probe's.

---

### F9 — The tolerance is still `UNMEASURED` although the measurement exists — **FIXED** (`abfd37255`)

`compare_png.py:65-66` still reads `MEASURED_MAX_MAE = None`,
`MEASURED_MAX_BAD_PCT = None`, and its docstring still says *"As of this commit
no Windows render exists yet."* It does exist, and it is byte-identical.
`portable/win/README.md` states the conclusion plainly — *"the tolerance for core
render comparisons is zero, and it should stay zero"* — but nothing enforces it:
`case_probe_png` runs `--strict` for the report only, with the comment *"it never
decides the case"*, and the case is decided by the loose defaults
(`max_mae 1.5`, `max_bad_pct 2.0`, `max_block_mae 12.0`).

The consequence is concrete: my own 1-row-shift mutation moves the MAE to 4.15
and is caught, but a subtler regression that stayed inside 1.5 MAE and 2% bad
pixels would pass a comparison that is known to be exactly zero today. The plan
says *"If the delta is zero, pin it at zero."* It is zero. Pin it.

---

### F10 — `tools/check-file-sizes.sh` is red — **FIXED** (`e53d24466`)

```
File-size ratchet failed:
  portable/win/src/spdf_win_render.c: 732 lines exceeds the unlisted 500-line default
CHECK_FILE_SIZES_EXIT=1
```

This is uncommitted Phase 3 work, so it is a warning rather than a landed
regression — but it is risk 11 of the port plan arriving exactly as predicted,
and it will block a release. The **committed** tree is clean: this is the only
violation reported.

---

### F11 — Two of the "passing suites" are unregistered stale binaries — **RESOLVED IN REPORTING**

`core_compat_yaml` and `recolor_smoke` are not in `CORE_SUITES` and are not
discovered by `case_win_tests` (which globs `tests/*_test.c`). They pass when I
run them:

```
core_compat_yaml    exit=0   SPDFCoreCompatTests: all checks passed
recolor_smoke       exit=0   ok
```

— but those are `.exe` files built by hand at 03:46 and 03:58 and never rebuilt.
Running a stale binary proves nothing about current sources, and `run-tests.sh
--list` does not mention either of them. Also note `core_compat_yaml.exe` and
`core_compat_tests.exe` print the *same* banner as `SPDFCoreCompatTests.exe`;
they appear to be three copies of one suite counted as three results.

---

### F12 — `portable/win/README.md` contradicts itself — **FIXED** (`abfd37255` + this commit)

The harness chapter's "Where it stands" says **"12 cases, 8 pass, 0 fail, 4
blocked"**, blocked on an `LNK2048` alignment defect in `libmupdf.lib`, and that
*"Until it is fixed there is no Windows render."* The MuPDF chapter two hundred
lines later says libmupdf builds, links and renders byte-identically — which is
true, and which I confirmed. A reader who stops at the first section will
conclude the port has no Windows render at all.

---

### F13 — The two Windows entry points disagree about page numbering — **FIXED** (`647d9390f`)

`spdf_win_probe.exe golden.pdf 0` renders the first page. `ShenzhenPDF.exe
--render-png golden.pdf 0` answers *"Page 0 is outside this document (2
pages)"* and exits 1; it wants `1`. Both are test-facing interfaces over the
same fixture in the same directory. Whoever wires up the missing D2D comparison
(F3) will compare different pages and not immediately know why.

---

### F14 — The working tree does not compile — **FIXED** (tree now clean; app target builds)

At the time of audit, `spdf_win_canvas.h` existed with no `.c`/`.cpp` sibling
(the `.cpp` appeared minutes later), `SPDF_WIN_FIT_CONTAIN` was referenced from
three `.cpp` files after the header renamed it to `SPDF_WIN_FIT_CANVAS`, and
`spdf_win_d2d.cpp` still read `d2d->cache_bitmap`/`cache_src`/`cache_w`/`cache_h`
after the struct moved to a slot array. Building the app target fails with a wall
of `LNK2019: unresolved external symbol spdf_win_canvas_*`.

Recorded only as the state of the tree, not as a defect in anyone's landed work.
The `ShenzhenPDF.exe` I exercised for F3 and F4 is the 04:00 binary built from
committed sources.

---

### F15 — Smaller items, verified, not individually severe — **MOSTLY STILL OPEN**

- **`spdf_yaml.c:1120` inverted guard.** `if (snprintf(backup, sizeof(backup),
  "%s.migrated-backup", json_path) < (int)sizeof(backup))` passes on a
  *negative* return, then calls `spdf_compat_replace_file(json_path, backup)`
  with `backup` uninitialised. Truncation is handled; encoding error is not.
  This is **shared core code that ships on macOS and Linux too**. Wants
  `n >= 0 && n < (int)sizeof(backup)`. Two more `snprintf` sites
  (`spdf_win_state.c:276`, `spdf_yaml.c:1085`) have the same missing `n < 0`
  arm without the inversion.
- **`spdf_compat_widen` accepts malformed UTF-8**, substituting U+FFFD
  (`MultiByteToWideChar(CP_UTF8, 0, …)` — no `MB_ERR_INVALID_CHARS`), so a
  "mostly converted" path is opened silently. `spdf_win_paths.h:22-27` goes to
  real trouble to reject exactly this, for exactly the right stated reason. The
  two files disagree about the same class of path.
- **Five narrow `remove(temp_path)` calls** at `shenzhen_pdf_core.c:2394, 2403,
  2437, 2478, 2487`, return values ignored, on user document paths, at the moment
  a save has just failed. `spdf_compat_unlink` exists and is used by
  `spdf_yaml.c`; the core save paths do not call it. Leaves one orphan
  `.shenzhenpdf-save-XXXXXX` beside the user's PDF per failed save.
- **`spdf_win_probe.c` uses narrow `main(int, char**)`**, so the port's own
  conformance oracle cannot be pointed at a non-CP1252 path — the exact bug class
  §2.2 names as top risk. `spdf_win_main.cpp:243` gets this right with
  `CommandLineToArgvW`.
- **No `\\?\` prefix in `spdf_win_compat.c`.** `spdf_win_state.c` builds
  extended-length paths for everything it touches; the compat shim passes
  `spdf_compat_widen(path)` straight through, and `SPDF_COMPAT_PATH_MAX` is 1024
  — so the core can compose paths Win32 rejects at 260 without `LongPathsEnabled`.
- **No `FOLDERID_LocalAppData` anywhere in `portable/win`.** macOS separates
  state from cache; whatever cache lands next will go into `%APPDATA%` and roam
  with the profile on a domain network.
- **`session.lock` is declared and never taken.** `spdf_win_state.h:94-96`
  documents the protocol; `spdf_win_state_write_json_at` does read-compare-write
  with no lock and nothing calls
  `spdf_win_state_session_lock_acquire`. Untriggerable with one window; a
  lost-session bug the day a second one lands.
- **Dark-theme page separation reproduces a defect macOS explicitly fixed.**
  Windows draws a 10%-black offset rectangle in both themes
  (`spdf_win_d2d.cpp:306-309`). `SPDFMacDocumentViewTheme.mm:47-49` spells out
  why that is wrong on a dark gutter — a black shadow is invisible there — and
  swaps to a 1 px border, as does GTK.
- **The 96 MB render cap is never applied on the Windows path.**
  `spdf_win_capped_render_zoom` exists in `spdf_win_layout.h` and has no callers;
  GTK caps unconditionally at `spdf_render.c:291`. `--render-png <f> <p> <zoom>`
  is entirely unbounded.

---

## 3. What I attacked and could **not** break

Stated plainly, because a QC report that only lists faults is as misleading as
one that lists none.

**The exit-code contract holds under every attack I could construct.**

| attack | result |
|---|---|
| `vm-build.sh` on `smoke/broken.c` | exit **2** (cl.exe's own), `guest build FAILED` |
| guest `exit /b 0 / 1 / 42 / 255` | `$?` = 0 / 1 / 42 / 255 exactly |
| guest `exit /b 256`, `exit /b 3221225477` | clamped to **255** — non-zero preserved, the safe direction |
| a guest binary that **crashes** (null deref) | **255** |
| a guest binary that calls `abort()` | **255** |
| `ExitProcess(0xC0000100)` — low byte is `0x00` | **255**, not 0. An 8-bit truncation would have reported success here; it does not |
| a real failing case (`core.SPDFCoreSaveTests`) | `run-tests: FAILED`, exit **1** |
| `--self-check` (injected failure) | reports `injected failure produced exit 1` |
| VM unreachable (`SPDF_VM_NAME` bogus) | 12 BLOCKED, `"This is NOT a pass"`, exit **2** |
| `--filter` matching nothing | `"NOTHING RAN … refusing to report success"`, exit **3** |

The crash cases are pinned at **`portable/win/tests/qc/crash_probe.c`**. The
0xC0000100 case is the interesting one: it is the value that would distinguish a
faithful propagation from a naive `& 0xFF`, and `prlctl` clamps rather than
truncates. Nothing in the docs claims this; it is now checked.

`compare_png.py` also survived everything I threw at it (F8's table). The three
habits the runner's header insists on — no `set -e`, nothing piped into
`grep`/`tee` to decide pass or fail, status computed from records at the end —
are genuinely observed throughout `run-tests.sh`, `harness-lib.sh` and
`probe-cases.sh`, and they are why F2 surfaced as a loud red failure instead of a
quiet green one.

`portable/win/verify.sh` → exit 0. `mupdf-arch-check.sh` → exit 0.

---

## 4. Is Phase 1 complete by its own definition?

The plan's Phase 1 bar is: *"the window opens, the page is visible and correctly
scaled to the client area, resizing repaints, DPI scaling is correct on a 2×
display, and closing exits 0."*

**Not by that definition — and by construction it cannot be, from here.** All
five criteria are interactive. `prlctl exec` runs in the SYSTEM session, which
the plan itself notes (risk 9) has no interactive GUI; the plan's own answer is
that screenshot verification is *"later and manually"*. So nothing in this
session — mine or anyone's — has observed a window open on Windows. The
`ShenzhenPDF.exe` claim rests entirely on the two headless modes.

What is genuinely proven:

- The core renders **byte-identically** on Windows. Solid, independently
  re-verified, and the strongest possible foundation. **Confirmed.**
- The binary is **native ARM64**, including all 646 MuPDF objects. **Confirmed.**
- The Direct2D compose path produces **byte-identical output** in both plain and
  dark themes — which I established, because no test does (F3). Its scaling is
  wrong for small pages (F4), so "correctly scaled to the client area" fails on
  its own terms.
- `--render-png`'s error paths are sound: out-of-range page → exit 1, missing
  document → exit 1, unwritable output → exit 1 with the `HRESULT`. I expected
  to find a silent success here and did not.

A fair summary: **Phase 1 is complete at the core-and-pixels layer and unproven
at the window layer.** The port plan is unusually honest — it opens by saying
seven hours does not produce a 1:1 port — and the work matches that honesty
almost everywhere. The two places the documentation outruns the evidence are the
Phase 1 headless test, which describes a `spdf_win_paint()` comparison that was
never written (F3), and the harness chapter's stale standing (F12).

---

## 5. macOS regression status

All by exit code, `set -o pipefail`, never by piping into `grep`.

| check | exit |
|---|---|
| `make -C portable mac-app` | **0** |
| `make -C portable test-binaries` | **0** |
| every `*-tests` target except `file-size-ratchet-tests` (28 suites, run one at a time) | **0** |
| `file-size-ratchet-tests` / `tools/check-file-sizes.sh` | **1** at audit time — F10, now **0** (`e53d24466`) |
| `portable/mac/tests/markdown/run-tests.sh` | **0** |
| `portable/mac/tests/run-markdown-integration-tests.sh` | **0** |

Suites run individually rather than as one `make` invocation, so that a single
failure could not mask the rest. Core, password, recolor, render-theme, selection,
CJK-selection, icon, release-pipeline and all 20 `mac-*` suites pass.

**macOS is unregressed by the Windows work.** The single exception at audit time
was the file-size ratchet, tripped by an then-uncommitted Phase 3 file; it landed
split under the cap and the ratchet is green.

---

## 6. Recommended order of work

**Items 1, 2, 5, 6 and most of 7 are done.** What remains, re-ordered 06:45:

1. **F3 — add a Direct2D compose comparison case.** The single largest coverage
   gap in the port. `ShenzhenPDF.exe --render-png` and `--render-window-png` both
   work, write PNGs, and have been compared by hand and found byte-identical in
   both themes — so this is a morning's harness work with a known-good answer
   waiting at the end of it, not an investigation. Until it exists, the layer
   that the whole Direct2D-over-WIC architecture was chosen to make testable is
   the one layer nothing tests.
2. **Fold `t3-verify.sh`'s 7 cases into `run-tests.sh`.** The GTK4 differential
   (397,099 comparisons, 0 mismatches) is the strongest correctness evidence the
   layout port has and it does not run in the gating suite, because
   `gtk_differential.c` is not named `*_test.c`. Anyone editing
   `spdf_win_layout.h` will not learn they broke it.
3. **Register the remaining four core suites.** `SPDFCoreOutlineTests`,
   `SPDFCorePasswordTests`, `SPDFCoreRenderThemeTests`, `SPDFCoreSelectionTests`
   and `SPDFCoreCJKSelectionTests` are written, pure C over MuPDF, and absent
   from `CORE_SUITES`. Near-free Windows conformance; the plan called this out at
   03:22 and it is still unclaimed.
4. **F15's `spdf_yaml.c:1120`** — an inverted guard that calls
   `spdf_compat_replace_file` with an uninitialised buffer on a negative
   `snprintf`. **This ships on macOS and Linux too**, which makes it the only
   open finding here that is not Windows-only.
5. **F15's `session.lock`** — take the lock in `spdf_win_state_write_json_at`
   before Phase 4's multi-window work makes its absence a lost-session bug.
6. **F15's dark-theme shadow** — a 10%-black drop shadow is invisible on a dark
   gutter; macOS explicitly fixed this and documented why
   (`SPDFMacDocumentViewTheme.mm:47-49`). Windows currently reproduces the
   defect macOS removed.
7. **The rest of F15** — `MB_ERR_INVALID_CHARS`, the five narrow `remove()`
   calls, the probe's narrow `main`, `\\?\` prefixes, `FOLDERID_LocalAppData`,
   and capping `--render-png`.

And the one that is not a code change at all:

8. **Get a human to open the window.** Every other item on this list can be done
   by an agent from macOS. This one cannot, and it is the only thing standing
   between "Phase 1 complete on a generous reading" and "Phase 1 complete".
