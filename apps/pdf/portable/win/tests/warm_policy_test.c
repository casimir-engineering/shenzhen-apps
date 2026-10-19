/* warm_policy_test.c — the warm-up schedule and the tab warm order, asserted
 * against the macOS policy's OWN expectations.
 *
 * This is a DIFFERENTIAL test done the only way it can be done here: the mac
 * side is Objective-C and needs a mac to build, so instead of running both
 * implementations, every case below is a line-for-line transcription of a case
 * in portable/mac/tests/launch/SPDFMacLaunchWorkPolicyTests.mm -- the same
 * delays (0.05 / 0.35 / 0.10), the same timestamps to the millisecond, the same
 * expected stages, the same expected warm orders. The mac test names are given
 * per case so the pair can be diffed by eye, and the numbers are not
 * "reasonable values" chosen here: change one and this stops being evidence.
 *
 * WHAT IT PROVES. That spdf_win_warm_policy.h is a port and not a fresh
 * invention that happens to compile. The three behaviours that matter and that
 * a re-derivation gets wrong: input does NOT delay visible work but DOES delay
 * inactive work; a completed cycle stops responding to input at all; and the
 * warm order is adjacent, then most-recently-used, then outward -- including
 * the mac's subtle one, that a selected tab's own promotion rebuilds the
 * priority rather than leaving the old order in place.
 *
 * Pure: no document, no window, no thread, no clock. Every timestamp is a
 * literal.
 */
/* spdf-test-sources: */

#include <stdio.h>

#include "spdf_win_warm_policy.h"

static int g_failures;
static int g_checks;

#define EXPECT(cond)                                                                                                   \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* SPDFMacLaunchWorkPolicyTests.mm's make_policy(), figure for figure. */
static void make_policy(SpdfWinWarmPolicy* p) { spdf_win_warm_policy_init(p, 0.05, 0.35, 0.10); }

/* mac: test_visible_work_has_input_independent_deadlines */
static void test_visible_work_has_input_independent_deadlines(void) {
    SpdfWinWarmPolicy p;
    unsigned long long generation;
    double now;
    make_policy(&p);
    generation = spdf_win_warm_policy_begin(&p, SPDF_WIN_WARM_METADATA, 10.0);

    for (now = 10.01; now < 10.05; now += 0.01) {
        EXPECT(!spdf_win_warm_policy_note_input(&p, now));
        EXPECT(spdf_win_warm_policy_generation(&p) == generation);
    }
    EXPECT(spdf_win_warm_policy_take(&p, 10.049, generation) == SPDF_WIN_WARM_NONE);
    EXPECT(spdf_win_warm_policy_take(&p, 10.05, generation) == SPDF_WIN_WARM_METADATA);

    for (now = 10.06; now < 10.15; now += 0.01) {
        EXPECT(!spdf_win_warm_policy_note_input(&p, now));
        EXPECT(spdf_win_warm_policy_generation(&p) == generation);
    }
    EXPECT(spdf_win_warm_policy_take(&p, 10.149, generation) == SPDF_WIN_WARM_NONE);
    EXPECT(spdf_win_warm_policy_take(&p, 10.151, generation) == SPDF_WIN_WARM_ACTIVE_DOCUMENT);
}

