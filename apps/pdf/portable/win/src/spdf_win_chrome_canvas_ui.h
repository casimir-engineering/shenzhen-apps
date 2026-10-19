#pragma once

/* spdf_win_chrome_canvas_ui.h -- what the POINTER does over the document:
 * select text, follow a link, or pan.
 *
 * Split out of spdf_win_chrome_actions.h for the reason
 * tools/file-size-limits.md gives, and along a real seam: the file next door
 * routes a point to a CONTROL, and this one is what happens once the answer is
 * "no control, this is the page". It is the shell half of the six calls
 * spdf_win_canvas.h declares under "text selection and links"; the canvas owns
 * every one of the hard questions (which glyphs, which word, which link) and
 * this file owns only the gesture and the Win32 consequences of it.
 *
 * Header-only and included from spdf_win_main.cpp after `struct app` and before
 * spdf_win_chrome_actions.h, which calls into it. Same arrangement as
 * spdf_win_chrome_tabs_ui.h beside it.
 *
 * ---------------------------------------------------------------------------
 * WHICH GESTURE A LEFT DRAG IS, AND WHY IT IS DECIDED AT THE PRESS
 *
 * This port has had left-drag-to-pan since Phase 1, and the selection track now
 * needs left-drag-to-select. They are the same gesture and cannot both own it,
 * so the press decides, ONCE, from what is under the pointer:
 *
 *   over text or a link  ->  SELECT (or follow, on a click with no movement)
 *   anywhere else        ->  PAN, exactly as before
 *
 * That is what every PDF reader on both platforms does, and it is the only split
 * that keeps drag-to-pan real: a page at fit-width has margins and whitespace
 * everywhere, so there is always somewhere to grab. MIDDLE-drag pans
 * unconditionally and is untouched, which leaves a way to pan from anywhere at
 * all, including from the middle of a paragraph.
 *
 * Decided at the PRESS and not per move, because a gesture that changed its mind
 * halfway -- panning until the pointer crossed a word, then selecting -- would be
 * unusable, and because the decision costs a structured-text pass that must not
 * be paid on every pixel of pointer travel.
 *
 * ---------------------------------------------------------------------------
 * AND WHEN A LINK IS FOLLOWED, which is two different answers for the two kinds
 * of link: an in-document jump is taken on release, immediately, and a link
 * that leaves for another application waits out the double-click interval so a
 * second click can cancel it. See canvas_open_uri_after_wait() below.
 */

/* The one link model this file owns rather than delegating to the canvas: the
 * generation counter behind that wait. Everything else about a link -- which
 * rects, which target, where the jump lands -- is the canvas's. */
#include "spdf_win_links.h"

/* IS THERE TEXT (OR A LINK) HERE? The canvas answers in cursor terms, which is
 * exactly the question being asked: an I-beam means selectable text, a hand
 * means a link, and an arrow means neither. Reusing the cursor query rather than
 * adding a second predicate is what keeps the CURSOR the reader sees and the
 * GESTURE they get from pressing there in agreement -- the same rule
 * spdf_win_chrome.h states for hit-testing and painting. */
static int canvas_point_is_selectable(app* a, float canvas_x, float canvas_y) {
    spdf_win_canvas_cursor c;
    if (!a->canvas) return 0;
    c = spdf_win_canvas_cursor_at(a->canvas, canvas_x, canvas_y, 1);
    return c == SPDF_WIN_CANVAS_CURSOR_TEXT || c == SPDF_WIN_CANVAS_CURSOR_HAND;
}

/* OVER THE PAGE, THE DOCUMENT DECIDES WHICH CURSOR.
 *
 * The router answers SPDF_WIN_CC_ARROW for the whole canvas because it knows
 * nothing about documents; an I-beam over text and a hand over a link are things
 * only the canvas can see, so its answer overwrites the router's. Asked with the
 * SAME canvas-local point canvas_press() would use, so what the cursor promises
 * and what a press then does cannot disagree. */
