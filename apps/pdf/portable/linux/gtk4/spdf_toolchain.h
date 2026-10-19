// spdf_toolchain.c — shared external-toolchain infrastructure for the OCR and
// translation modules (Wave C): package-manager command table, install-script
// assembly (apt/dnf/pacman/zypper via pkexec, ported from the GTK3
// ocr_install_script/translate_install_script), Tesseract/Argos language
// helpers, the streaming subprocess seam, and the shared progress window
// (pulse/fraction progress bar + live copyable GtkTextView log + optional
// Cancel).
//
// GTK3 provenance (portable/linux/ShenzhenPDFGtk.c):
//   ocr_install_script (@7457), translate_install_script (@8573),
//   ocr_language_components/_uses_extra_traineddata/_shell_list (@7184),
//   custom_tessdata_parent_path (@7208), tessdata_parent_has_language (@7212),
//   list_output_has_ocr_language (@7227), tesseract_has_ocr_language (@7248),
//   is_argos_diagnostic_line / strip_argos_diagnostic_lines (@7971/@7985),
//   subprocess_capture_utf8_with_cancel (@7931), install_ocr_then_run /
//   install_translate_then_run progress dialogs (@7600/@8666). The
//   missing-Argos-package classifier and "translate-<from>_<to>" package name
//   are ports of the Mac post-freeze flow (runArgosPackageInstall*,
//   "is not an installed language" / "No package" detection).
//
// Subprocess seam: every external binary is resolved with
// spdf_toolchain_find_tool() (a $PATH lookup), and both spawn entry points
// take a ready argv — so the whole flow can be exercised against shell-script
// fixtures by putting a directory with fake ocrmypdf/tesseract/argos-translate
// binaries in front of $PATH. Nothing in this module hard-codes binary paths.
#pragma once

#ifndef SPDF_TOOLCHAIN_TESTING
#include "spdf_internal.h"
#else
#include <glib.h>
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Pure logic (glib string logic only — no GTK, no probing), exercised by
// tests/toolchain_test.c.

// Package managers the installer scripts can drive, in the order the GTK3
// scripts probed them (`command -v`).
typedef enum {
    SPDF_PKG_APT = 0,
    SPDF_PKG_DNF,
    SPDF_PKG_PACMAN,
    SPDF_PKG_ZYPPER,
    SPDF_PKG_MANAGER_COUNT
} SpdfPackageManager;

// The `command -v` probe name for a package manager ("apt-get", "dnf", ...).
const char* spdf_toolchain_pm_probe(SpdfPackageManager pm);

// Distro package names, per manager (GTK3 table):
//   OCR tools:        apt "ocrmypdf tesseract-ocr" / dnf "ocrmypdf tesseract"
//                     / pacman "ocrmypdf tesseract" / zypper "ocrmypdf tesseract-ocr"
//   Chinese packs:    apt "tesseract-ocr-chi-sim tesseract-ocr-chi-tra" ...
//   Argos Translate:  "argos-translate" everywhere
const char* spdf_toolchain_ocr_tool_packages(SpdfPackageManager pm);
const char* spdf_toolchain_chinese_traineddata_packages(SpdfPackageManager pm);
const char* spdf_toolchain_argos_packages(SpdfPackageManager pm);

// The full elevated install command for packages under a manager, e.g.
// "pkexec /bin/sh -c 'apt-get update && apt-get install -y ocrmypdf
// tesseract-ocr'" — exactly the commands the GTK3 scripts ran. Caller frees.
char* spdf_toolchain_pm_install_command(SpdfPackageManager pm, const char* packages);

// Install-plan assembly: which script phases a given toolchain state needs.
typedef struct {
    gboolean install_tools;          // ocrmypdf or tesseract missing
    gboolean install_chinese_packs;  // language uses non-eng traineddata
    gboolean download_traineddata;   // per-language tessdata_fast fallback
} SpdfOcrInstallPlan;
void spdf_toolchain_ocr_install_plan(gboolean have_ocrmypdf,
                                     gboolean have_tesseract,
                                     gboolean language_ready,
                                     const char* language,
                                     SpdfOcrInstallPlan* plan);

// Shell script that installs OCRmyPDF + Tesseract + the traineddata for
// `language` (runtime package-manager dispatch, tessdata_fast download
// fallback into $XDG_DATA_HOME/shenzhenpdf/tesseract/tessdata). Port of the
// GTK3 ocr_install_script; the per-manager commands are generated from the
// table above. Caller frees.
char* spdf_toolchain_ocr_install_script(const char* language);

// Shell script that installs Argos Translate (distro package first, pip
// --user fallback). Port of the GTK3 translate_install_script. Caller frees.
char* spdf_toolchain_argos_install_script(void);

// --- Tesseract language helpers (GTK3 names kept) ---------------------------
char** spdf_ocr_language_components(const char* language);        // "chi_sim+eng" -> strv
gboolean spdf_ocr_language_uses_extra_traineddata(const char* language); // any non-eng part
char* spdf_ocr_language_shell_list(const char* language);         // "chi_sim eng"
// `tesseract --list-langs` output contains every component of language.
gboolean spdf_toolchain_list_output_has_language(const char* output, const char* language);

