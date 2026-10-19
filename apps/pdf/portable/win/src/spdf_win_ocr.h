/* spdf_win_ocr.h -- OCR for the Windows shell: the 19-language table, the
 * OCRmyPDF command line (one job per core, deskew, rotate, optimize 1, a
 * forced retry for image-only scans), the backup and temp-file naming, the
 * verdict that decides whether the output may replace the original, and the
 * worker that runs it all with a live log and a Cancel.
 *
 * A PORT of portable/linux/gtk4/spdf_ocr.{h,c} (707 lines). The pure half is
 * function-for-function the GTK one, with Windows paths; portable/win/tests/
 * ocr_test.c pins it with the same cases as tests/ocr_test.c there.
 *
 * WHAT IS DIFFERENT ON WINDOWS, and why:
 *
 *   - THE SWAP HAPPENS ON THE UI THREAD, AFTER THE DOCUMENT IS CLOSED. GTK
 *     renames the validated output over the original while the tab still
 *     holds the document open; POSIX allows that, Windows does not (MuPDF's
 *     fopen takes no FILE_SHARE_DELETE, so MoveFileEx over it fails with a
 *     sharing violation). So the worker ends with the VALIDATED OUTPUT still
 *     beside the original and reports it; the host then releases the tab's
 *     document, calls spdf_win_ocr_install_output(), and reopens. The rule
 *     "swap in only confirmed text" (journal item 37) is unchanged; only who
 *     performs the confirmed swap moved.
 *   - ocrmypdf finds tesseract and gs through PATH, and neither is on PATH
 *     here (spdf_win_toolchain.h). spdf_win_ocr_env() builds the child's PATH
 *     prefix and TESSDATA_PREFIX for downloaded language data.
 *   - Process success is still not document success: the output is opened
 *     with the core and spdf_document_has_text() decides, exactly as GTK.
 */
#ifndef SPDF_WIN_OCR_H
#define SPDF_WIN_OCR_H

#include <stddef.h>

#include "spdf_win_toolchain.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpdfWinOcrLanguage {
    const char* code;  /* Tesseract -l value, e.g. "chi_sim+eng" */
    const char* label; /* human-readable */
} SpdfWinOcrLanguage;

/* The 19 options, identical to GTK OCR_LANGUAGE_OPTIONS and the Mac table
 * (order included): the two Chinese scripts alone or with English first,
 * English, then the most-spoken and the large European languages. */
const SpdfWinOcrLanguage* spdf_win_ocr_languages(int* count);
int spdf_win_ocr_language_index(const char* code); /* -1 when unknown */

/* The OCRmyPDF command line:
 *   "<tool>" [-m ocrmypdf] --jobs <n> --rotate-pages --optimize 1 -l <language>
 *   [--deskew [--force-ocr]]   (no existing text; force on the retry)
 *   [--redo-ocr]               (existing text)
 *   "<input>" "<output>"
 * `tool` is ocrmypdf.exe, or python.exe with via_python set (the console
 * script is absent but the package is importable). jobs is clamped to >= 1. */
size_t spdf_win_ocr_command(const char* tool, int via_python, const char* language, unsigned jobs, int has_text,
                            int force_ocr, const char* input_path, const char* output_path, char* out,
                            size_t out_bytes);

/* Decision after an attempt (journal item 37):
 *   run_ok           process exited 0
 *   output_has_text  core verdict on the produced PDF (-1 error, 0 no, 1 yes)
 *   input_had_text   the source had a text layer (redo path)
 *   forced           this attempt already used --force-ocr */
typedef enum spdf_win_ocr_verdict {
    SPDF_WIN_OCR_SWAP,         /* install the output over the original */
    SPDF_WIN_OCR_RETRY_FORCE,  /* image-only PDF, no text produced: retry once forced */
    SPDF_WIN_OCR_FAIL_NO_TEXT, /* completed but no text; original left unchanged */
    SPDF_WIN_OCR_FAIL_ERROR    /* process failed (or validation errored) */
} spdf_win_ocr_verdict;
spdf_win_ocr_verdict spdf_win_ocr_validation_verdict(int run_ok, int output_has_text, int input_had_text, int forced);

