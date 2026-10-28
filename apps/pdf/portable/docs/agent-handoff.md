# Agent handoff — how this codebase works and how to work in it

Written 2026-09-08, revised 2026-09-22 (releases 26.9.1-1 → 26.9.15-1). It is
the document I wish I had had on day one: the shape of the code, the reasons
behind its rules, where the tools are, and the traps that cost hours. Read
`agents.md` first (the rules — lowercase, and the filesystem here is
case-insensitive while git is not), then this, then the deeper docs it points
at.

- [What you are working on](#what)
- [Philosophy — the rules and why they exist](#philosophy)
- [Architecture map](#architecture)
- [Mechanisms you will touch](#mechanisms)
- [Tools and commands](#tools)
- [The release pipeline](#release)
- [Working conventions](#conventions)
- [Traps, each one paid for](#traps)
- [Open threads](#open)
- [First hour checklist](#first-hour)

## <a id="what"></a>What you are working on

ShenzhenPDF: a native macOS reader (AppKit, Objective-C++) for PDF and Markdown,
on a portable C core wrapping MuPDF. A GTK4 Linux frontend and a native Win32
frontend (`portable/win/`, in progress on a separate track, no binary shipped)
share the core and the on-disk formats. The inherited SumatraPDF tree (`src/`,
`vs2022/`, `cmd/`, `bin/`, `appx/`, `packages/`, `translations/`, premake, and
the three GitHub Actions workflows that built it) was deleted on 2026-09-15 —
523 files. `ext/` and `mupdf/` stay because the portable build compiles against
them, and `gfx/` because the macOS icon is built from it. The app is described
in `readme.md` (short) and `docs/features.md` (exhaustive — keep it current when
you ship a feature).

The owner uses the app all day on the same Mac you run on. Everything below is
shaped by that fact.

## <a id="philosophy"></a>Philosophy — the rules and why they exist

**The file-size ratchet is the codebase's immune system.** `tools/check-file-sizes.sh`
enforces 500 lines per maintained source file; 501–1000 needs an `exception`
entry with a justification in `tools/file-size-limits.tsv`; anything larger is
`legacy` with an *exact* cap that may only shrink. Several files sit exactly at
their cap (`ShenzhenPDFMac.mm` at 16297, `SPDFMacDelegatePrivate.h` at 641,
`SPDFMacUIHelpers.mm` at 744). Adding one line to those means removing one, and
the sanctioned way to pay is **extraction**: move a coherent unit into a new
file and lower the cap in the same change. Never raise a cap to pass. This is why
the mac frontend is ~143 small files and categories rather than one coordinator.
Read `tools/file-size-limits.md`.

**Every fix ships with a test that fails on the old code.** Prefer a pure
function you can call headlessly (see `SPDFMacFitGeometry.h`,
`SPDFMacSidebarOutline.mm`, `SPDFMacPageWheel.mm`, `SPDFMacMarkdownCopyText.mm`)
over UI plumbing. When the cause is a call that must exist in the coordinator, a
**source-contract test** that asserts on the coordinator's source text is the
accepted fallback (see `SPDFMacTabStateTests.mm`). Before claiming a test bites,
run it against the pre-fix code (`git show HEAD:path > /tmp/old.mm`, compile
against that).

**Comments say WHY.** Every non-obvious line carries the failure that motivated
it, often with the measured numbers. Match this. Lines are ≤120 columns; the
repo has a `.clang-format` but it does not cover Objective-C, so format by hand.

**Rendering is deterministic and explicit.** Theme variants, render options and
page configurations are passed as parameters; colours in rendered output are
concrete sRGB constants; screen, print, export and copy-page draw from the same
plan. Exports never carry the dark theme. See `portable/mac/markdown/README.md`.

**Speed is a requirement, not a feature.** Nothing new runs on the launch path;
a feature costs nothing for documents that do not use it. Measure with
`SPDF_LAUNCH_PROFILE=1` (phase timings to stderr). Current reference: first
window on screen ≈170 ms; a restored second window is a second process and now
starts alongside the first. `make -C portable mac-launch-performance-tests`
(in the release sweep) takes the previous release's app from its DMG and launches
it beside this tree headlessly, 15 interleaved rounds, Friends on and off: the
median per-round ratio of main-thread CPU before the first frame must stay
within 1.05x and spawn-to-first-frame within 1.08x, Friends must do no
main-thread work before the first frame and must connect to its helper. The
probe (`mac/tests/launch/SPDFMacLaunchPerformanceProbe.mm`, a library inserted into
both apps) also measures idle
CPU and wakeups (`PROBE_MODE=idle`), document opens and page jumps.

**Quitting hides first.** Cmd+Q, the close button and a window's last tab take the
windows off the screen before anything else (a key monitor sees Cmd+Q before the menu
highlight), answer `NSTerminateLater`, write out of sight and `exit(0)`, skipping AppKit's
~300 ms pasteboard wait unless this process last wrote the general pasteboard
(`SPDFMacQuitFinishing.mm`). A Dock click or document open while finishing starts a fresh
launch once the writes are done. Nothing on close or quit ever asks: edits to a read-only,
temporary or Collection-backup PDF go to a writable copy under `Edited Copies`
(`SPDFMacWritableCopy.mm`). Work that must wait for the first frame goes through
`spdf_mac_after_first_paint`, not a `dispatch_after` from launch code (its timer fires
before the first frame). `make -C portable mac-quit-performance-tests` (budgets for the
first frame and for the window leaving on quit, on a synthetic 100-tab profile; pass
`--baseline-app` to `run-quit-performance.py budget` for a before/after table) and
`mac-quit-integrity-tests` (20 quit-and-relaunch rounds with edits; nothing lost, nothing
asked). Instruments shows `Launch` and `Quit` signposts (category Lifecycle).

**Extraction over cleverness, and pictures over prose.** The readme is
picture-first; a feature earns a cropped screenshot, not a paragraph.

## <a id="architecture"></a>Architecture map

```
portable/core/        C: MuPDF wrapper (shenzhen_pdf_core.c), recolor (dark theme luma remap),
                      selection, YAML state codec, and the Windows-side Markdown C engine.
portable/mac/         AppKit app. ~90 .mm files. Entry: ShenzhenPDFMac.mm (the "coordinator",
                      class ShenzhenMacDelegate — app delegate + window controller + reader).
portable/mac/markdown/ The Markdown engine: parser (vendored MD4C + Gumbo), renderer to one
                      canonical NSAttributedString, paginator onto A4 sheets, native vector
                      diagrams, math typesetter, themes. Pure; no AppKit views.
portable/linux/gtk4/  GTK4 + libadwaita frontend on the same core and YAML files.
portable/win/         Native Win32 + Direct2D frontend (another agent's track; see its docs).
portable/release/     Release pipeline library and its tests.
portable/docs/        Journals, plans, this file, releases/<tag>.md notes.
tools/                Ratchet checker + tests.
```

### The coordinator and its categories

`ShenzhenMacDelegate` is declared in `SPDFMacDelegatePrivate.h` (ivars — capped)
and implemented across `ShenzhenPDFMac.mm` plus many `ShenzhenMacDelegate (X)`
categories, one per concern: `SPDFMacTabViewState` (a tab's view state becoming
the window's live state), `SPDFMacSidebarChapters` (chapter nesting + the
expand/collapse control), `SPDFMacWindowPlacement` (window frames across
displays, spawning sibling windows), `SPDFMacReadingThemeIntegration` (the one
dark-theme preference driving PDF recolor and the Markdown palette),
`SPDFMacLaunchPrerender` (speculative first-page render during launch),
`SPDFMacMarkdown*Integration` (routing Markdown tabs into the same chrome).
New coordinator behaviour goes into a category or a pure helper, never into the
big file.

### Two document paths, one chrome

- **PDF/XPS/EPUB/…**: `SPDFDocumentView` (`SPDFMacDocumentView.mm`) draws
  pre-rendered page bitmaps; zoom re-renders; `SPDFDocumentClipView` carries the
  page-aware scroll locks. Rendering pipeline, queues, crop regime, minimap:
  `portable/docs/architecture.md` — read it before touching any of that.
- **Markdown**: `SPDFMacMarkdownSession` owns a document's render + plan and its
  `SPDFMacMarkdownPagedView` (an `NSScrollView` whose zoom is `magnification`)
  around `SPDFMacMarkdownPageCanvas` (draws the plan with CoreText, live). The
  canvas is split into categories: `+Copy`, `+Cursor`, `+Decorations` (link
  rects, code-box controls), `+Navigation`, `+Pan`, `+Search`, `+Focus`. The
  paged view's fit logic lives in `SPDFMacMarkdownPagedView+Fit.mm`; its ivars
  are in `SPDFMacMarkdownPagedViewPrivate.h` so categories can reach them.

### The canonical string (Markdown)

`SPDFMarkdownRenderedDocument.attributedString` is the ONE coordinate space for
selection, search, links, pagination. It already encodes structure: `\n` after
every block and table row, `\t` before every table cell, list markers as text.
The **renderer records a rendered block per table ROW, never per cell** — cells
own the inline runs but have no rendered range. Anything walking blocks must
inherit the nearest recorded ancestor's range (see `SPDFMacMarkdownView.mm`).
Click destinations are stamped as `SPDFMacMarkdownDestinationAttribute` on the
"interactive string" (`SPDFMacMarkdownInteractiveString`), not `NSLinkAttributeName`.

### State on disk

`~/Library/Application Support/ShenzhenPDF/` (override with `SPDF_STATE_DIR`):
`settings.yaml`, `session.yaml` (windows → tabs; one entry per window with
`frame`, `selectedTab`, `focusedAt`), `documents.yaml` (per-file memory keyed
by standardized path: panels, collapsed chapters, Markdown orientation, page
geometry), `favorites.yaml`, `bookmarks.yaml`, `activity.yaml` (last opened and
last viewed per standardized path, merged under `activity.lock` by every window's
process; see `SPDFMacDocumentActivity.h`). Human-readable, hand-editable
while the app is closed. `spdf_dictionary_from_tab` / `spdf_tab_from_dictionary`
in `SPDFMacModels.mm` are the ONLY tab codecs — a second inline writer once
silently dropped a field for a release.

### Collection and version history (macOS)

`SPDFMacCollectionStore*` owns a lazy immutable blob store, atomic locked manifest,
identity and per-revision text indexes. No store work belongs on the empty launch
path. Capture follows first-use consent and a successful document open. Protection
before source writes must succeed or receive explicit Continue Without History.
Generic opens treat an unrelated replacement as a new document; observed changes
and successful app saves supply an explicit document ID. Per-path generations and
a durable protection epoch, checked under the shared lock, prevent older queued
captures in any window from superseding a newer edit. Keep those paths distinct.

`SPDFMacCollectionIntegration` wires consent and deferred capture; sidebar/export
integration, palette and manager are separate files. Save a Copy creates a new file
and cannot overwrite originals. `SPDFMacCollectionCompare*` aligns actual rendered
PDF/Markdown pages and presents independent PDFKit readers with red/green changes.
Markdown assets come from the reader parser's actual image nodes, never regexes over
source examples. Archives carry a persisted display label and cannot be edited.

Focused tests: `mac-collection-store-tests`, `mac-collection-asset-tests`,
`mac-collection-compare-tests`, `mac-collection-palette-tests`; the Markdown integration
runner compiles at production `-O2`, constructs manager/history/comparison windows
headlessly, and checks real Markdown indexing, mixed text/image page alignment and
PDFKit accessibility ownership. Aligned comparison PDFs are serialized and reopened
on the worker queue before installing independent backed documents in the readers. The implementation
and critic evidence live in `docs/journals/collection-implementation/`.

### Windows are processes

A multi-window session restores as **one process per window**: the process that
activates takes the window with the newest `focusedAt` and relaunches the others
with `--restore-window <id>`. Consequences: `applicationShouldTerminate`
**cascades** (quitting one instance terminates every other ShenzhenPDF process,
including a capture instance you launched), each process writes only its own
session entry under `session.lock`, and a window is "key" inside its own process
even when the app is not active (hence `NSApp.isActive &&` on the focus stamp).

## <a id="mechanisms"></a>Mechanisms you will touch

- **Exact-viewport fit.** Fit zooms are computed against the raw clip size; the
  decorative canvas inset collapses at exact fit (`SPDFMacFitGeometry.h`, pure,
  shared by both views). A fit also *places* the current page: centered where it
  fits, flush at its top where taller (`spdf_mac_fit_scroll_origin_y`,
  `alignCurrentPageAfterFit`).
- **Markdown magnification.** The clip view's bounds are in unmagnified document
  units. Any pointer delta must be divided by `magnification`; any scroll origin
  must land on a device pixel or live text wobbles (`SPDFMacMarkdownClipView`).
- **Option + wheel = page arrows.** `SPDFMacPageWheel.mm`, distance-based rather
  than notch-based so that mice delivering precise deltas page at the right rate;
  routed from `SPDFWindow -sendEvent:` so pointer location does not matter.
- **Chapter nesting** is modelled on table rows (`level`), not an
  `NSOutlineView`; collapsed keys are positional (`"0.2.1"`) in `documents.yaml`.
  Removing a segment from the sidebar `NSSegmentedControl` clears its selection
  to −1 — `spdf_sidebar_mode_control_set_segment_count` guards that.
- **Copy.** PDF copy collapses whitespace (line breaks are visual wraps).
  Markdown copy must not: `SPDFMacMarkdownCopyText` keeps blocks, rows, tabs, and
  applies the transform only inside a cell.
- **Reading theme.** One byte, `_darkReadingTheme`, read on background queues;
  changes bump the render generation. PDFs are luma-remapped in the core with
  chroma kept; Markdown swaps to a concrete dark palette; the minimap has its own
  variant. Print/export/copy-page never carry it.
- **External tools run in an environment the app controls.** ocrmypdf and Argos
  are Python programs and are **never installed globally**: Homebrew provides
  only the C programs ocrmypdf shells out to (tesseract, ghostscript), and the
  Python side goes into a virtualenv under Application Support. Every `NSTask`
  goes through `spdf_mac_tool_environment` (`SPDFMacToolEnvironment.h`), which
  drops `PYTHON*`, `CONDA*`, `VIRTUAL_ENV*`, `PYENV*`, `PIP_*`, `DYLD_*` and
  `__PYVENV_LAUNCHER__` — a leaked `PYTHONHOME` killed Homebrew's ocrmypdf
  outright — and builds a deterministic PATH. Installers do **not** use a login
  shell. A machine with no virtualenv is sent to the installer rather than
  adopted silently, once per session so a machine with no usable Python is not
  asked on every run.
- **The OCR command line is a pure function** (`SPDFMacOCRCommand.h`), and each
  flag is justified by a measurement written beside it: `--tesseract-pagesegmode
  11` because a dimension number alone among line art is not a column of prose
  (4 of 5 recovered against 2); `--oversample 400` because small text dies at low
  DPI. A source whose every page is a full-page image is re-recognised
  (`--force-ocr`) rather than trusted (`--redo-ocr`), because its "text" is a
  previous OCR pass. Verdicts about a finished run live in
  `SPDFMacOCRValidation.h`: a run that skipped pages, and a refusal ocrmypdf
  itself explains (a tagged PDF), both retry forced once.
- **Detaching a tab is a new process**, and the reading position crosses the
  boundary in a handoff file named from the document's path
  (`SPDFMacTabDetach.h`, `spdf_mac_detach_handoff_name`). The child adopts it
  before opening anything; `-openPaths:` reuses a tab that already exists for a
  path, which is what makes the seeded tab win.
- **Whole-document translation is PDF-shaped.** A Markdown document has no page
  geometry to write translated lines into, so it is rendered to a PDF beside
  itself and that is translated (`SPDFMacMarkdownTranslate.h`).
- **Launch prerender.** Starts in `main()` before `applicationDidFinishLaunching`,
  reads `settings.yaml` early, speculates on the session's focused window's
  selected tab, bails for Markdown and cloud paths. Ownership state machine in
  `SPDFMacLaunchWorkPolicy.mm`. Disable with `SPDF_DISABLE_LAUNCH_PRERENDER=1`.

## <a id="tools"></a>Tools and commands

```sh
make -C portable mac                     # alias for mac-app; builds dist/ShenzhenPDF.app (ad-hoc signed)
make -C portable <name>-tests            # one suite; names: grep -oE '^[a-z0-9-]+-tests:' portable/Makefile
make -C portable mac-markdown-tests      # engine suites (mac/tests/markdown/run-tests.sh)
                                         # + UI suites (mac/tests/run-markdown-integration-tests.sh)
./tools/check-file-sizes.sh              # the ratchet; tools/test-file-size-ratchet.sh self-tests it
./portable/cut-release.sh --dry-run|--prepare-only "summary"|--publish
```

Test suites are plain executables under `portable/mac/tests/` (and
`tests/markdown/`); each prints `<Name> passed` and exits 0. **Judge by exit
code**, never by grepping for "passed". Adding a UI suite means adding it to the
`TESTS` list in `run-markdown-integration-tests.sh` and, for a new source file,
to that script's `SOURCES`; the app itself globs `mac/*.mm`, so new sources need
no Makefile change. `make` skips a rebuild when source and binary share the same
mtime second — `rm -f build/<Test>` before trusting a rerun.

Env switches: `SPDF_STATE_DIR` (private state for experiments), `SPDF_NO_ACTIVATE=1`
(do not steal focus), `SPDF_LAUNCH_PROFILE=1`, `SPDF_DISABLE_LAUNCH_PRERENDER=1`,
`SPDF_RENDER_WORKERS`, `SPDF_DIAGRAM_LAYOUT_DEADLINE` (tests raise the diagram
budget so they are not timing-dependent).

Headless probes beat launching: compile a throwaway `.mm` against the sources
the test script lists, print geometry, delete it. If you must capture the app
(only when asked): scratch `SPDF_STATE_DIR`, your own copy of the bundle, find
the window by owner pid (CGWindowList), `screencapture -l <id>`, and end the
instance with `kill -9 <pid>` — never Cmd+Q (the cascade) and never `pkill`.

## <a id="release"></a>The release pipeline

Versions are `YY.M.DD-BUILD`, date of the *prepare*; a build number is spent
only when its tag reaches origin. Flow:

1. Write `portable/docs/releases/<tag>.md`: highlights above one `---` (≤500
   chars, direct, one line each), detail bullets below. The owner reads the
   highlights before every release — show them first.
2. `./portable/cut-release.sh --prepare-only "summary"`: the summary **must** be
   passed positionally — without it the script falls to `read -p`, which has no
   TTY here and exits 1 silently. It validates the notes,
   runs every `*-tests` target (41 at the time of writing), enforces the README
   gate (`readme.md` must change for a feature release; a pure bugfix sets
   `SPDF_README_UNCHANGED=1` deliberately), commits the metadata. The working
   tree must be clean except for the notes file.
3. `./portable/cut-release.sh --publish`: reruns the tests, clean release build,
   Developer ID signing, notarization, DMG, then an **atomic push of master and
   the tag** — the point of no return. It is rejected if origin moved; merge
   `origin/master`, delete the stale local tag it left, publish again. Other
   agents push to master constantly (the Windows track), so check
   `git log master..origin/master` right before both prepare and publish.

The script blocks on nothing — if it seems hung, the shell is (see traps). Poll
`pgrep -f cut-release.sh` and read its log; never sit on a 600 s timeout.

Daily-use local builds with saved AI credentials must also use a stable signing
identity (`make -C portable mac-app MAC_SIGN_IDENTITY='Developer ID Application: …'`).
The default ad-hoc signature changes its designated requirement on rebuild and
can invalidate Keychain trust. Never weaken credential ACLs to bypass this; an
old ad-hoc connection may require one explicit reconnect. Keep startup reads
noninteractive and verify the actual composer-to-send path, including stale
`connection_configured` flags. See [Return-send regression](journals/ai-reader/return-send-regression.md).

## <a id="conventions"></a>Working conventions

- **A reported bug is a fix request.** Diagnose, fix, test, then report — do not
  stop at the diagnosis. If you cannot reproduce, say so with the evidence and
  what you ruled out; do not guess a fix.
- **Validate chrome in its real host.** Reuse the reader’s existing toolbar space
  and button styling before adding rows or surfaces. Check alignment, clipping,
  narrow widths, both appearances and full-bounds clicks in the production
  workspace probe; an isolated control preview is insufficient. Keep the user’s
  app untouched: use offscreen probe renders, not app screenshots.
- **Stage explicit paths, never `git add -A`.** Other agents share the worktree.
  Commit each tested change set with a message that explains the failure and the
  fix; end with `Co-Authored-By`.
- **Be direct and brief** in release notes and reports: plain language, no
  hedging, numbers only where they change a decision.
- **User-facing docs are not your notebook.** `readme.md` and `docs/features.md`
  describe what the app does, in the present tense, for someone deciding whether
  to use it — never how a bug was fixed. A reader assumes it works, so "it now
  handles X correctly" only tells them it used to be broken. Fixes belong in the
  release notes as one brief line each, and the reasoning belongs in the commit
  message. A release that changes nothing a new reader would care about should
  pass `SPDF_README_UNCHANGED=1` rather than invent a readme edit.
- There is a second handoff, `portable/docs/agent-handoff-private.md`, that is
  deliberately untracked: it holds how the owner prefers to work and their
  machine's setup. If it is on disk, read it too; if it is not, ask rather than
  guess at approval boundaries.

## <a id="traps"></a>Traps, each one paid for

- A Bash command that produces no output for minutes is a **shell blocked on a
  prompt**, not a slow build — an interactive prompt in a shell startup file will
  do it. Check `pgrep clang|make|codesign` before waiting.
- A **multi-line regex** stripping debug lines deleted four load-bearing lines
  of window setup and shipped. Delete code with exact-string edits only.
- `initWithContentRect:` takes a content rect and AppKit repositions oversized
  windows during init; apply saved frames after the style mask is final, and
  never persist a fallback position over the one the reader left.
- A hidden `NSScrollView` does not scroll (tests fail mysteriously); use
  `alphaValue = 0` for a pre-rendered swap.
- `NSScreen.screens` may omit a sleeping display early in launch.
- Reusing an expired deadline for a second layout pass made diagrams vanish.
- The README gate's `grep -q` tail SIGPIPEd under `pipefail` on large diffs and
  rejected exactly the rewrite it should have passed (fixed; the lesson is: never
  end a pipeline in `grep -q` under `set -o pipefail`).
- A killed `--publish` can leave a **local tag** pointing at the old commit; the
  next publish refuses until you `git tag -d` it.
- The prepare's version is today's date: notes written yesterday under
  yesterday's tag are "changes outside the release notes" — rename the file.
- **zsh does not word-split unquoted variables.** `for d in $CANDIDATES` runs
  *once* with the whole string as one word, and `make $TARGETS` hands make one
  malformed goal. Both produced confident, meaningless results here — one
  "nothing references these directories" answer that was simply a single bogus
  iteration. Use an array and `"${arr[@]}"`, and sanity-check the count.
- **A build tool's silence is not evidence.** `make mac` had no such target, so
  make matched the `mac/` *directory*, printed "Nothing to be done for `mac'"
  and exited 0 — read as a successful no-op for a whole evening while the binary
  was never relinked, and a committed, tested fix never reached the app. There is
  a `mac` alias now, but the habit is the point: confirm the **artifact**
  changed (mtime, or `strings <binary> | grep '<a string only the new code has>'`),
  never a grep of build output that would also swallow "nothing to be done".
- **A test can encode the bug.** Markdown page stepping asserted `page top - 12`,
  which was the defect; fixing the code failed the test. Before "fixing" a test
  that a correct change broke, work out which one is wrong — here the fixture's
  page height equalled the viewport height, so flush was right and the constant
  was wrong.
- **Substring matching is not verification.** "Is `0.50` in the OCR output?"
  answered yes from an unrelated table cell and inflated a 3-of-5 result to
  4-of-5. Check *positions* (the core's `spdf_extract_page_text_lines` returns
  bounds) when the question is whether a specific thing on the page was read.

## <a id="open"></a>Open threads

- **Markdown light-on-dark launch.** Twice on 2026-09-05 a restored Markdown tab
  rendered the light palette while the gutter, minimap and toolbar were dark;
  never reproduced in ten tries across the dev build, the shipped release binary,
  fresh state and a light→dark replay. If seen again: instrument
  `SPDFMacMarkdownIntegration.mm`'s session creation with the theme byte.
- **Markdown page restore with the minimap hidden** landed on page 1 once out of
  three runs; the other two were correct. Not understood.
- **Diagram labels carry no links** by design: mermaid `click` and flowchart.js
  `:>url` are dropped in the parser. A small feature if wanted.
- Markdown chapters are H1–H3 only; `<details>` always renders expanded;
  footnotes unsupported.
- GTK frontend: a dead copy gate remains at `portable/linux/gtk4/spdf_window.c`
  (copying is always allowed now).
- The Windows track (`portable/win/`, `portable/docs/windows-*.md`) is another
  agent's; coordinate through master, do not edit its files.
- **One OCR dimension still resists.** On a USB-C footprint, `3.50` is read by
  tesseract directly at 600 dpi but lost through ocrmypdf at any oversample;
  something in its preprocessing drops it. Four of the five recover.
- **The repository is no longer a fork.** It was detached from
  `sumatrapdfreader/sumatrapdf` on 2026-09-15, which is what made it findable:
  GitHub excludes forks from repository search by default, so searching its own
  name returned six unrelated repositories and none of them this one. It now has
  a real description and 15 topics. Do not re-fork it, and remember that
  detaching is permanent.

## <a id="first-hour"></a>First hour checklist

1. `git fetch && git log --oneline master..origin/master` — someone else has
   probably pushed.
2. `./tools/check-file-sizes.sh` — know which files are at cap before editing.
3. `make -C portable mac-app` once, so incremental builds are fast (~2 min cold).
4. Read `portable/docs/architecture.md` §3–5 if you touch rendering or scrolling;
   `portable/mac/markdown/README.md` if you touch Markdown.
5. Find the test suite nearest your change and read one test in it — the style
   (headless, `Expect`, prints `<Name> passed`) is the contract.
6. Ask yourself where the line budget will come from before writing the fix.
