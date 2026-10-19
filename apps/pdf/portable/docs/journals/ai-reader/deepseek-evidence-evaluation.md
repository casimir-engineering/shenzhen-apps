# DeepSeek evidence replay — 2026-10-10

Historical evaluation record. The subsequent [pre-card baseline restoration](pre-card-baseline-restoration.md)
removed the added metadata field, automatic sparse-page previews and extra prompt
guidance; the retained-changes section below describes the earlier evaluated state.

## Retained changes

Keep the user's `deepseek/deepseek-v4.1-flash` choice. The base prompt retains
the earlier general evidence approach: answer the actual question and purpose,
check definitions/scope/conditions, distinguish source facts from derivations,
reuse readable evidence, and default to 1–3 short cited sentences. It explicitly
names text reads, passage search, full-page/region rendering, and the new
on-demand current viewport tool. The card hint explains label, value, exact
evidence citation and immediate completion without another answer round.

Cached document metadata now identifies generated summaries/chapters as
navigation hints, not verified source evidence. Text analysis coverage must not
be mistaken for inspection of visual content. In the reported conversation,
the cached analysis misidentified the first-page drawing as a cover/approval
page. Page pixels did reach the model; its interpretation was still unreliable.

## Live evaluation and limits

Used an isolated, production-linked native session/transport/tool probe, the
reported source, its actual cached metadata, and the original question plus a
paraphrase. Credentials were read through a non-echoing terminal prompt and were
not written to scripts, logs or the repository. The user's session and saved
chats were not edited. OpenRouter privacy routing stayed enabled.

The original general prompt produced a correct full-span interpretation in one
50.7-second replay, but not consistently. Replaying the exact pre-card general
prompt later produced one useful full-span answer in 39.4 seconds and two wrong
interpretations in 9.7 and 8.6 seconds. Those are observations, not evidence of a
speed improvement. Faster variants often substituted a related per-step value.

Rejected experiments included expanded purpose/scope instructions, progressive
single-page reads, larger automatic previews, overlapping image details,
explicit higher reasoning effort and a visual-first tool hint. None reliably
solved interpretation. Increased reasoning could take minutes. No such image,
reasoning, model-switch or domain-specific prompt change is shipped.

Three independent checks covered a chart comparison, visiting hours with a
booking condition, and an absent renewal price. They generally returned the
correct facts in 2–9 seconds and exercised both cards and prose, but passing
them does not establish reliable interpretation of the reported drawing.
No part number, expected answer, component terminology or case-specific rule is
embedded in the production prompt. No automatic repeated provider retries were
added to chase a desired answer.

**Unresolved:** DeepSeek can still give an incorrect interpretation despite
receiving the right page image. Restoring the earlier prompt is not a guarantee
of the previously observed good answer. No accuracy score or measured speedup
is claimed. The working viewport feature and deterministic evidence/citation
tests must not be reported as a model-quality fix.

Native chat, transport, reader acceptance, Markdown viewport and cancellation
checks pass. The viewport regression fails against the preceding tool dispatch.
No application launch, quit or screenshot was used for verification.
