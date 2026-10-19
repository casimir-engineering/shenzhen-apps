# Technical critic — loop 1

Reviewed 2026-10-09 while implementation was still being integrated. This is a review of the working tree, not a release certification. **Score: 5/10. Not ready.** The boundaries are promising (lazy objects, bounded requests, strict top-level argument validation, ephemeral transport, redirect rejection, private files, deterministic previews), but primary citation routing, provider-input validation, cache identity and deletion semantics need fixes. A score of 9 would require executable integration evidence, not only resolving these source findings.

No app launch, quit or screenshot was performed. Read `agents.md`, agent handoff, architecture and onboarding plans. Source modules were not edited by this critic.

## Executable evidence

- `make -C portable mac-ai-transport-tests mac-ai-chat-tests`: exit 0, both pass. Log: `/tmp/spdf-ai-critic-tests.log`.
- Compiled a Foundation-only probe from the existing fake transport/session fixture, then returned `{"content":"","tool_calls":["bad"]}`. The session raised `-[__NSCFConstantString objectForKeyedSubscript:]: unrecognized selector`. Probe catches the exception to avoid a process crash; a production callback does not. Source/binary: `/tmp/spdf-ai-malformed-probe.mm`, `/tmp/spdf-ai-malformed-probe`.
- The existing passing suites do not cover real citation dispatch, actual comment permission reentrancy, multi-process cache/deletion, page-layout changes or native chat history Stop behavior.

## Ranked concrete findings

### P1 — Provider JSON can crash the application; malformed arguments can execute an action

`SPDFMacAIChatSession.mm`, `nextRequest:` / `executeCalls:` / `cancel`.

Only the outer `tool_calls` array is validated. Array members and nested `function` are immediately treated as dictionaries. A string member reproduces an exception; `NSNull` function values have the same problem. The message is persisted before full validation, so malformed history can survive reopening. Separately, malformed arguments or a valid JSON non-object become `{}`: a malformed `undo_action` request therefore dispatches an actual Undo.

Validate and normalize the entire reply, every call, unique nonempty ID, allowed fields and argument JSON before persistence or dispatch. Reject malformed arguments, never substitute an executable default. Apply equivalent validation to stored history. A rejected call must not leave an orphan tool-call message that poisons the next API request. Add malformed array/function/argument and resumability tests.

### P1 — Every generated page citation currently fails to navigate

`SPDFMacAIIntegration.mm`, `aiOpenCitation:`; `SPDFMacAITools.mm`, `validatedArguments:forTool:`.

`NSURLQueryItem.value` supplies the page as an NSString, but `show_document` requires an NSNumber integer. A normal tool citation (`spdf-ai://document?path=...&page=1`) is rejected; the completion silently drops the error. Preview links fail the same way. In addition, text citation URLs contain no revision, and the show_document schema has no revision field, so adding a revision as done for previews also fails unknown-field validation. No citation registry verifies that a model-written URL came from retrieved evidence.

Introduce a dedicated typed citation route, validate document/revision/layout/page identity, reject duplicates/unknown query fields, and surface failures. Test clicking an actual link from a read result and a persisted preview, including changed source and changed Markdown pagination.

### P1 — Analysis cache identity is incomplete and duplicate network calls cross process boundaries

`SPDFMacAIAnalysisService.mm`, `startNext`; `SPDFMacAIAnalysisCache.mm`.

The disk filename is only the source-byte SHA-256. The service compares a default portrait/landscape string but does not compare the selected model or include Markdown image dependency identity, actual layout/text-size configuration, or a prompt version. A changed image can change pagination while Markdown bytes and cached chapter pages remain unchanged. Switching model also reuses the prior model's output. Deduplication checks only one service's active/pending path; this app uses a process per window, so two windows can both miss the cache and issue paid requests.

Use the complete planned cache key and a cross-process per-key transaction/in-flight lease. Revalidate revision/layout before installation. Tests should change an image dependency without editing Markdown, change model/layout, and start two independent processes on one key.

### P1 — Delete all chats does not remove all transcript imagery, and another window can resurrect deleted history

`SPDFMacAIChatStore.mm`, `savePreview:chatID:`, `deleteChatWithID:`, `deleteAll:`.

A generated image is copied from an owned `ShenzhenPDF-AI-*` temporary directory into Chats; its original is never removed on successful copy. Deleting the chat removes only the copied assets. `deleteAll` enumerates only successfully parsed chat JSON, leaving orphan assets or malformed chat files. There is also no shared store lock/tombstone: window B can have a chat loaded or running, window A deletes it, and B's next persist recreates it. Deletion therefore does not satisfy the stated private-transcript cleanup/persistence contract.

