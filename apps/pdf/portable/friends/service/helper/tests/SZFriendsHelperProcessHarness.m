// Harness for the helper's process tests (SZFriendsHelperProcessHarness.h).

#import "SZFriendsHelperProcessHarness.h"

#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <unistd.h>

#import "client/szfriends_client.h"

extern char **environ;

int SZFHFailures = 0;
NSString *SZFHLastStateDirectory;
static NSMutableSet<NSNumber *> *SZFHSpawned;

void SZFHFail(const char *file, int line, const char *condition, NSString *detail) {
    SZFHFailures++;
    fprintf(stderr, "%s:%d: expected %s %s\n", file, line, condition, detail.UTF8String);
}

static void SZFHKillLeftovers(void) {
    for (NSNumber *pid in SZFHSpawned) kill(pid.intValue, SIGKILL);
}

static int SZFHRun(NSString *tool, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return -1;
    [task waitUntilExit];
    return task.terminationStatus;
}

@implementation SZFHHarness {
    NSMutableArray<NSString *> *_directories;
    NSMutableSet<NSString *> *_stateDirectories;
}

- (instancetype)initWithApp:(NSString *)appPath {
    if ((self = [super init])) {
        _appPath = [appPath copy];
        _executablePath = [appPath stringByAppendingPathComponent:@"Contents/MacOS/Shenzhen Friends"];
        _directories = [NSMutableArray array];
        _stateDirectories = [NSMutableSet set];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            SZFHSpawned = [NSMutableSet set];
            atexit(SZFHKillLeftovers);
        });
    }
    return self;
}

- (BOOL)switchToAdHocCopy {
    NSString *copy = [[self makeDirectory] stringByAppendingPathComponent:@"Shenzhen Friends.app"];
    if (![[NSFileManager defaultManager] copyItemAtPath:self.appPath toPath:copy error:NULL]) return NO;
    if (SZFHRun(@"/usr/bin/codesign", @[ @"--force", @"--sign", @"-", copy ]) != 0) return NO;
    _appPath = copy;
    _executablePath = [copy stringByAppendingPathComponent:@"Contents/MacOS/Shenzhen Friends"];
    return YES;
}

- (NSString *)makeDirectory {
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfh.XXXXXX"];
    char buffer[PATH_MAX];
    strlcpy(buffer, template.fileSystemRepresentation, sizeof(buffer));
    NSString *path = mkdtemp(buffer) ? [NSString stringWithUTF8String:buffer] : @"";
    [_directories addObject:path];
    return path;
}

- (pid_t)spawnHelperWithStateDirectory:(NSString *)stateDirectory timeScale:(double)timeScale {
    return [self spawnExecutable:self.executablePath stateDirectory:stateDirectory timeScale:timeScale];
}

- (pid_t)spawnExecutable:(NSString *)executable stateDirectory:(NSString *)stateDirectory timeScale:(double)timeScale {
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDirectory withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *log = [stateDirectory stringByAppendingPathComponent:@"helper.log"];
    SZFHLastStateDirectory = stateDirectory;
    [_stateDirectories addObject:stateDirectory];
    // A fixed, minimal environment: nothing from the shell running the tests can point a helper at the Keychain
    // or at a real state directory.
    NSArray *variables = @[
        [@"SZFRIENDS_STATE_DIR=" stringByAppendingString:stateDirectory], @"SZFRIENDS_KEY_STORE=file",
        [@"SZFRIENDS_DOWNLOADS_DIR=" stringByAppendingString:[stateDirectory stringByAppendingString:@"-Downloads"]],
        [NSString stringWithFormat:@"SZFRIENDS_HELPER_TIME_SCALE=%g", timeScale],
        [@"HOME=" stringByAppendingString:NSHomeDirectory()], @"PATH=/usr/bin:/bin",
        [@"TMPDIR=" stringByAppendingString:NSTemporaryDirectory()],
    ];
    char *envp[10] = {0};
    for (NSUInteger i = 0; i < variables.count; i++) envp[i] = strdup([variables[i] UTF8String]);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, log.fileSystemRepresentation,
                                     O_WRONLY | O_CREAT | O_APPEND, 0600);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    // No descriptor of the test leaks into a helper: a helper holding a client socket's other end would never
    // see that client close.
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t pid = 0;
    const char *argv[] = {executable.fileSystemRepresentation, NULL};
    int result = posix_spawn(&pid, executable.fileSystemRepresentation, &actions, &attributes, (char **)argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    for (NSUInteger i = 0; i < variables.count; i++) free(envp[i]);
    if (result != 0) return -1;
    [SZFHSpawned addObject:@(pid)];
    return pid;
}

