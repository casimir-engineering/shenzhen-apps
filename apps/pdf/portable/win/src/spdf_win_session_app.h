#pragma once

/* spdf_win_session_app.h -- the app's half of the session and the settings:
 * the window title, showing the selected tab with its remembered view, the
 * frame, the periodic save, and the opening size.
 *
 * Header-only and included from spdf_win_main.cpp immediately after `struct
 * app` and before every other glue header, because show_selected_tab() is what
 * spdf_win_chrome_tabs_ui.h and spdf_win_chrome_commands.h call. Same
 * arrangement as spdf_win_tabs_app.h beside it, and split from
 * spdf_win_main.cpp for the reason that file keeps giving: it is at its
 * 500-line cap and tools/file-size-limits.md asks for an extracted file rather
 * than a raised one. Not part of the port's public surface.
 *
 * WHEN THE SESSION IS WRITTEN. It used to be written once, at exit; a crash or
 * a power cut lost every tab opened since launch. Now app_session_save() runs
 * on every change to the set of tabs (spdf_win_chrome_tabs_ui.h), on the
 * window's tick (spdf_win_window_set_tick, SPDF_WIN_SESSION_TICK_MS) and at
 * exit. The write itself is cheap and idempotent -- the state layer compares
 * bytes and skips a no-op save (spdf_win_state.h) -- and it runs under the
 * cross-process lock, so two windows saving at once cannot lose each other.
 */

/* Half a minute: often enough that a crash costs little, seldom enough that a
 * reader scrolling through a document does not churn the disk. */
#define SPDF_WIN_SESSION_TICK_MS 30000

/* macOS titles the window "<display name> - Shenzhen PDF", and the bare product
 * name with no document (ShenzhenPDFMac.mm:8615, :10582; :8985, :9168). Same two
 * strings here, so the two apps read alike in a task switcher -- and so the title
 * stops naming the launch document forever, which is what it did while
 * CreateWindowExW's argument was the only title a session ever got.
 *
 * The display name is the tab's own title, i.e. the path's last component. The
 * strip shows the disambiguated form (spdf_win_tabs_names.h); the title bar is
 * invisible on this window and only the taskbar and Alt-Tab read it, so the
 * plain leaf is enough there. */
static void sync_window_title(app* a) {
    wchar_t wide[288], title[320];
    int index = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
    const char* name = index < 0 ? NULL : spdf_win_tabs_title(a->tabs, index);
    if (!a->window) return;
    /* MB_ERR_INVALID_CHARS: a title is cosmetic, so malformed UTF-8 degrades to the
     * product name rather than to U+FFFD confetti. */
    if (name && *name &&
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, name, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) > 0)
        _snwprintf_s(title, _TRUNCATE, L"%s - Shenzhen PDF", wide);
    else
        _snwprintf_s(title, _TRUNCATE, L"Shenzhen PDF");
    spdf_win_window_set_title(a->window, title);
}

/* THE TAB'S QUERY BECOMES THE FIND FIELD'S. Each tab remembers its own
 * (spdf_win_tab_view::search_text); on show the field and the process-wide find
 * bridge are both set from it, so a Ctrl+Tab brings back the query the reader
 * left in that document -- and clears the field for a tab that had none.
 * Through spdf_win_find_set_query() directly rather than chrome_find_push(),
 * which is defined in a header included after this one. */
static void app_restore_find_text(app* a) {
    const spdf_win_tab_view* view =
        a->tabs ? spdf_win_tabs_view_const(a->tabs, spdf_win_tabs_selected_index(a->tabs)) : NULL;
    a->find_text[0] = L'\0';
    if (view && view->search_text[0] &&
        MultiByteToWideChar(CP_UTF8, 0, view->search_text, -1, a->find_text,
                            (int)(sizeof(a->find_text) / sizeof(a->find_text[0]))) <= 0)
        a->find_text[0] = L'\0';
    a->find_caret = (int)wcslen(a->find_text);
    spdf_win_find_set_query(a->find_text[0] ? a->find_text : NULL, a->find_regex);
}

