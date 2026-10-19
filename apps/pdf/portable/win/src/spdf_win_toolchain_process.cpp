/* spdf_win_toolchain_process.cpp -- THE SUBPROCESS SEAM of spdf_win_toolchain.h:
 * CreateProcessW with pipes, a job object so a cancel kills the whole tree,
 * stdout and stderr read by their own threads and fed to the caller's line
 * callback on the calling thread, stdin written by a third, and the inherited
 * environment with the caller's PATH prefix and Python's UTF-8 switches.
 * Every power tool goes through spdf_win_toolchain_run_capture(); the fake
 * tesseract.cmd in portable/win/tests/toolchain_run_test.c drives it. Split
 * from spdf_win_toolchain_run.cpp at the 500-line cap. */
#include "spdf_win_toolchain.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int to_wide(const char* utf8, wchar_t* out, int cap) {
    return utf8 && MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, cap) > 0;
}

static wchar_t* wide_dup(const char* utf8) {
    int need = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    wchar_t* w = need > 0 ? (wchar_t*)malloc(sizeof(wchar_t) * (size_t)need) : NULL;
    if (w && MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, need) <= 0) {
        free(w);
        w = NULL;
    }
    return w;
}

/* --- the subprocess seam ---------------------------------------------------- */

typedef struct pipe_reader {
    HANDLE pipe;
    HANDLE event; /* set when new bytes are queued */
    CRITICAL_SECTION lock;
    char* data;
    size_t len, cap, taken;
} pipe_reader;

static DWORD WINAPI pipe_reader_main(LPVOID param) {
    pipe_reader* r = (pipe_reader*)param;
    char chunk[8192];
    DWORD got;
    while (ReadFile(r->pipe, chunk, sizeof(chunk), &got, NULL) && got > 0) {
        EnterCriticalSection(&r->lock);
        if (r->len + got + 1 > r->cap) {
            size_t ncap = (r->cap ? r->cap * 2 : 16384);
            while (ncap < r->len + got + 1) ncap *= 2;
            r->data = (char*)realloc(r->data, ncap);
            r->cap = ncap;
        }
        if (r->data) {
            memcpy(r->data + r->len, chunk, got);
            r->len += got;
            r->data[r->len] = '\0';
        }
        LeaveCriticalSection(&r->lock);
        SetEvent(r->event);
    }
    SetEvent(r->event);
    return 0;
}

/* Feed whatever arrived since last time to the splitter, on this thread. */
static void pipe_reader_drain(pipe_reader* r, SpdfWinLineSplitter* s, spdf_win_toolchain_line_fn cb, void* user) {
    EnterCriticalSection(&r->lock);
    if (r->data && r->len > r->taken) {
        spdf_win_line_splitter_feed(s, r->data + r->taken, r->len - r->taken, cb, user);
        r->taken = r->len;
    }
    LeaveCriticalSection(&r->lock);
}

typedef struct stdin_writer {
    HANDLE pipe;
    const char* text;
} stdin_writer;

static DWORD WINAPI stdin_writer_main(LPVOID param) {
    stdin_writer* w = (stdin_writer*)param;
    const char* p = w->text;
    size_t left = strlen(p);
    DWORD wrote;
    while (left > 0 && WriteFile(w->pipe, p, (DWORD)(left > 65536 ? 65536 : left), &wrote, NULL)) {
        p += wrote;
        left -= wrote;
    }
    CloseHandle(w->pipe);
    return 0;
}

/* The inherited environment with the caller's "NAME=value" pairs applied --
 * PATH entries PREPENDED, everything else replaced -- plus the three Python
 * variables that make its console scripts speak UTF-8 through a pipe. */
