# Sidebar UX review — round 3, first integrated Group Management

24 September 2026. Reviewed production navigation and Group Management in hidden native-view renders. No application launched or screenshotted.

**Integrated visual quality: 8.8/10. Usability: 8.7/10.** The navigation component remains approved from round two; these grades account for the new panel content and its remaining issues.

Evidence: `/tmp/group-management-review/groups-narrow.png` (220×640 points), `groups-dark.png` (280×640), and `groups-short.png` (220×340). The controller supplies the actual rows and actions, rather than a painted mockup. Designer-reported headless checks cover group-name-only filtering, eye/disclosure without navigation, saved scroll restoration and active-document selection.

## Ranked findings

1. **Medium — selection is clipped at the trailing edge.** The selected document highlight has a rounded leading edge but a squared/clipped trailing edge in both themes. This violates the otherwise consistent rounded contour. Correct table/row width and clipping, not just the apparent corner radius. The designer independently identified this and is fixing it.
2. **Medium — short-height content is crowded.** At 340 points tall, navigation, summary/search and a permanent two-line footer leave only roughly one and a half group rows visible. A one-line “Hidden groups stay open.” explanation, or an adaptive shorter treatment, would return space to the scrollable list. Preserve usable hit targets.
3. **Validation — state and keyboard edge cases remain.** Need actual long-name and hidden-active rows, no-match search, and keyboard activation evidence. A row highlighted by keyboard focus/selection should not misleadingly imply its document has become active unless navigation actually occurred.

## Positive findings

The full-width content is substantially clearer than a separate options column. Group color swatches, consistent disclosure controls, aligned eye actions, member indentation and status lines explain structure. The strongest selected fill belongs to the active document; all normal rows remain quiet. The visible Group Management navigation keeps hidden groups reachable. Search explicitly targets group names. Light and dark palettes remain consistent with the approved navigation shell.

## Behavioral evidence received

The model/integration agent reports exit 0 for `make -C portable mac-tab-group-tests mac-tab-group-interaction-tests mac-agent-group-tests`; the tab-strip and agent suites also passed earlier. Coverage includes hiding the active group without navigation, explicit jump unhiding it, General promotion on rename, new-document creation of General, all-hidden recovery, codec roundtrips and close/reopen/ungroup edge cases. Full session-YAML restoration remains the coordinator's separate integration responsibility. These results support the semantics; they do not substitute for the missing native visual states above.
