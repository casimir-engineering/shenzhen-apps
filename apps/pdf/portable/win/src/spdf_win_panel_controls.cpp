/* spdf_win_panel_controls.cpp -- the flow half's view of the panel's controls:
 * append to the log, set the status and the progress bar, arrange the buttons,
 * read a picker or the input text, set the translation text, and the two
 * PostMessage helpers the workers use. Split from spdf_win_panel.cpp at the
 * 500-line cap; the class, layout and theme stay there. */
#include "spdf_win_panel_internal.h"

#include <commctrl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static wchar_t* wide_dup(const char* utf8) {
    int need = MultiByteToWideChar(CP_UTF8, 0, utf8 ? utf8 : "", -1, NULL, 0);
    wchar_t* w = need > 0 ? (wchar_t*)malloc(sizeof(wchar_t) * (size_t)need) : NULL;
    if (w) MultiByteToWideChar(CP_UTF8, 0, utf8 ? utf8 : "", -1, w, need);
    return w;
}

static char* utf8_dup(const wchar_t* w) {
    int need = WideCharToMultiByte(CP_UTF8, 0, w ? w : L"", -1, NULL, 0, NULL, NULL);
    char* s = need > 0 ? (char*)malloc((size_t)need) : NULL;
    if (s) WideCharToMultiByte(CP_UTF8, 0, w ? w : L"", -1, s, need, NULL, NULL);
    return s;
}

int spdf_win_panel_combo_code(spdf_win_panel* p, HWND combo, char* out, size_t out_bytes) {
    int sel = (int)SendMessageW(combo, CB_GETCURSEL, 0, 0), count = 0;
    if (sel < 0) return 0;
    if (p->mode == SPDF_WIN_PANEL_OCR) {
        const SpdfWinOcrLanguage* l = spdf_win_ocr_languages(&count);
        if (sel >= count) return 0;
        snprintf(out, out_bytes, "%s", l[sel].code);
    } else {
        const SpdfWinTranslationLanguage* l = spdf_win_translation_languages(&count);
        if (sel >= count) return 0;
        snprintf(out, out_bytes, "%s", l[sel].code);
    }
    return 1;
}

/* --- the flow's view of the controls -------------------------------------------- */

void spdf_win_panel_log(spdf_win_panel* p, const char* utf8) {
    wchar_t* w = wide_dup(utf8 ? utf8 : "");
    int len;
    if (!w || !p->log) {
        free(w);
        return;
    }
    len = GetWindowTextLengthW(p->log);
    SendMessageW(p->log, EM_SETSEL, (WPARAM)len, (LPARAM)len);
    SendMessageW(p->log, EM_REPLACESEL, FALSE, (LPARAM)w);
    SendMessageW(p->log, EM_REPLACESEL, FALSE, (LPARAM)L"\r\n");
    SendMessageW(p->log, EM_SCROLLCARET, 0, 0);
    free(w);
}

void spdf_win_panel_set_status(spdf_win_panel* p, const char* utf8) {
    wchar_t* w = wide_dup(utf8 ? utf8 : "");
    if (w) SetWindowTextW(p->status, w);
    free(w);
}

void spdf_win_panel_set_progress(spdf_win_panel* p, int permille) {
    if (!p->progress) return;
    if (permille < 0) {
        SetWindowLongPtrW(p->progress, GWL_STYLE, GetWindowLongPtrW(p->progress, GWL_STYLE) | PBS_MARQUEE);
        SendMessageW(p->progress, PBM_SETMARQUEE, TRUE, 60);
    } else {
        SendMessageW(p->progress, PBM_SETMARQUEE, FALSE, 0);
        SetWindowLongPtrW(p->progress, GWL_STYLE, GetWindowLongPtrW(p->progress, GWL_STYLE) & ~(LONG_PTR)PBS_MARQUEE);
        SendMessageW(p->progress, PBM_SETRANGE32, 0, 1000);
        SendMessageW(p->progress, PBM_SETPOS, (WPARAM)(permille > 1000 ? 1000 : permille), 0);
    }
}

void spdf_win_panel_set_buttons(spdf_win_panel* p, const wchar_t* primary, int cancel_enabled) {
    if (primary) SetWindowTextW(p->primary, primary);
    EnableWindow(p->primary, primary != NULL);
    ShowWindow(p->primary, primary ? SW_SHOW : SW_HIDE);
    EnableWindow(p->cancel_button, cancel_enabled);
    EnableWindow(p->close_button, !cancel_enabled);
}

char* spdf_win_panel_input_text(spdf_win_panel* p) {
    int len = GetWindowTextLengthW(p->input_edit);
    wchar_t* w = (wchar_t*)malloc(sizeof(wchar_t) * ((size_t)len + 1));
    char* s;
    size_t n;
    if (!w) return NULL;
    GetWindowTextW(p->input_edit, w, len + 1);
    s = utf8_dup(w);
    free(w);
    if (!s) return NULL;
    /* Trim, and let the EDIT's CRLF become the '\n' Argos expects. */
    for (char* q = s; *q; ++q)
        if (*q == '\r') *q = ' ';
    n = strlen(s);
    while (n && (s[n - 1] == ' ' || s[n - 1] == '\n' || s[n - 1] == '\t')) s[--n] = '\0';
    {
        char* start = s;
        while (*start == ' ' || *start == '\n' || *start == '\t') ++start;
        if (start != s) memmove(s, start, strlen(start) + 1);
    }
    return s;
}

void spdf_win_panel_set_output_text(spdf_win_panel* p, const char* utf8) {
    /* LF -> CRLF for the EDIT control, which shows a bare LF as a box. */
    size_t n = utf8 ? strlen(utf8) : 0, breaks = 0;
    char* crlf;
    wchar_t* w;
    for (size_t i = 0; i < n; ++i)
        if (utf8[i] == '\n') ++breaks;
    crlf = (char*)malloc(n + breaks + 1);
    if (!crlf) return;
    for (size_t i = 0, o = 0; i <= n; ++i) {
        if (i < n && utf8[i] == '\n' && (i == 0 || utf8[i - 1] != '\r')) crlf[o++] = '\r';
        crlf[o++] = i < n ? utf8[i] : '\0';
    }
    w = wide_dup(crlf);
    if (w) SetWindowTextW(p->output_edit, w);
    free(w);
    free(crlf);
}

void spdf_win_panel_post_text(HWND hwnd, UINT msg, const char* utf8) {
    char* copy = _strdup(utf8 ? utf8 : "");
    if (copy && !PostMessageW(hwnd, msg, 0, (LPARAM)copy)) free(copy);
}

void spdf_win_panel_post_result(HWND hwnd, UINT msg, int success, int cancelled, const char* message,
                                const char* output_path) {
    SpdfWinPanelResult* r = (SpdfWinPanelResult*)calloc(1, sizeof(*r));
    if (!r) return;
    r->success = success;
    r->cancelled = cancelled;
    r->message = _strdup(message ? message : "");
    r->output_path = _strdup(output_path ? output_path : "");
    if (!PostMessageW(hwnd, msg, 0, (LPARAM)r)) {
        free(r->message);
        free(r->output_path);
        free(r);
    }
}

void spdf_win_panel_set_busy(spdf_win_panel* p, int busy) {
    if (p->host.busy_changed) p->host.busy_changed(p->host.user, busy);
}