/* mac: test_only_inactive_work_is_idle_reset */
static void test_only_inactive_work_is_idle_reset(void) {
    SpdfWinWarmPolicy p;
    unsigned long long first, second, third, fourth;
    make_policy(&p);
    first = spdf_win_warm_policy_begin(&p, SPDF_WIN_WARM_METADATA, 1.0);
    EXPECT(spdf_win_warm_policy_take(&p, 1.05, first) == SPDF_WIN_WARM_METADATA);
    EXPECT(spdf_win_warm_policy_take(&p, 1.151, first) == SPDF_WIN_WARM_ACTIVE_DOCUMENT);

    /* The active document has been handed out, so the NEXT stage is inactive
     * work -- and now input does cancel. */
    EXPECT(spdf_win_warm_policy_note_input(&p, 1.20));
    second = spdf_win_warm_policy_generation(&p);
    EXPECT(second != first);
    EXPECT(spdf_win_warm_policy_take(&p, 1.549, second) == SPDF_WIN_WARM_NONE);
    EXPECT(spdf_win_warm_policy_note_input(&p, 1.54));
    third = spdf_win_warm_policy_generation(&p);
    EXPECT(spdf_win_warm_policy_take(&p, 1.889, third) == SPDF_WIN_WARM_NONE);
    EXPECT(spdf_win_warm_policy_take(&p, 1.891, third) == SPDF_WIN_WARM_INACTIVE_TABS);

    /* Running inactive work is cancelled by input too, and re-armed a whole
     * idle delay out. */
    EXPECT(spdf_win_warm_policy_note_input(&p, 2.0));
    fourth = spdf_win_warm_policy_generation(&p);
    EXPECT(spdf_win_warm_policy_take(&p, 2.349, fourth) == SPDF_WIN_WARM_NONE);
    EXPECT(spdf_win_warm_policy_take(&p, 2.351, fourth) == SPDF_WIN_WARM_INACTIVE_TABS);
}

/* mac: test_completion_disables_future_input_cancellation */
static void test_completion_disables_future_input_cancellation(void) {
    SpdfWinWarmPolicy p;
    unsigned long long generation;
    make_policy(&p);
    generation = spdf_win_warm_policy_begin(&p, SPDF_WIN_WARM_INACTIVE_TABS, 0.0);
    EXPECT(spdf_win_warm_policy_take(&p, 0.35, generation) == SPDF_WIN_WARM_INACTIVE_TABS);
    spdf_win_warm_policy_complete(&p, generation);
    EXPECT(!spdf_win_warm_policy_active(&p));
    EXPECT(!spdf_win_warm_policy_note_input(&p, 1.0));
}

/* An expired generation claims nothing. Implicit in the mac coordinator, which
 * captures the generation into the dispatch_after block and hands it back; made
 * explicit here because it is the whole reason take() takes one. */
static void test_stale_generation_claims_nothing(void) {
    SpdfWinWarmPolicy p;
    unsigned long long first;
    make_policy(&p);
    first = spdf_win_warm_policy_begin(&p, SPDF_WIN_WARM_METADATA, 0.0);
    (void)spdf_win_warm_policy_begin(&p, SPDF_WIN_WARM_METADATA, 0.0);
    EXPECT(spdf_win_warm_policy_take(&p, 10.0, first) == SPDF_WIN_WARM_NONE);
    EXPECT(spdf_win_warm_policy_take(&p, 10.0, spdf_win_warm_policy_generation(&p)) == SPDF_WIN_WARM_METADATA);
    /* And there is nothing to arm a timer for once the machine is done. */
    spdf_win_warm_policy_complete(&p, spdf_win_warm_policy_generation(&p));
    EXPECT(spdf_win_warm_policy_delay(&p, 10.0) < 0.0);
}

static void print_order(const char* label, const int* order, int count) {
    int i;
    printf("%-26s [", label);
    for (i = 0; i < count; ++i) printf("%s%d", i ? "," : "", order[i]);
    printf("]\n");
}

/* mac: test_adjacent_then_mru_then_distance_order -- five tabs, selected 2,
 * activation history a then e then c, expecting [3, 1, 4, 0]. */
static void test_adjacent_then_mru_then_distance_order(void) {
    char a, b, c, d, e;
    const void* ids[5];
    SpdfWinWarmPolicy p;
    int order[8];
    int n;
    ids[0] = &a;
    ids[1] = &b;
    ids[2] = &c;
    ids[3] = &d;
    ids[4] = &e;
    make_policy(&p);
    spdf_win_warm_policy_note_activation(&p, &a);
    spdf_win_warm_policy_note_activation(&p, &e);
    spdf_win_warm_policy_note_activation(&p, &c);
    n = spdf_win_warm_policy_order(&p, ids, 5, 2, order, 8);
    print_order("adjacent-mru-distance", order, n);
    EXPECT(n == 4);
    EXPECT(order[0] == 3 && order[1] == 1 && order[2] == 4 && order[3] == 0);
}

