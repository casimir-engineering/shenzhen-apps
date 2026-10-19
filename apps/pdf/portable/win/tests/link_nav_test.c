/* link_nav_test.c — the two PURE models behind following a link: where an
 * internal jump lands (spdf_win_links.h section 3) and the counter that lets a
 * second click cancel a link about to leave the document (section 4).
 *
 * NO DOCUMENT AND NO MUPDF, on purpose. Both models are arithmetic over numbers
 * a caller already has, so this runs on any host and stays exhaustive; the
 * real-document half is portable/win/tests/link_destination_test.c, which drives
 * the same two functions through a real canvas at a real zoom.
 *
 * BOTH ARE TRANSCRIPTIONS, so the expectations below are the MAC TESTS' OWN
 * cases rather than newly invented ones:
 *
 *   spdf_win_link_destination_scroll_y   <- spdf_mac_link_destination_scroll_origin_y
 *     pinned on that side by SPDFMacSelectionClickTests.mm's
 *     test_link_destination_scroll_is_target_page_top -- page-only destination,
 *     offset honoured, offset scaled by zoom, never reaching page N-1, a
 *     negative offset, and the first page clamping at the document top. Every
 *     one of those six is repeated here with this port's lead-in constant.
 *
 *   spdf_win_link_activation_*           <- SPDFMacDelayedLinkActivation.mm
 *     that class is 35 lines of Objective-C and cannot be compiled here, so
 *     portable/docs/windows-port-plan.md §2.3's fallback applies: transcribe and
 *     unit-test. The scenarios are the mac view test's --
 *     test_single_link_is_delayed (a scheduled activation fires),
 *     test_double_click_cancels_link_and_selects_word (a cancelled one does
 *     not), and "only the second run's jump is undone" (a superseded one does
 *     not) -- plus the cases a C API has and an Objective-C block does not: a
 *     token of 0, a second fire, a URI that will not fit, and the counter
 *     wrapping.
 */
#include "spdf_win_links.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        long long va = (long long)(a);                                                                                 \
        long long vb = (long long)(b);                                                                                 \
        ++g_checks;                                                                                                    \
        if (va != vb) {                                                                                                \
            printf("FAIL %s:%d: %s (%lld) != %s (%lld)\n", __FILE__, __LINE__, #a, va, #b, vb);                        \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQD(a, b)                                                                                                \
    do {                                                                                                               \
        double va = (double)(a);                                                                                       \
        double vb = (double)(b);                                                                                       \
        ++g_checks;                                                                                                    \
        if (!(fabs(va - vb) < 1e-9)) {                                                                                 \
            printf("FAIL %s:%d: %s (%.9f) != %s (%.9f)\n", __FILE__, __LINE__, #a, va, #b, vb);                        \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- section 3: where the jump lands -------------------------------------- */

/* Two adjacent slots from a real continuous layout: 612x792 pages at zoom 1,
 * so page 0 sits at y = SPDF_WIN_PAGE_MARGIN_V and page 1 one gutter below it
 * (spdf_win_layout_compute: y += h + 2 * margin_v). The mac test uses two
 * hand-written NSRects for the same reason -- the arithmetic must depend on the
 * TARGET slot only. */
#define SLOT_PREV (SPDF_WIN_PAGE_MARGIN_V)
#define SLOT_PREV_BOTTOM (SLOT_PREV + 792.0)
#define SLOT_TARGET (SLOT_PREV + 792.0 + 2.0 * SPDF_WIN_PAGE_MARGIN_V)

static void test_destination_scroll_y(void) {
    /* "page-only destination aligns the page top": EXACTLY what
     * spdf_win_canvas_scroll_to_page() computes, which is the invariant mac's
     * own comment states and the reason this port subtracts its own gutter
     * rather than mac's 12 pt lead-in. */
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, 0.0, 1.0), SLOT_TARGET - SPDF_WIN_PAGE_MARGIN_V);
    /* "destination offset is honored at zoom 1" */
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, 50.0, 1.0), SLOT_TARGET + 50.0 - SPDF_WIN_PAGE_MARGIN_V);
    /* "destination offset scales with zoom" -- points times zoom, not points. */
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, 50.0, 2.0), SLOT_TARGET + 100.0 - SPDF_WIN_PAGE_MARGIN_V);
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, 232.0, 1.5),
              SLOT_TARGET + 348.0 - SPDF_WIN_PAGE_MARGIN_V);
    /* "result never reaches the preceding page": the whole reason this is
     * top-aligned instead of centred. */
    CHECK(spdf_win_link_destination_scroll_y(SLOT_TARGET, 0.0, 1.0) > SLOT_PREV_BOTTOM);
    /* "a negative destination cannot pull the previous page in" */
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, -400.0, 1.0), SLOT_TARGET - SPDF_WIN_PAGE_MARGIN_V);
    /* "first page clamps at the document top" -- page 0's slot y IS the gutter,
     * so a page-only destination there is offset 0, not a negative scroll. */
    CHECK_EQD(spdf_win_link_destination_scroll_y(SPDF_WIN_PAGE_MARGIN_V, 0.0, 1.0), 0.0);
    CHECK_EQD(spdf_win_link_destination_scroll_y(0.0, 0.0, 1.0), 0.0);
    CHECK_EQD(spdf_win_link_destination_scroll_y(0.0, 4.0, 1.0), 0.0); /* still inside the gutter */
    CHECK_EQD(spdf_win_link_destination_scroll_y(0.0, 20.0, 1.0), 7.0);

    /* A zoom of 0 or less is treated as 1 (mac: `zoom > 0.0 ? zoom : 1.0`),
     * which is what a canvas with no measured page would hand over. */
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, 50.0, 0.0), SLOT_TARGET + 50.0 - SPDF_WIN_PAGE_MARGIN_V);
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, 50.0, -3.0), SLOT_TARGET + 50.0 - SPDF_WIN_PAGE_MARGIN_V);
    /* A destination exactly at the page's top edge is a page-only destination:
     * `> 0.0`, so zero adds nothing and no rounding creeps in. */
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, 0.0, 3.7), SLOT_TARGET - SPDF_WIN_PAGE_MARGIN_V);
}

