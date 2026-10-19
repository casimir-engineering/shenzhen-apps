# Reader-controls wheel evidence · 24 September 2026

This records a browser design prototype, not an Android/iPhone build. Source fingerprints are in `source-sha256.txt`. Fixture outputs, local source checks and real browser observations have different evidentiary scope.

## Actual browser input

Root used the Codex browser at 360×800. A single Tools-down / straight drag / up selected Rotate right (explicit placeholder), Fit page, then Fit height (sample state). The visible event trace records no action during moves and one action at each valid up; `live-pointer-trace.txt` preserves a recent event tail from that session. A final frozen-source replay by actual browser drag is recorded completely in `final-pointer-trace.txt`: Fit height, no move-time action, one up-time commit. A further outward release beyond the fan committed nothing. A page-origin drag crossing Tools left the wheel absent and action count unchanged. Ordinary document scrolling reached scrollTop 680 while the wheel stayed absent. These are desktop pointer observations, not phone touch/OS evidence.

The ordinary Controls list was exercised separately: enter 200%, choose Zoom in → stays 200% at its upper bound; reopen Adjust → value 200. In a collapsed list, Tab from Document wrapped to Close; Shift+Tab from Close wrapped to Document. Both stayed within the dialog. Closing returned focus to its actual Controls invoker.

The 200% text list used 26.88 px command labels, scrolled to 1600 px, and had no horizontal document overflow. At 320×568 the rest view disclosed that the fan cannot fit and exposed List. At 844×320 the actual phone height was 320 and Tools/List bottom 302.5, with an explicit short-layout notice. The list remained usable. PNGs with `final` in their name record these corrected states.

## Replayed interaction sequences

`sequence-*-final.png` captures whole four-frame rows from the browser document. These use deterministic down/move/up fixture replay, not four independently hand-performed touch captures. The same reducer drives actual pointer input. The study contains six rows: Fit width, Night, Next match, cancel, page scrub, zoom adjustment. For zoom, the final paper uses CSS zoom 1.25 and visibly enlarged text. The page fixture changes its displayed position; it does not render 48 real PDF pages.

The replay distinguishes preview from committed state. The numeric rail keeps the current value at entry, previews while held, and commits on release. The selected fan command remains visible above the footer after the trace-strip obstruction was fixed. Match navigation now scrolls only its iframe reader, so replay cannot move the parent research page.

## Pure tests and independent review

`state-tests.json` records 34 passing reducer checks: same-contact command/parameter selection, no hover action, duplicate-up protection, origin ownership, sparse/coalesced threshold crossings, inward correction, terminal cancel, unavailable actions, pointer interruption and honest layout fallback. Source syntax, local HTML references, file-size limits and whitespace were checked separately. The critic reproduced and then verified correction of a sparse/dense path disagreement.

The independent corrected-brief review is `../reviews/control-wheel-design-02.md`: 9.35/10 for design/prototype, no remaining major or medium issue in its reviewed scope. The prior document-switcher 9.57 scores do not apply.

## Not demonstrated

No participant study, physical thumb test, Android predictive Back/Home, iPhone system gesture, native renderer arbitration, native accessibility, PDF engine or mobile speed benchmark was run. The canonical study specifies these gates. Roughly 10 px radial labels still require physical readability/occlusion validation. Parent browser screenshots are a design inspection aid, not proof of touch accuracy.

Non-final files preserve intermediate findings, including the trace/footer overlapping the fan. They are not the final design.

Browser logging also emitted unlocated MutationObserver errors during embedded-page loading. None of the study/prototype sources uses MutationObserver; the logger provided no source URL, so this run does not claim a clean browser console or attribute those errors to a verified source. The recorded interaction checks completed.
