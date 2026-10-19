/* spdf_win_print_preview.cpp — the preview's WINDOW: the class, the painting
 * and the page stepper. What it is for and where every number comes from is
 * spdf_win_print_preview.h; the render pool is
 * spdf_win_print_preview_measure.cpp and the printer is
 * spdf_win_print_preview_sheet.cpp.
 *
 * A CHILD WINDOW, NOT A PAINT INSIDE THE DIALOG. The dialog is a plain window
 * with two dozen controls and a local modal loop (spdf_win_print_dialog.cpp);
 * making the preview one more child keeps its clipping, its invalidation and its
 * two stepper buttons out of that loop entirely, and means a dialog that could
 * not create it (a locked session, a driver that answers nothing) simply has no
 * preview rather than a hole in its paint.
 *
 * THE PAPER IS WHITE IN BOTH THEMES, and the unprintable band around it is grey
 * in both. That is not a theming oversight: the sheet is a picture OF PAPER, and
 * the page inside it carries the document's own colours because a print does
 * (spdf_win_export.h). The window's frame, its text and its buttons do follow
 * the app theme, because they are dialog chrome.
 */

#include "spdf_win_print_preview_internal.h"

#include "spdf_win_chrome_theme.h"

#include <uxtheme.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "uxtheme.lib")

static const wchar_t* k_preview_class = L"SpdfWinPrintPreview";

/* The paper, and the border it cannot print on. Literal in both themes. */
#define PV_PAPER_RGB RGB(255, 255, 255)
#define PV_UNPRINTABLE_RGB RGB(226, 226, 228)
#define PV_SHEET_EDGE_RGB RGB(138, 138, 142)
#define PV_PAGE_EDGE_RGB RGB(70, 110, 180)

/* At 96 dpi; everything goes through S(). Three text lines under the sheet — the
 * paper, the border, the scale actually in force — then the stepper. */
/* 17, not 15: the font is 13 px at 96 dpi and 20 at 144, and three lines at a
 * 15 px pitch put the descenders of one into the ascenders of the next --
 * measured on the 144 dpi display this was written on. */
#define PV_PAD 6
#define PV_TEXT_H 17
#define PV_TEXT_LINES 3
#define PV_STEP_H 26
#define PV_STEP_BTN 26

#define S(v) MulDiv((v), pv->dpi, 96)

static COLORREF theme_ref(SpdfWinChromeColor c) {
    return RGB((int)(c.r * 255.0f + 0.5f), (int)(c.g * 255.0f + 0.5f), (int)(c.b * 255.0f + 0.5f));
}

/* The pixels the SHEET may use: the client rect less the padding, the three
 * text lines and the stepper row. The stepper's row is reserved whether or not
 * it is shown, so the sheet does not resize when a range narrows to one page. */
static void preview_pane(spdf_win_print_preview* pv, RECT* out) {
    RECT client;
    GetClientRect(pv->hwnd, &client);
    out->left = S(PV_PAD);
    out->top = S(PV_PAD);
    out->right = client.right - S(PV_PAD);
    out->bottom = client.bottom - S(PV_PAD + PV_STEP_H + PV_TEXT_H * PV_TEXT_LINES);
    if (out->bottom < out->top) out->bottom = out->top;
}

/* --- what the reader is told in words ------------------------------------- */

static void preview_paper_line(const spdf_win_print_preview* pv, wchar_t* out, int cap) {
    double w_mm = pv->sheet.sheet_w_pt * 25.4 / 72.0;
    double h_mm = pv->sheet.sheet_h_pt * 25.4 / 72.0;
    _snwprintf_s(out, (size_t)cap, _TRUNCATE, L"Sheet %.0f \x00d7 %.0f mm, %s", w_mm, h_mm,
                 pv->sheet.sheet_w_pt > pv->sheet.sheet_h_pt ? L"landscape" : L"portrait");
}

/* The WIDEST of the four sides, because that is the one a reader loses content
 * to first, and it is stated rather than applied in silence. */
