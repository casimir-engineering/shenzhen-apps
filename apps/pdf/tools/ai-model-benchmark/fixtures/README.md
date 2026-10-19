# Frozen document-answer cases — 2026-10-11

These four small PDFs are synthetic controls, not private user documents. The
fifth case is the user's four-page SW-1302 switch datasheet; it is deliberately
not copied into the repository. Its SHA-256 is recorded in `rubric.json`.

The five questions and source requirements are in that rubric. **Never send the
rubric, expected values, or scoring instructions to a model.** Build the runner's
case manifest using only the question, document paths, model and repetition.
The cross-document case needs both `service-policy.pdf` and
`extended-advisory-plan.pdf`; the others use one document. Use absolute paths.

The original switch runs also exposed the same pre-existing cached summary to
each model through `document_metadata`. That summary mislabels the first-page
drawing as a cover/approval page. It remains a navigation hint, not ground truth.
Reproducing without that private cached metadata is a different condition and
must be reported as such. Its content was not inserted into the system prompt.

The controls cover a booking condition, a chart whose bar heights are visual,
a comparison across two policies, and an explicitly absent renewal price. They
are intentionally small. This suite does not measure long-document retrieval,
multilingual performance, app mutations or GUI interaction.