Transfer ownership and clean temporary previews on all terminal paths. Make deletion a locked transaction that invalidates stale writers, and clean all owned chat/attachment entries, including orphans. Test two store/session instances across deletion and assert both temporary and saved attachment paths are absent.

### P1 — Stop becomes unavailable while active work continues in history

`SPDFMacAIChatView.mm`, `displayChats:`; `SPDFMacAIIntegration.mm`, history actions.

Opening Chats while a session runs leaves it running but disables Stop. `session.changed` intentionally does not update history, so pending mutations can proceed without a visible cancellation control. Loading another chat cancels, but is not a discoverable substitute for Stop. Keep Stop connected to the running session in history, or cancel before switching surfaces. Test this using a held transport reply and held tool completion.

### P2 — Empty Command-K Return resumes the previous chat instead of creating a fresh chat

`ShenzhenPDFMac.mm`, `activatePaletteSelection:`; `SPDFMacAIIntegration.mm`, `showAIChatForQuery:`.

The empty-search path calls `showAIChat`, and neither method calls `newChat`. After sending one conversation, close the palette, press Command-K then Return: the prior session is reused. Split fresh-chat entry from resume/history entry and test the chat ID changes only on the fresh entry.

### P2 — Model selection is not checked against the live catalog

`SPDFMacAITransport.mm`, default constant and `ValidModel`; `SPDFMacAISettings.mm` and settings integration.

The default ID is hardcoded and settings validate only length/whitespace. No model-catalog request or availability validation exists. The plan explicitly requires validating provider identifiers and clearly displaying any alternative. The generic request failure does not establish whether the requested model exists. Implement a lazy catalog check on connection/model selection, preserve the user's requested preference and display a concrete unavailable-model error without silent substitution. Do not put it on launch.

### P2 — Undo can overwrite a later human page navigation

`SPDFMacAIToolsReader.mm`, `aiWorkspaceFingerprint`, `aiCaptureWorkspace`, `aiRestoreWorkspace`; `SPDFMacAgentGroups.mm`, `agentGroupSnapshot`.

The fingerprint includes selected tab and group state but omits its page. Navigation/group actions capture a previous page and restore it on Undo. After an assistant action, the user changes page in the same document; the fingerprint still matches, and Undo changes that independent human page edit. Include the relevant reader state in the guarded fingerprint, or separate group-only inverse state from navigation inverse state. Verify group Undo preserves unrelated page navigation and navigation Undo refuses an intervening page change.

### P2 — Filesystem paths are sent as the workspace's document identifiers

`SPDFMacAIToolsReader.mm`, `aiWorkspaceContext`; `SPDFMacAITools.mm`, tool schemas/results and citations.

The implementation reuses agent group snapshots containing every open document's full absolute path and group last-used paths, then sends them to the model. This violates the architecture's opaque-ID mapping requirement and uploads username/directory information unnecessary for retrieval. Keep the existing group command API internal; translate provider-facing document IDs to validated local paths at the adapter boundary. Assert request JSON has no local paths.

## Findings already being addressed during review

- Initial comment implementation did not recheck cancellation after `ensureActivePDFCanBeModifiedForOperation:` returned from a nested permission/protection panel. The parent has since threaded NSProgress and inserted cancellation checks before mutation. This needs a reentrant headless regression test before being counted closed.
- Initial Disconnect/disable path did not cancel running chat work retaining its key. A `cancelAIChat` call now appears in settings application. Verify analysis and other processes also observe opt-out and that pending cloud requests cannot start afterward.
- Live Markdown context extraction and automatic-analysis/sidebar installation were actively being added by the parent. Missing wiring from the initial snapshot is not separately scored as an architectural defect. Newly added source needs integration coverage and a final review, particularly stale result installation and actual live-page identity.

## Remaining acceptance evidence

The current score does not certify launch/open performance. There is no complete acceptance evidence yet for disabled-feature laziness through production entry points, cross-process behavior, actual tools/group/comment Undo, exact live Markdown page citations, all relevant Collection/search/group/launch/render suites, or complete native event routing. `SPDFMacAIAnalysisServiceTests` exists but was not wired into the focused Make targets observed at the start of this review. No live provider/key was used. Automatic analysis is bounded to first excerpts; retain explicit partial coverage and never imply whole-document evidence.
