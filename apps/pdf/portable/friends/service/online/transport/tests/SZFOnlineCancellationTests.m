// Cancellation (-close in every state) and the side path seam, with a scripted TCP path standing in for the NAT
// area's simultaneous-open path.

#import "SZFOnlineTestSupport.h"

static SZFriendsOnlineDataChannelTransport *LoopbackTransport(void) {
    return [[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"];
}

static id<SZFriendsOnlineConnection> OpenOfferer(SZFriendsOnlineDataChannelTransport *transport, SZFORecorder *events,
                                                dispatch_queue_t queue) {
    __block id<SZFriendsOnlineConnection> connection = nil;
    SZFOOnQueue(queue, ^{
        connection = [transport openConnection:[SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend]
                                      delegate:events
                                         queue:queue
                                         error:NULL];
    });
    return connection;
}

static void TestCloseWhileGathering(void) {
    dispatch_queue_t queue = dispatch_queue_create("szfo.cancel", DISPATCH_QUEUE_SERIAL);
    SZFORecorder *events = [SZFORecorder new];
    id<SZFriendsOnlineConnection> connection = OpenOfferer(LoopbackTransport(), events, queue);
    SZFO_CHECK(connection != nil);
    __block NSUInteger cleanups = 0;
    SZFOOnQueue(queue, ^{
        id<SZFriendsOnlineConnectionExtras> extras = (id<SZFriendsOnlineConnectionExtras>)connection;
        [extras addCleanup:^{
            cleanups++;
        }];
        events.closedByTest = YES;
        [connection close];
        [connection close]; // idempotent
        SZFO_CHECK(cleanups == 1, "cleanups run on close, once");
        [extras addCleanup:^{
            cleanups++;
        }];
        SZFO_CHECK(cleanups == 2, "and at once when already closed");
        NSError *error = nil;
        SZFO_CHECK(![connection applyRemoteAnswerSDP:@"v=0" remoteFingerprint:SZFOBytes(1, 32) error:&error]);
    });
    usleep(500000); // what the stack had in flight
    SZFOOnQueue(queue, ^{
        SZFO_CHECK(events.eventsAfterClose == 0, "nothing reaches the delegate after -close: %@", events.events);
    });

    // Dropped without -close: the stack's resources still go, silently.
    @autoreleasepool {
        SZFORecorder *dropped = [SZFORecorder new];
        __block id<SZFriendsOnlineConnection> lost = OpenOfferer(LoopbackTransport(), dropped, queue);
        SZFO_CHECK(lost != nil);
        lost = nil;
    }
    usleep(200000);
}

static void TestCloseWithOpenStreams(void) {
    SZFOPair *pair = [[SZFOPair alloc] initWithTransport:LoopbackTransport()
                                                 purpose:SZFriendsOnlinePurposeFriend
                                                    kind:SZFriendsOnlineConnectionDirect];
    SZFO_CHECK([pair start] && [pair waitForStreams]);
    __block NSUInteger offererCloses = 0, answererCloses = 0;
    __block NSError *offererError = (id)@"unset", *answererError = (id)@"unset";
    SZFOOnQueue(pair.offererQueue, ^{
        id<SZFriendsByteStream> stream = pair.offererEvents.streams.firstObject;
        stream.onClose = ^(NSError *error) {
            offererCloses++;
            offererError = error;
        };
        [stream startWithQueue:pair.offererQueue];
    });
    SZFOOnQueue(pair.answererQueue, ^{
        id<SZFriendsByteStream> stream = pair.answererEvents.streams.firstObject;
        stream.onClose = ^(NSError *error) {
            answererCloses++;
            answererError = error;
        };
        [stream startWithQueue:pair.answererQueue];
    });
    // The person cancelled, or a better route won: close everything this attempt started.
    SZFOOnQueue(pair.offererQueue, ^{
        pair.offererEvents.closedByTest = YES;
        [pair.offerer close];
    });
    SZFO_CHECK(SZFOWaitUntil(pair.offererQueue, 2, ^BOOL {
        return offererCloses == 1;
    }) && offererError == nil, "the open stream's onClose runs with no error");
    SZFO_CHECK(SZFOWaitUntil(pair.answererQueue, 10, ^BOOL {
        return pair.answererEvents.error != nil;
    }), "the far side learns the peer closed");
    SZFOOnQueue(pair.answererQueue, ^{
        SZFO_CHECK(pair.answererEvents.error.code == SZFriendsOnlineErrorPeerClosed, "%@", pair.answererEvents.error);
        SZFO_CHECK(answererCloses == 1, "its stream closed too");
        (void)answererError;
    });
    SZFOOnQueue(pair.offererQueue, ^{
        SZFO_CHECK(pair.offererEvents.eventsAfterClose == 0);
        SZFO_CHECK(pair.offerer.route.method == SZFriendsRouteMethodNone, "no open path after close");
    });
    [pair close];
}

// A refused answer fails the attempt, told after -apply... returns (never from inside it), and not at all once the
// owner has closed the connection.
static void TestRefusedAnswer(void) {
    dispatch_queue_t queue = dispatch_queue_create("szfo.answer", DISPATCH_QUEUE_SERIAL);
    SZFORecorder *events = [SZFORecorder new];
    id<SZFriendsOnlineConnection> connection = OpenOfferer(LoopbackTransport(), events, queue);
    __block BOOL returned = NO;
    SZFOOnQueue(queue, ^{
        NSError *error = nil;
        SZFO_CHECK(![connection applyRemoteAnswerSDP:@"v=0\r\n" remoteFingerprint:SZFOBytes(1, 32) error:&error] &&
                   error.code == SZFriendsOnlineErrorDescriptionInvalid);
        SZFO_CHECK(events.error == nil, "not re-entered from inside the call");
        returned = YES;
    });
    SZFO_CHECK(SZFOWaitUntil(queue, 2, ^BOOL {
        return events.error != nil;
    }) && returned && events.error.code == SZFriendsOnlineErrorDescriptionInvalid);

    SZFORecorder *closing = [SZFORecorder new];
    id<SZFriendsOnlineConnection> closed = OpenOfferer(LoopbackTransport(), closing, queue);
    SZFOOnQueue(queue, ^{
        [closed applyRemoteAnswerSDP:@"v=0\r\n" remoteFingerprint:SZFOBytes(1, 32) error:NULL];
        [closed close];
    });
    usleep(200000);
    SZFOOnQueue(queue, ^{
        SZFO_CHECK(closing.error == nil, "nothing after -close, not even the failure it raced");
    });
}

void SZFORunCancellationTests(void) {
    TestRefusedAnswer();
    TestCloseWhileGathering();
    TestCloseWithOpenStreams();
}

#pragma mark - Side path

@interface SZFOFakeStream : NSObject <SZFriendsByteStream>
@end

@implementation SZFOFakeStream
@synthesize onData = _onData;
@synthesize onClose = _onClose;
- (NSUInteger)preferredWriteSize {
    return 65536;
}
- (void)startWithQueue:(dispatch_queue_t)queue {
    (void)queue;
}
- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    (void)data;
    if (completion) completion(nil);
}
- (void)close {
}
@end

@interface SZFOFakeSidePath : NSObject <SZFriendsOnlineSidePath>
@property(nonatomic, weak) id<SZFriendsOnlineSidePathEvents> events;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) NSUInteger starts, closes;
@property(nonatomic) NSMutableArray<NSString *> *remote;
@end

