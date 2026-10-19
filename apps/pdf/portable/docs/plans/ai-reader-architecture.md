# Document assistant: implementation contract

The assistant belongs to the reader. It helps find, understand and organize the user's documents without delaying launch or opening a file. This document records the intended architecture, not a claim that every item is already implemented.

## Interaction and scope

- Command-K retains instant document search. Return on an empty query opens a fresh chat. A nonempty query keeps normal result activation and offers an explicit Ask action; ordinary navigation never unexpectedly sends content to a provider.
- Chat reuses the palette surface. Messages are displayed newest first, with readable Markdown, clickable verified document/page citations and bounded image previews. A Stop button cancels generation and pending tool work. Completed reversible actions have Undo; stopping does not silently undo completed actions.
- A chats icon immediately left of the group manager and before its separator opens recent chats, New Chat, delete one and delete all. Conversation deletion does not delete documents or silently undo edits.
- One reusable Settings panel includes reading preferences, Collection consent and AI connection/preferences. Opening it replaces fragmented first-use prompts. A versioned introduction flag causes existing users to see the new panel once; it does not clear their existing choices or reconnect disabled AI.
- OpenRouter connection uses browser authorization where supported, with secure manual key entry as fallback. Keys live only in Keychain. Never embed an account credential in source, YAML, logs, prompts, or tests.
- Model selection uses provider model identifiers validated against the live catalog; never invent an ID from a marketing name. The requested DeepSeek Flash preference is selected only if available. A different model is displayed explicitly.

## Privacy and fast paths

AI is optional. Cloud document analysis requires an explicit Settings choice explaining what is sent. No model request, content hashing, text extraction, assistant directory creation, credential access or AI worker allocation occurs during ordinary launch. After a successful user open and consent, queue low-priority analysis after the reader is ready. Merely restoring tabs is not opening every document for analysis.

All requests require provider no-training and zero-retention routing; do not silently retry with weaker privacy. Model messages distinguish user instructions from quoted document data. Text inside a document cannot grant tool authority, request other documents, or change privacy controls. Tool access is bounded to the workspace/Collection selected by the user. Do not let a model send arbitrary file paths, selectors, shell commands or URLs to executable dispatch.

## Context hierarchy

1. Cheap workspace map: group IDs/names, document IDs/titles/types, active document/page. Do not send full filesystem paths when opaque IDs suffice.
2. Available authored outlines and cached short summaries/keywords for shortlisted documents.
3. Search indexes and bounded snippets with exact page anchors.
4. Selected page text and, only when necessary, selected rendered page images.
5. Additional pages on demand, rather than serializing whole documents into every turn.

Summaries aid retrieval and are never evidence themselves. Answers cite actual retrieved passages. Page references are one-based and validated against the exact document revision. Markdown page anchors include layout/dependency identity because pagination may change without changing its source text.

## Existing integration seams

- `SPDFMacAgentGroups.mm`: validated live group listing and mutations. Saved-session operations already have a separate implementation for offline organization.
- `SPDFMacAgentPDFInspection.mm`: engine-backed bounded canonical page text and geometry. It must remain explicit and headless.
- `SPDFMacPaletteTextSearch.h` / `SPDFMacSearchFileCache.h`: lazy immutable extraction/cache and Markdown image dependency stamps. Reuse the mechanisms rather than creating another unbounded index on launch.
- `SPDFMacCollectionStore*`: immutable revision hashes, existing per-page indexes and protected writes. AI-generated metadata must not rewrite original files or create artificial Collection versions.
- The reader's comment actions currently save through the core and refresh version history. They are not a general undo API. Do not expose arbitrary existing menu selectors and call that reversible AI control.

## New focused modules

- `SPDFMacAIDocumentContext`: bounded outline/page extraction, cancellable text search, validated revision identity, hash-addressed summary/keyword/generated-outline cache. No reader or network dependency.
- `SPDFMacAITools`: strict JSON schemas, allowlisted operations, generation cancellation and action receipts.
- `SPDFMacAIToolsReader`: main-thread reader adapter, group snapshot/restore, navigation and live state validation.
- Provider transport, authentication, chat persistence, settings, palette chat presentation and document analysis scheduling remain separate files owned by their implementation tracks.

No new state belongs in the capped coordinator/private-header hotspots. Use focused category seams and an explicitly created coordinator. Keep new maintained files under 500 lines. App sources are globbed; headless test source lists require explicit additions.

## Transactions and cancellation

Every action receives a unique action ID and a request generation. Revalidate generation immediately before committing. Read tools run on a bounded worker queue. UI mutations run on main. A cancelled request cannot publish stale output or execute its next queued tool.

Group changes record prior membership/order/names/colors/collapse/visibility and the resulting state fingerprint. Undo only applies while that resulting state still matches, so it cannot overwrite intervening human edits. Navigation retains the previous document/page. Document writes use a protected preimage, revision guard, staged output and atomic replace; inverse restores the preimage only if the current bytes match the action's SHA-256 result. A freshly captured stat revision guards the final replacement. This permits chained Undo through new filesystem timestamps without overwriting changed content. Undo is available to both the user and the model as an explicit tool. Preserve independent human edits rather than promising universal blind rollback.

