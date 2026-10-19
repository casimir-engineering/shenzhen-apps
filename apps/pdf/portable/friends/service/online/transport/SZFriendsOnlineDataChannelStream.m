// One reliable, ordered data channel as an SZFriendsByteStream (ADR 0009: ADR 0001 runs unchanged above it).
//
// State lives on the connection's queue, where every channel event arrives; the owner's calls hop there, and its
// callbacks go to the queue it started the stream with. Writes larger than a message are split; a write's
// completion waits while the channel buffers more than the high-water mark, so ADR 0001's send window, not the
// channel, bounds what is in flight.

#import "service/online/transport/SZFriendsOnlinePeerConnection.h"

#include <rtc/rtc.h>
#include <stdatomic.h>

const NSUInteger SZFriendsOnlineChannelHighWater = 1024 * 1024;
const NSUInteger SZFriendsOnlineChannelLowWater = 256 * 1024;
const NSUInteger SZFriendsOnlineUnstartedBufferMax = 256 * 1024;

@implementation SZFriendsOnlineDataChannelStream {
    dispatch_queue_t _connectionQueue;
    dispatch_queue_t _callbackQueue; // set by -startWithQueue:, read on the connection queue afterwards
    NSUInteger _messageMax;
    NSMutableArray<NSData *> *_unstarted; // received before the owner started the stream
    NSUInteger _unstartedBytes;
    BOOL _started;
    BOOL _hasPendingEnd; // the path ended before the owner started the stream
    NSError *_pendingEndError;
    NSMutableArray<void (^)(NSError *)> *_heldCompletions;
    atomic_bool _ownerClosed; // read on the callback queue to drop deliveries racing -close
}

@synthesize onData = _onData;
@synthesize onClose = _onClose;

- (instancetype)initWithChannel:(int)channel connectionQueue:(dispatch_queue_t)connectionQueue
                     messageMax:(NSUInteger)messageMax {
    if ((self = [super init])) {
        _channel = channel;
        _connectionQueue = connectionQueue;
        _messageMax = messageMax == 0 ? SZFriendsOnlineMessageMax : MIN(messageMax, SZFriendsOnlineMessageMax);
        _unstarted = [NSMutableArray array];
        _heldCompletions = [NSMutableArray array];
        atomic_init(&_ownerClosed, false);
    }
    return self;
}

- (NSUInteger)preferredWriteSize {
    return SZFriendsOnlineMessageMax;
}

#pragma mark - Owner

- (void)startWithQueue:(dispatch_queue_t)queue {
    dispatch_async(_connectionQueue, ^{
        if (self->_started) return;
        self->_started = YES;
        self->_callbackQueue = queue;
        for (NSData *data in self->_unstarted) [self deliver:data];
        [self->_unstarted removeAllObjects];
        self->_unstartedBytes = 0;
        if (self->_hasPendingEnd) {
            self->_hasPendingEnd = NO;
            [self deliverEnd:self->_pendingEndError];
        }
    });
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    void (^done)(NSError *) = [completion copy];
    NSData *bytes = [data copy];
    dispatch_async(_connectionQueue, ^{
        [self sendData:bytes completion:done];
    });
}

- (void)close {
    if (atomic_exchange(&_ownerClosed, true)) return;
    dispatch_async(_connectionQueue, ^{
        BOOL wasEnded = self->_ended;
        self->_ended = YES;
        [self->_heldCompletions removeAllObjects];
        if (!wasEnded) {
            int channel = self->_channel;
            dispatch_async(SZFriendsOnlineTeardownQueue(), ^{
                rtcClose(channel);
            });
        }
        void (^onOwnerClose)(void) = self.onOwnerClose;
        self.onOwnerClose = nil;
        if (onOwnerClose) onOwnerClose();
    });
}

#pragma mark - Connection queue

- (void)sendData:(NSData *)data completion:(void (^)(NSError *))completion {
    if (_ended) {
        [self complete:completion error:SZFriendsOnlineMakeError(SZFriendsOnlineErrorPeerClosed, @"stream closed")];
        return;
    }
    const char *bytes = data.bytes;
    for (NSUInteger offset = 0; offset < data.length; offset += _messageMax) {
        NSUInteger length = MIN(_messageMax, data.length - offset);
        if (rtcSendMessage(_channel, bytes + offset, (int)length) < 0) {
            NSError *error = SZFriendsOnlineMakeError(SZFriendsOnlineErrorPeerClosed, @"channel refused a message");
            [self complete:completion error:error];
            [self endWithError:error];
            return;
        }
    }
    int buffered = rtcGetBufferedAmount(_channel);
    if (buffered > (int)SZFriendsOnlineChannelHighWater) {
        if (completion) [_heldCompletions addObject:completion];
    } else {
        [self complete:completion error:nil];
    }
}

- (void)complete:(void (^)(NSError *))completion error:(NSError *)error {
    if (completion == nil || atomic_load(&_ownerClosed)) return;
    dispatch_async(_callbackQueue ?: _connectionQueue, ^{
        completion(error);
    });
}

- (void)channelBufferedAmountLow {
    if (_ended || _heldCompletions.count == 0) return;
    // The callback fires when the amount drops below the low mark; it may have grown again since.
    if (rtcGetBufferedAmount(_channel) > (int)SZFriendsOnlineChannelHighWater) return;
    NSArray<void (^)(NSError *)> *held = [_heldCompletions copy];
    [_heldCompletions removeAllObjects];
    for (void (^completion)(NSError *) in held) [self complete:completion error:nil];
}

- (void)channelDidReceive:(NSData *)data {
    if (_ended || data.length == 0) return;
    if (!_started) {
        _unstartedBytes += data.length;
        if (_unstartedBytes > SZFriendsOnlineUnstartedBufferMax) {
            [_unstarted removeAllObjects];
            [self endWithError:SZFriendsOnlineMakeError(SZFriendsOnlineErrorPeerClosed, @"too much before start")];
            int channel = _channel;
            dispatch_async(SZFriendsOnlineTeardownQueue(), ^{
                rtcClose(channel);
            });
            return;
        }
        [_unstarted addObject:data];
        return;
    }
    [self deliver:data];
}

- (void)deliver:(NSData *)data {
    dispatch_async(_callbackQueue, ^{
        if (atomic_load(&self->_ownerClosed)) return;
        void (^onData)(NSData *) = self.onData;
        if (onData) onData(data);
    });
}

- (void)endWithError:(NSError *)error {
    if (_ended) return;
    _ended = YES;
    NSArray<void (^)(NSError *)> *held = [_heldCompletions copy];
    [_heldCompletions removeAllObjects];
    NSError *closed = error ?: SZFriendsOnlineMakeError(SZFriendsOnlineErrorPeerClosed, @"stream closed");
    for (void (^completion)(NSError *) in held) [self complete:completion error:closed];
    if (!_started) {
        _hasPendingEnd = YES;
        _pendingEndError = error;
        return;
    }
    [self deliverEnd:error];
}

- (void)deliverEnd:(NSError *)error {
    dispatch_async(_callbackQueue, ^{
        if (atomic_load(&self->_ownerClosed)) return;
        void (^onClose)(NSError *) = self.onClose;
        if (onClose) onClose(error);
    });
}

@end
