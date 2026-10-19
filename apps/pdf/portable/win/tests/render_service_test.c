/* render_service_test.c — the render pool's scheduling contract, asserted
 * against a stub renderer (track T5).
 *
 * Everything here runs at the injectable seam: spdf_win_render_service_new()
 * is handed a backend whose render hook is a controllable stub, so no MuPDF
 * page is ever rasterised and no window exists. That is what makes these
 * assertions deterministic -- a real render's duration is not.
 *
 * The stub's gate is the whole trick. While the gate is up, a render blocks
 * inside the stub polling spdf_win_render_aborted(), which lets the test park
 * a worker mid-render and then observe what the pool does to it: coalesce more
 * askers onto it, supersede it, cancel it, or shut down under it. Dropping the
 * gate lets everything drain.
 *
 * Exit code is the result: 0 only when every check passed.
 *
 * The two declarations below are read by portable/win/tests/run-tests.sh, which
 * expects each on a single line ending in the comment terminator -- hence the
 * long line, which is not reflowable. */
/* spdf-test-sources: portable/win/src/spdf_win_render.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-needs: mupdf */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spdf_win_render.h"

#ifdef _WIN32
#include <windows.h>
#define SLEEP_MS(n) Sleep(n)
#define AGET(p) ((long)InterlockedCompareExchange((volatile LONG*)(p), 0, 0))
#define ASET(p, v) ((void)InterlockedExchange((volatile LONG*)(p), (LONG)(v)))
#define AADD(p) ((void)InterlockedIncrement((volatile LONG*)(p)))
#define SET_WORKERS(v) ((void)_putenv_s("SPDF_RENDER_WORKERS", (v)))
#else
#include <unistd.h>
#define SLEEP_MS(n) usleep((useconds_t)(n) * 1000)
#define AGET(p) __atomic_load_n((p), __ATOMIC_SEQ_CST)
#define ASET(p, v) __atomic_store_n((p), (long)(v), __ATOMIC_SEQ_CST)
#define AADD(p) ((void)__atomic_add_fetch((p), 1, __ATOMIC_SEQ_CST))
#define SET_WORKERS(v) ((void)setenv("SPDF_RENDER_WORKERS", (v), 1))
#endif

static int g_failures = 0;
static const char* g_case = "";

static void check(int ok, const char* what) {
    if (ok) return;
    printf("FAIL [%s] %s\n", g_case, what);
    g_failures++;
}

/* --- the stub renderer -------------------------------------------------- */

#define STUB_MAX_SPINS 20000 /* ~20 s: a cancel that does not work will show */

typedef struct stub {
    volatile long gate;     /* 1: renders block until this drops */
    volatile long entered;  /* renders that reached the stub */
    volatile long aborts;   /* renders that saw the abort flag and stopped */
    volatile long spins;    /* spins of the most recent gated render */
    volatile long notified; /* notify-hook fires */
    float page_w, page_h;   /* what page_size reports (immutable per case) */
} stub;

static int stub_page_size(void* ctx, const char* path, int page, float* w, float* h, char* err, size_t n) {
    stub* s = (stub*)ctx;
    (void)path;
    (void)page;
    (void)err;
    (void)n;
    *w = s->page_w;
    *h = s->page_h;
    return 1;
}

/* The rendered pixels encode (page, flags, zoom) so a test can prove that the
 * bitmap it received was produced by the request it thinks it was. */
static int stub_render(void* ctx, const char* path, int page, float zoom, unsigned flags,
                       const spdf_win_render_abort* abort, spdf_bitmap* out, char* err, size_t n) {
    stub* s = (stub*)ctx;
    long i;
    (void)path;
    AADD(&s->entered);
    for (i = 0; i < STUB_MAX_SPINS && AGET(&s->gate); i++) {
        if (spdf_win_render_aborted(abort)) break;
        SLEEP_MS(1);
    }
    ASET(&s->spins, i);
    if (spdf_win_render_aborted(abort)) {
        AADD(&s->aborts);
        snprintf(err, n, "Render canceled.");
        return 0;
    }
    out->width = 4;
    out->height = 4;
    out->stride = 16;
    out->rgba = (unsigned char*)calloc(1, 64);
    if (!out->rgba) return 0;
    out->rgba[0] = (unsigned char)page;
    out->rgba[1] = (unsigned char)flags;
    out->rgba[2] = (unsigned char)(int)(zoom * 10.0f + 0.5f);
    return 1;
}

