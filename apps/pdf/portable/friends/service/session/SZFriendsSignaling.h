// Shenzhen Friends online signalling: what two helpers, or a browser and a helper, say to each other through the
// host's connection setup (sig_open, sig_msg; portable/server/friends/HOST-PROTOCOL-ONLINE.md), and the sealed blob
// of a rendezvous record.
//
// Helper-only. ADR 0009 § Who may reach the stack, ADR 0010 § Rendezvous records and § Connection setup, ADR 0011
// and the gating rule in service/online/SZFriendsOnlineTransport.h are the decisions; this header is their wire
// format. The host forwards every payload here unread: it sees neither identities, descriptions nor candidates.
//
// One item format, three ways to protect it:
//   1. Friends and own devices: Noise IK (ADR 0001's suite) under the signalling prologue
//      "SZFriends signal v1\0" || header, where the header is the first two bytes of message 1 ('S', pattern).
//      Message 1 carries the caller's certificate, its time, and usually the offer with its DTLS fingerprint;
//      message 2 the answerer's certificate and answer; every later payload is one Noise transport message.
//   2. Add by ID online: Noise NN under the same prologue with pattern NN. It authenticates nobody: it carries
//      REQUEST_BY_ID and RECEIVED (ADR 0004 step 1) as Frame items, and descriptions only after acceptance.
//   3. Download links: payloads sealed under keys derived from the link secret with what WebCrypto offers a browser
//      (HKDF-SHA-256, AES-256-GCM, HMAC-SHA-256), and a proof of the secret over the sender's fresh challenge
//      before the sender sends a description or creates a peer connection.
// The prologue differs from ADR 0001's ("SZFriends session\0"), so a signalling message 1 can never be replayed into
// a nearby listener, nor a nearby one into signalling.
//
// Every payload, sealed, is at most SZFriendsSignalPayloadMax bytes: the host's limit,
// SZFriendsOnlineSignalPayloadMax.
// Nothing here is logged or stored: descriptions and candidates hold addresses (ADR 0011 § Technique log).

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Limits

extern const NSUInteger SZFriendsSignalPayloadMax;      // 4,096 bytes per payload, as the host forwards it
extern const NSUInteger SZFriendsSignalSDPMax;          // 3,072 bytes of SDP in one Description
extern const NSUInteger SZFriendsSignalCandidateMax;    // 256 bytes per candidate line
extern const NSUInteger SZFriendsSignalFrameMax;        // 1,024 bytes of an ADR 0001 frame in a Frame item
// IK message 1 carries the caller's clock (Hello's Time); the answerer refuses one further than this from its own,
// so a captured message 1 is good only while the replay cache still remembers its ephemeral key (half of
// SZFriendsReplayWindow either side: a message accepted at T was first seen after T - 300 s and is remembered 600 s).
extern const NSTimeInterval SZFriendsSignalClockSkewMax; // 300 s

#pragma mark - Items

// Item types. Wire values: never renumber. A payload is one or more items: type:u8 len:u16be value, the value
// being fields tag:u8 len:u16be value (one tag namespace, below). Unknown item types and unknown tags are skipped,
// so later versions can add both; a duplicate tag, a known field of the wrong length or a missing required field
// fails the whole payload.
typedef NS_ENUM(uint8_t, SZFriendsSignalItemType) {
    // Added and read by SZFriendsSignalingSession itself, first in message 1 (both patterns) and message 2 (IK):
    // MinorMin, MinorMax, and for IK Time, Certificate, Attestation (optional), Token (optional, message 1).
    SZFriendsSignalItemHello = 1,
    SZFriendsSignalItemDescription = 2,   // Connection, Kind, SDP, Fingerprint: an offer or an answer
    SZFriendsSignalItemCandidate = 3,     // Connection, Technique, Candidate: one RFC 8839 line without "a="
    SZFriendsSignalItemCandidatesEnd = 4, // Connection: this side has sent its last candidate
    SZFriendsSignalItemNAT = 5,           // NATClass, NATStep (per-destination only): ADR 0011 § NAT class
    SZFriendsSignalItemStart = 6,         // Connection, Kind: the offerer starts probing or the relay (ADR 0011)
    SZFriendsSignalItemFrame = 7,         // Frame: an encoded ADR 0001 frame (NN: REQUEST_BY_ID, RECEIVED)
    SZFriendsSignalItemEnd = 8,           // Reason: this attempt is over for the sender (declined, cancelled, done)
    // Added and read by SZFriendsSignalingLink itself:
    SZFriendsSignalItemLinkNonce = 9,     // Nonce: the opener's, in its first payload
    SZFriendsSignalItemLinkChallenge = 10, // Nonce: the sender's challenge
    SZFriendsSignalItemLinkProof = 11,    // Proof: the opener's HMAC over both nonces
};

