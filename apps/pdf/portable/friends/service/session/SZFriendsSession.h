// Shenzhen Friends sessions: byte streams, the Noise secure channel and the frame codec above every route.
//
// Helper-only. ADR 0001 (portable/friends/docs/adr/0001-session-protocol.md) is the decision; this header is its
// interface. Every route is a reliable byte stream (TCP on the LAN and peer-to-peer Wi-Fi, an L2CAP channel on
// Bluetooth, later a WebRTC data channel), and security lives above the stream, identical on all of them.
// Layering, bottom up:
//   1. SZFriendsByteStream: ordered bytes, no meaning.
//   2. The initiator's 4-byte preamble 'S' 'Z' major pattern, then Noise messages, each preceded by a 16-bit
//      big-endian length and at most 65,535 bytes. Noise revision 34, Noise_{XX,IK,NN}_25519_ChaChaPoly_BLAKE2b,
//      prologue "SZFriends session\0" || preamble, so a tampered preamble fails the handshake.
//   3. One application frame per Noise transport message: type:u8, then fields tag:u8 len:u16be value.
// The Noise state machine is C over libsodium in this directory (an internal header, checked against the
// cacophony and snow vectors); Objective-C callers use only what is declared here.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsIdentity;

typedef NS_ENUM(uint8_t, SZFriendsHandshakePattern) {
    SZFriendsHandshakeXX = 0, // first contact: friend requests, and public entries during visibility
    SZFriendsHandshakeIK = 1, // known friend; or the holder's callback after Add by ID, presenting the token
    SZFriendsHandshakeNN = 2, // Add by ID nearby only: encrypted, reveals no static key on either side
};

#pragma mark - Byte streams

// A reliable, ordered, bidirectional byte stream. Implemented by the Network.framework and CoreBluetooth
// adapters, and by fake streams with fault injection (truncation, corruption, disconnect mid-chunk, delay) in
// tests. Callbacks arrive on the queue given to -startWithQueue:.
@protocol SZFriendsByteStream <NSObject>
// Largest write the link carries efficiently; L2CAP is far smaller than TCP, so chunk size adapts to it.
@property(nonatomic, readonly) NSUInteger preferredWriteSize;
@property(nonatomic, copy, nullable) void (^onData)(NSData *data);
@property(nonatomic, copy, nullable) void (^onClose)(NSError *_Nullable error);
- (void)startWithQueue:(dispatch_queue_t)queue;
// Completion runs once the bytes are handed to the link (not delivered); error closes the stream.
- (void)writeData:(NSData *)data completion:(nullable void (^)(NSError *_Nullable error))completion;
- (void)close;
@optional
// Admission (ADR 0001 review item 4, work before authentication). A listener's adapter holds every stream it
// accepts against its limits until that stream's session authenticates; a responder channel reports to it through
// these three, so the helper wires nothing. Streams that do not implement them are never limited.
//
// Asked once by a responder, when the preamble names the pattern and before any Diffie-Hellman: NO refuses the
// connection exactly like a key-policy refusal (a per-pattern admission rate is full).
- (BOOL)admitHandshakePattern:(SZFriendsHandshakePattern)pattern;
// Told once by a responder when a complete message 1 has arrived, before any work on it. The adapter closes a
// connection that has not got this far soon after accept, so a peer that connects and sends nothing, or trickles,
// cannot hold a place for the whole handshake timeout.
- (void)handshakeDidReceiveFirstMessage;
// Told by a responder as soon as it knows who the initiator is: when the key policy accepts IK message 1 (fresh,
// since the replay cache refused any repeat before the policy) or XX message 3, and for NN, which never names
// anyone, when HELLO arrives. The stream then no longer counts against the limits on connections that have not
// authenticated, so a newcomer evicting the oldest such connection cannot cut off a friend whose handshake is
// already past message 1. May be told more than once; only the first counts.
- (void)sessionDidAuthenticate;
@end

#pragma mark - Limits (ADR 0001 § Wire format, § Files)

