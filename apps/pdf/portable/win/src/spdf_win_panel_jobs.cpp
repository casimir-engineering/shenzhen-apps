/* spdf_win_panel_jobs.cpp -- the FLOW half of the tool panel: for each mode,
 * probe the toolchain, offer and run the install plan with the live log, then
 * run the job and hand the result to the host. The same three steps whichever
 * button opened the panel, which is what lets an install roll straight into
 * the OCR or translation it was for (readme: "resumes automatically").
 *
 * Every worker below reports with PostMessage; spdf_win_panel_flow_message()
 * is the UI-thread half of each of them. Ported from the GTK flows in
 * spdf_ocr.c (ocr_start_for_language / ocr_install_done / ocr_exit_cb) and
 * spdf_translate.c (selection_panel_run / translate_doc_finished and the
 * argospm resume), with the Mac rule that only a missing-language-package
 * failure may be answered with an argospm offer. */
#include "spdf_win_panel_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- phases and the busy flag ------------------------------------------------ */

static int phase_busy(spdf_win_panel_phase ph) {
    return ph == SPDF_WIN_PANEL_PROBING || ph == SPDF_WIN_PANEL_INSTALLING || ph == SPDF_WIN_PANEL_RUNNING;
}

static void set_phase(spdf_win_panel* p, spdf_win_panel_phase ph) {
    int was = phase_busy(p->phase), now = phase_busy(ph);
    p->phase = ph;
    if (was != now) spdf_win_panel_set_busy(p, now);
}

static const wchar_t* primary_label(const spdf_win_panel* p) {
    return p->mode == SPDF_WIN_PANEL_OCR ? L"Run OCR" : L"Translate";
}

static void join_worker(spdf_win_panel* p) {
    if (p->worker) {
        WaitForSingleObject(p->worker, INFINITE);
        CloseHandle(p->worker);
        p->worker = NULL;
    }
}

static int start_worker(spdf_win_panel* p, LPTHREAD_START_ROUTINE fn) {
    join_worker(p);
    if (!p->cancel) p->cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
    ResetEvent(p->cancel);
    p->worker = CreateThread(NULL, 0, fn, p, 0, NULL);
    return p->worker != NULL;
}

static void post_line(const char* line, void* user) {
    spdf_win_panel* p = (spdf_win_panel*)user;
    spdf_win_panel_post_text(p->hwnd, SPDF_WIN_PANEL_MSG_LINE, line);
}

/* --- workers ------------------------------------------------------------------- */

static DWORD WINAPI probe_thread(LPVOID param) {
    spdf_win_panel* p = (spdf_win_panel*)param;
    spdf_win_toolchain_roots_from_env(&p->roots);
    spdf_win_toolchain_probe(&p->roots, p->mode == SPDF_WIN_PANEL_OCR ? p->language : NULL, &p->tools);
    PostMessageW(p->hwnd, SPDF_WIN_PANEL_MSG_PROBED, 0, 0);
    return 0;
}

static DWORD WINAPI install_thread(LPVOID param) {
    spdf_win_panel* p = (spdf_win_panel*)param;
    int ok = 1;
    for (int i = 0; i < p->plan.count && ok; ++i) {
        if (WaitForSingleObject(p->cancel, 0) == WAIT_OBJECT_0) {
            ok = 0;
            break;
        }
        ok = spdf_win_toolchain_run_step(&p->plan.steps[i], &p->roots, p->cancel, post_line, p);
    }
    PostMessageW(p->hwnd, SPDF_WIN_PANEL_MSG_INSTALLED, (WPARAM)ok, 0);
    return 0;
}

static DWORD WINAPI text_thread(LPVOID param) {
    spdf_win_panel* p = (spdf_win_panel*)param;
    char err[2048] = "";
    char* out = NULL;
    int rc = spdf_win_translate_text(p->tools.path[SPDF_WIN_TOOL_ARGOS_TRANSLATE], p->roots.user_scripts, p->from_lang,
                                     p->to_lang, p->selection ? p->selection : "", p->cancel, &out, err, sizeof(err));
    spdf_win_panel_post_result(p->hwnd, SPDF_WIN_PANEL_MSG_TEXT_DONE, rc > 0, rc < 0, rc > 0 ? out : err, "");
    free(out);
    return 0;
}

