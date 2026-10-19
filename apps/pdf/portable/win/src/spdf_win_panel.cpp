/* spdf_win_panel.cpp -- the WINDOW half of the tool panel: class, controls,
 * layout, theme, and the message plumbing between the workers and the flow
 * half (spdf_win_panel_jobs.cpp). Contract in spdf_win_panel.h. */
#include "spdf_win_panel_internal.h"

#include <commctrl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uxtheme.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "uxtheme.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
/* Version-6 common controls, so the buttons and combos draw in the current
 * Windows style and accept the DarkMode_* themes. The port has no .rc and no
 * manifest file; the linker writes this dependency into the exe's manifest. */
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' " \
                        "version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

#define ID_PRIMARY 2001
#define ID_CANCEL 2002
#define ID_CLOSE 2003
#define ID_COPY 2004

static const wchar_t* k_class = L"SpdfWinToolPanel";
static spdf_win_panel* g_panel; /* one per process; see the header */

/* --- helpers --------------------------------------------------------------- */

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

static int scale(const spdf_win_panel* p, int px) {
    UINT dpi = p->hwnd ? GetDpiForWindow(p->hwnd) : 96;
    return MulDiv(px, (int)(dpi ? dpi : 96), 96);
}

static HWND make(spdf_win_panel* p, const wchar_t* cls, const wchar_t* text, DWORD style, DWORD ex, int id) {
    HWND h = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, p->hwnd, (HMENU)(INT_PTR)id,
                             GetModuleHandleW(NULL), NULL);
    if (h) SendMessageW(h, WM_SETFONT, (WPARAM)p->font, TRUE);
    return h;
}

static void fill_combo(HWND combo, int translate, const char* selected_code) {
    int count = 0, pick = 0;
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    if (translate) {
        const SpdfWinTranslationLanguage* l = spdf_win_translation_languages(&count);
        for (int i = 0; i < count; ++i) {
            char label[96];
            wchar_t* w;
            snprintf(label, sizeof(label), "%s (%s)", l[i].name, l[i].code);
            w = wide_dup(label);
            SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)w);
            free(w);
            if (selected_code && strcmp(selected_code, l[i].code) == 0) pick = i;
        }
    } else {
        const SpdfWinOcrLanguage* l = spdf_win_ocr_languages(&count);
        for (int i = 0; i < count; ++i) {
            wchar_t* w = wide_dup(l[i].label);
            SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)w);
            free(w);
            if (selected_code && strcmp(selected_code, l[i].code) == 0) pick = i;
        }
    }
    SendMessageW(combo, CB_SETCURSEL, (WPARAM)pick, 0);
}

/* --- theme ------------------------------------------------------------------ */

typedef HRESULT(WINAPI* dwm_set_attr_fn)(HWND, DWORD, LPCVOID, DWORD);

static void apply_theme(spdf_win_panel* p) {
    HWND controls[] = {p->lang_combo, p->to_combo, p->input_edit, p->output_edit, p->log,       p->copy_button,
                       p->primary,    p->cancel_button, p->close_button, p->status, p->lang_label, p->to_label,
                       p->input_label, p->output_label};
    HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
    if (p->bg) DeleteObject(p->bg);
    if (p->field_bg) DeleteObject(p->field_bg);
    p->bg = CreateSolidBrush(p->dark ? RGB(32, 32, 32) : GetSysColor(COLOR_3DFACE));
    p->field_bg = CreateSolidBrush(p->dark ? RGB(45, 45, 45) : GetSysColor(COLOR_WINDOW));
    if (dwm) {
        dwm_set_attr_fn set_attr = (dwm_set_attr_fn)GetProcAddress(dwm, "DwmSetWindowAttribute");
        BOOL on = p->dark ? TRUE : FALSE;
        if (set_attr && FAILED(set_attr(p->hwnd, 20, &on, sizeof(on)))) set_attr(p->hwnd, 19, &on, sizeof(on));
        FreeLibrary(dwm);
    }
    for (size_t i = 0; i < sizeof(controls) / sizeof(controls[0]); ++i) {
        wchar_t cls[32] = L"";
        if (!controls[i]) continue;
        GetClassNameW(controls[i], cls, 32);
        SetWindowTheme(controls[i], p->dark ? (_wcsicmp(cls, L"ComboBox") == 0 ? L"DarkMode_CFD" : L"DarkMode_Explorer")
                                            : L"Explorer",
                       NULL);
    }
    InvalidateRect(p->hwnd, NULL, TRUE);
}

/* --- layout ----------------------------------------------------------------- */

static void place(HWND h, int x, int y, int w, int hgt) {
    if (h) MoveWindow(h, x, y, w < 1 ? 1 : w, hgt < 1 ? 1 : hgt, TRUE);
}

