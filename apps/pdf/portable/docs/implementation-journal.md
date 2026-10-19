# Implementation Journal

Date: 2026-06-03

Scope: prompt-linked implementation journal for the current working tree. This records what was changed, what was tested, and what is still not complete.

## Original Prompt Tracker

1. Refactor the 10k-line `.mm` file and keep an eagle view of oversized files.
   - Status: Partially complete, not done.
   - Changed: extracted Mac models, tab strip, document view, minimap, print view, and shortcut-help delegate behavior into dedicated files under `portable/mac/`.
   - Current line counts: `portable/mac/ShenzhenPDFMac.mm` is 8,502 lines; extracted Mac files are 99-749 lines except `SPDFMacMinimapView.mm` at 604 lines and `SPDFMacDocumentView.mm` at 578 lines, plus `SPDFMacDelegatePrivate.h` at 357 lines and `ShenzhenMacDelegate+ShortcutHelp.mm` at 234 lines. `portable/linux/ShenzhenPDFGtk.c` is 9,130 lines after one helper extraction.
   - Gap: the Mac and Linux monoliths are still too large. Next refactors should split session/window lifecycle, rendering/cache orchestration, palette/favorites, sidebar/comments, and Linux minimap/session code.

2. Closing the last document in a non-last window should close that window, not show “no file loaded.”
   - Status: Implemented for the current Mac multi-process window architecture; manual multi-Space QA still needed.
   - Changed: `closeTabAtIndex:` removes the current session window and terminates only this process when another Shenzhen window/process exists. The empty view remains only when no other Shenzhen window exists.
   - Gap: restored windows still use separate processes; true single-process multi-window restore remains a larger architecture task.

3. Duplicate same-name tabs should add enough path context and collapse repeated folders with `...`.
   - Status: Implemented for Mac, Linux, and Windows.
   - Changed: Mac `spdf_disambiguated_display_names_for_paths`, Linux `spdf_gtk_disambiguated_tab_title`, Windows `DisplayTabTitleTemp`.
   - Tested: Mac and Linux runtime checks for `/root/documents/folder1/folder2/test.pdf` and `/root/invoices/folder1/folder2/test.pdf` returned `documents/.../test` and `invoices/.../test`.

4. Add Shift+Cmd/Ctrl+F presentation shortcut.
   - Status: Implemented for Mac, Linux, and Windows.
   - Changed: Mac adds `Cmd+Shift+F`, Linux/Windows add `Ctrl+Shift+F`; F5 remains.
   - Tested: build/syntax coverage only. Runtime shortcut QA still needed on all platforms.

5. Presentation mode should launch when already fullscreen on Mac.
   - Status: Implemented in Mac source; manual fullscreen QA still needed.
   - Changed: native fullscreen and presentation are separated, and presentation chrome avoids breaking when already in fullscreen.

6. Long landscape PDFs over 20 pages should use simpler speed-based minimap/scroll behavior.
   - Status: Implemented for Mac and Linux minimap dragging; manual large-PDF QA still needed.
   - Changed: long-document drag now scales by document length and pointer speed rather than the old catch-up blend.
   - Changed: fixed the long-document precision-drag regression by preserving horizontal viewport dragging on Mac and Linux, stabilizing the long-document minimap thumb near the bottom, and deferring heavy Mac page/session updates until mouse-up.
   - Changed: Linux precision drag now matches the prompt wording and Mac behavior by activating only for documents with more than 20 pages.
   - Changed: fixed the follow-up minimap overlay regression by drawing the real viewport/page-intersection rectangle again while keeping the stabilized long-document drag math internal.
   - Changed: tuned the long-document drag acceleration curve on Mac and Linux to keep fine adjustment below 180 px/s unchanged while reaching 1:1 speed at 560 px/s instead of 900 px/s.
   - Changed: fixed the follow-up non-continuous regression: Mac single-page mode sizes to the current page instead of the continuous document, so page 1 centers like later pages; Mac minimap uses synthetic full-document coordinates so only the current page's visible slice is highlighted; Linux single-page mode now vertically centers the page box outside continuous mode.
   - Changed: fixed the follow-up block-diagram non-continuous page-change regression by making single-page visible-page detection return the current page instead of re-scanning overlapping single-page rects; fixed minimap churn while zooming by suppressing thumbnail render queueing during live zoom and rendering once after zoom settles.
   - Changed: fixed the follow-up Mac single-page scrollbar regression: non-continuous mode again exposes a vertical scrollbar backed by synthetic whole-document height; scrollbar-origin changes now snap straight to page positions so the current page remains centered instead of pixel-scrolling vertically.
   - Tested: installed `/Applications/ShenzhenPDF.app`, cleaned app JSON state with a timestamped backup, opened the Sample Datasheet PDF, switched to Single Page with Cmd+4, dragged the document scrollbar from page 2 to page 20, and verified the page jumped directly while remaining centered; Cmd+5 still returns to Continuous mode.
   - Changed: made Fit Page the default zoom for fresh Mac, Linux, and Windows/Sumatra startup state; made long-document minimap viewport dragging more aggressive by keeping fine adjustment at 180 px/s but reaching 1:1 speed at 300 px/s instead of 560 px/s.
   - Tested: built and installed the Mac app, backed up and cleaned app JSON state, opened the Sample Datasheet PDF from a fresh state, and verified both Zoom and View menus mark Fit Page by default; built the Linux GTK target successfully; attempted the Windows build on macOS and it failed because VS 2026/msbuild.exe is unavailable in this shell.
   - Changed: ensured fresh Mac tabs opened through Finder/external-open paths start in Fit Page instead of inheriting the active tab's current zoom.
   - Changed: restored the Mac toolbar zoom popup's dynamic custom-zoom row: a remembered non-100% zoom appears above the fixed 100% row and remains available after choosing Fit Page, Fit Width, or Fit Height.
   - Changed: added a Mac tab right-click menu with Show in Folder and Copy; Copy places the tab's file URL on the pasteboard so Finder-style paste copies the PDF file.
   - Tested: rebuilt and installed `/Applications/ShenzhenPDF.app`; user confirmed the custom zoom popup behavior works in the installed app.
   - Changed: stopped the Mac minimap from queuing high-priority full-resolution page renders for minimap-visible placeholders; the minimap now reuses document-view pages when available and fills visible map pages through a separate low-resolution utility thumbnail queue, so the right rail does not stay as blank placeholders and does not block main-page rendering.
   - Changed: routed right-click tab events through the custom titlebar event bridge so the tab context menu appears reliably in the titlebar tab strip.
   - Tested: rebuilt and installed `/Applications/ShenzhenPDF.app`; confirmed there is still exactly one ShenzhenPDF app in `/Applications`; built the Linux GTK target successfully and verified GTK minimap already uses placeholder drawing rather than minimap-triggered full-size renders.

7. Opening a PDF from Finder while the app is in another workspace should switch to the app.
   - Status: Implemented in Mac source; manual Spaces QA still needed.
   - Changed: external open handlers activate/order the target window after opening files.

8. Relaunching should restore split windows promptly in one workspace.
   - Status: Partially treated, not solved.
   - Changed: closing a window removes only that window’s session and suppresses stale rewrite-on-terminate.
   - Changed: direct launch restores stored tabs, and launching with an explicit PDF now restores remembered tabs first, then adds/selects the clicked PDF. Empty windows and tabs without paths are pruned from `session.json`.
   - Changed: external PDF opens are validated before adding tabs, so a corrupt clicked PDF cannot erase or pollute a good previous session.
   - Changed: closing the last app window now saves its tabs before quitting; only non-last windows remove themselves from the stored session.
   - Tested: backed up and cleaned `~/Library/Application Support/ShenzhenPDF/*.json`, then verified clean direct launch, restore-after-quit, cold Finder-style PDF launch restoring Sample Datasheet plus adding the clicked PDF, empty first-window pruning, corrupt external-open preservation, already-running Finder-open adding to the visible restored session, and red-window-close preserving the last window's documents.
   - Gap: session restore still spawns restored windows as separate processes with `--restore-window`. A full fix should migrate to one-process multi-window controllers.

9. Support default Mac move/resize window shortcuts.
   - Status: Implemented in Mac source; installed-app menu shortcut QA still needed.
   - Changed: the main Mac window now remains movable outside presentation/fullscreen mode, which lets AppKit enable its native Fill, Center, Move & Resize, Full Screen Tile, quarter, arrange, display, and default shortcut handling.
   - Changed: tab-strip and toolbar drag paths now restore the movable state instead of leaving the window non-movable after interaction.
   - Changed: removed the duplicate custom Window-menu Fill/Center/Move & Resize shortcut entries so they no longer conflict with macOS' native Window menu.
   - Changed: added a green-button fullscreen fallback for Control+Fn/Globe+F/C/arrow arrangement shortcuts: the app exits native fullscreen, waits for AppKit's exit callback, then applies the requested Fill, Center, or half-screen frame.
   - Changed: mirrored Fill, Center, and half-window actions under View > Move & Resize Window so they are visible from the menu the user checked.

10. Improve Mac print quality to high DPI.
   - Status: Implemented in Mac source; print-to-PDF visual QA still needed.
   - Changed: PDF files now use PDFKit's native document print operation first, so the original PDF page content is passed to the macOS printing pipeline instead of being pre-rasterized by the app.
   - Changed: PDF print permissions are respected before printing; fallback raster printing remains for non-PDF formats and PDFKit failure cases.
   - Changed: printing now uses `SPDFPrintView` to render pages directly from `spdf_document` at a 1200 DPI target with fallback to lower render zoom and then cached pages.

11. Install and prepare for TestFlight.
   - Status: Local user install completed; TestFlight signing is blocked by missing Apple assets.
   - Installed: `/Applications/ShenzhenPDF.app`.
   - Changed: removed the Mac document-type icon override so Finder/Quick Look can show PDF document previews instead of forcing the Shenzhen PDF app logo on every registered PDF/XPS/CBZ/EPUB file.
   - Changed: set the canonical bundle/app id to `com.intuition.shenzhenpdf`, switched macOS defaults to date-style version `26.6.4-1`, updated TestFlight docs/scripts/package naming, removed the copyright line from the bundle metadata, and added About-panel publisher copy: "Shenzhen PDF is an Open Source app in the spirit of Sumatra PDF, created by Raphaël Casimir, published by Intuition R&T."
   - Gap: TestFlight readiness fails for missing Apple Distribution certificate, 3rd Party Mac Developer Installer certificate, provisioning profile, and Transporter.

12. Tab switching/loading should not reload every PDF on every tab change.
   - Status: Implemented for Mac and Linux; Windows audited as already using persistent per-tab controllers.
   - Changed: Mac tabs now keep resident document/render caches with file mtime/size validation, reuse cached tabs on selection, avoid canceling all inactive preload work on tab switch, and move outline/comment loading off the tab-switch path into cached background work.
   - Changed: Mac inactive preloading is multi-threaded but capped to at most two utility operations, publishes a reusable geometry/document cache before preferred-page rastering, and checks file attributes before reusing the cache.
   - Changed: Linux parks/restores per-tab documents with mtime/size validation so tab selection does not reopen the document when unchanged.
   - Gap: manual stress QA is still needed on many-tab sessions and on Windows because this macOS machine cannot run the Windows app.

