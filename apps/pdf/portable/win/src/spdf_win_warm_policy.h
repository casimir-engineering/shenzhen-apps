/* spdf_win_warm_policy.h — WHEN to warm things up, and in WHAT ORDER.
 *
 * The Windows port of the pure half of portable/mac/SPDFMacLaunchWorkPolicy.mm
 * (SPDFMacLaunchWorkPolicy, spdf_mac_launch_inactive_worker_limit,
 * spdf_mac_launch_can_start_inactive_work) and of
 * portable/mac/SPDFMacInactivePreload.mm's ownership handshake. It is a PORT,
 * not a re-derivation: every rule below is the mac rule, and
 * portable/win/tests/warm_policy_test.c asserts the same expectations
 * portable/mac/tests/launch/SPDFMacLaunchWorkPolicyTests.mm asserts, case for
 * case, so the two frontends cannot drift on the one thing readers feel --
 * whether a tab switch is instant and whether warming up steals the machine
 * while they are trying to read.
 *
 * WHY IT IS A HEADER OF PURE FUNCTIONS, like spdf_win_layout.h next to it: no
 * timers, no threads, no queues, no Windows headers, no clock. Time arrives as
 * a double of seconds from any monotonic origin, so a test can drive a whole
 * launch in microseconds and assert on deadlines exactly. The adapter that owns
 * a real timer and a real thread is the caller's; the mac keeps its own in
 * SPDFMacLaunchWorkCoordinator, which is AppKit and is deliberately not ported.
 *
 * WHAT IT IS FOR, on Windows specifically. spdf_win_tabs_app.h keeps ONE canvas
 * per process: switching tabs destroys it and builds a new one over the new
 * tab's document, which is what keeps a restored fifteen-tab session honest
 * about memory. The cost is that an inactive tab is stone cold -- its document
 * is not even open until the first time it is shown -- so a switch pays an open
 * plus a full page render on the UI thread. macOS pays neither, because it warms
 * inactive tabs in the background once the visible page is settled. This is the
 * policy that says when that may start, which tab to warm first, and how the
 * foreground takes over a warm-up that is still in flight when the reader
 * clicks the tab. See the section 3 note for what still has to be wired.
 *
 * THREE RULES WORTH READING BEFORE CHANGING ANY OF IT:
 *
 *   1. VISIBLE WORK HAS INPUT-INDEPENDENT DEADLINES. Metadata and the active
 *      document run on their own schedule and user input does NOT push them
 *      back; only inactive-tab work is deferred by a touch of the mouse. A
 *      reader scrolling the page they are on must not thereby delay the work
 *      that makes that page good.
 *   2. INACTIVE WORK IS IDLE WORK. Any input while it is queued or running
 *      cancels it and re-arms it a full idle delay later, and bumps the
 *      generation so the results of the cancelled cycle cannot be adopted.
 *   3. THERE IS ONE WARM WORKER, AND IT WAITS ITS TURN. The limit is one, and
 *      it may not start while ANY foreground operation is outstanding.
 */
#ifndef SPDF_WIN_WARM_POLICY_H
#define SPDF_WIN_WARM_POLICY_H

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 1. The staged warm-up
 *
 * Ported from SPDFMacLaunchWarmStage. The order is metadata (cheap, and the
 * chrome wants it), then the active document (its neighbours, its outline), then
 * everything that belongs to a tab nobody is looking at. */
typedef enum SpdfWinWarmStage {
    SPDF_WIN_WARM_NONE = 0,
    SPDF_WIN_WARM_METADATA = 1,
    SPDF_WIN_WARM_ACTIVE_DOCUMENT = 2,
    SPDF_WIN_WARM_INACTIVE_TABS = 3
} SpdfWinWarmStage;

/* How many tab identities the activation history remembers. THE ONE DEVIATION
 * from the mac policy, whose history is an unbounded NSMutableArray: a fixed
 * array keeps this header allocation-free, and a reader with more than 64 tabs
 * open falls back to distance order for the coldest of them, which is the order
 * they would have had anyway. */
