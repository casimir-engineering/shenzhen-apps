# Native workspace UX critic

## Loop 1 — 1 October 2026

**UX: 7.8/10. Not accepted against the requested >9/10 threshold.**

This independent review uses the interface-design, macOS design guidelines and Rams review criteria. Evidence is the production-view offscreen PNGs in this directory, the approved `reader-workspace.fragment.html`, and the native layout/interaction code. No running user application was launched, quit or captured. Static visual/source review cannot establish a full VoiceOver or live updater result.

The approved intent is a compact reader for many grouped technical documents. The document remains primary; stable tab geometry, direct tools and one restrained navigation panel support it. The native implementation has the broad structure, sensible compact targets, persistent mode identifiers and accessible icon labels. It does not yet reproduce the sidebar's typography, list rhythm or clarity of actions closely enough.

### Ranked improvements

| Rank | Severity | Finding and evidence | Required correction / acceptance evidence |
|---|---|---|---|
| 1 | Medium | Filename can omit its extension despite the probe fixture showing one. `SPDFMacWorkspaceChrome.mm` currently prefers `selectedTab.title` to `path.lastPathComponent`. A user-facing title need not be a filename. | Resolve the displayed filename from the document's source identity, including archived previews. Test an extensionless custom title with a real `.pdf` path and an archived temporary payload whose original display filename ends in `.md`. Keep full text available to accessibility and hover help. |
| 2 | Medium | Collection's Apply is at the bottom after Location (`SPDFMacCollectionWindowSettings.mm`). It changes storage cap only but visually appears to submit all settings. The distance obscures pending changes and violates the user's explicit placement request. | Put Apply and its pending/applied feedback immediately below the storage-cap input, inside the Storage section. Location remains independent. Verify at the smallest supported settings size with custom limit, unlimited and pending changes. |
| 3 | Medium | The native chapter list feels like an unchanged source list: 13-point text in ~25-point rows, no trailing page numbers, edge-to-edge system selection; the prototype uses 12-point text, 32-point rows, an inset rounded muted selection and trailing page numbers. See `native-reader-light-560.png` and `lean-tabs-sidebar-icons.png`. | Match that list grammar while retaining real nested disclosure, comment wrapping and chapter state. Render selected and unselected chapters, deeply nested outline, long titles and PDF page numbers. Do not fake page numbers for Markdown if unavailable. |
| 4 | Medium | Sidebar and reading controls are visually smaller and less consistent than the mockup. Sidebar icons are explicitly rendered14×14 with13-point symbol configuration; prototype icons are16×16 inside28-point targets. Toolbar symbols rely on heterogeneous existing defaults. | Use a consistent16-point optical icon system within existing28-point targets, preserve clear enabled/disabled contrast, and keep the Groups divider. Inspect both appearances and the full document-tool row rather than only target rectangles. |
| 5 | Medium | At560 points, two permanently reserved side columns leave only~235 points of reading width and fit-width at39%. The left panel/table, direct toolbar and real map technically fit, but the reading task becomes a sliver. | Provide an explicit responsive strategy consistent with the prototype's overlay sidebar, without changing saved visibility, map rendering or reading positions. At minimum demonstrate narrow reading with each panel toggled and avoid simultaneous sidebar/map domination; no silent permanent preference changes. |
| 6 | Minor | Native footer repeats page position on both ends (“Page1 of3 · Zoom155%” and “Page1/3”) whereas the prototype puts source/protection state at left and page position at right. | Remove redundant page text in the left status, retain useful zoom/source information, and surface meaningful Collection protection only when accurate. |
| 7 | Minor | Native Find results have a heavier, cramped hierarchy than the quiet prototype. This is visible in `native-reader-light-find.png`; repeated bold snippets dominate the metadata and chapter group labels. | Keep actual matching spans emphasized, quiet the rest, align item insets with chapters and use a clear selected result. Preserve multiline comment/search behavior. |

### What already works

- Compact selected tabs, visible group labels and a continuous accent underline form a understandable hierarchy.
- The group control is separate from document tools. Direct tooltips and accessibility names exist.
- Top-level panel/reader/map headers align. Real map content is retained; its thumbnail geometry is not scored against the nonfunctional mockup.
- Collection's document row composition and command search's compact sectioned result hierarchy are substantially closer to the prototype than the chapter list.
- File rendering, PDF page margins, source content, map thumbnail rendering and the user's chosen document zoom are outside this visual-fidelity score. The prototype's fake paper should not replace those systems.

### Required next loop

Supply fresh native offscreen evidence for a regular reader, selected/nested chapters, narrow reader, Find, Collection Settings with pending storage change, and extensionless-title/original-filename cases. Regrade only changes actually visible or behavior asserted; do not count source-test success alone as improved visual quality. This score does not certify updater safety, which requires the separate release/updater regression suite.

## Read-only implementation notes — responsive panels and filenames

The current reader has no responsive panel collapse: it clamps sidebar width to34% of the window (176-point minimum;216 with search), while the map independently retains its width. At560 points this combines two valid panels into an unusably narrow document area.

The smallest safe alternative to reparenting the sidebar as an overlay is a transient compact-panel priority. Calculate effective reading width after requested panels. If it falls below320 points, show the currently requested navigation panel and temporarily suppress the other. Default to the sidebar because that is where the active navigation/search task occurs. Explicit Show Map gives map priority; Show Sidebar, Find, Groups or History gives sidebar priority. When sufficient space returns, restore both user-requested panels. These are effective layout decisions only; do not change persisted visibility, panel widths, group/document identity or reading positions. The Show Map action must inspect actual visibility: its current implementation toggles preferred visibility, so a map hidden only by layout would otherwise require two clicks to reveal.

Before adding that rule, stop overwriting preferred width during resizing. `restoreSidebarWidth` currently writes its clamped result back to `_sidebarWidth`; `savePersistentState` clamps again using the current window. Keep a local effective width in restoration and sanitize the stored preference independently of current viewport size. Guard temporary panel suppression from the existing sidebar-width persistence path. Explicit divider drags may continue to change the preferred width.

Collection has sufficient filename metadata already. Captured versions contain `filename` (original basename including extension); the document contains `title` and `path` (updated when relinked). Materialized copies are named after `version.filename`, under per-document/per-version directories. The tab's `title`, by contrast, can be changed into an archival status string with the extension removed. The sidebar should use the live path basename, or archived version filename obtained from the already-cached version-info dictionary. Do not instantiate or load Collection from a generic toolbar refresh solely to obtain the display filename. Date/status remain in the version pill, not in the filename.