typedef NS_ENUM(uint8_t, SZFriendsSignalTag) {
    SZFriendsSignalTagConnection = 1,  // u8: which connection of this attempt (0 the first direct one; the offerer
                                       // numbers each relay or probe handover connection it starts)
    SZFriendsSignalTagKind = 2,        // u8: SZFriendsOnlineConnectionKind (1 direct, 2 probe handover, 3 relay)
    SZFriendsSignalTagSDP = 3,         // UTF-8, 1 to SZFriendsSignalSDPMax bytes
    SZFriendsSignalTagFingerprint = 4, // 32 bytes: SHA-256 of the sender's DTLS certificate, beside the SDP
    SZFriendsSignalTagTechnique = 5,   // u8: SZFriendsOnlineTechnique of a candidate
    SZFriendsSignalTagCandidate = 6,   // UTF-8, 1 to SZFriendsSignalCandidateMax bytes
    SZFriendsSignalTagNATClass = 7,    // u8: SZFriendsSignalNATClass
    SZFriendsSignalTagNATStep = 8,     // 2 bytes, signed big-endian: a per-destination NAT's port step
    SZFriendsSignalTagTime = 9,        // u64be Unix seconds, the sender's clock
    SZFriendsSignalTagMinorMin = 10,   // u16be: the signalling version range this sender speaks
    SZFriendsSignalTagMinorMax = 11,   // u16be
    SZFriendsSignalTagCertificate = 12, // 96 bytes: SZFriendsIdentity staticCertificate
    SZFriendsSignalTagAttestation = 13, // 1 to SZFriendsAttestationMax bytes, opaque (SZFriendsFieldAttestation)
    SZFriendsSignalTagToken = 14,      // 16 bytes: the Add by ID request token, on the holder's callback
    SZFriendsSignalTagFrame = 15,      // 1 to SZFriendsSignalFrameMax bytes
    SZFriendsSignalTagReason = 16,     // u8: SZFriendsSignalEndReason
    SZFriendsSignalTagNonce = 17,      // 32 bytes
    SZFriendsSignalTagProof = 18,      // 32 bytes
};

// ADR 0011 § NAT class, from the two-port STUN classifier.
typedef NS_ENUM(uint8_t, SZFriendsSignalNATClass) {
    SZFriendsSignalNATUnknown = 0,        // no answer from 3479, or not measured on this network yet
    SZFriendsSignalNATIndependent = 1,    // one mapped port for both STUN ports
    SZFriendsSignalNATPerDestination = 2, // a new mapping per destination; NATStep gives prediction its step
};

typedef NS_ENUM(uint8_t, SZFriendsSignalEndReason) {
    SZFriendsSignalEndDone = 0,      // the attempt is over: a better route won, or the person cancelled
    SZFriendsSignalEndDeclined = 1,  // the person declined (Add by ID) or the purpose was refused
    SZFriendsSignalEndFailed = 2,    // every technique failed on this side
};

// The highest signalling version this build speaks; peers agree on the lower maximum (Hello's MinorMin/MinorMax).
extern const uint16_t SZFriendsSignalMinor; // 0

