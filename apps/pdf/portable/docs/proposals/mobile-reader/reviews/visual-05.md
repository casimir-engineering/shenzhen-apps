# Independent review — visual round 5

Reviewed 2026-09-24: the first rendered prototype evidence bundle, its `results.json`, prototype source and root agent's live CUA observations. The critic inspected all 16 supplied PNGs, including reader formats, Groups, document list, Collection, History, Storage, consent, missing-original recovery, portrait/landscape wheel and the supplied larger-text variants.

The critic's CUA inventory returned **no browser surfaces**. Therefore live interactions below are explicitly root-observed or supplied test evidence, not interactions performed by this critic. Source inspection supplements the rendered images; it does not replace them. This report freezes the first bundle. Corrections being made concurrently need fresh evidence in the next round.

## Score: 8.64 / 10

The same requested weights assess the prototype's expression of the design, not native engine correctness or measured storage savings.

| Dimension | Weight | Score | Weighted contribution |
|---|---:|---:|---:|
| Product clarity | 25% | 8.5 | 2.125 |
| Technical feasibility expressed by interactions | 25% | 8.7 | 2.175 |
| AI development and reproducible feedback | 20% | 9.0 | 1.800 |
| Storage/reliability UX and truthful state | 20% | 8.8 | 1.760 |
| Accessibility and responsive recovery | 10% | 7.8 | 0.780 |
| **Total** | **100%** | | **8.64** |

## What works

The actual reader screens are restrained and readable, with substantive sample content rather than empty page placeholders. EPUB and Markdown look like reflowed reading. Groups and Collection are visually distinct destinations. Group/document rows use space sensibly; Collection combines small thumbnails, titles, location and snippets without giant cover cards. The wheel fits the supplied portrait and landscape viewports, exposes a current neutral slot, and retains a visible reading context. The ordinary switcher is a credible accessible alternative.

History provides recognizable chronology and explicit dated-version actions. Storage separates retained, temporary and shared-byte figures. Consent explains local copies and a visible budget. Prototype and simulated-file/export behavior are identified rather than presented as real native operations.

Root live CUA confirmed PDF reader → tap Switch → EPUB, organizer browsing without an immediate document switch, Collection layout, an older revision and Return to latest, and correct sample cleanup arithmetic (312 + 48 MiB → 286 + 12 MiB = 298 MiB). Switch-sheet Escape returns focus to Switch. Supplied automated evidence additionally reports held-wheel selection, unarmed cancellation and no outer horizontal overflow in its listed viewports; that evidence is not a native touch/accessibility test.

## Blockers

None preventing continued prototype work.

## Major — V1: document context changes during unrelated organizer actions

Source shows `docmenu` immediately assigning `state.doc`, which is also the active reading document. Opening another item's overflow menu in Collection can change the eventual Reader destination without selecting Open. `history` then forces `state.doc = 0`, so EPUB/Markdown History resolves to the PDF fixture. Contents is also hard-coded to the PDF title and chapter list. This is a visible violation of the canonical separation between browsing, selection and opening.

**Required change:** separate active reading identity from organizer/menu target. Bind History, Contents and export to the selected target and format. Preserve the active reader until an explicit successful Open. Add live or browser test evidence: read EPUB → inspect another Collection item's menu → dismiss → Reader still EPUB; open EPUB History → EPUB identity; open EPUB Contents → its chapter identity. A fixture can use sample data, but it must model the state contract consistently.

## Medium findings

### V2 — “Large” does not exercise the specified 200% text state

The supplied `large=1` CSS increases selected text sizes, e.g. document titles to 18px, while many 10–14px labels, sheet content and controls stay fixed. These screenshots are a larger-text design variant, not the required 200% accessibility proof. The ordinary text is often small enough that the missing test matters. No true-200% or dark-theme evidence is in the first bundle.

**Required change:** provide a genuine text-scale fixture or platform-equivalent 200% test, identify the method, and make all meaningful text participate. At 360×800 verify consent, switcher, long group/document titles, History and Storage with actions reachable by scrolling; test dark theme and a long-title wheel/list fallback. Capture screenshots and state reachability, not only a page-level `scrollWidth` check. Keeping primary controls on screen is less important than readable text and reachable actions.

### V3 — Dismissal restores the wrong focus outside the Switch sheet

Source `closeSheet()` always targets `#switch-control`. That is correct for Switch but wrong for Contents, Find, More, storage, creation and organizer menus. On screens without Switch it restores nowhere. Root has confirmed Switch/Escape only; other cases must not inherit that pass.

**Required change:** remember the invoker by stable action/identity and restore its corresponding rendered control after dismissal. Preserve a sensible fallback if the invoking item was deleted. Verify Contents→Escape, Find→Escape, Groups Add→Escape and Collection menu→Escape, including keyboard focus visible and no background modal interaction.

### V4 — Search destination and scope are not yet demonstrated

Root observed “quiet” filtering two rows while the count remained seven, with “quiet” highlighted even before a query. Selecting a result opens the generic sample reader rather than demonstrating its exact hit and Return origin. Global search had no organizer entry in this bundle. Source Find returns the same hard-coded match for every nonempty input.

**Required change:** make counts and highlights reflect actual fixture results; distinguish empty query from no matches. Add the canonical global-search entry. Model a hit destination with a visible highlight and Return to the prior location using the sample DOM; this does not require a native engine. Use a meaningful unmatched query and stale-version fixture so the design is inspectable rather than a universal success response.

### V5 — Revision labels disagree across the modeled reading/export flow

Root selected 12 September and saw that date in the header, but the footer still said 18 September. Source export similarly hard-codes the older revision as 18 September. This weakens the most important archive promise: users must know which exact saved version they are reading or exporting.

**Required change:** derive header, footer, History selection and export confirmation from one revision identity. Verify two distinct older dates and Return to latest. Include the latest-verified/unverified distinction from the finalized text in at least one recovery fixture; no native byte operation is needed to show those labels correctly.

## Minor findings

- The full focused wheel title is confined to a roughly 105px center circle. Current short fixtures fit, but a realistic long title needs either a full-width focused-title line or an explicit readable fallback. Show the selected-sector state as well as the idle wheel; the spec's non-color selection marker should be visible.
- Android-first presentation should identify its system-inset assumptions. The simulated status/home chrome looks generic/iPhone-like; it is not evidence of Android Back/gesture-safe placement. Native validation remains separate.
- The 390px evidence is useful, but the agreed 412×915 reference and more than six documents/one-alternative states still need a small representative evidence sample before declaring the entire mockup set complete.

## Next-round evidence

Recheck the repaired flows on the actual browser, regenerate images/results with a source/build hash, and include true 200%, dark, long titles, one overflow group and revision-consistency evidence. Keep the evidence concise and distinguish root-operated live CUA, automated browser observations and critic-inspected screenshots. No native benchmark is required for this design task.

Text remains accepted at **9.57/10**. Visual phase remains open at **8.64/10**. Round count: **5 of 8**.
