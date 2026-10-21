// The two-helper harness (SZFriendsE2EHarness.h).

#import "SZFriendsE2EHarness.h"

#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

#import "client/szfriends_client.h"

int SZFE2EFailures = 0;
static NSMutableSet<NSNumber *> *SZFE2ESpawned;
static NSHashTable<SZFE2EClient *> *SZFE2EClients;

void SZFE2EFail(const char *file, int line, const char *condition, NSString *detail) {
    SZFE2EFailures++;
    fprintf(stderr, "%s:%d: expected %s %s\n", file, line, condition, detail.UTF8String);
}

static void SZFE2EKillLeftovers(void) {
    for (NSNumber *pid in SZFE2ESpawned) kill(pid.intValue, SIGKILL);
}

void SZFE2ETrackPID(pid_t pid) {
    [SZFE2ESpawned addObject:@(pid)];
}

void SZFE2EUntrackPID(pid_t pid) {
    [SZFE2ESpawned removeObject:@(pid)];
}

#pragma mark - Helpers

@interface SZFE2EHelper ()
@property(nonatomic, copy) NSString *executable;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *baseEnvironment;
@end

@implementation SZFE2EHelper

- (instancetype)initWithName:(NSString *)name state:(NSString *)state {
    if ((self = [super init])) {
        _name = [name copy];
        _stateDirectory = [state copy];
        _downloadsDirectory = [state stringByAppendingString:@"-Downloads"];
        _extraEnvironment = @{};
        _pid = -1;
    }
    return self;
}

- (BOOL)start {
    if ([self isRunning]) return YES;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.stateDirectory withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    NSMutableDictionary *env = [self.baseEnvironment mutableCopy];
    [env addEntriesFromDictionary:self.extraEnvironment];
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSString *key in env) [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, env[key]]];
    char **envp = calloc(pairs.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < pairs.count; i++) envp[i] = strdup(pairs[i].UTF8String);
    NSString *log = [self.stateDirectory stringByAppendingPathComponent:@"helper.log"];
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, log.fileSystemRepresentation,
                                     O_WRONLY | O_CREAT | O_APPEND, 0600);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    // No descriptor of the runner leaks into a helper (a client socket's other end would keep it alive).
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t pid = -1;
    const char *argv[] = {self.executable.fileSystemRepresentation, NULL};
    int result = posix_spawn(&pid, argv[0], &actions, &attributes, (char **)argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    for (NSUInteger i = 0; i < pairs.count; i++) free(envp[i]);
    free(envp);
    if (result != 0) return NO;
    _pid = pid;
    [SZFE2ESpawned addObject:@(pid)];
    return YES;
}

- (BOOL)reap:(BOOL)block {
    if (_pid <= 0) return YES;
    int status = 0;
    pid_t done = waitpid(_pid, &status, block ? 0 : WNOHANG);
    if (done != _pid) return NO;
    // Forgotten at once: a reaped pid can be reused by an unrelated process, which must never be signalled.
    [SZFE2ESpawned removeObject:@(_pid)];
    _pid = -1;
    return YES;
}

- (BOOL)isRunning {
    return _pid > 0 && ![self reap:NO];
}

- (void)kill9 {
    if (_pid <= 0) return;
    kill(_pid, SIGKILL);
    [self reap:YES];
}

- (BOOL)terminate {
    if (_pid <= 0) return YES;
    kill(_pid, SIGTERM);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (deadline.timeIntervalSinceNow > 0) {
        if ([self reap:NO]) return YES;
        SZFE2EPump(0.02); // clients keep reading, so goodbyes are received
    }
    [self kill9];
    return NO;
}

- (NSString *)log {
    NSString *path = [self.stateDirectory stringByAppendingPathComponent:@"helper.log"];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"(no log)";
}

@end

#pragma mark - Clients

@interface SZFE2EClient ()
- (void)receivedFrame:(NSDictionary *)frame;
- (void)changedState:(szfriends_connection_state)state;
@property(nonatomic, readonly) szfriends_client *client;
@end

static void SZFE2EOnFrame(void *context, const char *json, size_t length) {
    NSData *data = [NSData dataWithBytes:json length:length];
    id frame = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([frame isKindOfClass:[NSDictionary class]]) [(__bridge SZFE2EClient *)context receivedFrame:frame];
}

static void SZFE2EOnState(void *context, szfriends_connection_state state) {
    [(__bridge SZFE2EClient *)context changedState:state];
}

@implementation SZFE2EClient {
    NSMutableDictionary<NSString *, NSDictionary *> *_replies;
    NSMutableDictionary<NSString *, NSDictionary *> *_latest;
}

+ (nullable instancetype)clientForHelper:(SZFE2EHelper *)helper {
    return [self clientForHelper:helper capabilities:@[ @"drop.files", @"attach.items" ]];
}