Tools must report unsupported capabilities accurately. Destructive irreversible operations cannot be advertised until a reversible staging path exists. Native permission/password/file panels remain human interaction, with cancellation propagated to the assistant.

## Automatic analysis

Cache key: SHA-256 content identity + format/layout/dependency identity + schema/prompt version + model. Store short summary, keywords and generated chapters in private sidecar metadata. Reopening unchanged content performs no second model call. Deduplicate simultaneous analysis requests across windows. Recheck the revision before installing results.

Generate chapters only when there is no authored usable outline. Validate each returned title, level and page against the source, and label the result AI-generated. User can remove/regenerate it; never overwrite authored PDF bookmarks or Markdown headings. Scans with no readable text should offer OCR, not fabricated chapters.

## Verification acceptance

1. Launch and opening with AI disabled allocate no assistant cache/queue, read no key and send no network request. Existing launch-work-policy tests stay green.
2. Repeated unchanged document analysis makes one request; changes invalidate; stale callbacks never replace current metadata.
3. Empty Command-K Return enters chat, nonempty search selection still opens its result, Escape closes the topmost surface, and no shortcut leaks into document search.
4. All new controls have full-bounds mouse-down/up tests at smallest supported width, 1x/2x backing scales and both appearances. Vector icon aspect ratios remain fixed.
5. Mock transport tests cover streaming chunk boundaries, cancellation, auth failures, rate limits, provider error, privacy routing and unavailable model.
6. Tools reject unknown names/fields, wrong types, unsafe paths, stale revision IDs and excess budgets. Document text containing tool-like instructions is treated as data.
7. Search/read results include correct matching text and verified page citations across PDF and rendered text; oversized inputs return explicit truncation with continuation.
8. Group mutations and comment changes can be undone without losing independent edits; cancellation before commit leaves state unchanged. Post-commit Stop exposes the completed action and Undo.
9. Chat deletion and settings changes persist across processes without storing credentials. Deleting all chats clears private transcript attachments too.
10. Run relevant Collection, group, search, Markdown, rendering, updater and launch suites. Judge each by its exit code; document pre-existing failures separately.
11. At most four review loops. Independent technical and UX critics provide a score and ranked reproducible findings, with score >=9/10 and no unresolved major/medium defects before claiming readiness. Scores cannot replace executable evidence.

## Tool implementation verification (9 October 2026)

The production bridge now exposes workspace/Collection discovery, bounded page reads and search, trusted page previews, revision/layout-checked navigation, group organization, reader controls, PDF comment edits, tab close/reopen, safe same-folder rename, and asynchronous PDF export/OCR/translation jobs. Opaque IDs replace filesystem paths in provider-facing fields. Job outputs have owned identities and their inverse closes the generated tab and removes only the unchanged generated file.

`SPDFMacAIDocumentContextTests` links the production adapters. The reader host fixture replaces native window/open/close effects; core PDF extraction, saved-file mutations, Collection storage, output generation and tool dispatch are real. Tests cover exact snippets, text-layout identity, lazy cache reads, cancellation after permission handling, grouped workspace restoration, chained file Undo, failure before atomic replacement, external-file edit races, human page-navigation guards, stale-layout navigation races, rename/reopen, Collection original/copy choice, and asynchronous export followed by Undo. The latest build and run returned exit 0.

Remaining explicit adapter boundaries: encrypted PDF mutations require a password-aware staging transaction; read-only and Collection-working-copy renames require the native Rename/Save As flow; arbitrary original-file deletion is not exposed. Local OCR and translation require already-installed tools. Tool discovery and errors disclose these boundaries rather than promising unavailable operations. No live provider request or user-app launch was used by this test suite.

Source-provenance correction (10 October): each existing asynchronous Markdown parse now brackets its source read with two metadata-only stat stamps and attaches the validated stamp to the parsed model. No AI queue, credential access, content hash or extra source read is added. This small shared-reader cost is unconditional so later explicit chat can trust already-open snapshots without forcing a full reload. A local 10,000-pair benchmark measured 4.821 microseconds per pair; this is a warm-local-file measurement, not a universal storage-latency guarantee. Real session tests prove that a changed disk file cannot relabel old text as fresh, and a completed reload installs the new provenance.

Large-workspace discovery (10 October): `list_workspace` returns up to 50 groups and 50 document titles by default (maximum page size 100), with independent one-based `next` and `nextGroup` continuations and optional document `groupID` filtering. Group rows contain counts rather than every member path. Discovery performs no candidate file-stat pass or summary lookup. `document_metadata` retrieves one selected document's validated cached summary/keywords/chapters explicitly, preventing quadratic workspace scans and oversized responses. A 1,000-tab/1,000-group regression asserts complete continuation, opaque IDs, group filtering, zero candidate/analysis calls during discovery, and a response below 100 KB.
