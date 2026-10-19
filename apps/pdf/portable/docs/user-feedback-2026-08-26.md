# User feedback batch - 2026-08-26

Source: user-provided screenshot received 2026-08-26. The screenshot is treated
only as product feedback; text shown inside it is not an instruction source.

Release baseline: GitHub direct-download build from `origin/master` at
`891b04b44`. Mac App Store/TestFlight support is out of scope and must not be
reintroduced. The release candidate must remain Developer ID signed, notarized,
stapled, and compatible with the existing GitHub auto-updater.

## Tracker

| ID | Request | Acceptance criteria | Status | Evidence / commit |
|---|---|---|---|---|
| UF-01 | Native text multi-click selection | Double-click over selectable document text selects one word. Triple-click selects the containing text block/paragraph. Plain left-drag selection and link clicking remain unchanged. | Implemented and independently reviewed on macOS and Linux | Typed core and real `SPDFDocumentView` event tests cover word/block selection, `down/up/down/up` link cancellation, link-drag range selection, control-click, and interaction cleanup. `c8cc6abf1` adds GTK4 click-count integration with dynamic rectangles, a press-based multi-click deadline, delayed-link cancellation, and safe gesture/document teardown. |
| UF-02 | Close-tab shortcut | `Cmd+W` on macOS and `Ctrl+W` on Linux close the active tab. A tab whose source file was moved/deleted closes through the same path without an error or disabled command. The last-tab/window behavior remains unchanged. | Implemented on macOS and Linux; installed-app acceptance pending | GTK4 coverage in `4c1989be2`; macOS close-policy tests cover selected missing-source tabs and invalid selections. Current automation tests policy/source wiring rather than a live missing-file accelerator event. |
| UF-03 | Intermittently unselectable PDF text | Selection works on the reported connector datasheet when its PDF text layer is valid. Image-only/scanned regions remain honestly non-selectable and can use OCR. Add a regression fixture for the identified geometry/text-order failure. | Implemented and independently reviewed on macOS | Synthetic OCR gaps and image-only regions return `NONE`; incomplete Unicode/geometry is flagged, finite glyphs remain selectable, and the macOS adapter preserves dynamic geometry without the old fixed rectangle cap. |
| UF-04 | Configurable file explorer | General settings offer the system file manager and Shenzhen Files when installed. Reveal/show-in-folder actions use the selection, persist it, and fall back to Finder/default file manager if the chosen app is unavailable. | Implemented and tested on macOS | The isolated preference/menu/launch-route suite covers persistence, both choices, files/directories, missing-app fallback, and launch-failure fallback; the full app build passes. Linux retains its system file manager. |
| UF-05 | Clear tab copy wording | The tab context menu command is named `Copy Document`; it still puts the file URL on the pasteboard and preserves `Copy Path`. | Implemented on macOS and Linux; live clipboard acceptance pending | `4c1989be2` and the macOS menu wiring preserve distinct document-copy and path-copy actions. GTK automation currently verifies the wiring rather than a live desktop clipboard transfer. |
| UF-06 | Correct source tab after detaching | Detaching the selected PDF tab never opens or selects an unrelated text document in the source window. The source window selects the document that was active immediately before the detached document, with a deterministic adjacent-tab fallback. | Implemented on macOS and Linux; installed-app acceptance pending | GTK4 MRU restoration in `4c1989be2`; macOS identity-based MRU/adjacent fallback policy tests pass. A real detach/process interaction remains in the RC checklist. |
| UF-07 | Minimap wheel speed cap | Without modifiers, each discrete wheel notch over the minimap moves at most one document page. Precise trackpad scrolling remains smooth; `Cmd/Ctrl` zoom gestures and minimap dragging keep their current behavior. | Implemented and tested | `ecdbd73d7`; macOS minimap suite and complete GTK4 test sweep pass. |
| UF-08 | Double-click titlebar to maximize | Double-clicking an actually draggable, empty titlebar/tab-row region invokes the native window zoom/maximize behavior. Double-clicking tabs, buttons, and fields keeps their existing behavior. | Implemented and independently reviewed on macOS and Linux | GTK4 behavior landed in `4c1989be2`. The repaired macOS path dispatches real synthetic events through `NSWindow` and the production tab strip: empty background routes once to native drag/zoom while tabs, plus/control regions, traffic lights, and resize corners keep priority. |
| UF-09 | Password-protected PDFs | Opening an encrypted PDF prompts securely for its password, retries after a wrong password, supports cancel, and never persists or logs the password. A successful unlock supports normal reading/search/rendering for that session. | Implemented and independently reviewed on macOS and Linux | Generated encrypted-PDF tests cover plain, wrong-password, user, owner, owner-only, and restricted cases. `a79ea1b07` drives a real AppKit secure sheet through wrong-password retry, success, field clearing, and idempotent cancel. `1ec21d2f0` adds the asynchronous GTK4 prompt/controller lifecycle, transactional watcher refresh, generation-bound workers, and runtime qpdf coverage without persisting credentials. |
| UF-10 | EPUB chapter navigation | Clicking an EPUB chapter reliably navigates to the chapter destination and updates the visible/current page. PDF chapter navigation remains unchanged. | Implemented and tested | `d5cb2965b`; generated nested EPUB outline test passes, including invalid and external targets. |
| UF-11 | Read-only Markdown | Open common `.md` Markdown from Claude/Obsidian; render headings, emphasis, links, block quotes, lists, tables where supported, and fenced code. Code fences use syntax highlighting and expose a supported-language selector when the declared language is absent/unknown. | Implemented and independently reviewed on macOS | MD4C parser/model/renderer/resource and language services pass seven focused suites. `73ab26d08` integrates native Markdown tabs, cache identity, links, state restoration, and language selection into the app; the focused integration suites pass normally and under ASan/UBSan, and the optimized app builds and signs. |
| UF-12 | Markdown language search, print, and PDF export | Markdown appears in the normal tab/session workflow. The syntax-language selector has a narrowing search field and full keyboard navigation. Print and Save as PDF use an A4 portrait pagination model that fills pages while avoiding a section heading in roughly the final quarter when its following content cannot fit. | Implemented and independently reviewed on macOS | Bounded cancellable search, language filtering, TextKit pagination, PDF export, image budgets, descriptor-pinned resources, and smart heading placement are verified. `73ab26d08` connects the services to the native print panel and tab/session workflow, with overlapping search/render generation and atomic-file-replacement regressions covered. |
| UF-13 | Release candidate handoff | All targeted tests pass; each meaningful tested slice is committed. Produce a signed/notarized/stapled DMG without publishing, open the installed DMG app with representative PDFs, encrypted PDF, EPUB, and Markdown fixtures, show the in-app release-notes window, and capture it for user go/no-go. | Release gates complete; full sweep and unpublished artifact pending | `56aa13d51` enforces exact source-size ratchets. `17e301ef4` adds native Markdown integration to the release test target and stages/verifies GitHub assets as drafts before public promotion. The signed/notarized/stapled RC remains intentionally unbuilt and unpublished until metadata preparation and the complete test sweep finish. |
| UF-14 | Shenzhen family application logo | Replace the application logo everywhere with a Shenzhen Files sibling: a blue document marked `深圳` over `PDF`, using a white-to-orange background for product distinction. Cover macOS, DMG, Windows, Linux, dormant AppX/file assets, and documentation branding from one reproducible source. | Implemented; signed-DMG acceptance pending | A deterministic AppKit renderer generates native 16/32/48/64/128/256/512/1024 px artwork. Asset verification covers dimensions, mirrors, Windows ICO frames, AppX, and favicon surfaces; macOS now compiles true 64/512/1024 px renditions. |
| UF-15 | Paginated Markdown and perceived-instant launch | Present Markdown as continuous A4 sheets in the same reader shell as PDFs. H1-H3 headings populate Chapters; Search uses the shared results panel; the existing minimap represents every A4 page and live viewport; page, zoom, keyboard, mouse, presentation, and menu navigation remain shared. Fenced code remains one block and exposes a directly visible language control above it, including when no language is declared. Increase perceived launch speed without visual or behavioral regressions, using lazy loading outside first paint. | Implemented and automated gates pass; installed-app acceptance pending | The canonical attributed-string renderer and exact A4 paginator remain the source of truth. `portable/mac/tests/markdown/fixtures/language-picker-demo.md` is parsed by the test suite and verifies H1-H3 chapters, H4 exclusion, one untyped multi-line fence, whole-block language switching, search, minimap geometry, pointer zoom, right/middle panning, and presentation chrome. Markdown uses the shared document context-menu builder and a tested keyboard policy matching PDF scrolling versus paging. Visible launch work has bounded deadlines; atomic prerender and inactive-tab handoffs prevent late speculative rendering or duplicate opens from blocking selected work. The complete Markdown suites, launch/tab/file/minimap policies, broad macOS/core regression sweep, optimized app build, and strict code-sign verification pass. |

