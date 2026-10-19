#pragma once

/* Window PROPERTIES -- the frame, the title, the dark frame, the menu bar --
 * for spdf_win_window.cpp only.
 *
 * NOT A NEW LAYER, and the same arrangement as spdf_win_window_input.h beside
 * it: header-only, included from exactly one translation unit, AFTER
 * `struct spdf_win_window` because it dereferences it, and not part of the
 * port's public surface. Every function here was in spdf_win_window.cpp and does
 * exactly what it did there; they moved out when the menu bar pushed that file
 * to its 500-line cap, and tools/file-size-limits.md asks for an extracted file
 * rather than a raised one.
 *
 * WHAT BELONGS HERE: things that are true of the WINDOW rather than of a frame
 * of pixels or of a message. All four are properties an HWND has and a WIC
 * bitmap cannot -- which is exactly the boundary spdf_win_window.h already draws
 * for the reading theme's two window-level halves, and the reason none of this
 * can sit behind spdf_win_paint().
 */

/* SetProcessDpiAwarenessContext and GetDpiForWindow both arrived in Windows 10
 * 1607/1703. Resolving them dynamically means one binary runs everywhere and
 * merely looks slightly wrong on a Windows older than the feature. */
typedef BOOL(WINAPI* set_dpi_ctx_fn)(DPI_AWARENESS_CONTEXT);
typedef UINT(WINAPI* get_dpi_for_window_fn)(HWND);

void spdf_win_enable_dpi_awareness(void) {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (!user32) return;
    set_dpi_ctx_fn set_ctx = (set_dpi_ctx_fn)GetProcAddress(user32, "SetProcessDpiAwarenessContext");
    if (set_ctx) set_ctx(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}

static UINT window_dpi(HWND hwnd) {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32) {
        get_dpi_for_window_fn get_dpi = (get_dpi_for_window_fn)GetProcAddress(user32, "GetDpiForWindow");
        if (get_dpi) {
            UINT dpi = get_dpi(hwnd);
            if (dpi >= 48 && dpi <= 960) return dpi;
        }
    }
    return USER_DEFAULT_SCREEN_DPI;
}

/* --- full screen ---------------------------------------------------------
 *
 * The standard Win32 arrangement (it is what Raymond Chen documents and what
 * every browser does): drop the overlapped styles for WS_POPUP, cover the
 * monitor's whole rectangle, and put the saved placement back on exit. The
 * client-owned caption needs two things to know about it -- the DWM frame
 * extension goes to zero (extend_frame_into_strip) and the top resize band is
 * not offered (nc_hit_test), both exactly as for a maximized window. */
