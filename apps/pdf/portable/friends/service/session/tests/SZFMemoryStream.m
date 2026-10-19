// In-memory SZFriendsByteStream pair with fault injection (SZFriendsSessionTestSupport.h).
//
// Delivery is asynchronous on the reader's queue, in write order, like a real link. A global count of scheduled
// deliveries lets SZFDrain wait for quiescence instead of sleeping for a guessed time.

#import "SZFriendsSessionTestSupport.h"

#import <stdatomic.h>

static atomic_long gPendingDeliveries;

@interface SZFMemoryStream ()
@property(nonatomic, weak) SZFMemoryStream *peer;
@end

@implementation SZFMemoryStream {
    dispatch_queue_t _queue;
    NSMutableArray<dispatch_block_t> *_beforeStart; // deliveries that arrived before -startWithQueue:
    uint64_t _bytesWritten;
    BOOL _severed;
}
@synthesize onData = _onData, onClose = _onClose, preferredWriteSize = _preferredWriteSize;

+ (NSArray<SZFMemoryStream *> *)pair {
    SZFMemoryStream *a = [[SZFMemoryStream alloc] init];
    SZFMemoryStream *b = [[SZFMemoryStream alloc] init];
    a.peer = b;
    b.peer = a;
    return @[ a, b ];
}

- (instancetype)init {
    if ((self = [super init])) {
        _preferredWriteSize = 65536;
        _transcript = [NSMutableData data];
        _beforeStart = [NSMutableArray array];
        _duplicateWriteIndex = -1;
    }
    return self;
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    _queue = queue;
    for (dispatch_block_t block in _beforeStart) {
        dispatch_async(queue, block);
    }
    [_beforeStart removeAllObjects];
}

// Schedules `block` on this end's queue, counted so SZFDrain can tell when the link is idle.
- (void)schedule:(dispatch_block_t)block delay:(NSTimeInterval)delay {
    atomic_fetch_add(&gPendingDeliveries, 1);
    dispatch_block_t counted = ^{
        block();
        atomic_fetch_sub(&gPendingDeliveries, 1);
    };
    if (_queue == nil) {
        [_beforeStart addObject:counted];
    } else if (delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, counted);
    } else {
        dispatch_async(_queue, counted);
    }
}

- (void)receive:(NSData *)data delay:(NSTimeInterval)delay {
    __weak SZFMemoryStream *weakSelf = self;
    [self schedule:^{
        SZFMemoryStream *strongSelf = weakSelf;
        if (strongSelf && !strongSelf->_closed && strongSelf.onData) {
            strongSelf.onData(data);
        }
    }
             delay:delay];
}

- (void)deliverToPeer:(NSData *)data {
    SZFMemoryStream *peer = self.peer;
    if (data.length == 0 || peer == nil) {
        return;
    }
    if (_byteByByte) {
        for (NSUInteger i = 0; i < data.length; i++) {
            [peer receive:[data subdataWithRange:NSMakeRange(i, 1)] delay:_delay];
        }
    } else {
        [peer receive:data delay:_delay];
    }
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    NSUInteger index = _writeCount++;
    if (_closed || _severed) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"SZFMemoryStream" code:1 userInfo:nil];
            [self schedule:^{
                completion(error);
            }
                     delay:0];
        }
        return;
    }
    [_transcript appendData:data];
    uint64_t offset = _bytesWritten;
    _bytesWritten += data.length;
    NSData *outgoing = _filter ? _filter(data, offset) : data;
    BOOL sever = NO;
    if (_severAfterBytes > 0 && offset + data.length > _severAfterBytes) {
        uint64_t keep = _severAfterBytes > offset ? _severAfterBytes - offset : 0;
        outgoing = [outgoing subdataWithRange:NSMakeRange(0, MIN((NSUInteger)keep, outgoing.length))];
        sever = YES;
    }
    [self deliverToPeer:outgoing];
    if ((NSInteger)index == _duplicateWriteIndex) {
        [self deliverToPeer:outgoing];
    }
    if (completion) {
        [self schedule:^{
            completion(nil);
        }
                 delay:0];
    }
    if (sever) {
        [self severLink];
    }
}

- (void)severLink {
    NSError *error = [NSError errorWithDomain:@"SZFMemoryStream" code:2 userInfo:nil];
    _severed = YES;
    self.peer->_severed = YES;
    [self.peer remoteClosedWithError:error];
    [self remoteClosedWithError:error];
}

- (void)remoteClosedWithError:(NSError *)error {
    __weak SZFMemoryStream *weakSelf = self;
    [self schedule:^{
        SZFMemoryStream *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_closed) {
            return;
        }
        strongSelf->_closed = YES;
        strongSelf->_closedByPeer = YES;
        if (strongSelf.onClose) {
            strongSelf.onClose(error);
        }
    }
             delay:_delay];
}

- (void)close {
    if (_closed) {
        return;
    }
    _closed = YES;
    [self.peer remoteClosedWithError:nil];
}

@end

void SZFDrain(dispatch_queue_t queue) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while ([deadline timeIntervalSinceNow] > 0) {
        dispatch_sync(queue, ^{
        });
        if (atomic_load(&gPendingDeliveries) == 0) {
            dispatch_sync(queue, ^{
            });
            if (atomic_load(&gPendingDeliveries) == 0) {
                return;
            }
        }
        usleep(200);
    }
    SZFTestFail(__FILE__, __LINE__, "SZFDrain", @"deliveries still pending after 10 s");
}
