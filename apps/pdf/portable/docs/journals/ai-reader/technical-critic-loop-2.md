# Technical critic — loop 2

Reviewed 2026-10-09–10 against the evolving working tree, then rechecked the final focused binaries. **Score: 9/10 for the reviewed technical implementation.** No unresolved P1 or P2 finding remains from this review. This is not a claim of authenticated OpenRouter acceptance, complete human-action parity, or a completed release regression run. The small unconditional Markdown provenance cost below is real and must not be described as literally zero new launch work.

Read repository instructions, agent handoff, architecture, Markdown contract, AI implementation plan and loop 1. The critic did not edit implementation files, launch/quit the user app, or take app screenshots. Findings were sent to the implementation owners, who made the fixes; the critic re-read them and reran headless tests.

## Ranked findings and disposition

### P1 — Old Markdown text could be labelled with a new source revision — fixed

`SPDFMacAIToolsReader.mm:48`, `SPDFMacMarkdownSession+Paper.mm:60`, `SPDFMacAILiveTextContext.mm:17`.

Candidates originally paired a fresh disk stamp with the session's existing rendered document. During asynchronous reload, the reader intentionally retains its old visible pages. A read during that interval could therefore report old text under the new revision; background analysis could hash new source bytes while analyzing old text.

The parser seam now records the source revision around the actual source load and associates it with the parsed model. Rerendering retains that provenance; disk reload replaces it. Candidates expose a live snapshot only when the loaded revision still matches the file. Context and preview extraction require the matching source revision. Production-linked tests exercise initial installation, a disk change before watcher reload, rejection of a forged new revision with old source provenance, and successful completed reload.

### P2 — Consecutive file actions could not both be undone — fixed

`SPDFMacAIFileTransaction.mm:15`, `SPDFMacAIFileTransaction.mm:74`.

The initial inverse checked inode/timestamps. For A→B→C, undoing C restored B's bytes with a new stamp, so the preceding B→A inverse incorrectly failed. An independent production-source probe reproduced `mutations=1/1 undo-second=1 undo-first=0`.

Receipts now guard the exact resulting content with SHA-256 and capture a fresh revision for the final replacement check. The same standalone probe rebuilt against the fix reports `mutations=1/1 undo-second=1 undo-first=1`. The production-linked suite also covers chained Undo, failed staged mutation and rejection of an intervening external edit.

### P2 — Concurrent chat writers could silently discard another window's messages — fixed

`SPDFMacAIChatStore.mm:79`, `SPDFMacAIChatSession.mm:32`.

The shared lock serialized whole-file replacement but did not detect two writers extending different copies of the same transcript. Saving now checks that the already committed transcript is an exact prefix of the incoming messages under the lock. A conflicting session stops requests/tools and retains its unsaved conversation with an actionable error. Tests confirm the stale writer cannot erase the first window's answer. Existing deletion tombstones remain independent of this conflict guard.

### P2 — Citation checks and navigation had gaps — fixed

`SPDFMacAICitations.mm:28`, `SPDFMacAIIntegration.mm:129`, `SPDFMacAITools.mm:296`, `SPDFMacAITools.mm:372`.

Typed page parsing alone still accepted a model-invented document link. The new route requires strict parameters and an exact normalized citation previously issued in this chat's tool result or trusted page-preview record; assistant prose cannot register evidence. Persisted tool results support resumed chats without a process-local-only registry.

Separately, layout verification occurred against a captured Markdown candidate on the worker, while the final main-thread navigation checked only source bytes. Navigation now re-fetches the candidate and rejects changed live rendered/plan identity before mutation. A layout-bearing citation cannot fall through the unloaded-text page-one shortcut. Tests cover fabricated citations, duplicate parameters, valid issued evidence and the main-thread layout race.

### P2 — New document inverses could overwrite a later human page move — fixed

`SPDFMacAIDocumentActions.mm:19`, `SPDFMacAIDocumentActions.mm:107`.

The new open/close adapter's fingerprint omitted the page even though its inverse restored captured navigation. The fingerprint now includes the actual current page, and a regression verifies that a later human page change blocks the inverse. Scoped reader-control inverses continue to preserve unrelated settings changes.

### P2 — Generated metadata disappeared after reflow or unrelated Settings edits — fixed

`SPDFMacAIAnalysisIntegration.mm:28`, `SPDFMacAIAnalysisIntegration.mm:45`, `SPDFMacMarkdownSession.mm:408`.

Every settings edit previously cancelled analysis and cleared installed metadata. Markdown theme/font/paper rerenders invalidated snapshot pointers without scheduling replacement analysis. Configuration now compares an immutable enabled/automatic/model tuple, preserving results for unrelated changes. An optional render-installed callback schedules analysis only after a completed rerender and only while automatic analysis is enabled; viewport scrolling is not a trigger. The cache handles an unchanged semantic layout without another provider request. Tests cover equivalent settings, stale installation, disabled entry-point laziness and the rerender callback.

