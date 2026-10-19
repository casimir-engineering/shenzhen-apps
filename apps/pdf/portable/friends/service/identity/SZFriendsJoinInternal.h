// The join exchange's wire format and keyed tags, shared by SZFriendsJoinWire.m, SZFriendsJoiner.m and
// SZFriendsJoinApprover.m, and read by the identity suite. Internal to service/identity/.
//
// A message is `version u8 (1) | kind u8 | fields`, each field `tag u8 | length u16be | value`, tags ascending and
// each at most once, every field its kind requires and no other: one encoding per message, so a signature or tag over
// the fields covers exactly what the reader acts on.

#import "service/identity/SZFriendsJoin.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, SZFriendsJoinField) {
    SZFriendsJoinTagRequestID = 1,  // 16
    SZFriendsJoinTagDeviceKey = 2,  // 32
    SZFriendsJoinTagStaticKey = 3,  // 32
    SZFriendsJoinTagName = 4,       // 1 to 64, UTF-8 without control characters
    SZFriendsJoinTagSystem = 5,     // 1 to 64, likewise
    SZFriendsJoinTagFriendsID = 6,  // 1 to 64
    SZFriendsJoinTagTime = 7,       // u64be milliseconds since 1970
    SZFriendsJoinTagSignature = 8,  // 64
    SZFriendsJoinTagShare = 9,      // 32: a CPace share
    SZFriendsJoinTagRootKey = 10,   // 32
    SZFriendsJoinTagTag = 11,       // 32: a keyed tag
    SZFriendsJoinTagConsent = 12,   // 64
    SZFriendsJoinTagPartIndex = 13, // u8
    SZFriendsJoinTagPartCount = 14, // u8, 1 to 255
    SZFriendsJoinTagPartData = 15,  // 1 to SZFriendsJoinPartMax
    SZFriendsJoinTagReason = 16,    // u8 SZFriendsJoinEndReason
    SZFriendsJoinTagChain = 17,     // 1 to 64,000
    SZFriendsJoinTagProfile = 18,   // 1 to 65,535
    SZFriendsJoinTagIDState = 19,   // u8
    SZFriendsJoinTagApproverKey = 20, // 32
};

// Never sent whole: the welcome's Parts reassemble into this.
static const SZFriendsJoinMessageKind SZFriendsJoinMessageWelcome = (SZFriendsJoinMessageKind)7;

// Canonical encoding; nil for a field outside its bounds or one the kind does not take.
NSData *_Nullable SZFriendsJoinEncode(SZFriendsJoinMessageKind kind, NSDictionary<NSNumber *, NSData *> *fields);
// Strict decoding of a message of `kind`: nil for any other kind, a field out of bounds, order or place, a missing
// one, or (for every kind but the welcome) more than SZFriendsJoinMessageMax bytes.
NSDictionary<NSNumber *, NSData *> *_Nullable SZFriendsJoinDecode(NSData *message, SZFriendsJoinMessageKind kind);

// BLAKE2b-256 keyed with `isk` over UTF-8(domain) || extra.
NSData *SZFriendsJoinTag(NSData *isk, NSString *domain, NSData *_Nullable extra);
BOOL SZFriendsJoinTagsEqual(NSData *a, NSData *b); // constant time; NO unless both are 32 bytes

// CPace's inputs for this exchange (SZFriendsJoin.h).
NSData *SZFriendsJoinChannelIdentifier(NSData *requestID, NSData *deviceKey, NSData *staticKey);
NSData *SZFriendsJoinApproverAD(NSData *approverKey, NSData *rootKey);

extern NSString *const SZFriendsJoinResponderTagDomain; // "SZFriends join responder v1"
extern NSString *const SZFriendsJoinInitiatorTagDomain; // "SZFriends join initiator v1"
extern NSString *const SZFriendsJoinWelcomeTagDomain;   // "SZFriends join welcome v1"

// A request message's fields once its signature verified; nil otherwise.
NSDictionary<NSNumber *, NSData *> *_Nullable SZFriendsJoinVerifiedRequest(NSData *message);

NSData *SZFriendsJoinUInt8(uint8_t value);
NSData *SZFriendsJoinUInt64(uint64_t value);
uint64_t SZFriendsJoinReadUInt64(NSData *data);

@interface SZFriendsJoinRequest ()
- (instancetype)initWithFields:(NSDictionary<NSNumber *, NSData *> *)fields receivedAt:(NSDate *)receivedAt;
@property(nonatomic, readwrite) SZFriendsJoinRequestState state;
@property(nonatomic, readwrite, copy, nullable) NSString *code;
@property(nonatomic, readwrite, copy, nullable) NSDate *codeExpiresAt;
@property(nonatomic, readwrite) NSUInteger attempts;
// The latest copy: a Waiting row ends SZFriendsJoinRequestLifetime after it.
@property(nonatomic, copy) NSDate *lastHeardAt;
@end

@interface SZFriendsJoinStep ()
+ (instancetype)stepWithKind:(SZFriendsJoinStepKind)kind;
+ (instancetype)sendStep:(NSData *)message;
+ (instancetype)endedStep:(SZFriendsJoinEndReason)reason;
+ (instancetype)joinedStepWithChain:(SZFriendsDeviceChain *)chain profile:(NSData *)profile state:(NSInteger)state;
@end

NS_ASSUME_NONNULL_END
