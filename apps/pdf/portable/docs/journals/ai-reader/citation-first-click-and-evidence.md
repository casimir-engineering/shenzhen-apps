# Citation destinations and first-image evidence — 2026-10-10

## Diagnosed behavior

Reviewed the saved conversation **Switch Actuator Max Travel Distance**. Its
first full-page drawing (1130 × 1598) already contains the readable 3.1 dimension
and the solid/dashed extreme actuator positions. The assistant instead answered
with the table's 1.6 ± 0.2 per-step specification, asserted that the drawing
contained only mounting/general dimensions, and required a correction followed
by four overlapping detail captures to identify the full displacement.

This was interpretation failure, not a missing image in that conversation. Its
final answer also overlooked the title block's general tolerance note while
claiming there was no tolerance. The general prompt now prioritizes the actual
requested quantity, explicit dimension endpoints, readable first-image evidence,
and local/general notes. It prohibits using repeated readable crops as a
substitute for interpretation and distinguishes observations from deductions.
No part number, document name or expected numeric answer is in the prompt.
The complete runtime base prompt is in `mac/SPDFMacAIChatSession.mm`; response
language and untrusted active-reader metadata are appended per conversation.

## Navigation fix

`aiNavigateDocument` previously seeded the requested page but left the target
tab's saved scroll origin intact. Document opening captured that old origin for
its deferred layout stabilization. It could restore the old viewport *after*
the immediate page navigation, explaining why clicking the citation a second
time worked. The regression fixture mirrors this capture-and-defer sequence.

An explicit citation now clears that saved origin and stale Markdown anchor
before selecting its tab. Page-only citations also wait for asynchronous
navigation readiness with the same cancellation, revision, selected-tab and
human-state guards as highlighted citations. Empty loading viewports no longer
write over the requested destination. No launch hook, indexing or background
work was added; readiness polling runs only for a pending explicit citation.

## Verification

- New first-click regression failed against the previous production code.
- Fixed production reader passes immediate/deferred saved-origin tests, real
  PDF citation highlights, source validation, cancellation and Undo tests.
- AI reader acceptance, chat/session/view tests, launch-work policy tests and
  updater tests passed. File-size ratchet and whitespace checks passed.
- Prompt transport checks verify the general evidence rules are actually sent
  and do not embed the example document or expected answer.
- Verification is headless; the user's running app was not restarted or captured.
- A fresh live first-image replay was attempted using the original question.
  macOS denied the standalone probe noninteractive Keychain access (-25293),
  so no provider request ran. Prompt wiring is tested; a live model success
  is not claimed, and prompt changes cannot guarantee infallible interpretation.
- Rebuilt `dist/ShenzhenPDF.app` with Developer ID signing; strict deep
  signature verification passed. The running app was left untouched.
