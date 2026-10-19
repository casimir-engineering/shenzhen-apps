# Sparse page evidence — 2026-10-10

The reported chat B4CA82D6-E885-4D25-87D4-06785748C735 read pages 1–3,
then page 4, and searched for “actuator”. It never called `render_page`.
Page 1's extracted text contained names and title-block content; the dimensional
artwork was not in the text layer. The assistant treated reading every page's
text as inspecting every page and falsely claimed that no drawing existed.
This was evidence selection, not lost image delivery or a card rendering defect.

`read_pages` now labels fixed-layout text as incomplete visual coverage. For a
requested page containing fewer than 200 non-whitespace UTF-16 units, it includes
one full-page image using the existing 1600-pixel renderer, cancellation and
private asset handling. Other sparse page numbers are reported explicitly.
This threshold is a retrieval heuristic, not proof that a page is blank or that
dense pages contain no visuals. The model can still request any page or crop.
No switch-specific facts or additional system-prompt rules were added.

The preview travels with the existing tool result through saved chat assets and
multimodal request serialization, with its exact opaque source/page/revision
citation. It requires no extra model round. A changed source or failed render
gets an explicit image error, preserving the extracted text. Cards remain
optional, evidence-linked outputs; this change does not force a potentially
unsupported number into a card.

Verification: production-linked headless acceptance tests exercise real PDF
reads, sparse multi-page budgets, pixel payload delivery in the HTTP request,
citations, missing files, cancellation, short Markdown and dense text. The
previous tool dispatch fails the new sparse-read assertion. Replaying the user's
actual source read verifies that page 1's pixels accompany the first read
(58 ms locally for text extraction plus image rendering). The exported preview
was visually checked: the 3.1 dimension is legible.
Constructor tests prove no reads or queue creation at initialization; dense
read tests use a nonexistent file to verify rendering is not attempted.
No app launch, quit, or screen capture. No live model quality score is claimed:
these tests verify evidence delivery, not a guaranteed model answer.
