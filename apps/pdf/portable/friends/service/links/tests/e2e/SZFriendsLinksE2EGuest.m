// The browser stand-in of the links e2e (SZFriendsLinksE2E.h): a guest connection to the host (/v1?guest=1) carrying
// one link's sid, as the link page's receiver.js does, and the helper's own opener code on the loopback transport
// behind it. Everything it does runs on its own serial queue; the runner reads results through -[... wait...].

#import "SZFriendsLinksE2E.h"

@interface SZFLGuest : NSObject <SZFriendsOnlineSignalChannel, NSURLSessionWebSocketDelegate>
// The host answered that the link ended (sig_opened's link_ended), as the page reads it.
@property(nonatomic, copy, nullable) void (^onLinkEnded)(void);
@end

@implementation SZFLGuest {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    dispatch_queue_t _queue;
    NSData *_linkID, *_hello;
    NSString *_sid;
    void (^_opened)(id, BOOL);
    void (^_credentials)(id<SZFriendsOnlineRelayCredentials>, NSError *);
}

@synthesize onPayload = _onPayload;
@synthesize onEnd = _onEnd;
@synthesize ended = _ended;

- (instancetype)initWithURL:(NSURL *)url queue:(dispatch_queue_t)queue linkID:(NSData *)linkID hello:(NSData *)hello
                     opened:(void (^)(id, BOOL))opened {
    if ((self = [super init])) {
        _queue = queue;
        _linkID = linkID;
        _hello = hello;
        _opened = [opened copy];
        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        delegateQueue.underlyingQueue = queue;
        delegateQueue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                 delegate:self delegateQueue:delegateQueue];
        _task = [_session webSocketTaskWithURL:url];
        [_task resume];
        [self receive];
    }
    return self;
}

- (void)send:(NSDictionary *)message {
    NSMutableDictionary *full = [message mutableCopy];
    full[@"v"] = @1;
    NSData *json = [NSJSONSerialization dataWithJSONObject:full options:0 error:NULL];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [_task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text] completionHandler:^(NSError *e) {
        (void)e;
    }];
}

- (void)receive {
    __weak SZFLGuest *weakSelf = self;
    [_task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        SZFLGuest *guest = weakSelf;
        if (guest == nil) return;
        dispatch_async(guest->_queue, ^{
            if (error != nil || message == nil) {
                [guest ended:NO];
                return;
            }
            NSData *data = message.data ?: [message.string dataUsingEncoding:NSUTF8StringEncoding];
            id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if ([object isKindOfClass:[NSDictionary class]]) [guest hostSaid:object];
            [guest receive];
        });
    }];
}

- (void)hostSaid:(NSDictionary *)message {
    NSString *type = message[@"type"];
    if ([type isEqual:@"challenge"] && _sid == nil && _opened) {
        [self send:@{@"type" : @"link_open", @"req" : @1, @"link_id" : SZFriendsLinkBase64URLEncode(_linkID),
                     @"payload" : SZFriendsLinkBase64URLEncode(_hello)}];
    } else if ([type isEqual:@"sig_opened"] && _opened) {
        _sid = message[@"sid"];
        void (^opened)(id, BOOL) = _opened;
        _opened = nil;
        BOOL linkEnded = [message[@"link_ended"] isEqual:@"revoked"] || [message[@"link_ended"] isEqual:@"expired"];
        if (linkEnded && self.onLinkEnded) self.onLinkEnded();
        opened(linkEnded ? nil : self, [message[@"owner_online"] isEqual:@YES]);
    } else if ([type isEqual:@"sig_msg"] && [message[@"sid"] isEqual:_sid]) {
        NSData *payload = SZFriendsLinkBase64URLDecode(message[@"payload"]);
        if (payload && self.onPayload) self.onPayload(payload);
    } else if ([type isEqual:@"sig_closed"] && [message[@"sid"] isEqual:_sid]) {
        [self ended:YES];
    } else if ([type isEqual:@"relay_credentials_result"] || [type isEqual:@"relay_refused"]) {
        void (^completion)(id<SZFriendsOnlineRelayCredentials>, NSError *) = _credentials;
        _credentials = nil;
        NSString *uri = nil;
        for (id candidate in [message[@"ice_servers"] isKindOfClass:[NSArray class]] ? message[@"ice_servers"] : @[]) {
            BOOL turn = [candidate isKindOfClass:[NSString class]] && [candidate hasPrefix:@"turn:"];
            if (uri == nil && turn) uri = candidate;
        }
        if (completion == nil) return;
        if (uri == nil || [type isEqual:@"relay_refused"]) {
            completion(nil, [NSError errorWithDomain:SZFriendsOnlineErrorDomain code:SZFriendsOnlineErrorRelayRefused
                                            userInfo:nil]);
            return;
        }
        SZFriendsOnlineRelayCredentialsValue *value = [SZFriendsOnlineRelayCredentialsValue new];
        value.turnURI = uri;
        value.username = message[@"username"];
        value.credential = message[@"credential"];
        value.expires = [NSDate dateWithTimeIntervalSinceNow:250];
        completion(value, nil);
    }
}