/* OCR and document-translation callbacks: the jobs have their own threads. */
static void job_line(const char* utf8, void* user) { post_line(utf8, user); }
static void job_status(const char* utf8, void* user) {
    spdf_win_panel* p = (spdf_win_panel*)user;
    spdf_win_panel_post_text(p->hwnd, SPDF_WIN_PANEL_MSG_STATUS, utf8);
}
static void job_progress(double fraction, const char* message, void* user) {
    spdf_win_panel* p = (spdf_win_panel*)user;
    PostMessageW(p->hwnd, SPDF_WIN_PANEL_MSG_PROGRESS, (WPARAM)(fraction * 1000.0), 0);
    if (message) spdf_win_panel_post_text(p->hwnd, SPDF_WIN_PANEL_MSG_STATUS, message);
}
static void job_done(int success, int cancelled, const char* message, const char* output, void* user) {
    spdf_win_panel* p = (spdf_win_panel*)user;
    spdf_win_panel_post_result(p->hwnd, SPDF_WIN_PANEL_MSG_JOB_DONE, success, cancelled, message, output);
}

/* --- starting things ------------------------------------------------------------- */

static void begin_probe(spdf_win_panel* p) {
    set_phase(p, SPDF_WIN_PANEL_PROBING);
    spdf_win_panel_set_status(p, "Looking for the toolchain...");
    spdf_win_panel_set_progress(p, -1);
    spdf_win_panel_set_buttons(p, NULL, 1);
    if (!start_worker(p, probe_thread)) {
        set_phase(p, SPDF_WIN_PANEL_DONE);
        spdf_win_panel_set_status(p, "Could not start a worker thread.");
        spdf_win_panel_set_buttons(p, primary_label(p), 0);
    }
}

static void begin_install(spdf_win_panel* p) {
    set_phase(p, SPDF_WIN_PANEL_INSTALLING);
    spdf_win_panel_set_status(p, "Installing...");
    spdf_win_panel_set_progress(p, -1);
    spdf_win_panel_set_buttons(p, NULL, 1);
    spdf_win_panel_log(p, "Everything installs for this user from official sources; no document leaves the machine.");
    if (p->plan.needs_elevation_note)
        spdf_win_panel_log(p, "A machine-wide installer is in the plan: Windows may show a consent prompt.");
    if (!start_worker(p, install_thread)) PostMessageW(p->hwnd, SPDF_WIN_PANEL_MSG_INSTALLED, 0, 0);
}

static void offer_install(spdf_win_panel* p) {
    char text[256];
    set_phase(p, SPDF_WIN_PANEL_NEED_INSTALL);
    spdf_win_panel_log(p, "");
    spdf_win_panel_log(p, "Missing on this machine:");
    for (int i = 0; i < p->plan.count; ++i) spdf_win_panel_log(p, p->plan.steps[i].label);
    snprintf(text, sizeof(text), "%d step%s to install. Click Install to set it up, then %s continues automatically.",
             p->plan.count, p->plan.count == 1 ? "" : "s", p->mode == SPDF_WIN_PANEL_OCR ? "OCR" : "translation");
    spdf_win_panel_set_status(p, text);
    spdf_win_panel_set_progress(p, 0);
    spdf_win_panel_set_buttons(p, L"Install", 0);
}

static void run_ocr(spdf_win_panel* p) {
    SpdfWinOcrRequest req;
    SpdfWinOcrCallbacks cb;
    char message[1024];

    if (p->document_has_text) {
        char backup[SPDF_WIN_TC_PATH], err[256] = "";
        /* GTK3: copy <stem>_backup.pdf beside the original before OCR replaces a
         * PDF that already had selectable text -- after asking. */
        if (MessageBoxW(p->hwnd,
                        L"This PDF already contains selectable text.\n\nShenzhen PDF will make a backup before OCR "
                        L"replaces it.",
                        L"OCR and Backup", MB_OKCANCEL | MB_ICONINFORMATION) != IDOK) {
            set_phase(p, SPDF_WIN_PANEL_DONE);
            spdf_win_panel_set_status(p, "OCR not started.");
            spdf_win_panel_set_buttons(p, primary_label(p), 0);
            return;
        }
        if (!spdf_win_ocr_write_backup(p->pdf_path, backup, sizeof(backup), err, sizeof(err))) {
            set_phase(p, SPDF_WIN_PANEL_DONE);
            spdf_win_panel_set_status(p, err);
            spdf_win_panel_set_buttons(p, primary_label(p), 0);
            return;
        }
        snprintf(message, sizeof(message), "Backup written: %s", backup);
        spdf_win_panel_log(p, message);
    }
    memset(&req, 0, sizeof(req));
    req.pdf_path = p->pdf_path;
    req.language = p->language;
    req.language_label = p->language_label;
    req.input_has_text = p->document_has_text;
    req.tools = &p->tools;
    req.roots = &p->roots;
    memset(&cb, 0, sizeof(cb));
    cb.user = p;
    cb.on_line = job_line;
    cb.on_status = job_status;
    cb.on_done = job_done;
    p->ocr = spdf_win_ocr_start(&req, &cb);
    if (!p->ocr) {
        set_phase(p, SPDF_WIN_PANEL_DONE);
        spdf_win_panel_set_status(p, "Could not start OCRmyPDF.");
        spdf_win_panel_set_buttons(p, primary_label(p), 0);
        return;
    }
    set_phase(p, SPDF_WIN_PANEL_RUNNING);
    spdf_win_panel_set_progress(p, -1);
    spdf_win_panel_set_buttons(p, NULL, 1);
}

