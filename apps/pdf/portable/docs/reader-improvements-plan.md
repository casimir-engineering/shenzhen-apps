# Reader improvements — implementation plan

Scope agreed 2026-09-22. macOS implementation; retain the shared document core
and existing state formats. No release publication is part of this work.

## Work streams

- [x] Persistent tab groups: model, layout, menus, drag/drop, whole-group
  detach/reattach, palette, and backward-compatible session restore.
- [x] Markdown table widths: prevent short headers and cells from being
  squeezed into character-by-character wrapping.
- [x] Markdown paper controls: author-specified paper size, orientation,
  margins, and explicit page breaks, shared by screen and export.
- [x] Agent inspection: deterministic JSON layout reports and page PNGs using
  the native Markdown and PDF engines; stdio MCP adapter and a headless CLI.
- [x] Agent navigation: open a document at a page, populate search, and reveal
  a passage distinguished by surrounding context.
- [x] Markdown Open in Editor: document/tab menus, remembered editor, Settings.
- [x] Context-page copy: PDF and Markdown copy the page under the pointer;
  ordinary menu actions use the current page.
- [x] Integration, regression tests, launch-laziness checks, documentation,
  final app build and visual verification as needed.

Already shipped and excluded from new changes: Markdown page numbers,
whole-document translation, and backup before Delete All Text.
The radial tab/group switcher remains a subsequent backlog item.

## Tab group contract

The first custom group places remaining tabs in General. Group names are
shown only when collapsed; unnamed groups use their color's name. The group
contour follows the tabs' rounded corners. Inactive tabs retain the group tint;
the selected tab uses a deep accent fill, near-white text and a stronger outline.
General uses neutral gray and charcoal. A single fold control sits on the left.

Right-click a tab to create or join a group. Dragging over a tab center previews
grouping; edges retain insertion/reorder behavior. Drag the group separator to
reorder the group or move it into another/new window. The group menu puts the
color choices directly beneath Rename. Rename, color, collapse, ungroup, and
close are available without dragging. Selecting a group collapses all other
groups, including General.

Persist group identity, name, color, order, collapsed state, last-used tab, tab
membership/order, and all existing reading/window positions. Transfer the same
state when moving groups between processes. Old sessions without groups must
continue to load. Ordinary ungrouped tabs must not allocate group state.

## Agent architecture

Explicit CLI requests enter before application/delegate construction. Native
inspection uses the same parser, renderer and pagination plan as the reader.
An optional Python standard-library MCP adapter invokes that CLI over stdio;
it does not run when the reader launches and opens no network listener.

Live navigation is delivered on demand through a private command document and
the existing external-file-open path. Requests and responses are bounded and
validated. No startup polling or background agent service is installed.
Document text and report strings are data, never executable instructions.

## Verification

Use focused headless regression suites, state round trips, cancellation/error
cases, and source-contract checks for lazy integration. Check exit codes.
Keep source files within the ratchet by extracting focused units. Commit each
tested work stream with explicit paths. Run the integrated suites and build
the final application; do not replace or terminate the owner's running app.

## Delivered and verified

Markdown engine and integration suites pass, including authoring geometry,
screen/export agreement, disk reload, and navigation readiness. Focused native
suites cover grouping, interaction, persisted state, transfer, pointer-page copy,
editor choice, command validation, navigation ordering, and PDF inspection.
MCP protocol tests cover discovery laziness, input bounds, and tool failures.
The application builds locally; page images and native tab-strip probe renders
were checked headlessly. No installed app was replaced or restarted.

Setup and command examples: [agent interface](agent-interface.md).
The radial group switcher remains in the backlog as agreed.
