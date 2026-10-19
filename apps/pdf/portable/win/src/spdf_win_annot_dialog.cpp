/* spdf_win_annot_dialog.cpp — see the header. */
#include "spdf_win_annot_dialog.h"

#include "spdf_win_about.h" /* spdf_win_about_dark_caption */
#include "spdf_win_chrome_theme.h"
#include "spdf_win_modal_scope.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <stdlib.h>
#include <string.h>
#include <wctype.h>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")

#define ANNOT_ID_AUTHOR 1101
#define ANNOT_ID_TEXT 1102
#define ANNOT_ID_OK 1103
#define ANNOT_ID_CANCEL 1104

#define ANNOT_DLG_W 480
#define ANNOT_DLG_H 340
#define ANNOT_AUTHOR_DLG_H 170
#define ANNOT_MARGIN 14
#define ANNOT_LABEL_H 18
#define ANNOT_FIELD_H 26
#define ANNOT_BUTTON_W 96
#define ANNOT_BUTTON_H 28

static const wchar_t* k_annot_class = L"SpdfWinAnnotDialog";

/* The caller's buffers, filled from the fields at the moment of OK -- which
 * has to happen BEFORE DestroyWindow takes the controls away. One modal
 * dialog at a time (the loop is modal), so one state. */
typedef struct annot_dlg_state {
    int finished;
    int ok;
    int dark;
    HBRUSH bg;
    HBRUSH field;
    SpdfWinChromeTheme theme;
    wchar_t* author;
    int author_cap;
    wchar_t* text;
    int text_cap;
} annot_dlg_state;

static COLORREF theme_ref(SpdfWinChromeColor c) {
    int r = (int)(c.r * 255.0f + 0.5f), g = (int)(c.g * 255.0f + 0.5f), b = (int)(c.b * 255.0f + 0.5f);
    return RGB(r < 0 ? 0 : r > 255 ? 255 : r, g < 0 ? 0 : g > 255 ? 255 : g, b < 0 ? 0 : b > 255 ? 255 : b);
}

int spdf_win_annot_dialog_trim(wchar_t* text) {
    size_t n, start = 0;
    if (!text) return 0;
    n = wcslen(text);
    while (n > 0 && iswspace(text[n - 1])) text[--n] = L'\0';
    while (start < n && iswspace(text[start])) ++start;
    if (start > 0) memmove(text, text + start, (n - start + 1) * sizeof(wchar_t));
    return (int)(n - start);
}

/* Read both fields into the caller's buffers, trimmed; the text loses the
 * CR of every CRLF an EDIT control produces, since the document and the
 * other two frontends keep LF. */
static void annot_capture(HWND hwnd, annot_dlg_state* st) {
    HWND a = GetDlgItem(hwnd, ANNOT_ID_AUTHOR);
    HWND t = GetDlgItem(hwnd, ANNOT_ID_TEXT);
    if (a && st->author && st->author_cap > 0) {
        GetWindowTextW(a, st->author, st->author_cap);
        spdf_win_annot_dialog_trim(st->author);
    }
    if (t && st->text && st->text_cap > 0) {
        wchar_t* raw = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)st->text_cap);
        int i, w = 0;
        if (!raw) return;
        GetWindowTextW(t, raw, st->text_cap);
        for (i = 0; raw[i] && w < st->text_cap - 1; ++i) {
            if (raw[i] == L'\r') continue;
            st->text[w++] = raw[i];
        }
        st->text[w] = L'\0';
        free(raw);
        spdf_win_annot_dialog_trim(st->text);
    }
}

static void annot_accept(HWND hwnd, annot_dlg_state* st) {
    if (!st || st->finished) return;
    annot_capture(hwnd, st);
    st->ok = 1;
    DestroyWindow(hwnd);
}

