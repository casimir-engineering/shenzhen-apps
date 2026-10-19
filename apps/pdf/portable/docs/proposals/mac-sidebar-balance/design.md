# Mac sidebar balance — whole-reader direction

24 September 2026. Design study and implementation recommendation. This does not launch, quit, or capture the user's running reader. Existing native evidence is the baseline; the comparison is a code-native layout study, not proof of AppKit geometry. Earlier component scores do not establish whole-reader balance.

Open [the comparison](comparison.html). It compares the whole 1100pt-wide reader, with a fixed document and independently selectable task, theme, panel width and height. The controls inside the mock reader illustrate layout; the study selectors above it work. Production native renders are a separate acceptance gate.

## Diagnosis

The sidebar reads as several independently designed panels stacked together. The navigation, task controls, list rows and History buttons each claim a different scale. No single element is broken; their combined vertical cost and visual weight are the problem.

- The PDF mode control has five 28pt rows, 3pt gaps and 9pt residual space: 161pt before its outer placement. The Markdown four-mode stack is 130pt. This is expensive in the real minimum-height panel, approximately 296pt.
- Groups adds a separate summary/search region, then 48pt group rows and 30pt documents. At 220×340, the saved PDF native fixture exposes only one complete group. The information hierarchy is padded like a preferences pane but lives in a reader sidebar.
- The navigation selection and current document use similarly large blue rounded rectangles. “Which panel is open” competes with “which document am I reading.” Dark appearance makes both rectangles especially prominent.
- Every group title is bold with a second metadata line; indented document titles are also bold when current. Color, indentation, weight and selection all explain identity at once. A shallower text grid and calmer mode selection can do more with fewer competing signals.
- History adds a repeated 15pt heading, up to three filename lines, explanatory text, 82pt versions and five vertical buttons. Its nested scroll regions can present navigation/prose/actions before showing even one revision in a short missing-original state.
- The existing saved sidebar crops cannot alone establish the reader/sidebar proportion. The study therefore keeps the page visible throughout, at the actual default 240pt and minimum 176pt widths; it does not solve density by widening the sidebar.

Source basis: [navigation](../../../mac/SPDFMacSidebarNavigation.mm), [workspace attachment](../../../mac/SPDFMacSidebarWorkspace.mm), [Groups](../../../mac/SPDFMacGroupManagement.mm), [History](../../../mac/SPDFMacCollectionHistory.mm). Native baseline: [220pt Groups](../../journals/collection-implementation/assets/groups-narrow.png), [dark Groups](../../journals/collection-implementation/assets/groups-dark.png), [short PDF](../../journals/collection-implementation/assets/groups-pdf-short.png), [short History](../../journals/collection-implementation/assets/history-short-window.png).

## Three layouts

| Direction | Dimensions and hierarchy | Benefit | Cost / decision |
|---|---|---|---|
| **A. Quiet stacked navigation** | Full-width vertical icon+text modes; 26pt targets, no row gaps, 8pt outer gutters. A thin separator precedes one task region. 36pt group headers, 26pt document rows. | Keeps the page width, familiar navigation, keyboard model and full-width task content. Gives actual information more of the sidebar. | Still spends 139pt on five modes; cannot make a 296pt sidebar feel spacious. **Recommended.** |
| B. Two-column workspace | 113pt vertical text navigation beside 224pt task content; 340pt combined sidebar. | Task content starts at the top and retains its full height. | Costs 100pt more reader width than the default. At the real 176–220pt widths it is unusable. Reject as the default; shown to make the tradeoff tangible. |
| C. Modes at the bottom | Same full-width vertical navigation, below task content. | Puts useful content at the upper-left on entry. | Recovers no height, separates modes from their panel, and moves modes as the window changes height. Reject. |

A changes the hierarchy of the whole sidebar: navigation becomes a quiet persistent choice, the selected task has a bounded header, content is the dominant region, and contextual actions do not grow indefinitely beneath it. It is not a new card treatment or a new sidebar width.

## Recommended A contract

### Shared navigation