@interface SZFriendsSignalItem : NSObject
@property(nonatomic, readonly) SZFriendsSignalItemType type;
@property(nonatomic, readonly) NSDictionary<NSNumber *, NSData *> *fields; // tag -> value
+ (instancetype)itemWithType:(SZFriendsSignalItemType)type fields:(NSDictionary<NSNumber *, NSData *> *)fields;
+ (instancetype)descriptionWithConnection:(uint8_t)connection
                                     kind:(uint8_t)kind
                                      sdp:(NSString *)sdp
                              fingerprint:(NSData *)fingerprint;
+ (instancetype)candidateWithConnection:(uint8_t)connection technique:(uint8_t)technique line:(NSString *)line;
+ (instancetype)candidatesEndWithConnection:(uint8_t)connection;
// `step` is sent only for a per-destination NAT.
+ (instancetype)natWithClass:(SZFriendsSignalNATClass)natClass step:(int16_t)step;
+ (instancetype)startWithConnection:(uint8_t)connection kind:(uint8_t)kind;
+ (instancetype)frameItemWithData:(NSData *)encodedFrame;
+ (instancetype)endWithReason:(SZFriendsSignalEndReason)reason;
- (nullable NSData *)dataForTag:(SZFriendsSignalTag)tag;
- (nullable NSString *)stringForTag:(SZFriendsSignalTag)tag; // nil when absent or not UTF-8
// u8, u16 and u64 fields at their width; NO when absent.
- (BOOL)getUnsigned:(uint64_t *)value forTag:(SZFriendsSignalTag)tag;
// NATStep as signed; 0 when absent.
- (int16_t)natStep;
@end

// Encodes items as one plaintext. Strict: every known field must have its length, every type its required fields,
// and the result must fit `capacity` bytes. Nil with an SZFriendsSessionErrorFrameInvalid error otherwise.
NSData *_Nullable SZFriendsEncodeSignalItems(NSArray<SZFriendsSignalItem *> *items, NSUInteger capacity,
                                             NSError **error);
// Decodes a plaintext: unknown item types and tags are left out; anything malformed fails the whole plaintext.
NSArray<SZFriendsSignalItem *> *_Nullable SZFriendsDecodeSignalItems(NSData *plaintext, NSError **error);

#pragma mark - Noise signalling (friends, own devices, Add by ID online)

// One signalling exchange, for one sid. Not thread-safe: use it on one queue. A call that fails leaves the session
// dead (every later call fails), as Noise requires; the caller then closes the sid or lets it expire, saying nothing.
@interface SZFriendsSignalingSession : NSObject
// IK toward a friend or one's own device: the stored X25519 static key, and the identity key its certificate must
// name. `requestToken` (16 bytes) only for the holder's callback after Add by ID.
- (nullable instancetype)initIKInitiatorWithIdentity:(SZFriendsIdentity *)identity
                                     remoteStaticKey:(NSData *)remoteStaticKey
                                 expectedIdentityKey:(NSData *)expectedIdentityKey
                                        requestToken:(nullable NSData *)requestToken;
// NN for Add by ID online: reveals no static key on either side.
- (instancetype)initNNInitiator;
- (instancetype)init NS_UNAVAILABLE;

// The responder for a received message 1 (sig_incoming's payload), IK or NN from its header. For IK it decrypts,
// checks the certificate binds the static key and refuses a Time further than SZFriendsSignalClockSkewMax from `now`,
// then asks `keyPolicy` (pure, as for SZFriendsSecureChannel). NN asks `keyPolicy` with a nil key. Only a message 1
// that decrypted and that the policy admitted is recorded in `replayCache`, and one whose ephemeral key is already
// there is refused, so junk and strangers cannot evict entries. On success *items holds message 1's items without
// its Hello. Nil with an error otherwise: SZFriendsSessionErrorReplayed, SZFriendsSessionErrorRejected (the policy,
// or a pattern `allowed` does not include), SZFriendsSessionErrorHandshakeFailed (anything else). A refusal is
// silence: the caller sends nothing, and the host's sid expires as if nobody were there.
+ (nullable instancetype)responderForMessage:(NSData *)message
                                    identity:(SZFriendsIdentity *)identity
                                     allowed:(NSArray<NSNumber *> *)allowedPatterns
                                 replayCache:(SZFriendsReplayCache *)replayCache
                                   keyPolicy:(SZFriendsRemoteKeyPolicy)keyPolicy
                                         now:(NSDate *)now
                                       items:(NSArray<SZFriendsSignalItem *> *_Nullable *_Nonnull)items
                                       error:(NSError **)error;

