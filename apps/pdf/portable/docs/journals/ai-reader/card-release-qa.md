# Answer-card release QA — 11 October 2026

**Card UI and first-click evidence gate passed in the running signed candidate.**
The separate fresh DeepSeek switch-answer evaluation failed accuracy. This report
must not be read as an overall answer-quality pass or a recommendation to conceal
that failure when deciding whether to publish.

## Candidate and isolation

The first attempt on 10 October was blocked by a locked Mac. Testing resumed on
11 October after user authorization to continue. The user explicitly requested
live computer-use verification, overriding the usual repository no-launch rule.

The final signed candidate from `/tmp/sz-card-final-build.log` was copied from
`dist/ShenzhenPDF.app` into `/tmp/sz-card-live-qa/ShenzhenPDF-QA.app` and launched
with `SPDF_STATE_DIR=/tmp/sz-card-live-qa/state`. Final QA PID: 24752. Existing user
reader processes were not quit. The older owned QA process ignored SIGTERM and
was terminated by PID before selecting the replacement; app-wide Quit was never
used. Credentials stayed in Keychain; no password prompt occurred during QA.

## Genuine model-generated card and actual interactions

A disposable two-page PDF has `Nominal gain: 42 dB` on page 2. The source explicitly
labels this a test fixture, not a production specification. The question was:

> QA release check: What is the nominal gain in this document? Show the answer in a card with evidence.

DeepSeek completed in approximately 4–5 seconds, using `read_pages`,
`document_metadata`, and `present_answer`. Its persisted card says
**42 dB**, with label **Nominal gain (test fixture, not a production spec)** and a
revision-bound page-2 citation. This was a real OpenRouter response, not an inserted
answer-card fixture.

Actual CUA checks:

- Return sent the message and the response/card appeared.
- Hiding and reopening chat preserved messages and the card. Switching to another
  saved chat and back preserved it too.
- Restarting the owned candidate and reopening the saved chat preserved the card.
- With the unrelated switch PDF selected on page 1, a **single CUA click** on
  **View evidence** selected `Answer card QA.pdf` and displayed **2 / 2**. No
  second click or citation error was needed.
- The screenshot confirms the cited page visibly contains `Nominal gain: 42 dB`.
  This full-page citation has no query, so no text highlight is expected.

Local computer-use screenshot evidence:

- `/tmp/sz-card-live-qa/card-evidence-first-click.png` — genuine card and page 2.
- `/tmp/sz-card-live-qa/card-reopened.png` — card after reopening.

Visual assessment: **9/10 for the card**. Restrained lavender, dark large value,
clear small label, and high-contrast evidence button establish the intended
hierarchy. At the tested 400-point chat width the longer label fits and the value
and button do not collide. This score covers the card UI, not model accuracy.

## Text citation and highlight

A separately labeled **QA — evidence highlight fixture** was inserted only into
the isolated chat store. It contains a page-2 citation with query `Zeta42`, which
is present in the disposable PDF. It is explicitly synthetic and tests UI routing,
not retrieval or answer generation.

Starting on the unrelated switch PDF page 1, one evidence-button click selected
the QA document, navigated to page 2, opened document search with `Zeta42`, and
showed **1 / 1**. The screenshot visibly confirms a yellow highlight on the exact
word in both source page and result context:

- `/tmp/sz-card-live-qa/card-evidence-highlight.png`

The initial fixture incorrectly hashed `/tmp` instead of the canonical
`/private/tmp` source path and was correctly rejected as an unavailable document
ID. Correcting that fixture identifier resolved it; no app code was changed for
this fixture error.

## Defect found and fixed during this QA

The visible evidence button was missing from the real accessibility tree because
its parent is an `NSTextView`. The parent agent added explicit accessibility
children and evidence-button press forwarding, plus regression coverage, then
rebuilt and signed the candidate. In the final running app the real CUA tree
exposed `answerCard` → `answerEvidence` button; the successful navigation above
used that button directly.

Coordinate clicks/drags through this computer-use environment returned
`noWindowsAvailable` before delivery. Therefore live resize/edge-click coverage
is **not claimed**. Accessibility clicks and keys, app screenshots, reopen and
navigation all worked. The native offscreen suite supplements this limitation:
`portable/build/SPDFMacAIChatViewTests` exited 0 (`AI chat view: 0 failures`), log
`/tmp/sz-card-release-view-tests.log`. It exercises corner hits, hover/pressed
states, both appearances, narrow reflow, citation forwarding and reopen. The
parent also ran the new accessibility-child/press regressions successfully.

## Fresh switch question: accuracy failure remains

A fresh chat on the user's switch datasheet asked exactly:

> What is the max actuator distance of this switch (to size a hole in a case)?

No correct answer was seeded. From send to persisted completion: **19.2 seconds**.
The model used `read_pages`, `search_documents`, and `render_page`, then answered
**1.8 mm** from the page-3 travel-to-closure table. It did not report the drawing's
**3.1 mm** full span. Its requested page-1 crop was
`x=0.05, y=0.08, width=0.6, height=0.3`, excluding the relevant 3.1 mm region.
It also misidentified a 0.4 mm dimension as useful actuator/pin width. No answer
card was produced for this response.

