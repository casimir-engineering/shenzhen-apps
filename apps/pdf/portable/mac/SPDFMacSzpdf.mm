// szpdf at run time (SPDFMacSzpdf.h): finding the running readers, starting the app when none runs, and printing
// what they answer.
#import "SPDFMacSzpdf.h"
#import "SPDFMacAgentChannel.h"
#import "SPDFMacAgentComments.h"
#import "SPDFMacDocumentVersions.h"
#import "SPDFMacStateDirectory.h"

#import <AppKit/AppKit.h>

#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static void Print(NSDictionary* object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingSortedKeys | NSJSONWritingPrettyPrinted
                                                     error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

static int Finish(NSDictionary* answer) {
    Print(answer);
    return answer[@"error"] ? 1 : 0;
}

static BOOL Alive(pid_t pid) { return kill(pid, 0) == 0 || errno == EPERM; }

// The app this tool belongs to: the bundle around the real executable, whatever link it was run through.
static NSURL* AppBundle(void) {
    char path[PATH_MAX], resolved[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0 || !realpath(path, resolved)) return nil;
    NSString* bundle = @(resolved).stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
                           .stringByDeletingLastPathComponent;
    return [bundle.pathExtension isEqualToString:@"app"] ? [NSURL fileURLWithPath:bundle] : nil;
}

// Every running reader that answers, by pid. A socket left by a process that is gone is removed.
static NSDictionary<NSNumber*, NSDictionary*>* Readers(void) {
    NSString* directory = SPDFMacAgentChannelDirectory(SPDFMacStateDirectoryPath());
    NSMutableDictionary* readers = [NSMutableDictionary dictionary];
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
        pid_t pid = SPDFMacAgentChannelPIDFromName(name);
        if (!pid) continue;
        NSString* path = [directory stringByAppendingPathComponent:name];
        if (!Alive(pid)) {
            unlink(path.fileSystemRepresentation);
            continue;
        }
        NSDictionary* state = SPDFMacAgentChannelExchange(path, @{@"command" : @"state"}, 5, nil);
        if (state) readers[@(pid)] = state;
    }
    return readers;
}

static NSDictionary* Send(pid_t pid, NSDictionary* request, NSTimeInterval timeout) {
    NSError* error = nil;
    NSString* path = SPDFMacAgentChannelSocketPath(SPDFMacStateDirectoryPath(), pid);
    NSDictionary* answer = SPDFMacAgentChannelExchange(path, request, timeout, &error);
    return answer ?: @{@"error" : error.localizedDescription ?: @"ShenzhenPDF did not answer."};
}

static BOOL WaitUntil(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        [NSThread sleepForTimeInterval:0.1];
    }
    return YES;
}