#define SPDF_WIN_WARM_HISTORY_MAX 64

typedef struct SpdfWinWarmPolicy {
    /* Deadlines, in seconds. The mac's own figures are 0.05 / 0.35 / 0.10
     * (SPDFMacLaunchWorkPolicyTests.mm's make_policy); spdf_win_warm_policy_init
     * takes them from the caller rather than hard-coding them so a test can
     * drive them and a shell can tune them in one place. */
    double visible_start_delay;
    double inactive_idle_delay;
    double stage_delay;

    int active;
    unsigned long long generation;
    SpdfWinWarmStage next_stage;
    double ready_at;
    int inactive_work_running;

    const void* history[SPDF_WIN_WARM_HISTORY_MAX];
    int history_count;
} SpdfWinWarmPolicy;

static void spdf_win_warm_policy_init(SpdfWinWarmPolicy* p, double visible_start_delay, double inactive_idle_delay,
                                      double stage_delay) {
    int i;
    if (!p) return;
    p->visible_start_delay = visible_start_delay > 0.0 ? visible_start_delay : 0.0;
    p->inactive_idle_delay = inactive_idle_delay > 0.0 ? inactive_idle_delay : 0.0;
    p->stage_delay = stage_delay > 0.0 ? stage_delay : 0.0;
    p->active = 0;
    p->generation = 0;
    p->next_stage = SPDF_WIN_WARM_NONE;
    p->ready_at = 0.0;
    p->inactive_work_running = 0;
    p->history_count = 0;
    for (i = 0; i < SPDF_WIN_WARM_HISTORY_MAX; ++i) p->history[i] = 0;
}

/* Start a warm-up cycle at `stage`. Returns the generation the caller must hand
 * back to take_ready_stage and complete_cycle, so that a cycle cancelled while
 * its timer was armed cannot be resumed by the timer that outlived it. */
static unsigned long long spdf_win_warm_policy_begin(SpdfWinWarmPolicy* p, SpdfWinWarmStage stage, double now) {
    if (!p) return 0;
    p->generation++;
    p->active = stage != SPDF_WIN_WARM_NONE ? 1 : 0;
    p->next_stage = stage;
    p->inactive_work_running = 0;
    p->ready_at = now + (stage == SPDF_WIN_WARM_INACTIVE_TABS ? p->inactive_idle_delay : p->visible_start_delay);
    return p->generation;
}

/* THE READER TOUCHED SOMETHING. Returns non-zero when that cancelled a cycle,
 * in which case the caller must abandon whatever it had running and re-arm from
 * delay_until_ready(). Rule 1 lives here: a stage that is not inactive work is
 * left entirely alone. */
static int spdf_win_warm_policy_note_input(SpdfWinWarmPolicy* p, double now) {
    if (!p || !p->active) return 0;
    if (p->next_stage != SPDF_WIN_WARM_INACTIVE_TABS && !p->inactive_work_running) return 0;
    p->generation++;
    p->next_stage = SPDF_WIN_WARM_INACTIVE_TABS;
    p->inactive_work_running = 0;
    p->ready_at = now + p->inactive_idle_delay;
    return 1;
}

/* Seconds until the next stage may run, 0 when it may run now, and NEGATIVE
 * when there is nothing to arm a timer for. */
static double spdf_win_warm_policy_delay(const SpdfWinWarmPolicy* p, double now) {
    double delay;
    if (!p || !p->active || p->next_stage == SPDF_WIN_WARM_NONE) return -1.0;
    delay = p->ready_at - now;
    return delay > 0.0 ? delay : 0.0;
}

/* Claim the stage that is due, advancing the machine. SPDF_WIN_WARM_NONE means
 * "not yet, or not yours" -- an expired generation, an inactive policy, or a
 * deadline that has not arrived. */
