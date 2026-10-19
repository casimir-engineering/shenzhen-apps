// The check-in client's private state, shared by its sources (SZFriendsCheckInClient.m and its +Attestation,
// +Release and +Reservation categories) and nothing else. Everything here is touched only on the client's queue.

#import "service/host/SZFriendsHostConnection.h"

#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFriendsCheckInPhase) {
    SZFriendsCheckInPhaseIdle = 0,       // no socket
    SZFriendsCheckInPhaseOpening = 1,    // waiting for the host's challenge
    SZFriendsCheckInPhaseCheckingIn = 2, // check-in sent, waiting for the welcome
    SZFriendsCheckInPhaseCheckedIn = 3,
    SZFriendsCheckInPhaseReleasing = 4, // release sent, waiting for the answer
};

// Cancels and clears a timer slot; nil is fine.
void SZFriendsHostCancelTimer(dispatch_source_t _Nullable __strong *_Nonnull timer);

// One URL of one rendezvous host, in the order the client tries them.
@interface SZFriendsHostCandidate : NSObject
@property(nonatomic) SZFriendsHostEntry *entry;
@property(nonatomic) NSURL *url;
@end

@class SZFriendsIdentity;
@class SZFriendsHostOnline;

@interface SZFriendsCheckInClient () {
    SZFriendsHostListCache *_cache;
    SZFriendsIdentity *_identity;
    NSString *_appVersion;
    SZFriendsHostSocketFactory _factory;
    dispatch_queue_t _queue;
    SZFriendsHostState _state;
    BOOL _running;
    SZFriendsIDProvider _Nullable _idProvider;
    id<SZFriendsHostSocket> _Nullable _socket;
    NSUInteger _generation;
    SZFriendsCheckInPhase _phase;
    NSArray<SZFriendsHostCandidate *> *_Nullable _candidates;
    NSUInteger _candidateIndex;
    NSData *_Nullable _challenge;
    NSUInteger _attempt;
    NSString *_Nullable _originalID; // the ID this connection claimed first; a rename notice names it
    NSString *_Nullable _pendingID;  // the ID most recently sent
    NSUInteger _collisions;
    NSUInteger _draws; // fresh IDs drawn since start, capped at SZFriendsHostMaxDrawsPerLaunch
    NSUInteger _unavailableRetries;
    dispatch_source_t _Nullable _connectTimer;
    dispatch_source_t _Nullable _retryTimer;
    dispatch_source_t _Nullable _reserveTimer;
    dispatch_source_t _Nullable _releaseTimer;
    void (^_Nullable _releaseCompletion)(BOOL released);
    nw_path_monitor_t _Nullable _pathMonitor;
    // Protocol 2's online side (SZFriendsHostRendezvous.m), made on first use of -online.
    SZFriendsHostOnline *_Nullable _online;
    // Read from any thread (-attestationForFriendsID:), so both are touched only under @synchronized(self).
    SZFriendsHostAttestation *_Nullable _attestation;
    NSData *_Nullable _personKey; // the root this connection checked in for
    BOOL _attestationLoaded; // attestationPath has been read once
}
- (void)setState:(SZFriendsHostState)state;
- (dispatch_source_t)timerAfter:(NSTimeInterval)delay handler:(void (^)(SZFriendsCheckInClient *client))handler;
- (void)beginRound;
- (void)closeSocket;
- (void)send:(NSString *)type fields:(NSDictionary<NSString *, id> *)fields;
- (BOOL)verifies:(NSDictionary<NSString *, id> *)message body:(NSArray *)body;
@end

@interface SZFriendsCheckInClient (Attestation)
// After a verified reservation of `friendsID`: keeps `value` (the answer's "attestation") when it checks out for this
// identity and that ID against the current list, writes it to attestationPath and tells the delegate. On the queue.
- (void)takeAttestation:(id _Nullable)value forFriendsID:(NSString *)friendsID;
// -attestationForFriendsID: (the public header) lands here.
- (nullable SZFriendsHostAttestation *)keptAttestationForFriendsID:(NSString *)friendsID;
// Reset Friends: the identity is going away, and so is anything a host said about it.
- (void)forgetAttestation;
@end

@interface SZFriendsCheckInClient (Reservation)
// A reservation's answer: `result` "reserved", "taken", "invalid" or "unavailable" with the ID and attestation the
// host gave. `adoptable`: a welcome may name another ID than the one claimed; an answer after a collision may not.
- (void)handleReservation:(id _Nullable)result
                friendsID:(id _Nullable)value
              attestation:(id _Nullable)attestation
                adoptable:(BOOL)adoptable;
@end

@interface SZFriendsCheckInClient (Release)
// -releaseIdentityWithCompletion: (the public header) lands here.
- (void)startReleaseWithCompletion:(void (^)(BOOL released))completion;
- (void)sendRelease;
- (void)finishRelease:(BOOL)released;
@end

NS_ASSUME_NONNULL_END
