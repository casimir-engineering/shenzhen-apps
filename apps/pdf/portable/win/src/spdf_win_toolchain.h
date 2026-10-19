/* spdf_win_toolchain.h -- the external toolchain the power tools stand on:
 * where Tesseract, Ghostscript, Python, OCRmyPDF and Argos Translate are on a
 * Windows machine, how to acquire the missing ones, and how to run any of them
 * with a live log and a Cancel button.
 *
 * A PORT of portable/linux/gtk4/spdf_toolchain.{h,c} (725 lines) with the
 * Linux package-manager table replaced by the Windows decision recorded in
 * portable/docs/windows-feature-matrix.md items 18/19:
 *
 *   native tools   winget      UB-Mannheim.TesseractOCR (installs to
 *                              %ProgramFiles%\Tesseract-OCR, NOT on PATH),
 *                              Python.Python.3.12 --scope user when no
 *                              python.exe resolves
 *   Ghostscript    detected only, never installed: OCRmyPDF 17 rasterises
 *                              with pypdfium2 and needs gs solely for PDF/A,
 *                              falling back to a plain PDF without it. The
 *                              winget catalogue here has no Ghostscript and
 *                              Artifex's installer has no silent mode (a
 *                              wizard behind UAC), so it is not worth asking
 *                              for; when it is present it goes on the child's
 *                              PATH (spdf_win_toolchain_install.cpp)
 *   ocrmypdf       pip --user  its console script lands in Python's per-user
 *                              Scripts directory, which is not on PATH either
 *   argostranslate pip, into a venv at %USERPROFILE%\.shenzhenpdf\argos. Not
 *                              --user: the first real run failed with
 *                              WinError 206 (path too long) unpacking torch's
 *                              dist-info under the Store Python's 120-character
 *                              user site-packages prefix, and a venv at a short
 *                              path also keeps the torch/ctranslate2 stack out
 *                              of the user's own site-packages; and not under
 *                              %LOCALAPPDATA%, see below
 *   language data  tessdata_fast (as Linux) into
 *                              %USERPROFILE%\.shenzhenpdf\tesseract\tessdata;
 *                              argospm install translate-<from>_<to> on demand
 *
 * WHY %USERPROFILE%\.shenzhenpdf AND NOT %LOCALAPPDATA%. The Store Python is a
 * packaged app, and every process it starts -- ocrmypdf, and the tesseract that
 * ocrmypdf starts -- runs in its package context, where AppData\Local is a
 * virtualised view: writes land in the package's LocalCache and a directory
 * deleted through that view stays invisible to it. Measured twice here: the
 * Argos venv was created where no other process could find it, and tesseract
 * launched by ocrmypdf could not open a traineddata file that plainly existed
 * and that the same tesseract opened from a shell. The profile root is not
 * virtualised, so everything this file downloads or creates goes there.
 *
 * TWO HALVES, ONE HEADER. Everything above the SPDF_WIN_TOOLCHAIN_RUN marker
 * is pure C: paths and PATH searches take the roots and an existence callback
 * as arguments, command lines are returned as strings, versions are parsed
 * from text. portable/win/tests/toolchain_test.c exercises all of it with no
 * network, no installer and no subprocess. Below the marker is the Win32
 * half -- probing the real machine and CreateProcess with pipes -- which the
 * same test drives against a fake tesseract.cmd it writes itself.
 *
 * NOTHING LEAVES THE MACHINE. The only outbound traffic any of this ever
 * makes is the installers' own downloads (winget's, pip's, argospm's, and the
 * tessdata_fast curl fetch); documents and their text go to local processes
 * over pipes and nowhere else. readme.md's "100% on-device" promise is a
 * property of this file: no function here takes a document.
 */
#ifndef SPDF_WIN_TOOLCHAIN_H
#define SPDF_WIN_TOOLCHAIN_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_WIN_TC_PATH 1024
#define SPDF_WIN_TC_CMD 4096
#define SPDF_WIN_TC_ENV 8192

/* --- what a machine may or may not have ---------------------------------- */