static SpdfWinWarmStage spdf_win_warm_policy_take(SpdfWinWarmPolicy* p, double now, unsigned long long generation) {
    SpdfWinWarmStage result;
    if (!p || !p->active || generation != p->generation || p->next_stage == SPDF_WIN_WARM_NONE || now < p->ready_at)
        return SPDF_WIN_WARM_NONE;
    result = p->next_stage;
    if (result == SPDF_WIN_WARM_INACTIVE_TABS) {
        /* The last stage. It stays "running" so that input still cancels it
         * (rule 2) even though there is nothing left to arm. */
        p->next_stage = SPDF_WIN_WARM_NONE;
        p->inactive_work_running = 1;
    } else if (result == SPDF_WIN_WARM_ACTIVE_DOCUMENT) {
        p->next_stage = SPDF_WIN_WARM_INACTIVE_TABS;
        p->ready_at = now + p->inactive_idle_delay;
    } else {
        p->next_stage = SPDF_WIN_WARM_ACTIVE_DOCUMENT;
        p->ready_at = now + p->stage_delay;
    }
    return result;
}

/* The cycle finished. Bumping the generation is what makes a later input a
 * no-op rather than the start of another idle wait for work that is done. */
static void spdf_win_warm_policy_complete(SpdfWinWarmPolicy* p, unsigned long long generation) {
    if (!p || generation != p->generation) return;
    p->generation++;
    p->active = 0;
    p->next_stage = SPDF_WIN_WARM_NONE;
    p->inactive_work_running = 0;
}

static int spdf_win_warm_policy_active(const SpdfWinWarmPolicy* p) { return p && p->active ? 1 : 0; }
static unsigned long long spdf_win_warm_policy_generation(const SpdfWinWarmPolicy* p) { return p ? p->generation : 0; }

/* ---------------------------------------------------------------------------
 * 2. Which inactive tab to warm first
 *
 * Move-to-front, so the history is a most-recently-used list of tab identities.
 * `id` is whatever pointer the caller uses as a stable tab identity -- the mac
 * compares object identity with indexOfObjectIdenticalTo:, so this compares
 * pointers, and a caller must not pass a pointer it reuses for another tab. */
static void spdf_win_warm_policy_note_activation(SpdfWinWarmPolicy* p, const void* id) {
    int i;
    int found = -1;
    if (!p || !id) return;
    for (i = 0; i < p->history_count; ++i)
        if (p->history[i] == id) {
            found = i;
            break;
        }
    if (found < 0 && p->history_count < SPDF_WIN_WARM_HISTORY_MAX) found = p->history_count++;
    if (found < 0) found = SPDF_WIN_WARM_HISTORY_MAX - 1; /* full: the coldest entry is displaced */
    for (i = found; i > 0; --i) p->history[i] = p->history[i - 1];
    p->history[0] = id;
}

/* THE WARM ORDER, and each tier is there for a measured reason on macOS:
 *
 *   the tab NEXT to the selected one, then the one BEFORE it -- Ctrl+Tab and a
 *   click on a neighbour are the two commonest switches;
 *   then most-recently-activated first, because the tab you came from is the
 *   tab you are most likely to go back to;
 *   then outward by distance, so a fifteen-tab session finishes warming in an
 *   order that is at least predictable.
 *
 * Writes at most `count - 1` indexes into `out` (every tab but the selected
 * one) and returns how many. `selected` out of range yields 0. It also PRUNES
 * the activation history to the identities still present, which is the one
 * place a closed tab leaves the history -- exactly as the mac does, and the
 * reason this takes the whole identity array rather than just a count. */
