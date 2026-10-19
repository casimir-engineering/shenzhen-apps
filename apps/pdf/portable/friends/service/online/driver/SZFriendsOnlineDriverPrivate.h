// The driver's own seams, for SZFriendsOnlineDriver.m and the driver suite. Not a public header: the helper uses
// SZFriendsOnlineDriver.h.

#import "service/host/SZFriendsHostRendezvous.h"
#import "service/online/driver/SZFriendsOnlineAttemptInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsOnlineDriver () <SZFriendsHostOnlineDelegate, SZFriendsOnlineAttemptOwner>
// An open toward this helper, from any sid (the host's, or a suite's in-memory one). Only an IK message 1 from a
// friend with the static key we hold becomes an attempt; anything else is closed unanswered.
- (void)receiveOpenVia:(SZFriendsHostSignalVia)via
               channel:(id<SZFriendsOnlineSignalChannel>)channel
               payload:(NSData *)payload;
// Made on first use; tests read it to see what was (not) made.
@property(nonatomic, readonly) SZFriendsOnlineContext *onlineContext;
@property(nonatomic, readonly) NSArray<SZFriendsOnlineAttempt *> *attempts;
// Tests only: opens go here instead of to a host, and the driver counts as available while it is set.
@property(nonatomic, copy, nullable) void (^testOpener)
    (NSData *rdvKey, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel> _Nullable channel));
// Tests only: opens by Friends ID go here instead of to a host.
@property(nonatomic, copy, nullable) void (^testIDOpener)
    (NSString *friendsID, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel> _Nullable channel));
// Add by ID online (+ByID): the NN exchanges running, either way, and when this helper last opened by ID.
@property(nonatomic, strong, nullable) NSMutableArray *idExchanges;
@property(nonatomic, strong, nullable) NSMutableArray<NSNumber *> *idOpenTimes; // on the context's clock
@property(nonatomic, strong, nullable) NSMutableArray<NSNumber *> *joinOpenTimes; // the same, for to.join
@property(nonatomic, strong, nullable) SZFriendsReplayCache *idReplayCache;
// The host connection's online side (the attached one), backed by the driver's own ivar.
@property(nonatomic, readonly, nullable) SZFriendsHostOnline *online;
// Tests only: lookups go here instead of to a host.
@property(nonatomic, copy, nullable) void (^testLookup)
    (NSArray<NSData *> *keys, void (^completion)(NSArray<NSData *> *_Nullable blobs, NSError *_Nullable error));
// Tests only: what the default routes are, instead of reading the routing table.
@property(nonatomic, copy, nullable) NSString * (^testNetworkSignature)(void);
// The system's network-change notification arrived (debounced; acts only when the signature changed).
- (void)scheduleNetworkChange;
- (void)watchNetwork;
@end

// Add by ID online (SZFriendsOnlineDriver+ByID.m).
@interface SZFriendsOnlineDriver (ByIDInternal)
// An open via a Friends ID: NN message 1 is answered, REQUEST_BY_ID read and RECEIVED sent back; nothing else is.
- (void)answerIDOpenWithChannel:(id<SZFriendsOnlineSignalChannel>)channel payload:(NSData *)payload;
// The person an IK message 1 presenting `token` may come from, or nil (the delegate decides; pure).
- (nullable SZFriendsOnlineFriend *)friendAnsweringWithIdentityKey:(NSData *)identityKey token:(NSData *)token;
- (void)closeIDExchanges;
@end

// Joining a profile (SZFriendsOnlineDriver+Join.m).
@interface SZFriendsOnlineDriver (JoinInternal)
// An open via a Friends ID: a join payload ('J') goes to the delegate (or the channel is closed), never to Add by ID;
// anything else is Add by ID's (-answerIDOpenWithChannel:payload:).
- (void)routeIDOpenWithChannel:(id<SZFriendsOnlineSignalChannel>)channel payload:(NSData *)payload;
// An open by Friends ID (as above) or via to.join (protocol 3), where only a join payload is answered.
- (void)routeOpenVia:(SZFriendsHostSignalVia)via
             channel:(id<SZFriendsOnlineSignalChannel>)channel
             payload:(NSData *)payload;
// The open budget Add by ID uses (+ByID): NO once 5 opens by ID went out this hour.
- (BOOL)takeIDOpen;
// Joining's own budget (+ByID), the host's for to.join: NO once SZFriendsOnlineJoinOpensPerHour went out this hour.
- (BOOL)takeJoinOpen;
@end

@interface SZFriendsOnlineDriverTestHooks (Registry)
// Every driver made is reachable by +simulateNetworkChange (weakly held).
+ (void)registerDriver:(SZFriendsOnlineDriver *)driver;
@end

// Both helpers apply this to two simultaneous attempts: the side whose identity key sorts first keeps its offer.
BOOL SZFriendsOnlineKeySortsFirst(NSData *key, NSData *other);

// The stun: URIs in order, as numeric endpoints: an address is taken as it is, a name is resolved (blocking: call off
// the helper's queue). URIs that do not parse or resolve are left out.
NSArray<SZFriendsNATEndpoint *> *SZFriendsOnlineResolveSTUNURIs(NSArray<NSString *> *uris);

// The IPv4 and IPv6 default routes as one string: interface, gateway and source address of each. Reads the routing
// table (RTM_GET, nothing sent).
NSString *SZFriendsOnlineNetworkSignature(void);

NS_ASSUME_NONNULL_END
