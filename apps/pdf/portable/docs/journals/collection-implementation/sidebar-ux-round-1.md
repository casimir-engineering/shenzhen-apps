# Sidebar UX review — round 1

24 September 2026. Independent review of generated native views; no app launched or screenshotted.

## Scope and grades

**Navigation shell: visual quality 9.1/10; usability 8.7/10, provisional.** Group Management content has not been reviewed yet, so these are not whole-feature scores.

Inspected native PNGs: `/tmp/sidebar-nav-review/sidebar-light-narrow.png` (220×620 points), `sidebar-dark.png` (240×620), and `sidebar-short.png` (220×340). These use the production navigation class above a fixture search field and chapter table. The designer reports passing headless checks for 28-point hit areas, accessible labels, stable mode identity when Comments/History disappear, and arrow selection; I also inspected the test source and production navigation implementation.

## Findings

1. **Medium — focused keyboard interaction needs evidence.** Rows draw a rounded focus mask, but the parent still inherits from NSSegmentedControl and accepts first responder. Verify actual Tab entry, parent versus row focus, Up/Down, Space/Return after arrows, and disabled-item skipping. Focus should follow the current navigational choice, and an inherited horizontal segmented-control outline must not appear. This is an unresolved validation concern, not a demonstrated user-visible defect.
2. **Medium — focused search needs evidence.** Existing history includes a previously missed field-editor baseline/focus-ring defect. The unfocused fixture looks aligned; it does not establish focused text, selection and rounded ring behavior in the real sidebar. Capture that state before final grading.
3. **Scope — Group Management still pending.** Show/Hide, current-document identity when hidden, group-name-only filtering, General rename, scrolling, persistence and context actions require separate renders and interaction tests.

## What works

The icon/label rows align cleanly, selected text is semibold, the slate accent fill and slim marker give a clear selected state, and the divider separates navigation from content without a heavy border. Group Management fits the narrow panel without truncation. The dark palette is restrained and legible. The short panel retains approximately 120 points of scrollable content. No cosmetic changes are requested merely to raise the score; the remaining shell requirement is focused interaction evidence.