typedef enum spdf_win_tool {
    SPDF_WIN_TOOL_TESSERACT = 0,
    SPDF_WIN_TOOL_GHOSTSCRIPT,
    SPDF_WIN_TOOL_PYTHON,
    SPDF_WIN_TOOL_OCRMYPDF,
    SPDF_WIN_TOOL_ARGOS_TRANSLATE,
    SPDF_WIN_TOOL_ARGOSPM,
    SPDF_WIN_TOOL_WINGET,
    SPDF_WIN_TOOL_CURL,
    SPDF_WIN_TOOL_COUNT
} spdf_win_tool;

/* The executable's file name, e.g. "tesseract.exe". */
const char* spdf_win_tool_exe(spdf_win_tool tool);

/* The directories a search starts from. Filled by
 * spdf_win_toolchain_roots_from_env() on a real machine and by hand in tests.
 * `user_scripts` is Python's per-user console-script directory
 * (sysconfig.get_path('scripts', 'nt_user')); empty when Python is absent. */
typedef struct SpdfWinToolchainRoots {
    char program_files[SPDF_WIN_TC_PATH];
    char local_appdata[SPDF_WIN_TC_PATH];
    char user_profile[SPDF_WIN_TC_PATH]; /* %USERPROFILE%; the one root a packaged Python does not redirect */
    char system_root[SPDF_WIN_TC_PATH];
    char user_scripts[SPDF_WIN_TC_PATH];
    char path_env[SPDF_WIN_TC_ENV];
} SpdfWinToolchainRoots;

/* Where the tool is expected when it is NOT on PATH, most likely first. Paths
 * may end in a "*" component (Ghostscript's versioned "gs\gs10.07.1\bin"),
 * which the Win32 half expands with spdf_win_toolchain_glob_newest(). Returns
 * the number written; the ith candidate is out[i]. */
#define SPDF_WIN_TC_MAX_CANDIDATES 8
int spdf_win_toolchain_candidates(spdf_win_tool tool, const SpdfWinToolchainRoots* roots,
                                  char out[SPDF_WIN_TC_MAX_CANDIDATES][SPDF_WIN_TC_PATH]);

/* PATH lookup with the filesystem behind a callback, so a test can say which
 * files exist. Returns 1 and fills out with "<dir>\<exe>" for the first PATH
 * entry that has it. Empty entries and surrounding quotes are skipped, as the
 * shell skips them. */
typedef int (*spdf_win_toolchain_exists_fn)(const char* path, void* user);
int spdf_win_toolchain_search_path_env(const char* path_env, const char* exe, spdf_win_toolchain_exists_fn exists,
                                       void* user, char* out, size_t out_bytes);

/* Among directory names like "gs10.07.1", "gs9.56.1", the one with the highest
 * dotted version. Returns the index or -1. Pure; the Win32 glob feeds it. */
int spdf_win_toolchain_newest_version_index(const char* const* names, int count);

/* First "N.N[.N]" in a tool's --version output: "tesseract v5.4.0.20240606",
 * "Python 3.13.14", "GPL Ghostscript 10.07.1 (2025-..)". Returns 1 when found. */
int spdf_win_toolchain_parse_version(const char* text, int* major, int* minor, int* patch);

/* --- Tesseract language helpers (GTK names kept) -------------------------- */

/* "chi_sim+eng" -> ["chi_sim", "eng"]. Returns the count; at most 8 parts of
 * up to 31 bytes each. NULL or "" means "eng". */
int spdf_win_ocr_language_components(const char* language, char out[8][32]);
int spdf_win_ocr_language_uses_extra_traineddata(const char* language); /* any non-eng part */
/* `tesseract --list-langs` output names every component of `language`. */
int spdf_win_toolchain_list_output_has_language(const char* output, const char* language);

/* --- Argos helpers --------------------------------------------------------- */
int spdf_win_toolchain_is_argos_diagnostic_line(const char* line, int previous_line_was_diagnostic);
/* Drops the model-mismatch WARNING lines Argos prints on stdout. Writes into
 * out (NUL-terminated, truncated to fit); returns the byte length. */
size_t spdf_win_toolchain_strip_argos_diagnostics(const char* text, char* out, size_t out_bytes);
int spdf_win_toolchain_argos_failure_is_missing_package(const char* failure);
/* "translate-<from>_<to>"; returns 0 for an empty code. */
int spdf_win_toolchain_argos_package_name(const char* from_lang, const char* to_lang, char* out, size_t out_bytes);

