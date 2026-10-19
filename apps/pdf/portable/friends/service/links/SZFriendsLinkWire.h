// Shenzhen Friends links, the wire: what a link carries, and what travels between the sender's helper and whoever
// opens a download link (a browser page, or another Mac's helper). PROTOCOL.md § Links is the contract for the
// apps' side; § Links, wire format, documents these bytes for the link pages, which implement them in JavaScript
// with WebCrypto (portable/docs/plans/friends-links.md, lead decision 10 of m2-decision-brief.md).
//
// Helper-only and pure: no store, network or clock. Everything an opener sends is parsed strictly, and nothing in a
// payload or record is trusted before it opens under the link's keys.

#import <Foundation/Foundation.h>


NS_ASSUME_NONNULL_BEGIN

#pragma mark - Payloads (PROTOCOL.md § Links, the app's URL)

extern const NSUInteger SZFriendsLinkPayloadMax;    // 512 bytes: the longest payload string an app passes on
extern const NSUInteger SZFriendsLinkNameMax;       // 160 bytes of UTF-8 in a friend link's name
extern const NSUInteger SZFriendsLinkInviteLength;  // 16

// "f." then base64url of: 0x01, identity key (32), invite token (16), Friends ID length (3 to 64) and the ID, name
// length (0 to 160) and the name (UTF-8, no control characters), nothing after.
@interface SZFriendsFriendLinkPayload : NSObject
@property(nonatomic, copy) NSData *identityKey;
@property(nonatomic, copy) NSData *inviteToken;
@property(nonatomic, copy) NSString *friendsID;
@property(nonatomic, copy) NSString *name; // may be empty: the page and card then name the Friends ID
// "f.<base64url>", or nil when a field is out of bounds.
- (nullable NSString *)payloadString;
@end

// "d." then base64url of: 0x01, link id (16), link secret (32): exactly 49 bytes.
@interface SZFriendsDownloadLinkPayload : NSObject
@property(nonatomic, copy) NSData *linkID;
@property(nonatomic, copy) NSData *secret;
- (nullable NSString *)payloadString;
@end

// A friend or a download payload as an app received it; nil for anything else, including a payload longer than
// SZFriendsLinkPayloadMax, base64url that is not canonical, a version other than 1 or bytes left over.
id _Nullable SZFriendsParseLinkPayload(id _Nullable payload);
// The page's own link: <origin>/f#<base64url> or <origin>/d#<base64url>, from an app payload. Nil for a payload that
// does not parse or an origin that is not http(s) with a host and nothing after it.
NSString *_Nullable SZFriendsLinkWebURL(NSString *origin, NSString *payload);

// Strict base64url (RFC 4648 § 5): no padding, the URL alphabet only, unused trailing bits zero.
NSData *_Nullable SZFriendsLinkBase64URLDecode(NSString *text);
NSString *SZFriendsLinkBase64URLEncode(NSData *data);

#pragma mark - Keys and setup payloads (between the opener and the sender's helper, through the host)

// Every key comes from the link's secret with HKDF-SHA-256, so a browser derives the same with WebCrypto:
//   setup   salt link id, info "SZFriends link setup v1": the opener's hello and the sender's challenge (or end)
//   proof   salt link id, info "SZFriends link proof v1": HMAC key of the proof
//   session salt opener nonce || sender nonce, info "SZFriends link session v1": every later setup payload
//   content salt opener nonce || sender nonce, info "SZFriends link content v1" || attempt (1 byte): the records of
//           one connection attempt (1 direct, 2 relayed)
// A setup payload is a random 12-byte nonce, then AES-256-GCM of one JSON object with a string "t", under associated
// data "SZFriends link setup v1" || who sealed it (0x4f opener, 0x53 sender) || the link id.
extern const NSUInteger SZFriendsLinkNonceLength; // 16: the opener's and the sender's random values

typedef NS_ENUM(uint8_t, SZFriendsLinkSide) {
    SZFriendsLinkSideOpener = 0x4f,
    SZFriendsLinkSideSender = 0x53,
};

