// The helper's Unix socket server: bind under helper.lock, check each peer, run the hello and route intents.
//
// PROTOCOL.md § Transport, § Framing, § Handshake and § Replies and errors are the contract. Protocol errors
// (not JSON, no usable type or id, a frame over the cap) end the connection with a goodbye; a well-formed frame
// with a bad field gets an error reply and the connection stays open.

#import "service/helper/SZFriendsIPCPrivate.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

#import "client/szfriends_client.h"

static const NSUInteger SZFriendsIPCMaxConnections = 64; // PROTOCOL.md § Limits
static const NSUInteger SZFriendsIPCMaxOutstandingIntents = 64;
// A peer's code-signing check normally takes a few milliseconds. One still running after this long is abandoned and
// only that connection is refused, so a stalled check never holds up the helper or the clients behind it.
static const int64_t SZFriendsIPCPeerCheckLimitMs = 1000;
// Checks still running in the background (each may hold a thread while it waits on trustd); past this, a new
// connection is refused at once rather than adding another.
static const NSUInteger SZFriendsIPCMaxRunningPeerChecks = 8;
// This many checks in a row over the limit: this process cannot check its clients any more, so it steps aside and a
// fresh helper takes over.
static const NSUInteger SZFriendsIPCStalledChecksBeforeStepAside = 2;
static char SZFriendsIPCQueueKey;

static NSDictionary<NSString *, id> *SZFriendsErrorObject(NSString *code, id _Nullable message,
                                                          NSDictionary *_Nullable details) {
    // The codes a client may retry unchanged; PROTOCOL.md § Replies and errors.
    static NSSet<NSString *> *retryable;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        retryable = [NSSet setWithArray:@[ @"rate_limited", @"disk_full", @"internal", @"not_ready" ]];
    });
    return @{
        @"code" : code,
        @"message" : message ?: [NSNull null],
        @"retryable" : @([retryable containsObject:code]),
        @"details" : details ?: @{},
    };
}

static NSDictionary<NSString *, id> *SZFriendsErrorReply(NSString *re, NSString *code, id _Nullable message,
                                                         NSDictionary *_Nullable details) {
    return @{@"type" : @"reply", @"re" : re, @"ok" : @NO, @"error" : SZFriendsErrorObject(code, message, details)};
}

static BOOL SZFriendsParseVersion(id object, BOOL withMinMajor, SZFriendsProtocolVersion *version,
                                  NSInteger *minMajor) {
    if (![object isKindOfClass:[NSDictionary class]]) return NO;
    id major = object[@"major"], minor = object[@"minor"], min = object[@"min_major"];
    if (!SZFriendsJSONIsInteger(major) || !SZFriendsJSONIsInteger(minor)) return NO;
    if (withMinMajor && !SZFriendsJSONIsInteger(min)) return NO;
    *version = (SZFriendsProtocolVersion){.major = [major integerValue], .minor = [minor integerValue]};
    if (minMajor) *minMajor = withMinMajor ? [min integerValue] : version->major;
    return YES;
}

@implementation SZFriendsIPCServer {
    SZFriendsStatePaths *_paths;
    dispatch_queue_t _queue;
    int _listenFD;
    dispatch_source_t _acceptSource;
    NSMutableArray<SZFriendsIPCConnection *> *_connections;
    uint64_t _nextConnection;
    BOOL _bound;
    BOOL _teamResolved;
    BOOL _handoverScheduled;
    dispatch_queue_t _peerCheckQueue;
    NSUInteger _runningPeerChecks;      // checks not yet returned, abandoned ones included (helper queue)
    NSUInteger _stalledPeerChecksInRow; // checks over the limit since the last one that finished in time
}

- (instancetype)initWithPaths:(SZFriendsStatePaths *)paths queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _paths = paths;
        _queue = queue;
        _listenFD = -1;
        _connections = [NSMutableArray array];
        _peerCheckQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        // Lets a reply tell whether it already runs on the helper queue.
        dispatch_queue_set_specific(queue, &SZFriendsIPCQueueKey, &SZFriendsIPCQueueKey, NULL);
    }
    return self;
}

- (NSArray<SZFriendsIPCConnection *> *)connections {
    return [_connections copy];
}

#pragma mark - Listening

