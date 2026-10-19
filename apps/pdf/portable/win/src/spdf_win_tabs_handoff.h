#pragma once

/* spdf_win_tabs_handoff.h -- ONE CONTINUOUS DRAG that can end in another
 * window's tab bar.
 *
 * macOS does this inside one process: the strip starts an NSDraggingSession,
 * every strip in the app is a registered drop target, and AppKit supplies the
 * cursor, the Escape cancel and the cross-window routing
 * (SPDFMacTabStripView.mm:753-925). On Windows a window IS a process
 * (spdf_win_chrome_tabs_ui.h, "ANOTHER WINDOW IS ANOTHER PROCESS"), so the same
 * gesture has to be assembled from three pieces:
 *
 *   1. A NESTED DRAG LOOP in the source process. Once the pointer leaves the
 *      strip the gesture stops being a reorder, but it is not over either --
 *      release note 26.7.17-1: "pull the tab out of the bar and slide it back
 *      ... without releasing the mouse". So the source takes the capture back
 *      and pumps the messages itself until the button comes up, Escape is
 *      pressed, or the capture is taken away. That is the same shape
 *      DoDragDrop() has, and the same shape TrackPopupMenu() and the file
 *      dialog already have in this app: a modal loop reached from a click.
 *   2. WHICH WINDOW IS UNDER THE POINTER, answered with WindowFromPoint plus a
 *      window-class check, and then with the REAL chrome layout
 *      (spdf_win_chrome_layout) applied to that window's client rect -- the tab
 *      strip's band depends on nothing but the client size and the DPI, both of
 *      which Win32 reports for another process's HWND. So the source can tell
 *      "over that window's tab bar" from "over its document" without asking it
 *      anything.
 *   3. THE HAND-OVER ITSELF, through session.yaml under the well-known parking
 *      id (SPDF_WIN_SESSION_HANDOFF_ID) -- the file that is ALREADY the
 *      hand-over for a tear-off, so the tab's page, zoom, search text and
 *      read-only binding travel through the one schema this port has, with no
 *      second serializer to keep in step.
 *
 * WHY NOT OLE DRAG-AND-DROP. DoDragDrop + IDropTarget would get the cursor
 * feedback and the Escape cancel from the shell, and it is the closest thing to
 * what AppKit hands macOS. Two things ruled it out. RegisterDragDrop REPLACES
 * WM_DROPFILES on a window, and this app's file drop is deliberately the old
 * shell protocol ("it delivers exactly what this app wants ... and costs no
 * COM", spdf_win_window_lifecycle.h) -- so adopting OLE means reimplementing
 * the file drop through IDropTarget too, in a file this track does not own. And
 * every interesting decision would then live inside a shell modal loop where no
 * test can reach it; here the three things that can actually be wrong -- which
 * window a point is over, which index a slot means, and whether the tab's view
 * state survives the file -- are all reachable without a desktop and pinned by
 * portable/win/tests/tabs_handoff_test.c.
 *
 * WHAT TRAVELS BETWEEN THE TWO PROCESSES is three WM_COMMANDs and nothing else.
 * WM_COMMAND rather than WM_APP because a WM_COMMAND already has a route from
 * another process's PostMessage all the way into a handler this track owns
 * (spdf_win_window.cpp -> SPDF_WIN_INPUT_COMMAND -> command_perform ->
 * spdf_win_cmd_window_perform), and because SPDF_WIN_INPUT_APP_MESSAGE
 * deliberately drops wParam and lParam. The receiving window reads the pointer
 * position itself: the message means "a tab is being dragged over you", and
 * where the pointer is when that gets drawn is the truth the reader can see.
 *
 * Header-only, included at the END of spdf_win_chrome_tabs_ui.h -- after the
 * tear-off and the window spawner it calls. The receiving half is in
 * spdf_win_cmd_window.h. Not part of the port's public surface.
 */

#include <windowsx.h> /* GET_X_LPARAM / GET_Y_LPARAM, for the loop's own WM_MOUSEMOVE */

/* Ids in a range of their own: above the Open Recent rows (0x100-0x109) and far
 * below the tab overflow popup's absolute WM_COMMAND ids (0x800), so a stray
 * message can never be read as either. Never persisted, never in a menu -- the
 * only sender is another ShenzhenPDF window. */
#define SPDF_WIN_TABS_CMD_DRAG_OVER 0x200
#define SPDF_WIN_TABS_CMD_DRAG_LEAVE 0x201
#define SPDF_WIN_TABS_CMD_DRAG_DROP 0x202

