# Collection History revision — critique round 1

23 September 2026. Independent review of the revised design mockup. This begins a new review sequence limited to two rounds; the earlier 9.2/10 score does not apply to this revision.

**Score: 8.9/10. One medium finding should be resolved before presentation.**

## Evidence

Inspected browser-rendered captures in `assets/collection-mockup/history/`: `round1-documents.png`, `round1-history.png`, `round1-settings.png`, `round1-cleanup.png`, `round1-history-390.png`, `round1-selected-history-390.png`, and `round1-history-light.png`. Read the revised source. Root supplied CUA runtime/accessibility checks, including focus, filtered-result return, cleanup effects, and protection. No native app window was launched or captured.

## Ranked findings

1. **Medium — explain Keep's whole-history effect at the control.** The checkbox says “Keep this version,” but retaining one version protects the entire document history from automatic cleanup. The explanation is below the large page preview, partly outside the visible narrow-screen toggle context. The checkbox also has no accessible description of this effect. Move a concise protection explanation/status next to the Keep control, associate it with `aria-describedby`, and announce changes to protection state. Keep the selected version flag distinct from the document's effective protection: another kept version can leave the history protected after the selected version is unkept. This affects a real storage decision and should be available before the user changes the checkbox.

- **Major:** none identified.
- **Minor:** the persistent left navigation still makes narrow pages tall, but the measured 390 px layout has no horizontal overflow and remains readable. This does not require another redesign.

## What works

- Documents contains the search field; the separate Search destination is gone. Fresh state opens with an empty query and a zero/unlimited cap. Settings clearly says that unlimited means no automatic cleanup.
- Every result exposes an obvious History action. History identifies the document, original availability, capture dates, latest/earlier status, sizes, and capture reasons. The selected version and read-only preview agree. Page selection works, and the preview is visible after narrow-screen selection.
- Returning from History retains the query, All versions scope, expanded matches, and focus on the originating History action. Entering from an earlier-version page-7 hit retains that version and page; returning preserves the saved-copy preview.
- Reload retains the History view, selected 18 September version, and its Keep state, as verified by root.
- The cleanup review visibly separates removing previous versions from removing last copies/document entries. At 2 GB it first removes the Greenhouse older version (2 opens), then Botanical's older version (8 opens), then Greenhouse's last copy. This matches the two-stage policy. Opens are frequency counts, and history explains that preview/search/index/restore activity does not increment them.
- Cleanup uses the same simulated version data as Documents and History. A 2.5 GB cap removes only the two eligible older versions, leaving five versions and one Botanical version. A 2 GB application removes Greenhouse's entry, leaving two documents. Cancellation leaves storage unchanged. A 1 GB cap blocks Apply because protected history cannot fit and says nothing is removed.
- Dark and light layouts preserve legibility and a compact native style. Original files remain explicitly untouched.

A suspected mismatch between a checked Keep box and its version-row label was checked again by root. Fresh runtime text and accessible name both include “Kept”; no inconsistency was confirmed, so this is not a finding.

## Second-round acceptance

Inspect the revised Keep control and explanation at desktop and 390 px. Verify the checkbox's accessible description and changed protection status, including unkeeping one of several kept versions. Recheck the selected version identity and filtered-result return. No backend, native-app, or real-file behavior is required by this mockup review.
