# AI model benchmark

An opt-in macOS command-line runner for comparing document answers through the
app's actual chat session, prompt, full tool definitions, retrieval, page rendering,
vision-message conversion, citation checks, and answer-card validation. It is not
linked into the application and adds nothing to launch or document-open paths.

The runner makes paid OpenRouter requests **only when explicitly executed with a
case manifest**. Building does not run it, sign it, read credentials, or call APIs.

## Build

From the repository root, with the normal portable macOS build dependencies:

```sh
python3 tools/ai-model-benchmark/build.py --output-dir /tmp/sz-ai-benchmark
```

The output directory must be outside the repository. The script creates a scratch
copy of the production transport and injects telemetry plus the benchmark budget
checks. Every replacement must match exactly once; source drift fails the build
instead of silently losing a hook. It then links the production workspace-probe
objects through the existing portable Makefile. Production files are unchanged.
`--generate-only` validates hooks and writes build inputs without compiling.

For existing Keychain access, an authorized developer can explicitly sign the
helper with the app's normal Developer ID identity and identifier:

```sh
codesign --force --sign 'Developer ID Application: YOUR TEAM (TEAMID)' \
  --identifier com.intuition.shenzhenpdf --options runtime \
  /tmp/sz-ai-benchmark/ai-model-benchmark
/tmp/sz-ai-benchmark/ai-model-benchmark --check-key
```

`--check-key` prints only `true` (exit 0) or `false` (exit 3). It uses the production
noninteractive credential API and does not show a Keychain authorization dialog.
If access is unavailable, connect/authorize normally in the app first. An explicit
`--stdin-key` argument offers a hidden terminal prompt as a fallback; enter the key
personally. Never put credentials in manifests, command arguments, environment
variables, logs, or the repository. The build script never signs automatically.

## Cases and execution

Keep private source paths and scoring truth outside the repository. A manifest is
an array of cases or an object containing `cases` and `costCapUSD`:

```json
{
  "costCapUSD": 0.75,
  "cases": [
    {
      "name": "service_comparison",
      "repeat": 1,
      "model": "provider/model-id",
      "question": "Which plan has the longer warranty?",
      "path": "/absolute/path/standard-plan.pdf",
      "paths": [
        "/absolute/path/standard-plan.pdf",
        "/absolute/path/extended-plan.pdf"
      ]
    }
  ]
}
```

`path` is the active document, `paths` is the available workspace. Omit `paths` for
one document. Source paths are resolved through symlinks. Optional `metadata`
supplies the active document's cached metadata, or `metadataByPath` supplies the
same production-shaped data per canonical source path. Use identical metadata
across models; never insert expected answers or scoring instructions.

```sh
/tmp/sz-ai-benchmark/ai-model-benchmark /tmp/cases.json /tmp/results.json
```

Each case starts a fresh conversation and has a 180-second deadline. The model
must be specified per case. Shuffle/rotate models consistently across repetitions;
do not selectively repeat failed answers. Score against a separate truth file,
which must never be given to the runner or model.

## Budget and privacy

Every provider request, including retries, preserves the production
`data_collection: deny` and `zdr: true` settings and applies a fixed maximum price
of **$0.18 per million prompt tokens and $0.72 per million completion tokens**.
There is no manifest option to bypass these price limits. Unavailable eligible
providers produce an error; the runner does not silently weaken privacy or switch
the requested model.

The measured cost cap defaults to $2 and accepts values greater than zero up to
$2. Before every request the runner checks cumulative reported `usage.cost`.
Reaching the cap stops further requests. A successful response without cost data
also stops further requests; errors without cost are recorded as unknown. A
request already in flight can exceed the remaining cap: this is a measured spend
guard, not an account-level prepaid limit. Each process has its own cap; divide
an overall allowance between concurrent processes. Do not run unbounded workers.

Credentials and image/base64 payloads are excluded from the JSON report. However,
reports **do contain document paths, extracted text, answers and citations**; treat
them as private. The isolated temporary chat directory may also contain page
preview files. No private documents, credentials, manifests, truth, or results
belong in this repository.

## Output and limits

The JSON output is replaced atomically after each completed case and includes:

- Final chat, structured cards, tool arguments/results, and citation provenance.
- Total latency, timeout and session status, run identifier and repetition.
- Per-request provider/model/response ID, usage/cost, HTTP status and latency.
- Message count, text byte count, image count and system-prompt SHA-256.
- Cumulative measured cost, missing-cost flag, definitions and isolated state path.

HTTP response telemetry belongs to the case that created the request, including
late cancellation callbacks. A callback arriving after a case snapshot may be
absent from that snapshot; it never gets assigned to the next case. Output-write
failure stops execution. Exit 0 means the batch ran, **not that answers were
correct**: inspect case errors, timeouts and evidence before scoring.

Uniform benchmark differences from the desktop app:

- Automatic chat-title generation is disabled to exclude auxiliary cost/latency.
- A minimal read-only workspace supplies paths, active page 1 and optional cached
  metadata. Production execution is allowed only for `list_workspace`,
  `document_metadata`, `read_pages`, `search_documents`, `render_page`, and
  `reader_state`. Other app tools remain in the definitions but return an explicit
  unavailable-in-benchmark error; this includes mutations and Collection/chat
  listing outside the isolated workspace. Sources are never modified.
- `current_view` returns an explicit unavailable error because no user viewport
  exists. `render_page` works normally. UI navigation, button hit targets, real
  window context and visual card appearance require separate computer-use QA.
- No automatic document analysis is triggered. Documents need not be open in the
  user's running app; only the provided case workspace is accessible.

A passing answer benchmark is not a substitute for visual tests or an assurance
that a model will always interpret drawings correctly.

## Offline runner checks

After building, run `/tmp/sz-ai-benchmark/ai-model-benchmark --self-test`. This
checks malformed manifests/provider responses, redaction, and cost guards without
reading credentials, creating an app window, or making provider requests. Manifest
shape/type validation also runs before credential lookup in normal execution.
