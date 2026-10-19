// Apps as processes of their own (SZFriendsE2EApps.h).

#import "SZFriendsE2EApps.h"

#import <errno.h>
#import <fcntl.h>
#import <libproc.h>
#import <signal.h>
#import <spawn.h>
#import <stdlib.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString *SZFE2EHelperBundle(NSString *appExecutable) {
    NSString *contents = appExecutable.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    return [contents stringByAppendingPathComponent:@"Helpers/Shenzhen Friends.app"];
}

NSString *SZFE2EAppHelperExecutable(NSString *appExecutable) {
    return [SZFE2EHelperBundle(appExecutable) stringByAppendingPathComponent:@"Contents/MacOS/Shenzhen Friends"];
}

BOOL SZFE2ESetAppHelperBuild(NSString *appExecutable, uint64_t build) {
    // What helper.mk stamps into the shipped bundle, under a test identifier: never the production helper's.
    NSDictionary *info = @{
        @"CFBundleIdentifier" : @"com.example.shenzhenfriends-e2e",
        @"CFBundleName" : @"Shenzhen Friends",
        @"CFBundleExecutable" : @"Shenzhen Friends",
        @"CFBundlePackageType" : @"APPL",
        @"CFBundleShortVersionString" : @"26.10.13",
        @"CFBundleVersion" : [NSString stringWithFormat:@"%llu", build],
        @"SZFriendsBuildNumber" : @(build),
        @"LSBackgroundOnly" : @YES,
    };
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0
                                                              options:0 error:NULL];
    NSString *path = [SZFE2EHelperBundle(appExecutable) stringByAppendingPathComponent:@"Contents/Info.plist"];
    return plist != nil && [plist writeToFile:path atomically:YES];
}

NSString *SZFE2EMakeAppBundle(NSString *directory, NSString *name, NSString *program, NSString *helper,
                              uint64_t build) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *app = [directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
    NSString *executable = [app stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:name]];
    NSString *embedded = SZFE2EAppHelperExecutable(executable);
    for (NSString *path in @[ executable, embedded ]) {
        if (![files createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                               attributes:nil error:NULL]) {
            return nil;
        }
    }
    // Copies keep the linker's ad-hoc signature, and nothing seals the bundles, so editing a plist later is fine.
    if (![files copyItemAtPath:program toPath:executable error:NULL] ||
        ![files copyItemAtPath:helper toPath:embedded error:NULL] || !SZFE2ESetAppHelperBuild(executable, build)) {
        return nil;
    }
    return executable;
}

NSString *SZFE2EProcessPath(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int length = pid > 0 ? proc_pidpath(pid, path, sizeof path) : 0;
    return length > 0 ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path
                                                                                   length:(NSUInteger)length]
                      : nil;
}

BOOL SZFE2EWaitGone(pid_t pid, NSTimeInterval timeout) {
    return SZFE2EWaitUntil(timeout, ^BOOL {
        // A process that has exited but not yet been reaped by the app that spawned it has no path any more.
        return (kill(pid, 0) != 0 && errno == ESRCH) || SZFE2EProcessPath(pid) == nil;
    });
}

void SZFE2EKillHelpersUnder(NSArray<NSNumber *> *pids, NSString *directory) {
    if (directory.length == 0) return;
    char resolved[PATH_MAX];
    // proc_pidpath reports the real path (/private/var/...), so compare against the directory's real path too.
    NSString *root = realpath(directory.fileSystemRepresentation, resolved) ? @(resolved) : directory;
    for (NSNumber *pid in pids) {
        if ([SZFE2EProcessPath(pid.intValue) hasPrefix:[root stringByAppendingString:@"/"]]) {
            kill(pid.intValue, SIGKILL);
        }
    }
    for (NSNumber *pid in pids) SZFE2EWaitGone(pid.intValue, 5);
}

@implementation SZFE2EApp {
    int _input, _output;
    NSMutableData *_pending;
    NSMutableArray<NSNumber *> *_helperPIDs;
    NSMutableArray<NSDictionary *> *_goodbyes, *_welcomes;
    NSMutableDictionary<NSString *, NSDictionary *> *_conversations, *_replies;
}