- (BOOL)waitForExit:(pid_t)pid timeout:(NSTimeInterval)timeout status:(int *)status {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    while (deadline.timeIntervalSinceNow > 0) {
        int waitStatus = 0;
        pid_t done = waitpid(pid, &waitStatus, WNOHANG);
        if (done == pid) {
            [SZFHSpawned removeObject:@(pid)];
            if (status) *status = waitStatus;
            return YES;
        }
        usleep(10000);
    }
    return NO;
}

- (BOOL)reap:(pid_t)pid status:(int *)status {
    int waitStatus = 0;
    if (waitpid(pid, &waitStatus, WNOHANG) != pid) return NO;
    // Forgotten at once: a reaped pid can be reused by an unrelated process, which the exit handler must not kill.
    [SZFHSpawned removeObject:@(pid)];
    if (status) *status = waitStatus;
    return YES;
}

- (BOOL)isRunning:(pid_t)pid {
    int waitStatus = 0;
    if (waitpid(pid, &waitStatus, WNOHANG) == pid) {
        [SZFHSpawned removeObject:@(pid)];
        return NO;
    }
    return kill(pid, 0) == 0;
}

- (NSString *)socketPathForStateDirectory:(NSString *)stateDirectory {
    char path[SZFRIENDS_PATH_CAP];
    bool fallback = false;
    if (szfriends_socket_path(stateDirectory.fileSystemRepresentation, path, sizeof(path), &fallback) != SZFRIENDS_OK) {
        return @"";
    }
    return @(path);
}

- (nullable NSString *)copyOfAppWithBuildNumber:(uint64_t)buildNumber {
    NSString *copy = [[self makeDirectory] stringByAppendingPathComponent:@"Shenzhen Friends.app"];
    return [self copyOfAppAtPath:copy buildNumber:buildNumber];
}

- (nullable NSString *)copyOfAppAtPath:(NSString *)copy buildNumber:(uint64_t)buildNumber {
    [[NSFileManager defaultManager] createDirectoryAtPath:copy.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![[NSFileManager defaultManager] copyItemAtPath:self.appPath toPath:copy error:NULL]) return nil;
    NSString *plist = [copy stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSString *set = [NSString stringWithFormat:@"Set :SZFriendsBuildNumber %llu", buildNumber];
    if (SZFHRun(@"/usr/libexec/PlistBuddy", @[ @"-c", set, plist ]) != 0) return nil;
    // Editing Info.plist breaks the seal; an ad-hoc signature over the copy makes it a well-formed build again.
    if (SZFHRun(@"/usr/bin/codesign", @[ @"--force", @"--sign", @"-", copy ]) != 0) return nil;
    return [copy stringByAppendingPathComponent:@"Contents/MacOS/Shenzhen Friends"];
}

- (NSString *)logForStateDirectory:(NSString *)stateDirectory {
    NSString *log = [stateDirectory stringByAppendingPathComponent:@"helper.log"];
    return [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:NULL] ?: @"(no log)";
}

- (void)cleanUp {
    NSFileManager *files = [NSFileManager defaultManager];
    // A state directory too deep for sun_path put its socket in a per-user szfriends-<hash> directory, outside the
    // directories below: removed too, even when the test that caused it stopped early.
    for (NSString *state in _stateDirectories) {
        char path[SZFRIENDS_PATH_CAP];
        bool fallback = false;
        if (szfriends_socket_path(state.fileSystemRepresentation, path, sizeof(path), &fallback) == SZFRIENDS_OK &&
            fallback) {
            NSString *directory = @(path).stringByDeletingLastPathComponent;
            if ([directory.lastPathComponent hasPrefix:@"szfriends-"]) [files removeItemAtPath:directory error:NULL];
        }
    }
    [_stateDirectories removeAllObjects];
    for (NSString *directory in _directories) [files removeItemAtPath:directory error:NULL];
    [_directories removeAllObjects];
}

@end

@implementation SZFHClient {
    int _fd;
    NSMutableData *_buffer;
    NSUInteger _nextID;
}

- (instancetype)init {
    if ((self = [super init])) _fd = -1;
    return self;
}

+ (nullable instancetype)connectToSocket:(NSString *)socketPath timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));
    while (deadline.timeIntervalSinceNow > 0) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return nil;
        if (connect(fd, (struct sockaddr *)&address, (socklen_t)SUN_LEN(&address)) == 0) {
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
            SZFHClient *client = [[self alloc] init];
            client->_fd = fd;
            client->_buffer = [NSMutableData data];
            client->_skipped = [NSMutableArray array];
            client->_snapshots = [NSMutableArray array];
            return client;
        }
        close(fd);
        usleep(20000);
    }
    return nil;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    if (_fd >= 0) close(_fd);
    _fd = -1;
}