/* Friendly failure text for OCRmyPDF output: --redo-ocr incompatibility and
 * Python tracebacks get dedicated explanations; anything else passes through,
 * truncated to fit. */
size_t spdf_win_ocr_failure_message(const char* detail, char* out, size_t out_bytes);

/* Backup name candidates: index 0 -> "<stem>_backup.<ext>", n ->
 * "<stem>_backup_<n+1>.<ext>" (GTK3 numbering: the second candidate is _2).
 * Both separators are accepted in `path`; the one before the leaf is kept. */
int spdf_win_ocr_backup_candidate(const char* path, int index, char* out, size_t out_bytes);

/* Same-directory temp file: ".<basename>.ocr-<nonce>.pdf". */
int spdf_win_ocr_temp_path(const char* path, unsigned nonce, char* out, size_t out_bytes);

/* The child's environment additions, as the NUL-separated, double-NUL-ended
 * block spdf_win_toolchain_run_capture() takes: "PATH=<tesseract dir>;<gs
 * dir>;<scripts dir>" from whichever are non-empty, then
 * "TESSDATA_PREFIX=<tessdata dir>" when a downloaded-data directory is given
 * (Tesseract 4+ wants the tessdata directory itself, not its parent). Returns
 * the block's length including the final NUL. */
size_t spdf_win_ocr_env(const char* tesseract_dir, const char* gs_dir, const char* scripts_dir,
                        const char* tessdata_dir, char* out, size_t out_bytes);

/* --- the worker (spdf_win_ocr.cpp, Win32 + core) ------------------------- */

typedef struct SpdfWinOcrJob SpdfWinOcrJob;

/* All three fire on the WORKER thread. on_done fires exactly once; after it,
 * the caller joins with spdf_win_ocr_free(). `output_path` on success is the
 * validated OCR result waiting beside the original for
 * spdf_win_ocr_install_output(); on failure or cancel it has been deleted. */
typedef struct SpdfWinOcrCallbacks {
    void* user;
    void (*on_line)(const char* utf8, void* user);
    void (*on_status)(const char* utf8, void* user);
    void (*on_done)(int success, int cancelled, const char* message, const char* output_path, void* user);
} SpdfWinOcrCallbacks;

typedef struct SpdfWinOcrRequest {
    const char* pdf_path; /* UTF-8 */
    const char* language;
    const char* language_label;
    int input_has_text; /* the redo path; a backup is written first */
    const SpdfWinToolchainState* tools;
    const SpdfWinToolchainRoots* roots;
} SpdfWinOcrRequest;

/* Copies the request, starts the thread. NULL when it could not start. */
SpdfWinOcrJob* spdf_win_ocr_start(const SpdfWinOcrRequest* request, const SpdfWinOcrCallbacks* callbacks);
void spdf_win_ocr_cancel(SpdfWinOcrJob* job);
/* Waits for the thread if it is still running, then frees. */
void spdf_win_ocr_free(SpdfWinOcrJob* job);

/* <stem>_backup.pdf beside the original (first free candidate), copied with
 * CopyFileW. Fills backup_out with the path written. */
int spdf_win_ocr_write_backup(const char* pdf_path, char* backup_out, size_t out_bytes, char* err, size_t err_len);

/* MoveFileExW REPLACE_EXISTING with a few retries for an antivirus hold. Call
 * with every handle on `pdf_path` closed. */
int spdf_win_ocr_install_output(const char* output_path, const char* pdf_path, char* err, size_t err_len);

/* Delete a leftover temp output; ignores a missing file. */
void spdf_win_ocr_discard(const char* output_path);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_OCR_H */