13. First launch should feel instant, and tab hover titles must not stick.
   - Status: First low-risk optimization round implemented for Mac and Linux; deeper async first-page rendering remains future work.
   - Plan: paint the Mac window shell before document/session restore, coalesce state writes during startup/open bursts, avoid activating helper restore windows, hide tab hover panels from lifecycle paths that can bypass mouse tracking, and defer Linux sidebar metadata scans out of the attach path.
   - Changed: Mac startup document/session work now runs one main-queue turn after the window is ordered, so the shell can paint before MuPDF open/render starts.
   - Changed: Mac `openPaths` and startup restore batch persistent-state saves, collapsing repeated synchronous JSON/session writes into one final write.
   - Changed: Mac restored helper windows no longer force app activation on launch.
   - Changed: Mac tab hover panels are dismissed when the tab strip is hidden/detached, app/window focus changes, the window resizes/miniaturizes/fullscreens, presentation chrome hides tabs, or tab-strip events become window chrome actions.
   - Changed: Mac minimap thumbnails now render on a separate utility queue so launch/tab-switch visible-page renders are not blocked by the map filling itself.
   - Changed: Mac long-document minimap dragging now explicitly queues high-priority renders for the pages visible in the main viewport while the mouse is still down, forces a tracking-loop repaint, and draws available minimap thumbnails as temporary page previews until full-resolution renders arrive.
   - Changed: Mac now estimates full rendered-page memory at the current zoom; cheap views such as the sample catalogue at 37% Retina (~2.08 MB/page, ~244 MB total) and Sample Datasheet at 37% Retina (~1.08 MB/page, ~38 MB total) pre-render and keep the whole document warm, while expensive zooms such as the sample catalogue at 100% Retina (~15.2 MB/page, ~1.78 GB total) keep the bounded cache.
   - Changed: Mac oversized high-zoom pages no longer open a blocking "Rendered page would be too large" alert. Whole-page rastering is skipped when the bitmap would exceed the render guard, and the main viewport renders a full-resolution cropped page region instead.
   - Changed: Mac scroll/minimap-drag/zoom paths render those oversized viewport crops while the mouse is still down, and distant crop images are counted in the render cache so moving through a giant page does not keep unbounded bitmaps.
   - Changed: Mac document panning now suppresses high-resolution oversized crop rerenders during drag/inertia and refreshes the crop once the pan motion settles, fixing max-zoom drag FPS without dropping the final full-resolution viewport.
   - Changed: Mac max-zoom document panning now renders throttled 1x viewport crops during pan/inertia, then refreshes the full backing-scale crop when motion settles; document pan and inertia scrolls explicitly notify the reader, and both single-page and continuous scroll paths call the live crop renderer while pan is active.
   - Changed: Mac live zoom/unzoom now scales the previous high-quality viewport crop instead of falling back to the minimap thumbnail; live zoom no longer performs synchronous crop rendering or full scroll-change normalization on each gesture tick, leaving target-quality rendering until the gesture settles.
   - Changed: Mac tab/document switches now cancel active document pan inertia so motion from one tab cannot carry into the next tab.
   - Changed: Mac empty tab-strip chrome plus passive toolbar labels/spacer support first-click window drag, while toolbar controls and tabs keep normal click/drag handling.
   - Changed: Mac document and minimap interactions now explicitly activate their owning window on first-click drag, so dragging an inactive document or minimap both works immediately and focuses the app.
   - Changed: Mac toolbar page controls now place previous/next to the right of the page field/count, zoom controls now place -/+ to the right of the zoom popup, and zoom overflow keeps the popup plus +/- together.
   - Changed: Mac zoom popup keeps the 100% entry anchored and inserts the custom zoom value after it when distinct, preserving the quick return-to-custom behavior without hiding 100%.
   - Changed: Mac tab strip now captures the whole tab-strip mouse sequence and disables native window movement only while a tab/control mouse sequence is active; passive toolbar drag views temporarily opt into window dragging, protecting tab reorder and drag-out gestures while keeping native window arrangement available.
   - Changed: Mac empty space in the tab row explicitly drags the window again, while expanded tab/control hit zones keep tab reordering and drag-out from being mistaken for window drag.
   - Changed: Mac tab state now writes the latest normalized scroll origin before saving document state JSON.
   - Changed: Mac render queue concurrency now follows the earlier 60% CPU cap, and minimap-drag visible pages promote already-queued background operations instead of waiting behind older low-priority renders.
   - Changed: Mac live zoom no longer runs a synchronous full-document render from the zoom-finish timer; it cancels stale queued page/minimap work when a zoom gesture starts, prevents old-zoom render operations from applying after the zoom changes, suppresses full minimap rebuilds while live zoom is active, and queues visible pages once zoom settles. The user validated that this fixed the reported quick zoom-in then zoom-out input-loss regression.
   - Changed: Mac tab selection no longer saves persistent/session state between switching `_path` to the target tab and restoring that tab's own scroll origin. State is saved after cached and cold tab loads apply the tab's saved viewport, preventing the previous document's clip-view origin from being written into the newly selected tab. The same fix preserves explicit `hasScrollOrigin=false` session entries, suppresses fresh-load viewport relayout until the target tab's origin is restored, and cancels pending live-zoom settle timers when switching/closing documents. The user validated that document positions no longer appear to cross-affect each other.
   - Changed: Mac windows are movable again in their resting state so AppKit can enable native Fill, Center, Move & Resize, Full Screen Tile, and their default shortcuts; tab-strip gestures still force `movable` off until mouse-up so tab reordering and drag-out stay protected. The user validated that window-management shortcuts work again.
   - Changed: Mac high-zoom live zoom now skips no-op ticks at the zoom cap before doing anchor/geometry work, uses a lightweight resize path during the gesture instead of retile/layout/minimap/find invalidation on every wheel tick, suppresses scroll callbacks while preserving the zoom anchor, throttles toolbar refreshes, and repaints only the current viewport. `SPDFDocumentView` also fills only the dirty rectangle instead of the full enormous high-zoom document bounds. When live zoom settles, the app now renders the visible viewport crop synchronously before queueing full/nearby page renders, so the visible document crisps up immediately instead of waiting behind background work. The user validated that high-zoom zooming is responsive again and no longer stays blurry after settling.
   - Changed: Linux `attach_document_to_view` always schedules the existing deferred sidebar metadata load instead of synchronously loading outline/comments before tab-switch paint.
   - TODO: investigate rare Mac tab switches where restored document position appears influenced by the previous tab's viewport even after the scroll-origin save-order fix.
   - Gap: next performance round should move Mac and Linux first-page rastering off the launch/tab-switch foreground path and build exact long-document geometry lazily.

14. Prepare `26.6.4-2` launch-performance round without behavior changes.
   - Status: First strict behavior-preserving Mac reductions implemented.
   - Constraint: no visual or behavioral changes. Do not change render/loading resolution, first visible document quality, restored documents/tabs, active tab selection, scroll position, sidebar/minimap semantics, or file/session persistence semantics.
   - Process: reread this journal before decisions; collect read-only agent reports first; classify options as safe/medium/risky; implement only safe changes that remove redundant blocking work or move already-deferred work later without changing user-visible output.
   - Candidate-safe areas to investigate: redundant synchronous state writes during startup/open, work duplicated between startup restore and tab selection, avoidable post-first-paint background scheduling before the first window visibly settles, and cross-platform equivalents that preserve exact visual behavior.
   - Changed: `SPDFDocumentView` now caches exact snapped page sizes, widest-page width, continuous page rectangles, continuous document height, and synthetic single-page slots. The cache is invalidated on pages, zoom, view mode, presentation mode, backing scale, viewport width, and view bounds; live single-page centering still reads the current clip-view bounds.
   - Changed: `SPDFMinimapView` now caches the exact unscrolled mini page rectangles for the current pages, bounds width, scale, and gap. Minimap overlay, drag, hit-test, and click math continue to use the same geometry formulas.
   - Changed: identical delayed nearby-render schedules for the same delegate, generation, path, and preferred page are coalesced until the delayed request fires; page render order, priority, resolution, and eventual queueing stay unchanged.
   - Changed: max-zoom document panning no longer renders live viewport crops synchronously on the main drag path. A single generation-guarded utility background crop job updates the preview when ready, stale crop jobs are ignored across new pans/tabs/zooms, live-zoom settle re-arms itself while a pan is active instead of running final layout/render work mid-drag, and image cache eviction is deferred until pan finish.
   - Tested: ran explicit ObjC-style clang-format on touched Mac `.mm` edits, `git diff --check`, ObjC++ syntax for `SPDFMacDocumentView.mm`, `SPDFMacMinimapView.mm`, and `ShenzhenPDFMac.mm`, `make -C portable mac-app`, and `./dist/ShenzhenPDF.app/Contents/MacOS/ShenzhenPDF --version`.

15. First-launch default PDF reader prompt and print scaling controls.
   - Status: Implemented for Mac; pending manual validation before commit.
   - Changed: added a first-launch prompt to make Shenzhen PDF the default PDF reader, persisted dismissal in `settings.json`, and added a File menu command to retrigger the same flow at any time.
   - Changed: added LaunchServices default-reader helpers using the app bundle id and the PDF UTI.
   - Changed: added print scaling controls as an accessory inside the macOS print panel itself, so the user sees Shenzhen PDF scaling next to the normal printer options and the panel's real page preview. PDF printing uses a PDFKit page-drawing print view for fit, actual-size, and custom scaling; non-PDF/fallback printing keeps the 1200 DPI bitmap renderer and now honors the same scaling modes.
   - Changed: enabled the system Paper Size and Orientation controls in the macOS print panel. The options are seeded by AppKit from the selected/default printer, and the Shenzhen PDF print views resize their page frame from the current `NSPrintInfo` so the real preview/output follows the selected target sheet.
   - Constraint: bitmap output remains fallback-only for PDF printing unless PDFKit/native printing cannot be used.
   - Tested: ran explicit ObjC-style clang-format on touched Mac files, `git diff --check`, `make -C portable mac-app`, `make -C portable install`, `/Applications/ShenzhenPDF.app/Contents/MacOS/ShenzhenPDF --version`, installed app codesign verification, `/Applications` uniqueness check, and `make -C portable linux`.

16. Prepare `26.6.5-1` for TestFlight validation.
   - Status: Implemented; commit and tag requested by user.
   - Changed: bumped macOS bundle defaults to App Store-compatible `CFBundleShortVersionString=26.6.5` and `CFBundleVersion=1`, with About/CLI display as `26.6.5-1`.
   - Changed: updated TestFlight build defaults and handoff docs to produce `ShenzhenPDF-testflight-26.6.5-1.pkg`.
   - Tested: rebuilt and installed `/Applications/ShenzhenPDF.app`; verified CLI version `26.6.5-1`, bundle short version `26.6.5`, bundle build `1`, bundle id `com.intuition.shenzhenpdf`, codesign, `/Applications` uniqueness, `git diff --check`, and Linux build. TestFlight readiness has build tools/OpenSSL/MuPDF OK and still requires Apple Distribution certificate, 3rd Party Mac Developer Installer certificate, provisioning profile, and optionally Transporter.

17. Command palette result display and tab-strip drag regression.
   - Status: Implemented; pending manual validation before amending the `26.6.5-1` commit.
   - Changed: open-document text-search results now show `<tab title> - page x : y matches` on the first line, with only the tab title bolded, and keep the second line as compact context snippets with bolded matches.
   - Changed: Mac tab gestures now use an expanded interaction rect across the tab row height for each visible tab, and the window is non-movable in its resting state so AppKit cannot steal tab gestures as titlebar drags. True empty tab-row space and passive chrome still perform explicit temporary window drags.
   - Changed: Mac app-owned Window menu arrangement entries and Ctrl+Fn Fill/Center/Half shortcuts now work in normal windows as well as fullscreen; the Window menu temporarily enables window movability while open so macOS can still validate its own native arrangement items, then restores the non-movable resting state when closed.
   - Changed: Mac single-page mode now treats left-drag as document panning. Pages that fit vertically remain centered and vertical drag/page scroll changes pages; zoomed pages taller than the viewport keep a stable page rect and clamp inside the page so dragging moves through the enlarged document instead of snapping back to center.
   - Changed: Mac active document panning now keeps gesture ticks lightweight by repainting the viewport immediately while coalescing minimap updates and live crop rendering behind one scheduled maintenance callback. Final full-resolution crop rendering still runs when pan motion finishes.
   - Changed: Mac single-page/non-continuous drag now disables release inertia entirely so slides do not vibrate after the user lets go.
   - Changed: Mac scroll-wheel page changes now ignore Command, Control, and Option modified events, while modified wheel zoom events are consumed by the scroll view and immediate post-zoom phase/momentum or very-near follow-up wheel ticks are dropped so zoom gestures cannot also flip/scroll pages.
   - Changed: Mac live zoom now keeps one stable page anchor for the duration of the wheel/magnify gesture, preventing continuous-mode zoom ticks from drifting the document slightly downward.
   - Constraint: do not commit/amend until the user manually validates the tab detach/window-drag behavior.

