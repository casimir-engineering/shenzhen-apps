/* spdf_win_print_dialog_choose.cpp — WHICH DIALOG IS ASKED, IN WHAT ORDER, AND
 * WHAT IS REMEMBERED. The two dialogs themselves are
 * spdf_win_print_dialog_system.cpp (Windows', watchdogged) and
 * spdf_win_print_dialog.cpp (the port's own); the job both of them end in is
 * spdf_win_print.cpp. This file is only the choosing, and the reasoning behind
 * the order is spdf_win_print_dialog.h.
 *
 * SEPARATE FROM spdf_win_print.cpp SO THE JOB STAYS CHEAP TO LINK. Deciding
 * which dialog to show needs settings.yaml -- for the remembered printer and
 * the theme -- which needs the state file shell, the YAML codec, the recents
 * store and the watcher. Printing ONE PAGE ONTO A DC needs none of that, and
 * portable/win/tests/light_theme_test.c and print_e2e_test.c both link
 * spdf_win_print.cpp for exactly that. Keeping the orchestration here keeps
 * their link lines as short as the thing they test, which is also how the
 * dependency was noticed: moving it into the job file broke light_theme_test's
 * build and nothing else.
 *
 * spdf_win_print_document(), spdf_win_print_document_ex() and
 * spdf_win_print_document_for_view() are DECLARED in spdf_win_print.h, beside
 * the job they drive and where the shell already looks for them, and DEFINED
 * here.
 */

#include "spdf_win_print.h"

#include "spdf_win_export.h"       /* spdf_win_export_utf8_path, spdf_win_export_file_name */
#include "spdf_win_open.h"         /* the job's own document handle */
#include "spdf_win_print_dialog.h" /* the two dialogs */
#include "spdf_win_settings.h"     /* printerName, and the theme the fallback wears */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "advapi32.lib") /* RegGetValueW, for print_prefers_dark() */

spdf_win_print_status spdf_win_print_document(HWND parent, spdf_document* doc, const wchar_t* doc_path,
                                              spdf_win_print_scaling_mode mode, double custom_scale, char* err,
                                              size_t err_len) {
    spdf_win_print_choice choice;
    choice.mode = mode;
    choice.custom_scale = custom_scale;
    return spdf_win_print_document_ex(parent, doc, doc_path, &choice, err, err_len);
}

/* --- WHICH DIALOG, AND WHAT THE FALLBACK WEARS ---------------------------- */

/* The app's own dark/light verdict, for a dialog that has to match the window
 * it came out of: settings.yaml when the reader has expressed a preference, the
 * system otherwise -- exactly the line spdf_win_session_app.h:196 uses to theme
 * the window itself.
 *
 * THE REGISTRY READ IS DUPLICATED, AND KNOWINGLY. The original is
 * spdf_win_system_prefers_dark(), which lives in spdf_win_window_frame.h -- a
 * header included by spdf_win_window.cpp alone. Reaching it from here would
 * drag the whole window layer (Direct2D, the canvas, the tab strip) into every
 * test binary that wants to print. Six lines and a pointer to the original is
 * the cheaper honesty. */
static int print_prefers_dark(void) {
    spdf_win_settings* s = spdf_win_settings_shared();
    DWORD light = 1;
    DWORD size = sizeof(light);
    if (s->theme == SPDF_WIN_THEME_DARK) return 1;
    if (s->theme == SPDF_WIN_THEME_LIGHT) return 0;
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &light, &size) != ERROR_SUCCESS)
        return 0;
    return light ? 0 : 1;
}

/* The job's own document handle; see spdf_win_print.h. A failure here is not
 * fatal -- it means the job shares the caller's handle, which is safe because
 * the job runs on this thread either way. */
static spdf_document* print_own_document(const wchar_t* doc_path) {
    char utf8[MAX_PATH * 4];
    char open_err[512] = "";
    if (!doc_path || !spdf_win_export_utf8_path(doc_path, utf8, (int)sizeof(utf8))) return NULL;
    return spdf_win_open_document(utf8, open_err, sizeof(open_err));
}

static const wchar_t* print_job_name(const wchar_t* doc_path) {
    return (doc_path && *doc_path) ? spdf_win_export_file_name(doc_path) : L"Shenzhen PDF";
}

spdf_win_print_status spdf_win_print_document_ex(HWND parent, spdf_document* doc, const wchar_t* doc_path,
                                                 spdf_win_print_choice* choice, char* err, size_t err_len) {
    return spdf_win_print_document_for_view(parent, doc, doc_path, choice, -1, err, err_len);
}

