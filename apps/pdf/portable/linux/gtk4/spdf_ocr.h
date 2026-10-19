// spdf_ocr.c — OCR flow for the GTK4 shell (Wave C): language selector
// (19 Tesseract language options, persisted choice), writable preflight via
// spdf_annot_preflight, already-has-text warning + backup copy, OCRmyPDF run
// (one job per core, deskew, image-only force retry) with a live-log progress
// window and Cancel, post-run validation through the core text extractor
// before the output is swapped over the original, then render invalidate +
// document reload + toast. Toolchain detection + one-click install is shared
// with translation (spdf_toolchain.c).
//
// GTK3 provenance (portable/linux/ShenzhenPDFGtk.c):
//   OCR_LANGUAGE_OPTIONS (@7160) → spdf_ocr_languages
//   prompt_for_ocr_language (@7281) → ocr_language_dialog (persisted choice
//     is new on GTK4; GTK3/Mac always preselected the first entry)
//   backup_path_for_pdf (@7314) → spdf_ocr_backup_candidate + probing loop
//   ocr_failure_message (@7350) → spdf_ocr_failure_message
//   pdf_has_selectable_text_at_path (@7370) → ocr_validate (GTask thread)
//   run_ocr_attempt (@7386) → spdf_ocr_build_argv + streaming spawn
//   ocr_worker two-attempt loop (@7647) → spdf_ocr_validation_verdict
//   ocr_clicked / start_ocr_for_language (@7715/@7726) → action_ocr /
//     ocr_start_for_language
//   install_ocr_then_run (@7600) → ocr_offer_install (spdf_toolchain runner)
//   journal item 37: never trust process success — validate the produced PDF
//     with the core text extractor, leave the original untouched on failure,
//     retry once with --force-ocr for image-only PDFs.
#pragma once

#ifndef SPDF_OCR_TESTING
#include "spdf_window.h"

G_BEGIN_DECLS

// Registers win.ocr on the window action map (replaces the Wave A stub).
// Called from spdf_window_init.
void spdf_ocr_install(SpdfWindow* win);

G_END_DECLS
#else
#include <glib.h>
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Pure logic (glib only — no GTK, no core), exercised by tests/ocr_test.c.

typedef struct {
    const char* code;  // Tesseract -l value, e.g. "chi_sim+eng"
    const char* label; // human-readable
} SpdfOcrLanguage;

// The 19 OCR language options, identical to GTK3 OCR_LANGUAGE_OPTIONS and the
// Mac spdf_ocr_languages() table (order included).
const SpdfOcrLanguage* spdf_ocr_languages(int* count);
int spdf_ocr_language_index(const char* code); // -1 when unknown

// OCRmyPDF argv (NULL-terminated strv, caller frees with g_strfreev):
//   <tool> --jobs <n> --rotate-pages --optimize 1 -l <language>
//   [--deskew [--force-ocr]]   (no existing text; force on the retry)
//   [--redo-ocr]               (existing text)
//   <input> <output>
char** spdf_ocr_build_argv(const char* tool,
                           const char* language,
                           guint jobs,
                           gboolean has_text,
                           gboolean force_ocr,
                           const char* input_path,
                           const char* output_path);

// Decision after an OCRmyPDF attempt (journal item 37):
//   run_ok           process exited 0
//   output_has_text  core verdict on the produced PDF (-1 error, 0 no, 1 yes)
//   input_had_text   the source PDF had a text layer (redo path)
//   forced           this attempt already used --force-ocr
typedef enum {
    SPDF_OCR_SWAP,        // install the output over the original
    SPDF_OCR_RETRY_FORCE, // image-only PDF, no text produced: retry once forced
    SPDF_OCR_FAIL_NO_TEXT,// completed but no text; original left unchanged
    SPDF_OCR_FAIL_ERROR   // process failed (or validation errored)
} SpdfOcrVerdict;
SpdfOcrVerdict spdf_ocr_validation_verdict(gboolean run_ok,
                                           int output_has_text,
                                           gboolean input_had_text,
                                           gboolean forced);

// Friendly failure text for OCRmyPDF output (redo-ocr incompatibility and
// Python tracebacks get dedicated explanations).
char* spdf_ocr_failure_message(const char* detail);

// Backup name candidates: index 0 → "<stem>_backup.<ext>", n →
// "<stem>_backup_<n+1>.<ext>" (GTK3 numbering: the second candidate is _2).
char* spdf_ocr_backup_candidate(const char* path, int index);

// Same-directory hidden temp file: ".<basename>.ocr-<nonce>.pdf".
char* spdf_ocr_temp_path(const char* path, guint32 nonce);

G_END_DECLS