## Validation rules

- Preserve the shipped GitHub updater and direct-download signing model.
- Do not publish, push a release tag, or replace the public GitHub release until
  the user gives an explicit go decision.
- Run focused tests after every slice and the complete discovered test suite
  before building the release candidate.
- Treat visual/manual interaction claims as requiring an installed-app check;
  automate model and geometry behavior where practical.
- Keep Linux parity for shared behavior and shortcuts. Platform-native macOS
  titlebar behavior may remain macOS-specific.

## Session log

- 2026-08-26: fetched GitHub and discovered the original checkout was four
  unpublished YAML commits ahead of the old base and 66 commits behind the
  released branch. Preserved it as `archive/local-yaml-migration-20260826` and
  started `codex/user-batch-20260826` from published `origin/master` at
  `891b04b44`.
- 2026-08-26: first agent wave assigned to product acceptance, text/tab
  interactions, minimap/window behavior, and password-protected PDFs.
- 2026-08-26: committed EPUB internal-outline URI resolution and a generated
  nested EPUB regression fixture as `d5cb2965b`.
- 2026-08-26: committed the one-page discrete minimap wheel cap for macOS and
  GTK4 as `ecdbd73d7`. Precise trackpad input and momentum retain their existing
  paths. The focused macOS suite and all GTK4 tests pass.