static void stub_notify(void* ctx) { AADD(&((stub*)ctx)->notified); }

/* --- what the callbacks recorded ---------------------------------------- */

#define MAX_TOK 4096

static int r_calls[MAX_TOK], r_status[MAX_TOK], r_page[MAX_TOK], r_pixel_page[MAX_TOK];
static unsigned r_flags[MAX_TOK];
static unsigned long long r_primary[MAX_TOK];
static float r_zoom[MAX_TOK];
static unsigned long long r_order[MAX_TOK];
static int r_delivered;

static void reset_records(void) {
    memset(r_calls, 0, sizeof(r_calls));
    memset(r_status, 0, sizeof(r_status));
    memset(r_pixel_page, -1, sizeof(r_pixel_page));
    r_delivered = 0;
}

/* Runs on the draining thread, one call per request, ever. */
static void on_done(spdf_win_render_result* res, void* user_data) {
    size_t i = (size_t)res->token;
    (void)user_data;
    if (i >= MAX_TOK) {
        check(0, "token out of test range");
        return;
    }
    r_calls[i]++;
    r_status[i] = res->status;
    r_page[i] = res->spec.page;
    r_flags[i] = res->spec.flags;
    r_primary[i] = res->primary_token;
    r_zoom[i] = res->render_zoom;
    r_pixel_page[i] = res->rgba ? (int)res->rgba[0] : -1;
    if (r_delivered < MAX_TOK) r_order[r_delivered] = res->token;
    r_delivered++;
}

/* --- waiting ------------------------------------------------------------ */

static int wait_entered(stub* s, long n, int ms) {
    while (ms-- > 0 && AGET(&s->entered) < n) SLEEP_MS(1);
    return AGET(&s->entered) >= n;
}

static int wait_aborts(stub* s, long n, int ms) {
    while (ms-- > 0 && AGET(&s->aborts) < n) SLEEP_MS(1);
    return AGET(&s->aborts) >= n;
}

/* NOTE: idle means every request has been ANSWERED, which for a cancelled or
 * superseded one happens the instant it is retired -- before the worker has
 * noticed. Use wait_aborts() to observe the render itself stopping. */
static int wait_idle(spdf_win_render_service* svc, int ms) {
    while (ms-- > 0 && spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_INFLIGHT) > 0) SLEEP_MS(1);
    return spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_INFLIGHT) == 0;
}

/* `max_workers` 0 is the plain constructor's behaviour -- the policy default,
 * i.e. whatever SPDF_RENDER_WORKERS said. Anything else is the per-service
 * ceiling case_worker_ceiling() drives. */
static spdf_win_render_service* make_service(stub* s, const char* workers, size_t cap, int max_workers) {
    static spdf_win_render_backend backend;
    backend.ctx = s;
    backend.page_size = stub_page_size;
    backend.render = stub_render;
    backend.thread_exit = NULL;
    memset(s, 0, sizeof(*s));
    s->page_w = 612.0f;
    s->page_h = 792.0f;
    SET_WORKERS(workers);
    reset_records();
    return max_workers ? spdf_win_render_service_new_ex("C:\\stub.pdf", &backend, cap, stub_notify, s, max_workers)
                       : spdf_win_render_service_new("C:\\stub.pdf", &backend, cap, stub_notify, s);
}

static spdf_win_render_spec spec_of(int page, float zoom, unsigned flags) {
    spdf_win_render_spec spec;
    spec.page = page;
    spec.zoom = zoom;
    spec.flags = flags;
    spec.generation = 0;
    return spec;
}

static unsigned long long ask(spdf_win_render_service* svc, int page, float zoom, unsigned flags, int priority) {
    spdf_win_render_spec spec = spec_of(page, zoom, flags);
    return spdf_win_render_request(svc, &spec, priority, on_done, NULL);
}

