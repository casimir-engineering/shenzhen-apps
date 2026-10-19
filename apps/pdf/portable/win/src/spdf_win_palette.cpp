/* spdf_win_palette.cpp — see spdf_win_palette.h. Direct2D + DirectWrite over a
 * WS_POPUP window, one modal loop, every decision delegated to the model. */
#include "spdf_win_palette.h"

#include "spdf_win_chrome_text.h"
#include "spdf_win_chrome_theme.h"
#include "spdf_win_paths.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <windowsx.h>

#include <d2d1.h>
#include <dwrite.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* NOTE: <windows.h> without UNICODE turns the token DrawText into DrawTextA
 * everywhere after it -- including inside <d2d1.h>, where the method is
 * declared. The call below therefore spells DrawText too, and both sides
 * expand to the same name; an #undef here would break exactly that. */

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "user32.lib")

namespace {

/* The mac panel's geometry, in points (ShenzhenPDFMac.mm :12261, :12294, :12385-12396). */
const float kWidth = 650.0f;
const float kFieldTop = 14.0f;
const float kFieldHeight = 34.0f;
const float kFieldGap = 8.0f;
const float kRowHeight = 42.0f;
const float kHeaderHeight = 32.0f;
const float kStatusHeight = 38.0f;
const float kBottomPad = 8.0f;
const float kSideInset = 14.0f;
const float kTopOffset = 88.0f; /* below the owner's top edge */
const float kMaxScreenFraction = 0.60f;

const wchar_t* const kClassName = L"ShenzhenPDF.Palette";
const wchar_t* const kPlaceholder = L"Favorites, open documents, and commands";

struct Palette {
    HWND hwnd;
    HWND owner;
    SpdfWinPaletteModel* model;
    SpdfWinPaletteChoice* out;
    float scale;
    int dark;
    SpdfWinChromeTheme theme;
    wchar_t query[256];
    int caret;
    float scroll;   /* first visible y of the list, in points */
    int hot;        /* row under the pointer, or -1 */
    int done;       /* 1 chosen, 2 dismissed */
    ID2D1Factory* d2d;
    ID2D1HwndRenderTarget* target;
    ID2D1SolidColorBrush* brush;
    IDWriteFactory* dwrite;
    IDWriteTextFormat* fmt_query;
    IDWriteTextFormat* fmt_title;
    IDWriteTextFormat* fmt_subtitle;
    IDWriteTextFormat* fmt_header;
    IDWriteTextFormat* fmt_accel;
};

template <class T> void release(T*& p) {
    if (p) p->Release();
    p = NULL;
}

D2D1_COLOR_F color(const SpdfWinChromeColor& c) { return D2D1::ColorF(c.r, c.g, c.b, c.a); }

IDWriteTextFormat* make_format(IDWriteFactory* dw, float size, DWRITE_FONT_WEIGHT weight, int trim) {
    IDWriteTextFormat* fmt = NULL;
    if (FAILED(dw->CreateTextFormat(SPDF_WIN_CT_FONT_FAMILY, NULL, weight, DWRITE_FONT_STYLE_NORMAL,
                                    DWRITE_FONT_STRETCH_NORMAL, size, L"", &fmt)) &&
        FAILED(dw->CreateTextFormat(SPDF_WIN_CT_FONT_FAMILY_FALLBACK, NULL, weight, DWRITE_FONT_STYLE_NORMAL,
                                    DWRITE_FONT_STRETCH_NORMAL, size, L"", &fmt)))
        return NULL;
    fmt->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    fmt->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    if (trim) {
        DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        IDWriteInlineObject* ellipsis = NULL;
        if (SUCCEEDED(dw->CreateEllipsisTrimmingSign(fmt, &ellipsis)) && ellipsis) {
            fmt->SetTrimming(&trimming, ellipsis);
            ellipsis->Release();
        }
    }
    return fmt;
}

/* --- layout ---------------------------------------------------------------- */

float row_height(const Palette* p, int i) {
    const SpdfWinPaletteRow* r = spdf_win_palette_model_row(p->model, i);
    if (!r) return 0.0f;
    if (r->kind == SPDF_WIN_PALETTE_ROW_STATUS) return kStatusHeight;
    return kRowHeight + (spdf_win_palette_model_section_starts(p->model, i) ? kHeaderHeight : 0.0f);
}

float rows_height(const Palette* p) {
    float h = 0.0f;
    int n = spdf_win_palette_model_row_count(p->model);
    for (int i = 0; i < n; ++i) h += row_height(p, i);
    return h;
}

float list_top() { return kFieldTop + kFieldHeight + kFieldGap; }

/* The panel's height in points for its current rows, capped at 60% of the
 * owner's monitor (mac updatePalettePanelFramePreservingTop). */
float panel_height(const Palette* p) {
    float ideal = list_top() + rows_height(p) + kBottomPad + 10.0f;
    float min_h = list_top() + kRowHeight + kBottomPad;
    HMONITOR mon = MonitorFromWindow(p->owner, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    float max_h = 600.0f;
    mi.cbSize = sizeof(mi);
    if (mon && GetMonitorInfoW(mon, &mi))
        max_h = floorf((float)(mi.rcWork.bottom - mi.rcWork.top) / p->scale * kMaxScreenFraction);
    if (ideal < min_h) ideal = min_h;
    if (ideal > max_h) ideal = max_h;
    return ceilf(ideal);
}

void place_window(Palette* p) {
    RECT owner;
    float h = panel_height(p);
    int w_px = (int)(kWidth * p->scale), h_px = (int)(h * p->scale);
    GetWindowRect(p->owner, &owner);
    int x = (owner.left + owner.right) / 2 - w_px / 2;
    int y = owner.top + (int)(kTopOffset * p->scale);
    HMONITOR mon = MonitorFromWindow(p->owner, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (mon && GetMonitorInfoW(mon, &mi)) {
        if (x + w_px > mi.rcWork.right) x = mi.rcWork.right - w_px;
        if (x < mi.rcWork.left) x = mi.rcWork.left;
        if (y + h_px > mi.rcWork.bottom) y = mi.rcWork.bottom - h_px;
        if (y < mi.rcWork.top) y = mi.rcWork.top;
    }
    SetWindowPos(p->hwnd, NULL, x, y, w_px, h_px, SWP_NOZORDER | SWP_NOACTIVATE);
    if (p->target) p->target->Resize(D2D1::SizeU((UINT32)w_px, (UINT32)h_px));
}

/* Keep the selected row (and its header) in view: GTK palette_scroll_to_row. */
void scroll_to_selection(Palette* p) {
    int sel = spdf_win_palette_model_selected(p->model);
    float y = 0.0f, visible = panel_height(p) - list_top() - kBottomPad;
    if (sel < 0) {
        p->scroll = 0.0f;
        return;
    }
    for (int i = 0; i < sel; ++i) y += row_height(p, i);
    float bottom = y + row_height(p, sel);
    if (y < p->scroll) p->scroll = y;
    else if (bottom > p->scroll + visible) p->scroll = bottom - visible;
    float total = rows_height(p);
    if (p->scroll > total - visible) p->scroll = total > visible ? total - visible : 0.0f;
    if (p->scroll < 0.0f) p->scroll = 0.0f;
}

int row_at(const Palette* p, float y_pt) {
    float y = list_top() - p->scroll;
    int n = spdf_win_palette_model_row_count(p->model);
    for (int i = 0; i < n; ++i) {
        float h = row_height(p, i);
        float header = spdf_win_palette_model_section_starts(p->model, i) ? kHeaderHeight : 0.0f;
        if (y_pt >= y + header && y_pt < y + h) return i;
        y += h;
    }
    return -1;
}

/* --- the query ------------------------------------------------------------- */

void requery(Palette* p) {
    char utf8[1024];
    if (spdf_win_utf8_from_utf16((const spdf_wchar*)p->query, utf8, sizeof(utf8)) == SPDF_WIN_CONV_ERROR) utf8[0] = 0;
    spdf_win_palette_model_set_query(p->model, utf8);
    p->scroll = 0.0f;
    p->hot = -1;
    place_window(p);
    scroll_to_selection(p);
    InvalidateRect(p->hwnd, NULL, FALSE);
}

void choose(Palette* p, int index) {
    const SpdfWinPaletteRow* r = spdf_win_palette_model_row(p->model, index);
    if (!r || r->kind == SPDF_WIN_PALETTE_ROW_STATUS) return;
    memset(p->out, 0, sizeof(*p->out));
    p->out->kind = r->kind;
    p->out->command = r->command;
    p->out->doc = r->doc;
    p->out->page = r->page;
    strcpy_s(p->out->path, sizeof(p->out->path), r->path);
    p->done = 1;
}

/* --- painting -------------------------------------------------------------- */

void draw_text(Palette* p, IDWriteTextFormat* fmt, const wchar_t* text, D2D1_RECT_F rect,
               const SpdfWinChromeColor& c, DWRITE_TEXT_ALIGNMENT align) {
    if (!text || !text[0]) return;
    fmt->SetTextAlignment(align);
    p->brush->SetColor(color(c));
    p->target->DrawText(text, (UINT32)wcslen(text), fmt, rect, p->brush, D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

void draw_utf8(Palette* p, IDWriteTextFormat* fmt, const char* utf8, D2D1_RECT_F rect, const SpdfWinChromeColor& c,
               DWRITE_TEXT_ALIGNMENT align) {
    wchar_t wide[1200];
    if (!utf8 || !utf8[0]) return;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) <= 0) return;
    draw_text(p, fmt, wide, rect, c, align);
}

void paint(Palette* p) {
    if (!p->target) return;
    D2D1_SIZE_F size = p->target->GetSize();
    float s = p->scale, w = size.width / s, h = size.height / s;
    p->target->BeginDraw();
    p->target->SetTransform(D2D1::Matrix3x2F::Scale(s, s));
    p->target->Clear(color(p->theme.band));

    /* The search field. */
    D2D1_RECT_F field = D2D1::RectF(kSideInset, kFieldTop, w - kSideInset, kFieldTop + kFieldHeight);
    D2D1_ROUNDED_RECT rr = D2D1::RoundedRect(field, 6.0f, 6.0f);
    p->brush->SetColor(color(p->theme.field_fill));
    p->target->FillRoundedRectangle(rr, p->brush);
    p->brush->SetColor(color(p->theme.field_stroke));
    p->target->DrawRoundedRectangle(rr, p->brush, 1.0f);
    D2D1_RECT_F text_rect = D2D1::RectF(field.left + 10.0f, field.top, field.right - 10.0f, field.bottom);
    if (p->query[0]) draw_text(p, p->fmt_query, p->query, text_rect, p->theme.label, DWRITE_TEXT_ALIGNMENT_LEADING);
    else draw_text(p, p->fmt_query, kPlaceholder, text_rect, p->theme.field_placeholder, DWRITE_TEXT_ALIGNMENT_LEADING);
    /* The caret, at the end of the text. */
    {
        IDWriteTextLayout* layout = NULL;
        float caret_x = text_rect.left;
        if (p->query[0] && SUCCEEDED(p->dwrite->CreateTextLayout(p->query, (UINT32)wcslen(p->query), p->fmt_query,
                                                                 10000.0f, kFieldHeight, &layout)) &&
            layout) {
            DWRITE_TEXT_METRICS m;
            if (SUCCEEDED(layout->GetMetrics(&m))) caret_x += m.widthIncludingTrailingWhitespace;
            layout->Release();
        }
        p->brush->SetColor(color(p->theme.accent));
        p->target->FillRectangle(D2D1::RectF(caret_x + 1.0f, field.top + 8.0f, caret_x + 2.0f, field.bottom - 8.0f),
                                 p->brush);
    }

    /* The rows, clipped to the list area. */
    D2D1_RECT_F list = D2D1::RectF(0.0f, list_top(), w, h - kBottomPad);
    p->target->PushAxisAlignedClip(list, D2D1_ANTIALIAS_MODE_ALIASED);
    float y = list_top() - p->scroll;
    int n = spdf_win_palette_model_row_count(p->model);
    int sel = spdf_win_palette_model_selected(p->model);
    for (int i = 0; i < n && y < h; ++i) {
        const SpdfWinPaletteRow* r = spdf_win_palette_model_row(p->model, i);
        float rh = row_height(p, i);
        if (y + rh < list.top) {
            y += rh;
            continue;
        }
        if (r->kind == SPDF_WIN_PALETTE_ROW_STATUS) {
            draw_utf8(p, p->fmt_subtitle, r->title, D2D1::RectF(kSideInset, y, w - kSideInset, y + kStatusHeight),
                      p->theme.label_secondary, DWRITE_TEXT_ALIGNMENT_CENTER);
            y += rh;
            continue;
        }
        if (spdf_win_palette_model_section_starts(p->model, i)) {
            draw_utf8(p, p->fmt_header, spdf_win_palette_section_title(r->section),
                      D2D1::RectF(kSideInset + 4.0f, y + 6.0f, w - kSideInset, y + kHeaderHeight),
                      p->theme.label_secondary, DWRITE_TEXT_ALIGNMENT_LEADING);
            y += kHeaderHeight;
        }
        D2D1_RECT_F row = D2D1::RectF(kSideInset - 6.0f, y, w - kSideInset + 6.0f, y + kRowHeight);
        if (i == sel || i == p->hot) {
            p->brush->SetColor(color(i == sel ? p->theme.row_selected_fill : p->theme.row_hot_fill));
            p->target->FillRoundedRectangle(D2D1::RoundedRect(row, 5.0f, 5.0f), p->brush);
        }
        float accel_w = r->accel[0] ? 110.0f : 0.0f;
        float text_left = kSideInset + 8.0f, text_right = w - kSideInset - 8.0f - accel_w;
        char title[300];
        _snprintf_s(title, sizeof(title), _TRUNCATE, "%s%s", r->toggled ? "\xE2\x9C\x93 " : "", r->title);
        if (r->subtitle[0]) {
            draw_utf8(p, p->fmt_title, title, D2D1::RectF(text_left, y + 3.0f, text_right, y + 23.0f), p->theme.label,
                      DWRITE_TEXT_ALIGNMENT_LEADING);
            draw_utf8(p, p->fmt_subtitle, r->subtitle, D2D1::RectF(text_left, y + 22.0f, text_right, y + 39.0f),
                      p->theme.label_secondary, DWRITE_TEXT_ALIGNMENT_LEADING);
        } else {
            draw_utf8(p, p->fmt_title, title, D2D1::RectF(text_left, y, text_right, y + kRowHeight), p->theme.label,
                      DWRITE_TEXT_ALIGNMENT_LEADING);
        }
        if (r->accel[0])
            draw_utf8(p, p->fmt_accel, r->accel, D2D1::RectF(text_right, y, w - kSideInset - 8.0f, y + kRowHeight),
                      p->theme.label_secondary, DWRITE_TEXT_ALIGNMENT_TRAILING);
        y += kRowHeight;
    }
    p->target->PopAxisAlignedClip();

    /* A hairline frame, so the popup reads as a panel over the document. */
    p->brush->SetColor(color(p->theme.separator));
    p->target->DrawRectangle(D2D1::RectF(0.5f, 0.5f, w - 0.5f, h - 0.5f), p->brush, 1.0f);
    if (p->target->EndDraw() == D2DERR_RECREATE_TARGET) release(p->target);
}

/* --- the window ------------------------------------------------------------ */

int create_device(Palette* p) {
    RECT rc;
    GetClientRect(p->hwnd, &rc);
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &p->d2d))) return 0;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                   reinterpret_cast<IUnknown**>(&p->dwrite))))
        return 0;
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties();
    D2D1_HWND_RENDER_TARGET_PROPERTIES hprops =
        D2D1::HwndRenderTargetProperties(p->hwnd, D2D1::SizeU((UINT32)(rc.right - rc.left), (UINT32)(rc.bottom - rc.top)));
    if (FAILED(p->d2d->CreateHwndRenderTarget(props, hprops, &p->target))) return 0;
    if (FAILED(p->target->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &p->brush))) return 0;
    p->fmt_query = make_format(p->dwrite, 15.0f, DWRITE_FONT_WEIGHT_NORMAL, 0);
    p->fmt_title = make_format(p->dwrite, 13.0f, DWRITE_FONT_WEIGHT_NORMAL, 1);
    p->fmt_subtitle = make_format(p->dwrite, 11.0f, DWRITE_FONT_WEIGHT_NORMAL, 1);
    p->fmt_header = make_format(p->dwrite, 11.0f, DWRITE_FONT_WEIGHT_SEMI_BOLD, 0);
    p->fmt_accel = make_format(p->dwrite, 12.0f, DWRITE_FONT_WEIGHT_NORMAL, 0);
    return p->fmt_query && p->fmt_title && p->fmt_subtitle && p->fmt_header && p->fmt_accel;
}

