// The production SZFriendsHostSocket: NSURLSessionWebSocketTask. Ephemeral session (no cookies, no cache, nothing
// on disk), JSON text messages of at most 64 KiB, callbacks on the client's queue, and a ping every 25 s that
// also keeps NAT mappings and the ingress's 120 s idle timeout alive (ADR 0005 step 5).

#import "service/host/SZFriendsHostInternal.h"

static const NSTimeInterval SZFriendsHostPingInterval = 25;
static const NSTimeInterval SZFriendsHostPongTimeout = 15;

@interface SZFriendsHostWebSocket : NSObject <SZFriendsHostSocket, NSURLSessionWebSocketDelegate>
- (instancetype)initWithURL:(NSURL *)url queue:(dispatch_queue_t)queue;
@end

@implementation SZFriendsHostWebSocket {
    NSURL *_url;
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    dispatch_source_t _pingTimer;
    NSUInteger _pingsSent;
    NSUInteger _pongsReceived; // the highest ping answered
    BOOL _finished;
}

@synthesize onOpen = _onOpen;
@synthesize onMessage = _onMessage;
@synthesize onClose = _onClose;

- (instancetype)initWithURL:(NSURL *)url queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _url = url;
        _queue = queue;
    }
    return self;
}

- (void)open {
    if (!SZFriendsHostURLAllowed(_url)) {
        // Refused before any byte leaves the machine; the client moves on to its next host.
        dispatch_async(_queue, ^{
            [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL userInfo:nil]];
        });
        return;
    }
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 15;
    configuration.waitsForConnectivity = NO;
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPCookieStorage = nil;
    configuration.URLCache = nil;
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    delegateQueue.underlyingQueue = _queue;
    // The session retains its delegate until invalidated; -finish: and -close invalidate it.
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
    _task = [_session webSocketTaskWithURL:_url];
    _task.maximumMessageSize = (NSInteger)SZFriendsHostMaxMessageBytes;
    [_task resume];
    [self receiveNext];
}

- (void)receiveNext {
    __weak SZFriendsHostWebSocket *weakSelf = self;
    NSURLSessionWebSocketTask *task = _task;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        SZFriendsHostWebSocket *socket = weakSelf;
        if (socket == nil) return;
        dispatch_async(socket->_queue, ^{
            if (socket->_finished || socket->_task != task) return;
            if (error) {
                // A close frame the host sent may surface here first: its code says why (4002, a removed device).
                NSInteger code = task.closeCode;
                [socket finish:code != NSURLSessionWebSocketCloseCodeInvalid
                                   ? [NSError errorWithDomain:SZFriendsHostErrorDomain code:code userInfo:nil]
                                   : error];
                return;
            }
            NSData *data = message.type == NSURLSessionWebSocketMessageTypeString
                               ? [message.string dataUsingEncoding:NSUTF8StringEncoding]
                               : message.data;
            if (data && socket.onMessage) socket.onMessage(data);
            if (!socket->_finished) [socket receiveNext];
        });
    }];
}

- (void)sendMessage:(NSData *)message {
    if (_finished || _task == nil) return;
    NSString *text = [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding];
    if (text == nil) return;
    __weak SZFriendsHostWebSocket *weakSelf = self;
    [_task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text]
        completionHandler:^(NSError *error) {
            if (error == nil) return;
            SZFriendsHostWebSocket *socket = weakSelf;
            if (socket) dispatch_async(socket->_queue, ^{
                [socket finish:error];
            });
        }];
}

// An explicit close is the client's decision; it gets no onClose for it.
- (void)close {
    if (_finished) return;
    _finished = YES;
    [self stopPinging];
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [_session invalidateAndCancel];
    _onOpen = nil;
    _onMessage = nil;
    _onClose = nil;
}

- (void)finish:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    [self stopPinging];
    [_task cancel];
    [_session invalidateAndCancel];
    void (^onClose)(NSError *) = _onClose;
    _onOpen = nil;
    _onMessage = nil;
    _onClose = nil;
    if (onClose) onClose(error);
}

#pragma mark - Keepalive

- (void)startPinging {
    _pingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = (uint64_t)(SZFriendsHostPingInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(_pingTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, NSEC_PER_SEC);
    __weak SZFriendsHostWebSocket *weakSelf = self;
    dispatch_source_set_event_handler(_pingTimer, ^{
        [weakSelf ping];
    });
    dispatch_resume(_pingTimer);
}

- (void)stopPinging {
    if (_pingTimer) dispatch_source_cancel(_pingTimer);
    _pingTimer = nil;
}

- (void)ping {
    if (_finished) return;
    NSUInteger sequence = ++_pingsSent;
    __weak SZFriendsHostWebSocket *weakSelf = self;
    [_task sendPingWithPongReceiveHandler:^(NSError *error) {
        SZFriendsHostWebSocket *socket = weakSelf;
        if (socket == nil) return;
        dispatch_async(socket->_queue, ^{
            if (error) [socket finish:error];
            else socket->_pongsReceived = MAX(socket->_pongsReceived, sequence);
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsHostPongTimeout * NSEC_PER_SEC)), _queue, ^{
        SZFriendsHostWebSocket *socket = weakSelf;
        if (socket && !socket->_finished && socket->_pongsReceived < sequence) {
            [socket finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
        }
    });
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
          webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didOpenWithProtocol:(NSString *)protocol {
    (void)session;
    (void)protocol;
    if (_finished || webSocketTask != _task) return;
    [self startPinging];
    if (_onOpen) _onOpen();
}

- (void)URLSession:(NSURLSession *)session
       webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
              reason:(NSData *)reason {
    (void)session;
    (void)reason;
    if (webSocketTask != _task) return;
    [self finish:[NSError errorWithDomain:SZFriendsHostErrorDomain code:closeCode userInfo:nil]];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session;
    if (task != _task) return;
    [self finish:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]];
}

@end

SZFriendsHostSocketFactory SZFriendsHostWebSocketFactory(dispatch_queue_t queue) {
    return ^id<SZFriendsHostSocket>(NSURL *url) {
        return [[SZFriendsHostWebSocket alloc] initWithURL:url queue:queue];
    };
}