/* Every token in [1, last] was delivered exactly once. */
static void check_exactly_once(unsigned long long last) {
    unsigned long long i;
    int bad = 0;
    for (i = 1; i <= last && i < MAX_TOK; i++)
        if (r_calls[i] != 1) bad++;
    check(bad == 0, "every token delivered exactly once");
}

/* --- cases -------------------------------------------------------------- */

/* Identity, not threads: the render flags are part of a page's key, so a
 * theme flip cannot be answered with a light-theme bitmap. */
static void case_identity(void) {
    spdf_win_render_spec a = spec_of(3, 1.5f, 0);
    spdf_win_render_spec b = spec_of(3, 1.5f, SPDF_RENDER_DARK_THEME);
    spdf_win_render_spec c = spec_of(3, 1.5f + 1.0f / 65536.0f, 0);
    spdf_win_render_key ka = spdf_win_render_key_for(&a);
    spdf_win_render_key kb = spdf_win_render_key_for(&b);
    spdf_win_render_key kc = spdf_win_render_key_for(&c);
    double capped;
    g_case = "identity";
    check(spdf_win_render_key_equal(&ka, &ka), "a key equals itself");
    check(!spdf_win_render_key_equal(&ka, &kb), "dark theme is a different key");
    check(spdf_win_render_key_hash(&ka) != spdf_win_render_key_hash(&kb), "dark theme hashes differently");
    check(spdf_win_render_key_equal(&ka, &kc), "sub-quantum zoom difference is the same key");
    capped = spdf_win_render_capped_zoom(4.0, 10900.0, 7539.0, SPDF_WIN_RENDER_MAX_BYTES);
    check(capped < 4.0, "an oversized sheet is capped below the requested zoom");
    check(10900.0 * 7539.0 * capped * capped * 4.0 <= (double)SPDF_WIN_RENDER_MAX_BYTES + 1.0, "capped under budget");
    check(spdf_win_render_capped_zoom(2.0, 612.0, 792.0, SPDF_WIN_RENDER_MAX_BYTES) == 2.0, "a normal page is uncapped");
}

/* The happy path, plus the byte cap actually applied by a worker. */
static void case_delivery(void) {
    stub s;
    spdf_win_render_service* svc = make_service(&s, "2", 0, 0);
    unsigned long long a, b, c;
    g_case = "delivery";
    check(svc != NULL, "service created");
    if (!svc) return;
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_WORKERS) == 0, "no threads before the first request");
    a = ask(svc, 0, 1.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    b = ask(svc, 1, 2.0f, SPDF_RENDER_DARK_THEME, SPDF_WIN_RENDER_NEAR);
    c = ask(svc, 2, 1.0f, 0, SPDF_WIN_RENDER_WARM);
    check(a && b && c && a != b && b != c, "distinct tokens");
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_WORKERS) <= SPDF_WIN_RENDER_MAX_WORKERS, "worker cap held");
    check(wait_idle(svc, 5000), "all three renders finished");
    check(spdf_win_render_drain(svc, 0) == 3, "drain delivered three results");
    check_exactly_once(c);
    check(r_status[a] == SPDF_WIN_RENDER_OK && r_status[b] == SPDF_WIN_RENDER_OK, "renders succeeded");
    check(r_pixel_page[b] == 1, "the bitmap came from the page that was asked for");
    check(r_flags[b] == SPDF_RENDER_DARK_THEME, "the result carries the flags that produced it");
    check(AGET(&s.notified) > 0, "the notify hook fired from a worker");
    spdf_win_render_service_free(svc);

    svc = make_service(&s, "1", 0, 0);
    if (!svc) return;
    s.page_w = 10900.0f;
    s.page_h = 7539.0f;
    a = ask(svc, 0, 4.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    check(wait_idle(svc, 5000) && spdf_win_render_drain(svc, 0) == 1, "giant-sheet render finished");
    check(r_zoom[a] > 0.0f && r_zoom[a] < 4.0f, "the worker applied the byte cap to the render zoom");
    spdf_win_render_service_free(svc);
}

/* Five asks for one page start one render. The first asker gets the pixels;
 * the rest are told which token did. A different theme is a different render. */