- (BOOL)startWithError:(NSError **)error {
    const char *path = _paths.socketPath.fileSystemRepresentation;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (_paths.socketPath.length == 0 || strlen(path) >= sizeof(address.sun_path)) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENAMETOOLONG userInfo:nil];
        return NO;
    }
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    // Only the holder of helper.lock reaches this line, so a socket file here is a leftover of a helper that
    // died; removing it cannot take a live helper's socket away.
    unlink(path);
    // The socket file is created 0600 from the start rather than chmod-ed after bind, so there is no moment
    // when another user could connect.
    mode_t previousMask = umask(0077);
    int bound = bind(fd, (struct sockaddr *)&address, (socklen_t)SUN_LEN(&address));
    int bindErrno = errno;
    umask(previousMask);
    if (bound != 0 || listen(fd, 128) != 0) {
        int saved = bound != 0 ? bindErrno : errno;
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil];
        return NO;
    }
    _listenFD = fd;
    _bound = YES;
    // Read now, while the bundle is surely in place: an updater may delete it later, and a team-signed helper that
    // could no longer read its own team would fall back to the uid check.
    [self resolvedTeam];
    __weak SZFriendsIPCServer *weakSelf = self;
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(_acceptSource, ^{ [weakSelf acceptPending]; });
    dispatch_source_set_cancel_handler(_acceptSource, ^{ close(fd); });
    dispatch_resume(_acceptSource);
    return YES;
}

- (void)stopAccepting {
    if (_acceptSource != nil) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
        _listenFD = -1;
    }
    // Unlinked while this helper still holds the lock: connecting clients get ENOENT at once and spawn, and the
    // spawned helper waits its turn on the lock instead of finding a socket nobody answers.
    if (_bound) {
        unlink(_paths.socketPath.fileSystemRepresentation);
        _bound = NO;
    }
}

- (void)stop {
    [self stopAccepting];
    for (SZFriendsIPCConnection *connection in [_connections copy]) [connection closeImmediately];
}

- (nullable NSString *)resolvedTeam {
    if (!_teamResolved) {
        _teamResolved = YES;
        if (_teamIdentifier == nil) _teamIdentifier = SZFriendsOwnTeamIdentifier();
    }
    return _teamIdentifier;
}

- (void)acceptPending {
    for (;;) {
        int fd = accept(_listenFD, NULL, NULL);
        if (fd < 0) return; // EAGAIN: drained; anything else: the next event retries
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        SZFriendsPeerCredentials credentials;
        SZFriendsReadPeerCredentials(fd, &credentials);
        NSString *team = [self resolvedTeam];
        if (team == nil || !SZFriendsPeerUIDAllowed(&credentials, geteuid())) {
            // Ad-hoc and test builds check the uid only, which costs nothing: decided here.
            if (SZFriendsPeerAllowed(&credentials, geteuid(), team, nil)) {
                [self admitDescriptor:fd credentials:credentials];
            } else {
                [self refuseDescriptor:fd pid:credentials.pid];
            }
            continue;
        }
        [self checkSignatureOfDescriptor:fd credentials:credentials team:team];
    }
}

// Closed without a word (PROTOCOL.md § Peer checks): a refused peer learns nothing about Friends.
- (void)refuseDescriptor:(int)fd pid:(pid_t)pid {
    SZFriendsHelperLog(@"refused a connection from pid %d", pid);
    close(fd);
}