- Keep equally readable enabled tab labels (native labelColor) and the existing vertical icon-and-text tabs and all format-appropriate modes. Display **Groups**, preserving the Group Management mode identity, actions and persistence.
- 26pt row targets, no inter-row gap; existing 8pt outer placement. Five rows plus a 9pt divider allowance = 139pt intrinsic height, down from 161pt. Four rows = 113pt, down from 130pt.
- 12pt labels. Use a neutral selected fill and semibold text; reserve the accent for the current content row and keyboard focus. Maintain disabled state, hover, focus rings, arrow navigation and Space/Return behavior.
- Do not change remembered widths, modes, group expansion, query, scroll position, selection semantics or lazy loading. Default240/minimum176 remain supported; Search's separate216 minimum remains unchanged.

### Groups

- Keep group-name-only search in a search-only header:8pt top/side insets,26pt search field,8pt below to table (42pt total). Move the summary into a22pt footer, with info-circle tooltip/accessibility help explaining that hidden groups stay open. No duplicated “Group Management” heading.
- 36pt group rows with 12pt semibold name, 11pt secondary count/hidden/active line and 1pt line gap. Keep the two-line status at minimum width; do not encode Hidden solely as opacity or an eye icon.
- 26pt document rows with12pt text. Use smaller8pt swatch and5pt inter-control gap. Group and document name baselines share a deliberate indentation grid. Plain table style avoids an additional implicit cell inset. For the combined Hidden+Active state, the document count moves beside the group name so both state words remain fully visible at176pt. Disclosure and visibility retain26pt targets and separate behaviors.
- A restrained accent selection denotes the current document. Selected mode is neutral. Hidden groups remain readable. Keep accessible labels. The footer counts remain visible; contextual help explains hiding without occupying a second permanent line.
- At176pt, titles truncate before the visibility control and reveal full names by existing tooltips. Long names must never push an action outside the viewport. Search clear action and keyboard focus must remain usable.

### Chapters, Search, Comments

- Preserve their native content controls and semantics. The shared compact mode region makes more room without inventing new functions.
- Use the same8pt horizontal content grid. The mockups illustrate density and alignment. They are not proof of a live whole-reader layout.

### History coordination

Implemented History direction:12pt semibold filename, muted11pt source line;56pt version rows with the full date on the first line, time and Latest badge on the second, and compact reason/size on the third. This preserves the date even when an always-visible scroller reduces the inner width at the176pt minimum. A primary Compare with Latest action, then Keep checkbox and a labeled Actions menu containing Compare with Previous, Save a Copy and Manage Collection. No function removed.

Missing-original state remains explicit near the filename. Recovery controls remain explicit but follow initial version rows so the short panel first shows that saved versions are available. Selected, empty and missing-original short cases require native evidence. The earlier CSS History scene is retired because it showed no version at minimum height. The comparison now routes History to native evidence; the production contract above is authoritative.

## Review and native gates

1. **Whole-reader design review:** compare A/B/C with identical content at1100pt reader width; A light/dark Chapters, Groups and History; minimum176 and default240;296pt available sidebar height. Judge sidebar/page hierarchy before details. Independent critic establishes criteria; no target score is an acceptance substitute.
2. **Native implementation review:** hidden-view renders of production navigation and Groups at176,220,240; all five PDF modes;340 and296pt heights; light/dark; hidden current group, long names, no matches and keyboard focus. Inspect actual label clipping and table viewport, not just source constants.
3. **Integrated review:** root combines Chapters/Groups/History with whole-reader proportion evidence and focused behavior checks. Preserve all navigation/group action semantics, query/expansion/scroll persistence and zero work when panel is closed. One additional bounded loop addresses material findings.

Required behavioral checks include disclosure without navigation, visibility without closing/changing the current document, Return activation, arrow focus, disabled mode traversal, search scope, clear action, unchanged-refresh field-editor selection and restoration after initial layout. Renders alone do not validate VoiceOver or live trackpad feel.

## Evidence status

Baseline images and source inspected. Comparison syntax checked. Production Navigation and Groups focused tests pass. Native evidence is in [native/](native/). Actual176×296 five-mode fixture retains81pt for the group list and shows two whole groups; first content row starts at193pt. This is headless production-view evidence, not a live-app screenshot. The [presentation gallery](index.html) separates matched native before/after evidence from whole-reader CSS illustrations. Four focused sidebar suites and25 UI integration suites pass. The review journal records the final assessment; this document does not claim live-app interaction validation.