static wchar_t* build_environment(const char* prepend) {
    static const char* const forced[] = {"PYTHONUTF8=1", "PYTHONIOENCODING=utf-8", "PYTHONUNBUFFERED=1", NULL};
    wchar_t* inherited = GetEnvironmentStringsW();
    size_t total = 0, at = 0;
    wchar_t* block;
    char path_prefix[SPDF_WIN_TC_ENV] = "";
    const char* p;
    int i;

    if (!inherited) return NULL;
    /* Collect PATH prefixes and measure. */
    for (p = prepend; p && *p; p += strlen(p) + 1) {
        if (_strnicmp(p, "PATH=", 5) == 0) {
            size_t n = strlen(path_prefix);
            snprintf(path_prefix + n, sizeof(path_prefix) - n, "%s;", p + 5);
        }
        total += strlen(p) + 1;
    }
    for (i = 0; forced[i]; ++i) total += strlen(forced[i]) + 1;
    for (const wchar_t* w = inherited; *w; w += wcslen(w) + 1) total += wcslen(w) + 1;
    total += strlen(path_prefix) + 2;
    block = (wchar_t*)calloc(total + 1, sizeof(wchar_t));
    if (!block) {
        FreeEnvironmentStringsW(inherited);
        return NULL;
    }
    for (const wchar_t* w = inherited; *w; w += wcslen(w) + 1) {
        int replaced = 0;
        wchar_t name[256];
        const wchar_t* eq = wcschr(w, L'=');
        size_t nlen = eq ? (size_t)(eq - w) : 0;
        if (nlen == 0 || nlen >= 255) continue; /* the "=C:=..." drive entries */
        memcpy(name, w, nlen * sizeof(wchar_t));
        name[nlen] = 0;
        for (p = prepend; p && *p && !replaced; p += strlen(p) + 1) {
            wchar_t wp[SPDF_WIN_TC_ENV];
            const wchar_t* peq;
            if (!to_wide(p, wp, SPDF_WIN_TC_ENV)) continue;
            peq = wcschr(wp, L'=');
            if (peq && (size_t)(peq - wp) == nlen && _wcsnicmp(wp, name, nlen) == 0 && _wcsicmp(name, L"PATH") != 0)
                replaced = 1;
        }
        for (i = 0; forced[i] && !replaced; ++i) {
            wchar_t wf[64];
            to_wide(forced[i], wf, 64);
            if (_wcsnicmp(wf, name, nlen) == 0 && wf[nlen] == L'=') replaced = 1;
        }
        if (replaced) continue;
        if (_wcsicmp(name, L"PATH") == 0 && path_prefix[0]) {
            wchar_t wprefix[SPDF_WIN_TC_ENV];
            to_wide(path_prefix, wprefix, SPDF_WIN_TC_ENV);
            wcscpy(block + at, L"PATH=");
            at += 5;
            wcscpy(block + at, wprefix);
            at += wcslen(wprefix);
            wcscpy(block + at, eq + 1);
            at += wcslen(eq + 1) + 1;
            continue;
        }
        wcscpy(block + at, w);
        at += wcslen(w) + 1;
    }
    for (p = prepend; p && *p; p += strlen(p) + 1) {
        if (_strnicmp(p, "PATH=", 5) == 0) continue;
        to_wide(p, block + at, (int)(total - at));
        at += wcslen(block + at) + 1;
    }
    for (i = 0; forced[i]; ++i) {
        to_wide(forced[i], block + at, (int)(total - at));
        at += wcslen(block + at) + 1;
    }
    block[at] = 0;
    FreeEnvironmentStringsW(inherited);
    return block;
}

static void reader_start(pipe_reader* r, HANDLE pipe, HANDLE* thread) {
    memset(r, 0, sizeof(*r));
    r->pipe = pipe;
    r->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    InitializeCriticalSection(&r->lock);
    *thread = CreateThread(NULL, 0, pipe_reader_main, r, 0, NULL);
}

static void reader_finish(pipe_reader* r, HANDLE thread, char** out) {
    if (thread) {
        WaitForSingleObject(thread, 5000);
        CloseHandle(thread);
    }
    CloseHandle(r->pipe);
    CloseHandle(r->event);
    DeleteCriticalSection(&r->lock);
    if (out) *out = r->data ? r->data : _strdup("");
    else free(r->data);
}

