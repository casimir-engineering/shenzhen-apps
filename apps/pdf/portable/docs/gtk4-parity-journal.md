# GTK4 Parity Session Journal

2026-07-19 → 2026-07-20, autonomous session on the dev machine
(Ubuntu 25.10, GNOME 49 Wayland, GTK 4.20.1, libadwaita 1.8, 12 cores).
Spec: `gtk4-parity-spec.md`. Branch `linux-gtk4-parity` (unpushed).

## What was built

A complete GTK4 + libadwaita frontend (`portable/linux/gtk4/`, 24 modules,
~19k LOC + 17 test suites / 161 checks) replacing the GTK3 app, in five waves
of parallel worktree agents, each merged only with the container build green
(`-Wall`, zero warnings):

- **A — core:** AdwApplication shell (AdwTabView tabs: native drag reorder,
  continuous-drag detach/reattach, middle-click close, overview), Mac-layout
  header bar, presentation mode + idle inhibit, accel table + F1 sheet;
  custom snapshot/GdkTexture canvas with document-space anchored zoom (fixes
  the June capped-sheet drift), total-width scroll clamp, click-vs-drag
  links, I-beam/hand cursors; worker render pipeline (persistent docs,
  display lists, tokens, 96 MB LRU); Mac-schema JSON state with legacy-GTK3
  migration and workarea-clamped restore.
- **B — features:** search (type-anywhere, regex/multiline, paste-to-search,
  selection-to-search, Escape/nearest-match, scrollbar heat-map, per-tab
  persistence), command palette (all commands + favorites + recents +
  cross-doc text search), annotations (comment CRUD, highlights, rotate,
  save-as, page export, context menu), minimap (thumbnails, strip-scroll
  model db9515802, hit markers, right edge like Mac), sidebar
  (chapters/comments/chapter-grouped results), properties panel (full
  SPDFMacPropertiesFormat port).
- **C — subsystems:** printing (GtkPrintOperation, Fit/Actual/Custom with
  paper-visible-region rendering), file watcher + read-only shadow copies
  (orange dot, session-persisted binding), auto-updater (GitHub Releases +
  minisign over OpenSSL Ed25519/BLAKE2b, pkexec deb install, user-local
  atomic swap + rollback, health probe), OCR + translation ports (19
  languages, toolchain auto-install, post-freeze translate refinements).
- **D — polish:** resident instant-launch (below), login autostart,
  default-reader prompt + menu item (xdg-mime), dark-mode palettes, deferred
  menus, deb packaging + release scripts, this validation.

## Launch speed (the headline requirement)

Measured on this machine; day-2 session was noisy (empty-AdwWindow floor
300–465 ms vs 285 ms on day 1), so deltas beat absolutes:

| Path | Measured | Notes |
|---|---|---|
| Platform floor, first window of a process | 285–465 ms | empty AdwApplicationWindow, any renderer |
| Platform floor, second window, warm process | ~4 ms | the win condition |
| Cold app launch → page visible | ~700–950 ms | once per login with resident mode on |
| First `gtk_window_present` of a process | blocks 240–470 ms | fonts/glyph atlas/CSS/shaders, one-time |
| **Resident warm open (the shipped path)** | **~60 ms** | 40 ms D-Bus forward + 8 ms present + 10 ms first render |

The decisive mechanism: `--resident` login start presents a fully
transparent throwaway window and destroys it after its first frame, paying
the process-global warmup invisibly; every later open forwards over D-Bus to
the held process. `instantLaunchResident` (default on) controls the hold +
autostart entry. Evidence: `SPDF-LAUNCH` marks, `gtk4-captures/launch-profile.txt`.

## Capture matrix (gtk4-captures/, synthetic 12-page 3-chapter PDF)