void spdf_win_window_set_fullscreen(spdf_win_window* window, int on) {
    LONG_PTR style;
    if (!window || !window->hwnd) return;
    on = on ? 1 : 0;
    if (on == window->fullscreen) return;
    style = GetWindowLongPtrW(window->hwnd, GWL_STYLE);
    /* Both transitions move the window by our hand, not the reader's: a parked
     * window (spdf_win_window_restore_placement) must stay parked through them. */
    window->placing = 1;
    if (on) {
        MONITORINFO mi;
        HMONITOR mon = MonitorFromWindow(window->hwnd, MONITOR_DEFAULTTONEAREST);
        memset(&mi, 0, sizeof(mi));
        mi.cbSize = sizeof(mi);
        if (!mon || !GetMonitorInfoW(mon, &mi)) return;
        window->placement.length = sizeof(window->placement);
        GetWindowPlacement(window->hwnd, &window->placement);
        window->fullscreen = 1;
        SetWindowLongPtrW(window->hwnd, GWL_STYLE, (style & ~(LONG_PTR)WS_OVERLAPPEDWINDOW) | WS_POPUP);
        extend_frame_into_strip(window);
        SetWindowPos(window->hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                     mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top,
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    } else {
        window->fullscreen = 0;
        SetWindowLongPtrW(window->hwnd, GWL_STYLE, (style & ~(LONG_PTR)WS_POPUP) | WS_OVERLAPPEDWINDOW);
        SetWindowPlacement(window->hwnd, &window->placement);
        extend_frame_into_strip(window);
        SetWindowPos(window->hwnd, NULL, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    }
    window->placing = 0;
    InvalidateRect(window->hwnd, NULL, FALSE);
}

int spdf_win_window_is_fullscreen(const spdf_win_window* window) { return window ? window->fullscreen : 0; }

/* ES_DISPLAY_REQUIRED keeps the screen on, ES_SYSTEM_REQUIRED keeps the
 * machine from sleeping, ES_CONTINUOUS makes both stick until the next call.
 * The same call with ES_CONTINUOUS alone clears them. */
void spdf_win_window_prevent_sleep(int on) {
    SetThreadExecutionState(on ? (ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED) : ES_CONTINUOUS);
}

/* --- the placement --------------------------------------------------------
 *
 * The Win32 half of spdf_win_placement.h, which states the rules and the
 * defect. Everything about "is this frame showable" is decided there, on plain
 * rectangles; this file only enumerates the displays, reads and writes the
 * WINDOWPLACEMENT, and tells its own moves from the reader's. */

static spdf_win_rect rect_of(const RECT* r) {
    spdf_win_rect out;
    out.x = r->left;
    out.y = r->top;
    out.w = r->right - r->left;
    out.h = r->bottom - r->top;
    return out;
}

/* szDevice is ASCII ("\\.\DISPLAY2"); anything else is truncated to the
 * bytes that fit, which still compares unequal to every other display. */
static void display_name_utf8(const wchar_t* wide, char* out, size_t out_len) {
    size_t i;
    for (i = 0; i + 1 < out_len && wide[i]; ++i) out[i] = wide[i] < 0x80 ? (char)wide[i] : '?';
    out[i] = '\0';
}

typedef struct display_list {
    spdf_win_display items[16];
    int count;
} display_list;

static BOOL CALLBACK collect_display(HMONITOR mon, HDC hdc, LPRECT rect, LPARAM lparam) {
    display_list* list = (display_list*)lparam;
    MONITORINFOEXW mi;
    (void)hdc;
    (void)rect;
    if (list->count >= (int)(sizeof(list->items) / sizeof(list->items[0]))) return FALSE;
    memset(&mi, 0, sizeof(mi));
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, (MONITORINFO*)&mi)) return TRUE;
    display_name_utf8(mi.szDevice, list->items[list->count].name, sizeof(list->items[list->count].name));
    list->items[list->count].monitor = rect_of(&mi.rcMonitor);
    list->items[list->count].work = rect_of(&mi.rcWork);
    list->count++;
    return TRUE;
}

static void attached_displays(display_list* list) {
    list->count = 0;
    EnumDisplayMonitors(NULL, NULL, collect_display, (LPARAM)list);
}

/* The display a rectangle is (mostly) on, for the identity the session keeps. */
static void display_of_rect(const RECT* r, spdf_win_placement* out) {
    MONITORINFOEXW mi;
    HMONITOR mon = MonitorFromRect(r, MONITOR_DEFAULTTONEAREST);
    out->display[0] = '\0';
    memset(&out->display_rect, 0, sizeof(out->display_rect));
    memset(&mi, 0, sizeof(mi));
    mi.cbSize = sizeof(mi);
    if (!mon || !GetMonitorInfoW(mon, (MONITORINFO*)&mi)) return;
    display_name_utf8(mi.szDevice, out->display, sizeof(out->display));
    out->display_rect = rect_of(&mi.rcMonitor);
}

/* Put the NORMAL rect somewhere, as our own doing. Through the placement
 * rather than SetWindowPos: rcNormalPosition is what get_placement reads, so a
 * save-restore-save round trip is the identity. A hidden window stays hidden;
 * a shown one keeps whatever state it is in. */
static void place_normal_rect(spdf_win_window* window, const RECT* r) {
    WINDOWPLACEMENT wp;
    memset(&wp, 0, sizeof(wp));
    wp.length = sizeof(wp);
    if (!GetWindowPlacement(window->hwnd, &wp)) return;
    if (!IsWindowVisible(window->hwnd)) wp.showCmd = SW_HIDE;
    wp.rcNormalPosition = *r;
    window->placing = 1;
    SetWindowPlacement(window->hwnd, &wp);
    window->placing = 0;
    if (window->parked) window->parked_rect = *r;
}