int spdf_win_toolchain_run_capture(SpdfWinToolchainRun* run) {
    SECURITY_ATTRIBUTES sa = {sizeof(sa), NULL, TRUE};
    HANDLE out_r = NULL, out_w = NULL, err_r = NULL, err_w = NULL, in_r = NULL, in_w = NULL;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    HANDLE job;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    wchar_t* cmd;
    wchar_t* env;
    pipe_reader out_reader, err_reader;
    HANDLE out_thread = NULL, err_thread = NULL, in_thread = NULL;
    SpdfWinLineSplitter out_split, err_split;
    stdin_writer writer;
    int rc = SPDF_WIN_TC_SPAWN_FAILED;
    int cancelled = 0;

    if (!run || !run->command_line) return SPDF_WIN_TC_SPAWN_FAILED;
    run->error[0] = '\0';
    if (run->stdout_out) *run->stdout_out = NULL;
    if (run->stderr_out) *run->stderr_out = NULL;

    if (!CreatePipe(&out_r, &out_w, &sa, 0) || !SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0)) goto pipe_fail;
    if (run->merge_stderr) {
        if (!DuplicateHandle(GetCurrentProcess(), out_w, GetCurrentProcess(), &err_w, 0, TRUE,
                             DUPLICATE_SAME_ACCESS))
            goto pipe_fail;
    } else if (!CreatePipe(&err_r, &err_w, &sa, 0) || !SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0)) {
        goto pipe_fail;
    }
    if (!CreatePipe(&in_r, &in_w, &sa, 0) || !SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0)) goto pipe_fail;

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r;
    si.hStdOutput = out_w;
    si.hStdError = err_w;
    memset(&pi, 0, sizeof(pi));
    cmd = wide_dup(run->command_line);
    env = build_environment(run->env_prepend);
    if (!cmd || !env) {
        snprintf(run->error, sizeof(run->error), "out of memory");
        free(cmd);
        free(env);
        goto pipe_fail;
    }
    job = CreateJobObjectW(NULL, NULL);
    if (job) {
        memset(&limits, 0, sizeof(limits));
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    }
    if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                        env, NULL, &si, &pi)) {
        DWORD err = GetLastError();
        snprintf(run->error, sizeof(run->error), "CreateProcess failed (%lu)", (unsigned long)err);
        free(cmd);
        free(env);
        if (job) CloseHandle(job);
        goto pipe_fail;
    }
    free(cmd);
    free(env);
    if (job) AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    /* The child's ends, or the readers never see EOF. */
    CloseHandle(out_w);
    CloseHandle(err_w);
    CloseHandle(in_r);
    out_w = err_w = in_r = NULL;

    reader_start(&out_reader, out_r, &out_thread);
    if (err_r) reader_start(&err_reader, err_r, &err_thread);
    spdf_win_line_splitter_init(&out_split);
    spdf_win_line_splitter_init(&err_split);
    if (run->stdin_text) {
        writer.pipe = in_w;
        writer.text = run->stdin_text;
        in_thread = CreateThread(NULL, 0, stdin_writer_main, &writer, 0, NULL);
        if (!in_thread) CloseHandle(in_w);
    } else {
        CloseHandle(in_w);
    }
    in_w = NULL;

    for (;;) {
        HANDLE waits[4];
        DWORD n = 0, which;
        waits[n++] = pi.hProcess;
        waits[n++] = out_reader.event;
        if (err_r) waits[n++] = err_reader.event;
        if (run->cancel) waits[n++] = (HANDLE)run->cancel;
        which = WaitForMultipleObjects(n, waits, FALSE, INFINITE);
        pipe_reader_drain(&out_reader, &out_split, run->on_line, run->user);
        if (err_r && run->merge_stderr == 0)
            pipe_reader_drain(&err_reader, &err_split, run->on_line ? run->on_line : NULL, run->user);
        if (which == WAIT_OBJECT_0) break;
        if (run->cancel && which == WAIT_OBJECT_0 + n - 1) {
            cancelled = 1;
            if (job) TerminateJobObject(job, 1);
            else TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 5000);
            break;
        }
    }
    if (in_thread) {
        WaitForSingleObject(in_thread, 2000);
        CloseHandle(in_thread);
    }
    reader_finish(&out_reader, out_thread, run->stdout_out);
    if (err_r) reader_finish(&err_reader, err_thread, run->stderr_out);
    /* Lines that arrived between the last drain and EOF. */
    if (run->stdout_out && *run->stdout_out && out_reader.taken < strlen(*run->stdout_out))
        spdf_win_line_splitter_feed(&out_split, *run->stdout_out + out_reader.taken,
                                    strlen(*run->stdout_out) - out_reader.taken, run->on_line, run->user);
    spdf_win_line_splitter_flush(&out_split, run->on_line, run->user);
    spdf_win_line_splitter_flush(&err_split, run->on_line, run->user);
    {
        DWORD code = 1;
        GetExitCodeProcess(pi.hProcess, &code);
        rc = cancelled ? SPDF_WIN_TC_CANCELLED : (int)code;
    }
    CloseHandle(pi.hProcess);
    if (job) CloseHandle(job);
    return rc;

pipe_fail:
    if (!run->error[0]) snprintf(run->error, sizeof(run->error), "could not create pipes (%lu)", (unsigned long)GetLastError());
    if (out_r) CloseHandle(out_r);
    if (out_w) CloseHandle(out_w);
    if (err_r) CloseHandle(err_r);
    if (err_w) CloseHandle(err_w);
    if (in_r) CloseHandle(in_r);
    if (in_w) CloseHandle(in_w);
    return SPDF_WIN_TC_SPAWN_FAILED;
}

