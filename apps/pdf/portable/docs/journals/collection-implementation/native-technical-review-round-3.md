# Native Collection technical review — round 3

2026-09-23. Final focused technical follow-up through `913a26d17`, including inspection of the current usage integration and retained History lifecycle/search fixes. No production files were changed by this review.

**Score: 9.2/10 for the reviewed technical scope. No major or medium finding remains.** The last medium finding, NT6, is independently closed. This exceeds the requested technical threshold; it is not approval of the visual restructuring currently in progress or its final native build.

## Ranked findings and disposition

| Priority | Finding | Final disposition |
|---|---|---|
| Medium | NT6: excluded/failed-open fallback could lag a later cleanup | Closed by independent reproduction and freshly compiled regression suites in this round. |
| Medium | NT1: successful capture pruned before counting its triggering open | Closed in round 2; the transactional count-before-cleanup path remains present. |
| Medium | NT5: an obsolete History preview could overwrite newer persisted context | Closed by the delayed-controller probe in round 2; explicit invalidation, completion guards and shared preference queue remain present. |
| Medium | NT2: Markdown phrase highlighting failed across actual rendered line wraps | Closed by the actual two-line PDF-selection probe in round 2; the normalized search with original-text offset mapping remains wired into History. |
| Medium | NT3: separate pending opens collapsed and successful uncaptured reads went uncounted | Closed. The ledger retains separate request counts, deduplicates within each batch, and the serialized fallback now records excluded/failed reads before subsequent queued cleanup. |
| Minor | NT4: preview/comparison budgets and `.mdown` thumbnail dispatch differed | Source repairs remain present. Separate preview/comparison limits and supported-extension dispatch were inspected; large boundary-size documents were not independently rendered. |

There are no remaining ranked corrective findings in this bounded technical review.

## NT6 verification

`SPDFMacCollectionStoreScheduling.mm:43` records outstanding usage for a retained document under the store transaction. Only a successful commit clears the pending count and marks it recorded. The worker invokes this fallback at line 94 before deciding on retries or posting completion, so a busy main queue cannot postpone the count until after another queued capture.

I independently rebuilt the original excluded-open ordering probe with `-O2 -Wall -Wextra -Werror`. The only changed expectation requires the repaired survival order, exactly one persisted A open, and both completions. `/tmp/native-excluded-count-order-final-probe.mm` exited 0 and printed:

```text
After explicit A open: A_count=1 A_versions=2; B_count=1 B_versions=1; limit=222 used=222
```

The probe deliberately holds the main queue while both worker operations finish. A's explicit open now affects ranking before B's observed revision triggers cleanup. Processing the delayed completion does not increment A again. The old code produced A with one retained version and B with two under the same fixture.

The current coordinator consumes the pending ledger count before invoking counted capture and requests its extra fallback only when `userOpenCountRecorded` is false. The worker's committed count therefore suppresses that second write. Retry state carries a zero remaining count after successful persistence, retaining the recorded flag even if a later retry fails. Archive and disabled-store checks preserve laziness.

## Test evidence and scope

Fresh `make -C portable mac-collection-store-tests` exited 0. Storage, integrity and expanded cleanup binaries were rebuilt and run; log: `/tmp/native-technical-review-round3-tests.log`. The suite verifies busy-main cleanup ordering, no delayed-completion double count, excluded and epoch-cancelled reads, fast protection reuse, separate superseded open requests, precommit rollback/retry, postcommit retries, permanently failed retries after a recorded count, concurrent store counters and unused-store laziness. The original cleanup safety, Keep protection, shared-file accounting and failure-preservation tests also pass.

The grouped-search suite and three independent History/count probes passed in round 2; those results are not represented as new executions in this round. The corresponding lifecycle/search wiring was re-inspected here. No user app was launched, quit, ordered or screenshot.

Visual restructuring, its newest layout/accessibility behavior, the final complete native integration run/build, and live restart verification remain separate pending evidence owned by the coordinator and UX review. They must not inherit this technical score automatically.