18. `26.6.5-2` launch should be static and faster without visual compromise.
   - Status: Implementation started; commit step by step after each validated slice.
   - Constraint: preserve first visible document quality, restored tabs, restored position, sidebar/minimap semantics, tab order, and Finder/session behavior. No low-resolution first paint or visible layout mutation as a launch shortcut.
   - Changed: Mac startup document/session work now runs before the main window is ordered, so the first visible frame already has the selected tab, document, sidebar, minimap, and restored scroll state applied. Default-reader and shortcut-help prompts remain deferred until after the window is visible.
   - Changed: added a core page-size cache seeding API and a Mac exact page-geometry cache in `documents.json`. After a document has completed exact all-page layout once, later launches/openings validate file size, modified date, page count, and all page dimensions before seeding MuPDF's in-memory page-size cache, avoiding synchronous load/bounds of every page while preserving exact layout.
   - Changed: Mac launch now loads the selected document's outline/comments before ordering the first window when the sidebar is meant to be visible, so the left panel does not collapse or appear after the first visible frame. Normal tab switching keeps the deferred metadata path.
   - Changed: Mac single-page/non-continuous live zoom now preserves the active page and live-zoom anchor through the final resize pass, suppressing synthetic scrollbar callbacks so Command-scroll zoom cannot be interpreted as a page-changing scroll.
   - Changed: Mac continuous-mode live zoom now uses a centered page anchor when the current page is fully visible, avoiding the slight downward scroll drift while zooming/unzooming at fit-page-like sizes. Mac single-page drag/page-turn detection now uses an explicit one-third-viewport threshold instead of waiting for the synthetic page slot overlap to dominate.
   - Next: validate launch behavior on restored/recent long PDFs, then consider diagnostics and deeper post-first-paint staging if Preview is still noticeably ahead.

19. Prepare `26.6.7-1` for TestFlight validation.
   - Status: Implemented; commit and tag requested by user.
   - Changed: bumped macOS bundle defaults to App Store-compatible `CFBundleShortVersionString=26.6.7` and `CFBundleVersion=1`, with About/CLI display as `26.6.7-1`.
   - Changed: updated TestFlight build defaults and handoff docs to produce `ShenzhenPDF-testflight-26.6.7-1.pkg`.
   - Constraint: keep previous release journal entries historically intact; only current build defaults and handoff references move to today's version.
   - Tested: ran ObjC-style clang-format on the touched Mac fallback lines, `git diff --check`, `make -C portable mac-app`, `make -C portable install`, installed CLI version check, installed bundle id/short-version/build checks, installed app codesign verification, `/Applications` app-name check, `./portable/check-testflight-ready.sh`, `make -C portable linux`, and `portable/build/ShenzhenPDF-gtk --version`.
   - Gap: TestFlight readiness still requires the Apple Distribution certificate, 3rd Party Mac Developer Installer certificate, App Store provisioning profile, and optionally Transporter. A hidden root-owned `/Applications/.ShenzhenPDF.app.old-20260603-122602` backup could not be removed by the unprivileged cleanup command; `/Applications/ShenzhenPDF.app` is the current installed app.

20. Non-continuous drag/page-turn state cleanup.
   - Status: User validated; committed in `167c0bce0`.
   - Agent findings: stale single-page pan baselines could survive a page snap, wheel-page accumulators could carry sub-threshold deltas or momentum across gestures, pinch zoom did not clear wheel page-turn state, and pending live-zoom timers could restore pre-navigation anchors.
   - Changed: rebase single-page mouse-drag state after a drag-induced page snap, turn wheel page changes into one-shot gestures that ignore momentum and reset on begin/end/direction/timeout, clear wheel state for pinch zoom, cancel pending live-zoom completion before page navigation or document panning, defer single-page snap-back until pan release unless a page actually changed, and restore continuous-mode left-drag entry into document panning when the document has scrollable content.
   - Validation target: in non-continuous mode, dragging beyond the threshold should move exactly one slide per drag segment, release should have no inertia/vibration, Cmd/Ctrl zoom should not queue page changes, and dragging immediately after zoom should not feel blocked.

21. Default PDF reader double-click regression.
   - Status: Implemented and committed in `167c0bce0`; direct double-click behavior remains a manual Finder validation item.
   - Root cause: the previous default-reader helper only set LaunchServices' PDF viewer role. Finder's Get Info showed Shenzhen PDF, but the all/editor role used by double-click could remain `com.apple.Preview`.
   - Changed: declare PDF as its own explicit `com.adobe.pdf` document type, set viewer/editor/all roles through LaunchServices, and fall back to repairing the user's `LSHandlers` row plus refreshing `lsd` when macOS returns success but leaves Preview in the all-role slot.
   - Tested: reproduced the broken `viewer=Shenzhen, all/editor=Preview` state, ran the helper harness, verified a fresh LaunchServices query reports viewer/editor/all as `com.intuition.shenzhenpdf`, rebuilt/installed `/Applications/ShenzhenPDF.app`, and confirmed `open /Users/raph/Downloads/sample-datasheet.pdf` opens Shenzhen PDF without launching Preview.app.

22. GNOME-style document search sidebar.
   - Status: User validated; included in the `26.6.8-1` release commit.
   - Prompt link: when the user searches, a new sidebar tab like Chapters/Comments should appear, switch to immediately, list contextual search results, and insert visually distinct chapter separators.
   - Agent findings: product acceptance criteria require current-document-only results, exact-match jumps, non-clickable divider/status rows, result selection syncing with next/previous find navigation, graceful no-result/searching states, and no stale rows after clearing or switching documents.
   - Changed: Mac sidebar mode now dynamically adds a Search segment only while search state exists, opens/switches the sidebar when a query starts, builds result rows from `_findMatches` with page/match subtitles and extracted text snippets, groups results under chapter dividers, keeps Search selection synced to `_findMatchIndex`, and routes result clicks through `jumpToFindMatchAtIndex:`.
   - Review fixes: changed divider rows to adaptive left-aligned muted capsule chapter labels that only draw a right-side rule when there is meaningful leftover space, made status/divider rows non-navigable, dynamically clamps sidebar width so three segments fit, keeps result rows single-line truncated instead of wrapped, and bolds literal query matches in result context text.
   - Validation target: type a search, confirm Search appears and is selected, results show useful single-line snippets grouped by chapter, clicking a result jumps and flashes the exact match, next/previous updates the selected result, no-result/searching rows do not navigate, and clearing search removes Search without breaking Chapters/Comments.

23. Mac window arrangement shortcut regression.
   - Status: User validated; included in the `26.6.8-1` release commit.
   - Prompt link: the Window/View menu actions still work, but their keyboard shortcuts regressed, so the keyboard dispatch path needs a test and fix.
   - Changed: extracted Mac window-arrangement shortcut matching into `SPDFMacWindowShortcuts`, installed a local key monitor so Ctrl+Fn/Globe window shortcuts are handled before AppKit menu-key dispatch can swallow them, accepts missing Fn/NumericPad flags as a fallback outside text editing, and kept the existing `SPDFWindow` send-event fallback.
   - Changed: added `make -C portable mac-window-shortcut-tests`, covering Ctrl+Fn/Globe Fill/Center, Ctrl+Fn/Globe arrows, Fn-arrow translations to Home/End/PageUp/PageDown, AppKit numeric-pad arrow events, missing-flag fallback events, selector routing, and modified-key rejection.
   - Validation target: with the installed app focused, Ctrl+Fn/Globe+F fills, Ctrl+Fn/Globe+C centers, Ctrl+Fn/Globe+Left/Right/Up/Down move to halves, and clicking the menu items continues to work.

24. Mac window resize smoothness and corner hit-testing.
   - Status: User validated; included in the `26.6.8-1` release commit.
   - Prompt link: resizing lagged badly, and the top-right resize corner often started a window drag instead of a resize.
   - Changed: live window resize now uses a lightweight relayout path that scales cached page imagery, skips full-resolution crop rendering, avoids minimap thumbnail queueing, avoids repeated persistent-state writes, and performs the full viewport/fit render once when resizing ends.
   - Changed: top chrome drag now reserves a small 16 px resize zone in the top corners so AppKit can receive corner resize gestures while the rest of the empty top chrome still drags the window.
   - Validation target: resize the app from corners and edges with Sample Datasheet/sample catalogue open; resizing should feel much smoother, top-right corner should consistently resize, and dragging empty tab/chrome space should still move the window.

25. Mac trackpad pan direction stickiness.
   - Status: User validated; included in the `26.6.8-1` release commit.
   - Prompt link: two-finger trackpad movement felt directionally sticky compared with Preview, requiring extra movement to switch from horizontal to vertical motion or back.
   - Changed: disabled AppKit predominant-axis scrolling on the document scroll view and explicitly allowed horizontal/vertical scroll elasticity, so precise trackpad deltas can flow as free 2D panning while existing zoom and non-continuous page-turn handling stays in place.
   - Validation target: with a zoomed document wider and taller than the viewport, two-finger pan horizontally, vertically, diagonally, and change direction quickly; movement should follow the fingers with much less axis locking.

26. Mac defaults for side panel and map on new documents.
   - Status: Implemented; included in the `26.6.8-1` release commit.
   - Prompt link: add General/Settings controls for whether new documents open with the side panel and map visible, defaulting to the current behavior of visible.
   - Agent finding: global visibility defaults did not exist; current app stores per-tab/session and per-document `showSidebar`/`showMinimap`, and new tabs hardcoded both to `YES` before applying remembered document state.
   - Changed: added `settings.json` keys `defaultSidebarVisibleForNewDocuments` and `defaultMinimapVisibleForNewDocuments`, both defaulting to `YES`.
   - Changed: added checkable Settings menu items for “Open New Documents with Side Panel” and “Open New Documents with Map”; toggling saves immediately and affects future tabs only.
   - Changed: new tabs and legacy session entries without saved visibility use the global defaults first, then existing remembered per-document state still wins.
   - Validation target: defaults are checked on a clean profile, unchecking one or both writes `settings.json`, newly opened never-seen PDFs follow the chosen defaults, and previously opened PDFs keep their remembered visibility.

27. Mac trackpad fast-swipe acceleration.
   - Status: User validated; included in the `26.6.8-1` release commit.
   - Prompt link: after free 2D trackpad panning felt good, fast two-finger swipes accelerated too aggressively to the first/last page.
   - Changed: precise trackpad scroll events now use a high-speed damping curve in `SPDFScrollView` after zoom/page-turn handling; slow/fine deltas remain effectively unchanged, while large and momentum deltas are compressed before moving the document clip view.
   - Constraint: mouse-wheel scrolling, Command/Control zoom gestures, and non-continuous page-turn conversion are left on their existing paths.
   - Validation target: fast two-finger swipes should still coast, but no longer jump violently to the beginning/end; slow two-finger panning should retain the improved Preview-like free movement.

28. Continuous Fit Page scroll behavior.
   - Status: User validated; included in the `26.6.8-1` release commit.
   - Prompt link: fitting the page in continuous mode made scrolling act like non-continuous mode, jumping one page at a time.
   - Root cause: wheel-to-page-turn conversion was keyed on `Fit Height`/`Fit Page` even when `_viewMode` was continuous.
   - Changed: only single-page view converts wheel/trackpad scrolling into page changes; continuous mode keeps normal continuous scrolling for every zoom/fit mode.
   - Validation target: in continuous mode, choose Fit Page and scroll with the trackpad/wheel; the document should move continuously instead of stepping page by page. Non-continuous mode should still page-turn as before.

29. Single-page PDF map default.
   - Status: User validated; included in the `26.6.8-1` release commit.
   - Prompt link: when a single-page PDF is opened, override the default map display option and hide the map by default, while still allowing the map to be opened manually.
   - Changed: tabs now track whether minimap visibility came from explicit saved/session state versus a default. After a document loads and page count is known, one-page documents with no explicit minimap preference default to hidden regardless of the global new-document map setting.
   - Constraint: user/session/document-state choices still win. If the map was explicitly shown for that one-page file, it can persist normally.
   - Validation target: open a never-seen one-page PDF with the global map default enabled; the map should be hidden. Toggle Map on, reopen or switch away/back, and it should remain allowed/restored.

