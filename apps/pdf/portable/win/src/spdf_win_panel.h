/* spdf_win_panel.h -- the tool panel: one Win32 window for OCR, Translate
 * Selection and Translate Document, with the language picker, a status line,
 * a progress bar, a live copyable log, and Install / Cancel / Close.
 *
 * The GTK shell has three windows for this (the OCR language dialog, the
 * selection-translation window and the shared SpdfToolchainProgress window);
 * the Mac has its NSPanel and NSAlerts. Here it is ONE window with three
 * arrangements, because the flow is the same in every mode -- pick languages,
 * find the toolchain, install what is missing with a live log, run the job
 * with the same log -- and one window lets the reader see the install roll
 * straight into the OCR it was for, which is the readme's "resumes
 * automatically" promise made visible.
 *
 * WIN32 CONTROLS, NOT DIRECT2D. The rest of the chrome is custom-drawn so it
 * can be composed headlessly (spdf_win_d2d.h's rule). This panel is a modeless
 * secondary window with an EDIT control for the log -- a multiline EDIT gives
 * selection, Ctrl+C and Ctrl+A for free, which is exactly what "copyable log"
 * means -- and nothing on the paint path depends on it. It follows the app's
 * theme: DWMWA_USE_IMMERSIVE_DARK_MODE on its caption, DarkMode_Explorer /
 * DarkMode_CFD themes on the controls, and dark brushes for the statics and
 * edits, when the app is dark; the process already opted into dark menus
 * (spdf_win_enable_dark_menus).
 *
 * THREADS. Every job runs on a worker (spdf_win_ocr.h, spdf_win_translate.h,
 * spdf_win_toolchain.h) and reports through PostMessage to this window; the
 * host callbacks below fire on the UI thread, inside this window's procedure,
 * which is the same thread as the main window's -- so the host may touch the
 * tab model and the canvas directly.
 *
 * ONE PANEL PER PROCESS, because one process is one window (session.yaml's
 * window ids), and a second job while one runs is refused with a status line
 * rather than queued. */
#ifndef SPDF_WIN_PANEL_H
#define SPDF_WIN_PANEL_H

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum spdf_win_panel_mode {
    SPDF_WIN_PANEL_OCR = 1,
    SPDF_WIN_PANEL_TRANSLATE_SELECTION,
    SPDF_WIN_PANEL_TRANSLATE_DOCUMENT
} spdf_win_panel_mode;

/* What the panel asks of the app, all on the UI thread.
 *   ocr_finished    the validated OCR output sits at output_path beside
 *                   pdf_path; release every handle on pdf_path, call
 *                   spdf_win_ocr_install_output(), reopen. The panel reports
 *                   the swap's success from the return value.
 *   open_document   the translated copy is at path; open it in a new tab.
 *   busy_changed    a job or an install started (1) or ended (0): the toolbar
 *                   greys its two buttons from this. */
typedef struct SpdfWinPanelHost {
    void* user;
    int (*ocr_finished)(void* user, const char* pdf_path, const char* output_path, char* err, size_t err_len);
    void (*open_document)(void* user, const char* path);
    void (*busy_changed)(void* user, int busy);
} SpdfWinPanelHost;

typedef struct SpdfWinPanelRequest {
    spdf_win_panel_mode mode;
    HWND owner;           /* the main window; the panel is owned, not a child */
    int dark;             /* the app's current theme */
    const char* pdf_path; /* UTF-8; the current document (OCR, document translation) */
    const char* selection; /* UTF-8; the selected text (selection translation), may be NULL */
    int document_has_text; /* OCR: the source already has a text layer (backup + --redo-ocr) */
} SpdfWinPanelRequest;

/* Show (or re-target) the panel. Returns 1 when it is up. A running job keeps
 * the panel in its current mode and only brings it to the front. */
int spdf_win_panel_open(const SpdfWinPanelRequest* request, const SpdfWinPanelHost* host);

/* A job or an install is in flight. */
int spdf_win_panel_is_busy(void);

/* Retheme a live panel when the app toggles its theme. */
void spdf_win_panel_set_dark(int dark);

/* Destroy the panel if it exists; a running job is cancelled and joined. */
void spdf_win_panel_close(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PANEL_H */