extern const uint8_t SZFriendsSessionMajor;             // 1, in the preamble
extern const NSUInteger SZFriendsNoiseMessageMax;       // 65,535 bytes including the 16-byte tag
extern const NSUInteger SZFriendsFramePlaintextMax;     // 65,519 bytes: one frame per transport message
extern const NSUInteger SZFriendsFrameTextMax;          // 32,768 bytes of MSG text; the composer refuses longer
extern const NSUInteger SZFriendsFramePictureMax;       // 49,152 bytes of own picture in PROFILE
extern const NSUInteger SZFriendsFrameThumbnailMax;     // 64,000 bytes of QOI in THUMBNAIL
extern const NSUInteger SZFriendsFrameChainMax;         // 64,000 bytes of device chain in CHAIN
extern const NSUInteger SZFriendsFrameJoinMax;          // 1,000 bytes of join message in JOIN (SZFriendsJoinMessageMax)
extern const NSUInteger SZFriendsFrameSyncMax;          // 64,000 bytes of sync message in SYNC
extern const NSUInteger SZFriendsFrameAgainMax;         // 64,000 bytes of again message in AGAIN
extern const NSUInteger SZFriendsChunkBytesWiFi;        // 61,440 (60 KiB) per CHUNK on LAN and peer-to-peer Wi-Fi
extern const NSUInteger SZFriendsChunkBytesBluetooth;   // 4,096 per CHUNK on Bluetooth
extern const uint64_t SZFriendsSendWindowWiFi;          // 8 MiB of bytes sent but not yet in a PROGRESS
extern const uint64_t SZFriendsSendWindowBluetooth;     // 256 KiB
// Rekey per direction after this many bytes or this long since that direction's last rekey; redial (fresh
// Diffie-Hellman) once a session is older than SZFriendsSessionMaxAge.
extern const uint64_t SZFriendsRekeyAfterBytes;         // 1 GiB
extern const NSTimeInterval SZFriendsRekeyAfterInterval; // 900 s
extern const NSTimeInterval SZFriendsSessionMaxAge;     // 86,400 s
// A handshake that has not gone live this long after -start closes, so a silent or trickling peer cannot hold a
// listener's connection (ADR 0001 review item 4: work before authentication).
extern const NSTimeInterval SZFriendsHandshakeTimeout;  // 10 s
// A responder that refuses before its first reply (message 1 did not decrypt, a bad certificate, the key policy, an
// admission limit, a replay, an unknown preamble) reads nothing more and closes exactly this long after the bytes
// that decided it arrived, whatever the reason. WHY: the reasons cost different work (one Diffie-Hellman for a
// message sealed to another key; three, a signature check and a policy lookup for one sealed to ours), so closing
// at once would tell anyone holding a person's static key which hidden listener is theirs.
extern const NSTimeInterval SZFriendsRefusalDelay;      // 1.5 s
// How long a responder remembers the initiator ephemeral keys of IK and NN message 1 (SZFriendsReplayCache).
extern const NSTimeInterval SZFriendsReplayWindow;      // 600 s
// The highest minor version this build speaks; it accepts peers whose range overlaps 0...this. Minor 1 adds THUMBNAIL,
// minor 2 adds CHAIN, JOIN and SYNC, minor 3 adds AGAIN, minor 4 fast transfers (HASHES, WANT, PART, HAVE; ADR 0018),
// used only when both sides also set SZFriendsCapabilityFastTransfers.
extern const uint16_t SZFriendsSessionMinor;            // 4
extern const uint16_t SZFriendsFastTransfersMinor;      // 4
// Handshake capability bits (SZFriendsFieldCapabilities). A side uses what a bit names only when both set it and the
// negotiated minor knows it; unknown bits are ignored.
typedef NS_OPTIONS(uint32_t, SZFriendsCapabilities) {
    SZFriendsCapabilityFastTransfers = 1u << 0, // blocks, the tree, WANT and HAVE (ADR 0018)
    SZFriendsCapabilityAESLanes = 1u << 1,      // reserved for AES-GCM lanes (ADR 0018 § 9.2): never sent yet
    SZFriendsCapabilityCompressedParts = 1u << 2, // compressed PARTs (ADR 0018 § 9.4): never sent yet
};
// What a new channel sets: fast transfers, unless the helper switched them off (settings key transfers.fast, read as
// it starts) or SZFRIENDS_TEST_FAST_TRANSFERS=0 plays a released helper in a test home.
SZFriendsCapabilities SZFriendsDefaultCapabilities(void);
void SZFriendsSetFastTransfersEnabled(BOOL enabled);
// Liveness while a transfer runs (ADR 0018 § 7, -setLivenessKeepalive:watch:): PING after this long without sending
// anything, and a session that heard nothing for the silence limit closes (SZFriendsSessionErrorSilent) and is
// redialed. A route that goes out of range stays open to TCP and L2CAP for minutes; this is what notices it.
extern const NSTimeInterval SZFriendsKeepaliveInterval;      // 1 s
extern const NSTimeInterval SZFriendsSilenceLimit;           // 8 s
extern const NSTimeInterval SZFriendsSilenceLimitBluetooth;  // 12 s, when the initiator declared Bluetooth
// Largest Attestation field (SZFriendsFieldAttestation) a handshake payload or PROFILE may carry.
extern const NSUInteger SZFriendsAttestationMax;        // 512 bytes
// Longest handshake message a responder reads (IK and NN message 1, XX messages 1 and 3). The largest honest one, IK
// message 1 with a certificate, a token and the longest attestation, is 750 bytes. A longer one is refused on its
// length prefix, before any Diffie-Hellman, so every listener refuses it alike: only the listener a message is sealed
// to decrypts and hashes its payload, and a 64 KB payload made that measurable from outside (wave-4 re-check).
extern const NSUInteger SZFriendsResponderHandshakeMax; // 1,024 bytes

#pragma mark - Errors

extern NSErrorDomain const SZFriendsSessionErrorDomain;

// What onClose and the codec report. None of these are shown to people; the helper maps them to retries and logs.
typedef NS_ERROR_ENUM(SZFriendsSessionErrorDomain, SZFriendsSessionError) {
    SZFriendsSessionErrorFrameInvalid = 1,    // codec: bad length, duplicate tag, over a limit, unknown type
    SZFriendsSessionErrorProtocol = 2,        // a well-formed frame out of place (before HELLO, wrong direction)
    SZFriendsSessionErrorHandshakeFailed = 3, // did not authenticate: wrong key, bad certificate, tampering
    SZFriendsSessionErrorRejected = 4,        // the key policy refused the remote, or a hidden listener got XX
    SZFriendsSessionErrorDecryptFailed = 5,   // a transport message failed authentication (tampered, replayed)
    SZFriendsSessionErrorStreamClosed = 6,    // the link ended without CLOSE; NSUnderlyingErrorKey when known
    SZFriendsSessionErrorPeerClosed = 7,      // the peer sent CLOSE; SZFriendsSessionCloseReasonKey has its reason
    SZFriendsSessionErrorExpired = 8,         // older than SZFriendsSessionMaxAge or out of nonces: redial
    SZFriendsSessionErrorCodeMismatch = 9,    // the comparison-code commitment did not verify
    SZFriendsSessionErrorTimedOut = 10,       // the handshake did not go live within SZFriendsHandshakeTimeout
    SZFriendsSessionErrorReplayed = 11,       // message 1 repeated an initiator ephemeral key seen within the window
    SZFriendsSessionErrorSilent = 12,         // while a transfer ran, nothing arrived for the silence limit: redial
};
extern NSString *const SZFriendsSessionCloseReasonKey; // NSNumber (SZFriendsCloseReason) in PeerClosed errors