static void preview_border_line(const spdf_win_print_preview* pv, wchar_t* out, int cap) {
    double widest = pv->sheet.margin_l_pt;
    if (pv->sheet.margin_t_pt > widest) widest = pv->sheet.margin_t_pt;
    if (pv->sheet.margin_r_pt > widest) widest = pv->sheet.margin_r_pt;
    if (pv->sheet.margin_b_pt > widest) widest = pv->sheet.margin_b_pt;
    /* Kept short enough to fit the pane at every DPI: the line is clipped with
     * an ellipsis when it does not, and a caveat a reader cannot finish reading
     * is worse than no caveat. */
    if (!pv->sheet.sheet_measured)
        _snwprintf_s(out, (size_t)cap, _TRUNCATE, L"Border estimated (driver reported none)");
    else if (widest <= 0.05) _snwprintf_s(out, (size_t)cap, _TRUNCATE, L"Prints to the very edge of the sheet");
    else
        _snwprintf_s(out, (size_t)cap, _TRUNCATE, L"Grey border: %.1f mm unprintable", widest * 25.4 / 72.0);
}

static void preview_scale_line(const spdf_win_print_preview* pv, wchar_t* out, int cap) {
    /* The mode's SHORT name: the radio above spells it out, and the number is
     * what only the preview can say. The long form did not fit the pane. */
    const wchar_t* name = pv->choice.mode == SPDF_WIN_PRINT_SCALING_ACTUAL   ? L"Actual size"
                          : pv->choice.mode == SPDF_WIN_PRINT_SCALING_CUSTOM ? L"Custom"
                                                                             : L"Fit";
    /* mode_scale is spdf_win_print_mode_scale()'s own answer, not a second
     * calculation of it: at Fit it is what the paper forced, which is the number
     * a reader cannot work out for themselves. */
    _snwprintf_s(out, (size_t)cap, _TRUNCATE, L"%s \x2014 %.0f%% of actual size", name, pv->layout.mode_scale * 100.0);
}

/* --- painting ------------------------------------------------------------- */

static void preview_paint_sheet(spdf_win_print_preview* pv, HDC dc, const RECT* pane) {
    const spdf_win_preview_tile* tile = spdf_win_preview_tile_now(pv);
    HBRUSH paper = CreateSolidBrush(PV_PAPER_RGB);
    HBRUSH unprintable = CreateSolidBrush(PV_UNPRINTABLE_RGB);
    HBRUSH sheet_edge = CreateSolidBrush(PV_SHEET_EDGE_RGB);
    HPEN page_pen = CreatePen(PS_SOLID, 1, PV_PAGE_EDGE_RGB);
    HGDIOBJ old_pen;
    HGDIOBJ old_brush;
    RECT r;
    int saved;

    /* The whole sheet in the unprintable tone, then the printable area in paper
     * white on top of it: the band that is left IS the driver's margin, drawn
     * rather than applied behind the reader's back. */
    r.left = pane->left + (int)(pv->layout.sheet.x + 0.5);
    r.top = pane->top + (int)(pv->layout.sheet.y + 0.5);
    r.right = r.left + (int)(pv->layout.sheet.w + 0.5);
    r.bottom = r.top + (int)(pv->layout.sheet.h + 0.5);
    FillRect(dc, &r, unprintable);
    FrameRect(dc, &r, sheet_edge);
    saved = SaveDC(dc);
    IntersectClipRect(dc, r.left, r.top, r.right, r.bottom);

    r.left = pane->left + (int)(pv->layout.image.x + 0.5);
    r.top = pane->top + (int)(pv->layout.image.y + 0.5);
    r.right = r.left + (int)(pv->layout.image.w + 0.5);
    r.bottom = r.top + (int)(pv->layout.image.h + 0.5);
    FillRect(dc, &r, paper);

    /* THE PAGE, exactly where spdf_win_print_dest_rect() put it, clipped to the
     * sheet — an Actual Size or large Custom page genuinely does hang off the
     * paper, and hiding that would be the one thing this window exists to
     * prevent. */
    r.left = pane->left + (int)(pv->layout.page.x + 0.5);
    r.top = pane->top + (int)(pv->layout.page.y + 0.5);
    r.right = r.left + (int)(pv->layout.page.w + 0.5);
    r.bottom = r.top + (int)(pv->layout.page.h + 0.5);
    FillRect(dc, &r, paper);
    if (tile) {
        BITMAPINFOHEADER bi;
        memset(&bi, 0, sizeof(bi));
        bi.biSize = sizeof(bi);
        bi.biWidth = tile->width;
        bi.biHeight = -tile->height; /* negative: the tile is top-down */
        bi.biPlanes = 1;
        bi.biBitCount = 32;
        bi.biCompression = BI_RGB;
        SetStretchBltMode(dc, HALFTONE);
        SetBrushOrgEx(dc, 0, 0, NULL);
        StretchDIBits(dc, r.left, r.top, r.right - r.left, r.bottom - r.top, 0, 0, tile->width, tile->height,
                      tile->bgra, (const BITMAPINFO*)&bi, DIB_RGB_COLORS, SRCCOPY);
    }
    old_pen = SelectObject(dc, page_pen);
    old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    Rectangle(dc, r.left, r.top, r.right, r.bottom);
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    RestoreDC(dc, saved);
    DeleteObject(page_pen);
    DeleteObject(sheet_edge);
    DeleteObject(unprintable);
    DeleteObject(paper);
}