- 2026-08-26: confirmed that the sampled connector datasheet contains an
  incomplete Tesseract OCR layer. Selectable OCR text must remain selectable;
  visible raster labels with no glyph geometry cannot be selected without OCR.
- 2026-08-26: clarified the screenshot's search request: it belongs to the
  supported syntax-language picker, not to a second Markdown document-search
  interface. Ordinary document Find remains part of normal tab integration.
- 2026-08-27: release audit selected `26.8.27-1` (no existing tag) and verified
  the GitHub updater contract: exact `ShenzhenPDF-mac-arm64.dmg` asset name,
  Developer ID Team `66LJ4BV7Q3`, bundle ID `com.intuition.shenzhenpdf`, hardened
  runtime, notarization, and a stapled ticket. The unpublished RC will be built
  from a clean detached worktree and will not run the publishing path.
- 2026-08-27: release audit also confirmed stale TestFlight tooling remains in
  the repository despite the product's completed App Store removal. It will be
  removed as an isolated release-tooling slice while retaining the generic
  sandbox guard used against third-party repackaging.
- 2026-08-27: committed GTK4 missing-source `Ctrl+W`, real-file tab copy,
  MRU restoration after detach, and empty-header maximize as `4c1989be2`.
  The complete GTK4 test sweep, including eight new interaction tests, passes.
- 2026-08-27: completed the macOS/core encrypted-PDF security gate. The
  generated qpdf fixture suite, credential/source-identity tests, permission
  source contracts, properties/translation regressions, window-chrome test,
  and full macOS application build pass. Passwords remain process-memory only;
  encrypted OCR is blocked instead of creating a plaintext temporary copy, and
  protected printing uses the authenticated MuPDF path.
- 2026-08-27: completed the macOS native titlebar interaction gate. The pure
  chrome-action test and full macOS app build pass; empty draggable regions use
  native window zoom on double-click, while tab controls retain their own event
  handling. The tab context menu now says `Copy Document`.
- 2026-08-27: completed macOS tab-lifecycle parity. Missing-source tabs keep
  `Cmd+W` enabled, and detaching the active tab restores the most recently
  active surviving tab with deterministic adjacent fallback. The isolated
  lifecycle suite and full macOS app build pass.
- 2026-08-27: added a persisted Settings > File Manager choice between Finder
  and Shenzhen Files. All reveal actions use the selected application, with a
  tested Finder fallback when Shenzhen Files is absent or rejects the launch.
  The implementation is isolated in a 143-line helper and reduces the legacy
  macOS coordinator by five lines.
