// One run: validate the request, prepare the work directory, spawn --sandboxed-exec, watch it, read the results back
// and delete the directory. The design and the request/result shapes are in SPDFPythonSandbox.h.
#import "SPDFPythonSandboxInternal.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <spawn.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// Memory regions the watchdog walks per check, looking for mapped files the code unlinked: about 5 µs each, measured.
static const NSUInteger kSPDFRegionsPerCheck = 512;

typedef struct {
    long long cpuSeconds, wallSeconds;
    unsigned long long memoryBytes;
} SPDFLimits;

static NSDictionary* SPDFFailure(NSString* error, NSString* message) {
    return @{@"ok" : @NO, @"error" : error, @"message" : message};
}

// Only lower: a request can make a run stricter (the suite does, to stay fast), never looser.
static long long SPDFLowered(NSDictionary* limits, NSString* key, long long ceiling) {
    id value = limits[key];
    if (![value isKindOfClass:NSNumber.class] || [value longLongValue] < 1) return ceiling;
    return MIN([value longLongValue], ceiling);
}

static double SPDFNow(void) { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9; }

static NSString* SPDFDefaultWorkParent(void) {
    char path[PATH_MAX];
    size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, path, sizeof path);
    return length > 0 && length <= sizeof path ? @(path) : NSTemporaryDirectory();
}

// Tracebacks name main.py by its full path in a temporary folder; the model and the person read "main.py".
static NSString* SPDFTidy(NSData* data, NSString* work) {
    NSString* text = SPDFPythonSandboxText(data);
    text = [text stringByReplacingOccurrencesOfString:[work stringByAppendingString:@"/"] withString:@""];
    if ([work hasPrefix:@"/private/var/"])
        text = [text stringByReplacingOccurrencesOfString:[[work substringFromIndex:8] stringByAppendingString:@"/"]
                                               withString:@""];
    return text;
}

// The spawned process and the read ends of its stdout, stderr and status pipe (-1 once closed).
enum { SPDFOut, SPDFErr, SPDFStatus };
typedef struct {
    pid_t pid;
    int fds[3];
} SPDFChild;

static BOOL SPDFSpawn(NSString* helper, NSArray<NSString*>* arguments, NSDictionary* environment, NSString* work,
                      SPDFChild* child) {
    int out[2], err[2], status[2];
    if (pipe(out) != 0) return NO;
    if (pipe(err) != 0) { close(out[0]); close(out[1]); return NO; }
    if (pipe(status) != 0) { close(out[0]); close(out[1]); close(err[0]); close(err[1]); return NO; }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, out[1], 1);
    posix_spawn_file_actions_adddup2(&actions, err[1], 2);
    posix_spawn_file_actions_adddup2(&actions, status[1], 3);
    posix_spawn_file_actions_addchdir_np(&actions, work.fileSystemRepresentation);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    // Only stdin, stdout, stderr and the status pipe reach the code: no descriptor the helper holds leaks in.
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF |
                                              POSIX_SPAWN_SETSIGMASK);
    sigset_t all, none;
    sigfillset(&all);
    sigemptyset(&none);
    posix_spawnattr_setsigdefault(&attributes, &all);
    posix_spawnattr_setsigmask(&attributes, &none);
    NSMutableArray* strings = [NSMutableArray arrayWithObject:helper];
    [strings addObjectsFromArray:arguments];
    char** argv = calloc(strings.count + 1, sizeof(char*));
    for (NSUInteger i = 0; i < strings.count; i++) argv[i] = strdup([strings[i] UTF8String]);
    NSArray* keys = [environment.allKeys sortedArrayUsingSelector:@selector(compare:)];
    char** envp = calloc(keys.count + 1, sizeof(char*));
    for (NSUInteger i = 0; i < keys.count; i++)
        envp[i] = strdup([[NSString stringWithFormat:@"%@=%@", keys[i], environment[keys[i]]] UTF8String]);
    int spawned = posix_spawn(&child->pid, helper.fileSystemRepresentation, &actions, &attributes, argv, envp);
    for (NSUInteger i = 0; argv[i]; i++) free(argv[i]);
    for (NSUInteger i = 0; envp[i]; i++) free(envp[i]);
    free(argv);
    free(envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(out[1]);
    close(err[1]);
    close(status[1]);
    if (spawned != 0) errno = spawned; // posix_spawn returns its error rather than setting errno
    child->fds[SPDFOut] = out[0];
    child->fds[SPDFErr] = err[0];
    child->fds[SPDFStatus] = status[0];
    for (int i = 0; i < 3; i++) {
        if (spawned != 0) close(child->fds[i]);
        else fcntl(child->fds[i], F_SETFL, O_NONBLOCK);
    }
    return spawned == 0;
}

