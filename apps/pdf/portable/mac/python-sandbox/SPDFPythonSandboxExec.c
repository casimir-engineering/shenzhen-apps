// --sandboxed-exec: the only code that runs between the helper and the interpreter. It is a separate process image
// (the helper spawns itself) so that nothing here runs after a fork of a process with Foundation threads, and it is
// plain C so the path to exec is short enough to read in one sitting. See SPDFPythonSandbox.h for the whole design.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sandbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

#include "SPDFPythonSandbox.h"

volatile sig_atomic_t spdf_python_sandbox_stop_requested = 0;

// fd 3 is the status pipe the helper reads: anything written there means the interpreter never started. It is closed
// on exec, so a clean start reads as an empty pipe. Stderr gets the same line for someone running this by hand.
static void spdf_report(const char* stage, const char* detail) {
    char line[512];
    int length = snprintf(line, sizeof line, "%s: %s\n", stage, detail ? detail : "");
    if (length < 0) return;
    if ((size_t)length >= sizeof line) length = (int)sizeof line - 1;
    (void)!write(3, line, (size_t)length);
    (void)!write(2, line, (size_t)length);
}

static __attribute__((noreturn)) void spdf_refuse(const char* stage, const char* detail) {
    spdf_report(stage, detail);
    _exit(SPDF_PYTHON_EXIT_REFUSED);
}

// Strict: a whole decimal number in [1, max]; anything else refuses the run rather than guessing a limit.
static long long spdf_parse_limit(const char* text, long long max) {
    if (!text || !*text) return -1;
    char* end = NULL;
    errno = 0;
    long long value = strtoll(text, &end, 10);
    if (errno || !end || *end || value < 1 || value > max) return -1;
    return value;
}

static void spdf_limit(int resource, rlim_t soft, rlim_t hard, const char* name) {
    struct rlimit limit = {soft, hard};
    if (setrlimit(resource, &limit) != 0) spdf_refuse("limits", name);
}

int spdf_python_sandbox_exec(int argc, char** argv, char** envp) {
    if (argc < 6) spdf_refuse("usage", "--sandboxed-exec <cpu seconds> <file bytes> <profile> <interpreter> [args]");
    long long cpu = spdf_parse_limit(argv[2], SPDF_PYTHON_CPU_SECONDS);
    long long fileBytes = spdf_parse_limit(argv[3], (long long)SPDF_PYTHON_OUTPUT_FILE_BYTES);
    if (cpu < 0 || fileBytes < 0) spdf_refuse("limits", "invalid limit");
    const char* profile = argv[4];
    char** command = argv + 5;
    if (command[0][0] != '/') spdf_refuse("exec", "the interpreter path is not absolute");

    // Inside the kernel, so they hold even if the watchdog outside were gone: SIGXCPU at the soft CPU limit and
    // SIGKILL a second later; EFBIG for a file beyond the output cap (Python ignores SIGXFSZ, so the code sees an
    // OSError); no core file; and one process, so a fork fails even before the profile's own rule.
    spdf_limit(RLIMIT_CPU, (rlim_t)cpu, (rlim_t)cpu + 1, "cpu");
    spdf_limit(RLIMIT_FSIZE, (rlim_t)fileBytes, (rlim_t)fileBytes, "file size");
    spdf_limit(RLIMIT_NOFILE, SPDF_PYTHON_OPEN_FILES, SPDF_PYTHON_OPEN_FILES, "open files");
    spdf_limit(RLIMIT_CORE, 0, 0, "core");
    spdf_limit(RLIMIT_NPROC, 1, 1, "processes");

    // sandbox_init is deprecated as an API for apps to sandbox themselves, which is not this use: it is still how a
    // process applies an SBPL profile to itself and everything it execs, on every macOS this app supports (12+).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    char* error = NULL;
    if (sandbox_init(profile, 0, &error) != 0) {
        char detail[256];
        snprintf(detail, sizeof detail, "%s", error ? error : "the profile was rejected");
        if (error) sandbox_free_error(error);
        spdf_refuse("sandbox", detail);
    }
#pragma clang diagnostic pop

    // Trust, but check: a profile that applied yet still reaches the network or the person's folders is not the
    // profile we meant, so the code does not run. Creating a socket is not itself a network operation to the
    // sandbox; connecting is. A UDP connect to loopback sends nothing, so even a failed sandbox leaks no packet.
    int probe = socket(AF_INET, SOCK_DGRAM, 0);
    if (probe >= 0) {
        struct sockaddr_in loopback;
        memset(&loopback, 0, sizeof loopback);
        loopback.sin_len = sizeof loopback;
        loopback.sin_family = AF_INET;
        loopback.sin_port = htons(9);
        loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int connected = connect(probe, (struct sockaddr*)&loopback, sizeof loopback);
        int reason = errno;
        close(probe);
        if (connected == 0 || reason != EPERM)
            spdf_refuse("sandbox", "the profile applied but did not block the network");
    }
    int folder = open("/Users", O_RDONLY | O_DIRECTORY);
    if (folder >= 0 || errno != EPERM) {
        if (folder >= 0) close(folder);
        spdf_refuse("sandbox", "the profile applied but did not block reading other folders");
    }

    if (fcntl(3, F_SETFD, FD_CLOEXEC) != 0 && errno != EBADF) spdf_refuse("exec", "status pipe");
    execve(command[0], command, envp);
    spdf_report("exec", strerror(errno));
    _exit(SPDF_PYTHON_EXIT_EXEC_FAILED);
}
