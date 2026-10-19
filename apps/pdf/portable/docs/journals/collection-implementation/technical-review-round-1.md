# Technical review · round 1

23 September 2026 · Independent Astra technical critic

**Score: 6.8/10. Not acceptable for release yet. Two major and four medium findings remain in the implementation reviewed.** This is a substantial, well-separated implementation with real safeguards and useful tests. The remaining issues include a reproducible false protection guarantee and an unprotected overwrite, so the passing normal-path suites do not justify an 8 or 9 yet. Repairs started during review are not credited here; they need independent verification in round 2.

## Ranked findings

### T1 · Major · A late external edit is falsely recorded as protected

**Location:** `portable/mac/SPDFMacCollectionStoreCapture.mm:113`, `:148`; `portable/mac/SPDFMacCollectionStoreFingerprint.mm:11`, `:28`.

The last source consistency check precedes writing the text index. `recordFingerprints:` subsequently reads the *current* source and dependency metadata into the trusted cache. If an external editor replaces A with B after the consistency check, the manifest archives A but fingerprints B. The cheap protection check then returns YES for B without ever capturing it. An app-owned overwrite can consequently destroy B while claiming its pre-edit revision is protected.

**Reproduced headlessly:** a test subclass injects a real atomic source replacement immediately before calling the superclass `recordFingerprints:`. This deterministically selects the production race window; it does not fabricate manifest contents or bypass the protection gate. Output:

```text
race: gate=1 versionCount=1 source=EXTERNAL REVISION B latestArchive=REVISION A
```

**Required remedy:** derive the trusted source fingerprint from the stat that validated the captured bytes and the dependency fingerprints from the validated captures. Never publish later, unvalidated metadata as proof of those bytes. Add a biting race regression for both the source and a linked asset. It is fine for a subsequent check to reject a changed revision and retry.

### T2 · Major · Save a Copy can overwrite another source without protection

**Location:** `portable/mac/SPDFMacCollectionStoreExport.mm:14`, `:58`; callers `SPDFMacCollectionWindowActions.mm:73` and `SPDFMacCollectionExportIntegration.mm:15`.

Export rejects Collection storage and the archived document's own original, but accepts any other existing file and atomically replaces it. Neither caller protects that destination. A save-panel Replace choice authorizes overwriting the selected file, but does not waive the promised Collection pre-edit history guarantee.

**Reproduced headlessly:** export A onto a separate file containing its only copy of `ONLY COPY OF TARGET`; result:

```text
export: overwrote=1 target=REVISION A targetHistory=0
```

**Required remedy:** either require a new destination for Save a Copy and reject existing targets, or pass every existing destination through the same durable protection gate and explicit failure choice as other writes. Cover a never-collected destination, an already-collected destination, quota failure and destination races.

### T3 · Medium · An unrelated same-path replacement inherits another document's identity

**Location:** `portable/mac/SPDFMacCollectionStoreCapture.mm:43` and `:62`.

The path lookup adopts an existing document before examining file identity. The inode logic only handles moves into a new path. After an original is removed while the app is closed and an unrelated file takes that exact current path, reopening it appends to the old history. The existing reused-*alias* regression exercises a different case and does not catch this.

**Reproduced headlessly:** remove the captured source, move a separately-created unrelated file to the same path, construct a fresh store, then capture with reason First opened:

```text
identity: unrelated same-path after new store merged=1 versions=2
```

**Required remedy:** make continuous watched/app-owned save evidence explicit. A normal atomic save with that evidence retains identity; an ambiguous replacement without it creates a separate entry unless explicitly linked. Add distinct tests for both behaviors and a verified move.

### T4 · Medium · Reference-style Markdown assets are silently lost

**Location:** `portable/mac/SPDFMacCollectionStoreAssets.mm:8`.

The two regular expressions only discover inline parenthesized destinations and HTML attributes. Valid reference-style image destinations, including `![Logo][image]` with `[image]: logo.svg`, are not discovered. The archive records no dependency and no warning while claiming Protected; offline preview/export loses the image.

**Reproduced headlessly:** capture that Markdown alongside an existing bounded SVG:

```text
reference asset: assets=0 warnings=0 status=Protected
```

**Required remedy:** derive destinations from the Markdown parser's resolved image/link nodes, or implement reference resolution consistently with the renderer. Cover full, collapsed and shortcut references, escaped destinations, missing assets and asset-only edits. Unsupported dependencies must at least produce an explicit incomplete-capture warning.