30. Prepare `26.6.8-1` for TestFlight validation.
   - Status: Implemented and validated for the `26.6.8-1` release commit.
   - Prompt link: after validating the recent Mac behavior fixes, update the About/version metadata to today's version, prepare TestFlight, commit, and tag.
   - Changed: bumped macOS bundle defaults to App Store-compatible `CFBundleShortVersionString=26.6.8` and `CFBundleVersion=1`, with About/CLI display as `26.6.8-1`.
   - Changed: updated TestFlight helper defaults, package naming docs, and release references to produce `ShenzhenPDF-testflight-26.6.8-1.pkg`.
   - Tested: rebuilt and installed `/Applications/ShenzhenPDF.app`; verified CLI version `26.6.8-1`, bundle metadata `com.intuition.shenzhenpdf`/`26.6.8`/`1`, local codesign, Objective-C++ syntax, shortcut tests, and diff hygiene.
   - Gap: TestFlight readiness has build tools/OpenSSL/MuPDF OK but still requires Apple Distribution certificate, 3rd Party Mac Developer Installer certificate, App Store provisioning profile, and optionally Transporter before a signed upload `.pkg` can be produced.

31. Prepare `26.6.8-2` post-zoom responsiveness release.
   - Status: Implemented; committed and tagged as `26.6.8-2`.
   - Prompt link: after live zoom became fluent, the user reported an unacceptable 2-500 ms freeze immediately after zooming, plus a missing minimap viewport preview during zoom. README should also be refreshed to showcase the reader before TestFlight prep.
   - Agent prompt rewrite: priority is immediate post-zoom pan/scroll responsiveness while preserving the fluent zoom/pan strategy; minimap during-zoom viewport preview is desirable only if it does not reintroduce stutter.
   - Changed: live-zoom settle no longer renders the crisp backing-scale viewport crop synchronously on the main thread. It queues a high-priority async viewport crop, invalidates stale crop results when newer movement or sync rendering happens, and gives throttled requests a delayed retry so the latest viewport is not lost.
   - Changed: minimap updates now refresh lightweight geometry and viewport state during live zoom while still skipping minimap thumbnail/render work until zoom settles.
   - Changed: README and portable README were rewritten to describe Shenzhen PDF's core reader features, macOS/Linux portable frontends, search/minimap/OCR/translation/windowing polish, current boundaries, and TestFlight handoff.
   - Changed: bumped macOS bundle build to App Store-compatible `CFBundleVersion=2`, keeping `CFBundleShortVersionString=26.6.8`, with About/CLI display as `26.6.8-2`.
   - Changed: updated TestFlight helper defaults and docs to produce `ShenzhenPDF-testflight-26.6.8-2.pkg`.
   - Reviewed: agent review found and the implementation fixed stale async crop application, dropped throttled crop requests, full-page render priority ahead of viewport crops, in-flight stale crop loops, live-zoom minimap O(n^2) geometry work, and pan-begin crop invalidation.
   - Tested: rebuilt and installed `/Applications/ShenzhenPDF.app`; verified CLI version `26.6.8-2`, bundle metadata `com.intuition.shenzhenpdf`/`26.6.8`/`2`, local codesign, Objective-C++ syntax, shortcut tests, and diff hygiene.
   - Gap: TestFlight readiness has build tools/OpenSSL/MuPDF OK but still requires Apple Distribution certificate, 3rd Party Mac Developer Installer certificate, App Store provisioning profile, and optionally Transporter before a signed upload `.pkg` can be produced.

32. High-zoom drag regression after `26.6.8-2`.
   - Status: Implemented for manual validation; not committed.
   - Prompt link: moving inside the document became laggy at relatively high zoom; check whether it is better to revert the latest async crop changes and keep only a zoom-to-drag transition fix.
   - Finding: the async post-zoom viewport crop queue added in `26.6.8-2` is the likely regression source because it can compete with high-zoom pan rendering on the shared render queue right when the user starts dragging.
   - Changed: removed the async viewport-crop queue, retry throttle, and grace window, restoring the `26.6.8-1` synchronous crop path for normal pan/minimap behavior.
   - Changed: replaced the immediate post-zoom crisp crop with a short delayed render guarded by document path, render generation, live-zoom sequence, and viewport-movement generation. If the user begins dragging or trackpad-scrolling after zoom, the delayed crop cancels instead of stealing responsiveness.
   - Kept: lightweight minimap viewport updates during live zoom, since they avoid thumbnail work and were not tied to the high-zoom drag lag.
   - Validation target: at high zoom, dragging inside Sample Datasheet and the long document should feel like the validated `26.6.8-1` movement path. Zoom-to-drag should no longer freeze; if dragging starts immediately after zoom, the crisp crop may wait until movement settles.

33. Search sidebar panel cleanup.
   - Status: Implemented for manual validation; not committed.
   - Prompt link: the Search sidebar tab should not show the redundant disabled “Search Results” filter box, and the “No matches...” empty state should be visually centered.
   - Changed: the sidebar filter field is now hidden only while the Search segment is active, and the results scroll view moves directly below the segmented control. Chapters and Comments keep their existing filter field behavior.
   - Changed: search status rows use the visible search-results height so the centered label is actually centered in the panel, not in a short table row at the top.
   - Validation target: search with no matches should show no in-panel search box and center the “No matches for ...” text in the available Search panel area.

34. Restore text selection priority over page drag.
   - Status: Implemented for manual validation; not committed.
   - Prompt link: text became unselectable because primary left-drag on the PDF page started document panning instead of text selection.
   - Finding: the Mac document view was checking “can this document pan?” before starting selection, so any zoomed or single-page document swallowed left-drag selection.
   - Changed: primary left-drag on a page now starts as text selection. If the drag moves past a small threshold and still selects no text, the interaction falls back to document panning from the original mouse-down point.
   - Preserved: page-margin/blank-page dragging, right-drag, middle/other-button drag, trackpad panning, and single-page pan/page-turn behavior remain available.
   - Validation target: dragging over selectable text should select/copy text; dragging blank slide/page areas should still move the document where panning is available.

35. Save As fallback for protected PDFs.
   - Status: Implemented, installed, and ready for user validation.
   - Prompt link: Cmd/Ctrl+S should expose Save As, File should include Save As, and operations that need to write back to a read-only or temporary PDF should offer Save As instead of failing.
   - Changed: macOS adds File > Save As... on Cmd+S and saves the active PDF through `NSSavePanel`, then updates the tab path, cached document state, recent documents, and persistent state.
   - Changed: macOS preflights PDF mutations before rotate, OCR, translation, and comment add/edit/delete. If the current PDF is in a temp folder or the file/folder is not writable, Shenzhen PDF asks for a writable copy and continues only if Save As succeeds.
   - Changed: Linux mirrors File > Save As... on Ctrl+S, saves through a GTK save dialog, retargets the active tab to the saved PDF in place, and preflights rotate, OCR, translation, and comment add/edit/delete with the same writable/non-temp requirement.
   - Validation target: open a PDF from `/tmp` or a read-only folder, run rotate/OCR/translate/comment edit, and verify the Save As prompt appears before the operation writes back.

36. Stop left-click panning and stabilize trackpad live-zoom minimap preview.
   - Status: Partially reverted for manual validation; not committed.
   - Prompt link: after zoom-to-drag responsiveness improved, trackpad zoom still felt slightly laggy, the minimap viewport preview drifted during zoom, and left-click still dragged when clicking between text.
   - Changed: primary left-drag on the document surface is selection-only. It no longer falls back to document panning on blank text gaps or page whitespace. Right/middle-button panning and trackpad scrolling remain separate paths.
   - Reverted: the live-zoom minimap page-rect refresh and center-anchored trackpad pinch were rolled back after they made the drag/zoom behavior worse. Trackpad magnify again uses the event window point, and live zoom no longer rebuilds minimap page geometry mid-gesture.
   - Validation target: drag between words/lines with left click should select or do nothing, never pan; trackpad zoom/drag should return to the previously better feel without the new minimap drift.

37. Restore OCR output integrity.
   - Status: Implemented for validation; not committed.
   - Prompt link: OCR appears to run successfully, but after completion no selectable text is produced in the document.
   - Finding: direct OCRmyPDF runs on controlled no-text PDFs do produce selectable text, so the app boundary needed to stop trusting process success as document success.
   - Changed: macOS and Linux now run the image-only path without `--skip-text`, validate the produced PDF with the core text extractor before replacing the original, and leave the original file unchanged if validation fails.
   - Changed: if an image-only PDF still validates as no-text after the normal OCR pass, the app retries once with OCRmyPDF's forced image OCR mode, then validates again before installing the result.
   - Validation target: OCR a no-text scanned/image PDF; after the app reports completion, text selection/search should work in the reloaded document. If OCRmyPDF completes but produces no selectable text, Shenzhen PDF should show an error instead of replacing the original.

38. Revert last drag/zoom tweak.
   - Status: Implemented for manual validation; not committed.
   - Prompt link: the last modification to the drag/zoom issue made the behavior worse and should be reverted.
   - Changed: removed the trackpad pinch center-anchor helper and restored `magnifyWithEvent:` to pass `event.locationInWindow`.
   - Changed: removed the live-zoom minimap page-rectangle rebuild added in the previous tweak; during live zoom the minimap updates only the lightweight viewport fields as before.
   - Preserved: OCR output validation, Save As fallback work, and text-selection-only left-click behavior were left intact.
   - Validation target: compare trackpad zoom/drag against the previous better feel; the new worsening drift/stickiness should be gone.

39. Stabilize page rotation reload state.
   - Status: Implemented for validation; not committed.
   - Prompt link: page rotation reloads incorrectly, the displayed page state does not always match the saved PDF, and sometimes a second page rotates; only the current page shown in the page counter should turn.
   - Finding: the core rotation function rotates exactly one page object in a controlled `qpdf` smoke test, but macOS render worker threads cached opened PDFs by path only, so after saving a rotation they could continue rendering the pre-rotation file.
   - Finding: after a rotation save, the selected tab kept its old absolute scroll origin. Because rotation changes page geometry, reload could land on a neighboring page, so a repeated rotate could affect a different page than the one the user meant.
   - Changed: macOS worker PDF caches are keyed by standardized path, file size, and modification date, forcing render workers to reopen a changed PDF after rotation/OCR/Save As-style writes.
   - Changed: macOS rotation reads the current page from the visible page counter, cancels transient pan/zoom state, clears the tab scroll origin, and reloads explicitly to that page index after saving.
   - Validation target: rotate page N, verify the app reloads still on page N, only page N changes in the saved PDF, and a second rotation without changing the page rotates page N again rather than a neighbor.

40. Passive inactive-window scrolling and zooming.
   - Status: Implemented for validation; not committed.
   - Prompt link: if the mouse is over the app and the app is not focused, scrolling and zooming should work without focusing the app until a click is detected.
   - Finding: the main document scroll view already handled wheel and magnify events without calling the window activation helper, but the minimap wheel and magnify handlers activated the app before forwarding scroll/zoom.
   - Changed: minimap scroll-wheel zoom, minimap pinch zoom, and minimap wheel scrolling now forward passive events without activating the app. Minimap click/drag still activates through `mouseDown`, preserving the current click behavior.
   - Validation target: make another app active, hover the document and minimap in Shenzhen PDF, scroll and pinch/Cmd-scroll; the document should move/zoom while Shenzhen PDF remains inactive until an actual click.

41. Copy Path menu commands and menu icons.
   - Status: Implemented for validation; not committed.
   - Prompt link: add Copy Path to the document right-click menu and tab right-click menu, and try to put relevant system icons in front of menu options, including top menus.
   - Changed: macOS File, document context, and tab context menus now expose Copy Path, copying the active/tab PDF path as plain text while keeping the existing tab Copy command as a file pasteboard copy.
   - Changed: macOS menu items receive SF Symbol icons by action/title across top-level menus and context menus where symbols are available on the host system.
   - Changed: Linux File and document context menus expose Copy Path, Linux tab right-click now exposes Show in Folder and Copy Path, and icon-capable GTK menu items use standard theme icon names where the desktop renders menu icons.
   - Validation target: Copy Path from File, document right-click, and tab right-click should place the exact document path on the clipboard; existing Copy should still copy the PDF file object on macOS tabs; menu icons should appear where the OS/theme allows them.

