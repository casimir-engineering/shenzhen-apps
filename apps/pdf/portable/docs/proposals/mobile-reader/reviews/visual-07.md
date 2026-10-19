# Independent review — visual round 7

Reviewed 2026-09-24: `dark-corrected.png`, `recovery-return-corrected.png`, `history-export-corrected.png`, the associated source snapshot/hash record, and appended root-operated live checks. This critic inspected the rendered images and code independently; live browser actions were performed by root because the critic has no CUA browser surface.

## Score: 9.47 / 10

| Dimension | Weight | Score | Weighted contribution |
|---|---:|---:|---:|
| Product clarity | 25% | 9.6 | 2.400 |
| Technical feasibility expressed by interactions | 25% | 9.5 | 2.375 |
| AI development and reproducible feedback | 20% | 9.6 | 1.920 |
| Storage/reliability UX and truthful state | 20% | 9.1 | 1.820 |
| Accessibility and responsive recovery | 10% | 9.5 | 0.950 |
| **Total** | **100%** | | **9.465 → 9.47** |

## Resolved

**V6 resolved:** the fresh dark screenshot has readable title, Organizer, status, Contents/Find/Switch/More and secondary page text. The container now sets its actual foreground, and relevant hard-coded colors received dark overrides. This closes the major navigation defect.

**V7 resolved:** root's live recovery transition and the inspected screenshot show Latest verified · 18 Sep 2026, no unverified warning, and Find original still available. The no-verified-target case exposes Recovery choices rather than a false verified-return action.

**V8 resolved for History and active reading:** the 18 September row passes an explicit export target; the fresh dialog says 18 Sep 2026 version and root confirmed dismissal preserves History. The already checked 12 September reader export remains separately identified.

## Medium — V8 remains on the unverified-only recovery sheet's direct export

The unverified-only fixture deliberately starts on Groups before opening captured bytes. Its recovery sheet exposes **Save a separate copy**, but that button still calls generic `export`. At that point `older` and `unverified` are false, so the export handler derives “Current readable version” instead of the sole 24 September unverified capture. Root confirmed this exact defect live after the critic identified the source path. It is the same explicit-target defect on another displayed export entry point.

**Required final correction:** make that recovery-sheet button pass the document ID, 24 September revision identity and unverified status explicitly. The dialog must name the captured version and consistency warning without first opening it or changing the active reader. Verify direct recovery export and recheck the already fixed History-row export. Use the final eighth round for this bounded regression, not a wider redesign.

## Minor observation

The dark reader's decorative drop-cap A remains dark teal against the dark paper. The rest of the paragraph and controls are readable. Matching the dark heading/accent color would improve polish; this is not a new medium gate.

## Status

No remaining blocker or major finding. One medium export-identity path remains. Text remains accepted at **9.57/10**. Visual review is **9.47/10** and not yet closed. **Round count: 7 of 8.** Scores still assess a browser design proposal, not native behavior or actual storage savings.
