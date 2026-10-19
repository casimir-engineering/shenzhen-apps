/* spdf_win_render_thread.h — the two-line-per-primitive threading layer the
 * render pool is written against.
 *
 * Extracted from spdf_win_render.c under the repo's 500-line cap
 * (tools/file-size-limits.md), which is the rule that says extract rather than
 * raise. The seam is the honest one: everything here is "how do I take a lock,
 * wait on a condition, start a thread and read an atomic on this platform", and
 * nothing here knows what a render is. spdf_win_render.c is then the scheduling
 * policy with no #ifdef in it below the include.
 *
 * WHY THERE IS A PTHREAD BRANCH AT ALL, since the product is Windows-only: it
 * lets the exact scheduling code in spdf_win_render.c run under
 * ThreadSanitizer, which no MSVC build can do. That is the only reason, and it
 * is worth the twenty lines -- the alternative is that the one file in this
 * frontend with four threads in it is the one file never checked by a race
 * detector.
 *
 * Included by spdf_win_render.c and spdf_win_render_core.h, and by nothing
 * else: a caller outside the pool has no business starting threads of its own.
 */
#ifndef SPDF_WIN_RENDER_THREAD_H
#define SPDF_WIN_RENDER_THREAD_H

#ifdef _WIN32
#include <process.h>
#include <windows.h>
typedef SRWLOCK spdf_mtx;
typedef CONDITION_VARIABLE spdf_cnd;
typedef HANDLE spdf_thr;
#define MTX_INIT(m) InitializeSRWLock(m)
#define MTX_LOCK(m) AcquireSRWLockExclusive(m)
#define MTX_UNLOCK(m) ReleaseSRWLockExclusive(m)
#define CND_INIT(c) InitializeConditionVariable(c)
#define CND_WAIT(c, m) ((void)SleepConditionVariableSRW((c), (m), INFINITE, 0))
#define CND_BROADCAST(c) WakeAllConditionVariable(c)
#define THR_START(out, fn, arg) (((*(out)) = (spdf_thr)_beginthreadex(NULL, 0, (fn), (arg), 0, NULL)) != NULL)
/* Wait for every worker to exit, for at most `ms`; 1 when all of them did.
 * The handles are closed either way -- a thread outlives its handle. */
#define THR_JOIN_ALL(handles, n, ms) spdf_win_render_join_all((handles), (n), (ms))
#define ATOMIC_LOAD(p) ((long)InterlockedCompareExchange((volatile LONG*)(p), 0, 0))
#define ATOMIC_STORE(p, v) ((void)InterlockedExchange((volatile LONG*)(p), (LONG)(v)))
#define SPDF_TLS __declspec(thread)
#define WORKER_ENTRY unsigned __stdcall
#define WORKER_RETURN 0
#define SPDF_CPU_COUNT() spdf_win_render_cpu_count()
static int spdf_win_render_cpu_count(void) {
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    return (int)info.dwNumberOfProcessors;
}
static int spdf_win_render_join_all(spdf_thr* handles, int n, unsigned ms) {
    int i;
    int ok = n <= 0 || WaitForMultipleObjects((DWORD)n, handles, TRUE, ms) == WAIT_OBJECT_0;
    for (i = 0; i < n; i++) CloseHandle(handles[i]);
    return ok;
}
#else
#include <pthread.h>
#include <unistd.h>
typedef pthread_mutex_t spdf_mtx;
typedef pthread_cond_t spdf_cnd;
typedef pthread_t spdf_thr;
#define MTX_INIT(m) pthread_mutex_init((m), NULL)
#define MTX_LOCK(m) pthread_mutex_lock(m)
#define MTX_UNLOCK(m) pthread_mutex_unlock(m)
#define CND_INIT(c) pthread_cond_init((c), NULL)
#define CND_WAIT(c, m) pthread_cond_wait((c), (m))
#define CND_BROADCAST(c) pthread_cond_broadcast(c)
#define THR_START(out, fn, arg) (pthread_create((out), NULL, (fn), (arg)) == 0)
/* No timed join in pthreads, and this branch exists for ThreadSanitizer, not
 * for a desktop: it joins outright, so the abandon path is Windows-only. */
#define THR_JOIN_ALL(handles, n, ms) spdf_win_render_join_all((handles), (n), (ms))
#define ATOMIC_LOAD(p) __atomic_load_n((p), __ATOMIC_SEQ_CST)
#define ATOMIC_STORE(p, v) __atomic_store_n((p), (long)(v), __ATOMIC_SEQ_CST)
#define SPDF_TLS __thread
#define WORKER_ENTRY void*
#define WORKER_RETURN NULL
#define SPDF_CPU_COUNT() ((int)sysconf(_SC_NPROCESSORS_ONLN))
static int spdf_win_render_join_all(spdf_thr* handles, int n, unsigned ms) {
    int i;
    (void)ms;
    for (i = 0; i < n; i++) (void)pthread_join(handles[i], NULL);
    return 1;
}
#endif

#endif /* SPDF_WIN_RENDER_THREAD_H */