static void case_coalescing(void) {
    stub s;
    spdf_win_render_service* svc = make_service(&s, "1", 0, 0);
    unsigned long long a, b, c, d, dark;
    int i;
    g_case = "coalescing";
    if (!svc) return;
    ASET(&s.gate, 1);
    a = ask(svc, 7, 1.0f, 0, SPDF_WIN_RENDER_NEAR);
    check(wait_entered(&s, 1, 5000), "the first render is parked in the stub");
    b = ask(svc, 7, 1.0f, 0, SPDF_WIN_RENDER_NEAR);
    c = ask(svc, 7, 1.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    d = ask(svc, 7, 1.0f, 0, SPDF_WIN_RENDER_WARM);
    dark = ask(svc, 7, 1.0f, SPDF_RENDER_DARK_THEME, SPDF_WIN_RENDER_NEAR);
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_TASKS_STARTED) == 1, "no second task while one is running");
    ASET(&s.gate, 0);
    check(wait_idle(svc, 5000), "everything finished");
    check(spdf_win_render_drain(svc, 0) == 5, "five callbacks for five requests");
    check_exactly_once(dark);
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_TASKS_STARTED) == 2,
          "four identical asks ran one render; the dark one ran its own");
    check(AGET(&s.entered) == 2, "the backend was entered twice, not five times");
    check(r_status[a] == SPDF_WIN_RENDER_OK && r_pixel_page[a] == 7, "the first asker got the pixels");
    for (i = 0; i < 3; i++) {
        unsigned long long t = i == 0 ? b : (i == 1 ? c : d);
        check(r_status[t] == SPDF_WIN_RENDER_COALESCED, "a later asker was told it coalesced");
        check(r_primary[t] == a, "coalesced results name the token that got the pixels");
        check(r_pixel_page[t] == -1, "coalesced results carry no pixels");
    }
    check(r_status[dark] == SPDF_WIN_RENDER_OK && r_flags[dark] == SPDF_RENDER_DARK_THEME, "the dark render is its own");
    spdf_win_render_service_free(svc);
}

/* A theme flip is a generation bump: in-flight work stops and its pixels are
 * never adopted, and a request built against a dead epoch never runs. */
static void case_supersede(void) {
    stub s;
    spdf_win_render_service* svc = make_service(&s, "1", 0, 0);
    spdf_win_render_spec stale;
    unsigned long long a, old_gen, late;
    g_case = "supersede";
    if (!svc) return;
    old_gen = spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_GENERATION);
    ASET(&s.gate, 1);
    a = ask(svc, 4, 1.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    check(wait_entered(&s, 1, 5000), "the render is parked in the stub");
    check(spdf_win_render_service_bump_generation(svc) == old_gen + 1, "generation advanced");
    check(wait_idle(svc, 5000), "the superseded request was answered immediately");
    check(wait_aborts(&s, 1, 5000), "the running render observed the abort and returned early");
    check(AGET(&s.aborts) == 1, "exactly one render was aborted");
    check(AGET(&s.spins) < STUB_MAX_SPINS, "it stopped early rather than running to completion");
    check(spdf_win_render_drain(svc, 0) == 1, "the superseded request still got its callback");
    check(r_status[a] == SPDF_WIN_RENDER_SUPERSEDED, "status is SUPERSEDED");
    check(r_pixel_page[a] == -1, "no stale pixels reached the caller");
    ASET(&s.gate, 0);

    stale = spec_of(4, 1.0f, 0);
    stale.generation = old_gen; /* explicitly from the dead epoch */
    late = spdf_win_render_request(svc, &stale, SPDF_WIN_RENDER_VISIBLE, on_done, NULL);
    check(late != 0, "a stale request is still accepted and answered");
    check(spdf_win_render_drain(svc, 0) == 1, "answered without waiting for a worker");
    check(r_status[late] == SPDF_WIN_RENDER_SUPERSEDED, "a stale request is never rendered");
    check(AGET(&s.entered) == 1, "the backend was never entered for it");
    check_exactly_once(late);
    spdf_win_render_service_free(svc);
}

/* Cancelling stops a running render, and stops a queued one from ever
 * starting. Both still get exactly one callback. */
