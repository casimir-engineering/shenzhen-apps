// szpdf at run time (SPDFMacSzpdf.h): finding the running readers, starting the app when none runs, and printing
// what they answer. The commands that need no window run here, in the tool's own process (SPDFMacSzpdfInternal.h).
#import "SPDFMacSzpdf.h"
#import "SPDFMacAgentChannel.h"
#import "SPDFMacAgentComments.h"
#import "SPDFMacCommentActions.h"
#import "SPDFMacDocumentVersions.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacSzpdfHeadingMatch.h"
#import "SPDFMacSzpdfInternal.h"

#import <AppKit/AppKit.h>

#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>


static void Print(NSDictionary* object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingSortedKeys | NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes
                                                     error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

int SPDFMacSzpdfFinish(NSDictionary* answer) {
    NSDictionary* normalized = SPDFMacSzpdfNormalized(answer);
    Print(normalized);
    return [normalized[@"ok"] boolValue] ? 0 : 1;
}

static int Finish(NSDictionary* answer) { return SPDFMacSzpdfFinish(answer); }
static NSDictionary* Readers(void) { return SPDFMacSzpdfReaders(); }
static NSDictionary* Send(pid_t pid, NSDictionary* request, NSTimeInterval timeout) {
    return SPDFMacSzpdfSend(pid, request, timeout);
}
static NSDictionary* Failure(NSString* code, NSString* message) { return SPDFMacSzpdfFailure(code, message, nil); }

static NSDictionary* FromError(NSError* error, NSString* fallback) {
    return Failure(error.userInfo[SPDFMacAgentCommentsErrorCodeKey] ?: @"failed", error.localizedDescription ?: fallback);
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
NSDictionary<NSNumber*, NSDictionary*>* SPDFMacSzpdfReaders(void) {
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

NSDictionary* SPDFMacSzpdfSend(pid_t pid, NSDictionary* request, NSTimeInterval timeout) {
    NSError* error = nil;
    NSString* path = SPDFMacAgentChannelSocketPath(SPDFMacStateDirectoryPath(), pid);
    NSDictionary* answer = SPDFMacAgentChannelExchange(path, request, timeout, &error);
    return answer ?: Failure(@"not-responding", error.localizedDescription ?: @"ShenzhenPDF did not answer.");
}

static BOOL WaitUntil(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        [NSThread sleepForTimeInterval:0.1];
    }
    return YES;
}

// This app's processes, running or still starting (a socket appears only after the first frame).
static NSArray<NSRunningApplication*>* RunningApps(void) {
    NSString* identifier = [NSBundle bundleWithURL:AppBundle()].bundleIdentifier;
    NSMutableArray* running = [NSMutableArray array];
    for (NSRunningApplication* app in identifier ? [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier] : @[])
        if (!app.terminated) [running addObject:app];
    return running;
}

// Starts the app with no document, the focus staying where it is unless `front`. A document is never handed over
// through Launch Services: that is an "open documents" event, on which AppKit itself asks to activate the app (and the
// reader asks too, for a document opened from Finder). It goes over the socket once the reader answers.
static NSDictionary* Launch(BOOL front) {
    NSURL* app = AppBundle();
    if (!app) return Failure(@"launch-failed", @"This szpdf is not inside ShenzhenPDF.app; run the one in "
                                              @"ShenzhenPDF.app/Contents/MacOS.");
    NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = front;
    configuration.addsToRecentItems = NO;
    configuration.createsNewApplicationInstance = NO;
    if (!front) configuration.environment = @{@"SPDF_BACKGROUND_LAUNCH" : @"1"};
    __block NSString* failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:configuration
                                    completionHandler:^(NSRunningApplication* running, NSError* error) {
                                      (void)running;
                                      if (error) failure = error.localizedDescription ?: @"ShenzhenPDF could not be started.";
                                      dispatch_semaphore_signal(done);
                                    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
        return Failure(@"launch-failed", @"ShenzhenPDF did not start within 30 seconds.");
    return failure ? Failure(@"launch-failed", failure) : nil;
}

// The reader a request about `path` goes to: one already running, else ShenzhenPDF started for it (behind, unless
// `front`). 0 and `failure` when there is none.
pid_t SPDFMacSzpdfReader(NSString* path, BOOL front, NSTimeInterval timeout, NSDictionary** failure) {
    __block NSDictionary<NSNumber*, NSDictionary*>* readers = Readers();
    pid_t target = SPDFMacSzpdfChooseProcess(readers, path);
    if (target) return target;
    if (readers.count) {
        // Every reader is quitting: a document handed to one now would wait for a relaunch nobody sees. Let it
        // finish, then start afresh.
        NSArray* quitting = readers.allKeys;
        BOOL gone = WaitUntil(MIN(timeout, 15), ^BOOL {
          for (NSNumber* pid in quitting)
              if (Alive(pid.intValue)) return NO;
          return YES;
        });
        if (!gone) {
            *failure = Failure(@"quitting", @"ShenzhenPDF is quitting and has not finished. Try again once it has closed.");
            return 0;
        }
    } else if (RunningApps().count) {
        // Running but not answering yet (starting, or busy): wait for it rather than start another.
        BOOL answered = WaitUntil(timeout, ^BOOL {
          readers = Readers();
          return SPDFMacSzpdfChooseProcess(readers, path) != 0;
        });
        if (answered) return SPDFMacSzpdfChooseProcess(readers, path);
        *failure = Failure(@"not-responding", [NSString stringWithFormat:@"ShenzhenPDF is running but did not answer "
                                                                         @"within %.0f seconds.", timeout]);
        return 0;
    }
    *failure = Launch(front);
    if (*failure) return 0;
    BOOL answered = WaitUntil(timeout, ^BOOL {
      readers = Readers();
      return SPDFMacSzpdfChooseProcess(readers, path) != 0;
    });
    if (!answered) {
        *failure = Failure(@"not-responding", [NSString stringWithFormat:@"ShenzhenPDF started but did not answer "
                                                                         @"within %.0f seconds.", timeout]);
        return 0;
    }
    return SPDFMacSzpdfChooseProcess(readers, path);
}

// The process showing `path`, if any runs and shows it.
static pid_t Showing(NSDictionary* readers, NSString* path) {
    for (NSNumber* pid in readers)
        for (NSDictionary* window in readers[pid][@"windows"])
            for (NSDictionary* document in window[@"documents"])
                if ([document[@"path"] isEqual:path]) return pid.intValue;
    return 0;
}

#pragma mark - The window commands

static int Open(NSDictionary* command) {
    NSString* path = command[@"path"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        return Finish(SPDFMacSzpdfFailure(@"not-found", [NSString stringWithFormat:@"No document at %@.", path],
                                          @{@"opened" : @NO}));
    BOOL front = [command[@"front"] boolValue];
    NSTimeInterval timeout = [command[@"timeout"] doubleValue];
    NSDictionary* failure = nil;
    pid_t target = SPDFMacSzpdfReader(path, front, timeout, &failure);
    if (!target) return Finish([failure mutableCopy] ?: Failure(@"not-responding", @"ShenzhenPDF did not answer."));
    NSMutableDictionary* request = [@{@"command" : @"open", @"path" : path, @"front" : @(front),
                                      @"wait" : command[@"wait"], @"reload" : command[@"reload"],
                                      @"timeout" : command[@"timeout"]} mutableCopy];
    if (command[@"page"]) request[@"page"] = command[@"page"];
    if (command[@"heading"]) request[@"heading"] = command[@"heading"];
    NSMutableDictionary* answer = [Send(target, request, timeout + 10) mutableCopy];
    if (!answer[@"opened"]) answer[@"opened"] = @NO;
    return Finish(answer);
}

static int Reload(NSDictionary* command) {
    NSDictionary* readers = Readers();
    pid_t target = Showing(readers, command[@"path"]);
    if (!target)
        return Finish(readers.count || RunningApps().count
                          ? Failure(@"not-open", @"The document is not open in ShenzhenPDF; szpdf open shows it.")
                          : Failure(@"not-running", @"ShenzhenPDF is not running; szpdf open starts it."));
    return Finish(Send(target, @{@"command" : @"reload", @"path" : command[@"path"], @"timeout" : command[@"timeout"]},
                       [command[@"timeout"] doubleValue] + 10));
}

static int Close(NSDictionary* command) {
    NSDictionary* readers = Readers();
    if (!readers.count) return Finish(Failure(@"not-running", @"ShenzhenPDF is not running."));
    NSMutableArray *closed = [NSMutableArray array], *windows = [NSMutableArray array];
    NSDictionary* refused = nil;
    NSMutableDictionary* request = [@{@"command" : @"close"} mutableCopy];
    if (command[@"windowId"]) request[@"windowId"] = command[@"windowId"];
    else request[@"path"] = command[@"path"];
    for (NSNumber* pid in readers) {
        NSDictionary* answer = Send(pid.intValue, request, 15);
        [closed addObjectsFromArray:answer[@"closed"] ?: @[]];
        [windows addObjectsFromArray:answer[@"windowIds"] ?: @[]];
        if (answer[@"error"] && [answer[@"errorCode"] isEqual:@"unsaved-changes"]) refused = answer;
    }
    if (refused) return Finish(refused);
    if (!closed.count)
        return Finish(command[@"windowId"] ? Failure(@"no-window", @"No ShenzhenPDF window has that id; see szpdf state.")
                                           : Failure(@"not-open", @"The document is not open in ShenzhenPDF."));
    return Finish(@{@"closed" : closed, @"windowIds" : windows});
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
    NSString* path = command[@"path"];
    NSDictionary* readers = nil;
    if (command[@"windowId"] && command[@"page"]) {
        // A page of what the window shows, drawn from the document: the window does not move.
        readers = Readers();
        for (NSNumber* pid in readers)
            for (NSDictionary* window in readers[pid][@"windows"])
                if ([window[@"windowId"] isEqual:command[@"windowId"]])
                    for (NSDictionary* document in window[@"documents"])
                        if ([document[@"selected"] boolValue]) path = document[@"path"];
        if (!path) return Finish(Failure(readers.count ? @"no-window" : @"not-running",
                                         readers.count ? @"No ShenzhenPDF window with a document has that id; see szpdf state."
                                                       : @"ShenzhenPDF is not running."));
    }
    if (path) {
        NSDictionary* failure = nil;
        SPDFMacSzpdfDocument* document = [SPDFMacSzpdfDocument documentAtPath:path failure:&failure];
        if (!document) return Finish(failure);
        NSMutableDictionary* answer = [[document writePage:[command[@"page"] unsignedIntegerValue] toPNG:command[@"output"]
                                                     scale:command[@"scale"] ? [command[@"scale"] doubleValue] : 2
                                                    region:command[@"region"]] mutableCopy];
        if (command[@"windowId"]) answer[@"windowId"] = command[@"windowId"];
        return Finish(answer);
    }
    readers = Readers();
    NSDictionary* request = @{@"command" : @"screenshot", @"windowId" : command[@"windowId"], @"output" : command[@"output"]};
    for (NSNumber* pid in readers)
        for (NSDictionary* window in readers[pid][@"windows"])
            if ([window[@"windowId"] isEqual:command[@"windowId"]]) return Finish(Send(pid.intValue, request, 30));
    // Not a document window: a comparison or another of the app's windows, which only its own process knows.
    for (NSNumber* pid in readers) {
        NSDictionary* answer = Send(pid.intValue, request, 30);
        if (!answer[@"error"]) return Finish(answer);
    }
    return Finish(readers.count ? Failure(@"no-window", @"No ShenzhenPDF window has that id; see szpdf state.")
                                : Failure(@"not-running", @"ShenzhenPDF is not running."));
}

#pragma mark - Without the app

static int Headless(NSDictionary* command) {
    NSString* verb = command[@"command"];
    NSDictionary* failure = nil;
    SPDFMacSzpdfDocument* document = [SPDFMacSzpdfDocument documentAtPath:command[@"path"] failure:&failure];
    if (!document) return Finish(failure);
    if ([verb isEqual:@"headings"])
        return Finish(@{@"path" : document.path, @"pageCount" : @(document.pageCount), @"headings" : document.headings});
    if ([verb isEqual:@"find"])
        return Finish([document find:command[@"text"] caseSensitive:[command[@"case"] boolValue]
                               limit:[command[@"limit"] unsignedIntegerValue]]);
    if ([verb isEqual:@"export-pdf"]) return Finish([document writePDF:command[@"output"]]);
    return Finish(SPDFMacSzpdfCheck(document));
}

static void PrintUsageMistake(NSError* error) {
    NSString* name = error.userInfo[@"command"];
    fprintf(stderr, "szpdf: %s\n%s\n", error.localizedDescription.UTF8String, SPDFMacSzpdfUsageText(name).UTF8String);
    NSMutableDictionary* answer = [SPDFMacSzpdfFailure(@"usage", error.localizedDescription, nil) mutableCopy];
    if (name) answer[@"usage"] = SPDFMacSzpdfCommandNamed(name)[@"usage"];
    Print(answer);
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
            PrintUsageMistake(error);
            return 2;
        }
        NSString* verb = command[@"command"];
        if ([verb isEqual:@"help"]) {
            NSString* topic = command[@"topic"];
            if (topic && ![topic isEqual:@"errors"] && !SPDFMacSzpdfCommandNamed(topic)) {
                PrintUsageMistake([NSError errorWithDomain:@"ShenzhenPDF.szpdf" code:2
                                                  userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"No command %@.", topic]}]);
                return 2;
            }
            printf("%s", SPDFMacSzpdfHelpText(topic).UTF8String);
            return 0;
        }
        if ([verb isEqual:@"version-info"]) {
            NSDictionary* info = [NSBundle bundleWithURL:AppBundle()].infoDictionary ?: @{};
            return Finish(@{@"version" : info[@"CFBundleShortVersionString"] ?: @"", @"build" : info[@"CFBundleVersion"] ?: @"",
                            @"app" : AppBundle().path ?: @""});
        }
        if ([verb isEqual:@"schema"]) return Finish(SPDFMacSzpdfSchema(command[@"topic"]));
        if ([verb isEqual:@"features"]) return Finish(SPDFMacSzpdfFeatures(command[@"format"]));
        if ([@[ @"headings", @"find", @"export-pdf", @"check" ] containsObject:verb]) return Headless(command);
        if ([verb isEqual:@"open"]) return Open(command);
        if ([verb isEqual:@"reload"]) return Reload(command);
        if ([verb isEqual:@"close"]) return Close(command);
        if ([verb isEqual:@"state"]) return State();
        if ([verb isEqual:@"screenshot"]) return Screenshot(command);
        if ([verb hasPrefix:@"version-"]) return SPDFMacSzpdfVersions(command);
        return SPDFMacSzpdfComments(command);
    }
}
