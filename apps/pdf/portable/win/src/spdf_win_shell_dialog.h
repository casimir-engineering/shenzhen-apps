/* spdf_win_shell_dialog.h — one modal text prompt, built in memory.
 *
 * Two commands need to ask the reader for a line of text and nothing else: Open
 * Path... (a path) and the password prompt (a secret). Both are a Win32 dialog
 * with a message, one edit control and OK/Cancel, and the ONLY difference is
 * ES_PASSWORD. So there is one dialog, built from an in-memory DLGTEMPLATE --
 * this port ships no resource script, and adding one for two dialogs would put
 * a second build input beside the source list build-native.cmd discovers.
 *
 * WHY A REAL DIALOG AND NOT A DIRECT2D POPUP LIKE THE PALETTE. A password field
 * must behave exactly as every other password field on the desktop: masked
 * characters, no autocomplete, IME and screen-reader behaviour the system
 * defines, Ctrl+V and Shift+Insert working. An EDIT control with ES_PASSWORD is
 * that; a hand-drawn field would have to re-earn each of those. The same
 * argument spdf_win_chrome_text.h makes AGAINST an edit control for the find
 * field -- it would sit outside spdf_win_paint() -- does not apply here: a modal
 * prompt is not part of the window's frame and is never composed offscreen.
 *
 * SECRETS. The caller's buffer receives the text; this header keeps no copy.
 * The edit control's own text is cleared with an empty SetWindowText before the
 * dialog is destroyed, so the secret does not linger in the control's buffer
 * after the window is gone. Nothing here logs.
 *
 * Header-only, included by spdf_win_shell.cpp and spdf_win_password.cpp. Win32
 * only; not compiled into any test binary (a modal dialog cannot be shown on a
 * locked workstation, see windows-native-observations.md 4.6).
 */
#ifndef SPDF_WIN_SHELL_DIALOG_H
#define SPDF_WIN_SHELL_DIALOG_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <stdlib.h>
#include <string.h>

#define SPDF_WIN_SHELL_DLG_EDIT 1001
#define SPDF_WIN_SHELL_DLG_MESSAGE 1002
#define SPDF_WIN_SHELL_DLG_NOTE 1003

typedef struct SpdfWinShellPrompt {
    const wchar_t* message;
    const wchar_t* note; /* a second, quieter line ("Incorrect password."), or NULL */
    const wchar_t* ok_label;
    wchar_t* out;
    int out_cap;
    int password;
} SpdfWinShellPrompt;

/* --- the template ---------------------------------------------------------- */

typedef struct SpdfWinShellDlgBuf {
    WORD words[1024];
    size_t n;
} SpdfWinShellDlgBuf;

static void spdf_win_shell_dlg_word(SpdfWinShellDlgBuf* b, WORD w) {
    if (b->n < sizeof(b->words) / sizeof(b->words[0])) b->words[b->n++] = w;
}

static void spdf_win_shell_dlg_dword(SpdfWinShellDlgBuf* b, DWORD d) {
    spdf_win_shell_dlg_word(b, (WORD)(d & 0xFFFFu));
    spdf_win_shell_dlg_word(b, (WORD)(d >> 16));
}

static void spdf_win_shell_dlg_string(SpdfWinShellDlgBuf* b, const wchar_t* s) {
    for (; s && *s; ++s) spdf_win_shell_dlg_word(b, (WORD)*s);
    spdf_win_shell_dlg_word(b, 0);
}

static void spdf_win_shell_dlg_align(SpdfWinShellDlgBuf* b) {
    if (b->n & 1) spdf_win_shell_dlg_word(b, 0);
}

/* One DLGITEMTEMPLATE. `atom` is the predefined class: 0x0080 button, 0x0081
 * edit, 0x0082 static. Units are dialog units, as Win32 wants. */
static void spdf_win_shell_dlg_item(SpdfWinShellDlgBuf* b, DWORD style, short x, short y, short cx, short cy, WORD id,
                                    WORD atom, const wchar_t* text) {
    spdf_win_shell_dlg_align(b);
    spdf_win_shell_dlg_dword(b, style | WS_CHILD | WS_VISIBLE);
    spdf_win_shell_dlg_dword(b, 0); /* dwExtendedStyle */
    spdf_win_shell_dlg_word(b, (WORD)x);
    spdf_win_shell_dlg_word(b, (WORD)y);
    spdf_win_shell_dlg_word(b, (WORD)cx);
    spdf_win_shell_dlg_word(b, (WORD)cy);
    spdf_win_shell_dlg_word(b, id);
    spdf_win_shell_dlg_word(b, 0xFFFF);
    spdf_win_shell_dlg_word(b, atom);
    spdf_win_shell_dlg_string(b, text);
    spdf_win_shell_dlg_word(b, 0); /* no creation data */
}