static void canvas_cursor_override(app* a, spdf_win_input* in, const SpdfWinChromeLayout* l) {
    if (!a->canvas) return;
    switch (spdf_win_canvas_cursor_at(a->canvas, spdf_win_chrome_input_canvas_x(l, in->x),
                                      spdf_win_chrome_input_canvas_y(l, in->y), 1)) {
        case SPDF_WIN_CANVAS_CURSOR_TEXT: in->cursor = SPDF_WIN_CC_IBEAM; break;
        case SPDF_WIN_CANVAS_CURSOR_HAND: in->cursor = SPDF_WIN_CC_HAND; break;
        default: break;
    }
}

/* THE SHELL'S HALF OF A LINK.
 *
 * spdf_win_canvas.h is explicit that an INTERNAL target has already been
 * scrolled to and that a URI is deliberately NOT opened by the canvas, because
 * "launching a browser is a shell decision with a shell's security questions".
 * Here are the answers to those questions.
 *
 * ONLY http, https and mailto ARE LAUNCHED. A URI in a PDF is untrusted input
 * from a file the reader may have been sent, and ShellExecuteW will happily
 * launch anything the shell has a handler for -- file:, ms-msdt:, a UNC path, a
 * registered custom scheme belonging to some other installed application. A
 * reader clicking a footnote in a document has not consented to any of that. The
 * three schemes below are the ones a document link plausibly means and the ones
 * whose handler is a browser or a mail client; everything else is ignored
 * silently rather than opened or reported, because a dialog about a link is
 * itself a thing a hostile document could make appear.
 *
 * Case-insensitively, because a scheme is case-insensitive (RFC 3986 3.1) and
 * "HTTPS://" is a link, not an attack. */
static int canvas_scheme_is_safe(const char* uri) {
    static const char* allowed[] = {"http://", "https://", "mailto:"};
    size_t i;
    if (!uri) return 0;
    for (i = 0; i < sizeof(allowed) / sizeof(allowed[0]); ++i)
        if (_strnicmp(uri, allowed[i], strlen(allowed[i])) == 0) return 1;
    return 0;
}

static void canvas_open_uri(app* a, const char* utf8_uri) {
    wchar_t wide[2048];
    if (!canvas_scheme_is_safe(utf8_uri)) return;
    /* MB_ERR_INVALID_CHARS: a malformed URI is not opened at all rather than
     * opened with U+FFFD substituted into it, which would be a different URI
     * from the one the document contained. */
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_uri, -1, wide,
                            (int)(sizeof(wide) / sizeof(wide[0]))) <= 0)
        return;
    ShellExecuteW(a->window ? (HWND)spdf_win_window_native_handle(a->window) : NULL, L"open", wide, NULL, NULL,
                  SW_SHOWNORMAL);
}

/* AND THE WAIT IN FRONT OF IT.
 *
 * A jump inside the document happens on release, immediately -- the canvas has
 * already done it by the time canvas_release() runs. A link that hands the
 * point to ANOTHER APPLICATION waits out the double-click interval first,
 * because launching a browser is not something a second click can undo, and a
 * double-click on link text is how a reader selects the word it is printed on.
 * That asymmetry is macOS's (SPDFMacDocumentView.mm mouseUp:, the 26.9.1-1
 * release note) and spdf_win_links.h section 4 holds the mechanism: a
 * generation counter, because WM_TIMER is already queued by the time KillTimer
 * runs and the counter is what makes cancellation deterministic anyway.
 *
 * THE WAIT GETS A MESSAGE-ONLY WINDOW OF ITS OWN, which is the pattern
 * spdf_win_updater_ui.cpp already uses for its two timers. Two reasons, and
 * neither is style:
 *
 *   spdf_win_window_set_once() is documented as ONE pending one-shot PER
 *   WINDOW, and the deferred sweep of orphaned read-only copies already holds
 *   it (spdf_win_main.cpp arms it at startup, 10 s out). Arming a second one
 *   would silently replace the first, so a reader who clicks an external link
 *   in the first ten seconds of a session would cancel that sweep.
 *
 *   A timer on the DOCUMENT window would need spdf_win_window.cpp's WM_TIMER
 *   arm to learn a fourth id -- it handles exactly three and drops the rest --
 *   and that file belongs to another track.
 *
 * With its own sink the procedure that learns the id is this file's own, and
 * the sink is created lazily: a session in which nobody clicks an external
 * link creates no window.
 *
 * WHAT COULD NOT BE CHECKED LIVE, stated because the next person will try.
 * portable/win/drive-window.ps1 appears not to deliver WM_TIMER to the app at
 * all: measured with a probe build in which the app's OWN
 * spdf_win_window_set_once() -- 550 ms, its callback flipping the zoom mode so
 * the toolbar would have read "Actual Size" -- did not run either, while a
 * click in the same session followed an in-document link normally and a
 * synchronous ShellExecuteW from the same code path did open the browser. So
 * the single-click case cannot be observed under that harness in ANY timer
 * shape, and it is the harness that is the obstacle, not this file. What IS
 * checked: the counter (portable/win/tests/link_nav_test.c, 70 checks) and,
 * live, that a DOUBLE click on an external link opens nothing 1.5 s later.
 *
 * FILE-STATIC state, because a window procedure takes no user pointer -- and
 * because this is exactly where mac keeps its _pendingLinkActivation: on the
 * document view, of which this process has one. */