// --- Argos helpers -----------------------------------------------------------
// Model-mismatch diagnostics Argos prints on stdout (WARNING: Language ...
// package ... expects ...) that must not leak into translated output.
gboolean spdf_toolchain_is_argos_diagnostic_line(const char* line, gboolean previous_line_was_diagnostic);
char* spdf_toolchain_strip_argos_diagnostics(const char* text); // caller frees
// Mac-parity classifier: only missing-language-package failures may be
// answered with an argospm install prompt; real errors must surface.
gboolean spdf_toolchain_argos_failure_is_missing_package(const char* failure);
// argospm package name for a pair: "translate-<from>_<to>". Caller frees.
char* spdf_toolchain_argos_package_name(const char* from_lang, const char* to_lang);

#ifndef SPDF_TOOLCHAIN_TESTING

// ---------------------------------------------------------------------------
// Probing + subprocess seam (GTK only from here on).

// $PATH lookup (g_find_program_in_path). Caller frees. The single seam through
// which ocrmypdf / tesseract / argos-translate / argospm / pdftotext / mutool
// are located; prepend a fixture directory to $PATH to fake any of them.
char* spdf_toolchain_find_tool(const char* name);

// Where Shenzhen PDF keeps self-downloaded traineddata
// ($XDG_DATA_HOME/shenzhenpdf/tesseract). Caller frees.
char* spdf_toolchain_custom_tessdata_parent(void);
// parent/tessdata/<component>.traineddata exists for every component.
gboolean spdf_toolchain_tessdata_parent_has_language(const char* parent, const char* language);
// tesseract --list-langs (or the custom tessdata dir) covers the language.
gboolean spdf_toolchain_tesseract_has_language(const char* language);
// The custom parent when it covers the language (for TESSDATA_PREFIX), else NULL.
char* spdf_toolchain_tessdata_parent_for_language(const char* language);

// Blocking subprocess capture with cancellation (worker threads; GTK3
// subprocess_capture_utf8_with_cancel). Cancelling force-exits the child.
// Returns TRUE only on a zero exit status.
gboolean spdf_toolchain_run_capture(const char* const* argv,
                                    const char* const* envp, // NULL = inherit
                                    const char* stdin_text,  // NULL = no stdin pipe
                                    GCancellable* cancellable,
                                    char** stdout_out,
                                    char** stderr_out,
                                    GError** error);

// Fully async spawn on the main loop with live line streaming (stderr merged
// into stdout). on_line fires per output line, on_exit exactly once — both on
// the main thread. Cancelling force-exits the child (on_exit still fires,
// with success=FALSE and a G_IO_ERROR_CANCELLED-shaped collected tail).
typedef void (*SpdfToolchainLineFunc)(const char* line, gpointer user_data);
typedef void (*SpdfToolchainExitFunc)(gboolean success, const char* collected_output, gpointer user_data);
gboolean spdf_toolchain_spawn_streaming(const char* const* argv,
                                        const char* const* envp,
                                        GCancellable* cancellable,
                                        SpdfToolchainLineFunc on_line,
                                        SpdfToolchainExitFunc on_exit,
                                        gpointer user_data,
                                        GError** error);

// ---------------------------------------------------------------------------
// Shared progress window: heading, progress bar (pulses until a fraction is
// set), live monospace log (selectable/copyable), optional Cancel button.
// Main-thread only; workers queue idles holding a ref. Closing is blocked
// while running (GTK3 block_dialog_delete) and allowed after finish().
typedef struct _SpdfToolchainProgress SpdfToolchainProgress;

SpdfToolchainProgress* spdf_toolchain_progress_new(GtkWindow* parent,
                                                   const char* title,
                                                   const char* heading,
                                                   GCancellable* cancellable); // NULL = no Cancel button
SpdfToolchainProgress* spdf_toolchain_progress_ref(SpdfToolchainProgress* p);
void spdf_toolchain_progress_unref(SpdfToolchainProgress* p);
void spdf_toolchain_progress_append_log(SpdfToolchainProgress* p, const char* text);
void spdf_toolchain_progress_set_message(SpdfToolchainProgress* p, const char* message);
void spdf_toolchain_progress_set_fraction(SpdfToolchainProgress* p, double fraction); // stops pulsing
// Ends the running state: full/empty bar, final message appended to the log,
// window becomes closable (and gains a Close button).
void spdf_toolchain_progress_finish(SpdfToolchainProgress* p, gboolean success, const char* message);
void spdf_toolchain_progress_close(SpdfToolchainProgress* p); // destroy the window now

// Convenience: run /bin/sh -c script with output streamed into a new progress
// window; done(success, collected_output, user_data) fires on the main thread.
// On success the window closes itself; on failure it stays open with the log
// (GTK3 behavior) — done may still present its own UI.
typedef void (*SpdfToolchainScriptDone)(gboolean success, const char* output, gpointer user_data);
void spdf_toolchain_run_install_script(GtkWindow* parent,
                                       const char* title,
                                       const char* heading,
                                       const char* initial_log,
                                       const char* script,
                                       SpdfToolchainScriptDone done,
                                       gpointer user_data);

#endif // SPDF_TOOLCHAIN_TESTING

G_END_DECLS
