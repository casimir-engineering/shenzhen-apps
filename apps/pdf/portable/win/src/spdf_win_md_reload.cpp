/* spdf_win_md_reload.cpp -- see spdf_win_md_reload.h. */
#include "spdf_win_md_reload.h"

#include "spdf_win_md.h"

#include <stdlib.h>
#include <string.h>

namespace {

/* One re-read in flight. Owned by the thread until it lands, then freed. */
struct reload_job {
    char path[1024];
    unsigned generation;
    HWND notify;
    UINT message;
};

/* SRWLOCK_INIT needs no init call, so there is no first-use race. */
SRWLOCK g_lock = SRWLOCK_INIT;
unsigned g_generation;         /* bumped by every begin(); a job whose generation differs is stale */
spdf_document* g_parked;       /* the landed document not yet taken */
char g_parked_path[1024];
HANDLE g_thread;               /* the most recent job's thread, for shutdown */
volatile LONG g_running;       /* jobs currently on a thread */

DWORD WINAPI reload_thread(void* arg) {
    reload_job* job = (reload_job*)arg;
    char err[256] = {0};
    spdf_document* doc = spdf_win_md_open_any(job->path, err, sizeof(err));
    int current;
    AcquireSRWLockExclusive(&g_lock);
    current = job->generation == g_generation;
    if (current) {
        if (g_parked) spdf_close(g_parked);
        g_parked = doc; /* NULL on a failed read: nothing to swap, the old document stays */
        strncpy_s(g_parked_path, sizeof(g_parked_path), job->path, _TRUNCATE);
    }
    ReleaseSRWLockExclusive(&g_lock);
    /* Superseded: a later begin() owns the outcome now. */
    if (!current && doc) spdf_close(doc);
    if (current && doc && job->notify) PostMessageW(job->notify, job->message, 0, 0);
    InterlockedDecrement(&g_running);
    free(job);
    return 0;
}

} // namespace

int spdf_win_md_reload_begin(const char* utf8_path, HWND notify, UINT message) {
    reload_job* job;
    HANDLE thread;
    if (!utf8_path || !*utf8_path) return 0;
    job = (reload_job*)calloc(1, sizeof(*job));
    if (!job) return 0;
    strncpy_s(job->path, sizeof(job->path), utf8_path, _TRUNCATE);
    job->notify = notify;
    job->message = message;

    AcquireSRWLockExclusive(&g_lock);
    job->generation = ++g_generation;
    /* A parked result nobody took describes a file that has changed again. */
    if (g_parked) spdf_close(g_parked);
    g_parked = NULL;
    g_parked_path[0] = 0;
    ReleaseSRWLockExclusive(&g_lock);

    InterlockedIncrement(&g_running);
    thread = CreateThread(NULL, 0, reload_thread, job, 0, NULL);
    if (!thread) {
        InterlockedDecrement(&g_running);
        free(job);
        return 0;
    }
    /* Only the newest thread is kept for shutdown to join; a superseded one
     * finishes on its own, closes its document and exits. */
    if (g_thread) CloseHandle(g_thread);
    g_thread = thread;
    return 1;
}

spdf_document* spdf_win_md_reload_take(char* path_out, size_t path_cap) {
    spdf_document* doc;
    AcquireSRWLockExclusive(&g_lock);
    doc = g_parked;
    g_parked = NULL;
    if (path_out && path_cap) strncpy_s(path_out, path_cap, doc ? g_parked_path : "", _TRUNCATE);
    g_parked_path[0] = 0;
    ReleaseSRWLockExclusive(&g_lock);
    return doc;
}

int spdf_win_md_reload_in_flight(void) {
    return InterlockedCompareExchange(&g_running, 0, 0) > 0;
}

void spdf_win_md_reload_shutdown(void) {
    spdf_document* doc;
    if (g_thread) {
        WaitForSingleObject(g_thread, INFINITE);
        CloseHandle(g_thread);
        g_thread = NULL;
    }
    doc = spdf_win_md_reload_take(NULL, 0);
    if (doc) spdf_close(doc);
}