spdf_win_print_status spdf_win_print_document_for_view(HWND parent, spdf_document* doc, const wchar_t* doc_path,
                                                       spdf_win_print_choice* choice, int current_page, char* err,
                                                       size_t err_len) {
    spdf_win_print_choice fallback;
    spdf_win_print_system_result sys;
    spdf_win_print_request req;
    spdf_win_settings* settings;
    spdf_document* own_doc;
    spdf_document* job_doc;
    spdf_win_print_status status;
    char preview_path[MAX_PATH * 4];
    int page_count;

    if (err && err_len) err[0] = '\0';
    if (!doc) return SPDF_WIN_PRINT_NO_DOCUMENT;
    if (!choice) {
        fallback.mode = SPDF_WIN_PRINT_SCALING_FIT;
        fallback.custom_scale = 1.0;
        choice = &fallback;
    }
    choice->custom_scale = spdf_win_print_clamp_custom_scale(choice->custom_scale);
    if (!spdf_win_print_allowed(doc)) {
        /* macOS's sentence, verbatim (ShenzhenPDFMac.mm:15574). */
        if (err && err_len)
            _snprintf_s(err, err_len, _TRUNCATE,
                        "Printing is not allowed. This PDF's permissions do not allow printing.");
        return SPDF_WIN_PRINT_NOT_PERMITTED;
    }
    page_count = spdf_page_count(doc);
    if (page_count <= 0) return SPDF_WIN_PRINT_NO_DOCUMENT;

    /* RUNG ONE: WINDOWS' OWN DIALOG, watchdogged. It comes back one way or
     * another -- that is the whole point of spdf_win_print_dialog.h -- and on a
     * host where it works this is the only rung the reader ever sees. */
    status = spdf_win_print_system_dialog(parent, page_count, choice, &sys, err, err_len);
    if (status == SPDF_WIN_PRINT_CANCELLED) return SPDF_WIN_PRINT_CANCELLED;
    if (status == SPDF_WIN_PRINT_OK) {
        *choice = sys.choice;
        own_doc = print_own_document(doc_path);
        job_doc = own_doc ? own_doc : doc;
        status = spdf_win_print_run_job(sys.dc, job_doc, print_job_name(doc_path), NULL, sys.pages, sys.page_count,
                                        sys.copies, choice->mode, choice->custom_scale, err, err_len);
        if (own_doc) spdf_close(own_doc);
        free(sys.pages);
        DeleteDC(sys.dc);
        return status;
    }
    if (status != SPDF_WIN_PRINT_NO_DIALOG) return status;

    /* RUNG TWO: OURS. Whatever the system dialog left in `err` diagnoses
     * WINDOWS, not this print: the reader is about to be handed a working
     * dialog, and a message box about the one that failed in front of it would
     * be noise. It is replaced by one line inside the dialog, which is where a
     * reader looking at an unfamiliar print window will actually read it. */
    if (err && err_len) err[0] = '\0';
    memset(&req, 0, sizeof(req));
    settings = spdf_win_settings_shared();
    if (settings->printer_name[0])
        MultiByteToWideChar(CP_UTF8, 0, settings->printer_name, -1, req.printer, SPDF_WIN_PRINT_NAME_MAX);
    req.range = SPDF_WIN_PRINT_RANGE_ALL;
    req.copies = 1;
    req.choice = *choice;
    /* THE PREVIEW'S PATH, in UTF-8 because that is what the render service and
     * the core take. Its workers open it for themselves; `doc` below is the
     * caller's handle and the dialog only measures pages with it, on this
     * thread. An unconvertible path leaves the preview showing the sheet and
     * the placement with no page bitmap, which is still true. */
    preview_path[0] = '\0';
    if (doc_path) spdf_win_export_utf8_path(doc_path, preview_path, (int)sizeof(preview_path));
    if (!spdf_win_print_dialog_show(parent, print_prefers_dark(), print_job_name(doc_path), page_count, current_page,
                                    spdf_win_print_system_dialog_abandoned()
                                        ? "Windows' own print dialog did not open on this computer, so this is "
                                          "Shenzhen PDF's."
                                        : NULL,
                                    doc, preview_path, &req, err, err_len)) {
        spdf_win_print_request_free(&req);
        /* A sentence means no window could be made at all; silence means the
         * reader pressed Cancel, which is not a failure and says nothing. */
        return (err && err[0]) ? SPDF_WIN_PRINT_NO_DIALOG : SPDF_WIN_PRINT_CANCELLED;
    }
    *choice = req.choice;
    /* THE PRINTER IS REMEMBERED HERE, not by the caller: the scaling is already
     * the shell's business because the menu handler reads it out of settings to
     * begin with, and nothing else in the app has any use for a printer name. */
    {
        char utf8[SPDF_WIN_SETTINGS_PRINTER_MAX];
        if (WideCharToMultiByte(CP_UTF8, 0, req.printer, -1, utf8, (int)sizeof(utf8), NULL, NULL) > 0 &&
            strcmp(utf8, settings->printer_name) != 0) {
            strncpy_s(settings->printer_name, sizeof(settings->printer_name), utf8, _TRUNCATE);
            spdf_win_settings_commit();
        }
    }
    own_doc = print_own_document(doc_path);
    job_doc = own_doc ? own_doc : doc;
    status = spdf_win_print_dialog_run(&req, job_doc, print_job_name(doc_path), page_count, current_page, err,
                                      err_len);
    if (own_doc) spdf_close(own_doc);
    spdf_win_print_request_free(&req);
    return status;
}
