// Shared by the sandbox suites: checks, finding a Python to sandbox, and running the real helper with a deadline.
// The helper and its interpreter run for real on this Mac, in throwaway work directories and with no network.
#pragma once
#import <Foundation/Foundation.h>

#include <signal.h>
#include <unistd.h>

static int failures;
static void SandboxCheck(const char* file, int line, BOOL condition, const char* message) {
    if (condition) return;
    fprintf(stderr, "FAIL %s:%d: %s\n", file, line, message);
    ++failures;
}
#define CHECK(...) SandboxCheck(__FILE__, __LINE__, __VA_ARGS__)

static void SandboxSpin(NSTimeInterval seconds) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// Spins the main run loop until `done` or 10 s, whichever is first.
__attribute__((unused)) static BOOL SandboxWait(BOOL (^done)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done() && deadline.timeIntervalSinceNow > 0) SandboxSpin(0.02);
    return done();
}

// A Python 3 with a real bin/ directory, from the same fixed places the installer looks; the Xcode tools' stubs are
// skipped for the interpreters they point at, so nothing here can trigger the "install command line tools" prompt.
static NSString* SandboxBasePython(void) {
    for (NSString* path in @[ @"/opt/homebrew/bin/python3", @"/usr/local/bin/python3",
                              @"/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
                              @"/Library/Developer/CommandLineTools/usr/bin/python3" ])
        if (access(path.fileSystemRepresentation, X_OK) == 0) return path;
    return nil;
}

static NSString* SandboxTemporaryDirectory(NSString* name) {
    NSString* pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"spdf-%@-XXXXXX", name]];
    char buffer[1024];
    strlcpy(buffer, pattern.fileSystemRepresentation, sizeof buffer);
    if (!mkdtemp(buffer)) return nil;
    char resolved[1024];
    return realpath(buffer, resolved) ? @(resolved) : @(buffer);
}

// Runs the helper binary on one request, killing it if it outlives `seconds`.
__attribute__((unused)) static NSDictionary* SandboxRunHelper(NSString* helper, NSDictionary* request,
                                                         NSTimeInterval seconds) {
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:helper];
    NSPipe* input = [NSPipe pipe], *output = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return nil;
    [input.fileHandleForWriting writeData:[NSJSONSerialization dataWithJSONObject:request options:0 error:nil]];
    [input.fileHandleForWriting closeFile];
    __block NSData* data = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        data = [output.fileHandleForReading readDataToEndOfFile];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)))) {
        killpg(task.processIdentifier, SIGKILL);
        kill(task.processIdentifier, SIGKILL);
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    }
    [task waitUntilExit];
    id result = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}

// A pure-Python PNG writer: the image path is tested without matplotlib, which only the installed environment has.
static NSString* const kSandboxPNGWriter =
    @"import struct, zlib\n"
     "def write_png(path, width, height):\n"
     "    raw = b''.join(b'\\x00' + bytes([200, 40, 40] * width) for _ in range(height))\n"
     "    def chunk(kind, body):\n"
     "        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))\n"
     "    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)\n"
     "    with open(path, 'wb') as f:\n"
     "        f.write(b'\\x89PNG\\r\\n\\x1a\\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(raw)) +\n"
     "                chunk(b'IEND', b''))\n";
