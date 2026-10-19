/* window_activation_test.c -- the app's REAL window, and the four ways a
 * Win32 window can be on screen and take no input.
 *
 * WHY. The report this campaign is chasing is "the app was never responsive to
 * any user input and not even focusable". A window can be exactly that, and
 * every way it can be is a property of the window itself rather than of the
 * routing behind it:
 *
 *   WS_EX_TRANSPARENT  -- the mouse falls through to whatever is behind;
 *   WS_EX_LAYERED with an alpha of 0 -- drawn, invisible, and not hit-tested;
 *   WS_EX_NOACTIVATE   -- clicking it never gives it the keyboard;
 *   MA_NOACTIVATE from WM_MOUSEACTIVATE, or a WM_NCACTIVATE that is eaten --
 *                         the same, one message down.
 *
 * None of them is in this port's sources (a grep for GWL_EXSTYLE,
 * SetLayeredWindowAttributes, WM_MOUSEACTIVATE and WM_NCACTIVATE across
 * portable/win/src finds only spdf_win_gpu_prewarm.h's offscreen 64x64 popup,
 * which is never shown and is destroyed with its worker). But "the code does
 * not contain it" is an argument about today's sources; this is the measurement,
 * on a live HWND, across the state changes that would be the plausible way to
 * acquire one by accident -- show, full screen, back, maximize, restore.
 *
 * WHAT IT CANNOT REACH, and this is stated rather than glossed: the Markdown
 * reload and the tab hand-off drag both belong to `struct app`, which no test
 * can build. What is asserted about them instead is the invariant that makes
 * them safe -- neither one has any way to change the extended style, because
 * NOTHING in this port does, and the sweep below proves the style is what it
 * was after every transition the window itself performs. See
 * portable/docs/windows-native-observations.md.
 *
 * A HEADLESS SESSION HAS NO DESKTOP. Where a window cannot be created at all
 * (no window station, no D3D device), the case reports what was missing and
 * exits 0 with nothing asserted rather than failing -- the runner's BLOCKED
 * convention in miniature. Everything it CAN do, it does.
 */
/* spdf-test-sources: portable/win/src/spdf_win_window.cpp portable/win/src/spdf_win_d2d.cpp portable/win/src/spdf_win_chrome_paint.cpp portable/win/src/spdf_win_chrome_scrollbar.cpp portable/win/src/spdf_win_chrome_find.cpp portable/win/src/spdf_win_chrome_toolbar.cpp portable/win/src/spdf_win_chrome_panels.cpp portable/win/src/spdf_win_chrome_sidebar.cpp portable/win/src/spdf_win_chrome_minimap.cpp portable/win/src/spdf_win_chrome_content.cpp portable/win/src/spdf_win_chrome_thumbs.cpp portable/win/src/spdf_win_render.c portable/win/src/spdf_win_lru.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_win_compat.c portable/core/spdf_recolor.c portable/win/src/spdf_win_open.c */
/* spdf-test-needs: mupdf */
#include "spdf_win_window.h"

#include <stdio.h>
#include <string.h>

/* THE TWO APP-SIDE SYMBOLS THE WINDOW LAYER CALLS, stubbed here rather than
 * linked. spdf_win_window_caption.h pushes the three caption facts into the
 * chrome model and reads them back, and their real definitions
 * (spdf_win_chrome_model.cpp) drag in the tab model and the find session -- the
 * whole app -- for state this test never inspects. Stubbing them is what keeps
 * the case about the WINDOW, which is its subject; the model's own behaviour is
 * chrome_caption_paint_test.c's. */
#ifdef __cplusplus
extern "C"
#endif
void spdf_win_chrome_caption_set_state(int maximized, int hot, int pressed) {
    (void)maximized;
    (void)hot;
    (void)pressed;
}

#ifdef __cplusplus
extern "C"
#endif
void spdf_win_chrome_caption_state(int* maximized, int* hot, int* pressed) {
    if (maximized) *maximized = 0;
    if (hot) *hot = 0;
    if (pressed) *pressed = 0;
}

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* The window needs a scene builder and an input handler. Both are the minimum
 * that is honest: the scene declines (so nothing is drawn but the background)
 * and the input handler records what it was given. */
