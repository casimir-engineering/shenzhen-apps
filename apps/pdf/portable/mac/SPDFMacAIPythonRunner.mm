#import "SPDFMacAIPythonRunner.h"

#import "SPDFMacToolEnvironment.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

NSString* SPDFMacAIPythonHelperPath(NSBundle* bundle) {
    NSString* path = [bundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/spdf-python-sandbox"];
    return access(path.fileSystemRepresentation, X_OK) == 0 ? path : nil;
}

static NSDictionary* SPDFRunFailure(NSString* error, NSString* message) {
    return @{@"ok" : @NO, @"error" : error, @"message" : message};
}

// One run's state, shared by the reader, the deadline and Stop. Main thread only.
@interface SPDFMacAIPythonRun : NSObject
@property(nonatomic) NSTask* task;
@property(nonatomic) BOOL finished, stopping;
@property(nonatomic, copy) SPDFMacAIPythonRunCompletion completion;
@end
@implementation SPDFMacAIPythonRun
- (void)finishWith:(NSDictionary*)result {
    if (self.finished) return;
    self.finished = YES;
    SPDFMacAIPythonRunCompletion completion = self.completion;
    self.completion = nil;
    if (completion) completion(result);
}
@end

@implementation SPDFMacAIPythonSandboxRunner

- (instancetype)initWithHelperPath:(NSString*)helperPath {
    if (!(self = [super init])) return nil;
    _helperPath = [helperPath copy];
    _timeout = 45;
    _stopGrace = 5;
    return self;
}

// A write that cannot raise SIGPIPE in the app: the helper may have exited (a bad request) before reading.
static void SPDFWriteRequest(int fd, NSData* body) {
    fcntl(fd, F_SETNOSIGPIPE, 1);
    const uint8_t* bytes = (const uint8_t*)body.bytes;
    size_t left = body.length;
    while (left) {
        ssize_t written = write(fd, bytes, left);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) break;
        bytes += written;
        left -= (size_t)written;
    }
    close(fd);
}

- (void)stop:(SPDFMacAIPythonRun*)run {
    if (run.finished || run.stopping || !run.task.isRunning) return;
    run.stopping = YES;
    pid_t pid = run.task.processIdentifier;
    kill(pid, SIGTERM);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_stopGrace * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (run.finished || !run.task.isRunning) return;
        // The helper leads its own process group (it calls setpgid at start), so this also ends the code it runs.
        if (killpg(pid, SIGKILL) != 0) kill(pid, SIGKILL);
    });
}

- (dispatch_block_t)runRequest:(NSDictionary*)request completion:(SPDFMacAIPythonRunCompletion)completion {
    SPDFMacAIPythonRun* run = [SPDFMacAIPythonRun new];
    run.completion = completion;
    NSData* body = [NSJSONSerialization isValidJSONObject:request]
        ? [NSJSONSerialization dataWithJSONObject:request options:0 error:nil] : nil;
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:_helperPath];
    // The helper builds the interpreter's environment from nothing; this keeps the helper itself clear of the
    // interpreter and loader variables a GUI app can inherit.
    task.environment = spdf_mac_tool_environment(NSProcessInfo.processInfo.environment, @[], nil);
    NSPipe* input = [NSPipe pipe];
    NSPipe* output = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError* error = nil;
    if (!body || ![task launchAndReturnError:&error]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [run finishWith:SPDFRunFailure(@"internal", body ? @"The Python sandbox could not start."
                                                             : @"The request could not be encoded.")];
        });
        return ^{};
    }
    run.task = task;
    int writer = dup(input.fileHandleForWriting.fileDescriptor);
    [input.fileHandleForWriting closeFile];
    NSFileHandle* reader = output.fileHandleForReading;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ SPDFWriteRequest(writer, body); });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData* data = [reader readDataToEndOfFile];
        [task waitUntilExit];
        id result = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([result isKindOfClass:NSDictionary.class]) [run finishWith:result];
            else if (run.stopping) [run finishWith:SPDFRunFailure(@"stopped", @"The run was stopped.")];
            else [run finishWith:SPDFRunFailure(@"internal", @"The Python sandbox ended without a result.")];
        });
    });
    __weak SPDFMacAIPythonSandboxRunner* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf stop:run];
    });
    return ^{
        if (NSThread.isMainThread) [weakSelf stop:run];
        else dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf stop:run]; });
    };
}

@end
