# Whole-reader information architecture

25 September 2026. Source-based inventory and two alternative organizations. Read-only production audit; no app launch or capture. The previous sidebar layout and its review scores are not design assumptions for this pass.

## Starting problem

A reader has three different questions: **which document**, **where in this document**, and **which saved state of this document**. The current interface distributes those questions across grouped tabs, a five-mode sidebar, a mixed toolbar, a global palette and Collection. Shrinking one stack does not resolve this fragmentation.

The actual session reported by the parent’s read-only accessibility inspection has **72 open tabs in four groups; General contains 63**. A six-document mockup would hide the core problem. The workspace must make long lists, overflow and return-to-reading straightforward without turning the page into a narrow preview.

## Inventory: what exists and what scope it belongs to

| Scope | Existing surfaces and behavior | Design implication |
|---|---|---|
| Window/session | Grouped document tabs; rename/recolor/collapse/hide groups; drag/reorder/move to other windows; tab overflow; previous-document toggle. Groups panel projects the same open tabs and groups. | Tabs and the workspace browser must remain two views of one session model, not separate libraries or group definitions. |
| Current document | Page number/count, previous/next page, zoom/fit, Markdown text size, reading theme, document map. | Stable reading controls belong near the page, with the current document identity always clear. |
| Current-document navigation | Chapters and nested outline, chapter filtering, expansion/collapse state. | “Filter chapters” filters headings; it must never look like full-text Find. |
| Current-document search | Toolbar Find, Regex, result counter/arrows; chapter-grouped sidebar results; page/map/scrollbar highlights. Typing-to-find and Cmd+F already exist. | There is one Find query/state. The task pane may edit it; do not add an independent sidebar query beside the existing toolbar search. |
| Current-document annotations | Comments panel and format-specific annotation operations. | Notes/Comments belong to the current document, with clear unsupported or empty states. |
| Current-document versions | History; Latest/original versus immutable saved copies; Keep, Save a Copy, Compare Latest/Previous; missing-original recovery. | A version selection must make the reader’s source/date/read-only state explicit. History is not an app-wide document list. |
| Across the workspace | Cmd+K searches open names, group names, open text and Collection; `col:` restricts it. Open text is live-file text; Collection text belongs to a saved revision. | Keep the fast palette, but label result source and destination. A match against saved content must not silently imply the current original contains that match. |
| Across saved documents | Collection manager: one latest saved copy per document, name/latest-text search, thumbnails/context, All Documents / Originals Unavailable / Kept / Excluded, settings. History actions route into the reader. | Collection is a browsing destination with enough width for results, not another cramped 220 pt sidebar list. |
| Compare task | Separate read-only, paired document views with additions/removals and change navigation. | Keep this focused task separate from ordinary reading, with explicit version labels and a predictable return. |
| Occasional document tools | OCR, translation, print/export, file operations, external Markdown editor. | Contextual document tools, not a permanent preamble ahead of page navigation. Selection tools should appear only with relevant selection. |

Source anchors: [toolbar construction and overflow](../../../mac/ShenzhenPDFMac.mm), [grouped-tab menus](../../../mac/SPDFMacTabStripMenus.mm), [group semantics](../../../mac/SPDFMacTabGroupIntegration.mm), [sidebar workspace projection](../../../mac/SPDFMacSidebarWorkspace.mm), [Find/sidebar integration](../../../mac/SPDFMacSidebarChapters.mm), [palette scopes](../../../mac/SPDFMacCollectionPalette.mm), [Collection layout](../../../mac/SPDFMacCollectionWindowLayout.mm), [Collection-to-History routing](../../../mac/SPDFMacCollectionWindowHistory.mm), [reader History identity](../../../mac/SPDFMacCollectionSidebarIntegration.mm), [comparison](../../../mac/SPDFMacCollectionCompareWindow.mm), [feature inventory](../../../../docs/features.md).

## Shared hierarchy for both alternatives