// CLOSE's Reason field, for logs on both sides. Wire values: never renumber.
typedef NS_ENUM(uint8_t, SZFriendsCloseReason) {
    SZFriendsCloseReasonNormal = 0,
    SZFriendsCloseReasonProtocolError = 1, // the receiver of a bad frame says so before closing
    SZFriendsCloseReasonSuperseded = 2,    // lost the session race (SZFriendsSessionAWins)
    SZFriendsCloseReasonExpired = 3,       // SZFriendsSessionMaxAge reached; the helper redials
    SZFriendsCloseReasonShuttingDown = 4,  // helper exit, handover or Friends turned off
    SZFriendsCloseReasonCodeMismatch = 5,  // comparison-code commitment failed
    SZFriendsCloseReasonLaneRefused = 6,   // a lane the responder would not admit (ADR 0018 § 6)
};

#pragma mark - Frames (pure codec)

// Transport frame types. Numbers are wire values: never renumber once M1 ships; until then this header is where
// the session area changes them, by agreement with the helper. Unknown type: close with CLOSE (senders use only
// types the peer's minor version knows). Frames marked (channel) are handled inside SZFriendsSecureChannel and
// never reach onFrame.
typedef NS_ENUM(uint8_t, SZFriendsFrameType) {
    SZFriendsFrameTypeHello = 1,          // (channel) initiator's first transport frame: the session is live
    SZFriendsFrameTypeProfile = 2,        // Name, FriendsID, PictureSet+PictureIndex or Data (own picture)
    SZFriendsFrameTypePresenceSecret = 3, // ID, Secret: the sender's current presence secret (acceptance, rotation)
    SZFriendsFrameTypeRequest = 4,        // ID, SentAt, Text (optional note): friend request in an XX session
    SZFriendsFrameTypeAccept = 5,         // ID (of the request)
    SZFriendsFrameTypeDecline = 6,        // ID (of the request)
    SZFriendsFrameTypeRequestByID = 7,    // NN only: FriendsID, Token, CallbackSecret, Certificate, StaticKey,
                                          // Signature over the NN handshake hash (ADR 0004 step 1)
    SZFriendsFrameTypeReceived = 8,       // NN only: the fixed-size reply every device sends, before any lookup
    SZFriendsFrameTypeCodeCommit = 9,     // (channel) Commitment
    SZFriendsFrameTypeCodeNonce = 10,     // (channel) Nonce: the initiator's
    SZFriendsFrameTypeCodeReveal = 11,    // (channel) Nonce: the responder's
    SZFriendsFrameTypeMessage = 12,       // ID, SentAt, Text, OfferIDs (optional), ViaAssistant (optional)
    SZFriendsFrameTypeAck = 13,           // ID: durable acknowledgement after the recipient's commit
    SZFriendsFrameTypeOffer = 14,         // ID (offer id), Name, FileType, Size, Digest, ViaAssistant (optional)
    SZFriendsFrameTypeOfferReply = 15,    // ID, Accept, Offset (resume point when accepting)
    SZFriendsFrameTypeCancel = 16,        // ID: withdraw an unanswered request or offer, or stop a transfer
    SZFriendsFrameTypeChunk = 17,         // ID, Offset, Data
    SZFriendsFrameTypeProgress = 18,      // ID, Offset: bytes written, fsynced and committed
    SZFriendsFrameTypeDone = 19,          // ID, Digest
    SZFriendsFrameTypeRekey = 20,         // (channel)
    SZFriendsFrameTypePing = 21,          // (channel)
    SZFriendsFrameTypeClose = 22,         // (channel) Reason
    // Minor 1: ID (of an offer), Width, Height, Data (QOI, at most SZFriendsFrameThumbnailMax bytes): the file's
    // preview, after its OFFER. Sent only to a peer that negotiated minor 1 or later, and only while the offer waits
    // for an answer. It travels in the CHUNK queue, so messages overtake it, and it is acknowledged like a message.
    SZFriendsFrameTypeThumbnail = 23,
    // Minor 2: Chain (an encoded SZFriendsDeviceChain, opaque here): which devices speak for the sender's person
    // (ADR 0012). Sent once on every XX and IK session that negotiated minor 2, right after it goes live, so friends
    // and the person's own devices always hold the newest chain. Never in NN, which names nobody.
    SZFriendsFrameTypeChain = 24,
    // Join (one message of joining a profile, SZFriendsJoin.h, opaque here): NN only, either way and as often as the
    // exchange needs, because a computer asking to join a profile is known to nobody yet (PROTOCOL.md § Joining).
    // Never in IK or XX. A device that does not know it closes the session, which reads as "not here".
    SZFriendsFrameTypeJoin = 25,
    // Minor 2: Sync (one message of the sync exchange, service/sync/SZFriendsSync.h, opaque here): between two devices
    // of the same person only, IK or XX, as often as the exchange needs (friends-multi-device.md § Sync). The helper
    // sends it only on a session whose peer our own device chain authorizes; never in NN.
    SZFriendsFrameTypeSync = 26,
    // Minor 3: Again (one message of getting a file again, ADR 0016, opaque here): between a person and a friend who
    // sent them a file, IK or XX, as often as the exchange needs; never in NN. It travels in the CHUNK queue.
    SZFriendsFrameTypeAgain = 27,
    // Minor 4, and only on a session where both sides set SZFriendsCapabilityFastTransfers (ADR 0018 § 3): the channel
    // refuses to send them to anyone else and closes on one received outside such a session. HASHES and PART travel in
    // the CHUNK queue.
    SZFriendsFrameTypeHashes = 28, // ID, Index, Hashes: the leaves, after acceptance
    SZFriendsFrameTypeWant = 29,   // ID, Ranges: blocks missing, send them
    SZFriendsFrameTypePart = 30,   // ID, Offset, Data (1 to 61,440 bytes); Codec and Length when compressed
    SZFriendsFrameTypeHave = 31,   // ID, Ranges (blocks checked and written), Durable (blocks made durable)
};