42. Restore live-zoom minimap viewport geometry only.
   - Status: Implemented for validation; not committed.
   - Prompt link: zoom now feels like the previous acceptable behavior, but the minimap viewport behavior should keep the earlier good fix.
   - Finding: after reverting the worsening zoom-anchor changes, live zoom still updated the minimap visible rectangle and scale but no longer refreshed the per-page document rectangles used to project that viewport onto the minimap. That left the blue viewport overlay calculated against stale page geometry during zoom.
   - Changed: live zoom now refreshes only `documentPageRects` for the minimap before drawing the viewport overlay. It still avoids resetting minimap pages and skips thumbnail rendering while zooming, so the zoom gesture behavior and thumbnail performance strategy remain unchanged.
   - Validation target: during fast zoom in/out, the minimap viewport should stay aligned with the actual visible document area without reintroducing the previous trackpad zoom/drag regression.

43. Search sidebar layout polish.
   - Status: Implemented for validation; not committed.
   - Prompt link: no-match text is still not centered, search result text should align with the beginning of the “Chapters” segment label, chapter pills should extend farther right, and result text should truncate with ellipses according to panel width.
   - Changed: search result rows and chapter divider pills use a dedicated left edge, matching the segmented-control text line more closely than the generic sidebar row inset.
   - Changed: the sidebar table column now tracks the visible scroll-view width on rebuild and sidebar resize, so result titles/subtitles truncate against the current panel width.
   - Changed: empty/search-status rows refresh their height and reset scroll position when search results disappear, so the “No matches...” message centers in the visible Search panel instead of inheriting the previous result-list scroll offset.
   - Changed: chapter divider pills expand to the available row width when there is no room for a useful trailing line; highlighted result titles carry a truncating paragraph style so they end with ellipses instead of clipping or wrapping.
   - Validation target: search for no matches and verify the message is visually centered; search for matches and verify divider pills/results start at the same left edge as the “Chapters” label and truncate cleanly while resizing the side panel.

44. Live minimap FPS after accurate viewport geometry.
   - Status: Implemented for validation; not committed.
   - Prompt link: the minimap viewport position is now accurate, but the minimap itself runs around 5 fps while the rest of the app remains smooth.
   - Finding: the accurate live-zoom path recalculates the viewport overlay correctly, but each minimap repaint still redraws every visible thumbnail, highlight, selection, and current-page border before drawing the blue viewport rectangle.
   - Changed: `SPDFMinimapView` now builds a bounded offscreen thumbnail-strip cache during live viewport updates and reuses it while the accurate viewport overlay moves. Normal minimap redraws still invalidate the cache, so search highlights, selections, page changes, and newly rendered thumbnails do not stay stale outside the live path.
   - Changed: the controller enables this cache only while `_liveZooming` is true. The existing accurate `documentPageRects` and `documentVisibleRect` updates remain unchanged.
   - Validation target: zoom/drag a long document with the minimap open; the blue viewport should remain aligned with the visible document area while the minimap updates fluidly, without changing normal thumbnail resolution after zoom settles.

45. Side-panel resize hit target.
   - Status: Implemented for validation; not committed.
   - Prompt link: the side panel resize click target is too small and nearly impossible to grab; the minimap divider was already correct and should not be changed.
   - Changed: the left side-panel `NSSplitView` now advertises an 18 pt effective divider hit rectangle while keeping the thin visual divider and all existing sidebar width constraints.
   - Preserved: the minimap divider remains the separate `SPDFMinimapDividerView` with its existing width and drag behavior unchanged.
   - Validation target: with the side panel open, grabbing near the vertical split between sidebar and document should resize reliably; the minimap divider should feel exactly as before.

46. Restore top-menu text and protect Find-field navigation.
   - Status: Implemented for validation; not committed.
   - Prompt link: top menu names should be plain text; icons belong only inside menu contents. Long Find-field text should be navigable with arrow keys and mouse like a standard macOS text field.
   - Finding: the menu icon helper was applied to `NSApp.mainMenu` itself, so it decorated the top-level menu bar items. It should instead recurse into each top-level submenu.
   - Finding: an explorer agent confirmed the main Find field is a stock `NSSearchField`; the likely shortcut conflict was the window-arrangement key path bypassing the text-editing guard when Function-style arrows were pressed.
   - Changed: top-level menu bar items are no longer assigned SF Symbol icons. Icons still apply inside File/View/Window/etc. menus and nested menu contents.
   - Changed: the toolbar Find field now uses `SPDFFindSearchField`, a tiny subclass that accepts first mouse and cannot become a window-drag region.
   - Changed: document arrow navigation and window-arrangement shortcuts now always yield while any text field/editor is active, and window-arrangement menu key equivalents validate disabled during text editing.
   - Validation target: menu bar should show text-only top menu names; inside opened menus icons should remain. Paste a Find query longer than the field, then verify mouse clicks and Left/Right, Option-Left/Right, Command-Left/Right, and Fn/Home/End-style navigation move within the field without scrolling pages or moving/resizing the window.

47. Selected-text browser search and editable selection translation.
   - Status: Implemented for validation; not committed.
   - Prompt link: add a Preview-like selected-text Search in Browser action, and add local selection translation without asking language first; remember languages, show source/target dropdowns, editable input/output, and retranslate on demand.
   - Agent prompt rewrite: selected text should gain context actions that are lazy, fast, and non-blocking: macOS should use the system/default browser search route rather than hardcoded Google, and translation should reuse the existing local Argos backend only when invoked.
   - Finding: the portable Mac app already stores selected text in `_selectedText` and already has Argos Translate support for document/selection-to-PDF translation with persisted source/target language codes.
   - Changed: the document context menu now shows `Translate "<selection>"` and `Search Web for "<selection>"` above Copy when text is selected. Search uses macOS `x-web-search://?...`, avoiding a hardcoded Google search URL.
   - Changed: selection translation now opens a lazy `Translate Selection` panel from the context menu or existing Translate command when text is selected. It has source/target dropdowns, editable input and output text, a Translate button, and remembered language choices. Opening the panel immediately translates the selected text; clicking Translate later replaces any edited output with a fresh local translation of the current input.
   - Changed: selection translation runs Argos on a background queue and reuses the existing installer/package prompts only after the user invokes translation, so launch and render paths do not initialize translation tooling.
   - Validation target: select text, right-click, verify Search Web opens browser search; verify Translate opens the panel, immediately translates with last languages, allows editing input/output, persists changed language dropdowns, and retranslation replaces output without blocking app launch.

48. Post-zoom crisp render guarantee.
   - Status: Implemented for validation; not committed.
   - Prompt link: after some zoom/unzoom cycles, the page can stay blurry forever; when it does render at high zoom, unzoom becomes laggy.
   - Agent finding: the delayed post-live-zoom crop render was gated on `_viewportMovementGeneration`, so ordinary viewport settling could cancel the only crisp fallback without scheduling another one. The same callback rendered MuPDF page crops synchronously on the main thread, which explains the high-zoom unzoom hitch.
   - Changed: the post-live-zoom render no longer treats viewport movement as a cancellation reason. It still validates live-zoom sequence, render generation, path, document presence, and current zoom before applying results.
   - Changed: post-live-zoom viewport crops now render on the page render queue with user-initiated priority and apply back on the main thread only if they still match the current document and zoom. If a document pan is active when the callback fires, it reschedules instead of dropping the crisp pass.
   - Changed: document drawing now prefers the minimap fallback over stale full-page images during zoom transitions and draws viewport crop images only when their zoom matches the current zoom, preventing old high-zoom crops from being scaled during unzoom.
   - Validation target: repeatedly zoom in/out quickly around high zoom on Sample Datasheet and long landscape documents; the viewport should never remain permanently blurry, and unzoom should not hitch when the crisp crop arrives.

49. Copy-selected-text newline normalization.
   - Status: Implemented for validation; not committed.
   - Prompt link: do the same replace-newline-with-space text trick when copying selected text, and make it toggleable in the Edit menu with the default on.
   - Changed: document text copy now uses the same whitespace-collapsing helper as selection translation/search when `Replace Line Breaks When Copying Text` is enabled. This affects only `copySelection:`; normal macOS text-field copy remains untouched.
   - Changed: the toggle is checkable in the Edit menu, defaults on for fresh settings, and persists in `settings.json` as `collapseWhitespaceWhenCopyingText`.
   - Validation target: select multiline PDF text and copy; with the Edit-menu toggle on, pasted text should be one whitespace-normalized line. Turn it off and copy again; pasted text should preserve the original selected line breaks.

50. Find-field horizontal navigation and zoom render de-regression.
   - Status: Implemented for validation; not committed.
   - Prompt link: long Find-field text still cannot be navigated horizontally; zoom/unzoom can still leave pages blurry forever and create massive lag when unzooming.
   - Changed: the toolbar Find search field is explicitly single-line, scrollable, non-wrapping, and handles horizontal trackpad scrolling locally by moving/scrolling the field editor through the query instead of letting the event fall through to document scrolling.
   - Changed: live zoom now clears queued render work immediately instead of suspending and carrying stale background work. Queued full-page renders also check the live-zoom sequence before starting expensive work.
   - Changed: post-zoom visible viewport crops are scheduled before full-page/nearby background renders, and those background renders are delayed briefly so the crisp visible crop is not stuck behind stale high-zoom work.
   - Changed: drawing again uses the previous full-page image as the live fallback instead of dropping straight to the minimap image, while stale viewport crops are still ignored when their zoom/scale no longer matches.
   - Validation target: enter a long Find query and verify horizontal trackpad movement/arrows can navigate it. Repeatedly zoom in/out at high zoom; the visible page should crisp up without getting stuck behind background renders, and fast unzoom should not hitch behind stale high-zoom work.

51. High-zoom unzoom lag fallback.
   - Status: Superseded by item 52 after validation feedback.
   - Prompt link: when zoomed in, unzoom still has extreme lag.
   - Finding: the live unzoom path could still draw a stale high-resolution full-page bitmap as the fallback after the zoom value changed. Scaling that large image every live-zoom frame can dominate the UI thread.
   - Changed: `SPDFDocumentView` was taught when live zoom is active. The first attempt used the lightweight minimap fallback instead of scaling stale high-resolution page images; validation feedback rejected that because the visible document became too pixelated during zoom changes.
   - Validation target: zoom deeply into a page and immediately unzoom; the gesture should stay responsive instead of hitching on stale high-zoom bitmap scaling.

52. Proper live-zoom fallback and stale render cleanup.
   - Status: Implemented for validation; not committed.
   - Prompt link: repeated zoom in/out cycles still behave the same or worse over time, and the extremely pixelated document image during zoom changes is unacceptable. Test against Sample Datasheet and `test-protocol.pdf`.
   - Agent finding: the previous fallback deliberately stretched minimap thumbnails as the page during live zoom, while canceled render operations could still be running and later compete with the next crisp viewport render.
   - Changed: live zoom no longer uses minimap thumbnails as the normal document content. It draws exact full-page images, cheap stale full-page images, and reusable viewport crops; minimap thumbnails are only the final fallback if no crop/image exists, so pages do not go blank. Expensive stale full-page bitmaps are skipped so high-zoom unzoom cannot block the main thread scaling huge images. The same lightweight draw policy remains active until the post-zoom visible viewport crop is applied or found unnecessary.
   - Changed: live zoom now suspends render/minimap queues before canceling queued work, invalidates pending async visible-crop render generations without letting ordinary viewport maintenance cancel the post-zoom crisp pass, and protects currently visible pages/crops from cache eviction.
   - Validation target: repeatedly zoom in/out and pan at high zoom on Sample Datasheet and Test Protocol; no minimap-grade pixel fallback should appear, zoom input should not degrade over cycles, and the visible viewport should render crisp after the gesture without carrying stale high-zoom lag into unzoom.