1. **Document identity:** grouped tab strip and current filename. An archived revision adds a persistent dated read-only indicator and Return to Latest action in the reader, not only in its History panel.
2. **Reading controls:** page navigation and zoom/fit form a small coherent group. View contains theme, layout and Map. Document Tools contains OCR/translation and other occasional operations; unavailable commands explain why.
3. **One task surface at a time:** Workspace, Outline, Find, Notes or History. Each has its own title, explicit scope and only its relevant controls. Do not stack its mode selector above its content.
4. **Collection and Compare have room:** open the existing manager/comparison window, or a deliberately labeled full-content destination with Return to Reading. Prototype one choice consistently; do not make the same click unpredictably open a window in one case and replace the page in another.
5. **Global palette remains the shortcut:** Cmd+K is for finding/jumping across things; Cmd+F is for finding within the displayed document. Search buttons use these explicit scopes.

## Alternative A — a narrow task rail beside one full-height pane

**Recommended prototype to test first.** This preserves persistent vertical icon-and-text destinations while fixing the loss of content height.

- Approximately 86 pt task rail, independent of the approximately 220–260 pt task pane. The reading page occupies the remainder. These are design starting dimensions, not final native sizing claims.
- Rail has two visibly separated scopes: **Open / Collection**, then **Outline / Find / Notes / History** for the displayed document. “Open” means the current open workspace; its tooltip/title can say Open Documents. Do not try to fit “Workspace” into an unreadable narrow single-line row.
- Icon above its short text label gives a complete readable label at 86 pt. Six 42 pt entries,8 pt outer margins and a 12 pt scope break total about 280 pt: all entries can fit the approximately 296 pt minimum available content height. Avoid adding Settings, Tools and duplicate Close controls to that rail.
- The adjacent task pane starts at the top of the reading area, with a compact title/scope line and then its actual list/query. The selected mode consumes no rows inside it. Panel close is in this header; the rail remains reachable.
- **Open** projects the existing group/tab state. Group expansion browses, document activation navigates, hiding a group removes its tabs without closing documents. Group rename/recolor/move operations remain available from explicit menus.
- **Collection** opens the existing full Collection manager in the first prototype. It should not leave an empty task pane while the user wonders where the results went.
- The rail costs horizontal space:86+220≈306 pt compared with the previous 240 pt sidebar. At 1120 pt this leaves roughly 814 pt before Map and separators. At the real 560 pt minimum, it leaves only 254 pt; permanently docking both rail and pane there is not acceptable.
- **Narrow policy:** preserve a useful reading viewport (prototype target 480 pt after optional Map). When opening a task would cross that threshold, show its pane as a temporary overlay over the reading area with an explicit Close/Return; keep the rail and the user’s remembered docked width. Do not silently shrink text, widen the window, or overwrite the saved sidebar width. Map and a task pane must not jointly consume the entire page.

This is a change of organization, not a second narrow navigation column inside the old 176 pt sidebar. Never put 86 pt rail plus 90 pt content into the old width and call it responsive.

### Handling 72 open documents

Open Documents is the complete inventory. Initially expand the active group and reveal its current document; preserve other group expansion/scroll state. General (63) becomes a normal scrollable/virtualized list, not 63 always-visible cards. Show title, a secondary disambiguator when names repeat, and a current-document marker independent of row focus.

Provide **Find an open document** across document names, with an explicit scope control if group-name filtering must coexist. The existing **Search group names** behavior remains available as a separate scope; do not silently broaden it. Results show their group and remain derived from the same tabs. A query must reveal matching documents even in collapsed or hidden groups, with hidden state explicit; opening intentionally reveals/navigates as current semantics require.

The grouped tab strip remains a fast switching surface. It need not display the entire inventory legibly at once. Its overflow should lead to the same complete Open view, not another independent organizer. If the prototype limits the strip to the active group’s tabs, label that change as a proposal and keep group switching, drag/move and all-open access intact.