| Test | Result | Capture |
|---|---|---|
| Launch, first paint, sidebar chapters, minimap | PASS | 00, 01 |
| Page-entry navigation (Ctrl+L), chapter follow | PASS | 02 |
| Anchored zoom in, reset | PASS | 03 |
| Mixed-size landscape page layout | PASS | 04 |
| End/Home scroll, minimap tracks | PASS | 05 |
| Fit page / fit width | PASS | 06, 07 |
| Type-anywhere search bar + counter + Results pane | PASS* | 10 |
| Find next/prev | PASS | 11 |
| Regex query entry | PASS | 12 |
| Escape clears search | PASS | 13 |
| Chapter-grouped results sidebar | PASS | 14 |
| Sidebar chapters pane | PASS | 20 |
| Command palette: sections, fuzzy commands + accels, recents, cross-doc search | PASS | 21, 22 |
| Properties panel (Ctrl+I) | PASS | 23 |
| Presentation mode (F5) | PASS | 24 |
| Tab overview | PASS | 25 |
| Shortcuts cheat sheet (F1) | PASS | 26 |

\* Known issue: one keystroke can be lost while the search bar reveals (typed
"connector", entry got "cnnector") — the type-anywhere prefill focuses the
entry asynchronously and a fast second keystroke races it. Fix: buffer
window-level keys until the entry has focus. Low severity, logged.
**RESOLVED 2026-07-22 in two stages:** the bubble-phase append (45bd9d6ee)
was not enough — GNOME's ibus IM consumes-and-drops keys during the entry's
async focus-in, so they never bubble. A 500 ms capture-phase takeover after
a type-anywhere reveal now commits printable keys straight into the query
(62c11bd3b). Verified 5/5 clean "connector" runs at 30–80 ms per key.

## 2026-07-22 follow-up session (release-notes parity closure)

All gaps from the release-notes audit closed, each verified with live
XTEST captures on the built binary unless noted:

- **Minimap viewport width vs zoom** (user report): the indicator kept the
  GTK3 full-width band at every zoom. Now ports the Mac
  `unscrolledVisibleRectForScale` union-of-page-intersections model — zoom
  in and the indicator narrows/tracks horizontally. Verified: 115 px →
  63 px at 195 % on a captured run; unit tests cover narrow + fallback.
- **Enter mid-search on a large document** (45bd9d6ee, was unverified):
  400-page probe shows 2395/4799 (nearest match) immediately after Enter
  and unchanged after the final result batch.
- **Palette (26.7.9 headliners)**: Open Documents section first (deduped
  against favorites, current tab excluded), "fav" prefix lists favorites,
  every command row carries a menu-breadcrumb subtitle + toggle state, and
  menu names are searchable. New `win.search-nearest` toggle exposes
  `searchJumpsToNearestResult`. Verified in a two-document capture.
- **Cursor regions (26.7.17)**: plain-text URLs get the hand cursor;
  rects built off-main with `detect_text_links=1` (Mac @11269 model),
  generation-invalidated. Unit-tested (priority/slop/merge); live hover
  needs a manual pass.
- **Minimap (26.7.17)**: strip-scroll kinetic momentum
  (`::decelerate` + frame clock, GtkKineticScrolling decay), Ctrl+scroll
  forwards to the docview zoom anchored at the strip point (verified live:
  100 % → 121 % on two notches over the strip). Momentum needs a touchpad
  flick to feel-check (wheel notches never emit decelerate, same as Mac).
- **Read-only dot (26.6.27-2)**: fixed systemOrange #FF9500 PNG icon
  replaces the theme-recolored symbolic (verified in capture, dark theme).
  Bonus fix found while verifying: shadow-copy tabs no longer show the
  `ro-<hash>` working-copy basename as their title.

## 2026-07-23 session (fresh-install UI report: shell chrome + sidebar)

A user pass on the freshly installed 26.7.22 deb surfaced shell-level gaps
that never showed in the earlier single-focus captures. All fixed and
verified live (X11 captures on the dev build); 182 unit checks stay green.

- **No tab row with one document**: AdwTabBar autohides by default until a
  second tab opens; the Mac strip is always visible. `autohide = FALSE`.
- **Zoomed pages painted over the sidebar** (user screenshot): the docview
  is a custom GtkScrollable that draws page textures translated by the
  scroll offset, and GTK4 widgets default to `GTK_OVERFLOW_VISIBLE` — at
  zoom > fit the canvas painted left of its allocation, across the panel.
  `gtk_widget_set_overflow(GTK_OVERFLOW_HIDDEN)` in init (what GtkViewport
  does). Verified at 161%: the page clips exactly at the pane edge.