static void preview_paint(spdf_win_print_preview* pv, HDC dc) {
    SpdfWinChromeTheme t = spdf_win_chrome_theme_for(pv->dark);
    HGDIOBJ old_font;
    wchar_t line[192];
    RECT client;
    RECT pane;
    RECT text;
    int i;

    GetClientRect(pv->hwnd, &client);
    FillRect(dc, &client, pv->back);
    preview_pane(pv, &pane);

    old_font = SelectObject(dc, pv->font);
    SetBkMode(dc, TRANSPARENT);
    if (!pv->layout.valid) {
        SetTextColor(dc, theme_ref(t.label_secondary));
        /* FOUR DIFFERENT THINGS, and a reader is told which. A printer still
         * being asked is not a printer that answered nothing, and neither is a
         * page the core could not measure. */
        _snwprintf_s(line, _TRUNCATE, L"%s",
                     !pv->printers || pv->printers->count <= 0 ? L"No printer to preview."
                     : pv->measuring                           ? L"Measuring the printer\x2026"
                     : pv->have_sheet                          ? L"This page could not be measured."
                                                               : L"This printer did not report a page size.");
        DrawTextW(dc, line, -1, &pane, DT_CENTER | DT_VCENTER | DT_WORDBREAK);
        SelectObject(dc, old_font);
        return;
    }
    preview_paint_sheet(pv, dc, &pane);

    text.left = S(PV_PAD);
    text.right = client.right - S(PV_PAD);
    for (i = 0; i < PV_TEXT_LINES; ++i) {
        text.top = pane.bottom + i * S(PV_TEXT_H);
        text.bottom = text.top + S(PV_TEXT_H);
        if (i == 0) preview_paper_line(pv, line, 192);
        else if (i == 1) preview_border_line(pv, line, 192);
        else preview_scale_line(pv, line, 192);
        /* The paper and the scale are facts about this print; the border line is
         * a caveat, so it takes the quieter colour the dialog's own note does. */
        SetTextColor(dc, theme_ref(i == 1 ? t.label_secondary : t.label));
        DrawTextW(dc, line, -1, &text, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    }
    if (!spdf_win_preview_tile_now(pv) && pv->doc_path_utf8[0]) {
        text.top = pane.top;
        text.bottom = pane.bottom;
        SetTextColor(dc, theme_ref(t.label_secondary));
        DrawTextW(dc, L"Rendering\x2026", -1, &text, DT_CENTER | DT_BOTTOM | DT_SINGLELINE);
    }
    SelectObject(dc, old_font);
}

/* --- the stepper ---------------------------------------------------------- */

static void preview_step(spdf_win_print_preview* pv, int by) {
    int at = pv->at + by;
    if (pv->page_count <= 0) return;
    if (at < 0 || at >= pv->page_count) return;
    pv->at = at;
    spdf_win_print_preview_invalidate(pv);
}

void spdf_win_print_preview_invalidate(spdf_win_print_preview* pv) {
    RECT pane;
    wchar_t label[64];
    int many;

    if (!pv || !pv->hwnd) return;
    preview_pane(pv, &pane);
    spdf_win_preview_relayout(pv, pane.right - pane.left, pane.bottom - pane.top);

    /* A ONE-PAGE RANGE HAS NO STEPPER, rather than two arrows that do nothing:
     * a dead control is a question a reader has to answer for themselves. */
    many = pv->page_count > 1;
    if (many && pv->at >= 0)
        _snwprintf_s(label, _TRUNCATE, L"Page %d of %d", pv->pages[pv->at] + 1, pv->doc_page_count);
    else label[0] = L'\0';
    SetWindowTextW(pv->count_label, label);
    ShowWindow(pv->prev_button, many ? SW_SHOW : SW_HIDE);
    ShowWindow(pv->next_button, many ? SW_SHOW : SW_HIDE);
    ShowWindow(pv->count_label, many ? SW_SHOW : SW_HIDE);
    EnableWindow(pv->prev_button, many && pv->at > 0);
    EnableWindow(pv->next_button, many && pv->at + 1 < pv->page_count);
    InvalidateRect(pv->hwnd, NULL, FALSE);
}

/* --- the window ----------------------------------------------------------- */

static LRESULT CALLBACK preview_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    spdf_win_print_preview* pv = (spdf_win_print_preview*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

    if (!pv) return DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        case WM_ERASEBKGND: return 1; /* WM_PAINT fills every pixel */
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(hwnd, &ps);
            if (dc) preview_paint(pv, dc);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case SPDF_WIN_PREVIEW_WM_READY: spdf_win_preview_drain(pv); return 0;
        case SPDF_WIN_PREVIEW_WM_SHEET:
            /* A printer answered. `measuring` stays set while another request is
             * still outstanding, so clicking through printers does not flicker
             * between a sheet and a sentence. */
            pv->have_sheet = spdf_win_preview_measure_take(pv->measure, &pv->sheet, &pv->measuring);
            spdf_win_print_preview_invalidate(pv);
            return 0;
        case WM_SIZE: spdf_win_print_preview_invalidate(pv); return 0;
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLORBTN: {
            SpdfWinChromeTheme t = spdf_win_chrome_theme_for(pv->dark);
            SetBkMode((HDC)wparam, TRANSPARENT);
            SetTextColor((HDC)wparam, theme_ref(t.label));
            return (LRESULT)pv->back;
        }
        case WM_COMMAND:
            if (HIWORD(wparam) == BN_CLICKED) {
                if (LOWORD(wparam) == SPDF_WIN_PREVIEW_ID_PREV) preview_step(pv, -1);
                else if (LOWORD(wparam) == SPDF_WIN_PREVIEW_ID_NEXT) preview_step(pv, 1);
            }
            return 0;
        default: break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static int preview_register(void) {
    static int registered = 0;
    WNDCLASSEXW cls;
    if (registered) return 1;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = preview_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    /* MAKEINTRESOURCEW, not IDC_ARROW: this unit is built without UNICODE
     * defined, so the bare constant would expand to the ANSI form. */
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
    cls.lpszClassName = k_preview_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return 0;
    registered = 1;
    return 1;
}

static HWND preview_child(spdf_win_print_preview* pv, const wchar_t* cls, const wchar_t* text, DWORD style, int x,
                          int y, int w, int h, int id) {
    HWND child = CreateWindowExW(0, cls, text, style | WS_CHILD, x, y, w, h, pv->hwnd, (HMENU)(INT_PTR)id,
                                 GetModuleHandleW(NULL), NULL);
    if (!child) return NULL;
    SendMessageW(child, WM_SETFONT, (WPARAM)pv->font, TRUE);
    /* Dark mode strips the visual style, for the reason spdf_win_print_dialog.cpp
     * gives: a themed control paints its own label and ignores SetTextColor. */
    if (pv->dark) SetWindowTheme(child, L"", L"");
    return child;
}

spdf_win_print_preview* spdf_win_print_preview_create(HWND parent, int dark, int dpi, spdf_document* doc,
                                                      const char* doc_path_utf8,
                                                      const spdf_win_print_printers* printers, int page_count,
                                                      int current_page, int x, int y, int w, int h) {
    spdf_win_print_preview* pv;
    int step_y;
    int mid;

    if (!parent || page_count <= 0 || !preview_register()) return NULL;
    pv = (spdf_win_print_preview*)calloc(1, sizeof(*pv));
    if (!pv) return NULL;
    pv->dark = dark;
    pv->dpi = dpi >= 96 && dpi <= 480 ? dpi : 96;
    pv->doc = doc;
    pv->doc_page_count = page_count;
    pv->current_page = current_page;
    pv->printers = printers;
    pv->at = -1;
    pv->token_page = -1;
    pv->choice.mode = SPDF_WIN_PRINT_SCALING_FIT;
    pv->choice.custom_scale = 1.0;
    if (doc_path_utf8) strncpy_s(pv->doc_path_utf8, sizeof(pv->doc_path_utf8), doc_path_utf8, _TRUNCATE);
    pv->pages = (int*)calloc((size_t)page_count, sizeof(int));
    spdf_win_preview_tiles_clear(pv);
    if (!pv->pages) {
        free(pv);
        return NULL;
    }
    pv->back = CreateSolidBrush(theme_ref(spdf_win_chrome_theme_for(dark).panel));
    pv->font = CreateFontW(-MulDiv(13, pv->dpi, 96), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                           OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    pv->hwnd = CreateWindowExW(0, k_preview_class, NULL, WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, x, y, w, h, parent,
                               NULL, GetModuleHandleW(NULL), NULL);
    if (!pv->hwnd) {
        DeleteObject(pv->font);
        DeleteObject(pv->back);
        free(pv->pages);
        free(pv);
        return NULL;
    }
    SetWindowLongPtrW(pv->hwnd, GWLP_USERDATA, (LONG_PTR)pv);
    pv->measure = spdf_win_preview_measure_new(pv->hwnd);

    step_y = h - S(PV_PAD + PV_STEP_H);
    mid = w / 2;
    pv->prev_button = preview_child(pv, L"BUTTON", L"\x2039", BS_PUSHBUTTON | WS_TABSTOP, mid - S(PV_STEP_BTN + 62),
                                    step_y, S(PV_STEP_BTN), S(PV_STEP_H - 2), SPDF_WIN_PREVIEW_ID_PREV);
    pv->count_label = preview_child(pv, L"STATIC", L"", SS_CENTER, mid - S(58), step_y + S(4), S(116),
                                    S(PV_TEXT_H + 3), SPDF_WIN_PREVIEW_ID_COUNT);
    pv->next_button = preview_child(pv, L"BUTTON", L"\x203a", BS_PUSHBUTTON | WS_TABSTOP, mid + S(62), step_y,
                                    S(PV_STEP_BTN), S(PV_STEP_H - 2), SPDF_WIN_PREVIEW_ID_NEXT);
    return pv;
}

void spdf_win_print_preview_destroy(spdf_win_print_preview* pv) {
    if (!pv) return;
    /* THE SERVICE FIRST, and while the preview is still whole: freeing it
     * cancels everything in flight and then delivers each outstanding request on
     * this thread, and those callbacks touch the tiles below. The window goes
     * before that, so a worker's PostMessage after this point lands nowhere. */
    pv->hwnd = NULL;
    spdf_win_render_service_free(pv->service);
    /* THE MEASURING WORKER IS NOT WAITED FOR. It may be most of a minute inside
     * a network driver, and this call comes from a reader pressing Cancel. Its
     * window handle is cleared and this side's reference dropped; the worker
     * frees the mailbox when it finally comes back. */
    spdf_win_preview_measure_detach(pv->measure);
    spdf_win_preview_measure_release(pv->measure);
    spdf_win_preview_tiles_clear(pv);
    DeleteObject(pv->font);
    DeleteObject(pv->back);
    free(pv->devmode);
    free(pv->pages);
    free(pv);
}

int spdf_win_print_preview_page(const spdf_win_print_preview* pv) {
    if (!pv || pv->at < 0 || pv->at >= pv->page_count) return -1;
    return pv->pages[pv->at];
}

int spdf_win_print_preview_sheet(const spdf_win_print_preview* pv, spdf_win_preview_sheet* out) {
    if (!pv || !out) return 0;
    *out = pv->sheet;
    return pv->have_sheet;
}

#undef S