static void run_document(spdf_win_panel* p) {
    SpdfWinTranslateDocRequest req;
    SpdfWinTranslateDocCallbacks cb;
    memset(&req, 0, sizeof(req));
    req.pdf_path = p->pdf_path;
    req.from_lang = p->from_lang;
    req.to_lang = p->to_lang;
    req.argos_path = p->tools.path[SPDF_WIN_TOOL_ARGOS_TRANSLATE];
    req.scripts_dir = p->roots.user_scripts;
    memset(&cb, 0, sizeof(cb));
    cb.user = p;
    cb.on_line = job_line;
    cb.on_progress = job_progress;
    cb.on_done = job_done;
    p->doc = spdf_win_translate_doc_start(&req, &cb);
    if (!p->doc) {
        set_phase(p, SPDF_WIN_PANEL_DONE);
        spdf_win_panel_set_status(p, "Could not start the translation.");
        spdf_win_panel_set_buttons(p, primary_label(p), 0);
        return;
    }
    set_phase(p, SPDF_WIN_PANEL_RUNNING);
    spdf_win_panel_set_status(p, "Preparing translation...");
    spdf_win_panel_set_progress(p, 0);
    spdf_win_panel_set_buttons(p, NULL, 1);
}

static void run_selection(spdf_win_panel* p) {
    free(p->selection);
    p->selection = spdf_win_panel_input_text(p);
    if (!p->selection || !*p->selection) {
        set_phase(p, SPDF_WIN_PANEL_DONE);
        spdf_win_panel_set_status(p, "Input text is empty.");
        spdf_win_panel_set_buttons(p, primary_label(p), 0);
        return;
    }
    set_phase(p, SPDF_WIN_PANEL_RUNNING);
    spdf_win_panel_set_status(p, "Translating locally with Argos...");
    spdf_win_panel_set_output_text(p, "");
    spdf_win_panel_set_progress(p, -1);
    spdf_win_panel_set_buttons(p, NULL, 1);
    if (!start_worker(p, text_thread))
        spdf_win_panel_post_result(p->hwnd, SPDF_WIN_PANEL_MSG_TEXT_DONE, 0, 0, "Could not start a worker thread.", "");
}

/* The toolchain is in hand: run the mode's job. */
static void run_job(spdf_win_panel* p) {
    switch (p->mode) {
        case SPDF_WIN_PANEL_OCR: run_ocr(p); break;
        case SPDF_WIN_PANEL_TRANSLATE_DOCUMENT: run_document(p); break;
        default: run_selection(p); break;
    }
}

/* Read the pickers, persist them (settings.yaml: ocrLanguage /
 * translateSourceLanguage / translateTargetLanguage, the GTK keys), probe. */
static void gather_and_probe(spdf_win_panel* p) {
    if (p->mode == SPDF_WIN_PANEL_OCR) {
        int index;
        if (!spdf_win_panel_combo_code(p, p->lang_combo, p->language, sizeof(p->language))) return;
        index = spdf_win_ocr_language_index(p->language);
        snprintf(p->language_label, sizeof(p->language_label), "%s",
                 index >= 0 ? spdf_win_ocr_languages(NULL)[index].label : p->language);
        spdf_win_toolchain_setting_set("ocrLanguage", p->language);
    } else {
        if (!spdf_win_panel_combo_code(p, p->lang_combo, p->from_lang, sizeof(p->from_lang)) ||
            !spdf_win_panel_combo_code(p, p->to_combo, p->to_lang, sizeof(p->to_lang)))
            return;
        if (strcmp(p->from_lang, p->to_lang) == 0) {
            spdf_win_panel_set_status(p, "Choose different source and target languages.");
            return;
        }
        spdf_win_toolchain_setting_set("translateSourceLanguage", p->from_lang);
        spdf_win_toolchain_setting_set("translateTargetLanguage", p->to_lang);
    }
    p->offered_package = 0;
    p->with_package = 0;
    begin_probe(p);
}

