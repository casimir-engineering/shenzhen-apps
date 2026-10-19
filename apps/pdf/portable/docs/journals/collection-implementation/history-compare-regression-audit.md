# History and comparison regression audit

24 September 2026. Verification used hidden native views and focused test binaries; the running application was not launched, stopped, or captured.

## Fixed: History at short window heights

The previous History test still used the old horizontal mode selector. Replacing it with the real five-row PDF navigation exposed an excessive minimum height: a requested 220 × 300 sidebar grew to accommodate the fixed History stack below the 161-point navigation. That conflicts with the reader's supported short window sizes.

History now puts its content in a vertical scrolling viewport. Tall panes continue filling the available space; short panes keep every recovery and version action reachable without requiring a larger reader window. The regression checks the requested host height and scrolls each recovery/action button into view, verifying its full readable bounds.

![History in a short native sidebar; the content below navigation scrolls](assets/history-short-window.png)

## Fixed: hidden History creates work unnecessarily

A restored History mode previously created its controller and requested the Collection store even when the sidebar was closed. It now defers controller creation until reveal. Capture completion still updates the document identity and toolbar metadata, but an existing hidden History panel is marked dirty and reloads when shown. Explicit History commands already request sidebar visibility before rebuilding.

The test exercises the production sidebar category with an isolated fixture store: hidden History makes zero default-store requests, reveal creates one controller, and subsequent visible rebuilds reuse it.

## Validation

- Focused `SPDFMacCollectionHistorySidebarTests`: passed, including version selection, stale-preview cancellation, recovery dispatch, Latest behavior, short layout, and lazy reveal.
- `make -C portable mac-collection-compare-tests mac-collection-reader-navigation-tests`: passed (exit 0).
- `tools/check-file-sizes.sh`: passed, 1,071 maintained files and 35 exact caps.
- Tall and short probe PNGs were visually inspected. The short screenshot shows the initial scroll position; the test separately verifies lower controls can be scrolled fully into view.

No additional concrete comparison regression was found. Comparison preparation remains behind explicit user actions and off the launch path. The independent full native UI suite and final candidate build are handled by the coordinating agent.
