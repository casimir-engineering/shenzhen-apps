# Sidebar UX review — round 4, integrated approval

24 September 2026. Independent review of actual production controls in hidden native-view renders and headless interactions. No launch, quit or screenshot of the user's reader.

**Visual quality: 9.2/10. Usability: 9.2/10 for the exercised component states.** Both exceed the requested target. The grades describe this bounded design review; they are not a claim of exhaustive real-app usability testing.

## Evidence

Reviewed the permanent native evidence: [narrow light](assets/groups-narrow.png), [dark](assets/groups-dark.png), [short Markdown](assets/groups-short.png), [hidden active group and long name](assets/groups-hidden-active-focus.png), [no matching groups](assets/groups-no-matches.png), and [short PDF](assets/groups-pdf-short.png). Component/evidence commit: `fe8866ad7`. These instantiate the production navigation and Group Management controllers. Production and test source were also inspected. Confirmed the final log for `SPDF_GROUP_MANAGEMENT_EVIDENCE_DIR=/tmp/group-management-review make -C portable mac-group-management-tests`: compile and `SPDFMacGroupManagementTests` passed (exit 0 reported by the designer).

## Prior findings closed

- **Rounded selection:** the selected document's trailing corner is now fully visible and matches the leading corner in both themes. Table width follows the clip viewport. The current document also has a filled accent document icon and semibold title, so its reading identity is distinguishable from a merely selected row.
- **Short-height density:** the permanent explanation is one line, “Hidden groups stay open.” The short fixture now displays two group rows, with scrolling for the rest. Hit targets retain their size.
- **Hidden and current state:** the narrow fixture clearly displays “2 · Hidden · Active” beside a hidden active group. Its documents remain visible in the manager, and its current document remains highlighted. Show/Hide and disclosure retain separate aligned controls.
- **Long names:** the name truncates at the text boundary rather than displacing the eye action; the full name remains in its tooltip. Group-targeted accessible labels identify which visibility/disclosure action will operate.
- **Search scope and empty state:** searching a member filename produces no group matches, as requested. The native empty state says “No matching groups. Try another group name.” The query and clear action remain visible.
- **Keyboard semantics:** headless controller checks cover selection without navigation, Return activation independent of stale clicked-row state, and eye/disclosure actions without a jump. Navigation shell focus/arrow/Space/accessibility checks are recorded in round two.

## Why the design meets the target

There is one consistent hierarchy: selected navigation, group summary/search, color-coded group rows and indented documents. Neutral inactive controls, restrained accent selection, aligned icons/text, rounded contours and one-line status summaries hold together in light and dark appearances. Group Management remains reachable when tabs are hidden. Hiding, opening, expanding and renaming have separate meanings; a hidden current document is not concealed from the manager.

No unresolved material visual issue remains in the reviewed states. The remaining scope is integration verification, not another requested visual redesign.

## Explicit limits

The hidden-window search editor render establishes centered text and clear-control geometry; it does not visibly show AppKit's native key-window focus ring. Rounded focus-mask code is present. Real whole-app Tab traversal, VoiceOver speech and subjective trackpad feel were not exercised. Session-YAML roundtrips and final reader build remain separate coordinator checks; group model/codec tests support, but do not replace, those checks. The PDF five-mode 340-point panel was also inspected: one complete group row and its controls remain visible, with scrolling and no overlap. This is an intentional density tradeoff of the requested full vertical navigation at that short height.