static unsigned g_key = 0;
static unsigned g_key_char = 0;
static int g_text_key = -1;
static int g_key_events = 0;

static int scene_fn(void* user, spdf_win_scene* scene) {
    (void)user;
    (void)scene;
    return 0;
}

static int input_fn(void* user, spdf_win_input* in) {
    (void)user;
    if (in->kind == SPDF_WIN_INPUT_KEY) {
        g_key = in->key;
        g_key_char = in->key_char;
        g_text_key = in->text_key;
        ++g_key_events;
    }
    return 0;
}

/* Every extended style that would make a visible window uninteractable. */
static void check_ex_style_is_clean(HWND hwnd, const char* when) {
    LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    ++g_checks;
    if (ex & (WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_NOACTIVATE)) {
        ++g_failures;
        fprintf(stderr, "FAIL %s: ex-style 0x%08lX carries%s%s%s\n", when, (unsigned long)ex,
                (ex & WS_EX_TRANSPARENT) ? " WS_EX_TRANSPARENT" : "", (ex & WS_EX_LAYERED) ? " WS_EX_LAYERED" : "",
                (ex & WS_EX_NOACTIVATE) ? " WS_EX_NOACTIVATE" : "");
    }
}

/* Drain whatever the transition posted, so the window is settled before the
 * next assertion. Bounded: a pump that could spin forever is worse than one
 * that misses a message. */