53. Three-page nonblocking zoom seed cache.
   - Status: Implemented for validation; not committed.
   - Prompt link: zoom should scale the current render immediately, then after zoom stops render only the current page plus one above and one below; a background thread should keep a reasonable 200% quality cache for those three pages and switch to it as soon as the next zoom starts. Also support out-of-focus trackpad zoom like out-of-focus mouse zoom.
   - Agent rewrite: keep live zoom purely on the UI thread with pre-existing images, never synchronously render during the gesture, and constrain all exact/background work to the active page neighborhood. Seed images are view-transient; exact page/crop renders replace them only after the gesture settles.
   - Changed: each rendered page can hold a high-quality zoom seed image and transient live-zoom seed metadata. Live zoom freezes the current three-page neighborhood from the best available source, preferring the capped 2x cache, then exact full-page render, exact viewport crop, cheap stale full-page image, and finally minimap only as a last resort.
   - Changed: page changes and first-paint work now warm the current page neighborhood with normal renders and a capped high-quality cache instead of depending only on broad nearby-page rendering. The cache refuses pages above the per-page bitmap cap so it cannot reintroduce the massive-image scaling hitch.
   - Changed: after live zoom finishes, the visible crop render remains the first exact work, while normal full-page renders and 2x cache refreshes are delayed and limited to the three-page neighborhood. Zoom seeds are cleared only after the crisp viewport render is applied or no crop is needed.
   - Validation target: with Sample Datasheet and `test-protocol.pdf`, repeatedly zoom in/out quickly, move immediately after zooming, and change pages; live input should not stutter, the page should not stay blurry forever, and no broad full-document render should block the gesture.

54. Cache queue isolation for first-input zoom stutter.
   - Status: Implemented for validation; not committed.
   - Prompt link: the first zoom/pan inputs can still stutter, sometimes more after repeated zoom cycles; focused documents should already have a 100% base cache and a 200% current-page-neighborhood cache without blocking interaction.
   - Agent finding: the first seed-cache implementation warmed base and high-quality cache images through the same `_renderQueue` used by visible page/crop renders. Even with low QoS, already-running cache jobs could occupy foreground render slots and recreate the transition hitch.
   - Changed: base and 2x zoom cache warming now use a dedicated low-priority `_cacheRenderQueue` capped to one worker. Foreground page renders and visible viewport crop renders stay on `_renderQueue`, while cache work is cancelled only on document identity changes and paused during ordinary live zoom.
   - Changed: live zoom now cancels stale queued foreground/minimap work instead of merely forgetting its bookkeeping, so old render jobs cannot keep competing invisibly after a zoom starts.
   - Review loop: a verification agent flagged three risks before validation: cache warmers could still run during live zoom, crop-only seeds could blank the rest of the page, and the fixed 1x base cache could be chosen for high-zoom live drawing. The patch was tightened so live zoom suspends the cache queue, crop seeds overlay the existing page fallback instead of replacing it, and the 1x base cache is only used as a seed near 100% after better sources are unavailable.
   - Validation target: with Sample Datasheet and Test Protocol, open a document, wait briefly for cache warming, then pinch/scroll zoom and immediately pan. The first input should not pause, repeated zoom cycles should not get progressively worse, and no visible resolution should be intentionally lowered during the gesture.

55. New zoom gesture first-frame stutter.
   - Status: Implemented for validation; not committed.
   - Prompt link: the app is much better, but each new zoom action still has a small painful stutter and misses the beginning of inputs.
   - Finding: the first event of a new live-zoom gesture still performed avoidable main-thread work. It forced toolbar/menu synchronization by resetting the live-zoom control timer, allowed normal background full-page renders to occupy the foreground render queue, and scheduled minimap viewport updates on the next runloop for every gesture event.
   - Changed: live zoom no longer mutates toolbar/menu controls during the gesture; the existing finish path still updates the visible zoom value and controls after the gesture settles. Non-urgent full-page renders now run on the single-worker low-priority cache queue, while explicitly high-priority visible renders remain on the foreground renderer. Starting live zoom cancels queued cache/background work, and live minimap viewport updates are coalesced to a 60 Hz cadence.
   - Validation target: repeatedly start short trackpad zoom gestures on Sample Datasheet and Test Protocol, including immediately after a previous zoom settles. The first pinch/scroll input should affect the document immediately without the tiny initial pause.

56. Resident 100% / 200% zoom seed correction.
   - Status: Implemented for validation; not committed.
   - Prompt link: unzooming from high zoom still feels like the app has to re-render something; the active document should already have the 100% render and the 200% current-page-neighborhood render in RAM.
   - Finding: the previous cache split still let current-page seed work sit behind full-document warming, suspended that cache during live zoom, and only adopted finished 2x renders on the next gesture. Eviction and seed selection could also leave the 100% base image unused during a high-zoom unzoom gesture.
   - Changed: added a dedicated zoom-seed render queue for the current page plus one page above and below. The 2x seed and urgent 100% base seed now jump ahead of ordinary nearby renders and full-document 100% warming. The full-document 100% cache remains on the slower cache warmer.
   - Changed: if a 100% or 200% seed finishes while live zoom is already active, the page view adopts it immediately and redraws that page. Live zoom now allows the base 100% image as a fallback seed when the 2x seed is not ready, instead of forcing a fresh render or blank/minimap fallback.
   - Validation target: open Sample Datasheet and Test Protocol, wait briefly after the focused page appears, zoom deeply, then unzoom repeatedly. The first unzoom frames should use resident page imagery, not pause for a new render; repeated cycles should not get progressively worse.

57. Expert-agent zoom hot-path correction.
   - Status: Implemented for validation; not committed.
   - Prompt link: validation reported no behavior change after the resident-cache queue patch; use expert agents to find why.
   - Agent findings: the cache queue change could not help until `drawRect:` actually ran. The first live-zoom event still performed synchronous anchor/layout/frame/scroll work, `drawPage:` did not directly consider `highQualityImage`, seed pages could miss the page under the cursor when `_pageIndex` lagged, and high-quality 2x images were evicted with ordinary page renders.
   - Changed: live zoom now seeds the anchor page, current page, current document-view page, and visible pages instead of only `_pageIndex +/- 1`. The 2x seed queue is nudged for that set immediately when the gesture starts.
   - Changed: document drawing now directly falls back to resident 2x and 100% full-page images during live zoom when a transient seed is unavailable. Full-page image drawing clips to the dirty/visible slice while preserving the original full-image coordinate mapping; an attempted source-rect crop caused corrupt exploded text and was reverted immediately.
   - Changed: the document view no longer invalidates its page-layout cache just because the live-zoom frame height changed, continuous drawing/hit-testing early-exits once it passes the dirty point/rect, and the 2x cache has a separate memory budget from ordinary exact/current-zoom page images.
   - Validation target: with Sample Datasheet and Test Protocol, zoom deeply and unzoom repeatedly using trackpad and Cmd/Ctrl-scroll. Watch especially for first-input stutter, wrong cropped image sections during live zoom, and whether repeated cycles degrade.

58. Zoom input priority over render work.
   - Status: Implemented for validation; not committed.
   - Prompt link: keep the current no-lag/good-looking architecture, but prioritize unzooming over rendering and run rendering separately so starting zoom/unzoom has no wait.
   - Changed: starting a live zoom no longer enqueues a 2x render. The gesture start now flips into live-zoom mode, suspends/cancels foreground, zoom-seed, cache, background, and minimap render queues, then freezes only already-resident page images for drawing.
   - Changed: cache workers now exit if they wake up after live zoom has started, and the zoom-seed queue is capped to one utility-priority worker. This keeps 100%/200% warming in the background while making input responsiveness higher priority than cache freshness.
   - Validation target: trigger short rapid zoom/unzoom gestures immediately after opening and after repeated zoom cycles. The first input should move the page immediately, with no new render stealing the start of the gesture.

59. Measured zoom gesture-start stutter fix (giant renders and minimap strip).
   - Status: Implemented; validated with the built-in profiler self-test.
   - Prompt link: starting zoom or unzoom still stutters before the movement begins, especially from fully zoomed in; performance is great after that.
   - Method: added an env-gated profiler (`SPDF_ZOOM_PROFILE=1`) that logs slow document/minimap draws, every core render with size and duration, and main-thread stalls over 50ms, plus a synthetic gesture driver (`SPDF_ZOOM_SELFTEST=1`) that replays zoom-in/unzoom phases through the real `beginLiveZoomByFactor:` path. Event handling measured sub-millisecond; the stutter was elsewhere.
   - Finding 1: after a gesture settled at high zoom, the post-zoom neighborhood full-page renders were allowed up to the old 512MB per-page cap. At zoom 8 that meant 15357x8640 (506MB, 2.4s) renders; starting the next gesture while one was in flight stalled the main thread ~380ms (memory-bandwidth contention), which is exactly the "stutter before the movement starts, especially from fully zoomed in".
   - Finding 2: the minimap strip drew `page.image ?: page.minimapImage`, preferring full-resolution page bitmaps over thumbnails. Rebuilding the live-zoom content cache on the first gesture frame cold-decoded dozens of large bitmaps (83-133ms on the main thread), stuttering gesture start at any zoom level.
   - Changed: `kMaxRenderedPageBitmapByteLimit` lowered 512MB -> 96MB; beyond it the existing viewport-crop path keeps the visible region crisp, so deep-zoom full-page giants are never rendered. The minimap now prefers `minimapImage` thumbnails and falls back to `page.image` only when no thumbnail exists.
   - Result: self-test on Sample Datasheet and Test Protocol shows no main-thread stalls during any gesture phase (previously 82-384ms at gesture start), minimap draws 5-22ms (previously 83-133ms), and no render above 35MB after deep zoom.
   - Validation target: trackpad pinch and Cmd/Ctrl-scroll zoom/unzoom, especially starting from fully zoomed in right after a previous zoom settled; the first input should track immediately with no initial hiccup.

60. Navigation renders moved fully off the main thread.
   - Status: Implemented; validated with the profiler self-test navigation phase.
   - Prompt link: when it renders it still misses input and feels buggy; rendering must be a background process that never hampers navigation.
   - Finding: `renderPageIfNeededAtIndex:` rendered the full page synchronously on the main thread (50-500ms depending on zoom) and is called from `documentScrollPositionChanged`, `goToPage:`, minimap drag callbacks, find-match jumps, link activation, and sidebar activation — every navigation gesture could block on an inline render. The foreground render queue also allowed up to 60% of cores of concurrent page renders, enough memory-bandwidth pressure to stall main-thread input even with all work off-main.
   - Changed: `renderPageIfNeededAtIndex:` now enqueues the page through the existing async high-priority render path (same adoption semantics: highlights, selection, minimap copy, eviction) and keeps drawing resident stale/base imagery until the render lands. The viewport-crop fallback for over-cap pages is unchanged. `_renderQueue` concurrency is capped at 3.
   - Self-test: added a navigation stress phase (`SPDF_ZOOM_SELFTEST=1`): 28 rapid next/previous page turns at 50ms cadence right after the zoom phases. Sample Datasheet and Test Protocol both show zero main-thread stalls and zero main-thread renders during navigation; the only synchronous render left is the intentional first-paint render in `renderDocumentAndScrollToPage:` at document open/full relayout.
   - Validation target: scroll and page through documents while pages are still rendering (e.g., right after changing zoom); input should never pause, with stale imagery sharpening as async renders land.

61a. Per-scroll-event maintenance coalescing (input drops during rendering).
   - Status: Implemented; validated with the extended profiler self-test.
   - Prompt link: some inputs are still missed during rendering despite async renders.
   - Investigation (agent + manual): an agent added a continuous-scroll stress (500 steps at 8ms emulating the trackpad entry path, with an input-latency histogram), a mixed scroll+zoom phase, adoption-block timing, and an SPDF_RENDER_WORKERS override; a high-zoom (5.0, crop-regime) scroll phase was added on top. Result: render adoption, first-draw decode, and bg-render bandwidth were all clean (99%+ of steps under 8ms at render concurrency 1 and 3 on both test documents). The real cost was per-event: `documentScrollPositionChanged` spent 4-6ms per scroll tick (visible-crop checks, full `updateMinimap` rebuild including page-rect arrays and thumbnail scans, cache eviction) plus 5-8ms minimap full redraws — at 120Hz trackpad event rates this saturates the main thread, so real input events get coalesced/dropped, worst exactly while renders add adoption work on top.
   - Changed: the non-panning scroll path now does only page-index sync per event and coalesces crops + minimap + eviction into a single ~30Hz maintenance pass. During scrolling the minimap updates in its cached `liveViewportOnly` mode (indicator moves over the cached strip); a full minimap refresh runs 300ms after scrolling rests.
   - Result: per-tick `scrollPosChanged` cost drops to sub-millisecond; scroll stress histograms stay at 99%+ under 8ms with maintenance now bounded regardless of event rate.
   - Validation target: flick-scroll and momentum-scroll through documents while pages render (after zoom changes, at high zoom in the crop regime); input should stay responsive with no dropped scroll segments.

