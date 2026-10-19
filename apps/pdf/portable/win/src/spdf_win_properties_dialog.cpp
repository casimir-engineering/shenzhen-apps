/* spdf_win_properties_dialog.cpp — the WINDOW half of the properties panel.
 * The model it draws is spdf_win_properties.cpp; see spdf_win_properties.h for
 * why they are separate translation units.
 *
 * NO RESOURCE SCRIPT, NO DIALOG TEMPLATE. The port has no .rc file and adding
 * one would put a build step in front of every other track's `cl` invocation
 * (build-native.cmd discovers .c/.cpp and nothing else). So this is a plain
 * window with three child controls and a local modal loop, which is also what
 * lets it disable exactly one parent window instead of the whole thread.
 *
 * WHAT THIS IS NOT. It is not the macOS panel's appearance: that one is grouped
 * AdwPreferencesGroup-style sections with selectable subtitles, and reproducing
 * it means the chrome track's DirectWrite painting, which another agent owns
 * this round. What is here is the same INFORMATION, in the same order, with the
 * same "Copy All" affordance both other frontends have — and the model behind
 * it is finished, so restyling it later is a paint change and not a rewrite.
 *
 * UNTESTED ON THIS MACHINE, AND SAID SO RATHER THAN ASSERTED AWAY. The
 * workstation is locked, so no window can be created and no dialog can be
 * shown. spdf_win_properties_show() returns 0 in that case; the model and the
 * transcript it would have displayed are covered by properties_test.c.
 */

#include "spdf_win_modal_scope.h"
#include "spdf_win_properties.h"

#include "spdf_win_selection.h" /* spdf_win_clipboard_put_utf8, the CF_UNICODETEXT rule */

#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")

#define PROPS_ID_TEXT 1001
#define PROPS_ID_COPY 1002
#define PROPS_ID_CLOSE 1003

#define PROPS_WIDTH 620
#define PROPS_HEIGHT 560
#define PROPS_MARGIN 12
#define PROPS_BUTTON_W 110
#define PROPS_BUTTON_H 28

static const wchar_t* k_props_class = L"SpdfWinPropertiesDialog";

typedef struct props_window_state {
    const char* transcript; /* UTF-8, owned by the caller of the show function */
    int finished;
} props_window_state;

/* UTF-8 -> UTF-16 with every LF turned into CRLF. An EDIT control renders a
 * bare LF as a box and runs the whole transcript onto one line, so the
 * conversion is not cosmetic. Caller frees. */
static wchar_t* props_wide_crlf(const char* utf8) {
    int need;
    wchar_t* wide;
    wchar_t* out;
    int i;
    int w = 0;
    int breaks = 0;

    if (!utf8) return NULL;
    need = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (need <= 0) return NULL;
    wide = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)need);
    if (!wide) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, need) <= 0) {
        free(wide);
        return NULL;
    }
    for (i = 0; wide[i]; ++i)
        if (wide[i] == L'\n') ++breaks;
    out = (wchar_t*)malloc(sizeof(wchar_t) * ((size_t)need + (size_t)breaks));
    if (!out) {
        free(wide);
        return NULL;
    }
    for (i = 0; wide[i]; ++i) {
        if (wide[i] == L'\n') out[w++] = L'\r';
        out[w++] = wide[i];
    }
    out[w] = L'\0';
    free(wide);
    return out;
}