static spdf_link_target internal_target(int page, float x, float y) {
    spdf_link_target t;
    memset(&t, 0, sizeof(t));
    t.kind = SPDF_LINK_INTERNAL;
    t.page_index = page;
    t.x = x;
    t.y = y;
    return t;
}

static void test_destination_page_y(void) {
    spdf_link_target t = internal_target(3, 72.0f, 232.0f);
    /* PAGE SPACE, y DOWN, taken as it comes: link_test.c measures that
     * fz_resolve_link already flipped it, so nothing here flips it again. */
    CHECK_EQD(spdf_win_link_destination_page_y(&t), 232.0);

    /* A destination that names only a page, reported as the origin. */
    t.x = 0.0f;
    t.y = 0.0f;
    CHECK_EQD(spdf_win_link_destination_page_y(&t), 0.0);

    /* BOTH AXES MUST BE FINITE, which is mac's `isfinite(target.x) &&
     * isfinite(target.y)`: fz_resolve_link fills them together, so a
     * half-finite point is a point it could not resolve. This is the real
     * /Fit case, not a hypothetical one -- link_destination_test.c measures a
     * /Fit destination arriving as (nan, nan). */
    t = internal_target(3, 72.0f, (float)NAN);
    CHECK_EQD(spdf_win_link_destination_page_y(&t), 0.0);
    t = internal_target(3, (float)NAN, 232.0f);
    CHECK_EQD(spdf_win_link_destination_page_y(&t), 0.0);
    t = internal_target(3, (float)INFINITY, 232.0f);
    CHECK_EQD(spdf_win_link_destination_page_y(&t), 0.0);
    t = internal_target(3, 72.0f, (float)-INFINITY);
    CHECK_EQD(spdf_win_link_destination_page_y(&t), 0.0);

    /* Only an INTERNAL target names a place in this document. */
    t = internal_target(3, 72.0f, 232.0f);
    t.kind = SPDF_LINK_URI;
    CHECK_EQD(spdf_win_link_destination_page_y(&t), 0.0);
    t.kind = SPDF_LINK_NONE;
    CHECK_EQD(spdf_win_link_destination_page_y(&t), 0.0);
    CHECK_EQD(spdf_win_link_destination_page_y(NULL), 0.0);

    /* A negative y survives the extraction and is dropped by the scroll, which
     * is where mac drops it too -- one guard, not two. */
    t = internal_target(3, 72.0f, -5.0f);
    CHECK_EQD(spdf_win_link_destination_page_y(&t), -5.0);
    CHECK_EQD(spdf_win_link_destination_scroll_y(SLOT_TARGET, spdf_win_link_destination_page_y(&t), 1.0),
              SLOT_TARGET - SPDF_WIN_PAGE_MARGIN_V);
}

