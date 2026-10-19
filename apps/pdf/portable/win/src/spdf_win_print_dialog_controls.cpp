/* spdf_win_print_dialog_controls.cpp — WHAT THE PRINT DIALOG'S CONTROLS SAY,
 * and which of them are live. Nothing else: no window is created here, no
 * printer is opened, no job is started.
 *
 * ITS OWN FILE BECAUSE THREE CALLERS SHARE IT. The dialog reads its controls
 * when the reader presses Print (spdf_win_print_dialog.cpp), the preview reads
 * the SAME controls after every change so it can follow
 * (spdf_win_print_preview_measure.cpp), and portable/win/tests/print_dialog_test.c
 * drives them from a second thread. Three private copies of "which radio is
 * checked, and what does the percentage field hold" would drift, and the first
 * symptom of that drift would be a preview showing one scale while the job used
 * another -- exactly the failure the preview exists to prevent.
 *
 * The ids are in spdf_win_print_dialog.h for the same reason.
 */

#include "spdf_win_print_dialog.h"

#pragma comment(lib, "user32.lib")

/* The checked radio in [first, last] as an offset from `first`, which IS the
 * mode: the range radios are in spdf_win_print_range_mode order and the scaling
 * radios in spdf_win_print_scaling_mode order. Nothing checked is 0, the first
 * of each group, which is also each group's default. */
static int print_dialog_checked(HWND dialog, int first, int last) {
    int id;
    for (id = first; id <= last; ++id)
        if (IsDlgButtonChecked(dialog, id) == BST_CHECKED) return id - first;
    return 0;
}

static int print_dialog_number(HWND dialog, int id, int fallback) {
    BOOL ok = FALSE;
    UINT value = GetDlgItemInt(dialog, id, &ok, FALSE);
    return ok ? (int)value : fallback;
}

void spdf_win_print_dialog_read_controls(HWND dialog, const spdf_win_print_printers* printers, int page_count,
                                         spdf_win_print_request* req) {
    wchar_t text[32];
    int at;

    if (!dialog || !req) return;
    at = (int)SendDlgItemMessageW(dialog, SPDF_WIN_PD_ID_PRINTER, CB_GETCURSEL, 0, 0);
    if (printers && at >= 0 && at < printers->count)
        wcsncpy_s(req->printer, SPDF_WIN_PRINT_NAME_MAX, printers->name[at], _TRUNCATE);
    req->range =
        (spdf_win_print_range_mode)print_dialog_checked(dialog, SPDF_WIN_PD_ID_RANGE_ALL, SPDF_WIN_PD_ID_RANGE_FROMTO);
    req->from = print_dialog_number(dialog, SPDF_WIN_PD_ID_FROM, 1);
    req->to = print_dialog_number(dialog, SPDF_WIN_PD_ID_TO, page_count);
    req->copies = print_dialog_number(dialog, SPDF_WIN_PD_ID_COPIES, 1);
    if (req->copies < 1) req->copies = 1;
    /* The percentage goes through spdf_win_print_choice_from_page() -- the same
     * clamping the Scaling tab in Windows' own dialog uses, so an empty field or
     * 900% means the same thing whichever dialog was shown. */
    GetDlgItemTextW(dialog, SPDF_WIN_PD_ID_PERCENT, text, (int)(sizeof(text) / sizeof(text[0])));
    spdf_win_print_choice_from_page(print_dialog_checked(dialog, SPDF_WIN_PD_ID_SCALE_FIT, SPDF_WIN_PD_ID_SCALE_CUSTOM),
                                    text, &req->choice);
}

/* A field is only enabled while the radio that gives it meaning is checked --
 * a page range nobody asked for should not look editable. */
void spdf_win_print_dialog_sync_enables(HWND dialog) {
    int range = print_dialog_checked(dialog, SPDF_WIN_PD_ID_RANGE_ALL, SPDF_WIN_PD_ID_RANGE_FROMTO);
    int scale = print_dialog_checked(dialog, SPDF_WIN_PD_ID_SCALE_FIT, SPDF_WIN_PD_ID_SCALE_CUSTOM);
    EnableWindow(GetDlgItem(dialog, SPDF_WIN_PD_ID_FROM), range == SPDF_WIN_PRINT_RANGE_FROM_TO);
    EnableWindow(GetDlgItem(dialog, SPDF_WIN_PD_ID_TO), range == SPDF_WIN_PRINT_RANGE_FROM_TO);
    EnableWindow(GetDlgItem(dialog, SPDF_WIN_PD_ID_PERCENT), scale == SPDF_WIN_PRINT_SCALING_CUSTOM);
}