- (void)ended:(BOOL)bySid {
    (void)bySid;
    if (_opened) {
        void (^opened)(id, BOOL) = _opened;
        _opened = nil;
        opened(nil, NO);
    }
    if (_ended) return;
    _ended = YES;
    if (self.onEnd) self.onEnd();
}

- (BOOL)sendPayload:(NSData *)payload {
    if (_ended || _sid == nil) return NO;
    [self send:@{@"type" : @"sig_msg", @"sid" : _sid, @"payload" : SZFriendsLinkBase64URLEncode(payload)}];
    return YES;
}

- (void)close {
    if (_sid && !_ended) [self send:@{@"type" : @"sig_close", @"sid" : _sid}];
    _ended = YES;
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [_session finishTasksAndInvalidate];
}

- (void)requestRelayCredentials:(void (^)(id<SZFriendsOnlineRelayCredentials>, NSError *))completion {
    _credentials = [completion copy];
    [self send:@{@"type" : @"relay_credentials", @"req" : @2, @"sid" : _sid ?: @""}];
}

@end

@implementation SZFLGuestSink

- (instancetype)init {
    if ((self = [super init])) _bytes = [NSMutableData data];
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
    return YES;
}

- (void)linkDidStop:(SZFriendsLinkOutcome)outcome {
    (void)outcome;
}

@end

SZFriendsLinkOutcome SZFLGuestOpen(NSURL *guestURL, NSString *stunURI, NSString *payloadString, BOOL blockDirect,
                                   SZFLGuestSink *sink, uint8_t *attempt) {
    static dispatch_queue_t queue;
    static id<SZFriendsOnlineTransport> transport;
    if (queue == nil) {
        queue = dispatch_queue_create("szfl.guest", DISPATCH_QUEUE_SERIAL);
        transport = [[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"];
    }
    SZFriendsDownloadLinkPayload *payload = SZFriendsParseLinkPayload(payloadString);
    SZFriendsLinkEnvironment *environment = [SZFriendsLinkEnvironment new];
    environment.transport = transport;
    environment.queue = queue;
    environment.stunURI = blockDirect ? nil : stunURI;
    environment.directPathsBlocked = ^BOOL { return blockDirect; };
    environment.answerTimeout = 4;
    environment.directTimeout = 3;
    environment.relayTimeout = 10;
    __block NSInteger outcome = -1;
    __block SZFriendsLinkOpening *opening = nil;
    dispatch_sync(queue, ^{
        opening = [[SZFriendsLinkOpening alloc] initWithLinkID:payload.linkID secret:payload.secret
                                                   environment:environment sink:sink];
        __weak SZFriendsLinkOpening *opener = opening;
        [opening startWithOpen:^(NSData *hello, void (^done)(id, BOOL)) {
            SZFLGuest *guest = [[SZFLGuest alloc] initWithURL:guestURL queue:queue linkID:payload.linkID hello:hello
                                                       opened:done];
            guest.onLinkEnded = ^{ [opener noteLinkEnded]; };
        }
            completion:^(SZFriendsLinkOutcome result) { outcome = result; }];
    });
    BOOL ended = SZFE2EWaitUntil(30, ^BOOL {
        __block BOOL done = NO;
        dispatch_sync(queue, ^{ done = outcome >= 0; });
        return done;
    });
    __block uint8_t used = 0;
    dispatch_sync(queue, ^{ used = opening.attempt; });
    if (attempt) *attempt = used;
    SZFE2EPump(1.2); // the connection goes a moment after the last record
    return ended ? (SZFriendsLinkOutcome)outcome : SZFriendsLinkOutcomeFailed;
}