/* mac: test_selected_tab_promotion_rebuilds_priority -- four tabs, selected 3,
 * history b then d, expecting [2, 1, 0]. The selected tab is the most recently
 * activated one, which must not appear in its own warm order. */
static void test_selected_tab_promotion_rebuilds_priority(void) {
    char a, b, c, d;
    const void* ids[4];
    SpdfWinWarmPolicy p;
    int order[8];
    int n;
    ids[0] = &a;
    ids[1] = &b;
    ids[2] = &c;
    ids[3] = &d;
    make_policy(&p);
    spdf_win_warm_policy_note_activation(&p, &b);
    spdf_win_warm_policy_note_activation(&p, &d);
    n = spdf_win_warm_policy_order(&p, ids, 4, 3, order, 8);
    print_order("selected-promotion", order, n);
    EXPECT(n == 3);
    EXPECT(order[0] == 2 && order[1] == 1 && order[2] == 0);
}

/* The history is PRUNED to the identities still present, which is the mac's
 * survivingHistory pass and the only place a closed tab leaves the history. */
static void test_order_prunes_closed_tabs(void) {
    char a, b, c, closed;
    const void* ids[3];
    SpdfWinWarmPolicy p;
    int order[8];
    ids[0] = &a;
    ids[1] = &b;
    ids[2] = &c;
    make_policy(&p);
    spdf_win_warm_policy_note_activation(&p, &closed);
    spdf_win_warm_policy_note_activation(&p, &c);
    spdf_win_warm_policy_note_activation(&p, &a);
    EXPECT(p.history_count == 3);
    (void)spdf_win_warm_policy_order(&p, ids, 3, 1, order, 8);
    EXPECT(p.history_count == 2);
    EXPECT(p.history[0] == (const void*)&a && p.history[1] == (const void*)&c);
    /* A one-tab window has nothing to warm, and a selected index off the end
     * asks for nothing rather than reading past the array. */
    EXPECT(spdf_win_warm_policy_order(&p, ids, 1, 0, order, 8) == 0);
    EXPECT(spdf_win_warm_policy_order(&p, ids, 3, 3, order, 8) == 0);
    EXPECT(spdf_win_warm_policy_order(&p, ids, 3, -1, order, 8) == 0);
}

/* Every tab but the selected one is warmed, exactly once, however long the
 * strip is -- the loop the mac writes as `while (result.count + 1 <
 * identifiers.count)`. A capped `out` truncates rather than overflowing. */
static void test_order_covers_every_tab_once(void) {
    char slots[15];
    const void* ids[15];
    SpdfWinWarmPolicy p;
    int order[15];
    int seen[15];
    int n;
    int i;
    for (i = 0; i < 15; ++i) {
        ids[i] = &slots[i];
        seen[i] = 0;
    }
    make_policy(&p);
    n = spdf_win_warm_policy_order(&p, ids, 15, 11, order, 15);
    EXPECT(n == 14);
    for (i = 0; i < n; ++i) {
        EXPECT(order[i] >= 0 && order[i] < 15 && order[i] != 11);
        if (order[i] >= 0 && order[i] < 15) EXPECT(seen[order[i]]++ == 0);
    }
    print_order("fifteen-tabs-from-11", order, n);
    EXPECT(spdf_win_warm_policy_order(&p, ids, 15, 11, order, 3) == 3);
}

/* mac: test_inactive_work_budget */
static void test_inactive_work_budget(void) {
    unsigned counts[6];
    int index;
    int i;
    EXPECT(spdf_win_warm_inactive_worker_limit() == 1);
    EXPECT(spdf_win_warm_can_start(0, 0, 0, 0, 0, 0));
    for (index = 0; index < 6; ++index) {
        for (i = 0; i < 6; ++i) counts[i] = 0;
        counts[index] = 1;
        EXPECT(!spdf_win_warm_can_start(counts[0], counts[1], counts[2], counts[3], counts[4], counts[5]));
    }
}

