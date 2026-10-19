// The NAT area's TCP simultaneous-open path (SZFriendsNATTCPPath, ADR 0011 § TCP simultaneous open) as the
// transport's side path (SZFriendsOnlineSidePath). The order component is the one owner of the direct phase's timers
// (lead decision for M2), so the path dials until the attempt says the order has ended its direct phase
// (-finishBudget), not on a budget of its own. Its configured budget is only a backstop past the order's longest
// direct phase, for a path whose connection somehow outlived its attempt.

#import "service/online/driver/SZFriendsOnlineDriverInternal.h"

#import "service/online/nat/SZFriendsNATSocketStream.h"
#import "service/online/nat/SZFriendsNATTCPPath.h"

@interface SZFriendsOnlineTCPSidePath () <SZFriendsNATTCPPathDelegate>
@end

@implementation SZFriendsOnlineTCPSidePath {
    SZFriendsNATTCPPathConfiguration *_configuration;
    SZFriendsNATTCPPath *_path;
    __weak id<SZFriendsOnlineSidePathEvents> _events;
    id<SZFriendsByteStream> _stream;
    BOOL _over;     // reported over (or closed): silent from then on
    BOOL _finished; // the order ended the direct phase
}

+ (instancetype)sidePathForRequest:(id<SZFriendsOnlineConnectionRequest>)request
                        stunServer:(SZFriendsNATEndpoint *)stunServer
                      loopbackOnly:(BOOL)loopbackOnly {
    // Browsers cannot open a TCP path, so links have none; first contacts have none either while Add by ID online
    // is not offered (SZFriendsOnlineDriver.h).
    if (request.purpose != SZFriendsOnlinePurposeFriend || request.kind != SZFriendsOnlineConnectionDirect) return nil;
    SZFriendsNATTCPPathConfiguration *configuration = [SZFriendsNATTCPPathConfiguration new];
    configuration.purpose = request.purpose;
    configuration.stunServer = stunServer;
    configuration.loopbackOnly = loopbackOnly;
    configuration.budget = SZFriendsOnlineRetrySignallingLimit + SZFriendsOnlinePlainChecksBudget +
                           SZFriendsOnlineHardNATBudget;
    SZFriendsOnlineTCPSidePath *path = [[self alloc] initWithConfiguration:configuration];
    return path;
}

- (instancetype)initWithConfiguration:(SZFriendsNATTCPPathConfiguration *)configuration {
    if ((self = [super init])) _configuration = configuration;
    return self;
}

- (BOOL)carriesStream {
    return _stream != nil && !_over;
}

- (void)startWithQueue:(dispatch_queue_t)queue events:(id<SZFriendsOnlineSidePathEvents>)events {
    if (_path != nil || _over) return;
    _events = events;
    if (_finished) {
        [self endWithCode:SZFriendsNATErrorTimedOut];
        return;
    }
    _path = [[SZFriendsNATTCPPath alloc] initWithConfiguration:_configuration delegate:self queue:queue];
    NSError *error = nil;
    if (![_path start:&error]) [self endWithError:error];
}

- (BOOL)addRemoteCandidate:(NSString *)candidate error:(NSError **)error {
    if (_path == nil || _over || _finished) {
        if (error) {
            *error = [NSError errorWithDomain:SZFriendsNATErrorDomain code:SZFriendsNATErrorCancelled userInfo:nil];
        }
        return NO;
    }
    return [_path addRemoteCandidate:candidate error:error];
}

- (void)finishBudget {
    if (_finished) return;
    _finished = YES;
    if (_stream != nil || _over || _path == nil) return;
    [_path close];
    [self endWithCode:SZFriendsNATErrorTimedOut];
}

- (void)endWithCode:(SZFriendsNATError)code {
    [self endWithError:[NSError errorWithDomain:SZFriendsNATErrorDomain code:code userInfo:nil]];
}

- (void)endWithError:(NSError *)error {
    if (_over) return;
    _over = YES;
    [_events sidePath:self didFailWithError:error];
}

// The connection closing ends the path and its stream (SZFriendsOnlineTransport.h: -close ends every stream).
- (void)close {
    _over = YES;
    [_path close];
    _path = nil;
    id<SZFriendsByteStream> stream = _stream;
    _stream = nil;
    [stream close];
}

#pragma mark SZFriendsNATTCPPathDelegate

- (void)tcpPath:(SZFriendsNATTCPPath *)path didGatherLocalCandidate:(NSString *)candidate {
    (void)path;
    if (!_over && !_finished) [_events sidePath:self didGatherLocalCandidate:candidate];
}

- (void)tcpPathDidFinishGathering:(SZFriendsNATTCPPath *)path {
    (void)path;
}

- (void)tcpPath:(SZFriendsNATTCPPath *)path didOpenStream:(id<SZFriendsByteStream>)stream ipv6:(BOOL)ipv6 {
    (void)path;
    if (_over) {
        [stream close];
        return;
    }
    _stream = stream;
    // The stream ending is the path ending (SZFriendsOnlineSidePathEvents), so the connection can fail once the data
    // channel's path is over too.
    if ([stream isKindOfClass:[SZFriendsNATSocketStream class]]) {
        __weak SZFriendsOnlineTCPSidePath *weakSelf = self;
        ((SZFriendsNATSocketStream *)stream).onEnd = ^{
            [weakSelf endWithCode:SZFriendsNATErrorCancelled];
        };
    }
    [_events sidePath:self didOpenStream:stream ipv6:ipv6];
}

- (void)tcpPath:(SZFriendsNATTCPPath *)path didFailWithError:(NSError *)error {
    (void)path;
    [self endWithError:error];
}

@end
