// spdf-python-sandbox: one JSON request on stdin, one JSON result on stdout (SPDFPythonSandbox.h). The app embeds it
// in Contents/Helpers and runs it once per run_python call.
#import "SPDFPythonSandbox.h"

#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void SPDFStopRequested(int signal) {
    (void)signal;
    spdf_python_sandbox_stop_requested = 1;
}

static NSString* SPDFOwnPath(void) {
    char path[PATH_MAX], resolved[PATH_MAX];
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0 || !realpath(path, resolved)) return nil;
    return @(resolved);
}

static void SPDFWriteAll(int fd, NSData* data) {
    const uint8_t* bytes = data.bytes;
    size_t left = data.length;
    while (left) {
        ssize_t written = write(fd, bytes, left);
        if (written <= 0) return; // the app went away; the run is over either way
        bytes += written;
        left -= (size_t)written;
    }
}

int main(int argc, char** argv, char** envp) {
    // First, before Foundation exists in this process: the sandboxed process image (SPDFPythonSandboxExec.c).
    if (argc >= 2 && strcmp(argv[1], "--sandboxed-exec") == 0) spdf_python_sandbox_exec(argc, argv, envp);
    @autoreleasepool {
        // Its own process group, so the app's last resort (killpg after Stop goes unanswered) also ends the code.
        setpgid(0, 0);
        // The app may stop reading; a write must fail quietly so the work directory is still deleted.
        signal(SIGPIPE, SIG_IGN);
        struct sigaction stop;
        memset(&stop, 0, sizeof stop);
        stop.sa_handler = SPDFStopRequested;
        sigaction(SIGTERM, &stop, NULL);
        sigaction(SIGINT, &stop, NULL);
        sigaction(SIGHUP, &stop, NULL);

        NSMutableData* input = [NSMutableData data];
        uint8_t buffer[65536];
        for (;;) {
            ssize_t n = read(0, buffer, sizeof buffer);
            if (n > 0 && input.length + (size_t)n <= SPDF_PYTHON_MAX_REQUEST_BYTES)
                [input appendBytes:buffer length:(size_t)n];
            else if (n > 0) { input = nil; break; }
            else if (n == 0 || errno != EINTR) break;
        }
        id request = input ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
        NSString* helper = SPDFOwnPath();
        NSDictionary* result;
        if (![request isKindOfClass:NSDictionary.class]) {
            result = @{@"ok" : @NO, @"error" : @"bad_request", @"message" : @"The request is not a JSON object."};
        } else if (!helper) {
            result = @{@"ok" : @NO, @"error" : @"internal", @"message" : @"The helper cannot find itself."};
        } else {
            result = SPDFPythonSandboxRun(request, helper);
        }
        NSData* output = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        SPDFWriteAll(1, output ?: [@"{\"ok\":false,\"error\":\"internal\"}" dataUsingEncoding:NSUTF8StringEncoding]);
        return 0;
    }
}
