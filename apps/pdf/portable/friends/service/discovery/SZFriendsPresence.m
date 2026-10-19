// Presence and callback tags (ADR 0004 § Presence tags, § Add by ID nearby step 3).

#import "service/discovery/SZFriendsDiscovery.h"

#include <sodium.h>

const NSTimeInterval SZFriendsPresenceWindow = 900;
const NSUInteger SZFriendsPresenceTagLength = 8;
const NSUInteger SZFriendsPresenceSecretLength = 32;
const NSUInteger SZFriendsCallbackTagsMax = 4;
const NSTimeInterval SZFriendsCallbackRequestLifetime = 7 * 24 * 3600;
// Hours, not the request's 7 days: long enough to cover a holder who answers later the same day (the helper keeps
// broadcasting to devices it sees), short enough that a device which heard us once stops recognising us.
const NSTimeInterval SZFriendsCallbackAdvertiseWindow = 6 * 3600;
const NSTimeInterval SZFriendsCallbackSecretLifetime = 24 * 3600;

// The personalisation string is part of the hashed message, not a BLAKE2b parameter, so the tag can be computed
// by any BLAKE2b implementation (the tests check vectors from Python's hashlib).
static const char kPresenceContext[] = "SZFriends presence v1";

int64_t SZFriendsPresenceWindowIndex(NSDate *date) {
    // floor, not truncation: a pre-1970 clock must still land in exactly one window.
    return (int64_t)floor(date.timeIntervalSince1970 / SZFriendsPresenceWindow);
}

NSDate *SZFriendsPresenceWindowEnd(NSDate *date) {
    int64_t window = SZFriendsPresenceWindowIndex(date);
    return [NSDate dateWithTimeIntervalSince1970:(double)(window + 1) * SZFriendsPresenceWindow];
}

NSData *SZFriendsPresenceTag(NSData *secret, int64_t windowIndex) {
    if (secret.length != SZFriendsPresenceSecretLength) {
        // A malformed stored secret must not crash the helper or yield a predictable tag: random bytes match
        // nobody and reveal nothing.
        NSMutableData *noise = [NSMutableData dataWithLength:SZFriendsPresenceTagLength];
        randombytes_buf(noise.mutableBytes, noise.length);
        return noise;
    }
    uint8_t message[sizeof kPresenceContext - 1 + 8];
    memcpy(message, kPresenceContext, sizeof kPresenceContext - 1);
    uint64_t w = (uint64_t)windowIndex;
    for (int i = 0; i < 8; i++) {
        message[sizeof kPresenceContext - 1 + (size_t)i] = (uint8_t)(w >> (56 - 8 * i));
    }
    // A 32-byte digest truncated to 8, as ADR 0004 says: BLAKE2b's output length is a parameter, so an 8-byte
    // BLAKE2b would be a different function.
    uint8_t digest[32];
    crypto_generichash(digest, sizeof digest, message, sizeof message, secret.bytes, secret.length);
    NSData *tag = [NSData dataWithBytes:digest length:SZFriendsPresenceTagLength];
    sodium_memzero(digest, sizeof digest);
    return tag;
}

NSArray<NSData *> *SZFriendsPresenceTagsToMatch(NSData *secret, NSDate *now) {
    int64_t w = SZFriendsPresenceWindowIndex(now);
    // The previous, current and next window, in that order.
    return @[
        SZFriendsPresenceTag(secret, w - 1), SZFriendsPresenceTag(secret, w), SZFriendsPresenceTag(secret, w + 1)
    ];
}

NSData *SZFriendsNewPresenceSecret(void) {
    NSMutableData *secret = [NSMutableData dataWithLength:SZFriendsPresenceSecretLength];
    randombytes_buf(secret.mutableBytes, secret.length);
    return secret;
}

