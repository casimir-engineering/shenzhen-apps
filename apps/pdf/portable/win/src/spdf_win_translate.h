/* spdf_win_translate.h -- on-device translation for the Windows shell: the
 * 19-language Argos table, the enablement policy, the whole-document batching
 * and naming logic, the Argos command line, and the two runners -- one text
 * (the selection panel) and one document (writes <name>_<lang>.pdf).
 *
 * A PORT of portable/linux/gtk4/spdf_translate.{h,c} (1,631 lines) for the
 * pipeline and of portable/mac/SPDFMacTranslationPolicy.mm for the policy,
 * both toolkit-free originals. portable/win/tests/translate_test.c pins the
 * pure half with the GTK suite's cases plus the Mac policy's.
 *
 * WHAT IS DIFFERENT ON WINDOWS:
 *   - No pdftotext/mutool + cairo fallback. GTK kept it for PDFs whose text
 *     only external extractors can read; there is no cairo here and the core
 *     extractor is the one the app already renders with. A document with no
 *     translatable item reports that plainly instead.
 *   - No Markdown tabs yet, so the policy's markdownActive is always false;
 *     it is kept in the context struct so the Mac tests transcribe 1:1.
 *   - The Argos console scripts sit in Python's per-user Scripts directory
 *     (spdf_win_toolchain.h); the runners take the resolved path.
 * Everything a document's text touches is a local process over a pipe.
 */
#ifndef SPDF_WIN_TRANSLATE_H
#define SPDF_WIN_TRANSLATE_H

#include <stddef.h>

#include "spdf_win_toolchain.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpdfWinTranslationLanguage {
    const char* code; /* Argos code, e.g. "zh" */
    const char* name; /* human-readable, e.g. "Chinese (Simplified)" */
} SpdfWinTranslationLanguage;

/* The 19 Argos languages, identical to GTK k_translation_languages and the
 * Mac popup (order included). */
const SpdfWinTranslationLanguage* spdf_win_translation_languages(int* count);
int spdf_win_translation_language_index(const char* code); /* -1 when unknown */

/* --- policy (SPDFMacTranslationPolicy.mm, transcribed) --------------------- */

typedef struct SpdfWinTranslationContext {
    int markdown_active;    /* always 0 on Windows today */
    int pdf_document_open;  /* a core document is loaded */
    int has_selection;      /* trimmed selected text is non-empty */
    int translation_running;
    int install_running;
} SpdfWinTranslationContext;

/* The toolbar button and its menu twin: enabled whenever a document is open
 * and nothing is running; with a selection the button translates that. */
int spdf_win_translation_command_enabled(SpdfWinTranslationContext c);
/* The selection panel. */
int spdf_win_translation_selection_enabled(SpdfWinTranslationContext c);
/* Whole-document translation: the PDF render path only. */
int spdf_win_translation_whole_document_available(SpdfWinTranslationContext c);

/* --- naming ------------------------------------------------------------------ */

/* "english" for en, "translated" for empty, else the code itself. */
const char* spdf_win_translate_suffix_for_language(const char* target_language);
/* "<dir>\<stem>_<suffix>.pdf" beside the source (its separator kept). */
int spdf_win_translate_output_path(const char* path, const char* target_language, char* out, size_t out_bytes);
/* Same-directory temp file: ".<basename>.translate-<nonce>.pdf". */
int spdf_win_translate_temp_path(const char* path, unsigned nonce, char* out, size_t out_bytes);

/* Collapse runs of whitespace to single spaces and trim; outline titles and
 * comment bodies go through this so the one-line-per-item mapping through
 * Argos holds. Returns the length written. */
size_t spdf_win_translate_collapse_whitespace(const char* text, char* out, size_t out_bytes);

/* --- batching (Mac page-boundary batches, budget 100 lines) ------------------ */

typedef struct SpdfWinTranslateBatchItem {
    int kind; /* 0 = body line, 1 = outline title, 2 = comment */
    int page; /* body: page index; outline: page_count; comment: page_count+1 */
} SpdfWinTranslateBatchItem;
#define SPDF_WIN_TRANSLATE_BATCH_LINE_BUDGET 100

/* End (exclusive) of the batch starting at `start`: whole page groups, at most
 * `budget` lines unless a single page exceeds it. */
int spdf_win_translate_batch_end(const SpdfWinTranslateBatchItem* items, int count, int start, int budget);
/* "page 3", "pages 3-5 and comments", "chapter titles", ... for progress text. */
size_t spdf_win_translate_batch_scope(const SpdfWinTranslateBatchItem* items, int count, int start, int end,
                                      char* out, size_t out_bytes);
/* Distribute one batch's Argos output over result_lines[start..end): line i
 * gets output line i-start (" " when Argos produced nothing for it); extra
 * output lines fold into the last line, space-joined and newline-free.
 * Entries are malloc'd strings; existing ones are freed and replaced. */
void spdf_win_translate_apply_batch_output(char** result_lines, int start, int end, const char* batch_output);

/* "<argos-translate>" --from-lang <from> --to-lang <to>   (text on stdin) */
size_t spdf_win_translate_argos_cmd(const char* argos, const char* from_lang, const char* to_lang, char* out,
                                    size_t out_bytes);

/* --- runners (spdf_win_translate_run.cpp, Win32 + core) --------------------- */

/* Translate one text through Argos, synchronously, on the calling thread.
 * `cancel` is an event HANDLE or NULL. On success *translated_out is malloc'd
 * (diagnostic WARNING lines stripped); on failure err holds Argos's own
 * message, which spdf_win_toolchain_argos_failure_is_missing_package() can
 * classify. Returns 1 / 0 / -1 for cancelled. */
int spdf_win_translate_text(const char* argos_path, const char* scripts_dir, const char* from_lang, const char* to_lang,
                            const char* text, void* cancel, char** translated_out, char* err, size_t err_len);

typedef struct SpdfWinTranslateDocJob SpdfWinTranslateDocJob;

/* All on the WORKER thread; on_done exactly once. On success `output_path`
 * is the finished <stem>_<lang>.pdf. */
typedef struct SpdfWinTranslateDocCallbacks {
    void* user;
    void (*on_line)(const char* utf8, void* user);
    void (*on_progress)(double fraction, const char* message, void* user);
    void (*on_done)(int success, int cancelled, const char* message, const char* output_path, void* user);
} SpdfWinTranslateDocCallbacks;

typedef struct SpdfWinTranslateDocRequest {
    const char* pdf_path; /* UTF-8 */
    const char* from_lang;
    const char* to_lang;
    const char* argos_path;
    const char* scripts_dir; /* prepended to the child's PATH; may be "" */
} SpdfWinTranslateDocRequest;

SpdfWinTranslateDocJob* spdf_win_translate_doc_start(const SpdfWinTranslateDocRequest* request,
                                                     const SpdfWinTranslateDocCallbacks* callbacks);
void spdf_win_translate_doc_cancel(SpdfWinTranslateDocJob* job);
void spdf_win_translate_doc_free(SpdfWinTranslateDocJob* job);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_TRANSLATE_H */