static void settle(void) {
    MSG msg;
    int guard = 0;
    while (guard++ < 200 && PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

int main(void) {
    char err[256] = {0};
    spdf_win_d2d* d2d;
    spdf_win_window* window;
    HWND hwnd;
    POINT centre;
    RECT rc;

    spdf_win_enable_dpi_awareness();

    d2d = spdf_win_d2d_create(err, sizeof(err));
    if (!d2d) {
        printf("window_activation_test: SKIPPED -- no Direct2D device (%s)\n", err[0] ? err : "unknown");
        return 0;
    }
    window = spdf_win_window_create(d2d, L"activation probe", 900, 640, scene_fn, input_fn, NULL, err, sizeof(err));
    if (!window) {
        printf("window_activation_test: SKIPPED -- no window (%s)\n", err[0] ? err : "unknown");
        spdf_win_d2d_destroy(d2d);
        return 0;
    }
    hwnd = (HWND)spdf_win_window_native_handle(window);
    CHECK(hwnd != NULL);
    if (!hwnd) {
        spdf_win_window_destroy(window);
        spdf_win_d2d_destroy(d2d);
        printf("window_activation_test: %d checks, %d failures\n", g_checks, g_failures);
        return 1;
    }

    check_ex_style_is_clean(hwnd, "on create");

    /* WM_MOUSEACTIVATE AND WM_NCACTIVATE, asked of the real window procedure.
     * The port handles neither, so both must come back with DefWindowProc's own
     * answers: a click activates, and a non-client activation is accepted. A
     * window that answered MA_NOACTIVATE would be visible, clickable-looking and
     * never focusable -- exactly the report. */
    CHECK(SendMessageW(hwnd, WM_MOUSEACTIVATE, (WPARAM)hwnd, MAKELPARAM(HTCLIENT, WM_LBUTTONDOWN)) == MA_ACTIVATE);
    CHECK(SendMessageW(hwnd, WM_NCACTIVATE, TRUE, 0) != 0);

    spdf_win_window_show(window);
    settle();
    check_ex_style_is_clean(hwnd, "after show");
    CHECK(IsWindowVisible(hwnd));
    /* WS_DISABLED is the fifth way: a disabled window is drawn and takes no
     * input at all. Nothing in this port calls EnableWindow, and this says so. */
    CHECK(IsWindowEnabled(hwnd));

    /* THE POINT UNDER THE POINTER IS OURS. WindowFromPoint is the question
     * Windows itself asks before routing a click, so this is the end-to-end
     * form of "the canvas takes the mouse" -- and it is the assertion that a
     * WS_EX_TRANSPARENT or an alpha-0 layered window fails.
     *
     * Only meaningful when the window really is on top at that point: another
     * window over the test's is not this port's fault. So it is asserted only
     * when the window has the foreground. */
    if (GetClientRect(hwnd, &rc) && GetForegroundWindow() == hwnd) {
        centre.x = (rc.right - rc.left) / 2;
        centre.y = (rc.bottom - rc.top) * 3 / 4; /* below the two chrome bands: the canvas */
        ClientToScreen(hwnd, &centre);
        CHECK(WindowFromPoint(centre) == hwnd);
    }

    /* THE TRANSITIONS. Full screen swaps WS_OVERLAPPEDWINDOW for WS_POPUP
     * (spdf_win_window_frame.h) and is the one place this port rewrites a window
     * style at all; maximize and restore are the reader's own. None of them may
     * leave an extended style behind. */
    spdf_win_window_set_fullscreen(window, 1);
    settle();
    check_ex_style_is_clean(hwnd, "in full screen");
    CHECK(IsWindowEnabled(hwnd));
    spdf_win_window_set_fullscreen(window, 0);
    settle();
    check_ex_style_is_clean(hwnd, "after leaving full screen");
    CHECK(IsWindowEnabled(hwnd));
    /* And the ordinary style really did come back, which is what makes the
     * caption buttons and the resize border work again. */
    CHECK((GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_POPUP) == 0);

    ShowWindow(hwnd, SW_MAXIMIZE);
    settle();
    check_ex_style_is_clean(hwnd, "maximized");
    ShowWindow(hwnd, SW_RESTORE);
    settle();
    check_ex_style_is_clean(hwnd, "restored");

    /* THE KEYBOARD REACHES THE HANDLER, and carries the layout fields the
     * accelerator matcher now needs. Sent rather than posted so it is delivered
     * to the window procedure with no pump race; text_key is 0 because nothing
     * queued a WM_CHAR behind it, which is exactly the documented answer for a
     * synthetic key (spdf_win_window_input.h key_is_text). */
    g_key_events = 0;
    SendMessageW(hwnd, WM_KEYDOWN, VK_F11, 0);
    CHECK(g_key_events == 1);
    CHECK(g_key == VK_F11);
    CHECK(g_key_char == 0); /* a function key produces no character on any layout */
    CHECK(g_text_key == 0);
    SendMessageW(hwnd, WM_KEYDOWN, 'A', 0);
    CHECK(g_key_events == 2);
    CHECK(g_key == 'A');
    /* 'A' is 'A' on every layout Windows ships, so this is safe to assert
     * whatever the machine running the test is set to. */
    CHECK(g_key_char == 'A');

    /* text_key, THROUGH THE QUEUE, which is the only way to exercise it.
     *
     * key_is_text() answers by looking for the WM_CHAR TranslateMessage has
     * already queued behind the WM_KEYDOWN (spdf_win_window_input.h). So the
     * two are POSTED in that order and pumped: the window procedure must find
     * the character while handling the key. This is the AltGr case in
     * miniature -- on a French layout AltGr+'=' arrives as VK_OEM_PLUS with
     * Ctrl and Alt AND a '}' behind it, and it is the '}' that says the
     * keystroke is text rather than the Larger Text accelerator
     * (spdf_win_menu_layout.h, keyboard_layout_test.c). */
    g_key_events = 0;
    g_text_key = -1;
    PostMessageW(hwnd, WM_KEYDOWN, VK_OEM_PLUS, 0);
    PostMessageW(hwnd, WM_CHAR, (WPARAM)L'}', 0);
    settle();
    CHECK(g_key_events == 1);
    CHECK(g_key == VK_OEM_PLUS);
    CHECK(g_text_key == 1);

    /* And a CONTROL character behind the key is not text: Ctrl+F queues 0x06,
     * and reading that as text would disable every accelerator in the table. */
    g_key_events = 0;
    g_text_key = -1;
    PostMessageW(hwnd, WM_KEYDOWN, 'F', 0);
    PostMessageW(hwnd, WM_CHAR, 0x06, 0);
    settle();
    CHECK(g_key_events == 1);
    CHECK(g_text_key == 0);

    spdf_win_window_destroy(window);
    spdf_win_d2d_destroy(d2d);

    printf("window_activation_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
