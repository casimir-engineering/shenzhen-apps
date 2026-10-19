// Field rules for transport frames and handshake payloads, and the tag-length-value walker both use. Internal to
// service/session/. One walker for both because both carry the same `tag:u8 len:u16be value` fields in one tag
// namespace (SZFriendsSession.h), so a limit is enforced the same way wherever a field appears.

#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(uint8_t, SZFriendsFieldRuleFlags) {
    SZFriendsFieldRuleRequired = 1 << 0,
    SZFriendsFieldRuleBoolean = 1 << 1,      // one byte, 0 or 1
    SZFriendsFieldRuleMultipleOf16 = 1 << 2, // a list of 16-byte IDs
};

typedef struct {
    uint8_t tag;
    uint16_t minLength;
    uint16_t maxLength;
    uint8_t flags;
} SZFriendsFieldRule;

typedef struct {
    const SZFriendsFieldRule *_Nullable rules;
    size_t count;
} SZFriendsFieldRules;

// NO for a type this build does not know.
BOOL SZFriendsFrameRulesForType(uint8_t type, SZFriendsFieldRules *rules);
// Every field any handshake payload may carry; which ones a given message needs is the channel's check.
SZFriendsFieldRules SZFriendsHandshakePayloadRules(void);
// The rule for `tag` within `rules`, or NULL when that type does not define the tag.
const SZFriendsFieldRule *_Nullable SZFriendsFindFieldRule(SZFriendsFieldRules rules, uint8_t tag);
BOOL SZFriendsFieldValueAllowed(const SZFriendsFieldRule *rule, NSData *value);
// Byte width of an integer field, 0 for a tag that is not an integer.
NSUInteger SZFriendsIntegerFieldWidth(uint8_t tag);

// Walks the fields of `data` from `offset`, checking every length, duplicate and limit before copying anything.
// Fields the rules do not define are skipped (unknown tags are ignored); a duplicate of any tag fails.
NSDictionary<NSNumber *, NSData *> *_Nullable SZFriendsDecodeFields(NSData *data, NSUInteger offset,
                                                                   SZFriendsFieldRules rules, NSError **error);
// Appends fields in ascending tag order; fails on a field the rules do not define, a value out of its limits or a
// missing required field, appending nothing.
BOOL SZFriendsAppendFields(NSMutableData *output, NSDictionary<NSNumber *, NSData *> *fields,
                           SZFriendsFieldRules rules, NSError **error);

NSError *SZFriendsSessionMakeError(SZFriendsSessionError code, NSString *logDescription);

NS_ASSUME_NONNULL_END
