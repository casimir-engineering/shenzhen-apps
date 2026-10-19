# Chat reliability, native windows and source highlighting

10 October 2026. This change addresses a stopped first reply, missing user text,
window behavior, and clickable source passages.

## Root cause and correction

The explicit **Authorize & send…** path passed the native composer's mutable
backing string into the session, then cleared the composer. The in-memory user
message became empty after its original text had already been saved and sent to
the model. Saving the assistant's first reply then failed the store's append-only
prefix check, producing the misleading “changed in another window” error before
the tool could run.

The regression reproduces that exact `NSTextView` insertion, direct string
submission and clear sequence. The session now copies incoming text and freezes
response/tool boundaries; the store compares the same immutable serialized
snapshot that it writes. Real concurrent edits still fail safely. Tests cover
user → assistant tool call → tool result → final assistant answer, disk reopening,
and the original native authorization path.

## Window and conversation behavior

Chat has a separate native resizable window. Search retains its own palette.
Close, Escape and File → Close preserve the current draft and chat. Minimize and
Zoom target the active window. Two exclusive pin toggles select ordinary,
above-Shenzhen-PDF, or above-all-apps ordering. Position, size and mode are saved
in YAML, accessed only when chat is explicitly opened.

Thinking, the current tool, errors and readiness for a reply have prominent
status text. The latest question remains visible above the newest-first
transcript, which includes both user and assistant messages. A compacting pass
removed excess terminal paragraph space from rendered messages.

![Native chat with source link and pin selected](images/chat-window-pin-dark.png)

Independent UI review: **9.0/10 appearance, 9.1/10 usability**, with no major or
medium findings in the reviewed scope. See [the review](ux-critic-chat-window.md)
and [native-window validation](chat-window-validation.md).

## Clickable evidence

Document-search results provide source URLs containing an opaque document ID,
page, revision, optional text-layout identity, and the literal matched query.
The assistant is instructed to use those exact links with a document/page label,
and to search a short exact passage after reading it when it needs a precise
highlightable citation. Page-only links remain useful for visual evidence.

A click must match evidence actually retrieved in that conversation. It cannot
substitute a different passage, arbitrary local path, stale revision or changed
text layout. Accepted text links open the source tab, navigate to the page and
use normal document-search highlights. Chat stays open. Navigation and search
state participate in the assistant's Undo receipt.

Source highlighting is initiated only by explicit citation/navigation actions;
there is no new document-open or launch analysis. Ordinary searches do not
allocate a citation guard. The production-linked workspace test also retains
its 1,000-tab assertion: listing the first page performs zero document-candidate
passes and zero analysis lookups.

## Verification boundary

Verification uses native offscreen window/view probes and production-linked
reader tests, without launching, quitting or capturing the user's app. Window
ordering is checked through AppKit state and activation notifications; live
multi-application switching is not claimed. PDF citation tests run actual MuPDF
search and inspect its resulting highlight rectangles, including a different
source tab.

A separately signed synthetic live-provider probe attempted a noninteractive
saved-credential read. macOS returned `errSecAuthFailed` (`-25293`); no provider
request, credential prompt or credit spending occurred. Provider round trips
were therefore verified using controlled transport responses, not represented
as a successful live OpenRouter conversation.

## Citation publication review

The initial implementation had two asynchronous race boundaries: waiting for a
source tab to load, then waiting for PDF/Markdown text extraction. Both now check
the citation token, cancellation, selected tab, exact workspace/search state and
captured source revision before publishing. Stop invalidates every pending
citation token even when a later tool has replaced the current progress object.
Undo changes the navigation token and restores prior searches. The desired page
and query are installed before the action receipt is fingerprinted, so successful
highlight completion does not invalidate its own Undo.

Markdown keeps a pending guarded query out of automatic reload/reflow searches
until publication succeeds, and rejects a changed rendered-document snapshot.
Ordinary searches pass a nil publication predicate. PDF find execution was
extracted into a focused file and the coordinator's size cap was lowered.

Final headless evidence:

- Production-linked Context tests pass, including real MuPDF rectangles, exact
  citation provenance, different-tab navigation, source revision rejection,
  and deferred loading/Undo.
- Suspended PDF extraction covers successful publication, manual page/search
  changes, multiline changes, Stop, Stop after a later tool, Undo and source
  replacement. Discarded completion clears the search busy state.
- The real Markdown SessionFind suite passes existing regex, nearest-match,
  silent search and reflow behavior, plus suspended extraction cancelled by
  Stop or manual navigation. A temporary guard-disabled build fails its late
  publication assertion; the guarded production build passes.
- Citation URLs round-trip spaces, ampersands and Unicode. Search/navigation
  queries above 512 characters fail explicitly rather than losing highlights.
- File-size and whitespace checks pass. There was no user-app interaction or
  further provider/credential attempt during this review.

## Local delivery

The final `make -C portable -j4 mac-app` run used the established Developer ID
identity and completed successfully after the final Markdown guard correction.
`dist/ShenzhenPDF.app` passes deep, strict code-signature verification, including
its Collection helper. The updater regression suite passes all 32 cases. Chat,
transport/credential and unified-settings regression targets also exit zero.

The running user app was left alone. This is an updated local build; no public
release or notarization submission was performed for this change.

Independent final source review (revision_analysis): **9.2/10 technical**, with no
major or medium blockers found in the reviewed changes. The guarded citation and
native menu routing implementation is committed as `0c685c13d`; immutable chat
submission/persistence is committed as `94c2a8f36`. This grade covers the source
and headless evidence above, not a live provider round trip or interactive app
verification.
