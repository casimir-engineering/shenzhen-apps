# Full-page and region evidence — 2026-10-10

## Problem and change

`render_page` saved a local PNG and showed it in the transcript, but `nextRequest`
filtered out all local messages. The model received only `rendered: true`, not
pixels. This could lead to text-only conclusions about dimensions visible in a
drawing while the UI misleadingly displayed an image next to the answer.

The tool now accepts a whole page or a normalized top-left `region` (`x`, `y`,
`width`, `height`) and optional longest-edge `maxDimension` from 256 to 2400
(default 1600). Core rendering clips directly to the region; Markdown renders
its existing pagination plan into a bounded region context. Original sRGB colors
are explicit. The return includes crop coordinates, pixel dimensions, revision
and page citation. Small crops receive their own resolution budget.

The request worker projects saved preview references into OpenRouter multipart
`image_url` PNG data URIs. Images are inserted only after every response in a
tool-call batch, retaining tool pairing. Up to four recent images and 9 MiB raw
PNG data are included, with the newest evidence prioritized. Missing, invalid
or omitted images have explicit model-facing notices. Transcripts keep private
asset references rather than base64 copies. Reopening a chat reconstructs image
evidence lazily. Image work and large request serialization happen off-main;
plain text chat takes its existing immediate path.

The model picker labels catalog entries with image input support **Images**.
Unsupported image/provider errors explain the requirement without switching the
selected model. The system prompt asks for whole-page then detail inspection
before concluding that diagram information is absent from extracted text.

Protocol reference: [OpenRouter image understanding](https://openrouter.ai/docs/guides/overview/multimodal/image-understanding).

## Verification and review

- Headless reader acceptance: actual PDF quadrants verify crop coordinates,
  original colors and independently magnified crop pixels. Markdown crop tests
  verify visible heading/paragraph ink. Invalid bounds, stale revisions and
  cancellation reject rendering. Real tool dispatch verifies opaque IDs,
  crop metadata, PNG assets and citations; tool construction performs no reads
  and creates no render queue.
- The new regression fails against the previous Session implementation precisely
  because no image bytes are delivered; it passes with the corrected session.
- Session fixtures verify decoded PNG bytes reach model input, all batched tool
  responses precede images, resumed chats reconstruct images, missing assets are
  explicit, and cancellation prevents network dispatch. Plain-text requests
  perform no preview reads. Stored JSON contains no base64 data.
- Transport fixtures intercept outgoing requests and check multipart JSON,
  size limits, privacy routing and useful incompatible-model errors.
- Asset reads are restricted to the current chat's exact private asset directory,
  valid UUID PNG filenames, regular files and bounded sizes. Symlinks and files
  outside the chat are rejected. Independent review additionally identified
  malformed persisted call IDs and FIFO blocking; both were hardened and tested.
- Model catalog tests cover image labels, ordinary text models and malformed
  architecture metadata. Launch-work policy and all 32 updater tests pass.

Tests use synthetic documents and a fake network endpoint. No live model answer
quality is claimed. No user app was launched, quit or captured.