/* Point the canvas at the newly selected tab, put the tab's remembered view
 * back on it, restore its query AND retitle the window: every caller wants all
 * of it, and doing only the first was the defect being fixed. The view is
 * placed against the canvas viewport the last input event or the launch laid
 * the chrome out against (a->view_w/h); with none known yet, the first paint's
 * pending_page path places the page alone. */
/* Defined in spdf_win_md_commands.h, which spdf_win_main.cpp includes after this
 * header: a Markdown tab whose open recorded remote images not yet in the cache
 * starts fetching them; a no-op on a PDF tab and with nothing pending. */
static void spdf_win_md_command_after_open(app* a, HWND window);

/* WM_APP + 0x0244: a page render landed. Posted by a canvas render worker; the
 * router turns it into one invalidate. Without it an asynchronous visible-page
 * render would finish and nothing would ask for the repaint that shows it.
 *
 * IT WAS WM_APP + 0x5244 ("RD"), WHICH IS 0xD244 AND WAS NEVER DELIVERED. The
 * window forwards WM_APP..0xBFFF and nothing above, because 0xC000 up is the
 * RegisterWindowMessage range; 0xD244 fell straight through to
 * DefWindowProc. Every asynchronous render since the pool landed finished
 * without asking for a repaint, which is why the visible page only ever
 * appeared on the next mouse move -- and why, once the launch's first frame was
 * allowed to wait for the pool, the page never appeared at all. The mnemonic
 * is kept in the low three nibbles, and SPDF_WIN_APP_MSG_OK below is a
 * compile-time check that this number is one the window will hand over. */
#define SPDF_WIN_WM_RENDER_READY (WM_APP + 0x0244)
SPDF_WIN_APP_MSG_OK(spdf_win_render_ready_is_routable, SPDF_WIN_WM_RENDER_READY);

/* Called ON A WORKER THREAD by the canvas. PostMessage is the only thing it is
 * allowed to do here. */
static void canvas_render_ready(void* ctx) {
    PostMessageW((HWND)ctx, SPDF_WIN_WM_RENDER_READY, 0, 0);
}

/* THE RENDER FLAGS FOR THE SELECTED TAB: the app's theme with THAT document's
 * Keep Image Colors in the SPDF_RENDER_PRESERVE_IMAGES bit. The choice is per
 * document (spdf_win_tab_view::preserves_image_colors), so it is composed
 * every time a tab is shown -- open, switch, restore, reload, a theme rebuild
 * -- rather than held in the app: a datasheet keeps its colour-coded figures
 * while the scan in the next tab is recoloured whole. The bit is set whatever
 * the theme, because the Settings menu ticks the row from it whatever the
 * theme (as the mac's does); the core only acts on it while dark. With no tab
 * the flags are left as they are. */
static unsigned app_render_flags_for_selected_tab(const app* a) {
    const spdf_win_tab_view* view =
        a->tabs ? spdf_win_tabs_view_const(a->tabs, spdf_win_tabs_selected_index(a->tabs)) : NULL;
    unsigned flags = a->render_flags & ~(unsigned)SPDF_RENDER_PRESERVE_IMAGES;
    if (!view) return a->render_flags;
    return view->preserves_image_colors != 0 ? flags | SPDF_RENDER_PRESERVE_IMAGES : flags;
}

