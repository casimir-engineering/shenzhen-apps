# Sidebar navigation and Group Management — independent UX review

Review criteria established 24 September 2026. Native headless renders and focused interaction checks only; no launch, quit or screenshot of the user's application. The target is **above 9/10 for both visual quality and usability**, with evidence and remaining limitations stated separately. A desired score is not evidence of quality.

## Interaction contract

- Navigation is a compact vertical list of horizontal icon-and-label rows at the top of the existing sidebar. Remove the old horizontal mode strip. Content retains the full panel width.
- Group Management remains reachable while groups are hidden. Hiding a group removes its tabs from the strip, never closes documents or changes the currently displayed document. Explicitly activating a group in the manager unhides and navigates to it.
- General uses current focus/collapse behavior. Renaming General promotes it to an ordinary group; opening the next new document creates a new General. Expose this consequence in the rename flow without requiring the user to learn model terminology.
- Group-header expansion browses contents without switching documents. Actual tab activation follows the current auto-collapse behavior.
- Search filters group names only, as explicitly requested. Disclosure reveals member documents. The field says Search groups and offers an obvious empty-result state and clear action.

## Initial recommendations

1. A compact title and search field should establish the panel's purpose. Align group names, disclosure controls, counts and visibility actions consistently; use one strong active-document indicator.
2. Show/Hide needs a state users can understand without remembering an eye icon. A tooltip/accessibility label should name both action and target. Hidden status must remain evident without relying solely on low opacity.
3. An active document can belong to a hidden group. Explain this state without navigating away automatically. Group activation should have a clear target distinct from rename, expand and visibility.
4. Keep rename explicit in Group Management; do not let an ordinary selection unexpectedly edit a name. The General rename explanation should state that newly opened documents will go into a new General group.
5. Match the existing restrained native palette, rounded corners, icon weight, typography and field focus outlines. Selection and hover must be distinguishable in both themes. No badge/control should fight the group name for attention.
6. Verify 220-point panel width, long group/document names, empty search, hidden active group and short available height. Expensive member enumeration/filtering should only run when the panel is used.

## Scoring rubric

Visual quality: hierarchy/space 25%, alignment/type 25%, palette/selection 25%, narrow/edge states 25%.

Usability: discoverability/action clarity 25%, interaction semantics 30%, keyboard/accessibility 20%, persistence/recovery/empty states 25%.

A score above 9 requires no unresolved material issue in observed states; visual mockups alone cannot establish interaction, persistence or accessibility. Each iteration records exact render paths, test evidence, ranked findings, separate scores, and scope limitations. Broader real-app ergonomics remain unverified unless explicitly authorized and exercised.