static void case_cancel(void) {
    stub s;
    spdf_win_render_service* svc = make_service(&s, "1", 0, 0);
    unsigned long long running, queued;
    g_case = "cancel";
    if (!svc) return;
    ASET(&s.gate, 1);
    running = ask(svc, 1, 1.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    check(wait_entered(&s, 1, 5000), "the render is parked in the stub");
    queued = ask(svc, 2, 1.0f, 0, SPDF_WIN_RENDER_WARM);
    spdf_win_render_cancel(svc, queued);
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_TASKS_STARTED) == 1, "the queued render never started");
    spdf_win_render_cancel(svc, running);
    check(wait_idle(svc, 5000), "both requests were answered immediately");
    check(wait_aborts(&s, 1, 5000), "the running render observed the abort, gate still up");
    check(AGET(&s.aborts) == 1, "exactly one render was aborted");
    check(AGET(&s.spins) < STUB_MAX_SPINS, "cancellation actually stopped the work");
    check(AGET(&s.entered) == 1, "the cancelled queued render never reached the backend");
    check(spdf_win_render_drain(svc, 0) == 2, "both requests were answered");
    check(r_status[running] == SPDF_WIN_RENDER_CANCELED, "the running one reports CANCELED");
    check(r_status[queued] == SPDF_WIN_RENDER_CANCELED, "the queued one reports CANCELED");
    check_exactly_once(queued);
    spdf_win_render_cancel(svc, 999999); /* unknown token must be a no-op */
    check(spdf_win_render_drain(svc, 0) == 0, "cancelling an unknown token delivers nothing");
    ASET(&s.gate, 0);
    spdf_win_render_service_free(svc);
}

/* One worker, so the order results arrive in is fully determined: priority
 * first, then the order the requests were made. */
static void case_order(void) {
    stub s;
    spdf_win_render_service* svc = make_service(&s, "1", 0, 0);
    unsigned long long block, warm, mid, vis1, vis2;
    g_case = "order";
    if (!svc) return;
    ASET(&s.gate, 1);
    block = ask(svc, 99, 1.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    check(wait_entered(&s, 1, 5000), "the single worker is parked");
    warm = ask(svc, 5, 1.0f, 0, SPDF_WIN_RENDER_WARM);
    mid = ask(svc, 4, 1.0f, 0, SPDF_WIN_RENDER_NEAR);
    vis1 = ask(svc, 3, 1.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    vis2 = ask(svc, 2, 1.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    ASET(&s.gate, 0);
    check(wait_idle(svc, 10000), "the queue drained");
    check(spdf_win_render_drain(svc, 0) == 5, "five results");
    check(r_order[0] == block, "the parked render completes first");
    check(r_order[1] == vis1 && r_order[2] == vis2, "visible before near, FIFO within the band");
    check(r_order[3] == mid, "near before warm");
    check(r_order[4] == warm, "warm last");
    check_exactly_once(vis2);
    spdf_win_render_service_free(svc);
}

/* Freeing with work in flight still releases every request's user_data. */
static void case_shutdown(void) {
    stub s;
    spdf_win_render_service* svc = make_service(&s, "1", 0, 0);
    unsigned long long a, b, c;
    int i, all = 1;
    g_case = "shutdown";
    if (!svc) return;
    ASET(&s.gate, 1);
    a = ask(svc, 1, 1.0f, 0, SPDF_WIN_RENDER_VISIBLE);
    check(wait_entered(&s, 1, 5000), "a render is parked");
    b = ask(svc, 2, 1.0f, 0, SPDF_WIN_RENDER_NEAR);
    c = ask(svc, 3, 1.0f, 0, SPDF_WIN_RENDER_WARM);
    spdf_win_render_service_free(svc); /* delivers on this thread before returning */
    check(r_delivered == 3, "every outstanding request was answered by free()");
    check_exactly_once(c);
    for (i = (int)a; i <= (int)c; i++)
        if (r_status[i] != SPDF_WIN_RENDER_SHUTDOWN) all = 0;
    check(all, "all three report SHUTDOWN");
    check(b != 0, "tokens were issued");
}

/* THE TIERING KNOB: a real ceiling, not a hint. It is what stops the minimap's
 * pool from out-threading the canvas's, so that a process running two pools
 * does not start 2 * cores/2 workers inside its first paint
 * (portable/docs/windows-launch-performance.md §3.4, §5 item 3).
 *
 * Proved through the gate, not the counter alone: while the gate is up every
 * started render parks inside the stub, so the number that ENTERED is the
 * number of threads whatever the queue depth. Six distinct pages cannot
 * coalesce, so a third worker would appear as a third entrant. */
static void case_worker_ceiling(void) {
    stub s;
    spdf_win_render_service* svc = make_service(&s, "4", 0, 2);
    unsigned long long last = 0;
    int i;
    g_case = "worker-ceiling";
    if (!svc) return;
    ASET(&s.gate, 1);
    for (i = 0; i < 6; i++) last = ask(svc, i, 1.0f, 0, SPDF_WIN_RENDER_NEAR);
    check(wait_entered(&s, 2, 4000), "both permitted workers picked up a render");
    SLEEP_MS(60); /* long enough for a third worker to have entered, had one existed */
    check(AGET(&s.entered) == 2, "exactly two renders are in flight, not four");
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_WORKERS) == 2, "two threads, not SPDF_RENDER_WORKERS' four");
    ASET(&s.gate, 0);
    check(wait_idle(svc, 20000), "the capped pool still drains everything");
    (void)spdf_win_render_drain(svc, 0);
    check_exactly_once(last);
    spdf_win_render_service_free(svc);

    /* A ceiling above the policy is not a floor: the cap caps. */
    svc = make_service(&s, "1", 0, 4);
    if (!svc) return;
    last = ask(svc, 0, 1.0f, 0, SPDF_WIN_RENDER_NEAR);
    check(wait_idle(svc, 20000), "the one-worker pool drained");
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_WORKERS) == 1, "a ceiling of 4 does not raise a target of 1");
    (void)spdf_win_render_drain(svc, 0);
    check_exactly_once(last);
    spdf_win_render_service_free(svc);
}