61. Out-of-focus trackpad pinch zoom (agent-implemented).
   - Status: Implemented; build-verified, needs manual pinch validation.
   - Prompt link: window-out-of-focus zoom works with Cmd+scroll but not trackpad pinch.
   - Agent root causes: (1) the inactive-magnify support only had a global event monitor, which by definition never observes events delivered to ShenzhenPDF itself — when the app was active but a different ShenzhenPDF window was key, the pinch always went to the key window; (2) the global handler hit-tested window frames front-to-back among registered windows only, ignoring other apps' windows stacked above, so an occluded window could zoom; (3) `hitTest:` was fed a point in the content view's own coordinates instead of its superview's.
   - Changed (`SPDFMacUIHelpers.mm`): new `spdf_magnify_window_under_screen_point()` resolves the topmost window at the cursor via `+[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:]` and matches it to a registered ShenzhenPDF window. The global monitor (other app frontmost) now uses it; a new local monitor reroutes magnify events to a non-key ShenzhenPDF window under the cursor and swallows them, returning the event unchanged when the cursor is over the key window so the responder chain fires exactly once. Monitor tokens are retained; the `hitTest:` coordinate space is fixed.
   - Limitation: if a macOS release neither delivers pinches to global monitors nor to the inactive app's own event stream, no in-process mechanism can observe them; current releases document magnify as globally observable without Accessibility permission.
   - Validation target: with two ShenzhenPDF windows, pinch over the non-key one (should zoom it, not the key window); with another app frontmost, pinch over a visible ShenzhenPDF window; normal focused pinch must zoom exactly once.

62. Out-of-focus pinch cumulative-magnification correction (agent-implemented).
   - Status: Implemented; build-verified, needs manual pinch validation.
   - Prompt link: out-of-focus pinching reacts but behaves like an absolute movement (slams to min zoom, then rezooms).
   - Agent root cause (established by disassembling AppKit's `-[NSEvent _initWithCGEvent:eventRef:]` on this machine): NSEvents built from monitored CGEvents map gesture field 113 directly into `magnification`, and field 113 carries the CUMULATIVE gesture magnification, not a per-event delta (cross-checked against Hammerspoon's TouchEvents synthesis, which writes total magnification into field 0x71). No phase field is decoded, so monitored magnify events always report phase None. Compounding `1+m*0.82` per event with a cumulative `m` is exactly "absolute movement": pinch-in slams to min zoom, reversing climbs back. Legacy type-30 magnify CGEvents additionally convert with magnification 0 and would corrupt a naive delta tracker, so they are filtered.
   - Changed (`SPDFMacUIHelpers.mm`, plus thin delta-method plumbing in `ShenzhenPDFMac.mm` and the headers): the global-monitor path converts cumulative values to per-event deltas (baseline on first event, reset on phase Began, cleared on Ended/Cancelled, >0.3s gap treated as a new gesture); the global monitor bails when the app is active so exactly one path ever applies a pinch; |delta| > 0.5 is swallowed defensively; SPDF_ZOOM_PROFILE logs path/phase/raw/delta for one-pinch confirmation. The focused responder-chain path is byte-for-byte equivalent via wrappers.
   - Validation target: with another app frontmost, pinch over a ShenzhenPDF window — zoom should track the pinch relatively and smoothly, exactly like a focused pinch; `SPDF_ZOOM_PROFILE=1` should log `inactiveMagnify path=global` lines with monotonically growing `raw` and small `delta` values.

63. Trackpad-only first-input loss (pinch and scroll).
   - Status: Implemented; build- and regression-verified, needs manual trackpad validation.
   - Prompt link: mouse zoom/scroll fully resolved; trackpad pinch and two-finger scroll still miss the first inputs of a gesture.
   - Cause 1 (scroll after pinch/zoom — proven by code reading): every magnify event and Cmd-scroll zoom event arms a residual-suppression window (`markZoomWheelAtTimestamp`: 0.65s for phased events). The exemption only covered the new gesture's Began/MayBegin event (which carries a zero delta); all the following Changed events of a genuinely new trackpad scroll were swallowed until the window expired. Mouse wheels are immune: their events are phase-less (0.18s window only) and never follow a pinch. Fix: Began/MayBegin now terminates the residual window entirely — only the tail/momentum of the gesture that drove the zoom can be suppressed.
   - Cause 2 (out-of-focus pinch start): the cumulative-to-delta converter swallowed the first observed magnification as a "baseline", but a gesture's cumulative value restarts from zero, so the first value IS the first input. Fix: on a gesture break the first non-Began value is applied as the delta (Began events genuinely carry zero); the existing |delta|>0.5 guard still catches mid-gesture pickup.
   - Cause 3 (focused pinch latency): the local magnify monitor performed a `windowNumberAtPoint` window-server IPC on every pinch event even with a single focused window. Fix: an in-process fast path returns the event untouched when the cursor is inside the key ShenzhenPDF window's frame; the IPC now only runs in the actual rerouting case. Known trade-off: with overlapping ShenzhenPDF windows where a non-key window covers the key window at the cursor, the key window wins — acceptable for removing per-event IPC from the hot path.
   - Diagnostics: `SPDF_ZOOM_PROFILE=1` now logs `focusedMagnify phase/m/age` per focused pinch event (age = delivery latency) and `suppressResidualWheel` whenever the residual window swallows a scroll event, so one manual gesture confirms behavior.
   - Validation target: pinch then immediately two-finger scroll (no suppressed gap); rapid alternation of pinch and scroll; out-of-focus pinch should track from the very first finger movement.

64. Zoom anchors on the cursor at every zoom level.
   - Status: Implemented; build- and regression-verified.
   - Prompt link: zoom goes to the page center instead of the mouse cursor; hybrid behavior that follows the cursor only past a certain zoom level.
   - Cause: `pageAnchorForWindowPoint:` special-cased fully-visible pages — while the page still fit the viewport it returned a page-CENTER anchor, only switching to the cursor anchor once zoomed past page-fits. That is exactly the observed hybrid.
   - Changed: the cursor point is now always the anchor when it falls in a page; when it falls in the margins/gutter it is clamped to the nearest page instead of using the viewport center. The fully-visible helpers were removed. While the document is smaller than the viewport, scroll clamping still keeps it centered, so small-zoom layouts are unchanged; the anchor takes over seamlessly as the page outgrows the viewport. Keyboard zoom (Cmd+/-) passes the viewport center as its anchor point and behaves as before.
   - Validation target: pinch or Cmd/Ctrl-scroll with the cursor over a corner of a page at low zoom; the content under the cursor should stay under the cursor through the whole zoom range with no jump at the page-fits boundary.

65. Out-of-focus pinch: phase-based cumulative/relative discrimination.
   - Status: Implemented; build- and regression-verified, needs manual out-of-focus pinch validation.
   - Prompt link: enable trackpad zoom over the viewport or minimap of an unfocused window; panning and mouse zoom work but pinch does nothing.
   - Reasoning: the earlier "absolute movement" report proves macOS DOES deliver pinch events natively to the inactive app's window under the cursor (scroll-focus delivery, the reason the original sendEvent: override existed) and that those events carry cumulative magnification. The local-monitor and sendEvent paths still passed `event.magnification` through as a relative delta, and the |delta|>0.5 sanity guard then swallowed every event once the gesture's cumulative value grew — first "weird absolute zoom", now a dead gesture. A synthetic CGEvent probe could not run (event posting requires Accessibility for the posting process), so the fix uses a delivery-independent rule instead.
   - Changed: new `spdf_normalized_magnify_delta()` discriminates on the event itself — item 62's AppKit disassembly proved raw-converted gesture events NEVER carry a phase, while live gesture-session events always do. Phase-less magnify events are converted cumulative-to-delta; phased events pass through as relative. All three routing paths (global monitor, local monitor, sendEvent fallback) now use it; zero deltas are consumed without routing so no path double-processes an event.
   - Diagnostics: each path logs `path/phase/raw/delta` under SPDF_ZOOM_PROFILE=1. If an out-of-focus pinch still does nothing AND no `inactiveMagnify` lines appear, no in-process mechanism is receiving the events and the next step would be a listen-only CGEventTap (requires Accessibility permission).
   - Validation target: with another app frontmost, pinch over the unfocused window's document viewport (zooms the document) and over the minimap (zooms via the minimap's magnify handling); same with a second ShenzhenPDF window focused. Focused pinch must remain unchanged.

66. Display-list render cache (performance initiative phase 1).
   - Status: Implemented; pixel-identity and regression validated.
   - Prompt link: match Preview/Chromium render speed on big pages (8550 power tree, an ~11000x7500pt vector schematic at page index 10; every viewport crop cost 200-230ms at all zooms).
   - Method: a prototype agent benchmarked mupdf display lists on the exact page (build 88ms one-time/~7MB, replay 14-38ms, pixel-identical, cookie overhead zero); an architect agent designed the integration; an implementation agent built it in a worktree.
   - Changed (core): per-document 4-slot LRU `fz_display_list` cache built lazily on first flagged render; new `_opts` render APIs with `SPDF_RENDER_USE_PAGE_LIST` (legacy APIs are wrappers; shared pixmap-copy tail); region replay keeps the exact crop/ctm/bbox math with a device-space scissor; fail-open to direct rendering on any build failure; list invalidation in all six document mutators; documented one-thread-per-spdf_document contract.
   - Changed (Mac): viewport/pan/sync crop renders pass the flag only for crop-regime pages (full-page-render-disallowed predicate), so the launch/first-paint path is byte-identical by construction. `SPDF_DISABLE_LIST_CACHE=1` kill switch; `renderCrop` profiler lines tagged `list=hit|build|off build=Nms`.
   - Result: page-10 crops drop from median ~153-230ms to median 35.6ms (hits as low as 17ms) after a one-time ~115-157ms per-thread build; ordinary pages unchanged (builds 0-5ms, output pixel-identical by memcmp); self-test histograms and stall counts unchanged on the schematic doc and Sample Datasheet.
   - Validation target: open 8550 power tree, zoom/scroll on the schematic page; content should sharpen near-instantly after the first render; comments/rotation/search/selection on that page must behave unchanged.

67. Abortable renders via fz_cookie tokens (performance initiative phase 2).
   - Status: Implemented; regression validated.
   - Prompt link: same initiative as item 66; in-flight renders (up to ~230ms of mupdf work) ran to completion after logical cancellation, delaying the fresh gesture's renders.
   - Changed (core): `spdf_render_token` wraps an fz_cookie; cancel sets `cookie.abort` (thread-safe plain flag mupdf polls per node). The cookie reaches both display-list replay paths, the direct region render, the list build (aborted builds are never cached), and a token-aware explicit expansion of the full-page path. Canceled renders return 0 with "Render canceled." without fz_throw so nothing hits stderr.
   - Changed (Mac): `SPDFRenderOperation : NSBlockOperation` owns a token; `-cancel` also cancels the cookie, so the EXISTING gesture-start queue purges and generation bumps now abort running renders within milliseconds. All six render enqueue sites converted; canceled renders skip error UI and do bookkeeping cleanup only; newly enqueued visible-crop/pan-crop renders cancel their superseded in-flight predecessor via weak references. No queue topology/priority/suspension/generation changes.
   - Result: 85+ renderCanceled events per stress run on the schematic doc at gesture starts; histograms and stall counts unchanged on both standard documents; crop replay medians unchanged.
   - Validation target: on the schematic page, chain zoom/scroll gestures rapidly; fresh crops should start immediately instead of queueing behind doomed renders.

