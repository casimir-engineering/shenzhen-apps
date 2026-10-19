// friends-driver-check: the NAT area's TCP simultaneous-open path as the transport's side path. The order is the one
// owner of the direct phase's timers, so the path dials until the attempt says the phase is over, not for a budget of
// its own; a path that carries a stream keeps it.

#import "SZFODriverTestSupport.h"

@interface SZFODSidePathEvents : NSObject <SZFriendsOnlineSidePathEvents>
@property(nonatomic, readonly) NSMutableArray<NSString *> *candidates;
@property(nonatomic, strong, nullable) id<SZFriendsByteStream> stream;
@property(nonatomic, strong, nullable) NSError *failure;
@end

@implementation SZFODSidePathEvents

- (instancetype)init {
    if ((self = [super init])) _candidates = [NSMutableArray array];
    return self;
}

- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didGatherLocalCandidate:(NSString *)candidate {
    (void)path;
    [_candidates addObject:candidate];
}

- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didOpenStream:(id<SZFriendsByteStream>)stream ipv6:(BOOL)ipv6 {
    (void)path;
    (void)ipv6;
    _stream = stream;
}

- (void)sidePath:(id<SZFriendsOnlineSidePath>)path didFailWithError:(NSError *)error {
    (void)path;
    _failure = error;
}

@end

static SZFriendsOnlineRequest *DirectRequest(SZFriendsOnlineRole role) {
    SZFriendsOnlineRequest *request = [SZFriendsOnlineRequest new];
    request.purpose = SZFriendsOnlinePurposeFriend;
    request.role = role;
    request.kind = SZFriendsOnlineConnectionDirect;
    request.peer = SZFODRandom(32);
    return request;
}

void SZFODTestSidePath(void) {
    SZFriendsOnlineRequest *relay = DirectRequest(SZFriendsOnlineRoleOfferer);
    relay.kind = SZFriendsOnlineConnectionRelay;
    EXPECT([SZFriendsOnlineTCPSidePath sidePathForRequest:relay stunServer:nil loopbackOnly:YES] == nil,
           "a relay connection has no TCP path");

    // Nobody answers: the path keeps dialling past the NAT area's own 5 s budget, until the order ends the phase.
    SZFriendsOnlineTCPSidePath *lonely =
        [SZFriendsOnlineTCPSidePath sidePathForRequest:DirectRequest(SZFriendsOnlineRoleOfferer) stunServer:nil
                                          loopbackOnly:YES];
    SZFODSidePathEvents *lonelyEvents = [SZFODSidePathEvents new];
    [lonely startWithQueue:dispatch_get_main_queue() events:lonelyEvents];
    EXPECT(SZFODWaitUntil(2, ^BOOL { return lonelyEvents.candidates.count > 0; }), "loopback candidates");
    [lonely addRemoteCandidate:@"candidate:1 1 TCP 1 127.0.0.1 9 typ host tcptype so" error:NULL];
    SZFODSpin(SZFriendsOnlinePlainChecksBudget + 0.6);
    EXPECT(lonelyEvents.failure == nil, "no budget of its own: %@", lonelyEvents.failure);
    [lonely finishBudget];
    EXPECT(lonelyEvents.failure != nil && !lonely.carriesStream, "over when the order says so");
    [lonely close];

    // Two paths that meet: the stream outlives the end of the phase.
    SZFriendsOnlineTCPSidePath *offerer =
        [SZFriendsOnlineTCPSidePath sidePathForRequest:DirectRequest(SZFriendsOnlineRoleOfferer) stunServer:nil
                                          loopbackOnly:YES];
    SZFriendsOnlineTCPSidePath *answerer =
        [SZFriendsOnlineTCPSidePath sidePathForRequest:DirectRequest(SZFriendsOnlineRoleAnswerer) stunServer:nil
                                          loopbackOnly:YES];
    SZFODSidePathEvents *offererEvents = [SZFODSidePathEvents new], *answererEvents = [SZFODSidePathEvents new];
    [offerer startWithQueue:dispatch_get_main_queue() events:offererEvents];
    [answerer startWithQueue:dispatch_get_main_queue() events:answererEvents];
    EXPECT(SZFODWaitUntil(2, ^BOOL {
        return offererEvents.candidates.count > 0 && answererEvents.candidates.count > 0;
    }));
    for (NSString *line in offererEvents.candidates) [answerer addRemoteCandidate:line error:NULL];
    for (NSString *line in answererEvents.candidates) [offerer addRemoteCandidate:line error:NULL];
    EXPECT(SZFODWaitUntil(5, ^BOOL { return offererEvents.stream != nil && answererEvents.stream != nil; }),
           "crossing SYNs connect on loopback");
    [offerer finishBudget];
    [answerer finishBudget];
    SZFODSpin(0.1);
    EXPECT(offerer.carriesStream && answerer.carriesStream && offererEvents.failure == nil,
           "a path carrying a stream keeps it");
    [offerer close];
    [answerer close];
}