/* --- command lines --------------------------------------------------------- */

/* One argument, quoted for CreateProcess/CommandLineToArgvW when it needs
 * it (spaces, tabs, quotes, or empty). Returns the length written. */
size_t spdf_win_toolchain_quote_arg(const char* arg, char* out, size_t out_bytes);
/* argv -> one command line, each argument through quote_arg. */
size_t spdf_win_toolchain_join_argv(const char* const* argv, int argc, char* out, size_t out_bytes);

#define SPDF_WIN_TC_WINGET_TESSERACT "UB-Mannheim.TesseractOCR"
#define SPDF_WIN_TC_WINGET_PYTHON "Python.Python.3.12"
#define SPDF_WIN_TC_TESSDATA_URL "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/"

/* "<winget>" install --id <id> -e --accept-source-agreements
 * --accept-package-agreements --disable-interactivity [--scope user] */
size_t spdf_win_toolchain_winget_cmd(const char* winget, const char* id, int user_scope, char* out, size_t out_bytes);
/* "<python>" -m pip install [--user] --upgrade --progress-bar off <packages...>
 * (--user for the user's Python; not inside a venv, where pip rejects it) */
size_t spdf_win_toolchain_pip_cmd(const char* python, int user_site, const char* const* packages, int count,
                                  char* out, size_t out_bytes);
/* "<python>" -m venv "<dir>" */
size_t spdf_win_toolchain_venv_cmd(const char* python, const char* dir, char* out, size_t out_bytes);
/* The Argos venv: %USERPROFILE%\.shenzhenpdf\argos, and its Scripts\python.exe. */
int spdf_win_toolchain_argos_env_dir(const SpdfWinToolchainRoots* roots, char* out, size_t out_bytes);
int spdf_win_toolchain_argos_env_python(const SpdfWinToolchainRoots* roots, char* out, size_t out_bytes);
/* "<curl>" -L -f -sS -o "<dest>" "<url>" */
size_t spdf_win_toolchain_curl_cmd(const char* curl, const char* url, const char* dest, char* out, size_t out_bytes);
/* "<argospm>" install translate-<from>_<to> */
size_t spdf_win_toolchain_argospm_cmd(const char* argospm, const char* from_lang, const char* to_lang, char* out,
                                      size_t out_bytes);
/* Where downloaded tessdata goes: %USERPROFILE%\.shenzhenpdf\tesseract. */
int spdf_win_toolchain_tessdata_parent(const SpdfWinToolchainRoots* roots, char* out, size_t out_bytes);

/* --- install plans --------------------------------------------------------- */

typedef enum spdf_win_tc_step_kind {
    SPDF_WIN_TC_STEP_WINGET = 1, /* command: the winget line */
    SPDF_WIN_TC_STEP_PIP,        /* command: the pip line; "python" re-resolved if it was just installed */
    SPDF_WIN_TC_STEP_VENV,       /* command: python -m venv; dest: the environment directory */
    SPDF_WIN_TC_STEP_TRAINEDDATA, /* command: the curl line; dest: the .traineddata path */
    SPDF_WIN_TC_STEP_ARGOSPM,     /* command: the argospm line */
    SPDF_WIN_TC_STEP_BLOCKED      /* nothing runnable: label says what the reader must do */
} spdf_win_tc_step_kind;

typedef struct SpdfWinToolchainStep {
    int kind;
    char label[160];
    char command[SPDF_WIN_TC_CMD];
    char dest[SPDF_WIN_TC_PATH];
} SpdfWinToolchainStep;

#define SPDF_WIN_TC_MAX_STEPS 16
typedef struct SpdfWinToolchainPlan {
    SpdfWinToolchainStep steps[SPDF_WIN_TC_MAX_STEPS];
    int count;
    int needs_elevation_note; /* an installer that may raise UAC is in the plan */
} SpdfWinToolchainPlan;

