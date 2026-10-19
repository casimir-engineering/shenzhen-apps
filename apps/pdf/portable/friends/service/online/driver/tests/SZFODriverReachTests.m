// friends-driver-check: what the driver tells the helper about a friend between sessions (-reachOfFriend:), which the
// words "Connecting to Mei…" and "Couldn’t connect just now" come from. Fake transports and a fake clock: the order's
// timers are fired by hand, and no connection ever connects.

#import "SZFODriverTestSupport.h"

// Counts the driver's reach notices, per friend (NSNull for "any friend").
@interface SZFODReachDelegate : SZFODDelegate
@property(nonatomic, readonly) NSMutableArray *notices;
@end

@implementation SZFODReachDelegate

- (instancetype)init {
    if ((self = [super init])) _notices = [NSMutableArray array];
    return self;
}

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver reachChangedForFriend:(NSData *)identityKey {
    (void)driver;
    [_notices addObject:identityKey ?: (id)[NSNull null]];
}

@end

// A stream that carries nothing: the driver hands it on, as a connected path's would be.
@interface SZFODReachStream : NSObject <SZFriendsByteStream>
@end

@implementation SZFODReachStream
@synthesize onData = _onData, onClose = _onClose;
- (NSUInteger)preferredWriteSize {
    return 1024;
}
- (void)startWithQueue:(dispatch_queue_t)queue {
    (void)queue;
}
- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    (void)data;
    if (completion) completion(nil);
}
- (void)close {
}
@end

// The drivers' clock: static, since a driver may outlive the test that made it.
static NSTimeInterval sClock;

static SZFODWorld *ReachWorld(SZFODReachDelegate *delegate) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:^id<SZFriendsOnlineTransport> {
        return [SZFODFakeTransport new];
    }];
    world.a.delegate = delegate;
    [world befriend];
    delegate.friends[world.identityB.publicKey] = world.delegateA.friends[world.identityB.publicKey];
    for (SZFriendsOnlineDriver *driver in @[ world.a, world.b ]) {
        driver.onlineContext.clock = ^NSTimeInterval { return sClock; };
    }
    return world;
}

// Moves both sides' clocks on in steps and fires every timer, until A has no attempt left (or 60 steps pass). Once the
// descriptions are exchanged, every connection A opens fails, as ICE does when no pair answers.
static void RunOut(SZFODWorld *world) {
    SZFODFakeTransport *fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;
    for (int step = 0; step < 60 && world.a.attempts.count > 0; step++) {
        sClock += 3;
        SZFriendsOnlineAttempt *offer = world.a.attempts.firstObject;
        if (offer.order.phase != SZFriendsOnlinePhaseSignalling) {
            for (SZFODFakeConnection *connection in fakeA.connections.copy) [connection fail];
        }
        for (SZFriendsOnlineAttempt *attempt in [world.a.attempts arrayByAddingObjectsFromArray:world.b.attempts]) {
            [attempt fireTimers];
        }
        SZFODSpin(0.02);
    }
}

void SZFODTestReach(void) {
    // 1. The friend answers, no direct path connects and the relay is refused: Trying, then Failed.
    sClock = 1000;
    SZFODReachDelegate *delegate = [SZFODReachDelegate new];
    SZFODWorld *world = ReachWorld(delegate);
    NSData *peer = world.identityB.publicKey;
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachIdle, "nothing ran yet");
    [world.a reachFriend:peer];
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachTrying && [delegate.notices containsObject:peer],
           "an attempt runs, and the helper hears of it: %@", delegate.notices);
    EXPECT(SZFODWaitUntil(2, ^BOOL { return world.b.attempts.count == 1; }), "B answers");
    NSUInteger before = delegate.notices.count;
    RunOut(world);
    SZFriendsTechniqueLogEntry *entry = world.a.onlineContext.techniqueLog.entries.lastObject;
    EXPECT(world.a.attempts.count == 0 && entry.relayRequested && entry.endReason == SZFriendsOnlineEndUnreachable,
           "every path failed, the relay included: %@", entry.propertyList);
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachFailed, "failed everywhere");
    EXPECT(delegate.notices.count > before, "and the helper hears the attempt ended");
    NSDate *since = [world.a failedSinceForFriend:peer];
    EXPECT(since != nil, "the failure has a start");
    // Retries keep it: the header must not swap Couldn’t connect for Not connected with each one.
    sClock += SZFriendsOnlineBackoffFirst + 1;
    [world.a reachFriend:peer];
    EXPECT([world.a hasAttemptForFriend:peer] && [world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachFailed,
           "a retry runs, and the words stay failed");
    RunOut(world);
    EXPECT(world.a.attempts.count == 0 && [world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachFailed &&
               [[world.a failedSinceForFriend:peer] isEqualToDate:since],
           "the retry failed too: still failed, since the first failure");
    // The helper forgets it (something new queued, the conversation opened): the words follow the attempts again.
    before = delegate.notices.count;
    [world.a forgetFailureForFriend:peer];
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachIdle &&
               [world.a failedSinceForFriend:peer] == nil && delegate.notices.count > before,
           "forgotten, and the helper hears of it");
    sClock += SZFriendsOnlineBackoffMax + 1;
    [world.a reachFriend:peer];
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachTrying, "a retry after forgetting is Trying");
    RunOut(world);
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachFailed, "and failed everywhere again");
    // A network change forgets it: the next attempt may find a path.
    before = delegate.notices.count;
    [world.a networkChanged];
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachIdle && delegate.notices.count > before,
           "forgotten after a network change");
    // A stream opening forgets it, even from the retry that was still running.
    [world.a reachFriend:peer];
    RunOut(world);
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachFailed, "failed once more");
    sClock += SZFriendsOnlineBackoffFirst + 1;
    [world.a reachFriend:peer];
    SZFriendsOnlineAttempt *retry = world.a.attempts.firstObject;
    EXPECT(retry != nil && [world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachFailed, "a retry runs, failed");
    [world.a attempt:retry
        didOpenStream:[SZFODReachStream new]
                route:SZFriendsOnlineRouteMake(SZFriendsOnlineTechniqueServerReflexive, NO)];
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachTrying && world.a.delegate != nil,
           "a stream opened: no longer failed");
    // Stopping forgets every failure.
    NSMutableDictionary *failures = [world.a valueForKey:@"_failedEverywhere"];
    failures[peer] = [NSDate date];
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachFailed);
    [world stop];
    EXPECT([world.a failedSinceForFriend:peer] == nil && failures.count == 0, "stopped: nothing failed");

    // 2. Nobody answers (the friend is not online): never Failed, that is no failure anyone can act on.
    sClock = 1000;
    delegate = [SZFODReachDelegate new];
    world = ReachWorld(delegate);
    [world.b stop];
    [world.a reachFriend:peer = world.identityB.publicKey];
    EXPECT([world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachTrying);
    SZFODSpin(0.1);
    RunOut(world);
    EXPECT(world.a.attempts.count == 0 && [world.a reachOfFriend:peer] == SZFriendsOnlineFriendReachIdle,
           "unanswered: idle, not failed");
    [world stop];
}
