# Independent native workspace review

Fresh reviewer, 1 October 2026. This reviewer made no production changes. The interface-design skill informed the review. Scores are human-style visual/interaction judgments, not automated similarity metrics or rewards for passing tests.

## Round 2: similarity 8.9/10; UX 8.8/10

The persistent chrome is substantially closer to the approved layout. This round does **not** yet pass the requested greater-than-9 threshold.

Evidence actually opened: `/tmp/sz-workspace-loop2/reader-light-1280.png`, dark equivalent, light 560 and 880, light/dark Find, light Markdown and version states; `/tmp/collection-polish-pdf-NSAppearanceNameAqua.png` and DarkAqua; Collection settings custom-cap light/dark; `/tmp/palette-polish/NSAppearanceNameAqua.png` and DarkAqua. Reference: latest effective rules in `reader-workspace.fragment.html`, `evidence/lean-tabs-sidebar-icons.png`, and Collection reference. Native images are Retina renders, so dimensions were interpreted in points rather than treating 2× pixels as oversized UI.

### Ranked remaining improvements

1. **Medium — finish outline row sizing.** Selected chapter rows have rounded left corners but are visibly clipped at the sidebar's right edge in the 1280, 880 and 560 captures. The 560 capture also loses all trailing page numbers. The right-hand geometry appears tied to a wider stale table/column extent. Resize the actual outline row/column with the visible panel and preserve both the inset right edge and trailing metadata.
2. **Medium — make source status truthful in older/missing states.** The version capture shows “Older version — … · Original missing” above the document while the footer says “Original file.” These are contradictory explanations of what the user is reading. Derive the footer from actual original/archive/missing identity and verify both an older collected version and missing original.
3. **Verification gap — supply the real History state.** The fixture currently has no History mode in the normal PDF capture; that is reasonable for a document without saved history. However, the request covers the full layout. A real captured-document fixture must show History's rows, Latest state, and actions before the entire interface can be accepted.
4. **Minor — settle the PDF render before final evidence.** The dark1280 image has blank paper and thumbnails, while dark Find contains rendered text. This appears to be capture timing rather than a chrome issue, but the published evidence should not show a transient unrendered document. It is excluded from the chrome score, not ignored as a release artifact.

### Improvements verified this round

- The actual sidebar includes `.pdf` and `.md` while tab labels omit them.
- The chapter hierarchy now has compact regular-size text, muted page numbers, rounded blue selection, and an outline summary.
- Navigation icons have consistent optical size and a separate Groups area. Reading tools are directly exposed.
- Find uses quiet page metadata and highlighted context, rather than the earlier heavy result decoration.
- The narrow reader suppresses the map rather than leaving the document between two dominating columns.
- Collection uses the reference's narrow navigation, bounded previews, metadata/context beside previews, and restrained actions. Apply is directly beneath the storage control before cleanup policy and Location.
- Command search has the compact section/metadata grammar and Esc affordance.

### Scope and limits

Document content, PDF/Markdown margins, user zoom and the working native map renderer are intentionally excluded from similarity to the prototype's fabricated paper/map. No user app was launched, quit or captured. UX assessment covers the supplied production-view renders and inspected code; it is not a live VoiceOver, updater, drag/drop or full end-to-end certification.

## Final round: similarity 9.2/10; UX 9.1/10

**Accepted for the requested chrome review: both scores are greater than 9/10. No major or medium chrome findings remain in the reviewed states.** These scores are bounded visual/UX judgments, not a claim of pixel identity or complete application certification.

Fresh evidence opened: `/tmp/sz-workspace-final/reader-light-1280.png`, dark1280, light560, light/dark History, and light version. The Collection/Settings and command images from the preceding round remain applicable because those accepted surfaces were unchanged. The full native probe log reports `SPDFMacWorkspaceProbe passed`; its layout and state assertions supplement the visual judgment rather than substitute for it.

### Why the grade increased

- The actual chapter surface now ends inside the panel with both rounded corners visible. Page numbers remain visible at560 points. The row cadence now matches the final32-point reference override and fields the final30-point override.
- The older/missing document's footer correctly says “Saved version · Read-only” alongside its missing-original pill. It no longer claims to show the original.
- The real History panel contains multiple saved versions, a clear Latest pill, date/time/reason metadata and unobstructed Compare/Keep/Actions controls. It uses the same direct icon navigation and filename identity as the other modes.
- Light/dark chrome, compact titlebar groups, aligned headers, separate Groups/document controls, inset selection, sidebar filename, Find context and Collection actions now form a coherent rendition of the approved system.
- The native narrow state gives reading space priority without silently discarding a panel preference; this is a reasonable native adaptation of the reference's compact response.

### Ranked minor notes

1. **Minor, visual continuity — History uses a somewhat wider panel and three metadata lines.** The compact reference keeps the usual panel width and groups date/time more tightly. The native design remains readable and usable, including long dates. Reducing the expansion without truncation would improve continuity but is not needed to meet the accepted score.
2. **Minor, native optical differences — SF Symbols and the native fit selector differ slightly from Lucide/CSS.** Their placement, target size and hierarchy now match. Replacing functional native controls only to imitate tiny glyph differences would add risk for little user benefit.

The final scores specifically cover the reviewed reader chrome, Collection browse/settings and command surfaces. Updater integrity, persistence, native input, asynchronous rendering and performance still depend on the separate regression/release checks. No real user window was launched, quit or captured during this review.

### Final evidence recheck

Reopened the exact final files `/tmp/sz-workspace-final/reader-dark-1280.png` and `/tmp/sz-workspace-final/reader-dark-history.png` using `view_image` with original detail. Both now visibly contain the PDF title/body and all three populated map thumbnails. The earlier blank-capture caveat is resolved and has been removed from the remaining findings. Final scores remain similarity9.2/10 and UX9.1/10.
