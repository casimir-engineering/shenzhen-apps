#import "SPDFMacAIDocumentJobs.h"
#include <signal.h>
#include <unistd.h>

static NSString* Fail(NSError** error, NSString* message) {
    if (error) *error=[NSError errorWithDomain:@"ShenzhenPDF.AI.Job" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
NSString* SPDFAIRunLocalTool(NSString* executable, NSArray<NSString*>* arguments,
    NSDictionary* environment, NSString* input, NSString* directory, NSProgress* progress, NSError** error) {
    if (progress.cancelled) return Fail(error,@"Cancelled.");
    // Files avoid pipe backpressure when Argos writes before consuming stdin.
    // All are in the request's private scratch directory and removed by its owner.
    NSString* prefix=[directory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString* stdinPath=[prefix stringByAppendingString:@".in"];
    NSString* stdoutPath=[prefix stringByAppendingString:@".out"];
    NSString* stderrPath=[prefix stringByAppendingString:@".err"];
    NSFileManager* fm=NSFileManager.defaultManager;
    if (![(input ?: @"") writeToFile:stdinPath atomically:YES encoding:NSUTF8StringEncoding error:error] ||
        ![fm createFileAtPath:stdoutPath contents:nil attributes:@{NSFilePosixPermissions:@0600}] ||
        ![fm createFileAtPath:stderrPath contents:nil attributes:@{NSFilePosixPermissions:@0600}]) return nil;
    NSTask* task=[NSTask new]; task.executableURL=[NSURL fileURLWithPath:executable];
    task.arguments=arguments; task.environment=environment; task.currentDirectoryURL=[NSURL fileURLWithPath:directory];
    NSFileHandle* inHandle=[NSFileHandle fileHandleForReadingAtPath:stdinPath];
    NSFileHandle* outHandle=[NSFileHandle fileHandleForWritingAtPath:stdoutPath];
    NSFileHandle* errHandle=[NSFileHandle fileHandleForWritingAtPath:stderrPath];
    task.standardInput=inHandle; task.standardOutput=outHandle; task.standardError=errHandle;
    // Serialize launch and cancellation: Stop between the last check and launch
    // must still own and terminate the newly launched process.
    NSObject* lock=[NSObject new];
    progress.cancellationHandler=^{
        @synchronized(lock) {
            if (task.running) {
                pid_t pid=task.processIdentifier;
                // Every output is disposable until validation, so Stop can kill
                // the owned process group immediately. Waiting for the leader
                // to exit first would orphan OCR workers that ignore SIGTERM.
                if (getpgid(pid)==pid) kill(-pid,SIGKILL); else kill(pid,SIGKILL);
            }
        }
    };
    BOOL launched=NO;
    @synchronized(lock) {
        if (!progress.cancelled) launched=[task launchAndReturnError:error];
    }
    if (launched) [task waitUntilExit];
    progress.cancellationHandler=nil;
    [inHandle closeFile]; [outHandle closeFile]; [errHandle closeFile];
    if (progress.cancelled) return Fail(error,@"Cancelled.");
    if (!launched) return nil;
    if (task.terminationStatus!=0) {
        NSString* detail=[NSString stringWithContentsOfFile:stderrPath encoding:NSUTF8StringEncoding error:nil];
        return Fail(error,detail.length ? [detail substringToIndex:MIN((NSUInteger)1500,detail.length)] :
            @"The local tool failed. Install its required support/language packages using the reader, then retry.");
    }
    NSDictionary* attributes=[fm attributesOfItemAtPath:stdoutPath error:error];
    if (!attributes || [attributes fileSize]>16*1024*1024) return Fail(error,@"Local tool output exceeded 16 MiB.");
    return [NSString stringWithContentsOfFile:stdoutPath encoding:NSUTF8StringEncoding error:error];
}
