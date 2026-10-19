// nw_connection_t as an SZFriendsByteStream.

#import "service/discovery/SZFriendsNetworkStream.h"

#include <dns_sd.h>

static const uint32_t kReceiveMaximum = 65536;
// After a local close, the FIN normally goes out at once; this bounds how long a peer that stopped reading can
// keep the connection (and its buffers) alive.
static const NSTimeInterval kGracefulCloseTimeout = 2;

BOOL SZFriendsNetworkErrorIsPolicyDenied(nw_error_t error) {
    return error && nw_error_get_error_domain(error) == nw_error_domain_dns &&
           nw_error_get_error_code(error) == kDNSServiceErr_PolicyDenied;
}

NSError *SZFriendsErrorFromNetworkError(nw_error_t error) {
    if (SZFriendsNetworkErrorIsPolicyDenied(error)) {
        return SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorDenied, @"Local Network access denied");
    }
    CFErrorRef cfError = error ? nw_error_copy_cf_error(error) : NULL;
    if (cfError) return CFBridgingRelease(cfError);
    return SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorCancelled, @"connection ended");
}

static NSData *CopyDispatchData(dispatch_data_t content) {
    NSMutableData *data = [NSMutableData dataWithCapacity:dispatch_data_get_size(content)];
    dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        (void)region;
        (void)offset;
        [data appendBytes:buffer length:size];
        return true;
    });
    return data;
}

@implementation SZFriendsNetworkStream {
    nw_connection_t _connection;
    dispatch_queue_t _connectionQueue;
    dispatch_queue_t _callbackQueue;
    void (^_ready)(NSError *);
    BOOL _isReady;
    BOOL _receiving;
    BOOL _closed;        // no more callbacks: closed by the peer, an error, or locally
    BOOL _closedLocally; // -close or -cancel: the owner knows, so onClose is not called
    BOOL _hasPendingClose;
    NSError *_pendingCloseError;
}

@synthesize onData = _onData;
@synthesize onClose = _onClose;

- (instancetype)initWithConnection:(nw_connection_t)connection connectionQueue:(dispatch_queue_t)connectionQueue {
    if ((self = [super init])) {
        _connection = connection;
        _connectionQueue = connectionQueue;
        _pathRoute = SZFriendsRouteMethodLAN;
    }
    return self;
}

- (void)dealloc {
    // After -close the FIN is still on its way and its completion cancels; cancelling here would drop it.
    if (!_closedLocally) nw_connection_cancel(_connection);
}

- (NSUInteger)preferredWriteSize {
    return 65536;
}

- (void)connectWithTimeout:(NSTimeInterval)timeout ready:(void (^)(NSError *))ready {
    _ready = [ready copy];
    __weak SZFriendsNetworkStream *weakSelf = self;
    nw_connection_set_queue(_connection, _connectionQueue);
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        [weakSelf handleState:state error:error];
    });
    nw_connection_start(_connection);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), _connectionQueue, ^{
        SZFriendsNetworkStream *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_isReady || !strongSelf->_ready) return;
        nw_connection_cancel(strongSelf->_connection);
        [strongSelf finishReady:SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorTimedOut, @"connect timed out")];
    });
}

- (void)finishReady:(NSError *)error {
    void (^ready)(NSError *) = _ready;
    _ready = nil;
    if (ready) ready(error);
}

- (void)handleState:(nw_connection_state_t)state error:(nw_error_t)error {
    switch (state) {
    case nw_connection_state_ready:
        if (_isReady) break;
        _isReady = YES;
        [self classifyPath];
        [self finishReady:nil];
        break;
    case nw_connection_state_waiting:
        // Waiting means "not now": the attempt timeout decides, except when the system refused outright.
        if (!_isReady && SZFriendsNetworkErrorIsPolicyDenied(error)) {
            nw_connection_cancel(_connection);
            [self finishReady:SZFriendsErrorFromNetworkError(error)];
        } else if (_isReady) {
            [self peerClosed:SZFriendsErrorFromNetworkError(error)];
        }
        break;
    case nw_connection_state_failed:
        nw_connection_cancel(_connection);
        if (!_isReady) [self finishReady:SZFriendsErrorFromNetworkError(error)];
        else [self peerClosed:SZFriendsErrorFromNetworkError(error)];
        break;
    case nw_connection_state_cancelled:
        if (!_isReady) [self finishReady:SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorCancelled, @"cancelled")];
        else [self peerClosed:nil];
        break;
    default:
        break;
    }
}

