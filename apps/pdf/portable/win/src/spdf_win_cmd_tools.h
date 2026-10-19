#pragma once

/* COMMAND HANDLERS: power tools: OCR and translation.
 *
 * Header-only, included from spdf_win_chrome_commands.h only, after the app
 * struct, the chrome model and the input types are complete -- the same
 * arrangement as every other *_commands/*_actions header in this port. Owned
 * by the parity track of that name (portable/docs/windows-feature-matrix.md);
 * the other tracks have their own and none of them edits command_perform().
 *
 * Return 1 when the command was consumed, 0 to let it fall through.
 *
 * WHAT THIS GLUE DOES, and no more: it turns the three commands into a panel
 * request (spdf_win_panel.h) with the current document's path, the selection's
 * text and the theme, and it answers the panel's three questions on the UI
 * thread -- swap the OCR result in and reload, open the translated copy in a
 * new tab, grey the toolbar while a job runs. Everything about the toolchain,
 * the jobs and the window lives behind spdf_win_panel.h; this file is the only
 * place that knows both `app` and the panel.
 *
 * THE OCR SWAP IS HERE BECAUSE ONLY THE APP CAN CLOSE THE DOCUMENT. Windows
 * will not rename over a file MuPDF has open (spdf_win_ocr.h), and the
 * handles on it belong to three owners this glue can reach: the canvas (whose
 * render workers each hold one), the tab model, and the sidebar bridge. All
 * three are released, the validated output is moved into place, and the tab
 * is shown again -- which re-opens the file with its new text layer, on the
 * page the reader was on. */

#include "spdf_win_ocr.h"
#include "spdf_win_panel.h"

static int tools_selected_pdf(app* a, char* path, size_t path_len, spdf_document** doc_out) {
    char err[256] = {0};
    int sel;
    const char* utf8;
    if (!a->tabs || !a->canvas) return 0;
    sel = spdf_win_tabs_selected_index(a->tabs);
    if (sel < 0) return 0;
    utf8 = spdf_win_tabs_path(a->tabs, sel);
    if (!utf8 || !*utf8) return 0;
    /* PDF only, as GTK's spdf_annot_path_has_pdf_extension: OCRmyPDF and the
     * translated-copy writer both rewrite a PDF's own pages. */
    {
        size_t n = strlen(utf8);
        if (n < 4 || _stricmp(utf8 + n - 4, ".pdf") != 0) return 0;
    }
    snprintf(path, path_len, "%s", utf8);
    if (doc_out) *doc_out = (spdf_document*)spdf_win_tabs_document(a->tabs, sel, err, sizeof(err));
    return 1;
}

/* The panel's host callbacks. All on the UI thread (spdf_win_panel.h). */

static int tools_host_ocr_finished(void* user, const char* pdf_path, const char* output_path, char* err,
                                   size_t err_len) {
    app* a = (app*)user;
    int index = a->tabs ? spdf_win_tabs_index_of_path(a->tabs, pdf_path) : -1;
    int selected = index >= 0 && index == spdf_win_tabs_selected_index(a->tabs);
    int page = a->canvas ? spdf_win_canvas_current_page(a->canvas) : 0;
    int ok;

    if (selected) {
        spdf_win_tabs_app_remember(a->tabs, a->canvas);
        spdf_win_canvas_destroy(a->canvas); /* joins the render workers, closing their documents */
        a->canvas = NULL;
    }
    if (index >= 0) spdf_win_tabs_release_document(a->tabs, index);
    spdf_win_chrome_content_set_document(NULL, 0); /* the sidebar bridge's own handle */
    ok = spdf_win_ocr_install_output(output_path, pdf_path, err, err_len);
    if (selected) {
        show_selected_tab(a);
        a->pending_page = page;
        /* A live query re-runs against the new text layer: the whole point of
         * OCR is that a search now finds something. */
        chrome_find_push(a);
    }
    if (a->window) spdf_win_window_invalidate(a->window);
    return ok;
}

static void tools_host_open_document(void* user, const char* path) {
    app* a = (app*)user;
    wchar_t wide[1024];
    if (!path || !*path) return;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) == 0)
        return;
    chrome_open_wide(a, wide);
    if (a->window) spdf_win_window_invalidate(a->window);
}

static void tools_host_busy_changed(void* user, int busy) {
    app* a = (app*)user;
    spdf_win_chrome_toolbar_set_tools_state(busy, busy, a->canvas ? spdf_win_canvas_has_selection(a->canvas) : 0);
    if (a->window) spdf_win_window_invalidate(a->window);
}

static int tools_open_panel(app* a, spdf_win_panel_mode mode) {
    SpdfWinPanelRequest req;
    SpdfWinPanelHost host;
    spdf_document* doc = NULL;
    char path[1024];
    char err[256] = {0};
    const char* selection = NULL;

    if (!tools_selected_pdf(a, path, sizeof(path), &doc) || !doc) return 0;
    if (mode == SPDF_WIN_PANEL_TRANSLATE_SELECTION) {
        /* Mac translateDocument: a live selection opens the selection panel;
         * anything else runs the whole-document pipeline. */
        selection = a->canvas && spdf_win_canvas_has_selection(a->canvas) ? spdf_win_canvas_selection_text(a->canvas)
                                                                          : NULL;
        if (!selection || !*selection) mode = SPDF_WIN_PANEL_TRANSLATE_DOCUMENT;
    }
    if (mode == SPDF_WIN_PANEL_OCR && !spdf_has_permission(doc, 'e')) {
        report(L"OCR is not allowed: this document does not permit changes.", a->window != NULL);
        return 0;
    }
    memset(&req, 0, sizeof(req));
    req.mode = mode;
    req.owner = a->window ? (HWND)spdf_win_window_native_handle(a->window) : NULL;
    req.dark = (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    req.pdf_path = path;
    req.selection = selection;
    if (mode == SPDF_WIN_PANEL_OCR) {
        int has = spdf_document_has_text(doc, 0, err, sizeof(err));
        if (has < 0) {
            doc_action_report(a, err[0] ? err : "Could not inspect document text.");
            return 0;
        }
        req.document_has_text = has;
    }
    memset(&host, 0, sizeof(host));
    host.user = a;
    host.ocr_finished = tools_host_ocr_finished;
    host.open_document = tools_host_open_document;
    host.busy_changed = tools_host_busy_changed;
    return spdf_win_panel_open(&req, &host);
}

static int spdf_win_cmd_tools_perform(app* a, int command, const spdf_win_input* in) {
    (void)in;
    switch (command) {
        case SPDF_WIN_CMD_OCR: tools_open_panel(a, SPDF_WIN_PANEL_OCR); return 1;
        case SPDF_WIN_CMD_TRANSLATE_SELECTION: tools_open_panel(a, SPDF_WIN_PANEL_TRANSLATE_SELECTION); return 1;
        case SPDF_WIN_CMD_TRANSLATE_DOCUMENT: tools_open_panel(a, SPDF_WIN_PANEL_TRANSLATE_DOCUMENT); return 1;
        default: return 0;
    }
}