## Alternative B — a full-width task pane with a vertical chooser

At the top of a single 220–260 pt pane, show the active task name and an icon. Clicking it opens a vertical icon-and-text chooser containing the same two scopes. The pane itself is full height except for this one-line header. Collection still opens the full manager.

This saves the 86 pt rail and gives more width to the page. It also makes changing tasks one extra action and removes the persistent visible tab list. That is a real tradeoff against the user’s earlier preference for vertical icon-and-text tabs; show it explicitly rather than quietly substituting an icon-only rail or horizontal segments. Shortcuts and context entry points (Cmd+F, History from the document menu, Open overflow) still land directly in the task.

Use the same narrow overlay rule. Do not let the chooser be the only way to find hidden tabs or recover the current reading context. Compare A and B with the same 72 documents, current document and minimum window, not different sample content.

## Task flows and return contracts

| Task | Entry → useful state → action | Required return / edge behavior |
|---|---|---|
| Read without managing anything | Open a file → current page, identity and reading controls → navigate/zoom. | Last position restored. Closed task pane stays closed. No collection scan, text indexing or group enumeration added to launch merely for new chrome. |
| Move among 72 documents | Open rail / tab overflow / Cmd+K → search or group tree → choose an actual document. | Same tab identity, same saved place. Selecting a group disclosure does not navigate. Hide does not close. Current document in a hidden group remains clearly identified. |
| Find in the current document | Cmd+F / Find rail → query with “In [filename]” scope → grouped results and page highlights. | One underlying query; existing Regex and previous/next controls remain together. Escape first leaves editing/results as designed, then returns focus to reader. Clearing a query never changes global workspace search. |
| Find another document or saved text | Cmd+K for quick jump; Collection for browsing → labeled Open / Group / Saved-text results. | Preserve browse query/scroll when returning. Saved hit opens the revision containing it or explains source mismatch; no false latest-location claim. |
| Read an earlier version | History → dated revisions for the displayed document → select/open revision. | Reader shows date/read-only state and Return to Latest even after closing History. Latest with missing original remains source-unavailable; a protected copy is not relabeled as the live original. |
| Compare revisions | Select revision → Compare with Latest/Previous → paired read-only comparison. | Labels identify both dates and document. Close returns to the same History selection and reader position. Missing page, unavailable comparison, and encrypted version are explicit. |
| Recover a missing original | Missing-source status beside document identity → Find Document / Save New Copy. | Saved versions remain readable. Exact-content verification and new-copy semantics remain unchanged; a recovery action must not silently replace the wrong document or overwrite the source. |
| Organize groups | Open → group menu → rename/color/move/hide. | One existing group model; group collapse, tab order and YAML persist. Rename General keeps its current special consequences explicit. No second “Collection groups” model is implied. |

## States the full-app prototype must exercise

- 72 documents / four groups / General (63), duplicate titles, long names, selected item offscreen, collapsed and hidden groups, active document inside a hidden group.
- 560×380 minimum window, comfortable 1120×800, dark appearance, task pane closed, rail-only/overlay fallback, optional Map open. Do not show all side surfaces open by default.
- PDF with and without chapters/comments; Markdown with unsupported annotation tools explained; no document open; no saved history; history disabled by choice.
- Find empty/query/no matches/Regex error; workspace name search and group-name-only filter distinct; Collection saved-text result distinct from live text.
- Older revision with History closed, source missing, recovery cancelled, comparison returned, original changed after a saved match was indexed.
- Keyboard entry and return focus for every task; panel chooser/rail labels remain readable and reachable; selecting a list row versus activating a document follows one consistent contract.

## First implementation decision, only after prototype review

Choose A or B and its narrow-window behavior from a full task walk-through before changing production constraints. Then move existing controllers into that shell rather than rewrite their state models. Keep task scope, active document identity, reading return points and lazy work explicit. Native geometry, keyboard and persistence checks follow the chosen structure; no score substitutes for those checks.
