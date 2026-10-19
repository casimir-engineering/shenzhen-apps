# Response recovery and exact chat search — 2026-10-10

## Reported conversation

Inspected **what is the max actuator distance of this switch (to size a hole in
a case)?**. The stored history ends after seven render_page calls (three whole
pages, four crops) without an assistant answer. The raw failed provider response
was not retained, so the exact response shape for that request cannot be proven.

The transport collapsed null-content reasoning responses, provider errors inside
HTTP 200, and unsupported content-block shapes into one “unreadable response”
message. It also ignored finish_reason, allowing truncated actions to reach the
session and empty-string replies to appear successful. OpenRouter documents
that reasoning shares max_tokens with visible output; the previous 4096 budget
could be exhausted before an answer:
https://openrouter.ai/docs/guides/best-practices/reasoning-tokens

## Changes

- Normal allowance is 8192 tokens. A length-truncated response is rejected and
  retried once at 16384 with exactly the same model, input, tools and privacy
  policy. No tool from the truncated reply is executed. Stop cancels either
  request; no third attempt or silent model switch occurs.
- Text content blocks are normalized. Empty answers, refusals, provider failures
  and malformed envelopes have separate messages. Private reasoning/provider
  text is not exposed. The session cannot save a blank successful reply.
- The general prompt uses the user's stated purpose to choose the measurement:
  clearance asks for the moving part's swept envelope, not merely travel. No
  document-specific dimension is embedded in the prompt.
- Chat find reveals the exact rendered glyph and highlights every occurrence,
  with stronger highlighting on the current one. Return/Shift-Return move among
  matches. Navigation waits for text layout and prevents queued follow-bottom
  scrolling from hiding the match. Clearing/changing query cancels stale jumps.
  Opening a content match from history also reveals its passage; title-only
  matches open the full chat. Work is local to an explicitly searched chat,
  with no AI request or disk write.

## Verification

Offline transport tests cover reasoning-only truncation, repeat exhaustion,
partial tool batches, text blocks, provider errors, refusal, empty response and
Stop during recovery. The updated tests fail against the previous transport
(13 assertions); the fixed transport and session tests pass.

Native offscreen chat tests verify actual glyph rectangles within the viewport,
including two matches thousands of characters into a message, next/previous
navigation, existing old-message search, and highlighting. Reader acceptance,
launch-work policy and updater tests pass. No running user app was launched,
quit or captured. Live provider behavior remains unverified: the standalone
probe cannot access the saved Keychain credential noninteractively.

## Shorter default answers

The user confirmed that the latest answer was acceptable but too long. Replaced
765 words of general chat instructions with 193 words (including the language
suffix). The default is now 1–3 short sentences containing the answer, citation,
and essential qualifications. Detailed reasoning, derivations, tables and extra
suggestions require an explicit request. Retrieval stops once evidence suffices.
The prompt still preserves source honesty, language overrides, reversible tool
actions, plain chapter titles and untrusted-document boundaries. No answer value
or document-specific example is embedded. Chat session/request tests pass,
including a prompt-size ceiling and checks that the brevity rule reaches the
provider request. This checks wiring, not a guarantee of live model compliance.

## Restore evidence checks without long replies

The next saved conversation exposed two different failures. The model read all
four pages as text but rendered only the specification tables on pages 3 and 4;
it nevertheless claimed no dimensional drawing existed. Its answer also appended
an unretrieved Chinese search phrase to an otherwise valid page-3 citation, which
the evidence gate correctly rejected.

The revised prompt is 344 words versus the earlier 765-word version. It again
distinguishes individual steps, total travel, component size and
clearance envelopes; requires inspecting the relevant drawing and its arrows and
general notes; and forbids absence claims about uninspected pages. It retains the
1–3 sentence response default, avoids repeat crops of readable evidence, and
requires verbatim tool citations. Metadata lookup is optional when the relevant
page is already known. No document-specific numbers or answers are encoded.

Citation handling now deterministically removes an invented highlight query only
if the exact page, document, revision and layout already have a retrieved page
citation. New answers are repaired before persistence; clicking the same defect
in existing chats uses that safe page fallback. Exact retrieved text highlights
are preserved. Unknown pages, revisions and document identities remain blocked.
There is no additional model request, launch work or document-open work.

Validation: chat tests pass; the pre-change session fails four new assertions.
Reader acceptance tests pass, including real PDF citation navigation and search
highlights. A read-only native replay of the reported saved chat recovers its one
broken link. Existing constructor checks prove no network, disk or reader-context
work at session creation. Live model accuracy and latency have not been measured;
these tests verify prompt delivery and deterministic citation behavior, not model
compliance. The user's running app was not launched, stopped or captured.

## Generalize the evidence policy

Removed the engineering-specific instructions after user feedback: there is no
longer a rule privileging drawings over tables, or mentioning travel, dimension
arrows or clearances. The general policy chooses text or rendered pages according
to the evidence, checks definitions/scope/conditions, separates facts from
inferences, resolves apparent conflicts in context, and does not infer absence
from incomplete inspection. Brevity and bounded retrieval remain. Exact citation
rules and deterministic link recovery are unchanged. Request tests check the
general policy and reject the previous engineering-specific wording; session
construction remains inert. No new runtime behavior or model call was added.

## Empty bubbles in a reopened chat

Read-only inspection of the reported “Latest” transcript found the final answer
intact. Four intermediate assistant/tool-call records contained only two line
breaks. The transcript treated any nonzero string length as visible content,
created an Assistant heading, then trimmed the Markdown to an empty bubble.
This looked like erased answers and wasted the visible-message budget.

The view now excludes whitespace-only records from visible rows and pagination,
and creates a role heading only after Markdown produces visible content. Existing
saved chats need no migration or edits. New tool rounds canonicalize whitespace
content to an empty string while retaining all tool calls, results and reasoning.
Meaningful answer text is preserved verbatim.

Session and production reader tests pass. A new fixture checks 45 empty tool
records do not hide real messages or create an older-messages control, and covers
reopen/search/clear. The previous session fails the normalization assertion; the previous view fails
the empty-row, reopen and display-budget checks (121 failed assertions).
An optional read-only replay of the reported transcript verified its final answer
and previews inside the real dock layout; its native offscreen render was
inspected. No app launch, screenshot or conversation rewrite was performed.