// The code-signing check runs on a background queue, never on the helper queue: it waits on trustd, and while it
// waited here no other client could connect, no intent was answered and no signal was handled. The verdict comes
// back to the helper queue; a check over the time limit refuses only its own connection.
- (void)checkSignatureOfDescriptor:(int)fd credentials:(SZFriendsPeerCredentials)credentials team:(NSString *)team {
    if (_runningPeerChecks >= SZFriendsIPCMaxRunningPeerChecks) {
        SZFriendsHelperLog(@"%lu peer checks still running; refused pid %d", (unsigned long)_runningPeerChecks,
                           credentials.pid);
        close(fd);
        return;
    }
    _runningPeerChecks++;
    // Settled once, on the helper queue, by whichever comes first: the verdict or the time limit.
    __block BOOL settled = NO;
    __weak SZFriendsIPCServer *weakSelf = self;
    dispatch_queue_t queue = _queue;
    uid_t uid = geteuid();
    SZFriendsRequirementChecker checker = SZFriendsSecurityRequirementChecker();
    dispatch_async(_peerCheckQueue, ^{
        SZFriendsPeerCredentials peer = credentials;
        BOOL allowed = SZFriendsPeerAllowed(&peer, uid, team, checker);
        dispatch_async(queue, ^{
            SZFriendsIPCServer *strongSelf = weakSelf;
            if (strongSelf != nil) strongSelf->_runningPeerChecks--;
            if (settled) return;
            settled = YES;
            if (strongSelf == nil) {
                close(fd);
                return;
            }
            strongSelf->_stalledPeerChecksInRow = 0;
            if (!allowed) {
                [strongSelf refuseDescriptor:fd pid:credentials.pid];
            } else if (!strongSelf->_bound) {
                close(fd); // stepping aside meanwhile: the client reconnects to the successor
            } else {
                [strongSelf admitDescriptor:fd credentials:credentials];
            }
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SZFriendsIPCPeerCheckLimitMs * (int64_t)NSEC_PER_MSEC), queue, ^{
        if (settled) return;
        settled = YES;
        SZFriendsIPCServer *strongSelf = weakSelf;
        close(fd);
        if (strongSelf == nil) return;
        strongSelf->_stalledPeerChecksInRow++;
        SZFriendsHelperLog(@"the signature check of pid %d took over %lld ms; refused that connection", credentials.pid,
                           SZFriendsIPCPeerCheckLimitMs);
        if (strongSelf->_stalledPeerChecksInRow == SZFriendsIPCStalledChecksBeforeStepAside &&
            strongSelf.onPeerChecksStalled) {
            strongSelf.onPeerChecksStalled();
        }
    });
}

- (void)admitDescriptor:(int)fd credentials:(SZFriendsPeerCredentials)credentials {
    NSString *identifier = [NSString stringWithFormat:@"c%llu", ++_nextConnection];
    SZFriendsIPCConnection *connection = [[SZFriendsIPCConnection alloc] initWithDescriptor:fd
                                                                               connectionID:identifier
                                                                                    peerPID:credentials.pid
                                                                                     server:self
                                                                                      queue:_queue];
    connection.peerCredentials = credentials;
    if (_connections.count >= SZFriendsIPCMaxConnections) {
        [connection start];
        [connection sendGoodbyeWithReason:@"too_many_clients" successor:nil error:nil];
        return;
    }
    [_connections addObject:connection];
    [connection start];
    if (self.onConnectionsChanged) self.onConnectionsChanged(nil);
}

- (void)connectionDidClose:(SZFriendsIPCConnection *)connection {
    if (![_connections containsObject:connection]) return;
    [_connections removeObject:connection];
    [self.intentHandler connectionDidClose:connection];
    if (self.onConnectionsChanged) self.onConnectionsChanged(connection);
}

- (void)broadcastGoodbyeWithReason:(NSString *)reason successor:(nullable NSDictionary<NSString *, id> *)successor {
    for (SZFriendsIPCConnection *connection in [_connections copy]) {
        [connection sendGoodbyeWithReason:reason successor:successor error:nil];
    }
}

#pragma mark - Frames

- (void)protocolError:(NSString *)code
                   on:(SZFriendsIPCConnection *)connection
              details:(nullable NSDictionary *)details {
    SZFriendsHelperLog(@"protocol error %@ on %@", code, connection.connectionID);
    [connection sendGoodbyeWithReason:@"protocol_error" successor:nil error:SZFriendsErrorObject(code, nil, details)];
}

- (void)connectionReceivedOversizedFrame:(SZFriendsIPCConnection *)connection {
    [self protocolError:@"frame_too_large"
                     on:connection
                details:@{@"max_frame_bytes" : @(SZFRIENDS_MAX_FRAME_BYTES)}];
}

- (void)connection:(SZFriendsIPCConnection *)connection didReceiveLine:(NSData *)line {
    NSString *text = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
    // A line of only whitespace (a stray "\r") counts as the empty line PROTOCOL.md says to skip.
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if (text != nil && [text stringByTrimmingCharactersInSet:whitespace].length == 0) return;
    id frame = text != nil ? [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL] : nil;
    if (![frame isKindOfClass:[NSDictionary class]]) {
        [self protocolError:@"bad_frame" on:connection details:nil];
        return;
    }
    NSString *type = frame[@"type"];
    NSString *frameID = frame[@"id"];
    if (!SZFriendsJSONIsString(type) || type.length == 0 || !SZFriendsFrameIDIsValid(frameID)) {
        [self protocolError:@"bad_frame" on:connection details:nil];
        return;
    }
    if (connection.client == nil) {
        if (![type isEqualToString:@"hello"]) {
            [connection sendFrame:SZFriendsErrorReply(frameID, @"hello_required", nil, nil)];
            [self protocolError:@"hello_required" on:connection details:nil];
            return;
        }
        [self handleHello:frame id:frameID on:connection];
        return;
    }
    if ([connection.outstandingIDs containsObject:frameID]) {
        // Two intents with one id would make their replies ambiguous; the id is not usable.
        [self protocolError:@"bad_frame" on:connection details:@{@"field" : @"id"}];
        return;
    }
    if ([type isEqualToString:@"hello"]) {
        [connection sendFrame:SZFriendsErrorReply(frameID, @"not_allowed", nil, nil)];
        return;
    }
    [self handleIntent:frame type:type id:frameID on:connection];
}

- (void)handleHello:(NSDictionary *)hello id:(NSString *)frameID on:(SZFriendsIPCConnection *)connection {
    SZFriendsProtocolVersion clientVersion;
    NSInteger clientMinMajor = 0;
    if (!SZFriendsParseVersion(hello[@"protocol"], YES, &clientVersion, &clientMinMajor)) {
        [connection sendFrame:SZFriendsErrorReply(frameID, @"invalid_field", nil, @{@"field" : @"protocol"})];
        return;
    }
    // The handover request is read before negotiation on purpose: a newer app can always ask an older helper
    // to step aside, even when the two share no protocol major (PROTOCOL.md § Handover request).
    id embedded = hello[@"embedded_helper"];
    if (embedded != nil && embedded != [NSNull null]) {
        SZFriendsProtocolVersion embeddedProtocol;
        id build = [embedded isKindOfClass:[NSDictionary class]] ? embedded[@"build_number"] : nil;
        id version = [embedded isKindOfClass:[NSDictionary class]] ? embedded[@"version"] : nil;
        if (!SZFriendsJSONIsInteger(build) || [build longLongValue] < 0 || !SZFriendsJSONIsString(version) ||
            !SZFriendsParseVersion(embedded[@"protocol"], NO, &embeddedProtocol, NULL)) {
            NSDictionary *details = @{@"field" : @"embedded_helper"};
            [connection sendFrame:SZFriendsErrorReply(frameID, @"invalid_field", nil, details)];
            return;
        }
        uint64_t claimed = [build unsignedLongLongValue];
        if (SZFriendsEmbeddedHelperIsNewer(SZFriendsHelperProtocolVersion(), SZFriendsHelperBuildNumber(),
                                           embeddedProtocol, claimed) &&
            [self connection:connection backsHandoverToBuild:claimed]) {
            _handoverScheduled = YES;
            if (self.onHandoverRequested) self.onHandoverRequested(embedded);
        }
    }
    SZFriendsProtocolVersion negotiated;
    if (!SZFriendsNegotiateProtocol(SZFriendsHelperProtocolVersion(), SZFRIENDS_PROTOCOL_MIN_MAJOR, clientVersion,
                                    clientMinMajor, &negotiated)) {
        NSDictionary *details = @{
            @"helper_major" : @(SZFRIENDS_PROTOCOL_MAJOR),
            @"helper_min_major" : @(SZFRIENDS_PROTOCOL_MIN_MAJOR),
            @"handover" : _handoverScheduled ? @"scheduled" : @"none",
        };
        [connection sendFrame:SZFriendsErrorReply(frameID, @"protocol_unsupported", nil, details)];
        [self protocolError:@"protocol_unsupported" on:connection details:details];
        return;
    }
    NSError *contextError = nil;
    SZFriendsClientContext *context = [SZFriendsClientContext contextFromHello:hello
                                                             negotiatedVersion:negotiated
                                                                         error:&contextError];
    if (context == nil) {
        NSString *field = contextError.userInfo[@"field"] ?: @"client";
        [connection sendFrame:SZFriendsErrorReply(frameID, @"invalid_field", nil, @{@"field" : field})];
        return;
    }
    connection.client = context;
    NSMutableDictionary *welcome = [NSMutableDictionary dictionary];
    if (self.welcomeBuilder) [welcome addEntriesFromDictionary:self.welcomeBuilder(context)];
    if (welcome[@"capabilities"] == nil) welcome[@"capabilities"] = @[];
    if (welcome[@"strings"] == nil) welcome[@"strings"] = @{};
    if (welcome[@"limits"] == nil) {
        welcome[@"limits"] = @{
            @"max_frame_bytes" : @(SZFRIENDS_MAX_FRAME_BYTES),
            @"max_message_bytes" : @32768,
            @"max_files_per_send" : @100,
            @"max_subscriptions" : @32,
        };
    }
    // The frozen fields are the server's to fill, whatever the builder returned.
    SZFriendsProtocolVersion own = SZFriendsHelperProtocolVersion();
    welcome[@"type"] = @"welcome";
    welcome[@"re"] = frameID;
    welcome[@"protocol"] = @{@"major" : @(negotiated.major), @"minor" : @(negotiated.minor)};
    welcome[@"helper"] = @{
        @"version" : SZFriendsHelperVersionString(),
        @"build_number" : @(SZFriendsHelperBuildNumber()),
        @"protocol" : @{@"major" : @(own.major), @"minor" : @(own.minor)},
        @"pid" : @(getpid()),
    };
    welcome[@"handover"] = _handoverScheduled ? @"scheduled" : @"none";
    [connection sendFrame:welcome];
}

// A handover is granted only for a build that could follow ours and that the asking app really carries: its own
// bundle embeds that build, which it will start once we are gone. A hello naming any other build is answered as if
// it named ours (handover "none"), so no client can make Friends step aside for a successor that never comes.
- (BOOL)connection:(SZFriendsIPCConnection *)connection backsHandoverToBuild:(uint64_t)claimed {
    if (!SZFriendsHandoverBuildIsPlausible(SZFriendsHelperBuildNumber(), claimed)) {
        SZFriendsHelperLog(@"handover refused: build %llu is not one that could follow %llu", claimed,
                           SZFriendsHelperBuildNumber());
        return NO;
    }
    SZFriendsPeerCredentials credentials = connection.peerCredentials;
    if (![SZFriendsEmbeddedHelperBuildsOfApp(SZFriendsPeerExecutablePath(&credentials)) containsObject:@(claimed)]) {
        SZFriendsHelperLog(@"handover refused: the asking app does not carry build %llu", claimed);
        return NO;
    }
    return YES;
}

- (void)handleIntent:(NSDictionary *)intent type:(NSString *)type id:(NSString *)frameID
                  on:(SZFriendsIPCConnection *)connection {
    [connection.outstandingIDs addObject:frameID];
    // PROTOCOL.md § Limits: past 64 unanswered intents the helper stops reading until it has replied.
    if (connection.outstandingIDs.count >= SZFriendsIPCMaxOutstandingIntents) [connection pauseReading];
    __block BOOL replied = NO;
    __weak SZFriendsIPCConnection *weakConnection = connection;
    dispatch_queue_t queue = _queue;
    SZFriendsIntentReply reply = ^(NSDictionary *result, NSString *code, NSString *message, NSDictionary *details) {
        dispatch_block_t send = ^{
            if (replied) {
                SZFriendsHelperLog(@"second reply to a %@ intent ignored", type);
                return;
            }
            replied = YES;
            SZFriendsIPCConnection *strongConnection = weakConnection;
            if (strongConnection == nil) return;
            [strongConnection.outstandingIDs removeObject:frameID];
            if (code != nil) {
                [strongConnection sendFrame:SZFriendsErrorReply(frameID, code, message, details)];
            } else {
                [strongConnection
                    sendFrame:@{@"type" : @"reply", @"re" : frameID, @"ok" : @YES, @"result" : result ?: @{}}];
            }
            if (strongConnection.outstandingIDs.count < SZFriendsIPCMaxOutstandingIntents) {
                [strongConnection resumeReading];
            }
        };
        // Handlers reply on the helper queue; a reply from elsewhere hops there so frames never interleave.
        if (dispatch_get_specific(&SZFriendsIPCQueueKey) == &SZFriendsIPCQueueKey) {
            send();
        } else {
            dispatch_async(queue, send);
        }
    };
    id<SZFriendsIntentHandler> handler = self.intentHandler;
    if (handler == nil) {
        reply(nil, @"internal", nil, nil);
        return;
    }
    [handler connection:connection handleIntent:intent reply:reply];
}

@end
