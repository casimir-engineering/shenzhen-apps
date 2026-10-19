/* spdf_win_about.cpp — the About box and the taskbar identity. Contract in
 * spdf_win_about.h.
 *
 * THE BOX IS A PLAIN WINDOW, owner-drawn in the chrome theme, not a
 * MessageBox: a MessageBox cannot show the app's icon at 64 px, cannot be dark
 * and cannot be selected-and-copied, and "what version are you on?" is the
 * first question every bug report asks, so the version line is a read-only
 * EDIT the reader can copy from. Modal against the parent only, like the
 * properties dialog beside it (spdf_win_properties_dialog.cpp), and for the
 * same reason: disabling the thread would freeze every other window.
 *
 * THE CORE VERSION IS MuPDF's. The portable core (shenzhen_pdf_core.h) carries
 * no version constant of its own -- it ships inside each app and is versioned
 * with it -- so the one component version worth showing is the renderer's,
 * which is also the one that changes what a page looks like.
 */
#include "spdf_win_about.h"

#include "spdf_win_about_version.h"
#include "spdf_win_chrome_theme.h"
#include "spdf_win_modal_scope.h"

#include <windows.h>
#include <dwmapi.h>
#include <shobjidl.h>

#include <mupdf/fitz/version.h>

#include <stdio.h>
#include <string.h>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "dwmapi.lib")

/* The caption follows the box: DWMWA_USE_IMMERSIVE_DARK_MODE, the same
 * attribute the main window sets through spdf_win_window_set_dark_frame(),
 * so a dark About box does not arrive under a white title bar. Measured on
 * the first capture of this box, not assumed. Harmless where unsupported. */
void spdf_win_about_dark_caption(void* hwnd, int dark) {
    BOOL on = dark ? TRUE : FALSE;
    if (!hwnd) return;
    DwmSetWindowAttribute((HWND)hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &on, sizeof(on));
}

int spdf_win_about_text(const char* os_build, char* out, size_t out_len) {
    int n;
    if (!out || !out_len) return 0;
    n = snprintf(out, out_len,
                 "%s\n"
                 "Version %s (build %s)\n"
                 "Rendering: MuPDF %s\n"
                 "%s%s"
                 "%s",
                 SPDF_WIN_PRODUCT_NAME, SPDF_WIN_VERSION_STR, SPDF_WIN_BUILD_STR, FZ_VERSION,
                 os_build && *os_build ? os_build : "", os_build && *os_build ? "\n" : "", SPDF_WIN_COPYRIGHT);
    if (n < 0) {
        out[0] = '\0';
        return 0;
    }
    return n >= (int)out_len ? (int)out_len - 1 : n;
}

int spdf_win_about_os_build(char* out, size_t out_len) {
    /* RtlGetVersion tells the truth; GetVersionEx lies to unmanifested apps
     * and the manifest's supportedOS list is a promise about testing, not a
     * report about the machine. */
    typedef LONG(WINAPI * rtl_get_version_fn)(PRTL_OSVERSIONINFOW);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    rtl_get_version_fn get = ntdll ? (rtl_get_version_fn)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
    RTL_OSVERSIONINFOW info;
    SYSTEM_INFO sys;
    const char* arch;

    if (!out || !out_len) return 0;
    out[0] = '\0';
    if (!get) return 0;
    memset(&info, 0, sizeof(info));
    info.dwOSVersionInfoSize = sizeof(info);
    if (get(&info) != 0) return 0;
    GetNativeSystemInfo(&sys);
    switch (sys.wProcessorArchitecture) {
        case PROCESSOR_ARCHITECTURE_AMD64: arch = "x64"; break;
        case PROCESSOR_ARCHITECTURE_ARM64: arch = "ARM64"; break;
        case PROCESSOR_ARCHITECTURE_INTEL: arch = "x86"; break;
        default: arch = "unknown"; break;
    }
    /* Windows 11 reports 10.0 with a build of 22000 or later. */
    snprintf(out, out_len, "Windows %s build %lu, %s",
             (info.dwMajorVersion == 10 && info.dwBuildNumber >= 22000) ? "11"
             : info.dwMajorVersion == 10                                 ? "10"
                                                                         : "(older)",
             (unsigned long)info.dwBuildNumber, arch);
    return 1;
}

/* --- identity --------------------------------------------------------------- */

