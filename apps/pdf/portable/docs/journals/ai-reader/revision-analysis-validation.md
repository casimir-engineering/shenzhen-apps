# Latest-document analysis and revision context

10 October 2026

Automatic analysis ignores immutable Collection previews and editable copies tied to an older saved revision. Classification reads only Collection metadata, on the existing analysis worker, before content hashing or extraction. A candidate explicitly marked ineligible does not even create the worker. The latest source still uses the existing content/model/layout/prompt cache and process lock, so reopening the same bytes does not create another paid request.

A successful latest-document analysis retains one private bounded text baseline for its document identity, model, layout compatibility, and prompt version. On the next compatible revision, the model receives the previous summary, keywords and chapters plus exact page text replacements and nearby context. It does not receive another full copy of the extracted text. The baseline is replaced after source and live-layout validation succeeds. Different models, incompatible layouts, changed page coverage, or more than 32,000 changed UTF-16 code units fall back to the existing bounded excerpt analysis. Authored chapters still win.

Collection metadata exposes the revision count, dates and sizes without reading the archived document bytes. File size changes are deliberately not described as content diffs. An explicit revision-detail request compares only that revision and its predecessor using existing saved text indexes. It reads at most 4 MiB per index and compares at most 30 pages / 128,000 combined text characters. Results describe added and removed UTF-16 code units under the stated single-replacement-per-page algorithm. They are explicitly partial text excerpts: image changes and content outside the saved index are not measured. Missing, encrypted, or oversized indexes return an unavailable reason. No model call, history materialization, or whole-history hash pass occurs.

## Verification

The production-linked `SPDFMacAIAnalysisServiceTests` executable passed with exit code 0 on this change. Its cases include:

- No queue, hash, extraction, credential, network or directory work when analysis is disabled; the same no-work behavior for a explicitly ineligible older candidate.
- Content cache deduplication and process-safe one-request behavior.
- Source changes, stale layout, cancellation, authored chapters, partial coverage and upload bounds.
- Successive same-byte-size revisions send a two-character removal/insertion plus the previous analysis, with no full `pages` upload.
- Reopening the same hash does not reanalyze it; incompatible layouts safely use bounded full excerpts.
- Unicode emoji splices reconstruct the new text exactly and remain valid JSON.
- Oversized changes refuse incremental upload.
- A real temporary Collection records two versions, returns a bounded dated metadata page without creating previews, and lazily finds the same-size text change through its saved indexes.
- Both an immutable old preview and an editable old revision are ineligible for automatic summaries.

The first complete AI reader suite passed before parent metadata integration began. A later combined run reached an unrelated metadata-contract assertion while that integration was changing; the freshly linked analysis executable was then run separately and passed. The parent run performs the final integrated suite.

## Lifecycle and encoding follow-up

The technical review found a cache-lease race: an editable copy could become historical while waiting for another process, yet receive a cached summary. The worker now checks latest status again after obtaining the lease. Collection-copy requests also capture a revision generation. Local and cross-process committed Collection changes invalidate that generation, hiding already installed copy summaries and rejecting queued stale completions. The active copy is rechecked on the worker after a capture promotes it to latest. Notifications are scoped to the Collection roots represented by that reader's copies; unrelated temporary stores do not invalidate user documents. Opting out disables the observer before it queues any work. None of these display checks read the Collection manifest.

A separate test places an emoji across the 64,000-unit analysis upload boundary. Clipping now uses the shared Unicode-safe prefix helper, and failed JSON encoding returns an error before request construction. Tests cover the lease race, installed and queued stale copy results, actual second-process invalidation, unrelated-store isolation, and the post-opt-out no-work path.