/* The thread-sanitizer case: many workers, requests, cancels and generation
 * bumps racing against draining, with one invariant that must survive it all. */
static void case_stress(void) {
    stub s;
    spdf_win_render_service* svc = make_service(&s, "4", 0, 0);
    unsigned long long tokens[600];
    unsigned seed = 12345u;
    int i, accepted = 0;
    g_case = "stress";
    if (!svc) return;
    for (i = 0; i < 600; i++) {
        seed = seed * 1103515245u + 12345u;
        tokens[i] = ask(svc, (int)((seed >> 16) % 12), 1.0f + (float)((seed >> 8) % 4),
                        ((seed >> 4) & 1u) ? SPDF_RENDER_DARK_THEME : 0u, (int)((seed >> 20) % 3));
        if (tokens[i]) accepted++;
        if (i % 7 == 3) spdf_win_render_cancel(svc, tokens[(seed >> 12) % (unsigned)(i + 1)]);
        if (i % 53 == 17) (void)spdf_win_render_service_bump_generation(svc);
        if (i % 11 == 5) (void)spdf_win_render_drain(svc, 4);
    }
    check(wait_idle(svc, 20000), "the pool went idle");
    (void)spdf_win_render_drain(svc, 0);
    check(r_delivered == accepted, "one delivery per accepted request, no more and no fewer");
    check_exactly_once(tokens[599]);
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_INFLIGHT) == 0, "nothing left in flight");
    check(spdf_win_render_stat(svc, SPDF_WIN_RENDER_STAT_WORKERS) <= SPDF_WIN_RENDER_MAX_WORKERS, "worker cap held");
    spdf_win_render_service_free(svc);
}

int main(void) {
    check(spdf_win_render_service_new(NULL, NULL, 0, NULL, NULL) == NULL, "a NULL path is rejected");
    check(spdf_win_render_request(NULL, NULL, 0, NULL, NULL) == 0, "a NULL service is rejected");
    case_identity();
    case_delivery();
    case_coalescing();
    case_supersede();
    case_cancel();
    case_order();
    case_shutdown();
    case_worker_ceiling();
    case_stress();
    printf("render_service_test: %s (%d failure%s)\n", g_failures ? "FAIL" : "PASS", g_failures,
           g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}