### P2 — New job acceptance needed isolation and descendant cancellation evidence — fixed

`SPDFMacAIDocumentJobsIntegration.mm:66`, `SPDFMacAILocalTool.mm:39`.

The initial exports root ignored `SPDF_STATE_DIR`; it now uses the shared state-directory helper. Completion also guards the captured Markdown layout. The job owner added a spawned-child/delayed-marker test, in addition to the uncooperative parent test, so Stop verifies termination of owned tool descendants as well as suppression of late output. The focused job executable passed independently after these changes.

### P2 — New reader acceptance suites were outside ordinary release discovery — fixed

`portable/Makefile:842`.

Reader/context/analysis/view tests previously required an extra `-f` argument. The main Makefile now includes guarded helper makefiles and exposes the reader and document-job test targets directly, so release discovery sees them.

### P3 — Markdown source provenance adds a small unconditional parse cost — retained, explicit limitation

`SPDFMacMarkdownSession+Paper.mm:60`.

The correctness fix adds two metadata stamp operations around Markdown parsing even when AI is disabled. The implementation owner measured 4.821 microseconds per pair over 10,000 warm local iterations; this critic did not independently reproduce that timing. It performs no extra source read, content hash, credential access, model request, cache creation or AI worker allocation. Disabled analysis is tested inert at the production open entry point. Nevertheless, a warm metadata microbenchmark is not an end-to-end cold/network-volume launch comparison, and the literal claim “nothing new runs on launch” would be inaccurate.

## Executable evidence

All results below were judged by process exit status, not text filtering. Shared build objects were left to the implementation owners; the critic reran the resulting headless executables.

The parent reports that the final ordinary entry point, `make -C portable -j4 mac-ai-reader-tests mac-ai-document-job-tests`, rebuilt and passed with exit 0 after the source-provenance fixture changes; log `/tmp/ai-acceptance-stable.log`. The critic then independently reran its newly linked context, analysis and view executables listed below.

- `SPDFMacAIChatSessionTests`: exit 0, including malformed response/stored history, cancellation, deletion, concurrent-writer and issued-citation cases. `/tmp/spdf-ai-loop2-chat-latest.log`.
- `SPDFMacAITransportTests`: exit 0. `/tmp/spdf-ai-loop2-transport.log`.
- `SPDFMacAIModelCatalogTests`: exit 0. `/tmp/spdf-ai-loop2-model.log`.
- Final `SPDFMacAIDocumentContextTests`: exit 0. `/tmp/spdf-ai-loop2-context-final.log`.
- Final `SPDFMacAIAnalysisServiceTests`: exit 0, including two independent processes issuing one request per cache key. `/tmp/spdf-ai-loop2-analysis-final.log`.
- Final `SPDFMacAIChatViewTests`: exit 0. `/tmp/spdf-ai-loop2-view-final.log`.
- `SPDFMacAIDocumentJobsTests`: exit 0; malformed-PDF diagnostics are intentional failure fixtures. `/tmp/spdf-ai-loop2-jobs.log`.
- Independent chained-file-Undo probe compiled against production transaction code: exit 0 after the fix. `/tmp/spdf-ai-undo-chain.mm`, `/tmp/spdf-ai-undo-chain`, `/tmp/spdf-ai-loop2-undo.log`.

Loop 1's crash, path disclosure, broken typed citations, history Stop, fresh-chat entry, preview cleanup/deletion, model catalog and analysis cache identity findings have concrete implementation changes and focused coverage. The score increase comes from those fixes and the additional executable evidence, not from reducing the earlier requirements.

## Scope and remaining acceptance

Supported assistant actions include bounded workspace/Collection discovery, current-layout text/search/page previews, document navigation, group changes, reader controls, protected PDF comment/rotation transactions, limited rename, tab close/reopen, and staged export/local OCR/local translation with guarded Undo. They do not constitute every human action in the app. Arbitrary file deletion, general PDF content editing, arbitrary Save As destinations, printer interaction, support installation and encrypted-document workflows still require native human flows or remain unsupported. Do not advertise universal reversibility or full menu parity.

The critic used no account key and made no authenticated provider request. Browser authentication success, real model tool behavior, actual installed OCR/translation language quality and the parent's isolated native interaction exercise are separate evidence. The local job tests use controlled executables. No complete release suite or cold-launch comparison was independently run by this critic. Automatic analysis remains explicitly bounded to supplied excerpts; generated summaries and chapters are not evidence for unread pages.