static LRESULT CALLBACK annot_wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    annot_dlg_state* st = (annot_dlg_state*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
        case WM_COMMAND:
            switch (LOWORD(wparam)) {
                case ANNOT_ID_OK:
                case IDOK: annot_accept(hwnd, st); return 0;
                case ANNOT_ID_CANCEL:
                case IDCANCEL: DestroyWindow(hwnd); return 0;
                default: break;
            }
            break;
        case WM_CTLCOLORSTATIC:
            if (st && st->dark) {
                SetTextColor((HDC)wparam, theme_ref(st->theme.label));
                SetBkColor((HDC)wparam, theme_ref(st->theme.band));
                return (LRESULT)st->bg;
            }
            break;
        case WM_CTLCOLOREDIT:
            if (st && st->dark) {
                SetTextColor((HDC)wparam, theme_ref(st->theme.label));
                SetBkColor((HDC)wparam, theme_ref(st->theme.field_fill));
                return (LRESULT)st->field;
            }
            break;
        case WM_ERASEBKGND:
            if (st && st->dark) {
                RECT r;
                GetClientRect(hwnd, &r);
                FillRect((HDC)wparam, &r, st->bg);
                return 1;
            }
            break;
        case WM_CLOSE: DestroyWindow(hwnd); return 0;
        case WM_DESTROY:
            if (st) st->finished = 1;
            /* Wake the modal loop for a SENT close -- the properties dialog's
             * WM_DESTROY says why a thread WM_NULL and not PostQuitMessage. */
            PostThreadMessageW(GetCurrentThreadId(), WM_NULL, 0, 0);
            return 0;
        default: break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static int annot_register_class(void) {
    static int registered = 0;
    WNDCLASSEXW cls;
    if (registered) return 1;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = annot_wnd_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); /* IDC_ARROW; see the properties dialog */
    cls.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    cls.lpszClassName = k_annot_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return 0;
    registered = 1;
    return 1;
}

static BOOL CALLBACK annot_set_font(HWND child, LPARAM font) {
    SendMessageW(child, WM_SETFONT, (WPARAM)font, TRUE);
    return TRUE;
}

/* One window, two layouts: with a comment field (the editor) or without (the
 * author prompt). `hint` is the one-line explanation under the title bar,
 * the mac's informativeText. `text` arrives with LF and is shown with CRLF. */
