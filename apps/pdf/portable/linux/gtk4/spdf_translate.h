// spdf_translate.c — translation for the GTK4 shell (Wave C):
//
//   * Selection translation: a "Translate Selection" dialog (From/To language
//     rows, editable input, translated output, status line) — the Mac
//     selection panel (buildSelectionTranslationPanelIfNeeded /
//     runSelectionTranslationWithText) in libadwaita idiom. The GTK3 frontend
//     had no such panel (its selection path wrote a PDF); Mac parity wins per
//     the gtk4-parity spec.
//   * Whole-document translation: writable preflight (spdf_annot_preflight),
//     From/To prompt with persisted languages, worker thread that extracts
//     per-line text through the core, batches whole pages through Argos
//     Translate spawns, and writes "<stem>_<lang>.pdf" with the translated
//     text overlaid per line (spdf_save_translated_copy_full), opened in a
//     new tab; cancellable live-log progress window.
//   * Toolchain: Argos install script shared with OCR (spdf_toolchain.c) and
//     on-demand "argospm install translate-<from>_<to>" language-package
//     fetches, resuming the interrupted translation (Mac flow).
//
// GTK3 provenance (portable/linux/ShenzhenPDFGtk.c):
//   k_translation_languages (@495) → spdf_translation_languages (19 entries)
//   translation_suffix_for_target_language / translate_output_path_for_pdf /
//     translate_temp_path_for_pdf (@8057-@8086) → spdf_translate_suffix_* /
//     spdf_translate_output_path / spdf_translate_temp_path
//   extract_document_lines_for_translate (@8120) → translate_collect_items
//   extract_full_document_text_for_translate (@8188) + write_translated_text_pdf
//     cairo pipeline (@8243) → translate_fallback_* (kept for PDFs whose text
//     only external extractors can read)
//   translate_worker (@8359) → translate_doc_thread (per-page spawn batching
//     upgraded to the Mac page-boundary batch budget of 100 lines)
//   prompt_translate_languages / populate_translation_language_combo (@8730/
//     @8712) → translate_language_prompt / translate_language_dropdown
//   translate_install_script + install_translate_then_run (@8573/@8666) →
//     spdf_toolchain_argos_install_script + shared runner
//   translate_cancel_clicked / translate_force_exit_subprocess (@8048/@7926)
//     → GCancellable + spdf_toolchain_run_capture
//
// Mac post-freeze refinements ported (commit 78072bf55):
//   * chapters (outline titles) + comments join the batched pipeline, written
//     via spdf_save_translated_copy_full;
//   * per-item script-based translate/skip filter
//     (spdf_translation_should_translate);
//   * empty body text is not fatal while chapters/comments remain;
//   * batch scope labels ("pages 3-5 and comments") in progress/error text;
//   * extra Argos output lines folded into the batch's last line with spaces.
// NOT ported from 78072bf55 (macOS-only): NSAlert/NSPanel plumbing,
// NSCharacterSet whitespace collapsing (replaced by
// spdf_translate_collapse_whitespace), and the Mac progress-panel
// double-label layout — the shared SpdfToolchainProgress window is used
// instead.
#pragma once

#ifndef SPDF_TRANSLATE_TESTING
#include "spdf_window.h"

G_BEGIN_DECLS

// Registers win.translate on the window action map (replaces the Wave A
// stub). Called from spdf_window_init. The action translates the current
// selection when one exists, else the whole document (Mac translateDocument).
void spdf_translate_install(SpdfWindow* win);

G_END_DECLS
#else
#include <glib.h>
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Pure logic (glib only — no GTK, no core), exercised by
// tests/translate_test.c.

typedef struct {
    const char* code; // Argos code, e.g. "zh"
    const char* name; // human-readable, e.g. "Chinese (Simplified)"
} SpdfTranslationLanguage;

// The 19 Argos translation languages, identical to the GTK3
// k_translation_languages table and the Mac popup (order included).
const SpdfTranslationLanguage* spdf_translation_languages(int* count);
int spdf_translation_language_index(const char* code); // -1 when unknown

// Output-name suffix: "english" for en, "translated" for empty, else the code.
const char* spdf_translate_suffix_for_language(const char* target_language);
// "<dir>/<stem>_<suffix>.pdf" next to the source document. Caller frees.
char* spdf_translate_output_path(const char* path, const char* target_language);
// Same-directory hidden temp file: ".<basename>.translate-<nonce>.pdf".
char* spdf_translate_temp_path(const char* path, guint32 nonce);

// Collapse runs of whitespace (space/tab/newline/CR) to single spaces and
// trim; used for outline titles and comment bodies so the one-line-per-item
// mapping through Argos holds. Caller frees.
char* spdf_translate_collapse_whitespace(const char* text);

// Batch assembly over the translation item list (body blocks page-grouped,
// then outline titles, then comments — 78072bf55 ordering). Batches end on
// page-group boundaries and hold at most `budget` lines (unless a single
// page exceeds it); Mac batchLineBudget = 100.
typedef struct {
    int kind; // 0 = body line, 1 = outline title, 2 = comment
    int page; // body: page index; outline: page_count; comment: page_count+1
} SpdfTranslateBatchItem;
#define SPDF_TRANSLATE_BATCH_LINE_BUDGET 100
int spdf_translate_batch_end(const SpdfTranslateBatchItem* items, int count, int start, int budget);

// Human-readable batch scope for progress/error text: "page 3",
// "pages 3-5 and comments", "chapter titles", ... Caller frees.
char* spdf_translate_batch_scope(const SpdfTranslateBatchItem* items, int count, int start, int end);

// Distribute one batch's Argos output over result_lines[start..end): line i
// gets output line i-start (" " when Argos produced nothing for it); extra
// output lines are folded into the last line, space-joined and newline-free
// (78072bf55: stray newlines would shift every later overlay). Existing
// entries are replaced; new entries are allocated.
void spdf_translate_apply_batch_output(char** result_lines, int start, int end, const char* batch_output);

G_END_DECLS
