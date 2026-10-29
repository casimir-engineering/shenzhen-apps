// Shenzhen Friends frames (ADR 0001 § Wire format): frame types, field tags and the pure codec. Part of
// SZFriendsSession.h, which imports it where these were, after the limits and errors they use: import that one.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
    // Minor 4, and only on a fast session where both sides set SZFriendsCapabilityDirectWiFiBoost (ADR 0019): ID,
    // Step and, by step, Abilities, the link (Network, Passphrase, Address, Port) or Reason.
    SZFriendsFrameTypeBoost = 32,
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
    // BOOST only (ADR 0019).
    SZFriendsFieldStep = 48,       // u8: 1 PROPOSE, 2 READY, 3 HOST, 4 END, 5 DECLINE
    SZFriendsFieldAbilities = 49,  // u8: host, join, hosting keeps Wi-Fi, joining keeps Wi-Fi
    SZFriendsFieldNetwork = 50,    // 1 to 32 bytes: the link's network name
    SZFriendsFieldPassphrase = 51, // 8 to 63 bytes: its one-time passphrase
    SZFriendsFieldAddress = 52,    // 4 or 16 bytes: the host's address on the link
    SZFriendsFieldPort = 53,       // u16be: its lane listener
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

NS_ASSUME_NONNULL_END