- (void)classifyPath {
    nw_path_t path = nw_connection_copy_current_path(_connection);
    if (!path) return;
    __block NSString *name = nil;
    nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
        name = @(nw_interface_get_name(interface));
        return false; // the first interface is the one the connection uses
    });
    if (name) _pathRoute = SZFriendsRouteForInterfaceName(name);
}

- (void)cancel {
    dispatch_async(_connectionQueue, ^{
        self->_closedLocally = YES;
        self->_closed = YES;
        nw_connection_cancel(self->_connection);
        [self finishReady:SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorCancelled, @"cancelled")];
    });
}

#pragma mark - SZFriendsByteStream

- (void)startWithQueue:(dispatch_queue_t)queue {
    // Set here, not in the block below: send completions read it on the connection queue, after this call.
    _callbackQueue = queue;
    dispatch_async(_connectionQueue, ^{
        if (self->_hasPendingClose) {
            self->_hasPendingClose = NO;
            [self deliverClose:self->_pendingCloseError];
            return;
        }
        if (self->_receiving || self->_closed) return;
        self->_receiving = YES;
        [self receiveNext];
    });
}

- (void)receiveNext {
    __weak SZFriendsNetworkStream *weakSelf = self;
    nw_connection_receive(_connection, 1, kReceiveMaximum,
                          ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error) {
                              (void)context;
                              SZFriendsNetworkStream *strongSelf = weakSelf;
                              if (!strongSelf || strongSelf->_closed) return;
                              if (content && dispatch_data_get_size(content) > 0) {
                                  NSData *data = CopyDispatchData(content);
                                  dispatch_async(strongSelf->_callbackQueue, ^{
                                      if (strongSelf.onData) strongSelf.onData(data);
                                  });
                              }
                              // On a byte stream, completion means the peer finished sending (FIN).
                              if (error) [strongSelf peerClosed:SZFriendsErrorFromNetworkError(error)];
                              else if (isComplete) [strongSelf peerClosed:nil];
                              else [strongSelf receiveNext];
                          });
}

- (void)peerClosed:(NSError *)error {
    if (_closed) return;
    _closed = YES;
    nw_connection_cancel(_connection);
    if (!_callbackQueue) {
        _hasPendingClose = YES;
        _pendingCloseError = error;
        return;
    }
    [self deliverClose:error];
}

- (void)deliverClose:(NSError *)error {
    dispatch_async(_callbackQueue, ^{
        if (self.onClose) self.onClose(error);
    });
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    void (^done)(NSError *) = [completion copy];
    dispatch_data_t content = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    __weak SZFriendsNetworkStream *weakSelf = self;
    nw_connection_send(_connection, content, NW_CONNECTION_DEFAULT_STREAM_CONTEXT, false, ^(nw_error_t error) {
        SZFriendsNetworkStream *strongSelf = weakSelf;
        NSError *failure = error ? SZFriendsErrorFromNetworkError(error) : nil;
        if (failure && strongSelf && !strongSelf->_closedLocally) [strongSelf peerClosed:failure];
        if (!done) return;
        dispatch_queue_t queue = strongSelf ? (strongSelf->_callbackQueue ?: strongSelf->_connectionQueue)
                                            : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_async(queue, ^{
            done(failure);
        });
    });
}

- (void)close {
    nw_connection_t connection = _connection;
    dispatch_async(_connectionQueue, ^{
        if (self->_closedLocally) return;
        self->_closedLocally = YES;
        self->_closed = YES;
        if (!self->_isReady) {
            nw_connection_cancel(connection);
            [self finishReady:SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorCancelled, @"closed")];
            return;
        }
        // FIN after everything already queued (the session's CLOSE frame), then let go.
        nw_connection_send(connection, NULL, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
            (void)error;
            nw_connection_cancel(connection);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGracefulCloseTimeout * NSEC_PER_SEC)),
                       self->_connectionQueue, ^{
                           nw_connection_cancel(connection);
                       });
    });
}

@end