void spdf_win_about_apply_identity(void* hwnd_handle) {
    HWND hwnd = (HWND)hwnd_handle;
    static int model_id_set = 0;
    HINSTANCE self = GetModuleHandleW(NULL);

    if (!model_id_set) {
        /* Available since Windows 7; every supported Windows has it, but a
         * missing export must not be a crash. */
        typedef HRESULT(WINAPI * set_id_fn)(PCWSTR);
        HMODULE shell32 = GetModuleHandleW(L"shell32.dll");
        if (!shell32) shell32 = LoadLibraryW(L"shell32.dll");
        set_id_fn set_id = shell32 ? (set_id_fn)GetProcAddress(shell32, "SetCurrentProcessExplicitAppUserModelID") : NULL;
        if (set_id) set_id(L"" SPDF_WIN_APP_USER_MODEL_ID);
        model_id_set = 1;
    }
    if (!hwnd) return;
    {
        /* LoadImage rather than LoadIcon so each slot gets the size it wants
         * from the multi-size group instead of the 32 px default scaled. */
        int big = GetSystemMetrics(SM_CXICON), small_ = GetSystemMetrics(SM_CXSMICON);
        HICON hbig = (HICON)LoadImageW(self, MAKEINTRESOURCEW(SPDF_WIN_RES_ICON_APP), IMAGE_ICON, big, big, 0);
        HICON hsmall = (HICON)LoadImageW(self, MAKEINTRESOURCEW(SPDF_WIN_RES_ICON_APP), IMAGE_ICON, small_, small_, 0);
        if (hbig) SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)hbig);
        if (hsmall) SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)hsmall);
    }
}

/* --- the box ------------------------------------------------------------------ */

#define ABOUT_ID_TEXT 1101
#define ABOUT_ID_CLOSE 1102
/* Five lines of 15 px Segoe UI under a 24 px title, plus the button row: the
 * first capture at 250 clipped the copyright line. */
#define ABOUT_WIDTH 480
#define ABOUT_HEIGHT 290
#define ABOUT_MARGIN 20
#define ABOUT_ICON 64

static const wchar_t* k_about_class = L"SpdfWinAboutBox";

typedef struct about_state {
    int finished;
    int dark;
    HICON icon;
    HBRUSH bg;
    HFONT title_font;
    HFONT font;
} about_state;

static COLORREF theme_ref(SpdfWinChromeColor c) {
    return RGB((int)(c.r * 255.0f + 0.5f), (int)(c.g * 255.0f + 0.5f), (int)(c.b * 255.0f + 0.5f));
}

static LRESULT CALLBACK about_wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    about_state* st = (about_state*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(hwnd, &ps);
            RECT client;
            SpdfWinChromeTheme t = spdf_win_chrome_theme_for(st ? st->dark : 0);
            GetClientRect(hwnd, &client);
            FillRect(dc, &client, st ? st->bg : (HBRUSH)(COLOR_BTNFACE + 1));
            if (st && st->icon) DrawIconEx(dc, ABOUT_MARGIN, ABOUT_MARGIN, st->icon, ABOUT_ICON, ABOUT_ICON, 0, NULL, DI_NORMAL);
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, theme_ref(t.label));
            if (st) SelectObject(dc, st->title_font);
            TextOutW(dc, ABOUT_MARGIN + ABOUT_ICON + 16, ABOUT_MARGIN + 4, L"Shenzhen PDF", 12);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_CTLCOLOREDIT:
        case WM_CTLCOLORSTATIC: {
            /* The read-only EDIT paints itself; give it our colours so it does
             * not arrive as a white slab on a dark box. */
            HDC dc = (HDC)wparam;
            SpdfWinChromeTheme t = spdf_win_chrome_theme_for(st ? st->dark : 0);
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, theme_ref(t.label_secondary));
            return (LRESULT)(st ? st->bg : (HBRUSH)GetStockObject(WHITE_BRUSH));
        }
        case WM_COMMAND:
            if (LOWORD(wparam) == ABOUT_ID_CLOSE || LOWORD(wparam) == IDCANCEL) {
                DestroyWindow(hwnd);
                return 0;
            }
            break;
        case WM_CLOSE: DestroyWindow(hwnd); return 0;
        case WM_DESTROY:
            if (st) st->finished = 1;
            /* WAKE THE MODAL LOOP. A close that arrives as a SENT message --
             * another thread's SendMessageW(WM_CLOSE), which is also how a
             * test drives this box -- is handled INSIDE GetMessageW, which then
             * goes on waiting for a POSTED message that never comes: the loop
             * cannot re-test `finished` until one does. Not PostQuitMessage:
             * a WM_QUIT left in the queue after this loop exits would end the
             * app's own message loop. A thread WM_NULL is delivered, wakes the
             * loop, and is a no-op to anyone else who receives it. */
            PostThreadMessageW(GetCurrentThreadId(), WM_NULL, 0, 0);
            return 0;
        default: break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static int about_register_class(void) {
    static int registered = 0;
    WNDCLASSEXW cls;
    if (registered) return 1;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = about_wnd_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); /* IDC_ARROW; see the properties dialog */
    cls.lpszClassName = k_about_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return 0;
    registered = 1;
    return 1;
}