- (BOOL)sendData:(NSData *)data timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t written = write(_fd, (const uint8_t *)data.bytes + offset, data.length - offset);
        if (written > 0) {
            offset += (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno != EAGAIN && errno != EINTR) return NO;
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        struct pollfd p = {.fd = _fd, .events = POLLOUT};
        poll(&p, 1, 50);
    }
    return YES;
}

- (BOOL)sendLine:(NSString *)line {
    return [self sendData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding] timeout:5];
}

- (BOOL)sendFrame:(NSDictionary *)frame {
    NSData *json = [NSJSONSerialization dataWithJSONObject:frame options:0 error:NULL];
    return json != nil && [self sendLine:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
}

- (nullable NSDictionary *)nextFrameWithTimeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    for (;;) {
        NSRange newline = [_buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                         range:NSMakeRange(0, _buffer.length)];
        if (newline.location != NSNotFound) {
            NSData *line = [_buffer subdataWithRange:NSMakeRange(0, newline.location)];
            [_buffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            id frame = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            return [frame isKindOfClass:[NSDictionary class]] ? frame : @{@"type" : @"(unparseable)"};
        }
        if (_eof || deadline.timeIntervalSinceNow <= 0) return nil;
        struct pollfd p = {.fd = _fd, .events = POLLIN};
        poll(&p, 1, (int)MAX(1, MIN(100, deadline.timeIntervalSinceNow * 1000)));
        uint8_t chunk[65536];
        ssize_t count = read(_fd, chunk, sizeof(chunk));
        if (count > 0) [_buffer appendBytes:chunk length:(NSUInteger)count];
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) _eof = YES;
    }
}

- (nullable NSDictionary *)nextFrameOfType:(NSString *)type timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    while (deadline.timeIntervalSinceNow > 0) {
        NSDictionary *frame = [self nextFrameWithTimeout:deadline.timeIntervalSinceNow];
        if (frame == nil) return nil;
        if ([frame[@"type"] isEqual:type]) return frame;
        [_skipped addObject:frame];
    }
    return nil;
}

- (BOOL)waitForEOFWithTimeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    while (!_eof && deadline.timeIntervalSinceNow > 0) {
        NSDictionary *frame = [self nextFrameWithTimeout:deadline.timeIntervalSinceNow];
        if (frame != nil) [_skipped addObject:frame];
    }
    return _eof;
}

- (nullable NSDictionary *)helloWithEmbeddedBuild:(uint64_t)build {
    id embedded = build == 0 ? [NSNull null] : @{
        @"version" : [NSString stringWithFormat:@"test-%llu", build],
        @"build_number" : @(build),
        @"protocol" : @{@"major" : @1, @"minor" : @0},
    };
    NSDictionary *hello = @{
        @"type" : @"hello", @"id" : @"1", @"protocol" : @{@"major" : @1, @"minor" : @0, @"min_major" : @1},
        @"client" : @{@"app_id" : @"com.example.friends-test", @"app_name" : @"Friends Test", @"app_version" : @"1",
                      @"toolkit" : @"appkit", @"reveal_in" : @"Finder", @"pid" : @(getpid())},
        @"embedded_helper" : embedded, @"capabilities" : @[ @"drop.files" ], @"open_formats" : @[ @"pdf" ],
        @"locale" : @"en-GB",
    };
    if (![self sendFrame:hello]) return nil;
    _nextID = 1;
    return [self nextFrameWithTimeout:5];
}

- (nullable NSDictionary *)intent:(NSString *)type fields:(nullable NSDictionary *)fields {
    NSString *identifier = [NSString stringWithFormat:@"%lu", (unsigned long)++_nextID + 100];
    NSMutableDictionary *frame = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    frame[@"type"] = type;
    frame[@"id"] = identifier;
    if (![self sendFrame:frame]) return nil;
    // 10 s (the longest wait for one frame), not 5: on a 3-core CI runner, opening 140 messages of 32 KB (link
    // detection on each, twice when the first snapshot is too big) takes over 5 s; 1.3 s on the owner's Mac and 4.5 s
    // on it at background priority. The app waits for replies without a limit.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (deadline.timeIntervalSinceNow > 0) {
        NSDictionary *next = [self nextFrameWithTimeout:deadline.timeIntervalSinceNow];
        if (next == nil) return nil;
        if ([next[@"type"] isEqual:@"reply"] && [next[@"re"] isEqual:identifier]) return next;
        if ([next[@"type"] isEqual:@"snapshot"]) [_snapshots addObject:next];
        else [_skipped addObject:next];
    }
    return nil;
}

@end
