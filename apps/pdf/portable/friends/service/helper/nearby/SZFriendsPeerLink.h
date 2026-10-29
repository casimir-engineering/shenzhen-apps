// One secure channel to one device, as the helper's nearby orchestration tracks it: what it was opened for, which
// conversation it belongs to once known, what it has in flight, and the chunk flows it carries.
//
// Internal to the helper. A link never decides anything; SZFriendsNearbyService does, on the helper queue, which is
// also the queue every channel callback runs on.

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsSyncExchange;
@class SZFriendsAgainExchange;
@class SZFriendsDeviceChain;
@class SZFriendsBlockExchange;

// Why a link exists. A responder link starts as Incoming and is classified by its handshake.
typedef NS_ENUM(NSInteger, SZFriendsLinkPurpose) {
    SZFriendsLinkPurposeIncoming = 0, // accepted from a listener
    SZFriendsLinkPurposeFriend = 1,   // IK to a known person (a friend, or a request in either direction)
    SZFriendsLinkPurposeBrowse = 2,   // XX to a public entry, stopping after its profile (who is this?)
    SZFriendsLinkPurposeRequest = 3,  // XX to a public entry to deliver a nearby friend request
    SZFriendsLinkPurposeByID = 4,     // NN carrying one Add by ID request (ADR 0004 step 1)
    SZFriendsLinkPurposeJoin = 5,     // NN from a computer joining a profile: its request, or its code (+Join)
    SZFriendsLinkPurposeOwnDevice = 6, // IK to another device of this person's, to sync (+Sync)
};

// 32 lowercase hex digits <-> 16 bytes: the store's ids and the wire's ID fields name the same thing.
NSString *SZFriendsLinkHex(NSData *data);
NSData *_Nullable SZFriendsLinkBytesFromHex(NSString *_Nullable hex); // nil unless exactly 32 hex digits

@interface SZFriendsPeerLink : NSObject
- (instancetype)initWithChannel:(SZFriendsSecureChannel *)channel
                        purpose:(SZFriendsLinkPurpose)purpose
                          route:(SZFriendsRouteMethod)route NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) SZFriendsSecureChannel *channel;
@property(nonatomic, readonly) SZFriendsLinkPurpose purpose;
// The route the stream runs over as this side knows it before the handshake (the dialed sighting, or the
// listener's classification). Once live, the race uses the channel's initiatorRoute, which both sides share.
@property(nonatomic, readonly) SZFriendsRouteMethod dialedRoute;
@property(nonatomic, copy, nullable) NSString *endpointID;   // initiator: what was dialed
@property(nonatomic) NSInteger discoveryMethod;              // SZFriendsDiscoveryMethod of endpointID
@property(nonatomic) BOOL publicEntry;                       // responder: arrived through the public entry
// An IK attempt at a device whose tag matched nobody, hoping it is this person: failing is the normal outcome, so
// it never counts against the person's backoff.
@property(nonatomic) BOOL probe;
@property(nonatomic, copy, nullable) NSString *dialKey;      // initiator: its entry in the service's dialing set
@property(nonatomic, copy, nullable) NSString *conversationID;
@property(nonatomic, copy, nullable) NSData *requestToken;  // NN: the request it carries; IK: the token presented
@property(nonatomic) BOOL live;                              // established (responder: HELLO received)
@property(nonatomic) BOOL adopted;                           // carries this conversation's traffic
@property(nonatomic) BOOL superseded;                        // lost the race; closing after its in-flight ACKs
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL profileSent;
@property(nonatomic) BOOL createsFriendship;                 // runs the comparison-code exchange
@property(nonatomic) BOOL codeExchangeStarted;               // runs once per link, and only when no code is stored
@property(nonatomic, copy, nullable) NSString *comparisonCode;
// Responder: admitted by the key policy as someone who is not a friend (counted against SZFriendsStrangerSessionsMax).
@property(nonatomic) BOOL stranger;
// Responder: an unknown key let in only by our Add by ID token. Until that person is a friend the session carries
// friendship creation only (PROFILE, ACCEPT, DECLINE, ACK), whatever else they send.
@property(nonatomic) BOOL tokenAdmitted;
// A live session with another device of this person's (+Sync): it carries CHAIN and SYNC and nothing else, belongs to
// no conversation, and its exchange runs until it ends. syncDeviceHex names the device a dial was meant for.
@property(nonatomic) BOOL ownDevice;
@property(nonatomic, strong, nullable) SZFriendsSyncExchange *syncExchange;
@property(nonatomic, copy, nullable) NSString *syncDeviceHex;
// A session with a friend at session minor 3 or later (+Again): files asked for again, either way.
@property(nonatomic, strong, nullable) SZFriendsAgainExchange *againExchange;
// Responder of an IK callback presenting our Add by ID token: the Friends ID that request asked for, and whether the
// answer showed the host's attestation for it. An ACCEPT the host did not vouch for becomes a request the person
// accepts (+Inbound), never a friendship by itself (wave-4 security re-check).
@property(nonatomic, copy, nullable) NSString *answerForID;
@property(nonatomic) BOOL answerAttested;
// Initiator, NN: the device answered RECEIVED (our request reached it), and the attempt this link made, which is
// tried again soon when the device never answered.
@property(nonatomic) BOOL byIDAnswered;
@property(nonatomic, copy, nullable) NSString *attemptKey;
// When the session last moved forward (or went live): sessions with people who are not friends end
// SZFriendsStrangerIdleTimeout after it. Only frames that advance a request count (+Limits), so repeating one frame
// cannot keep a stranger's session open.
@property(nonatomic, nullable) NSDate *lastApplicationFrameAt;
@property(nonatomic) BOOL idleCheckScheduled;
// Which request-advancing frames already arrived once on this link: a second copy moves nothing forward.
@property(nonatomic) BOOL profileReceived;
@property(nonatomic) BOOL requestReceived;
@property(nonatomic) BOOL answerReceived;
@property(nonatomic, copy, nullable) NSDictionary<NSNumber *, NSData *> *pendingProfile; // before REQUEST names them
@property(nonatomic, readonly) NSDate *createdAt;
@property(nonatomic, nullable) NSDate *liveAt;