static void layout(spdf_win_panel* p) {
    RECT rc;
    int m = scale(p, 12), row = scale(p, 26), gap = scale(p, 8), bw = scale(p, 120), bh = scale(p, 28);
    int x = m, y = m, w, label_w = scale(p, 56), combo_w;
    int selection = p->mode == SPDF_WIN_PANEL_TRANSLATE_SELECTION;
    GetClientRect(p->hwnd, &rc);
    w = rc.right - rc.left - 2 * m;

    /* Row 1: the language picker(s). */
    if (p->mode == SPDF_WIN_PANEL_OCR) {
        place(p->lang_label, x, y + scale(p, 4), label_w + scale(p, 20), row);
        place(p->lang_combo, x + label_w + scale(p, 24), y, scale(p, 260), row * 12);
    } else {
        combo_w = (w - 2 * label_w - gap) / 2;
        place(p->lang_label, x, y + scale(p, 4), label_w, row);
        place(p->lang_combo, x + label_w, y, combo_w, row * 12);
        place(p->to_label, x + label_w + combo_w + gap, y + scale(p, 4), label_w, row);
        place(p->to_combo, x + 2 * label_w + combo_w + gap, y, combo_w, row * 12);
    }
    y += row + gap;

    /* Selection mode: input and output, the log below smaller. */
    if (selection) {
        int text_h = (rc.bottom - y - m - bh - gap - 3 * row - 3 * gap - scale(p, 90)) / 2;
        if (text_h < scale(p, 60)) text_h = scale(p, 60);
        place(p->input_label, x, y, w, row);
        y += row;
        place(p->input_edit, x, y, w, text_h);
        y += text_h + gap;
        place(p->output_label, x, y, w, row);
        y += row;
        place(p->output_edit, x, y, w, text_h);
        y += text_h + gap;
    }

    /* Status, progress, log, buttons. */
    place(p->status, x, y, w, row);
    y += row;
    place(p->progress, x, y, w, scale(p, 6));
    y += scale(p, 6) + gap;
    {
        int log_h = rc.bottom - m - bh - gap - y;
        if (log_h < scale(p, 40)) log_h = scale(p, 40);
        place(p->log, x, y, w, log_h);
        y += log_h + gap;
    }
    place(p->copy_button, x, y, scale(p, 90), bh);
    place(p->close_button, rc.right - m - bw, y, bw, bh);
    place(p->cancel_button, rc.right - m - 2 * bw - gap, y, bw, bh);
    place(p->primary, rc.right - m - 3 * bw - 2 * gap, y, bw, bh);
}

static void show_mode_controls(spdf_win_panel* p) {
    int selection = p->mode == SPDF_WIN_PANEL_TRANSLATE_SELECTION;
    int translate = p->mode != SPDF_WIN_PANEL_OCR;
    ShowWindow(p->to_label, translate ? SW_SHOW : SW_HIDE);
    ShowWindow(p->to_combo, translate ? SW_SHOW : SW_HIDE);
    ShowWindow(p->input_label, selection ? SW_SHOW : SW_HIDE);
    ShowWindow(p->input_edit, selection ? SW_SHOW : SW_HIDE);
    ShowWindow(p->output_label, selection ? SW_SHOW : SW_HIDE);
    ShowWindow(p->output_edit, selection ? SW_SHOW : SW_HIDE);
    SetWindowTextW(p->lang_label, translate ? L"From" : L"Language");
    SetWindowTextW(p->hwnd, p->mode == SPDF_WIN_PANEL_OCR                   ? L"OCR"
                            : p->mode == SPDF_WIN_PANEL_TRANSLATE_SELECTION ? L"Translate Selection"
                                                                            : L"Translate Document");
}

/* --- window procedure ---------------------------------------------------------- */

