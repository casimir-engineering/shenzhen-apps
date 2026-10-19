# Technical review · round 3

23 September 2026 · Independent Astra technical critic

**Score: 9.1/10. No major or medium technical findings remain in the final candidate reviewed.** The earlier defects have concrete repairs and meaningful regressions. This score reflects the final shared-epoch and activation-hook changes verified during this round, not the candidate at the beginning of the round. Technical review supports proceeding through the remaining release checks and independent live UX review.

## Ranked disposition

### 1 · T7 closed · Stale captures are invalidated across independent stores

The initial per-instance generation fix passed the single-store regression but still failed when a pending generic capture in one store overlapped an edit in another store sharing its root. I reproduced that residual with a freshly compiled probe and reported it before scoring.

The final implementation publishes a new `protectionEpoch` under the manifest transaction before the pre-edit gate allows a source write. Each asynchronous request snapshots that epoch when enqueued, retains it across retries and checks it against the current document under the Collection lock. Local generations still suppress superseded jobs within one instance. An older job in another window can no longer turn a legitimate atomic save into an unrelated replacement.

**Independent verification:** recompiled the exact two-store probe against the final sources and ran it, exit 0:

```text
gate=1 rows=1 originalVersionCount=2 savedError=0 currentIdentityChanged=0
```

The earlier candidate had produced two histories and error 19 from this same ordering. The updated integrity suite now covers both single-store and independent-store variants and passed independently. The unchanged-protection test correctly checks retained bytes/version counts while allowing the deliberately required durable epoch metadata write.

Relevant files: `SPDFMacCollectionStoreScheduling.mm`, `SPDFMacCollectionStoreCapture.mm`, `SPDFMacCollectionIntegrityTests.mm`, `SPDFMacCollectionStoreTests.mm`.

### 2 · T8 closed · Confirmed live changes retain identity at focus and activation boundaries

Both writable and read-only focus-change branches record continuity before reload or cache invalidation. This round also found and closed the equivalent inactive-tab activation gap: PDF activation and inactive preload record it before discarding a stale in-memory document; Markdown activation records it before clearing a stale cached session.

The final conditions require an existing live document/session. They do not infer continuity from persisted session metadata alone after relaunch. Pending app-save identities remain separate from observed external-change identities; successful-save hooks consume the former, and closing the tab clears pending context.

**Verification:** independently traced the final focus, PDF activation, inactive preload, Markdown activation, generic open, successful-save and tab-close branches. This closure is source-verified; I did not operate the live app to replay the focus/activation sequence.

Relevant locations: `ShenzhenPDFMac.mm:6759`, `:6780`, `:7172`, `:8542`; `SPDFMacMarkdownIntegration.mm:250`; `SPDFMacCollectionIntegration.mm`.

### 3 · T9 closed · Markdown dependency capture follows actual parsed image nodes

The raw regular-expression scan has been replaced by traversal of the reader's parsed image runs. Literal examples, unused definitions, escaped syntax, comments, front matter and suppressed HTML no longer become dependencies. Real inline, reference and HTML images use the parser's destination resolution.

**Independent verification:** the current asset suite passed. It covers sixteen literal contexts, actual reference/HTML destinations, duplicate definition semantics, spaces/parentheses/entities, and an object-store assertion that the private adjacent file's hash never appears. It also asserts that non-Markdown capture never invokes the parser and that dependency parsing uses no source URL or resource store. The current integrity suite passed its actual archive/reference tests as well.

Relevant files: `SPDFMacCollectionStoreAssets.mm`, `SPDFMacCollectionAssetTests.mm`.

### 4 · Comparison accessibility repair accepted

The live UX reviewer found a PDFKit accessibility crash in comparison readers. Source inspection supports the stated cause: reparented copied pages could retain Core Graphics ownership inconsistent with the new PDFKit document.

The final comparison preparation assembles marks and blank counterparts, serializes the aligned documents, and reopens independent backed PDF documents on the worker queue before installing them in either reader. This gives every presented page coherent PDFKit and Core Graphics ownership while preserving vector text and annotations.