static void handoff_post(HWND hwnd, int command) {
    if (hwnd) PostMessageW(hwnd, WM_COMMAND, (WPARAM)(SPDF_WIN_MENU_ID_BASE + command), 0);
}

/* --- where a screen point is ---------------------------------------------- */

/* The DPI of a window that may belong to another process. Same GetProcAddress
 * dance spdf_win_window_frame.h does for our own window, for the same reason:
 * GetDpiForWindow is Windows 10 1607 and this port still starts on older ones,
 * where 96 is the only honest answer. */
static float handoff_dpi_scale(HWND hwnd) {
    typedef UINT(WINAPI * get_dpi_fn)(HWND);
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32) {
        get_dpi_fn get_dpi = (get_dpi_fn)GetProcAddress(user32, "GetDpiForWindow");
        if (get_dpi) {
            UINT dpi = get_dpi(hwnd);
            if (dpi >= 48 && dpi <= 960) return (float)dpi / (float)USER_DEFAULT_SCREEN_DPI;
        }
    }
    return 1.0f;
}

/* Is `screen_pt` over THIS window's tab bar, and if so where along it?
 *
 * The band comes from spdf_win_chrome_layout() rather than from the strip's own
 * constant, so this cannot drift from what the window drew: the band collapses
 * on a window too short for both chrome bands, and the caption reserve at its
 * trailing end is excluded -- dropping a tab on another window's Close button
 * must not insert a tab into it.
 *
 * The model is zeroed, which is right for everything the band depends on: only
 * `presentation` could change it, and a presenting window has no strip to drop
 * onto. Both outputs are in STRIP-LOCAL POINTS, the space every function in
 * spdf_win_tabstrip.h takes. */
static int handoff_strip_hit(HWND hwnd, POINT screen_pt, double* out_strip_x, double* out_strip_w) {
    RECT rc;
    POINT pt = screen_pt;
    SpdfWinChromeModel model;
    SpdfWinChromeLayout l;
    double s;
    if (!hwnd || !GetClientRect(hwnd, &rc)) return 0;
    if (!ScreenToClient(hwnd, &pt)) return 0;
    s = (double)handoff_dpi_scale(hwnd);
    if (!(s > 0.0)) s = 1.0;
    memset(&model, 0, sizeof(model));
    spdf_win_chrome_layout(&model, (unsigned)(rc.right - rc.left), (unsigned)(rc.bottom - rc.top), (float)s, &l);
    if (spdf_win_chrome_rect_empty(l.tabstrip)) return 0;
    if (!spdf_win_chrome_contains(l.tabstrip, (float)pt.x, (float)pt.y)) return 0;
    if (spdf_win_chrome_contains(l.caption, (float)pt.x, (float)pt.y)) return 0;
    if (out_strip_x) *out_strip_x = ((double)pt.x - (double)l.tabstrip.x) / s;
    if (out_strip_w) *out_strip_w = (double)l.tabstrip.w / s;
    return 1;
}

/* The ShenzhenPDF window whose TAB BAR is under `screen_pt`, or NULL.
 *
 * WindowFromPoint ignores the mouse capture -- which the drag is holding -- and
 * reports the topmost window at the point across every process, which is
 * exactly the question. GA_ROOT because a hit can land on a child and the strip
 * belongs to the top-level window. The class-name check is what keeps a tab
 * from being dropped into some other application under the pointer. */
static HWND handoff_window_at(POINT screen_pt, double* out_strip_x, double* out_strip_w) {
    wchar_t cls[64];
    HWND hwnd = WindowFromPoint(screen_pt);
    if (!hwnd) return NULL;
    hwnd = GetAncestor(hwnd, GA_ROOT);
    if (!hwnd) return NULL;
    if (GetClassNameW(hwnd, cls, (int)(sizeof(cls) / sizeof(cls[0]))) <= 0) return NULL;
    if (wcscmp(cls, spdf_win_window_class_name()) != 0) return NULL;
    return handoff_strip_hit(hwnd, screen_pt, out_strip_x, out_strip_w) ? hwnd : NULL;
}

/* --- one flight ----------------------------------------------------------- */

typedef struct SpdfWinTabFlight {
    HWND self;
    int index;    /* the tab being dragged, in THIS window's model */
    HWND target;  /* the foreign window currently showing an indicator, or NULL */
    int own_slot; /* the slot in OUR strip, or -1 when the pointer is elsewhere */
    /* OUR strip's width in points as of the last time the pointer was over it.
     * Remembered rather than re-measured on release, so a release that lands a
     * pixel outside the band still completes the reorder the indicator was
     * showing. */
    double own_strip_w;
} SpdfWinTabFlight;

