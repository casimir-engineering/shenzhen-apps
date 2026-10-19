/* spdf_win_modal_scope.h — one rule, made structural: NO DIALOG MAY LEAVE ITS
 * OWNER DISABLED.
 *
 * WHY THIS FILE EXISTS. A Win32 window that is disabled cannot be activated by
 * a click, by Alt+Tab, or by SetForegroundWindow. If the dialog that disabled
 * it is invisible, off-screen, on another thread, or never appeared at all, the
 * app is indistinguishable from a hung one: it repaints, it answers WM_NULL,
 * it is not marked "not responding" -- and no input reaches it. That is the
 * exact shape of the report this file was written for ("the app was never
 * responsive to any user input and not even focusable"), and section 14 of
 * portable/docs/windows-native-observations.md is the measurement.
 *
 * Before this header every modal site in the port spelled the same four lines
 * out by hand:
 *
 *     if (parent) was_enabled = IsWindowEnabled(parent);
 *     if (parent && was_enabled) EnableWindow(parent, FALSE);
 *     ... a message loop, or a system dialog ...
 *     if (parent && was_enabled) { EnableWindow(parent, TRUE); SetForegroundWindow(parent); }
 *
 * Correct in each place, and correct only for as long as no path leaves between
 * the second line and the fourth. A scope cannot be left: the destructor runs
 * on the early return, on the exception, and on the watchdog giving up.
 *
 * WHAT THE SCOPE ADDS BEYOND "re-enable":
 *
 *   THE OWNER'S THREAD. EnableWindow is a cross-thread operation, so a dialog
 *   run on a WORKER thread against a main-window owner disables that owner from
 *   a thread that does not own it and cannot be reasoned about. No site in this
 *   port does that today; if one is ever added, the scope REFUSES the disable
 *   rather than performing it -- a dialog that is merely not modal is a bug you
 *   can see and click your way out of, a main window disabled from a foreign
 *   thread is not.
 *
 *   ACTIVATION. Windows does not reliably hand the foreground back to the owner
 *   after a dialog that ran on another thread, or after one that failed to
 *   appear (TaskDialogIndirect answers E_* when the Common Controls 6 assembly
 *   is not active; DialogBoxParam answers -1). The scope restores it -- but
 *   only when this process held the foreground when the scope opened, so a
 *   dialog finishing in the background never steals the reader's focus from
 *   whatever they moved to.
 *
 *   PLACEMENT. A dialog created at CW_USEDEFAULT is cascaded onto the PRIMARY
 *   monitor, not the owner's; with the app on a second display the reader is
 *   left with a disabled window and a modal dialog they cannot see.
 *   spdf_win_modal_place_point() is the pure geometry (centre on the owner,
 *   then clamp into that monitor's work area) and is covered headlessly by
 *   portable/win/tests/modal_scope_test.c.
 *
 * WHAT IT DOES NOT DO. It does not run a message loop and it does not know what
 * a dialog is. Sites keep their own loops; this only owns the enable/disable
 * and the activation that go around one.
 */
#ifndef SPDF_WIN_MODAL_SCOPE_H
#define SPDF_WIN_MODAL_SCOPE_H

#include <windows.h>

typedef struct SpdfWinModalScope {
    HWND owner;                /* NULL when there is nothing to restore */
    int disabled;              /* THIS scope is the one that disabled the owner */
    int owner_had_foreground;  /* this process was in front when the scope opened */
    int wrong_thread;          /* the caller does not own `owner` -- see the header */
} SpdfWinModalScope;

/* Whether `owner` belongs to the calling thread. A window with no thread (a
 * destroyed handle) counts as fine: there is nothing to disable. */
static int spdf_win_modal_owner_thread_ok(HWND owner) {
    DWORD tid;
    if (!owner) return 1;
    tid = GetWindowThreadProcessId(owner, NULL);
    return tid == 0 || tid == GetCurrentThreadId();
}

/* Does this process own the foreground right now? */
static int spdf_win_modal_process_is_foreground(void) {
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    if (!fg) return 0;
    GetWindowThreadProcessId(fg, &pid);
    return pid == GetCurrentProcessId();
}

/* Open the scope: remember, then disable. Safe with a NULL owner, a destroyed
 * owner, and an owner that is ALREADY disabled by an outer scope -- in which
 * case this one records that it did not disable anything and the outer scope
 * stays the one that re-enables. */
static void spdf_win_modal_scope_begin(SpdfWinModalScope* s, void* owner_handle) {
    HWND owner = (HWND)owner_handle;
    if (!s) return;
    s->owner = NULL;
    s->disabled = 0;
    s->owner_had_foreground = 0;
    s->wrong_thread = 0;
    if (!owner || !IsWindow(owner)) return;
    s->owner = owner;
    s->owner_had_foreground = spdf_win_modal_process_is_foreground();
    if (!spdf_win_modal_owner_thread_ok(owner)) {
        /* Loud in a debugger, harmless in a release build, and NOT disabled:
         * the whole point of the check is that this state must never reach a
         * reader as a window they cannot click. */
        s->wrong_thread = 1;
        OutputDebugStringW(L"ShenzhenPDF: a modal scope was opened on a thread that does not own its window; "
                           L"the owner was left enabled deliberately.\n");
        return;
    }
    if (IsWindowEnabled(owner)) {
        EnableWindow(owner, FALSE);
        s->disabled = 1;
    }
}

/* Close the scope: re-enable, then give the owner the activation back. Runs
 * exactly once; calling it twice is a no-op. */
