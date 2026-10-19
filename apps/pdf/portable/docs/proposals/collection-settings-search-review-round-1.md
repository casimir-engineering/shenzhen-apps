# Collection settings and search — critique round 1

23 September 2026. Independent UX critique of the interactive mockup, not of the application implementation.

**Score: 7.8/10. Revise before presenting as finished.**

## Evidence

Visually inspected `assets/collection-mockup/round1-search.png`, `round1-settings.png`, `round1-cleanup.png`, `round1-history-736.png`, and `round1-history-390.png`. Read the mockup source as supporting evidence. Root supplied CUA runtime results for query changes, empty results, history scope and preview identity, cleanup, and location dialogs. No ShenzhenPDF application window was opened or inspected.

The desktop design is a substantial improvement on the existing manager: Settings has an obvious left-sidebar destination, capture/storage/location controls form clear groups, result thumbnails anchor readable contextual matches, and ordinary metadata remains legible in the dark theme. The location labels match the requested wording and default path. The cleanup review identifies whole histories, recovered space, resulting usage, protection, and untouched originals. The sample-only footer and dialog copy are honest.

## Ranked findings

1. **Major — a selected hit does not reliably take the user to its preview.** At 736 and 390 CSS pixels the preview is appended after every result. Selecting an early result can leave its preview far outside the viewport. The 390 screenshot shows how long even two results become. CUA also reported focus landing on the iframe/body after rebuilding the hit. Move the narrow preview adjacent to the selected result, or explicitly reveal and focus a preview destination. Closing it must return focus and viewport position to the exact hit. Keep the selected version/date/page identity visible in that destination.

2. **Medium — title-only matches masquerade as page-text hits.** CUA confirmed that searching `maintenance` gives the Greenhouse document an unrelated first-page snippet. Source inspection explains the fallback to the first hit when there are no body matches. Clearly label a title-only result and provide a separate saved-copy preview action, or scope the search to body text. Do not present unrelated body text as a query hit.

3. **Medium — accessible hit names omit both the context and the version.** Each button's `aria-label` overrides its contextual text and names only the title and page. Under All versions, two saved versions of the same document and page have indistinguishable accessible names. Include capture date, page, and snippet in the accessible name/description; verify this in the browser accessibility output. Visible focus must remain meaningful after selection and preview close.

4. **Medium — location dialogs contradict completed cleanup.** After applying the 2 GB limit, the Settings summary reports 1.8 GB; Set location still promises a move of 128 copies / 3.2 GB. CUA confirmed this. Derive move and folder-preview figures from the same simulated state, or omit counts the demo does not model. The folder preview also invents `copies` and `collection.db` entries; use an honest generic folder preview or actual store structure. A storage-management prototype needs internally consistent consequences.

5. **Minor — mobile reading area is unnecessarily narrow.** The permanent 109 px sidebar plus thumbnail leaves a thin text column at 390 px. Keep the requested left navigation, but reduce its narrow width and surrounding spacing, and consider a compact thumbnail size. Preserve readable type and complete contextual phrases rather than shrinking the text.

## Required verification for the next round

- Render desktop Search and Settings, and narrow selected-hit previews. Narrow captures should be framed so the full 390/736 px mockup is inspectable without a large blank surround.
- Verify early-result and historical-result preview entry and return with keyboard focus, including distinct accessible version/context names.
- Verify title-only results, zero results, expanded matches, post-cleanup location figures, and a cap below protected usage.
- Verify 0 remains an explicit unlimited state, and cancellation leaves simulated location and cleanup unchanged.

A score above 9 requires the major and medium findings to be resolved with rendered/runtime evidence. This is a bounded mockup review; real filesystem migration, backend cleanup, and native application integration are outside this review.

Additional CUA evidence supplied after the main inspection: a 1 GB cap correctly disables Apply and explains that protected histories need 1.4 GB and nothing will be removed. Location cancellation restores focus, selecting the sample Documents location changes the displayed path, and Open location reflects that path. These are positive findings.

Also inspected corrected viewport captures `round1-search-390-top.png` and `round1-search-390-viewport.png`; the earlier full-page capture's blank surround came from the iframe capture, not the mockup. Narrow text is readable. Finding 5 concerns scan efficiency and wrapping, not clipped or illegible content.
