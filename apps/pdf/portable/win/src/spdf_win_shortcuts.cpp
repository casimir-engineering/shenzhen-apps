/* spdf_win_shortcuts.cpp — the window half of the F1 sheet. The rows come from
 * spdf_win_shortcuts_build() in the header; this only draws them.
 *
 * OWNER-DRAWN, GDI, IN THE CHROME THEME. Group headings in the label colour,
 * each shortcut's title in the label colour and its keys as keycaps -- rounded
 * rectangles in the control fill with the control stroke -- which is how the
 * GTK sheet (GtkShortcutsWindow) and the macOS panel draw theirs, and how
 * 26.7.17-1 describes them ("key labels ... centered inside their keycaps").
 * "Ctrl+PgDn or Ctrl+Tab" is split on " or " into two keycap runs, and each
 * run on "+" into its caps, so a chord reads as caps and not as a string.
 *
 * SCROLLABLE: a WS_VSCROLL bar over a virtual height computed from the rows,
 * with the wheel and the keyboard wired to it, because ~60 rows do not fit a
 * modal box on a laptop. Modal against the parent only, like the properties
 * dialog and the About box, for the reason they give.
 */
#include "spdf_win_shortcuts.h"

#include "spdf_win_about.h" /* spdf_win_about_dark_caption */
#include "spdf_win_chrome_theme.h"
#include "spdf_win_modal_scope.h"

#include <windows.h>
#include <windowsx.h>

#include <string.h>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")

#define SC_WIDTH 640
#define SC_HEIGHT 620
#define SC_MARGIN 20
#define SC_ROW_H 34
#define SC_GROUP_H 40
#define SC_GROUP_GAP 12
#define SC_CAP_H 24
#define SC_CAP_PAD 8
#define SC_CAP_GAP 4

static const wchar_t* k_sc_class = L"SpdfWinShortcutsSheet";

typedef struct sc_state {
    SpdfWinShortcutRow rows[SPDF_WIN_SHORTCUT_MAX_ROWS];
    int count;
    int dark;
    int scroll;     /* first visible virtual pixel */
    int content_h;  /* virtual height */
    int finished;
    HFONT font;
    HFONT heading;
    HFONT cap_font;
    HBRUSH bg;
} sc_state;

static COLORREF cref(SpdfWinChromeColor c) {
    return RGB((int)(c.r * 255.0f + 0.5f), (int)(c.g * 255.0f + 0.5f), (int)(c.b * 255.0f + 0.5f));
}

/* The virtual height: a heading per group plus a row per shortcut. */
static int sc_measure(const sc_state* st) {
    int y = SC_MARGIN, i;
    const wchar_t* group = NULL;
    for (i = 0; i < st->count; ++i) {
        if (st->rows[i].group != group) {
            if (group) y += SC_GROUP_GAP;
            y += SC_GROUP_H;
            group = st->rows[i].group;
        }
        y += SC_ROW_H;
    }
    return y + SC_MARGIN;
}

static void sc_update_scrollbar(HWND hwnd, sc_state* st) {
    RECT client;
    SCROLLINFO si;
    GetClientRect(hwnd, &client);
    memset(&si, 0, sizeof(si));
    si.cbSize = sizeof(si);
    si.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    si.nMin = 0;
    si.nMax = st->content_h - 1;
    si.nPage = (UINT)(client.bottom - client.top);
    if (st->scroll > st->content_h - (int)si.nPage) st->scroll = st->content_h - (int)si.nPage;
    if (st->scroll < 0) st->scroll = 0;
    si.nPos = st->scroll;
    SetScrollInfo(hwnd, SB_VERT, &si, TRUE);
}