/* What probing found: the resolved path for each tool, or "" when absent. */
typedef struct SpdfWinToolchainState {
    char path[SPDF_WIN_TOOL_COUNT][SPDF_WIN_TC_PATH];
    /* Components of the OCR language tesseract does not list, "" when all are
     * present; filled by the caller from spdf_win_toolchain_missing_components. */
    char missing_languages[8][32];
    int missing_language_count;
} SpdfWinToolchainState;

int spdf_win_toolchain_has(const SpdfWinToolchainState* st, spdf_win_tool tool);

/* Everything OCR needs and does not have, in dependency order: Tesseract,
 * Python, ocrmypdf, then one traineddata download per missing component
 * (Ghostscript is optional and never planned; see the header comment). A tool
 * that cannot be acquired (no winget, no curl) becomes a BLOCKED step with the
 * reason, so the log says so instead of the plan being silently shorter. */
void spdf_win_toolchain_ocr_plan(const SpdfWinToolchainState* st, const SpdfWinToolchainRoots* roots,
                                 const char* language, SpdfWinToolchainPlan* plan);
/* Python, then the venv, then argostranslate into it; optionally the
 * translate-<from>_<to> package with the venv's argospm. */
void spdf_win_toolchain_argos_plan(const SpdfWinToolchainState* st, const SpdfWinToolchainRoots* roots,
                                   const char* from_lang, const char* to_lang, int with_package,
                                   SpdfWinToolchainPlan* plan);

/* --- the live log's line splitter ------------------------------------------ */

/* Bytes from a pipe -> lines. '\n' and a bare '\r' both end a line (winget and
 * pip redraw progress with '\r'; each redraw becomes a line rather than a
 * 30 KB blob), "\r\n" ends one, and VT escape sequences (colours, cursor
 * moves) are dropped so the EDIT control shows text and not "[?25l". */
typedef void (*spdf_win_toolchain_line_fn)(const char* line, void* user);
typedef struct SpdfWinLineSplitter {
    char buf[4096];
    int len;
    int esc; /* 0 none, 1 after ESC, 2 inside CSI, 3 inside OSC */
    int pending_cr;
} SpdfWinLineSplitter;
void spdf_win_line_splitter_init(SpdfWinLineSplitter* s);
void spdf_win_line_splitter_feed(SpdfWinLineSplitter* s, const char* bytes, size_t n, spdf_win_toolchain_line_fn cb,
                                 void* user);
void spdf_win_line_splitter_flush(SpdfWinLineSplitter* s, spdf_win_toolchain_line_fn cb, void* user);

/* --- settings.yaml's three keys, through the shared JSON text ------------- */

/* Minimal string-member get/set over a JSON object text, enough for
 * "ocrLanguage", "translateSourceLanguage" and "translateTargetLanguage"
 * (spdf_state_internal.h:80-87) without pulling a parser into this module.
 * set writes the whole updated object into out; a NULL/empty json starts one. */
int spdf_win_toolchain_json_get_string(const char* json, const char* key, char* out, size_t out_bytes);
int spdf_win_toolchain_json_set_string(const char* json, const char* key, const char* value, char* out,
                                       size_t out_bytes);

/* ==========================================================================
 * SPDF_WIN_TOOLCHAIN_RUN -- the Win32 half (spdf_win_toolchain_run.cpp).
 * ======================================================================= */

/* ProgramFiles, LOCALAPPDATA, SystemRoot and PATH from the environment, plus
 * Python's per-user Scripts directory, which costs one `python -c` and is
 * therefore resolved once per process. */
void spdf_win_toolchain_roots_from_env(SpdfWinToolchainRoots* roots);

/* Resolve one tool: PATH first, then the candidates, expanding "*" components
 * to the newest matching directory. Tesseract additionally consults
 * HKLM\SOFTWARE\Tesseract-OCR. Returns 1 and fills out, or 0. */
int spdf_win_toolchain_find(spdf_win_tool tool, const SpdfWinToolchainRoots* roots, char* out, size_t out_bytes);
/* All of them at once, plus the OCR language's missing components. */
void spdf_win_toolchain_probe(const SpdfWinToolchainRoots* roots, const char* ocr_language,
                              SpdfWinToolchainState* st);

/* Every component of `language` that tesseract --list-langs does not print
 * and that <tessdata parent>\tessdata\<lang>.traineddata does not supply.
 * `tesseract` may be "" (then every component is missing). */