typedef struct {
    NSMutableData *stdoutData, *stderrData, *statusData;
    unsigned long long produced;
    BOOL stdoutTruncated, stderrTruncated;
    NSString* limit;
    int waitStatus;
    double seconds;
} SPDFWatch;

static void SPDFDrain(int* fd, NSMutableData* keep, NSUInteger cap, BOOL* truncated, unsigned long long* produced) {
    uint8_t buffer[16384];
    for (;;) {
        ssize_t n = read(*fd, buffer, sizeof buffer);
        if (n > 0) {
            if (produced) *produced += (unsigned long long)n;
            NSUInteger room = keep.length < cap ? cap - keep.length : 0;
            [keep appendBytes:buffer length:MIN(room, (NSUInteger)n)];
            if ((NSUInteger)n > room && truncated) *truncated = YES;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n == 0) { close(*fd); *fd = -1; }
        return;
    }
}

// The watchdog: polls the pipes every 25 ms and checks each limit until the child is gone and its pipes are closed.
static void SPDFWatchChild(SPDFChild* child, SPDFLimits limits, NSString* work, unsigned long long baseline,
                           SPDFWatch* watch) {
    double start = SPDFNow();
    BOOL reaped = NO;
    double reapedAt = 0, measuredAt = 0;
    struct rusage usage = {0};
    SPDFPythonSandboxHiddenDisk* hidden = [[SPDFPythonSandboxHiddenDisk alloc] initWithPid:child->pid];
    for (;;) {
        int* fds = child->fds;
        struct pollfd polled[3] = {{fds[SPDFOut], POLLIN, 0}, {fds[SPDFErr], POLLIN, 0}, {fds[SPDFStatus], POLLIN, 0}};
        poll(polled, 3, 25);
        if (fds[SPDFOut] >= 0)
            SPDFDrain(&fds[SPDFOut], watch->stdoutData, SPDF_PYTHON_STDOUT_BYTES, &watch->stdoutTruncated,
                      &watch->produced);
        if (fds[SPDFErr] >= 0)
            SPDFDrain(&fds[SPDFErr], watch->stderrData, SPDF_PYTHON_STDERR_BYTES, &watch->stderrTruncated,
                      &watch->produced);
        if (fds[SPDFStatus] >= 0) SPDFDrain(&fds[SPDFStatus], watch->statusData, 1024, NULL, NULL);
        double now = SPDFNow();
        if (!reaped && wait4(child->pid, &watch->waitStatus, WNOHANG, &usage) == child->pid) {
            reaped = YES;
            reapedAt = now;
            watch->seconds = now - start;
        }
        if (reaped && ((fds[SPDFOut] < 0 && fds[SPDFErr] < 0 && fds[SPDFStatus] < 0) || now - reapedAt > 1)) break;
        if (reaped || watch->limit) continue;
        NSString* limit = nil;
        struct rusage_info_v4 info;
        if (spdf_python_sandbox_stop_requested) limit = @"stopped";
        else if (now - start >= (double)limits.wallSeconds) limit = @"time";
        else if (proc_pid_rusage(child->pid, RUSAGE_INFO_V4, (rusage_info_t*)&info) == 0 &&
                 info.ri_phys_footprint >= limits.memoryBytes) limit = @"memory";
        else if (watch->produced >= SPDF_PYTHON_RUNAWAY_OUTPUT_BYTES) limit = @"output";
        else if (now - measuredAt >= 0.025) {
            // Every 25 ms at most: poll returns at once while output streams, and a walk per read would be waste.
            measuredAt = now;
            unsigned long long bytes = 0;
            NSUInteger entries = 0;
            BOOL unreadable = NO;
            SPDFPythonSandboxMeasure(work, &bytes, &entries, SPDF_PYTHON_MAX_ENTRIES, &unreadable);
            // Plus the disk held by files the code unlinked while keeping them open or mapped, which the walk cannot
            // see. Python with every standard extension loaded has about 400 memory regions and each large numpy array
            // adds one; a slice per check keeps a check to a few milliseconds, however many regions the code makes.
            bytes += [hidden bytesScanningRegions:kSPDFRegionsPerCheck];
            if (unreadable || entries > SPDF_PYTHON_MAX_ENTRIES ||
                bytes > baseline + SPDF_PYTHON_OUTPUT_FILE_BYTES) limit = @"files";
        }
        if (limit) {
            watch->limit = limit;
            kill(child->pid, SIGKILL);
        }
    }
    for (int i = 0; i < 3; i++)
        if (child->fds[i] >= 0) close(child->fds[i]);
    double cpu = (double)usage.ru_utime.tv_sec + (double)usage.ru_stime.tv_sec;
    if (!watch->limit && WIFSIGNALED(watch->waitStatus) &&
        (WTERMSIG(watch->waitStatus) == SIGXCPU ||
         (WTERMSIG(watch->waitStatus) == SIGKILL && cpu >= (double)limits.cpuSeconds - 0.5)))
        watch->limit = @"cpu";
}

