/* Shenzhen Friends client library: connect-or-spawn (ADR 0002).
 *
 * posix_spawn with POSIX_SPAWN_SETSID, so the helper leaves the app's process group and session and outlives the
 * app, and POSIX_SPAWN_CLOEXEC_DEFAULT, so it inherits none of the app's descriptors (a held lock or pipe would
 * otherwise stay open as long as the helper runs). A detached thread reaps each child; it touches nothing but its
 * own copy of the pid, so a helper that exits never lingers as a zombie of a long-running reader. */

#define _DARWIN_C_SOURCE 1 /* pthread_main_np, POSIX_SPAWN_SETSID, POSIX_SPAWN_CLOEXEC_DEFAULT */

#include "client/szfriends_client.h"
#include "client/szfriends_client_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/* The environment the helper starts with: ours, with SZFRIENDS_STATE_DIR replaced when the caller names a state
 * directory. Returns a NULL-terminated array whose strings belong to `environ` except the one override. */
static char **helper_environment(const char *state_dir, char **override_out) {
    size_t count = 0, i, n = 0;
    size_t key_length = strlen(SZFRIENDS_ENV_STATE_DIR);
    char **envp;
    *override_out = NULL;
    while (environ && environ[count]) count++;
    envp = (char **)calloc(count + 2, sizeof *envp);
    if (!envp) return NULL;
    for (i = 0; i < count; i++) {
        if (state_dir && strncmp(environ[i], SZFRIENDS_ENV_STATE_DIR, key_length) == 0 &&
            environ[i][key_length] == '=')
            continue;
        envp[n++] = environ[i];
    }
    if (state_dir) {
        size_t length = key_length + 1 + strlen(state_dir) + 1;
        char *entry = (char *)malloc(length);
        if (!entry) {
            free(envp);
            return NULL;
        }
        snprintf(entry, length, "%s=%s", SZFRIENDS_ENV_STATE_DIR, state_dir);
        envp[n++] = entry;
        *override_out = entry;
    }
    envp[n] = NULL;
    return envp;
}

szfriends_status szfriends_spawn_process(const char *helper_path, const char *state_dir, pid_t *pid_out) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    sigset_t signals;
    char *argv[2];
    char **envp;
    char *override = NULL;
    pid_t pid = 0;
    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
    int error;

    if (pid_out) *pid_out = 0;
    if (!helper_path || !helper_path[0]) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    envp = helper_environment(state_dir, &override);
    if (!envp) return SZFRIENDS_ERR_NO_MEMORY;

    if (posix_spawn_file_actions_init(&actions) != 0) {
        free(override);
        free(envp);
        return SZFRIENDS_ERR_NO_MEMORY;
    }
    /* With CLOEXEC_DEFAULT only descriptors named here survive; all three standard ones go to /dev/null. */
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_init(&attributes);
#ifdef POSIX_SPAWN_SETSID
    flags |= POSIX_SPAWN_SETSID;
#endif
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    posix_spawnattr_setflags(&attributes, flags);
    sigemptyset(&signals);
    posix_spawnattr_setsigmask(&attributes, &signals);
    /* Ignored signals survive exec; an app that ignores SIGPIPE or SIGTERM must not pass that on. */
    sigaddset(&signals, SIGPIPE);
    sigaddset(&signals, SIGTERM);
    sigaddset(&signals, SIGINT);
    sigaddset(&signals, SIGHUP);
    sigaddset(&signals, SIGQUIT);
    sigaddset(&signals, SIGCHLD);
    sigaddset(&signals, SIGUSR1);
    sigaddset(&signals, SIGUSR2);
    sigaddset(&signals, SIGALRM);
    posix_spawnattr_setsigdefault(&attributes, &signals);

    argv[0] = (char *)helper_path;
    argv[1] = NULL;
    error = posix_spawn(&pid, helper_path, &actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    free(override);
    free(envp);
    if (error != 0) {
        errno = error;
        return SZFRIENDS_ERR_IO;
    }
    if (pid_out) *pid_out = pid;
    return SZFRIENDS_OK;
}

static void *reap_child(void *argument) {
    pid_t pid = (pid_t)(intptr_t)argument;
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    return NULL;
}