// Field tags, one namespace for every type so a value means the same thing wherever it appears. Unknown tag:
// ignored. Duplicate tag, or a value over its per-type limit: close.
typedef NS_ENUM(uint8_t, SZFriendsFieldTag) {
    SZFriendsFieldID = 1,             // 16 bytes: msg_id, offer_id or request id; random, reused on every retry
    SZFriendsFieldSentAt = 2,         // u64be milliseconds since 1970 UTC, the sender's clock
    SZFriendsFieldText = 3,           // UTF-8, at most SZFriendsFrameTextMax bytes
    SZFriendsFieldName = 4,           // UTF-8: display name (PROFILE) or file name (OFFER)
    SZFriendsFieldFileType = 5,       // UTF-8 uniform type identifier, or the extension
    SZFriendsFieldSize = 6,           // u64be bytes
    SZFriendsFieldDigest = 7,         // 32 bytes: BLAKE2b-256 of the whole file
    SZFriendsFieldOffset = 8,         // u64be byte offset
    SZFriendsFieldData = 9,           // raw bytes: chunk data, or the own picture (JPEG)
    SZFriendsFieldPictureSet = 10,    // u16be animal set version
    SZFriendsFieldPictureIndex = 11,  // u16be animal index
    SZFriendsFieldAccept = 12,        // u8: 1 accept, 0 decline
    SZFriendsFieldSecret = 13,        // 32 bytes
    SZFriendsFieldNonce = 14,         // 32 bytes
    SZFriendsFieldCommitment = 15,    // 32 bytes
    SZFriendsFieldOfferIDs = 16,      // n x 16 bytes: the offers attached to a message
    SZFriendsFieldFriendsID = 17,     // UTF-8, canonical "word-word"
    SZFriendsFieldToken = 18,         // 16 bytes: Add by ID request token
    SZFriendsFieldCallbackSecret = 19, // 32 bytes
    SZFriendsFieldCertificate = 20,   // 96 bytes: identity key || signature (SZFriendsIdentity staticCertificate)
    SZFriendsFieldStaticKey = 21,     // 32 bytes X25519
    SZFriendsFieldSignature = 22,     // 64 bytes Ed25519
    SZFriendsFieldReason = 23,        // u8 close or decline reason, for logs
    // Handshake payloads only (never in a transport frame), handled inside SZFriendsSecureChannel:
    SZFriendsFieldMinorMin = 24,      // u16be lowest minor version the sender speaks
    SZFriendsFieldMinorMax = 25,      // u16be highest
    SZFriendsFieldCapabilities = 26,  // u32be capability bits; none defined in M1, unknown bits ignored
    SZFriendsFieldRouteClass = 27,    // u8 SZFriendsRouteMethod the initiator dialed over
    // Handshake payloads and PROFILE: 1 to SZFriendsAttestationMax bytes, a host-issued Friends ID attestation (the
    // host's signature binding a Friends ID to this identity key; its layout is the host area's, opaque here). It
    // travels only beside the certificate, never in NN, because it names the identity. Nothing here verifies it:
    // the helper checks it against the pinned host keys and the certificate's identity key before believing the ID.
    SZFriendsFieldAttestation = 28,
    // MSG and OFFER: u8 1 when the sender's assistant sent this for them (PROTOCOL.md via_assistant), so the recipient
    // sees it too. Absent means the person sent it; an older peer ignores the unknown tag and shows nothing.
    SZFriendsFieldViaAssistant = 29,
    SZFriendsFieldWidth = 30,         // u16be pixels (THUMBNAIL)
    SZFriendsFieldHeight = 31,        // u16be pixels (THUMBNAIL)
    // REQUEST_BY_ID, optional: 32 bytes, SZFriendsInviteProof over this NN session's handshake hash, from a request
    // made through a friend link (friends-links.md). The holder accepts such a request at once while the invite it
    // proves is valid; an older holder ignores the unknown tag and the request waits for an answer as any other.
    SZFriendsFieldInviteProof = 32,
    // CHAIN: 3 to SZFriendsFrameChainMax bytes, the sender's encoded device chain (SZFriendsDeviceChain encodedData).
    SZFriendsFieldChain = 33,
    // JOIN: 1 to SZFriendsFrameJoinMax bytes, one join message (service/identity/SZFriendsJoin.h).
    SZFriendsFieldJoin = 34,
    // SYNC: 1 to SZFriendsFrameSyncMax bytes, one sync message (SZFriendsSyncExchange).
    SZFriendsFieldSync = 35,
    // AGAIN: 1 to SZFriendsFrameAgainMax bytes, one again message (SZFriendsAgainExchange).
    SZFriendsFieldAgain = 36,
    // Fast transfers only (ADR 0018): never sent to a peer that did not negotiate them; the channel strips them.
    SZFriendsFieldTreeRoot = 37,   // OFFER: 32 bytes, the root of the file's hash tree
    SZFriendsFieldBlockShift = 38, // OFFER: u8, blocks of 2^shift bytes
    SZFriendsFieldIndex = 39,      // HASHES: u32be, the first leaf's index
    SZFriendsFieldHashes = 40,     // HASHES: 32 to 64,000 bytes of leaves
    SZFriendsFieldRanges = 41,     // WANT and HAVE: pairs of u32be (first block, count), at most 8,000
    SZFriendsFieldDurable = 42,    // HAVE: the same, for blocks made durable
    SZFriendsFieldBlocks = 43,     // OFFER_REPLY: u8 1, the receiver takes the file by blocks
    SZFriendsFieldCodec = 44,      // PART: u8, 1 is zstd
    SZFriendsFieldLength = 45,     // PART: u32be, what compressed data expands to
    SZFriendsFieldLane = 46,       // handshake payload, IK message 1 of a lane: 16 bytes (SZFriendsLaneToken)
    SZFriendsFieldPieces = 47,     // WANT and HAVE: the Ranges format over 16 KiB pieces of the file (ADR 0018 § 3)
};