+ (nullable instancetype)clientForHelper:(SZFE2EHelper *)helper capabilities:(NSArray<NSString *> *)names {
    return [self clientForHelper:helper appID:@"com.example.friends-e2e" appName:@"Friends Test" urlScheme:nil
                    capabilities:names];
}

+ (nullable instancetype)clientForHelper:(SZFE2EHelper *)helper
                                   appID:(NSString *)appID
                                 appName:(NSString *)appName
                               urlScheme:(nullable NSString *)urlScheme
                            capabilities:(NSArray<NSString *> *)names {
    SZFE2EClient *client = [[self alloc] init];
    client->_replies = [NSMutableDictionary dictionary];
    client->_latest = [NSMutableDictionary dictionary];
    client->_goodbyes = [NSMutableArray array];
    const char *capabilities[8] = {NULL};
    NSUInteger capabilityCount = MIN(names.count, (NSUInteger)8);
    for (NSUInteger i = 0; i < capabilityCount; i++) capabilities[i] = names[i].UTF8String;
    static const char *formats[] = {"pdf", "txt"};
    szfriends_client_config config = {
        .state_dir = helper.stateDirectory.fileSystemRepresentation,
        .helper_path = NULL, // the harness starts and kills helpers itself
        .app_id = appID.UTF8String,
        .app_name = appName.UTF8String,
        .app_version = "1",
        .toolkit = "appkit",
        .reveal_in = "Finder",
        .locale = "en-GB",
        .capabilities = capabilities,
        .capability_count = capabilityCount,
        .open_formats = formats,
        .open_format_count = 2,
        .on_frame = SZFE2EOnFrame,
        .on_state = SZFE2EOnState,
        .context = (__bridge void *)client,
        .url_scheme = urlScheme.UTF8String,
    };
    client->_client = szfriends_client_new(&config);
    if (client->_client == NULL) return nil;
    [SZFE2EClients addObject:client];
    szfriends_client_start(client->_client);
    return [client waitReady] ? client : nil;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    if (_client == NULL) return;
    [SZFE2EClients removeObject:self];
    szfriends_client_stop(_client, false);
    szfriends_client_free(_client);
    _client = NULL;
}

- (BOOL)ready {
    return _client != NULL && szfriends_client_state(_client) == SZFRIENDS_CONNECTION_READY;
}

- (BOOL)waitReady {
    return SZFE2EWaitUntil(10, ^BOOL { return self.ready; });
}

- (void)changedState:(szfriends_connection_state)state {
    (void)state;
}

- (void)receivedFrame:(NSDictionary *)frame {
    NSString *type = frame[@"type"];
    if ([type isEqual:@"reply"] && [frame[@"re"] isKindOfClass:[NSString class]]) {
        _replies[frame[@"re"]] = frame;
    } else if ([type isEqual:@"snapshot"] && [frame[@"subscription"] isKindOfClass:[NSString class]]) {
        _latest[frame[@"subscription"]] = frame[@"data"];
    } else if ([type isEqual:@"welcome"]) {
        _welcome = frame;
        [_latest removeAllObjects]; // subscription ids never survive a reconnect
    } else if ([type isEqual:@"goodbye"]) {
        [_goodbyes addObject:frame];
    }
}

- (nullable NSDictionary *)intent:(NSString *)type fields:(nullable NSDictionary *)fields {
    if (![self waitReady]) return nil;
    NSString *json = nil;
    if (fields.count > 0) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:fields options:0 error:NULL];
        json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    char identifier[32] = {0};
    if (szfriends_client_send(_client, type.UTF8String, json.UTF8String, identifier, sizeof(identifier)) !=
        SZFRIENDS_OK) {
        return nil;
    }
    NSString *key = @(identifier);
    SZFE2EWaitUntil(10, ^BOOL { return self->_replies[key] != nil; });
    NSDictionary *reply = _replies[key];
    [_replies removeObjectForKey:key];
    return reply;
}

- (nullable NSString *)subscribe:(NSString *)view params:(nullable NSDictionary *)params {
    NSMutableDictionary *fields = [@{@"view" : view} mutableCopy];
    if (params != nil) fields[@"params"] = params;
    NSDictionary *reply = [self intent:@"subscribe" fields:fields];
    return reply[@"result"][@"subscription"];
}

- (nullable NSString *)openConversation:(NSString *)conversationID {
    NSDictionary *reply = [self intent:@"open_conversation" fields:@{@"conversation_id" : conversationID}];
    return reply[@"result"][@"subscription"];
}

- (nullable NSDictionary *)dataFor:(NSString *)subscription {
    return subscription ? _latest[subscription] : nil;
}

@end