static void start_reaper(pid_t pid) {
    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    /* If no thread can be made the child is reaped by nobody until the app exits; nothing better is possible
     * without installing a SIGCHLD handler, which a library must not do behind its host's back. */
    pthread_create(&thread, &attributes, reap_child, (void *)(intptr_t)pid);
    pthread_attr_destroy(&attributes);
}

/* One connect attempt on the socket, without waiting. OK when a helper of ours answered. */
szfriends_status szfriends_probe_socket(const char *socket_path) {
    struct sockaddr_un address;
    int fd;
    szfriends_status status = szfriends_socket_directory_check(socket_path, false);
    if (status != SZFRIENDS_OK) return status;
    fd = szfriends_socket_open_connected(socket_path, &address, &status);
    if (fd < 0) return status;
    close(fd);
    return SZFRIENDS_OK;
}

szfriends_status szfriends_spawn_helper(const char *helper_path, const char *state_dir, pid_t *pid_out) {
    char state[SZFRIENDS_PATH_CAP];
    char socket_path[SZFRIENDS_PATH_CAP];
    szfriends_status status;
    pid_t pid = 0;

    if (pid_out) *pid_out = 0;
    if (!helper_path || !helper_path[0]) return SZFRIENDS_ERR_INVALID_ARGUMENT;
#if defined(__APPLE__)
    if (pthread_main_np()) return SZFRIENDS_ERR_INVALID_ARGUMENT;
#endif
    if (state_dir) {
        if (strlen(state_dir) >= sizeof state) return SZFRIENDS_ERR_PATH_TOO_LONG;
        memcpy(state, state_dir, strlen(state_dir) + 1);
    } else {
        status = szfriends_default_state_dir(state, sizeof state);
        if (status != SZFRIENDS_OK) return status;
    }
    status = szfriends_socket_path(state, socket_path, sizeof socket_path, NULL);
    if (status != SZFRIENDS_OK) return status;

    status = szfriends_probe_socket(socket_path);
    if (status == SZFRIENDS_OK) return SZFRIENDS_OK; /* a helper answered: spawn nothing */
    /* A listener another team signed gets one chance to be replaced at launch: our helper takes the lock and the
     * path if the listener does not hold them, and exits at once if it does. The client never spawns for it again,
     * so a squatter costs one process per launch, never a loop. */
    if (status != SZFRIENDS_ERR_NO_HELPER && status != SZFRIENDS_ERR_PEER_SIGNATURE)
        return status; /* unsafe directory, another user's helper... */

    status = szfriends_spawn_process(helper_path, state_dir, &pid);
    if (status != SZFRIENDS_OK) return status;
    start_reaper(pid);
    if (pid_out) *pid_out = pid;
    return SZFRIENDS_OK;
}

typedef struct spawn_job {
    char *helper_path;
    char *state_dir;
} spawn_job;

/* Spawns and then reaps on one detached thread: the caller's thread (often the host's main thread) never runs
 * posix_spawn, and the job owns copies of its strings so it shares nothing with the client. */
static void *spawn_and_reap(void *argument) {
    spawn_job *job = (spawn_job *)argument;
    pid_t pid = 0;
    if (szfriends_spawn_process(job->helper_path, job->state_dir, &pid) == SZFRIENDS_OK) {
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
    }
    free(job->helper_path);
    free(job->state_dir);
    free(job);
    return NULL;
}

szfriends_status szfriends_spawn_detached(const char *helper_path, const char *state_dir) {
    pthread_t thread;
    pthread_attr_t attributes;
    spawn_job *job;
    int error;

    if (!helper_path || !helper_path[0]) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    job = (spawn_job *)calloc(1, sizeof *job);
    if (!job) return SZFRIENDS_ERR_NO_MEMORY;
    job->helper_path = strdup(helper_path);
    job->state_dir = state_dir ? strdup(state_dir) : NULL;
    if (!job->helper_path || (state_dir && !job->state_dir)) {
        free(job->helper_path);
        free(job->state_dir);
        free(job);
        return SZFRIENDS_ERR_NO_MEMORY;
    }
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    error = pthread_create(&thread, &attributes, spawn_and_reap, job);
    pthread_attr_destroy(&attributes);
    if (error != 0) {
        free(job->helper_path);
        free(job->state_dir);
        free(job);
        errno = error;
        return SZFRIENDS_ERR_IO;
    }
    return SZFRIENDS_OK;
}