// One decoded frame: its type and raw field values. Typed accessors return nil / NO for an absent or
// wrong-length field, so callers never parse lengths themselves.
@interface SZFriendsFrame : NSObject
@property(nonatomic, readonly) SZFriendsFrameType type;
@property(nonatomic, readonly) NSDictionary<NSNumber *, NSData *> *fields; // tag -> value
+ (instancetype)frameWithType:(SZFriendsFrameType)type fields:(NSDictionary<NSNumber *, NSData *> *)fields;
- (nullable NSData *)dataForTag:(SZFriendsFieldTag)tag;
- (nullable NSString *)stringForTag:(SZFriendsFieldTag)tag; // nil for invalid UTF-8
// Integer fields (SentAt, Size, Offset: u64; PictureSet, PictureIndex, Width, Height: u16; Accept, Reason: u8) at
// their width.
- (BOOL)getUInt64:(uint64_t *)value forTag:(SZFriendsFieldTag)tag;
// The big-endian bytes of `value` at the tag's width; nil for a tag that is not an integer or a value too wide.
+ (nullable NSData *)fieldWithUInt64:(uint64_t)value tag:(SZFriendsFieldTag)tag;
@end

// Pure: plaintext of one transport message <-> frame. Enforces SZFriendsFramePlaintextMax, the per-type limits,
// duplicate and unknown tags, and unknown types, before allocating anything sized by the peer.
// Decoding: an unknown type, a duplicate tag (known or not), a known field outside its length limits or a missing
// required field fails; a tag the type does not define is ignored and left out of `fields`. Encoding is strict:
// every field must belong to the type. Per-type rules: SZFriendsFrameSchema.m beside this header.
NSData *_Nullable SZFriendsEncodeFrame(SZFriendsFrame *frame, NSError **error);
SZFriendsFrame *_Nullable SZFriendsDecodeFrame(NSData *plaintext, NSError **error);

#pragma mark - Secure channel

// What the initiator knows before dialing, and what it puts in its handshake payload. The payload that reveals a
// static key carries the certificate, the supported minor-version range, capability bits and the initiator's
// route class; on a public entry, the responder's XX message 2 carries its public profile.
@interface SZFriendsHandshakeOptions : NSObject <NSCopying>
@property(nonatomic) SZFriendsHandshakePattern pattern;
// The route this attempt runs over. Both sides judge the session race from it (SZFriendsSessionAWins). Required
// for XX and IK: a channel whose route is not LAN through Relay refuses to start, and a responder refuses an
// initiator that declares none, so the race only ever compares real classes. NN ignores it.
@property(nonatomic) SZFriendsRouteMethod route;
// IK: the friend's stored X25519 static key, and the Ed25519 identity key its certificate must name.
@property(nonatomic, copy, nullable) NSData *remoteStaticKey;
@property(nonatomic, copy, nullable) NSData *expectedIdentityKey;
// IK callback after Add by ID: the requester's 16-byte token, which lets its listener accept an unknown key.
@property(nonatomic, copy, nullable) NSData *requestToken;
// XX against a public entry: stop after message 2 (the responder's profile) without revealing ourselves, unless
// the person sends a request; then message 3 completes the handshake.
@property(nonatomic) BOOL browseOnly;
// IK: a lane of a live session with the same device (ADR 0018 § 6): SZFriendsLaneToken of that session's handshake
// hash and the lane's index, carried in message 1's encrypted payload. Nil for an ordinary session.
@property(nonatomic, copy, nullable) NSData *lane;
@end

// A lane's token: keyed BLAKE2b-128, the first session's handshake hash h (64 bytes) as the key, over
// "SZFriends lane v1" || u8 index (1 to 15). Nil for a hash that is not 64 bytes.
NSData *_Nullable SZFriendsLaneToken(NSData *handshakeHash, uint8_t index);

