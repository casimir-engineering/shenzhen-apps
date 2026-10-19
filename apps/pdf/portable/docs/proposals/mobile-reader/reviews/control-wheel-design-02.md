# Independent review — controls-only wheel implementation and study

24 September 2026. **Design/prototype score: 9.35/10. Native implementation and participant usability: ungraded, not yet tested.** The rejected document-switching wheel and its earlier scores provide no credit toward this assessment.

The corrected proposal satisfies the central interaction brief in the inspected browser model: start directly on Tools, keep the same contact down, pass through a reader-control family, choose a command, and release once. There is no preliminary tap or hold timer. No document switcher, Group or Collection destination appears in the wheel. The optional parameter continuation can choose a zoom/page value during that same contact; releasing over the ordinary parameter leaf instead opens an explicitly separate numeric editor.

## Scope and evidence

Reviewed `control-wheel-study.md`, the retired-alternative markings in `control-wheel-comparables.md`, the study wrapper, and `command-wheel-state.js`, `command-wheel-ui.js`, `command-wheel.js`, CSS and HTML. The live sample is an unlocked text PDF illustration. Its 48 slots are command routes, including visibly disclosed unavailable or placeholder operations; they are not 48 functioning native PDF tools.

The child reviewer could not open an IAB browser (`Browser is not available: iab`). I independently inspected source, ran the reducer tests, reproduced the sparse-event regression, and inspected root-provided actual browser PNGs. Root's live interactions are attributed evidence, not interactions I performed. Inspected images include the final 360px family, Zoom, Notes and Document fans, 200% list, the scrolled 200% list, 320px narrow-layout fallback, the final 844×320 short landscape fallback, and the earlier parameter rail. The obsolete screenshots showing the trace obstruction and landscape failure are evidence of corrected defects, not the final appearance.

The revised suite passes **34 tests, exit 0**, including source/ownership cancellation, second contact, off-fan release, frozen inventory, parameter preview/commit and layout availability. My separate reproduction feeds the identical cross-fan straight segment once and in 30 increments: both now select Document → Information and commit `info`. Tests prove this reducer's behavior, not native event delivery. Root also verified that Zoom in at 200% stays at 200%, Adjust starts at 200%, and the large list scrolls without horizontal overflow.

## Corrections verified during this review

| Original finding | Corrected behavior / evidence |
|---|---|
| **Major:** a sparse segment missed the inward 62-unit retreat, while dense delivery of the same path switched families | The reducer processes the inward crossing and subsequent outward 90-unit crossing. Sparse/dense parity passes independently. An arc outside the retreat band preserves the original family. |
| **Medium:** Zoom in could reduce 200% to 150%; Adjust reset to 100% | Steps are relative and bounded. The editor starts with current numeric state and validates a number before applying it. Fit modes use the explicitly simulated numeric baseline; this is not native fit-scale verification. |
| **Medium:** short/narrow layouts still attempted the full fan | Shared availability logic rejects width below 360 CSS pixels, insufficient vertical room, and the 200% text scenario. The notice explicitly says the continuous gesture is unavailable and exposes the list. |
| **Medium:** a 390px CSS minimum could defeat the short-height availability rule | The minimum was removed. Root measured the actual phone at 320px high in an 844×320 viewport; the final screenshot shows the explanatory notice and reachable List above the system strip. |
| **Medium:** diagnostic/footer layering cut through the fan | Final PNGs show unobstructed sectors and labels. The diagnostic strip is hidden while active without changing the control origin. |
| **Medium:** disabled hover had no reason; parameter continuation was undiscoverable | Disabled candidates remain visible without committing and produce a reason. Adjust/Page expose a continuation caption and dashed gate. |
| **Medium:** the list's Tab trap included buttons hidden inside collapsed sections | Final source filters non-rendered controls and closed-details descendants, including correct handling of initial dialog focus. Root live-checked Document summary → Tab → Close, and Close → Shift+Tab → Document, both within the dialog. |

Root also found that the embedded Next-match replay used `scrollIntoView`, which could scroll the surrounding research page. The final source confines movement to `#reading.scrollTop` through `scrollReaderTo`; this correction is source-verified here. Root live-confirmed that closing the Controls sheet returns focus to Controls.

## Remaining ranked findings

**Blocker: none in the inspected proposal/prototype scope. Major: none. Medium: none identified after these bounded corrections.** This does not declare the unrun acceptance gates passed.

The additional minor focus-return defect was corrected before this final snapshot: sheets preserve the connected external invoker and restore it, with Tools as fallback.

**Minor — compact fan labels need explicit readability evidence before visual polish is called finished.** The inspected English labels fit, with no collisions in the supplied 360px family and eight-leaf images. Initial family labels are about 10 CSS pixels and the entire menu is near the operating finger. The study already includes reach/occlusion and longer text in acceptance work; record those results rather than treating geometric 48-unit target containment as proof of readable labels. Do not shrink translated text to rescue this arrangement. This is an evidence limit, not a demonstrated clipping defect in the supplied English fixture.

## Grounded score

These dimensions grade the **reviewable design and browser prototype**. Reliability here means input-state reliability; this task does not retest the separate Collection/storage proposal.

| Dimension | Weight | Score | Basis |
|---|---:|---:|---|
| Product clarity and command coverage | 25% | 9.4 | Correct controls-only scope, finite map, honest completion boundaries and capability audit. EPUB/Markdown maps remain a named delivery gate. |
| Geometry and technical feasibility | 25% | 9.2 | Fixed-center bounds, full-depth child band, disclosed fallback and parameter grammar are concrete. Usable physical reach and native ownership are not established by CSS geometry. |
| Ease of implementation and AI-assisted development | 20% | 9.5 | Small pure reducer, explicit command IDs, frozen contact state and executable traces avoid an implicit custom UI framework. Native command/renderer integration is still work. |
| Input reliability and cancellation | 20% | 9.4 | Commit-on-release, terminal hub cancellation, sparse crossings, ownership and interruption cases are inspectable and tested. Browser evidence cannot validate native generation arbitration. |
| Accessibility and understandable feedback | 10% | 9.2 | Equivalent semantic list, disabled reasons, large-text disclosure, modal focus filtering and invoker restoration are present. Actual assistive-technology evaluation remains. |
| **Weighted total** | **100%** | **9.35** | A strong corrected prototype; not a justified 9.5+ validated interaction yet. |

## Gates that remain outside this score

The study correctly leaves Android predictive Back/Home, three-button navigation, native reader scroll/pan/pinch/selection, interruption and actual safe-region layout to a native spike. Browser pointer capture cannot certify those. Android's own guidance distinguishes mandatory bottom gestures and explains child cancellation during parent interception: [gesture navigation](https://developer.android.com/develop/ui/views/touch-and-input/gestures/gesturenav), [touch interception](https://developer.android.com/develop/ui/views/touch-and-input/gestures/viewgroup).

The proposed 12-participant, counterbalanced toolbar comparison has not run. Neither has the separate assistive-technology session. The fan's long cross-family paths, abrupt category-to-child remapping, small family labels and three-phase parameter rail are hypotheses to test there. Thirty native trials are a screening procedure, not proof of zero field failures. Nothing in the comparable-product research transfers its measured performance to this particular six-family/eight-child layout.

Proceed to the bounded native ownership spike and participant study with this candidate. The remaining uncertainty should be resolved with device and participant evidence, not further score-driven cosmetic review rounds.