void destroy_device(Palette* p) {
    release(p->fmt_accel);
    release(p->fmt_header);
    release(p->fmt_subtitle);
    release(p->fmt_title);
    release(p->fmt_query);
    release(p->brush);
    release(p->target);
    release(p->dwrite);
    release(p->d2d);
}

LRESULT CALLBACK palette_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    Palette* p = (Palette*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (msg == WM_NCCREATE) {
        p = (Palette*)((CREATESTRUCTW*)lparam)->lpCreateParams;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)p);
        p->hwnd = hwnd;
        return TRUE;
    }
    if (!p) return DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            BeginPaint(hwnd, &ps);
            paint(p);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_ERASEBKGND: return 1;
        case WM_KEYDOWN:
            switch (wparam) {
                case VK_ESCAPE: p->done = 2; return 0;
                case VK_RETURN: choose(p, spdf_win_palette_model_selected(p->model)); return 0;
                case VK_UP:
                case VK_DOWN:
                    spdf_win_palette_model_move(p->model, wparam == VK_DOWN ? 1 : -1);
                    scroll_to_selection(p);
                    InvalidateRect(hwnd, NULL, FALSE);
                    return 0;
                case VK_PRIOR:
                case VK_NEXT:
                    spdf_win_palette_model_move(p->model, wparam == VK_NEXT ? 8 : -8);
                    for (int i = 0; i < 7; ++i) spdf_win_palette_model_move(p->model, wparam == VK_NEXT ? 1 : -1);
                    scroll_to_selection(p);
                    InvalidateRect(hwnd, NULL, FALSE);
                    return 0;
                case VK_BACK:
                    if (spdf_win_text_backspace(p->query, &p->caret)) requery(p);
                    return 0;
                default: return 0;
            }
        case WM_CHAR:
            if (spdf_win_text_is_printable((unsigned)wparam) &&
                spdf_win_text_insert(p->query, (int)(sizeof(p->query) / sizeof(p->query[0])), &p->caret,
                                     (unsigned)wparam))
                requery(p);
            return 0;
        case WM_MOUSEMOVE: {
            int hot = row_at(p, (float)GET_Y_LPARAM(lparam) / p->scale);
            if (hot != p->hot) {
                p->hot = hot;
                InvalidateRect(hwnd, NULL, FALSE);
            }
            return 0;
        }
        case WM_LBUTTONDOWN: {
            int hit = row_at(p, (float)GET_Y_LPARAM(lparam) / p->scale);
            if (hit >= 0) {
                spdf_win_palette_model_select(p->model, hit);
                choose(p, hit);
            }
            return 0;
        }
        case WM_MOUSEWHEEL: {
            p->scroll -= (float)GET_WHEEL_DELTA_WPARAM(wparam) / WHEEL_DELTA * kRowHeight * 2.0f;
            float visible = panel_height(p) - list_top() - kBottomPad, total = rows_height(p);
            if (p->scroll > total - visible) p->scroll = total > visible ? total - visible : 0.0f;
            if (p->scroll < 0.0f) p->scroll = 0.0f;
            InvalidateRect(hwnd, NULL, FALSE);
            return 0;
        }
        case WM_ACTIVATE:
            /* The mac panel hidesOnDeactivate; a click anywhere else dismisses. */
            if (LOWORD(wparam) == WA_INACTIVE) p->done = 2;
            return 0;
        case WM_CLOSE: p->done = 2; return 0;
        default: return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
}

} /* namespace */