int spdf_win_toolchain_missing_components(const char* tesseract, const char* tessdata_parent, const char* language,
                                          char out[8][32]);
/* The parent to hand tesseract as TESSDATA_PREFIX when it covers the
 * language's downloaded components, else 0. */
int spdf_win_toolchain_tessdata_parent_for_language(const SpdfWinToolchainRoots* roots, const char* language,
                                                    char* out, size_t out_bytes);

/* Make the downloaded-data directory usable as TESSDATA_PREFIX. That variable
 * REPLACES tesseract's search path rather than extending it, so once one
 * component lives in our directory every other component of the language --
 * and osd, which --rotate-pages needs -- must be there too; the ones tesseract
 * ships (eng, osd under <tesseract dir>\tessdata) are copied in. Returns 1
 * with the parent in `out` when our directory is needed and complete, 0 when
 * it is not needed (tesseract has everything) or cannot be completed. Learned
 * from the first panel run: chi_sim downloaded, prefix withheld because eng
 * was not beside it, and OCRmyPDF reported chi_sim missing. */
int spdf_win_toolchain_tessdata_complete(const SpdfWinToolchainRoots* roots, const char* tesseract_exe,
                                         const char* language, char* out, size_t out_bytes);

/* Directory of a resolved tool path ("C:\x\bin\gswin64c.exe" -> "C:\x\bin"). */
int spdf_win_toolchain_dirname(const char* path, char* out, size_t out_bytes);

/* THE SUBPROCESS SEAM. One child, stdout and stderr captured, cancellable.
 *
 *   command_line   as for CreateProcessW; use the *_cmd builders above
 *   env_prepend    extra "NAME=value" pairs, NUL-separated, double-NUL ended,
 *                  or NULL; PATH= entries are PREPENDED to the inherited PATH
 *                  (how tesseract's and gs's directories reach ocrmypdf)
 *   stdin_text     written to the child's stdin then closed, or NULL
 *   cancel         an event HANDLE (void*) or NULL; when signalled the whole
 *                  process tree is killed (a job object with
 *                  KILL_ON_JOB_CLOSE, so ocrmypdf's tesseract children die
 *                  with it) and the call returns SPDF_WIN_TC_CANCELLED
 *   on_line        called on the CALLING thread for each line of stdout
 *                  (and stderr, when merge_stderr) as it arrives
 *   stdout_out     malloc'd UTF-8 of all stdout, or NULL; caller free()s
 *   stderr_out     likewise for stderr when not merged
 *
 * Returns the exit code, or one of the negative codes below. Output is
 * treated as UTF-8: PYTHONUTF8=1 and PYTHONIOENCODING=utf-8 are always set so
 * Python's console scripts comply; tesseract and gs already do. */
#define SPDF_WIN_TC_CANCELLED (-1)
#define SPDF_WIN_TC_SPAWN_FAILED (-2)
typedef struct SpdfWinToolchainRun {
    const char* command_line;
    const char* env_prepend;
    const char* stdin_text;
    void* cancel;
    int merge_stderr;
    spdf_win_toolchain_line_fn on_line;
    void* user;
    char** stdout_out;
    char** stderr_out;
    char error[256]; /* filled on SPDF_WIN_TC_SPAWN_FAILED */
} SpdfWinToolchainRun;
int spdf_win_toolchain_run_capture(SpdfWinToolchainRun* run);

/* One job per core: the number of logical processors, at least 1. */
unsigned spdf_win_toolchain_cpu_count(void);

/* Run one plan step to completion, streaming its output. Returns 1 on
 * success. */
int spdf_win_toolchain_run_step(const SpdfWinToolchainStep* step, const SpdfWinToolchainRoots* roots, void* cancel,
                                spdf_win_toolchain_line_fn on_line, void* user);

/* settings.yaml, through spdf_win_state: read a string key (0 when absent) /
 * write one, refusing to overwrite an unreadable file as the state layer
 * requires. */
int spdf_win_toolchain_setting_get(const char* key, char* out, size_t out_bytes);
int spdf_win_toolchain_setting_set(const char* key, const char* value);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_TOOLCHAIN_H */