/* One keycap at (x, y); returns the x after it. */
static int sc_draw_cap(HDC dc, const SpdfWinChromeTheme* t, int x, int y, const wchar_t* text, int len) {
    SIZE size;
    RECT r;
    HBRUSH fill = CreateSolidBrush(cref(t->control_fill));
    HPEN pen = CreatePen(PS_SOLID, 1, cref(t->control_stroke));
    HGDIOBJ old_brush = SelectObject(dc, fill);
    HGDIOBJ old_pen = SelectObject(dc, pen);
    GetTextExtentPoint32W(dc, text, len, &size);
    r.left = x;
    r.top = y;
    r.right = x + size.cx + SC_CAP_PAD * 2;
    r.bottom = y + SC_CAP_H;
    RoundRect(dc, r.left, r.top, r.right, r.bottom, 6, 6);
    SetTextColor(dc, cref(t->control_glyph));
    /* Vertically centred inside the cap: the 26.7.17-1 fix, kept. */
    TextOutW(dc, x + SC_CAP_PAD, y + (SC_CAP_H - size.cy) / 2, text, len);
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    DeleteObject(fill);
    DeleteObject(pen);
    return r.right + SC_CAP_GAP;
}

/* "Ctrl+PgDn or Ctrl+Tab" -> caps [Ctrl][PgDn]  or  [Ctrl][Tab]. A '+' that
 * ENDS a chord ("Ctrl++") is the key itself, not a separator. */
static void sc_draw_accel(HDC dc, const SpdfWinChromeTheme* t, int right, int y, const wchar_t* accel) {
    /* Measure first so the run can be right-aligned: draw once into a
     * position list, then paint from the computed left edge. */
    struct piece {
        const wchar_t* text;
        int len;
        int is_or;
    } pieces[24];
    int n = 0, i, width = 0, x;
    const wchar_t* p = accel;
    SIZE sz;

    while (*p && n < 24) {
        const wchar_t* start = p;
        if (wcsncmp(p, L" or ", 4) == 0) {
            pieces[n].text = L"or";
            pieces[n].len = 2;
            pieces[n].is_or = 1;
            ++n;
            p += 4;
            continue;
        }
        if (*p == L'+' && (p == accel || p[-1] == L'+' || !p[1] || p[1] == L' ')) {
            /* the '+' key itself, or a '+' ending a chord */
            p++;
        } else {
            while (*p && *p != L'+' && wcsncmp(p, L" or ", 4) != 0) p++;
        }
        pieces[n].text = start;
        pieces[n].len = (int)(p - start);
        pieces[n].is_or = 0;
        if (pieces[n].len > 0) ++n;
        if (*p == L'+' && p[1] && p[1] != L' ') p++; /* the separator */
    }
    for (i = 0; i < n; ++i) {
        GetTextExtentPoint32W(dc, pieces[i].text, pieces[i].len, &sz);
        width += pieces[i].is_or ? sz.cx + SC_CAP_GAP * 3 : sz.cx + SC_CAP_PAD * 2 + SC_CAP_GAP;
    }
    x = right - width;
    for (i = 0; i < n; ++i) {
        if (pieces[i].is_or) {
            GetTextExtentPoint32W(dc, pieces[i].text, pieces[i].len, &sz);
            SetTextColor(dc, cref(t->label_secondary));
            TextOutW(dc, x + SC_CAP_GAP, y + (SC_CAP_H - sz.cy) / 2, pieces[i].text, pieces[i].len);
            x += sz.cx + SC_CAP_GAP * 3;
        } else {
            x = sc_draw_cap(dc, t, x, y, pieces[i].text, pieces[i].len);
        }
    }
}

