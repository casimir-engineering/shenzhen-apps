/* spdf_win_launch_profile.h — the in-process launch timeline.
 *
 * WHAT IT IS. One line per phase, in the format the GTK frontend already
 * prints (portable/docs/gtk4-captures/launch-profile.txt):
 *
 *     SPDF-LAUNCH     12.3ms d2d-factories
 *
 * with the millisecond count measured from PROCESS CREATION -- the kernel's
 * timestamp for this process, read back through GetProcessTimes -- rather
 * than from main(), so the loader, the static CRT's initialisation and the
 * 40 MB image's first page-ins are inside the number. A shell stopwatch
 * started before CreateProcess and this timeline therefore share an origin
 * to within the kernel's clock granularity, and portable/win/measure-launch.ps1
 * lines the two up on exactly that basis.
 *
 * WHY IT EXISTS. The first launch measurement of this port was a phantom (the
 * observations' §4.8: a constant second that belonged to the stopwatch, not
 * the app), and the second could see the window appear but not the page. The
 * number a reader feels is launch -> first PAGE pixels, and only the process
 * itself knows when its first frame was presented. This header is how it says
 * so.
 *
 * ZERO COST WHEN OFF, and that is the whole design:
 *
 *   - ONE environment check per process, on the first mark, guarded by an
 *     interlocked state so the check is exactly one even if the first two
 *     marks race on two threads.
 *   - When SPDF_WIN_LAUNCH_PROFILE is unset every later mark is one load and
 *     one compare (`state > 0`). No formatting, no allocation, no call.
 *   - When set, a mark formats into a stack buffer and does one WriteFile.
 *     Nothing is buffered, so a crash after a mark still has the mark.
 *
 * SPDF_WIN_LAUNCH_PROFILE=1 (or "stderr") writes to the standard error handle
 * -- which a /SUBSYSTEM:WINDOWS process only has when its parent redirected
 * one; without it the marks are silently dropped. Any other value is a file
 * path, opened for append so a harness can delete it before a run and read
 * it after, and so a child process cannot truncate a parent's timeline.
 *
 * HEADER-ONLY, C AND C++, MANY TRANSLATION UNITS. The state lives in ONE
 * __declspec(selectany) object, so every TU that includes this header shares
 * the same env check and the same handle; the functions are `static` so a
 * TU that includes it and marks nothing costs a few unused bytes. MSVC only,
 * like everything under portable/win/src.
 *
 * SPDF_WIN_LAUNCH_MARK_ONCE(name) is for a site that runs every frame -- a
 * WM_PAINT, a compose, a texture upload -- where only the FIRST occurrence is
 * launch. The per-site flag is interlocked, so a worker thread and the UI
 * thread cannot both report the same first.
 *
 * Marks are stable identifiers, not prose: the harness groups runs by them.
 * The insertion points and the names they carry are listed in
 * portable/docs/windows-launch-performance.md and applied by
 * portable/docs/windows-launch-profile.patch where the file belongs to another
 * track.
 */
#ifndef SPDF_WIN_LAUNCH_PROFILE_H
#define SPDF_WIN_LAUNCH_PROFILE_H

#if !defined(_WIN32)
/* The portable files (spdf_win_render.c, spdf_win_lru.c) also build under
 * clang for the native test suite; there the timeline is simply absent. */
static void spdf_win_launch_mark(const char* phase) { (void)phase; }
static void spdf_win_launch_mark_n(const char* phase, long long n) { (void)phase; (void)n; }
static int spdf_win_launch_enabled(void) { return 0; }
#define SPDF_WIN_LAUNCH_MARK_ONCE(phase) ((void)0)
#else

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <stdio.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_win_launch_profile {
    /* 0 never checked; 2 checking (another thread is in init); 1 enabled;
     * -1 disabled. Only ever moves 0 -> 2 -> {1, -1}. */
    volatile long state;
    HANDLE out;
    LONGLONG qpc_freq;
    LONGLONG qpc_origin;    /* QueryPerformanceCounter at init */
    double ms_before_origin; /* process creation -> init, in ms */
} spdf_win_launch_profile;

/* One instance per process, however many TUs include this header. */
__declspec(selectany) spdf_win_launch_profile spdf_win_launch_profile_state = {0, NULL, 0, 0, 0.0};

static unsigned long long spdf_win_launch_ft_u64(const FILETIME* ft) {
    return ((unsigned long long)ft->dwHighDateTime << 32) | (unsigned long long)ft->dwLowDateTime;
}

