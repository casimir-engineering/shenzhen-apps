# Native/prototype similarity review

Independent critic: similarity review, 1 October 2026. This is a visual judgment, not a test pass count. The approved reference is the latest effective CSS and markup in `reader-workspace.fragment.html`, supported by `evidence/lean-tabs-sidebar-icons.png`, `stable-tab-title-fade.png`, and the Collection reference. Obsolete double-panel and oversized-tab designs are excluded.

## Loop 1 — baseline: 7.7/10 overall similarity

**Reader/sidebar: 7.4/10. Tabs/titlebar: 9.0/10. Collection browse: 8.9/10. Command palette: 8.9/10.** The result does not meet the requested >9/10 bar. The native composition moved in the right direction, but the sidebar still visibly belongs to the old app. Reader/sidebar is weighted most heavily because it is the persistent interface.

Actual offscreen AppKit images reviewed: native reader light/dark at1280, narrow560, Find, Markdown; Collection light/dark; command palette light/dark. These were opened as images rather than inferred from code. Native command images are2× raster scale for a550-point palette; apparent raw-image text size is not a defect.

### Ranked improvements

1. **Major — bring sidebar content into the approved visual system.** Native chapter text is13pt in25pt rows, versus12px in32px rows in the final prototype. It appears larger/heavier and more cramped. Native selection is a square, full-width gray band in the narrow image; prototype selection is an inset rounded blue row. Native sidebar has no right-aligned page numbers and no outline summary at its foot. Use12pt regular titles, the approved row rhythm, inset rounded selected/hover surfaces and trailing page metadata. Preserve actual heading text and nesting; do not invent numeric prefixes that are absent from the document. Restore a quiet outline-count footer.
2. **Medium — restyle the Find result hierarchy.** Native results retain the old group-pill/line decoration, medium-weight snippet above metadata, and bold-only search matches. The reference has small page/chapter metadata above normal-weight context with a yellow match highlight. Reuse the actual search data and navigation; change presentation only. This is visible in `native-reader-light-find.png` against the panel implementation in the reference.
3. **Medium — fix the sidebar document identity in real data, not just fixtures.** Probe images show extensions, yet `syncWorkspaceChrome` takes `selectedTab.title` ahead of the path filename. A prettified title can therefore omit the extension. Prefer actual source/display filename with extension, including collected documents. Add an extensionless-title/full-path case to the probe rather than trusting its conveniently full title.
4. **Medium — match sidebar search-field shape and density.** Native field has the older shallow capsule appearance; the reference uses a30px-high rounded rectangle with7px radius,12px insets and a quiet inset surface. Align Chapters and Find field sizes, search icon baselines and focus appearance. Keep a visible rounded focus ring.
5. **Medium — put Collection Apply immediately below Storage.** The existing production settings builder puts Apply in the final footer below Location. This breaks the user's explicit requested association. Move it into Storage before Location and inspect a native settings image, including a narrow layout and unlimited/capped state. No current native settings image exists in the reviewed evidence.
6. **Minor — normalize icon optical weight and tint.** Native sidebar symbols appear smaller/fainter than the16px reference icons, and toolbar icons have varied weights. Sidebar source uses13pt SF Symbols. Match the reference's perceived16px optical size and shared primary tint while retaining genuinely disabled controls. Keep the separated workspace/document control groups.
7. **Minor — match the command palette close affordance.** Native has a bare X where the reference has an Esc label. The overall550-point width,30-point rows, section labels and right-aligned metadata are otherwise close. Use an Esc-labelled accessible close control if seeking literal fidelity. Retain native text-match context, which is useful additional information.
8. **Minor — Collection chrome details.** Browse layout is close:125-point navigation,65×88 preview,14-point result gaps and action buttons match. Real thumbnails should remain real; they need only the reference's subtle boundary in light mode so white pages remain visible. Native header has a larger leading offset for window traffic lights; this is a platform accommodation, not a reason to draw fake traffic lights inside content.

### Explicit exclusions

- Document content, PDF page proportions, original document theme, and preserved zoom/margins are not chrome similarity defects. Do not shrink pages or change Markdown margins to imitate a fabricated page in the mockup.
- The native working map must remain a real map. Its thumbnail width, rendering and viewport rectangle are deliberately not scored against the mockup's numbered decorative rail.
- Native macOS traffic lights sit outside the offscreen content capture; their absence is not a defect.
- History availability must be checked using a captured document fixture. The baseline uncaptured fixture has no History button, so this image alone cannot establish that History is missing in production.

### Next-loop evidence required

Fresh reader light/dark, Chapters with selected row and page metadata, Find with highlighted contexts, Markdown filename, real History, Collection Settings showing Apply directly under Storage, and command palette. Verify a real production-built view, not a static replica. A source-only change or passing behavioral test cannot raise this visual grade.

## Implementation follow-through before loop 2

The parent assigned the sidebar changes back to this reviewer after the baseline report. This reviewer therefore does not claim independence for its later assessment of those specific components; the separate UX critic should cross-check them.

- Extracted legacy Find cell rendering from the coordinator into `SPDFMacSidebarPresentation`. Its pure view builders preserve result identity/actions while putting muted metadata above regular two-line context, retaining highlighted query ranges and full context in tooltips.
- Chapters retain actual heading text and disclosure nesting; titles use12pt regular type in32pt rows, with right-aligned one-based page metadata. The shared row view draws an inset rounded selection in the same theme tokens as the reference.
- Added the total-outline summary accessor for the parent-owned footer; filtering and collapsing do not rewrite the document's total heading count.
- First integrated visual rerender exposed clipped right selection corners and missing trailing page labels at narrow widths. The old sizing routine updated only the column width, leaving the table document view wider than its viewport. The extracted sizing helper now keeps both widths synchronized, disables the conflicting column autoresizer, and avoids comment-height work when the viewport is unchanged.
- Focused presentation tests instantiate real offscreen AppKit cells at176/240/400pt and verify metadata/context order, text insets, wrapping, safe highlight ranges and unchanged font metrics. Table resizing300→176→240 verifies viewport/document/column agreement. `mac-sidebar-presentation-tests` and `mac-sidebar-outline-tests` exit0. These checks do not launch or capture the user's app.

### Reference correction

The first critique incorrectly read the earlier36px chapter-row and32px field rules without applying the later overrides at lines139–141. The effective contract is32px rows and30px fields; implementation and this report now use those values. This correction does not change the baseline conclusion that the native25pt rows and old field treatment were visibly different, but it prevents introducing new spacing drift while fixing them.
