# Native Collection technical review — round 2

2026-09-23. Follow-up through storage commit `4b7148c98` and the working History/search lifecycle fixes. This score covers storage, usage accounting, saved search and History lifecycle only. The coordinator is revising the visual design; the latest UI is not approved or scored here.

**Score: 8.3/10. No major finding; one medium finding remains.** The three demonstrated round-one defects are repaired, with independent reproductions now passing. The requested greater-than-9/no-medium threshold still requires NT6 below.

## Ranked remaining finding

### NT6 — Medium: fallback usage accounting can still occur after a later capture prunes history

The counted-capture API correctly updates a successful capture inside its transaction before quota enforcement. Excluded captures return without recording the count (`SPDFMacCollectionStoreCapture.mm:165`). Their completion is dispatched to the main queue, where `SPDFMacCollectionIntegration.mm:111` requests fallback recording. `SPDFMacCollectionUsageIntegration.mm:27` then places that write on a separate global queue. Meanwhile the serial capture queue can process another document and irreversibly prune using the old count.

Independent `/tmp/native-excluded-count-order-probe.mm`, freshly compiled against `4b7148c98`, sets A to two versions/count zero/excluded, B to one version/count one, and the cap to their existing 222 retained bytes. It queues an explicit counted open of A followed by an observed new B revision, lets the worker queue finish while the main queue is busy, and then services completions with the same fallback behavior. Exit code 0 reproduced:

```text
After explicit A open: A_count=1 A_versions=1; B_count=1 B_versions=2; limit=222 used=222
```

A's successful explicit open should have made the counts equal with A opened most recently. B's older saved version should therefore have been removed, leaving A with two versions and B with one. Delaying main-queue completion instead loses A's prior version. Record valid existing-document fallback counts on the serialized capture worker before processing subsequent captures, set the completion's recorded flag accurately, and preserve original-identity checks and exactly-once retry behavior. The analogous permanent capture-failure path should receive the same ordering protection.

The storage implementer received this probe and finding before this report was finalized. A source edit alone does not close it; rerun the probe with its survival expectation reversed and retain a regression.

## Findings independently closed

| Finding | Independent result |
|---|---|
| NT1, current successful capture omitted its own explicit open | `/tmp/native-open-cleanup-fixed-probe.mm` uses the new counted asynchronous API and reports `A_count=1 A_versions=2; B_count=1 B_versions=1; limit=222 used=222`. Count recorded flag is true and no error is returned. |
| NT2, phrase highlighting across actual Markdown soft wraps | `/tmp/native-history-search-fixed-probe.mm` renders the actual Markdown document into PDF and applies the new offset-mapped search. `café and` produces one mapped range and a PDF selection covering two lines. Additional helper probes exercised surrounding whitespace, accents, decomposed accents and emoji. |
| NT5, detached old History preview overwrote newer context | `/tmp/native-history-context-fixed-probe.mm` calls the new invalidation method at replacement, matching manager wiring. Delayed A completes after B is installed and persisted; the final persisted document remains B. |
| NT3, pending requests collapsed and excluded opens disappeared | The intent ledger now counts separate requests and deduplicates within one batch. Expanded cleanup tests verify excluded fallback batch counts, fast reuse, superseded explicit requests, precommit rollback/retry, postcommit retries and retained recorded status after permanent retry failure. Eventual count persistence is fixed; its fallback ordering is NT6. |

All three independent fixed probes exited 0. Preview/comparison budgets and `.mdown` dispatch were also re-inspected: preview and comparison now have separate bounds, and `.mdown` reaches the Markdown thumbnail path. Large-file boundary previews were not separately rendered in this round.

## Validation and limits

Fresh `make -C portable mac-collection-store-tests mac-collection-search-tests` exited 0 after the counted-capture changes. This independently compiled and ran storage, integrity, expanded cleanup and grouped-search suites; log: `/tmp/native-technical-review-final-tests.log`. The cleanup suite includes global prior-version ordering, whole-history Keep, shared objects/assets, cap and transaction failure preservation, original-file preservation, concurrent store counters, count/capture retry semantics and unused-store laziness.

The coordinator reports an earlier 23-suite native integration run passed in `/tmp/spdf-full-native-integration.log`; it predates the latest lifecycle and visual changes, so this report does not present it as final UI validation. No user app was launched, quit, ordered or screenshot during this technical review. Live restart behavior, the forthcoming visual redesign and full cross-process UI timing remain outside this round's independent evidence.