static NSDictionary* SPDFPrepareAndRun(NSDictionary* request, NSString* helper, NSString* interpreter,
                                       NSDictionary* paths, NSString* work) {
    NSDictionary* requestLimits = [request[@"limits"] isKindOfClass:NSDictionary.class] ? request[@"limits"] : @{};
    SPDFLimits limits = {SPDFLowered(requestLimits, @"cpu_seconds", SPDF_PYTHON_CPU_SECONDS),
                         SPDFLowered(requestLimits, @"wall_seconds", SPDF_PYTHON_WALL_SECONDS),
                         (unsigned long long)SPDFLowered(requestLimits, @"memory_mb", SPDF_PYTHON_MEMORY_BYTES >> 20)
                             << 20};
    NSMutableSet* skip = [NSMutableSet setWithObject:@"main.py"];
    NSData* code = [request[@"code"] dataUsingEncoding:NSUTF8StringEncoding];
    BOOL written = SPDFPythonSandboxWriteFile(work, @"main.py", code);
    for (NSDictionary* file in request[@"files"]) {
        NSData* text = [file[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
        written = written && SPDFPythonSandboxWriteFile(work, file[@"name"], text);
        [skip addObject:file[@"name"]];
    }
    NSString* config = [work stringByAppendingPathComponent:@".matplotlib"];
    written = written && mkdir([work stringByAppendingPathComponent:@".tmp"].fileSystemRepresentation, 0700) == 0 &&
              mkdir(config.fileSystemRepresentation, 0700) == 0;
    if (!written) return SPDFFailure(@"internal", @"Could not write the code and its files.");
    SPDFPythonSandboxSeedMatplotlib(paths[@"venv"], config);
    unsigned long long baseline = 0;
    NSUInteger entries = 0;
    SPDFPythonSandboxMeasure(work, &baseline, &entries, SPDF_PYTHON_MAX_ENTRIES, NULL);

    // -I: no PYTHON* variables, no user site-packages, no script directory on sys.path. -B: no .pyc files in the
    // work directory. -u: output reaches the pipe as it is printed, so a run stopped by a limit still shows how far
    // it got. -X utf8: text files and pipes are UTF-8 whatever the locale.
    NSArray* arguments = @[ @"--sandboxed-exec", [NSString stringWithFormat:@"%lld", limits.cpuSeconds],
                            [NSString stringWithFormat:@"%llu", SPDF_PYTHON_OUTPUT_FILE_BYTES],
                            SPDFPythonSandboxProfile(paths, work), interpreter, @"-I", @"-B", @"-u", @"-X", @"utf8",
                            @"main.py" ];
    if (spdf_python_sandbox_stop_requested)
        return @{@"ok" : @YES, @"status" : @"stopped", @"limit" : @"stopped", @"seconds" : @0, @"stdout" : @"",
                 @"stderr" : @"", @"files" : @[]};
    // Taken before the child exists, so the cleanup below leaves alone every segment that predates the run.
    NSSet<NSNumber*>* segments = SPDFPythonSandboxSharedMemoryIdentifiers();
    SPDFChild child;
    if (!SPDFSpawn(helper, arguments, SPDFPythonSandboxEnvironment(work), work, &child))
        return SPDFFailure(@"internal",
                           [NSString stringWithFormat:@"Could not start the sandbox: %s.", strerror(errno)]);
    SPDFWatch watch = {[NSMutableData data], [NSMutableData data], [NSMutableData data], 0, NO, NO, nil, 0, 0};
    SPDFWatchChild(&child, limits, work, baseline, &watch);
    // The child has exited by now (SPDFWatchChild returns only after it is reaped). macOS lets sandboxed code create
    // System V shared memory it can never use, and it outlives the run; remove the segments it created before its pid
    // is reused, so a run cannot fill the Mac's small table (SPDFPythonSandbox.h § residuals).
    SPDFPythonSandboxRemoveSharedMemory(child.pid, segments);

    if (watch.statusData.length) {
        NSString* status = SPDFPythonSandboxText(watch.statusData);
        BOOL exec = [status hasPrefix:@"exec:"];
        return SPDFFailure(exec ? @"interpreter_unavailable" : @"sandbox_unavailable",
                           [status stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    }
    NSUInteger omitted = 0;
    NSArray* files = SPDFPythonSandboxCollect(work, skip, SPDF_PYTHON_OUTPUT_FILE_BYTES, &omitted);
    NSMutableDictionary* result = [@{
        @"ok" : @YES,
        // Milliseconds as a decimal, so the JSON reads 0.068 rather than a binary double's 0.068000000000000005.
        @"seconds" : [NSDecimalNumber decimalNumberWithMantissa:(unsigned long long)llround(watch.seconds * 1000)
                                                       exponent:-3 isNegative:NO],
        @"stdout" : SPDFTidy(watch.stdoutData, work),
        @"stdout_truncated" : @(watch.stdoutTruncated),
        @"stderr" : SPDFTidy(watch.stderrData, work),
        @"stderr_truncated" : @(watch.stderrTruncated),
        @"files" : files,
        @"files_omitted" : @(omitted),
        @"limits" : @{@"cpu_seconds" : @(limits.cpuSeconds), @"wall_seconds" : @(limits.wallSeconds),
                      @"memory_mb" : @(limits.memoryBytes >> 20), @"stdout_bytes" : @(SPDF_PYTHON_STDOUT_BYTES),
                      @"output_bytes" : @(SPDF_PYTHON_OUTPUT_FILE_BYTES)},
    } mutableCopy];
    if (WIFEXITED(watch.waitStatus)) result[@"exit_code"] = @(WEXITSTATUS(watch.waitStatus));
    if (WIFSIGNALED(watch.waitStatus)) result[@"signal"] = @(WTERMSIG(watch.waitStatus));
    if (watch.limit) result[@"limit"] = watch.limit;
    BOOL clean = !watch.limit && WIFEXITED(watch.waitStatus) && WEXITSTATUS(watch.waitStatus) == 0;
    result[@"status"] = [watch.limit isEqual:@"stopped"] ? @"stopped" : clean ? @"completed" : @"failed";
    return result;
}

static NSString* SPDFRequestProblem(NSDictionary* request) {
    if (![request[@"interpreter"] isKindOfClass:NSString.class]) return @"interpreter must be a path.";
    if (![request[@"code"] isKindOfClass:NSString.class] || ![request[@"code"] length]) return @"code is required.";
    id files = request[@"files"];
    if (files && (![files isKindOfClass:NSArray.class] || [files count] > SPDF_PYTHON_MAX_INPUTS))
        return @"files must be a list of at most 16 files.";
    NSMutableSet* names = [NSMutableSet set];
    for (id file in files) {
        if (![file isKindOfClass:NSDictionary.class] || !SPDFPythonSandboxValidInputName(file[@"name"]) ||
            ![file[@"text"] isKindOfClass:NSString.class] || [names containsObject:file[@"name"]])
            return @"Each file needs a unique plain name (letters, digits, dot, dash, underscore, space) and text.";
        [names addObject:file[@"name"]];
    }
    id parent = request[@"work_parent"];
    if (parent && (![parent isKindOfClass:NSString.class] || ![parent hasPrefix:@"/"]))
        return @"work_parent must be an absolute path.";
    return nil;
}

NSDictionary<NSString*, id>* SPDFPythonSandboxRun(NSDictionary<NSString*, id>* request, NSString* helperPath) {
    NSString* problem = SPDFRequestProblem(request);
    if (problem) return SPDFFailure(@"bad_request", problem);
    NSString* reason = nil;
    NSDictionary* paths = SPDFPythonSandboxPathsForInterpreter(request[@"interpreter"], &reason);
    if (!paths) return SPDFFailure(@"interpreter_unavailable", reason);
    NSString* parent = request[@"work_parent"] ?: SPDFDefaultWorkParent();
    SPDFPythonSandboxSweepStale(parent);
    NSString* work = SPDFPythonSandboxMakeWorkDirectory(parent, &reason);
    if (!work) return SPDFFailure(@"internal", reason);
    NSDictionary* result = SPDFPrepareAndRun(request, helperPath, request[@"interpreter"], paths, work);
    if (!SPDFPythonSandboxRemoveTree(work) && [result[@"ok"] boolValue]) {
        NSMutableDictionary* noted = [result mutableCopy];
        noted[@"cleanup_failed"] = @YES;
        result = noted;
    }
    return result;
}
