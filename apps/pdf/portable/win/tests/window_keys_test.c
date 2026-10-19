/* window_keys_test.c — pins the ONE key policy portable/win/src/spdf_win_window.cpp
 * holds of its own: what happens to an Escape the input handler declined.
 *
 * The window proc itself cannot be driven without a desktop, so the decision
 * is a pure predicate in spdf_win_window.h and the proc calls it. What this
 * pins is the defect portable/docs/windows-feature-matrix.md listed as gap 2:
 * "Escape with nothing focused closes the window (spdf_win_window.cpp:354) --
 * macOS never does". An Escape nothing wanted now leaves full screen when the
 * window is in it, and otherwise does nothing; there is no outcome that closes
 * the window, and this file is what makes putting one back a red test rather
 * than a quiet regression.
 *
 * Header-only under test -- the predicate is inline -- so no
 * `spdf-test-sources` line is needed. The header pulls in spdf_win_d2d.h and so
 * d2d1.h, which MSVC has; nothing is linked.
 */
#include "spdf_win_window.h"

#include <stdio.h>

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

int main(void) {
    /* The ordinary window: an unhandled Escape does NOTHING. Not close, not
     * quit -- nothing. (macOS: documentEscapeKeyDown clears the search or the
     * selection and stops there.) */
    CHECK(spdf_win_window_escape_leaves_fullscreen(0) == 0);
    /* Full screen (F11) or presentation (F5): the same Escape leaves it, which
     * the window expresses as SPDF_WIN_CMD_FULLSCREEN back through the command
     * route -- the caller decides whether that means leaving presentation. */
    CHECK(spdf_win_window_escape_leaves_fullscreen(1) == 1);
    CHECK(spdf_win_window_escape_leaves_fullscreen(7) == 1);

    /* The right button is its own event kind and does not alias any other. */
    CHECK(SPDF_WIN_INPUT_CONTEXT != SPDF_WIN_INPUT_MOUSE_DOWN);
    CHECK(SPDF_WIN_INPUT_CONTEXT != SPDF_WIN_INPUT_COMMAND);
    CHECK(SPDF_WIN_INPUT_CONTEXT != SPDF_WIN_INPUT_DROP_FILE);

    printf("window_keys_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