// The responder's view of message 1 (IK and NN) or message 3 (XX), before any reply or application frame: whether
// this remote may continue. Unknown keys pass only for XX on a public entry or with a pending request token;
// blocked keys never; NN passes only for REQUEST_BY_ID (the policy may still refuse it, to rate-limit). Returning
// NO closes the channel without revealing anything, at SZFriendsRefusalDelay like every early refusal. `requestToken`
// is only ever passed for IK. Before asking, the channel has verified the certificate against the handshake's
// static key, refused a replayed message 1 (SZFriendsReplayCache), and a responder without a public profile has
// already refused XX at the preamble, so a hidden listener never answers a stranger. The channel's
// remoteAttestation already holds that payload's attestation (unverified) while the policy runs, and is cleared
// again if it refuses.
//
// The policy must be pure until onEstablished: no store writes, no nearby facts, no token consumed, nothing marked
// seen. Only counting toward a rate limit is allowed. WHY: it runs before the initiator has proved anything (IK
// message 1 can be replayed, Noise § 7.7), and the replay cache bounds repeats only to one per ephemeral key per
// window, so an action belongs after HELLO, which cannot be replayed.
typedef BOOL (^SZFriendsRemoteKeyPolicy)(NSData *_Nullable remoteIdentityKey, SZFriendsHandshakePattern pattern,
                                         NSData *_Nullable requestToken);

// IK and NN message 1 can be replayed (Noise § 7.7). A channel responder records the initiator's ephemeral key, the
// first 32 bytes of message 1, once message 1 has decrypted and before its payload or the key policy (online
// signalling records it after decryption and the policy, SZFriendsSignaling.h), and refuses message 1 whose key it
// already holds, so a captured message 1 reaches the key policy once. Junk never enters the cache. Entries last
// SZFriendsReplayWindow; past `capacity` the oldest goes first (a replay of an evicted entry only reaches the pure
// policy again). Thread-safe.
@interface SZFriendsReplayCache : NSObject
// The cache every responder uses unless given another: one per process, so all listeners share it.
@property(class, nonatomic, readonly) SZFriendsReplayCache *sharedCache;
// `clock` counts seconds and keeps counting during sleep (nil: CLOCK_MONOTONIC); tests inject one.
- (instancetype)initWithCapacity:(NSUInteger)capacity clock:(nullable NSTimeInterval (^)(void))clock
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init; // capacity 65,536 (about 110 handshakes a second for 10 minutes), CLOCK_MONOTONIC
// YES, recording it, when `ephemeralKey` has not been seen within the window; NO for a repeat.
- (BOOL)recordEphemeralKey:(NSData *)ephemeralKey;
@property(nonatomic, readonly) NSUInteger count;
@end

// Every method and property is used on the channel's queue, and every callback arrives there; the stream is
// started on it too.
@interface SZFriendsSecureChannel : NSObject
- (instancetype)initAsInitiatorWithStream:(id<SZFriendsByteStream>)stream
                                 identity:(SZFriendsIdentity *)identity
                                  options:(SZFriendsHandshakeOptions *)options
                                    queue:(dispatch_queue_t)queue;
// `publicProfile`: PROFILE fields served in XX message 2 while this listener's public entry is on; nil otherwise.
- (instancetype)initAsResponderWithStream:(id<SZFriendsByteStream>)stream
                                 identity:(SZFriendsIdentity *)identity
                            publicProfile:(nullable NSDictionary<NSNumber *, NSData *> *)publicProfile
                                keyPolicy:(SZFriendsRemoteKeyPolicy)keyPolicy
                                    queue:(dispatch_queue_t)queue;
- (instancetype)init NS_UNAVAILABLE;

// Responder: where message 1's ephemeral keys are remembered. Defaults to SZFriendsReplayCache.sharedCache; set it
// before -start only to keep a test's channels apart.
@property(nonatomic, strong, null_resettable) SZFriendsReplayCache *replayCache;

// Responder: after the initiator's HELLO (IK message 1 can be replayed, so nothing acts on handshake payloads).
// Initiator: when the handshake completes.
@property(nonatomic, copy, nullable) void (^onEstablished)(void);
// Initiator, XX: the responder's public profile from message 2. Return YES to continue (send a request), NO to
// close without revealing ourselves. With browseOnly and no handler, the channel closes after message 2.
@property(nonatomic, copy, nullable) BOOL (^onPublicProfile)(NSDictionary<NSNumber *, NSData *> *profile);
@property(nonatomic, copy, nullable) void (^onFrame)(SZFriendsFrame *frame);
// Once, after the stream is closed. nil when this side closed deliberately (-close, browse-only, onPublicProfile
// returning NO); an SZFriendsSessionErrorDomain error otherwise. A responder's refusal before its first reply
// arrives here when the stream closes, SZFriendsRefusalDelay after message 1 (sooner if -close is called).
@property(nonatomic, copy, nullable) void (^onClose)(NSError *_Nullable error);

- (void)start;
// Queues a frame for encryption; frames queued before the session is live wait for it. Control and message frames
// jump queued CHUNKs, so a message never waits behind a file; order is otherwise preserved, and DONE and THUMBNAIL
// travel in the CHUNK queue, so DONE never overtakes its transfer's last chunk and a preview never delays a message.
// Returns NO, sending nothing, for a frame the codec refuses, a type the channel owns (HELLO, CODE_*, REKEY, PING,
// CLOSE), a type the pattern does not allow (NN carries only REQUEST_BY_ID from the initiator and RECEIVED from the
// responder; XX and IK never carry them), or a channel that is closing.
- (BOOL)sendFrame:(SZFriendsFrame *)frame;
// Sends CLOSE after the queued control frames (so in-flight ACKs still go out), drops queued CHUNKs, then closes
// the stream.
- (void)close;
- (void)closeWithReason:(SZFriendsCloseReason)reason;

