# Native Collection technical review — round 1

2026-09-23. Independent review of `9bfb38f30`, `4b346d5f1`, `17dfd78ed` and the developing History/Usage integration on `codex/collection-history-release`. The working tree changed during review; repairs observed below are distinguished from independently verified closure.

**Score: 7.9/10.** The storage implementation has strong transactional protection and the ordinary retained-search path passes its tests. Three medium issues were demonstrated during this round: current explicit opens are omitted from the cleanup ranking that the same open triggers, normal Markdown phrase matches lose their highlights across a rendered line wrap, and a detached History controller can overwrite newer persisted context. Neither the 8/10 acceptable threshold nor the requested greater-than-9/no-medium target was established by this initial candidate. No major issue was found. Repairs made during review will be scored separately in round 2.

## Ranked findings

### NT1 — Medium: cleanup runs before accounting for the explicit open that triggered it

`SPDFMacCollectionIntegration.mm:106` starts capture and records usage only in its completion at line 109. `SPDFMacCollectionStoreCapture.mm:148` enforces the cap during that capture. `SPDFMacCollectionUsageIntegration.mm:23` further defers the count onto an independent global queue. Consequently the current open is absent from the ranking used for irreversible history removal, and later captures can overtake its count as well.

Independent probe `/tmp/native-open-cleanup-order-probe.mm` creates A with one retained version and zero opens, B with two versions and one earlier open, and a cap exactly equal to current retained bytes. It changes and explicitly opens A using the integration's capture-then-count order. Fresh compilation and execution exit 0 with:

```text
After explicit A open: A_count=1 A_versions=1; B_count=1 B_versions=2; limit=222 used=222
```

At the successful explicit open, A and B should each have one open and B's older last-open timestamp should cause B's oldest version to be removed first. Instead A's prior version is removed while A still has a count of zero. Make successful-open accounting precede or participate in the same serialized transaction as quota enforcement, preserving identity checks and first-capture laziness. A regression must assert which actual version survives, not merely final counts or bytes.

### NT2 — Medium: a matching Markdown phrase can open with no History highlight

`SPDFMacCollectionStoreMarkdown.mm` indexes canonical rendered text. `SPDFMacCollectionHistoryDetail.mm:220` searches extracted PDF page text using literal `rangeOfString:` and constructs a selection from that result. Rendering inserts soft line breaks that canonical text does not contain.

Independent probe `/tmp/native-history-search-probe.mm` compiled the actual current preview loader with the repository Markdown implementation and rendered a normal paragraph. The canonical matching phrase `café and` became `café\nand` in the generated PDF. The phrase remains a valid saved-text search match but the History search finds no range. Even `PDFDocument findString:withOptions:` returned zero for this fixture, so substituting that call alone is insufficient.

Normalize layout whitespace while retaining offsets back into the PDF string, then build selections from mapped source ranges. Preserve the store's case/diacritic-insensitive and query-trimming behavior. Verify a phrase spanning two drawn lines, including a diacritic, against an actual Markdown History preview.

### NT3 — Medium, repairs observed but not yet independently closed: successful opens were lost

The initial completion recorded a count only when capture returned a document without an error. Successful reader opens of excluded documents and documents whose new capture exceeded the cap therefore never counted. The initial `SPDFCollectionOpenIntents` used a set, which also collapsed separate explicit open requests while capture was pending.

During review the owner changed `SPDFMacCollectionIntegration.mm:108` to fall back to the existing document independently of capture success, and `SPDFMacCollectionUsage.mm:3` to a per-path counter that deduplicates only within each request. Those are appropriate repairs. They require follow-up verification of separate request counts and excluded/cap-failed reader opens; NT1 remains distinct.

### NT4 — Minor, repairs observed: preview compatibility differed from retained data

Initially History reused comparison-only limits of 256 MB/1,000 Markdown pages even though capture permits 512 MB and indexing covers up to 2,000 pages. The owner has split preview and comparison budgets in `SPDFMacCollectionCompareLoad.mm:14`, with preview-specific diagnostics. Initially `SPDFMacCollectionWindowGrid.mm` also omitted the supported `.mdown` extension; its line 170 now includes it. Follow-up should retain comparison bounds while verifying the broader preview path and a `.mdown` thumbnail.

### NT5 — Medium: an old detached preview overwrites the current History context

`SPDFMacCollectionWindowHistory.mm:12` removes the previous History view and later replaces its associated controller. It does not explicitly cancel that controller. The preview work block in `SPDFMacCollectionHistoryDetail.mm:192` strongly retains the old controller, so cancellation in `dealloc` cannot happen while that work is outstanding. Its eventual main-queue callback installs a PDF, triggers `pageChanged:`, and persists its own document/version/page using its separate preference queue.

Independent `/tmp/native-history-stale-context-probe.mm` delayed A's materialization with a semaphore, replaced the controller in an unordered headless window with B, waited for B's two-page preview and context to persist, and then released A. It printed `Live controller=B, persisted history=A, hidden old completion overwrote context=YES` and exited 0. This can reopen the wrong document after restart. Explicitly invalidate the outgoing controller on replacement/navigation, suppress stale page/selection writes, and serialize shared history preference writes. Cover this with a delayed-preview regression, since ordinary same-controller version-generation tests do not expose it.

## Independently verified strengths

Fresh `make -C portable mac-collection-store-tests mac-collection-search-tests` finished with exit code 0. This compiled and executed storage, integrity, cleanup and grouped-search suites; output is `/tmp/native-technical-review-tests.log`. Results were judged by the command's exit code.

The cleanup suite exercises least-opened ordering, last-open tie breaking, every prior-version stage before final-copy removal, whole-history Keep protection, shared blob/asset accounting, immutable incoming-version protection, stale review rejection, transaction/write/cap failure preservation, original-file preservation and twenty independently locked concurrent count increments. Code inspection confirms the manifest replacement becomes durable before unreferenced files are collected under the same lock. The search implementation reads retained indexes rather than live originals or materializing archives. Read-only cleanup previews and absent-document usage calls do not create an unused store.

## Scope and remaining evidence

No user app was launched, quit or screenshot. The only rendering probe used a prohibited-activation test process and generated temporary files. Manager browse-context persistence was actively being repaired by another agent and was deliberately not assigned a duplicate finding. This review does not claim visual UX approval, full process-restart validation, or cross-process UI timing coverage. Round 2 should rerun the concrete findings against the final code and report remaining material issues without treating source edits alone as proof.