/* mac: test_inactive_preload_foreground_claims_inflight_open */
static void test_preload_foreground_claims_inflight_open(void) {
    SpdfWinWarmPreload pre;
    char document;
    spdf_win_warm_preload_init(&pre);
    EXPECT(spdf_win_warm_preload_may_open(&pre));
    EXPECT(spdf_win_warm_preload_claim(&pre));
    /* The worker publishes the handle and is then told to stop: the foreground
     * wants THIS document, not a second open of the same file. */
    EXPECT(!spdf_win_warm_preload_may_continue(&pre, &document));
    spdf_win_warm_preload_finish(&pre);
    EXPECT(spdf_win_warm_preload_settled(&pre));
    EXPECT(spdf_win_warm_preload_take_foreground(&pre) == (void*)&document);
    EXPECT(spdf_win_warm_preload_take_foreground(&pre) == 0);
}

/* mac: test_inactive_preload_finished_result_has_one_consumer */
static void test_preload_finished_result_has_one_consumer(void) {
    SpdfWinWarmPreload pre;
    char document;
    spdf_win_warm_preload_init(&pre);
    EXPECT(spdf_win_warm_preload_may_open(&pre));
    EXPECT(spdf_win_warm_preload_may_continue(&pre, &document));
    spdf_win_warm_preload_finish(&pre);
    EXPECT(spdf_win_warm_preload_claim(&pre));
    /* Claimed, so the background adoption is refused and the handle has exactly
     * one consumer. */
    EXPECT(spdf_win_warm_preload_take_background(&pre) == 0);
    EXPECT(spdf_win_warm_preload_take_foreground(&pre) == (void*)&document);
    EXPECT(!spdf_win_warm_preload_claim(&pre));
}

/* mac: test_prerender_cancels_before_worker_open, in its preload form -- a
 * claim before the worker starts cancels the warm-up outright, and settles it
 * so the foreground does not wait for a worker that will refuse to run. */
static void test_preload_claim_before_open_cancels(void) {
    SpdfWinWarmPreload pre;
    spdf_win_warm_preload_init(&pre);
    EXPECT(spdf_win_warm_preload_claim(&pre));
    EXPECT(spdf_win_warm_preload_settled(&pre));
    EXPECT(!spdf_win_warm_preload_may_open(&pre));
    EXPECT(spdf_win_warm_preload_take_foreground(&pre) == 0);
}

/* Nobody claimed it: the warm store adopts the handle, and once adopted there
 * is nothing left for a late claim to take. */
static void test_preload_background_adoption(void) {
    SpdfWinWarmPreload pre;
    char document;
    spdf_win_warm_preload_init(&pre);
    EXPECT(spdf_win_warm_preload_may_open(&pre));
    EXPECT(spdf_win_warm_preload_may_continue(&pre, &document));
    EXPECT(spdf_win_warm_preload_take_background(&pre) == 0); /* not finished yet */
    spdf_win_warm_preload_finish(&pre);
    EXPECT(spdf_win_warm_preload_take_background(&pre) == (void*)&document);
    EXPECT(!spdf_win_warm_preload_claim(&pre));
    EXPECT(spdf_win_warm_preload_take_background(&pre) == 0);
}

int main(void) {
    printf("== spdf_win_warm_policy transcript ==\n");
    test_visible_work_has_input_independent_deadlines();
    test_only_inactive_work_is_idle_reset();
    test_completion_disables_future_input_cancellation();
    test_stale_generation_claims_nothing();
    test_adjacent_then_mru_then_distance_order();
    test_selected_tab_promotion_rebuilds_priority();
    test_order_prunes_closed_tabs();
    test_order_covers_every_tab_once();
    test_inactive_work_budget();
    test_preload_foreground_claims_inflight_open();
    test_preload_finished_result_has_one_consumer();
    test_preload_claim_before_open_cancels();
    test_preload_background_adoption();
    printf("warm_policy_test: %s (%d failure%s of %d checks)\n", g_failures ? "FAIL" : "PASS", g_failures,
           g_failures == 1 ? "" : "s", g_checks);
    return g_failures ? 1 : 0;
}
