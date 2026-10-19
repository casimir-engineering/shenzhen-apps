# Independent sidebar balance review — baseline and criteria

24 September 2026. This is a new review of the macOS reader's sidebar as part of the reading layout. Prior component approval scores are not inherited. No app was launched, quit or captured.

**Provisional baseline beauty: 6.6/10. Provisional baseline usability: 6.8/10.** These scores concern the current source and existing isolated native sidebar evidence. A definitive whole-reader score requires the forthcoming matched full-reader compositions; a Collection manager window is not a substitute for the reader.

## Evidence and diagnosis

Inspected production `SPDFMacSidebarNavigation.mm`, `SPDFMacSidebarModeControl.mm`, `SPDFMacSidebarWorkspace.mm`, `SPDFMacGroupManagement.mm`, `SPDFMacCollectionHistory.mm`, `SPDFMacCollectionSidebarIntegration.mm`, chapter controls and coordinator layout. Native evidence includes `sidebar-light-narrow.png`, `sidebar-short.png`, `groups-narrow.png`, `groups-dark.png`, `groups-hidden-active-focus.png`, `groups-pdf-short.png` and `history-short-window.png` under the collection-implementation journal. Those files are Retina renders: pixel dimensions must not be mistaken for point dimensions. Older horizontal-tab History images are not the current navigation shell.

### Major — fixed navigation and task chrome overwhelm useful content

The vertical navigation uses 28pt rows, 3pt gaps and 9pt additional intrinsic height. Five modes therefore occupy **161pt**, plus the outer top inset. Its selected full-width pill, accent stripe and semibold label are prominent before the task content begins.

Groups then adds its own attachment gap, 12pt top inset, summary, 7pt internal gap, 28pt search field, 10pt gap, and a fixed explanatory footer. At 220×340pt, the actual PDF fixture shows **one complete group row**. Chapters can fit more because their rows are 25pt; Groups uses 48pt group rows and 30pt document rows. This is a structural height allocation problem, not a missing accent color or corner-radius adjustment.

**Change needed:** preserve full vertical icon-and-text navigation while reducing its row/gap budget, normalize the content start and horizontal gutter, and recover task height from repeated summaries/help. Evaluate a 24pt/2pt navigation candidate first. Count visible usable rows at the short size; do not accept a proposal merely because every control technically exists in a scroller.

### Major — History repeats context and spends too much space on actions

History introduces a 15pt bold “Version History” heading immediately below the selected History tab, followed by a filename of up to three lines, status, optional recovery actions, 82pt version rows and five vertically stacked buttons. Its outer scrolling content contains the independently scrolling version table. The current 300pt-high fixture reaches only the missing-source explanation and part of a recovery button; **no version is initially visible**.

**Change needed:** remove the redundant heading, make document context compact, use approximately 54–56pt version rows with date/Latest on one line and metadata below, and replace the action tower with a compact primary/secondary arrangement. Keep exact Compare Latest/Previous, Save Copy, Keep and Manage destinations accessible. Preserve recovery as explicit status plus action. At the minimum width, use a deliberate menu/wrap layout rather than clipped button titles. A short-height layout must expose useful version content, not require scrolling through an introductory form to find it.

### Medium — scope and visual hierarchy are flattened

Chapters, Comments, Search and History describe the current document; Group Management operates across open documents. They currently have identical visual hierarchy. Inside Groups, the active mode, active group and selected document can all read as strong destinations. The group headings are 13pt semibold with a second status line, while document content is 12pt. Combined with generous gaps and wide selected pills, the sidebar can compete with the page instead of supporting it.

**Change needed:** use restrained inactive navigation and a single clear current-mode cue. Keep current-document identity distinct from a selected manager row. Preserve visible Hidden/Active meaning, the separate disclosure and eye controls, and the existing navigation behavior. A small scope separator can help if it does not introduce another heading band; an icon-only rail would violate the requested vertical icon+text tabs.

### Medium — modes do not share a content rhythm

Chapters use 8pt attachment/filter gaps, Groups attaches at 4pt then introduces its own header, History attaches at 8pt then adds another 12pt inset. Search's empty state starts with a 14pt heading, explanatory paragraph and button that transfers focus to the toolbar search. These choices work locally, but make switching modes feel like opening unrelated mini-panels.

**Change needed:** one shared shell: consistent outside gutter, content origin and task-header typography. Preserve the existing toolbar Search entry/⌘F behavior and current-document scope. Do not add a second independent search model to make the picture symmetrical. Show empty, populated and no-result Search separately.

### Medium — width changes must be assessed against the whole reader

Current source sets default width240pt, ordinary minimum176pt and active-search minimum216pt. Opening History raises the stored width to at least280pt, but its panel can subsequently be resized. A proposed340pt split navigation/content arrangement consumes100pt more than the default before the page can draw; at220pt, a text navigation subcolumn would leave an unusably narrow content list.

**Change needed:** assess matched full-reader compositions with the same page, window and sidebar width. The best isolated sidebar is not automatically the best reader. Avoid widening the default to hide a density problem.

## Strongest structural options

1. **Preferred: compact full-width vertical tabs above one task surface.** Keep all requested icons/text visible, use lighter navigation and consistent gutters, and put recovered height into actual chapters/results/versions/groups. This preserves the model and YAML state with the least implementation risk.
2. **Comparison only: separated text navigation and task subcolumns at a genuinely wide sidebar.** Show the page-width cost explicitly. Reject this at176–240pt; do not recommend it based on an enlarged sidebar crop.
3. **Comparison only: bottom-docked vertical mode stack.** It brings content nearer the reader toolbar but does not recover its height and increases pointer travel. The short fixture should make that tradeoff obvious. It is not a default recommendation.

No preference for new borders, cards, shadows or accent colors is necessary. The current light/dark palette is serviceable; proportion and hierarchy are the primary defects.

## Review contract for the next two loops

**Loop 1 — compare whole-reader proposals.** Same document, selected item, sidebar width and window size across candidates. Show normal light/dark and a short sidebar. Choose structure before refining pixels.

**Loop 2 — inspect production-view renders and interactions.** Include widths176/220/240/280pt where supported, Search216pt, and content heights340pt plus a comfortable height. Cover PDF's five modes and Markdown's four; Chapters with nesting/long titles; Search empty/results/no matches; History one/latest/older/missing-source; Groups expanded/hidden active/long names/no matches. No clipped controls, nested-scroll trap, unusable truncation or unreadable inactive dark text. Record initial visible rows and first content y-position.

If needed, a final bounded loop addresses specific defects from those renders; do not repeatedly regrade unchanged screenshots.

**Behavior must remain:** vertical icon+text navigation, selected mode and width/visibility restoration, group query/expansion/scroll YAML state, chapter collapse state, hidden-group semantics, keyboard selection versus activation, explicit visibility/disclosure actions, history protection/export/recovery, and lazy loading. No new launch work or controller recreation solely for appearance.

**Beauty grading:** whole-reader hierarchy40%, proportions/density30%, alignment/type20%, light/dark coherence10%. **Usability grading:** useful content/access to actions35%, narrow/short resilience25%, scope/state clarity20%, keyboard/accessibility/state preservation20%. Scores remain separate. A high beauty grade cannot compensate for hidden version rows or inaccessible actions, and correct persistence cannot establish visual balance.
