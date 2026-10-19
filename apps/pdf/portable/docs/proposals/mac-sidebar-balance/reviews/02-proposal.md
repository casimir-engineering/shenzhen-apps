# Independent sidebar review — proposal direction

24 September 2026. **Approve direction A for native implementation.** This review covers the design contract and CSS comparison source. Rendered whole-reader evidence is still pending at this writing, so beauty and final usability grades are deliberately withheld. Child CUA reports no available browser; root will supply actual browser frames. No running native app was launched or captured.

## Direction decision

The compact full-width vertical stack is the strongest of the three alternatives. It preserves the requested visible icon-and-text modes, the current width and YAML behavior, and leaves a full text lane for task content. A neutral selected-mode fill and an accent current-content selection communicate two different states without two equally strong blue panels. The page should remain the most prominent surface in the complete reader.

The final agreed Groups budget is preferable to more aggressive row compression:26pt navigation rows with zero inter-row gap; a search-only42pt header;36pt two-line group rows;26pt document rows; compact counts footer with an information affordance. Keeping counts/Hidden/Active on the second group line protects meaning at176pt. A32pt single-line row would buy only8pt across two groups while making status compete with names and controls. Do not obtain density by shrinking26pt action targets or hiding state.

Direction B demonstrates a real height benefit but needs340pt combined width. At default240pt that takes100pt from the document; at176–220pt the split text columns cannot work. It is a useful comparison, not the default. Direction C rearranges where the same fixed-height cost occurs, moves mode access with window height, and leaves the short-height budget unsolved. Neither is a better fit for this request than A.

## Bounded corrections identified before the native pass

**Medium — synchronize the written budget and mockup with the accepted contract.** The inspected `design.md` still described1pt navigation gaps/143pt intrinsic height and a Groups summary-plus-search header, whereas the accepted direction and current CSS use zero gap, search-only header and counts footer. Replace those stale statements, including the option table. The minimum-height claim must correspond to one canonical set of dimensions.

**Medium — make minimum-width mockup metadata match production meaning.** The CSS fixture uses `2 documents · Current` and `2 documents · Hidden` in a nonwrapping metadata lane without truncation. Production uses the more compact `2 · Active` / `2 · Hidden · Active`. At176pt, the long fixture strings can compete with the reserved eye control. Use the actual compact strings and preserve the complete state when both Hidden and Active apply; constrain text so it cannot enter action bounds. Titles may truncate with a full-name tooltip, but essential state cannot silently disappear.

**Medium — do not treat illustrative task controls as implemented behavior.** The mockup's History action layout is explicitly not root's authoritative implementation contract. Search and Chapters also illustrate additional header/footer arrangements. Native acceptance must inspect the actual controllers, not infer that mockup controls establish query ownership, exact comparison targets, keyboard operation or persistence. Keep the distinction visible when presenting the work.

No additional major structural correction is needed before implementing A. These are bounded fidelity/fit issues, not reasons to add another navigation architecture.

## Native acceptance focus

- At296pt available sidebar height, five-mode Groups should show at least two complete group rows with search and footer usable. Verify actual Auto Layout/table spacing, not just the arithmetic in prose.
- At176pt width, reserve disclosure and visibility targets before allocating text. Show a hidden active group, long title and current document. Default240pt should look calm rather than merely more empty.
- Root's History contract removes the duplicate heading and action tower. Inspect56pt revisions, explicit Latest/older identity, and the exact narrow action-menu fallback. Missing-source state must still explain recovery while showing that versions exist. Empty/one-version cases cannot make an unusable Compare button the dominant object.
- Chapters and Search should benefit from the shared shell without acquiring a second search model or losing native filter/outline semantics. Match real216pt Search minimum. Preserve the format-specific Comments mode.
- In dark appearance, distinguish muted text from disabled text. A neutral selected-mode fill must still be obvious when keyboard focus is elsewhere; focus retains its own cue.
- Compare the whole reader at the same window, document and sidebar width. CSS appearance cannot establish AppKit row fitting, field-editor behavior, native accessibility or state restoration.

The baseline grading rubric remains in `01-baseline.md`: separate beauty and usability scores, with whole-reader hierarchy and useful content weighted most heavily. Native renders and focused checks, rather than prior grades, determine the next verdict.

## Rendered evidence addendum

Root subsequently supplied the actual CSS browser captures in `evidence/`. I inspected A Groups light/dark, B wide-column, C bottom-modes and A minimum. These confirm the direction choice: A leaves the page prominent and keeps the content/navigation relationship clear. B produces a persistent extra column with considerable empty space; C moves mode controls away from their task. A's neutral selected mode is distinguishable from the accented current document. The minimum capture is a whole-page browser view, so fine label fitting is judged from the separate native renders, not its scaled appearance.

The proposal's canonical dimensions and compact group metadata have since been corrected. Final native grades belong in the subsequent native review, not in this CSS-source review.