// This side's Friends ID attestation, sent beside its certificate (IK messages 1 and 2). Set before the message.
@property(nonatomic, copy, nullable) NSData *localAttestation;

// Initiator: message 1, the Hello first, then `items`. NN message 1 is plaintext, so it takes no items. `now` is
// the Time IK sends.
- (nullable NSData *)openingMessageWithItems:(NSArray<SZFriendsSignalItem *> *)items
                                         now:(NSDate *)now
                                       error:(NSError **)error;
// Responder: message 2 (its Hello, then `items`). The session is established after it.
- (nullable NSData *)replyWithItems:(NSArray<SZFriendsSignalItem *> *)items error:(NSError **)error;
// Initiator: reads message 2. IK checks the certificate names expectedIdentityKey. Established after it.
- (nullable NSArray<SZFriendsSignalItem *> *)readReply:(NSData *)message error:(NSError **)error;
// Established only: one Noise transport message each way, in order.
- (nullable NSData *)sealItems:(NSArray<SZFriendsSignalItem *> *)items error:(NSError **)error;
- (nullable NSArray<SZFriendsSignalItem *> *)openPayload:(NSData *)payload error:(NSError **)error;

// 32 bytes bound to this exchange (BLAKE2b-256 keyed with the handshake hash over UTF-8(label)): the probes' STUN
// short-term credentials (ADR 0011 § Probing budget) are derived from it on both sides. Nil before established.
- (nullable NSData *)exportKeyWithLabel:(NSString *)label;

@property(nonatomic, readonly) SZFriendsHandshakePattern pattern;
@property(nonatomic, readonly) BOOL isInitiator;
@property(nonatomic, readonly) BOOL established;
@property(nonatomic, readonly) uint16_t negotiatedMinor;
// IK, once the peer's certificate verified: its Ed25519 identity key, X25519 static key and certificate.
@property(nonatomic, readonly, nullable) NSData *remoteIdentityKey;
@property(nonatomic, readonly, nullable) NSData *remoteStaticKey;
@property(nonatomic, readonly, nullable) NSData *remoteCertificate;
@property(nonatomic, readonly, nullable) NSData *remoteAttestation; // unverified, as in SZFriendsSecureChannel
@property(nonatomic, readonly, nullable) NSData *presentedRequestToken; // responder: the IK callback's token
@property(nonatomic, readonly, nullable) NSData *handshakeHash;         // h, 64 bytes, once established
@end

#pragma mark - Rendezvous records (ADR 0010)

extern const NSUInteger SZFriendsRendezvousSealedLength; // 512: rdv_publish's sealed field, exactly
extern const NSUInteger SZFriendsRendezvousBodyMax;      // 365 bytes of items inside
// A host shows a record during the 60 s period after the one it was published in, and its filler for a key nobody
// published under changes every period (HOST-PROTOCOL-ONLINE.md § Rendezvous records), so a helper seals a fresh blob
// for every publish: the nonce is new each time, and the host refuses a blob sealed the same as the last as stale.
// The window inside is the presence window (SZFriendsPresenceWindow, 900 s); a friend accepts the one its own clock
// gives and the two next to it, the skew presence tags allow, so an old blob a host replays opens for at most about
// half an hour and says only what it said then.

// SHA-256(UTF-8("SZFriends rendezvous key v1") || identity key): the name a person's records are kept under on
// the hosts (HOST-PROTOCOL-ONLINE.md). Nil unless the key is 32 bytes.
NSData *_Nullable SZFriendsRendezvousKey(NSData *identityKey);

