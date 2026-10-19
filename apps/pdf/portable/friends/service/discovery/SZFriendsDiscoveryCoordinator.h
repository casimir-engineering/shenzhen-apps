// Shenzhen Friends discovery coordinator: runs the adapters side by side for the helper and feeds one merger.
//
// Helper-only. ADR 0004 § Merger and § Permissions at launch. Each adapter starts, stops and reports on its own,
// and nothing here waits for one method before using another: a denied, off, failing or silent method never
// delays or hides what the others find (brief § Parallel discovery). The coordinator adds no policy of its own
// beyond that wiring: tags come from SZFriendsDiscovery.h, sessions from the session layer, visibility from
// SZFriendsVisibility. Everything runs on the queue given at init.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsDiscoveryCoordinator;

@protocol SZFriendsDiscoveryCoordinatorDelegate <NSObject>
// The merger's candidates, identified candidates or unmatched devices changed (its generation moved).
- (void)discoveryCoordinatorDidChangeCandidates:(SZFriendsDiscoveryCoordinator *)coordinator;
- (void)discoveryCoordinator:(SZFriendsDiscoveryCoordinator *)coordinator
              didChangeState:(SZFriendsAdapterState)state
                    ofMethod:(SZFriendsDiscoveryMethod)method;
// An incoming stream from either adapter; `publicEntry` as in SZFriendsDiscoveryAdapterDelegate.
- (void)discoveryCoordinator:(SZFriendsDiscoveryCoordinator *)coordinator
             didAcceptStream:(id<SZFriendsByteStream>)stream
                       route:(SZFriendsRouteMethod)route
                 publicEntry:(BOOL)publicEntry;
@end

@interface SZFriendsDiscoveryCoordinator : NSObject <SZFriendsDiscoveryAdapterDelegate>
// One adapter per method. `clock` stamps removals and expiry (injected for tests; the helper passes
// ^{ return [NSDate date]; }).
- (instancetype)initWithAdapters:(NSArray<id<SZFriendsDiscoveryAdapter>> *)adapters
                          merger:(SZFriendsDiscoveryMerger *)merger
                           queue:(dispatch_queue_t)queue
                           clock:(NSDate * (^)(void))clock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, weak, nullable) id<SZFriendsDiscoveryCoordinatorDelegate> delegate;
@property(nonatomic, readonly) SZFriendsDiscoveryMerger *merger;
@property(nonatomic, readonly) SZFriendsRouteRacer *racer;

// Launch, before any `activate`: starts each adapter SZFriendsStartAdapterAtLaunch allows from its own
// permission read. One whose permission reads Denied is reported Denied and not started; the others still start.
- (void)startAtLaunchWithNearbyPermissionsRequested:(BOOL)nearbyPermissionsRequested;
// The person opened Friends (`activate`): starts every adapter not yet running. This is what may prompt.
- (void)activate;
// After a wake: restarts running adapters so they look again at once. Check the visibility deadline and
// re-advertise before calling this, so an expired public entry is never put back on the air.
- (void)restartAfterWake;
// Disable or quit: stops every adapter and forgets every sighting.
- (void)stop;
// What Nearby shows per method: NotAsked until started, Denied when the launch read said so, then the adapter's.
- (SZFriendsAdapterState)stateOfMethod:(SZFriendsDiscoveryMethod)method;

// Sends the same advertisement to every adapter now, and again to any adapter started later. Callback tags go out
// as exactly SZFriendsCallbackTagsMax slots, the same on both adapters (SZFriendsCallbackSlots).
- (void)advertisePresenceTag:(nullable NSData *)tag
                callbackTags:(NSArray<NSData *> *)callbackTags
                 publicEntry:(BOOL)publicEntry;

// The admission limits every adapter applies to incoming connections; set it to change them (the default is
// SZFriendsAdmissionLimits.defaultLimits). Applied to adapters that implement -setAdmissionLimits:.
@property(nonatomic, copy) SZFriendsAdmissionLimits *admissionLimits;

// Dials a candidate as the racer says: each attempt after its delay, started only if
// -[SZFriendsRouteRacer shouldStartAttempt:currentRoute:] still agrees with `currentRoute()` asked at that moment.
// `onStream` gets every stream that opens; the session layer runs the handshake and asks the racer what to keep.
// Failed attempts are silent: another route or the next sighting retries. `delayScale` (default 1) shortens the
// stagger in tests.
- (void)dialCandidate:(SZFriendsCandidate *)candidate
         currentRoute:(SZFriendsRouteMethod (^)(void))currentRoute
             onStream:(void (^)(id<SZFriendsByteStream> stream, SZFriendsDialAttempt *attempt))onStream;
@property(nonatomic) double delayScale;

// Drops expired sightings now (the coordinator also schedules this itself at the merger's next expiry).
- (void)expireSightings;
@end

NS_ASSUME_NONNULL_END