/* --- section 4: the wait a second click cancels --------------------------- */

static const char* URI_A = "https://example.invalid/a";
static const char* URI_B = "mailto:someone@example.invalid";

/* mac test_single_link_is_delayed: the activation is not performed on release,
 * and IS performed when the wait expires. */
static void test_scheduled_activation_fires(void) {
    spdf_win_link_activation a;
    const char* uri = NULL;
    unsigned token;

    spdf_win_link_activation_init(&a);
    CHECK_EQI(spdf_win_link_activation_pending(&a), 0);
    token = spdf_win_link_activation_schedule(&a, URI_A);
    CHECK(token != 0u);
    CHECK_EQI(spdf_win_link_activation_pending(&a), 1);
    CHECK_EQI(spdf_win_link_activation_fire(&a, token, &uri), 1);
    CHECK(uri != NULL && strcmp(uri, URI_A) == 0);
    CHECK_EQI(spdf_win_link_activation_pending(&a), 0);

    /* ONE SCHEDULE, ONE ACTIVATION. mac bumps the counter before running the
     * handler for exactly this; here it stops a duplicate WM_TIMER. */
    uri = (const char*)1;
    CHECK_EQI(spdf_win_link_activation_fire(&a, token, &uri), 0);
    CHECK(uri == NULL);
}

/* mac test_double_click_cancels_link_and_selects_word: the second press moves
 * the counter, so the queued activation drops itself. */
static void test_cancel_beats_a_pending_activation(void) {
    spdf_win_link_activation a;
    const char* uri = (const char*)1;
    unsigned token;

    spdf_win_link_activation_init(&a);
    token = spdf_win_link_activation_schedule(&a, URI_A);
    CHECK(token != 0u);
    spdf_win_link_activation_cancel(&a);
    CHECK_EQI(spdf_win_link_activation_pending(&a), 0);
    CHECK_EQI(spdf_win_link_activation_fire(&a, token, &uri), 0);
    CHECK(uri == NULL);

    /* Cancelling nothing, and cancelling twice, are both no-ops -- the shell
     * cancels on EVERY press, which is almost always a press with nothing
     * pending. */
    spdf_win_link_activation_cancel(&a);
    spdf_win_link_activation_cancel(&a);
    CHECK_EQI(spdf_win_link_activation_pending(&a), 0);
    spdf_win_link_activation_cancel(NULL);
    CHECK_EQI(spdf_win_link_activation_pending(NULL), 0);
    CHECK_EQI(spdf_win_link_activation_schedule(NULL, URI_A), 0u);
    CHECK_EQI(spdf_win_link_activation_fire(NULL, 1u, &uri), 0);
    spdf_win_link_activation_init(NULL);
}

/* mac "only the second run's jump is undone": a second schedule supersedes the
 * first, and only the newest token is live. */
static void test_schedule_supersedes(void) {
    spdf_win_link_activation a;
    const char* uri = NULL;
    unsigned first, second;

    spdf_win_link_activation_init(&a);
    first = spdf_win_link_activation_schedule(&a, URI_A);
    second = spdf_win_link_activation_schedule(&a, URI_B);
    CHECK(first != 0u && second != 0u && first != second);
    CHECK_EQI(spdf_win_link_activation_fire(&a, first, &uri), 0);
    CHECK(uri == NULL);
    CHECK_EQI(spdf_win_link_activation_pending(&a), 1);
    CHECK_EQI(spdf_win_link_activation_fire(&a, second, &uri), 1);
    CHECK(uri != NULL && strcmp(uri, URI_B) == 0);
}

