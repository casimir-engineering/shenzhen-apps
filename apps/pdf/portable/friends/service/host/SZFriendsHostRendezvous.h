// Shenzhen Friends host protocol 2 (online Friends), the helper's side: rendezvous records, lookups, connection setup
// and relay credentials, over the check-in client's own connection.
//
// Helper-only. ADR 0010 is the decision and portable/server/friends/HOST-PROTOCOL-ONLINE.md the protocol; this header
// is the helper's side of it. Everything here moves opaque bytes: the sealed record blob, every signalling payload
// and the meaning of both belong to the session area (service/session/SZFriendsSignaling.h), and when to open what
// to the online order component. The host never learns from this side who a payload is for beyond the rendezvous
// key, Friends ID or link id named in an open.
//
// Online messages go only to a host whose welcome said `online: true` (HOST-PROTOCOL-ONLINE.md § Who may send these
// messages); with a host that runs protocol 1, or with FRIENDS_M2 off, nothing here is sent, the check-in stays
// exactly what it was, and Nearby is unaffected either way. Online Friends never depends on a host to work nearby.
//
// Threading: every method is called on the check-in client's queue, and every callback and completion arrives there.

#import "service/host/SZFriendsHostConnection.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Wire values (HOST-PROTOCOL-ONLINE.md; mirrored by server/friends/src/online-protocol.js)

extern NSString *const SZFriendsHostRendezvousKeyDomain;    // "SZFriends rendezvous key v1"
extern NSString *const SZFriendsHostRendezvousRecordDomain; // "SZFriends rendezvous record v1"
extern const NSUInteger SZFriendsHostSealedRecordLength;    // 512 bytes, exactly
extern const NSUInteger SZFriendsHostLookupKeysMax;         // 32 keys per rdv_lookup; more are split
extern const NSUInteger SZFriendsHostSignalPayloadMax;      // 4,096 bytes per sig_open or sig_msg payload
extern const NSUInteger SZFriendsHostSignalMessagesMax;     // 64 sig_msg each way per sid; the 65th would end it
// Lookups change only at the boundaries of the host's 60 s periods, and show a record during the period after the
// one it was published in, so the helper publishes once in every period, at a random moment in its first half.
extern const NSTimeInterval SZFriendsHostRecordPeriod;      // 60 s
extern const NSTimeInterval SZFriendsHostRecordLifetime;    // 300 s: each record's expiry, in host time
// Lookups, opens and credential requests the host has not answered within this fail with TimedOut.
extern const NSTimeInterval SZFriendsHostOnlineTimeout;     // 10 s

// SHA-256(UTF-8("SZFriends rendezvous key v1") || identity key): a person's rendezvous key. Nil unless 32 bytes.
NSData *_Nullable SZFriendsHostRendezvousKey(NSData *identityKey);
// What a record's signature covers after its domain: the length-prefixed host id, rdv key, seq and expiry (decimal)
// and SHA-256 of the sealed blob (HOST-PROTOCOL-ONLINE.md § Signatures).
NSData *SZFriendsHostRendezvousRecordMessage(NSString *hostID, NSData *rdvKey, uint64_t seq, int64_t expires,
                                             NSData *sealed);

#pragma mark - Errors

extern NSErrorDomain const SZFriendsHostOnlineErrorDomain;
extern NSString *const SZFriendsHostLinkEndedKey;

typedef NS_ERROR_ENUM(SZFriendsHostOnlineErrorDomain, SZFriendsHostOnlineError) {
    SZFriendsHostOnlineErrorUnavailable = 1, // no host takes online messages now, or the connection ended first
    SZFriendsHostOnlineErrorRateLimited = 2, // the host's budget for this identity or connection
    SZFriendsHostOnlineErrorInvalid = 3,     // outside the protocol's bounds (key or payload size, an ended sid)
    SZFriendsHostOnlineErrorTimedOut = 4,    // no answer within SZFriendsHostOnlineTimeout
    SZFriendsHostOnlineErrorNotAnswered = 5, // relay credentials: the far end has not spoken on this sid
    SZFriendsHostOnlineErrorNoRelay = 6,     // relay credentials: this host runs no relay
    // An open to a link nobody holds that its sender ended: userInfo SZFriendsHostLinkEndedKey says "revoked" or
    // "expired" (sig_opened's link_ended, HOST-PROTOCOL-ONLINE.md § Download links).
    SZFriendsHostOnlineErrorLinkEnded = 7,
};

#pragma mark - Connection setup

typedef NS_ENUM(NSInteger, SZFriendsHostSignalVia) {
    SZFriendsHostSignalViaRendezvous = 1, // a friend or own device, by rendezvous key
    SZFriendsHostSignalViaFriendsID = 2,  // Add by ID online
    SZFriendsHostSignalViaLink = 3,       // a download link
    SZFriendsHostSignalViaJoin = 4,       // protocol 3: a new computer asking to join the person holding a Friends ID
};

// Why a sid ended. From a target that has not answered there is no ending at all: it stays silent and the sid expires
// (Expired), exactly as when nobody is there.
typedef NS_ENUM(NSInteger, SZFriendsHostSignalEnd) {
    SZFriendsHostSignalEndClosed = 1,            // the far end, having spoken, closed it
    SZFriendsHostSignalEndGone = 2,              // the far end, having spoken, disconnected
    SZFriendsHostSignalEndExpired = 3,           // 120 s passed (a link's sid: after its sender came back)
    SZFriendsHostSignalEndLimit = 4,             // 64 messages one way
    SZFriendsHostSignalEndUnknown = 5,           // the host no longer knows this sid
    SZFriendsHostSignalEndAnsweredElsewhere = 6, // incoming: another device of this person answered first
    SZFriendsHostSignalEndConnectionLost = 7,    // this helper's own connection to the host ended
};