static LRESULT CALLBACK props_wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    props_window_state* state = (props_window_state*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

    switch (msg) {
        case WM_COMMAND:
            switch (LOWORD(wparam)) {
                case PROPS_ID_COPY:
                    /* CF_UNICODETEXT, through the selection track's tested
                     * allocator. A properties dump contains the document's
                     * Title and Author, which are exactly the fields most
                     * likely to be CJK, so a narrow format would mangle the
                     * one thing worth copying (clipboard_test.c measured that
                     * on this machine). */
                    if (state && state->transcript) spdf_win_clipboard_put_utf8(state->transcript);
                    return 0;
                case PROPS_ID_CLOSE:
                case IDCANCEL:
                    DestroyWindow(hwnd);
                    return 0;
                default:
                    break;
            }
            break;
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            if (state) state->finished = 1;
            /* A cross-thread SendMessageW(WM_CLOSE) -- what properties_dialog_test
             * does to close the sheet -- is handled INSIDE the modal loop's
             * GetMessageW, which then keeps waiting for a message that never
             * comes. A thread message wakes it so it can see `finished`. */
            PostThreadMessageW(GetCurrentThreadId(), WM_NULL, 0, 0);
            return 0;
        default:
            break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static int props_register_class(void) {
    static int registered = 0;
    WNDCLASSEXW cls;

    if (registered) return 1;
    memset(&cls, 0, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = props_wnd_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    /* MAKEINTRESOURCEW, not the bare IDC_ARROW: this translation unit is built
     * without UNICODE defined, so IDC_ARROW expands to MAKEINTRESOURCEA and
     * would not convert for the -W entry point. The port calls *W exclusively;
     * this is the one place the ANSI constant slipped in. */
    cls.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); /* IDC_ARROW */
    cls.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    cls.lpszClassName = k_props_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return 0;
    registered = 1;
    return 1;
}

int spdf_win_properties_show(HWND parent, const spdf_win_properties* props) {
    char transcript[SPDF_WIN_PROPS_MAX_ROWS * (SPDF_WIN_PROPS_LABEL_MAX + SPDF_WIN_PROPS_VALUE_MAX + 8) + 256];
    props_window_state state;
    wchar_t* text;
    HWND hwnd;
    HWND edit;
    HFONT font;
    MSG msg;
    BOOL msg_got = 1; /* GetMessageW's answer: 0 is WM_QUIT, see spdf_win_modal_scope.h */
    RECT client;
    int text_h;

    if (!props || props->count <= 0) return 0;
    if (!props_register_class()) return 0;
    spdf_win_properties_transcript(props, transcript, sizeof(transcript));
    text = props_wide_crlf(transcript);
    if (!text) return 0;

    state.transcript = transcript;
    state.finished = 0;

    /* NOT WS_VISIBLE: the window is placed on the owner's monitor first and
     * shown after, so it never appears at the cascade position and jumps. */
    hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, k_props_class, L"Properties",
                           WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, PROPS_WIDTH,
                           PROPS_HEIGHT, parent, NULL, GetModuleHandleW(NULL), NULL);
    if (!hwnd) {
        free(text);
        return 0;
    }
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)&state);

    GetClientRect(hwnd, &client);
    text_h = client.bottom - client.top - PROPS_MARGIN * 3 - PROPS_BUTTON_H;
    if (text_h < 40) text_h = 40;
    edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", text,
                           WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                           PROPS_MARGIN, PROPS_MARGIN, client.right - client.left - PROPS_MARGIN * 2, text_h, hwnd,
                           (HMENU)(INT_PTR)PROPS_ID_TEXT, GetModuleHandleW(NULL), NULL);
    CreateWindowExW(0, L"BUTTON", L"Copy All", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, PROPS_MARGIN,
                    PROPS_MARGIN * 2 + text_h, PROPS_BUTTON_W, PROPS_BUTTON_H, hwnd, (HMENU)(INT_PTR)PROPS_ID_COPY,
                    GetModuleHandleW(NULL), NULL);
    CreateWindowExW(0, L"BUTTON", L"Close", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
                    client.right - client.left - PROPS_MARGIN - PROPS_BUTTON_W, PROPS_MARGIN * 2 + text_h,
                    PROPS_BUTTON_W, PROPS_BUTTON_H, hwnd, (HMENU)(INT_PTR)PROPS_ID_CLOSE, GetModuleHandleW(NULL),
                    NULL);

    /* The shell font, so the panel does not arrive in the 1990s System font
     * that a bare CreateWindow child gets by default. */
    font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    EnumChildWindows(
        hwnd,
        [](HWND child, LPARAM param) -> BOOL {
            SendMessageW(child, WM_SETFONT, (WPARAM)param, TRUE);
            return TRUE;
        },
        (LPARAM)font);

    /* Modal against the parent only. Disabling the whole thread would freeze
     * every other window this process owns, which is wrong in a tabbed,
     * multi-window app. */
    /* CENTRED ON THE OWNER'S MONITOR before it is shown. CW_USEDEFAULT cascades
     * onto the PRIMARY display; with the app on a second one that is a modal
     * dialog the reader cannot see in front of a window they cannot click. */
    spdf_win_modal_place_on_owner(hwnd, parent);
    /* From here the owner is disabled, and there is no path out of this
     * function that leaves it that way -- see spdf_win_modal_scope.h. */
    SpdfWinModalGuard modal(parent);
    ShowWindow(hwnd, SW_SHOW);
    SetFocus(edit);

    while (!state.finished && (msg_got = GetMessageW(&msg, NULL, 0, 0)) > 0) {
        if (msg.message == WM_KEYDOWN && msg.wParam == VK_ESCAPE) {
            DestroyWindow(hwnd);
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    spdf_win_modal_requeue_quit(msg_got, &msg);

    modal.end();
    free(text);
    return 1;
}

int spdf_win_properties_show_for_document(HWND parent, spdf_document* doc, const wchar_t* path, int page_index,
                                          int outline_count, int comment_count) {
    spdf_win_properties props;
    if (!spdf_win_properties_collect(doc, path, page_index, outline_count, comment_count, &props)) return 0;
    return spdf_win_properties_show(parent, &props);
}