SZFriendsTagMatcher SZFriendsMakeTagMatcher(NSDictionary<NSString *, NSArray<NSData *> *> *secretsByConversation,
                                            NSDate *now) {
    NSMutableDictionary<NSData *, NSString *> *table = [NSMutableDictionary dictionary];
    // Sorted so that, in the astronomically unlikely event two people's tags collide, the winner is
    // deterministic; a false match only costs one failed IK (ADR 0004).
    for (NSString *conversationID in [secretsByConversation.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        for (NSData *secret in secretsByConversation[conversationID]) {
            if (secret.length != SZFriendsPresenceSecretLength) continue;
            for (NSData *tag in SZFriendsPresenceTagsToMatch(secret, now)) {
                if (!table[tag]) table[tag] = conversationID;
            }
        }
    }
    NSDictionary<NSData *, NSString *> *frozen = [table copy];
    return ^NSString *_Nullable(NSData *tag) {
        return frozen[tag];
    };
}

@implementation SZFriendsPendingCallback

- (instancetype)initWithCallbackSecret:(NSData *)callbackSecret
                             createdAt:(NSDate *)createdAt
                             expiresAt:(NSDate *)expiresAt
                        secretIssuedAt:(NSDate *)secretIssuedAt
                       lastBroadcastAt:(NSDate *)lastBroadcastAt {
    if ((self = [super init])) {
        _callbackSecret = [callbackSecret copy];
        _createdAt = [createdAt copy];
        _expiresAt = [expiresAt copy];
        _secretIssuedAt = [secretIssuedAt copy];
        _lastBroadcastAt = [lastBroadcastAt copy];
    }
    return self;
}

- (instancetype)initWithCallbackSecret:(NSData *)callbackSecret
                             createdAt:(NSDate *)createdAt
                             expiresAt:(NSDate *)expiresAt {
    return [self initWithCallbackSecret:callbackSecret
                              createdAt:createdAt
                              expiresAt:expiresAt
                         secretIssuedAt:createdAt
                        lastBroadcastAt:createdAt];
}

@end

// When the request itself stops: its expiresAt or 7 days after createdAt, whichever is sooner. The lifetime is
// enforced here as well as by the store's expiresAt, so a row whose expiry was written wrongly still stops.
static NSDate *SZFriendsCallbackRequestEnd(SZFriendsPendingCallback *request) {
    NSDate *lifetimeEnd = [request.createdAt dateByAddingTimeInterval:SZFriendsCallbackRequestLifetime];
    return [request.expiresAt earlierDate:lifetimeEnd];
}

// When this request's tags stop being advertised; nil when they never start (no broadcast, malformed secret).
static NSDate *SZFriendsCallbackAdvertiseEnd(SZFriendsPendingCallback *request) {
    if (request.callbackSecret.length != SZFriendsPresenceSecretLength || request.lastBroadcastAt == nil) return nil;
    NSDate *end = SZFriendsCallbackRequestEnd(request);
    end = [end earlierDate:[request.lastBroadcastAt dateByAddingTimeInterval:SZFriendsCallbackAdvertiseWindow]];
    return [end earlierDate:[request.secretIssuedAt dateByAddingTimeInterval:SZFriendsCallbackSecretLifetime]];
}

NSArray<NSData *> *SZFriendsCallbackTagsToAdvertise(NSArray<SZFriendsPendingCallback *> *pending, NSDate *now) {
    NSMutableArray<SZFriendsPendingCallback *> *live = [NSMutableArray array];
    for (SZFriendsPendingCallback *request in pending) {
        NSDate *end = SZFriendsCallbackAdvertiseEnd(request);
        if (end != nil && [now compare:end] == NSOrderedAscending) [live addObject:request];
    }
    // Newest first: the request the person just made is the one they are waiting on.
    [live sortUsingComparator:^NSComparisonResult(SZFriendsPendingCallback *a, SZFriendsPendingCallback *b) {
        return [b.createdAt compare:a.createdAt];
    }];
    int64_t window = SZFriendsPresenceWindowIndex(now);
    NSMutableArray<NSData *> *tags = [NSMutableArray array];
    for (SZFriendsPendingCallback *request in live) {
        if (tags.count == SZFriendsCallbackTagsMax) break;
        [tags addObject:SZFriendsPresenceTag(request.callbackSecret, window)];
    }
    return tags;
}

BOOL SZFriendsCallbackNeedsFreshSecret(SZFriendsPendingCallback *request, NSDate *now) {
    if ([now compare:SZFriendsCallbackRequestEnd(request)] != NSOrderedAscending) return NO; // over: nothing to renew
    NSDate *retire = [request.secretIssuedAt dateByAddingTimeInterval:SZFriendsCallbackSecretLifetime];
    return [now compare:retire] != NSOrderedAscending;
}

NSDate *SZFriendsCallbackNextChange(NSArray<SZFriendsPendingCallback *> *pending, NSDate *now) {
    NSDate *next = nil;
    for (SZFriendsPendingCallback *request in pending) {
        NSDate *requestEnd = SZFriendsCallbackRequestEnd(request);
        NSDate *candidates[3] = {
            SZFriendsCallbackAdvertiseEnd(request),
            [request.secretIssuedAt dateByAddingTimeInterval:SZFriendsCallbackSecretLifetime],
            requestEnd,
        };
        for (int i = 0; i < 3; i++) {
            NSDate *moment = candidates[i];
            if (moment == nil || [moment compare:now] != NSOrderedDescending) continue;
            if (i == 1 && [moment compare:requestEnd] != NSOrderedAscending) continue; // the request ends first
            next = next ? [next earlierDate:moment] : moment;
        }
    }
    return next;
}

@implementation SZFriendsCallbackSlots {
    id _rotationKey;
    NSMutableArray<NSData *> *_slots;
    NSMutableIndexSet *_real; // slots holding a real tag rather than padding
}

static NSData *SZFriendsRandomSlot(void) {
    NSMutableData *slot = [NSMutableData dataWithLength:SZFriendsPresenceTagLength];
    randombytes_buf(slot.mutableBytes, slot.length);
    return slot;
}

- (NSArray<NSData *> *)slotsForTags:(NSArray<NSData *> *)tags rotationKey:(id<NSCopying, NSObject>)rotationKey {
    if (_slots == nil || ![_rotationKey isEqual:rotationKey]) {
        // A new window: every slot changes anyway (real tags are per window), so the padding is drawn afresh.
        _rotationKey = [rotationKey copyWithZone:nil];
        _slots = [NSMutableArray array];
        _real = [NSMutableIndexSet indexSet];
        for (NSUInteger i = 0; i < SZFriendsCallbackTagsMax; i++) [_slots addObject:SZFriendsRandomSlot()];
    }
    NSMutableArray<NSData *> *live = [NSMutableArray array];
    for (NSData *tag in tags) {
        if (tag.length == SZFriendsPresenceTagLength && live.count < SZFriendsCallbackTagsMax &&
            ![live containsObject:tag]) {
            [live addObject:tag];
        }
    }
    // A request that ended frees its slot for fresh padding: its holder must not keep matching us this window.
    for (NSUInteger i = 0; i < SZFriendsCallbackTagsMax; i++) {
        if ([_real containsIndex:i] && ![live containsObject:_slots[i]]) {
            _slots[i] = SZFriendsRandomSlot();
            [_real removeIndex:i];
        }
    }
    for (NSData *tag in live) {
        NSUInteger held = [_slots indexOfObject:tag];
        if (held != NSNotFound && [_real containsIndex:held]) continue;
        for (NSUInteger i = 0; i < SZFriendsCallbackTagsMax; i++) {
            if ([_real containsIndex:i]) continue;
            _slots[i] = tag;
            [_real addIndex:i];
            break;
        }
    }
    return [_slots copy];
}

@end
