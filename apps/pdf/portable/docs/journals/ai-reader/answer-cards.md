# Brief answer cards

## Design

Intent: let a reader take one result from a document and immediately inspect its
source. Domain: result, unit, range, citation, passage, conversation. Color world:
paper white, reader charcoal, annotation mint, tab lavender, selection blue. The
signature is a large answer paired with a verified source action inside the chat.
Reject dashboard metrics, celebratory decoration and extra toolbar controls.

Hierarchy: 12-point medium label, 36-point semibold short answer (34 points for
15–24 characters, 28 for longer values). Lavender surfaces use #D8CDE9 in dark
mode and #EEE8F7 in light, with #2E253F answer ink and #655574 supporting text.
18-point side insets and 16-point top/bottom insets form a compact answer slip.
The 31-point evidence capsule uses #3B304D, pale text and a vector right arrow.
It shares the answer row when the measured value and button fit, otherwise moves
below right. Height follows content rather than a fixed minimum. Short cards are
97 points high, down from 138. Full-bounds clicks, hover, pressed and keyboard
focus states use the reader's established button tracking. Text stays selectable
and searchable; long values wrap without clipping or semantic abbreviation.

A web UX design agent reviewed the initial and revised native renders. Its ranked
critique replaced wasted vertical space and the disabled-looking outline button
with a tighter horizontal arrangement and a contrasting source action. The review
rated the final design 9.2/10 for visual design and usability (subjective design
ratings) after its narrow-panel typography adjustment was applied. Light, dark, hover, pressed and narrow native captures were inspected.

## Implementation

The session exposes `present_answer` only in document chat. It validates bounded
plain-text label/value and an exact tool-issued citation. It records the tool
result plus an ordinary assistant message carrying local card metadata, then
completes immediately. No continuation request or duplicate prose is needed.
Optional automatic chat-title generation follows its existing policy. History
stores/searches the plain-text answer; provider replay strips local presentation
metadata. Invalid cards return a tool error so the model can correct or use prose.
The view only renders validated cards and routes evidence through existing source
revision/layout checks. There are no document mutations or new startup jobs.

## Verification

Chat/session tests cover tool discovery, inert construction, evidence validation,
completion without another answer round, persistence, history search and clean
provider replay. The previous session fails six new checks. Production-linked
reader acceptance tests pass. Offscreen native chat probes cover light/dark,
minimum widths, long labels/values, all button corners, exact citation callbacks,
search highlights and reopening the chat. Native PNGs were visually inspected;
there are no overlaps or clipped values. User app was not launched or captured.
Live model selection of the new tool remains unverified; the transport/session
path is exercised with a deterministic fake model.
