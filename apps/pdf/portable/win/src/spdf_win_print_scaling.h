/* spdf_win_print_scaling.h — the print dialog's Scaling page: Fit / Actual
 * Size / Custom, as the macOS print accessory (SPDFMacPrintView.mm) and the GTK
 * print dialog's custom tab (spdf_print.c) offer it.
 *
 * TWO HALVES. The first is pure: how the page's three radio buttons and one
 * percentage field become a spdf_win_print_choice, and back. It compiles as C
 * with no Win32 and portable/win/tests/print_math_test.c drives it. The second
 * is the Win32 page itself -- an in-memory DLGTEMPLATE, because this port has
 * no resource script and a dialog resource would be the only thing in one; a
 * property sheet page built from it; and the dialog procedure that reads the
 * choice out on PSN_APPLY. PrintDlgEx hosts it as an extra tab beside its own
 * General page (PRINTDLGEX::lphPropertyPages), which is where Windows puts a
 * printing application's own options and where a reader looks for them.
 *
 * WHAT CANNOT BE TESTED HERE, AND IT IS NOT THE LOCK: the page only exists
 * inside PrintDlgEx, and PrintDlgExW does not return on this host at all --
 * with the session unlocked too (portable/docs/windows-print-dialog.md), while
 * the classic PrintDlgW, PageSetupDlg and the driver's own DocumentProperties
 * sheet all work. The same three choices are therefore also offered by the
 * port's own print dialog (spdf_win_print_dialog.h), which is what a reader
 * here actually sees.
 * Everything the page DECIDES is in the pure half, and the template builder is
 * deterministic arithmetic over WORDs; the dialog procedure is the two lines
 * that join them.
 */
#ifndef SPDF_WIN_PRINT_SCALING_H
#define SPDF_WIN_PRINT_SCALING_H

#include "spdf_win_print_math.h"

#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The reader's scaling choice: the mode, and the custom factor that applies
 * when the mode is CUSTOM. Persisted by the caller as settings.yaml
 * "printScalingMode" / "printCustomScale" (spdf_win_settings.h). */
typedef struct spdf_win_print_choice {
    spdf_win_print_scaling_mode mode;
    double custom_scale;
} spdf_win_print_choice;

/* --- the pure half -------------------------------------------------------- */

/* Control ids on the page. 101-103 are the radios in mode order, so
 * (id - SPDF_WIN_PRINT_ID_FIT) IS the spdf_win_print_scaling_mode. */
#define SPDF_WIN_PRINT_ID_GROUP 100
#define SPDF_WIN_PRINT_ID_FIT 101
#define SPDF_WIN_PRINT_ID_ACTUAL 102
#define SPDF_WIN_PRINT_ID_CUSTOM 103
#define SPDF_WIN_PRINT_ID_PERCENT 104
#define SPDF_WIN_PRINT_ID_PERCENT_SIGN 105
#define SPDF_WIN_PRINT_ID_NOTE 106

/* The custom scale as the whole-percent text the field shows: 1.5 -> "150".
 * Returns the length written. */
static SPDF_WIN_INLINE int spdf_win_print_percent_text(double custom_scale, wchar_t* out, int out_len) {
    int value, n = 0, d = 0;
    wchar_t digits[8];
    if (!out || out_len < 2) return 0;
    value = (int)(spdf_win_print_clamp_custom_scale(custom_scale) * 100.0 + 0.5);
    do {
        digits[d++] = (wchar_t)(L'0' + value % 10);
        value /= 10;
    } while (value > 0 && d < 7);
    while (d > 0 && n < out_len - 1) out[n++] = digits[--d];
    out[n] = L'\0';
    return n;
}

/* The page's state back into a choice: `which` is the checked radio as a mode
 * (0 fit, 1 actual, 2 custom; anything else is fit), `percent_text` is what
 * the field holds ("150", "  75 ", "" ...). A percentage that does not parse
 * or is out of range clamps the way SPDFClampPrintCustomScale does -- an empty
 * or nonsense field is 100%, 5 is 10%, 900 is 800%. Returns 1 when the choice
 * is CUSTOM and the text was usable as typed, 0 when it was corrected; the
 * caller does not need to care. */
