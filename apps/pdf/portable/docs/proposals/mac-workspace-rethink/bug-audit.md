# Sidebar mode availability regression

In commit `6b005c8bc`, the Chapters and Comments rows could remain disabled
after switching documents while Groups or Collection History was selected.
`rebuildSidebar` returned early through `showSidebarWorkspacePanel` or
`collectionShowSelectedHistoryPanel` before it refreshed the per-document
enabled states. A later rebuild on a document with an outline or comments did
not necessarily occur until the user left the workspace panel, leaving the
rows gray even though the selected document supported them.

The fix moves segment and content-availability synchronization ahead of those
early returns. The helper reads the active content model (PDF outline/comments
or Markdown chapters/search), updates modes by their stable semantic tags, and
keeps Markdown's Comments mode absent. Ordinary list rebuilds retain their
existing fallback selection rules.

Headless regression coverage exercises disabled-to-enabled transitions while
Groups remains selected, then checks Markdown's chapter availability and the
production call order before the early-return route. `make -C portable
mac-sidebar-outline-tests` and `make -C portable mac-sidebar-workspace-tests`
pass. `ShenzhenPDFMac.mm` also passes a headless `clang++ -fsyntax-only`
compile. No app was launched.

## Candidate packaging

The reader was built to the isolated path
`portable/build/sidebar-availability-candidate/ShenzhenPDF.app` with an
absolute `DIST` override. Both the reader and nested Collection helper passed
strict signature verification and were arm64 Mach-O executables. The candidate
was copied to a sibling staging path under `dist`; strict checks passed there,
and the reader/helper SHA-256 values matched the candidate. The prior `dist`
bundle was renamed into
`portable/build/sidebar-availability-previous-dba8f16e0/ShenzhenPDF.app`, then
the staged bundle was renamed to `dist/ShenzhenPDF.app`. Final strict checks
passed; `cmp` confirmed both installed executables match the candidate. The
previous bundle remains strictly valid and its reader hash is
`4b24ff24ea0c8673f4fd98d96187b14a30925d1647a4a6e3006edaa339a15840`. No app
was launched, quit or screenshotted.