static int show_selected_tab(app* a) {
    int shown;
    a->render_flags = app_render_flags_for_selected_tab(a);
    shown = spdf_win_tabs_app_show(a->tabs, &a->canvas, a->render_flags, &a->pending_page);
    if (shown && spdf_win_tabs_app_apply_view(a->tabs, a->canvas, a->view_w, a->view_h, a->view_dpi))
        a->pending_page = -1;
    app_restore_find_text(a);
    sync_window_title(a);
    /* Every show goes through here -- open, switch, restore, reload, a theme
     * rebuild -- so this is the one place a Markdown tab's images are asked
     * for. The completion message re-shows the tab (spdf_win_md_commands.h). */
    if (shown && a->window) {
        HWND hwnd = (HWND)spdf_win_window_native_handle(a->window);
        /* THE VISIBLE PAGE OFF THE UI THREAD, from this canvas's SECOND frame
         * on: the canvas renders its first frame on the calling thread come
         * what may, so a launch still paints a complete window before
         * ShowWindow and a tab switch still lands finished. */
        spdf_win_canvas_set_async_visible(a->canvas, canvas_render_ready, hwnd);
        spdf_win_md_command_after_open(a, hwnd);
    }
    return shown;
}

/* The window's frame for the session -- the one the reader left, which while
 * the window is parked at a fallback is NOT the one on screen
 * (spdf_win_window_get_placement) -- with the display it is on; or a zero
 * frame when there is no window (the headless paths, or after it closed). The
 * two structs are the same shape on purpose and kept apart on purpose: the
 * session's is toolkit-free and tested headlessly, the window's is Win32's. */
static spdf_win_session_frame app_session_frame(app* a) {
    spdf_win_session_frame f;
    spdf_win_placement p;
    memset(&f, 0, sizeof(f));
    if (!a->window || !spdf_win_window_get_placement(a->window, &p)) return f;
    f.x = p.frame.x;
    f.y = p.frame.y;
    f.w = p.frame.w;
    f.h = p.frame.h;
    strncpy_s(f.display, sizeof(f.display), p.display, _TRUNCATE);
    f.display_x = p.display_rect.x;
    f.display_y = p.display_rect.y;
    f.display_w = p.display_rect.w;
    f.display_h = p.display_rect.h;
    return f;
}

/* The saved placement, back into the window's shape, for the launch. */
static spdf_win_placement app_placement_of(const spdf_win_session_frame* f) {
    spdf_win_placement p;
    memset(&p, 0, sizeof(p));
    p.frame.x = f->x;
    p.frame.y = f->y;
    p.frame.w = f->w;
    p.frame.h = f->h;
    strncpy_s(p.display, sizeof(p.display), f->display, _TRUNCATE);
    p.display_rect.x = f->display_x;
    p.display_rect.y = f->display_y;
    p.display_rect.w = f->display_w;
    p.display_rect.h = f->display_h;
    return p;
}

/* Write this window into session.yaml now: the reader's place in the selected
 * tab, every tab's metadata, the frame, and -- while this is the foreground
 * window -- the focus stamp that brings it back in front (spdf_win_session.h). */
static int app_session_save(app* a) {
    spdf_win_session_frame f;
    if (!a->tabs) return 0;
    spdf_win_tabs_app_remember(a->tabs, a->canvas);
    f = app_session_frame(a);
    return spdf_win_session_save_focused(a->tabs, a->window_id, &f, spdf_win_window_is_foreground(a->window));
}

/* --- the other windows of a restored session ---------------------------------
 *
 * ONE PROCESS PER WINDOW, so "every other window opens with the first" means
 * starting the sibling processes -- and starting them NOW, the moment the
 * session names them, rather than after this window's first paint as the
 * detach path's app_spawn_window() would from the tail of a launch: measured on
 * the mac (5776dd6cf), both windows then reach the screen together instead of a
 * launch apart. Each sibling restores its own id (`--window`) and is told to
 * show BEHIND (`--behind`, spdf_win_window_show_ex), so the window the reader
 * left focused -- the one this process restored -- is the one that ends up in
 * front however the two launches interleave. --state-dir is passed along when
 * this process was given one, so a test's windows share the test's file.
 *
 * On a worker thread: CreateProcessW is milliseconds each, and this launch is
 * still assembling its first frame. The command lines are built here, where the
 * app's state is, and the thread owns the copy. */
