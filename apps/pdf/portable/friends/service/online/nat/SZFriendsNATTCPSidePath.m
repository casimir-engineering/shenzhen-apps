// The TCP path as the transport's side path (SZFriendsNATTCPSidePath.h).

#import "service/online/nat/SZFriendsNATTCPSidePath.h"

#import "service/online/nat/SZFriendsNATSocketStream.h"

@interface SZFriendsNATTCPSidePath () <SZFriendsNATTCPPathDelegate>
@end

@implementation SZFriendsNATTCPSidePath {
    SZFriendsNATTCPPath *_path;
    __weak id<SZFriendsOnlineSidePathEvents> _events;
    id<SZFriendsByteStream> _stream;
    BOOL _over;
}

+ (instancetype)sidePathForRequest:(id<SZFriendsOnlineConnectionRequest>)request
                        stunServer:(SZFriendsNATEndpoint *)stunServer
                      loopbackOnly:(BOOL)loopbackOnly {
    BOOL helperPeer = request.purpose == SZFriendsOnlinePurposeFriend ||
                      request.purpose == SZFriendsOnlinePurposeFirstContact;
    if (!helperPeer || request.kind != SZFriendsOnlineConnectionDirect) return nil;
    SZFriendsNATTCPPathConfiguration *configuration = [SZFriendsNATTCPPathConfiguration new];
    configuration.purpose = request.purpose;
    configuration.stunServer = stunServer;
    configuration.loopbackOnly = loopbackOnly;
    // The transport's SZFriendsOnlineDirectPlainBudget, spelled out so these objects link without the transport's.
    configuration.budget = 5;
    return [[self alloc] initWithConfiguration:configuration];
}

- (instancetype)initWithConfiguration:(SZFriendsNATTCPPathConfiguration *)configuration {
    if ((self = [super init])) _configuration = configuration;
    return self;
}

- (void)startWithQueue:(dispatch_queue_t)queue events:(id<SZFriendsOnlineSidePathEvents>)events {
    if (_path != nil || _over) return;
    _events = events;
    _path = [[SZFriendsNATTCPPath alloc] initWithConfiguration:_configuration delegate:self queue:queue];
    NSError *error = nil;
    if (![_path start:&error]) [self endWithError:error];
}

- (BOOL)addRemoteCandidate:(NSString *)candidate error:(NSError **)error {
    if (_path == nil || _over) {
        if (error) {
            *error = [NSError errorWithDomain:SZFriendsNATErrorDomain code:SZFriendsNATErrorCancelled userInfo:nil];
        }
        return NO;
    }
    return [_path addRemoteCandidate:candidate error:error];
}

- (void)endWithError:(NSError *)error {
    if (_over) return;
    _over = YES;
    [_events sidePath:self didFailWithError:error];
}

- (void)close {
    _over = YES;
    [_path close];
    [_stream close];
    _stream = nil;
}

#pragma mark SZFriendsNATTCPPathDelegate

- (void)tcpPath:(SZFriendsNATTCPPath *)path didGatherLocalCandidate:(NSString *)candidate {
    (void)path;
    if (!_over) [_events sidePath:self didGatherLocalCandidate:candidate];
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
    if ([stream isKindOfClass:[SZFriendsNATSocketStream class]]) {
        __weak SZFriendsNATTCPSidePath *weakSelf = self;
        ((SZFriendsNATSocketStream *)stream).onEnd = ^{
            [weakSelf endWithError:[NSError errorWithDomain:SZFriendsNATErrorDomain code:SZFriendsNATErrorCancelled
                                                   userInfo:nil]];
        };
    }
    [_events sidePath:self didOpenStream:stream ipv6:ipv6];
}

- (void)tcpPath:(SZFriendsNATTCPPath *)path didFailWithError:(NSError *)error {
    (void)path;
    [self endWithError:error];
}

@end
