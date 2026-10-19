# Local / AI translation choice — 2026-10-12

## User behavior

Translate opens a native two-item menu below its toolbar button: Local and AI.
File/overflow entries use the same choice. Each invocation has a source-named panel; translating a different document never silently reuses another document’s text. Local routes into the existing Argos
selection or PDF pipeline, including text/raster-to-PDF continuations without a
second chooser. AI opens a dedicated translation panel; it does not create chat.

AI displays the extracted text and uses the configured default AI language in
the shared searchable language control. The user must press Translate with AI
before text leaves the computer. The panel states that OpenRouter receives text
using the selected model and that the result is a new Markdown document.

Preparation is cancellable before/between pages and lines, with the character budget checked before appending each line. Closing a panel cancels preparation and requests. Source Markdown is decoded on the worker without flattening headings, links or code fences.

The translated output is editable, cancellable, and explicitly saved/opened as
a separate document. Original-path, symlink and hard-link aliases are rejected
by the save guard, for both the original path and the actual Collection working path. Nothing is saved on failure or cancellation.

## Implementation

- `SPDFMacTranslationChoice*`: native menu, lazy panel integration, background
  text extraction through the authenticated worker document cache. The cache
  owns its documents; the translation code must not close those pointers.
- `SPDFMacAITranslationPanel`: explicit source review, searchable language,
  existing noninteractive credentials and settings, progress, cancel and save.
- `SPDFMacAITranslation`: sequential ~3,000-character requests through the
  existing OpenRouter transport (including its privacy settings). Unicode-safe
  chunks prefer paragraph boundaries and retain all source characters.
- Maximum input: 500,000 characters. Larger documents receive a clear error and
  can be translated as selections. No automatic cloud request or launch hook.
- Empty/scanned documents require OCR. Text extraction preserves readable text,
  not source page layout. Large tables spanning chunks can need manual cleanup.

## Verification

- `make -C portable mac-ai-translation-tests`: mocked OpenRouter multi-part
  success, error, cancellation and stale completion suppression; no requests on
  service construction or panel population; native menu action routing;
  searchable language control; source/alias preservation; cancellation before extraction completion and per-line bounds; native panel geometry. Transport errors use translation-specific wording rather than claiming chat persistence.
- Existing translation copy, Chinese filtering, document-tool input and AI
  transport suites: pass.
- Offscreen native panel rendered to `/tmp/spdf-ai-translation-panel.png` and
  visually inspected in dark appearance. The app was not launched or captured.
- No paid API requests. Translation quality was not benchmarked against a live
  provider; provider behavior remains model-dependent.
- Independent reviewer found and verified fixes for preparation cancellation,
  stale document-panel reuse, transport wording, working-copy save protection,
  raw Markdown preservation and immediate closed-panel teardown. Regression
  tests check closed-panel release and absence of callback retain cycles.
- Final `make -C portable -j12 mac-app`: exit 0, after freezing reviewed source.
  Built/ad-hoc signed the local bundle only; did not install or launch it.
- `tools/check-file-sizes.sh` and `git diff --check`: pass.
