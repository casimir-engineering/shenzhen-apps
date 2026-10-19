/* print_scaling_dialog_test.c — the print dialog's Scaling page, as a real Win32
 * dialog, without a printer and without showing anything.
 *
 * The page is an in-memory DLGTEMPLATE (spdf_win_print_scaling.h) that
 * PrintDlgEx hosts as a property sheet page. PrintDlgEx cannot be shown on a
 * locked workstation and needs a reader to dismiss it anywhere else, so the
 * template is exercised the other way round: CreateDialogIndirectParamW builds
 * a HIDDEN dialog from the very same WORDs, which is what proves the template
 * is well-formed -- a misaligned item or a wrong control count makes that call
 * fail, and PrintDlgEx would then quietly show the dialog without our tab. Then
 * the show/read pair the property page's WM_INITDIALOG and PSN_APPLY call is
 * driven directly against the controls: preset a choice, read it back,
 * change the radios and the field, read again.
 *
 * Header-only under test, so no `spdf-test-sources` line is needed. Creates
 * and destroys one invisible window; works on a locked workstation.
 */
#include "spdf_win_print_scaling.h"

#include <stdio.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static INT_PTR CALLBACK quiet_proc(HWND dlg, UINT msg, WPARAM wparam, LPARAM lparam) {
    (void)dlg;
    (void)msg;
    (void)wparam;
    (void)lparam;
    return FALSE;
}

int main(void) {
    spdf_win_print_tpl tpl;
    spdf_win_print_choice c;
    HWND parent, dlg;
    wchar_t text[32];
    int i;

    spdf_win_print_scaling_template(&tpl);
    CHECK(tpl.n > 0 && tpl.n < sizeof(tpl.buf) / sizeof(tpl.buf[0]));
    /* cdit is the 5th WORD of a DLGTEMPLATE: style (2), exstyle (2), cdit. */
    CHECK(tpl.buf[4] == 7);

    /* A property page is a WS_CHILD dialog -- the sheet is its parent -- so it
     * needs one here too (a top-level WS_CHILD is ERROR_TLW_WITH_WSCHILD, 1406).
     * A hidden static window stands in for the sheet. */
    parent = CreateWindowExW(0, L"STATIC", L"sheet", WS_OVERLAPPED, 0, 0, 400, 300, NULL, NULL,
                             GetModuleHandleW(NULL), NULL);
    CHECK(parent != NULL);
    /* The same WORDs PrintDlgEx gets, made into a dialog the user never sees:
     * neither the parent nor the template's style carries WS_VISIBLE. */
    dlg = CreateDialogIndirectParamW(GetModuleHandleW(NULL), (LPCDLGTEMPLATEW)tpl.buf, parent, quiet_proc, 0);
    CHECK(dlg != NULL);
    if (!dlg) {
        fprintf(stderr, "CreateDialogIndirectParamW failed (%lu): the template is malformed\n", GetLastError());
        printf("print_scaling_dialog_test: %d checks, %d failures\n", g_checks, g_failures);
        return 1;
    }
    CHECK(!IsWindowVisible(dlg));
    for (i = SPDF_WIN_PRINT_ID_GROUP; i <= SPDF_WIN_PRINT_ID_NOTE; ++i) CHECK(GetDlgItem(dlg, i) != NULL);
    GetWindowTextW(dlg, text, 32);
    CHECK(wcscmp(text, L"Scaling") == 0);

    /* Preset Custom 150%: the custom radio is checked, the field says 150 and is
     * enabled. */
    c.mode = SPDF_WIN_PRINT_SCALING_CUSTOM;
    c.custom_scale = 1.5;
    spdf_win_print_scaling_show(dlg, &c);
    CHECK(IsDlgButtonChecked(dlg, SPDF_WIN_PRINT_ID_CUSTOM) == BST_CHECKED);
    CHECK(IsDlgButtonChecked(dlg, SPDF_WIN_PRINT_ID_FIT) != BST_CHECKED);
    GetDlgItemTextW(dlg, SPDF_WIN_PRINT_ID_PERCENT, text, 32);
    CHECK(wcscmp(text, L"150") == 0);
    CHECK(IsWindowEnabled(GetDlgItem(dlg, SPDF_WIN_PRINT_ID_PERCENT)));
    memset(&c, 0, sizeof(c));
    spdf_win_print_scaling_read(dlg, &c);
    CHECK(c.mode == SPDF_WIN_PRINT_SCALING_CUSTOM);
    CHECK(c.custom_scale > 1.499 && c.custom_scale < 1.501);

    /* Preset Fit: the field is disabled but still carries the remembered 100%. */
    c.mode = SPDF_WIN_PRINT_SCALING_FIT;
    c.custom_scale = 1.0;
    spdf_win_print_scaling_show(dlg, &c);
    CHECK(IsDlgButtonChecked(dlg, SPDF_WIN_PRINT_ID_FIT) == BST_CHECKED);
    CHECK(!IsWindowEnabled(GetDlgItem(dlg, SPDF_WIN_PRINT_ID_PERCENT)));

    /* The reader picks Actual, types 75 into the field: read gives Actual with
     * the 75% remembered for the next time they pick Custom. */
    CheckRadioButton(dlg, SPDF_WIN_PRINT_ID_FIT, SPDF_WIN_PRINT_ID_CUSTOM, SPDF_WIN_PRINT_ID_ACTUAL);
    SetDlgItemTextW(dlg, SPDF_WIN_PRINT_ID_PERCENT, L"75");
    spdf_win_print_scaling_read(dlg, &c);
    CHECK(c.mode == SPDF_WIN_PRINT_SCALING_ACTUAL);
    CHECK(c.custom_scale > 0.749 && c.custom_scale < 0.751);

    /* And the property-sheet page itself can be created from the template. */
    {
        HPROPSHEETPAGE page = spdf_win_print_scaling_page(&tpl, &c);
        CHECK(page != NULL);
        if (page) DestroyPropertySheetPage(page);
    }

    DestroyWindow(dlg);
    DestroyWindow(parent);
    printf("print_scaling_dialog_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