- 2026-08-27: completed the shared dynamic text-selection engine. Word and
  paragraph/block selection require a hit inside real glyph geometry, while
  OCR gaps and image-only areas return a non-error `NONE`. Generated fixtures
  cover separated columns, multiline blocks, invisible OCR text, large gaps,
  rotation, incomplete geometry, and more than 256 highlight rectangles. The
  focused suite passes normally and under AddressSanitizer/UBSan; macOS and
  GTK event integration remains a separate reviewable slice.
- 2026-08-27: completed the macOS selection event integration. Single link
  clicks wait through AppKit's multi-click interval, while a second or third
  click cancels the pending activation and selects the word or containing text
  block. A real `SPDFDocumentView` event harness covers AppKit's
  `down/up/down/up` sequence, link-drag selection, control-click, `NONE`, page
  replacement, tab replacement, and deallocation. Focused suites pass under
  ASan, UBSan, and ThreadSanitizer; an independent reviewer returned COMMIT.
- 2026-08-27: a clean-snapshot acceptance audit caught that the selection object
  was present in the dirty integration Makefile but absent from committed app
  linkage. `318d0711d` adds the shared object as an explicit app dependency; a
  fresh detached worktree now builds an arm64 app that passes strict code-sign
  verification. The same audit downgraded source-contract checks to their honest
  scope and reopened Linux multi-click parity plus the macOS empty-tab-row path.
- 2026-08-27: strengthened the macOS password UI gate in `a79ea1b07`. The
  AppKit test attaches the real secure sheet to a parent window, submits a wrong
  password, verifies retry controls and secure-field clearing, succeeds on the
  second attempt, and verifies cancel is idempotent. It passes normally and with
  the password/core path under AddressSanitizer and UBSan.
- 2026-08-27: the native Markdown foundation passed independent review after
  three repair loops. The final gate inspected attachment line fragments in an
  A4 export, replaced the document path between parse and render, ran 500
  descriptor lifecycles, exercised the 8 MiB/64 KiB pathological query and
  Unicode/case variants, and repeated all seven suites under ASan/UBSan. First-
  party files remain at or below 458 lines; vendored MD4C matches upstream
  commit `472c417005c2c71b8617de4f7b8d6b30411d78f4`.
- 2026-08-27: repaired the macOS empty-tab-row event path after the acceptance
  audit found the policy helper was not reached by the real view. The independent
  gate dispatched events through `NSWindow` into `SPDFTabStripView`, repeated the
  focused suite 25 times and its ASan/UBSan build 20 times, and confirmed that
  tab reorder/detach and padded control hit regions never enter window chrome.
- 2026-08-27: extracted tab-strip control geometry into its existing focused
  owner in `1f72a8427`, returning the legacy tab view to its exact 1,123-line
  cap without changing the independently exercised event behavior.
- 2026-08-27: removed the obsolete App Store/TestFlight path and committed the
  hardened direct-GitHub release pipeline as `faf75339f`. Prepare and publish
  are separate operations; publication requires committed metadata, a clean
  release branch, the exact signed asset name, and explicit final visibility.
  No tag, push, notarization, or release publication was performed.
- 2026-08-27: extracted Linux updater version parsing and exact relaunch-health
  matching into a 75-line policy module in `033d1cae4`. The focused updater
  suite passes and the legacy updater shrank from 2,441 to 2,369 lines.
- 2026-08-27: committed the independently approved GTK selection ownership and
  gesture policy boundary as `a0815a048`. It retains all dynamic selection
  rectangles, including a 513-rectangle regression case. Live GTK click-count
  and delayed-link integration remains open until the password work releases
  its overlapping document-view files.
- 2026-08-27: committed the independently reviewed asynchronous GTK4 encrypted-
  PDF flow as `1ec21d2f0`. Secure retry/cancel, transactional watcher refresh,
  stale-worker invalidation, permission gates, and qpdf runtime cases pass; the
  credential remains process-memory only and never enters persisted state.
- 2026-08-27: committed native macOS Markdown integration as `73ab26d08` after
  repairing independent search/render/activation generations, repeated-text
  link attribution, and device/inode cache identity. Four integration suites
  pass normally and under ASan/UBSan; the optimized arm64 app builds and passes
  strict code-sign verification.