+ (instancetype)launch:(NSString *)executable build:(uint64_t)build
           environment:(NSDictionary<NSString *, NSString *> *)environment {
    int input[2], output[2];
    if (pipe(input) != 0) return nil;
    if (pipe(output) != 0) {
        close(input[0]);
        close(input[1]);
        return nil;
    }
    NSString *log = [executable stringByAppendingPathExtension:@"log"];
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, log.fileSystemRepresentation,
                                     O_WRONLY | O_CREAT | O_APPEND, 0600);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT); // nothing else of the runner's leaks in
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSString *key in environment) [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, environment[key]]];
    char **envp = calloc(pairs.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < pairs.count; i++) envp[i] = strdup(pairs[i].UTF8String);
    NSString *buildText = [NSString stringWithFormat:@"%llu", build];
    NSString *version = [NSString stringWithFormat:@"26.10.13-%llu", build % 100];
    NSString *helper = SZFE2EAppHelperExecutable(executable);
    const char *argv[] = {executable.fileSystemRepresentation, helper.fileSystemRepresentation, version.UTF8String,
                          buildText.UTF8String, NULL};
    pid_t pid = -1;
    int result = posix_spawn(&pid, argv[0], &actions, &attributes, (char **)argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    for (NSUInteger i = 0; i < pairs.count; i++) free(envp[i]);
    free(envp);
    close(input[0]);
    close(output[1]);
    if (result != 0) {
        close(input[1]);
        close(output[0]);
        return nil;
    }
    SZFE2ETrackPID(pid);
    SZFE2EApp *app = [[self alloc] init];
    app->_executable = [executable copy];
    app->_pid = pid;
    app->_input = input[1];
    app->_output = output[0];
    // An app that died must fail the scenario, not kill the runner with SIGPIPE on the next command.
    fcntl(app->_input, F_SETNOSIGPIPE, 1);
    fcntl(app->_input, F_SETFD, FD_CLOEXEC);
    fcntl(app->_output, F_SETFD, FD_CLOEXEC);
    fcntl(app->_output, F_SETFL, O_NONBLOCK);
    app->_state = @"idle";
    app->_pending = [NSMutableData data];
    app->_helperPIDs = [NSMutableArray array];
    app->_goodbyes = [NSMutableArray array];
    app->_welcomes = [NSMutableArray array];
    app->_conversations = [NSMutableDictionary dictionary];
    app->_replies = [NSMutableDictionary dictionary];
    return app;
}

- (void)dealloc {
    [self quitWithin:2];
}

- (NSArray<NSNumber *> *)helperPIDs {
    return [_helperPIDs copy];
}

- (NSArray<NSDictionary *> *)goodbyes {
    return [_goodbyes copy];
}

- (NSArray<NSDictionary *> *)welcomes {
    return [_welcomes copy];
}

- (NSDictionary *)conversation:(NSString *)conversationID {
    return _conversations[conversationID];
}

- (NSDictionary *)replyTagged:(NSString *)tag {
    return _replies[tag];
}

- (void)send:(NSDictionary *)command {
    if (_input < 0) return;
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:command options:0 error:NULL] mutableCopy];
    [line appendBytes:"\n" length:1];
    (void)write(_input, line.bytes, line.length); // short commands: one write into an empty pipe
}

- (void)handle:(NSDictionary *)event {
    NSString *kind = event[@"event"];
    if ([kind isEqual:@"state"]) {
        _state = [event[@"state"] copy];
        _helperPID = [_state isEqual:@"ready"] ? [event[@"helper_pid"] intValue] : 0;
        if (_helperPID > 0 && ![_helperPIDs.lastObject isEqual:@(_helperPID)]) [_helperPIDs addObject:@(_helperPID)];
    } else if ([kind isEqual:@"snapshot"] && [event[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *data = event[@"data"];
        if ([event[@"view"] isEqual:@"list"]) _list = data;
        if ([event[@"view"] isEqual:@"conversation"] && [data[@"conversation_id"] isKindOfClass:[NSString class]]) {
            _conversations[data[@"conversation_id"]] = data;
        }
    } else if ([kind isEqual:@"reply"] && [event[@"tag"] isKindOfClass:[NSString class]]) {
        _replies[event[@"tag"]] = event;
    } else if ([kind isEqual:@"welcome"] && event[@"frame"]) {
        [_welcomes addObject:event[@"frame"]];
    } else if ([kind isEqual:@"goodbye"] && event[@"frame"]) {
        [_goodbyes addObject:event[@"frame"]];
    }
}

- (void)drain {
    if (_output < 0) return;
    uint8_t chunk[65536];
    ssize_t got;
    while ((got = read(_output, chunk, sizeof chunk)) > 0) [_pending appendBytes:chunk length:(NSUInteger)got];
    for (;;) {
        NSRange newline = [_pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                          range:NSMakeRange(0, _pending.length)];
        if (newline.location == NSNotFound) break;
        NSData *line = [_pending subdataWithRange:NSMakeRange(0, newline.location)];
        [_pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        id event = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        if ([event isKindOfClass:[NSDictionary class]]) [self handle:event];
    }
}

- (pid_t)waitReady:(NSTimeInterval)timeout {
    SZFE2EWaitUntil(timeout, ^BOOL {
        [self drain];
        return [self.state isEqual:@"ready"] && self.helperPID > 0;
    });
    return [self.state isEqual:@"ready"] ? self.helperPID : 0;
}

- (BOOL)quitWithin:(NSTimeInterval)timeout {
    if (_pid <= 0) return YES;
    [self send:@{@"cmd" : @"quit"}];
    __block int status = 0;
    pid_t pid = _pid;
    BOOL quit = SZFE2EWaitUntil(timeout, ^BOOL { return waitpid(pid, &status, WNOHANG) == pid; });
    if (!quit) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
    }
    // Forgotten once reaped: the pid may be reused by an unrelated process, which must never be signalled.
    SZFE2EUntrackPID(pid);
    _pid = -1;
    [self drain];
    if (_input >= 0) close(_input);
    if (_output >= 0) close(_output);
    _input = _output = -1;
    return quit && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

- (NSString *)log {
    NSString *path = [self.executable stringByAppendingPathExtension:@"log"];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"(no log)";
}

@end