// The race's facts once live: the route class the initiator declared and the initiator's identity key.
@property(nonatomic, readonly) SZFriendsRouteMethod raceRoute;
- (nullable NSData *)initiatorKeyWithLocalKey:(NSData *)localIdentityKey;

// Outbox entries written on this link and not yet acknowledged, by id: a lost link sends them back to Queued.
@property(nonatomic, readonly) NSMutableSet<NSString *> *inFlightEntries;
// What each ACK this link may receive acknowledges, oldest first per wire ID (hex): an outbox entry id, or a
// transfer id prefixed "done:" for the ACK that follows DONE. The peer acknowledges in the order it processes
// frames, so the oldest token for an ID is the one an ACK answers.
- (void)expectAckForID:(NSString *)wireID token:(NSString *)token;
- (nullable NSString *)takeAckForID:(NSString *)wireID;
// Whether an ACK for this wire ID would acknowledge something this link sent (without taking it).
- (BOOL)expectsAckForID:(NSString *)wireID;

// Chunk flows on this link, by transfer id.
@property(nonatomic, readonly) NSMutableDictionary<NSString *, SZFriendsChunkSender *> *senders;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, SZFriendsChunkReceiver *> *receivers;
// Transfers this link stopped carrying (cancelled, declined, moved): their late chunks are dropped, not refused.
@property(nonatomic, readonly) NSMutableSet<NSString *> *endedTransfers;
@property(nonatomic, readonly) NSMutableSet<NSString *> *doneSent;
// Previews (THUMBNAIL) this link sent that the friend's Mac has not acknowledged yet, by transfer id: once per link.
@property(nonatomic, readonly) NSMutableSet<NSString *> *thumbnailsSent;
// Rate measurement per transfer: first offset and time seen on this link.
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSArray *> *rateStart;
// Open snapshots of outgoing files being sent on this link, by transfer id.
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSFileHandle *> *sources;
@property(nonatomic, nullable) dispatch_source_t progressTimer;
// Files by blocks on this session (ADR 0018), when it negotiated fast transfers with a friend (+Blocks).
@property(nonatomic, strong, nullable) SZFriendsBlockExchange *blocks;
@property(nonatomic) BOOL blockFlushScheduled;
// A lane (ADR 0018 § 6): another session with the same device, admitted by its token into the group of `laneHead`,
// the first session. A lane never races and carries no conversation of its own: its frames count as the head's.
@property(nonatomic, weak, nullable) SZFriendsPeerLink *laneHead;
@property(nonatomic) uint8_t laneIndex;
@property(nonatomic) BOOL lane;
// The head's admitted lanes.
@property(nonatomic, readonly) NSHashTable<SZFriendsPeerLink *> *lanes;
@property(nonatomic) BOOL pumpScheduled;
// Chunk pacing (SZFriendsHelperTestHooks.chunkBytesPerSecond): bytes handed out since paceStart.
@property(nonatomic) CFAbsoluteTime paceStart;
@property(nonatomic) uint64_t paceBytes;
// First contact from a device other than a person's first (+Chain): our chain went out before our request or answer
// on this session; theirs, verified, arrived before their request.
@property(nonatomic) BOOL firstContactChainSent;
@property(nonatomic) BOOL chainSent; // our chain went on this session to a friend (+Chain)
@property(nonatomic, strong, nullable) SZFriendsDeviceChain *pendingChain;
- (void)cancelTimers;
@end

NS_ASSUME_NONNULL_END