typedef struct sibling_launch {
    wchar_t exe[MAX_PATH * 4];
    int count;
    wchar_t cmd[SPDF_WIN_SESSION_MAX_WINDOWS][MAX_PATH * 8];
} sibling_launch;

static DWORD WINAPI app_spawn_siblings_thread(void* arg) {
    sibling_launch* launch = (sibling_launch*)arg;
    int i;
    for (i = 0; i < launch->count; ++i) {
        STARTUPINFOW si;
        PROCESS_INFORMATION pi;
        memset(&si, 0, sizeof(si));
        si.cb = sizeof(si);
        memset(&pi, 0, sizeof(pi));
        if (CreateProcessW(launch->exe, launch->cmd[i], NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }
    free(launch);
    return 0;
}

static void app_spawn_siblings(app* a) {
    char ids[SPDF_WIN_SESSION_MAX_WINDOWS][SPDF_WIN_SESSION_ID_MAX];
    int n = spdf_win_session_window_ids(ids, SPDF_WIN_SESSION_MAX_WINDOWS), i;
    sibling_launch* launch;
    HANDLE thread;
    if (n <= 1) return; /* the common single-window launch, off in one branch */
    launch = (sibling_launch*)calloc(1, sizeof(*launch));
    if (!launch) return;
    if (!GetModuleFileNameW(NULL, launch->exe, (DWORD)(sizeof(launch->exe) / sizeof(launch->exe[0])))) {
        free(launch);
        return;
    }
    for (i = 0; i < n; ++i) {
        wchar_t id[SPDF_WIN_SESSION_ID_MAX];
        wchar_t* cmd;
        if (strcmp(ids[i], a->window_id) == 0) continue;
        if (MultiByteToWideChar(CP_UTF8, 0, ids[i], -1, id, (int)(sizeof(id) / sizeof(id[0]))) <= 0) continue;
        cmd = launch->cmd[launch->count++];
        if (a->state_dir[0])
            _snwprintf_s(cmd, MAX_PATH * 8, _TRUNCATE, L"\"%s\" --window %s --behind --state-dir \"%s\"", launch->exe,
                         id, a->state_dir);
        else
            _snwprintf_s(cmd, MAX_PATH * 8, _TRUNCATE, L"\"%s\" --window %s --behind", launch->exe, id);
    }
    if (launch->count == 0) {
        free(launch);
        return;
    }
    thread = CreateThread(NULL, 0, app_spawn_siblings_thread, launch, 0, NULL);
    if (thread) CloseHandle(thread);
    else app_spawn_siblings_thread(launch); /* no thread: still spawned, just not overlapped */
}

/* Preferences that are the window's to record: the two panel widths the reader
 * dragged, and the content size, as the mac writes them (windowSize is a
 * CONTENT size in points, :1798). Committed to settings.yaml at exit and on the
 * tick; the state layer skips a save whose bytes are unchanged. */
static void app_settings_record(app* a) {
    spdf_win_settings* s = spdf_win_settings_shared();
    if (a->sidebar_w > 0.0f) s->sidebar_width = (int)(a->sidebar_w + 0.5f);
    if (a->minimap_w > 0.0f) s->minimap_width = (double)a->minimap_w;
    if (a->window && !a->fullscreen && a->view_dpi > 0.0f) {
        RECT rc;
        if (GetClientRect((HWND)spdf_win_window_native_handle(a->window), &rc)) {
            s->window_width = (int)((float)(rc.right - rc.left) / a->view_dpi + 0.5f);
            s->window_height = (int)((float)(rc.bottom - rc.top) / a->view_dpi + 0.5f);
        }
    }
    spdf_win_settings_commit();
}

/* The periodic tick is the SESSION's, and only the session's. The sweep of
 * orphaned shadow copies used to ride it and now has its own one-shot ten
 * seconds after the show (spdf_win_watch_app.h app_watch_sweep_once), because
 * a reader who closed the app inside the first thirty seconds never swept. */
static void app_tick(void* user) {
    app* a = (app*)user;
    app_session_save(a);
    app_settings_record(a);
}

/* THE WINDOW'S OPENING SIZE, AND ITS FLOOR.
 *
 * This used to derive the size from page 0 at 100% -- page width plus margins,
 * shrunk to fit the work area, with NO minimum. On golden.pdf that opens a
 * 244 x 286 window: narrower than its own caption buttons, and far narrower
 * than the 84 pt of chrome the window now has to hold. macOS never did this. It
 * opens every document window at a fixed 1120 x 800 and clamps a restored size
 * into [560 … min(2200, screenW − 40)] x [380 … min(1600, screenH − 40)]
 * (ShenzhenPDFMac.mm:2912-2938, :69-70, :189-196), so a small page gets a
 * normal window with a small page in it rather than a window the size of the
 * page. The constants live in spdf_win_chrome.h with the rest of the metrics;
 * the size itself is settings.yaml's windowSize, which is where the mac keeps
 * it too, so a reader who made the window bigger gets it back that size.
 *
 * The floor is enforced twice, deliberately: here, so the window opens above it,
 * and in WM_GETMINMAXINFO, so the user cannot drag below it afterwards. Only the
 * second is load-bearing against a user; the first is what stops the app from
 * doing it to itself.
 *
 * Done before the window exists, so it uses the system DPI; WM_DPICHANGED
 * corrects anything the real monitor disagrees with. */
#define SPDF_WIN_RESTORE_MAX_W 2200.0f /* :189-196 */
#define SPDF_WIN_RESTORE_MAX_H 1600.0f
#define SPDF_WIN_SCREEN_INSET 40.0f

static float clamp_content(float want, float lo, float hi, float screen) {
    float top = screen - SPDF_WIN_SCREEN_INSET;
    if (top < hi) hi = top;
    if (hi < lo) hi = lo; /* a screen too small to satisfy both: the floor wins */
    if (want < lo) want = lo;
    if (want > hi) want = hi;
    return want;
}

static void initial_client_size(int* out_w, int* out_h) {
    const spdf_win_settings* s = spdf_win_settings_shared();
    RECT work = {0, 0, 1280, 800};
    float want_w = s->window_width > 0 ? (float)s->window_width : (float)SPDF_WIN_CHROME_DEFAULT_CONTENT_W;
    float want_h = s->window_height > 0 ? (float)s->window_height : (float)SPDF_WIN_CHROME_DEFAULT_CONTENT_H;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    *out_w = (int)clamp_content(want_w, (float)SPDF_WIN_CHROME_MIN_CONTENT_W, SPDF_WIN_RESTORE_MAX_W,
                                (float)(work.right - work.left));
    *out_h = (int)clamp_content(want_h, (float)SPDF_WIN_CHROME_MIN_CONTENT_H, SPDF_WIN_RESTORE_MAX_H,
                                (float)(work.bottom - work.top));
}

/* The reading theme a window STARTS in, from the settings and then the system:
 * an expressed preference wins (the reader toggled it once), else the system's
 * app theme (spdf_win_system_prefers_dark). Keep Image Colors is NOT composed
 * here any more: it is the selected document's own, and show_selected_tab()
 * puts it in the flags for each tab as it is shown. Windowed path only, and
 * BEFORE the canvas exists, for the two reasons spdf_win_window.h gives at
 * spdf_win_system_prefers_dark(). */
static unsigned app_initial_render_flags(void) {
    const spdf_win_settings* s = spdf_win_settings_shared();
    int dark = s->theme == SPDF_WIN_THEME_DARK ? 1 : s->theme == SPDF_WIN_THEME_LIGHT ? 0 : spdf_win_system_prefers_dark();
    return dark ? (unsigned)(SPDF_RENDER_DEFAULT | SPDF_RENDER_DARK_THEME) : (unsigned)SPDF_RENDER_DEFAULT;
}
