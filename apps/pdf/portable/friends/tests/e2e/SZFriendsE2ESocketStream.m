// A Unix stream socket as an SZFriendsByteStream, paced like a Bluetooth L2CAP channel: small writes at a bounded
// rate. For the harness's scripted Bluetooth adapter only (SZFriendsE2EBluetooth.h).

#import "SZFriendsE2ESocketStream.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>

// L2CAP's useful payload is a few KiB; the session derives its in-flight budget from this.
static const NSUInteger SZFE2EBluetoothWriteSize = 4096;

@interface SZFE2EPendingWrite : NSObject
@property(nonatomic) NSData *data;
@property(nonatomic) NSUInteger offset;
@property(nonatomic, copy) void (^completion)(NSError *);
@end

@implementation SZFE2EPendingWrite
@end

@implementation SZFE2ESocketStream {
    int _fd;
    double _rate;
    dispatch_queue_t _queue;
    dispatch_source_t _readSource;
    dispatch_source_t _writeSource;
    BOOL _writeSourceActive;
    NSMutableArray<SZFE2EPendingWrite *> *_pending;
    CFAbsoluteTime _start;
    uint64_t _sent;
    BOOL _pumpScheduled;
    BOOL _closed;
    BOOL _closedLocally;
}

@synthesize onData = _onData;
@synthesize onClose = _onClose;

- (instancetype)initWithDescriptor:(int)fd bytesPerSecond:(double)rate queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _fd = fd;
        _rate = rate;
        _queue = queue;
        _pending = [NSMutableArray array];
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
    }
    return self;
}

- (void)dealloc {
    [self cancelSources];
    if (_fd >= 0 && _readSource == nil) close(_fd);
}

- (void)cancelSources {
    if (_readSource != nil) dispatch_source_cancel(_readSource);
    if (_writeSource != nil) {
        // A suspended source must be resumed before it can be cancelled and released.
        if (!_writeSourceActive) dispatch_resume(_writeSource);
        _writeSourceActive = YES;
        dispatch_source_cancel(_writeSource);
    }
}

- (NSUInteger)preferredWriteSize {
    return SZFE2EBluetoothWriteSize;
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    _queue = queue;
    _start = CFAbsoluteTimeGetCurrent();
    int fd = _fd;
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
    __weak SZFE2ESocketStream *weakSelf = self;
    dispatch_source_set_event_handler(_readSource, ^{ [weakSelf readable]; });
    // The descriptor is closed only once the read source is cancelled: the kernel may still be watching it.
    dispatch_source_set_cancel_handler(_readSource, ^{ close(fd); });
    dispatch_resume(_readSource);
    _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, queue);
    dispatch_source_set_event_handler(_writeSource, ^{
        SZFE2ESocketStream *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        dispatch_suspend(strongSelf->_writeSource);
        strongSelf->_writeSourceActive = NO;
        [strongSelf pump];
    });
    [self pump];
}

- (void)readable {
    uint8_t buffer[65536];
    ssize_t count = read(_fd, buffer, sizeof(buffer));
    if (count > 0) {
        if (!_closedLocally && self.onData) self.onData([NSData dataWithBytes:buffer length:(NSUInteger)count]);
        return;
    }
    if (count < 0 && (errno == EAGAIN || errno == EINTR)) return;
    NSError *error = count < 0 ? [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil] : nil;
    [self finishWithError:error];
}

- (void)finishWithError:(NSError *)error {
    if (_closed) return;
    _closed = YES;
    [self cancelSources];
    void (^onClose)(NSError *) = self.onClose;
    self.onClose = nil;
    self.onData = nil;
    for (SZFE2EPendingWrite *write in _pending) {
        if (write.completion) write.completion([NSError errorWithDomain:NSPOSIXErrorDomain code:EPIPE userInfo:nil]);
    }
    [_pending removeAllObjects];
    // A stream closed locally does not call back (the discovery adapters' rule, which the channel relies on).
    if (!_closedLocally && onClose) onClose(error);
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    SZFE2EPendingWrite *write = [[SZFE2EPendingWrite alloc] init];
    write.data = data;
    write.completion = completion;
    [_pending addObject:write];
    if (_readSource != nil) [self pump];
}

// Writes what the pace allows now, in link-sized pieces; the rest waits for time or for socket space.
- (void)pump {
    while (_pending.count > 0 && !_closed) {
        SZFE2EPendingWrite *next = _pending.firstObject;
        double allowance = _rate * (CFAbsoluteTimeGetCurrent() - _start) + SZFE2EBluetoothWriteSize - (double)_sent;
        if (allowance < 1) {
            [self pumpAfter:(1 - allowance) / _rate + 0.002];
            return;
        }
        NSUInteger length = MIN(next.data.length - next.offset, MIN((NSUInteger)allowance, SZFE2EBluetoothWriteSize));
        ssize_t written = write(_fd, (const uint8_t *)next.data.bytes + next.offset, length);
        if (written < 0) {
            if (errno == EAGAIN || errno == EINTR) {
                if (!_writeSourceActive) {
                    _writeSourceActive = YES;
                    dispatch_resume(_writeSource);
                }
                return;
            }
            [self finishWithError:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
            return;
        }
        next.offset += (NSUInteger)written;
        _sent += (uint64_t)written;
        if (next.offset == next.data.length) {
            [_pending removeObjectAtIndex:0];
            void (^completion)(NSError *) = next.completion;
            if (completion) dispatch_async(_queue, ^{ completion(nil); });
        }
    }
    if (_pending.count == 0 && _closedLocally && !_closed) {
        // Everything queued before -close (the session's CLOSE) is out: end our direction, then let go.
        shutdown(_fd, SHUT_WR);
        [self finishWithError:nil];
    }
}

- (void)pumpAfter:(NSTimeInterval)delay {
    if (_pumpScheduled) return;
    _pumpScheduled = YES;
    __weak SZFE2ESocketStream *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        SZFE2ESocketStream *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf->_pumpScheduled = NO;
        [strongSelf pump];
    });
}

- (void)close {
    if (_closedLocally || _closed) return;
    _closedLocally = YES;
    if (_readSource == nil) {
        // Never started: nothing was queued and nobody listens.
        _closed = YES;
        close(_fd);
        _fd = -1;
        return;
    }
    [self pump];
}

@end