static LRESULT CALLBACK panel_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    spdf_win_panel* p = (spdf_win_panel*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (p && msg >= SPDF_WIN_PANEL_MSG_LINE && msg <= SPDF_WIN_PANEL_MSG_TEXT_DONE)
        return spdf_win_panel_flow_message(p, msg, wparam, lparam);
    switch (msg) {
        case WM_SIZE:
            if (p) layout(p);
            return 0;
        case WM_GETMINMAXINFO: {
            MINMAXINFO* mmi = (MINMAXINFO*)lparam;
            mmi->ptMinTrackSize.x = 520;
            mmi->ptMinTrackSize.y = 360;
            return 0;
        }
        case WM_COMMAND:
            if (!p) break;
            switch (LOWORD(wparam)) {
                case ID_PRIMARY: spdf_win_panel_flow_primary(p); return 0;
                case ID_CANCEL: spdf_win_panel_flow_cancel(p); return 0;
                case ID_CLOSE:
                case IDCANCEL: SendMessageW(hwnd, WM_CLOSE, 0, 0); return 0;
                case ID_COPY: {
                    /* Select all + copy through the EDIT itself, so what is
                     * copied is exactly what is shown. */
                    SendMessageW(p->log, EM_SETSEL, 0, -1);
                    SendMessageW(p->log, WM_COPY, 0, 0);
                    SendMessageW(p->log, EM_SETSEL, (WPARAM)-1, 0);
                    return 0;
                }
                default: break;
            }
            break;
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLOREDIT:
        case WM_CTLCOLORLISTBOX:
        case WM_CTLCOLORBTN:
            if (p && p->dark) {
                HDC dc = (HDC)wparam;
                HWND ctl = (HWND)lparam;
                int field = ctl == p->log || ctl == p->input_edit || ctl == p->output_edit || msg == WM_CTLCOLORLISTBOX;
                SetTextColor(dc, RGB(235, 235, 235));
                SetBkColor(dc, field ? RGB(45, 45, 45) : RGB(32, 32, 32));
                return (LRESULT)(field ? p->field_bg : p->bg);
            }
            break;
        case WM_ERASEBKGND:
            if (p && p->dark) {
                RECT rc;
                GetClientRect(hwnd, &rc);
                FillRect((HDC)wparam, &rc, p->bg);
                return 1;
            }
            break;
        case WM_CLOSE:
            if (p && spdf_win_panel_is_busy()) {
                /* GTK3 block_dialog_delete: closing while a job runs cancels it
                 * first; the window goes when the job has reported. */
                p->close_when_done = 1;
                spdf_win_panel_flow_cancel(p);
                return 0;
            }
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            if (p) {
                spdf_win_panel_flow_shutdown(p);
                if (p->bg) DeleteObject(p->bg);
                if (p->field_bg) DeleteObject(p->field_bg);
                if (p->font) DeleteObject(p->font);
                if (p->mono) DeleteObject(p->mono);
                free(p->selection);
                free(p);
                g_panel = NULL;
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            }
            return 0;
        default: break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static int register_class(void) {
    static int done = 0;
    WNDCLASSEXW cls;
    INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES};
    if (done) return 1;
    InitCommonControlsEx(&icc);
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = panel_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); /* IDC_ARROW; see spdf_win_properties_dialog.cpp */
    cls.hbrBackground = (HBRUSH)(COLOR_3DFACE + 1);
    cls.lpszClassName = k_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return 0;
    done = 1;
    return 1;
}

static HFONT ui_font(int dpi, int mono) {
    NONCLIENTMETRICSW ncm;
    LOGFONTW lf;
    ncm.cbSize = sizeof(ncm);
    if (SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0, (UINT)dpi)) lf = ncm.lfMessageFont;
    else {
        memset(&lf, 0, sizeof(lf));
        lf.lfHeight = -MulDiv(9, dpi, 72);
        wcscpy(lf.lfFaceName, L"Segoe UI");
    }
    if (mono) {
        wcscpy(lf.lfFaceName, L"Consolas");
        lf.lfPitchAndFamily = FIXED_PITCH | FF_MODERN;
    }
    return CreateFontIndirectW(&lf);
}

