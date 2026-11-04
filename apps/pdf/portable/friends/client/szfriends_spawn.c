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
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#endif

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
    fd = szfriends_socket_open_connected(socket_path, &address, &status, NULL);
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

#if defined(__APPLE__)
static const char *last_component(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

/* The path `pid` was started from (KERN_PROCARGS2: argc, then the exec path). proc_pidpath() fails for a process
 * whose bundle was since moved or deleted, as an updater test's replaced copy is; that path still says what it is. */
static bool started_from(pid_t pid, char *path, size_t size) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, (int)pid}, argmax_mib[2] = {CTL_KERN, KERN_ARGMAX}, argmax = 0;
    size_t length = sizeof argmax, used;
    char *buffer;
    bool found = false;
    if (sysctl(argmax_mib, 2, &argmax, &length, NULL, 0) != 0 || argmax <= (int)sizeof(int)) return false;
    buffer = (char *)malloc((size_t)argmax);
    if (!buffer) return false;
    length = (size_t)argmax;
    if (sysctl(mib, 3, buffer, &length, NULL, 0) == 0 && length > sizeof(int)) {
        used = strnlen(buffer + sizeof(int), length - sizeof(int));
        if (used > 0 && used < size && sizeof(int) + used < length && buffer[sizeof(int)] == '/') {
            memcpy(path, buffer + sizeof(int), used);
            path[used] = '\0';
            found = true;
        }
    }
    free(buffer);
    return found;
}

/* In /Applications or ~/Applications: where an app the person installed runs from. A test copy, a build in its
 * folder or an app opened from a disk image runs from anywhere else. */
static bool runs_installed(const char *path) {
    struct passwd *user;
    size_t length;
    if (strncmp(path, "/Applications/", 14) == 0) return true;
    user = getpwuid(geteuid());
    if (!user || !user->pw_dir || !user->pw_dir[0]) return false;
    length = strlen(user->pw_dir);
    return strncmp(path, user->pw_dir, length) == 0 && strncmp(path + length, "/Applications/", 14) == 0;
}

/* Whether `pid` runs code that is no longer on disk where it runs from: the file was deleted (an updater moved the
 * old app aside and then removed it) or another file now has its name. No installed app carries that helper any
 * more, and a team-signed app's signature check of it fails (the Security framework reads the code from that path),
 * so it can never serve that app again. */
static bool runs_vanished_code(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    struct proc_regionwithpathinfo region;
    struct stat now;
    uint64_t address = 0;
    int i;
    errno = 0;
    /* The kernel follows the file through renames and fails with ENOENT once it has no name left. */
    if (proc_pidpath(pid, path, sizeof path) <= 0) return errno == ENOENT;
    if (stat(path, &now) != 0) return errno == ENOENT;
    /* The mapping of the main executable carries the file it was loaded from; the first regions are its own. */
    for (i = 0; i < 16; i++) {
        memset(&region, 0, sizeof region);
        if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, (int)sizeof region) <= 0) return false;
        if (strcmp(region.prp_vip.vip_path, path) == 0)
            return (uint64_t)region.prp_vip.vip_vi.vi_stat.vst_ino != (uint64_t)now.st_ino ||
                   (dev_t)region.prp_vip.vip_vi.vi_stat.vst_dev != now.st_dev;
        if (region.prp_prinfo.pri_size == 0) return false;
        address = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size;
    }
    return false;
}

/* The build `pid` recorded in <state dir>/helper.lock when it took the lock ("<pid> <build>\n"), or 0: helpers
 * before 26110402 record nothing, and a record of another process says nothing about this one. */
static uint64_t recorded_build(const char *state_dir, pid_t pid) {
    char state[SZFRIENDS_PATH_CAP], path[SZFRIENDS_PATH_CAP + 16], text[64];
    unsigned long long build = 0;
    int fd, owner = 0;
    ssize_t length;
    if (state_dir && state_dir[0]) {
        if (strlen(state_dir) >= sizeof state) return 0;
        memcpy(state, state_dir, strlen(state_dir) + 1);
    } else if (szfriends_default_state_dir(state, sizeof state) != SZFRIENDS_OK) {
        return 0;
    }
    snprintf(path, sizeof path, "%s/helper.lock", state);
    fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return 0;
    length = read(fd, text, sizeof text - 1);
    close(fd);
    if (length <= 0) return 0;
    text[length] = '\0';
    if (sscanf(text, "%d %llu", &owner, &build) != 2 || owner != pid) return 0;
    return (uint64_t)build;
}
#endif

bool szfriends_helper_may_be_ended(const char *own_helper_path, const char *state_dir, uint64_t own_build, pid_t pid,
                                   bool refused) {
#if defined(__APPLE__)
    char path[PROC_PIDPATHINFO_MAXSIZE];
    struct proc_bsdshortinfo info;
    bool own_installed, peer_installed;
    if (!own_helper_path || !own_helper_path[0] || pid <= 1 || pid == getpid()) return false;
    if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, (int)sizeof info) != (int)sizeof info ||
        info.pbsi_uid != geteuid())
        return false;
    if (proc_pidpath(pid, path, sizeof path) <= 0 && !started_from(pid, path, sizeof path)) return false;
    if (strcmp(last_component(path), last_component(own_helper_path)) != 0) return false;
    /* A helper whose app an update deleted or replaced. Where it started from (/Applications, say) no longer says
     * anything about it, so the installed-app rule below would protect it for as long as it runs and Friends would
     * wait on "Starting Friends…" forever. Ended unless it recorded a build newer than ours: a newer one steps aside
     * by itself (it watches its own executable), and we wait for that instead. */
    if (runs_vanished_code(pid)) {
        uint64_t build = recorded_build(state_dir, pid);
        if (build == 0 || (own_build != 0 && build <= own_build)) return true;
    }
    own_installed = runs_installed(own_helper_path);
    peer_installed = runs_installed(path);
    return refused ? own_installed && !peer_installed : own_installed || !peer_installed;
#else
    (void)own_helper_path;
    (void)state_dir;
    (void)own_build;
    (void)pid;
    (void)refused;
    return false;
#endif
}

void szfriends_end_helper(pid_t pid, bool now) {
    if (pid > 1 && pid != getpid()) kill(pid, now ? SIGKILL : SIGTERM);
}
