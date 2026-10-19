# Document assistant model benchmark — 2026-10-11

**No clear upgrade over DeepSeek in this sample.** Six models were tested on the same
five tests twice, with independent grading after model names, timings and prices
were removed. DeepSeek, Haiku, Luna and GLM passed 8/10; MiMo passed 6/10 and
Gemini Flash Lite passed 0/10 under supported-answer grading. Applying the literal
whole-page retrieval requirement lowers Haiku and Luna to 6/10; see the
[grading interpretation](#disclosed-grading-interpretation).
**Every model failed the original switch question both times.** The default and
production prompt remain unchanged. At the end of this evaluation, publication
was held; the later release authorization is recorded below and does not change
these findings.

Recorded provider cost was **$0.08927**, excluding unreported charges from two
malformed provider responses. This is recorded usage, not a reconciled account
invoice. See the results below and the [per-run data](model-benchmark-2026-10-11-results.json).

## Why compare models

The [earlier DeepSeek evaluation](deepseek-evidence-evaluation.md) produced both
correct and incorrect interpretations of the same drawing. One useful answer
took 50.7 seconds; another replay of the pre-card prompt took 39.4 seconds, while
two faster replies were wrong. Broader checks on a chart, visiting hours and an
absent price generally answered correctly, so the failure was not universal.
Expanded prompts, larger previews and higher reasoning effort did not establish
a reliable improvement and sometimes made responses substantially slower.

The user then requested the [pre-card baseline restoration](pre-card-baseline-restoration.md):
the earlier general system prompt, with only the original brief answer-card hint.
A fresh isolated live check still gave the wrong quantity in 12.6 seconds. It
read all four pages' text but rendered the specification page rather than the
relevant drawing. That rollback result is a single observation, not a measured
accuracy rate. The following comparison tests that restored behavior across
several affordable model families without tuning it to a desired answer.

## Frozen protocol

- **Five questions, two repetitions, six models:** 60 fresh chats, ten
  per model. Every model receives the same question, source bytes, available
  documents, saved metadata and production prompt for that case.
- **Five distinct tasks:** interpret the reported switch drawing for an enclosure
  question; find visiting hours with a prerequisite; compare a visual chart;
  compare the duration and coverage of two separate service documents; identify
  a price that the supplied policy does not state.
- The switch case includes its existing cached analysis, including the misleading
  first-page description. It is not corrected for a favored model. The other
  cases use controlled fixtures. Source hashes and expected facts are frozen
  before paid runs in a separate grading file.
- Expected answers, scoring criteria, benchmark labels and results are never
  included in model messages or tool responses. No question-specific hints or
  retries are added after observing an answer.
- Each request uses the restored production base prompt from `d14d7c8af`, the
  original short `present_answer` hint, English default language, active-reader
  context and production tool definitions. Reasoning settings remain each
  model's normal defaults; the benchmark does not force a common effort level.
- Two workers run separate manifests. Model order rotates by case and reverses
  in the second repetition. Warm OS file caches and normal provider caching are
  allowed, as in production. This is not a cold-cache latency experiment.

## What the harness exercises

The native headless harness links the production chat session, tool adapters,
MuPDF extraction/rendering, image-delivery pipeline, card validation, citation
validation and chat persistence. Text reads remain text-only; the model must
request `render_page` when it needs pixels. Full-page/crop previews use the same
production image budget and model-message construction. `present_answer` remains
the production session's final-answer tool.

Fixtures replace only the reader workspace: they expose the selected source,
its page and the case's open documents. Cross-document discovery uses the actual
`aiWorkspaceContextWithArguments:` dispatch and consistent resolved file paths.
Chats and preview assets are stored in isolated temporary state. The user's
open windows, saved conversations and source files are not modified.

The benchmark is read-only. Its tool adapter supports `list_workspace`,
`document_metadata`, `reader_state`, `read_pages`, `render_page` and
`search_documents`. Other app tools retain their production definitions but
return an unavailable error, including Collection lookup. The scratch runner's
generic error incorrectly called every unsupported tool a mutation; the reusable
runner now uses an accurate message. Some cross-document attempts tried Collection
lookup before recovering through workspace discovery. This is a limited isolated
workspace, not complete app-feature parity. There is no live document
viewport, so `current_view` reports that limitation and directs the model to
`render_page`. Automatic chat-title generation is disabled to measure the answer
rather than an unrelated follow-up request. These differences are uniform across
models and must remain visible in the result report.

This is an answer-quality and tool-use comparison, **not a computer-use or UI
validation**. Card appearance and clicking **View evidence** are validated
separately in [card release QA](card-release-qa.md).

## Pricing and privacy screening

Public snapshot: **2026-10-11, 10:15 UTC**. The OpenRouter catalog lists DeepSeek
V4.1 Flash at $0.30 input / $1.20 output per million tokens. Its first-party
weekend/off-peak endpoint publishes $0.15 / $0.60, with UTC time overrides.
To avoid using the higher rate as a permissive comparison, every benchmark
request uses the stricter +20% ceiling of **$0.18 / $0.72 per million tokens**.
First-party DeepSeek is not itself in the snapshot's ZDR list; other eligible
DeepSeek routes can cost less. Actual charged cost is therefore measured too.

| Model | Example ZDR endpoint at snapshot | Input / output, USD per million | Relevant qualification |
|---|---|---|---|
| DeepSeek V4.1 Flash | `deepinfra/fp8` | 0.14 / 0.42 | Baseline; other routes have different prices and discounts. |
| Claude Haiku 5.5 | `google-vertex/global`, `amazon-bedrock` | 0.10 / 0.50 | At 100,000 input tokens, its higher tier exceeds the ceiling. |
| GLM 5.3 Flash | `baseten/fp8`, `fireworks` | 0.15 / 0.50 | Multiple ZDR providers and quantizations are available. |
| MiMo V2.6 Flash | `makora/fp8` | 0.13 / 0.28 | DeepInfra is also eligible at 0.14 / 0.28. |
| GPT-6 Luna | `azure` | 0.10 / 0.50 | At 272,000 input tokens, its higher tier exceeds the ceiling. |
| Gemini 2.5 Flash Lite | `google-vertex` | 0.10 / 0.40 | Image and reasoning usage have additional published rate fields. |

All six list image input and tool calling in the public catalog and have at least
one tool-capable endpoint in the public ZDR feed below the ceiling. Qwen3.8 Flash
met the price/modality check but had no listed ZDR endpoint, so it was excluded.
Free/batch variants, variable-price routers, mutable latest aliases and pro
reasoning modes are excluded from this real-time comparison. The table is a
screening snapshot, not a quality ranking or a promise of future availability.

The transport retains production `data_collection: "deny"` and `zdr: true` and
adds `max_price: {prompt: 0.18, completion: 0.72}`. The latter uses **USD per
million tokens**, not per-token dollars, and rejects requests if no endpoint
qualifies. This extra ceiling changes routing compared with the unmodified app;
results are not a claim of identical production provider selection. There is no
weaker-privacy fallback.

The two initial workers each had a $0.75 measured-spend threshold, checked
before every provider request. A successful response without usage cost stops further requests. The
already-started request can take measured spend past the threshold; this is not
a prepaid hard spending limit. Response telemetry belongs to its original case,
including cancellation callbacks. Two workers do not share a live spend counter.
Two malformed HTTP-200 responses omitted usage and stopped the first worker's
batch. The failed cases stayed in the results; only its unrun cases resumed in
fresh processes with reduced $0.65 and $0.55 thresholds. No failed case was rerun.
Recorded spend was far below the user’s $25 authorization. Charges for the two
responses with missing usage remain unreconciled and cannot be claimed as zero.

Token rates are not total turn cost: tokenizers, image tokenization, output
reasoning, tool-call count and caching vary. Cache reads can favor DeepSeek;
cache writes and long-context tiers can add cost. No separate image-price field
does not imply free images. Report actual returned usage/cost and provider per
request, and note missing or unbilled cancellation data. Public dashboard latency
is not substituted for measured time to the final answer.

Sources: [OpenRouter model catalog](https://openrouter.ai/api/v1/models),
[ZDR endpoint feed](https://openrouter.ai/api/v1/endpoints/zdr),
[price-cap units and routing](https://openrouter.ai/docs/guides/routing/provider-selection#max-price),
[ZDR policy](https://openrouter.ai/docs/guides/features/zdr).
Model pages: [DeepSeek](https://openrouter.ai/deepseek/deepseek-v4.1-flash),
[Haiku](https://openrouter.ai/anthropic/claude-haiku-5.5),
[GLM](https://openrouter.ai/z-ai/glm-5.3-flash),
[MiMo](https://openrouter.ai/xiaomi/mimo-v2.6-flash),
[Luna](https://openrouter.ai/openai/gpt-6-luna),
[Gemini](https://openrouter.ai/google/gemini-2.5-flash-lite).

## Grading and reporting

Grade transcripts without model identities first, using the frozen expected
facts. Record correctness, retrieved-source coverage, exact citation validity,
unsupported assertions, visible reply length and whether a card was appropriate.
A card's valid source link proves retrieved provenance, not that its displayed
value is true. Concise valid prose is not a factual failure merely because the
model did not choose a card. Conditional or multi-source answers may need prose.

A full pass requires a correct supported answer, valid source links and no
material unsupported claim. Visual tasks require retrieved pixels; the
cross-document task requires both sources. Record errors, timeouts and incomplete
runs explicitly rather than dropping them. Do not selectively retry a model or
combine correct pieces from different attempts.

Report pass counts and individual failures separately from latency, number of
provider/tool rounds, actual charged cost and card use. Two repetitions are a
small consistency check, not a population accuracy estimate. The 180-second
per-case timeout is also a result, not a successful answer with missing text.

The harness logs request model/provider, response status, timing, usage/cost,
image count, message/text sizes, system-prompt hash, tool-definition count,
provider options, tool trace and final transcript. It omits credential headers,
raw image base64 and provider reasoning content. Public pricing snapshots and
benchmark fixtures/results are retained separately under `/tmp/sz-model-benchmark*`
for review; publish only the summarized results after checking for private data.

## Results

| Model | Fully supported passes | Switch passes | Median seconds | Slowest seconds | Recorded cost, 10 runs | Cards displayed |
|---|---:|---:|---:|---:|---:|---:|
| DeepSeek V4.1 Flash | 8/10 | 0/2 | 6.21 | 44.07 | $0.01240 | 2 |
| Claude Haiku 5.5 | 8/10 | 0/2 | 5.99 | 12.05 | $0.03337 | 0 |
| GPT-6 Luna | 8/10 | 0/2 | 23.06 | 74.03 | $0.01368 | 2 |
| MiMo V2.6 Flash | 6/10 | 0/2 | 41.35 | 145.03 | $0.01699 + unknown | 6 |
| GLM 5.3 Flash | 8/10 | 0/2 | 7.55 | 10.05 | $0.00804 + unknown | 5 |
| Gemini 2.5 Flash Lite | 0/10 | 0/2 | 2.36 | 4.97 | $0.00479 | 0 |

Latency is measured to completion **or failure**, across all ten attempts; it
is not time to a correct answer. One GLM and one MiMo attempt failed with an
invalid provider response and missing usage. There were no 180-second timeouts.
No percentile claims or significance claims are made from ten attempts per model.

The independent grader scored 38/60 full passes: switch 0/12, clinic 10/12,
chart 10/12, cross-document comparison 8/12, absent price 10/12. All four non-switch
tasks produced supported answers in both repetitions for DeepSeek, Haiku, Luna and GLM. MiMo passed the
clinic, chart and absent-price tasks but failed both cross-document runs: one
provider failure and one correct factual comparison with a corrupted citation.
Gemini sometimes supplied correct facts, but none of its attempts met the full
retrieval-and-citation criteria. Thus 0/10 does not mean every sentence was false.

### Disclosed grading interpretation

The frozen absent-price rubric specifically requested an entire-page read. The
blinded grader accepted a successful search excerpt that **explicitly says the
policy does not state a renewal price**, while rejecting an inference based only
on a failed search. This is enough evidence for that narrow claim, but it is a
relaxation of the literal retrieval-method requirement, and must not be hidden.
The table reports supported-answer passes under that interpretation.

Applying the literal whole-page requirement gives **34/60**, rather than 38/60:
Haiku and Luna each lose both absent-price passes (6/10 each instead of 8/10).
DeepSeek 8/10, GLM 8/10, MiMo 6/10 and Gemini 0/10 are unchanged. The public data
retains both counts and the frozen rubric remains unchanged. Neither reading
makes an alternative better than DeepSeek or fixes the switch test.

### Cost and speed decision

- **Keep DeepSeek for now.** None increased measured supported-answer accuracy,
  and none solved the user's original question.
- **Haiku was only slightly faster by median**, with the same pass count and no
  cards. Its ten answers cost 2.69 times DeepSeek's recorded total despite lower
  advertised token rates. It fails a +20% ceiling interpreted as actual task cost.
- **Luna cost about 10% more**, but its median was 3.71 times slower. Repeated
  optional-argument errors contributed; this is not a clean judgment of its
  underlying reasoning ability.
- **GLM is worth a later compatibility/reliability check**, with more card use and
  lower recorded cost, but its median was 22% slower, one provider request failed,
  and that request's charge is unknown. It is not a demonstrated overall upgrade.
- **MiMo was much slower** and its known cost already exceeded DeepSeek by 37%,
  before its missing charge. **Gemini Lite's speed did not produce grounded
  answers** in this app pipeline.

All models passed the token-rate screening. The actual-cost comparison above is
stricter and matters for the user's bill. Provider caching, reasoning and repeated
tool calls explain why list-price order does not equal per-answer cost order.
Actual routed providers were InferenceNet/DigitalOcean (DeepSeek), Google
(Haiku and Gemini), Azure (Luna), Venice/Novita (MiMo), and Together/InferenceNet
(GLM). Example catalog endpoints were not forced; the same price/privacy filter
was applied to each requested model.

### Useful findings to retain

1. **Prompt rollback is not a reliability fix.** The restored general prompt can
   succeed, but the current repeated test did not. No switch terminology, expected
   measurement, or question-specific rule was added to the production prompt.
2. **Retrieval and interpretation both fail.** Some models never rendered the
   drawing, often following the stale summary toward the specification table.
   Others received the drawing and still selected the wrong quantity. A valid
   retrieved citation alone does not prove the claim.
3. **Cards need correct evidence, not just a valid URL.** Fifteen responses used
   cards; four displayed incorrect switch answers. The card transport/rendering
   feature cannot certify semantic correctness. No extra model round was added
   merely to obtain a card, and no answer was selectively retried.
4. **Normalize optional tool inputs in a separate fix.** Luna repeatedly supplied
   `revision: ""`; production treated that as a stale revision and rejected the
   read/render. It sometimes recovered, but incurred extra requests. Empty optional
   values should be handled consistently with omission, with regression tests;
   a nonempty wrong revision must still be rejected. This benchmark left the
   implementation frozen so every model faced the same contract.
5. **Preserve honest coverage and explicit image tools.** Cached summaries are
   navigation hints. Full pages, regions and the on-request current user view are
   useful capabilities, but larger previews/higher effort did not reliably fix
   the earlier failures. Improve summary coverage and tool contracts before
   adding more prompt rules or switching by advertised benchmarks alone.

### Verification and artifacts

- Exactly 60 unique run IDs, six models, five questions and two repeats; all runs
  independently graded. First-request system-prompt hashes match across models
  for each case. All five source-file SHA-256 hashes remained unchanged.
- Every recorded request retained `data_collection: deny`, `zdr: true` and the
  $0.18/$0.72 price caps. The base prompt and source bytes were not changed between models. The
  single grading interpretation above was applied uniformly, with literal-rubric
  counts also retained. Error cases remain in the denominator.
- [Reusable runner](../../../../tools/ai-model-benchmark/README.md) builds
  separately from the application. Offline build, instrumentation-drift checks,
  malformed-input checks, telemetry/redaction self-tests and file-size checks
  passed. It adds no code to app launch or document opening.
- [Synthetic fixtures and frozen rubric](../../../../tools/ai-model-benchmark/fixtures/README.md)
  retain the four small control documents. The private switch source and full
  extracted transcripts are not committed. Public per-run data contains grades,
  timings, recorded usage and provider names, without keys or local source paths.
- Private raw results remain in `/tmp/sz-model-benchmark-results-*.json`; pricing
  snapshots, manifests and blinded grades remain under the same prefix. The
  public [results JSON](model-benchmark-2026-10-11-results.json) is summarized data.

The scope is deliberately five small tests. It does not establish long-document,
multilingual, mutation-tool or live-viewport quality, and it does not justify a
claim that any model will always read technical drawings correctly.

## Release decision — 2026-10-11

After reviewing the known benchmark limitation, the user explicitly authorized
release and requested README pictures and a link to these results. The
[26.10.11-1 release notes](../../releases/26.10.11-1.md) retain the limitation and
separate user features from AI integration details. This authorization changes
the publication decision, not the benchmark scores, model default or production
prompt. The independent [card UI and evidence-button QA](card-release-qa.md)
remains a functional check, not a claim of semantic answer accuracy.