/* WM_DPICHANGED's suggested rectangle, applied as our own move. */
static void placement_own_move(spdf_win_window* window, const RECT* suggested) {
    WINDOWPLACEMENT wp;
    window->placing = 1;
    SetWindowPos(window->hwnd, NULL, suggested->left, suggested->top, suggested->right - suggested->left,
                 suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
    window->placing = 0;
    memset(&wp, 0, sizeof(wp));
    wp.length = sizeof(wp);
    if (window->parked && GetWindowPlacement(window->hwnd, &wp)) window->parked_rect = wp.rcNormalPosition;
}

void spdf_win_window_restore_placement(spdf_win_window* window, const spdf_win_placement* saved) {
    display_list displays;
    RECT r;
    spdf_win_rect frame;
    if (!window || !window->hwnd || !saved || saved->frame.w <= 0 || saved->frame.h <= 0) return;
    window->desired = *saved;
    window->has_desired = 1;
    window->parked = 0;
    attached_displays(&displays);
    {
        /* The main display's work area: the monitor at the origin. Only the
         * frame with no home among the attached displays is centred there;
         * a frame hanging off a display it is still partly on is pulled onto
         * that display instead (spdf_win_placement_resolve, rule 4). */
        RECT work = {0, 0, 1280, 800};
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        frame = spdf_win_placement_resolve(saved, displays.items, displays.count, rect_of(&work), &window->parked);
    }
    r.left = frame.x;
    r.top = frame.y;
    r.right = frame.x + frame.w;
    r.bottom = frame.y + frame.h;
    place_normal_rect(window, &r);
}

/* WM_DISPLAYCHANGE: a parked window whose frame can be shown now goes back. */
static void placement_displays_changed(spdf_win_window* window) {
    display_list displays;
    RECT r;
    if (!window->hwnd || !window->has_desired || !window->parked) return;
    attached_displays(&displays);
    if (!spdf_win_placement_is_usable(&window->desired, displays.items, displays.count)) return;
    r.left = window->desired.frame.x;
    r.top = window->desired.frame.y;
    r.right = r.left + window->desired.frame.w;
    r.bottom = r.top + window->desired.frame.h;
    window->parked = 0;
    place_normal_rect(window, &r);
}

/* WM_WINDOWPOSCHANGED: the reader moved or resized a parked window, so what
 * is on screen is now their choice and supersedes the remembered frame. Only a
 * change to the NORMAL rect counts -- showing, maximizing and our own placing
 * leave it alone -- and full screen is a placement of ours too. */
static void placement_note_moved(spdf_win_window* window) {
    WINDOWPLACEMENT wp;
    if (!window->parked || window->placing || window->fullscreen || !window->hwnd) return;
    memset(&wp, 0, sizeof(wp));
    wp.length = sizeof(wp);
    if (!GetWindowPlacement(window->hwnd, &wp)) return;
    if (!EqualRect(&wp.rcNormalPosition, &window->parked_rect)) window->parked = 0;
}

int spdf_win_window_get_placement(const spdf_win_window* window, spdf_win_placement* out) {
    WINDOWPLACEMENT wp;
    const RECT* r;
    if (!window || !out) return 0;
    memset(out, 0, sizeof(*out));
    /* Still parked at a fallback: the reader's frame, not our stand-in. */
    if (window->has_desired && window->parked) {
        *out = window->desired;
        return 1;
    }
    /* While full screen the live placement is the monitor; the one worth
     * remembering is the one that will come back. After WM_DESTROY there is no
     * HWND and the placement is what it recorded on the way out -- which is
     * when the exit save asks. */
    if (window->fullscreen || !window->hwnd) {
        if (window->placement.length != sizeof(window->placement)) return 0;
        wp = window->placement;
    } else {
        memset(&wp, 0, sizeof(wp));
        wp.length = sizeof(wp);
        if (!GetWindowPlacement(window->hwnd, &wp)) return 0;
    }
    r = &wp.rcNormalPosition;
    if (r->right <= r->left || r->bottom <= r->top) return 0;
    out->frame = rect_of(r);
    display_of_rect(r, out);
    return 1;
}

int spdf_win_window_is_foreground(const spdf_win_window* window) {
    if (!window) return 0;
    if (window->hwnd) return GetForegroundWindow() == window->hwnd;
    return window->foreground_at_close;
}

/* Grow the FRAME until the CLIENT area is the requested size at this window's
 * DPI. Idempotent.
 *
 * frame_extents(), not AdjustWindowRectEx: the caption is client area now
 * (spdf_win_window_caption.h), so the frame around the client is the three
 * resize borders and nothing else. AdjustWindowRectEx would still add the
 * caption it no longer has, and the client would come out one caption taller
 * than every offscreen render this port compares against. The requested size
 * INCLUDES the strip -- macOS's 1120 x 800 is a full-size content view whose
 * top 42 pt is the title bar, and so is ours. */
static void resize_to_client(spdf_win_window* window) {
    float s = spdf_win_window_dpi_scale(window);
    int extra_w = 0, extra_h = 0;
    if (!window->hwnd || window->client_px_w <= 0 || window->client_px_h <= 0) return;
    frame_extents(window, &extra_w, &extra_h);
    SetWindowPos(window->hwnd, NULL, 0, 0, (int)(window->client_px_w * s) + extra_w,
                 (int)(window->client_px_h * s) + extra_h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void spdf_win_window_set_title(spdf_win_window* window, const wchar_t* title) {
    if (!window || !window->hwnd || !title) return;
    SetWindowTextW(window->hwnd, title);
}

/* DWMWA_USE_IMMERSIVE_DARK_MODE. The attribute number is 20 from Windows 10
 * 2004 (build 19041) onward; on 1809/1903/1909 the same undocumented attribute
 * was 19, and the two were never valid at the same time. So try 20 and fall back
 * to 19: DwmSetWindowAttribute rejects an out-of-range attribute with
 * E_INVALIDARG rather than succeeding quietly, which makes the fallback a real
 * runtime check instead of a guess from a version number. (This machine is
 * 10.0.26200, where 20 is the live one and 19 never runs.)
 *
 * GetProcAddress rather than a link-time import of dwmapi.lib, following
 * spdf_win_enable_dpi_awareness() above for exactly the same reason: one binary
 * that starts everywhere and simply looks slightly wrong on a Windows older than
 * the feature. LoadLibraryW, not GetModuleHandleW -- unlike user32.dll,
 * dwmapi.dll is not already in the process. */
typedef HRESULT(WINAPI* dwm_set_window_attribute_fn)(HWND, DWORD, LPCVOID, DWORD);

void spdf_win_window_set_dark_frame(spdf_win_window* window, int dark) {
    if (!window || !window->hwnd) return;
    HMODULE dwmapi = LoadLibraryW(L"dwmapi.dll");
    if (!dwmapi) return;
    dwm_set_window_attribute_fn set_attr =
        (dwm_set_window_attribute_fn)GetProcAddress(dwmapi, "DwmSetWindowAttribute");
    if (set_attr) {
        /* BOOL, 4 bytes: DWM validates the size and fails a plain `int` on some
         * builds. */
        BOOL on = dark ? TRUE : FALSE;
        if (FAILED(set_attr(window->hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &on, sizeof(on))))
            set_attr(window->hwnd, 19 /* the same attribute pre-2004 */, &on, sizeof(on));
    }
    FreeLibrary(dwmapi);
}

/* MAKE MENUS AND OTHER COMMON CONTROLS FOLLOW DARK MODE.
 *
 * A Win32 menu bar and every TrackPopupMenu are drawn by the system in the
 * light palette unless the process opts in, and there is no documented way to
 * ask. The result on a dark desktop is a bright strip between a dark caption
 * and dark chrome, which reads as a second title bar -- reported from actual
 * use as "a double top bar like it's a window inside of a window".
 *
 * uxtheme.dll's SetPreferredAppMode is ordinal 135 and has no exported name.
 * That is what every Windows app that themes its menus uses, because it is the
 * only thing that works; it is also why this is wrapped in as much caution as
 * it is:
 *
 *   - Looked up BY ORDINAL, which is what it is published as. If a future
 *     Windows renumbers or removes it, GetProcAddress returns NULL and the app
 *     keeps its light menus. That is a cosmetic loss, never a failure.
 *   - Version-gated to build 18362 (1903) and later, where the entry point
 *     appeared. On anything older the ordinal may point at something else
 *     entirely, so it is not called at all.
 *   - Return value ignored on purpose: it hands back the PREVIOUS mode, and
 *     there is nothing useful to do with it.
 *
 * The alternative was owner-drawing the whole menu bar, which means taking over
 * measurement, keyboard navigation and accessibility for a strip this app may
 * not even keep. Not worth it for the same pixels.
 *
 * FlushMenuThemes() afterwards, because menus created before the mode changed
 * keep their old theme otherwise -- and the menu bar is created right after
 * this runs. */
void spdf_win_enable_dark_menus(void) {
    /* PreferredAppMode: 0 Default, 1 AllowDark, 2 ForceDark, 3 ForceLight. */
    typedef int(WINAPI * set_preferred_app_mode_fn)(int);
    typedef void(WINAPI * flush_menu_themes_fn)(void);
    HMODULE uxtheme;
    set_preferred_app_mode_fn set_mode;
    flush_menu_themes_fn flush;
    DWORD build = 0;

    /* RtlGetNtVersionNumbers rather than GetVersionEx, which lies to
     * unmanifested processes and would report 6.2 here. */
    {
        typedef void(WINAPI * get_version_fn)(DWORD*, DWORD*, DWORD*);
        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        get_version_fn get_version =
            ntdll ? (get_version_fn)GetProcAddress(ntdll, "RtlGetNtVersionNumbers") : NULL;
        DWORD major = 0, minor = 0;
        if (get_version) {
            get_version(&major, &minor, &build);
            build &= 0x0FFFFFFF; /* the top nibble is a flag, not part of the number */
        }
        if (major < 10 || build < 18362) return;
    }

    uxtheme = LoadLibraryW(L"uxtheme.dll");
    if (!uxtheme) return;
    set_mode = (set_preferred_app_mode_fn)GetProcAddress(uxtheme, (LPCSTR)135);
    if (set_mode) {
        /* AllowDark, not ForceDark: the app then follows the SYSTEM setting, so
         * a user who flips Windows back to light gets light menus without the
         * app having to notice. */
        set_mode(1);
        flush = (flush_menu_themes_fn)GetProcAddress(uxtheme, (LPCSTR)136);
        if (flush) flush();
    }
    /* uxtheme stays loaded deliberately: the mode is process-wide and menus are
     * created later, so unloading here could take the theming with it. */
}

int spdf_win_system_prefers_dark(void) {
    /* AppsUseLightTheme is the APP theme; SystemUsesLightTheme next to it is the
     * taskbar's, and the two are independently settable in Windows Settings. A
     * document reader is an app, so it follows the app one.
     *
     * RRF_RT_REG_DWORD makes the type part of the query rather than something to
     * check afterwards, and a missing key leaves `light` at its initial 1 --
     * which is what Windows itself assumes when the value has never been
     * written. So a machine that has never touched the setting reads as light,
     * not as garbage. */
    DWORD light = 1;
    DWORD size = sizeof(light);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &light, &size) != ERROR_SUCCESS)
        return 0;
    return light ? 0 : 1;
}

/* NOTE: a menu bar and a client-owned caption do not combine. WM_NCCALCSIZE in
 * spdf_win_window_caption.h gives the client the whole top of the frame, menu
 * bar included, so a bar installed here would be painted by DefWindowProc over
 * the strip. Nothing installs one -- spdf_win_main.cpp deliberately passes no
 * menu and opens the app menu from the toolbar instead -- and if one ever comes
 * back it has to be drawn inside the strip like every other control. */
void spdf_win_window_set_menu(spdf_win_window* window, void* hmenu) {
    if (!window || !window->hwnd || !hmenu) return;
    if (!SetMenu(window->hwnd, (HMENU)hmenu)) return;
    DrawMenuBar(window->hwnd);
    resize_to_client(window);
}

void* spdf_win_window_native_handle(spdf_win_window* window) {
    return window ? (void*)window->hwnd : NULL;
}