// A record's sealed blob: 24-byte nonce || XChaCha20-Poly1305 of 472 bytes, the key BLAKE2b-256 keyed with the
// presence secret over "SZFriends rendezvous seal v1", the associated data that label || rdv key. Inside: version 1,
// the window, the signing device's key, its Ed25519 signature ("SZFriends rendezvous seal v1" over rdv key ||
// version || window || device key || body), the body's length and the body (items: NAT, standing Candidates), then
// zeros. Only friends hold the presence secret; the signature means even they cannot make a record for this person.
// `personKey` is the identity key the rdv key is derived from; in M2 every device signs with that key itself.
NSData *_Nullable SZFriendsSealRendezvousRecord(SZFriendsIdentity *device, NSData *personKey, NSData *presenceSecret,
                                                int64_t window, NSArray<SZFriendsSignalItem *> *items,
                                                NSError **error);

@interface SZFriendsRendezvousRecord : NSObject
@property(nonatomic, readonly) NSData *deviceKey;
@property(nonatomic, readonly) int64_t window;
@property(nonatomic, readonly) NSArray<SZFriendsSignalItem *> *items;
@end

// Opens a blob a lookup returned for `personKey`'s rdv key with that person's presence secret. Nil (no error kept:
// a lookup's random filler for someone offline looks exactly like a record sealed for others) unless it decrypts,
// names one of `deviceKeys` (M2: @[personKey]), verifies, and its window is `window` or next to it.
SZFriendsRendezvousRecord *_Nullable SZFriendsOpenRendezvousRecord(NSData *sealed, NSData *personKey,
                                                                  NSData *presenceSecret,
                                                                  NSArray<NSData *> *deviceKeys, int64_t window);

#pragma mark - Download links (friends-links.md § Signalling)

extern const NSUInteger SZFriendsLinkIDLength;     // 16
extern const NSUInteger SZFriendsLinkSecretLength; // 32

// One link exchange, opener or sender, over one sid. Every payload is 12-byte nonce || AES-256-GCM ciphertext and
// tag, under HKDF-SHA-256(secret, salt link id, info "SZFriends link seal v1"), with associated data
// "SZFriends link seal v1" || direction (1 opener to sender, 2 back) || u32be count of that direction's payloads ||
// the exchange's context (empty for the opener's first payload, then its nonce, then its nonce || the challenge),
// so no payload opens in another exchange, another place or another order. The order is fixed:
//   opener 1: LinkNonce + items (e.g. its offer)   sender 1: LinkChallenge + items (nothing about the file)
//   opener 2: LinkProof + items                   then anything, both ways
// LinkProof = HMAC-SHA-256(HKDF(..., info "SZFriends link proof v1"), "SZFriends link proof v1" || link id ||
// nonce || challenge), compared in constant time. Before it verifies, the sender may seal only its challenge
// payload, and should apply nothing it read (the opener's first payload can be replayed by anyone who saw it).
@interface SZFriendsSignalingLink : NSObject
- (nullable instancetype)initAsOpener:(BOOL)opener linkID:(NSData *)linkID secret:(NSData *)secret;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSData *)sealItems:(NSArray<SZFriendsSignalItem *> *)items error:(NSError **)error;
// The items, without the exchange's own (nonce, challenge, proof). Nil with an error for a payload that does not
// open here or breaks the order; a sender whose proof check fails is dead.
- (nullable NSArray<SZFriendsSignalItem *> *)openPayload:(NSData *)payload error:(NSError **)error;
// Sender: the opener has proved the secret in this exchange.
@property(nonatomic, readonly) BOOL proven;
@property(nonatomic, readonly) BOOL isOpener;
// 32 bytes bound to this exchange once the challenge is known (HMAC-SHA-256 under the proof key over
// "SZFriends link export v1" || label || nonce || challenge); nil before.
- (nullable NSData *)exportKeyWithLabel:(NSString *)label;
@end

NS_ASSUME_NONNULL_END
