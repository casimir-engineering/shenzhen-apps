// Links suite support (SZFLinksTestSupport.h) and its entry point.

#import "SZFLinksTestSupport.h"

#import <sodium.h>

int SZFLFailures = 0;
static NSString *SZFLRoot;

void SZFLFail(const char *file, int line, const char *expression, NSString *detail) {
    SZFLFailures++;
    fprintf(stderr, "%s:%d: FAILED %s %s\n", file, line, expression, detail.UTF8String);
}

BOOL SZFLWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

void SZFLSpin(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    SZFLWaitUntil(seconds + 1, ^BOOL { return until.timeIntervalSinceNow <= 0; });
}

NSString *SZFLTemporaryDirectory(NSString *label) {
    if (SZFLRoot == nil) {
        char pattern[] = "/tmp/szfl.XXXXXX";
        SZFLRoot = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:mkdtemp(pattern)
                                                                                length:strlen(pattern)];
    }
    NSString *path = [SZFLRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", label,
                                                                                         [NSUUID UUID].UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    return [path stringByResolvingSymlinksInPath];
}

void SZFLRemoveTemporaryRoot(void) {
    if (SZFLRoot) [[NSFileManager defaultManager] removeItemAtPath:SZFLRoot error:NULL];
}

NSData *SZFLRandom(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    randombytes_buf(data.mutableBytes, length);
    return data;
}

@implementation SZFLChannel

@synthesize onPayload = _onPayload;
@synthesize onEnd = _onEnd;
@synthesize ended = _ended;

+ (NSArray<SZFLChannel *> *)pair {
    SZFLChannel *a = [SZFLChannel new], *b = [SZFLChannel new];
    a.peer = b;
    b.peer = a;
    return @[ a, b ];
}

- (BOOL)sendPayload:(NSData *)payload {
    if (_ended || payload.length == 0 || payload.length > 4096) return NO;
    self.sent += 1;
    SZFLChannel *peer = self.peer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!peer.ended && peer.onPayload) peer.onPayload(payload);
    });
    return YES;
}

- (void)close {
    if (_ended) return;
    _ended = YES;
    SZFLChannel *peer = self.peer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (peer == nil || peer.ended) return;
        peer->_ended = YES;
        if (peer.onEnd) peer.onEnd();
    });
}

- (void)requestRelayCredentials:(void (^)(id<SZFriendsOnlineRelayCredentials>, NSError *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, [NSError errorWithDomain:SZFriendsOnlineErrorDomain code:SZFriendsOnlineErrorRelayRefused
                                        userInfo:nil]);
    });
}

@end

@implementation SZFLCountingTransport {
    id<SZFriendsOnlineTransport> _inner;
}

- (instancetype)initWithTransport:(id<SZFriendsOnlineTransport>)transport {
    if ((self = [super init])) _inner = transport;
    return self;
}

- (id<SZFriendsOnlineConnection>)openConnection:(id<SZFriendsOnlineConnectionRequest>)request
                                       delegate:(id<SZFriendsOnlineConnectionDelegate>)delegate
                                          queue:(dispatch_queue_t)queue
                                          error:(NSError **)error {
    _opened += 1;
    if (request.role == SZFriendsOnlineRoleAnswerer) _openedBySender += 1;
    id<SZFriendsOnlineConnection> connection = [_inner openConnection:request delegate:delegate queue:queue
                                                                error:error];
    if (connection != nil) {
        if (_connections == nil) _connections = [NSMutableArray array];
        [_connections addObject:connection];
    }
    return connection;
}

@end

@implementation SZFLSink

- (instancetype)init {
    if ((self = [super init])) {
        _bytes = [NSMutableData data];
        _stopped = -1;
    }
    return self;
}

- (BOOL)linkDidReceiveMetadata:(SZFriendsLinkMetadata *)metadata {
    self.metadata = metadata;
    return YES;
}

- (BOOL)linkDidReceiveBytes:(NSData *)bytes atOffset:(uint64_t)offset {
    if (offset != _bytes.length) return NO;
    [_bytes appendData:bytes];
    return YES;
}

- (BOOL)linkDidFinish {
    self.finished = YES;
    return YES;
}

- (void)linkDidStop:(SZFriendsLinkOutcome)outcome {
    self.stopped = outcome;
}

@end

id<SZFriendsOnlineTransport> SZFLLoopbackTransport(void) {
    static SZFriendsOnlineDataChannelTransport *transport;
    if (transport == nil) {
        transport = [[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"];
    }
    return transport;
}

SZFriendsLinkEnvironment *SZFLEnvironment(id<SZFriendsOnlineTransport> transport) {
    SZFriendsLinkEnvironment *environment = [[SZFriendsLinkEnvironment alloc] init];
    environment.transport = transport;
    environment.queue = dispatch_get_main_queue();
    environment.answerTimeout = 3;
    environment.directTimeout = 5;
    environment.setupTimeout = 8;
    return environment;
}

int main(void) {
    @autoreleasepool {
        if (sodium_init() < 0) return 1;
        SZFriendsOnlineTestLinksUseLocalAddresses = YES; // both ends on this Mac's loopback
        SZFLRunWireTests();
        SZFLRunPageVectorTests();
        SZFLRunSourceTests();
        SZFLRunStoreTests();
        SZFLRunExchangeTests();
        SZFLRunReceiveTests();
        SZFLRunServingTests();
        SZFLRunResumeTests();
        SZFLRunTombstoneTests();
        SZFLRemoveTemporaryRoot();
        if (SZFLFailures > 0) {
            fprintf(stderr, "SZFriendsLinksTests: %d failure(s)\n", SZFLFailures);
            return 1;
        }
        printf("SZFriendsLinksTests: all passed\n");
    }
    return 0;
}