@interface SZFriendsLinkKeys : NSObject
// Nil unless the id is 16 bytes and the secret 32.
- (nullable instancetype)initWithLinkID:(NSData *)linkID secret:(NSData *)secret;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSData *linkID;
// Seals `message` (a JSON object with "t") as `side` under the setup key, or the session key once both nonces are set.
- (nullable NSData *)sealMessage:(NSDictionary<NSString *, id> *)message from:(SZFriendsLinkSide)side;
// Opens a payload the other side sealed: the object, or nil when it does not open under the current key, is not JSON,
// or has no string "t".
- (nullable NSDictionary<NSString *, id> *)openPayload:(NSData *)payload from:(SZFriendsLinkSide)side;
// Both nonces, once the challenge is known: later payloads use the session key.
- (void)setOpenerNonce:(NSData *)openerNonce senderNonce:(NSData *)senderNonce;
@property(nonatomic, readonly) BOOL hasSession;
// HMAC-SHA-256 under the proof key over "SZFriends link proof v1" || link id || sender nonce || opener nonce.
- (nullable NSData *)proof;
// Constant time; NO before the nonces are set.
- (BOOL)verifyProof:(NSData *)proof;
// 32 bytes: the content key of `attempt`; nil before the nonces are set.
- (nullable NSData *)contentKeyForAttempt:(uint8_t)attempt;
@end

#pragma mark - Records (over the data channel)

// One record is one data-channel message of at most 64 KiB, which every browser takes whole: its type (1 byte), then
// AES-256-GCM of the plaintext under the attempt's content key, with the nonce type || 0 0 0 || u64be index and the
// associated data "SZFriends link record v1". Chunks and the final chunk share one index sequence; every other type
// counts from 0. The type is in the nonce, so a chunk relabelled as the final one does not open.
extern const NSUInteger SZFriendsLinkRecordMax;  // 65,536
extern const NSUInteger SZFriendsLinkChunkBytes; // 65,280: every chunk but the final one holds exactly this
// Chunks the opener lets the sender run ahead ("upto" in start and credit), at most: what the sender keeps to.
extern const NSUInteger SZFriendsLinkCreditMax;  // 1,024

typedef NS_ENUM(uint8_t, SZFriendsLinkRecordType) {
    SZFriendsLinkRecordMetadata = 0x4d, // sender, index 0: u32be JSON length, the JSON, then the thumbnail's PNG
    SZFriendsLinkRecordChunk = 0x43,    // sender: the next SZFriendsLinkChunkBytes of the file
    SZFriendsLinkRecordFinal = 0x46,    // sender: the last bytes (possibly none)
    SZFriendsLinkRecordEnd = 0x45,      // sender, index 0: {"reason": "changed"|...}; nothing follows
    // opener: {"t":"start"|"credit","upto":n}, {"t":"done","ok":true} or {"t":"cancel"}
    SZFriendsLinkRecordControl = 0x51,
};

NSData *_Nullable SZFriendsLinkSealRecord(NSData *contentKey, SZFriendsLinkRecordType type, uint64_t index,
                                          NSData *plaintext);
// The plaintext of `record` when its type is one of `types` and it opens at `index`; *type says which.
NSData *_Nullable SZFriendsLinkOpenRecord(NSData *contentKey, NSArray<NSNumber *> *types, uint64_t index,
                                          NSData *record, SZFriendsLinkRecordType *_Nullable type);

#pragma mark - Metadata

// The metadata record's JSON: what the page shows and checks, plus, for an app opening the link, who sent it.
//   {"name":"Site photos.pdf","size":2516582,"type":"application/pdf","sha256":"<base64url>","sender":"Mei",
//    "from":{"identity_key":"<base64url>","friends_id":"brave-otter","blake2b":"<base64url>","sig":"<base64url>"}}
// The page reads name, size, type, sha256 and sender (a display name) and ignores "from". "from" lets an app put the
// file in the sender's conversation: `sig` is the sender's identity key's signature (domain "SZFriends link sender
// v1") over -signedBytesForLinkID:.
@interface SZFriendsLinkMetadata : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint64_t size;
@property(nonatomic, copy) NSString *mediaType; // "application/octet-stream" when unknown
@property(nonatomic, copy) NSData *sha256;
@property(nonatomic, copy, nullable) NSData *thumbnailPNG;
@property(nonatomic, copy, nullable) NSString *senderName;
@property(nonatomic, copy, nullable) NSData *senderIdentityKey;
@property(nonatomic, copy, nullable) NSString *senderFriendsID;
@property(nonatomic, copy, nullable) NSData *blake2b;
@property(nonatomic, copy, nullable) NSData *senderSignature;
// Link id, SHA-256, BLAKE2b, u64be size, then the file's name, the sender's Friends ID and name, each u32be-length-
// prefixed UTF-8.
- (NSData *)signedBytesForLinkID:(NSData *)linkID;
// The record's plaintext; nil when it would not fit one record (the thumbnail is left out first).
- (nullable NSData *)recordPlaintext;
+ (nullable instancetype)metadataFromRecordPlaintext:(NSData *)plaintext;
@end

NS_ASSUME_NONNULL_END