void SZFE2EPump(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        NSArray<SZFE2EClient *> *clients = SZFE2EClients.allObjects;
        struct pollfd fds[64];
        SZFE2EClient *owners[64];
        nfds_t count = 0;
        for (SZFE2EClient *client in clients) {
            int fd = client.client ? szfriends_client_fd(client.client) : -1;
            if (fd < 0 || count == 64) continue;
            owners[count] = client;
            fds[count++] = (struct pollfd){.fd = fd, .events = POLLIN};
        }
        int wait = (int)MAX(0, MIN(20, deadline.timeIntervalSinceNow * 1000));
        if (count > 0) poll(fds, count, wait);
        else usleep((useconds_t)wait * 1000);
        // Read only what poll says is readable, as a host's run loop would.
        for (nfds_t i = 0; i < count; i++) {
            if ((fds[i].revents & (POLLIN | POLLHUP | POLLERR)) && owners[i].client != NULL &&
                szfriends_client_fd(owners[i].client) == fds[i].fd) {
                szfriends_client_on_readable(owners[i].client);
            }
        }
        uint64_t now = szfriends_monotonic_ms();
        for (SZFE2EClient *client in clients) {
            if (client.client != NULL) szfriends_client_tick(client.client, now);
        }
    } while (deadline.timeIntervalSinceNow > 0);
}

BOOL SZFE2EWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        SZFE2EPump(0.02);
    }
    return YES;
}

#pragma mark - World

@implementation SZFE2EWorld {
    NSString *_executable;
    NSString *_manifest;
    NSString *_root;
    NSMutableArray<SZFE2EHelper *> *_helpers;
}

- (instancetype)initWithExecutable:(NSString *)executable manifest:(NSString *)manifest root:(NSString *)root {
    if ((self = [super init])) {
        _executable = [executable copy];
        _manifest = [manifest copy];
        _root = [root copy];
        _helpers = [NSMutableArray array];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            SZFE2ESpawned = [NSMutableSet set];
            SZFE2EClients = [NSHashTable weakObjectsHashTable];
            atexit(SZFE2EKillLeftovers);
        });
    }
    return self;
}

- (void)beginScenario:(NSString *)name {
    _scenarioDirectory = [_root stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:_scenarioDirectory withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    // A new type per scenario: helpers of an earlier scenario still winding down can never be found. A test joined to
    // another network through a bridge (the phone tests) names the type the bridge uses.
    const char *given = getenv("SZFRIENDS_E2E_SERVICE_TYPE");
    _serviceType = given && *given ? @(given) : [NSString stringWithFormat:@"_szfe%08x._tcp", arc4random()];
    _bluetoothDirectory = [_scenarioDirectory stringByAppendingPathComponent:@"bt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:_bluetoothDirectory withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
}

- (void)printLogs {
    for (SZFE2EHelper *helper in _helpers) {
        NSArray<NSString *> *lines = [helper.log componentsSeparatedByString:@"\n"];
        NSUInteger keep = MIN(lines.count, (NSUInteger)60);
        NSArray *tail = [lines subarrayWithRange:NSMakeRange(lines.count - keep, keep)];
        fprintf(stderr, "--- %s helper log (last %lu lines)\n%s\n", helper.name.UTF8String, (unsigned long)keep,
                [tail componentsJoinedByString:@"\n"].UTF8String);
    }
}

- (void)endScenario {
    for (SZFE2EClient *client in SZFE2EClients.allObjects) [client close];
    for (SZFE2EHelper *helper in _helpers) [helper kill9];
    [_helpers removeAllObjects];
}

- (SZFE2EHelper *)helperNamed:(NSString *)name {
    SZFE2EHelper *helper = [[SZFE2EHelper alloc] initWithName:name
                                                        state:[_scenarioDirectory stringByAppendingPathComponent:name]];
    helper.executable = _executable;
    helper.baseEnvironment = @{
        @"SZFRIENDS_STATE_DIR" : helper.stateDirectory,
        @"SZFRIENDS_DOWNLOADS_DIR" : helper.downloadsDirectory,
        @"SZFRIENDS_KEY_STORE" : @"file",
        @"SZFRIENDS_TEST_SERVICE_TYPE" : _serviceType,
        @"SZFRIENDS_AVATARS_MANIFEST" : _manifest,
        @"HOME" : NSHomeDirectory(),
        @"PATH" : @"/usr/bin:/bin",
        @"TMPDIR" : NSTemporaryDirectory(),
    };
    [_helpers addObject:helper];
    return helper;
}

- (NSString *)fileOfSize:(NSUInteger)size named:(NSString *)name {
    NSMutableData *data = [NSMutableData dataWithLength:size];
    arc4random_buf(data.mutableBytes, size);
    NSString *path = [_scenarioDirectory stringByAppendingPathComponent:name];
    [data writeToFile:path atomically:YES];
    return path;
}

@end