static void test_refused_and_boundary_uris(void) {
    static char too_long[SPDF_WIN_LINK_ACTIVATION_URI_MAX + 8];
    static char exactly_fits[SPDF_WIN_LINK_ACTIVATION_URI_MAX];
    spdf_win_link_activation a;
    const char* uri = NULL;
    unsigned token, live;

    memset(too_long, 'x', sizeof(too_long) - 1);
    too_long[sizeof(too_long) - 1] = '\0';
    memset(exactly_fits, 'y', sizeof(exactly_fits) - 1);
    exactly_fits[sizeof(exactly_fits) - 1] = '\0';

    /* THE LONGEST URI THAT FITS ROUND-TRIPS WHOLE. */
    spdf_win_link_activation_init(&a);
    token = spdf_win_link_activation_schedule(&a, exactly_fits);
    CHECK(token != 0u);
    CHECK_EQI(spdf_win_link_activation_fire(&a, token, &uri), 1);
    CHECK(uri != NULL && strcmp(uri, exactly_fits) == 0);
    CHECK_EQI(strlen(uri), SPDF_WIN_LINK_ACTIVATION_URI_MAX - 1);

    /* ONE BYTE LONGER IS REFUSED, NOT TRUNCATED: opening a prefix of a link is
     * opening a different link. */
    spdf_win_link_activation_init(&a);
    CHECK_EQI(spdf_win_link_activation_schedule(&a, too_long), 0u);
    CHECK_EQI(spdf_win_link_activation_pending(&a), 0);
    CHECK_EQI(spdf_win_link_activation_schedule(&a, NULL), 0u);
    CHECK_EQI(spdf_win_link_activation_schedule(&a, ""), 0u);

    /* AND A REFUSED SCHEDULE STILL SUPERSEDES THE PENDING ONE: the reader
     * clicked something else, so the old link must not fire. */
    spdf_win_link_activation_init(&a);
    live = spdf_win_link_activation_schedule(&a, URI_A);
    CHECK(live != 0u);
    CHECK_EQI(spdf_win_link_activation_schedule(&a, too_long), 0u);
    CHECK_EQI(spdf_win_link_activation_pending(&a), 0);
    uri = (const char*)1;
    CHECK_EQI(spdf_win_link_activation_fire(&a, live, &uri), 0);
    CHECK(uri == NULL);
}

static void test_token_zero_and_wrap(void) {
    spdf_win_link_activation a;
    const char* uri = (const char*)1;
    unsigned token;

    /* A ZERO TOKEN IS NEVER LIVE, which is what lets the shell keep 0 as "no
     * pending activation" in a plain unsigned. It is not live even on a
     * freshly zeroed struct, whose generation IS 0. */
    spdf_win_link_activation_init(&a);
    CHECK_EQI(spdf_win_link_activation_fire(&a, 0u, &uri), 0);
    CHECK(uri == NULL);

    /* THE COUNTER SKIPS 0 ON THE WAY ROUND, so a process that has followed
     * 2^32 links does not suddenly hand out a dead token. */
    spdf_win_link_activation_init(&a);
    a.generation = UINT_MAX;
    token = spdf_win_link_activation_schedule(&a, URI_A);
    CHECK(token != 0u);
    CHECK_EQI(spdf_win_link_activation_fire(&a, token, &uri), 1);
    CHECK(uri != NULL && strcmp(uri, URI_A) == 0);

    spdf_win_link_activation_init(&a);
    a.generation = UINT_MAX;
    spdf_win_link_activation_cancel(&a);
    CHECK(a.generation != 0u);
}

static void test_delay(void) {
    /* mac's default is NSEvent.doubleClickInterval and its initialiser clamps
     * with MAX(0.0, delay); the caller here passes GetDoubleClickTime(), whose
     * Windows default is 500 ms. */
    CHECK_EQI(spdf_win_link_activation_delay_ms(500), 500u);
    CHECK_EQI(spdf_win_link_activation_delay_ms(1), 1u);
    CHECK_EQI(spdf_win_link_activation_delay_ms(0), 0u);
    CHECK_EQI(spdf_win_link_activation_delay_ms(-1), 0u);
    CHECK_EQI(spdf_win_link_activation_delay_ms(-500), 0u);
}

int main(void) {
    test_destination_scroll_y();
    test_destination_page_y();
    test_scheduled_activation_fires();
    test_cancel_beats_a_pending_activation();
    test_schedule_supersedes();
    test_refused_and_boundary_uris();
    test_token_zero_and_wrap();
    test_delay();

    printf("link_nav_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