/* --- entry points from the window half ----------------------------------------- */

void spdf_win_panel_flow_begin(spdf_win_panel* p) {
    set_phase(p, SPDF_WIN_PANEL_IDLE);
    spdf_win_panel_set_progress(p, 0);
    spdf_win_panel_set_buttons(p, primary_label(p), 0);
    switch (p->mode) {
        case SPDF_WIN_PANEL_OCR:
            spdf_win_panel_set_status(p, "Choose the language data Tesseract should use for this PDF, then Run OCR.");
            break;
        case SPDF_WIN_PANEL_TRANSLATE_DOCUMENT:
            spdf_win_panel_set_status(p, "Translate the whole document with Argos Translate, on this machine.");
            break;
        default:
            /* The selection panel runs at once, as on macOS and GTK. */
            spdf_win_panel_set_status(p, "Preparing translation...");
            gather_and_probe(p);
            break;
    }
}

void spdf_win_panel_flow_primary(spdf_win_panel* p) {
    if (p->phase == SPDF_WIN_PANEL_NEED_INSTALL) begin_install(p);
    else if (!phase_busy(p->phase)) gather_and_probe(p);
}

void spdf_win_panel_flow_cancel(spdf_win_panel* p) {
    if (!phase_busy(p->phase)) return;
    spdf_win_panel_set_status(p, "Canceling...");
    EnableWindow(p->cancel_button, FALSE);
    if (p->ocr) spdf_win_ocr_cancel(p->ocr);
    if (p->doc) spdf_win_translate_doc_cancel(p->doc);
    if (p->cancel) SetEvent(p->cancel);
}

static void finished(spdf_win_panel* p, const char* status) {
    set_phase(p, SPDF_WIN_PANEL_DONE);
    if (status) {
        spdf_win_panel_set_status(p, status);
        spdf_win_panel_log(p, status);
    }
    spdf_win_panel_set_buttons(p, primary_label(p), 0);
    if (p->close_when_done) DestroyWindow(p->hwnd);
}

/* Mac rule: only a missing-language-package failure gets the argospm offer,
 * once; every other error must show as itself. */
static int offer_package(spdf_win_panel* p, const char* failure) {
    wchar_t text[512];
    char package[96];
    if (p->offered_package || !spdf_win_toolchain_argos_failure_is_missing_package(failure)) return 0;
    p->offered_package = 1;
    spdf_win_toolchain_argos_package_name(p->from_lang, p->to_lang, package, sizeof(package));
    _snwprintf_s(text, _TRUNCATE,
                 L"The offline %hs to %hs package may be missing. Shenzhen PDF can ask argospm to install %hs, then "
                 L"continue translation.",
                 p->from_lang, p->to_lang, package);
    if (MessageBoxW(p->hwnd, text, L"Install Argos language package?", MB_OKCANCEL | MB_ICONQUESTION) != IDOK) return 0;
    p->with_package = 1;
    spdf_win_toolchain_argos_plan(&p->tools, &p->roots, p->from_lang, p->to_lang, 1, &p->plan);
    begin_install(p);
    return 1;
}