/* The one environment check. Returns the state it settled on (1 or -1). */
static long spdf_win_launch_init(void) {
    spdf_win_launch_profile* p = &spdf_win_launch_profile_state;
    long prev = InterlockedCompareExchange(&p->state, 2, 0);
    if (prev != 0) {
        /* Someone else is initialising or has initialised: wait for the
         * verdict rather than duplicating the env check. Spinning is fine --
         * init is a handful of syscalls and this only ever races at launch. */
        while ((prev = InterlockedCompareExchange(&p->state, 0, 0)) == 2) SwitchToThread();
        return prev;
    }
    {
        wchar_t value[1024];
        DWORD n = GetEnvironmentVariableW(L"SPDF_WIN_LAUNCH_PROFILE", value, (DWORD)(sizeof(value) / sizeof(value[0])));
        HANDLE out = INVALID_HANDLE_VALUE;
        if (n == 0 || n >= (DWORD)(sizeof(value) / sizeof(value[0])) || value[0] == 0 ||
            wcscmp(value, L"0") == 0) {
            InterlockedExchange(&p->state, -1);
            return -1;
        }
        if (wcscmp(value, L"1") == 0 || wcscmp(value, L"stderr") == 0) {
            out = GetStdHandle(STD_ERROR_HANDLE);
            if (out == NULL) out = INVALID_HANDLE_VALUE;
        } else {
            out = CreateFileW(value, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        }
        if (out == INVALID_HANDLE_VALUE) {
            InterlockedExchange(&p->state, -1);
            return -1;
        }
        {
            LARGE_INTEGER freq, now;
            FILETIME created, exited, kernel, user, wall;
            QueryPerformanceFrequency(&freq);
            QueryPerformanceCounter(&now);
            GetSystemTimePreciseAsFileTime(&wall);
            p->qpc_freq = freq.QuadPart ? freq.QuadPart : 1;
            p->qpc_origin = now.QuadPart;
            p->ms_before_origin = 0.0;
            if (GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) {
                unsigned long long c = spdf_win_launch_ft_u64(&created), w = spdf_win_launch_ft_u64(&wall);
                if (w > c) p->ms_before_origin = (double)(w - c) / 10000.0;
            }
        }
        p->out = out;
        /* The handle and clocks are written before the state flips to 1, and
         * InterlockedExchange is a full barrier, so a reader that sees 1 sees
         * them. */
        InterlockedExchange(&p->state, 1);
        return 1;
    }
}

/* True when marks are being recorded. One load and one compare after the
 * first call. Use it to skip work that only exists to be marked. */
static int spdf_win_launch_enabled(void) {
    long s = spdf_win_launch_profile_state.state;
    if (s == 0 || s == 2) s = spdf_win_launch_init();
    return s > 0;
}

/* Milliseconds since process creation, or 0 when profiling is off. */
static double spdf_win_launch_now_ms(void) {
    LARGE_INTEGER now;
    const spdf_win_launch_profile* p = &spdf_win_launch_profile_state;
    if (!spdf_win_launch_enabled()) return 0.0;
    QueryPerformanceCounter(&now);
    return p->ms_before_origin + (double)(now.QuadPart - p->qpc_origin) * 1000.0 / (double)p->qpc_freq;
}

/* Record one phase. `phase` is a short stable token: "main", "spdf-open",
 * "first-paint-end". Nothing happens when profiling is off. */
static void spdf_win_launch_mark(const char* phase) {
    char line[256];
    int len;
    DWORD written = 0;
    double ms;
    if (!spdf_win_launch_enabled()) return;
    ms = spdf_win_launch_now_ms();
    /* Same field width as the GTK profile: "SPDF-LAUNCH      0.0ms main". */
    len = _snprintf_s(line, sizeof(line), _TRUNCATE, "SPDF-LAUNCH %9.1fms %s\n", ms, phase ? phase : "?");
    if (len <= 0) return;
    WriteFile(spdf_win_launch_profile_state.out, line, (DWORD)len, &written, NULL);
}

/* The same, with a number attached ("first-page-bitmap 1234x1650" reads
 * better than a second mark). */
static void spdf_win_launch_mark_n(const char* phase, long long n) {
    char text[160];
    if (!spdf_win_launch_enabled()) return;
    _snprintf_s(text, sizeof(text), _TRUNCATE, "%s %lld", phase ? phase : "?", n);
    spdf_win_launch_mark(text);
}

/* For a site that runs every frame: marks the FIRST time only. */
#define SPDF_WIN_LAUNCH_MARK_ONCE(phase)                                                          \
    do {                                                                                          \
        static volatile long spdf_win_launch_once_flag__ = 0;                                     \
        if (spdf_win_launch_enabled() && InterlockedExchange(&spdf_win_launch_once_flag__, 1) == 0) \
            spdf_win_launch_mark(phase);                                                          \
    } while (0)

#ifdef __cplusplus
}
#endif

#endif /* _WIN32 */
#endif /* SPDF_WIN_LAUNCH_PROFILE_H */