static int annot_run(HWND parent, int dark, const wchar_t* title, const wchar_t* hint, const wchar_t* ok_label,
                     wchar_t* author, int author_cap, wchar_t* text, int text_cap) {
    annot_dlg_state st;
    HWND hwnd, author_edit, text_edit = NULL;
    MSG msg;
    BOOL msg_got = 1; /* GetMessageW's answer: 0 is WM_QUIT, see spdf_win_modal_scope.h */
    RECT client;
    int y, w, h = text ? ANNOT_DLG_H : ANNOT_AUTHOR_DLG_H;
    wchar_t* prefill = NULL;

    if (!annot_register_class()) return 0;
    memset(&st, 0, sizeof(st));
    st.dark = dark;
    st.theme = spdf_win_chrome_theme_for(dark);
    st.bg = CreateSolidBrush(theme_ref(st.theme.band));
    st.field = CreateSolidBrush(theme_ref(st.theme.field_fill));
    st.author = author;
    st.author_cap = author_cap;
    st.text = text;
    st.text_cap = text_cap;
    if (text) {
        int i, n = 0;
        prefill = (wchar_t*)malloc(sizeof(wchar_t) * (wcslen(text) * 2 + 1));
        if (!prefill) {
            DeleteObject(st.bg);
            DeleteObject(st.field);
            return 0;
        }
        for (i = 0; text[i]; ++i) {
            if (text[i] == L'\n') prefill[n++] = L'\r';
            prefill[n++] = text[i];
        }
        prefill[n] = L'\0';
    }

    hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, k_annot_class, title,
                           WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, ANNOT_DLG_W, h,
                           parent, NULL, GetModuleHandleW(NULL), NULL);
    if (!hwnd) {
        free(prefill);
        DeleteObject(st.bg);
        DeleteObject(st.field);
        return 0;
    }
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)&st);
    spdf_win_about_dark_caption(hwnd, dark);
    GetClientRect(hwnd, &client);
    w = client.right - client.left - ANNOT_MARGIN * 2;
    y = ANNOT_MARGIN;

    CreateWindowExW(0, L"STATIC", hint, WS_CHILD | WS_VISIBLE, ANNOT_MARGIN, y, w, ANNOT_LABEL_H, hwnd, NULL,
                    GetModuleHandleW(NULL), NULL);
    y += ANNOT_LABEL_H + 8;
    CreateWindowExW(0, L"STATIC", L"Author", WS_CHILD | WS_VISIBLE, ANNOT_MARGIN, y, w, ANNOT_LABEL_H, hwnd, NULL,
                    GetModuleHandleW(NULL), NULL);
    y += ANNOT_LABEL_H;
    author_edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", author ? author : L"",
                                  WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, ANNOT_MARGIN, y, w,
                                  ANNOT_FIELD_H, hwnd, (HMENU)(INT_PTR)ANNOT_ID_AUTHOR, GetModuleHandleW(NULL), NULL);
    y += ANNOT_FIELD_H + 10;
    if (text) {
        int text_h = client.bottom - y - ANNOT_LABEL_H - ANNOT_MARGIN * 2 - ANNOT_BUTTON_H;
        if (text_h < 40) text_h = 40;
        CreateWindowExW(0, L"STATIC", L"Comment", WS_CHILD | WS_VISIBLE, ANNOT_MARGIN, y, w, ANNOT_LABEL_H, hwnd,
                        NULL, GetModuleHandleW(NULL), NULL);
        y += ANNOT_LABEL_H;
        text_edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", prefill,
                                    WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL |
                                        ES_WANTRETURN,
                                    ANNOT_MARGIN, y, w, text_h, hwnd, (HMENU)(INT_PTR)ANNOT_ID_TEXT,
                                    GetModuleHandleW(NULL), NULL);
    }
    CreateWindowExW(0, L"BUTTON", ok_label, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                    client.right - ANNOT_MARGIN - ANNOT_BUTTON_W * 2 - 8, client.bottom - ANNOT_MARGIN - ANNOT_BUTTON_H,
                    ANNOT_BUTTON_W, ANNOT_BUTTON_H, hwnd, (HMENU)(INT_PTR)ANNOT_ID_OK, GetModuleHandleW(NULL), NULL);
    CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                    client.right - ANNOT_MARGIN - ANNOT_BUTTON_W, client.bottom - ANNOT_MARGIN - ANNOT_BUTTON_H,
                    ANNOT_BUTTON_W, ANNOT_BUTTON_H, hwnd, (HMENU)(INT_PTR)ANNOT_ID_CANCEL, GetModuleHandleW(NULL),
                    NULL);
    EnumChildWindows(hwnd, annot_set_font, (LPARAM)GetStockObject(DEFAULT_GUI_FONT));
    free(prefill);

    /* CENTRED ON THE OWNER'S MONITOR before it is shown. CW_USEDEFAULT cascades
     * onto the PRIMARY display; with the app on a second one that is a modal
     * dialog the reader cannot see in front of a window they cannot click. */
    spdf_win_modal_place_on_owner(hwnd, parent);
    /* From here the owner is disabled, and there is no path out of this
     * function that leaves it that way -- see spdf_win_modal_scope.h. */
    SpdfWinModalGuard modal(parent);
    ShowWindow(hwnd, SW_SHOW);
    /* The caret goes to the comment, selected whole, so a prefilled selection
     * is accepted with Ctrl+Return or replaced by typing (GTK selects the
     * prefill too: gtk_text_buffer_select_range in annot_comment_text_view). */
    SetFocus(text_edit ? text_edit : author_edit);
    SendMessageW(text_edit ? text_edit : author_edit, EM_SETSEL, 0, -1);

    while (!st.finished && (msg_got = GetMessageW(&msg, NULL, 0, 0)) > 0) {
        if (msg.message == WM_KEYDOWN && msg.wParam == VK_RETURN && (GetKeyState(VK_CONTROL) & 0x8000)) {
            annot_accept(hwnd, &st);
            continue;
        }
        /* Tab between the controls, Escape as IDCANCEL, Return as the default
         * button everywhere but in the multi-line field, whose ES_WANTRETURN
         * keeps it as a new line. */
        if (IsDialogMessageW(hwnd, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    spdf_win_modal_requeue_quit(msg_got, &msg);
    modal.end();
    DeleteObject(st.bg);
    DeleteObject(st.field);
    return st.ok;
}

int spdf_win_annot_dialog_edit(void* parent, int dark, const wchar_t* title, const wchar_t* ok_label,
                               wchar_t* author, int author_cap, wchar_t* text, int text_cap) {
    if (!author || author_cap <= 0 || !text || text_cap <= 0) return 0;
    return annot_run((HWND)parent, dark, title ? title : L"Comment", L"Edit the comment author and text.",
                     ok_label ? ok_label : L"Save", author, author_cap, text, text_cap);
}

int spdf_win_annot_dialog_author(void* parent, int dark, wchar_t* author, int author_cap) {
    if (!author || author_cap <= 0) return 0;
    return annot_run((HWND)parent, dark, L"Set Author for Comments", L"New comments will use this author.", L"Save",
                     author, author_cap, NULL, 0);
}

int spdf_win_annot_dialog_confirm_delete(void* parent, int dark, const wchar_t* detail) {
    (void)dark; /* a MessageBox follows the system's theme; the app's own boxes follow the reading theme */
    return MessageBoxW((HWND)parent, detail ? detail : L"This will permanently remove the comment from the PDF.",
                       L"Delete Comment?", MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2) == IDOK;
}