- Chat title: **Max Switch Actuator Travel for Hole Sizing**.
- Persisted QA chat: `/tmp/sz-card-live-qa/state/Chats/2B5C1B1B-C198-4A00-96C4-9B5A065CD4C3.json`.
- Screenshot: `/tmp/sz-card-live-qa/switch-answer.png`.

This is a substantive answer-quality failure, independent of the now-passing
card/evidence UI. No further paid retries were made after the parent requested
that this failure be recorded plainly. Publication remains the parent's decision;
the simple 42 dB card test does not establish drawing interpretation reliability.

## Cleanup

The owned QA process was stopped after recording evidence; isolated files and
screenshots remain in `/tmp/sz-card-live-qa` for audit. A disposable QA document
tab opened in the user's original reader during early setup was closed using its
specific **Close Tab** action. The user's switch document was selected again.
No user chat, source file, Collection entry, or reader process was deleted.

## Restored pre-card baseline retest — 11 October, 17:32 CST

Parent restored the exact pre-card system prompt plus the original card hint,
text-only `read_pages`, and removed the newly added metadata field. A separately
signed candidate from `/tmp/sz-ai-baseline-build.log` was launched in the isolated
QA state (owned PID 48477). This was a **fresh chat**, not a continuation of any
previous incorrect answer.

The unchanged original switch question was sent at `2026-10-11T09:32:07.396Z`.
Completion was persisted at `2026-10-11T09:32:19.971Z` (**12.6 seconds**).

Tool sequence: `read_pages(page=1,count=4)` then `render_page(page=3)`. The model
did not request an image of page 1. No card was emitted. Literal final answer:


> The only actuator-movement figure given is **travel to closure: 1.6 mm ± 0.2 mm**, so the maximum is **1.8 mm** [SW-1302 - toggle switch - datasheet · p. 3](spdf-ai://document?path=doc:f8538877d07ab4a986a54389ced19f6c9335ec3a68ffe9567a0ab890f755d244&page=3&revision=16777231:39442337:787494:1791534936:95873130:1791614963:858501215).
>
> Caveat: that is the handle's travel per position step, not the actuator's protruding length. This datasheet contains no dimensional/mounting drawing (actuator height, width or panel cutout), so a hole size cannot be derived from it — you'd need the mechanical drawing or a physical measurement.


Result: **accuracy failed**. It again confused per-step travel with the full
span and falsely claimed there was no dimensional drawing. Per the parent’s
instruction, a second fresh repeat was conditional on a correct first answer
and was not run. Screenshot: `/tmp/sz-card-live-qa/baseline-switch-answer.png`.
Saved chat: `C721CF8A-687E-4DED-B21D-F8F7BED0ECD1.json` in the isolated Chats store.

## Public README images — 11 October

Rendered the current production AppKit reader, chat/history/card components,
settings controller, and Collection wizard into PNGs using an offscreen probe.
All windows remained hidden under the probe's order guard. No user app was
launched, quit, or captured; no provider or credential request was made.
The PDF, conversation, folders, and configuration are scripted fictional data.
These images demonstrate the interface, not model answer quality.

Approved assets, inspected individually by the QA agent and release owner:

- `docs/images/portable/macos-ai-chat.png`: actual three-panel native reader,
  organized chat history, user question, and pastel “3 pages” answer card beside
  the fictional Interface specification PDF.
- `docs/images/portable/macos-ai-settings.png`: connection, searchable model and
  language controls, enabled analysis options, and usage/privacy explanation.
- `docs/images/portable/macos-setup.png`: Collection wizard with dynamic storage
  at the 80% default and Move location control.

The initial chat fixture contained an orphan tool result. The production store
correctly refused to load that malformed transcript. The fixture was corrected
to contain the matching assistant tool call and tool-call identifier, with an
explicit successful reload assertion. The evidence callback was installed
before constructing the card, which captures its callback at initialization.
The final probe passed the saved-chat reload, visible card, and exact evidence
URL forwarding assertions: **exit 0, zero failures**. This offscreen check tests
button forwarding; it does not replace the earlier real computer-use navigation
and highlighted-passage checks above.

Targeted checks against current sources also passed by process exit code:
`SPDFMacAIChatViewTests` (**0 failures**, card accessibility/clicks, appearance,
reopening and layout) and `mac-unified-settings-tests` (**0 failures**).
Logs: `/tmp/sz-readme-ai-probe-run.log`, `/tmp/sz-readme-chat-tests.log`, and
`/tmp/sz-readme-settings-tests.log`. The temporary probe is
`/tmp/sz-readme-ai-probe.mm`; it links the production workspace objects and uses
`SPDFMacReadmeFixtures.h`. An optional Properties capture was not selected for
the README because its synthetic missing-source state distracted from the
metadata demonstration. No production code was changed for these images.
