# Technical review · round 2

23 September 2026 · Independent Astra technical critic

**Score: 8.0/10. The two major findings from round 1 are fixed. Three medium findings still prevent the requested ≥9/no-medium release recommendation.** The repairs are substantive: captured metadata now refers to captured bytes, Save a Copy cannot overwrite an existing destination, identity continuity is explicit, hybrid comparison anchors include visuals, and transient capture failures retry. The remaining problems concern how those mechanisms interact with deferred work and literal Markdown content.

## Round 1 disposition

| ID | Result | Independently checked evidence |
|---|---|---|
| T1 · false protection after late source replacement | Fixed | Freshly compiled integrity suite passes its injected late-replacement test. Stored source/dependency fingerprints come from the validated capture; a post-commit source mismatch returns code 5 rather than success. |
| T2 · export overwrites another original | Fixed | Fresh integrity regression preserves another original. Source inspection confirms an early existing-target rejection plus exclusive `link()` installation closes the destination-creation race. |
| T3 · unrelated same-path replacement merged | Fixed at store boundary | Fresh integrity tests distinguish ambiguous new-inode opens from explicit known saves, retain the former document as unavailable, and reject a superseded continuation ID. Integration gaps are T7/T8 below. |
| T4 · omitted reference-style images | Fixed for reported forms | Fresh integrity suite covers full, collapsed and shortcut image references. The remaining parser-boundary issue is T9 below. |
| T5 · hybrid page insertion alignment | Fixed | Independently ran the updated comparison-loader binary, built after its source/test changes. Front/middle insertions and deletion with repeated selectable headers and distinct raster figures pass, with unchanged following pages unmarked. |
| T6 · no asynchronous transient retry | Fixed for bounded transient retries | Fresh integrity test injects two transient failures, then verifies successful third attempt and main-thread completion. Source rechecks enabled/excluded state; delays are bounded at 250/500 ms. Persistent unavailability remains an explicit failed state, rather than a hot loop. |

## Ranked remaining findings

### T7 · Medium · A stale background open capture can split a legitimate app save

**Location:** `portable/mac/SPDFMacCollectionStoreCapture.mm:203`, `:215`, `:68`; `portable/mac/SPDFMacCollectionIntegration.mm:49`.

The synchronous pre-edit gate and queued background capture are not coordinated by source generation. An initial generic capture can be queued before an edit but only read the file after the edit. It then sees the new inode without continuation evidence, declares the protected pre-edit document replaced, and starts a new identity. The queued successful-save capture carries the correct old identity, but now fails with code 19 because the stale generic job superseded it.

**Independent deterministic reproduction, compiled against current sources:** `/tmp/spdf-tech-round2-queue.mm` delays the first asynchronous generic open just before its source read. While delayed, a synchronous pre-edit gate archives A and returns its ID; the probe atomically writes B and queues a saved capture with that ID. Releasing the older open job produces:

```text
gate=1 rows=2 originalVersionCount=1 savedError=19 currentIdentityChanged=1
```

The semaphore selects a plausible queue/lock scheduling interval; the source writes, store calls and returned failure are real. Both bytes survive, but a normal edit fragments one document's history, incorrectly marks its original replaced, and reports failed post-save capture.

**Required remedy:** coordinate pending generic captures and successful writes per path/document generation. A stale queued open must not supersede identity after an authorized write. Cancellation alone must also handle an operation already waiting to enter the transaction. Add this ordering as a biting regression, alongside the normal queued-open and unrelated-replacement cases; consider multiple store instances/processes, not only one queue.

### T8 · Medium · Focus-detected external saves omit continuity evidence

**Location:** `portable/mac/ShenzhenPDFMac.mm:6737`, `:6753`, `:6777`; the only observed-change recording calls are currently in the active watcher path around `:6651` and `:6684`.

`checkAllTabsForExternalChangesOnFocus` explicitly detects changes against an already-open tab's cached source state. However, neither its read-only nor writable branch records Collection continuity before reloading the active tab or discarding an inactive tab's cache. The later load uses generic capture. A normal atomic external save to an inactive open tab is consequently treated as an unrelated same-path replacement when that tab is selected.

**Evidence:** traced the confirmed-change branches and their capture path in source; this round did not operate the live app to reproduce the tab interaction. The store's tested nil-continuation behavior establishes the resulting identity split.

**Required remedy:** record observed continuity at each confirmed external-change boundary before reload/cache invalidation, including inactive tabs and any equivalent activation-time checks. Keep generic newly-opened paths without such evidence conservative. Add a headless integration regression for open A → inactive A → external atomic save → focus check → reactivate A, asserting the same document ID and two versions.

### T9 · Medium · Literal Markdown examples archive unrelated adjacent files

**Location:** `portable/mac/SPDFMacCollectionStoreAssets.mm:9`, `:20`, `:31`.

Dependency discovery still scans raw Markdown with regular expressions, including fenced code, inline code and other literal syntax. A document demonstrating `![Example](private.txt)` in a fenced code block displays that string as code, but Collection treats `private.txt` as a real dependency and retains its contents. This exceeds the intended document dependency set and can silently collect private adjacent files that were never rendered or opened as an asset.

**Independent reproduction:** `/tmp/spdf-tech-round2-assets.mm` creates an adjacent `private.txt` and passes this Markdown to the production asset collector:

````markdown
# Syntax example

```markdown
![Example](private.txt)
```
````

Output:

```text
fenced code example dependencies=1 filename=private.txt
```

**Required remedy:** discover dependencies from parsed, resolved image/link nodes, with the same literal/code/escape semantics as the renderer. If a filtering implementation is retained, prove it handles fenced and indented code, inline code, comments and escaped syntax, while retaining real inline/reference/HTML assets. Add an assertion that the unrelated file never enters the object store, not merely that a warning appears.

## Verification and limits

Freshly compiled `SPDFMacCollectionIntegrityTests.mm` against all current Collection store modules into `/tmp/spdf-tech-round2-integrity`; ran it with exit 0. Separately compiled and ran the two new probes above with exit 0 and the quoted outputs. As in round 1, their exit 0 indicates successful reproduction, not passing acceptance assertions.

Independently ran `portable/build/SPDFMacCollectionCompareLoadTests`, `SPDFMacCollectionPaletteTests` and `SPDFMacCollectionStoreTests`; each exited 0. Confirmed the comparison-loader binary timestamp was newer than the changed loader and its expanded hybrid-page tests. Read the changed store/fingerprint/export/assets/retry code, comparison loader and tests, and the coordinator's pre-edit, post-save, watcher, focus, generic-open and OCR hooks. The explicit successful-save hook and separation of pending-save IDs from watcher IDs are improvements; T7/T8 identify uncovered interactions rather than asking to revert conservative identity handling.

No app was launched, quit, controlled or captured by this critic. Root's full build, manager/search/export UX repairs and the concurrent thumbnail changes are not independently certified here. This score is for the snapshot inspected and the evidence above; subsequent repairs require the next review round before raising it.