// Starts the app on the document: behind the other apps' windows and without the focus unless `front`.
static NSString* Launch(NSString* document, BOOL front) {
    NSURL* app = AppBundle();
    if (!app) return @"This szpdf is not inside ShenzhenPDF.app; run the one in ShenzhenPDF.app/Contents/MacOS.";
    NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = front;
    configuration.addsToRecentItems = NO;
    if (!front) configuration.environment = @{@"SPDF_BACKGROUND_LAUNCH" : @"1"};
    __block NSString* failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [NSWorkspace.sharedWorkspace openURLs:@[ [NSURL fileURLWithPath:document] ] withApplicationAtURL:app
                            configuration:configuration
                        completionHandler:^(NSRunningApplication* running, NSError* error) {
                          (void)running;
                          if (error) failure = error.localizedDescription ?: @"ShenzhenPDF could not be started.";
                          dispatch_semaphore_signal(done);
                        }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
        return @"ShenzhenPDF did not start within 30 seconds.";
    return failure;
}

// The reader a request about `path` goes to, starting ShenzhenPDF on `path` when none runs (behind, unless `front`).
// 0 and `failure` when there is none.
static pid_t Reader(NSString* path, BOOL front, NSTimeInterval timeout, NSString** failure) {
    __block NSDictionary<NSNumber*, NSDictionary*>* readers = Readers();
    pid_t target = SPDFMacSzpdfChooseProcess(readers, path);
    if (!target && readers.count) {
        // Every reader is quitting: a document handed to one now would wait for a relaunch nobody sees. Let it
        // finish, then start afresh.
        NSArray* quitting = readers.allKeys;
        BOOL gone = WaitUntil(MIN(timeout, 15), ^BOOL {
          for (NSNumber* pid in quitting)
              if (Alive(pid.intValue)) return NO;
          return YES;
        });
        if (!gone) {
            *failure = @"ShenzhenPDF is quitting and has not finished. Try again once it has closed.";
            return 0;
        }
        readers = @{};
    }
    if (target) return target;
    *failure = Launch(path, front);
    if (*failure) return 0;
    BOOL answered = WaitUntil(timeout, ^BOOL {
      readers = Readers();
      return SPDFMacSzpdfChooseProcess(readers, path) != 0;
    });
    if (!answered) {
        *failure = [NSString stringWithFormat:@"ShenzhenPDF started but did not answer within %.0f seconds.", timeout];
        return 0;
    }
    return SPDFMacSzpdfChooseProcess(readers, path);
}

static int Open(NSDictionary* command) {
    NSString* path = command[@"path"];
    BOOL front = [command[@"front"] boolValue];
    NSTimeInterval timeout = [command[@"timeout"] doubleValue];
    NSString* failure = nil;
    pid_t target = Reader(path, front, timeout, &failure);
    if (!target) return Finish(@{@"opened" : @NO, @"error" : failure ?: @"ShenzhenPDF did not answer."});
    NSMutableDictionary* request = [@{@"command" : @"open", @"path" : path, @"front" : @(front),
                                      @"wait" : command[@"wait"]} mutableCopy];
    if (command[@"page"]) request[@"page"] = command[@"page"];
    if (command[@"heading"]) request[@"heading"] = command[@"heading"];
    NSMutableDictionary* answer = [Send(target, request, timeout) mutableCopy];
    if (!answer[@"opened"]) answer[@"opened"] = @NO;
    return Finish(answer);
}

static int State(void) {
    NSDictionary* readers = Readers();
    NSMutableArray* processes = [NSMutableArray array];
    NSMutableArray* windows = [NSMutableArray array];
    NSMutableArray* documents = [NSMutableArray array];
    for (NSNumber* pid in [readers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary* state = readers[pid];
        [processes addObject:@{@"pid" : pid, @"active" : state[@"active"] ?: @NO,
                               @"quitting" : state[@"quitting"] ?: @NO}];
        for (NSDictionary* window in state[@"windows"]) {
            NSMutableDictionary* entry = [window mutableCopy];
            entry[@"pid"] = pid;
            [windows addObject:entry];
            for (NSDictionary* document in window[@"documents"]) {
                NSMutableDictionary* row = [document mutableCopy];
                row[@"windowId"] = window[@"windowId"];
                [documents addObject:row];
            }
        }
    }
    return Finish(@{@"running" : @(processes.count > 0), @"processes" : processes, @"windows" : windows,
                    @"documents" : documents});
}

static int Screenshot(NSDictionary* command) {
    NSDictionary* readers = Readers();
    for (NSNumber* pid in readers)
        for (NSDictionary* window in readers[pid][@"windows"])
            if ([window[@"windowId"] isEqual:command[@"windowId"]])
                return Finish(Send(pid.intValue, @{@"command" : @"screenshot", @"windowId" : command[@"windowId"],
                                                   @"output" : command[@"output"]},
                                   30));
    // Not a document window: a comparison or another of the app's windows, which only its own process knows.
    NSDictionary* request = @{@"command" : @"screenshot", @"windowId" : command[@"windowId"], @"output" : command[@"output"]};
    for (NSNumber* pid in readers) {
        NSDictionary* answer = Send(pid.intValue, request, 30);
        if (!answer[@"error"]) return Finish(answer);
    }
    return Finish(@{@"error" : readers.count ? @"No ShenzhenPDF window has that id; see `szpdf state`."
                                             : @"ShenzhenPDF is not running."});
}

static SPDFDocumentVersionCarry CarryNamed(NSString* name) {
    return [name isEqual:@"all"] ? SPDFDocumentVersionCarryAll
           : [name isEqual:@"none"] ? SPDFDocumentVersionCarryNone : SPDFDocumentVersionCarryOpen;
}

// version new and list go through the reader when one runs (it updates the tabs showing the document), else straight to
// the files; compare needs the reader, and starts it.
static int Versions(NSDictionary* command) {
    NSString* path = command[@"path"];
    NSString* verb = command[@"command"];
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path];
    if (!exists || !SPDFDocumentVersionsSupportsPath(path))
        return Finish(@{@"error" : exists ? @"Versions are kept for Markdown documents and PDFs."
                                          : [NSString stringWithFormat:@"No document at %@.", path]});
    NSString* current = SPDFDocumentVersionsCurrentPath(path);
    NSString* action = [verb substringFromIndex:8];
    NSMutableDictionary* request = [@{@"command" : @"version", @"action" : action, @"path" : current} mutableCopy];
    if ([action isEqual:@"compare"]) {
        NSString* failure = nil;
        pid_t target = Reader(current, [command[@"front"] boolValue], 30, &failure);
        if (!target) return Finish(@{@"opened" : @NO, @"error" : failure ?: @"ShenzhenPDF did not answer."});
        [request addEntriesFromDictionary:@{@"older" : command[@"older"], @"newer" : command[@"newer"],
                                            @"front" : command[@"front"], @"wait" : command[@"wait"]}];
        return Finish(Send(target, request, 70));
    }
    pid_t target = SPDFMacSzpdfChooseProcess(Readers(), current);
    if (target) {
        if ([action isEqual:@"new"]) request[@"carry"] = command[@"carry"];
        NSMutableDictionary* answer = [Send(target, request, 30) mutableCopy];
        answer[@"via"] = @"app";
        return Finish(answer);
    }
    if ([action isEqual:@"list"])
        return Finish(@{@"path" : current, @"via" : @"files",
                        @"versions" : [SPDFDocumentVersionsList(current) valueForKey:@"dictionaryRepresentation"]});
    NSError* error = nil;
    SPDFDocumentVersion* version = SPDFDocumentVersionsCreate(current, CarryNamed(command[@"carry"]), &error);
    if (!version) return Finish(@{@"error" : error.localizedDescription ?: @"The version could not be made."});
    return Finish(@{@"path" : current, @"via" : @"files", @"version" : version.dictionaryRepresentation});
}

// The file holding version `number` of the document `path` belongs to, or nil.
static NSString* VersionPath(NSString* path, NSInteger number) {
    for (SPDFDocumentVersion* version in SPDFDocumentVersionsList(path))
        if (version.number == number) return version.path;
    return nil;
}

static void PrintCommentsText(NSDictionary* listing) {
    NSArray* comments = listing[@"comments"];
    if (!comments.count) printf("No comments on %s.\n", [listing[@"path"] lastPathComponent].UTF8String);
    for (NSDictionary* comment in comments) {
        NSString* where = comment[@"page"] ? [NSString stringWithFormat:@"page %@", comment[@"page"]]
                          : [comment[@"line"] isKindOfClass:NSNumber.class]
                              ? [NSString stringWithFormat:@"line %@", comment[@"line"]]
                              : @"unplaced";
        printf("%s  %s  %s  %s\n", [comment[@"id"] UTF8String], where.UTF8String, [comment[@"status"] UTF8String],
               [comment[@"author"] UTF8String]);
        if ([comment[@"quote"] length]) printf("  > %s\n", [comment[@"quote"] UTF8String]);
        if ([comment[@"text"] length]) printf("  %s\n", [comment[@"text"] UTF8String]);
        for (NSDictionary* reply in comment[@"replies"])
            printf("    - %s: %s\n", [reply[@"author"] UTF8String], [reply[@"text"] UTF8String]);
    }
}

static int Comments(NSDictionary* command) {
    NSError* error = nil;
    NSString* path = command[@"path"];
    NSString* author = command[@"author"] ?: NSProcessInfo.processInfo.environment[@"SZPDF_AUTHOR"] ?: @"Agent";
    NSDictionary* result = nil;
    if ([command[@"command"] isEqual:@"comments"]) {
        if (command[@"version"]) {
            NSString* versionPath = VersionPath(path, [command[@"version"] integerValue]);
            if (!versionPath)
                return Finish(@{@"error" : [NSString stringWithFormat:@"There is no v%@ of this document; see `szpdf "
                                                                      @"version list`.", command[@"version"]]});
            path = versionPath;
        }
        result = SPDFMacAgentListComments(path, &error);
        if (result && command[@"version"]) {
            NSMutableDictionary* stamped = [result mutableCopy];
            stamped[@"version"] = command[@"version"];
            result = stamped;
        }
        if (result && ![command[@"json"] boolValue]) {
            PrintCommentsText(result);
            return 0;
        }
        return Finish(result ?: @{@"error" : error.localizedDescription});
    }
    if ([command[@"command"] isEqual:@"comment-reply"])
        result = SPDFMacAgentReplyToComment(path, command[@"id"], command[@"text"], author, &error);
    else result = SPDFMacAgentResolveComment(path, command[@"id"], [command[@"resolved"] boolValue], author, &error);
    if (!result) return Finish(@{@"error" : error.localizedDescription ?: @"The comment could not be changed."});
    // Readers showing the document redraw its comments now rather than when next looked at.
    NSUInteger refreshed = 0;
    NSDictionary* readers = Readers();
    for (NSNumber* pid in readers)
        refreshed += [Send(pid.intValue, @{@"command" : @"comments-changed", @"path" : path}, 5)[@"refreshed"]
                         unsignedIntegerValue];
    return Finish(@{@"path" : path, @"comment" : result, @"readersRefreshed" : @(refreshed)});
}

int SPDFMacRunSzpdf(int argc, const char* argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSMutableArray<NSString*>* arguments = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [arguments addObject:@(argv[i])];
        NSError* error = nil;
        NSDictionary* command =
            SPDFMacSzpdfParseArguments(arguments, NSFileManager.defaultManager.currentDirectoryPath, &error);
        if (!command) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return [arguments containsObject:@"--help"] || [arguments containsObject:@"-h"] ? 0 : 2;
        }
        NSString* verb = command[@"command"];
        if ([verb isEqual:@"open"]) return Open(command);
        if ([verb isEqual:@"state"]) return State();
        if ([verb isEqual:@"screenshot"]) return Screenshot(command);
        if ([verb hasPrefix:@"version-"]) return Versions(command);
        return Comments(command);
    }
}
