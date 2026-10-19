// UDP exchanges with a gateway (SZFriendsNATExchange.h).

#import "service/online/nat/SZFriendsNATExchange.h"

#import "service/online/nat/SZFriendsNATPCP.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

@implementation SZFriendsNATExchange {
    dispatch_queue_t _queue;
    int _socket;
    dispatch_source_t _reader;
    NSMutableArray<dispatch_source_t> *_timers;
    NSData *_request;
    SZFriendsNATExchangeAccept _accept;
    SZFriendsNATExchangeCompletion _completion;
}

- (instancetype)initWithServer:(SZFriendsNATEndpoint *)server
                   bindAddress:(SZFriendsNATEndpoint *)bindAddress
                         queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _queue = queue;
        _timers = [NSMutableArray array];
        _socket = socket(server.family, SOCK_DGRAM, IPPROTO_UDP);
        if (_socket < 0) return nil;
        fcntl(_socket, F_SETFL, fcntl(_socket, F_GETFL) | O_NONBLOCK);
        int on = 1;
        setsockopt(_socket, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        struct sockaddr_storage storage;
        if (bindAddress != nil) {
            socklen_t length = [[bindAddress endpointWithPort:0] getSockaddr:&storage];
            if (bindAddress.family != server.family || bind(_socket, (struct sockaddr *)&storage, length) != 0) {
                close(_socket);
                return nil;
            }
        }
        socklen_t length = [server getSockaddr:&storage];
        if (connect(_socket, (struct sockaddr *)&storage, length) != 0) {
            close(_socket);
            return nil;
        }
        length = sizeof storage;
        getsockname(_socket, (struct sockaddr *)&storage, &length);
        _localEndpoint = [SZFriendsNATEndpoint endpointWithSockaddr:(struct sockaddr *)&storage length:length];
        if (_localEndpoint == nil) {
            close(_socket);
            return nil;
        }
        __weak SZFriendsNATExchange *weakSelf = self;
        _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_socket, 0, queue);
        int fd = _socket;
        dispatch_source_set_event_handler(_reader, ^{
            [weakSelf readAvailable];
        });
        dispatch_source_set_cancel_handler(_reader, ^{
            close(fd);
        });
        dispatch_resume(_reader);
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)readAvailable {
    uint8_t buffer[SZFriendsPCPMessageMax + 1];
    for (;;) {
        ssize_t received = recv(_socket, buffer, sizeof buffer, 0);
        if (received < 0) {
            if (errno == ECONNREFUSED) {
                [self finishWithAnswer:nil
                                 error:[NSError errorWithDomain:SZFriendsNATErrorDomain code:SZFriendsNATErrorRefused
                                                       userInfo:nil]];
            }
            return; // EAGAIN, or a refusal with no exchange running
        }
        if (_completion == nil || received == 0 || (size_t)received > SZFriendsPCPMessageMax) continue;
        NSData *answer = [NSData dataWithBytes:buffer length:(size_t)received];
        if (_accept(answer)) {
            [self finishWithAnswer:answer error:nil];
        }
    }
}

- (void)send:(NSData *)request {
    ssize_t sent = send(_socket, request.bytes, request.length, 0);
    if (sent < 0 && errno == ECONNREFUSED) {
        // An earlier datagram's ICMP answer arrived before this send: the port is closed.
        [self finishWithAnswer:nil
                         error:[NSError errorWithDomain:SZFriendsNATErrorDomain code:SZFriendsNATErrorRefused
                                               userInfo:nil]];
    }
}

- (dispatch_source_t)timerAfter:(NSTimeInterval)seconds handler:(dispatch_block_t)handler {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, (uint64_t)(0.005 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, handler);
    dispatch_resume(timer);
    [_timers addObject:timer];
    return timer;
}

- (void)sendRequest:(NSData *)request
        retransmits:(NSArray<NSNumber *> *)retransmits
             budget:(NSTimeInterval)budget
             accept:(SZFriendsNATExchangeAccept)accept
         completion:(SZFriendsNATExchangeCompletion)completion {
    [self cancelTimers];
    if (_reader == nil) {
        dispatch_async(_queue, ^{
            completion(nil, [NSError errorWithDomain:SZFriendsNATErrorDomain code:SZFriendsNATErrorCancelled
                                            userInfo:nil]);
        });
        return;
    }
    _request = [request copy];
    _accept = [accept copy];
    _completion = [completion copy];
    __weak SZFriendsNATExchange *weakSelf = self;
    for (NSNumber *delay in retransmits) {
        if (delay.doubleValue >= budget) continue;
        [self timerAfter:delay.doubleValue handler:^{
            SZFriendsNATExchange *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_completion != nil) [strongSelf send:strongSelf->_request];
        }];
    }
    [self timerAfter:budget handler:^{
        [weakSelf finishWithAnswer:nil
                             error:[NSError errorWithDomain:SZFriendsNATErrorDomain code:SZFriendsNATErrorTimedOut
                                                   userInfo:nil]];
    }];
    [self send:_request];
}

- (void)finishWithAnswer:(NSData *)answer error:(NSError *)error {
    SZFriendsNATExchangeCompletion completion = _completion;
    if (completion == nil) return;
    _completion = nil;
    _accept = nil;
    [self cancelTimers];
    completion(answer, error);
}

- (void)cancelTimers {
    for (dispatch_source_t timer in _timers) dispatch_source_cancel(timer);
    [_timers removeAllObjects];
}

- (void)sendOnly:(NSData *)request {
    _completion = nil;
    _accept = nil;
    [self cancelTimers];
    if (_reader != nil) send(_socket, request.bytes, request.length, 0);
}

- (void)close {
    _completion = nil;
    _accept = nil;
    [self cancelTimers];
    if (_reader != nil) {
        dispatch_source_cancel(_reader); // its cancel handler closes the socket
        _reader = nil;
    }
}

@end