// TURN REST credentials for one relay attempt (HOST-PROTOCOL-ONLINE.md § Relay credentials).
@interface SZFriendsHostRelayCredentials : NSObject
// The turn: URIs to use, from the signed host list: the connected host's own when it is a relay, otherwise every
// relay host's in priority order. Never from the host's answer (only guests get those).
@property(nonatomic, readonly) NSArray<NSString *> *turnURIs;
@property(nonatomic, readonly) NSString *username;   // "<expires>:<attempt id>"
@property(nonatomic, readonly) NSString *credential; // base64 HMAC-SHA1
@property(nonatomic, readonly) NSDate *expires;      // an allocation must start before this
@end

// One sid: an open this helper made, or one made toward it.
@interface SZFriendsHostSignal : NSObject
@property(nonatomic, readonly) NSString *sid;
@property(nonatomic, readonly) SZFriendsHostSignalVia via;
@property(nonatomic, readonly) BOOL incoming;
@property(nonatomic, readonly, nullable) NSData *linkID; // via a link: its 16-byte id
// An open to a link: whether the sender's helper is connected now (the only open that says).
@property(nonatomic, readonly) BOOL ownerOnline;
@property(nonatomic, readonly) BOOL ended;
// Each payload from the far end, in order. For an open this helper made, the first is the target's answer.
@property(nonatomic, copy, nullable) void (^onPayload)(NSData *payload);
// Once, when the sid ends other than by -close.
@property(nonatomic, copy, nullable) void (^onEnd)(SZFriendsHostSignalEnd reason);
// Sends one payload (1 to SZFriendsHostSignalPayloadMax bytes). NO, sending nothing, once ended, for a bad size, or
// for the 65th payload, which would end the sid for both. An incoming target answers with its first payload.
- (BOOL)sendPayload:(NSData *)payload;
// Ends this side: sig_close, and nothing more arrives. A target that never answered stays nobody to the caller.
- (void)close;
// Relay credentials for this sid, once both ends have spoken (ADR 0010: at most 2 per end per sid).
- (void)requestRelayCredentials:(void (^)(SZFriendsHostRelayCredentials *_Nullable credentials,
                                          NSError *_Nullable error))completion;
@end

@class SZFriendsHostOnline;

@protocol SZFriendsHostOnlineDelegate <NSObject>
// Online messages may now be sent (checked in with a host whose welcome said online), or no longer may. Every open
// sid has ended (ConnectionLost) before NO arrives.
- (void)hostOnline:(SZFriendsHostOnline *)online didChangeAvailability:(BOOL)available;
// Someone opened a sid toward this helper; `payload` is their first message (sig_incoming). Answer with
// -sendPayload:, or stay silent and -close it: a target that never answers is indistinguishable from nobody.
- (void)hostOnline:(SZFriendsHostOnline *)online
    didReceiveSignal:(SZFriendsHostSignal *)signal
             payload:(NSData *)payload;
@end

@interface SZFriendsHostOnline : NSObject
@property(nonatomic, weak, nullable) id<SZFriendsHostOnlineDelegate> delegate;
@property(nonatomic, readonly) BOOL available;
// The host the connection checked in with, while available.
@property(nonatomic, readonly, nullable) NSString *hostID;
// Asked once per period while available: this device's record blob, freshly sealed (SZFriendsSealRendezvousRecord;
// exactly 512 bytes), or nil to publish nothing this period (Friends off, no presence secret yet). Unset: nothing is
// published and this helper is not reachable by key or by Friends ID.
@property(nonatomic, copy, nullable) NSData *_Nullable (^sealedRecordProvider)(void);
// When lookups start to show the last record the host accepted (the start of the host's next period, on this
// helper's clock); nil before the first and after the connection ends.
@property(nonatomic, readonly, nullable) NSDate *recordShownFrom;

// Rendezvous keys (32 bytes each) to 512-byte blobs, in order: a record's or the host's filler, which only the
// presence secret tells apart (SZFriendsOpenRendezvousRecord). Any number of keys, sent 32 per message.
- (void)lookupRendezvousKeys:(NSArray<NSData *> *)keys
                  completion:(void (^)(NSArray<NSData *> *_Nullable blobs, NSError *_Nullable error))completion;
@end

@interface SZFriendsHostOnline (Signaling)
// sig_open. The completion gets the sid at once whatever exists (the host answers before looking), or an error.
- (void)openToRendezvousKey:(NSData *)rdvKey
                    payload:(NSData *)payload
                 completion:(void (^)(SZFriendsHostSignal *_Nullable signal, NSError *_Nullable error))completion;
- (void)openToFriendsID:(NSString *)friendsID
                payload:(NSData *)payload
             completion:(void (^)(SZFriendsHostSignal *_Nullable signal, NSError *_Nullable error))completion;
// sig_open to.join (protocol 3): a join request or code to every connected device of the person holding `friendsID`.
- (void)openToJoinFriendsID:(NSString *)friendsID
                    payload:(NSData *)payload
                 completion:(void (^)(SZFriendsHostSignal *_Nullable signal, NSError *_Nullable error))completion;
- (void)openToLinkID:(NSData *)linkID
             payload:(NSData *)payload
          completion:(void (^)(SZFriendsHostSignal *_Nullable signal, NSError *_Nullable error))completion;
@end

@interface SZFriendsCheckInClient (Online)
// The client's online side, made on first use and kept for the client's life. Call on the client's queue.
@property(nonatomic, readonly) SZFriendsHostOnline *online;
@end

NS_ASSUME_NONNULL_END