@implementation SZFOFakeSidePath
- (void)startWithQueue:(dispatch_queue_t)queue events:(id<SZFriendsOnlineSidePathEvents>)events {
    self.starts++;
    self.queue = queue;
    self.events = events;
    self.remote = [NSMutableArray array];
    [events sidePath:self didGatherLocalCandidate:@"candidate:9 1 TCP 2105458943 127.0.0.1 9000 typ host tcptype so"];
    [events sidePath:self didGatherLocalCandidate:@"candidate:8 1 UDP 2105458943 127.0.0.1 9000 typ host"]; // not TCP
}
- (BOOL)addRemoteCandidate:(NSString *)candidate error:(NSError **)error {
    (void)error;
    [self.remote addObject:candidate];
    return YES;
}
- (void)close {
    self.closes++;
}
@end

void SZFORunSidePathTests(void) {
    SZFriendsOnlineDataChannelTransport *transport = LoopbackTransport();
    NSMutableArray<SZFOFakeSidePath *> *paths = [NSMutableArray array];
    transport.sidePathFactory = ^id<SZFriendsOnlineSidePath>(id<SZFriendsOnlineConnectionRequest> request) {
        SZFO_CHECK(request.kind == SZFriendsOnlineConnectionDirect, "direct connections only");
        SZFOFakeSidePath *path = [SZFOFakeSidePath new];
        [paths addObject:path];
        return path;
    };
    SZFOPair *pair = [[SZFOPair alloc] initWithTransport:transport
                                                 purpose:SZFriendsOnlinePurposeFriend
                                                    kind:SZFriendsOnlineConnectionDirect];
    SZFO_CHECK([pair start] && [pair waitForStreams]);
    SZFO_CHECK(paths.count == 2);
    SZFOFakeSidePath *offererPath = paths.firstObject, *answererPath = paths.lastObject;
    SZFOOnQueue(pair.answererQueue, ^{
        SZFO_CHECK(answererPath.starts == 1 && answererPath.remote.count == 1 &&
                   [answererPath.remote.firstObject hasSuffix:@"tcptype so"],
                   "the offerer's TCP endpoint reached the answerer's path: %@", answererPath.remote);
    });
    SZFOOnQueue(pair.offererQueue, ^{
        NSUInteger index = [pair.offererEvents.techniques indexOfObject:@(SZFriendsOnlineTechniqueTCPSimultaneousOpen)];
        SZFO_CHECK(index != NSNotFound && [pair.offererEvents.candidates[index] containsString:@" TCP "],
                   "sent with its technique, and only the TCP one");
        SZFO_CHECK(pair.offererEvents.candidates.count == pair.offererEvents.techniques.count);
        // The TCP path connects too: its stream is a second session, reported as such.
        SZFOFakeStream *tcp = [SZFOFakeStream new];
        [offererPath.events sidePath:offererPath didOpenStream:tcp ipv6:YES];
        SZFO_CHECK(pair.offererEvents.streams.count == 2 && pair.offererEvents.streams.lastObject == tcp);
        SZFO_CHECK(pair.offererEvents.openedRoute.technique == SZFriendsOnlineTechniqueTCPSimultaneousOpen &&
                   pair.offererEvents.openedRoute.method == SZFriendsRouteMethodInternet &&
                   pair.offererEvents.openedRoute.ipv6);
        // The TCP path ending leaves the data channel running: the connection lives while one path does.
        [offererPath.events sidePath:offererPath didFailWithError:SZFriendsOnlineMakeError(5, @"budget")];
        SZFO_CHECK(pair.offererEvents.error == nil && pair.offerer.route.method == SZFriendsRouteMethodInternet);
        [pair.offerer close];
        SZFO_CHECK(offererPath.closes == 1, "closing the connection closes its TCP path");
    });
    [pair close];
    SZFOOnQueue(pair.answererQueue, ^{
        SZFO_CHECK(answererPath.closes == 1);
    });
}
