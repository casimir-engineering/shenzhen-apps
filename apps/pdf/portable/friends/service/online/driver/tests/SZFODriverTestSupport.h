// friends-driver-check: what the suite's files share. Drivers run on the main queue, which the tests turn by
// spinning the run loop; two drivers meet through in-memory sids instead of a host, and the transport binds to
// 127.0.0.1 only (SZFriendsOnlineDriverTestHooks.loopbackOnly). Every wait is bounded (at most 10 s).

#import <Foundation/Foundation.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFODFailures;
void SZFODFail(const char *file, int line, const char *expression, NSString *detail);
#define EXPECT(condition, ...)                                                                                      \
    do {                                                                                                            \
        if (!(condition)) SZFODFail(__FILE__, __LINE__, #condition, [NSString stringWithFormat:@"" __VA_ARGS__]);   \
    } while (0)

// Turns the main queue until `condition` holds or `timeout` (capped at 10 s) passes.
BOOL SZFODWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void));
void SZFODSpin(NSTimeInterval seconds);
SZFriendsIdentity *SZFODNewIdentity(void);
NSData *SZFODRandom(NSUInteger count);

// One end of an in-memory sid: payloads reach the other end on a later turn of the main queue.
@interface SZFODChannel : NSObject <SZFriendsOnlineSignalChannel>
+ (NSArray<SZFODChannel *> *)pair;
@property(nonatomic, weak, nullable) SZFODChannel *peer;
@property(nonatomic, readonly) NSMutableArray<NSData *> *sent;
@property(nonatomic, readonly) BOOL closed;
// What -requestRelayCredentials: answers; nil refuses (no relay).
@property(nonatomic, copy, nullable) id<SZFriendsOnlineRelayCredentials> _Nullable (^credentials)(void);
@end

// A delegate holding friends by identity key, the nearby route, and every stream it was handed.
@interface SZFODDelegate : NSObject <SZFriendsOnlineDriverDelegate>
@property(nonatomic, readonly) NSMutableDictionary<NSData *, SZFriendsOnlineFriend *> *friends;
@property(nonatomic) SZFriendsRouteMethod nearbyRoute;
@property(nonatomic, readonly) NSMutableArray<id<SZFriendsByteStream>> *streams;
@property(nonatomic, readonly) NSMutableArray<NSNumber *> *routes;      // SZFriendsRouteMethod of each stream
@property(nonatomic, readonly) NSMutableArray<NSNumber *> *initiators;  // BOOL of each stream
@property(nonatomic, readonly) NSMutableArray<NSData *> *received;      // bytes read from every stream, in order
@property(nonatomic) NSUInteger availabilityCalls;
@end

// A friend as the other side's delegate holds it.
SZFriendsOnlineFriend *SZFODFriendFor(SZFriendsIdentity *identity, NSData *presenceSecret);

// Two drivers whose opens meet in memory: A's -reachFriend: becomes an open B receives, and the other way round.
@interface SZFODWorld : NSObject
- (instancetype)initWithTransportFactory:(nullable id<SZFriendsOnlineTransport> (^)(void))factory;
@property(nonatomic, readonly) SZFriendsIdentity *identityA, *identityB;
@property(nonatomic, readonly) SZFriendsOnlineDriver *a, *b;
@property(nonatomic, readonly) SZFODDelegate *delegateA, *delegateB;
// Every sid opened so far, the opener's end first in each pair.
@property(nonatomic, readonly) NSMutableArray<NSArray<SZFODChannel *> *> *sids;
// What each new sid's ends answer to -requestRelayCredentials:.
@property(nonatomic, copy, nullable) id<SZFriendsOnlineRelayCredentials> _Nullable (^credentials)(void);
- (void)befriend;
- (void)stop;
@end

// A transport that never touches the stack: it records what it was asked, and makes connections that create a
// dummy description and then wait.
@interface SZFODFakeConnection : NSObject <SZFriendsOnlineConnection>
@property(nonatomic, readonly) NSUInteger answersApplied;
@property(nonatomic, readonly) NSUInteger candidatesAdded;
@property(nonatomic, readonly) BOOL closed;
// Every path failed before a stream opened (ICE gave up): tells the attempt, as the real connection does.
- (void)fail;
@end

@interface SZFODFakeTransport : NSObject <SZFriendsOnlineTransport>
@property(nonatomic, readonly) NSMutableArray<SZFODFakeConnection *> *connections;
@property(nonatomic, readonly) NSMutableArray<id<SZFriendsOnlineConnectionRequest>> *requests;
@end

void SZFODTestGating(void);
void SZFODTestBackoffLookups(void);
void SZFODTestBackoffLookupsUnderTheRoot(void);
void SZFODTestHelpers(void);
void SZFODTestSidePath(void);
void SZFODTestDirect(void);
void SZFODTestSimultaneous(void);
void SZFODTestBackWhileWeWait(void);
void SZFODTestRelayAndLeave(void);
void SZFODTestProbing(void);
void SZFODTestNetworkChange(void);
void SZFODTestReach(void);
void SZFODTestByID(void);
void SZFODTestJoin(void);

NS_ASSUME_NONNULL_END