static int spdf_win_warm_policy_order(SpdfWinWarmPolicy* p, const void* const* ids, int count, int selected,
                                      int* out, int max_out) {
    int used = 0;
    int distance;
    int i;
    int j;
    int surviving = 0;

    if (!p || !ids || !out || max_out <= 0 || count <= 0 || selected < 0 || selected >= count) return 0;

/* Append `index` unless it is out of range, already queued, or the selected
 * tab. The mac uses an NSMutableIndexSet; a linear scan of at most `count`
 * ints is the same answer without the allocation. */
#define SPDF_WARM_APPEND(index)                                                                                        \
    do {                                                                                                               \
        int idx_ = (index);                                                                                            \
        int seen_ = idx_ == selected;                                                                                  \
        int k_;                                                                                                        \
        if (idx_ >= 0 && idx_ < count && !seen_) {                                                                     \
            for (k_ = 0; k_ < used; ++k_)                                                                              \
                if (out[k_] == idx_) {                                                                                 \
                    seen_ = 1;                                                                                         \
                    break;                                                                                             \
                }                                                                                                      \
            if (!seen_ && used < max_out) out[used++] = idx_;                                                          \
        }                                                                                                              \
    } while (0)

    SPDF_WARM_APPEND(selected + 1);
    SPDF_WARM_APPEND(selected - 1);

    for (i = 0; i < p->history_count; ++i) {
        for (j = 0; j < count; ++j) {
            if (ids[j] != p->history[i]) continue;
            /* Compacted in place, so the surviving order is the MRU order. */
            p->history[surviving++] = p->history[i];
            SPDF_WARM_APPEND(j);
            break;
        }
    }
    p->history_count = surviving;
    for (i = surviving; i < SPDF_WIN_WARM_HISTORY_MAX; ++i) p->history[i] = 0;

    for (distance = 2; used + 1 < count && used < max_out; ++distance) {
        int before = used;
        SPDF_WARM_APPEND(selected + distance);
        SPDF_WARM_APPEND(selected - distance);
        /* Both ends of the strip are past: nothing further can be appended, so
         * stop rather than count to infinity. */
        if (used == before && selected + distance >= count && selected - distance < 0) break;
    }
#undef SPDF_WARM_APPEND
    return used;
}

/* ---------------------------------------------------------------------------
 * 3. The budget, and the handshake with the foreground
 *
 * ONE warm worker (spdf_mac_launch_inactive_worker_limit), and it may not start
 * while ANY foreground operation is outstanding. The mac counts six kinds; the
 * Windows shapes that correspond are named in the parameters. The rule is the
 * simple one on purpose: warming is worth nothing if it competes with the thing
 * the reader is waiting for.
 *
 * NOT YET WIRED, and this is what it is waiting for. The store an inactive
 * tab's warm page would land in has to outlive the canvas, because
 * spdf_win_tabs_app.h destroys the canvas on every switch -- so warming needs a
 * process-wide page store and a document handle the tab model keeps, and both
 * of those live in the tab and shell files rather than here. This header is the
 * policy half, tested against the mac policy's own expectations, so that when
 * the wiring lands it does not have to invent the schedule as well. */
static int spdf_win_warm_inactive_worker_limit(void) { return 1; }

static int spdf_win_warm_can_start(unsigned page_renders, unsigned metadata_jobs, unsigned thumbnail_jobs,
                                   unsigned zoom_seeds, unsigned cache_jobs, unsigned background_jobs) {
    return page_renders == 0 && metadata_jobs == 0 && thumbnail_jobs == 0 && zoom_seeds == 0 && cache_jobs == 0 &&
                   background_jobs == 0
               ? 1
               : 0;
}

/* WHO OWNS THE WARM-UP WHEN THE READER CLICKS THE TAB. Ported from
 * SPDFMacInactivePreload's state machine: the foreground either cancels the
 * warm-up before the worker has claimed the open, or takes ownership of the one
 * in flight. It NEVER starts a competing open, because the measured cost of
 * abandoning an in-flight open and redoing it was a duplicate of work that was
 * milliseconds from done.
 *
 * PURE, so the WAIT is the caller's. The mac blocks on a dispatch_group;
 * spdf_win_warm_preload_settled() is the predicate a Win32 event or a bounded
 * poll would wait on, and take_foreground() must only be called once it is
 * true. That seam is the only thing not ported verbatim, and it is what keeps
 * this header free of windows.h. */