// Liveness while a transfer runs (ADR 0018 § 7). `keepalive`: a transfer runs on this session, so PING whenever this
// side sent nothing for SZFriendsKeepaliveInterval, and the peer always hears something. `watch`: something from the
// peer is due (SZFriendsTransferLiveness), so hearing nothing for the silence limit, counted from when watching
// starts, closes the session without CLOSE (SZFriendsSessionErrorSilent) and the helper redials. Every minor knows
// PING and ignores it, so a released peer simply receives it; against one, which never pings, watching is on only
// while its own traffic is due. A gap of more than two keepalives between this side's timer runs (a busy queue,
// sleep) is this side's stall, not the peer's silence: the count starts again. Call it whenever either changes;
// repeating the same values changes nothing.
- (void)setLivenessKeepalive:(BOOL)keepalive watch:(BOOL)watch;
@property(nonatomic, readonly) BOOL watchingLiveness;
// File data (CHUNK, DONE, THUMBNAIL, AGAIN, HASHES, PART) queued and not yet encrypted: how far a sender may run ahead.
@property(nonatomic, readonly) NSUInteger queuedBulkFrames;
// After each write the link completed (bytes left this side): the session is moving, and room opened.
@property(nonatomic, copy, nullable) void (^onWritten)(void);

// Runs CODE_COMMIT / CODE_NONCE / CODE_REVEAL once, in the session that creates the friendship; both sides call
// it, in either order, before or after the session is live. Completion gets six ASCII digits ("418270"), or an
// error when the commitment does not verify (which closes the channel), when the channel closes first, for NN, or
// on a second call. The initiator sees its code only after the responder's nonce verified against the commitment.
- (void)runComparisonCodeExchange:(void (^)(NSString *_Nullable code, NSError *_Nullable error))completion;

// This side's host-issued Friends ID attestation (SZFriendsFieldAttestation), set before -start: sent in the
// handshake payload that carries our certificate (IK messages 1 and 2, XX messages 2 and 3), never in NN. Nil sends
// none. One longer than SZFriendsAttestationMax fails the handshake rather than being cut.
@property(nonatomic, copy, nullable) NSData *localAttestation;

// Valid once established.
@property(nonatomic, readonly) BOOL isInitiator;
@property(nonatomic, readonly) SZFriendsHandshakePattern pattern;
@property(nonatomic, readonly) SZFriendsRouteMethod initiatorRoute;     // as the initiator declared it
@property(nonatomic, readonly, nullable) NSData *remoteIdentityKey;     // Ed25519 from the certificate; nil for NN
// The 96-byte certificate (identity key || signature) the peer's handshake presented, verified against
// remoteStaticKey and set together with remoteIdentityKey: what the store checks before keeping a changed static key
// for review. Nil for NN.
@property(nonatomic, readonly, nullable) NSData *remoteCertificate;
// The peer's Attestation field from the same payload, unverified (see SZFriendsFieldAttestation); nil when it sent
// none. Also available to onPublicProfile on an XX initiator, and to a responder's key policy.
@property(nonatomic, readonly, nullable) NSData *remoteAttestation;
@property(nonatomic, readonly, nullable) NSData *remoteStaticKey;       // X25519, to store for later IK
@property(nonatomic, readonly, nullable) NSData *presentedRequestToken; // responder: the IK callback's token
@property(nonatomic, readonly, nullable) NSData *handshakeHash;         // h, 64 bytes
@property(nonatomic, readonly) NSUInteger negotiatedMinor;
// The capability bits this side sets in its handshake, set before -start; SZFriendsDefaultCapabilities() at first.
@property(nonatomic) SZFriendsCapabilities localCapabilities;
@property(nonatomic, readonly) SZFriendsCapabilities remoteCapabilities; // valid once established
// ADR 0018 § 1: minor 4 or more negotiated and both sides set SZFriendsCapabilityFastTransfers. Otherwise nothing of
// fast transfers is sent (frames refused, OFFER fields stripped) and nothing of them is accepted.
@property(nonatomic, readonly) BOOL fastTransfers;
// Responder: the Lane field of IK message 1, unchecked (the helper checks it against its live sessions); nil when none.
@property(nonatomic, readonly, nullable) NSData *presentedLane;
@end

#pragma mark - Comparison codes (pure, ADR 0001 § Comparison codes)

// BLAKE2b-256("SZFriends code commit v1" || h || responderNonce).
NSData *SZFriendsCodeCommitment(NSData *handshakeHash, NSData *responderNonce);
// First 8 bytes of BLAKE2b-256("SZFriends code v1" || h || initiatorNonce || responderNonce) as a big-endian
// integer mod 1,000,000, as six ASCII digits. Presentation groups them for display ("418 270").
NSString *SZFriendsComparisonCode(NSData *handshakeHash, NSData *initiatorNonce, NSData *responderNonce);

#pragma mark - Add by ID requests (ADR 0004 step 1)

// REQUEST_BY_ID for an NN session, signed by `identity` with the domain "SZFriends request v1" over
// h (64 bytes) || Token (16) || CallbackSecret (32) || StaticKey (32) || UTF-8 FriendsID. Signing the NN handshake
// hash makes the request verify only inside the session it was made for, so it cannot be relayed or replayed into
// another; signing the fields too means none can be swapped. Nil for a token that is not 16 bytes, a secret that is
// not 32, an empty ID or one over 64 bytes, or a hash that is not 64 bytes.
SZFriendsFrame *_Nullable SZFriendsMakeRequestByIDFrame(SZFriendsIdentity *identity, NSString *friendsID,
                                                        NSData *requestToken, NSData *callbackSecret,
                                                        NSData *handshakeHash);