#define SPDF_WIN_LINK_ACTIVATION_TIMER 1

static spdf_win_link_activation g_link_activation;
static unsigned g_link_activation_token;
static app* g_link_activation_app;
static HWND g_link_activation_sink;

static LRESULT CALLBACK canvas_link_activation_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == WM_TIMER && wparam == SPDF_WIN_LINK_ACTIVATION_TIMER) {
        const char* uri = NULL;
        /* Killed BEFORE the activation runs, so a wait that is over cannot
         * repeat however long opening the link takes. */
        KillTimer(hwnd, SPDF_WIN_LINK_ACTIVATION_TIMER);
        /* A stale token is the whole point of the counter: the press that
         * cancelled this moved it, and a WM_TIMER already in the queue when
         * KillTimer ran drops itself here. */
        if (spdf_win_link_activation_fire(&g_link_activation, g_link_activation_token, &uri)) {
            g_link_activation_token = 0u;
            canvas_open_uri(g_link_activation_app, uri);
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

/* The sink, created on the first external link of the session. NULL when the
 * class or the window could not be made, which the caller reads as "no wait
 * available" and follows the link at once. */
static HWND canvas_link_activation_sink(void) {
    static const wchar_t* k_class = L"ShenzhenPDFLinkActivation";
    WNDCLASSEXW wc;

    if (g_link_activation_sink) return g_link_activation_sink;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = canvas_link_activation_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = k_class;
    /* A second registration fails with ERROR_CLASS_ALREADY_EXISTS, which is
     * fine: CreateWindowExW only needs the class to exist. */
    RegisterClassExW(&wc);
    g_link_activation_sink =
        CreateWindowExW(0, k_class, NULL, 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, GetModuleHandleW(NULL), NULL);
    return g_link_activation_sink;
}

/* mac's -cancel, plus the timer. Called on every press over the page (mac
 * cancels in -mouseDown:, before it knows what the press is) and on a
 * cancelled drag (mac's -cancelTransientInteraction). The counter is what makes
 * this deterministic; KillTimer is the tidy-up, not the mechanism. */
static void canvas_cancel_link_activation(void) {
    spdf_win_link_activation_cancel(&g_link_activation);
    g_link_activation_token = 0u;
    if (g_link_activation_sink) KillTimer(g_link_activation_sink, SPDF_WIN_LINK_ACTIVATION_TIMER);
}

static void canvas_open_uri_after_wait(app* a, const char* utf8_uri) {
    HWND sink;

    /* A scheme canvas_open_uri() would ignore is not worth waiting for, and any
     * pending activation stays cancelled: the reader clicked something else. */
    if (!canvas_scheme_is_safe(utf8_uri)) {
        canvas_cancel_link_activation();
        return;
    }
    /* No window means no message pump to deliver WM_TIMER: the headless probe
     * and the tests. Nothing there can click twice, so there is nothing to wait
     * for and swallowing the link would be the only observable difference. */
    sink = a && a->window ? canvas_link_activation_sink() : NULL;
    if (!sink) {
        canvas_open_uri(a, utf8_uri);
        return;
    }
    g_link_activation_token = spdf_win_link_activation_schedule(&g_link_activation, utf8_uri);
    if (!g_link_activation_token) {
        /* Refused -- a URI too long to copy whole. The schedule already
         * superseded whatever was pending; this stops that one's timer too. */
        canvas_cancel_link_activation();
        return;
    }
    g_link_activation_app = a;
    if (SetTimer(sink, SPDF_WIN_LINK_ACTIVATION_TIMER,
                 spdf_win_link_activation_delay_ms((long)GetDoubleClickTime()), NULL))
        return;
    /* SetTimer failed (the process is out of timers). Following the link the
     * reader clicked is a better failure than silently swallowing it. */
    canvas_cancel_link_activation();
    canvas_open_uri(a, utf8_uri);
}

/* A LEFT PRESS ON THE PAGE. Returns 1 when the view changed.
 *
 * Sets a->drag to whichever of the two canvas gestures this is, which is what
 * every later move and the release read. */
static int canvas_press(app* a, const spdf_win_input* in, const SpdfWinChromeLayout* l) {
    float cx = spdf_win_chrome_input_canvas_x(l, in->x);
    float cy = spdf_win_chrome_input_canvas_y(l, in->y);

    /* BEFORE ANYTHING ELSE, and for ANY button: this press is the second click
     * that gets to cancel a link about to leave the document. mac cancels at
     * the same point, at the top of -mouseDown: before it converts a single
     * coordinate and before it checks for the Control-click that opens the
     * context menu -- so its context-menu gesture cancels too, and a right
     * press here is that same gesture. */
    canvas_cancel_link_activation();

    if (in->button != SPDF_WIN_CB_LEFT || !canvas_point_is_selectable(a, cx, cy)) {
        a->drag = SPDF_WIN_CA_CANVAS; /* pan, exactly as before */
        return 0;
    }
    a->drag = SPDF_WIN_CA_CANVAS_SELECT;
    /* click_count is the ROUTER's accumulation (spdf_win_window.h): 1 places a
     * caret, 2 selects a word, 3 or more selects the block. A press that
     * reported 0 -- which nothing does -- is still a single click. */
    return spdf_win_canvas_pointer_press(a->canvas, cx, cy, in->click_count ? in->click_count : 1u);
}

static int canvas_drag(app* a, const spdf_win_input* in, const SpdfWinChromeLayout* l) {
    if (!a->canvas) return 0;
    return spdf_win_canvas_pointer_drag(a->canvas, spdf_win_chrome_input_canvas_x(l, in->x),
                                        spdf_win_chrome_input_canvas_y(l, in->y));
}

/* THE RELEASE, WHICH IS ALSO WHERE A LINK IS FOLLOWED.
 *
 * `cancelled` is a button-up whose button is SPDF_WIN_CB_NONE -- the capture was
 * taken away by an Alt+Tab or a system modal, which spdf_win_window.h documents
 * as a CANCELLED drag rather than a release. A cancel must not follow a link:
 * the reader never let go over it. */
static int canvas_release(app* a, int cancelled) {
    spdf_win_canvas_link_nav nav;
    int changed;
    if (!a->canvas) return 0;
    if (cancelled) {
        /* mac's -cancelTransientInteraction: a capture taken away by an
         * Alt+Tab must not leave a browser launch armed either. */
        canvas_cancel_link_activation();
        spdf_win_canvas_pointer_cancel(a->canvas);
        return 0;
    }
    memset(&nav, 0, sizeof(nav));
    changed = spdf_win_canvas_pointer_release(a->canvas, &nav);
    /* INTERNAL has already been scrolled to by the canvas -- at the
     * destination's own y (spdf_win_links.h section 3) -- so there is genuinely
     * nothing to do for it, and forwarding it back would scroll twice. A URI
     * waits; see canvas_open_uri_after_wait(). */
    if (nav.kind == SPDF_LINK_URI) canvas_open_uri_after_wait(a, nav.uri);
    else if (nav.kind == SPDF_LINK_INTERNAL) changed = 1;
    return changed;
}