/* Our own indicator, on or off. Reuses the reorder drag's two model fields, so
 * the yellow line the reader sees while sliding a torn-off tab back in is
 * literally the one a reorder draws (spdf_win_chrome_paint.cpp:395). */
static void flight_show_own(app* a, SpdfWinTabFlight* f, int slot) {
    if (slot == f->own_slot) return;
    f->own_slot = slot;
    a->drag_tab = slot >= 0 ? f->index : -1;
    a->drop_slot = slot;
    spdf_win_window_invalidate(a->window);
}

static void flight_leave_target(SpdfWinTabFlight* f) {
    if (!f->target) return;
    handoff_post(f->target, SPDF_WIN_TABS_CMD_DRAG_LEAVE);
    f->target = NULL;
}

static void flight_track(app* a, SpdfWinTabFlight* f, POINT screen_pt) {
    double strip_x = 0.0, strip_w = 0.0;
    HWND over = handoff_window_at(screen_pt, &strip_x, &strip_w);
    if (over && over == f->self) {
        flight_leave_target(f);
        f->own_strip_w = strip_w;
        flight_show_own(a, f,
                        spdf_win_tabstrip_drop_slot(strip_w, spdf_win_tabs_count(a->tabs),
                                                    spdf_win_tabs_selected_index(a->tabs), strip_x));
        return;
    }
    flight_show_own(a, f, -1);
    if (over != f->target) {
        flight_leave_target(f);
        f->target = over;
    }
    /* On every move, not only on every change: the receiving window reads the
     * pointer itself, so a message is how it learns the pointer moved. */
    if (f->target) handoff_post(f->target, SPDF_WIN_TABS_CMD_DRAG_OVER);
}

/* THE TAB LEAVES THIS WINDOW. Park it, drop it locally, then tell the other
 * window to take it -- the tear-off's order (spdf_win_session.h: "the file is
 * consistent before the child reads it"), with a message where the tear-off
 * has a CreateProcess. Returns 1 when the tab went. */
static int flight_hand_over(app* a, SpdfWinTabFlight* f) {
    /* The window may have closed while the tab was being dragged over it. The
     * tab must not leave here for a window that is gone -- the caller then
     * gives it its own window instead. */
    if (!IsWindow(f->target)) return 0;
    if (f->index == spdf_win_tabs_selected_index(a->tabs)) spdf_win_tabs_app_remember(a->tabs, a->canvas);
    if (!spdf_win_session_detach_tab_as(a->tabs, f->index, NULL, SPDF_WIN_SESSION_HANDOFF_ID)) return 0;
    /* Unwatched, not forgotten: the shadow copy (if any) is the other window's
     * now, exactly as for a tear-off. */
    spdf_win_tabs_open_unwatch(spdf_win_tabs_path(a->tabs, f->index));
    spdf_win_tabs_close(a->tabs, f->index, 1);
    show_selected_tab(a);
    app_session_save(a);
    handoff_post(f->target, SPDF_WIN_TABS_CMD_DRAG_DROP);
    /* THE LAST TAB CAN LEAVE. Dragging a window's only tab into another window
     * empties this one, and an empty window with a sibling closes -- the rule
     * chrome_close_tab() already states for Ctrl+W. (The reorder drag only
     * reaches here with two or more tabs today, so this is the path a future
     * one-tab drag takes; it costs two lines and its absence would leave a
     * blank window behind.) */
    if (spdf_win_tabs_count(a->tabs) == 0 && spdf_win_session_other_windows(a->window_id) > 0 && a->window)
        PostMessageW((HWND)spdf_win_window_native_handle(a->window), WM_CLOSE, 0, 0);
    return 1;
}

/* Back into our OWN strip: the reorder that the pointer leaving the bar
 * interrupted, finished. The live tab moves -- no reload, no process -- which is
 * what macOS's same-window branch does for the same reason (:895-925). */
static int flight_reinsert(app* a, SpdfWinTabFlight* f, int slot) {
    int start = 0, visible = 0, to;
    if (slot < 0 || !(f->own_strip_w > 0.0)) return 0;
    spdf_win_tabstrip_visible_range(f->own_strip_w, spdf_win_tabs_count(a->tabs),
                                    spdf_win_tabs_selected_index(a->tabs), &start, &visible);
    /* move_index, not insert_index: this tab IS in this strip, so the two slots
     * either side of it are the same no-op place (spdf_win_tabs_drag.h). */
    to = spdf_win_tabstrip_move_index(start + slot, f->index, spdf_win_tabs_count(a->tabs));
    if (to == f->index) return 0;
    if (!spdf_win_tabs_move(a->tabs, f->index, to)) return 0;
    app_session_save(a);
    return 1;
}