68. Launch latency: instrumentation, deferral, and dead-stripping (26.6.11-2).
   - Status: Implemented; validated (agent-investigated in a worktree, merged).
   - Prompt link: launch is sometimes instant, sometimes ~1s; make it faster AND consistent; lazy loading suggested; no functionality or viewer-performance changes.
   - Instrumentation: SPDF_LAUNCH_PROFILE=1 logs a full launch timeline relative to process entry (image-load constructor): per-phase applicationDidFinishLaunching marks, per-file JSON loads, per-document session-restore opens with the first-paint render split, and the first document drawRect (= first visible paint). Zero overhead when unset.
   - Findings (8-run medians on a real 12-tab session): warm first paint ~244ms total (dyld+AppKit 58, buildWindow 81, startup doc work 72 incl. 27ms spdf_open + 30ms intentional sync first-paint render). Warm spread <7ms — the instant-vs-1s variance is environmental: (1) the restored ACTIVE tab living on Google Drive pays a synchronous DriveFS stat+read before first paint (network-dependent, the multi-hundred-ms case); (2) one-time Gatekeeper validation after a build/update (+~100ms); (3) pre-fix, savePersistentState ran a full session.lock flock/read/serialize cycle inside buildWindow.
   - Changed: launch now wraps menu/window/startup work in one batched persistent-state save (three pre-paint flock cycles became one, identical bytes on disk; flock-contention window inside buildWindow eliminated); ~70 SF-symbol menu images deferred 50ms past first paint (invisible until a menu opens; buildMenu 9.3ms -> 3.8ms); the app link gains -Wl,-dead_strip -Wl,-x (binary 42.6MB -> 40.7MB, less cold page-in/signature hashing).
   - Not touched (by constraint or by ownership): the sync first-paint render, buildWindow geometry work (determines first-frame layout), AppKit/dyld init, render/cache logic from items 59-67. DriveFS active-tab latency is attributable with the profiler but cannot move off the critical path without changing what first paint shows.
   - Result: warm first paint 244 -> 239ms median; app-controllable worst-case contributors removed; self-test histograms and schematic crop medians unchanged on the stripped binary; session restore byte-identical (12 tabs, selection, geometry, favorites verified).
   - Validation target: cold-boot launch and post-quit relaunch with a multi-tab session; SPDF_LAUNCH_PROFILE=1 attributes any residual slow launch (look for the DriveFS open line).

69. Launch initiative round 2: cloud-async open, deeper deferrals, prerender (refreshed 26.6.11-2).
   - Status: Implemented via four expert agents (cloud-open, lazy-load audit, advanced strategies, integrator); merged and validated.
   - Cold attribution: ~1s "cold" launch is 65-75% pre-main system work (Gatekeeper hashing + dyld page-in: 604-852ms cold vs 5.7ms warm); in-process is ~250ms either way. Notarized distribution is the real fix for that share. The everyday "cold after using other apps" case was the DriveFS active tab revalidating before first paint.
   - Cloud-async open: when the restored active tab is on cloud storage (pathIsOnCloudStorage: /CloudStorage/ or non-apfs/hfs statfs), launch shows full chrome immediately and opens the doc on a background queue, landing through the same restore path with token/tab-identity race guards; local docs keep the byte-identical sync path. Window precedes the cloud open in the profiler; session restore byte-equal.
   - Deferrals: launch-end savePersistentState moved past first paint (resume hook on all termination paths), default-reader prompt/shortcut help/sibling-window spawn post-paint, recents menu lazy via menuNeedsUpdate:, sidebar context icons post-paint; warming barrage waits 350ms only when spawn-to-now indicates a cold launch (sysctl p_starttime).
   - Prerender + trims: a thread at main() entry session-peeks and pre-renders the active local tab before AppKit init, adopted only on exact (path,size,mtime,page,zoom,scale) match (SPDF_DISABLE_LAUNCH_PRERENDER kill switch; cloud paths excluded); buildWindow layout-tail skip; toolbar overflow pass coalescing. SPDF_WINDOW_FIRST=1 opt-in shows chrome at ~106ms (off pending product decision). Rejected with evidence: Metal first-paint (blit is 0.1ms), snapshot-at-quit, threaded JSON/menu loads, linker tricks.
   - Result: warm first paint ~245 -> ~198ms with prerender; cloud-cold launches show the window instantly; self-tests at or above baselines (schematic scrollA 100% lt8, crop hit median 10.05ms; Sample Datasheet 100/100/99.8%).
   - Validation target: launch after long use of other apps with a Drive-hosted active tab (window instant, content lands when DriveFS delivers); File > Recently Opened populates on first click; quick quit-after-launch persists state byte-identically.

## Validation

- Launch state/persistence lane: cached the Mac support-directory lookup, skipped byte-identical JSON atomic writes, skipped unchanged Mac current-window session writes under the same lock/read flow, and deferred GTK favorites loading behind `ensure_favorites_loaded`. Rendering resolution/timing, tab order, scroll restoration, minimap behavior, and session restore semantics were left untouched.
- Formatting: ran clang-format on touched C/C++/Linux files. Mac ObjC files required an explicit ObjC style because the repo `.clang-format` only declares `Language: Cpp`.
- Diff hygiene: `git diff --check` passed.
- Mac syntax: `clang++ -std=c++17 -fobjc-arc -Icore -I../mupdf/include -fsyntax-only mac/*.mm` passed.
- Mac build: `make -C portable mac-app` passed after fixing the MuPDF PKCS7 target and adding a local `.icns` fallback when `actool` is missing.
- Mac install/smoke: installed to `/Applications/ShenzhenPDF.app`, codesign verification passed, and launched the app with `/Users/raph/Downloads/sample-datasheet.pdf`.
- Mac long-document minimap regression: temporary Objective-C++ harness against `SPDFMinimapView` verified a 35-page horizontal viewport drag uses the long-document viewport callback, changes `documentCenterX` from `885.11` to `991.49`, avoids the normal center-drag callback, and sends one finish callback.
- Mac long-document minimap overlay regression: temporary Objective-C++ harness against `SPDFMinimapView` verified the displayed overlay matches page-intersection geometry (`y=6.00`, `h=95.61`) instead of the synthetic drag thumb.
- Mac non-continuous page geometry regression: temporary Objective-C++ harness against `SPDFDocumentView` verified page 1 and page 2 center in an 800 pt viewport, tall pages keep a top margin, and continuous page stacking remains unchanged.
- Mac non-continuous minimap overlay regression: temporary Objective-C++ harness against `SPDFMinimapView` verified synthetic single-page minimap geometry highlights only the current page and scales a partial visible page slice to the expected overlay height.
- Mac installed long-document smoke: launched `/Applications/ShenzhenPDF.app` with the 117-page `/Users/raph/Downloads/sample catalogue 样本目录.pdf`, verified the ShenzhenPDF process started, then quit cleanly.
- Mac installed non-continuous regression smoke: installed `/Applications/ShenzhenPDF.app`, launched `/Users/raph/Downloads/sample-datasheet.pdf`, verified the ShenzhenPDF process started, then quit cleanly.
- Mac installed block-diagram non-continuous regression smoke: rebuilt and installed `/Applications/ShenzhenPDF.app`, launched `/Users/raph/Documents/samples/block-diagram.pdf`, verified the ShenzhenPDF process started, and captured `/tmp/shenzhenpdf-single-page-fix.png`.
- Mac tab-loading regression smoke: rebuilt and installed `/Applications/ShenzhenPDF.app`, launched Sample Datasheet plus Sample Manual, inspected `~/Library/Application Support/ShenzhenPDF/session.json` for multiple tabs, and verified only `/Applications/ShenzhenPDF.app` exists.
- Mac Finder document icon preview correction: rebuilt and installed `/Applications/ShenzhenPDF.app`, verified the installed `Info.plist` no longer has `CFBundleTypeIconFile` for document types, re-registered LaunchServices, reset Quick Look cache, and restarted Finder.
- Mac green-button fullscreen window movement fallback: rebuilt and installed `/Applications/ShenzhenPDF.app`, verified an app-owned Left Half command exits native fullscreen and applies a half-width frame, and the user confirmed the fullscreen shortcut path works.
- Mac PDF vector printing smoke: built and installed `/Applications/ShenzhenPDF.app`, verified the installed binary links PDFKit, and ran a PDFKit print-to-PDF smoke on Sample Datasheet that produced 35 pages with font/text operators (`fonts=146`, `text_ops=3721`) rather than a purely raster page image.
- Mac app uniqueness: after install and smoke, `find` and Spotlight metadata both report only `/Applications/ShenzhenPDF.app` for the ShenzhenPDF bundle id/name.
- Mac launch-performance/hover round: rebuilt and installed `/Applications/ShenzhenPDF.app`, verified codesign, checked `ShenzhenPDF --version`, launched the installed app with `/Users/raph/Downloads/sample-datasheet.pdf`, verified the process started, then quit cleanly.
- Mac static-launch/page-geometry round: rebuilt and installed `/Applications/ShenzhenPDF.app`, verified codesign, cleaned app JSON state with a timestamped backup, opened `/Users/raph/Downloads/sample catalogue 样本目录.pdf`, confirmed `documents.json` stored exact geometry for 117 pages (`pageGeometryLength=234`), relaunched from that saved state to exercise the seeded geometry cache and pre-visible sidebar metadata path, verified the process started, then quit cleanly.
- Mac zoom/page-turn tweak: ran `git diff --check`, Mac Objective-C++ syntax check, rebuilt and installed `/Applications/ShenzhenPDF.app`, verified CLI version/codesign, launched `/Users/raph/Downloads/sample-datasheet.pdf`, verified the process started, then quit cleanly. Manual trackpad validation is still needed for the exact continuous zoom drift and single-page drag threshold feel.
- Mac resident zoom-seed validation build: `git diff --check` passed. The repo `.clang-format` refused `portable/mac/SPDFMacDelegatePrivate.h` because it has no Objective-C language entry. `make -C portable mac-app` passed, the build was installed to `/Applications/ShenzhenPDF.app`, codesign verification passed, and the installed app launched with Sample Datasheet plus `/Users/raph/Documents/samples/test-protocol.pdf` for manual high-zoom/unzoom validation.
- Mac expert-agent zoom hot-path build: `git diff --check` passed. `clang-format` again refused Mac Objective-C files because the repo config lacks Objective-C support. `make -C portable mac-app` passed, the build was installed to `/Applications/ShenzhenPDF.app`, codesign verification passed, and the installed app launched with Sample Datasheet plus `/Users/raph/Documents/samples/test-protocol.pdf`.
- Mac zoom-input-priority build: `git diff --check` passed. `make -C portable mac-app` passed, the build was installed to `/Applications/ShenzhenPDF.app`, codesign verification passed, and the installed app launched with Sample Datasheet plus `/Users/raph/Documents/samples/test-protocol.pdf`.
- Mac session JSON cleanup: moved current state files to `~/Library/Application Support/ShenzhenPDF/backup-20260603-110422-finder-final` before the latest Finder-style session tests.
- Mac additive Finder-open correction: moved current state files to `~/Library/Application Support/ShenzhenPDF/backup-20260603-122509-additive-final`, verified cold Finder-open restores Sample Datasheet plus adds/selects the clicked PDF, corrupt clicked PDF preserves Sample Datasheet only, already-running Finder-open adds/selects, and the installed `/Applications/ShenzhenPDF.app` passes the Sample Datasheet-plus-clicked-PDF case.
- Linux syntax: `cc -Icore -I../mupdf/include $(pkg-config --cflags gtk+-3.0) -fsyntax-only linux/ShenzhenPDFGtkDisplay.c linux/ShenzhenPDFGtk.c` passed.
- Linux build: `make -C portable linux` passed.
- Linux launch-performance round: `portable/build/ShenzhenPDF-gtk --version` returned `Shenzhen PDF portable gtk 0.5` after the deferred-sidebar metadata change.
- Windows build: `bun ./cmd/build.ts` failed on this macOS machine because Visual Studio 2026 `msbuild.exe` is not available in PATH.
- TestFlight readiness: `portable/check-testflight-ready.sh` reports build tools and OpenSSL OK, but Apple signing/provisioning/Transporter are missing.