static void spdf_win_shell_dlg_build(SpdfWinShellDlgBuf* b, const wchar_t* title, int password, const wchar_t* ok) {
    const short W = 300, H = 96;
    b->n = 0;
    spdf_win_shell_dlg_dword(b, DS_MODALFRAME | DS_SETFONT | DS_CENTER | WS_POPUP | WS_CAPTION | WS_SYSMENU);
    spdf_win_shell_dlg_dword(b, 0); /* dwExtendedStyle */
    spdf_win_shell_dlg_word(b, 6);  /* cdit */
    spdf_win_shell_dlg_word(b, 0);
    spdf_win_shell_dlg_word(b, 0);
    spdf_win_shell_dlg_word(b, (WORD)W);
    spdf_win_shell_dlg_word(b, (WORD)H);
    spdf_win_shell_dlg_word(b, 0); /* menu */
    spdf_win_shell_dlg_word(b, 0); /* class */
    spdf_win_shell_dlg_string(b, title);
    spdf_win_shell_dlg_word(b, 9); /* point size */
    spdf_win_shell_dlg_string(b, L"Segoe UI");
    spdf_win_shell_dlg_item(b, SS_LEFT | SS_NOPREFIX, 10, 10, W - 20, 20, SPDF_WIN_SHELL_DLG_MESSAGE, 0x0082, L"");
    spdf_win_shell_dlg_item(b, SS_LEFT | SS_NOPREFIX, 10, 30, W - 20, 10, SPDF_WIN_SHELL_DLG_NOTE, 0x0082, L"");
    spdf_win_shell_dlg_item(b,
                            WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL | ES_LEFT | (password ? ES_PASSWORD : 0), 10, 44,
                            W - 20, 14, SPDF_WIN_SHELL_DLG_EDIT, 0x0081, L"");
    spdf_win_shell_dlg_item(b, BS_DEFPUSHBUTTON | WS_TABSTOP, W - 120, H - 24, 50, 14, IDOK, 0x0080, ok);
    spdf_win_shell_dlg_item(b, BS_PUSHBUTTON | WS_TABSTOP, W - 62, H - 24, 50, 14, IDCANCEL, 0x0080, L"Cancel");
    /* A spacer static keeps cdit honest at 6 without a seventh visible thing. */
    spdf_win_shell_dlg_item(b, SS_LEFT, 0, 0, 0, 0, 0, 0x0082, L"");
}

/* --- the procedure --------------------------------------------------------- */

static INT_PTR CALLBACK spdf_win_shell_prompt_proc(HWND dlg, UINT msg, WPARAM wparam, LPARAM lparam) {
    SpdfWinShellPrompt* p = (SpdfWinShellPrompt*)GetWindowLongPtrW(dlg, DWLP_USER);
    switch (msg) {
        case WM_INITDIALOG:
            p = (SpdfWinShellPrompt*)lparam;
            SetWindowLongPtrW(dlg, DWLP_USER, (LONG_PTR)p);
            SetDlgItemTextW(dlg, SPDF_WIN_SHELL_DLG_MESSAGE, p->message ? p->message : L"");
            SetDlgItemTextW(dlg, SPDF_WIN_SHELL_DLG_NOTE, p->note ? p->note : L"");
            if (p->out && p->out_cap > 0 && !p->password) SetDlgItemTextW(dlg, SPDF_WIN_SHELL_DLG_EDIT, p->out);
            SendDlgItemMessageW(dlg, SPDF_WIN_SHELL_DLG_EDIT, EM_SETLIMITTEXT, (WPARAM)(p->out_cap - 1), 0);
            SetFocus(GetDlgItem(dlg, SPDF_WIN_SHELL_DLG_EDIT));
            /* Behind the Claude app or another window, a prompt that is not
             * foreground looks like a hang; a modal dialog may take the front. */
            SetForegroundWindow(dlg);
            return FALSE; /* focus was set by hand */
        case WM_COMMAND:
            if (LOWORD(wparam) == IDOK) {
                if (p && p->out && p->out_cap > 0) GetDlgItemTextW(dlg, SPDF_WIN_SHELL_DLG_EDIT, p->out, p->out_cap);
                SetDlgItemTextW(dlg, SPDF_WIN_SHELL_DLG_EDIT, L"");
                EndDialog(dlg, 1);
                return TRUE;
            }
            if (LOWORD(wparam) == IDCANCEL) {
                SetDlgItemTextW(dlg, SPDF_WIN_SHELL_DLG_EDIT, L"");
                EndDialog(dlg, 0);
                return TRUE;
            }
            break;
        case WM_CLOSE:
            SetDlgItemTextW(dlg, SPDF_WIN_SHELL_DLG_EDIT, L"");
            EndDialog(dlg, 0);
            return TRUE;
        default: break;
    }
    return FALSE;
}

/* Run the prompt. Returns 1 with `out` filled, 0 when cancelled, -1 when the
 * dialog could not be shown at all (a locked workstation, no desktop) -- which
 * is not a cancellation and callers must not report as one. For a password
 * prompt `out` is NOT pre-filled from its previous contents. */
static int spdf_win_shell_prompt_run(HWND owner, const wchar_t* title, const SpdfWinShellPrompt* prompt) {
    SpdfWinShellDlgBuf* buf = (SpdfWinShellDlgBuf*)calloc(1, sizeof(SpdfWinShellDlgBuf));
    INT_PTR rc;
    if (!buf) return -1;
    spdf_win_shell_dlg_build(buf, title, prompt->password, prompt->ok_label ? prompt->ok_label : L"OK");
    rc = DialogBoxIndirectParamW(GetModuleHandleW(NULL), (LPCDLGTEMPLATEW)buf->words, owner, spdf_win_shell_prompt_proc,
                                 (LPARAM)prompt);
    free(buf);
    if (rc == -1) return -1;
    return rc == 1 ? 1 : 0;
}

#endif /* SPDF_WIN_SHELL_DIALOG_H */
