/* spdf_win_panel_internal.h -- the tool panel's state, shared by the window
 * half (spdf_win_panel.cpp: class, controls, layout, theme, messages) and the
 * flow half (spdf_win_panel_jobs.cpp: probe -> install -> run, per mode). Not
 * part of the port's public surface; spdf_win_panel.h is. */
#ifndef SPDF_WIN_PANEL_INTERNAL_H
#define SPDF_WIN_PANEL_INTERNAL_H

#include "spdf_win_panel.h"

#include "spdf_win_ocr.h"
#include "spdf_win_toolchain.h"
#include "spdf_win_translate.h"

/* Worker -> UI. lParam carries a malloc'd payload the handler frees. */
#define SPDF_WIN_PANEL_MSG_LINE (WM_APP + 1)     /* char* utf8 */
#define SPDF_WIN_PANEL_MSG_STATUS (WM_APP + 2)   /* char* utf8 */
#define SPDF_WIN_PANEL_MSG_PROGRESS (WM_APP + 3) /* wParam = permille, -1 = indeterminate */
#define SPDF_WIN_PANEL_MSG_JOB_DONE (WM_APP + 4) /* SpdfWinPanelResult* */
#define SPDF_WIN_PANEL_MSG_PROBED (WM_APP + 5)   /* nothing: p->tools is filled */
#define SPDF_WIN_PANEL_MSG_INSTALLED (WM_APP + 6) /* wParam = success */
#define SPDF_WIN_PANEL_MSG_TEXT_DONE (WM_APP + 7) /* SpdfWinPanelResult* (message = translation or error) */

typedef struct SpdfWinPanelResult {
    int success;
    int cancelled;
    char* message;     /* malloc'd */
    char* output_path; /* malloc'd, may be "" */
} SpdfWinPanelResult;

typedef enum spdf_win_panel_phase {
    SPDF_WIN_PANEL_IDLE = 0,
    SPDF_WIN_PANEL_PROBING,
    SPDF_WIN_PANEL_NEED_INSTALL,
    SPDF_WIN_PANEL_INSTALLING,
    SPDF_WIN_PANEL_RUNNING,
    SPDF_WIN_PANEL_DONE
} spdf_win_panel_phase;

typedef struct spdf_win_panel {
    HWND hwnd;
    HWND owner;
    HWND lang_label, lang_combo; /* OCR: the language; translate: From */
    HWND to_label, to_combo;
    HWND input_label, input_edit, output_label, output_edit; /* selection mode */
    HWND status, progress, log, copy_button, primary, cancel_button, close_button;
    HFONT font, mono;
    HBRUSH bg, field_bg;
    int dark;
    spdf_win_panel_mode mode;
    char pdf_path[SPDF_WIN_TC_PATH];
    char* selection; /* owned UTF-8 */
    int document_has_text;
    SpdfWinPanelHost host;

    /* flow state */
    spdf_win_panel_phase phase;
    HANDLE worker; /* the generic worker: probe, install, text translate */
    HANDLE cancel;
    SpdfWinOcrJob* ocr;
    SpdfWinTranslateDocJob* doc;
    SpdfWinToolchainRoots roots;
    SpdfWinToolchainState tools;
    SpdfWinToolchainPlan plan;
    char language[64];
    char language_label[96];
    char from_lang[32];
    char to_lang[32];
    int offered_package; /* the argospm offer is made once per run, as on the Mac */
    int with_package;    /* the pending install plan includes the language package */
    int close_when_done; /* the reader closed the window mid-job: cancel, then destroy */
} spdf_win_panel;

/* window half */
void spdf_win_panel_log(spdf_win_panel* p, const char* utf8);
void spdf_win_panel_set_status(spdf_win_panel* p, const char* utf8);
void spdf_win_panel_set_progress(spdf_win_panel* p, int permille); /* -1 = marquee */
void spdf_win_panel_set_buttons(spdf_win_panel* p, const wchar_t* primary_or_null, int cancel_enabled);
int spdf_win_panel_combo_code(spdf_win_panel* p, HWND combo, char* out, size_t out_bytes);
char* spdf_win_panel_input_text(spdf_win_panel* p); /* malloc'd UTF-8, trimmed */
void spdf_win_panel_set_output_text(spdf_win_panel* p, const char* utf8);
void spdf_win_panel_post_result(HWND hwnd, UINT msg, int success, int cancelled, const char* message,
                                const char* output_path);
void spdf_win_panel_post_text(HWND hwnd, UINT msg, const char* utf8);

/* flow half */
void spdf_win_panel_flow_begin(spdf_win_panel* p);      /* the panel was (re)targeted */
void spdf_win_panel_flow_primary(spdf_win_panel* p);    /* primary button */
void spdf_win_panel_flow_cancel(spdf_win_panel* p);     /* cancel button or close while running */
int spdf_win_panel_flow_message(spdf_win_panel* p, UINT msg, WPARAM wparam, LPARAM lparam);
void spdf_win_panel_flow_shutdown(spdf_win_panel* p);   /* join everything */
void spdf_win_panel_set_busy(spdf_win_panel* p, int busy);

#endif /* SPDF_WIN_PANEL_INTERNAL_H */