static void sc_paint(HWND hwnd, sc_state* st) {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    RECT client;
    SpdfWinChromeTheme t = spdf_win_chrome_theme_for(st->dark);
    HDC mem;
    HBITMAP bmp;
    HGDIOBJ old_bmp;
    int y, i;
    const wchar_t* group = NULL;
    HPEN sep = CreatePen(PS_SOLID, 1, cref(t.separator));

    GetClientRect(hwnd, &client);
    /* Double-buffered: a scrolled repaint of 60 rows flickers otherwise. */
    mem = CreateCompatibleDC(dc);
    bmp = CreateCompatibleBitmap(dc, client.right, client.bottom);
    old_bmp = SelectObject(mem, bmp);
    FillRect(mem, &client, st->bg);
    SetBkMode(mem, TRANSPARENT);

    y = SC_MARGIN - st->scroll;
    for (i = 0; i < st->count; ++i) {
        const SpdfWinShortcutRow* r = &st->rows[i];
        if (r->group != group) {
            wchar_t name[32];
            if (group) y += SC_GROUP_GAP;
            spdf_win_shortcuts_group_name(r, name, 32);
            SelectObject(mem, st->heading);
            SetTextColor(mem, cref(t.label));
            TextOutW(mem, SC_MARGIN, y + 10, name, (int)wcslen(name));
            {
                HGDIOBJ old_pen = SelectObject(mem, sep);
                MoveToEx(mem, SC_MARGIN, y + SC_GROUP_H - 2, NULL);
                LineTo(mem, client.right - SC_MARGIN, y + SC_GROUP_H - 2);
                SelectObject(mem, old_pen);
            }
            group = r->group;
            y += SC_GROUP_H;
        }
        if (y + SC_ROW_H >= 0 && y <= client.bottom) {
            SelectObject(mem, st->font);
            SetTextColor(mem, cref(t.label));
            TextOutW(mem, SC_MARGIN, y + (SC_ROW_H - 18) / 2, r->title, (int)wcslen(r->title));
            SelectObject(mem, st->cap_font);
            sc_draw_accel(mem, &t, client.right - SC_MARGIN, y + (SC_ROW_H - SC_CAP_H) / 2, r->accel);
        }
        y += SC_ROW_H;
    }
    BitBlt(dc, 0, 0, client.right, client.bottom, mem, 0, 0, SRCCOPY);
    SelectObject(mem, old_bmp);
    DeleteObject(bmp);
    DeleteDC(mem);
    DeleteObject(sep);
    EndPaint(hwnd, &ps);
}

static void sc_scroll_to(HWND hwnd, sc_state* st, int pos) {
    st->scroll = pos;
    sc_update_scrollbar(hwnd, st);
    InvalidateRect(hwnd, NULL, FALSE);
}

static LRESULT CALLBACK sc_wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    sc_state* st = (sc_state*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (!st) return DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        case WM_PAINT: sc_paint(hwnd, st); return 0;
        case WM_ERASEBKGND: return 1;
        case WM_SIZE: sc_update_scrollbar(hwnd, st); return 0;
        case WM_VSCROLL: {
            RECT client;
            int page;
            GetClientRect(hwnd, &client);
            page = client.bottom - client.top;
            switch (LOWORD(wparam)) {
                case SB_LINEUP: sc_scroll_to(hwnd, st, st->scroll - SC_ROW_H); break;
                case SB_LINEDOWN: sc_scroll_to(hwnd, st, st->scroll + SC_ROW_H); break;
                case SB_PAGEUP: sc_scroll_to(hwnd, st, st->scroll - page); break;
                case SB_PAGEDOWN: sc_scroll_to(hwnd, st, st->scroll + page); break;
                case SB_THUMBTRACK:
                case SB_THUMBPOSITION: {
                    SCROLLINFO si;
                    memset(&si, 0, sizeof(si));
                    si.cbSize = sizeof(si);
                    si.fMask = SIF_TRACKPOS;
                    GetScrollInfo(hwnd, SB_VERT, &si);
                    sc_scroll_to(hwnd, st, si.nTrackPos);
                    break;
                }
                case SB_TOP: sc_scroll_to(hwnd, st, 0); break;
                case SB_BOTTOM: sc_scroll_to(hwnd, st, st->content_h); break;
                default: break;
            }
            return 0;
        }
        case WM_MOUSEWHEEL:
            sc_scroll_to(hwnd, st, st->scroll - GET_WHEEL_DELTA_WPARAM(wparam) * SC_ROW_H * 3 / WHEEL_DELTA);
            return 0;
        case WM_KEYDOWN:
            switch (wparam) {
                case VK_UP: SendMessageW(hwnd, WM_VSCROLL, SB_LINEUP, 0); return 0;
                case VK_DOWN: SendMessageW(hwnd, WM_VSCROLL, SB_LINEDOWN, 0); return 0;
                case VK_PRIOR: SendMessageW(hwnd, WM_VSCROLL, SB_PAGEUP, 0); return 0;
                case VK_NEXT:
                case VK_SPACE: SendMessageW(hwnd, WM_VSCROLL, SB_PAGEDOWN, 0); return 0;
                case VK_HOME: SendMessageW(hwnd, WM_VSCROLL, SB_TOP, 0); return 0;
                case VK_END: SendMessageW(hwnd, WM_VSCROLL, SB_BOTTOM, 0); return 0;
                case VK_ESCAPE:
                case VK_F1: /* F1 toggles the sheet closed too */
                case VK_RETURN: DestroyWindow(hwnd); return 0;
                default: break;
            }
            break;
        case WM_CLOSE: DestroyWindow(hwnd); return 0;
        case WM_DESTROY:
            st->finished = 1;
            /* Wake the modal loop out of GetMessageW when the close arrived as
             * a sent message; see the same line in spdf_win_about.cpp. */
            PostThreadMessageW(GetCurrentThreadId(), WM_NULL, 0, 0);
            return 0;
        default: break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static int sc_register_class(void) {
    static int registered = 0;
    WNDCLASSEXW cls;
    if (registered) return 1;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = sc_wnd_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); /* IDC_ARROW */
    cls.lpszClassName = k_sc_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return 0;
    registered = 1;
    return 1;
}