typedef enum SpdfWinWarmPreloadState {
    SPDF_WIN_WARM_PRELOAD_PREPARING = 0,
    SPDF_WIN_WARM_PRELOAD_OPENING = 1,
    SPDF_WIN_WARM_PRELOAD_WORKING = 2,
    SPDF_WIN_WARM_PRELOAD_FINISHED = 3,
    SPDF_WIN_WARM_PRELOAD_CONSUMED = 4
} SpdfWinWarmPreloadState;

typedef struct SpdfWinWarmPreload {
    int state; /* SpdfWinWarmPreloadState */
    int foreground_claimed;
    int settled;
    void* document; /* borrowed until taken; the caller's spdf_document* */
} SpdfWinWarmPreload;

static void spdf_win_warm_preload_init(SpdfWinWarmPreload* pre) {
    if (!pre) return;
    pre->state = SPDF_WIN_WARM_PRELOAD_PREPARING;
    pre->foreground_claimed = 0;
    pre->settled = 0;
    pre->document = 0;
}

/* Worker: may I open the document? No once the foreground has claimed it. */
static int spdf_win_warm_preload_may_open(SpdfWinWarmPreload* pre) {
    if (!pre || pre->state != SPDF_WIN_WARM_PRELOAD_PREPARING || pre->foreground_claimed) return 0;
    pre->state = SPDF_WIN_WARM_PRELOAD_OPENING;
    return 1;
}

/* Worker: the open succeeded; may I go on to render pages into the warm store?
 * The document is published either way, because a foreground that has claimed
 * it wants exactly this handle rather than a second open of the same file. */
static int spdf_win_warm_preload_may_continue(SpdfWinWarmPreload* pre, void* document) {
    if (!pre) return 0;
    pre->document = document;
    if (pre->foreground_claimed) return 0;
    pre->state = SPDF_WIN_WARM_PRELOAD_WORKING;
    return 1;
}

/* Worker: done, whatever the outcome. Exactly one call, so the foreground's
 * wait always ends. */
static void spdf_win_warm_preload_finish(SpdfWinWarmPreload* pre) {
    if (!pre) return;
    if (pre->state != SPDF_WIN_WARM_PRELOAD_CONSUMED) pre->state = SPDF_WIN_WARM_PRELOAD_FINISHED;
    pre->settled = 1;
}

static int spdf_win_warm_preload_settled(const SpdfWinWarmPreload* pre) { return pre && pre->settled ? 1 : 0; }

/* Foreground: the reader picked this tab. Returns 0 only when the warm-up has
 * already been consumed, i.e. when there is nothing here to take. Claiming
 * before the worker ever started settles it immediately, so the caller does not
 * wait for a worker that will now refuse to run. */
static int spdf_win_warm_preload_claim(SpdfWinWarmPreload* pre) {
    if (!pre || pre->state == SPDF_WIN_WARM_PRELOAD_CONSUMED) return 0;
    pre->foreground_claimed = 1;
    if (pre->state == SPDF_WIN_WARM_PRELOAD_PREPARING) spdf_win_warm_preload_finish(pre);
    return 1;
}

/* Foreground, once settled: take the document the worker opened, or NULL when
 * there is none and the foreground must open it itself. */
static void* spdf_win_warm_preload_take_foreground(SpdfWinWarmPreload* pre) {
    void* document;
    if (!pre || !pre->settled || !pre->foreground_claimed || pre->state == SPDF_WIN_WARM_PRELOAD_CONSUMED) return 0;
    document = pre->document;
    pre->document = 0;
    pre->state = SPDF_WIN_WARM_PRELOAD_CONSUMED;
    return document;
}

/* Background: adopt the finished warm-up into the warm store. Refused once the
 * foreground has claimed it, so the handle has exactly one consumer. */
static void* spdf_win_warm_preload_take_background(SpdfWinWarmPreload* pre) {
    void* document;
    if (!pre || pre->foreground_claimed || pre->state != SPDF_WIN_WARM_PRELOAD_FINISHED) return 0;
    document = pre->document;
    pre->document = 0;
    pre->state = SPDF_WIN_WARM_PRELOAD_CONSUMED;
    return document;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_WARM_POLICY_H */