int spdf_win_panel_flow_message(spdf_win_panel* p, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
        case SPDF_WIN_PANEL_MSG_LINE:
            spdf_win_panel_log(p, (const char*)lparam);
            free((void*)lparam);
            return 0;
        case SPDF_WIN_PANEL_MSG_STATUS:
            spdf_win_panel_set_status(p, (const char*)lparam);
            free((void*)lparam);
            return 0;
        case SPDF_WIN_PANEL_MSG_PROGRESS: spdf_win_panel_set_progress(p, (int)wparam); return 0;

        case SPDF_WIN_PANEL_MSG_PROBED: {
            join_worker(p);
            if (WaitForSingleObject(p->cancel, 0) == WAIT_OBJECT_0) {
                finished(p, "Canceled.");
                return 0;
            }
            if (p->mode == SPDF_WIN_PANEL_OCR) spdf_win_toolchain_ocr_plan(&p->tools, &p->roots, p->language, &p->plan);
            else spdf_win_toolchain_argos_plan(&p->tools, &p->roots, p->from_lang, p->to_lang, p->with_package, &p->plan);
            if (p->plan.count > 0) offer_install(p);
            else run_job(p);
            return 0;
        }

        case SPDF_WIN_PANEL_MSG_INSTALLED:
            join_worker(p);
            if (wparam) {
                spdf_win_panel_log(p, "Installation finished; continuing.");
                p->with_package = 0;
                begin_probe(p); /* GTK ocr_install_done: continue automatically */
            } else if (WaitForSingleObject(p->cancel, 0) == WAIT_OBJECT_0) {
                finished(p, "Installation canceled.");
            } else {
                set_phase(p, SPDF_WIN_PANEL_NEED_INSTALL);
                spdf_win_panel_set_status(p, "Installation failed. The log above can be selected and copied.");
                spdf_win_panel_set_progress(p, 0);
                spdf_win_panel_set_buttons(p, L"Retry Install", 0);
                if (p->close_when_done) DestroyWindow(p->hwnd);
            }
            return 0;

        case SPDF_WIN_PANEL_MSG_TEXT_DONE: {
            SpdfWinPanelResult* r = (SpdfWinPanelResult*)lparam;
            join_worker(p);
            spdf_win_panel_set_progress(p, r->success ? 1000 : 0); /* stop the marquee */
            if (r->success) {
                spdf_win_panel_set_output_text(p, r->message);
                finished(p, "Translation complete.");
            } else if (r->cancelled) {
                finished(p, "Translation canceled.");
            } else if (!offer_package(p, r->message)) {
                finished(p, r->message);
            }
            free(r->message);
            free(r->output_path);
            free(r);
            return 0;
        }

        case SPDF_WIN_PANEL_MSG_JOB_DONE: {
            SpdfWinPanelResult* r = (SpdfWinPanelResult*)lparam;
            if (p->ocr) {
                spdf_win_ocr_free(p->ocr);
                p->ocr = NULL;
                if (r->success) {
                    char err[512] = "";
                    /* The validated output waits beside the original; the host
                     * closes its handles, swaps, reopens (spdf_win_ocr.h). */
                    spdf_win_panel_set_progress(p, 1000);
                    if (p->host.ocr_finished &&
                        p->host.ocr_finished(p->host.user, p->pdf_path, r->output_path, err, sizeof(err))) {
                        finished(p, "OCR complete. The document has been reloaded with its new text layer.");
                    } else {
                        spdf_win_ocr_discard(r->output_path);
                        finished(p, err[0] ? err : "Could not install the OCR output over the original.");
                    }
                } else {
                    spdf_win_panel_set_progress(p, 0);
                    finished(p, r->message);
                }
            } else if (p->doc) {
                spdf_win_translate_doc_free(p->doc);
                p->doc = NULL;
                if (r->success) {
                    char text[SPDF_WIN_TC_PATH + 32];
                    const char* leaf = strrchr(r->output_path, '\\');
                    snprintf(text, sizeof(text), "Translation saved: %s", leaf ? leaf + 1 : r->output_path);
                    spdf_win_panel_set_progress(p, 1000);
                    if (p->host.open_document) p->host.open_document(p->host.user, r->output_path);
                    finished(p, text);
                } else if (r->cancelled) {
                    spdf_win_panel_set_progress(p, 0);
                    finished(p, "Translation canceled.");
                } else if (!offer_package(p, r->message)) {
                    spdf_win_panel_set_progress(p, 0);
                    finished(p, r->message);
                }
            }
            free(r->message);
            free(r->output_path);
            free(r);
            return 0;
        }
        default: return 0;
    }
}

void spdf_win_panel_flow_shutdown(spdf_win_panel* p) {
    if (p->ocr) spdf_win_ocr_cancel(p->ocr);
    if (p->doc) spdf_win_translate_doc_cancel(p->doc);
    if (p->cancel) SetEvent(p->cancel);
    join_worker(p);
    if (p->ocr) {
        spdf_win_ocr_free(p->ocr);
        p->ocr = NULL;
    }
    if (p->doc) {
        spdf_win_translate_doc_free(p->doc);
        p->doc = NULL;
    }
    if (p->cancel) {
        CloseHandle(p->cancel);
        p->cancel = NULL;
    }
    if (phase_busy(p->phase)) spdf_win_panel_set_busy(p, 0);
    p->phase = SPDF_WIN_PANEL_IDLE;
}