### T5 · Medium · Repeated text headers defeat image-page insertion alignment

**Location:** `portable/mac/SPDFMacCollectionCompareLoad.mm:78`; `portable/mac/SPDFMacCollectionCompareEngine.mm:31`.

A page key uses only text whenever a page has any text. Two otherwise distinct drawing/image pages that share a title/header therefore have the same key. Insert a third differently illustrated page with that same header at the front: old `[H,H]` and new `[H,H,H]` align as `(0,0),(1,1),(-1,2)`, comparing each original against the wrong image and presenting the last original as newly inserted. This is a common hybrid PDF shape, not just identical duplicate pages.

**Evidence:** direct source analysis of the key construction and equality-first alignment, supported by the existing pure alignment tests. I did not run a new end-to-end hybrid-PDF loader fixture in this round.

**Required remedy:** use visual information to disambiguate repeated text anchors while retaining tolerant text correspondence for changed pages. Add a loader-level fixture with identical headers, distinct image bodies and an insertion/deletion in the middle; verify subsequent original pages pair with their actual counterparts and have no spurious changes.

### T6 · Medium · Failed asynchronous captures never retry automatically

**Location:** `portable/mac/SPDFMacCollectionStoreCapture.mm:173`–`:184`; `portable/mac/SPDFMacCollectionIntegration.mm:65`.

The background operation calls synchronous capture once and reports failure. The three immediate retries inside byte reading do not retry a change during commit/indexing or a transient destination failure. No delayed retry is queued after failure, including a failed post-edit capture. If an external save races capture or a disconnected destination returns, the current document stays unprotected until a later open/reload or manual edit gate causes another attempt.

**Evidence:** source inspection of capture scheduling, completion and integration; no time-based retry probe was run. The approved contract explicitly requires transient and post-edit retries while keeping reading available.

**Required remedy:** bounded, cancellable backoff keyed by source identity, with deduplication and fresh enabled/excluded checks before each attempt. Preserve the failure and last-success state until a genuine durable capture completes. Test a transient first-attempt failure followed by success without another open, disabling/excluding during backoff, and persistent failure without a hot loop.

## Observed strengths

- Content-addressed objects are immutable copies, verified before materialization; exports do not share their inode with archive objects.
- Atomic file publication, file/directory fsync, a cross-process flock and post-lock root revalidation provide a serious persistence foundation.
- Corrupt manifests are rejected for writes rather than overwritten with empty history; encrypted PDF bytes remain encrypted and omit the plaintext index.
- Storage limits preserve existing history rather than silently deleting it. Exclusion persists independently of archive deletion.
- Collection construction and disabled capture have explicit laziness tests. Heavy snapshot/index work is queued after opening; the first-use decision precedes capture.
- Comparison has bounded page/region/LCS budgets, isolated documents, real text geometry, visual regions and empty counterpart slots. The issue in T5 concerns anchor selection, not absence of a comparison engine.

## Verification and limits

Read the repository instructions, agent handoff, approved proposal and action journal; inspected the tracked diff and new Collection store, capture, fingerprint, assets, search, location, export, comparison, palette, recovery and integration files. Reviewed the relevant existing tests and source write hooks. No app was launched, quit, controlled or captured by this critic.

Independently ran the already-built `portable/build/SPDFMacCollectionStoreTests`, `SPDFMacCollectionIntegrityTests` and `SPDFMacCollectionCompareTests`; all exited 0. These were existing binaries, not a claim of a fresh full-app build. Separately compiled the temporary probe against the current store sources and ran it successfully. Its exit 0 means the printed bugs reproduced, not that acceptance passed.

Temporary reproduction source: `/tmp/spdf-tech-review-probe.mm`. Build command:

```sh
clang++ -std=c++17 -fobjc-arc -Wno-deprecated-declarations \
  -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation \
  -Iportable/mac /tmp/spdf-tech-review-probe.mm portable/mac/SPDFMacCollectionStore*.mm \
  -framework Cocoa -framework PDFKit -o /tmp/spdf-tech-review-probe
/tmp/spdf-tech-review-probe
```

The broader engine/UI/agent regressions and live consent/search/navigation checks are root-reported evidence, not independently rerun here. This bounded first pass does not certify crash/power-loss behavior on real storage, long-term quota growth, every source-writing tool, or every accessibility interaction. Release review should prioritize the six findings above and biting regressions before repeating the full integration build.
