// A peer under the scenario's control (friends-e2e-check): it browses and listens on the scenario's loopback Bonjour
// type like a helper, but speaks the session protocol directly, so a scenario can do what a well-behaved helper
// never would (stop after HELLO, ask again under a new key, answer a request it overheard, say nothing at all).
//
// Loopback only, like everything in the harness: the test-only adapter on lo0, random identities made in memory (no
// key store, no Keychain), nothing written to disk. Everything runs on the rogue's own queue; the methods below may
// be called from the scenario's thread and wait for that queue.

#import <Foundation/Foundation.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

// One channel the rogue opened or accepted, and what happened on it.
@interface SZFE2ERogueSession : NSObject
@property(nonatomic, readonly) BOOL established;
@property(nonatomic, readonly, nullable) NSDate *establishedAt;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, readonly, nullable) NSError *closeError;
@property(nonatomic, readonly, nullable) NSDate *closedAt;
@property(nonatomic, readonly, nullable) NSDictionary<NSNumber *, NSData *> *publicProfile; // XX message 2
@property(nonatomic, readonly, nullable) NSString *code;                                    // comparison code
// Application frames received, oldest first, and when the first of each type arrived.
@property(nonatomic, readonly) NSArray<SZFriendsFrame *> *frames;
- (nullable NSDate *)firstArrivalOfType:(SZFriendsFrameType)type;
@property(nonatomic, readonly, nullable) NSData *handshakeHash;
- (BOOL)send:(SZFriendsFrame *)frame;
- (void)runCodeExchange;
- (void)close;
@end

@interface SZFE2ERogue : NSObject
- (instancetype)initWithServiceType:(NSString *)serviceType;
// The identity it presents now; -useFreshIdentity draws another (an answer "from someone else").
@property(nonatomic, readonly) SZFriendsIdentity *identity;
- (void)useFreshIdentity;
// Browses, listens, and advertises a hidden entry with a random tag, so helpers see an unrecognised device.
- (void)start;
- (void)stop;
// Endpoints of other devices on the type, as the adapter reported them; nil when none is seen yet.
- (nullable NSString *)publicEndpoint;
- (nullable NSString *)hiddenEndpoint;
// An initiator channel to `endpointID`; the session reports how it went.
- (SZFE2ERogueSession *)dial:(NSString *)endpointID options:(SZFriendsHandshakeOptions *)options;
// The same, showing `attestation` beside its certificate (SZFriendsSecureChannel.localAttestation): an IK callback
// that claims a holder's host attestation.
- (SZFE2ERogueSession *)dial:(NSString *)endpointID
                     options:(SZFriendsHandshakeOptions *)options
                 attestation:(nullable NSData *)attestation;
// NN requests other devices sent to its listener: the frame and the handshake hash it was signed over. It answers
// each with RECEIVED like any device.
@property(nonatomic, readonly) NSArray<SZFE2ERogueSession *> *requestsByID;
@end

@class SZFE2EWorld;

// What rogue scenarios share (SZFriendsE2ERogueScenarios.m). Handshake options for a pattern on the LAN route.
SZFriendsHandshakeOptions *SZFE2EOptions(SZFriendsHandshakePattern pattern, BOOL browseOnly);
// A started rogue once it sees the helper's hidden entry (and its public one with `needPublic`); nil after recording a
// failure.
SZFE2ERogue *_Nullable SZFE2EStartRogue(SZFE2EWorld *world, BOOL needPublic);
// Whether the session went live within 10 s.
BOOL SZFE2EWaitEstablished(SZFE2ERogueSession *session);
// IK options for answering the Add by ID the rogue overheard (the requester's static key, identity and token), as a
// holder's callback would dial it; nil after recording a failure when nothing was overheard within 15 s.
SZFriendsHandshakeOptions *_Nullable SZFE2EOverheardAnswerOptions(SZFE2ERogue *rogue);

// Fields for the frames a scenario sends.
NSData *SZFE2ERandomBytes(NSUInteger count);
SZFriendsFrame *SZFE2ERequestFrame(void);
SZFriendsFrame *SZFE2EProfileFrame(NSString *name);
SZFriendsFrame *SZFE2EMessageFrame(NSString *text);
SZFriendsFrame *SZFE2EAcceptFrame(void);

NS_ASSUME_NONNULL_END
