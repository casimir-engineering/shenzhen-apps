# Sidebar UX review — round 2, navigation shell

24 September 2026. Independent review of generated native views, implementation and focused test evidence. No application launch or screenshot.

**Navigation shell visual quality: 9.2/10. Usability: 9.1/10.** These grades apply to the navigation component; Group Management and whole-reader integration are still pending.

## Evidence and changes

Inspected [focus and hover](assets/sidebar-focus-hover.png) and [focused search](assets/sidebar-search-focus.png), alongside [light narrow](assets/sidebar-light-narrow.png), [dark](assets/sidebar-dark.png), and [short panel](assets/sidebar-short.png). Reviewed production code and the expanded headless test source. The designer reports `SPDF_SIDEBAR_EVIDENCE_DIR=/tmp/sidebar-nav-review make -C portable mac-sidebar-navigation-tests mac-sidebar-outline-tests` exited 0 with both suites passing. Component and evidence commit: `d35abcebd`.

- The selected row now has a rounded keyboard-focus outline. The parent suppresses inherited NSSegmentedControl focus chrome; the native render contains no legacy horizontal control outline.
- Neutral hover on Group Management is visibly different from the blue/slate selected Chapters row. Icon and label baselines remain aligned.
- Arrow navigation transfers row focus to the new selected row. Space/Return uses the current selection instead of a stale previously focused row. Tests cover disabled-mode skipping and selected accessible radio value.
- The actual AppKit search field editor shows centered selected text, correctly offset after the search icon, and a separate clear control.

The prior focus concerns are closed for the navigation component. The native search field's focus ring is not visible in this hidden-window render; only its editor geometry is visually established. Real whole-window Tab traversal and subjective pointing/scrolling feel are not claimed as tested.

## Remaining scope

Group Management requires its own actual native render and action evidence: group-name-only filtering, hidden/current state, Show/Hide versus activate, rename of General, context controls, scrolling, long names, empty results and persistence. Whole-feature grading waits for that evidence.
