# Collection settings and search — critique round 2

23 September 2026. Independent UX critique of the revised interactive mockup.

**Score: 9.2/10. Pass for presentation as a design mockup.** This is strictly above the requested 9/10 threshold. Two formal critique rounds were needed.

## Evidence and scope

Visually inspected the round-2 captures in `assets/collection-mockup/`: `search-1024`, `settings-1024`, `title-only`, `location-after-cleanup`, `preview-736`, `preview-focus-736`, `final-history-390`, `final-settings-390`, `settings-light`, and `search-light`. These are browser-rendered mockup captures. The final narrow captures show real viewport content without the round-1 full-page iframe artifact.

Also inspected `final-search-dark.png` and `final-settings-dark.png` after the final copy edits and icon load. Root reported no JavaScript errors and equal root client/scroll widths at the 1024 px viewport.

Root supplied CUA runtime and accessibility evidence. Supporting source inspection checked the final state-echo handling, preview placement, accessible names, unlimited guidance, storage ordering, and location totals. This is not a native application, screen-reader, real-file-migration, or backend-cleanup certification. No ShenzhenPDF app window was launched or captured.

## Findings resolved

- **Preview entry and return:** at 736 px the preview appears directly after the selected document. At 390 px the final historical-hit capture visibly shows the 18 September version, page 4, highlighted context, and focused Close control. Root verified focus survives the host state echo, and Close returns to the exact historical hit. The final result was inspected after host resizing settled; the earlier premature capture was not treated as a pass.
- **Search honesty:** the `maintenance` query explicitly distinguishes a title match with no page-text matches and provides a saved-copy preview action. Ordinary text hits retain page labels, highlighted terms, and enough surrounding text to judge relevance. Empty results recover, additional matches expand, and Latest copies versus All versions remains explicit.
- **Accessible identity:** runtime accessibility output includes document title, capture date, page, and contextual snippet for a hit. Different saved versions can now be distinguished. Expanded-match focus and preview focus/return were verified.
- **Consistent simulated storage:** cleanup cancellation retains 3.2 GB; applying the 2 GB limit removes the reviewed eligible histories and reports 1.8 GB. Set location then reports 1.8 GB. The fictional filesystem listing is gone. Choosing and cancelling a location are honest simulations; Open location does not claim Finder has opened.
- **Policy clarity:** histories are ordered by each history's most recent capture, oldest first. A kept version protects its entire history. Originals remain untouched. The 1 GB case blocks application, states that kept histories need 1.4 GB, and says nothing will be removed. A 0 limit explicitly means unlimited with no automatic cleanup; obsolete blocked-cap guidance is hidden.
- **Persistence:** root verified that the search survives Documents → Search, and that a reload preserves Settings selection and the applied unlimited cap. Pending settings remain visibly distinct from applied settings.

## Visual assessment

The dedicated left Settings destination fixes the original hierarchy problem. Capture, storage, and location form coherent groups. The exact default path is legible; Set location and Open location remain distinct and fit at 390 px. Both light and dark themes keep ordinary text and metadata readable. Search rows use the requested left thumbnail and right context list without reproducing the original manager's dense action column. Narrow layouts preserve their essential identity and actions.

## Remaining ranked findings

- **Major:** none identified within the reviewed mockup scope.
- **Medium:** none unresolved in the final evidence.
- **Minor:** the permanent left navigation still makes long result lists tall at 390 px, although the reduced sidebar/thumbnail widths materially improve reading and the selected preview is now reachable. An optional future compact navigation treatment could improve scanning on very narrow windows. This is a density tradeoff, not clipping, unreadable text, or a blocked action.

The small singular-count and full-width title-preview-button polish noted during verification was corrected in source after the corresponding capture; those edits received syntax verification, not a separate visual claim. They do not determine this score. Sample pages and thumbnails remain illustrations, appropriately disclosed by the mockup; production rendering and real cleanup are outside this proposal.