- 2026-08-27: committed the repository-wide source-size ratchet as
  `56aa13d51`. It scans tracked and non-ignored first-party source, including
  case-insensitive Lua/C-family extensions; 15 bypass-focused self-tests and a
  live 664-file scan pass with 108 exact, reduction-only caps.
- 2026-08-27: committed Linux GTK4 multi-click selection as `c8cc6abf1` after
  an independent review caught and repaired replacement signal ordering,
  press-versus-release deadline accounting, and lost-grab cancellation. Strict,
  sanitizer, focused, and complete GTK4 suites pass; the legacy document view
  remains locked at its reduced 1,793-line cap.
- 2026-08-27: committed draft-first GitHub publication as `17e301ef4`.
  Release assets are uploaded, downloaded, and byte-verified while private;
  upload or verification failures remain drafts, and only an exact asset is
  promoted to final/latest. The release gate now runs both Markdown suites;
  55 release-pipeline cases and all Markdown tests pass.
- 2026-08-27: created a reproducible Shenzhen PDF sibling logo with a blue
  `深圳`/`PDF` document on a white-to-orange field. Native-size visual checks
  preserve the folded-page silhouette down to 16 px. All macOS, Windows, Linux,
  AppX/file-association, and documentation assets now derive from one renderer;
  the macOS build no longer substitutes 48 px for 64 px or upscales 256 px for
  Retina renditions.
- 2026-08-27: started the paginated-Markdown and perceived-launch-performance
  pass. The no-regression boundary keeps the canonical Markdown model,
  selectable attributed text, link and code-language interactions, search
  coordinates, print/export pagination, PDF visuals, and static first frame.
  A virtualized A4 screen surface will consume the existing paginator; zoom is
  geometry-only, page interaction layers are visible-range lazy, and launch
  changes require before/after profiler evidence rather than speculative work.
- 2026-08-28: completed the A4 Markdown reader integration. The existing PDF
  shell now owns Markdown chapters, search results, page and zoom controls,
  minimap viewport routing, keyboard and trackpad input, right/middle hand
  panning, text selection, and presentation mode. H1-H3 are chapters; H4 and
  deeper headings remain document content only. The directly visible code
  language control is screen-only, while print and Save as PDF retain vector
  text without synthetic control spacing.
- 2026-08-28: repaired launch warming around explicit ownership and bounded
  stages. Visible metadata starts independently of input, active-page caches
  follow on a bounded delay, and only inactive tabs wait for idle. Foreground
  loading cancels a speculative open before it starts or adopts the single
  in-flight open; inactive work uses one background worker, checks cancellation
  throughout, and waits for all foreground render queues to become idle.
- 2026-08-28: the final automated gate passed the complete Markdown suites,
  launch/tab/file/minimap policies, window shortcuts and chrome, tab-strip
  interaction, text selection, updater, password, translation, properties,
  core outline/password/selection, the 698-file source-size ratchet, an optimized
  arm64 app build with no compiler warnings, and strict code-sign verification.
  The installed-app demo and unpublished release artifact remain pending by
  design until the final review and commit are complete.
- 2026-08-28: the final independent audit found and drove four additional
  repairs before commit. A foreground launch claim now abandons an in-progress
  speculative bitmap render immediately; selecting an inactive tab atomically
  adopts its one in-flight open; Markdown builds its right-click menu through
  the shared PDF menu owner; and a pure tested keyboard policy leaves Page
  Up/Down and Space/Return/Backspace to native scrolling outside presentation
  mode, while plain arrows use the same 60 fps velocity ramp as PDF tabs. The
  menu and preload state machines were extracted into 104-line and 124-line
  owners, reducing the legacy delegate to 16,742 lines and tightening its
  no-growth cap.
- 2026-08-28: visual acceptance against the installed notarized candidate
  confirmed the five-sheet A4 demo, H1-H3 Chapters hierarchy, shared map, and
  untyped-fence language selector. It also caught insufficient breathing room
  before the first code line. Screen pagination now reserves 34 points for the
  22-point selector, while print and PDF export keep their unchanged vector
  layout with no screen-control spacer.