/* THE DRAG, from the moment the pointer left the bar to the moment it stops.
 *
 * Reached from spdf_win_chrome_actions.h's DRAG_TAB arm, which has already
 * cleared a->drag and given the capture back; the button is still physically
 * down, so this takes the capture again and owns the gesture until it ends.
 * Everything the loop does not care about is dispatched, so the window keeps
 * repainting its own indicator while the drag runs.
 *
 * FOUR WAYS IT ENDS, all of them the release note's:
 *   the button comes up over another window's bar   -> the tab moves there
 *   the button comes up over our own bar            -> the reorder completes
 *   the button comes up anywhere else               -> its own window, at once
 *   Escape, or the capture is taken away            -> nothing moves */
static int chrome_detach_tab(app* a, int index) {
    SpdfWinTabFlight f;
    MSG msg;
    int changed = 0, cancelled = 0, dropped = 0;

    /* NO TAB-COUNT GUARD. A window's ONLY tab has nowhere to go on its own --
     * it is already its own window -- but it can still be dropped on another
     * window's bar, and this is the function that tells those apart, so the
     * decision belongs below rather than here. (Releasing a lone tab outside
     * every bar reaches chrome_detach_tab_into_new_window(), which refuses a
     * one-tab window on its own; today the drag arm next door still stops a
     * lone tab from ever leaving the bar.) */
    if (!a->tabs || !a->window || index < 0 || index >= spdf_win_tabs_count(a->tabs)) return 0;

    memset(&f, 0, sizeof(f));
    f.self = (HWND)spdf_win_window_native_handle(a->window);
    f.index = index;
    f.own_slot = -1;
    if (!f.self) return 0;

    SetCapture(f.self);
    while (!cancelled && !dropped) {
        if (!GetMessageW(&msg, NULL, 0, 0)) {
            /* WM_QUIT during a drag: put it back for the real pump and let go. */
            PostQuitMessage((int)msg.wParam);
            cancelled = 1;
            break;
        }
        if (msg.hwnd == f.self) {
            switch (msg.message) {
                case WM_MOUSEMOVE: {
                    POINT pt;
                    pt.x = GET_X_LPARAM(msg.lParam);
                    pt.y = GET_Y_LPARAM(msg.lParam);
                    if (ClientToScreen(f.self, &pt)) flight_track(a, &f, pt);
                    continue;
                }
                case WM_LBUTTONUP:
                    dropped = 1;
                    continue;
                /* Any other button, or Escape, abandons the drag -- AppKit's own
                 * rule for a dragging session (SPDFMacTabStripView.mm:806-813,
                 * "cancelled ... rather than concluded by a drop"). */
                case WM_RBUTTONDOWN:
                case WM_MBUTTONDOWN:
                    cancelled = 1;
                    continue;
                case WM_KEYDOWN:
                case WM_SYSKEYDOWN:
                    if (msg.wParam == VK_ESCAPE) cancelled = 1;
                    continue;
                case WM_CAPTURECHANGED:
                    cancelled = 1;
                    continue;
                /* The cursor belongs to the DRAG, not to whatever the pointer
                 * has got to -- the rule chrome_mouse() states for every other
                 * gesture, kept here because a->drag is no longer set. */
                case WM_SETCURSOR:
                    SetCursor(LoadCursorW(NULL, MAKEINTRESOURCEW(32512 /* IDC_ARROW */)));
                    continue;
                default: break;
            }
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (GetCapture() == f.self) ReleaseCapture();

    if (cancelled) {
        /* NOTHING MOVED. The tab is where it was, both indicators go out. */
        flight_leave_target(&f);
        flight_show_own(a, &f, -1);
        return 1;
    }
    if (f.target) {
        HWND target = f.target;
        changed = flight_hand_over(a, &f);
        f.target = NULL;
        if (changed) {
            /* The window that just received a document should be the one in
             * front, as it is when a tear-off opens a new one. */
            SetForegroundWindow(target);
            return 1;
        }
        /* Parking failed (an unreadable session.yaml): fall through and give
         * the tab its own window rather than losing the gesture. */
        handoff_post(target, SPDF_WIN_TABS_CMD_DRAG_LEAVE);
    }
    if (f.own_slot >= 0) {
        int slot = f.own_slot;
        flight_show_own(a, &f, -1);
        return flight_reinsert(a, &f, slot) | 1;
    }
    flight_show_own(a, &f, -1);
    /* Released outside every tab bar: its own window, immediately -- the
     * release note's "now immediately (the brief slide-back animation is
     * gone)". */
    return chrome_detach_tab_into_new_window(a, index) | 1;
}