int spdf_win_shortcuts_show(void* parent_handle, int dark) {
    HWND parent = (HWND)parent_handle;
    sc_state* st;
    HWND hwnd;
    MSG msg;
    BOOL msg_got = 1; /* GetMessageW's answer: 0 is WM_QUIT, see spdf_win_modal_scope.h */
    SpdfWinChromeTheme t = spdf_win_chrome_theme_for(dark);

    if (!sc_register_class()) return 0;
    st = (sc_state*)calloc(1, sizeof(*st));
    if (!st) return 0;
    st->count = spdf_win_shortcuts_build(st->rows, SPDF_WIN_SHORTCUT_MAX_ROWS);
    st->dark = dark;
    st->content_h = sc_measure(st);
    st->bg = CreateSolidBrush(cref(t.band));
    st->font = CreateFontW(-15, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    st->heading = CreateFontW(-17, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                              CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    st->cap_font = CreateFontW(-13, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                               CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");

    hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, k_sc_class, L"Keyboard Shortcuts",
                           WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VSCROLL | WS_THICKFRAME, CW_USEDEFAULT,
                           CW_USEDEFAULT, SC_WIDTH, SC_HEIGHT, parent, NULL, GetModuleHandleW(NULL), NULL);
    if (!hwnd) {
        DeleteObject(st->bg);
        DeleteObject(st->font);
        DeleteObject(st->heading);
        DeleteObject(st->cap_font);
        free(st);
        return 0;
    }
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)st);
    spdf_win_about_dark_caption(hwnd, dark);
    sc_update_scrollbar(hwnd, st);
    /* CENTRED ON THE OWNER'S MONITOR before it is shown. CW_USEDEFAULT cascades
     * onto the PRIMARY display; with the app on a second one that is a modal
     * dialog the reader cannot see in front of a window they cannot click. */
    spdf_win_modal_place_on_owner(hwnd, parent);
    /* From here the owner is disabled, and there is no path out of this
     * function that leaves it that way -- see spdf_win_modal_scope.h. */
    SpdfWinModalGuard modal(parent);
    ShowWindow(hwnd, SW_SHOW);
    SetFocus(hwnd);

    while (!st->finished && (msg_got = GetMessageW(&msg, NULL, 0, 0)) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    spdf_win_modal_requeue_quit(msg_got, &msg);
    modal.end();
    DeleteObject(st->bg);
    DeleteObject(st->font);
    DeleteObject(st->heading);
    DeleteObject(st->cap_font);
    free(st);
    return 1;
}