**Independent verification:** ran the retained `/tmp/spdf-compare-controller-probe` presentation regression, exit 0. It traverses actual PDF accessibility children, verifies page/document ownership including blank counterparts, searchable/selectable text, original annotations and comparison marks, unchanged source bytes, and worker-only serialization. The test's window remains hidden. I also independently ran the comparison-loader tests, exit 0, including hybrid repeated-header image insertions/deletions.

This headless pass is good technical evidence for the repair. Confirmation that the original live interaction no longer crashes belongs to the independent UX retest; this review does not claim to have performed that interaction.

## Minor follow-up

**M1 · Minor · Add direct coordinator regressions for the T8 activation routes.** The repaired branches are straightforward and their store behavior is covered, but a focused headless integration test would better prevent a future extraction from dropping one hook. Exercise both an inactive PDF and Markdown tab changed by a background process without a window-focus transition, then assert the same history ID on reactivation. Also assert that relaunch without a live cache remains conservative. This is a test-maintenance recommendation, not an observed remaining production defect or a release blocker.

## Other checked repairs

Round 1's captured-fingerprint, non-overwriting export, conservative same-path identity, reference-image, hybrid-alignment and bounded transient-retry fixes remain present. Source inspection of the restored palette favorites/actions confirms that supplementary sections follow the five required document/group/text sections, while `col:` remains restricted to Collection. Archive labeling uses explicit archived/read-only identity rather than silently routing replaced originals as available.

## Verification and scope

Independent commands completed with exit 0:

- Freshly compiled `/tmp/spdf-tech-round3-multistore`, linked to the final store and parser sources.
- `portable/build/SPDFMacCollectionIntegrityTests`.
- `portable/build/SPDFMacCollectionAssetTests`.
- `/tmp/spdf-compare-controller-probe` — the retained comparison presentation/AX regression.
- `portable/build/SPDFMacCollectionCompareLoadTests`.
- `portable/build/SPDFMacCollectionPaletteTests`.

The integrity/asset binaries were newer than their repaired source files when inspected. The complete UI runner and final app build are root-reported exit-0 results in `/tmp/spdf-round4-ui.log` and `/tmp/spdf-round5-build.log`; they are not represented as independently rebuilt by this critic.

No installed app was launched, quit, controlled or captured. The presentation regression constructed its own hidden test window. Physical power-loss behavior on real storage and every possible third-party external-save pattern are outside this bounded review. The 9.1 score recognizes the resolved, reproduced defects, meaningful privacy/durability tests, explicit scheduling/identity boundaries and improved comparison ownership; it is not a claim that future testing cannot uncover another issue.

## Final bounded addendum · optimized ownership and linked counters

**Score retained: 9.1/10; no new major or medium finding in these repairs.**

The thumbnail caption now stays in a strong local variable until `addSubview:` gives it an owning view, before assigning the weak `NSCollectionViewItem.textField` outlet. The image outlet follows the same ownership order. This directly repairs the ARC lifetime defect seen in the optimized manager. The UI runner's C++ flags now include `-O2`, so the constructor tests exercise production optimization rather than relying on debug lifetime behavior. Live manager recovery and the complete optimized suite are root/UX-reported results; this critic inspected the ownership repair and test flags.

The comparison pane now routes destination jumps through one method that explicitly updates its aligned-page/source counter and exposes the requested destination during peer synchronization. `_navigating` suppresses PDFKit callbacks during the jump; the controller's `_synchronizing` guard prevents immediate peer feedback. Deferred scroll updates carry a generation token, so a later explicit navigation invalidates an earlier queued update. Ordinary scrolling refreshes counters after PDFKit settles, and unlinked controls remain local. Next/previous change uses the same destination route for both panes.

I independently reran the updated `/tmp/spdf-compare-controller-probe`, exit 0. Its expanded regression removes a pane's page-change observer, checks inserted-page counterpart labels, linked and unlinked stepping, counter stability after draining the run loop, actual displayed pages, and scroll-driven refresh without page notifications. The existing ownership/AX/search/source-immutability assertions still pass. No UI interaction was performed outside that hidden headless test.

The viewport-checkpoint extraction also preserves its weak owner/session references and active-tab/session guard before persisting state. I found no behavior change in that bounded source move. The live comparison-counter retest remains separate UX evidence.