static spdf_win_panel* create_panel(HWND owner, int dark) {
    spdf_win_panel* p = (spdf_win_panel*)calloc(1, sizeof(*p));
    int dpi;
    if (!p || !register_class()) {
        free(p);
        return NULL;
    }
    p->owner = owner;
    p->dark = dark;
    dpi = owner ? (int)GetDpiForWindow(owner) : 96;
    /* An OWNED top-level window (not a child, not a tool window): it gets its
     * own caption and taskbar entry, stays above the main window, and closes
     * with it. */
    p->hwnd = CreateWindowExW(0, k_class, L"OCR", WS_OVERLAPPEDWINDOW & ~WS_MAXIMIZEBOX,
                              CW_USEDEFAULT, CW_USEDEFAULT, MulDiv(680, dpi, 96), MulDiv(560, dpi, 96), owner, NULL,
                              GetModuleHandleW(NULL), NULL);
    if (!p->hwnd) {
        free(p);
        return NULL;
    }
    SetWindowLongPtrW(p->hwnd, GWLP_USERDATA, (LONG_PTR)p);
    p->font = ui_font(dpi, 0);
    p->mono = ui_font(dpi, 1);
    p->lang_label = make(p, L"STATIC", L"Language", SS_LEFT, 0, 0);
    p->lang_combo = make(p, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, 0, 0);
    p->to_label = make(p, L"STATIC", L"To", SS_LEFT, 0, 0);
    p->to_combo = make(p, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, 0, 0);
    p->input_label = make(p, L"STATIC", L"Input", SS_LEFT, 0, 0);
    p->input_edit = make(p, L"EDIT", L"", ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, WS_EX_CLIENTEDGE, 0);
    p->output_label = make(p, L"STATIC", L"Translation", SS_LEFT, 0, 0);
    p->output_edit = make(p, L"EDIT", L"", ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY | WS_VSCROLL, WS_EX_CLIENTEDGE, 0);
    p->status = make(p, L"STATIC", L"", SS_LEFT | SS_ENDELLIPSIS, 0, 0);
    p->progress = make(p, PROGRESS_CLASSW, L"", PBS_SMOOTH, 0, 0);
    p->log = make(p, L"EDIT", L"", ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY | WS_VSCROLL | WS_TABSTOP,
                  WS_EX_CLIENTEDGE, 0);
    if (p->log && p->mono) SendMessageW(p->log, WM_SETFONT, (WPARAM)p->mono, TRUE);
    /* A 30 K-character default limit would truncate a pip install log. */
    SendMessageW(p->log, EM_SETLIMITTEXT, 0x7FFFFFFE, 0);
    p->copy_button = make(p, L"BUTTON", L"Copy Log", BS_PUSHBUTTON | WS_TABSTOP, 0, ID_COPY);
    p->primary = make(p, L"BUTTON", L"Run", BS_DEFPUSHBUTTON | WS_TABSTOP, 0, ID_PRIMARY);
    p->cancel_button = make(p, L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, 0, ID_CANCEL);
    p->close_button = make(p, L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, 0, ID_CLOSE);
    apply_theme(p);
    return p;
}

/* --- public ------------------------------------------------------------------- */

int spdf_win_panel_open(const SpdfWinPanelRequest* req, const SpdfWinPanelHost* host) {
    spdf_win_panel* p;
    char code[64] = "";
    if (!req) return 0;
    if (g_panel && spdf_win_panel_is_busy()) {
        SetForegroundWindow(g_panel->hwnd);
        spdf_win_panel_set_status(g_panel, "A job is already running; wait for it or cancel it first.");
        return 1;
    }
    p = g_panel ? g_panel : create_panel(req->owner, req->dark);
    if (!p) return 0;
    g_panel = p;
    p->mode = req->mode;
    if (host) p->host = *host;
    else memset(&p->host, 0, sizeof(p->host));
    snprintf(p->pdf_path, sizeof(p->pdf_path), "%s", req->pdf_path ? req->pdf_path : "");
    free(p->selection);
    p->selection = _strdup(req->selection ? req->selection : "");
    p->document_has_text = req->document_has_text;
    if (p->dark != req->dark) {
        p->dark = req->dark;
        apply_theme(p);
    }
    show_mode_controls(p);
    if (p->mode == SPDF_WIN_PANEL_OCR) {
        spdf_win_toolchain_setting_get("ocrLanguage", code, sizeof(code));
        fill_combo(p->lang_combo, 0, code[0] ? code : "chi_sim+eng");
    } else {
        spdf_win_toolchain_setting_get("translateSourceLanguage", code, sizeof(code));
        fill_combo(p->lang_combo, 1, code[0] ? code : "zh");
        code[0] = '\0';
        spdf_win_toolchain_setting_get("translateTargetLanguage", code, sizeof(code));
        fill_combo(p->to_combo, 1, code[0] ? code : "en");
    }
    SetWindowTextW(p->log, L"");
    SetWindowTextW(p->output_edit, L"");
    if (p->mode == SPDF_WIN_PANEL_TRANSLATE_SELECTION) {
        spdf_win_panel_set_output_text(p, ""); /* clear */
        {
            wchar_t* w = wide_dup(p->selection);
            if (w) SetWindowTextW(p->input_edit, w);
            free(w);
        }
    }
    layout(p);
    ShowWindow(p->hwnd, SW_SHOW);
    SetForegroundWindow(p->hwnd);
    spdf_win_panel_flow_begin(p);
    return 1;
}

int spdf_win_panel_is_busy(void) {
    return g_panel && (g_panel->phase == SPDF_WIN_PANEL_PROBING || g_panel->phase == SPDF_WIN_PANEL_INSTALLING ||
                       g_panel->phase == SPDF_WIN_PANEL_RUNNING);
}

void spdf_win_panel_set_dark(int dark) {
    if (g_panel && g_panel->dark != dark) {
        g_panel->dark = dark;
        apply_theme(g_panel);
    }
}

void spdf_win_panel_close(void) {
    if (g_panel) DestroyWindow(g_panel->hwnd);
}