- **Page↔tab link race (root cause of two symptoms)**: AdwTabView emits
  `page-attached` + `notify::selected-page` synchronously INSIDE
  `adw_tab_view_append`, i.e. before spdf_tab.c could attach the
  "spdf-tab" object data to the page. `tab_for_page()` returned NULL, so
  (a) the window never connected `page-changed`/`zoom-changed` for any
  freshly opened tab — the header page entry sat stale through scrolling
  and chapter jumps — and (b) `win.minimap` stayed disabled for the first
  tab (grey toggle → the report "no hide minimap option").
  `spdf_window_tab_linked()` (called right after the data is set) re-runs
  the attach hookup + minimap sync; cannot double-connect since the
  NULL-tab run connected nothing.
- **Hamburger menu had no View section**: added Zoom submenu (Fit
  Page/Width/Height, Actual Size) and stateful check items for Show Side
  Panel / Show Minimap / Presentation Mode.
- **Mac toolbar parity**: fit-mode dropdown (100% / Fit Width / Fit
  Height / Fit Page; label mirrors the tab's fit, "Zoom" when custom) and
  prev/next page-step buttons beside the page entry. `SPDF_FIT_HEIGHT` is
  new end-to-end: fit zoom + margin rules, session schema id 3 (was
  approximated to Fit Page on restore), Ctrl+3.
- **Sidebar filter (Mac `_sidebarFilterField`)**: search entry under the
  pane switcher; chapters filter to a flat matching list (Mac filters the
  flattened table), comments filter via list-box filter func; placeholder
  swaps Chapters/Comments; hidden on the Results pane (it has its own
  query). Matching = casefolded substring (`spdf_sidebar_filter_matches`).
- **Sidebar dead click** (user report): jumps hung off `notify::selected`,
  so clicking the row that follow-page had ALREADY selected did nothing —
  "click the chapter I'm in to return to its start" was dead. Chapters and
  results lists now single-click-activate and jump from the `activate`
  signal too (Mac `activateSidebarRow` semantics).
- **Window icon**: never set → decoration layouts that render the window
  icon showed the broken-image glyph (user screenshot, flatpak).
  `gtk_window_set_default_icon_name(FLATPAK_ID || "shenzhenpdf")`.
- Deliberately NOT ported (Adw conventions, documented divergence):
  OCR/Translate toolbar icon buttons (hamburger menu + palette cover
  them), the inline Find field + Regex checkbox (GTK search bar has
  its own regex/multiline toggles).

## Known issues / needs live verification

1. ~~Search-bar reveal keystroke race~~ — fixed + capture-verified above.
2. pkexec flows (updater install, OCR toolchain install) need a real
   interactive auth dialog — not testable headless.
3. Printing verified by unit tests + dialog code paths; needs a real CUPS
   queue for paper output.
4. OCR/translation end-to-end need ocrmypdf/argos installed; ported logic is
   test-covered, subprocess seams verified with fixtures.
5. Updater end-to-end needs the first release that ships
   `ShenzhenPDF-linux-amd64.{deb,tar.gz}` + `.minisig` (cut-linux-assets.sh).
6. Giant-sheet (10900 pt schematic) behavior ported with regression tests;
   worth one manual session on the real power-tree PDF from the June VM run.
7. Cold-path present (~450 ms of process warmup) could shrink further by
   moving warmup earlier for non-resident users; resident mode makes it moot.
8. Minimap kinetic momentum: touchpad flick feel-check (direction assumed
   from the GtkScrolledWindow decelerate convention).
9. Plain-text URL hover: one manual hover+click on a PDF with a bare URL.

## GTK3 retirement

`ShenzhenPDFGtk.c` / `ShenzhenPDFGtkDisplay.{c,h}` and the `linux` Makefile
target are deleted in this branch's final commit; `portable/linux/gtk4/` is
the Linux frontend. The GTK3 file remains in git history and is cited by
provenance comments throughout the GTK4 modules.