// The requester's Ed25519 identity key when the certificate binds StaticKey and the signature verifies for this
// session's `handshakeHash`; nil otherwise. The responder sends RECEIVED either way, before looking anything up.
NSData *_Nullable SZFriendsVerifyRequestByIDFrame(SZFriendsFrame *frame, NSData *handshakeHash);
// HMAC-SHA-256 keyed with a friend link's 16-byte invite token over UTF-8("SZFriends invite v1") || h: proof that the
// requester holds the link, bound to this one NN session, so a device that hears the request (every device nearby
// answers it) learns nothing it could present in another. Nil unless the token is 16 bytes and h 64.
NSData *_Nullable SZFriendsInviteProof(NSData *inviteToken, NSData *handshakeHash);

#pragma mark - File chunks: windowed flow and resume (pure, ADR 0001 § Files, § Resume and route migration)

// Per route (the session's initiatorRoute, which both sides know): Bluetooth gets the small chunk and window, every
// other route the Wi-Fi ones.
NSUInteger SZFriendsChunkBytesForRoute(SZFriendsRouteMethod route);
uint64_t SZFriendsSendWindowForRoute(SZFriendsRouteMethod route);

// The sending side of one accepted transfer within one session. Resume and route migration are one mechanism: a
// new session gets a new sender starting at the offset of the recipient's PROGRESS, after the helper has checked
// that the offer is its own, to this recipient, still accepted, and that its source still hashes to the digest.
@interface SZFriendsChunkSender : NSObject
// Nil when resumeOffset is past size, or chunkBytes is 0 or larger than the window.
- (nullable instancetype)initWithOfferID:(NSData *)offerID
                                    size:(uint64_t)size
                            resumeOffset:(uint64_t)resumeOffset
                              chunkBytes:(NSUInteger)chunkBytes
                                  window:(uint64_t)window NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithOfferID:(NSData *)offerID
                                    size:(uint64_t)size
                            resumeOffset:(uint64_t)resumeOffset
                                   route:(SZFriendsRouteMethod)route;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSData *offerID;
@property(nonatomic, readonly) uint64_t size;
@property(nonatomic, readonly) uint64_t sentOffset;    // bytes handed out in CHUNKs so far
@property(nonatomic, readonly) uint64_t durableOffset; // the recipient's latest PROGRESS
@property(nonatomic, readonly) BOOL allSent;           // send DONE now
@property(nonatomic, readonly) BOOL acknowledged;      // PROGRESS reached size
// The next CHUNK's range while the window has room; NO when the window is full or everything is sent.
- (BOOL)getNextChunkOffset:(uint64_t *)offset length:(NSUInteger *)length;
// Builds the CHUNK for exactly that range and advances sentOffset; nil, advancing nothing, for any other length.
- (nullable SZFriendsFrame *)chunkFrameWithData:(NSData *)data;
// PROGRESS from the recipient. NO for another offer, a step backwards or bytes never sent: close the session.
- (BOOL)handleProgressFrame:(SZFriendsFrame *)frame error:(NSError **)error;
@end

// The receiving side of one accepted transfer within one session. A CHUNK whose offer has no receiver is
// unsolicited: the helper closes the session (SZFriendsCloseReasonProtocolError).
@interface SZFriendsChunkReceiver : NSObject
// `verifiedOffset`: bytes already written, fsynced and committed (the store's verifiedBytes); the session starts
// by sending -resumeProgressFrame so the sender continues from there.
- (nullable instancetype)initWithOfferID:(NSData *)offerID
                                    size:(uint64_t)size
                          verifiedOffset:(uint64_t)verifiedOffset
                              chunkBytes:(NSUInteger)chunkBytes
                                  window:(uint64_t)window NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithOfferID:(NSData *)offerID
                                    size:(uint64_t)size
                          verifiedOffset:(uint64_t)verifiedOffset
                                   route:(SZFriendsRouteMethod)route;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSData *offerID;
@property(nonatomic, readonly) uint64_t receivedOffset; // bytes accepted from CHUNKs
@property(nonatomic, readonly) uint64_t reportedOffset; // the last PROGRESS sent
@property(nonatomic, readonly) BOOL complete;           // every byte received
// Chunks arrived on this session and more are due: the sender is sending (its PROGRESS-driven window included).
@property(nonatomic, readonly) BOOL arriving;
- (SZFriendsFrame *)resumeProgressFrame;
// Checks a CHUNK against this transfer: same offer, offset exactly receivedOffset, 1 to chunkBytes bytes, inside
// the declared size and inside the window past the last PROGRESS. Returns the data and advances; nil with an
// error otherwise: close the session.
- (nullable NSData *)acceptChunkFrame:(SZFriendsFrame *)frame error:(NSError **)error;
// PROGRESS for bytes the store made durable; nil when `durableOffset` is behind the last report or past what was
// received.
- (nullable SZFriendsFrame *)progressFrameForDurableOffset:(uint64_t)durableOffset;
// DONE for this offer once every byte arrived: returns its digest for the store's whole-file check; nil with an
// error for an early DONE or another offer: close the session.
- (nullable NSData *)acceptDoneFrame:(SZFriendsFrame *)frame error:(NSError **)error;
@end

// What a session carrying these transfers asks of -setLivenessKeepalive:watch: (ADR 0018 § 7): keepalive while any
// runs, and watching while the peer owes this side something it sends anyway, even a released peer that never pings:
// PROGRESS for bytes sent and not yet confirmed, or the rest of a file whose chunks are arriving. Not while an offer
// waits for its answer, before a released sender's first chunk (it may hash the snapshot first), nor between DONE and
// its ACK, when a released receiver checks the whole file in silence.
void SZFriendsTransferLiveness(NSArray<SZFriendsChunkSender *> *senders, NSArray<SZFriendsChunkReceiver *> *receivers,
                               BOOL *keepalive, BOOL *watch);

NS_ASSUME_NONNULL_END
