// A connected TCP socket as an SZFriendsByteStream (SZFriendsNATSocketStream.h).

#import "service/online/nat/SZFriendsNATSocketStream.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

enum {
    kReadMaximum = 65536,
    kWriteSize = 65536, // SZFriendsOnlineMessageMax: the online transport's preferred write size
    kKeepAliveIdle = 60,
    kKeepAliveInterval = 10,
    kKeepAliveCount = 3,
};
static const NSTimeInterval kGracefulCloseTimeout = 2;

@interface SZFriendsNATPendingWrite : NSObject
@property(nonatomic, strong) NSData *data;
@property(nonatomic) NSUInteger offset;
@property(nonatomic, copy, nullable) void (^completion)(NSError *_Nullable error);
@end

@implementation SZFriendsNATPendingWrite
@end

@implementation SZFriendsNATSharedDescriptor {
    int _descriptor;
    int _holders;
}
- (instancetype)initWithDescriptor:(int)descriptor holders:(int)holders {
    if ((self = [super init])) {
        _descriptor = descriptor;
        _holders = holders;
    }
    return self;
}
- (void)letGo {
    @synchronized(self) {
        if (--_holders == 0) close(_descriptor);
    }
}
@end

@implementation SZFriendsNATSocketStream {
    int _fd;
    dispatch_queue_t _queue;
    dispatch_source_t _reader, _writer;
    BOOL _writerResumed, _closed, _closedLocally, _peerClosed;
    NSMutableArray<SZFriendsNATPendingWrite *> *_writes;
}

@synthesize onData = _onData;
@synthesize onClose = _onClose;

- (instancetype)initWithConnectedSocket:(int)descriptor {
    if ((self = [super init])) {
        _fd = descriptor;
        _writes = [NSMutableArray array];
        fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL) | O_NONBLOCK);
        int on = 1, idle = kKeepAliveIdle, interval = kKeepAliveInterval, count = kKeepAliveCount;
        setsockopt(_fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        setsockopt(_fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
        setsockopt(_fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof on);
        setsockopt(_fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof idle);
        setsockopt(_fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof interval);
        setsockopt(_fd, IPPROTO_TCP, TCP_KEEPCNT, &count, sizeof count);
        struct sockaddr_storage storage;
        socklen_t length = sizeof storage;
        if (getpeername(_fd, (struct sockaddr *)&storage, &length) == 0) {
            _remoteEndpoint = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&storage length:length];
        }
        length = sizeof storage;
        if (getsockname(_fd, (struct sockaddr *)&storage, &length) == 0) {
            _localEndpoint = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&storage length:length];
        }
    }
    return self;
}

- (void)dealloc {
    [self teardown];
}

- (NSUInteger)preferredWriteSize {
    return kWriteSize;
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    if (_queue != nil || _fd < 0) return;
    _queue = queue;
    int fd = _fd;
    SZFriendsNATSharedDescriptor *shared = [[SZFriendsNATSharedDescriptor alloc] initWithDescriptor:fd holders:2];
    __weak SZFriendsNATSocketStream *weakSelf = self;
    _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
    dispatch_source_set_event_handler(_reader, ^{
        [weakSelf readAvailable];
    });
    dispatch_source_set_cancel_handler(_reader, ^{
        [shared letGo];
    });
    _writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, queue);
    dispatch_source_set_event_handler(_writer, ^{
        [weakSelf writeAvailable];
    });
    dispatch_source_set_cancel_handler(_writer, ^{
        [shared letGo];
    });
    dispatch_resume(_reader);
    if (_writes.count > 0) [self resumeWriter];
}

- (void)readAvailable {
    if (_closed) return;
    uint8_t buffer[kReadMaximum];
    ssize_t received = read(_fd, buffer, sizeof buffer);
    if (received > 0) {
        NSData *data = [NSData dataWithBytes:buffer length:(size_t)received];
        if (_onData != nil) _onData(data);
    } else if (received == 0) {
        [self peerClosedWithError:nil];
    } else if (errno != EAGAIN && errno != EINTR) {
        [self peerClosedWithError:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
    }
}

- (void)resumeWriter {
    if (_writer != nil && !_writerResumed) {
        _writerResumed = YES;
        dispatch_resume(_writer);
    }
}

- (void)suspendWriter {
    if (_writer != nil && _writerResumed) {
        _writerResumed = NO;
        dispatch_suspend(_writer);
    }
}

- (void)writeAvailable {
    while (_writes.count > 0 && !_peerClosed) {
        SZFriendsNATPendingWrite *write = _writes.firstObject;
        const uint8_t *bytes = (const uint8_t *)write.data.bytes + write.offset;
        ssize_t sent = send(_fd, bytes, write.data.length - write.offset, 0);
        if (sent < 0) {
            if (errno == EAGAIN || errno == EINTR) return;
            NSError *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            [self failWrites:error];
            if (!_closedLocally) [self peerClosedWithError:error];
            return;
        }
        write.offset += (NSUInteger)sent;
        if (write.offset < write.data.length) return;
        [_writes removeObjectAtIndex:0];
        if (write.completion != nil) write.completion(nil);
    }
    [self suspendWriter];
    if (_closedLocally && _writes.count == 0) [self finishLocalClose];
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    if (_closed || _closedLocally) {
        if (completion != nil && _queue != nil) {
            dispatch_async(_queue, ^{
                completion([NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTCONN userInfo:nil]);
            });
        }
        return;
    }
    SZFriendsNATPendingWrite *write = [SZFriendsNATPendingWrite new];
    write.data = [data copy];
    write.completion = completion;
    [_writes addObject:write];
    if (_queue != nil) [self resumeWriter];
}

- (void)failWrites:(NSError *)error {
    NSArray<SZFriendsNATPendingWrite *> *writes = [_writes copy];
    [_writes removeAllObjects];
    for (SZFriendsNATPendingWrite *write in writes) {
        if (write.completion != nil) write.completion(error);
    }
}

- (void)peerClosedWithError:(NSError *)error {
    if (_closed) return;
    _closed = YES;
    _peerClosed = YES;
    [self teardown];
    [self failWrites:error ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:ECONNRESET userInfo:nil]];
    if (!_closedLocally && _onClose != nil) _onClose(error);
}

- (void)close {
    if (_closedLocally || _closed) {
        _closedLocally = YES;
        return;
    }
    _closedLocally = YES;
    if (_queue == nil || _writes.count == 0) {
        [self finishLocalClose];
        return;
    }
    // FIN after what is already queued (the session's CLOSE frame), but never wait on a peer that stopped reading.
    __weak SZFriendsNATSocketStream *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGracefulCloseTimeout * NSEC_PER_SEC)), _queue, ^{
        [weakSelf finishLocalClose];
    });
}

- (void)finishLocalClose {
    if (_closed) return;
    _closed = YES;
    shutdown(_fd, SHUT_WR);
    [self failWrites:[NSError errorWithDomain:NSPOSIXErrorDomain code:ECANCELED userInfo:nil]];
    [self teardown];
}

- (void)teardown {
    void (^onEnd)(void) = _onEnd;
    _onEnd = nil;
    if (onEnd != nil && _queue != nil) dispatch_async(_queue, onEnd);
    if (_writer != nil) {
        [self resumeWriter];
        dispatch_source_cancel(_writer);
        _writer = nil;
    }
    if (_reader != nil) {
        dispatch_source_cancel(_reader); // the two cancel handlers close the descriptor
        _reader = nil;
    } else if (_fd >= 0) {
        close(_fd); // never started: no source holds it
    }
    _fd = -1;
}

@end