int spdf_win_about_show(void* parent_handle, int dark) {
    HWND parent = (HWND)parent_handle;
    about_state st;
    char text[1024];
    char os[128];
    wchar_t wtext[1200];
    wchar_t crlf[1400];
    HWND hwnd, edit, button;
    MSG msg;
    BOOL msg_got = 1; /* GetMessageW's answer: 0 is WM_QUIT, see spdf_win_modal_scope.h */
    RECT client;
    SpdfWinChromeTheme t = spdf_win_chrome_theme_for(dark);
    int i, w = 0;

    if (!about_register_class()) return 0;
    spdf_win_about_os_build(os, sizeof(os));
    spdf_win_about_text(os, text, sizeof(text));
    if (MultiByteToWideChar(CP_UTF8, 0, text, -1, wtext, _countof(wtext)) <= 0) return 0;
    /* An EDIT wants CRLF; the first line is drawn as the title, so skip it. */
    {
        const wchar_t* p = wcschr(wtext, L'\n');
        p = p ? p + 1 : wtext;
        for (i = 0; p[i] && w + 2 < (int)_countof(crlf); ++i) {
            if (p[i] == L'\n') crlf[w++] = L'\r';
            crlf[w++] = p[i];
        }
        crlf[w] = L'\0';
    }

    memset(&st, 0, sizeof(st));
    st.dark = dark;
    st.bg = CreateSolidBrush(theme_ref(t.band));
    st.icon = (HICON)LoadImageW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(SPDF_WIN_RES_ICON_APP), IMAGE_ICON,
                                ABOUT_ICON, ABOUT_ICON, 0);
    st.title_font = CreateFontW(-24, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    st.font = CreateFontW(-15, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                          CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");

    hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, k_about_class, L"About Shenzhen PDF",
                           WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, ABOUT_WIDTH,
                           ABOUT_HEIGHT, parent, NULL, GetModuleHandleW(NULL), NULL);
    if (!hwnd) {
        DeleteObject(st.bg);
        DeleteObject(st.title_font);
        DeleteObject(st.font);
        if (st.icon) DestroyIcon(st.icon);
        return 0;
    }
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)&st);
    spdf_win_about_dark_caption(hwnd, dark);
    GetClientRect(hwnd, &client);
    edit = CreateWindowExW(0, L"EDIT", crlf, WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_READONLY,
                           ABOUT_MARGIN + ABOUT_ICON + 16, ABOUT_MARGIN + 40,
                           client.right - ABOUT_MARGIN * 2 - ABOUT_ICON - 16, client.bottom - ABOUT_MARGIN * 3 - 40 - 28,
                           hwnd, (HMENU)(INT_PTR)ABOUT_ID_TEXT, GetModuleHandleW(NULL), NULL);
    button = CreateWindowExW(0, L"BUTTON", L"Close", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
                             client.right - ABOUT_MARGIN - 100, client.bottom - ABOUT_MARGIN - 28, 100, 28, hwnd,
                             (HMENU)(INT_PTR)ABOUT_ID_CLOSE, GetModuleHandleW(NULL), NULL);
    SendMessageW(edit, WM_SETFONT, (WPARAM)st.font, TRUE);
    SendMessageW(button, WM_SETFONT, (WPARAM)st.font, TRUE);
    /* CENTRED ON THE OWNER'S MONITOR before it is shown. CW_USEDEFAULT cascades
     * onto the PRIMARY display; with the app on a second one that is a modal
     * dialog the reader cannot see in front of a window they cannot click. */
    spdf_win_modal_place_on_owner(hwnd, parent);
    /* From here the owner is disabled, and there is no path out of this
     * function that leaves it that way -- see spdf_win_modal_scope.h. */
    SpdfWinModalGuard modal(parent);
    ShowWindow(hwnd, SW_SHOW);
    SetFocus(button);

    while (!st.finished && (msg_got = GetMessageW(&msg, NULL, 0, 0)) > 0) {
        if (msg.message == WM_KEYDOWN && (msg.wParam == VK_ESCAPE || msg.wParam == VK_RETURN)) {
            DestroyWindow(hwnd);
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    spdf_win_modal_requeue_quit(msg_got, &msg);
    modal.end();
    DeleteObject(st.bg);
    DeleteObject(st.title_font);
    DeleteObject(st.font);
    if (st.icon) DestroyIcon(st.icon);
    return 1;
}