static SPDF_WIN_INLINE int spdf_win_print_choice_from_page(int which, const wchar_t* percent_text,
                                                           spdf_win_print_choice* out) {
    double value = 0.0;
    int digits = 0, exact = 1;
    const wchar_t* p = percent_text ? percent_text : L"";
    if (!out) return 0;
    out->mode = (which == SPDF_WIN_PRINT_SCALING_ACTUAL || which == SPDF_WIN_PRINT_SCALING_CUSTOM)
                    ? (spdf_win_print_scaling_mode)which
                    : SPDF_WIN_PRINT_SCALING_FIT;
    while (*p == L' ' || *p == L'\t') ++p;
    while (*p >= L'0' && *p <= L'9') {
        value = value * 10.0 + (double)(*p - L'0');
        ++digits;
        ++p;
        if (digits > 7) break;
    }
    while (*p == L' ' || *p == L'\t' || *p == L'%') ++p;
    if (digits == 0 || *p != L'\0') {
        out->custom_scale = 1.0;
        return 0;
    }
    out->custom_scale = spdf_win_print_clamp_custom_scale(value / 100.0);
    if (out->custom_scale * 100.0 < value - 0.5 || out->custom_scale * 100.0 > value + 0.5) exact = 0;
    return out->mode == SPDF_WIN_PRINT_SCALING_CUSTOM && exact;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PRINT_SCALING_H -- the pure half */

/* --- the Win32 half -------------------------------------------------------
 *
 * Guarded on its own, because spdf_win_print.h includes this file for the
 * choice type with SPDF_WIN_PRINT_SCALING_PURE defined, and spdf_win_print.cpp
 * then includes it again without: the second include must still deliver the
 * page even though the first has set the guard above. */
#if defined(_WIN32) && !defined(SPDF_WIN_PRINT_SCALING_PURE) && !defined(SPDF_WIN_PRINT_SCALING_WIN32_H)
#define SPDF_WIN_PRINT_SCALING_WIN32_H

#include <windows.h>
#include <prsht.h>
#pragma comment(lib, "comctl32.lib")

/* An in-memory dialog template, word by word. DLGTEMPLATE and each
 * DLGITEMTEMPLATE are DWORD-aligned; strings are NUL-terminated UTF-16; a
 * control class given as 0xFFFF followed by an ordinal (0x0080 button, 0x0081
 * edit, 0x0082 static). Sizes are dialog units. */
typedef struct spdf_win_print_tpl {
    WORD buf[1024];
    size_t n;
} spdf_win_print_tpl;

static void tpl_word(spdf_win_print_tpl* t, WORD w) {
    if (t->n < sizeof(t->buf) / sizeof(t->buf[0])) t->buf[t->n++] = w;
}
static void tpl_dword(spdf_win_print_tpl* t, DWORD d) {
    tpl_word(t, (WORD)(d & 0xFFFFu));
    tpl_word(t, (WORD)(d >> 16));
}
static void tpl_str(spdf_win_print_tpl* t, const wchar_t* s) {
    for (; *s; ++s) tpl_word(t, (WORD)*s);
    tpl_word(t, 0);
}
static void tpl_align(spdf_win_print_tpl* t) {
    if (t->n & 1) tpl_word(t, 0);
}
static void tpl_item(spdf_win_print_tpl* t, DWORD style, int x, int y, int cx, int cy, WORD id, WORD cls,
                     const wchar_t* text) {
    tpl_align(t);
    tpl_dword(t, style | WS_CHILD | WS_VISIBLE);
    tpl_dword(t, 0);
    tpl_word(t, (WORD)x);
    tpl_word(t, (WORD)y);
    tpl_word(t, (WORD)cx);
    tpl_word(t, (WORD)cy);
    tpl_word(t, id);
    tpl_word(t, 0xFFFF);
    tpl_word(t, cls);
    tpl_str(t, text);
    tpl_word(t, 0); /* no creation data */
}

/* The page: a group with three radios, a percentage field and a note. The
 * wording is the macOS accessory's (Fit / Actual Size / Custom). */
static void spdf_win_print_scaling_template(spdf_win_print_tpl* t) {
    t->n = 0;
    tpl_dword(t, DS_SETFONT | DS_3DLOOK | WS_CHILD | WS_DISABLED | WS_CAPTION);
    tpl_dword(t, 0);
    tpl_word(t, 7); /* cdit */
    tpl_word(t, 0);
    tpl_word(t, 0);
    tpl_word(t, 252);
    tpl_word(t, 110);
    tpl_word(t, 0); /* no menu */
    tpl_word(t, 0); /* default class */
    tpl_str(t, L"Scaling");
    tpl_word(t, 8);
    tpl_str(t, L"MS Shell Dlg");
    tpl_item(t, BS_GROUPBOX, 7, 7, 238, 96, SPDF_WIN_PRINT_ID_GROUP, 0x0080, L"Scaling");
    tpl_item(t, BS_AUTORADIOBUTTON | WS_GROUP | WS_TABSTOP, 16, 24, 200, 10, SPDF_WIN_PRINT_ID_FIT, 0x0080,
             L"&Fit to the printable area");
    tpl_item(t, BS_AUTORADIOBUTTON, 16, 40, 200, 10, SPDF_WIN_PRINT_ID_ACTUAL, 0x0080, L"&Actual size (100%)");
    tpl_item(t, BS_AUTORADIOBUTTON, 16, 56, 60, 10, SPDF_WIN_PRINT_ID_CUSTOM, 0x0080, L"&Custom:");
    tpl_item(t, ES_NUMBER | ES_AUTOHSCROLL | WS_BORDER | WS_TABSTOP, 80, 54, 40, 12, SPDF_WIN_PRINT_ID_PERCENT,
             0x0081, L"");
    tpl_item(t, SS_LEFT, 124, 56, 20, 10, SPDF_WIN_PRINT_ID_PERCENT_SIGN, 0x0082, L"%");
    tpl_item(t, SS_LEFT, 16, 76, 222, 20, SPDF_WIN_PRINT_ID_NOTE, 0x0082,
             L"Fit shrinks or enlarges each page to the paper. Custom scales about the page centre; "
             L"10% to 800%.");
}

static void spdf_win_print_scaling_show(HWND page, const spdf_win_print_choice* c) {
    wchar_t text[16];
    int id = c->mode == SPDF_WIN_PRINT_SCALING_ACTUAL   ? SPDF_WIN_PRINT_ID_ACTUAL
             : c->mode == SPDF_WIN_PRINT_SCALING_CUSTOM ? SPDF_WIN_PRINT_ID_CUSTOM
                                                        : SPDF_WIN_PRINT_ID_FIT;
    CheckRadioButton(page, SPDF_WIN_PRINT_ID_FIT, SPDF_WIN_PRINT_ID_CUSTOM, id);
    spdf_win_print_percent_text(c->custom_scale, text, (int)(sizeof(text) / sizeof(text[0])));
    SetDlgItemTextW(page, SPDF_WIN_PRINT_ID_PERCENT, text);
    EnableWindow(GetDlgItem(page, SPDF_WIN_PRINT_ID_PERCENT), id == SPDF_WIN_PRINT_ID_CUSTOM);
}

static void spdf_win_print_scaling_read(HWND page, spdf_win_print_choice* c) {
    wchar_t text[32];
    int which = IsDlgButtonChecked(page, SPDF_WIN_PRINT_ID_CUSTOM) == BST_CHECKED   ? SPDF_WIN_PRINT_SCALING_CUSTOM
                : IsDlgButtonChecked(page, SPDF_WIN_PRINT_ID_ACTUAL) == BST_CHECKED ? SPDF_WIN_PRINT_SCALING_ACTUAL
                                                                                    : SPDF_WIN_PRINT_SCALING_FIT;
    GetDlgItemTextW(page, SPDF_WIN_PRINT_ID_PERCENT, text, (int)(sizeof(text) / sizeof(text[0])));
    spdf_win_print_choice_from_page(which, text, c);
}

/* The choice lives in the caller's frame for the life of the dialog; the page
 * keeps a pointer to it in its user data. */
static INT_PTR CALLBACK spdf_win_print_scaling_proc(HWND page, UINT msg, WPARAM wparam, LPARAM lparam) {
    spdf_win_print_choice* c = (spdf_win_print_choice*)GetWindowLongPtrW(page, DWLP_USER);
    switch (msg) {
        case WM_INITDIALOG:
            c = (spdf_win_print_choice*)((PROPSHEETPAGEW*)lparam)->lParam;
            SetWindowLongPtrW(page, DWLP_USER, (LONG_PTR)c);
            if (c) spdf_win_print_scaling_show(page, c);
            return TRUE;
        case WM_COMMAND:
            if (HIWORD(wparam) == BN_CLICKED && LOWORD(wparam) >= SPDF_WIN_PRINT_ID_FIT &&
                LOWORD(wparam) <= SPDF_WIN_PRINT_ID_CUSTOM)
                EnableWindow(GetDlgItem(page, SPDF_WIN_PRINT_ID_PERCENT), LOWORD(wparam) == SPDF_WIN_PRINT_ID_CUSTOM);
            return FALSE;
        case WM_NOTIFY: {
            const NMHDR* hdr = (const NMHDR*)lparam;
            /* PSN_APPLY is what PrintDlgEx sends every page when the reader
             * presses Print (or Apply); PSN_KILLACTIVE when they switch tabs.
             * Reading on both means the choice is current whichever came last. */
            if (hdr && (hdr->code == PSN_APPLY || hdr->code == PSN_KILLACTIVE) && c) {
                spdf_win_print_scaling_read(page, c);
                SetWindowLongPtrW(page, DWLP_MSGRESULT, hdr->code == PSN_APPLY ? PSNRET_NOERROR : FALSE);
                return TRUE;
            }
            return FALSE;
        }
        default: return FALSE;
    }
}

/* The page, ready for PRINTDLGEX::lphPropertyPages. `tpl` and `choice` must
 * outlive the dialog. NULL when it cannot be created, in which case the caller
 * prints with the choice it was given and shows the dialog without the tab. */
static HPROPSHEETPAGE spdf_win_print_scaling_page(spdf_win_print_tpl* tpl, spdf_win_print_choice* choice) {
    PROPSHEETPAGEW psp;
    spdf_win_print_scaling_template(tpl);
    memset(&psp, 0, sizeof(psp));
    psp.dwSize = sizeof(psp);
    psp.dwFlags = PSP_DLGINDIRECT | PSP_USETITLE;
    psp.pResource = (LPCDLGTEMPLATEW)tpl->buf;
    psp.pszTitle = L"Scaling";
    psp.pfnDlgProc = spdf_win_print_scaling_proc;
    psp.lParam = (LPARAM)choice;
    return CreatePropertySheetPageW(&psp);
}

#endif /* the Win32 half */