int spdf_win_palette_run(void* hwnd_owner, int dark, float dpi_scale, SpdfWinPaletteModel* model,
                         SpdfWinPaletteChoice* out) {
    static ATOM registered = 0;
    Palette p;
    MSG msg;
    if (!hwnd_owner || !model || !out) return -1;
    memset(&p, 0, sizeof(p));
    p.owner = (HWND)hwnd_owner;
    p.model = model;
    p.out = out;
    p.scale = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    p.dark = dark;
    p.theme = spdf_win_chrome_theme_for(dark);
    p.hot = -1;
    if (!registered) {
        WNDCLASSEXW wc;
        memset(&wc, 0, sizeof(wc));
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = palette_proc;
        wc.hInstance = GetModuleHandleW(NULL);
        wc.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); /* IDC_ARROW, spelled wide */
        wc.lpszClassName = kClassName;
        registered = RegisterClassExW(&wc);
        if (!registered) return -1;
    }
    spdf_win_palette_model_set_query(model, "");
    /* WS_EX_TOOLWINDOW: no taskbar button; owned, so it stays above its window
     * and goes away with it. Created hidden, placed, then shown. */
    HWND hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kClassName, L"Command", WS_POPUP, 0, 0, 10, 10,
                                p.owner, NULL, GetModuleHandleW(NULL), &p);
    if (!hwnd) return -1;
    if (!create_device(&p)) {
        destroy_device(&p);
        DestroyWindow(hwnd);
        return -1;
    }
    place_window(&p);
    ShowWindow(hwnd, SW_SHOWNA);
    SetForegroundWindow(hwnd);
    SetFocus(hwnd);
    SetActiveWindow(hwnd);
    InvalidateRect(hwnd, NULL, FALSE);

    while (!p.done && GetMessageW(&msg, NULL, 0, 0) > 0) {
        /* Keyboard input belongs to the palette whichever window has focus:
         * the owner must not scroll while the reader types a query. */
        if ((msg.message == WM_KEYDOWN || msg.message == WM_CHAR || msg.message == WM_KEYUP) && msg.hwnd != hwnd)
            msg.hwnd = hwnd;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (!p.done) PostQuitMessage(0); /* WM_QUIT arrived for the app: pass it on */
    destroy_device(&p);
    DestroyWindow(hwnd);
    SecureZeroMemory(p.query, sizeof(p.query));
    return p.done == 1 ? 1 : 0;
}
