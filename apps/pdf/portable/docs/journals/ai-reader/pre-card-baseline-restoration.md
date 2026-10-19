# Restore the pre-card chat baseline — 2026-10-11

The user requested returning to the earlier successful chat behavior while
retaining answer cards, instead of continuing prompt tuning. The base system
prompt is restored to `d14d7c8af`, with only the original short `present_answer`
hint added. Default language and active reader context retain their existing
handling. No expected answer, drawing-specific instruction or new reasoning
setting is introduced.

Page text reads are text-only again: the later automatic sparse-page preview
is removed. The added `evidenceBasis` metadata field is also removed. Full-page
and crop inspection remain explicit `render_page` calls. The separately
requested `current_view` capability stays available as an optional tool, without
extra system-prompt guidance. Transport, page rendering and citation behavior
are not retuned as part of this restoration.

The [DeepSeek evaluation](deepseek-evidence-evaluation.md) and
[sparse-page evidence journal](sparse-page-evidence.md) record earlier experiments
and the behavior at that time; they are not descriptions of the restored
release behavior. The public assistant guide, release notes and preview notes
now describe explicit image requests and the restored baseline.

This is a baseline restoration, not evidence of improved model correctness or
speed. Card layout and evidence navigation have their own validation record
in [release QA](card-release-qa.md).

## Deterministic verification

An independent review confirmed that the 2,113-character base prompt matches
`d14d7c8af` byte for byte. The only added prompt sentence is the original card
hint. Page-preview source/header and metadata responses also match that commit.
Transport, reasoning preservation and citation handling were already unchanged.

Chat session, reader acceptance, analysis and chat-view tests pass. A new prompt
snapshot test fails against the preceding session source and passes after the
restoration. A sparse-page regression verifies that text reads return text and
citations without generating an image. The signed app builds successfully and
passes strict signature verification. Live model results are recorded separately.

## Fresh live check

The signed restored candidate was tested in a new isolated chat with the original
question, without answer hints or previous conversation context. DeepSeek replied
in 12.6 seconds with 1.8 mm and falsely said there was no dimensional drawing.
It read the text of pages 1–4, then rendered page 3, without inspecting the drawing
on page 1. No card was produced. There was no second paid retry after this failure.

The rollback is complete; it did not make the earlier successful answer repeat
in this fresh test. No further prompt tuning was added and publication was held
at that point. The user’s chats and source documents were not rewritten. The
[subsequent benchmark and release decision](model-benchmark-2026-10-11.md#release-decision--2026-10-11)
record the later user authorization to release with this limitation disclosed.