static void spdf_win_modal_scope_end(SpdfWinModalScope* s) {
    HWND owner;
    if (!s) return;
    owner = s->owner;
    s->owner = NULL;
    if (!owner || !IsWindow(owner)) {
        s->disabled = 0;
        return;
    }
    if (s->disabled) {
        EnableWindow(owner, TRUE);
        s->disabled = 0;
    }
    /* A window that is still disabled (an outer scope owns it), hidden, or
     * minimised must not be activated: SetForegroundWindow on a minimised
     * window restores it, which is a window the reader did not ask to see. */
    if (!IsWindowEnabled(owner) || !IsWindowVisible(owner) || IsIconic(owner)) return;
    if (!s->owner_had_foreground) return;
    /* The reader may have moved to another application while the dialog was up.
     * Their choice wins over ours. */
    if (!spdf_win_modal_process_is_foreground()) return;
    SetActiveWindow(owner);
    SetForegroundWindow(owner);
}

/* --- WM_QUIT, which a nested loop must not eat --------------------------- */

/* EVERY MODAL LOOP IN THIS PORT IS SHAPED `while (!finished && GetMessageW(...)
 * > 0)`, and GetMessageW answers 0 for exactly one message: WM_QUIT. So the
 * condition that ends the loop cleanly is also the condition that SWALLOWS a
 * request to quit. WM_QUIT is not dispatched and not re-queued; it is returned
 * once and consumed. The outer pump in spdf_win_window.cpp then never sees it,
 * and an app asked to close while any dialog was open simply carried on with
 * the dialog gone.
 *
 * Windows itself posts WM_QUIT on a session end, and so does anything that
 * calls PostQuitMessage while a dialog is up. The fix is one line at the bottom
 * of each loop, and it has to distinguish the two ways out, which is why it
 * takes the value GetMessageW returned rather than guessing:
 *
 *     BOOL got;
 *     while (!st.finished && (got = GetMessageW(&msg, NULL, 0, 0)) > 0) { ... }
 *     spdf_win_modal_requeue_quit(got, &msg);
 *
 * -1 is GetMessageW's error return (an invalid window, usually a race with
 * teardown); there is no quit to forward and re-posting one would invent a
 * shutdown nobody asked for. */
static void spdf_win_modal_requeue_quit(int got, const MSG* msg) {
    if (got != 0) return;
    PostQuitMessage(msg ? (int)msg->wParam : 0);
}

/* --- placement ------------------------------------------------------------ */

/* PURE. Where a `w` x `h` dialog goes: centred on `owner` when there is one,
 * otherwise on the work area, and always clamped inside `work`. The right and
 * bottom edges are pulled in first so a dialog LARGER than the work area is
 * pinned to its top-left corner -- with the title bar and the first buttons on
 * screen -- rather than to its bottom-right, where nothing usable is. */
static POINT spdf_win_modal_place_point(RECT owner, int have_owner, RECT work, int w, int h) {
    POINT p;
    if (have_owner) {
        p.x = owner.left + ((owner.right - owner.left) - w) / 2;
        p.y = owner.top + ((owner.bottom - owner.top) - h) / 2;
    } else {
        p.x = work.left + ((work.right - work.left) - w) / 2;
        p.y = work.top + ((work.bottom - work.top) - h) / 2;
    }
    if (p.x + w > work.right) p.x = work.right - w;
    if (p.y + h > work.bottom) p.y = work.bottom - h;
    if (p.x < work.left) p.x = work.left;
    if (p.y < work.top) p.y = work.top;
    return p;
}

/* Move `dialog` to that point. Call it after the window is created and sized
 * and BEFORE it is shown, so it never appears at the cascade position first.
 * Nothing is resized and nothing is activated. */
static void spdf_win_modal_place_on_owner(HWND dialog, HWND owner) {
    RECT d;
    RECT o;
    RECT empty;
    MONITORINFO mi;
    HMONITOR mon;
    POINT p;
    int have_owner;

    if (!dialog || !IsWindow(dialog) || !GetWindowRect(dialog, &d)) return;
    have_owner = owner && IsWindow(owner) && IsWindowVisible(owner) && !IsIconic(owner) && GetWindowRect(owner, &o);
    if (!have_owner) {
        empty.left = empty.top = empty.right = empty.bottom = 0;
        o = empty;
    }
    /* The OWNER's monitor, not the primary and not the cascade's: that is the
     * display the reader is looking at. MONITOR_DEFAULTTONEAREST so a window
     * dragged half off a display still resolves. */
    mon = MonitorFromWindow(have_owner ? owner : dialog, MONITOR_DEFAULTTONEAREST);
    memset(&mi, 0, sizeof(mi));
    mi.cbSize = sizeof(mi);
    if (!mon || !GetMonitorInfoW(mon, &mi)) return;
    p = spdf_win_modal_place_point(o, have_owner, mi.rcWork, d.right - d.left, d.bottom - d.top);
    SetWindowPos(dialog, NULL, p.x, p.y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

#ifdef __cplusplus
/* The scope as a scope. Every .cpp modal site uses this rather than the two
 * calls, because the point of the file is that there is no path out that skips
 * the second one. */
struct SpdfWinModalGuard {
    SpdfWinModalScope scope;
    explicit SpdfWinModalGuard(HWND owner) { spdf_win_modal_scope_begin(&scope, owner); }
    ~SpdfWinModalGuard() { spdf_win_modal_scope_end(&scope); }
    /* Close it early, on the ordinary path, so the owner comes back the instant
     * the dialog is gone rather than after whatever teardown follows. Idempotent
     * -- the destructor is still the net under every other path out. */
    void end() { spdf_win_modal_scope_end(&scope); }

private:
    SpdfWinModalGuard(const SpdfWinModalGuard&);
    SpdfWinModalGuard& operator=(const SpdfWinModalGuard&);
};
#endif

#endif /* SPDF_WIN_MODAL_SCOPE_H */
