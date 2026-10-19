// Shared by the online transport suite: checks, bounded waits, request and credential objects, a recording
// delegate, an in-process signalling pair standing in for the host and the Noise exchange, and ADR 0001 transfers
// over the resulting streams. Everything runs on 127.0.0.1 through the transport's testing initializer.
//
// Every wait is bounded (at most 10 s), so a hang fails the suite instead of stalling the build.

#import <Foundation/Foundation.h>

#import "service/online/transport/SZFriendsOnlineTransportInternal.h"
#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFOFailures;
void SZFOFail(const char *file, int line, const char *expression, NSString *detail);
#define SZFO_CHECK(condition, ...)                                                                                  \
    do {                                                                                                            \
        if (!(condition)) SZFOFail(__FILE__, __LINE__, #condition, [NSString stringWithFormat:@"" __VA_ARGS__]);    \
    } while (0)

// Polls `condition` on `queue` every 10 ms until it holds or `timeout` (capped at 10 s) passes.
BOOL SZFOWaitUntil(dispatch_queue_t queue, NSTimeInterval timeout, BOOL (^condition)(void));
void SZFOOnQueue(dispatch_queue_t queue, dispatch_block_t block);
NSData *SZFOBytes(uint8_t value, NSUInteger count);

@interface SZFORequest : NSObject <SZFriendsOnlineConnectionRequest>
@property(nonatomic) SZFriendsOnlinePurpose purpose;
@property(nonatomic) SZFriendsOnlineRole role;
@property(nonatomic) SZFriendsOnlineConnectionKind kind;
@property(nonatomic, copy) NSData *peer;
@property(nonatomic, copy, nullable) NSString *stunURI;
@property(nonatomic, nullable) id<SZFriendsOnlineRelayCredentials> relay;
@property(nonatomic) uint16_t localPort;
@property(nonatomic, copy, nullable) NSString *remoteOfferSDP;
@property(nonatomic, copy, nullable) NSData *remoteFingerprint;
// A friend's direct offerer: the smallest request that passes the gating rule.
+ (instancetype)offererForPurpose:(SZFriendsOnlinePurpose)purpose;
@end

@interface SZFORelayCredentials : NSObject <SZFriendsOnlineRelayCredentials>
@property(nonatomic, copy) NSString *turnURI;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSString *credential;
@property(nonatomic) NSDate *expires;
@end

// Records every delegate callback, in order, on the connection's queue.
@interface SZFORecorder : NSObject <SZFriendsOnlineConnectionDelegate>
@property(nonatomic, readonly) NSMutableArray<NSString *> *events; // "description", "candidate", "gathered", ...
@property(nonatomic, copy, nullable) NSString *sdp;
@property(nonatomic, copy, nullable) NSData *fingerprint;
@property(nonatomic, readonly) NSMutableArray<NSString *> *candidates;
@property(nonatomic, readonly) NSMutableArray<NSNumber *> *techniques;
@property(nonatomic, readonly) NSMutableArray<id<SZFriendsByteStream>> *streams;
@property(nonatomic) SZFriendsOnlineRoute openedRoute;
@property(nonatomic, strong, nullable) NSError *error;
@property(nonatomic) NSUInteger eventsAfterClose; // set by tests that close the connection, then counted
@property(nonatomic) BOOL closedByTest;
// Forwarders the pair installs.
@property(nonatomic, copy, nullable) void (^onDescription)(NSString *sdp, NSData *fingerprint);
@property(nonatomic, copy, nullable) void (^onCandidate)(NSString *candidate, SZFriendsOnlineTechnique technique);
@end

// An offerer and an answerer on one transport, each on its own queue, with signalling forwarded in order: the offer
// opens the answerer (as IK message 1 would), the answer is applied by the offerer (IK message 2), and candidates
// wait until the far side may take them.
@interface SZFOPair : NSObject
- (instancetype)initWithTransport:(SZFriendsOnlineDataChannelTransport *)transport
                          purpose:(SZFriendsOnlinePurpose)purpose
                             kind:(SZFriendsOnlineConnectionKind)kind;
@property(nonatomic, readonly) dispatch_queue_t offererQueue, answererQueue;
@property(nonatomic, readonly) SZFORecorder *offererEvents, *answererEvents;
@property(nonatomic, readonly, nullable) id<SZFriendsOnlineConnection> offerer, answerer;
@property(nonatomic, nullable) id<SZFriendsOnlineRelayCredentials> offererRelay, answererRelay;
// Applied to the offer before the answerer opens: what a host in the middle would do. The fingerprint passed
// separately is `authenticatedOfferFingerprint` when set, else the offerer's own.
@property(nonatomic, copy, nullable) NSString *_Nullable (^rewriteOffer)(NSString *sdp);
@property(nonatomic, copy, nullable) NSData *authenticatedOfferFingerprint;
@property(nonatomic, strong, nullable) NSError *answererOpenError;
// Opens the offerer; the rest follows from the callbacks. NO when the offerer did not open.
- (BOOL)start;
- (BOOL)waitForStreams;      // both sides opened a stream (10 s)
- (void)close;
@end

// ADR 0001 over two streams: the offerer's side as IK initiator, the answerer's as responder, then `bytes` of
// pseudo-random data in CHUNK frames from the initiator, a DONE with BLAKE2b-256, and PROGRESS back. YES when the
// receiver's digest matched within `timeout`.
BOOL SZFOTransfer(id<SZFriendsByteStream> initiatorStream, id<SZFriendsByteStream> responderStream, uint64_t bytes,
                  NSTimeInterval timeout, NSTimeInterval *_Nullable seconds);

void SZFORunCandidateTests(void);
void SZFORunDescriptionTests(void);
void SZFORunGatingTests(void);
void SZFORunTimerTests(void);
void SZFORunLoopbackTests(void);
void SZFORunCancellationTests(void);
void SZFORunSidePathTests(void);
void SZFORunRelayTests(void);

NS_ASSUME_NONNULL_END
